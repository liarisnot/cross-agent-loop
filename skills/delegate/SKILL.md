---
name: delegate
description: Delegate coding subtasks from Claude Code (as lead programmer) to Cursor CLI worker agents running locally in isolated git worktrees, then review, iterate and merge their work; run read-only goldfish reviews with other model families (Grok, GLM, DeepSeek); or convene a read-only multi-model council (Grok + GLM + Claude) on a design decision and escalate unresolved disagreements to the user. Use when the user asks to delegate, farm out, or parallelize work to Cursor or "other agents", run the cross-agent dev loop, or get a second/third opinion from other models.
---

# delegate: cross-agent dev loop

You are the **lead**. You plan, split the work, delegate, review and merge. Workers are Cursor CLI agents. They run headless, with full tool permissions, but **only** inside a dedicated git worktree created by `scripts/delegate.ps1`.

**Never call `agent` directly with `--force`. Always go through the script.** Only the script is allow-listed.

**Antigravity (`-Agent agy`) is disabled.** Google's FAQ forbids wrapping `agy` inside third-party agents, Claude Code included, on consumer plans (T0 in `docs/test-plan.md` of the cross-agent-loop repo). The script refuses it unless `models.json` sets `agy.enabled: true`, which is kept only for a possible API-key setup later. Every role runs on `-Agent cursor`.

## Invocation

`<skill dir>` below is the base directory Claude Code reports when this skill loads, with forward slashes. Use the **Bash** tool:

```bash
pwsh -NoProfile -File <skill dir>/scripts/delegate.ps1 -Agent cursor -Repo D:/path/to/repo -TaskId short-kebab-id -TaskFile D:/path/to/repo/.xagent/tasks/short-kebab-id.md
```

| Param | Notes |
|---|---|
| `-Agent` | `cursor` |
| `-Repo` | top level of the target git repo |
| `-TaskId` | `^[a-z0-9][a-z0-9-]{0,48}$`; becomes the branch `xagent/<id>` and the worktree `<repoParent>/<repoName>.xagent/<id>`. Read-only runs use a detached worktree `<id>-<Seat or agent>` |
| `-TaskFile` | markdown task description (see below) |
| `-Base` | starting ref for a new worktree (default `HEAD`) |
| `-Resume` | `sessionId` from a previous run, to continue the same conversation |
| `-Profile` | `code` (default), `code-hard`, `review` or `council`; picks the model from `models.json` (see below) |
| `-Persona` | with `-Profile review`: `implementation_readiness`, `comprehension`, `design_critic`, `zoom_out`, `inventive_catalyst`, `codebase_details`, `structural`, `style` or `drift_report` (goldfish personas in `personas/`) |
| `-Standard` | with `-Profile review`: a standard file in `personas/` to append. Without it, the persona's default from `personas/standards.json`; with neither, none |
| `-Model` | overrides the profile's model. Claude models and Cursor `auto` are **blocked** |
| `-Seat` | `^[a-z0-9]+$`. Names a read-only run's worktree and logs (`<id>-grok`, `<id>-glm`), so two runs with one id don't collide. With `-Profile council`, it also picks the seat's model |
| `-TargetFile` | `<path>[,<path>]`: files not in the commit (a diff, a draft) copied into the worktree's `.xagent/`; the prompt names them |
| `-KeepRuleFiles` | read-only runs remove `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.cursor/` and `.agents/` (at any depth) so the reviewer doesn't load project instructions. Pass this when rule files are part of what's reviewed |
| `-Feature` | the `feature` skill's feature name, written to `runs.jsonl` and the pid file |
| `-TimeoutSec` | default 900; the process tree is killed on timeout. **A timed-out run loses its session** (Cursor writes `session_id` and usage only at the end), so it can't be resumed: size this to the work, counting how long the test suite takes. To continue after a timeout, rerun the same `-TaskId` without `-Resume`: the worktree and its uncommitted changes are reused; hand over the original task with `-TargetFile` and say what's left |
| `-Cleanup` | removes the worktree and deletes the branch only if it's merged; also removes every read-only worktree `<TaskId>-<label>`, restoring rule files first. Pass `-Repo` |
| `-Cleanup -Discard` | throws away an **unmerged** worker branch (e.g. a failed attempt), saving its diff as a patch in the run logs first |
| `-NoSandbox` | run Cursor outside the AppContainer (only when the user asks) |
| `-SandboxCheck` | check sandbox support; with `-Repo` runs the canary; use `-Reserve` or `-Release` to manage drive letters |
| `-Reserve` | three drive letters, comma-separated (`D`–`Z`); the first is the runtime letter, the other two are slots |
| `-Release` | remove reserved letters, slot containers and the runtime cache (only when the user asks) |

To run workers in parallel, issue several Bash calls in one message, each with its own `-TaskId` (or the same id with different `-Seat`s for read-only runs). Set the Bash tool `timeout` above `-TimeoutSec`. Short runs (preflights, reviews) can stay in the foreground.

**Long runs (workers): launch detached.** Claude Code can stop its own background tasks when the machine is low on memory, and that kills `delegate.ps1` and the worker with it: no `finally`, no session id, a stale pid file (D16 in the cross-agent-loop test plan). A process started with `Start-Process` is not part of that task tree, so it survives. With the PowerShell tool:

```powershell
$runs = '<repo>/.xagent/runs/<taskId>'; New-Item -ItemType Directory -Force $runs | Out-Null
$a = @('-NoProfile','-File','<skill dir>/scripts/delegate.ps1','-Agent','cursor','-Repo','<repo>','-TaskId','<taskId>','-TaskFile','<task.md>','-TimeoutSec','3000')
$p = Start-Process pwsh -ArgumentList $a -WindowStyle Hidden -RedirectStandardOutput "$runs/summary.json" -RedirectStandardError "$runs/launcher.err.txt" -PassThru; $p.Id
```

A detached run sends no signal when it ends, so **start the wait in the same message as the launch**, never in a later turn: a result nobody waits for sits unreviewed (it did for about an hour on 2026-11-15). Use one Bash call with `run_in_background`, which notifies you once when it exits:

```bash
f=<repo>/.xagent/runs/<taskId>/summary.json; until [ -s "$f" ] || ! powershell.exe -NoProfile -c "if (Get-Process -Id <pid> -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >/dev/null 2>&1; do sleep 20; done; if [ -s "$f" ]; then echo DONE; else echo "LAUNCHER GONE, no summary"; fi
```

For two workers, one call can wait for both (loop until each has a summary or a dead launcher). "LAUNCHER GONE" means the run died without a summary: read `launcher.err.txt` and the run logs. The summary file holds the same JSON line as a foreground run. A detached worker keeps running if Claude Code exits; stop it early with the pid in `<logs>.pid`. Use a new summary file name per round so an old one isn't read as the new result.

The script prints **one compact JSON line**: `ok, violation, profile, model, usage, agent, seat, feature, taskId, worktree, branch, baseSha, exitCode, timedOut, seconds, cliStatus, sessionId, result, reviewFile, changes, diffStat, stderrTail, logs, sandboxed, sandbox, skillDir, sandboxNotes`. `baseSha` is the commit the worktree was created from (diff against it). `sandboxed` is true or false. `sandbox` holds container, slot, runtime letter and version, and whether `node.exe` was patched. `skillDir` is the folder `delegate.ps1` ran from. `sandboxNotes` lists clean-up steps that failed, and is empty when all went well. Full logs are in `<repo>/.xagent/runs/<taskId>/`. While a run is live, `<logs>.pid` holds `{pid, startTime, childPid, childStartTime, feature}`.

**Worker environment.** For sandboxed runs the environment is built from scratch with only the variables a run needs, so no secret variable reaches the worker. The denylist still applies to `-NoSandbox` runs. The network and the user's registry, including user environment variables, stay reachable, so never give workers anything secret there.

## Models (`models.json`)

| Profile or seat | Model | Use for |
|---|---|---|
| `code` | `composer-2.5` | well-specified tasks that follow your task file (the default) |
| `code-hard` | `grok-4.7-high` | tricky bugs, bigger refactors, or a task that failed review twice on `code` |
| `review` | `composer-2.5` | **read-only** goldfish review with `-Persona`; comprehension preflight |
| `council` seats | `grok` → `grok-4.7-high`, `glm` → `glm-5.2-high` | **read-only** deliberation (see Council below) |
| `seats.readiness` | `deepseek-v41-flash-1017-medium` | `implementation_readiness` reviews (pass it with `-Model`) |
| `seats.judgement` | `grok-4.7-medium`, `glm-5.2-high` | judgement lenses (`design_critic`, `zoom_out`, `style` …; pass with `-Model`) |

Cursor's plan has two monthly pools: Cursor models (Composer, Grok) and other models (GLM, DeepSeek). The user doesn't want Claude models used through Cursor: Claude is already the lead, and it's expensive there. Never pass `-Model claude-*` or `auto`; the script refuses them. Edit `models.json` to change the mapping.

## The loop

1. **Plan.** Break the work into tasks as [Breaking work into tasks](#breaking-work-into-tasks) says. Keep anything security-sensitive for yourself.
2. **Write a task file** for each subtask at `<repo>/.xagent/tasks/<taskId>.md` (`.xagent/` is git-excluded by the script). Include:
   - **Goal**: one or two sentences.
   - **Scope**: files and dirs it may touch, and what it must not touch.
   - **Constraints**: no new dependencies, follow existing style, etc.
   - **Acceptance criteria** and the **exact test command**. You'll run it from Bash, so quote PowerShell one-liners with single quotes (`pwsh -NoProfile -c '…$r…'`); in double quotes Bash expands `$` first. For a longer check, write a `.ps1` and hand it over with `-TargetFile` (the worker runs `pwsh -NoProfile -File .xagent/<name>.ps1`).
   - If the task adds a helper nothing can call yet, have it tested against a stub, or its bugs wait for the next task.
   - If the test suite is slow (minutes), give the worker a command that runs a subset while iterating (for Pester, a `New-PesterConfiguration` with `Filter.FullName`), and say to run the full suite once at the end.
   - Relevant context: interfaces, gotchas, links to code.
   - **Goldfish preflight** (see below) for anything beyond a trivial task.
3. **Delegate** with the script. Start with `-Profile code`; escalate to `code-hard` only when needed. If a worker reports a usage limit, stop and tell the user (there is no second provider).
4. **Review. Never trust the worker's `result` summary on its own.**
   - Read the actual diff in the worktree, **one file at a time** (`git -C <worktree> diff <baseSha> -- <file>`, plus untracked files from `changes`). Headroom compresses large tool outputs, so a whole diff at once may arrive cut short. If you see a compression marker (`[... compressed ...]`, `[↑NL same as …]`, `<<ccr:…>>`), read smaller chunks.
   - Rerun the test command yourself inside the worktree.
   - Check that the change stays within scope.
5. **Iterate if needed.** Write `<taskId>.review-N.md` with specific, actionable feedback and rerun with the same `-TaskId`, `-TaskFile <review file>` and `-Resume <sessionId>`. Stop after about 3 rounds and do it yourself or rethink the split. If the next round starts a **fresh** session (no `-Resume`, e.g. after a timeout), the follow-up file is the whole task for a worker with no context: give it the comprehension preflight first, and readiness too if it changes scope.
6. **Merge.** Commit in the worktree on the `xagent/<taskId>` branch (you write the commit message), then `git merge` it into the main branch from the main checkout. Resolve conflicts between parallel tasks yourself. (The `feature` skill merges with `--no-ff` and an `Xagent-Task: <id>` trailer, which its records read.)
7. **Cleanup** with `-Cleanup -Repo <repo>`. Tell the user what each worker did, what you changed during review, and anything left open.

## Breaking work into tasks

This applies whether the work is one issue or a whole design the user already wrote. The user owns scope and priority; how the work is cut into tasks and handed to workers is your call as lead.

**Start from the design.** List what changes, by component and file. Mark the interfaces other code depends on (signatures, data formats, file layouts): those are what tasks hand to each other, so they must be fixed in the task files before parallel tasks start. Anything the design leaves for someone to discover (undocumented platform behaviour, a protocol to probe) gets probed first, by you or by a small probe task, never folded into a timed task.

**What makes a good task.**
- One cohesive outcome, with its own files (the task file's Scope) and its own narrow test command that proves it.
- Testable on its own. A helper nothing calls yet is tested against a stub.
- About 20 worker minutes or 600 lines of code and tests at most. Past that, high-reasoning models (`code-hard`) slow down sharply (a 1,840-line `code-hard` task took about 44 minutes on 2026-11-14). Calibration is in `personas/task-size-standard.md`.
- **Size alone is never the reason to split.** Split along a **seam**: a point where one part's output is a stable interface for the next (native layer, then the module functions that call it, then the integration), or between parts that are independent (two unrelated bugs). A cohesive unit whose halves cannot be tested apart (a harness and the one test that proves it) stays one task, even when big.
- Split rather than drop a `code-hard` task to a cheaper model.
- Small edits, a few lines in one or two files, are cheaper to make yourself than to write a task file for.

**Order and parallel runs.**
- Interfaces before their callers: a task starts only when the tasks it depends on are merged.
- Run at most **2 runs at once**, workers, preflights and reviews together: there are two sandbox slots, and a third sandboxed run fails with `sandbox: no free slot (both slots busy)`. They also share one Cursor allowance. Two tasks run in parallel only when their files don't overlap and neither depends on the other; launch both in one message, each with its own wait. Otherwise run them one after another.
- After each batch is merged, run the full test suite once. Task test commands only cover their own change.

**Write the breakdown down** when there are more than about three tasks: a short list in `<repo>/.xagent/tasks/plan.md` with each task's id, files, test command, profile and what it depends on. It is your working plan: it lets you resume after a lost session and shows the user the shape of the work. Change it freely as you learn.

**Re-splitting is normal.** A preflight `split` verdict, a worker that times out, or a task that turns out bigger than it looked: split it along a seam, or keep it whole and say why. That is your decision and needs no approval. Stop for the user only when **scope or cost** grows: the design must change, the work needs files or behaviour the design didn't cover, or it looks much bigger than expected (roughly half again). Present that as a priority choice, each option with its cost (do it now, defer it, or cut something else), not as a yes/no on your plan.

The `feature` skill builds on this section: it records the breakdown as a plan with phases and gates, and its `schedule` command enforces the order and parallel rules.

## Goldfish preflight & review (from Google's Elephant-Goldfish Model)

You're the *elephant*: you hold the whole conversation's context, so you can't see what your task file leaves unsaid. The workers are *goldfish*: they see only the task file. Before delegating, have a goldfish with no context check the task file:

```bash
pwsh -NoProfile -File <skill dir>/scripts/delegate.ps1 -Agent cursor -Profile review -Persona comprehension -Standard task-size-standard.md -Repo <repo> -TaskId <id>-pc -TaskFile <task.md>
pwsh -NoProfile -File <skill dir>/scripts/delegate.ps1 -Agent cursor -Profile review -Persona implementation_readiness -Model deepseek-v41-flash-1017-medium -Repo <repo> -TaskId <id>-pr -TaskFile <task.md>
```

- **When:** tasks touching more than two files, `code-hard` tasks, and interface or validation changes. Skip it for trivial edits. Measured on real build tasks (2026-11-11): comprehension on Composer takes about 15–30 seconds and 15–30k tokens; readiness on DeepSeek about 100–135 seconds and 100–125k tokens (other-models pool). Readiness is the one that finds real gaps; for a small, mechanical task, comprehension alone is enough.
- **comprehension** paraphrases the task. If its paraphrase doesn't match what you meant, that's the most important finding. **implementation_readiness** applies the "zero-decision rule": does the task leave design choices to the worker?
- **Size gate.** With `-Standard task-size-standard.md`, comprehension also estimates the task's lines, files and worker minutes, and checks that the acceptance command runs only the task's own tests. It also says whether the task is cohesive (whether any cut leaves a part that proves nothing alone). A `split` verdict (over about 20 worker minutes or 600 lines, with a seam) is advice: split along the seam into tasks with their own tests, or keep a cohesive task whole and say why. Size alone is never the reason to split. Big tasks cost far more than their size on high-reasoning models: on 2026-11-14 a 1,840-line `code-hard` task on Grok 4.7 high ran about 44 minutes and hit its timeout (root cause in `docs/test-plan.md`). The estimate is a guess; check it against your own sense of the task.
- **Narrow acceptance commands.** A task's acceptance command runs only the tests for what the task changes (its test file, or a Pester filter). The lead runs the full suite after merging. A worker running a 7-minute suite it can't affect is pure cost.
- The report goes to `reviewFile` (Markdown, findings with Blocker/Major/Nit severity). Read it from the file.
- **Pass a document by path.** Point the task file at a committed file and its line range; the reviewer reads it with its file tools. For anything not committed, use `-TargetFile`.
- **Triage, don't obey blindly.** EGM's standard was written for design docs and over-asks on small tasks (exact helper names, error strings, phase plans, file-level allowlists). Fix findings where two reasonable workers could build *different behaviour or interfaces*. Ignore pure over-specification.
- **When the task points at a document by path,** `comprehension` still judges the task file as if it had to stand alone, and reports "not reproduced here" findings. Those are noise; its paraphrase is the signal. If the paraphrase matches what you meant, the task reads right.
- The script tells reviewers what the harness adds to a worker's prompt (the `result.json` contract), so they shouldn't flag it as missing. If one does, ignore it.
- **Optional goldfish code review:** for risky diffs, write the diff to a file and run `-Profile review -Persona design_critic -Model glm-5.2-high -TargetFile <diff>` (a different model family from the writer). Your own review still comes first.
- Clean up with `-Cleanup -Profile review -Repo <repo> -TaskId <that id>`.

## Benchmark mode: unavailable in v1

The head-to-head benchmark needs a second worker provider, and `agy` is disabled. `benchmarks/bench.py` and its records stay for when one exists. Every delegate run still appends its token usage to `runs.jsonl` in `$env:XAGENT_LOG_DIR`, or `%LOCALAPPDATA%\xagent\` when unset, outside every repo, so usage from private projects is never committed.

## Council: multi-model deliberation (read-only)

Three model families (Claude as lead, Grok and GLM via Cursor) argue a decision. The goal is to surface blind spots and real disagreements, **not** to vote.

**Convene a council when:** an architecture or interface decision is hard to reverse; there are data or security trade-offs; requirements are ambiguous with several reasonable readings; a bug fix has failed twice for reasons you can't pin down; or the user asks for it. **Not** for routine implementation (each seat costs about one judgement-lens run).

1. **Question file:** `<repo>/.xagent/tasks/council-<id>.md` with the context, the decision(s) needed as numbered questions, the options you see, and the constraints. Keep it neutral; don't reveal your preference.
2. **Write your own position first:** `council-<id>.lead.md`, written before reading theirs, so you aren't anchored.
3. **Round 1:** run both seats in one message: `-Profile council -Seat grok -TaskId <id>` and `-Profile council -Seat glm -TaskId <id>` (detached worktrees, plan mode, read-only).
4. **Fact-check:** where members disagree on a *fact*, verify it yourself (run the code, read the docs). Facts are settled by evidence, not by debate.
5. **Round 2:** write `council-<id>.r2.md` containing the verified facts plus all three positions, labelled A/B/C (include your own and note what you concede), and the remaining open questions. Run both again with their own `-Seat` and `-Resume <sessionId>`. Usually 2 rounds is enough; never more than 3.
6. **Synthesize:**
   - **Consensus** (all three agree, or one concedes with a stated reason, `changed_position: true`): adopt it and mention it briefly to the user.
   - **Unresolved disagreement** on a judgment call (values, priorities, risk appetite): **stop and escalate to the user.** Don't break the tie yourself, even if you're 2-to-1.
7. **Escalation brief** (in chat, and saved to `<repo>/.xagent/decisions/<id>.md`):
   - the decision in one line
   - what was agreed (so the user doesn't re-decide it)
   - each side of the dispute: who holds it, the strongest argument, and its main risk
   - what would settle it (a fact about the user's callers, product intent, etc.)
   - your recommendation, clearly labelled as one vote
   - Use AskUserQuestion when the options are crisp.
8. `-Cleanup -Profile council -Repo <repo> -TaskId <id>` removes both seats' worktrees.

Council notes: Grok tends to put a preamble before its JSON (the script extracts it anyway). Headroom may compress long fields in tool output (`<<ccr:…>>`); read the specific fields from the `.stdout.json` log when you need the full text.

## Sandbox

By default every Cursor worker, review lens and council seat runs in a Windows AppContainer. A run can reach:

- its worktree (workers read/write; read-only runs read only);
- that repo's `.git` data needed for `git status` and `git diff` (no `git add`, `commit`, or hooks changes);
- its run home under `<worktree>\.xagent\sandbox` (profile, app data and temp for the slot);
- `C:\Windows` and `C:\Program Files` (Windows grants these to all AppContainers);
- paths on the optional read list in `%LOCALAPPDATA%\xagent\sandbox.json` (per-user toolchains you opt in);
- the network (internet on; the host's `localhost` is blocked).

Everything else on disk is denied, including the user's profile, other repos and other drives.

**First use.** On the first sandboxed run, `delegate.ps1` fails with `sandbox: no drive letters reserved` and suggests three free letters. Ask the user to approve three drive letters, then run:

```bash
pwsh -NoProfile -File <skill dir>/scripts/delegate.ps1 -SandboxCheck -Reserve <a>,<b>,<c> -Repo <repo>
```

That reserves the letters, maps them, creates the slot containers and runs the canary when `-Repo` is set. Retry the original run.

**Release.** Run `-SandboxCheck -Release` only when the user asks. It removes the letter mappings, slot containers and runtime cache, and keeps the read list.

**Read list.** Edit `%LOCALAPPDATA%\xagent\sandbox.json` to add toolchain folders under your profile. Each entry can set `addToPath: true`. Refused entries: the profile root itself; anything under `~\.ssh`, `~\.aws`, `~\.gnupg`, `~\.cursor`, `~\AppData\Roaming` or `%LOCALAPPDATA%\cursor-agent`; anything under the sandbox's own folder; and paths that do not exist. A refused entry fails the run with `sandbox: read-list entry '<path>' <reason>; edit sandbox.json`, and `doctor` reports it first.

**Limits.**

- `taskkill.exe` hangs inside the container; use `Stop-Process -Force` or `.Kill($true)` in scripts.
- SSH git remotes need `~\.ssh`, which is blocked; HTTPS remotes work.
- Host `localhost` services are not reachable unless an admin loopback exemption was granted for a slot (not part of the default setup).
- Workers must not `git add` or `git commit`; the lead commits.

**Node read-list limit.** A Node.js tool started from a read-list entry under the user profile fails on `require`, because Node resolves real paths through `C:\`, which the sandbox cannot read. Run such tools with `node --preserve-symlinks`. Granting read access on `C:\` is deliberately not done.

**Registry reads.** The sandbox does not block reading the user's registry, including user environment variables (`HKCU\Environment`). Do not keep secrets in user environment variables. This is an accepted risk.

**Unsandboxed runs.** Pass `-NoSandbox` only when the user asks. The summary records `sandboxed: false`.

## Rules

- Never delegate secrets, credentials, deploy or publish steps, or anything outside the repo.
- Workers must not commit or push. If one did, review its commits as part of the diff (`git -C <wt> log <baseSha>..`).
- If `ok` is false: read `stderrTail` and the log files, then retry once unless `error` starts with `sandbox:`. That is a setup problem: report it to the user and do not retry.
