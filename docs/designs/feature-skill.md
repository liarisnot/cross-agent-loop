# `feature` skill: plain-language, feature-level development flow

*   **Author:** Eugene Chin
*   **Status:** Approved (locked 2026-11-11)
*   **Date:** 2026-11-09 (revised 2026-11-11 after review stages 5–9)
*   **Amended:** 2026-11-13, after the build. The build's task files settled details this design left open or got wrong, and they are written back here: `reconcile`'s output and finished-run rule, the second-failure stop off the feature branch, the entry rows the router handles itself, and on-request council ids. No goal, gate or stage changed.
*   **Amended:** 2026-11-15: worker sandboxing shipped (docs/designs/worker-sandbox.md). No goal, gate or stage changed.

--------------------------------------------------------------------------------

## Overview

`feature` is a Claude Code skill. It takes one feature from design to a merged branch. Claude Code is the lead programmer. Workers on the Cursor CLI do the coding through the existing `delegate` skill, and the user approves each major step.

The user drives it in plain language. "Design a feature for X", "plan it", "build it", "continue" and "where are we?" each map to a stage (see the [entry-point table](#entry-point-table)). The skill keeps each feature's progress in files in the repo, so the work survives context compaction and new Claude Code sessions.

Version 1 covers five stages plus a status query:

1.  design
2.  design review
3.  plan
4.  build
5.  test and sign-off

For hard or contested problems, the skill can bring in a multi-model council (Claude, Grok 4.7 and GLM 5.2) at any stage. The design stages reuse the Elephant-Goldfish Model (EGM) workflow, copied into this repo per [decision 001](../decisions/001-vendor-egm-workflow.md). The build stage reuses `delegate.ps1`, with the changes listed in [Changes to `delegate` in v1](#changes-to-delegate-in-v1). Brainstorming and benchmark mode come later.

--------------------------------------------------------------------------------

## The Problem

The user is a single developer on Windows, with a Claude subscription and a Cursor subscription. They want to take a feature to `main` without spending Claude quota on coding or review. Today, building a feature with this project's tools means the user runs each piece by hand and keeps the state in their head:

*   **Typed commands.** EGM's skills are user-only (`disable-model-invocation`), so each design stage needs a typed `/egm-*` command with arguments. The user wants to say what they want, not remember command names and parameters.
*   **No memory across sessions.** A feature takes several sessions. Today progress lives only in the conversation and a hand-written `docs/HANDOFF.md`. After a context compaction or in a new session, the lead has to rebuild where things stand.
*   **No link from design to build.** `delegate` works one task at a time. Nothing turns a locked design into an ordered set of tasks, decides which tasks can safely run in parallel, gathers their results on one branch, or checks the finished code against the design.
*   **Gates are informal.** Whether the design is locked, the plan approved, or the result signed off is not recorded anywhere. Nothing stops the flow from moving past a step the user never approved.

Similar tools exist (see [research §7](../research.md#7-landscape-survey-similar-projects-2026-11-09)). The spec-driven frameworks (Spec Kit, Superpowers, BMAD) have stages and gates, but they run only on Claude subagents. kodo has workers from other vendors, but no user-locked design and, by its own account, no independent verification gate. None of them targets native Windows PowerShell with a policy of keeping coding work off the user's Claude quota.

--------------------------------------------------------------------------------

## Goals

*   **G1. Plain-language entry.** Every v1 stage and the status query start from a plain-language request. No step requires the user to type a slash command or a parameter. Pass: each phrase in the [entry-point table](#entry-point-table), said in a fresh session, starts the right action, and each "must not fire" phrase starts nothing.
*   **G2. Resumable from disk.** A fresh session that knows nothing about the feature can answer "where are we?". It gives the current stage, what is done, what is waiting on the user, and the next action. It reads only files on disk. Pass: the answer is correct after `/clear`, for a feature paused at each stage, including with a worker run that was killed mid-run.
*   **G3. Recorded user gates.** The flow stops at three gates: design locked, plan approved, and final sign-off. It does not move past a gate until the user approves. Each approval is written to the feature's records with a timestamp and the user's words. During the build, the flow also stops on problems. It stops after each phase only when the user has turned on phase check-ins for that feature.
*   **G4. Isolated build, no Claude-written feature code.**
    *   **One branch.** All code for a feature lands on one integration branch, `feature/<name>`, and `main` changes only after the user signs off.
    *   **Workers code.** Coding tasks go to Cursor workers through `delegate`: Composer 2.5, or Grok 4.7 high for `code-hard`.
    *   **Claude reviews and merges.** It does not write feature code, and the plan cannot assign code to it.
    *   **One exception: fix-ups during review.** When fixing an issue directly costs less, in tokens and in time, than another worker round, the lead fixes it and records it.
    *   **Pass:** the plan schema has no profile that assigns code to the lead, and every fix-up appears as a `[fix-up]` line, with its file and line counts, followed by a `verify` run.
*   **G5. Safe parallelism.** Two tasks run at the same time only if their declared file sets do not overlap and neither depends on the other. Otherwise they run one after another. Pass: the `schedule` overlap tests pass, and `reconcile` never finds two overlapping tasks `running` together.
*   **G6. Final check against the design.** Before sign-off, the whole feature diff is checked against the locked design for missing, extra or changed behaviour, and the user sees the result. Pass: the drift report's three lists are shown before every **signed-off** prompt.
*   **G7. Council on hard problems.** The skill brings in the existing multi-model council (`delegate`'s `council` profile: Grok 4.7 high and GLM 5.2, both through Cursor, with Claude as lead) at three points. It is not a separate stage.
    *   **Design or plan:** the skill offers it for a decision that is hard to reverse or contested.
    *   **Build:** it convenes one automatically when a `code` task fails review twice, or a `code-hard` task fails review once.
        *   **Consensus:** the build retries the task with the council's advice, without stopping.
        *   **Disagreement, or the task has already had 2 councils:** the build stops for the user.
    *   **Any stage:** it convenes one when the user asks.

    It does not convene one for routine work. A council runs two frontier seats, each costing about one judgement-lens run (1–10 minutes per seat during this design's review), plus a second round when needed. Each council's outcome is recorded in the feature's decisions.

    Pass: each trigger produces a `[council]` line. Consensus is followed by a retry, and disagreement by a `[stop]`.

--------------------------------------------------------------------------------

## Non-Goals

*   **Brainstorm stage.** Deferred. v1 starts from a problem statement the user gives in chat or from an existing brief.
*   **Benchmark mode.** Deferred, both inside `feature` and in `delegate`. `delegate`'s head-to-head mode ran Cursor against `agy`, so with `agy` disabled it has no second worker. Its `SKILL.md` section is marked unavailable in v1.
*   **Cloud or remote agents.** Workers and goldfish run locally through the Cursor CLI only.
*   **Automating Antigravity on a consumer plan.**
    *   **Why not.** Google's Antigravity FAQ calls wrapping `agy -p` inside third-party coding agents unsupported on consumer plans. It names Claude Code as third-party software whose use with an Antigravity login breaks the Terms (checked 2026-11-10, [T0 in `docs/test-plan.md`](../test-plan.md#t0-policy-check-antigravity)).
    *   **What v1 does.** It sends no work to `agy`. The Google Pro plan stays for the user's own interactive use.
    *   **The API-key route isn't used either,** because it bills per token ([Alternative J](#alternative-j-antigravity-as-the-second-worker-and-reviewer-provider)).
*   **Deploying.** v1 ends at the merge into `main`.
    *   **Workers** never handle secrets, credentials or deploy steps.
    *   **The lead** may run a deploy or operations step only with the user's explicit approval at that step, and only using secret references (environment variables or a secret store), never secret values.
    *   **A `deploy` stage** is in [Future Improvements](#future-improvements).
*   **macOS or Linux support.** v1 targets Windows and PowerShell 7, matching `delegate.ps1`.
*   **Several people or sessions on one feature.** One user and one lead session own a feature at a time. There is no locking between machines. On one machine, a lock stops a second session from changing the same feature (see [State model](#state-model)).
*   **More than one active feature (side mode).** Deferred. v1 runs one feature at a time, in the user's checkout ([Alternative F](#alternative-f-side-mode-in-v1)).
*   **Merging to `main` without the user.** The skill never merges to `main` or pushes without explicit sign-off.
*   **Replacing EGM's review content.** We reuse EGM's personas and standards. Changing how a goldfish reviews is out of scope, except for the drift-report persona, which is adapted ([item 13](#13-skillsdelegatepersonas-modify)).
*   **Plugin packaging.** v1 is installed as a personal skill ([Installation](#installation)). Packaging as a Claude Code plugin comes after v1.

--------------------------------------------------------------------------------

## Open Questions

None open. Every question raised while drafting and reviewing is answered in the Technical Plan. The decision log for this design is in [`docs/designs/reviews/feature-skill/`](reviews/feature-skill/).

--------------------------------------------------------------------------------

## Critical User Journeys (CUJs)

### CUJ 1: Start a design from a problem statement

*   **Given**: A repo with no active feature and a clean working tree. The user is in a Claude Code session in that repo.
*   **When**: The user says "let's design an export-to-PDF feature: users need to …".
*   **Then**:
    *   The skill proposes the name `export`, and the user confirms it.
    *   The skill creates the branch `feature/export` from `main` and switches the user's checkout to it.
    *   It creates the feature's records with stage `design`.
    *   It drafts `docs/designs/export.md` one section at a time, following the vendored EGM draft workflow. The user approves each section.
    *   When drafting finishes, the stage moves to `design-review`.

### CUJ 2: Resume after a fresh session

*   **Given**: Feature `export` is paused in the middle of the build.
    *   Phase 2 of 3 is running.
    *   Task `export-renderer` is merged, and task `export-cli` is waiting on review round 2.
    *   A third task's worker process died when the user ran `/clear`.
*   **When**: The user says "where are we?".
*   **Then**: Reading only files on disk, the skill reports:
    *   the stage (build, phase 2 of 3)
    *   which tasks are done, running, waiting or failed (the dead run shows as `failed` and its slot is free)
    *   what is waiting on the user (nothing, an open problem stop, or a named gate)
    *   the feature's token use so far
    *   the next action it will take on "continue"

### CUJ 3: Review and lock the design

*   **Given**: Feature `export` is at stage `design-review`.
*   **When**: The user says "review the design".
*   **Then**:
    *   The skill runs the goldfish review phases and commits each reviewer's raw report.
    *   It writes one synthesized report with Blocker, Major and Nit findings.
    *   It walks the user through resolving each finding. Any finding left out of the report is logged as dismissed, with a reason.
    *   It asks for the design-lock gate. Only after the user explicitly approves does it record the lock and move to `plan`.

### CUJ 4: Plan and approve

*   **Given**: The design for `export` is locked.
*   **When**: The user says "plan it" (or "plan the feature").
*   **Then**:
    *   The skill writes a plan with phases and tasks. Each task has its dependencies, its declared files, a test command and a profile (`code` or `code-hard`).
    *   Steps that must not be delegated, such as anything needing secrets, are listed as steps for the user.
    *   It runs a goldfish comprehension and readiness check on the plan and fixes the findings.
    *   It asks for the plan-approval gate, stating that phase check-ins are off unless the user asks for them. On approval, it records the gate and moves to `build`.

### CUJ 5: Build a phase, with a council escalation

*   **Given**: The plan is approved. Phase 1 has tasks A and B, whose file sets don't overlap, and task C, which depends on A.
*   **When**: The user says "build it".
*   **Then**:
    *   The skill delegates A and B in parallel with `-Base feature/export`. It reviews each diff, merges the accepted work into `feature/export`, then delegates C.
    *   Suppose C fails review twice. The skill convenes a council on C's problem and records the outcome as a decision.
        *   **The council agrees:** the skill retries C on `code-hard` with the council's advice and keeps going.
        *   **The council disagrees, or C fails after a second council:** it stops and shows the user the positions and its proposed next step.
    *   With phase check-ins off (the default), phase 2 starts as soon as phase 1 is merged and its tests pass. With check-ins on, it reports and waits for "continue".

### CUJ 6: Test and sign off

*   **Given**: All phases of `export` are merged into `feature/export`, and the working tree is clean.
*   **When**: The user says "test and sign off".
*   **Then**:
    *   The skill runs the full test suite on `feature/export`.
    *   It runs the final check of the whole diff against the locked design, and shows the missing, added and changed behaviour.
    *   It asks for the sign-off gate. On explicit approval, it merges `feature/export` into `main`.
    *   It marks the feature `done` once the merge commit exists. It does not push unless the user asks.

### CUJ 7: An unclear reply does not pass a gate

*   **Given**: The skill is waiting at the plan-approval gate.
*   **When**: The user replies "ok, looks fine I guess".
*   **Then**: The skill asks one confirming question ("Approve the plan and start building?"). It records the approval only after a clear yes.

--------------------------------------------------------------------------------

## Technical Plan (Architecture)

### Components

```text
 user (plain language)
        |
        v
+----------------------------------------------+
| skills/feature/SKILL.md          (router)    |
|  plan-mode check -> status -> reconcile      |
|  -> say what happens -> load stage file      |
+----------------------------------------------+
   |                 |                    |
   v                 v                    v
stages/*.md     scripts/feature.ps1   egm/ (vendored EGM workflow
(design,        (all feature state)   and standards, unmodified)
 review, plan,       |
 build, signoff,     |
 status)             |
   |                 |
   v                 v
delegate.ps1 (existing, modified by v1) --> Cursor CLI
   workers: Composer 2.5, Grok 4.7 high
   goldfish and council: Composer 2.5, DeepSeek V4.1 Flash, Grok 4.7 high, GLM 5.2
```

*   **Router (`skills/feature/SKILL.md`).** The only entry point, with one description. On every invocation it runs these steps in order:
    1.  If the session is in Claude Code's plan mode, it says so and allows only read-only actions, such as "where are we?", until the user leaves plan mode.
    2.  Run `feature.ps1 status -Cwd <current folder>`. This picks the active feature (see [Active feature selection](#active-feature-selection)).
    3.  Run `feature.ps1 reconcile` for that feature. On contradictions, show them and stop. If either script call fails, show its error and stop, and never guess the stage.
    4.  State in one line the feature, the stage and the action about to be taken.
    5.  Read the matching stage file and follow it. The entry rows with no stage file of their own are handled by the router itself (see [Rows the router handles](#rows-the-router-handles)).
*   **Stage files (`skills/feature/stages/*.md`).** Instructions for one stage each: `design.md`, `design-review.md`, `plan.md`, `build.md`, `signoff.md`, and `status.md` for "where are we?". The design and review stage files tell the lead to follow the vendored EGM workflow, and list where our flow differs from it (see [EGM integration](#egm-integration)).
*   **State script (`skills/feature/scripts/feature.ps1`).** All reads and writes of feature state go through this script, so the rules can be tested. It prints compact JSON, like `delegate.ps1`. Its subcommands are listed in [item 8](#8-skillsfeaturescriptsfeatureps1-create).
*   **Vendored EGM (`skills/feature/egm/`).** A copy of the EGM skill text and standards our stages use, pinned per [decision 001](../decisions/001-vendor-egm-workflow.md). The goldfish personas live with the other personas in `skills/delegate/personas/`.
*   **`delegate.ps1` (existing, modified by v1).** It runs every worker, goldfish and council run. `feature` adds no new way to launch an agent.

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

*   **Forward moves.** One step at a time. A gate is needed only where the table lists a gate to leave the current stage.
*   **Going back** is allowed. For example, a design flaw found during the build moves the feature to `design-review`.
    *   Moving back to stage S clears S's own exit gate and every gate after it, so the next forward move needs that gate again.
    *   The move is logged as a decision.
*   **Abandoning** is allowed from any stage. The skill switches the checkout back to `main` if the tree is clean, and keeps the branch and records until the user deletes them.

#### Merged work after going back

Merged tasks stay merged and keep their ids. Rework after going back is planned as new tasks with new ids. Removing merged code is itself a task (or a hand edit by the user). Abandoning stays available.

### Routing rules

*   **Invoking the skill.** Claude invokes it when the user asks to design, review, plan, build, continue, test, sign off or abandon a feature, or asks where a feature stands. A sentence that only mentions a feature is not a request.
*   **"Plan it" is not plan mode.** It means this skill's plan stage. Claude must not call `EnterPlanMode` for it. If the user is already in plan mode, the router asks them to leave it (Shift+Tab) before any stage that writes files.
*   **Moving to the next stage.** The skill moves forward only when the user asks for the next stage, or says "continue" while the current stage is finished.
*   **Passing a gate.** A gate is passed only by an explicit approval of that gate. An unclear reply ("ok", "looks fine I guess") gets one confirming question that names the gate.
*   **First action on every invocation.** The skill states in one line which feature, stage and action it is about to take, so a misfire is visible before anything changes.

#### Entry-point table

The phrases are examples. The router also accepts close paraphrases.

| The user says (examples) | Action | Gate |
|---|---|---|
| "design a feature for X", "let's design X" | `new`, then the `design` stage | — |
| "review the design" | `design-review` | asks for **design-locked** |
| "lock the design" | records **design-locked** | — |
| "plan it", "plan the feature" | `plan` | asks for **plan-approved** |
| "approve the plan", "approve the plan and check in every phase" | records **plan-approved** and the check-in mode | — |
| "build it", "continue" | `build`, or resumes the current stage | — |
| "check in every phase" / "stop checking in" | changes the check-in mode | — |
| "test and sign off" | `signoff` | asks for **signed-off** |
| "sign off" | records **signed-off**, then merges into `main` | — |
| "where are we?", "status" | `status` (read-only) | — |
| "get a second opinion on …", "convene a council" | council | — |
| "go back to the design / plan" | moves back a stage | — |
| "abandon this feature" | `abandoned`, switch back to `main` if clean | — |
| **Must not fire:** "this feature is slow", "what features does X have?", "add a feature flag" | nothing | — |

#### Rows the router handles

These rows have no stage file. The router handles them after its steps 1–4:

*   **"lock the design".** Only in `design-review` once the review is resolved, using the lock steps in `design-review.md`. In any other stage, the router says what stage the feature is in and what is needed first.
*   **"approve the plan".** Only in `plan` with a plan imported, using the approve steps in `plan.md`.
*   **"sign off".** Only in `signoff` after the final check was shown, using the sign-off step in `signoff.md`.
*   **Check-in mode.** `feature.ps1 checkin`, in any stage, confirmed in one line.
*   **"go back to the design / plan".** `feature.ps1 stage -To design-review` or `-To plan` with the user's words as the reason, then that stage's file.
*   **"abandon this feature".** One plain confirmation (the branch and records are kept), then `feature.ps1 stage -To abandoned`, and a report of whether the checkout switched to `main`.
*   **Council.** In `build`, about a task: the build council in `build.md`. Otherwise an [on-request council](#council-g7).

### Active feature selection

The skill checks these in order:
1.  The feature named in the request.
2.  The feature whose branch is checked out in the session's current folder, unless that feature is `done` or `abandoned`.
3.  The only feature in progress, if there is exactly one.
4.  Otherwise, it asks the user.

### Where the feature runs

*   **One active feature, in the user's checkout.** `feature.ps1 new` refuses if the working tree has uncommitted changes (the user commits or stashes first) or another feature is active. Otherwise it runs `git switch -c feature/<name> main` in the user's repo folder.
*   **Local state** lives in `<repo>/.xagent/features/<name>/`.
*   **Workers** are launched with `-Repo <repo> -Base feature/<name>`. The lead merges worker branches in `<repo>`, which has `feature/<name>` checked out.
*   **Side work.** While a feature is active, side work happens outside the skill, for example by hand on another branch after committing or stashing. The checkout must be back on `feature/<name>` before the skill continues. Reconcile checks this, and asks the user to switch back if it isn't.
*   **Keeping current with `main`.** `main` can move during a long feature. When the user asks, the lead merges `main` into `feature/<name>` at a phase boundary (`git merge --no-ff main`, never a rebase, so the task trailers stay in history). It logs the merge as a `[decision]` and runs the current phase's test again. A conflict stops for the user. Otherwise the branch diverges until sign-off, where a conflict aborts the merge (see [Sign-off](#sign-off-and-final-check-g6)).

### State model

The feature's lasting records are committed on `feature/<name>`, in `docs/features/<name>/`:

*   **`feature.json`.** The script is its only writer. It holds:
    *   the name, the stage, the check-in mode and the path to the design doc;
    *   the gates, each with a timestamp, the user's quote, and the commit it approved (the `feature/<name>` SHA; for **design-locked**, also the design file's blob id);
    *   the plan: a summary, then phases (each with its number, rationale and test command), then tasks (id, title, depends-on, declared files, test command, profile and brief).
*   **`plan.md`.** Generated entirely from `feature.json` for the user to read, and never edited by hand.
*   **`decisions.md`.** An append-only log. Each line is `- <ISO time> [<kind>] <text>`. Kinds:
    *   `decision`, `gate` and `stage`;
    *   `council`, with the task id and its outcome, and `round`, one per failed review round;
    *   `fix-up` (with the files and lines changed) and `dismiss`;
    *   `stop` and `resume`.
*   **`reviews/raw/<lens id>.md`.** Each goldfish's raw report, committed unchanged before the synthesis is written.
*   **`reviews/<stage>-<n>.md`.** The synthesized review reports.

The design doc itself is `docs/designs/<name>.md` on the branch. It is drafted in place with `Status: Draft` and committed after each approved section.

Fast-changing runtime state is local, in `<repo>/.xagent/features/<name>/state.json` (git-excluded):
*   for each task: status (`pending`, `preflight`, `running`, `in-review`, `merged` or `failed`), `delegate` task id, session id, result file and the last `verify` output;
*   the time of the last reconcile.

A task under council stays `in-review`. A stop that follows is the committed `[stop]` decision.

**Session lock.** Every `feature.ps1` command that writes takes an advisory lock, `.xagent/features/<name>/.lock`, which holds a process id and that process's start time. If a running process matches both, the command fails with "another session is working on this feature". Otherwise the lock is stale and is taken over. Matching the start time guards against Windows reusing process ids.

Derived, not stored:
*   **What the flow is waiting for.** A gate the stage needs, an open `[stop]`, or a running worker.
*   **Review rounds and council counts.** Counted from the committed lines, so the council trigger and cap survive a lost local file. A task's round count is its `[round]` lines since its latest `[council]` line. Its council count is all of its `[council]` lines.
*   **Review progress.** A lens is done when its raw report is committed under `reviews/raw/`.
*   **Token use.** The sum of the `runs.jsonl` lines whose `feature` field equals `<name>`, including cache reads, so it matches Cursor's usage page.

### Reconcile rules

`feature.ps1 reconcile` runs at the start of every invocation. Git and the files on disk win for the facts they can prove. Local-only fields are kept. The script stops and asks only on a real contradiction.

| Fact | Source | Rule |
|---|---|---|
| Feature branch exists | git | Missing while the local `state.json` exists → **contradiction `branch-missing`, ask**, whatever the stage (it can't be read once the branch is gone). Nothing else is checked. With no local file either, `no feature <name>` |
| Feature branch checked out | `git branch --show-current` | Another branch checked out while the feature is active → **ask the user to switch back** (nothing changes) |
| Merge in progress on `main` | git (`MERGE_HEAD` while on `main`) | **Ask** the user to finish or abort the merge |
| Task merged | a merge commit on `feature/<name>` with the trailer `Xagent-Task: <id>` | Counts as `merged`. This absorbs manual merges that carry the trailer. |
| Task merged per local state, no trailer commit | — | **contradiction, ask** |
| Task in `preflight` or `running` | every pid file and the newest run under `.xagent/runs/` for the task's own ids (`<delegate task id>`, `-pc`, `-pr`, `-c<k>`), and the process list | A live `delegate.ps1` (pid and start time match) → left alone, never launched twice. A live worker whose parent is gone → killed and marked `failed`. Otherwise, if the newest run has a non-empty `stdout.json` → `in-review`. Else → `failed`, and the slot is freed. A `failed` task is not scheduled again until the user resumes it ("continue" asks first). A second failure of the same task is a problem stop: a `[stop]` line is committed if `feature/<name>` is checked out; otherwise nothing is committed and the contradiction `stop-not-recorded` asks the user to check it out (a later reconcile won't retry, so the lead records that stop with `decision -Kind stop`). |
| Task in `in-review` | — | Unchanged. The lead sets `running` before starting a round, so the round is checked then. |
| `signed-off` recorded, feature not yet in `main` | git | `finish` is pending |
| Feature merged into `main` | `feature/<name>` is an ancestor of `main` | Counts as `done` if `signed-off` is recorded (derived, not stored). Without that gate → **contradiction, ask** |
| Gates, stage, plan, stops, rounds, councils | committed `feature.json` and `decisions.md` | Always taken from the committed copy |
| Session ids | local only | Kept. If the local file is missing, the losses are reported and the affected tasks resume from their last committed state |

All worker merges into the feature branch use `git merge --no-ff` with the trailers, so a task's completion can be proven from history after `delegate -Cleanup` deletes the task branch.

**Finished run.** A run is finished when its `stdout.json` is non-empty. `delegate.ps1` creates that file at launch and fills it when the run ends, for every kind of run; a run killed from outside leaves it empty. `result.json` can't be the test (it lives in the worker's worktree, which cleanup removes), and neither can `.review.md` (only read-only runs write it).

### Build scheduling

#### Ready tasks and overlap

*   **Task ids** are `<feature>-<task>`, built to fit `delegate`'s 49-character limit by the id budget in [item 8](#8-skillsfeaturescriptsfeatureps1-create) (the feature part cut to 12 characters, task ids of at most 20).
*   **Ready.** A task is ready when all of its `depends-on` tasks are merged. `feature.ps1 schedule` returns the ready tasks of the current phase that can start now.
*   **Overlap.** A task can start only if its declared files overlap no running task's declared files.
    *   Two paths overlap when they are equal or one is a parent folder of the other. Paths are compared with a trailing `/`, so a folder never matches a name prefix.
    *   An entry in `files` can be a glob (`*`, `**`). For the overlap check, a glob's key is its folder part, up to the last `/` before the first wildcard (`src/test*.ts` → `src/`). An empty key (`**`, `*.md`) means the whole repo.
    *   For the scope check, a glob matches files the normal way. So two tasks that add files to the same folder run in parallel only if each lists its exact file names. A task with a glob entry blocks every other task whose files sit under that glob's folder, even if the other task lists exact files.
*   **At most 2 agents at a time, in every stage.** The cap counts every `delegate` run of the feature: preflights, workers, review lenses and council members. So a three-lens review phase runs two lenses, then the third. This keeps load on the Cursor subscription bounded.

#### Models and usage pools

*   **Models.** Everything runs through the Cursor CLI. There is one worker model per profile, so no routing between vendors is needed.
    *   `code` tasks: Composer 2.5.
    *   `code-hard` tasks: Grok 4.7 high.
*   **Usage pools (confirmed 2026-11-10 on Cursor's Spending page, legacy Pro plan).** There are two monthly pools, shown as a percentage used, both resetting each billing month.
    *   **Cursor Models** (Grok, Composer). Usage beyond its limit spills into the Other Models pool, then into on-demand spend.
    *   **Other Models** (GLM, DeepSeek). Usage beyond its limit goes to on-demand spend, which is disabled on this account.
*   **Usage limits.** A run that reports a usage limit is a problem stop. The user resumes when the allowance is back. Every other failure follows the normal failed-run path, where a task's second failure is a problem stop. No Cursor usage-limit error has been seen yet, so v1 has no matcher for one. It is added once a real error is seen. v1 has no automatic retry timer, no model fallback and no dollar estimate.
*   **Profile.** Each task starts on the profile the plan gives it.

#### Task preflight

This applies to the build's task preflights only. The design and plan reviews follow [Goldfish review routing](#goldfish-review-routing).
*   **Comprehension** runs on the worker's model: Composer 2.5 for `code`, Grok 4.7 high for `code-hard`. If the worker would misread the task, this reviewer should too.
*   **Implementation readiness** runs on DeepSeek V4.1 Flash, a different model family.

#### Verify, review and merge

*   **`feature.ps1 verify`.** After each worker run, one script call:
    1.  lists the worker's changed and untracked files;
    2.  matches them against the task's `files`;
    3.  runs the task's test command in the worker's worktree;
    4.  records the result.

    A change outside `files` is a problem stop. The script does not revert it automatically, because silently undoing a worker's change could hide a real problem. Task test commands must be non-interactive.
*   **Reading the diff.** The lead reads each changed file's diff separately (`git -C <worktree> diff <base>...HEAD -- <file>`). The lead's traffic passes through the Headroom proxy, which can compress large outputs. If an output carries a compression marker, that file's review is not done: expand it with `headroom_retrieve` or read smaller ranges. Expanding a compressed diff hasn't been tested yet (T6 in `docs/test-plan.md`), so reading smaller ranges is the fallback.
*   **Merging.** Each task is reviewed and merged per `delegate`'s loop, with the differences in the [build stage file](#5-skillsfeaturestagesbuildmd-create).
    *   `merge` refuses unless the tree is clean and `HEAD` is `feature/<name>`.
    *   A phase ends when all its tasks are merged and the phase test command passes on `feature/<name>`.
*   **Fix-ups (judgement, not a limit).**
    *   **The choice.** During review, the lead either fixes an issue itself or sends it back as a review round.
    *   **How it decides.** It weighs the token and time cost of each path.
    *   **Guideline, not a cap.** "About 3 files and 30 lines" helps it gauge its own effort.
    *   **Afterwards.** Every fix-up is logged as `[fix-up]` with the number of files and lines it changed, so a large one is visible at sign-off, and `verify` runs again.

#### Problem stops and check-ins

*   **Problem stops.** In the default mode, the build runs through phases without stopping, except for:
    *   a council that disagrees, or a failure after a task's second council;
    *   a test failure on `feature/<name>` that a fix-up cannot solve;
    *   a change outside the declared files;
    *   a needed change to the plan or the design;
    *   a usage limit;
    *   a task that fails a second time (see Reconcile rules).
*   **Committed stops.** A stop is logged as `[stop]` and clearing it as `[resume]`, so it survives the loss of the local state file.
*   **Phase check-ins.** With phase check-ins turned on, the build also stops after each phase. Only the user turns them on, at plan approval or during the build, and the skill never does it by itself.

### Council (G7)

*   **Design and plan.** When the lead faces a choice that is hard to reverse or contested, it offers a council, and runs one only if the user agrees.
*   **Build.** A `code` task that fails review twice, or a `code-hard` task that fails review once, triggers a council automatically.
    *   **The round limit.** This is the one place it is set for feature tasks, and it replaces `delegate`'s "about 3 rounds" for them.
    *   **Procedure and record.** The council uses `delegate`'s council procedure, with seats Grok 4.7 high and GLM 5.2. Its outcome is logged as `[council]`.
    *   **Consensus.** The lead retries the task on `code-hard` with the council's guidance as a delta brief, without stopping. The round count starts again from 0, because only rounds after the latest council count. The council count never resets.
    *   **Disagreement.** The seats disagree on the fix, and the lead cannot settle it from verified facts. That's a problem stop, with `delegate`'s escalation brief.
    *   **Cap.** A task gets at most 2 councils. If the retry after the second council fails review, that's a problem stop.
*   **On request.** At any stage, the user can ask for a council.
*   **Ids for design, plan and on-request councils.** These use the same procedure and seats. The run id is `<name12>-dc<k>` in `design` and `design-review`, and `<name12>-pc<k>` otherwise. `<name12>` is the name cut to 12 characters, without a trailing `-`. `<k>` is 1 plus the number of `[council]` lines starting `design:` (or `plan:`). The question file is `.xagent/features/<name>/council-<run id>.md`. The outcome is logged as `[council] design: …` or `plan: …`.

### Goldfish review routing

All goldfish run on non-Claude models through the Cursor CLI, so the reviewer is always a different model family from the author (the Claude lead).

**`GoldfishContext`.** This is the reading list in a review task file: the repository files a reviewer reads to understand the existing system, besides the target. It is plain text, not a schema field. For a design review it holds the files the design links to inside the repo, plus any the lead names. Reviewers can't open URLs, so web pages are saved as files first. Example:

```text
GoldfishContext (read-only):
- skills/delegate/SKILL.md
- skills/delegate/scripts/delegate.ps1
- docs/decisions/001-vendor-egm-workflow.md
```

#### Models per lens

This applies to the design review, the plan review and the sign-off check.

| Lens | Model | Why |
|---|---|---|
| comprehension | Composer 2.5 | The same model as the workers who will read the tasks. |
| implementation_readiness | DeepSeek V4.1 Flash | A cheap reader from a different model family. |
| zoom_out, design_critic, inventive_catalyst, codebase_details, structural, style, drift_report | Grok 4.7 medium or GLM 5.2, fixed per lens run in the next table | These lenses need judgement about architecture and hidden complexity. Two model families give two independent views. Grok medium matched Grok high on time and quality in the stage 8 trial. |

#### Lens runs per review

| Review | EGM review phase | Lenses | Models |
|---|---|---|---|
| design review | 5. Initial zoom out | zoom_out, inventive_catalyst | Grok, GLM |
| | 6. Comprehension | comprehension | Composer 2.5 |
| | 7. Critic | design_critic, structural, style | GLM, Grok, GLM |
| | 8. Intermediate zoom out | zoom_out | Grok |
| | 9. Implementation readiness | implementation_readiness, codebase_details, style | DeepSeek, Grok, GLM |
| plan review | — | comprehension, implementation_readiness | Composer 2.5, DeepSeek |
| sign-off | — | drift_report | Grok or GLM |

A design review is about 10 lens runs. The plan review has no judgement lens, because the locked design already settles the architecture. It checks only that workers will read the tasks the same way and can build them without guessing. Each re-audit after "update the doc first" reruns that phase's lenses once.

*   **Lens ids.** Each lens run has a fixed `delegate` task id, built by `feature.ps1`: the shortened feature name, the review and its number, a two-letter lens code and the EGM phase (for example `export-d1-zo-p5` and `export-d1-zo-p8` for the two zoom-out runs). A lens used in two phases gets two ids.
    *   The review number is 1 for the first design review, 2 after going back to `design-review`, and so on.
    *   A re-audit within one review adds `-r<k>`.
    *   `feature.ps1 status` lists the current review's runs and which are done. Every id fits `delegate`'s 49-character limit (see [item 8](#8-skillsfeaturescriptsfeatureps1-create)).
*   **Failed reviewers.** A lens run that ends without a report is retried once. If it fails again, it is rerun on the other judgement model (Grok ↔ GLM) and logged. If that fails too, the lens is recorded as **not run** in the report, never as "no findings". A lens that was not run blocks the next gate until it is rerun or the user waives it, which is logged as `[dismiss] <run id>: not run — <reason>`.
*   **Diff reviews.** The lead reads every diff itself. When a goldfish also reviews a risky diff (optional, as in `delegate`), the model is GLM 5.2, a different family from the writer.
*   **Report format and synthesis.**
    *   Reviewers return Markdown with Blocker, Major and Nit findings.
    *   Each raw report is committed under `reviews/raw/` before the lead writes the synthesis.
    *   The lead does the synthesis EGM's synthesizer would do: it deduplicates and ranks findings into `reviews/<stage>-<n>.md`, which lists the raw files it was built from.
    *   **Nothing dropped silently.** Every finding either appears in the synthesis or is logged as `[dismiss] <lens>: <finding> — <reason>`.

### Changes to `delegate` in v1

These are changes to the existing skill. Until they are built, `delegate.ps1` behaves as it does today.

*   **Target passed by file.**
    *   The review or council target is written to `.xagent/target-<stamp>.md` in the read-only worktree, and the prompt names that path. It is never embedded in the command line.
    *   `-TargetFile <path>[,<path>]` copies files that aren't in the commit, such as the sign-off diff, into the worktree's `.xagent/` the same way.
    *   Every Cursor review during this design's own review read its target this way.
*   **Rule files removed in read-only runs.**
    *   **Removal.** Before launch, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursor/`, `.cursorrules` and `.agents/` are deleted from the throwaway worktree, so the reviewer does not load project instructions.
    *   **Restoring.** They are restored in a `finally` block before the read-only check. `-Cleanup` also restores them, so an aborted run cannot block cleanup.
    *   **Exception.** The caller passes `-KeepRuleFiles` when rule files are part of the review target. For sign-off, `feature.ps1` reports whether the final diff touches a rule file.
*   **Standards lookup.** The standard appended to a persona comes from `-Standard <file>` when the caller passes it (the stage files do, because the right standard depends on what is reviewed). Otherwise it is that persona's default in `personas/standards.json`. Nothing is hard-coded.
*   **Model seats.** `models.json` names the models for each seat: worker, `code-hard`, comprehension, readiness, judgement and council.
*   **`-Feature <name>`.** The full feature name is written as a `feature` field on each `runs.jsonl` line, so token totals don't depend on shortened task ids.
*   **`-Seat <label>`.** It names a run's worktree and logs (`<id>-grok`, `<id>-glm`), so two council members on the Cursor CLI don't collide on `<id>-cursor`.
*   **agy disabled.** `-Agent agy` fails with the T0 reason unless `models.json` sets `agy.enabled: true`. That is kept for a possible API-key setup later.
*   **Worker environment cleaned.** Known secret variables are removed from a worker's environment before launch (see [Risks & Mitigations](#risks--mitigations)).
*   **Pid file per run.** Each run writes `<logBase>.pid` with the process ids and start times of `delegate.ps1` and of the CLI process it launched, plus the `-Feature` name, so reconcile can tell live runs from dead or orphaned ones, and `schedule` can count the feature's live runs.
*   **Logs moved.** `runs.jsonl` is written to `%LOCALAPPDATA%\xagent\`, outside every repo, so usage data from private projects can never be committed to this repo.

### EGM integration

*   **Vendored copy.** The design and design-review stage files tell the lead to read and follow the vendored EGM `egm-draft`, `egm-review`, `egm-review-loop` and `egm-resolve` text in `skills/feature/egm/`. They list where our flow differs:
    *   where EGM spawns a Claude reviewer agent, run `delegate.ps1` with the model from [Goldfish review routing](#goldfish-review-routing);
    *   where EGM writes `design_draft.md`, write to `docs/designs/<name>.md`;
    *   EGM's question gates map to our recorded gates.
*   **Unmodified text.** The vendored text stays unmodified. All differences live in our stage files, per [decision 001](../decisions/001-vendor-egm-workflow.md). The one adapted file is the drift-report persona ([item 13](#13-skillsdelegatepersonas-modify)).
*   **Sync.**
    *   v1 copies the files once and records commit `b7d9e27` in `THIRD_PARTY_NOTICES.md`.
    *   The lead checks upstream monthly with `git ls-remote https://github.com/google/elephant-goldfish-model HEAD` against the pinned commit, as an item in `docs/HANDOFF.md`.
    *   The sync script from decision 001 is written when the first upstream change arrives.

### Sign-off and final check (G6)

1.  Refuse unless the tree is clean and `HEAD` is `feature/<name>`. Run the repo's full test command.
2.  Run the final check: one judgement-tier goldfish with the `drift_report` persona, on a worktree detached at `feature/<name>`. It is given the locked design and a file holding `git diff main...feature/<name>`, both by path. It returns three lists: behaviour missing from the code, added beyond the design, and changed from it.
3.  Show the results and ask for the **signed-off** gate.
4.  On approval, record `signed-off` with the `feature/<name>` SHA that was checked. `finish` refuses if anything outside `docs/features/<name>/` has changed since then (the gate's own commit changes only that folder), or if the design file's blob differs from the one recorded at **design-locked**. Then it runs `git switch main` and `git merge --no-ff feature/<name>`.
    *   **On conflict:** run `git merge --abort` and `git switch feature/<name>`, clear `signed-off`, and report the conflicting files. A new final check is needed.
    *   **On success:** the feature counts as `done` once the merge commit exists (derived, not stored).

    Pushing happens only if the user asks.

### Installation

*   **No absolute paths in skill files.** When Claude Code loads a skill, it gives the skill's base directory. `SKILL.md` and the stage files call `pwsh -NoProfile -File <skill base dir>/scripts/feature.ps1`, and `delegate`'s SKILL.md does the same for `delegate.ps1`. The scripts find their own files through `$PSScriptRoot`.
*   **Logs** live in `%LOCALAPPDATA%\xagent\`, wherever the skills are installed.
*   **Install for v1.**
    1.  Copy or clone the repo anywhere.
    2.  Link or copy `skills/delegate` and `skills/feature` into `~\.claude\skills\`. The author's machine uses junctions to the repo. With junctions, the skill that runs is whatever is checked out, so a feature of this repo that edits `skills/` changes the running skill mid-build. Use a copy for such features.
    3.  Add the permission rule that `doctor` prints.
*   **`feature.ps1 doctor`** checks the prerequisites and prints what is missing:
    *   PowerShell 7.4 or later (for `Test-Json` with draft 2020-12 schemas) and git;
    *   `delegate`'s files beside `feature` (`../delegate/models.json`);
    *   Python, reported as optional (only the manual sandbox uses it);
    *   the Cursor CLI, installed and logged in, at the path `delegate.ps1` launches (`%LOCALAPPDATA%\cursor-agent\cursor-agent.ps1`);
    *   the models in `models.json`, available to this account (from `--list-models`);
    *   Pester 5.5 or later (for the tests only);
    *   `%LOCALAPPDATA%\xagent\` writable;
    *   the exact `Bash(pwsh -NoProfile -File <path>/feature.ps1 *)` and `delegate.ps1` permission rules to add.

--------------------------------------------------------------------------------

## Alternatives Considered

### Alternative A: Adopt an existing tool instead of building `feature`

The candidates, from [research §7](../research.md#7-landscape-survey-similar-projects-2026-11-09): kodo, Spec Kit, Superpowers, BMAD and amElnagdy/delegate-skills.

*   **Pros**: These tools exist now, and some are mature, with more users and testing than ours will have.
*   **Cons**:
    *   The spec frameworks run only on Claude subagents, which spends the Claude quota on every stage.
    *   kodo has no user-locked design and, by its own account, no independent verification gate, and it runs its agents with permission checks bypassed.
    *   delegate-skills has no feature-level flow.
    *   None targets native Windows PowerShell with a policy of keeping coding work off the Claude quota.
*   **Reason for Rejection**: Rejected by author: the project also exists to learn how to build multi-agent workflows across ecosystems, and to fit a personal workflow and budget. Ideas are borrowed instead: scope checks against touched files, outcome logging, the `tasks.md` shape, file claims, and anonymized peer review.

### Alternative B: Call the installed EGM plugin instead of vendoring it

*   **Pros**: No copy to keep in sync, and upstream fixes arrive automatically.
*   **Cons**: All seven EGM skills set `disable-model-invocation: true`. Claude cannot start them, so each design stage would need a typed `/egm-*` command, which breaks G1. Flipping the flag in the installed plugin is undone silently by every plugin update.
*   **Reason for Rejection**: Rejected by author: it conflicts with plain-language entry. See [decision 001](../decisions/001-vendor-egm-workflow.md).

### Alternative C: One skill per stage

*   **Pros**: Each skill gets a precise description, and only one stage's text is loaded per invocation.
*   **Cons**: Five skill descriptions compete for phrases like "continue" and "where are we?". The active-feature, reconcile and gate rules would be repeated in each skill.
*   **Reason for Rejection**: Rejected by author: one router skill keeps the routing, reconcile and gate rules in one place, and loads stage files on demand.

### Alternative D: Where feature state lives

#### D1. Local only, in `.xagent/features/`
*   **Pros**: No commits for state.
*   **Cons**: `git clean -fdx`, a reclone or a second machine loses the gate approvals, the decision log and the review reports.
*   **Reason for Rejection**: Rejected by author: the records that matter must survive.

#### D2. Everything committed on the branch
*   **Pros**: One source of truth that survives a reclone, a second machine or `git clean -fdx`.
*   **Cons**: Task status and session ids change constantly, which means many noise commits.
*   **Reason for Rejection**: Rejected by author. Chosen instead: lasting records are committed and runtime state stays local ([State model](#state-model)).

### Alternative E: Create the feature branch at plan approval

*   **Pros**: The design and plan are visible on `main` early, and there is no branch to manage during design.
*   **Cons**: An abandoned design leaves commits on `main`. One feature's records split across `main` and its branch, and a design changed during the build diverges from the copy on `main`.
*   **Reason for Rejection**: Rejected by author: everything for a feature lives on its branch, and `main` changes only at sign-off.

### Alternative F: Side mode in v1

Side mode means a second active feature in its own lead worktree (`<repo>.xagent/_feature-<name>`), with a `promote` command to move it into the main checkout later.

#### F1. Side mode with `promote`
*   **Pros**: Side work and experiments while a major feature is in progress.
*   **Cons**: A worktree, a name prefix, `promote`, two dirty-tree checks, overlap warnings between features, and logic for two folders in every subcommand.
*   **Reason for Rejection**: Deferred by author after the [zoom-out review](reviews/feature-skill/zoom_out_report.md) (M6). It's in Future Improvements.

#### F2. Side mode without `promote`
*   **Pros**: Most of the benefit, without the trickiest step.
*   **Cons**: Leaves no way to move a side feature into the main checkout.
*   **Reason for Rejection**: Rejected by author: a side mode without `promote` is incomplete.

#### F3. Always a worktree per feature
*   **Pros**: The user's checkout is never touched.
*   **Cons**: To try a major feature, the user would have to open a different folder, and the checked-out branch could no longer pick the active feature.
*   **Reason for Rejection**: Rejected by author.

### Alternative G: Other ways to handle state that disagrees with git

#### G1. Git always wins
*   **Pros**: Simple, and the local file never goes stale.
*   **Cons**: Session ids exist only locally, and would be lost or guessed.
*   **Reason for Rejection**: Rejected by author.

#### G2. The state file wins, and every mismatch stops
*   **Pros**: The skill never guesses.
*   **Cons**: A harmless manual merge would interrupt the flow with a question.
*   **Reason for Rejection**: Rejected by author. Chosen instead: [Reconcile rules](#reconcile-rules).

### Alternative H: Claude subagents, or cheap models only, as goldfish

#### H1. Claude subagents (EGM's default)
*   **Pros**: Frontier-model judgement, and isolation built into EGM's Claude adapters.
*   **Cons**: Every review spends Claude Pro quota, and the reviewer shares a model family, and so possibly blind spots, with the Claude author.
*   **Reason for Rejection**: Rejected by author: a reviewer from another model family avoids the same biases.

#### H2. Cheap worker-tier models for every lens
*   **Pros**: The lowest cost.
*   **Cons**: Untested on the judgement lenses (architecture, hidden complexity, alternatives). The `delegate` preflight trials tested only comprehension and readiness on one small task file.
*   **Reason for Rejection**: Rejected by author: the judgement lenses go to frontier models (Grok 4.7 high and GLM 5.2). Revisit with benchmark data.

### Alternative I: A fixed check-in policy

#### I1. Always check in after every phase
*   **Pros**: The user sees every phase.
*   **Cons**: Too many interruptions for routine features, and the build can't run while the user is away.
*   **Reason for Rejection**: Rejected by author.

#### I2. Only stop on problems, with no option to check in
*   **Pros**: One setting fewer.
*   **Cons**: Some complex features need a check after every phase. A pause request made once would not be remembered across phases or compaction.
*   **Reason for Rejection**: Rejected by author, and reconfirmed after the [zoom-out review](reviews/feature-skill/zoom_out_report.md) (M4). Chosen instead: stop on problems by default, with check-ins after every phase as an explicit option per feature.

### Alternative J: Antigravity as the second worker and reviewer provider

*   **Pros**: A second subscription (Google AI Pro), so the load is split and a quota limit on one provider can fail over to the other. Gemini 4 Argon is a strong reviewer.
*   **Cons**: Google's FAQ says wrapping `agy -p` inside third-party coding agents is unsupported on consumer plans. It names Claude Code as third-party software whose use with an Antigravity login breaks the Terms, with suspension as a possible outcome (`docs/test-plan.md` T0). The supported route, an AI Studio API key, bills per token.
*   **Reason for Rejection**: Rejected by author: the subscription route breaks Google's terms, and paying per token was not wanted. Gemini models are still available through the Cursor CLI if a review ever needs them.

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Quota.** Claude runs only the lead. Workers, goldfish and councils run on the Cursor subscription.
    *   **Per feature.** One design review (about 10 lens runs), one plan review (2), one final check (1), the task preflights, the workers, and any councils.
    *   **Measured during this design's own review.** A judgement-lens run on GLM 5.2 took 1–2 minutes and 32k–89k tokens. On Grok 4.7 it took 6–11 minutes and 86k–176k tokens. Both ranges exclude cache reads, which Cursor's usage page includes.
    *   **Usage.** All seats show as "Included" on Cursor's usage page. `status` shows the feature's token use, including cache reads. There is no budget stop and no dollar estimate.
    *   **Lead bookkeeping.** Mechanical steps (scope check, tests, state updates) are one `feature.ps1` call each, so the lead's context and Claude quota go to review and judgement.
*   **Safety.**
    *   The skill never merges to `main` or pushes without the **signed-off** gate.
    *   `feature.ps1` refuses to start a feature on a dirty working tree. `merge` and `finish` refuse unless the tree is clean and on `feature/<name>`. It never runs `git reset --hard`, `git clean`, or a force push.
    *   Worker permissions and their risks are covered in [Risks & Mitigations](#risks--mitigations).
*   **Rollback.**
    *   Abandoning a feature leaves `main` untouched. The branch and records stay until the user deletes them.
    *   Removing the skill means deleting `~\.claude\skills\feature`. `delegate` keeps working on its own.

--------------------------------------------------------------------------------

## Risks & Mitigations

| Risk | Mitigation | What remains |
|---|---|---|
| **Workers change files** with permission checks bypassed (`--force`) | `verify` checks the changed files against the declared scope. The lead reviews every diff, file by file. Merges go only into `feature/<name>`. | — |
| **Workers can read any file and reach the network**, which diff review cannot see | `delegate.ps1` launches workers with known secret variables removed from the environment (`*_API_KEY`, `*_TOKEN`, `*_SECRET`, `AWS_*`, `AZURE_*`, `GH_TOKEN`, `GITHUB_TOKEN`, `ANTHROPIC_*`, `OPENAI_*`, `SSH_AUTH_SOCK`, `GOOGLE_APPLICATION_CREDENTIALS`, `DATABASE_URL`). No secrets, credentials or deploys go to workers. | **Mitigated by `worker-sandbox`:** runs are confined to their worktree in an AppContainer; network stays on, and the Cursor token in the run home is an accepted risk (see `docs/designs/worker-sandbox.md`, Risks & Mitigations). |
| **Reviewers load project instructions** from CLI rule files | Rule files are removed from read-only worktrees | — |
| **The diff review is compressed by the Headroom proxy** | Per-file diffs, and a compression marker means "not reviewed" | — |
| **The Cursor allowance runs out** | Any usage limit is a problem stop. The user resumes when the allowance is back. | The build waits. |
| **Antigravity terms** | No `agy` automation (T0) | — |
| **Local state is lost or contradicts git** | Reconcile rules, plus committed stops, rounds, councils and raw reports | Session ids are lost and reported |
| **A council agrees on a wrong fix, retried unattended** | At most 2 councils per task, the next review round, and the drift report at sign-off | Wasted runs before a stop |
| **Damage to the user's only checkout** | Clean-tree and branch checks, and merge abort on conflict | — |
| **Usage data from private repos ends up in this public repo** | Logs live in `%LOCALAPPDATA%\xagent\`, outside every repo | — |
| **Capacity** | Limits: one active feature and 2 agents at a time. A first rough rate: about 0.75% of the Other Models pool per GLM lens run (about 130 a month), and about 0.5% of the Cursor Models pool per Grok lens run. Token use per feature is shown in `status`. | The rates are rough (from one day's usage), and are refined on the first real feature. |
| **The final check misses drift** (one lens at sign-off) | The full test suite, and the drift report's three lists shown before sign-off | Drift the `drift_report` lens misses is caught only if the user reads the diff. A very large diff may not fit one reviewer's context. A second lens, or a per-phase check, is in Future Improvements. |
| **Two sessions on one machine** | The advisory session lock | — |

--------------------------------------------------------------------------------

## Future Improvements

*   **Worker sandboxing:** done in `worker-sandbox`.
*   **Plugin packaging:** a `.claude-plugin/plugin.json` and a marketplace entry, so others install with `claude plugin install`, and `${CLAUDE_PLUGIN_ROOT}` replaces the base-directory paths.
*   **Side mode:** a second active feature in its own lead worktree, with `promote` and overlap warnings between features ([Alternative F](#alternative-f-side-mode-in-v1)).
*   **Deploy stage:** an optional stage after sign-off, run by the lead with its own approval gate, using secret references only.
*   **Brainstorm stage:** put the vendored `egm-brainstorm` in front of `design`, with an optional council.
*   **Benchmark mode:** bring back `delegate`'s head-to-head benchmark, for example two Cursor models on separate `-Seat`s, and run it on a feature's tasks.
*   **Data-driven model choice:** log task outcomes (rounds, first-try `verify`, councils) and decide which tasks should start on `code-hard`.
*   **A second subscription for overflow:** for example Antigravity with an API key, or another provider, if the Cursor pools turn out too small.
*   **Anonymized peer review in the council** (the epicsagas idea).
*   **EGM sync script** (`scripts/egm-sync.ps1`, per decision 001): written when the first upstream change arrives.
*   **Whole-diff `design_critic` at sign-off:** add it if real features show the drift report is too weak on its own.
*   **Claude Code advisor tool** (experimental): compatible as an optional lead-session setting (`/advisor opus`) for the lead's own judgement calls, such as triage and its council position. It is not used for reviews: it is the same model family and sees the full context, while the goldfish lenses must be fresh and from other vendors. `feature` doesn't depend on it, and each call re-reads the whole transcript against the Claude plan's limits.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Names used below: `<repo>` is the user's checkout of the target repo, where `feature/<name>` is checked out while the feature is active, and `<name>` is the feature name. Paths like `D:\cross-agent-loop` are on the author's machine. Use your own install location.

### Target Files to Create/Modify

#### 1. `skills/feature/SKILL.md` (Create)

*   **Type / Scope**: Claude Code skill, the router. It is model-invocable, so it must not set `disable-model-invocation`.
*   **Proposed Changes**:
    *   **Frontmatter `description`.** It names the trigger: a request to design, review, plan, build, continue, test, sign off, abandon or check the status of a feature in this repo. It lists example phrases from the entry-point table, and says that a sentence only mentioning a feature is not a request, and that "plan it" for a feature never means Claude Code's plan mode.
    *   **Body.**
        *   The router steps, the routing rules and the entry-point table from the Technical Plan, in full.
        *   Rules that apply in every stage:
            *   never merge to `main` without signed-off;
            *   call scripts by the skill's base directory;
            *   never use Claude models for workers or goldfish;
            *   never run `delegate.ps1 -Agent agy`;
            *   **the cap rule:** before any `delegate.ps1` run that doesn't come from `schedule` (preflights, lenses, council seats), run `feature.ps1 schedule` and start at most `cap − liveRuns` runs. If none can start, wait for a running call to finish, then check again;
            *   every `delegate.ps1 -Cleanup` call passes `-Repo <repo>`.

#### 2. `skills/feature/stages/design.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    *   **Name.** If no feature exists, propose a short name from the request (lowercase kebab-case, `^[a-z0-9][a-z0-9-]{0,30}$`, for example `export` for "an export-to-PDF feature"). Ask the user to confirm or change it, then call `feature.ps1 new -Name <name>`.
    *   Then read and follow `skills/feature/egm/skills/egm-draft/SKILL.md`, applying these differences:
        *   Write to `docs/designs/<name>.md` in `<repo>`, not to `design_draft.md`.
        *   After each approved section, run `feature.ps1 commit-design -Section "<section heading>"`.
        *   Skip EGM Step 6.2 (picking the target folder).
        *   If the problem statement is missing, ask for it in chat.
    *   When all sections are approved, run `feature.ps1 stage -To design-review`.

#### 3. `skills/feature/stages/design-review.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    *   Read and follow the vendored `egm-review`, `egm-review-loop` and `egm-resolve` text, with these differences:
        *   **Reviewer runs.** Instead of spawning `egm:*` agents, take each run from `status.reviewRuns`, which lists the review's lens runs with their `id`, `persona`, `model`, `standard` and `done` (item 8). For each run not done, call `delegate.ps1 -Agent cursor -Profile review -Persona <persona> -Model <model> [-Standard <standard>] -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <id> -TaskFile <task file>`, following the cap rule (item 1).
        *   **Task file.** Written to `.xagent/features/<name>/<id>.task.md`. It names the design doc's path and line range (the doc is committed, so the worktree has it) and the `GoldfishContext` list, which the reviewer reads with its file tools.
        *   **Raw reports.** Copy each `reviewFile` to `docs/features/<name>/reviews/raw/<id>.md` and run `feature.ps1 commit-records -Message "review: <id>"` before synthesizing. Then run `delegate.ps1 -Cleanup -Profile review -Repo <repo> -TaskId <id>`. On resume, the runs with `done: false` in `status.reviewRuns` are still to do, and the review continues from the first of them.
        *   **Re-audit.** After "update the doc first", run `feature.ps1 reaudit -Phase <egm phase>`, which adds that phase's runs again with an `-r<k>` suffix.
        *   **Synthesis.** The lead does the synthesizer's job, following `skills/feature/egm/agents/synthesizer.md`, writes `docs/features/<name>/reviews/design-<n>.md` and commits it with `commit-records`. Every finding left out is logged with `feature.ps1 decision -Kind dismiss -Text "<lens>: <finding> — <reason>"`.
        *   **Failed reviewers** are handled per Goldfish review routing. A lens recorded as not run blocks the gate until it is rerun or waived (`decision -Kind dismiss -Text "<run id>: not run — <reason>"`). The retry ladder isn't recorded: after a resume it starts again from the first attempt.
        *   **Checkpoints.** EGM's stage checkpoints become chat questions. They are not recorded gates.
    *   After resolution, ask for **design-locked**. On a clear yes, in this order, so the recorded blob is the final one:
        1.  Set the design doc's `Status:` to `Approved`, and run `feature.ps1 commit-design -Section Status`.
        2.  Run `feature.ps1 gate -Gate design-locked -Quote "<user words>"`.
        3.  Run `feature.ps1 stage -To plan`.

#### 4. `skills/feature/stages/plan.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    *   **Write the plan** as JSON matching `skills/feature/schemas/plan.schema.json`, in a temporary input file `<repo>/.xagent/features/<name>/plan-input.json`.
        *   The plan has a `summary`, then phases (each with a `rationale` and a test command), then tasks. Each task has:
            *   `id`: the short task part, `^[a-z0-9][a-z0-9-]*$`. The script builds the `delegate` task id from it.
            *   `title` and `dependsOn` (task ids);
            *   `files`: files, folders (ending in `/`) or globs that it may touch;
            *   `test`: the exact, non-interactive test command;
            *   `profile`: `code` or `code-hard`;
            *   `brief`: one paragraph, which the task file expands.
    *   **Plan rules.**
        *   Every task is a worker task. Architecture is settled in the design, and cross-cutting changes become worker tasks with broad `files`.
        *   Steps that `delegate` never delegates (secrets, credentials, deploys) are listed in the plan summary as steps for the user.
        *   The last phase's test is the full suite. Sign-off runs the same command.
    *   **Import and check.**
        1.  Run `feature.ps1 plan -PlanFile <path>`. It validates the plan, writes it into `feature.json`, generates `plan.md`, deletes the input file and commits.
        2.  Run the plan review like the design review (item 3: runs from `status.reviewRuns`, task files, raw reports, cleanup, synthesis into `reviews/plan-<n>.md`, and dismissals). Its target is `docs/features/<name>/plan.md`, with the design doc as `GoldfishContext`.
        3.  Triage the findings per `delegate`'s rule (fix what would make two workers build different things).
        4.  To change the plan, write a new complete input file and import it again.
    *   **Re-plan after going back.** Already merged tasks stay in the plan, unchanged. Rework is added as new tasks.
    *   **Offer a council** if the plan contains a choice that is hard to reverse.
    *   **Approve.** Ask for **plan-approved**, stating that phase check-ins are off unless the user asks for them. On a clear yes:
        1.  Run `feature.ps1 gate -Gate plan-approved -Quote "<user words>" -Checkin on-problems`, or `every-phase` if the user asked for check-ins.
        2.  Run `feature.ps1 stage -To build`.

#### 5. `skills/feature/stages/build.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**: The file says first: "Follow `delegate`'s loop (task file, preflight, run, review, iterate, merge, cleanup). This file lists only what differs for feature tasks." The differences:
    *   **Picking tasks.** Take tasks only from `feature.ps1 schedule`, which returns each ready task with its `delegateTaskId` and worker `model`. When two are ready, run both in the same message.
    *   **Running a task.**
        *   Call `feature.ps1 task -Task <id> -Status preflight` before the preflight, and `task -Task <id> -Status running` before the worker.
        *   Write the task file `.xagent/features/<name>/<id>.task.md` from `templates/task.md` (item 11), copying the task's `files` and `test` from `feature.json` exactly.
        *   Run `delegate.ps1 -Agent cursor -Model <model> -Profile <profile> -Feature <name> -Base feature/<name> -Repo <repo> -TaskId <delegateTaskId> -TaskFile <task file>`.
        *   After it returns, run `feature.ps1 task -Task <id> -Status in-review -SessionId <sessionId> -ResultFile <worktree>/.xagent/result.json -Worktree <worktree> -BaseSha <baseSha>`, with the other values from `delegate.ps1`'s summary.
    *   **Preflight.** Run it when `delegate`'s preflight rules call for it, on the task file, following the cap rule:
        *   `delegate.ps1 -Agent cursor -Profile review -Persona comprehension -Model <worker model> -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <delegateTaskId>-pc -TaskFile <task file>`;
        *   `delegate.ps1 -Agent cursor -Profile review -Persona implementation_readiness -Model deepseek-v41-flash-1017-medium -Standard implementation-readiness-standard.md -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <delegateTaskId>-pr -TaskFile <task file>`.
        *   Clean up each with `delegate.ps1 -Cleanup -Profile review -Repo <repo> -TaskId <that id>`.
    *   **After each worker run.**
        *   Call `feature.ps1 verify -Task <id>`. A non-empty `outOfScope` is a problem stop.
        *   Then read each changed file's diff separately (`git -C <worktree> diff <baseSha> -- <file>`).
        *   A compression marker means that file is unread. The forms seen so far (`docs/test-plan.md`, the delegate and council trial notes) are `[... compressed ...]`, `[↑NL same as …]` and `<<ccr:…>>`. Read the file in smaller ranges (`git -C <worktree> diff <baseSha> -U3 -- <file>`, or `Read` with an offset) until no marker remains. `headroom_retrieve` may also work, but it is untested (T6).
    *   **Usage limit.** A run that reports a usage limit is a problem stop. Every other failed run takes the normal failed-run path.
    *   **Review rounds.** Log each failed round with `decision -Kind round -Text "<id>: <reason>"`. `status.tasks[].rounds` counts only the rounds since the task's latest council.
    *   **Cap check first.** A failed review when `status.tasks[].councils` is already 2 is a problem stop: log `decision -Kind stop -Text "<id>: failed review after the second council — <reason>"`, with no `[council]` line, and convene nothing.
    *   **Council escalation.** Otherwise, when `rounds` reaches 2 on `code`, or 1 on `code-hard`, convene a build council. Follow `delegate`'s council procedure (SKILL.md, "Council"), with only these differences. `<k>` is `councils + 1`.
        *   **Question:** in `.xagent/features/<name>/<id>.council-<k>.q.md`, the task file, each failed round's review feedback, the last attempt's diff (`git -C <worktree> diff <baseSha>`), and "What change would make this task pass review? Name the concrete fix."
        *   **Runs:** both seats with `-Seat grok` and `-Seat glm`, each with `-Feature <name> -Repo <repo> -TaskId <delegateTaskId>-c<k>`, following the cap rule. At most two rounds, and round 2 only when the seats name different fixes. Clean up with `-Cleanup -Profile council -Repo <repo> -TaskId <delegateTaskId>-c<k>`.
        *   **Consensus** (`delegate`'s rule): log `decision -Kind council -Text "<id>: consensus — <one-line guidance>"`. Write the delta brief `.xagent/features/<name>/<id>.council-<k>.md` (the task file, then `## Council guidance`, then `## Previous attempt` with the failed feedback). Discard the attempt (`delegate.ps1 -Cleanup -Discard -Repo <repo> -TaskId <delegateTaskId>`), and rerun the same `delegateTaskId` on `-Profile code-hard` with the delta brief and no `-Resume`. The round count is 0 again.
        *   **Disagreement:** log `decision -Kind council -Text "<id>: disagreement — <summary>"`, save `delegate`'s escalation brief to `.xagent/features/<name>/<id>.council-<k>.brief.md`, show it, and make a problem stop.
    *   **Fix-ups.**
        *   **Before the merge.** First stage the worker's work (`git -C <worktree> add -A`). Then make the edit in the worktree, and take the counts from `git -C <worktree> diff --shortstat`, which now shows only the lead's unstaged edit. The merge step's commit includes both. Log `decision -Kind fix-up -Text "<id>: <files> files, <lines> lines — <what>"`, then run `verify` again.
        *   **After the merge** (a phase test failing on `feature/<name>`). Edit in `<repo>`, commit with the message `fix-up: <what>`, and log the same way, with `phase <n>` in place of the task id. The phase test is the check.
    *   **Merge.** On accept:
        1.  Commit everything in the worker worktree (`git -C <worktree> add -A`, then `commit`), so a fix-up is included. If cleanup later reports tracked changes, stop rather than discard them.
        2.  Run `feature.ps1 merge -Task <id> -Message "<msg>"`.
        3.  Run `delegate.ps1 -Cleanup -Repo <repo> -TaskId <delegateTaskId>`.
    *   **Phase end.** When all tasks of a phase are merged:
        1.  Run the phase test in `<repo>`. If a fix-up solves a failure, log it. Otherwise make a problem stop.
        2.  If phase check-ins are on, report and stop.
        3.  Otherwise, continue to the next phase.
    *   **Merging `main` in.** At a phase boundary, when the user asks: run `git merge --no-ff main` in `<repo>`, log a `decision`, and run the phase test again. On a conflict, run `git merge --abort`, show the files, and stop for the user.
    *   **End of build.** When the last phase is done, run `feature.ps1 stage -To signoff` and report.
    *   **Problem stop.**
        *   **Stopping:** run `feature.ps1 decision -Kind stop -Text "<id or phase>: <why>"`, report to the user, and end the turn.
        *   **Resuming:** when the user says to go on:
            1.  Run `decision -Kind resume -Text "<what was decided>"`.
            2.  For a `failed` task the user wants retried, run `task -Task <id> -Status pending`.
            3.  After a council stop, the retry uses the profile and brief the user chose. The default is `code-hard` with the last delta brief.

#### 6. `skills/feature/stages/signoff.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    1.  Stop unless `feature.ps1 status` shows a clean tree on `feature/<name>`.
    2.  Run the last phase's `test` command (the full suite) in `<repo>`.
    3.  Write `git diff main...feature/<name>` to `<repo>/.xagent/features/<name>/final.diff`.
    4.  Write a task file naming the locked design's path, and saying the diff is `.xagent/final.diff` in the reviewer's worktree.
    5.  Take the one run from `status.reviewRuns` (persona `drift_report`, model `grok-4.7-medium`, no standard), and run `delegate.ps1 -Agent cursor -Profile review -Persona drift_report -Model <model> -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <id> -TaskFile <task file> -TargetFile <repo>/.xagent/features/<name>/final.diff`.
        *   **If it ends without a report:** retry once with the same model. If that fails, run it once on `glm-5.2-high` and log a `decision`. If that fails too, the lens is recorded as not run, which blocks the gate.
        *   Pass `-KeepRuleFiles` if `status.diffTouchesRuleFiles` is true.
        *   Copy `reviewFile` to `docs/features/<name>/reviews/raw/<id>.md`, commit it with `commit-records`, then run `delegate.ps1 -Cleanup -Profile review -Repo <repo> -TaskId <id>`.
    6.  Show the test results and the findings, grouped as missing, added or changed behaviour.
    7.  Ask for **signed-off**. On a clear yes:
        1.  Run `feature.ps1 gate -Gate signed-off -Quote "<user words>"`.
        2.  Run `feature.ps1 finish`.
        3.  Ask whether to push.

#### 7. `skills/feature/stages/status.md` (Create)

*   **Type / Scope**: Stage instructions for "where are we?".
*   **Proposed Changes**: Print the output of `feature.ps1 status` as a short report:
    *   the stage and phase;
    *   tasks by status;
    *   what the flow is waiting on;
    *   the token use so far, including cache reads;
    *   the last 3 decisions;
    *   the action "continue" would take.

    Make no changes. With no active feature, list the features in progress.

#### 8. `skills/feature/scripts/feature.ps1` (Create)

*   **Type / Scope**: PowerShell 7 script. It is the only writer of feature state. It prints one compact JSON object on stdout.
    *   **Success** (including `verify` with a failing test, and `reconcile` with contradictions): exit 0, with `ok: true` plus the result.
    *   **A refused or failed command:** exit 1 with `{ok:false,error}`.
    *   This differs from `delegate.ps1`, which exits 0 with `ok:false` when a worker fails.
*   **Proposed Changes**:
    *   **Common parameters**:
        *   `-Repo`: the checkout's top level. If omitted, `git -C <Cwd or current folder> rev-parse --show-toplevel`.
        *   `-Name`, pattern `^[a-z0-9][a-z0-9-]{0,30}$`. If omitted, the selection rules pick it.
        *   `-Cwd`: the session's folder, used for selection rule 2.
    *   **Setup.** `.xagent/` is added to `info/exclude` the same way `delegate.ps1` does it.
    *   **Commits.** The script's commits stage only files under `docs/features/<name>/`. The one exception is `commit-design`, which stages only the design doc.
    *   **Clean tree** means no staged or unstaged changes to tracked files (`git status --porcelain --untracked-files=no` is empty). Untracked files don't count.
    *   **Listing features.** For each local branch `feature/<n>`, read `git show feature/<n>:docs/features/<n>/feature.json`. Its stage is the stored one, except that a feature whose branch is an ancestor of `main` and which has `signed-off` recorded is `done`. `done` is derived this way and never written, so the branch, `main` and the list always agree. A feature is in progress unless it is `done` or `abandoned`. `new`, `status`, `reconcile` and the selection rules all use this list.
    *   **Lock.** Every command that writes first takes `.xagent/features/<name>/.lock`, holding `{pid, startTime}` from `(Get-Process -Id $PID).StartTime`. If that pid is running with the same start time, it fails with "another session is working on this feature". Otherwise it takes the lock over. The lock is released in a `finally` block.
    *   **Shared logs** are read from `$env:XAGENT_LOG_DIR`, or `%LOCALAPPDATA%\xagent\` when that is unset. The only file is `runs.jsonl`, written by `delegate.ps1`. If the folder can't be read, `status` reports token use as `null` with a warning.
    *   **`delegate`'s files** are found at `$PSScriptRoot/../../delegate/` (`models.json`, `scripts/delegate.ps1`), since both skills are installed side by side. If they're missing, every command fails with that path, and `doctor` checks it. The worker model for a profile is `profiles.<profile>.model`.
    *   **Run ids.** Every `delegate` task id is built by this script and must fit `delegate`'s `^[a-z0-9][a-z0-9-]{0,48}$`. `<name12>` is the name cut to 12 characters, without a trailing `-`.
        *   **Task:** `<name12>-<task>`, at most 33 characters. `plan` rejects a task id longer than 20, and task ids are unique, so these ids can't collide. `plan` stores it as `delegateTaskId`.
        *   **Preflight:** `<delegateTaskId>-pc` (comprehension) and `-pr` (readiness).
        *   **Council:** `<delegateTaskId>-c<k>`. The seats are kept apart by `-Seat`, not by the id.
        *   **Lens runs:** `<name12>-<r><n>-<lens>-p<phase>`, where `<r>` is `d` (design review), `p` (plan review) or `s` (sign-off), and `<n>` is the review number. A re-audit adds `-r<k>`. `<lens>` is a two-letter code: `zo` (zoom_out), `ic` (inventive_catalyst), `cm` (comprehension), `dc` (design_critic), `st` (structural), `sy` (style), `ir` (implementation_readiness), `cd` (codebase_details), `dr` (drift_report). For example, `export-d1-zo-p5` and `export-d1-zo-p8` are the two zoom-out runs. The phase is omitted for the plan review and sign-off. The longest id is under 40 characters.
    *   **Review runs.** The script holds the [lens-runs table](#lens-runs-per-review) as data. Each row is a review, an EGM phase, a persona, a model (from `models.json`: `seats.judgement[0]` for Grok, `[1]` for GLM, `seats.readiness`, or the review profile's model for comprehension) and a standard (from `standards.json`). For the current review stage, `status.reviewRuns` lists every run of review `<n>`, plus re-audit runs from `[reaudit]` lines, each with `{id, phase, persona, model, standard, done}`. A run is `done` when `reviews/raw/<id>.md` is committed.
    *   **Review number.** `<n>` for a review is 1 plus the number of committed syntheses for that review (`reviews/design-*.md` or `reviews/plan-*.md`; sign-off has no synthesis, so it is always 1). So it stays the same until that review's synthesis is written.
    *   **Decision lines** are `- <ISO time> [<kind>] <text>`. For `round`, `council`, `fix-up` and `stop`, the text starts with `<task id>:` (or `phase <n>:`). For `dismiss`, it starts with `<lens>:` (a finding) or `<run id>:` (a lens not run), and for `reaudit` with `<review><n>: phase <p>`. Counts parse that prefix.
    *   **Path rules.** Paths are normalized to forward slashes, lowercase, with no leading `./`. An entry that ends in `/` is a folder. Anything else is a file or a glob.
        *   **Overlap key** (used by `schedule`): a file or folder is its own key. A glob's key is its folder part, up to the last `/` before the first wildcard (`src/test*.ts` → `src/`). An empty key (`**`, `*.md`) overlaps everything. Two keys overlap when one is a prefix of the other.
        *   **Scope match** (used by `verify`): a changed file is in scope if it equals a file entry, sits under a folder entry, or matches a glob entry (`*` within one folder, `**` across folders). `src/test*.ts` accepts `src/testing.ts` and rejects `src/other.ts`.

    | Subcommand | Arguments | Behaviour |
    |---|---|---|
    | `doctor` | — | Check the prerequisites listed in Installation, and print what's missing plus the permission rules to add. |
    | `new` | `-Name` | Fail if the tree isn't clean, the branch exists, or the feature list has a feature in progress. Run `git switch -c feature/<name> main`. Write `feature.json` (`{name, stage: "design", checkin: "on-problems", designDoc: "docs/designs/<name>.md", gates: {}}`) and `decisions.md` from the template, and commit `feature(<name>): start`. |
    | `status` | `[-Name]`, `[-Cwd]` | Selection rules, then print an object matching `status.schema.json`. With no feature, print `{selected:null, features:[…]}`. Read-only, and takes no lock. |
    | `reconcile` | `-Name` | Apply the reconcile table, including checking pid files for in-flight tasks. When a task becomes `failed`, add 1 to its local `failures`. A second failure appends and commits a `[stop]` (only when `feature/<name>` is checked out; otherwise the contradiction `stop-not-recorded`). Print `{name, changes:[], contradictions:[], lost:[]}`. Contradiction kinds: `branch-missing`, `wrong-branch`, `merge-in-progress`, `merged-without-trailer`, `merged-without-signoff`, `stop-not-recorded`. Contradictions change nothing. |
    | `stage` | `-Name`, `-To`, `[-Reason]` (default `<from> -> <to>`, the decision text) | Forward moves one step at a time. Where the stage table lists a gate to leave the current stage, only with that gate recorded. Backward moves to any earlier stage clear that stage's exit gate and every later gate. `abandoned` is allowed from any stage, and switches to `main` if the tree is clean. Append a decision and commit. |
    | `gate` | `-Name`, `-Gate`, `-Quote`, `[-Checkin]` | The gate must match the stage (`design-review` → `design-locked`, `plan` → `plan-approved`, `signoff` → `signed-off`). Record `{at, quote, sha}`, where `sha` is `git rev-parse feature/<name>`. For `design-locked`, also record `designBlob`, the blob of `designDoc` at that SHA. Append a decision and commit. `-Checkin` is allowed only with `plan-approved`, and sets the mode through the same code as `checkin`. |
    | `plan` | `-Name`, `-PlanFile` | Allowed only in stage `plan`. Validate against `plan.schema.json`, then check: unique ids of at most 20 characters, existing `dependsOn`, no cycles, a dependency's phase ≤ the task's phase, and non-empty `files`. Compute the `delegateTaskId`s, keeping the earlier one for any task already in `feature.json`. A re-plan must still contain every task that has an `Xagent-Task` trailer on `feature/<name>`, with every field equal (judged from git, not from `state.json`). Write the plan into `feature.json`, generate `plan.md`, delete the input file and commit. |
    | `schedule` | `-Name` | Count `liveRuns` first. Return no tasks while a `[stop]` is open or before a plan exists (`liveRuns` and `cap` are still returned, for the cap rule). Otherwise, from the lowest phase with unmerged tasks, take the `pending` tasks whose dependencies are all `merged` and whose overlap keys overlap no `preflight`, `running` or `in-review` task. The live runs are the pid files in `.xagent/runs/*/` whose process is running and whose `feature` is `<name>`. Return at most `2 − liveRuns` tasks. Print an object matching `schedule.schema.json`. |
    | `task` | `-Name`, `-Task`, `[-Status] [-SessionId] [-ResultFile] [-Worktree] [-BaseSha]` | Update local `state.json` only. |
    | `verify` | `-Name`, `-Task`, `[-TimeoutSec]` (default 900) | In the task's `worktree`: list the changed files (`git diff --name-only <baseSha>`, which includes uncommitted changes, plus `git ls-files --others --exclude-standard`, so ignored build output like `__pycache__` doesn't count), and apply the scope match. Run `test` with a timeout of `-TimeoutSec` seconds, as `delegate.ps1` does. On a timeout, kill the process tree and set `exitCode: -1` and `passed: false`. Store the result and print an object matching `verify.schema.json`. Change nothing. Fail if the worktree is gone. |
    | `merge` | `-Name`, `-Task`, `-Message` | Refuse unless the tree is clean and `HEAD` is `feature/<name>`. Run `git merge --no-ff xagent/<delegateTaskId>` with `<Message>`, a blank line, then `Xagent-Task: <id>`. On conflict, run `git merge --abort` and fail with the files. On success, set `merged`. |
    | `decision` | `-Name`, `-Kind`, `-Text` | Append and commit. Kinds: `decision`, `gate`, `stage`, `round`, `council`, `fix-up`, `dismiss`, `stop`, `resume`. (`[reaudit]` lines are written only by `reaudit`.) `resume` fails without an open `stop`. |
    | `reaudit` | `-Name`, `-Phase` | Append `[reaudit] <review><n>: phase <p>` for the current review, so `status.reviewRuns` adds that phase's runs with the next `-r<k>`. Commit. |
    | `commit-design` | `-Name`, `-Section` | Commit only `designDoc`, with the message `feature(<name>): design – <Section>`. |
    | `commit-records` | `-Name`, `-Message` | Commit only files under `docs/features/<name>/` (raw reports, syntheses), with the message `feature(<name>): <Message>`. |
    | `checkin` | `-Name`, `-Mode <on-problems\|every-phase>` | Set it in `feature.json`, append a decision and commit. |
    | `finish` | `-Name` | Require `signed-off`, a clean tree and `HEAD` on `feature/<name>`. Refuse if `git diff --name-only <signed-off sha> HEAD` lists any file outside `docs/features/<name>/` (the gate's own commit changes only those), or the blob of `designDoc` at `HEAD` differs from `designBlob` on `design-locked`. Run `git switch main` and `git merge --no-ff feature/<name>`. On conflict, run `git merge --abort` and `git switch feature/<name>`, clear `signed-off` (committed on `feature/<name>`), and fail. On success, the feature is `done` by the listing rule, so nothing more is written. Never push. |

    *   **`plan.md`**, generated by `plan`:
        *   a title `# Plan: <name>`, the summary, and the check-in mode;
        *   one `## Phase <n>` per phase, with its rationale and `Test: <command>`;
        *   under each phase, a table with the columns `Id`, `Title`, `Depends on`, `Files`, `Profile` and `Test`;
        *   each task's brief as a short paragraph under the table, headed by its id.

#### 9. `skills/feature/schemas/` (Create)

*   **Type / Scope**: JSON Schemas, draft 2020-12 (`"$schema": "https://json-schema.org/draft/2020-12/schema"`), one file per validated object, with no cross-file `$ref`s. `feature.ps1` and the Pester tests validate with `Test-Json -Json <text> -SchemaFile <file>`, which in PowerShell 7.4 and later uses JsonSchema.Net. `doctor` checks for PowerShell 7.4 or later.
*   **Files**: `feature.schema.json`, `plan.schema.json` (it defines the task in its own `$defs/task`), `status.schema.json`, `schedule.schema.json` and `verify.schema.json`. `feature.schema.json` checks `phases` only as an array of objects, because each plan is validated by `plan.schema.json` when it is imported.
*   **Proposed Changes**:
    *   **`feature.json`**:
        *   required: `name`, `stage` (`design`|`design-review`|`plan`|`build`|`signoff`|`abandoned`; `done` is derived, never stored), `checkin` (`on-problems`|`every-phase`), `designDoc`, and `gates` (keyed by gate name: `{at, quote, sha, designBlob?}`);
        *   optional until `plan` runs: `summary`, and `phases` (`{n, rationale, test, tasks}`).
    *   **Tasks in `feature.json`**: as in the plan, plus `delegateTaskId`, set by `plan`.
    *   **`plan.schema.json`**: `summary` and `phases` (`{n, rationale, test, tasks}`). `$defs/task` is `id`, `title`, `dependsOn`, `files`, `test`, `profile` (`code`|`code-hard`) and `brief`.
    *   **`status.schema.json`**:
        *   `ok`, and `selected` (the name, or `null`), with `features` (`[{name, stage}]`) when nothing is selected;
        *   `stage`, `phase` (`{current, total}`, or `null` before a plan exists) and `checkin`;
        *   `branch` and `treeClean`;
        *   `tasks`: `[{id, delegateTaskId, status, rounds, councils, failures}]`;
        *   `waitingOn`: `null`, `{gate}`, `{stop: "<text>"}` or `{running: [ids]}`;
        *   `reviewRuns`: `[{id, phase, persona, model, standard, done}]` for the current review stage (item 8), or `[]`;
        *   `diffTouchesRuleFiles`: whether `git diff --name-only main...feature/<name>` includes `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursorrules`, or anything under `.cursor/` or `.agents/`, at any depth;
        *   `tokens` (`{input, output, reasoning, cacheRead, total}`, where `total` includes `cacheRead`, or `null`);
        *   `lastDecisions`: the last 3 lines of the committed `decisions.md`;
        *   `nextAction`: one sentence, taken from a fixed table in the script keyed by the stage and `waitingOn` (for example, `build` with nothing waiting gives "Run the next ready tasks from schedule").
    *   **`schedule.schema.json`**: `ok`, `liveRuns`, `cap` (2), and `tasks: [{id, delegateTaskId, profile, model, files}]`.
    *   **`verify.schema.json`**: `ok`, `inScope` (a boolean), `changed: []`, `outOfScope: []`, and `test: {command, passed, exitCode, tail}`, where `tail` is the last 40 lines.

#### 10. `skills/feature/schemas/state.schema.json` (Create)

*   **Type / Scope**: JSON Schema for the local `state.json`.
*   **Proposed Changes**: `name`, `lastReconcile`, and `tasks` (keyed by task id: `status`, `sessionId`, `resultFile`, `worktree`, `baseSha`, `failures`, `verify`).

#### 11. `skills/feature/templates/` (Create)

*   **Type / Scope**: Templates. `plan.md` is generated (its layout is in item 8), so it needs none.
*   **`decisions.md`**, which `feature.ps1 new` copies with `<name>` filled in:

    ```markdown
    # Decisions: <name>

    Append-only. One line per entry: `- <ISO time> [<kind>] <text>`. Written only by feature.ps1.

    ```
*   **`task.md`**, the worker's task file. The build stage fills it in. It follows `delegate`'s task-file sections:

    ```markdown
    # Task <id>: <title>

    ## Goal
    <brief>

    ## Scope
    You may change only these paths (files, folders ending in /, or globs):
    <files, one per line, copied exactly from feature.json>
    Do not change anything else, and do not commit or push.

    ## Constraints
    No new dependencies unless the brief says so. Follow the existing style.

    ## Acceptance criteria
    This command passes, run from the repository root:
    <test, copied exactly>

    ## Context
    Design: <designDoc> (read the sections relevant to this task).
    <interfaces, gotchas and links the lead adds>
    ```

    A council delta brief is this file plus `## Council guidance` and `## Previous attempt` sections (item 5).

#### 12. `skills/feature/egm/` (Create, vendored, unmodified)

*   **Type / Scope**: A copy of upstream EGM at commit `b7d9e27`, keeping the upstream relative paths, so diffing is direct.
*   **Source**: `git clone https://github.com/google/elephant-goldfish-model` and `git checkout b7d9e27`, or the installed plugin's marketplace clone (`~\.claude\plugins\marketplaces\egm`) after checking that its `HEAD` is `b7d9e27`.
*   **Proposed Changes**: Copy these files:
    *   `skills/egm-draft/SKILL.md` and `skills/egm-draft/references/design_doc.md`
    *   `skills/egm-review/SKILL.md`, `skills/egm-resolve/SKILL.md` and `skills/egm-review-loop/SKILL.md`
    *   `resources/execution_instructions.md`
    *   `agents/synthesizer.md`
    *   `LICENSE` (as `LICENSE-egm`)

    The document standards aren't copied here. The copies `delegate.ps1` reads live in `skills/delegate/personas/` (item 13), so there is one copy of each.

#### 13. `skills/delegate/personas/` (Modify)

*   **Type / Scope**: Goldfish personas run by `delegate.ps1`. Keeping one copy here avoids duplicating persona files between the skills.
*   **Proposed Changes**:
    *   **Keep** the unmodified upstream files already committed during this design's review: `zoom_out.md`, `inventive_catalyst.md`, `codebase_details.md`, `structural.md`, `style.md` and `zoom-out-standard.md`.
    *   **Add** the unmodified upstream `resources/document_standards/feature-spec-standard.md`.
    *   **Add our own `drift_report.md`, adapted from EGM.**
        *   It quotes EGM's drift checklist: missing features, incomplete models, logic shortcuts, architectural divergence, and logic not covered by the design.
        *   It asks for one read-only pass over the design and the diff file, returning three lists: missing, added and changed behaviour.
        *   Its header says it is modified from upstream `skills/egm-drift-report/SKILL.md` at `b7d9e27`, per Apache-2.0 §4(b).
    *   **Add `standards.json`**, the default standard per persona, used when the caller passes no `-Standard`:

        ```json
        {
          "implementation_readiness": "implementation-readiness-standard.md",
          "codebase_details": "implementation-readiness-standard.md",
          "zoom_out": "zoom-out-standard.md",
          "design_critic": "feature-spec-standard.md",
          "structural": "feature-spec-standard.md",
          "inventive_catalyst": "feature-spec-standard.md"
        }
        ```
    *   `comprehension`, `style` and `drift_report` have no entry, so they get no standard (item 14: with neither `-Standard` nor an entry, nothing is appended).
    *   **Appending the standard.** `delegate.ps1` appends it under the heading `Target Standard (follow it; this is the standard the persona refers to, including any resources/document_standards/ path)`, so `zoom_out.md`'s upstream path resolves to the text that follows.
    *   Update `README.md`.

#### 14. `skills/delegate/scripts/delegate.ps1` (Modify)

*   **Type / Scope**: Worker launcher.
*   **Proposed Changes**: Each change listed in [Changes to `delegate` in v1](#changes-to-delegate-in-v1), with these details:
    *   **`-TargetFile <path>[,<path>]`.** Copy each file into the read-only worktree's `.xagent/` under its file name, and name the copies in the prompt.
    *   **`-Standard <file>`.** A file name in `personas/`. Without it, use `standards.json`. With neither, append nothing.
    *   **Rule files.** Remove them in read-only runs, with `-KeepRuleFiles` as the exception. Restore them in a `finally` block and in `-Cleanup`.
    *   **Models.** Read them from the new `models.json` (item 15). Keep both `claude` and `^auto$` blocked.
    *   **`-Seat <label>`** (`^[a-z0-9]+$`). The read-only worktree and log suffix is `-<Seat>` when given, and `-<Agent>` otherwise. `-Cleanup` removes every `<TaskId>-*` read-only worktree, instead of looping over `cursor` and `agy`.
    *   **`-Feature <name>`.** Written as `feature` on the `runs.jsonl` line and in the pid file.
    *   **The summary JSON** gains `baseSha`, the commit the worktree was created from.
    *   **`-Agent agy`** fails with the T0 reason unless `models.json` has `agy.enabled: true`.
    *   **Secret variables** are removed from the worker's environment (the denylist in Risks & Mitigations).
    *   **Pid file per run:** `<logBase>.pid` holds `{pid, startTime, childPid, childStartTime, feature}`: `delegate.ps1` itself, and the CLI process from `Start-Process`. It is written right after the launch and deleted when the run ends.
        *   **A run is live** when `pid` is running with the same start time.
        *   **A worker is orphaned** when `pid` is gone but `childPid` is running with the same start time. Reconcile kills only that process tree (`taskkill /T /F /PID <childPid>`), so an unrelated process that reused a pid is never touched.
    *   **`runs.jsonl`** is written to `$env:XAGENT_LOG_DIR`, or `%LOCALAPPDATA%\xagent\` when that is unset. Its `usage.total` stays `input + output + reasoning`. Consumers that need Cursor's figure add `cacheRead`.

#### 15. `skills/delegate/models.json` (Modify)

*   **Type / Scope**: Model profiles and seats.
*   **Proposed Changes**: The new shape (the per-agent keys go away, because every run is Cursor):

    ```json
    {
      "profiles": {
        "code":      { "readOnly": false, "model": "composer-2.5" },
        "code-hard": { "readOnly": false, "model": "grok-4.7-high" },
        "review":    { "readOnly": true,  "model": "composer-2.5" },
        "council":   { "readOnly": true,  "seats": { "grok": "grok-4.7-high", "glm": "glm-5.2-high" } }
      },
      "seats": {
        "readiness": "deepseek-v41-flash-1017-medium",
        "judgement": ["grok-4.7-medium", "glm-5.2-high"]
      },
      "agy": { "enabled": false, "reason": "T0: Antigravity FAQ forbids wrapping agy in third-party agents on consumer plans" },
      "blockedModelPatterns": ["claude", "^auto$"]
    }
    ```

    `comprehension` uses the worker's model, so it has no seat. `feature.ps1` reads `seats` to fill in the models of the review runs. The `_comment` field is rewritten to describe this shape, with no `agy` routing advice. With `-Profile council -Seat <s>`, the model is `profiles.council.seats.<s>` unless `-Model` is given.

#### 16. `skills/delegate/SKILL.md` (Modify)

*   **Type / Scope**: Docs.
*   **Proposed Changes**:
    *   Replace the absolute `D:/cross-agent-loop/...` paths with paths from the skill's base directory.
    *   Replace the cursor-or-agy routing advice with the model seats. Document `-Seat`, `-Feature`, `-Standard`, `-TargetFile`, `-KeepRuleFiles`, the new log location and the T0 reason.
    *   List every `-Persona` value: `implementation_readiness`, `comprehension`, `design_critic`, `zoom_out`, `inventive_catalyst`, `codebase_details`, `structural`, `style` and `drift_report`.
    *   Mark the benchmark (head-to-head) section as unavailable in v1, with the reason: it needs a second worker, and `agy` is disabled.
    *   Note that `feature` merges with the `Xagent-Task` trailer.

#### 17. `benchmarks/bench.py`, `benchmarks/runs.jsonl` and `.gitignore` (Modify)

*   **Type / Scope**: Benchmark tooling and repo hygiene.
*   **Proposed Changes**:
    *   `bench.py` reads `runs.jsonl` from `$env:XAGENT_LOG_DIR`, or `%LOCALAPPDATA%\xagent\`.
    *   Move the tracked `benchmarks/runs.jsonl` there (appending to any existing file), then run `git rm --cached benchmarks/runs.jsonl` and delete the working copy.
    *   These land in the same commit as `delegate.ps1`'s log-path change (build step 1), so `bench.py report` never reads an empty file mid-build.
    *   Add `benchmarks/runs.jsonl` to `.gitignore`. `records.jsonl`, `trial-records.jsonl` and `REPORT.md` stay tracked.

#### 18. `scripts/new-sandbox.ps1` and `skills/feature/tests/fixtures/sandbox/` (Create)

*   **Type / Scope**: Test helper and its committed fixture. `sandbox/` at the repo root is gitignored scratch space, so the fixture lives under the tests.
*   **Proposed Changes**:
    *   Add `skills/feature/tests/fixtures/sandbox/calc.py` and `test_calc.py`, written fresh (`sandbox/` is not in the repo): `add(a, b)` and `multiply(a, b)`, and one `unittest` case for each. The sandbox's test command is `python -m unittest -q`. Python is needed only for this manual sandbox, so `doctor` reports it as optional.
    *   The script:
        1.  Copies that folder to a new temporary folder.
        2.  Runs `git init -b main` there and makes the first commit.
        3.  Prints the path.

    The end-to-end checks run there, and the folder is deleted afterwards.

#### 19. `skills/feature/tests/feature.Tests.ps1` and `skills/feature/tests/fixtures/` (Create)

*   **Type / Scope**: Pester tests. The file starts with `#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.5'}`. Each test:
    *   builds a throwaway repo in `$TestDrive` with a `main` commit;
    *   sets `XAGENT_LOG_DIR` to a folder in `$TestDrive`;
    *   calls `feature.ps1` as a child process, and checks its exit code and its JSON against the matching schema in `skills/feature/schemas/`.
*   **Proposed Changes**: These cases.
    *   **`new`**:
        *   refuses a dirty tree, a bad name, and a second feature in progress;
        *   creates the branch, switches to it, and commits a `feature.json` with `designDoc` and `checkin: on-problems`.
    *   **`stage` and `gate`**:
        *   `design` → `design-review` succeeds with no gate;
        *   `plan` → `build` without `plan-approved` fails;
        *   the gate in the wrong stage fails;
        *   `-Checkin` with any gate other than `plan-approved` fails;
        *   the gate records the quote, the time, the SHA and, for `design-locked`, the design blob;
        *   after going back to `design-review`, `stage -To plan` fails until a new `design-locked` is recorded;
        *   `abandoned` switches to `main` when clean, and stays on the branch when dirty.
    *   **`commit-design` and `commit-records`** commit only their own files, even when other files are modified.
    *   **`checkin`** switches the mode both ways.
    *   **`plan`**:
        *   rejects a cycle, an unknown dependency, a dependency in a later phase, a duplicate id, and running outside stage `plan`;
        *   builds `delegateTaskId`s from a 12-character cut name, rejects a task id over 20 characters, and keeps an existing task's `delegateTaskId` across a re-plan;
        *   generates `plan.md` in the layout from item 8, and deletes the input file.
    *   **Re-plan**: a re-plan that drops or changes a task with a trailer merge is rejected, even with `state.json` deleted.
    *   **`schedule`**:
        *   dependency gating;
        *   overlap keys: exact path, parent folder, `**`, `*.md`, `src/test*.ts` against `src/testing.ts` (overlap: same key `src/`), and `src/a/*` against `src/b/x.ts` (no overlap);
        *   the cap: two live fixture pid files for the feature mean no tasks, and pid files of another feature don't count;
        *   an open `[stop]` returns no tasks;
        *   with no plan, it returns no tasks but still reports `liveRuns` and `cap`;
        *   tasks carry the worker model and the `delegateTaskId`;
        *   phase advance.
    *   **`task`** updates only `state.json`.
    *   **`verify`**:
        *   scope match: in-scope changes, including `src/test*.ts` accepting `src/testing.ts` and rejecting `src/other.ts`;
        *   an out-of-scope file is reported;
        *   an untracked file is counted, and an ignored `__pycache__/` is not;
        *   a failing test is reported with its exit code (and the script still exits 0);
        *   a timeout gives `exitCode: -1`;
        *   the worktree is left as it was.
    *   **`merge`**:
        *   refuses a dirty tree and the wrong branch;
        *   carries the `Xagent-Task` trailer.
    *   **`reconcile`**:
        *   a trailer merge counts after the task branch is deleted;
        *   a manual merge with the trailers is absorbed;
        *   local `merged` without a trailer is a contradiction;
        *   a missing branch is a contradiction;
        *   another branch checked out asks to switch back;
        *   a merge in progress on `main` is reported;
        *   a task `running` with no live pid file and no output becomes `failed` and frees its slot;
        *   a finished run becomes `in-review`;
        *   a task in `preflight` whose live run is `<delegateTaskId>-pr` stays in `preflight`;
        *   a pid file whose `pid` is gone and whose `childPid` is live (a sleeping test process) has that process killed and the task marked `failed`. A `childPid` whose start time differs is left alone;
        *   a `failed` task is not scheduled until set back to `pending`, and a second failure opens a `[stop]`; with another branch checked out, it reports `stop-not-recorded` and commits nothing;
        *   a feature merged to `main` without `signed-off` is a contradiction;
        *   a missing local file is rebuilt and the losses are reported.
    *   **Committed state**:
        *   an open `[stop]` is reported as waiting with `state.json` deleted;
        *   `resume` without an open stop fails;
        *   rounds come from `decisions.md`, count only those since the task's latest `[council]`, and survive a deleted `state.json`;
        *   councils are counted across the whole log;
        *   a second process holding the lock (same pid and start time) makes a write fail, and a lock whose pid is gone, or whose start time differs, is taken over;
        *   lens progress comes from the committed raw reports: `status.reviewRuns` lists the 10 design-review runs with distinct ids (two `zo`, two `sy`), marks the committed ones `done`, and adds `-r1` runs after a `reaudit`;
        *   the review number stays the same until the synthesis is committed, then goes up by 1;
        *   every run id built for a 12-character name and a 20-character task fits `^[a-z0-9][a-z0-9-]{0,48}$`.
    *   **`status`**:
        *   each of the 4 selection rules, with rule 2 skipping `done` and `abandoned`;
        *   no feature gives `{selected:null, features:[]}`;
        *   `waitingOn` for a gate, a stop and a running task, and a `nextAction` for each stage;
        *   the token sum from a fixture `runs.jsonl`, matched on the `feature` field, with `total` including `cacheRead`;
        *   `-Repo` derived from `-Cwd`;
        *   `phase` is `null` before a plan exists;
        *   `diffTouchesRuleFiles` for a nested `.cursor/rules/x.md`, and false for an unrelated file;
        *   `lastDecisions` holds the last 3 committed lines;
        *   `done` is derived after `finish`, and a later `new` then succeeds.
    *   **`finish`**:
        *   fails without signed-off, on a dirty tree, or on the wrong branch;
        *   a conflict aborts, leaves `main` unchanged, and clears `signed-off`;
        *   it succeeds right after `gate -Gate signed-off` (whose own commit touches only `docs/features/<name>/`);
        *   a code commit after `signed-off`, or a design file that differs from `designBlob`, makes `finish` refuse;
        *   it merges and sets `done`;
        *   it never pushes (the test repo has no remote).
    *   **The drift persona** (fixtures `fixtures/drift/design.md` and `fixtures/drift/change.diff`: a small design plus a diff with one planted deviation): a manual check, run once, that `drift_report` reports it.
    *   **Other fixtures:** `fixtures/runs.jsonl` (two features' runs, with cache reads), and `fixtures/pid/` (pid-file samples). The repo files for the scope and overlap cases (`src/testing.ts`, `src/other.ts` and so on) are created by each test in `$TestDrive`. The `test` commands in test plans are PowerShell one-liners (`pwsh -NoProfile -c "exit 0"`, `exit 3`, and `Start-Sleep 5` with `verify -TimeoutSec 2`), so the suite doesn't need Python.
    *   **Out of scope for automated tests:** `doctor` (checked by hand on this machine), and the stage files (the manual CUJ checklist).

#### 20. `docs/test-plan.md` (Modify)

*   **Type / Scope**: Docs.
*   **Proposed Changes**: Add a `feature` section:
    *   the Pester command;
    *   how to install Pester (`Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck`);
    *   a manual checklist running CUJ 1–7 in a sandbox from `scripts/new-sandbox.ps1`, with each check covering one goal's pass criterion (G1–G7).

#### 21. `THIRD_PARTY_NOTICES.md` (Modify)

*   **Type / Scope**: Licensing.
*   **Proposed Changes**:
    *   List every file from items 12 and 13 at commit `b7d9e27` as unmodified (adding `feature-spec-standard.md` and the item 12 files), except `drift_report.md`, which is listed as adapted.
    *   Note the monthly upstream check.

#### 22. `docs/decisions/001-vendor-egm-workflow.md` (Modify)

*   **Type / Scope**: Decision record.
*   **Proposed Changes**: Record the final layout:
    *   the workflow text in `skills/feature/egm/`;
    *   the personas and standards in `skills/delegate/personas/`, with `drift_report.md` adapted;
    *   the monthly `git ls-remote` check;
    *   the sync script deferred until the first upstream change.

    Also correct the sentence saying attribution is "already done for the four `delegate` personas": the notices file lists all the personas.

#### 23. `README.md` and `docs/HANDOFF.md` (Modify)

*   **Type / Scope**: Docs.
*   **Proposed Changes**:
    *   **README**:
        *   Replace the Antigravity claims: v1 delegates only through the Cursor CLI, and the T0 result (2026-11-10) is the reason. Tick T0 in the status list.
        *   Add a `feature` section (what it does, the entry-point phrases, stages and gates) and the Installation steps.
    *   **HANDOFF**: replace the "Next" section with the build status. Add the open items: worker sandboxing (high priority after v1), plugin packaging, and the monthly EGM upstream check.

#### 24. `docs/designs/feature-skill.md` (Modify)

*   **Type / Scope**: This design. Set `Status: Approved` when the user locks it.

### Machine setup (outside the repo, not committed)

*   Link the skill: `New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\feature" -Target "<repo>\skills\feature"`. Do the same for `delegate`, or copy instead (see Installation for when to copy).
*   Add the permission rules that `feature.ps1 doctor` prints to `~\.claude\settings.json`. The rule uses the path Claude Code reports as the skill's base directory (the junction path), with forward slashes.
*   Install Pester 5.5 or later for the current user.

### Build order

Each step ends with its check passing, so the repo stays working.

1.  **`delegate` changes** (items 13–17).
    *   **Check:** the `delegate` regression in the Verification Plan.
2.  **`feature.ps1`, its schemas and template, the fixtures and the Pester tests** (items 8–11, 18 and 19), written test-first.
    *   **Sub-steps:**
        1.  the schemas;
        2.  `new`, `stage`, `gate`, `decision`, the commit helpers and `checkin`;
        3.  `plan` and `schedule`;
        4.  `task`, `verify` and `merge`;
        5.  `reconcile` and `status`;
        6.  `finish` and `doctor`.
    *   **Check:** after each sub-step, `Invoke-Pester skills/feature/tests` passes for every case written so far.
3.  **Vendored EGM and the notices** (items 12 and 21).
    *   **Check:** a diff of `skills/feature/egm/` against upstream `b7d9e27` shows no differences.
4.  **The router and stage files** (items 1–7).
    *   **Check:** the G1 phrase checks from the manual checklist.
5.  **Docs and machine setup** (items 20, 22 and 23, plus Machine setup). Item 24 is not a build step: `Status: Approved` is set when the user locks the design.
    *   **Check:** `feature.ps1 doctor` reports everything present.
6.  **The manual CUJ checklist** in a sandbox.

Steps 2 and 3 share no files and can be delegated in parallel. Step 4 is written by the lead, because it is prompt design.

### Verification Plan

*   **Unit tests**: `pwsh -NoProfile -c "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester skills/feature/tests -Output Detailed"`. All cases in item 19 pass.
*   **`delegate` regression**: re-run the `delegate` checks in `docs/test-plan.md` that touch profiles and personas, and add these:
    *   one judgement-lens review on `grok-4.7-medium` and one on `glm-5.2-high`, of this design doc, with `-Standard feature-spec-standard.md`;
    *   one `deepseek-v41-flash-1017-medium` readiness review;
    *   one review with `-TargetFile`: the reviewer quotes a line from the copied file;
    *   `-Agent agy` fails with the T0 reason, and `-Model auto` is refused;
    *   one read-only run in a repo with an `AGENTS.md`: no violation, and the file is back afterwards;
    *   one read-only run killed mid-run, followed by a `-Cleanup` that succeeds;
    *   one `council` run with `-Seat grok` and `-Seat glm`: no collision, and `-Cleanup` removes both worktrees;
    *   `runs.jsonl` lands in `%LOCALAPPDATA%\xagent\`, with the `feature` field when `-Feature` is given;
    *   the summary carries `baseSha`, and the pid file exists during the run and is gone after it;
    *   a worker started with `FOO_API_KEY` set does not see it (checked with a tiny task that prints its environment).
*   **`doctor`**: on this machine, it reports everything present. With the Cursor CLI renamed away, it reports it missing.
*   **End to end**: the manual CUJ 1–7 checklist in a sandbox from `scripts/new-sandbox.ps1`, in fresh sessions:
    *   CUJ 2 is run after `/clear`, with one worker process killed;
    *   CUJ 7 checks that "ok" does not pass a gate;
    *   G1 is verified by saying each entry-point phrase without naming the skill, and each "must not fire" phrase;
    *   saying "plan it" while in plan mode gets the request to leave plan mode.

--------------------------------------------------------------------------------

<!-- Provenance: Indicates initial structural drafting via EGM. -->

*Drafted with EGM*
