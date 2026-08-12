#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

sources=(Sources/PublicStats/*.swift)
[[ ${#sources[@]} -eq 13 ]] || { echo E_SOURCE_COUNT >&2; exit 1; }

forbidden='IOReport|AppleSMC|SMC(Open|Close|Read|Write|Call)|IOHIDEvent|IOHIDServiceClient|IORegistryEntry(CreateCFProperties|GetName|GetNameInPlane|GetPath|GetRegistryEntryID|SearchCFProperty|CreateIterator)|IOService(Matching|NameMatching|GetMatching|Open)|IOConnectCall|currentAllocatedSize|MXGPUMetric|MTLCounterSampleBuffer|sampleCounters|hw\.perflevel|powermetrics|ioreg|wdutil|fs_usage|nettop|smctemp|osx-cpu-temp|system_profiler|sppower_|pmset|libproc|proc_pid|KERN_PROCARGS2|x-apple\.systempreferences|/usr/bin/shortcuts|IOPMSleepSystem|AuthorizationExecuteWithPrivileges|SMJobBless|posix_spawn|popen\(|system\(|execv|dlopen|dlsym|NSClassFromString|NSSelectorFromString|sel_registerName|CFBundleGetFunctionPointerForName|methodForSelector|performSelector|/usr/bin/sudo|/bin/sh|/bin/bash|/usr/bin/env|ProcessInfo\.globallyUniqueString'
if grep -En "$forbidden" "${sources[@]}"; then
  echo E_SOURCE_DENY >&2
  exit 1
fi
[[ -f Sources/PublicStats/StorageIOSampler.swift ]] || { echo E_STORAGE_IO_SOURCE >&2; exit 1; }
[[ ! -e ../../scripts/gpu-usage.py ]] || { echo E_GPU_ACTIVITY_SOURCE >&2; exit 1; }
grep -Fq 'system_metrics_v3' Sources/PublicStats/Contract.swift || { echo E_METRICS_V3_EVENT >&2; exit 1; }
if grep -R -F 'system_metrics_v2' Sources Tests ../../init.lua ../../lib/stats_contract.lua ../../items/status.lua >/dev/null; then
  echo E_METRICS_V2_RETAINED >&2
  exit 1
fi
if grep -Fq 'gpu-usage.py' ../../items/status.lua; then
  echo E_GPU_ACTIVITY_CONSUMER >&2
  exit 1
fi
grep -Fq 'system_cpu_detail_v1' Sources/PublicStats/Contract.swift || { echo E_CPU_DETAIL_EVENT >&2; exit 1; }
grep -Fq 'ProcessInfo.processInfo.systemUptime' Sources/PublicStats/Daemon.swift || { echo E_CPU_UPTIME_SOURCE >&2; exit 1; }
grep -Fq 'host_processor_info' Sources/PublicStats/PerCoreCPUSampler.swift || { echo E_CPU_CORE_SOURCE >&2; exit 1; }
for fixture in Tests/AuditFixtures/private-*.fixture \
               Tests/AuditFixtures/dynamic-call.fixture \
               Tests/AuditFixtures/shell-call.fixture \
               Tests/AuditFixtures/power-command.fixture \
               Tests/AuditFixtures/settings-deeplink.fixture; do
  grep -Eq "$forbidden" "$fixture" || { echo E_NEGATIVE_FIXTURE >&2; exit 1; }
done
grep -q '/System/Library/PrivateFrameworks/' Tests/AuditFixtures/public-link-mutation.fixture || {
  echo E_LINK_NEGATIVE_FIXTURE >&2; exit 1;
}
if Tests/validate-privacy.py Tests/AuditFixtures/privacy-mutation.fixture >/dev/null 2>&1; then
  echo E_PRIVACY_NEGATIVE_FIXTURE >&2
  exit 1
fi

allowed='^(AppKit|Darwin|DiskArbitration|Dispatch|Foundation|IOKit|IOKit\.ps|Metal|Network|SystemConfiguration)$'
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
for token in PrimaryInterface 'State:/Network/Global/IPv4' if_nametoindex NET_RT_IFLIST2 RTM_IFINFO2; do
  if grep -l "$token" "${sources[@]}" | grep -v '/NetworkSampler.swift$' >/dev/null; then
    echo E_NETWORK_IDENTITY_SCOPE >&2
    exit 1
  fi
done
for token in DADiskGetBSDName Statistics 'Bytes (Read)' 'Bytes (Write)'; do
  if grep -l -F "$token" "${sources[@]}" | grep -v '/StorageIOSampler.swift$' >/dev/null; then
    echo E_STORAGE_IDENTITY_SCOPE >&2
    exit 1
  fi
done
if grep -l -F '/System/Volumes/Data' "${sources[@]}" \
    | grep -Ev '/(StorageIOSampler|VolumeSampler)\.swift$' >/dev/null; then
  echo E_STORAGE_PATH_SCOPE >&2
  exit 1
fi
expected_storage_calls=$(printf '%s
' \
  DADiskCopyIOMedia DADiskCreateFromVolumePath DASessionCreate \
  IOObjectIsEqualTo IOObjectRelease IORegistryEntryCreateCFProperty \
  IORegistryEntryGetParentEntry | sort)
actual_storage_calls=$(grep -Eo '(DADisk|DASession|IOObject|IORegistryEntry)[A-Za-z0-9]+\(' \
  Sources/PublicStats/StorageIOSampler.swift | tr -d '(' | sort -u)
[[ "$actual_storage_calls" == "$expected_storage_calls" ]] || { echo E_STORAGE_CALL_ALLOWLIST >&2; exit 1; }
expected_storage_literals=$(printf '%s
' '/System/Volumes/Data' 'Bytes (Read)' 'Bytes (Write)' Statistics | sort)
actual_storage_literals=$(grep -Eo '/System/Volumes/Data|Bytes \(Read\)|Bytes \(Write\)|Statistics' \
  Sources/PublicStats/StorageIOSampler.swift | sort -u)
[[ "$actual_storage_literals" == "$expected_storage_literals" ]] || { echo E_STORAGE_LITERAL_ALLOWLIST >&2; exit 1; }
expected_network_calls=$(printf '%s
' SCDynamicStoreCopyValue if_nametoindex sysctl | sort)
actual_network_calls=$(grep -Eo 'SCDynamicStoreCopyValue|if_nametoindex|sysctl' \
  Sources/PublicStats/NetworkSampler.swift | sort -u)
[[ "$actual_network_calls" == "$expected_network_calls" ]] || { echo E_NETWORK_CALL_ALLOWLIST >&2; exit 1; }
[[ $(grep -Fxc '        sysctlbyname("kern.memorystatus_vm_pressure_level", value, size, nil, 0)' \
  Sources/PublicStats/ConditionSampler.swift) -eq 2 ]] || { echo E_PRESSURE_CALL_ALLOWLIST >&2; exit 1; }
if grep -El 'kIOPS[A-Za-z0-9]+Key' "${sources[@]}" | grep -v '/BatterySampler.swift$' >/dev/null; then
  echo E_BATTERY_DICTIONARY_SCOPE >&2
  exit 1
fi
if grep -EIl 'IOPS(CopyPowerSourcesInfo|CopyPowerSourcesList|GetPowerSourceDescription|GetProvidingPowerSourceType|NotificationCreateRunLoopSource)' "${sources[@]}" | grep -v '/BatterySampler.swift$' >/dev/null; then
  echo E_BATTERY_API_SCOPE >&2
  exit 1
fi
expected_battery_keys=$(printf '%s\n' \
  kIOPSCurrentCapacityKey kIOPSIsChargedKey kIOPSIsChargingKey \
  kIOPSIsFinishingChargeKey kIOPSIsPresentKey kIOPSMaxCapacityKey \
  kIOPSPowerSourceStateKey kIOPSTimeToEmptyKey kIOPSTimeToFullChargeKey \
  kIOPSTypeKey | sort)
actual_battery_keys=$(grep -Eo 'kIOPS[A-Za-z0-9]+Key' Sources/PublicStats/BatterySampler.swift | sort -u)
[[ "$actual_battery_keys" == "$expected_battery_keys" ]] || { echo E_BATTERY_KEY_ALLOWLIST >&2; exit 1; }
for fixture in Tests/AuditFixtures/battery-identity.fixture Tests/AuditFixtures/battery-unapproved-key.fixture; do
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if grep -Fxq "$key" <<<"$actual_battery_keys"; then
      echo E_BATTERY_IDENTITY_KEY >&2
      exit 1
    fi
  done < <(grep -Eo 'kIOPS[A-Za-z0-9]+Key' "$fixture" | sort -u)
done
expected_providing_keys=$(printf '%s\n' kIOPMACPowerKey kIOPMBatteryPowerKey kIOPMUPSPowerKey | sort)
actual_providing_keys=$(grep -Eo 'kIOPM[A-Za-z0-9]+Key' Sources/PublicStats/BatterySampler.swift | sort -u)
[[ "$actual_providing_keys" == "$expected_providing_keys" ]] || { echo E_PROVIDING_KEY_ALLOWLIST >&2; exit 1; }
expected_source_values=$(printf '%s\n' kIOPSACPowerValue kIOPSBatteryPowerValue kIOPSOffLineValue | sort)
actual_source_values=$(grep -Eo 'kIOPS[A-Za-z0-9]+Value' Sources/PublicStats/BatterySampler.swift | sort -u)
[[ "$actual_source_values" == "$expected_source_values" ]] || { echo E_SOURCE_VALUE_ALLOWLIST >&2; exit 1; }
expected_source_types=$(printf '%s\n' kIOPSInternalBatteryType kIOPSUPSType | sort)
actual_source_types=$(grep -Eo 'kIOPS[A-Za-z0-9]+Type' Sources/PublicStats/BatterySampler.swift | sort -u)
[[ "$actual_source_types" == "$expected_source_types" ]] || { echo E_SOURCE_TYPE_ALLOWLIST >&2; exit 1; }
expected_battery_calls=$(printf '%s\n' \
  IOPSCopyPowerSourcesInfo IOPSCopyPowerSourcesList IOPSGetPowerSourceDescription \
  IOPSGetProvidingPowerSourceType IOPSNotificationCreateRunLoopSource | sort)
actual_battery_calls=$(grep -Eo 'IOPS[A-Za-z0-9]+\(' Sources/PublicStats/BatterySampler.swift | tr -d '(' | sort -u)
[[ "$actual_battery_calls" == "$expected_battery_calls" ]] || { echo E_BATTERY_CALL_ALLOWLIST >&2; exit 1; }
if grep -l 'Process()' "${sources[@]}" | grep -v '/EventEmitter.swift$' >/dev/null; then
  echo E_PROCESS_SCOPE >&2
  exit 1
fi
grep -Fq 'UUID().uuidString' Sources/PublicStats/Contract.swift || { echo E_INSTANCE_SOURCE >&2; exit 1; }
grep -Fq 'value.utf8.count == 32' Sources/PublicStats/Contract.swift || { echo E_INSTANCE_GRAMMAR >&2; exit 1; }
grep -Fq 'order &+= 1' Tests/AuditFixtures/pending-wrap.fixture || { echo E_PENDING_NEGATIVE_FIXTURE >&2; exit 1; }
if grep -Fq '&+=' Sources/PublicStats/EventEmitter.swift; then
  echo E_PENDING_WRAP >&2
  exit 1
fi
grep -Fq 'String(value.metricsSequence)' Tests/AuditFixtures/sequence-numeric.fixture || {
  echo E_SEQUENCE_NEGATIVE_FIXTURE >&2; exit 1;
}
if grep -Eq 'String\(value\.(metrics|cpuDetail|battery)Sequence\)' Sources/PublicStats/Contract.swift; then
  echo E_SEQUENCE_NUMERIC_SERIALIZATION >&2
  exit 1
fi
grep -Fq '"METRICS_SEQ", sequenceField(value.metricsSequence)' Sources/PublicStats/Contract.swift || {
  echo E_METRICS_SEQUENCE_GRAMMAR >&2; exit 1;
}
grep -Fq '"CPU_DETAIL_SEQ", sequenceField(value.cpuDetailSequence)' Sources/PublicStats/Contract.swift || {
  echo E_CPU_DETAIL_SEQUENCE_GRAMMAR >&2; exit 1;
}
grep -Fq '"BATTERY_SEQ", sequenceField(value.batterySequence)' Sources/PublicStats/Contract.swift || {
  echo E_BATTERY_SEQUENCE_GRAMMAR >&2; exit 1;
}
if grep -Eq 'SAMPLE_NS|system_(metrics|battery)_v1|system_metrics_v2' Sources/PublicStats/Contract.swift; then
  echo E_V2_SCHEMA_MUTATION >&2
  exit 1
fi

current_sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -typecheck -warnings-as-errors -swift-version 6 -sdk "$current_sdk" \
  -target arm64-apple-macosx15.0 "${sources[@]}"
baseline_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
[[ -d "$baseline_sdk" ]] || { echo E_BASELINE_SDK >&2; exit 1; }
xcrun swiftc -typecheck -warnings-as-errors -swift-version 6 -sdk "$baseline_sdk" \
  -target arm64-apple-macosx15.0 "${sources[@]}"

scratch=$(mktemp -d "${TMPDIR:?macOS per-user TMPDIR is required}/public-stats-audit.XXXXXX")
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
if nm -u "$binary" | grep -E '_IOReport|_IOHID|_IORegistryEntry(CreateCFProperties|GetName|GetPath|GetRegistryEntryID|SearchCFProperty|CreateIterator)|_IOService|_IOConnect|_dlopen|_dlsym|_popen|_system$|_execv|_posix_spawn|_proc_pid|_IOPMSleepSystem' >/dev/null; then
  echo E_SYMBOL_DENY >&2
  exit 1
fi
actual_binary_iops=$(nm -u "$binary" | sed -nE 's/.*_(IOPS[A-Za-z0-9]+).*/\1/p' | sort -u)
[[ "$actual_binary_iops" == "$expected_battery_calls" ]] || { echo E_BINARY_IOPS_ALLOWLIST >&2; exit 1; }
expected_new_read_symbols=$(printf '%s
' \
  DADiskCopyIOMedia DADiskCreateFromVolumePath DASessionCreate \
  IOObjectIsEqualTo IOObjectRelease IORegistryEntryCreateCFProperty IORegistryEntryGetParentEntry \
  SCDynamicStoreCopyValue if_nametoindex sysctl sysctlbyname | sort)
actual_new_read_symbols=$(nm -u "$binary" \
  | sed -nE 's/.*_(DADisk[A-Za-z0-9_]+|DASession[A-Za-z0-9_]+|IOObject[A-Za-z0-9_]+|IORegistryEntry[A-Za-z0-9_]+|SCDynamicStore[A-Za-z0-9_]+|if_nametoindex|sysctl|sysctlbyname)$/\1/p' \
  | sort -u)
[[ "$actual_new_read_symbols" == "$expected_new_read_symbols" ]] || {
  echo E_BINARY_NEW_READ_ALLOWLIST >&2
  exit 1
}
expected_sensitive_literals=$(printf '%s
' \
  '/System/Volumes/Data' PrimaryInterface 'State:/Network/Global/IPv4' | sort)
actual_sensitive_literals=$(strings -a "$binary" \
  | grep -E '^(/System/Volumes/Data|PrimaryInterface|State:/Network/Global/IPv[46])$' \
  | sort -u)
[[ "$actual_sensitive_literals" == "$expected_sensitive_literals" ]] || {
  echo E_BINARY_SENSITIVE_LITERAL_ALLOWLIST >&2
  exit 1
}
if strings -a "$binary" | grep -E 'IOReport|AppleSMC|IOHIDEvent|IOHIDServiceClient|IORegistryEntry(CreateCFProperties|GetName|GetPath|GetRegistryEntryID|SearchCFProperty|CreateIterator)|IOServiceMatching|IOServiceGetMatching|IOServiceOpen|IOConnectCall|currentAllocatedSize|MXGPUMetric|MTLCounterSampleBuffer|powermetrics|ioreg|wdutil|fs_usage|nettop|smctemp|osx-cpu-temp|system_profiler|sppower_|pmset|libproc|KERN_PROCARGS2|x-apple\.systempreferences|/usr/bin/shortcuts|/usr/bin/sudo|/bin/sh|/bin/bash' >/dev/null; then
  echo E_STRING_DENY >&2
  exit 1
fi
expected_linker_frameworks=$(printf '%s\n' AppKit DiskArbitration IOKit Metal Network SystemConfiguration | sort)
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
source_manifest=Sources/PublicStats/Resources/PrivacyInfo.xcprivacy
[[ -f "$manifest" ]] || { echo E_PRIVACY_MISSING >&2; exit 1; }
cmp -s "$source_manifest" "$manifest" || { echo E_PRIVACY_PACKAGE_MISMATCH >&2; exit 1; }
plutil -lint "$manifest" >/dev/null
Tests/validate-privacy.py "$manifest" || { echo E_PRIVACY_CONTENT >&2; exit 1; }
echo AUDIT_OK
