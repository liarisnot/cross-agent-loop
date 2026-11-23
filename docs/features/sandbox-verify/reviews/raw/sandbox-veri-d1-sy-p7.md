<!-- persona: style | agent: cursor | model: glm-5.2-high -->
# Style Goldfish — Review of `docs/designs/sandbox-verify.md`

Scope: lines 1–235. Persona: Technical Copy Editor (clarity, precision, brevity, objectivity, claim calibration). Findings below; caveats classified per the persona's `DROP | CALIBRATE | RELOCATE | KEEP` scheme.

## Findings

### 1. Major — D4 rationale: false precedent for `doctor`
**Affected scope:** Decisions table, D4 (line ~64).
**Style rationale:** D4 justifies routing through `delegate.ps1 -SandboxRun` with "feature.ps1 already calls delegate.ps1 that way for doctor." This is a claim about existing behavior that outruns the evidence. `feature.ps1 doctor` does not invoke `delegate.ps1` at all — it only `Test-Path`-checks the script's existence (`skills/feature/scripts/feature.ps1:3039-3042`), and it never uses `-SandboxRun`. The cited precedent does not exist.
**Recommended action:** CALIBRATE — either cite an actual existing `feature.ps1` → `delegate.ps1 -SandboxRun` call (none was found in the read-only source) or drop the "already calls … that way for doctor" justification and rest D4 on the architectural argument alone (sandbox code stays in the delegate skill).

### 2. Major — D2 rationale: unquantified "rare" / "few"
**Affected scope:** Decisions table, D2 (line ~65).
**Style rationale:** "A sandbox failure is rare (this repo's task tests pass in the sandbox), so the prompts are few." `rare` and `few` are subjective frequency judgments. The parenthetical only covers this repo's task tests; the claim is then generalized to "the prompts are few" across all repos, which the design does not measure. A repo whose tests need the host (acknowledged in the Problem section and D1) would prompt at every task.
**Recommended action:** CALIBRATE — restrict to "in this repo's task tests pass in the sandbox" and drop the general "prompts are few" claim, or quantify the expected prompt rate per repo class.

### 3. Major — Risks table: uncalibrated "a few seconds"
**Affected scope:** Risks and Mitigations table, row 1 (line ~100).
**Style rationale:** "Slower checks: about 14% measured, plus a few seconds to set up the slot." The 14% is measured (604 s vs 531 s, lines ~38); "a few seconds to set up the slot" is not. Mixing a measured figure with an unquantified estimate in the same cell blurs the calibration.
**Recommended action:** CALIBRATE — cite a measured slot-setup time or drop the clause ("Slower checks: about 14% measured.").

### 4. Nit — Open Questions: dangling Q1/Q2 references
**Affected scope:** Open Questions (line ~41).
**Style rationale:** "Q1 and Q2 were decided by the author on 2026-11-19 (D1, D2 below)." Q1 and Q2 are never stated anywhere in the document; a fresh reader cannot tell what was decided. D1 and D2 are self-contained, so the Q1/Q2 reference adds no signal.
**Recommended action:** DROP the "Q1 and Q2" reference (leave "None. The open questions were decided by the author on 2026-11-19; see D1 and D2.") or restate the two questions in one line each.

### 5. Nit — Overview: vague "minutes later"
**Affected scope:** Overview, last sentence (line ~16).
**Style rationale:** "A worker that wrote harmful code, on purpose or by mistake, gets it run outside the sandbox minutes later." `minutes later` is a vague temporal claim and is redundant with the Problem section's "It happens before review. The build stage runs verify before the lead reads the diff." The ordering, not the elapsed minutes, is the operative fact.
**Recommended action:** CALIBRATE — replace with the concrete ordering ("…gets it run on the host during the build stage, before review.") or DROP the temporal clause.

### 6. Nit — Overview: "and little else"
**Affected scope:** Overview, line ~12.
**Style rationale:** "every Cursor worker runs in a Windows AppContainer that can reach its worktree and little else." `and little else` is imprecise filler; the actual surface is a fixed read list per `worker-sandbox`.
**Recommended action:** CALIBRATE — name the surface ("…can reach its worktree and a fixed read list") or DROP ("…can reach its worktree and little else" → "…can reach only its worktree").

### 7. Nit — Flow: informal "right there"
**Affected scope:** Flow of a task check, phase-test paragraph (line ~91).
**Style rationale:** "(a fresh worktree is right there: the phase test runs merged code)." `right there` is conversational filler.
**Recommended action:** DROP — "(a fresh worktree is appropriate: the phase test runs merged code)."

### 8. Nit — Rules: "as doctor finds it"
**Affected scope:** Rules, "Which delegate.ps1" (line ~187).
**Style rationale:** "<skill dir>/../delegate/scripts/delegate.ps1, as doctor finds it." Informal shorthand. Accurate (doctor does locate that path), but the phrasing reads as colloquial reference rather than a precise path-resolution rule.
**Recommended action:** CALIBRATE — "the same path doctor locates" or describe the resolution explicitly.

### 9. Nit — Problem: "most repos" loosely quantified
**Affected scope:** Problem, bullet 3 (line ~21).
**Style rationale:** "The phase test has the same gap in most repos." `most repos` is quantified only by the next sentence ("only when the repo has Python projects. Every other repo, this one included"). The reader must parse two sentences to learn "most" means "repos without Python projects."
**Recommended action:** CALIBRATE — lead with the precise class: "The phase test has the same gap in repos without Python projects."

## Items reviewed and kept (not findings)
- Measured block (line ~38): numbers internally consistent (228+1 skipped = 229 host; 604 vs 531 s ≈ 13.7% ≈ "14%"). KEEP.
- D6 rationale (exit code cannot distinguish access-denied from a real bug): concrete and calibrated. KEEP.
- Risk row "The test can read Cursor's login copy" with "No new exposure … Unchanged by this feature": calibrated to existing behavior. KEEP.
- "Not every test can run in a container" paragraph: concrete examples (AppContainers, drive letters, `HKCU\Software\Pester`), with named mitigations. KEEP.
- Rules "encodes it as UTF-16LE base64 the way `Invoke-TaskTestCommand` does": matches `skills/feature/scripts/feature.ps1:2623` (`[Text.Encoding]::Unicode.GetBytes`). KEEP.
- "Get-SandboxSlot still times out after 60 s": matches `skills/delegate/scripts/Sandbox.psm1:2279,2613`. KEEP.
- `Get-LiveDelegateRunCount` "already counts any `*.pid` under `.xagent\runs` with those three fields": matches `feature.ps1:1764-1771` (recursive `*.pid`, checks `pid`/`startTime`/`feature`). KEEP.
- No subjective quality judgments ("beautiful", "terrible", etc.) and no synonym redundancy ("quick and rapid" type) found. No "essentially"/"simply"/"it is important to note" filler found.

## Summary
9 findings: 3 Major (claims about existing/quantified behavior that outrun evidence — D4 doctor precedent, D2 "rare/few", Risks "a few seconds"), 6 Nit (informal filler and dangling references). No Blockers. The document is largely precise and well-calibrated; the Major items are all in decision/rationale text where a measured or existing-behavior claim should be narrowed to its evidence.
