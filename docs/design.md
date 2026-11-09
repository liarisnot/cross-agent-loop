# Design (draft): `delegate` skill for Claude Code

*Status: draft. Pending results of [test-plan.md](test-plan.md).*

## Goal

Claude Code (the lead) runs the dev loop:

```
issue → plan & break down → delegate subtasks → collect results → review diff → iterate or merge
```

Delegated subtasks go to `agent` (Cursor CLI) or `agy` (Antigravity CLI) instead of Haiku sub-agents or manual copy-paste. Everything runs locally.

## Hand-off contract

**Task in.** Claude writes `.xagent/tasks/<task-id>.md` containing:
- goal, scope (the files and dirs it may touch), and constraints (no new dependencies, style rules, etc.)
- acceptance criteria and the test command to run
- the output contract (below)

**Isolation.** Each task runs in its own git worktree on branch `xagent/<task-id>`, so parallel workers never collide, and the review is just `git diff main...xagent/<task-id>`.

**Result out.** A JSON object, enforced with `--json-schema` on `agy` and asked for in the prompt for Cursor:

```json
{
  "status": "done | blocked | partial",
  "summary": "what was done",
  "files_changed": ["..."],
  "tests_run": "command + pass/fail",
  "open_questions": ["..."]
}
```

Claude never trusts the summary alone. It always reads the actual diff and reruns the tests.

## Invocation sketch

| Worker | Command (run inside the worktree) | Answer field | Iterate |
|---|---|---|---|
| Cursor | `agent -p --force --trust --output-format json "<prompt>"` | `.result` | new `-p` call with the review notes (check whether a resume/continue flag exists) |
| Antigravity | `agy -p - --output-format json --json-schema result.schema.json --dangerously-skip-permissions` (prompt on stdin) | `.response` | `agy -p --continue "<review notes>"` |

Every call:
- is wrapped in a timeout (Cursor `-p` hang bug; `agy --print-timeout` defaults to 5m)
- checks the exit code before parsing stdout
- saves the raw stdout and stderr to `.xagent/runs/<task-id>/<n>.json` for auditing

## Routing (initial heuristic, to be tuned)

- **Claude (self or subagent):** architecture, cross-cutting changes, review.
- **Cursor:** well-scoped implementation in an existing codebase, UI work.
- **Antigravity:** exploration, tests, migrations, tasks where structured output matters.
- Use whichever worker still has quota. All three are on ~$20 tiers, so rate limits will shape routing.

## Packaging

- `skills/delegate/SKILL.md`: when and how to delegate, the contract, and the review checklist.
- `skills/delegate/scripts/delegate.ps1` (plus maybe `.sh`): creates the worktree, runs the CLI with a timeout, normalizes the output into the result JSON.
- Possibly an MCP tool later if the skill+script approach turns out too loose.

## Alternatives considered

- **hcom:** messaging between live sessions, not one-shot calls. Could replace or augment this design if live conversation between agents turns out to be valuable. Evaluate in the test plan.
- **Omnigent:** too heavy and alpha-stage for now, and weak on Windows.
- **Cloud APIs** (Cursor Cloud Agents, Gemini Managed Agents): deferred because we're local-only. The contract above would carry over unchanged.

## Open questions

- Does Cursor's `-p` support resuming a session, or does each iteration start cold?
- Is the Antigravity Pro subscription allowed and functional for headless use? (Test plan T3/T4.)
- How do Windows paths and PowerShell quoting behave for long prompts? Prefer stdin or a prompt file over argv.

## v0 implementation notes (2026-11-09)

- Skill: `skills/delegate/SKILL.md`. Script: `skills/delegate/scripts/delegate.ps1`. Linked into `~/.claude/skills/delegate` with a junction, so the repo copy stays the only source.
- Invoked from the Bash tool as `pwsh -NoProfile -File D:/cross-agent-loop/skills/delegate/scripts/delegate.ps1 ...`. This exact prefix is what the permission rule allows.
- Instead of passing the long task text as a CLI argument (Windows quoting is fragile), the script copies the task file to `<worktree>/.xagent/task.md` and gives the worker a short fixed prompt that points to it. The worker writes `.xagent/result.json`, and the script falls back to parsing the final message.
- Cursor is started through `cursor-agent.ps1` with Windows PowerShell (same as `agent.cmd`), which avoids `cmd.exe` quoting. Iteration uses `--resume <session_id>`. Antigravity uses `--conversation <conversation_id>`.
- On timeout, `taskkill /T` kills the whole process tree.
- `.xagent/` goes in `.git/info/exclude` (shared by all worktrees), so the target repo's `.gitignore` is never touched.
