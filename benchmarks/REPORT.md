# Usage report: delegate runs in this repo
_Generated 2026-11-25 by `python benchmarks/bench.py usage` from 293 runs, 2026-11-09 to 2026-11-22._

Every `delegate.ps1` run appends one line (model, profile, feature, seconds, tokens, exit code) to a log outside the repo. This report totals the runs made while building this repo, plus the throwaway test repos its checklists create. Runs in any other repo are left out.

A clean exit means the run finished; it says nothing about the quality of the result. Review rounds and the bugs the lead found are written up in `docs/test-plan.md` (the "Dogfooding `delegate`" rows and the manual checklist results).

## By feature

Runs from before the `feature` skill existed (its own design reviews and build) and one-off fixes carry no feature name. In this repo's history, `subtract-divide` and `power-and-mean` were throwaway sandbox repos for the `feature` manual checklist (2026-11-12), and `regress` and `feature` were the regression checks of build step 1 (2026-11-11).

| | runs | clean exits | timeouts | wall hours | median minutes | tokens excl. cache (M) | cache reads (M) |
|---|---|---|---|---|---|---|---|
| (no feature: `delegate` used directly) | 104 | 101 | 3 | 8.6 | 1.5 | 11.93 | 59.5 |
| `worker-sandbox` | 80 | 78 | 1 | 8.3 | 2.5 | 13.37 | 72.0 |
| `sandbox-env` | 47 | 46 | 0 | 4.2 | 2.3 | 11.27 | 77.8 |
| `sandbox-verify` | 27 | 27 | 0 | 2.6 | 3.8 | 4.94 | 26.9 |
| `subtract-divide` | 18 | 18 | 0 | 0.5 | 0.7 | 0.70 | 1.3 |
| `power-and-mean` | 11 | 11 | 0 | 0.2 | 0.7 | 0.49 | 1.0 |
| `regress` | 4 | 4 | 0 | 0.0 | 0.3 | 0.06 | 0.1 |
| `feature` | 2 | 2 | 0 | 0.0 | 1.5 | 0.19 | 0.9 |

## By model and role

Role is the `delegate` profile: `code` and `code-hard` write code; `review` is a read-only lens or preflight; `council` is one council seat.

| | runs | clean exits | timeouts | wall hours | median minutes | tokens excl. cache (M) | cache reads (M) |
|---|---|---|---|---|---|---|---|
| deepseek-v41-flash-1017-medium (review) | 65 | 65 | 0 | 4.4 | 2.8 | 17.80 | 67.3 |
| composer-2.5 (review) | 63 | 63 | 0 | 0.7 | 0.7 | 2.76 | 11.0 |
| composer-2.5 (code) | 58 | 56 | 1 | 7.3 | 3.4 | 9.51 | 88.0 |
| grok-4.7-medium (review) | 36 | 34 | 1 | 4.0 | 6.3 | 5.13 | 19.0 |
| glm-5.2-high (review) | 33 | 33 | 0 | 0.6 | 0.9 | 1.48 | 8.9 |
| grok-4.7-high (code-hard) | 12 | 11 | 1 | 5.0 | 20.0 | 3.39 | 34.0 |
| grok-4.7-high (review) | 8 | 7 | 1 | 1.3 | 9.5 | 1.15 | 1.1 |
| gemini-3.8-flash-medium (review) | 5 | 5 | 0 | 0.0 | 0.1 | 0.12 | 0.0 |
| gemini-4-argon-high (review) | 4 | 4 | 0 | 0.2 | 3.5 | 0.35 | 0.5 |
| glm-5.2-high (council) | 3 | 3 | 0 | 0.0 | 0.5 | 0.03 | 0.1 |
| grok-4.7-high (council) | 3 | 3 | 0 | 0.2 | 3.5 | 0.28 | 0.3 |
| gemini-3.8-flash-low (council) | 1 | 1 | 0 | 0.0 | 0.2 | 0.02 | 0.0 |
| gemini-3.8-flash-medium (code) | 1 | 1 | 0 | 0.0 | 1.0 | 0.18 | 0.0 |
| grok-4.7-high (code) | 1 | 1 | 0 | 0.6 | 36.1 | 0.75 | 9.3 |

## Sandboxed or not

The worker sandbox became the default on 2026-11-16.

| | runs | clean exits | timeouts | wall hours | median minutes | tokens excl. cache (M) | cache reads (M) |
|---|---|---|---|---|---|---|---|
| no sandbox | 183 | 179 | 4 | 15.4 | 1.4 | 22.82 | 110.7 |
| AppContainer sandbox | 110 | 108 | 0 | 9.1 | 1.7 | 20.13 | 128.7 |

## Notes

- Tokens are as the Cursor CLI reports them. Cache reads are listed apart because they are usually billed or rate-limited lower.
- The plans are flat-rate subscriptions, so there is no dollar cost per run; tokens and wall time are the cost measures.
- `agy` rows are trial runs from before the Antigravity policy check (`docs/test-plan.md`, T0).
