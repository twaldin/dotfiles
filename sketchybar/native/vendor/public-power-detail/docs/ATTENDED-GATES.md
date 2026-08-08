# Residual hardware and attended gates

Status: **not run**. No live read, screenshot, application launch, sleep, drain, charge, hot-plug, or host mutation was used for this prototype.

Release remains blocked on these attended checks:

1. **Supported portable:** validate one current sample and natural AC to battery to AC convergence. Check adapter attach/detach wording. Do not force a warning, drain, or charge.
2. **Battery health:** compare IOPS labels, cycle count, and capacity detail with Apple UI without claiming that nominal/design equals Apple Maximum Capacity. Do not record live values.
3. **Low Power:** on supported hardware, observe `on` after the user enables it and `off_or_unsupported` after disable. Check the ambiguous wording on inapplicable hardware if available.
4. **Unsupported energy and charging modes:** confirm only disabled Settings fallback text for Automatic/High Power, Optimized Battery Charging, Charge Limit, and Charge to Full.
5. **Sleep:** confirm that the direct row has no action. The user can perform one manual sleep and physical wake. Check popup generation closure and full refresh without logging transition time.
6. **Displays:** check built-in and external all-awake, mixed, all-asleep, topology-change, and wake cases. Do not emit display identifiers. Display Sleep remains disabled.
7. **Session and Lock:** check active/inactive transitions. Confirm that no event becomes a locked or unlocked claim and that Lock stays disabled.
8. **Settings:** on macOS 15 and 26, run one attended main System Settings launch. Confirm that no pane is claimed.
9. **Schedule and privacy:** compare only an anonymous event-count shape. Confirm that no item, application name, event time, live charge, health, cycle, sleep, or session value enters logs or screenshots.
10. **Popup access:** check pointer, keyboard, focus return, VoiceOver disabled rows, privacy mode, display scale, source hot-plug, restart/stale behavior, callback bursts, and one-popup ownership.
11. **Packaging:** prove source pin, architecture, owner, mode, no-follow behavior, atomic replacement, flush, recovery, rollback, and installed hash in the future real installer.
12. **Sandbox boundary:** this prototype targets the reviewed unsandboxed helper boundary. A sandboxed build needs a separate proof.

Keep Awake has a separate owner and is not an attended gate for this component.
