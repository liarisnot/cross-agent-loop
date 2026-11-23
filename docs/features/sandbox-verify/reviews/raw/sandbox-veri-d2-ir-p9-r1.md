<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll read the task file first.

Sec 

 

## Review Report — `docs/designs/sandbox-verify.md` (all 246 lines)

Persona: Implementation Readiness Goldfish (REVIEW mode). Standard: Implementation Readiness Standard (zero-decision rule, phasing, file boundary, test plan). Read as a fresh implementer who must write these changes without asking anyone anything.

Overall: this is an unusually complete design. Line numbers, exact error strings, JSON shapes, refusal ordering, schema deltas and a per-test disposition list are all present. I found no Blocker — nothing here stops an implementer from starting. The findings below are places where I would still have to open a second document or make a call the design claims to have made for me.

---

### 1. Missing a distinct status for the slot timeout

**Severity:** Major

**Affected scope:** `skills/feature/stages/build.md` row (line 224); Risks table row "`verify` gets `sandbox-error` because both slots were busy for 60 s" (line 144); Data → `verify` output (lines 172-179).

**Finding & Guidance:** The design deliberately makes `sandbox-error` cover everything from `ok: false`, including `no free slot`. It then asks `build.md` to single out that one case: "sandbox-error -> problem stop, except `no free slot`, which waits …". The only way to tell them apart is a substring match against `setup.message`, which is free-form text produced by whatever `delegate.ps1` threw. That is exactly the guessing the design's own D6 forbids for test failures, and it makes `build.md` prose brittle in a second place. Pre-determine the value instead: add a third `setup.status`, e.g. `slot-timeout` (set when `delegate.ps1`'s `error` is the `Get-SandboxSlot` timeout), extend the schema enum on line 180, and have `build.md` branch on `setup.status`, not on message text. If you keep it as `sandbox-error`, say explicitly that `build.md` matches the literal substring `no free slot` and that this substring is a stable contract of `Sandbox.psm1`.

---

### 2. The sandboxed run adds a second PowerShell layer that re-encodes the test's output

**Severity:** Major

**Affected scope:** "The sandboxed run" (lines 186-195); `tail` in Data → Output (line 161); Rules → Mapping (line 199).

**Finding & Guidance:** The chain is `delegate.ps1` → sandbox `pwsh -NoProfile -Command "<cmd>"` (`Invoke-SandboxCommand`, `Sandbox.psm1` line 2308) → the inner `pwsh -EncodedCommand <base64>` whose wrapper sets `[Console]::OutputEncoding = UTF8` (`feature.ps1` lines 2615-2626). The wrapper's UTF-8 setting governs the *inner* process only. The outer sandbox `pwsh` receives the inner process's output as a native command and re-emits it through its own `[Console]::OutputEncoding`, which is the console code page — this repo already documents that as code page 437 (`delegate.ps1` line 145). So non-ASCII test output is decoded and re-encoded once more before it reaches `stdout.txt`, and `tail` (and any `denied`/assertion text the lead reads) can come back mojibake. The host path does not have this extra hop: `Start-Process -RedirectStandardOutput` hands the file handle straight to the child. The design asserts "a test behaves the same under `where: sandbox` and `where: host`" but this is a behavioural difference it does not address. Specify the fix in the plan: set `[Console]::OutputEncoding`/`$OutputEncoding` to UTF-8 in the outer `-Command` text too (i.e. make the `-Command` value `[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); pwsh … ; exit $LASTEXITCODE`), or invoke the inner shell in a way that does not round-trip through the outer PowerShell pipeline. Also add a test case: a test command that prints a non-ASCII string, asserting `tail` contains it exactly. This repo already treats non-ASCII fidelity as a requirement (`feature.Tests.ps1` line 577).

---

### 3. The readiness gate at the worktree's `HEAD` cannot see the worker's uncommitted environment inputs

**Severity:** Major

**Affected scope:** Components (line 65), Terms → readiness gate (line 47), "`-SandboxRun -Worktree` checks" (line 205); the `environment-missing` recovery path in the `build.md` row (line 224) and in the flow diagram (lines 86-87).

**Finding & Guidance:** `Test-SandboxEnvReady` → `Get-SandboxEnvProjects` enumerates projects from the **commit tree** (`SandboxEnv.psm1` lines 284-307). The design fixes the gate at the worktree's `HEAD`, while the whole point of D3 is that the worker's changes are *uncommitted*. Two cases follow, and neither is covered:

- The worker adds a Python project or a new `uv.lock` in its diff. The gate at `HEAD` sees no such project, so it is "ready" with zero links; the test then fails with an import error and `verify` reports an ordinary `passed: false`, `setup: null`. The lead reads a code-shaped failure and opens a review round.
- The worker edits `uv.lock`/`pyproject.toml`. The gate passes against the stale lock, links the stale environment, and the test fails on a missing dependency. If instead the gate did report `environment-missing`, the documented recovery — run `-SandboxEnv -Apply`, then `verify` again — rebuilds at `HEAD` and reproduces the same state, so the recovery loop never converges.

Decide and record it. Either (a) the gate evaluates the worktree's working tree (a stated delta from `sandbox-env`, with the cache-key implications spelled out), or (b) it stays at `HEAD` and the design says plainly that a task touching environment inputs must be committed/the environment rebuilt first, with the exact `build.md` instruction the lead follows and the `setup`/`tail` signal that tells them this is what happened. "As a worker launch does" is not sufficient guidance, because for `verify` the failure is indistinguishable from a bug.

---

### 4. `verify-setup.json` would never be validated — the schema test does not enumerate the folder

**Severity:** Major

**Affected scope:** Files row for `skills/feature/tests/fixtures/samples/verify.json` (line 221).

**Finding & Guidance:** The row says "The schema test checks every sample in the folder, so the new required fields are covered." It does not. `feature.Tests.ps1` lines 30-38 hold a literal `$validSamples` array of seven file names; the `-ForEach` on line 40 iterates that array, not the directory. An implementer who follows the design will create `verify-setup.json`, see the suite stay green, and ship an unvalidated sample. Change the row to require adding `'verify-setup.json'` to `$validSamples` (and say the file-name prefix rule maps it to the `verify` schema via `Get-SampleSchemaName`, `TestHelpers.ps1` line 108), or state that the test is changed to enumerate `Get-ChildItem fixtures/samples -Filter *.json` and classify by prefix — either way, pick one and put it in the plan.

---

### 5. The test row claims completeness but two existing tests are unaccounted for

**Severity:** Major

**Affected scope:** Files row for `skills/feature/tests/feature.Tests.ps1` (line 223), which says "says what happens to every existing test".

**Finding & Guidance:** The row disposes of ten existing `It` blocks. `Describe 'feature.ps1 verify'` (lines 1635-1924) has twelve. Missing:

- `computes changed before test writes out.txt` (line 1900). This is the only test that pins the scope-check-before-test ordering in `Invoke-VerifyFeature` (lines 2764-2776) and it asserts `Test-Path (Join-Path $wt 'out.txt')`. Under the default path that file is now written by the *fake*, not by a local `pwsh` started in the worktree, so whether the assertion still holds depends on the fake's `ran` mode really executing `-Command` in `-Worktree` — a property stated only in the `fake-delegate.ps1` row.
- `fails invalid TimeoutSec, unknown task, missing Task` (line 1915). It exercises `-TimeoutSec` values `0`, `-1`, `abc`, which the design now also gates at 30-3600 for sandboxed runs. The expected message is the same string, but the design should confirm the 30-3600 range check reuses `invalid -TimeoutSec` rather than introducing a new refusal the test would not match.

Add both to the row with their expected treatment.

---

### 6. `Get-LaunchSkipReason -Kind Sandbox` cannot be "copied" as a single function, and the helpers it needs are outside the write allowlist

**Severity:** Major

**Affected scope:** Verification items 2-3 (line 245); Files rows (lines 219-223) — `verify-sandbox`'s file boundary.

**Finding & Guidance:** The design says the Live test "skips with a reason when `Get-LaunchSkipReason -Kind Sandbox` (copied from `DelegateLaunch.Tests.ps1`) returns one". That function (`DelegateLaunch.Tests.ps1` lines 386-407) is not self-contained: it uses `Add-Type` on `$script:Here/../scripts/SandboxNative.cs`, `$script:Here` itself, `Get-TestFreeLetters`, `Get-TestGitTopLevel`, `Test-TestPathUnderUserProfile`, `Test-TestDriveRootWritable`, `Get-TestRealCursorVersionDir` and `$script:RealCursorVersionDir`. Copying it into `feature.Tests.ps1` therefore means duplicating or re-implementing six helpers, and the file that would naturally host them — `skills/feature/tests/TestHelpers.ps1` — is **not** in the Files table under any task, so the write allowlist forbids `verify-sandbox` from touching it. Decide one of: (a) list the exact functions to copy into `feature.Tests.ps1` (as new `Describe`-scope helpers) in that row; (b) add `skills/feature/tests/TestHelpers.ps1` to the row and to `verify-sandbox`'s owning files on line 236; (c) have the Live test skip on a narrower, self-contained predicate and state what it is. Also note `-Kind Sandbox` falls through to the Cursor-version check in the same function, so the copied code returns a reason when the Cursor install is unreadable — if `verify` does not need Cursor, say whether that check is kept.

---

### 7. Nothing verifies that `verify` passes `-Feature` (the whole of D5) to `delegate.ps1`

**Severity:** Major

**Affected scope:** D5 (line 60); Files rows for `fake-delegate.ps1` (line 222) and `feature.Tests.ps1` (line 223).

**Finding & Guidance:** D5's only protection is that the sandboxed `verify` passes `-Feature <name>` so a pid file exists and `Get-LiveDelegateRunCount` counts it (lines 162-163, 48). The delegate-level test proves the pid file for `-SandboxRun -Feature` called directly; nothing proves `verify` passes the flag, passes the right worktree, or passes the resolved feature name (as opposed to `-Name`, which can be absent). The fake already records its argument list and the new tests already inspect it — add assertions on `-Feature`, `-Repo`, `-Worktree` and `-TimeoutSec` to the "fake's recorded arguments" case so the wiring in `feature.ps1` (which the fake is standing in for) is pinned. Without this, a `verify` that forgets `-Feature` passes the whole suite while silently defeating D5.

---

### Nit 1. "Three places that call `Add-SandboxEnvLinks`" contradicts "one helper"

**Severity:** Nit

**Affected scope:** Rules → `.venv` links and git (line 196) vs. Rules → One helper (line 207).

**Finding & Guidance:** The one-helper rule merges the probe form and the `-Worktree` form into a single call site, leaving two: the helper and the worker launch (`delegate.ps1` line 542). Say "both call sites" or place `Add-DelegateVenvExclude` inside the helper and say so, so the implementer does not hunt for a third caller.

---

### Nit 2. Appending to `.git/info/exclude` "the same way it keeps `.xagent/` there" reproduces a latent newline bug

**Severity:** Nit

**Affected scope:** Rules → `.venv` links and git (line 196); `delegate.ps1` line 270.

**Finding & Guidance:** The existing code is `Add-Content -LiteralPath $exclude -Value '.xagent/'`, which appends the value plus a terminator but no *leading* newline; `feature.ps1`'s `Ensure-XagentExclude` (line 82) has the same shape. If `info/exclude` does not end with a newline, the new entry is glued onto the previous line and silently ineffective — which for `.venv/` reopens the G4 scope-check/merge failure. Specify that `Add-DelegateVenvExclude` reads the file, and when the existing text is non-empty and does not end with `` `n ``, prefixes one newline before appending. Cheap, and it removes the only way this feature's G4 can fail on a fresh clone.

---

### Nit 3. The `-Worktree` form's run name and pid-file `<hex>` are only inferable

**Severity:** Nit

**Affected scope:** Data → Pid file (line 162); Rules → One helper (line 207).

**Finding & Guidance:** The pid file is `<repo>\.xagent\runs\probe-<hex>.pid` and "both names use the same `<hex>`", but nothing states that the `-Worktree` form also names its run folder `probe-<hex>` and generates `<hex>` the way the probe form does (`[guid]::NewGuid().ToString('N').Substring(0,8)`). One sentence in the helper paragraph removes the guess; the delegate test that globs `probe-*.pid` already assumes it.

---

### Nit 4. "Read asynchronously into strings (as `Invoke-TaskTestCommand` reads its files)" is self-contradictory

**Severity:** Nit

**Affected scope:** Rules → The sandboxed run (line 195).

**Finding & Guidance:** `Invoke-TaskTestCommand` does not read pipes; it redirects to temp files and reads the files afterwards (lines 2624-2650). If the sandboxed path must be pipe-based, say which mechanism (e.g. `RedirectStandardOutput = $true` with `BeginOutputReadLine` into a `StringBuilder`, and `WaitForExit()` without a timeout after the handle completes before checking elapsed time), because `WaitForExit(ms)` returning true does not guarantee the async handlers have drained.

---

### Nit 5. Phase 1's expected outcome contradicts the phasing

**Severity:** Nit

**Affected scope:** Phases table (line 233), closing paragraph (line 238).

**Finding & Guidance:** Phase 1's row says its phase test "is the delegate tests, so under D1 it asks for a host run (expected)". At that point `build.md` and the new phase rule only land in phase 2 (`build-docs`), so phase 1's phase test runs under today's rule — and this repo has no root Python project (the only `uv.lock` is under `skills/delegate/tests/fixtures/sandbox-env`, excluded by `Test-SandboxTestDataPath`, `SandboxEnv.psm1` line 270), so it runs in `<repo>` on the host with no prompt at all. Reword to "runs on the host under the current rule; the new rule first applies to phase 2's test", otherwise the lead will wait for an approval prompt that never comes and will not know whether D1 was exercised.

---

### Nit 6. Verification list numbering

**Severity:** Nit

**Affected scope:** Verification items (lines 244-246).

**Finding & Guidance:** The list reads `1.`, then `2. and 3. are one … test`, then `4.`. A fresh reader looking for item 3 finds only a cross-reference. Renumber to 1-3 so the sign-off checklist can be ticked item by item.

---

### What I checked and found sufficient

For the record, these were the areas I probed hardest and they hold up: the `-Worktree` path-normalization and worktree-ownership rules (line 200-206) against `delegate.ps1`'s existing safety check; the pid-file contract `{pid, startTime, feature}` against `Get-LiveDelegateRunCount` (`feature.ps1` lines 1759-1781); the `-Base`/`-Worktree` exclusion using `$PSBoundParameters.ContainsKey('Base')` against `-Base`'s default; the `-Quote` reuse without disturbing `Invoke-GateFeature`; the `Add-FeatureDecision` extraction from `Invoke-DecisionFeature` (noting it must not inherit `Out-FeatureOk`'s `exit 0`); the refusal ordering that keeps `{ok: false}` for pre-scope-check failures and `setup` for post-scope-check ones; `tail` versus `output` mirroring `Get-SandboxCommandOutputLines`; and the `.venv` exclusion actually removing the junctions from `git ls-files --others --exclude-standard`, `Get-ChangedPaths` and `Test-MergeBlockingPorcelainLine`. The file boundary in the Files table is exact-path complete apart from the `TestHelpers.ps1` question in finding 6.
