Follow `delegate`'s loop (task file, preflight, run, review, iterate, merge, cleanup). This file lists only what differs for feature tasks.

When this file applies: the stage is `build`, or the user said "build it" or "continue" and the stage is `build`.

Read and follow `<delegate dir>/SKILL.md`: "The loop", "Goldfish preflight & review", and the detached launch for long worker runs. Where that file says `<skill dir>`, use `<delegate dir>`.

`feature.ps1 <subcommand>` means `pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 <subcommand>`, and `delegate.ps1` means `pwsh -NoProfile -File <delegate dir>/scripts/delegate.ps1`. `<skill dir>`, `<delegate dir>`, `<repo>` and `<name>` are defined in SKILL.md. Every `feature.ps1` call passes `-Repo <repo> -Name <name>`.

If `status.waitingOn.stop` is set, do not schedule work. Follow [Problem stop](#problem-stop). If `waitingOn.running` lists a task, do not launch it again. `schedule` will not return a `failed` task. When the user says "continue" and a task is `failed` and no `[stop]` is open, ask once whether to retry it. On a clear yes, run `feature.ps1 task -Repo <repo> -Name <name> -Task <id> -Status pending`, then schedule.


## Sandbox environments

Before the first worker of the build, run `delegate.ps1 -SandboxEnv -Repo <repo> -Base feature/<name>`. When `proposal.needsApproval` is true, show `proposal.text` and ask once; then run `delegate.ps1 -SandboxEnv -Repo <repo> -Base feature/<name> -Apply` and report the result in one line.

## Picking tasks

Take tasks only from `feature.ps1 schedule -Repo <repo> -Name <name>`. Read `liveRuns`, `cap` and `tasks`. Each task has `id`, `delegateTaskId`, `profile`, `model` and `files`. When `tasks` lists two, run both in the same message. Do not start a task `schedule` did not return. `code` uses that task's `model` (Composer 2.5, `composer-2.5`). `code-hard` uses that task's `model` (Grok 4.7 high, `grok-4.7-high`). Each task starts on the profile the plan gives it.

## Running a task

1. Write `<repo>/.xagent/features/<name>/<id>.task.md` from `<skill dir>/templates/task.md`. Copy the task's `files` and `test` from `docs/features/<name>/feature.json` exactly.
2. Do [Preflight](#preflight) when `delegate`'s rules call for it. Run `feature.ps1 task -Repo <repo> -Name <name> -Task <id> -Status preflight` before that preflight. Read `task` and `state`.
3. Run `feature.ps1 task -Repo <repo> -Name <name> -Task <id> -Status running` before the worker, then:

```text
delegate.ps1 -Agent cursor -Model <model> -Profile <profile> -Feature <name> -Base feature/<name> -Repo <repo> -TaskId <delegateTaskId> -TaskFile <task file>
```

`<model>` and `<profile>` come from `schedule.tasks`. Workers are long runs: launch them detached, the way `<delegate dir>/SKILL.md` launches long runs, and start the background wait for each in the same message as its launch. Preflights, reviews and council seats stay in the foreground.

4. When the run returns with `ok: true` and `timedOut` is not true, run `feature.ps1 task -Repo <repo> -Name <name> -Task <id> -Status in-review -SessionId <sessionId> -ResultFile <worktree>/.xagent/result.json -Worktree <worktree> -BaseSha <baseSha>`. Take `sessionId`, `worktree` and `baseSha` from `delegate.ps1`'s summary. Omit `-SessionId` when the summary has none. Then do [After each worker run](#after-each-worker-run). A failed run (`ok: false` or `timedOut: true`) follows [Failed runs](#failed-runs) instead, and does not move to `in-review`. A task under council stays `in-review`.

## Preflight

Do this after the task file is written and before the worker command above. Run it when `delegate`'s preflight rules call for it, on the task file, following the cap rule in SKILL.md. Skip a trivial edit. For a small mechanical task, comprehension alone is enough. When both lenses are called for, run:

```text
delegate.ps1 -Agent cursor -Profile review -Persona comprehension -Model composer-2.5 -Standard task-size-standard.md -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <delegateTaskId>-pc -TaskFile <task file>
delegate.ps1 -Agent cursor -Profile review -Persona implementation_readiness -Model deepseek-v41-flash-1017-medium -Standard implementation-readiness-standard.md -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <delegateTaskId>-pr -TaskFile <task file>
```

Comprehension always runs on Composer 2.5: on Grok 4.7 high it took 8.6 minutes for one task file (2026-11-14), against about 1 minute on Composer. The standard files are in `<delegate dir>/personas/`.

Read the comprehension report's **Size estimate** and its **Cohesion** answer. Preflight verdicts are advice: you decide, and you log a decision whenever you overrule one.

- **Keep the task whole** when it is one cohesive unit, even if it is big: a harness and the one test that proves it, or a change whose halves cannot be tested apart. Log `feature.ps1 decision -Repo <repo> -Name <name> -Kind decision -Text "<id>: kept whole despite split verdict — <why it is one unit>"`, and launch it. Size alone (minutes or lines) is never the reason to split.
- **Split the task** when it has a real seam (one part's output is a stable interface for the next, and each part is testable on its own). That is your call: do not ask the user and do not go back to the plan. Follow [Splitting a task in build](#splitting-a-task-in-build).
- **Narrow the acceptance command** after a Major finding about its scope: fix it in the same re-import as a split, or as a re-import of its own.
- **Strong pushback and you are unsure** (for example, both lenses say the task cannot work as written and you cannot tell who is right): convene a council on that question, as in `<delegate dir>/SKILL.md`, "Council". It is the furthest escalation. Do not stop for the user over it.

Escalate to the user only for scope or cost growth: see [Scope or cost growth](#scope-or-cost-growth).

Clean up each lens:

```text
delegate.ps1 -Cleanup -Profile review -Repo <repo> -TaskId <that id>
```

Read `reviewFile`. Triage per `delegate`'s rule (fix what would make two workers build different behaviour or interfaces). A failed preflight follows [Failed runs](#failed-runs).

## Splitting a task in build

Roles: the user is the product owner and sets scope and priority. You are the lead engineer. How tasks are cut and assigned is yours, as long as the locked design and the phase's scope do not change. Cut along a seam as `<delegate dir>/SKILL.md`, "Breaking work into tasks", says; these steps record the split.

1. Write a new complete plan input file to `<repo>/.xagent/features/<name>/plan-input.json`, as in `stages/plan.md`: every phase unchanged (`n`, `rationale`, `test`), every task that is merged or not `pending` unchanged, and the task being split replaced by its parts (new ids). The parts' `files` must stay inside what that phase's tasks already declared.
2. Run `feature.ps1 plan -Repo <repo> -Name <name> -PlanFile <that file>`. In stage `build` it refuses a phase change, a change to a task that is not `pending`, or a file outside the phase's declared files. Any of those is scope growth, not a split.
3. Log `feature.ps1 decision -Repo <repo> -Name <name> -Kind decision -Text "<id>: split into <new ids> — <seam and reason>"`.
4. Schedule as usual. No plan review and no new **plan-approved**: the gate stays.

The same steps refine later phases' tasks once earlier phases show what they need (planning a later phase in detail just in time). Task files are always written just before each run.

## Scope or cost growth

Stop for the user only when scope or cost grows: the phase goal, its files or the design must change, or the phase's total estimate grows by more than about 50% over the plan. The user re-prioritizes, so present it as a priority choice, each option with its cost, not as a yes/no on your plan. For example: do it now (cost), defer it to a later phase or feature, or cut something else to make room. Make it a [problem stop](#problem-stop).

## After each worker run

Run `feature.ps1 verify -Repo <repo> -Name <name> -Task <id>`. Read `changed`, `outOfScope`, `inScope` and `test` (`passed`, `exitCode`, `tail`). A non-empty `outOfScope` is a problem stop. Do not revert the files. The script does not revert them. A failing `test.passed` is a failed review round, handled under [Review rounds](#review-rounds).

Then read each changed file's diff separately: `git -C <worktree> diff <baseSha> -- <file>`. Never trust the worker's `result` summary on its own. A compression marker means that file is unread. The forms seen so far are `[... compressed ...]`, `[↑NL same as …]` and `<<ccr:…>>`. Read the file in smaller ranges (`git -C <worktree> diff <baseSha> -U3 -- <file>`, or `Read` with an offset) until no marker remains. `headroom_retrieve` may also work, but it is untested (T6 in `docs/test-plan.md`), so smaller ranges are the fallback.

## Failed runs

A usage-limit message is a problem stop at once. Do not retry it. There is no retry timer, no model fallback and no dollar estimate. The user resumes when the allowance is back. If the task is `preflight` or `running`, run `feature.ps1 task -Repo <repo> -Name <name> -Task <id> -Status failed`, then make the problem stop even when `failures` is 1.

Every other failed run (`ok: false` or `timedOut: true`) takes the normal failed-run path. Read `stderrTail` and the logs, then retry once with the same command. If `error` starts with `sandbox:`, do not retry: it is a sandbox setup problem, except `sandbox: environment not ready` — run `delegate.ps1 -SandboxEnv -Repo <repo> -Base feature/<name> -Apply` (ask first when `proposal.needsApproval` is true), then retry the launch once; failing again is a problem stop. Other `sandbox:` errors follow the usage-limit steps above: if the task is `preflight` or `running`, it is set `failed`, and a problem stop is made even when `failures` is 1. After a timeout, do not pass `-Resume`: the worktree and its uncommitted changes are reused. If it fails again, run `feature.ps1 task -Repo <repo> -Name <name> -Task <id> -Status failed`. Run `feature.ps1 status -Repo <repo> -Name <name>` and read that task's `failures` in `status.tasks`. If `failures` is now 2, make a problem stop. This path covers workers and task preflights. Review lenses are not build tasks; they follow the ladder in `stages/design-review.md`.

## Review rounds

During review, either fix the issue yourself ([Fix-ups](#fix-ups)) or send it back. Weigh the token and time cost of each path. "About 3 files and 30 lines" is a guideline for your own effort, not a cap.

This round limit replaces `delegate`'s "about 3 rounds" for feature tasks. Do not stop at about 3 rounds yourself.

When the review fails and you are not fixing it yourself, log the failed round immediately, before any rerun:

```text
feature.ps1 decision -Repo <repo> -Name <name> -Kind round -Text "<id>: <reason>"
```

Read `line`. Then run `feature.ps1 status -Repo <repo> -Name <name>`. `status.tasks[].rounds` counts only the rounds since that task's latest council. `status.tasks[].councils` is all of its `[council]` lines. Do not rerun until that line is logged.

Cap check first. A failed review when `councils` is already 2 is a problem stop. Log `feature.ps1 decision -Repo <repo> -Name <name> -Kind stop -Text "<id>: failed review after the second council — <reason>"`. Do not log a `[council]` line. Convene nothing. Do not rerun.

Otherwise, when `rounds` reaches 2 on `code`, or 1 on `code-hard`, convene a build council. Do not send the task back first.

Otherwise the round line is already logged. Send it back per `delegate`'s loop: write the review file, and rerun with the same `-TaskId` (`<delegateTaskId>`), `-TaskFile` set to that review file, and `-Resume <sessionId>`. If the next round is a fresh session (no `-Resume`, for example after a timeout), give it the comprehension preflight first, and readiness too if it changes scope.

## Council escalation

The user can also ask for a second opinion on a task. Convene this build council then too. If `councils` is already 2, say so and do not convene a third.

Follow `<delegate dir>/SKILL.md`, section "Council", with only the differences below. `<k>` is `councils + 1`.

- **Question.** Write `<repo>/.xagent/features/<name>/<id>.council-<k>.q.md`: the task file, each failed round's review feedback, the last attempt's diff (`git -C <worktree> diff <baseSha>`), and the line "What change would make this task pass review? Name the concrete fix." Keep it neutral. Write your own position first, to `<repo>/.xagent/features/<name>/<id>.council-<k>.lead.md`, before reading the seats. Where the seats disagree on a fact, verify it yourself.
- **Runs.** Both seats, in one message, following the cap rule in SKILL.md. At most two rounds, and round 2 only when the seats name different fixes.

```text
delegate.ps1 -Agent cursor -Profile council -Seat grok -Feature <name> -Repo <repo> -TaskId <delegateTaskId>-c<k> -TaskFile <question file>
delegate.ps1 -Agent cursor -Profile council -Seat glm -Feature <name> -Repo <repo> -TaskId <delegateTaskId>-c<k> -TaskFile <question file>
```

Round 2 writes `<repo>/.xagent/features/<name>/<id>.council-<k>.r2.md` and adds `-Resume <that seat's sessionId>`, using that round-2 file as `-TaskFile`. A failed seat follows "Failed delegate.ps1 runs" in SKILL.md (read `stderrTail`, retry once, no `-Resume` after a timeout). If `error` starts with `sandbox:`, do not retry: it is a sandbox setup problem, except `sandbox: environment not ready` — run the same `-SandboxEnv ... -Apply` steps, then retry the launch once; failing again is a problem stop at once, handled like a usage limit. A usage-limit message is a problem stop at once.

Clean up:

```text
delegate.ps1 -Cleanup -Profile council -Repo <repo> -TaskId <delegateTaskId>-c<k>
```

- **Consensus** (`delegate`'s rule: all three agree, or one concedes with a stated reason). Log `feature.ps1 decision -Repo <repo> -Name <name> -Kind council -Text "<id>: consensus — <one-line guidance>"`. Write the delta brief `<repo>/.xagent/features/<name>/<id>.council-<k>.md` (the task file, then `## Council guidance`, then `## Previous attempt` with the failed feedback). Discard the attempt: `delegate.ps1 -Cleanup -Discard -Repo <repo> -TaskId <delegateTaskId>`. Rerun the same `delegateTaskId` on `-Profile code-hard` with the delta brief and no `-Resume`:

```text
delegate.ps1 -Agent cursor -Model grok-4.7-high -Profile code-hard -Feature <name> -Base feature/<name> -Repo <repo> -TaskId <delegateTaskId> -TaskFile <delta brief>
```

Run `feature.ps1 task -Repo <repo> -Name <name> -Task <id> -Status running` before that rerun. The round count is 0 again, because only rounds after the latest council count. The council count never resets. Do not stop.

- **Disagreement.** The seats disagree on the fix, and you cannot settle it from verified facts. Log `feature.ps1 decision -Repo <repo> -Name <name> -Kind council -Text "<id>: disagreement — <summary>"`. Save `delegate`'s escalation brief to `<repo>/.xagent/features/<name>/<id>.council-<k>.brief.md`, show it, and make a problem stop. A task gets at most 2 councils. If the retry after the second council fails review, that is the cap-check stop above.

## Fix-ups

**Before the merge.** First stage the worker's work:

```text
git -C <worktree> add -A -- . ":(exclude,glob)**/__pycache__/**" ":(exclude,glob)**/.pytest_cache/**" ":(exclude,glob)**/.mypy_cache/**" ":(exclude,glob)**/.ruff_cache/**" ":(exclude,glob)**/*.pyc"
```

This leaves out the Python cache files that `verify` reports as `ignoredCaches`; they are never part of a task. Then make the edit in the worktree, and take the counts from `git -C <worktree> diff --shortstat`, which now shows only your unstaged edit. The merge step's commit includes both. Log `feature.ps1 decision -Repo <repo> -Name <name> -Kind fix-up -Text "<id>: <files> files, <lines> lines — <what>"`. Then run `feature.ps1 verify -Repo <repo> -Name <name> -Task <id>` again.

**After the merge** (a phase test failing on `feature/<name>`). Edit in `<repo>`, commit with the message `fix-up: <what>`, and log the same way, with `phase <n>` in place of the task id: `feature.ps1 decision -Repo <repo> -Name <name> -Kind fix-up -Text "phase <n>: <files> files, <lines> lines — <what>"`. The phase test is the check.

## Merge

`merge` refuses unless the tree is clean and `HEAD` is `feature/<name>`. On accept:

1. Commit everything in the worker worktree so a fix-up is included: `git -C <worktree> add -A -- . ":(exclude,glob)**/__pycache__/**" ":(exclude,glob)**/.pytest_cache/**" ":(exclude,glob)**/.mypy_cache/**" ":(exclude,glob)**/.ruff_cache/**" ":(exclude,glob)**/*.pyc"`, then commit with the message `task(<id>): <title>`. If cleanup later reports tracked changes, stop rather than discard them.
2. Run `feature.ps1 merge -Repo <repo> -Name <name> -Task <id> -Message "<title>"`. Read `mergeSha`. `-Message` is `<title>`. The script merges with `--no-ff` and the trailer `Xagent-Task: <id>`. If it fails with `merge conflict in …`, the merge was aborted. Show `error` and the files, and stop for the user. Do not discard the worker branch.
3. Run `delegate.ps1 -Cleanup -Repo <repo> -TaskId <delegateTaskId>`.

## Phase end

When all tasks of a phase are merged:

1. Run `delegate.ps1 -SandboxEnv -Repo <repo> -Base feature/<name>` (no `-Apply`). If any listed project is not `ready`, run `-SandboxEnv -Repo <repo> -Base feature/<name> -Apply` first (ask only when `proposal.needsApproval` is true). The phase test command is that phase's `test` in `docs/features/<name>/feature.json` (also `Test:` under the phase in `plan.md`). When the report lists at least one Python project, run it with `delegate.ps1 -SandboxRun -Repo <repo> -Base feature/<name> -Command "<test>" -TimeoutSec 3600`; the phase test passes only when `status` is `ran` and `exitCode` is 0, and any other result is a failure (show `output`). A repo with no Python projects runs the phase test in `<repo>` as before. If a fix-up solves a failure, log it as an after-merge fix-up. Otherwise make a problem stop.
2. If phase check-ins are on (`status.checkin` is `every-phase`), report and stop. The user turns check-ins on, at plan approval or with "check in every phase". You never turn them on yourself.
3. Otherwise, continue to the next phase.

## Merging main in

At a phase boundary, when the user asks: run `git -C <repo> merge --no-ff main`. Never rebase. Log `feature.ps1 decision -Repo <repo> -Name <name> -Kind decision -Text "merged main into feature/<name>"`, then run the phase test the same way as [Phase end](#phase-end) step 1 (`-SandboxEnv` and `-SandboxRun` when the repo has Python projects). On a conflict, run `git -C <repo> merge --abort`, show the files, and stop for the user. Otherwise the branch diverges until sign-off.

## End of build

When the last phase is done, run `feature.ps1 stage -Repo <repo> -Name <name> -To signoff`. Read `from` and `to`, and report. Do not start sign-off until the user asks to test and sign off, or says continue.

## Problem stop

Stop for: a council that disagrees, or a failure after a task's second council; a test failure on `feature/<name>` that a fix-up cannot solve; a change outside the declared files; scope or cost growth (a needed change to the design, a phase's goal or files, or a phase estimate up more than about 50%); a usage limit; a task that fails a second time. A task split or a refined later-phase task inside the phase's scope is not a stop: see [Splitting a task in build](#splitting-a-task-in-build). A needed design change, or a plan change beyond that, stops here. The user can say "go back to the design" or "go back to the plan". Do not edit the locked design or the imported plan in place.

**Stopping.** Run `feature.ps1 decision -Repo <repo> -Name <name> -Kind stop -Text "<id or phase>: <why>"`. Read `line`. Report to the user, and end the turn. A stop is committed, so it survives a lost local state file.

**Resuming.** When the user says to go on:

1. Run `feature.ps1 decision -Repo <repo> -Name <name> -Kind resume -Text "<what was decided>"`. Read `line`. `resume` fails when no `[stop]` is open.
2. For a `failed` task the user wants retried, run `feature.ps1 task -Repo <repo> -Name <name> -Task <id> -Status pending`.
3. After a council stop, the retry uses the profile and brief the user chose. The default is `code-hard` with the last delta brief (`-Profile code-hard -Model grok-4.7-high -TaskFile` that brief, no `-Resume`).
