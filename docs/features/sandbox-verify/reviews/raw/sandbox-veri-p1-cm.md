<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Reading the plan and referenced context documents for the audit.
Checking a few specifics: design vs plan on phase-2 host-run expectations and whether parallel `build-docs` creates merge-order risk.
## What this proposes

The plan implements **sandbox-verify**: move `feature.ps1 verify` and every repo’s phase test into `delegate.ps1 -SandboxRun`, with explicit host fallback only after user approval. **Phase 1** (`sbrun-worktree`) extends the delegate skill with `-SandboxRun -Worktree`/`-Feature`, JSON `tail`, pid files for cap counting, shared probe/worktree helper logic, and `.venv/` in `.git/info/exclude`. **Phase 2** splits the design’s single verify task into **`verify-host`** (wrapper/decision refactors, `-OnHost`/`-Quote`, `where`/`setup` schema and samples, host-only verify behavior), **`verify-sandbox`** (default sandbox path, fake delegate, full test matrix, Live describe), and **`build-docs`** (parallel, driven by the locked design’s doc rows). Task acceptance tests stay narrow; phase tests widen; sign-off adds three lead-only checks plus `docs/test-plan.md` and `docs/HANDOFF.md`. The summary also notes that this repo’s phase-2 full suite will likely need **one D1/D2 host-approved phase test run** because delegate tests do not pass in the sandbox.

## How the existing system works, per this document

Today each worker already runs in an AppContainer, but **`verify` still runs the worker’s test command on the host** in the task worktree before the lead reviews it, so worker-controlled code can reach anything the sandbox blocks. Phase tests run through `-SandboxRun` only in Python repos; others run on the host. The design keeps verify on the **existing worktree** (not a probe worktree) via a new `-Worktree` parameter, routes all sandbox mechanics through **delegate.ps1**, counts sandboxed verify toward the **two-run cap**, and adds **`where`/`setup`** to verify output so the lead can branch on environment-missing, slot-busy, or sandbox-error without silently falling back to the host. Until phase 2 lands, verify and phase tests keep today’s host behavior for this feature’s own builds; the first sandboxed phase test is expected after both verify-sandbox and build-docs are in.

---

### Findings

1. **Severity:** Major  
   **Affected Scope:** `verify-host` brief (plan § Phase 2, line 31); design `Files` row for `verify.json`  
   **Discrepancy Description & Rationale:** The `verify-host` brief states that in this task every verify run (with or without `-OnHost`) reports `where: host` and `setup: null`, because sandbox is not wired yet. The locked design’s Files table instructs adding `"where": "sandbox"` to `samples/verify.json`. The plan says to update that sample but does not say whether the fixture should reflect **interim** (`host`) or **final** (`sandbox`) behavior. A worker can satisfy the brief or the design table, but not both without choosing which task owns the sample’s `where` value. That is a small design decision the brief should pin down (e.g. `where: host` in `verify-host`, flipped in `verify-sandbox`).

2. **Severity:** Major  
   **Affected Scope:** `verify-sandbox` brief; design `Rules` → **Mapping** vs `Data` → `setup.status`  
   **Discrepancy Description & Rationale:** The `verify-sandbox` brief requires mapping delegate results to `test.setup`, **including `slot-busy`**. In the design, `Data` defines `slot-busy` when the error starts with `sandbox: no free slot`, but the **Mapping** rule says flatly `ok: false` → `sandbox-error` with no exception. A worker implementing “Rules” literally will lump slot-busy into `sandbox-error` and break the build.md / fake-delegate `slot-busy` path. The plan points at both sections but does not state precedence (check error prefix before the generic `ok: false` rule). That ordering ought to be explicit in the brief or called out as a design erratum so implementers do not guess.

3. **Severity:** Major  
   **Affected Scope:** Plan summary (line 3) vs design `Phases` / Verification narrative (design ~lines 236–239)  
   **Discrepancy Description & Rationale:** The plan summary correctly expects **one host-approved phase test run** when phase 2’s full suite hits delegate tests that fail in the sandbox (consistent with D1 and the Problem section). The design’s Phases paragraph still says the first sandboxed phase test passes with **“No host run is expected there.”** A worker or lead reading only the design Phases table gets the opposite expectation from the plan summary. The plan is more accurate for this repo; the mismatch is a comprehension hazard when reconciling locked design vs plan.

4. **Severity:** Major  
   **Affected Scope:** `build-docs` task — `dependsOn`, parallel with `verify-sandbox`  
   **Discrepancy Description & Rationale:** `build-docs` depends only on `sbrun-worktree` and may merge **before** `verify-sandbox`. Its brief tells the worker to document sandbox-default verify and universal sandboxed phase tests while `feature.ps1` might still run tests on the host. Phase tests run only after the whole phase merges, so the broken window is short, but the plan never states **merge order** or “do not follow updated build.md until verify-sandbox is merged.” A lead (or worker treating docs as immediately authoritative) could follow new instructions against old code. Worth one sentence in the plan summary or `build-docs` brief.

5. **Severity:** Major  
   **Affected Scope:** `build-docs` — acceptance test (plan table, line 29)  
   **Discrepancy Description & Rationale:** Acceptance is Pester filtered to `*templates*` and `*fixtures*` only. That proves doc-related **samples/templates** still validate, not that `build.md` / SKILL text matches behavior (cap rule, `setup.status` ordering, phase-test `-SandboxRun` invocation). A worker could omit or misstate lead flows and still pass. For a docs-only task that may be intentional, but it means **the brief alone cannot enforce doc correctness**; the lead must diff prose against the design. Call out so “worker could build from brief” is not confused with “worker’s test proves docs right.”

6. **Severity:** Nit  
   **Affected Scope:** `sbrun-worktree` brief (line 17); design `DelegateLaunch.Tests.ps1` Files row  
   **Discrepancy Description & Rationale:** The brief says the new Describe should cover cases “in the design’s Files row,” which is one very long table cell (refusals, container worktree run, `.venv` exclude, environment-missing before build, pid file with `-Feature`, etc.). The task is buildable because the design is the locked reference, but the brief does not enumerate cases; a worker must transcribe the whole cell. Not a blocker with design open; slightly high cognitive load.

7. **Severity:** Nit  
   **Affected Scope:** Plan summary vs design `Phases` — phase 1 phase-test command  
   **Discrepancy Description & Rationale:** Design phase 1 test is `scripts/test.ps1 -Path skills/delegate/tests`; the plan uses `scripts/test.ps1 -Fast`. The plan follows feature plan rules (full or fast suite per phase). A reader comparing only the design Phases table might think the plan changed scope; the plan does not explain that `-Fast` is the repo’s fast subset. Minor self-containment gap unless the reader knows `scripts/test.ps1`.

8. **Severity:** Nit  
   **Affected Scope:** Opening paragraph — “Check-in mode: on-problems”  
   **Discrepancy Description & Rationale:** The mode is stated without inline definition in `plan.md`. It appears in `feature.json` and feature-stage docs, which worker task expansion likely includes, but the plan alone does not define when the lead must check in. General process term, not a build blocker.

---

### Worker buildability (summary judgment)

- **`sbrun-worktree`:** Buildable from brief plus design Data/Rules/Files; dense but contract-heavy.  
- **`verify-host`:** Buildable for code and most tests; **`verify.json` `where` value** needs the clarification in finding 1.  
- **`verify-sandbox`:** Buildable if the worker resolves **`slot-busy` vs generic `ok: false` mapping** (finding 2) from design `Data`; the brief should not rely on the Mapping bullet alone.  
- **`build-docs`:** Buildable as prose updates from design Files rows; **correctness is lead-verified**, not acceptance-tested (finding 5); **merge timing** with `verify-sandbox` matters for the lead (finding 4).

No **Blocker**-level gaps where the paraphrase fails or a task lacks a design anchor; the **Major** items are ambiguities or cross-document conflicts that can cause wrong implementations or wrong lead expectations if not triaged before build.
