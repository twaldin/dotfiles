---
name: machine-health
description: Diagnose machine pressure or Tim's input lag on demand on twaldin-home or twaldin-work. Use for CPU, memory, filesystem, GPU or ColorSync attribution, not routine monitoring.
---

Pick the probe for the symptom and run it once. `machine-watch` schedules nothing, sends no messages and kills nothing. `machine-census`, `machine-watch` and `fsevents-top` are installed on twaldin-home and twaldin-work; `gpu-top` and the ColorSync tools on twaldin-home only.

## Pressure or input lag

- `machine-census`: CPU and memory grouped by owner, plus omp sessions with their heaviest subprocess. Memory is physical footprint (Activity Monitor's figure), not RSS, so compressed and swapped pages count. It uses `sudo -n` when available and warns that counts are partial without it. `--detail` lists each group's heaviest members; `--json` prints the structured report.
- `machine-watch`: one JSON report on stdout: the census, a 5 s FSEvents sample, ColorSync request and profile-build rates over the last 120 s, WindowServer's pid and Tim's input-idle seconds. A null value means that probe failed, not zero. It takes no arguments.
- `fsevents-top [seconds=30] [depth=5] [rows=25]`: filesystem mutations (create, modify, remove, rename; never reads or stats) grouped by path prefix. Read the event rate, top-prefix share and `dropped` count before blaming a watcher.
- `gpu-top [seconds=5] [rows=12]`: whole-GPU utilisation next to per-process busy time from the GPU driver's counters. `powermetrics` per-process GPU time reads 0 on these Macs. Lag with idle CPU can be the GPU.

## Periodic display hitches

- `colorsync-k [periods=12]`: K, the number of WindowServer ColorSync chains, from display-info requests over about 60 s; each chain costs one synchronous request and one ~57 ms frame hitch every ~5.03 s. Read-only.
- `cs-measure [secs=60]`: request rate, K, displays per request, request service-time median/p90/max, and ColorSync and WindowServer CPU over 5 s. Both tools read the log through `sudo -n`; without it a zero rate is a missing measurement.
- `logout-colorsync-test baseline`: read-only K, screens and the Agent-p2N identity. After Tim's logout and login, `logout-colorsync-test post` writes the readout to `~/.local/state/machine-shepherd/k-readout.txt` before any agent touches a screen; read it there.
- Steps `a`/`b`/`c` change Tim's displays; run them only when Tim asks, and run `logout-colorsync-test` with no arguments for the procedure.

Report the numbers that matched the symptom (CPU idle, free, compressed and swap memory, owner and pid, event or GPU rate, ColorSync K and timing). Reclaim only processes you can prove are yours, and queue the next heavy run through `shared-machine`.
