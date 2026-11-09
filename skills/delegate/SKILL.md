---
name: delegate
description: Delegate coding subtasks from Claude Code (as lead programmer) to Cursor CLI or Google Antigravity CLI worker agents running locally in isolated git worktrees, then review, iterate and merge their work. Use when the user asks to delegate, farm out, or parallelize work to Cursor / Antigravity / agy / "other agents", or to run the cross-agent dev loop.
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
| `-Model` | optional worker model (`agy models` / `agent --list-models`) |
| `-TimeoutSec` | default 900; the process tree is killed on timeout |
| `-Cleanup` | removes the worktree and deletes the branch only if it's merged |

To run workers in parallel, issue several Bash calls in one message, each with its own `-TaskId`. Set the Bash tool `timeout` above `-TimeoutSec`. Use `run_in_background` for long tasks.

The script prints **one compact JSON line**: `ok, agent, taskId, worktree, branch, exitCode, timedOut, seconds, cliStatus, sessionId, result, changes, diffStat, stderrTail, logs`. Full logs are in `<repo>/.xagent/runs/<taskId>/`.

## The loop

1. **Plan.** Break the issue into subtasks that are independent and well scoped. Keep architecture, cross-cutting changes and anything security-sensitive for yourself.
2. **Write a task file** for each subtask at `<repo>/.xagent/tasks/<taskId>.md` (`.xagent/` is git-excluded by the script). Include:
   - **Goal**: one or two sentences.
   - **Scope**: files and dirs it may touch, and what it must not touch.
   - **Constraints**: no new dependencies, follow existing style, etc.
   - **Acceptance criteria** and the **exact test command**.
   - Relevant context: interfaces, gotchas, links to code.
3. **Delegate** with the script. Route work like this:
   - `cursor`: well-scoped implementation inside an existing codebase; UI work.
   - `agy`: exploration, tests, migrations, structured or mechanical changes. It can also run Claude or Gemini models via `-Model`.
   - If a worker reports a quota or rate limit, switch to the other one.
4. **Review. Never trust the worker's `result` summary on its own.**
   - Read the actual diff in the worktree, **one file at a time** (`git -C <worktree> diff -- <file>`, plus untracked files from `changes`). Headroom compresses large tool outputs, so a whole diff at once may arrive cut short. If you see a `[... compressed ...]` marker, use `headroom_retrieve` or read smaller chunks.
   - Rerun the test command yourself inside the worktree.
   - Check that the change stays within scope.
5. **Iterate if needed.** Write `<taskId>.review-N.md` with specific, actionable feedback and rerun with the same `-TaskId`, `-TaskFile <review file>` and `-Resume <sessionId>`. Stop after about 3 rounds and do it yourself or rethink the split.
6. **Merge.** Commit in the worktree on the `xagent/<taskId>` branch (you write the commit message), then `git merge` it into the main branch from the main checkout. Resolve conflicts between parallel tasks yourself.
7. **Cleanup** with `-Cleanup`. Tell the user what each worker did, what you changed during review, and anything left open.

## Rules

- Never delegate secrets, credentials, deploy or publish steps, or anything outside the repo.
- Workers must not commit or push. If one did, review its commits as part of the diff (`git -C <wt> log <base>..`).
- If `ok` is false: read `stderrTail` and the log files, then retry once or reroute to the other worker.
- Antigravity on a consumer or Pro Google plan: whether automated use is allowed by the terms is unresolved (see the cross-agent-loop repo, `docs/research.md`). Mention this if the user hasn't acknowledged it.
