<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Reading the task file to follow the reviewer persona and instructions.


Reading the plan (phase 3), design doc, and the prior review for context.
## What this proposes

Phase 3 of the worker-sandbox build is now **five** sequential `code-hard` tasks instead of the round-3 **four-task** plan that still had a single `sandbox-access`. The former `sandbox-access` scope was split at the comprehension preflight size gate into **`sandbox-readlist`** (read list validation, `%USERPROFILE%` refusal, environment block, and the extra `Test-SandboxSupport` read-list problems) and **`sandbox-grants`** (`Get-SandboxGrantList`, ledger read/write, exported `Remove-SandboxGrants`). Phase 3 still delivers read list, grants, slots, run lifecycle, and canary; only the first former “access” chunk is divided in two. Each task keeps the G7 two-part brief, depends on the prior task in the chain, runs `scripts/test.ps1 -Fast -Path skills/delegate/tests`, and is described as ~20 worker minutes with detailed row/ledger contracts left to the generated task file at preflight.

## How the existing system works, per this document

After phase 2, `Sandbox.psm1` already provides support checks (without read-list rules), runtime cache/patch, and letter reservation. Phase 3 adds run-time access control and orchestration on top: config validation and a fixed child environment first, then computation of per-run `icacls` grant rows and ledger handling, then slots, `New-SandboxRun` / launch / stop, then canary and isolation tests. `delegate.ps1` wiring waits until phase 4. The design doc remains the authority for behavior; the plan assigns **named private seams** so later tasks call earlier helpers instead of reimplementing them.

### Split vs old `sandbox-access` (coverage, duplication, edges)

Relative to round-3’s `sandbox-access` bundle (read list + env + ledger + `Remove-SandboxGrants` + `%USERPROFILE%` refusal + phase-3 unit tests in design file 5), **nothing obvious is dropped**:

| Former `sandbox-access` slice | Now in |
|---|---|
| Read list + `Test-SandboxSupport` extension | `sandbox-readlist` |
| Environment array | `sandbox-readlist` |
| `%USERPROFILE%` refusal | `sandbox-readlist` (`Assert-SandboxOutsideProfile`) |
| Ledger + `Remove-SandboxGrants` | `sandbox-grants` |
| Complete grant rows (`Get-SandboxGrantList`) | `sandbox-grants` |
| File 5 unit tests: env, read list, refusal, ledger | Read list/env/refusal → readlist; ledger removal → grants; grants adds an explicit grant-list row test |

**Duplication:** The split **moves** `Get-SandboxGrantList` and ledger helpers off readlist and tells lifecycle to apply rows unchanged—aligned with plan-3’s ir 8/9 fix, not two owners for the same work. Repeated G7 boilerplate and “call earlier helpers” text is template duplication, not dual implementation. **Naming duplication:** both `sandbox-grants` and `sandbox-slots` use the subtitle “part 2b” (see finding below).

**Dependency edges:** `sandbox-core` → `sandbox-readlist` → `sandbox-grants` matches consumption: grant rows include read-list paths and rules; `sandbox-slots` needs `Remove-SandboxGrants` for dead ledgers. That order is coherent.

**Testability alone:** Readlist is explicitly no letters, profiles, or `icacls`; its acceptance tests are unit-only and match design file 5 for env/read list/profile refusal. Grants stays off slots/containers but **`Remove-SandboxGrants` and grant-list tests still touch real paths and `icacls`**—still unit-level, not container tests. Grants **depends on** readlist helpers for read-list portions of the table; it is not meant to run before readlist merges, which the `dependsOn` edge encodes.

**Size (~20 min / ~600 lines):** Readlist is plausibly within the old `sandbox-access` lower half (many tests, moderate module growth on an already large `Sandbox.psm1` / `Sandbox.Tests.ps1` from phase 2). **Grants still carries the full “What the sandbox can reach” table builder**—the piece that helped push whole `sandbox-access` over the preflight gate—so the plan’s uniform “~20 worker minutes” on grants is **hard to believe from the plan text alone** even though deferring row/ledger detail to the task file is intentional.

---

## Findings

### 1. Major — `Get-SandboxGrantList` call shape is not self-contained in the plan brief

**Affected scope:** `sandbox-grants` brief (plan.md ~47), concept `Get-SandboxGrantList`

**Discrepancy:** The brief says the function returns the complete `[{path, spec}]` list for worker or read-only runs and that **worktree name is an explicit parameter**, but it does not say what else the worker must pass (repo root, worktree path, read-only flag, runtime cache location, SID, etc.) or where those values come from. A reader who treats **only** `plan.md` as the spec cannot implement or test the synthetic repo/worktree row test without opening `docs/designs/worker-sandbox.md` “What the sandbox can reach” and `New-SandboxRun`. That is acceptable for build-time task files if preflight pins it; at **plan** level it leaves a comprehension gap for the split’s second half.

---

### 2. Major — `sandbox-grants` sizing language conflicts with why the split happened

**Affected scope:** Phase 3 intro and `sandbox-grants` brief (“Each task is sized to about 20 worker minutes”)

**Discrepancy:** `decisions.md` records preflight stopping **`sandbox-access`** for an oversized estimate (hundreds of lines / tens of minutes). The plan now asserts the **grant-list half alone** is still ~20 minutes while assigning it the access table, ledger format, `Remove-SandboxGrants`, and new tests. The narrative of the split (cut access in two for the size gate) and the unchanged per-task time target for the heavier half do not connect; a naive reader cannot tell whether grants is expected to pass the same gate or is betting on task-file trimming alone.

---

### 3. Major — `sandbox-readlist` “Decided” line mixes private seams with vague “public … as the design states them”

**Affected scope:** `sandbox-readlist` brief, G7 Decided block (plan.md ~44)

**Discrepancy:** Decided lists **`Test-SandboxReadList`**, **`Assert-SandboxOutsideProfile`**, and **`Get-SandboxEnvironment`** as private helpers, then adds “public function signatures as the design states them.” In the locked design’s file 2, phase-3 **exported** surface includes `Remove-SandboxGrants`, `Get-SandboxSlot`, `New-SandboxRun`, and others—not those three. The only clear public change in this task is extended **`Test-SandboxSupport`**. A new worker may think they must implement or export design-listed functions early, or be unsure what “Decided” actually locks for exports in task 1 of 5.

---

### 4. Nit — Two tasks share the same “part 2b” label

**Affected scope:** Phase 3 table titles: `sandbox-grants` and `sandbox-slots` (plan.md ~45, ~48)

**Discrepancy:** Readlist is “2a”; grants and slots are both “2b.” Task indices are 1–5 of 5, so work order is clear, but the **a/b/c lettering does not match five tasks** and can confuse traceability to an older three-part “2a/2b/2c” mental model.

---

### 5. Nit — `sandbox-grants` does not restate the “no slot / no profile” boundary for `icacls`

**Affected scope:** `sandbox-grants` vs `sandbox-readlist` (readlist says “runs no icacls”; grants does not)

**Discrepancy:** Readlist explicitly says it does not map letters, create profiles, or run `icacls`. Grants implements **`Remove-SandboxGrants`** (inherently `icacls`) but only says it maps no letter and creates no profile. A naive reader might infer **no** `icacls` in grants and be surprised that acceptance tests require grant removal. A one-line contrast with readlist (“no grant application on a slot; removal and grant-list computation only”) would close the gap.

---

### 6. Nit — Round-3 artifact `sandbox-access` in plan-3 vs five-task names

**Affected scope:** Phase 3 intro (plan.md ~36), cross-ref `docs/features/worker-sandbox/reviews/plan-3.md`

**Discrepancy:** The intro correctly explains the split from `sandbox-access` into readlist + grants. Plan-3’s fix table still talks about a single **`sandbox-access`** owning all seam helpers. A reader jumping between documents might think a **`sandbox-access` task still exists** until they reconcile with the five IDs. The current `plan.md` body is consistent; the friction is **external** to the reviewed scope unless the intro added “formerly one task, now these two IDs.”

---

## Summary judgment (comprehension, scoped questions)

| Question | Assessment |
|---|---|
| Anything from old `sandbox-access` lost? | **No** — responsibilities map cleanly to readlist + grants. |
| Duplicated ownership? | **No meaningful code ownership duplication**; seam split matches plan-3 intent. |
| Each half testable on its own? | **Yes**, with grants logically and procedurally after readlist; grants’ tests are still filesystem/`icacls` unit tests, not container tests. |
| Each ~20 min / ~600 lines? | **Readlist plausible**; **grants still reads optimistic** relative to the split rationale. |
| Dependency edges | **`sandbox-core` → `sandbox-readlist` → `sandbox-grants`** is correct and reflected in `feature.json`. |

No **Blocker**-level comprehension failures: the split’s intent, ordering, and test homes are understandable; remaining gaps are pinning/`Get-SandboxGrantList` inputs in the plan brief, Decided wording on readlist, sizing credibility for grants, and minor labeling/boundary clarity.
