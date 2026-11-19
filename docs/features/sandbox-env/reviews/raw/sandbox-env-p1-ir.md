<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll read the task file first.

## Review verdict — Mode: REVIEW

The plan is structurally sound: five phases, each leaving the tree buildable, tasks ordered so that same-file edits serialize, and every brief anchored to a named design Rule. It fails the Zero-Decision Rule in a handful of places where two different workers (each seeing only its own task file) must agree on an interface that the plan never fixes, and one place where the design and the plan contradict each other outright. Details below.

---

### Blocker 1 — `XAGENT_WORKTREE` has no owner, and the plan assigns it to a function that cannot know its value

**Severity:** Blocker
**Affected scope:** `plan.md` line 50 (task `env-link`), line 62 (task `dlg-commands`), line 20 (`sbx-command`); design Rules "Environment variables", "Linking", "Invoke-SandboxCommand".

`env-link` says linking "returns the env paths, interpreter folders, `.envs\bin` and the variables for `New-SandboxRun`", and the design's Rules "Environment variables" lists the value `XAGENT_WORKTREE=<slot>:\` among the values `SandboxEnv.psm1` supplies. But the slot letter does not exist when `SandboxEnv.psm1` runs: for a worker launch, `delegate.ps1` calls the link step after `git worktree add` and only then calls `Get-SandboxSlot` (current `delegate.ps1:510`); for a probe, `Invoke-SandboxCommand` takes the slot *inside* itself and receives the extra environment as a parameter, so its caller cannot fill in a slot-rooted value either. A Phase 3 worker reading only `env-link` will emit an `ExtraEnv` map it has no value for (null, empty, or the host worktree path, all of which silently break the `_xagent_<n>.pth` line from D7), and the Phase 4 worker will happily pass it through. Unit tests that only assert "the variables contain the key" will pass; only the live sign-off check (design Verification 6) would fail.

Decide and write it down: either `New-SandboxRun` / `Get-SandboxEnvironment` sets `XAGENT_WORKTREE=<letter>:\` itself (the letter is bound there), in which case `env-link` must *not* return it and the override-refusal rule in `sbx-envpaths` becomes the guard that stops a caller from setting it; or the link step takes the slot as an argument and `Invoke-SandboxCommand` calls it after `Get-SandboxSlot`. One of the two, named, with the exact value format.

---

### Blocker 2 — `Invoke-SandboxCommand`'s result-shape test rests on a stub that does not exist

**Severity:** Blocker
**Affected scope:** `plan.md` line 20 (`sbx-command`), file `skills/delegate/tests/Sandbox.Tests.ps1`.

The brief says: "result shape with a stubbed process where the existing tests stub one." There is no such stub. `Sandbox.Tests.ps1` contains zero `Mock` calls; every existing run test (`Describe 'run lifecycle'`, `Describe 'run functions'`, the `Invoke-RunScript` helper at line ~2588) starts a *real* sandboxed process and is guarded by `$script:RunSkip`. `Start-SandboxProcess` ends in `[XagentSandbox]::Start(...)`, a .NET static that Pester cannot mock, and there is no injection parameter or script-scope function pointer anywhere in the run path. So the Phase 1 worker must invent the seam — adding an injectable "start process" hook to `Sandbox.psm1`, or writing the result-shape assertions against a real slot (slow, machine-dependent, skipped where unsupported). The first is a structural change to a module the plan says is finished in this phase; the second contradicts the brief's promise of a stubbed process.

Name the mechanism in the brief: either a small injectable scriptblock parameter (mirroring the existing `-UvProbe` precedent, e.g. `-StartProcess { ... }` on `Invoke-SandboxCommand`) with the exact parameter name and default, or state that the case is a `-Tag Sandbox` live test with the same skip guard as `Describe 'run lifecycle'`, and drop "stubbed".

---

### Blocker 3 — Two design Files rows and the whole live verification have no owning task

**Severity:** Blocker
**Affected scope:** `plan.md` lines 3-7 (summary), Phase 5 table and briefs (lines 68-80); design Files rows `docs/test-plan.md` and `docs/HANDOFF.md`; design "Verification" items 1-8.

The plan's own summary claims "Every task follows the design's Rules and Files sections", but no task's Files column contains `docs/test-plan.md` or `docs/HANDOFF.md`, which the design's Files table explicitly requires ("Rows for the probes and the live checks", "State of the feature at sign-off"). Under the Target Standard's file-boundary requirement the Phase 5 write allowlist will therefore forbid the worker who notices from touching them, and no worker will notice, because no brief mentions them. The same hole swallows the live checks: the plan says at the top that sign-off needs `uv` and the private repo, but no task owns running design Verification 1-8 or recording their results, and each Phase 5 task's Test column is only the Pester suite. Either add a sixth Phase 5 task (`signoff-records`, files `docs/test-plan.md`, `docs/HANDOFF.md`) with the eight checks as its acceptance list, or state that the lead performs and records them outside the task sequence — but do not leave the design's two files unassigned while also promising the design is implemented in full.

---

### Major 1 — Inter-task function contracts are unnamed and untyped

**Severity:** Major
**Affected scope:** `plan.md` lines 34-35 (Phase 2), 47-50 (Phase 3), 62-64 (Phase 4), 74-76 (Phase 5); new module `skills/delegate/scripts/SandboxEnv.psm1`.

The briefs name the functions the module must contain (`Invoke-SandboxEnvApply`, `Test-SandboxEnvReady`, "linking", "unlinking", prune) but never their parameter names, types or return shapes. Two concrete consumers exist outside the module and are written by different workers: `delegate.ps1` (`-SandboxEnv`, `-SandboxRun`, the launch gate, cleanup unlink) and `feature.ps1` (`Get-SandboxEnvReport` called in-process). "The gate returns ready or the not-ready list with the exact error text and proposal" does not say whether that is `$true`/`$false`, `@{ready; message}`, or a throw; "returns the env paths, interpreter folders, `.envs\bin` and the variables" does not say the property names, nor the shape of the env-path entries (`{path, project}`? parallel arrays?). Also missing: the `Export-ModuleMember` list for `SandboxEnv.psm1` — without it `feature.ps1`'s in-process call to `Get-SandboxEnvReport` fails at runtime, and nothing in `doctor-env` tells the worker which functions to export.

Pin, per function: parameter names and types, return shape with field names, and the export list. This is exactly the "defining an API signature" case the Zero-Decision Rule calls out.

---

### Major 2 — Nothing assigns the `pruned` output array or the `-Apply` report assembly

**Severity:** Major
**Affected scope:** `plan.md` lines 47 (`env-build`), 50 (`env-link`), 62 (`dlg-commands`); design Data "`-SandboxEnv` output".

The design's output object has `built`, `failedNow` **and** `pruned` (each with defined element fields), all present only under `-Apply`. `env-build` says "Returns built and failedNow". `env-link` adds prune to `-Apply` but says nothing about emitting `pruned: [{env, bytes}]`, and no brief says who merges the three arrays into the single JSON line `dlg-commands` prints, nor whether the report is recomputed after apply (and if so, whether `projects`/`proposal` in an `-Apply` response reflect pre- or post-build state). A worker will implement some of this and skip the rest, and the only test named is "prune keeps a fresh stamp", which does not touch the output.

Say explicitly: which function returns `pruned`, its element shape, and whether `delegate.ps1` prints one object assembled from the apply result plus a fresh report (and in which order).

---

### Major 3 — "the caller passes the project name per path" has no mechanism

**Severity:** Major
**Affected scope:** `plan.md` line 18 (`sbx-envpaths`), `skills/delegate/scripts/Sandbox.psm1` (`Get-SandboxGrantList`, `New-SandboxRun`).

The refusal message is parameterized: `sandbox: environment path '<path>' <reason>; run -SandboxEnv -Apply -Rebuild <project>`, "(the caller passes the project name per path; without one, omit the clause)". But the only new inputs are `-EnvPaths <string[]>` on `New-SandboxRun`/`Get-SandboxGrantList`, and a `string[]` carries no project name. The worker must choose between a parallel `-EnvProjects` array (and decide what happens when the counts differ), an object array `@{path; project}`, or a side-table — and must decide whether the message is built in `Get-SandboxGrantList` or by whoever maps environments to projects (`SandboxEnv.psm1`, which does not exist yet in Phase 1). Fix the parameter (name, type, zip/validation rule) and where the message is formatted.

---

### Major 4 — CLI refusals: mechanism and message text unspecified

**Severity:** Major
**Affected scope:** `plan.md` line 62 (`dlg-commands`), `skills/delegate/tests/DelegateLaunch.Tests.ps1`.

"`-Rebuild` only with `-Apply`" and "refused with `-NoSandbox`" both need a decision the brief withholds. Note the trap: today `-NoSandbox` is declared in the `Run` and `Check` sets only (`delegate.ps1:101-103`); if it is *not* declared in the new `SandboxRun` set, PowerShell fails binding with its own message ("Parameter set cannot be resolved…") and never reaches `Fail`, so the existing pattern (`Fail '-NoSandbox cannot be used with -SandboxCheck'`, asserted verbatim in `DelegateLaunch.Tests.ps1:500-507`) cannot be reproduced without adding the switch to the new set. Name the exact error strings (e.g. `-NoSandbox cannot be used with -SandboxRun`, `-Rebuild requires -Apply`), state that both switches must be declared in the new sets so `Fail` can produce them, and say whether `-Rebuild` also needs a `ValidatePattern`/membership check.

---

### Major 5 — `Invoke-SandboxCommand`'s log location is undefined

**Severity:** Major
**Affected scope:** `plan.md` line 20 (`sbx-command`), line 62 (`dlg-commands`).

"logs to `<repo>\.xagent\runs\<run name>\`" — `<run name>` is never defined. The design says `probe-<hex>`, but not which hex (the probe worktree's suffix in `dlg-commands`, a fresh GUID inside `Invoke-SandboxCommand`, or a name passed in), not the stdout/stderr file names, not whether the folder is created by `Invoke-SandboxCommand` or by the caller, and not whether `<repo>\.xagent` must be added to `info/exclude` (the worker launch path does this at `delegate.ps1:249-253`; `-SandboxRun` may bypass it). Since `dlg-commands` and `sbx-command` are different tasks, this is another shared contract. Specify the folder name source, the file names, and the creator.

---

### Major 6 — The fake `uv` contract is split across two phases and never written down

**Severity:** Major
**Affected scope:** `plan.md` line 34 (`env-discover` — creates the fixtures), line 47 (`env-build` — needs them), `skills/delegate/tests/fixtures/sandbox-env/fake-uv.ps1`.

Phase 2 owns `fake-uv.ps1`/`fake-uv.cmd`; Phase 3 requires that "the fake uv creates the folders and files a real build would (`Scripts\python.exe` stand-in, `Lib\site-packages`) and can be told to fail". The mechanism for "told to fail" (env var? sentinel file? argument?), the argument dispatch (`--version`, `python install`, `python find --managed-python`, `sync --frozen …`, `lock`, `venv`, `pip install --python …`), the printed output for each, and whether the interpreter stand-in must satisfy the `python.exe -c "import platform; print(...)"` exact-version probe (design Rules "Interpreter") are all unstated. The Phase 2 worker cannot anticipate what Phase 3 needs, and Phase 3's brief only allows editing the fixtures dir via `env-build`'s Files column — meaning Phase 3 will rewrite Phase 2's fixture and, more importantly, rewrite Phase 2's tests' assumptions.

Write the fake's contract in `env-discover`'s brief (argument table, output per call, failure injection switch, whether `python.exe` is a real `pwsh`-or-`.cmd` shim that answers `-c`), and state that Phase 3 may only extend it additively.

---

### Major 7 — Resolve-build working directory contradicts itself

**Severity:** Major
**Affected scope:** `plan.md` line 47 (`env-build`); design Rules "Inputs" and "Build (`resolve`)".

Inputs are written "at the same repo-relative paths" under `.envs\work\<name>`, so a project at `src/tts` lands at `.envs\work\<name>\src\tts\pyproject.toml`. The design's lock build correctly says `In .envs\work\<name>\<project>`, but the resolve build says "`uv lock` in `.envs\work\<name>`" — i.e. one level above the lockfile it must read — and the plan's brief repeats "resolve builds (`uv lock` then sync)" without resolving it. It also does not say whether `uv lock` receives the same `UV_PROJECT_ENVIRONMENT`/`UV_PYTHON_INSTALL_DIR`/`UV_PYTHON_PREFERENCE` environment as the sync, or how the pinned interpreter from `uv python find` is passed to `uv lock` and `uv venv` (the brief mentions `--python <interpreter>` only for `uv venv`). State the working directory and the full environment/argument set for each of `uv lock`, `uv sync`, `uv venv`, `uv pip install`.

---

### Major 8 — Design-mandated test cases are missing from the briefs

**Severity:** Major
**Affected scope:** `plan.md` lines 34-35, 47, 50; Target Standard "Test Plan: Specific test cases (happy path and edge cases)".

The design's own Files row for `SandboxEnv.Tests.ps1` enumerates cases the plan does not assign anywhere, so a worker following its brief will not write them:
- "an index in `uv.toml` is copied" (build inputs) — absent from `env-build`.
- Linking's branch "if it is a real folder, leave it, and add the `sandboxNotes` line `.venv in <project> is a real folder; environment not linked`" — absent from `env-link`'s test list.
- "If `.venv` is already a junction, replace it" — absent.
- Status `uv-missing` for every project and "`-Apply` then builds nothing and still returns `ok: true`" — absent.
- The gate leaving an existing worktree untouched (design Rules "Readiness gate": "an existing one is left as it was") — `dlg-launch-gate` only tests "leaves no worktree" for the new-worktree case.
- A corrupt `envs.json` — implied by `env-report`'s "unreadable" wording but not stated as a case.

Add these to the relevant briefs' test lists, with the assertion each one makes.

---

### Major 9 — Report field decisions left to the implementer

**Severity:** Major
**Affected scope:** `plan.md` lines 35 (`env-report`), 47 (`env-build`), 50 (`env-link`); design Data "envs.json", "`-SandboxEnv` output".

Four small but externally visible choices are unmade:
- `warning` is a single optional string, but two sources exist (unreadable `envs.json`, and the `uv.exe` copy failure in `env-build`). Say how they combine (`'; '`-joined, last-wins, or a `warnings` array — the last would change the design's shape).
- Whether the `-Apply`-only keys (`built`, `failedNow`, `pruned`) are absent from a report-only object or present as empty arrays. Tests written in two different tasks will otherwise disagree.
- `envsBytes` = "current size of `.envs`": recursive enumeration (a multi-second walk of a 5 GB tree, on every `-SandboxEnv` and every doctor run) or the sum of `bytes` recorded in `envs.json` (cheap, but wrong for stray files). Both are defensible; only one is correct for the estimate text and for the doctor's 300-character detail.
- `-Rebuild <project>` naming a project that has no current environment is "a normal build", but a project path that is not a project at all (bad path, or `unsupported`) has no defined behaviour or error text.

---

### Nit 1 — Files column uses a directory where six exact files are known

**Severity:** Nit
**Affected scope:** `plan.md` lines 34, 47 (`skills/delegate/tests/fixtures/sandbox-env/`).

The Target Standard allows a directory glob "only for generated output whose filenames can't be known in advance". These names are known and are enumerated in `env-discover`'s own brief (`uv.lock`, `pyproject.toml`, `uv.toml`, `requirements.txt`, `fake-uv.ps1`, `fake-uv.cmd`). Listing them as paths makes the Phase 5 allowlist checkable and stops `env-build` from silently adding fixtures that no test owns.

---

### Nit 2 — The `*canary*` filter and the phase `-Fast` test have different, undocumented costs

**Severity:** Nit
**Affected scope:** `plan.md` line 19 (task row `sbx-command`), line 9 and the per-phase test lines.

The per-task command invokes Pester with `Run.Path` set directly, so `scripts/test.ps1`'s `ExcludeTag Live/Slow` never applies. `-Filter.FullName "*canary*"` therefore pulls in `It 'the canary passes and leaves nothing behind'` (inside `Describe 'run lifecycle' -Tag Sandbox`), which needs a real sandbox and a network. Conversely the phase checkpoint `scripts/test.ps1 -Fast` excludes `Slow` but not `Sandbox`, so Phase 1's checkpoint is machine-dependent. Either add `$c.Filter.ExcludeTag = "Sandbox"` (or `"Live"`) to the per-task commands, or say in the Phase note which tags the checkpoint tolerates.

---

### Nit 3 — `_xagent_<n>.pth` numbering when two projects share an environment

**Severity:** Nit
**Affected scope:** `plan.md` line 47 (`env-build`); design Rules "Project path (D7)".

D7 and the identity hash both allow two projects with identical inputs to share one environment, which means two `.pth` files in the same `Lib\site-packages`. "n from 1" does not say in what order projects are numbered (repo-relative ordinal sort of project paths is the natural answer) or what happens on a rebuild of one of the two (are both rewritten?). One sentence in the brief closes it.

---

### Nit 4 — Where the `-NoSandbox` launch case lives

**Severity:** Nit
**Affected scope:** `plan.md` line 64 (`dlg-launch-gate`).

The brief says the `-NoSandbox` case goes in the new `Describe 'environment gate'`, but the task's own test filter also matches `*unsandboxed delegate*`, i.e. the existing Describe at `DelegateLaunch.Tests.ps1:544`. The worker must guess, and the filter will run whichever exists either way. Pick one and say so; also say whether the new Describe carries `-Tag Sandbox` (the sibling uses `-Tag Sandbox` plus a `Get-LaunchSkipReason -Kind Sandbox` discovery skip, which the brief only alludes to as "like the existing sandboxed Describes").

---

### Nit 5 — Small unfixed strings and formats

**Severity:** Nit
**Affected scope:** `plan.md` lines 18, 20, 35, 50.

- `Get-SandboxEnvironment` "refused with a throw" for an `ExtraEnv` name it already sets: no message text, and no rule for rendering non-string values into the `NAME=value` string array the native layer takes.
- The gate error embeds `-Base <commit>`: state whether `<commit>` is the resolved SHA (`git rev-parse`) or the ref as typed, since `dlg-launch-gate` will assert this text.
- `Invoke-SandboxCommand` returns "status ran or timeout, exitCode, …": name the fields, and state whether `seconds` is measured from slot acquisition or process start.
- The lock helper is named only as "the lock helper": give it a name (`Invoke-SandboxLocked`?) and whether it takes `-ScriptBlock` only or also returns the body's output.

---

### What is already good, so it does not get re-litigated

Task ordering enforces serialization on `Sandbox.psm1`, `SandboxEnv.psm1`, `delegate.ps1` and each test file; every brief points at named design Rules rather than paraphrasing them; the estimate, status order, gate text and link/unlink primitives are precise enough to code against; and the "existing runs behave exactly as before" invariant is stated per phase with a concrete checkpoint. The findings above are all about interfaces *between* tasks and about output fields, which is where this plan is thin — not about the phasing.
