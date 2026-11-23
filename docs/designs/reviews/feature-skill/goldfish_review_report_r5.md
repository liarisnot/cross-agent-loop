# Goldfish review report: Stage 7 (Critic Review), round 5

**Target:** `docs/designs/feature-skill.md` at `01cfbd6`, FeatureRange lines 1–671. Raw reports are in `.xagent/runs/fr-s7r5-{dc,st,sy}/`. This is round 2 of the new convergence count.

| Lens | Model | Time | Result |
|---|---|---|---|
| `design_critic` | GLM 5.2 | 85 s | 2 Blockers, 9 Majors, 6 Nits |
| `structural` | Grok 4.7 medium | 381 s | 1 Major (settled), 1 Nit (settled). Clean |
| `style` | GLM 5.2 | 49 s | 1 Major ("survives anything", one word), 3 Nits. Clean after triage |

**Round status: not clean, with churn (EGM `egm-review-loop` §2.4).** Per EGM, the loop stops here and the user answers one question: accept and proceed, continue, or return to drafting.

## Settled list (elephant only; never given to reviewers)

Earlier rounds: "Rejected by author", the heading names, the sync stub, the single-lens sign-off, the invented "trickiest step" citation.

Added from round 4's decisions (recorded without a further fix, so they are accepted risks):
*   Fix-ups are a judgement call with no hard cap; only their size is recorded.
*   No per-feature budget stop and no dollar estimate (cut in stage 8).
*   Manual merges carrying the `Xagent-Task` trailer count as merged (Alternative G). A worker forging one is covered by the unmitigated worker-access risk.

## Churn: new findings at the scope of round 4 fixes

Reverting the round 4 fix would resolve each of these.

*   **B1:** the single drift lens misses drift on large diffs. This is at the risk-row note added in round 4, and the single-lens sign-off is settled.
*   **B2:** waivers for lenses that didn't run have no quorum. This is at the not-run rule added in round 4 (DC-M8).
*   **M2:** no total ceiling on review rounds per task. This is at "the council count never resets".
*   **M4:** the fix-up size is recorded but not capped. This is at the counts added in round 4, and the no-cap rule is settled.
*   **M7:** a single large file's diff can't be split further. This is at the T6 fallback sentence.

## Re-raised settled findings

*   **M1:** a per-feature budget (settled).
*   **M3:** a trailer can be forged (settled, accepted risk).
*   **N3:** `doctor` should run `ls-remote` (the sync stub is settled).
*   **N4:** "Rejected by author" (settled).
*   **Structural:** "Rejected by author" and the heading names (both settled).

## Dismissed

*   **M9: the drift reviewer only sees a diff file.** It already runs on a worktree detached at `feature/<name>` (Sign-off step 2), so it can read the live tree.
*   **M6 (resetting an orphaned worktree, reading a process start time) and N1 (lock start time).** Implementation detail for stage 9.
*   **M8: task ids colliding across features.** Only one feature is active, and `delegate` refuses an existing worktree.
*   **N2 (the first usage limit costs one extra run) and N6 (the wording of the switch-back prompt).** Low value.

## New and valid (small)

*   **M5: the plan review has no judgement lens, and the doc doesn't say why.** One sentence: the plan's architecture is already settled by the locked design, and the plan review checks only that workers will read the tasks the same way.
*   **N5: the router has no rule for when `feature.ps1` itself fails.** One sentence: show the error and stop, never guess the stage.
*   **SY-1 (downgraded to Nit):** "survives anything" in D2 becomes "survives a reclone, a second machine or `git clean -fdx`".

## Outcome (2026-11-10)

The author chose **accept and proceed** (EGM: churn accepted by the user). The three new items (M5, N5, SY-1) were fixed. The churn findings and re-raised settled findings stay open as accepted risks. Because the doc changed after stage 8, stage 8 (the intermediate zoom-out) runs once more before stage 9.
