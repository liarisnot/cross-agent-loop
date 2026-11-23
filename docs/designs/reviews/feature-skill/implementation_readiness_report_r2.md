# Stage 9 re-audit (implementation readiness), round 2

**Target:** the Detailed Implementation Plan at `6e227e5` (lines 673–1190). Raw reports are in `.xagent/runs/fr-s9r2-{ir,sy,cd,cd2}/`.

| Lens | Model | Time | Result |
|---|---|---|---|
| `implementation_readiness` (IR) | DeepSeek V4.1 Flash | 261 s | 3 Blockers, 11 Majors, 5 Nits |
| `style` (SY) | GLM 5.2 | 44 s | No Blocker or Major, 4 Nits |
| `codebase_details` (CD) | Grok 4.7 medium | 901 s | **Timed out** at the 900 s default with no report. Retried once as `fr-s9r2-cd2` with `-TimeoutSec 1800` (the failed-reviewer rule) |

## IR findings and resolutions

| # | Sev | Finding | Resolution |
|---|---|---|---|
| 1 | Blocker | `finish` writes `done` on `main`, but the feature list reads the branch tip, so `new` refuses forever | **Fixed.** `done` is derived (the branch is an ancestor of `main` and `signed-off` is recorded), never stored. The reconcile row, the listing rule, `finish` and the schema are updated |
| 2 | Blocker | Suffixed ids (`-r2`, `-c<k>`, `-pre-<lens>`) can exceed 49 characters | **Fixed.** One id scheme with a length budget: `<name12>`, task ids of at most 20, short suffixes (`-pc`, `-pr`, `-c<k>`) and two-letter lens codes. A test checks the worst case |
| 3 | Blocker | `zoom_out` and `style` run twice per design review and get the same id. `lensesMissing` has no expected set | **Fixed.** Lens ids include the EGM phase (`-p5`/`-p8`). `feature.ps1` holds the lens table as data and returns `status.reviewRuns` with model, standard and `done`. The new `reaudit` subcommand and decision kind record re-audits |
| 4 | Major | Cleanup calls omit `-Repo` | **Fixed** everywhere, plus a router rule |
| 5 | Major | Build-council procedure undefined | **Fixed.** A cut-down procedure: neutral question file, lead position first, round 1, round 2 only on differing fixes, a consensus definition, and the cleanup |
| 6 | Major | Fix-up counts have no baseline | **Fixed.** `git add -A` the worker's work first, so `diff --shortstat` shows only the lead's edit |
| 7 | Major | Schema dialect and validator unnamed, and `$defs` fragments can't be selected | **Fixed.** Draft 2020-12, one file per object under `skills/feature/schemas/`, no cross-file `$ref`, `Test-Json -SchemaFile` (JsonSchema.Net on PowerShell 7.4+, checked: 7.6.10 here) |
| 8 | Major | Only `schedule` enforces the cap | **Fixed.** A router cap rule for every non-`schedule` run |
| 9 | Major | No worker task-file or delta-brief template | **Fixed.** `templates/task.md` (item 11), with `files` and `test` copied exactly |
| 10 | Major | Fixture test command and paths unnamed, and Python not checked | **Fixed.** `python -m unittest -q` for the manual sandbox (Python optional in `doctor`). Pester uses PowerShell one-liners. Fixture paths listed |
| 11 | Major | The 15-minute timeout makes the timeout test take 15 minutes | **Fixed.** `XAGENT_VERIFY_TIMEOUT_SEC` |
| 12 | Major | The pid file can't find an orphaned worker | **Fixed.** The pid file records the child pid and its start time. Reconcile kills only that process tree |
| 13 | Major | Status fields have no derivation or tests | **Fixed.** Derivations for `reviewRuns`, the review number, `diffTouchesRuleFiles` (the path list), `lastDecisions`, `phase: null` and `nextAction`, plus tests |
| 14 | Major | How `models.json` is found and looked up | **Fixed.** `$PSScriptRoot/../../delegate/`, `profiles.<p>.model`, seats feed `reviewRuns`, `doctor` checks it, and `_comment` is rewritten |
| 15 | Nit | Re-plan "unchanged" is unclear | **Fixed.** Every field equal, and `delegateTaskId` kept |
| 16 | Nit | `drift_report` has no standard, and the failed-reviewer sequence was compressed | **Fixed** |
| 17 | Nit | The `runs.jsonl` move leaves a working copy | **Fixed.** Delete it, in the same commit as the log-path change |
| 18 | Nit | `nextAction` and the `decisions.md` header are unspecified | **Fixed.** A fixed table keyed by stage and `waitingOn`, and the header text in item 11 |
| 19 | Nit | Item 24 is in the build order | **Fixed.** It's a gate action, not a build step |

## SY findings

1 (cite where the marker forms were seen): **fixed**. 2, 3, 4: no action (the comparison is load-bearing, the caveat is KEEP, and the parallelism change is cosmetic).
