# `sandbox-env`: environments a sandboxed worker can reach

*   **Author:** Eugene Chin
*   **Status:** Draft
*   **Date:** 2026-11-16

--------------------------------------------------------------------------------

## Overview

Since `worker-sandbox` (docs/designs/worker-sandbox.md), every `delegate` worker, review lens and council seat runs in a Windows AppContainer. The container can read its worktree, `C:\Windows`, `C:\Program Files` and the paths on an explicit read list, and nothing else. Its `PATH` is fixed: Windows, PowerShell 7, Git, then read-list entries marked `addToPath`.

A repo whose tests need a language runtime or packages outside those places cannot be built by a sandboxed worker. Today nothing notices this until a worker fails, and the fix is a hand edit of `%LOCALAPPDATA%\xagent\sandbox.json` plus whatever setup the toolchain needs.

This feature makes `delegate` find the problem before any worker starts, explain it, propose a fix with its cost, and on the user's approval set up an environment the sandbox can reach. It follows the pattern the sandbox already uses for drive letters: the skill detects, asks once, then does the work. `feature` calls it from `doctor` and before the build starts.

## The Problem

The first real repo it was tried on, a private Python project, shows the failure. The repo is split into subprojects, each with its own `pyproject.toml`, `uv.lock` and `.venv` folder:

*   **The environments are not in a worktree.** Each `.venv` sits inside the user's checkout and is ignored by git, so a worker's fresh worktree has none of them.
*   **The interpreters are out of reach.** The subprojects ask for different Pythons: most use a 3.12 that `uv` installed under `AppData\Roaming\uv\python`, one uses `C:\Program Files\Python311` and one uses `C:\Python314`. The sandbox denies the whole profile, the read list refuses anything under `AppData\Roaming` on purpose (other programs keep credentials there), and folders at the root of `C:` other than `Windows` and `Program Files` are denied. Only the 3.11 is readable, and it is not on the sandbox `PATH`.
*   **The tool that builds the environments is out of reach.** `uv` itself is in `~\.local\bin`, under the profile.
*   **Some packages are large and come from their own index.** The text-to-speech subproject needs a CUDA build of `torch` from PyTorch's index (declared in its `pyproject.toml`), several gigabytes once installed.
*   **So a sandboxed worker cannot run a single test of that repo.** Running its workers with `-NoSandbox` would work, but it removes the protection that repo most needs: it holds a live database that experiments must never touch.

The general shape: the sandbox is safe because it sees little, and a repo's toolchain is usually installed where it can't see. Each repo's setup is different, and the user should not have to know the sandbox's rules to fix it.

## Goals

*   **G1. Detect before a worker runs.** `delegate.ps1` can run a plain command (no Cursor) inside the sandbox, in a fresh worktree of the repo, and return its exit code, the first lines of its output and a diagnosis: command not found, module or package missing, access denied, or other. It takes seconds and uses no Cursor allowance.
*   **G2. Propose, with the cost, before changing anything.** A diagnosis that has a known fix produces a proposal in plain words: what will be created, where, roughly how much disk and time, and what read-list entry will be added. Nothing is created until the user says yes, once per repo. After that, rebuilds for a changed lockfile run without asking and are reported in one line.
*   **G3. Set up Python on approval.** For a Python project the skill finds the interpreter and packages it declares, builds an environment the sandbox can read, and adds it to the read list. A repo with several projects gets one environment per project. Pass: the G1 probe that failed now passes.
*   **G4. No hand setup.** The user never edits `sandbox.json`, never runs a setup command and never needs to know the sandbox's rules. Every step is proposed in chat and run by the skill.
*   **G5. Built into the flow.** `feature.ps1 doctor` reports whether the repo's environment is ready for the sandbox. Before the build starts, `feature` runs each phase's test command once in the sandbox, so a broken environment is found before the first worker's time is spent. A lead using `delegate` alone runs the same probe before its first worker.
*   **G6. Stale environments are caught.** When a project's lockfile changes, or the sandboxed probe starts failing, the same detection offers to bring the environment up to date.
*   **G7. The sandbox does not get wider than needed.** Each fix grants read access to the environment's own folder only. Nothing under the profile root, `AppData\Roaming`, `.ssh`, `.aws`, `.gnupg` or Cursor's folders is ever granted, and the existing read-list refusals stay as they are.

## Non-Goals

*   **Every language in v1.** v1 sets up Python only. For Node, workers can already run `npm ci` inside their own writable worktree with the network on, so the probe checks that and nothing is set up. For any other toolchain, the skill reports what is missing and stops at a proposal the user acts on.
*   **Changing the user's own environments.** The skill reads the user's checkout and tools (to learn what each project needs) and never changes them.
*   **GPU access.** If a test needs the GPU and the sandbox cannot reach it, the probe reports that. Making the GPU reachable from an AppContainer is out of scope.
*   **Dependency management.** The skill installs what a project already declares. It does not resolve, pin or upgrade dependencies, and does not write lockfiles into the repo.
*   **Secrets.** No credentials, tokens or private package-index logins are copied into the environment.

## Open Questions

Where the environments live, where the interpreters come from, projects without a lockfile and several environments in one repo were settled in the Technical Plan (D1–D4). Still open:

*   **Editable installs.** Whether a worker's tests import the worktree's code through the linked environment (probe P3).
*   **Disk.** One environment per project with CUDA `torch` costs several gigabytes, copied, not hard-linked, because `uv`'s cache is on another drive. The proposal states the estimate; there is no cap.
*   **GPU.** Whether an AppContainer can use the GPU at all is unverified.

## Technical Plan

### Decisions so far

| # | Decision | Why |
|---|---|---|
| D1 | Environments live per repo in `<repo>.xagent\.envs\`, one folder per environment, named `py<major.minor>-<first 12 hex of the lockfile's SHA-256>`. | Everything for a repo sits beside its worktrees and goes away with it. Sharing one root across repos saves almost nothing: lockfiles rarely match, and `uv`'s cache is on another drive, so packages are copied either way. A task id can't start with `.`, so no worktree can land on `.envs`. |
| D2 | Interpreters are always copied with `uv` into `<repo>.xagent\.envs\python\`. The user's installed Pythons are never granted. | One rule for every case; nothing outside `<repo>.xagent` is granted; upgrading or removing one of the user's Pythons never breaks a worker. |
| D3 | A project with `uv.lock` is installed with `uv sync --frozen`. A project without one, whose checkout has a `.venv`, is copied file by file onto the copied interpreter, then fixed up. If that fix-up grows past one normal task, it is replaced by installing from `requirements.txt` or `pyproject.toml`. | The lockfile is the record the user committed, with every package's version and download address. Reading a `.venv` and reinstalling would mean guessing where each package came from. |
| D4 | Before each sandboxed run, the host links each project's environment into the worktree as `.venv` (a directory junction). A copy of `uv.exe` is on the sandbox `PATH`. | The worktree then looks like the user's checkout. `.venv\Scripts\python -m pytest`, `uv run pytest` and the repo's own instructions work unchanged. |
| D5 | The skill decides by itself wherever one answer is defensible. The user is asked once per repo, to approve the disk and time cost of the first setup. | The skills exist to make a feature faster; every question stalls the run. |

### What a project is

A project is a folder in the repo's tracked files that either holds `uv.lock` (D3's main path), or holds `pyproject.toml` or `requirements*.txt` and has a `.venv` in the user's checkout (D3's copy path). A `uv` workspace has one `uv.lock` at its root and one `.venv` there, so it is one project. Projects are found with `git ls-files`, so ignored folders (the user's own `.venv` folders, other tools' worktrees) are never scanned.

A project's interpreter version comes from, in order: `.python-version` in the project folder or above it; the `requires-python` line recorded in `uv.lock`; the `version_info` in the user's `.venv\pyvenv.cfg` (copy path only). The newest patch release of that minor version is used. `uv` takes it from its own cache, or downloads it.

### Components

```text
delegate.ps1
  -SandboxEnv [-Apply]          --> SandboxEnv.psm1 (new): find, report, build, prune
  -SandboxRun -Command "<cmd>"  --> Sandbox.psm1 run path, no Cursor
  every sandboxed run           --> link .venv junctions; .envs\bin on PATH

feature.ps1 doctor              --> delegate.ps1 -SandboxEnv (report only)
stages/build.md, delegate SKILL --> before the first worker: -SandboxEnv, then
                                    -SandboxRun each phase's test command
```

*   **`SandboxEnv.psm1` (new, in `skills/delegate/scripts/`).** Finds the projects, works out each one's interpreter and environment name, compares them with what exists in `.envs`, and builds what is missing. It keeps `.envs\envs.json`: for each environment, the project folder, lockfile hash, interpreter, size and the last time it was linked into a worktree; and for the repo, whether the user approved the first setup.
*   **`delegate.ps1 -SandboxEnv -Repo <repo>`.** Prints one JSON object: each project with a status (`ready`, `missing`, `stale`, or `unsupported` with a reason) and, for anything to build, a proposal: what, where, estimated disk and estimated time. The disk estimate is the sum of the `win_amd64` wheel sizes that `uv.lock` records, times an unpack factor; nothing is downloaded to estimate it. With `-Apply` it builds what the report proposed, records the approval, and prunes environments that no current lockfile names and that no worktree has linked for 14 days.
*   **`delegate.ps1 -SandboxRun -Repo <repo> -Command "<cmd>" [-Base <ref>] [-TimeoutSec <n>]` (G1).** Creates a detached worktree, links the environments, runs the command in a sandbox slot with the same grants and `PATH` a worker gets, removes the worktree, and prints one JSON object: `exitCode`, the first 40 lines of output, `seconds` and `diagnosis` (`ok`, `command-not-found`, `module-missing`, `access-denied`, `timeout`, `other`). The diagnosis is matched from the output: `is not recognized`; `ModuleNotFoundError` or `No module named`; `Access is denied` or `PermissionError`. It takes one of the two slots, like any run.
*   **Every sandboxed run** (worker, lens, council seat, probe). Before the process starts, the host creates `<worktree>\<project>\.venv` as a junction to the project's environment, for every project whose environment is `ready`, and records the link time. It puts `.envs\bin` (holding `uv.exe`) on `PATH` and sets `UV_FROZEN=1`, `UV_NO_SYNC=1`, `UV_PYTHON_DOWNLOADS=never` and `UV_CACHE_DIR` inside the run's own home, so `uv run` uses the linked environment and never changes it. A missing or stale environment doesn't stop the run; it is listed in `sandboxNotes`. A worker that tries `pip install` or `uv add` gets an access error, because the environment is read-only.
*   **Grants.** Read-list entries are granted per run today, and `icacls` rewrites every file below the folder on each grant and each removal. A CUDA `torch` environment has tens of thousands of files. So `.envs` instead gets one lasting read grant for the two slot identities, set when an environment is built and removed by `-SandboxCheck -Release`. It is not a `sandbox.json` entry: the user's read list and its refusals are unchanged (G7). The cost: a worker for one repo could read another repo's `.envs`, which holds third-party package files only.
*   **`feature.ps1 doctor`** adds the `-SandboxEnv` summary for the repo, and the proposal when something is missing.
*   **`stages/build.md` and `delegate`'s SKILL.md.** Before the first worker, the lead runs `-SandboxEnv`. If something is missing and the user hasn't approved this repo's first setup, the lead shows the proposal and asks once. After that, rebuilds on that repo (for example after a lockfile change) run without asking and are reported in one line. Then the lead runs each phase's test command once with `-SandboxRun`. A failure is fixed, or reported, before any worker starts.

### Flow on first use

```text
lead: delegate.ps1 -SandboxEnv -Repo R
  -> 6 projects, 0 ready; build 3 interpreters and 6 environments, about 9 GB, about 6 min
lead -> user: the proposal in plain words, one question
user: yes
lead: delegate.ps1 -SandboxEnv -Repo R -Apply
  -> uv python install 3.11 3.12 3.14        (UV_PYTHON_INSTALL_DIR = R.xagent\.envs\python)
  -> for each project: uv sync --frozen      (UV_PROJECT_ENVIRONMENT = R.xagent\.envs\py3.12-<hash>)
  -> lasting read grant on R.xagent\.envs for both slots
lead: delegate.ps1 -SandboxRun -Repo R -Command "<phase 1 test command>"
  -> ok, so the build starts
```

`uv sync` installs the project itself in editable mode, pointing at the folder it was built from. A worker must import its own worktree's code, not the user's checkout. Probe P3 settles how: build with `--no-install-project` and rely on the test runner's own path setup, or rewrite the editable entry to a path relative to the `.venv` link.

### Probes before the plan

*   **P1.** In a sandbox slot, a `.venv` junction in the worktree pointing into `<repo>.xagent\.envs`, on a `uv`-installed Python: `python -c "import numpy"` and `uv run pytest --version` both pass with the variables above, and nothing is written into the environment.
*   **P2.** Time an `icacls` grant and removal on a built CUDA `torch` environment, to confirm the lasting grant is needed.
*   **P3.** After `uv sync --frozen` into an outside environment, a test run in a worktree through the link imports the worktree's code, not the checkout's.
*   **P4.** The D3 copy path on one small `.venv` without a lockfile, to size the fix-up code against the one-task limit.
