<!-- persona: design_critic | agent: cursor | model: glm-5.2-high -->
I have enough context to write the review. Here it is.

---

# Design Critic Goldfish — REVIEW of `docs/designs/sandbox-verify.md`

Mode: REVIEW. Target: `docs/designs/sandbox-verify.md` (lines 1–235). Standard: Feature Specification Standard. Cross-referenced against `sandbox-env.md`, `worker-sandbox.md`, `delegate.ps1`, `Sandbox.psm1`, `feature.ps1`, `build.md`, `SKILL.md`, `verify.schema.json`.

## Standard Compliance

The document satisfies the Feature Specification Standard's enumerated requirements: Problem Statement (lines 13–24), Goals & Non-Goals (25–38), Proposed Architecture (51–95), Alternatives Considered (102–143), and Risks & Mitigations (97–101). The Alternatives Rule is met: five alternatives are evaluated and each rejection states a concrete technical trade-off (history mutation under the worker, silent re-approval collapse, command-string ≠ code-run ambiguity, false-positive host escalation, two-rule inconsistency). No rejection is attributed to an external maintainer without a link.

## Findings

### 1. Major — `G4` overstates "the worktree is not changed for the lead"

**Affected Scope:** `docs/designs/sandbox-verify.md` line 33 (G4) and line 99 (Risks), vs `sandbox-env.md` "Linking"/"Unlinking" (junctions persist until `-Cleanup`).

**Finding:** G4 claims "the worktree is not changed for the lead: the sandboxed run writes only what the test itself writes." But `Add-SandboxEnvLinks` creates `<worktree>\<project>\.venv` junctions for the sandboxed `verify` run, and per `sandbox-env.md` unlinking happens only in `-Cleanup`, which runs after the lead merges. So between `verify` and merge the lead's `git -C <wt> status` will show `.venv` as an untracked directory unless the repo's `.gitignore` covers `.venv`. The scope check runs before the test so it is unaffected (as G4 actually claims), but the literal phrase "the worktree is not changed for the lead" is false for the review step. The Risks table row "A test writes files into the worktree" does not mention the harness-added junctions at all.

**Recommendation:** Reword G4 to scope the claim to the `changed`/`outOfScope` computation, and add a Risks row noting that `.venv` junctions remain in the worktree until `-Cleanup` (as for worker launches), so a repo without `.venv` in `.gitignore` will show an untracked directory during review. Either confirm `.venv` is gitignored in target repos or document the noise.

### 2. Major — Cap-rule race between back-to-back `verify` calls

**Affected Scope:** `docs/designs/sandbox-verify.md` lines 57 (D5), 199 (Cap rule), vs `feature.ps1` `Get-LiveDelegateRunCount` (1759–1780) and `build.md` "After each worker run" (line 79).

**Finding:** D5 makes `verify` count toward the cap by writing the pid file "before the slot is taken." `Get-LiveDelegateRunCount` counts live `*.pid` files whose `feature` matches. But the lead calls `feature.ps1 verify` directly after each worker returns — it is not dispatched through `schedule`. Consider two workers finishing close together: the lead launches `verify` A (pid written, slot taken), then `verify` B (pid written, waiting for a slot, `liveRuns=2`). If `verify` A finishes and deletes its pid before B takes a slot, there is a window where `liveRuns=1` and a `schedule` call would return a third task; the lead launches worker C, and now three runs contend for two slots. The design's mitigation ("the lead follows the cap rule before each") is procedural, not enforced by `verify` itself, and `build.md`'s "After each worker run" section does not tell the lead to call `schedule` before `verify`.

**Recommendation:** Either (a) have `verify` itself call `schedule`/cap-check before taking a slot and block/queue, or (b) add an explicit step in `build.md`'s "After each worker run" requiring the lead to confirm `liveRuns < cap` before each `verify`, mirroring the preflight/lens/council rule in `SKILL.md` line 233. As written, the cap is enforced for `schedule`-dispatched runs but not for the `verify` path the lead drives directly.

### 3. Major — `tail` semantics diverge between `verify` and `-SandboxRun`; `output` dropped silently

**Affected Scope:** `docs/designs/sandbox-verify.md` lines 64 (Components, `tail`), 188 (Mapping: "test.tail is `-SandboxRun`'s `tail` … never `output`"), vs `Sandbox.psm1` `Get-SandboxCommandOutputLines` (2202–2224) and `Invoke-SandboxCommand` (2258–2342).

**Finding:** The design adds `tail` to `-SandboxRun`'s output as "the **last** 40 lines of stdout then stderr" and keeps `output` as "the first 40." But the existing `Invoke-SandboxCommand` returns only `output` (first 40, via `Get-SandboxCommandOutputLines`). Adding `tail` is a new code path in `Sandbox.psm1`. The design says `test.tail` is `-SandboxRun`'s `tail` "never `output`" — but for `environment-missing` and `sandbox-error`, there is no `-SandboxRun` `tail` at all; the design sets `tail = setup.message` in those cases (line 171). That is a third meaning of `tail`. A reader of `state.json` seeing `tail` cannot tell whether it is "last 40 lines of test output", "an environment-missing message", or "a sandbox-error string" without also reading `where`/`setup`. The schema adds `where` and `setup` but does not constrain `tail`'s form. This is a contract ambiguity for any downstream consumer of `state.json` (the lead today, and any future dashboard/audit tool).

**Recommendation:** Either (a) keep `tail` strictly as "last 40 lines of test output" and put setup errors only in `setup.message` (with `tail` empty/null in those cases), or (b) document the three meanings explicitly in the schema description and in `build.md`'s reading instructions. Option (a) is cleaner; the current `build.md` flow already reads `test.setup` before `test.passed`, so `tail` does not need to carry setup text.

### 4. Major — `verify` timeout accounting understates real wait and can kill a still-running sandbox

**Affected Scope:** `docs/designs/sandbox-verify.md` lines 187–189 ("Waiting for `delegate.ps1`"), vs `delegate.ps1` `-SandboxRun` block (303–363) and `Sandbox.psm1` `Get-SandboxSlot` (1690, 60 s wait) / `Invoke-SandboxCommand` (2280, 60 s slot wait).

**Finding:** `verify` passes `-TimeoutSec <t>` to `delegate.ps1` and waits `<t> + 300` s for the delegate process. But the delegate process itself spends up to 60 s in `Get-SandboxSlot` waiting for a slot, then up to `<t>` s in `Invoke-SandboxCommand`, then grant/link/cleanup time. With D5 making `verify` count toward the cap, a `verify` that hits a busy slot waits up to 60 s before its test even starts; the delegate's own `<t>` clock starts only after the slot is taken, so total wall time can be `60 + <t> + cleanup`. The `<t> + 300` budget covers this in the common case, but if the slot wait is near 60 s and cleanup is slow on a large worktree, the 300 s margin is comfortable but not obviously so. More importantly: when `verify`'s `<t> + 300` fires, it "kills the process tree and reports `sandbox-error` with `delegate.ps1 did not finish`." Killing the delegate.ps1 process does not release the sandbox slot mutex (Windows releases it on process death, OK) but the slot ledger may remain and the run folder may remain — the design does not say `verify` cleans up the slot ledger or the `runs\probe-<hex>\` folder after a kill. A stale ledger blocks the next run in that slot until `Get-SandboxSlot`'s abandoned-mutex/ dead-pid recovery runs, which is fine, but the leftover `runs\probe-<hex>\` folder and the pid file (deleted in an "outer `finally`" that never runs if the process is killed) may accumulate.

**Recommendation:** Specify what `verify` cleans up when it kills `delegate.ps1`: confirm the slot is released via the existing dead-pid recovery in `Get-SandboxSlot`, and state whether the orphaned `runs\probe-<hex>\` folder and the pid file are reaped (the pid file is "removed in an outer `finally`" — but a killed process has no `finally`). Either widen the wait budget or document that a killed `verify` leaves a stale pid file that the next `Get-LiveDelegateRunCount` may mis-count as live until the dead-pid check drops it.

### 5. Major — `XAGENT_DELEGATE_SCRIPT` is an undocumented production escape hatch

**Affected Scope:** `docs/designs/sandbox-verify.md` line 186 ("Which `delegate.ps1`") and line 209 (fake-delegate fixture).

**Finding:** `verify` resolves the delegate script as `<skill dir>/../delegate/scripts/delegate.ps1`, overridable by `XAGENT_DELEGATE_SCRIPT`, "documented only in the tests." This is the same pattern `doctor` uses. But `verify` runs the worker's test command through this script — i.e. it executes a PowerShell script chosen by an environment variable, inside a sandbox slot, with the worker's untrusted test code as the inner command. If a malicious or careless actor sets `XAGENT_DELEGATE_SCRIPT` in the lead's environment, `verify` runs an arbitrary script with the lead's privileges on the host (the delegate script itself runs on the host, only the inner command runs in the sandbox). The design says the override "exists so tests can use a fake" — but it is a real, unguarded host-code-execution hook gated only by an env var. The threat model in `worker-sandbox.md` explicitly distrusts worker-written code; this hook is not worker-reachable, but it is also not mentioned in `SKILL.md`, `README.md`, or any security note.

**Recommendation:** At minimum, document `XAGENT_DELEGATE_SCRIPT` in `delegate/SKILL.md` as a test-only override and note that it must not be set in production. Preferably, gate it: refuse the override unless `XAGENT_DELEGATE_SCRIPT_ALLOW` is also set, or only honor it when `XAGENT_SANDBOX_ROOT` points outside the default location (a test indicator). A silent host-code-execution env var is a real footgun.

### 6. Major — Phase test host-fallback decision is recorded only as a `decision` line, not in any queryable state

**Affected Scope:** `docs/designs/sandbox-verify.md` lines 89–91 (Flow, phase test host fallback) and line 194 (Host runs: phase logging).

**Finding:** For a task, `verify -OnHost` stores `test.where: host` in `state.json` under the task's `verify` record — queryable via `feature.ps1 status`. For a phase test run on the host, the only record is a `feature.ps1 decision -Kind decision -Text "phase <n>: …"` line. There is no `state.json` field, no phase record, and no schema for "this phase was tested on the host." The design itself notes "there is no `verify` record for a phase, today or after this feature." That means an auditor cannot answer "was any phase of this feature ever run on the host?" without parsing `decisions.md` free text. Given D1 makes every phase test sandboxed by default and D2 makes host runs approval-gated, the frequency of host phase runs is a security-relevant signal that deserves a structured record.

**Recommendation:** Add a phase-level record (e.g. a `phaseTests` array in `state.json` with `{phase, where, at, approved}`), or at minimum require the `decision` line to use a distinct `-Kind` (e.g. `host-run`) so it can be queried by `feature.ps1 status`/`decisions` filters. A free-text `decision` line is too weak a record for "worker-equivalent code ran on the host."

### 7. Nit — Alternatives rejection phrasing

**Affected Scope:** `docs/designs/sandbox-verify.md` lines 110, 117, 125, 137, 143.

**Finding:** Every alternative ends with "Rejected by author (Dn)." The standard's Alternatives Rule says rejection rationales "must not attribute a rejection to a maintainer without linking their issue, discussion, or PR." The author is the spec author, not an upstream maintainer, so this is technically compliant, and each rationale does state a concrete trade-off. But the repeated "Rejected by author" formula adds nothing the D-table doesn't already say and slightly weakens the appearance of independent evaluation.

**Recommendation:** Drop "Rejected by author" and lead with the technical reason (e.g. "Reason for rejection: a temporary commit mutates the worktree's history under the worker (D3).").

### 8. Nit — `30,000`-character limit is asserted without derivation

**Affected Scope:** `docs/designs/sandbox-verify.md` line 184.

**Finding:** The design refuses a sandboxed run when the `delegate.ps1` command line would exceed 30,000 characters, citing the 32,767 Windows limit. But the wrapper is UTF-16LE base64-encoded, so a wrapper of N characters produces ~`(4/3) * 2N` base64 chars ≈ 2.67N. A 30,000-char final command line leaves only ~11,000 chars for the wrapper before encoding — far less than the host path allows today. The design does not state the effective wrapper-size ceiling, so a reader cannot tell whether a realistic test command (a long `pwsh -File scripts/test.ps1 -Path … -Filter …`) fits until it is refused at runtime.

**Recommendation:** State the effective pre-encoding wrapper limit (≈11 KB) and confirm the largest expected test command in this repo fits. If 11 KB is tight, consider passing the wrapper via a temp file in the run folder instead of `EncodedCommand` on the command line (the run folder is writable on the host before the slot is taken).

### 9. Nit — `Get-SandboxSlot` timeout (60 s) vs `verify` slot-wait is not reconciled

**Affected Scope:** `docs/designs/sandbox-verify.md` line 198 ("`Get-SandboxSlot` still times out after 60 s, which `verify` reports as `sandbox-error`"), vs `Sandbox.psm1` `Get-SandboxSlot` (1690) and `Invoke-SandboxCommand` (2280).

**Finding:** If the two slots are held by two workers and `verify` waits, `Get-SandboxSlot` throws `sandbox: no free slot (both slots busy)` after 60 s. `delegate.ps1`'s `-SandboxRun` block catches this and `Fail`s with `{ok:false, error}`. `verify` maps `ok:false` to `sandbox-error`. So a `verify` that merely lost the slot race is reported as `sandbox-error`, which `build.md` treats as a problem stop. A slot race is transient (the workers will finish), but the design offers no retry — the lead must stop and ask the user, who will say "retry," and the lead re-runs `verify`. This is operationally noisy for a common transient condition.

**Recommendation:** Either (a) let `verify` retry once on `no free slot` after a short backoff, or (b) document in `build.md` that a `sandbox-error` whose `message` is `no free slot` is retried once by the lead without a problem stop (analogous to the existing `sandbox: environment not ready` exception).

### 10. Nit — Verification step 2 creates `D:\xagent-verify-check` but harness says "work only inside this directory"

**Affected Scope:** `docs/designs/sandbox-verify.md` lines 233–235 (Verification, check 2), vs the harness context note in the task file (lines 127–131): the worker runs in an isolated worktree and is told "Work only inside this directory."

**Finding:** Verification check 2 creates a scratch repo at `D:\xagent-verify-check` outside the worktree and deletes it afterwards. This is a lead-run live check at sign-off, not a worker task, so the harness constraint does not strictly apply to the lead. But the design does not call out that this check is exempt from the "work only inside this directory" rule, which could confuse a worker who reads this section as a task instruction.

**Recommendation:** Add a one-line note that checks 2–4 are lead-run, at sign-off, outside the worktree, and are not worker tasks.

## Summary

The design is well-structured, addresses the standard's required sections, and evaluates alternatives with concrete trade-offs. The main substantive gaps are: (1) G4's wording overclaims worktree immutability during review when `.venv` junctions persist; (2) the cap rule is enforced for `schedule`-dispatched runs but not for the `verify` path the lead drives directly; (3) `tail` carries three distinct meanings depending on `where`/`setup`; (4) `verify`'s kill path on timeout does not specify cleanup of the pid file/run folder; (5) `XAGENT_DELEGATE_SCRIPT` is an undocumented host-code-execution env-var override; and (6) host phase-test runs are recorded only as free-text decisions, not structured state. The Nits concern alternatives phrasing, the unstated effective wrapper-size limit, the unreconciled 60 s slot timeout, and a verification step that crosses the worktree boundary without noting it.
