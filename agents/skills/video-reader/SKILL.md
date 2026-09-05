---
name: video-reader
description: Inspect or summarize videos and screen recordings. Use native video support when available, with frame and audio extraction as a fallback.
---

Use the current harness's video capability and live documentation when it supports the source and requested analysis.

For a local file without suitable native support:

1. Use `ffprobe` to inspect duration, dimensions, frame rate, and audio streams.
2. Use `ffmpeg` to sample a small number of representative frames into a fresh task-local temporary directory. Start sparsely and bound the sampled interval and output count, especially for long recordings.
3. Inspect frames in order using the available image tool. Sample relevant intervals more densely when the question concerns a brief transition or glitch.
4. When audio matters, use available audio tools or extract audio for a configured transcription tool. Keep visual and audio evidence distinct.

Answer the user's question with useful timestamps. Describe what the inspected material establishes and identify gaps; sampled frames may miss brief events or motion. Keep the source file unchanged and extracted artifacts within the deployment that owns the recording.
