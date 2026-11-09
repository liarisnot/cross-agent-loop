# Feasibility test plan

Goal: prove that Claude Code can drive both CLIs headlessly on our Pro subscriptions on Windows, before building the skill. Record the results inline (✅ / ❌ plus notes and date).

Environment as of 2026-11-08: Claude Code 2.1.319 installed. **`agent` (Cursor CLI) and `agy` are NOT installed yet.**

## T0: Policy check (Antigravity)

- [ ] Read the current Antigravity FAQ and ToS for consumer and Pro plans: is wrapping or automating `agy` headless allowed? Record the URL and a quote here.
- [ ] Do the same check for Cursor (automation of the CLI on a Pro plan).

Result:

## T1: Install

- [x] Cursor CLI on Windows: native installer `irm 'https://cursor.com/install?win32=true' | iex`. Installs to `%LOCALAPPDATA%\cursor-agent` (`agent.exe` / `cursor-agent.exe`) and adds it to user PATH. Requires Git for Windows (present).
- [x] Antigravity CLI: `irm https://antigravity.google/cli/install.ps1 | iex`. SHA-512 verified. Installs to `%LOCALAPPDATA%\agy\bin\agy.exe` and adds it to user PATH.
- [ ] Log in interactively with each, using the Pro accounts (no API keys).

Result (2026-11-08): both installed. `agent` 2026.11.05-86047df, reports "Not logged in". `agy` 1.5.3, no login subcommand, so authentication presumably happens on the first interactive run. Both installer scripts were read before running.

Notes from `agy --help` (1.5.3) that differ from the research docs:
- `--print-timeout` now **defaults to 0** (wait until the turn completes), not 5m. So we need our own timeout wrapper.
- New/extra flags: `--mode accept-edits|auto|plan`, `--sandbox`, `--effort`, `--model`, `--conversation <id>` (resume by ID, which beats `--continue` for parallel workers), `--add-dir`.
- **`agy acp`**: starts an Agent Client Protocol stdio server. Possibly a cleaner integration than parsing `-p` output. Worth evaluating.
- `agy models` lists the models available to our account. Useful for the tier check.

## T2: Cursor headless basics

Run in a throwaway repo (e.g. `sandbox/` with a tiny project):

- [ ] `agent -p --output-format json "Say hello"`: valid JSON, `.result` present, exit code 0.
- [ ] Without `--force`: confirm no files are changed.
- [ ] With `--force --trust`: ask it to add a function and a test. Confirm the files changed and tests pass.
- [ ] Hang check: wrap the call in a timeout; note how long typical runs take.
- [ ] Iterating: is there a resume/continue flag? Test a follow-up call.
- [ ] Note which model is used by default on Pro, and whether `--model` works.

Result:

## T3: Antigravity headless basics (subscription tier question)

- [ ] `agy -p "Say hello" --output-format json`: did it succeed on the **Pro Google account**? Record `status` and `usage`. **This is the key tier question.**
- [ ] Unauthenticated behaviour: an error, not a hang.
- [ ] `--json-schema docs/result.schema.json`: is the output conforming?
- [ ] Prompt on stdin (`-p -`) with a long multi-line task.
- [ ] `--dangerously-skip-permissions`: edit files and run tests in the sandbox repo.
- [ ] `--continue`: does a follow-up keep context?
- [ ] Check the quota/usage display after a few runs: how fast does Pro get used up?

Result:

## T4: Driven from Claude Code

- [ ] From a Claude Code session, run both CLIs via the Bash/PowerShell tool with a timeout; confirm no TTY or interactive-prompt problems.
- [ ] Run each worker in a separate git worktree at the same time (parallel run).
- [ ] Claude reviews both diffs and sends one round of review feedback to each.

Result:

## T5: hcom (alternative)

- [ ] Install hcom on Windows; launch `hcom claude`, `hcom cursor-agent`, `hcom agy`.
- [ ] Can Claude message a Cursor or agy session and get a reply back?
- [ ] Compare with the one-shot CLI approach: is a live session better for iterating?

Result:

## T6: Headroom interaction

- [ ] With headroom running, run `agent -p` and `agy -p` from a Claude Code Bash call: any TLS or cert errors (`tls.process_injected`, `HEADROOM_PROCESS_TRUST`)? If so, retry with those vars unset for the child process.
- [ ] Compression fidelity: have a worker produce a ~300-line diff. Does the lead see it in full via `git diff`? Note any `[compressed]` markers. Compare reading it per file vs. all at once.
- [ ] Does a structured JSON result (`.result` / `.response`) reach the lead intact?
- [ ] Optional (only if T0 allows it): `headroom mcp install --agent antigravity` and check that `agy` sees the tools.
- [ ] Do NOT route `agy` model traffic through `/v1internal` until the ToS question is settled.

Result:

## Decision after testing

- [ ] Go / no-go per worker
- [ ] Choose: our own `delegate` skill vs. hcom vs. a hybrid
