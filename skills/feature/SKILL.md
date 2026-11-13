---
name: feature
description: "Use when the user asks to design, review, plan, build, continue, test, sign off, abandon or check the status of a feature in this repo. Examples: 'design a feature for X', 'let's design X', 'review the design', 'lock the design', 'plan it', 'plan the feature', 'approve the plan', 'build it', 'continue', 'check in every phase', 'test and sign off', 'sign off', 'where are we?', 'status', 'get a second opinion', 'convene a council', 'go back to the design', 'abandon this feature'. A sentence only mentioning a feature is not a request. 'plan it' for a feature never means Claude Code's plan mode. Do not fire on 'this feature is slow', 'what features does X have?', or 'add a feature flag'."
---

# feature

You are the lead. The user speaks in plain language. You design, review, plan, build, sign off and report status for one feature at a time. Talk to the user in plain language. Never ask the user to type a command or a slash command. Gates are approved in words ("lock the design", "approve the plan", "sign off").

## Paths and names

`<skill dir>` is the base directory Claude Code reports when this skill loads, with forward slashes. `<delegate dir>` is the `delegate` skill beside it (`<skill dir>/../delegate`).

`<repo>` is the top level of the session's current folder (`git rev-parse --show-toplevel`). `<name>` is `status.selected` after a feature has been selected.

Personas and standards live in `<delegate dir>/personas/`. Files this skill ships are named from `<skill dir>`: `<skill dir>/egm/skills/egm-draft/SKILL.md`, `<skill dir>/egm/skills/egm-review/SKILL.md`, `<skill dir>/egm/skills/egm-review-loop/SKILL.md`, `<skill dir>/egm/skills/egm-resolve/SKILL.md`, `<skill dir>/egm/agents/synthesizer.md`, `<skill dir>/schemas/plan.schema.json`, `<skill dir>/templates/task.md`.

Paths inside the vendored EGM files are relative to EGM's own layout. Read them this way: `resources/execution_instructions.md` is `<skill dir>/egm/resources/execution_instructions.md`; `resources/document_standards/<standard>.md` is `<delegate dir>/personas/<standard>.md`. Skip the line "read `${CLAUDE_PLUGIN_ROOT}/docs/claude.md` first": that file is not vendored, and this file and the stage files replace it.

In this file and in the stage files, `feature.ps1 <subcommand>` means:

```text
pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 <subcommand>
```

and `delegate.ps1` means:

```text
pwsh -NoProfile -File <delegate dir>/scripts/delegate.ps1
```

After a feature has been selected, every `feature.ps1` call passes `-Repo <repo> -Name <name>`. `new` passes `-Repo <repo> -Name <proposed name>` and no selected name. `doctor` passes neither `-Repo` nor `-Name`.

Every `feature.ps1` command prints one JSON object. Success, including `verify` with a failing test and `reconcile` with contradictions, is exit 0 and `ok: true`. A refused or failed command is exit 1 and `{ok: false, error}`. Show `error` and stop. Never guess the stage. `delegate.ps1` is different: a failed worker is still one JSON object, and `ok: false` or `timedOut: true` means the run failed. Read `ok`, `timedOut`, `sessionId`, `worktree`, `baseSha`, `reviewFile`, `stderrTail`, `taskId` and `model`.

`-Quote`, `-Reason`, `-Text`, `-Message` and `-Section` are each a single line.

## Router

On every invocation, run these steps in order.

### 1. Plan mode

If the session is in Claude Code's plan mode, run only:

```text
pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 status -Repo <repo> -Cwd <current folder>
```

That call is read-only. Answer read-only questions from it (see `stages/status.md` for the report). Say the user must leave plan mode (Shift+Tab) for anything else. Do not run `feature.ps1 reconcile` until plan mode is off: reconcile can commit. Do not call `EnterPlanMode`. "Plan it" means this skill's plan stage, not Claude Code's plan mode.

### 2. Status

Run:

```text
feature.ps1 status -Repo <repo> -Cwd <current folder>
```

If the user named a feature, pass that name too: `-Name <that name>`. Read `ok`, `selected`, `features`, `warnings`, and, when a feature is selected, `stage`, `phase`, `checkin`, `branch`, `treeClean`, `tasks`, `waitingOn`, `reviewRuns`, `diffTouchesRuleFiles`, `tokens`, `lastDecisions` and `nextAction`. This call applies [Active feature selection](#active-feature-selection). If it fails, show `error` and stop.

### 3. Reconcile, or no feature

If `selected` is `null`, skip `feature.ps1 reconcile`, then take the first match:

1. If the request is to design a feature, read `stages/design.md` and follow it. It starts with `new`.
2. If the request is only a status question, read `stages/status.md` and follow it.
3. If `features` lists any feature whose stage is not `done` or `abandoned`, ask which one (by name, in plain words). Then run `feature.ps1 status -Repo <repo> -Name <that name>` and continue from this step.
4. If none are in progress, say there is no feature in progress and offer to design one. Stop.

Otherwise run:

```text
feature.ps1 reconcile -Repo <repo> -Name <name>
```

Read `changes`, `contradictions` and `lost`. If `contradictions` is not empty, show them and stop. Contradictions change nothing. Do not guess the stage. If the call fails, show `error` and stop.

A contradiction is: the feature branch is missing while the stage is not `done` or `abandoned`; local state says a task is merged but `feature/<name>` has no merge commit with the trailer `Xagent-Task: <id>`; or `feature/<name>` is an ancestor of `main` without **signed-off** recorded. These asks also stop you, and nothing changes: another branch is checked out while the feature is active (ask the user to switch back to `feature/<name>`); a merge is in progress on `main` (ask the user to finish or abort it).

If `lost` is not empty, report it. Those session ids were local only. The affected tasks resume from their last committed state.

If `changes` moved any task to `failed`, run `feature.ps1 status -Repo <repo> -Name <name>` again: a task's second failure makes reconcile commit a `[stop]`. If `waitingOn.stop` is set (now, or already in step 2), report the stop's text and do no other work. In stage `build`, resuming follows "Problem stop" in `stages/build.md`. In any other stage, when the user says to go on, run `feature.ps1 decision -Repo <repo> -Name <name> -Kind resume -Text "<what was decided>"`, then continue.

`<name>` for every later call is `status.selected`.

### 4. Say what happens

State in one line the feature, the stage and the action about to be taken, before anything changes. This is the first action the user sees on every invocation, so a misfire is visible before anything changes.

### 5. Load the stage or handle the request here

Handle [Rows this router handles](#rows-this-router-handles) here. Otherwise read one stage file and follow it:

| Stage or request | File |
|---|---|
| `design` | `stages/design.md` |
| `design-review` | `stages/design-review.md` |
| `plan` | `stages/plan.md` |
| `build` | `stages/build.md` |
| `signoff` | `stages/signoff.md` |
| "where are we?", "status" | `stages/status.md` |

## Routing rules

- Invoke this skill when the user asks to design, review, plan, build, continue, test, sign off or abandon a feature, or asks where a feature stands. A sentence that only mentions a feature is not a request. The "Must not fire" row of the entry-point table is not a request: stop, and do not start a feature.
- "Plan it" is not plan mode. It means this skill's plan stage. Do not call `EnterPlanMode` for it. If the user is already in plan mode, ask them to leave it (Shift+Tab) before any stage that writes files.
- Move forward only when the user asks for the next stage, or says "continue" while the current stage is finished. Forward moves are one step at a time. A gate is required only where the stage table lists a gate to leave the current stage. If the request does not match the stage, say what stage the feature is in and what is needed first. Do not skip a stage.
- Pass a gate only by an explicit approval of that gate. An unclear reply ("ok", "looks fine I guess") gets one confirming question that names the gate. Record the gate only after a clear yes.
- The one-line statement in router step 4 happens before anything changes.

### Stages and gates

```text
design --> design-review --[GATE design-locked]--> plan --[GATE plan-approved]-->
build (phase 1..n) --> signoff --[GATE signed-off]--> done
                       any stage --> abandoned (user asks)
```

| Stage | Done when | Gate to leave |
|---|---|---|
| `design` | all sections of `docs/designs/<name>.md` approved | none |
| `design-review` | goldfish findings resolved | **design-locked** |
| `plan` | the plan imported and readiness-checked | **plan-approved** (also records the check-in mode) |
| `build` | every task merged into `feature/<name>` and each phase's test passes | none (opt-in phase check-ins and problem stops pause it) |
| `signoff` | full tests pass and the final check is shown | **signed-off**, followed by the merge into `main` |

Going back is allowed. Moving back to stage S clears S's own exit gate and every gate after it, so the next forward move needs that gate again. The `stage` command logs the move. Merged tasks stay merged and keep their ids. Rework after going back is new tasks with new ids. Removing merged code is itself a task, or a hand edit by the user.

Abandoning is allowed from any stage. The branch and records are kept until the user deletes them. The checkout switches back to `main` only when the tree is clean.

## Entry-point table

The phrases are examples. Also accept close paraphrases.

| The user says (examples) | Action | Gate |
|---|---|---|
| "design a feature for X", "let's design X" | `new`, then the `design` stage (`stages/design.md`) | — |
| "review the design" | `design-review` (`stages/design-review.md`) | asks for **design-locked** |
| "lock the design" | records **design-locked** | — |
| "plan it", "plan the feature" | `plan` (`stages/plan.md`) | asks for **plan-approved** |
| "approve the plan", "approve the plan and check in every phase" | records **plan-approved** and the check-in mode | — |
| "build it", "continue" | `build` (`stages/build.md`), or resumes the current stage | — |
| "check in every phase" / "stop checking in" | changes the check-in mode | — |
| "test and sign off" | `signoff` (`stages/signoff.md`) | asks for **signed-off** |
| "sign off" | records **signed-off**, then merges into `main` | — |
| "where are we?", "status" | `status` (`stages/status.md`, read-only) | — |
| "get a second opinion on …", "convene a council" | council | — |
| "go back to the design / plan" | moves back a stage | — |
| "abandon this feature" | `abandoned`, switch back to `main` if clean | — |
| **Must not fire:** "this feature is slow", "what features does X have?", "add a feature flag" | nothing | — |

### Rows this router handles

After steps 1–4, handle these rows here. The others load the stage file in step 5.

| The user says | Do |
|---|---|
| "lock the design" | Only in stage `design-review`, after the review is resolved: follow the lock steps in `stages/design-review.md`. In any other stage, say what stage the feature is in and what is needed first. |
| "approve the plan" (with or without check-ins) | Only in stage `plan`, with a plan imported: follow the approve steps in `stages/plan.md`. |
| "sign off" | Only in stage `signoff`, after the final check was shown: follow step 7 in `stages/signoff.md`. |
| "check in every phase" / "stop checking in" | Run `feature.ps1 checkin -Repo <repo> -Name <name> -Mode every-phase`, or `-Mode on-problems`. Read `mode`. Confirm in one line. Any stage. |
| "go back to the design" | Run `feature.ps1 stage -Repo <repo> -Name <name> -To design-review -Reason "<user words>"`. Read `from` and `to`. Then follow `stages/design-review.md`. |
| "go back to the plan" | Run `feature.ps1 stage -Repo <repo> -Name <name> -To plan -Reason "<user words>"`. Read `from` and `to`. Then follow `stages/plan.md` (re-plan rules). |
| "abandon this feature" | Confirm once, in plain words, that the feature will be abandoned (the branch and records are kept). On a clear yes, run `feature.ps1 stage -Repo <repo> -Name <name> -To abandoned -Reason "<user words>"`. Read `from` and `to`. Then run `git -C <repo> branch --show-current` and report whether the checkout switched to `main`. |
| "get a second opinion on …", "convene a council" | In stage `build`, about a task: the build council in `stages/build.md`. Otherwise: [On-request and design/plan councils](#on-request-and-designplan-councils). |

"build it" and "continue" resume the current stage file. Follow `stages/build.md` when the stage is `build`. Do not skip stages.

## Active feature selection

Check these in order:

1. The feature named in the request. Pass it as `-Name` on `feature.ps1 status`. The name matches `^[a-z0-9][a-z0-9-]{0,30}$`.
2. The feature whose branch is checked out in the session's current folder, unless that feature is `done` or `abandoned`. `feature.ps1 status` applies this when `-Name` is omitted and `-Cwd` is the session's folder.
3. The only feature in progress, if there is exactly one. `feature.ps1 status` applies this when `-Name` is omitted. A feature is in progress unless it is `done` or `abandoned`. `done` is derived (the branch is an ancestor of `main` and **signed-off** is recorded) and is never stored.
4. Otherwise, ask the user.

One feature is active, in the user's checkout. Local state is `<repo>/.xagent/features/<name>/`. Lasting records are committed on `feature/<name>` under `docs/features/<name>/`. The design doc is `docs/designs/<name>.md`. Workers are launched with `-Repo <repo> -Base feature/<name>`, and you merge their branches in `<repo>` while `feature/<name>` is checked out. Side work happens outside this skill. The checkout must be back on `feature/<name>` before you continue. Reconcile asks the user to switch back when it is not. `main` is merged into the feature only when the user asks, at a phase boundary, as `stages/build.md` describes.

`feature.ps1` is the only writer of `feature.json`. Do not hand-edit `feature.json`, `plan.md` or `decisions.md`. `plan.md` is generated for the user to read.

## On-request and design/plan councils

In `design` and `plan` (including `design-review`), when you face a choice that is hard to reverse or contested, offer a council. Run one only if the user agrees. The user can ask for a council at any stage. In stage `build`, a request about a task uses the build council in `stages/build.md`. Every other request uses this section. `stages/design.md`, `stages/design-review.md` and `stages/plan.md` point here.

Read and follow `<delegate dir>/SKILL.md`, section "Council", with these values:

- `<k>` is 1 plus the number of `[council]` lines in `docs/features/<name>/decisions.md` whose text starts with `design:` (stages `design` and `design-review`) or `plan:` (otherwise).
- `<name12>` is `<name>` cut to 12 characters. If that ends with `-`, drop the trailing `-`.
- The run id is `<name12>-dc<k>` in `design` or `design-review`, and `<name12>-pc<k>` otherwise.
- The question file is `<repo>/.xagent/features/<name>/council-<run id>.md`. Keep it neutral. Do not reveal your preference. Write your own position first, to `<repo>/.xagent/features/<name>/council-<run id>.lead.md`, before reading the seats.
- Follow the cap rule in this file before the seats. Run both seats in one message:

```text
delegate.ps1 -Agent cursor -Profile council -Seat grok -Feature <name> -Repo <repo> -TaskId <run id> -TaskFile <question file>
delegate.ps1 -Agent cursor -Profile council -Seat glm -Feature <name> -Repo <repo> -TaskId <run id> -TaskFile <question file>
```

- Round 2 writes `<repo>/.xagent/features/<name>/council-<run id>.r2.md`. It adds `-Resume <that seat's sessionId>` and uses that round-2 file as `-TaskFile`. Usually 2 rounds is enough. Never more than 3.
- Fact-check, synthesize, and write the escalation brief the way that Council section says. Save the brief to `<repo>/.xagent/decisions/<run id>.md`.
- Log the outcome:

```text
feature.ps1 decision -Repo <repo> -Name <name> -Kind council -Text "design: <outcome>"
```

Use `plan: <outcome>` instead of `design: <outcome>` outside `design` and `design-review`. `<outcome>` is one line, `consensus — <guidance>` or `disagreement — <summary>`. Read `line`.

- Then clean up:

```text
delegate.ps1 -Cleanup -Profile council -Repo <repo> -TaskId <run id>
```

A failed seat (`ok: false` or `timedOut: true`): read `stderrTail` and the logs under `<repo>/.xagent/runs/<run id>/`, then retry once with the same command. After a timeout, do not pass `-Resume`. A usage-limit message is a problem stop at once (see [Failed delegate.ps1 runs](#failed-delegateps1-runs)).

## Rules for every stage

- Never merge `feature/<name>` into `main` without **signed-off**. Only `feature.ps1 finish` does that merge, and only from `stages/signoff.md`.
- Call the scripts through `<skill dir>` and `<delegate dir>` as above. Do not put an absolute path in a command.
- Never use a Claude model for a worker or a goldfish. Do not pass a Claude model or `auto` as `-Model`.
- Never use the Antigravity agent (`agy`) with `delegate.ps1`.
- Every `delegate.ps1 -Cleanup` call passes `-Repo <repo>`.
- If a command fails because the setup is incomplete, run `feature.ps1 doctor` and show what it prints, including the permission rules to add.
- If a writing command fails with "another session is working on this feature", show that and stop.
- `feature.ps1 schedule` returns no tasks while a `[stop]` is open or before a plan exists. It still returns `liveRuns` and `cap`.

### The cap rule

At most 2 agents of this feature run at a time. The cap counts every `delegate.ps1` run of the feature: preflights, workers, review lenses and council seats.

Before any `delegate.ps1` run that does not come from `feature.ps1 schedule` (preflights, lenses, council seats), run `feature.ps1 schedule -Repo <repo> -Name <name>` and read `cap` and `liveRuns`. Start at most `cap - liveRuns` such runs. If none can start, wait for a running call to finish, then check again. Worker tasks listed in `schedule.tasks` are already capped by `schedule`. Stage files call this the cap rule in SKILL.md and do not restate it.

## Failed delegate.ps1 runs

If `ok` is false or `timedOut` is true, read `stderrTail` and the logs, then retry once with the same command. After a timeout, do not pass `-Resume`. A usage-limit message (in `stderrTail`, `error`, or the summary) is a problem stop at once: do not retry it, do not switch models, and do not wait on a timer. In `build`, follow the problem-stop steps in `stages/build.md`. In any other stage, log it with `feature.ps1 decision -Repo <repo> -Name <name> -Kind stop -Text "<what was running>: usage limit"`, report it, and end the turn.

In `build`, a worker or a task preflight that fails again after that one retry is handled in `stages/build.md`: set the task to `failed`, and if that task's `failures` in `status.tasks` is then 2, make a problem stop. Review lenses, after the one retry, follow the ladder in `stages/design-review.md`. The sign-off lens follows the ladder in `stages/signoff.md`.
