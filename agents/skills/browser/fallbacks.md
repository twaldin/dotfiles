# Browser supplements

Choose a fallback for a specific missing capability, using its installed documentation and CLI help. Tool names here are discovery hints, not installation requirements.

- **Browser control:** `browser-harness` and `browser-use` are optional alternatives when the native tool cannot do the task. Inspect whichever is installed before selecting it; their commands and session models differ. Prefer an existing compatible driver over adding another stack.
- **Detailed recording:** if installed, `browser-trace` can collect CDP events and related screenshots/DOM snapshots when native diagnostics are insufficient. It requires a compatible exposed CDP endpoint and its own capture dependencies; some native sessions may not expose one. Keep recording on demand and store captures with the task, outside shared configuration.

Read a supplement's own instructions only when using it. Follow the host's configured tool restrictions; a fallback is not a way around them.
