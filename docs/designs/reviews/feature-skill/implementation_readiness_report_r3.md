# Implementation readiness, stage 9 round 3 (focused re-audit of `81d4ecd`)

| Lens | Model | Time | Result |
|---|---|---|---|
| `implementation_readiness` (IR) | DeepSeek V4.1 Flash | ~7 min | 3 Blockers, 9 Majors, 6 Nits |

**Scope:** only the lines `81d4ecd` changed (the round 2 fixes), plus defects they cause. Raw report: `.xagent/runs/fr-s9r3/`. Every finding was checked against the doc by the lead before triage.

**Verdict from the reviewer:** not ready. **Lead's decision, agreed with the user:** fix everything below except M7 and M10, and lock **without a round 4**. Each round since round 1 has found new defects in the previous round's fixes. The remaining risk is local, and the Pester suite covers it at build time (B1, for example, fails test "`done` derived after `finish`" on its first run).

## Resolutions

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Blocker | `gate` records `sha` and then commits, so `HEAD` is always past it and `finish` refuses forever | **Fixed.** `finish` refuses only if `git diff --name-only <sha> HEAD` lists a file outside `docs/features/<name>/`. Test added: `finish` succeeds right after the gate. (The reviewer's suggested tree-id compare would also fail: the gate commit changes the tree.) |
| 2 | Blocker | The council trigger has no cap, so a third council is convened instead of the documented stop | **Fixed.** A "cap check first" bullet: a failed review with `councils == 2` is a problem stop, before the trigger is considered |
| 3 | Blocker | Reconcile reads `.xagent/runs/<delegateTaskId>/`, but preflight and council runs use `-pc`/`-pr`/`-c<k>` | **Fixed.** Reconcile takes the newest run among the task's own ids (exact set, no prefix glob). Test added. No new state field |
| 4 | Major | The fix-up is left unstaged, so the merge commit drops it | **Fixed.** Merge step 1 commits with `add -A`; stop if cleanup reports tracked changes |
| 5 | Major | The stop after the second council is logged as `[council]`, inflating the count | **Fixed.** Logged as `[stop]` only |
| 6 | Major | Name cut 12 in the plan, 16 in the design | **Fixed.** The design points at the item 8 budget (12/20). Same as zoom-out Nit 3 |
| 7 | Major | The `nextAction` table isn't written out | **Rejected.** Zoom-out r3 judged key plus example the right altitude. The builder writes the table; the test checks one entry per stage |
| 8 | Major | `schedule` undefined without a plan, but the cap rule calls it in every stage | **Fixed.** `liveRuns` first; no tasks before a plan, `liveRuns` and `cap` still returned. Test added |
| 9 | Major | Sign-off never copies its raw report; `[dismiss] <lens>: not run` can't tell p5 from p8 | **Fixed** (copy step added; not-run dismissals use the full run id). The script-enforced gate check (9b) is **not added**: the stage files enforce it |
| 10 | Major | The failed-reviewer retry ladder isn't recorded across a resume | **Rejected** as new machinery for a rare case. One sentence instead: after a resume the ladder restarts (worst case one extra retry) |
| 11 | Major | `-ResultFile` has no producer in `delegate.ps1`'s summary | **Fixed.** `<worktree>/.xagent/result.json` |
| 12 | Major | Preflight commands omit `-Agent`, `-Profile review`, `-Feature` and more | **Fixed.** Written out in full |
| 13 | Nit | `state.schema.json` listed in two items | **Fixed.** Removed from item 9 |
| 14 | Nit | `<review>` in the review-number glob is undefined | **Fixed.** Literal globs; sign-off is always 1 |
| 15 | Nit | `doctor` checks Pester 5, tests need 5.5 | **Fixed** |
| 16 | Nit | `stage -Reason` mandatory but never passed | **Fixed.** Optional, default `<from> -> <to>` |
| 17 | Nit | The collision suffix can't happen | **Fixed.** Rule and test dropped |
| 18 | Nit | Sandbox fixture source not in the repo | **Fixed.** Written fresh: `add`, `multiply`, one case each |
