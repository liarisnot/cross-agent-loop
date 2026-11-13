# Handoff: where we are (2026-11-11)

Start a new Claude Code session in `D:\cross-agent-loop` and read this file first.

## Done
- **The `delegate` skill** (the task-level loop). See `docs/test-plan.md` for every behaviour we've verified and every pitfall we've hit. **Its routing to agy must not be used** (see "Antigravity" below).
- **The `feature` skill design:** `docs/designs/feature-skill.md`, now locked (see below). Every report and resolution is in `docs/designs/reviews/feature-skill/`. Review history:
  - Stage 5 (plus re-audit), stage 6, stage 7 rounds 1–3, stage 8.
  - **Stage 7 rounds 4–5** (`8ddc6c3`, `72f8d69`). Round 5 still churned; accepted and moved on, per the EGM rules.
  - **Stage 8 re-run** (`27134f5`, `intermediate_zoom_out_report_r2.md`): "still the small version". One Major (two round counters) was fixed.
  - **Stage 9 round 1** (`f51998d`) and **round 2 re-audit** (`baa1646`, `implementation_readiness_report_r2.md`). Round 2 found 3 Blockers, 11 Majors and 5 Nits, all marked Fixed. Style found nothing above a Nit.
- **The landscape survey** is in `docs/research.md` §7. **Decision 001** (vendor EGM and track upstream) is in `docs/decisions/`.
- **Antigravity: no automation.** Checked 2026-11-10 (`docs/test-plan.md`, T0): Google's FAQ forbids wrapping `agy -p` inside third-party agents, Claude Code included, on consumer plans. The user doesn't want an API key.
- **All models now go through the Cursor CLI:**
  - workers: Composer 2.5, and Grok 4.7 high for `code-hard`;
  - judgement goldfish: Grok 4.7 medium and GLM 5.2 (`glm-5.2-high`);
  - readiness: DeepSeek V4.1 Flash (`deepseek-v41-flash-1017-medium`);
  - council: Grok and GLM.
- **The Cursor legacy Pro plan has two monthly pools:** Cursor Models (Grok, Composer) and Other Models (GLM, DeepSeek). On-demand spending is off. Rough rates are in `docs/test-plan.md`.

- **Focused r3 check of the `baa1646` fixes** (2026-11-11), two reviewers in parallel on the changed lines only:
  - **Stage 9 r3** (`fr-s9r3`, DeepSeek, `implementation_readiness_report_r3.md`): 3 Blockers, 9 Majors, 6 Nits. All fixed except M7 (`nextAction` table, left to the build) and M10 (retry ladder state; instead, the ladder restarts after a resume).
  - **Stage 8 r3** (`fr-s8r3`, Grok, `intermediate_zoom_out_report_r3.md`): still the small version. The build council was cut down to its differences from `delegate`, plus 3 Nits.
  - **Decision with the user: no round 4.** Each round found defects in the previous round's fixes. The rest is left for the Pester suite at build time.

- **Design locked** (Status: Approved, 2026-11-11). Last addition before the lock: a Future Improvements line saying the Claude Code advisor tool is an optional lead-session setting, never a review lens (same model family, full context).
  - **Settled list**, for any later triage: "Rejected by author", the heading names, the sync stub, the single-lens sign-off, the invented "trickiest step" citation, `agy.enabled` (kept), and IR r3 M7/M10. It stays in the lead's triage and is never given to reviewers.

- **Build step 1 done (2026-11-11): the `delegate` changes** (design items 13–17). `-Seat`, `-Feature`, `-Standard` (+ `personas/standards.json`), `-TargetFile`, `-KeepRuleFiles` (rule files removed at any depth in read-only runs, restored in `finally` and in `-Cleanup`), `baseSha` in the summary (`.xagent/base.sha` in the worktree), pid file, secret-env denylist, `agy` refused with the T0 reason, new `models.json` shape, `drift_report.md` persona, `feature-spec-standard.md`, SKILL.md rewritten. `runs.jsonl` moved to `%LOCALAPPDATA%\xagent\` (untracked, gitignored; `bench.py` reads it there).
  - **Regression (Verification Plan):** passed. Live: Grok and GLM judgement lenses with `-Standard`, DeepSeek readiness with `-TargetFile` (quoted the marker line), council seats grok+glm on one id with one cleanup, a Composer worker run. Offline with a fake Cursor CLI: rule-file removal/restore, `-KeepRuleFiles`, secret vars stripped, pid file live then gone, kill mid-run then `-Cleanup`, scoped cleanup never touches `<id>-pc-*`, `agy`/`auto` refused.
  - **Bug the regression caught (fixed):** strict mode broke on `.Count` when a repo has 0 or 1 rule files (PowerShell unrolls one-item arrays), in the `finally` block.

- **Build step 2, sub-steps 2.1–2.3 done (2026-11-11), every one through `delegate`** (the user's standing instruction: each build step dogfoods the skill; observations go in `docs/test-plan.md`, "Dogfooding `delegate`", D1–D15).
  - **2.1** `fb-schemas` (schemas, templates, fixtures, test helpers) and `fb-egm` (vendored EGM files, byte-identical to upstream `b7d9e27` as git blobs; `THIRD_PARTY_NOTICES.md`).
  - **2.2** `fb-core`: `feature.ps1` dispatcher plus `new`, `stage`, `gate`, `decision`, `reaudit`, `commit-design`, `commit-records`, `checkin`.
  - **2.3** `fb-plan`: `plan` and `schedule`. 108 Pester tests pass (full suite about 5 minutes).
  - **Loop per sub-step:** task file in `.xagent/tasks/`, comprehension (Composer) and readiness (DeepSeek) preflights, Composer worker, lead review (diff per file, tests rerun, probes in scratch repos), merge with `--no-ff`. Probes found 4 real bugs that green worker tests missed (D11, D14).
## Next
1. **Build steps 1-5 are done (2026-11-12).** Step 2 sub-steps 2.1-2.6 (`feature.ps1`, 200 Pester tests: full suite about 10 min, fast tier `ExcludeTag Slow` about 7 min), step 3 (vendored EGM), step 4 (router `skills/feature/SKILL.md` and `stages/*.md`, delegated at the user's request), step 5 (sandbox script and fixtures, test-plan `feature` section with the manual checklist, decision 001, README). `feature.ps1 doctor` reports ready on this machine.
2. **Step 6 done (2026-11-12):** results and findings S1-S7 in `docs/test-plan.md`, "Results, 2026-11-12: manual checklist (step 6)". Everything passed except CUJ 2's killed-worker part (partial) and the escalation council (not triggered). Next: fix S1, S3, S6, S7; S4 needs the user's choice.
3. **Machine setup done (2026-11-12):** junction `~/.claude/skills/feature` to `skills/feature`, and the `feature.ps1` allow rule (junction path) in `~/.claude/settings.json`. `doctor` reports ready through the junction.
4. **Design write-back (docs):** the task files added decisions the design doesn't have (D19): `reconcile`'s output `name` and `stop-not-recorded`, the non-empty `stdout.json` finished-run rule, the router's handling of entry rows without stage files, on-request council ids `<name12>-dc<k>`/`-pc<k>`. Fold them into `docs/designs/feature-skill.md` (a post-lock amendment the user should approve).
   - **Launch workers detached** (SKILL.md, D16); every step since 2.4 ran that way.

## How to run a review lens
- `pwsh -NoProfile -File skills/delegate/scripts/delegate.ps1 -Agent cursor -Profile review -Persona <lens> -Model <model> -Repo D:/cross-agent-loop -TaskId <id> -TaskFile <path>`
- **Give each reviewer its own `-TaskId`.** Two Cursor runs with the same id collide on one worktree.
- **Pass the doc by file path.** The worktree gets only committed files, so commit the doc before a run.
- **Standards:** the `implementation_readiness` persona appends its standard automatically. For `zoom_out`, paste `personas/zoom-out-standard.md` into the task file (see `fr-s8r3.md`).

## Open items
- **`benchmarks/runs.jsonl` is untracked now** (moved to `%LOCALAPPDATA%\xagent\` in build step 1). Its old lines are still in git history, so delete and recreate the GitHub repo before going public (below).
- **Worker sandboxing** (a restricted account or a VM) is the **high-priority first item after v1**. Workers run with `--force` and can read the machine's files.
- **Plugin packaging** comes after v1. The v1 install is a personal skill with no absolute paths (the design's Installation section).
- **Check upstream EGM monthly:** `git ls-remote https://github.com/google/elephant-goldfish-model HEAD` against `b7d9e27`.
- **Delete the local backup bundle** that still contains the pre-rewrite history with the email, once confident.
- **Before making the repo public,** delete and recreate the GitHub repo, so old commits aren't reachable by SHA.
- **First trial on a real repo** (for example MyApp), using `feature` once it's built.
