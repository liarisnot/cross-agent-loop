# Sign off

Run the full test suite and the final drift check, show them, and merge into `main` only after a clear **signed-off**.

When this file applies: the stage is `signoff`, the user asked to test and sign off, or the router sent you here for step 7 after the final check was shown.

`feature.ps1 <subcommand>` means `pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 <subcommand>`, and `delegate.ps1` means `pwsh -NoProfile -File <delegate dir>/scripts/delegate.ps1`. `<skill dir>`, `<delegate dir>`, `<repo>` and `<name>` are defined in SKILL.md. Every `feature.ps1` call passes `-Repo <repo> -Name <name>`. Never merge `feature/<name>` into `main` yourself. Only `feature.ps1 finish` does that, and only after **signed-off**.

## 1. Clean tree

Run `feature.ps1 status -Repo <repo> -Name <name>`. Stop unless `treeClean` is true and `branch` is `feature/<name>`. Tell the user what is wrong, in plain words. Read `diffTouchesRuleFiles` and `reviewRuns` for the later steps.

## 2. Full suite

Run the last phase's `test` command in `<repo>`. That command is the full suite. It is the `test` field of the last phase in `docs/features/<name>/feature.json`, and the `Test:` line of that phase in `plan.md`. If it fails, show the failure and stop. Do not ask for sign-off.

## 3. Final diff

Write the diff with:

```text
git -C <repo> diff --output=.xagent/features/<name>/final.diff main...feature/<name>
```

Do not use `>` to write this file. In PowerShell, `>` writes UTF-16.

## 3a. As-built note

`finish` refuses when the design file differs from the one locked at **design-locked**, so build findings cannot go into the design before the merge. If the build settled or changed anything the design says (a platform fact, a changed mechanism, an accepted limit), write `docs/features/<name>/as-built.md`: one short item per finding, each naming the design section it affects. Commit it with `feature.ps1 commit-records -Repo <repo> -Name <name> -Message "as-built note"`. Skip this step when there is nothing to note.

## 4. Task file

Write `<repo>/.xagent/features/<name>/<id>.task.md`, where `<id>` is the one run in `status.reviewRuns`. The file names the locked design's path (`<design doc>`) and says the diff is `.xagent/final.diff` in the reviewer's worktree. If `as-built.md` exists, the file names it too and asks the reviewer to mark each finding that the note explains as "explained by as-built.md", not as drift.

## 5. Drift check

Take the one run from `status.reviewRuns` (persona `drift_report`, model `grok-4.7-medium`, no standard). If `done` is true, the raw report is already committed. Go to step 6.

If `done` is false, follow the cap rule in SKILL.md, then:

```text
delegate.ps1 -Agent cursor -Profile review -Persona drift_report -Model <model> -Feature <name> -Repo <repo> -Base feature/<name> -TaskId <id> -TaskFile <task file> -TargetFile <repo>/.xagent/features/<name>/final.diff
```

`<model>` is that run's `model`. Do not pass `-Standard`. Pass `-KeepRuleFiles` on that command if `status.diffTouchesRuleFiles` is true. The reviewer runs in a worktree detached at `feature/<name>`. It is given the locked design and the diff file by path.

A run that fails with `ok: false` and an `error` starting with `sandbox:` is not retried: it is a sandbox setup problem. Report it to the user; it is a problem stop at once, handled like a usage limit. If it ends without a report, retry once with the same model. If that fails, run it once on `glm-5.2-high` and log a decision:

```text
feature.ps1 decision -Repo <repo> -Name <name> -Kind decision -Text "<id>: rerun on glm-5.2-high"
```

If that fails too, the lens is recorded as not run, which blocks the gate. Never record it as "no findings". Tell the user. Rerun it, or waive it only on a clear yes:

```text
feature.ps1 decision -Repo <repo> -Name <name> -Kind dismiss -Text "<run id>: not run — <reason>"
```

A usage-limit message is a problem stop at once. Follow "Failed delegate.ps1 runs" in SKILL.md.

When the run produced a report, copy `reviewFile` to `docs/features/<name>/reviews/raw/<id>.md`. Commit it, then clean up:

```text
feature.ps1 commit-records -Repo <repo> -Name <name> -Message "review: <id>"
delegate.ps1 -Cleanup -Profile review -Repo <repo> -TaskId <id>
```

Read `commit` from `commit-records`.

## 6. Show the results

Show the test results and the findings, grouped as missing, added or changed behaviour. The check returns three lists: behaviour missing from the code, added beyond the design, and changed from it.

## 7. Ask for signed-off

Ask for **signed-off**. An unclear reply gets one confirming question that names the gate. Do not ask while the drift lens is not run and not waived.

On a clear yes:

1. Run `feature.ps1 gate -Repo <repo> -Name <name> -Gate signed-off -Quote "<user words>"`. Read `gate` and `sha`. The recorded `sha` is the `feature/<name>` commit that was checked.
2. Run `feature.ps1 finish -Repo <repo> -Name <name>`.
3. Ask whether to push. `finish` never pushes. On a clear yes, run `git -C <repo> push`. Otherwise do not push.

On success (`ok: true`), the feature counts as `done` once the merge commit exists on `main`. That is derived, not stored. Report it.

### After the merge

1. **Fold in the as-built note.** If `docs/features/<name>/as-built.md` exists, write each item into the design on `main`, marked "(as built)", and add an `Amended:` line at the top of the design. Show the user the changes and commit only on their approval.
2. **Live check, when the feature changed the skills that run it.** When a feature changes files under `skills/` in this repo, the build usually runs a frozen copy of the skills, and its tests start one run at a time. So bugs that show only with the live skills, with runs at the same time, or with a killed run surface after the merge (on `worker-sandbox`: grants lost between concurrent starts, a slot left mapped after a kill). Once the skill links point at the merged code, do a short check: two live runs at once, and one run killed mid-way and then cleaned up. Fix what it finds on `main` as ordinary commits, and note them in `docs/test-plan.md`.

`finish` also refuses when the tree is not clean, when `HEAD` is not `feature/<name>`, when `git diff` from the signed-off SHA to `HEAD` lists any file outside `docs/features/<name>/`, or when the design file's blob differs from the one recorded at **design-locked**. Show `error` and stop.

### Conflict

On a merge conflict, `finish` fails with `error` beginning `merge conflict in`, and **signed-off** is cleared. `finish` aborts the merge and switches back to `feature/<name>`. Report the files named in `error`. A new final check is needed after the user resolves them.
