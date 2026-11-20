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

*   **Q1. Phase tests.** Should the phase test also move into the sandbox for every repo, not only repos with Python projects?
*   **Q2. The host fallback.** When a test cannot run in the sandbox, who approves running it on the host, and for how long does the approval last: once per task, once per feature, or once per repo?
