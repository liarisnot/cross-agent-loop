<!-- persona: structural | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer instructions exactly.The task is a structural review of the design doc. I'll map its headings and formatting against the feature-spec standard.Structural review of `docs/designs/sandbox-env.md` (lines 1–273) against the Feature Specification Standard.

## Structure

One H1 (line 1). Eight H2s, in order: Overview (9), The Problem (17), Goals (29), Non-Goals (39), Open Questions (48), Technical Plan (54), Alternatives Considered (111), Detailed Implementation Plan (156). H3s sit only under those last three H2s. No H4. Heading levels are not skipped.

Tables at lines 57, 162, and 244 have a header, a `|---|---|---|` separator, and three cells per row. Fenced blocks at lines 77, 98, 173, and 197 are opened and closed. Lists use `*` throughout. There are no Markdown links in the file.

## Findings

**1. Severity:** Blocker  
**Affected scope:** Whole document (lines 1–273). Related clauses sit in Goals (G7, line 37), Non-Goals (39–46), Open Questions (48–52), and Rules (234–240).  
**Discrepancy:** The standard requires a Risks & Mitigations section, and under Risks & Limits it requires failure modes, security implications, scalability limits, and mitigations to be called out as constraints. No heading names that section, and no other section collects those four. Security limits (profile and `AppData\Roaming` refusals, no secrets, per-run grants, read-only environments), scale limits (no disk cap, the 5 GB re-approval, prune after 14 days, grant cost on a multi-gigabyte tree), and failure behavior (`install-failed`, a junction left behind on worktree removal, diagnosis `other`, missing `uv`, GPU unverified) are scattered through goals, non-goals, a settled-questions paragraph, probes, and rules. A reader cannot find one place that states the constraints and how each is mitigated.

**2. Severity:** Major  
**Affected scope:** `## Alternatives Considered` (lines 111–154).  
**Discrepancy:** The section exists and most rejections state a concrete trade-off, so this is not a single-path spec. The Alternatives Rule also says a rejection must not be attributed to a maintainer unless the rationale links their issue, discussion, or PR. Nine options are marked “Rejected by author” (lines 115, 130, 131, 135, 140, 141, 145, 146, 153). Two more are “Rejected after review” (lines 139 and 150). None of these link an issue, discussion, or PR. Line 150 cites probe P2, which is an in-document check, not that link. The grant-in-place option (line 119) is the one rejection in this section that is not phrased as a person’s decision.

**3. Severity:** Major  
**Affected scope:** `### What a project is` (lines 69–73) and `### Rules` (lines 222–225), under `## Technical Plan` and `## Detailed Implementation Plan`.  
**Discrepancy:** There is no `Proposed Architecture` heading. Component layout and data flow are partly under `### Components` and `### Flow on first use`, while the normative rules are restated later under `### Rules`. Those two passages both define what a project is and how its interpreter is chosen, and they disagree. Line 71 discovers projects with `git ls-files`. Line 224 uses `git -C <repo> ls-tree -r --name-only <ref>`. Line 73 takes the newest patch of the chosen minor version. Line 225 takes the lowest version `requires-python` allows that `uv python list` offers. Neither block is marked as the one that wins. The architecture the standard asks for is split across two H2s and, for these rules, has two peer texts.

**4. Severity:** Nit  
**Affected scope:** `## The Problem` (line 17), `## Goals` (line 29), `## Non-Goals` (line 39).  
**Discrepancy:** The standard’s area labels are Problem Statement and Goals & Non-Goals. The problem is under `## The Problem`. Goals and non-goals are two sibling H2s rather than one `## Goals & Non-Goals`. The material is present and the levels are sequential; the headings do not use the standard’s names. `Proposed Architecture` is the related gap in finding 3, not a second copy of this label mismatch.

**5. Severity:** Nit  
**Affected scope:** `### Probes` (lines 158–167).  
**Discrepancy:** The probe table is numbered P1, P2, P3, P5. P4 is only in the sentence above the table, as a path that was dropped before it ran. The series in the table is not contiguous, and the dropped check has no row.

**6. Severity:** Nit  
**Affected scope:** `## Open Questions` (lines 48–52).  
**Discrepancy:** The section has one open item (GPU, line 50), then a paragraph of decisions that are already settled (worktree import, disk, projects without a lockfile) and that points at Probes and the Decisions table. Settled decisions are stored in the open-questions section as well as in `### Decisions`.

**7. Severity:** Nit  
**Affected scope:** `## Alternatives Considered` (lines 111–154).  
**Discrepancy:** H3 granularity is not uniform. Some H3s are one rejected option (lines 113, 117, 124, 133, 148, 152). Others are a decision group whose options are bullets (lines 128, 137, 143). The section cannot be scanned as one list of rejected options.

**8. Severity:** Nit  
**Affected scope:** Line 11; line 52; line 167.  
**Discrepancy:** The file has no Markdown links, and the standard states no link-text pattern, so nothing fails a stated URL shape. The cross-references that are there are bare text: `docs/designs/worker-sandbox.md` (line 11), “see Probes” and “see the Decisions table” (line 52), and “see Rules” (line 167). They do not resolve as links.
