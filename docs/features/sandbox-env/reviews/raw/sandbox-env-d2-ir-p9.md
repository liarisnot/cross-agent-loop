<!-- persona: implementation_readiness | agent: cursor | model: deepseek-v41-flash-1017-medium -->
I'll read the task file first.

# Implementation Readiness Review — `docs/designs/sandbox-env.md` (lines 1–289)

Verdict: **not implementation-ready.** The document is strong on *what* and *why* (decisions table, probes, grant model, risk table), but a fresh implementer cannot start coding without inventing module structure, persisted state, ref selection, and several data formats. Details below.

---

## Blockers

**1. Severity: Blocker — Standard Readiness (Phasing & Checkpoints)**
**Affected scope:** whole "Detailed Implementation Plan" (lines ~172–289); `Files` table lines 259–277.

**Finding & Guidance:** The plan has no phases, no build order, and no checkpoint per phase. The Standard requires the work to be partitioned into incremental phases that each leave the codebase buildable and testable. As written, an implementer has to decide sequencing themselves — and the order is genuinely non-obvious here: `SandboxEnv.psm1` cannot be exercised at all until `delegate.ps1` has `-SandboxEnv`, but `delegate.ps1`'s launch path cannot link environments until `SandboxEnv.psm1` exists. Required: a phase table (`Phase | tasks/files | done when`), with at least: (a) `Sandbox.psm1` helper extraction + `SandboxEnv.psm1` discovery/report only, verified by Pester with a stubbed `uv`; (b) build/`-Apply` + `envs.json` + lock + prune; (c) link/unlink + `New-SandboxRun -EnvPaths` grants; (d) `delegate.ps1 -SandboxEnv`/`-SandboxRun` + worker launch gate; (e) `feature`/`SKILL.md`/README/test-plan edits + live checks. State what "buildable and testable" means at each checkpoint (which suite, which stub).

**2. Severity: Blocker — Persisted state cannot represent `install-failed`**
**Affected scope:** "Rules" → *Build failure* (line ~251), *Status* (line ~246), "Data" `envs.json` schema (lines 189–207); Risks row "A build fails part-way" (line ~126).

**Finding & Guidance:** The status machine requires `install-failed` ("the last build for this hash failed") and the output contract requires its `reason` (last 20 lines of `uv`'s error). But the `envs.json` schema has no field for either, and the rule says the failed build "records nothing for it". The state therefore evaporates with the process, so a later `-SandboxEnv` can only report `missing` and re-propose a build that already failed — and there is no way to distinguish it in tests. Required: add an explicit field to the schema, e.g. `"failed": { "py3.12-<hash12>": { "at": "<ISO>", "error": "<last 20 lines>" } }`, say that `-Apply` clears the entry for a hash before building and writes it on failure, and say that `install-failed` **is** included in the proposal (`needsApproval` unchanged if `approved` is set and the estimate is under 5 GB), so the report→apply loop terminates.

**3. Severity: Blocker — Module dependency cycle and non-exported helpers are unresolved**
**Affected scope:** "Components" lines 75–89; "Files" rows `SandboxEnv.psm1` and `Sandbox.psm1` (lines 261–263); Rules *Hash* (line ~208), *Grant* (line ~251).

**Finding & Guidance:** The design says `SandboxEnv.psm1` is imported by "`delegate.ps1` and `Sandbox.psm1`", while `SandboxEnv.psm1` must call `Get-SandboxFileHash` (in `Sandbox.psm1`) and the ACL lock's wait/takeover helper (factored out of `Invoke-SandboxAclLocked`). Today `Sandbox.psm1` exports only twelve functions (`Export-ModuleMember`, line 2473) — `Get-SandboxFileHash`, `Resolve-SandboxReadEntry`, `Resolve-SandboxPath`, `Test-SandboxPathUnder`, `Add-SandboxGrantRow` and `Invoke-SandboxAclLocked` are all private. A nested import in either direction yields a partially initialised module (or a hard cycle), so the implementer must choose a structure the plan does not authorise. Also unstated: `SandboxEnv.psm1` needs read-at-a-ref git helpers (`git ls-tree`, `git show`), which today live only in `delegate.ps1` (`Invoke-Git`). Required: name the shared module (e.g. a new `skills/delegate/scripts/SandboxCommon.psm1` holding path/hash/ACL-lock/git-at-ref helpers), add it to the Files table as **New**, and state the import direction (`Sandbox.psm1` and `SandboxEnv.psm1` both import `SandboxCommon.psm1`; neither imports the other), plus which functions stay exported.

**4. Severity: Blocker — The ref that `-SandboxEnv`/`-Apply` builds for is specified three different ways**
**Affected scope:** "Components" line ~91 (`delegate.ps1 -SandboxEnv -Repo <repo> [-Base <ref>]`), "Flow on first use" lines 98–109 (no `-Base`), "Files" row `stages/build.md` (line ~274), "Verification" step 1 (line ~283).

**Finding & Guidance:** "Components" says `feature` passes `feature/<name>`; the Flow shows `delegate.ps1 -SandboxEnv -Repo R` and `-Apply` with no `-Base`, which means `HEAD` (`main`); `stages/build.md`'s change text says only "run `-SandboxEnv`". Since D8 links by the *worktree's* lockfile hash and phase tests then run through `-SandboxRun -Base feature/<name>`, building for `HEAD` and running on `feature/<name>` produces `environment not ready` for any project whose lockfile differs between the two refs — exactly the case D8 was added for. Required: state one rule (the pre-build call is `delegate.ps1 -SandboxEnv -Repo <repo> -Base feature/<name> -Apply`), rewrite the Flow block with `-Base feature/<name>`, and say in the `build.md`/`SKILL.md` change text that `-Base feature/<name>` is passed. Also say whether `-Apply` rebuilds for a ref that was never linked (expected: yes, it builds for `<ref>` only).

**5. Severity: Blocker — `envs.json` read/write has no atomicity or reader rule, and `-Apply` runs concurrently with launches**
**Affected scope:** "Data" lines 188–210; "Last use" lines 233–234; Rules *Status*, *Linking*.

**Finding & Guidance:** `-Apply` rewrites `envs.json` under the `.envs` lock, but worker launches *read* it (status `ready` requires "`envs.json` names it for this project") and take no lock. A launch that reads the file mid-write sees truncated JSON; the design gives no defined outcome, and the likely implementation (treat as absent) turns a transient write into a `sandbox: environment not ready` launch failure — a fail-closed gate tripping on a benign race. Required: specify the write as temp-file-plus-rename into `.envs\envs.json` (`[IO.File]::WriteAllText` to `<file>.tmp`, `Move-Item -Force`), and specify the reader contract for unreadable/absent content (report `missing` for every project, never throw) plus what `-SandboxEnv` itself does when the file is corrupt (an explicit error string is fine, but choose one).

---

## Majors

**6. Severity: Major — `-Apply` approval gating is not defined**
**Affected scope:** "Components" line ~91, Rules *Approval* (line ~248), G2 (line ~33).

**Finding & Guidance:** "The first build needs the user's yes" and "a build that adds more than 5 GB is proposed again" are stated as policy, but no function-level rule says whether `-Apply` refuses when `approved` is null or `needsApproval` is true, or what it does with a recorded first approval when a second, >5 GB approval is needed (there is only one `approved` field, so the design implies approvals are never recorded for rebuilds and `needsApproval` is recomputed each time). The implementer cannot tell whether G2 is enforced by code or by the lead. Required: one sentence of the form "`-Apply` never refuses; `approved` is written on the first successful `-Apply`; `needsApproval` is computed per report and is not persisted; enforcement is the lead's, per `stages/build.md`", plus the exact `needsApproval` predicate (`approved == null || estimateBytes > 5 GB`, with the 5 GB compared against the *delta* or the new total — say which).

**7. Severity: Major — Interpreter resolution is one sentence over an unspecified parser**
**Affected scope:** Rules *Interpreter* (line ~243); "What a project is" line ~72; Build (`lock`) line ~251.

**Finding & Guidance:** "`requires-python` … taking the lowest version it allows that `uv python list` offers" and "a major.minor gets the newest patch `uv` offers" both require parsing `uv python list` output (keys, `download-available` vs installed, exact triples such as `cpython-3.12.1-windows-x86_64-none`) and PEP 440 specifiers (`>=3.11,<4`, `~=3.12`, `==3.12.*`) in PowerShell. Neither the output format nor the selection algorithm is given, and no existing helper in the repo does this. Every one of the six projects in the motivating repo depends on this rule. Required: either specify the exact parse (`uv python list --only-downloads --output-format json` if that exists, else the column you consume, with a worked example line → `3.12.1`), or replace it with a rule that needs no parsing ("`uv python install <spec>` with `UV_PYTHON_PREFERENCE=only-managed` and read the created folder under `.envs\python` to learn the version"). Also state the fallback when `.python-version` names a version `uv` cannot provide (that is currently only `python-version-unknown` for "neither gives an answer").

**8. Severity: Major — `.pth` contents and "the root its build backend declares" are deferred to the implementer**
**Affected scope:** D7 (line ~67), Rules *Project path (D7)* (line ~249), Verification item 6 (line ~287).

**Finding & Guidance:** ".pth … holds one line that appends that project's import root under `XAGENT_WORKTREE` … and does nothing when the variable is unset" plus "The fixture with a `[build-system]` settles the exact rule" is precisely the kind of deferred decision the Standard forbids — and it is not a detail: a `.pth` line must be valid Python (path lines and `import` lines only), and "the root its build backend declares" implies per-backend parsing (hatchling `[tool.hatch.build.targets.wheel].packages` versus setuptools `package_dir`/auto-discovery versus flit `module`/`packages`). Nothing bounds that work. Required: give the exact line (`import os, sys; sys.path.insert(0, ...)` form, guarded on `os.environ.get('XAGENT_WORKTREE')`, with the repo-relative path baked as a literal), the fallback rule when the root cannot be determined (project folder, and a `sandboxNotes` line), and the supported backend list for v1 (if hatchling only, say so and make every other backend take the fallback).

**9. Severity: Major — The estimate depends on factors the plan explicitly leaves open, and it drives the approval gate**
**Affected scope:** Rules *Estimate* (line ~247), G2 (line ~33), Risks row "Disk grows" (line ~114), Verification item 1.

**Finding & Guidance:** "Each interpreter not yet in `.envs\python` adds its own size" — no size is knowable without downloading, so the interpreter term has no source. "scaled for unpacking" and "the factors are fixed in the implementation and its tests" delegate the multiplier, and the multiplier combined with wheel `size` sums determines whether the 5 GB re-approval fires, i.e. the gate is calibrated by an unstated constant. `estimateSeconds` has no formula at all ("download-bound"). Required: fix the numbers in the doc (e.g. unpacking factor 2.5×, interpreter contribution 120 MB each for CPython on Windows x64, seconds = `40 + estimateBytes / 8 MB/s`), say what happens when `uv.lock` lacks `size` for a wheel (treat as 0 and mark the estimate "unknown"), and say that an "unknown" estimate never triggers the 5 GB re-approval path except when `approved` is null.

**10. Severity: Major — `envs.json` can hold only one project per environment, so identical lockfiles in two projects are unrepresentable**
**Affected scope:** "Data" `envs` object (lines 198–206), Rules *Status* (line ~246), Risks row "Two lockfiles share a 12-hex folder name" (line ~124).

**Finding & Guidance:** The env key is `py<ver>-<hash12>` and each entry carries a single `project` string. Two subprojects with byte-identical `uv.lock` (a normal monorepo pattern) produce the same key; `-Apply` overwrites the first entry, and the second project's status falls through every branch of the Status rule ("`envs.json` names it for this project" fails; "an older environment exists for this project" is also false) — an undefined status the implementer must invent. The existing risk row covers only hash-*prefix* collisions, not this. Required: key the environment by its full hash (`"byHash": { "<full sha256>": { "env": "py3.12-<hash12>", "projects": ["src/a","src/b"], "kind", "python", "bytes", "built" } }`) and make Status a lookup by hash; or, minimally, state that two projects with the same hash share the environment and that both names are recorded.

**11. Severity: Major — The readiness gate is evaluated after the worktree exists, with no defined cleanup**
**Affected side:** "Files" row `delegate.ps1` (line ~263); Rules *Linking* (line ~253); G5 (line ~37).

**Finding & Guidance:** Today all `sandbox:` failures happen before the worktree is created (`delegate.ps1` line 339 comment: "sandbox setup (before any worktree, so a failure leaves none)"). The new gate needs the worktree's own lockfile hash, which the design places after worktree creation — leaving a worktree and a `xagent/<TaskId>` branch behind on `sandbox: environment not ready`, and no `runs.jsonl` line to point at it (worker-sandbox.md: "a run that fails before the agent starts … exits through `Fail`"). The plan must say which of the two happens. Required: evaluate readiness from the ref (`git ls-tree`/`git show` at `-Base`) *before* `worktree add`, and only link after creation; or, if you keep the post-creation check, add the worktree+link removal to the failure path and say so. Pick one and write it into the `delegate.ps1` Files row.

**12. Severity: Major — `-SandboxRun` orchestration has no owner and no error path**
**Affected scope:** "Files" row `Sandbox.psm1` → `Invoke-SandboxCommand` (line ~263), "Components" line ~92, Rules *`-SandboxRun` status* (line ~255).

**Finding & Guidance:** `Invoke-SandboxCommand` is specified as "calls `New-SandboxRun`, then `Start-SandboxProcess`, waits up to the timeout, then calls `Stop-SandboxRun`" — but `New-SandboxRun` *requires* a `-Slot` from `Get-SandboxSlot`, which only `delegate.ps1`'s launch path and `Invoke-SandboxCanary` call today. Worktree creation/removal, the `environment-missing` early return, killing on timeout, reading the two log files into "the first 40 lines", and mapping results into the JSON object are all unassigned between two files. Required: give `Invoke-SandboxCommand -Repo -Command -Base -TimeoutSec` the whole sequence, step by step, in the style of the existing `Invoke-SandboxCanary` spec (setup → slot → `New-SandboxRun` → start → wait/kill → `Stop-SandboxRun` in `finally` → unlink → `git worktree remove --force` → JSON), and name the worktree folder pattern (e.g. `<repo>.xagent\probe-<rand8>`) so it cannot collide with task ids or the `-Cleanup` detached-worktree match `^<TaskId>-[a-z0-9]+$`.

**13. Severity: Major — No seam for stubbing `uv`, which the test plan depends on**
**Affected scope:** "Files" row `SandboxEnv.Tests.ps1` (line ~266) — "No `uv` and no network: building is tested with stubbed commands"; Rules *`uv` itself*.

**Finding & Guidance:** `uv` is located with `Get-Command uv` and invoked for `python list`, `python install`, `sync`, `lock`, `venv`, `pip install`. Pester has no supported way to shadow `Get-Command` for a module's internal calls, so "stubbed commands" needs a documented injection point — the repo has precedent in `Get-SandboxRuntime -UvProbe <scriptblock>` (`Sandbox.psm1` line 818). Required: state the seam in the Rules (`SandboxEnv.psm1` resolves `uv` through an overridable script-level `$script:UvPath`, set from `XAGENT_UV_PATH`, and every invocation goes through one `Invoke-SandboxUv` helper), and say which tests drive that helper with a fake `uv.exe`.

**14. Severity: Major — `feature.ps1 doctor` integration is unspecified, and its test prescription is factually wrong**
**Affected scope:** "Files" rows `feature.ps1` and `feature.Tests.ps1` (lines 270–271); "Components" line ~95; `skills/feature/scripts/feature.ps1` lines 2982–3166; `skills/feature/tests/feature.Tests.ps1` lines 2982–3004.

**Finding & Guidance:** Three concrete problems. (a) The mechanism is unstated: the Components line shows a subprocess (`doctor -> delegate.ps1 -SandboxEnv`) while the Files row says the check is "built from the `-SandboxEnv` report", and `doctor` today imports `Sandbox.psm1` in-process (line 3152). Pick one: if in-process, say `doctor` imports `SandboxEnv.psm1` and calls the report function directly (no JSON round-trip) and that a `uv`-missing report is not a doctor failure; if subprocess, say it uses `Invoke-DoctorCommand` with the existing 30 s timeout and what a timeout reports. (b) The Files row says `It 'reports prerequisites'` "(~line 2468) expects ten checks, with `sandbox` last" — that is already true today (line 3002 asserts `10`; line 3004 lists `..., 'log-dir', 'sandbox'`). After adding the check the assertion becomes **eleven**, with `'sandbox-env'` last; the line number is ~2982, not ~2468. (c) The detail-length cut (worker-sandbox.md uses 300 chars for `sandbox`) is not stated for `sandbox-env`, and the check name (`sandbox-env`) must be distinct from the existing `sandbox` — say so explicitly, since two similarly named checks will confuse the lead reading the JSON.

**15. Severity: Major — No recovery or removal path for a broken `.envs`, while the gate fails closed**
**Affected scope:** G4 (line ~36), G6 (line ~38), Risks lines 113–127, "Files" rows for `SKILL.md`/`README.md`.

**Finding & Guidance:** With G5 failing closed, any environment that is wrong but *looks* `ready` (e.g. a `uv` upgrade changes lockfile semantics, a bad build that succeeded, a `.pth` pointing at a stale root) blocks every worker for that repo, and the only documented remedies are `-NoSandbox` (which the skills forbid without the user asking) and waiting 14 days for prune. There is no `-Rebuild`/`-Forget <project>` switch and no documented manual reset. Required: either add `delegate.ps1 -SandboxEnv -Repo <repo> -Forget <env|project>` (delete folder, stamp and `envs.json` entry under the lock) or write an explicit "if the report looks wrong, delete `<repo>.xagent\.envs` and re-run `-Apply`" procedure into `SKILL.md` and `README.md`. Also say what the failure report looks like when `-Apply` itself keeps failing (the `install-failed` reason is only "last 20 lines").

---

## Nits

**16. Severity: Nit — Status list omits `install-failed`.** "Components" line ~91 lists `ready`, `missing`, `stale`, `unsupported`; the JSON contract and the Status rule include `install-failed`. Add it to the prose so a reader of only the Components section does not implement four states.

**17. Severity: Nit — Probe P3's evidence contradicts the chosen build command.** P3's failure mode is "the editable install points at the checkout", but the build rule uses `uv sync --frozen --no-install-workspace`, under which the project is never installed, so the observed failure cannot recur. Say plainly why the `.pth` is still required after `--no-install-workspace` (nothing puts the project on `sys.path` at all), otherwise the implementer may think the `.pth` is the fix for a solved problem — or may omit `--no-install-workspace`.

**18. Severity: Nit — `.envs\work\<name>` and pruned entries are never collected.** Prune deletes environment folders but says nothing about `.envs\work\<name>`, the `linked` stamp, or the `envs` entry; all three accumulate. Add "prune also deletes `.envs\work\<name>`, `.envs\linked\<name>`, and the matching `envs`/`failed` entries".

**19. Severity: Nit — Lock naming details.** The `.envs` lock name hashes "the .envs path" — say it is the normalized `<repo>.xagent\.envs` (`GetFullPath`, trailing separator removed, lower-cased) so two spellings of the same repo do not make two locks; and say the factored helper takes the timeout message as a parameter, since `Invoke-SandboxAclLocked`'s current text ("finish changing permissions") is wrong for builds.

**20. Severity: Nit — `Get-SandboxEnvironment` extension shape.** "appends what it is given" plus `-ExtraEnv` "(variables and a `PATH` suffix)" leaves the parameter type open (hashtable with a reserved `PATH` key? `[string[]]$ExtraEnv` of `NAME=VALUE` plus `[string]$PathSuffix`?). Name the shape, and state the behaviour when `.envs\bin` exists but `uv.exe` was deleted (today's rule adds it to `PATH` regardless, and the worker's `uv run` then fails with a bare "not recognized").

**21. Severity: Nit — Probe output contract details.** Which stream the "first 40 lines" come from (stdout, stderr, or interleaved — the run path writes two files), whether lines are truncated per line, and `exitCode`'s value on `environment-missing` (null versus `-1`). One sentence each.

**22. Severity: Nit — Unlink enumeration.** "delete every `.venv` junction in the worktree" — say how they are found (the tracked project list at the worktree's `HEAD`, joined with `\.venv`), and how a junction is detected (`(Get-Item -Force).LinkType -eq 'Junction'` / `Target`), since deleting needs `Directory.Delete`-as-link semantics and must not recurse.

**23. Severity: Nit — `-SandboxEnv` failure contract.** The output object always shows `"ok": true`; state that an invalid repo/ref or an unreadable `.envs` returns `{ok:false, error}` with exit 1 (delegate's `Fail`), so the lead and `doctor` can branch on it.

**24. Severity: Nit — `pythons` map discovery, and `.python-version` as written.** `"3.12": "<folder under .envs\python>"` presumes the folder name, which `uv python install` chooses; say the folder is discovered by diffing `.envs\python` before and after the install (or by `uv python find --managed-python`). Also "a full version such as `3.12.1` is used as written" — say whether the `pythons` key is then `3.12.1` while environment names still use `py<major.minor>`.

**25. Severity: Nit — Command quoting for `-Command`.** `pwsh -NoProfile -Command <cmd>` is built by `Get-SandboxCommandLine`/`ConvertTo-SandboxArgument`, which follow MSVCRT quoting, not PowerShell's parser; a phase test containing quotes or `|` can change meaning. Say the command is passed as a single argument through `ConvertTo-SandboxArgument` and add a Pester case for a command containing `"` and `;`.

**26. Severity: Nit — `resolve` hash serialization.** "each file's repo-relative path and bytes, in sorted order" has no length or separator between fields, so two different file sets can hash the same. Add a length prefix or a NUL/U+0001 separator to the spec.

**27. Severity: Nit — Document structure.** The repo's design template (`skills/feature/egm/skills/egm-draft/references/design_doc.md`, and `worker-sandbox.md` as an example) expects a "Critical User Journeys" section and a "Non-Functional Requirements" section. The Flow block covers the happy path only; there are no Given/When/Then journeys for the failure paths the goals hinge on (launch refused by the gate; a >5 GB rebuild; a stale lockfile; a probe returning `environment-missing`). Adding two or three CUJs would also give the test plan its acceptance cases.

---

## What is already good (no action)

The Decisions table with justification, probe results P1–P5 with pass/fail stated, the explicit `Files` table (a genuine write allowlist, with the one directory glob used only for fixtures — acceptable), the `envs.json`/report JSON shapes, the per-run grant model reusing `Resolve-SandboxReadEntry` and the ledger, and the "no second permission system" reasoning are all at the right level of detail. Items 1–5 above are what stand between this document and an implementable plan.
