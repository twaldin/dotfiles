#!/usr/bin/env python3
"""Fail-closed, source-only guard for the approved native artifact fan-in."""

import ast
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess


EXPECTED_QUERY_TUPLE = (
    "calendar",
    "calendar.event.bracket",
    "calendar.date.bracket",
    "system.bracket",
    "release.probe",
)
EXPECTED_SMOKE_QUERY_ORDER = (
    "calendar.event.bracket",
    "calendar.date.bracket",
    "system.bracket",
    "calendar",
    "release.probe",
)

EXPECTED_RUNTIME_SURFACES = ('sketchybar/OPERATIONS.md',
 'sketchybar/THIRD_PARTY.md',
 'sketchybar/bar.lua',
 'sketchybar/bootstrap.lua',
 'sketchybar/colors.lua',
 'sketchybar/default.lua',
 'sketchybar/init.lua',
 'sketchybar/install-deps.sh',
 'sketchybar/launch-agents/homebrew.mxcl.sketchybar.plist',
 'sketchybar/items/audio.lua',
 'sketchybar/items/battery.lua',
 'sketchybar/items/calendar.lua',
 'sketchybar/items/connectivity.lua',
 'sketchybar/items/display.lua',
 'sketchybar/items/front_window.lua',
 'sketchybar/items/init.lua',
 'sketchybar/items/microphone.lua',
 'sketchybar/items/status.lua',
 'sketchybar/items/workspaces.lua',
 'sketchybar/lib/audio.lua',
 'sketchybar/lib/calendar.lua',
 'sketchybar/lib/calendar_bar_layout.lua',
 'sketchybar/lib/calendar_width_ranges.lua',
 'sketchybar/lib/fan_power_control.lua',
 'sketchybar/lib/hardware_contract.lua',
 'sketchybar/lib/hover.lua',
 'sketchybar/lib/icons.lua',
 'sketchybar/lib/popup.lua',
 'sketchybar/lib/shell.lua',
 'sketchybar/lib/stats_contract.lua',
 'sketchybar/lib/text.lua',
 'sketchybar/lib/text_ranges.lua',
 'sketchybar/lib/unicode_grapheme_ranges.lua',
 'sketchybar/lib/window_pages.lua',
 'sketchybar/privileged/fan-power-owner/LaunchDaemon.plist',
 'sketchybar/privileged/fan-power-owner/Package.swift',
 'sketchybar/privileged/fan-power-owner/README.md',
 'sketchybar/privileged/fan-power-owner/RELEASE-MANIFEST.sha256',
 'sketchybar/privileged/fan-power-owner/ReleaseBinding.swift.in',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerClient/App.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerCore/Models.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerCore/OwnerController.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerCore/PMSetBackend.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerCore/RequestCodec.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerDaemon/App.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerDaemon/AppleSMCFanHardware.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerDaemon/PeerAuthenticator.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerDaemon/PowerWakeMonitor.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerDaemon/ReleaseBinding.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerDaemon/ResponseCodec.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerDaemon/SocketServer.swift',
 'sketchybar/privileged/fan-power-owner/Sources/FanPowerDaemon/SystemPMSetRunner.swift',
 'sketchybar/privileged/fan-power-owner/audit/mutation_test.py',
 'sketchybar/privileged/fan-power-owner/audit/source_audit.py',
 'sketchybar/privileged/fan-power-owner/install.sh',
 'sketchybar/privileged/fan-power-owner/scripts/verify.sh',
 'sketchybar/providers/public-stats/Package.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/BatterySampler.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/ConditionSampler.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/Contract.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/Daemon.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/EventEmitter.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/MachSampler.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/Main.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/MetalSampler.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/NetworkSampler.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/PerCoreCPUSampler.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/Resources/PrivacyInfo.xcprivacy',
 'sketchybar/providers/public-stats/Sources/PublicStats/SelfTest.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/StorageIOSampler.swift',
 'sketchybar/providers/public-stats/Sources/PublicStats/VolumeSampler.swift',
 'sketchybar/providers/public-stats/audit-public-stats.sh',
 'sketchybar/providers/public-stats/run-tests.sh',
 'sketchybar/scripts/audio-state.py',
 'sketchybar/scripts/battery-hardware-state.py',
 'sketchybar/scripts/battery-hardware.swift',
 'sketchybar/scripts/battery-state.py',
 'sketchybar/scripts/battery-state.swift',
 'sketchybar/scripts/betterdisplay-control.swift',
 'sketchybar/scripts/connectivity-state.py',
 'sketchybar/scripts/connectivity-state.swift',
 'sketchybar/scripts/display-state.py',
 'sketchybar/scripts/fan-power-client.sh',
 'sketchybar/scripts/focus-space.sh',
 'sketchybar/scripts/focus-window.sh',
 'sketchybar/scripts/generate-unicode-grapheme-ranges.py',
 'sketchybar/scripts/hardware-metrics-bridge.h',
 'sketchybar/scripts/hardware-metrics.swift',
 'sketchybar/scripts/hardware-state.py',
 'sketchybar/scripts/provider-launch.sh',
 'sketchybar/scripts/provider-log.py',
 'sketchybar/scripts/secure-file-install.py',
 'sketchybar/scripts/sketchybar-launch-agent.py',
 'sketchybar/scripts/smoke-config.sh',
 'sketchybar/scripts/system-controls-helper-install-transaction.sh',
 'sketchybar/scripts/system-controls.swift',
 'sketchybar/scripts/yabai-guard.py',
 'sketchybar/scripts/yabai-windows.sh',
 'sketchybar/settings.lua',
 'sketchybar/sketchybarrc',
 'sketchybar/vendor/unicode/17.0.0/DerivedCoreProperties.txt',
 'sketchybar/vendor/unicode/17.0.0/GraphemeBreakProperty.txt',
 'sketchybar/vendor/unicode/17.0.0/LICENSE.txt',
 'sketchybar/vendor/unicode/17.0.0/emoji-data.txt')


# Exact reviewed runtime integration. The vendored power artifact remains
# source-only; this independently reviewed helper may use only these closed
# contract names, and any byte change invalidates the approval.
APPROVED_RUNTIME_REFERENCE_PINS = {
    "sketchybar/scripts/battery-state.swift": {
        "sha256": "6480561f5e7481f6f4b8af5d802fbd2face75c5033766b3c8439321a1f4f8d04",
        "allowed": frozenset({
            "batteryhealth", "closedvalue", "inventorystate",
            "strictcfbridge", "strictvalue", "valuestate",
        }),
    },
}

VENDOR_REFERENCE_TOKENS = ('actionregistration',
 'activepowersource',
 'activetimercontract',
 'activetimermeaning',
 'activetimervalues',
 'adaptercontract',
 'adapterdictionary',
 'adapterstate',
 'aggregatetimecontract',
 'aggregatetimestate',
 'allowedwindowfield',
 'anonymousdisplay',
 'anonymousdisplaypowersnapshot',
 'anonymousmirrorstate',
 'anonymouswindowinventory',
 'anonymouswindowrow',
 'appearancefacts',
 'appkitgeometry',
 'applepublicsurfacematrix',
 'applicationresource',
 'batterycondition',
 'batteryhealth',
 'betterdisplaycapabilitymatrix',
 'betterdisplaycapabilityrow',
 'betterdisplaycontract',
 'betterdisplayfuturewriteevidence',
 'betterdisplaylicenserequirement',
 'betterdisplayreaddisposition',
 'betterdisplaywritedisposition',
 'betterdisplaywritegateevaluator',
 'bindingsmodel',
 'callbackbox',
 'capacityanalysis',
 'closedsleeptransition',
 'closedvalue',
 'coarseonlinedisplaycount',
 'colorfacts',
 'confirmedsnapshotcoordinator',
 'contractconstants',
 'controlrow',
 'coregraphicsboundary',
 'cycledictionary',
 'darwinpublicbindings',
 'darwinpublicpowerbindings',
 'darwinpublicpowerobservationbackend',
 'darwinsystemsettingsapplicationopener',
 'dispatchresult',
 'displayaggregate',
 'displayapplyresult',
 'displayconfiguration',
 'displayconfigurationscope',
 'displaylistfunction',
 'displaymutationgate',
 'displaypoweraggregate',
 'displaysnapshot',
 'edrfacts',
 'electricalcontract',
 'energycontract',
 'entitlementevidence',
 'errorsink',
 'evidencereason',
 'evidencestatus',
 'exactgateevidence',
 'failurecategory',
 'failurecontract',
 'failurestate',
 'fallbackaction',
 'fallbackcontract',
 'fallbackmessage',
 'fallbackrow',
 'fallbackstate',
 'forbiddenactioncounters',
 'freshnesscontract',
 'freshnessstate',
 'generationclock',
 'healthcontract',
 'insetsvalue',
 'installerlifecycledesign',
 'invalidationevent',
 'invalidationregistration',
 'inventorycontract',
 'inventorystate',
 'inventorysummary',
 'keepawakeandworkspaces',
 'keepawakeboundary',
 'keepawakecoordinator',
 'keepawakeresult',
 'launchcompletion',
 'lifecyclecontract',
 'loadadvisorycontract',
 'loadadvisoryraw',
 'loadlevel',
 'lockstateread',
 'lowbatterywarning',
 'mainactorinvalidationbox',
 'mainqueuerefreshscheduler',
 'mirroractionresult',
 'mirroredge',
 'mirroring',
 'mirroringcoordinator',
 'modesemantickey',
 'modevalue',
 'monotonicclock',
 'mutationcontractdesign',
 'nativedisplayentry',
 'nativedisplaysnapshot',
 'nativesnapshotgeneration',
 'nativewindowidentity',
 'nativewindowrecord',
 'nativewmsnapshot',
 'observationdriver',
 'opaquedisplayhandle',
 'opaquedisplaymode',
 'ownedawakestate',
 'policysurface',
 'popupgeneration',
 'popuptruthrow',
 'powercontract',
 'powerdetailagent',
 'powerdetailinvalidation',
 'powerobservationmode',
 'powersourcefield',
 'powersourcesnapshot',
 'previewcancellationreason',
 'previewlease',
 'privatedisplaytoken',
 'privateresourceidentity',
 'privatewindowcontent',
 'publicappmediastate',
 'publicbindings',
 'publiccoregraphicsboundary',
 'publiccoregraphicsboundaryerror',
 'publicdisplaybindings',
 'publicinvalidationbindings',
 'publicpowerbindings',
 'publicpowerdetail',
 'publicpowerdetaildocument',
 'publicpowerdetailreader',
 'publicpowererror',
 'publicpowerobservationbackend',
 'publicpowerobservationdriver',
 'publicrawmodekey',
 'publicread',
 'publicrows',
 'publicsurfacerow',
 'publicsurfacestate',
 'rawappearance',
 'rawappkitfacts',
 'rawcolorfacts',
 'rawdisplay',
 'rawmode',
 'rawpublicsnapshot',
 'rectvalue',
 'refreshfacts',
 'refreshscheduling',
 'refreshsink',
 'remainingcontrolscore',
 'remainingcontrolslifecycle',
 'remainingcontrolslifecycleevent',
 'remainingcontrolsmacboundaries',
 'requiredpopuptruth',
 'reservedshortcutslot',
 'rowdispatcher',
 'rowrole',
 'schedulecontract',
 'schedulemanagement',
 'sealedhandoffdestination',
 'sealedhandoffplan',
 'sealedsystemsettingsboundary',
 'sealedsystemsettingsboundaryerror',
 'sessioncontract',
 'sessiontransition',
 'settingscontract',
 'settingskey',
 'settingslaunchresult',
 'settingsoperation',
 'settingspaneclaim',
 'settingssemanticaction',
 'settingstarget',
 'shortcutallowlist',
 'shortcutattemptresult',
 'shortcutcoordinator',
 'shortcutsandlifecycle',
 'singlewindowtransition',
 'sleepcapability',
 'sleepcapabilitystate',
 'sleepdisplaycontract',
 'sleepreadboundary',
 'sleepreadonly',
 'sleepreadonlycoordinator',
 'snapshotcoordinator',
 'snapshotnormalizer',
 'sourceanalysis',
 'sourcetimecontract',
 'sourcetimes',
 'sourcetimestate',
 'strictcfbridge',
 'strictjson',
 'strictpowersource',
 'strictsnapshotjson',
 'strictvalue',
 'systeminvalidationregistration',
 'systemmonotonicclock',
 'systempublicbindings',
 'systempublicdisplaybindings',
 'systempublicinvalidationbindings',
 'systemsettings',
 'systemsettingsapplicationopening',
 'systemsettingsboundary',
 'systemsettingscommand',
 'systemsettingscoordinator',
 'systemsettingslaunchcommand',
 'systemtransition',
 'timeranalysis',
 'topologyfacts',
 'undolease',
 'unsupportedrows',
 'unsupportedsurfaces',
 'useclass',
 'valuestate',
 'vendorcommand',
 'vendorcommandresult',
 'viewgeneration',
 'windowmanager',
 'windowmanagercoordinator',
 'windowmanagerpolicy',
 'windowpanelsession',
 'windowslot',
 'wmactionresult',
 'wmdirection',
 'wmmutationgate',
 'workspacepresentation',
 'workspacepresentationrow',
 'writegatedecision',
 'yabaiboundary')

EXPECTED_PHASES = {
    "binding": {
        "approved_plan_sha256": "62b6c8f8955e11b24b9771d14937b6620ea40c5cd4b0a8711a43883211c71bc9",
        "final_codex_stdout_review_sha256": "df73944445cc078e405a588d424bd3ba965f0ef1e4dc98eb50a879cb1d525fdd",
    },
    "approvals": ({'artifact': 'public-power-detail',
  'destination': 'vendor/public-power-detail',
  'manifest': 'MANIFEST.sha256',
  'manifest_sha256': 'ba85e0a9b5084c1e317dc9636ffdfbb815fcbbc9135a902be061915e23bb5d8b',
  'same_byte_review_sha256': '5b918a625d2c61ef142b29dba69cc3b84970cd0e5002b61971e795b054093059',
  'external_tree_sha256': None,
  'supplementals': ()},
 {'artifact': 'display-public-detail',
  'destination': 'vendor/display-public-detail',
  'manifest': 'SOURCE-MANIFEST.sha256',
  'manifest_sha256': 'd4dddf0ec161da8421ae08706ac75c79d6b54affe51d9cccfc6b5bd4230c22e6',
  'same_byte_review_sha256': '79a01e8e6c7cae924eaa67c65198f3802268e4681299878f2da6e1ba89042547',
  'external_tree_sha256': 'd7cd6a00727a25ea76b0c45cfc35ff13a9956a1289be0ef41effabdbf432fde4',
  'supplementals': (('REPORT.md', 'b2c2f740a20572bf3703741bab7b937416a08dd3734afe21854b1ae00485fb67'),)},
 {'artifact': 'remaining-controls-v2',
  'destination': 'vendor/remaining-controls-v2',
  'manifest': 'SOURCE-MANIFEST.sha256',
  'manifest_sha256': 'b871e75315730a9beac0d59a0346ac70ef75eb4b629d77eaa493e024f1ca25d0',
  'same_byte_review_sha256': 'bd491660aafb0cec0a64d74ab1c0cce14a51e240b1e14587a6f883cdc81d31b1',
  'external_tree_sha256': None,
  'supplementals': (('REPORT.md', 'd18a21a2b317b2da1b2396d31c9d7c70c7efb62b502b95c6f4b56dbf6575208f'),
                    ('SHA256SUMS', 'c93f0ba36ae4667404a41b4a18e8ea09674360b5c7d177059a9b95d811331ace'))}),
    "files": (
        ('sketchybar/native/vendor/public-power-detail/MANIFEST.sha256', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Package.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/README.md', 0o644),
        ('sketchybar/native/vendor/public-power-detail/REPORT.md', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/shim.h', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/audit/NoLiveLinkProbe.swift', 0o644),
        ('sketchybar/native/vendor/public-power-detail/audit/manifest.py', 0o755),
        ('sketchybar/native/vendor/public-power-detail/audit/mutation_test.py', 0o755),
        ('sketchybar/native/vendor/public-power-detail/audit/source_only.py', 0o755),
        ('sketchybar/native/vendor/public-power-detail/audit/verify.py', 0o755),
        ('sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json', 0o644),
        ('sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json', 0o644),
        ('sketchybar/native/vendor/public-power-detail/docs/ATTENDED-GATES.md', 0o644),
        ('sketchybar/native/vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md', 0o644),
        ('sketchybar/native/vendor/public-power-detail/docs/SURFACE-MATRIX.md', 0o644),
        ('sketchybar/native/vendor/public-power-detail/scripts/verify.sh', 0o755),
        ('sketchybar/native/vendor/display-public-detail/README.md', 0o644),
        ('sketchybar/native/vendor/display-public-detail/REPORT.md', 0o644),
        ('sketchybar/native/vendor/display-public-detail/SOURCE-MANIFEST.sha256', 0o644),
        ('sketchybar/native/vendor/display-public-detail/Sources/BetterDisplayContract.swift', 0o644),
        ('sketchybar/native/vendor/display-public-detail/Sources/BindingsModel.swift', 0o644),
        ('sketchybar/native/vendor/display-public-detail/Sources/Contract.swift', 0o644),
        ('sketchybar/native/vendor/display-public-detail/Sources/PolicySurface.swift', 0o644),
        ('sketchybar/native/vendor/display-public-detail/Sources/SnapshotCoordinator.swift', 0o644),
        ('sketchybar/native/vendor/display-public-detail/Sources/StrictJSON.swift', 0o644),
        ('sketchybar/native/vendor/display-public-detail/Sources/SystemPublicBindings.swift', 0o644),
        ('sketchybar/native/vendor/display-public-detail/Tests/main.swift', 0o644),
        ('sketchybar/native/vendor/display-public-detail/scripts/policy_audit.py', 0o755),
        ('sketchybar/native/vendor/display-public-detail/scripts/verify.sh', 0o755),
        ('sketchybar/native/vendor/remaining-controls-v2/LIFECYCLE-DESIGN.md', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Package.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/README.md', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/REPORT.md', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/SHA256SUMS', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/SOURCE-MANIFEST.sha256', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/KeepAwakeAndWorkspaces.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/Mirroring.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/PublicRows.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/ShortcutsAndLifecycle.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/SleepReadOnly.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/SystemSettings.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/UnsupportedSurfaces.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/WindowManager.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/PublicCoreGraphicsBoundary.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/SealedSystemSettingsBoundary.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/BoundaryCompilationTests.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/Fakes.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/KeepAwakeWorkspaceTests.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/MirroringTests.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/RowsAndSettingsTests.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SelfTestMain.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SleepShortcutLifecycleTests.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/TestingCompatibility.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/WindowManagerTests.swift', 0o644),
        ('sketchybar/native/vendor/remaining-controls-v2/scripts/link_audit.py', 0o755),
        ('sketchybar/native/vendor/remaining-controls-v2/scripts/static_audit.py', 0o755),
        ('sketchybar/native/vendor/remaining-controls-v2/scripts/test.sh', 0o755),
    ),
    "states": ({'name': 'F1',
  'vendor_roots': ('public-power-detail',),
  'tsv': b'# approved-native-artifacts-v1\n# artifact\tdestination\trecord_kind\trelative_path\tsha256\tsame_byte_review_sha256\texternal_tree_sha256\npublic-p'
         b'ower-detail\tvendor/public-power-detail\tmanifest\tMANIFEST.sha256\tba85e0a9b5084c1e317dc9636ffdfbb815fcbbc9135a902be061915e23bb5d8b\t5b918a625d2'
         b'c61ef142b29dba69cc3b84970cd0e5002b61971e795b054093059\t-\n',
  'imported_files': ('sketchybar/native/vendor/public-power-detail/MANIFEST.sha256',
                     'sketchybar/native/vendor/public-power-detail/Package.swift',
                     'sketchybar/native/vendor/public-power-detail/README.md',
                     'sketchybar/native/vendor/public-power-detail/REPORT.md',
                     'sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap',
                     'sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/shim.h',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift',
                     'sketchybar/native/vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift',
                     'sketchybar/native/vendor/public-power-detail/audit/NoLiveLinkProbe.swift',
                     'sketchybar/native/vendor/public-power-detail/audit/manifest.py',
                     'sketchybar/native/vendor/public-power-detail/audit/mutation_test.py',
                     'sketchybar/native/vendor/public-power-detail/audit/source_only.py',
                     'sketchybar/native/vendor/public-power-detail/audit/verify.py',
                     'sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json',
                     'sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json',
                     'sketchybar/native/vendor/public-power-detail/docs/ATTENDED-GATES.md',
                     'sketchybar/native/vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md',
                     'sketchybar/native/vendor/public-power-detail/docs/SURFACE-MATRIX.md',
                     'sketchybar/native/vendor/public-power-detail/scripts/verify.sh'),
  'native_dirs': ('vendor',
                  'vendor/public-power-detail',
                  'vendor/public-power-detail/Sources',
                  'vendor/public-power-detail/Sources/CDarwinNotify',
                  'vendor/public-power-detail/Sources/PublicPowerDetail',
                  'vendor/public-power-detail/Tests',
                  'vendor/public-power-detail/Tests/PublicPowerDetailTests',
                  'vendor/public-power-detail/audit',
                  'vendor/public-power-detail/docs',
                  'vendor/public-power-detail/scripts'),
  'native_files': ('APPROVED-ARTIFACTS.tsv',
                   'vendor/public-power-detail/MANIFEST.sha256',
                   'vendor/public-power-detail/Package.swift',
                   'vendor/public-power-detail/README.md',
                   'vendor/public-power-detail/REPORT.md',
                   'vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap',
                   'vendor/public-power-detail/Sources/CDarwinNotify/shim.h',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift',
                   'vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift',
                   'vendor/public-power-detail/audit/NoLiveLinkProbe.swift',
                   'vendor/public-power-detail/audit/manifest.py',
                   'vendor/public-power-detail/audit/mutation_test.py',
                   'vendor/public-power-detail/audit/source_only.py',
                   'vendor/public-power-detail/audit/verify.py',
                   'vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json',
                   'vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json',
                   'vendor/public-power-detail/docs/ATTENDED-GATES.md',
                   'vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md',
                   'vendor/public-power-detail/docs/SURFACE-MATRIX.md',
                   'vendor/public-power-detail/scripts/verify.sh'),
  'readme_sha256': None},
 {'name': 'F2',
  'vendor_roots': ('public-power-detail', 'display-public-detail'),
  'tsv': b'# approved-native-artifacts-v1\n# artifact\tdestination\trecord_kind\trelative_path\tsha256\tsame_byte_review_sha256\texternal_tree_sha256\npublic-p'
         b'ower-detail\tvendor/public-power-detail\tmanifest\tMANIFEST.sha256\tba85e0a9b5084c1e317dc9636ffdfbb815fcbbc9135a902be061915e23bb5d8b\t5b918a625d2'
         b'c61ef142b29dba69cc3b84970cd0e5002b61971e795b054093059\t-\ndisplay-public-detail\tvendor/display-public-detail\tmanifest\tSOURCE-MANIFEST.sha256\td'
         b'4dddf0ec161da8421ae08706ac75c79d6b54affe51d9cccfc6b5bd4230c22e6\t79a01e8e6c7cae924eaa67c65198f3802268e4681299878f2da6e1ba89042547\td7cd6a00727a25e'
         b'a76b0c45cfc35ff13a9956a1289be0ef41effabdbf432fde4\ndisplay-public-detail\tvendor/display-public-detail\tsupplemental\tREPORT.md\tb2c2f740a20572bf'
         b'3703741bab7b937416a08dd3734afe21854b1ae00485fb67\t-\t-\n',
  'imported_files': ('sketchybar/native/vendor/public-power-detail/MANIFEST.sha256',
                     'sketchybar/native/vendor/public-power-detail/Package.swift',
                     'sketchybar/native/vendor/public-power-detail/README.md',
                     'sketchybar/native/vendor/public-power-detail/REPORT.md',
                     'sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap',
                     'sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/shim.h',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift',
                     'sketchybar/native/vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift',
                     'sketchybar/native/vendor/public-power-detail/audit/NoLiveLinkProbe.swift',
                     'sketchybar/native/vendor/public-power-detail/audit/manifest.py',
                     'sketchybar/native/vendor/public-power-detail/audit/mutation_test.py',
                     'sketchybar/native/vendor/public-power-detail/audit/source_only.py',
                     'sketchybar/native/vendor/public-power-detail/audit/verify.py',
                     'sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json',
                     'sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json',
                     'sketchybar/native/vendor/public-power-detail/docs/ATTENDED-GATES.md',
                     'sketchybar/native/vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md',
                     'sketchybar/native/vendor/public-power-detail/docs/SURFACE-MATRIX.md',
                     'sketchybar/native/vendor/public-power-detail/scripts/verify.sh',
                     'sketchybar/native/vendor/display-public-detail/README.md',
                     'sketchybar/native/vendor/display-public-detail/REPORT.md',
                     'sketchybar/native/vendor/display-public-detail/SOURCE-MANIFEST.sha256',
                     'sketchybar/native/vendor/display-public-detail/Sources/BetterDisplayContract.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/BindingsModel.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/Contract.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/PolicySurface.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/SnapshotCoordinator.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/StrictJSON.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/SystemPublicBindings.swift',
                     'sketchybar/native/vendor/display-public-detail/Tests/main.swift',
                     'sketchybar/native/vendor/display-public-detail/scripts/policy_audit.py',
                     'sketchybar/native/vendor/display-public-detail/scripts/verify.sh'),
  'native_dirs': ('vendor',
                  'vendor/display-public-detail',
                  'vendor/display-public-detail/Sources',
                  'vendor/display-public-detail/Tests',
                  'vendor/display-public-detail/scripts',
                  'vendor/public-power-detail',
                  'vendor/public-power-detail/Sources',
                  'vendor/public-power-detail/Sources/CDarwinNotify',
                  'vendor/public-power-detail/Sources/PublicPowerDetail',
                  'vendor/public-power-detail/Tests',
                  'vendor/public-power-detail/Tests/PublicPowerDetailTests',
                  'vendor/public-power-detail/audit',
                  'vendor/public-power-detail/docs',
                  'vendor/public-power-detail/scripts'),
  'native_files': ('APPROVED-ARTIFACTS.tsv',
                   'vendor/display-public-detail/README.md',
                   'vendor/display-public-detail/REPORT.md',
                   'vendor/display-public-detail/SOURCE-MANIFEST.sha256',
                   'vendor/display-public-detail/Sources/BetterDisplayContract.swift',
                   'vendor/display-public-detail/Sources/BindingsModel.swift',
                   'vendor/display-public-detail/Sources/Contract.swift',
                   'vendor/display-public-detail/Sources/PolicySurface.swift',
                   'vendor/display-public-detail/Sources/SnapshotCoordinator.swift',
                   'vendor/display-public-detail/Sources/StrictJSON.swift',
                   'vendor/display-public-detail/Sources/SystemPublicBindings.swift',
                   'vendor/display-public-detail/Tests/main.swift',
                   'vendor/display-public-detail/scripts/policy_audit.py',
                   'vendor/display-public-detail/scripts/verify.sh',
                   'vendor/public-power-detail/MANIFEST.sha256',
                   'vendor/public-power-detail/Package.swift',
                   'vendor/public-power-detail/README.md',
                   'vendor/public-power-detail/REPORT.md',
                   'vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap',
                   'vendor/public-power-detail/Sources/CDarwinNotify/shim.h',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift',
                   'vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift',
                   'vendor/public-power-detail/audit/NoLiveLinkProbe.swift',
                   'vendor/public-power-detail/audit/manifest.py',
                   'vendor/public-power-detail/audit/mutation_test.py',
                   'vendor/public-power-detail/audit/source_only.py',
                   'vendor/public-power-detail/audit/verify.py',
                   'vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json',
                   'vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json',
                   'vendor/public-power-detail/docs/ATTENDED-GATES.md',
                   'vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md',
                   'vendor/public-power-detail/docs/SURFACE-MATRIX.md',
                   'vendor/public-power-detail/scripts/verify.sh'),
  'readme_sha256': None},
 {'name': 'F3',
  'vendor_roots': ('public-power-detail', 'display-public-detail', 'remaining-controls-v2'),
  'tsv': b'# approved-native-artifacts-v1\n# artifact\tdestination\trecord_kind\trelative_path\tsha256\tsame_byte_review_sha256\texternal_tree_sha256\npublic-p'
         b'ower-detail\tvendor/public-power-detail\tmanifest\tMANIFEST.sha256\tba85e0a9b5084c1e317dc9636ffdfbb815fcbbc9135a902be061915e23bb5d8b\t5b918a625d2'
         b'c61ef142b29dba69cc3b84970cd0e5002b61971e795b054093059\t-\ndisplay-public-detail\tvendor/display-public-detail\tmanifest\tSOURCE-MANIFEST.sha256\td'
         b'4dddf0ec161da8421ae08706ac75c79d6b54affe51d9cccfc6b5bd4230c22e6\t79a01e8e6c7cae924eaa67c65198f3802268e4681299878f2da6e1ba89042547\td7cd6a00727a25e'
         b'a76b0c45cfc35ff13a9956a1289be0ef41effabdbf432fde4\ndisplay-public-detail\tvendor/display-public-detail\tsupplemental\tREPORT.md\tb2c2f740a20572bf'
         b'3703741bab7b937416a08dd3734afe21854b1ae00485fb67\t-\t-\nremaining-controls-v2\tvendor/remaining-controls-v2\tmanifest\tSOURCE-MANIFEST.sha256\tb871'
         b'e75315730a9beac0d59a0346ac70ef75eb4b629d77eaa493e024f1ca25d0\tbd491660aafb0cec0a64d74ab1c0cce14a51e240b1e14587a6f883cdc81d31b1\t-\nremaining-contro'
         b'ls-v2\tvendor/remaining-controls-v2\tsupplemental\tREPORT.md\td18a21a2b317b2da1b2396d31c9d7c70c7efb62b502b95c6f4b56dbf6575208f\t-\t-\nremaining-con'
         b'trols-v2\tvendor/remaining-controls-v2\tsupplemental\tSHA256SUMS\tc93f0ba36ae4667404a41b4a18e8ea09674360b5c7d177059a9b95d811331ace\t-\t-\n',
  'imported_files': ('sketchybar/native/vendor/public-power-detail/MANIFEST.sha256',
                     'sketchybar/native/vendor/public-power-detail/Package.swift',
                     'sketchybar/native/vendor/public-power-detail/README.md',
                     'sketchybar/native/vendor/public-power-detail/REPORT.md',
                     'sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap',
                     'sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/shim.h',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift',
                     'sketchybar/native/vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift',
                     'sketchybar/native/vendor/public-power-detail/audit/NoLiveLinkProbe.swift',
                     'sketchybar/native/vendor/public-power-detail/audit/manifest.py',
                     'sketchybar/native/vendor/public-power-detail/audit/mutation_test.py',
                     'sketchybar/native/vendor/public-power-detail/audit/source_only.py',
                     'sketchybar/native/vendor/public-power-detail/audit/verify.py',
                     'sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json',
                     'sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json',
                     'sketchybar/native/vendor/public-power-detail/docs/ATTENDED-GATES.md',
                     'sketchybar/native/vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md',
                     'sketchybar/native/vendor/public-power-detail/docs/SURFACE-MATRIX.md',
                     'sketchybar/native/vendor/public-power-detail/scripts/verify.sh',
                     'sketchybar/native/vendor/display-public-detail/README.md',
                     'sketchybar/native/vendor/display-public-detail/REPORT.md',
                     'sketchybar/native/vendor/display-public-detail/SOURCE-MANIFEST.sha256',
                     'sketchybar/native/vendor/display-public-detail/Sources/BetterDisplayContract.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/BindingsModel.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/Contract.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/PolicySurface.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/SnapshotCoordinator.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/StrictJSON.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/SystemPublicBindings.swift',
                     'sketchybar/native/vendor/display-public-detail/Tests/main.swift',
                     'sketchybar/native/vendor/display-public-detail/scripts/policy_audit.py',
                     'sketchybar/native/vendor/display-public-detail/scripts/verify.sh',
                     'sketchybar/native/vendor/remaining-controls-v2/LIFECYCLE-DESIGN.md',
                     'sketchybar/native/vendor/remaining-controls-v2/Package.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/README.md',
                     'sketchybar/native/vendor/remaining-controls-v2/REPORT.md',
                     'sketchybar/native/vendor/remaining-controls-v2/SHA256SUMS',
                     'sketchybar/native/vendor/remaining-controls-v2/SOURCE-MANIFEST.sha256',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/KeepAwakeAndWorkspaces.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/Mirroring.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/PublicRows.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/ShortcutsAndLifecycle.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/SleepReadOnly.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/SystemSettings.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/UnsupportedSurfaces.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/WindowManager.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/PublicCoreGraphicsBoundary.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/SealedSystemSettingsBoundary.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/BoundaryCompilationTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/Fakes.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/KeepAwakeWorkspaceTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/MirroringTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/RowsAndSettingsTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SelfTestMain.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SleepShortcutLifecycleTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/TestingCompatibility.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/WindowManagerTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/scripts/link_audit.py',
                     'sketchybar/native/vendor/remaining-controls-v2/scripts/static_audit.py',
                     'sketchybar/native/vendor/remaining-controls-v2/scripts/test.sh'),
  'native_dirs': ('vendor',
                  'vendor/display-public-detail',
                  'vendor/display-public-detail/Sources',
                  'vendor/display-public-detail/Tests',
                  'vendor/display-public-detail/scripts',
                  'vendor/public-power-detail',
                  'vendor/public-power-detail/Sources',
                  'vendor/public-power-detail/Sources/CDarwinNotify',
                  'vendor/public-power-detail/Sources/PublicPowerDetail',
                  'vendor/public-power-detail/Tests',
                  'vendor/public-power-detail/Tests/PublicPowerDetailTests',
                  'vendor/public-power-detail/audit',
                  'vendor/public-power-detail/docs',
                  'vendor/public-power-detail/scripts',
                  'vendor/remaining-controls-v2',
                  'vendor/remaining-controls-v2/Sources',
                  'vendor/remaining-controls-v2/Sources/RemainingControlsCore',
                  'vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries',
                  'vendor/remaining-controls-v2/Tests',
                  'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests',
                  'vendor/remaining-controls-v2/scripts'),
  'native_files': ('APPROVED-ARTIFACTS.tsv',
                   'vendor/display-public-detail/README.md',
                   'vendor/display-public-detail/REPORT.md',
                   'vendor/display-public-detail/SOURCE-MANIFEST.sha256',
                   'vendor/display-public-detail/Sources/BetterDisplayContract.swift',
                   'vendor/display-public-detail/Sources/BindingsModel.swift',
                   'vendor/display-public-detail/Sources/Contract.swift',
                   'vendor/display-public-detail/Sources/PolicySurface.swift',
                   'vendor/display-public-detail/Sources/SnapshotCoordinator.swift',
                   'vendor/display-public-detail/Sources/StrictJSON.swift',
                   'vendor/display-public-detail/Sources/SystemPublicBindings.swift',
                   'vendor/display-public-detail/Tests/main.swift',
                   'vendor/display-public-detail/scripts/policy_audit.py',
                   'vendor/display-public-detail/scripts/verify.sh',
                   'vendor/public-power-detail/MANIFEST.sha256',
                   'vendor/public-power-detail/Package.swift',
                   'vendor/public-power-detail/README.md',
                   'vendor/public-power-detail/REPORT.md',
                   'vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap',
                   'vendor/public-power-detail/Sources/CDarwinNotify/shim.h',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift',
                   'vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift',
                   'vendor/public-power-detail/audit/NoLiveLinkProbe.swift',
                   'vendor/public-power-detail/audit/manifest.py',
                   'vendor/public-power-detail/audit/mutation_test.py',
                   'vendor/public-power-detail/audit/source_only.py',
                   'vendor/public-power-detail/audit/verify.py',
                   'vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json',
                   'vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json',
                   'vendor/public-power-detail/docs/ATTENDED-GATES.md',
                   'vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md',
                   'vendor/public-power-detail/docs/SURFACE-MATRIX.md',
                   'vendor/public-power-detail/scripts/verify.sh',
                   'vendor/remaining-controls-v2/LIFECYCLE-DESIGN.md',
                   'vendor/remaining-controls-v2/Package.swift',
                   'vendor/remaining-controls-v2/README.md',
                   'vendor/remaining-controls-v2/REPORT.md',
                   'vendor/remaining-controls-v2/SHA256SUMS',
                   'vendor/remaining-controls-v2/SOURCE-MANIFEST.sha256',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/KeepAwakeAndWorkspaces.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/Mirroring.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/PublicRows.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/ShortcutsAndLifecycle.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/SleepReadOnly.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/SystemSettings.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/UnsupportedSurfaces.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/WindowManager.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/PublicCoreGraphicsBoundary.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/SealedSystemSettingsBoundary.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/BoundaryCompilationTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/Fakes.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/KeepAwakeWorkspaceTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/MirroringTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/RowsAndSettingsTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SelfTestMain.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SleepShortcutLifecycleTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/TestingCompatibility.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/WindowManagerTests.swift',
                   'vendor/remaining-controls-v2/scripts/link_audit.py',
                   'vendor/remaining-controls-v2/scripts/static_audit.py',
                   'vendor/remaining-controls-v2/scripts/test.sh'),
  'readme_sha256': None},
 {'name': 'F4',
  'vendor_roots': ('public-power-detail', 'display-public-detail', 'remaining-controls-v2'),
  'tsv': b'# approved-native-artifacts-v1\n# artifact\tdestination\trecord_kind\trelative_path\tsha256\tsame_byte_review_sha256\texternal_tree_sha256\npublic-p'
         b'ower-detail\tvendor/public-power-detail\tmanifest\tMANIFEST.sha256\tba85e0a9b5084c1e317dc9636ffdfbb815fcbbc9135a902be061915e23bb5d8b\t5b918a625d2'
         b'c61ef142b29dba69cc3b84970cd0e5002b61971e795b054093059\t-\ndisplay-public-detail\tvendor/display-public-detail\tmanifest\tSOURCE-MANIFEST.sha256\td'
         b'4dddf0ec161da8421ae08706ac75c79d6b54affe51d9cccfc6b5bd4230c22e6\t79a01e8e6c7cae924eaa67c65198f3802268e4681299878f2da6e1ba89042547\td7cd6a00727a25e'
         b'a76b0c45cfc35ff13a9956a1289be0ef41effabdbf432fde4\ndisplay-public-detail\tvendor/display-public-detail\tsupplemental\tREPORT.md\tb2c2f740a20572bf'
         b'3703741bab7b937416a08dd3734afe21854b1ae00485fb67\t-\t-\nremaining-controls-v2\tvendor/remaining-controls-v2\tmanifest\tSOURCE-MANIFEST.sha256\tb871'
         b'e75315730a9beac0d59a0346ac70ef75eb4b629d77eaa493e024f1ca25d0\tbd491660aafb0cec0a64d74ab1c0cce14a51e240b1e14587a6f883cdc81d31b1\t-\nremaining-contro'
         b'ls-v2\tvendor/remaining-controls-v2\tsupplemental\tREPORT.md\td18a21a2b317b2da1b2396d31c9d7c70c7efb62b502b95c6f4b56dbf6575208f\t-\t-\nremaining-con'
         b'trols-v2\tvendor/remaining-controls-v2\tsupplemental\tSHA256SUMS\tc93f0ba36ae4667404a41b4a18e8ea09674360b5c7d177059a9b95d811331ace\t-\t-\n',
  'imported_files': ('sketchybar/native/vendor/public-power-detail/MANIFEST.sha256',
                     'sketchybar/native/vendor/public-power-detail/Package.swift',
                     'sketchybar/native/vendor/public-power-detail/README.md',
                     'sketchybar/native/vendor/public-power-detail/REPORT.md',
                     'sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap',
                     'sketchybar/native/vendor/public-power-detail/Sources/CDarwinNotify/shim.h',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift',
                     'sketchybar/native/vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift',
                     'sketchybar/native/vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift',
                     'sketchybar/native/vendor/public-power-detail/audit/NoLiveLinkProbe.swift',
                     'sketchybar/native/vendor/public-power-detail/audit/manifest.py',
                     'sketchybar/native/vendor/public-power-detail/audit/mutation_test.py',
                     'sketchybar/native/vendor/public-power-detail/audit/source_only.py',
                     'sketchybar/native/vendor/public-power-detail/audit/verify.py',
                     'sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json',
                     'sketchybar/native/vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json',
                     'sketchybar/native/vendor/public-power-detail/docs/ATTENDED-GATES.md',
                     'sketchybar/native/vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md',
                     'sketchybar/native/vendor/public-power-detail/docs/SURFACE-MATRIX.md',
                     'sketchybar/native/vendor/public-power-detail/scripts/verify.sh',
                     'sketchybar/native/vendor/display-public-detail/README.md',
                     'sketchybar/native/vendor/display-public-detail/REPORT.md',
                     'sketchybar/native/vendor/display-public-detail/SOURCE-MANIFEST.sha256',
                     'sketchybar/native/vendor/display-public-detail/Sources/BetterDisplayContract.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/BindingsModel.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/Contract.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/PolicySurface.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/SnapshotCoordinator.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/StrictJSON.swift',
                     'sketchybar/native/vendor/display-public-detail/Sources/SystemPublicBindings.swift',
                     'sketchybar/native/vendor/display-public-detail/Tests/main.swift',
                     'sketchybar/native/vendor/display-public-detail/scripts/policy_audit.py',
                     'sketchybar/native/vendor/display-public-detail/scripts/verify.sh',
                     'sketchybar/native/vendor/remaining-controls-v2/LIFECYCLE-DESIGN.md',
                     'sketchybar/native/vendor/remaining-controls-v2/Package.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/README.md',
                     'sketchybar/native/vendor/remaining-controls-v2/REPORT.md',
                     'sketchybar/native/vendor/remaining-controls-v2/SHA256SUMS',
                     'sketchybar/native/vendor/remaining-controls-v2/SOURCE-MANIFEST.sha256',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/KeepAwakeAndWorkspaces.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/Mirroring.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/PublicRows.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/ShortcutsAndLifecycle.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/SleepReadOnly.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/SystemSettings.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/UnsupportedSurfaces.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsCore/WindowManager.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/PublicCoreGraphicsBoundary.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/SealedSystemSettingsBoundary.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/BoundaryCompilationTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/Fakes.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/KeepAwakeWorkspaceTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/MirroringTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/RowsAndSettingsTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SelfTestMain.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SleepShortcutLifecycleTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/TestingCompatibility.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/WindowManagerTests.swift',
                     'sketchybar/native/vendor/remaining-controls-v2/scripts/link_audit.py',
                     'sketchybar/native/vendor/remaining-controls-v2/scripts/static_audit.py',
                     'sketchybar/native/vendor/remaining-controls-v2/scripts/test.sh'),
  'native_dirs': ('vendor',
                  'vendor/display-public-detail',
                  'vendor/display-public-detail/Sources',
                  'vendor/display-public-detail/Tests',
                  'vendor/display-public-detail/scripts',
                  'vendor/public-power-detail',
                  'vendor/public-power-detail/Sources',
                  'vendor/public-power-detail/Sources/CDarwinNotify',
                  'vendor/public-power-detail/Sources/PublicPowerDetail',
                  'vendor/public-power-detail/Tests',
                  'vendor/public-power-detail/Tests/PublicPowerDetailTests',
                  'vendor/public-power-detail/audit',
                  'vendor/public-power-detail/docs',
                  'vendor/public-power-detail/scripts',
                  'vendor/remaining-controls-v2',
                  'vendor/remaining-controls-v2/Sources',
                  'vendor/remaining-controls-v2/Sources/RemainingControlsCore',
                  'vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries',
                  'vendor/remaining-controls-v2/Tests',
                  'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests',
                  'vendor/remaining-controls-v2/scripts'),
  'native_files': ('APPROVED-ARTIFACTS.tsv',
                   'README.md',
                   'vendor/display-public-detail/README.md',
                   'vendor/display-public-detail/REPORT.md',
                   'vendor/display-public-detail/SOURCE-MANIFEST.sha256',
                   'vendor/display-public-detail/Sources/BetterDisplayContract.swift',
                   'vendor/display-public-detail/Sources/BindingsModel.swift',
                   'vendor/display-public-detail/Sources/Contract.swift',
                   'vendor/display-public-detail/Sources/PolicySurface.swift',
                   'vendor/display-public-detail/Sources/SnapshotCoordinator.swift',
                   'vendor/display-public-detail/Sources/StrictJSON.swift',
                   'vendor/display-public-detail/Sources/SystemPublicBindings.swift',
                   'vendor/display-public-detail/Tests/main.swift',
                   'vendor/display-public-detail/scripts/policy_audit.py',
                   'vendor/display-public-detail/scripts/verify.sh',
                   'vendor/public-power-detail/MANIFEST.sha256',
                   'vendor/public-power-detail/Package.swift',
                   'vendor/public-power-detail/README.md',
                   'vendor/public-power-detail/REPORT.md',
                   'vendor/public-power-detail/Sources/CDarwinNotify/module.modulemap',
                   'vendor/public-power-detail/Sources/CDarwinNotify/shim.h',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/Contract.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/DarwinPublicBindings.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/ObservationDriver.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/PowerDetailAgent.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/PublicBindings.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/Reader.swift',
                   'vendor/public-power-detail/Sources/PublicPowerDetail/SystemSettingsCommand.swift',
                   'vendor/public-power-detail/Tests/PublicPowerDetailTests/PublicPowerDetailTests.swift',
                   'vendor/public-power-detail/audit/NoLiveLinkProbe.swift',
                   'vendor/public-power-detail/audit/manifest.py',
                   'vendor/public-power-detail/audit/mutation_test.py',
                   'vendor/public-power-detail/audit/source_only.py',
                   'vendor/public-power-detail/audit/verify.py',
                   'vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-INITIAL.json',
                   'vendor/public-power-detail/docs/ADVERSARIAL-REVIEW-REPAIR.json',
                   'vendor/public-power-detail/docs/ATTENDED-GATES.md',
                   'vendor/public-power-detail/docs/INSTALL-LIFECYCLE-DESIGN.md',
                   'vendor/public-power-detail/docs/SURFACE-MATRIX.md',
                   'vendor/public-power-detail/scripts/verify.sh',
                   'vendor/remaining-controls-v2/LIFECYCLE-DESIGN.md',
                   'vendor/remaining-controls-v2/Package.swift',
                   'vendor/remaining-controls-v2/README.md',
                   'vendor/remaining-controls-v2/REPORT.md',
                   'vendor/remaining-controls-v2/SHA256SUMS',
                   'vendor/remaining-controls-v2/SOURCE-MANIFEST.sha256',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/KeepAwakeAndWorkspaces.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/Mirroring.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/PublicRows.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/ShortcutsAndLifecycle.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/SleepReadOnly.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/SystemSettings.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/UnsupportedSurfaces.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsCore/WindowManager.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/PublicCoreGraphicsBoundary.swift',
                   'vendor/remaining-controls-v2/Sources/RemainingControlsMacBoundaries/SealedSystemSettingsBoundary.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/BoundaryCompilationTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/Fakes.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/KeepAwakeWorkspaceTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/MirroringTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/RowsAndSettingsTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SelfTestMain.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/SleepShortcutLifecycleTests.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/TestingCompatibility.swift',
                   'vendor/remaining-controls-v2/Tests/RemainingControlsCoreTests/WindowManagerTests.swift',
                   'vendor/remaining-controls-v2/scripts/link_audit.py',
                   'vendor/remaining-controls-v2/scripts/static_audit.py',
                   'vendor/remaining-controls-v2/scripts/test.sh'),
  'readme_sha256': '6d9e279176b3d86e2a5c2edcb30b6c805126af4f8603ffd7ec3218d094cd7716'}),
}

_FORBIDDEN_OUTPUT_COMPONENTS = frozenset({
    ".build", ".swiftpm", "deriveddata", ".cache", "cache", "caches",
    "build", "builds", "dist", "generated", "generator", "generators", "codegen",
})
_FORBIDDEN_OUTPUT_SUFFIXES = (
    ".o", ".obj", ".a", ".ar", ".lib", ".dylib", ".so", ".dll", ".exe",
    ".bc", ".pyc", ".pyo", ".pcm", ".swiftmodule", ".swiftdoc",
    ".swiftsourceinfo", ".app", ".bundle", ".framework", ".xpc", ".dsym",
    ".zip", ".tar", ".tgz", ".gz", ".bz2", ".xz", ".7z",
)
_COMPILED_MAGICS = (
    (b"\xfe\xed\xfa\xce", "Mach-O"),
    (b"\xce\xfa\xed\xfe", "Mach-O"),
    (b"\xfe\xed\xfa\xcf", "Mach-O"),
    (b"\xcf\xfa\xed\xfe", "Mach-O"),
    (b"\xca\xfe\xba\xbe", "fat Mach-O"),
    (b"\xbe\xba\xfe\xca", "fat Mach-O"),
    (b"\xca\xfe\xba\xbf", "fat Mach-O"),
    (b"\xbf\xba\xfe\xca", "fat Mach-O"),
    (b"\x7fELF", "ELF"),
    (b"MZ", "PE"),
    (b"BC\xc0\xde", "LLVM bitcode"),
    (b"\xde\xc0\x17\x0b", "LLVM bitcode wrapper"),
    (b"!<arch>\n", "archive"),
    (b"PK\x03\x04", "ZIP archive"),
    (b"PK\x05\x06", "ZIP archive"),
    (b"PK\x07\x08", "ZIP archive"),
)
_SAFE_MANIFEST_COMPONENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+@-]*\Z")
_HEX64 = re.compile(r"[0-9a-f]{64}\Z")


def fail(message):
    raise SystemExit(f"native approved artifact guard: {message}")


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _require_real_directory(path, label):
    try:
        info = os.lstat(path)
    except OSError as error:
        fail(f"{label} is not an accessible real directory: {error}")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        fail(f"{label} is not a real directory")
    return info


def _require_parent_directories(path, repository_root):
    try:
        relative = path.relative_to(repository_root)
    except ValueError:
        fail("an inspected path escaped the repository root")
    current = repository_root
    _require_real_directory(current, "repository root")
    for component in relative.parts[:-1]:
        current = current / component
        _require_real_directory(current, f"parent directory {current.relative_to(repository_root).as_posix()}")


def _read_regular_file(path, repository_root, label, expected_mode=None, identities=None):
    _require_parent_directories(path, repository_root)
    try:
        before = os.lstat(path)
    except OSError as error:
        fail(f"{label} cannot be inspected: {error}")
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        fail(f"{label} is not a real regular file")
    if before.st_nlink != 1:
        fail(f"{label} does not have exactly one hard link")
    permissions = stat.S_IMODE(before.st_mode)
    risky = permissions & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX | 0o022)
    if risky:
        fail(f"{label} has set-id, sticky, group-write, or other-write permission bits")
    if expected_mode is not None and permissions != expected_mode:
        fail(f"{label} mode is {permissions:04o}, expected {expected_mode:04o}")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"{label} cannot be opened without following links: {error}")
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
            fail(f"{label} changed type or link count while being read")
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            fail(f"{label} changed identity while being opened")
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(descriptor)
    try:
        after = os.lstat(path)
    except OSError as error:
        fail(f"{label} disappeared after reading: {error}")
    stable_fields_before = (
        before.st_dev, before.st_ino, before.st_mode, before.st_nlink,
        before.st_size, before.st_mtime_ns, before.st_ctime_ns,
    )
    stable_fields_after = (
        after.st_dev, after.st_ino, after.st_mode, after.st_nlink,
        after.st_size, after.st_mtime_ns, after.st_ctime_ns,
    )
    if stable_fields_before != stable_fields_after:
        fail(f"{label} changed while being read")
    identity = (before.st_dev, before.st_ino)
    if identities is not None:
        if identity in identities:
            fail(f"{label} aliases another imported file identity")
        identities.add(identity)
    return b"".join(chunks)


def _scan_tree(root, label):
    _require_real_directory(root, label)
    directories = set()
    files = set()

    def visit(directory, prefix):
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            fail(f"cannot enumerate {label}: {error}")
        for entry in entries:
            relative = f"{prefix}/{entry.name}" if prefix else entry.name
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError as error:
                fail(f"cannot inspect {label} entry {relative}: {error}")
            if stat.S_ISLNK(info.st_mode):
                fail(f"{label} contains symlink {relative}")
            if stat.S_ISDIR(info.st_mode):
                directories.add(relative)
                visit(Path(entry.path), relative)
            elif stat.S_ISREG(info.st_mode):
                files.add(relative)
            else:
                fail(f"{label} contains non-directory, non-regular entry {relative}")

    visit(root, "")
    return frozenset(directories), frozenset(files)


def _validate_tsv(data):
    if not data or not data.endswith(b"\n"):
        fail("APPROVED-ARTIFACTS.tsv must end in LF")
    if b"\r" in data or b"\x00" in data:
        fail("APPROVED-ARTIFACTS.tsv contains CR or NUL")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        fail(f"APPROVED-ARTIFACTS.tsv is not UTF-8: {error}")
    lines = text.splitlines()
    if not lines or any(line == "" for line in lines):
        fail("APPROVED-ARTIFACTS.tsv contains a blank row")
    if lines[0] != "# approved-native-artifacts-v1":
        fail("APPROVED-ARTIFACTS.tsv version header is not exact")
    schema = "# artifact\tdestination\trecord_kind\trelative_path\tsha256\tsame_byte_review_sha256\texternal_tree_sha256"
    if len(lines) < 3 or lines[1] != schema:
        fail("APPROVED-ARTIFACTS.tsv schema row is not exact")
    for row_number, line in enumerate(lines[2:], start=3):
        fields = line.split("\t")
        if len(fields) != 7:
            fail(f"APPROVED-ARTIFACTS.tsv row {row_number} does not have seven literal-tab fields")
        if fields[2] not in {"manifest", "supplemental"}:
            fail(f"APPROVED-ARTIFACTS.tsv row {row_number} has an invalid record kind")
        for value in fields[4:]:
            if value != "-" and _HEX64.fullmatch(value) is None:
                fail(f"APPROVED-ARTIFACTS.tsv row {row_number} has a non-lowercase SHA-256 field")
    return text


def _reject_output_name(relative):
    parts = PurePosixPath(relative).parts
    for component in parts:
        lowered = component.lower()
        if lowered in _FORBIDDEN_OUTPUT_COMPONENTS or lowered.endswith(_FORBIDDEN_OUTPUT_SUFFIXES):
            fail(f"native inventory contains compiled, generated, bundle, or cache name {relative}")
        if lowered.startswith("package-cache") or lowered.startswith("module-cache"):
            fail(f"native inventory contains package or module cache name {relative}")


def _reject_compiled_content(relative, data):
    for magic, kind in _COMPILED_MAGICS:
        if data.startswith(magic):
            fail(f"imported file {relative} contains {kind} magic")
    if b"\x00" in data:
        fail(f"imported file {relative} contains NUL bytes instead of source text")


def _safe_manifest_path(value, label):
    if not value or value.startswith("/") or "\\" in value or "//" in value:
        fail(f"{label} has an unsafe absolute or non-canonical path {value!r}")
    pure = PurePosixPath(value)
    if pure.is_absolute() or pure.as_posix() != value:
        fail(f"{label} has a non-canonical path {value!r}")
    for component in pure.parts:
        if component in {"", ".", ".."} or _SAFE_MANIFEST_COMPONENT.fullmatch(component) is None:
            fail(f"{label} has an unsafe path component in {value!r}")
    return value


def _parse_manifest(data, label):
    if not data or not data.endswith(b"\n"):
        fail(f"{label} is missing its final LF")
    if b"\r" in data or b"\x00" in data:
        fail(f"{label} contains CR or NUL")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        fail(f"{label} is not strict UTF-8: {error}")
    records = []
    seen = set()
    for row_number, line in enumerate(text[:-1].split("\n"), start=1):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            fail(f"{label} row {row_number} is not '<64 lowercase hex><two spaces><safe relative path><LF>'")
        digest, relative = match.groups()
        _safe_manifest_path(relative, label)
        if relative in seen:
            fail(f"{label} repeats path {relative}")
        seen.add(relative)
        records.append((relative, digest))
    paths = [path for path, unused_digest in records]
    if paths != sorted(paths):
        fail(f"{label} rows are not sorted by relative path")
    return dict(records)


def _directory_prefixes(files):
    result = set()
    for relative in files:
        parts = PurePosixPath(relative).parts
        for count in range(1, len(parts)):
            result.add("/".join(parts[:count]))
    return frozenset(result)


def _check_artifacts(repository_root, native_root, phase, native_directories, native_files):
    expected_mode_by_path = dict(EXPECTED_PHASES["files"])
    imported_paths = tuple(phase["imported_files"])
    if len(imported_paths) != len(set(imported_paths)):
        fail("trusted phase file table contains a duplicate")
    identities = set()
    contents = {}
    for repository_relative in imported_paths:
        expected_mode = expected_mode_by_path.get(repository_relative)
        if expected_mode is None:
            fail(f"trusted phase file has no hard-coded mode: {repository_relative}")
        path = repository_root / repository_relative
        data = _read_regular_file(
            path, repository_root, repository_relative,
            expected_mode=expected_mode, identities=identities,
        )
        _reject_compiled_content(repository_relative, data)
        contents[repository_relative] = data
    if len(contents) != len(imported_paths) or len(identities) != len(imported_paths):
        fail("imported file identity coverage is incomplete")

    approval_by_artifact = {item["artifact"]: item for item in EXPECTED_PHASES["approvals"]}
    for artifact in phase["vendor_roots"]:
        approval = approval_by_artifact.get(artifact)
        if approval is None:
            fail(f"trusted phase names unknown artifact {artifact}")
        destination = approval["destination"]
        vendor_root = native_root / destination
        _require_real_directory(vendor_root, f"vendor root {artifact}")
        repository_prefix = f"sketchybar/native/{destination}/"
        artifact_repository_paths = tuple(path for path in imported_paths if path.startswith(repository_prefix))
        artifact_relative_files = frozenset(path[len(repository_prefix):] for path in artifact_repository_paths)
        expected_directories = _directory_prefixes(artifact_relative_files)
        actual_directories, actual_files = _scan_tree(vendor_root, f"vendor root {artifact}")
        if actual_directories != expected_directories:
            fail(f"{artifact} directory-prefix set differs from the exact approved set")
        for relative_directory in expected_directories:
            _require_real_directory(vendor_root / relative_directory, f"{artifact} directory {relative_directory}")

        manifest_relative = approval["manifest"]
        supplemental_map = dict(approval["supplementals"])
        coverage = set()
        manifest_repository_path = repository_prefix + manifest_relative
        manifest_data = contents.get(manifest_repository_path)
        if manifest_data is None:
            fail(f"{artifact} canonical manifest is absent from the phase file table")
        if _sha256(manifest_data) != approval["manifest_sha256"]:
            fail(f"{artifact} canonical manifest SHA-256 does not match its hard-coded pin")
        records = _parse_manifest(manifest_data, f"{artifact} canonical manifest")
        coverage.add(manifest_relative)
        for supplemental_relative, expected_sha256 in approval["supplementals"]:
            supplemental_repository_path = repository_prefix + supplemental_relative
            supplemental_data = contents.get(supplemental_repository_path)
            if supplemental_data is None:
                fail(f"{artifact} supplemental file {supplemental_relative} is missing")
            if _sha256(supplemental_data) != expected_sha256:
                fail(f"{artifact} supplemental file {supplemental_relative} does not match its pin")
            coverage.add(supplemental_relative)

        expected_payloads = artifact_relative_files - {manifest_relative} - set(supplemental_map)
        if frozenset(records) != frozenset(expected_payloads):
            fail(f"{artifact} manifest record paths do not equal the exact approved payload set")
        for payload_relative, expected_sha256 in records.items():
            payload_repository_path = repository_prefix + payload_relative
            payload_data = contents.get(payload_repository_path)
            if payload_data is None:
                fail(f"{artifact} manifest payload {payload_relative} is missing")
            if _sha256(payload_data) != expected_sha256:
                fail(f"{artifact} payload {payload_relative} does not match its manifest digest")
            coverage.add(payload_relative)
        if frozenset(coverage) != actual_files or actual_files != artifact_relative_files:
            fail(f"{artifact} manifest plus manifest file plus supplemental pins do not cover its complete regular-file set")

    expected_active_paths = frozenset(imported_paths)
    if expected_active_paths != frozenset(contents):
        fail("active imported path coverage differs from the trusted phase")
    expected_native_vendor_files = frozenset(path.removeprefix("sketchybar/native/") for path in imported_paths)
    actual_native_vendor_files = frozenset(path for path in native_files if path.startswith("vendor/"))
    if actual_native_vendor_files != expected_native_vendor_files:
        fail("native vendor files differ from the phase-exact 66-file table subset")


def _read_repository_text(path, repository_root, label):
    data = _read_regular_file(path, repository_root, label)
    if b"\x00" in data or b"\r" in data:
        fail(f"{label} is not LF-only source text")
    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        fail(f"{label} is not strict UTF-8: {error}")


def _check_runtime_query_ast(repository_root):
    path = repository_root / "sketchybar/tests/calendar-bar-runtime-shape.py"
    text = _read_repository_text(path, repository_root, "calendar-bar-runtime-shape.py")
    try:
        tree = ast.parse(text, filename="calendar-bar-runtime-shape.py")
    except SyntaxError as error:
        fail(f"calendar-bar-runtime-shape.py cannot be parsed: {error}")

    binary_assignments = [
        node for node in tree.body
        if isinstance(node, ast.Assign) and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "BINARY"
    ]
    if len(binary_assignments) != 1:
        fail("runtime source must have one exact top-level BINARY assignment")
    binary_assignment = binary_assignments[0]
    if not isinstance(binary_assignment.value, ast.Constant) or binary_assignment.value.value != "/opt/homebrew/bin/sketchybar":
        fail("runtime BINARY is not the approved literal SketchyBar path")
    binary_names = [node for node in ast.walk(tree) if isinstance(node, ast.Name) and node.id == "BINARY"]
    binary_stores = [node for node in binary_names if isinstance(node.ctx, ast.Store)]
    binary_loads = [node for node in binary_names if isinstance(node.ctx, ast.Load)]
    if binary_stores != [binary_assignment.targets[0]]:
        fail("runtime BINARY has another store")

    assignments = []
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "QUERIED_ITEMS":
            assignments.append(node)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == "QUERIED_ITEMS":
            assignments.append(node)
    if len(assignments) != 1 or not isinstance(assignments[0], ast.Assign):
        fail("runtime source must have one exact top-level QUERIED_ITEMS assignment")
    try:
        literal = ast.literal_eval(assignments[0].value)
    except (ValueError, TypeError, SyntaxError):
        fail("runtime QUERIED_ITEMS must be a literal tuple")
    if type(literal) is not tuple or literal != EXPECTED_QUERY_TUPLE:
        fail("runtime QUERIED_ITEMS tuple or order changed")

    query_functions = [node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == "query"]
    if len(query_functions) != 1 or not isinstance(query_functions[0], ast.FunctionDef):
        fail("runtime source must have one synchronous query function")
    function = query_functions[0]
    if len(function.args.args) != 1 or function.args.args[0].arg != "name" or function.args.vararg is not None or function.args.kwarg is not None:
        fail("runtime query function signature changed")

    query_calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "query"]
    if len(query_calls) != 1:
        fail("runtime queries must have exactly one query call site")
    queried_assignments = [
        node for node in tree.body
        if isinstance(node, ast.Assign) and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "queried"
    ]
    if len(queried_assignments) != 1 or not isinstance(queried_assignments[0].value, ast.ListComp):
        fail("runtime queried values must be built by one list comprehension")
    comprehension = queried_assignments[0].value
    if comprehension.elt is not query_calls[0] or len(comprehension.generators) != 1:
        fail("runtime query call is not routed only through the approved tuple comprehension")
    generator = comprehension.generators[0]
    if (
        not isinstance(generator.target, ast.Name) or generator.target.id != "name"
        or not isinstance(generator.iter, ast.Name) or generator.iter.id != "QUERIED_ITEMS"
        or generator.ifs or generator.is_async
    ):
        fail("runtime query comprehension changed target, tuple source, filters, or sync form")
    call = query_calls[0]
    if len(call.args) != 1 or not isinstance(call.args[0], ast.Name) or call.args[0].id != "name" or call.keywords:
        fail("runtime query call does not use only the tuple iteration name")

    query_name_loads = [node for node in ast.walk(tree) if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and node.id == "query"]
    tuple_name_loads = [node for node in ast.walk(tree) if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load) and node.id == "QUERIED_ITEMS"]
    if query_name_loads != [call.func] or tuple_name_loads != [generator.iter]:
        fail("runtime query function or tuple has an alternate use")

    subprocess_calls = [
        node for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess" and node.func.attr == "run"
    ]
    if len(subprocess_calls) != 1:
        fail("runtime source must contain exactly one subprocess.run query boundary")
    subprocess_call = subprocess_calls[0]
    if len(subprocess_call.args) != 1 or not isinstance(subprocess_call.args[0], ast.List):
        fail("runtime subprocess query command shape changed")
    command = subprocess_call.args[0].elts
    command_ok = (
        len(command) == 3
        and isinstance(command[0], ast.Name) and command[0].id == "BINARY"
        and isinstance(command[1], ast.Constant) and command[1].value == "--query"
        and isinstance(command[2], ast.Name) and command[2].id == "name"
    )
    if not command_ok:
        fail("runtime subprocess query command is not [BINARY, '--query', name]")
    if binary_loads != [command[0]]:
        fail("runtime BINARY has an alternate load")
    query_option_literals = [node for node in ast.walk(tree) if isinstance(node, ast.Constant) and node.value == "--query"]
    if len(query_option_literals) != 1 or query_option_literals[0] is not command[1]:
        fail("runtime source contains another query command marker")


def _logical_shell_lines(text):
    physical = text.splitlines(keepends=True)
    result = []
    offset = 0
    index = 0
    while index < len(physical):
        start = offset
        pieces = []
        while True:
            line = physical[index]
            offset += len(line)
            body = line[:-1] if line.endswith("\n") else line
            if body.endswith("\r"):
                body = body[:-1]
            continued = body.endswith("\\")
            pieces.append(body[:-1] if continued else body)
            index += 1
            if not continued or index >= len(physical):
                break
        result.append((start, offset, " ".join(piece.strip() for piece in pieces).strip()))
    return result


def _check_smoke_gate(repository_root, phase):
    path = repository_root / "sketchybar/scripts/smoke-config.sh"
    text = _read_repository_text(path, repository_root, "smoke-config.sh")
    assignment = "require_live_shape=${SKETCHYBAR_REQUIRE_LIVE_SHAPE:-0}"
    if text.count(assignment) != 1:
        fail("smoke live-shape input assignment changed or is duplicated")
    gate = 'if [ "$require_live_shape" = 1 ]; then'
    logical = _logical_shell_lines(text)
    gate_rows = [index for index, unused in enumerate(logical) if logical[index][2] == gate]
    if len(gate_rows) != 1:
        fail("smoke source must contain one exact explicit live gate")
    gate_index = gate_rows[0]
    gate_start, gate_end, unused_gate_text = logical[gate_index]
    if text.find(assignment) > gate_start:
        fail("smoke explicit live gate occurs before its validated input assignment")

    guard_invocation = '/usr/bin/python3 "$root/tests/native-approved-artifacts-test.py"'
    guard_count = text.count(guard_invocation)
    root_assignment = "root=$(CDPATH='' cd -- \"$(dirname -- \"$0\")/..\" && pwd)"
    if text.count(root_assignment) != 1 or text.find(root_assignment) >= gate_start:
        fail("smoke root assignment is not exact or does not precede the live gate")
    if phase["name"] == "F4":
        immediate = gate_index > 0 and logical[gate_index - 1][2] == guard_invocation
        if guard_count != 1 or not immediate or text.find(root_assignment) >= text.find(guard_invocation):
            fail("F4 smoke must invoke the native artifact guard immediately before the live gate after root setup")
    elif guard_count != 0:
        fail("native artifact guard must remain disconnected before F4")

    depth = 0
    outer_else = None
    outer_end = None
    for start, end, source in logical[gate_index:]:
        if re.match(r"^if(?:[ \t]|$)", source) and re.search(r";[ \t]*then$", source):
            depth += 1
            continue
        if source == "else":
            if depth == 1 and outer_else is None:
                outer_else = start
            continue
        if source == "fi":
            depth -= 1
            if depth < 0:
                fail("smoke live branch has an unmatched fi")
            if depth == 0:
                outer_end = end
                break
    if depth != 0 or outer_else is None or outer_end is None:
        fail("smoke explicit live branch cannot be bounded through its else and fi")

    marker_matches = list(re.finditer(r"--query\b", text))
    command_matches = list(re.finditer(r"/opt/homebrew/bin/sketchybar[ \t]+--query[ \t]+([A-Za-z0-9._-]+)", text))
    if len(marker_matches) != 5 or len(command_matches) != 5:
        fail("smoke source must contain exactly five direct query commands and no other query marker")
    if [match.start() for match in marker_matches] != [text.find("--query", match.start(), match.end()) for match in command_matches]:
        fail("smoke query marker is not part of an exact direct SketchyBar query command")
    query_names = tuple(match.group(1) for match in command_matches)
    if query_names != EXPECTED_SMOKE_QUERY_ORDER or frozenset(query_names) != frozenset(EXPECTED_QUERY_TUPLE):
        fail("smoke live query order or exact five-name set changed")
    for match in command_matches:
        if not (gate_end <= match.start() < outer_else):
            fail("smoke query occurs before the explicit live gate or outside its live branch")

    runtime_name = "calendar-bar-runtime-shape.py"
    runtime_invocations = [match for match in re.finditer(re.escape(runtime_name), text)]
    if len(runtime_invocations) != 1:
        fail("smoke source must invoke the runtime query test exactly once")
    invocation = runtime_invocations[0]
    if not (command_matches[-1].end() < invocation.start() < outer_else):
        fail("smoke runtime query test is not after all guarded availability queries")


def _collect_runtime_surfaces(sketchybar_root, repository_root):
    excluded_directory_names = {"test", "tests", "fixtures", "docs"}
    observed = set()

    def visit(directory, prefix):
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as error:
            fail(f"cannot enumerate production surfaces below {prefix or 'sketchybar'}: {error}")
        for entry in entries:
            relative_inside = f"{prefix}/{entry.name}" if prefix else entry.name
            parts = PurePosixPath(relative_inside).parts
            if parts[0] == "native" or any(part.lower() in excluded_directory_names for part in parts):
                continue
            repository_relative = f"sketchybar/{relative_inside}"
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError as error:
                fail(f"cannot inspect production surface {repository_relative}: {error}")
            if stat.S_ISLNK(info.st_mode):
                fail(f"production source tree contains symlink {repository_relative}")
            if stat.S_ISDIR(info.st_mode):
                visit(Path(entry.path), relative_inside)
                continue
            if not stat.S_ISREG(info.st_mode):
                fail(f"production source tree contains non-regular entry {repository_relative}")
            observed.add(repository_relative)

    visit(sketchybar_root, "")
    expected = frozenset(EXPECTED_RUNTIME_SURFACES)
    if frozenset(observed) != expected:
        fail("complete non-test production file inventory changed")
    try:
        tracked = subprocess.run(
            ["/usr/bin/git", "-C", os.fspath(repository_root), "ls-files", "--error-unmatch", "--",
             *EXPECTED_RUNTIME_SURFACES],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        fail("cannot verify the tracked production file inventory")
    if tracked.returncode != 0:
        fail("production inventory contains an untracked release surface")
    return tuple(EXPECTED_RUNTIME_SURFACES)

def _check_no_runtime_references_or_adapters(repository_root, sketchybar_root, native_root):
    forbidden_native_roots = (
        "Package.swift", "Sources", "Tests", "bin", "build", ".build", ".swiftpm",
        "DerivedData", "Runtime", "runtime", "LaunchAgents", "launchd", "daemon",
    )
    for relative in forbidden_native_roots:
        try:
            os.lstat(native_root / relative)
        except FileNotFoundError:
            continue
        except OSError as error:
            fail(f"cannot confirm absence of forbidden native root {relative}: {error}")
        fail(f"forbidden integration, runtime, build, generated, launch, or daemon root exists: native/{relative}")

    forbidden_references = (
        "sketchybar/native/vendor",
        "native/vendor",
        "vendor/public-power-detail",
        "vendor/display-public-detail",
        "vendor/remaining-controls-v2",
        "public-power-detail",
        "display-public-detail",
        "remaining-controls-v2",
        "publicpowerdetail",
        "remainingcontrolscore",
        "remainingcontrolsmacboundaries",
        "darwinpublicpowerbindings",
        "powerdetailagent",
        "systemsettingslaunchcommand",
        "systempublicdisplaybindings",
        "systempublicbindings",
        "betterdisplaycontract",
        "policysurface",
        "snapshotcoordinator",
        "publiccoregraphicsboundary",
        "sealedsystemsettingsboundary",
        "darwinsystemsettingsapplicationopener",
    ) + VENDOR_REFERENCE_TOKENS
    for repository_relative in _collect_runtime_surfaces(sketchybar_root, repository_root):
        path = repository_root / repository_relative
        text = _read_repository_text(path, repository_root, repository_relative)
        lowered = text.lower()
        approval = APPROVED_RUNTIME_REFERENCE_PINS.get(repository_relative)
        allowed = frozenset()
        if approval is not None:
            if _sha256(text.encode("utf-8")) != approval["sha256"]:
                fail(f"reviewed runtime integration byte pin changed: {repository_relative}")
            allowed = approval["allowed"]
        for forbidden in forbidden_references:
            if forbidden in lowered and forbidden not in allowed:
                fail(f"runtime surface {repository_relative} references a vendor destination or vendored module")



def _lexical_real_script_path():
    raw = Path(os.path.abspath(os.fspath(__file__)))
    if not raw.is_absolute() or raw.name != "native-approved-artifacts-test.py":
        fail("guard script path is not the exact absolute test path")
    current = Path(raw.anchor)
    components = raw.parts[1:]
    for index, component in enumerate(components):
        current = current / component
        try:
            info = os.lstat(current)
        except OSError as error:
            fail(f"cannot lstat guard path component: {error}")
        if stat.S_ISLNK(info.st_mode):
            fail("guard script path contains a symlink")
        final = index == len(components) - 1
        if final:
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                fail("guard script is not a single-link real regular file")
            permissions = stat.S_IMODE(info.st_mode)
            if permissions != 0o755 or permissions & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX | 0o022):
                fail("guard script mode is not exact and safe")
        elif not stat.S_ISDIR(info.st_mode):
            fail("guard script parent component is not a real directory")
    return raw

def main():
    script_path = _lexical_real_script_path()
    if len(script_path.parents) < 3:
        fail("script path is too shallow to determine the repository root")
    repository_root = script_path.parents[2]
    if script_path != repository_root / "sketchybar/tests/native-approved-artifacts-test.py":
        fail("guard script is not at the exact repository-relative path")
    sketchybar_root = repository_root / "sketchybar"
    native_root = sketchybar_root / "native"
    _require_real_directory(sketchybar_root, "sketchybar root")
    _require_real_directory(native_root, "native root")

    native_directories, native_files = _scan_tree(native_root, "native root")
    for relative in sorted(native_directories | native_files):
        _reject_output_name(relative)
    tsv_path = native_root / "APPROVED-ARTIFACTS.tsv"
    tsv_data = _read_regular_file(tsv_path, repository_root, "APPROVED-ARTIFACTS.tsv", expected_mode=0o644)
    _validate_tsv(tsv_data)

    states = EXPECTED_PHASES["states"]
    if len(states) != 4 or tuple(state["name"] for state in states) != ("F1", "F2", "F3", "F4"):
        fail("trusted guard does not contain exactly the four approved phase states")
    matches = [
        state for state in states
        if tsv_data == state["tsv"]
        and native_directories == frozenset(state["native_dirs"])
        and native_files == frozenset(state["native_files"])
    ]
    if len(matches) != 1:
        fail("TSV bytes and native-root inventory do not match one complete approved F1/F2/F3/F4 state")
    phase = matches[0]

    readme_path = native_root / "README.md"
    expected_readme_sha256 = phase["readme_sha256"]
    if expected_readme_sha256 is None:
        if "README.md" in native_files:
            fail(f"README.md must be absent in {phase['name']}")
    else:
        readme_data = _read_regular_file(readme_path, repository_root, "native README.md", expected_mode=0o644)
        if _sha256(readme_data) != expected_readme_sha256:
            fail("native README.md does not match the frozen F4 byte pin")

    _check_artifacts(repository_root, native_root, phase, native_directories, native_files)
    _check_no_runtime_references_or_adapters(repository_root, sketchybar_root, native_root)
    _check_runtime_query_ast(repository_root)
    _check_smoke_gate(repository_root, phase)
    print(f"native approved artifacts: {phase['name']} source-only state OK")


if __name__ == "__main__":
    main()
