<!-- persona: structural | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer instructions.The task is a structural review of the design document. I'll read it and the related context so the layout audit is grounded in the standard.The spec lists required areas by name. I'll compare this document's heading tree and formatting against that list and the other design docs.A prior structural review used a design-doc template as the heading blueprint. I'll read that template and check this spec's outline against it.Structural review of `docs/designs/sandbox-verify.md` (lines 1–235) against the Feature Specification Standard.

## Heading map

One H1 (line 1). H2s, in order: Overview (9), The Problem (17), Goals (25), Non-Goals (32), Open Questions (39), Technical Plan (43), Alternatives Considered (104), Detailed Implementation Plan (142). H3s under Technical Plan: Terms from the existing skills (45), Decisions (52), Components (63), Flow of a task check (71), Risks and Mitigations (93). Five H3s under Alternatives Considered (106, 114, 120, 128, 136). H3s under Detailed Implementation Plan: Probes (144), Data (148), Rules (175), Files (200), Phases (217), Verification (226). Levels step H1 → H2 → H3 with no skip.

The Decisions, Risks, Files, and Phases tables each have a header, a separator, and a stable column count. The two `text` fences (73–89 and 180–184) are closed. Lists use `*`. The file has no Markdown links.

## Findings

**1. Severity:** Major  
**Affected scope:** `### Risks and Mitigations` (lines 93–102), before `## Alternatives Considered` (line 104).  
**Discrepancy:** Risks & Mitigations is a main section in the standard, alongside the architecture and the alternatives. Here it is the last H3 inside Technical Plan, so the H2 outline has no risks section, and the table sits before Alternatives Considered. The standard lists that area after alternatives. The table itself does gather the required kinds of constraint: slower checks and the two-slot wait (scale), tests that need the host and the delegate-test phase failure (failure modes), the Cursor login copy (security), and worktree writes, each with a mitigation or an explicit acceptance.

**2. Severity:** Major  
**Affected scope:** `## Alternatives Considered`, Reason for rejection lines 118, 126, 134, and 140.  
**Discrepancy:** Each option has Pros, Cons, and a Reason for rejection, and the Cons state concrete trade-offs. The reason line is the rationale slot. Line 112 states one: the existing worktree tests exactly what the worker left, with no extra commit. The other four do not. Lines 118, 134, and 140 say only “Rejected by author” plus D2, D6, or D1. Line 126 adds that the option collapses into “Remember a host approval”, which is shorter than the H3 it points at (`Remember a host approval for the feature or the repo`, line 114). The standard requires the rejection rationale to state a technical or scope trade-off, and it forbids attributing a rejection to a maintainer with no link to their issue, discussion, or PR. These four lines use the author as the reason and link no issue, discussion, or PR.

**3. Severity:** Major  
**Affected scope:** `### Flow of a task check` (line 71) and the paragraph at line 91.  
**Discrepancy:** The fenced diagram (lines 73–89) is the task `verify` path. Line 91 is a second procedure: the phase test on `feature/<name>`, including the host fallback, the decision line, and the fact that a phase has no `verify` record. That procedure has no heading. The H3 name covers only the task check, so the outline omits the phase-test flow.

**4. Severity:** Nit  
**Affected scope:** `## The Problem` (line 17), `## Goals` (line 25), `## Non-Goals` (line 32), `### Components` (line 63) and `### Flow of a task check` (line 71), `### Risks and Mitigations` (line 93).  
**Discrepancy:** The standard’s area names are Problem Statement, Goals & Non-Goals, Proposed Architecture, and Risks & Mitigations. The problem is under The Problem. Goals and non-goals are two sibling H2s. Component layout and the task data flow are under Components and Flow of a task check, with no Proposed Architecture heading. The risks heading uses “and” where the standard uses “&”. The material for each area is in the file. `## Alternatives Considered` (line 104) matches the standard’s name.

**5. Severity:** Nit  
**Affected scope:** `## Open Questions` (line 41).  
**Discrepancy:** The section says there are no open questions, then cites Q1 and Q2 as decided on 2026-11-19 and points at D1 and D2. This document has no Q1 or Q2 heading, list, or anchor. D1 and D2 are rows in the Decisions table (lines 56–57). The question ids do not resolve.

**6. Severity:** Nit  
**Affected scope:** Lines 11, 47–50, 56, and 146.  
**Discrepancy:** The standard states no link-text pattern, and there is no broken Markdown link because there are no Markdown links. Cross-references are bare text: `docs/designs/worker-sandbox.md` and `docs/designs/sandbox-env.md` (line 11), `docs/designs/sandbox-env.md` again (line 47), `skills/feature/SKILL.md` (line 48), `skills/feature/stages/build.md` (line 49), `skills/delegate/SKILL.md` (line 50), and “the Problem section” (lines 56 and 146). They do not resolve as links.
