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
*   **Measured (2026-11-19).** `scripts/test.ps1 -Fast -Path skills/feature/tests` through `-SandboxRun` passed 228 tests, skipped 1 (a container test) and took 604 s. On the host it passed 229 and took 531 s. So this repo's task tests already run in the sandbox, about 14% slower. The delegate skill's tests (`-Path skills/delegate/tests`) are different: 165 passed and 4 failed in the sandbox, because they start `delegate.ps1` itself, which reaches the real `D:\` and the user's temp folder. Those tests need the host.

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
| D1 | The phase test runs in the sandbox in **every** repo, through `-SandboxRun`, not only in repos with Python projects. | Author's choice: one rule for both test steps, and no repo is left on the host by default. Reconfirmed after review (2026-11-20), knowing that in this repo a phase whose test includes the delegate tests will ask for a host run (see the Problem section). |
| D2 | A test runs on the host only after the user approves that one run. The approval is never remembered: not for the task, the feature or the repo. | Author's choice: the protection never lapses. A sandbox failure is rare (this repo's task tests pass in the sandbox), so the prompts are few. |
| D3 | `verify` runs the test in the worker's **existing** worktree, not in a fresh one. | The test must see the worker's uncommitted changes, which is what `verify` checks today. A fresh worktree at a commit (what `-SandboxRun` does now) would test nothing the worker wrote. |
| D4 | `feature.ps1` reaches the sandbox only through `delegate.ps1 -SandboxRun`, with a new `-Worktree` parameter. | All sandbox code stays in the delegate skill; `feature.ps1` already calls `delegate.ps1` that way for `doctor`. |
| D5 | A sandboxed `verify` counts toward the feature's cap of 2 runs. | It takes a sandbox slot, and there are only two. If it did not count, `schedule` could start a second worker while `verify` waits, and one of them would time out waiting for a slot. |
| D6 | The skills do not guess whether a failure was caused by the sandbox. The lead reads the output and asks the user. | An exit code cannot tell "access denied by the sandbox" from a real bug, and a wrong guess either hides a bug or runs code on the host without approval. |

### Components

*   **`delegate.ps1 -SandboxRun -Worktree <path>`** (new parameter). Runs the command in an existing worktree of `-Repo` instead of creating a `.probe-<hex>` worktree. The readiness gate uses the worktree's `HEAD`, as a worker launch does. Python environments are linked as for a worker and are left in place afterwards (the worktree's own `-Cleanup` removes them). The worktree is not removed. Both `-SandboxRun` forms go through one helper in `delegate.ps1` (readiness gate, linking, the run); only how the worktree is obtained and the `finally` differ, and only the probe form removes a worktree. With `-Feature <name>`, the run writes a pid file like a worker run's, so `feature.ps1 schedule` counts it (D5). The output keeps its fields, `{ok, status, exitCode, output, seconds, notes}` plus `message` and `proposal` for `environment-missing`, and gains `tail`: the **last** 40 lines of stdout then stderr (`output` stays the first 40).
*   **`feature.ps1 verify`** runs the test command through `-SandboxRun -Worktree <task worktree> -Feature <name>` by default. The test command goes into the same wrapper it uses today, passed inside the command line as `pwsh -NoProfile -NonInteractive -EncodedCommand <base64>`, so nothing is written into the worktree. The scope check (`changed`, `outOfScope`) is computed before the test, as today.
*   **`feature.ps1 verify -OnHost -Quote "<user's words>"`** runs the test on the host exactly as today, and logs a decision with the user's words. `-OnHost` without `-Quote` is refused.
*   **The `test` object** in `verify`'s output and in `state.json` keeps `command`, `passed`, `exitCode` and `tail`. It gains `where` (`sandbox` or `host`) and, when the sandbox could not run the test at all, `setup` (`{status, message, proposal}`).
*   **`stages/build.md`.** Reads `test.setup` before `test.passed`. Runs every phase test through `-SandboxRun` (D1). Describes the host fallback (D2, D6).

### Flow of a task check

```text
worker finishes
  -> feature.ps1 verify -Task <id>
       scope check on the worktree (unchanged)
       delegate.ps1 -SandboxRun -Repo <repo> -Worktree <wt> -Feature <name>
                    -Command "pwsh -NoProfile -NonInteractive -EncodedCommand <wrapper>; exit $LASTEXITCODE"
                    -TimeoutSec <t>
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
| The test can read Cursor's login copy. `New-SandboxRun` copies `auth.json` and `cli-config.json` into every run's home, including plain `-SandboxRun` commands. | No new exposure: the worker that wrote the code already ran with the same copy in the same home. Unchanged by this feature. |
| In this repo, a phase whose test includes the delegate tests fails in the sandbox and asks for a host run (D1, D2). | Accepted by the author. The lead shows the failing lines; the approval covers that one run. |
| A test writes files into the worktree. | Unchanged from today: the scope check runs first, and the lead's review reads the diff. |

## Alternatives Considered

### Run the test in a fresh worktree at a commit of the worker's changes

The lead would commit the worker's changes first (or `verify` would stash them into a temporary commit) and run `-SandboxRun -Base <that commit>` as it does today.

*   **Pros:** no change to `-SandboxRun`; the run cannot touch the worker's worktree.
*   **Cons:** `verify` runs before the lead commits, and the build stage's review rounds resume the worker in the same worktree. A temporary commit changes the worktree's history under the worker, and copying the changes adds a second place for files to differ.
*   **Reason for rejection:** Rejected by author: running in the existing worktree (D3) tests exactly what the worker left, with no extra commit.

### Remember a host approval for the feature or the repo

*   **Pros:** fewer questions for a repo whose tests always need the host.
*   **Cons:** once given, later tasks run worker code on the host without anyone looking, which is the gap this feature closes.
*   **Reason for rejection:** Rejected by author (D2).

### Approve a test command for host runs instead of one run

The user would approve the plan's test command string once (say, at the first host run in a repo), and later runs of that exact command would go to the host without asking.

*   **Pros:** one question per command instead of one per run.
*   **Cons:** the command is fixed by the plan, but what it runs is not: `pwsh -File scripts/test.ps1` runs whatever test files and helpers the worker changed. Approving the command approves running every later worker's code on the host.
*   **Reason for rejection:** Rejected by author (D2): it collapses into "Remember a host approval".

### Detect sandbox failures automatically and retry on the host

`verify` would look for "access denied" in the output and rerun on the host.

*   **Pros:** no prompt.
*   **Cons:** a test can print "access denied" because of a real bug, and a sandbox failure can print anything. Either way, worker code runs on the host without approval.
*   **Reason for rejection:** Rejected by author (D6).

### Keep phase tests on the host outside Python repos

*   **Pros:** no change to the phase step for most repos, and no 14% slowdown there.
*   **Cons:** two rules for two test steps; a repo stays unprotected because it has no Python projects, not because it needs the host.
*   **Reason for rejection:** Rejected by author (D1).

## Detailed Implementation Plan

### Probes

None needed. The one open fact, whether this repo's own task tests run inside the sandbox, was measured before the design (see the Problem section). The `-SandboxRun` machinery, slot handling and environment links are from `sandbox-env` and unchanged.

### Data

**`delegate.ps1 -SandboxRun` parameters.** Today's set (`-Repo`, `-Base`, `-Command`, `-TimeoutSec`) gains:

*   `-Worktree <path>`: an existing worktree of `-Repo`. Cannot be combined with `-Base` (refused: `-Worktree cannot be used with -Base`).
*   `-Feature <name>`: the same pattern as on worker runs. Written to the pid file.

**Output** keeps today's fields, `{ok, status, exitCode, output, seconds, notes}` plus `message`, `projects` and `proposal` when `status` is `environment-missing`, and gains `tail` for `ran` and `timeout`: the last 40 lines of the run's `stdout.txt` followed by `stderr.txt`, each line cut at 400 characters (the same reading `output` uses, from the other end). A refused call or a `sandbox:` error is `{ok: false, error}` with exit 1, as today.

**Pid file.** Every `-SandboxRun` with `-Feature` writes `<repo>\.xagent\runs\probe-<hex>.pid`, beside the run folder and not inside it (`Invoke-SandboxCommand` deletes and recreates `runs\probe-<hex>\` when it starts), holding `{pid, startTime, feature}` (`pid` and `startTime` of the `delegate.ps1` process, `startTime` in UTC ISO 8601 as on worker runs). It is written before the slot is taken and deleted in a `finally`. `feature.ps1`'s `Get-LiveDelegateRunCount` already counts any `*.pid` under `.xagent\runs` with those three fields, so `schedule` needs no change. Without `-Feature`, no pid file is written.

**`feature.ps1 verify` parameters.** Today's (`-Repo`, `-Name`, `-Task`, optional `-TimeoutSec`) plus:

*   `-OnHost`: run the test on the host as today. Requires `-Quote`; without it, refused: `-OnHost requires -Quote with the user's approval`.
*   `-Quote "<user's words>"`: one line. Only with `-OnHost` (refused otherwise: `-Quote requires -OnHost`).
*   `-TimeoutSec` must be 30–3600 when the test runs in the sandbox (refused otherwise: `invalid -TimeoutSec`); any positive number with `-OnHost`, as today.

**`verify` output.** Unchanged fields plus, in `test`:

*   `where`: `sandbox` or `host`. Always present.
*   `setup`: `null` when the test ran (or timed out). Otherwise `{status, message, proposal}`:
    *   `status: environment-missing`, with `message` and `proposal` copied from `-SandboxRun` at the time of the run (a snapshot; the lead runs `-SandboxEnv` again before acting on it);
    *   `status: sandbox-error`, with `message` the `error` text of `delegate.ps1` (or `delegate.ps1 did not finish` / `delegate.ps1 printed no JSON`), and `proposal: null`.

When `setup` is not `null`, `passed` is `false`, `exitCode` is `-1` and `tail` is `setup.message`. `exitCode` stays an integer in every case, so existing readers keep working. The same `test` object is stored in `state.json` under the task's `verify`.

`schemas/verify.schema.json` adds `where` (required, enum) and `setup` (required, `null` or the object above).

### Rules

*   **The sandboxed run.** `verify` builds the wrapper it uses today (`$ErrorActionPreference = 'Stop'`, the test command in a script block, output merged, `exit $LASTEXITCODE`), encodes it as UTF-16LE base64 the way `Invoke-TaskTestCommand` does, and runs:

    ```text
    pwsh -NoProfile -File <delegate.ps1> -SandboxRun -Repo <repo> -Worktree <worktree> -Feature <name>
         -Command "pwsh -NoProfile -NonInteractive -EncodedCommand <base64>; exit $LASTEXITCODE"
         -TimeoutSec <timeout>
    ```

    The sandbox's working folder is the worktree (the slot letter's root), so a relative path in the test command resolves as it does on the host. Nothing is written into the worktree. The base64 text keeps the command line free of quotes. Windows limits a command line to 32,767 characters, so a test command whose encoded wrapper would make the `delegate.ps1` command line longer than 30,000 characters is refused before the run: `test command too long for a sandboxed run`.
*   **Which `delegate.ps1`.** `<skill dir>/../delegate/scripts/delegate.ps1`, as `doctor` finds it. When the environment variable `XAGENT_DELEGATE_SCRIPT` is set, that path is used instead. It exists so tests can use a fake, and is documented only in the tests.
*   **Waiting for `delegate.ps1`.** `verify` waits up to `<timeout> + 300` seconds (slot wait, grants and clean-up). Past that, it kills the process tree and reports `sandbox-error` with `delegate.ps1 did not finish`. It reads stdout as JSON (the last non-empty line). If none parses, it reports `sandbox-error` with `delegate.ps1 printed no JSON`.
*   **Mapping.** `ok: false` -> `sandbox-error`. `status: environment-missing` -> that setup. `status: ran` -> `passed = (exitCode = 0)`. `status: timeout` -> `passed: false`, `exitCode: -1`, and the tail ends with `timed out after <timeout> s`. `test.tail` is `-SandboxRun`'s `tail` (its last 40 lines), never `output`.
*   **`-SandboxRun -Worktree` checks**, in order, each failing with `{ok: false, error}`:
    *   the path exists: `sandbox: worktree not found: <path>`;
    *   `git -C <path> rev-parse --show-toplevel` equals the path, and `--git-common-dir` resolves to `-Repo`'s: `sandbox: <path> is not a worktree of <repo>`;
    *   the path is not `-Repo` itself: `sandbox: -Worktree must not be the repo's own checkout`.

    Then the readiness gate runs at the worktree's `HEAD`, environments are linked with `Add-SandboxEnvLinks` (an existing link is replaced, as for a worker relaunch), and the command runs with `Invoke-SandboxCommand`. The links and the worktree stay afterwards.
*   **One helper.** The probe form and the `-Worktree` form call one function in `delegate.ps1` that takes the worktree path, a run name and a flag saying whether the worktree is a probe. It runs the gate, links, runs, and in its `finally` unlinks and removes the worktree **only** when the flag says probe and the path's leaf starts with `.probe-`. The pid file is written before that function is called and removed in an outer `finally`.
*   **Host runs.** `verify -OnHost -Quote "<q>"` first logs the decision as `feature.ps1 decision -Kind decision -Text "<task>: test run on the host, approved: <q>"` would (same line, same commit rule), then runs the test exactly as today with `where: host`. A phase test run on the host is logged by the lead with `feature.ps1 decision -Kind decision -Text "phase <n>: test run on the host, approved: <q>"` before it runs in `<repo>`.
*   **Cap.** A sandboxed `verify` and a phase test run through `-SandboxRun -Feature <name>` count toward the cap of 2. The lead follows the cap rule before each. `verify -OnHost` and a host phase test do not take a slot and do not count.

### Files

| File | Change | Why |
|---|---|---|
| `skills/delegate/scripts/delegate.ps1` | `-Worktree` and `-Feature` in the `SandboxRun` set; the worktree checks; the shared helper; the pid file; `tail` in the output. | D3, D4, D5. |
| `skills/delegate/scripts/Sandbox.psm1` | `Invoke-SandboxCommand` also returns `tail` (a `-Last` reading of the same two files, beside `Get-SandboxCommandOutputLines`). | The lead and `verify` judge a failure from the end of the output. |
| `skills/delegate/tests/DelegateLaunch.Tests.ps1` | `-SandboxRun -Worktree` tests: the refusals (no container needed), and a container test (tagged `Sandbox`, skipped as the existing ones are) that runs a command in an existing worktree with an uncommitted file, reads it, checks the exit code, and checks that the worktree and the file remain and the pid file is gone. With `-Feature`, the command sleeps a few seconds while the test, on the host, finds `<repo>\.xagent\runs\probe-*.pid` with the three fields; the file is gone after the run. | Covers the new parameter. |
| `skills/delegate/tests/Sandbox.Tests.ps1` | Unit tests for the `tail` reading: fewer than 40 lines, more than 40 across stdout and stderr, a line over 400 characters. | Covers `tail`. |
| `skills/feature/scripts/feature.ps1` | `verify` runs through `delegate.ps1 -SandboxRun -Worktree` by default; `-OnHost` / `-Quote`; `XAGENT_DELEGATE_SCRIPT`; `where` and `setup`; the decision line for host runs. | G1–G4, D2. |
| `skills/feature/schemas/verify.schema.json` | `where`, `setup`. | Output contract. |
| `skills/feature/tests/fixtures/fake-delegate.ps1` | New. Accepts the `-SandboxRun` parameters and runs `-Command` with `pwsh` in `-Worktree`, printing `-SandboxRun`'s JSON. The environment variable `XAGENT_FAKE_SANDBOX` selects `ran` (default), `environment-missing`, `error` (prints `{ok:false, error:"sandbox: fake"}`, exit 1), `nojson` or `timeout`. | Lets `verify` be tested without a container or a repo outside the profile. |
| `skills/feature/tests/feature.Tests.ps1` | The existing `verify` tests set `XAGENT_DELEGATE_SCRIPT` to the fake. New tests: each mapping row; `-OnHost` with and without `-Quote` and the logged decision; `-Quote` alone refused; the `-TimeoutSec` range; nothing new in the worktree after a sandboxed run; the too-long refusal. | Covers the new behaviour; existing tests keep their meaning. |
| `skills/feature/stages/build.md` | Verify step: follow the cap rule first; read `test.setup` before `test.passed` (environment-missing -> `-SandboxEnv -Apply` flow, then verify again, not a failed round; sandbox-error -> problem stop); the host fallback (read `tail`; when it looks like a sandbox limit, ask the user, quoting the lines, and on a yes run `verify -OnHost -Quote`). Phase end and "merge main": always `-SandboxRun -Base feature/<name> -Feature <name>`; on `environment-missing`, run the `-SandboxEnv -Apply` flow and run again; host fallback as for verify, logged by the lead. | D1, D2, D5, D6. |
| `skills/feature/SKILL.md` | The cap rule counts sandboxed `verify` and phase test runs. | D5. |
| `skills/delegate/SKILL.md` | The `-SandboxRun` row names `-Worktree` and `-Feature`; the Environments paragraph says the `feature` skill runs task and phase tests through it in every repo. | Docs. |
| `docs/test-plan.md`, `docs/HANDOFF.md` | Results row and state, by the lead at sign-off. | Records. |

### Phases

| Phase | Tasks | Test |
|---|---|---|
| 1 | `sbrun-worktree` (`delegate.ps1`, `Sandbox.psm1` and their tests). Its phase test is the delegate tests, so under D1 it asks for a host run (expected) | `pwsh -NoProfile -File scripts/test.ps1 -Path skills/delegate/tests` |
| 2 | `verify-sandbox` (`feature.ps1`, schema, fake, `feature.Tests.ps1`); `build-docs` (`build.md`, both `SKILL.md` files) | `pwsh -NoProfile -File scripts/test.ps1 -Path skills/feature/tests` |

`build-docs` depends only on the interfaces fixed above, so it runs in parallel with `verify-sandbox`. Phase 2's test runs in the sandbox under the new phase rule, which exercises D1 on this repo.

### Verification

At sign-off, besides the full suite on the host:

1.  This feature's own phase 2 tasks are checked by the new `verify` (after phase 1 merges, the build uses the new code from `feature/sandbox-verify`): `where: sandbox` and `passed: true` for each.
2.  A task test that reads a file outside the worktree (for example `Get-Content $env:USERPROFILE\.gitconfig`) fails in the sandbox with an access error. No scratch feature is needed: run `verify` against a throwaway task record in a scratch repo on `D:\`.
3.  `verify -OnHost -Quote` on the same task passes and leaves its decision line.
4.  A phase test of a repo with Python projects (the private repo) still passes through `-SandboxRun`.
