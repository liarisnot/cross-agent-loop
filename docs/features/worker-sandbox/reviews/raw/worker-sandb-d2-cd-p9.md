<!-- persona: codebase_details | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow the reviewer persona exactly.This is a round-2 implementation-readiness audit. I'll read the plan section, the prior findings, and the code those claims point at.Round 1 and the resolution are in. Next I’ll check the plan’s claims against the current scripts and the sections it points at.Round-1 fixes that hold against the tree: the cited `taskkill.exe` sites are `feature.ps1` 1806, 2290, and 2556; `feature.Tests.ps1:2469` expects nine checks ending in `log-dir`; the three named "retry once" sentences are `skills/delegate/SKILL.md:144`, `skills/feature/SKILL.md:216` and `:237`, and `skills/feature/stages/build.md:58`; the feature-skill Risks row and Future Improvements bullet match the quoted text; `feature.ps1:1582` really caps one feature at two live runs; `cursor-agent.ps1:57` uses the version regex the plan copies; `index.js` sits beside `node.exe` in the version folder. The findings below are holes in this revision, mostly in the slot, grant, and launch wiring.

## Blocker

**Severity:** Blocker
**Affected scope:** `skills/delegate/scripts/delegate.ps1:37-38`; plan lines 585-592; CUJ 1's `-SandboxCheck -Reserve`
**Discrepancy:** `-Repo` and `-TaskId` are both `[Parameter(Mandatory)]`. The plan adds a `SandboxCheck` parameter set that makes only `-Repo` optional. `-Agent` and `-TaskFile` are enforced later (`delegate.ps1:165` and `:169`), so an early return skips them. `-TaskId` fails at parameter binding. `delegate.ps1 -SandboxCheck` and `delegate.ps1 -SandboxCheck -Reserve` cannot start, and no test in file 6 requires those commands to bind without `-TaskId`. Resolution M10 required no `-TaskId`.

**Severity:** Blocker
**Affected scope:** `delegate.ps1:286-290`; plan lines 546, 593-596, and 638-650
**Discrepancy:** The unsandboxed launcher is always `%LOCALAPPDATA%\cursor-agent\cursor-agent.ps1`. `XAGENT_CURSOR_ROOT` is a `Sandbox.psm1` setting only. File 3 says to build `$cliArgs` as today, and that construction starts with `Test-Path` on the real launcher and `Fail`s when it is missing. File 6 puts the fake CLI under `TestDrive\cursor-agent` and sets `XAGENT_CURSOR_ROOT`, including a `cursor-agent.ps1` copy for `-NoSandbox`. Nothing in file 3 tells `delegate.ps1` to read that variable. The `-NoSandbox` case, and a sandboxed case whose `$cliArgs` are built "as today", either hits the real CLI or fails the existence check. The plan says no test calls a real model.

**Severity:** Blocker
**Affected scope:** Plan lines 564-566 and 570-577; ledger format called Decided at lines 316-318
**Discrepancy:** `Remove-SandboxGrants -Ledger` runs `icacls <path> /remove "*<sid>"`, but the ledger is `{pid, startTime, runtimeVersion, worktree, grants:[{path, spec}]}`. There is no `sid`. `Get-SandboxSlot` calls that function for a crashed run's ledger before the new run has a `Run` object. The slot letter is in the file name, and the container name `xagent.slot-<L>` can be turned back into a SID, but the plan never says to do that or to store the SID. Crash recovery (CUJ 6) cannot remove grants without that choice.

**Severity:** Blocker
**Affected scope:** Grant table lines 184-194, applied by plan line 571; `docs/designs/worker-sandbox-probe/probe5.ps1:74-75`
**Discrepancy:** The table defines inheritance where it wants it: "RA" is "this folder only, with no inheritance," and `.git` children are "read, inherited." The worktree, the read-only worktree, the run home, `<runtime cache>\<version>`, and `.running` say "read + write" or "read + execute" with neither word. Line 571 applies every row with `icacls <path> /grant "*<sid>:<spec>"` and no `/T`. The probe's working grant is `icacls <work> /grant "*${sid}:(OI)(CI)F" /T` and `(OI)(CI)RX` with `/T` on the other trees. Without object-inherit, container-inherit, and `/T`, existing worktree files and the copied Cursor tree are not granted. D5b left the spelling of `icacls` to the phase-3 task; it did not leave the access policy undecided, and this table is that policy.

**Severity:** Blocker
**Affected scope:** Plan lines 559 and 564; `Set-SandboxLetters` and `Get-SandboxRuntime`
**Discrepancy:** The runtime letter is mapped to `<Root>\sandbox\cursor`, and the copy goes to `<CacheRoot>\<version>.partial`. The only directory the plan creates is `idle\`, which creates `<Root>\sandbox` and not `cursor`. `subst` refuses a missing target, and `Copy-Item` does not create missing parents. `-Reserve` maps the letter before the full check builds the cache (line 590), so the first reservation fails. No step creates the cache directory.

## Major

**Severity:** Major
**Affected scope:** Plan lines 566 and 576; Clean-up lines 296-301
**Discrepancy:** `Get-SandboxSlot` says the mutex is released in the `delegate.ps1` scope that took it. `Stop-SandboxRun` runs Clean-up, whose last step is also "release the slot lock." Two releasers, or a release outside `Stop-SandboxRun` while Clean-up still lists it. `Kill` already closes the job handle (line 540), and Clean-up closes the job again on the timeout path.

**Severity:** Major
**Affected scope:** Plan lines 548-555 and 564-565; `cursor-agent.ps1:12-35` and `:49-60`
**Discrepancy:** Version choice says it follows `cursor-agent.ps1`: date, then name, last wins. The launcher sorts only by `Parse-VersionString` (the `YYYYMMDD` integer) descending and takes `-First 1`. The timestamp form the same regex allows (`YYYY.MM.DD-HH-MM-SS-<hash>`) collapses to that integer, so two folders from the same day have no name tie-break. The unit test only requires a set "where name order and date order differ," which does not lock this tie. The sandbox can patch a different folder than the one the unsandboxed launcher runs. The free-letter check has the same class of miss: "free" is defined only from `subst` output (line 555). A real volume is not in that output, so `D:` or a USB drive looks free. `Set-SandboxLetters` says "checks that the letters are free" and does not require three distinct single letters or a `Get-PSDrive` / logical-drive check. There is no error string for a letter that is in use.

**Severity:** Major
**Affected scope:** Plan lines 572 and 576-579; "Cursor login and git config" lines 260-264; probe layout at `probe5.ps1:65`
**Discrepancy:** The copy step names `cli-config.json` and `auth.json` with no source path and no destination under the directories it creates (`home\.cursor`, `home\AppData\Roaming\Cursor`, `home\AppData\Local`). The parenthetical "if present, with the read-only attribute set" can apply to all three files or only `~\.gitconfig`. The login section copies `~\.cursor\cli-config.json` and `%APPDATA%\Cursor\auth.json` as normal files, copies `~\.gitconfig` read-only only when it exists, and leaves `auth.json` writable until the phase-5 token check fails. A read-only attribute now makes that check unable to observe a refresh. The later fix is "read-only to the container," which is an ACL, not the file attribute this step sets. `-Release` never runs `Remove-SandboxGrants` before `DeleteProfile`, so every repo that was granted keeps ACEs for the deleted SIDs. The probe removes with `/T`; the plan's `/remove` has no `/T`, so inherited ACEs on children survive a slot reclaim too.

**Severity:** Major
**Affected scope:** Read list lines 209-211; plan lines 569 and 624
**Discrepancy:** Refusal is `sandbox: read-list entry '<path>' is refused (<reason>); edit sandbox.json`, and the unit tests require the exact message for six cases, including "a mixed-case path." The reason strings are not listed, and the mixed-case input is not a path. "The user's Cursor folders" is an extra protected class beyond `~\.cursor` and `~\AppData\Roaming`. It is not a path. `%LOCALAPPDATA%\cursor-agent` and `%APPDATA%\Cursor` are both plausible, and they are not the same rule.

**Severity:** Major
**Affected scope:** `cursor-agent.ps1:12-60` versus plan line 557; already covered in the version-sort finding above. Separate from that: plan line 564, `Get-SandboxConfig` "returns `sandbox.json`, or defaults."
**Discrepancy:** The missing-file object is never given. `letters` absent, `letters` null, and `read` omitted are different inputs for `Initialize-SandboxLetters` and the fast check.

**Severity:** Major
**Affected scope:** Plan lines 593-598; `delegate.ps1:332` and `:348-350`
**Discrepancy:** On timeout the plan sets `timedOut = $true` and `exitCode = -1`. On success it never says to call `ExitCode` and store the result. The script initializes `$exitCode = -1` and today replaces it with `$proc.ExitCode`. A sandboxed success can leave `-1` in the summary and in `runs.jsonl`. `ExitCode` closes the process handle, so the call has to happen once, after `Wait` returns true, and not on the timeout path.

**Severity:** Major
**Affected scope:** Plan lines 676-686; `skills/feature/stages/build.md:94`; `skills/feature/stages/design-review.md:29`; `feature.ps1:2351-2352`
**Discrepancy:** The three named sentences match the file. Two more copies of the same rule are not in the edit list. `build.md:94` tells a failed council seat to retry once. `design-review.md:29` does the same for a failed lens, and that file is not a target. Both point at SKILL.md and then restate "retry once," so a lead who follows the stage file retries a `sandbox:` error. Line 686 says a `sandbox:` failure is a problem stop and is not counted as a task failure. `Set-FeatureStateTask` increments `failures` on every transition to `failed`. The usage-limit path still sets `-Status failed`. The plan gives no status transition that stops the task without that increment, and no test for it.

**Severity:** Major
**Affected scope:** Plan lines 611-635 and 741-743
**Discrepancy:** File 5 puts the environment-array test, the read-list exact-message tests, and the "repo under `%USERPROFILE%`" refusal in the unit-test group. Those functions are phase 3 (`New-SandboxRun`, read list). Phase 2 says "their unit tests" for the phase-2 functions only. Phase 3 says "container tests" and does not mention those unit tests. The read-list tests and the profile refusal have no phase.

**Severity:** Major
**Affected scope:** `skills/delegate/SKILL.md:54`; plan lines 600 and 665-676
**Discrepancy:** The skill lists the summary fields and does not include `sandboxed`, `sandbox`, or `skillDir`. File 3 adds those fields to the script. File 8's Sandbox section does not add them to that list. `Stop-SandboxRun`'s `notes` are "put into the summary" with no key. After the edit, the skill's field list and the script disagree.

**Severity:** Major
**Affected scope:** Risks line 489; `feature.ps1:1581-1582`; plan lines 566 and 171
**Discrepancy:** The slot mutexes are machine-local (`Local\xagent-slot-<L>`). The cap of two is per feature, inside one `schedule` call. A second feature, or a feature plus a manual `delegate.ps1`, can start a third and fourth sandboxed run. Those runs wait 60 seconds and throw `sandbox: no free slot (both slots busy)`. The risk row says the two slots match the cap. That is true only inside one feature.

## Nit

**Severity:** Nit
**Affected scope:** Plan line 599; `delegate.ps1:349`
**Discrepancy:** The unsandboxed timeout replacement is `try { $proc.Kill($true) } catch {}`. Today's line also does `$proc.WaitForExit(10000)`. `Stop-ProcessTree` waits up to 10 seconds. This path does not.

**Severity:** Nit
**Affected scope:** Plan lines 732-735; `docs/HANDOFF.md:44-48`
**Discrepancy:** File 15 says to revise Next item 5 in place and gives no replacement text. Item 5 still says one AppContainer per worktree, and that the next step is to resolve design-1, lock, and plan. The libuv watch item is the separate Open items bullet at line 60, which the plan correctly leaves alone.
