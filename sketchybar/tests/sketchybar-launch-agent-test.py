#!/usr/bin/env python3
"""Unit and hostile-filesystem tests for the first-party LaunchAgent installer."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import signal
import stat
import subprocess
import sys
import tempfile
from unittest import mock


def check(condition, message):
    if not condition:
        raise SystemExit(message)


installer_path = Path(sys.argv[1]).resolve()
plist_path = Path(sys.argv[2]).resolve()
source_text = installer_path.read_text()
check("SKETCHYBAR_" not in source_text and "--test" not in source_text
      and "argparse" not in source_text and "LAUNCHCTL_TIMEOUT_SECONDS" in source_text
      and "timeout=LAUNCHCTL_TIMEOUT_SECONDS" in source_text,
      "production installer must have no fixture environment or test CLI and must bound launchctl")
check("print(result" not in source_text and 'decode("utf-8"' in source_text,
      "production installer must keep launchctl output private and parse live state strictly")

spec = importlib.util.spec_from_file_location("sketchybar_launch_agent", installer_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
reviewed_bytes = plist_path.read_bytes()
module._validate_plist(reviewed_bytes)
expected = plistlib.loads(reviewed_bytes)
check(expected == module.EXPECTED_PLIST
      and "Umask" not in expected and "ThrottleInterval" not in expected,
      "reviewed plist must match the installer's exact closed contract")


def live_output(good=True, plist_data=None, last_exit=True, process_token=42):
    value = plistlib.loads(plist_data or reviewed_bytes)
    arguments_value = tuple(value["ProgramArguments"])
    program = arguments_value[0] if good else "/invalid/program"
    arguments = "\n".join("\t\t" + item for item in arguments_value)
    exit_line = "\tlast exit code = (never exited)\n" if last_exit else ""
    return (f"gui/service = {{\n"
            f"\tpath = {module.DESTINATION}\n"
            f"\tstate = running\n"
            f"\tprogram = {program}\n"
            f"\targuments = {{\n{arguments}\n\t}}\n"
            f"\tstdout path = {value['StandardOutPath']}\n"
            f"\tstderr path = {value['StandardErrorPath']}\n"
            f"\tpid = {process_token}\n"
            f"{exit_line}"
            f"}}\n").encode()


EXPECTED_SOURCE_BAR_ORDER = (
    "release.probe", "popup.controller",
    "space.1", "space.2", "space.3", "space.4", "space.5",
    "space.6", "space.7", "space.8", "space.9", "front_window",
    "wifi", "bluetooth", "display", "audio", "microphone", "battery",
    "calendar", "calendar.next", "calendar.event.bracket",
    "calendar.date.bracket", "tmp", "ssd", "net", "ram", "gpu", "cpu",
    "system.bracket",
)
check(module.EXPECTED_BAR_ITEMS == EXPECTED_SOURCE_BAR_ORDER,
      "installer bar order no longer matches independent source registration order")


def bar_output(drawing="on", height=36, items=None):
    value = {
        "drawing": drawing,
        "height": height,
        "items": list(module.EXPECTED_BAR_ITEMS) if items is None else items,
    }
    return module.json.dumps(value, separators=(",", ":")).encode()


class FakeLaunchctl:
    def __init__(self, loaded=False, fail_bootstrap=0, bad_live_print=None,
                 contract_data=None):
        self.loaded = loaded
        self.fail_bootstrap = fail_bootstrap
        self.bad_live_print = bad_live_print
        self.contract_data = contract_data or reviewed_bytes
        self.loaded_prints = 0
        self.process_token = 42
        self.calls = []

    def __call__(self, arguments):
        self.calls.append(arguments[0])
        command = arguments[0]
        if command == "print":
            if not self.loaded:
                return module.CommandResult(113, b"")
            self.loaded_prints += 1
            good = (self.bad_live_print is None
                    or self.loaded_prints < self.bad_live_print
                    or self.contract_data != reviewed_bytes)
            return module.CommandResult(
                0, live_output(good, self.contract_data,
                               process_token=self.process_token))
        if command == "bootout":
            if not self.loaded:
                return module.CommandResult(1, b"")
            self.loaded = False
            return module.CommandResult(0, b"")
        if command == "bootstrap":
            if self.fail_bootstrap:
                self.fail_bootstrap -= 1
                return module.CommandResult(1, b"")
            self.contract_data = module.DESTINATION.read_bytes()
            self.loaded = True
            return module.CommandResult(0, b"")
        raise RuntimeError("unexpected mocked command")


class Fixture:
    def __init__(self, raw, loaded=False, previous=None, fail_bootstrap=0,
                 bad_live_print=None, logs=True):
        self.base = Path(raw)
        self.home = self.base / "home"
        self.library = self.home / "Library"
        self.launch_agents = self.library / "LaunchAgents"
        self.logs_parent = self.library / "Logs"
        self.log_directory = self.logs_parent / "sketchybar"
        self.source_parent = self.base / "source" / "launch-agents"
        self.source = self.source_parent / "homebrew.mxcl.sketchybar.plist"
        self.destination = self.launch_agents / "homebrew.mxcl.sketchybar.plist"
        self.home.mkdir(mode=0o700)
        self.library.mkdir(mode=0o700)
        self.launch_agents.mkdir(mode=0o755)
        self.logs_parent.mkdir(mode=0o700)
        self.source_parent.mkdir(parents=True, mode=0o755)
        self.launch_agents.chmod(0o755)
        self.source_parent.chmod(0o755)
        self.source.write_bytes(reviewed_bytes)
        self.source.chmod(0o644)
        if logs:
            self.log_directory.mkdir(mode=0o700)
        if previous is not None:
            self.destination.write_bytes(previous)
            self.destination.chmod(0o644)
        self.fake = FakeLaunchctl(
            loaded, fail_bootstrap, bad_live_print,
            previous if loaded and previous is not None else reviewed_bytes)
        self.stack = contextlib.ExitStack()
        self.stack.enter_context(mock.patch.object(module, "USER_HOME", self.home))
        self.stack.enter_context(mock.patch.object(module, "SOURCE", self.source))
        self.stack.enter_context(mock.patch.object(module, "DESTINATION", self.destination))
        self.stack.enter_context(mock.patch.object(module, "LOG_DIRECTORY", self.log_directory))
        self.stack.enter_context(mock.patch.object(
            module, "LOCK_FILE", self.log_directory / ".launch-agent-install.lock"))
        self.stack.enter_context(mock.patch.object(
            module, "LOG_FILES",
            (self.log_directory / "sketchybar.out.log",
             self.log_directory / "sketchybar.err.log")))
        self.stack.enter_context(mock.patch.object(module.Path, "home", return_value=self.home))
        self.stack.enter_context(mock.patch.dict(os.environ, {"HOME": os.fspath(self.home)}))
        self.stack.enter_context(mock.patch.object(module, "_bounded_launchctl", self.fake))
        self.stack.enter_context(mock.patch.object(
            module, "_bounded_bar_query",
            return_value=module.CommandResult(0, bar_output())))

    def close(self):
        self.stack.close()

    def install(self):
        module.install()

    def residue(self):
        return [entry.name for entry in self.launch_agents.iterdir()
                if entry.name != self.destination.name]


old_value = dict(expected)
old_value["ProgramArguments"] = [module.PROGRAM_ARGUMENTS[0]]
old_value["StandardOutPath"] = "/opt/homebrew/var/log/sketchybar/sketchybar.out.log"
old_value["StandardErrorPath"] = "/opt/homebrew/var/log/sketchybar/sketchybar.err.log"
old_bytes = plistlib.dumps(old_value, sort_keys=False)

# Exact schema: every added, removed, mistyped, reordered-array, and changed value fails.
mutations = []
for key in expected:
    changed = dict(expected)
    changed.pop(key)
    mutations.append(changed)
changed = dict(expected)
changed["Umask"] = 63
mutations.append(changed)
changed = dict(expected)
changed["ThrottleInterval"] = 5
mutations.append(changed)
changed = dict(expected)
changed["RunAtLoad"] = 1
mutations.append(changed)
changed = dict(expected)
changed["ProgramArguments"] = list(reversed(expected["ProgramArguments"]))
mutations.append(changed)
changed = dict(expected)
changed["EnvironmentVariables"] = dict(expected["EnvironmentVariables"], HOME="/Users/twaldin")
mutations.append(changed)
changed = dict(expected)
changed["LimitLoadToSessionType"] = list(reversed(expected["LimitLoadToSessionType"]))
mutations.append(changed)
for value in mutations:
    data = plistlib.dumps(value, sort_keys=False)
    try:
        module._validate_plist(data)
    except module.InstallFailure:
        pass
    else:
        raise SystemExit("closed plist schema or exact value mutation was accepted")
duplicate = reviewed_bytes.replace(b"\t<key>KeepAlive</key>",
                                   b"\t<key>Label</key>\n\t<string>homebrew.mxcl.sketchybar</string>\n\t<key>KeepAlive</key>", 1)
try:
    module._validate_plist(duplicate)
except module.InstallFailure:
    pass
else:
    raise SystemExit("duplicate plist key was accepted")

# The real bounded launchctl boundary rejects timeout, oversized output, and unknown status.
completed = subprocess.CompletedProcess(["launchctl"], 0, b"ok", b"")
with mock.patch.object(module.subprocess, "run", return_value=completed) as run_mock:
    result = module._bounded_launchctl(("print", "gui/service"))
    check(result.returncode == 0 and result.stdout == b"ok"
          and run_mock.call_args.kwargs.get("timeout") == module.LAUNCHCTL_TIMEOUT_SECONDS,
          "bounded launchctl subprocess path is not executed with its timeout")
for outcome in (
        subprocess.TimeoutExpired(["launchctl"], module.LAUNCHCTL_TIMEOUT_SECONDS),
        subprocess.CompletedProcess(["launchctl"], 0, b"x" * (module.MAX_LAUNCHCTL_OUTPUT + 1), b""),
        subprocess.CompletedProcess(["launchctl"], 0, b"", b"x" * (module.MAX_LAUNCHCTL_OUTPUT + 1))):
    with mock.patch.object(module.subprocess, "run", side_effect=outcome) if isinstance(outcome, Exception) \
            else mock.patch.object(module.subprocess, "run", return_value=outcome):
        try:
            module._bounded_launchctl(("print", "gui/service"))
        except module.InstallFailure:
            pass
        else:
            raise SystemExit("bounded launchctl failure was accepted")
with mock.patch.object(module, "_bounded_launchctl",
                       return_value=module.CommandResult(64, b"")):
    try:
        module._print_state(os.getuid())
    except module.InstallFailure:
        pass
    else:
        raise SystemExit("unknown launchctl print status was accepted")

# Live parsing rejects every exact-path, running-state, argument, log, process, and encoding mismatch.
positive_live = module._parse_live_snapshot(live_output())
positive_live_without_exit = module._parse_live_snapshot(live_output(last_exit=False))
check(module._reviewed_live_snapshot(positive_live)
      and module._reviewed_live_snapshot(positive_live_without_exit),
      "exact live launchctl contract or running output without an exit field was rejected")
live_mutations = (
    live_output().replace(b"\tpath = ", b"\tpath = /wrong/", 1),
    live_output().replace(b"\tstate = running", b"\tstate = waiting", 1),
    live_output().replace(module.PROGRAM_ARGUMENTS[0].encode(), b"/wrong/program", 1),
    live_output().replace(module.STDOUT_PATH.encode(), b"/wrong/stdout", 1),
    live_output().replace(module.STDERR_PATH.encode(), b"/wrong/stderr", 1),
    live_output().replace(b"\t\t--config\n", b"", 1),
    live_output().replace(b"\tprogram = ", b"\tprogram = /duplicate\n\tprogram = ", 1),
    live_output().replace(b"\t}\n", b"", 1),
    live_output().replace(b"\tpid = 42", b"\tpid = invalid", 1),
    live_output().replace(b"(never exited)", b"1", 1),
    live_output().replace(b"\tlast exit code = ",
                          b"\tlast exit code = 0\n\tlast exit code = ", 1),
    live_output() + b"\x00",
    b"\xff",
)
for payload in live_mutations:
    try:
        accepted = module._reviewed_live_snapshot(module._parse_live_snapshot(payload))
    except module.InstallFailure:
        accepted = False
    check(not accepted, "malformed or mismatched live launchctl contract was accepted")

# The bounded bar query and exact configured shape parser reject nearby states.
with mock.patch.object(
        module.subprocess, "run",
        return_value=subprocess.CompletedProcess(["sketchybar"], 0, bar_output(), b"")) as run_mock:
    bar_result = module._bounded_bar_query()
    check(bar_result.returncode == 0 and module._valid_bar_shape(bar_result.stdout)
          and run_mock.call_args.kwargs.get("timeout") == module.BAR_QUERY_TIMEOUT_SECONDS,
          "bounded exact bar query path is not executed")
for result in (
        subprocess.TimeoutExpired(["sketchybar"], module.BAR_QUERY_TIMEOUT_SECONDS),
        subprocess.CompletedProcess(["sketchybar"], 0,
                                    b"x" * (module.MAX_LAUNCHCTL_OUTPUT + 1), b"")):
    context = (mock.patch.object(module.subprocess, "run", side_effect=result)
               if isinstance(result, Exception)
               else mock.patch.object(module.subprocess, "run", return_value=result))
    with context:
        try:
            module._bounded_bar_query()
        except module.InstallFailure:
            pass
        else:
            raise SystemExit("bounded bar query failure was accepted")
popup_after_spaces = list(EXPECTED_SOURCE_BAR_ORDER)
popup_after_spaces.remove("popup.controller")
popup_after_spaces.insert(popup_after_spaces.index("space.9") + 1,
                          "popup.controller")
for payload in (
        bar_output(drawing="off"),
        bar_output(height=25),
        bar_output(height=True),
        bar_output(items=list(module.EXPECTED_BAR_ITEMS[:-1])),
        bar_output(items=popup_after_spaces),
        bar_output(items=list(reversed(module.EXPECTED_BAR_ITEMS))),
        b"{}", b"\xff", bar_output() + b"\x00"):
    check(not module._valid_bar_shape(payload), "nearby or malformed bar shape was accepted")

# Source hostility: links, excess links, unsafe modes, and invalid schema all fail before launchctl.
for attack in ("symlink", "hardlink", "mode", "schema"):
    with tempfile.TemporaryDirectory(prefix="launch-agent-source-test.") as raw:
        fixture = Fixture(raw)
        try:
            if attack == "symlink":
                fixture.source.unlink()
                fixture.source.symlink_to(plist_path)
            elif attack == "hardlink":
                alias = fixture.base / "source-alias"
                os.link(fixture.source, alias)
            elif attack == "mode":
                fixture.source.chmod(0o666)
            else:
                fixture.source.write_bytes(plistlib.dumps(dict(expected, Umask=63), sort_keys=False))
                fixture.source.chmod(0o644)
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("hostile source was accepted: " + attack)
            check(fixture.fake.calls == [], "source hostility must fail before launchctl")
        finally:
            fixture.close()

# Destination and LaunchAgents parent hostility fail without replacing any entry.
for attack in ("symlink", "hardlink", "mode", "parent-mode", "parent-link"):
    with tempfile.TemporaryDirectory(prefix="launch-agent-target-test.") as raw:
        fixture = Fixture(raw, previous=old_bytes)
        alias = None
        try:
            if attack == "symlink":
                fixture.destination.unlink()
                alias = fixture.base / "destination-alias"
                alias.write_bytes(old_bytes)
                fixture.destination.symlink_to(alias)
            elif attack == "hardlink":
                alias = fixture.base / "destination-alias"
                os.link(fixture.destination, alias)
            elif attack == "mode":
                fixture.destination.chmod(0o666)
            elif attack == "parent-mode":
                fixture.launch_agents.chmod(0o777)
            else:
                fixture.close()
                real_parent = fixture.library / "RealLaunchAgents"
                fixture.launch_agents.rename(real_parent)
                fixture.launch_agents.symlink_to(real_parent, target_is_directory=True)
                fixture.stack = contextlib.ExitStack()
                fixture.stack.enter_context(mock.patch.object(module, "USER_HOME", fixture.home))
                fixture.stack.enter_context(mock.patch.object(module, "SOURCE", fixture.source))
                fixture.stack.enter_context(mock.patch.object(module, "DESTINATION", fixture.destination))
                fixture.stack.enter_context(mock.patch.object(module, "LOG_DIRECTORY", fixture.log_directory))
                fixture.stack.enter_context(mock.patch.object(
                    module, "LOCK_FILE",
                    fixture.log_directory / ".launch-agent-install.lock"))
                fixture.stack.enter_context(mock.patch.object(module, "LOG_FILES", (
                    fixture.log_directory / "sketchybar.out.log",
                    fixture.log_directory / "sketchybar.err.log")))
                fixture.stack.enter_context(mock.patch.object(module.Path, "home", return_value=fixture.home))
                fixture.stack.enter_context(mock.patch.dict(os.environ, {"HOME": os.fspath(fixture.home)}))
                fixture.stack.enter_context(mock.patch.object(module, "_bounded_launchctl", fixture.fake))
                fixture.stack.enter_context(mock.patch.object(
                    module, "_bounded_bar_query",
                    return_value=module.CommandResult(0, bar_output())))
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("hostile destination was accepted: " + attack)
            check(fixture.fake.calls == [], "destination hostility must fail before launchctl")
            if alias is not None and alias.is_file():
                check(alias.read_bytes() == old_bytes, "destination alias changed")
        finally:
            fixture.close()

# Log directory/files must be private real single-link files. Missing safe files are created.
with tempfile.TemporaryDirectory(prefix="launch-agent-log-success-test.") as raw:
    fixture = Fixture(raw, logs=False)
    try:
        fixture.install()
        check(stat.S_IMODE(fixture.log_directory.stat().st_mode) == 0o700,
              "created log directory mode is not 0700")
        for path in module.LOG_FILES:
            info = os.lstat(path)
            check(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                  and stat.S_IMODE(info.st_mode) == 0o600,
                  "created log file is not a mode-0600 single-link regular file")
    finally:
        fixture.close()

for attack in ("dir-link", "dir-mode", "file-link", "file-hardlink", "file-mode"):
    with tempfile.TemporaryDirectory(prefix="launch-agent-log-hostile-test.") as raw:
        fixture = Fixture(raw)
        alias = fixture.base / "log-alias"
        try:
            if attack == "dir-link":
                fixture.log_directory.rmdir()
                real = fixture.logs_parent / "real-sketchybar"
                real.mkdir(mode=0o700)
                fixture.log_directory.symlink_to(real, target_is_directory=True)
            elif attack == "dir-mode":
                fixture.log_directory.chmod(0o755)
            else:
                log = module.LOG_FILES[0]
                log.write_bytes(b"old log")
                log.chmod(0o600)
                if attack == "file-link":
                    log.unlink()
                    alias.write_bytes(b"old log")
                    alias.chmod(0o600)
                    log.symlink_to(alias)
                elif attack == "file-hardlink":
                    os.link(log, alias)
                else:
                    log.chmod(0o644)
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("hostile log path was accepted: " + attack)
            check(fixture.fake.calls == [], "log hostility must fail before launchctl")
            if alias.exists() and alias.is_file():
                check(alias.read_bytes() == b"old log", "log alias changed")
        finally:
            fixture.close()

# A loaded job whose on-disk plist does not match live state is not booted out.
with tempfile.TemporaryDirectory(prefix="launch-agent-unrecoverable-loaded-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    fixture.fake.contract_data = reviewed_bytes
    try:
        try:
            with mock.patch.object(module, "LAUNCHCTL_TIMEOUT_SECONDS", 0.25):
                fixture.install()
        except module.InstallFailure:
            pass
        else:
            raise SystemExit("unrecoverable loaded prior state was accepted")
        check(fixture.destination.read_bytes() == old_bytes and fixture.fake.loaded
              and "bootout" not in fixture.fake.calls and fixture.residue() == [],
              "unrecoverable loaded prior state was mutated")
    finally:
        fixture.close()

# A prior plist with unreviewed launch semantics is not treated as a recoverable source.
with tempfile.TemporaryDirectory(prefix="launch-agent-semantics-test.") as raw:
    changed_value = dict(expected)
    changed_value["KeepAlive"] = False
    changed_bytes = plistlib.dumps(changed_value, sort_keys=False)
    fixture = Fixture(raw, loaded=True, previous=changed_bytes)
    try:
        try:
            with mock.patch.object(module, "LAUNCHCTL_TIMEOUT_SECONDS", 0.25):
                fixture.install()
        except module.InstallFailure:
            pass
        else:
            raise SystemExit("unreviewed prior launch semantics were accepted")
        check(fixture.destination.read_bytes() == changed_bytes and fixture.fake.loaded
              and "bootout" not in fixture.fake.calls,
              "unreviewed prior launch semantics were mutated")
    finally:
        fixture.close()

# Rollback-source readback rejects one transient matching process observation.
with tempfile.TemporaryDirectory(prefix="launch-agent-transient-rollback-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    matching_snapshot = module._parse_live_snapshot(live_output(plist_data=old_bytes))
    observations = {"count": 0}

    def transient_snapshot(unused_owner):
        observations["count"] += 1
        if observations["count"] == 1:
            return matching_snapshot
        raise module.InstallFailure()

    try:
        with mock.patch.object(module, "_read_live_snapshot", side_effect=transient_snapshot), \
                mock.patch.object(module, "LAUNCHCTL_TIMEOUT_SECONDS", 0.25):
            try:
                module._verify_loaded_rollback_source(os.getuid(), module._read_destination(os.getuid()))
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("transient prior process was accepted as stable rollback")
    finally:
        fixture.close()

# A replacement between initial and fresh destination preflights is rejected without mutation.
with tempfile.TemporaryDirectory(prefix="launch-agent-race-test.") as raw:
    fixture = Fixture(raw, previous=old_bytes)
    original_read = module._read_destination
    reads = {"count": 0}

    def raced_read(owner):
        reads["count"] += 1
        if reads["count"] == 2:
            replacement = fixture.launch_agents / "race-replacement"
            replacement.write_bytes(old_bytes)
            replacement.chmod(0o644)
            os.replace(replacement, fixture.destination)
        return original_read(owner)

    try:
        with mock.patch.object(module, "_read_destination", side_effect=raced_read):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("fresh expected-state race was accepted")
        check(fixture.destination.read_bytes() == old_bytes and fixture.fake.calls == ["print"],
              "expected-state race changed destination or launch state")
    finally:
        fixture.close()

# A loaded-state change between initial and fresh preflights also fails before mutation.
with tempfile.TemporaryDirectory(prefix="launch-agent-state-race-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    print_calls = {"count": 0}

    def raced_launchctl(arguments):
        check(arguments[0] == "print", "loaded-state race attempted a mutation")
        print_calls["count"] += 1
        if print_calls["count"] <= 3:
            return module.CommandResult(0, live_output(plist_data=old_bytes))
        return module.CommandResult(113, b"")

    try:
        with mock.patch.object(module, "_bounded_launchctl", side_effect=raced_launchctl):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("fresh loaded-state race was accepted")
        check(fixture.destination.read_bytes() == old_bytes and print_calls["count"] == 4,
              "loaded-state race changed the destination or passed the fresh preflight")
    finally:
        fixture.close()

# One reviewed post-bootstrap read is not recorded as a stable ownership token.
with tempfile.TemporaryDirectory(prefix="launch-agent-unstable-token-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    original_rollback = module._rollback
    observed_tokens = []

    def capture_rollback(owner, previous, was_loaded, source_data,
                         candidate_ownership_token):
        observed_tokens.append(candidate_ownership_token)
        return original_rollback(owner, previous, was_loaded, source_data,
                                 candidate_ownership_token)

    try:
        with mock.patch.object(module, "_verify_live_contract",
                               side_effect=module.InstallFailure()), \
                mock.patch.object(module, "_rollback",
                                  side_effect=capture_rollback):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("unstable candidate process was accepted")
        check(len(observed_tokens) == 1
              and type(observed_tokens[0]) is int and observed_tokens[0] > 0
              and fixture.destination.read_bytes() == old_bytes
              and fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes
              and fixture.residue() == [],
              "one reviewed read was not used only as exact rollback ownership")
    finally:
        fixture.close()


# A same-contract replacement with a different process token is not unloaded.
with tempfile.TemporaryDirectory(prefix="launch-agent-reviewed-replacement-race-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    original_verify = module._verify_live_contract
    bootouts_before_failure = []

    def replace_reviewed_process_then_fail(owner):
        first = module._read_live_snapshot(owner)
        check(module._reviewed_live_snapshot(first),
              "same-contract replacement fixture did not observe the candidate")
        fixture.fake.process_token += 1
        bootouts_before_failure.append(fixture.fake.calls.count("bootout"))
        raise module.InstallFailure()

    try:
        with mock.patch.object(module, "_verify_live_contract",
                               side_effect=replace_reviewed_process_then_fail):
            try:
                fixture.install()
            except module.RollbackFailure:
                pass
            else:
                raise SystemExit("same-contract unowned replacement did not fail closed")
        check(len(bootouts_before_failure) == 1
              and fixture.fake.calls.count("bootout") == bootouts_before_failure[0]
              and fixture.fake.loaded
              and fixture.fake.contract_data == reviewed_bytes
              and fixture.destination.read_bytes() == old_bytes
              and fixture.residue() == [],
              "rollback unloaded a same-contract process with a different token")
    finally:
        fixture.close()


# A concurrently replaced live job is not unloaded during rollback.
with tempfile.TemporaryDirectory(prefix="launch-agent-unowned-live-race-test.") as raw:
    fixture = Fixture(raw, loaded=False, previous=old_bytes)
    bootouts_before = fixture.fake.calls.count("bootout")

    def replace_live_job_before_bar_query():
        fixture.fake.contract_data = old_bytes
        return module.CommandResult(0, bar_output(height=25))

    try:
        with mock.patch.object(module, "_bounded_bar_query",
                               side_effect=replace_live_job_before_bar_query), \
                mock.patch.object(module, "LAUNCHCTL_TIMEOUT_SECONDS", 0.25):
            try:
                fixture.install()
            except module.RollbackFailure:
                pass
            else:
                raise SystemExit("unowned live replacement did not fail closed")
        check(fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes
              and fixture.fake.calls.count("bootout") == bootouts_before
              and fixture.destination.read_bytes() == old_bytes
              and fixture.residue() == [],
              "rollback unloaded or rewrote an unowned live replacement")
    finally:
        fixture.close()


# A transient prior-service bootstrap failure is recovered once and fully proved.
with tempfile.TemporaryDirectory(prefix="launch-agent-rollback-bootstrap-recovery-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes, fail_bootstrap=1)
    try:
        with mock.patch.object(module, "_publish", side_effect=module.InstallFailure()):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("rollback trigger was accepted after bootstrap recovery")
        check(fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes
              and fixture.destination.read_bytes() == old_bytes
              and fixture.fake.calls.count("bootstrap") == 2
              and fixture.residue() == [],
              "transient prior bootstrap failure did not recover and prove the prior job")
    finally:
        fixture.close()


# Persistent prior-service bootstrap failure is a distinct incomplete rollback.
with tempfile.TemporaryDirectory(prefix="launch-agent-rollback-bootstrap-incomplete-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes, fail_bootstrap=2)
    try:
        with mock.patch.object(module, "_publish", side_effect=module.InstallFailure()):
            try:
                fixture.install()
            except module.RollbackFailure:
                pass
            else:
                raise SystemExit("persistent prior bootstrap failure was not distinct")
        check(not fixture.fake.loaded
              and fixture.destination.read_bytes() == old_bytes
              and fixture.fake.calls.count("bootstrap") == 2
              and fixture.residue() == [],
              "incomplete rollback verdict did not preserve restored prior bytes")
    finally:
        fixture.close()


# A transient prior-service readback failure is recovered without re-bootstrap.
with tempfile.TemporaryDirectory(prefix="launch-agent-rollback-readback-recovery-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    original_verify_rollback = module._verify_loaded_rollback_source
    verify_calls = {"count": 0}

    def fail_first_rollback_readback(owner, previous):
        verify_calls["count"] += 1
        if verify_calls["count"] == 5:
            raise module.InstallFailure()
        return original_verify_rollback(owner, previous)

    try:
        with mock.patch.object(module, "_publish", side_effect=module.InstallFailure()), \
                mock.patch.object(module, "_verify_loaded_rollback_source",
                                  side_effect=fail_first_rollback_readback):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("rollback trigger was accepted after readback recovery")
        check(verify_calls["count"] == 6
              and fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes
              and fixture.destination.read_bytes() == old_bytes
              and fixture.fake.calls.count("bootstrap") == 1
              and fixture.residue() == [],
              "transient prior readback failure did not recover and prove the prior job")
    finally:
        fixture.close()


# Persistent prior-service readback failure is a distinct incomplete rollback.
with tempfile.TemporaryDirectory(prefix="launch-agent-rollback-readback-incomplete-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    original_verify_rollback = module._verify_loaded_rollback_source
    verify_calls = {"count": 0}

    def fail_rollback_readbacks(owner, previous):
        verify_calls["count"] += 1
        if verify_calls["count"] >= 5:
            raise module.InstallFailure()
        return original_verify_rollback(owner, previous)

    try:
        with mock.patch.object(module, "_publish", side_effect=module.InstallFailure()), \
                mock.patch.object(module, "_verify_loaded_rollback_source",
                                  side_effect=fail_rollback_readbacks):
            try:
                fixture.install()
            except module.RollbackFailure:
                pass
            else:
                raise SystemExit("persistent prior readback failure was not distinct")
        check(verify_calls["count"] == 6
              and fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes
              and fixture.destination.read_bytes() == old_bytes
              and fixture.fake.calls.count("bootstrap") == 1
              and fixture.residue() == [],
              "incomplete readback rollback changed the restored prior state")
    finally:
        fixture.close()


# Same-contract different bytes after prior live recovery cannot pass exact rollback proof.
with tempfile.TemporaryDirectory(prefix="launch-agent-rollback-final-bytes-race-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    compatible_value = plistlib.loads(old_bytes)
    compatible_bytes = plistlib.dumps(
        {key: compatible_value[key] for key in reversed(tuple(compatible_value))},
        sort_keys=False)
    check(compatible_bytes != old_bytes,
          "same-contract byte-race fixture is not byte-distinct")
    original_verify_rollback = module._verify_loaded_rollback_source
    verify_calls = {"count": 0}

    def replace_after_recovery_proof(owner, previous):
        token = original_verify_rollback(owner, previous)
        verify_calls["count"] += 1
        if verify_calls["count"] == 5:
            replacement = fixture.launch_agents / "compatible-replacement"
            replacement.write_bytes(compatible_bytes)
            replacement.chmod(0o644)
            os.replace(replacement, fixture.destination)
        return token

    try:
        with mock.patch.object(module, "_publish", side_effect=module.InstallFailure()), \
                mock.patch.object(module, "_verify_loaded_rollback_source",
                                  side_effect=replace_after_recovery_proof):
            try:
                fixture.install()
            except module.RollbackFailure:
                pass
            else:
                raise SystemExit("same-contract final byte replacement passed rollback")
        check(verify_calls["count"] == 5
              and fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes
              and fixture.destination.read_bytes() == compatible_bytes
              and fixture.residue() == [],
              "final byte race was rewritten or reported as a complete rollback")
    finally:
        fixture.close()


# A byte-distinct replacement after the final prior live proof fails before mutation.
with tempfile.TemporaryDirectory(prefix="launch-agent-final-prior-race-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    compatible_value = plistlib.loads(old_bytes)
    compatible_bytes = plistlib.dumps(
        {key: compatible_value[key] for key in reversed(tuple(compatible_value))},
        sort_keys=False)
    original_verify_rollback = module._verify_loaded_rollback_source
    verify_calls = {"count": 0}

    def replace_after_final_prior_proof(owner, previous):
        token = original_verify_rollback(owner, previous)
        verify_calls["count"] += 1
        if verify_calls["count"] == 2:
            replacement = fixture.launch_agents / "final-prior-replacement"
            replacement.write_bytes(compatible_bytes)
            replacement.chmod(0o644)
            os.replace(replacement, fixture.destination)
        return token

    try:
        with mock.patch.object(module, "_verify_loaded_rollback_source",
                               side_effect=replace_after_final_prior_proof):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("final prior byte replacement passed preflight")
        check(verify_calls["count"] == 2
              and fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes
              and "bootout" not in fixture.fake.calls
              and "bootstrap" not in fixture.fake.calls
              and fixture.destination.read_bytes() == compatible_bytes
              and fixture.residue() == [],
              "final prior byte race was mutated or entered the transaction")
    finally:
        fixture.close()


# The transaction lock excludes a competing installer before candidate creation.
with tempfile.TemporaryDirectory(prefix="launch-agent-lock-exclusion-test.") as raw:
    fixture = Fixture(raw, previous=old_bytes)
    held = module._acquire_transaction_lock(os.getuid())
    try:
        try:
            fixture.install()
        except module.InstallFailure:
            pass
        else:
            raise SystemExit("competing LaunchAgent installer acquired the pair lock")
        check(fixture.destination.read_bytes() == old_bytes
              and fixture.fake.calls == ["print"]
              and fixture.residue() == [],
              "competing installer reached launch state or left candidate residue")
    finally:
        module._release_transaction_lock(held)
        fixture.close()


# Handled signals during real candidate writing remove partial files and stop.
for candidate_signal in (signal.SIGINT, signal.SIGTERM):
    with tempfile.TemporaryDirectory(prefix="launch-agent-candidate-signal-test.") as raw:
        fixture = Fixture(raw, previous=old_bytes)
        original_write = module.os.write
        signal_sent = {"value": False}

        def signal_after_write(descriptor, data):
            written = original_write(descriptor, data)
            if not signal_sent["value"]:
                signal_sent["value"] = True
                os.kill(os.getpid(), candidate_signal)
            return written

        try:
            with mock.patch.object(module.os, "write", side_effect=signal_after_write):
                try:
                    fixture.install()
                except module.InstallFailure:
                    pass
                else:
                    raise SystemExit("candidate signal did not stop installation")
            check(signal_sent["value"]
                  and fixture.destination.read_bytes() == old_bytes
                  and fixture.fake.calls == ["print", "print"]
                  and fixture.residue() == [],
                  "candidate signal left residue or changed launch state")
        finally:
            fixture.close()


# Replacement after candidate creation is caught by the final bound read under lock.
with tempfile.TemporaryDirectory(prefix="launch-agent-post-candidate-race-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    compatible_value = plistlib.loads(old_bytes)
    compatible_bytes = plistlib.dumps(
        {key: compatible_value[key] for key in reversed(tuple(compatible_value))},
        sort_keys=False)
    original_write_candidate = module._write_candidate

    def replace_after_candidate(directory, data, mode):
        candidate = original_write_candidate(directory, data, mode)
        replacement = fixture.launch_agents / "post-candidate-replacement"
        replacement.write_bytes(compatible_bytes)
        replacement.chmod(0o644)
        os.replace(replacement, fixture.destination)
        return candidate

    try:
        with mock.patch.object(module, "_write_candidate",
                               side_effect=replace_after_candidate):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("post-candidate replacement passed final binding")
        check(fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes
              and "bootout" not in fixture.fake.calls
              and "bootstrap" not in fixture.fake.calls
              and fixture.destination.read_bytes() == compatible_bytes
              and fixture.residue() == [],
              "post-candidate replacement was overwritten or changed launch state")
    finally:
        fixture.close()


# First lock creation is normalized to mode 0600 under a maximally strict umask.
with tempfile.TemporaryDirectory(prefix="launch-agent-lock-umask-test.") as raw:
    fixture = Fixture(raw, previous=old_bytes)
    previous_umask = os.umask(0o777)
    descriptor = -1
    try:
        descriptor = module._acquire_transaction_lock(os.getuid())
        check(stat.S_IMODE(os.fstat(descriptor).st_mode) == 0o600,
              "first lock creation did not normalize strict-umask mode")
    finally:
        os.umask(previous_umask)
        if descriptor >= 0:
            module._release_transaction_lock(descriptor)
        fixture.close()


# A live-job replacement after candidate creation fails before destructive mutation.
with tempfile.TemporaryDirectory(prefix="launch-agent-post-candidate-live-race-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    original_write_candidate = module._write_candidate

    def replace_live_after_candidate(directory, data, mode):
        candidate = original_write_candidate(directory, data, mode)
        fixture.fake.contract_data = reviewed_bytes
        fixture.fake.process_token += 1
        return candidate

    try:
        with mock.patch.object(module, "_write_candidate",
                               side_effect=replace_live_after_candidate), \
                mock.patch.object(module, "LAUNCHCTL_TIMEOUT_SECONDS", 0.25):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("post-candidate live replacement passed approval")
        check(fixture.fake.loaded
              and fixture.fake.contract_data == reviewed_bytes
              and "bootout" not in fixture.fake.calls
              and "bootstrap" not in fixture.fake.calls
              and fixture.destination.read_bytes() == old_bytes
              and fixture.residue() == [],
              "post-candidate live replacement was unloaded or published over")
    finally:
        fixture.close()


# An idempotent same-contract process replacement fails final token approval.
with tempfile.TemporaryDirectory(prefix="launch-agent-idempotent-token-race-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=reviewed_bytes)
    original_write_candidate = module._write_candidate

    def replace_token_after_candidate(directory, data, mode):
        candidate = original_write_candidate(directory, data, mode)
        fixture.fake.process_token += 1
        return candidate

    try:
        with mock.patch.object(module, "_write_candidate",
                               side_effect=replace_token_after_candidate):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("same-contract token replacement passed approval")
        check(fixture.fake.loaded
              and fixture.fake.contract_data == reviewed_bytes
              and "bootout" not in fixture.fake.calls
              and "bootstrap" not in fixture.fake.calls
              and fixture.destination.read_bytes() == reviewed_bytes
              and fixture.residue() == [],
              "same-contract replacement was unloaded or published over")
    finally:
        fixture.close()


# A token replacement after final approval is rejected at destructive point of use.
with tempfile.TemporaryDirectory(prefix="launch-agent-point-of-use-token-race-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=reviewed_bytes)
    original_bootout_approved = module._bootout_approved_prior

    def replace_before_approved_bootout(owner, previous, expected_process_token):
        fixture.fake.process_token += 1
        return original_bootout_approved(owner, previous, expected_process_token)

    try:
        with mock.patch.object(module, "_bootout_approved_prior",
                               side_effect=replace_before_approved_bootout):
            try:
                fixture.install()
            except module.RollbackFailure:
                pass
            else:
                raise SystemExit("point-of-use token replacement was not closed")
        check(fixture.fake.loaded
              and fixture.fake.contract_data == reviewed_bytes
              and "bootout" not in fixture.fake.calls
              and "bootstrap" not in fixture.fake.calls
              and fixture.destination.read_bytes() == reviewed_bytes
              and fixture.residue() == [],
              "point-of-use replacement was unloaded or published over")
    finally:
        fixture.close()


# A rollback failure has its own closed exception and cannot look like a clean no-op.
with tempfile.TemporaryDirectory(prefix="launch-agent-rollback-failure-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    try:
        with mock.patch.object(module, "_publish", side_effect=module.InstallFailure()), \
                mock.patch.object(module, "_rollback", side_effect=module.InstallFailure()):
            try:
                fixture.install()
            except module.RollbackFailure:
                pass
            else:
                raise SystemExit("incomplete rollback did not raise its distinct closed failure")
    finally:
        fixture.close()

# Cleanup failure cannot mask the distinct rollback-incomplete verdict.
with tempfile.TemporaryDirectory(prefix="launch-agent-masked-rollback-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    try:
        with mock.patch.object(module, "_publish", side_effect=module.InstallFailure()), \
                mock.patch.object(module, "_rollback", side_effect=module.InstallFailure()), \
                mock.patch.object(module.os, "unlink", side_effect=OSError()):
            try:
                fixture.install()
            except module.RollbackFailure:
                pass
            else:
                raise SystemExit("cleanup failure masked the incomplete rollback")
    finally:
        fixture.close()

# Publication failure keeps the exact prior file identity and loaded state.
with tempfile.TemporaryDirectory(prefix="launch-agent-publication-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    before = os.lstat(fixture.destination)
    original_publish = module._publish
    calls = {"count": 0}

    def failed_publish(candidate):
        calls["count"] += 1
        if calls["count"] == 1:
            raise module.InstallFailure()
        return original_publish(candidate)

    try:
        with mock.patch.object(module, "_publish", side_effect=failed_publish):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("publication failure was accepted")
        after = os.lstat(fixture.destination)
        check(fixture.destination.read_bytes() == old_bytes
              and (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino)
              and fixture.fake.loaded and fixture.residue() == [],
              "publication failure did not preserve the exact prior file and loaded state")
    finally:
        fixture.close()

# A real handled SIGTERM after bootout enters rollback and leaves no residue.
with tempfile.TemporaryDirectory(prefix="launch-agent-signal-rollback-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    sent = {"value": False}

    def signal_during_publish(unused_candidate):
        check(not sent["value"], "signal publication fixture repeated")
        sent["value"] = True
        os.kill(os.getpid(), signal.SIGTERM)
        raise SystemExit("handled SIGTERM did not interrupt publication")

    try:
        with mock.patch.object(module, "_publish", side_effect=signal_during_publish):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("handled SIGTERM was accepted")
        check(sent["value"] and fixture.destination.read_bytes() == old_bytes
              and fixture.fake.loaded and fixture.residue() == [],
              "handled SIGTERM did not restore exact prior loaded state")
    finally:
        fixture.close()

# A publication durability failure after replacement restores the prior bytes and loaded state.
with tempfile.TemporaryDirectory(prefix="launch-agent-post-publication-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    original_fsync = module._fsync_directory
    fsync_calls = {"count": 0}

    def failed_first_fsync(directory):
        fsync_calls["count"] += 1
        if fsync_calls["count"] == 1:
            raise module.InstallFailure()
        return original_fsync(directory)

    try:
        with mock.patch.object(module, "_fsync_directory", side_effect=failed_first_fsync):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("post-replacement publication failure was accepted")
        check(fixture.destination.read_bytes() == old_bytes and fixture.fake.loaded
              and fixture.residue() == [],
              "post-replacement publication failure did not restore prior state")
    finally:
        fixture.close()

# Bootstrap failure rolls back exact bytes/mode and loaded state for loaded, unloaded, and absent targets.
for prior_name, loaded, previous in (
        ("loaded", True, old_bytes),
        ("unloaded", False, old_bytes),
        ("absent", False, None)):
    with tempfile.TemporaryDirectory(prefix="launch-agent-bootstrap-rollback-test.") as raw:
        fixture = Fixture(raw, loaded=loaded, previous=previous, fail_bootstrap=1)
        try:
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("bootstrap failure was accepted: " + prior_name)
            check(fixture.destination.exists() == (previous is not None),
                  "bootstrap rollback restored wrong target presence: " + prior_name)
            if previous is not None:
                check(fixture.destination.read_bytes() == previous
                      and stat.S_IMODE(fixture.destination.stat().st_mode) == 0o644,
                      "bootstrap rollback did not restore exact file: " + prior_name)
            check(fixture.fake.loaded == loaded and fixture.residue() == [],
                  "bootstrap rollback did not restore launch state or cleanup: " + prior_name)
        finally:
            fixture.close()

# A configured bar-shape mismatch is inside the transaction and restores the prior job.
with tempfile.TemporaryDirectory(prefix="launch-agent-bar-shape-rollback-test.") as raw:
    fixture = Fixture(raw, loaded=True, previous=old_bytes)
    try:
        with mock.patch.object(
                module, "_bounded_bar_query",
                return_value=module.CommandResult(0, bar_output(height=25))), \
                mock.patch.object(module, "LAUNCHCTL_TIMEOUT_SECONDS", 0.25):
            try:
                fixture.install()
            except module.InstallFailure:
                pass
            else:
                raise SystemExit("wrong configured bar shape was accepted")
        check(fixture.destination.read_bytes() == old_bytes and fixture.fake.loaded
              and fixture.fake.contract_data == old_bytes and fixture.residue() == [],
              "wrong configured bar shape did not restore exact prior loaded job")
    finally:
        fixture.close()

# A live readback mismatch after successful bootstrap also restores the prior loaded target.
with tempfile.TemporaryDirectory(prefix="launch-agent-readback-rollback-test.") as raw:
    # Loaded print 8 starts the reviewed contract readback after both stable rollback preflights and bootstrap.
    fixture = Fixture(raw, loaded=True, previous=old_bytes, bad_live_print=8)
    try:
        try:
            with mock.patch.object(module, "LAUNCHCTL_TIMEOUT_SECONDS", 0.25):
                fixture.install()
        except module.InstallFailure:
            pass
        else:
            raise SystemExit("live contract readback failure was accepted")
        check(fixture.destination.read_bytes() == old_bytes and fixture.fake.loaded
              and fixture.residue() == [],
              "live readback failure did not restore exact prior loaded state")
    finally:
        fixture.close()

# Successful publication has exact bytes, safe logs, loaded state, and no transaction residue.
with tempfile.TemporaryDirectory(prefix="launch-agent-success-test.") as raw:
    fixture = Fixture(raw, previous=old_bytes)
    try:
        fixture.install()
        info = os.lstat(fixture.destination)
        check(fixture.destination.read_bytes() == reviewed_bytes
              and stat.S_ISREG(info.st_mode) and info.st_nlink == 1
              and stat.S_IMODE(info.st_mode) == 0o644
              and fixture.fake.loaded and fixture.residue() == [],
              "successful LaunchAgent publication contract failed")
        for path in module.LOG_FILES:
            log_info = os.lstat(path)
            check(stat.S_ISREG(log_info.st_mode) and log_info.st_nlink == 1
                  and stat.S_IMODE(log_info.st_mode) == 0o600,
                  "successful install left an unsafe log file")
    finally:
        fixture.close()

# CLI output is a closed fixed vocabulary and never contains launchctl or process data.
old_argv = sys.argv
try:
    cases = (
        ([os.fspath(installer_path), "unexpected"], None, 64, "", module.FAILURE_MESSAGE + "\n"),
        ([os.fspath(installer_path)], module.InstallFailure(), 1, "", module.FAILURE_MESSAGE + "\n"),
        ([os.fspath(installer_path)], module.RollbackFailure(), 2, "", module.ROLLBACK_FAILURE_MESSAGE + "\n"),
        ([os.fspath(installer_path)], None, 0, module.SUCCESS_MESSAGE + "\n", ""),
    )
    for arguments, failure, expected_status, expected_stdout, expected_stderr in cases:
        sys.argv = arguments
        stdout = io.StringIO()
        stderr = io.StringIO()
        replacement = mock.Mock(side_effect=failure) if failure is not None else mock.Mock()
        with mock.patch.object(module, "install", replacement), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = module.main()
        check(status == expected_status and stdout.getvalue() == expected_stdout
              and stderr.getvalue() == expected_stderr,
              "closed CLI verdict output changed")
finally:
    sys.argv = old_argv

print("SketchyBar LaunchAgent install contracts passed")
