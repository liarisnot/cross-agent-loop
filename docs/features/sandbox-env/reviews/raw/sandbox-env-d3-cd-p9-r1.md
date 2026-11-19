<!-- persona: codebase_details | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer instructions exactly.The task is a read-only implementation-readiness review of `docs/designs/sandbox-env.md`. I'll read that document and the listed source files next.The design cites existing sandbox, delegate, and feature code. I'll read those sources and the earlier stage-9 reports to check what still disagrees.The earlier stage-9 findings were rewritten into the design. I'll check those claims against the sandbox, delegate, and feature code.The plan is not implementation-ready. The rewrite closes the earlier stage-9 data-model and grant holes, and four current-behavior or lead-procedure gaps are still open. A fresh implementer still has to invent command startup, the approval branch, and several launch paths that already exist in `delegate.ps1`.

## Earlier stage-9 findings

Closed in this text: the `PATH` sentence matches `Get-SandboxEnvironment`; `uv` on the README is a planned edit; the drive-letter analogy is the `sandbox:` error that names the fix; `failed` is stored; the identity hash is git blob ids; the `.pth` line, the estimate formula, the `-SandboxRun` schema and steps, the one-way module import, `-Base feature/<name>`, the `-NoSandbox` skip, the retry exception in the `SKILL.md` and `build.md` rows, the doctor check (in-process, eleven checks, 300 characters), `-Rebuild`, atomic `envs.json`, and the pre-worktree gate are all specified.

Still open: there are still no phases. `design-2.md` dismissed that because the plan stage would add them. The Implementation Readiness Standard still requires phases in this document, each leaving the tree buildable and testable. That dismissal does not close the finding.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` line 283 (`Invoke-SandboxCommand`); `skills/delegate/scripts/SandboxNative.cs` `Start` (line 237) and `CreateProcessW` (line 322); `skills/delegate/scripts/Sandbox.psm1` `Invoke-SandboxCanary` (lines 2301–2303)
**Discrepancy:** The probe starts `pwsh -NoProfile -Command`. `Start-SandboxProcess` passes that exe string as `lpApplicationName`. `CreateProcessW` does not search `PATH` for that argument, and the process working directory is the slot root (`<slot>:\`), so a bare `pwsh` fails with `sandbox: cannot start pwsh`. The only sandboxed PowerShell launch in the tree uses `C:\Program Files\PowerShell\7\pwsh.exe`.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 32, 95, 115, 268, 297, and 300
**Discrepancy:** G2, the disk risk, the Approval rule, and the `SKILL.md` / `build.md` file rows ask again when `needsApproval` is true, including when `approved` is already set and this build’s estimate is over 5 GB. The Components paragraph tells the lead to ask only when something is missing and the repo’s first setup is not yet approved, and otherwise to run `-Apply` with no question. Those are two lead procedures. The Components paragraph drops the re-approval the rest of the document requires.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` lines 95, 247–257, and 300; `skills/feature/stages/build.md` lines 160 and 166
**Discrepancy:** A phase test today is a command run in `<repo>`, and a non-zero exit is the failure `build.md` handles. `-SandboxRun` prints one JSON object and exits 0 whenever that object is a result, including `status` `ran` with a non-zero `exitCode`, `timeout`, and `environment-missing`. A setup failure is the case that exits 1. The `build.md` edit says to run that command instead of the test in `<repo>` and does not say the phase fails unless `status` is `ran` and `exitCode` is 0. Following the file row as written records a failing phase test as a successful delegate run.

## Blocker

**Severity:** Blocker
**Affected scope:** `docs/designs/sandbox-env.md` line 11; `skills/delegate/scripts/Sandbox.psm1` `Get-SandboxGrantList` lines 1198–1202
**Discrepancy:** The overview says that, besides the worktree, the run home, and the `.git` paths the run needs, the container can read `C:\Windows`, `C:\Program Files`, and the read list, and nothing else. `Get-SandboxGrantList` also grants the Cursor runtime cache folder `RA`, `<runtime cache>\<version>` `(OI)(CI)RX`, and `<runtime cache>\<version>\.running` `(OI)(CI)M`. Those paths are readable on every sandboxed run.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` line 263
**Discrepancy:** `$script:UvPath` is set from `Get-CommandPath uv`, or from `XAGENT_UV_PATH`. There is no `Get-CommandPath` in this repository. Command lookup that exists today is `Get-Command` (for example `feature.ps1` doctor’s git check). The plan cites the missing function as the host lookup.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` line 190
**Discrepancy:** A reader treats a missing or unreadable `envs.json` as every environment absent, and `-SandboxEnv` then adds `"warning": "envs.json unreadable; rebuilding on -Apply"`. The file is absent on the first report, before any `-Apply`. That warning is defined for the normal first run and for a corrupt file as the same case.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 92, 278–279, and 290; `skills/delegate/scripts/delegate.ps1` lines 360–367
**Discrepancy:** The gate is specified before `git worktree add`, and linking is specified after that add, using the worktree `HEAD` hash. When `<repoParent>\<repoName>.xagent\<TaskId>` already exists, `delegate.ps1` does not call `worktree add`. When `refs/heads/xagent/<TaskId>` already exists, `worktree add` checks out that branch, so `HEAD` is the branch tip and `-Base` is not that commit. The plan does not say whether a reused worktree still fails the gate, whether an existing worktree is left in place, or which hash is linked when `HEAD` and `-Base` differ. D8 exists for that difference.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` line 283; `skills/delegate/scripts/delegate.ps1` lines 248–265
**Discrepancy:** The plan says `probe-<8 hex>` cannot clash with task ids because `-Cleanup` matches `^<TaskId>-[a-z0-9]+$`. `-TaskId` allows `probe` (`^[a-z0-9][a-z0-9-]{0,48}$`). `-Cleanup -TaskId probe` removes detached directories whose names match `^probe-[a-z0-9]+$`. A probe worktree is detached and its name is `probe-` plus eight hex characters, which matches that regex. Cleanup of a task named `probe` removes probe worktrees.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` line 281; `skills/delegate/scripts/delegate.ps1` lines 269–276
**Discrepancy:** Unlink is specified before the three `worktree remove` calls. `-Cleanup -Discard` runs `git -C <worktree> add -A` and `git diff --cached HEAD` before that remove. The junction is still in the worktree for that add. The plan’s “before any recursive walk” sentence and the “before `worktree remove`” sentence name different insertion points, and only the remove calls are listed.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` line 283; `skills/delegate/scripts/Sandbox.psm1` `Stop-SandboxRun` (the `-Slot` parameter is mandatory) and `Invoke-SandboxCanary` lines 2314–2328
**Discrepancy:** `Invoke-SandboxCommand`’s `finally` always calls `Stop-SandboxRun`, then unlinks, then `git worktree remove --force`. `Stop-SandboxRun` requires `-Slot`. The canary calls it only after a slot was acquired. A failure during `worktree add` or linking has no slot. A throw from `Stop-SandboxRun` on that path stops the rest of that `finally`, so the probe worktree is left behind. The plan does not say to skip `Stop-SandboxRun` when no slot was taken.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` lines 187 and 265
**Discrepancy:** The interpreter rule says the skill never parses versions, and that `uv python install "<request>"` then `uv python find --managed-python "<request>"` supply the exact version that keys `pythons` and the folder stored under `.envs\python`. The plan does not say which part of either command’s output is that version string or that folder. The identity hash includes every workspace member `pyproject.toml`, and members are “the paths matched by `[tool.uv.workspace] members`”. The plan does not say whether those values are literal paths or globs, or whether `exclude` applies. Both feeds decide the environment name and the hash.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` Files table, lines 285–303
**Discrepancy:** `SandboxEnv.psm1`, `SandboxEnv.Tests.ps1`, and `skills/delegate/tests/fixtures/sandbox-env/` are marked **New.** The other twelve paths describe an edit and are not marked Modify or Delete. The standard’s file boundary needs each path marked Create, Modify, or Delete.

## Major

**Severity:** Major
**Affected scope:** `docs/designs/sandbox-env.md` line 305; Implementation Readiness Standard, “Phasing & Checkpoints”
**Discrepancy:** The standard requires incremental phases that each leave the tree buildable and testable. Line 305 leaves the order to the plan stage. This is the same gap as the previous stage-9 reports. `design-2.md` records it as dismissed. The document still has no phase table, no checkpoint, and no suite that must pass at each checkpoint.

## Nit

**Severity:** Nit
**Affected scope:** `docs/designs/sandbox-env.md` lines 92 and 278
**Discrepancy:** The worker failure text is `sandbox: environment not ready: <projects>; <proposal>` in Components, and `sandbox: environment not ready: <project> (<status>), ...; run -SandboxEnv -Repo <repo> -Base <ref> -Apply` plus the proposal text in Rules. The two strings are the public error.

## Nit

**Severity:** Nit
**Affected scope:** `docs/designs/sandbox-env.md` lines 219 and 247
**Discrepancy:** Both results are “one line” of JSON. `Fail` uses `ConvertTo-Json -Compress` with no `-Depth`. `Out-Summary` uses `-Depth 6`. The default depth is 2, which collapses `proposal`, `projects`, `built`, and `failedNow`. The plan does not name `-Depth`.

## Nit

**Severity:** Nit
**Affected scope:** `docs/designs/sandbox-env.md` lines 32 and 268
**Discrepancy:** The re-approval threshold is “5 GB” and `estimateBytes` is a byte count. The plan does not say whether 5 GB is `5000000000` or `5 * 1024 * 1024 * 1024`. That comparison is the second user prompt.
