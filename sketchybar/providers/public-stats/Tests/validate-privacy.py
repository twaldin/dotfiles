#!/usr/bin/python3
import plistlib
import sys

if len(sys.argv) != 2:
    raise SystemExit(2)
try:
    with open(sys.argv[1], "rb") as handle:
        document = plistlib.load(handle)
except (OSError, plistlib.InvalidFileException):
    raise SystemExit(1)
expected = {
    "NSPrivacyTracking": False,
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyAccessedAPITypes": [{
        "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace",
        "NSPrivacyAccessedAPITypeReasons": ["85F4.1"],
    }],
}
raise SystemExit(0 if document == expected else 1)
