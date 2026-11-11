# Handoff: where we are (2026-11-10)

Start a new Claude Code session in `D:\cross-agent-loop` and read this file first.

## Done
- **The `delegate` skill** (the task-level loop). See `docs/test-plan.md` for every behaviour we've verified and every pitfall we've hit. **Its routing to agy must not be used** (see "Antigravity" below).
- **The `feature` skill design:** `docs/designs/feature-skill.md`, status In Review.
  - It was drafted with EGM, then reviewed: stage 5 (plus its re-audit), stage 6, stage 7 rounds 1–3, and stage 8.
  - Every report and resolution is in `docs/designs/reviews/feature-skill/`.
- **The landscape survey** is in `docs/research.md` §7. **Decision 001** (vendor EGM and track upstream) is in `docs/decisions/`.
- **Antigravity: no automation.** Checked 2026-11-10 (`docs/test-plan.md`, T0): Google's FAQ forbids wrapping `agy -p` inside third-party agents, Claude Code included, on consumer plans. The user doesn't want an API key.
- **All models now go through the Cursor CLI:**
  - workers: Composer 2.5, and Grok 4.7 high for `code-hard`;
  - judgement goldfish: Grok 4.7 medium and GLM 5.2 (`glm-5.2-high`);
  - readiness: DeepSeek V4.1 Flash;
  - council: Grok and GLM.
- **The Cursor legacy Pro plan has two monthly pools:** Cursor Models (Grok, Composer) and Other Models (GLM, DeepSeek). On-demand spending is off. Rough rates are in `docs/test-plan.md`.

## Next
1. **Stage 9 (implementation readiness)** on the Detailed Implementation Plan. Per the design's lens table, it runs `implementation_readiness` on DeepSeek V4.1 Flash, `codebase_details` on Grok 4.7 medium, and `style` on GLM 5.2.
   - Run each reviewer with its own `-TaskId`, because two Cursor runs with the same id collide on one worktree.
   - Pass the doc by file path. Task-file templates are in `.xagent/tasks/fr-s8.md`.
2. **Resolve the findings with the user, then the user locks the design** (Status: Approved).
3. **Build it**, in the order the design gives:
   - **Step 1: the `delegate` changes.** The six personas copied for this review are already committed, and listed in `THIRD_PARTY_NOTICES.md`.
   - **Step 2 onward:** delegate parts of the build where it makes sense.
4. **Since the vendor change, the stage 7 critic hasn't run on a clean round.** It ended at "accept and proceed" because of churn, and stage 8 then cut that machinery. Recommended: a fresh stage 7 pass **before** stage 9:
   - **Start a new convergence count**: 2 clean rounds in a row, with a cap of 5.
   - **Keep the settled list:** "Rejected by author", the heading names, the sync stub, the single-lens sign-off, and the invented "trickiest step" citation. It stays in the lead's triage and is never given to reviewers.
   - **Re-measure FeatureRange.** The `## Detailed Implementation Plan` heading moved, so the old `fr-s7r3-*.md` task files say lines 1–682, which is stale.
   - **Use new task ids** (`fr-s7r4-dc`, `-st`, `-sy`).
   - **Seats:** `design_critic` and `style` on GLM 5.2, and `structural` on `grok-4.7-medium`.
   - **If the pass edits the doc,** re-run stage 8 once before stage 9.

## Open items
- **`benchmarks/runs.jsonl` is still tracked.** The design moves it to `%LOCALAPPDATA%\xagent\` in build step 1. Until then, don't commit runs from private repos.
- **Worker sandboxing** (a restricted account or a VM) is the **high-priority first item after v1**. Workers run with `--force` and can read the machine's files.
- **Plugin packaging** comes after v1. The v1 install is a personal skill with no absolute paths (the design's Installation section).
- **Check upstream EGM monthly:** `git ls-remote https://github.com/google/elephant-goldfish-model HEAD` against `b7d9e27`.
- **Delete the local backup bundle** that still contains the pre-rewrite history with the email, once confident.
- **Before making the repo public,** delete and recreate the GitHub repo, so old commits aren't reachable by SHA.
- **First trial on a real repo** (for example MyApp), using `feature` once it's built.
