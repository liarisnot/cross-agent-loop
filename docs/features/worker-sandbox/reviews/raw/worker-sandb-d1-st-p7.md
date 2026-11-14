<!-- persona: structural | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer persona exactly.The task is a structural review of the feature specification. I'll map its headings and formatting against the standard.The spec portion ends at line 332. I'll compare its heading tree and formatting with the standard and the first design's layout.Structural review of `docs/designs/worker-sandbox.md`, lines 1–332 (the feature specification, through Future Improvements). Compared with the Feature Specification Standard and the design-doc skeleton (`Overview` through `Future Improvements`).

## Heading map

- H1, line 1: `` `worker-sandbox`: confine `delegate`'s agents to their worktree ``
- H2 Overview (9), The Problem (15), Goals (24), Non-Goals (34), Open Questions (42)
- H2 Critical User Journeys (CUJs) (50)
  - H3 CUJ 1–5 (52, 58, 64, 70, 76)
- H2 Technical Plan (Architecture) (82)
  - H3 Decision (84), Components (93), What the sandbox can reach (114), Why drive letters (131), The patched `node.exe` (135), Launch and kill (141), Cursor login (151), Requirements check (`-SandboxCheck`) (155), Record of each run (G5) (159), Clean-up (163), Freezing `delegate` for this build (G6) (169), The two-part task template (G7) (175), Limits that stay (179)
- H2 Alternatives Considered (187)
  - H3 Alternative A–K (189, 203, 216, 223, 230, 240, 248, 259, 266, 275, 282)
- H2 Non-Functional Requirements (292)
  - H3 Security (294), Performance (305), Rollout and rollback (311), Additional Resources (316), Future Improvements (326)

Heading levels step H1 to H2 to H3 with no skipped level. Section order matches the design-doc skeleton through Future Improvements. The Problem, Goals, Non-Goals, architecture, and Alternatives Considered headings are present. Lists in this range use one `*` marker. The only fenced block (95–112) is closed. Both tables (116–127 and 296–303) have a header, a separator, and a consistent column count.

## Findings

**1. Severity: Major**
**Affected scope:** No `## Risks & Mitigations` heading. Related text is `### Limits that stay` (179–185), `### Security` (294–303), `### Performance` (305–309), and `### Rollout and rollback` (311–314).

The standard requires a Risks & Mitigations area that identifies failure modes, security implications, scalability limits, and the mitigation for each. This scope has no heading by that name. Security items sit in a two-column Risk | Handling table under Non-Functional Requirements. Operational constraints sit earlier, under Technical Plan, as "Limits that stay". Performance states time and memory targets and does not record scalability limits (concurrent runs, the drive-letter pool, cache growth) or what remains after mitigation. Residual risk is not gathered in one section.

**2. Severity: Major**
**Affected scope:** `## Alternatives Considered` (187–290), each `### Alternative A` through `### Alternative K` block.

The design-doc block is three labeled items: **Pros**, **Cons**, and **Reason for Rejection**, with the rejection written as `Rejected by author:` plus a technical or scope trade-off. These blocks use **For** and **Against**, and the rejection is a following paragraph outside the list. Alternatives F (240–246), J (275–280), and K (282–290) have no For item, so the eleven blocks do not share one shape. Each paragraph states a concrete trade-off and attributes the decision to the author, which matches the template's author-decision form. The field layout does not match the template.

**3. Severity: Major**
**Affected scope:** `## Open Questions` (42–48).

That section is for unresolved questions only. Answered questions are removed once resolved. All four bullets open with a closed status: isolation mechanism and toolchains are Resolved, Cursor login is Resolved for the probe, and speed is Partly resolved. The gaps that are still open ( `taskkill.exe` inside an AppContainer, token refresh against the user's own login, and the per-run cost of setting permissions) are clauses inside those resolved bullets. The heading does not list the open items on their own.

**4. Severity: Nit**
**Affected scope:** Lines 314–316, and the boundary at 332–334.

The design-doc places a horizontal rule before Additional Resources and another before Detailed Implementation Plan. This specification has the opening rule after the metadata (line 7) only. Rollout and rollback runs directly into `### Additional Resources`, and Future Improvements runs directly into `## Detailed Implementation Plan`.

**5. Severity: Nit**
**Affected scope:** Line 13 (`docs/HANDOFF.md`); line 137 and lines 321–324 (libuv/libuv#5178, nodejs/node#66374, seshat-runtime PR #816, phantombot PR #787, openclaw PR #161128); line 272 (phantombot, inside Alternative I); lines 318–319 (`docs/designs/feature-skill.md` and the probe directory).

These citations are path or PR text. None is a markdown link. Alternative I's against-bullet uses phantombot's move as evidence, and the PR number appears only later, still as plain text. The `Rejected by author:` lines attribute the decision to the author together with a technical trade-off, so they do not need an issue link. The references a reader would follow are not links.
