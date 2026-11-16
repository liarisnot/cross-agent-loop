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
| D4 | 2026-11-11 | Preflight reviewers see the task file but not the worker contract `delegate.ps1` appends (`result.json`, `open_questions`), so `comprehension` flagged `open_questions` as undefined (Major). | **Fixed:** review runs now get a "Harness context" note with the worker contract; check on the next preflight |
| D5 | 2026-11-11 | SKILL.md says to pass documents by path, but `comprehension` judges self-containment, so a task that points at design sections gets 5 Majors for "not reproduced here" while its paraphrase is correct. The paraphrase is the useful signal; the Majors are noise for by-path tasks. | **Fixed:** SKILL.md triage advice |
| D6 | 2026-11-11 | DeepSeek readiness preflights cost 102k–125k tokens and 102–133 s per task file, against SKILL.md's "15–80k, 15–50 s" (measured on Composer and Gemini Flash). Composer comprehension stayed in range (18k–27k, 17–25 s). | **Fixed:** SKILL.md has the measured numbers |
| D7 | 2026-11-11 | Both DeepSeek preflights caught a lead bug: acceptance commands written as `pwsh -c "…$var…"` break when run from Bash (the lead's shell), because Bash expands `$` first. Fixed with single quotes, and for a long check, a `.ps1` handed to the worker with `-TargetFile` (a good use of it). | **Fixed:** SKILL.md task-file advice (and the stub-test lesson from D9) |
| D8 | 2026-11-11 | `core.autocrlf=true` here, so a worker's clone checks out CRLF files and its "byte-identical" copies are CRLF on disk. An on-disk hash check against the worker's own clone passes but proves little; a hash against an independent source fails on line endings alone. The right check is git blobs (`git hash-object`, or `git ls-tree` after commit), which matched upstream for all 8 EGM files. | By design; check blobs, not disk bytes |
| D9 | 2026-11-11 | First real build tasks: `fb-egm` (Composer, 22 s, 15k tokens) passed review first time; `fb-schemas` (Composer, 66 s, 52k tokens, 25 files, 26 tests) needed one round: a helper its task told it not to test yet had an unused parameter. Lesson for task files: if a helper can't be called yet, have it tested against a stub. | Lead's task-writing lesson |
| D10 | 2026-11-11 | **D4 fix confirmed:** on `fb-core`, `comprehension` noted the harness `result.json` instructions as out of scope instead of reporting them missing. **Readiness keeps paying for itself:** on the first real-code task (DeepSeek, 102 s, 119k tokens) it found two defects that would have broken the code: an untracked design doc invisible to the planned "has changes" check, and git's own stdout mixing into the JSON output. Plus lock, read-source and parameter-binding gaps. Comprehension (Composer, 42 s, 35k) found only clarity issues. | Confirms SKILL.md's advice: readiness for real-code tasks |
| D11 | 2026-11-11 | `fb-core` (step 2.2): Composer wrote a 675-line `feature.ps1` and 25 tests in 588 s (107k tokens); all 52 tests passed, but reading the code found a real bug: listing features threw for any unmerged feature (`Invoke-GitRepo` throws on `merge-base --is-ancestor` exit 1), and the "refuses a second feature" test passed only because any failure satisfied it. Round 2 via `-Resume`: 83 s, **10k tokens** (cached context), fixed it plus 6 tests that assert error messages. **Lessons:** green tests from a worker aren't enough; tests must assert the failure *reason*. A resumed round is about a tenth of the first round's tokens. | Lessons for task files and review |
| D12 | 2026-11-11 | **Lead slip:** I sent an Edit (a fix-up in the worker's worktree) and the commit-and-merge Bash in one parallel batch. The Edit failed (file changed since read), the Bash ran anyway, and the commit message claimed a fix-up that wasn't in it. Corrected with a follow-up commit (`f46b50a`). **Rule:** a commit that depends on an edit goes in the next message, after the edit succeeds. | Lead process lesson |
| D13 | 2026-11-11 | **A worker timed out** (`fb-plan`, 2400 s): `delegate.ps1` killed it and reported `sessionId: null` and 0 tokens, because Cursor writes its JSON summary only at the end. So a timed-out run can't be resumed and its usage isn't logged. The work itself was nearly done (1,215 lines, 104/105 tests). **Cause:** the Pester suite takes 283 s (105 tests, each spawning `pwsh` several times), and the worker reran the whole suite after each change. **Fixes used:** told the worker to run filtered tests while iterating and the full suite once; reran with a fresh session on the same `-TaskId`, which reuses the existing worktree and branch, handing over the original task with `-TargetFile`. | **Fixed:** SKILL.md now says both (the `-TimeoutSec` row and the task-file advice). Round 2 with a subset command: 377 s, 62k tokens, no timeout |
| D14 | 2026-11-11 | **Two latent bugs surfaced only through review probes**, not the worker's tests: (1) the console code page is `ibm437`, so `git show` output was mis-decoded and `feature.ps1` corrupted any non-ASCII text in `feature.json` on rewrite (`café — ok` → `caf├⌐ ΓÇö ok`), present since step 2.2; (2) PowerShell unwraps 0- and 1-element arrays returned from functions, so `dependsOn: []` was stored as `null` and `schedule` returned `files` as a string, violating its schema. Both the same family of PowerShell traps as step 1's `.Count` bug. | **Fixed:** in `fb-plan` round 2 (regression tests added), and the same UTF-8 decoding added to `delegate.ps1` |
| D15 | 2026-11-11 | **A follow-up file skipped the preflight when it shouldn't have:** follow-up files (`review-N.md`) went straight to the worker. That is fine with `-Resume`, since the worker keeps its earlier conversation, but `fb-plan` round 2 was a **fresh** session (D13), so its follow-up file was in effect the whole task for a worker with no context. It worked, but it was never checked by a goldfish. Raised by the user. | **Fixed:** SKILL.md step 5: a follow-up file for a fresh session gets the comprehension preflight (and readiness if it changes scope) |
| D16 | 2026-11-11 | **A worker run was killed from outside:** `fb-tvm` (step 2.4) ran as a background Bash task; after about 45 minutes Claude Code stopped it because the machine was low on memory. `delegate.ps1` and the Cursor CLI both died without running `finally`: a **stale pid file** stayed in `.xagent/runs/fb-tvm/` (its processes gone), `stdout.json` was empty, so no session id and no usage line. The worker's uncommitted work (+1106 lines in the 3 files) survived in the worktree. Same recovery as D13 applies (fresh session on the same `-TaskId`). | **Fixed:** SKILL.md now launches long workers detached (`Start-Process`, summary to a file, watched with Monitor). Round 2 ran that way: 1098 s, 91k tokens, session id captured. `reconcile` (step 2.5) must still treat a pid file whose processes are gone as not live, as the design says |
| D17 | 2026-11-11 | **`fb-tvm` (step 2.4) recap.** Preflights: comprehension 43 s / 36k, readiness 136 s / 159k; readiness found a real blocker (empty-string rule vs validation) and a design flaw in my task (holding the lock for the whole test run). Round 1 was killed (D16) with 19/27 new tests passing; two code bugs were the D14 family again: `return ,$arr` **plus** `@()` at the call site nests the array (two paths became one joined string, none became `[""]`), and `.Count` on an empty `Where-Object` result. The D15 preflight on the round-2 file (37 s / 24k) asked for a failure-to-fix map and a definition of done; both added. Round 2 (fresh session, detached): 1098 s / 91k, 138/138. Lead probes passed (non-ASCII and spaced names, 4 changes, quotes in the merge message, failures count). Lead fix-up: ordinal `StartsWith` in the scope and overlap helpers. **The full suite now takes 635 s** (was 300 s): size `-TimeoutSec` and the filtered-test advice for it. | Recorded; the next task files give the 635 s figure |
| D18 | 2026-11-11 | **Test cost, measured and cut (`fb-speed`).** The user asked whether a skill needs that many tests. Profile: each `feature.ps1` child call costs about 0.7 s (200 ms `pwsh` start, about 26 ms per git call, 70 ms `Test-Json`); stage setup made 3-5 such calls per test; one `verify` test built 7 repos and worktrees to check 7 path patterns (50 s). Fix, delegated: setup helpers call the script in-process (commands under test stay child processes), pure path and overlap rules get in-process unit cases taken from the script's own function definitions, 27 tests tagged `Slow`. Full suite 628 s to 366 s (164 tests), fast tier 225 s (137). Preflights: readiness caught that my `Slow` rule would tag nearly every test, and that one "overlap" test I meant to delete checks status gating. Worker 910 s / 53k. Also a lead slip: a Python edit script turned `\a` into a BEL byte in the task file; caught by a byte check before launch. | Design item 19's test list is long because the zero-decision rule enumerates every case; step 2.5's lists were trimmed (about 17 `status` tests) before delegating |
| D19 | 2026-11-12 | **Steps 2.5-5 overnight, unattended (the user authorized continuing).** Workers: `fb-status` 887 s / 180k, `fb-reconcile` 1430 s / 225k, `fb-finish` 1253 s / 126k (Composer); `fb-stages` (step 4, the router and 6 stage files; the user chose to delegate it) 1184 s / 478k on **`code-hard` (Grok 4.7 high), its first real use**; `fb-docs` 78 s / 64k. Every launch detached, no losses. **Readiness found a real blocker or gap in every task file**: a test expecting a decision line `new` never writes; reconcile's undefined multi-pid and double-failure cases; `finish` checks ordered so the branch refusal was unreachable; seven router entry points with no instructions, repo-relative paths that don't exist in a user's repo, and a council command `delegate.ps1` would reject; a root `.gitignore` rule that silently ignored the sandbox fixture. **Lead review found what tests missed again**: `doctor`'s PowerShell check always failed (`SemanticVersion` has no `Build` under strict mode; the test checked only shape); `status` summed tokens in `[int]` into the automatic `$input`; the router read a new `[stop]` from the wrong field. **Prompt files got a lint as their acceptance test** (`fb-stages-check.ps1`: files, frontmatter, every `feature.ps1` subcommand/parameter and `delegate.ps1` parameter mentioned exists). **Lead gap:** my step 2 task files had left out design item 18 (sandbox), caught at step 5. | Recorded; the Grok comprehension row is D20 |
| D20 | 2026-11-12 | **A comprehension preflight on Grok 4.7 high timed out** (600 s, no report) on `fb-stages`, whose task points the reviewer at about 1,200 lines of design; the retry with 1,500 s was stopped by Claude Code's memory reaper (a background Bash task, while a detached Pester run was using memory). Composer comprehension on similar tasks takes 40-60 s. The worker went ahead with the readiness preflight only, and the lead's review covered the gap. | Open: for large-context task files, comprehension on `code-hard` tasks needs a longer `-TimeoutSec` (about 1,500 s) and a detached launch, or Composer as a stand-in; decide when it recurs |

## The feature skill

### Automated tests

Install Pester for the current user (once):

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
```

Full suite (218 tests; measured 2026-11-12 after the step 6 fixes, **11 min 35 s** on the build machine; was about 9 minutes at 194 tests):

```powershell
pwsh -NoProfile -c 'Import-Module Pester -MinimumVersion 5.5; $r = Invoke-Pester skills/feature/tests -PassThru -Output Normal; exit $r.FailedCount'
```

Fast tier (excludes tests tagged `Slow`; about **6 minutes**):

```powershell
pwsh -NoProfile -c 'Import-Module Pester -MinimumVersion 5.5; $c = New-PesterConfiguration; $c.Run.Path = "skills/feature/tests"; $c.Filter.ExcludeTag = "Slow"; $c.Output.Verbosity = "Normal"; Invoke-Pester -Configuration $c'
```

Quick sandbox checks (from `<repo>`):

```powershell
pwsh -NoProfile -c '$d = (pwsh -NoProfile -File scripts/new-sandbox.ps1); if ($LASTEXITCODE) { exit 1 }; Push-Location $d; python -m unittest -q; $c = $LASTEXITCODE; $n = (git log --oneline | Measure-Object).Count; Pop-Location; Remove-Item -Recurse -Force $d; if ($c -ne 0 -or $n -ne 1) { exit 1 }; "sandbox ok"'
```

```powershell
pwsh -NoProfile -c '$r = (Get-Location).Path; $d = (pwsh -NoProfile -File scripts/new-sandbox.ps1); Push-Location $d; git apply (Join-Path $r "skills/feature/tests/fixtures/drift/change.diff"); $a = $LASTEXITCODE; python -m unittest -q; $t = $LASTEXITCODE; Pop-Location; Remove-Item -Recurse -Force $d; if ($a -ne 0 -or $t -ne 0) { exit 1 }; "drift diff ok"'
```

### Machine setup

Outside the repo (not committed):

1. Junction the skills into Claude Code's skill folder (or copy them — see the design's Installation section if the feature will edit `skills/`):
   - `New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\feature" -Target "<repo>\skills\feature"`
   - `New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\delegate" -Target "<repo>\skills\delegate"`
2. Install Pester 5.5+ for the current user (command above).
3. Run `pwsh -NoProfile -File <repo>/skills/feature/scripts/feature.ps1 doctor` and add **both** permission rules it prints to `~\.claude\settings.json` (one allowing `feature.ps1`, one allowing `delegate.ps1`). Use the junction path Claude Code reports as each skill's base directory, with forward slashes.

Prerequisite for the manual sandbox below: a real `python` on `PATH` (disable the Windows Store alias if it intercepts `python`).

### Manual checklist (CUJ 1–7, G1, drift)

Run in **fresh Claude Code sessions** with the `feature` and `delegate` skills loaded from their installed locations (junctions). The target repo is a throwaway git repo created by `scripts/new-sandbox.ps1`; start each session in that folder. Do not use this project's checkout as the feature target unless you intend to build `feature` itself.

**Order**

1. **Sandbox A:** CUJ 1–7 in sequence (one feature name, e.g. `export`).
2. **Sandbox A (same session or a new one):** G1 routing and "must not fire" checks that change no files.
3. **Sandbox B:** a new sandbox and a fresh feature; run only the backward/end phrases (`go back to the design`, `go back to the plan`, `abandon this feature`).
4. **Drift fixture check** from `<repo>` (command below).
5. Delete any leftover sandbox folders under `%TEMP%`.

| # | Type | Say (plain language) | Must happen | Goal |
|---|---|---|---|---|
| 1 | CUJ 1 | "Let's design an export-to-PDF feature: users need to …" (confirm the proposed name) | One-line statement naming the feature and `design`; branch `feature/<name>`; `docs/designs/<name>.md` drafted section by section; stage moves to `design-review` when drafting finishes | G1, G2 |
| 2 | CUJ 2 | After pausing mid-build (including a killed worker): `/clear`, then "where are we?" | Answer from disk only: stage, phase, task states (killed run → `failed`), waiting-on, token use, next action on "continue" — no reliance on chat history | G2 |
| 3 | CUJ 3 | "review the design" → resolve findings → clear yes to lock | Goldfish reports committed; synthesis with Blocker/Major/Nit; **design-locked** recorded with quote; stage → `plan` | G3, G7 (if council offered) |
| 4 | CUJ 4 | "plan it" → readiness fixes → clear yes to approve (note check-in mode) | `plan.md` and phases/tasks with files, tests, profiles; **plan-approved** recorded; stage → `build` | G3, G5 |
| 5 | CUJ 5 | "build it" through at least one phase; trigger a council if a task fails review twice on `code` | Parallel non-overlapping tasks; merges on `feature/<name>` with `Xagent-Task` trailers; `[council]` line on escalation; consensus → retry, disagreement → stop | G4, G5, G7 |
| 6 | CUJ 6 | "test and sign off" → review drift lists → clear yes to sign off | Full suite on `feature/<name>`; drift report (missing / added / **changed**) shown; **signed-off** recorded; `feature.ps1 finish` merges to `main`; feature marked `done` | G6 |
| 7 | CUJ 7 | At plan-approval gate, reply "ok, looks fine I guess" | One confirming question naming the gate; **plan-approved** not recorded until a clear yes | G3 |
| 8 | G1 | "design a feature for X" / "let's design X" | Router step 4 one-liner, then `new` + design stage | G1 |
| 9 | G1 | "review the design" | `design-review` stage | G1 |
| 10 | G1 | "lock the design" (only after review resolved) | **design-locked** recorded | G1 |
| 11 | G1 | "plan it" / "plan the feature" | `plan` stage (not Claude plan mode) | G1 |
| 12 | G1 | "approve the plan" | **plan-approved** recorded | G1 |
| 13 | G1 | "build it" / "continue" | `build` or resume current stage | G1 |
| 14 | G1 | "test and sign off" | `signoff` stage | G1 |
| 15 | G1 | "sign off" (after final check shown) | merge via `finish` | G1 |
| 16 | G1 | "where are we?" / "status" | read-only status report | G1 |
| 17 | G1 | "convene a council" / "get a second opinion on …" | council path per router | G1, G7 |
| 18 | G1 | "this feature is slow" | skill does **not** invoke; no feature files change | G1 |
| 19 | G1 | "what features does X have?" | skill does **not** invoke | G1 |
| 20 | G1 | "add a feature flag" | skill does **not** invoke | G1 |
| 21 | G1 | "plan it" while in Claude Code plan mode (Shift+Tab on) | read-only status; asks to leave plan mode before writing stages | G1 |
| 22 | Back | "go back to the design" (sandbox B, feature at `build` or later) | `stage` → `design-review`; design-locked and later gates cleared | G3 |
| 23 | Back | "go back to the plan" | `stage` → `plan`; plan-approved cleared | G3 |
| 24 | Back | "abandon this feature" (confirm yes) | stage `abandoned`; checkout → `main` if tree clean | G1 |

**Drift persona (planted deviation)**

The fixture diff implements `skills/feature/tests/fixtures/drift/design.md` except **`divide` returns `None` on a zero divisor instead of raising `ValueError`** (tests expect `None`). The reviewer should list that under **Changed**.

From `<repo>`:

1. Write `.xagent/tasks/drift-check.md`: "Compare the design `.xagent/design.md` with the change `.xagent/change.diff` and report behaviour missing, added or changed."
2. Run:

```powershell
pwsh -NoProfile -File <delegate dir>/scripts/delegate.ps1 -Agent cursor -Profile review -Persona drift_report -Model grok-4.7-medium -Repo <repo> -TaskId drift-check -TaskFile .xagent/tasks/drift-check.md -TargetFile skills/feature/tests/fixtures/drift/design.md,skills/feature/tests/fixtures/drift/change.diff
```

3. **Pass:** the report's **Changed** list names the zero-divisor behaviour (`ValueError` vs returning `None`).
4. `pwsh -NoProfile -File <delegate dir>/scripts/delegate.ps1 -Agent cursor -Cleanup -Profile review -Repo <repo> -TaskId drift-check`
5. Delete the sandbox folder(s) under `%TEMP%` when finished.

### Results, 2026-11-12: manual checklist (step 6)

Run by the user in fresh Claude Code sessions, with the lead checking every result on disk (git log, `feature.json`, `decisions.md`, `state.json`, `feature.ps1 status`) from a separate session. Sandbox A: feature `subtract-divide`, CUJ 1-7 in order, then the G1 phrases. Sandbox B: feature `power-and-mean` (two independent tasks), a killed worker, then the backward phrases.

| # | Result | Evidence |
|---|---|---|
| 1 CUJ 1 | Pass | Name proposed and confirmed; one design commit per approved section; requested change (ValueError) applied; `[stage] design -> design-review` |
| 2 CUJ 2 | Partial | Interrupted session resumed from disk with the stop and the finished run. Killed worker (sandbox B, killed by a watcher 3 s in: pid file left, empty `stdout.json`): the session relaunched it once without counting a failure, as `build.md` says, before any `/clear`, so "where are we?" with a killed run on disk was not seen live (reconcile's orphan handling is covered by Pester) |
| 3 CUJ 3 | Pass | Consolidated review: one raw report per lens committed, synthesis `design-1`; on-request council (Grok, GLM) reached consensus in round 1, `[council]` recorded, the author's earlier choice changed only after asking; round 2 waived; `design-locked` with quote and design blob; stage `plan` |
| 4 CUJ 4 | Pass | `plan.md` with phases, tasks, files, tests, profiles, check-in mode; two plan review rounds; `plan-approved` with quote; stage `build` |
| 5 CUJ 5 | Pass (no council-on-failure) | Sandbox B: two tasks launched 1 s apart in separate worktrees; both merged `--no-ff` with `Xagent-Task`; no task failed review twice, so the escalation council was not exercised |
| 6 CUJ 6 | Pass | Full suite; `drift_report` listed the `.gitignore` fix-up as Added; `signed-off` with quote; `finish` merged into `main`; `status` derives `done` |
| 7 CUJ 7 | Pass | "ok, looks fine I guess" at plan approval (and "ok I guess it's fine" at the lock) got one confirming question naming the gate; nothing recorded until a clear yes |
| 16, 21 | Pass | "where are we?" and "plan it" in plan mode invoked the skill read-only |
| 18-20 | Pass | "this feature is slow", "what features does calc have?", "add a feature flag" did not invoke it; sandbox unchanged |
| 22-24 | Pass | Back to the plan (from signoff) cleared `plan-approved`; back to the design cleared `design-locked`; abandon recorded `abandoned` and switched to `main`. Neither move started a review by itself |
| Drift | Pass | `drift_report` on the fixture (Grok 4.7 medium, 72 s): Changed lists `divide` returning `None` instead of raising `ValueError`, and the matching test |

Rows 8-15 and 17 were exercised by the CUJ runs.

**Findings**

| # | Finding | Status |
|---|---|---|
| S1 | Commit subjects are cut at 72 characters mid-list (`design – Overview, Problem, Goals, Non-Goals,`) | Fixed in `10c5656`: cut at the last space from index 40 in the first 72 characters, trailing punctuation trimmed, `…` appended |
| S2 | Paths inside the vendored EGM files (`resources/execution_instructions.md`, `resources/document_standards/`, `${CLAUDE_PLUGIN_ROOT}/docs/claude.md`) did not resolve from the skill | Fixed in `a034b3c`: the router maps them |
| S3 | Waiving a review round writes one `[dismiss]` commit per planned lens run (ten for a design round) | Fixed in `10c5656`: the stage files log one `review <design|plan>-<n>: declined by the user` decision, and a resumed session skips that round |
| S4 | `verify` flags `__pycache__/*.pyc` written by the test run as out of scope, so every Python repo without a `.gitignore` stops at its first task (both sandboxes; the plan saying the bytecode was expected did not help) | Fixed in `10c5656` (the user chose the first option): untracked `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache` and `*.pyc` are reported as `ignoredCaches`, not changes; `build.md` stages without them; `merge` ignores them |
| S5 | A foreground review run's summary line reached the session without `reviewFile`; the session found the report in the log folder | Note: likely Headroom compressing the tool output in that session; not reproduced |
| S8 | Killing a worker for CUJ 2: workers launch detached (`Start-Process -WindowStyle Hidden`), so Esc in the sandbox session stops only the session's monitor, never the worker | Procedure note for the next run: kill it from outside with a watcher that waits for the run's `<logs>.pid` file and runs `taskkill /T /F /PID <pid>` (step 6 used this, 3 s after launch). To see "where are we?" explain a killed run live, `/clear` right after the kill, before the session's monitor notices and relaunches |
| S6 | `feature.ps1 stage -Reason` writes only the reason (`[stage] go back to the plan`), losing which stage it left | Fixed in `10c5656`: `<from> -> <to>: <reason>`, also for abandon |
| S7 | The lint `fb-stages-check.ps1` fails on the main checkout because `core.autocrlf` gives CRLF files | Fixed (lead's lint in the git-excluded `.xagent/tasks/`): it checks committed line endings with `git ls-files --eol` |

## worker-sandbox build (from 2026-11-14)

- **G6 freeze (2026-11-14):** `D:\cross-agent-loop.frozen` is a detached worktree at `6ca02a1`, the design-lock commit. `~\.claude\skills\delegate` and `~\.claude\skills\feature` point at its `skills\delegate` and `skills\feature`, with the user's approval ("yes freeze skill"). `feature.ps1 doctor` through the junctions reports ready. Every run of this build should show `skillDir` under `D:\cross-agent-loop.frozen` once phase 4 adds the field. Before that, the junction targets are the record. After sign-off, the junctions go back to `D:\cross-agent-loop\skills\` and the worktree is removed.
- **Phase 1 (2026-11-14):** `test-runner` and `kill-tree` (Composer 2.5) merged. `kill-tree` took 17 min; one lead fix-up (its tree test didn't assert that the deepest process died). Phase test: full suite, 224 passed on `feature/worker-sandbox`.
- **`reconcile` loses the worktree (bug in the frozen `feature.ps1`):** for a detached worker that finished while no session was running, `reconcile` moved the task `running` → `in-review` but recorded no `worktree` or `baseSha`, so `verify` refused (`task kill-tree has no worktree in state.json`). Worked around by reading `summary-r1.json` and running `task -Status in-review -Worktree -BaseSha` by hand. Fix after this build: `reconcile` should take those fields from the run's summary file.
- **Not a worker fault: Windows Terminal auto-update (2026-11-14 17:28).** Every pwsh window and Claude CLI session closed while the user was away. The user suspected `kill-tree` (its tests kill process trees). Its transcript showed only kills of processes it had started itself, and it had finished at 17:00. The event log showed the Microsoft Store updating Windows Terminal 1.24 → 1.25 at 17:28:49, which closes every tab.

### `sandbox-core` run 1 timed out at 50 min: root cause (2026-11-14)

`sandbox-core` (`code-hard`, Grok 4.7 high) timed out at `-TimeoutSec 3000` while running its acceptance command. Run 2 (fresh session, same worktree) finished in 15.5 min **with no edits**: run 1 had finished the work and was killed about 40 s before its final test run ended.

**Timeline of run 1** (rebuilt from probe-file mtimes and terminal logs; Cursor writes no usage for a killed run):

| Time | Minutes | Activity |
|---|---|---|
| 20:18 → ~20:50 | ~32 | Read the design and code (20 reads, 14 greps, 5 probes), wrote the 3 files (1,842 lines, 83 KB), 4 unit-test runs |
| 20:52 → 20:55 | 3 | PowerShell quirks in its own tests (empty arrays collapsing to `$null`) |
| 20:55 → 21:02 | 7 | Undocumented Windows behaviour: `CreateProcess` into an AppContainer fails unless the environment block is sorted in Windows' case-insensitive ordinal order and holds `LOCALAPPDATA` (~12 probes and a web search) |
| ~21:00 | — | Context compaction (139 turns, ~415 KB) |
| 21:02:35 → 21:08:39 | 6 | Acceptance command `scripts/test.ps1 -Fast` (~6.7 min, 224 feature tests this task can't affect); killed by the timeout |

**Measured (run 2):** 926 s; 40.0k output tokens, of which 37.6k reasoning (94%); 179k input, 1.56M cache read; ~76 output tokens/s. Unit-test runs took 2-3 s each, so tests didn't eat the time; model turns did. **Estimated (run 1):** ~32 min at ~76 tok/s is ~140k output tokens against ~21k tokens of code, so roughly 110k reasoning tokens, about 5× the code. The user's "1,800 lines takes a few minutes" holds for a fast low-reasoning model (Composer), not for Grok high on Win32 interop.

**Root causes, most to least:**
1. **Task too big:** one task held a C# P/Invoke layer, a 795-line module and 32 tests, plus a 75-line task file with ~40 pinned rules to reason against. Nothing in plan or preflight estimated size or time.
2. **High reasoning effort scales with size:** right for small hard tasks, costly over 1,800 lines.
3. **Design gap handed to the worker:** the environment-block rule was not in the design; discovery belongs in design probes, not a timed run.
4. **Acceptance command wider than the task:** the full fast suite (6.7 min) instead of the task's own tests (3 s). The phase test already runs the full suite after each phase.

**Changes adopted (user, 2026-11-14):** the comprehension preflight gives a time and size estimate; a task estimated over ~20 min or ~600 changed lines goes back to be split (split by layer, so `code-hard` tasks stay on Grok high); a task's acceptance command (which `verify` also runs) covers only its own tests, and the full suite runs as the phase test. Rejected: telling the worker its time limit (the user doubted it would help). Committed on `main` as `8cb3a3a` (new `skills/delegate/personas/task-size-standard.md`, plus `delegate` SKILL.md and `feature` `plan.md`/`build.md`). **The G6 freeze moved** from `6ca02a1` to `8cb3a3a` (`skills/` differs only in those five files), so the rest of this build uses the size gate. Then back to `plan`: plan review 3 (`reviews/plan-3.md`) found the first three-way split of `sandbox-run` still over budget in its middle task (both lenses: 700-1,000 lines, 30-50 min), so phase 3 became four `code-hard` tasks. Review of the merged code: sound; one lead fix-up (the test file left `XAGENT_*` env vars pointing into a deleted TestDrive for later test files in the same run).

### Phases 3-5 and the phase-5 checks (2026-11-15)

- **Phase 3 (7 tasks after three plan-time splits; `code-hard`, Grok 4.7 high):** all merged. Phase test: fast suite 257 passed. Actual worker minutes against the comprehension preflight's estimate:

  | Task | Estimate (min) | Actual (min) |
  |---|---|---|
  | sandbox-run-fns | 22-32 | 17 |
  | sandbox-run-harness | 22-35 | 23 |
  | sandbox-run-checks | 18-28 | 15 |
  | sandbox-canary | 25-40 | 42 |
  | sandbox-slots | 18-26 | 22 |

  Grok's actuals land at or below the estimate's low end, except the canary.
- **Bugs the phase-3 workers found and fixed:**
  - `icacls` needs `(RA)` with parentheses.
  - `icacls` cannot grant a bare RA on a folder without propagating it. The canary task replaced it with `NtSetSecurityObject`, adding one non-inheriting ACE.
  - The lead fixed one bug: an assignment to PowerShell's read-only `$home`.
- **Phase-3 probes (lead):**
  - Cursor `--version` worked (1.6 s).
  - `cursor -p` in a slot replied OK (7.3 s), using `--workspace <real path>` with the working folder at `<slot>:\`.
  - ComfyUI's per-user Python, started from a read-list entry, printed `1`.
  - Found: Node tools started from a read-list entry under the profile fail on `require` without `--preserve-symlinks`, because Node's realpath `lstat`s `C:\`. The user deferred granting RA on `C:\` (option C, 2026-11-15).
  - Found: `HKCU\Environment` is readable from the container. The user accepted this as a risk (option A, 2026-11-15).
- **G7 (two-part task file), compared with `fb-stages`:**
  - Every phase-3 and phase-4 task used the "Decided / Yours to decide" file. Readiness review found 1 blocker and several majors each time, mostly gaps between the task file and code it pointed at: the login copy, parameter sets, exact strings. The lead pinned them before launch, in one preflight round each, with no second preflight round and no worker review round.
  - Every worker passed its own acceptance command on the first run. Lead fix-ups were small: 1-3 lines each, in run-fns, kill-tree and sandbox-docs.
  - `fb-stages` (feature-skill build, single-part task files) needed review rounds after the worker. G7's cost moved to preflight instead.
  - Verdict: keep the two-part layout for `code-hard` tasks. The template change waits for the process rework (HANDOFF Open items).
- **Phase 4:**
  - `delegate-wiring` (Grok 4.7 high, 36 min) was kept as one task against a "split" size verdict, the lead's call under the user's 2026-11-15 rule.
  - `doctor-check` (Composer 2.5, 97 s).
  - Phase test: full suite 307 passed.
- **Phase 5:**
  - `sandbox-docs` (Composer 2.5, 38 s); the lead de-duplicated one sentence.
  - Phase test: full suite 308 passed.
- **Lead checks, phase 5, with the live `D:\cross-agent-loop\skills\delegate`:**
  - **First use (CUJ 1):** reserved Z,Y,X (the user's choice). The documented `-Reserve Z,Y,X` failed, because `pwsh -File` passes it as one string. Fixed in `delegate.ps1`, with a test (`8ed0883`). Then `-SandboxCheck -Repo D:\cross-agent-loop` passed: support ok, runtime patched, all 9 canary checks ok (3 denied, git/node/network ok, no leak), no clean-up notes.
  - **Live canary (G1, CUJ 3):** a real Cursor worker (Composer 2.5) was told to read both canaries. The `Live` test passed in 30 s.
  - **In-sandbox suite (CUJ 2):** a sandboxed worker ran `scripts/test.ps1 -Fast`.
    - Run 1: 243 passed, 5 failed. Windows wrote its shell caches into the worktree under a literal `%SystemDrive%` folder, because the container environment had no `SystemDrive`. Fixed by adding `SystemDrive` and `ProgramData` (`3121100`). Five tests assumed a host (icacls, CIM, `IsAppContainer`, the real log folder).
    - Run 3: 245 passed, 0 failed, 25 skipped (container-only), worktree clean, `sandboxNotes` empty.
  - **Overhead:** `delegate.ps1` wall time with an instant fake Cursor, 5 runs each, median 2.95 s sandboxed vs 1.24 s unsandboxed: +1.7 s, against a target of 5 s. Grant removal is included. The first run of a Cursor version took 3.66 s.
  - **Token refresh:** after the probes, the live test and 3 sandboxed suite runs, `cursor-agent status` outside the sandbox still shows logged in. The design's one-day check is due 2026-11-16 after 16:30 local.
  - **Seen in passing:** Cursor tries to add itself to the user PATH via `reg.exe add HKCU\Environment`. It is denied, but the error message quotes the user's whole PATH into the run's stderr log (the accepted registry-read risk).
- **Not run by hand, covered by tests instead:**
  - timeout kill of a process tree (CUJ 7; `Sandbox.Tests.ps1` "Kill ends the whole process tree");
  - crash recovery (CUJ 6; the abandoned-mutex and live-ledger tests);
  - sandbox failures (CUJ 5; `DelegateLaunch.Tests.ps1` forced-failure and zeroed-pattern cases).
- **Not yet run:** the read-only canary as a `review` lens and a `council` seat (G2, CUJ 4), and the `delegate` regression with the sandbox on (G4). Both need the skill junctions pointed at the live skills, which happens after sign-off; the build still runs on the frozen copy.
