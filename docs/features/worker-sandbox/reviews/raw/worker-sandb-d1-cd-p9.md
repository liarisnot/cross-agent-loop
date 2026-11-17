<!-- persona: codebase_details | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer persona exactly.The review is a Stage 9 audit of the implementation plan against the repository. I'll read the target section and the files it claims exist.The plan names existing scripts, tests, and design docs. I'll check those claims against the source.The Detailed Implementation Plan (lines 333–542) does not meet the zero-decision bar. Four gaps would make a first implementation wrong or would fail the existing suite. The rest are decisions the plan still leaves open.

## Blocker

**1. Sandboxed argv and working directory are not specified**
Scope: `docs/designs/worker-sandbox.md` lines 401 and 418–421; `skills/delegate/scripts/delegate.ps1` lines 284–296; `cursor-agent.ps1` lines 44–71.

`Start-SandboxProcess` says the command line is `"<R>:\node.exe" "<R>:\index.js" <args>` and that `--workspace` becomes `<W>:\`. It never lists `<args>` or the `cwd` passed to `XagentSandbox.Start`. Today the cursor branch builds a Windows PowerShell command: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <LOCALAPPDATA>\cursor-agent\cursor-agent.ps1`, then `-p --trust --output-format json --workspace $wt --model $Model`, then `--mode ask`, `--mode plan`, or `--force`, then optional `--resume`, then the prompt. `cursor-agent.ps1` forwards only that tail to `node.exe index.js`. Passing the existing `$cliArgs` into `index.js` launches Node on PowerShell switches. The plan also does not say to run `versions\promote-staged.cmd`, which the launcher runs before it picks a version.

**2. The capability SIDs handed to `CreateProcessW` are not specified**
Scope: lines 353 and 389–401; `docs/designs/worker-sandbox-probe/probe5.ps1` lines 34–47.

`XagentSandbox.Start` takes `capabilitySids`. `New-SandboxRun` returns `capabilities` and never names the members. File grants for the runtime capability and `xagent-repo-<key>` apply only when those SIDs are in the process token. The probe's `AC.Run` passes one SID, `S-1-15-3-1` (`internetClient`), and grants the container SID itself, not a capability. Copying that call leaves the container unable to read the runtime cache or `<repo>\.git`. The sentence "Every container gets the `internetClient` capability" is at line 149, outside this plan, and it does not add `xagent-runtime` or `xagent-repo-<key>` to the token.

**3. "Failed runs" is not in the file the plan edits, and the retry rule stays in force**
Scope: line 480, file 8 (`skills/delegate/SKILL.md`); `skills/delegate/SKILL.md` line 144; `skills/feature/stages/build.md` lines 54–58.

`skills/delegate/SKILL.md` has no "Failed runs" section. Its Rules line is: "If `ok` is false: read `stderrTail` and the log files, then retry once." The heading "Failed runs" is in `skills/feature/stages/build.md`, which says every failed run other than a usage limit is retried once. That file is not in the create/modify list. A sandbox start failure (`ok: false`, G5) is still a retry under both current texts. The plan tells the implementer to add a line to a section the target file does not have, and it does not change the two sentences that actually retry.

**4. The doctor change breaks a test the plan never lists**
Scope: line 435, file 4; `skills/feature/tests/feature.Tests.ps1` lines 2468–2475; `skills/feature/scripts/feature.ps1` lines 2543–2557 and 2607–2784.

`doctor` today returns nine checks named `powershell`, `git`, `delegate`, `cursor-cli`, `cursor-login`, `models`, `pester`, `python`, `log-dir`. The suite asserts that count and that exact name array. Adding a `sandbox` check fails `It 'reports prerequisites'`. `skills/feature/tests/feature.Tests.ps1` is not a Create/Modify path. The verification plan (line 533) requires those existing tests to pass.

The plan also does not say how the new check sits in the existing record (`name`, `ok`, `required`, `detail`), or whether `ready` becomes false when the sandbox check fails. `Invoke-DoctorCommand` kills the child after 30 seconds. `-SandboxCheck` runs a container canary. The plan does not say to raise that timeout or to call the module in-process.

## Major

**5. Two shapes for the new summary field**
Scope: lines 159–161 and 425.

The Technical Plan says the summary gains `sandbox: {container, runtimeVersion, letters}` and that `runs.jsonl` gains `sandboxed` only. The implementation plan says both the summary and `runs.jsonl` gain `sandboxed` and, when sandboxed, `sandbox = {container, runtimeVersion, patched, worktreeLetter, runtimeLetter}`. An implementer has to pick one.

**6. Timeout result is not tied to today's `timedOut` / `exitCode`**
Scope: lines 421–422; `delegate.ps1` lines 348–350.

Today a timeout sets `timedOut` and stores `exitCode = -1` after `taskkill` and a 10-second `WaitForExit`. The plan waits with `XagentSandbox.Wait` and then calls `Kill`. `Wait` returns a bool. `ExitCode` after `TerminateJobObject` is the job's terminate code. The plan never says to keep `timedOut: true` and `exitCode: -1`. `feature.ps1` treats `timedOut` as the timeout signal (`skills/feature/stages/build.md` line 27).

**7. Inherited log handles contradict the probe's `CreateProcessW` call**
Scope: lines 353–357; `probe5.ps1` line 47.

The plan inherits two log handles and a `NUL` stdin through `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`. That list is used only when `CreateProcessW`'s inherit-handles flag is true. The probe passes `false` (`CreateProcessW(..., false, 0x00080000 | 0x08000000, ...)`). The plan says to take the launcher from that class and does not set the flag.

**8. The pipe-name search string is not a byte sequence**
Scope: lines 376–378; `docs/designs/worker-sandbox-probe/README.md` line 16.

The plan says to count ASCII occurrences of `` `\\?\pipe\uv\%llu-%lu` `` and, on one hit, write `` `\\?\pipe\LOCAL\%llu` `` plus a zero byte. In the file those backticks contain doubled backslashes. The bytes in `node.exe` are the C-string contents `\?\pipe\uv\%llu-%lu` (19 bytes) and `\?\pipe\LOCAL\%llu` plus NUL (19 bytes). A PowerShell single-quoted paste searches for a different string, the count is 0, and every version takes the "found n times" failure. The probe README records the match at offset `0x55df524` in Cursor `2026.11.11-043ef28`. The plan does not cite that offset or the 19-byte sequences.

The same step says "at 1.53 or later" and does not say how to compare `process.versions.uv` (`1.53`, `1.53.0`, and `1.53.0-pre` are all possible).

**9. `<latest>` is not the launcher's version pick**
Scope: line 371; `cursor-agent.ps1` lines 49–71.

`Test-SandboxSupport` and `Get-SandboxRuntime` say `<latest>` under `%LOCALAPPDATA%\cursor-agent\versions\`. The launcher keeps directories matching `^\d{4}\.\d{1,2}\.\d{1,2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$` and sorts them with `Parse-VersionString`, which uses only `YYYYMMDD` and ignores the time-of-day suffix. Last-write-time and a full-string sort can choose a different folder than the one `cursor-agent.ps1` would start. The plan also says to delete cache versions other than "this one and the one before" and does not define "the one before" (previous date under that same sort, or previous directory name).

**10. Profile-name shortening, repo key, and `repos.json` have no algorithm**
Scope: lines 382–384 and 390 and 408.

`Get-RepoKey` is "the first 12 hex characters of the SHA-256 of the lower-cased full path." `delegate.ps1` lines 83–84 resolve the repo and strip a trailing `\`. The plan does not say to use that path, `ToLowerInvariant`, or UTF-8 versus UTF-16. Two encodings produce two `xagent-repo-*` capabilities.

Names over 64 characters "are cut and a 6-character hash added." The cut point, the hash function, and the alphabet are open. AppContainer profile names are limited to 64 characters, so the cut has to leave room for the hash.

`Grant-RepoAccess` writes `%LOCALAPPDATA%\xagent\sandbox\repos.json`. `Remove-SandboxGrants` reads it. The plan does not give the JSON shape.

**11. Drive-letter ownership files are unnamed**
Scope: lines 386–388 and 402.

The runtime letter is kept while another live run uses it, "tracked by `.running` files" in `%LOCALAPPDATA%\xagent\sandbox\letters\`. The plan does not say who creates them, the file name, or when they are deleted. This is a different folder from the runtime cache's `.running` directory, which line 379 makes writable because Cursor writes markers there (probe README: `cscript` cannot clear them inside the container). The plan grants that directory and never says whether `Sandbox.psm1` clears stale Cursor markers.

**12. Run-home environment paths do not match the directories the plan creates**
Scope: lines 392–398; architecture line 104.

`New-SandboxRun` creates `home\.cursor`, `home\AppData\Roaming\Cursor`, `home\AppData\Local`, and `tmp`. The environment bullet puts `USERPROFILE`, `HOME`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, and `TMP` "under `<W>:\.xagent\sandbox`" with no `\home` or `\tmp`. The diagram at line 104 shows `{home,tmp}` as children of `.xagent\sandbox`. Those two readings put `cli-config.json` and `auth.json` in different places, and they disagree on whether `TEMP` is the sandbox directory or `tmp`.

**13. `icacls` identity format is missing**
Scope: lines 383–385 and 391; `probe5.ps1` lines 74–75.

Grants are described as `xagent-repo-<key> (OI)(CI)RX` and `RA` with no inheritance. The probe grants `*{sid}:(OI)(CI)...`. `icacls` treats a capability name as an account name. The plan's `CapabilitySid` helper is what produces the `*S-1-...` identity, and `Grant-RepoAccess` / `New-SandboxRun` never say to use it.

**14. `-Cleanup` covers one worktree name; the script removes many**
Scope: lines 403 and 426; `delegate.ps1` lines 116–162.

`Remove-SandboxRun -Repo -WtName` is one profile and one `.git\worktrees\<WtName>` entry. `-Cleanup` first removes every detached `<TaskId>-<label>` worktree (review and council), then the worker worktree `<TaskId>`. The plan says to call `Remove-SandboxRun` once, "before the worktree is removed." Detached profiles and their access entries stay. The wiring section also never says that `WtName` is the leaf of `$wt` (`TaskId` or `TaskId-<Seat|Agent>`), which is the name `git worktree add` uses under `.git\worktrees\`.

**15. Read-list rules leave `PATH` and `~\.ssh` undecided**
Scope: lines 397 and 409.

The sample entry has `addToPath: true`. The `PATH` bullet says to append "the read list's `path` entries" and never mentions `addToPath`. An entry is refused when it "is" the profile root, `.ssh`, `.aws`, `.cursor`, or `AppData\Roaming` as a whole. That wording is equality. A child such as `~\.ssh\id_ed25519`, or a narrower path under `AppData\Roaming`, is not those paths. `Grant-RepoAccess` would then put the runtime capability on it.

**16. The `feature-skill.md` edit does not match the row that is there**
Scope: lines 499–502; `docs/designs/feature-skill.md` lines 661 and 678.

The risks row is titled "Workers can read any file and reach the network". Its "What remains" cell begins "Unmitigated in v1". There is no row titled "workers can read the whole machine". There is no D19-style amendment line in that file. D19 is a dogfood row in `docs/test-plan.md`. HANDOFF says the D19 decisions were folded into the body with no marker. The Future Improvements bullet at line 678 still says worker sandboxing is future work, via a restricted account, Windows Sandbox, or a VM. File 11 does not change that bullet. After the planned edit the risks cell says the sandbox shipped, and the future-work bullet still describes a different mechanism.

**17. G5's failure check mixes two triggers the module section does not define together**
Scope: lines 461 and 537; file 2 (lines 370–381) has no `XAGENT_SANDBOX_FORCE_FAIL`.

File 6 says `XAGENT_SANDBOX_FORCE_FAIL` makes `Test-SandboxSupport` fail, the module is the only reader, and the summary is `ok: false` with no agent started. The verification plan instead uses a runtime copy whose pipe pattern was removed, plus that variable, and expects "the named error" and nothing written to `runs.jsonl` as sandboxed. The patch path's named error is the "found n times" throw in `Get-SandboxRuntime`, which is a different function. `Fail` in `delegate.ps1` (line 62) exits 1 with `{ok, error}` and writes no `runs.jsonl` line at all. The plan does not say which of those two outcomes the variable produces, or whether a patch throw still writes a line.

**18. The task-template edit fights the build stage's exact-copy rule**
Scope: lines 482–487; `skills/feature/templates/task.md` lines 14–16; `skills/feature/stages/build.md` line 17.

The template's acceptance section is "This command passes" plus `<test, copied exactly>`. The build stage copies `files` and `test` from `feature.json` into that template. The plan says the test instruction names `pwsh -NoProfile -File scripts/test.ps1` when the repo has it, and it does not say whether `<test, copied exactly>` stays. `skills/feature/stages/build.md` is not in the file list. The existing template test only checks that the six headings remain (`feature.Tests.ps1` lines 70–77), so a wording change can satisfy that test and still break the build-stage contract.

## Nit

**19. The third `taskkill.exe` is `Invoke-DoctorCommand`, not a generic helper**
Scope: line 434; `feature.ps1` lines 1806, 2290, and 2556.

The three call sites are the reconcile orphan kill, the verify timeout inside `Invoke-TaskTestCommand`, and the doctor timeout inside `Invoke-DoctorCommand`. Grep finds all three. There is no shared timeout helper to replace until `Stop-ProcessTree` is added.

**20. "Signatures from the probe's `AC` class" overstates what that class exports**
Scope: line 364; `probe5.ps1` lines 11–50.

`AC` exports `GetSid` and `Run`. It has no job object, no `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, no environment block, no `Wait`/`ExitCode`/`Kill`, and no `TokenIsAppContainer`. The plan lists the new methods. The Win32 imports are what the probe actually supplies.

**21. The HANDOFF edits are already present**
Scope: lines 513–517; `docs/HANDOFF.md` lines 44–47 and 58–59.

Next item 5 already records `worker-sandbox`, the libuv 1.52.1 hang, and nodejs/node#66374. The open items already say to watch Node.js for libuv 1.53 and to drop the `node.exe` patch once Cursor bundles it. The plan says to add that status and that watch item, and it does not say to revise these bullets in place.
