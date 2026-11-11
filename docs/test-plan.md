# Feasibility test plan

Goal: prove that Claude Code can drive both CLIs headlessly on our Pro subscriptions on Windows, before building the skill. Record the results inline (✅ / ❌ plus notes and date).

Environment as of 2026-11-08: Claude Code 2.1.319 installed. **`agent` (Cursor CLI) and `agy` are NOT installed yet.**

## T0: Policy check (Antigravity)

- [x] Read the current Antigravity FAQ and ToS for consumer and Pro plans: is wrapping or automating `agy` headless allowed? Record the URL and a quote here.
  - **Checked 2026-11-10. Answer: no, not under a consumer (Free, Plus, Pro or Ultra) login.**
  - [FAQ](https://antigravity.google/docs/faq/), "Can I use Antigravity CLI headless mode in third-party coding agents…": "Antigravity CLI headless mode (`agy -p`) is intended for direct scripting and CI workflows. Wrapping `agy` inside third-party coding agents or applications … [is not supported] under consumer plans."
  - FAQ, "Why can't I use third-party software (such as Claude Code, …) with my Antigravity login?": "Using third-party software, tools, or services to access Antigravity is a violation of our Terms of Service." "Such actions can result in suspension or termination of your account." "To use a third-party coding agent with Gemini, we recommend using a Gemini Enterprise or Google AI Studio API key."
  - The Additional Terms §6 cover third-party access to the Service. On the Google forum, replies after the FAQ update (mid-October 2026) say the FAQ supersedes earlier forum answers. They say the rule applies even when the official binary runs as a local subprocess, and that a worker backend for a multi-agent framework is not supported and can trigger automated enforcement. See [forum thread](https://discuss.ai.google.dev/t/clarification-on-subscription-based-agy-p-integration-with-a-local-multi-agent-framework/196472) and [GitHub issue #1493](https://github.com/google-antigravity/antigravity-cli/issues/1493).
  - **Our `delegate` use (Claude Code launches `agy -p` as a worker or reviewer) is exactly the unsupported case.**
  - **Supported route:** `agy` reads a Google AI Studio key when `~/.gemini/antigravity-cli/settings.json` has `{"modelProvider":"gemini"}` and `GEMINI_API_KEY` is set (since 1.1.13, 2026-08-14). That bills per token, not against the Pro subscription.
  - **Also found:** the Cursor CLI offers the same Gemini models (`gemini-4-argon-*`, `gemini-3.8-flash-*`), plus GPT, Kimi, GLM and DeepSeek, all on the Cursor subscription.
- [ ] Do the same check for Cursor (automation of the CLI on a Pro plan).

Result:

## T1: Install

- [x] Cursor CLI on Windows: native installer `irm 'https://cursor.com/install?win32=true' | iex`. Installs to `%LOCALAPPDATA%\cursor-agent` (`agent.exe` / `cursor-agent.exe`) and adds it to user PATH. Requires Git for Windows (present).
- [x] Antigravity CLI: `irm https://antigravity.google/cli/install.ps1 | iex`. SHA-512 verified. Installs to `%LOCALAPPDATA%\agy\bin\agy.exe` and adds it to user PATH.
- [x] Log in interactively with each, using the Pro accounts (no API keys).

Result (2026-11-08): both installed. `agent` 2026.11.05-86047df, reports "Not logged in". `agy` 1.5.3, no login subcommand, so authentication presumably happens on the first interactive run. Both installer scripts were read before running.

Notes from `agy --help` (1.5.3) that differ from the research docs:
- `--print-timeout` now **defaults to 0** (wait until the turn completes), not 5m. So we need our own timeout wrapper.
- New/extra flags: `--mode accept-edits|auto|plan`, `--sandbox`, `--effort`, `--model`, `--conversation <id>` (resume by ID, which beats `--continue` for parallel workers), `--add-dir`.
- **`agy acp`**: starts an Agent Client Protocol stdio server. Possibly a cleaner integration than parsing `-p` output. Worth evaluating.
- `agy models` lists the models available to our account. Useful for the tier check.

## Results log, 2026-11-08

- Login: `agent status` shows "Logged in as <user email>". `agy models` works on the Google Pro account and lists Gemini 4 Argon (low/med/high), Gemini 3.8 Flash, **Claude Opus 5.5 / Sonnet 5.5**, and GPT-OSS 120B.
- **Hello test, both ✅** (sandbox repo, read-only prompt, 180s timeout):
  - Cursor: `cmd.exe /c agent.cmd -p --trust --output-format json "..."` gave exit 0 in ~8s. JSON: `{"type":"result","subtype":"success","is_error":false,"result":"...","session_id":"...","usage":{...}}`. **The answer is in `.result`, and `session_id` should allow resuming.**
  - Antigravity: `agy.exe -p "..." --output-format json` gave exit 0 in ~6s. JSON: `{"conversation_id":"...","status":"SUCCESS","response":"...","num_turns":1,"usage":{...}}`. **Headless works on the Pro tier (technically). ToS (T0) is still open.**
- Windows gotchas: in Git Bash, call `agent.cmd` via `cmd.exe //c "<windows path>"`. A Windows-style PATH append doesn't work there, so use absolute paths. `agy.exe` runs directly.
- **Blocker found: Claude Code auto mode refuses to launch workers with approvals turned off** (`--force` / `--dangerously-skip-permissions`). It reports "Create Unsafe Agents". The `delegate` skill needs one of:
  1. an explicit Bash permission rule in `settings.json` allowing our wrapper script (narrowest: allow only `delegate.ps1`), or
  2. the user running the delegation step themselves, or
  3. workers in a restricted mode: `agy --sandbox` plus `--mode accept-edits`, and Cursor without `--force` (proposes only, so Claude applies the changes). Needs testing.

## T2: Cursor headless basics

Run in a throwaway repo (e.g. `sandbox/` with a tiny project):

- [x] `agent -p --output-format json "Say hello"`: valid JSON, `.result` present, exit code 0.
- [ ] Without `--force`: confirm no files are changed.
- [x] With `--force --trust`: ask it to add a function and a test. Confirm the files changed and tests pass.
- [x] Hang check: wrap the call in a timeout; note how long typical runs take.
- [x] Iterating: is there a resume/continue flag? (`--resume <session_id>` works) Test a follow-up call.
- [x] Note which model is used by default on Pro, and whether `--model` works. (default `auto`, so now blocked; `--model` works)

Result:

## T3: Antigravity headless basics (subscription tier question)

- [x] `agy -p "Say hello" --output-format json`: did it succeed on the **Pro Google account**? Record `status` and `usage`. **This is the key tier question.**
- [ ] Unauthenticated behaviour: an error, not a hang.
- [x] `--json-schema docs/result.schema.json` (also returns `structured_output`): is the output conforming?
- [ ] Prompt on stdin (`-p -`) with a long multi-line task. (**Not honored with `--mode plan`**; untested otherwise)
- [x] `--dangerously-skip-permissions`: edit files and run tests in the sandbox repo.
- [x] `--continue`: does a follow-up keep context? (used `--conversation <id>` instead; works once the prompt says the instructions are NEW)
- [ ] Check the quota/usage display after a few runs: how fast does Pro get used up?

Result:

## T4: Driven from Claude Code

- [x] From a Claude Code session, run both CLIs via the Bash/PowerShell tool with a timeout; confirm no TTY or interactive-prompt problems.
- [ ] Run each worker in a separate git worktree at the same time (parallel run). (separate worktrees ✅; truly simultaneous via `run_in_background` not yet tested)
- [x] Claude reviews both diffs and sends one round of review feedback to each.

Result:

## T5: hcom (alternative)

- [ ] Install hcom on Windows; launch `hcom claude`, `hcom cursor-agent`, `hcom agy`.
- [ ] Can Claude message a Cursor or agy session and get a reply back?
- [ ] Compare with the one-shot CLI approach: is a live session better for iterating?

Result:

## T6: Headroom interaction

- [x] With headroom running, run `agent -p` and `agy -p` (no TLS errors seen) from a Claude Code Bash call: any TLS or cert errors (`tls.process_injected`, `HEADROOM_PROCESS_TRUST`)? If so, retry with those vars unset for the child process.
- [ ] Compression fidelity (small diffs fine; long council fields got `<<ccr:…>>` placeholders, so read the logs. ~300-line diff not tested): have a worker produce a ~300-line diff. Does the lead see it in full via `git diff`? Note any `[compressed]` markers. Compare reading it per file vs. all at once.
- [x] Does a structured JSON result (`.result` / `.response`) reach the lead intact?
- [ ] Optional (only if T0 allows it): `headroom mcp install --agent antigravity` and check that `agy` sees the tools.
- [ ] Do NOT route `agy` model traffic through `/v1internal` until the ToS question is settled.

Result:

## Decision after testing

- [x] Go / no-go per worker (go for both; agy pending T0)
- [x] Choose: our own `delegate` skill vs. hcom vs. a hybrid (own skill; hcom not tried)

## Results log, 2026-11-09: full loop through `delegate.ps1` ✅

After the permission rule `Bash(pwsh -NoProfile -File D:/cross-agent-loop/skills/delegate/scripts/delegate.ps1 *)` was added, auto mode allowed the script. **The allow rule overrides the "Create Unsafe Agents" denial.**

| Step | Cursor (`add-subtract`) | Antigravity (`add-multiply`) |
|---|---|---|
| Initial task | ✅ 20s, correct, in scope, tests pass | ✅ 49s, correct, in scope, tests pass (left an extra trailing blank line) |
| Review 1 via `-Resume` | ✅ 15s, applied | ❌ then ✅. The first try changed nothing and returned the old summary. Fixed in the script (below); the retry took 39s and applied both changes |
| Lead verification | read diff + reran tests ✅ | read diff + reran tests ✅ |
| Merge | clean | conflict in `calc.py` / `test_calc.py` (both appended at the same spot), resolved by lead; 3 tests pass |
| Cleanup | ✅ | ✅ |

Fixes made during testing:
1. **Stale follow-up (agy):** with `--conversation`, a fixed prompt plus the same `task.md` name led the worker to assume it had already read the file. Now every run gets a unique `.xagent/task-<stamp>.md`, and resumed runs get an explicit "FOLLOW-UP… NEW instructions you have not seen" prompt.
2. agy returns `structured_output` (schema-validated) in its JSON. The script now uses it first.
3. `-Cleanup` failed on untracked leftovers (`__pycache__`, `.xagent/`). Now it force-removes only when the branch is merged into HEAD **and** no tracked file has uncommitted changes. Otherwise it refuses.
4. A helper named `Git` called itself recursively (PowerShell names aren't case-sensitive). Renamed it to `Invoke-Git`.

Observations:
- Headroom showed up in diff reviews as dedup markers (`[↑3L same as msg 97 …]`) rather than lossy compression. The review was still readable. Keep the "one file at a time" rule.
- Workers on parallel branches that touch the same file will conflict. Splitting tasks along file boundaries reduces this. The lead resolving conflicts is expected.
- The worker CLIs produce CRLF files on this machine (git autocrlf). Harmless.
- Calls from Claude Code ran one after another, not at the same time. True parallel runs need `run_in_background` (still to test).

Still open: T0 (Antigravity ToS on a consumer Pro plan), quota burn on the Pro tiers, true parallel runs in the background, a real-repo trial (e.g. MyApp).

## Results log, 2026-11-09: model profiles + council ✅

- `models.json` profiles: code = composer-2.5 / gemini-3.8-flash-medium; code-hard = grok-4.7-medium / gemini-4-argon-medium; council = grok-4.7-high / gemini-4-argon-high.
- The blocklist rejects `claude*` and Cursor `auto` (`auto` slipped through on the first test and actually ran a worker; now blocked).
- Council test in the sandbox ("input validation + divide-by-zero policy"):
  - Round 1: Grok 139s (put a preamble before its JSON, so the parser was fixed to extract the `{…}` span), Gemini 60s. Neither modified files in plan mode (`violation: null`).
  - Grok made a **factual error** (said `numbers.Number` excludes Decimal). Gemini found a **real gap** in the lead's position (`Decimal(0)/Decimal(0)` raises InvalidOperation, which isn't a ZeroDivisionError). The lead verified both in Python.
  - Round 2 (`-Resume`, verified facts plus A/B/C positions): Grok 197s, Gemini 53s. **Q1 converged 3/3**; **Q2 stayed 2-vs-1**, a real judgment call, so it was escalated (`sandbox/.xagent/decisions/validation.md`).
- Headroom compressed long string fields in the council output (`<<ccr:…>>`). Reading specific fields from the `.stdout.json` log works around it.

## Results log, 2026-11-09: benchmark mode ✅ (trial)

- `delegate.ps1` now writes normalized token usage (`input/output/reasoning/cacheRead/cacheWrite/total`) to its summary and appends every run to `benchmarks/runs.jsonl`.
- `benchmarks/bench.py` (on/off/status/add/report/last) and `benchmarks/config.json` (flag plus countdown). `REPORT.md` is regenerated after each recorded task.
- Trial (`add-divide`, profile `code`, held-out tests): both passed all held-out tests on the first try, with no review rounds. agy won on quality (5/5/5 vs 5/5/4). Cursor composer-2.5: 15s, 81.8k tokens incl. 70k cache reads. agy gemini-3.8-flash: 62s, 180.7k tokens, 0 cached.
- Lesson: the first comparison said "16x fewer tokens" but left out Cursor's cache reads. The fair figure is ~2.2x. The report now shows totals both ways.
- Added `-Cleanup -Discard` for unmerged losers (saves a patch first).
- The trial record was moved to `benchmarks/trial-records.jsonl`, so `REPORT.md` covers real tasks only.

## Results log, 2026-11-09: goldfish preflight (EGM personas) ✅

- Cursor `--mode ask` + `comprehension` persona (composer-2.5, 19s, 13k tokens): good paraphrase plus 3 Major / 3 Nit findings. Best one: the task title "add divide()" undersells a refactor that touches all four functions. `--mode plan` made composer narrate without writing a report.
- agy `implementation_readiness` (gemini-3.8-flash-medium, 48s, 77k tokens): verdict "ready-with-fixes". It flagged the unspecified helper signature, which is exactly where the two benchmark workers diverged (single-arg vs variadic). Some findings over-specify (phases, exact error strings). Triage rule added to SKILL.md.
- agy headless pitfalls found:
  1. flash models run `Get-ChildItem`/`cat` to read the hand-off file. Plan mode auto-denies shell commands, and the run aborts with "no output produced". Fix: embed the file in the prompt.
  2. `-p -` (stdin) is **not** honored with `--mode plan`: agy builds `/plan -` and the model sees a literal "-". Fix: pass the embedded prompt as an escaped argv argument (proper MSVCRT/Go quoting; capped at 28k chars).
  3. Without `--json-schema`, plan-mode runs tend not to end with a reply. All read-only agy runs now use a schema (`review.schema.json` / `council.schema.json`).
- Council plumbing re-verified after the change (flash-low override, 15s).


## Cursor usage pools (legacy Pro, checked 2026-11-10)

*   **Spending page.** It shows two pools as a percentage used, resetting monthly (next on Nov 13):
    *   **Cursor Models** (Grok, Composer). Overflow consumes the Other Models quota, then on-demand spend.
    *   **Other Models** (GLM, DeepSeek). Overflow goes to on-demand spend, which is disabled.
*   **Usage page.** It lists each request as "Included", with tokens that **include cache reads**. `runs.jsonl`'s `total` leaves them out.
*   **Rough rates, from 2026-11-10's design review.**
    *   **GLM 5.2:** 4 review runs took Other Models from 0% to 3%, so about 0.75% per run, or roughly 130 runs a month.
    *   **Grok 4.7:** about 7 review runs plus some Composer took Cursor Models to 4%, so about 0.5% per Grok run.
    *   **To refine:** re-check after the next review.

## Pitfalls and measurements from the feature-design review (2026-11-10)

*   **Two Cursor runs with the same `-TaskId` collide.** The read-only worktree is named `<TaskId>-<agent>`. Give each concurrent run its own id. The `feature` design adds `-Seat` for council seats.
*   **agy's read-only path embeds the target in the command line**, and fails above 28,000 characters (a 795-line design gave 66,915). Passing a short task file that names the target's path worked. Cursor reviewers read targets by path with no problem.
*   **The effort level barely matters for review lenses.** `grok-4.7-medium` took 421 s and about the same tokens as `grok-4.7-high` (414–632 s). Most of the time and tokens go into reading files. Grok reads about 3× more input than GLM.
*   **GLM 5.2 as a reviewer:** 49–79 s and 32k–44k tokens (excluding cache reads) per lens, against 400–630 s and 157k–176k for Grok. Its findings were comparable, with one invented citation (a quoted phrase not in the doc) out of about 23 findings. The lead's triage should verify quotes.
*   **The fourth review round brought churn.** Fixes added in earlier rounds generated new findings, which is EGM's signal to stop adding mechanism. The intermediate zoom-out (stage 8) then cut it. Expect this on large designs, and run stage 8 before a fourth critic round.
*   **`git commit -am` picks up `benchmarks/runs.jsonl`**, which is still tracked and changes on every run. Stage files explicitly until it moves to `%LOCALAPPDATA%\xagent\`. (Moved in build step 1, 2026-11-11.)

## Dogfooding `delegate` during the `feature` build (from 2026-11-11)

From build step 2 on, every build step goes through the `delegate` skill, loaded with the Skill tool and followed as written. This log records how the skill itself behaves. **Status:** open, fixed, or by design.

| # | Date | Observation | Status |
|---|---|---|---|
| D1 | 2026-11-11 | Claude Code reports the skill's base directory as the junction (`<user profile>/.claude/skills/delegate`), so the `<skill dir>` command in SKILL.md didn't match the only allow rule (`D:/cross-agent-loop/...`). Every literal call would have prompted. | **Fixed:** a second allow rule for the junction path (build step 5's Machine setup does this for new machines) |
| D2 | 2026-11-11 | Pester on this machine was 3.4.0 (Windows built-in); workers running Pester tests need 5.5+. `Install-Module` installed 6.2.0, which the `#Requires ModuleVersion='5.5'` line accepts. | **Fixed** (machine setup) |
| D3 | 2026-11-11 | `-TargetFile` copies files flat into `.xagent/` by file name, so two files with the same name (for example two `SKILL.md`) overwrite each other. Not a problem for v1's uses (one diff file), but it rules `-TargetFile` out for handing over a folder. | Open, by design for v1 |
