# Goldfish review report: Stage 7 (Critic Review), round 4

**Target:** `docs/designs/feature-skill.md` at `67d1c75`, FeatureRange lines 1–668. Raw reports are in `.xagent/runs/fr-s7r4-{dc,st,sy}/`.

This is round 1 of a new convergence count (clean = no Blocker or Major left after triage; 2 clean rounds in a row, cap 5).

| Lens | Model | Time | Result |
|---|---|---|---|
| `design_critic` | GLM 5.2 | 98 s | 8 Majors, 8 Nits. Verdict: passes the standard |
| `structural` | Grok 4.7 medium | 389 s | 1 Major (settled), 5 Nits |
| `style` | GLM 5.2 | 57 s | 4 Majors, about 8 Nits |

**Round status: not clean.** Six Majors survive triage. All are one- or two-sentence clarifications, and none adds mechanism except where marked **decision**.

## Majors that survive triage

*   **DC-M1. The 2-agent cap's scope is unclear.** Line 339 sits under Build scheduling, but its text counts review lenses. Say whether it also limits design-review and plan-review lens runs.
*   **DC-M7 (decision). No policy for keeping `feature/<name>` current with `main`.** Choose between letting the branch diverge until sign-off, or allowing a `git merge main` into the feature branch (by the user or at a phase boundary) and re-running the phase test.
*   **DC-M8. A "not run" lens has no effect on the gate.** Say that a lens recorded as **not run** blocks the next gate until it is rerun or the user waives it, logged as `[dismiss]`. This also covers the empty-report half of DC-M3 at sign-off, since the failed-reviewer rule already applies to the sign-off check (line 414).
*   **DC-M4. Usage-limit detection is unspecified.** Nobody has seen a real Cursor usage-limit error yet, and `delegate.ps1` doesn't classify one. Proposed fix: say the matcher is built from the first observed error, and that until then an unclassified failure follows the normal failed-run path (a second failure is a problem stop). Downgrade to a note if accepted.
*   **SY-2. The NFR figure "3–7 minutes and 80k–160k tokens" matches neither model.** Measured (`docs/test-plan.md`): GLM 49–98 s and 32k–89k tokens excluding cache reads; Grok 389–632 s and 86k–176k. Split it per model and state that cache reads are excluded.
*   **DC-M5 (decision). Fix-ups have no auditable size.** The "judgement, not a cap" rule is the author's choice and stays. The cheap option: `[fix-up]` lines record the file and line counts, so a large one is visible at sign-off.

## Downgraded to Nit (fix in the same edit)

*   **DC-M2.** The council cap is per task for its lifetime. Add "never reset" next to "the round count starts again from 0".
*   **DC-M3 (size half).** The single drift lens on a very large diff. YAGNI for v1; note it in the risk row's "What remains".
*   **DC-M6.** Sandboxing is already listed as unmitigated. Add one sentence: the env-var denylist is best effort (`~/.aws/credentials`, `~/.npmrc` and similar stay readable).
*   **SY-1.** Recovering compressed diffs with `headroom_retrieve` is untested (T6 open). Say so.
*   **DC-N4.** Junction-installed skills: a feature that edits `skills/feature/` or `skills/delegate/` changes the running skill. Note it for this repo's own use.
*   **DC-N5.** "Alternating" in the models-per-lens table should say "assigned per phase (see the next table)".
*   **ST-4.** The `Profile` bullet (line 350) is misplaced, and has no blank line before `#### Task preflight`.
*   **ST-5.** Line 513's "research §7" link lacks the `#7-…` fragment.

## Dismissed

*   **ST-1, DC-N1: "Rejected by author" without a link.** Settled (C1, round 1). This is the fourth round to raise it.
*   **DC-N7: `doctor` should run `git ls-remote`.** The sync stub is settled.
*   **SY-3: "about 130 a month".** It is plain arithmetic on the per-run rate, and the row already says the rates are rough.
*   **SY-4: "1–10 minutes per seat".** It matches the measured lens times (49–632 s).
*   **SY-15: "Rough rates" stated twice, citing line 349.** No such text at line 349. Invented citation.
*   **DC-N2 (atomic `state.json` write), DC-N3 (concurrent `runs.jsonl` appends).** Implementation details for the build, not design gaps.
*   **DC-N6 (quantitative targets), DC-N8 (CUJ for starting a second feature), ST-2/3/6 (labels and heading names).** Low value. The heading names are settled.
*   Remaining style Nits (5, 7, 9, 11, 13): wording preferences, not applied.
