<!-- persona: style | agent: cursor | model: glm-5.2-high -->
I have read the target scope (lines 512–761), the round-1 review, and the resolution. Below is my Style Goldfish re-audit report.

---

# Style Goldfish Review Report — design round 2 (re-audit)

**Target:** `docs/designs/worker-sandbox.md`, lines 512–761 (Detailed Implementation Plan).
**Mode:** REVIEW (Stage 9, style).
**Scope of this round:** new content since round 1 — reserved drive letters and per-slot containers, the slot mutex and slot ledger, per-run grants, the read list, host services, and the Risks & Mitigations section — plus verifying that round-1 style findings the resolution said it would fix are actually fixed.

## Verification of round-1 style findings

Round 1 raised 7 style findings on the plan (style p9 #1–#7) and a number of Nits (N6–N21). The resolution said all of N1–N21 would be applied and listed the one-phrase fixes. Spot checks against the target scope and the surrounding sections:

- **N17** ("cleans up in `finally`") — fixed at line 575: *"Clean-up runs in `finally`"*.
- **N18** ("sandbox behavior" not "guardrail") — fixed at line 599: *"Help comment: describe the sandbox…"*.
- **N19** ("in the logs, summary or branch" not "anywhere") — fixed at line 635: *"no canary text is in the logs, summary or branch"*.
- **N20** ("inside an already-sandboxed process" not "nested") — fixed at line 636: *"skipped when `IsAppContainer()` is true"*.
- **N10** ("218 test cases as of 2026-11-12") — fixed at line 751: *"the existing suite (218 test cases as of 2026-11-12)"*.
- **N13** (`RunHandle` public fields, `ExitCode` closes handles) — fixed at lines 529 and 539.
- **N14** (third `taskkill` is `Invoke-DoctorCommand`) — fixed at line 606: *"the `Invoke-DoctorCommand` timeout (~2556)"*.
- **N15** (`AC` supplies only Win32 imports) — fixed at line 525: *"The probe's `AC` class… supplies the Win32 imports and the basic `CreateProcessW` call. Everything else here is new."*
- **N16** ("revise item 5 in place" not "add") — fixed at line 737: *"revise Next item 5 in place"*.
- **M4** (`-MinimumVersion 5.5`) — fixed at line 659.
- **M18** (one summary shape) — fixed at line 597: `{container, slot, runtimeLetter, runtimeVersion, patched}` matches the Technical Plan.
- **M19** (timeout fields) — fixed at line 592: `timedOut = $true`, `exitCode = -1`.

No round-1 style finding that the resolution marked "apply" appears unfixed in the target scope. I do not re-report those.

## New findings (round 2)

### S1 — Major — File 2, `Get-SandboxRuntime` "Skip the patch" (line 560)

> **Skip the patch:** if `& $UvProbe <copy>\node.exe` is 1.53 or later, write `patch.json` `{patched:false, uv}`.

The phrase "Skip the patch" is fine, but the sentence conflates the probe call with the version comparison. "is 1.53 or later" reads as if the scriptblock returns a comparable value directly; the Technical Plan (line 232) specifies the comparison as `[version]` after removing a `-suffix`. The plan drops that detail here, so a reader implementing from this section alone could compare strings. **Style rationale:** the calibration rule is stated upstream and omitted at the step that performs it; an implementer following the plan top-to-bottom hits an under-specified comparison. **Recommended action:** CALIBRATE — add "(compared as `[version]` after removing any `-suffix`, per 'The patched `node.exe`')" to this line.

### S2 — Major — File 2, `Get-SandboxSlot` (line 569)

> It retries every 2 s until the timeout, then throws `sandbox: no free slot (both slots busy)`.

"Retries every 2 s until the timeout" is ambiguous about whether the retry loop is inside `Get-SandboxSlot` or its caller. The signature is `Get-SandboxSlot -TimeoutSec 60`, which implies the loop is inside, but the next sentence ("If the slot has a ledger, it calls `Remove-SandboxGrants`…") is ordered as if it happens after the retry loop succeeds. **Style rationale:** the temporal order of "retry loop → take slot → clean ledger" is not explicit; a reader could implement the ledger cleanup before the retry loop. **Recommended action:** CALIBRATE — split into "On a free slot it stops retrying; if that slot has a ledger, it calls `Remove-SandboxGrants`… and deletes it. If both slots stay held for `-TimeoutSec`, it throws…"

### S3 — Major — File 2, `New-SandboxRun` "Run home" (line 571)

> Copy `cli-config.json`, `auth.json` and `~\.gitconfig` (if present, with the read-only attribute set).

The "(if present, with the read-only attribute set)" parenthetical attaches ambiguously: it reads as if all three files are optional and all get the read-only attribute. The Technical Plan (line 260) says `cli-config.json` and `auth.json` are always copied, and only `~\.gitconfig` is conditional and read-only. **Style rationale:** a misplaced qualifier creates an incorrect implementation contract. **Recommended action:** CALIBRATE — "Copy `cli-config.json` and `auth.json`; copy `~\.gitconfig` if present, with the read-only attribute set."

### S4 — Major — File 5, container tests, "A read-only run" (line 632)

> A read-only run cannot write its worktree but can write its run home (G2).

"Cannot write its worktree" contradicts the access table (line 186), which grants the worker worktree "read + write" even for read-only runs — the read-only enforcement is done by `delegate.ps1`'s `git status` check, not by revoking write. The Technical Plan (G2, line 38) and M7's fix say read-only runs "cannot change git-tracked files; can write only their run home under `.xagent/`". **Style rationale:** the test description states the mechanism as a file-system denial, which is both inaccurate and contradicts the design's own access table; an implementer could write a test that asserts the wrong expectation. **Recommended action:** CALIBRATE — "A read-only run can write its run home but `git status --porcelain --untracked-files=no` finds no tracked-file changes (G2)."

### S5 — Major — File 6, "A cache whose pattern bytes are zeroed" (line 648)

> A cache whose pattern bytes are zeroed gives the named patch error under the same conditions.

"Under the same conditions" is a dangling referent: the prior bullet (`XAGENT_SANDBOX_FORCE_FAIL=1`) lists four conditions (exit 1, `error` starting with `sandbox:`, no agent process, no `runs.jsonl` line). It is not clear whether "same conditions" means all four, or just "exit 1 and no `runs.jsonl` line". The M25 fix in the resolution specified both checks produce "exit 1 with no agent started and no `runs.jsonl` line", which is a narrower set. **Style rationale:** vague anaphora leaves the test's acceptance criteria ambiguous. **Recommended action:** CALIBRATE — spell out: "gives exit 1, an `error` starting with `sandbox: Cursor <version>: node.exe pipe-name pattern found 0 times`, no agent process, and no `runs.jsonl` line."

### S6 — Nit — File 3, "agy" (line 598)

> `agy`: unchanged (still disabled). If ever enabled, it runs only with `-NoSandbox`.

"Still disabled" is conversational filler; the parenthetical adds nothing the sentence doesn't already convey. **Style rationale:** redundancy. **Recommended action:** drop "(still disabled)" → "`agy` is unchanged. If ever enabled, it runs only with `-NoSandbox`."

### S7 — Nit — File 5, "A third run fails" (line 634)

> A third run fails with "no free slot" after its timeout, shortened to 4 s by a parameter.

"Shortened to 4 s by a parameter" is awkward word order and leaves the parameter unnamed. The signature above (`Get-SandboxSlot -TimeoutSec 60`) names it. **Style rationale:** the test names a value but not the parameter that takes it, forcing the implementer to back-reference. **Recommended action:** "A third run fails with `sandbox: no free slot (both slots busy)` after `-TimeoutSec 4`."

### S8 — Nit — File 9, "the same `sandbox:` exception" (line 683)

> the same `sandbox:` exception, next to "retry once" in three places

"The same" presumes the reader carries File 8's wording. A worker implementing File 9 in isolation sees "the same" with no antecedent in this file. **Style rationale:** dangling anaphora across files. **Recommended action:** repeat the one-line rule: "an `error` starting with `sandbox:` is not retried and is reported to the user".

### S9 — Nit — File 13, "as a post-lock amendment" (line 715)

> **Type / Scope:** the first design, as a post-lock amendment.

"as a post-lock amendment" restates the section's intent without adding information; the Proposed Changes bullets that follow already describe an amendment. **Style rationale:** filler. **Recommended action:** "the first design" — or, if the amendment status matters, "the first design; this entry is a post-lock amendment".

### S10 — Nit — Build order table, "Done by" column (lines 741–747)

> | 5 | Files 8–10 and 12–15; the live canary, in-sandbox suite run, regression, overhead and token-refresh checks | the lead, with one `code` worker task for files 8–10 and 12 | 4 |

The cell "the lead, with one `code` worker task for files 8–10 and 12" is fine, but phases 1–4 use the bare profile names "worker, `code` profile", "worker, `code-hard` profile", etc. M29's resolution said "lead" in the build table becomes "done by the lead (no worker)". Phase 5 says "the lead, with one `code` worker task", which is consistent, but phases 1–4 still say "worker, `code` profile" without naming that the worker is a `delegate` run. **Style rationale:** the column header "Done by" is consistent, but the cell format drifts between "worker, <profile>" (phases 1–4) and "the lead, with one `code` worker task" (phase 5). Minor inconsistency, not a calibration issue. **Recommended action:** Nit only — leave as is, or align phase 5 to "the lead (no worker) + one `code` worker task" for parallelism with phase 2's "worker, `code-hard` profile".

### S11 — Nit — Verification Plan, "the suite inside the sandbox (CUJ 2)" (line 752)

> after phase 4, the lead runs one sandboxed worker from `D:\cross-agent-loop\skills\delegate` (the live copy) on a small task in this repo.

"(the live copy)" is a parenthetical aside that explains the path but interrupts the sentence. The G6 mechanism (frozen junction) already establishes that the live copy is distinct from the frozen one. **Style rationale:** the aside is informational filler inside an instruction. **Recommended action:** "the lead runs one sandboxed worker from the live `D:\cross-agent-loop\skills\delegate` on a small task in this repo."

### S12 — Nit — Verification Plan, "Crash recovery (CUJ 6)" (line 757)

> Also: remove the mappings with `subst /D` by hand, and the next run maps them again.

"By hand" is conversational; the operator is the lead, and "by hand" adds no information beyond "remove the mappings with `subst /D`". **Style rationale:** filler. **Recommended action:** "Also: remove the mappings with `subst /D`; the next run maps them again."

### S13 — Nit — Verification Plan, "Token refresh" (line 759)

> after 3 sandboxed runs over at least one day, `cursor-agent status` outside the sandbox still shows the user logged in. If not, merge is blocked until the read-only token is added (see "Cursor login").

"Still shows the user logged in" is fine, but "If not" is a sentence fragment that follows a long condition. The decision rule is correct (matches D8c and line 264), but the conditional clause is hard to parse. **Style rationale:** readability, not calibration. **Recommended action:** "If `cursor-agent status` shows the user logged out, merge is blocked until the run home's `auth.json` is made read-only (see 'Cursor login')."

## Defensive-caveat classification (per the audit vector)

- **S1, S2, S3, S4, S5** — CALIBRATE. Each names a concrete reader decision (the implementer writing the function or test), and the fix narrows an existing claim to its verified scope rather than dropping it.
- **S6, S7, S8, S9, S11, S12** — DROP. They are filler or dangling anaphora with no reader decision behind them.
- **S10** — KEEP. The build-order cells are factual and backed by the G6/G7 mechanism; the inconsistency is cosmetic and not worth a finding on its own. Reported as a Nit for awareness only.
- **S13** — KEEP the rule, CALIBRATE the wording (the rule itself is evidence-backed by D8c).

## Items I deliberately did not flag

- The Risks & Mitigations table (lines 472–490) sits outside the 512–761 target scope. From a style standpoint it is dry, factual and free of hyperbole; the "What remains" column is appropriately calibrated (each cell names a concrete operator consequence: "Revoke it in Cursor", "The user picks new letters", "The target repo changes its scripts"). No new style finding there.
- "Host services" (lines 213–221) is outside the target scope and reads cleanly; "Not granted by this feature" is direct and not a hedge.
- The read-list spec (lines 199–211) is outside the target scope and is precise; no fluff.
- Per-slot containers and the slot ledger (lines 152–156, 180) are outside the target scope and are stated factually.
- The phrase "Everything else here is new" (line 525) is borderline filler but carries signal (it distinguishes the new code from the borrowed `AC` class), so I did not flag it.

## Summary

13 findings: 0 Blockers, 5 Major (S1–S5, all CALIBRATE), 8 Nit (S6–S13). Round-1 style findings the resolution said it would fix are present in the document. The new content is largely dry and direct; the remaining issues are calibration gaps where a step in the plan under-specifies a comparison, an order, or a test's acceptance criteria relative to the Technical Plan above it, plus a handful of filler phrases. No hyperbole, marketing fluff, jargon, subjective quality judgments, or synonym redundancy were found in the target scope.
