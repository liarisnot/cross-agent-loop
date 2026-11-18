# Goldfish Review Report: design round 2 (re-audit of phases 7 and 9)

**Target:** `docs/designs/worker-sandbox.md` at `b4ede60`. Feature spec is lines 1–511; Detailed Implementation Plan is lines 512–761.
**Scope:** a re-audit after round 1's resolution (`resolution-1.md`). The user chose phases 7 and 9 only. The phase 5, 6 and 8 lenses of round 2 are logged as not run, waived by the user.
**Built from** `docs/features/worker-sandbox/reviews/raw/`:
- `worker-sandb-d2-dc-p7.md`
- `worker-sandb-d2-st-p7.md`
- `worker-sandb-d2-sy-p7.md`
- `worker-sandb-d2-ir-p9.md`
- `worker-sandb-d2-cd-p9.md`
- `worker-sandb-d2-sy-p9.md`

## Reviewer status

| Stage | Lens | Model | Range | Status |
|---|---|---|---|---|
| 7 | design_critic | glm-5.2-high | 1–511 | completed (7 Major, 4 Nit) |
| 7 | structural | grok-4.7-medium | 1–511 | completed (1 Major, 3 Nit) |
| 7 | style | glm-5.2-high | 1–511 | completed (2 Major, 5 Nit) |
| 9 | implementation_readiness | deepseek-v41-flash-1017-medium | 512–761 | completed (4 Blocker, 9 Major, 8 Nit) |
| 9 | codebase_details | grok-4.7-medium | 512–761 | completed (5 Blocker, 9 Major, 2 Nit) |
| 9 | style | glm-5.2-high | 512–761 | completed (5 Major, 8 Nit) |

All six lenses finished on their first try.

**Round-1 fixes:** every lens that checked them reports round 1's resolved items as fixed. Nothing from round 1 is raised again.

**Round 2 findings:** all are in the new material: the slots, the ledger, the grants, the read list, the canary wiring and the `delegate.ps1` parameter sets. The 80 raw findings merge into 7 Blockers, 15 Majors and 14 Nits below.

**Suggested resolution:** each item carries one, using the round-1 categories:
- **FIX:** valid, with one defensible answer.
- **CONTEST:** wrong, and the evidence is cited.
- **DECLINE:** a Nit, recorded and not fixed.

No item needs an architecture choice. Where a finding offered options, one was clearly smaller and kept your round-1 decisions, so it is proposed as the fix.

---

## Blockers

### R1. The `-SandboxCheck` parameter set still requires `-TaskId`
- **Lenses:** cd #1, ir M6.
- **Issue:** `delegate.ps1:37` makes `-TaskId` mandatory, and the plan relaxed only `-Repo`. So `delegate.ps1 -SandboxCheck` (CUJ 1, README) can't even bind.
- **FIX:** Use two parameter sets:
  - `Run`, the default: `-Repo` and `-TaskId` mandatory, as today.
  - `Check`: `-SandboxCheck` mandatory, `-Repo` optional, `-Reserve` and `-Release` allowed, and no other parameter needed.

  `-SandboxCheck` returns before the `-Agent` and `-TaskFile` guards (`delegate.ps1:165,169`). Invalid combinations go through `Fail` (exit 1, JSON). A file-6 test binds `delegate.ps1 -SandboxCheck` with no other parameter.

### R2. `-Reserve` maps the runtime letter to a folder that doesn't exist yet; `-Release` leaves the cache behind
- **Lenses:** ir B2, cd #5, ir N6.
- **FIX:**
  - **`Set-SandboxLetters`** first creates `<Root>\sandbox`, `\cursor` and `\idle`, then maps the letters, then creates the profiles.
  - **`Remove-SandboxLetters`** removes the mappings, deletes both profiles, deletes `<Root>\sandbox` (cache, idle folder, ledgers), and removes `letters` from `sandbox.json`, keeping `read`.
  - README's uninstall step says this.

### R3. The job handle has no owner, and `ExitCode` invalidates the handle before the job is closed
- **Lenses:** ir B3, cd Major (two releasers).
- **FIX:** Redefine the handle API:
  - `Start` resumes the process and closes the thread handle itself.
  - `Kill(h)` only terminates the job.
  - `Finish(h)` returns the exit code and closes the process and job handles; it can be called once.
  - `Stop-SandboxRun -Run -Slot -Handle` calls `Finish` when the handle is still open. It is the **only** place the slot mutex is released, and it runs in the scope that took it.

### R4. The canary can't launch `pwsh` and isn't a real worktree
- **Lenses:** ir B4.
- **FIX:**
  - `Start-SandboxProcess` takes `-Exe` and `-Arguments`. The Cursor launch builds `<R>:\<version>\node.exe` plus `index.js` on top of it.
  - The canary is a **real detached worktree** of the given repo: `git worktree add --detach <repoParent>\<repo>.xagent\canary-<rand>`. `New-SandboxRun` then applies unchanged.
  - The in-container steps become `git status`, `git diff` and `git log -1`. There's no commit, because workers can't write objects.
  - `Invoke-SandboxCanary` calls `Get-SandboxRuntime` itself.
  - Clean-up runs `git worktree remove --force`.

### R5. The crash ledger doesn't record the SID, so removal can't run
- **Lenses:** cd #3, ir M3.
- **FIX:**
  - The ledger becomes `{slot, sid, pid, startTime, runtimeVersion, worktree, grants:[{path, spec}]}`.
  - `Remove-SandboxGrants -Ledger` uses the ledger's `sid`.
  - A failed removal doesn't stop the others. The ledger is rewritten with only the failed entries and kept, and the failures go into the summary as `sandboxNotes`.

### R6. Inheritance and `icacls` spec strings are unspecified
- **Lenses:** cd #4, ir M2, dc Nit 1.
- **FIX:** Exact specs in the access table:

  | Target | Spec |
  |---|---|
  | worker worktree, run home, `.git\worktrees\<WtName>`, `.running` | `(OI)(CI)M` |
  | read-only worktree, runtime version folder, `.git` children, read-list entries | `(OI)(CI)RX` |
  | `.git` itself | `RX` (no inheritance) |
  | `.git\worktrees`, ancestors, runtime cache root | `RA` |

  Grants and removals both run without `/T`. Windows propagates inherited entries to existing children (git creates worktree files with inherited ACLs), and `/remove` on the parent removes the inherited copies. The probe's `/T` was belt-and-braces, not a requirement. A container test checks that a file created *before* the grant becomes readable.

### R7. Read-list entries under the profile: parents aren't granted
- **Lenses:** ir B1.
- **Assessment:** CONTEST in part, FIX in part.
  - **CONTEST:** the claim that AppContainer access "needs traverse on every parent folder" is wrong. Windows' bypass-traverse privilege applies. In the first probe run, Pester under `<profile>\OneDrive\Documents\...`, with only the module folder granted, was imported and passed (`worker-sandbox-probe/README.md`, Pester row; `inner2.ps1`).
  - **Still valid:** tools that *stat* their parents, as Node and git do, fail at any parent without RA.
  - **The profile root was refused for repos** because `C:\Users` itself can't be granted without admin; the user can grant inside their own profile.
- **FIX:**
  - Each read-list entry also gets `RA` on its ancestors from the profile root (inclusive) down. Nothing is granted above the profile root.
  - A phase-3 container test runs a program from a read-list entry under the profile: a copy of `node.exe`, which stats its parents, placed under `TestDrive`'s profile-like path. If it fails, a non-stat tool (`pwsh -File`) shows the difference.
  - Phase 3 also records whether ComfyUI's Python works, as a probe step.

---

## Majors

| # | Finding | Lenses | Resolution |
|---|---|---|---|
| R8 | **Two logon sessions can share a slot SID.** `Local\` mutexes are per session, so another session could take "slot S" while it's live. | dc M1, dc Nit 4 | **FIX:** a slot counts as free only if its mutex is taken **and** its ledger is absent or names a dead pid. A live ledger from another session means busy. A Risks row says isolation assumes one interactive user. |
| R9 | **The `AbandonedMutexException` wording reads as "skip the slot".** | dc M2, sy-p7 S1 | **FIX:** reword: "the waiter now owns the mutex and takes the slot, then removes the dead run's ledger grants". Narrow "with no clean-up logic" to the lock. Add a test: a child process takes the mutex and exits, and the next call takes the slot. |
| R10 | **A `taskkill` hang looks like an ordinary timeout to the lead.** | dc M3 | **FIX:** the Risks row names the observable: `timedOut: true` with `taskkill` in the run's commands. The task-template line is already in file 10. No shim (D9 stands). |
| R11 | **The read list doesn't protect the sandbox's own folders.** The refusal reasons aren't listed, and "the user's Cursor folders" isn't a path. | dc M4, ir M7, cd Major | **FIX:** refusals are checked in this order, first match wins: <ol><li>`is the profile root`</li><li>`is under a protected folder (<folder>)`: `~\.ssh`, `~\.aws`, `~\.gnupg`, `~\.cursor`, `~\AppData\Roaming`, `%LOCALAPPDATA%\cursor-agent`</li><li>`is under the sandbox's own folder` (`<Root>`)</li><li>`does not exist`</li></ol>Paths are normalized first, so mixed case can't bypass a protected folder. |
| R12 | **The host-services opt-in has no specified surface.** | dc M5, ir N7 | **FIX (small):** the surface stays with the first feature that needs it (D7). This feature adds only: `-Release` lists any loopback exemption still registered for a slot SID (`CheckNetIsolation LoopbackExempt -s`) and prints the admin command to remove it. |
| R13 | **G3's pass check is vacuous.** | dc M6 | **FIX:** the canary adds `Invoke-WebRequest https://example.com` and expects status 200, so it proves internet is on while the canaries stay unreadable. |
| R14 | **`-Reserve R,S,T` binds wrongly, the runtime letter is undecided, and the CUJ 1 example contradicts the rule.** | dc M7, ir M1 | **FIX:** `[string[]]$Reserve`, three distinct letters; the **first is the runtime letter**. Suggested letters are the three highest free letters, from Z down. CUJ 1's example becomes `Z, Y, X`, and its quoted error matches the function's exact string. |
| R15 | **The clean-up on a failed setup has no boundary.** | ir M4 | **FIX:** the `try` begins before `Get-SandboxSlot`, and `finally` calls `Stop-SandboxRun` whenever a slot was taken. `sandboxNotes` is a declared summary field. |
| R16 | **"Free letter" is undefined.** | ir M5, cd Major | **FIX:** one predicate, `Test-LetterFree`. A letter is free if it isn't in `[IO.DriveInfo]::GetDrives()` and not in `subst` output. A letter is "ours" if `subst` maps it to its expected target. Letters A–C are never suggested. In use: `sandbox: letter <L>: is in use`. |
| R17 | **The version tie-break differs from Cursor's launcher.** | cd Major | **FIX:** use the launcher's exact expression: `Sort-Object { Parse-VersionString $_.Name } -Descending \| Select-Object -First 1`, over `Get-ChildItem` in its default order. The test asserts the same pick as the launcher's function, run on the same folder set. |
| R18 | **The copy step is ambiguous, and the read-only attribute conflicts with the token check.** | cd Major, sy-p9 S3, dc Nit 2 | **FIX:** `cli-config.json` goes to `home\.cursor\`, and `auth.json` goes to `home\AppData\Roaming\Cursor\` as a normal file. `~\.gitconfig`, if present, goes to `home\` with the read-only attribute. One sentence says nothing is ever copied back. The later "read-only token" fix (D8) is an ACL (`RX` only for the slot SID on that file), not an attribute. |
| R19 | **A sandboxed success can report `exitCode: -1`.** | cd Major | **FIX:** after `Wait` returns true, `exitCode = Finish(handle)`. On timeout: `Kill`, `exitCode = -1`, `timedOut = $true`. |
| R20 | **Two more "retry once" copies, and the `sandbox:` stop contradicts the usage-limit path.** | cd Major, sy-p9 S8 | **FIX:** add `stages/build.md:94` (council seats) and `stages/design-review.md:29` (lenses) to file 9. Each spells the rule out in full, with no "the same". A `sandbox:` failure follows the **usage-limit path** in `build.md:56`: set the task `failed`, then a problem stop at once. Drop "not counted as a task failure". |
| R21 | **Unit tests are in the wrong phase, and the test environment isn't isolated.** | cd Major, ir M9, ir M8 | **FIX:** <ul><li>The env-array, read-list and profile-refusal tests go to phase 3.</li><li>File 6 sets `XAGENT_SANDBOX_ROOT` and `XAGENT_CURSOR_ROOT`, and reserves its own letters in `BeforeAll` (skipped if fewer than three are free). `AfterAll` releases in `finally`.</li><li>New tests: reserve → three mappings and two profiles → canary → release → all gone; and `-Release` refused while a slot is held.</li><li>A new Verification bullet covers CUJ 1.</li></ul> |
| R22 | **`delegate.ps1` ignores `XAGENT_CURSOR_ROOT`, so the fake CLI is never used.** | cd #2 (Blocker, raised as Major here) | **FIX:** `delegate.ps1` reads `XAGENT_CURSOR_ROOT` (default `%LOCALAPPDATA%\cursor-agent`) for both the unsandboxed launcher path and the sandboxed runtime. Downgraded to Major because the fix is one line, but it is required for file 6. |

---

## Smaller fixes and Nits

| # | Finding | Lenses | Resolution |
|---|---|---|---|
| R23 | SKILL.md's summary field list lacks `sandboxed`, `sandbox`, `skillDir`, `sandboxNotes` | cd Major | FIX: file 8 adds them. |
| R24 | "Two slots match the cap" is true only within one feature | cd Major, ir N3 | FIX: reword the Risks row. A second feature or a manual run can make a third run wait 60 s, then fail. |
| R25 | Structure: Additional Resources and Future Improvements sit under Risks; a rule is missing before NFR; the host-services question duplicates a Non-Goal; section names don't match | st #1–#4 | FIX: promote both to H2 with rules; add the rule; drop the host-services open question; make "Version choice" an H4 and fix the cross-references ("Cursor login and git config", "Risks & Mitigations"). |
| R26 | Style: "nothing else readable is secret" is unbounded | sy-p7 S3 | FIX: name the readable set (`cli-config.json`, `.gitconfig`, read-list paths: no credentials). |
| R27 | Style: "proven", "why it suits", the redundant tail, bare "None known" | sy-p7 S2, S4, S5, S7 | FIX: one-phrase edits. |
| R28 | Style: "still works outside the container" | sy-p7 S6 | DECLINE: a measured fact, not reassurance. The probe ran the patched copy outside the container (spawn tests 2026-11-13). It matters because the same cached copy could be run outside by mistake. |
| R29 | Plan: the uv comparison isn't restated at the step; `Get-SandboxSlot` order; the "same conditions" referent; "-TimeoutSec 4" | sy-p9 S1, S2, S5, S7 | FIX. |
| R30 | sy-p9 S4: "a read-only run cannot write its worktree" contradicts the table | sy-p9 S4 | CONTEST: the table grants the read-only worktree **read** (row 2), not read + write; the lens read the worker row. The test is correct. |
| R31 | ir N5: is `C:\Program Files` really readable without a grant? | ir N5 | CONTEST: probe run 6 (`README`, Pester row) loaded Pester from `C:\Program Files\PowerShell\Modules` with no grant. The OneDrive grant in `probe5.ps1` came from before the all-users install. |
| R32 | ir N1: the run-home row is redundant for workers | ir N1 | FIX: add "(needed for read-only runs; covered by the worktree grant for workers)". |
| R33 | ir N2, N4, N8: pruning wording; removal time isn't measured; `doctor` doesn't validate the read list | ir N2, N4, N8 | FIX: "the second in the version sort"; log removal time as `sandboxSeconds.remove`; the fast check validates the read list (R11 rules). |
| R34 | Unsandboxed kill has no wait; HANDOFF text unspecified; `agy` filler; "by hand"; "(the live copy)"; the token-refresh wording | cd Nits, sy-p9 S6, S9–S13 | FIX for the kill wait (`WaitForExit(10000)`) and the token wording. DECLINE the rest (wording only; the HANDOFF text is written at sign-off from the final state). |
| R35 | dc Nit 3: the Pester version phrase | dc Nit 3 | FIX: "any version ≥ 5.5; this machine has 6.2.0". |
