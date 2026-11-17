# Plan review round 3

**Target:** `docs/features/worker-sandbox/plan.md`, re-plan during the build (back to `plan` on 2026-11-14 to apply the task size gate after `sandbox-core`'s 50-minute timeout; `docs/test-plan.md`). Phases 1 and 2 are merged and unchanged.
**Built from:**
- `reviews/raw/worker-sandb-p3-cm.md`: comprehension, composer-2.5, completed (4 Major, 3 Nit), with size estimates.
- `reviews/raw/worker-sandb-p3-ir.md`: implementation readiness, deepseek-v41-flash-1017-medium, completed (1 Blocker, 6 Major, 5 Minor, 3 Nit), with size estimates.

The reviewed plan split the old `sandbox-run` into three tasks and narrowed every unmerged task's test command. Both lenses found the split complete and correctly ordered, and the narrowed commands right (readiness checked each against the tree). Both found the middle task still over budget. The plan was re-imported with the fixes below.

## Size estimates (reviewed three-way split)

| Task | Comprehension | Readiness |
|---|---|---|
| `sandbox-access` | 320-500 lines, 15-25 min | 430-600 lines, 18-25 min |
| `sandbox-launch` | 700-1,000 lines, 30-50 min | 750-1,000 lines, 30-45 min |
| `sandbox-canary` | 320-550 lines, 25-40 min | 550-750 lines, 25-40 min |
| `delegate-wiring` | — | 500-670 lines, 12-20 min |

## Fixed in the plan

| Finding | Fix |
|---|---|
| ir 1 (Blocker), cm 4: `sandbox-launch` still over 20 min / 600 lines | Phase 3 is four tasks: `sandbox-access` (no-container parts), `sandbox-slots` (`Get-SandboxSlot`, `Remove-SandboxLetters`, reserve/release, no-free-slot, crash recovery), `sandbox-lifecycle` (`New-SandboxRun`, `Start-SandboxProcess`, `Stop-SandboxRun` and their runs), `sandbox-canary` (canary, isolation and read-list runs, probes). Crash recovery moved to `sandbox-slots` and asserts with `icacls` that the SID is gone, so it needs no run. |
| ir 2: the read-list problem text would get a double `sandbox: ` prefix | Pinned in `sandbox-access`: `Test-SandboxSupport` adds it without the prefix, `Test-SandboxReadList` throws it with the prefix, and the test asserts both. |
| ir 3: file 5's `Live` test has no owner | Added to `delegate-wiring` as (g), tagged `Live` (excluded by `scripts/test.ps1`), skipping when Cursor's versions folder is unreadable. The lead runs it after phase 5. |
| ir 4: the summary's TIMEOUTS paragraph names tasks that no longer run the full suite | Rewritten: unmerged tasks run only their own tests (verify `-TimeoutSec 900`); the phase tests run the fast or full suite with at least 1800 s. |
| ir 5: "the only place the slot mutex is released" would leak rejected mutexes | `sandbox-slots`: `Get-SandboxSlot` releases and disposes every mutex it rejects; only `Stop-SandboxRun` releases a taken slot's mutex. |
| ir 6: the probes have no bound | Capped at 5 minutes in all; each result or failure is recorded, and a failing probe is not debugged. Isolation stays in `sandbox-canary`, which now has little module code. |
| ir 7: nothing tests `Invoke-SandboxCanary` | A container test: it returns `ok` with the expected `results[]` and leaves no canary worktree, file, mapping or ledger. |
| ir 8, ir 9: the seam helpers between the split tasks are unnamed, and nobody owns the grant rows | `sandbox-access` names `Test-SandboxReadList`, `Get-SandboxEnvironment`, `Get-SandboxGrantList` (the complete `[{path, spec}]` list, including read-list ancestors), `Read-SandboxLedger`, `Write-SandboxLedger` and `Assert-SandboxOutsideProfile`; later tasks call them. |
| ir 10: `Quote` copy or rewrite | Copied from `delegate.ps1` as a private function with identical behaviour. |
| ir 11: no test for the kept ledger or the `LoopbackExempt -s` parse | `sandbox-lifecycle` tests a kept ledger with one unremovable grant; `sandbox-slots` unit-tests the parse on a captured fixture. |
| ir 12: the sandboxed `DelegateLaunch` case has no letters/build skip rule | Added to `delegate-wiring` as (f). |
| ir 13, cm 3: "seven tasks" and the singular G7 task file | Ten tasks; the four phase-3 task files are the G7 group, compared once with `fb-stages`. |
| ir 14, cm 1: `sandbox-access` shows no dependency | Depends on `sandbox-core`. |
| ir 15: the doctor check's test expectations are unpinned | Tenth and last, `required = $false`, `ok` not asserted, left out of the every-required-check-is-ok assertion. |
| cm 2: one "Decided" block copied onto every phase-3 task | Each task's Decided list names only its own slice. |
| cm 6: two meanings of "canary" | The `sandbox-lifecycle` brief says its pwsh script is file 5's "pwsh canary script", not `Invoke-SandboxCanary`. |

## Dismissed

- **cm 5:** the TEST REPOS rule is missing from `sandbox-access`. It creates no repo or worktree (its refusal test only checks paths), so the rule doesn't apply.
- **cm 7:** no per-task `Describe` filter for iterating. `skills/delegate/tests` runs in seconds, so the narrowed command is the iteration command.

## Next

The revised plan's changes are the fixes above. Whether it gets a fourth review round before approval is the user's call. Either way, the build-time preflight on each task file (comprehension with the size gate, and readiness) checks every unmerged task again before a worker starts.
