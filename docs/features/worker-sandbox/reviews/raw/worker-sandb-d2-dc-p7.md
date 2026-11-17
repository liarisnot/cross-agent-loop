<!-- persona: design_critic | agent: cursor | model: glm-5.2-high -->
# Goldfish Review Report: design round 2 (re-audit)

**Target:** `docs/designs/worker-sandbox.md` lines 1–511, feature specification portion.
**Mode:** REVIEW.
**Standard:** Feature Specification Standard (problem statement, goals/non-goals, proposed architecture, alternatives considered with rejection rationale, risks & mitigations).
**Round-1 findings:** `docs/features/worker-sandbox/reviews/design-1.md`. **Author resolution:** `docs/features/worker-sandbox/reviews/resolution-1.md`.
**Scope of this round:** verify round-1 fixes landed; stress-test what is new since round 1 (reserved drive letters + per-slot containers, slot mutex + slot ledger, per-run grants, read list, host services, Risks & Mitigations).

## Verdict on round-1 fixes

Spot-checked against the repo and the design text. Resolved as claimed:

- **B1** (canary under profile): canary now at `<repoParent>\<repo>.xagent\canary-<rand>`, outside the profile; `Invoke-SandboxCanary` writes the in-container script and cleans up in `finally` (lines 277–279, 577). Fixed.
- **B2** (patch reuse): `Get-SandboxRuntime` reads `patch.json` first and reuses on hash match / libuv ≥ 1.53 (lines 558–565). Fixed.
- **B3** (launch contract): direct `node.exe index.js`, argument tail, working folder `<slot>:\`, `--workspace <real worktree path>` all spelled out (lines 246–248). Fixed.
- **B4/M9** (shared capabilities): dropped; per-run grants to the slot container SID (lines 181–191). Fixed.
- **B5** (G7 placement): moved to phase 3 `code-hard`, split into "Decided"/"Yours to decide" (lines 316–318, 745). Fixed.
- **B6** (G6 freeze + check): `skillDir` field added to summary and `runs.jsonl`; freeze is a `main` worktree at the lock commit (lines 287, 308–314, 759). Fixed.
- **B7** (retry rules): `sandbox:` exception named in `delegate` SKILL.md, `feature` SKILL.md, and `build.md`; `build.md` added to file list (lines 291, 682–690). Confirmed against `skills/feature/SKILL.md:216,237` and `skills/feature/stages/build.md:58`. Fixed.
- **B8** (doctor): fast `Test-SandboxSupport` in-process, `required = $false`, canary stays on `-SandboxCheck`; `feature.Tests.ps1` added to file list with ten-check expectation (lines 608–611, 701). Confirmed against `feature.Tests.ps1:2469–2476` (currently asserts 9). Fixed.
- **M2, M3, M6, M7, M10–M14, M18–M20, M22–M30, N1–N21**: applied as specified. Spot-checked the access table (lines 181–191), environment block (lines 250–255), summary shape (lines 287–289), pipe-name hex (lines 230–231), and Risks heading (lines 473–491). Fixed.

No round-1 finding is re-raised. The remainder of this report covers what is new or newly exposed.

---

## Findings

### Major 1 — Per-slot permanent containers break isolation across logon sessions

- **Affected scope:** "Reserved letters and slots" (lines 168–176); "What the sandbox can reach" (lines 181–191); Risks row "Two runs read each other's work" (line 481).
- **Finding & recommendation:** The mutex is `Local\xagent-slot-<L>` and `subst` mappings are per-logon-session, so within one session the two-slot protocol is sound. But the slot containers `xagent.slot-S` / `xagent.slot-T` are **permanent** (created at reservation, line 172) and identified by SID, not by session. If two logon sessions on the same machine each take "slot S", both processes run under the same AppContainer SID, and both runs' grants (made to that SID) accumulate on disk. Session A grants `worktree-A` to `xagent.slot-S`; session B grants `worktree-B` to `xagent.slot-S`; both processes can now read both worktrees. The "concurrent runs can't read each other's worktrees" property silently fails across sessions, and the slot ledger at `%LOCALAPPDATA%\xagent\sandbox\slot-S.json` is a shared file raced by two sessions. The design targets "this machine" (single user, typically single session), so this is not a Blocker, but the Risks table currently asserts "None known" for cross-run reads. Either (a) add a Risks row stating that isolation is per-logon-session and concurrent runs from different sessions on the same machine are out of scope, or (b) namespace the slot identity by logon session (e.g. `xagent.slot-<L>-<session>` and a `Global\`-free session-local name) so cross-session runs cannot share a SID. Option (a) is the smaller change and is recommended given the stated scope.

### Major 2 — "AbandonedMutexException counts as taken" is ambiguous against the crash-recovery claim

- **Affected scope:** `Get-SandboxSlot` (lines 176, 572); "Crash safety" (lines 174–175).
- **Finding & recommendation:** `Get-SandboxSlot` says "An `AbandonedMutexException` counts as taken" (line 572), and "Crash safety" says "A lock taken over from a dead run arrives as `AbandonedMutexException` and counts as taken, so a crashed run's slot is free with no clean-up logic" (lines 174–175). In .NET, `WaitOne` on an abandoned mutex **acquires** the mutex and throws `AbandonedMutexException`; the caller already owns it. "Counts as taken" reads, in plain English, as "counts as already held by someone else — skip," which is the opposite of the intended behavior (the run takes the slot and then cleans the ledger). A naive implementer could catch the exception and skip the slot, deadlocking both slots after one crash. Reword both lines to: "An `AbandonedMutexException` means the previous holder died; the waiter has acquired the mutex and takes the slot. It then removes any ledger left by the dead run before granting." Add a unit test that simulates an abandoned mutex (a child process takes and exits) and asserts the slot is taken and the ledger cleaned.

### Major 3 — `taskkill.exe` limit is asserted but not mitigated, and the design ships the shim's rejection

- **Affected scope:** Risks row "Target repos whose scripts call `taskkill.exe` hang" (line 487); Alternative Q (lines 450–455); `task.md` change (line 692); `delegate.ps1` unsandboxed path (line 599).
- **Finding & recommendation:** The probe (`worker-sandbox-probe/README.md:29`) confirms `taskkill.exe` hangs inside the container even against the container's own child. The design rejects Alternative Q (a `taskkill.cmd` shim) as "documenting the limit is enough for most development" and instead puts the burden on "the target repo changes its scripts." But the design itself still calls `taskkill.exe` in the unsandboxed path today (`delegate.ps1:349`), and `feature.ps1` calls it at three sites (1806, 2290, 2556) that file 4 replaces with `Stop-ProcessTree`. The Risks row says "Documented in SKILL.md and the task template" — but a worker sandboxing a **target repo whose test script** calls `taskkill /T /F /PID` will hang until `-TimeoutSec`, then get killed by the job object, and report `timedOut: true`. The lead has no way to distinguish this from a real hang. Two issues:
  1. The Risks row should name the observable (`timedOut: true` with the `taskkill` call in the tail) so the lead can recognize it.
  2. The rejection of Alternative Q is a real architecture choice, but the design does not say how a worker is supposed to run an unmodified third-party test script that calls `taskkill`. Either add a one-line instruction in `task.md` ("if your test script calls `taskkill.exe`, it will hang in the sandbox; replace it with `Stop-Process -Force` or pass `-NoSandbox`") or revisit the shim. As written, the limit is under-specified for the worker who hits it.

### Major 4 — Read-list refusal rules don't cover the runtime cache or slot idle folder

- **Affected scope:** "Read list" (lines 199–216); "What the sandbox can reach" (lines 181–191).
- **Finding & recommendation:** Refused entries are: profile root; `~\.ssh`, `~\.aws`, `~\.gnupg`, `~\.cursor`, `~\AppData\Roaming`, and the user's Cursor folders; plus a missing path (lines 211–212). That list protects the user's secrets, but it does **not** protect the sandbox's own state. A `read` entry pointing at `%LOCALAPPDATA%\xagent\sandbox` (the root that holds `sandbox.json`, the slot ledgers, and the runtime cache) would be accepted, and would let a worker read another slot's ledger (which records another run's worktree path and grant specs) and the cached `node.exe`. A ledger is not secret, but it is cross-run information the design says sequential runs should not see. Recommend adding to the refusal list: anything equal to or under `<Root>` (the `XAGENT_SANDBOX_ROOT` folder) and under the Cursor install (`XAGENT_CURSOR_ROOT`), with the same `sandbox: read-list entry '<path>' is refused (<reason>)` failure. Also refuse anything under a slot's mapped worktree parent that is not the run's own (harder; the `<Root>` refusal covers the ledger/cache case which is the concrete leak).

### Major 5 — Host-services exemption is "designed for, not granted," but no opt-in mechanism is specified

- **Affected scope:** "Host services" (lines 218–224); Non-Goals (line 69); Future Improvements (line 505); Risks row "The host-services exemption opens every host port" (line 485).
- **Finding & recommendation:** The section proves the mechanism (admin `CheckNetIsolation LoopbackExempt -a -p=<SID>`, per slot, one-time) and states it is "not granted by this feature" and "opt-in per slot later." But the design does not say **how** the opt-in is recorded or invoked. There is no `sandbox.json` field, no `delegate.ps1` flag, and no `Sandbox.psm1` function named for it. A future feature that needs ComfyUI will have to invent the surface. Because the exemption is permanent per container and opens **every** host port (Risks row, line 485), the opt-in is a security-relevant decision that should be pinned now, even if unused. Recommend: add a `hostLoopback: bool` (default `false`) to `sandbox.json` at the slot level (or a per-run `-HostLoopback` switch on `delegate.ps1` that `Set-SandboxLetters`/`Initialize-SandboxLetters` honors), name the `Sandbox.psm1` function that applies/removes it (`Enable-SandboxLoopback -Slot`/`Disable-SandboxLoopback -Slot`), and state that `-SandboxCheck -Release` also removes exemptions. The Risks row's "Decided with the first feature that needs it" can stay, but the storage and invocation should not.

### Major 6 — G3 pass check does not test the network story it asserts

- **Affected scope:** G3 (lines 38–41); Verification Plan "Canary" (line 755).
- **Finding & recommendation:** G3's pass check is "the G1 canary test passes with internet on" (line 41). That tests that G1 holds while the network is on; it does **not** test the actual G3 claim — "A run can send only what it can read: its worktree … and the copy of the user's Cursor login in its run home." The residual risk (Risks row A, line 479) is that the worker exfiltrates the Cursor token. No test in the Verification Plan asserts that the token can leave but that nothing else readable can. A meaningful G3 check would: (a) confirm the run can reach a non-Cursor host (e.g. `https://example.com` returns 200) and (b) confirm the only readable secret is the run-home `auth.json` (already covered by G1's canaries for `~/.ssh` etc.). At minimum, add to the canary a network egress step that succeeds (proving internet is on) so the pass check is not silently vacuous when G1 passes for unrelated reasons. Also, the Overview (line 7) still says "Network access stays on, because every run needs Cursor's servers" — that is consistent with the restated G3, good; confirm no stale "host allowed list" wording remains anywhere (none found).

### Major 7 — `Initialize-SandboxLetters` suggested-letters rule contradicts CUJ 1's example

- **Affected scope:** CUJ 1 (lines 82–87); `Initialize-SandboxLetters` (line 571).
- **Finding & recommendation:** CUJ 1 shows the error `sandbox: no drive letters reserved; suggested: R, S, T`. `Initialize-SandboxLetters` (line 571) generates "suggested: `<three free letters, highest first from Z>`". Highest-first from Z would yield `Z, Y, X` (or similar), not `R, S, T`. Either the example in CUJ 1 is wrong or the rule is wrong. If the intent is memorable contiguous letters near the end of the alphabet, say so ("three free letters, highest contiguous block from R upward") and make CUJ 1 match. If the intent is truly highest-first, fix CUJ 1. This is small but it is the user's first interaction with the feature and the message is specified as an exact string in tests.

### Nit 1 — `worktrees\<WtName>` grant inheritance is unspecified

- **Affected scope:** Access table row "`<repo>\.git\worktrees\<WtName>` | read + write" (line 189).
- **Finding & recommendation:** The row does not say whether the grant is inherited. Git writes `worktrees/<WtName>/index`, `HEAD`, and (for some operations) a `logs/` subfolder. If the grant is not inherited, a `logs/` subfolder would be unwritable and reflog updates would fail. Workers don't commit, so this is likely benign, but the implementer needs to know. Add "(OI)(CI)" or "this folder only" to the spec, matching the explicitness of the `.git` row above it.

### Nit 2 — `~\.gitconfig` copy-back is not addressed by the read-only token rule

- **Affected scope:** "Cursor login and git config" (lines 260–266); Risks row "A worker sends the Cursor token" (line 479).
- **Finding & recommendation:** The token-refresh rule (lines 262–263) says that if a refresh inside the sandbox would invalidate the user's login, merge is blocked until the run home's `auth.json` is made read-only. `~\.gitconfig` is also copied in (line 260) as read-only, so it cannot be modified — good. But the design does not say whether the run home's copy of `auth.json` is writable by the container before the read-only fallback is applied. If the phase-5 check passes (no invalidation), the copy stays writable, and a worker could tamper with its own copy — harmless, since nothing is copied back. State explicitly that neither `auth.json` nor `~\.gitconfig` is ever copied back to the user's profile, so a tampered in-sandbox copy affects only the run that tampered it. The Risks row already implies this; one sentence in "Cursor login and git config" would make it unambiguous.

### Nit 3 — `scripts/test.ps1` Pester minimum vs. the all-users install

- **Affected scope:** "Machine setup" (line 517); file 7 (lines 660–665); M4 resolution.
- **Finding & recommendation:** M4 resolved to `-MinimumVersion 5.5`, and the design says "Pester 5.5 or later installed for all users" (line 517). But "Machine setup" also records "done on 2026-11-13 (6.2.0 in `C:\Program Files\PowerShell\Modules`)" and says "The design requires Pester 5.5 or later." These are consistent, but a reader could read line 517 as "we require 6.2.0 because that's what's installed." Recommend one phrase: "any version ≥ 5.5; 6.2.0 is what this machine happens to have." Already implied; clarity only.

### Nit 4 — Risks table omits the multi-session / multi-user shared-SID case

- **Affected scope:** Risks & Mitigations (lines 473–491).
- **Finding & recommendation:** See Major 1. The table's "Two runs read each other's work" row claims "None known" for what remains. If Major 1 option (a) is taken, this row should carry the cross-session caveat. If option (b) is taken, the row can stay.

---

## Standard compliance

- **Problem statement:** present (lines 13–31), concrete, with the v1 risk row cross-referenced.
- **Goals & non-goals:** present (lines 33–69), each goal has a pass check; non-goals are explicit and include the host-services carve-out.
- **Proposed architecture:** present and detailed (lines 73–318) — components, data flows, access table, launch contract, environment, clean-up, freeze, build order.
- **Alternatives considered:** present (lines 320- **Alternatives considered:** present (lines 320–455), 17 alternatives (A–Q), each with Pros / Cons / Reason for rejection, satisfying the Alternatives Rule. Rejection rationales cite concrete trade-offs (admin step, account/password, test-portability, Pro-only features, binary-patch maintenance, proxy complexity); the only maintainer-attributed rejections are to "the author," which the resolution's D-decisions back, so the rule's "must not attribute to a maintainer without linking their issue" is borderline but the decisions are documented in `resolution-1.md`. Acceptable.
- **Risks & mitigations:** present (lines 473–491), 14 rows, each with Mitigation and What-remains. Gaps: Major 1 (cross-session), Major 3 (taskkill observability), Major 5 (host-services opt-in surface). Major 4 (read-list self-state) is a missing refusal, not a missing row.

## Summary

Round 1 is properly resolved; no round-1 finding is re-raised. The new mechanism (reserved letters, per-slot permanent containers, slot mutex, slot ledger, per-run grants, read list, host-services design, Risks table) is largely sound and well-specified at the implementation level. The remaining gaps are:

- **Major 1** — cross-logon-session shared slot SID is a real isolation hole the Risks table currently denies; document it as out of scope or namespace the slot by session.
- **Major 2** — `AbandonedMutexException` wording reads opposite to intent; reword and add a test.
- **Major 3** — `taskkill.exe` limit is asserted but a worker hitting it has no documented recovery path; name the observable and the worker instruction.
- **Major 4** — read-list refusal does not protect the sandbox's own state (`<Root>`, Cursor install); add those to the refusal list.
- **Major 5** — host-services opt-in has no specified storage or invocation; pin the `sandbox.json` field and `Sandbox.psm1` function now.
- **Major 6** — G3 pass check is vacuous against the G3 claim; add a network-egress step to the canary.
- **Major 7** — CUJ 1's `suggested: R, S, T` contradicts the `Initialize-SandboxLetters` rule; reconcile.
- **Nits 1–4** — `worktrees\<WtName>` inheritance, no-copy-back sentence, Pester version phrasing, Risks-table cross-session caveat.

No Blockers. The design is ready to lock after Majors 1–7 are addressed.
