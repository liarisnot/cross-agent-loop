<!-- persona: zoom_out | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer instructions exactly.The task is a REVIEW of `docs/designs/sandbox-verify.md`. I'll read that design against the Zoom-Out Standard and the related sandbox and feature context.The design is in place. Next I’ll check the project goals and the sandbox and verify code it claims to reuse.Context is sufficient. The objective is to stop `feature.ps1 verify` from running a worker's unreviewed test command on the host. Routing that command through the existing `delegate.ps1 -SandboxRun` path, in the worker's current worktree, is the small change that closes that hole. `Invoke-SandboxCommand`, `Add-SandboxEnvLinks`, and `Get-LiveDelegateRunCount` already cover the slot, the Python links, and the cap.

## Findings

### 1. Blocker — the cap pid is written into a directory the sandbox runner deletes

**Affected scope:** Data, "Pid file" (around line 141); Components, `-SandboxRun -Worktree` (D5).

**Simplicity rationale:** D5 is right to reuse the existing cap. `Get-LiveDelegateRunCount` already counts any `*.pid` under `<repo>\.xagent\runs` whose JSON has `pid`, `startTime`, and `feature`. Worker runs already publish that file as `$logBase.pid` and delete it in a `finally`.

The plan puts the new file at `<repo>\.xagent\runs\probe-<hex>\run.pid` and says to write it before the slot is taken. `Invoke-SandboxCommand` then does this with `-RunName` set to that same `probe-<hex>` (as today's `-SandboxRun` does): if the directory exists, it deletes it and creates it again for `stdout.txt` and `stderr.txt`. The pid disappears at the moment the slot is acquired. For the whole test, `schedule` sees a free cap slot while `verify` holds one of the two sandbox slots. That is the race D5 exists to prevent.

Keep the write-before-wait and the `finally` delete. Put the `*.pid` file somewhere `Invoke-SandboxCommand` does not wipe (a sibling file, same shape as a worker pid). No new counter.

### 2. Major — `tail` is defined as the end of a stream that is already the first 40 lines

**Affected scope:** G2; the `verify` output rules ("`tail` is the last 40 lines of `output`"); the lead flow that reads `tail` to choose a host rerun (D6).

**Simplicity rationale:** `Invoke-TaskTestCommand` stores the last 40 lines. That is where a Pester summary and an access error show up, and it is what `stages/build.md` shows on a failed round. `Get-SandboxCommandOutputLines` and the delegate skill do something else: `output` is the first 40 lines, stdout then stderr, each line cut at 400 characters. The plan treats that array as the full stream and tails it. The lead then decides "real bug" versus "sandbox limit" from the preamble.

The full text is already on disk. `Invoke-SandboxCommand` writes `stdout.txt` and `stderr.txt` under `<repo>\.xagent\runs\<RunName>\` before it truncates. Build `tail` from those files, with the same last-40 rule `verify` uses now. Leave the JSON `output` array as the existing 40-line head.

### 3. Major — D1 sandboxes a different problem from the one this feature states

**Affected scope:** Problem, third bullet; D1; Non-goals, "Sign-off's full test run"; `stages/build.md` phase end.

**Simplicity rationale:** The hole named in the overview is `verify`: worker-written code, on the host, before review. The same Problem section says the phase test runs code the lead has already reviewed and merged. Shipped `build.md` already sandboxes that step only when the repo has Python projects. `stages/plan.md` makes each phase test the full suite (or its fast subset). Sign-off runs that same command on the host, and this design's non-goals leave it there because this repo's suite needs the host (AppContainers, drive letters, the Pester registry).

D1 applies one sandbox rule to both steps anyway. Every phase test then takes a slot, counts toward the cap of 2, and, when it cannot run in a container, asks the user again with no memory (D2). The measured 14% was `scripts/test.ps1 -Fast -Path skills/feature/tests` (228 passed, 1 skipped), not this repo's full suite.

The smaller design is `-Worktree` plus `verify` calling `-SandboxRun`. Leave the Python-only phase rule as it is.

### 4. Nit — `-NoLogin` is a second change on the shared run path

**Affected scope:** Risks, "The test can read Cursor's login copy"; Rules, "Login files"; Files, `Sandbox.psm1`.

**Simplicity rationale:** The risk table says this is not a new exposure: the worker that wrote the code already ran with the same `auth.json` and `cli-config.json`. The README already documents that copy. `New-SandboxRun` copies both files for every run today. A `-NoLogin` switch, always passed by `Invoke-SandboxCommand`, splits that path and adds a container test, and it does not move any unreviewed code off the host. Leave the copy as it is.

### 5. Nit — a wrapper script in the worker worktree repeats a command runner that already exists

**Affected scope:** Components, `feature.ps1 verify`; Rules, "The sandboxed run".

**Simplicity rationale:** `Invoke-SandboxCommand` already starts `pwsh -NoProfile -Command` with the command string. `Invoke-TaskTestCommand` already has the wrapper body (`ErrorActionPreference`, merged output, `exit $LASTEXITCODE`). Writing `<worktree>\.xagent\verify-<hex>.ps1` and deleting it adds a file in the worker tree and a second copy of that wrapper. Pass the wrapper as `-Command`. G4 does not depend on this file: the scope check already skips `.xagent\` and already runs before the test.

## Reuse that holds

- D3 matches `Invoke-VerifyFeature`: the check is the worker's uncommitted worktree. A fresh detached worktree at a commit would miss it. `-Worktree` cannot be combined with `-Base`, which matches today's `-SandboxRun` (it always `git worktree add --detach`s a `.probe-<hex>` at `-Base`).
- D4 matches how `doctor` finds `skills/delegate/scripts/delegate.ps1`. `-Feature` already exists on worker runs and is the field the cap counter filters on.
- Leaving Python junctions in place until the worktree's own `-Cleanup` matches a worker launch. Probe runs unlink only because they delete the probe tree.
- D6 matches the runner: it reports `status` and `exitCode`, not a sandbox-versus-bug class. `environment-missing` is already a distinct status with `message` and `proposal`.
