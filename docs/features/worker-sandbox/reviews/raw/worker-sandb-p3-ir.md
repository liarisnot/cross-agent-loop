<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll read the task file first.

## Answer to the four questions

**1. Does the three-way split cover the design's phase 3 with nothing lost?**

Almost. All eight functions in Build order row 3 are assigned exactly once (`Get-SandboxSlot`, `New-SandboxRun`, `Start-SandboxProcess`, `Stop-SandboxRun`, `Remove-SandboxLetters` → `sandbox-launch`; read list + `Remove-SandboxGrants` → `sandbox-access`; `Invoke-SandboxCanary` → `sandbox-canary`), and every phase-3 unit test and container test in file 5 has a home, with two exceptions:

- The **`Live` test in file 5** ("`delegate.ps1` with a real Cursor worker on a temporary repo outside the profile, told to read the canaries") is owned by **no task**. It is not in file 6, so `delegate-wiring`'s "as file 6 lists, with all its cases" excludes it, and none of the three phase-3 briefs mentions it. Yet the Verification Plan says the canary step is "the `Live` test as a worker, then the same canaries as a review lens and a council seat" — the lead would have nothing to run.
- `Invoke-SandboxCanary` is the headline deliverable of `sandbox-canary`, and no test or command in that brief exercises it (the probes are described as bespoke checks, not as canary runs).

`SandboxNative.cs` and `fixtures/` appear in all three file lists; that is over-specification, not duplication, and the same "may change only if a test proves it must" guard is applied each time.

**2. Is each task testable on its own, in that order?**

Yes. The dependency chain is sound and each task's consumers exist by the time it runs: `sandbox-access` needs nothing from phase 3 (phase 2 already ships `Test-LedgerProcessLive`, `Get-PipePatternOffsets`, `Get-SandboxConfig`); `sandbox-launch` consumes the grant remover, ledger helpers and read-list validator; `sandbox-canary` consumes slot, run and launch from `sandbox-launch`. `sandbox-access`'s claim that it maps no drive letter and creates no AppContainer profile is accurate — its tests are unit-only, and the only container-touching tests its command runs are phase 2's merged ones. Reserve/release is correctly placed with `Remove-SandboxLetters` in `sandbox-launch`, and the "refused while a slot is held" test is satisfiable there because `Get-SandboxSlot` lands in the same task.

**3. Is each narrowed test command right?**

Yes, and I verified each against the merged tree:

- `pwsh -NoProfile -File scripts/test.ps1 -Fast -Path skills/delegate/tests` is valid: `-Path` already exists (`scripts/test.ps1` line 3), it resolves relative paths against the working directory, and `Invoke-TaskTestCommand` runs `verify` from the worktree root, so `skills/delegate/tests` resolves. This narrows to `Sandbox.Tests.ps1` (and later `DelegateLaunch.Tests.ps1`), which is exactly the right scope.
- Container tests are tagged `Sandbox`, not `Slow`, so `-Fast` still runs them. That is intended and consistent with the phase-4 note that both tasks' commands execute container tests.
- `doctor-check`'s `Filter.FullName = "*feature.ps1 doctor*"` matches the real names — `Describe 'feature.ps1 doctor'` at `skills/feature/tests/feature.Tests.ps1:2468`, `It 'reports prerequisites' -Tag 'Slow'` at :2469 — and since only `Filter.FullName` is set, the `Slow` test is not excluded.
- `sandbox-docs`'s `"templates.*"` matches `Describe 'templates'` at `skills/feature/tests/feature.Tests.ps1:64` and the new test inside it.
- `delegate-wiring`'s command also runs `Sandbox.Tests.ps1`, including all container tests; intended, and it is why phase 4 is serial.

One command-level problem is in the plan prose rather than the rows: see M4.

**4. Size and time estimates.** Basis: `sandbox-core` measured 1,842 changed lines in 926 s (docs/test-plan.md), of which ~14 min was debugging undocumented Windows behaviour, so roughly 1 changed line/second of model output plus a debugging tail that scales with how much unprobed Windows behaviour a task touches.

| Task | Module code (lines) | Tests (lines) | Changed lines | Est. worker minutes | Verdict |
|---|---|---|---|---|---|
| sandbox-access | 280–350 | 150–250 | 430–600 | 18–25 | At the 600 ceiling |
| sandbox-launch | 450–600 | 300–400 | 750–1000 | 30–45 | **Over both budgets** |
| sandbox-canary | 350–450 | 200–300 | 550–750 | 25–40 | **Over the time budget** |
| delegate-wiring (`code`) | 150–220 | 350–450 | 500–670 | 12–20 | At the ceiling, acceptable on Composer |
| doctor-check | 40–60 | 10–20 | 50–80 | 5–8 | Fine |
| sandbox-docs | — | ~15 | 120–200 (prose) | 10–15 | Fine |

---

## Findings

### 1. Severity: Blocker
**Affected scope:** `sandbox-launch` (plan.md row and brief, Phase 3).

**Finding & guidance:** This task still carries five of the eight phase-3 functions — `Get-SandboxSlot`, `New-SandboxRun`, `Start-SandboxProcess`, `Stop-SandboxRun`, `Remove-SandboxLetters` — plus the entire container-test scaffold (test root on the repo's drive, letter reservation in `BeforeAll`, `git worktree add` canary repo, sleeper-tree probe) and five of the seven container test groups. That is 750–1000 changed lines and realistically 30–45 worker minutes, 1.25–1.7× the 600-line budget that the split exists to enforce. Worse, it concentrates *all* of the behaviour the probes did not cover: icacls grant propagation over ~12 access-table rows including `.git` children and ancestor `RA` rows, `subst` re-mapping a letter a live process may be holding, run-home creation inside an `RX`-granted read-only worktree, and `AbandonedMutexException` ownership. Those are exactly the "undocumented Windows behaviour" minutes that turned `sandbox-core`'s 32 minutes into a 50-minute timeout, and this task gets no second slot to absorb them.

Concrete fix: split it four ways, not three, so each task stays at or under ~500 lines:

- 2a `sandbox-access` — unchanged.
- 2b `sandbox-slots` — `Get-SandboxSlot` + `Remove-SandboxLetters` + their tests (reserve/release, refused-while-held, and the `-TimeoutSec 4` no-free-slot case, which only needs two held mutexes, not two agent runs).
- 2c `sandbox-run` — `New-SandboxRun`, `Start-SandboxProcess`, `Stop-SandboxRun` + the worker-canary, read-only and sleeper-kill tests.
- 2d `sandbox-canary` — `Invoke-SandboxCanary`, isolation, crash recovery, read-list container test, probes.

That also removes the current dependency oddity where `Remove-SandboxLetters` (release) shares a task with the run lifecycle. The phase count grows from three to four, but the phase test and the phase-4 ordering are unaffected.

### 2. Severity: Major
**Affected scope:** `sandbox-access` brief (read-list check added to `Test-SandboxSupport`); consumed by `delegate-wiring`'s `Fail`.

**Finding & guidance:** The read-list problem string is not pinned, and the existing text invites a doubled prefix. The design gives the refusal as `sandbox: read-list entry '<path>' <reason>; edit sandbox.json`, and the plan's phase-1/phase-2 precedent explicitly prevents double prefixing for the pattern message: `Get-PatternProblem` returns text without a prefix and `throw "sandbox: $(...)"` adds it, because delegate.ps1 does `Fail ('sandbox: ' + ($problems -join '; '))`. The read-list text is given *with* the prefix in the design, so a worker that adds it to `problems[]` verbatim produces `sandbox: sandbox: read-list entry '...'` — a new instance of exactly the round-2 `ir 1` class of defect, and one that only shows up in a test that no task currently writes.

Guidance: pin it in `sandbox-access` alongside the other pinned strings, e.g. "`Test-SandboxSupport` adds the problem `read-list entry '<path>' <reason>; edit sandbox.json` with no `sandbox: ` prefix; `New-SandboxRun` throws the same text with the prefix", and have the read-list unit test assert both forms.

### 3. Severity: Major
**Affected scope:** design file 5's `Live` test; plan phases 3–5; no owning task.

**Finding & guidance:** As in answer 1, no task creates the `Live`-tagged test. `delegate-wiring` owns `DelegateLaunch.Tests.ps1` and is the natural home (it is the only task that touches `delegate.ps1`), but its brief scopes tests to "file 6 … all its cases", and file 6 has no `Live` case. Guidance: either add one line to `delegate-wiring` ("also create the file-5 `Live` test, tag `Live`, excluded by default; it must skip with a reason when `%LOCALAPPDATA%/cursor-agent/versions` is unreadable, as the fixture describes that need"), or state in the plan that the `Live` test is deliberately replaced by the lead's phase-5 manual canaries and change the Verification Plan's canary step to name the manual procedure instead of "the `Live` test".

### 4. Severity: Major
**Affected scope:** plan.md summary, `TIMEOUTS` paragraph, and the phase 3–5 test commands.

**Finding & guidance:** After this re-plan the `TIMEOUTS` paragraph is stale and now misleading: it says the lead launches "the tasks whose test command is the full suite (kill-tree, doctor-check, sandbox-docs) with `-TimeoutSec 2700` and verifies them with `feature.ps1 verify -TimeoutSec 2400`". But `doctor-check`'s row is a `Filter.FullName` Pester run over one Describe, and `sandbox-docs`'s row is a `templates.*` filter. Only `kill-tree` (already merged) matches. A lead reading the summary would size timeouts wrong, and — more importantly — the paragraph no longer says anything about the runs that *are* full-suite: the **phase 4 and phase 5 phase tests**, which now include the container tests (real AppContainer profiles, real grants, real processes) on top of the 695 s suite. Those are the runs most likely to exceed a shell or Bash time limit, and nothing in the plan sizes them.

Guidance: rewrite `TIMEOUTS` to name the phase tests, not tasks: "the phase 4 and phase 5 phase tests run the full suite (695 s plus the container tests); run them with an explicit timeout of at least 1800 s in the lead's shell. The only remaining worker task whose command is the full suite is none; every unmerged task uses its narrowed command, verified with `-TimeoutSec 900`." Also drop the two stale task names.

### 5. Severity: Major
**Affected scope:** `sandbox-launch` brief, `Stop-SandboxRun` and `Get-SandboxSlot` sentences.

**Finding & guidance:** The brief states `Stop-SandboxRun` is "the only place the slot mutex is released". The design's `Get-SandboxSlot` also releases a mutex — the slot it rejects because "its ledger names a live process … In that case it releases the mutex and tries the next slot". A worker reading the pinned rule literally will leak the mutex on the busy path; because a `[Threading.Mutex]` object that goes out of scope while owned keeps the slot busy for the process's lifetime, this breaks two of `sandbox-launch`'s own tests (the `-TimeoutSec 4` third-run case and "release is refused while a slot is held") in a way that looks like a timeout bug rather than a mutex bug.

Guidance: change the sentence to "the only place a *taken* slot's mutex is released; `Get-SandboxSlot` releases any mutex it rejects before trying the next slot, including on the abandoned-mutex and live-ledger paths", and add `$mutex.ReleaseMutex(); $mutex.Dispose()` on every reject branch in `Get-SandboxSlot`'s brief.

### 6. Severity: Major
**Affected scope:** `sandbox-canary` brief (size and the two probes).

**Finding & guidance:** Even after a launch re-split, this task is 550–750 changed lines and ~25–40 minutes: `Invoke-SandboxCanary` (canary worktree, two planted canaries, `.xagent\canary.ps1`, slot, `pwsh -File`, cleanup in `finally`), an isolation test that needs two *concurrent* sandboxed runs from within Pester (jobs or detached processes, two worktrees, cross-read attempts, then a sequential same-slot run), a crash-recovery pair, and a read-list container test. On top of that, the probes add an unbounded tail: a first-run runtime-cache copy (~256 MB), `Cursor --version`, a real `-p` model call with a 120 s timeout, and a Python run — plus the worker's natural urge to debug a probe that fails.

Guidance: two changes. (a) Bound the probes explicitly: "the probes are observe-only: record each result, cap the whole probe section at 5 minutes (the `-p` run at 120 s), and if a probe fails, record the failure and stop; do not debug it." (b) Cap the work too: move the read-list container test to `sandbox-access`… it cannot, since it needs a run — so instead move the **isolation** test to the `sandbox-run` task from finding 1, which already owns the multi-run scaffolding, and leave `sandbox-canary` with canary + crash recovery + read-list + probes.

### 7. Severity: Major
**Affected scope:** `sandbox-canary` brief; `delegate-wiring` brief's `-SandboxCheck` case.

**Finding & guidance:** `Invoke-SandboxCanary` is the task's main deliverable and nothing verifies it. The task's container tests do not call it, the probes are described as bespoke checks ("Cursor --version, then a `-p` run … inside a slot with `--workspace` …"), and `delegate-wiring`'s only `-SandboxCheck` test is "with no other parameter, binds and prints one JSON object" — no `-Repo`, so `canary = "skipped (pass -Repo)"`. Two capable workers diverge here: one writes the probes as a throwaway script, the other makes them call `Invoke-SandboxCanary`. The first ships an untested canary path into phase 4 and the lead's CUJ-1 check with no signal at all.

Guidance: state it. Either "the first probe *is* `Invoke-SandboxCanary` run against the probe root: assert `ok` and the shape of `results[]`, recording the Cursor `-p` outcome in `result.json`", or add one container test "canary: `Invoke-SandboxCanary -Repo <test repo>` returns `ok` with the expected `results[]` entries and leaves no canary worktree, canary file, mapping or ledger behind". A unit-level assertion on the returned shape plus a clean-up assertion would already be enough.

### 8. Severity: Minor
**Affected scope:** `sandbox-access` and `sandbox-launch` briefs ("public function signatures are Decided").

**Finding & guidance:** The split introduces four seam functions that do not exist in the design: the read-list validator, the ledger reader/writer, the `%USERPROFILE%` repo refusal, and the grant/applier wrapper. `sandbox-access` invents their names and signatures ("Yours to decide: internal helpers"), while `sandbox-launch` must call them and is simultaneously told signatures are Decided. Because the tasks are sequential and touch the same file the risk is contained, but it directly contradicts G7's own definition ("Decided covers … the shared interfaces") for a two-session interface.

Guidance: have `sandbox-access` pin the four names and parameter lists in its brief (the same way phase 2 pinned `Test-SandboxSupport`'s return shape), and have `sandbox-launch` say "call the helpers `sandbox-access` added; add no second icacls wrapper and no second ledger writer".

### 9. Severity: Minor
**Affected scope:** `sandbox-launch` brief, `New-SandboxRun` grant step.

**Finding & guidance:** It is not said who turns read-list entries into ledger grant rows (`{path, spec}`), including the `(OI)(CI)RX` on each entry and `RA` on each ancestor from the profile root down. `New-SandboxRun` says "icacls grants per the access table", and the access table includes the read-list row, while `sandbox-access` owns the read list. A `sandbox-launch` worker that re-derives those rows will duplicate and possibly diverge from `sandbox-access`'s normalization, and the difference is invisible until the canary or a read-list container test fails.

Guidance: pin it: "`sandbox-access` returns the complete grant list for the worktree, `.git`, runtime cache and read list as `[{path, spec}]`; `New-SandboxRun` writes that list to the ledger before applying it and applies each row unchanged."

### 10. Severity: Minor
**Affected scope:** `sandbox-launch` brief, `Start-SandboxProcess`.

**Finding & guidance:** "builds the command line from `-Exe` and `-Arguments` with `delegate.ps1`'s `Quote` rules" leaves two readings: copy `Quote` into `Sandbox.psm1`, or inline the escaping. The two differ in behaviour on a trailing-backslash argument (the prompt), which is the case the existing `Quote` exists for.

Guidance: "copy `Quote` from `delegate.ps1` into `Sandbox.psm1` as a private function with identical behaviour, and quote each `-Arguments` element then join with spaces."

### 11. Severity: Minor
**Affected scope:** `sandbox-launch` brief (`Stop-SandboxRun` step 2, `Remove-SandboxLetters`).

**Finding & guidance:** Two pinned behaviours have no test: the clean-up rewrite of failed grant removals into the kept ledger (design "Clean-up" step 2), and the `CheckNetIsolation LoopbackExempt -s` parse that returns leftover exemptions with their `-d` command. The first is a retry contract the next run depends on; the second is brittle string parsing. File 5's ledger unit test covers "returns the failed entry" but not "the ledger is kept with only the failures".

Guidance: add to `sandbox-launch`: one container test that makes one grant unremovable (an open handle on the file), calls `Stop-SandboxRun`, and asserts the ledger survives containing only that entry and `sandboxNotes` names it; and one unit test with a captured `LoopbackExempt -s` text fixture asserting the returned removal command.

### 12. Severity: Minor
**Affected scope:** `delegate-wiring` brief, `DelegateLaunch.Tests.ps1`.

**Finding & guidance:** The sandboxed run case is tagged `Sandbox`, but the brief gives a skip rule only for the missing `node.exe` copy. `Sandbox.Tests.ps1`'s container group also skips when fewer than three letters are free; a machine (or a second logon session) without three free letters would make `DelegateLaunch.Tests.ps1` fail rather than skip, and it runs in `sandbox-docs`'s and the phase tests' full-suite runs.

Guidance: "the sandboxed Describe also skips with a reason when `Set-SandboxLetters` cannot reserve three free letters or the build is below 26300, as Sandbox.Tests.ps1 does."

### 13. Severity: Nit
**Affected scope:** plan.md summary paragraph, first line.

**Finding & guidance:** "WORKER TASKS: seven, in five phases" is stale — the split makes nine (2 + 1 + 3 + 2 + 1). Since this sentence is the plan's scope statement and the G7 note sits next to it, correct it to nine, and say "Phase 3's task files are the G7 experiment" (plural) or keep one G7 task explicitly named, since all three phase-3 briefs now claim "G7 two-part task". Currently three tasks are labelled the G7 experiment while the summary and design speak of one; the comparison entry in `docs/test-plan.md` will need to know which.

### 14. Severity: Nit
**Affected scope:** Phase 3 task table, `sandbox-access` row.

**Finding & guidance:** The first phase-3 row shows `Depends on: —` while phase 2's row shows `test-runner`. `sandbox-access` does depend on `sandbox-core` (it extends `Test-SandboxSupport` and reuses the ledger-adjacent helpers). Phases order the work, so this is cosmetic, but a `feature.ps1` dependency reader or a future reordering should see the edge. Set it to `sandbox-core`.

### 15. Severity: Nit
**Affected scope:** `doctor-check` brief, second sentence of the test instruction.

**Finding & guidance:** "keep the sandbox check's expectations in that Describe" is the one unpinned part of an otherwise fully pinned brief. Name them: the check is tenth and last, `required` is `$false`, `ok` is not asserted (the machine's Cursor state is not this test's business), and it is excluded from the existing "every `required` check is ok" loop assertion. Without that, a worker may add `sandbox` to the `required` loop and make `doctor` environment-dependent in CI.
