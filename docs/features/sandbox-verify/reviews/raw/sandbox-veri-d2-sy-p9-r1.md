<!-- persona: style | agent: cursor | model: glm-5.2-high -->
# Style Goldfish Review — `docs/designs/sandbox-verify.md`

Mode: REVIEW. Scope: lines 1–246. Persona: Technical Copy Editor (clarity, precision, brevity, objectivity; strip fluff, jargon, and uncalibrated claims).

The document is, on the whole, dry, factual, and well-calibrated. Claims are tied to measured numbers (the 228/229, 165/4, 604 s/531 s, 14% rows) and to concrete code paths I verified in `feature.ps1`, `delegate.ps1`, `Sandbox.psm1`, and `verify.schema.json`. The findings below are narrow editorial issues, not architectural ones.

---

## Findings

### 1. Nit — Subjective size judgment
**Affected Scope:** Detailed Implementation Plan → Rules → "`.venv` links and git." (line 210)

> "This is one **small** function in `delegate.ps1` (`Add-DelegateVenvExclude`)…"

**Style Rationale:** "Small" is a subjective quality judgment about code, with no reader decision attached. The function's size is irrelevant to the design; the reader only needs to know it exists and where it is called. Drop "small".

---

### 2. Nit — Subjective effect judgment
**Affected Scope:** Detailed Implementation Plan → Rules → "`.venv` links and git." (line 212)

> "Two runs racing can both append the line; a duplicate line in `exclude` is **harmless**."

**Style Rationale:** "Harmless" is an opinionated evaluation. The verifiable fact is that git ignores duplicate `exclude` lines. **CALIBRATE**: replace "is harmless" with "has no effect" or "is ignored by git".

---

### 3. Nit — Jargon
**Affected Scope:** Detailed Implementation Plan → Probes (line 154)

> "The `-SandboxRun` **machinery**, slot handling and environment links are from `sandbox-env` and unchanged."

**Style Rationale:** "machinery" is non-precise jargon for the code path. The rest of the document names modules and functions directly. **CALIBRATE**: "The `-SandboxRun` code path" or simply "The `-SandboxRun` implementation".

---

### 4. Nit — Mild hyperbole / redundancy with the Decision column
**Affected Scope:** Decisions table, D2 "Why" cell (line 50)

> "Author's choice: **the protection never lapses**."

**Style Rationale:** "the protection never lapses" is hyperbolic framing and restates the Decision column ("The approval is never remembered"). The concrete, verifiable property is the per-run approval itself. **CALIBRATE**: "Author's choice: a remembered approval would reopen the gap for later tasks." This ties the Why to the gap closed in the Problem section without restating the Decision.

---

### 5. Nit — Speculative hedge without a reachable operator decision
**Affected Scope:** The Problem → "Not every test can run in a container." (line 28)

> "Other repos may have tests that need the host for reasons the skills cannot predict."

**Style Rationale:** This is speculative hedging ("may", "cannot predict") with no concrete operator decision named at this point — the per-run approval decision (D2) is introduced later. As a standalone sentence it adds noise. **RELOCATE**: move this justification into the D2 Why cell (where the per-run approval decision lives), so the caveat sits at the exact step where the user makes a choice. Alternatively **CALIBRATE** to: "Other repos may have tests that need the host; D2 makes each such run ask the user." Either action ties the caveat to a decision.

---

### 6. Nit — Sentence fragment in the Verification intro
**Affected Scope:** Verification (line 238)

> "At sign-off, besides the full suite on the host. These are checks the lead runs on the host, not worker tasks:"

**Style Rationale:** "At sign-off, besides the full suite on the host." is a fragment that does not parse as a sentence. **CALIBRATE**: "At sign-off, the lead runs the full suite on the host, plus the checks below. These are lead-run checks, not worker tasks:"

---

### 7. Nit — Awkward compound numbering
**Affected Scope:** Verification, items 2 and 3 (line 242)

> "**2. and 3. are one `Live`-tagged test** in `feature.Tests.ps1`…"

**Style Rationale:** Collapsing two numbered items into one sentence beginning "2. and 3. are" is awkward and breaks the numbered-list contract the surrounding items 1 and 4 rely on. **CALIBRATE**: keep the list as 1, 2, 3, 4 and let item 2 describe the `Live` test and item 3 describe the Python-repo phase check, or drop the numbers and use bullets for the two `Live` checks.

---

## Items reviewed and found clean (no finding)

- **Hyperbole scan:** No "flawless", "revolutionary", "fully eliminates" or similar unprovable claims. "the protection never lapses" (Finding 4) is the only borderline case.
- **Buzzword scan:** "leverage", "synergistic", "seamless" etc. are absent.
- **Filler scan:** No "essentially", "simply", "it is important to note that". The prose is consistently direct.
- **Synonym redundancy scan:** No "quick and rapid", "clean and elegant" patterns. "narrow" (size gate) is tied to a defined gate, not a redundant adjective.
- **Claim calibration against code:**
  - `output` = first 40 lines, `tail` = last 40 lines, each line cut at 400 — matches `Get-SandboxCommandOutputLines` (Sandbox.psm1:2202–2226) and the proposed `tail` helper beside it.
  - `Invoke-SandboxCommand` deletes and recreates `runs\probe-<hex>\` — matches Sandbox.psm1:2300–2302.
  - `Get-LiveDelegateRunCount` counts `*.pid` under `.xagent\runs` with `pid`, `startTime`, `feature` — matches feature.ps1:1759–1781, so the "schedule needs no change" claim holds.
  - `Invoke-TaskTestCommand` uses `pwsh -NoProfile -NonInteractive -EncodedCommand <base64>` with the wrapper text described — matches feature.ps1:2610–2632, so the "one wrapper" refactor claim is consistent.
  - `verify.schema.json` currently requires `command`, `passed`, `exitCode`, `tail` — matches the "adds `where` and `setup`" claim.
- **Defensive caveats (DROP/CALIBRATE/RELOCATE/KEEP) beyond Finding 5:**
  - D6 "a wrong guess either hides a bug or runs code on the host without approval" — **KEEP**: names two concrete, reachable outcomes.
  - Risks row "XAGENT_DELEGATE_SCRIPT makes verify run a different script on the host" with "Whoever can set the lead's environment can already change PATH or pwsh itself" — **KEEP**: backed by the existing trust model documented in the delegate skill; concrete and verifiable.
  - Risks row ".venv/ in .git/info/exclude also hides the user's own untracked .venv folders" with "Accepted" — **KEEP**: concrete reader decision (the user can delete the line), and the mitigation is operational.
  - "Accepted" entries in the Risks table each name the decision (D1, D2) or the unchanged behaviour — **KEEP**.

---

## Summary

Seven Nits, no Blockers or Majors. The document is close to publishable as a professional engineering design. The fixes are: drop one subjective adjective ("small"), replace one subjective effect word ("harmless"), replace one jargon term ("machinery"), tighten one hyperbolic Why cell (D2), relocate or calibrate one speculative hedge (line 28), repair one sentence fragment (Verification intro), and fix one awkward compound list item (Verification 2/3). None of these change the design's claims or its verification evidence; they tighten the prose to the standard the rest of the document already meets.
