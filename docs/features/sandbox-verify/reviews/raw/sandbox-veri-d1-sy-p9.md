<!-- persona: style | agent: cursor | model: glm-5.2-high -->
I have enough context to write the review. Let me deliver the report now.

---

# Style Goldfish Review: `docs/designs/sandbox-verify.md`

Mode: REVIEW. Findings below, ordered by severity. Each Defensive Caveat finding is tagged with the recommended editorial action.

## Blockers

None.

## Majors

**M1 — Subjective quality judgment.** Affected scope: Risks and Mitigations, row "`XAGENT_DELEGATE_SCRIPT` makes `verify` run a different script on the host."
The mitigation ends: "It is documented in the delegate skill as a test-only override." This is a factual claim about an existing fact, not a caveat with a reader decision, so it is fine — but the preceding clause "It gives no new power" is a capability claim that outruns the evidence in this document. The reasoning that follows ("whoever can set the lead's environment can already change `PATH` or `pwsh` itself") is the actual argument; the bare assertion adds nothing. Recommend `CALIBRATE`: drop "It gives no new power:" and keep the reasoning sentence, which is the verifiable part.

**M2 — Uncalibrated claim about existing behaviour.** Affected scope: Detailed Implementation Plan, Rules, "Which `delegate.ps1`."
"This repo's longest acceptance command so far (a `New-PesterConfiguration` one-liner in `sandbox-env`) is about 300." The "about 300" is presented as a measured fact with no date and no pointer to where the measurement was taken (no probe file, no test-plan row). The Problem section's measurement is dated 2026-11-19 and named as such; this one is not. Recommend `CALIBRATE`: either cite the file/line where the 300-character command lives, or restate it as "well under" the 10,000-character limit without a number, so the claim does not outrun its evidence.

**M3 — Uncalibrated claim about existing behaviour.** Affected scope: Risks and Mitigations, row "The test can read Cursor's login copy."
"`New-SandboxRun` copies `auth.json` and `cli-config.json` into every run's home, including plain `-SandboxRun` commands." This is a claim about current `Sandbox.psm1` behaviour stated as fact. The `worker-sandbox` design documents the copy for worker runs; whether plain `-SandboxRun` (no Cursor) also receives the login copy is not established by the Goldfish context supplied here, and the document offers no pointer. If a reader checks `New-SandboxRun` and finds it copies only for Cursor runs, the mitigation's "no new exposure" argument still holds but the premise is wrong. Recommend `CALIBRATE`: cite the function/file that does the copy for `-SandboxRun`, or narrow the claim to "worker runs already receive the copy; a sandboxed `verify` gets the same one."

## Nits

**N1 — Filler / wordiness.** Affected scope: The Problem, first bullet.
"The plan only fixes the command line." The referent of "the plan" is ambiguous on a first read (it could mean this design's plan, or the sandbox plan, or the worker's plan). From context it means "the current sandbox setup only restricts the command line, not the test files." Recommend `CALIBRATE`/rewrite: "The current sandbox only restricts the command line; the worker still chooses the test files and helper scripts."

**N2 — Synonym redundancy.** Affected scope: Decisions table, D1.
"Author's choice: one rule for both test steps, and no repo is left on the host by default." "one rule" and "no repo is left on the host by default" restate the same idea. The Why column already says it. Either clause alone carries the meaning. Drop one.

**N3 — Repeated filler phrase.** Affected scope: Decisions D1, D2, D3.
Each begins "Author's choice:". The table's Why column is the rationale; prefixing three rows with the same two words adds noise without signal. Drop the prefix, or replace with a single footnote that all three are author's choices.

**N4 — Wordiness.** Affected scope: Flow of a phase test.
"The decision line is the whole record of a host phase run, as `verify`'s decision line is for a task (where `test.where: host` is also stored)." The parenthetical repeats information already stated two sentences earlier ("logs `feature.ps1 decision -Kind decision -Text "host run: phase <n>, approved: <user's words>"`"). Trim to: "That decision line is the only record of a host phase run, like `verify`'s for a task."

**N5 — Slightly subjective framing.** Affected scope: Overview, first paragraph.
"every Cursor worker runs in a Windows AppContainer that can reach its worktree, the parts of `.git` it needs, its run home and a fixed read list, and nothing else on disk." "and nothing else on disk" is fine, but the sentence stacks five objects separated only by commas and one "and", which a fresh reader has to parse twice. Not a style fault, just dense; no action required, flagged for awareness.

**N6 — Defensive caveat, KEEP.** Affected scope: Risks, row "Slower checks: about 14% measured on this repo's feature tests (the time includes slot setup)."
The mitigation "Accepted; task tests are kept narrow by the size gate." names a concrete reader/operator decision (the size gate from `skills/feature/SKILL.md` is what bounds the cost) and the risk row carries a dated measurement. This is a calibrated, evidence-backed caveat. `KEEP` — reported only to show it was audited and not flagged.

**N7 — Defensive caveat, KEEP.** Affected scope: Risks, row "`verify` gets `sandbox-error` because both slots were busy for 60 s (`no free slot`)."
The mitigation names a concrete operator decision (wait for a live run to end, retry once, second failure is a problem stop) and ties to D5 and `Get-SandboxSlot`'s 60 s timeout. `KEEP`.

**N8 — Defensive caveat, KEEP.** Affected scope: Risks, row "`verify` kills a `delegate.ps1` that did not finish."
The mitigation names the concrete mechanism (`Get-LiveDelegateRunCount` checks pid liveness with start time; `Get-SandboxSlot`'s dead-process recovery) and matches the code in `feature.ps1` lines 1759–1781. `KEEP`.

**N9 — Minor imprecision.** Affected scope: Components, `delegate.ps1 -SandboxRun -Worktree` bullet.
"gains `tail`: the **last** 40 lines of stdout then stderr (`output` stays the first 40)." The Data section later says `tail` is "the last 40 lines of the run's `stdout.txt` followed by `stderr.txt`, each line cut at 400 characters." The Components bullet omits the 400-char cut. A reader comparing the two could wonder whether `tail` is capped. Recommend adding "(each line cut at 400 characters)" to the Components bullet for parity, or dropping the detail from Data and keeping it only in Rules.

**N10 — Minor imprecision.** Affected scope: Files table, `skills/delegate/scripts/Sandbox.psm1` row.
"`Invoke-SandboxCommand` also returns `tail` (a `-Last` reading of the same two files, beside `Get-SandboxCommandOutputLines`)." `Get-SandboxCommandOutputLines` (Sandbox.psm1 lines 2202–2226) reads the first 40 lines and cuts each at 400 chars; the new `tail` is described as "a `-Last` reading of the same two files" but does not say whether the 400-char cut also applies. The Data section says it does. Make the Files row explicit so the contract is in one place.

**N11 — Wordiness.** Affected scope: Detailed Implementation Plan, Rules, "Path comparison."
"Before any check, `delegate.ps1` normalizes it and every path it compares it with the way its worker-launch safety check does: `[IO.Path]::GetFullPath`, `/` replaced by `\`, trailing `\` trimmed, compared with `OrdinalIgnoreCase`." The phrase "and every path it compares it with" is grammatically tangled (double "it"). Rewrite: "Before any check, `delegate.ps1` normalizes `-Worktree` and every path it is compared against, the same way its worker-launch safety check does: …".

**N12 — Minor redundancy.** Affected scope: Detailed Implementation Plan, Rules, "Host runs."
"`verify -OnHost -Quote "<q>"` calls `Add-FeatureDecision -Kind decision -Text "host run: <task>, approved: <q>"` before anything else runs." and later "A phase test run on the host is logged by the lead with `feature.ps1 decision -Kind decision -Text "host run: phase <n>, approved: <q>"` before it runs in `<repo>`." The two sentences describe the same logging pattern for two callers; that is fine, but the second could just say "same pattern" to avoid restating the command shape.

**N13 — Defensive caveat, RELOCATE.** Affected scope: Detailed Implementation Plan, Rules, "Which `delegate.ps1`."
"If the chosen file does not exist, `verify` refuses before the scope check: `{ok: false, error: "delegate.ps1 not found: <path>"}`, exit 1. There is no fallback to the other path." The "no fallback" sentence is an operational caveat that belongs at the exact step where an operator chooses `XAGENT_DELEGATE_SCRIPT` (the test-only override). It is currently two sentences after the override is introduced. Recommend `RELOCATE`: move "There is no fallback to the other path" to the sentence that defines `XAGENT_DELEGATE_SCRIPT`, so the reader who sets the variable sees the consequence immediately.

**N14 — Minor calibration.** Affected scope: Verification, item 4.
"A phase test of a repo with Python projects (the lead's private Python repo used for `sandbox-env`'s live checks, or any repo with a `uv.lock`) still passes through `-SandboxRun`." "Still passes" is a claim about post-feature behaviour for an external repo. The Verification section is a sign-off checklist; this item reads as a future fact rather than a check to run. Recommend `CALIBRATE`: restate as a check ("run the phase test through `-SandboxRun` on a repo with `uv.lock`; pass when `status` is `ran` and `exitCode` is 0"), matching the form of items 1–3.

**N15 — Minor: uncalibrated scope claim.** Affected scope: Components, `stages/build.md` bullet.
"Reads `test.setup` before `test.passed`." and "Describes the host fallback (D2, D6)." These are directives, not claims, so they are fine. But the bullet also implicitly promises that `build.md` will be updated to "Run every phase test through `-SandboxRun` (D1)" — this is a future code/doc change stated as accomplished. The Files table row for `build.md` carries the same content with proper tense ("Verify step: … Phase end and 'merge main': always `-SandboxRun …`"). The Components bullet's phrasing is acceptable as a design statement; flagged only for consistency.

## Summary

The document is, on the whole, dry, factual, and well-calibrated: measurements are dated (Problem section, Risks row on 14% slowdown), rationales tie to concrete code (`Get-LiveDelegateRunCount`, `Get-SandboxSlot`, `Get-SandboxCommandOutputLines`), and most caveats name a concrete operator decision. No hyperbole, marketing fluff, or buzzwords were found. No synonym-redundancy clusters beyond N2/N3.

The three Major findings (M1–M3) are all the same shape: a capability claim about existing or measured behaviour stated without a pointer that a fresh reader can verify ("It gives no new power", "about 300", "copies `auth.json` … into every run's home"). Each is fixable by `CALIBRATE` — narrow the claim to the evidence the document already has, or cite the file/function/row that backs it. The Nits are local wordiness, a grammatical tangle (N11), and two places where the `tail` contract is stated in two spots with slightly different detail (N9, N10).

No Blockers. The document can ship after M1–M3 are calibrated; the Nits can be taken in the same pass.
