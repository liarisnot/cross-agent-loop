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
*   **G2. Propose, with the cost, before changing anything.** A diagnosis that has a known fix produces a proposal in plain words: what will be created, where, and roughly how much disk and time. Nothing is created until the user says yes, once per repo. After that, rebuilds for a changed lockfile run without asking and are reported in one line.
*   **G3. Set up Python on approval.** For a Python project the skill finds the interpreter and packages it declares, builds an environment the sandbox can read, and makes it visible to every sandboxed run of that repo. A repo with several projects gets one environment per project. Pass: the G1 probe that failed now passes.
*   **G4. No hand setup.** The user never edits `sandbox.json`, never runs a setup command and never needs to know the sandbox's rules. Every step is proposed in chat and run by the skill. The one prerequisite is `uv` on the host, which the README lists.
*   **G5. Built into the flow.** `feature.ps1 doctor` reports whether the repo's environment is ready for the sandbox. Before the build starts, `feature` runs each phase's test command once in the sandbox, so a broken environment is found before the first worker's time is spent. A lead using `delegate` alone runs the same probe before its first worker.
*   **G6. Stale environments are caught.** When a project's lockfile changes, or the sandboxed probe starts failing, the same detection offers to bring the environment up to date.
*   **G7. The sandbox does not get wider than needed.** A run is granted read access to the environments it links, for that run only, through the same per-run grant list as every other path. Nothing under the profile root, `AppData\Roaming`, `.ssh`, `.aws`, `.gnupg` or Cursor's folders is ever granted, and the existing read-list refusals stay as they are.

## Non-Goals

*   **Every language in v1.** v1 sets up Python only. For any other toolchain the probe reports what is missing and stops at a proposal the user acts on. Node is in that group: the sandbox `PATH` does not include `C:\Program Files\nodejs`, so `node` and `npm` are not found even where they are installed.
*   **Installing `uv`.** The skill needs `uv` on the host, and the README says so. If it is missing, the report says so and stops; adding `uv` to a machine is the user's setup choice.
*   **Changing the user's own environments.** The skill reads the user's checkout and tools (to learn what each project needs) and never changes them.
*   **GPU access.** If a test needs the GPU and the sandbox cannot reach it, the probe reports that. Making the GPU reachable from an AppContainer is out of scope.
*   **Dependency management.** The skill installs what a project declares. It does not pin or upgrade dependencies and never writes a lockfile into the repo. A project without `uv.lock` is resolved afresh, outside the repo, from what it declares.
*   **Secrets.** No credentials, tokens or private package-index logins are copied into the environment.

## Open Questions

*   **GPU.** Whether an AppContainer can use the GPU at all is unverified.

Settled since the first draft: editable installs (probe P3), disk (no cap; unused environments are pruned after 14 days and every proposal shows the total size of `.envs`), and projects without a lockfile (D3).

## Technical Plan

### Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Environments live per repo in `<repo>.xagent\.envs\`, one folder per environment, named `py<major.minor>-<first 12 hex of the project's hash>`. | Everything for a repo sits beside its worktrees and goes away with it. Sharing one root across repos saves almost nothing: lockfiles rarely match, and `uv`'s cache is on another drive, so packages are copied either way. A task id can't start with `.`, so no worktree can land on `.envs`. |
| D2 | Interpreters are always copied with `uv` into `<repo>.xagent\.envs\python\`. The user's installed Pythons are never granted. | One rule for every case; nothing outside `<repo>.xagent` is granted; upgrading or removing one of the user's Pythons never breaks a worker. |
| D3 | A project with `uv.lock` is installed with `uv sync --frozen`. A project without one is resolved afresh with `uv` from its `pyproject.toml` or `requirements*.txt`, outside the repo. | The lockfile is the record the user committed, with every package's version and download address. Without one, a fresh resolve is the only automatic answer that doesn't guess where installed packages came from; versions may differ slightly from the user's `.venv`. |
| D4 | Before each sandboxed run, the host links each project's environment into the worktree as `.venv` (a directory junction). A copy of `uv.exe` is on the sandbox `PATH`. | The worktree then looks like the user's checkout. `.venv\Scripts\python -m pytest`, `uv run pytest` and the repo's own instructions work unchanged. |
| D5 | The skill decides by itself wherever one answer is defensible. The user is asked once per repo, to approve the disk and time cost of the first setup. | The skills exist to make a feature faster; every question stalls the run. |
| D6 | Each run is granted the environments it links, the interpreters they use and `.envs\bin`, as rows of the existing per-run grant list, removed when the run ends. | No second permission system; a worker on one repo cannot read another repo's environments. Probe P2: granting and removing the largest environment (4.8 GB, 29,568 files) takes about 3 seconds each. |
| D7 | An editable install of the project is redirected to the run's worktree through the `XAGENT_WORKTREE` variable. | `uv sync` records the folder it built from, which is the user's checkout. Probe P3 found that a relative path works for `python.exe` but not for `uv run`, which resolves the link to its real path. |

### What a project is

A project is a folder in the repo's tracked files that holds `uv.lock` (a `lock` project), or holds `pyproject.toml` or `requirements*.txt` with no `lock` project above it (a `resolve` project). A `uv` workspace has one `uv.lock` at its root and one `.venv` there, so it is one project. Projects are found with `git ls-files`, so ignored folders (the user's own `.venv` folders, other tools' worktrees) are never scanned.

A project's interpreter version comes from, in order: `.python-version` in the project folder or above it; `requires-python` in `uv.lock` or `pyproject.toml`; the `version_info` in the user's `.venv\pyvenv.cfg`, if there is one. The newest patch release of that minor version is used. `uv` takes it from its own cache, or downloads it.

### Components

```text
delegate.ps1
  -SandboxEnv [-Apply]          --> SandboxEnv.psm1 (new): find, report, build, prune
  -SandboxRun -Command "<cmd>"  --> Sandbox.psm1 run path, no Cursor
  every sandboxed run           --> link .venv junctions; grant them for the run;
                                    .envs\bin on PATH

feature.ps1 doctor              --> delegate.ps1 -SandboxEnv (report only)
stages/build.md, delegate SKILL --> before the first worker: -SandboxEnv, then
                                    -SandboxRun each phase's test command
```

*   **`SandboxEnv.psm1` (new, in `skills/delegate/scripts/`).** Finds the projects, works out each one's interpreter and environment name, compares them with what exists in `.envs`, and builds what is missing. It keeps `.envs\envs.json`: what was built for each environment, and whether the user approved the first setup. Only the build writes it.
*   **`delegate.ps1 -SandboxEnv -Repo <repo>`.** Prints one JSON object: each project with a status (`ready`, `missing`, `stale`, or `unsupported` with a reason) and, for anything to build, a proposal: what, where, estimated disk and estimated time, plus the current size of `.envs`. The disk estimate comes from the wheel sizes `uv.lock` records; nothing is downloaded to estimate it. With `-Apply` it builds what the report proposed, records the approval, and prunes environments nothing has used for 14 days.
*   **`delegate.ps1 -SandboxRun -Repo <repo> -Command "<cmd>" [-Base <ref>] [-TimeoutSec <n>]` (G1).** Creates a detached worktree, links the environments, runs the command in a sandbox slot with the same grants and `PATH` a worker gets, removes the worktree, and prints one JSON object: `exitCode`, the first 40 lines of output, `seconds` and `diagnosis` (`ok`, `command-not-found`, `module-missing`, `access-denied`, `timeout`, `other`), matched from the output. It takes one of the two slots, like any run.
*   **Every sandboxed run** (worker, lens, council seat, probe). Before the process starts, the host creates `<worktree>\<project>\.venv` as a junction to the project's environment, for every project whose environment is `ready`, and adds read grants for those environments to the run's grant list (D6). It puts `.envs\bin` (holding `uv.exe`) on `PATH`, sets `XAGENT_WORKTREE` (D7), and sets `uv` variables so that `uv run` uses the linked environment and never changes it. A missing or stale environment doesn't stop the run; it is listed in `sandboxNotes`. A worker that tries `pip install` or `uv add` gets an access error, because the environment is read-only.
*   **`feature.ps1 doctor`** adds the `-SandboxEnv` summary for the repo, and the proposal when something is missing.
*   **`stages/build.md` and `delegate`'s SKILL.md.** Before the first worker, the lead runs `-SandboxEnv`. If something is missing and the user hasn't approved this repo's first setup, the lead shows the proposal and asks once. After that, rebuilds on that repo (for example after a lockfile change) run without asking and are reported in one line. Then the lead runs each phase's test command once with `-SandboxRun`. A failure is fixed, or reported, before any worker starts.

### Flow on first use

```text
lead: delegate.ps1 -SandboxEnv -Repo R
  -> 6 projects, 0 ready; build 3 interpreters and 6 environments, about 9 GB
lead -> user: the proposal in plain words, one question
user: yes
lead: delegate.ps1 -SandboxEnv -Repo R -Apply
  -> uv python install 3.11 3.12 3.14        (UV_PYTHON_INSTALL_DIR = R.xagent\.envs\python)
  -> for each project: uv sync --frozen      (UV_PROJECT_ENVIRONMENT = R.xagent\.envs\py3.12-<hash>)
lead: delegate.ps1 -SandboxRun -Repo R -Command "<phase 1 test command>"
  -> link .venv junctions, grant them for this run, run, remove grants
  -> ok, so the build starts
```

## Alternatives Considered

### Run such repos with `-NoSandbox`

Works today with no new code. Rejected by author: it drops the protection exactly where it matters most. The first repo that needs this holds a live database that experiments must never touch.

### Grant the user's own environments in place

Add the user's `.venv` folders and interpreters to the read list, and nothing is copied. Rejected for three reasons:
*   Most interpreters are under `AppData\Roaming`, which the read list refuses on purpose.
*   A venv loads its interpreter from the `home` path in `pyvenv.cfg` on every run, so granting the `.venv` alone is not enough.
*   An editable install in the user's `.venv` points at the user's checkout, so workers would test the checkout's code, not their worktree's.

### Let each worker build its own `.venv` inside its worktree

The closest match to the user's setup, with no shared state. Rejected by author: every task would install CUDA `torch` again (several GB). The worker's `uv` cache is inside its own run home, so nothing would be reused between tasks.

### Where the environments live (D1)

*   **One root shared by all repos, picked once by the user.** Environments named by lockfile could be shared between repos. Rejected by author: two repos rarely have identical lockfiles, so the saving is close to zero. And unless everything is on C:, where `uv`'s cache is, packages are copied anyway.
*   **`%LOCALAPPDATA%\xagent\envs\`.** On the same drive as `uv`'s cache, so packages could be hard-linked and cost little disk. Rejected by author: it is inside the user's profile and inside the folder the read list refuses. Granting a hard-linked file also changes permissions on `uv`'s cached copy, which is the same file.

### Where interpreters come from (D2)

Use the user's installed Python where the read list allows it (`C:\Program Files`, `C:\Python314`), and copy only the ones under `AppData\Roaming`. That gives the same builds the user tests with, and fewer copies. Rejected by author: it needs two rules instead of one. It grants folders outside the repo, including anything later installed into them globally. And upgrading or removing one of the user's Pythons would break workers until a rebuild.

### Projects without a lockfile (D3)

*   **Copy the user's `.venv` onto a copied interpreter and fix up its scripts and paths.** The closest match to what the user runs. Rejected after review: it is a second package installer (regenerating entry points, rewriting install records), the repo that motivated the feature doesn't need it, and the fresh resolve covers the same projects with `uv`'s own code.
*   **Read the packages installed in the user's `.venv` and reinstall them.** Rejected by author: the installed list doesn't record which index each package came from. CUDA `torch` and similar would need guessing, or a question to the user, and that layer of complexity shouldn't reach users.
*   **Report and stop.** Rejected by author: it stops the run for a question the skill can answer itself (D5).

### How a test command finds its environment (D4)

*   **Explicit interpreter paths in every test command.** No hidden behaviour. Rejected by author: commands get long and stop matching the repo's own instructions, and a worker that types `python` gets the wrong one.
*   **A `python` shim on `PATH` that picks the environment from the current folder.** Plain `python` works everywhere. Rejected by author: it is custom code imitating `uv run`, and tools that look for `.venv` still find none.

### A lasting read grant on all of `.envs` (D6)

One grant per build, for both slot identities, removed on `-SandboxCheck -Release`. It was planned on the assumption that per-run grants on a large environment are slow. Rejected after review and probe P2: per-run grants take seconds, and a lasting grant is a second permission system outside the grant ledger and the read-list checks, which lets a worker on one repo read every repo's `.envs`.

### Download `uv` when the host has none

A pinned release with a checked hash, so no prerequisite is left. Rejected by author: adding `uv` to a machine is a setup change the user should choose, and it would be the only download the skill makes itself. The README lists `uv` as required.

## Detailed Implementation Plan

### Probes

Run by the lead on 2026-11-17 against a scratch repo (a small `hatchling` package with `numpy` and `pytest`), with the private repo's text-to-speech `pyproject.toml` and `uv.lock` copied in for the large case.

| # | Check | Result |
|---|---|---|
| P1 | A sandboxed `pwsh` in a slot, with `<worktree>\.venv` a junction into `.envs`, built on a `uv`-installed 3.12, with `.envs` and `.envs\bin` granted. | **Pass.** `import numpy` and `uv run pytest` work. `uv` is found on `PATH` (`Get-Command`; `where.exe` does not find it). `uv pip install` fails with "Access is denied". The environment's file count (4,843) and newest write time are unchanged afterwards. |
| P2 | `icacls /grant (OI)(CI)RX` and `/remove`, without `/T`, for one slot identity on a built CUDA `torch` environment. | **Pass.** Build 13 s with packages already in `uv`'s cache (4.77 GB, 29,568 files, copied across drives). Grant 2.7 s, removal 2.8 s. Grants stay per run (D6). |
| P3 | After `uv sync --frozen` into the outside environment, a test in a worktree imports the project's own module. | **Fails as built**: the editable install points at the checkout the environment was built from, so `uv run pytest` gets `ModuleNotFoundError`. A relative path in the `.pth` works for `python.exe` but not for `uv run`. **Fix that passes:** the `.pth` reads `XAGENT_WORKTREE` (D7). Projects with no `[build-system]`, like every project in the private repo, are not installed into the environment and need nothing. |
| P5 | `git worktree remove --force` on a worktree holding a `.venv` junction. | The environment is untouched, but the junction itself is left behind and the folder is not fully removed. Cleanup deletes junctions first (see Rules). |

### Data

**`<repo>.xagent\.envs\envs.json`** (written only by `-SandboxEnv -Apply`, under a named lock, UTF-8 without BOM):

```text
{
  "version": 1,
  "approved": "<ISO time the user approved the first setup, or null>",
  "uv": "<path of the uv.exe in .envs\bin>",
  "pythons": { "3.12": "<folder under .envs\python>" },
  "envs": {
    "py3.12-<hash12>": {
      "project": "src/tts",              // repo-relative, '/' separators, '.' for the root
      "kind": "lock" | "resolve",
      "hash": "<full SHA-256>",
      "python": "3.12",
      "bytes": <size on disk>,
      "built": "<ISO time>"
    }
  }
}
```

**Hash.** `lock`: the SHA-256 of `uv.lock`, with the existing `Get-SandboxFileHash`. `resolve`: the SHA-256 of the project's declaration files (`pyproject.toml`, `requirements*.txt`), each file's repo-relative path and bytes, in sorted order. A changed declaration gives a new hash, so it is caught as stale (G6).

**Last use.** Linking touches `.envs\linked\<env name>` (an empty file; its write time is the last link). Runs never write `envs.json`, so two runs starting together, or a review lens, can't overwrite the approval record.

**Environment name:** `py<major.minor>-<first 12 hex of hash>`. A project whose lockfile changed gets a new folder. The old one stays until pruned, so a branch with the old lockfile still works.

### Rules

*   **Projects.** From `git -C <repo> ls-files`: every folder holding `uv.lock` is a `lock` project. Every other folder holding `pyproject.toml` or a `requirements*.txt`, with no `lock` project above it, is a `resolve` project.
*   **Interpreter.** In order: `.python-version` in the project folder or the nearest folder above it inside the repo; `requires-python` in `uv.lock` or `pyproject.toml`, taking the lowest version it allows that `uv python list` offers; `version_info` in the user's `<project>\.venv\pyvenv.cfg`, major.minor only. If none gives an answer: `unsupported` (`python-version-unknown`).
*   **Status.** `ready`: the folder exists, `envs.json` names it for this project, and `Scripts\python.exe` exists. `stale`: an older environment exists for this project, but not one for the current hash. `missing`: neither exists. If the host has no `uv`, every project is `unsupported` (`uv-missing`) and the report says to install `uv`.
*   **Estimate.** Disk: for `lock`, from the sizes of the Windows wheels for the chosen Python that `uv.lock` lists, scaled for unpacking; for `resolve`, the size of the user's `.venv\Lib\site-packages` if there is one, otherwise "unknown". Each interpreter not yet in `.envs\python` adds its own size. Time: under a minute when the packages are in `uv`'s cache (P2), otherwise download-bound. Both are labelled estimates; the constants are set in the build task.
*   **`uv` itself.** The host's `uv` is found with `Get-Command uv` and copied into `.envs\bin` when the build runs.
*   **Build (`lock`).** `uv python install <ver>` with `UV_PYTHON_INSTALL_DIR=<.envs>\python`. Then `uv sync --frozen --project <user's checkout>\<project>`, with `UV_PROJECT_ENVIRONMENT=<.envs>\<name>` and `UV_PYTHON_PREFERENCE=only-managed`. The user's checkout is only read, because the environment folder is outside it.
*   **Build (`resolve`).** With `pyproject.toml`: copy it (and only it) into `.envs\work\<name>`, `uv lock` there, then `uv sync --frozen --no-install-project` from that copy into `<.envs>\<name>`. With only `requirements*.txt`: `uv venv` on the copied interpreter, then `uv pip install -r` each file. Nothing is written into the user's checkout or the repo.
*   **Editable install (D7).** After either build, each `.pth` file in the environment's `site-packages` whose content is a path inside the user's checkout is replaced by a line that appends the same repo-relative path under `XAGENT_WORKTREE`, and does nothing when the variable is unset. For a `resolve` project with a `[build-system]`, the same line is written for the project folder (its `src` folder if it has one). Any other kind of editable install (an import hook) is left alone and noted in the report.
*   **Build failure.** If `uv` fails, nothing is recorded: the partial folder is deleted, and the report gives `install-failed` with the last 20 lines of `uv`'s error.
*   **Grant (D6).** Each sandboxed run adds rows to its grant list: `(OI)(CI)RX` on each linked environment, on each interpreter folder those environments use, and on `.envs\bin`. They go through the same path, ledger and removal as read-list entries.
*   **Prune** (after an `-Apply` build only). Delete an environment when no project's current hash names it, no existing worktree holds a junction to it, and its `linked` stamp is older than 14 days or missing. Delete an interpreter when no remaining environment uses it.
*   **Linking** (each sandboxed run, after the worktree exists, before the process starts). For each `ready` environment: if `<worktree>\<project>\.venv` does not exist, create a junction there and touch its `linked` stamp. If it exists and is a junction, replace it. If it is a real folder, leave it, and add a `sandboxNotes` line. Any project not `ready` gets a `sandboxNotes` line naming its status.
*   **Unlinking.** Before any worktree removal (`-Cleanup`, `-Cleanup -Discard`, read-only worktree removal, `-SandboxRun`, the canary), delete every `.venv` junction in the worktree. A junction is deleted as a link only, never with a recursive delete.
*   **Environment variables** added in `Get-SandboxEnvironment` when the repo has a `.envs\bin`: `.envs\bin` appended to `PATH`; `XAGENT_WORKTREE=<slot>:\`; `UV_FROZEN=1`, `UV_NO_SYNC=1`, `UV_PYTHON_DOWNLOADS=never`, `UV_CACHE_DIR=<slot>:\.xagent\sandbox\uv-cache`.
*   **`-SandboxRun` diagnosis.** From the combined output and exit code: `ok`, `command-not-found`, `module-missing` (with the module name), `access-denied` (with the path when present), `timeout` or `other`. The text patterns are set in the build task and its tests.

### Files

| File | Change | Why |
|---|---|---|
| `skills/delegate/scripts/SandboxEnv.psm1` | **New.** Project discovery, report, build, prune, link and unlink, and the `envs.json` reader and writer. | All of the Rules above, in one module that `delegate.ps1` and `Sandbox.psm1` import. |
| `skills/delegate/scripts/delegate.ps1` | New parameter sets `Env` (`-SandboxEnv -Repo [-Apply]`) and `SandboxRun` (`-SandboxRun -Repo -Command [-Base] [-TimeoutSec]`), each printing one JSON line. The normal run path links environments after the worktree is created and before Cursor starts. The three `worktree remove` sites unlink first. Usage text updated. | G1, G3, D4, and safe cleanup. |
| `skills/delegate/scripts/Sandbox.psm1` | `Get-SandboxGrantList` takes the run's linked environments and adds their rows (D6). `Get-SandboxEnvironment` gains the variables and the `.envs\bin` `PATH` entry. `Invoke-SandboxCanary` unlinks before its worktree removal. New `Invoke-SandboxCommand`, which `-SandboxRun` uses: `New-SandboxRun`, `Start-SandboxProcess` with `pwsh -NoProfile -Command <cmd>` in the worktree root, wait with timeout, `Stop-SandboxRun`. | One run path and one grant path for workers and probes. |
| `skills/delegate/tests/SandboxEnv.Tests.ps1` | **New.** Pester tests with fixture repos: project discovery (lock, resolve, workspace root, nested `pyproject.toml` under a lock); interpreter rules; hashes and names; status, including `uv-missing`; estimates from a fixture `uv.lock`; the `.pth` rewrite; prune rules; link and unlink on a temp folder (unlink leaves the target intact); diagnosis. No `uv` and no network: building is tested with stubbed commands. | Each rule tested without a sandbox. |
| `skills/delegate/tests/fixtures/sandbox-env/` | **New.** Small `uv.lock`, `pyproject.toml`, `requirements.txt`, `pyvenv.cfg` and `.pth` fixtures. | Inputs for the tests above. |
| `skills/delegate/tests/Sandbox.Tests.ps1` | Cases for the environment rows in `Get-SandboxGrantList`, and for the new variables in `Get-SandboxEnvironment` (present only when `.envs\bin` exists). | Covers the `Sandbox.psm1` changes. |
| `skills/delegate/tests/DelegateLaunch.Tests.ps1` | Parameter-set cases for `-SandboxEnv` and `-SandboxRun` (accepted combinations, refusals such as `-SandboxRun` with `-NoSandbox`). | The CLI surface. |
| `skills/delegate/SKILL.md` | Invocation table rows for `-SandboxEnv` and `-SandboxRun`. In "Sandbox", a section "Environments" (what is built, where, the one approval, rebuilds without asking, `.venv` links, read-only environments). In the loop, before the first worker: run `-SandboxEnv`; on a proposal, ask once; then `-SandboxRun` one test command. | `delegate`-only leads do the same as `feature` (G5). |
| `skills/feature/scripts/feature.ps1` | `doctor` takes an optional `-Repo`. With it, adds a non-required check `sandbox-env` built from the `-SandboxEnv` report: ok when every project is `ready`, otherwise the detail lists what is missing, with the estimate. | G5. |
| `skills/feature/tests/feature.Tests.ps1` | `doctor -Repo` case with a stubbed report: check present, ok or not, detail text. | Covers the doctor change. |
| `skills/feature/SKILL.md` | `doctor` may pass `-Repo <repo>`. | It currently says doctor passes neither. |
| `skills/feature/stages/build.md` | Before the first worker of the build: `-SandboxEnv`; proposal and one question if this repo was never approved; `-Apply`; then `-SandboxRun` with each phase's `test` command. Failure handling: `module-missing` or `command-not-found` with all environments `ready` means the repo's own setup is incomplete, and that is a problem stop; `access-denied` is a sandbox problem stop. | G5 in the feature flow. |
| `README.md` | "Requirements": `uv` on the host for Python repos run in the sandbox. | Non-goal: the skill doesn't install it. |
| `docs/test-plan.md` | Rows for the probes and the live checks below. | Records measured behaviour. |
| `docs/HANDOFF.md` | State of the feature at sign-off. | Handoff. |

### Verification

*   **Unit:** the full Pester suites in `skills/delegate/tests` and `skills/feature/tests` pass.
*   **Live, on this machine** (lead, at sign-off):
    1.  `-SandboxEnv` on the private repo reports six `lock` projects, three interpreters and an estimate. The probe command fails first with `module-missing`.
    2.  After `-Apply`, `-SandboxRun` with one test file from each project exits 0.
    3.  A sandboxed worker on a one-line task in that repo runs `uv run pytest <one test>` and passes.
    4.  `-Cleanup` of that worker leaves every environment in `.envs` intact (file counts before and after), and no slot identity is left on any `.envs` folder's access list.
    5.  `pip install` inside a sandboxed run fails with an access error.
    6.  A scratch package with an editable install: a sandboxed test imports the worktree's copy of its module.
    7.  The existing `-SandboxCheck -Repo` canary still passes all rows.
