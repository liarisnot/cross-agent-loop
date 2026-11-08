# Feasibility test plan

Goal: prove that Claude Code can drive both CLIs headlessly on our Pro subscriptions on Windows, before building the skill. Record the results inline (✅ / ❌ plus notes and date).

Environment as of 2026-11-08: Claude Code 2.1.319 installed. **`agent` (Cursor CLI) and `agy` are NOT installed yet.**

## T0: Policy check (Antigravity)

- [ ] Read the current Antigravity FAQ and ToS for consumer and Pro plans: is wrapping or automating `agy` headless allowed? Record the URL and a quote here.
- [ ] Do the same check for Cursor (automation of the CLI on a Pro plan).

Result:

## T1: Install

- [ ] Cursor CLI on Windows. The official one-liner is a bash script; check the docs for a Windows/PowerShell installer or whether WSL is needed. Then run `agent --version`.
- [ ] Antigravity CLI: `irm https://antigravity.google/cli/install.ps1 | iex`, then `agy --version`.
- [ ] Log in interactively with each, using the Pro accounts (no API keys).

Result:

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

## Decision after testing

- [ ] Go / no-go per worker
- [ ] Choose: our own `delegate` skill vs. hcom vs. a hybrid
