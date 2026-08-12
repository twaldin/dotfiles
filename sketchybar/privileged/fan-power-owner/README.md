# Fan and power owner (not installed)

This directory is a reviewed release payload. It is **not installed** by the dotfiles checkout or by `install-deps.sh`. The payload does not use the Stats privileged helper and does not send fan writes through Stats.

## Closed behavior

The root LaunchDaemon accepts one canonical JSON request per authenticated Unix-domain connection. It accepts only:

- status;
- all fans to firmware **Automatic**;
- all fans at their hardware-reported maximum for one 60-second lease;
- `Automatic`, `Low Power`, or `High Power` for the exact active `battery` or `ac` profile, and only when `pmset` reports that mode as supported.

There is no fixed lower RPM, custom RPM, curve, arbitrary command, environment-selected binary, configuration path, process list, or telemetry command. Power writes use `pmset -b` or `pmset -c`. They never use `pmset -a`.

A fan mutation has an exact preflight, one policy mutation, and readback. An uncertain fan result biases to maximum airflow. On launch after boot or crash, the daemon does not expose its socket as healthy unless it first proves Automatic. A Boost lease is non-renewable while active. Its monotonic 60-second deadline starts before the maximum write, not after readback. Boost returns to Automatic at lease expiry, client disconnect, sleep/wake, clean daemon termination, or daemon restart. If Automatic cannot be proved, the owner reports failure, retains the safer maximum-airflow bias, and exposes only recovery. A power mutation records every changed field in the exact active source profile, performs one `-b` or `-c` write, reads it back, and rolls back and proves those same source-profile fields after a readback failure, source switch, nonzero result, or uncertain timeout. A physical AC or battery source switch is external state; the owner does not and cannot switch it back.

## Trust boundary

- After startup Automatic recovery succeeds, the daemon creates and owns the socket at `/var/run/com.twaldin.sketchybar.fan-power-owner.sock`. Launchd does not pre-create it.
- The socket is connectable but not authoritative. The daemon obtains one immutable audit token from the connected socket. It binds the real and effective UID, PID generation, exact installed executable path, strict live code validity, identifier, and the exact client CDHash embedded at build time to that token.
- Requests have exact keys and canonical bytes. A 32-hex-character random nonce has a 30-second clock window, a 120-second replay window, and a 4,096-entry bound.
- The native client checks root ownership, single-link regular-file shape, exact non-writable modes, immutable flags, the daemon signature, its identifier, and the root-owned socket before it reports `trusted=true`.
- There is no Developer ID for this local-only payload. The installer applies hardened ad-hoc signatures, then publishes root-owned immutable binaries and plist files. The local root account remains the trust root.

## Verify without installation

The verification script builds only in a private temporary directory. It does not load a daemon and does not write fan or power state.

```sh
/Users/twaldin/dotfiles/sketchybar/privileged/fan-power-owner/scripts/verify.sh
```

## Attended install

Review `RELEASE-MANIFEST.sha256`, the source, the independent security review, and the command before use. This is the exact attended command prepared for the approved `twaldin` binding:

```sh
/usr/bin/sudo -- /bin/sh -ceu '
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
source=/Users/twaldin/dotfiles/sketchybar/privileged/fan-power-owner/install.sh
expected=bc386b90e07830791a9f155be6a33bf3e65cfd4b09d09f63f61c4482d0ac0205
[ -f "$source" ] && [ ! -L "$source" ]
[ "$(/usr/bin/stat -f "%Su %HT %Lp %l" "$source")" = "twaldin Regular File 755 1" ]
[ "$(/usr/bin/shasum -a 256 "$source" | /usr/bin/cut -d" " -f1)" = "$expected" ]
work=$(/usr/bin/mktemp -d /private/var/tmp/fan-power-owner-bootstrap.XXXXXX)
trap "/bin/rm -rf $work" EXIT HUP INT TERM
[ "$(/usr/bin/stat -f "%u %g %HT %Lp" "$work")" = "0 0 Directory 700" ]
bootstrap_code=aW1wb3J0IG9zLHN0YXQsc3lzCnMsZCxuPXN5cy5hcmd2WzFdLHN5cy5hcmd2WzJdLGludChzeXMuYXJndlszXSkKYz1beCBmb3IgeCBpbiBzLnNwbGl0KG9zLnNlcCkgaWYgeF0KZj1vcy5vcGVuKG9zLnNlcCxvcy5PX1JET05MWXxvcy5PX0RJUkVDVE9SWXxvcy5PX0NMT0VYRUMpCnRyeToKIGZvciB4IGluIGNbOi0xXToKICBxPW9zLm9wZW4oeCxvcy5PX1JET05MWXxvcy5PX0RJUkVDVE9SWXxvcy5PX05PRk9MTE9XfG9zLk9fQ0xPRVhFQyxkaXJfZmQ9Zik7b3MuY2xvc2UoZik7Zj1xCiBpPW9zLm9wZW4oY1stMV0sb3MuT19SRE9OTFl8b3MuT19OT0ZPTExPV3xvcy5PX0NMT0VYRUN8b3MuT19OT05CTE9DSyxkaXJfZmQ9ZikKZmluYWxseTogb3MuY2xvc2UoZikKdD1vcy5mc3RhdChpKQppZiBub3Qgc3RhdC5TX0lTUkVHKHQuc3RfbW9kZSkgb3IgdC5zdF9ubGluayE9MSBvciB0LnN0X3NpemUhPW4gb3IgdC5zdF9tb2RlJjBvMDIyOiBvcy5jbG9zZShpKTtyYWlzZSBTeXN0ZW1FeGl0KDEpCm89b3Mub3BlbihkLG9zLk9fV1JPTkxZfG9zLk9fQ1JFQVR8b3MuT19FWENMfG9zLk9fTk9GT0xMT1d8b3MuT19DTE9FWEVDLDBvNTAwKQp0cnk6CiB3aGlsZSBuOgogIGI9b3MucmVhZChpLG1pbihuLDY1NTM2KSkKICBpZiBub3QgYjogcmFpc2UgU3lzdGVtRXhpdCgxKQogIG4tPWxlbihiKQogIHdoaWxlIGI6CiAgIHo9b3Mud3JpdGUobyxiKQogICBpZiB6PDE6IHJhaXNlIFN5c3RlbUV4aXQoMSkKICAgYj1iW3o6XQogaWYgb3MucmVhZChpLDEpOiByYWlzZSBTeXN0ZW1FeGl0KDEpCmZpbmFsbHk6IG9zLmNsb3NlKGkpO29zLmNsb3NlKG8pCg==
/usr/bin/python3 -I -S -c "$(/usr/bin/printf %s "$bootstrap_code" | /usr/bin/base64 -D)" \
  "$source" "$work/install.sh" 24307
[ "$(/usr/bin/shasum -a 256 "$work/install.sh" | /usr/bin/cut -d" " -f1)" = "$expected" ]
exec "$work/install.sh" "$@"
' fan-power-owner-bootstrap install --target-user twaldin --manifest-sha256 08d951629b2d5c75c543bc9c559c827470cf772e3e14516a6b837aeefd6f3bfd
```

The attended root shell receives fixed command text as an argument. It checks the exact installer hash, copies the installer to a new root-only mode-0500 directory, verifies that copy, and executes only the root-owned copy. The installer then checks the root invocation, exact source path, account and home binding, source ownership and modes, the release manifest, the plist, both ad-hoc signatures, installed ownership/modes/immutable flags, launchd registration, and an authenticated status response. One root-only lifecycle lock serializes every install and uninstall through proof, publication, removal, and rollback. It copies and verifies a root-owned release snapshot before SwiftPM parses or compiles it. SwiftPM uses an explicit root-private scratch path. Publication and registration use a verified transaction. A failure restores and proves the exact prior file hashes, signatures, immutable flags, loaded state, root socket, and authenticated status, or proves the exact first-install absence. Uninstall repeats that exact release and loaded-state proof after the client proves Automatic and before it removes anything.

A fixed `rollback incomplete` result with exit 2 means an operating-system failure prevented proof of that restoration. Stop. Do not retry and do not remove a target by hand. Exit 2 preserves both the root-only lifecycle lock and the root-private transaction workspace. The exact prior backups remain below `/private/var/tmp` with the `fan-power-owner-install.` or `fan-power-owner-uninstall.` prefix for attended inspection and recovery. A process crash can also leave the root-only lifecycle-lock directory in place so that another transaction cannot cross an uninspected state. Remove that lock only during attended recovery after the installed files, registration, socket, and saved prior release are reconciled. A normal exit 1 completed its rollback proof.

No agent ran this command. Installation changes the live system and starts recovery by returning fans to Automatic.

## Safe uninstall

```sh
/usr/bin/sudo -- /bin/sh -ceu '
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
source=/Users/twaldin/dotfiles/sketchybar/privileged/fan-power-owner/install.sh
expected=bc386b90e07830791a9f155be6a33bf3e65cfd4b09d09f63f61c4482d0ac0205
[ -f "$source" ] && [ ! -L "$source" ]
[ "$(/usr/bin/stat -f "%Su %HT %Lp %l" "$source")" = "twaldin Regular File 755 1" ]
[ "$(/usr/bin/shasum -a 256 "$source" | /usr/bin/cut -d" " -f1)" = "$expected" ]
work=$(/usr/bin/mktemp -d /private/var/tmp/fan-power-owner-bootstrap.XXXXXX)
trap "/bin/rm -rf $work" EXIT HUP INT TERM
[ "$(/usr/bin/stat -f "%u %g %HT %Lp" "$work")" = "0 0 Directory 700" ]
bootstrap_code=aW1wb3J0IG9zLHN0YXQsc3lzCnMsZCxuPXN5cy5hcmd2WzFdLHN5cy5hcmd2WzJdLGludChzeXMuYXJndlszXSkKYz1beCBmb3IgeCBpbiBzLnNwbGl0KG9zLnNlcCkgaWYgeF0KZj1vcy5vcGVuKG9zLnNlcCxvcy5PX1JET05MWXxvcy5PX0RJUkVDVE9SWXxvcy5PX0NMT0VYRUMpCnRyeToKIGZvciB4IGluIGNbOi0xXToKICBxPW9zLm9wZW4oeCxvcy5PX1JET05MWXxvcy5PX0RJUkVDVE9SWXxvcy5PX05PRk9MTE9XfG9zLk9fQ0xPRVhFQyxkaXJfZmQ9Zik7b3MuY2xvc2UoZik7Zj1xCiBpPW9zLm9wZW4oY1stMV0sb3MuT19SRE9OTFl8b3MuT19OT0ZPTExPV3xvcy5PX0NMT0VYRUN8b3MuT19OT05CTE9DSyxkaXJfZmQ9ZikKZmluYWxseTogb3MuY2xvc2UoZikKdD1vcy5mc3RhdChpKQppZiBub3Qgc3RhdC5TX0lTUkVHKHQuc3RfbW9kZSkgb3IgdC5zdF9ubGluayE9MSBvciB0LnN0X3NpemUhPW4gb3IgdC5zdF9tb2RlJjBvMDIyOiBvcy5jbG9zZShpKTtyYWlzZSBTeXN0ZW1FeGl0KDEpCm89b3Mub3BlbihkLG9zLk9fV1JPTkxZfG9zLk9fQ1JFQVR8b3MuT19FWENMfG9zLk9fTk9GT0xMT1d8b3MuT19DTE9FWEVDLDBvNTAwKQp0cnk6CiB3aGlsZSBuOgogIGI9b3MucmVhZChpLG1pbihuLDY1NTM2KSkKICBpZiBub3QgYjogcmFpc2UgU3lzdGVtRXhpdCgxKQogIG4tPWxlbihiKQogIHdoaWxlIGI6CiAgIHo9b3Mud3JpdGUobyxiKQogICBpZiB6PDE6IHJhaXNlIFN5c3RlbUV4aXQoMSkKICAgYj1iW3o6XQogaWYgb3MucmVhZChpLDEpOiByYWlzZSBTeXN0ZW1FeGl0KDEpCmZpbmFsbHk6IG9zLmNsb3NlKGkpO29zLmNsb3NlKG8pCg==
/usr/bin/python3 -I -S -c "$(/usr/bin/printf %s "$bootstrap_code" | /usr/bin/base64 -D)" \
  "$source" "$work/install.sh" 24307
[ "$(/usr/bin/shasum -a 256 "$work/install.sh" | /usr/bin/cut -d" " -f1)" = "$expected" ]
exec "$work/install.sh" "$@"
' fan-power-owner-bootstrap uninstall --target-user twaldin --manifest-sha256 08d951629b2d5c75c543bc9c559c827470cf772e3e14516a6b837aeefd6f3bfd
```

Uninstall first uses the allowlisted client to command and prove Automatic. It removes nothing if that proof fails. It then unregisters and removes the exact immutable artifacts transactionally. A failure restores the prior release and registration.

## UI recovery

The TMP popup renders fan or power actions only after the installed client proves provenance and the daemon returns live supported capabilities. While an action is in progress, the control region is visibly inert. If trust or permission checks fail, the region has one action: **Open install and permission recovery**. It opens this file; it never invokes `sudo`.
