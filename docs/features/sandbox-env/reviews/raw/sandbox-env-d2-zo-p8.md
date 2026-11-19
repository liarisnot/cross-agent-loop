<!-- persona: zoom_out | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer instructions exactly.The review is a Stage 8 zoom-out of `docs/designs/sandbox-env.md`. I'll read the design and the listed context, then check the codebase for reuse.The design is in place. Next I’ll check the sandbox, delegate, and feature code for reuse and for anything the plan would duplicate.The design passes the context check. The core is sound: one environment store per repo under `<repo>.xagent\.envs`, interpreters copied there, a `.venv` junction per project, and the existing per-run grant list. That matches how the sandbox already treats drive letters, slots, and read-list grants. The findings below are the parts that add a second path or a second policy.

## Findings

### 1. Blocker — The sandbox gate is a lead ritual, and the build's real test stays outside it

**Affected scope:** Goals G1, G5, G6 (lines 31–36); Components, the worker-run and `stages/build.md` bullets (lines 92–94); Flow on first use (lines 106–108); Files, `stages/build.md` (line 273).

**Simplicity rationale:** The root problem is that a sandboxed worker cannot see the toolchain, and nothing says so until Cursor time is already spent. This repo already has the gate for that. `delegate.ps1` fails closed with a `sandbox:` error (drive letters, read-list refusals). `skills/feature/stages/build.md` treats an error that starts with `sandbox:` as a problem stop and does not retry. The design does not use that gate.

It adds a step the lead must remember: run `-SandboxEnv`, ask, `-Apply`, then `-SandboxRun` each phase's test command before the first worker. A worker whose environment is missing still starts; the gap is a `sandboxNotes` line. That field is the cleanup log (`skills/delegate/SKILL.md`: empty when cleanup succeeded). A missing toolchain is not a cleanup note, and `ok` can still be true.

The command it probes with is the wrong one. G5 and the `build.md` row run every phase's `test` before any worker. Those commands are the phase's definition of done, and later phases are not built yet. The flow diagram only runs phase 1. Meanwhile the existing phase-end test stays in the user's checkout, on the machine that can see the live database this feature is supposed to keep workers off.

`sandboxNotes` is the wrong channel, and a pre-build run of every phase test is a second acceptance suite. A sandboxed worker or probe whose ref has a project without a `ready` environment should fail in `delegate.ps1` with a `sandbox:` error that includes the proposal, the same way a missing drive letter does. `-NoSandbox` remains the escape. After the one approval, a stale lockfile is rebuilt inside that same launch (G6), and a build over 5 GB fails closed again. `-SandboxEnv` stays the report `doctor` and the lead print. The phase test runs once, through `-SandboxRun`, at phase end.

### 2. Major — Lockless projects are a second installer, and they read the checkout the design says not to trust

**Affected scope:** What a project is (lines 69–73); D3 (line 62); D8 (line 67); Rules, Interpreter, Estimate, Build (`resolve`) (lines 241–248); Alternatives, "Projects without a lockfile" (lines 152–156).

**Simplicity rationale:** The repo that motivates this feature has a `uv.lock` per subproject. D8 says an environment is a function of the tree being run. The Inputs rule reads that tree with `git show`. The `resolve` path breaks both: it runs `uv lock` or `uv venv` plus `uv pip install -r`, estimates size from the user's `.venv\Lib\site-packages`, and the interpreter rule falls through to `version_info` in the user's `<project>\.venv\pyvenv.cfg`. Those `.venv` folders are gitignored checkout state. Two checkouts of the same ref can build different environments, and a machine without the user's `.venv` reports `unsupported`. D3 also says a fresh resolve may not match the user's versions, so this path does not reproduce the setup the user actually runs.

Other languages already stop at "missing, here is why" (Non-Goals, line 41). The same status (`unsupported`, reason `no-lockfile`) covers a Python project with no `uv.lock`. The `.venv`-copy installer was rejected in the alternatives section as a second package installer the motivating repo does not need. The `resolve` build brings that second installer back.

### 3. Major — Scraping the probe's output into a diagnosis enum

**Affected scope:** G1 (line 31); `-SandboxRun` (line 92); Rules, `-SandboxRun` diagnosis (line 256); Files, `stages/build.md` failure handling (line 273).

**Simplicity rationale:** `environment-missing` is known before the process starts. The other six values are a classifier over arbitrary test output, with the patterns deferred to code. `build.md` then branches on those strings: `module-missing` means the repo's setup is wrong, `access-denied` means the sandbox is wrong. A Python traceback or a PowerShell error will not stay inside those buckets, and a mislabel becomes a problem stop or a false pass.

`-SandboxRun` should return `exitCode`, the output prefix, `seconds`, and a structural status only: `environment-missing`, `timeout`, or `ran`. The lead already reads command output. The `sandbox:` failure in finding 1 is what stops the build.

### 4. Nit — Environment inputs belong on `New-SandboxRun`

**Affected scope:** Files, `Sandbox.psm1` (line 264); Components, "Every worker run and probe" (line 92).

**Simplicity rationale:** Workers do not call `Get-SandboxGrantList` or `Get-SandboxEnvironment`. `New-SandboxRun` does (`Sandbox.psm1` around lines 1779 and 1860), and `delegate.ps1` calls `New-SandboxRun` (line 504). That is the run seam: it already takes `-ReadOnly` and is the only production caller. The plan adds parameters to the two leaves and a new `Invoke-SandboxCommand` that calls `New-SandboxRun`, and never says `New-SandboxRun` gains the linked paths and the extra environment. The probe would get `.envs` and the worker path would not.

`New-SandboxRun` should take the extra grant paths and the extra variables. `Invoke-SandboxCommand` only chooses `pwsh` and the command. `Get-SandboxEnvironment`'s new parameters stay an internal detail of that one function.

### 5. Nit — New grant rows should go through the existing refusal check

**Affected scope:** G7 (line 37); Rules, Grant (line 251).

**Simplicity rationale:** G7 repeats the read-list bans (profile root, `AppData\Roaming`, `.ssh`, `.aws`, `.gnupg`, Cursor's folders). Those bans are enforced by `Resolve-SandboxReadEntry` and `Add-SandboxProtectedFolders` in `Sandbox.psm1`. The new rows are described as additions to `Get-SandboxGrantList`, which does not call that check. Path construction under `<repo>.xagent\.envs` is enough only until a later change grants something else.

Run each environment path through `Resolve-SandboxReadEntry` before it is added. One refusal function, the same messages `doctor` already reports.

### 6. Nit — The `.envs` lock should use the existing abandoned-mutex wait

**Affected scope:** Data, the `Local\xagent-envs-…` lock (line 187); Risks, "Prune races a run" (line 118).

**Simplicity rationale:** `Invoke-SandboxAclLocked` (`Sandbox.psm1`, lines 1351–1366) already waits, takes over an abandoned mutex, and times out. A second copy of that wait, named beside it, will drift. The `.envs` lock must stay a different mutex: holding `Local\xagent-acl` across `uv sync` would block every sandbox grant. Share the wait, not the lock name.

### 7. Nit — The `.pth` import root is a folder-name guess

**Affected scope:** D7 (line 66); Rules, Project path (line 249).

**Simplicity rationale:** D7 is the right rule: do not install the project; point at the worktree via `XAGENT_WORKTREE`. Probe P3 showed why. "Its `src` folder if it has one" is a layout guess that sits in the rules as if it were settled. A flat layout and a `src` layout with a nested package name need different roots, and the private repo's projects have no `[build-system]` at all.

Leave the import root as "the root the project declares, otherwise the project directory" and settle the path in the fixture that already has a `[build-system]`.
