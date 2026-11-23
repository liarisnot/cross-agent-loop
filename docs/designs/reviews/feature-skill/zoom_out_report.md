# Stage 5: Initial Zoom Out review: `docs/designs/feature-skill.md`

*   **Date:** 2026-11-10. **Target:** commit `85e5165`, full file.
*   **Reviewers (cross-vendor goldfish):**
    *   `zoom_out` on Grok 4.7 high (Cursor): 414 s, 157k tokens.
    *   `inventive_catalyst` on Gemini Argon high (agy): 203 s, 79k tokens.
*   **Raw reports:** `.xagent/runs/fr-s5/*.review.md` (local, not committed).
*   **Verdicts:** zoom_out says no blocker, but five additions should come out of v1. inventive_catalyst says ready-with-fixes.

The lead's notes are marked **Lead:**. Findings that go against a choice the author made while drafting are tagged **[contests author decision]**. The goldfish could not know those choices were deliberate, so these need the author's call.

## 🟡 Major

### M1. Agy reviewers fail on long inputs (source: inventive_catalyst; confirmed by this review run)

*   **Finding.** `delegate.ps1` puts the whole review input into agy's command line (to keep agy from trying shell commands) and fails above 28,000 characters. The design doc is about 62 KB. A sign-off diff plus the design is larger still. So design-review and sign-off runs on agy fail. The 1,500-line file-group split at sign-off does not fix this, and it also hides problems that span phases.
*   **Recommendation.** Put only the control prompt (persona, standard, parameters) in the command line. Write the target (design, diff) to a file in the worktree's `.xagent/` and give the reviewer its path to read with file tools.
*   **Lead:** confirmed in practice. This stage's first agy run failed with `Embedded review/council prompt too long (66915 chars)`. The rerun with a file pointer worked: agy read the 795-line doc with its file tools. This is a real gap in the design: item 15 says "no other behaviour changes" to `delegate.ps1`.

### M2. Cross-vendor goldfish isolation is accepted too easily (source: inventive_catalyst)

*   **Finding.** The worker CLIs load `AGENTS.md`, `CLAUDE.md`, `.cursor/rules` and `.agents/` from the worktree as system instructions. Persona text in the user turn cannot reliably override them.
*   **Recommendation.** In read-only runs, have `delegate.ps1` remove those rule files from the throwaway worktree before launching the reviewer, and restore them in a `finally` block.
*   **Lead:** valid, and cheap, because read-only worktrees are already throwaway. The restore step may not be needed at all, since the worktree is deleted at cleanup. That is simpler than the reviewer's version.

### M3. The lead does too much mechanical work (source: inventive_catalyst)

*   **Finding.** Each task needs about 8–10 tool calls from the lead (scope check, tests, state updates, merge), and a design review needs 7 lens runs plus in-context synthesis. That grows the lead's context, causes compaction, and spends Claude quota on bookkeeping. Also, `state.json` does not track review-lens progress, so a compaction in the middle of a review loses its place.
*   **Recommendation:**
    *   Add a composite `feature.ps1` step that runs the scope check and the task's test, then updates the state.
    *   Have `feature.ps1` track the lens runs and merge the findings into one pre-sorted file, leaving the lead only the deduplication.
*   **Lead:** the direction is right, and it fits G2 (resumable). It does make the script bigger.

### M4. G3 contradicts the check-in default (source: zoom_out) [partly contests author decision]

*   **Finding.** G3 lists "each build phase checked in" as a gate. The stage table and Q4 make phase check-ins opt-in, with `on-problems` as the default. The reviewer suggests going further: drop the `every-phase` mode entirely.
*   **Lead:** the G3 wording is a real inconsistency, and I missed it when updating after Q4. G3 should name three recorded gates, with phase check-ins as an opt-in mode. Removing `every-phase` reverses your decision, which kept it on purpose for complex features.

### M5. Kind table and 60% rebalance are premature (source: zoom_out; inventive_catalyst Nit agrees) [contests author decision]

*   **Finding.** `kind`, `routing.json`, the 60% rule and its tests encode a guess, with no benchmark data, into the plan schema.
*   **Recommendation.** The lead writes `vendor` per task using `delegate`'s existing heuristic, and the user can change it at plan approval.
*   **Also from inventive_catalyst.** When one vendor hits its quota, every later task pinned to it fails the same way. Record a cooldown in the state so `schedule` routes around that vendor.
*   **Lead:** the cooldown point is valid under any routing option and should be adopted. Whether to drop the kind table is your call.

### M6. Main and side modes are two products (source: zoom_out) [contests author decision]

*   **Finding.** Side mode adds a worktree, a name prefix, `promote`, two dirty-tree checks, overlap warnings, and `<repo>` versus `<fdir>` logic in every subcommand.
*   **Recommendation.** v1 should be main mode only.
*   **Lead:** this goes against your explicit request for side work during a major feature. One middle path: keep side mode but drop `promote` from v1.

### M7. The comprehension preflight model rule conflicts with the routing table (source: zoom_out) [partly contests author decision]

*   **Finding.** The routing table puts comprehension on the cheap `review` profile, while Build scheduling puts it on the worker's model.
*   **Recommendation.** Use `delegate`'s preflight unchanged.
*   **Lead:** the conflict is in the wording only. The table covers design and plan reviews; the build rule covers task preflights. The text should say so. Matching the worker's model was your decision.

### M8. `hard` duplicates `code-hard` (source: zoom_out)

*   **Finding.** `hard: true` is a second "this is tricky" bit next to `profile: code-hard`, and the two can disagree.
*   **Recommendation.** Use one rule: council after 2 failed reviews on `code`, and after 1 on `code-hard`. Drop `hard`.
*   **Lead:** agree.

### M9. The build stage copies `delegate`'s loop (source: zoom_out)

*   **Finding.** `build.md` restates review, iterate, merge and quota switching, but with different round limits from `delegate` (council after 2 failed rounds versus about 3 rounds then the lead takes over). The two will drift apart.
*   **Recommendation.** `build.md` lists only what differs from `delegate` (scheduling, `-Base`, trailer merge, state updates, problem stops). The round limit is set in one place.
*   **Lead:** agree.

## 🟢 Nit

*   **N1. `review-strong` is just `review` with other models** (zoom_out).
    *   **Finding.** `-Model` already overrides the model, as this review run itself did.
    *   **Recommendation.** Keep `review`, list the strong model ids in `models.json`, and still add the `standards.json` lookup.
*   **N2. Three copies of the plan** (zoom_out).
    *   **Finding.** `plan.json`, `feature.json` and `plan.md` with markers can disagree.
    *   **Recommendation.** Keep `feature.json` as the source and generate `plan.md` from it.
*   **N3. Sign-off runs two final reviews** (zoom_out).
    *   **Recommendation.** In v1, the drift report plus the full test suite is enough for G6, and `design_critic` on the whole diff can be dropped. With M1 fixed, the file-group split is no longer needed either way.
*   **N4. The EGM sync script is premature** (zoom_out).
    *   **Recommendation.** Copy once, pin the commit, and write `egm-sync.ps1` when the first upstream change arrives.
*   **N5. A stale Non-Goals sentence** (zoom_out).
    *   **Finding.** "Where reviewers run … is an open question" contradicts the resolved Q3.
    *   **Recommendation.** Delete it.
*   **N6. File-claim overlap is coarse** (inventive_catalyst).
    *   **Finding.** Adding files to a shared folder, or editing a shared manifest, forces tasks to run one after another. A harmless stray file causes a problem stop.
    *   **Recommendation.** Allow globs in `files`. Revert harmless out-of-scope changes automatically before stopping.
*   **N7. Count-based balancing ignores token cost** (inventive_catalyst).
    *   **Recommendation.** Weight by the token totals in `runs.jsonl`. This only matters if M5 keeps the rebalance rule.

## Evidence about the review process itself

Running this stage tested the design's own goldfish path:
*   **The agy command-line limit** (M1) blocks agy for any doc of design size, unless the doc is passed by file.
*   **Cost and time.** The strong-tier reviews took 3–7 minutes and 79k–157k tokens each. A full 5-stage review is about 9 such runs. That is useful input for the Quota non-functional requirement.
*   **Output quality.** Both strong models produced specific, line-referenced findings that cite the code. That supports using the strong tier for the judgement lenses.

## Resolution (2026-11-10, with the author)

| Finding | Outcome |
|---|---|
| M1 agy command-line limit | **Fixed.** Review and council targets are passed by file. `delegate.ps1` keeps only the control prompt in the command line. |
| M2 isolation | **Fixed.** Rule files are removed from read-only worktrees before launch and restored before the read-only check. |
| M3 lead bookkeeping | **Fixed.** `feature.ps1 verify` (scope plus test), `lens` (review progress) and `cooldown` were added. The deterministic merge of findings was not adopted, because Cursor reviewers return free-form Markdown. |
| M4 G3 vs check-in | **Fixed wording.** G3 names three gates. Keeping the opt-in `every-phase` mode was **reconfirmed by the author**. |
| M5 kind table | **Kept by the author** as a provisional heuristic. All rules are guesses until data exists. **Added:** every merged task records a routing outcome in `benchmarks/routing.jsonl`. **Adopted:** the vendor cooldown from the inventive_catalyst Nit. |
| M6 main and side modes | **Accepted.** v1 is main mode only. Side mode is deferred to Future Improvements (Alternative F). |
| M7 preflight model conflict | **Fixed wording.** The task-preflight rule (build) and the review routing table (design, plan, sign-off) are scoped separately. |
| M8 `hard` flag | **Accepted.** `hard` was removed. A council runs after 2 failed rounds on `code` and 1 on `code-hard`. |
| M9 copied loop | **Accepted.** `build.md` lists only what differs from `delegate`. The round limit is set in one place. |
| N1 `review-strong` | **Accepted.** `-Profile review -Model <review.strong>` is used instead. |
| N2 three plan copies | **Accepted.** `feature.json` is the only source, `plan.md` is fully generated, and the input file is deleted after import. |
| N3 two final reviews | **Accepted.** Sign-off is the drift report (as a cross-vendor persona) plus the full tests. |
| N4 sync script | **Accepted.** Deferred until the first upstream change. |
| N5 stale sentence | **Fixed.** |
| N6 coarse overlap | **Partly accepted.** Globs are allowed, with a conservative overlap rule. Automatic revert of out-of-scope changes was not adopted. |
| N7 token-weighted balance | **Not adopted** for v1. `routing.jsonl` collects the data for later. |
