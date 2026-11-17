<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll start by reading the task file.

# Implementation Readiness Review (round 2) — `docs/designs/worker-sandbox.md`, lines 512–761

## Round-1 resolution check (verified fixed, not re-reported)

I checked the resolution's decisions against the text before looking for new gaps. Actually fixed: B2 (the `patch.json` reuse contract is now explicit, lines 557–563), B3 (argument tail, `--workspace <real path>`, working folder `<slot>:\`, lines 245–249), B4/D2 (per-run grants, no shared capabilities anywhere in the plan), B5 (G7 moved to phase 3), B6 (`skillDir` in summary and `runs.jsonl`; junction swap; the check now reads `feature: worker-sandbox` lines), B7 (the actual SKILL.md line 144 and `build.md` "Failed runs" are named; `build.md` is file 9), B8 (`required = $false`, `feature.Tests.ps1` is file 11), M2/M3 (ancestor RA; `.git` children except `worktrees`; sibling worktrees get nothing), M6, M7, M10, M12, M14–M16, M18, M19, M20 (hex bytes are in the text), M21 (version regex and date sort), M23, M25–M30. M11 is correctly retired rather than fixed: with one permanent container per slot there is no per-worktree container to delete, and `-Cleanup` removing only the worktree is consistent with the new architecture.

The findings below are all in the new material (reserved letters, slots, ledger, per-run grants, read list, host services, Risks) or in the phase plan for it.

---

## Blockers

### B1. The read list cannot reach anything it exists to reach: no ancestor traversal is granted
- **Severity:** Blocker
- **Affected scope:** "What the sandbox can reach" row `Read-list paths` (line 196); "Read list" (199–212); `New-SandboxRun` read-list step (line 569); Risks row "Per-user toolchains are unreadable" (line 488).
- **Finding & Guidance:** AppContainer access needs traverse on *every* parent folder of a path, which this design knows — it grants "Every ancestor of the worktree and of `<repo>\.git`, below the drive root | RA" (line 190) and refuses repos under `%USERPROFILE%` precisely because "the profile's parents cannot be granted safely" (line 191). The read list then grants read + execute on the leaf only, and its own example is `C:\Users\me\AppData\Local\Programs\Python\Python312`. That path needs traverse on `C:\Users`, `C:\Users\me`, `AppData`, `Local`, `Programs`. So either (a) read-list entries also get ancestor RA — which reopens exactly what line 191 refuses, and must then be argued safe for a grant that is per-run — or (b) every entry under the profile is refused, which makes the list useless for its motivating case (ComfyUI's per-user Python, Alternative O, risks row 488). The implementer must pick one, and the two produce opposite behaviour. Also missing: whether the granted leaf is also `addToPath`'d in its real form or in a letter form, and no container test proves a read-list entry is readable (file 5 tests only that its string lands on `PATH`).

### B2. CUJ 1 has no ordering: `-Reserve` maps the runtime letter to a folder that does not exist yet
- **Severity:** Blocker
- **Affected scope:** CUJ 1 (line 82); "Reserved letters and slots" (168–176); `Set-SandboxLetters` (line 564); "Machine setup" is silent; `Remove-SandboxLetters` (line 579).
- **Finding & Guidance:** Settings say the runtime cache is `<Root>\sandbox\cursor` and the idle folder is `<Root>\sandbox\idle`. `Set-SandboxLetters` "creates `idle\`, maps them (runtime to the cache root, slots to idle)" — but the cache root is created only later by `Get-SandboxRuntime`, which `-Reserve` calls *after* `Set-SandboxLetters` (line 590). `subst` to a missing folder fails, so the first-use journey fails on a healthy machine. Nothing says `<Root>\sandbox` exists either. Specify: create `<Root>\sandbox`, `idle\`, and `cursor\`; map runtime; then `EnsureProfile`; then the full check. `-Release` has the mirror gap: it removes the mappings and the profiles but says nothing about the runtime cache (up to ~512 MB) or the idle folder, so "Uninstall" in README (file 12) cannot be implemented as written.

### B3. `Stop-SandboxRun` cannot close the job: the handle is not in `$Run`, and `ExitCode` invalidates it
- **Severity:** Blocker
- **Affected scope:** `RunHandle`/`ExitCode` (lines 528, 539–540); `New-SandboxRun` return (line 573); `Start-SandboxProcess` (line 575); "Clean-up" step "close the job" (line 299); `Stop-SandboxRun -Run -Slot` (line 576).
- **Finding & Guidance:** `New-SandboxRun` returns `{slot, container, sid, runtimeLetter, runtimeVersion, patched, cwd, env}`; the `RunHandle` is returned separately by `Start-SandboxProcess`; `Stop-SandboxRun` is given only `-Run -Slot`. Neither carries the job handle, so the specified clean-up step "close the job" has no argument to act on. Worse, line 539 says `ExitCode` closes the process handle and "a `RunHandle` is not usable after it", so the normal exit path (`Wait` → `ExitCode` → close job) is forbidden by the contract it just defined. The implementer must invent whether the handle goes into `$Run`, becomes a `-Handle` parameter, or gets a separate `CloseJob`. State the lifetime: who owns `ProcessHandle`, `JobHandle` and the resume thread handle (`RunHandle` has no thread field, yet `CREATE_SUSPENDED` is used and only "the three [file] handles" are closed at line 538).

### B4. The canary — the G1/G2 gate — has no specified launcher or parameter mapping
- **Severity:** Blocker
- **Affected scope:** "Requirements checks / Test" (line 277); `Invoke-SandboxCanary` (line 578); `Start-SandboxProcess` (line 575); `New-SandboxRun -Repo -Worktree -WtName` (line 567).
- **Finding & Guidance:** `Invoke-SandboxCanary` "writes the in-container script to `<canary repo>\.xagent\canary.ps1` and runs it with `pwsh -NoProfile -File`". The only specified way into the container builds `"<R>:\<version>\node.exe" "<R>:\<version>\index.js" <CliArgs>`; there is no function, flag or parameter for launching an arbitrary executable. Second, the canary repo is a fresh `git init` throwaway (`<repoParent>\<repo>.xagent\canary-<rand>`), so what are `-Repo`, `-Worktree` and `-WtName` when `New-SandboxRun` grants `<repo>\.git\worktrees\<WtName>` on a repo that has no `worktrees` folder and is not a worktree of anything? Third, `Invoke-SandboxCanary -Repo` receives no `-Runtime`, yet `New-SandboxRun` requires one. All three are decisions on the path that decides whether the sandbox works at all.

---

## Majors

### M1. `-Reserve R,S,T` cannot bind, and who gets the runtime letter is undecided
- **Severity:** Major
- **Affected scope:** file 3 parameters (line 584); CUJ 1 (line 82); `Set-SandboxLetters -Runtime -Slots` (line 564).
- **Finding & Guidance:** `[string]$Reserve (comma-separated letters)` bound from `-Reserve R,S,T` receives a three-element array, which PowerShell converts to the single string `R S T` — `.Split(',')` then yields one token. Declare `[string[]]$Reserve` (or require a quoted string) and say so. Separately, nothing says which of the three letters is the runtime letter; `Set-SandboxLetters` needs `-Runtime` and `-Slots` separately, so the first-is-runtime rule (or similar) is an implementer decision that silently decides whether `<R>:\<version>\node.exe` exists. CUJ 1's suggested set `R, S, T` also contradicts the function's "three free letters, highest first from Z", and its quoted error text is shorter than the function's — for a design that makes error strings "Decided" in the G7 split, one string must win.

### M2. No `icacls` spec strings, and removal is not tied to how the grant was applied
- **Severity:** Major
- **Affected scope:** grant table (182–196); `New-SandboxRun` grant step (line 572); ledger `grants:[{path, spec}]` (line 570); `Remove-SandboxGrants` (line 577); Risks row "Two runs read each other's work … None known" (line 477).
- **Finding & Guidance:** The table gives words — "read + write", "read", "read, inherited", "RA", "read + execute" — and the plan stores them as `spec` and later removes them by path and SID. The mapping to ACL strings is undecided and consequential: `M` vs `F` for "read + write" differs on delete and on `WRITE_DAC`; `RX` vs `R` differs on executing a child `pwsh`; `RA` is `(RD)` with no inheritance. Since the ledger persists `spec` and the next run replays removal without knowing how the grant was applied, also state the application form: parent-only with `(OI)(CI)` (no `/T`), or recursive `/T` — and make `Remove-SandboxGrants` mirror it, otherwise stale explicit ACEs on children survive a `/remove` without `/T`. Today's probe applies grants with `/T` (probe5.ps1:71), which is the trap. The "None known" in the Risks row depends on this being right.

### M3. `Remove-SandboxGrants` has no SID, and the ledger doesn't carry one
- **Severity:** Major
- **Affected scope:** ledger format (line 570); `Remove-SandboxGrants -Ledger` (line 577); `Get-SandboxSlot` crash-recovery call (line 566).
- **Finding & Guidance:** Removal is `icacls <path> /remove "*<sid>"`, but the function takes only `-Ledger`, the ledger holds `{pid, startTime, runtimeVersion, worktree, grants}` with no SID, and `Get-SandboxSlot` holds the SID but does not pass it. Either add `-Sid` (and say `Get-SandboxSlot` passes `$sid`) or record the SID in the ledger — which changes a format the G7 brief calls "Decided". Say also whether a failed removal aborts or continues, and whether the ledger is deleted when removal failed (if it is, the grants leak with no record and the Risks row's ledger mitigation silently stops working).

### M4. Failed-setup clean-up has no defined boundary
- **Severity:** Major
- **Affected scope:** file 3 launch wiring (lines 593–598); "Clean-up" (294–302); `Stop-SandboxRun … notes[]` (line 576); summary fields (line 600).
- **Finding & Guidance:** Setup (`Get-SandboxSlot`, `New-SandboxRun`) and `Start-SandboxProcess` are described as separate steps whose throws go to `Fail`, while `Stop-SandboxRun` is said to run "in the existing `finally`". That `finally` today (delegate.ps1:351) surrounds only the process run, so a throw inside `New-SandboxRun` after the ledger is written leaves the ledger, the grants and the slot mapping in place with no clean-up path. State where the try starts (slot acquisition inside it) and what runs on a throw. Also: `Stop-SandboxRun` returns failures as `notes[]` and the summary "gains" only `sandboxed`, `sandbox`, `skillDir` — `notes` is neither a declared summary field nor fatal, so a failed grant removal is reported nowhere the lead is told to look.

### M5. "A free letter" is used in four places and defined nowhere
- **Severity:** Major
- **Affected scope:** suggested-letters message (line 565); `Set-SandboxLetters` "checks that the letters are free" (line 564); `Test-SandboxSupport` letters check (line 555); container tests "reserve letters from free ones in `BeforeAll`" (line 627).
- **Finding & Guidance:** The stated evidence source is `subst` output, which lists only substituted drives — it cannot show that `R:` is a physical drive or a mapped network share, so a reserved letter that collides with real hardware would pass the check and then fail at `subst`. Specify the predicate (for example `[IO.DriveInfo]::GetDrives()` plus `subst` plus `Test-Path` on the target being ours) once, and use it in all four places; otherwise the test's `BeforeAll` and the production check will disagree.

### M6. `-SandboxCheck` relaxes `-Repo` only; `-TaskId` and the `-Agent` guard still block it
- **Severity:** Major
- **Affected scope:** file 3 parameters (lines 584–586); `delegate.ps1:37` (`$TaskId` mandatory, `ValidatePattern`) and `delegate.ps1:166` (`if (-not $Agent) { Fail }`).
- **Finding & Guidance:** The resolution's M10 decision is that `-SandboxCheck` needs no `-Repo`, `-TaskId`, `-Agent` or `-TaskFile`, but the plan only makes `-Repo` optional and leaves "the default set unchanged". With `$TaskId` still mandatory, `delegate.ps1 -SandboxCheck` (exactly the command CUJ 1 and README tell the user to run) cannot bind. List the full SandboxCheck parameter set: which parameters move, which stay mandatory, and where the `-Agent`/`-TaskFile` guards are skipped. Also state the exit path for the three invalid combinations ("fail with a message" — `Fail`'s JSON, or a parameter-binding error?).

### M7. Read-list refusal reasons are asserted exactly by a test that cannot be written
- **Severity:** Major
- **Affected scope:** "What a refusal does" (line 212); file 5 unit tests (line 622).
- **Finding & Guidance:** The message is `sandbox: read-list entry '<path>' is refused (<reason>)` and the test requires "the refused cases (`~\.ssh`, `~\.ssh\id_ed25519`, the profile root, `AppData\Roaming\x`, a missing path, a mixed-case path) each give the exact message". Six cases, no `<reason>` strings. Enumerate them (for example `under a protected folder`, `is the profile root`, `does not exist`), and say which one wins when an entry is both missing and protected — that decides a test.

### M8. The first-use journey and `-Release` are in no test and no verification bullet
- **Severity:** Major
- **Affected scope:** file 5 (611–636); "Verification Plan" (749–761); build order phase 4 (line 745).
- **Finding & Guidance:** `Set-SandboxLetters` has no unit test, `-Reserve` and `-Release` have no `DelegateLaunch` case (file 6 lists only the invalid combinations and `-SandboxCheck` without `-Repo`), and the Verification Plan has bullets for regression, canary, failure, crash, timeout, overhead, token, G6 and G7 but none for CUJ 1. That is the one path every new user hits first, and the one path that mutates machine state (`subst`, two permanent AppContainer profiles, `sandbox.json`). Add: reserve on a clean root, assert three mappings and two profiles, run the canary, release, assert everything is gone; plus `-Release` refusing while a slot is held (that one test only exists for `Remove-SandboxLetters` directly).

### M9. The sandboxed `DelegateLaunch` case depends on the machine, and `-Reserve` mutates the machine in tests
- **Severity:** Major
- **Affected scope:** file 6 cases (644–650); file 5 container tests (line 627).
- **Finding & Guidance:** File 5 sets `XAGENT_SANDBOX_ROOT`/`XAGENT_CURSOR_ROOT`, but file 6 never mentions `XAGENT_SANDBOX_ROOT`, so its "sandboxed run gives `sandboxed: true`" case reads the user's real `sandbox.json` and needs the user's real letters reserved — and fails with `sandbox: no drive letters reserved` on a machine where that is not true. Say who reserves letters for it. Conversely the container tests write `sandbox.json` into `TestDrive` but call real `subst`/real profiles on the developer's machine, and must not pick a letter the developer already reserved; name the teardown guarantee (profiles deleted even on a failed assertion) as well as the "no free slot" path if the developer's own run holds a slot.

---

## Nits

| # | Scope | Finding |
|---|---|---|
| N1 | Grants, "Run home" row (line 187) | The worktree row already grants read + write on the whole worktree, so the run-home row is redundant for worker runs and only matters for read-only runs. Say that, or the implementer will wonder whether the worktree row is meant to exclude `.xagent/`. |
| N2 | `Get-SandboxRuntime` pruning (line 562) | "Delete older cache versions except the previous one" — the previous one is derivable from the stated sort, but say "second in the version sort" so pruning and selection cannot drift apart. |
| N3 | Risks (line 489) | "Two slots match the cap of two live runs per feature" is true only while one feature is live; two features can each start two runs, so a third run waits 60 s and then hard-stops. One sentence, or the row overclaims. |
| N4 | Open Questions, per-run permission cost (line 72) | The Overhead bullet measures start → agent start, which covers granting but not removal (`Stop-SandboxRun`), so half the open question is never measured. State that removal time is logged separately (`seconds` vs the host's wall clock), or drop that half. |
| N5 | Probe disagreement, "What the sandbox can reach" (line 195) | The design says `C:\Program Files` is readable "already granted by Windows"; the probe README says the same, but `probe5.ps1:71–72` explicitly grants the Pester module folder RX. Name which one is true, since the table is the write allowlist for `New-SandboxRun`. |
| N6 | File 12, `-Release` | README's Uninstall step is `-SandboxCheck -Release`, which per B2 leaves the runtime cache behind; either the bullet says what it leaves or `-Release` removes it. |
| N7 | Host services (213–219) | Containers are deleted and re-created with new SIDs by `-Release`/`-Reserve`, so a future loopback exemption outlives its container. One line saying the opt-in feature must also revoke stale exemptions keeps that out of a future review. |
| N8 | `feature.ps1 doctor` (line 607) | The fast check does not validate `sandbox.json`'s read list, so a refused entry passes `doctor` and fails the first run — the reverse of the M27 fix for the patch. Add the read list to the fast check's problems, or say why not. |

---

## What is now in good shape

The per-run grant table is a real allowlist with a stated purpose per row; the ledger-plus-mutex story correctly hands crash recovery to Windows and uses the ledger only for grants; `Test-SandboxSupport` has a test seam (`XAGENT_SANDBOX_FORCE_FAIL`), a timeout for the libuv probe and a version-pick rule that matches Cursor's launcher; the patch contract is reusable and idempotent with hashes; the `sandbox:` error prefix is defined once and propagated to all three "retry once" sites; `skillDir` closes the G6 check; `scripts/test.ps1` disables Pester's registry; and the Risks table now carries the accepted token-exfiltration residual, the unsandboxed build, and the letter/pattern/read-list residuals with an honest "what remains" column. The gaps above are all in the new mechanisms' edges — what the ACL strings are, who owns the handle, what a "free letter" is, and where the try/finally starts — not in the architecture.
