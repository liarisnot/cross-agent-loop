Status: resolved (2026-11-10)

# Goldfish annotated review report: Stage 7 (Critic Review), round 1

**Target:** `docs/designs/feature-skill.md` at `7803a7d`. FeatureRange is lines 1–477. The Stage 6 comprehension findings on the whole file are carried in, at the author's request.

*   **Reviewers (cross-vendor):**
    *   `design_critic` on Grok 4.7 high (Cursor), with `feature-spec-standard`
    *   `structural` on Gemini Argon high (agy), with `feature-spec-standard`
    *   `style` on Gemini Argon high (agy)
    *   `comprehension` from Stage 6, on Composer 2.5 (Cursor)
*   **Raw reports:** `.xagent/runs/fr-s7r1/`, `fr-s7r1s/` and `fr-s6/`.
*   **Ids:**
    *   `DC` is design_critic, `ST` structural and `SY` style.
    *   `CO` is comprehension. Its findings are numbered as in `comprehension_report.md`.
*   **Duplicates are merged into one item:**
    *   The missing entry-point table: CO3, ST3 and DC nit 1.
    *   The `lead` tasks: CO4 and DC5.
    *   The lens count: CO11 and DC nit 4.
    *   The Q tags: ST5 and SY7a.

## ⚠️ ESCALATE: these need the author's knowledge or decision

### E1. [`design_critic` DC5 + `comprehension` CO4]: Major. The `lead` profile and fix-ups contradict G4
*   **Discrepancy.** G4 says Claude doesn't write feature code, except small recorded fix-ups. Yet the plan can assign tasks to `lead`, and the build has no procedure for them: no verify, no cross-vendor review, no quota accounting. "Small" is undefined. A fix-up at merge time skips the scope check.
*   **AI suggestion:** ESCALATE. This is a policy choice about how much code Claude may write.
*   **Proposed edit if accepted:**
    *   **Keep `lead` tasks, with a procedure.** The lead commits on `feature/<name>`, then `verify` runs. The diff is reviewed by a non-Claude goldfish (`design_critic`, worker tier) and merged with the trailers. The task counts toward the cap.
    *   **Define a fix-up.** At most 3 files and 30 changed lines, followed by a `verify` re-run. Anything bigger is a problem stop.
    *   **G4 wording.** G4 names both exceptions.

### E2. [`design_critic` DC9]: Major. The Antigravity terms-of-service question is unresolved, and v1 routes work to agy by default
*   **Discrepancy.** `research.md` §2 leaves open whether automated `agy` use on a consumer plan is allowed, and `delegate` tells the lead to mention it. This design routes 4 of the 6 task kinds and half of all reviews to agy, and the cooldown can push even more there.
*   **AI suggestion:** ESCALATE. Only you can accept this risk or block it.
*   **Proposed edit:** under Risks & Mitigations, record it as an accepted risk with you as owner and a review date. The alternative is to block agy routing until the FAQ check is done.

### E3. [`design_critic` DC4b]: Major. There is no per-feature spending ceiling
*   **Discrepancy.**
    *   Automatic councils (up to 2 per task, run unattended) and design reviews (about 0.6–1.1M strong-tier tokens) have no token ceiling.
    *   The 60-minute cooldown is not tied to the vendors' real quota windows.
*   **AI suggestion:** ESCALATE for the ceiling. The mechanical parts are in F6.
*   **Proposed edit if accepted:**
    *   `status` shows a per-feature token total, read from `runs.jsonl` by delegate task id.
    *   An optional `budget` in `feature.json` (tokens per vendor) makes reaching it a problem stop. Off by default.
    *   The doc states that 60 minutes is a conservative guess, because neither CLI reports its reset time.

## 🔴 Blocker: PROPOSE FIX

### F1. [`design_critic` DC1]: Work in progress has no reconcile rule (G2 and CUJ 2)
*   **Problem.** The statuses `preflight`, `running` and `in-review` live only in local state. A `/clear` or crash can kill the `delegate.ps1` process, after which the task holds a slot forever.
*   **AI suggestion:** PROPOSE FIX.
*   **Proposed edit:** add a reconcile row that rebuilds these statuses from what's on disk:
    *   **The run finished** (a `.stdout.json` exists for the latest run, plus `result.json` or a review file) → `in-review`.
    *   **No live `delegate` process for that task id, and no result** → `failed`, and its slot is freed.
    *   **A live process** → leave it alone and don't relaunch.

    Also add a test that kills the session mid-run.

### F2. [`design_critic` DC2]: `merge` and `finish` operate on your only checkout with no failure protocol
*   **AI suggestion:** PROPOSE FIX.
*   **Proposed edit:**
    *   **Preconditions.** `merge` and `finish` refuse unless the tree is clean and `HEAD` is `feature/<name>`.
    *   **`finish` on conflict.** It runs `git merge --abort` followed by `git switch feature/<name>`, and fails.
    *   **Order of recording.** `signed-off` is recorded at approval, but `done` only after the merge commit on `main` exists.
    *   **New reconcile rows.** "Mid-merge on `main`" says to finish or abort the merge. "`signed-off` but not merged into `main`" means `finish` is pending.
    *   **Tests.** Cover a dirty tree and a conflicting finish.

### F3. [`comprehension` CO1]: The `escalated` status is used but missing from the `task` status list
*   **AI suggestion:** PROPOSE FIX.
*   **Proposed edit:** remove `escalated` from the state model. With the council rework, a stopped task stays `in-review` and the open `[stop]` decision carries the wait.

### F4. [`comprehension` CO2]: `stage` forbids `design` → `design-review`, which has no gate
*   **AI suggestion:** PROPOSE FIX.
*   **Proposed edit:** "A forward move needs the gate only when the stage table lists a gate to leave the current stage."

## 🟡 Major: PROPOSE FIX

*   **F5. [DC3] Going back can leave the stage's exit gate set.**
    *   **Edit.** State the invariant: "Moving to stage S clears every gate from S's exit gate onward, so the next forward move needs it again."
    *   **Test.** After going back to `design-review`, `stage -To plan` fails until a new `design-locked` is recorded.
*   **F6. [DC4a] Review runs sit outside the cap and the cooldown, and council counts and cooldowns are lost with local state.**
    *   **Edit.** The 2-agent cap and the cooldown apply to all `delegate` runs of a feature: reviews, preflights, workers and councils.
    *   **Edit.** A quota error during a review triggers the cooldown, and the lens is retried on the other vendor or after the cooldown.
    *   **Edit.** Council counts and cooldowns are derived from committed `[council]` and `[cooldown]` decisions, the same way `[stop]` already is.
*   **F7. [DC6] Glob overlap is wrong for `**` and `src/test*.ts`.**
    *   **Edit.** The overlap key is the folder part up to the last `/` before the first wildcard. An empty key means the whole repo. Paths are compared with a trailing `/`.
    *   **Tests.** Add `**`, `*.md`, and `src/test*.ts` vs `src/testing.ts`.
*   **F8. [DC7] Passing the target by file has no fallback.** This is partly contested: both trial agy runs (`fr-s5`, `fr-s5b`) did read the 795- and 880-line doc with file tools.
    *   **Edit.** Record that evidence.
    *   **Edit.** Keep "no shell" in the agy prompt.
    *   **Edit.** Fallback: if an agy review fails without a report, rerun that lens on Cursor and log it.
*   **F9. [DC8] The diff review goes through the Headroom proxy, which compresses large outputs.**
    *   **Edit.** `build.md` requires reading each changed file's diff separately. A compression marker means "review not done": use `headroom_retrieve` or a smaller chunk.
    *   **Edit.** Add this to Risks.
*   **F10. [DC11] The dismiss rule is not enforceable without the raw reports.**
    *   **Edit.** Each lens's raw report is committed as `docs/features/<name>/reviews/raw/<lens id>.md` before the synthesis is written.
*   **F11. [DC12] The threat model for workers is not stated.**
    *   **Edit.** Under Risks: workers run with permission checks bypassed (`--force` / `--dangerously-skip-permissions`) and have full shell and network access. A worktree doesn't isolate the parent repo or the network.
    *   **Edit.** `delegate`'s rule applies: secrets, credentials and deploy steps are never delegated.
*   **F12. [DC13] The drift report is a workflow skill, not a review persona.**
    *   **Edit.** Write our own thin persona `drift_report.md`. It quotes EGM's drift checklist (attributed and marked as modified) and asks for one read-only pass that returns three lists: missing, added and changed behaviour.
    *   **Test.** A fixture test with a planted deviation.
*   **F13. [CO3/ST3/DC-n1] There is no entry-point table.**
    *   **Edit.** Add a table to Routing rules: phrases → stage or action. Include abandon, status and council, plus phrases that must **not** fire.
*   **F14. [CO5 + CO11/DC-n4] The exact lens set per review isn't stated.**
    *   **Edit.** Add a table listing each review's phases, lenses, tiers and vendors:
        *   design review: 9 runs across EGM's 5 review phases
        *   plan review: 2 runs
        *   sign-off: 1 run
*   **F15. [CO6] `GoldfishContext` is undefined.**
    *   **Edit.** Define it: the reading list in the review task file, with one example.
*   **F16. [CO7] The router steps disagree between sections.**
    *   **Edit.** Use one sequence in both places: `status` (which includes feature selection), then `reconcile`.
*   **F17. [CO8] The location of `routing.jsonl` is unresolved.**
    *   **Edit.** `feature.ps1` resolves it from its own location (`<skill root>/../../benchmarks/`), the same way `delegate.ps1` finds `runs.jsonl`.
*   **F18. [CO9] `sandbox` is undefined.**
    *   **Edit.** Link `docs/test-plan.md`'s sandbox repo and its path.
*   **F19. [CO10] `<n>` in lens ids is undefined.**
    *   **Edit.** `<n>` is the review's run number for that stage: 1 for the first review, 2 after going back.
*   **F20. [ST1] Future Improvements is an H3.**
    *   **Edit.** Promote it to `##`.
*   **F21. [ST2] There is no Risks & Mitigations section.**
    *   **Edit.** Add `## Risks & Mitigations`, holding isolation, worker permissions (F11), the diff-review proxy (F9), quota (E3/F6), agy terms (E2) and command-line limits (F8). Each entry gets its mitigation and the risk that remains.
*   **F22. [ST4] Alternatives use inconsistent layouts.**
    *   **Edit.** Use Pros / Cons / Reason for Rejection everywhere, one block per option.
*   **F23. [SY1] Planned `delegate.ps1` changes read as if they exist.**
    *   **Edit.** Add a short "Changes to `delegate`" subsection, and refer to it with "after this change".
*   **F24. [SY2] `-KeepRuleFiles` reads as automatic.**
    *   **Edit.** State that the caller passes it.
*   **F25. [SY3] Alternative H overstates the preflight evidence.**
    *   **Edit.** The trials only tested comprehension and readiness on small task files. The judgement lenses go to the strong tier by choice, not because of measured weakness.

## CONTEST

*   **C1. [DC10, SY7c] "Rejected by author" without a link, used 15 times.**
    *   **Why contested.** `egm-draft` (vendored as item 12) requires `Rejected by author: [technical rationale]` for author decisions, and forbids naming a maintainer without a link. The reviewers could read that rule in the EGM files once they are vendored, but not today.
    *   **Partly fixed anyway.** Where a review changed an outcome (F and I), link the review report.
*   **C2. [SY4] Drop the "remaining risk" line.**
    *   **Why contested.** It's a real constraint for the operator: user-level CLI rules still load. It moves into Risks (F21) and gets the concrete instruction "keep project rules out of `~/.cursor` and `~/.gemini`".

## 🟢 Nits

*   **PROPOSE FIX (apply all):**
    *   DC-n2: add the phase `test` to the `feature.json` field list.
    *   DC-n3: put the `Xagent-Revert` trailer into the Technical Plan's redo text.
    *   DC-n5: the lead checks upstream EGM monthly with `git ls-remote` against `b7d9e27`, noted in `docs/HANDOFF.md`.
    *   DC-n7: `abandon` switches back to `main` when the tree is clean, and selection rule 2 skips `done`/`abandoned` features.
    *   ST5 + SY7a: remove the undefined Q1–Q4 tags.
    *   ST6: use dividers consistently, and split Build scheduling into H4 subsections.
    *   ST7: link the decision-001 and section references.
    *   SY5: drop "(main mode)" from CUJ 1.
    *   SY6: cut the subjective phrases, fix the `HANDOFF.md` path, and merge the repeated routing sentences.
    *   SY7b: replace review-history narration with links.
    *   CO12: renumber the implementation items.
    *   CO13: label machine-specific paths.
    *   CO14: add abandon to the entry table.
    *   CO15: name the `*.review.md` pattern exactly.
*   **DECLINE:**
    *   DC-n6 (Open Questions): it resolves itself once F1, F5 and F7 land.

## Resolution (interactive breakdown with the author, 2026-11-10)

*   **E1: the author decided.**
    *   No `lead` profile: Claude never writes feature code from the plan.
    *   Fix-ups are a judgement call, with "about 3 files and 30 lines" as a guideline, not a cap. Each is logged, and `verify` runs again afterwards.
    *   Deploy steps: workers never do them. The lead may, with the user's approval and using secret references only. v1 has no deploy stage.
*   **E2: the author decided, after the T0 check found that Google's FAQ forbids wrapping `agy` on consumer plans.**
    *   No `agy` automation, and no per-token API key.
    *   Everything runs through the Cursor CLI. Workers: Composer 2.5 and Grok 4.7 high. Judgement and council: Grok 4.7 high and GLM 5.2. Readiness: DeepSeek V4.1 Flash.
    *   The kind table and rebalance were dropped. A slimmer `outcomes.jsonl` was kept. Cooldowns are per Cursor pool.
*   **E3: the author decided.** `status` shows the feature's token total and estimated third-party dollars. No budget stop.
*   **F1–F25: accepted**, with these changes:
    *   **F16:** plus the plan-mode handling.
    *   **F17:** the logs moved to `%LOCALAPPDATA%\xagent\` (option b). An Installation section was added to v1. Plugin packaging comes after v1.
    *   **F11:** worker sandboxing became the high-priority first item after v1.
    *   **F24:** was already applied.
*   **C1: the contest was upheld.** "Rejected by author:" stays, with links added for F, I and J.
*   **C2: the author overruled the contest.** The "remaining risk" line was dropped.
*   **Nits: all proposed fixes were applied** (by the author's instruction). DC-n6 was declined, as it resolves itself.

The design doc was rewritten as a whole (commit `d50757a`) to apply all of these.
