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
  |     |-- run home:       <worktree>\.xagent\sandbox\{home,tmp}  (seen as W:\.xagent\sandbox)
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
| Run home and temp (`<worktree>\.xagent\sandbox`) | read + write, also in read-only runs | this run's container | `USERPROFILE`, `APPDATA`, `LOCALAPPDATA` and `TEMP` point here, through the worktree's drive letter, so Node tools can reach them too. `.xagent/` is already in the repo's `info/exclude`. Holds copies of `cli-config.json` and `auth.json`. |
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
*   **`-Cleanup`:** removes the worktree (and with it the run home) as today, removes the container's access entries from the worktree and `.git\worktrees\<wtName>`, and deletes the AppContainer profile.
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

## Non-Functional Requirements

### Security

| Risk | Handling |
|---|---|
| The worker reads the Cursor token copied into its run home and sends it elsewhere. | Accepted. The worker already acts with that token; the sandbox does not widen this. The copy is deleted after each run. |
| The worker edits files in the user's repo through `.git`. | `.git` is read-only to the sandbox, apart from the worktree's own folder under `.git\worktrees`. Hooks, config and refs cannot change. |
| A worker on one task tampers with another task's worktree. | Each worktree has its own container SID. Shared capabilities grant read access only. |
| A drive letter made by `subst` is visible to the user's other programs while a run is active. | It points only into the worktree and the runtime cache. It is removed after the run, and `-SandboxCheck` lists stale ones. |
| The patched `node.exe` does something other than what the patch intends. | The patch changes one string of equal length, only when it appears exactly once. The patched file is stored with its source version and SHA-256 in `patch.json`, next to the copy. |
| Capability grants outlive the feature. | They name only `xagent-*` capabilities. `-SandboxCheck -Remove` removes them all (see `Sandbox.psm1`). |

### Performance

*   **Per run:** target 5 s or less added before the agent starts, after the first run of a Cursor version. That covers the container profile, the worktree grants, the drive letters and the run home. Measured in phase 5.
*   **First run of each Cursor version:** copying about 256 MB into the runtime cache and patching it. The cache keeps the current and previous version and deletes older ones.
*   **Memory:** no VM, so there is no fixed memory cost. A sandboxed run uses the same memory as an unsandboxed one.

### Rollout and rollback

*   **Rollout:** sandboxing is on by default as soon as the change merges. A machine that fails the requirements check gets `ok: false` with the reason (G5).
*   **Rollback:** `-NoSandbox` runs one task unsandboxed, recorded in the summary and `runs.jsonl`. A full rollback reverts the merge. Capability grants left behind have no effect without the code.

### Additional Resources

*   `docs/designs/feature-skill.md`: the Risks row "workers can read the whole machine", and the Verification Plan regression used for G4.
*   Probe scripts and debugging findings: `docs/designs/worker-sandbox-probe/` (README lists findings not repeated here, e.g. Windows PowerShell 5.1 and `cscript` failing inside the container).
*   Related work:
    *   KPO-Tech/seshat-runtime PR #816 (git inside AppContainer);
    *   phantomyard/phantombot PR #787 (drive letters instead of admin grants);
    *   libuv/libuv#5178 and nodejs/node#66374 (pipe names);
    *   openclaw/openclaw PR #161128 (the same hang, handled by refusing to spawn).

### Future Improvements

*   **Host allowed list for network access:** a proxy that carries Cursor's own traffic too, once loopback rules and Cursor's streaming connections are tested (Alternative K).
*   **Drop the `node.exe` patch** once Cursor bundles libuv 1.53 or later. The version check already skips it then; the code can be removed after one Cursor release.
*   **Per-repo read lists** in addition to the one user-wide list.
*   **Run the lead's own test runs in the sandbox,** so a test that runs worker code is also confined.

## Detailed Implementation Plan

### Machine setup (outside the repo, not committed)

*   **Pester 6.2.0 for all users:** done on 2026-11-13, at `C:\Program Files\PowerShell\Modules\Pester\6.2.0`.
*   **Freeze (G6), before phase 1:**
    *   `git worktree add --detach D:\cross-agent-loop.frozen <commit where the design locks>`.
    *   With the user's approval, point `~\.claude\skills\delegate` and `~\.claude\skills\feature` at `D:\cross-agent-loop.frozen\skills\delegate` and `...\skills\feature` (`cmd /c rmdir` on each junction, then `New-Item -ItemType Junction`).
    *   Record the frozen path and commit in `docs/test-plan.md`.
*   **After sign-off:** point both junctions back at `D:\cross-agent-loop\skills\...`, then `git worktree remove D:\cross-agent-loop.frozen`.

### Target Files to Create/Modify

#### 1. `skills/delegate/scripts/SandboxNative.cs` (Create)

*   **Type / Scope:** C# source, loaded by `Sandbox.psm1` with `Add-Type -Path`.
*   **Proposed Changes:** one static class `XagentSandbox` with:
    *   `string EnsureProfile(string name)`: `CreateAppContainerProfile`, or `DeriveAppContainerSidFromAppContainerName` when it already exists; returns the SID string.
    *   `void DeleteProfile(string name)`.
    *   `string CapabilitySid(string name)`: `DeriveCapabilitySidsFromName`; returns the capability SID (not the group SID).
    *   `RunHandle Start(string containerSid, string[] capabilitySids, string exePath, string commandLine, string cwd, string[] environment, string stdoutPath, string stderrPath)`:
        *   creates a job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`;
        *   opens the two log files as inheritable handles;
        *   builds `STARTUPINFOEX` with `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES` and `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` (only the two log handles and a `NUL` stdin are inherited);
        *   calls `CreateProcessW` with `CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT`;
        *   assigns the process to the job, then resumes it.

        `RunHandle` holds the process id, the process handle and the job handle.
    *   `bool Wait(RunHandle h, int ms)`, `int ExitCode(RunHandle h)`, and `void Kill(RunHandle h)`. `Kill` uses `TerminateJobObject`, then closes the job.
    *   `bool IsAppContainer()`: reads `TokenIsAppContainer` for the current process. Tests use it to skip what cannot run nested.

    The code takes its signatures from the probe's `AC` class, which ran on this machine.

#### 2. `skills/delegate/scripts/Sandbox.psm1` (Create)

*   **Type / Scope:** PowerShell module, imported by `delegate.ps1`.
*   **Proposed Changes:** exported functions, each returning a hashtable or throwing with a message that names the cause and the fix.
    *   `Test-SandboxSupport`:
        *   checks the Windows build (`[Environment]::OSVersion.Version.Build -ge 26300`), the Cursor install (`%LOCALAPPDATA%\cursor-agent\versions\<latest>\node.exe` and `index.js`), and at least two free drive letters;
        *   returns `{ok, build, cursorVersion, freeLetters, problems[]}`.
    *   `Get-SandboxRuntime`:
        *   ensures `%LOCALAPPDATA%\xagent\sandbox\cursor\<version>\` exists. If not, it copies the version folder to `<version>.partial` and renames it when complete.
        *   Then it runs the patch:
            *   it reads `node.exe` as bytes and runs the copy with `-p process.versions.uv`. At 1.53 or later it writes `patch.json` with `{patched:false, uv}` and stops.
            *   Otherwise it counts the ASCII occurrences of `\\?\pipe\uv\%llu-%lu`. If the count is not exactly 1, it throws `"Cursor <version>: node.exe pipe-name pattern found <n> times; sandboxed runs need an update to Sandbox.psm1. Use -NoSandbox to run unsandboxed."`.
            *   On exactly 1, it writes `\\?\pipe\LOCAL\%llu` plus a 0 byte at that offset, and writes `patch.json` with `{patched:true, offset, uv, sourceSha256, patchedSha256}`.
        *   It grants the runtime capability `(OI)(CI)RX` on the version folder, and `(OI)(CI)M` on `.running\` inside it.
        *   It deletes cache versions other than this one and the one before.
        *   Returns `{root, version, uv, patched}`.
    *   `Get-RepoKey -Repo`: the first 12 hex characters of the SHA-256 of the lower-cased full path.
    *   `Grant-RepoAccess -Repo`:
        *   is idempotent: it checks with `Get-Acl` before calling `icacls`.
        *   gives `xagent-repo-<key>` `(OI)(CI)RX` on `<repo>\.git`, and `RA` with no inheritance on `<repo>` and `<repoParent>\<repo>.xagent`.
    *   `Get-FreeDriveLetter`:
        *   picks the highest free letter from `Z` down to `H`, skipping letters in use (`Get-PSDrive -PSProvider FileSystem` plus `subst` output).
        *   The choice is protected by a named mutex `Global\xagent-subst`, so two runs starting together do not take the same letter.
    *   `New-SandboxRun -Repo -Worktree -WtName -ReadOnly`:
        *   creates the profile `xagent.<key>.<WtName>` (names over 64 characters are cut and a 6-character hash added).
        *   It grants the container `(OI)(CI)M` on the worktree for workers, or `(OI)(CI)RX` for read-only runs. It also grants `(OI)(CI)M` on `<worktree>\.xagent\sandbox` and on `<repo>\.git\worktrees\<WtName>`.
        *   It creates `home\.cursor`, `home\AppData\Roaming\Cursor`, `home\AppData\Local` and `tmp`, and copies `cli-config.json` and `auth.json`.
        *   It maps the worktree and the runtime cache to drive letters with `subst`. The runtime letter is reused if a mapping to the same cache already exists.
        *   Returns `{container, sid, capabilities, worktreeLetter, runtimeLetter, home, env}`.
        *   `env` is the environment array:
            *   `SystemRoot`, `windir`, `ComSpec`, `PATHEXT`, `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE` and `OS`;
            *   `PATH` (`C:\Windows\System32`, `C:\Windows`, `C:\Windows\System32\WindowsPowerShell\v1.0`, `C:\Program Files\PowerShell\7`, `C:\Program Files\Git\cmd`, then the read list's `path` entries);
            *   `USERPROFILE`, `HOME`, `APPDATA`, `LOCALAPPDATA`, `TEMP` and `TMP` (under `<W>:\.xagent\sandbox`);
            *   `PSModulePath` (`C:\Program Files\PowerShell\Modules;C:\Program Files\PowerShell\7\Modules`);
            *   `CURSOR_INVOKED_AS=agent.cmd`.
    *   `Start-SandboxProcess -Run -CliArgs -StdoutPath -StderrPath`: builds the command line `"<R>:\node.exe" "<R>:\index.js" <args>` with the existing `Quote` rules, starts it through `XagentSandbox.Start`, and returns the handle.
    *   `Stop-SandboxRun -Run` (after every run): removes both `subst` letters (the runtime letter only when no other live run uses it, tracked by `.running` files in `%LOCALAPPDATA%\xagent\sandbox\letters\`), and deletes the run home's `auth.json`.
    *   `Remove-SandboxRun -Repo -WtName` (at `-Cleanup`): `icacls /remove` on the worktree's `.git\worktrees\<WtName>` folder (the worktree folder itself is deleted by the existing cleanup), and `DeleteProfile`.
    *   `Invoke-SandboxCanary`:
        *   creates a temporary repo under `<TEMP>\xagent-canary-<rand>` and plants canaries in `%USERPROFILE%` and next to the repo's parent.
        *   It runs `pwsh -NoProfile -File` on a fixed in-container script, which tries to read both canaries and list `%USERPROFILE%`, then runs `git init`/`commit` and `node -e` with a piped child.
        *   It returns `{ok, results[]}` and always cleans up, as the probe did.
    *   `Remove-SandboxGrants`: removes every `xagent-*` capability entry from the runtime cache, from every repo listed in `%LOCALAPPDATA%\xagent\sandbox\repos.json` (written by `Grant-RepoAccess`), and from read-list paths.
    *   **Read list:** `%LOCALAPPDATA%\xagent\sandbox.json` (optional) is `{ "read": [ {"path": "C:\\Users\\me\\AppData\\Local\\Programs\\Python\\Python312", "addToPath": true} ] }`. Each entry gets the runtime capability `(OI)(CI)RX`. An entry under `%USERPROFILE%` is refused if it is the profile root, `.ssh`, `.aws`, `.cursor` or `AppData\Roaming` as a whole.

#### 3. `skills/delegate/scripts/delegate.ps1` (Modify)

*   **Type / Scope:** the launch script.
*   **Proposed Changes:**
    *   **Parameters:** add `[switch]$NoSandbox`, `[switch]$SandboxCheck` and `[switch]$Remove` (valid only with `-SandboxCheck`).
        *   `-SandboxCheck` makes `-Repo` and `-TaskId` optional: the `Mandatory` attributes move into a parameter set, with the default set unchanged for every existing call.
        *   It prints `{ok, support, runtime, canary, grants, staleLetters}` and exits. With `-Remove` it runs `Remove-SandboxGrants` instead.
    *   **Launch, `cursor` agent:**
        *   Unless `-NoSandbox`, call `Test-SandboxSupport` (`Fail` with its problems), `Get-SandboxRuntime`, `Grant-RepoAccess` and `New-SandboxRun`.
        *   `--workspace` becomes `<W>:\` instead of `$wt`.
        *   Start through `Start-SandboxProcess`. The pid file keeps its format, with `childPid` as the sandboxed `node.exe`.
        *   Wait with `XagentSandbox.Wait`, and on timeout call `Kill`.
        *   `Stop-SandboxRun` runs in the existing `finally`.
    *   **Unsandboxed path (`-NoSandbox`):** keep `Start-Process` and the secret denylist. Replace `taskkill.exe` with `$proc.Kill($true)`, wrapped in try/catch.
    *   **Summary and `runs.jsonl`:** add `sandboxed` and, when sandboxed, `sandbox = {container, runtimeVersion, patched, worktreeLetter, runtimeLetter}`. `worktree` stays the real path (G4).
    *   **`-Cleanup`:** call `Remove-SandboxRun` before the worktree is removed. A failure there is reported in the cleanup JSON but does not stop the cleanup.
    *   **`agy`:** unchanged (still disabled). If it is ever enabled, it runs only with `-NoSandbox`.
    *   **Help comment:** add the sandbox guardrail and the new layout lines.

#### 4. `skills/feature/scripts/feature.ps1` (Modify)

*   **Type / Scope:** the feature state script.
*   **Proposed Changes:**
    *   Replace the three `taskkill.exe` calls (orphan kill in reconcile, the `verify` timeout, and the generic timeout helper) with one helper, `Stop-ProcessTree -ProcessId`. It calls `[Diagnostics.Process]::GetProcessById($id).Kill($true)`, ignores "process has exited", and waits up to 10 s. This makes the suite runnable inside the sandbox, where `taskkill.exe` hangs.
    *   `doctor` gains a `sandbox` entry: it runs `delegate.ps1 -SandboxCheck` and shows `ok` and `problems`.

#### 5. `skills/delegate/tests/Sandbox.Tests.ps1` (Create)

*   **Type / Scope:** Pester 6 tests.
*   **Proposed Changes:**
    *   **Unit tests (no container):**
        *   the patch on synthetic `node.exe` byte files: pattern once (patched, `patch.json` correct), zero times (throws the named error), twice (throws), and libuv ≥ 1.53 (skipped; `process.versions.uv` is mocked);
        *   `Get-RepoKey` is stable and case-insensitive;
        *   `Get-FreeDriveLetter` skips letters in use;
        *   the environment array has no variable outside the listed set, even when the test sets `GH_TOKEN` and `AWS_SECRET_ACCESS_KEY`;
        *   read-list entries for `~\.ssh` and the profile root are refused;
        *   the profile name is shortened past 64 characters.
    *   **Container tests** (tag `Sandbox`, skipped when `IsAppContainer()` is true or the build is below 26300):
        *   `New-SandboxRun` plus a `pwsh` canary script, covering CUJ 2 without Cursor;
        *   a read-only run cannot write its worktree but can write its run home (G2);
        *   two runs at the same time cannot read each other's worktrees;
        *   a timed-out sleeper tree dies on `Kill` (CUJ 5);
        *   `Stop-SandboxRun` removes the letters and `auth.json`, and `Remove-SandboxRun` removes the access entries and the profile.
    *   **Live test** (tag `Live`, excluded by default): `delegate.ps1` with a real Cursor worker (`composer-2.5`) on a temporary repo, told to read the canaries. It passes when no canary text appears in the logs, summary or branch, and `sandboxed` is `true`.

#### 6. `skills/delegate/tests/DelegateLaunch.Tests.ps1` (Create)

*   **Type / Scope:** Pester 6 tests for the `delegate.ps1` changes.
*   **Proposed Changes:**
    *   `-NoSandbox` gives `sandboxed: false` in the summary and `runs.jsonl` (with `XAGENT_LOG_DIR` pointed at `TestDrive`).
    *   A failing `Test-SandboxSupport` (mocked through a `XAGENT_SANDBOX_FORCE_FAIL` test variable that only the module reads) gives `ok: false` with the reason, and no agent starts (G5).
    *   `-SandboxCheck` without `-Repo` and `-TaskId` is accepted.
    *   Existing calls without the new switches still bind (G4).

#### 7. `scripts/test.ps1` (Create)

*   **Type / Scope:** the repo's one test command, for workers and the lead.
*   **Proposed Changes:**
    *   Imports Pester 6.2.0 or later and runs `skills/feature/tests` and `skills/delegate/tests`.
    *   Sets `TestRegistry.Enabled = $false`, because Pester's test registry writes under `HKCU\Software\Pester`, which an AppContainer cannot write. Excludes the `Live` tag, and `Slow` with `-Fast`.
    *   Exits with the failed count.
    *   `docs/test-plan.md` and the task template's test line point to it.

#### 8. `skills/delegate/SKILL.md` (Modify)

*   **Type / Scope:** skill instructions.
*   **Proposed Changes:**
    *   A "Sandbox" section: what a run can reach (the table in short), `-SandboxCheck` as a setup step, and `-NoSandbox` only when the user asks.
    *   The read list file, and the limits (no `taskkill`, per-user tools need the read list, all-or-nothing network).
    *   A line in "Failed runs": a sandbox start failure is not retried and is reported to the user.

#### 9. `skills/feature/templates/task.md` (Modify)

*   **Type / Scope:** worker task template.
*   **Proposed Changes:**
    *   The test instruction names `pwsh -NoProfile -File scripts/test.ps1` when the repo has it.
    *   One sentence: "You run in a sandbox: only this worktree, your home and temp folders, and installed tools are readable; do not try to work around access errors, report them."

    The two-part G7 layout is not added to the template. The G7 task file is written by hand in the plan stage, and the template changes only after the comparison.

#### 10. `README.md` (Modify)

*   **Type / Scope:** user-facing requirements.
*   **Proposed Changes:**
    *   Requirements: Windows 11 build 26300 or later, and Pester installed for all users for sandboxed test runs.
    *   Setup: run `delegate.ps1 -SandboxCheck` once.
    *   A short note on what the sandbox blocks.

#### 11. `docs/designs/feature-skill.md` (Modify)

*   **Type / Scope:** the first design's Risks table.
*   **Proposed Changes:** the "workers can read the whole machine" row changes from "unmitigated in v1" to "mitigated by `worker-sandbox` (see `docs/designs/worker-sandbox.md`)". This is a post-lock amendment line, in the same style as D19.

#### 12. `docs/test-plan.md` (Modify)

*   **Type / Scope:** test log.
*   **Proposed Changes:** new entries for:
    *   the frozen `delegate` path and commit (G6);
    *   the canary run results (G1, G2);
    *   the overhead per run;
    *   the token-refresh check;
    *   the G7 comparison.

#### 13. `docs/HANDOFF.md` (Modify)

*   **Type / Scope:** session hand-off.
*   **Proposed Changes:** the status of `worker-sandbox`, and the Node.js libuv 1.53 watch item, linking nodejs/node#66374.

### Build order

| Phase | Tasks | Profile | Depends on |
|---|---|---|---|
| 1 | `Stop-ProcessTree` in `feature.ps1`; `scripts/test.ps1`; `taskkill` removal in the unsandboxed `delegate.ps1` path | `code` | — |
| 2 | `SandboxNative.cs`; `Sandbox.psm1` support check, runtime cache and patch, repo key, drive letters; unit tests (file 5, unit part) | `code-hard` (first one: G7 template) | — |
| 3 | `Sandbox.psm1` run setup, launch, stop, remove, canary, grants removal; container tests | `code-hard` | 2 |
| 4 | `delegate.ps1` wiring, `-SandboxCheck`, `-NoSandbox`, summary fields, cleanup; file 6; `feature.ps1 doctor` entry | `code` | 1, 3 |
| 5 | Docs (files 8–13); live canary, regression, overhead and token-refresh checks | lead, with one `code` task for docs | 4 |

Phases 1 and 2 have no shared files and can run at the same time. Workers in this build are not sandboxed: they use the frozen `delegate` (G6).

### Verification Plan

*   **Unit and container tests:** `pwsh -NoProfile -File scripts/test.ps1`. All tests pass: the 218 existing ones and the new ones.
*   **The suite inside the sandbox (G1 with real work, CUJ 1):** after phase 4, the lead runs one sandboxed worker from `D:\cross-agent-loop\skills\delegate` (not the frozen copy) on a small task in this repo. The worker runs `scripts/test.ps1 -Fast` and reports the results in `result.json`. Pass: the suite passes inside the sandbox, apart from tests tagged `Sandbox`, which skip themselves.
*   **Canary (G1, G2, CUJ 2, CUJ 3):** the `Live` test as a worker, then the same canaries as a `review` lens and a `council` seat. Pass: every attempt is denied, no canary text appears anywhere, and the read-only worktrees are unchanged.
*   **Regression (G4):** the `delegate` regression from `docs/designs/feature-skill.md`'s Verification Plan, with the sandbox on. Pass: the same results as the last unsandboxed run recorded in `test-plan.md`.
*   **Failure (G5, CUJ 4):** a copy of the runtime cache with the pattern removed, plus `XAGENT_SANDBOX_FORCE_FAIL`. Pass: `ok: false` with the named error, no agent process started, and nothing written to `runs.jsonl` as sandboxed.
*   **Timeout (CUJ 5):** a worker task that runs `Start-Sleep 600` with `-TimeoutSec 30`. Pass: `timedOut: true` within 45 s, and no `node.exe` or `pwsh.exe` left from the run.
*   **Overhead:** the time from `delegate.ps1` start to agent start, sandboxed and unsandboxed, over 5 runs each. Target: 5 s or less extra (median), after the first run of a Cursor version.
*   **Token refresh:** after 3 sandboxed runs over at least one day, `cursor-agent status` outside the sandbox still shows the user logged in.
*   **G6:** every `runs.jsonl` line of this feature's build shows the frozen skill path in the lead's `test-plan.md` record. No build run fails because of unfinished sandbox code.
*   **G7:** the `test-plan.md` entry for the first `code-hard` task exists, with its review rounds, readiness findings and the comparison with `fb-stages`.
