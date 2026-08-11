#!/usr/bin/env python3
import hashlib
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
settings = root / "settings.lua"
pattern = re.compile(r'(release_fingerprint\s*=\s*")[0-9a-f]{64}("\s*,)')

def runtime_paths():
    values = [root / "sketchybarrc", root / "install-deps.sh"]
    values.extend(path for path in root.glob("*.lua") if path.is_file())
    for directory in (root / "items", root / "lib"):
        values.extend(path for path in directory.rglob("*.lua") if path.is_file())
    scripts = root / "scripts"
    values.extend(path for path in scripts.rglob("*")
                  if path.is_file() and path.suffix in {".py", ".sh", ".swift"})
    provider = root / "providers" / "public-stats"
    values.append(provider / "Package.swift")
    values.extend(path for path in (provider / "Sources").rglob("*") if path.is_file())
    values.extend(path for path in (root / "launch-agents").glob("*.plist") if path.is_file())
    return sorted(set(values), key=lambda path: path.relative_to(root).as_posix())

required_runtime_paths = {
    root / "install-deps.sh",
    root / "scripts/audio-state.py",
    root / "scripts/battery-state.py",
    root / "scripts/battery-state.swift",
    root / "scripts/connectivity-state.py",
    root / "scripts/provider-launch.sh",
    root / "scripts/provider-log.py",
    root / "scripts/secure-file-install.py",
    root / "scripts/system-controls.swift",
    root / "providers/public-stats/Package.swift",
    root / "launch-agents/homebrew.mxcl.sketchybar.plist",
}
missing_runtime_paths = required_runtime_paths.difference(runtime_paths())
if missing_runtime_paths:
    raise SystemExit("release fingerprint omits required production sources")


def normalized(path):
    data = path.read_bytes()
    if path == settings:
        text = data.decode("utf-8")
        text, count = pattern.subn(r'\g<1>' + ("0" * 64) + r'\g<2>', text)
        if count != 1:
            raise SystemExit("release fingerprint declaration shape")
        data = text.encode("utf-8")
    return data

def digest():
    value = hashlib.sha256()
    for path in runtime_paths():
        relative = path.relative_to(root).as_posix().encode("utf-8")
        data = normalized(path)
        value.update(len(relative).to_bytes(4, "big"))
        value.update(relative)
        value.update(len(data).to_bytes(8, "big"))
        value.update(data)
    return value.hexdigest()

settings_text = settings.read_text()
match = pattern.search(settings_text)
if not match:
    raise SystemExit("release fingerprint declaration missing")
expected = match.group(0).split('"')[1]
actual = digest()
if expected != actual:
    raise SystemExit(f"release fingerprint mismatch: expected {actual}")
print("SketchyBar runtime source fingerprint passed")
