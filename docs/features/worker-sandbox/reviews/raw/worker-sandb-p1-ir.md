<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll read the task file first.

# Implementation Readiness Review — `docs/features/worker-sandbox/plan.md`

**Mode:** REVIEW. **Target:** the whole plan file. **Standard:** implementation-readiness (zero-decision rule, phasing, target scope, actionable steps, test plan). Repository read for context only.

Overall: the plan is unusually precise for phases 1, 2 and 4 — exact line anchors (`feature.ps1` 1806/2290/2556, `delegate.ps1` 349), exact error strings deferred to the locked design, correct file boundaries per task, and a dependency graph that `feature.ps1`'s overlap detector will accept (phase 4's two tasks touch disjoint files). The gaps below are not "the plan is vague"; they are places where the plan's own test expectations are unachievable or self-contradictory, or where an interface crosses a task boundary that a different model will implement.

---

## Blocker

None. Every finding below is executable by a competent worker; the failures are in verification and in cross-task contracts.

---

## Major

### 1. The zeroed-pattern fixture case cannot produce the error it asserts
**Affected scope:** Phase 4, `delegate-wiring`; case "A cache whose pattern bytes are zeroed gives exit code 1, an `error` starting with `sandbox: Cursor 2099.01.01-abc123: node.exe pipe-name pattern found 0 times`".

**Finding & guidance:** Under the design's reuse contract (`Get-SandboxRuntime`: reuse when `patch.json` exists **and** the cached `node.exe` SHA-256 equals `patchedSha256`), zeroing the *cached* `node.exe` makes the hash mismatch, so the function re-copies from the source and patches successfully. The run exits 0 and the test fails for the wrong reason. To reach the error, the **source** `node.exe` must lack the pattern (zero the pattern bytes in `TestDrive\cursor-agent\versions\2099.01.01-abc123\node.exe`) with any `patch.json`/cache folder removed first. The plan should say "the fixture's source `node.exe`" and "clear `patch.json` and the cache", not "a cache whose pattern bytes are zeroed". Two workers reading this line will produce one test that never fails and one that fails correctly.

### 2. Phases 1 and 4 gate their work on a command that excludes the tests proving it
**Affected scope:** `kill-tree` and `doctor-check` test columns; phase 4 test line.

**Finding & guidance:** `scripts/test.ps1 -Fast` excludes `-Tag 'Slow'`. In this repo the relevant tests are all Slow: `It 'reports prerequisites' -Tag 'Slow'` (feature.Tests.ps1:2469 — the only place the tenth check and the names list are asserted), `It 'times out and kills process tree'` (1485), `It 'kills orphaned child or leaves reused pid alone'` (2281 — the reconcile `taskkill` site). The plan also does not pin a tag for the new `Stop-ProcessTree` test, so a worker will tag it Slow by analogy and its acceptance command will never run it. Fix: pin the new kill test as untagged, and give `doctor-check` (and ideally `kill-tree`) a test command that runs the Slow suite — `pwsh -NoProfile -File scripts/test.ps1`, or a `Filter.FullName` subset per `skills/delegate/SKILL.md`'s advice for slow suites.

### 3. The fake-Cursor fixture cannot be built inside the sandbox, so the phase-5 in-sandbox suite check must fail
**Affected scope:** `delegate-wiring` fixture; Verification Plan "The suite inside the sandbox (CUJ 2)".

**Finding & guidance:** The fixture copies "the real `node.exe`" from the Cursor install into `TestDrive\cursor-agent\versions\2099.01.01-abc123\`. Inside a container, `%LOCALAPPDATA%\cursor-agent` is unreadable — and the design's read list explicitly **refuses** entries under `%LOCALAPPDATA%\cursor-agent`, so it can never be granted. The `-NoSandbox` summary case is untagged, so it runs in the sandboxed suite and its `BeforeAll` copy throws, breaking the file. The plan nevertheless requires "the suite passes inside the sandbox, apart from tests tagged `Sandbox`". Fix one of: derive the fake Cursor root from the sandbox's own runtime cache (`<Root>\sandbox\cursor\<version>`, which the container can read and which already carries a patched `node.exe`), tag every describe that copies the real install `Sandbox`, or add "skip with a recorded reason when the Cursor install is unreadable".

### 4. `Test-SandboxSupport`'s return contract is not pinned, and a different worker consumes it
**Affected scope:** `sandbox-core` (producer) → `doctor-check` (consumer). Design file 2 and file 4.

**Finding & guidance:** The design fixes `{ok, build, cursorVersion, uv, patternCount, letters, problems[]}` but never the shape of `letters`. The doctor task must print "Cursor version, uv, pattern count, letters and problems"; a worker implementing phase 2 may return the reserved config (`{runtime, slots}`), or a per-letter state array (`[{letter, state}]`), or nothing when unreserved. The two tasks are separate workers on different profiles, and the tenth-check test only asserts that `name/ok/required/detail` exist — nothing catches the mismatch, and a property access on the wrong shape throws inside `doctor`, degrading the whole command. Also unpinned: whether "no letters reserved" is a support `problem` (which would show `sandbox: ok = false` before CUJ 1) or a normal pre-reservation state. Pin both in the plan (a literal example object plus one sentence on the unreserved case).

### 5. Phase 4's two tasks collide if run concurrently through the container tests
**Affected scope:** `delegate-wiring` + `doctor-check`; phase 3's container tests, which both phase-4 commands will execute.

**Finding & guidance:** The two tasks have disjoint `files` and no dependency between them, so `feature.ps1 schedule` may issue them in one round. Both run `scripts/test.ps1 -Fast`, which does **not** exclude the `Sandbox` tag, so both worktrees' test runs will reserve the three highest free letters, `subst` them, and call `EnsureProfile` for the fixed names `xagent.slot-<L>`. Profiles are per-user and permanent; the second run either fails to reserve (letters now `ours` from the first run's `sandbox.json`? — different `XAGENT_SANDBOX_ROOT`, so it sees them as `used`) or shares a container and interferes with grants. The plan does not mention serialization. Fix: add an explicit plan constraint that phase 4's tasks run one at a time (or sequence them with a dependency), rather than relying on file-disjointness.

### 6. `Get-SandboxRuntime`'s re-copy path has no instruction for an existing folder
**Affected scope:** `sandbox-core`; design file 2, "Copy: otherwise copy the version folder to `<version>.partial)`" / "Finish: rename `.partial` to `<version>`".

**Finding & guidance:** The reuse contract deliberately falls through to the copy path when `patch.json` is missing or the hash differs — i.e. exactly when `<version>` already exists. `Rename-Item` onto an existing directory fails, and a crashed run leaves `<version>.partial` behind. Nothing in the plan or design says to delete either first. Two workers will produce "delete `<version>` first", "fail with an error", and "copy over in place", with different observable behaviour on the second run of a version. Pin: "remove `<version>` and any `<version>.partial` before copying; a stale `.partial` is always discarded."

### 7. The two phase-3 probe checks have no gating or host rules
**Affected scope:** `sandbox-run` brief, last sentence ("Also run and record … two probe checks").

**Finding & guidance:** The probe set is: `Cursor --version` plus a short `-p` run with `--workspace <real worktree path>` and working folder `<slot>:\`, and a per-user Python started from a read-list entry. Unstated: (a) which sandbox root — a `TestDrive`-style temp root (in which case the worker must itself copy `cli-config.json` and `auth.json` into the run home, i.e. handle the user's real credentials in a scratch folder) or the real `%LOCALAPPDATA%\xagent` (which requires the three letters the user has not approved yet, per CUJ 1); (b) whether a failed probe blocks the task or is a recorded observation; (c) the field/format to record. As written, one worker spends a real model call against the real root and blocks on letter approval; another runs it against a temp root and reports a different result. Pin the root, the pass/fail (or observe-only) semantics, and that the `-p` probe must use a deliberately trivial prompt with its own timeout.

---

## Nit

### 8. `Add-Type` on a repeated import is unguarded
`Sandbox.psm1` is imported repeatedly in one process: Pester describes, `doctor` in-process, `delegate.ps1`. `Add-Type -Path SandboxNative.cs` throws when the type already exists, and `doctor`'s rule turns any import failure into `ok = $false` with the error — a spurious degraded check, and flaky tests. Say the guard explicitly (`if (-not ('XagentSandbox' -as [type])) { Add-Type -Path ... }`) and that `Import-Module` must be idempotent.

### 9. The version-choice test's oracle is circular
"The pick equals what the launcher's own `Parse-VersionString` sort picks" does not say where the test gets the launcher function. If it uses the copy inside `Sandbox.psm1`, the test asserts the implementation against itself. Name the source: the `cursor-agent.ps1` under `XAGENT_CURSOR_ROOT` (or a fixture copy of just that function).

### 10. Build-order deviation from the design, unexplained
The plan's summary says "Five phases follow the design's Build order", but `sandbox-core` depends on `kill-tree` while the design's Build order has phase 2 depending on nothing and states "Phases 1 and 2 share no files and can run at the same time". Harmless for correctness, but the design is declared the source of truth. Either restore `—` on `sandbox-core` or state that the serialization is deliberate.

### 11. `Remove-SandboxLetters` with nothing reserved is unspecified
`-SandboxCheck -Release` against an empty `sandbox.json` (or a missing `<Root>\sandbox`) has no defined outcome in plan or design: no-op returning `[]` with `ok: true`, or a `sandbox:` throw. Pin one, since `-Release` is a user-facing command the docs task describes.

### 12. `scripts/test.ps1` with no test folders
"Run.Path set to whichever of the two folders exist" degenerates to an empty path if neither exists (Pester errors on an empty `Run.Path`). One line — "if neither exists, print nothing and exit 0" — removes the branch.

---

## What the plan gets right (so the next reader doesn't re-litigate it)

- **Files:** every task's allowlist matches the design's file list; the two lead-only documents (`docs/test-plan.md`, `docs/HANDOFF.md`) are correctly excluded from `sandbox-docs` and named as the lead's, and the frozen-worktree/G6 steps are outside the tasks, as the plan rules require.
- **Anchors:** all four line references checked in this worktree are accurate (`feature.ps1` 1806, 2290, 2556; `delegate.ps1` 349), as is the doctor test at 2469 and its `Should -Be 9` / names array at 2473–2475.
- **Dependencies:** acyclic, phase-monotonic, and consistent with `plan.schema.json` and `feature.ps1`'s validation; phase 4's two tasks are genuinely file-disjoint (only finding 5 argues against running them in parallel).
- **Phase 3's openness is intentional** (G7) and correctly bounded: interfaces, ledger format, error strings and listed tests are Decided; helpers, `icacls` construction, mutex/ledger structure and work order are the worker's. That is the one place the zero-decision rule is waived on purpose, and the plan says so.
