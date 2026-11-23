# Goldfish Annotated Review Report: design-1 resolution

**Status: resolved** (2026-11-14). Author decisions: D1a, D2b, D3 = reserved letters with per-slot containers (new option c), D4b, D5b (phase 3), D6a, D7c (G3 restated + per-slot containers; host-localhost exemption proven by probe, not granted), D8 measure-first then read-only token, D9a. Part 2 accepted in full with the adjustments those decisions imply (M17 obsolete; repo key and profile-name shortening obsolete with per-slot containers; M11 replaced by end-of-run grant removal plus slot ledger). M20 contested in part (bytes verified); N22 declined.

**Target:** `docs/designs/worker-sandbox.md` (full file, at `23910b0`)
**Findings:** `docs/features/worker-sandbox/reviews/design-1.md` (B = Blocker, M = Major, N = Nit)

Each finding gets one category:
- **PROPOSE FIX:** the finding is valid, and the fix has one defensible answer.
- **AUTHOR DECIDES:** the finding is valid, and the fix is an architecture choice between options. The options are listed and not ranked; you pick.
- **CONTEST:** the finding is wrong, with the evidence cited.
- **DECLINE:** a Nit that is recorded but not fixed.

## Part 1: Author decisions

These need your choice before any edit. Several are linked: choosing to simplify in D2 makes D3 and parts of M17 smaller.

### D1 (B3, M21): How the sandboxed process starts Cursor
- **(a) Direct `node.exe index.js`.** The plan spells out the argument tail (everything after `-File cursor-agent.ps1`) and the working folder. The version is picked with `cursor-agent.ps1`'s own pattern and date sort, and the plan also runs `promote-staged.cmd` and sets `NODE_COMPILE_CACHE` itself.
  - **For:** one process fewer; this is the configuration the probe ran.
  - **Against:** it copies three behaviours of Cursor's launcher, which can drift when Cursor changes it.
- **(b) `pwsh -File` on a copy of `cursor-agent.ps1`** placed next to the patched `node.exe` in the runtime cache, inside the container.
  - **For:** Cursor's own script picks the version and sets the environment, so the argument tail stays as today.
  - **Against:** this layout is unprobed. The launcher's "node.exe beside the script" path and `promote-staged.cmd` inside the container need one probe run. It also adds a pwsh start (about 0.3 s).

Either way, the working folder and `--workspace` must be fixed. I propose `--workspace <real worktree path>`, as the probe ran it, and a working folder of `<W>:\`. Both get covered by one probe run in phase 3.

### D2 (B4, M9, M17): Shared capabilities or per-run grants
- **(a) Keep the shared capabilities** (`xagent-runtime` and `xagent-repo-<key>`), granted once and left in place.
  - The token gets `internetClient` plus both capability SIDs, derived with `DeriveCapabilitySidsFromName`.
  - `repos.json` (`[{repo, key, ts}]`) records them, and `Remove-SandboxGrants` removes them.
  - **For:** a small permission cost per run.
  - **Against:** a second permission system, and grants that outlive the feature.
- **(b) Per-run grants only.** Each run's container SID is granted on the runtime cache (read), the common `.git` data (read), and the parent folders (read-attributes). The existing `-Cleanup` and the after-run step remove them.
  - **For:** no capabilities, no `repos.json`, no `Remove-SandboxGrants`, no leftover grants.
  - **Against:** about 6–10 `icacls` edits per run, and the runtime cache's ACL grows while runs are live. The phase-5 overhead check measures the cost.

### D3 (M8): Drive letters
- **(a) Each run maps its own two letters** (runtime and worktree) under a `Local\xagent-subst` mutex held from picking the letter until `subst` succeeds. Before picking, it removes any `subst` letter pointing into the xagent roots whose run is dead (pid file plus start time).
  - **For:** no lease protocol.
  - **Against:** two letters per live run. With the cap of 2 runs that is 4 letters out of 19.
- **(b) A shared runtime letter with a lease.** One letter for the runtime cache, shared by all runs, with a lease file `letters\<L>.json` holding `{pid, startTime}`, liveness checked by `Test-ProcessStartTimeMatch`, and pruning at start. Also uses the `Local\` mutex.
  - **For:** fewer letters.
  - **Against:** the lease logic itself.

Either way, `Global\` becomes `Local\`. This session lacks `SeCreateGlobalPrivilege`.

### D4 (M13): The read list for per-user toolchains
- **(a) Ship with no read list.** Add one when a real run is blocked on a per-user tool. Remove `sandbox.json` and its rules from the plan, and put the limit in "Limits that stay".
- **(b) Keep it, fully specified.**
  - `addToPath` is false when missing.
  - An entry is refused if it equals, or sits under, the profile root's protected children (`.ssh`, `.aws`, `.cursor`, `.gnupg`, `AppData\Roaming`) or is the profile root itself.
  - Paths are normalized with `GetFullPath`, then compared case-insensitively.
  - A refused or missing entry makes the run `Fail` with `sandbox.json: read-list entry '<path>' is refused (<reason>)`.

### D5 (B5): Where the G7 two-part template is tried
- **(a)** Keep phase 2. Split files 1 and 2 into "Decided" (public functions and their parameters, the `patch.json` shape, the environment list, the error strings, the acceptance tests) and "Yours to decide" (C# marshalling details, how `icacls` calls are built, mutex handling, internal helpers, internal tests).
- **(b)** Move G7 to phase 3 (run setup, launch, stop, cleanup), which is off the patch and profile core, with the same split.
- **(c)** Drop G7 from this feature and try it on the next feature's first `code-hard` task.

### D6 (B6): The G6 freeze method and how it is checked
- **(a) Junction swap**, as designed.
  - **Check:** add `skillDir` (the resolved path of the `delegate` skill folder) to the summary and `runs.jsonl`, so every run shows which copy launched it. This doubles as a general diagnostic.
- **(b) A copy of the lock commit**, as `README.md:81` already recommends: `git worktree add D:\cross-agent-loop.frozen <lock sha>`. The lead launches through that copy's script paths directly. The junctions are not touched, and the user's other sessions keep the live skills.
  - **Check:** the same `skillDir` field.
  - **Against:** the `feature` skill's own `<delegate dir>` comes from where the skill loaded, so the lead must override the paths by hand for this build.

In both, "tested" becomes "`main` at the lock commit `<sha>`".

### D7 (M1): The network story
- **(a) Restate G3** as "every sandboxed run has internet; file isolation (G1) is what limits what can leak; host filtering is a Future Improvement".
  - Fix the Overview sentence.
  - Add a Security row: the Cursor token in the run home can be sent anywhere, accepted because the worker already acts with that token.
  - Alternative K mentions the in-container proxy idea as the Future Improvement's route.
- **(b) Bring back the host allowed list** through a filtering proxy inside the same container. Loopback there works, so no admin step. Shell commands go through `HTTP(S)_PROXY`.
  - This needs a probe first, to see whether Cursor's own streaming traffic works through the proxy, or whether Cursor's hosts get let past it.
  - It adds a proxy component to build, version and test.

### D8 (M5): The Cursor token in the sandbox
- **(a) Copy-back after the run.** If the run home's `auth.json` differs from the one copied in, and the user's file still matches the copy taken at start, replace the user's file atomically (write a temp file, then `Move-Item -Force`) under a `Local\xagent-auth` mutex.
- **(b) Read-only token.** Make the run home's `auth.json` read-only to the container. A refresh inside the sandbox fails, and the run ends with Cursor's login error, which `delegate` reports as `ok:false` telling the user to run `cursor-agent status` outside. No copy-back.
- **(c)** Keep the conditional wording, and add a decision rule to the Verification Plan: any invalidation fails the check and blocks merge until (a) or (b) is added.

### D9 (M31): Target repos whose tests call `taskkill`
- **(a)** Keep it as a documented limit.
- **(b)** Put a `taskkill.cmd` shim first on the container's `PATH`. It supports `/PID n`, `/T` and `/F` and calls `Process.Kill($true)`. Any other form fails with "unsupported in sandbox".

## Part 2: Fixes with one defensible answer (PROPOSE FIX)

| Finding | Fix |
|---|---|
| B1 | Canary folder: `<parent of the repo's .xagent folder>\xagent-canary-<rand>`, outside the profile. Its own container `xagent.canary.<rand>`; `subst` of the canary folder. The in-container script is written by `Invoke-SandboxCanary` into the canary folder. The second canary goes in the canary folder's parent, so it is denied for the right reason. Cleanup in `finally`: letters, then grants, then profile, then folder. |
| B2 | `Get-SandboxRuntime` reuse contract: read `patch.json` first. `patched:true` with the SHA matching → return. `patched:false` with libuv ≥ 1.53 → return. Otherwise copy and patch. Unit test for the second call. |
| B7 | Change the retry sentences in `skills/delegate/SKILL.md` (Rules) and `skills/feature/stages/build.md` ("Failed runs"): an `error` starting with `sandbox:` is not retried and is reported. Add `build.md` to the file list. `Sandbox.psm1` errors all start with `sandbox:`. |
| B8 | `doctor` gets a fast `sandbox` check: `Test-SandboxSupport` called in-process (build, Cursor install, free letters, the patch pattern count for the current version: M27). `required = $false`, so `ready` is unaffected and a failure is shown with the reason. `feature.Tests.ps1` is added to the file list, and its expected check names gain `sandbox`. The canary stays on `-SandboxCheck` only. |
| M2 | Read-attributes, no inheritance, on every ancestor of the worktree and of `.git`, stopping before the drive root. A repo or worktree under `%USERPROFILE%` is refused with `sandbox: repo under the user profile is not supported`. |
| M3 | Read on `.git` without inheritance into `worktrees`: grant `.git` itself RA, and its children `objects`, `refs`, `info`, `hooks` (read-only), `config`, `HEAD` and `packed-refs` read. Grant `worktrees\<WtName>` modify. Sibling worktree folders get nothing. |
| M4 | `scripts/test.ps1` uses `-MinimumVersion 5.5`. The design requires Pester ≥ 5.5 installed for all users. |
| M6 | Copy `~\.gitconfig` into the run home as read-only, if it exists. Canary step: `git status --porcelain` on a clean worktree is empty. SSH remotes are listed in "Limits that stay". |
| M7 | G2 and CUJ 3: "cannot change git-tracked files; can write only its run home under `.xagent/`". The check is named by its command (`git status --porcelain --untracked-files=no`). |
| M10 | `-SandboxCheck` is handled right after the helper functions, before `$Repo` is resolved. It needs no `-Repo`, `-TaskId`, `-Agent` or `-TaskFile`. It prints one JSON object and exits 0 when `ok`, 1 when not. `-Remove` (if D2a) needs `-SandboxCheck`. `-SandboxCheck` with `-NoSandbox` → `Fail`. |
| M11 | `Remove-SandboxRun` is called for every worktree that `-Cleanup` removes, with `WtName` = the folder name of that worktree. Failures go into the cleanup notes. Test: cleaning up a task that has a lens worktree removes both profiles. |
| M12 | The C# specifics: an unmanaged Unicode environment block, entries sorted case-insensitively, double-null terminated, freed in `finally`. `bInheritHandles = true`. Flags `0x4` (`CREATE_SUSPENDED`), `0x400` (`CREATE_UNICODE_ENVIRONMENT`), `0x00080000` (`EXTENDED_STARTUPINFO_PRESENT`), `0x08000000` (`CREATE_NO_WINDOW`). `PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002`. stdin is `NUL` opened for reading. Test: dump `process.env` from inside and check the names. |
| M14 | `Get-SandboxRuntime -CursorRoot -CacheRoot -UvProbe` (a scriptblock), with defaults. Tests pass `TestDrive` paths and a stub that returns `1.53.0`. |
| M15 | A fake CLI fixture selected by `XAGENT_CURSOR_ROOT` (see the note below the table). |
| M16 | `scripts/test.ps1 [-Fast]` runs only the test folders that exist and exits with `min(failed, 250)`. |
| M17 | Follows D2 (all three records are specified under D2a, or go away under D2b). `staleLetters` follows D3. |
| M18 | One shape, used everywhere: summary and `runs.jsonl` get `sandboxed` and `sandbox: {container, runtimeVersion, patched, worktreeLetter, runtimeLetter}`. |
| M19 | On timeout: `timedOut: true`, `exitCode: -1`, as today. |
| M20 | Partly CONTEST (below). The fix: write the hex bytes and lengths into the design. Version comparison: `[version]` after removing a `-suffix`. |
| M22 | Repo key: the SHA-256 of the UTF-8 bytes of `ToLowerInvariant()` of the resolved repo path with no trailing `\`; first 12 hex. The table is updated to match. Profile names over 64 characters: the first 57, then `-`, then 6 hex of the SHA-256 of the full name. `icacls` takes `*<sid>`. |
| M23 | `USERPROFILE`/`HOME` = `<W>:\.xagent\sandbox\home`. `APPDATA`/`LOCALAPPDATA` under `home\AppData\{Roaming,Local}`. `TEMP`/`TMP` = `<W>:\.xagent\sandbox\tmp`. |
| M24 | File 11 quotes the actual Risks row ("Workers can read any file and reach the network"; its "What remains" cell), and the Future Improvements bullet at line 678, and gives the replacement text. The amendment adds an "Amended: <date>" header line, as on 2026-11-13. |
| M25 | Two failure checks: (a) a cache with the pattern bytes zeroed → `sandbox: ... pattern found 0 times`; (b) `XAGENT_SANDBOX_FORCE_FAIL=1`, read first by `Test-SandboxSupport` → `sandbox: forced failure`. Both exit 1 with no agent started and no `runs.jsonl` line, as `Fail` does today. |
| M26 | `templates/task.md` keeps `<test, copied exactly>`. Only one new line is added under Boundaries (the sandbox sentence). The plan stage puts `pwsh -NoProfile -File scripts/test.ps1` in each task's `test` field for this repo. |
| M27 | Covered by B8 (the pattern count in `doctor`). Adds a Risks row "Cursor update changes the pattern". The first run of a Cursor version is not bounded: it is a one-time copy, logged with its time. |
| M28 | Security row: this feature's own build workers run unsandboxed (G6). Mitigation: the frozen copy is the reviewed `main`, and the sandbox is on for every run after merge. |
| M29 | One-line definitions: `fb-stages` (a `docs/test-plan.md` entry; build step 4's `code-hard` run), the denylist (`delegate.ps1` pattern), the read-only check (by its command), the profiles (`skills/delegate/models.json`), the `feature` lifecycle (link to `feature-skill.md`). "lead" in the build table becomes "done by the lead (no worker)". |
| M30 | Add `## Risks & Mitigations`, gathering the Security rows, "Limits that stay" and scalability (cap of 2 runs, letter pool, cache size). Alternatives become **Pros / Cons / Reason for rejection**. Open Questions keeps only what is open; the resolved answers move into the Technical Plan. |
| N1–N21 | Apply all (one-phrase fixes listed in design-1.md). N10: "the existing suite (218 test cases as of 2026-11-12)". |

**Note on M15:** the fake CLI is a small `fake-cursor.js` run by the real `node.exe`, which writes a fixed `{type:"result", subtype:"success", result:"{...}", session_id:"fake"}` line. `XAGENT_CURSOR_ROOT` points `delegate` at a `TestDrive` folder holding `versions\2099.01.01-fake\{node.exe (copy), index.js (the fake)}`. No test calls a real model.

## Part 3: Contested and declined

- **M20, CONTEST (in part).** The claim that the bytes are `\?\pipe\uv\...` with one backslash, 19 bytes, is wrong. The lead read `node.exe` at `0x55df524`: `5c 5c 3f 5c 70 69 70 65 5c 75 76 5c 25 6c 6c 75 2d 25 6c 75 00` (two backslashes, 20 bytes before the NUL). The design's string is correct. The version-comparison half stands (fixed above).
- **N22, DECLINE.** The lens itself kept "network blocking is at best partial" and "most target repos here are Windows-first" as acceptable.
