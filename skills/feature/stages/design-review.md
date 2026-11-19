# Design review

Run the goldfish review, resolve the findings, and record **design-locked** only on a clear yes.

When this file applies: the stage is `design-review`, the user asked to review the design, or the router sent you here to lock the design or after going back to the design.

`feature.ps1 <subcommand>` means `pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 <subcommand>`, and `delegate.ps1` means `pwsh -NoProfile -File <delegate dir>/scripts/delegate.ps1`. `<skill dir>`, `<delegate dir>`, `<repo>` and `<name>` are defined in SKILL.md. Every `feature.ps1` call passes `-Repo <repo> -Name <name>`.

## Review

Read and follow `<skill dir>/egm/skills/egm-review/SKILL.md`, `<skill dir>/egm/skills/egm-review-loop/SKILL.md` and `<skill dir>/egm/skills/egm-resolve/SKILL.md`, with these differences.

Where those files spawn a Claude reviewer, or an `egm:*` agent, do not spawn one. Run `delegate.ps1` with the model from `status.reviewRuns`, as below. Where they write `design_draft.md`, the design doc is `<design doc>`. Their question gates map to this skill's recorded gates. The only recorded gate in this stage is **design-locked**.

Use each run's `model` as `status` gives it. Do not swap models except in [Failed reviewers](#failed-reviewers).

### Reviewer runs

Run `feature.ps1 status -Repo <repo> -Name <name>` and read `reviewRuns`. Each run has `id`, `phase`, `persona`, `model`, `standard` and `done`. Do not invent runs. On resume, the runs with `done: false` are still to do, except the runs of a round the user declined: read the decisions (`git -C <repo> show feature/<name>:docs/features/<name>/decisions.md`) and skip every run of round `<n>` when a line contains `review design-<n>: declined by the user`. Continue from the first run left.

For each run that is not done, follow the cap rule in SKILL.md. Start as many of those runs as that rule allows, in one message. For each:

```text
delegate.ps1 -Agent cursor -Profile review -Persona <persona> -Model <model> -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <id> -TaskFile <task file>
```

Pass `-Standard <standard>` on that command only when `standard` is not null. `-Persona` is the persona name. `-Standard` is a file name in `<delegate dir>/personas/`.

A failed run (`ok: false` or `timedOut: true`) follows "Failed delegate.ps1 runs" in SKILL.md: read `stderrTail`, retry once with the same command, and do not pass `-Resume` after a timeout. If `error` starts with `sandbox:`, do not retry: it is a sandbox setup problem. Report it to the user; it is a problem stop at once, handled like a usage limit. Then follow [Failed reviewers](#failed-reviewers). A usage-limit message is a problem stop at once.

### Task file

Write `<repo>/.xagent/features/<name>/<id>.task.md`. It names the design doc's path and line range (`<design doc>` is committed, so the worktree has it) and the GoldfishContext list. The reviewer reads both with its file tools.

GoldfishContext is the reading list besides the target: the repository files the design links to, plus any you name. It is plain text, not a schema field. Reviewers cannot open URLs, so save a web page as a file first. Example:

```text
GoldfishContext (read-only):
- skills/delegate/SKILL.md
- skills/delegate/scripts/delegate.ps1
- docs/decisions/001-vendor-egm-workflow.md
```

### Raw reports

Copy each `reviewFile` to `docs/features/<name>/reviews/raw/<id>.md`. Commit that raw report before you synthesize:

```text
feature.ps1 commit-records -Repo <repo> -Name <name> -Message "review: <id>"
```

Read `commit`. Then:

```text
delegate.ps1 -Cleanup -Profile review -Repo <repo> -TaskId <id>
```

A lens is done when `reviews/raw/<id>.md` is committed (`reviewRuns[].done` is true).

### Re-audit

After "update the doc first", run `feature.ps1 reaudit -Repo <repo> -Name <name> -Phase <egm phase>`. `<egm phase>` is that phase's number from `reviewRuns`: 5 initial zoom out, 6 comprehension, 7 critic, 8 intermediate zoom out, 9 implementation readiness. This adds that phase's runs again with an `-r<k>` suffix. Each re-audit reruns that phase's lenses once. Run `feature.ps1 status -Repo <repo> -Name <name>` and continue from the first new run with `done: false`.

To re-check one phase after a round's synthesis is committed, run `reaudit` for that phase: the new round then lists only that phase's runs.

### Synthesis

Write the synthesis once per round, after the round's last phase and its re-audits are done. A stage checkpoint (5, 6 or 8) is reported in chat; it does not get a synthesis file, because committing one starts the next round.

You do the synthesizer's job. Read and follow `<skill dir>/egm/agents/synthesizer.md` for how to deduplicate and rank findings. Do not spawn the subagents it describes. The lens runs already happened through `delegate.ps1`.

Reviewers return Markdown with Blocker, Major and Nit findings. Write `docs/features/<name>/reviews/design-<n>.md`. `<n>` is 1 plus the number of committed `docs/features/<name>/reviews/design-*.md` files. The report lists the raw files it was built from. Nothing is dropped silently. Every finding either appears in the synthesis or is logged:

```text
feature.ps1 decision -Repo <repo> -Name <name> -Kind dismiss -Text "<lens>: <finding> — <reason>"
```

Read `line`. Then commit the synthesis:

```text
feature.ps1 commit-records -Repo <repo> -Name <name> -Message "review: design-<n>"
```

### Failed reviewers

A run that fails with `ok: false` and an `error` starting with `sandbox:` is not retried: it is a sandbox setup problem. Report it to the user; it is a problem stop at once, handled like a usage limit. A lens run that ends without a report is retried once, with the same model. The retry ladder is not recorded. After a resume it starts again from the first attempt.

If it fails again, rerun it once on the other judgement model and log a decision. A Grok model (`grok-4.7-medium` or `grok-4.7-high`) is rerun as `glm-5.2-high`. A GLM model (`glm-5.2-high`) is rerun as `grok-4.7-medium`. A lens that ran on `composer-2.5` or `deepseek-v41-flash-1017-medium` is rerun once on `glm-5.2-high`.

```text
feature.ps1 decision -Repo <repo> -Name <name> -Kind decision -Text "<id>: rerun on <model>"
```

If that fails too, the lens is recorded as **not run**, never as "no findings". Say so in the synthesis. A lens that was not run blocks **design-locked** until it is rerun or the user waives it. Waive it only on a clear yes:

```text
feature.ps1 decision -Repo <repo> -Name <name> -Kind dismiss -Text "<run id>: not run — <reason>"
```

**Declining another round.** When the user declines another review round, log it once: `feature.ps1 decision -Repo <repo> -Name <name> -Kind decision -Text "review design-<n>: declined by the user"`, where `<n>` is the number of the round they declined (the `d<n>` in its run ids, counted from 1). It is `-Kind decision`, not `dismiss`: it is neither a waiver nor a stop. Do not log that round's lens runs one by one as not run: they never started. `status.reviewRuns` still lists them with `done: false`; after this decision, skip them. The not-run rule above applies only to a lens that started and ended without a report.

### Checkpoints

EGM's stage checkpoints become chat questions. They are not recorded gates.

## Resolve

Walk the user through resolving each finding, following the vendored resolve text with the differences above. A finding left out of the synthesis is logged with `-Kind dismiss`, as in Synthesis.

## Council

When a finding is a choice that is hard to reverse or contested, offer a council as in SKILL.md under "On-request and design/plan councils". Run it only if the user agrees.

## Lock the design

After the review is resolved, ask for **design-locked**. An unclear reply gets one confirming question that names the gate. Do not ask while any lens is not run and not waived.

On a clear yes, in this order, so the recorded blob is the final one:

1. Set the design doc's `Status:` to `Approved`, and run `feature.ps1 commit-design -Repo <repo> -Name <name> -Section Status`. Read `commit`.
2. Run `feature.ps1 gate -Repo <repo> -Name <name> -Gate design-locked -Quote "<user words>"`. Read `gate` and `sha`.
3. Run `feature.ps1 stage -Repo <repo> -Name <name> -To plan`. Read `from` and `to`.

Tell the user the design is locked and the next step is the plan. Do not start the plan until they ask.
