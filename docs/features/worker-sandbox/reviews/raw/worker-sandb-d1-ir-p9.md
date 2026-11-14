<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll read the task file first.

## Implementation Readiness Review — `docs/designs/worker-sandbox.md`, lines 333–542

Scope reviewed: the Detailed Implementation Plan (machine setup, 13 target files, build order, verification plan). Read as the engineer who will execute phases 1–5. The spec above line 333 was read for context only.

What is already strong and should not be touched: the exact file-path allowlist (13 files, all repo-relative), the phase table with dependencies, the explicit patch-failure message text, the full environment variable list, and the `patch.json` field list. Those are at the bar the standard wants. The gaps below are where I would have to stop and choose.

---

### 1. [Blocker] The canary repo lives under the user profile, which the probe proved git cannot use

**Affected scope:** file 2, `Invoke-SandboxCanary` (lines ~405–407); also `-SandboxCheck` (line ~415) and the Failure test in the Verification Plan (line ~537).

**Finding:** The canary is specified as "creates a temporary repo under `<TEMP>\xagent-canary-<rand>`". `-SandboxCheck` runs on the host, so `<TEMP>` is the real `C:\Users\<me>\AppData\Local\Temp`. The probe README states the opposite rule as a finding: a work folder under `%TEMP%` failed because "git resolved `W:` back to `C:\Users\...` and failed with 'cannot lock ref HEAD: unable to create directory' when it stat-ed `C:\Users`", and "Moving the work folder to `D:\xagent-ac-probe` fixed git". The specified canary therefore fails `git init`/`commit` by construction, and `-SandboxCheck` — the one setup command README and CUJ 1 depend on — would report `ok: false` on a healthy machine.

Two further gaps in the same function:
* Nothing specifies the container profile, SID, drive letters or host folder the canary run uses. It is not a worktree, so `New-SandboxRun` does not apply; the canary needs its own container and its own `subst` roots, and none of that is stated.
* "a fixed in-container script" is a file that does not appear in the Target Files list. The phase-5 write allowlist cannot include it, and its location determines whether the container can read it at all.

Also note the canary's second planting site ("next to the repo's parent") is inside `%TEMP%`, which is denied for reasons unrelated to the goal, so the test can pass for the wrong reason.

**Guidance:** State the canary's host folder (a path outside `%USERPROFILE%`, e.g. `<repoParent>\xagent-canary-<rand>`, matching what the probe validated), that it is `subst`-mapped, which container/profile name and cleanup order it uses, and the exact repo-relative path of the in-container canary script (or state that it is written by the module into the canary folder, and where). Add the canary folder to the file-change list as generated output.

---

### 2. [Blocker] The runtime-cache patch step is not idempotent, so the second run of a Cursor version fails

**Affected scope:** file 2, `Get-SandboxRuntime` (lines ~376–381).

**Finding:** The function "ensures `<version>\` exists. If not, it copies… Then it runs the patch." On the second and every later run of the same Cursor version, the cache already exists and already holds the *patched* `node.exe`. The flow then measures `process.versions.uv` (still 1.52.1, so no skip), counts occurrences of `\\?\pipe\uv\%llu-%lu` (now 0), and throws the named error: "pattern found 0 times… need an update to Sandbox.psm1". Every run after the first fails at the patch step.

Related: `patch.json` records `sourceSha256` and `patchedSha256`, which strongly implies reuse is meant to be hash-verified, but the plan never says `patch.json` is read at all.

**Guidance:** Specify the reuse contract explicitly: if `<version>\patch.json` exists, read it; if `patched:false` and `uv` ≥ 1.53, return; if `patched:true`, verify the cached `node.exe` SHA-256 equals `patchedSha256`, then return without re-reading bytes. Only a missing or hash-mismatched `patch.json` triggers the copy/patch path. Add a unit test for "second call returns the same `{root, version, uv, patched}` without touching `node.exe`".

---

### 3. [Blocker] G6's pass criterion has no implementation

**Affected scope:** Verification Plan line ~542 ("every `runs.jsonl` line of this feature's build shows the frozen skill path"); file 3's `runs.jsonl` change (line ~425).

**Finding:** The only `runs.jsonl` change specified is `sandboxed`. Today's record fields (`delegate.ps1:401–405`) are `ts, repo, taskId, agent, profile, model, seat, feature, resumed, seconds, exitCode, timedOut, usage` — no skill path. Neither the summary nor `runs.jsonl` gains one in this plan, and the log files (`stdout.json`, `prompt.txt`) do not contain the skill directory either. The criterion as written cannot be satisfied, so phase 5's G6 check has no evidence to look at.

**Guidance:** Either add `skillDir` (or `delegatePath`) to the `runs.jsonl` record and the summary in file 3, with the exact field name and value (`$skillDir`), or rewrite the criterion to what the plan actually produces (the lead's `test-plan.md` record of the junction target). Pick one; do not leave both.

---

### 4. [Blocker] Phase 2 is both fully specified and the G7 "Yours to decide" task

**Affected scope:** Build order lines ~523–529 (phase 2 marked "`code-hard` (first one: G7 template)"); files 1 and 2 (lines 346–408).

**Finding:** G7 requires the first `code-hard` task to be split into "Decided" (outcome, boundaries, shared interfaces) and "Yours to decide" (internals, names, internal tests, order of work). Phase 2 is that task, and it is the same phase whose spec dictates method signatures, field names, struct attribute lists, flag sets, error strings and internal test cases for `SandboxNative.cs` and `Sandbox.psm1`. Both cannot be true: the worker either follows file 1/2 line by line (not a G7 task, and G7 measures nothing) or decides internals (and the reviewable plan is not what gets built).

**Guidance:** State which of files 1 and 2 becomes "Decided" (the public function signatures, the `patch.json` shape, the environment list, the error strings, the acceptance tests) and which becomes "Yours to decide" (C# marshalling strategy, icacls construction, mutex handling, internal helpers). If nothing can be delegated, move the G7 test to a different task and say so.

---

### 5. [Major] `-SandboxCheck` will die before it prints anything

**Affected scope:** file 3, parameters and `-SandboxCheck` bullet (lines ~414–417).

**Finding:** The plan says `-SandboxCheck` makes `-Repo` and `-TaskId` optional and "prints `{ok, support, runtime, canary, grants, staleLetters}` and exits", but does not say where the branch goes. In the current script, line 84 runs `(Resolve-Path -LiteralPath $Repo).Path` unconditionally, lines 108–112 create and write `<repo>\.git\info\exclude`, and line 166 `Fail`s when `-Agent` is missing (line 169 for `-TaskFile`). Any placement after line 84 makes `-SandboxCheck` without `-Repo` fail; any placement after line 112 mutates a repo it was not given.

**Guidance:** State the insertion point precisely: "immediately after the `Quote`/`Get-RuleFiles` helper definitions and before the `resolve repo & worktree paths` block, handle `-SandboxCheck` and `-Cleanup` before any `Resolve-Path` of `$Repo`". Also state whether `-SandboxCheck` requires `-Agent`/`-TaskFile` (it should not) and what exit code it returns for `ok:false` (`Fail` vs `Out-Summary`), since `feature.ps1 doctor` must parse it.

---

### 6. [Major] `Global\xagent-subst` will fail for a non-elevated launcher, and the mutex does not cover the race it exists for

**Affected scope:** file 2, `Get-FreeDriveLetter` (lines ~385–387); `New-SandboxRun` mapping step (line ~393).

**Finding:** Creating a `Global\` kernel object requires `SeCreateGlobalPrivilege`. A UAC-filtered administrator token does not hold it, and the probe explicitly runs non-elevated ("Run them only from a non-elevated PowerShell 7"). `New-Object Mutex 'Global\xagent-subst'` will throw `UnauthorizedAccessException` on the target machine. Separately, the mutex is named as protecting "the choice", but the `subst` call happens in `New-SandboxRun`, a different function; between return and `subst`, another run can take the same letter.

**Guidance:** Specify `Local\xagent-subst` (all runs are in the same session and user), and state that the mutex is held from letter selection through the successful `subst` — i.e. either `Get-FreeDriveLetter` takes a callback, or `New-SandboxRun` acquires the same mutex and re-reads free letters inside it. Add a unit test that two sequential selections under a held mutex never collide.

---

### 7. [Major] `-Cleanup` leaves read-only run containers behind

**Affected scope:** file 3 `-Cleanup` bullet (line ~427); `Remove-SandboxRun` (line ~404); existing cleanup loops at `delegate.ps1:114–148`.

**Finding:** The plan says "call `Remove-SandboxRun` before the worktree is removed", which names one worktree and one `WtName`. But `-Cleanup` also removes every detached `<TaskId>-<label>` read-only worktree (lines 128–135) and, with `-Discard`, the worker worktree (lines 138–148). Read-only runs get their own container per `New-SandboxRun` (`xagent.<key>.<TaskId>-<Seat>`), so each of those paths leaks an AppContainer profile and its ACEs. The design's Clean-up section says `-Cleanup` "deletes the AppContainer profile" — the plan cannot honour that for lenses and council seats.

**Guidance:** State the call sites explicitly: `Remove-SandboxRun -Repo $Repo -WtName <TaskId>-<label>` inside the detached-worktree loop, `-WtName $TaskId` in the normal and `-Discard` paths, and that a failure is collected into `$notes` rather than thrown. Add a container test for "cleanup of a task with a lens worktree removes both profiles".

---

### 8. [Major] The launched process's working directory is never stated

**Affected scope:** file 2, `Start-SandboxProcess` (line ~401); file 3 launch bullet (line ~420).

**Finding:** `XagentSandbox.Start` takes a `cwd`, but `Start-SandboxProcess -Run -CliArgs -StdoutPath -StderrPath` has no `-Cwd` and no statement of what it passes. Today the CLI runs with `-WorkingDirectory $wt` (`delegate.ps1:338–339`). Inside the container, `$wt` is the real `D:\...\...xagent\<TaskId>` path, whose drive root `D:\` is denied (probe README: "Node does check the drive root", `EPERM: lstat 'D:\'`). Passing the real path as cwd can therefore fail or degrade; passing `W:\` is untested. This is exactly the class of decision the standard forbids leaving to the implementer.

**Guidance:** State the cwd (`<W>:\`, i.e. `"$($Run.worktreeLetter):\"`) and require it in `Start-SandboxProcess`, and note that `--workspace` must equal the same value so the agent's relative `.xagent/` paths resolve.

---

### 9. [Major] `--workspace <W>:\` is a variant the probe never validated

**Affected scope:** file 3 launch bullet (line ~421).

**Finding:** The probe's successful Cursor run used the *real* path as the workspace: `inner5.ps1` passes `-workspace $repo` where `$repo = D:\xagent-ac-probe\repo`. The design's own finding is that Cursor "uses the native `fs.promises.realpath` and does not hit" the drive-root problem. Changing `--workspace` to `W:\` is therefore an unprobed change, and the plan does not say why it is needed. If Cursor writes absolute `W:\` paths into its session/auth state, `-Resume` and the host-side `result.json` handling also change shape.

**Guidance:** Either keep `--workspace $wt` (the probed configuration) and state that the drive letter exists only for the module loader, or state the reason for `W:\` and add the check that covers it (a canary step that runs a full Cursor run with `--workspace W:\`, or the Live test made a phase-4 exit gate).

---

### 10. [Major] The environment block is passed as `string[]` with no marshalling contract, and inheritance flags are unspecified

**Affected scope:** file 1, `Start` (lines ~355–360).

**Finding:** `CreateProcessW` with `CREATE_UNICODE_ENVIRONMENT` needs an unmanaged, sorted, double-null-terminated block; .NET cannot marshal a `string[]` into that. The probe sidestepped it entirely (`IntPtr.Zero` env, `bInheritHandles = false`, flags `0x00080000 | 0x08000000`). The plan adds `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` and two inheritable log handles, which requires `bInheritHandles = true` — never stated — and does not say how the environment block is built, whether the strings are sorted, or whether the buffer is freed. An implementer must invent all of it, and this is the one place where a mistake is silent (a wrong block yields an empty environment, and every later "why is PATH empty" symptom points elsewhere).

**Guidance:** Specify: `Marshal.AllocHGlobal` sized from UTF-16 lengths + terminators, entries `NAME=VALUE` sorted by name (case-insensitive ordinal), terminated by an extra `\0`, freed in `finally`; `bInheritHandles = true`; flag constant values (`0x4`, `0x00080000`, `0x08000000`, `0x400`); `PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002` and that `hStdInput` is a `NUL` handle opened with `GENERIC_READ`. Add a test that runs `node -e "console.log(JSON.stringify(process.env))"` and asserts only the listed names appear.

---

### 11. [Major] Read list: `addToPath` contradicts the environment rule, and a refused entry has no defined behaviour

**Affected scope:** file 2, `env` bullets (lines ~398–399) and the **Read list** bullet (line ~409); test at line ~447.

**Finding:** The JSON example carries `"addToPath": true`, but the `PATH` rule says "then the read list's `path` entries" with no mention of `addToPath`. So the implementer must decide whether every entry goes on `PATH` (making the field dead) or only flagged ones do. Likewise, "An entry under `%USERPROFILE%` is refused" does not say whether refusal throws (blocking every run on a bad config file) or is skipped with a problem recorded; it gives no message text, does not say whether the comparison is case-insensitive or after `Resolve-Path`/`GetFullPath`, and does not say what happens to a non-existent path or a relative one. The unit test ("read-list entries for `~\.ssh` and the profile root are refused") cannot be written without that answer.

**Guidance:** State the rule (`addToPath` true → append to `PATH`; absent → treated as false), the normalization (resolve to a full path, trailing `\` trimmed, compared case-insensitively), the refusal result (throw `"sandbox.json: read-list entry '<path>' is refused (<reason>); remove it or use -NoSandbox"`) with the reasons enumerated, and non-existent path handling (throw with the path). Add the exact asserted message to the test case.

---

### 12. [Major] The unit tests require test seams that the module signatures do not have

**Affected scope:** file 5 unit tests (lines ~442–447), file 2 `Get-SandboxRuntime` (line ~374) and `Test-SandboxSupport` (line ~370).

**Finding:** The tests demand the patch be exercised "on synthetic `node.exe` byte files" and that `process.versions.uv` be "skipped; `process.versions.uv` is mocked" — a contradiction in itself. Concretely, `Get-SandboxRuntime` takes no parameters, so it reads `%LOCALAPPDATA%\cursor-agent\versions\*` and writes `%LOCALAPPDATA%\xagent\sandbox\cursor\*`; there is no way for a Pester test to point it at `TestDrive`. The uv probe is executed by shelling out to `node.exe -p`, which cannot be mocked at all. The implementer must invent (or discover they need) an injection point, which is a design decision.

**Guidance:** Give the functions explicit overridable parameters: `Get-SandboxRuntime [-CursorRoot <path>] [-CacheRoot <path>] [-UvProbe <scriptblock or exe path>]`, with defaults as today, and say which the tests pass. Resolve "skipped; mocked" into one: "the uv probe is a scriptblock parameter, and the ≥1.53 case passes a stub returning `1.53.0`".

---

### 13. [Major] `DelegateLaunch.Tests.ps1` has no fixture that avoids a live agent

**Affected scope:** file 6 (lines ~460–463).

**Finding:** Two of the four cases run `delegate.ps1` for real: `-NoSandbox` (which starts the Cursor CLI via `Start-Process`) and "Existing calls without the new switches still bind" (which starts a sandboxed agent). Without a fake CLI these tests either cost model tokens or fail on a machine without a login, in a suite whose Verification Plan also requires it to pass *inside* the sandbox. The existing regression used "a fake Cursor CLI" (HANDOFF, build step 1) but the plan does not carry that fixture forward, nor say how `delegate.ps1` is pointed at it.

**Guidance:** Specify the fixture: a stub `cursor-agent.ps1`/`node.exe` under `TestDrive` and the parameter or environment variable `delegate.ps1` honours to use it (e.g. `-CliRoot` or `%LOCALAPPDATA%` override via `XAGENT_CURSOR_ROOT`), the exact JSON the stub writes so the summary parses, and that no test binds to a real model.

---

### 14. [Major] `scripts/test.ps1` makes phase 1 unstable

**Affected scope:** file 7 (lines ~467–472); build order phase 1 (line ~523).

**Finding:** Phase 1 creates `scripts/test.ps1`, which "runs `skills/feature/tests` and `skills/delegate/tests`". `skills/delegate/tests` does not exist until phase 2, so phase 1's one test command fails on a missing path — violating "each phase leaves the codebase stable, buildable and testable". The file's own contract is also under-specified: no `param([switch]$Fast)` block, no statement of how the configuration is built (`New-PesterConfiguration`, `Run.Path`, `Filter.ExcludeTag`), no `Output.Verbosity`, and "Exits with the failed count" is ambiguous (`exit $n` caps at 255; Pester's own exit code is 1).

**Guidance:** Say the script runs each existing test path only if it exists (`-Path` filtered by `Test-Path`), give the parameter block, and state the exit rule (`exit [int]([Math]::Min($failedCount, 250))`, 0 when all pass). Alternatively move `scripts/test.ps1` to phase 2.

---

### 15. [Major] Grants bookkeeping is referenced but never produced

**Affected scope:** file 2 `Grant-RepoAccess` (line ~383), `Remove-SandboxGrants` (line ~408), `New-SandboxRun` return (line ~394), `-SandboxCheck` output (line ~416).

**Finding:** Three dangling references:
* `repos.json` is "written by `Grant-RepoAccess`", but `Grant-RepoAccess`'s own bullets list only idempotency and the two `icacls` calls. Nothing says the file's shape, whether entries are appended or replaced, how duplicates are avoided, or where it lives (it is implied by `Remove-SandboxGrants` to be `%LOCALAPPDATA%\xagent\sandbox\repos.json`).
* `New-SandboxRun` returns `capabilities` but never says what it contains (`internetClient` S-1-15-3-1, `xagent-runtime`, `xagent-repo-<key>`), so `XagentSandbox.Start`'s `capabilitySids` argument is unspecified.
* `-SandboxCheck` prints `grants` and `staleLetters`, and neither has a producing function: `Test-SandboxSupport` returns `{ok, build, cursorVersion, freeLetters, problems[]}`, and no function computes letter staleness (what makes a letter stale — target missing, target not one of ours, mapping left by a dead run?).

**Guidance:** Add to `Grant-RepoAccess`: "appends `{repo, key, ts}` to `<cache>\repos.json` if `repo` is absent, rewriting the file atomically". Add to `New-SandboxRun`: "`capabilities = @($runtimeCapabilitySid, $repoCapabilitySid, 'S-1-15-3-1')", with container capability = the container SID and `internetClient` always present. Add a `Get-SandboxStaleLetters` function (or state that `-SandboxCheck` derives it inline: every `subst` letter whose target no longer exists or is not under the worktree/cache roots) and say what `grants` reports.

---

### 16. [Major] The `.running` letter markers that `Stop-SandboxRun` refcounts are never written

**Affected scope:** file 2, `Stop-SandboxRun` (line ~403), `Get-SandboxRuntime` (line ~379).

**Finding:** `Stop-SandboxRun` removes the runtime letter "only when no other live run uses it, tracked by `.running` files in `%LOCALAPPDATA%\xagent\sandbox\letters\`". Nothing in `New-SandboxRun` creates such a file, nothing says its name (pid? container name? guid?), and nothing deletes it when the *owning* run dies without `finally`. `Get-SandboxRuntime` separately mentions `.running\` *inside the runtime cache*, which is Cursor's own marker folder (per the probe README, `cscript identity.js` writes it) — two different concepts under one name. A stale-file scheme without a liveness check will leak the runtime letter permanently after one kill, and a `subst` mapping to a deleted cache then makes the next run fail with a confusing error.

**Guidance:** Specify the marker file (name `letters\<letter>.json`, content `{pid, startTime, path}`), that `New-SandboxRun` writes it under the letters mutex, that `Stop-SandboxRun` deletes its own and removes the `subst` when no remaining marker is live (liveness = `Test-ProcessStartTimeMatch`, which `feature.ps1:1702` already implements), and that stale markers are pruned at the start of `New-SandboxRun`. Rename either concept to avoid the collision.

---

### 17. [Major] `feature.ps1 doctor`'s sandbox entry will time out on principle

**Affected scope:** file 4, `doctor` bullet (line ~436); helper at `feature.ps1:2543–2567`.

**Finding:** `Invoke-DoctorCommand` defaults to `TimeoutSec = 30`. `-SandboxCheck` on a cold machine copies and patches ~256 MB (design: "First run of each Cursor version: copying about 256 MB") and then runs a canary container with `git init`/`commit` and a node spawn. Thirty seconds is not a safe bound, and a timeout is reported as `timedOut` with empty output, which the entry would render as a failed check with no reason. The plan also does not say whether the sandbox check is `required` for `ready` — that decides whether a machine that cannot sandbox is blocked from the whole skill or merely warned.

**Guidance:** State the call (`Invoke-DoctorCommand -FilePath ... -ArgumentList @('-NoProfile','-File',$delegate,'-SandboxCheck') -TimeoutSec 600`), the fields shown (`ok`, `problems` joined, truncated to N chars), and `required = $false` (or `$true`, with the consequence stated). Also say how `doctor` handles `ok:false` from `-SandboxCheck` (it must still print valid JSON).

---

### 18. [Nit] The job object is claimed for both paths, then dropped for one

**Affected scope:** line ~147 ("On timeout, `delegate.ps1` closes the job. `taskkill.exe` is no longer used, in sandboxed or unsandboxed runs") vs. line ~425 ("Unsandboxed path: … Replace `taskkill.exe` with `$proc.Kill($true)`").

**Finding:** The unsandboxed path keeps `Start-Process`, which cannot assign a job object, so it has no job and no `TerminateJobObject`; only the "no `taskkill`" half of the sentence is true. CUJ 5's "every process in the run at once through a Windows job object" therefore applies to sandboxed runs only, and the design should say so, since `Process.Kill($true)` walks parent links and can miss a grandchild that reparented.

**Guidance:** Reword line 147 to scope the job object to sandboxed runs and state the unsandboxed behaviour as today's `Kill($true)` best-effort.

---

### 19. [Nit] Verification counts and failure fixtures are not reproducible

**Affected scope:** Verification Plan lines ~533, ~537.

**Finding:** "All tests pass: the 218 existing ones" — `skills/feature/tests/feature.Tests.ps1` currently holds 166 `It` blocks and there is no other test file, so 218 is either stale or counting something else; a lead checking the gate against that number will be confused. The Failure case says "a copy of the runtime cache with the pattern removed, plus `XAGENT_SANDBOX_FORCE_FAIL`" — two injections at once, and "with the pattern removed" does not say how (zeroed bytes? spaces?), nor which of the two errors the run must report. `XAGENT_SANDBOX_FORCE_FAIL` is also not placed: which check reads it, and what `problems[]` entry does it add?

**Guidance:** Replace 218 with the measured `It` count or drop the number. Split the Failure case into two: (a) cache copy with the 27 pattern bytes overwritten by `0x00` → expect the named error; (b) `XAGENT_SANDBOX_FORCE_FAIL=1` → expect `ok:false`. State that `Test-SandboxSupport` reads the variable first and returns `problems = @('forced failure: XAGENT_SANDBOX_FORCE_FAIL')`.

---

### 20. [Nit] Small definitions left open

* **"The Cursor install (`versions\<latest>`)"** (line ~371): "latest" is undefined; the probe's rule (folders matching `^\d{4}\.`, name-sort, take the last) is available and should be named, since a numeric-vs-string sort difference picks a different version.
* **"It deletes cache versions other than this one and the one before"** (line ~380): ordering rule unspecified (version sort vs. mtime), and a cache version still mapped by a live run can be deleted mid-run. Say "ordered by version name; never delete the version recorded in any live `letters` marker".
* **`XagentSandbox` handle lifetime** (line ~360–362): nothing says the process handle is closed after `ExitCode`, so a long lived lead session leaks one handle per run. Say "`ExitCode` closes the process handle; `RunHandle` is valid only until then".
* **`RunHandle` shape:** for `Add-Type -Path`, its fields must be public for PowerShell to read `$h.ProcessId`. Say "`public int ProcessId; public IntPtr ProcessHandle; public IntPtr JobHandle`".
* **`-SandboxCheck` + `-NoSandbox`** and **`-Remove` without `-SandboxCheck`** are unaddressed; today's `[switch]$Remove` would be silently accepted on a normal run. Say both are `Fail` with a message.
* **Overhead target** (line ~539) still has no consequence if missed (previously flagged in the stage-7 design critic round). One clause is enough: "if the median exceeds 5 s, record it in `test-plan.md` and the feature proceeds; the target is not a gate".

---

### Summary for the orchestrator

Four blockers: the canary runs git in a folder the probe proved unusable (so `-SandboxCheck`, the setup step everything else assumes, fails); the patch step cannot run twice; G6's evidence is not produced by any specified change; and phase 2 cannot simultaneously be a fully specified task and the G7 "Yours to decide" experiment. Fourteen majors are mostly the same shape — a mechanism is named but the one detail that makes it idempotent, race-free, testable or reachable is not — which is exactly the "decide it for me" load the standard exists to remove. The file-path allowlist, phasing table and error-message texts are already at the bar; the gaps are inside the bullets, not around them.
