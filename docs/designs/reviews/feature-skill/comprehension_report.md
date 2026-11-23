# Stage 6: Comprehension test: `docs/designs/feature-skill.md`

*   **Date:** 2026-11-10. **Target:** commit `7803a7d`, the whole file (880 lines), passed by file path.
*   **Reviewer:** `comprehension` on Composer 2.5 (Cursor, worker tier): 42 s, 63k tokens.
*   **Raw report:** `.xagent/runs/fr-s6/` (local).

## Lead triage

*   **Both Blockers are real contradictions inside the doc.**
    *   Status `escalated` is used but missing from the `task` status list. The council rework also changed escalation, so the status should be removed.
    *   `stage` says forward moves need a recorded gate, but `design` → `design-review` has no gate.
*   **Valid Majors:**
    *   #3: there is no entry-point table, although G1 refers to it.
    *   #4: lead-assigned tasks have no build procedure.
    *   #5: the exact lens set per review isn't stated in the doc.
    *   #6: `GoldfishContext` is undefined.
    *   #7: router steps differ between sections.
    *   #8: the path of `routing.jsonl` is unresolved.
    *   #9: `sandbox` is undefined.
    *   #10: `<n>` in lens ids is undefined.
*   **Nits:**
    *   #11, #12, #14 and #15 are valid.
    *   #13 is a misreading. The reviewer saw its own worktree's path, while `D:\cross-agent-loop` is the real install path. Still, labelling machine-specific paths is cheap.
*   **The paraphrase matches the intended design.** No section was misread at the level of what the system does.

---

## What this proposes

The document specifies a new Claude Code skill, `feature`, that carries one product feature from a problem statement through design, multi-lens design review, planning, parallel delegated implementation, and sign-off. The user speaks in plain language; the skill routes to stage instructions, persists durable state on a per-feature git branch (`feature/<name>`), and records explicit approval gates. Design stages reuse a vendored copy of Google’s Elephant–Goldfish Model (EGM) workflow, but reviews run through the existing `delegate.ps1` launcher on Cursor and Antigravity instead of Claude subagents. The build stage turns an approved plan into phased tasks, schedules non-overlapping work (up to two workers), verifies scope and tests, merges with git trailers, and can escalate to a multi-model council. Sign-off runs tests and a drift-style check of the full diff against the locked design before merging to `main`.

## How the existing system works, per this document

Today the repo already has a `delegate` skill: Claude acts as lead, workers run headless in isolated worktrees via PowerShell, with model profiles in `models.json`, goldfish preflight/review personas, benchmark mode, and a council profile. EGM’s design workflow is not model-invocable as installed plugins, so decision 001 vendors EGM text into the repo while personas for cross-vendor review live under `skills/delegate/personas/`. The planned `feature` skill wraps that stack: a router `SKILL.md` calls `feature.ps1` for JSON state, reconciliation with git, gates, scheduling, and merges; stage markdown files tell the lead when to call vendored EGM steps versus `delegate.ps1`. Committed artifacts live under `docs/features/<name>/` and `docs/designs/<name>.md`; volatile runtime fields live in gitignored `.xagent/features/<name>/state.json`.

---

### Findings

**1. Severity: Blocker**  
**Affected Scope:** `feature.ps1` `task` subcommand (Detailed Implementation Plan, ~line 642) vs State model (~line 250) and `build.md` council escalation (~lines 578–581)  
**Discrepancy:** The state model and build stage describe task status `escalated` after council disagreement, and the build flow calls `task -Status escalated`. The `task` subcommand table limits status to `pending`, `preflight`, `running`, `in-review`, `merged`, and `failed` only. A reader cannot tell whether escalated tasks are representable, how `schedule` treats them, or whether this is a documentation typo versus a missing enum value—yet CUJ 5 and problem-stop flow depend on it.

**2. Severity: Blocker**  
**Affected Scope:** `feature.ps1` `stage` subcommand (~line 638) vs Stages and gates table (~lines 194–200) and design stage flow (~line 514)  
**Discrepancy:** The `stage` subcommand says forward moves are allowed “only when the gate is recorded.” The stages table says the `design` stage has **no** gate before `design-review`, and `design.md` moves to `design-review` when drafting finishes without any gate call. Read literally, the script spec forbids `design` → `design-review`. The doc needs an explicit rule: gates are required only when the stages table lists a “gate to leave,” or similar.

**3. Severity: Major**  
**Affected Scope:** Goal G1 (~line 38) vs Detailed Implementation Plan item 1 (~lines 498–499)  
**Discrepancy:** G1’s pass criterion refers to “the entry-point table,” but the design document never contains that table—only scattered example phrases and a note that the router `SKILL.md` will include a phrase-to-stage mapping. Someone verifying G1 from this design alone cannot know the canonical phrase list or expected routing for ambiguous phrases like “continue” at different stages.

**4. Severity: Major**  
**Affected Scope:** Build scheduling / `profile: lead` (~lines 545, 641) and `build.md` (~lines 560–561)  
**Discrepancy:** The plan assigns some tasks to `lead` (not workers), and `schedule` returns them with `assignee: lead`, but the build stage file only details the `delegate` loop for worker tasks. It does not describe how lead tasks are executed, marked complete, or merged—whether they skip `delegate`, how `verify` applies, whether they need commits on `feature/<name>`, or how they interact with the parallelism cap. The story from plan → build is incomplete for any feature with cross-cutting or security work assigned to the lead.

**5. Severity: Major**  
**Affected Scope:** Design-review stage (~lines 516–530) vs Goldfish review routing (~lines 333–354)  
**Discrepancy:** The routing table lists many lenses and tiers, and NFR mentions “about 9 lens runs over 5 stages” (~line 448), but the design never states the **exact** lens set and order for **design-review** versus **plan** (two runs) versus **sign-off** (drift only). Implementation is told to “follow vendored `egm-review`,” which externalizes critical scope. A naive implementer cannot estimate cost, resume behavior, or test expectations from this file alone without opening vendored EGM and inferring parity.

**6. Severity: Major**  
**Affected Scope:** GoldfishContext (~lines 348, 522)  
**Discrepancy:** Review task files must name a `GoldfishContext` reading list, and rule-file removal skips files listed there, but this design never defines the term or shows a minimal example (contrast the comprehension review task you were given, which includes a explicit list). Readers must guess it is a convention block in the delegate task file, not a schema field or path.

**7. Severity: Major**  
**Affected Scope:** Router components (~lines 160–164) vs Detailed router steps (~lines 493–496)  
**Discrepancy:** The architecture lists four router steps starting with “pick active feature,” then `reconcile`. The detailed router body runs `feature.ps1 status` first (which embeds active-feature selection), then `reconcile`. Functionally similar, but the split between “pick active feature” and `status` is inconsistent; someone implementing the diagram might duplicate selection logic outside `status` or skip `-Cwd` behavior described only on the `status` subcommand.

**8. Severity: Major**  
**Affected Scope:** `merge` subcommand (~line 645) and benchmarks paths  
**Discrepancy:** Worker merges and feature work happen in the user’s `<repo>`, but routing telemetry is appended to `benchmarks/routing.jsonl` in the **cross-agent-loop** harness repo. The doc does not explain how `feature.ps1` resolves that path (fixed install path, env var, or repo detection), whether CI on a consumer repo writes elsewhere, or what happens when the skill is vendored into another project. That breaks self-containment for operators who only read this design.

**9. Severity: Major**  
**Affected Scope:** Verification Plan (~lines 818, 859, 871)  
**Discrepancy:** End-to-end verification requires CUJ 1–7 on the ``sandbox` repo`, but this file never defines `sandbox` (path, layout, or pointer to `docs/test-plan.md`). `docs/test-plan.md` mentions `sandbox/` as a throwaway project; the feature design does not link or restate that, so the verification section is not executable from the design doc alone.

**10. Severity: Major**  
**Affected Scope:** Lens task ids (`<name>-design<n>-<lens>`, ~line 523)  
**Discrepancy:** The pattern includes `<n>` without defining whether it is review generation, repeat review after going back, or something else. Resume logic and collision avoidance depend on that number; only `generation` is defined for plan/build merges, not for design review rounds.

**11. Severity: Nit**  
**Affected Scope:** Non-Functional Requirements (~line 448)  
**Discrepancy:** “9 lens runs over 5 stages” mixes EGM’s phased review with the feature’s five **user** stages (design, design-review, plan, build, sign-off). Quota planning is harder because “5 stages” reads like the feature pipeline, not EGM review phases.

**12. Severity: Nit**  
**Affected Scope:** Detailed Implementation Plan numbering (items 12 → 14, no 13)  
**Discrepancy:** Skipped item number invites doubt about a missing section.

**13. Severity: Nit**  
**Affected Scope:** Machine setup (~lines 848–849)  
**Discrepancy:** Junction and permission examples use `D:\cross-agent-loop\` while this repository path may differ (`fr-s6-cursor`). Readers may copy the wrong path unless told these are placeholders.

**14. Severity: Nit**  
**Affected Scope:** Abandon flow (~lines 191, 489)  
**Discrepancy:** “Abandon” appears in routing and `stage` behavior but has no CUJ or stage file outline, unlike the other user-facing stages.

**15. Severity: Nit**  
**Affected Scope:** State model lens completion (~line 256) vs Pester case (~line 805)  
**Discrepancy:** Text says a lens is done when `.xagent/runs/<id>/` holds a `.review.md` file; the test description says `*.review.md` under runs. Aligning the glob with `delegate.ps1`’s concrete `reviewFile` naming would remove ambiguity for resume after compaction.

---

**Paraphrase confidence:** The overall pipeline and division between committed records, local state, `delegate`, and vendored EGM connect clearly. The blockers above are places where specified behavior contradicts itself or omits steps an implementer must invent; the major items are undefined terms, missing tables, or assumptions about external repos and vendored EGM content that this document claims to be the source of truth for building v1.
