<!-- persona: zoom_out | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer persona exactly.I'll audit the design against the zoom-out standard and check the cited code for reuse.The design is in hand. Next I’ll check the project’s existing launch path and whether the new modules duplicate something already there.Context is sufficient. The objective is clear: `delegate` agents run as the user, with `--force`, and can read the disk and the network. The design confines them with a Windows AppContainer, keeps the current `delegate.ps1` parameters, and fails closed. AppContainer is the smallest mechanism that meets that on Windows 11 Home and still runs this repo's Windows tests. Rejecting the host proxy, WSL, a second Windows account, and a per-run clone is consistent with that. The findings below are the places the design adds a second mechanism, a second contract, or a goal the plan never builds.

## Findings

### 1. The network "switch" is a goal with no caller

**Severity:** Major

**Affected scope:** G3 (lines 27–28); "Launch and kill" (line 149); `New-SandboxRun` (lines 389–400)

**Simplicity rationale:** G3 still says each run either has internet or has none. The plan grants `internetClient` to every container, and `New-SandboxRun` has no network parameter. Workers, lenses, and council seats all need Cursor's servers, so the off position has no caller. Alternative K correctly leaves a host allow-list as a future improvement. Leaving the switch in the goal invites a second mode, a flag, and tests for a case this feature does not use. The requirement should say what the plan already does: every sandboxed run has internet, and file isolation is what keeps secrets off the network.

### 2. Sandbox launch reimplements `cursor-agent.ps1`

**Severity:** Major

**Affected scope:** "Launch and kill" (lines 143–147); the component diagram (line 110); `Get-SandboxRuntime` and `New-SandboxRun` (lines 373–401)

**Simplicity rationale:** The probe's reason for skipping the wrapper is that Windows PowerShell 5.1 does not start in an AppContainer. PowerShell 7 does. The launcher that already exists, `%LOCALAPPDATA%\cursor-agent\cursor-agent.ps1`, selects the version (including the `YYYY.MM.DD-HH-MM-SS-commit` form), sets `CURSOR_INVOKED_AS`, sets `NODE_COMPILE_CACHE`, and runs `node.exe index.js`. The design grows a second bootstrap: a vague `<latest>` folder, a hand-built environment list, and a direct `R:\node.exe R:\index.js` command line. That list already omits `NODE_COMPILE_CACHE`. The C# `CreateProcessW` path has to stay, because that is what attaches the AppContainer. The process it starts can be `pwsh -File` on a copy of `cursor-agent.ps1` sitting next to the patched `node.exe` in the runtime cache, which is the wrapper's "node.exe beside the script" branch. Version choice then stays in Cursor's script instead of a sorter this repo would have to keep matching.

### 3. Git's parent-folder rule is implemented as two special cases

**Severity:** Major

**Affected scope:** "What the sandbox can reach" (lines 121–122); "Why drive letters" (lines 131–133)

**Simplicity rationale:** The design states the real rule: git resolves a `subst` letter to the real path and checks every parent, and never the drive root. The grant table then names only `<repo>` and `<repoParent>\<repo>.xagent`. That covers a repo that sits directly on a drive (`D:\cross-agent-loop`). It does not cover `D:\src\<repo>` or a clone under the user profile, which is a normal Windows layout for a skill whose workflow is unchanged for any repo. The simpler statement of the same grant is one non-inheriting read-attributes entry on each ancestor of the worktree and of `.git`, stopping before the drive root. No new capability and no broader read. The probe already showed why a worktree under the profile fails when those parents are missing.

### 4. The sandbox build also upgrades Pester

**Severity:** Major

**Affected scope:** Machine setup (line 337); file 7, `scripts/test.ps1` (lines 465–472)

**Simplicity rationale:** The locked feature design, `feature.ps1 doctor`, and `skills/feature/tests/feature.Tests.ps1` are on Pester 5.5 or later. The user-scoped install is invisible inside an AppContainer because it lives under the profile. The fix for that is an AllUsers install of the same Pester the suite already runs. This design instead installs 6.2.0, points `PSModulePath` only at Program Files, and makes `scripts/test.ps1` require 6.2.0 or later. A new single test command is warranted: two suites, and `TestRegistry.Enabled = $false` so the suite can run in the container. That script should keep `Import-Module Pester -MinimumVersion 5.5`, the same contract as `docs/designs/feature-skill.md`'s Verification Plan. A major-version move of the test stack is a separate change.

### 5. G7 is a second project on the riskiest task

**Severity:** Nit

**Affected scope:** G7 (line 32); "The two-part task template" (lines 175–177); build order phase 2 (line 524)

**Simplicity rationale:** The root problem is file isolation. G7 tries a looser task template and records the comparison. It adds no sandbox behavior, and the plan already keeps it out of `skills/feature/templates/task.md` until afterward. Phase 2 is the binary patch, the AppContainer profile, and the drive letters, and it is also the task that uses the untested brief. A bad result there does not say whether the template works. Keep the experiment off the security boundary.

### 6. G2 says read-only runs cannot write; the worktree still has a writable home

**Severity:** Nit

**Affected scope:** G2 (line 27); CUJ 3 (lines 63–68); access table (line 123)

**Simplicity rationale:** Lenses and council seats get a read-only worktree, then a read-write exception on `<worktree>\.xagent\sandbox`, where `auth.json` is copied. The existing read-only check already ignores `.xagent/`, so "the worktree is unchanged" and "the run cannot write" are different bars. Putting the home on `W:` is the small choice: Node can walk a `subst` root, and a third drive letter is more mechanism. The goal text should match the table. A read-only run cannot change git-visible files; it can write its run home. The token copy stays the accepted risk already in the Security table.

## Reuse checked

`delegate.ps1` already has `Quote`, the secret-variable denylist, and `Start-Process` of `cursor-agent.ps1` through Windows PowerShell 5.1. The unsandboxed path keeps that denylist. `Process.Kill($true)` is already what the probe found works where `taskkill.exe` hangs. `feature.ps1` has three `taskkill.exe` sites. Collapsing those into `Stop-ProcessTree` is reuse, not a new killer. `scripts/new-sandbox.ps1` is a throwaway git fixture for the feature checklist. It is unrelated to AppContainer, and the design does not try to extend it. No existing module creates an AppContainer, a job object, or a `subst` map. `SandboxNative.cs` coming from the probe's `AC` class is the right reuse. The probe scripts should stay throwaway.
