Status: resolved (2026-11-10)

# Goldfish annotated review report: Stage 7 (Critic Review), round 2

**Target:** `docs/designs/feature-skill.md` at `5f8e920`, FeatureRange lines 1–669.

**Reviewers.** This is the first round on the new model seats, all run through the Cursor CLI:

| Lens | Model | Time | Tokens |
|---|---|---|---|
| `design_critic` | GLM 5.2 | 79 s | 44k |
| `structural` | Grok 4.7 high | 632 s | 176k |
| `style` | GLM 5.2 | 49 s | 32k |

*   **Raw reports:** `.xagent/runs/fr-s7r2-{dc,st,sy}/`.
*   **Round status: not clean.** There is 1 new Blocker, and new unsettled Majors.
*   **The round 1 fixes held.** No round 1 finding came back except the two settled ones below (S1 and S2).
*   **Observation:** GLM 5.2 produced specific, line-referenced findings, about as dense as Grok's, at a quarter of the tokens and a tenth of the time.

## Settled (not reopened, per the loop rules)

*   **S1. [`structural` #1] "Rejected by author" without a link.** Settled as contest C1 in round 1. The EGM draft rule requires this format for author decisions. The link rule applies to maintainers.
*   **S2. [`design_critic` M3] Sign-off uses a single lens.** Settled in round 1 (N3, accepted by the author: the drift report plus the tests). Still worth adding: a Risks row stating the residual (PF9 below).

## ⚠️ ESCALATE

*   **X1. [`design_critic` B1] Blocker: the mitigation for "workers can read any file" only covers workers changing files.** Diff review shows what a worker *changed*, not what it *read*. That covers `~/.ssh`, `~/.aws`, environment variables and sibling repos. There are two options:
    *   **(a) A partial v1 mitigation.** `delegate.ps1` launches workers with a cleaned environment: it removes known secret variables (`*_API_KEY`, `*_TOKEN`, `AWS_*`, `SSH_AUTH_SOCK`, `ANTHROPIC_*`, `GH_TOKEN`, …). The residual stays honest: files on disk remain readable until sandboxing.
    *   **(b) Re-scope only.** Split the risk into "workers can change files" (mitigated by verify and review) and "workers can read any file and the network" (unmitigated in v1, sandboxing first after v1).

    I'd do (a) plus the split from (b). Cleaning the environment is cheap, and it removes the easiest leak.

## 🟡 Major: PROPOSE FIX

*   **PF1. [`design_critic` M1] Orphaned live workers.** A worker can still be running after the session that launched it is gone. A new session leaves it alone, but nobody collects its result, so its slot stays taken.
    *   **Fix.** Reconcile treats a live worker whose `delegate.ps1` parent is gone as *watched*. When its run output appears, the task moves to `in-review`, and the new session runs `verify` and the review. A worker with no output for its full timeout (`-TimeoutSec`, 900 s by default) is killed and marked `failed`. `delegate.ps1` writes a `pid` file per run, so ownership can be checked.
*   **PF2. [`design_critic` M2] G4–G7 have no pass criteria.** Add one to each:
    *   **G4:** at sign-off, `git log main..feature/<name>` contains no commits by the lead except record commits, merges and `[fix-up]`-logged commits. A Pester test checks the commit classification.
    *   **G5:** the `schedule` overlap tests pass, and no two overlapping tasks are ever `running` together (asserted in `reconcile`).
    *   **G6:** the drift report's three lists are shown before the **signed-off** prompt, every time.
    *   **G7:** each trigger produces a `[council]` line. A council on consensus leads to a retry, and on disagreement to a `[stop]`.
*   **PF3. [`design_critic` M4] Two sessions on the same machine can race.** Two Claude sessions in one checkout could both schedule tasks (4 agents) or both write `feature.json`.
    *   **Fix.** `feature.ps1` takes an advisory lock, `.xagent/features/<name>/.lock` (holding a pid and a timestamp), for every command that writes. A lock held by a live process makes the command fail with "another session is working on this feature". A stale lock is taken over.
    *   **Non-Goals.** Say "one session at a time", not only "one machine".
*   **PF4. [`design_critic` M5 + `structural` #2] There's no scalability row.** Add a Risks row "Capacity":
    *   **The limits:** one active feature, 2 agents at a time, and about 5–10 features a month before the third-party pool runs out (then reviews fall back to Grok).
    *   **The unknown:** the Cursor pool per feature is not known, and gets measured on the first feature.
    *   **The mitigation:** pool cooldowns and the token display in `status`.
*   **PF5. [`design_critic` M6] "Conservative" 60-minute cooldown.** Reword to "an arbitrary retry point; the real reset window is unknown. The user can clear it early." Measure the real window when it first happens, and record it in `docs/test-plan.md`.
*   **PF6. [`style` 1] The council cost claim doesn't match the evidence.** "1–3 minutes" contradicts the measured 3–7 minutes per strong-tier lens. Reword to "a council runs two frontier seats, at about one judgement-lens run each, plus a second round when needed (measured 1–10 minutes per seat in this design's review)".
*   **PF7. [`style` 2, 3, 4, 5] Phrasing.**
    *   **#2:** "weaker" → "ran on a single model family instead of two".
    *   **#3:** drop the circular "small fix or real problem" clause.
    *   **#4:** H1's "strongest judgement, and tested isolation" → "frontier-model judgement; isolation built into EGM's Claude adapters".
    *   **#5:** drop "by choice, not because of a measured weakness", and keep "Revisit with benchmark data".

## 🟢 Nits: PROPOSE FIX

*   **PF8. [`design_critic` N1] Glob versus exact files.** Add one sentence: a glob blocks every task whose files sit under its folder, even if that task lists exact files.
*   **PF9. [`design_critic` M3 residual] A Risks row for the single-lens sign-off.** "Drift the `drift_report` lens misses is caught only if the user reads the diff. Second lens in Future Improvements."
*   **PF10. [`design_critic` N2] The task-id shortening rule.** Cut the feature part to 16 characters and the task part to fill the rest. On a collision, add `-2`, `-3`, and so on.
*   **PF11. [`design_critic` N3] Semantic breaks after `redo` reverts.** After the reverts, the last merged phase's test runs before the gate is recorded. A failure means the gate is not recorded.
*   **PF12. [`design_critic` N4] The review-round counter resets on local loss.** Record each failed review round as a committed `[round]` decision, so the council trigger survives a lost local file.
*   **PF13. [`design_critic` N6] The Problem names the user.** Add one sentence: "a single developer on Windows, with a Claude subscription and a Cursor subscription, who wants to take a feature to `main` without spending Claude quota on coding or review." It names no person.
*   **PF14. [`structural` 4, 5, 6] Headings and links.**
    *   **#4:** make "Merged work after going back", "Models per lens" and "Lens runs per review" H4 headings.
    *   **#5:** link `research.md#7-landscape-survey-similar-projects-2026-11-09`.
    *   **#6:** link `test-plan.md` T0 and the review folder.
*   **PF15. [`style` 7, 10]** Drop "and the simplest to write". Change "predictable" to "bounded".

## CONTEST / DECLINE

*   **CT1. [`style` 6] "The trickiest step".** The doc doesn't contain this phrase (`grep` finds nothing). The reviewer's own text shows it re-reading and failing to find it. Contested: it's a hallucinated citation.
*   **DC1. [`structural` 3] Rename H2s to the standard's labels** ("Problem Statement", "Proposed Architecture"). Declined: the headings follow EGM's own design-doc template (`references/design_doc.md`), which uses "The Problem" and "Technical Plan (Architecture)".
*   **DC2. [`design_critic` N5] An EGM sync stub now.** Declined: the author already chose the monthly check in round 1.

## Resolution (2026-11-10)

The author chose **auto accept**:
*   **X1** went as recommended: the worker's environment is cleaned of known secret variables, and the risk is split into "workers change files" (mitigated) and "workers can read files and reach the network" (unmitigated until sandboxing).
*   **PF1–PF15** were applied.
*   **CT1** stays contested. **DC1** and **DC2** stay declined.

Round 2 was not clean, so round 3 is next.
