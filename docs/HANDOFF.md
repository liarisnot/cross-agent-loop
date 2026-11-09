# Handoff / where we are (2026-11-09)

Start a new Claude Code session in `D:\cross-agent-loop` and read this file first.

## Done
- `delegate` skill (task-level loop): profiles code / code-hard / review / council; Claude models and `auto` blocked; benchmark mode (off); goldfish preflight using vendored EGM personas. See `docs/test-plan.md` for every verified behaviour and pitfall.
- Permission rule in `~/.claude/settings.json`: `Bash(pwsh -NoProfile -File D:/cross-agent-loop/skills/delegate/scripts/delegate.ps1 *)`.
- Skill is linked into `~/.claude/skills/delegate` with a junction.
- Repo is Apache-2.0 with `NOTICE` and `THIRD_PARTY_NOTICES.md`. History was rewritten to remove a personal email (pushed 2026-11-09). Still private.
- **EGM plugin installed** (`egm@egm` 0.1.1, user scope). Its skills use the `/egm:` prefix: brainstorm, draft, review, resolve, review-loop, bootstrap, drift-report. Note: EGM's own goldfish reviewers are spawned as **Claude subagents** (the `Agent` tool), so they use the user's Claude quota, not Cursor/Google. Routing them through our cross-vendor `review` profile is a later option.

## Next: design the `feature` skill using EGM itself (dogfooding)
The user approved this plan:
1. `/egm:draft` → `docs/designs/feature-skill.md`, one section at a time with the user. Input is the proposal below.
2. `/egm:review` (5 goldfish stages), then `/egm:resolve` with the user. **The user locks the design.**
3. Build it, ideally delegating parts of the build through the `delegate` skill.

### Proposal to draft from
A user-friendly, end-to-end, feature-level flow on top of EGM and `delegate`. Plain-language entry points route to stages, and state lives on disk:

| User says | Runs | Gate |
|---|---|---|
| "brainstorm an idea about X" | egm-brainstorm (+ optional council) | user go/no-go |
| "start the design" | egm-draft | |
| "review the design" | egm-review + egm-resolve | **user locks design** |
| "plan it" | phases → tasks (deps, file boundaries, test plan) + implementation_readiness preflight | **user approves plan** |
| "build it" / "continue" | delegate phase by phase into `feature/<name>` branch; benchmark if on | check-in per phase |
| "test and sign off" | full tests + design_critic on whole diff + egm-drift-report | **user signs off** → merge main |
| "where are we?" | reads state | |

Missing pieces to design:
- the state file `.xagent/features/<name>/state.json` (stage, phases, tasks, status, branches, session ids, decisions), so the flow survives context compaction and new sessions;
- dependency-aware scheduling (parallel only when file sets don't overlap);
- a feature integration branch (delegate.ps1 `-Base feature/<name>` and merging into it);
- a final check against the design;
- routing EGM's goldfish through our cross-vendor `review` profile (optional, later).

## Open items
- Benchmark mode is **off**; `benchmarks/REPORT.md` has 0 real tasks (the sandbox trial is in `trial-records.jsonl`). The user turns it on per real work ("benchmark the next N tasks").
- The local backup bundle in the old session's scratchpad still contains the pre-rewrite history (with the email). Delete it once confident.
- Google ToS on automated `agy` use with a consumer Pro plan: unresolved (research.md §2).
- Before making the repo public: old commit SHAs may stay reachable on GitHub by direct URL until GitHub garbage-collects them. Safest is to delete and recreate the GitHub repo (or ask GitHub Support to purge) right before flipping to public.
- Background parallel runs (`run_in_background`) not yet tested.
- First real-repo trial (e.g. MyApp).
