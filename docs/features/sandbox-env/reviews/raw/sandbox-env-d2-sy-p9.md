<!-- persona: style | agent: cursor | model: glm-5.2-high -->
Let me check the referenced context files to verify claims against evidence# Style Goldfish Review — `docs/designs/sandbox-env.md` (lines 1–289)

Mode: REVIEW. Stage 9 (style). Persona: Technical Copy Editor (clarity, precision, brevity, objectivity).

The document is, on the whole, dry, factual, and well-calibrated. Most claims about tested behaviour cite a probe (P1–P5) or a fixture, and operational caveats are placed at the step where a user acts. Findings below are minor; none are blockers.

---

## Findings

### 1. Subjective superlative — "exactly where it matters most"
- **Severity:** Nit
- **Affected Scope:** "Alternatives Considered → Run such repos with `-NoSandbox`", line ~131 ("it drops the protection exactly where it matters most")
- **Style Rationale:** "exactly where it matters most" is an opinionated ranking of where protection matters, not a measurable property. The next sentence already supplies the concrete reason (the live database). Drop the ranking; the database justification carries the rejection on its own.
- **Suggested fix:** "Rejected: it drops the protection the repo most needs — the first repo that needs this holds a live database that experiments must never touch." → or simply "Rejected: it removes sandbox protection from a repo that holds a live database experiments must never touch."

### 2. Quantitative claim without evidence — "would save little"
- **Severity:** Nit
- **Affected Scope:** D1 rationale, line ~57 ("Sharing one root across repos would save little")
- **Style Rationale:** "Would save little" is a magnitude claim with no measurement behind it. The remainder of the sentence gives qualitative reasons (lockfiles differ, `uv` cache on another drive so packages copy anyway), which is the actual argument. Replace the bare magnitude assertion with the qualitative reason, or label it as an assumption consistent with the next clause.
- **Suggested fix:** "Sharing one root across repos saves nothing in practice: lockfiles differ between repos, and `uv`'s cache is on another drive, so packages are copied either way."

### 3. Unverifiable `uv` behaviour stated as fact
- **Severity:** Nit
- **Affected Scope:** "What a project is", line ~67 ("A `uv` workspace has one `uv.lock` at its root and one `.venv` there, so it is one project")
- **Style Rationale:** This is a claim about `uv`'s workspace behaviour. The task context notes `uv`'s docs cannot be opened from here, so the claim cannot be checked against the source. It is stated as flat fact. Calibrate to attribute it, or scope it to what the design relies on.
- **Suggested fix (CALIBRATE):** "The design treats a `uv` workspace as one project: it has one `uv.lock` at its root and one `.venv` there." — frames it as the design's modelling choice rather than a universal `uv` invariant.

### 4. Hedged caveat with no reachable operator decision
- **Severity:** Nit
- **Affected Scope:** Risks and Mitigations, "Tests need the GPU" row, line ~121 ("Not known to work in an AppContainer. The probe reports it; out of scope.")
- **Style Rationale:** This is the same content as the Open Question (line 47, "Whether an AppContainer can use the GPU at all is unverified") and the Non-Goal "GPU access". Stating it three times is redundant; the Open Question is the right home for an unverified capability, the Non-Goal is the right home for scope, and the Risks row adds no new operator decision.
- **Suggested action (RELOCATE/DROP):** Drop the Risks row, or collapse it to "See Open Questions: GPU." The Open Question already names the unverified capability; the Non-Goal already states the scope boundary.

### 5. Mild synonym redundancy — "plain words" / "in plain words"
- **Severity:** Nit
- **Affected Scope:** G2 heading and body, line ~33 ("Propose, with the cost, before changing anything" … "produces a proposal in plain words")
- **Style Rationale:** The heading already states the goal (propose, with cost, before changes). "In plain words" restates the form of the proposal rather than adding a requirement. The proposal's structure (what, where, disk, time) is specified in the same sentence, which is the operative content.
- **Suggested fix:** Drop "in plain words"; "produces a proposal: what will be created, where, and roughly how much disk and time."

### 6. Informal phrasing — "goes away with it"
- **Severity:** Nit
- **Affected Scope:** D1 rationale, line ~57 ("Everything for a repo sits beside its worktrees and goes away with it")
- **Style Rationale:** "Goes away with it" is conversational. The operative claim is co-location with the worktrees and co-lifecycle with the repo. The rest of the rationale already states this precisely.
- **Suggested fix:** "Everything for a repo sits beside its worktrees and is removed with them."

### 7. Informal phrasing — "sees little"
- **Severity:** Nit
- **Affected Scope:** "The Problem", closing paragraph, line ~27 ("the sandbox is safe because it sees little, and a repo's toolchain is usually installed where it can't see")
- **Style Rationale:** "Sees little" is a metaphor; the technical statement is that the sandbox's read surface is small. The next two sentences are precise. This is the only metaphorical line in an otherwise literal section.
- **Suggested fix:** "The sandbox is safe because its read surface is small, and a repo's toolchain is usually installed outside it."

### 8. Emphasis filler — "a single test"
- **Severity:** Nit
- **Affected Scope:** "The Problem", line ~25 ("So a sandboxed worker cannot run a single test of that repo.")
- **Style Rationale:** "A single test" is emphasis rather than a count; "any test" carries the same meaning without the rhetorical stress. Minor, but the rest of the section avoids this kind of emphasis.
- **Suggested fix:** "So a sandboxed worker cannot run any test of that repo."

---

## Items reviewed and kept (not findings)

For transparency on the caveat classification (`KEEP`):

- **D4, D6, D7** — every capability claim is followed by a probe reference (P1, P2, P3) with measured numbers. KEEP.
- **Open Question: GPU** (line 47) — appropriately hedged as "unverified"; names the unanswered question. KEEP.
- **Non-Goal: GPU access** — scope statement, not a capability claim. KEEP.
- **P1, P2, P3, P5** results — concrete numbers (4,843 files; 4.77 GB / 29,568 files / 13 s; grant 2.7 s / removal 2.8 s), and P3 explicitly reports "Fails as built" with the fix that passes. KEEP.
- **D3** "versions may differ slightly" — hedged to the resolve path, which is the only place it applies. KEEP.
- **Estimate** rule (line ~245) — labels both disk and time as estimates and fixes the factors in tests. KEEP.
- **`uv-missing` / `python-version-unknown`** — named failure modes with operator-facing messages. KEEP.

---

## Summary

No blockers, no major issues. Eight nits, all in the same family: a small number of informal/metaphorical phrases ("sees little", "goes away with it", "a single test", "in plain words"), one unattributed `uv` behaviour claim, one quantitative assertion without evidence ("would save little"), one subjective superlative ("exactly where it matters most"), and one redundant risk row that duplicates an Open Question and a Non-Goal. None change the technical content; each is a localised editorial fix.
