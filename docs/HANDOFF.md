# Handoff: where we are (2026-11-11)

Start a new Claude Code session in `D:\cross-agent-loop` and read this file first.

## Done
- **The `delegate` skill** (the task-level loop). See `docs/test-plan.md` for every behaviour we've verified and every pitfall we've hit. **Its routing to agy must not be used** (see "Antigravity" below).
- **The `feature` skill design:** `docs/designs/feature-skill.md`, status still In Review. Every report and resolution is in `docs/designs/reviews/feature-skill/`. Review history:
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

## Next
1. **The user locks the design** (Status: Approved). That's the only step left before the build.
   - **Keep the settled list** for any later review triage: "Rejected by author", the heading names, the sync stub, the single-lens sign-off, the invented "trickiest step" citation, `agy.enabled` (kept), and IR r3 M7/M10. It stays in the lead's triage and is never given to reviewers.
2. **Build it**, in the order the design gives:
   - **Step 1: the `delegate` changes.** The vendored EGM personas are already committed, and listed in `THIRD_PARTY_NOTICES.md`.
   - **Step 2 onward:** delegate parts of the build where it makes sense.

## How to run a review lens
- `pwsh -NoProfile -File skills/delegate/scripts/delegate.ps1 -Agent cursor -Profile review -Persona <lens> -Model <model> -Repo D:/cross-agent-loop -TaskId <id> -TaskFile <path>`
- **Give each reviewer its own `-TaskId`.** Two Cursor runs with the same id collide on one worktree.
- **Pass the doc by file path.** The worktree gets only committed files, so commit the doc before a run.
- **Standards:** the `implementation_readiness` persona appends its standard automatically. For `zoom_out`, paste `personas/zoom-out-standard.md` into the task file (see `fr-s8r3.md`).

## Open items
- **`benchmarks/runs.jsonl` is still tracked.** It has uncommitted lines now. The design moves it to `%LOCALAPPDATA%\xagent\` in build step 1. Until then, don't commit runs from private repos.
- **Worker sandboxing** (a restricted account or a VM) is the **high-priority first item after v1**. Workers run with `--force` and can read the machine's files.
- **Plugin packaging** comes after v1. The v1 install is a personal skill with no absolute paths (the design's Installation section).
- **Check upstream EGM monthly:** `git ls-remote https://github.com/google/elephant-goldfish-model HEAD` against `b7d9e27`.
- **Delete the local backup bundle** that still contains the pre-rewrite history with the email, once confident.
- **Before making the repo public,** delete and recreate the GitHub repo, so old commits aren't reachable by SHA.
- **First trial on a real repo** (for example MyApp), using `feature` once it's built.
