# Plan: worker-sandbox

Build worker-sandbox as designed in docs/designs/worker-sandbox.md (locked at 6ca02a1): every delegate agent run starts inside a Windows AppContainer on a reserved slot drive letter, with per-run grants, a slot ledger and a patched copy of Cursor's node.exe. Five phases follow the design's Build order: groundwork (one test command, no taskkill), the sandbox core (launcher, runtime cache and patch, letters), running one sandboxed task (slots, grants, read list, canary; this task's file uses the two-part Decided / Yours to decide template, G7), wiring into delegate.ps1 and doctor, then docs. Steps outside the tasks: (1) before phase 1, with the user's approval, the lead creates the frozen copy (git worktree add --detach D:/cross-agent-loop.frozen 6ca02a1) and points ~/.claude/skills/delegate and ~/.claude/skills/feature at it (G6); every build run then uses the frozen skills. (2) The first sandboxed run on the real machine needs the user to approve three drive letters (CUJ 1); tests reserve and release their own letters. (3) After phase 5 the lead runs the checks that need a real Cursor login or a human: the Live canary as worker, lens and council seat; the suite inside the sandbox; the delegate regression; crash recovery; overhead; the token-refresh check over at least a day; and records them, the G6 skillDir check and the G7 comparison in docs/test-plan.md and docs/HANDOFF.md. No step involves secrets, credentials or deploys.

Check-in mode: on-problems

## Phase 1

Groundwork with no sandbox code: one test command for workers and the lead, and no taskkill.exe anywhere, so this repo's own suite can later run inside the sandbox.

Test: `pwsh -NoProfile -File scripts/test.ps1 -Fast`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| test-runner | scripts/test.ps1: the repo's one test command | — | scripts/test.ps1 | code | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**test-runner.** Create scripts/test.ps1 as the design's file 7 specifies: param([switch]$Fast); Import-Module Pester -MinimumVersion 5.5; New-PesterConfiguration with Run.Path set to whichever of skills/feature/tests and skills/delegate/tests exist (resolved from the script's own folder, so it works from any working folder), Run.PassThru = $true, TestRegistry.Enabled = $false (Pester's test registry writes HKCU, which an AppContainer cannot write), Filter.ExcludeTag 'Live' plus 'Slow' with -Fast, Output.Verbosity 'Normal'; exit with [Math]::Min($result.FailedCount, 250). Nothing else changes.
| kill-tree | Replace taskkill.exe with a .NET tree kill | test-runner | skills/feature/scripts/feature.ps1<br>skills/feature/tests/feature.Tests.ps1<br>skills/delegate/scripts/delegate.ps1 | code | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**kill-tree.** Add Stop-ProcessTree -ProcessId to feature.ps1 ([Diagnostics.Process]::GetProcessById($id).Kill($true), ignore 'process has exited' and 'not found', wait up to 10 s) and use it at the three taskkill.exe sites: the reconcile orphan kill (~line 1806), the verify timeout in Invoke-TaskTestCommand (~2290) and the Invoke-DoctorCommand timeout (~2556). In delegate.ps1, replace the timeout's '& taskkill.exe /T /F /PID' (line ~349) with 'try { $proc.Kill($true) } catch {}; $proc.WaitForExit(10000) | Out-Null'; nothing else in delegate.ps1 changes in this task. Add a feature.Tests.ps1 test that a two-level child process tree (pwsh starting pwsh starting Start-Sleep) is fully gone after Stop-ProcessTree. Afterwards grep must find no taskkill in either script.

## Phase 2

The sandbox core: the native launcher and everything that does not depend on a run: support check, runtime cache and node.exe patch, reserved letters. Fully specified by the design (files 1 and 2, phase-2 functions).

Test: `pwsh -NoProfile -File scripts/test.ps1 -Fast`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| sandbox-core | SandboxNative.cs and Sandbox.psm1 part 1 (support, runtime cache and patch, letters) | kill-tree | skills/delegate/scripts/SandboxNative.cs<br>skills/delegate/scripts/Sandbox.psm1<br>skills/delegate/tests/Sandbox.Tests.ps1 | code-hard | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**sandbox-core.** Implement exactly what docs/designs/worker-sandbox.md specifies for phase 2. File 1, SandboxNative.cs: XagentSandbox with EnsureProfile, DeleteProfile, Start, Wait, Kill, Finish, IsAppContainer, and RunHandle, with the constants, handle-inheritance and environment-block rules given there. File 2, Sandbox.psm1, its Settings, Test-LetterFree, Test-SandboxSupport (all checks except the read-list rule, which phase 3 adds), Get-SandboxRuntime (version choice, reuse contract, copy, patch, prune), Get-SandboxConfig, Set-SandboxLetters and Initialize-SandboxLetters, with the exact error strings. Every thrown error starts with 'sandbox:'. Tests: the phase-2 unit tests listed in file 5, in skills/delegate/tests/Sandbox.Tests.ps1, using XAGENT_SANDBOX_ROOT and XAGENT_CURSOR_ROOT under TestDrive; no test calls a real model or touches the user's sandbox.json. Reference: docs/designs/worker-sandbox-probe/ (probe5.ps1's AC class, the pattern bytes and offset in the README).

## Phase 3

Running one sandboxed task: slots, grants, the ledger, the run home, the read list, launch, stop, the canary and release. This is the G7 task: its task file is written in two parts, Decided and Yours to decide, and compared afterwards with fb-stages.

Test: `pwsh -NoProfile -File scripts/test.ps1 -Fast`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| sandbox-run | Sandbox.psm1 part 2: slots, grants, ledger, read list, launch, stop, canary, release | sandbox-core | skills/delegate/scripts/Sandbox.psm1<br>skills/delegate/scripts/SandboxNative.cs<br>skills/delegate/tests/Sandbox.Tests.ps1<br>skills/delegate/tests/fixtures/ | code-hard | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**sandbox-run.** G7 two-part task. Decided: the public functions and parameters of Get-SandboxSlot, New-SandboxRun, Start-SandboxProcess, Stop-SandboxRun, Remove-SandboxGrants, Invoke-SandboxCanary and Remove-SandboxLetters as the design states them; the slot ledger format; the access table's paths and icacls specs; the read-list rules and refusal order; the run-home layout and copied files; the environment array; every error string; Test-SandboxSupport gains the read-list check; and the phase-3 unit and container tests listed in file 5 as acceptance tests. Yours to decide: internal helpers, how icacls calls are built and parsed, how the mutex and ledger checks are structured, internal tests beyond the listed ones, and the order of work. Also run and record (in result.json open_questions or summary) two probe checks: Cursor --version and a short -p run inside a slot with --workspace <real worktree path> and working folder <slot>:\, and a per-user Python (if one is installed) started from a read-list entry. SandboxNative.cs may change only if a test proves it must.

## Phase 4

Wire the sandbox into delegate.ps1 (default on, -NoSandbox, -SandboxCheck with -Reserve and -Release, new summary fields) and add the fast sandbox check to doctor.

Test: `pwsh -NoProfile -File scripts/test.ps1 -Fast`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| delegate-wiring | delegate.ps1: sandbox by default, parameter sets, -SandboxCheck, summary fields | sandbox-run | skills/delegate/scripts/delegate.ps1<br>skills/delegate/tests/DelegateLaunch.Tests.ps1<br>skills/delegate/tests/fixtures/ | code | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**delegate-wiring.** Implement the design's file 3: the Run and Check parameter sets, -NoSandbox, -SandboxCheck, [string[]]$Reserve, -Release and the invalid combinations; -SandboxCheck handled before $Repo is resolved and before the -Agent and -TaskFile guards; $cursorRoot from XAGENT_CURSOR_ROOT; the sandboxed launch with the try moved before Get-SandboxSlot and Stop-SandboxRun in finally; exitCode from Finish, -1 on timeout; summary and runs.jsonl gain sandboxed, sandbox, skillDir and sandboxNotes; help comment. Add skills/delegate/tests/DelegateLaunch.Tests.ps1 and the fake Cursor fixture (skills/delegate/tests/fixtures/fake-cursor/index.js) exactly as file 6 lists, with all its cases.
| doctor-check | feature.ps1 doctor: fast sandbox check | sandbox-run | skills/feature/scripts/feature.ps1<br>skills/feature/tests/feature.Tests.ps1 | code | `pwsh -NoProfile -File scripts/test.ps1 -Fast` |

**doctor-check.** Implement the design's file 4 doctor bullet: a tenth check named 'sandbox' that imports <delegate dir>/scripts/Sandbox.psm1 in-process and calls Test-SandboxSupport; required = $false so ready is unaffected; detail lists Cursor version, uv, pattern count, letters and problems, cut to 300 characters; an import failure gives ok = $false with the error. Update It 'reports prerequisites' (~line 2468) to expect ten checks with sandbox last.

## Phase 5

Documentation of the shipped behaviour: the skills' sandbox rules and the sandbox: no-retry rule in all five places, the task template line, README, and the first design's post-lock amendment. The lead's live checks follow (see the summary).

Test: `pwsh -NoProfile -File scripts/test.ps1`

| Id | Title | Depends on | Files | Profile | Test |
|---|---|---|---|---|---|
| sandbox-docs | Skill docs, task template, README and feature-skill amendment | delegate-wiring, doctor-check | skills/delegate/SKILL.md<br>skills/feature/SKILL.md<br>skills/feature/stages/build.md<br>skills/feature/stages/design-review.md<br>skills/feature/templates/task.md<br>skills/feature/tests/feature.Tests.ps1<br>README.md<br>docs/designs/feature-skill.md | code | `pwsh -NoProfile -File scripts/test.ps1` |

**sandbox-docs.** Apply the design's files 8, 9, 10, 12 and 13 exactly: the Sandbox section, the summary field list and the sandbox: exception in skills/delegate/SKILL.md; the same exception sentence in the five retry-once places named in file 9; the one-line sandbox note at the end of Constraints in templates/task.md (headings and <test, copied exactly> unchanged); README requirements, setup and uninstall; and the feature-skill.md Amended line, Risks row cell and Future Improvements bullet replaced with the texts given. Add the file-11 test that the task template keeps its six headings and has the sandbox line. Don't edit docs/test-plan.md or docs/HANDOFF.md: the lead writes those.
