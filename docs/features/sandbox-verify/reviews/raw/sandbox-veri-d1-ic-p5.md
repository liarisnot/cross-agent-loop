<!-- persona: inventive_catalyst | agent: cursor | model: glm-5.2-high -->
# Inventive Catalyst Goldfish — REVIEW of `docs/designs/sandbox-verify.md`

**Mode:** REVIEW (Step 5 strategic audit)
**Standard:** Feature Specification (mandatory alternatives evaluation; risks & limits)

## Verdict

A genuine technical contradiction exists and is the document's reason for being: worker-written test code must execute before merge, yet must not run with the user's full rights. The document addresses it directly and, on the whole, soundly. The alternatives section is the strongest part — five rejected paths, each with a concrete technical reason (D3, D6, D1, D2, plus the fresh-worktree alternative). Per the standard's Alternatives Rule, that bar is met.

However, several **false compromises** survive in the framing of operational trade-offs. Findings below.

---

## Finding 1 — Major

**Affected Scope:** Decisions D5; Risks table row "verify waits for a slot while two workers run"; `skills/feature/scripts/feature.ps1` `Get-LiveDelegateRunCount` (lines 1759–1780).

**False Compromise:** The document presents the slot-cap interaction as a single, solved case — "verify waits for a slot while two workers run" — and resolves it by making verify count toward the cap of 2 (D5). The reasoning is internally correct, but the framing hides the dominant operational consequence: in the **steady-state build loop**, verify runs after *each* worker, so while one worker is still running, verify occupies the second slot and `schedule` returns no tasks (`liveRuns = 2`). The next worker cannot start until verify completes. With the measured ~604 s sandboxed test time, this serializes worker launches against verify and roughly halves steady-state worker throughput whenever a build keeps two slots busy. The 14% per-test slowdown (Risks row "Slower checks") is a different, smaller cost; the slot-occupancy serialization is the larger one and is not named anywhere.

**Proposed Resolution:** **Segmentation** — give verify/phase-tests a resource pool distinct from worker slots, instead of sharing the cap of 2. Two concrete options:
- Reserve a third sandbox slot dedicated to lead-side test runs (`-SandboxRun -Feature <name> -Kind verify`), excluded from `Get-LiveDelegateRunCount`'s worker cap but counted against its own cap of 1. `Set-SandboxLetters` would reserve four letters (1 runtime + 3 slots); `Get-LiveDelegateRunCount` filters by a `kind` field in the pid file.
- Or **reuse the worker's just-released slot** for its own verify (D3 already runs in the worker's existing worktree): have `delegate.ps1` thread the worker's slot letter through to the verify call so verify re-binds that same slot without re-entering the general pool, eliminating contention with the next worker entirely.

**Secondary Liabilities:**
- Third-slot option: a fourth reserved drive letter (more user setup, more letters blocked against USB drives); a second cap counter and a `kind` discriminator in the pid-file schema (schema change rippling to `verify.schema.json` and `Get-LiveDelegateRunCount`); crash-recovery semantics now span three slots.
- Slot-reuse option: couples verify's lifetime to the worker's slot-release timing; a worker that crashed mid-run leaves a stale ledger that verify must reclaim before binding (existing `Get-SandboxSlot` abandoned-mutex path covers this, but the contract is now cross-feature); re-entrant calls to `Stop-SandboxRun` on a slot whose ledger names a different `feature` need an explicit rule to avoid mis-attributing grants.

---

## Finding 2 — Major

**Affected Scope:** Decisions D2, D6; Goals G3; Risks row "A repo whose tests always need the host asks the user at every task"; Alternatives "Remember a host approval" / "Detect sandbox failures automatically."

**False Compromise:** The document sets up a clean contradiction — *security: never auto-fallback to host* versus *usability: don't prompt every task* — and resolves it by surrendering usability entirely (D2: approval never remembered). The rejected alternatives are the two extremes: "remember approval for the feature or repo" (rejected because "later tasks run worker code on the host without anyone looking") and "auto-detect and retry" (rejected because worker code runs on the host without approval). Both rejections are correct *for those specific designs*, but the document does not consider the **scoped** middle ground that the IFR points at: the test *command* comes from `feature.json` (the plan, reviewed at plan approval), while only the test *files* and *helper scripts* come from the worker. An approval could be scoped to "the plan's declared test command may run on the host for this repo," with worker-added helpers still sandbox-bound by virtue of the test command itself being the only thing elevated. The document conflates "approve running on the host" with "approve running worker code on the host," and rejects the former by arguing against the latter.

**Proposed Resolution:** **Beforehand Cushioning** — on the first host-fallback for a repo, the user approves a narrow, reviewable *host-run policy* keyed to the plan's exact test command string (and a re-approval when `feature.json`'s `test` changes), recorded in `decisions.md` as a `[decision]` line. The policy names the command, not the worker's code. Worker-written helper scripts invoked transitively by that command remain subject to the sandbox's read grants on the host run (the host run still uses the sandbox's grant list for the worktree, just without the AppContainer boundary), so the worker's code does not gain the user's full rights — only the test command's declared surface does.

**Secondary Liabilities:**
- A policy keyed to the command string breaks when the plan legitimately changes the test command (re-approval needed; risk of silent refusal if the check is by exact string and the plan author forgets).
- "Host run with the sandbox's grant list but no AppContainer" is a new execution mode in `Invoke-SandboxCommand`/`New-SandboxRun` — a third code path alongside sandboxed and `-NoSandbox`, with its own failure modes (a granted path on the host is still readable by any process the test spawns, so the boundary is weaker than AppContainer).
- The transitive-helper problem is real: a test command `pwsh -File scripts/test.ps1` can `&` anything, so "worker-added helpers stay sandbox-bound" is only enforceable if the host-run policy also constrains the working set — which approximates the AppContainer the design just left. This may collapse back to D2; if so, the document should say why the scoped path was considered and rejected, to satisfy the Alternatives Rule for this exact shape.

---

## Finding 3 — Major

**Affected Scope:** "Components: `delegate.ps1 -SandboxRun -Worktree`"; Rules "`-SandboxRun -Worktree` checks"; the existing `Get-SandboxWorktreeName` in `skills/delegate/scripts/Sandbox.psm1` (lines 2183–2199).

**False Compromise:** The new `-Worktree` path adds three sequential pre-flight checks (exists; is a worktree of `-Repo`; is not `-Repo` itself) and then runs the readiness gate at the worktree's `HEAD`, links environments, and calls `Invoke-SandboxCommand`. This is a **second, parallel orchestration path** for `-SandboxRun` — the existing one (delegate.ps1:303–360) creates a `.probe-<hex>` worktree, links, runs, and unlinks in a `finally`. The document specifies the new path's checks but does not say whether the existing `Invoke-SandboxCommand` (Sandbox.psm1:2258) is reused as-is or whether the orchestration in delegate.ps1 grows a second branch. The two paths share the readiness gate, linking, and `Invoke-SandboxCommand`, but differ in worktree lifecycle (probe created+removed vs. existing worktree left in place) and now in pre-flight checks. The document treats this as additive, but the coupling is invisible: a future change to the probe path's linking or cleanup must be mirrored in the worktree path, and nothing in the design names that invariant. This is tight architectural coupling presented as a parameter addition.

**Proposed Resolution:** **Intermediary / Extraction** — extract the shared orchestration (readiness gate → link → `Invoke-SandboxCommand` → unlink) into a single internal helper in `delegate.ps1` (or `Sandbox.psm1`) that both the probe path and the worktree path call, differing only in a worktree-acquisition strategy (create-and-remove vs. validate-and-keep). The pre-flight checks for `-Worktree` become the strategy's `Enter` step; the probe worktree creation becomes the other strategy's `Enter`. The `finally` is shared and dispatches on strategy.

**Secondary Liabilities:**
- A shared helper with a strategy parameter reintroduces the branch the extraction was meant to remove, just at a different level; the strategy interface must be stable or both paths churn together anyway.
- The probe path's `git worktree remove --force` in `finally` is now conditional on strategy, so a strategy that forgets to skip removal (e.g., a future third caller) would delete a worker's worktree — a high-blast-radius bug class that needs an explicit guard (e.g., the helper refuses to remove any path that resolves under `<repo>.xagent\<TaskId>` without a `Probe` marker).
- Extracting into `Sandbox.psm1` would make `Sandbox.psm1` import `SandboxEnv.psm1`'s linking helpers transitively in a new way; the existing rule "Sandbox.psm1 never imports SandboxEnv.psm1" (sandbox-env.md Rules, "Modules") would need renegotiation, or the helper stays in delegate.ps1 and the module boundary holds.

---

## Finding 4 — Major

**Affected Scope:** "Components: `feature.ps1 verify`"; Rules "The sandboxed run"; the wrapper file `<worktree>\.xagent\verify-<hex>.ps1`; Goal G4.

**False Compromise:** G4 states "the sandboxed run writes only what the test itself writes, and the scope check sees the worker's files and nothing the harness added." The implementation writes a wrapper script into the worker's worktree (`.xagent\verify-<hex>.ps1`) and deletes it in a `finally`. The document relies on two facts to satisfy G4: `.xagent/` is git-excluded, and the `finally` deletes the file. But a `finally` does not run under hard termination (machine restart, `Stop-Process -Force` on the verify process, or a power loss), so a leftover wrapper is a real, unmentioned outcome. The scope check is unaffected (`.xagent/` excluded), so G4's *letter* holds; but G4's *spirit* — "the harness writes nothing into the worker's worktree" — is violated in the hard-kill case, and the document does not acknowledge this. The deeper contradiction: the test command must run *in* the worktree (relative paths, the sandbox's working folder is the slot root = the worktree), but the harness must not write *into* the worktree. The design resolves it by writing into the excluded `.xagent/` subfolder, which is a partial surrender rather than an inventive resolution.

**Proposed Resolution:** **Extraction / Taking Out** — write the wrapper *outside* the worker's worktree, in `<repo>.xagent\verify-<hex>.ps1` (the existing `.xagent` sibling folder where delegate already keeps worktrees and `.envs`), and reference it by an absolute path granted to the run. The sandbox's working folder stays the slot root; the command becomes `& '<repo>.xagent\verify-<hex>.ps1'` with that path added to the run's read-grant list. The worker's worktree is then never written to by the harness, satisfying G4 literally and in spirit, and a hard-kill leaves no artifact in the worker's tree.

**Secondary Liabilities:**
- A new read grant on `<repo>.xagent\verify-<hex>.ps1` (and its ancestor `RA` rows) per run — another grant/remove pair through the ACL lock, adding the ~seconds of overhead the sandbox already pays for `.git` grants; measurable but small next to the 604 s test.
- The wrapper, living outside the worktree, can no longer use a relative `.\.xagent\...` path and must receive the worktree path as an argument or env var, so the wrapper template changes and its tests must cover argument quoting (the existing `Invoke-SandboxCommand` argument-quoting tests in `Sandbox.Tests.ps1` are the model).
- `<repo>.xagent\` is shared across all worktrees of the repo; a leftover wrapper there is now visible to *other* workers (they have `RA` on the ancestor but not `RX` on the file unless granted), so cleanup-on-next-verify or a startup sweep is needed to avoid litter accumulating.

---

## Finding 5 — Nit

**Affected Scope:** "Components: `delegate.ps1 -SandboxRun -Worktree`"; the pid file at `<repo>\.xagent\runs\probe-<hex>\run.pid`; `Get-LiveDelegateRunCount` (feature.ps1:1759–1780).

**False Compromise:** The document says the pid file is "written before the slot is taken and deleted in a `finally`," and that `Get-LiveDelegateRunCount` "already counts any `*.pid` under `.xagent\runs` with those three fields, so `schedule` needs no change." The scanner is indeed generic and liveness-checked (it verifies `pid` is alive and `startTime` matches), so a stale pid file from a hard-killed verify does not inflate the count — this part is robust. The unexamined trade-off is the *opposite* failure: the pid file is written *before* the slot is taken, so a verify that fails to acquire a slot within 60 s (the existing `Get-SandboxSlot` timeout) and throws `sandbox: no free slot` will have already written the pid file with a live `pid` (the verify process itself is still alive at that moment) and a `feature` matching the current feature. `schedule` would then count this failed verify as a live run until the process exits, briefly double-counting. The window is short (the process exits on the throw), but the ordering ("pid file before slot") is the wrong order for a counting signal that gates scheduling.

**Proposed Resolution:** **Preliminary Action inversion** — write the pid file *after* the slot is acquired, not before, so a slot-acquisition failure cannot produce a pid file that `schedule` counts. The "before slot" ordering is only needed if the pid file's purpose is to claim the slot against concurrent verifiers, but the slot mutex already does that; the pid file is purely a counting signal for `schedule`.

**Secondary Liabilities:**
- A verify that is killed between slot acquisition and pid-file write is now invisible to `schedule` (it holds a slot but `schedule` sees `liveRuns` unchanged), so a second worker could be launched and time out on the slot. The window is small (slot acquisition to one file write) but nonzero; the existing worker-launch path writes its pid file after `Start-SandboxProcess` (delegate.ps1:707–711), so it has the same window — this would make verify consistent with workers, not worse.
- The `finally` deletion must be unconditional on the pid file's existence, so a write-after-slot path still cleans up on every exit.

---

## Finding 6 — Nit

**Affected Scope:** Rules "Login files" (`New-SandboxRun -NoLogin`); Risks row "The test can read Cursor's login copy."

**False Compromise:** The document bundles a quiet behavior change: `Invoke-SandboxCommand` will *always* pass `-NoLogin`, so every existing caller of plain `-SandboxRun` (the `doctor` probe, phase tests, any future lead-side probe) loses the Cursor login copy in its run home. The justification given is "Plain commands get no Cursor login copy" and "Not copying them for plain commands is a small follow-up and is included here." This is framed as a tidy-up, but it is a security *improvement* (less exposure) that is also a *behavior change* for any caller that relied on `auth.json` being present in the run home. The document does not list this under Risks or Alternatives, and does not say which existing callers (if any) depend on the login copy. If none do, the change is free; if any do, it is a silent regression.

**Proposed Resolution:** No inventive pattern needed — call out the behavior change explicitly in the Risks table with an audit of existing `-SandboxRun` callers, and confirm none read `auth.json`/`cli-config.json`. If a caller does, gate `-NoLogin` behind the verify path only (a `-NoLogin` switch passed by `feature.ps1 verify`'s call, not forced inside `Invoke-SandboxCommand`).

**Secondary Liabilities:**
- Per-call gating re-introduces a parameter that callers can forget; the "always pass it" default is safer if no caller needs the login.
- The audit is a documentation cost, not a code cost.

---

## Finding 7 — Nit

**Affected Scope:** "Components: the `test` object"; Rules "`verify` output"; `schemas/verify.schema.json`.

**False Compromise:** The schema gains `where` (required, enum `sandbox|host`) and `setup` (required, `null` or `{status, message, proposal}`). The document specifies that when `setup` is non-null, `passed` is `false`, `exitCode` is `-1`, and `tail` is `setup.message`. This is a clean extension and existing readers keep working because `exitCode` stays an integer. The unexamined trade-off is that `setup` carries a `proposal` (for `environment-missing`) that duplicates the `proposal` already present in `-SandboxRun`'s output and in `-SandboxEnv`'s output. A reader of `state.json` now sees the proposal in three shapes: the `-SandboxEnv` report, the `-SandboxRun` output's `proposal`, and `test.setup.proposal`. The document does not state whether they are guaranteed identical, or which is canonical when they differ (e.g., a stale `state.json` after an `-Apply` between the verify run and the read).

**Proposed Resolution:** **Intermediary** — name one source of truth: `test.setup.proposal` is a verbatim copy of the `-SandboxRun` `proposal` at verify time, stamped with the verify `at` time, and `build.md` is told totreat `test.setup.proposal` as stale if a `-SandboxEnv -Apply` has run since `test.at`. The schema documents the copy, not a re-derivation.

**Secondary Liabilities:**
- A staleness rule in `build.md` is a new procedural step the lead must follow (compare `test.at` to the latest `-Apply` time); a missed comparison could send the lead to a stale proposal.
- Storing only a copy means a reader cannot re-derive the proposal from current state without re-running `-SandboxEnv`; if `state.json` is the only record after a worktree is cleaned, the copy is what survives, so the duplication is also a durability win — the trade-off cuts both ways.

---

## Summary

The document meets the Feature Specification standard's alternatives bar and addresses its core contradiction honestly. The findings above are advisory: Findings 1–4 are **Major** — they name operational costs (slot-occupancy serialization, the unconsidered scoped-approval middle ground, a second parallel orchestration path, and a hard-kill leftover in the worker's tree) that the document frames as solved or does not name. Findings 5–7 are **Nits** — ordering and documentation gaps. None block the design; each has a concrete inventive resolution whose secondary liabilities are stated above.
