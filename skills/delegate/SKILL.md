---
name: delegate
description: Delegate coding subtasks from Claude Code (as lead programmer) to Cursor CLI or Google Antigravity CLI worker agents running locally in isolated git worktrees, then review, iterate and merge their work; or convene a read-only multi-model council (Grok + Gemini + Claude) on a design decision and escalate unresolved disagreements to the user. Use when the user asks to delegate, farm out, or parallelize work to Cursor / Antigravity / agy / "other agents", run the cross-agent dev loop, or get a second/third opinion from other models.
---

# delegate: cross-agent dev loop

You are the **lead**. You plan, split the work, delegate, review and merge. Workers are the Cursor CLI (`cursor`) and the Antigravity CLI (`agy`). They run headless, with full tool permissions, but **only** inside a dedicated git worktree created by `scripts/delegate.ps1`.

**Never call `agent` / `agy` directly with `--force` / `--dangerously-skip-permissions`. Always go through the script.** Only the script is allow-listed.

## Invocation (exact form, matches the permission rule)

Use the **Bash** tool:

```bash
pwsh -NoProfile -File D:/cross-agent-loop/skills/delegate/scripts/delegate.ps1 -Agent agy -Repo D:/path/to/repo -TaskId short-kebab-id -TaskFile D:/path/to/repo/.xagent/tasks/short-kebab-id.md
```

| Param | Notes |
|---|---|
| `-Agent` | `cursor` or `agy` |
| `-Repo` | top level of the target git repo |
| `-TaskId` | `^[a-z0-9][a-z0-9-]{0,48}$`; becomes the branch `xagent/<id>` and the worktree `<repoParent>/<repoName>.xagent/<id>` |
| `-TaskFile` | markdown task description (see below) |
| `-Base` | starting ref for a new worktree (default `HEAD`) |
| `-Resume` | `sessionId` from a previous run, to continue the same conversation |
| `-Profile` | `code` (default), `code-hard` or `council`; picks the model from `models.json` (see below) |
| `-Persona` | with `-Profile review`: `implementation_readiness`, `comprehension` or `design_critic` (EGM goldfish personas in `personas/`) |
| `-Model` | overrides the profile's model. Claude models and Cursor `auto` are **blocked** |
| `-TimeoutSec` | default 900; the process tree is killed on timeout |
| `-Cleanup` | removes the worktree and deletes the branch only if it's merged; also removes council worktrees for that TaskId |
| `-Cleanup -Discard` | throws away an **unmerged** worker branch (e.g. a benchmark loser or a failed attempt), saving its diff as a patch in the run logs first |

To run workers in parallel, issue several Bash calls in one message, each with its own `-TaskId`. Set the Bash tool `timeout` above `-TimeoutSec`. Use `run_in_background` for long tasks.

The script prints **one compact JSON line**: `ok, profile, model, violation, agent, taskId, worktree, branch, exitCode, timedOut, seconds, cliStatus, sessionId, result, changes, diffStat, stderrTail, logs`. Full logs are in `<repo>/.xagent/runs/<taskId>/`.

## Model profiles (`models.json`)

| Profile | Cursor | Antigravity | Use for |
|---|---|---|---|
| `code` | `composer-2.5` | `gemini-3.8-flash-medium` | well-specified tasks that follow your task file (the default) |
| `code-hard` | `grok-4.7-medium` | `gemini-4-argon-medium` | tricky bugs, bigger refactors, or a task that failed review twice on `code` |
| `review` | `composer-2.5` | `gemini-3.8-flash-medium` | **read-only** goldfish review with `-Persona` (see Goldfish preflight below) |
| `council` | `grok-4.7-high` | `gemini-4-argon-high` | **read-only** deliberation (see Council below) |

The user doesn't want Claude models used through Cursor or Antigravity: Claude is already the lead, and those are expensive there. Never pass `-Model claude-*` or `auto`; the script refuses them. Edit `models.json` to change the mapping.

## The loop

1. **Plan.** Break the issue into subtasks that are independent and well scoped. Keep architecture, cross-cutting changes and anything security-sensitive for yourself.
2. **Write a task file** for each subtask at `<repo>/.xagent/tasks/<taskId>.md` (`.xagent/` is git-excluded by the script). Include:
   - **Goal**: one or two sentences.
   - **Scope**: files and dirs it may touch, and what it must not touch.
   - **Constraints**: no new dependencies, follow existing style, etc.
   - **Acceptance criteria** and the **exact test command**.
   - Relevant context: interfaces, gotchas, links to code.
   - **Goldfish preflight** (see below) for anything beyond a trivial task.
3. **Delegate** with the script. Route work like this:
   - `cursor`: well-scoped implementation inside an existing codebase; UI work.
   - `agy`: exploration, tests, migrations, structured or mechanical changes.
   - Start with `-Profile code`; escalate to `code-hard` only when needed.
   - If a worker reports a quota or rate limit, switch to the other one.
4. **Review. Never trust the worker's `result` summary on its own.**
   - Read the actual diff in the worktree, **one file at a time** (`git -C <worktree> diff -- <file>`, plus untracked files from `changes`). Headroom compresses large tool outputs, so a whole diff at once may arrive cut short. If you see a `[... compressed ...]` marker, use `headroom_retrieve` or read smaller chunks.
   - Rerun the test command yourself inside the worktree.
   - Check that the change stays within scope.
5. **Iterate if needed.** Write `<taskId>.review-N.md` with specific, actionable feedback and rerun with the same `-TaskId`, `-TaskFile <review file>` and `-Resume <sessionId>`. Stop after about 3 rounds and do it yourself or rethink the split.
6. **Merge.** Commit in the worktree on the `xagent/<taskId>` branch (you write the commit message), then `git merge` it into the main branch from the main checkout. Resolve conflicts between parallel tasks yourself.
7. **Cleanup** with `-Cleanup`. Tell the user what each worker did, what you changed during review, and anything left open.

## Goldfish preflight & review (from Google's Elephant-Goldfish Model)

You're the *elephant*: you hold the whole conversation's context, so you can't see what your task file leaves unsaid. The workers are *goldfish*: they see only the task file. Before delegating, have a goldfish with no context check the task file:

```bash
pwsh -NoProfile -File D:/cross-agent-loop/skills/delegate/scripts/delegate.ps1 -Agent cursor -Profile review -Persona comprehension -Repo <repo> -TaskId pre-<id> -TaskFile <task.md>
pwsh -NoProfile -File D:/cross-agent-loop/skills/delegate/scripts/delegate.ps1 -Agent agy -Profile review -Persona implementation_readiness -Repo <repo> -TaskId pre-<id> -TaskFile <task.md>
```

- **When:** tasks touching more than two files, `code-hard` tasks, interface or validation changes, and **always in benchmark mode** (so neither worker is penalized for an ambiguity in the task). Skip it for trivial edits; each preflight costs about 15–50 seconds and 15–80k cheap tokens.
- **comprehension** paraphrases the task. If its paraphrase doesn't match what you meant, that's the most important finding. **implementation_readiness** applies the "zero-decision rule": does the task leave design choices to the worker?
- The report goes to `reviewFile` (Markdown, findings with Blocker/Major/Nit severity). Read it from the file.
- **Triage, don't obey blindly.** EGM's standard was written for design docs and over-asks on small tasks (exact helper names, error strings, phase plans). Fix findings where two reasonable workers could build *different behaviour or interfaces*. Ignore pure over-specification.
- **Optional goldfish code review:** for risky diffs, put the task file plus `git diff` into one file and run `-Profile review -Persona design_critic` on the **other vendor** from the one that wrote the code. Your own review still comes first.
- Clean up with `-Cleanup -Profile review -TaskId pre-<id>`.

## Benchmark mode (head-to-head; off by default)

Check it at the start of every delegation session: `python D:/cross-agent-loop/benchmarks/bench.py status`. The user turns it on with "benchmark the next N tasks", which you run as `bench.py on N [--profile code]`, and off with `bench.py off`. It turns itself off when the countdown hits 0.

When `enabled` is true, for each **implementation** subtask (not council runs or trivial edits):
1. Write the task file as usual. **Also write held-out acceptance tests** the workers never see. Keep them outside the task file, e.g. `.xagent/tasks/<id>.heldout_test.py` (or the repo's test-framework equivalent). They should check the behaviour the task asks for, without being stricter than the task.
2. Run **both** agents on the identical task file and base, with TaskIds `<id>--cursor` and `<id>--agy`, using the profile from `bench.py status`. Send both calls in the same message.
3. **First-try check, before any feedback:** in each worktree, run the worker-visible test command plus the held-out tests (copy them in temporarily, then delete them). Record pass or fail.
4. Review both the usual way. Give each one the review rounds it needs, judged by the same standard, and count the rounds.
   - **Token fairness:** Cursor reports cache reads separately and agy (so far) doesn't, so compare the *incl. cache* totals.
5. Score each 1–5 on **correctness**, **instructions** (followed the task and stayed in scope) and **quality** (readable, idiomatic, fits the codebase). Pick a winner: better final result, with fewer tokens and rounds as the tie-breaker.
6. **Merge only the winner's branch.** Then run `-Cleanup` for the winner and `-Cleanup -Discard` for the loser. Discard saves the loser's diff to `.xagent/runs/<taskId>/discarded-*.patch`, then deletes the worktree and branch.
7. Write a judgment JSON in the format shown in `bench.py`'s docstring and run `bench.py add <file>`. It pulls the tokens and wall time from `runs.jsonl` automatically, counts down, and rebuilds `benchmarks/REPORT.md`.
8. Include the printed comparison table in your report to the user.

Every delegate run, benchmarked or not, appends its token usage to `D:/cross-agent-loop/benchmarks/runs.jsonl`, which helps track quota use.

## Council: multi-model deliberation (read-only)

Three model families (Claude as lead, Grok via Cursor, Gemini via Antigravity) argue a decision. The goal is to surface blind spots and real disagreements, **not** to vote.

**Convene a council when:** an architecture or interface decision is hard to reverse; there are data or security trade-offs; requirements are ambiguous with several reasonable readings; a bug fix has failed twice for reasons you can't pin down; or the user asks for it. **Not** for routine implementation (it costs about 1–3 minutes and frontier tokens on both subscriptions).

1. **Question file:** `<repo>/.xagent/tasks/council-<id>.md` with the context, the decision(s) needed as numbered questions, the options you see, and the constraints. Keep it neutral; don't reveal your preference.
2. **Write your own position first:** `council-<id>.lead.md`, written before reading theirs, so you aren't anchored.
3. **Round 1:** run both with `-Profile council -TaskId <id>` (they run on detached worktrees, in plan mode, read-only).
4. **Fact-check:** where members disagree on a *fact*, verify it yourself (run the code, read the docs). Facts are settled by evidence, not by debate.
5. **Round 2:** write `council-<id>.r2.md` containing the verified facts plus all three positions, labelled A/B/C (include your own and note what you concede), and the remaining open questions. Run both again with `-Resume <sessionId>`. Usually 2 rounds is enough; never more than 3.
6. **Synthesize:**
   - **Consensus** (all three agree, or one concedes with a stated reason): adopt it and mention it briefly to the user.
   - **Unresolved disagreement** on a judgment call (values, priorities, risk appetite): **stop and escalate to the user.** Don't break the tie yourself, even if you're 2-to-1.
7. **Escalation brief** (in chat, and saved to `<repo>/.xagent/decisions/<id>.md`):
   - the decision in one line
   - what was agreed (so the user doesn't re-decide it)
   - each side of the dispute: who holds it, the strongest argument, and its main risk
   - what would settle it (a fact about the user's callers, product intent, etc.)
   - your recommendation, clearly labelled as one vote
   - Use AskUserQuestion when the options are crisp.
8. `-Cleanup -Profile council -TaskId <id>`.

Council notes: Cursor/Grok tends to put a preamble before its JSON (the script extracts it anyway). Headroom may compress long fields in tool output (`<<ccr:…>>`); read the specific fields from the `.stdout.json` log when you need the full text.

## Rules

- Never delegate secrets, credentials, deploy or publish steps, or anything outside the repo.
- Workers must not commit or push. If one did, review its commits as part of the diff (`git -C <wt> log <base>..`).
- If `ok` is false: read `stderrTail` and the log files, then retry once or reroute to the other worker.
- Antigravity on a consumer or Pro Google plan: whether automated use is allowed by the terms is unresolved (see the cross-agent-loop repo, `docs/research.md`). Mention this if the user hasn't acknowledged it.
