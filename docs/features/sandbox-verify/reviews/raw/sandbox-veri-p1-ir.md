<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll read the task file first.

 

 

 

## Implementation Readiness Review — `docs/features/sandbox-verify/plan.md` (all of it)

Scope audited: the plan's summary, both phase tables, and the four briefs (plan.md lines 1–35), read against the locked design `docs/designs/sandbox-verify.md` and the current code the tasks will change (`skills/delegate/scripts/delegate.ps1:303-364`, `skills/delegate/scripts/Sandbox.psm1:2202-2340`, `skills/feature/scripts/feature.ps1:1193-1216`, `2610-2673`, `2733-2805`).

The plan is unusually precise for its size — file boundaries, exact error strings, JSON shapes and per-test dispositions are mostly fixed. The gaps below are where two competent workers, or a worker plus the lead, could still produce different behaviour or get stuck.

---

### 1. Severity: Major
**Affected scope:** `verify-host` brief (plan.md:31), `verify-sandbox` refusal order (plan.md:33); design Data vs. design Rules; `feature.ps1:2733-2805`.

**Finding & Guidance:** The position of the `host run: <task>, approved: <quote>` decision line relative to the scope check and the `state.json` write is not fixed, and the design contradicts itself on it. Design *Rules* say `verify -OnHost -Quote` calls `Add-FeatureDecision` "before anything else runs"; design *Data* orders the refusals as `-TimeoutSec` → `-OnHost`/`-Quote` → worktree → `delegate.ps1` path → command length → the host-run decision, which places it *after* the worktree checks and after the scope computation (which the design also says runs "before the test"). The `verify-host` brief only says "before the test". Consequence a worker cannot avoid deciding: for `verify -OnHost` on a task with no recorded worktree, does the run log a `host run:` line and commit, then fail? Under "before anything else runs" — yes; under the Data order — no. That changes observable behaviour (git history on `feature/<name>`, and whether a refused run leaves a record), and the new test "`-OnHost` refused with no test run when not on `feature/<name>`" doesn't distinguish them. Guidance: state one order explicitly in the `verify-host` brief, e.g. `-TimeoutSec` → `-OnHost`/`-Quote` pairing → worktree checks → delegate path → command length → **host decision line** → scope check → test, and say that no `host run:` line is written when an earlier refusal fires (add that assertion to the refusal test).

### 2. Severity: Major
**Affected scope:** `verify-host` (verify.schema.json, `verify-setup.json`), plan.md:31; design Data "`verify` output" bullets.

**Finding & Guidance:** The plan says to add `setup` as "required; null or `{status enum environment-missing|slot-busy|sandbox-error, message, proposal}`" but never fixes the JSON types of `message` and `proposal`, nor whether extra properties are allowed. From the design, `proposal` must be **object for `environment-missing` and `null` for `sandbox-error`**, and `message` a string — so the schema needs `"proposal": {"type": ["object","null"]}`, `"message": {"type": "string"}`, `required: [status, message, proposal]`. A worker could reasonably write `"proposal": {"type": "object"}`, and nothing would catch it: the only schema assertion the plan names is `$validSamples`, and the single new sample is an `environment-missing` one. Production `sandbox-error` output is never schema-validated (`state.schema.json` types `verify` as a bare object; `test.ps1` doesn't validate verify output at runtime). Guidance: pin the three field types and required-ness in the brief, and add either a second sample (`setup.status: sandbox-error`, `proposal: null`) to `$validSamples` or an in-test `Test-Schema -Json` assertion on an `error`-mode fake result.

### 3. Severity: Major
**Affected scope:** plan summary (plan.md:5) and Phase 2 `Test:` row (plan.md:23); design "Phases" section.

**Finding & Guidance:** The plan sets phase 2's test to the full suite (`pwsh -NoProfile -File scripts/test.ps1`) and says the lead expects one host run there. The design's Phases table prescribes `-Path skills/feature/tests` for phase 2, and its next paragraph states flatly "**No host run is expected there.**" Both documents are read by the lead at build time, and the design's measurement says exactly why the full suite cannot pass in the sandbox (delegate tests: 165 passed, 4 failed). A lead following the design will read a failing phase test as a sandbox/`sandbox-error` problem stop instead of a D2 approval request. Guidance: add one sentence to the plan summary naming the deviation — that the plan's phase 2 test supersedes the design's Phases row and its "No host run is expected there", because the last phase's test is the full suite (plan rule) — and state that the lead logs the approval with `feature.ps1 decision -Kind decision -Text "host run: phase 2, approved: <words>"` before running the suite in `<repo>`.

### 4. Severity: Major
**Affected scope:** `verify-sandbox` brief (plan.md:33), test-handover between `verify-host` and `verify-sandbox`; design's `feature.Tests.ps1` Files row.

**Finding & Guidance:** `verify-host` creates tests that assert the *intermediate* contract — `where: host` on a run without `-OnHost`, `where`/`setup` in output and in `state.json`, `-OnHost` with/without `-Quote`, `-Quote` alone, the decision line, `-OnHost` refused off-branch. `verify-sandbox`'s brief says only to "handle every existing and new test as the design's feature.Tests.ps1 row lists", and that row enumerates the *pre-existing* verify tests plus design-level new ones — it says nothing about the tests `verify-host` just added, several of which `verify-sandbox` must invert (any assertion of `where: host` on a default run). The worker must decide which of the sibling task's tests to rewrite, delete or keep, which is exactly the seam decision the split should have made. Guidance: list them in the `verify-sandbox` brief: which flip to `where: sandbox`, which stay `-OnHost` (the timeout test, the off-branch refusal), and that the `state.json` assertion moves to `where: sandbox`. Also note there that `verify-host`'s `where: host` default deliberately contradicts the design's "`where`: `host` only for `verify -OnHost`" and is removed by this task.

### 5. Severity: Major
**Affected scope:** `verify-sandbox` (feature.ps1 process launch), plan.md:33; design Rules "The sandboxed run".

**Finding & Guidance:** The plan specifies `ProcessStartInfo` with `ArgumentList`, `RedirectStandardOutput/Error` and `ReadToEndAsync`, but says nothing about `StandardOutputEncoding`/`StandardErrorEncoding`. `delegate.ps1` prints its JSON with `ConvertTo-Json`, which does not escape non-ASCII, and the required test "a test command that prints a non-ASCII string (`Write-Output 'caf' + [char]0xE9`) whose `tail` contains it exactly" depends on that byte path surviving `delegate.ps1` → verify's read → `test.tail`. The design's `[Console]::OutputEncoding` statement only covers the *inner* command; it says nothing about the outer read. A worker can plausibly leave `StandardOutputEncoding` unset and get mojibake in `tail` in production while their own fake-based test happens to pass (the fake is in-process-ish and its encoding behaviour differs from a long-lived `pwsh -File` child). Guidance: state in the brief that verify sets `StandardOutputEncoding` and `StandardErrorEncoding` to `[Text.UTF8Encoding]::new($false)` before `Start()`, and that the `hang`/`nojson`/non-ASCII tests all read through that path.

### 6. Severity: Major
**Affected scope:** `sbrun-worktree` (DelegateLaunch.Tests.ps1 `.venv` case), plan.md:17; design Files row for `DelegateLaunch.Tests.ps1`; `delegate.ps1:264-271`.

**Finding & Guidance:** The design requires a `.venv` test that proves the line is appended "exactly once (also when the file did not end with a newline)". That case cannot be staged the obvious way: `delegate.ps1` appends `.xagent/` to `.git/info/exclude` at startup (`delegate.ps1:264-271`) whenever the file lacks that string, and `Add-Content` writes a terminator, so by the time `Add-DelegateVenvExclude` runs the file always ends with a newline — a plain repo fixture can never reach the leading-newline branch. The only arrangement that reaches it is pre-writing `.git/info/exclude` as `.xagent/` **without** a trailing newline before the run (then the startup check matches and does not append). The plan/design don't say this, so a worker will either write an unreachable test, weaken it, or move it to a unit test without being told that's acceptable. Guidance: say in the brief that the no-trailing-newline case is set up by pre-seeding `.git/info/exclude` with the text `.xagent/` and no terminator before the run (any other seed is normalised by the startup append), or allow that one case as an AST-extracted unit test of `Add-DelegateVenvExclude` in the untagged part of the new Describe.

### 7. Severity: Nit
**Affected scope:** `verify-sandbox` refusal "the 30,000-character command-line limit".

**Finding & Guidance:** The design gives the threshold, the error text (`test command too long for a sandboxed run`) and the exit code, but not what is measured. Sum of `ArgumentList` item lengths? Including the quoting .NET adds? Including `pwsh`, `-File`, the delegate path and `-Repo`? Two workers will implement different (both defensible) formulas, and the "too-long refusal" test is only meaningful if it targets the same quantity. Guidance: define it as one expression, e.g. refuse when `$delegatePath.Length + $repo.Length + $worktree.Length + $feature.Length + $commandText.Length + 200 -gt 30000`, or simply `($commandText.Length + $base64.Length + 300) -gt 30000`, and say the test uses a command sized to cross it by a wide margin.

### 8. Severity: Nit
**Affected scope:** `verify-sandbox`, `fake-delegate.ps1` argument recording + the "fake's recorded arguments" test.

**Finding & Guidance:** The test is meant to prove `-Command` "arrived as one argument … ending in the literal `exit $LASTEXITCODE`". If the fake declares `-SandboxRun, -Repo, -Worktree, -Feature, -Command, -TimeoutSec` as the plan says and records its *bound parameter values*, the recorded file will show one `-Command` string no matter how verify actually invoked it — the assertion is vacuous, and the bug it exists to catch (unquoted/space-split argument) would ship. Guidance: require the fake to record `[Environment]::GetCommandLineArgs()` (raw argv) to `fake-delegate-args.txt`, and let the test assert that exactly one raw token begins with the `[Console]::OutputEncoding` statement and ends with `exit $LASTEXITCODE`.

### 9. Severity: Nit
**Affected scope:** `build-docs` (plan.md:29, 35).

**Finding & Guidance:** The task's acceptance command filters `feature.Tests.ps1` on `*templates*` and `*fixtures*`, i.e. tests of `templates/task.md`, `templates/decisions.md` and `fixtures/runs.jsonl`. None of them reads `stages/build.md`, `feature/SKILL.md` or `delegate/SKILL.md`, so the command passes whatever the worker writes (or doesn't write) — the worker gets zero signal, and `verify` will report `passed: true` for a task whose entire output is prose. Guidance: either accept it explicitly (say "this task's check is the unchanged template/fixture tests; correctness is the lead's read") or add a cheap content assertion, e.g. a Pester `It` in the templates Describe asserting that `stages/build.md` contains the `-Feature <name> -TimeoutSec 3600` phase command and no longer contains "only when the report lists Python projects", and that `delegate/SKILL.md`'s `-SandboxRun` row names `-Worktree`.

### 10. Severity: Nit
**Affected scope:** `verify-host` / `verify-sandbox` `-Quote` handling.

**Finding & Guidance:** The design says `-Quote` is "one line", that `-OnHost` *requires* `-Quote`, and that `-Quote` requires `-OnHost`. It doesn't say whether verify must reject a multi-line quote (`Assert-OneLine 'Quote'`, as `gate` does at `feature.ps1:1134`) or whether a bound-but-empty `-Quote ''` counts as present (it would produce `host run: <task>, approved: `). Both are cheap to pin and both change testable behaviour. Guidance: state that verify calls `Assert-OneLine 'Quote' $Quote` and treats an empty `-Quote` as missing (`-OnHost requires -Quote with the user's approval`), matching `gate`.

---

Overall: none of these block execution outright, but findings 1, 4 and 5 would silently produce divergent implementations (history/record ordering, test ownership at the split seam, and encoding of the new `tail` contract), and 2, 3 and 6 need a sentence each in the briefs before the task files are generated.
