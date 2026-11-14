# Plan: worker-sandbox

Build worker-sandbox as designed in docs/designs/worker-sandbox.md (locked at 6ca02a1): every delegate agent run starts inside a Windows AppContainer on a reserved slot drive letter, with per-run grants, a slot ledger and a patched copy of Cursor's node.exe. READING THE BRIEFS: 'file N' means entry N under the design's 'Detailed Implementation Plan > Target Files to Create/Modify'; the design is the source of truth wherever a brief is shorter. Profiles (code, code-hard) pick the delegate worker model from skills/delegate/models.json. WORKER TASKS: seven, in five phases, following the design's Build order with one deliberate change: phase 2 runs after phase 1 instead of beside it, because every task's test command is scripts/test.ps1, which phase 1 creates. Phase 3's task file is the G7 experiment: it is written in two parts (Decided / Yours to decide) and afterwards compared with fb-stages, the earlier tightly specified code-hard task (the feature skill's build step 4, D19 in docs/test-plan.md). Phase 4's two tasks run one after the other, because both test runs execute the container tests, which reserve real drive letters and slot profiles. LEAD AND USER STEPS (not tasks): (1) before phase 1, with the user's approval, the lead creates the frozen copy (git worktree add --detach D:/cross-agent-loop.frozen 6ca02a1) and points ~/.claude/skills/delegate and ~/.claude/skills/feature at it (G6); (2) the first sandboxed run on the real machine needs the user to approve three drive letters (CUJ 1); tests reserve and release their own; (3) after phase 5 the lead runs the checks that need a real Cursor login or a human (the Live canary as worker, lens and council seat; the suite inside the sandbox; the delegate regression; crash recovery; overhead; the token-refresh check over at least a day) and records them, the G6 skillDir check and the G7 comparison in docs/test-plan.md and docs/HANDOFF.md. No step involves secrets, credentials or deploys.

Check-in mode: on-problems

## Phase 1

Groundwork with no sandbox code: one test command for workers and the lead, and no taskkill.exe anywhere, so this repo's own suite can later run inside the sandbox.

Test: `pwsh -NoProfile -File scripts/test.ps1`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| test-runner | scripts/test.ps1: the repo's one test command | — | scripts/test.ps1 | code | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**test-runner.** Create scripts/test.ps1 as the design's file 7 specifies: param([switch]$Fast); Import-Module Pester -MinimumVersion 5.5; New-PesterConfiguration with Run.Path set to whichever of skills/feature/tests and skills/delegate/tests exist (resolved from the script's own folder, so it works from any working folder; if neither exists, print 'no test folders' and exit 0), Run.PassThru = $true, TestRegistry.Enabled = $false (Pester's test registry writes HKCU, which an AppContainer cannot write), Filter.ExcludeTag 'Live' plus 'Slow' with -Fast, Output.Verbosity 'Normal'; exit with [Math]::Min($result.FailedCount, 250). Nothing else changes.
| kill-tree | Replace taskkill.exe with a .NET tree kill | test-runner | skills/feature/scripts/feature.ps1<br>skills/feature/tests/feature.Tests.ps1<br>skills/delegate/scripts/delegate.ps1 | code | `pwsh -NoProfile -File scripts/test.ps1` |

**kill-tree.** Add Stop-ProcessTree -ProcessId to feature.ps1 ([Diagnostics.Process]::GetProcessById($id).Kill($true), ignore 'process has exited' and 'not found', wait up to 10 s) and use it at the three taskkill.exe sites: the reconcile orphan kill (~line 1806), the verify timeout in Invoke-TaskTestCommand (~2290) and the Invoke-DoctorCommand timeout (~2556). In delegate.ps1, replace the timeout's '& taskkill.exe /T /F /PID' (line ~349) with 'try { $proc.Kill($true) } catch {}; $proc.WaitForExit(10000) | Out-Null'; nothing else in delegate.ps1 changes in this task. Add an UNTAGGED feature.Tests.ps1 test (not Slow) that a two-level child process tree (pwsh starting pwsh starting Start-Sleep) is fully gone after Stop-ProcessTree. Acceptance also includes: 'git grep -n taskkill -- skills/feature/scripts skills/delegate/scripts' finds nothing. The test command runs the full suite because the existing tests that cover these kill sites (feature.Tests.ps1 lines ~1485 and ~2281) are tagged Slow.

## Phase 2

The sandbox core: the native launcher and everything that does not depend on a run: support check, runtime cache and node.exe patch, reserved letters. Fully specified by the design (files 1 and 2, the functions the Build order lists for phase 2).

Test: `pwsh -NoProfile -File scripts/test.ps1 -Fast`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| sandbox-core | SandboxNative.cs and Sandbox.psm1 part 1 (support, runtime cache and patch, letters) | test-runner | skills/delegate/scripts/SandboxNative.cs<br>skills/delegate/scripts/Sandbox.psm1<br>skills/delegate/tests/Sandbox.Tests.ps1 | code-hard | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**sandbox-core.** Implement exactly what docs/designs/worker-sandbox.md specifies for phase 2. File 1, SandboxNative.cs: XagentSandbox with EnsureProfile, DeleteProfile, Start, Wait, Kill, Finish, IsAppContainer, and RunHandle, with the constants, handle-inheritance and environment-block rules given there. File 2, Sandbox.psm1: its Settings, Test-LetterFree, Test-SandboxSupport (all checks except the read-list rule, which phase 3 adds), Get-SandboxRuntime (version choice, reuse contract, copy, patch, prune), Get-SandboxConfig, Set-SandboxLetters and Initialize-SandboxLetters, with the exact error strings; every thrown error starts with 'sandbox:'. Pinned here because other tasks consume them: (a) Test-SandboxSupport returns {ok, build, cursorVersion, uv, patternCount, letters, problems[]} where letters is {reserved: bool, runtime: <letter or null>, slots: [<letters>], states: {<letter>: 'free'|'ours'|'used'}}; no letters reserved is NOT a problem (ok stays true, reserved = false); (b) the copy path first deletes any existing <version> folder and any <version>.partial; (c) the module loads SandboxNative.cs only if the type is not loaded yet (if (-not ('XagentSandbox' -as [type])) { Add-Type -Path ... }), so importing it twice in one process works. Tests: the phase-2 unit tests listed in file 5, in skills/delegate/tests/Sandbox.Tests.ps1, using XAGENT_SANDBOX_ROOT and XAGENT_CURSOR_ROOT under TestDrive; no test calls a real model or touches the user's sandbox.json. The version-choice test takes its oracle from the real launcher: it extracts Parse-VersionString from %LOCALAPPDATA%/cursor-agent/cursor-agent.ps1 with the PowerShell AST, and skips with a reason when that file is unreadable. Reference: docs/designs/worker-sandbox-probe/ (probe5.ps1's AC class; the pattern bytes and offset in the README).

## Phase 3

Running one sandboxed task: slots, grants, the ledger, the run home, the read list, launch, stop, the canary and release. This is the G7 task: its task file is written in two parts, Decided and Yours to decide, and compared afterwards with fb-stages.

Test: `pwsh -NoProfile -File scripts/test.ps1 -Fast`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| sandbox-run | Sandbox.psm1 part 2: slots, grants, ledger, read list, launch, stop, canary, release | sandbox-core | skills/delegate/scripts/Sandbox.psm1<br>skills/delegate/scripts/SandboxNative.cs<br>skills/delegate/tests/Sandbox.Tests.ps1<br>skills/delegate/tests/fixtures/ | code-hard | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**sandbox-run.** G7 two-part task. Decided: the public functions and parameters of Get-SandboxSlot, New-SandboxRun, Start-SandboxProcess, Stop-SandboxRun, Remove-SandboxGrants, Invoke-SandboxCanary and Remove-SandboxLetters as the design states them; Remove-SandboxLetters with nothing reserved is a no-op that returns released = [] and does not throw; the slot ledger format; the access table's paths and icacls specs; the read-list rules and refusal order; the run-home layout and copied files; the environment array; every error string; Test-SandboxSupport gains the read-list check; and the phase-3 unit and container tests listed in file 5 as acceptance tests. Yours to decide: internal helpers, how icacls calls are built and parsed, how the mutex and ledger checks are structured, internal tests beyond the listed ones, and the order of work. SandboxNative.cs may change only if a test proves it must. Two probe checks, observe-only (they do not block the task; report each result in result.json's summary): run them against a scratch root (XAGENT_SANDBOX_ROOT = <worktree>/.xagent/probe-root) with letters the probe reserves itself and releases afterwards, never the real %LOCALAPPDATA%/xagent; (1) Cursor --version, then a -p run with the prompt 'Reply with the single word OK.' and a 120 s timeout, inside a slot with --workspace <real worktree path> and working folder <slot>:\ (the run home gets the copied Cursor login as the design says, and it is deleted with the probe root); (2) if a per-user Python is installed, start it from a read-list entry with python -c "print(1)".

## Phase 4

Wire the sandbox into delegate.ps1 (default on, -NoSandbox, -SandboxCheck with -Reserve and -Release, new summary fields) and add the fast sandbox check to doctor. The two tasks run one after the other: both test runs execute the container tests, which reserve real drive letters and slot profiles.

Test: `pwsh -NoProfile -File scripts/test.ps1`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| delegate-wiring | delegate.ps1: sandbox by default, parameter sets, -SandboxCheck, summary fields | sandbox-run | skills/delegate/scripts/delegate.ps1<br>skills/delegate/tests/DelegateLaunch.Tests.ps1<br>skills/delegate/tests/fixtures/ | code | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**delegate-wiring.** Implement the design's file 3: the Run and Check parameter sets, -NoSandbox, -SandboxCheck, [string[]]$Reserve, -Release and the invalid combinations; -SandboxCheck handled before $Repo is resolved and before the -Agent and -TaskFile guards; $cursorRoot from XAGENT_CURSOR_ROOT; the sandboxed launch with the try moved before Get-SandboxSlot and Stop-SandboxRun in finally; exitCode from Finish, -1 on timeout; summary and runs.jsonl gain sandboxed, sandbox, skillDir and sandboxNotes; help comment. Add skills/delegate/tests/DelegateLaunch.Tests.ps1 and the fake Cursor fixture (skills/delegate/tests/fixtures/fake-cursor/index.js) as file 6 lists, with all its cases, and these two precisions: (a) the fixture copies node.exe from the real Cursor install's current version; every Describe that needs that copy skips itself with a reason when %LOCALAPPDATA%/cursor-agent/versions is unreadable (as inside the sandbox, where LOCALAPPDATA is the run home), so the suite still passes when run inside the sandbox; (b) the patch-failure case zeroes the pattern bytes in the fixture's SOURCE node.exe (TestDrive/cursor-agent/versions/2099.01.01-abc123/node.exe) and starts with no runtime cache and no patch.json, so Get-SandboxRuntime must take the copy-and-patch path and fail with 'pattern found 0 times'.
| doctor-check | feature.ps1 doctor: fast sandbox check | delegate-wiring | skills/feature/scripts/feature.ps1<br>skills/feature/tests/feature.Tests.ps1 | code | `pwsh -NoProfile -File scripts/test.ps1` |

**doctor-check.** Implement the design's file 4 doctor bullet: a tenth check named 'sandbox' that imports Sandbox.psm1 in-process from the delegate skill folder, found the same way doctor already finds it ($delegateDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../delegate')), see feature.ps1 ~line 2641), and calls Test-SandboxSupport; required = $false so ready is unaffected; detail lists cursorVersion, uv, patternCount, letters (reserved, and each letter's state) and problems, cut to 300 characters; an import failure gives ok = $false with the error. Update It 'reports prerequisites' (~line 2469, tagged Slow; the test command runs the full suite for that reason) to expect ten checks with sandbox last.

## Phase 5

Documentation of the shipped behaviour: the skills' sandbox rules and the sandbox: no-retry rule in all five places, the task template line, README, and the first design's post-lock amendment. The phase test is the full suite (no -Fast) because sign-off runs the same command.

Test: `pwsh -NoProfile -File scripts/test.ps1`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| sandbox-docs | Skill docs, task template, README and feature-skill amendment | delegate-wiring, doctor-check | skills/delegate/SKILL.md<br>skills/feature/SKILL.md<br>skills/feature/stages/build.md<br>skills/feature/stages/design-review.md<br>skills/feature/templates/task.md<br>skills/feature/tests/feature.Tests.ps1<br>README.md<br>docs/designs/feature-skill.md | code | `pwsh -NoProfile -File scripts/test.ps1` |

**sandbox-docs.** Apply the design's files 8, 9, 10, 12 and 13 exactly: the Sandbox section, the summary field list and the sandbox: exception in skills/delegate/SKILL.md; the same exception sentence in the five retry-once places named in file 9; the one-line sandbox note at the end of Constraints in templates/task.md (headings and <test, copied exactly> unchanged); README requirements, setup and uninstall; and the feature-skill.md Amended line, Risks row cell and Future Improvements bullet replaced with the texts given. Add the file-11 test that the task template keeps its six headings and has the sandbox line. Don't edit docs/test-plan.md or docs/HANDOFF.md: the lead writes those.
