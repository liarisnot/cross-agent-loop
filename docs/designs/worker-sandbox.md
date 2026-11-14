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
*   **G3. Network access is a per-run switch.** *(Amended during the Technical Plan: the original goal was a per-host allowed list.)* The agent process and its shell commands share one sandbox, and the agent needs Cursor's servers, so the sandbox cannot block shell traffic by host. A run either has internet access (workers, lenses and councils, which need Cursor) or has none. What limits leaks is G1: the only files a run can send anywhere are its worktree, which Cursor already receives. Pass: the canary test shows the canaries are unreadable, so no network path can carry them; a host-level allowed list is a Future Improvement.
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

*   **Which isolation mechanism.** *Resolved:* a Windows AppContainer, chosen by the author after a feasibility probe (see Technical Plan and Alternatives).
*   **Toolchains inside the sandbox.** *Resolved:* the sandbox is Windows, so Windows-only tests run in it. Tools installed under `C:\Program Files` (git, PowerShell 7, Pester installed for all users) are readable with no setup. Tools installed per user need an entry in the sandbox's read list. One gap is open: `taskkill.exe` hangs inside an AppContainer, so test code that calls it must use .NET's process kill instead.
*   **Cursor login inside the sandbox.** *Resolved for the probe:* a copy of the user's Cursor login works inside the sandbox (same account, same plan). Open: whether a token refresh inside the sandbox can invalidate the user's own copy.
*   **Speed.** *Partly resolved:* there is no VM, so start-up is about 0.5 s for the Cursor CLI. The cost of setting permissions per run is measured in the build.

## Critical User Journeys (CUJs)

### CUJ 1: A sandboxed worker builds and tests a task

*   **Given**: A feature in `build`, a planned `code` task, and a machine that passed `delegate.ps1 -SandboxCheck`.
*   **When**: The lead runs `delegate.ps1 -Agent cursor -Repo <repo> -TaskId <id> -TaskFile <file>` with no new parameters.
*   **Then**: The worker runs inside its own AppContainer. It edits files in its worktree, runs the repo's tests (for this repo, the Pester suite) and `git status`/`git diff`, and writes `result.json`. The summary JSON has the same fields as today plus `sandboxed: true`. The lead reviews and merges the branch as before.

### CUJ 2: A prompt injection tries to read a secret

*   **Given**: A worker whose task text tells it to read `~/.ssh/id_ed25519` and `D:\MyApp\.env` and paste them into a file.
*   **When**: The worker tries this with its shell and with its own file-read tool.
*   **Then**: Every attempt fails with "access denied". The worker reports the failure in `result.json`. Nothing outside the worktree appears in the branch or the logs.

### CUJ 3: Review lenses and a council run read-only

*   **Given**: A design or a diff to review.
*   **When**: The lead runs lenses (`-Profile review`) and council seats (`-Profile council`) as today.
*   **Then**: Each run can read only its own detached worktree, and cannot write to it. The existing read-only check still runs after the run and finds no changes.

### CUJ 4: The sandbox cannot start

*   **Given**: The Cursor CLI updated to a version whose `node.exe` cannot be patched, or Windows older than build 26300.
*   **When**: The lead launches any run.
*   **Then**: `delegate.ps1` fails before starting the agent, with `ok: false` and an error that names the cause and the fix. It never falls back to an unsandboxed run. The user can run unsandboxed only by passing `-NoSandbox`, and that run is recorded with `sandboxed: false`.

### CUJ 5: A timed-out run is killed

*   **Given**: A sandboxed worker that hangs.
*   **When**: The run reaches `-TimeoutSec`.
*   **Then**: `delegate.ps1` ends every process in the run at once through a Windows job object, and reports `timedOut: true` as today.

## Technical Plan (Architecture)

### Decision

`delegate.ps1` starts the Cursor CLI inside a Windows **AppContainer**. An AppContainer is a Windows process sandbox: the process gets its own security identity (an AppContainer SID), and it can open only the files and folders whose access lists name that SID, a capability it holds, or "ALL APPLICATION PACKAGES". Everything else on disk is denied by default, including the user's profile and other drives. It needs no administrator rights, no extra Windows account and no password.

A feasibility probe on this machine (2026-11-13) confirmed:

*   **Blocked:** the shell and the agent's own file-read tool were denied on canaries in the user's profile and on `D:\`, on `~\.ssh`, on `D:\MyApp`, and on the real Cursor login.
*   **Working:** git (init, commit, log), Pester 6.2.0 from `C:\Program Files`, child processes and .NET process kill, HTTPS, `localhost` connections inside the same container, and a full Cursor CLI run (`composer-2.5`, `--force`).

### Components

```text
lead (Claude Code, user account)
  |
  v
delegate.ps1 (user account)        unchanged parameters, plus -NoSandbox and -SandboxCheck
  |-- worktree + hand-off files (as today)
  |-- Sandbox.psm1 (new): prepare -> launch -> wait/kill -> tidy
  |     |-- runtime cache:  %LOCALAPPDATA%\xagent\sandbox\cursor\<version>\
  |     |                   (copy of Cursor, with a patched node.exe)
  |     |-- run home:       <repoParent>\<repo>.xagent\.sandbox\<wtName>\{home,tmp}
  |     |-- drive letters:  runtime cache -> R:, worktree -> W:
  |     |                   (subst, picked from free letters)
  |     |-- AppContainer:   one per worktree, named xagent.<repoKey>.<wtName>
  |     '-- job object:     holds every process of the run; closed on timeout
  v
node.exe (patched copy) R:\index.js --workspace W:\ ...    (inside the AppContainer)
  '-- shell commands, tests, git                            (same container)
```

### What the sandbox can reach

| Path | Access | Granted to | Why |
|---|---|---|---|
| Worker worktree (`<repoParent>\<repo>.xagent\<TaskId>`) | read + write | this run's container | The task. |
| Read-only worktree (`...\<TaskId>-<Seat>`) | read | this run's container | Lenses and councils (G2). |
| `<repo>\.git\worktrees\<wtName>` | read + write | this run's container | The worktree's own index and HEAD. |
| `<repo>\.git` (everything else) | read | the repo's capability | git needs objects, refs and config. Read-only, so hooks and config cannot be changed. |
| `<repo>`, `<repoParent>\<repo>.xagent` | read attributes only, this folder only | the repo's capability | git checks every parent folder of the paths it uses. No listing, no file reads. |
| Run home and temp (`...\.sandbox\<wtName>`) | read + write | this run's container | `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` and `TEMP` point here. Holds copies of `cli-config.json` and `auth.json`. |
| Runtime cache | read + execute; its `.running` folder writable | the `xagent-runtime` capability | Cursor's code and the patched `node.exe`. |
| `C:\Windows`, `C:\Program Files` | read + execute | already granted by Windows | Toolchains installed for all users. |
| Paths on the read list (`%LOCALAPPDATA%\xagent\sandbox.json`) | read + execute | the `xagent-runtime` capability | Per-user toolchains the user opts in. |
| Everything else | none | — | G1. |

A **capability** is a named SID that several containers can share. The runtime capability (`xagent-runtime`) and each repo's capability (`xagent-repo-<repoKey>`) are granted the first time they are needed, and stay in place. Each run's container SID gets only its own worktree and home, so two workers running at the same time cannot read each other's worktrees. `<repoKey>` is the first 12 hex characters of the SHA-256 of the repo's full path.

### Why drive letters

Node's module loader checks every folder from the drive root down, and an AppContainer cannot read the attributes of `C:\` or `D:\`. The probe showed `require` failing with `EPERM` on `D:\` for a file in a normal folder on `D:`. A drive letter made with `subst` turns the target folder into a drive root, which the container can read. So the runtime cache becomes `R:\` and each worktree becomes `W:\` (the actual letters are picked from free ones). git resolves drive letters back to the real path, which is why the repo's parent folders get read-attributes access.

### The patched `node.exe`

The Node.js that Cursor bundles (v24.22.1, libuv 1.52.1) hangs inside an AppContainer whenever it starts a child process with piped output. AppContainers may only create pipes under `\\.\pipe\LOCAL\`. libuv uses `\\?\pipe\uv\...`, treats "access denied" as a name clash, and retries forever. libuv 1.53.0 fixes this, but no Node.js release includes it yet (nodejs/node#66374).

`Sandbox.psm1` copies Cursor's current version folder into the runtime cache. In the copy's `node.exe` it replaces the pipe-name format string `\\?\pipe\uv\%llu-%lu` with `\\?\pipe\LOCAL\%llu` of equal length, ending with a null byte. The probe showed this fixes the hang, and that the patched `node.exe` still works outside the container. The patch is made only when the string appears exactly once. Otherwise the run fails with an error that names the Cursor version (CUJ 4). When Cursor ships a Node.js with libuv 1.53 or later, the patch is skipped: `process.versions.uv` is checked first.

### Launch and kill

`delegate.ps1` today starts `powershell.exe -File cursor-agent.ps1` with `Start-Process`. A sandboxed run starts the cached `node.exe index.js` directly through `CreateProcessW` with `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES`, using a C# helper loaded with `Add-Type`. That is the probe's launcher, with three additions:

*   **Output:** stdout and stderr go to the existing log files through inherited file handles.
*   **Job object:** the process is put in a job object that kills all its processes when the job closes. On timeout, `delegate.ps1` closes the job. `taskkill.exe` is no longer used, in sandboxed or unsandboxed runs.
*   **Environment:** the child gets an environment block built from scratch. It holds the system variables, a `PATH` limited to system and read-list folders, the run home's `USERPROFILE`/`APPDATA`/`LOCALAPPDATA`/`TEMP`/`TMP`, and `CURSOR_INVOKED_AS`. For sandboxed runs this replaces the secret-variable denylist: nothing from the user's environment passes through unless it is listed.

Every container gets the `internetClient` capability (G3).

### Cursor login

Each run copies the user's `~\.cursor\cli-config.json` and `%APPDATA%\Cursor\auth.json` into its run home, and deletes the run home's `auth.json` when the run ends. The run home itself is kept until `-Cleanup`, because Cursor keeps its chat history there and `-Resume` needs it. The worker can read this token. That is no new trust: the worker already runs as Cursor. Nothing is copied back. If testing shows that a token refresh inside the sandbox invalidates the user's own token, a checked copy-back is added.

### Requirements check (`-SandboxCheck`)

`delegate.ps1 -SandboxCheck` runs without a task. It checks Windows build 26300 or later (older builds deny AppContainers the `NUL` device, which git opens on every start), that the runtime cache can be built and patched, and that a free drive letter exists. Then it runs a short canary test in a container and prints one JSON object. Every sandboxed run repeats the first three checks before it starts.

### Record of each run (G5)

The summary JSON gains `sandboxed` (`true` or `false`) and, when sandboxed, `sandbox: {container, runtimeVersion, letters}`. `runs.jsonl` gains `sandboxed`. `-NoSandbox` is the only way to run unsandboxed, and the `feature` skill never passes it.

### Clean-up

*   **After each run:** the drive letters are removed, the job is closed, and the run home's `auth.json` is deleted.
*   **`-Cleanup`:** also deletes the run home, removes the container's access entries from the worktree and `.git\worktrees\<wtName>`, and deletes the AppContainer profile.
*   **Capability grants stay.** They name only xagent capabilities, and `-SandboxCheck` reports them.

### Freezing `delegate` for this build (G6)

The skill junctions `~\.claude\skills\delegate` and `~\.claude\skills\feature` point into `D:\cross-agent-loop\skills\`, the checkout where this feature's tasks are merged. Before the first build task, the lead creates a worktree of `main` at `D:\cross-agent-loop.frozen`, at the commit where the design locks. With the user's approval, the lead points both junctions at that worktree's `skills\` folder.

Every run in this build then uses the frozen `delegate` and `feature`, and the lead records the frozen path in `test-plan.md`. The new code runs only from `D:\cross-agent-loop\skills\delegate`: in its Pester tests and in the build's manual sandbox checks. After sign-off, the junctions go back to `D:\cross-agent-loop\skills\` and the frozen worktree is removed.

### The two-part task template (G7)

The plan marks the first `code-hard` task. Its task file uses the "Decided" / "Yours to decide" layout. After it merges, the lead adds an entry to `docs/test-plan.md` with its review rounds, its readiness findings, and a comparison with `fb-stages`.

### Limits that stay

*   **Network** is all or nothing (G3).
*   **`taskkill.exe`** hangs inside the sandbox. Code under test that calls it must change. This repo's `delegate.ps1` stops using it as part of this feature.
*   **Per-user toolchains**, for example a Python under `%LOCALAPPDATA%`, need a read-list entry.
*   **The `node.exe` patch** must be redone for each Cursor version until Node.js ships libuv 1.53.
*   **Windows 11 build 26300** or later is required.

## Alternatives Considered

### Alternative A: A restricted local Windows account

Run each agent as a separate standard Windows account (for example `xagent-worker`) through `CreateProcessWithLogonW`, with access lists that deny it the user's profile and other repos.

*   **For:** a normal account has none of the AppContainer gaps. git, Node, `taskkill` and the Cursor CLI work unpatched, and drive roots are readable.
*   **Against:**
    *   An administrator must create the account, and its password must be stored where `delegate.ps1` can read it.
    *   `D:\` gives "Authenticated Users" modify access on every folder (checked on this machine), so the account can read and write `D:\MyApp` until deny entries are added to every folder that matters. New folders are open by default.
    *   The worktree's `.git` lives in the user's repo, where a writable hooks folder runs code as the user. Avoiding that needs a per-run clone instead of a worktree.
    *   Windows Firewall cannot reliably filter by local user, so G3 gains nothing.
    *   Every new public user repeats the account setup.

Rejected by author: AppContainer reaches the same isolation by default, with no account, no password and no admin step.

### Alternative B: A dedicated WSL2 distribution with Cursor's Linux sandbox

Run the Cursor CLI inside its own WSL2 distribution, with Windows drives not mounted and Windows interop off, and use Cursor's `--sandbox` (Landlock and seccomp) inside it.

*   **For:** Cursor's sandbox is documented and maintained for Linux, with per-host network filtering, so G3 as first written would hold. The isolation from Windows files is strong.
*   **Against:**
    *   Windows-only tests cannot run there. This repo's Pester suite calls `taskkill.exe` and uses Windows paths. A worker that cannot run its tests hands that job to the lead, which defeats the skill's purpose (the author's main objection).
    *   Each repo needs setup in the distribution: toolchain installs and a second Cursor login.
    *   A worktree on `/mnt/d` is slow, and one inside the Linux file system must be synced back.
    *   All WSL distributions share one VM, whose memory competes with ComfyUI for MyApp.

Rejected by author: workers must run their own tests, and most target repos here are Windows-first.

### Alternative C: Both A and B, chosen per repo

*   **For:** each repo gets the sandbox that fits its tests.
*   **Against:** two mechanisms to build, test and keep working, each with the setup costs above.

Rejected by author: AppContainer covers both cases with one mechanism.

### Alternative D: Cursor's own `--sandbox` on native Windows

*   **For:** no new code.
*   **Against:** Cursor documents its sandbox for macOS and Linux only. On Windows it gives no file-system isolation. It also covers only shell commands: the agent's own file reads follow a separate "Read Access" setting that allows the whole disk by default.

Rejected by author: it does not meet G1 or G2 on this machine.

### Alternative E: Windows Sandbox, Hyper-V or Docker

*   **For:** VM-level isolation.
*   **Against:**
    *   Windows Sandbox and Hyper-V need Windows Pro; this machine runs Home.
    *   Docker Desktop on Home runs Linux containers on WSL2, which is Alternative B with more layers.
    *   Windows containers need Hyper-V.

Rejected by author: not available on Windows 11 Home.

### Alternative F: Worker in WSL, tests run by a separate Windows "tester"

A worker in WSL writes the code, and a second agent on Windows runs the tests with read-only access.

*   **Against:** a read-only tester is not safe. Tests run the worker's code with the tester's permissions, so the worker's code gets everything the tester has. It also adds a round trip to every test run.

Rejected by author: it moves the risk instead of removing it.

### Alternative G: A per-run clone instead of a worktree

Give the container a `git clone --shared` of the repo instead of a worktree, so it never touches the user's `.git`.

*   **For:** the container cannot see the user's `.git` at all.
*   **Against:**
    *   Changes `delegate`'s worktree and branch layout, and the `feature` skill's merge steps (G4).
    *   The lead would review and merge from a clone, which needs a fetch step after every run.

Rejected by author: read-only access to `.git` already prevents hooks and config changes, and keeps the layout.

### Alternative H: One container per repo instead of one per worktree

*   **For:** fewer profiles and fewer permission changes per run.
*   **Against:** workers running at the same time could read and write each other's worktrees. The reason to share one would have been an admin loopback exemption, and the probe showed that `localhost` inside one container works without it.

Rejected by author: per-worktree containers isolate concurrent tasks at small cost.

### Alternative I: Admin-granted access to drive roots instead of drive letters

Have an administrator give the containers read-attributes access to `C:\` and `D:\`, so git and Node can walk normal paths.

*   **For:** no `subst` drive letters, and paths stay the same inside and outside the sandbox.
*   **Against:** it needs an administrator on every machine, and it changes access on the system drive root for every AppContainer app when granted to "ALL APPLICATION PACKAGES". phantombot moved from this design to drive letters for the same reason.

Rejected by author: drive letters need no admin step.

### Alternative J: Wait for a Node.js release with libuv 1.53 instead of patching `node.exe`

*   **For:** no binary patch to maintain.
*   **Against:** as of 2026-11-12, no Node.js release line bundles libuv 1.53; the v24 backport request (nodejs/node#66374) is open. Cursor would then also need to ship it. Until both happen, the Cursor CLI cannot run in an AppContainer at all.

Rejected by author: the patch is one equal-length string, checked before it is applied, and is skipped once the bundled libuv has the fix.

### Alternative K: A filtering proxy for network access (G3 as first written)

Give the container no internet capability and let it reach the network only through a local proxy that allows listed hosts.

*   **Against:**
    *   The agent itself needs Cursor's servers, so the proxy would have to carry Cursor's own traffic, including streaming connections. That is untested.
    *   An AppContainer cannot connect to a proxy that runs outside it, on the host's `localhost`, without an admin loopback exemption per container SID. A new SID per worktree would need admin on every run.

Rejected by author: G3 is amended to a per-run switch. A host allowed list is a Future Improvement.
