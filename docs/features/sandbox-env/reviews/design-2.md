# Design review 2: sandbox-env, stages 5–9

Built from the raw reports in `reviews/raw/`:
- `sandbox-env-d2-zo-p5.md`, `sandbox-env-d2-ic-p5.md` (stage 5 re-check after round 1)
- `sandbox-env-d2-cm-p6.md` (comprehension)
- `sandbox-env-d2-dc-p7.md`, `sandbox-env-d2-st-p7.md`, `sandbox-env-d2-sy-p7.md` (critic, structure, style)
- `sandbox-env-d2-zo-p8.md` (intermediate zoom out)
- `sandbox-env-d2-ir-p9.md`, `sandbox-env-d2-cd-p9.md`, `sandbox-env-d2-sy-p9.md` (readiness, codebase details, style)

`sandbox-env-d2-zo-p5-r1` and `sandbox-env-d2-ic-p5-r1` were not run; the user waived them as duplicates (see `decisions.md`). The doc was updated after each stage; the last update is commit `e9bc9d1` plus the D8 wording fix in the same commit.

Each finding below was fixed in the doc or logged as a dismissal with its reason in `decisions.md`. The lead's triage of every finding is in `decisions.md`; this table lists what changed the design.

## What changed the design

| Stage | Lenses | Finding | Resolution |
|---|---|---|---|
| 5 | ZO | Environments followed the user's checkout, not the tree being run. | D8: environments are found by the identity hash at the commit being run. |
| 5 | ZO | Review lenses and council seats were linked and granted environments. | Only sandboxed worker runs and probes get them. |
| 5 | IC | A large rebuild ran on the first approval. | A build whose estimate is over 5 GB asks again. |
| 5 | IC | The probe reported a missing environment as a note. | It returns `environment-missing` and doesn't run. |
| 5 | IC | Index settings in `uv.toml` were left behind. | Builds copy all inputs from the ref. |
| 6 | CM | `-SandboxEnv` output had no shape; `environment-missing` missing from a list. | Output schema added; lists aligned. |
| 7 | DC, ST | No Risks and Mitigations section. | Added. |
| 7 | DC, SY | `ls-files` vs `ls-tree`; `.python-version` patch pins; unbacked claims. | Fixed and calibrated. |
| 8 | ZO (Blocker) | Pre-build runs of every phase test fail for unbuilt phases; real phase tests ran in the user's checkout. | **User decision:** a worker launch fails closed with `sandbox: environment not ready`; phase tests run in the sandbox through `-SandboxRun`. |
| 8 | ZO | Output scraped into a diagnosis enum. | `-SandboxRun` returns `ran`, `environment-missing` or `timeout`; the lead reads the output. |
| 9 | IR, CD | `install-failed` had no stored record; hash sources disagreed (checkout bytes vs `git show`); no exact `.pth` line; estimate factors open; `-SandboxRun` contract and steps open; module import cycle; ref for `-Apply` unclear; `envs.json` reads racing writes; gate after worktree creation; `-NoSandbox` would fail closed; the "never retry `sandbox:`" rule conflicted; doctor mechanism open; no recovery for a wrong environment. | All specified: the identity hash from git blob ids, a `failed` map, an atomic write, the gate before `git worktree add`, the exact `.pth` line, the estimate formula, the `-SandboxRun` schema and steps, a one-way module import, `-Base feature/<name>`, `-NoSandbox` skipping the gate, the retry exception, doctor in-process, `-Rebuild`. |
| 9 | IR, CD | No phases in the design. | Dismissed: the plan stage makes phases. |

## Left for the user to know

- Task acceptance tests (`feature.ps1`'s task `test`) still run on the host in the worker's worktree. Only phase tests move into the sandbox in v1. Listed under Risks.
- Every lens run's cleanup failed with "Filename too long" because Cursor updates itself inside the run home. Each was removed with `core.longpaths` and a `\\?\` delete. To be added to `docs/HANDOFF.md` as a `worker-sandbox` follow-up.
- The review tracker started a new round when the round-1 summary was committed mid-round, then added duplicate stage-5 runs on re-audit. To be added to `docs/HANDOFF.md` as a `feature` bug.
