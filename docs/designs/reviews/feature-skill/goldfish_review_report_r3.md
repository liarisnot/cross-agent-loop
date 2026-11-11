# Goldfish review report: Stage 7 (Critic Review), round 3

**Target:** `docs/designs/feature-skill.md` at `e93a74c`, FeatureRange lines 1–682. Raw reports are in `.xagent/runs/fr-s7r3-{dc,st,sy}/`.

| Lens | Model | Result |
|---|---|---|
| `structural` | GLM 5.2 | PASS, 4 Nits |
| `style` | GLM 5.2 | 16 Nits, no Blocker or Major |
| `design_critic` | Grok 4.7 high | 2 Blockers, 10 Majors, 2 Nits |

**Round status: not clean.**

## Churn detected (EGM loop rule)

Several new findings sit exactly at the scope of fixes applied in earlier rounds. Reverting or simplifying those fixes would resolve them, and EGM calls that churn:

*   **DC1 (Blocker):** the G4 pass test (added in round 2) can't pass, because "record commit" is undefined and the lead commits each task's worktree before merging. It also doesn't cover conflict resolutions.
*   **DC7:** the session lock and the pid-file "exact" checks (added in round 2) can be fooled by pid reuse on Windows, and leave a gap between taking the lock and launching.
*   **DC8:** the token total keyed on a `<name>-` prefix (added for E3 in round 1) breaks with shortened ids and same-prefix feature names.
*   **DC4:** a `failed` task (from F1 in round 1) is rescheduled endlessly. There is no crash budget.

## Other new findings (valid, not churn)

*   **DC2 (Blocker): gates aren't bound to what they approve.**
    *   `signed-off` stores no commit SHA. Commits that land after the approval, or while resolving a conflict, merge under the old approval.
    *   `design-locked` doesn't pin the design file, so the drift check can run against an edited design.
*   **DC3: the quota model isn't measured.**
    *   Which pool bills which model, the prices, and how a usage-limit error looks are all unverified.
    *   `delegate.ps1` can't detect a limit yet.
    *   The Grok fallback assumes Grok isn't billed from the third-party pool.
    *   The per-task GLM diff reviews are missing from the cost estimate.
*   **DC5: re-plan gaps.**
    *   A plan that omits a merged task must be rejected.
    *   Every kept phase's test should run, not only the last.
*   **DC6: declared paths versus actual writes.**
    *   Two tasks can both touch an undeclared shared file, such as a lockfile.
    *   Paths must be compared case-insensitively.
*   **DC9: the drift check can read the diff truncated and report "no drift".**
    *   It needs per-file coverage, and a rule that an empty report on a non-empty diff is a failure.
*   **DC10: `delegate`'s own SKILL.md still describes agy council seats and failover between vendors.**
    *   The v1 change list must rewrite those parts, not just disable agy.
*   **DC12: the rules for the feature name are unspecified** in the Technical Plan: the grammar, collisions with abandoned features, and reuse of a name.
*   **DC13 (Nit):** the denylist misses `CURSOR_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_APPLICATION_CREDENTIALS` and `DATABASE_URL`.
*   **DC14 (Nit):** "Open Questions: none" is untrue. The pool facts are unverified.

## Settled (not reopened)

*   **DC11:** "Rejected by author" without a link. Settled as C1 in round 1. This is the third time a reviewer has raised it.
