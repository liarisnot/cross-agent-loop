<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll read the task file first.

## Review: `docs/designs/sandbox-verify.md` (lines 1–241)

I read the design as the engineer who has to write this code, with the existing `delegate.ps1`, `Sandbox.psm1`, `SandboxEnv.psm1`, `feature.ps1`, the schemas and the tests in front of me. The design is unusually complete for a document of this size: decisions are made, the output contract is written out, refusals have exact messages, and the alternatives are rejected with reasons. What follows are the places where I would still have to invent something, or where the text contradicts the code it points at.

---

### Blockers

**1. Severity: Blocker**
**Affected scope:** Decision D2; Components (`feature.ps1 verify -OnHost`, line ~66); Rules → `Host runs` (line ~205).

**Finding & Guidance:** The design requires `verify -OnHost -Quote` to "first log the decision … same line, same commit rule, then run the test". The only code that does that today is `Invoke-DecisionFeature` in `skills/feature/scripts/feature.ps1`, and it ends in `Out-FeatureOk`, which calls `exit 0`. Called from `Invoke-VerifyFeature` it would terminate the process before the test ever runs. The design does not say whether to (a) extract the logging body (`Enter-FeatureLock` → `Assert-OnFeatureBranch` → `Append-TextLf` → `Invoke-FeatureCommit` → release) into a helper that both paths call, or (b) spawn a child `feature.ps1 decision` process, or (c) inline the body. That is exactly the kind of structural decision that must be pre-made.

Worse, the failure mode is unspecified, and D2's guarantee rests entirely on that line existing: if the decision cannot be written (HEAD is not `feature/<name>` so `Assert-OnFeatureBranch` throws, the tree is dirty, the commit fails, the feature lock is held), does `verify` run the test on the host anyway? It must not — "a host run without its decision line" is precisely the gap this feature closes. The plan must state the mechanism (I would extract `Add-FeatureDecision` and call it from both `Invoke-DecisionFeature` and `Invoke-VerifyFeature`), and state that any failure to write the line refuses the run with exit 1 and `{ok:false, error}`, with no test executed.

**2. Severity: Blocker**
**Affected scope:** Rules → "The sandboxed run" (lines ~183–191); Components (`feature.ps1 verify`, line ~65).

**Finding & Guidance:** The command shown is

```text
pwsh -NoProfile -File <delegate.ps1> -SandboxRun ... -Command "pwsh -NoProfile -NonInteractive -EncodedCommand <base64>; exit $LASTEXITCODE"
```

Two things here are decided by the code but not decided by the document, and both fail silently rather than loudly:

* **`$LASTEXITCODE`.** If `verify` builds that string with a double-quoted here-string (as `Invoke-TaskTestCommand` does for its wrapper), `$LASTEXITCODE` is expanded *on the host* while building the argument, and the inner `pwsh` receives `exit 0` (or whatever the host's last native command returned). `verify` then records `test.passed` from a value unrelated to the test. That is a false pass on the acceptance gate. The document must say the trailing `; exit $LASTEXITCODE` is literal text for the inner shell (single-quoted, or escaped), not host-expanded — and the plan should have a test that proves a failing test command reports `passed: false` through the real command shape, not only through the fake.

* **Quoting of `-Command`.** `Invoke-TaskTestCommand` today calls `Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded)`; every token is space-free, so the unquoted join works. The new call passes a `-Command` value that contains spaces. `Start-Process -ArgumentList` joins with spaces and adds no quotes, so the inner `pwsh` would see `-Command pwsh`, then `-NoProfile` as a separate top-level argument, and the run fails in a confusing way — or, worse, runs something unintended. The document must fix how the argument list is built: either `-ArgumentList` with the `-Command` value pre-quoted using the same MSVCRT escaping the delegate skill's `Quote` uses, or `& pwsh` with a real argument array. "The base64 text keeps the command line free of quotes" addresses the encoded payload only, not the argument carrying it.

---

### Major

**3. Severity: Major**
**Affected scope:** Data → "`verify` output" (lines ~172–179); `schemas/verify.schema.json` change.

**Finding & Guidance:** `where` is described as "Always present" with values `sandbox` or `host`, and separately the design defines `setup` for runs where the sandbox could not start the test at all. What is `where` in those cases? It is a required enum property, `build.md` will read `test.where`, and `state.json` will carry it. Leaving it unspecified means the implementer guesses, and the plausible wrong guess is `host` — which would record that worker code ran on the host when it did not. State it: `where: sandbox` whenever `setup` is not null (the run was attempted in the sandbox and did not start there), `host` only for `-OnHost`.

**4. Severity: Major**
**Affected scope:** Files table (lines ~209–221); `feature.Tests.ps1` schema tests.

**Finding & Guidance:** `schemas/verify.schema.json` gains `where` as a *required* property, but the Files table does not list `skills/feature/tests/fixtures/samples/verify.json`. That fixture is loaded by the `schemas` Describe (`valid sample <_> passes its schema`, `Get-SampleSchemaName 'verify.json'` → `verify`) and its current `test` object has only `command`, `passed`, `exitCode`, `tail`. The phase 2 test command will therefore fail on a file that no task is allowed to write under the write allowlist. Add the fixture to the file list and say what it must contain (`where`, `setup: null`), and consider a second sample or an invalid sample for `setup` since the new required property is the one thing that can silently regress.

**5. Severity: Major**
**Affected scope:** Files → `skills/feature/tests/feature.Tests.ps1` (line ~218: "existing tests keep their meaning"); Data → `-TimeoutSec` rule.

**Finding & Guidance:** "Existing tests keep their meaning" is not achievable as written. The existing `feature.ps1 verify` Describe contains at least three tests whose meaning changes under sandbox-by-default:

* `times out and kills process tree` passes `-TimeoutSec 5`. Under the new rule `-TimeoutSec` must be 30–3600 for a sandboxed run and is "refused otherwise: `invalid -TimeoutSec`", so this test now asserts the wrong thing. To keep its meaning it must run `-OnHost -Quote '<something>'`, which in turn means the test repo has to be on `feature/<name>` and the test has to allow the decision commit.
* `computes changed before test writes out.txt` and `does not change worktree git status or HEAD` pass only because the fake writes nothing; through the fake they no longer test the property they name. They should either stay on the fake (and be renamed to what they now prove) or take an `-OnHost` leg.

The plan must say, test by test, which existing case moves to `-OnHost` (with its decision-line assertion), which stays on the fake, and which is renamed. Otherwise the implementer is designing the test suite's semantics.

**6. Severity: Major**
**Affected scope:** Rules → "`-SandboxRun -Worktree` checks" (lines ~198–200).

**Finding & Guidance:** The checks are written as string comparisons that will not hold against real values. `feature.ps1` stores the worktree in `state.json` as `[IO.Path]::GetFullPath($Worktree.Trim()).Replace('\', '/')` — so `verify` will hand `delegate.ps1` a forward-slash path, and `git rev-parse --show-toplevel` returns a backslash path with its own drive-letter casing. "equals the path" fails on the very first real run. Likewise `--git-common-dir` may be relative to the worktree (the worker path already handles this at `delegate.ps1` lines ~265–267). Specify the normalization explicitly — full path, `-replace '/', '\'`, trailing-separator trim, ordinal-ignore-case comparison — and point at the existing safety check (`$wtTop.TrimEnd('\') -ne $wt`) as the pattern to copy, since `state.json`'s forward slashes are exactly the trap it avoided.

**7. Severity: Major**
**Affected scope:** Rules → "Waiting for `delegate.ps1`" (line ~206); Files → `feature.Tests.ps1` and the fake (lines ~217–218).

**Finding & Guidance:** The `delegate.ps1 did not finish` branch is not reachable from any test. The fake's modes are `ran`, `environment-missing`, `error`, `nojson`, `timeout`; none of them hangs, and the grace period is `<timeout> + 300`, which no phase test can afford. The plan says "New tests: each mapping row", but this row cannot be covered. Add either a `hang` mode to the fake plus a way to shrink the grace (an env var, or a `-GraceSec` on `verify` that defaults to 300 and is documented as test-only), or move this row to the lead-run Verification section and say so. As it stands, the branch that turns a wedged sandbox run into a problem stop ships untested.

**8. Severity: Major**
**Affected scope:** Rules → "The sandboxed run" (lines ~183–188); Files → `feature.ps1`.

**Finding & Guidance:** "`verify` builds the wrapper it uses today (`$ErrorActionPreference = 'Stop'`, the test command in a script block, output merged, `exit $LASTEXITCODE`)" is a loose restatement of the real wrapper in `Invoke-TaskTestCommand`, which is six lines and includes `[Console]::OutputEncoding`, `$global:LASTEXITCODE = 0`, the `try { & { … } 2>&1 | ForEach-Object { "$_" } } catch { "$_"; exit 1 }` shape, and `exit $LASTEXITCODE`. Three decisions are left open: do the two paths share one builder function (and if so, what is it called and where does it live), does `Invoke-TaskTestCommand` keep its own copy, and does the sandboxed path reuse the identical text or a variant. Since `tail` and `passed` are read from that output, a drift between the two wrappers is a behavioural difference between `where: sandbox` and `where: host` for the same test. Name the shared function and require both paths to call it.

---

### Nits

**9. Severity: Nit**
**Affected scope:** Rules → "`.venv` links and git" (line ~196); Files → `delegate.ps1`.

There are three places in `delegate.ps1` that call `Add-SandboxEnvLinks`: the probe form (~line 339), the worker launch (~line 542), plus the new `-Worktree` form. "Whenever `delegate.ps1` links environments" covers all three semantically but not structurally. Say that the exclude write goes into one small local helper called at each link site (not into `Add-SandboxEnvLinks` in `SandboxEnv.psm1`, whose other callers are unit tests), and note that it should also be idempotent under two concurrent runs. A cheap no-container unit test of the "appended exactly once" property would be better than keeping that assertion only in the container-tagged test.

**10. Severity: Nit**
**Affected scope:** Data → `-SandboxRun` parameters (line ~157).

`-Base` defaults to `'HEAD'` in the current parameter block, so "cannot be combined with `-Base`" needs `$PSBoundParameters.ContainsKey('Base')`, not a null/default check. One sentence saves an implementer a wrong first attempt.

**11. Severity: Nit**
**Affected scope:** Rules → "The sandboxed run", the 30,000-character refusal (line ~191).

The design gives the message (`test command too long for a sandboxed run`) but not the shape. Is it `{ok:false, error}` with exit 1, as the other `verify` refusals, or a `test.setup` with `status: sandbox-error`? Both are defensible; pick one, since `build.md` treats those two differently.

**12. Severity: Nit**
**Affected scope:** Rules → "Which `delegate.ps1`" (line ~193).

`XAGENT_DELEGATE_SCRIPT` is described as an override with no behaviour for a path that does not exist. Say it fails like any other missing script (`{ok:false, error}` naming the path), rather than letting the implementer choose between a silent fallback and an error.

**13. Severity: Nit**
**Affected scope:** Flow of a task check (line ~80); Data → `setup` shape.

The flow diagram shows `setup: {status: sandbox-error, message}` while the Data section defines `setup` as `{status, message, proposal}`. The `proposal: null` is implied but omitting it in one of two places that define the same object invites the schema to be written with the field optional.

**14. Severity: Nit**
**Affected scope:** Risks and Mitigations (lines ~137–146).

Adding `.venv/` to the shared `.git/info/exclude` also hides a developer's own untracked `.venv` from `git status` in every worktree of the repo, and from `feature.ps1`'s clean-tree and merge-blocking checks. That is a deliberate and acceptable trade-off, but it is a side effect on the user's own checkout and belongs in the risk table next to the "scope check" rationale for G4.

**15. Severity: Nit**
**Affected scope:** Verification (lines ~232–241), check 2.

The setup for check 2 says to set "a task record with `feature.ps1 task -Worktree -BaseSha`", but `verify` calls `Get-PlanTaskFromFeature`, so the scratch repo also needs a feature (`new`), a stage transition, and a plan import before any task record exists, and the plan task needs a non-empty `test` that reads outside the worktree. As written the check cannot be run by someone who has not already internalized the plan-stage plumbing. Spell out the four or five commands.

**16. Severity: Nit**
**Affected scope:** Files table (lines ~209–221) and Phases (lines ~223–231).

The Files table is repository-wide while the Phases table names task ids. Nothing states which task owns which row (I can infer it, but the plan stage will have to restate it for the write allowlist). One extra column, or splitting the table in two with the task id as a heading, removes the inference — and would have made finding 4 impossible to miss.
