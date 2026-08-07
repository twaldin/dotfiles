#!/bin/sh
set -eu
/usr/bin/python3 - <<'PY'
import subprocess
import time
start = time.monotonic()
result = subprocess.run(["/usr/bin/perl", "-e", "alarm 1; exec @ARGV or exit 127", "/bin/sleep", "10"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
elapsed = time.monotonic() - start
if result.returncode == 0:
    raise SystemExit("Alarm-wrapped hung provider unexpectedly succeeded")
if not 0.5 <= elapsed < 3.0:
    raise SystemExit("Alarm-wrapped provider did not stop within its wall timeout")
PY
echo "Calendar provider alarm timeout passed"
