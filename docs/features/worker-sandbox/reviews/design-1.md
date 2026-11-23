# Goldfish Review Report: design round 1

**Target:** `docs/designs/worker-sandbox.md` at commit `23910b0`. Feature spec is lines 1–332; Detailed Implementation Plan is lines 333–542.
**Preset:** consolidated (all five stages, no checkpoints), chosen by the user 2026-11-14.
**Built from** `docs/features/worker-sandbox/reviews/raw/`:
- `worker-sandb-d1-zo-p5.md`
- `worker-sandb-d1-ic-p5.md`
- `worker-sandb-d1-cm-p6.md`
- `worker-sandb-d1-dc-p7.md`
- `worker-sandb-d1-st-p7.md`
- `worker-sandb-d1-sy-p7.md`
- `worker-sandb-d1-ir-p9.md`
- `worker-sandb-d1-cd-p9.md`
- `worker-sandb-d1-sy-p9.md`
- `worker-sandb-d1-zo-p8.md`

## Reviewer status

| Stage | Lens | Model | Range | Status |
|---|---|---|---|---|
| 5 | zoom_out | grok-4.7-medium | 1–542 | completed (6 findings) |
| 5 | inventive_catalyst | glm-5.2-high | 1–542 | completed (2) |
| 6 | comprehension | composer-2.5 | 1–542 | completed (12) |
| 7 | design_critic | glm-5.2-high | 1–332 | completed (12) |
| 7 | structural | grok-4.7-medium | 1–332 | completed (5) |
| 7 | style | glm-5.2-high | 1–332 | completed (12) |
| 8 | zoom_out | grok-4.7-medium | 1–542 | completed (6) |
| 9 | implementation_readiness | deepseek-v41-flash-1017-medium | 333–542 | completed (20) |
| 9 | codebase_details | grok-4.7-medium | 333–542 | completed (21) |
| 9 | style | glm-5.2-high | 333–542 | completed (7) |

Every lens finished on its first attempt, with no retries and no model fallbacks. The 103 raw findings are merged below into 8 Blockers, 30 Majors and a list of Nits. None was dismissed; each raw finding appears under one item, and its source lenses are listed. A **Lead check** line means the lead checked the claim against the repo or the machine.

## Themes

1. **The launch contract is under-specified.** The plan doesn't fully say what the container process is given: its arguments, working folder, workspace path, capability SIDs, environment block, or handle inheritance (B3, B4, M12). The probe proved the pieces work, but the plan doesn't pin them down.
2. **Two mechanisms break on their second use.** The `node.exe` patch can't run twice on the same version (B2). The `-SandboxCheck` canary uses a folder that the probe showed git can't use (B1).
3. **Both zoom-outs propose cutting mechanism; these are architecture choices for the author:**
   - drop the shared capabilities and grant each run's container SID directly (B4/M9);
   - give each run its own drive letters with no lease (M8);
   - ship without a read list (M13);
   - launch through Cursor's own `cursor-agent.ps1` under PowerShell 7 instead of reimplementing it (B3);
   - freeze `delegate` with a copy, not a junction swap (B6).
4. **Goals and the plan disagree** on the network story (M1), G2 wording (M7), G6 evidence (B6) and G7 placement (B5).
5. **Files the plan must touch but doesn't list:** `skills/feature/stages/build.md` (B7, M26) and `feature.Tests.ps1`, whose doctor test would break (B8).

---

## Blockers

### B1. The canary repo lives under the user profile, where the probe showed git can't work
- **Lenses:** implementation_readiness #1.
- **Scope:** `Invoke-SandboxCanary` (~405–409); `-SandboxCheck`; the Failure check in the Verification Plan.
- **Issue:** The canary repo is `<TEMP>\xagent-canary-<rand>`, which is under `C:\Users\...`. The probe README records this exact layout failing in git ("cannot lock ref HEAD"). So `-SandboxCheck` would report failure on a healthy machine. The plan also doesn't say which container, drive letters or cleanup order the canary uses. Its in-container script isn't in the file list. The second canary site, "next to the repo's parent", is inside `%TEMP%`, so it would be denied for the wrong reason.
- **Recommendation:**
  - Put the canary folder outside the profile, for example `<repoParent>\xagent-canary-<rand>` or a fixed `D:\` folder.
  - Map it with `subst` and give it its own container name.
  - State the cleanup order.
  - Name where the in-container script is written.

### B2. The `node.exe` patch fails on every run after the first of a Cursor version
- **Lenses:** implementation_readiness #2.
- **Scope:** `Get-SandboxRuntime` (~373–381).
- **Issue:** On the second run, the cached `node.exe` is already patched. The pattern count is 0 and the libuv version is still 1.52.1, so the function throws "pattern found 0 times". `patch.json` is written but never read back.
- **Recommendation:** Specify the reuse contract:
  - Read `patch.json` first.
  - If `patched:true` and the SHA-256 matches `patchedSha256`, return without patching.
  - If `patched:false` and libuv is 1.53 or later, return.
  - Copy and patch only when `patch.json` is missing or the hash doesn't match.
  - Add a unit test for the second call.

### B3. The sandboxed launch doesn't say its arguments, working folder or workspace, and the workspace choice wasn't probed
- **Lenses:** codebase_details #1, implementation_readiness #8 and #9, zoom_out p5 #2; related: codebase_details #9 (M21).
- **Scope:** "Launch and kill" (~143–149); `Start-SandboxProcess` (~401); `delegate.ps1` wiring (~418–422).
- **Issue:**
  - **Arguments:** today `$cliArgs` begins with the `powershell.exe -File cursor-agent.ps1` switches. The plan never says which tail goes to `index.js`.
  - **Working folder:** not stated. Today it is the real `$wt`, under `D:\`, whose root the container can't read.
  - **Workspace:** `--workspace W:\` was never probed. The successful Cursor run used the real `D:\...\repo` path, and Cursor's own realpath works on real paths.
  - **What `cursor-agent.ps1` also does:** it runs `promote-staged.cmd`, picks the version with its own sort, and sets `NODE_COMPILE_CACHE`. The plan drops all three.
- **Recommendation (author decides):**
  - (a) Keep a direct `node.exe index.js` launch, and spell out the argument tail, the working folder (`<W>:\` or the real path), and the workspace value. Add a probe step for whichever workspace value is chosen.
  - (b) Inside the container, launch `pwsh -File` on a copy of `cursor-agent.ps1` placed next to the patched `node.exe` in the runtime cache. This keeps Cursor's own version choice and environment, as zoom_out p5 proposes. PowerShell 7 works in the container; only 5.1 doesn't.

### B4. The capability SIDs given to `CreateProcessW` aren't specified, so the runtime and `.git` grants wouldn't apply
- **Lenses:** codebase_details #2, implementation_readiness #15 (in part), zoom_out p8 #1.
- **Scope:** access table (~116–129); `XagentSandbox.Start` (~353); `New-SandboxRun` return (~394).
- **Issue:** A grant to `xagent-runtime` or `xagent-repo-<key>` takes effect only if that capability SID is in the process token. The probe passed only `internetClient`. If the implementer copies the probe, the container can't read the runtime cache or `.git`. zoom_out p8 goes further: the shared capabilities are a second permission system (permanent grants, `repos.json`, a removal command) built only to share two folders.
- **Recommendation (author decides):**
  - (a) Keep the capabilities and state the token list exactly: `internetClient`, `xagent-runtime`, `xagent-repo-<key>`, each derived with `DeriveCapabilitySidsFromName`.
  - (b) Drop the shared capabilities. Grant each run's container SID on the runtime cache and the common `.git` data, and remove those grants in the existing cleanup. This removes `repos.json`, `Remove-SandboxGrants` and the "grants outlive the feature" risk, at the cost of more permission edits per run. The overhead target in Performance would decide between the two.

### B5. Phase 2 can't be both fully specified and the G7 "Yours to decide" experiment
- **Lenses:** implementation_readiness #4, zoom_out p5 #5 (Nit), design_critic #10 (Nit).
- **Scope:** G7; "The two-part task template"; Build order, phase 2.
- **Issue:** Files 1 and 2 dictate signatures, fields, flags, error strings and test cases. If the worker follows them, there is nothing left to decide, and G7 measures nothing. Two lenses also object to running the experiment on the security-boundary task: a bad result there can't tell the template's effect apart from the task's difficulty.
- **Recommendation (author decides):**
  - (a) Split files 1 and 2 into "Decided" (public signatures, `patch.json` shape, environment list, error strings, acceptance tests) and "Yours to decide" (marshalling, `icacls` construction, mutex, helpers).
  - (b) Move G7 to a less critical `code-hard` task, for example phase 3's run setup and cleanup.
  - (c) Move G7 out of this feature.

### B6. G6's pass check can't be met as written, and the freeze has a simpler existing route
- **Lenses:** implementation_readiness #3, zoom_out p8 #4, style p7 M3.
- **Scope:** G6; "Freezing `delegate`"; Machine setup; Verification "G6".
- **Issue:** The check says every `runs.jsonl` line shows the frozen skill path, but no field records a skill path. zoom_out p8 points out that the README's install step already says to use a copy of `skills/` when a feature will change `skills/` itself. A copy needs no junction swap and puts no machine paths in the design. "The current, tested copy" is also an unsupported claim; it should name the commit.
- **Lead check:** `README.md:81` confirms the copy guidance.
- **Recommendation (author decides):**
  - (a) Add a `skillDir` field to `runs.jsonl` and the summary.
  - (b) Change the check to the lead's `test-plan.md` record of the frozen path.

  Separately, choose between the junction swap and a copy of the lock commit at a path the lead uses. Replace "tested" with the lock commit's SHA.

### B7. The plan edits a "Failed runs" section that `delegate`'s SKILL.md doesn't have, and the retry rules stay in place
- **Lenses:** codebase_details #3.
- **Scope:** file 8; `skills/delegate/SKILL.md:144`; `skills/feature/stages/build.md:54–58`.
- **Issue:** Both texts say to retry any failed run once. A sandbox start failure (G5) would be retried, and `build.md` isn't in the file list.
- **Recommendation:**
  - Name the actual sentences to change: the SKILL.md Rules line, and `build.md` "Failed runs".
  - Add `build.md` to the file list.
  - Define how a sandbox start failure is recognised, for example a fixed error prefix such as `sandbox:`.

### B8. The `doctor` sandbox check breaks an existing test and times out
- **Lenses:** codebase_details #4, implementation_readiness #17, design_critic #12, zoom_out p8 #6.
- **Scope:** file 4 `doctor`; `feature.Tests.ps1:2468–2475`; `Invoke-DoctorCommand` (30 s timeout).
- **Issue:** The existing test asserts exactly nine named checks. A first `-SandboxCheck` copies 256 MB and runs a canary, so it would far exceed the 30 s timeout. The plan also doesn't say whether the check is `required` for `ready`. Three lenses say `doctor` should run only the fast checks (build, install, free letters, patch count), with the canary kept to the explicit `-SandboxCheck`.
- **Recommendation:**
  - Add `feature.Tests.ps1` to the file list and update the expected names.
  - Have `doctor` run a fast check (a `-Quick` mode, or `Test-SandboxSupport` called directly) with a stated timeout.
  - Decide whether the check is required for `ready`.

---

## Majors

### M1. The network story disagrees across the Overview, G3 and the plan
- **Lenses:** style p7 M1 and M2, zoom_out p5 #1, design_critic #1, inventive_catalyst #1.
- **Issue:**
  - The Overview still promises a host allowed list.
  - G3 promises an on/off switch, but every container gets `internetClient` and no off mode exists.
  - G3's pass check tests G1, not the switch.
  - The token copied into the run home can be sent anywhere. The Problem section names network exfiltration as the threat, and the Security table accepts this case, so the two contradict each other.
  - inventive_catalyst: a filtering proxy running *inside* the same container avoids the loopback-exemption objection in Alternative K, because the probe showed loopback inside one container works. That leaves Cursor's own streaming traffic through a proxy as the only untested part.
- **Recommendation (author decides):**
  - (a) Restate G3 as "every sandboxed run has internet; file isolation (G1) is what limits leaks; host filtering is a Future Improvement". Fix the Overview, and add the token-exfiltration residual to the Security table.
  - (b) Bring back a host allowed list through an in-container proxy, after a probe of Cursor's traffic through it.

  Option (a) is the smaller change. Option (b) brings back the goal you first approved.

### M2. Git parent-folder grants cover only a repo that sits directly under a drive root
- **Lenses:** zoom_out p5 #3.
- **Issue:** The grants name `<repo>` and `<repoParent>\<repo>.xagent`. A repo at `D:\src\<repo>` also needs `D:\src`.
- **Recommendation:** Grant read-attributes, this folder only, on every ancestor of the worktree and of `.git`, stopping before the drive root. Still refuse repos under the user profile (see the probe README), with a clear error.

### M3. The inherited read grant on `.git` lets runs read each other's `.git\worktrees\<id>`
- **Lenses:** zoom_out p8 #2.
- **Issue:** `(OI)(CI)` read on `.git` reaches every sibling `worktrees\<other>`, which contradicts "concurrent workers can't read each other's worktrees". Making `.git` writable to match the probe would reopen the hooks risk.
- **Recommendation:** Grant read on the common data that is actually needed (`objects`, `refs`, `packed-refs`, `config`, `HEAD`, `info`) and nothing under `worktrees` except this run's own folder. Alternatively, accept and document read access to sibling indexes.

### M4. The design moves the test stack to Pester 6.2.0
- **Lenses:** zoom_out p5 #4.
- **Issue:** The suite's contract is Pester 5.5 or later (`feature-skill.md` Verification Plan, `doctor`, the tests). `scripts/test.ps1` requires 6.2.0 or later.
- **Lead check:** 6.2.0 is what this machine already runs, and the all-users install happened to be 6.2.0.
- **Recommendation:** `scripts/test.ps1` keeps `-MinimumVersion 5.5`. The design says only that Pester must be installed for all users, at any version that satisfies 5.5 or later.

### M5. What happens on a token refresh is left to testing
- **Lenses:** design_critic #3, comprehension #11, style p7 m3.
- **Recommendation (author decides):**
  - (a) Specify the conditional copy-back now: at the end of the run, compare the files, then swap them atomically under a lock.
  - (b) Make the run home's `auth.json` read-only, so Cursor can't refresh inside the sandbox, and state what happens when a refresh fails.

  Either way, give the Verification Plan a decision rule.

### M6. User-level git config is unreachable: identity, SSH remotes and possibly `core.autocrlf`
- **Lenses:** design_critic #2 and #11 (Nit).
- **Issue:** `HOME` moves to the run home, so `~\.gitconfig` isn't read. Workers don't commit (SKILL.md), so identity matters less. But a setting such as `core.autocrlf` in the user's global config would change how `git status` sees the worktree.
- **Lead check (2026-11-14):** `core.autocrlf=true` comes from `C:/Program Files/Git/etc/gitconfig`, the system config, which the container can read. On this machine line endings are unaffected. A user who sets it only in `~\.gitconfig` would still see the problem.
- **Recommendation:**
  - Copy `~\.gitconfig` read-only into the run home, or say why not.
  - Add a canary step: `git status` on a clean worktree is empty.
  - List SSH remotes as a limit.

### M7. G2 says read-only runs can't write, but they can write their run home
- **Lenses:** zoom_out p5 #6, design_critic #5.
- **Lead check:** `delegate.ps1`'s read-only check is `git status --porcelain --untracked-files=no`, so it ignores `.xagent/`. The mechanism works; the wording doesn't match it.
- **Recommendation:** Reword G2 and CUJ 3: "cannot change git-tracked files; can write only its run home". Name the check by its command.

### M8. The drive-letter lease, mutex and markers are unworkable or unspecified
- **Lenses:** implementation_readiness #6 and #16, codebase_details #11, design_critic #7, zoom_out p8 #3.
- **Issue:**
  - A `Global\` mutex needs `SeCreateGlobalPrivilege`, which a non-elevated token lacks.
  - The mutex doesn't cover the `subst` call.
  - The `letters\*.running` files are never named or written, and have no liveness check, so a crash leaks them.
  - The name collides with Cursor's own `.running` folder.
  - zoom_out p8: per-run letters remove the lease entirely.
- **Lead check:** `whoami /priv` in this session shows no `SeCreateGlobalPrivilege`.
- **Recommendation (author decides):**
  - (a) Give each run its own two letters, picked and mapped under a `Local\` mutex. On a collision, take the next free letter. At start, remove `subst` letters whose target is under the xagent roots but not in use by a live run.
  - (b) Keep a shared runtime letter, with a specified lease file (`letters\<L>.json` holding `{pid, startTime}`), liveness checked with `Test-ProcessStartTimeMatch`, and pruning at start.

### M9. Shared capabilities as a second permission system
Merged into **B4**, option (b).

### M10. `-SandboxCheck` has no stated place in `delegate.ps1`, and its required parameters and exit code aren't specified
- **Lenses:** implementation_readiness #5 and #20.
- **Issue:** `delegate.ps1:84` resolves `$Repo` unconditionally, and lines 108–112 write `.git\info\exclude`.
- **Recommendation:**
  - Handle `-SandboxCheck` (and `-Cleanup`) before the repo is resolved.
  - `-Agent` and `-TaskFile` are not required.
  - Define the exit code for `ok:false`.
  - `-Remove` without `-SandboxCheck`, and `-SandboxCheck` with `-NoSandbox`, both `Fail`.

### M11. `-Cleanup` leaves the read-only runs' containers behind
- **Lenses:** implementation_readiness #7, codebase_details #14.
- **Recommendation:**
  - Call `Remove-SandboxRun` inside the detached-worktree loop with `WtName = <TaskId>-<label>`, and in the normal and `-Discard` paths with `WtName = <TaskId>`. `WtName` is the leaf of `$wt`.
  - Collect failures into notes rather than stopping.
  - Add a test that cleanup removes both profiles.

### M12. Environment-block marshalling and handle inheritance are unspecified
- **Lenses:** implementation_readiness #10, codebase_details #7.
- **Issue:** `HANDLE_LIST` needs `bInheritHandles = true`, but the probe passes `false`. A `string[]` can't be marshalled as a Unicode environment block.
- **Recommendation:**
  - Build the block in unmanaged memory: entries sorted case-insensitively, double-null terminated, freed in `finally`.
  - `bInheritHandles = true`.
  - Give the constants: `HANDLE_LIST` = `0x00020002`, `CREATE_SUSPENDED` = `0x4`, `CREATE_UNICODE_ENVIRONMENT` = `0x400`.
  - stdin is a `NUL` handle.
  - Add a test that dumps `process.env` and checks the names.

### M13. Read-list rules are ambiguous, and zoom_out p8 says to drop the list for now
- **Lenses:** implementation_readiness #11, codebase_details #15, zoom_out p8 #5 (Nit).
- **Issue:**
  - `addToPath` is unused by the `PATH` rule.
  - Refusal uses equality, so `~\.ssh\id_ed25519` isn't refused.
  - The refusal behaviour, path normalization and missing paths are undefined.
- **Recommendation (author decides):**
  - (a) Ship with no read list and add one when a real run needs it.
  - (b) Specify it fully: `addToPath` semantics; refuse an entry equal to *or under* a protected path; normalize, then compare case-insensitively; refusal is a `Fail` with the given message.

### M14. Unit tests need test seams the functions don't have
- **Lenses:** implementation_readiness #12.
- **Recommendation:** `Get-SandboxRuntime -CursorRoot -CacheRoot -UvProbe <scriptblock>`, with defaults as today. Replace "mocked" with a stub that returns `1.53.0`.

### M15. `DelegateLaunch.Tests.ps1` has no fake Cursor CLI
- **Lenses:** implementation_readiness #13.
- **Recommendation:** A stub CLI under `TestDrive`, selected by an override (for example `XAGENT_CURSOR_ROOT`). Specify the exact JSON it prints. No test calls a real model.

### M16. `scripts/test.ps1` in phase 1 points at `skills/delegate/tests`, which doesn't exist until phase 2
- **Lenses:** implementation_readiness #14.
- **Recommendation:**
  - Run only the test folders that exist.
  - Give the parameter block (`-Fast`).
  - Exit with `min(failed, 250)`.

### M17. The grants records are referenced but never produced
- **Lenses:** implementation_readiness #15, codebase_details #10 (in part).
- **Issue:** The shape of `repos.json`, the `grants` and `staleLetters` outputs of `-SandboxCheck`, and the contents of `capabilities` are all undefined.
- **Recommendation:** Specify them, or remove them if B4 option (b) and M8 option (a) are chosen.

### M18. The new summary field has two shapes
- **Lenses:** codebase_details #5.
- **Issue:** The Technical Plan gives `{container, runtimeVersion, letters}`; file 3 gives `{container, runtimeVersion, patched, worktreeLetter, runtimeLetter}`. The plan also differs on whether `runs.jsonl` gets only `sandboxed`.
- **Recommendation:** Pick one shape and use it in both places.

### M19. The timeout result isn't tied to today's fields
- **Lenses:** codebase_details #6.
- **Recommendation:** On timeout, keep `timedOut: true` and `exitCode: -1` (not the job's terminate code). `build.md` relies on `timedOut`.

### M20. The pipe-name pattern is ambiguous as bytes, and the version comparison is unstated
- **Lenses:** codebase_details #8.
- **Issue (as raised):** the lens says the bytes in the file are 19 bytes, `\?\pipe\uv\%llu-%lu`, so a search for the Markdown text would find nothing.
- **Lead check (2026-11-14), which refutes the byte claim:** at `0x55df524` the file holds `5c 5c 3f 5c 70 69 70 65 5c 75 76 5c 25 6c 6c 75 2d 25 6c 75 00`. That is `\\?\pipe\uv\%llu-%lu` with **two** leading backslashes, 20 bytes before the NUL. The design text is correct. Its replacement `\\?\pipe\LOCAL\%llu` is 19 characters plus a NUL, which is equal length.
- **Recommendation:**
  - Add the hex sequence and its length to the design, so nobody re-derives it.
  - Compare versions with `[version]` after removing any `-suffix`; that part of the finding stands.

### M21. Which Cursor version is "latest" is undefined, and so is which cache version is "the one before"
- **Lenses:** codebase_details #9, implementation_readiness #20, style p9 #5.
- **Recommendation:** Use `cursor-agent.ps1`'s own version pattern and `Parse-VersionString` sort, or B3 option (b), which removes the question. Never delete a cache version that a live run is using.

### M22. Repo key, profile-name shortening and `icacls` identity format are unspecified
- **Lenses:** codebase_details #10 and #13, style p7 m5.
- **Recommendation:**
  - Repo key: the SHA-256 of UTF-8 `ToLowerInvariant()` applied to the resolved repo path without a trailing `\`. Use the same definition in the table.
  - Names over 64 characters: cut to 57, then add `-` and 6 hex characters of the SHA-256.
  - Grants use `*<sid>` from `CapabilitySid` or the container SID.

### M23. The run-home environment paths don't match the folders the plan creates
- **Lenses:** codebase_details #12.
- **Recommendation:**
  - `USERPROFILE` and `HOME` are `<W>:\.xagent\sandbox\home`.
  - `APPDATA` and `LOCALAPPDATA` are under `home\AppData\...`.
  - `TEMP` and `TMP` are `<W>:\.xagent\sandbox\tmp`.

### M24. The `feature-skill.md` edit targets a row title that doesn't exist, and "D19 style" isn't a marker
- **Lenses:** codebase_details #16, comprehension #7.
- **Issue:** The row is "Workers can read any file and reach the network" at line 661. The Future Improvements bullet at line 678 also needs an update.
- **Recommendation:** Quote the actual row and bullet, and give the replacement text.

### M25. The G5 failure check mixes two triggers
- **Lenses:** codebase_details #17, implementation_readiness #19, comprehension #9.
- **Issue:** `Fail` exits 1 and writes no `runs.jsonl` line at all.
- **Recommendation:** Two checks:
  - (a) A cache with the pattern bytes zeroed gives the named patch error.
  - (b) `XAGENT_SANDBOX_FORCE_FAIL=1`, read first by `Test-SandboxSupport`, gives `ok:false` with that problem.

  In both cases no `runs.jsonl` line is written. State this.

### M26. The task-template edit conflicts with `build.md`'s exact-copy rule
- **Lenses:** codebase_details #18.
- **Recommendation:** Keep `<test, copied exactly>`. Put the `scripts/test.ps1` hint into the plan's task `test` field instead. Add the sandbox sentence only in a new line of the template. If `build.md` changes, list it.

### M27. When a Cursor update breaks the patch, the user finds out mid-run
- **Lenses:** design_critic #6.
- **Recommendation:**
  - The fast `doctor` check (B8) reports the patch-pattern count for the current Cursor version.
  - Add a Risks row for "Cursor update changes the pattern".
  - Give the first-run cost a bound, or explicitly no bound.

### M28. This feature's own build workers run unsandboxed, and only the build-order note says so
- **Lenses:** design_critic #4.
- **Recommendation:** Add a Security row with the mitigation: a short build, a frozen reviewed copy, and the sandbox on for every run after merge.

### M29. Undefined insider terms
- **Lenses:** comprehension #1–#5.
- **Issue:** `fb-stages`; "build step 1" and the secret-variable denylist; "the existing read-only check"; the profiles `code`, `code-hard` and `lead`; the `feature` lifecycle (`build`, plan).
- **Recommendation:**
  - Add one-line definitions or links: `fb-stages` → `docs/test-plan.md` entry; denylist → `delegate.ps1` pattern; read-only check → command; profiles → `skills/delegate/models.json`; lifecycle → `feature-skill.md`.
  - "lead" isn't a profile: reword the build table.

### M30. Structure: no Risks heading, the Alternatives fields differ from the template, and Open Questions holds resolved items
- **Lenses:** structural #1–#3.
- **Recommendation:**
  - Add `## Risks & Mitigations`, gathering the Security table, "Limits that stay" and scalability: concurrent runs, the drive-letter pool, cache growth.
  - Convert the Alternatives to **Pros / Cons / Reason for rejection**.
  - Keep only the open questions in Open Questions (token refresh, per-run permission cost, `taskkill` in target repos), and move the resolved answers to the Technical Plan.

### M31. Target repos whose tests call `taskkill` must change (inventive: a `taskkill` shim on `PATH`)
- **Lenses:** inventive_catalyst #2 (Nit, raised here because it affects every target repo).
- **Recommendation (author decides):**
  - (a) Ship a `taskkill.cmd`/`.ps1` shim in the runtime cache, placed first on the container's `PATH`, covering `/PID /T /F` through `Kill($true)`.
  - (b) Keep it as a documented limit.

---

## Nits

| # | Lens | Scope | Fix |
|---|---|---|---|
| N1 | comprehension #6 | Non-Goals, "`agy` … (T0)" | Spell out Antigravity and T0, or link `agy-tos` decision. |
| N2 | comprehension #8, structural #5 | Alt I "phantombot"; citations | Make PR and issue references Markdown links, and define phantombot at first use. |
| N3 | comprehension #10, ir #18 | Launch and kill; CUJ 5 | The job object covers sandboxed runs only. Unsandboxed runs use best-effort `Kill($true)`, as today. |
| N4 | comprehension #12 | Access table, "read attributes only, this folder only" | Say "RA, no inheritance; lets git stat the folder, not list it". |
| N5 | structural #4 | Before Additional Resources and before Detailed Implementation Plan | Add the template's horizontal rules. |
| N6 | style p7 m1 | Performance | Write "adds no fixed memory cost" and drop "the same memory". |
| N7 | style p7 m2 | Open Questions, "0.5 s" | Cite the probe run (probe5, 459 ms for `--version`). |
| N8 | style p7 m4 | Alt A, "the same isolation" | Change to "comparable isolation". |
| N9 | style p7 n1 | Overview, "of its own" | Delete. |
| N10 | style p7 n4, style p9 #7, ir #19 | Verification, "218 existing" | `feature.Tests.ps1` has 166 `It` blocks; 218 counts expanded cases. Say "the existing suite (218 test cases on 2026-11-12)", or drop the number. |
| N11 | design_critic #8, ir #20 | Overhead target | Add "not a gate; record it in `test-plan.md` if exceeded". |
| N12 | design_critic #9 | Unsandboxed `Kill($true)` | Add a two-level child-tree test for the unsandboxed path. |
| N13 | ir #20 | `RunHandle` | Public fields; `ExitCode` closes the handles. |
| N14 | codebase_details #19 | File 4 | The third `taskkill` is in `Invoke-DoctorCommand`, not a generic helper. |
| N15 | codebase_details #20 | File 1, "signatures from the probe's `AC` class" | `AC` supplies only the Win32 imports and `GetSid`/`Run`. The rest is new. |
| N16 | codebase_details #21 | File 13 | The HANDOFF item already exists: "revise item 5 in place" instead of "add". |
| N17 | style p9 #1 | `Invoke-SandboxCanary`, "always cleans up" | Write "cleans up in `finally`". |
| N18 | style p9 #2 | Help comment, "guardrail" | Write "sandbox behavior". |
| N19 | style p9 #3 | Canary pass, "anywhere" | Write "in the logs, summary or branch". |
| N20 | style p9 #4 | `IsAppContainer`, "nested" | Write "inside an already-sandboxed process". |
| N21 | style p9 #6 | Canary, "next to the repo's parent" | Name the path (see B1). |
| N22 | style p7 n2, n3 | Problem; Alt B | No change (the lens kept them as acceptable). |
