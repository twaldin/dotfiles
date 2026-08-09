#!/usr/bin/env python3
"""Fail-closed yabai/skhd build, publication, activation, and rollback lifecycle."""
from __future__ import annotations

import argparse
import contextlib
import dataclasses
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import uuid
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple


class LifecycleError(RuntimeError):
    pass


def write_all(descriptor: int, content: bytes) -> None:
    offset = 0
    while offset < len(content):
        written = os.write(descriptor, content[offset:])
        if written <= 0:
            raise LifecycleError("a durable file write did not progress")
        offset += written


@dataclasses.dataclass(frozen=True)
class AppSpec:
    name: str
    bundle_id: str
    executable: str
    short_version: str
    bundle_version: Optional[str]
    version_output: str
    archs: str
    executable_sha256: str
    info_sha256: str
    cdhash: str
    tree_sha256: str


YABAI_SPEC = AppSpec(
    name="Yabai.app",
    bundle_id="com.asmvik.yabai",
    executable="yabai",
    short_version="7.1.25",
    bundle_version="7.1.25",
    version_output="yabai-v7.1.25",
    archs="x86_64 arm64",
    executable_sha256="294491fa38fd025d3c7ea9cb9e5ef7c4238f3da7859a5e082fc63585f25dd909",
    info_sha256="1514502bbdd0c0dcd69913ce5bb0976d4282949d063f4f48e14ec6743ae5324e",
    cdhash="dd5802e8ffff9db46511bd539eeb38efa219ca14",
    tree_sha256="08ce103be8b3b06da27070013c90af68a84fefb581cb0c896e1a25f8b5d026f7",
)
SKHD_SPEC = AppSpec(
    name="skhd.app",
    bundle_id="com.koekeishiya.skhd",
    executable="skhd",
    short_version="0.3.9",
    bundle_version="0.3.9",
    version_output="skhd-v0.3.9",
    archs="arm64",
    executable_sha256="b0b063cb45e6357d11b6236bd72e110ae1118f6fd14e5837b54f7d8f197ce1d5",
    info_sha256="c19fa475cedc7ffad097ce1fa790a065ec44b45add7b0dd8936f7289001182f7",
    cdhash="9f65beedc20db2ef5a891cc0dea38a05d3c92d9d",
    tree_sha256="149fb0a3d2943bed86014cd65b03b316dc5723433feb9cdca118a3abd0e71554",
)
AEROSPACE_SPEC = AppSpec(
    name="AeroSpace.app",
    bundle_id="bobko.aerospace",
    executable="AeroSpace",
    short_version="0.21.3-Beta",
    bundle_version=None,
    version_output="0.21.3-Beta d56e1637c3a1ed660d0cadd7534e94fb3218d1c3",
    archs="x86_64 arm64",
    executable_sha256="dfcda5349519df53e8778309ceec46fae92022637a0570e82fec662d8f583adb",
    info_sha256="4fe4240034368c4b6bf2c3fea0d96ac20356f771bc80add1bb9224ee068a6c4d",
    cdhash="eab4b122257e31986865eb448c74c7a8b614143c",
    tree_sha256="6c8a086407a1056185903861271d2362eead06f3764f326fa4d817adda4d33a9",
)
# First baseline: no earlier lifecycle-managed app pair is approved. Before a
# reviewed version bump, move the outgoing specs into this table.
PREVIOUS_APP_SPECS: Mapping[str, Tuple[AppSpec, ...]] = {"yabai": (), "skhd": ()}
PREVIOUS_FALLBACK_SPECS: Tuple[AppSpec, ...] = ()
SOURCE_SHA256 = {
    "yabai": "372ad557a7c54a6199a78dcbcefe5b60fd0224e5c1f5139cfaed00dfdaa44501",
    "skhd": "7cc052bb45c9b0b7cec28756c99f8267d495cf24b15e91b6fbe06da367a87b80",
}
LABELS = ("com.asmvik.yabai", "com.koekeishiya.skhd", "com.asmvik.skhd")
PROCESS_NAMES = ("yabai", "skhd")
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
# Exact normalized strings captured from yabai 7.1.25. In particular,
# focus_follows_mouse configures as "off" but reads back as "disabled".
EXPECTED_CONFIG: Mapping[str, str] = {
    "external_bar": "all:32:0",
    "mouse_follows_focus": "off",
    "focus_follows_mouse": "disabled",
    "display_arrangement_order": "default",
    "window_origin_display": "default",
    "window_placement": "second_child",
    "window_insertion_point": "last",
    "window_zoom_persist": "on",
    "skip_window_focus_animation": "on",
    "window_animation_duration": "0.000000",
    "split_ratio": "0.5500",
    "split_type": "auto",
    "auto_balance": "off",
    "top_padding": "10",
    "bottom_padding": "10",
    "left_padding": "10",
    "right_padding": "10",
    "window_gap": "8",
    "layout": "bsp",
    "mouse_modifier": "fn",
    "mouse_action1": "move",
    "mouse_action2": "resize",
    "mouse_drop_action": "swap",
}
PRIMARY_DISPLAY_INDEX = 1
EXPECTED_PRIMARY_SPACE_INDICES = tuple(range(1, 10))


@dataclasses.dataclass(frozen=True)
class Paths:
    home: pathlib.Path
    repo_root: pathlib.Path
    app_root: pathlib.Path
    launch_agents: pathlib.Path
    config_root: pathlib.Path
    state_root: pathlib.Path
    legacy_log_root: pathlib.Path
    fallback_app: pathlib.Path

    @classmethod
    def production(cls) -> "Paths":
        home = pathlib.Path.home().resolve()
        module = pathlib.Path(__file__).resolve()
        return cls(
            home=home,
            repo_root=module.parent.parent,
            app_root=home / "Applications",
            launch_agents=home / "Library/LaunchAgents",
            config_root=home / ".config",
            state_root=home / "Library/Application Support/dotfiles-deploy/wm-lifecycle-v1",
            legacy_log_root=pathlib.Path("/tmp"),
            fallback_app=pathlib.Path("/Applications/AeroSpace.app"),
        )

    def app(self, spec: AppSpec) -> pathlib.Path:
        if spec == AEROSPACE_SPEC:
            return self.fallback_app
        return self.app_root / spec.name

    def executable(self, spec: AppSpec) -> pathlib.Path:
        return self.app(spec) / "Contents/MacOS" / spec.executable

    def plist(self, label: str) -> pathlib.Path:
        return self.repo_root / "yabai/launch-agents" / (label + ".plist")

    def installed_plist(self, label: str) -> pathlib.Path:
        return self.launch_agents / (label + ".plist")


class Runner:
    def __init__(self, home: pathlib.Path, temp: pathlib.Path) -> None:
        self.home = home
        self.temp = temp

    def environment(self) -> Dict[str, str]:
        return {
            "HOME": str(self.home),
            "USER": self.home.name,
            "LOGNAME": self.home.name,
            "PATH": SYSTEM_PATH,
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": str(self.temp),
        }

    def run(
        self,
        argv: Sequence[str],
        allowed: Iterable[int] = (0,),
        timeout: int = 30,
        input_text: Optional[str] = None,
    ) -> subprocess.CompletedProcess[str]:
        if not argv or not pathlib.Path(argv[0]).is_absolute():
            raise LifecycleError("an external tool path is not absolute")
        try:
            result = subprocess.run(
                list(argv),
                input=input_text,
                stdin=subprocess.DEVNULL if input_text is None else None,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=timeout,
                env=self.environment(),
                check=False,
                shell=False,
                close_fds=True,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise LifecycleError("an external operation could not be inspected") from error
        if result.returncode not in set(allowed):
            raise LifecycleError("an external operation failed")
        return result


class Lifecycle:
    def __init__(
        self,
        paths: Paths,
        runner: Runner,
        sleep: Callable[[float], None] = time.sleep,
        support_failpoint: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.paths = paths
        self.runner = runner
        self.sleep = sleep
        self.support_failpoint = support_failpoint or (lambda _name: None)
        self.uid = os.getuid()
        self.domain = "gui/{0}".format(self.uid)

    @staticmethod
    def sha256(path: pathlib.Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()

    def require_owned_directory(self, path: pathlib.Path, mode: Optional[int] = None) -> None:
        try:
            metadata = os.lstat(str(path))
        except OSError as error:
            raise LifecycleError("a required directory is absent") from error
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise LifecycleError("a directory path has an unsafe type")
        if metadata.st_uid != self.uid:
            raise LifecycleError("a directory owner is invalid")
        if mode is not None and stat.S_IMODE(metadata.st_mode) != mode:
            raise LifecycleError("a private directory mode is invalid")

    def make_private_directory(self, path: pathlib.Path) -> None:
        try:
            relative = path.relative_to(self.paths.home)
        except ValueError as error:
            raise LifecycleError("a private directory is outside the user home") from error
        current = self.paths.home
        self.require_owned_directory(current)
        for component in relative.parts:
            current = current / component
            try:
                metadata = os.lstat(str(current))
            except FileNotFoundError:
                os.mkdir(str(current), 0o700)
                metadata = os.lstat(str(current))
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != self.uid:
                raise LifecycleError("a private directory ancestor is unsafe")
        if stat.S_IMODE(os.lstat(str(path)).st_mode) != 0o700:
            raise LifecycleError("a private directory mode is invalid")

    def verify_regular_file(self, path: pathlib.Path, executable: bool = False) -> os.stat_result:
        try:
            metadata = os.lstat(str(path))
        except OSError as error:
            raise LifecycleError("a required file is absent") from error
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise LifecycleError("a required file has an unsafe type")
        if metadata.st_uid != self.uid or metadata.st_nlink != 1:
            raise LifecycleError("a required file identity is unsafe")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            raise LifecycleError("a required file is group- or world-writable")
        if executable and not os.access(str(path), os.X_OK):
            raise LifecycleError("a required executable is not executable")
        return metadata

    def canonical_tree_digest(self, root: pathlib.Path) -> str:
        records: List[Dict[str, Any]] = []
        paths = [root] + sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())
        for path in paths:
            metadata = os.lstat(str(path))
            relative = "." if path == root else path.relative_to(root).as_posix()
            if stat.S_ISDIR(metadata.st_mode):
                record: Dict[str, Any] = {"path": relative, "kind": "dir", "mode": stat.S_IMODE(metadata.st_mode)}
            elif stat.S_ISREG(metadata.st_mode):
                record = {"path": relative, "kind": "file", "mode": stat.S_IMODE(metadata.st_mode), "size": metadata.st_size, "nlink": metadata.st_nlink, "sha256": self.sha256(path)}
            else:
                raise LifecycleError("an app bundle node type is unsafe")
            records.append(record)
        return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()

    def verify_app(self, path: pathlib.Path, spec: AppSpec, compare_identity: bool = True) -> Dict[str, str]:
        self.require_owned_directory(path)
        for root, directories, files in os.walk(str(path), topdown=True, followlinks=False):
            for name in list(directories) + list(files):
                node = pathlib.Path(root) / name
                metadata = os.lstat(str(node))
                if stat.S_ISLNK(metadata.st_mode):
                    raise LifecycleError("an app bundle contains a symbolic link")
                if metadata.st_uid != self.uid or stat.S_IMODE(metadata.st_mode) & 0o022:
                    raise LifecycleError("an app bundle node identity is unsafe")
                if stat.S_ISREG(metadata.st_mode) and metadata.st_nlink != 1:
                    raise LifecycleError("an app bundle file is multiply linked")
                if not (stat.S_ISREG(metadata.st_mode) or stat.S_ISDIR(metadata.st_mode)):
                    raise LifecycleError("an app bundle node type is unsafe")
        info_path = path / "Contents/Info.plist"
        executable = path / "Contents/MacOS" / spec.executable
        self.verify_regular_file(info_path)
        self.verify_regular_file(executable, executable=True)
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        if info.get("CFBundleIdentifier") != spec.bundle_id:
            raise LifecycleError("an app bundle identifier is not reviewed")
        if info.get("CFBundleExecutable") != spec.executable:
            raise LifecycleError("an app executable name is not reviewed")
        if info.get("CFBundleShortVersionString") != spec.short_version:
            raise LifecycleError("an app short version is not reviewed")
        if info.get("CFBundleVersion") != spec.bundle_version:
            raise LifecycleError("an app bundle version is not reviewed")
        executable_hash = self.sha256(executable)
        info_hash = self.sha256(info_path)
        tree_hash = self.canonical_tree_digest(path)
        if compare_identity and (executable_hash != spec.executable_sha256 or info_hash != spec.info_sha256 or tree_hash != spec.tree_sha256):
            raise LifecycleError("an app content identity is not reviewed")
        self.runner.run(("/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)))
        details = self.runner.run(("/usr/bin/codesign", "-dvvv", str(path)))
        cdhashes = [line.split("=", 1)[1] for line in details.stderr.splitlines() if line.startswith("CDHash=")]
        if len(cdhashes) != 1:
            raise LifecycleError("an app code identity is ambiguous")
        if compare_identity and cdhashes[0] != spec.cdhash:
            raise LifecycleError("an app code identity is not reviewed")
        architecture = self.runner.run(("/usr/bin/lipo", "-archs", str(executable))).stdout.strip()
        if architecture != spec.archs:
            raise LifecycleError("an app architecture is not reviewed")
        version = self.runner.run((str(executable), "--version")).stdout.strip()
        if version != spec.version_output:
            raise LifecycleError("an app version output is not reviewed")
        return {
            "bundle_id": spec.bundle_id,
            "version": version,
            "archs": architecture,
            "executable_sha256": executable_hash,
            "info_sha256": info_hash,
            "cdhash": cdhashes[0],
            "tree_sha256": tree_hash,
        }

    def verify_approved_fallback(self) -> Dict[str, str]:
        for spec in (AEROSPACE_SPEC,) + PREVIOUS_FALLBACK_SPECS:
            try:
                return self.verify_app(self.paths.app(AEROSPACE_SPEC), spec)
            except LifecycleError:
                continue
        raise LifecycleError("the fallback app is not an approved identity")

    def verify_all_apps(self) -> Dict[str, Dict[str, str]]:
        return {
            "primary_a": self.verify_app(self.paths.app(YABAI_SPEC), YABAI_SPEC),
            "primary_b": self.verify_app(self.paths.app(SKHD_SPEC), SKHD_SPEC),
            "fallback": self.verify_approved_fallback(),
        }

    def runtime_manifest(self) -> Dict[str, Any]:
        plist_identities = {}
        for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
            path = self.paths.plist(label)
            self.verify_regular_file(path)
            plist_identities[label] = self.sha256(path)
        config_identities = {}
        for relative in ("yabai/yabairc", "skhd/skhdrc", "aerospace/aerospace.toml"):
            path = self.paths.repo_root / relative
            self.verify_regular_file(path)
            config_identities[relative] = self.sha256(path)
        return {
            "schema": "wm-runtime-manifest-v1",
            "apps": {
                "primary_a": dataclasses.asdict(YABAI_SPEC),
                "primary_b": dataclasses.asdict(SKHD_SPEC),
                "fallback": dataclasses.asdict(AEROSPACE_SPEC),
            },
            "source_sha256": dict(SOURCE_SHA256),
            "previous_app_identities": {key: [dataclasses.asdict(spec) for spec in specs] for key, specs in PREVIOUS_APP_SPECS.items()},
            "previous_fallback_identities": [dataclasses.asdict(spec) for spec in PREVIOUS_FALLBACK_SPECS],
            "labels": list(LABELS),
            "expected_config": dict(EXPECTED_CONFIG),
            "config_sha256": config_identities,
            "plist_sha256": plist_identities,
            "module_sha256": self.sha256(pathlib.Path(__file__).resolve()),
        }

    def manifest_digest(self) -> str:
        encoded = json.dumps(self.runtime_manifest(), sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def app_xattr_digest(self, root: pathlib.Path) -> str:
        records: List[Dict[str, Any]] = []
        for path in [root] + sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
            relative = "." if path == root else path.relative_to(root).as_posix()
            attributes = []
            names_output = self.runner.run(("/usr/bin/xattr", str(path))).stdout
            for name in sorted(line for line in names_output.splitlines() if line):
                encoded = self.runner.run(("/usr/bin/xattr", "-px", name, str(path))).stdout
                normalized = "".join(encoded.split()).lower()
                if not re.fullmatch(r"[0-9a-f]*", normalized):
                    raise LifecycleError("an app extended attribute could not be inspected")
                attributes.append({"name": name, "sha256": hashlib.sha256(bytes.fromhex(normalized)).hexdigest()})
            records.append({"path": relative, "attributes": attributes})
        return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()

    def app_pair_xattr_digest(self) -> str:
        values = [
            self.app_xattr_digest(self.paths.app(YABAI_SPEC)),
            self.app_xattr_digest(self.paths.app(SKHD_SPEC)),
        ]
        return hashlib.sha256(json.dumps(values, separators=(",", ":")).encode("utf-8")).hexdigest()

    @staticmethod
    def app_pair_digest_from_identities(primary_a: Mapping[str, str], primary_b: Mapping[str, str]) -> str:
        records = [("primary_a", dict(primary_a)), ("primary_b", dict(primary_b))]
        return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()

    def app_pair_digest(self) -> str:
        primary_a = self.verify_app(self.paths.app(YABAI_SPEC), YABAI_SPEC)
        primary_b = self.verify_app(self.paths.app(SKHD_SPEC), SKHD_SPEC)
        return self.app_pair_digest_from_identities(primary_a, primary_b)

    def accessibility_attestation_path(self) -> pathlib.Path:
        return self.paths.state_root / "accessibility-attestation.json"

    def write_atomic_private_json(self, path: pathlib.Path, payload: Mapping[str, Any]) -> None:
        self.make_private_directory(path.parent)
        if path.exists() or path.is_symlink():
            metadata = self.verify_regular_file(path)
            if stat.S_IMODE(metadata.st_mode) != 0o600:
                raise LifecycleError("an existing private JSON file mode is invalid")
        temporary = path.parent / ("." + path.name + "-" + uuid.uuid4().hex)
        descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            write_all(descriptor, (json.dumps(payload, sort_keys=True, indent=2) + "\n").encode("utf-8"))
            os.fsync(descriptor)
        except BaseException:
            os.close(descriptor)
            if temporary.exists():
                temporary.unlink()
            raise
        else:
            os.close(descriptor)
        os.replace(str(temporary), str(path))
        descriptor = os.open(str(path.parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def attest_accessibility(self, supplied_manifest_digest: str) -> Dict[str, Any]:
        actual = self.manifest_digest()
        if supplied_manifest_digest != actual:
            raise LifecycleError("the Accessibility attestation manifest digest is stale")
        apps = self.verify_all_apps()
        pair_digest = self.app_pair_digest_from_identities(apps["primary_a"], apps["primary_b"])
        payload = {
            "schema": "wm-accessibility-attestation-v1",
            "manifest_sha256": actual,
            "app_pair_sha256": pair_digest,
            "operator_confirmation": "both exact app entries enabled in System Settings Accessibility",
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        self.write_atomic_private_json(self.accessibility_attestation_path(), payload)
        return {"deployment_state": "READY", "manifest_sha256": actual, "app_pair_sha256": payload["app_pair_sha256"]}

    def accessibility_attestation_matches(self, manifest_digest: str, app_pair_digest: str) -> bool:
        path = self.accessibility_attestation_path()
        metadata = self.verify_regular_file(path)
        if stat.S_IMODE(metadata.st_mode) != 0o600:
            raise LifecycleError("the Accessibility attestation mode is invalid")
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        return (
            data.get("schema") == "wm-accessibility-attestation-v1"
            and data.get("manifest_sha256") == manifest_digest
            and data.get("app_pair_sha256") == app_pair_digest
        )

    def require_accessibility_attestation(self) -> None:
        if not self.accessibility_attestation_matches(self.manifest_digest(), self.app_pair_digest()):
            raise LifecycleError("the Accessibility attestation does not bind the current deployment")

    def process_present(self, name: str) -> bool:
        if name not in ("yabai", "skhd", "AeroSpace"):
            raise LifecycleError("a process lane name is not allowed")
        result = self.runner.run(("/usr/bin/pgrep", "-q", "-U", self.paths.home.name, "-x", name), allowed=(0, 1))
        return result.returncode == 0

    def job_loaded(self, label: str) -> bool:
        if label not in LABELS:
            raise LifecycleError("a launch-job label is not allowed")
        result = self.runner.run(("/bin/launchctl", "print", self.domain + "/" + label), allowed=(0, 3, 113))
        return result.returncode == 0

    def verify_loaded_job(self, label: str, spec: AppSpec) -> None:
        if label not in LABELS:
            raise LifecycleError("a launch-job label is not allowed")
        result = self.runner.run(("/bin/launchctl", "print", self.domain + "/" + label), allowed=(0, 3, 113))
        if result.returncode != 0:
            raise LifecycleError("an expected launch job is absent")
        program_line = "program = " + str(self.paths.executable(spec))
        path_line = "path = " + str(self.paths.installed_plist(label))
        normalized = [line.strip() for line in result.stdout.splitlines()]
        if program_line not in normalized or path_line not in normalized:
            raise LifecycleError("a loaded launch job identity is not exact")

    def exact_process_image_present(self, executable: pathlib.Path) -> bool:
        expression = "^" + re.escape(str(executable)) + "( |$)"
        result = self.runner.run(("/usr/bin/pgrep", "-q", "-U", self.paths.home.name, "-f", expression), allowed=(0, 1))
        return result.returncode == 0

    def disabled_state(self) -> Dict[str, bool]:
        output = self.runner.run(("/bin/launchctl", "print-disabled", self.domain)).stdout
        states: Dict[str, bool] = {}
        for label in LABELS:
            match = re.search(r'"' + re.escape(label) + r'"\s*=>\s*(enabled|disabled|true|false)', output)
            if not match:
                states[label] = False
            else:
                states[label] = match.group(1) in ("disabled", "true")
        return states

    def assert_jobs_disabled(self) -> None:
        states = self.disabled_state()
        if not all(states.get(label, False) for label in LABELS):
            raise LifecycleError("a primary launch lane is not disabled")

    def wait_processes_absent(self, timeout: float = 12.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not any(self.process_present(name) for name in PROCESS_NAMES):
                return
            self.sleep(0.1)
        raise LifecycleError("a primary process lane did not stop")

    def wait_process_present(self, name: str, timeout: float = 15.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process_present(name):
                return
            self.sleep(0.1)
        raise LifecycleError("an expected process lane did not start")

    def stop_primaries(self) -> None:
        for label in LABELS:
            try:
                self.runner.run(("/bin/launchctl", "bootout", self.domain + "/" + label), allowed=range(0, 256))
            except LifecycleError:
                pass
        for label in LABELS:
            try:
                self.runner.run(("/bin/launchctl", "disable", self.domain + "/" + label), allowed=range(0, 256))
            except LifecycleError:
                pass
        self.wait_processes_absent()
        loaded = [self.job_loaded(label) for label in LABELS]
        if any(loaded):
            raise LifecycleError("a primary launch lane remains loaded")
        self.assert_jobs_disabled()

    def enable_and_bootstrap(self, label: str) -> None:
        self.runner.run(("/bin/launchctl", "enable", self.domain + "/" + label))
        states = self.disabled_state()
        if states.get(label, True):
            raise LifecycleError("a primary launch lane did not enable")
        self.runner.run(("/bin/launchctl", "bootstrap", self.domain, str(self.paths.installed_plist(label))))
        if not self.job_loaded(label):
            raise LifecycleError("a primary launch lane did not load")
        self.verify_loaded_job(label, YABAI_SPEC if label == "com.asmvik.yabai" else SKHD_SPEC)

    def resolve_required(self, path: pathlib.Path) -> pathlib.Path:
        try:
            return path.resolve(strict=True)
        except OSError as error:
            raise LifecycleError("a required configured target is missing") from error

    def link_matches(self, source: pathlib.Path, destination: pathlib.Path) -> bool:
        if not destination.is_symlink():
            return False
        try:
            return destination.resolve(strict=True) == self.resolve_required(source)
        except OSError as error:
            raise LifecycleError("a configured link target is missing") from error

    def safe_symlink(self, source: pathlib.Path, destination: pathlib.Path) -> None:
        source = self.resolve_required(source)
        parent = destination.parent
        self.require_owned_directory(parent)
        if destination.is_symlink():
            if self.link_matches(source, destination):
                return
            raise LifecycleError("an existing symbolic link has an unexpected target")
        if destination.exists():
            raise LifecycleError("an existing path blocks safe publication")
        temporary = parent / ("." + destination.name + ".wm-lifecycle-" + uuid.uuid4().hex)
        try:
            os.symlink(str(source), str(temporary))
            os.replace(str(temporary), str(destination))
            descriptor = os.open(str(parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            if temporary.is_symlink():
                temporary.unlink()
        if not self.link_matches(source, destination):
            raise LifecycleError("a symbolic link publication did not persist")

    def remove_legacy_logs(self) -> List[str]:
        removed: List[str] = []
        user = self.paths.home.name
        for prefix in ("yabai", "skhd"):
            for stream in ("out", "err"):
                path = self.paths.legacy_log_root / (prefix + "_" + user + "." + stream + ".log")
                try:
                    metadata = os.lstat(str(path))
                except FileNotFoundError:
                    continue
                if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != self.uid or metadata.st_nlink != 1:
                    raise LifecycleError("a legacy log path has an unsafe identity")
                path.unlink()
                removed.append(prefix + "-" + stream)
        return removed

    def assert_legacy_logs_absent(self) -> None:
        user = self.paths.home.name
        for prefix in ("yabai", "skhd"):
            for stream in ("out", "err"):
                path = self.paths.legacy_log_root / (prefix + "_" + user + "." + stream + ".log")
                if path.exists() or path.is_symlink():
                    raise LifecycleError("a legacy shared log path remains present")

    def support_journal_path(self) -> pathlib.Path:
        return self.paths.state_root / "support-journal.json"

    def write_support_journal(self, data: Mapping[str, Any]) -> None:
        self.write_atomic_private_json(self.support_journal_path(), data)

    def remove_support_journal(self) -> None:
        path = self.support_journal_path()
        if path.exists():
            self.verify_regular_file(path)
            path.unlink()
            descriptor = os.open(str(path.parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)

    def recover_support(self) -> Dict[str, Any]:
        path = self.support_journal_path()
        if not path.exists():
            return {"support_recovery": "not-needed"}
        metadata = self.verify_regular_file(path)
        if stat.S_IMODE(metadata.st_mode) != 0o600:
            raise LifecycleError("the support recovery journal mode is invalid")
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        list_keys = ("intent_links", "intent_files", "intent_directories", "created_links", "created_files", "created_directories")
        if data.get("schema") != "wm-support-transaction-v1" or any(not isinstance(data.get(key), list) for key in list_keys):
            raise LifecycleError("the support recovery journal is invalid")
        allowed_phases = {
            "intent-stop-primary", "primary-off", "intent-create-directory", "created-directory",
            "intent-create-file", "created-file", "intent-create-link", "created-link",
            "intent-remove-legacy-logs", "legacy-logs-removed", "committed",
        }
        phase = data.get("phase")
        if phase not in allowed_phases:
            raise LifecycleError("the support recovery journal phase is invalid")
        self.stop_primaries()
        if phase == "committed":
            if data.get("manifest_sha256") != self.manifest_digest() or data.get("app_pair_sha256") != self.app_pair_digest():
                raise LifecycleError("the committed support journal identity is invalid")
            self.require_owned_directory(self.paths.config_root)
            for directory in (self.paths.home / "Library/Logs/yabai", self.paths.home / "Library/Logs/skhd"):
                self.require_owned_directory(directory, 0o700)
            for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
                self.validate_plist(label, self.paths.installed_plist(label), installed=True)
            self.verify_links()
            self.assert_legacy_logs_absent()
            self.remove_support_journal()
            return {"support_recovery": "committed-support-retained"}

        def journaled(kind: str) -> List[str]:
            return list(dict.fromkeys(data["intent_" + kind] + data["created_" + kind]))

        expected_destinations = {str(destination) for _source, destination in self.expected_links()}
        link_records: Dict[str, Mapping[str, Any]] = {}
        for value in data["intent_links"] + data["created_links"]:
            if not isinstance(value, dict) or set(value) != {"destination", "source"} or not isinstance(value["destination"], str) or not isinstance(value["source"], str):
                raise LifecycleError("the support recovery journal contains an invalid link record")
            link_records.setdefault(value["destination"], value)
        for record in reversed(list(link_records.values())):
            raw_destination = record["destination"]
            destination = pathlib.Path(raw_destination)
            if raw_destination not in expected_destinations:
                raise LifecycleError("the support recovery journal contains an unknown path")
            if destination.is_symlink() and os.readlink(str(destination)) == record["source"]:
                destination.unlink()
            elif destination.exists() or destination.is_symlink():
                raise LifecycleError("support recovery found an unknown object")
        expected_files = {str(self.paths.installed_plist(label)): label for label in ("com.asmvik.yabai", "com.koekeishiya.skhd")}
        for raw_file in reversed(journaled("files")):
            file_path = pathlib.Path(raw_file)
            label = expected_files.get(raw_file)
            if label is None:
                raise LifecycleError("the support recovery journal contains an unknown file")
            if file_path.exists() or file_path.is_symlink():
                self.validate_plist(label, file_path, installed=True)
                file_path.unlink()
        for raw_directory in reversed(journaled("directories")):
            directory = pathlib.Path(raw_directory)
            allowed = {
                self.paths.config_root,
                self.paths.home / "Library/Logs/yabai",
                self.paths.home / "Library/Logs/skhd",
            }
            if directory not in allowed:
                raise LifecycleError("the support recovery journal contains an unknown directory")
            if directory.exists():
                self.require_owned_directory(directory, 0o700)
                try:
                    directory.rmdir()
                except OSError as error:
                    raise LifecycleError("a support recovery directory is not empty") from error
        self.remove_support_journal()
        return {"support_recovery": "created-support-removed"}

    def validate_plist(self, label: str, path: Optional[pathlib.Path] = None, installed: bool = False) -> None:
        source = self.paths.plist(label)
        path = path or source
        metadata = self.verify_regular_file(path)
        if installed:
            if stat.S_IMODE(metadata.st_mode) != 0o600 or self.sha256(path) != self.sha256(source):
                raise LifecycleError("an installed launch-agent file identity is invalid")
        with path.open("rb") as handle:
            data = plistlib.load(handle)
        spec = YABAI_SPEC if label == "com.asmvik.yabai" else SKHD_SPEC
        expected_log = self.paths.home / "Library/Logs" / spec.executable
        if data.get("Label") != label:
            raise LifecycleError("a launch-agent label is invalid")
        if data.get("ProgramArguments") != [str(self.paths.executable(spec))]:
            raise LifecycleError("a launch-agent executable is invalid")
        if data.get("StandardOutPath") != str(expected_log / (spec.executable + ".out.log")):
            raise LifecycleError("a launch-agent standard output path is invalid")
        if data.get("StandardErrorPath") != str(expected_log / (spec.executable + ".err.log")):
            raise LifecycleError("a launch-agent standard error path is invalid")
        if data.get("Umask") != 0o77:
            raise LifecycleError("a launch-agent umask is invalid")

    def install_plist(self, label: str) -> bool:
        source = self.paths.plist(label)
        destination = self.paths.installed_plist(label)
        self.validate_plist(label, source, installed=False)
        if destination.exists() or destination.is_symlink():
            self.validate_plist(label, destination, installed=True)
            return False
        temporary = destination.parent / ("." + destination.name + ".wm-lifecycle-" + uuid.uuid4().hex)
        descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with source.open("rb") as handle:
                while True:
                    block = handle.read(1024 * 1024)
                    if not block:
                        break
                    write_all(descriptor, block)
            os.fsync(descriptor)
        except BaseException:
            os.close(descriptor)
            if temporary.exists():
                temporary.unlink()
            raise
        else:
            os.close(descriptor)
        os.replace(str(temporary), str(destination))
        parent_descriptor = os.open(str(destination.parent), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
        self.validate_plist(label, destination, installed=True)
        return True

    def expected_links(self) -> List[Tuple[pathlib.Path, pathlib.Path]]:
        return [
            (self.paths.repo_root / "yabai", self.paths.config_root / "yabai"),
            (self.paths.repo_root / "skhd", self.paths.config_root / "skhd"),
            (self.paths.repo_root / "aerospace", self.paths.config_root / "aerospace"),
        ]

    def verify_links(self) -> None:
        for source, destination in self.expected_links():
            if not self.link_matches(source, destination):
                raise LifecycleError("a configured link identity is invalid")
        for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
            self.validate_plist(label, self.paths.installed_plist(label), installed=True)

    def preflight_support_adoption(self) -> None:
        if self.support_journal_path().exists():
            raise LifecycleError("preflight: support recovery is required")
        self.require_owned_directory(self.paths.app_root)
        self.require_owned_directory(self.paths.launch_agents)
        self.require_owned_directory(self.paths.home / "Library/Logs")
        if self.paths.config_root.exists() or self.paths.config_root.is_symlink():
            self.require_owned_directory(self.paths.config_root)
            if stat.S_IMODE(os.lstat(str(self.paths.config_root)).st_mode) & 0o022:
                raise LifecycleError("preflight: the config root is group- or world-writable")
        for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
            self.validate_plist(label, self.paths.plist(label), installed=False)
            destination = self.paths.installed_plist(label)
            if destination.exists() or destination.is_symlink():
                if destination.is_symlink():
                    raise LifecycleError("preflight: remove the prior launch-agent symlink before adoption")
                self.validate_plist(label, destination, installed=True)
        for source, destination in self.expected_links():
            source = self.resolve_required(source)
            if destination.is_symlink():
                if not self.link_matches(source, destination):
                    raise LifecycleError("preflight: a configured link has an unexpected target")
            elif destination.exists():
                if destination.parent == self.paths.config_root:
                    raise LifecycleError("preflight: remove the prior real config directory before adoption")
                raise LifecycleError("preflight: an existing object blocks safe support publication")
        for executable in ("yabai", "skhd"):
            log_directory = self.paths.home / "Library/Logs" / executable
            if log_directory.exists() or log_directory.is_symlink():
                self.require_owned_directory(log_directory, 0o700)
        user = self.paths.home.name
        for prefix in ("yabai", "skhd"):
            for stream in ("out", "err"):
                path = self.paths.legacy_log_root / (prefix + "_" + user + "." + stream + ".log")
                if path.exists() or path.is_symlink():
                    metadata = os.lstat(str(path))
                    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != self.uid or metadata.st_nlink != 1:
                        raise LifecycleError("preflight: a legacy log object is unsafe")
        if any(self.process_present(name) for name in PROCESS_NAMES) or any(self.job_loaded(label) for label in LABELS):
            raise LifecycleError("preflight: stop the prior primary window-manager lanes before adoption")

    def ensure_config_root(self) -> bool:
        if self.paths.config_root.exists() or self.paths.config_root.is_symlink():
            self.require_owned_directory(self.paths.config_root)
            if stat.S_IMODE(os.lstat(str(self.paths.config_root)).st_mode) & 0o022:
                raise LifecycleError("the config root is group- or world-writable")
            return False
        os.mkdir(str(self.paths.config_root), 0o700)
        self.require_owned_directory(self.paths.config_root, 0o700)
        return True

    def configure(self) -> Dict[str, Any]:
        if self.support_journal_path().exists():
            raise LifecycleError("support recovery is required before preparation")
        apps = self.verify_all_apps()
        before_pair = self.app_pair_digest_from_identities(apps["primary_a"], apps["primary_b"])
        before_xattrs = self.app_pair_xattr_digest()
        self.preflight_support_adoption()
        self.require_owned_directory(self.paths.app_root)
        self.require_owned_directory(self.paths.launch_agents)
        self.require_owned_directory(self.paths.home / "Library/Logs")
        for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
            self.validate_plist(label)
        directories = [
            self.paths.home / "Library/Logs/yabai",
            self.paths.home / "Library/Logs/skhd",
        ]
        journal: Dict[str, Any] = {
            "schema": "wm-support-transaction-v1",
            "phase": "intent-stop-primary",
            "manifest_sha256": self.manifest_digest(),
            "app_pair_sha256": before_pair,
            "intent_directories": [],
            "intent_links": [],
            "intent_files": [],
            "created_directories": [],
            "created_links": [],
            "created_files": [],
        }
        self.write_support_journal(journal)
        self.stop_primaries()
        journal["phase"] = "primary-off"
        self.write_support_journal(journal)
        if self.app_pair_digest() != before_pair or self.app_pair_xattr_digest() != before_xattrs:
            raise LifecycleError("the adopted app pair changed before support mutation")
        config_needed = not self.paths.config_root.exists()
        if config_needed:
            journal["intent_directories"].append(str(self.paths.config_root))
            journal["phase"] = "intent-create-directory"
            self.write_support_journal(journal)
        if self.ensure_config_root():
            self.support_failpoint("after-create-directory")
            journal["created_directories"].append(str(self.paths.config_root))
            journal["phase"] = "created-directory"
            self.write_support_journal(journal)
        for directory in directories:
            existed = directory.exists()
            if not existed:
                journal["intent_directories"].append(str(directory))
                journal["phase"] = "intent-create-directory"
                self.write_support_journal(journal)
            self.make_private_directory(directory)
            if not existed:
                self.support_failpoint("after-create-directory")
                journal["created_directories"].append(str(directory))
                journal["phase"] = "created-directory"
                self.write_support_journal(journal)
        self.make_private_directory(self.paths.state_root / "tmp")
        self.make_private_directory(self.paths.state_root / "receipts")
        for label in ("com.asmvik.yabai", "com.koekeishiya.skhd"):
            destination = self.paths.installed_plist(label)
            needed = not destination.exists()
            if needed:
                journal["intent_files"].append(str(destination))
                journal["phase"] = "intent-create-file"
                self.write_support_journal(journal)
            if self.install_plist(label):
                self.support_failpoint("after-create-file")
                journal["created_files"].append(str(destination))
                journal["phase"] = "created-file"
                self.write_support_journal(journal)
        for source, destination in self.expected_links():
            existed = destination.is_symlink()
            if not existed:
                link_record = {"destination": str(destination), "source": str(self.resolve_required(source))}
                journal["intent_links"].append(link_record)
                journal["phase"] = "intent-create-link"
                self.write_support_journal(journal)
            self.safe_symlink(source, destination)
            if not existed:
                self.support_failpoint("after-create-link")
                journal["created_links"].append(link_record)
                journal["phase"] = "created-link"
                self.write_support_journal(journal)
        journal["phase"] = "intent-remove-legacy-logs"
        self.write_support_journal(journal)
        removed = self.remove_legacy_logs()
        self.assert_legacy_logs_absent()
        journal["phase"] = "legacy-logs-removed"
        journal["legacy_log_classes_removed"] = sorted(removed)
        self.write_support_journal(journal)
        self.verify_links()
        self.stop_primaries()
        after_pair = self.app_pair_digest()
        if after_pair != before_pair or self.app_pair_xattr_digest() != before_xattrs:
            raise LifecycleError("the adopted app pair changed during support preparation")
        journal["phase"] = "committed"
        self.write_support_journal(journal)
        self.support_failpoint("after-support-commit")
        self.remove_support_journal()
        return {"apps": apps, "legacy_log_classes_removed": sorted(removed), "configured_link_count": len(self.expected_links()), "deployment_state": "APPROVAL_REQUIRED", "manifest_sha256": self.manifest_digest(), "app_pair_sha256": after_pair}

    def query_yabai(self, *arguments: str) -> str:
        result = self.runner.run(tuple([str(self.paths.executable(YABAI_SPEC))] + list(arguments)), timeout=1)
        return result.stdout.strip()

    def read_yabai_runtime_once(self) -> Dict[str, Any]:
        for key, expected in EXPECTED_CONFIG.items():
            actual = self.query_yabai("-m", "config", key)
            if actual != expected:
                raise LifecycleError("a yabai runtime setting is not exact")
        try:
            spaces = json.loads(self.query_yabai("-m", "query", "--spaces"))
            rules = json.loads(self.query_yabai("-m", "rule", "--list"))
        except (ValueError, TypeError) as error:
            raise LifecycleError("a yabai runtime query is invalid") from error
        if not isinstance(spaces, list):
            raise LifecycleError("the native Space topology is invalid")
        primary_indices = sorted(
            item.get("index") for item in spaces
            if isinstance(item, dict) and item.get("display") == PRIMARY_DISPLAY_INDEX
        )
        if primary_indices != list(EXPECTED_PRIMARY_SPACE_INDICES):
            raise LifecycleError("the primary display does not own native Spaces one through nine")
        expected_rules = {
            "raycast": {"app": "^Raycast$", "manage": 0},
            "system-settings": {"app": "^System Settings$", "manage": 0},
        }
        by_label = {item.get("label"): item for item in rules if isinstance(item, dict)} if isinstance(rules, list) else {}
        for label, expected in expected_rules.items():
            item = by_label.get(label)
            if not isinstance(item, dict) or item.get("app") != expected["app"] or item.get("manage") != expected["manage"]:
                raise LifecycleError("a yabai runtime rule is not exact")
        return {"native_space_count": len(primary_indices), "external_space_count": len(spaces) - len(primary_indices), "runtime_setting_count": len(EXPECTED_CONFIG), "runtime_rule_count": len(expected_rules)}

    def verify_yabai_runtime(self, attempts: int = 40) -> Dict[str, Any]:
        self.wait_process_present("yabai")
        for attempt in range(attempts):
            try:
                return self.read_yabai_runtime_once()
            except LifecycleError:
                if attempt + 1 == attempts:
                    break
                self.sleep(0.5)
        raise LifecycleError("yabai did not converge to the reviewed runtime contract")

    def start_fallback(self) -> None:
        self.verify_approved_fallback()
        self.runner.run(("/usr/bin/open", str(self.paths.app(AEROSPACE_SPEC))))
        self.wait_process_present("AeroSpace")
        if not self.exact_process_image_present(self.paths.executable(AEROSPACE_SPEC)):
            raise LifecycleError("the fallback process image is not exact")

    def rollback(self, start_fallback: bool = True) -> Dict[str, Any]:
        self.stop_primaries()
        if start_fallback:
            self.start_fallback()
        return {"anonymous_primary_active_lane_count": 0, "fallback_active": self.process_present("AeroSpace") if start_fallback else False}

    def activate(self) -> Dict[str, Any]:
        apps = self.verify_all_apps()
        self.verify_links()
        initial_pair = self.app_pair_digest_from_identities(apps["primary_a"], apps["primary_b"])
        if not self.accessibility_attestation_matches(self.manifest_digest(), initial_pair):
            raise LifecycleError("the Accessibility attestation does not bind the current deployment")
        if self.process_present("AeroSpace"):
            if not self.exact_process_image_present(self.paths.executable(AEROSPACE_SPEC)):
                raise LifecycleError("the active fallback process image is not exact")
            raise LifecycleError("the attended fallback exit is required before primary activation")
        self.stop_primaries()
        try:
            self.enable_and_bootstrap("com.asmvik.yabai")
            runtime = self.verify_yabai_runtime()
            self.enable_and_bootstrap("com.koekeishiya.skhd")
            self.wait_process_present("skhd")
            self.verify_loaded_job("com.asmvik.yabai", YABAI_SPEC)
            self.verify_loaded_job("com.koekeishiya.skhd", SKHD_SPEC)
            if self.job_loaded("com.asmvik.skhd"):
                raise LifecycleError("the alternate primary-b lane is loaded")
            states = self.disabled_state()
            if not states.get("com.asmvik.skhd", False):
                raise LifecycleError("the alternate primary-b lane is not disabled")
        except BaseException as activation_error:
            try:
                self.rollback(start_fallback=True)
            except Exception as rollback_error:
                raise LifecycleError("activation failed and rollback convergence failed; run status, then rollback or recover") from rollback_error
            raise LifecycleError("activation failed; primary shutdown and exact fallback startup converged: " + str(activation_error)) from activation_error
        return {
            "anonymous_primary_active_lane_count": 2,
            "fallback_active": False,
            "runtime": runtime,
            "manifest_sha256": self.manifest_digest(),
            "app_pair_sha256": self.app_pair_digest(),
            "physical_hotkey_acceptance": "PENDING",
        }

    def accept_runtime(self, activation_receipt_sha256: str) -> Dict[str, Any]:
        receipts = self.paths.state_root / "receipts"
        self.require_owned_directory(receipts, 0o700)
        if not re.fullmatch(r"[0-9a-f]{64}", activation_receipt_sha256):
            raise LifecycleError("the activation receipt digest is invalid")
        matches = list(receipts.glob("*-activate-" + activation_receipt_sha256 + ".json"))
        if len(matches) != 1:
            raise LifecycleError("the activation receipt is unavailable or ambiguous")
        matched = matches[0]
        metadata = self.verify_regular_file(matched)
        if stat.S_IMODE(metadata.st_mode) != 0o600 or self.sha256(matched) != activation_receipt_sha256:
            raise LifecycleError("the activation receipt identity is invalid")
        with matched.open("r", encoding="utf-8") as handle:
            receipt = json.load(handle)
        data = receipt.get("data") if isinstance(receipt, dict) else None
        if receipt.get("action") != "activate" or receipt.get("status") != "PASS" or not isinstance(data, dict):
            raise LifecycleError("the activation receipt is invalid")
        if data.get("manifest_sha256") != self.manifest_digest() or data.get("app_pair_sha256") != self.app_pair_digest():
            raise LifecycleError("the activation receipt is stale")
        runtime = self.verify_yabai_runtime()
        if not self.process_present("skhd") or self.process_present("AeroSpace"):
            raise LifecycleError("the runtime lane state is not acceptable")
        payload = {
            "schema": "wm-runtime-acceptance-v1",
            "activation_receipt_sha256": activation_receipt_sha256,
            "manifest_sha256": self.manifest_digest(),
            "app_pair_sha256": self.app_pair_digest(),
            "operator_confirmation": "physical directional, Space, and send-and-follow hotkeys passed",
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        self.write_atomic_private_json(self.paths.state_root / "runtime-acceptance.json", payload)
        return {"deployment_state": "RUNTIME_ACCEPTED", "runtime": runtime, "physical_hotkey_acceptance": "PASS"}

    def status(self) -> Dict[str, Any]:
        transaction_state = "CLEAN"
        app_pending = (self.paths.app_root / ".wm-lifecycle-app-pair-transaction").exists()
        support_pending = self.support_journal_path().exists()
        if app_pending and support_pending:
            transaction_state = "CONFLICTED_RECOVERY"
        elif app_pending:
            transaction_state = "APP_RECOVERY_REQUIRED"
        elif support_pending:
            transaction_state = "SUPPORT_RECOVERY_REQUIRED"
        app_states: Dict[str, bool] = {}
        app_identities: Dict[str, Dict[str, str]] = {}
        identity_error = False
        for key, spec in (("primary_a", YABAI_SPEC), ("primary_b", SKHD_SPEC), ("fallback", AEROSPACE_SPEC)):
            try:
                app_identities[key] = self.verify_approved_fallback() if key == "fallback" else self.verify_app(self.paths.app(spec), spec)
                app_states[key] = True
            except LifecycleError:
                app_states[key] = False
                identity_error = True
        manifest_digest = self.manifest_digest()
        pair_digest = None
        if "primary_a" in app_identities and "primary_b" in app_identities:
            pair_digest = self.app_pair_digest_from_identities(app_identities["primary_a"], app_identities["primary_b"])
        try:
            processes = {name: self.process_present(name) for name in ("yabai", "skhd", "AeroSpace")}
            jobs = {label: self.job_loaded(label) for label in LABELS}
            disabled = self.disabled_state()
            inspections_safe = True
        except LifecycleError:
            processes = {name: False for name in ("yabai", "skhd", "AeroSpace")}
            jobs = {label: False for label in LABELS}
            disabled = {label: False for label in LABELS}
            inspections_safe = False
        primary_off = inspections_safe and not processes["yabai"] and not processes["skhd"] and not any(jobs.values()) and all(disabled.values())
        if not inspections_safe:
            lane_state = "UNKNOWN_UNSAFE"
        elif primary_off and processes["AeroSpace"] and app_states.get("fallback", False):
            lane_state = "FALLBACK_ACTIVE"
        elif primary_off and not processes["AeroSpace"] and app_states.get("fallback", False):
            lane_state = "PRIMARY_OFF"
        elif primary_off and not app_states.get("fallback", False):
            lane_state = "PRIMARY_OFF_FALLBACK_UNAVAILABLE"
        elif (
            processes["yabai"]
            and processes["skhd"]
            and not processes["AeroSpace"]
            and jobs.get("com.asmvik.yabai", False)
            and jobs.get("com.koekeishiya.skhd", False)
            and not jobs.get("com.asmvik.skhd", False)
            and not disabled.get("com.asmvik.yabai", True)
            and not disabled.get("com.koekeishiya.skhd", True)
            and disabled.get("com.asmvik.skhd", False)
        ):
            try:
                self.verify_loaded_job("com.asmvik.yabai", YABAI_SPEC)
                self.verify_loaded_job("com.koekeishiya.skhd", SKHD_SPEC)
                self.read_yabai_runtime_once()
                lane_state = "PRIMARY_ACTIVE"
            except LifecycleError:
                lane_state = "PARTIAL_UNSAFE"
        else:
            lane_state = "PARTIAL_UNSAFE"
        support_ready = False
        try:
            self.verify_links()
            support_ready = True
        except LifecycleError:
            support_ready = False
        attested = False
        if pair_digest is not None:
            try:
                attested = self.accessibility_attestation_matches(manifest_digest, pair_digest)
            except (LifecycleError, OSError, ValueError, json.JSONDecodeError):
                attested = False
        runtime_accepted = False
        runtime_path = self.paths.state_root / "runtime-acceptance.json"
        if runtime_path.exists():
            try:
                metadata = self.verify_regular_file(runtime_path)
                if stat.S_IMODE(metadata.st_mode) != 0o600:
                    raise LifecycleError("the runtime acceptance mode is invalid")
                with runtime_path.open("r", encoding="utf-8") as handle:
                    runtime_data = json.load(handle)
                runtime_accepted = (
                    runtime_data.get("schema") == "wm-runtime-acceptance-v1"
                    and runtime_data.get("manifest_sha256") == manifest_digest
                    and pair_digest is not None
                    and runtime_data.get("app_pair_sha256") == pair_digest
                    and lane_state == "PRIMARY_ACTIVE"
                )
            except (LifecycleError, OSError, ValueError, json.JSONDecodeError):
                runtime_accepted = False
        if identity_error:
            deployment_state = "IDENTITY_INVALID"
        elif not support_ready or transaction_state != "CLEAN":
            deployment_state = "SUPPORT_NOT_READY"
        elif runtime_accepted:
            deployment_state = "RUNTIME_ACCEPTED"
        elif not attested:
            deployment_state = "APPROVAL_REQUIRED"
        else:
            deployment_state = "READY"
        return {
            "transaction_state": transaction_state,
            "lane_state": lane_state,
            "deployment_state": deployment_state,
            "apps_exact": app_states,
            "anonymous_primary_process_lane_count": int(processes["yabai"]) + int(processes["skhd"]),
            "anonymous_loaded_primary_job_count": sum(1 for value in jobs.values() if value),
            "fallback_active": processes["AeroSpace"],
            "disabled_primary_job_count": sum(1 for value in disabled.values() if value),
        }

    def write_receipt(self, action: str, data: Mapping[str, Any]) -> pathlib.Path:
        self.make_private_directory(self.paths.state_root)
        receipts = self.paths.state_root / "receipts"
        self.make_private_directory(receipts)
        payload = {
            "schema": "wm-lifecycle-v1-receipt",
            "action": action,
            "status": "PASS",
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "data": data,
        }
        content = (json.dumps(payload, sort_keys=True, indent=2) + "\n").encode("utf-8")
        content_digest = hashlib.sha256(content).hexdigest()
        path = receipts / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + action + "-" + content_digest + ".json")
        descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            write_all(descriptor, content)
            os.fsync(descriptor)
        except BaseException:
            os.close(descriptor)
            if path.exists():
                path.unlink()
            raise
        else:
            os.close(descriptor)
        parent_descriptor = os.open(str(receipts), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
        return path


def reduced_result(action: str, receipt: pathlib.Path, data: Mapping[str, Any]) -> Dict[str, Any]:
    return {
        "action": action,
        "status": "PASS",
        "receipt": str(receipt),
        "receipt_sha256": Lifecycle.sha256(receipt),
        "anonymous_primary_active_lane_count": data.get("anonymous_primary_active_lane_count"),
        "physical_hotkey_acceptance": data.get("physical_hotkey_acceptance"),
        "manifest_sha256": data.get("manifest_sha256"),
        "deployment_state": data.get("deployment_state"),
        "transaction_state": data.get("transaction_state"),
        "lane_state": data.get("lane_state"),
    }


class PairPublisher:
    """Crash-recoverable two-app publication with intent records before each rename."""

    def __init__(self, lifecycle: Lifecycle, failpoint: Optional[Callable[[str], None]] = None) -> None:
        self.lifecycle = lifecycle
        self.paths = lifecycle.paths
        self.failpoint = failpoint or (lambda _name: None)
        self.transaction = self.paths.app_root / ".wm-lifecycle-app-pair-transaction"
        self.manifest = self.transaction / "manifest.json"
        self.lock_path = self.paths.state_root / "pair-publication.lock"

    def tree_digest(self, root: pathlib.Path) -> str:
        records: List[Dict[str, Any]] = []
        for path in [root] + sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
            metadata = os.lstat(str(path))
            relative = "." if path == root else path.relative_to(root).as_posix()
            if stat.S_ISDIR(metadata.st_mode):
                kind = "dir"
                digest = None
            elif stat.S_ISREG(metadata.st_mode):
                if metadata.st_nlink != 1:
                    raise LifecycleError("an app-pair tree file is multiply linked")
                kind = "file"
                digest = self.lifecycle.sha256(path)
            else:
                raise LifecycleError("an app-pair tree node type is unsafe")
            if metadata.st_uid != self.lifecycle.uid or stat.S_IMODE(metadata.st_mode) & 0o022:
                raise LifecycleError("an app-pair tree identity is unsafe")
            records.append({"path": relative, "kind": kind, "mode": stat.S_IMODE(metadata.st_mode), "size": metadata.st_size, "sha256": digest})
        return hashlib.sha256(json.dumps(records, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()

    def write_manifest(self, data: Mapping[str, Any]) -> None:
        if self.manifest.exists() or self.manifest.is_symlink():
            metadata = self.lifecycle.verify_regular_file(self.manifest)
            if stat.S_IMODE(metadata.st_mode) != 0o600:
                raise LifecycleError("an app-pair manifest mode is invalid")
        temporary = self.transaction / (".manifest-" + uuid.uuid4().hex)
        descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            content = (json.dumps(data, sort_keys=True, indent=2) + "\n").encode("utf-8")
            write_all(descriptor, content)
            os.fsync(descriptor)
        except BaseException:
            os.close(descriptor)
            if temporary.exists():
                temporary.unlink()
            raise
        else:
            os.close(descriptor)
        os.replace(str(temporary), str(self.manifest))
        descriptor = os.open(str(self.transaction), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def read_manifest(self) -> Dict[str, Any]:
        metadata = self.lifecycle.verify_regular_file(self.manifest)
        if stat.S_IMODE(metadata.st_mode) != 0o600:
            raise LifecycleError("an app-pair manifest mode is invalid")
        with self.manifest.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        if data.get("schema") != "wm-app-pair-transaction-v1":
            raise LifecycleError("an app-pair recovery manifest is invalid")
        return data

    def cleanup_transaction(self) -> None:
        if not self.transaction.exists():
            return
        self.lifecycle.require_owned_directory(self.transaction, 0o700)
        shutil.rmtree(str(self.transaction))
        descriptor = os.open(str(self.paths.app_root), os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def recover(self) -> Dict[str, Any]:
        if not self.transaction.exists():
            return {"recovery": "not-needed"}
        self.lifecycle.require_owned_directory(self.transaction, 0o700)
        data = self.read_manifest()
        items = (("yabai", YABAI_SPEC), ("skhd", SKHD_SPEC))
        if data.get("phase") == "committed":
            for _key, spec in items:
                self.lifecycle.verify_app(self.paths.app(spec), spec)
            self.cleanup_transaction()
            return {"recovery": "committed-cleanup"}
        for key, spec in items:
            destination = self.paths.app(spec)
            backup = self.transaction / ("old-" + spec.name)
            discard = self.transaction / ("discard-" + spec.name)
            item = data.get("items", {}).get(key)
            if not isinstance(item, dict):
                raise LifecycleError("an app-pair recovery item is invalid")
            old_present = item.get("old_present") is True
            old_digest = item.get("old_digest")
            if old_present:
                if backup.exists():
                    if self.tree_digest(backup) != old_digest:
                        raise LifecycleError("an app-pair backup identity changed")
                    if destination.exists():
                        if not item.get("install_intent") or self.tree_digest(destination) != item.get("new_digest"):
                            raise LifecycleError("app-pair recovery found an unknown destination object")
                        if discard.exists():
                            raise LifecycleError("an app-pair discard path is occupied")
                        os.replace(str(destination), str(discard))
                    os.replace(str(backup), str(destination))
                    if self.tree_digest(destination) != old_digest:
                        raise LifecycleError("an app-pair restore identity changed")
                elif not destination.exists() or self.tree_digest(destination) != old_digest:
                    raise LifecycleError("an app-pair backup is unavailable")
            else:
                if destination.exists():
                    if not item.get("install_intent") or self.tree_digest(destination) != item.get("new_digest"):
                        raise LifecycleError("app-pair recovery found an unknown destination object")
                    self.lifecycle.verify_app(destination, spec)
                    if discard.exists():
                        raise LifecycleError("an app-pair discard path is occupied")
                    os.replace(str(destination), str(discard))
        data["phase"] = "recovered"
        self.write_manifest(data)
        self.cleanup_transaction()
        return {"recovery": "prior-pair-restored"}

    @contextlib.contextmanager
    def lock(self) -> Iterable[None]:
        self.lifecycle.make_private_directory(self.paths.state_root)
        descriptor = os.open(str(self.lock_path), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            metadata = os.fstat(descriptor)
            if metadata.st_uid != self.lifecycle.uid or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1:
                raise LifecycleError("the app-pair lock identity is unsafe")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise LifecycleError("another app-pair publication is active") from error
            yield
        finally:
            os.close(descriptor)

    def verify_known_existing_app(self, key: str, path: pathlib.Path, current: AppSpec) -> None:
        for spec in (current,) + PREVIOUS_APP_SPECS.get(key, ()):
            try:
                self.lifecycle.verify_app(path, spec)
                return
            except LifecycleError:
                continue
        raise LifecycleError("an existing app object is not an approved prior identity")

    def publish(self, source_root: pathlib.Path) -> Dict[str, Any]:
        if not source_root.is_absolute():
            raise LifecycleError("the candidate source root is not absolute")
        self.lifecycle.require_owned_directory(source_root, 0o700)
        source_root = source_root.resolve(strict=True)
        source_apps = {"yabai": source_root / YABAI_SPEC.name, "skhd": source_root / SKHD_SPEC.name}
        self.lifecycle.verify_app(source_apps["yabai"], YABAI_SPEC)
        self.lifecycle.verify_app(source_apps["skhd"], SKHD_SPEC)
        self.lifecycle.stop_primaries()
        with self.lock():
            if self.transaction.exists():
                raise LifecycleError("app-pair recovery is required before publication")
            items: Dict[str, Dict[str, Any]] = {}
            for key, spec in (("yabai", YABAI_SPEC), ("skhd", SKHD_SPEC)):
                destination = self.paths.app(spec)
                if destination.exists():
                    self.verify_known_existing_app(key, destination, spec)
                items[key] = {
                    "old_present": destination.exists(),
                    "old_digest": self.tree_digest(destination) if destination.exists() else None,
                    "new_digest": self.tree_digest(source_apps[key]),
                    "backup_intent": False,
                    "backed_up": False,
                    "install_intent": False,
                    "installed": False,
                }
            self.transaction.mkdir(mode=0o700)
            self.lifecycle.require_owned_directory(self.transaction, 0o700)
            data: Dict[str, Any] = {"schema": "wm-app-pair-transaction-v1", "phase": "intent-stage", "items": items}
            try:
                self.write_manifest(data)
            except BaseException:
                self.cleanup_transaction()
                raise
            previous_handlers: Dict[int, Any] = {}

            def interrupted(_signal: int, _frame: Any) -> None:
                raise KeyboardInterrupt()

            for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                previous_handlers[signal_number] = signal.getsignal(signal_number)
                signal.signal(signal_number, interrupted)
            try:
                for key, spec in (("yabai", YABAI_SPEC), ("skhd", SKHD_SPEC)):
                    data["phase"] = "intent-stage-" + key
                    self.write_manifest(data)
                    self.failpoint(data["phase"])
                    staged = self.transaction / ("new-" + spec.name)
                    shutil.copytree(str(source_apps[key]), str(staged), copy_function=shutil.copy2)
                    self.lifecycle.verify_app(staged, spec)
                    data["phase"] = "staged-" + key
                    self.write_manifest(data)
                    self.failpoint(data["phase"])
                for key, spec in (("yabai", YABAI_SPEC), ("skhd", SKHD_SPEC)):
                    destination = self.paths.app(spec)
                    backup = self.transaction / ("old-" + spec.name)
                    if items[key]["old_present"]:
                        items[key]["backup_intent"] = True
                        data["phase"] = "intent-backup-" + key
                        self.write_manifest(data)
                        self.failpoint(data["phase"])
                        os.replace(str(destination), str(backup))
                        items[key]["backed_up"] = True
                        data["phase"] = "backed-up-" + key
                        self.write_manifest(data)
                        self.failpoint(data["phase"])
                for key, spec in (("yabai", YABAI_SPEC), ("skhd", SKHD_SPEC)):
                    destination = self.paths.app(spec)
                    staged = self.transaction / ("new-" + spec.name)
                    items[key]["install_intent"] = True
                    data["phase"] = "intent-install-" + key
                    self.write_manifest(data)
                    self.failpoint(data["phase"])
                    os.replace(str(staged), str(destination))
                    items[key]["installed"] = True
                    data["phase"] = "installed-" + key
                    self.write_manifest(data)
                    self.failpoint(data["phase"])
                self.lifecycle.verify_app(self.paths.app(YABAI_SPEC), YABAI_SPEC)
                self.lifecycle.verify_app(self.paths.app(SKHD_SPEC), SKHD_SPEC)
                data["phase"] = "committed"
                self.write_manifest(data)
                self.failpoint("committed")
            except BaseException:
                self.recover()
                raise
            finally:
                for signal_number, handler in previous_handlers.items():
                    signal.signal(signal_number, handler)
            self.cleanup_transaction()
        return {"published_app_count": 2, "recovery": "not-needed"}


def stage_verified_source(
    lifecycle: Lifecycle,
    source: pathlib.Path,
    destination: pathlib.Path,
    expected_sha256: str,
    expected_archs: str,
    expected_version: str,
) -> Dict[str, str]:
    if not source.is_absolute():
        raise LifecycleError("a source executable path is not absolute")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        source_descriptor = os.open(str(source), flags)
    except OSError as error:
        raise LifecycleError("a source executable cannot be opened safely") from error
    destination_descriptor: Optional[int] = None
    digest = hashlib.sha256()
    try:
        metadata = os.fstat(source_descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != lifecycle.uid or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) & 0o022:
            raise LifecycleError("a source executable identity is unsafe")
        if not metadata.st_mode & stat.S_IXUSR:
            raise LifecycleError("a source executable is not executable")
        destination_descriptor = os.open(str(destination), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        while True:
            block = os.read(source_descriptor, 1024 * 1024)
            if not block:
                break
            digest.update(block)
            write_all(destination_descriptor, block)
        os.fsync(destination_descriptor)
    finally:
        os.close(source_descriptor)
        if destination_descriptor is not None:
            os.close(destination_descriptor)
    if digest.hexdigest() != expected_sha256:
        raise LifecycleError("a source executable identity is not approved")
    os.chmod(str(destination), 0o700)
    architecture = lifecycle.runner.run(("/usr/bin/lipo", "-archs", str(destination))).stdout.strip()
    if architecture != expected_archs:
        raise LifecycleError("a source executable architecture is not approved")
    version = lifecycle.runner.run((str(destination), "--version")).stdout.strip()
    if version != expected_version:
        raise LifecycleError("a source executable version is not approved")
    return {"sha256": digest.hexdigest(), "archs": architecture, "version": version}


def build_wrapper(
    lifecycle: Lifecycle,
    source: pathlib.Path,
    destination: pathlib.Path,
    spec: AppSpec,
) -> Dict[str, str]:
    contents = destination / "Contents"
    executable_directory = contents / "MacOS"
    executable_directory.mkdir(parents=True, mode=0o700)
    executable = executable_directory / spec.executable
    shutil.copyfile(str(source), str(executable))
    os.chmod(str(executable), 0o755)
    info = {
        "CFBundleDevelopmentRegion": "English",
        "CFBundleExecutable": spec.executable,
        "CFBundleIdentifier": spec.bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": spec.executable,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": spec.short_version,
        "CFBundleVersion": spec.bundle_version or spec.short_version,
        "LSMinimumSystemVersion": "12.0",
        "LSUIElement": True,
        "NSAccessibilityUsageDescription": spec.executable + " needs Accessibility access to manage windows or global shortcuts.",
        "NSHighResolutionCapable": True,
        "NSSupportsAutomaticGraphicsSwitching": True,
    }
    info_path = contents / "Info.plist"
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle, fmt=plistlib.FMT_XML, sort_keys=True)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(str(info_path), 0o644)
    lifecycle.runner.run(("/usr/bin/xattr", "-cr", str(destination)))
    lifecycle.runner.run(("/usr/bin/codesign", "--force", "--sign", "-", "--identifier", spec.bundle_id, str(destination)))
    for root, directories, files in os.walk(str(destination)):
        os.chmod(root, 0o755)
        for name in directories:
            os.chmod(os.path.join(root, name), 0o755)
        for name in files:
            path = pathlib.Path(root) / name
            os.chmod(str(path), 0o755 if path == executable else 0o644)
    return lifecycle.verify_app(destination, spec, compare_identity=False)


def dynamic_spec(base: AppSpec, version: str, version_output: str, archs: str) -> AppSpec:
    return AppSpec(
        name=base.name,
        bundle_id=base.bundle_id,
        executable=base.executable,
        short_version=version,
        bundle_version=version,
        version_output=version_output,
        archs=archs,
        executable_sha256="",
        info_sha256="",
        cdhash="",
        tree_sha256="",
    )


def recover_transactions(
    lifecycle: Lifecycle,
    publisher: PairPublisher,
    support_pending: bool,
    app_pending: bool,
) -> Dict[str, Any]:
    if not support_pending and not app_pending:
        return {"app": "not-needed", "support": "not-needed"}
    lifecycle.stop_primaries()
    return {"app": publisher.recover(), "support": lifecycle.recover_support()}


def verify_fallback_candidate(lifecycle: Lifecycle, arguments: argparse.Namespace) -> Dict[str, Any]:
    candidate = pathlib.Path(arguments.path)
    if not candidate.is_absolute():
        raise LifecycleError("the fallback candidate path is not absolute")
    bundle_version = None if arguments.bundle_version == "NONE" else arguments.bundle_version
    spec = AppSpec(
        name="AeroSpace.app",
        bundle_id="bobko.aerospace",
        executable="AeroSpace",
        short_version=arguments.short_version,
        bundle_version=bundle_version,
        version_output=arguments.version_output,
        archs=arguments.archs,
        executable_sha256=arguments.executable_sha256,
        info_sha256=arguments.info_sha256,
        cdhash=arguments.cdhash,
        tree_sha256=arguments.tree_sha256,
    )
    identity = lifecycle.verify_app(candidate, spec)
    return {"candidate_identity": identity, "candidate_path": str(candidate)}


def build_only(lifecycle: Lifecycle, arguments: argparse.Namespace) -> Dict[str, Any]:
    output = pathlib.Path(arguments.output)
    if not output.is_absolute():
        raise LifecycleError("the build-only output path is not absolute")
    parent = output.parent
    lifecycle.require_owned_directory(parent)
    parent = parent.resolve(strict=True)
    if output.parent != parent:
        raise LifecycleError("the build-only output parent is not canonical")
    if output.exists() or output.is_symlink():
        raise LifecycleError("the build-only output path already exists")
    yabai_spec = dynamic_spec(YABAI_SPEC, arguments.yabai_version, "yabai-v" + arguments.yabai_version, arguments.yabai_archs)
    skhd_spec = dynamic_spec(SKHD_SPEC, arguments.skhd_version, "skhd-v" + arguments.skhd_version, arguments.skhd_archs)
    yabai_source = pathlib.Path(arguments.yabai_source)
    skhd_source = pathlib.Path(arguments.skhd_source)
    output.mkdir(mode=0o700)
    lifecycle.require_owned_directory(output, 0o700)
    source_staging = output / "verified-sources"
    source_staging.mkdir(mode=0o700)
    staged_yabai = source_staging / "yabai"
    staged_skhd = source_staging / "skhd"
    sources = {
        "yabai": stage_verified_source(lifecycle, yabai_source, staged_yabai, arguments.yabai_source_sha256, arguments.yabai_archs, yabai_spec.version_output),
        "skhd": stage_verified_source(lifecycle, skhd_source, staged_skhd, arguments.skhd_source_sha256, arguments.skhd_archs, skhd_spec.version_output),
    }
    apps = {
        "yabai": build_wrapper(lifecycle, staged_yabai, output / YABAI_SPEC.name, yabai_spec),
        "skhd": build_wrapper(lifecycle, staged_skhd, output / SKHD_SPEC.name, skhd_spec),
    }
    identity = {"schema": "wm-build-only-identity-v1", "sources": sources, "apps": apps}
    identity_path = output / "identity.json"
    descriptor = os.open(str(identity_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        write_all(descriptor, (json.dumps(identity, sort_keys=True, indent=2) + "\n").encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return {"output": str(output), "identity_sha256": lifecycle.sha256(identity_path), "apps": apps, "sources": sources}



class InterruptedLifecycle(LifecycleError):
    pass


@contextlib.contextmanager
def rollback_signals() -> Iterable[None]:
    previous: Dict[int, Any] = {}

    def interrupted(_number: int, _frame: Any) -> None:
        raise InterruptedLifecycle("the lifecycle operation was interrupted")

    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[number] = signal.getsignal(number)
        signal.signal(number, interrupted)
    try:
        yield
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def bootstrap_private_state(paths: Paths) -> None:
    current = paths.home
    metadata = os.lstat(str(current))
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise LifecycleError("the user home identity is unsafe")
    relative = paths.state_root.relative_to(paths.home)
    for component in relative.parts:
        current = current / component
        try:
            metadata = os.lstat(str(current))
        except FileNotFoundError:
            os.mkdir(str(current), 0o700)
            metadata = os.lstat(str(current))
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise LifecycleError("a lifecycle state ancestor is unsafe")
    if stat.S_IMODE(os.lstat(str(paths.state_root)).st_mode) != 0o700:
        raise LifecycleError("the lifecycle state directory mode is invalid")
    temporary = paths.state_root / "tmp"
    if not temporary.exists():
        os.mkdir(str(temporary), 0o700)
    metadata = os.lstat(str(temporary))
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise LifecycleError("the lifecycle temporary directory identity is unsafe")


@contextlib.contextmanager
def lifecycle_lock(lifecycle: Lifecycle) -> Iterable[None]:
    path = lifecycle.paths.state_root / "lifecycle.lock"
    descriptor = os.open(str(path), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if metadata.st_uid != lifecycle.uid or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise LifecycleError("the lifecycle lock identity is unsafe")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise LifecycleError("another lifecycle operation is active") from error
        yield
    finally:
        os.close(descriptor)


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="action", required=True)
    for action in ("status", "activate", "rollback", "recover"):
        subcommands.add_parser(action)
    prepare = subcommands.add_parser("prepare")
    prepare.add_argument("--adopt-existing", action="store_true", required=True)
    attest = subcommands.add_parser("attest-accessibility")
    attest.add_argument("--manifest-digest", required=True)
    accept = subcommands.add_parser("accept-runtime")
    accept.add_argument("--activation-receipt-sha256", required=True)
    fallback = subcommands.add_parser("verify-fallback-candidate")
    fallback.add_argument("--path", required=True)
    fallback.add_argument("--short-version", required=True)
    fallback.add_argument("--bundle-version", required=True)
    fallback.add_argument("--version-output", required=True)
    fallback.add_argument("--archs", required=True)
    fallback.add_argument("--executable-sha256", required=True)
    fallback.add_argument("--info-sha256", required=True)
    fallback.add_argument("--tree-sha256", required=True)
    fallback.add_argument("--cdhash", required=True)
    publish = subcommands.add_parser("publish-pair")
    publish.add_argument("--source-root", required=True)
    build = subcommands.add_parser("build-only")
    build.add_argument("--output", required=True)
    build.add_argument("--yabai-source", required=True)
    build.add_argument("--skhd-source", required=True)
    build.add_argument("--yabai-source-sha256", required=True)
    build.add_argument("--skhd-source-sha256", required=True)
    build.add_argument("--yabai-version", required=True)
    build.add_argument("--skhd-version", required=True)
    build.add_argument("--yabai-archs", required=True)
    build.add_argument("--skhd-archs", required=True)
    return parser


def main() -> int:
    parser = make_parser()
    arguments = parser.parse_args()
    paths = Paths.production()
    try:
        bootstrap_private_state(paths)
        temporary = paths.state_root / "tmp"
        lifecycle = Lifecycle(paths, Runner(paths.home, temporary))
        publisher = PairPublisher(lifecycle)
        with lifecycle_lock(lifecycle), rollback_signals():
            support_pending = lifecycle.support_journal_path().exists()
            app_pending = publisher.transaction.exists()
            if arguments.action == "status":
                data = lifecycle.status()
            elif arguments.action == "prepare":
                if support_pending or app_pending:
                    raise LifecycleError("recovery is required before preparation")
                data = lifecycle.configure()
            elif arguments.action == "attest-accessibility":
                if support_pending or app_pending:
                    raise LifecycleError("recovery is required before attestation")
                data = lifecycle.attest_accessibility(arguments.manifest_digest)
            elif arguments.action == "activate":
                if support_pending or app_pending:
                    raise LifecycleError("recovery is required before activation")
                data = lifecycle.activate()
            elif arguments.action == "rollback":
                data = lifecycle.rollback(start_fallback=True)
            elif arguments.action == "recover":
                data = recover_transactions(lifecycle, publisher, support_pending, app_pending)
            elif arguments.action == "verify-fallback-candidate":
                if support_pending or app_pending:
                    raise LifecycleError("recovery is required before fallback verification")
                data = verify_fallback_candidate(lifecycle, arguments)
            elif arguments.action == "publish-pair":
                if support_pending or app_pending:
                    raise LifecycleError("recovery is required before publication")
                data = publisher.publish(pathlib.Path(arguments.source_root))
            elif arguments.action == "build-only":
                if support_pending or app_pending:
                    raise LifecycleError("recovery is required before candidate build")
                data = build_only(lifecycle, arguments)
            elif arguments.action == "accept-runtime":
                if support_pending or app_pending:
                    raise LifecycleError("recovery is required before runtime acceptance")
                data = lifecycle.accept_runtime(arguments.activation_receipt_sha256)
            else:
                raise LifecycleError("an unknown lifecycle action was requested")
            if arguments.action == "status":
                result = {
                    "action": "status",
                    "status": "PASS",
                    "receipt": None,
                    "transaction_state": data.get("transaction_state"),
                    "lane_state": data.get("lane_state"),
                    "deployment_state": data.get("deployment_state"),
                }
            else:
                receipt = lifecycle.write_receipt(arguments.action, data)
                result = reduced_result(arguments.action, receipt, data)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (LifecycleError, KeyboardInterrupt) as error:
        print(json.dumps({"action": arguments.action, "status": "FAIL", "reason": str(error)}, sort_keys=True), file=sys.stderr)
        return 1
    except Exception:
        print(json.dumps({"action": arguments.action, "status": "FAIL", "reason": "an unexpected internal failure occurred"}, sort_keys=True), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
