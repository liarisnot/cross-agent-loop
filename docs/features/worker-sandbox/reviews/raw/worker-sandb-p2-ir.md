<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll start by reading the task file.

# Implementation Readiness Review — `docs/features/worker-sandbox/plan.md` (round 2)

**Verdict: not ready.** One Blocker (a phase-4 test that cannot pass as written for most reasonable implementations), three Majors, five Nits. All twelve round-1 fixes landed, and two of them (`ir 4`, `ir 11`) are now strong pins. One round-1 fix (`ir 1`) is incomplete: the scenario it repaired now collides with an earlier check in the same call chain (finding 1). I have not repeated anything listed as fixed or dismissed in `reviews/plan-1.md`.

---

## Findings

### 1. Blocker — the zeroed-pattern test asserts a message the fast check produces first, with unpinned wording

**Affected scope:** `delegate-wiring` brief (plan.md:56), its test case "A cache whose pattern bytes are zeroed…", `sandbox-core` (`Test-SandboxSupport`), design "Requirements checks" and file 2 / file 3.

**Finding & guidance:** The test asserts that a run with a zeroed source `node.exe` exits 1 with `error` starting with:

```text
sandbox: Cursor 2099.01.01-abc123: node.exe pipe-name pattern found 0 times
```

That string is pinned in the design only as `Get-SandboxRuntime`'s throw. But the design's file 3 setup runs, in this order, `Test-SandboxSupport` (fail with `sandbox: ` plus the problems joined) → `Initialize-SandboxLetters` → `Get-SandboxRuntime`. `Test-SandboxSupport` checks the installed version's `node.exe` pattern count (design "Requirements checks": *"that the current Cursor version's `node.exe` has the pattern exactly once"*). In this fixture the source `node.exe` is exactly the zeroed one, its libuv is the real 1.52.x (< 1.53), so the fast check reports a problem and `delegate.ps1` fails **before** `Get-SandboxRuntime` ever copies anything.

The assertion therefore passes only if `Test-SandboxSupport`'s problem string is byte-identical to the runtime error, which no document states. A worker who writes the fast-check problem as `node.exe pipe-name pattern found 0 times (Cursor 2099.01.01-abc123)` gets the same behaviour and a failing test; a worker who writes it the other way passes. That is exactly the round-1 class of defect (`ir 1`) resurfacing one layer earlier.

Fix in the `delegate-wiring`/`sandbox-core` briefs, one of:
* pin `Test-SandboxSupport`'s problem string for this case to exactly `Cursor <version>: node.exe pipe-name pattern found <n> times; Sandbox.psm1 needs an update` (then `sandbox: ` + joined problems satisfies the assertion); or
* state that the zeroed-pattern case is exercised through `-SandboxCheck` / `Get-SandboxRuntime` directly, not through a full sandboxed run; or
* loosen the assertion to `-Match 'pipe-name pattern found 0 times'`.

Also worth stating in the same brief that `delegate.ps1` joins `problems[]` with `'; '` (or `' '`), since the assertion prefix depends on the joiner.

---

### 2. Major — every sandboxed test case needs a repo and worktree **outside** `%USERPROFILE%`, and the plan pins only `XAGENT_*` roots to `TestDrive`

**Affected scope:** `sandbox-core`/`sandbox-run` container tests (file 5, plan.md:32, :44), `delegate-wiring` fixture (plan.md:56, file 6).

**Finding & guidance:** The design's access table refuses any worktree or `<repo>\.git` under `%USERPROFILE%` (`sandbox: repos under the user profile are not supported`), and `New-SandboxRun` repeats that refusal. Pester's `TestDrive` lives under `[IO.Path]::GetTempPath()`, i.e. `C:\Users\<user>\AppData\Local\Temp\...` — under the profile. The existing helper every worker will reach for, `New-TestRepo` in `skills/feature/tests/TestHelpers.ps1`, creates repos in `$TestDrive`.

So the natural implementation of both new test files fails on the first grant:
* `Sandbox.Tests.ps1` container cases (worker run, read-only run, read-list, isolation, crash recovery, timeouts) all need a real repo plus a real worktree.
* `DelegateLaunch.Tests.ps1`'s sandboxed case runs `delegate.ps1 -Repo <repo>`, which creates `<repoParent>\<repo>.xagent\<TaskId>`; a `TestDrive` repo is refused.

The plan says only "`XAGENT_SANDBOX_ROOT` and `XAGENT_CURSOR_ROOT` under `TestDrive`". Where the *repo* goes is a decision two workers will make differently (drive root, repo parent, `D:\Temp`, inside the worktree), and one obvious choice — a scratch dir inside the current worktree — additionally shows up as untracked in `verify`'s `Get-ChangedPaths` (it only filters `.xagent/`), producing an out-of-scope problem stop for that task.

Guidance to add to both briefs: a test temp root computed from the suite's repo/worktree drive (for example `Join-Path (Split-Path <worktreeRoot> -Qualifier) "xagent-tests-<guid>"`), created in `BeforeAll`, removed in `AfterAll` `finally`, never inside the worktree; plus `Set-ItResult -Skip`/describe-level skip with a reason when the repo is under `%USERPROFILE%` (a user whose only writable drive is the profile cannot run these cases), and confirmation that the `-NoSandbox` cases may stay in `TestDrive`.

---

### 3. Major — the three full-suite test commands are close to, or past, the 900 s defaults that `verify` and `delegate` use

**Affected scope:** `kill-tree` (plan.md:20), `doctor-check` (plan.md:59), `sandbox-docs` (plan.md:71); phase-level tests for phases 1, 4 and 5.

**Finding & guidance:** The plan correctly switches these three tasks to the full suite (`ir 2`), but nothing accounts for the cost. `docs/test-plan.md:216` records the full suite at **11 min 35 s (695 s)** for 218 tests, and `D17`/`D18` show the trend upward. Phases 3–5 add container tests that are *not* excluded by `-Fast` or by the default tag filter, each reserving three letters, creating AppContainer profiles and running `icacls` over a worktree — plausibly hundreds of seconds more.

Against that: `feature.ps1 verify` runs the task's test command with `$timeout = 900` (feature.ps1:2395), and `build.md` launches workers with `delegate.ps1` and no `-TimeoutSec`, so 900 s. `sandbox-docs` is a docs-only task whose only acceptance is that suite, so a timeout there loses the session (`delegate` SKILL: a timed-out run cannot be resumed) and a timed-out `verify` counts as a failed review round.

Guidance to add: state the timeout for these three tasks (for example "the lead launches this task with `-TimeoutSec 2400`", and "`feature.ps1 verify -TimeoutSec 1800`"), and add the `delegate` SKILL's existing advice — a filtered Pester command while iterating (`Filter.FullName` or `-Tag`), full suite once at the end. This is a plan-level line, not a design change.

---

### 4. Major — "invalid combinations fail through `Fail` (JSON)" is not achievable with the two parameter sets as described

**Affected scope:** `delegate-wiring` (plan.md:56), design file 3 "Two parameter sets" and "Invalid combinations", test case "`-Reserve` with `-Release`, and `-SandboxCheck` with `-NoSandbox`, each fail with exit 1 and JSON".

**Finding & guidance:** `-Reserve` with `-Release` is fine — both are in the `Check` set, so the combination binds and can be rejected in code. `-SandboxCheck -NoSandbox` is not: if `-NoSandbox` is declared only in the `Run` set, PowerShell rejects the combination at parameter binding, before any script runs. The output is a binding message on stderr and exit code 1, with **no JSON**, so the test's `ConvertFrom-Json` on `Raw` yields `$null` and the case fails. A worker will either discover this and declare `-NoSandbox` in both sets (passing), or "fix" the test instead.

Guidance: pin it — "`-NoSandbox` is declared in both sets so the invalid combination is rejected by `Fail`, not by the binder". Related, and worth one clause in the same brief: the "existing calls without the new switches still bind (G4)" case should be stated as a binding/shape assertion (AST or `Get-Command -Syntax`), not a real run — as written, a worker could read it as "run a sandboxed default launch", which needs reserved letters and a repo outside the profile (finding 2) and would be a second copy of the sandboxed case.

---

### 5. Nit — an unpinned literal in a docs diff

**Affected scope:** `sandbox-docs` (plan.md:71), design file 13 "Header".

**Finding & guidance:** The amended line is specified as `2026-<date>: worker sandboxing shipped (docs/designs/worker-sandbox.md).` Two workers will put different dates. Pin the date (or say "the date of the merge into `feature/worker-sandbox`"), so a reviewer is not diffing a guess.

---

### 6. Nit — two "retry once" sentences stay outside every task's file list

**Affected scope:** `sandbox-docs` file list (plan.md:69) and design file 9.

**Finding & guidance:** The design names five places for the `sandbox:` exception. The repo has two more retry-once sentences that are in no task's file list: `skills/feature/stages/signoff.md:43` ("If it ends without a report, retry once with the same model") and `skills/feature/stages/design-review.md:82` ("A lens run that ends without a report is retried once"). A `sandbox:` failure in the sign-off lens or in that ladder will therefore still be retried, which contradicts CUJ 5 and G5. I am not asking for a scope change against the locked design — but the plan should record the gap (a lead decision line is enough) so it is a known omission rather than an oversight, or add the two files to `sandbox-docs`'s list if the intent is "every retry-once site".

---

### 7. Nit — `test-runner` has no test of its own contract

**Affected scope:** `test-runner` (plan.md:15, :17).

**Finding & guidance:** The one artifact of phase 1 is the command that every later task's acceptance depends on, and its three pinned behaviours (`-Fast` excludes `Slow` and `Live`; "no test folders" prints and exits 0; the exit code caps at 250) have no assertion. `ir 2`'s entire fix rests on `-Fast` actually excluding `Slow` — if that line is dropped, the suite silently gets *weaker* for every worker, and no test notices. Either add a small self-test (a temp folder with one passing, one failing and one `Slow`-tagged test, run via `& scripts/test.ps1 -Fast`) to `kill-tree`'s scope, or state explicitly that the later phases are the check.

---

### 8. Nit — the phase-3 probe root lives inside the workspace and is only implicitly cleaned up

**Affected scope:** `sandbox-run` (plan.md:44).

**Finding & guidance:** `XAGENT_SANDBOX_ROOT = <worktree>/.xagent/probe-root` puts the ~256 MB runtime copy, the idle folder and the run home inside the worktree that is also the probe's `--workspace`. It is invisible to `git status` only because `delegate.ps1` adds `.xagent/` to `info/exclude`. State that the probe root is deleted at the end of the probe (and before the task's own `scripts/test.ps1` run, so a full copy is not being scanned by every later test), and that the deletion is part of the task, not left to `-Cleanup`.

---

### 9. Nit — testing a function the design calls private

**Affected scope:** `sandbox-core` `Test-LetterFree` test (plan.md:32), design file 2 "Private helper".

**Finding & guidance:** `Test-LetterFree` is explicitly private, and `sandbox-run`/`delegate-wiring` consume only `Test-SandboxSupport`. Testing it needs `InModuleScope` (or `& (Get-Module Sandbox) { … }`); otherwise a worker exports it to make the test easy, changing the module's public surface under phase 4's feet. One clause — "test `Test-LetterFree` in module scope; it is not exported" — removes the choice.

---

### 10. Nit — how the new `feature.Tests.ps1` test obtains `Stop-ProcessTree`

**Affected scope:** `kill-tree` (plan.md:20).

**Finding & guidance:** Every unit-style test in `feature.Tests.ps1` gets script functions through a `BeforeAll { . (Get-FeatureFunctionScript -Name @(...)) }` extraction (see lines 140–142, 200–201, 239–240). The brief does not say the new two-level-tree test uses that pattern, and the alternative (dot-sourcing the whole script) would run the dispatcher. Say which; it is a 30-second fix for the lead and a wasted round for the worker.

---

## Round-1 fix verification

| Finding | Landed? | Note |
|---|---|---|
| ir 1 zeroed-pattern case | **Incomplete** | See finding 1 — the fixture setup is right, but the fast check intercepts the failure with unpinned wording. |
| ir 2 Slow tests skipped by `-Fast` | Yes | `kill-tree`, `doctor-check` and phases 1/4/5 use the full suite; the new kill test is untagged. Line refs `~1485`, `~2281`, `~2469` all check out against the repo. |
| ir 3 fixture inside the sandbox | Yes | Skip-with-reason is stated; note it must be describe/`-Skip:` level, not a silent `BeforeAll` return. |
| ir 4 `letters` shape, unreserved not a problem | Yes | This also resolves the CUJ 1 ordering hazard: if "not reserved" were a problem, `Test-SandboxSupport` would pre-empt `Initialize-SandboxLetters`'s pinned message. |
| ir 5 phase-4 serialization | Yes | `doctor-check` depends on `delegate-wiring`; rationale says why. |
| ir 6 delete `<version>` and `.partial` | Yes | |
| ir 7 phase-3 probes | Yes | Root, prompt, timeout and observe-only are all stated; only clean-up is loose (finding 8). |
| ir 8 `Add-Type` on repeated import | Yes | |
| ir 9 version-test oracle | Yes | Also correctly reads `%LOCALAPPDATA%\cursor-agent\cursor-agent.ps1` rather than `XAGENT_CURSOR_ROOT`, which the test redirects. |
| ir 10 / cm 2 phase-2 dependency | Yes | Consistent with every task's test command being `scripts/test.ps1`. |
| ir 11 `-Release` with nothing reserved | Yes | |
| ir 12 no test folders | Yes | |
| cm 3–10 | Yes | Summary is restructured; `file N`, `<delegate dir>`, `fb-stages`, profiles and phase-5 rationale are all defined. |

**Dependencies and file boundaries reviewed clean:** all seven `dependsOn` edges exist and point at earlier or same-phase tasks; `feature.ps1`'s `Assert-PlanBusinessRules` constraints are satisfied. Every design Target File (1–13) is owned by exactly one task, and 14–15 are explicitly the lead's. Phase 1's file split between `kill-tree`, `doctor-check` and `sandbox-docs` over `feature.Tests.ps1` is consistent with each file's three bullets in design file 11. Line references quoted in the briefs (`delegate.ps1:349`, `feature.ps1:1806/2290/2556/2641`, `feature.Tests.ps1:1485/2281/2469`, the five SKILL/stage lines) all match the committed files.
