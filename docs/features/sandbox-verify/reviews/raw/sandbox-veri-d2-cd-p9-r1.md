<!-- persona: codebase_details | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow the reviewer instructions exactly.The review target is the design doc against the implementation-readiness standard and the listed source files. I'll read those next and check the claims against the code.The design cites specific functions and parameters. I'll compare those claims to the scripts and the earlier design docs.## Review

The design is not executable as written. Three statements about current code are false, and several test and control-flow instructions leave the implementer to choose behavior the standard requires the plan to fix.

### 1. Blocker

**Affected scope:** `docs/designs/sandbox-verify.md` (path comparison rule); `skills/delegate/scripts/delegate.ps1` lines 533–534.

The plan says `-Worktree` is normalized "the same way its worker-launch safety check does": `[IO.Path]::GetFullPath`, `/` replaced by `\`, trailing `\` trimmed, then `OrdinalIgnoreCase`. The worker-launch check does not do that. It only rewrites `/` to `\` and trims a trailing `\`, then compares with PowerShell `-ne`:

```533:534:skills/delegate/scripts/delegate.ps1
$wtTop = (Invoke-Git -C $wt rev-parse --show-toplevel | Select-Object -First 1) -replace '/', '\'
if ($wtTop.TrimEnd('\') -ne $wt -or $wt -eq $Repo) { Fail "Safety check failed: worktree toplevel is $wtTop, expected $wt" }
```

There is no `GetFullPath` and no `OrdinalIgnoreCase`. Copying the existing check produces a different predicate than the one the plan lists after the colon. `$Repo` itself is normalized earlier with `Resolve-Path`, not `GetFullPath` (line 256).

### 2. Blocker

**Affected scope:** `docs/designs/sandbox-verify.md` (Files row for `verify.json` / `verify-setup.json`); `skills/feature/tests/feature.Tests.ps1` lines 30–44; `skills/feature/tests/TestHelpers.ps1` `Get-SampleSchemaName` lines 108–114.

The plan says adding `skills/feature/tests/fixtures/samples/verify-setup.json` is enough because "the schema test checks every sample in the folder." It does not. The `schemas` Describe walks a fixed list of seven names (`feature.json`, `plan.json`, `state.json`, `status-selected.json`, `status-none.json`, `schedule.json`, `verify.json`). A new file in that folder is never loaded. `Get-SampleSchemaName` would map `verify-setup.json` to the `verify` schema only if that name were added to `$validSamples`. As written, the filled `setup` object (`environment-missing`, message, proposal) is not schema-checked, and a schema that rejects it still passes.

### 3. Blocker

**Affected scope:** `docs/designs/sandbox-verify.md` Rules, "The sandboxed run" ("Nothing is written into the worktree"); G4; `skills/delegate/scripts/Sandbox.psm1` `New-SandboxRun` lines 1964–2001 and `Stop-SandboxRun` lines 2129–2133.

`verify` is specified to run the test through `Invoke-SandboxCommand`, which calls `New-SandboxRun`. That function creates `<worktree>\.xagent\sandbox\home` and `<worktree>\.xagent\sandbox\tmp`, and copies `cli-config.json`, `auth.json`, and `.gitconfig` into that home. `Stop-SandboxRun` deletes `auth.json` and leaves the other two. The risk row describes those copies. The Rules sentence forbids them. G4 equates "what a worker launch already adds" with only the `.venv` links. A worker launch already writes this home as well. An implementer who treats "nothing is written" as a requirement will fight `New-SandboxRun`, or will delete the home after the run and drop the login copy the risk row says stays.

### 4. Major

**Affected scope:** `docs/designs/sandbox-verify.md`, Files table.

The table lists repository paths and describes edits, and it never marks each path `Create`, `Modify`, or `Delete`. `fake-delegate.ps1` is described as "New." The other rows, including `docs/test-plan.md` and `docs/HANDOFF.md` (both already exist), are not marked. One gap for the whole table.

### 5. Major

**Affected scope:** `docs/designs/sandbox-verify.md`, "One helper" and `Add-DelegateVenvExclude`; `skills/delegate/scripts/delegate.ps1` lines 339 and 542.

The plan puts readiness, linking, and the run in one helper shared by the probe form and `-Worktree`. It also says `Add-DelegateVenvExclude` is called at each of three `Add-SandboxEnvLinks` sites: probe, `-Worktree`, and worker launch. Today there are two sites (probe at line 339, worker launch at line 542). After the helper, probe and `-Worktree` are one call. Following both instructions either links twice or drops the exclude from the helper. `Add-SandboxEnvLinks` runs only when some project is `ready` (lines 334–344 and 536–543). The exclude has to sit on that same condition. The plan does not say which structure wins.

### 6. Major

**Affected scope:** `skills/feature/tests/feature.Tests.ps1` Describe `feature.ps1 verify`, lines 1900–1923; Files row for that file.

The plan says that row states what happens to every existing test in the Describe. Two `It` blocks are missing:

- `computes changed before test writes out.txt` (line 1900). It is the check that `changed` is taken before the command creates `out.txt`. `BeforeAll` sends it through the fake. That passes only if default `ran` actually runs `-Command` in the worktree. The plan never says this test stays on the fake.
- `fails invalid TimeoutSec, unknown task, missing Task` (line 1915). It expects `invalid -TimeoutSec` for `0`, `-1`, and `abc` when the task has no worktree. Today the timeout check runs before the worktree check (`Invoke-VerifyFeature`, timeout at lines 2742–2747, worktree at 2757–2761). The new refusals (missing `delegate.ps1`, command longer than 30,000 characters, `-OnHost` / `-Quote`) are specified as happening before the scope check, and the relative order versus the timeout check is not. If the worktree check moves ahead of the timeout check, this test reports `no worktree in state` instead of `invalid -TimeoutSec`.

### 7. Major

**Affected scope:** `New-TaskTestWrapper` rule; `Invoke-TaskTestCommand` lines 2653–2665; `Get-SandboxCommandOutputLines` lines 2202–2225.

The plan says the shared wrapper makes a test behave the same for `where: sandbox` and `where: host`. The wrapper covers encoding and exit code only. The tails differ, and the plan keeps both algorithms:

- Host: split on `` `n ``, trim `` `r ``, drop trailing empty lines after the streams are joined, no 400-character cut (`Invoke-TaskTestCommand`).
- Sandbox: `Get-SandboxCommandOutputLines` splits on `` `r?`n ``, drops one trailing empty line per stream, cuts each line at 400 characters, and the new reader takes the last 40 of that combined list.

Same output can produce different `test.tail` values. The plan does not say whether the host path stays on the old reader or both paths use the new one.

### 8. Major

**Affected scope:** Verification item 2 (`live sandbox verify`); `feature.ps1 verify` `BeforeAll`; `Get-LaunchSkipReason` in `skills/delegate/tests/DelegateLaunch.Tests.ps1` lines 386–408.

The Live `It` is in the same Describe whose `BeforeAll` sets `XAGENT_DELEGATE_SCRIPT` to `fake-delegate.ps1` and whose `AfterAll` clears it. The plan says the `It` "leaves `XAGENT_DELEGATE_SCRIPT` unset" so the real `delegate.ps1` runs. It does not say to remove the variable for that `It` and restore it afterward. Left set, the fake runs `-Command` on the host, the profile file reads successfully, and `passed: false` with `denied` in `tail` does not happen.

The skip helper is "copied from `DelegateLaunch.Tests.ps1`." That function calls `Get-TestFreeLetters`, `Get-TestGitTopLevel`, `Test-TestPathUnderUserProfile`, `Test-TestDriveRootWritable`, and `Get-TestRealCursorVersionDir`, and it loads `SandboxNative.cs`. Those are separate functions in the same file (lines 22–92). For `-Kind Sandbox`, a passing sandbox check still falls through into the Cursor `versions` directory check and can skip because Cursor is unreadable. The plan does not say to copy those callees or to drop the fall-through.

### 9. Major

**Affected scope:** `DelegateLaunch.Tests.ps1` row, the Python `.git/info/exclude` case; `delegate.ps1` lines 309–344.

`.venv/` is appended only when environments are linked, and linking runs only after `Test-SandboxEnvReady` is ready and some project status is `ready`. A repo that merely contains a Python project returns `status: environment-missing` and never calls `Add-SandboxEnvLinks` (current probe path, lines 311–323 and 334–344). The planned test expects `.venv/` in `.git/info/exclude` exactly once and a clean `git status --porcelain`. The plan does not say to build the environment first (`-SandboxEnv -Apply`, the pattern in `links a ready environment and omits .venv from changes`) or to assert that an unready repo does not write the line.

### 10. Major

**Affected scope:** `fake-delegate.ps1`; verify mapping rules.

`error` has a full body (`{ok:false, error:"sandbox: fake"}`, exit 1). `environment-missing` and `timeout` do not. `verify` copies `message` and `proposal` for `environment-missing`, and for `timeout` it joins `-SandboxRun`'s `tail` array and forces `exitCode` to `-1`. Today's timeout `exitCode` is `$null` (`Invoke-SandboxCommand` line 2319), and `environment-missing` has `message`, `projects`, and `proposal` and no `notes` key (`delegate.ps1` lines 312–322). The fake is not told to print those shapes, so the mapping tests have no fixed input.

The new tests are also not told to use `-Tag 'Slow'`. Every current test in that Describe is `Slow`, and `scripts/test.ps1 -Fast` excludes `Slow`. The `hang` mode sleeps 600 seconds against `XAGENT_VERIFY_GRACE_SEC=5` and `-TimeoutSec 30`, so the wait is about 35 seconds. Untagged, that test runs on the fast path.

### 11. Major

**Affected scope:** Phase 1 task `sbrun-worktree`; `stages/build.md` verify and phase-end updates; `Test-SandboxEnvReady` proposal at `SandboxEnv.psm1` lines 956–964.

Phase 1's task test and its phase test are both `pwsh -NoProfile -File scripts/test.ps1 -Path skills/delegate/tests`. The Problem section records that this path fails in the sandbox (165 passed, 4 failed) because those tests start `delegate.ps1` and touch `D:\` and the user temp folder. The phase table says the phase test asks for a host run. It does not say `verify` of `sbrun-worktree` fails for the same measured reason. The flow treats `passed: false` as a failed review round unless the lead decides it is a sandbox limit. This failure is expected and should be specified as one `-OnHost` approval, same as the phase test.

`build.md` today asks for `-SandboxEnv -Apply` only when `proposal.needsApproval` is true (line 165). The proposal object has `needsApproval`, `text`, `interpreters`, `envs`, `estimateBytes`, `estimateSeconds`, and `unknownSize`. The plan replaces that with "ask only if the proposal says so," which does not name the boolean.

`verify` retries once on `no free slot` and stops on a second failure. A phase test uses the same `-SandboxRun` and the same two global slots (`Get-SandboxSlot` throws `sandbox: no free slot (both slots busy)` after 60 seconds, line 1738). The phase-end text does not include that retry. "Host fallback as for verify" is the approval path, not the slot wait.

### 12. Nit

**Affected scope:** SandboxRun output fields; timeout tail; `Invoke-TaskTestCommand` lines 2662–2665.

`environment-missing` today has no `notes` field. The plan's field list reads as if `{ok, status, exitCode, output, seconds, notes}` is always present and `message`, `projects`, and `proposal` are added for that status.

The sandbox mapping says `test.tail` is the `tail` array joined with `\n`, plus the timeout line. The host path appends `timed out after <timeout> s` as another array element and then joins, so an empty capture becomes that line with no leading newline. The plan does not say the sandbox path does the same.

The parenthetical that the new reader matches `Invoke-TaskTestCommand` "from the other end" does not match that function. The host reader is not the 400-character, `\r?\n` reader used for `output`.
