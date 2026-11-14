<!-- persona: structural | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer persona exactly.I'll audit the specification against the feature standard and check round-1 resolutions against the current document.Round 1 called out heading and template gaps. I'll compare the current spec's outline to that standard and to the first design's structure.## Structural review (round 2)

Scope is `docs/designs/worker-sandbox.md` lines 1–511, checked against the Feature Specification Standard and the design-document template (`skills/feature/egm/skills/egm-draft/references/design_doc.md`), with `docs/designs/feature-skill.md` as the locked spec that already has a Risks section.

The H1 is followed by H2s in template order: Overview, The Problem, Goals, Non-Goals, Open Questions, Critical User Journeys (CUJs), Technical Plan (Architecture), Alternatives Considered, Non-Functional Requirements, then Risks & Mitigations. CUJs 1–7 and Technical Plan subsections are H3s. No level is skipped. The five required areas are present and spelled as in the template or the standard. Alternatives A–Q each have Pros, Cons, and Reason for rejection, attributed to the author with a technical reason. Tables, the `text` diagram, and the JSON fence are closed and well-formed. Links resolve.

Round-1 structural items that hold: M30 (the Risks heading, the three alternative fields, and taskkill removed from Open Questions), N2 (issue and PR links; phantombot defined at first use), and the N5 rule immediately before Detailed Implementation Plan (line 510). Reserved letters, per-slot containers, the slot mutex, the slot ledger, per-run grants, the read list, and host services sit under Technical Plan without a heading-level skip. The Risks table uses the same three columns as the first design.

### 1. Severity: Major

**Affected scope:** `## Risks & Mitigations` (line 471) through `### Future Improvements` (lines 492–508).

**Discrepancy:** `### Additional Resources` and `### Future Improvements` are children of Risks & Mitigations. In the template those two blocks are the document tail after Non-Functional Requirements. In `feature-skill.md`, once Risks was added, Future Improvements was promoted to H2 and fenced with a horizontal rule so it is not a risk subsection. Here the rule that N5 required before Additional Resources was not added. The rule at line 469 stands before Risks, and the next rule is not until line 510, so the outline treats citations and future work as mitigations. Promote both tail sections to H2 and put a horizontal rule between the risks table and Additional Resources.

### 2. Severity: Nit

**Affected scope:** Between `### Alternative Q` (line 450) and `## Non-Functional Requirements` (line 456).

**Discrepancy:** The template and `feature-skill.md` both place a horizontal rule after Alternatives Considered and before Non-Functional Requirements. This spec goes from Alternative Q to Non-Functional Requirements with only a blank line. That group separator is still missing. The rule before the implementation plan is already present and should stay.

### 3. Severity: Nit

**Affected scope:** `## Open Questions`, third bullet (line 74).

**Discrepancy:** M30 kept only questions that are still open. Token refresh and per-run permission cost are still measurements, so they belong here. "Which host services MyApp needs" says it is settled when a later feature is designed. The same deferral is already a Non-Goal (line 68) and a Future Improvements bullet (line 505). It is not an open question in this spec.

### 4. Severity: Nit

**Affected scope:** Goals, G3 (line 42); Open Questions, token refresh (line 72); `### The patched node.exe` (line 236).

**Discrepancy:** Quoted section names do not match headings. Line 72 points at "Cursor login"; the heading is "Cursor login and git config" (line 258). Line 42 says "Risks and Mitigations"; the heading uses an ampersand (line 471). "Version choice" is only a bold run-in at line 236, while the implementation plan cites it as a section ("Version choice", lines 552 and 557). The other quoted targets in this range ("Host services", "Read list", "Reserved letters and slots") match H3s.
