# `sandbox-verify`: run a worker's tests inside the sandbox

*   **Author:** Eugene Chin
*   **Status:** Draft
*   **Date:** 2026-11-19

--------------------------------------------------------------------------------

## Overview

Since `worker-sandbox` (`docs/designs/worker-sandbox.md`), every Cursor worker runs in a Windows AppContainer that can reach its worktree, the parts of `.git` it needs, its run home and a fixed read list, and nothing else on disk. Since `sandbox-env` (`docs/designs/sandbox-env.md`), the phase test of a repo with Python projects also runs in the sandbox, through `delegate.ps1 -SandboxRun`.

One step still runs a worker's code with the user's full rights: the lead's acceptance check of each task. `feature.ps1 verify` starts the task's test command with `pwsh` on the host, in the worker's worktree. The test command runs whatever the worker wrote: the code under test, the test files, and any helper script the worker added. A worker that wrote harmful code, on purpose or by mistake, gets it run on the host during the build, before the lead reviews it.

This feature moves that run into the sandbox, so code a worker wrote runs only inside a container until the lead has reviewed and merged it.

## The Problem

*   **`verify` undoes the sandbox for every task.** The worker's run is contained, but `verify` runs the worker's test command on the host as the user. Anything the sandbox blocks, such as reading the user's profile, other repos or credentials, or writing anywhere on disk, the test command can do there. The feature's plan fixes only the test command line; the worker chooses the test files and helper scripts it runs.
*   **It happens before review.** The build stage runs `verify` before the lead reads the diff in detail, so the lead's review is not a guard.
*   **The phase test has the same gap in repos without Python projects.** `stages/build.md` runs the phase test through `-SandboxRun` only when the repo has Python projects. Every other repo, this one included, runs the phase test in the user's checkout on the host. Unlike `verify`, the phase test runs code the lead has already reviewed and merged.
*   **Not every test can run in a container.** This repo's own suite creates AppContainers, maps drive letters and writes Pester's test registry (`HKCU\Software\Pester`). None of that works inside a container. Its container tests already skip themselves when they detect one (`Get-LaunchSkipReason -Kind Sandbox`), and `scripts/test.ps1` turns the test registry off. Other repos may have tests that need the host for reasons the skills cannot predict.
*   **Measured (2026-11-19).** `scripts/test.ps1 -Fast -Path skills/feature/tests` through `-SandboxRun` passed 228 tests, skipped 1 (a container test) and took 604 s. On the host it passed 229 and took 531 s. So this repo's task tests already run in the sandbox, about 14% slower. The delegate skill's tests (`-Path skills/delegate/tests`) are different: 165 passed and 4 failed in the sandbox, because they start `delegate.ps1` itself, which reaches the real `D:\` and the user's temp folder. Those tests need the host.

## Goals

*   **G1.** `feature.ps1 verify` runs the task's test command in the sandbox, in the worker's own worktree with its uncommitted changes, with the same environments a worker gets (`sandbox-env` links for Python projects).
*   **G2.** The result keeps its current shape (`test.passed`, `exitCode`, `tail`), so `stages/build.md` reads it unchanged, and it records whether the test ran in the sandbox.
*   **G3.** A test that cannot run in the sandbox never falls back to the host silently. Running on the host needs the user's approval, given for that one run (D2).
*   **G4.** The harness adds nothing to the worktree beyond what a worker launch already adds (the run home under `.xagent\sandbox\`, which git excludes, and the `.venv` links of `sandbox-env`), and the scope check (`changed`, `outOfScope`) sees the worker's files and nothing the harness added. Today, in a Python repo whose `.gitignore` does not list `.venv`, those links show up as untracked: the scope check reports them as out of scope and the merge step stops on them. This feature adds `.venv` to the repo's `.git/info/exclude` when links are made, as `delegate.ps1` already does for `.xagent/`.

## Non-Goals

*   **Pester's test registry in the sandbox.** It stays a documented workaround (`TestRegistry.Enabled = $false`, see the delegate skill's sandbox limits).
*   **Sign-off's full test run.** It runs merged, reviewed code on `main`'s way in, and in this repo it needs the host (containers, drive letters). Unchanged.
*   **Running tests with no network.** The sandbox keeps internet access, as for workers.
*   **Other agents.** Only Cursor workers are sandboxed today; `verify` follows the same rule.

## Open Questions

None. Whether phase tests also move to the sandbox, and how long a host approval lasts, were decided by the author on 2026-11-19 (D1 and D2 below).

## Technical Plan

### Terms from the existing skills

*   **Readiness gate** (`docs/designs/sandbox-env.md`, Rules): before a sandboxed run, `Test-SandboxEnvReady` checks that every Python project at the commit has a built environment. If not, the run does not start and reports `environment-missing` with a build proposal.
*   **Cap rule** (`skills/feature/SKILL.md`): at most 2 `delegate.ps1` runs of one feature at a time. `feature.ps1 schedule` reports `cap` and `liveRuns`; `liveRuns` is `Get-LiveDelegateRunCount`, which counts live `*.pid` files under `<repo>\.xagent\runs` whose `feature` matches. Worker runs, review lenses and council seats already write such files. This design adds `-SandboxRun` to the same counter.
*   **Problem stop** (`skills/feature/stages/build.md`): the build pauses, a `[stop]` decision is logged, and the lead reports to the user and waits.
*   **Size gate** (`skills/delegate/SKILL.md`, "Goldfish preflight"): before a task launches, a reviewer estimates its size and checks that its acceptance command runs only the task's own tests. Task tests are therefore narrow, usually one test file or a filter.

### Decisions

| # | Decision | Why |
|---|---|---|
| D1 | The phase test runs in the sandbox in **every** repo, through `-SandboxRun`, not only in repos with Python projects. | Author's choice: one rule for both test steps. Reconfirmed after review (2026-11-20), knowing that in this repo a phase whose test includes the delegate tests will ask for a host run (see the Problem section). |
| D2 | A test runs on the host only after the user approves that one run. The approval is never remembered: not for the task, the feature or the repo. | Author's choice: the protection never lapses. In this repo the task tests measured pass in the sandbox; a repo whose task tests need the host asks at every task (see Risks). |
| D3 | `verify` runs the test in the worker's **existing** worktree, not in a fresh one. | The test must see the worker's uncommitted changes, which is what `verify` checks today. A fresh worktree at a commit (what `-SandboxRun` does now) would test nothing the worker wrote. |
| D4 | `feature.ps1` reaches the sandbox only through `delegate.ps1 -SandboxRun`, with a new `-Worktree` parameter. | All sandbox code stays in the delegate skill, which already owns slots, grants and environment links. `feature.ps1` only locates `delegate.ps1` today (`doctor` checks that it exists); this is its first call into it. |
| D5 | A sandboxed `verify` counts toward the feature's cap of 2 runs. | It takes a sandbox slot, and there are only two. If it did not count, `schedule` could start a second worker while `verify` waits, and one of them would time out waiting for a slot. |
| D6 | The skills do not guess whether a failure was caused by the sandbox. The lead reads the output and asks the user. | An exit code cannot tell "access denied by the sandbox" from a real bug, and a wrong guess either hides a bug or runs code on the host without approval. |

### Components

*   **`delegate.ps1 -SandboxRun -Worktree <path>`** (new parameter). Runs the command in an existing worktree of `-Repo` instead of creating a `.probe-<hex>` worktree. The readiness gate uses the worktree's `HEAD`, as a worker launch does. Python environments are linked as for a worker and are left in place afterwards (the worktree's own `-Cleanup` removes them). The worktree is not removed. Both `-SandboxRun` forms go through one helper in `delegate.ps1` (readiness gate, linking, the run); only how the worktree is obtained and the `finally` differ, and only the probe form removes a worktree. With `-Feature <name>`, the run writes a pid file like a worker run's, so `feature.ps1 schedule` counts it (D5). The output keeps its fields, `{ok, status, exitCode, output, seconds, notes}` plus `message`, `projects` and `proposal` for `environment-missing`, and gains `tail`: the **last** 40 lines of stdout then stderr (`output` stays the first 40).
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
         environment-missing -> test {passed: false, where: sandbox, setup: {...}}
         sandbox: error   -> test {passed: false, where: sandbox, setup: {status: sandbox-error, message, proposal: null}}
  -> lead:
       setup environment-missing -> -SandboxEnv -Apply (ask only if the proposal says so), verify again
       setup sandbox-error       -> problem stop (as for any sandbox: error)
       passed false              -> read tail; a code failure is a failed review round (unchanged);
                                    a sandbox limit -> ask the user -> verify -OnHost -Quote "<yes>"
```

### Flow of a phase test

The phase test follows the same flow at `feature/<name>`, through `-SandboxRun -Repo <repo> -Base feature/<name> -Feature <name> -Command "<phase test>" -TimeoutSec 3600` (the timeout phase tests use today; a fresh worktree fits here, because the phase test runs merged code). The lead reads `status`, `exitCode` and `tail` directly; there is no `verify` record for a phase, today or after this feature. When the lead judges a failure to be a sandbox limit, it asks the user, quoting the failing lines. On a yes it logs `feature.ps1 decision -Kind decision -Text "host run: phase <n>, approved: <user's words>"`, then runs the phase test command in `<repo>` on `feature/<name>`, as phase tests ran before this feature. That decision line is the only record of a host phase run.

## Alternatives Considered

### Run the test in a fresh worktree at a commit of the worker's changes

The lead would commit the worker's changes first (or `verify` would stash them into a temporary commit) and run `-SandboxRun -Base <that commit>` as it does today.

*   **Pros:** no change to `-SandboxRun`; the run cannot touch the worker's worktree.
*   **Cons:** `verify` runs before the lead commits, and the build stage's review rounds resume the worker in the same worktree. A temporary commit changes the worktree's history under the worker, and copying the changes adds a second place for files to differ.
*   **Reason for rejection:** a temporary commit rewrites the worktree's history under a worker that may be resumed there; running in the existing worktree (D3) tests exactly what the worker left, with no extra commit.

### Remember a host approval for the feature or the repo

*   **Pros:** fewer questions for a repo whose tests always need the host.
*   **Cons:** once given, later tasks run worker code on the host without anyone looking, which is the gap this feature closes.
*   **Reason for rejection:** a remembered approval reopens the gap for every later task, and the author chose per-run approval (D2).

### Approve a test command for host runs instead of one run

The user would approve the plan's test command string once (say, at the first host run in a repo), and later runs of that exact command would go to the host without asking.

*   **Pros:** one question per command instead of one per run.
*   **Cons:** the command is fixed by the plan, but what it runs is not: `pwsh -File scripts/test.ps1` runs whatever test files and helpers the worker changed. Approving the command approves running every later worker's code on the host.
*   **Reason for rejection:** it gives every later worker's code host access through an unchanged command line, the same exposure as "Remember a host approval for the feature or the repo" (D2).

### Detect sandbox failures automatically and retry on the host

`verify` would look for "access denied" in the output and rerun on the host.

*   **Pros:** no prompt.
*   **Cons:** a test can print "access denied" because of a real bug, and a sandbox failure can print anything. Either way, worker code runs on the host without approval.
*   **Reason for rejection:** no text pattern separates a sandbox limit from a bug, and a wrong match runs worker code on the host unapproved (D6).

### Keep phase tests on the host outside Python repos

*   **Pros:** no change to the phase step for most repos, and no 14% slowdown there.
*   **Cons:** two rules for two test steps; a repo stays unprotected because it has no Python projects, not because it needs the host.
*   **Reason for rejection:** the phase test would stay unprotected in a repo for a reason unrelated to whether it needs the host; the author chose one rule (D1).

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Slower checks: about 14% measured on this repo's feature tests (the time includes slot setup). | Accepted; task tests are kept narrow by the size gate. |
| `verify` waits for a slot while two workers run. | D5: it counts toward the cap, so the lead runs it only when a run slot is free. `Get-SandboxSlot` still times out after 60 s, which `verify` reports as `sandbox-error`. |
| A repo whose tests always need the host asks the user at every task. | Accepted (D2). The prompt shows the output, so the user can instead fix the repo's tests or the sandbox read list. |
| The test can read Cursor's login copy. `New-SandboxRun` (`skills/delegate/scripts/Sandbox.psm1`, its `Copy-SandboxLoginFile` calls) copies `cli-config.json`, `auth.json` and `.gitconfig` into every run's home `<worktree>\.xagent\sandbox\home`, including plain `-SandboxRun` commands, and `Stop-SandboxRun` deletes `auth.json` afterwards. | No new exposure: the worker that wrote the code already ran with the same copy in the same home. Unchanged by this feature. These files are under `.xagent\`, which git excludes. |
| In this repo, a phase whose test includes the delegate tests fails in the sandbox and asks for a host run (D1, D2). | Accepted by the author. The lead shows the failing lines; the approval covers that one run. |
| A test writes files into the worktree. | Unchanged from today: the scope check runs first, and the lead's review reads the diff. |
| `.venv/` in the repo's shared `.git/info/exclude` also hides the user's own untracked `.venv` folders from `git status`, in their checkout and every worktree. | Accepted: a `.venv` is never meant to be committed, and `.git/info/exclude` is local to the machine (never pushed). The user can delete the line. |
| `verify` gets `sandbox-error` because both slots were busy for 60 s (`no free slot`). | Not a problem stop: the lead waits for a live run of the feature to end (the cap rule) and runs `verify` again once. A second failure is a problem stop. |
| `verify` kills a `delegate.ps1` that did not finish. | Its pid file stays, but `Get-LiveDelegateRunCount` checks that the pid is alive with the same start time, so it stops counting. The slot is freed by `Get-SandboxSlot`'s dead-process recovery on the next run. The `runs\probe-<hex>\` folder holds only logs. |
| `XAGENT_DELEGATE_SCRIPT` makes `verify` run a different script on the host. | Whoever can set the lead's environment can already change `PATH` or `pwsh` itself. It is documented in the delegate skill as a test-only override. |

## Detailed Implementation Plan

### Probes

None needed. The one open fact, whether this repo's own task tests run inside the sandbox, was measured before the design (see the Problem section). The `-SandboxRun` machinery, slot handling and environment links are from `sandbox-env` and unchanged.

### Data

**`delegate.ps1 -SandboxRun` parameters.** Today's set (`-Repo`, `-Base`, `-Command`, `-TimeoutSec`) gains:

*   `-Worktree <path>`: an existing worktree of `-Repo`. Cannot be combined with `-Base` (refused: `-Worktree cannot be used with -Base`). `-Base` has a default of `HEAD`, so the check is `$PSBoundParameters.ContainsKey('Base')`.
*   `-Feature <name>`: the same pattern as on worker runs. Written to the pid file.

**Output** keeps today's fields, `{ok, status, exitCode, output, seconds, notes}` plus `message`, `projects` and `proposal` when `status` is `environment-missing`, and gains `tail` for `ran` and `timeout`: the last 40 lines of the run's `stdout.txt` followed by `stderr.txt`, each line cut at 400 characters (the same reading `output` uses, from the other end). A refused call or a `sandbox:` error is `{ok: false, error}` with exit 1, as today.

**Pid file.** Every `-SandboxRun` with `-Feature` writes `<repo>\.xagent\runs\probe-<hex>.pid`, beside the run folder and not inside it (`Invoke-SandboxCommand` deletes and recreates `runs\probe-<hex>\` when it starts; both names use the same `<hex>`), holding `{pid, startTime, feature}` (`pid` and `startTime` of the `delegate.ps1` process, `startTime` in UTC ISO 8601 as on worker runs). It is written before the slot is taken and deleted in a `finally`. `feature.ps1`'s `Get-LiveDelegateRunCount` already counts any `*.pid` under `.xagent\runs` with those three fields, so `schedule` needs no change. Without `-Feature`, no pid file is written.

**`feature.ps1 verify` parameters.** Today's (`-Repo`, `-Name`, `-Task`, optional `-TimeoutSec`) plus:

*   `-OnHost`: run the test on the host as today. Requires `-Quote`; without it, refused: `-OnHost requires -Quote with the user's approval`.
*   `-Quote "<user's words>"`: one line. `feature.ps1` already declares `-Quote` (the `gate` command requires it), so no new parameter is added; `verify` refuses it without `-OnHost` (`-Quote requires -OnHost`), and `gate` is unchanged.
*   `-TimeoutSec` must be 30–3600 when the test runs in the sandbox (refused otherwise: `invalid -TimeoutSec`); any positive number with `-OnHost`, as today.

**`verify` output.** Unchanged fields plus, in `test`:

*   `setup.status` values: `environment-missing`, `slot-busy` (the `delegate.ps1` error starts with `sandbox: no free slot`, the text `Get-SandboxSlot` throws after 60 s), and `sandbox-error` (any other failure). The lead branches on `setup.status`, never on `setup.message`.
*   `where`: `host` only for `verify -OnHost`. Every other result, including one where the sandbox could not start the test (`setup` not `null`), is `sandbox`. Always present.
*   `setup`: `null` when the test ran (or timed out). Otherwise `{status, message, proposal}`:
    *   `status: environment-missing`, with `message` and `proposal` copied from `-SandboxRun` at the time of the run (a snapshot; the lead runs `-SandboxEnv` again before acting on it);
    *   `status: sandbox-error`, with `message` the `error` text of `delegate.ps1` (or `delegate.ps1 did not finish` / `delegate.ps1 printed no JSON`), and `proposal: null`.

When `setup` is not `null`, `passed` is `false`, `exitCode` is `-1` and `tail` is the empty string: `tail` only ever holds test output, and the reason is in `setup.message`. A result with `setup` is still a successful `verify` (`ok: true`, exit 0), like a failing test; only refusals before the scope check are `{ok: false, error}`. They run in this order, so today's tests keep their messages: `-TimeoutSec` (today's check and message, extended with the 30–3600 range for sandboxed runs), `-OnHost`/`-Quote` pairing, the task's worktree (today's checks), the `delegate.ps1` path (sandboxed only), the command length (sandboxed only), and the host-run decision (`-OnHost` only). `exitCode` stays an integer in every case, so existing readers keep working. The same `test` object is stored in `state.json` under the task's `verify`.

`schemas/verify.schema.json` adds `where` (required, enum) and `setup` (required, `null` or the object above, `status` an enum of the three values).

**Environment inputs and uncommitted changes.** The readiness gate and the environment links follow the worktree's `HEAD`, as for a worker launch: environments are built from committed `uv.lock`, `pyproject.toml`, `requirements*.txt` and `.python-version` files. A task whose diff changes any of those files is tested against environments that do not match it. The lead sees this from `changed` (`verify` lists the files) and handles it before trusting the result: it commits the worker's changes on the task branch (the commit it makes at merge anyway), runs `-SandboxEnv -Repo <repo> -Base xagent/<task> -Apply` (asking only when `proposal.needsApproval` is true), and runs `verify` again. The plan stage keeps environment-input changes in their own small task where it can.

### Rules

*   **One wrapper.** The wrapper text `Invoke-TaskTestCommand` builds today (`[Console]::OutputEncoding` set to UTF-8, `$ErrorActionPreference = 'Stop'`, `$global:LASTEXITCODE = 0`, the test command in a script block with output merged into strings, `catch` printing the error and exiting 1, then `exit $LASTEXITCODE`) moves into one function, `New-TaskTestWrapper -TestCommand <cmd>`, which returns its UTF-16LE base64 encoding. `Invoke-TaskTestCommand` (the host path) and the sandboxed path both call it, so a test behaves the same under `where: sandbox` and `where: host`.
*   **The sandboxed run.** `verify` gets the encoded wrapper from `New-TaskTestWrapper` and runs:

    ```text
    pwsh -NoProfile -File <delegate.ps1> -SandboxRun -Repo <repo> -Worktree <worktree> -Feature <name>
         -Command "pwsh -NoProfile -NonInteractive -EncodedCommand <base64>; exit $LASTEXITCODE"
         -TimeoutSec <timeout>
    ```

    The process is started with `[Diagnostics.ProcessStartInfo]` and each argument added to its `ArgumentList` collection, one item per argument, so .NET quotes them; the `-Command` value is one item. The `-Command` value is built from single-quoted PowerShell strings plus the base64 text, so the host never expands `$`: the inner shell does. Its exact text is `[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); pwsh -NoProfile -NonInteractive -EncodedCommand <base64>; exit $LASTEXITCODE`. The first statement makes the sandbox's outer `pwsh` pass the inner shell's UTF-8 output through unchanged; without it the outer shell re-encodes it in the console code page and non-ASCII text in `tail` is garbled. `RedirectStandardOutput` and `RedirectStandardError` are on; `StandardOutput.ReadToEndAsync()` and `StandardError.ReadToEndAsync()` start right after `Start()`, so a full pipe cannot block. `verify` calls `WaitForExit(<ms>)`; when it returns true, it calls `WaitForExit()` with no argument so both reads finish, then takes their results.

    The sandbox's working folder is the worktree (the slot letter's root), so a relative path in the test command resolves as it does on the host. `verify` writes no file into the worktree; the sandbox writes only its run home under `.xagent\sandbox\`, as for every sandboxed run. The base64 text keeps the inner command free of quotes. Windows limits a command line to 32,767 characters, so a test command whose encoded wrapper would make the `delegate.ps1` command line longer than 30,000 characters is refused before the scope check, like `verify`'s other refusals: `{ok: false, error: "test command too long for a sandboxed run"}`, exit 1. UTF-16LE base64 is about 2.7 characters per wrapper character, so the limit is a test command of roughly 10,000 characters. The acceptance commands in `docs/features/sandbox-env/feature.json` are all under 400 characters.
*   **Which `delegate.ps1`.** `scripts/delegate.ps1` under the `delegate` skill folder beside the `feature` skill folder (`<skill dir>/../delegate`, the same path `doctor` checks). When the environment variable `XAGENT_DELEGATE_SCRIPT` is set, that path is used instead, with no fallback to the default path, so tests can use a fake. If the chosen file does not exist, `verify` refuses before the scope check: `{ok: false, error: "delegate.ps1 not found: <path>"}`, exit 1.
*   **`.venv` links and git.** Whenever `delegate.ps1` links environments into a worktree (a worker launch or `-SandboxRun`), it first makes sure the repo's shared `.git/info/exclude` has the line `.venv/`, appending it once, the same way it keeps `.xagent/` there. This is one small function in `delegate.ps1` (`Add-DelegateVenvExclude`), called immediately before each `Add-SandboxEnvLinks` call, inside the same "some project is `ready`" condition. After this feature there are two such calls: in the shared `-SandboxRun` helper (both forms) and in the worker launch. `SandboxEnv.psm1` is not changed. When the file's current text is not empty and does not end with a newline, the function writes a newline before the line, so the entry is never glued to the previous one. Two runs racing can both append the line; a duplicate line in `exclude` is harmless. git then hides the links (and any untracked `.venv` folder) from `git status`, the scope check and the merge step. A tracked `.venv` is unaffected; `sandbox-env` already refuses to link over a real `.venv` folder.
*   **Waiting for `delegate.ps1`.** `verify` waits up to `<timeout> + <grace>` seconds (slot wait, grants and clean-up). `<grace>` is 300, or the value of the environment variable `XAGENT_VERIFY_GRACE_SEC` when it is a positive integer (tests use it to reach this branch quickly). Past that, it kills the process tree and reports `sandbox-error` with `delegate.ps1 did not finish`. It reads stdout as JSON (the last non-empty line). If none parses, it reports `sandbox-error` with `delegate.ps1 printed no JSON`.
*   **Mapping.** `ok: false` -> `sandbox-error`. `status: environment-missing` -> that setup. `status: ran` -> `passed = (exitCode = 0)`. `status: timeout` -> `passed: false`, `exitCode: -1`, and `verify` appends the line `timed out after <timeout> s` to the tail (as `Invoke-TaskTestCommand` does on the host). `-SandboxRun`'s `tail` is a JSON array of strings, like `output`; `test.tail` is a single string: the timeout line, when there is one, is added as one more array element, and the array is joined with `\n` (so an empty capture gives just that line). It is never built from `output`. The two paths read lines differently: the host path keeps today's reader (lines split on `\n`, no length cut), and the sandboxed path's lines are cut at 400 characters. This difference is accepted; the end of the output, where failures appear, is the same.
*   **Path comparison.** `-Worktree` arrives with forward slashes (`state.json` stores worktrees that way). Before any check, `delegate.ps1` normalizes `-Worktree` and every path it is compared against with this rule (new; the worker-launch safety check only swaps slashes and trims): `[IO.Path]::GetFullPath`, `/` replaced by `\`, trailing `\` trimmed, compared with `[string]::Equals(a, b, OrdinalIgnoreCase)`. `--git-common-dir` names a `.git` folder: a relative value is joined to the worktree path, and the result must equal `-Repo`'s own `--git-common-dir`, resolved the same way.
*   **`-SandboxRun -Worktree` checks**, in order, each failing with `{ok: false, error}`:
    *   the path exists: `sandbox: worktree not found: <path>`;
    *   `git -C <path> rev-parse --show-toplevel` equals the path, and `--git-common-dir` resolves to `-Repo`'s: `sandbox: <path> is not a worktree of <repo>`;
    *   the path is not `-Repo` itself: `sandbox: -Worktree must not be the repo's own checkout`.

    Then the readiness gate runs at the worktree's `HEAD`, environments are linked with `Add-SandboxEnvLinks` (an existing link is replaced, as for a worker relaunch), and the command runs with `Invoke-SandboxCommand`. The links and the worktree stay afterwards.
*   **One helper.** The probe form and the `-Worktree` form call one function in `delegate.ps1` that takes the worktree path, a run name and a flag saying whether the worktree is a probe. It runs the gate, links, runs, and in its `finally` unlinks and removes the worktree **only** when the flag says probe and the path's leaf starts with `.probe-`. The pid file is written before that function is called and removed in an outer `finally`. Both forms make `<hex>` the same way (`[guid]::NewGuid().ToString('N').Substring(0, 8)`), use the run name `probe-<hex>` (logs in `runs\probe-<hex>\`) and the pid file `runs\probe-<hex>.pid`; only the probe form also uses `<hex>` in its worktree name `.probe-<hex>`.
*   **Host runs.** The body of `Invoke-DecisionFeature` (feature lock, `Assert-OnFeatureBranch`, append the line, commit) moves into a function `Add-FeatureDecision -Repository -FeatureName -Kind -Text` that returns the line and throws on any failure; `Invoke-DecisionFeature` calls it and then prints its output as today. `verify -OnHost -Quote "<q>"` calls `Add-FeatureDecision -Kind decision -Text "host run: <task>, approved: <q>"` before anything else runs. If it throws (not on `feature/<name>`, the lock is held, the commit fails), `verify` prints `{ok: false, error}`, exits 1, and runs no test: a host run never happens without its line. Then it runs the test exactly as today, with `where: host`. A phase test run on the host is logged by the lead with `feature.ps1 decision -Kind decision -Text "host run: phase <n>, approved: <q>"` before it runs in `<repo>`.
*   **Cap.** A sandboxed `verify` and a phase test run through `-SandboxRun -Feature <name>` count toward the cap of 2. The lead follows the cap rule before each. `verify -OnHost` and a host phase test do not take a slot and do not count.

### Files

| File | Change | Why |
|---|---|---|
| `skills/delegate/scripts/delegate.ps1` | `-Worktree` and `-Feature` in the `SandboxRun` set; the worktree checks; the shared helper; the pid file; `tail` in the output; `.venv/` in `.git/info/exclude` when environments are linked. | D3, D4, D5. |
| `skills/delegate/scripts/Sandbox.psm1` | `Invoke-SandboxCommand` also returns `tail`: a string array of the last 40 lines of the same two files (stdout then stderr), each cut at 400 characters, from a new function beside `Get-SandboxCommandOutputLines`. | The lead and `verify` judge a failure from the end of the output. |
| `skills/delegate/tests/DelegateLaunch.Tests.ps1` | `-SandboxRun -Worktree` tests: the refusals (no container needed), and a container test (tagged `Sandbox`, skipped as the existing ones are) that runs a command in an existing worktree with an uncommitted file, reads it, checks the exit code, and checks that the worktree and the file remain and the pid file is gone. For `.venv`: in a repo made from the `sandbox-env` fixture with its environment built first (`-SandboxEnv -Apply`, as the existing test `links a ready environment and omits .venv from changes` does), a `-Worktree` run leaves `.venv/` in `.git/info/exclude` exactly once (also when the file did not end with a newline) and `git status --porcelain` of the worktree shows no `.venv`; in the same repo before the build, the run reports `environment-missing` and does not write the line. With `-Feature`, the command sleeps a few seconds while the test, on the host, finds `<repo>\.xagent\runs\probe-*.pid` with the three fields; the file is gone after the run. | Covers the new parameter. |
| `skills/delegate/tests/Sandbox.Tests.ps1` | Unit tests for the `tail` reading: fewer than 40 lines, more than 40 across stdout and stderr, a line over 400 characters. | Covers `tail`. |
| `skills/feature/scripts/feature.ps1` | `verify` runs through `delegate.ps1 -SandboxRun -Worktree` by default; `-OnHost` / `-Quote`; `XAGENT_DELEGATE_SCRIPT`; `where` and `setup`; the decision line for host runs. | G1–G4, D2. |
| `skills/feature/schemas/verify.schema.json` | `where`, `setup`. | Output contract. |
| `skills/feature/tests/fixtures/samples/verify.json` | Add `"where": "sandbox"` and `"setup": null` to `test`; add a second sample `verify-setup.json` with `setup` filled (`environment-missing`, a message, a proposal object), `passed: false`, `exitCode: -1`, `tail: ""`. The `schemas` Describe in `feature.Tests.ps1` lists its samples by name in `$validSamples`, so `verify-setup.json` is added to that list (`Get-SampleSchemaName` maps the `verify` prefix to `verify.schema.json`). | Keeps the schema test true and checks the new sample. |
| `skills/feature/tests/fixtures/fake-delegate.ps1` | New. Accepts the `-SandboxRun` parameters (`-SandboxRun`, `-Repo`, `-Worktree`, `-Feature`, `-Command`, `-TimeoutSec`) and prints one JSON line. The environment variable `XAGENT_FAKE_SANDBOX` selects the mode. `ran` (default): runs `-Command` with `pwsh -NoProfile -Command` in `-Worktree` and prints `{ok:true, status:"ran", exitCode:<its exit code>, output:<first 40 lines>, tail:<last 40 lines>, seconds:<n>, notes:[]}`. `timeout`: prints `{ok:true, status:"timeout", exitCode:null, output:["partial"], tail:["partial"], seconds:<TimeoutSec>, notes:[]}`. `environment-missing`: prints `{ok:true, status:"environment-missing", exitCode:null, output:[], seconds:0, message:"sandbox: environment not ready (fake)", projects:[], proposal:{needsApproval:false, text:"fake"}}`. `error`: prints `{ok:false, error:"sandbox: fake"}`, exit 1. `slot-busy`: prints `{ok:false, error:"sandbox: no free slot (both slots busy)"}`, exit 1. `nojson`: prints `not json`, exit 0. `hang`: sleeps 600 s (for the kill branch with `XAGENT_VERIFY_GRACE_SEC=5` and `-TimeoutSec 30`). It also records its own argument list to `<worktree>\..\fake-delegate-args.txt` (beside the worktree), so a test can check that `-Command` arrived as one argument ending in the literal text `exit $LASTEXITCODE`. | Lets `verify` be tested without a container or a repo outside the profile. |
| `skills/feature/tests/feature.Tests.ps1` | The `feature.ps1 verify` Describe sets `XAGENT_DELEGATE_SCRIPT` to the fake in `BeforeAll` and clears it in `AfterAll`. Existing tests, one by one: the six scope tests (`lists committed and uncommitted…`, `flags in-scope and out-of-scope…`, `puts untracked cache…`, `still lists tracked modified pyc…`, `counts untracked, ignores __pycache__…`, `serializes changed as JSON array…`) stay on the fake unchanged. `runs test command and records pass or fail…` and `captures hello in tail` stay on the fake and also assert `where: sandbox`; in its default `ran` mode the fake runs `-Command` with `pwsh` in `-Worktree` and reports that process's exit code as `exitCode` and its last 40 output lines as `tail`. `times out and kills process tree` moves to `-OnHost -Quote 'test'` (the host path keeps any positive `-TimeoutSec`) and also asserts the `host run:` decision line. `stores verify in state…` stays on the fake and asserts `where` and `setup` in `state.json`. `does not change worktree git status or HEAD` keeps its fake leg and gains an `-OnHost` leg. `fails without worktree and when folder missing` is unchanged. `computes changed before test writes out.txt` stays on the fake (its `ran` mode runs the command in the worktree, so `out.txt` is created after the scope check, as today). `fails invalid TimeoutSec, unknown task, missing Task` is unchanged and still passes, because the `-TimeoutSec` check stays first and keeps its message. New tests, all tagged `Slow` like the rest of the Describe: each mapping row (`ran` pass and fail, `timeout`, `environment-missing`, `error`, `slot-busy`, `nojson`, `hang` with the grace variable); a test command that prints a non-ASCII string (`Write-Output 'caf' + [char]0xE9`) whose `tail` contains it exactly (through the fake, and in the live test); `-OnHost` with and without `-Quote`; `-Quote` alone refused; `-OnHost` refused with no test run when the checkout is not on `feature/<name>`; the `-TimeoutSec` range for sandboxed runs; the fake's recorded arguments (one `-Command` item that starts with the `[Console]::OutputEncoding` statement and ends in the literal `exit $LASTEXITCODE`; `-Feature` equal to the feature name; `-Repo` and `-Worktree` equal to the test repo and the task's worktree; `-TimeoutSec` equal to the value passed to `verify`); `XAGENT_DELEGATE_SCRIPT` naming a missing file; nothing new in the worktree after a sandboxed run; the too-long refusal. | Covers the new behaviour; says what happens to every existing test. |
| `skills/feature/stages/build.md` | Verify step: follow the cap rule first; when `changed` includes an environment input (`uv.lock`, `pyproject.toml`, `requirements*.txt`, `.python-version`), follow "Environment inputs and uncommitted changes" before reading the result; read `test.setup.status` before `test.passed` (`environment-missing` -> run `-SandboxEnv -Apply`, asking only when `proposal.needsApproval` is true, then verify again, not a failed round; `slot-busy` -> wait for a live run of the feature to end, verify again once, and make a problem stop if it is `slot-busy` again; `sandbox-error` -> problem stop); the host fallback (read `tail`; when it looks like a sandbox limit, ask the user, quoting the lines, and on a yes run `verify -OnHost -Quote`). Phase end and "merge main": always `-SandboxRun -Base feature/<name> -Feature <name> -TimeoutSec 3600`; on `environment-missing`, run the `-SandboxEnv -Apply` flow (same `proposal.needsApproval` rule) and run again; on `ok: false` with an `error` starting `sandbox: no free slot`, wait and run again once, as for `slot-busy`; host fallback as for verify, logged by the lead. | D1, D2, D5, D6. |
| `skills/feature/SKILL.md` | The cap rule counts sandboxed `verify` and phase test runs. | D5. |
| `skills/delegate/SKILL.md` | The `-SandboxRun` row names `-Worktree`, `-Feature` and the `tail` field; a note that `XAGENT_DELEGATE_SCRIPT` is a test-only override read by `feature.ps1`; the Environments paragraph says the `feature` skill runs task and phase tests through it in every repo. | Docs. |
| `docs/test-plan.md`, `docs/HANDOFF.md` | Results row and state, by the lead at sign-off. | Records. |

### Phases

| Phase | Tasks | Test |
|---|---|---|
| 1 | `sbrun-worktree` (`delegate.ps1`, `Sandbox.psm1` and their tests). Runs under today's rules (see below) | `pwsh -NoProfile -File scripts/test.ps1 -Path skills/delegate/tests` |
| 2 | `verify-sandbox` (`feature.ps1`, schema, fake, `feature.Tests.ps1`); `build-docs` (`build.md`, both `SKILL.md` files) | `pwsh -NoProfile -File scripts/test.ps1 -Path skills/feature/tests` |

Phase 1 runs under today's rules: `verify` and the phase test still run on the host, because the new `verify` and the new phase rule land in phase 2 (and this repo has no Python project, so today's phase rule runs on the host without asking). Phase 2's own task checks also run on the host, because the new `verify` exists only once `verify-sandbox` merges. The first sandboxed run is phase 2's phase test (the feature tests, which pass in the sandbox as measured), run under the new rule once both tasks are merged. No host run is expected there.

Files per task: `sbrun-worktree` owns the four `skills/delegate/scripts` and `skills/delegate/tests` rows of the Files table; `verify-sandbox` owns `feature.ps1`, `verify.schema.json`, the two sample files, `fake-delegate.ps1` and `feature.Tests.ps1`; `build-docs` owns `build.md` and both `SKILL.md` files. The lead writes `docs/test-plan.md` and `docs/HANDOFF.md`.

`build-docs` depends only on the interfaces fixed above, so it runs in parallel with `verify-sandbox`.
### Verification

At sign-off, besides the full suite on the host. These are checks the lead runs on the host, not worker tasks:

1.  After `verify-sandbox` merges, and before its worktree is cleaned up, the lead runs the new `verify` on that task again (the skill runs from the checkout, which is on `feature/sandbox-verify`): `where: sandbox`, `passed: true`. Phase 2's phase test then runs through `-SandboxRun -Feature` and passes.
2.  A sandboxed `verify` of a test that reads a file outside the worktree fails with an access error, and the same `verify -OnHost -Quote` passes and logs its line.
3.  Run the phase test of a repo with Python projects (the lead's private Python repo used for `sandbox-env`'s live checks, or any repo with a `uv.lock`) through `-SandboxRun -Feature`; it passes when `status` is `ran` and `exitCode` is 0.

Check 2 is one `Live`-tagged test, `live sandbox verify`, written by the `verify-sandbox` task in its own `Describe 'live sandbox verify'` in `feature.Tests.ps1`, outside the `feature.ps1 verify` Describe, so the fake's `XAGENT_DELEGATE_SCRIPT` is never set for it (its `BeforeAll` also removes the variable if present, and `AfterAll` restores it). `scripts/test.ps1` excludes `Live`. Inside the `It`, it sets a local `$TestDrive` to a new folder `D:\xagent-tests-<8 hex>` (the drive of the repo under test), so `New-TestRepo` and `New-TaskWorktree` create the repo and worktree there instead of under the user profile, which the sandbox refuses; PowerShell's dynamic scoping makes the helpers see that local value. With the variable unset, the real `delegate.ps1` runs. Before shadowing `$TestDrive`, it writes `outside.txt` into Pester's real `TestDrive` (under the user profile, which the sandbox denies and the host can read) and builds the task's test command with that file's absolute path written into it: `pwsh -NoProfile -c "Get-Content -LiteralPath '<absolute path>'"`. It must not use `$env:USERPROFILE` inside the command: in the sandbox that variable names the run home, which holds a copy of `.gitconfig`. It asserts that sandboxed `verify` gives `where: sandbox`, `passed: false` and a `tail` that contains `denied`, then that `verify -OnHost -Quote 'live check'` gives `where: host`, `passed: true` and adds a `host run:` decision line. A `finally` removes the worktree and deletes the folder. It skips with a reason, using a self-contained check and no helper from `DelegateLaunch.Tests.ps1`: when `pwsh -NoProfile -File <delegate dir>/scripts/delegate.ps1 -SandboxCheck` prints `ok: false` or `support.ok: false` (sandbox not supported or letters not reserved; the reason is `support.problems`), or when the root of the repo's drive is not writable (a probe folder cannot be created). The lead runs it at sign-off with `Invoke-Pester` and `Filter.Tag = 'Live'`, `Filter.FullName = '*live sandbox verify*'`.
