<!-- persona: style | agent: cursor | model: glm-5.2-high -->
# Style Goldfish — Review Report

**Mode:** REVIEW
**Target:** `docs/designs/worker-sandbox.md`, lines 1–332 (feature specification, Stage 7 critic pass)
**Scope audited:** tone, conciseness, objectivity, claim calibration, fluff/redundancy, defensive caveats.

The document is largely dry and direct. Findings below are ordered by severity. Line numbers refer to the committed file.

---

## Blocker

None.

---

## Major

**M1. Overview overstates the network control that G3 actually delivers.**
- **Affected Scope:** Overview, ~line 11 ("shell commands reach only an allowed list of network hosts").
- **Style Rationale:** Uncalibrated claim / inconsistency. The Overview promises a per-host allowed list, but the amended G3 (~line 31) explicitly retreats from that: "A run either has internet access … or has none … a host-level allowed list is a Future Improvement." The Overview describes a capability the design later says it does not have. A fresh reader taking the Overview at face value will expect host filtering that never appears in the Technical Plan.
- **Recommended action:** CALIBRATE the Overview sentence to match the amended G3 (per-run on/off, not a host list).

**M2. G3's "per-run switch" framing is not implemented, and its Pass criterion tests G1 instead.**
- **Affected Scope:** G3 (~line 31), "Launch and kill" (~line 149, "Every container gets the `internetClient` capability (G3)"), and the Verification Plan's "Canary" line (~line 537).
- **Style Rationale:** Two linked calibration problems.
  1. G3 states "A run either has internet access … or has none," implying an off mode. But "Launch and kill" grants `internetClient` to *every* container, and no mechanism for a sandboxed run without internet is described. The "or has none" branch has no implementation and no test. The claim outruns the evidence.
  2. G3's Pass criterion ("the canary test shows the canaries are unreadable, so no network path can carry them") verifies file isolation (G1), not the on/off switch the goal names. The pass test does not match the goal statement.
- **Recommended action:** CALIBRATE G3 — either restate the goal as "all sandboxed runs have internet; host filtering is deferred" to match the implementation, or describe the off switch and add a pass test that exercises it (a run with network reaches a host, a run without cannot).

**M3. "the current, tested copy" / "the current, tested `delegate`" is an uncalibrated quality claim.**
- **Affected Scope:** Overview ~line 13; G6 ~line 35 and ~line 169 ("Freezing `delegate` for this build").
- **Style Rationale:** "Tested" is a subjective quality judgment presented as fact. The frozen copy is the `main` checkout at the lock commit; the design cites no test run proving that copy passes. Repeated three times, so it reads as a blanket assurance rather than a verified property.
- **Recommended action:** CALIBRATE — replace "tested" with a concrete reference ("the `main` checkout at the lock commit") or cite the passing test run recorded in `test-plan.md`.

---

## Minor

**m1. "A sandboxed run uses the same memory as an unsandboxed one."**
- **Affected Scope:** Performance, ~line 315.
- **Style Rationale:** Uncalibrated claim with no measurement. AppContainer adds little, but "the same memory" is a strong equality the design does not verify. The preceding sentence ("no fixed memory cost") is the defensible claim.
- **Recommended action:** CALIBRATE to "adds no fixed memory cost" and drop the equality.

**m2. "start-up is about 0.5 s for the Cursor CLI."**
- **Affected Scope:** Open Questions, "Speed", ~line 47.
- **Style Rationale:** Measured-behavior claim with no cited source. The probe is referenced elsewhere for other numbers; this one floats. "About" hedges it, but the figure still implies a measurement the reader cannot trace.
- **Recommended action:** CALIBRATE — cite the probe run, or restate as "start-up is dominated by the Cursor CLI, measured in the build."

**m3. Token-refresh copy-back is a deferred decision stated as a future action.**
- **Affected Scope:** "Cursor login", ~line 153 ("If testing shows that a token refresh inside the sandbox invalidates the user's own token, a checked copy-back is added").
- **Style Rationale:** Defensive caveat. It is correctly placed at the Cursor-login step (so not a RELOCATE), but it commits to an action conditional on a test whose result is still open (Open Questions, ~line 45). As written it reads as a decision; the Open Question says it is not decided.
- **Recommended action:** CALIBRATE — restate as "if the token-refresh check (Verification Plan) shows invalidation, a checked copy-back will be added," tying the action to the named verification step.

**m4. "the same isolation by default" overstates AppContainer parity.**
- **Affected Scope:** Alternative A rejection, ~line 203.
- **Style Rationale:** The design itself documents AppContainer gaps that a normal account does not have (pipe-name patch, `subst` drive letters, `taskkill` hang, per-user toolchain read list). "The same isolation" is therefore stronger than the rest of the document supports. The real differentiator — "no account, no password, no admin step" — is valid on its own.
- **Recommended action:** CALIBRATE to "comparable isolation, with no account, no password and no admin step," or drop "the same."

**m5. `<repoKey>` definition diverges between table and implementation.**
- **Affected Scope:** "What the sandbox can reach" table ~line 129 ("SHA-256 of the repo's full path") vs. `Get-RepoKey` ~line 383 ("SHA-256 of the lower-cased full path").
- **Style Rationale:** Imprecise terminology; two definitions of the same key. A reader implementing from the table will produce a different key than the code.
- **Recommended action:** CALIBRATE the table to include "lower-cased."

---

## Nit

**n1. "The build has two rules of its own."**
- **Affected Scope:** Overview, ~line 13.
- **Style Rationale:** "Of its own" adds nothing. "The build has two rules." carries the same signal.

**n2. "its network blocking is at best partial."**
- **Affected Scope:** Problem, ~line 25.
- **Style Rationale:** Reasonable calibration, but the evidence is Cursor's documentation silence on Windows, not a measured result. Acceptable as-is; flagging only for the record.

**n3. "most target repos here are Windows-first."**
- **Affected Scope:** Alternative B rejection, ~line 213.
- **Style Rationale:** Context claim about the user's own repos; not independently verifiable from the document, but acceptable as the author's stated context. No change required.

**n4. "All tests pass: the 218 existing ones and the new ones."**
- **Affected Scope:** Verification Plan, ~line 533.
- **Style Rationale:** "218" is a specific count stated as a target. If the count drifts as tests are added, the line becomes stale. Consider "the existing suite plus the new tests" unless the count is locked at freeze.

---

## Summary

The strongest cluster is **M1–M2**: the network story is inconsistent across the Overview, G3, and "Launch and kill." The Overview promises a host allowed list, G3 promises an on/off switch, and the implementation grants `internetClient` to every container with no off mode described. A fresh reader cannot reconcile the three. Resolving this cluster is the main editorial fix; the remaining findings are local calibration and word-choice nits. No hyperbole, marketing fluff, or synonym redundancy was found — the document's tone is already at the dry, factual register the role expects.
