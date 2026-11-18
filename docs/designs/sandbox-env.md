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
*   **G2. Propose, with the cost, before changing anything.** A diagnosis that has a known fix produces a proposal in plain words: what will be created, where, roughly how much disk and time, and what read-list entry will be added. Nothing is created or changed until the user says yes.
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

*   **Where the environments live.** Not under the profile (denied) and not in the repo (worktrees hold only tracked files). Candidates: beside the worktrees in `<repo>.xagent\env\` (needs a narrow grant, because the sandbox denies reads beside the repo on purpose), under `%LOCALAPPDATA%\xagent\envs\` (inside the profile, so a profile subfolder grant), or a folder on the repo's drive the user picks once.
*   **Where the interpreters come from.** Copy each one a project needs into the reachable folder (`uv` can install a Python into a chosen folder, from its own download cache), grant only the ones already readable, or install new ones.
*   **Projects without a lockfile.** A project with only `requirements.txt`, or with nothing but a `.venv`, has no full record of its packages or of the index each came from. Support them in v1 (by copying what the `.venv` holds), or report them and stop.
*   **Several environments on one `PATH`.** A repo with six projects needs six environments, and only one `python` can be first on `PATH`. Tests then have to be run with each project's own interpreter, which the probe and the task files must know.
*   **Keeping it in sync.** Compare each `uv.lock` with what the environment was built from at every build start, or re-check only when a probe fails.
*   **Disk.** One environment per project with CUDA `torch` costs several gigabytes. `uv` can hard-link from its cache when the cache and the environment are on the same drive; across drives it copies.
*   **GPU.** Whether an AppContainer can use the GPU at all is unverified.
