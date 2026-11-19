# Design review 1: sandbox-env, Stage 5 (initial zoom out)

Built from:
- `reviews/raw/sandbox-env-d1-zo-p5.md` (zoom_out, grok-4.7-medium)
- `reviews/raw/sandbox-env-d1-ic-p5.md` (inventive_catalyst, glm-5.2-high)
- Lead probes P1, P2, P3 and P5 (results in the design doc, "Probes")

The doc was updated after this round (commit `4b1bb97`).

## Findings

| # | Severity | Lenses | Finding | Resolution |
|---|---|---|---|---|
| 1 | Major | ZO 1, IC 1 | The lasting `/T` grant on all of `.envs` is a second permission system, skips `Resolve-SandboxReadEntry`, and lets one repo's runs read another repo's environments. | **Fixed.** Grants are per run, through the existing grant list (D6). P2 measured 2.7 s to grant and 2.8 s to remove on a 4.8 GB environment. |
| 2 | Major | ZO 2, IC 3 | The no-lockfile copy path is a second package installer. | **Fixed (user decision).** Dropped. Projects without `uv.lock` are resolved afresh with `uv`, outside the repo (D3). P4 is no longer needed. |
| 3 | Major | ZO 3 | The editable-install handling was left to an unrun probe, while the build rule already specified flags for it. | **Fixed.** P3 ran: a `.pth` that reads `XAGENT_WORKTREE` works for both `python.exe` and `uv run` (D7). Projects without `[build-system]` need nothing. |
| 4 | Major | ZO 4 | Every run rewrites `lastLinked` in `envs.json`, which also holds the approval, with parallel runs and no lock. | **Fixed.** Runs never write `envs.json`; last use is a per-environment stamp file. Only `-Apply` writes `envs.json`, under a named lock. |
| 5 | Major | IC 2 | Add a disk ceiling with least-recently-used eviction. | **Dismissed (user decision).** The 14-day prune is kept; every proposal shows the total size of `.envs`, and rebuilds are cheap with a warm `uv` cache (13 s for 4.8 GB). |
| 6 | Nit | IC 4 | Writes to `envs.json` need a mutex. | **Fixed** with finding 4. |
| 7 | Nit | IC 5 | Give runs a shared, read-only `uv` cache. | **Dismissed.** Runs use `uv run` against a frozen environment with `UV_NO_SYNC`, which reads no cache; P1 needed none. |
| 8 | Nit | ZO 5 | The pinned `uv` download is a second installer; report a missing `uv` instead. | **Fixed (user decision).** A missing `uv` is reported as `uv-missing`; the README lists `uv` as required. |
| 9 | Nit | ZO 6 | The Node non-goal assumed `npm` is on the sandbox `PATH`; it isn't. | **Fixed.** The non-goal now gives the right reason. |
| 10 | Nit | ZO 7 | Diagnosis text patterns, estimate constants and function names are below the design's level. | **Fixed.** The doc keeps the categories; the patterns and constants are set in the build task. |

## Probe notes found outside the design

- Cursor updates itself (about 254 MB) inside each sandboxed run's home, and tries to write the user `PATH` in the registry (denied). The long paths it leaves make `delegate -Cleanup` fail with "Filename too long" unless git uses `core.longpaths`. To be added to `docs/HANDOFF.md` as a `worker-sandbox` follow-up (after `main` is merged into this branch, which carries an edit to that file).
