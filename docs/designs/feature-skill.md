# `feature` skill: plain-language, feature-level development flow

*   **Author:** Eugene Chin
*   **Status:** Proposed
*   **Date:** 2026-11-09

--------------------------------------------------------------------------------

## Overview

`feature` is a Claude Code skill. It takes one feature from design to a merged branch. Claude Code is the lead programmer. Cursor workers do the coding through the existing `delegate` skill, and the user approves each major step.

The user drives it in plain language. "Start the design", "plan it", "build it", "continue" and "where are we?" each map to a stage. The skill keeps each feature's progress in a file in the repo, so the work survives context compaction and new Claude Code sessions.

Version 1 covers five stages plus a status query:

1. design
2. design review
3. plan
4. build
5. test and sign-off

For hard or contested problems, the skill can bring in a multi-model council (Claude, Grok 4.7 and GLM 5.2) at any stage. The design stages reuse the Elephant-Goldfish Model (EGM) workflow, copied into this repo per [decision 001](../decisions/001-vendor-egm-workflow.md). The build stage reuses `delegate.ps1`. Brainstorming and benchmark mode come later.

## The Problem

Today, building a feature with this project's tools means the user runs each piece by hand and keeps the state in their head:

*   **Typed commands.** EGM's skills are user-only (`disable-model-invocation`), so each design stage needs a typed `/egm-*` command with arguments. The user wants to say what they want, not remember command names and parameters.
*   **No memory across sessions.** A feature takes several sessions. Today progress lives only in the conversation and a hand-written `HANDOFF.md`. When the context is compacted or a new session starts, the lead must rebuild where things stand, and that is slow and error-prone.
*   **No link from design to build.** `delegate` works one task at a time. Nothing turns a locked design into an ordered set of tasks, decides which tasks can safely run in parallel, gathers their results on one branch, or checks the finished code against the design.
*   **Gates are informal.** Whether the design is locked, the plan approved, or the result signed off is not recorded anywhere. Nothing stops the flow from moving past a step the user never approved.

Similar tools exist (see [research §7](../research.md)). The spec-driven frameworks (Spec Kit, Superpowers, BMAD) have stages and gates, but they run only on Claude subagents. kodo has cross-vendor workers, but no user-locked design and, by its own account, no independent verification gate. None of them targets native Windows PowerShell with a policy of keeping coding work off the user's Claude quota.

## Goals

*   **G1. Plain-language entry.** Every v1 stage and the status query start from a plain-language request. No step requires the user to type a slash command or a parameter. Pass: each phrase in the entry-point table, said in a fresh session, starts the right stage.
*   **G2. Resumable from disk.** A fresh session that knows nothing about the feature can answer "where are we?". It gives the current stage, what is done, what is waiting on the user, and the next action. It reads only files in the repo. Pass: the answer is correct after `/clear`, for a feature paused at each stage.
*   **G3. Recorded user gates.** The flow stops at three gates: design locked, plan approved, and final sign-off. It does not move past a gate until the user approves. Each approval is written to the feature's state with a timestamp. During the build, the flow also stops on problems. It stops after each phase only when the user has turned on phase check-ins for that feature.
*   **G4. Isolated build.** All code for a feature lands on one integration branch, `feature/<name>`. `main` changes only after the user signs off. Coding tasks go to Cursor workers (Composer 2.5, or Grok 4.7 high for `code-hard`) through `delegate`. Claude reviews and merges. It does not write feature code, and the plan cannot assign code to it. The one exception is a fix-up during review: when fixing an issue directly costs less, in tokens and in time, than another worker round, the lead fixes it and records it.
*   **G5. Safe parallelism.** Two tasks run at the same time only if their declared file sets do not overlap and neither depends on the other. Otherwise they run one after another.
*   **G6. Final check against the design.** Before sign-off, the whole feature diff is checked against the locked design for missing, extra or changed behaviour, and the user sees the result.
*   **G7. Council on hard problems.** The skill brings in the existing multi-model council (`delegate`'s `council` profile: Grok 4.7 high and GLM 5.2, both through Cursor, with Claude as lead) at three points. It is not a separate stage.
    *   **Design or plan:** the skill offers it for a decision that is hard to reverse or contested.
    *   **Build:** it convenes one automatically when a `code` task fails review twice, or a `code-hard` task fails review once. If the council agrees, the build retries the task with its advice without stopping. If it disagrees, or a task has already had 2 councils, the build stops for the user.
    *   **Any stage:** it convenes one when the user asks.

    It does not convene one for routine work, because a council costs about 1–3 minutes plus frontier-model tokens from both Cursor usage pools. Each council's outcome is recorded in the feature's decisions.

## Non-Goals

*   **Brainstorm stage.** Deferred. v1 starts from a problem statement the user gives in chat or from an existing brief.
*   **Benchmark mode inside `feature`.** Deferred. `delegate`'s own benchmark mode still works per task if the user turns it on.
*   **Cloud or remote agents.** Workers and goldfish run locally through the Cursor CLI only.
*   **Automating Antigravity on a consumer plan.**
    *   **What Google says.** The Antigravity FAQ calls wrapping `agy -p` inside third-party coding agents unsupported on consumer plans, and names Claude Code as third-party software whose use with an Antigravity login breaks the Terms (checked 2026-11-10, `docs/test-plan.md` T0).
    *   **So v1 sends no work to `agy`.** The Google Pro plan stays for the user's own interactive use.
    *   **Not chosen either:** an AI Studio API key, which Google supports, because it bills per token (Alternative J).
*   **Deploying.** v1 ends at the merge into `main`.
    *   **Workers** never handle secrets, credentials or deploy steps.
    *   **The lead** may run a deploy or operations step later, but only with the user's explicit approval at that step, and only using secret references (environment variables or a secret store), never secret values.
    *   **A `deploy` stage** is in Future Improvements.
*   **macOS or Linux support.** v1 targets Windows and PowerShell 7, matching `delegate.ps1`.
*   **Several people on one feature.** One user and one lead session own a feature at a time. No locking between machines.
*   **More than one active feature (side mode).** Deferred. v1 runs one feature at a time, in the user's checkout. A side mode that runs a second feature in its own worktree is in Future Improvements.
*   **Merging to `main` without the user.** The skill never merges to `main` or pushes without explicit sign-off.
*   **Replacing EGM's review content.** We reuse EGM's personas and standards. Changing how a goldfish reviews is out of scope.

## Open Questions

None open. Q1 (active feature), Q2 (state versus git), Q3 (goldfish vendor) and Q4 (check-ins) were resolved during drafting. See the Technical Plan.

## Critical User Journeys (CUJs)

### CUJ 1: Start a design from a problem statement

*   **Given**: A repo with no in-progress feature named `export`. The user is in a Claude Code session in that repo.
*   **When**: The user says "let's design an export-to-PDF feature: users need to …".
*   **Then**:
    *   The skill creates the branch `feature/export` from `main` (main mode) and switches the user's checkout to it.
    *   It creates the feature's records with stage `design`.
    *   It drafts `docs/designs/export.md` one section at a time, with the user approving each section, following the vendored EGM draft workflow.
    *   When drafting finishes, the state records the design path and the stage moves to `design-review`.

### CUJ 2: Resume after a fresh session

*   **Given**: Feature `export` is paused in the middle of the build stage. Phase 2 of 3 is running: task `export-renderer` is merged and task `export-cli` is waiting on review round 2. The user runs `/clear`.
*   **When**: The user says "where are we?".
*   **Then**: Reading only repo files, the skill reports:
    *   the stage (build, phase 2 of 3)
    *   which tasks are done, running or waiting
    *   what is waiting on the user (nothing, or a named gate)
    *   the next action it will take on "continue"

### CUJ 3: Review and lock the design

*   **Given**: Feature `export` is at stage `design-review`.
*   **When**: The user says "review the design".
*   **Then**:
    *   The skill runs the goldfish review stages and writes a report with Blocker, Major and Nit findings.
    *   It walks the user through resolving each finding.
    *   It asks for the design-lock gate. Only after the user explicitly approves does it record the lock with a timestamp and move to `plan`.

### CUJ 4: Plan and approve

*   **Given**: The design for `export` is locked.
*   **When**: The user says "plan it".
*   **Then**:
    *   The skill writes a plan with phases and tasks. Each task has its dependencies, its declared file set, a test command and a profile (`code` or `code-hard`). Steps that must not be delegated, such as anything needing secrets, are listed as steps for the user.
    *   It runs a goldfish implementation-readiness check on the plan and fixes the findings.
    *   It asks for the plan-approval gate.
    *   It asks whether to check in after every phase. The default is to stop only on problems.
    *   On approval, it records the gate and moves to `build`.

### CUJ 5: Build a phase, with a council escalation

*   **Given**: The plan is approved. Phase 1 has tasks A and B, whose file sets don't overlap, and task C, which depends on A.
*   **When**: The user says "build it".
*   **Then**:
    *   The skill delegates A and B in parallel with `-Base feature/export`. It reviews each diff, merges the accepted work into `feature/export`, then delegates C.
    *   Suppose C fails review twice. The skill convenes a council on C's problem and records the outcome as a decision.
        *   **The council agrees.** The skill retries C on `code-hard` with the council's advice and keeps going.
        *   **The council disagrees, or C fails after a second council.** It stops and shows the user the positions and its proposed next step.
    *   With the default check-in mode (`on-problems`), phase 2 starts as soon as phase 1 is merged and its tests pass. With `every-phase`, it reports and waits for "continue".

### CUJ 6: Test and sign off

*   **Given**: All phases of `export` are merged into `feature/export`.
*   **When**: The user says "test and sign off".
*   **Then**:
    *   The skill runs the full test suite on `feature/export`.
    *   It runs the final check of the whole diff against the locked design, and shows the results.
    *   It asks for the sign-off gate. On explicit approval, it merges `feature/export` into `main` and marks the feature `done`. It does not push unless the user asks.

### CUJ 7: An unclear reply does not pass a gate

*   **Given**: The skill is waiting at the plan-approval gate.
*   **When**: The user replies "ok, looks fine I guess".
*   **Then**: The skill asks one confirming question ("Approve the plan and start building?"). It records the approval only after a clear yes.

## Technical Plan (Architecture)

### Components

```text
 user (plain language)
        |
        v
+----------------------------------------------+
| skills/feature/SKILL.md          (router)    |
|  1. pick active feature   2. reconcile state |
|  3. pick stage            4. load stage file |
+----------------------------------------------+
   |                 |                    |
   v                 v                    v
stages/*.md     scripts/feature.ps1   egm/ (vendored EGM workflow,
(design,        (state: new, status,   personas, standards; unmodified
 review, plan,   reconcile, gate,      where possible)
 build,          schedule, task)              |
 signoff)            |                        |
   |                 |                        |
   v                 v                        v
delegate.ps1  -->  Cursor CLI workers    (code, code-hard, review,
(existing)         in worktrees           council profiles)
```

*   **Router (`skills/feature/SKILL.md`).** It is the only entry point and has one description. On every invocation it does four things in order:
    1.  Pick the active feature (rules below).
    2.  Run `feature.ps1 reconcile`.
    3.  Pick the stage from the reconciled state and the user's request.
    4.  Read only that stage's file from `stages/`.
*   **Stage files (`skills/feature/stages/*.md`).** Instructions for one stage each: `design.md`, `design-review.md`, `plan.md`, `build.md`, `signoff.md`, and `status.md` for "where are we?". The design and review stage files tell the lead to follow the vendored EGM workflow, and say where our flow differs from it (see "EGM integration").
*   **State script (`skills/feature/scripts/feature.ps1`).** All reads and writes of feature state go through this script, so the rules can be tested. It prints compact JSON, like `delegate.ps1`. Subcommands:
    *   `new`: create the branch and records.
    *   `status`: print the reconciled state.
    *   `reconcile`: fix local state from git and report contradictions.
    *   `gate`: record an approval.
    *   `stage`: move to another stage.
    *   `plan`: import and check the plan.
    *   `schedule`: list the tasks that are ready to run now.
    *   `task`: update one task's runtime fields.
    *   `verify`: check a finished worker run's scope and run its test.
    *   `cooldown`: mark a Cursor usage pool as exhausted for a while.
    *   `merge`: merge a task's branch, adding its `Xagent-Task` trailer.
    *   `decision`: append to the decision log.
    *   `checkin`: set the check-in mode.
    *   `finish`: merge the feature into `main` after sign-off.

    The full interface is in the Detailed Implementation Plan.
*   **Vendored EGM (`skills/feature/egm/`).** A copy of the EGM skill text and standards that our stages use, pinned per [decision 001](../decisions/001-vendor-egm-workflow.md). The goldfish personas live with the other personas in `skills/delegate/personas/`.
*   **`delegate.ps1` (existing).** Runs every worker, goldfish and council run. `feature` adds no new way to launch an agent.

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
| `plan` | `plan.md` written and readiness-checked | **plan-approved** (records the check-in mode) |
| `build` | every task merged into `feature/<name>` and the phase tests pass | none, except opt-in `every-phase` check-ins and problem stops |
| `signoff` | full tests pass and the final check is shown | **signed-off**, which merges into `main` |

Going back is allowed. For example, a design flaw found during the build moves the feature to `design-review`. Going back clears the gates after the target stage, and the change is logged as a decision.

**Merged work after going back (keep or redo).** Each approved plan has a generation number, starting at 1, and every task merge records it in its trailer (`Xagent-Gen: <n>`). If tasks were already merged when the feature went back, the next plan must list each of them:
*   **`keep`:** the work stays merged and counts as done in the new generation.
*   **`redo`:** `feature.ps1` undoes that merge with `git revert -m 1 <merge commit>`, newest first, and the task goes back to pending. History is kept and nothing is force-pushed.

The user sees and approves the keep/redo list at **plan-approved**, and the generation goes up by one. If a revert conflicts (for example, a kept task built on top of a redone one), the script stops the revert, names the conflicting files and the tasks involved, and asks the user to choose: change the list, or resolve by hand.

### Routing rules

*   **Invoking the skill.** Claude invokes it when the user asks to design, review, plan, build, continue, test or sign off a feature, or asks where a feature stands. The description lists example phrases. A sentence that only mentions a feature ("this feature is slow") is not a request.
*   **Moving to the next stage.** The skill moves forward only when the user asks for the next stage ("plan it", "build it") or says "continue" while the current stage is finished.
*   **Passing a gate.** A gate is passed only by an explicit approval of that gate ("lock the design", "approve the plan", "sign off"). An unclear reply ("ok", "looks fine I guess") gets one confirming question that names the gate. The approval is recorded with a timestamp and a short quote of what the user said.
*   **First action on every invocation.** The skill states in one line which feature, stage and action it is about to take. A misfire is then visible before anything changes.

### Active feature selection (resolves Q1)

The skill checks these in order:
1.  The feature named in the request.
2.  The feature whose branch is checked out in the session's current folder.
3.  The only feature in progress, if there is exactly one.
4.  Otherwise, it asks the user.

### Where the feature runs (one active feature, in the user's checkout)

*   **Start.** `feature.ps1 new` refuses if:
    *   the working tree has uncommitted changes (the user commits or stashes first);
    *   another feature is active (not `done` or `abandoned`).

    Otherwise it runs `git switch -c feature/<name> main` in the user's repo folder.
*   **Location.** Local state lives in `<repo>/.xagent/features/<name>/`.
*   **Workers.** They are launched with `-Repo <repo> -Base feature/<name>`. The lead merges worker branches in `<repo>`, which has `feature/<name>` checked out.
*   **Side work.** While a feature is active, side work happens outside the skill, for example by hand on another branch after committing or stashing. The checkout must be back on `feature/<name>` before the skill continues. Reconcile checks this and asks the user to switch back if it isn't.
*   **Side mode** (a second feature in its own worktree) was designed and then deferred (see Alternative F and Future Improvements). v1 records no mode. A later version can treat a feature with no `mode` as main mode.

### State model (split: committed records plus local runtime state)

Committed on `feature/<name>`, in `docs/features/<name>/`:

*   `feature.json`: name, base, stage, check-in mode, plan generation, path to the design doc, gates (each with a timestamp and the user's quote), and the plan's phases and tasks (id, title, depends-on, declared files, test command, profile, brief, and on a re-plan `carry: keep|redo`). The script is the only writer.
*   `plan.md`: the plan as the user reviews it, in prose plus a task table generated from `feature.json`.
*   `decisions.md`: an append-only log of decisions, gate approvals, council outcomes, scope changes, moves back to an earlier stage, dismissed review findings, and problem stops and resumes.
    *   **Problem stops are committed.** A stop is logged as `[stop]` and clearing it as `[resume]`, so a stop survives the loss of the local state file. An unmatched `[stop]` means the flow is waiting on the user.

The design doc itself is `docs/designs/<name>.md` on the branch. It is drafted in place with `Status: Draft` and committed after each approved section.

Local, in `<main repo>/.xagent/features/<name>/state.json` (git-excluded):

*   For each task: status (`pending`, `running`, `in-review`, `merged`, `failed`, `escalated`), delegate task id, session id, review round, worktree path, and last result file.
*   For each Cursor usage pool (`cursor` for Cursor's own models, `thirdParty` for GLM and DeepSeek): `cooldownUntil`, set when that pool hits its limit.
*   For the feature: the time of the last reconcile.

These are not stored, because they can be derived:
*   **What the flow is waiting for.** `status` computes it: a gate the stage needs, an open problem stop in `decisions.md`, a cooldown, or a running worker.
*   **Goldfish review progress.** Each lens run uses a fixed `delegate` task id, `<name>-<review>-<lens>` (for example `export-design1-zoom-out`). A lens is done when `.xagent/runs/<that id>/` holds a `.review.md` file. A review interrupted by compaction resumes at the first lens with no report.

### Reconcile rules (resolves Q2)

`feature.ps1 reconcile` runs at the start of every invocation. Git wins for the facts it can prove. Local-only fields are kept. The script stops and asks only on a real contradiction.

| Fact | Source | Rule |
|---|---|---|
| Feature branch exists | git | Missing branch while the stage is not `done`/`abandoned` → **contradiction, ask** |
| Feature branch checked out | git: `git -C <repo> branch --show-current` | Another branch checked out while the feature is active → **ask the user to switch back** (no change is made) |
| Task merged | git: a merge commit on `feature/<name>` with trailers `Xagent-Task: <id>` and `Xagent-Gen: <n>`, not undone by a later `Xagent-Revert: <id>` commit | Counts as `merged` if `<n>` is the current generation, or the task is marked `keep` in the current plan. Absorbs manual merges that carry the trailers. |
| Task merged per local state, no trailer commit found | — | **contradiction, ask** |
| Feature merged into `main` | git: `feature/<name>` is an ancestor of `main` | Mark `done` if `signed-off` is recorded. Without that gate → **contradiction, ask** |
| Gates, stage, plan | committed `feature.json` | Always taken from the committed copy |
| Open problem stop | committed `decisions.md`: a `[stop]` line with no later `[resume]` | Always waiting on the user, even if the local file was lost |
| Review rounds, session ids, cooldowns, council counts | local only | Kept. If the local file is missing, reset to defaults and report what was lost |

All worker merges into a feature branch use `git merge --no-ff` with the trailer, so task completion can be proven from history after `delegate -Cleanup` deletes the task branch.

### Build scheduling

*   **Task ids** are `<feature>-<task>`, shortened to fit `delegate`'s 49-character limit.
*   **Ready tasks.** A task is ready when all of its `depends-on` tasks are merged. `feature.ps1 schedule` returns the ready tasks of the current phase that can start now. A task can start only if its declared files overlap no running task's declared files. Two paths overlap when they are equal or one is a parent folder of the other. An entry in `files` can be a glob (`*`, `**`). For the overlap check, a glob counts as its literal folder prefix, the part before the first wildcard, which is conservative. For the scope check, a glob matches files the normal way. So two tasks that add files to the same folder run in parallel only if each lists its exact file names.
*   **At most 2 agents at a time.** The cap counts tasks in preflight, running or in review, so goldfish preflights count too. This keeps load on the Cursor subscription predictable.
*   **Models.** Everything runs through the Cursor CLI. There is one worker model per profile, so no routing between vendors is needed.
    *   `code` tasks: Composer 2.5.
    *   `code-hard` tasks: Grok 4.7 high.
*   **Usage pools and cooldown.** The Cursor subscription has two monthly pools. One is for Cursor's own models (Composer, Grok). The other is for third-party models at API price (GLM 5.2, DeepSeek V4.1 Flash), which on the legacy $20 Pro plan holds $20 of usage.
    1.  When a run reports a usage limit, `feature.ps1 cooldown -Pool <cursor|thirdParty>` sets that pool's `cooldownUntil` to now plus 60 minutes and logs one decision. Neither the CLI nor Cursor reports a reset time, so 60 minutes is a conservative retry point, not a known window.
    2.  **The Cursor pool is exhausted.** Workers and Grok seats cannot run. That's a problem stop: there is no other subscription to fail over to.
    3.  **The third-party pool is exhausted.** GLM and DeepSeek seats fall back to Grok 4.7 high for the rest of that review or council. The fallback is logged, and the report states that the check across model families was weaker.
    4.  The user can clear a cooldown early ("Cursor is back").
*   **Profile.** Each task starts on the profile the plan gives it.
*   **Task outcomes recorded.** Every merged task appends one line to `benchmarks/outcomes.jsonl` in this project. The line holds:
    *   the feature, the task and its profile
    *   the number of review rounds, whether its first `verify` passed, and how many councils it needed
    *   its `delegate` task id, which links it to the token counts already in `benchmarks/runs.jsonl`

    This is the data for a later rule about which tasks should start on `code-hard`.
*   **Task preflight models (build only).** This rule is for the per-task preflight in the build. The design and plan reviews follow the table in "Goldfish review routing".
    *   **Comprehension** runs on the worker's model: Composer 2.5 for `code`, Grok 4.7 high for `code-hard`. If the worker would misread the task, this reviewer should too.
    *   **Implementation readiness** runs on DeepSeek V4.1 Flash, a different model family.
*   **Scope check and test (`feature.ps1 verify`).**
    *   **What it does.** After each worker run, one script call:
        1.  lists the worker's changed and untracked files;
        2.  matches them against the task's `files`;
        3.  runs the task's test command in the worker worktree;
        4.  records the result in the state.
    *   **What it returns.** One compact summary. The lead then reviews only the diff's content.
    *   **When it stops the build.** A change outside `files` is a problem stop. The script does not revert it automatically, because silently undoing a worker's change could hide a real problem.
    *   **What it needs from the plan.** Task test commands must be non-interactive.
*   **Merge.** Each task is reviewed and merged per `delegate`'s loop, with the differences listed in the build stage file. A phase ends when all its tasks are merged and the phase test command passes on `feature/<name>`.
*   **Problem stops.** In `on-problems` mode (the default), the build runs through phases without stopping, except for:
    *   a council escalation
    *   a test failure on `feature/<name>` that the lead cannot fix in one small fix-up
    *   a change outside the declared files
    *   a needed change to the plan or the design
    *   the Cursor usage pool exhausted
*   **Check-in mode.** In `every-phase` mode, it also stops after each phase. The user turns this mode on explicitly, at plan approval or during the build, and the skill never switches to it by itself.
*   **Fix-ups (judgement, not a limit).**
    *   **The choice.** During review, the lead either fixes an issue itself or sends it back as a review round.
    *   **How it decides.** It weighs the token and time cost of each path, and asks whether the issue is a small fix or a real review problem that needs rework.
    *   **Guideline, not a cap.** "About 3 files and 30 lines" helps the lead gauge its own effort.
    *   **Afterwards.** Every fix-up is logged as `[fix-up]` in `decisions.md`, and `verify` runs again.

### Council (G7)

*   **Design and plan.** When the lead faces a choice that is hard to reverse or contested, it offers a council and runs one only if the user agrees.
*   **Build.** A `code` task that fails review twice, or a `code-hard` task that fails review once, triggers a council automatically. This is the one place the round limit is set for feature tasks, and it replaces `delegate`'s "about 3 rounds" rule for them. The council uses `delegate`'s council procedure, and its outcome is appended to `decisions.md`.
    *   **Consensus.** The lead retries the task on `code-hard` with the council's guidance, without stopping. The task's round count starts again from 0.
    *   **Disagreement.** The council's members disagree on the fix, and the lead cannot settle it from verified facts. That's a problem stop, with `delegate`'s escalation brief.
    *   **Cap.** A task gets at most 2 councils. If the retry after the second council fails review, that's a problem stop.
*   **On request.** At any stage, the user can ask for a council.

### Goldfish review routing

All goldfish run on non-Claude models through the Cursor CLI, so the reviewer is always a different model family from the author (the Claude lead). Antigravity is not used (see Non-Goals).

This table applies to the design review, the plan review and the sign-off check. The build's task preflights follow "Task preflight models" above.

| Lens | Model | Cursor pool | Why |
|---|---|---|---|
| comprehension | Composer 2.5 | Cursor | The same model as the workers who will read the tasks. |
| implementation_readiness | DeepSeek V4.1 Flash | third-party | A cheap reader from a different model family. |
| zoom_out, design_critic, inventive_catalyst, codebase_details, structural, style, drift_report | Grok 4.7 high and GLM 5.2, alternating | Cursor / third-party | These lenses need judgement about architecture and hidden complexity. Two model families give two independent views. |

*   **Model per lens.** Grok and GLM alternate across the judgement lenses, so both review each document.
*   **Diff reviews.** A worker's diff (written by Composer or Grok) is reviewed by GLM 5.2, a different family from the writer.
*   **Target passed by file.** The review target (design doc, plan or diff) is never embedded in the command line. `delegate.ps1` writes it to the read-only worktree's `.xagent/` and gives the reviewer the path. Every Cursor review during this design's own review read its target this way.
*   **Rule files removed.** Before a read-only run, `delegate.ps1` removes the CLIs' project rule files from the throwaway worktree, so the reviewer does not load project instructions as system context.
    *   **Exception.** The caller passes `-KeepRuleFiles` when rule files are part of the review target: changed in the diff under review, or listed in `GoldfishContext`.
    *   **Restoring.** The files are restored in a `finally` block. `-Cleanup` also restores them, so an aborted run cannot block cleanup.
*   **Report format.**
    *   Reviewers return Markdown with Blocker/Major/Nit findings.
    *   The lead does the synthesis EGM's synthesizer would do: it deduplicates and ranks findings into one report at `docs/features/<name>/reviews/<stage>-<n>.md`.
    *   Lens progress is derived from the fixed lens task ids, so a review survives compaction.
    *   **Nothing dropped silently.** Every finding from every lens either appears in the synthesized report or is logged in `decisions.md` as `[dismiss] <lens>: <finding> — <reason>`. Synthesis by the Claude lead can then not quietly drop a non-Claude reviewer's point.

### EGM integration

*   **Vendored copy.** The design and design-review stage files tell the lead to read and follow the vendored EGM `egm-draft`, `egm-review` and `egm-resolve` text in `skills/feature/egm/`. They also list where our flow differs from it:
    *   where EGM spawns a Claude reviewer agent, run `delegate.ps1` with the profile and persona from the routing table above;
    *   where EGM writes `design_draft.md`, write to `docs/designs/<name>.md`;
    *   EGM's question gates map to our gate recording.
*   **Unmodified text.** The vendored text stays unmodified. All differences live in our stage files, per decision 001.
*   **Sync.** v1 copies the files once and records commit `b7d9e27` in `THIRD_PARTY_NOTICES.md`. The sync script from decision 001 is written when the first upstream change arrives.

### Sign-off and final check (G6)

1.  Run the repo's full test command on `feature/<name>`.
2.  Run the final check:
    *   It runs as one strong-tier goldfish, using the vendored `egm-drift-report` procedure as its persona (`drift_report`).
    *   Its worktree is detached at `feature/<name>`. It is given the locked design and the path of a `git diff main...feature/<name>` file, both passed by file.
    *   It lists behaviour that is missing from the code, added beyond the design, or changed from it.
    *   `design_critic` on the whole diff is left out of v1. The drift report plus the full test suite is the G6 check.
3.  Show the results and ask for the **signed-off** gate.
4.  On approval, run `git switch main` and `git merge --no-ff feature/<name>` in the user's checkout. Then mark the feature `done`. Pushing happens only if the user asks.

## Alternatives Considered

### Alternative A: Adopt an existing tool instead of building `feature`

Candidates from [research §7](../research.md):
*   kodo: cross-vendor workers and a staged loop.
*   Spec Kit, Superpowers or BMAD: staged spec-driven flows.
*   amElnagdy/delegate-skills: per-CLI delegation.

*   **Pros**: These tools exist now and some are mature, with more users and testing than ours will have.
*   **Cons**:
    *   The spec frameworks run only on Claude subagents, which spends the Claude quota on every stage.
    *   kodo has no user-locked design and, by its own account, no independent verification gate, and it runs its agents with permission checks bypassed.
    *   delegate-skills has no feature-level flow.
    *   None targets native Windows PowerShell with a policy of keeping coding work off the Claude quota.
*   **Reason for Rejection**: Rejected by author: the project also exists to learn how to build cross-ecosystem multi-agent workflows, and to fit a personal workflow and a three-subscription budget. Ideas are borrowed instead: `touchedFiles`-style scope checks, cost tracking split between API and subscription, the `tasks.md` shape, file claims, and anonymized peer review.

### Alternative B: Call the installed EGM plugin instead of vendoring it

*   **Pros**: No copy to keep in sync, and upstream fixes arrive automatically.
*   **Cons**: All seven EGM skills set `disable-model-invocation: true`. Claude cannot start them, so each design stage would need a typed `/egm-*` command. That breaks G1. Flipping the flag in the installed plugin is undone silently by every plugin update.
*   **Reason for Rejection**: Rejected by author: it conflicts with plain-language entry. See [decision 001](../decisions/001-vendor-egm-workflow.md).

### Alternative C: One skill per stage

*   **Pros**: Each skill gets a precise description, and only one stage's text is loaded per invocation.
*   **Cons**: Five skill descriptions compete for phrases like "continue" and "where are we?". The active-feature, reconcile and gate rules would be repeated in each skill, or each would depend on a shared file anyway.
*   **Reason for Rejection**: Rejected by author: one router skill keeps the routing, reconcile and gate rules in one place, and loads stage files on demand.

### Alternative D: Local-only state, or all state committed

*   **Local only (`.xagent/features/`)**: Rejected by author. `git clean -fdx` deletes it, and a reclone or a second machine loses the gate approvals and the decision log.
*   **All state committed on the branch**: Rejected by author. Task status and session ids change constantly and would mean many noise commits.
*   **Chosen instead**: Lasting records (the plan, gates and decisions) are committed. Runtime state stays local.

### Alternative E: Create the feature branch at plan approval

*   **Pros**: The design and plan are visible on `main` early, and there is no branch to manage during design.
*   **Cons**: An abandoned design leaves commits on `main`. One feature's records end up split across `main` and its branch, and a design changed during the build diverges from the copy on `main`.
*   **Reason for Rejection**: Rejected by author: everything for a feature lives on its branch, and `main` changes only at sign-off.

### Alternative F: Side mode in v1 (a second feature in its own worktree)

*   **Considered while drafting**: main mode by default, plus a side mode on request. The side feature would get its own lead worktree at `<repo>.xagent/_feature-<name>`, and a `promote` command would later move it into the main checkout.
*   **Always a worktree per feature**: Rejected by author. To try a major feature, the user would have to open a different folder, and the checked-out branch could no longer pick the active feature.
*   **Side mode without `promote`**: Rejected by author, as a half-built side mode.
*   **Outcome**: Deferred by author after the zoom-out review. Side mode added a worktree, a name prefix, `promote`, two dirty-tree checks, overlap warnings between features, and two-folder logic in every subcommand. v1 is main mode only, and side mode is in Future Improvements.

### Alternative G: Other ways to handle state that disagrees with git

*   **Git always wins**: Rejected by author. Review round counts, session ids and waiting gates exist only locally and would be lost or guessed.
*   **State file wins, and every mismatch stops the flow**: Rejected by author. A harmless manual merge would interrupt the flow with a question.

### Alternative H: Claude subagents, or cheap models only, as goldfish

*   **Claude subagents (EGM's default)**:
    *   **Pros**: The strongest judgement, and tested isolation.
    *   **Rejected by author**: Every review spends Claude Pro quota, and the reviewer shares a model family, and so possibly blind spots, with the Claude author. A reviewer from another vendor avoids the same biases.
*   **Cheap cross-vendor models for every lens**: Rejected by author. Worker-tier models are too weak for the judgement lenses (architecture, hidden complexity, alternatives). The `delegate` preflight trials showed them over-asking on surface details.

### Alternative I: A fixed check-in policy

*   **Always check in after every phase**: Rejected by author. Too many interruptions for routine features, and the build can't run while the user is away.
*   **Always check in only on problems**: Rejected by author. Some complex features need a check after every phase, so the user needs to be able to turn that on.
*   **Chosen instead**: `on-problems` is the default, and the user can explicitly switch to `every-phase` for a feature.
*   **Reconfirmed after review**: The zoom-out reviewer proposed dropping `every-phase` and pausing only on request. Rejected by author: a pause request made once would not be remembered across phases or compaction, and the mode records it in `feature.json`.

### Alternative J: Antigravity (`agy`) as the second worker and reviewer provider

*   **Pros**: A second subscription (Google AI Pro), so load is split and a quota limit on one provider can fail over to the other. Gemini 4 Argon is a strong reviewer.
*   **Cons**: Google's FAQ says wrapping `agy -p` inside third-party coding agents is unsupported on consumer plans, and names Claude Code as third-party software whose use with an Antigravity login breaks the Terms, with suspension as a possible outcome (`docs/test-plan.md` T0, checked 2026-11-10). The supported route, an AI Studio API key, bills per token.
*   **Reason for Rejection**: Rejected by author: the subscription route breaks Google's terms, and paying per token was not wanted. Gemini models are still reachable through the Cursor CLI if a review ever needs them.

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Quota.** Claude runs only the lead. Workers, goldfish and councils run on the Cursor subscription.
    *   **Estimated third-party spend.** About $2–4 per feature out of the $20 third-party pool: GLM 5.2 at about $0.23 per review run, DeepSeek V4.1 Flash at about $0.05. Composer and Grok runs draw from the Cursor pool. These are estimates, to be checked against `runs.jsonl` after the first real feature.
    *   **Cost per feature.** One goldfish review of the design (about 9 lens runs over 5 stages), one of the plan (2 runs), one final check, plus any councils.
    *   **Measured during this design's own review.** A strong-tier lens run took 3–7 minutes and 80k–160k tokens.
    *   **Workers.** At most 2 run at once.
    *   **Lead bookkeeping.** Mechanical steps (scope check, tests, state updates) are done by `feature.ps1` in one call each, so the lead's context and Claude quota go to review and judgement.
*   **Safety.**
    *   The skill never merges to `main` or pushes without the **signed-off** gate.
    *   `feature.ps1` refuses to start a feature on a dirty working tree, and never runs `git reset --hard`, `git clean`, or a force push.
    *   Worker permissions are unchanged from `delegate`.
*   **Isolation.**
    *   **Mitigation.** Cross-vendor goldfish would load their CLI's project rules (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursor/`, `.agents/`). `delegate.ps1` removes those from the throwaway review worktree before launch.
    *   **Remaining risk (accepted).** User-level CLI settings outside the repo still load, so isolation is weaker than with EGM's Claude adapters.
*   **Rollback.**
    *   Abandoning a feature leaves `main` untouched. The branch and records stay until the user deletes them.
    *   Removing the skill means deleting the `~/.claude/skills/feature` junction. `delegate` keeps working on its own.

--------------------------------------------------------------------------------

### Future Improvements

*   **Side mode**: a second active feature in its own lead worktree (`<repo>.xagent/_feature-<name>`). It would come with `promote` to move it into the main checkout, and overlap warnings between features at plan approval. It was designed in the first draft and deferred (Alternative F).
*   **Brainstorm stage**: put the vendored `egm-brainstorm` in front of `design`, with an optional council.
*   **Benchmark mode per feature**: run `delegate`'s head-to-head benchmark on the tasks of a feature.
*   **Cost report per feature**: split API spend from subscription use (the kodo idea), using `benchmarks/runs.jsonl`.
*   **Anonymized peer review in the council** (the epicsagas idea).
*   **Data-driven model choice**: decide which tasks start on `code-hard` from `benchmarks/outcomes.jsonl` and benchmark results.
*   **Deploy stage**: an optional stage after sign-off, run by the lead with its own approval gate, using secret references only.
*   **A second subscription for overflow**: for example Antigravity through an API key, or another provider, if the Cursor pools turn out too small.
*   **EGM sync script** (`scripts/egm-sync.ps1`, per decision 001): written when the first upstream EGM change arrives.
*   **Whole-diff `design_critic` at sign-off**: add it if real features show the drift report is too weak on its own.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Names used below: `<repo>` is the user's checkout of the target repo, where `feature/<name>` is checked out while the feature is active, and `<name>` is the feature name.

### Target Files to Create/Modify

#### 1. `skills/feature/SKILL.md` (Create)

*   **Type / Scope**: Claude Code skill, the router. It is model-invocable, so it must not set `disable-model-invocation`.
*   **Proposed Changes**:
    *   **Frontmatter `description`**:
        *   It names the trigger: a request to design, review the design of, plan, build, continue, test, sign off, abandon, or check the status of a feature in this repo.
        *   It lists example phrases: "design a feature for X", "review the design", "plan it", "build it", "continue", "where are we?", "sign off".
        *   It says that a sentence only mentioning a feature is not a request.
    *   **Body**: the steps every invocation runs, in order:
        1.  Run `feature.ps1 status` with the current folder, which applies the active-feature rules.
        2.  Run `feature.ps1 reconcile`. On contradictions, show them and stop.
        3.  Say one line: feature, stage, the action about to be taken.
        4.  Read the single matching stage file and follow it.
    *   **The routing rules**, from the Technical Plan, quoted in full: invoking the skill, moving stage, passing gates, unclear replies.
    *   **A table mapping user phrases to stage files and subcommands.**
    *   **Rules that apply in every stage**:
        *   never merge to `main` without signed-off;
        *   every `feature.ps1` call is made with `-Repo <repo>`;
        *   Claude models are never used for workers or goldfish.

#### 2. `skills/feature/stages/design.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    *   If no feature exists, call `feature.ps1 new`. Ask for a name if none can be derived. Names are lowercase kebab-case of at most 31 characters.
    *   Then read and follow `skills/feature/egm/skills/egm-draft/SKILL.md`, applying these differences:
        *   Write to `docs/designs/<name>.md` in `<repo>`, not to `design_draft.md`.
        *   Commit after each approved section, with the message `feature(<name>): design – <section>`.
        *   Skip EGM Step 6.2 (picking the target folder).
        *   If the problem statement is missing, ask for it in chat. Don't point to `egm-brainstorm`.
    *   When all sections are approved, run `feature.ps1 stage -To design-review`.

#### 3. `skills/feature/stages/design-review.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    *   Read and follow the vendored `egm-review` SKILL.md, then the vendored `egm-resolve` SKILL.md. Where `egm-review` invokes `egm-review-loop`, read the vendored copy of that too. Apply these differences:
        *   **Reviewer runs.** Instead of spawning `egm:*` agents, run `delegate.ps1 -Agent cursor -Profile review -Persona <lens> -Model <model from the routing table>`. Alternate Grok 4.7 high and GLM 5.2 across the judgement lenses.
        *   **Task file.** It names the design doc's path and the `GoldfishContext` reading list, which the reviewer reads with its file tools. It does not embed the document.
        *   **Lens ids.** Each lens run uses the fixed task id `<name>-design<n>-<lens with _ as ->`. On resume, `feature.ps1 status` lists the lenses without a report. Continue from the first of them.
        *   **Dismissals.** Log every finding not carried into the report with `feature.ps1 decision -Kind dismiss`.
        *   **Synthesis.** The lead does the synthesizer's job, following `egm/agents/synthesizer.md`. It writes `docs/features/<name>/reviews/design-<n>.md`.
        *   **Checkpoints.** The stage checkpoints in EGM become chat questions. They are not recorded gates.
    *   After resolution, ask for **design-locked**. On a clear yes:
        1.  Run `feature.ps1 gate -Gate design-locked -Quote "<user words>"`.
        2.  Set the design doc's `Status:` to `Approved`.
        3.  Run `feature.ps1 stage -To plan`.

#### 4. `skills/feature/stages/plan.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    *   **Write the plan.** Produce a plan as JSON, matching `$defs/plan` in `feature.schema.json`, in a temporary input file at `<repo>/.xagent/features/<name>/plan-input.json`. `feature.ps1 plan` imports it into `feature.json`, which is the only source of the plan, and then deletes the input file. The plan has a `summary` paragraph and is split into phases. Each phase has a `rationale` and a test command, and each task has:
        *   an id
        *   a title
        *   `dependsOn`
        *   `files`: the files and folders it may touch
        *   `test`: the exact test command
        *   `profile`: `code` or `code-hard`
        *   `brief`: one paragraph the task file will expand
    *   **Plan rules.**
        *   Every task is a worker task. Architecture is settled in the design, and cross-cutting changes become worker tasks with broad `files`.
        *   Steps that `delegate` never delegates (anything needing secrets or credentials, and deploy steps) are listed in the plan as steps for the user.
        *   Each phase has a phase test command, and the last phase's test is the full suite.
    *   **Import and check it.**
        1.  Run `feature.ps1 plan -PlanFile <path>`. It validates the plan, writes it into `feature.json`, generates `plan.md` from `feature.json`, and appends a decision.
        2.  Run the plan goldfish: `comprehension` and `implementation_readiness` on `plan.md`, `comprehension` on Composer 2.5 and `implementation_readiness` on DeepSeek V4.1 Flash.
        3.  Triage the findings per `delegate`'s rule (fix what would make two workers build different things).
        4.  To change the plan, write a new complete input file and import it again. `plan.md` is never edited by hand.
    *   **Re-plan after going back.** If tasks are already merged, the input must list each of them with `carry: keep` or `carry: redo`. At approval, show the keep/redo list, and the reverts that approval will cause, next to the plan.
    *   **Offer a council** if the plan contains a choice that is hard to reverse.
    *   **Approve.**
        *   Ask for **plan-approved**, stating that the check-in mode is `on-problems` unless the user says "check in every phase".
        *   On a clear yes, run `feature.ps1 gate -Gate plan-approved -Quote ... -Checkin <mode>`. On a re-plan, this also runs the `redo` reverts and raises the generation. Then run `stage -To build`.

#### 5. `skills/feature/stages/build.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**: The file says first: "Follow `delegate`'s loop (task file, preflight, run, review, iterate, merge, cleanup). This file lists only what differs for feature tasks." The differences:
    *   **Picking tasks.** Take tasks only from `feature.ps1 schedule`, which returns each ready task with its worker model. Run both ready tasks in the same message when two are ready.
    *   **Running a task.**
        *   Before the preflight, call `feature.ps1 task -Status preflight`. Before the worker run, call `task -Status running`.
        *   Pass `-Agent cursor -Model <worker model from schedule> -Base feature/<name> -Repo <repo>` to `delegate.ps1`.
    *   **Preflight.**
        *   `comprehension` runs with `-Model <worker model from schedule>`.
        *   `implementation_readiness` runs with `-Model <DeepSeek V4.1 Flash>`.
        *   It runs when `delegate`'s preflight rules call for it.
    *   **After each worker run.** Call `feature.ps1 verify -Task <id>` before reading the diff. If it reports files out of scope, make a problem stop.
    *   **Usage limit.** Call `feature.ps1 cooldown -Pool <cursor|thirdParty>`.
        *   For the Cursor pool, make a problem stop.
        *   For the third-party pool, continue, with GLM and DeepSeek seats replaced by Grok 4.7 high, and say so in the report.
    *   **Review rounds.** Update `task -Round <n>` each round.
    *   **Council escalation.** The round limit is the feature rule in the Technical Plan (`code`: 2 failed rounds, `code-hard`: 1), which replaces `delegate`'s "about 3 rounds" for feature tasks. When it is reached, convene the council per `delegate`'s procedure, then do one of the following.
    *   **Consensus, and the task's council count was 0 or 1.**
        1.  Append the outcome with `feature.ps1 decision -Kind council`.
        2.  Raise the count with `task -Councils <n>`.
        3.  Retry on `code-hard`, with the council's guidance added to the task file as a delta brief.
        4.  Keep going.
    *   **Disagreement, or a failure after the second council.**
        1.  Append the outcome to `decisions.md` (`feature.ps1 decision`).
        2.  Run `task -Status escalated`.
        3.  Make a problem stop.
    *   **Merge.** On accept:
        1.  Commit in the worker worktree.
        2.  Run `feature.ps1 merge -Task <id> -Message "<msg>"`.
        3.  Run `delegate -Cleanup`.
    *   **Phase end.** When all tasks of a phase are merged:
        1.  Run the phase test in `<repo>`. Fix it if the fix is small (logged as a fix-up decision). Otherwise make a problem stop.
        2.  If the check-in mode is `every-phase`, report and stop.
        3.  Otherwise, continue to the next phase.
    *   **End of build.** When the last phase is done, run `stage -To signoff` and report.
    *   **Problem stop.**
        *   **Stopping.** Run `feature.ps1 decision -Kind stop -Text "<why>"`, which commits it, then report to the user and end the turn.
        *   **Resuming.** When the user says to go on, first run `decision -Kind resume -Text "<what was decided>"`.

#### 6. `skills/feature/stages/signoff.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    1.  Run the full test command in `<repo>`.
    2.  Write `git diff main...feature/<name>` to `<repo>/.xagent/features/<name>/final.diff`.
    3.  Write a task file naming the locked design's path and the diff file's path.
    4.  Run `delegate.ps1 -Profile review -Persona drift_report -Agent cursor -Model <Grok 4.7 high or GLM 5.2> -Base feature/<name>`, with the fixed task id `<name>-signoff<n>-drift-report`. Pass `-KeepRuleFiles` if the diff changes any CLI rule file.
    5.  Show the test results and the findings, grouped as missing, added or changed behaviour.
    6.  Ask for **signed-off**. On a clear yes:
        1.  Run `feature.ps1 gate -Gate signed-off -Quote ...`.
        2.  Run `feature.ps1 finish`.
        3.  Ask whether to push.

#### 7. `skills/feature/stages/status.md` (Create)

*   **Type / Scope**: Stage instructions for "where are we?".
*   **Proposed Changes**: Print the output of `feature.ps1 status` as a short report:
    *   stage and phase
    *   tasks by status
    *   what the flow is waiting on
    *   the last 3 decisions
    *   the action "continue" would take

    Make no changes. With no active feature, list the features in progress.

#### 8. `skills/feature/scripts/feature.ps1` (Create)

*   **Type / Scope**: PowerShell 7 script. It is the only writer of feature state. It prints one compact JSON object on stdout: exit 0 on success, exit 1 with `{ok:false,error}` on failure, like `delegate.ps1`.
*   **Proposed Changes**:
    *   **Common parameters**:
        *   `-Repo` (mandatory, the main checkout top level)
        *   `-Name` (pattern `^[a-z0-9][a-z0-9-]{0,30}$`)
        *   `-Cwd` (used only by `status`)
    *   **Folders and commits.**
        *   `.xagent/` is added to `info/exclude` the same way `delegate.ps1` does it.
        *   Record commits are made in `<repo>`. Each commit stages only the files under `docs/features/<name>/`, or the design doc for `design` commits.

    | Subcommand | Arguments | Behaviour |
    |---|---|---|
    | `new` | `-Name` | Fail if the working tree is dirty, the branch exists, or another feature is not `done`/`abandoned`. Run `git switch -c feature/<name> main`. Write `feature.json` (stage `design`, `generation: 1`, `checkin: on-problems`) and `decisions.md`, and commit `feature(<name>): start`. Write the local `state.json`. |
    | `status` | `[-Name]`, `-Cwd` | Compute `waitingOn` (a gate, an open stop, a cooldown, or a running worker) and, during a goldfish review, the lenses with no report yet. Without `-Name`, apply the selection rules. Rule 2 reads `git -C <Cwd> branch --show-current`. Rule 3 scans `.xagent/features/*/state.json` plus branches `feature/*` whose stage is not `done`/`abandoned`. Output the selected feature's merged view (committed plus local) with `nextAction`, or `{selected:null, features:[...]}`. |
    | `reconcile` | `-Name` | Apply the reconcile table. Output `{changes:[], contradictions:[], lost:[]}`. Contradictions don't change anything. |
    | `stage` | `-Name`, `-To`, `-Reason` | Forward moves are allowed only one step at a time, and only when the gate is recorded. Backward moves are allowed to any earlier stage: they clear later gates and append a decision. `abandoned` is allowed from any stage. Commit. |
    | `gate` | `-Name`, `-Gate`, `-Quote`, `[-Checkin]` | The gate must match the current stage (`design-review` → `design-locked`, `plan` → `plan-approved`, `signoff` → `signed-off`). Record `{at, quote}`, append a decision and commit. `-Checkin` is allowed only with `plan-approved`. On `plan-approved` with `redo` tasks: revert each one's current merge with `git revert -m 1 --no-edit`, newest first, then amend each revert message to add `Xagent-Revert: <id>`. On conflict, run `git revert --abort` and fail, naming the files and tasks; the gate is not recorded. On success, raise `generation` by 1. |
    | `plan` | `-Name`, `-PlanFile` | Validate against the plan part of `feature.schema.json`: unique ids, existing `dependsOn`, no cycles, a dependency's phase ≤ the task's phase, non-empty `files`, `taskId` ≤ 49 characters. Every task currently merged must appear with `carry: keep` or `carry: redo`, and `carry` is rejected on other tasks. Write the summary and phases into `feature.json`, generate the whole `plan.md` from it (summary, then each phase's rationale and test, then a task table), and delete the input file. Commit. Allowed only in stage `plan`. |
    | `schedule` | `-Name` | From the current phase (the lowest phase with tasks not yet merged), return tasks that are `pending`, have every dependency `merged`, and whose files overlap no `preflight`/`running`/`in-review` task. Cap the total of preflight, running and in-review tasks at 2. If the Cursor pool is cooling down, return `{blocked: "quota", until}`. Each task includes the worker `model` for its profile, read from `delegate`'s `models.json`. |
    | `task` | `-Name`, `-Task`, `[-Status] [-DelegateTaskId] [-SessionId] [-Round] [-Councils] [-ResultFile]` | Update local `state.json` only. Status is one of `pending`, `preflight`, `running`, `in-review`, `merged`, `failed`. |
    | `verify` | `-Name`, `-Task` | In the task's worker worktree: list the changed files (`git diff --name-only <base>...HEAD` plus uncommitted and untracked files), and match them against the task's `files` (exact, parent folder, or glob). Run the task's `test` command there with a 15-minute timeout. Store the result and print `{inScope, outOfScope:[], test:{command, passed, exitCode, tail}}`. Change nothing in the worktree. |
    | `cooldown` | `-Name`, `-Pool <cursor\|thirdParty>`, `[-Clear]` | Set the pool's `cooldownUntil` to now plus 60 minutes and append a decision, or clear it. |
    | `merge` | `-Name`, `-Task`, `-Message` | In `<repo>`: `git merge --no-ff xagent/<delegateTaskId>` with the message `<Message>` plus a blank line plus `Xagent-Task: <task id>`. On conflict, run `git merge --abort` and fail with the conflicting files. The message also gets the trailer `Xagent-Gen: <generation>`. On success, set the task to `merged` and append the task outcome line to `benchmarks/outcomes.jsonl` (in the cross-agent-loop repo, next to `runs.jsonl`). |
    | `decision` | `-Name`, `-Kind`, `-Text` | Append `- <ISO time> [<kind>] <text>` to `decisions.md` and commit. Kinds: `decision`, `council`, `fix-up`, `scope`, `gate`, `stage`, `dismiss`, `stop`, `resume`. `resume` fails if there is no open `stop`. |
    | `checkin` | `-Name`, `-Mode` | Set `on-problems` or `every-phase` in `feature.json`, append a decision and commit. |
    | `finish` | `-Name` | Require `signed-off`. In `<repo>`: `git switch main` and `git merge --no-ff feature/<name> -m "Merge feature/<name>"`. Set the stage to `done` and commit the final `feature.json` on `main`. Never push. |

    *   **Path overlap.** Normalize both paths (forward slashes, no trailing slash, lowercase on Windows). They overlap if they are equal or one starts with the other plus `/`.

#### 9. `skills/feature/feature.schema.json` (Create)

*   **Type / Scope**: One JSON Schema. The plan input is validated against its `$defs/plan`, so the task structure is defined once.
*   **Proposed Changes**:
    *   **`feature.json` fields**:
        *   `name`, `generation`, `stage` (`design`|`design-review`|`plan`|`build`|`signoff`|`done`|`abandoned`)
        *   `checkin` (`on-problems`|`every-phase`), `designDoc`
        *   `gates`: an object keyed by the gate name, each holding `{at, quote}`
        *   `summary`, and `phases`: an array of `{n, rationale, test, tasks:[task]}`
    *   **Task fields (`$defs/task`)**: `id`, `title`, `dependsOn`, `files`, `test`, `profile` (`code`|`code-hard`), `brief`, and `carry` (`keep`|`redo`), which is allowed only on a re-plan.

#### 10. `skills/feature/state.schema.json` (Create)

*   **Type / Scope**: JSON Schema for the local `state.json`.
*   **Proposed Changes**:
    *   `name`, `lastReconcile`
    *   `tasks`: keyed by task id, each holding `status`, `delegateTaskId`, `sessionId`, `round`, `councils`, `resultFile`, `verify` (the last `verify` output)
    *   `pools`: `{cursor: {cooldownUntil}, thirdParty: {cooldownUntil}}`

#### 11. `skills/feature/templates/decisions.md` (Create)

*   **Type / Scope**: The template that `feature.ps1 new` copies.
*   **Proposed Changes**:
    *   `decisions.md` has a header and an empty log.
    *   `plan.md` is fully generated by `feature.ps1 plan`, so it needs no template.

#### 12. `skills/feature/egm/` (Create, vendored, unmodified)

*   **Type / Scope**: A copy of upstream EGM at commit `b7d9e27`. The upstream relative paths are kept, so diffing is direct.
*   **Proposed Changes**: Copy these files:
    *   `skills/egm-draft/SKILL.md` and `skills/egm-draft/references/design_doc.md`
    *   `skills/egm-review/SKILL.md`, `skills/egm-resolve/SKILL.md`, `skills/egm-review-loop/SKILL.md`
    *   `resources/execution_instructions.md` and `resources/document_standards/*.md` (5 files)
    *   `agents/synthesizer.md`
    *   `LICENSE` (as `LICENSE-egm`)

#### 14. `skills/delegate/personas/` (Modify: add files)

*   **Type / Scope**: Goldfish personas run by `delegate.ps1`. Keeping one copy here avoids duplicating persona files between the skills.
*   **Proposed Changes**:
    *   Add the unmodified upstream `zoom_out.md`, `inventive_catalyst.md`, `codebase_details.md`, `structural.md`, `style.md` and `zoom-out-standard.md`. These were copied during this design's review.
    *   Add the unmodified upstream `skills/egm-drift-report/SKILL.md` as `drift_report.md`, so the sign-off check can run it as a persona.
    *   Add `standards.json`, which maps each persona to the standard file appended to it: `implementation_readiness` → `implementation-readiness-standard.md`, `zoom_out` → `zoom-out-standard.md`.
    *   Update `README.md`.

#### 15. `skills/delegate/scripts/delegate.ps1` (Modify)

*   **Type / Scope**: Worker launcher.
*   **Proposed Changes**:
    *   **Target by file (review and council runs).**
        *   The hand-off file holds the persona, the standard and the caller parameters, then a line naming the target's path.
        *   The target itself (the `-TaskFile` content) is written to `.xagent/target-<stamp>.md` in the worktree.
        *   For agy, only the control part is embedded in the command line. The 28,000-character check then applies only to that part.
        *   The prompt tells the reviewer to read the target file with its file tools.
    *   **Rule files removed.** In read-only runs:
        *   Before launch, delete `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursor/`, `.cursorrules` and `.agents/` from the throwaway worktree, wherever they exist in its tree. Record the deleted paths.
        *   After the process exits, and before the read-only check, restore them with `git -C <wt> checkout -- <paths>` inside a `finally` block. The read-only check then does not report them.
        *   A new switch, `-KeepRuleFiles`, skips the removal when rule files are part of the review target.
        *   `-Cleanup` of a read-only worktree first restores any deleted tracked rule files, so an aborted run does not block it.
    *   **Standards lookup.** Replace the hard-coded `implementation_readiness` standard injection with a lookup in `personas/standards.json`.
    *   **No new profile.** Judgement-lens reviews use `-Profile review -Model <id>`, which already works.
    *   **Council seats.** Both council members now run on the Cursor CLI. A new `-Seat <label>` parameter names the worktree and the logs (`<id>-grok`, `<id>-glm`) instead of the agent name. Without it, two Cursor members would collide on `<id>-cursor`.
    *   **agy disabled.** `-Agent agy` fails with the T0 reason unless `models.json` sets `agy.enabled: true`, kept for a possible API-key setup later.

#### 16. `skills/delegate/models.json` (Modify)

*   **Type / Scope**: Model profiles.
*   **Proposed Changes**:
    *   `code`: `composer-2.5`.
    *   `code-hard`: `grok-4.7-high`.
    *   `review`: `composer-2.5` by default, plus named seats for the stage files to pass as `-Model`:
        *   `readiness: deepseek-v41-flash-1017-medium`
        *   `judgement: [grok-4.7-high, glm-5.2-high]`
    *   `council`: seats `grok-4.7-high` and `glm-5.2-high`.
    *   All `agy` model entries are removed, and `agy: {enabled: false, reason: "T0"}` is added. Claude models stay blocked.

#### 17. `skills/delegate/SKILL.md` (Modify)

*   **Type / Scope**: Docs.
*   **Proposed Changes**:
    *   Document the model seats, `-Seat` for council members, and that `agy` is disabled with the T0 reason, replacing the old cursor-or-agy routing advice.
    *   Document that review and council targets are passed by file, and that rule files are removed in read-only runs.
    *   Note that `feature` uses `delegate` and merges with the `Xagent-Task` trailer.
    *   Add the `-Base feature/<name>` usage.

#### 19. `skills/feature/tests/feature.Tests.ps1` (Create)

*   **Type / Scope**: Pester 5 tests. The file starts with `#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.0'}`. Each test builds a throwaway repo in `$TestDrive` with a `main` commit and calls `feature.ps1` as a child process, checking its JSON.
*   **Proposed Changes**: These cases:
    *   **`new`**:
        *   refuses a dirty tree
        *   refuses a bad name
        *   refuses a second active feature
        *   creates the branch, switches to it, and commits with `generation: 1`
    *   **`stage` and `gate`**:
        *   a forward move without the gate fails
        *   the gate in the wrong stage fails
        *   the gate records the quote and time
        *   a backward move clears later gates
    *   **`plan`**:
        *   rejects a cycle
        *   rejects an unknown dependency
        *   rejects a dependency in a later phase
        *   rejects a duplicate id
        *   rejects an over-long task id
        *   generates `plan.md` from `feature.json` and deletes the input file
    *   **`schedule`**:
        *   dependency gating
        *   exact-path overlap
        *   parent-folder overlap
        *   the cap of 2
        *   returned tasks include the profile's worker `model`
        *   the cap counts `preflight` tasks
        *   a Cursor-pool cooldown returns `blocked: quota` with the end time
        *   a glob entry counts as its literal folder for overlap
        *   phase advance
    *   **`merge` and `reconcile`**:
        *   a trailer merge is marked merged after the task branch is deleted
        *   a merge appends one task outcome line with every field filled in
        *   a merge carries both the `Xagent-Task` and `Xagent-Gen` trailers
        *   a manual merge with the trailer is absorbed
        *   local `merged` without a trailer is a contradiction
        *   a missing branch is a contradiction
        *   another branch checked out while the feature is active asks to switch back
        *   a feature merged to `main` without `signed-off` is a contradiction
        *   a missing local file is rebuilt and the losses are reported
    *   **`verify`**:
        *   in-scope changes, including glob matches
        *   an out-of-scope file is reported
        *   an untracked new file is counted
        *   a failing test is reported with its exit code
        *   the worktree is left unchanged
    *   **`cooldown`**:
        *   a cooldown expires after its time
        *   `-Clear` clears it
    *   **Re-plan (keep and redo)**:
        *   a re-plan missing a merged task is rejected
        *   `carry` on a never-merged task is rejected
        *   approval reverts `redo` merges newest first with `Xagent-Revert` and raises the generation
        *   `keep` tasks stay merged under the new generation
        *   an old-generation merge without `keep` does not count as merged
        *   a conflicting revert aborts cleanly and the gate is not recorded
    *   **Stops and derived status**:
        *   a `[stop]` with no `[resume]` is reported as waiting, even with `state.json` deleted
        *   `resume` without an open stop fails
        *   lens progress is read from `.xagent/runs/<lens id>/*.review.md`
    *   **`status`**: each of the 4 selection rules.
    *   **`finish`**:
        *   fails without signed-off
        *   merges and sets `done`
        *   never pushes (the test repo has no remote)

#### 20. `docs/test-plan.md` (Modify)

*   **Type / Scope**: Docs.
*   **Proposed Changes**: Add a `feature` section:
    *   the Pester command
    *   how to install Pester 5 (`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck`)
    *   a manual checklist that runs CUJ 1–7 on the `sandbox` repo, with each check covering one goal's pass check (G1–G7)

#### 21. `THIRD_PARTY_NOTICES.md` (Modify)

*   **Type / Scope**: Licensing.
*   **Proposed Changes**:
    *   List every file from items 12 and 14 under EGM, at commit `b7d9e27`, as unmodified.
    *   Include `drift_report.md` (from `skills/egm-drift-report/SKILL.md`) and the six persona and standard files added in item 14.

#### 22. `docs/decisions/001-vendor-egm-workflow.md` (Modify)

*   **Type / Scope**: Decision record.
*   **Proposed Changes**: Record the final layout:
    *   the workflow text in `skills/feature/egm/`
    *   the personas in `skills/delegate/personas/`
    *   the sync script deferred until the first upstream change

#### 23. `README.md` and `docs/HANDOFF.md` (Modify)

*   **Type / Scope**: Docs.
*   **Proposed Changes**:
    *   **README**: add a short `feature` section: what it does, example phrases, and the stages and gates.
    *   **HANDOFF**: replace the "Next" section with the build status.

#### 24. `docs/designs/feature-skill.md` (Create)

*   **Type / Scope**: This design, finalized.

#### 25. Machine setup (outside the repo; not committed)

*   Create the junction `~/.claude/skills/feature` → `D:\cross-agent-loop\skills\feature`.
*   Add `Bash(pwsh -NoProfile -File D:/cross-agent-loop/skills/feature/scripts/feature.ps1 *)` to `~/.claude/settings.json` permissions.
*   Install Pester 5 for the current user.

### Build order

1.  **delegate changes** (items 14–17): target by file, rule-file removal, standards lookup, model seats, `-Seat`, agy disabled. Re-run the existing `delegate` checks.
2.  **`feature.ps1`, its schemas, and templates, and the Pester tests** (items 8–11 and 19). These are written test-first.
3.  **Vendored EGM and the notices** (items 12 and 21).
4.  **The router and stage files** (items 1–7).
5.  **Docs and machine setup** (items 20 and 22–25).
6.  **The manual CUJ checklist** on `sandbox`.

Steps 2 and 3 do not share files and can be delegated in parallel. Step 4 is written by the lead, because it is prompt design.

### Verification Plan

*   **Unit tests**: `pwsh -NoProfile -c "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester skills/feature/tests -Output Detailed"`. All cases in item 19 pass.
*   **delegate regression**: re-run the `delegate` checks in `docs/test-plan.md` that touch profiles and personas. Also add these checks:
    *   One judgement-lens review on Grok 4.7 high and one on GLM 5.2, of this design doc passed by file.
    *   `-Agent agy` fails with the T0 reason.
    *   One DeepSeek V4.1 Flash readiness review.
    *   One read-only run in a repo that has an `AGENTS.md`. It must report no violation, and the rule file must be back after the run.
    *   One read-only run that is killed mid-run, followed by `-Cleanup`, which must succeed.
    *   One `council` run with two Cursor seats (`-Seat grok`, `-Seat glm`), to confirm they don't collide and that the target-by-file change did not break it.
*   **End to end**: the manual CUJ 1–7 checklist on the `sandbox` repo, in fresh sessions:
    *   CUJ 2 is run after `/clear`.
    *   CUJ 7 checks that "ok" does not pass a gate.
    *   G1 is verified by saying each phrase without naming the skill.

--------------------------------------------------------------------------------

<!-- Provenance: Indicates initial structural drafting via EGM. -->

*Drafted with EGM*
