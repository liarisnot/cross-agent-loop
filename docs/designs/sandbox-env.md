# `sandbox-env`: environments a sandboxed worker can reach

*   **Author:** Eugene Chin
*   **Status:** Draft
*   **Date:** 2026-11-16

--------------------------------------------------------------------------------

## Overview

Since `worker-sandbox` (docs/designs/worker-sandbox.md), every `delegate` worker, review lens and council seat runs in a Windows AppContainer. Besides its worktree, its run home, the parts of the repo's `.git` it needs and the Cursor runtime cache, the container can read `C:\Windows`, `C:\Program Files` and the paths on an explicit read list, and nothing else. Its `PATH` is fixed: Windows (including Windows PowerShell's folder), PowerShell 7, Git, then read-list entries marked `addToPath`.

A repo whose tests need a language runtime or packages outside those places cannot be built by a sandboxed worker. Today nothing notices this until a worker fails, and the fix is a hand edit of `%LOCALAPPDATA%\xagent\sandbox.json` plus whatever setup the toolchain needs.

This feature makes `delegate` find the problem before any worker starts, explain it, propose a fix with its cost, and on the user's approval set up an environment the sandbox can reach. It follows the pattern the sandbox uses for drive letters: a run fails with a `sandbox:` error that names the fix, the user approves once, and the skill does the work. `feature` calls it from `doctor` and before the build starts.

## The Problem

The first real repo it was tried on, a private Python project, shows the failure. The repo is split into subprojects, each with its own `pyproject.toml`, `uv.lock` and `.venv` folder:

*   **The environments are not in a worktree.** Each `.venv` sits inside the user's checkout and is ignored by git, so a worker's fresh worktree has none of them.
*   **The interpreters are out of reach.** The subprojects ask for different Pythons: most use a 3.12 that `uv` installed under `AppData\Roaming\uv\python`, one uses `C:\Program Files\Python311` and one uses `C:\Python314`. The sandbox denies the whole profile, the read list refuses anything under `AppData\Roaming` on purpose (other programs keep credentials there), and folders at the root of `C:` other than `Windows` and `Program Files` are denied. Only the 3.11 is readable, and it is not on the sandbox `PATH`.
*   **The tool that builds the environments is out of reach.** `uv` itself is in `~\.local\bin`, under the profile.
*   **Some packages are large and come from their own index.** The text-to-speech subproject needs a CUDA build of `torch` from PyTorch's index (declared in its `pyproject.toml`), several gigabytes once installed.
*   **So a sandboxed worker cannot run any test of that repo.** Running its workers with `-NoSandbox` would work, but it removes the protection that repo most needs: it holds a live database that experiments must never touch.

The general shape: the sandbox is safe because it can read little, and a repo's toolchain is usually installed outside what it can read. Each repo's setup is different, and the user should not have to know the sandbox's rules to fix it.

## Goals

*   **G1. Detect before a worker runs.** `delegate.ps1` can run a plain command (no Cursor) inside the sandbox, in a fresh worktree of the repo, with the same environments and grants a worker gets, and return its exit code and the first lines of its output, which the lead reads. It costs one sandboxed process, not a worker, and uses none of the user's Cursor plan usage.
*   **G2. Propose, with the cost, before changing anything.** A diagnosis that has a known fix produces a proposal: what will be created, where, and roughly how much disk and time. Nothing is created until the user says yes, once per repo. After that, rebuilds for a changed lockfile run without asking and are reported in one line, unless one would add more than 5 GB to `.envs`, which is proposed again.
*   **G3. Set up Python on approval.** For a Python project the skill finds the interpreter and packages it declares, builds an environment the sandbox can read, and makes it visible to every sandboxed run of that repo. A repo with several projects gets one environment per project. Pass: the G1 probe that failed now passes.
*   **G4. No hand setup.** The user never edits `sandbox.json`, never runs a setup command and never needs to know the sandbox's rules. Every step is proposed in chat and run by the skill. The one prerequisite is `uv` on the host, which the README will list.
*   **G5. Built into the flow, failing closed.** A sandboxed worker launch for a repo whose projects lack a `ready` environment fails with a `sandbox:` error that carries the proposal, the same way missing drive letters fail today, so no Cursor time is spent on a worker that can't run its tests. `feature.ps1 doctor` reports the same state. Before the build, the lead runs `-SandboxEnv` and, on a proposal, asks once. Each phase-end test runs inside the sandbox through `-SandboxRun` on `feature/<name>`, not in the user's checkout.
*   **G6. Stale environments are caught.** When a project's lockfile changes, or the sandboxed probe starts failing, the same detection offers to bring the environment up to date.
*   **G7. The sandbox does not get wider than needed.** A run is granted read access to the environments it links, for that run only, through the same per-run grant list as every other path. Nothing under the profile root, `AppData\Roaming`, `.ssh`, `.aws`, `.gnupg` or Cursor's folders is ever granted, and the existing read-list refusals stay as they are.

## Non-Goals

*   **Every language in v1.** v1 sets up Python only. For any other toolchain the probe reports what is missing and stops at a proposal the user acts on. Node is in that group: the sandbox `PATH` does not include `C:\Program Files\nodejs`, so `node` and `npm` are not found even where they are installed.
*   **Installing `uv`.** The skill needs `uv` on the host, and the README will say so. If it is missing, the report says so and stops; adding `uv` to a machine is the user's setup choice.
*   **Changing the user's own environments.** The skill reads the user's checkout and tools (to learn what each project needs) and never changes them.
*   **GPU access.** If a test needs the GPU and the sandbox cannot reach it, the probe reports that. Making the GPU reachable from an AppContainer is out of scope.
*   **Dependency management.** The skill installs what a project declares. It does not pin or upgrade dependencies and never writes a lockfile into the repo. A project without `uv.lock` is resolved afresh, outside the repo, from what it declares.
*   **Secrets.** No credentials, tokens or private package-index logins are copied into the environment.

## Open Questions

*   **GPU.** Whether an AppContainer can use the GPU at all is unverified.

Questions settled since the first draft are recorded in the Decisions table (D3, D7) and in Risks and Mitigations (disk).

## Technical Plan

### Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Environments live per repo in `<repo>.xagent\.envs\` (`<repo>.xagent` is the folder beside the repo where `delegate` already puts its worktrees; there is one `.envs` per repo, not per worktree), one folder per environment, named `py<major.minor>-<first 12 hex of the project's hash>`. | Everything for a repo sits beside its worktrees and is removed with them. Sharing one root across repos is not worth it: the design assumes lockfiles differ between repos, and `uv`'s cache is on another drive, so packages are copied either way. Worktree names start with a letter or digit (task ids, `canary-`, `probe-`), so none can land on `.envs`. |
| D2 | Interpreters are always copied with `uv` into `<repo>.xagent\.envs\python\`. The user's installed Pythons are never granted. | One rule for every case; nothing outside `<repo>.xagent` is granted; upgrading or removing one of the user's Pythons never breaks a worker. |
| D3 | A project with `uv.lock` is installed with `uv sync --frozen`. A project without one is resolved afresh with `uv` from its `pyproject.toml` or `requirements*.txt`, outside the repo. | The lockfile is the record the user committed, with every package's version and download address. Without one, a fresh resolve is an automatic answer that doesn't guess where installed packages came from; versions may differ slightly from the user's `.venv`. |
| D4 | Before each sandboxed worker run and probe, the host links each project's environment into the worktree as `.venv` (a directory junction). A copy of `uv.exe` is on the sandbox `PATH`. Review lenses and council seats run no tests and get no environments. | The worktree then looks like the user's checkout: `.venv\Scripts\python` and `uv run pytest` work as they do there (probe P1). |
| D5 | The skill decides by itself wherever a rule covers the case. The user is asked once per repo, to approve the disk and time cost of the first setup. | The skills exist to make a feature faster; every question stalls the run. |
| D6 | Each worker run and probe is granted the environments it links, the interpreters they use and `.envs\bin`, as rows of the existing per-run grant list, removed when the run ends. | No second permission system; a worker on one repo cannot read another repo's environments. Probe P2: granting and removing the largest environment (4.8 GB, 29,568 files) takes about 3 seconds each. |
| D7 | The project itself is never installed into the environment. A project with a `[build-system]` gets a `.pth` file that adds its folder under `XAGENT_WORKTREE`, the run's worktree. | An installed project records the folder it was built from, not the worktree. Probe P3 found that a relative path works for `python.exe` but not for `uv run`, which resolves the link to its real path; the `XAGENT_WORKTREE` line works for both. |
| D8 | An environment belongs to the tree being run, not to the user's checkout. A run hashes the project's inputs at the commit it runs (Data, "Identity hash") and links the environment with that hash; `-SandboxEnv` builds for a given ref. | Workers run on `feature/<name>`, whose lockfile can differ from the checkout's. An older environment stays usable for a branch that still has the older lockfile. |

### What a project is

A project is a folder in the tracked files of the ref being run that holds `uv.lock` (a `lock` project), or holds `pyproject.toml` or `requirements*.txt` with no `lock` project above it (a `resolve` project). `uv` workspaces are not supported in v1 (Rules, "Projects"). Projects are found from the files tracked at the ref, so ignored folders (the user's own `.venv` folders, other tools' worktrees) are never scanned.

A project's interpreter comes from `.python-version`, then `requires-python`; `uv` resolves the request to an exact version (Rules, "Interpreter").

### Components

```text
delegate.ps1
  -SandboxEnv -Repo [-Apply]    --> SandboxEnv.psm1 (new): find, report, build, prune
  -SandboxRun -Repo -Command    --> Sandbox.psm1 run path, no Cursor
  every sandboxed run           --> link .venv junctions; grant them for the run;
                                    .envs\bin on PATH

feature.ps1 doctor              --> delegate.ps1 -SandboxEnv (report only)
stages/build.md, delegate SKILL --> before the first worker: -SandboxEnv;
                                    phase-end tests through -SandboxRun
```

*   **`SandboxEnv.psm1` (new, in `skills/delegate/scripts/`).** Finds the projects, works out each one's interpreter and environment name, compares them with what exists in `.envs`, and builds what is missing. It keeps `.envs\envs.json`: what was built for each environment, and whether the user approved the first setup. Only the build writes it.
*   **`delegate.ps1 -SandboxEnv -Repo <repo> [-Base <ref>]`.** Reads the projects at `<ref>` (default: the checkout's `HEAD`; `feature` passes `feature/<name>`). Prints one JSON object: each project with a status (`ready`, `missing`, `stale`, `install-failed`, or `unsupported` with a reason) and, for anything to build, a proposal: what, where, estimated disk and estimated time, plus the current size of `.envs`. The disk estimate comes from the wheel sizes `uv.lock` records; nothing is downloaded to estimate it. With `-Apply` it builds what the report proposed, records the approval, and prunes environments nothing has used for 14 days. `-Rebuild <project>` rebuilds one environment that looks `ready` but is wrong.
*   **`delegate.ps1 -SandboxRun -Repo <repo> -Command "<cmd>" [-Base <ref>] [-TimeoutSec <n>]` (G1).** Creates a detached worktree, links the environments, runs the command in a sandbox slot through the same run path a worker uses, removes the worktree, and prints one JSON object: `status` (`ran`, `environment-missing` or `timeout`), `exitCode`, the first 40 lines of output and `seconds`. `environment-missing` is decided before the command runs, and lists the projects and the proposal. It waits for one of the two slots like any run.
*   **Every worker run and probe** (not review lenses or council seats). Before the process starts, the host creates `<worktree>\<project>\.venv` as a junction to the environment matching that worktree's lockfile (D8), when it is `ready`, and adds read grants for those environments to the run's grant list (D6). `SandboxEnv.psm1` supplies the `PATH` entry for `.envs\bin` (holding `uv.exe`), `XAGENT_WORKTREE` (D7) and the `uv` variables that make `uv run` use the linked environment and never change it; `Get-SandboxEnvironment` appends what it is given. If a project at the base ref has no `ready` environment, a sandboxed worker launch fails before it starts, with the `sandbox: environment not ready` error in Rules, "Readiness gate"; `-NoSandbox` runs skip this check and get no environments. A worker that tries `pip install` or `uv pip install` gets an access error, because the environment is read-only (P1).
*   **`feature.ps1 doctor`** adds the `-SandboxEnv` summary for the repo, and the proposal when something is missing.
*   **`stages/build.md` and `delegate`'s SKILL.md.** Before the first worker, the lead runs `-SandboxEnv -Base feature/<name>`. If the report's `proposal.needsApproval` is true (no approved setup yet, or this build is estimated over 5 GB), the lead shows the proposal and asks once; otherwise it runs `-Apply` and reports in one line. A worker launch that fails with `sandbox: environment not ready` is handled the same way, then retried once; this is the one `sandbox:` error the lead does not treat as a stop at once. At each phase end, the lead runs the phase's `test` with `-SandboxRun -Base feature/<name>` instead of in the user's checkout. The phase test passes only when `status` is `ran` and `exitCode` is 0; anything else is a failing phase test, with the output shown.

### Flow on first use

```text
lead: delegate.ps1 -SandboxEnv -Repo R -Base feature/<name>
  -> 6 projects, 0 ready; build 3 interpreters and 6 environments, about <n> GB
lead -> user: the proposal in plain words, one question
user: yes
lead: delegate.ps1 -SandboxEnv -Repo R -Base feature/<name> -Apply
  -> uv python install 3.11 3.12 3.14        (UV_PYTHON_INSTALL_DIR = R.xagent\.envs\python)
  -> for each project: uv sync --frozen      (UV_PROJECT_ENVIRONMENT = R.xagent\.envs\py3.12-<hash>)
lead: start the first worker (environments linked and granted for its run)
  ...
lead: at phase end, delegate.ps1 -SandboxRun -Repo R -Base feature/<name> -Command "<phase test>"
```

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| **Disk grows.** Each lockfile version gets its own environment (D8), and a CUDA `torch` environment is about 5 GB; each repo also holds its own interpreters. | Unused environments are pruned after 14 days. A build that adds more than 5 GB is proposed again. Every proposal shows the size of `.envs`. No hard cap: the user chose this over evicting environments. |
| **A run pays for grants.** Granting and removing a 4.8 GB environment takes about 3 seconds each (P2). | Accepted. Only worker runs and probes are granted environments; review lenses and council seats are not. |
| **A junction survives worktree removal** (P5), leaving the worktree folder behind. | Every removal deletes `.venv` junctions first, as links only. |
| **Prune races a run that is linking.** | Linking and prune both hold the `.envs` lock; linking touches the stamp before creating the junction. |
| **The copied `uv` falls behind the lockfile format.** | `uv.exe` is copied again on every `-Apply`, and a lockfile change always leads to an `-Apply`. Inside a run, `uv` reads only the linked environment (`UV_FROZEN`, `UV_NO_SYNC`). |
| **Private package indexes.** | Builds run on the host with the user's own `uv` settings. Nothing with credentials is copied into `.envs`, and inside a run `uv` contacts no index. |
| **Writes outside the read-only environment.** `pip install --user` or `uv tool install` could write into the run home. | `pip` refuses `--user` inside a virtual environment. Anything else lands in the run home, which is removed with the worktree. |
| **Two lockfiles share a 12-hex folder name.** | `envs.json` is keyed by the full hash, and a build refuses a folder that belongs to another hash (`name-clash`). |
| **A build fails part-way.** | The partial folder is deleted `failed` records the hash and `uv`'s error, and the project reports `install-failed` until the next `-Apply` retries it. |
| **An environment looks `ready` but is wrong** (a bad build, or a `.pth` root that doesn't fit). Workers fail closed on it. | `-SandboxEnv -Apply -Rebuild <project>`; `SKILL.md` names it. |
| **Task acceptance tests still run on the host.** `feature.ps1`'s task `test` runs with host `pwsh` in the worker's worktree. | Accepted for v1: only phase tests move into the sandbox. Moving task tests is a follow-up. |

## Alternatives Considered

### Run such repos with `-NoSandbox`

Works today with no new code. Rejected: it removes sandbox protection from a repo that holds a live database experiments must never touch.

### Grant the user's own environments in place

Add the user's `.venv` folders and interpreters to the read list, and nothing is copied. Rejected for three reasons:
*   Most interpreters are under `AppData\Roaming`, which the read list refuses on purpose.
*   A venv loads its interpreter from the `home` path in `pyvenv.cfg` on every run, so granting the `.venv` alone is not enough.
*   An editable install in the user's `.venv` points at the user's checkout, so workers would test the checkout's code, not their worktree's.

### Let each worker build its own `.venv` inside its worktree

The closest match to the user's setup, with no shared state. Rejected: every task would install CUDA `torch` again (several GB). The worker's `uv` cache is inside its own run home, so nothing would be reused between tasks.

### Where the environments live (D1)

*   **One root shared by all repos, picked once by the user.** Environments named by lockfile could be shared between repos. Rejected: the design assumes lockfiles differ between repos, so little would be shared. And unless everything is on C:, where `uv`'s cache is, packages are copied anyway.
*   **`%LOCALAPPDATA%\xagent\envs\`.** On the same drive as `uv`'s cache, so packages could be hard-linked and cost little disk. Rejected: it is inside the user's profile and inside the folder the read list refuses. Granting a hard-linked file also changes permissions on `uv`'s cached copy, which is the same file.

### Where interpreters come from (D2)

Use the user's installed Python where the read list allows it (`C:\Program Files`, `C:\Python314`), and copy only the ones under `AppData\Roaming`. That gives the same builds the user tests with, and fewer copies. Rejected: it needs two rules instead of one. It grants whole folders outside the repo, such as `C:\Python314`, so anything later installed into them is readable by workers too. And upgrading or removing one of the user's Pythons would break workers until a rebuild.

### Projects without a lockfile (D3)

*   **Copy the user's `.venv` onto a copied interpreter and fix up its scripts and paths.** The closest match to what the user runs. Rejected in review round 1 (`docs/features/sandbox-env/reviews/design-1.md`): it is a second package installer (regenerating entry points, rewriting install records), the repo that motivated the feature doesn't need it, and the fresh resolve covers the same projects with `uv`'s resolver.
*   **Read the packages installed in the user's `.venv` and reinstall them.** Rejected: the installed list doesn't record which index each package came from. CUDA `torch` and similar would need guessing, or a question to the user, and that layer of complexity shouldn't reach users.
*   **Report and stop.** Rejected: it stops the run for a question the skill can answer itself (D5).

### How a test command finds its environment (D4)

*   **Explicit interpreter paths in every test command.** No hidden behaviour. Rejected: commands get long and stop matching the repo's own instructions, and a worker that types `python` gets the wrong one.
*   **A `python` shim on `PATH` that picks the environment from the current folder.** Plain `python` works everywhere. Rejected: it is custom code imitating `uv run`, and tools that look for `.venv` still find none.

### A lasting read grant on all of `.envs` (D6)

One grant per build, for both slot identities, removed on `-SandboxCheck -Release`. It was planned on the assumption that per-run grants on a large environment are slow. Rejected in review round 1 (`docs/features/sandbox-env/reviews/design-1.md`) and by probe P2: per-run grants take seconds, and a lasting grant is a second permission system outside the grant ledger and the read-list checks, which lets a worker on one repo read every repo's `.envs`.

### Download `uv` when the host has none

A pinned release with a checked hash, so no prerequisite is left. Rejected: adding `uv` to a machine is a setup change the user should choose, and it would be the only download the skill makes itself. The README will list `uv` as required.

## Detailed Implementation Plan

### Probes

Run by the lead on 2026-11-17 against a scratch repo (a small `hatchling` package with `numpy` and `pytest`), with the private repo's text-to-speech `pyproject.toml` and `uv.lock` copied in for the large case.

| # | Check | Result |
|---|---|---|
| P1 | A sandboxed `pwsh` in a slot, with `<worktree>\.venv` a junction into `.envs`, built on a `uv`-installed 3.12, with `.envs` and `.envs\bin` granted. | **Pass.** `import numpy` and `uv run pytest` work. `uv` starts by name from `PATH`; `where.exe` inside the sandbox did not list it, which does not affect starting it. `uv pip install` fails with "Access is denied". The environment's file count (4,843) and newest write time are unchanged afterwards. |
| P2 | `icacls /grant (OI)(CI)RX` and `/remove`, without `/T`, for one slot identity on a built CUDA `torch` environment. | **Pass.** With the packages already in `uv`'s cache, building the environment (4.77 GB, 29,568 files, copied across drives) took 13 s. Grant 2.7 s, removal 2.8 s. Grants stay per run (D6). |
| P3 | After `uv sync --frozen` into the outside environment, a test in a worktree imports the project's own module. | **Fails as built**: the editable install points at the checkout the environment was built from, so `uv run pytest` gets `ModuleNotFoundError`. A relative path in the `.pth` works for `python.exe` but not for `uv run`. **Fix that passes:** the `.pth` reads `XAGENT_WORKTREE` (D7). The build now keeps the project out of the environment entirely (`--no-install-project`), so the `.pth` is what puts it on `sys.path`. Projects with no `[build-system]` are not installed into the environment and need nothing; every project in the private repo is of that kind (by reading its `pyproject.toml` files). |
| P4 | The `.venv` copy path. | Not run: that path was dropped (D3). |
| P5 | `git worktree remove --force` on a worktree holding a `.venv` junction. | The environment is untouched, but the junction is left behind, so the worktree folder is not fully removed. Cleanup deletes junctions first (Rules, "Unlinking"). |

### Data

**Identity hash.** A project's inputs are, at the commit: `uv.lock`, `pyproject.toml`, `uv.toml`, files directly in the project folder whose lower-cased name matches `requirements*.txt`, the files that `pyproject.toml` names in `readme = "..."` or `license = { file = "..." }`, and `.python-version` (the first found walking up from the project folder to the repo root). The hash is the SHA-256 of the UTF-8 text formed by one line per input, `<repo-relative path, '/' separators>` TAB `<git blob id>` LF, sorted by path with ordinal comparison. Blob ids come from `git ls-tree` at the ref, or at the worktree's `HEAD` when linking, so line-ending conversion in a checkout never changes the hash. Two projects with identical inputs share one environment.

**`<repo>.xagent\.envs\envs.json`** (UTF-8 without BOM). Only `-SandboxEnv -Apply` writes it, under the `.envs` lock, by writing `envs.json.tmp` and renaming it over `envs.json`. A reader that finds it missing treats every environment as absent (status `missing`). A reader that finds it present but unreadable does the same and never throws; `-SandboxEnv` then adds `"warning": "envs.json unreadable; rebuilding on -Apply"`. A missing file is the normal first run and gets no warning.

```text
{
  "version": 1,
  "approved": "<ISO time of the first successful -Apply, or null>",
  "uv": "<path of the uv.exe in .envs\bin>",
  "uvVersion": "<its version>",
  "pythons": { "3.12.7": "<folder under .envs\python>" },       // keyed by full version
  "envs": {
    "<full SHA-256>": {
      "name": "py3.12-<first 12 hex>",
      "projects": ["src/tts"],          // repo-relative, '/' separators, '.' for the root
      "kind": "lock" | "resolve",
      "python": "3.12.7",
      "bytes": <size on disk>,
      "built": "<ISO time>"
    }
  },
  "failed": {
    "<full SHA-256>": { "at": "<ISO time>", "error": "<last 20 lines of uv's error>" }
  }
}
```

**`.envs` lock.** `Local\xagent-envs-<first 12 hex of the SHA-256 of the lower-cased full path of .envs, no trailing separator>`, one per repo. It uses the wait, abandoned-lock takeover and timeout that `Invoke-SandboxAclLocked` uses, factored into a helper that takes the mutex name and the timeout message. It is a separate mutex from `Local\xagent-acl`.

**Last use.** `.envs\linked\<env name>` is an empty file whose write time is the last link. Runs never write `envs.json`.

**JSON output.** Both commands print with `ConvertTo-Json -Compress -Depth 8`, so nested objects are kept.

**`-SandboxEnv` output** (one line on stdout, exit 0; an invalid repo or ref is `{ok: false, error}` with exit 1, through `delegate.ps1`'s `Fail`):

```text
{
  "ok": true,
  "repo": "<path>", "ref": "<ref>",
  "uv": "<host uv path or null>",
  "envsBytes": <current size of .envs>,
  "approved": <true or false>,
  "warning": "<optional>",
  "projects": [
    { "project": "src/tts", "kind": "lock" | "resolve",
      "status": "ready" | "missing" | "stale" | "unsupported" | "install-failed",
      "reason": "<unsupported: uv-missing or python-version-unknown; install-failed: uv's error>",
      "env": "py3.12-<hash12>", "python": "<requested version or specifier>" }
  ],
  "proposal": null | {
    "needsApproval": <true or false>,
    "interpreters": ["3.11"], "envs": ["py3.12-<hash12>"],
    "estimateBytes": <n or null>, "estimateSeconds": <n or null>,
    "text": "<one paragraph: what is built, where, the estimate, the current size of .envs>"
  },
  "built": [ { "env": "<name>", "projects": [...], "bytes": <n>, "seconds": <n> } ],   // -Apply only
  "failedNow": [ { "env": "<name>", "projects": [...], "error": "<...>" } ],          // -Apply only
  "pruned": [ { "env": "<name>", "bytes": <n> } ]                                      // -Apply only
}
```

**`-SandboxRun` output** (one line on stdout, exit 0; a setup failure such as no free slot is `{ok: false, error}` with exit 1):

```text
{
  "ok": true,
  "status": "ran" | "environment-missing" | "timeout",
  "exitCode": <n, or null unless ran>,
  "output": ["<first 40 lines: stdout, then stderr; each line cut at 400 characters>"],
  "seconds": <n>,
  "projects": [ ... ], "proposal": { ... }     // environment-missing only, as in -SandboxEnv
}
```

### Rules

*   **Modules.** `SandboxEnv.psm1` imports `Sandbox.psm1`; `Sandbox.psm1` never imports `SandboxEnv.psm1`. `delegate.ps1` imports both and does the orchestration: the readiness gate, linking and unlinking come from `SandboxEnv.psm1`, and it passes the resulting environment paths and variables into `Sandbox.psm1` functions. `Sandbox.psm1` adds to its exports `Resolve-SandboxReadEntry`, `Invoke-SandboxCommand` and the lock helper. `SandboxEnv.psm1` reads a commit with its own `git ls-tree` and `git show` calls, and reads `pyproject.toml` with one private line-based reader: a `key = "string"` line inside a named `[section]`, or a `[section]` header's presence. No other TOML syntax is supported; a value the reader can't find counts as absent.
*   **`uv` calls.** Every `uv` call goes through one `Invoke-SandboxUv` function, which runs the path in `$script:UvPath`: `XAGENT_UV_PATH` when set, otherwise `(Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source`, looked up once per `-SandboxEnv` call. No path means `uv-missing`. Tests set `XAGENT_UV_PATH` to a fake `uv` script.
*   **Projects.** From `git -C <repo> ls-tree -r --name-only <ref>`: every folder holding `uv.lock` is a `lock` project. Every other folder holding `pyproject.toml` or a `requirements*.txt`, with no `lock` project above it, is a `resolve` project. A project whose `pyproject.toml` has a `[tool.uv.workspace]` section is `unsupported` (`workspace`) in v1; the repo that motivated the feature has none.
*   **Interpreter.** The request is the first line of `.python-version` as written (`3.12` or `3.12.7`). Without one, it is the lowest minor version that the `requires-python` line allows (from `uv.lock`'s top-level `requires-python`, or from `pyproject.toml`'s `[project]` when there is no lock): the first clause of the form `>=X.Y`, `~=X.Y`, `==X.Y.*` or `==X.Y.Z` gives `X.Y`, and `>X.Y` gives `X.(Y+1)`; any other form, or none, is `unsupported` (`python-version-unknown`). A user who wants a different version commits a `.python-version`. At build, `uv python install <request>` runs, then `uv python find --managed-python <request>` prints the interpreter's path; its parent folder is the interpreter folder, and `python.exe -c "import platform; print(platform.python_version())"` gives the exact version that keys `pythons` and fills `python`. The environment name uses its major.minor. If `uv` can't provide the request, the build fails with `install-failed`.
*   **Status** (per project, at the commit). `unsupported` (`uv-missing`) first, for every project, when the host has no `uv`; `-Apply` then builds nothing and still returns `ok: true`. Then `ready`: `envs` has the project's hash and its folder has `Scripts\python.exe`. `install-failed`: `failed` has the hash. `stale`: `envs` has an entry listing this project, but not for this hash. `missing`: otherwise.
*   **Estimate.** Disk for a `lock` project: the sum of `size` over the wheels `uv.lock` lists for each package whose file name has `win_amd64` or `none-any` and a Python tag the chosen version accepts (`cp3XY`, `abi3`, `py3`), times 2.5, plus 100 MB per interpreter not yet installed. 1 GB is 1,000,000,000 bytes, so the 5 GB threshold is 5,000,000,000. A package with no matching wheel `size`, and every `resolve` project, makes the estimate `null` ("unknown"). Seconds: 30 plus 1 per 20 MB, shown as an upper bound. Both are shown as estimates.
*   **Approval.** `-Apply` never refuses: the lead enforces approval (`stages/build.md`, `delegate` SKILL.md). `needsApproval` is computed on every report and not stored: true when `approved` is null, or when this build's estimate is over 5 GB. A `null` estimate needs approval only when `approved` is null. `approved` is written after the first `-Apply` in which at least one build succeeded.
*   **`uv` itself.** On every `-Apply`, before any build: if the host's `uv --version` differs from `uvVersion`, the host's `uv` is copied into `.envs\bin\uv.exe` and `uvVersion` updated. If the copy fails because a running sandboxed `uv` holds the file, the old copy stays, the report adds a warning, and the builds go ahead.
*   **Inputs.** A build writes the project's inputs (Data, "Identity hash"), read with `git show <commit>:<path>`, to `.envs\work\<env name>` at the same repo-relative paths, so index and source settings and the files `pyproject.toml` names come along. Nothing is read from or written to a working tree.
*   **Build (`lock`).** In `.envs\work\<name>\<project>`: `uv sync --frozen --no-install-project`, with `UV_PROJECT_ENVIRONMENT=<.envs>\<name>`, `UV_PYTHON_INSTALL_DIR=<.envs>\python` and `UV_PYTHON_PREFERENCE=only-managed`. `--no-install-project` keeps the project out of the environment.
*   **Build (`resolve`).** With `pyproject.toml`: `uv lock` in `.envs\work\<name>`, then the same sync. With only `requirements*.txt`: `uv venv --python <interpreter> <.envs>\<name>`, then `uv pip install --python <.envs>\<name>\Scripts\python.exe -r <file>` for each file, in ordinal name order.
*   **Project path (D7).** Since nothing installs the project, nothing else puts it on `sys.path`. For a project with a `[build-system]`, the build writes `<.envs>\<name>\Lib\site-packages\_xagent_<n>.pth` (n from 1) with one line: `import os, sys; w = os.environ.get('XAGENT_WORKTREE'); w and sys.path.append(os.path.join(w, r'<root>'))`. `<root>` is the project's `src` folder at the commit if it has one, otherwise the project folder, repo-relative. `site` runs lines that start with `import`, so the same line works for `python.exe` and `uv run` (P3).
*   **Build failure.** If any `uv` step fails, the partial environment folder is deleted, `failed` records the hash with the last 20 lines of `uv`'s error, and nothing is added to `envs`. `-Apply` deletes a `failed` entry before retrying that hash.
*   **Name clash.** If the folder for a new environment's 12-hex name already belongs to a different full hash, the build records `install-failed` with `name-clash` and does not touch that folder.
*   **Rebuild.** `-SandboxEnv -Apply -Rebuild <project>` (`-Rebuild` requires `-Apply`) deletes that project's current environment (folder, stamp, `envs` and `failed` entries) under the lock, then builds it again; projects that share it are rebuilt with it. For a project with no current environment it is a normal build. `SKILL.md` names it as the fix for an environment that looks `ready` but is wrong.
*   **Prune** (on every `-Apply`, under the `.envs` lock, after any builds). Delete an environment when no project's hash at the ref names it and its `linked` stamp is older than 14 days or missing. A run is at most an hour and touches the stamp when it starts, so no live run can use an environment that old; a worktree reused later goes through the readiness gate again, and a pruned environment shows as not ready there. Deleting means its folder, `.envs\work\<name>`, its stamp and its `envs` entry. Delete an interpreter when no remaining environment uses it. Prune deletes environment folders with a recursive delete, which is safe because they contain no junctions.
*   **Readiness gate** (worker runs and probes, sandboxed only). The commit is the one the run will check out: the base ref for a new worktree; the tip of `xagent/<TaskId>` when that branch exists; the worktree's `HEAD` when the worktree folder already exists. Before any `git worktree add`, `SandboxEnv.psm1` computes the projects and their hashes at that commit and checks each is `ready`. If any is not, a worker launch fails with `sandbox: environment not ready: <project> (<status>), ...; run -SandboxEnv -Repo <repo> -Base <commit> -Apply. <proposal text>`, and a probe returns `environment-missing`. No worktree is created, and an existing one is left as it was. Linking uses the same computed list, so the gate and the links can't disagree. `-NoSandbox` runs, review lenses and council seats skip the gate and get no links.
*   **Linking** (after the worktree exists, before the process starts, under the `.envs` lock). For each project from the gate's list: touch its `linked` stamp, then create `<worktree>\<project>\.venv` as a junction to its environment. If `.venv` is already a junction, replace it. If it is a real folder, leave it, and add the `sandboxNotes` line `.venv in <project> is a real folder; environment not linked`.
*   **Grant (D6).** `New-SandboxRun -EnvPaths` adds `(OI)(CI)RX` rows for each linked environment, the interpreter folders they use and `.envs\bin`. Each is checked with `Resolve-SandboxReadEntry` first. A refusal fails the run with `sandbox: environment path '<path>' <reason>; run -SandboxEnv -Apply -Rebuild <project>`, never with the read-list message about editing `sandbox.json`. Rows go through the same ledger and removal as read-list entries.
*   **Unlinking.** First thing in `-Cleanup` and `-Cleanup -Discard` (before `-Discard`'s `git add -A`), before read-only worktree removal, and before the worktree removal in `-SandboxRun` and the canary: for each project folder at the worktree's `HEAD`, and also the worktree root, if `.venv` exists and `(Get-Item -Force).LinkType` is `Junction`, delete it with `[IO.Directory]::Delete(<path>, $false)`. This runs before any recursive walk of the worktree; the canary's fallback walk also skips reparse points.
*   **Environment variables** (from `SandboxEnv.psm1`, for sandboxed worker runs and probes with at least one linked environment). `New-SandboxRun` takes `-ExtraEnv <hashtable>` (name to value) and `-PathSuffix <string[]>`, and passes both to `Get-SandboxEnvironment`, which appends `PathSuffix` after its own `PATH` and adds `ExtraEnv`, refusing any name it already sets. The gate counts a project as not `ready` if `.envs\bin\uv.exe` is missing. The values: `PATH` suffix `<.envs>\bin`; `XAGENT_WORKTREE=<slot>:\` (D7); `UV_FROZEN=1` and `UV_NO_SYNC=1`, so `uv run` uses the linked environment as it is; `UV_PYTHON_DOWNLOADS=never`.
*   **`-SandboxRun`** (orchestrated in `delegate.ps1`, in order): the readiness gate at the ref (return `environment-missing` if it fails); `git worktree add --detach <repo>.xagent\.probe-<8 random hex> <ref>`; link; call `Invoke-SandboxCommand`; in `finally`, unlink and `git worktree remove --force`. The leading `.` keeps probe worktrees out of every task-id pattern, including `-Cleanup`'s `^<TaskId>-[a-z0-9]+$`.
*   **`Invoke-SandboxCommand`** (`Sandbox.psm1`; takes the repo, worktree, environment paths, variables, command and timeout): `Get-SandboxSlot` with the usual wait; `New-SandboxRun` with `-EnvPaths`, `-ExtraEnv` and `-PathSuffix`; `Start-SandboxProcess` with `C:\Program Files\PowerShell\7\pwsh.exe` (the full path, as the canary uses) and the arguments `-NoProfile -Command <cmd>`, the command passed as one argument through `ConvertTo-SandboxArgument`, stdout and stderr to `<repo>\.xagent\runs\probe-<hex>\`; `[XagentSandbox]::Wait` up to the timeout, then `Kill` and `Finish` on timeout; in `finally`, `Stop-SandboxRun` only if a slot was taken. `-TimeoutSec` keeps its existing range (30–3600) and default (900).

### Files

| File | Change | Why |
|---|---|---|
| `skills/delegate/scripts/SandboxEnv.psm1` | **Create.** Project discovery at a ref, identity hashes, report, build, prune, rebuild, readiness gate, link and unlink, `Invoke-SandboxUv`, and the `envs.json` reader and atomic writer. | The Rules above, in one module. |
| `skills/delegate/scripts/delegate.ps1` | **Modify.** New parameter sets `Env` (`-SandboxEnv -Repo [-Base] [-Apply] [-Rebuild <project>]`) and `SandboxRun` (`-SandboxRun -Repo -Command [-Base] [-TimeoutSec]`), each printing one JSON line. On a sandboxed, non-read-only worker launch: the readiness gate before `git worktree add`, then linking, then `New-SandboxRun` with `-EnvPaths` and `-ExtraEnv`. Cleanup unlinks first (Rules, "Unlinking"). `-SandboxRun` orchestration (Rules). Usage text updated. | G1, G3, G5, D4, and safe cleanup. |
| `skills/delegate/scripts/Sandbox.psm1` | **Modify.** `New-SandboxRun` gains `-EnvPaths` and `-ExtraEnv` and passes them to `Get-SandboxGrantList` (rows checked with `Resolve-SandboxReadEntry`) and `Get-SandboxEnvironment` (`-ExtraEnv`, `-PathSuffix`). The ACL lock's wait-and-takeover becomes a helper taking a mutex name and a timeout message. `Invoke-SandboxCanary` unlinks before its worktree removal, and its fallback walk skips reparse points. New `Invoke-SandboxCommand` (Rules). New exports: `Resolve-SandboxReadEntry`, `Invoke-SandboxCommand`, the lock helper. | One run path and one grant path for workers and probes. |
| `skills/delegate/tests/SandboxEnv.Tests.ps1` | **Create.** Pester tests on fixture repos (temporary git repos with commits): discovery at a ref, including a nested `pyproject.toml` under a lock and a workspace reported as `unsupported`; the `pyproject.toml` reader; the interpreter request from each `requires-python` form; the identity hash, including an `autocrlf` checkout giving the same hash and identical inputs in two projects sharing an environment; status order; estimates from a fixture `uv.lock`, the `null` case and the 5 GB `needsApproval`; build inputs (an index in `uv.toml` is copied); the `.pth` line and root; build failure and `failed`; name clash; rebuild; prune, including the stamp re-check; the readiness gate creating no worktree; link and unlink (unlink leaves the target intact); a corrupt `envs.json`. `uv` is a fake script through `XAGENT_UV_PATH`; no network. | Each rule tested without a sandbox. |
| `skills/delegate/tests/fixtures/sandbox-env/` | **Create.** `uv.lock`, `pyproject.toml`, `uv.toml`, `requirements.txt` and `fake-uv.ps1` (with a `fake-uv.cmd` wrapper). | Inputs for the tests above. |
| `skills/delegate/tests/Sandbox.Tests.ps1` | **Modify.** Cases for `-EnvPaths` rows and their refusal message, `-ExtraEnv` in `Get-SandboxEnvironment`, the lock helper, and `Invoke-SandboxCommand`'s argument quoting with `"` and `;` in the command. | Covers the `Sandbox.psm1` changes. |
| `skills/delegate/tests/DelegateLaunch.Tests.ps1` | **Modify.** Parameter-set cases for `-SandboxEnv` and `-SandboxRun` (accepted combinations; `-SandboxRun` with `-NoSandbox` refused); `-NoSandbox` launches skip the gate. | The CLI surface. |
| `skills/delegate/SKILL.md` | **Modify.** Invocation rows for `-SandboxEnv` and `-SandboxRun`. In "Sandbox", a section "Environments": what is built and where, the one approval, rebuilds without asking unless over 5 GB, `-Rebuild` for a wrong environment, read-only environments. The rule "an `error` that starts with `sandbox:` is not retried" gains its exception: `sandbox: environment not ready` is handled by `-SandboxEnv -Apply` (asking first when `proposal.needsApproval` is true), then the launch is retried once. `-SandboxRun` for the lead's own test runs. | `delegate`-only leads do the same as `feature` (G5). |
| `skills/feature/scripts/feature.ps1` | **Modify.** `doctor` takes an optional `-Repo`; without it the new check is left out. With it, `doctor` imports `SandboxEnv.psm1` and calls the report in-process, adding a non-required check `sandbox-env` (distinct from `sandbox`): ok when every project is `ready`; otherwise the detail lists the projects and statuses and the estimate, cut at 300 characters. An error from the report is a not-ok check with the error as detail. `uv-missing` is a not-ok, non-required check. | G5. |
| `skills/feature/tests/feature.Tests.ps1` | **Modify.** `It 'reports prerequisites'` expects eleven checks, `sandbox-env` last, when `-Repo` is passed (ten without). A case with a stubbed report: ok, not ok, an error. | Covers the doctor change. |
| `skills/feature/SKILL.md` | **Modify.** `doctor` may pass `-Repo <repo>`. | It currently says doctor passes neither. |
| `skills/feature/stages/build.md` | **Modify.** Before the first worker: `-SandboxEnv -Repo <repo> -Base feature/<name>`; if `needsApproval`, the proposal and one question; then `-Apply` with the same `-Base`. The "`sandbox:` is not retried" rule gains the same exception as `delegate`'s SKILL.md: after `-Apply`, the launch is retried once, and failing again is a problem stop. The phase test, and the phase test after merging `main`, run with `-SandboxRun -Repo <repo> -Base feature/<name>` instead of in `<repo>`; the test passes only when `status` is `ran` and `exitCode` is 0. | G5 in the feature flow. |
| `README.md` | **Modify.** "Requirements": `uv` on the host for Python repos run in the sandbox. | Non-goal: the skill doesn't install it. |
| `docs/test-plan.md` | **Modify.** Rows for the probes and the live checks below. | Records measured behaviour. |
| `docs/HANDOFF.md` | **Modify.** State of the feature at sign-off. | Handoff. |

### Phases

Each phase leaves the tree working: its checkpoint is the full Pester suite of the skills it touched.

| # | Work | Done when |
|---|---|---|
| 1 | `Sandbox.psm1`: `-EnvPaths`, `-ExtraEnv`, `-PathSuffix`, the lock helper, `Invoke-SandboxCommand`, new exports, the canary's unlink and reparse-point skip. | `skills/delegate/tests` pass; existing runs unchanged. |
| 2 | `SandboxEnv.psm1` read side: discovery, the `pyproject.toml` reader, identity hash, interpreter request, status, estimate, report, with a fake `uv`. | `SandboxEnv.Tests.ps1` read-side cases pass. |
| 3 | `SandboxEnv.psm1` write side: `-Apply` builds, `failed`, `-Rebuild`, prune, `envs.json` writes, link and unlink. | Build, prune and link cases pass with a fake `uv`. |
| 4 | `delegate.ps1`: `-SandboxEnv`, `-SandboxRun`, the readiness gate and linking on worker launch, cleanup unlinking. | `skills/delegate/tests` pass; a live `-SandboxRun` on a scratch repo returns `ran`. |
| 5 | `feature.ps1` doctor, both SKILL.md files, `build.md`, README. | `skills/feature/tests` pass; the live checks below. |

### Verification

*   **Unit:** the full Pester suites in `skills/delegate/tests` and `skills/feature/tests` pass.
*   **Live, on this machine** (lead, at sign-off):
    1.  `-SandboxEnv` on the private repo reports six `lock` projects, three interpreters and an estimate. Before `-Apply`, a worker launch is expected to fail before creating a worktree with `sandbox: environment not ready`, and a probe to return `environment-missing`.
    2.  After `-Apply`, `-SandboxRun` with one test file from each project exits 0.
    3.  A sandboxed worker on a one-line task in that repo runs `uv run pytest <one test>` and passes; the phase test then runs through `-SandboxRun` on `feature/<name>`.
    4.  `-Cleanup` of that worker leaves every environment in `.envs` intact (file counts before and after), and no slot identity is left on any `.envs` folder's access list.
    5.  `pip install` and `uv pip install` inside a sandboxed run fail with an access error.
    6.  A scratch package with a `[build-system]`: a sandboxed test imports the worktree's copy of its module.
    7.  With an environment built for lockfile A, `feature/<name>` moved on to lockfile B and B built: a worker worktree at a commit with lockfile A links the A environment; a review lens gets no `.venv` and no environment grants.
    8.  The existing `-SandboxCheck -Repo` canary still passes every row of its result.
