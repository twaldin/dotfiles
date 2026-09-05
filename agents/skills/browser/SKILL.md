---
name: browser
description: Browser tool selection. Use when choosing browser controls, a native browser capability is missing, or browser automation needs tracing.
---

Prefer browser tools supplied by the current harness, following their live documentation. Availability depends on the session and machine, not just the harness name.

If a needed capability is absent, read [fallbacks.md](fallbacks.md) and use an available supplemental tool for that gap. Keep one driver in charge of the same tab at a time.

For debugging, inspect native console, network, and trace support first; use the tracing fallback only when more evidence is needed.

Project guidance supplies login and environment details. Browser sessions and captures stay within the work or personal deployment that owns them.
