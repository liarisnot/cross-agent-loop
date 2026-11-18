<!-- persona: codebase_details | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer persona exactly.The review is Stage 9 on `docs/designs/sandbox-env.md`. I'll read that design and the sandbox, delegate, and feature sources it depends on.The design claims current sandbox behavior. I'll check those claims against the delegate and feature sources.The plan does not pass the Implementation Readiness Standard. A fresh implementer cannot produce this change without choosing behavior the document leaves open, and several statements about the sandbox and the README are false today.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 11–12; `skills/delegate/SKILL.md` lines 179–188; `skills/delegate/scripts/Sandbox.psm1` `Get-SandboxGrantList` (lines 1156–1220) and `Get-SandboxEnvironment` (lines 770–808)
**Discrepancy:** The overview says a container can read its worktree, `C:\Windows`, `C:\Program Files`, and the read list, and nothing else, and that `PATH` is Windows, PowerShell 7, Git, then `addToPath` entries. The grant list also grants the run home `<worktree>\.xagent\sandbox` with `(OI)(CI)M`, `<repo>\.git` and its children, ancestor `RA` below the drive root, and the Cursor runtime cache. `Get-SandboxEnvironment` builds this `PATH` and then appends `addToPath` entries:

`C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\PowerShell\7;C:\Program Files\Git\cmd`

Windows PowerShell 5.1 is on that path. The same design says 5.1 does not start inside an AppContainer. Any `PATH` suffix for `.envs\bin` has to be defined against this string.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 15, 34, 42, and 169; `README.md` lines 18–23
**Discrepancy:** G4, the non-goal, and the "download `uv`" alternative say the README already lists `uv` as required. The Requirements section lists Windows 11 build 26300, Pester 5.5+, a Cursor CLI under `%LOCALAPPDATA%\cursor-agent`, and three drive letters. It does not mention `uv`. The Files row that adds that sentence is the change, not the current README.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 15 and 190–198; `skills/delegate/SKILL.md` lines 190–196; `skills/delegate/scripts/delegate.ps1` lines 361–368; `skills/delegate/scripts/Sandbox.psm1` `Invoke-SandboxCanary` lines 2258–2262 and `New-SandboxRun` lines 1853–1858
**Discrepancy:** The overview says this feature follows the drive-letter pattern: detect, ask once, then build the environment and link it into each worker's worktree. Drive letters are not links inside the worktree. `Get-NoLettersReservedMessage` fails the run with `sandbox: no drive letters reserved` and a suggested `-SandboxCheck -Reserve` command. Reservation writes `sandbox.json` and `subst` maps the runtime letter onto the Cursor cache and the two slot letters onto the idle directory. Each run then `subst`s its slot letter onto that run's worktree. Worktrees are created with `git worktree add` under `<repoParent>\<repoName>.xagent\<TaskId>`. Nothing in that path creates a junction in the worktree.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 123, 189–206, 221, 242, and 250
**Discrepancy:** `install-failed` is a public status, and its `reason` is the last 20 lines of `uv`'s error. The same rules say a failed build deletes the partial folder and that `envs.json` records nothing for it. The schema has `version`, `approved`, `uv`, `uvVersion`, `pythons`, and `envs`. It has no failure record. A later `-SandboxEnv` report has no field from which to return `install-failed` instead of `missing`. The status cannot be implemented from the data the plan says is stored.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 209, 241–242, 247, and 254; `skills/delegate/scripts/Sandbox.psm1` `Get-SandboxFileHash` lines 75–85
**Discrepancy:** Three different byte sources are named for one hash. The hash rule says a `lock` project is `Get-SandboxFileHash` of a filesystem path, and a `resolve` project is the SHA-256 of each declaration file's repo-relative path and bytes in sorted order. The build rule reads those files with `git show` and writes them under `.envs\work\<name>`. Linking hashes the files in the worktree. `Get-SandboxFileHash` hashes raw file bytes. A checkout with `core.autocrlf` or a smudge filter will not match `git show` bytes, so an environment just built for the ref will not be `ready` when the worktree is linked. The concatenation for a `resolve` hash (path encoding, separators, which `requirements*.txt` names match) is not specified. `.python-version` and `uv.toml` are build inputs and, for `.python-version`, the first interpreter input, and neither is in the hash. Changing them leaves status `ready` on the old interpreter and the old index settings. The interpreter rule and G6 are then not what the status function computes.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 66 and 249 (D7)
**Discrepancy:** After the build, a project with a `[build-system]` gets a `.pth` in `site-packages` whose one line appends an import root under `XAGENT_WORKTREE` and does nothing when that variable is unset. The plan then says the fixture with a `[build-system]` settles the exact rule. That leaves the line, the import root, and the `site-packages` path to the implementer. A normal `.pth` line is a directory path and cannot read an environment variable. `site.py` executes a line only when it starts with `import `. The Windows venv directory (`Lib\site-packages`) is not named. P3's failure mode depends on this line being identical for `python.exe` and `uv run`.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 115, 227, and 243
**Discrepancy:** The 5 GB re-approval gate compares `estimateBytes` with 5 GB. Disk size for a `lock` project is "the `size` field of the Windows wheels for the chosen Python that `uv.lock` lists, scaled for unpacking," and "the factors are fixed in the implementation and its tests." Wheel choice is not defined (`win_amd64` versus `win32`, `cp312` versus `py3-none-any`, whether to skip non-Windows tags). The unpacking multiplier is explicitly left open, and it changes when the user is asked again. Interpreter size for a Python not yet under `.envs\python` is "its own size," with no source. Time is "under a minute when cached, otherwise download-bound," while the JSON field `estimateSeconds` is a number. For a `resolve` project the disk estimate is the string `"unknown"`. The plan does not say whether `"unknown"` sets `needsApproval`.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 91–92 and 257; `skills/delegate/scripts/Sandbox.psm1` `Start-SandboxProcess` lines 1874–1896; `skills/delegate/scripts/delegate.ps1` lines 93–94 and 501–523
**Discrepancy:** `-SandboxEnv` has a field-by-field JSON object. `-SandboxRun` does not. The prose says one JSON object with `status` (`ran`, `environment-missing`, or `timeout`), `exitCode`, the first 40 lines of output, and `seconds`, and that `environment-missing` lists the projects and the proposal. It does not name those keys, the exit code of the `delegate.ps1` process, how stdout and stderr are merged, or what is returned when `Get-SandboxSlot` throws. `Start-SandboxProcess` requires `-StdoutPath` and `-StderrPath`. The worker path waits with `[XagentSandbox]::Wait`, then `Kill` and `Finish` on timeout (`delegate.ps1` lines 516–523). The plan does not say the probe uses that pair, where the files go, or the worktree directory name under `<repo>.xagent`. The existing `-TimeoutSec` is `ValidateRange(30, 3600)` with default 900 on the `Run` set. A second parameter of the same name is illegal, so `-SandboxRun` inherits that range unless the plan changes the attribute. The plan gives neither a default nor a range.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` "Detailed Implementation Plan" (lines 171–276); Implementation Readiness Standard, "Phasing & Checkpoints"
**Discrepancy:** The standard requires logical phases that each leave the tree buildable and testable. The plan is one file table: a new module, two parameter sets, grant and environment changes, doctor, two skills, `build.md`, the README, the test plan, and the handoff. There is no intermediate checkpoint.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 95, 263, and 273; `skills/delegate/SKILL.md` line 219; `skills/feature/stages/build.md` lines 82 and 160–166
**Discrepancy:** Both current lead instructions say an `error` that starts with `sandbox:` is not retried. The plan tells the lead to treat `sandbox: environment not ready` as a proposal, run `-Apply` or ask, and retry the worker once. The SKILL and `build.md` rows do not say to amend those two sentences. `build.md` also runs the phase test in `<repo>` (line 160) and says to run it again after merging `main` (line 166). The plan names the phase-end command and not the retest sentence. `Invoke-TaskTestCommand` in `skills/feature/scripts/feature.ps1` (lines 2589–2650) still runs the task `test` with host `pwsh` in the worker worktree, outside the AppContainer. The file list does not mention it, and no sentence says task tests stay on the host.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 63, 92, and 263 (D4); `skills/delegate/scripts/delegate.ps1` lines 301 and 341
**Discrepancy:** D4 links environments only before a sandboxed worker run or probe, and the components bullet keeps `-NoSandbox` as the escape that does not fail closed. The Files row for `delegate.ps1` applies the link and the `sandbox: environment not ready` failure to the worker run path except read-only runs. `-NoSandbox` is a non-read-only worker path (`$sandboxed` is false only when `-Agent` is not `cursor` or `-NoSandbox` is set). Following the Files row fails the escape. `agy` is already rejected unless `-NoSandbox` is set.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 251 and 264; `skills/delegate/scripts/Sandbox.psm1` `Resolve-SandboxReadEntry` lines 659–724, `Test-SandboxReadList` lines 738–748, `Export-ModuleMember` line 2473
**Discrepancy:** Environment paths are checked with `Resolve-SandboxReadEntry` and then granted like read-list rows. That function accepts an object with a `path` string, refuses a missing path with `does not exist`, and `Test-SandboxReadList` throws `sandbox: read-list entry '<path>' <reason>; edit sandbox.json`. G4 says the user never edits `sandbox.json`. The plan does not say what the worker does when this check fails, or that the error text must not tell the user to edit the read list. `Get-SandboxFileHash` and `Invoke-SandboxAclLocked` are not exported. `delegate.ps1` only calls exported commands. The plan has `SandboxEnv.psm1` call `Get-SandboxFileHash` and a factored ACL helper, and has `-SandboxRun` call a new `Invoke-SandboxCommand`, without adding any of them to `Export-ModuleMember`.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 90, 118, 234, and 252–255
**Discrepancy:** The component list says every `-Apply` prunes environments unused for 14 days. The Rules section says prune runs after an `-Apply` build only. An `-Apply` that finds nothing to build has no defined prune behavior. Linking updates `.envs\linked\<name>` and does not take `Local\xagent-envs-...`. Prune holds that lock and re-checks the stamp immediately before delete. A link that does not take the same lock can update the stamp after the re-check and before the delete. The plan also does not say whether `approved` is written when `uv` fails part-way. Writing it at the start makes a failed first build count as the user's one approval.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 117, 195–206, and 255; `skills/delegate/scripts/Sandbox.psm1` lines 2358–2376
**Discrepancy:** P5 says `git worktree remove --force` leaves a `.venv` junction behind. Cleanup must delete the junction as a link only, never with a recursive delete. The plan does not name the call. `Remove-Item -Recurse` and `Get-ChildItem -Recurse` follow junctions. The canary already does the latter when removal leaves the directory (lines 2371–2376). Unlink has to happen before that walk, and the walk has to skip reparse points. The `sandboxNotes` line used when `.venv` is a real directory is not specified. On a 12-hex folder clash, status must not link the wrong environment, and the plan does not say whether the build overwrites that folder or refuses it.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 195, 241, 247–249
**Discrepancy:** `pythons` is keyed by major.minor (`"3.12"`), while a `.python-version` of `3.12.1` is installed as written. Two projects that need different patches of 3.12 share one map entry and one install directory. The plan does not say which patch wins. Workspace members are "every member's `pyproject.toml`" copied in the same layout. It does not say how members are found (`[tool.uv.workspace] members` globs versus the lockfile). The lock build always passes `uv sync --frozen --no-install-workspace`. It does not say what that flag does for a project that is not a workspace, and D7 says the project itself is never installed. The `requirements*.txt` build is `uv venv` on the copied interpreter, then `uv pip install -r` each file, with no `--python`, `VIRTUAL_ENV`, or `UV_PROJECT_ENVIRONMENT`, and no file order when several `requirements*.txt` files exist. `requires-python` is "the lowest version it allows that `uv python list` offers," with no specifier grammar and no rule for when `uv.lock` and `pyproject.toml` disagree.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 211–231 and 270; `skills/feature/scripts/feature.ps1` `Invoke-DoctorFeature` lines 2982–3162 and `Get-DoctorSandboxDetail` lines 2932–2978
**Discrepancy:** `-Apply` adds `built` and `pruned` with no element shape. `proposal.text` is "the proposal in plain words"; the flow diagram is an example, not the template. Doctor adds a non-required `sandbox-env` check from the report: ok when every project is `ready`, otherwise the detail lists what is missing and the estimate. It does not say what doctor does when `delegate.ps1` exits non-zero, times out, or prints the `{ok:false, error}` object from `Fail`. The existing sandbox detail is truncated at 300 characters. Doctor returns before `Resolve-Repository` and ignores `$Repo` today, which matches the plan's "without `-Repo`, leave the check out." The failure path is still unspecified. The claim that doctor currently passes neither `-Repo` nor `-Name` matches `skills/feature/SKILL.md` line 32.

## Nit

**Severity:** Nit
**Affected scope:** `docs/designs/sandbox-env.md` line 60; `skills/delegate/scripts/delegate.ps1` line 57
**Discrepancy:** "A task id can't start with `.`" is true, and it is the weaker fact. `-TaskId` must match `^[a-z0-9][a-z0-9-]{0,48}$`. Read-only worktrees are `<TaskId>-<suffix>` with the same restriction. `canary-<rand>` is the other name already used under `<repo>.xagent`. `.envs` does not collide with those names. The probe worktree name is the one the plan still has to assign.
