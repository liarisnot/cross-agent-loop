# Plan

Write the plan, import it, run the plan review, and record **plan-approved** only on a clear yes.

When this file applies: the stage is `plan`, the user asked to plan the feature, or the router sent you here to approve the plan or after going back to the plan.

`feature.ps1 <subcommand>` means `pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 <subcommand>`, and `delegate.ps1` means `pwsh -NoProfile -File <delegate dir>/scripts/delegate.ps1`. `<skill dir>`, `<delegate dir>`, `<repo>` and `<name>` are defined in SKILL.md. Every `feature.ps1` call passes `-Repo <repo> -Name <name>`.

## Write the plan

Write JSON matching `<skill dir>/schemas/plan.schema.json` to `<repo>/.xagent/features/<name>/plan-input.json`.

The plan has a `summary`, then `phases`, then each phase's `tasks`. Each phase has `n`, `rationale` and `test` (the phase test command). Each task has:

- `id`: the short task part, matching `^[a-z0-9][a-z0-9-]*$`, at most 20 characters. The script builds the `delegate` task id from it.
- `title`
- `dependsOn`: task ids
- `files`: files, folders (ending in `/`) or globs that the task may touch
- `test`: the exact, non-interactive test command. It runs only the tests for what this task changes (its test file, or a Pester filter on its `Describe` names), not the whole suite. The worker runs it as its acceptance command and `verify` runs it again.
- `profile`: `code` or `code-hard`
- `brief`: one paragraph, which the task file expands

`feature.ps1 plan` rejects the file unless the ids are unique and at most 20 characters, every `dependsOn` exists, there are no cycles, a dependency's phase is less than or equal to the task's phase, and `files` is non-empty. On `ok: false`, show `error`, fix the input file, and import again.

## Plan rules

- Every task is a worker task. Architecture is settled in the design. Cross-cutting changes become worker tasks with broad `files`.
- Steps that `delegate` never delegates (secrets, credentials, deploys) are listed in the plan summary as steps for the user. They are not tasks.
- The last phase's test is the full suite. Sign-off runs the same command.
- Every phase's test runs the full suite (or its fast subset). After the merge, it catches what the narrow task tests miss.
- **Aim for tasks of about 20 worker minutes or 600 lines of code and tests.** Past that, high-reasoning models (`code-hard`) slow down sharply: a 1,840-line `code-hard` task took about 44 minutes on 2026-11-14 (`docs/test-plan.md`). Split a big task along a seam where one task's output is a stable interface for the next (native layer, then the module functions that call it, then the integration), each with its own files and tests. Split rather than drop a `code-hard` task to a cheaper model. But size alone is not a reason to split: a cohesive unit whose halves cannot be tested apart (a harness and the one test that proves it) stays one task, even when big.
- **Plan later phases loosely.** Phase goals, tests and files are fixed at approval. Tasks in later phases may be rough; the lead refines and splits them in build within the phase's scope (`stages/build.md`, "Splitting a task in build"), without a new review or gate.
- Anything the design leaves for the worker to discover (undocumented platform behaviour, a protocol to probe) is a probe for the design stage, not part of a timed task.

## Import and check

1. Run `feature.ps1 plan -Repo <repo> -Name <name> -PlanFile <repo>/.xagent/features/<name>/plan-input.json`. It validates the plan, writes it into `feature.json`, generates `plan.md`, deletes the input file and commits. Read `phases` and `tasks`. `plan.md` is generated for the user to read. Do not edit it by hand.
2. Run the plan review like the design review in `stages/design-review.md`: runs from `status.reviewRuns`, task files, raw reports, cleanup, synthesis, and dismissals. Do not add lenses. `status.reviewRuns` is the whole list (comprehension and implementation readiness for a plan review).
   - Task file: `<repo>/.xagent/features/<name>/<id>.task.md`. Its target is `docs/features/<name>/plan.md`. Its GoldfishContext is the design doc, `<design doc>`.
   - For each run with `done: false`, follow the cap rule in SKILL.md, except the runs of a round the user declined: read the decisions (`git -C <repo> show feature/<name>:docs/features/<name>/decisions.md`) and skip every run of round `<n>` when a line contains `review plan-<n>: declined by the user`; then `delegate.ps1 -Agent cursor -Profile review -Persona <persona> -Model <model> -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <id> -TaskFile <task file>`. Pass `-Standard <standard>` only when `standard` is not null.
   - Copy `reviewFile` to `docs/features/<name>/reviews/raw/<id>.md`, run `feature.ps1 commit-records -Repo <repo> -Name <name> -Message "review: <id>"`, then `delegate.ps1 -Cleanup -Profile review -Repo <repo> -TaskId <id>`.
   - Synthesize into `docs/features/<name>/reviews/plan-<n>.md`, following `<skill dir>/egm/agents/synthesizer.md` the same way `stages/design-review.md` does. `<n>` is 1 plus the number of committed `reviews/plan-*.md` files. The report lists the raw files it was built from. Log every finding you leave out: `feature.ps1 decision -Repo <repo> -Name <name> -Kind dismiss -Text "<lens>: <finding> — <reason>"`. Commit the synthesis with `feature.ps1 commit-records -Repo <repo> -Name <name> -Message "review: plan-<n>"`.
   - A lens that ends without a report follows the failed-reviewer ladder in `stages/design-review.md`. A lens recorded as not run blocks **plan-approved** until it is rerun or waived.

**Declining another round.** When the user declines another review round, log it once: `feature.ps1 decision -Repo <repo> -Name <name> -Kind decision -Text "review plan-<n>: declined by the user"`, where `<n>` is the number of the round they declined (the `p<n>` in its run ids, counted from 1). It is `-Kind decision`, not `dismiss`: it is neither a waiver nor a stop. Do not log that round's lens runs one by one as not run: they never started. `status.reviewRuns` still lists them with `done: false`; after this decision, skip them. The not-run rule above applies only to a lens that started and ended without a report.

3. Triage the findings per `delegate`'s rule: fix what would make two workers build different things. Read `<delegate dir>/SKILL.md`, "Goldfish preflight & review", for that triage. Ignore pure over-specification.
4. To change the plan, write a new complete input file and import it again. Then review the new plan.

## Re-plan after going back

Already merged tasks stay in the plan, unchanged. Rework is added as new tasks with new ids. `plan` keeps the earlier `delegateTaskId` for any task already in `feature.json`. A re-plan must still contain every task that has an `Xagent-Task` trailer on `feature/<name>`, with every field equal. Removing merged code is itself a new task, or a hand edit by the user.

## Council

If the plan contains a choice that is hard to reverse or contested, offer a council as in SKILL.md under "On-request and design/plan councils". Run it only if the user agrees.

## Approve the plan

Ask for **plan-approved**. State that phase check-ins are off unless the user asks for them. An unclear reply gets one confirming question that names the gate (for example, "Approve the plan (plan-approved) and start building?"). Do not ask while any plan-review lens is not run and not waived.

On a clear yes:

1. Run `feature.ps1 gate -Repo <repo> -Name <name> -Gate plan-approved -Quote "<user words>" -Checkin on-problems`. If the user asked for check-ins, use `-Checkin every-phase` instead. Read `gate` and `sha`.
2. Run `feature.ps1 stage -Repo <repo> -Name <name> -To build`. Read `from` and `to`.

Tell the user the plan is approved and the next step is to build. Do not start building until they ask, or say continue.
