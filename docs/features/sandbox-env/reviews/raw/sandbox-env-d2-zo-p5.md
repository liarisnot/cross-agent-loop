<!-- persona: zoom_out | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer persona for a read-only review.I'll review the design as it stands now, including the prior findings and the sandbox code it extends.The design and the prior review are in. Next I’ll check the sandbox and skill code the plan says it reuses.Context is sufficient. The objective is clear: a sandboxed worker cannot see a repo's Python toolchain, and the skill should detect that, get one approval, and build an environment the existing per-run grant path can reach. That matches `worker-sandbox` (explicit grants, profile and `AppData\Roaming` refused, two slots, fixed `PATH`) and the drive-letter pattern in `skills/delegate/SKILL.md` (detect, ask once, then do the work).

## Prior resolutions

All ten items in `docs/features/sandbox-env/reviews/design-1.md` still hold.

1. The lasting grant is gone. D6 and the rejected alternative "A lasting read grant" use the existing per-run grant list. P2 is recorded. `Get-SandboxGrantList` in `Sandbox.psm1` is the function to extend.
2. The venv-copy installer is gone. D3 is a fresh `uv` resolve.
3. P3 ran. Editable installs follow `XAGENT_WORKTREE`.
4. Runs do not write `envs.json`. Last use is `.envs\linked\<name>`. Only `-Apply` writes the file, under a lock.
5. There is no disk ceiling. The 14-day prune and a size line on the proposal remain, as decided.
6. Covered by 4.
7. There is no shared `uv` cache. `UV_NO_SYNC=1` matches that dismissal. The extra cache variable is the nit below.
8. A missing `uv` is `uv-missing`. The skill does not download one.
9. The Node non-goal now says `C:\Program Files\nodejs` is absent from the sandbox `PATH`. `Get-SandboxEnvironment` builds `PATH` from Windows, PowerShell 7, Git, then read-list `addToPath` entries.
10. Diagnosis patterns and estimate constants are left to the build task. The new public surface is the two `delegate.ps1` parameter sets. The lockfile hash reuses `Get-SandboxFileHash`.

`delegate.ps1` already rejects a task id that fails `^[a-z0-9][a-z0-9-]{0,48}$`, so a worktree cannot land on `.envs`. `feature.ps1 doctor` already has a non-required `sandbox` check through `Test-SandboxSupport`. A separate non-required `sandbox-env` check that calls `-SandboxEnv` is the right split. `Invoke-DoctorFeature` returns before `Resolve-Repository` and ignores `-Repo`, so the optional `-Repo` is a real, small change.

## Findings

### 1. Major

**Affected scope:** Data, "Last use" (lines 193–195); Rules, "Status", "Linking", and the `lock` build (lines 201, 204, 209–210). Also G6 and `-SandboxRun -Base`.

**Simplicity rationale:** Line 195 says an old environment folder stays so a branch with the old lockfile still works. The rules under it only honor one current hash, taken from `git -C <repo> ls-files` and from `uv sync --project <user's checkout>`. `ready` means `envs.json` names that current hash. Linking links only `ready` environments. Prune deletes a folder when no project's current hash names it. An older folder is never linked, its `linked` stamp never moves, and the 14-day prune removes the environment a branch still needs.

Worker worktrees are a different commit from that checkout. `delegate.ps1` creates `xagent/<TaskId>` from `-Base` (for a feature build, `feature/<name>`). `-SandboxRun` also takes `-Base`. G6 cannot see a lockfile change that exists only on the tree under test, and a probe of that ref still links the checkout's environments.

One identity rule makes the sentence true: an environment is the lockfile hash (or declaration hash) for a project path. A run links the folder whose hash equals the tree it is about to execute, and the report says `missing` or `stale` when that hash is absent. `-SandboxEnv` builds the hashes of the tree it was pointed at. Prune keeps a folder a live worktree still links. That drops the second meaning of "current," where the checkout decides and every worktree inherits it.

### 2. Major

**Affected scope:** Components (lines 80–81 and 91), D4, D6, and Rules, "Linking" (line 210).

**Simplicity rationale:** Every sandboxed run links every ready environment and grants it. That includes review lenses and council seats. Those profiles are `readOnly` in `delegate.ps1`: detached worktrees, ask or plan mode, no test command. `New-SandboxRun` already takes `-ReadOnly`.

P2 measured about 2.7 seconds to grant and 2.8 seconds to remove one 4.8 GB environment. A review of a six-project repo pays that for every environment, on runs that do not execute tests. G7 grants a run the environments it links, and nothing wider. Linking also writes `.envs\linked\<name>` and, because of P5, requires an unlink before every review `worktree remove` (the three sites in `delegate.ps1`: read-only cleanup, `-Cleanup -Discard`, and ordinary `-Cleanup`).

Link and grant on worker runs and `-SandboxRun` only. Read-only runs keep the grant list they have today. The flag is already on the run path.

### 3. Nit

**Affected scope:** Environment variables (line 212); project definition and the `resolve` build (lines 70, 199, 205).

**Simplicity rationale:** `Get-SandboxEnvironment` is a closed list of generic process variables (Windows, the slot home, `PATH`, `CURSOR_INVOKED_AS`, `NODE_COMPILE_CACHE`). Adding `UV_FROZEN`, `UV_NO_SYNC`, `UV_PYTHON_DOWNLOADS`, and `UV_CACHE_DIR` there puts Python into the shared sandbox module. `UV_CACHE_DIR` also has nothing to do once `UV_NO_SYNC` is set, which is why the shared cache was dropped. `SandboxEnv.psm1` can return the extra `name=value` pairs and the `PATH` suffix, and `Get-SandboxEnvironment` can append what it is given.

The accepted no-lockfile decision is a fresh `uv` resolve. Inside that, `requirements*.txt` and a scratch `uv lock` under `.envs\work` are a second and third build recipe. The repo in the problem statement is `pyproject.toml` plus `uv.lock` in each subproject. A requirements-only tree can be `unsupported` until one appears.
