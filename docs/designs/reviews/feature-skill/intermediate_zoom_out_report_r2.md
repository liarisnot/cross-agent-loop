# Intermediate zoom-out (stage 8), re-run after stage 7 rounds 4–5

**Target:** `docs/designs/feature-skill.md` at `72f8d69`, full file. `zoom_out` on Grok 4.7 medium, 413 s. Raw report: `.xagent/runs/fr-s8r2/`.

**Verdict:** the design is still the small version. The stage 5 and first stage 8 cuts hold. Rounds 4–5 added sentences, not machinery (the `main` merge on request, blocking a lens that didn't run, fix-up counts, gate SHAs, the cap counting every run, and token use including cache reads). Keep them.

## Resolutions

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Major | Two round counters: local `round` in `state.json` / `task -Round`, plus committed `[round]` lines. Append-only lines can't "start again from 0" | **Fixed.** One counter: a task's `[round]` lines since its latest `[council]`. `round` was removed from `state.json`, `task -Round` and `state.schema.json`. The G1 cons and the risk row now say only session ids are local-only |
| 2 | Nit | `agy.enabled` flag for a provider v1 never calls | **Kept.** The author chose this earlier, to keep a path open for an API-key setup |
| 3 | Nit | The usage-limit "looks like one" wording and a future matcher bring a detector back | **Fixed.** A reported usage limit is a stop, and everything else takes the normal failed-run path. The matcher is added after a real error |
| 4 | Nit | The `scope` decision kind has no writer | **Fixed.** Removed |
| 5 | Nit | The Deploying non-goal still lets the lead deploy with approval | **Kept.** This is the author's earlier choice; it only allows a user-approved one-off step and adds no stage |
| 6 | Nit | `sandbox/calc.py` doesn't exist | **Dismissed.** It does exist (`sandbox/calc.py`, `sandbox/test_calc.py`) |
