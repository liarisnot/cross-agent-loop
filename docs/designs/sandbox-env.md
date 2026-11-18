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

## Alternatives Considered

### Run such repos with `-NoSandbox`

Works today with no new code. Rejected by author: it drops the protection exactly where it matters most. The first repo that needs this holds a live database that experiments must never touch.

### Grant the user's own environments in place

Add the user's `.venv` folders and interpreters to the read list, and nothing is copied. Rejected for three reasons:
*   Most interpreters are under `AppData\Roaming`, which the read list refuses on purpose.
*   A venv loads its interpreter from the `home` path in `pyvenv.cfg` on every run, so granting the `.venv` alone is not enough.
*   An editable install in the user's `.venv` points at the user's checkout, so workers would test the checkout's code, not their worktree's.

### Let each worker build its own `.venv` inside its worktree

The closest match to the user's setup, with no shared state. Rejected by author: every task would install CUDA `torch` again (several GB, minutes). The worker's `uv` cache is inside its own run home, so nothing would be reused between tasks.

### Where the environments live (D1)

*   **One root shared by all repos, picked once by the user.** Environments named by lockfile could be shared between repos. Rejected by author: two repos rarely have identical lockfiles, so the saving is close to zero. And unless everything is on C:, where `uv`'s cache is, packages are copied anyway.
*   **`%LOCALAPPDATA%\xagent\envs\`.** On the same drive as `uv`'s cache, so packages could be hard-linked and cost little disk. Rejected by author: it is inside the user's profile and inside the folder the read list refuses. Granting a hard-linked file also changes permissions on `uv`'s cached copy, which is the same file.

### Where interpreters come from (D2)

Use the user's installed Python where the read list allows it (`C:\Program Files`, `C:\Python314`), and copy only the ones under `AppData\Roaming`. That gives the same builds the user tests with, and fewer copies. Rejected by author: it needs two rules instead of one. It grants folders outside the repo, including anything later installed into them globally. And upgrading or removing one of the user's Pythons would break workers until a rebuild.

### Projects without a lockfile (D3)

*   **Install from `requirements.txt` or `pyproject.toml`, resolving versions afresh.** Kept as the fallback if the copy path's fix-up grows past one task. Not the first choice: versions can differ from what the user runs, so a worker might see failures the user doesn't.
*   **Read the packages installed in the user's `.venv` and reinstall them.** Rejected by author: the installed list doesn't record which index each package came from. CUDA `torch` and similar would need guessing, or a question to the user, and that layer of complexity shouldn't reach users.
*   **Report and stop.** Rejected by author: it forces a tool choice (`uv` with a committed lock) on the user's repo.

### How a test command finds its environment (D4)

*   **Explicit interpreter paths in every test command.** No hidden behaviour. Rejected by author: commands get long and stop matching the repo's own instructions, and a worker that types `python` gets the wrong one.
*   **A `python` shim on `PATH` that picks the environment from the current folder.** Plain `python` works everywhere. Rejected by author: it is custom code imitating `uv run`, and tools that look for `.venv` still find none.

### Grant `.envs` per run, like other read-list entries

Keeps today's rule that grants last only for a run. Rejected: on each grant and each removal, `icacls` rewrites the permissions of every file below the folder, and a CUDA `torch` environment has tens of thousands of files. Probe P2 measures it, and the plan switches back if it's fast enough.

## Detailed Implementation Plan

### Probes (lead, on the host, before the plan stage)

Run against a scratch repo, with the private repo's `src/tts/uv.lock` copied in for the large case. Results go into this section as **(probe)** notes, and change the plan where they disagree with it.

| # | Check | Pass | If it fails |
|---|---|---|---|
| P1 | A sandboxed `pwsh` in a slot, with `<worktree>\proj\.venv` a junction into `<repo>.xagent\.envs\py3.12-<hash>`, built on a `uv`-installed 3.12: `.venv\Scripts\python -c "import numpy"`, then `uv run pytest --version` with the variables in "Every sandboxed run". | Both exit 0; the environment's file count and newest write time are unchanged afterwards. | If only `uv run` fails, workers use `.venv\Scripts\python` and the SKILL text says so. If the junction itself fails, the feature stops for a redesign. |
| P2 | `icacls /grant` and `/remove` for one slot identity on that environment, timed. | Measured. Under 5 seconds for both: grants go back to per run, and the lasting grant is dropped from this plan. | Lasting grant as designed. |
| P3 | After `uv sync --frozen` into the outside environment, a test in a worktree imports the project's own module. | The module's `__file__` is under the worktree. | Use `--no-install-project`, and record which way works. |
| P4 | Copy path: a small `.venv` without a lockfile (made for the probe, with one package that has a console script and one editable install) copied onto a `uv` Python and fixed up. | `python -c "import <pkg>"` and the console script work from a worktree in a slot. | The size of the fix-up is what D3's one-task limit is judged by. |
| P5 | `git worktree remove --force` and `Remove-Item -Recurse -Force` on a worktree holding a `.venv` junction. | The environment is untouched. | Cleanup removes junctions first (planned either way, see `delegate.ps1`). |

### Data

**`<repo>.xagent\.envs\envs.json`** (written only by `SandboxEnv.psm1`, UTF-8 without BOM):

```text
{
  "version": 1,
  "approved": "<ISO time the user approved the first setup, or null>",
  "uv": "<path of the uv.exe in .envs\bin>",
  "pythons": { "3.12": "<folder under .envs\python>" },
  "envs": {
    "py3.12-<hash12>": {
      "project": "src/tts",              // repo-relative, '/' separators, '.' for the root
      "kind": "lock" | "copy",
      "hash": "<full SHA-256>",          // lock: of uv.lock bytes; copy: see below
      "python": "3.12",
      "bytes": <size on disk>,
      "built": "<ISO time>",
      "lastLinked": "<ISO time or null>"
    }
  }
}
```

The copy path's hash is the SHA-256 of the user's `.venv\pyvenv.cfg` `version_info` line, then a newline, then the sorted names of the `*.dist-info` folders in `site-packages`, one per line. A package added to the user's `.venv` changes it, so it is caught as stale (G6).

**Environment name:** `py<major.minor>-<first 12 hex of hash>`. A project whose lockfile changed gets a new folder. The old one stays until pruned, so a branch with the old lockfile still works.

### Rules

*   **Projects.** From `git -C <repo> ls-files`: every folder holding `uv.lock` is a `lock` project. Every other folder holding `pyproject.toml` or a `requirements*.txt`, with no `lock` project above it, is a `copy` project if `<repo>\<folder>\.venv\pyvenv.cfg` exists in the user's checkout, otherwise `unsupported` (`no-lock-no-venv`).
*   **Interpreter.** In order: `.python-version` in the project folder or the nearest folder above it inside the repo; for `lock`, the `requires-python` line in `uv.lock`, taking the lowest version it allows that `uv python list` offers; for `copy`, `version_info` in the user's `pyvenv.cfg`, major.minor only. If none gives an answer: `unsupported` (`python-version-unknown`).
*   **Status.** `ready`: the folder exists, `envs.json` names it for this project, and `Scripts\python.exe` exists. `stale`: an older environment exists for this project, but not one for the current hash. `missing`: neither exists.
*   **Estimate.** Disk: for `lock`, the sum of `size` over the `win_amd64` (or `py3-none-any`) wheels for the chosen Python that `uv.lock` lists, times 2.0, rounded up to 0.1 GB; for `copy`, the size of the user's `site-packages`. Each interpreter not yet in `.envs\python` adds 0.1 GB. Time: one minute per GB, at least one minute. Both are labelled estimates.
*   **`uv` itself.** The host's `uv` is found with `Get-Command uv`, and copied into `.envs\bin` when the build runs. If the host has none, the proposal says so and adds downloading `uv`'s Windows release. The version and its SHA-256 are pinned in `skills/delegate/scripts/uv-pin.json`, and the hash is checked before use. That is the only download the skill makes outside `uv`'s own.
*   **Build (`lock`).** `uv python install <ver>` with `UV_PYTHON_INSTALL_DIR=<.envs>\python`. Then `uv sync --frozen --project <user's checkout>\<project>`, with `UV_PROJECT_ENVIRONMENT=<.envs>\<name>` and `UV_PYTHON_PREFERENCE=only-managed`, plus `--no-install-project` if P3 says so. The user's checkout is only read, because the environment folder is outside it. If `uv` fails, nothing is recorded: the partial folder is deleted, and the report gives `install-failed` with the last 20 lines of `uv`'s error.
*   **Build (`copy`).** `uv venv --python <copied interpreter> <.envs>\<name>`, then copy `site-packages` across, regenerate the `Scripts` entry points from each `dist-info\entry_points.txt`, and rewrite each editable `.pth` or `direct_url.json` path that points into the user's checkout to the same path relative to the `.venv` link. P4 decides whether this stays within one task.
*   **Grant.** After a build, one `icacls <.envs> /grant *<slot SID>:(OI)(CI)RX /T` per slot identity (the slow step, once per build). Each `.envs` path granted is added to `envGrants` in `%LOCALAPPDATA%\xagent\sandbox.json`, which `-SandboxCheck -Release` reads to remove them.
*   **Prune** (after an `-Apply` build only). Delete an environment when no lockfile or `.venv` in the user's checkout now hashes to it, no existing worktree holds a junction to it, and `lastLinked` is older than 14 days or null. Delete an interpreter when no remaining environment uses it.
*   **Linking** (each sandboxed run, after the worktree exists, before the process starts). For each `ready` environment: if `<worktree>\<project>\.venv` does not exist, create a junction there and update `lastLinked`. If it exists and is a junction, replace it. If it is a real folder, leave it, and add a `sandboxNotes` line. Any project not `ready` gets a `sandboxNotes` line naming its status.
*   **Unlinking.** Before any worktree removal (`-Cleanup`, `-Cleanup -Discard`, read-only worktree removal, `-SandboxRun`, the canary), delete every `.venv` junction in the worktree. A junction is deleted as a link only (`[IO.Directory]::Delete(path, $false)`), never with a recursive delete.
*   **Environment variables** added in `Get-SandboxEnvironment` when the repo has a `.envs\bin`: `.envs\bin` appended to `PATH`; `UV_FROZEN=1`, `UV_NO_SYNC=1`, `UV_PYTHON_DOWNLOADS=never`, `UV_CACHE_DIR=<slot>:\.xagent\sandbox\uv-cache`.
*   **`-SandboxRun` diagnosis**, first match in the combined output: `is not recognized as` gives `command-not-found`; `ModuleNotFoundError` or `No module named` gives `module-missing` (plus the module name); `Access is denied`, `PermissionError` or `UnauthorizedAccess` gives `access-denied` (plus the path when present); a timeout gives `timeout`. Exit 0 gives `ok`; anything else `other`.

### Files

| File | Change | Why |
|---|---|---|
| `skills/delegate/scripts/SandboxEnv.psm1` | **New.** `Get-SandboxEnvProjects`, `Get-SandboxEnvReport`, `Invoke-SandboxEnvBuild`, `Invoke-SandboxEnvPrune`, `Add-SandboxEnvLinks`, `Remove-SandboxEnvLinks`, `Read-`/`Write-SandboxEnvIndex`. | All of the Rules above, in one module that `delegate.ps1` and `Sandbox.psm1` import. |
| `skills/delegate/scripts/uv-pin.json` | **New.** `{version, url, sha256}` for `uv`'s Windows x64 zip. | The one download outside `uv`, pinned and checked. |
| `skills/delegate/scripts/delegate.ps1` | New parameter sets `Env` (`-SandboxEnv -Repo [-Apply]`) and `SandboxRun` (`-SandboxRun -Repo -Command [-Base] [-TimeoutSec]`), each printing one JSON line. The normal run path calls `Add-SandboxEnvLinks` after the worktree is created and before Cursor starts. The three `worktree remove` sites call `Remove-SandboxEnvLinks` first. Usage text updated. | G1, G3, D4, and safe cleanup. |
| `skills/delegate/scripts/Sandbox.psm1` | `Get-SandboxEnvironment` gains the `uv` variables and the `.envs\bin` `PATH` entry. `Invoke-SandboxCanary` unlinks before its worktree removal. New `Invoke-SandboxCommand`, which `-SandboxRun` uses: `New-SandboxRun`, `Start-SandboxProcess` with `pwsh -NoProfile -Command <cmd>` in the worktree root, wait with timeout, `Stop-SandboxRun`. `Remove-SandboxLetters` (`-Release`) removes the `envGrants` grants and clears the list. | One run path for workers and probes; the lasting grant is undone on release. |
| `skills/delegate/tests/SandboxEnv.Tests.ps1` | **New.** Pester tests with fixture repos: project discovery (lock, copy, workspace root, nested `pyproject.toml` under a lock, unsupported); interpreter rules; hashes and names; status; estimates from a fixture `uv.lock`; prune rules; link and unlink on a temp folder (unlink leaves the target intact); diagnosis matching. No `uv` and no network: building and granting are tested with stubbed commands. | Each rule tested without a sandbox. |
| `skills/delegate/tests/fixtures/sandbox-env/` | **New.** Small `uv.lock`, `pyproject.toml`, `requirements.txt`, `pyvenv.cfg` and `dist-info` fixtures. | Inputs for the tests above. |
| `skills/delegate/tests/Sandbox.Tests.ps1` | Cases for the new variables in `Get-SandboxEnvironment` (present only when `.envs\bin` exists), and for `envGrants` removal on release. | Covers the `Sandbox.psm1` changes. |
| `skills/delegate/tests/DelegateLaunch.Tests.ps1` | Parameter-set cases for `-SandboxEnv` and `-SandboxRun` (accepted combinations, refusals such as `-SandboxRun` with `-NoSandbox`). | The CLI surface. |
| `skills/delegate/SKILL.md` | Invocation table rows for `-SandboxEnv` and `-SandboxRun`. In "Sandbox", a section "Environments" (what is built, where, the one approval, rebuilds without asking, `.venv` links, read-only environments). In "Breaking work into tasks" or the loop, before the first worker: run `-SandboxEnv`; on a proposal, ask once; then `-SandboxRun` one test command. | `delegate`-only leads do the same as `feature` (G5). |
| `skills/feature/scripts/feature.ps1` | `doctor` takes an optional `-Repo`. With it, adds a non-required check `sandbox-env` built from the `-SandboxEnv` report: ok when every project is `ready`, otherwise the detail lists what is missing, with the estimate. | G5. |
| `skills/feature/tests/feature.Tests.ps1` | `doctor -Repo` case with a stubbed report: check present, ok or not, detail text. | Covers the doctor change. |
| `skills/feature/SKILL.md` | `doctor` may pass `-Repo <repo>`. | It currently says doctor passes neither. |
| `skills/feature/stages/build.md` | Before the first worker of the build: `-SandboxEnv`; proposal and one question if this repo was never approved; `-Apply`; then `-SandboxRun` with each phase's `test` command. Failure handling: `module-missing` or `command-not-found` with all environments `ready` means the repo's own setup is incomplete, and that is a problem stop; `access-denied` is a sandbox problem stop. | G5 in the feature flow. |
| `docs/test-plan.md` | Rows for P1–P5 and the live checks below. | Records measured behaviour. |
| `docs/HANDOFF.md` | State of the feature at sign-off. | Handoff. |

### Verification

*   **Unit:** the full Pester suites in `skills/delegate/tests` and `skills/feature/tests` pass.
*   **Live, on this machine** (lead, at sign-off):
    1.  `-SandboxEnv` on the private repo reports six `lock` projects, three interpreters and an estimate. The probe command fails first with `module-missing`.
    2.  After `-Apply`, `-SandboxRun` with one test file from each project exits 0.
    3.  A sandboxed worker on a one-line task in that repo runs `uv run pytest <one test>` and passes.
    4.  `-Cleanup` of that worker leaves every environment in `.envs` intact (file counts before and after).
    5.  `pip install` inside a sandboxed run fails with an access error.
    6.  `-SandboxCheck -Release`, then `-Reserve` again: the `envGrants` grants are removed, then re-granted on the next build.
    7.  The existing `-SandboxCheck -Repo` canary still passes all rows.
