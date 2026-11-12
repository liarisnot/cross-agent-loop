# Status

Report where the feature stands. Make no changes.

When this file applies: the user asked where a feature stands ("where are we?", "status"), including a read-only question while plan mode is on.

## Run only status

Run only `feature.ps1 status`. That means `pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 status`. `<skill dir>`, `<repo>` and `<name>` are defined in SKILL.md.

When no feature is selected yet:

```text
feature.ps1 status -Repo <repo> -Cwd <current folder>
```

When a feature is selected, also pass `-Name <name>`:

```text
feature.ps1 status -Repo <repo> -Name <name> -Cwd <current folder>
```

Do not run any other command. Do not run `feature.ps1 reconcile`, `feature.ps1 schedule`, or `delegate.ps1`. Do not edit files or commit.

Read `ok`, `selected`, `features`, `warnings`, and, when a feature is selected, `stage`, `phase`, `tasks`, `waitingOn`, `tokens`, `lastDecisions` and `nextAction`.

## No active feature

If `selected` is null, list the features in progress: each entry in `features` whose stage is not `done` or `abandoned`, by name and stage. If that list is empty, say there is no feature in progress and offer to design one. Stop.

## Report

Print the status JSON as a short report:

- the stage (`stage`) and the phase (`phase.current` of `phase.total`). When `phase` is null, say there is no phase yet.
- tasks by status (each `tasks` entry: `id` and `status`; include `rounds`, `councils` and `failures` when they are not zero)
- what the flow is waiting on (`waitingOn`: a `gate`, a `stop`, the `running` ids, or nothing)
- the token use so far, including cache reads (`tokens.input`, `tokens.output`, `tokens.reasoning`, `tokens.cacheRead`, `tokens.total`). If `tokens` is null, say the usage log could not be read and include `warnings`. Do not invent a number.
- the last 3 decisions (`lastDecisions`)
- the action "continue" would take (`nextAction`)

If `warnings` says the feature is done, say it is done and merged into `main`.
