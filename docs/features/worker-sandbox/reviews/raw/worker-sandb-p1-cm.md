<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Reading the task file to follow the reviewer persona and produce the review report.


Checking whether plan-only terms like "on-problems" and "check-in mode" are defined elsewhere in the document or design.
## What this proposes

The plan is a five-phase build schedule for the **worker-sandbox** feature: put every `delegate.ps1` agent run inside a Windows AppContainer with reserved drive letters, per-run ACL grants, a slot ledger, and a patched copy of Cursor’s `node.exe`. Phase 1 adds `scripts/test.ps1` as the single test entry point and removes all `taskkill.exe` usage so the suite can run inside a container. Phase 2 adds `SandboxNative.cs` and the first half of `Sandbox.psm1` (support checks, runtime cache, patching, letter reservation). Phase 3 completes sandbox lifecycle code and tests, using the G7 two-part worker task format (Decided vs Yours to decide). Phase 4 integrates sandboxing into `delegate.ps1` by default and adds a fast sandbox check to `feature.ps1` doctor. Phase 5 updates skill docs, the task template, README, and amends `feature-skill.md`, while the lead—not workers—records live verification in `docs/test-plan.md` and `docs/HANDOFF.md`. Before phase 1 the lead freezes skills at the locked design commit (G6); the first real sandboxed run needs user-approved drive letters (CUJ 1); after phase 5 the lead runs manual checks (live canary, in-sandbox suite, regression, crash recovery, overhead, token refresh, G6/G7 records).

## How the existing system works, per this document

Today, `delegate.ps1` launches Cursor CLI workers (and review/council profiles) as the normal Windows user with no filesystem confinement: agents can read broadly and write outside their git worktree unless modes discourage edits. The `feature` skill drives build by delegating phased tasks to workers in worktrees. Timeouts and orphan cleanup use `taskkill.exe` in `delegate.ps1` and `feature.ps1`. Tests live under `skills/feature/tests` and `skills/delegate/tests` rather than a single repo-level command. The locked design in `docs/designs/worker-sandbox.md` is the authoritative spec; each plan task points workers at numbered “files” in that design’s implementation section and reuses the design’s build order and verification ideas, with workers on frozen `main` at the lock commit while new sandbox code is exercised mainly through Pester.

---

### Findings

1. **Severity:** Major  
   **Affected Scope:** Opening paragraph; line 5 (`Check-in mode: on-problems`)  
   **Discrepancy Description & Rationale:** The plan states check-in mode `on-problems` but neither `plan.md` nor `docs/designs/worker-sandbox.md` defines what that mode means (when the lead must stop for the user vs continue). A new reader who only has the plan and the worker-sandbox design cannot tell whether this affects workers or only the lead, or what behaviour it implies. The feature skill defines it elsewhere (`on-problems` vs `every-phase`), but the plan does not name or link that doc.

2. **Severity:** Major  
   **Affected Scope:** Phase 2 task `sandbox-core` — Depends on `kill-tree`; vs design Build order (“Phases 1 and 2 share no files and can run at the same time”)  
   **Discrepancy Description & Rationale:** The design says phase 1 (test runner + kill-tree) and phase 2 (sandbox core) can run in parallel because they touch disjoint files. The plan makes `sandbox-core` depend on `kill-tree`, so phase 2 cannot start until all of phase 1 finishes. That may be intentional (e.g. always run `scripts/test.ps1` after taskkill removal), but the plan never says why it overrides the design’s parallelism note. Someone scheduling workers from the design alone could start sandbox core too early or wonder which document is wrong.

3. **Severity:** Major  
   **Affected Scope:** Summary paragraph (lines 3–4)  
   **Discrepancy Description & Rationale:** The opening block is one dense sentence chaining lock SHA, five phases, G6 freeze paths, G7 template, CUJ 1, test letter behaviour, and a long post-phase-5 checklist. Individual items are defined in the design, but the paragraph does not separate “worker tasks,” “lead-only prep,” and “lead-only sign-off,” so a naive reader cannot quickly see who does what or in what order without re-reading the whole file.

4. **Severity:** Major  
   **Affected Scope:** Phase 2 — `sandbox-core` brief (“design's file 1”, “file 2”, “file 5”, “phase-2 functions”)  
   **Discrepancy Description & Rationale:** Task briefs lean on numbered entries in the design’s “Target Files to Create/Modify” and on the phrase “phase-2 functions” without a pointer to a single heading (e.g. Detailed Implementation Plan §2). That is workable for someone already in the design doc, but the plan never states that “file *N*” always means “§*N* in the design’s file list,” so a reader jumping from the task table alone may not know where to look first.

5. **Severity:** Major  
   **Affected Scope:** `doctor-check` brief — “imports `<delegate dir>/scripts/Sandbox.psm1`”  
   **Discrepancy Description & Rationale:** `<delegate dir>` is a placeholder with no definition in the plan. The design implies the delegate skill directory from the frozen or live skills layout, but a worker told to implement doctor without reading `feature.ps1` may not know how that path is resolved (junction, `skillDir`, env, etc.).

6. **Severity:** Nit  
   **Affected Scope:** Phase 3 rationale and sandbox-run brief — “compared afterwards with `fb-stages`”  
   **Discrepancy Description & Rationale:** `fb-stages` is named as the G7 comparison baseline without a one-line reminder in the plan (the design ties it to an earlier `code-hard` build task and `docs/test-plan.md` D19). Readers who have not followed that history may not know which run or task id `fb-stages` refers to.

7. **Severity:** Nit  
   **Affected Scope:** Task table — `Profile` column (`code`, `code-hard`)  
   **Discrepancy Description & Rationale:** Profiles are listed on every task but the plan does not say they select the `delegate` model/profile (design G7 mentions `skills/delegate/models.json`). A new teammate may treat them as labels only unless they already know the delegate skill.

8. **Severity:** Nit  
   **Affected Scope:** Phase 5 — phase-level `Test: pwsh ... scripts/test.ps1` (no `-Fast`) vs phases 1–4 using `-Fast`  
   **Discrepancy Description & Rationale:** The slower phase gate is consistent with the design’s full-suite verification, but the plan’s phase 5 rationale does not say that the phase test intentionally includes non-`Fast` tests (e.g. untagged or `Slow`). Someone comparing phase rows might think the omission is accidental.

9. **Severity:** Nit  
   **Affected Scope:** Summary line 3 — “this task's file uses the two-part Decided / Yours to decide template, G7”  
   **Discrepancy Description & Rationale:** “This task's file” grammatically sounds like the plan document or the current reader task, but it means the **phase-3 `sandbox-run` worker task file** (hand-written, not the standard `templates/task.md` layout per the design). That ambiguity is cleared only after reading phase 3.

10. **Severity:** Nit  
    **Affected Scope:** `kill-tree` brief — “grep must find no taskkill”  
    **Discrepancy Description & Rationale:** The acceptance criterion does not say whether to grep the whole repo, only the touched scripts, or exclude docs/history. A literal reader might be unsure of scope; the intent (no `taskkill` left in `feature.ps1` / `delegate.ps1`) is implied but not spelled out.
