# `feature` skill: plain-language, feature-level development flow

*   **Author:** Eugene Chin
*   **Status:** Proposed
*   **Date:** 2026-11-09

--------------------------------------------------------------------------------

## Overview

`feature` is a Claude Code skill. It takes one feature from design to a merged branch. Claude Code is the lead programmer. Cursor and Antigravity workers do the coding through the existing `delegate` skill, and the user approves each major step.

The user drives it in plain language. "Start the design", "plan it", "build it", "continue" and "where are we?" each map to a stage. The skill keeps each feature's progress in a file in the repo, so the work survives context compaction and new Claude Code sessions.

Version 1 covers five stages plus a status query:

1. design
2. design review
3. plan
4. build
5. test and sign-off

For hard or contested problems, the skill can bring in a multi-model council (Claude, Grok and Gemini) at any stage. The design stages reuse the Elephant-Goldfish Model (EGM) workflow, copied into this repo per [decision 001](../decisions/001-vendor-egm-workflow.md). The build stage reuses `delegate.ps1`. Brainstorming and benchmark mode come later.

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
*   **G3. Recorded user gates.** The flow stops at four gates: design locked, plan approved, each build phase checked in, and final sign-off. It does not move past a gate until the user approves. Each approval is written to the feature's state with a timestamp.
*   **G4. Isolated build.** All code for a feature lands on one integration branch, `feature/<name>`. `main` changes only after the user signs off. Coding tasks go to Cursor or Antigravity workers through `delegate`. Claude reviews and merges, and does not write the feature code itself, except for small fix-ups it records.
*   **G5. Safe parallelism.** Two tasks run at the same time only if their declared file sets do not overlap and neither depends on the other. Otherwise they run one after another.
*   **G6. Final check against the design.** Before sign-off, the whole feature diff is checked against the locked design for missing, extra or changed behaviour, and the user sees the result.
*   **G7. Council on hard problems.** The skill brings in the existing multi-model council (`delegate`'s `council` profile: Grok via Cursor and Gemini Argon via agy, with Claude as lead) at three points. It is not a separate stage.
    *   **Design or plan:** the skill offers it for a decision that is hard to reverse or contested.
    *   **Build:** it convenes one automatically when a task fails review twice, or when a task is tagged `hard` in the plan.
    *   **Any stage:** it convenes one when the user asks.

    It does not convene one for routine work, because a council costs about 1–3 minutes plus frontier-model tokens on both subscriptions. Each council's outcome is recorded in the feature's decisions.

## Non-Goals

*   **Brainstorm stage.** Deferred. v1 starts from a problem statement the user gives in chat or from an existing brief.
*   **Benchmark mode inside `feature`.** Deferred. `delegate`'s own benchmark mode still works per task if the user turns it on.
*   **Cloud or remote agents.** Workers run locally through the `cursor-agent` and `agy` CLIs only, as `delegate` does today.
*   **macOS or Linux support.** v1 targets Windows and PowerShell 7, matching `delegate.ps1`.
*   **Several people on one feature.** One user and one lead session own a feature at a time. No locking between machines.
*   **Merging to `main` without the user.** The skill never merges to `main` or pushes without explicit sign-off.
*   **Replacing EGM's review content.** We reuse EGM's personas and standards. Changing how a goldfish reviews is out of scope. Where reviewers run (Claude or another vendor) is an open question.

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
    *   The skill writes a plan with phases and tasks. Each task has its dependencies, its declared file set, a test command and a profile (`code`, `code-hard`, or tagged `hard`).
    *   It runs a goldfish implementation-readiness check on the plan and fixes the findings.
    *   It asks for the plan-approval gate.
    *   It asks whether to check in after every phase. The default is to stop only on problems.
    *   On approval, it records the gate and moves to `build`.

### CUJ 5: Build a phase, with a council escalation

*   **Given**: The plan is approved. Phase 1 has tasks A and B, whose file sets don't overlap, and task C, which depends on A.
*   **When**: The user says "build it".
*   **Then**:
    *   The skill delegates A and B in parallel with `-Base feature/export`. It reviews each diff, merges the accepted work into `feature/export`, then delegates C.
    *   Suppose C fails review twice. The skill convenes a council on C's problem and records the outcome as a decision. Because an escalation is a problem, it then stops and shows the user the outcome and its proposed retry.
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
delegate.ps1  -->  Cursor / agy workers  (code, code-hard, review,
(existing)         in worktrees           review-strong, council profiles)
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
    *   `merge`: merge a task's branch, adding its `Xagent-Task` trailer.
    *   `decision`: append to the decision log.
    *   `wait`: record what the flow is waiting on.
    *   `checkin`: set the check-in mode.
    *   `promote`: make a side feature the main-mode feature.
    *   `finish`: merge the feature into `main` after sign-off.

    The full interface is in the Detailed Implementation Plan.
*   **Vendored EGM (`skills/feature/egm/`).** A copy of the EGM skill text, personas and standards that our stages use, pinned and kept in sync per [decision 001](../decisions/001-vendor-egm-workflow.md).
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

### Main mode and side mode

*   **Main mode (default).** `feature.ps1 new` refuses if the working tree has uncommitted changes, so the user commits or stashes first. Otherwise it runs `git switch -c feature/<name> main` in the user's repo folder. Only one feature can be in main mode at a time.
*   **Side mode (on request: "side feature", "try this in a worktree").** `feature.ps1 new -Side` runs `git worktree add <repo>.xagent/_feature-<name> -b feature/<name> main`. The `_` prefix cannot collide with a `delegate` task id, because task ids allow only `[a-z0-9-]`. The user can continue from the same session (naming the feature) or open a second Claude Code session in that folder.
    *   A side feature can be promoted to main mode later. The worktree is removed, and the user's checkout switches to the branch.
*   **In both modes:**
    *   Local state lives in the main repo's `.xagent/features/<name>/`.
    *   Workers are launched with `-Repo <main repo> -Base feature/<name>`, so worker worktrees and run logs stay in one place.
    *   The lead merges worker branches in whichever folder has `feature/<name>` checked out.
*   **Overlap warning.** At plan approval, the skill warns if the plan's declared files overlap another in-progress feature's files, since the second one to reach `main` would conflict.

### State model (split: committed records plus local runtime state)

Committed on `feature/<name>`, in `docs/features/<name>/`:

*   `feature.json`: name, mode, base, stage, check-in mode, path to the design doc, gates (each with a timestamp and the user's quote), and the plan's phases and tasks (id, title, depends-on, declared files, test command, profile, `hard` tag). The script is the only writer.
*   `plan.md`: the plan as the user reviews it, in prose plus a task table generated from `feature.json`.
*   `decisions.md`: an append-only log of decisions, gate approvals, council outcomes, scope changes and moves back to an earlier stage.

The design doc itself is `docs/designs/<name>.md` on the branch. It is drafted in place with `Status: Draft` and committed after each approved section.

Local, in `<main repo>/.xagent/features/<name>/state.json` (git-excluded):

*   For each task: status (`pending`, `running`, `in-review`, `merged`, `failed`, `escalated`), worker vendor, delegate task id, session id, review round, worktree path, and last result file.
*   For the feature: the worktree path in side mode, the time of the last reconcile, and what the flow is waiting for (`user:<gate>`, `user:problem`, `worker:<task>`, or nothing).

### Reconcile rules (resolves Q2)

`feature.ps1 reconcile` runs at the start of every invocation. Git wins for the facts it can prove. Local-only fields are kept. The script stops and asks only on a real contradiction.

| Fact | Source | Rule |
|---|---|---|
| Feature branch exists | git | Missing branch while the stage is not `done`/`abandoned` → **contradiction, ask** |
| Task merged | git: a merge commit on `feature/<name>` with trailer `Xagent-Task: <id>` | Found → mark `merged`, even if local said otherwise (absorbs manual merges that keep the trailer) |
| Task merged per local state, no trailer commit found | — | **contradiction, ask** |
| Feature merged into `main` | git: `feature/<name>` is an ancestor of `main` | Mark `done` if `signed-off` is recorded. Without that gate → **contradiction, ask** |
| Gates, stage, plan | committed `feature.json` | Always taken from the committed copy |
| Review rounds, session ids, waiting-on | local only | Kept. If the local file is missing, reset to defaults and report what was lost |

All worker merges into a feature branch use `git merge --no-ff` with the trailer, so task completion can be proven from history after `delegate -Cleanup` deletes the task branch.

### Build scheduling

*   **Task ids** are `<feature>-<task>`, shortened to fit `delegate`'s 49-character limit.
*   **Ready tasks.** A task is ready when all of its `depends-on` tasks are merged. `feature.ps1 schedule` returns the ready tasks of the current phase that can start now. A task can start only if its declared files overlap no running task's declared files. Two paths overlap when they are equal or one is a parent folder of the other.
*   **At most 2 workers at a time.** This keeps load on the two $20 subscriptions predictable.
*   **Vendor choice (by kind, then balance).**
    *   **Kind.** Each task in the plan has a `kind`: `ui`, `impl`, `test`, `migration`, `mechanical` or `explore`.
    *   **Kind table.** `skills/feature/routing.json` maps `ui` and `impl` to Cursor and the other kinds to agy. The table is a starting guess, to be revised once benchmark data exists.
    *   **Balance.** `feature.ps1 plan` assigns vendors from the table. If one vendor then has more than 60% of a phase's worker tasks, it moves `impl` tasks to the other vendor, in plan order, until the share is at or below 60% or no `impl` tasks are left.
    *   **Visible in the plan.** The vendor is written into the plan, so the user sees and can change it before **plan-approved**.
    *   **Quota switch.** A quota limit during the build switches that task to the other vendor, and the switch is logged as a decision.
*   **Profile.** Each task starts on the profile the plan gives it.
*   **Preflight models.**
    *   **Comprehension** runs on the same vendor and the same model as the assigned worker (for example Composer 2.5 for a Cursor `code` task, Grok 4.7 medium for a Cursor `code-hard` task). If the worker misreads the task, this reviewer should too.
    *   **Implementation readiness** runs on the other vendor.
    *   **After a vendor switch,** the comprehension preflight runs again on the new worker's model.
*   **Scope check.** After each worker run, the lead compares the worker's changed files against the task's declared files. A change outside them is a problem stop.
*   **Merge.** Each task is reviewed and merged per `delegate`'s loop. A phase ends when all its tasks are merged and the phase test command passes on `feature/<name>`.
*   **Problem stops.** In `on-problems` mode (the default), the build runs through phases without stopping, except for:
    *   a council escalation
    *   a test failure on `feature/<name>` that the lead cannot fix in one small fix-up
    *   a change outside the declared files
    *   a needed change to the plan or the design
    *   a worker quota limit on both vendors
*   **Check-in mode.** In `every-phase` mode, it also stops after each phase. The user turns this mode on explicitly, at plan approval or during the build, and the skill never switches to it by itself.
*   **Fix-ups.** Small fixes by the lead during merge are allowed and logged in `decisions.md`, as G4 requires.

### Council (G7)

*   **Design and plan.** When the lead faces a choice that is hard to reverse or contested, it offers a council and runs one only if the user agrees.
*   **Build.** A task that fails review twice, or is tagged `hard` and fails review once, triggers a council automatically. The council uses `delegate`'s council procedure. The outcome is appended to `decisions.md`, and the build makes a problem stop showing the outcome and the proposed retry (with the `code-hard` profile and the council's guidance).
*   **On request.** At any stage, the user can ask for a council.

### Goldfish review routing (resolves Q3)

All goldfish are non-Claude, so the reviewer is always a different vendor from the author (the Claude lead).

| Lens | Tier | Profile | Why |
|---|---|---|---|
| comprehension, implementation_readiness | worker tier (Composer 2.5, Gemini Flash) | `review` (existing) | Same tier as the workers who will read the tasks. If they misread, a worker will too. |
| zoom_out, design_critic, inventive_catalyst, codebase_details, structural, style | strong tier (Grok 4.7 high, Gemini Argon high) | `review-strong` (new) | Needs judgement about architecture and hidden complexity. |

*   **Vendor per lens.** Within a tier, lenses are split between Cursor and agy so both vendors review each document.
*   **Diff reviews.** Reviews of a diff keep `delegate`'s rule: the reviewer is the other vendor from the worker that wrote the code.
*   **Report format.** Findings use `review.schema.json` (Blocker/Major/Nit). The lead does the synthesis EGM's synthesizer would do, deduplicating and ranking findings into one report at `docs/features/<name>/reviews/<stage>-<n>.md`.

### EGM integration

*   **Vendored copy.** The design and design-review stage files tell the lead to read and follow the vendored EGM `egm-draft`, `egm-review` and `egm-resolve` text in `skills/feature/egm/`. They also list where our flow differs from it:
    *   where EGM spawns a Claude reviewer agent, run `delegate.ps1` with the profile and persona from the routing table above;
    *   where EGM writes `design_draft.md`, write to `docs/designs/<name>.md`;
    *   EGM's question gates map to our gate recording.
*   **Unmodified text.** The vendored text stays unmodified. All differences live in our stage files, per decision 001.
*   **Sync.** `scripts/egm-sync.ps1` diffs upstream EGM from the pinned commit for the vendored paths and copies unchanged files.

### Sign-off and final check (G6)

1.  Run the repo's full test command on `feature/<name>`.
2.  Run the final check, a judgement-tier goldfish:
    *   **`design_critic`** gets the locked design plus the diff from `main` to `feature/<name>`. For a large diff, it gets one file group per run.
    *   **The vendored `egm-drift-report` procedure** lists behaviour that is missing from the code, added beyond the design, or changed from it.
3.  Show the results and ask for the **signed-off** gate.
4.  On approval, run `git switch main` and `git merge --no-ff feature/<name>` in the main checkout. In side mode the worktree is removed first. Then mark the feature `done`. Pushing happens only if the user asks.

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

### Alternative F: Only one working place for the lead

*   **Always switch the main checkout**: Rejected by author. Side work, or a quick experiment, would be blocked while a major feature is in progress.
*   **Always a worktree per feature**: Rejected by author. To try a major feature, the user would have to open a different folder, and the checked-out branch could no longer pick the active feature.
*   **Chosen instead**: Main mode by default, and side mode (a worktree) on request.

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

--------------------------------------------------------------------------------

## Non-Functional Requirements

*   **Quota.** Claude runs only the lead. Workers, goldfish and councils run on Cursor and Google. The cost added per feature is about one goldfish review of the design (7 lens runs), one of the plan (2 runs), one final check, plus any councils. At most 2 workers run at once.
*   **Safety.**
    *   The skill never merges to `main` or pushes without the **signed-off** gate.
    *   `feature.ps1` refuses to start a feature on a dirty working tree, and never runs `git reset --hard`, `git clean`, or a force push.
    *   Worker permissions are unchanged from `delegate`.
*   **Isolation risk (accepted).** Cross-vendor goldfish load their own CLI's project rules (`AGENTS.md`, `.cursor/rules`), so their context is less isolated than EGM's Claude adapters. Each persona prompt tells the reviewer to judge only the given document.
*   **Rollback.**
    *   Abandoning a feature leaves `main` untouched. The branch and records stay until the user deletes them.
    *   Removing the skill means deleting the `~/.claude/skills/feature` junction. `delegate` keeps working on its own.

--------------------------------------------------------------------------------

### Future Improvements

*   **Brainstorm stage**: put the vendored `egm-brainstorm` in front of `design`, with an optional council.
*   **Benchmark mode per feature**: run `delegate`'s head-to-head benchmark on the tasks of a feature.
*   **Cost report per feature**: split API spend from subscription use (the kodo idea), using `benchmarks/runs.jsonl`.
*   **Anonymized peer review in the council** (the epicsagas idea).
*   **Data-driven routing**: revise `routing.json`'s kind table from benchmark results, once benchmark mode has real tasks.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Names used below: `<repo>` is the main checkout of the target repo, `<name>` is the feature name, and `<fdir>` is the folder that has `feature/<name>` checked out (`<repo>` in main mode, `<repo>.xagent/_feature-<name>` in side mode).

### Target Files to Create/Modify

#### 1. `skills/feature/SKILL.md` (Create)

*   **Type / Scope**: Claude Code skill, the router. It is model-invocable, so it must not set `disable-model-invocation`.
*   **Proposed Changes**:
    *   **Frontmatter `description`**:
        *   It names the trigger: a request to design, review the design of, plan, build, continue, test, sign off, abandon, or check the status of a feature in this repo.
        *   It lists example phrases: "design a feature for X", "review the design", "plan it", "build it", "continue", "where are we?", "side feature: X", "sign off".
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
    *   If no feature exists, call `feature.ps1 new` (`-Side` when the user asked for a side feature). Ask for a name if none can be derived. Names are lowercase kebab-case of at most 31 characters.
    *   Then read and follow `skills/feature/egm/skills/egm-draft/SKILL.md`, applying these differences:
        *   Write to `docs/designs/<name>.md` in `<fdir>`, not to `design_draft.md`.
        *   Commit after each approved section, with the message `feature(<name>): design – <section>`.
        *   Skip EGM Step 6.2 (picking the target folder).
        *   If the problem statement is missing, ask for it in chat. Don't point to `egm-brainstorm`.
    *   When all sections are approved, run `feature.ps1 stage -To design-review`.

#### 3. `skills/feature/stages/design-review.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    *   Read and follow the vendored `egm-review` SKILL.md, then the vendored `egm-resolve` SKILL.md. Where `egm-review` invokes `egm-review-loop`, read the vendored copy of that too. Apply these differences:
        *   **Reviewer runs.** Instead of spawning `egm:*` agents, run `delegate.ps1 -Profile <review|review-strong> -Persona <lens> -Agent <cursor|agy>`. Use the lens-to-tier table and alternate vendors within each tier. The task file is the design doc, plus the `GoldfishContext` EGM would pass.
        *   **Synthesis.** The lead does the synthesizer's job, following `egm/agents/synthesizer.md`. It writes `docs/features/<name>/reviews/design-<n>.md`.
        *   **Checkpoints.** The stage checkpoints in EGM become chat questions. They are not recorded gates.
    *   After resolution, ask for **design-locked**. On a clear yes:
        1.  Run `feature.ps1 gate -Gate design-locked -Quote "<user words>"`.
        2.  Set the design doc's `Status:` to `Approved`.
        3.  Run `feature.ps1 stage -To plan`.

#### 4. `skills/feature/stages/plan.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    *   **Write the plan.** Produce a plan JSON file in `<repo>/.xagent/features/<name>/plan.json`, matching `plan.schema.json`. It is split into phases, and each task has:
        *   an id
        *   a title
        *   `dependsOn`
        *   `files`: the files and folders it may touch
        *   `test`: the exact test command
        *   `profile`: `code` or `code-hard`
        *   `kind`: `ui`, `impl`, `test`, `migration`, `mechanical` or `explore`
        *   `hard`: true or false
        *   `brief`: one paragraph the task file will expand
    *   **Plan rules.** Architecture, cross-cutting and security-sensitive work is assigned to `lead`, which means the lead does it, not a worker. Each phase has a phase test command, and the last phase's test is the full suite.
    *   **Import and check it.**
        1.  Run `feature.ps1 plan -PlanFile <path>`. It validates the plan and writes `feature.json`, `plan.md` and `decisions.md`.
        2.  Run the plan goldfish: `comprehension` and `implementation_readiness` on `plan.md`, with the worker tier on both vendors.
        3.  Triage the findings per `delegate`'s rule (fix what would make two workers build different things).
        4.  Re-import the fixed plan.
    *   **Offer a council** if the plan contains a choice that is hard to reverse.
    *   **Approve.**
        *   Show the overlap warnings from `feature.ps1 plan`'s output.
        *   Ask for **plan-approved**, stating that the check-in mode is `on-problems` unless the user says "check in every phase".
        *   On a clear yes, run `feature.ps1 gate -Gate plan-approved -Quote ... -Checkin <mode>`, then `stage -To build`.

#### 5. `skills/feature/stages/build.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**: a loop.
    *   **Pick tasks.** `feature.ps1 schedule` returns the ready tasks.
    *   **Run each task.** For each ready task:
        1.  Write the task file `<repo>/.xagent/tasks/<taskId>.md` from its brief, using `delegate`'s task-file format.
        2.  Run the goldfish preflight on the task file if `delegate`'s rules call for it:
            *   `comprehension` with `-Agent <task vendor> -Model <the worker's model for the task's profile>`;
            *   `implementation_readiness` on the other vendor.
        3.  Run `feature.ps1 task -Status running`.
        4.  Run `delegate.ps1 -Agent <task vendor> -Repo <repo> -Base feature/<name> -TaskId <taskId> -Profile <profile>`, with both ready tasks in the same message when two are ready.
    *   **Quota limit.** If a worker reports one:
        1.  Run `feature.ps1 task -Vendor <other>`.
        2.  Log it with `feature.ps1 decision -Kind decision`.
        3.  Rerun the comprehension preflight on the new model.
        4.  Run the task again on the other vendor.
        5.  If both vendors hit their limit, make a problem stop.
    *   **Review** per `delegate`'s loop, and update `task -Round <n>` each round.
    *   **Scope check.** If the worker changed files outside the task's `files`, that's a problem stop.
    *   **Council escalation.** Two failed rounds, or one failed round on a task with `hard: true`, triggers the council per `delegate`'s procedure:
        1.  Append the outcome to `decisions.md` (`feature.ps1 decision`).
        2.  Run `task -Status escalated`.
        3.  Make a problem stop.
    *   **Merge.** On accept:
        1.  Commit in the worker worktree.
        2.  Run `feature.ps1 merge -Task <id> -Message "<msg>"`.
        3.  Run `delegate -Cleanup`.
    *   **Phase end.** When all tasks of a phase are merged:
        1.  Run the phase test in `<fdir>`. Fix it if the fix is small (logged as a fix-up decision). Otherwise make a problem stop.
        2.  If the check-in mode is `every-phase`, report and stop.
        3.  Otherwise, continue to the next phase.
    *   **End of build.** When the last phase is done, run `stage -To signoff` and report.
    *   **Problem stop.** Defined as: run `feature.ps1 wait -On user:problem -Note "<why>"`, report to the user, and end the turn.

#### 6. `skills/feature/stages/signoff.md` (Create)

*   **Type / Scope**: Stage instructions.
*   **Proposed Changes**:
    1.  Run the full test command in `<fdir>`.
    2.  Build the final-check input:
        *   the locked design
        *   `git diff main...feature/<name>`
        *   if the diff is over 1,500 lines, one input per file group, as declared in the plan phases
    3.  Run `design_critic` with `review-strong` on one vendor. Run the vendored `egm-drift-report` procedure with the lead as the reader.
    4.  Show the test results and the findings, grouped as missing, added or changed behaviour.
    5.  Ask for **signed-off**. On a clear yes:
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
        *   Record commits are made in `<fdir>`. Each commit stages only the files under `docs/features/<name>/`, or the design doc for `design` commits.

    | Subcommand | Arguments | Behaviour |
    |---|---|---|
    | `new` | `-Name`, `-Side` | Fail if the working tree is dirty, the branch exists, or (main mode) another main-mode feature is not `done`/`abandoned`. Main mode: `git switch -c feature/<name> main`. Side mode: `git worktree add <repo>.xagent/_feature-<name> -b feature/<name> main`. Write `feature.json` (stage `design`, mode, `checkin: on-problems`) and `decisions.md`, and commit `feature(<name>): start`. Write the local `state.json`. |
    | `status` | `[-Name]`, `-Cwd` | Without `-Name`, apply the selection rules. Rule 2 reads `git -C <Cwd> branch --show-current`. Rule 3 scans `.xagent/features/*/state.json` plus branches `feature/*` whose stage is not `done`/`abandoned`. Output the selected feature's merged view (committed plus local) with `nextAction`, or `{selected:null, features:[...]}`. |
    | `reconcile` | `-Name` | Apply the reconcile table. Output `{changes:[], contradictions:[], lost:[]}`. Contradictions don't change anything. |
    | `stage` | `-Name`, `-To`, `-Reason` | Forward moves are allowed only one step at a time, and only when the gate is recorded. Backward moves are allowed to any earlier stage: they clear later gates and append a decision. `abandoned` is allowed from any stage. Commit. |
    | `gate` | `-Name`, `-Gate`, `-Quote`, `[-Checkin]` | The gate must match the current stage (`design-review` → `design-locked`, `plan` → `plan-approved`, `signoff` → `signed-off`). Record `{at, quote}`, append a decision and commit. `-Checkin` is allowed only with `plan-approved`. |
    | `plan` | `-Name`, `-PlanFile` | Validate against `plan.schema.json`: unique ids, existing `dependsOn`, no cycles, a dependency's phase ≤ the task's phase, non-empty `files`, `taskId` ≤ 49 characters. Assign `vendor` to each worker task from `routing.json` (unless the plan sets `vendor` explicitly, which the user can ask for), then apply the 60% balance rule for each phase, moving `impl` tasks in plan order. Write the phases into `feature.json` and regenerate the table in `plan.md` between `<!-- tasks:begin -->` and `<!-- tasks:end -->`. Compute overlap warnings against other in-progress features' `files`. Commit. Allowed only in stage `plan`. |
    | `schedule` | `-Name` | From the current phase (the lowest phase with tasks not yet merged), return tasks that are `pending`, have every dependency `merged`, and whose files overlap no `running`/`in-review` task. Cap the total of running plus in-review tasks at 2. Tasks with `profile: lead` are returned with `assignee: lead`. Each worker task includes its `vendor` and the worker `model` for its profile, read from `delegate`'s `models.json`. |
    | `task` | `-Name`, `-Task`, `[-Status] [-Vendor] [-DelegateTaskId] [-SessionId] [-Round] [-ResultFile]` | Update local `state.json` only. |
    | `merge` | `-Name`, `-Task`, `-Message` | In `<fdir>`: `git merge --no-ff xagent/<delegateTaskId>` with the message `<Message>` plus a blank line plus `Xagent-Task: <task id>`. On conflict, run `git merge --abort` and fail with the conflicting files. On success, set the task to `merged`. |
    | `decision` | `-Name`, `-Kind`, `-Text` | Append `- <ISO time> [<kind>] <text>` to `decisions.md` and commit. Kinds: `decision`, `council`, `fix-up`, `scope`, `gate`, `stage`. |
    | `wait` | `-Name`, `-On`, `[-Note]` | Set the local `waitingOn`. `-On none` clears it. |
    | `checkin` | `-Name`, `-Mode` | Set `on-problems` or `every-phase` in `feature.json`, append a decision and commit. |
    | `promote` | `-Name` | Side to main. Fail if another main-mode feature is active or the main checkout is dirty. Remove the side worktree (fail if it is dirty), `git switch feature/<name>` in `<repo>`, and set the mode to main. |
    | `finish` | `-Name` | Require `signed-off`. Side mode: remove the worktree. In `<repo>`: `git switch main` and `git merge --no-ff feature/<name> -m "Merge feature/<name>"`. Set the stage to `done` and commit the final `feature.json` on `main`. Never push. |

    *   **Path overlap.** Normalize both paths (forward slashes, no trailing slash, lowercase on Windows). They overlap if they are equal or one starts with the other plus `/`.

#### 9. `skills/feature/feature.schema.json` and `skills/feature/plan.schema.json` (Create)

*   **Type / Scope**: JSON Schemas.
*   **Proposed Changes**:
    *   **`feature.json` fields**:
        *   `name`, `mode` (`main`|`side`), `stage` (`design`|`design-review`|`plan`|`build`|`signoff`|`done`|`abandoned`)
        *   `checkin` (`on-problems`|`every-phase`), `designDoc`
        *   `gates`: an object keyed by the gate name, each holding `{at, quote}`
        *   `phases`: an array of `{n, test, tasks:[task]}`
    *   **`plan.json` task fields**: `id`, `title`, `dependsOn`, `files`, `test`, `profile` (`code`|`code-hard`|`lead`), `kind` (`ui`|`impl`|`test`|`migration`|`mechanical`|`explore`), `hard`, `brief`, and an optional `vendor` (`cursor`|`agy`) that overrides the table.
    *   **`feature.json` task fields**: every task field, with `vendor` always filled in for worker tasks.

#### 10. `skills/feature/state.schema.json` (Create)

*   **Type / Scope**: JSON Schema for the local `state.json`.
*   **Proposed Changes**:
    *   `name`, `fdir`, `lastReconcile`, `waitingOn`, `waitingNote`
    *   `tasks`: keyed by task id, each holding `status`, `vendor`, `delegateTaskId`, `sessionId`, `round`, `resultFile`

#### 10b. `skills/feature/routing.json` (Create)

*   **Type / Scope**: Vendor routing config.
*   **Proposed Changes**:
    *   `kinds`: `{ui: cursor, impl: cursor, test: agy, migration: agy, mechanical: agy, explore: agy}`
    *   `maxShare: 0.6`
    *   `rebalanceKind: impl`
    *   `_comment`: the table is a guess and should be revised from benchmark data.

#### 11. `skills/feature/templates/decisions.md` and `skills/feature/templates/plan.md` (Create)

*   **Type / Scope**: Templates that `feature.ps1 new` and `plan` copy.
*   **Proposed Changes**:
    *   `decisions.md` has a header and an empty log.
    *   `plan.md` has a header, a placeholder for the lead's prose, and the task-table markers.

#### 12. `skills/feature/egm/` (Create, vendored, unmodified)

*   **Type / Scope**: A copy of upstream EGM at commit `b7d9e27`. The upstream relative paths are kept, so diffing is direct.
*   **Proposed Changes**: Copy these files:
    *   `skills/egm-draft/SKILL.md` and `skills/egm-draft/references/design_doc.md`
    *   `skills/egm-review/SKILL.md`, `skills/egm-resolve/SKILL.md`, `skills/egm-review-loop/SKILL.md`, `skills/egm-drift-report/SKILL.md`
    *   `resources/execution_instructions.md` and `resources/document_standards/*.md` (5 files)
    *   `agents/synthesizer.md`
    *   `LICENSE` (as `LICENSE-egm`)

#### 13. `skills/feature/egm/MANIFEST.json` (Create)

*   **Type / Scope**: The sync manifest.
*   **Proposed Changes**:
    *   `upstream`: the repo URL.
    *   `pinnedCommit`: `b7d9e27`.
    *   `files`: a list of `{upstream, local, modified:false}`. It covers items 12 and 14, including the personas that live under `skills/delegate/personas/`.

#### 14. `skills/delegate/personas/` (Modify: add files)

*   **Type / Scope**: Goldfish personas run by `delegate.ps1`. Keeping one copy here avoids duplicating persona files between the skills.
*   **Proposed Changes**:
    *   Add the unmodified upstream `zoom_out.md`, `inventive_catalyst.md`, `codebase_details.md`, `structural.md`, `style.md` and `zoom-out-standard.md`.
    *   Add `standards.json`, which maps each persona to the standard file appended to it: `implementation_readiness` → `implementation-readiness-standard.md`, `zoom_out` → `zoom-out-standard.md`.
    *   Update `README.md`.

#### 15. `skills/delegate/scripts/delegate.ps1` (Modify)

*   **Type / Scope**: Worker launcher.
*   **Proposed Changes**:
    *   Add `review-strong` to the `-Profile` ValidateSet.
    *   Treat `review-strong` exactly like `review` (read-only, needs `-Persona`, writes `reviewFile`).
    *   Replace the hard-coded `implementation_readiness` standard injection with a lookup in `personas/standards.json`.
    *   Make no other behaviour changes.

#### 16. `skills/delegate/models.json` (Modify)

*   **Type / Scope**: Model profiles.
*   **Proposed Changes**: Add the `review-strong` profile:
    *   `readOnly: true`
    *   `cursor: grok-4.7-high`, `agy: gemini-4-argon-high`
    *   purpose: "Read-only goldfish review needing judgement (zoom-out, design critic, etc.)".

#### 17. `skills/delegate/SKILL.md` (Modify)

*   **Type / Scope**: Docs.
*   **Proposed Changes**:
    *   Document `review-strong` in the profile table.
    *   Note that `feature` uses `delegate` and merges with the `Xagent-Task` trailer.
    *   Add the `-Base feature/<name>` usage.

#### 18. `scripts/egm-sync.ps1` (Create)

*   **Type / Scope**: Maintenance script.
*   **Proposed Changes**:
    *   **Parameters**: `-Upstream <path to a local clone of EGM>` and `-Apply`.
    *   **Comparison.** For each manifest entry, compare upstream at `pinnedCommit` and at HEAD.
    *   **Report.** Print JSON listing `unchanged`, `changedUpstream`, `modifiedLocally`, `conflict` (changed upstream and modified locally) and `newUpstreamFiles` (new files in the vendored folders).
    *   **`-Apply`.**
        1.  Copy the `changedUpstream` files that are not modified locally.
        2.  Update `pinnedCommit` in the manifest and `THIRD_PARTY_NOTICES.md`.
        3.  Print the conflicts, which are left for a hand merge.

#### 19. `skills/feature/tests/feature.Tests.ps1` (Create)

*   **Type / Scope**: Pester 5 tests. The file starts with `#Requires -Modules @{ModuleName='Pester';ModuleVersion='5.0'}`. Each test builds a throwaway repo in `$TestDrive` with a `main` commit and calls `feature.ps1` as a child process, checking its JSON.
*   **Proposed Changes**: These cases:
    *   **`new`**:
        *   refuses a dirty tree
        *   refuses a bad name
        *   refuses a second main-mode feature
        *   main mode creates the branch and commit
        *   side mode creates the worktree at the `_feature-` path
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
        *   regenerates the table between the markers
        *   assigns vendors from the kind table
        *   keeps an explicit `vendor`
        *   rebalances a phase at 4 of 5 `impl` tasks (80%), so Cursor ends at or below 60%
        *   leaves a phase alone when there are no `impl` tasks to move
        *   reports an overlap with another feature
    *   **`schedule`**:
        *   dependency gating
        *   exact-path overlap
        *   parent-folder overlap
        *   the cap of 2
        *   `lead` tasks returned with `assignee: lead`
        *   returned tasks include `vendor` and the profile's worker `model`
        *   phase advance
    *   **`merge` and `reconcile`**:
        *   a trailer merge is marked merged after the task branch is deleted
        *   a manual merge with the trailer is absorbed
        *   local `merged` without a trailer is a contradiction
        *   a missing branch is a contradiction
        *   a feature merged to `main` without `signed-off` is a contradiction
        *   a missing local file is rebuilt and the losses are reported
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
    *   Mention the manifest and the sync script.

#### 22. `docs/decisions/001-vendor-egm-workflow.md` (Modify)

*   **Type / Scope**: Decision record.
*   **Proposed Changes**: Record the final layout:
    *   the workflow text in `skills/feature/egm/`
    *   the personas in `skills/delegate/personas/`
    *   the manifest
    *   the sync script path `scripts/egm-sync.ps1`

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

1.  **delegate changes** (items 14–17), with the existing `delegate` checks re-run.
2.  **`feature.ps1`, its schemas, templates and routing config, and the Pester tests** (items 8–11, 10b and 19). These are written test-first.
3.  **Vendored EGM, the manifest and the sync script** (items 12, 13, 18 and 21).
4.  **The router and stage files** (items 1–7).
5.  **Docs and machine setup** (items 20 and 22–25).
6.  **The manual CUJ checklist** on `sandbox`.

Steps 2 and 3 do not share files and can be delegated in parallel. Step 4 is written by the lead, because it is prompt design.

### Verification Plan

*   **Unit tests**: `pwsh -NoProfile -c "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester skills/feature/tests -Output Detailed"`. All cases in item 19 pass.
*   **delegate regression**: re-run the `delegate` checks in `docs/test-plan.md` that touch profiles and personas. Add one `review-strong` run on each vendor.
*   **Sync script**: run `egm-sync.ps1` against a local EGM clone at the pinned commit (expect all `unchanged`), then with one file edited locally (expect `modifiedLocally`).
*   **End to end**: the manual CUJ 1–7 checklist on the `sandbox` repo, in fresh sessions:
    *   CUJ 2 is run after `/clear`.
    *   CUJ 7 checks that "ok" does not pass a gate.
    *   G1 is verified by saying each phrase without naming the skill.

--------------------------------------------------------------------------------

<!-- Provenance: Indicates initial structural drafting via EGM. -->

*Drafted with EGM*
