#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

sources=(Sources/PublicStats/*.swift)
forbidden='IOReport|AppleSMC|SMC(Open|Close|Read|Write|Call)|IOHIDEvent|IOHIDServiceClient|IORegistry|IOServiceMatching|IOServiceGetMatching|IOServiceOpen|IOConnectCall|currentAllocatedSize|MXGPUMetric|MTLCounterSampleBuffer|sampleCounters|powermetrics|ioreg|wdutil|fs_usage|nettop|smctemp|osx-cpu-temp|AuthorizationExecuteWithPrivileges|SMJobBless|posix_spawn|popen\(|system\(|execv|dlopen|dlsym|NSClassFromString|NSSelectorFromString|sel_registerName|CFBundleGetFunctionPointerForName|methodForSelector|performSelector|/usr/bin/sudo|/bin/sh|/bin/bash|/usr/bin/env|ProcessInfo\.globallyUniqueString'
if grep -En "$forbidden" "${sources[@]}"; then
  echo E_SOURCE_DENY >&2
  exit 1
fi
for fixture in Tests/AuditFixtures/private-*.fixture Tests/AuditFixtures/dynamic-call.fixture Tests/AuditFixtures/shell-call.fixture; do
  grep -Eq "$forbidden" "$fixture" || { echo E_NEGATIVE_FIXTURE >&2; exit 1; }
done

allowed='^(AppKit|Darwin|Dispatch|Foundation|IOKit\.ps|Metal|Network)$'
while IFS= read -r module; do
  if ! printf '%s\n' "$module" | grep -Eq "$allowed"; then
    echo E_IMPORT >&2
    exit 1
  fi
done < <(sed -nE 's/^import ([A-Za-z0-9_.]+)$/\1/p' "${sources[@]}" | sort -u)

if grep -l 'unsafeBitCast' "${sources[@]}" | grep -v '/BatterySampler.swift$' >/dev/null; then
  echo E_UNSAFE_BRIDGE >&2
  exit 1
fi
for token in ifa_name 'interface.name'; do
  if grep -l "$token" "${sources[@]}" | grep -v '/NetworkSampler.swift$' >/dev/null; then
    echo E_NETWORK_IDENTITY_SCOPE >&2
    exit 1
  fi
done
if grep -El 'kIOPS[A-Za-z0-9]+Key' "${sources[@]}" | grep -v '/BatterySampler.swift$' >/dev/null; then
  echo E_BATTERY_DICTIONARY_SCOPE >&2
  exit 1
fi
if grep -l 'IOPSGetPowerSourceDescription' "${sources[@]}" | grep -v '/BatterySampler.swift$' >/dev/null; then
  echo E_BATTERY_DESCRIPTION_SCOPE >&2
  exit 1
fi
expected_battery_keys=$(printf '%s\n' \
  kIOPSCurrentCapacityKey kIOPSIsChargingKey kIOPSMaxCapacityKey \
  kIOPSPowerSourceStateKey kIOPSTimeToEmptyKey kIOPSTimeToFullChargeKey | sort)
actual_battery_keys=$(grep -Eo 'kIOPS[A-Za-z0-9]+Key' Sources/PublicStats/BatterySampler.swift | sort -u)
[[ "$actual_battery_keys" == "$expected_battery_keys" ]] || { echo E_BATTERY_KEY_ALLOWLIST >&2; exit 1; }
if printf '%s\n' "$expected_battery_keys" | grep -q "$(cat Tests/AuditFixtures/battery-identity.fixture | grep -Eo 'kIOPS[A-Za-z0-9]+Key')"; then
  echo E_BATTERY_NEGATIVE_FIXTURE >&2
  exit 1
fi
if grep -l 'Process()' "${sources[@]}" | grep -v '/EventEmitter.swift$' >/dev/null; then
  echo E_PROCESS_SCOPE >&2
  exit 1
fi

current_sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -typecheck -warnings-as-errors -swift-version 6 -sdk "$current_sdk" \
  -target arm64-apple-macosx15.0 "${sources[@]}"
baseline_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
[[ -d "$baseline_sdk" ]] || { echo E_BASELINE_SDK >&2; exit 1; }
xcrun swiftc -typecheck -warnings-as-errors -swift-version 6 -sdk "$baseline_sdk" \
  -target arm64-apple-macosx15.0 "${sources[@]}"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/public-stats-audit.XXXXXX")
chmod 700 "$scratch"
cleanup() {
  chmod -R u+w "$scratch" 2>/dev/null || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT HUP INT TERM
xcrun swift build \
  --package-path "$PWD" \
  --scratch-path "$scratch/build" \
  --configuration release \
  --triple arm64-apple-macosx15.0 \
  -Xswiftc -warnings-as-errors

binary=$scratch/build/arm64-apple-macosx/release/sketchybar-public-stats
[[ -x "$binary" ]] || { echo E_BINARY >&2; exit 1; }
file "$binary" | grep -q 'arm64' || { echo E_ARCH >&2; exit 1; }
if nm -u "$binary" | grep -E '_IOReport|_IOHID|_IORegistry|_IOService|_IOConnect|_dlopen|_dlsym|_popen|_system$|_execv|_posix_spawn' >/dev/null; then
  echo E_SYMBOL_DENY >&2
  exit 1
fi
if strings -a "$binary" | grep -E 'IOReport|AppleSMC|IOHIDEvent|IOHIDServiceClient|IORegistry|IOServiceMatching|IOServiceGetMatching|IOServiceOpen|IOConnectCall|currentAllocatedSize|MXGPUMetric|MTLCounterSampleBuffer|powermetrics|ioreg|wdutil|fs_usage|nettop|smctemp|osx-cpu-temp|/usr/bin/sudo|/bin/sh|/bin/bash' >/dev/null; then
  echo E_STRING_DENY >&2
  exit 1
fi
expected_linker_frameworks=$(printf '%s\n' AppKit IOKit Metal Network | sort)
actual_linker_frameworks=$(sed -nE 's/.*\.linkedFramework\("([A-Za-z0-9_]+)"\).*/\1/p' Package.swift | sort -u)
[[ "$actual_linker_frameworks" == "$expected_linker_frameworks" ]] || { echo E_PACKAGE_LINKER_DENY >&2; exit 1; }
if otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/Frameworks/|/usr/lib/|@rpath/libswift)' >/dev/null; then
  echo E_LINK_DENY >&2
  exit 1
fi
if otool -L "$binary" | grep -q '/System/Library/PrivateFrameworks/'; then
  echo E_PRIVATE_FRAMEWORK >&2
  exit 1
fi

manifest=$scratch/build/arm64-apple-macosx/release/PublicStats_PublicStats.bundle/PrivacyInfo.xcprivacy
[[ -f "$manifest" ]] || { echo E_PRIVACY_MISSING >&2; exit 1; }
plutil -lint "$manifest" >/dev/null
plutil -extract NSPrivacyAccessedAPITypes xml1 -o - "$manifest" | grep -q NSPrivacyAccessedAPICategoryDiskSpace
plutil -extract NSPrivacyAccessedAPITypes xml1 -o - "$manifest" | grep -q 85F4.1

self_test_output=$($binary --self-test)
printf '%s\n' "$self_test_output" | Tests/validate-self-test.py

echo AUDIT_OK
