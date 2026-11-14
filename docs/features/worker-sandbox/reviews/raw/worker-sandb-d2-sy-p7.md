<!-- persona: style | agent: cursor | model: glm-5.2-high -->
# Style Goldfish Review Report — Round 2 (Re-audit)

**Target:** `docs/designs/worker-sandbox.md` (lines 1–511), feature specification part.
**Mode:** REVIEW.
**Scope of re-audit:** resolved findings from round 1, plus what is new since round 1 — reserved drive letters and per-slot containers, the slot mutex and slot ledger, per-run grants, the read list, host services, and the Risks & Mitigations section.

## Resolution verification (round-1 findings that touch style)

All round-1 style findings I checked are fixed in the document:

- **M1 / D7a** — Overview and G3 now state "network on; file isolation limits leaks"; the token-exfiltration residual sits in the Risks table. Fixed.
- **M7** — G2 now reads "cannot change git-tracked files; can write only its run home under `.xagent/`", and names the check by command. Fixed.
- **M20** — The hex bytes and lengths are written in (lines 226–229), and the version comparison rule is stated. Fixed.
- **M29** — `fb-stages`, the denylist, the read-only check, and the profiles each get a one-line definition or link; the build table's "Done by" column no longer calls the lead a profile. Fixed.
- **M30** — A `## Risks & Mitigations` heading exists; Alternatives use Pros / Cons / Reason for rejection; Open Questions holds only open items. Fixed.
- **N4, N6, N7, N8, N9, N10, N17, N18, N19, N20, N21** — each applied. Verified against the relevant lines.

No round-1 style finding that the resolution fixed or deliberately decided is repeated below.

## New findings (round 2)

### Finding S1 — Uncalibrated claim about crash slot recovery
- **Severity:** Major
- **Affected Scope:** "Reserved letters and slots", Crash safety bullet (line ~175).
- **Style Rationale:** The bullet says "a crashed run's slot is free **with no clean-up logic**." The mutex is indeed auto-released, but the run's grants survive until the next run reads the slot ledger and removes them — which *is* clean-up logic, explicitly specified two sections later ("What the sandbox can reach") and in the ledger bullet. The bare phrase overstates what Windows gives for free and contradicts the ledger design a few lines down.
- **Recommended action (CALIBRATE):** Narrow the claim to the lock only, e.g. "so a crashed run's slot *lock* is free with no clean-up logic; its grants are removed by the next run in that slot (see the slot ledger)."

### Finding S2 — "Proven" overruns the evidence
- **Severity:** Nit
- **Affected Scope:** Open Questions, "Which host services MyApp needs" (line ~76).
- **Style Rationale:** "the mechanism is proven (see 'Host services')" — "proven" is a strong word for a single probe run on one machine. The Host services section itself is more careful ("the 2026-11-14 probe showed …").
- **Recommended action (CALIBRATE):** "the mechanism is demonstrated by the probe (see 'Host services')."

### Finding S3 — "Nothing else readable is secret" is an unbounded claim
- **Severity:** Major
- **Affected Scope:** Risks & Mitigations, first row "A worker sends the Cursor token …" (line ~472).
- **Style Rationale:** The mitigation cell asserts "nothing else readable is secret." The run home also holds `cli-config.json` and `~\.gitconfig` (copied in per "Cursor login and git config"), and the read list may open per-user toolchain folders. Whether any of those are "secret" is a judgment the sentence asserts without naming what is readable. A reader cannot verify "nothing else" without enumerating the readable set.
- **Recommended action (CALIBRATE):** Name the readable set and drop the blanket word, e.g. "The token is deleted after each run; the other files copied into the run home (`cli-config.json`, `~\.gitconfig`) and any read-list paths are not credentials."

### Finding S4 — "Why it suits this design" reads as soft sell
- **Severity:** Nit
- **Affected Scope:** "Host services", second bullet (line ~221).
- **Style Rationale:** "Why it suits this design" is mildly promotional phrasing for what is a factual consequence (permanent containers ⇒ one exemption per slot). The rest of the section is dry.
- **Recommended action (CALIBRATE / light edit):** "Because containers are permanent per slot, an exemption is a one-time step per slot, not per run."

### Finding S5 — Redundant qualifier in the crash-recovery risk row
- **Severity:** Nit
- **Affected Scope:** Risks & Mitigations, row "A crash or restart leaves grants, letters or locks behind" (line ~476).
- **Style Rationale:** The "What remains" cell ends "They give access only to that container's processes, and none are running." The clause "and none are running" repeats the subject of the prior clause ("that container's processes") and adds no information — if no process of that container is running, "none are running" is the same statement.
- **Recommended action (CALIBRATE / trim):** "They give access only to that container's processes, and none are." Or drop the tail clause.

### Finding S6 — "still works outside the container" is an untested-benefit hedge
- **Severity:** Nit
- **Affected Scope:** "The patched `node.exe`", closing sentence (line ~234).
- **Style Rationale:** "The probe showed that the patch fixes the hang and that the patched `node.exe` still works outside the container." The second half is a reassuring aside that the design does not actually rely on (the patched copy is only launched inside the container). It reads as a defensive caveat with no operator decision attached.
- **Recommended action (KEEP or DROP):** If the probe did run it outside and the fact matters for reuse, KEEP but cite the probe step; otherwise DROP the second clause as a reassurance with no design consequence.

### Finding S7 — "None known" used as a residual without a reader action
- **Severity:** Nit
- **Affected Scope:** Risks & Mitigations, rows for the patched `node.exe` and "Two runs read each other's work" (lines ~474, 478).
- **Style Rationale:** Two "What remains" cells are just "None known." As a residual it is fine, but it is bare; a reader cannot tell whether "none known" means "verified absent" or "not investigated." The crash-recovery row next to them does better by naming the concrete residual.
- **Recommended action (CALIBRATE):** For the patch row, "None known; source and patched hashes are kept in `patch.json` for audit." For the two-runs row, "None known; the slot ledger removes a crashed run's grants before the next run starts." (Both restate the mitigation's evidence rather than asserting absence.)

## Summary

Round-1 style findings are resolved in the document; none is repeated. Seven new findings, all in the new content: two **Major** (S1 crash-recovery overstatement, S3 "nothing else readable is secret"), and five **Nit** (S2 "proven", S4 soft-sell heading, S5 redundant tail clause, S6 untested-benefit hedge, S7 bare "None known"). No Blockers. The new sections are otherwise dry and factual; the audit vectors for hyperbole, jargon, filler and subjective quality judgments turn up nothing beyond the items above.
