# yabai and skhd operations

`deploy-lifecycle.py` is the only supported build, installation, activation, and rollback entrypoint. The runtime configuration remains in `yabairc` and `../skhd/skhdrc`.

## Fixed Home deployment

The reviewed Home deployment uses these exact bundles:

- `/Users/twaldin/Applications/Yabai.app`
- `/Users/twaldin/Applications/skhd.app`
- `/Applications/AeroSpace.app`

The lifecycle manifest binds their bundle identifiers, versions, architectures, executable and `Info.plist` SHA-256 values, CDHashes, source pins, launch-agent bytes, all three launch labels, and the exact fallback path. A change to either ad-hoc-signed primary app invalidates its Accessibility approval.

The primary labels are:

- `com.asmvik.yabai`
- `com.koekeishiya.skhd`
- alternate legacy label `com.asmvik.skhd`

Every prepare, activation, recovery, and rollback operation gates all three labels.

## State model

The command reports typed states instead of raw process data:

- Transaction: `CLEAN`, `APP_RECOVERY_REQUIRED`, `SUPPORT_RECOVERY_REQUIRED`, or `CONFLICTED_RECOVERY`.
- Lanes: `UNKNOWN_UNSAFE`, `PARTIAL_UNSAFE`, `PRIMARY_OFF`, `PRIMARY_OFF_FALLBACK_UNAVAILABLE`, `FALLBACK_ACTIVE`, or `PRIMARY_ACTIVE`.
- Deployment: `IDENTITY_INVALID`, `SUPPORT_NOT_READY`, `APPROVAL_REQUIRED`, `READY`, or `RUNTIME_ACCEPTED`.

No successful state permits AeroSpace with yabai, two skhd lanes, an enabled unloaded alternate job, a mixed app pair, or an unresolved journal.
Support journals use typed phases. Recovery rolls back only an incomplete support transaction. If the exact support objects, manifest, and app pair reached `committed`, recovery retains them and removes only the stale committed journal.

## First adoption

Run from the checked-out repository. `status` emits typed point-in-time state, does not wait for runtime convergence, and emits no receipt, so routine diagnostics do not grow the receipt directory:

```sh
/usr/bin/python3 -I yabai/deploy-lifecycle.py status
/usr/bin/python3 -I yabai/deploy-lifecycle.py prepare --adopt-existing
```

Preparation verifies all three apps and every support destination before it changes a launch label. It also refuses to adopt while any prior yabai/skhd process or launch job is active; stop that prior primary manager through its own safe lifecycle first. The preflight requires each config destination to be absent or already point to the reviewed target, each launch-agent destination to be absent or an exact mode-0600 copy, each private log directory to be absent or exact, and each legacy log name to be absent or a safe owned regular file. It refuses prior real config directories and prior launch-agent symlinks before it stops any primary lane.

After that preflight, preparation converges every primary label off and disabled, installs three exact configuration links plus mode-0600 launch-agent files, creates mode-0700 private log directories, removes the four exact legacy shared-log names, and verifies the app pair again. It does not replace, sign, modify, or rebuild the approved primary apps. The result is `APPROVAL_REQUIRED` and contains the manifest digest. `yabairc` and `skhdrc` call `/Users/twaldin/Applications/Yabai.app/Contents/MacOS/yabai` directly; the lifecycle does not create or change Homebrew command links.

After the operator confirms that both exact primary apps are enabled in System Settings > Privacy & Security > Accessibility, bind that confirmation to the current manifest:

```sh
/usr/bin/python3 -I yabai/deploy-lifecycle.py attest-accessibility --manifest-digest MANIFEST_SHA256
```

The module does not inspect or change TCC. The attestation is invalid after any manifest or app-pair change. Add and enable the exact `/Applications/AeroSpace.app` fallback in Accessibility too; fallback permission is an attended rollback prerequisite and is not part of the two-app primary attestation.

## Activation

AeroSpace must be fully stopped by the operator before activation. If the status is `FALLBACK_ACTIVE`, `activate` makes no primary transition and requests that attended step.

```sh
/usr/bin/python3 -I yabai/deploy-lifecycle.py activate
```

Activation starts yabai first. It then proves the exact launch job, executable path, process lane, configuration, two rules, and native Spaces 1 through 9 on primary display 1. Additional native Spaces on external displays are permitted. Only then does it start the intended skhd lane and recheck the alternate label, fallback absence, and all primary state. A failure converges all primary labels off and starts only the exact `/Applications/AeroSpace.app` fallback after that proof.

Process presence does not prove Accessibility or hotkey behavior. Before runtime acceptance, physically test:

1. Hyper-H/J/K/L and Hyper-arrow directional focus.
2. Hyper-1 through Hyper-9 native Space focus.
3. Option-Shift-1 through Option-Shift-9 send-and-follow.

Do not use synthetic input for acceptance. The activation receipt filename contains its SHA-256, so acceptance resolves one exact receipt without scanning and hashing the full directory. After those tests pass, bind the operator result to the activation receipt:

```sh
/usr/bin/python3 -I yabai/deploy-lifecycle.py accept-runtime --activation-receipt-sha256 ACTIVATION_RECEIPT_SHA256
```

## Rollback and recovery

Rollback always attempts bootout and disable for all three labels. Individual command errors do not end the sequence. Final job, disabled-state, and anonymous process readbacks decide success. Fallback absence never blocks primary shutdown.

```sh
/usr/bin/python3 -I yabai/deploy-lifecycle.py rollback
/usr/bin/python3 -I yabai/deploy-lifecycle.py recover
```

Rollback launches the fallback by its exact absolute path. It never uses application-name lookup. Recovery is idempotent. Unknown or ambiguous objects are preserved and block activation.

## Candidate build and pair publication

`build-only` is the sole wrapper identity-generation path. Give it independently reviewed source hashes, versions, and architectures. It opens source files without following links, copies and hashes from the same descriptor, verifies the staged copy before execution, builds and signs into a new mode-0700 directory, retains all artifacts, and emits `identity.json`. It cannot publish.

```sh
/usr/bin/python3 -I yabai/deploy-lifecycle.py build-only \
  --output "$HOME/Library/Application Support/dotfiles-deploy/wm-lifecycle-v1/candidate-VERSION" \
  --yabai-source /ABSOLUTE/PATH/yabai \
  --skhd-source /ABSOLUTE/PATH/skhd \
  --yabai-source-sha256 REVIEWED_SHA256 \
  --skhd-source-sha256 REVIEWED_SHA256 \
  --yabai-version VERSION \
  --skhd-version VERSION \
  --yabai-archs 'x86_64 arm64' \
  --skhd-archs 'arm64'
```

Before a primary version bump, copy the currently deployed `AppSpec` values into `PREVIOUS_APP_SPECS`, then replace the current specs with the independently reviewed candidate identities. The table is empty in the first baseline because no earlier lifecycle-managed pair is approved. A future upgrade without an explicit outgoing identity is intentionally rejected. The contract suite publishes approved version B over approved version A and exercises crash recovery back to A.

The fallback is also lifecycle-owned and byte-pinned. Do not run `brew upgrade --cask aerospace` against `/Applications/AeroSpace.app`. For a reviewed fallback update, first copy the outgoing `AEROSPACE_SPEC` into `PREVIOUS_FALLBACK_SPECS`. Independently audit the official signed candidate and record its bundle metadata, version output, architectures, executable SHA-256, `Info.plist` SHA-256, canonical tree SHA-256, and CDHash in the new `AEROSPACE_SPEC`. Verify those independently obtained pins without executing unpinned candidate bytes:

```sh
/usr/bin/python3 -I yabai/deploy-lifecycle.py verify-fallback-candidate \
  --path /ABSOLUTE/REVIEWED/AeroSpace.app \
  --short-version VERSION \
  --bundle-version NONE \
  --version-output 'EXACT VERSION OUTPUT' \
  --archs 'x86_64 arm64' \
  --executable-sha256 REVIEWED_SHA256 \
  --info-sha256 REVIEWED_SHA256 \
  --tree-sha256 REVIEWED_SHA256 \
  --cdhash REVIEWED_CDHASH
```

Obtain a new source review before publishing that exact candidate to `/Applications/AeroSpace.app`. Previous reviewed fallback identities remain accepted during the transition. The lifecycle intentionally refuses root-owned package or MDM copies because this Home deployment requires the exact user-owned app identity.

Copy candidate app identities into the runtime manifest only after independent review. Then publish the exact reviewed pair while every primary lane is off:

```sh
/usr/bin/python3 -I yabai/deploy-lifecycle.py publish-pair --source-root /ABSOLUTE/REVIEWED/CANDIDATE
```

Pair publication uses a destination-filesystem transaction directory, a mode-0600 fsynced write-ahead manifest before every rename, an exclusive lock, exact object identities, signal recovery, and old-or-new pair convergence. It never deletes an unknown object.

## Logs and runtime files

Launch-agent stdout and stderr redirects use:

- `~/Library/Logs/yabai/`
- `~/Library/Logs/skhd/`

Both directories are mode 0700. Both launch agents apply umask 077. The redirects no longer target shared `/tmp` paths.

The programs still create their required private runtime paths in `/tmp`, normally mode 0600:

- `/tmp/yabai_$USER.socket`
- `/tmp/yabai_$USER.lock`
- `/tmp/skhd_$USER.pid`

These runtime paths are not log redirects. Diagnostics report only reduced lane states and counts; they do not print process identifiers or raw process listings.

## Scope limits

- System Integrity Protection stays enabled.
- The scripting addition is not installed or loaded.
- Automatic native Space rearrangement must stay disabled.
- Primary display 1 must own exactly native Spaces 1 through 9. Additional external-display Spaces are permitted.
- Raycast and any other global shortcut owner must not overlap the documented bindings.
- A successful automated activation is not final acceptance. Physical keyboard tests and an explicit runtime-acceptance receipt are required.
