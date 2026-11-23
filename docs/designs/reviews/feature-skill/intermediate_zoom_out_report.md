# Stage 8: Intermediate zoom out: `docs/designs/feature-skill.md`

*   **Date:** 2026-11-10. **Target:** commit `0be2b32` and later, the full file (1,091 lines).
*   **Reviewer:** `zoom_out` on **Grok 4.7 medium**, the effort trial: 421 s; 142k input, 17k output and 14k reasoning tokens, plus 322k cache reads.
*   **Raw report:** `.xagent/runs/fr-s8/`.
*   **Verdict:** buildable, with no Blocker. Four mechanisms added during review should come out of v1.

## Effort trial result

*   **Medium was not faster here.** It took 421 s, against 414 s for Grok high's stage 5 zoom-out (and 632 s for its round 2 structural review). Its token use was about the same.
*   **Its judgement was strong.** It cleanly separated the churn from the real gaps, and proposed the smallest version of each fix.
*   **Conclusion.** For review lenses, effort level barely changes cost or time, because most of the time goes into reading. Either level works, and medium is fine for the judgement seat.

## Lead note

Findings 1–5 and 7 contest decisions the author made during review rounds 1–2:
*   **#1** keep/redo (N-A);
*   **#2** pool cooldowns and fallback;
*   **#3** watched orphans (PF1);
*   **#4** the G4 pass test (PF2);
*   **#5** a GLM review of every diff;
*   **#7** the duplicate check-in writer.

They are the author's call. Finding 8 (DC2: one SHA field on each gate) and the small fixes in finding 10 are uncontested.

---

The design still solves the same problem, and it is still buildable. Review since the stage-5 zoom-out also added four mechanisms that v1 does not need. No finding is a blocker. Context is sufficient: the problem, the seven goals, and the reason (plain language, disk memory, recorded gates, coding kept off the Claude quota) are all in the document.

Stage 5’s cuts should stay cut. Side mode, the kind table and rebalance, the `hard` flag, `review-strong`, a second sign-off lens, the EGM sync script, and three copies of the plan are gone. Dropping Antigravity and the `lead` task profile after the terms check removed a second vendor path. `feature.ps1` as the only state writer, with `delegate.ps1` as the only agent launcher, matches the repo: there is no existing feature runner, lock, or pid file, and `delegate` already owns worktrees, profiles, and `runs.jsonl`. New JSON schemas follow the `result` / `review` / `council` schemas already in `skills/delegate/`.

## Major

**1. Severity:** Major  
**Affected scope:** Merged work after going back (lines 229–235); `plan` / `gate` (lines 834–835); re-plan tests (lines 962–968). Contests the stage-5 re-audit choice of per-task keep/redo.  
**Simplicity rationale:** A generation counter, `carry: keep|redo`, `Xagent-Gen` / `Xagent-Revert` trailers, ordered `git revert -m 1`, a revert-conflict abort, and a post-revert phase test are a second git product inside “go back.” v1 has one user and one checkout. On a move back, merged tasks stay merged and keep their ids; new work gets new task ids. Removing code is a hand edit or abandon. That closes the original hole (a reused id never rebuilds) without teaching every later stage about generations.

**2. Severity:** Major  
**Affected scope:** Usage pools (lines 346–358); cooldown in the build stage (lines 763–765); Quota (lines 632–635); prices in `models.json` (lines 915–916). Contests the pool-cooldown and dollar-estimate choices made when Antigravity was removed.  
**Simplicity rationale:** The doc already says the reset window is unknown and the Cursor pool’s size is unmeasured. A 60-minute auto-retry and a silent swap of GLM and DeepSeek onto Grok encode that guess into the scheduler, and the swap can spend the pool the workers need. Any usage-limit report is a problem stop until the user says the pool is back. `status` can show the raw token sum from `runs.jsonl`. Prices, dollar estimates, pool enums, and model fallback wait until one real limit has been seen. Round 3’s “measure the billing model” item should shrink this machinery, not add a detector.

**3. Severity:** Major  
**Affected scope:** Reconcile row for in-flight tasks (line 326); pid file (line 479); the watched-worker test (line 995). Contests the round-2 orphan rule.  
**Simplicity rationale:** “Watched” is a third runtime state: dead parent, live child, wait for output, kill at the child’s timeout, and a claim that pid checks are exact. Round 3 already showed that Windows pid reuse breaks “exact.” If the launching `delegate.ps1` is gone, reconcile kills the worker and marks the task `failed`. “Continue” runs it again. A pid file is enough to tell a live process from a dead one. Process-start-time tokens and a watcher are hardening on top of a mitigation.

**4. Severity:** Major  
**Affected scope:** G4 pass criterion (lines 49–50); commit-classification test (line 1003). Contests the round-2 pass-criteria addition.  
**Simplicity rationale:** The lead commits each accepted task inside the worker worktree, then merges it. A test that flags every lead-authored commit except “record, merge, or `[fix-up]`” fails on a correct run. Defining record commits, conflict commits, and revert commits so the test can pass is the churn round 3 already hit. G4 stays a rule: the plan cannot assign feature code to Claude, and each fix-up is a `[fix-up]` line followed by `verify`. The history classifier comes out.

**5. Severity:** Major  
**Affected scope:** Diff reviews (line 456), read against the build stage (lines 751–782) and `skills/delegate/SKILL.md` (optional goldfish only for risky diffs).  
**Simplicity rationale:** The build steps already have the lead read every changed file. A standing GLM review of every worker diff is a second review `delegate` does not require, and it spends the third-party pool the capacity row says covers about 5–10 features. When a goldfish does review a diff, GLM 5.2 is the model. That is not a per-task stage, and the cost estimate should not grow a line for one.

## Nit

**6. Severity:** Nit  
**Affected scope:** Task outcomes (lines 360–365 and 480); Future Improvements (line 675).  
**Simplicity rationale:** `outcomes.jsonl` exists to feed a later `code-hard` rule. Token totals already go to `runs.jsonl`. Review rounds and councils are already `[round]` and `[council]` lines. The log ships with the deferred rule, not with v1.

**7. Severity:** Nit  
**Affected scope:** `gate -Checkin` (line 834) and `checkin` (line 842).  
**Simplicity rationale:** One mode has two writers. `checkin` during the build is the one the author kept; the gate flag can set it only at plan approval by calling that same path.

## Round-3 items that are still open

These stay small. None of them justify a new subsystem.

**8. Severity:** Major  
**Affected scope:** Gate record (line 287); sign-off (lines 496–501). This is DC2.  
**Simplicity rationale:** A gate that stores only a timestamp and a quote does not name the tree it approved. The fix is one field: the feature-branch SHA (and, for design-locked, the design file’s blob) on the gate. `finish` and the drift check refuse when that SHA moved. Per-file pins, conflict-commit classes, and approval snapshots are the large version of this fix.

**9. Severity:** Nit  
**Affected scope:** `schedule` (line 336) and the `failed` reconcile result (line 326). This is DC4 and DC8.  
**Simplicity rationale:** `schedule` already returns only `pending` tasks. Say that `failed` stays failed until the user resumes it, and that a second failure is a `[stop]`. A crash-budget field is extra. For the token total, put a `feature` field on the `runs.jsonl` line. Prefix matching on shortened ids is the brittle version.

**10. Severity:** Nit  
**Affected scope:** DC5, DC6, DC9, DC10, DC12, DC13, DC14.  
**Simplicity rationale:**  
- DC5 is already met for omitted tasks (line 835). The “test every kept phase” loop disappears with the redo machine in finding 1.  
- DC6: undeclared shared files are caught by the out-of-scope stop and by `git merge --abort`. Case-folding is already specified (line 845). An implicit-dependency graph is not part of v1.  
- DC9: a drift run that does not return the three lists is a failed lens, same as any other missing report. The diff is already a file (line 497). A per-file coverage ledger is extra.  
- DC10 is item 16 (lines 919–925): rewrite `delegate`’s SKILL off Antigravity routing. No extra mechanism.  
- DC12: the name grammar is already at lines 706 and 820. `new` keeps failing while `feature/<name>` exists, including after abandon. A name registry is extra.  
- DC13: `*_API_KEY` already covers the Cursor and Gemini key names. Two more literals (`GOOGLE_APPLICATION_CREDENTIALS`, `DATABASE_URL`) fit the existing denylist. A secret scanner does not.  
- DC14: finding 2 closes the pool question. “Open Questions: none” (line 90) is then true.

## Resolution (2026-11-10)

The author chose to **accept all cuts**:
*   Merged tasks stay merged. Keep/redo, generations and reverts are gone.
*   There are no pool cooldowns, fallbacks or dollar estimates, and any limit is a problem stop.
*   Orphaned workers are killed and marked `failed`, and a `failed` task waits for resume, with a second failure becoming a stop.
*   G4 is a rule, not a commit-classification test.
*   The goldfish diff review is optional.
*   The outcomes log is deferred.
*   The check-in setter is a single code path.

Also applied:
*   **Gates record the approved SHA** (and, for design-locked, the design blob), and `finish` refuses if either has moved.
*   **Runs carry a `feature` field** for token totals.
*   **Two more names** went on the environment denylist.
*   **The judgement seat** is `grok-4.7-medium`, after this trial.
*   **The two Cursor pools** are stated as facts, from the author's Spending page, with rough rates.
