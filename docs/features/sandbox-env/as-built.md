# sandbox-env: as built

What the build settled or changed relative to the locked design (`docs/designs/sandbox-env.md`). Each item names the design section it affects. These are folded into the design after the merge.

1. **Data, "Identity hash".** Hash lines use paths relative to the project folder (`../` for a `.python-version` above it), not repo-relative paths, so two projects with identical inputs really share one environment. `inputs` stays repo-relative.
2. **Rules, "Projects".** Discovery skips anything under a folder named `fixtures`, `testdata`, `test_data` or `__fixtures__`. Found by dogfooding: the gate refused this repo's own workers because the test fixture's `uv.lock` counted as a project.
3. **Rules, "Estimate"; Data, "`-SandboxEnv` output".** The PyTorch index records no `size` in `uv.lock`, so the largest package had no size. The estimate sums every recorded size, counts a source-only package's sdist size, and lists packages whose Windows wheel has no recorded size in a new `proposal.unknownSize`, named in `proposal.text` ("plus torch, torchaudio (size not recorded in uv.lock)"). `estimateBytes` is `null` only for `resolve` projects or an unreadable lock. A wheel matches by its three tags: platform `win_amd64` or `any`, and Python tag `cp<XY>`, `py3`, `py2.py3`, or ABI tag `abi3`.
4. **Rules, "Interpreter".** The interpreter is found with `uv python find <request>` under `UV_PYTHON_PREFERENCE=only-managed`; real `uv` refuses `--managed-python` together with that variable. `uv python find` returns the minor-version junction (`cpython-3.12-...`); the build records the junction's target (`cpython-3.12.12-...`), which `pyvenv.cfg`'s `home` names and which the per-run grant must cover.
5. **Rules, "Environment variables" and "Grant (D6)".** `XAGENT_WORKTREE` is set by `New-SandboxRun` from the slot it binds (whenever environment paths are passed), not by `SandboxEnv.psm1`: only `New-SandboxRun` knows the slot letter. `New-SandboxRun` and `Get-SandboxEnvironment` take `-ExtraEnv` and `-PathSuffix`; environment grant rows also get ancestor `RA` rows.
6. **Rules, "Invoke-SandboxCommand" and "-SandboxRun".** `Invoke-SandboxCommand` takes an optional `-Runtime`; the readiness gate, the `.probe-<hex>` worktree and linking are orchestrated in `delegate.ps1`. A one-line output is still an array.
7. **Rules, "Readiness gate".** Projects `unsupported` for a reason other than `uv-missing` (a workspace, an unknown Python version) do not block a run. A ready project blocks with `uv-copy-missing` when `.envs\bin\uv.exe` is missing. Linking takes the `.envs` lock with a 60-second timeout.
8. **Rules, "Prune".** An environment's age is the later of its `linked` stamp and its `built` time, so one built for another branch and never linked is not deleted the same day. Prune also drops `failed` records for hashes that are no longer current, and skips malformed index entries.
9. **Goal G5; Files, `stages/build.md`.** The phase test runs through `-SandboxRun` only when the repo's `-SandboxEnv` report lists Python projects; other repos run it in the checkout as before. This repo's own Pester suite cannot run inside the sandbox (no HKCU test registry; writes through the real path are denied).
10. **Rules, "uv workspaces".** Unchanged: unsupported in v1.
11. **Data, `-SandboxRun` output.** Adds `notes` (linking notes) and, for `environment-missing`, `message`.
12. **Not done in v1 (accepted limit).** Task acceptance tests (`feature.ps1 verify`) still run on the host in the worker's worktree; only phase tests move into the sandbox.

## Live checks at sign-off (2026-11-19, on the private repo)

1. `-SandboxEnv -Apply` built all six projects' environments in 27 s with packages in `uv`'s cache (the CUDA `torch` environment 5.12 GB, the others 0.01–0.23 GB); every project then reported `ready`.
2. One `-SandboxRun` (9 s): `uv run python` started in each of the five other projects' linked environments and imported a dependency; `src/tts` ran `tests/test_align.py`, 11 passed.
3. A sandboxed Cursor worker (21 s) ran the same test, 11 passed; `changes` was empty (the `.venv` link is not reported).
4. `uv pip install tomli-w` inside the sandbox failed with `Access is denied` on the environment's `site-packages`. (`uv` environments have no `pip` module.)
5. `-Cleanup -Discard` of that worker left `.envs` intact: 46,230 files before and after.
6. `-SandboxCheck -Repo` canary: all 13 rows pass.
Not run live: the older-lockfile case and the review-lens case (covered by unit tests).

## Drift check findings accepted as built

The sign-off drift check (`reviews/raw/sandbox-env-s1-dr.md`) also listed these. Each was decided in a task file during the build:

- **Linking notes.** Linking adds notes for a missing project folder, a missing environment folder and a `.venv` that is a real folder or a non-junction link, and still passes `.envs\bin`, the `uv` variables and `XAGENT_WORKTREE` when a ready project could not be linked.
- **Phase end.** The lead runs `-SandboxEnv` (and `-Apply` if needed) before the phase test, to decide whether the repo has Python projects and to make sure the environments are ready.
- **`-Rebuild`.** Throws (exit 1) for a project not found at the ref or `unsupported`; it rebuilds only the environment of the project's current hash, and an older one is left to the 14-day prune.
- **Prune.** Removes the `envs` entry and lists the environment in `pruned` even if deleting its folder fails, with a warning. It deletes the interpreter's real folder; `uv` recreates the minor-version junction on the next install.
- **`-SandboxRun`.** A failed worktree removal after the run does not change the result (the run's own outcome is what the lead needs).
- **Estimate.** Each package counts its largest matching wheel, not the sum of several matching wheels (one wheel is installed). `envsBytes` and the size in `proposal.text` are the sum of recorded environment sizes, not a walk of `.envs`. An interpreter counts as installed when any `pythons` key has the same major.minor (the request names a major.minor).
- **Interpreter request.** The first clause of `requires-python` that matches a known form wins (later clauses are tried when the first is not one of them); `>=X.Y.Z` gives `X.Y`.
- **`uv` lookup.** `Get-SandboxUvPath` is evaluated on every call (no cache).
- **Build failure text.** The last 20 lines of the failing step's stderr followed by its stdout.
- **`--python <exact version>`** is passed to `uv lock` and `uv sync`, so the environment uses the interpreter the build installed.
- **`.envs` lock timeout.** `-Apply` waits up to 1800 s (builds take minutes); linking waits 60 s.
- **`doctor`'s `sandbox-env` check** uses the readiness gate's rule: `unsupported` projects for other reasons do not fail it, and the detail lists only blocking projects.
- **Refused environment path message.** Says `run -SandboxEnv -Repo <repo> -Apply` (plus `-Rebuild <project>` when the path belongs to a project).
- **Discovery.** A lock at the repo root does not cover projects in subfolders; a lock in a subfolder covers that folder's `pyproject.toml` and `requirements*.txt` files below it.
- **Unlinking** removes junctions in the project folders at the worktree's `HEAD` and the root; if `HEAD` cannot be read, only the root. `Remove-Worktree`'s recursive delete does not follow junctions in PowerShell 7.
- **Canary.** Links no environments, so it has nothing to unlink; its fallback delete skips reparse points.
