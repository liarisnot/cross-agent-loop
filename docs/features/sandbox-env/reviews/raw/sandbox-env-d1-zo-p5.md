<!-- persona: zoom_out | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer instructions exactly.The task is a Stage 5 zoom-out review of the sandbox environment design. I'll read the design and the related sandbox, delegate, and feature files it depends on.The design is in hand. Next I’ll check the sandbox, delegate, and feature code it plans to extend so reuse and fit are judged against what already exists.Context is sufficient. The objective is clear: a sandboxed worker cannot see a repo's Python toolchain, the failure shows up only after a worker starts, and turning the sandbox off is unacceptable on a repo with a live database. The design detects that, asks once, and builds an environment the sandbox can read. Drive-letter setup is the right pattern to copy. What follows is where the design adds a second system, or specifies installer behavior, beyond that.

## Findings

### 1. Lasting `envGrants` are a second permission system

**Severity:** Major  
**Affected scope:** Components, "Grants"; Rules, "Grant"; Alternatives, "Grant `.envs` per run"

The sandbox already grants a folder for one run and takes it back at the end. `Get-SandboxGrantList` adds read-list paths as `(OI)(CI)RX`, `New-SandboxRun` records them in the slot ledger, and `Remove-SandboxGrants` removes them. `icacls` is called without `/T`. The module notes that `icacls` still rewrites every descendant because it refreshes inheritance, which is why attribute-only entries go through `NtSetSecurityObject` under the `Local\xagent-acl` lock. A dead run's grants are cleared from that ledger before the next run uses the slot.

The plan does not use that path. It runs `icacls /grant … /T` once over all of `<repo>.xagent\.envs`, for both slot identities, stores the paths in a new `sandbox.json` key `envGrants`, and removes them only in `-SandboxCheck -Release`. `/T` is the walk the current grant code avoids. The new key never passes `Resolve-SandboxReadEntry`, so the protected-folder refusals are not on this path. Goal G7 says each fix grants that environment's own folder. This grant is the parent of every environment, held by both slots for the life of the reservation, so a worker on one repo can read another repo's `.envs`. That breaks the sandbox rule that a run cannot read other repos.

Probe P2 is the right measurement, and it has not been run. Until it says a per-run grant is too slow, the grant should be one row from `Get-SandboxGrantList` for this repo's environment folder, written into the slot ledger and removed with the run. If P2 shows the walk is too expensive, keep the durable access control entry as a row that same ledger knows not to strip, still checked by `Resolve-SandboxReadEntry`.

### 2. The no-lockfile copy path is a second package installer

**Severity:** Major  
**Affected scope:** Decision D3; "What a project is"; Rules, "Build (`copy`)" and the copy-path hash; Probe P4; Alternatives, "Projects without a lockfile"

The repo that motivates the feature has a `uv.lock` per subproject. v1 already handles every non-Python toolchain by reporting it and stopping. The copy path is a different installer: read the user's `.venv`, copy `site-packages`, regenerate `Scripts` from `dist-info\entry_points.txt`, and rewrite editable `.pth` and `direct_url.json` paths. The plan already says to throw that away if it grows past one task and install from `requirements.txt` or `pyproject.toml` instead. The non-goal on dependency management says the skill installs what the project declares and does not reconstruct a resolve.

For v1, a project without `uv.lock` should be `unsupported` (the discovery rule already has `no-lock-no-venv` for the case with no `.venv`). Drop `kind: copy`, the composite `.venv` hash, the entry-point rewriter, and P4. `Get-SandboxFileHash` in `Sandbox.psm1` is the existing SHA-256 helper for the lockfile hash on the path that remains.

### 3. The junction does not decide which tree the tests import

**Severity:** Major  
**Affected scope:** Open Questions, "Editable installs"; "Flow on first use"; Decision D4; Probe P3; Rules, "Build (`lock`)"

Goal G3 is met when the probe that failed then passes. The failure that matters is a worker running that repo's tests against its own worktree, not against the user's checkout. `uv sync --frozen` into an environment outside the worktree records the checkout it was built from. Linking `.venv` into the worktree makes `python` and `uv run` find the environment. It does not change that recorded path. P3 is still open, and the build rule is already "`--no-install-project` if P3 says so," plus the copy-path path rewriter.

Those are two different data flows. One leaves the project out of the environment and lets the test command see the worktree. The other rewrites install metadata so the link is the path the environment records. P3 picks one of them. Until it does, the plan should not specify the sync flags or the `.pth` rewriter. The junction, the read grant, and `uv` on `PATH` are the parts that stand either way.

### 4. Every sandboxed run rewrites a shared index

**Severity:** Major  
**Affected scope:** Components, "Every sandboxed run"; Rules, "Linking" and "Prune"

Linking a ready environment into a fresh worktree belongs on the host, before the process starts, including the canary and the three `worktree remove` sites in `delegate.ps1`. Writing `envs.json` there does not. `feature` starts two workers in the same message when `schedule` returns two tasks. Both would update `lastLinked` in one file that also holds the user's approval. The sandbox already serializes access-control edits because two writers drop each other's changes. This index has the same shape and no lock.

Prune already treats an environment as live when a worktree holds a junction to it. `lastLinked` only feeds the 14-day clock after those worktrees are gone. Record that time in a way that review lenses, council seats, and a parallel worker do not rewrite the approval record. Linking on read-only runs can stay. Authoring the index on those runs should not.

### 5. A pinned `uv` download duplicates the doctor pattern

**Severity:** Nit  
**Affected scope:** Rules, "`uv` itself"; Files, `uv-pin.json`

Copying the host `uv` from `Get-Command uv` into `.envs\bin` matches the rest of the plan. Fetching a pinned Windows zip when the host has no `uv` is a second installer: URL, hash file, and a network fetch no other skill performs. `feature` doctor already reports a missing `python`, Pester, or Cursor CLI and stops. A proposal line that `uv` is missing is the same pattern. The projects this feature builds are already `uv` projects.

### 6. The Node non-goal describes a PATH the sandbox does not have

**Severity:** Nit  
**Affected scope:** Non-Goals, "Every language in v1"

Leaving Node as "probe and report" is the right v1 cut. The reason given is that workers can already run `npm ci` in the worktree. `Get-SandboxEnvironment` builds `PATH` from Windows, PowerShell 7, Git, and read-list entries marked `addToPath`. A normal Node install under `C:\Program Files\nodejs` is readable and is not on that path. The user `PATH` in the registry is not copied into the container. The scope decision can stand. It should not be justified by an `npm` that a default sandbox cannot start, or the Python module becomes the template for the next language.

### 7. Diagnosis matchers and estimate constants are below the report contract

**Severity:** Nit  
**Affected scope:** Rules, "Estimate" and "`-SandboxRun` diagnosis"; Files, the `SandboxEnv.psm1` function list

The contract is the right level: project status `ready`, `missing`, `stale`, or `unsupported`; a proposal with disk and time; a probe result with `exitCode` and a diagnosis of `ok`, `command-not-found`, `module-missing`, `access-denied`, `timeout`, or `other`. The English substrings, the 2.0 unpack factor, the 0.1 GB rounding, and the eight function names are task internals. The matchers in particular will stick to one host language. Keep the categories in the design.

## What already fits

`-SandboxRun` through `New-SandboxRun`, `Start-SandboxProcess`, and `Stop-SandboxRun` is the existing slot path. `Get-SandboxEnvironment` is the right place for `.envs\bin` and the `UV_*` variables. Cleanup belongs on the current worktree-remove sites and `Invoke-SandboxCanary`. `doctor` already has a non-required `sandbox` check next to `Test-SandboxSupport`. One approval per repo matches the drive-letter ask. Copying interpreters into `<repo>.xagent\.envs` instead of granting `AppData\Roaming` matches the read-list refusals.
