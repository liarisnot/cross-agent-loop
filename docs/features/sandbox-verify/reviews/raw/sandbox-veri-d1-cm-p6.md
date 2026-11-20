<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Reading the task file and following its reviewer instructions.


Checking whether key terms used in the design are defined in the document or linked context.
## What this proposes

The design moves `feature.ps1 verify` off the host and into the same Windows AppContainer path workers use (`delegate.ps1 -SandboxRun`), so a worker’s test command runs with sandbox isolation before the lead reviews the diff. It adds `-Worktree` to `-SandboxRun` so the test runs in the worker’s existing worktree (with uncommitted changes), not a disposable probe worktree. Task verify gets `-OnHost`/`-Quote` for explicit, one-shot user approval when the sandbox cannot run the test. Verify output gains `test.where` and `test.setup`. D1 extends that sandbox-first rule to phase tests in every repo. D5 makes sandboxed verify and phase `-SandboxRun` runs count toward the feature’s two concurrent-run cap via a pid file.

## How the existing system works, per this document

Workers already run sandboxed via `worker-sandbox`. `sandbox-env` runs phase tests through `-SandboxRun` only when the repo has Python projects; otherwise phase tests run on the host. Today, `verify` always runs the worker’s test command with host `pwsh` in the task worktree, so worker-written scripts can reach anything the host can. `-SandboxRun` today creates a `.probe-<hex>` worktree at a ref, runs a command, then removes the worktree. The build stage consumes verify’s JSON (`test.passed`, `exitCode`, `tail`) and a pre-test scope check (`changed`, `outOfScope`). This repo’s own feature tests already pass in the sandbox; delegate skill tests fail there because they exercise real `D:\` and temp paths.

---

### Finding 1
1. **Severity:** Major  
2. **Affected Scope:** Goals, G3 (line 29) vs Open Questions (lines 39–41)  
3. **Discrepancy Description & Rationale:** G3 still says “(The open question below is how wide that approval is.)” but Open Questions is “None” and D2 already fixes per-run, never-remembered approval. A reader can’t tell whether host-approval scope is still undecided.

### Finding 2
1. **Severity:** Major  
2. **Affected Scope:** Components (line 58) vs Data, “Output” (line 148)  
3. **Discrepancy Description & Rationale:** `-SandboxRun` JSON for `environment-missing` is described inconsistently. Components list `message` and `proposal`; Data also includes `projects`. An implementer won’t know whether verify/setup must surface `projects`.

### Finding 3
1. **Severity:** Major  
2. **Affected Scope:** Flow of a task check (lines 84, 190–191); Files table, `build.md` (line 205)  
3. **Discrepancy Description & Rationale:** Task host fallback is explicit (`verify -OnHost -Quote`). Phase host fallback is only “log `feature.ps1 decision`, then run in `<repo>`” with no command, no mirror of `-OnHost`, and no statement of what output the lead reads or stores. “As for verify” overpromises for a path that has no structured `test.where`/`setup` like verify.

### Finding 4
1. **Severity:** Major  
2. **Affected Scope:** Components, Rules (lines 58, 188, 191); Risks (line 90); Files table, `build.md` (line 205)  
3. **Discrepancy Description & Rationale:** **Readiness gate**, **cap rule**, and **problem stop** are load-bearing but not defined or linked in this document. “As a worker launch does” and “as for any sandbox: error” assume `sandbox-env` Rules and `SKILL.md`/`build.md`. Someone implementing only from `sandbox-verify.md` won’t know what runs, what fails, or what the lead must do.

### Finding 5
1. **Severity:** Major  
2. **Affected Scope:** Rules, “Cap” (line 191); Decision D5 (line 54)  
3. **Discrepancy Description & Rationale:** D5 ties verify to “the feature’s cap of 2 runs” and slot waiting, while the Cap rule says the lead follows “the cap rule” from `SKILL.md` (agent concurrency via `schedule`’s `cap`/`liveRuns`). The doc never states that these are the same counter (`Get-LiveDelegateRunCount` on `*.pid` under `.xagent/runs`) or how a non-agent `delegate.ps1 -SandboxRun` probe pid relates to worker pids under task run folders.

### Finding 6
1. **Severity:** Nit  
2. **Affected Scope:** Risks and Mitigations (line 90)  
3. **Discrepancy Description & Rationale:** **Size gate** is cited as why slower sandbox checks are acceptable, but neither this doc nor a linked section defines what the size gate is or where it lives.

### Finding 7
1. **Severity:** Nit  
2. **Affected Scope:** Verification (lines 224–226)  
3. **Discrepancy Description & Rationale:** Manual checks refer to “a scratch repo on `D:\`” and “the private repo” without naming them or saying how to obtain/create them. A new teammate can’t run sign-off checks without unstated machine context.

### Finding 8
1. **Severity:** Nit  
2. **Affected Scope:** Data, “Pid file” (line 150); Rules, “One helper” (line 189)  
3. **Discrepancy Description & Rationale:** The probe run directory is `runs\probe-<hex>\` while the pid file is `runs\probe-<hex>.pid`. The doc never says the hex is shared between those two names, so readers may assume unrelated artifacts.

### Finding 9
1. **Severity:** Nit  
2. **Affected Scope:** Rules, Host runs (line 190); `feature.ps1 decision`  
3. **Discrepancy Description & Rationale:** Host verify logging is spelled out with a full `decision` text template; verify’s `test` object is updated with `where: host`. The doc does not say whether phase host runs must record anything beyond the decision line (e.g. in `state.json` or phase notes), so audit trail parity between task and phase host runs is unclear.
