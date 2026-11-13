# `worker-sandbox`: confine `delegate`'s agents to their worktree

*   **Author:** Eugene Chin
*   **Status:** Draft
*   **Date:** 2026-11-13

--------------------------------------------------------------------------------

## Overview

`delegate.ps1` launches Cursor CLI agents (workers, goldfish review lenses, council seats) as the user's own Windows account. A worker runs with `--force`, so its shell commands run without approval, and its file tools may read any path. Nothing confines it to the git worktree it was given. This feature puts every `delegate` agent run inside a sandbox: a worker can read and write only its worktree (plus the tools and caches it needs to build and test), read-only runs can only read, and shell commands reach only an allowed list of network hosts. The lead's workflow does not change: `delegate.ps1` keeps its parameters and output, and the `feature` skill calls it as before.

The build has two rules of its own. First, the `delegate` code being changed is never the `delegate` that runs this feature's workers, lenses and councils: those keep using the current, tested copy, and the new code runs only in the tests that need it. Second, the first `code-hard` task in the build tries the two-part task template ("Decided" / "Yours to decide") proposed in `docs/HANDOFF.md`, and records how it compared.

## The Problem

*   **Workers can read the whole machine.** The first design's Risks table lists this as unmitigated in v1: files on disk (`~/.ssh`, `~/.aws/credentials`, `~/.npmrc`, browser profiles, other repos such as `D:\MyApp`) are readable by any worker. A worker reads repository text, web pages and tool output, and any of these can carry a prompt injection. One injected instruction can make a worker read a secret and print it into a commit, a log, or a network request.
*   **Workers can write outside their worktree.** A wrong `rm -rf`, a bad path in a script, or a test that writes to `%TEMP%` paths it doesn't own can damage the user's files. Diff review sees only the worktree, so damage outside it is invisible to the lead.
*   **Shell commands can reach any host.** A worker's commands can upload files anywhere. The secret-variable denylist added in build step 1 strips environment variables only; it does nothing about files or the network.
*   **Read-only runs are only read-only by request.** Review lenses run in Cursor's `ask` mode and council seats in `plan` mode. These modes stop edits, but the agent can still read outside the worktree.
*   **Cursor's own sandbox does not cover this machine.** The Cursor CLI has a `--sandbox` flag, but Cursor documents its sandbox for macOS (Seatbelt) and Linux (Landlock and seccomp) only. On native Windows it gives no file-system isolation, and its network blocking is at best partial. It also covers shell commands only: the agent's own file reads follow a separate "Read Access" setting whose default allows the whole disk.
*   **This machine is Windows 11 Home.** Windows Sandbox and Hyper-V need Pro, so they are not available. WSL2 is installed (Ubuntu, version 2).

## Goals

*   **G1. Files outside the worktree are out of reach.** A worker can read and write its worktree, and read only the tools, runtimes and caches on an explicit list. It cannot read or write anything else, including the user's profile, other repos and other drives. Pass: a canary test plants a secret file in the user's profile and one in another repo; a worker told to read both, list the user's home folder, and write a file outside its worktree fails at every step, and the canary contents appear nowhere in the run's logs or branch.
*   **G2. Read-only runs stay read-only.** Review lenses and council seats can read their worktree and nothing else, and cannot write. Pass: the canary test, run as a lens, fails to read the canaries and leaves the worktree unchanged.
*   **G3. Shell network access is limited to an allowed list.** Shell commands reach only the hosts on a list (package registries the target repo needs). The agent's own connection to Cursor's servers is unaffected. Pass: a worker's `curl` to a host not on the list fails, and to a listed registry succeeds.
*   **G4. The workflow does not change.** `delegate.ps1` keeps its parameters, JSON output, worktree and branch layout, and log files. Workers still leave a branch in the user's repo that the lead reviews and merges with the existing commands. Pass: `delegate`'s regression from the first design's Verification Plan passes with the sandbox on, and the `feature` skill needs no change to call it.
*   **G5. No silent fallback.** If the sandbox cannot start, `delegate.ps1` fails the run with a clear error. Running unsandboxed takes an explicit opt-out, and the summary and `runs.jsonl` record whether each run was sandboxed. Pass: a test breaks the sandbox setup and gets a failed run, not an unsandboxed one.
*   **G6. The build never runs on half-built `delegate` code.** This feature's own workers, lenses and councils use the current, tested `delegate`, which is frozen for the whole build. The new code runs from a separate copy, and only in the tests that need it. Pass: every run of this feature's build is launched from the frozen copy (its path is in the run logs), and no run fails because of an unfinished change.
*   **G7. Try the two-part task template.** The first `code-hard` task in the build uses a task file split into "Decided" (outcome, boundaries, shared interfaces) and "Yours to decide" (internals, names, internal tests, order of work). Pass: an entry in `docs/test-plan.md` records the task's review rounds, readiness findings and the lead's view next to the earlier tightly specified `code-hard` run (`fb-stages`).

## Non-Goals

*   **Keeping code from Cursor.** The agent sends the files it reads to Cursor's model servers; that is how it works. The sandbox limits what it can read, not what it sends to Cursor.
*   **Sandboxing the lead.** Claude Code runs as the user, as it does today.
*   **Other host systems.** macOS and Linux hosts, Windows Pro features (Windows Sandbox, Hyper-V), and cloud runners are out of scope. The design targets this machine: Windows 11 Home with WSL2.
*   **Antigravity.** `agy` stays refused (T0).
*   **Hardening against a malicious Cursor CLI.** The CLI binary and Cursor's servers are trusted. The threat is the model being misled by its inputs or making mistakes, not the tool itself.
*   **New review or planning features.** Lenses, councils and the `feature` stages are unchanged apart from launching through the sandbox.

## Open Questions

*   **Which isolation mechanism.** A restricted Windows account, a dedicated WSL2 distribution using Cursor's Linux sandbox, or a mix. The author decides this in the Technical Plan, from up to three options.
*   **Toolchains inside the sandbox.** Some target repos test only on Windows (this repo's Pester suite calls `taskkill.exe` and Windows paths). If the sandbox is Linux, these tests can't run there. Does a worker then skip tests and leave them to the lead, or does the sandbox have to be Windows?
*   **Cursor login inside the sandbox.** A separate account or a WSL distribution needs its own Cursor CLI login. Is a second login on the same Cursor plan allowed, and does it share the usage pools?
*   **Speed.** A worktree on a Windows drive seen from WSL (`/mnt/d`) is slow for git and file-heavy tests; a worktree inside the WSL file system needs syncing back. The overhead per run must be measured before it is accepted.
