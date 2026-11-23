# Stage 9 (implementation readiness) report

**Target:** `docs/designs/feature-skill.md` at `43033eb`, the Detailed Implementation Plan (lines 671–1069), with lines 1–670 as context. Raw reports: `.xagent/runs/fr-s9-{ir,cd,sy}/`.

| Lens | Model | Time | Raw count |
|---|---|---|---|
| `implementation_readiness` (IR) | DeepSeek V4.1 Flash | 99 s | 9 Blockers, 17 Majors, 8 Nits. Verdict: not ready |
| `codebase_details` (CD) | Grok 4.7 medium | 827 s | 3 Blockers, 25 Majors, 7 Nits |
| `style` (SY) | GLM 5.2 | 68 s | 3 Majors, 5 Nits |

Many findings overlap. Grouped and deduplicated below. Quotes and repo claims were spot-checked: `sandbox/` is gitignored and untracked, `delegate.ps1`'s `usage.total` leaves out `cacheRead`, the worktree suffix is `$TaskId-$Agent`, and `.gitignore` handling of `records.jsonl` is as reported.

## A. Contradictions and bugs (the plan as written would not work)

| Id | Finding | Fix |
|---|---|---|
| IR1 | `design-locked` records the design blob, then the next step edits `Status:`, so `finish` always refuses | Set `Status: Approved` and commit first, then record the gate |
| CD2 | `-Repo` is mandatory, but the router calls `status -Cwd` and `reconcile` without it | `-Repo` defaults to `git -C <Cwd> rev-parse --show-toplevel` |
| IR9, CD3 | `new-sandbox.ps1` copies the gitignored `sandbox/`, which a fresh clone doesn't have | Commit `calc.py` and `test_calc.py` as `skills/feature/tests/fixtures/sandbox/` and copy from there |
| IR3, CD18 | Review targets (the diff file, `plan.md`) live outside the read-only worktree, and nothing copies them in | `delegate.ps1 -TargetFile <path>[,<path>]` copies each into the worktree's `.xagent/` and names them in the prompt |
| IR4, CD15 | `verify` has no defined base or worktree path | `state.json` records `baseSha` and `worktree` per task (from `delegate.ps1`'s output) |
| IR5, CD13 | No owner for building the `delegate` task id | The plan stores the short task part. `feature.ps1` composes `<feature16>-<task>`, adds the collision suffix, and returns it from `schedule` |
| IR6, CD4 | Item 14 drops `-Feature`, and `usage.total` leaves out cache reads | Add `-Feature`. The token sum adds `cacheRead`. Add an `XAGENT_LOG_DIR` override so tests can use a fixture log |
| IR7, CD26 | The cap of 2 has no data source for lens and council runs | Count live pid files (item 14) for the feature |
| CD1 | "Exit 1 with `{ok:false}`, like `delegate.ps1`" is wrong. `delegate` exits 0 with `ok:false` for a failed run | Exit 1 only for a script error. `verify` reports a failing test as exit 0 with `passed:false` |
| CD5 | `-Seat` doesn't change the worktree suffix or the cleanup loop, and the `models.json` shape is undefined | The suffix is `-<Seat ?? Agent>`, and cleanup globs `<TaskId>-*`. Give the JSON shape |
| CD6 | `structural`, `design_critic` and `codebase_details` need a standard, and `zoom_out.md` opens a path that doesn't exist here | `standards.json` maps every persona that needs one. The appended text says the standard is included below |
| CD7, SY1 | Sign-off and the regression use Grok 4.7 **high** for judgement lenses, but the design says medium | Use `grok-4.7-medium` |
| CD8 | The build stage needs a usage-limit detector that the design says v1 lacks | Copy the design's wording |
| CD9 | `new` writes check-ins "off", which isn't a schema value | Use `on-problems` |
| CD10, IR20 | The required plan fields make `new` fail, and `designDoc` is never set | Plan fields are optional, and `new` sets `designDoc` |
| CD11, IR11 | No decision-line format, so per-task round counts can't be parsed. The stage file omits the reset | `[round]`/`[council]`/`[fix-up]`/`[dismiss]` text starts with `<task id or lens>:`. State the reset |
| CD14 | Overlap keys and scope matching use different glob rules, and one helper would blur them | Two named rules, and the test cases say which one applies |
| CD16 | `__pycache__` and similar test outputs would count as out of scope | Untracked files come from `git ls-files --others --exclude-standard` |
| CD17 | The re-plan check must read the trailers, not `state.json` | State it |
| CD19 | Sign-off doesn't check for a clean tree before testing, and the full test command is unnamed | Check first. The command is the last phase's `test` |
| CD20, IR12 | The plan review doesn't commit raw reports, write a synthesis, or log dismissals | Same rules as the design review, with lens ids `<name>-plan<n>-<lens>` and target `plan.md` |
| CD21 | Wrong synthesizer path | `skills/feature/egm/agents/synthesizer.md` |
| CD22 | Ignoring `benchmarks/*.jsonl` also drops `records.jsonl` | Ignore only `runs.jsonl` |
| CD27 | The build stage has no fallback for compressed diffs | List the three marker forms and say to read smaller ranges |
| SY2 | The "Record commits stage only…" sentence doesn't parse | Rewrite it |
| SY3, CD28, CD29, IR26 | "Add" for personas that are already committed, and "Create" for this doc | Say "Keep", and give item 24 the right verb |

## B. Gaps an implementer would have to decide (the contracts)

IR8 (the `plan.md` layout), IR10 (the JSON output of `status`, `schedule` and `verify`), IR15 (the delta-brief mechanics), IR16 (where fix-ups are made), IR17 (resume sets the task back to `pending`), IR18 (folder paths need a trailing `/`), IR19 (how features are listed), IR21 (the EGM source and the 5 standards' names), IR22 (a test command for each build step), IR24 (test gaps), IR25 and CD30 (the Pester floor), CD12 (lock details), CD31 (`^auto$` stays blocked), CD32 (`doctor` checks the real cursor-agent path), CD33 (untracked files and "clean"), IR33 (lens worktree cleanup).

## C. Needs a decision

*   **CD23: benchmark mode.** With agy disabled, `delegate`'s head-to-head benchmark has no second worker, but the design says it still works.
*   **IR23: deriving the feature name.** The proposal is that the lead proposes a name and the user confirms it.

## D. Docs drift

CD24 (README still describes Antigravity and leaves T0 unchecked), CD25 (`SKILL.md`'s `-Persona` list), CD35 (the decision 001 attribution sentence), IR30 (the `git rm --cached` command), IR32 (the junction command).

## Outcome (2026-11-10)

Decisions by the author:
*   **CD23:** benchmark mode is unavailable in v1, in `delegate` as well (Non-Goals, item 16).
*   **Section B:** the contracts are pinned in the plan now, not deferred to the build.
*   **IR23:** the lead proposes a name and the user confirms it (CUJ 1, item 2).

Applied:
*   **Sections A, B and D**, by rewriting items 2–25, the build order and the verification plan.
*   **New contracts:**
    *   `-Standard`, `-TargetFile` and `baseSha` in `delegate`;
    *   `commit-design` and `commit-records`;
    *   the `$defs/status`, `$defs/schedule` and `$defs/verify` outputs;
    *   the decision-line prefixes, the path rules, the `plan.md` layout and the `models.json` shape;
    *   the sandbox fixture under `skills/feature/tests/fixtures/`.
*   **`feature-spec-standard.md`** is added to the personas, because `design_critic` and `structural` need it.

Per the design ("each re-audit after 'update the doc first' reruns that phase's lenses once"), stage 9 re-runs once on the revised plan.
