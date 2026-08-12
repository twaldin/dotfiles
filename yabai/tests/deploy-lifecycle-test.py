#!/usr/bin/env python3
from __future__ import annotations

import ast
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Dict, Iterable, Optional, Sequence, Set, Tuple

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "deploy-lifecycle.py"
RUNTIME_CAPTURE_PATH = pathlib.Path(__file__).resolve().parent / "fixtures/yabai-7.1.25-runtime.json"
RUNTIME_CAPTURE = json.loads(RUNTIME_CAPTURE_PATH.read_text())
SPEC = importlib.util.spec_from_file_location("wm_deploy_lifecycle", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise SystemExit("module import failed")
wm = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = wm
SPEC.loader.exec_module(wm)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def make_app(root: pathlib.Path, name: str, executable_name: str, bundle_id: str, version: str, marker: str) -> Tuple[pathlib.Path, wm.AppSpec]:
    app = root / name
    executable_directory = app / "Contents/MacOS"
    executable_directory.mkdir(parents=True)
    executable = executable_directory / executable_name
    executable.write_text("#!/bin/sh\nprintf '%s\\n'\n" % marker)
    os.chmod(executable, 0o755)
    info = {
        "CFBundleExecutable": executable_name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundlePackageType": "APPL",
    }
    info_path = app / "Contents/Info.plist"
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle, fmt=plistlib.FMT_XML, sort_keys=True)
    os.chmod(info_path, 0o644)
    spec = wm.AppSpec(
        name=name,
        bundle_id=bundle_id,
        executable=executable_name,
        short_version=version,
        bundle_version=version,
        version_output=marker,
        archs="arm64",
        executable_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
        info_sha256=hashlib.sha256(info_path.read_bytes()).hexdigest(),
        cdhash="cdhash-" + executable_name,
        tree_sha256="",
    )
    lifecycle_stub = object.__new__(wm.Lifecycle)
    lifecycle_stub.sha256 = wm.Lifecycle.sha256
    spec = wm.dataclasses.replace(spec, tree_sha256=wm.Lifecycle.canonical_tree_digest(lifecycle_stub, app))
    return app, spec


def write_plist(path: pathlib.Path, label: str, executable: pathlib.Path, log: pathlib.Path) -> None:
    data = {
        "Label": label,
        "ProgramArguments": [str(executable)],
        "RunAtLoad": True,
        "KeepAlive": {"Crashed": True},
        "ThrottleInterval": 10,
        "StandardOutPath": str(log / (executable.name + ".out.log")),
        "StandardErrorPath": str(log / (executable.name + ".err.log")),
        "Umask": 0o77,
    }
    with path.open("wb") as handle:
        plistlib.dump(data, handle)


class FakeRunner:
    def __init__(self, paths: wm.Paths, specs: Dict[str, wm.AppSpec]) -> None:
        self.paths = paths
        self.specs = specs
        self.calls = []
        self.jobs: Set[str] = set()
        self.disabled: Dict[str, bool] = {label: True for label in wm.LABELS}
        self.processes: Set[str] = set()
        self.bootout_errors: Dict[str, int] = {}
        self.bootout_noop: Set[str] = set()
        self.config = dict(RUNTIME_CAPTURE["config"])
        self.spaces = [{"index": index, "display": 1} for index in range(1, 10)]
        self.rules = list(RUNTIME_CAPTURE["expected_rules"])
        self.runtime_socket_failures = 0
        self.runtime_default_cycles = 0

    def completed(self, argv: Sequence[str], code: int = 0, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(list(argv), code, stdout, stderr)

    def run(self, argv: Sequence[str], allowed: Iterable[int] = (0,), timeout: int = 30, input_text: Optional[str] = None) -> subprocess.CompletedProcess[str]:
        del timeout, input_text
        argv = tuple(argv)
        require(pathlib.Path(argv[0]).is_absolute(), "fake observed a non-absolute tool")
        self.calls.append(argv)
        code = 0
        stdout = ""
        stderr = ""
        if argv[0] == "/usr/bin/codesign" and "-dvvv" in argv:
            executable = pathlib.Path(argv[-1]) / "Contents/MacOS"
            name = next(executable.iterdir()).name
            stderr = "CDHash=" + self.specs[name].cdhash + "\n"
        elif argv[0] == "/usr/bin/lipo":
            stdout = self.specs[pathlib.Path(argv[-1]).name].archs + "\n"
        elif argv[0] == "/usr/bin/pgrep":
            if "-x" in argv:
                code = 0 if argv[-1] in self.processes else 1
            elif "-f" in argv:
                code = 0 if "AeroSpace" in self.processes else 1
            else:
                code = 2
        elif argv[0] == "/bin/launchctl":
            operation = argv[1]
            if operation == "print-disabled":
                stdout = "\n".join('"%s" => %s' % (label, "disabled" if self.disabled[label] else "enabled") for label in wm.LABELS)
            elif operation == "print":
                label = argv[2].rsplit("/", 1)[1]
                if label not in self.jobs:
                    code = 113
                else:
                    spec = wm.YABAI_SPEC if label == "com.asmvik.yabai" else wm.SKHD_SPEC
                    stdout = "path = %s\nprogram = %s\n" % (self.paths.installed_plist(label), self.paths.executable(spec))
            elif operation == "disable":
                label = argv[2].rsplit("/", 1)[1]
                self.disabled[label] = True
            elif operation == "enable":
                label = argv[2].rsplit("/", 1)[1]
                self.disabled[label] = False
            elif operation == "bootout":
                label = argv[2].rsplit("/", 1)[1]
                if label not in self.bootout_noop:
                    self.jobs.discard(label)
                    if label == "com.asmvik.yabai":
                        self.processes.discard("yabai")
                    else:
                        self.processes.discard("skhd")
                code = self.bootout_errors.get(label, 0)
            elif operation == "bootstrap":
                label = pathlib.Path(argv[3]).stem
                self.jobs.add(label)
                if label == "com.asmvik.yabai":
                    self.processes.add("yabai")
                else:
                    self.processes.add("skhd")
        elif argv[0] == "/usr/bin/open":
            require(argv[1] == str(self.paths.fallback_app), "fallback was not opened by exact path")
            self.processes.add("AeroSpace")
        elif pathlib.Path(argv[0]).name == "yabai" and len(argv) >= 3 and argv[1:3] == ("-m", "config"):
            if argv[3] == "external_bar" and self.runtime_socket_failures > 0:
                self.runtime_socket_failures -= 1
                code = 1
            elif argv[3] == "external_bar" and self.runtime_default_cycles > 0:
                self.runtime_default_cycles -= 1
                stdout = "off\n"
            else:
                stdout = self.config[argv[3]] + "\n"
        elif pathlib.Path(argv[0]).name == "yabai" and list(argv[1:]) == RUNTIME_CAPTURE["spaces_command"]:
            stdout = json.dumps(self.spaces)
        elif pathlib.Path(argv[0]).name == "yabai" and list(argv[1:]) == RUNTIME_CAPTURE["rules_command"]:
            stdout = json.dumps(self.rules)
        elif pathlib.Path(argv[0]).name in self.specs and argv[1:] == ("--version",):
            executable = pathlib.Path(argv[0])
            info_path = executable.parents[1] / "Info.plist"
            with info_path.open("rb") as handle:
                info = plistlib.load(handle)
            if executable.name == "AeroSpace":
                stdout = self.specs["AeroSpace"].version_output + "\n"
            else:
                stdout = executable.name + "-v" + str(info["CFBundleVersion"]) + "\n"
        if code not in set(allowed):
            raise wm.LifecycleError("fake external failure")
        return self.completed(argv, code, stdout, stderr)


def fixture() -> Tuple[pathlib.Path, wm.Paths, FakeRunner, wm.Lifecycle]:
    root = pathlib.Path(tempfile.mkdtemp(prefix="wm-lifecycle-test-"))
    os.chmod(root, 0o700)
    home = root / "home"
    repo = root / "repo"
    for directory in [home, repo, home / "Applications", home / "Library/LaunchAgents", home / "Library/Logs", root / "opt/homebrew/bin", root / "tmp", root / "Applications"]:
        directory.mkdir(parents=True, exist_ok=True)
    os.chmod(home, 0o700)
    app_yabai, yabai_spec = make_app(home / "Applications", "Yabai.app", "yabai", "com.test.yabai", "1", "yabai-v1")
    app_skhd, skhd_spec = make_app(home / "Applications", "skhd.app", "skhd", "com.test.skhd", "1", "skhd-v1")
    app_aero, aero_spec = make_app(root / "Applications", "AeroSpace.app", "AeroSpace", "bobko.aerospace", "1", "aero-v1")
    del app_yabai, app_skhd, app_aero
    wm.YABAI_SPEC = yabai_spec
    wm.SKHD_SPEC = skhd_spec
    wm.AEROSPACE_SPEC = aero_spec
    wm.PREVIOUS_APP_SPECS = {"yabai": (), "skhd": ()}
    wm.PREVIOUS_FALLBACK_SPECS = ()
    for directory in [repo / "yabai/launch-agents", repo / "skhd", repo / "aerospace"]:
        directory.mkdir(parents=True, exist_ok=True)
    (repo / "yabai/yabairc").write_text("YABAI=/Users/twaldin/Applications/Yabai.app/Contents/MacOS/yabai\n", encoding="utf-8")
    (repo / "skhd/skhdrc").write_text("alt - x : /Users/twaldin/Applications/Yabai.app/Contents/MacOS/yabai -m window --focus recent\n", encoding="utf-8")
    (repo / "aerospace/aerospace.toml").write_text("start-at-login = false\n", encoding="utf-8")
    paths = wm.Paths(
        home=home,
        repo_root=repo,
        app_root=home / "Applications",
        launch_agents=home / "Library/LaunchAgents",
        config_root=home / ".config",
        state_root=home / "Library/Application Support/dotfiles-deploy/wm-lifecycle-v1",
        legacy_log_root=root / "tmp",
        fallback_app=root / "Applications/AeroSpace.app",
    )
    write_plist(paths.plist("com.asmvik.yabai"), "com.asmvik.yabai", paths.executable(yabai_spec), home / "Library/Logs/yabai")
    write_plist(paths.plist("com.koekeishiya.skhd"), "com.koekeishiya.skhd", paths.executable(skhd_spec), home / "Library/Logs/skhd")
    runner = FakeRunner(paths, {"yabai": yabai_spec, "skhd": skhd_spec, "AeroSpace": aero_spec})
    lifecycle = wm.Lifecycle(paths, runner, sleep=lambda _seconds: None)
    lifecycle.make_private_directory(paths.state_root)
    lifecycle.make_private_directory(paths.state_root / "tmp")
    return root, paths, runner, lifecycle


def prepare(lifecycle: wm.Lifecycle, paths: wm.Paths, runner: FakeRunner) -> Dict[str, object]:
    for label in wm.LABELS:
        runner.disabled[label] = False
    for prefix in ("yabai", "skhd"):
        for stream in ("out", "err"):
            (paths.legacy_log_root / (prefix + "_" + paths.home.name + "." + stream + ".log")).write_text("private history")
    before = lifecycle.app_pair_digest()
    result = lifecycle.configure()
    require(result["deployment_state"] == "APPROVAL_REQUIRED", "prepare did not require approval")
    require(lifecycle.app_pair_digest() == before, "prepare changed adopted app bytes")
    require(not lifecycle.support_journal_path().exists(), "prepare left a support journal")
    require(not runner.jobs and all(runner.disabled.values()), "prepare did not converge all three labels")
    require(not runner.processes.intersection(("yabai", "skhd")), "prepare left a primary process")
    require(not list(paths.legacy_log_root.glob("*.log")), "prepare left legacy logs")
    lifecycle.verify_links()
    return result






def test_prepare_accepts_owned_nonwritable_existing_config_root() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        paths.config_root.mkdir(mode=0o755)
        (paths.config_root / "unrelated").mkdir()
        prepare(lifecycle, paths, runner)
        require((paths.config_root / "unrelated").is_dir(), "prepare changed an unrelated config object")
    finally:
        shutil.rmtree(root)


def test_active_prior_lanes_refuse_before_mutation() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        runner.jobs.update(("com.asmvik.yabai", "com.koekeishiya.skhd"))
        runner.disabled["com.asmvik.yabai"] = False
        runner.disabled["com.koekeishiya.skhd"] = False
        runner.processes.update(("yabai", "skhd"))
        before = len(runner.calls)
        try:
            lifecycle.configure()
        except wm.LifecycleError as error:
            require("stop the prior primary" in str(error), "active prior lane error is not actionable")
        else:
            raise AssertionError("active prior lanes were stopped by adoption")
        mutations = [call for call in runner.calls[before:] if call[0] == "/bin/launchctl" and call[1] in ("bootout", "disable", "enable", "bootstrap")]
        require(not mutations, "active prior preflight mutated a launch label")
        require(runner.processes.issuperset(("yabai", "skhd")), "active prior preflight stopped a process")
    finally:
        shutil.rmtree(root)

def test_prior_support_collision_refuses_before_lane_mutation() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        paths.config_root.mkdir(mode=0o700)
        for name in ("yabai", "skhd", "aerospace"):
            (paths.config_root / name).mkdir()
        for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
            os.symlink(str(paths.plist(label)), str(paths.installed_plist(label)))
        runner.jobs.update(wm.LABELS)
        runner.disabled = {label: False for label in wm.LABELS}
        runner.processes.update(("yabai", "skhd"))
        try:
            lifecycle.configure()
        except wm.LifecycleError as error:
            require(str(error).startswith("preflight:"), "collision did not return a preflight error")
        else:
            raise AssertionError("prior support collision was adopted without a policy")
        launch_mutations = [call for call in runner.calls if call[0] == "/bin/launchctl" and call[1] in ("bootout", "disable", "enable", "bootstrap")]
        require(not launch_mutations, "preflight collision mutated a primary label")
        require(runner.jobs == set(wm.LABELS), "preflight collision stopped a prior job")
        require(runner.processes.issuperset(("yabai", "skhd")), "preflight collision stopped a prior process")
        require(not lifecycle.support_journal_path().exists(), "preflight collision created a support journal")
    finally:
        shutil.rmtree(root)


def test_runtime_requires_primary_spaces_and_permits_external_spaces() -> None:
    root, _paths, runner, lifecycle = fixture()
    try:
        runner.processes.add("yabai")
        runner.spaces.extend(({"index": 10, "display": 2}, {"index": 11, "display": 2}))
        result = lifecycle.read_yabai_runtime_once()
        require(result["native_space_count"] == 9 and result["external_space_count"] == 2, "external Spaces were not permitted")
        runner.spaces = [item for item in runner.spaces if not (item["display"] == 1 and item["index"] == 9)]
        try:
            lifecycle.read_yabai_runtime_once()
        except wm.LifecycleError:
            pass
        else:
            raise AssertionError("missing primary-display Space was accepted")
    finally:
        shutil.rmtree(root)

def test_captured_runtime_contract() -> None:
    require(RUNTIME_CAPTURE["binary"]["version_output"] == "yabai-v7.1.25", "runtime capture version changed")
    require(RUNTIME_CAPTURE["binary"]["executable_sha256"] == "294491fa38fd025d3c7ea9cb9e5ef7c4238f3da7859a5e082fc63585f25dd909", "runtime capture binary identity changed")
    require(dict(wm.EXPECTED_CONFIG) == RUNTIME_CAPTURE["config"], "module config is not the independent runtime capture")
    require(RUNTIME_CAPTURE["rules_command"] == ["-m", "rule", "--list"], "runtime capture uses an unsupported rule command")
    require(RUNTIME_CAPTURE["spaces_contract"] == {"primary_display": 1, "primary_indices": list(range(1, 10)), "external_spaces_permitted": True}, "runtime Space capture changed")
    require(wm.PRIMARY_DISPLAY_INDEX == 1 and list(wm.EXPECTED_PRIMARY_SPACE_INDICES) == list(range(1, 10)), "module Space contract is not the independent capture")
    require(RUNTIME_CAPTURE["config"]["focus_follows_mouse"] == "disabled", "focus normalization capture changed")
    require(RUNTIME_CAPTURE["config"]["split_ratio"] == "0.5500", "split-ratio capture changed")




def test_status_observes_runtime_once_without_settling() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        prepared = prepare(lifecycle, paths, runner)
        lifecycle.attest_accessibility(str(prepared["manifest_sha256"]))
        lifecycle.activate()
        runner.runtime_default_cycles = 20
        runner.calls.clear()
        status = lifecycle.status()
        require(status["lane_state"] == "PARTIAL_UNSAFE", "point-in-time status hid a nonconverged runtime")
        starts = [call for call in runner.calls if pathlib.Path(call[0]).name == "yabai" and len(call) >= 4 and call[1:4] == ("-m", "config", "external_bar")]
        require(len(starts) == 1, "status retried instead of observing once")
    finally:
        shutil.rmtree(root)

def test_status_types_each_dangling_expected_link() -> None:
    for index in range(3):
        root, paths, runner, lifecycle = fixture()
        try:
            prepare(lifecycle, paths, runner)
            _source, destination = lifecycle.expected_links()[index]
            destination.unlink()
            os.symlink(str(root / "missing-target"), str(destination))
            status = lifecycle.status()
            require(status["deployment_state"] == "SUPPORT_NOT_READY", "dangling link did not resolve to support-not-ready")
        finally:
            shutil.rmtree(root)

def test_status_verifies_each_app_once() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        prepare(lifecycle, paths, runner)
        before = len(runner.calls)
        lifecycle.status()
        delta = runner.calls[before:]
        version_calls = [call for call in delta if len(call) == 2 and call[1] == "--version" and pathlib.Path(call[0]).name in ("yabai", "skhd", "AeroSpace")]
        require(len(version_calls) == 3, "status repeated app version execution")
        require(sorted(pathlib.Path(call[0]).name for call in version_calls) == ["AeroSpace", "skhd", "yabai"], "status app verification set is wrong")
    finally:
        shutil.rmtree(root)



def test_fallback_candidate_requires_all_reviewed_pins() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        spec = wm.AEROSPACE_SPEC
        arguments = wm.argparse.Namespace(
            path=str(paths.fallback_app),
            short_version=spec.short_version,
            bundle_version=spec.bundle_version or "NONE",
            version_output=spec.version_output,
            archs=spec.archs,
            executable_sha256=spec.executable_sha256,
            info_sha256=spec.info_sha256,
            tree_sha256=spec.tree_sha256,
            cdhash=spec.cdhash,
        )
        result = wm.verify_fallback_candidate(lifecycle, arguments)
        require(result["candidate_identity"]["tree_sha256"] == spec.tree_sha256, "fallback candidate pin verification failed")
        arguments.executable_sha256 = "0" * 64
        try:
            wm.verify_fallback_candidate(lifecycle, arguments)
        except wm.LifecycleError:
            pass
        else:
            raise AssertionError("fallback candidate accepted a wrong pin")
    finally:
        shutil.rmtree(root)

def test_previous_reviewed_fallback_identity_remains_usable() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        old_spec = wm.AEROSPACE_SPEC
        new_spec = wm.dataclasses.replace(
            old_spec,
            short_version="2",
            bundle_version="2",
            version_output="aero-v2",
            executable_sha256="0" * 64,
            info_sha256="1" * 64,
            cdhash="new-cdhash",
            tree_sha256="2" * 64,
        )
        wm.AEROSPACE_SPEC = new_spec
        wm.PREVIOUS_FALLBACK_SPECS = (old_spec,)
        identity = lifecycle.verify_approved_fallback()
        require(identity["version"] == old_spec.version_output, "previous fallback identity was not accepted")
        lifecycle.start_fallback()
        require("AeroSpace" in runner.processes, "previous fallback identity did not start")
    finally:
        shutil.rmtree(root)


def test_clean_recover_is_a_noop() -> None:
    root, _paths, runner, lifecycle = fixture()
    try:
        runner.jobs.update(("com.asmvik.yabai", "com.koekeishiya.skhd"))
        runner.processes.update(("yabai", "skhd"))
        runner.disabled["com.asmvik.yabai"] = False
        runner.disabled["com.koekeishiya.skhd"] = False
        before = (set(runner.jobs), set(runner.processes), dict(runner.disabled), list(runner.calls))
        result = wm.recover_transactions(lifecycle, wm.PairPublisher(lifecycle), False, False)
        after = (set(runner.jobs), set(runner.processes), dict(runner.disabled), list(runner.calls))
        require(result == {"app": "not-needed", "support": "not-needed"}, "clean recover result is wrong")
        require(after == before, "clean recover mutated a healthy deployment")
    finally:
        shutil.rmtree(root)

def test_prepare_attest_activate_rollback() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        prepared = prepare(lifecycle, paths, runner)
        attested = lifecycle.attest_accessibility(str(prepared["manifest_sha256"]))
        require(attested["deployment_state"] == "READY", "attestation did not become ready")
        activated = lifecycle.activate()
        require(activated["anonymous_primary_active_lane_count"] == 2, "activation lane count is wrong")
        require(runner.jobs == {"com.asmvik.yabai", "com.koekeishiya.skhd"}, "activation job set is wrong")
        require(runner.disabled["com.asmvik.skhd"], "alternate skhd is enabled")
        require(lifecycle.status()["lane_state"] == "PRIMARY_ACTIVE", "active state resolution failed")
        runner.bootout_errors = {label: 36 for label in wm.LABELS}
        rolled_back = lifecycle.rollback(start_fallback=True)
        require(rolled_back["anonymous_primary_active_lane_count"] == 0, "rollback left a primary lane")
        require("AeroSpace" in runner.processes, "rollback did not start fallback")
        open_calls = [call for call in runner.calls if call[0] == "/usr/bin/open"]
        require(open_calls[-1] == ("/usr/bin/open", str(paths.fallback_app)), "rollback used a fuzzy fallback path")
    finally:
        shutil.rmtree(root)


def test_rollback_attempts_every_label_and_never_opens_when_unsafe() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        prepare(lifecycle, paths, runner)
        runner.jobs.update(wm.LABELS)
        runner.processes.update(("yabai", "skhd"))
        runner.bootout_noop.add("com.asmvik.yabai")
        try:
            lifecycle.rollback(start_fallback=True)
        except wm.LifecycleError:
            pass
        else:
            raise AssertionError("unsafe rollback passed")
        attempts = [call for call in runner.calls if call[:2] == ("/bin/launchctl", "bootout")][-3:]
        require(len(attempts) == 3, "rollback exited before all three bootout attempts")
        require(not [call for call in runner.calls if call[0] == "/usr/bin/open"], "unsafe rollback opened fallback")
    finally:
        shutil.rmtree(root)





def test_activation_receipt_is_digest_indexed() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        prepared = prepare(lifecycle, paths, runner)
        lifecycle.attest_accessibility(str(prepared["manifest_sha256"]))
        activated = lifecycle.activate()
        receipt = lifecycle.write_receipt("activate", activated)
        digest = lifecycle.sha256(receipt)
        require(receipt.name.endswith("-activate-" + digest + ".json"), "activation receipt is not digest-indexed")
        accepted = lifecycle.accept_runtime(digest)
        require(accepted["deployment_state"] == "RUNTIME_ACCEPTED", "digest-indexed runtime acceptance failed")
    finally:
        shutil.rmtree(root)

def test_activation_waits_for_runtime_convergence() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        prepared = prepare(lifecycle, paths, runner)
        lifecycle.attest_accessibility(str(prepared["manifest_sha256"]))
        runner.runtime_socket_failures = 2
        runner.runtime_default_cycles = 2
        activated = lifecycle.activate()
        require(activated["runtime"]["runtime_setting_count"] == len(RUNTIME_CAPTURE["config"]), "settled runtime was not accepted")
        config_starts = [call for call in runner.calls if pathlib.Path(call[0]).name == "yabai" and len(call) >= 4 and call[1:4] == ("-m", "config", "external_bar")]
        require(len(config_starts) >= 5, "activation did not retry the full runtime predicate")
    finally:
        shutil.rmtree(root)

def test_activation_reports_rollback_convergence() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        prepared = prepare(lifecycle, paths, runner)
        lifecycle.attest_accessibility(str(prepared["manifest_sha256"]))
        runner.config["layout"] = "float"
        try:
            lifecycle.activate()
        except wm.LifecycleError as error:
            require("exact fallback startup converged" in str(error), "successful failure rollback was not reported")
        else:
            raise AssertionError("invalid runtime activated")
        require("AeroSpace" in runner.processes, "activation failure did not start fallback")
    finally:
        shutil.rmtree(root)

    root, paths, runner, lifecycle = fixture()
    try:
        prepared = prepare(lifecycle, paths, runner)
        lifecycle.attest_accessibility(str(prepared["manifest_sha256"]))
        runner.config["layout"] = "float"
        runner.bootout_noop.add("com.asmvik.yabai")
        try:
            lifecycle.activate()
        except wm.LifecycleError as error:
            require("rollback convergence failed" in str(error), "failed rollback convergence was hidden")
        else:
            raise AssertionError("unsafe activation rollback passed")
        require("AeroSpace" not in runner.processes, "unsafe activation rollback opened fallback")
    finally:
        shutil.rmtree(root)

def test_fallback_active_activation_is_noop() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        prepared = prepare(lifecycle, paths, runner)
        lifecycle.attest_accessibility(str(prepared["manifest_sha256"]))
        runner.processes.add("AeroSpace")
        before = len(runner.calls)
        try:
            lifecycle.activate()
        except wm.LifecycleError:
            pass
        else:
            raise AssertionError("fallback-active activation passed")
        delta = runner.calls[before:]
        require(not [call for call in delta if call[0] == "/bin/launchctl" and call[1] in ("enable", "disable", "bootstrap", "bootout")], "fallback-active activation mutated a primary label")
    finally:
        shutil.rmtree(root)


def test_source_rejected_before_execution() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        source = root / "unreviewed"
        sentinel = root / "executed"
        source.write_text("#!/bin/sh\n: > '%s'\n" % sentinel)
        os.chmod(source, 0o700)
        destination = paths.state_root / "tmp/staged"
        try:
            wm.stage_verified_source(lifecycle, source, destination, "0" * 64, "arm64", "bad")
        except wm.LifecycleError:
            pass
        else:
            raise AssertionError("unreviewed source passed")
        require(not sentinel.exists(), "unreviewed source executed")
        require(not [call for call in runner.calls if call and call[0] == str(destination)], "staged unreviewed source executed")
    finally:
        shutil.rmtree(root)


def make_marker_app(path: pathlib.Path, marker: str) -> None:
    (path / "Contents").mkdir(parents=True)
    (path / "Contents/marker").write_text(marker)


def test_pair_failpoints_restore_old_pair() -> None:
    phases = ["intent-stage-yabai", "staged-yabai", "intent-stage-skhd", "staged-skhd", "intent-backup-yabai", "backed-up-yabai", "intent-backup-skhd", "backed-up-skhd", "intent-install-yabai", "installed-yabai", "intent-install-skhd", "installed-skhd"]
    for phase in phases:
        root, paths, runner, lifecycle = fixture()
        try:
            candidate = root / "candidate"
            shutil.copytree(paths.app(wm.YABAI_SPEC), candidate / wm.YABAI_SPEC.name)
            shutil.copytree(paths.app(wm.SKHD_SPEC), candidate / wm.SKHD_SPEC.name)
            os.chmod(candidate, 0o700)
            shutil.rmtree(paths.app(wm.YABAI_SPEC))
            shutil.rmtree(paths.app(wm.SKHD_SPEC))
            _, old_yabai_spec = make_app(paths.app_root, wm.YABAI_SPEC.name, "yabai", "com.test.yabai.old", "0", "yabai-v0")
            _, old_skhd_spec = make_app(paths.app_root, wm.SKHD_SPEC.name, "skhd", "com.test.skhd.old", "0", "skhd-v0")
            old_yabai_spec = wm.dataclasses.replace(old_yabai_spec, cdhash=wm.YABAI_SPEC.cdhash)
            old_skhd_spec = wm.dataclasses.replace(old_skhd_spec, cdhash=wm.SKHD_SPEC.cdhash)
            wm.PREVIOUS_APP_SPECS = {"yabai": (old_yabai_spec,), "skhd": (old_skhd_spec,)}
            def failpoint(name: str) -> None:
                if name == phase:
                    raise KeyboardInterrupt()
            publisher = wm.PairPublisher(lifecycle, failpoint=failpoint)
            try:
                publisher.publish(candidate)
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("pair failpoint did not interrupt")
            with (paths.app(wm.YABAI_SPEC) / "Contents/Info.plist").open("rb") as handle:
                restored_yabai = plistlib.load(handle)
            with (paths.app(wm.SKHD_SPEC) / "Contents/Info.plist").open("rb") as handle:
                restored_skhd = plistlib.load(handle)
            require(restored_yabai["CFBundleIdentifier"] == "com.test.yabai.old", "pair recovery changed old yabai")
            require(restored_skhd["CFBundleIdentifier"] == "com.test.skhd.old", "pair recovery changed old skhd")
            require(not publisher.transaction.exists(), "safe pair recovery left transaction residue")
        finally:
            shutil.rmtree(root)



def test_pair_success_fresh_recovery_and_conflict_preservation() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        candidate = root / "candidate"
        shutil.copytree(paths.app(wm.YABAI_SPEC), candidate / wm.YABAI_SPEC.name)
        shutil.copytree(paths.app(wm.SKHD_SPEC), candidate / wm.SKHD_SPEC.name)
        os.chmod(candidate, 0o700)
        shutil.rmtree(paths.app(wm.YABAI_SPEC))
        shutil.rmtree(paths.app(wm.SKHD_SPEC))
        _, old_yabai_spec = make_app(paths.app_root, wm.YABAI_SPEC.name, "yabai", "com.test.yabai.old", "0", "yabai-v0")
        _, old_skhd_spec = make_app(paths.app_root, wm.SKHD_SPEC.name, "skhd", "com.test.skhd.old", "0", "skhd-v0")
        old_yabai_spec = wm.dataclasses.replace(old_yabai_spec, cdhash=wm.YABAI_SPEC.cdhash)
        old_skhd_spec = wm.dataclasses.replace(old_skhd_spec, cdhash=wm.SKHD_SPEC.cdhash)
        wm.PREVIOUS_APP_SPECS = {"yabai": (old_yabai_spec,), "skhd": (old_skhd_spec,)}
        publisher = wm.PairPublisher(lifecycle)
        result = publisher.publish(candidate)
        require(result["published_app_count"] == 2, "successful pair publication count is wrong")
        lifecycle.verify_app(paths.app(wm.YABAI_SPEC), wm.YABAI_SPEC)
        lifecycle.verify_app(paths.app(wm.SKHD_SPEC), wm.SKHD_SPEC)
        require(not publisher.transaction.exists(), "successful pair publication left a transaction")
    finally:
        shutil.rmtree(root)

    root, paths, runner, lifecycle = fixture()
    try:
        candidate = root / "candidate"
        shutil.copytree(paths.app(wm.YABAI_SPEC), candidate / wm.YABAI_SPEC.name)
        shutil.copytree(paths.app(wm.SKHD_SPEC), candidate / wm.SKHD_SPEC.name)
        os.chmod(candidate, 0o700)
        shutil.rmtree(paths.app(wm.YABAI_SPEC))
        shutil.rmtree(paths.app(wm.SKHD_SPEC))
        def interrupt(name: str) -> None:
            if name == "installed-yabai":
                raise KeyboardInterrupt()
        publisher = wm.PairPublisher(lifecycle, failpoint=interrupt)
        try:
            publisher.publish(candidate)
        except KeyboardInterrupt:
            pass
        else:
            raise AssertionError("fresh pair failure did not interrupt")
        require(not paths.app(wm.YABAI_SPEC).exists() and not paths.app(wm.SKHD_SPEC).exists(), "fresh recovery left a partial pair")
        require(not publisher.transaction.exists(), "fresh recovery left safe residue")
    finally:
        shutil.rmtree(root)

    root, paths, runner, lifecycle = fixture()
    try:
        publisher = wm.PairPublisher(lifecycle)
        publisher.transaction.mkdir(mode=0o700)
        source_digest = publisher.tree_digest(paths.app(wm.YABAI_SPEC))
        data = {
            "schema": "wm-app-pair-transaction-v1",
            "phase": "intent-install-yabai",
            "items": {
                "yabai": {"old_present": False, "old_digest": None, "new_digest": source_digest, "install_intent": True},
                "skhd": {"old_present": True, "old_digest": publisher.tree_digest(paths.app(wm.SKHD_SPEC)), "new_digest": publisher.tree_digest(paths.app(wm.SKHD_SPEC)), "install_intent": False},
            },
        }
        publisher.write_manifest(data)
        shutil.rmtree(paths.app(wm.YABAI_SPEC))
        make_marker_app(paths.app(wm.YABAI_SPEC), "unknown")
        try:
            publisher.recover()
        except wm.LifecycleError:
            pass
        else:
            raise AssertionError("conflicted recovery deleted an unknown object")
        require((paths.app(wm.YABAI_SPEC) / "Contents/marker").read_text() == "unknown", "conflicted recovery changed an unknown object")
        require(publisher.transaction.exists(), "conflicted recovery deleted its evidence")
    finally:
        shutil.rmtree(root)



def test_committed_support_recovery_retains_published_support() -> None:
    root, paths, runner, _lifecycle = fixture()
    def failpoint(name: str) -> None:
        if name == "after-support-commit":
            raise wm.InterruptedLifecycle("injected post-commit interruption")
    lifecycle = wm.Lifecycle(paths, runner, sleep=lambda _seconds: None, support_failpoint=failpoint)
    try:
        try:
            lifecycle.configure()
        except wm.InterruptedLifecycle:
            pass
        else:
            raise AssertionError("post-commit failpoint did not interrupt")
        require(lifecycle.support_journal_path().exists(), "post-commit interruption lost its journal")
        lifecycle.support_failpoint = lambda _name: None
        recovered = lifecycle.recover_support()
        require(recovered["support_recovery"] == "committed-support-retained", "committed recovery did not retain support")
        lifecycle.verify_links()
        for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
            require(paths.installed_plist(label).exists(), "committed recovery removed a launch agent")
    finally:
        shutil.rmtree(root)

def test_support_write_ahead_recovery_after_each_mutation_class() -> None:
    for stage in ("after-create-directory", "after-create-file", "after-create-link"):
        root, paths, runner, _lifecycle = fixture()
        triggered = {"done": False}
        def failpoint(name: str) -> None:
            if name == stage and not triggered["done"]:
                triggered["done"] = True
                raise wm.InterruptedLifecycle("injected support interruption")
        lifecycle = wm.Lifecycle(paths, runner, sleep=lambda _seconds: None, support_failpoint=failpoint)
        try:
            try:
                lifecycle.configure()
            except wm.InterruptedLifecycle:
                pass
            else:
                raise AssertionError("support write-ahead failpoint did not interrupt")
            require(lifecycle.support_journal_path().exists(), "support write-ahead failure lost its journal")
            lifecycle.support_failpoint = lambda _name: None
            result = lifecycle.recover_support()
            require(result["support_recovery"] == "created-support-removed", "support write-ahead recovery result is wrong")
            require(not lifecycle.support_journal_path().exists(), "support write-ahead recovery left its journal")
            for _source, destination in lifecycle.expected_links():
                require(not destination.exists() and not destination.is_symlink(), "support write-ahead recovery left a link")
            for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
                require(not paths.installed_plist(label).exists(), "support write-ahead recovery left a plist")
        finally:
            shutil.rmtree(root)

def test_support_recovery_removes_only_recorded_objects() -> None:
    root, paths, runner, lifecycle = fixture()
    try:
        original = lifecycle.safe_symlink
        calls = {"count": 0}
        def interrupted(source: pathlib.Path, destination: pathlib.Path) -> None:
            calls["count"] += 1
            if calls["count"] == 3:
                raise wm.LifecycleError("injected")
            original(source, destination)
        lifecycle.safe_symlink = interrupted  # type: ignore[assignment]
        try:
            lifecycle.configure()
        except wm.LifecycleError:
            pass
        else:
            raise AssertionError("support interruption did not fail")
        lifecycle.safe_symlink = original  # type: ignore[assignment]
        require(lifecycle.support_journal_path().exists(), "support failure lost its journal")
        result = lifecycle.recover_support()
        require(result["support_recovery"] == "created-support-removed", "support recovery result is wrong")
        require(not lifecycle.support_journal_path().exists(), "support recovery left its journal")
        require(not paths.installed_plist("com.asmvik.yabai").exists(), "support recovery left a created primary-a plist")
        require(not paths.installed_plist("com.koekeishiya.skhd").exists(), "support recovery left a created primary-b plist")
    finally:
        shutil.rmtree(root)


def test_tool_binding_contract() -> None:
    tree = ast.parse(MODULE_PATH.read_text())
    subprocess_calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess" and node.func.attr == "run"]
    require(len(subprocess_calls) == 1, "subprocess execution escaped Runner")
    keywords = {keyword.arg: keyword.value for keyword in subprocess_calls[0].keywords}
    require(isinstance(keywords.get("shell"), ast.Constant) and keywords["shell"].value is False, "subprocess shell is not explicitly disabled")
    prohibited = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name) and node.func.value.id == "os" and node.func.attr in ("system", "popen", "spawnl", "spawnv")]
    require(not prohibited, "a prohibited process API is present")
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "run" and node.args:
            first = node.args[0]
            if isinstance(first, (ast.Tuple, ast.List)) and first.elts and isinstance(first.elts[0], ast.Constant) and isinstance(first.elts[0].value, str):
                require(first.elts[0].value.startswith("/"), "a literal external tool path is not absolute")


def main() -> None:
    test_prepare_accepts_owned_nonwritable_existing_config_root()
    test_active_prior_lanes_refuse_before_mutation()
    test_prior_support_collision_refuses_before_lane_mutation()
    test_runtime_requires_primary_spaces_and_permits_external_spaces()
    test_captured_runtime_contract()
    test_status_observes_runtime_once_without_settling()
    test_status_types_each_dangling_expected_link()
    test_status_verifies_each_app_once()
    test_fallback_candidate_requires_all_reviewed_pins()
    test_previous_reviewed_fallback_identity_remains_usable()
    test_clean_recover_is_a_noop()
    test_prepare_attest_activate_rollback()
    test_rollback_attempts_every_label_and_never_opens_when_unsafe()
    test_activation_receipt_is_digest_indexed()
    test_activation_waits_for_runtime_convergence()
    test_activation_reports_rollback_convergence()
    test_fallback_active_activation_is_noop()
    test_source_rejected_before_execution()
    test_pair_failpoints_restore_old_pair()
    test_pair_success_fresh_recovery_and_conflict_preservation()
    test_committed_support_recovery_retains_published_support()
    test_support_write_ahead_recovery_after_each_mutation_class()
    test_support_recovery_removes_only_recorded_objects()
    test_tool_binding_contract()
    print("wm deployment lifecycle: PASS")


if __name__ == "__main__":
    main()
