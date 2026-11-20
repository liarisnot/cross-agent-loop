# `sandbox-verify`: run a worker's tests inside the sandbox

*   **Author:** Eugene Chin
*   **Status:** Draft
*   **Date:** 2026-11-19

--------------------------------------------------------------------------------

## Overview

Since `worker-sandbox` (`docs/designs/worker-sandbox.md`), every Cursor worker runs in a Windows AppContainer that can reach its worktree and little else. Since `sandbox-env` (`docs/designs/sandbox-env.md`), the phase test of a repo with Python projects also runs in the sandbox, through `delegate.ps1 -SandboxRun`.

One step still runs a worker's code with the user's full rights: the lead's acceptance check of each task. `feature.ps1 verify` starts the task's test command with `pwsh` on the host, in the worker's worktree. The test command runs whatever the worker wrote: the code under test, the test files, and any helper script the worker added. A worker that wrote harmful code, on purpose or by mistake, gets it run outside the sandbox minutes later.

This feature moves that run into the sandbox, so code a worker wrote runs only inside a container until the lead has reviewed and merged it.

## The Problem

*   **`verify` undoes the sandbox for every task.** The worker's run is contained, but `verify` runs the worker's test command on the host as the user. Anything the sandbox blocks, such as reading the user's profile, other repos or credentials, or writing anywhere on disk, the test command can do there. The worker chooses the test files and helper scripts. The plan only fixes the command line.
*   **It happens before review.** The build stage runs `verify` before the lead reads the diff in detail, so the lead's review is not a guard.
*   **The phase test has the same gap in most repos.** `stages/build.md` runs the phase test through `-SandboxRun` only when the repo has Python projects. Every other repo, this one included, runs the phase test in the user's checkout on the host. Unlike `verify`, the phase test runs code the lead has already reviewed and merged.
*   **Not every test can run in a container.** This repo's own suite creates AppContainers, maps drive letters and writes Pester's test registry (`HKCU\Software\Pester`). None of that works inside a container. Its container tests already skip themselves when they detect one (`Get-LaunchSkipReason -Kind Sandbox`), and `scripts/test.ps1` turns the test registry off. Other repos may have tests that need the host for reasons the skills cannot predict.
*   **Measured (2026-11-19).** `scripts/test.ps1 -Fast -Path skills/feature/tests` through `-SandboxRun` passed 228 tests, skipped 1 (a container test) and took 604 s. On the host it passed 229 and took 531 s. So this repo's task tests already run in the sandbox, about 14% slower.

## Goals

*   **G1.** `feature.ps1 verify` runs the task's test command in the sandbox, in the worker's own worktree with its uncommitted changes, with the same environments a worker gets (`sandbox-env` links for Python projects).
*   **G2.** The result keeps its current shape (`test.passed`, `exitCode`, `tail`), so `stages/build.md` reads it unchanged, and it records whether the test ran in the sandbox.
*   **G3.** A test that cannot run in the sandbox never falls back to the host silently. Running on the host needs the user's approval. (The open question below is how wide that approval is.)
*   **G4.** The worktree is not changed for the lead: the sandboxed run writes only what the test itself writes, and the scope check (`changed`, `outOfScope`) still sees the worker's files and nothing the harness added.

## Non-Goals

*   **Pester's test registry in the sandbox.** It stays a documented workaround (`TestRegistry.Enabled = $false`, see the delegate skill's sandbox limits).
*   **Sign-off's full test run.** It runs merged, reviewed code on `main`'s way in, and in this repo it needs the host (containers, drive letters). Unchanged.
*   **Running tests with no network.** The sandbox keeps internet access, as for workers.
*   **Other agents.** Only Cursor workers are sandboxed today; `verify` follows the same rule.

## Open Questions

None. Q1 and Q2 were decided by the author on 2026-11-19 (D1, D2 below).

## Technical Plan

### Decisions

| # | Decision | Why |
|---|---|---|
| D1 | The phase test runs in the sandbox in **every** repo, through `-SandboxRun`, not only in repos with Python projects. | Author's choice: one rule for both test steps, and no repo is left on the host by default. |
| D2 | A test runs on the host only after the user approves that one run. The approval is never remembered: not for the task, the feature or the repo. | Author's choice: the protection never lapses. A sandbox failure is rare (this repo's task tests pass in the sandbox), so the prompts are few. |
| D3 | `verify` runs the test in the worker's **existing** worktree, not in a fresh one. | The test must see the worker's uncommitted changes, which is what `verify` checks today. A fresh worktree at a commit (what `-SandboxRun` does now) would test nothing the worker wrote. |
| D4 | `feature.ps1` reaches the sandbox only through `delegate.ps1 -SandboxRun`, with a new `-Worktree` parameter. | All sandbox code stays in the delegate skill; `feature.ps1` already calls `delegate.ps1` that way for `doctor`. |
| D5 | A sandboxed `verify` counts toward the feature's cap of 2 runs. | It takes a sandbox slot, and there are only two. If it did not count, `schedule` could start a second worker while `verify` waits, and one of them would time out waiting for a slot. |
| D6 | The skills do not guess whether a failure was caused by the sandbox. The lead reads the output and asks the user. | An exit code cannot tell "access denied by the sandbox" from a real bug, and a wrong guess either hides a bug or runs code on the host without approval. |

### Components

*   **`delegate.ps1 -SandboxRun -Worktree <path>`** (new parameter). Runs the command in an existing worktree of `-Repo` instead of creating a `.probe-<hex>` worktree. The readiness gate uses the worktree's `HEAD`, as a worker launch does. Python environments are linked as for a worker and are left in place afterwards (the worktree's own `-Cleanup` removes them). The worktree is not removed. With `-Feature <name>`, the run writes the same pid file as a worker run, so `feature.ps1 schedule` counts it (D5). The output keeps its shape: `{ok, status, exitCode, output, seconds, notes}`, plus `message` and `proposal` for `environment-missing`.
*   **`feature.ps1 verify`** runs the test command through `-SandboxRun -Worktree <task worktree> -Feature <name>` by default. The test command goes into the same wrapper script it uses today, written to `<worktree>\.xagent\verify-<hex>.ps1` and deleted afterwards. `.xagent\` is excluded from git, so the scope check never sees it. The scope check (`changed`, `outOfScope`) is computed before the test, as today.
*   **`feature.ps1 verify -OnHost -Quote "<user's words>"`** runs the test on the host exactly as today, and logs a decision with the user's words. `-OnHost` without `-Quote` is refused.
*   **The `test` object** in `verify`'s output and in `state.json` keeps `command`, `passed`, `exitCode` and `tail`. It gains `where` (`sandbox` or `host`) and, when the sandbox could not run the test at all, `setup` (`{status, message, proposal}`).
*   **`stages/build.md`.** Reads `test.setup` before `test.passed`. Runs every phase test through `-SandboxRun` (D1). Describes the host fallback (D2, D6).

### Flow of a task check

```text
worker finishes
  -> feature.ps1 verify -Task <id>
       scope check on the worktree (unchanged)
       write .xagent\verify-<hex>.ps1 (the test wrapper)
       delegate.ps1 -SandboxRun -Repo <repo> -Worktree <wt> -Feature <name>
                    -Command "& '.\.xagent\verify-<hex>.ps1'" -TimeoutSec <t>
         status ran       -> test {passed: exitCode = 0, where: sandbox}
         status timeout   -> test {passed: false, exitCode: -1, where: sandbox}
         environment-missing -> test {passed: false, setup: {...}}
         sandbox: error   -> test {passed: false, setup: {status: sandbox-error, message}}
  -> lead:
       setup environment-missing -> -SandboxEnv -Apply (ask only if the proposal says so), verify again
       setup sandbox-error       -> problem stop (as for any sandbox: error)
       passed false              -> read tail; a code failure is a failed review round (unchanged);
                                    a sandbox limit -> ask the user -> verify -OnHost -Quote "<yes>"
```

The phase test follows the same flow at `feature/<name>`, through `-SandboxRun -Base feature/<name>` (a fresh worktree is right there: the phase test runs merged code). A host run of a phase test is approved and logged the same way, by the lead, with `feature.ps1 decision`.

### Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Slower checks: about 14% measured, plus a few seconds to set up the slot. | Accepted; task tests are kept narrow by the size gate. |
| `verify` waits for a slot while two workers run. | D5: it counts toward the cap, so the lead runs it only when a run slot is free. `Get-SandboxSlot` still times out after 60 s, which `verify` reports as `sandbox-error`. |
| A repo whose tests always need the host asks the user at every task. | Accepted (D2). The prompt shows the output, so the user can instead fix the repo's tests or the sandbox read list. |
| The test can read Cursor's login copy. `New-SandboxRun` copies `auth.json` and `cli-config.json` into every run's home, including plain `-SandboxRun` commands. | No new exposure: the worker that wrote the code already ran with the same copy in the same home. Not copying them for plain commands is a small follow-up and is included here (see the implementation plan). |
| A test writes files into the worktree. | Unchanged from today: the scope check runs first, and the lead's review reads the diff. |
