# Stage 5 re-audit: Initial Zoom Out: `docs/designs/feature-skill.md`

*   **Date:** 2026-11-10. **Target:** commit `687b0df`, full file, passed by file path (not embedded).
*   **Reviewers:** vendors swapped from the first audit, so each lens got a second vendor's view.
    *   `zoom_out` on Gemini Argon high (agy): 108 s, 81k tokens.
    *   `inventive_catalyst` on Grok 4.7 high (Cursor): about 100k tokens.
*   **Raw reports:** `.xagent/runs/fr-s5b/*.review.md` (local).
*   **Verdicts:** zoom_out says ready-with-fixes. inventive_catalyst found 3 Major findings and 2 Nits.
*   **Convergence cap:** EGM allows one re-audit per stage, and this was it. The remaining findings are resolved together with Stage 7's findings or recorded as accepted trade-offs. Stage 5 is not run again.

The first-audit fixes held up. Neither reviewer raised the command-line limit, the copied loop, the `hard` flag, `review-strong`, the duplicate plan copies, or side mode again.

## Re-raised against decisions the author already made

These need no new decision unless the author wants to reopen them.

*   **R1. Drop the kind table, `routing.json`, the rebalance rule and `routing.jsonl`** (zoom_out, Major).
    *   **Finding.** The reviewer says `runs.jsonl` already logs runs.
    *   **Lead:** the author kept a provisional heuristic on purpose, and `runs.jsonl` doesn't hold kind, rounds, verify result or council outcome. Kept.
*   **R2. Use `delegate`'s cheap `review` profile for task preflights, not the worker's model** (zoom_out, Major).
    *   **Finding.** The reviewer argues that if the cheap model can paraphrase the task, a stronger one can too.
    *   **Lead:** that's a fair point about direction. Matching the worker's model mostly matters for `code`-tier workers, where cheap and worker tier are the same model anyway. Only the `code-hard` case differs. This decision is the author's, so it's kept unless reopened.

## New findings

### 🟡 Major

*   **N-A. Merged work survives a move back to an earlier stage** (inventive_catalyst).
    *   **Finding.** After a design flaw sends the feature back to `design-review` or `plan`, tasks merged under the old plan still count as merged. A reused task id is never rebuilt, and new tasks start on top of the rejected code.
    *   **Recommendation.** Give each approved plan a generation number and stamp it in the merge trailer. Reconcile counts only current-generation merges.
    *   **Lead:** this is a real gap. It's also simpler than it looks: a move back can make the user choose between keeping the merged work (the tasks stay merged) and reverting the feature branch to the last good point. The generation stamp is the mechanical part of either choice.
*   **N-B. A quota failover moves the whole load onto the other subscription** (inventive_catalyst).
    *   **Finding.** The cap of 2 doesn't count preflights. On a quota limit, every remaining task moves to the other vendor at full speed, which makes it likely the second subscription runs out too.
    *   **Recommendation.** Count preflights in the cap. During a cooldown, drop to 1 agent and reroute only the task that hit the limit. Other tasks wait for the cooled-down vendor.
    *   **Lead:** this is valid, and partly reverses the cooldown rule adopted in stage 5. Note the trade-off: the build gets slower while a vendor cools down.
*   **N-C. A council that agrees still stops the unattended build** (inventive_catalyst).
    *   **Finding.** Every build council is a problem stop, even when the models agree on the retry. That conflicts with `on-problems` mode, whose purpose is running while you're away.
    *   **Recommendation.** On consensus, retry automatically and log the decision. Stop only on disagreement.
    *   **Lead:** this is a design choice for the author. The risk is that a wrong consensus retries unattended, and the next review round still catches it.
*   **N-D. Trim `feature.ps1`** (zoom_out).
    *   **Finding.** Of the 16 subcommands, `lens` can be derived from deterministic review task ids plus the `.review.md` files already on disk. `wait` duplicates what `status` can compute. `checkin` can fold into `gate` and `stage`. The two plan schemas can be one.
    *   **Lead:** I'd accept the `lens` derivation (it uses less state) and the single schema. But `wait` overlaps with N-F: a problem stop's reason can't be derived from other state. I'd keep `checkin`, because the author wants the mode switchable during the build.

### 🟢 Nit

*   **N-E. The lead's synthesis can drop findings silently** (inventive_catalyst).
    *   **Recommendation.** Every lens finding appears in the report or is logged as a dismissal in `decisions.md` with a reason.
    *   **Lead:** cheap and in keeping with cross-vendor review. Accept.
*   **N-F. A problem stop is only in local state** (inventive_catalyst).
    *   **Finding.** If `state.json` is lost, `continue` can move past a stop you never cleared.
    *   **Recommendation.** Log each problem stop as a decision. Clearing it writes another decision, and reconcile treats an uncleared stop as still waiting.
    *   **Lead:** accept. This replaces local `waitingOn` with committed `stop` and `resume` decisions, which also settles `wait` in N-D.
*   **N-G. Rule-file removal is fragile** (zoom_out).
    *   **Finding.** An aborted run leaves tracked deletions that block `-Cleanup`. Removal can also hide rule files that are part of the reviewed change.
    *   **Recommendation.** Use `try/finally`. Don't strip files that are in the target diff or in `GoldfishContext`. `-Cleanup` tolerates deleted rule files.
    *   **Lead:** accept.
*   **N-H. The `mode` field reserved for side mode** (zoom_out).
    *   **Finding.** A future version can treat a missing `mode` as `main`.
    *   **Lead:** accept. It removes a field and costs nothing later.

## Resolution (2026-11-10, with the author)

| Finding | Outcome |
|---|---|
| R1 kind table and routing log | **Kept** (author decision, reconfirmed). |
| R2 preflight on the worker's model | **Kept** (author decision). The preflight now reruns on the new vendor after a reroute. |
| N-A merged work after going back | **Author chose per-task keep/redo.** The re-plan lists each merged task as `keep` or `redo`. `redo` merges are reverted with `git revert -m 1`, newest first, at plan approval. Merges carry an `Xagent-Gen` trailer, and only current-generation or kept merges count. |
| N-B quota failover | **Author chose to throttle.** Preflights count toward the cap. During a cooldown the cap drops to 1, only the failing task is rerouted, and the cooled vendor's other tasks wait. If only those are ready, `schedule` returns a cooldown wait. |
| N-C council stop | **Author chose to retry on consensus.** A consensus leads to an automatic `code-hard` retry with the council's guidance. Disagreement is a problem stop. At most 2 councils per task (author choice); a failure after the second is a problem stop. |
| N-D trim `feature.ps1` | **Partly accepted.** `lens` was removed: progress comes from fixed lens task ids and their `.review.md` files. There is one schema (`$defs/plan`). `wait` was removed in favour of N-F. `checkin` was kept (the author wants the mode switchable during the build). |
| N-E silent dismissals | **Accepted.** Every finding is in the report or logged as `[dismiss]` with a reason. |
| N-F problem stops only in local state | **Accepted.** Stops and resumes are committed decisions. An unmatched `[stop]` means the flow is waiting. |
| N-G rule-file removal | **Accepted.** Restore in `finally`. `-KeepRuleFiles` when rule files are in the target. `-Cleanup` restores before removing. |
| N-H `mode` field | **Accepted.** Removed. |
