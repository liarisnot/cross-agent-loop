<!-- persona: codebase_details | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer instructions exactly.The review target is `docs/designs/sandbox-verify.md`. I'll read it alongside the cited source and related design docs.The design cites specific functions and current behavior. I'll check those against the source.`docs/designs/sandbox-verify.md` does not meet the implementation-readiness bar. Several statements disagree with the current scripts, and a few contracts are still open choices.

## Blocker

**Severity:** Blocker  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 156–157 and 196; `skills/delegate/scripts/delegate.ps1` lines 68–71 and 101–102; `skills/delegate/tests/DelegateLaunch.Tests.ps1` lines 572–573.

`-Base` on the `SandboxRun` parameter set already defaults to `HEAD`. The plan adds `-Worktree` to that same set and refuses the combination with the exact error `-Worktree cannot be used with -Base`. A check of the bound value treats every `-Worktree` call as combined with `-Base`, because the default is always present. The existing test requires exactly one `SandboxRun` parameter set, so a second set is not available unless that test is updated, and the plan does not mention it. PowerShell’s own parameter-set error is also not the `{ok: false, error}` string the plan requires. The plan has to say that the refusal applies only when the caller passed `-Base` (`$PSBoundParameters` contains `Base`).

**Severity:** Blocker  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 168 and 216–217; `skills/feature/tests/feature.Tests.ps1` lines 1822–1840; `skills/feature/scripts/feature.ps1` `Invoke-TaskTestCommand` (lines 2610–2671).

The plan says the existing `verify` tests keep their meaning and only point `XAGENT_DELEGATE_SCRIPT` at the new fake. The test `times out and kills process tree` calls `verify -TimeoutSec 5`, expects `exitCode` `-1`, expects the tail to match `timed out after 5 s`, and expects a `pwsh` sleeper started in the worktree to be dead. The new rule refuses a sandboxed `-TimeoutSec` outside 30–3600 with `invalid -TimeoutSec`, so this call never starts. The fake’s default mode `ran` runs `-Command` to completion, and `timeout` is a canned result selected by `XAGENT_FAKE_SANDBOX`, which this test does not set. Neither mode starts that sleeper and kills its tree at 5 seconds. The plan does not say to change this test, to pass `-OnHost`, or to make the fake enforce `-TimeoutSec`. The same gap hits the pass/fail and `hello` tests unless default `ran` copies the child process exit code into `exitCode` and the child’s output into `tail`. The fake section does not say that.

**Severity:** Blocker  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 179 and 209–221; `skills/feature/schemas/verify.schema.json`; `skills/feature/tests/fixtures/samples/verify.json`; `skills/feature/tests/feature.Tests.ps1` lines 30–44.

Phase 2’s test is `scripts/test.ps1 -Path skills/feature/tests`. `Describe 'schemas'` requires `fixtures/samples/verify.json` to validate against `verify.schema.json`. That sample’s `test` object is only `command`, `passed`, `exitCode`, and `tail`. The plan makes `where` and `setup` required and does not list the sample under Files. The phase test fails until that file is edited, and the file is outside the plan’s allowlist.

## Major

**Severity:** Major  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 64, 160, 174, and 195; `skills/delegate/scripts/Sandbox.psm1` `Get-SandboxCommandOutputLines` (lines 2202–2225) and the timeout branch of `Invoke-SandboxCommand` (lines 2312–2320); `skills/feature/schemas/verify.schema.json` (`tail` is a string).

`output` today is a string array: stdout, then stderr, first 40 lines, each cut at 400 characters. The plan says `tail` is that reading from the other end, and also that `test.tail` is `-SandboxRun`’s `tail` and that `tail` is the empty string when `setup` is set. It never says whether the new JSON field is an array or a newline-joined string. On timeout, `Invoke-SandboxCommand` sets `exitCode` to `$null` and does not append a line. Today’s host runner appends `timed out after <n> s` after the last 40 lines, so the line is a 41st line. The plan says both that `test.tail` is `-SandboxRun`’s `tail` and that the tail ends with `timed out after <timeout> s`. It does not say which layer appends that line.

**Severity:** Major  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 196–199; `skills/delegate/scripts/delegate.ps1` lines 256–266.

The worktree check says `git -C <path> rev-parse --show-toplevel` equals the path, and that `--git-common-dir` resolves to `-Repo`. The script already normalizes toplevel output by turning `/` into `\` and trimming a trailing separator, and it resolves a relative `--git-common-dir` with `Join-Path`. `--git-common-dir` is the `.git` directory, not the checkout root. A literal equality against `-Repo` rejects a valid linked worktree. The plan does not state those normalizations or that the resolved common directory’s parent is `-Repo`.

**Severity:** Major  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 93 and 218; `skills/feature/stages/build.md` line 165; `skills/delegate/scripts/delegate.ps1` line 102.

Today’s phase test command passes `-TimeoutSec 3600`. The new flow’s command is `-SandboxRun -Repo <repo> -Base feature/<name> -Feature <name> -Command "<phase test>"`, and the `build.md` change text does not mention a timeout. On `SandboxRun`, `-TimeoutSec` defaults to 900 and the parameter range is 30–3600. Following the new command shortens every phase test from 3600 seconds to 900.

**Severity:** Major  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 164–167; `skills/feature/scripts/feature.ps1` line 12 and `Invoke-GateFeature` (lines 1132–1136).

The plan lists `-Quote` as a new `verify` parameter. The script param block already declares `[string]$Quote`, and `gate` requires it (`-Quote is required`). A second declaration will not parse. The refusal `-Quote requires -OnHost` has to stay inside `verify`. `gate` must keep requiring `-Quote` with no `-OnHost`.

**Severity:** Major  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 80–88 and 195; `skills/feature/scripts/feature.ps1` `Invoke-VerifyFeature` (lines 2776–2805).

A failed test today still returns `ok: true` and exit 0, with the failure inside `test`. The plan’s mapping fills `test.setup` for `environment-missing` and `sandbox-error`, and `stages/build.md` is told to read `test.setup` from that result. It never says those outcomes still go through `Out-FeatureOk`. `worktree not found` and `invalid -TimeoutSec` throw and become `{ok: false, error}`. Treating setup failures the same way leaves the lead with no `test.setup`.

**Severity:** Major  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 207–221.

The file table does not mark each path `Create`, `Modify`, or `Delete`. `skills/feature/tests/fixtures/fake-delegate.ps1` is marked `New`. The other rows are prose. One correction covers the whole table.

## Nit

**Severity:** Nit  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 80–83 and 174; `skills/feature/schemas/verify.schema.json`.

`where` is required and always `sandbox` or `host`. The flow rows for `environment-missing` and `sandbox-error` omit it. Those results still need `where: sandbox`, because `-OnHost` is the only host route.

**Severity:** Nit  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 183–187; `skills/feature/scripts/feature.ps1` lines 2616–2622.

The sandboxed command is specified as the wrapper `Invoke-TaskTestCommand` uses today. The parenthetical drops `[Console]::OutputEncoding`, `$global:LASTEXITCODE = 0`, and the `try/catch` that prints the error and `exit 1`. The outer command text also contains `$LASTEXITCODE`, which `feature.ps1` will expand if that string is double-quoted. That dollar sign has to stay literal until the sandbox `-Command` runs.

**Severity:** Nit  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 140 and 191; `skills/delegate/scripts/Sandbox.psm1` lines 1964–2001 and 2129–2133.

`New-SandboxRun`, which `Invoke-SandboxCommand` calls, creates `<worktree>\.xagent\sandbox\home` and `\tmp`, and copies `cli-config.json`, `auth.json`, and `.gitconfig`. `Stop-SandboxRun` deletes only `auth.json`. The risk names the two JSON files. The rule “Nothing is written into the worktree” covers the encoded wrapper, not this home directory. `verify` also drops `-SandboxRun`’s `notes`, so a real `.venv` folder that `Add-SandboxEnvLinks` leaves in place (note `.venv in <project> is a real folder; environment not linked`, `SandboxEnv.psm1` lines 1603–1608) is invisible on the `test` object.

**Severity:** Nit  
**Affected scope:** `docs/designs/sandbox-verify.md` lines 143 and 218.

The risk table says a second `no free slot` (`sandbox: no free slot (both slots busy)`, `Get-SandboxSlot` line 1738) is a problem stop. The `build.md` change text says the lead waits and runs `verify` again once, and does not state the second outcome.
