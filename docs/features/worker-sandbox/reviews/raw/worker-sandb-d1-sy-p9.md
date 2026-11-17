<!-- persona: style | agent: cursor | model: glm-5.2-high -->
I have read the full target scope (lines 333–542) and surrounding context. Here is my Style Goldfish review.

---

# Style Goldfish Review — `docs/designs/worker-sandbox.md`, lines 333–542 (Detailed Implementation Plan)

Mode: REVIEW. The section is unusually clean for an implementation plan: imperative, concrete, and almost entirely free of marketing fluff and subjective praise. Findings below are limited to genuine style defects. No Blockers.

---

## Finding 1 — Absolute "always" on unverified new code

* **Severity:** Nit
* **Affected Scope:** Line 409 (`Invoke-SandboxCanary`)
* **Style Rationale:** "It returns `{ok, results[]}` and **always** cleans up, as the probe did." The probe's cleanup is evidence; the new function's cleanup is not yet verified — it is a requirement. "Always" presents a requirement as a verified property. Recommended action: `CALIBRATE` — narrow to the evidence: "It returns `{ok, results[]}` and cleans up (the probe did; the new code must)."

---

## Finding 2 — "guardrail" figurative phrasing

* **Severity:** Nit
* **Affected Scope:** Line 429 (`Help comment`)
* **Style Rationale:** "add the sandbox **guardrail** and the new layout lines." "Guardrail" is figurative for a help-comment edit; the help comment documents behavior, it does not enforce it. Prefer the concrete: "add the sandbox behavior and the new layout lines."

---

## Finding 3 — "no canary text appears anywhere"

* **Severity:** Nit
* **Affected Scope:** Line 535 (Verification Plan, Canary pass criterion)
* **Style Rationale:** "no canary text appears **anywhere**" — "anywhere" is unbounded. The same line already bounds the scope elsewhere ("logs or branch" at line 21 / G1). Recommended action: `CALIBRATE` — replace "anywhere" with the concrete surfaces: "no canary text appears in the logs, summary, or branch."

---

## Finding 4 — "skip what cannot run nested"

* **Severity:** Nit
* **Affected Scope:** Line 362 (`IsAppContainer()`)
* **Style Rationale:** "Tests use it to skip what cannot run nested." "Nested" is informal shorthand for "inside an already-sandboxed process." A fresh reader must infer it. Prefer: "Tests use it to skip tests that cannot run inside an already-sandboxed process."

---

## Finding 5 — "the one before" imprecision

* **Severity:** Nit
* **Affected Scope:** Line 379 (`Get-SandboxRuntime`)
* **Style Rationale:** "It deletes cache versions other than this one and **the one before**." "The one before" is ambiguous between the immediately previous Cursor version and the previous run. The Non-Functional Requirements (line 312) state this precisely as "the current and previous version." Reuse that phrasing: "other than the current and previous Cursor version."

---

## Finding 6 — "next to the repo's parent"

* **Severity:** Nit
* **Affected Scope:** Line 407 (`Invoke-SandboxCanary`)
* **Style Rationale:** "plants canaries in `%USERPROFILE%` and **next to the repo's parent**." "Next to" is spatially vague — it could mean inside or adjacent. State the path: "and in the repo's parent directory."

---

## Finding 7 — "218 existing ones" is an unverified count

* **Severity:** Nit
* **Affected Scope:** Line 533 (Verification Plan, Unit and container tests)
* **Style Rationale:** "All tests pass: the **218 existing ones** and the new ones." The number is a specific claim about the current suite. If the count drifts before the run, the pass criterion reads as failed when it is not. Recommended action: `CALIBRATE` — "All tests pass: the existing suite plus the new ones," or tie the number to a recorded baseline in `test-plan.md`.

---

## Items reviewed and kept (not findings)

Per the `KEEP` classification, the following were checked and are backed by concrete evidence or are explicit pass criteria, so they are not reported as defects:

- Line 364: "The code takes its signatures from the probe's `AC` class, which ran on this machine." — evidence-backed (probe ran 2026-11-13, line 89).
- Line 437: "This makes the suite runnable inside the sandbox, where `taskkill.exe` hangs." — backed by the probe finding cited at line 184 and Open Questions (line 43).
- Line 470: "Pester's test registry writes under `HKCU\Software\Pester`, which an AppContainer cannot write." — concrete technical constraint.
- Line 541: "No build run fails because of unfinished sandbox code." — read as a pass criterion under Verification Plan, not a claim of verified behavior.
- Line 539: Overhead target "5 s or less extra (median)" — measurable target, not a capability claim.
- Line 487: The quoted worker sentence ("You run in a sandbox…") — direct instructional voice, appropriate for a task template.

---

## Summary

The Detailed Implementation Plan is tight and well-calibrated. No Blockers, no Majors. Seven Nits, all in two categories: a few absolute/figurative words ("always", "guardrail", "anywhere", "nested") that slightly outrun their evidence, and a few spatial/numeric imprecisions ("the one before", "next to the repo's parent", "218") that a fresh reader would have to resolve. None obscure the plan's meaning; all are one-phrase fixes. No hyperbole, marketing fluff, jargon-as-buzzword, synonym redundancy, or subjective quality judgments were found in the target scope.
