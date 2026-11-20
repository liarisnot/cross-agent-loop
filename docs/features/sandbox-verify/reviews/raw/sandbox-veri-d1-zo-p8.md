<!-- persona: zoom_out | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer instructions exactly.The review is of `docs/designs/sandbox-verify.md` against the Zoom-Out Standard. I'll read that design and the related context next.The design is in place. I'll compare it with the earlier sandbox designs and the functions it says it will reuse.The context check passes. The design is about moving `feature.ps1 verify` into the existing sandbox so a worker's uncommitted test command stops running as the user on the host. That part is the root problem, and the plan reuses the sandbox that already exists.

Code search backs the reuse. `delegate.ps1` already has a `SandboxRun` set that gates with `Test-SandboxEnvReady`, links with `Add-SandboxEnvLinks`, and runs with `Invoke-SandboxCommand` (`skills/delegate/scripts/delegate.ps1` around 303–366). `Get-SandboxCommandOutputLines` already keeps 40 lines cut at 400 characters. `Invoke-TaskTestCommand` already builds the encoded wrapper and the last-40 tail. `Get-LiveDelegateRunCount` already counts any `.xagent\runs\*.pid` that has `pid`, `startTime`, and `feature`. `-TimeoutSec` on `SandboxRun` is already 30–3600. `doctor` already finds `delegate.ps1` beside the feature skill. No second sandbox module is justified, and the design does not add one. D3, D4, and D6 are the small shape of the change.

## Findings

### 1. Major — D1, Goals vs the phase-test flow, Phases (phase 1)

**Simplicity rationale:** The hole this feature exists to close is `verify`: it runs code the worker just wrote, on the host, before review. The Problem section says the phase test is a different case. It runs code the lead has already reviewed and merged. Sign-off is left on the host for that same reason (Non-Goals). D1 still sends every repo's phase test through `-SandboxRun`, including repos with no Python projects, where `sandbox-env` left the phase test on the host.

The cost is already measured, and the mitigation does not cover it. The 14% figure is a narrow feature-task run. Phase tests are not under the size gate. In this repo the delegate suite failed in the sandbox (165 passed, 4 failed), and phase 1's test is that suite, so the design's own first checkpoint is specified as a host prompt. D2 says that prompt is asked again every time and never remembered. The phase host path is also a second procedure: the lead logs a free-text decision and runs the command in the checkout, beside `verify -OnHost -Quote`.

`sandbox-env` already sandboxes phase tests when the repo has Python projects (`skills/feature/stages/build.md`). Leaving every other repo as it is closes the unreviewed-code hole without a new prompt loop for suites that cannot run in a container.

### 2. Major — G4 and the `.venv` rule under Rules / Files (`Get-ChangedPaths`)

**Simplicity rationale:** A new junction check in `Get-ChangedPaths` is a one-reader patch. `git ls-files --others --exclude-standard` already drops ignored paths, which is why a normal `.venv` never reaches the scope check. `sandbox-env` already treats `.venv` as gitignored.

The case G4 is written for is a repo that does not ignore `.venv`. For that repo the skip is incomplete. `Invoke-MergeFeature` still treats untracked porcelain as blocking unless `Test-CachePath` matches (`skills/feature/scripts/feature.ps1`, `Test-MergeBlockingPorcelainLine`). `?? .venv/` is not a cache path, so merge still stops on the junction the worker launch or this run left behind. There is no existing `.venv` helper to extend. The mechanism that already hides these links from both the scope check and the merge gate is the gitignore. A detector only on `Get-ChangedPaths` adds a special case and leaves the build flow that G4 is about still blocked.

### 3. Nit — Rules: command-line budget, the shared helper's `.probe-` leaf check, and `timeout + 300`

**Simplicity rationale:** The architectural surface is `-Worktree`, `-Feature`, `where` / `setup`, and `-OnHost`. The Rules section then specifies a 30,000-character cutoff, a 2.7× UTF-16LE ratio, a ~10,000-character test command, and this repo's longest acceptance line (~300). It also specifies that the shared helper removes a worktree only when a probe flag is set and the leaf name starts with `.probe-`, and that `verify` waits `<timeout> + 300` seconds before killing `delegate.ps1`. Those are implementation constants. The Windows command-line limit and "do not delete a worktree this run did not create" are enough at this altitude.
