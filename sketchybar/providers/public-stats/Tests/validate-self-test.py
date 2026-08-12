#!/usr/bin/python3
import json
import sys

try:
    document = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
if set(document) != {"checks", "ok", "schema"}:
    raise SystemExit(1)
if document["ok"] is not True or document["schema"] != 3:
    raise SystemExit(1)
checks = document["checks"]
expected = {
    "battery", "conditions", "cpu", "cpu_detail", "memory_pressure", "metal",
    "network_counters", "network_path", "storage_io", "swap", "vm", "volume",
}
if set(checks) != expected:
    raise SystemExit(1)
allowed = {
    "battery": {"present", "absent", "unavailable", "ambiguous"},
    "conditions": {"closed_read"},
    "cpu": {"ok"},
    "cpu_detail": {"ok"},
    "memory_pressure": {"ok"},
    "metal": {"ok", "absent"},
    "network_counters": {"ok", "unavailable"},
    "network_path": {"ok"},
    "storage_io": {"ok"},
    "swap": {"ok", "unavailable"},
    "vm": {"ok"},
    "volume": {"ok"},
}
if any(value not in allowed[key] for key, value in checks.items()):
    raise SystemExit(1)
encoded = json.dumps(document, sort_keys=True).lower()
identity_terms = (
    "pid", "process", "interface", "address", "device", "serial",
    "registry", "hostname", "username", "executable", "command",
)
if any(term in encoded for term in identity_terms):
    raise SystemExit(1)
