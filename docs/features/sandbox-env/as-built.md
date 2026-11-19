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
