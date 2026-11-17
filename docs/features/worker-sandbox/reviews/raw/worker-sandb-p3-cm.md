<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Reading the target plan, design doc, and related context for the Phase 3 split review.
## What this proposes

The plan turns the locked `worker-sandbox` design into seven worker tasks across five phases. Phases 1 and 2 are done. Phase 3 is now three sequential `code-hard` tasks (`sandbox-access`, `sandbox-launch`, `sandbox-canary`) instead of one `sandbox-run`, each aimed at ~20 worker minutes after `sandbox-core` hit a 50-minute timeout. Each phase-3 task uses a G7 two-part brief, narrows acceptance to `scripts/test.ps1 -Fast -Path skills/delegate/tests`, and the phase still gates on the full fast suite. Later phases wire `delegate.ps1`, doctor, and docs.

## How the existing system works, per this document

`delegate.ps1` launches Cursor agents with broad disk access. The design confines runs in Windows AppContainers with reserved drive letters, per-run `icacls` grants, slot ledgers, and a patched `node.exe`. Phase 1 added `scripts/test.ps1` and removed `taskkill.exe`. Phase 2 added `SandboxNative.cs` and the first half of `Sandbox.psm1` (support checks, runtime cache/patch, letters) plus phase-2 Pester tests. Phase 3 fills in run lifecycle (read list, slots, launch/stop, `Invoke-SandboxCanary`, container tests, probes). Phase 4 connects the sandbox to `delegate.ps1` and doctor; phase 5 updates skills docs and README. The lead keeps a frozen `delegate`/`feature` copy (G6), reserves drive letters with the user, and runs manual checks after phase 5.

---

## Split coverage (design phase 3 / file 5)

**Verdict:** The three tasks cover design build-order row 3 and file 5’s phase-3 scope with no obvious gaps or duplicate ownership.

| Design item | Task |
|---|---|
| Read list + `Test-SandboxSupport` extension | `sandbox-access` |
| Environment array (Launch and kill) | `sandbox-access` |
| Ledger format, `Remove-SandboxGrants` | `sandbox-access` |
| `%USERPROFILE%` refusal (used by `New-SandboxRun`) | `sandbox-access` |
| `Get-SandboxSlot`, `New-SandboxRun`, `Start-SandboxProcess`, `Stop-SandboxRun`, `Remove-SandboxLetters` | `sandbox-launch` |
| `Invoke-SandboxCanary` | `sandbox-canary` |
| Phase-3 unit tests (env, read list, refusal, ledger) | `sandbox-access` |
| Container: reserve/release, pwsh worker script, read-only, timeouts | `sandbox-launch` |
| Container: read-list profile path, isolation, crash recovery | `sandbox-canary` |
| Probe checks (Cursor `-p`, optional Python) | `sandbox-canary` |

**Sequential testability:** `sandbox-access` needs no container and no slot APIs. `sandbox-launch` depends on access helpers (`Remove-SandboxGrants`, read-list validation, ledger, refusal). `sandbox-canary` depends on the full launch stack for `Invoke-SandboxCanary` and the harder container scenarios. Order is coherent.

**Test commands:** All three use the same narrowed folder (`skills/delegate/tests`), not the whole repo—appropriate for delegate-only work and regression against phase-2 tests. `scripts/test.ps1` has `-Path` but no `Filter.FullName`, so acceptance is the entire delegate test tree, not a per-task Describe filter (unlike `doctor-check` / `sandbox-docs`).

---

## Size / duration estimates (unmerged phase-3 tasks)

Baseline after phase 2 (this worktree): `Sandbox.psm1` ~795 lines, `Sandbox.Tests.ps1` ~578 lines.

| Task | Est. new module LOC | Est. new test (+fixture) LOC | Est. worker minutes | vs 20 min / 600 lines |
|---|---|---|---|---|
| `sandbox-access` | ~200–300 | ~120–200 | ~15–25 | Likely within budget |
| `sandbox-launch` | ~350–500 (`New-SandboxRun` + stop path dominate) | ~350–500 (many `Sandbox`-tagged container tests) | ~30–50 | **Likely over** both limits |
| `sandbox-canary` | ~120–200 | ~200–350 (isolation + crash + `Invoke-SandboxCanary`) | ~25–40 | **Borderline or over** (tests heavy; probes add wall time but not blocking) |

`sandbox-launch` is the main risk: it still owns the access-table grant walk, run home, subst, six container scenarios, and `Remove-SandboxLetters`—most of what made the original monolith large.

---

## Findings

### 1. Major — `sandbox-access` dependencies

**Affected scope:** Phase 3 table row `sandbox-access` (plan.md ~42), `feature.json` `dependsOn: []`

**Discrepancy:** The Depends column is `—` / empty, but the task extends `Test-SandboxSupport` and `Sandbox.psm1` on top of all phase-2 exports. A reader who only uses the task table may think phase 3 can start without `sandbox-core`. Phases imply ordering, but this row is the only explicit dep mechanism in the plan table.

---

### 2. Major — Copied “Decided” block on `sandbox-access`

**Affected scope:** `sandbox-access` brief (plan.md ~44)

**Discrepancy:** The brief lists “the access table’s paths and icacls specs” as Decided alongside ledger and read list, but the same brief scopes **no-container** work and does not assign grant application (`icacls` grant) to this task—that belongs to `sandbox-launch`’s `New-SandboxRun`. A worker can reasonably think they must implement the full reachability table in task 3a. The shared paragraph is copied verbatim on all three tasks without trimming per slice.

---

### 3. Major — G7 framing vs three tasks

**Affected scope:** Plan summary (plan.md ~3), each phase-3 brief (“G7 two-part task”)

**Discrepancy:** The opening summary still says “Phase 3’s task file is **the** G7 experiment” (singular), while three separate tasks each claim G7. The design’s G7 pass criterion is one `docs/test-plan.md` comparison to `fb-stages` (design ~354–360). The plan does not say whether G7 is measured once for phase 3 as a whole, per task, or only for the last task—so the experiment’s unit of comparison is unclear.

---

### 4. Major — `sandbox-launch` vs the ~20 min / 600 line split goal

**Affected scope:** Phase 3 rationale (plan.md ~36–37), `sandbox-launch` brief (plan.md ~47)

**Discrepancy:** The split is justified by `sandbox-core` timing out at 50 minutes (`docs/test-plan.md`, “sandbox-core run 1 timed out at 50 min”). `sandbox-launch` still concentrates `New-SandboxRun`, grant application, run home copies, launch/kill, letter release, and the bulk of container tests—the same bottleneck class as the old single task. The plan does not call out that the middle slice may still need a longer lead timeout or a further split, despite the uniform “~20 worker minutes” label on all three.

---

### 5. Nit — `TEST REPOS` only on tasks 3b and 3c

**Affected scope:** `sandbox-launch` / `sandbox-canary` briefs vs `sandbox-access`

**Discrepancy:** The long `TEST REPOS` rule appears on launch and canary but not access. For access that is mostly consistent (no container), but refusal/read-list tests may still need repo paths; a worker on 3a must infer the same rule from phase 2’s brief or design unless they read the sibling tasks.

---

### 6. Nit — Two different “canary” meanings

**Affected scope:** `sandbox-launch` (“pwsh canary script”) vs `sandbox-canary` (`Invoke-SandboxCanary`)

**Discrepancy:** Both names echo the design’s canary concept but refer to different things: an in-container PowerShell script exercise (file 5, launch) vs the full `delegate.ps1 -SandboxCheck` canary API (design file 2, canary task). A new reader can conflate them when tracing tests or acceptance.

---

### 7. Nit — Phase-3 test command vs plan-level iteration advice

**Affected scope:** Plan TIMEOUTS line (plan.md ~3), phase-3 test commands (plan.md ~42–48)

**Discrepancy:** The plan tells workers to iterate with filtered Pester (`Filter.FullName`) and run the full command once at the end, but phase-3 acceptance commands are only `scripts/test.ps1 -Fast -Path skills/delegate/tests` with no suggested filter for in-progress runs. That matches delegate skill practice in spirit but does not pin which Describes belong to which slice while building.

---

## Summary for orchestrator

The phase-3 split is **complete** relative to design row 3 and file 5 tests, **testable in order**, and **not duplicative** on code ownership. **`sandbox-access` is plausibly sized; `sandbox-launch` (and possibly `sandbox-canary`) still look large enough to exceed the stated 20-minute / 600-line targets.** Narrowed test commands correctly limit to `skills/delegate/tests` but not to per-task Describes. Comprehension issues: empty `sandbox-access` dependency, boilerplate Decided text on 3a, and singular vs triple G7 wording.
