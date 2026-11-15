<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
## Verdict on the caller's three questions

**Is anything from the old `sandbox-access` lost?** No function or test is lost. The six seam helpers named in round 3 (`Test-SandboxReadList`, `Assert-SandboxOutsideProfile`, `Get-SandboxEnvironment`, `Get-SandboxGrantList`, `Read-SandboxLedger`, `Write-SandboxLedger`, plus `Remove-SandboxGrants` and the `Test-SandboxSupport` read-list check) all appear exactly once: read list, profile refusal, environment and the support check in `sandbox-readlist`; grant list, ledger and grant removal in `sandbox-grants`. The test list from file 5 is likewise split cleanly (environment array, every refusal, `addToPath`, `%USERPROFILE%` refusal → readlist; row test, unremovable-entry removal → grants). One *connection* is lost in the split, though: who turns a read-list entry into grant rows, and where that is asserted (finding 3).

**Is each half testable on its own?** `sandbox-readlist` yes, fully: every case is pure unit work in `TestDrive` plus the existing synthetic Cursor tree, and its one public-facing change (`Test-SandboxSupport`) already accepts `-CursorRoot`/`-CacheRoot`/`-UvProbe`. `sandbox-grants` is testable in principle but one of its two tests inherits an unstated prerequisite (a SID that `icacls` will grant) that collides with its own "creates no AppContainer profile" rule (finding 4).

**Under ~20 minutes / 600 lines each?** Yes, both. Estimates below.

| Task | Module lines | Test lines | Changed total | Est. worker minutes |
|---|---|---|---|---|
| `sandbox-readlist` | 100–140 | 120–180 | 220–320 | 10–14 |
| `sandbox-grants` | 150–210 | 150–220 | 300–430 | 15–22 |

Basis: `sandbox-core` produced ~1,842 changed lines in 926 s (`docs/test-plan.md`), i.e. roughly 600 lines ≈ 20 min of output plus a debugging tail that scales with unprobed Windows behaviour. `sandbox-grants` sits in the upper part of the band, but its only genuine wildcard is the ACL fixture (finding 4). Both are well inside the gate.

---

## Findings

### 1. Severity: Major
**Affected scope:** `sandbox-readlist` brief, `Test-SandboxReadList` and its use inside `Test-SandboxSupport`.

**Finding & guidance:** The two required behaviours are stated in terms that contradict each other, and the mechanism that reconciles them is not given. `Test-SandboxReadList` "throws on the first refused entry", but `Test-SandboxSupport` must report "one problem per refused entry, in config order, after the letter problems". A function that throws on the first refusal cannot yield the full ordered problem list without something else, and three implementations are equally reasonable: an `-All`/`-Problems` collector parameter on `Test-SandboxReadList`, a private per-entry validator it is built on (which `Test-SandboxSupport` also calls), or `Test-SandboxSupport` looping and catching per entry. The worker for `sandbox-lifecycle` then calls `Test-SandboxReadList` expecting throw-on-first, so whichever shape is chosen becomes a seam.

Guidance: pin it in the brief, e.g. "`Test-SandboxReadList` is a thin wrapper: it calls a private per-entry validator and throws the first refusal. `Test-SandboxSupport` iterates the config entries itself, calls the same per-entry validator, and adds one problem per refused entry." That also makes the "both message forms" test a one-liner in both directions.

### 2. Severity: Major
**Affected scope:** `sandbox-readlist` and `sandbox-grants` briefs — the parameter lists of the private seam functions these tasks *create* and later tasks *call*.

**Finding & guidance:** The briefs pin function names, error strings and the design's *public* signatures, and `sandbox-grants` even says in `Decided` that "the public function signatures as the design states them" are fixed — but the seams the next workers must call are private and their parameter lists are nowhere. Concretely:
* `Get-SandboxGrantList` is pinned only as "taking the worktree name as an explicit parameter", yet the access table it must produce needs the repo root (for `<repo>\.git` and its children), the worktree path, the runtime cache or version (for `<runtime cache>` and `<runtime cache>\<version>\.running`), the read-only flag, and the normalized read-list entries. `sandbox-lifecycle`'s `New-SandboxRun` must call this after `Test-SandboxReadList` and before the ledger write, and nothing says what it passes.
* `Get-SandboxEnvironment` "from 'Launch and kill'" needs the slot letter (`USERPROFILE`, `APPDATA`, `TEMP`, `CURSOR_INVOKED_AS`, `NODE_COMPILE_CACHE`) and the read-list entries with `addToPath` for `PATH`, and again nothing says so; `New-SandboxRun` returns this as `env`.
* `Assert-SandboxOutsideProfile` "(for a repo or worktree)" leaves open one path, two paths, or a `-ReadOnly` variant.
* `Read-SandboxLedger`/`Write-SandboxLedger` are named with no signature at all, and `Get-SandboxSlot` and `Stop-SandboxRun` in the later tasks both need the exact shape.

This is the round-2 `ir 8` class of defect (`Decided` must cover the shared interfaces), reappearing one split later. It is contained because the tasks are sequential and edit the same file, but a `sandbox-readlist` worker and a `sandbox-grants` worker will each invent a different seam, and `sandbox-lifecycle` then guesses.

Guidance: add one line per function to each brief, e.g. "`Get-SandboxGrantList -Repo -Worktree -WtName -Runtime -ReadOnly -Read` returns `[{path, spec}]` in the table's order; `New-SandboxRun` passes exactly its own parameters plus the value `Test-SandboxReadList` returned", and the equivalent for `Get-SandboxEnvironment -Slot -Read` and `Assert-SandboxOutsideProfile -Path [-Label]`. No grant-row or ledger-body detail is needed for this — only the parameter lists.

### 3. Severity: Major
**Affected scope:** the read-list → grant-row seam between `sandbox-readlist` and `sandbox-grants`; `sandbox-grants`'s test list.

**Finding & guidance:** Round 3's `ir 9` was fixed by moving `Get-SandboxGrantList` into `sandbox-access` ("the complete `[{path, spec}]` list … including read-list ancestors"). The re-split puts the row builder in `sandbox-grants` and the read-list validator in `sandbox-readlist`, and nothing now says who composes read-list rows, or that they exist. `sandbox-grants` says only "the complete list from 'What the sandbox can reach'", the table's read-list row is `(OI)(CI)RX` plus `RA` on each ancestor from the profile root down, and its one test is "a `Get-SandboxGrantList` row test on a synthetic repo and worktree" — no read-list entry. `sandbox-readlist`'s tests cover refusals and `addToPath`, not rows. So the read-list grant path is asserted nowhere until `sandbox-canary`'s read-list container test, five tasks and one long-running run later, where a failure costs a slot reservation instead of a unit test.

Guidance: in `sandbox-grants`, state "it takes the entries `Test-SandboxReadList` returned (already normalized) and appends one `(OI)(CI)RX` row per entry plus one `RA` row per ancestor from the profile root down", and extend the row test to one read-list entry so the ancestor chain is asserted. That keeps the row's *shape* in the build-time task file, as the caller intends, while restoring the ownership that the split dissolved.

### 4. Severity: Major
**Affected scope:** `sandbox-grants` brief — "Remove-SandboxGrants with one unremovable entry" and the task-level rule "This task maps no drive letter and creates no AppContainer profile."

**Finding & guidance:** `Remove-SandboxGrants` runs `icacls <path> /remove "*<ledger.sid>"`, so the test needs a SID that is actually present on a path. On this machine the sanctioned source of such a SID is `EnsureProfile`, which is the one thing the brief forbids ("creates no AppContainer profile"); the alternatives are the test user's own SID (granting and then removing the user's own ACE on a test folder, recoverable but destructive to the folder's ACL) or a hand-written `S-1-15-2-…` string whose acceptance by `icacls` is unprobed. The brief defers this to "a tested way to make one grant unremovable" pinned in the task file, but the *tested* part is the unremovability trick, not the SID source, and the SID source is what collides with the task rule.

Guidance: pin both halves at build time, and relax the rule explicitly: either "this task may call `EnsureProfile`/`DeleteProfile` once for a throwaway `xagent.test-<guid>` profile to obtain a real container SID" (which is what `Sandbox.Tests.ps1` already does at file 5's profile round-trip test, so no new Windows surface), or "use the current user's SID with `/grant "*<sid>:(OI)(CI)M"` and restore it in a `finally`". Note also that `sandbox-lifecycle` already pins the unremovable mechanism as "an open handle on the file"; use the same sentence in both briefs so the two tasks do not solve it twice — an `[IO.File]::Open(..., FileShare]::None)` handle blocks `icacls` because its open fails with a sharing violation, which is cheap and non-admin.

### 5. Severity: Minor
**Affected scope:** `sandbox-readlist` brief, the protected-folder refusal rule.

**Finding & guidance:** The design's rule 2 refuses `%LOCALAPPDATA%\cursor-agent`, and file 5's test case is spelled `%LOCALAPPDATA%\cursor-agent\versions`. The module already has a configurable `$script:CursorRoot` (`XAGENT_CURSOR_ROOT`), which every test sets to a `TestDrive` path. A worker that builds the protected list from `$script:CursorRoot` produces a validator that refuses the configured root instead of the real one, and the pinned test case then fails for a reason unrelated to the rule; the other worker hard-codes `[Environment]::GetFolderPath('LocalApplicationData')` and passes. Both readings are defensible from the text.

Guidance: one clause — "the protected folders and the profile root are computed from the real environment (`$env:USERPROFILE`, `[Environment]::GetFolderPath(...)`), never from `XAGENT_CURSOR_ROOT` or `XAGENT_SANDBOX_ROOT`" (the sandbox's own folder, `<Root>`, stays the configurable one, since its test case is written against `TestDrive`).

### 6. Severity: Minor
**Affected scope:** `sandbox-grants` brief — ledger helpers; interaction with phase 2's merged code.

**Finding & guidance:** `Sandbox.psm1` already ships two ledger readers, `Test-LedgerProcessLive` (pid + start-time liveness) and `Get-LedgerRuntimeVersions` (collects `runtimeVersion` from `slot-?.json`), both of which parse `<Root>\sandbox\slot-<L>.json` directly. `Read-SandboxLedger` will be a third reader unless the brief says otherwise, and phase 2's reuse/pruning contract depends on the format `Get-LedgerRuntimeVersions` expects. Also, the brief lists no round-trip test for the new reader/writer pair, so nothing pins that they agree with phase 2's reader.

Guidance: add "`Read-SandboxLedger` is the single reader; `Test-LedgerProcessLive` and `Get-LedgerRuntimeVersions` keep reading through it (or are left untouched and must keep parsing the same file)" and one test — write a ledger, read it back, and assert `Get-LedgerRuntimeVersions` still sees its `runtimeVersion`. Two lines of test, and it prevents the "second version of a helper" failure the briefs warn about elsewhere.

### 7. Severity: Minor
**Affected scope:** `sandbox-grants` brief — the row test's repo location, and the missing TEST REPOS rule.

**Finding & guidance:** `sandbox-readlist` correctly carries no TEST REPOS paragraph (it creates no repo), but `sandbox-grants`'s row test *does* create a synthetic repo and worktree, and its brief says nothing about where. If the worker puts it in `TestDrive` (the natural choice for a unit test), a `Get-SandboxGrantList` that internally calls `Assert-SandboxOutsideProfile` — plausible, since that helper is the module's path guard — will refuse it, and the worker will "fix" the module or move the repo onto the repo's drive for no real reason. Nothing states that the profile refusal belongs to `New-SandboxRun` alone.

Guidance: one clause in `sandbox-grants`: "`Get-SandboxGrantList` does no profile refusal — `New-SandboxRun` calls `Assert-SandboxOutsideProfile` first — so its test may build the synthetic repo in `TestDrive`." That is also what makes the half testable on its own.

### 8. Severity: Nit
**Affected scope:** phase 3 task table — `sandbox-grants` and `sandbox-slots` rows.

**Finding & guidance:** Both rows are titled "Sandbox.psm1 part 2b". Since the plan's own numbering is the reader's tool for checking that nothing was lost or duplicated in the split, the duplicate label works against the caller's question. Renumber `sandbox-slots` to part 2c and shift the later two (`2d`, `2e`), or drop the letters and keep `task N of 5`.

### 9. Severity: Nit
**Affected scope:** `Files` columns of `sandbox-readlist` and `sandbox-grants`.

**Finding & guidance:** Both list `skills/delegate/tests/fixtures/`, but neither brief's tests need a fixture: the read-list cases are paths built in `TestDrive`, and the grant-row test builds its repo inline (the `LoopbackExempt` text fixture belongs to `sandbox-slots`). Listing the folder in the write allowlist invites a stray fixture file and adds nothing to either task's line budget.

Guidance: drop `fixtures/` from both rows; keep it on `sandbox-slots`, `sandbox-lifecycle` and `sandbox-canary`.

### 10. Severity: Nit
**Affected scope:** `sandbox-readlist` brief, `Decided` list.

**Finding & guidance:** `Decided` ends "the public function signatures as the design states them", but the task's three added functions are all private and it changes no public signature — `Test-SandboxSupport` only gains a check inside its existing `-CursorRoot`/`-CacheRoot`/`-UvProbe` surface. The clause is vacuous here and slightly misleading, since it is the thing a worker checks to conclude its interfaces are settled (finding 2 is the real content). Either delete it for this task or replace it with the seam signatures.

### 11. Severity: Nit
**Affected scope:** `sandbox-grants` brief, test sentence.

**Finding & guidance:** File 5 asserts three things about `Remove-SandboxGrants` — the failed entry is returned, *the others are removed*, and the ledger is rewritten with only that entry (the third is stated in `sandbox-lifecycle`). The brief compresses this to "Remove-SandboxGrants with one unremovable entry". Since the module's own contract is "a failed entry doesn't stop the others", the surviving-entries half is the interesting assertion and should be named in the test line.

---

## Edges judged sound

`readslist → grants → slots → lifecycle → canary` is a real chain, not just phase order: `Get-SandboxSlot` needs `Remove-SandboxGrants` and the ledger readers from `sandbox-grants`; `New-SandboxRun` needs all of `sandbox-readlist`'s three helpers plus `sandbox-grants`' row builder; `sandbox-canary` needs the slot, launch and stop trio. `sandbox-readlist`'s single edge to `sandbox-core` is correct — everything it extends (`Get-SandboxConfig`, `Get-SupportLetters`, `Get-PatternProblem`) is in the merged module. The narrowed test command `pwsh -NoProfile -File scripts/test.ps1 -Fast -Path skills/delegate/tests` is valid against the merged `scripts/test.ps1`, whose `param([switch]$Fast, [string[]]$Path)` resolves a relative path against the caller's working folder, and `-Fast` excludes only `Live` and `Slow`, which leaves the phase-2 unit `Describe`s and the new ones in scope.
