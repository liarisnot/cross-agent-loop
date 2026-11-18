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

The first real repo it was tried on, a private Python project, shows the failure:

*   Its tests need Python 3.11. `C:\Program Files\Python311` is readable inside the sandbox, but it is not on the sandbox `PATH`, so `python` is not found.
*   Its packages (`torch`, `numpy` and others) are installed in the user's site-packages, `C:\Users\<user>\AppData\Roaming\Python\Python311\site-packages`. The sandbox denies the whole profile, and the read list refuses anything under `AppData\Roaming` on purpose, because other programs keep credentials there.
*   So a sandboxed worker cannot run a single test of that repo. Running its workers with `-NoSandbox` would work, but it removes the protection that repo most needs: it holds a live database that experiments must never touch.

The general shape: the sandbox is safe because it sees little, and a repo's toolchain is usually installed where it can't see. Each repo's setup is different, and the user should not have to know the sandbox's rules to fix it.

## Goals

*   **G1. Detect before a worker runs.** `delegate.ps1` can run a plain command (no Cursor) inside the sandbox, in a fresh worktree of the repo, and return its exit code, the first lines of its output and a diagnosis: command not found, module or package missing, access denied, or other. It takes seconds and uses no Cursor allowance.
*   **G2. Propose, with the cost, before changing anything.** A diagnosis that has a known fix produces a proposal in plain words: what will be created, where, roughly how much disk and time, and what read-list entry will be added. Nothing is created or changed until the user says yes.
*   **G3. Set up Python on approval.** For a Python repo, the skill creates an environment the sandbox can read, installs the packages the repo needs into it, and adds it to the read list with `addToPath`. Pass: the G1 probe that failed now passes.
*   **G4. No hand setup.** The user never edits `sandbox.json`, never runs a setup command and never needs to know the sandbox's rules. Every step is proposed in chat and run by the skill.
*   **G5. Built into the flow.** `feature.ps1 doctor` reports whether the repo's environment is ready for the sandbox. Before the build starts, `feature` runs each phase's test command once in the sandbox, so a broken environment is found before the first worker's time is spent. A lead using `delegate` alone runs the same probe before its first worker.
*   **G6. Stale environments are caught the same way.** When the user later adds a package to their working environment and the sandboxed probe starts failing, the same detection offers to bring the environment up to date.
*   **G7. The sandbox does not get wider than needed.** Each fix grants read access to the environment's own folder only. Nothing under the profile root, `AppData\Roaming`, `.ssh`, `.aws`, `.gnupg` or Cursor's folders is ever granted, and the existing read-list refusals stay as they are.

## Non-Goals

*   **Every language in v1.** v1 sets up Python only. For Node, workers can already run `npm ci` inside their own writable worktree with the network on, so the probe checks that and nothing is set up. For any other toolchain, the skill reports what is missing and stops at a proposal the user acts on.
*   **Installing language runtimes.** The skill uses an interpreter that is already installed. It does not download or install Python itself.
*   **Managing the user's own working environment.** The skill reads it (to learn the packages) and never changes it.
*   **GPU access.** If a test needs the GPU and the sandbox cannot reach it, the probe reports that. Making the GPU reachable from an AppContainer is out of scope.
*   **Lockfiles and dependency management.** The skill copies what the working environment has; it does not resolve, pin or upgrade dependencies.
*   **Secrets.** No credentials, tokens or private package-index logins are copied into the environment.

## Open Questions

*   **Where the environment lives.** Not under the profile (denied) and not in the repo (worktrees hold only tracked files). Candidates: beside the worktrees in `<repo>.xagent\env\` (needs a narrow grant, because the sandbox denies reads beside the repo on purpose), under `%LOCALAPPDATA%\xagent\envs\` (inside the profile, so a profile subfolder grant), or a folder on the repo's drive the user picks once.
*   **Which packages to install.** `pip freeze` of the user site lists every package installed for that interpreter, from every project that shares it, not only this repo's. Installing all of them is simple but large; installing only what the repo imports needs a way to find that.
*   **Packages from other indexes.** A CUDA build of `torch` (for example `torch==2.x+cu128`) comes from PyTorch's own index, and `pip freeze` does not record which index a package came from. A plain `pip install -r` of the freeze fails on it.
*   **Which interpreter the repo uses.** That repo's setup script checks for 3.11. The skill needs a rule to find the right one (a `.python-version` file, `requires-python` in `pyproject.toml`, the interpreter the user's tests already run with, or ask).
*   **Keeping it in sync.** Re-check only when a probe fails, or compare the working environment's package list with the copy each time a build starts.
*   **GPU.** Whether an AppContainer can use the GPU at all is unverified.
