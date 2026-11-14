# `worker-sandbox`: confine `delegate`'s agents to their worktree

*   **Author:** Eugene Chin
*   **Status:** Draft
*   **Date:** 2026-11-13 (revised 2026-11-14 after design review round 1, `docs/features/worker-sandbox/reviews/design-1.md`)

--------------------------------------------------------------------------------

## Overview

`delegate.ps1` launches Cursor CLI agents as the user's own Windows account: workers, goldfish review lenses and council seats. A worker runs with `--force`, so its shell commands run without approval, and its file tools may read any path. Nothing confines it to the git worktree it was given.

This feature puts every `delegate` agent run inside a Windows AppContainer:
*   a worker can read and write only its worktree, plus the installed tools it needs to build and test;
*   read-only runs can change no tracked file;
*   nothing else on disk is reachable.

Network access stays on, because every run needs Cursor's servers. What a run can leak is limited by what it can read. The lead's workflow does not change: `delegate.ps1` keeps its parameters and output, and the `feature` skill calls it as before.

The build has two rules:
1.  The `delegate` code being changed is never the `delegate` that runs this feature's workers, lenses and councils. Those use `main` at the commit where this design locks, and the new code runs only in the tests that need it.
2.  The phase-3 `code-hard` task tries the two-part task template ("Decided" / "Yours to decide") proposed in `docs/HANDOFF.md`, and records how it compared.

## The Problem

*   **Workers can read the whole machine.** The first design's Risks table (`docs/designs/feature-skill.md`, row "Workers can read any file and reach the network") lists this as unmitigated in v1. Files on disk are readable by any worker: `~/.ssh`, `~/.aws/credentials`, `~/.npmrc`, browser profiles, and other repos such as `D:\MyApp`. A worker reads repository text, web pages and tool output, and any of these can carry a prompt injection. One injected instruction can make a worker read a secret and print it into a commit, a log, or a network request.
*   **Workers can write outside their worktree.** A wrong `rm -rf`, a bad path in a script, or a test that writes to `%TEMP%` paths it doesn't own can damage the user's files. Diff review sees only the worktree, so damage outside it is invisible to the lead.
*   **Shell commands can reach any host.** A worker's commands can upload anything they can read. Today's only mitigation is a denylist in `delegate.ps1` (`$secretPattern`, added in the `feature` skill's build step 1). It strips environment variables whose names look like secrets (`*_API_KEY`, `*_TOKEN`, `AWS_*` and similar) and does nothing about files or the network.
*   **Read-only runs are only read-only by request.** Review lenses run in Cursor's `ask` mode and council seats in `plan` mode. These modes stop edits, but the agent can still read outside the worktree.
*   **Cursor's own sandbox does not cover this machine.** The Cursor CLI has a `--sandbox` flag, but Cursor documents its sandbox for macOS (Seatbelt) and Linux (Landlock and seccomp) only. On native Windows it gives no file-system isolation, and its network blocking is at best partial. It also covers shell commands only: the agent's own file reads follow a separate "Read Access" setting whose default allows the whole disk.
*   **This machine is Windows 11 Home.** Windows Sandbox and Hyper-V need Pro, so they are not available. WSL2 is installed (Ubuntu, version 2).

## Goals

*   **G1. Files outside the worktree are out of reach.**
    *   A worker can read and write its worktree, and read only installed tools and the paths on an explicit read list. It cannot read or write anything else, including the user's profile, other repos and other drives.
    *   **Pass:** a canary test plants a secret file in the user's profile and one next to the repo. A worker is told to read both, list the user's home folder, and write a file outside its worktree. Every step fails, and the canary contents appear in none of the run's logs, summary or branch.
*   **G2. Read-only runs change nothing tracked.**
    *   Review lenses and council seats can read their own worktree and nothing else. They cannot change git-tracked files. They can write only their run home under `.xagent/`.
    *   **Pass:** the canary test, run as a lens and as a council seat, fails to read the canaries. Afterwards `git status --porcelain --untracked-files=no` in the worktree is empty. That is the read-only check `delegate.ps1` already runs.
*   **G3. Network access stays on; file isolation limits what can leak.** *(Amended twice during design: the first goal was a per-host allowed list, then a per-run switch.)*
    *   The agent process and its shell commands share one container, and the agent needs Cursor's servers. So every sandboxed run has internet access. A run can send only what it can read: its worktree (which Cursor receives anyway) and the copy of the user's Cursor login in its run home (an accepted risk, see Risks and Mitigations).
    *   The host's own `localhost` is blocked by default. Windows gives AppContainers no loopback access to the host.
    *   **Pass:** the G1 canary test passes with internet on.
*   **G4. The workflow does not change.**
    *   `delegate.ps1` keeps its parameters, its JSON output, its worktree and branch layout, and its log files. Workers still leave a branch in the user's repo, which the lead reviews and merges with the existing commands.
    *   **Pass:** `delegate`'s regression from the first design's Verification Plan passes with the sandbox on, and the `feature` skill needs no change to call it.
*   **G5. No silent fallback.**
    *   If the sandbox cannot start, `delegate.ps1` fails the run with an error that starts with `sandbox:` and names the cause and the fix.
    *   Running unsandboxed takes an explicit `-NoSandbox`. The summary and `runs.jsonl` record whether each run was sandboxed.
    *   **Pass:** two tests break the sandbox setup; each gets a failed run and no agent process.
*   **G6. The build never runs on half-built `delegate` code.**
    *   This feature's own workers, lenses and councils use `main` at the commit where this design locks. That copy is frozen for the whole build. The new code runs from the live checkout, and only in the tests that need it.
    *   **Pass:** the `skillDir` field of every `runs.jsonl` line from this feature's build is the frozen copy's `skills\delegate`, and no build run fails because of an unfinished change.
*   **G7. Try the two-part task template.**
    *   The phase-3 `code-hard` task uses a task file split into two parts. "Decided" covers the outcome, the boundaries and the shared interfaces. "Yours to decide" covers internals, names, internal tests and the order of work.
    *   `code` and `code-hard` are `delegate` profiles defined in `skills/delegate/models.json`: Composer 2.5 for ordinary tasks, Grok 4.7 high for hard ones.
    *   **Pass:** an entry in `docs/test-plan.md` records the task's review rounds, its readiness findings and the lead's view. It sets them next to the earlier, tightly specified `code-hard` run `fb-stages`: the `feature` skill's build step 4 (the router and stage files), recorded as D19 in `docs/test-plan.md`.

## Non-Goals

*   **Keeping code from Cursor.** The agent sends the files it reads to Cursor's model servers; that is how it works. The sandbox limits what it can read, not what it sends to Cursor.
*   **Sandboxing the lead.** Claude Code runs as the user, as it does today.
*   **Other host systems.** macOS and Linux hosts, Windows Pro features (Windows Sandbox, Hyper-V), and cloud runners are out of scope. The design targets this machine: Windows 11 Home, build 26300.
*   **Antigravity.** The Antigravity CLI (`agy`) stays disabled. Its terms forbid wrapping it in third-party agents on consumer plans (decision T0 in `skills/delegate/models.json`).
*   **Hardening against a malicious Cursor CLI.** The CLI binary and Cursor's servers are trusted. The threat is the model being misled by its inputs or making mistakes, not the tool itself.
*   **New review or planning features.** Lenses, councils and the `feature` stages are unchanged apart from launching through the sandbox.
*   **Host services in this build.** Reaching services on the host's `localhost` (ComfyUI, Ollama) is designed for, but not granted, here. See "Host services".

## Open Questions

*   **Token refresh.** Can a Cursor token refresh inside the sandbox invalidate the user's own login? Measured in phase 5. The rule is in "Cursor login".
*   **Per-run permission cost.** How long do granting and removing access take on a large worktree? Each one propagates to every file, for example under `node_modules`. Measured in phase 5. The target is not a gate.
*   **Which host services MyApp needs.** Settled when the first MyApp feature is designed; the mechanism is proven (see "Host services").

## Critical User Journeys (CUJs)

The `feature` skill moves a feature through stages (`design`, `design-review`, `plan`, `build`, `signoff`), described in `docs/designs/feature-skill.md`. In `build`, the lead runs each planned task through `delegate.ps1`.

### CUJ 1: First use: reserve the drive letters

*   **Given**: A machine on which no sandboxed run has happened yet.
*   **When**: The lead starts the first sandboxed run.
*   **Then**: `delegate.ps1` fails with `sandbox: no drive letters reserved; suggested: R, S, T`. The lead asks the user to approve three letters. On approval it runs `delegate.ps1 -SandboxCheck -Reserve R,S,T -Repo <repo>`, which maps the letters, creates the two slot containers and runs the canary. Then the lead retries the run.

### CUJ 2: A sandboxed worker builds and tests a task

*   **Given**: A feature in `build`, a planned `code` task, and reserved letters.
*   **When**: The lead runs `delegate.ps1 -Agent cursor -Repo <repo> -TaskId <id> -TaskFile <file>` with no new parameters.
*   **Then**: The worker runs inside a slot's container. It edits files in its worktree, runs the repo's tests (for this repo, `scripts/test.ps1`) and `git status`/`git diff`, and writes `result.json`. The summary JSON has today's fields plus `sandboxed: true`, `sandbox` and `skillDir`. The lead reviews and merges the branch as before.

### CUJ 3: A prompt injection tries to read a secret

*   **Given**: A worker whose task text tells it to read `~/.ssh/id_ed25519` and `D:\MyApp\.env` and paste them into a file.
*   **When**: The worker tries this with its shell and with its own file-read tool.
*   **Then**: Every attempt fails with "access denied". The worker reports the failure in `result.json`. Nothing outside the worktree appears in the branch, the summary or the logs.

### CUJ 4: Review lenses and a council run read-only

*   **Given**: A design or a diff to review.
*   **When**: The lead runs lenses (`-Profile review`) and council seats (`-Profile council`) as today.
*   **Then**: Each run can read only its own detached worktree and write only its run home. `delegate.ps1`'s read-only check (`git status --porcelain --untracked-files=no`) finds no changes.

### CUJ 5: The sandbox cannot start

*   **Given**: Any one of: the Cursor CLI updated to a version whose `node.exe` cannot be patched; Windows older than build 26300; a reserved letter taken by another drive; both slots busy for 60 s.
*   **When**: The lead launches a run.
*   **Then**: `delegate.ps1` fails before starting the agent, with `ok: false` and an `error` that starts with `sandbox:` and names the cause and the fix. The lead does not retry it. The lead reports it to the user. The user can run unsandboxed only by passing `-NoSandbox`, and that run is recorded with `sandboxed: false`.

### CUJ 6: A run is killed or the machine restarts mid-run

*   **Given**: A sandboxed run whose `delegate.ps1` is killed, or a machine that restarts during a run.
*   **When**: The next sandboxed run starts.
*   **Then**: Windows has already released the dead run's slot lock. If the machine restarted, the drive letters are gone, and the next run maps them again. The next run that takes that slot removes the dead run's access grants before granting its own, so it cannot read the old worktree.

### CUJ 7: A timed-out run is killed

*   **Given**: A sandboxed worker that hangs.
*   **When**: The run reaches `-TimeoutSec`.
*   **Then**: `delegate.ps1` ends every process in the run at once through a Windows job object. It reports `timedOut: true` and `exitCode: -1`, as today.

## Technical Plan (Architecture)

### Decision

`delegate.ps1` starts the Cursor CLI inside a Windows **AppContainer**. An AppContainer is a Windows process sandbox. The process gets its own security identity (an AppContainer SID), and it can open only files and folders whose access lists name that SID or "ALL APPLICATION PACKAGES". Everything else on disk is denied by default, including the user's profile and other drives. It needs no extra Windows account and no password. Day-to-day use needs no administrator rights; only the optional host-services exemption does.

Feasibility probes on this machine (2026-11-13 and 14; scripts and findings in `docs/designs/worker-sandbox-probe/`) confirmed:

*   **Blocked:** the shell and the agent's own file-read tool were denied on canaries in the user's profile and on `D:\`, on `~\.ssh`, on `D:\MyApp`, and on the real Cursor login. The host's `localhost` was blocked.
*   **Working:**
    *   git (init, commit, log), in a folder outside the user profile;
    *   Pester 6.2.0 from `C:\Program Files`;
    *   child processes and .NET process kill;
    *   HTTPS;
    *   `localhost` connections within one container;
    *   a full Cursor CLI run (`composer-2.5`, `--force`), on the patched `node.exe`;
    *   the host's `localhost`, after an admin loopback exemption for that container.

### Components

```text
lead (Claude Code, user account)
  |
  v
delegate.ps1 (user account)     unchanged parameters, plus -NoSandbox, -SandboxCheck, -Reserve, -Release
  |-- worktree + hand-off files (as today)
  |-- Sandbox.psm1 (new): ensure letters -> take slot -> grant -> launch -> wait/kill -> release slot
  |     |-- sandbox.json:   %LOCALAPPDATA%\xagent\sandbox.json  (reserved letters, read list)
  |     |-- runtime cache:  %LOCALAPPDATA%\xagent\sandbox\cursor\<version>\  (Cursor copy, patched node.exe)
  |     |-- runtime letter: R:  -> the runtime cache folder, always mapped
  |     |-- slot letters:   S:, T:  -> a run's worktree while in use, an empty "idle" folder otherwise
  |     |-- containers:     xagent.slot-S, xagent.slot-T  (one permanent AppContainer per slot)
  |     |-- slot lock:      named mutex Local\xagent-slot-<letter>, held by delegate.ps1 for the run
  |     |-- slot ledger:    %LOCALAPPDATA%\xagent\sandbox\slot-<letter>.json  (grants made by the run)
  |     '-- job object:     holds every process of the run; closed on timeout
  v
R:\<version>\node.exe R:\<version>\index.js --workspace <real worktree path> ...
  (inside the slot's AppContainer; working folder S:\ or T:\)
  '-- shell commands, tests, git  (same container)
```

### Reserved letters and slots

Node's module loader checks every folder from the drive root down, and an AppContainer cannot read the attributes of `C:\` or `D:\`. The probe showed `require` failing with `EPERM: lstat 'D:\'` for a file in an ordinary `D:` folder. A drive letter made with `subst` turns the target folder into a drive root, which the container can read.

The user reserves three letters once (CUJ 1), and they are stored in `sandbox.json`:

*   **The runtime letter** is mapped to the runtime cache folder and stays mapped. A run uses `<R>:\<version>\node.exe`, so a Cursor update needs no remapping, and a run on the previous version keeps working.
*   **Two slot letters** each carry one live run. The cap of two live runs per feature matches the slot count. Each slot has its own permanent AppContainer, `xagent.slot-<letter>`, created at reservation.
    *   **Taking a slot:** a run tries each slot's lock, a named mutex `Local\xagent-slot-<letter>`, without waiting. It takes the first one it gets. If both are held, it retries every 2 s for up to 60 s, then fails with `sandbox: no free slot (both slots busy)`.
    *   **Using it:** the run maps the slot letter to its worktree.
    *   **Releasing it:** at the end it maps the letter back to the empty folder `%LOCALAPPDATA%\xagent\sandbox\idle`, which keeps the letter reserved against USB drives, and releases the lock.
    *   **Crash safety:** Windows releases a dead process's mutexes. A lock taken over from a dead run arrives as `AbandonedMutexException` and counts as taken, so a crashed run's slot is free with no clean-up logic.
*   **Mapping:** `subst` mappings belong to the user's logon session and disappear at sign-out or restart. Each run first maps any reserved letter that is missing. If a reserved letter is in use by a drive that isn't ours, the run fails with `sandbox: reserved letter <L>: is used by another drive; choose new letters` and changes nothing.
*   **Release:** `delegate.ps1 -SandboxCheck -Release` removes the three mappings, deletes the two slot containers, and removes the reservation from `sandbox.json`. It refuses while a slot lock is held.

### What the sandbox can reach

Every grant below goes to the slot's container SID, is made at the start of the run, and is removed at its end. Before granting, the run writes the list of grants to the slot ledger. A run that takes a slot whose ledger still exists (left by a crashed run) first removes those grants and only then deletes the ledger. "RA" means read attributes, on that folder only, with no inheritance: it lets a program check the folder exists, not list or read it.

| Path | Access | Why |
|---|---|---|
| Worker worktree (`<repoParent>\<repo>.xagent\<TaskId>`) | read + write | The task. |
| Read-only worktree (`...\<TaskId>-<Seat>`) | read | Lenses and councils (G2). |
| Run home (`<worktree>\.xagent\sandbox`) | read + write, also in read-only runs | `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP` point here through the slot letter. `.xagent/` is already in the repo's `.git\info\exclude`. |
| `<repo>\.git` itself | read, this folder only | git opens the common directory. |
| Every child of `<repo>\.git` except `worktrees` (`objects`, `refs`, `info`, `hooks`, `logs`, `config`, `HEAD`, `packed-refs`, …) | read, inherited | Objects, refs and config. Read-only, so hooks and config cannot be changed, and workers cannot `git add` or `git commit` (they don't today: the lead commits). |
| `<repo>\.git\worktrees` | RA | Only the path to this run's own folder. |
| `<repo>\.git\worktrees\<WtName>` | read + write | This worktree's own index and HEAD. Other worktrees' folders get nothing. |
| Every ancestor of the worktree and of `<repo>\.git`, below the drive root | RA | git checks every parent folder of the paths it uses. A repo or worktree under `%USERPROFILE%` is refused (`sandbox: repos under the user profile are not supported`), because the profile's parents cannot be granted safely. |
| Runtime cache folder | RA | The runtime letter's root. |
| `<runtime cache>\<version>` | read + execute | Cursor's code and the patched `node.exe`. |
| `<runtime cache>\<version>\.running` | read + write | Cursor writes a marker there at start. |
| `C:\Windows`, `C:\Program Files` | read + execute | Already granted by Windows to all AppContainers: git, PowerShell 7, Pester installed for all users. |
| Read-list paths (`sandbox.json`) | read + execute | Per-user toolchains the user opts in (see "Read list"). |
| Everything else | none | G1. |

### Read list

`sandbox.json` may list per-user toolchain folders, for example the Python that ComfyUI uses:

```json
{ "letters": { "runtime": "R", "slots": ["S", "T"] },
  "read": [ { "path": "C:\\Users\\me\\AppData\\Local\\Programs\\Python\\Python312", "addToPath": true } ] }
```

*   Each `read` entry is granted read + execute for the run. `addToPath` is `false` when missing; when `true`, the path is appended to the container's `PATH`.
*   **Comparison:** paths are normalized with `GetFullPath`, trailing `\` removed, and compared case-insensitively.
*   **Refused entries:** the profile root itself; anything equal to or under `~\.ssh`, `~\.aws`, `~\.gnupg`, `~\.cursor`, `~\AppData\Roaming`, or the user's Cursor folders. A missing path is refused too.
*   **What a refusal does:** the run fails with `sandbox: read-list entry '<path>' is refused (<reason>); edit sandbox.json`, and nothing is granted.

### Host services

AppContainers cannot reach the host's `localhost`. Windows offers a per-container exemption: `CheckNetIsolation LoopbackExempt -a -p=<container SID>`, run as administrator. The 2026-11-14 probe showed a container blocked, then reaching a host HTTP server after the exemption, then blocked again after `-d`.

*   **Why it suits this design:** containers are permanent per slot, so an exemption is a one-time step per slot, not per run.
*   **Not granted by this feature.** The first feature that needs a host service (for example MyApp and ComfyUI) adds it as an opt-in.
*   **What it opens:** every host `localhost` port, not just one service.

### The patched `node.exe`

The Node.js that Cursor bundles (v24.22.1, libuv 1.52.1) hangs inside an AppContainer whenever it starts a child process with piped output. AppContainers may only create pipes under `\\.\pipe\LOCAL\`. libuv uses `\\?\pipe\uv\...`, treats "access denied" as a name clash, and retries forever. libuv 1.53.0 fixes this, but no Node.js release includes it yet ([nodejs/node#66374](https://github.com/nodejs/node/issues/66374)).

`Sandbox.psm1` copies Cursor's current version folder into the runtime cache. It then patches the copy's `node.exe`:

*   **The pattern:** the C string `\\?\pipe\uv\%llu-%lu`, which is 20 bytes: `5c 5c 3f 5c 70 69 70 65 5c 75 76 5c 25 6c 6c 75 2d 25 6c 75`, followed by a 0 byte.
*   **The replacement:** `\\?\pipe\LOCAL\%llu`, which is 19 bytes plus a 0 byte, so the length is equal. In Cursor `2026.11.11-043ef28` the pattern is at offset `0x55df524`.
*   **When it is applied:** only when the pattern appears exactly once. Otherwise the run fails with an error that names the Cursor version (CUJ 5).
*   **When it is skipped:** when the copy's libuv is 1.53 or later. That is read with `node -p process.versions.uv`, with any `-suffix` removed, and compared as `[version]`.
*   **The record:** a `patch.json` next to the copy holds `{patched, offset, uv, sourceSha256, patchedSha256}`.
*   **Reuse:** a later run reads `patch.json` and reuses the copy when its `node.exe` hash matches. It copies and patches again only when `patch.json` is missing or the hash differs.

The probe showed that the patch fixes the hang and that the patched `node.exe` still works outside the container.

**Version choice.** The cache follows Cursor's own launcher, `cursor-agent.ps1`:
*   **Which folders:** folders in `%LOCALAPPDATA%\cursor-agent\versions` that match `^\d{4}\.\d{1,2}\.\d{1,2}(-\d{2}-\d{2}-\d{2})?-[a-f0-9]+$`.
*   **Which one:** sorted by their `YYYYMMDD` date, then by name; the last one wins.
*   **Updates:** the sandbox does not run Cursor's `promote-staged.cmd`, so it never installs an update itself. It uses the version Cursor's normal launcher last installed.
*   **Pruning:** the cache keeps the current and previous version. It never deletes a version named in a slot ledger.

### Launch and kill

`delegate.ps1` today starts `powershell.exe -File cursor-agent.ps1` with `Start-Process`. Windows PowerShell 5.1 does not start inside an AppContainer. So a sandboxed run starts `<R>:\<version>\node.exe <R>:\<version>\index.js` directly, through a C# helper (`SandboxNative.cs`) that calls `CreateProcessW` with the container's security attributes.

*   **Arguments:** the same Cursor arguments `delegate.ps1` builds today after `-File cursor-agent.ps1`. In order: `-p --trust --output-format json --workspace <real worktree path> --model <model>`, then `--mode ask`, `--mode plan` or `--force`, then optional `--resume <id>`, then the prompt.
*   **Workspace and working folder:** `--workspace` stays the real worktree path, as in the probe's successful run. The working folder is the slot letter's root (`S:\` or `T:\`). The probe ran it in its own work folder; phase 3 checks this exact pairing.
*   **Output:** stdout and stderr go to the existing log files through inherited file handles. stdin is `NUL`.
*   **Job object:** the process is put in a job object that kills all its processes when the job closes. On timeout, `delegate.ps1` closes the job and reports `timedOut: true` and `exitCode: -1`. Unsandboxed runs (`-NoSandbox`) keep `Start-Process`; on timeout they use .NET's `Process.Kill($true)` instead of `taskkill.exe`.
*   **Environment:** the child gets an environment block built from scratch, with nothing from the user's environment unless it is listed. For sandboxed runs this replaces the secret-variable denylist.
    *   **System variables:** `SystemRoot`, `windir`, `ComSpec`, `PATHEXT`, `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE`, `OS`.
    *   **`PATH`:** `C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\PowerShell\7;C:\Program Files\Git\cmd`, then the read-list entries with `addToPath`.
    *   **`PSModulePath`:** `C:\Program Files\PowerShell\Modules;C:\Program Files\PowerShell\7\Modules`.
    *   **Run home:** `USERPROFILE` and `HOME` are `<slot>:\.xagent\sandbox\home`. `APPDATA` and `LOCALAPPDATA` are `home\AppData\Roaming` and `home\AppData\Local` under it. `TEMP` and `TMP` are `<slot>:\.xagent\sandbox\tmp`.
    *   **Cursor:** `CURSOR_INVOKED_AS=agent.cmd` and `NODE_COMPILE_CACHE=<slot>:\.xagent\sandbox\tmp\node-compile-cache`.
*   **Network:** every container gets the `internetClient` capability (G3).

### Cursor login and git config

*   **Copied in:** at the start of each run, these files go into the run home: the user's `~\.cursor\cli-config.json` and `%APPDATA%\Cursor\auth.json`, and `~\.gitconfig` (read-only) if it exists.
*   **Deleted after:** at the end of each run, the run home's `auth.json` is deleted.
*   **Kept until `-Cleanup`:** the run home itself, because Cursor keeps its chat history there and `-Resume` needs it. It goes when the worktree is removed.
*   **Nothing is copied back.** The worker can read the token. That is no new trust: the worker already acts as the user's Cursor account.
*   **Token refresh rule:** the phase-5 token check (3 sandboxed runs over at least one day, then `cursor-agent status` outside the sandbox) decides it. If the user's own login is broken, merge is blocked until the run home's `auth.json` is made read-only to the container. A refresh inside a run would then fail that run with `sandbox: Cursor login needs a refresh; run 'cursor-agent status' outside the sandbox, then retry`, and the sandbox never writes the user's login.
*   **Git identity:** workers don't commit (the lead does), so git identity only matters for `git status` and `git diff` behaviour. On this machine `core.autocrlf` comes from Git's system config (`C:\Program Files\Git\etc\gitconfig`), which the container can read.

### Requirements checks

*   **The fast check, `Test-SandboxSupport`,** is run in-process by every sandboxed run and by `feature.ps1 doctor`. It takes about a second and checks:
    *   Windows build 26300 or later (older builds deny AppContainers the `NUL` device, which git opens on every start);
    *   that the Cursor install is found;
    *   that the letters are reserved, with each one either ours or free;
    *   that the current Cursor version's `node.exe` has the pattern exactly once, or a libuv of 1.53 or later. This is how a Cursor update that breaks the patch shows up in `doctor` before a run.
*   **The full check, `delegate.ps1 -SandboxCheck [-Repo <repo>]`,** runs the fast check and builds the runtime cache. With `-Repo`, it also runs a canary in a slot:
    *   **Setup:** a throwaway repo at `<repoParent>\<repo>.xagent\canary-<rand>`. One canary file goes in the user's profile, another next to the canary repo.
    *   **Test:** a short PowerShell script in the container tries to read both canaries and list the profile, then runs `git init`, `commit` and `status`, and a Node child process with piped output.
    *   **Clean-up:** releases the slot and deletes everything it created.

    It prints one JSON object `{ok, support, runtime, canary}` and exits 0 when `ok`, 1 otherwise.

### Record of each run (G5, G6)

The summary JSON and each `runs.jsonl` line gain:
*   `sandboxed` (`true` or `false`);
*   when sandboxed, `sandbox: {container, slot, runtimeLetter, runtimeVersion, patched}`;
*   `skillDir`, the folder the running `delegate.ps1` came from.

`worktree` stays the real path (G4). `-NoSandbox` is the only way to run unsandboxed, and the `feature` skill never passes it. A run that fails before the agent starts (any `sandbox:` error) exits through `delegate.ps1`'s existing `Fail`: exit code 1, `{ok: false, error}`, and no `runs.jsonl` line.

### Failed runs

An `error` that starts with `sandbox:` is a setup problem, not a flaky run. Retrying does not help. The lead does not retry it; it reports the error to the user. `skills/delegate/SKILL.md`, `skills/feature/SKILL.md` and `skills/feature/stages/build.md` each get this exception next to their "retry once" rule.

### Clean-up

*   **At the end of each run** (in `delegate.ps1`'s `finally`):
    *   remove the grants listed in the slot ledger, then delete the ledger;
    *   delete the run home's `auth.json`;
    *   close the job;
    *   map the slot letter back to the idle folder;
    *   release the slot lock.
*   **`-Cleanup`:** removes worktrees, and with them the run homes, as today. No sandbox step is needed, because no grant outlives its run.
*   **`-SandboxCheck -Release`:** see "Reserved letters and slots".

### Freezing `delegate` for this build (G6)

The skill junctions `~\.claude\skills\delegate` and `~\.claude\skills\feature` point into `D:\cross-agent-loop\skills\`. That is the checkout where this feature's tasks are merged. Before phase 1:

1.  The lead creates a detached worktree of `main` at the commit where this design locks: `D:\cross-agent-loop.frozen`.
2.  With the user's approval, the lead points both junctions at that worktree's `skills\` folder.

Every run in this build then uses the frozen `delegate` and `feature`, and `skillDir` in `runs.jsonl` shows it. The new code runs only from `D:\cross-agent-loop\skills\delegate`, in its Pester tests and the build's manual sandbox checks. After sign-off, the junctions go back to `D:\cross-agent-loop\skills\` and the frozen worktree is removed.

### The two-part task template (G7)

The plan writes the phase-3 `code-hard` task file in two parts:
*   **"Decided":** the public functions and their parameters, the slot ledger format, the error strings, and the acceptance tests.
*   **"Yours to decide":** internal helpers, how `icacls` calls are built, internal tests, and the order of work.

After it merges, the lead adds an entry to `docs/test-plan.md` with its review rounds, its readiness findings, and a comparison with `fb-stages`.

## Alternatives Considered

### Alternative A: A restricted local Windows account

Run each agent as a separate standard Windows account (for example `xagent-worker`) through `CreateProcessWithLogonW`, with access lists that deny it the user's profile and other repos.

*   **Pros:** a normal account has none of the AppContainer gaps. git, Node, `taskkill` and the Cursor CLI work unpatched, and drive roots are readable.
*   **Cons:**
    *   An administrator must create the account, and its password must be stored where `delegate.ps1` can read it.
    *   `D:\` gives "Authenticated Users" modify access on every folder (checked on this machine), so the account can read and write `D:\MyApp` until deny entries are added to every folder that matters. New folders are open by default.
    *   The worktree's `.git` lives in the user's repo, where a writable hooks folder runs code as the user. Avoiding that needs a per-run clone.
    *   Windows Firewall cannot reliably filter by local user.
    *   Every new public user repeats the account setup.
*   **Reason for rejection:** Rejected by author: AppContainer gives comparable isolation, default-closed, with no account, no password and no admin step for normal use.

### Alternative B: A dedicated WSL2 distribution with Cursor's Linux sandbox

Run the Cursor CLI inside its own WSL2 distribution, with Windows drives not mounted and Windows interop off, and use Cursor's `--sandbox` (Landlock and seccomp) inside it.

*   **Pros:** Cursor's sandbox is documented and maintained for Linux, with per-host network filtering. Isolation from Windows files is strong.
*   **Cons:**
    *   Windows-only tests cannot run there. This repo's Pester suite uses Windows paths and processes. A worker that cannot run its tests hands that job to the lead, which defeats the skill's purpose.
    *   Each repo needs setup in the distribution: toolchain installs and a second Cursor login.
    *   A worktree on `/mnt/d` is slow, and one inside the Linux file system must be synced back.
    *   All WSL distributions share one VM, whose memory competes with ComfyUI for MyApp.
*   **Reason for rejection:** Rejected by author: workers must run their own tests, and most target repos here are Windows-first.

### Alternative C: Both A and B, chosen per repo

*   **Pros:** each repo gets the sandbox that fits its tests.
*   **Cons:** two mechanisms to build, test and keep working, each with the setup costs above.
*   **Reason for rejection:** Rejected by author: AppContainer covers both cases with one mechanism.

### Alternative D: Cursor's own `--sandbox` on native Windows

*   **Pros:** no new code.
*   **Cons:** Cursor documents its sandbox for macOS and Linux only. On Windows it gives no file-system isolation. It also covers only shell commands; the agent's own file reads follow a "Read Access" setting that allows the whole disk by default.
*   **Reason for rejection:** Rejected by author: it does not meet G1 or G2 on this machine.

### Alternative E: Windows Sandbox, Hyper-V or Docker

*   **Pros:** VM-level isolation.
*   **Cons:** Windows Sandbox and Hyper-V need Windows Pro; this machine runs Home. Docker Desktop on Home runs Linux containers on WSL2, which is Alternative B with more layers. Windows containers need Hyper-V.
*   **Reason for rejection:** Rejected by author: not available on Windows 11 Home.

### Alternative F: Worker in WSL, tests run by a separate Windows "tester"

A worker in WSL writes the code, and a second agent on Windows runs the tests with read-only access.

*   **Pros:** the worker is isolated, and Windows tests still run.
*   **Cons:** a read-only tester is not safe. Tests run the worker's code with the tester's permissions, so the worker's code gets everything the tester has. It also adds a round trip to every test run.
*   **Reason for rejection:** Rejected by author: it moves the risk instead of removing it.

### Alternative G: A per-run clone instead of a worktree

Give the container a `git clone --shared` of the repo instead of a worktree, so it never touches the user's `.git`.

*   **Pros:** the container cannot see the user's `.git` at all.
*   **Cons:** it changes `delegate`'s worktree and branch layout and the `feature` skill's merge steps (G4). The lead would review and merge from a clone, which needs a fetch step after every run.
*   **Reason for rejection:** Rejected by author: read-only access to `.git` already prevents hooks and config changes, and keeps the layout.

### Alternative H: A new AppContainer per run, or one per repo

*   **Pros:** a container per run never shares an identity across runs. A container per repo needs fewer profiles.
*   **Cons:** a per-run identity means a host-services exemption would need an admin step on every run. A per-repo container lets concurrent workers read each other's worktrees.
*   **Reason for rejection:** Rejected by author: one permanent container per slot lets an exemption be granted once, and per-run grants removed at the end of each run keep sequential runs in a slot apart.

### Alternative I: Admin-granted access to drive roots instead of drive letters

Have an administrator give containers read-attributes access to `C:\` and `D:\`, so git and Node can walk normal paths.

*   **Pros:** no `subst` drive letters; paths stay the same inside and outside the sandbox.
*   **Cons:** it needs an administrator on every machine, and it changes access on the system drive root for every AppContainer app if granted to "ALL APPLICATION PACKAGES". The [phantombot](https://github.com/phantomyard/phantombot/pull/787) project (an agent runner with a Windows AppContainer backend) moved from this approach to drive letters for that reason.
*   **Reason for rejection:** Rejected by author: drive letters need no admin step.

### Alternative J: Wait for a Node.js release with libuv 1.53 instead of patching `node.exe`

*   **Pros:** no binary patch to maintain.
*   **Cons:** as of 2026-11-12, no Node.js release line bundles libuv 1.53. The v24 backport request is open, and Cursor would then also need to ship it. Until both happen, the Cursor CLI cannot run in an AppContainer at all.
*   **Reason for rejection:** Rejected by author: the patch is one equal-length string, checked before it is applied, and skipped once the bundled libuv has the fix.

### Alternative K: Host filtering through a proxy

Shell commands reach the network only through a filtering proxy that allows listed hosts.

*   **Pros:** brings back a per-host allowed list (G3 as first written).
*   **Cons:**
    *   A proxy on the host needs an admin loopback exemption.
    *   A proxy inside the same container avoids that (loopback within one container works), but it filters only tools that honour `HTTP_PROXY`. A worker can connect around it, because the container keeps `internetClient` for Cursor.
    *   Whether Cursor's own streaming traffic works through a proxy is untested.
    *   It adds a component to build and version.
*   **Reason for rejection:** Rejected by author: G3 is restated (network on, file isolation limits leaks). The in-container proxy stays a Future Improvement.

### Alternative L: Launch through Cursor's own `cursor-agent.ps1` under PowerShell 7

*   **Pros:** Cursor keeps owning version choice and environment set-up.
*   **Cons:** unprobed inside the container. The script runs `promote-staged.cmd` and may try to write the real install folder.
*   **Reason for rejection:** Rejected by author: the direct `node.exe` launch is the probed configuration, and the sandbox should never install updates.

### Alternative M: Shared capabilities granted once

Grant the runtime cache and each repo's `.git` to named capabilities that every container carries, once and permanently.

*   **Pros:** almost no permission changes per run.
*   **Cons:** a second permission system that outlives every run, needing a record of granted repos and a removal command.
*   **Reason for rejection:** Rejected by author: per-run grants are simpler and leave nothing behind. The extra seconds are small next to a task's length.

### Alternative N: Drive letters picked per run, or a shared runtime letter with a lease

*   **Pros:** no reservation step.
*   **Cons:**
    *   Letters picked per run need a sweep for letters left by crashed runs.
    *   A shared runtime letter needs a lease protocol that can leak after a crash, and one bug affects every run sharing it.
    *   A `Global\` mutex cannot be created by a non-elevated session (checked: `whoami /priv` shows no `SeCreateGlobalPrivilege`).
*   **Reason for rejection:** Rejected by author: reserved letters plus per-slot mutexes let Windows handle crash recovery.

### Alternative O: No read list until one is needed

*   **Pros:** no hole-punching rules to get wrong now.
*   **Cons:** the first expected outside use, MyApp with ComfyUI's per-user Python, would block.
*   **Reason for rejection:** Rejected by author: the skill should be ready for per-user tools.

### Alternative P: Copy a refreshed Cursor token back to the user's login

*   **Pros:** the user never notices a refresh inside a run.
*   **Cons:** the sandbox would write into the user's Cursor folder after runs. A tampered copy would be installed.
*   **Reason for rejection:** Rejected by author: measure first. If a fix is needed, use a read-only token.

### Alternative Q: A `taskkill` shim on the container's `PATH`

*   **Pros:** existing scripts that call `taskkill /PID` work unchanged.
*   **Cons:** a fake tool that differs from the real one in exit codes and messages, and it doesn't help scripts that call `C:\Windows\System32\taskkill.exe` by full path.
*   **Reason for rejection:** Rejected by author: documenting the limit is enough for most development.

## Non-Functional Requirements

### Performance

*   **Per run:** target 5 s or less added before the agent starts, after the first run of a Cursor version. That covers taking a slot, granting, mapping and the run home. Granting and removing access propagate to every file in the worktree, so large worktrees cost more. Measured in phase 5. The target is not a gate: if it is exceeded, the result is recorded in `docs/test-plan.md` and the feature proceeds.
*   **First run of each Cursor version:** a one-time copy of about 256 MB into the runtime cache, plus the patch. Its time is logged and has no target.
*   **Memory:** no VM, so the sandbox adds no fixed memory cost.

### Rollout and rollback

*   **Rollout:** sandboxing is on by default as soon as the change merges. The first sandboxed run asks for the letters (CUJ 1). A machine that fails the requirements check gets `ok: false` with the reason (G5).
*   **Rollback:** `-NoSandbox` runs one task unsandboxed, and this is recorded. A full rollback reverts the merge and runs `-SandboxCheck -Release` from the pre-revert code.

--------------------------------------------------------------------------------

## Risks & Mitigations

| Risk | Mitigation | What remains |
|---|---|---|
| A worker sends the Cursor token from its run home to another host. | The token is deleted after each run, and nothing else readable is secret. | Accepted: the worker already acts with that token. Revoke it in Cursor if a leak is suspected. |
| A worker edits the user's repo through `.git`. | `.git` is read-only apart from the worktree's own folder under `.git\worktrees`. | Workers cannot `git add`, `commit` or `stash`. This matches today's "the lead commits" rule. |
| Two runs read each other's work. | Concurrent runs use different slot containers. Sequential runs in one slot share a container, but grants are removed at each run's end, or by the next run after a crash (the slot ledger). | None known. |
| A crash or restart leaves grants, letters or locks behind. | Windows releases locks at process death and letters at sign-out. The ledger lets the next run in that slot remove leftover grants. | Until a slot is next used, its container still holds the dead run's grants. They give access only to that container's processes, and none are running. |
| A reserved letter is taken by another drive after a restart. | The run fails with a `sandbox:` error naming the letter and changes nothing. | The user picks new letters. |
| A Cursor update moves or removes the pipe-name pattern. | `doctor`'s fast check reports the pattern count. Sandboxed runs fail with the version named (G5). | Sandboxed runs stop until `Sandbox.psm1` is updated. `-NoSandbox` remains. |
| The patched `node.exe` does something the patch didn't intend. | One equal-length string, changed only when it appears exactly once. Source and patched hashes are kept in `patch.json`. | None known. |
| A read-list entry opens too much. | Protected profile folders are refused, and paths are normalized before comparison. | The user decides what else to open. |
| The host-services exemption opens every host port. | It is not part of this feature; it is opt-in per slot later. | Decided with the first feature that needs it. |
| This feature's own build workers run unsandboxed. | They use the frozen `main` at the lock commit (G6), and the sandbox is on for every run after merge. | Accepted for the build's duration. |
| Target repos whose scripts call `taskkill.exe` hang. | Documented in SKILL.md and the task template: use `Stop-Process -Force` or `.Kill($true)`. | The target repo changes its scripts. |
| Per-user toolchains are unreadable. | The read list. | One entry per toolchain. |
| SSH git remotes are unusable (`~\.ssh` is blocked). | Workers don't push. HTTPS remotes work. | Documented. |
| Network is always on. | File isolation limits what can be sent (G3). | Host filtering is a Future Improvement. |
| Scalability. | Two slots match the cap of two live runs per feature, and a third run waits up to 60 s. The cache holds at most two Cursor versions (about 512 MB). | More slots need more reserved letters. |
| Windows older than build 26300. | Refused by the fast check. | No support on older builds. |

### Additional Resources

*   [`docs/designs/feature-skill.md`](feature-skill.md): the Risks row "Workers can read any file and reach the network", the stages, and the Verification Plan regression used for G4.
*   [`docs/designs/worker-sandbox-probe/`](worker-sandbox-probe/README.md): probe scripts and debugging findings not repeated here, for example Windows PowerShell 5.1 and `cscript` failing inside the container.
*   Related work:
    *   [KPO-Tech/seshat-runtime PR #816](https://github.com/KPO-Tech/seshat-runtime/pull/816): git inside an AppContainer;
    *   [phantomyard/phantombot PR #787](https://github.com/phantomyard/phantombot/pull/787): drive letters instead of admin grants;
    *   [libuv/libuv#5178](https://github.com/libuv/libuv/issues/5178) and [nodejs/node#66374](https://github.com/nodejs/node/issues/66374): the pipe-name hang;
    *   [openclaw/openclaw PR #161128](https://github.com/openclaw/openclaw/pull/161128): the same hang, handled by refusing to spawn.

### Future Improvements

*   **Host allowed list for network access:** an in-container proxy, once Cursor's streaming traffic is tested through it (Alternative K).
*   **Host services:** the per-slot loopback exemption, added as an opt-in with the first feature that needs it.
*   **Drop the `node.exe` patch** once Cursor bundles libuv 1.53 or later. The version check already skips it then; the code can be removed after one Cursor release.
*   **Per-repo read lists**, in addition to the user-wide one.
*   **Run the lead's own test runs in the sandbox,** so a test that runs worker code is also confined.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Machine setup (outside the repo, not committed)

*   **Pester for all users:** done on 2026-11-13 (6.2.0 in `C:\Program Files\PowerShell\Modules`). The design requires Pester 5.5 or later installed for all users.
*   **Freeze (G6), before phase 1:**
    *   Run `git worktree add --detach D:\cross-agent-loop.frozen <lock commit>`.
    *   With the user's approval, run `cmd /c rmdir` on `~\.claude\skills\delegate` and `~\.claude\skills\feature`, then `New-Item -ItemType Junction` for each, pointing at `D:\cross-agent-loop.frozen\skills\delegate` and `...\skills\feature`.
    *   Record the path and the commit in `docs/test-plan.md`.
*   **After sign-off:** point both junctions back at `D:\cross-agent-loop\skills\...`, then run `git worktree remove D:\cross-agent-loop.frozen`.

### Target Files to Create/Modify

#### 1. `skills/delegate/scripts/SandboxNative.cs` (Create)

*   **Type / Scope:** C# source, loaded by `Sandbox.psm1` with `Add-Type -Path`. The probe's `AC` class (`docs/designs/worker-sandbox-probe/probe5.ps1`) supplies the Win32 imports and the basic `CreateProcessW` call. Everything else here is new.
*   **Proposed Changes:** a public static class `XagentSandbox` and a public class `RunHandle { public int ProcessId; public IntPtr ProcessHandle; public IntPtr JobHandle; }`. Methods:
    *   **`string EnsureProfile(string name)`:** calls `CreateAppContainerProfile`, or `DeriveAppContainerSidFromAppContainerName` when the profile exists, and returns the SID string.
    *   **`void DeleteProfile(string name)`.**
    *   **`RunHandle Start(string containerSid, string exePath, string commandLine, string cwd, string[] environment, string stdoutPath, string stderrPath)`:**
        *   **Capabilities:** `internetClient` (`S-1-15-3-1`) only.
        *   **Job object:** created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`.
        *   **Handles:** the two log files are opened as inheritable handles (create or append), and `NUL` is opened for reading as stdin.
        *   **Environment block:** built in unmanaged memory from `NAME=VALUE` entries, sorted case-insensitively and double-null terminated, then freed in `finally`.
        *   **`STARTUPINFOEX`:** carries two attributes. `PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES` (`0x00020009`) holds the container SID and the capability. `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` (`0x00020002`) lists only those three handles.
        *   **`CreateProcessW`:** called with `bInheritHandles = true` and the flags `CREATE_SUSPENDED (0x4) | CREATE_UNICODE_ENVIRONMENT (0x400) | EXTENDED_STARTUPINFO_PRESENT (0x00080000) | CREATE_NO_WINDOW (0x08000000)`.
        *   **Then:** the process is assigned to the job and resumed, and the parent's copies of the three handles are closed.
    *   **`bool Wait(RunHandle h, int ms)`** and **`int ExitCode(RunHandle h)`**. `ExitCode` closes the process handle; a `RunHandle` is not usable after it.
    *   **`void Kill(RunHandle h)`:** `TerminateJobObject`, then close the job handle.
    *   **`bool IsAppContainer()`:** reads `TokenIsAppContainer` for the current process. Tests use it to skip container tests when they are already running inside a sandbox.

#### 2. `skills/delegate/scripts/Sandbox.psm1` (Create)

*   **Type / Scope:** PowerShell module, imported by `delegate.ps1` and by `feature.ps1 doctor`. Every thrown error starts with `sandbox:` and names the cause and the fix.
*   **Settings:** `$script:Root` is `%LOCALAPPDATA%\xagent`, overridable by `XAGENT_SANDBOX_ROOT`; tests use this. `sandbox.json` is `<Root>\sandbox.json`. The runtime cache is `<Root>\sandbox\cursor`, the idle folder `<Root>\sandbox\idle`, and the ledgers are `<Root>\sandbox\slot-<L>.json`. The Cursor install is `%LOCALAPPDATA%\cursor-agent`, overridable by `XAGENT_CURSOR_ROOT`.
*   **Exported functions:**
    *   **`Test-SandboxSupport`** (the fast check). It returns `{ok, build, cursorVersion, uv, patternCount, letters, problems[]}`.
        *   If `XAGENT_SANDBOX_FORCE_FAIL` is set, it returns at once with the problem `forced failure (XAGENT_SANDBOX_FORCE_FAIL)`.
        *   Otherwise it checks:
            *   the Windows build is 26300 or later;
            *   the Cursor version, picked with the rule in "Version choice";
            *   the libuv version of the installed `node.exe` (`-p process.versions.uv`, 5 s timeout);
            *   when libuv is below 1.53, that the 20-byte pattern appears exactly once in that `node.exe`;
            *   when letters are reserved, that each letter is free or mapped to its expected target, as read from `subst` output.
    *   **`Get-SandboxRuntime [-CursorRoot] [-CacheRoot] [-UvProbe <scriptblock>]`.** The defaults are the settings above, and the default `-UvProbe` runs `node.exe -p process.versions.uv`.
        *   **Pick the version:** with the rule in "Version choice".
        *   **Reuse:** if `<CacheRoot>\<version>\patch.json` exists and the cached `node.exe` SHA-256 equals `patchedSha256` (or `patched` is `false` and `uv` ≥ 1.53), return.
        *   **Copy:** otherwise copy the version folder to `<version>.partial`.
        *   **Skip the patch:** if `& $UvProbe <copy>\node.exe` is 1.53 or later, write `patch.json` `{patched:false, uv}`.
        *   **Patch:** otherwise count the pattern. If the count is not 1, delete `.partial` and throw `sandbox: Cursor <version>: node.exe pipe-name pattern found <n> times; Sandbox.psm1 needs an update (use -NoSandbox to run unsandboxed)`. If the count is 1, write the replacement and write `patch.json` `{patched:true, offset, uv, sourceSha256, patchedSha256}`.
        *   **Finish:** rename `.partial` to `<version>`. Delete older cache versions except the previous one, and skip any version named in a ledger.
        *   **Return:** `{root, version, uv, patched}`.
    *   **`Get-SandboxConfig`** returns `sandbox.json`, or defaults. **`Set-SandboxLetters -Runtime <L> -Slots <L1>,<L2>`** checks that the letters are free, writes them, creates `idle\`, maps them (runtime to the cache root, slots to idle), and calls `EnsureProfile` for `xagent.slot-<L1>` and `xagent.slot-<L2>`.
    *   **`Initialize-SandboxLetters`** (each run). If no letters are reserved, it throws `sandbox: no drive letters reserved; suggested: <three free letters, highest first from Z>; ask the user, then run delegate.ps1 -SandboxCheck -Reserve <letters>`. It maps any reserved letter that is missing. If a letter is mapped to a target that isn't ours, it throws `sandbox: reserved letter <L>: is used by another drive; choose new letters`.
    *   **`Get-SandboxSlot -TimeoutSec 60`.** For each slot letter, it opens `[Threading.Mutex]::new($false, "Local\xagent-slot-<L>")` and calls `WaitOne(0)`. An `AbandonedMutexException` counts as taken. It retries every 2 s until the timeout, then throws `sandbox: no free slot (both slots busy)`. If the slot has a ledger, it calls `Remove-SandboxGrants` with that ledger and deletes it. It returns `{letter, mutex, container, sid}`. The mutex is released in the same `delegate.ps1` scope that took it.
    *   **`New-SandboxRun -Slot -Runtime -Repo -Worktree -WtName -ReadOnly`.**
        *   **Refuse:** if the worktree or `<repo>\.git` is under `%USERPROFILE%`, throw.
        *   **Read list:** validate it (see "Read list") and throw on a refused entry.
        *   **Ledger:** write the ledger `{pid, startTime, runtimeVersion, worktree, grants:[{path, spec}]}` before granting anything.
        *   **Grant:** with `icacls <path> /grant "*<sid>:<spec>"`, apply every row of "What the sandbox can reach".
        *   **Run home:** create `<worktree>\.xagent\sandbox\home\{.cursor, AppData\Roaming\Cursor, AppData\Local}` and `...\sandbox\tmp`. Copy `cli-config.json`, `auth.json` and `~\.gitconfig` (if present, with the read-only attribute set).
        *   **Map:** `subst <slot>: /D`, then `subst <slot>: <worktree>`.
        *   **Return:** `{slot, container, sid, runtimeLetter, runtimeVersion, patched, cwd = '<slot>:\', env}`, where `env` is the environment array in "Launch and kill".
    *   **`Start-SandboxProcess -Run -CliArgs -StdoutPath -StderrPath`.** It builds the command line `"<R>:\<version>\node.exe" "<R>:\<version>\index.js" <CliArgs>` with `delegate.ps1`'s `Quote` rules, and calls `XagentSandbox.Start` with `cwd = $Run.cwd`. It returns the `RunHandle`.
    *   **`Stop-SandboxRun -Run -Slot`.** It runs the end-of-run steps in "Clean-up" in that order. Each step is in its own try/catch, and its failures are returned as `notes[]`.
    *   **`Remove-SandboxGrants -Ledger`.** It runs `icacls <path> /remove "*<sid>"` for each ledger entry and ignores paths that no longer exist.
    *   **`Invoke-SandboxCanary -Repo`.** It runs the canary described in "Requirements checks", using `Get-SandboxSlot` and `New-SandboxRun` on the canary repo with `-ReadOnly:$false`. `Invoke-SandboxCanary` writes the in-container script to `<canary repo>\.xagent\canary.ps1` and runs it with `pwsh -NoProfile -File`. Clean-up runs in `finally`: `Stop-SandboxRun`, then delete both canaries and the canary folder. It returns `{ok, results[]}`.
    *   **`Remove-SandboxLetters`** (`-Release`). It throws if any slot mutex can't be taken. Otherwise it runs `subst /D` on all three letters, calls `DeleteProfile` for both slot containers, and removes `letters` from `sandbox.json`.

#### 3. `skills/delegate/scripts/delegate.ps1` (Modify)

*   **Type / Scope:** the launch script.
*   **Proposed Changes:**
    *   **Parameters:** add `[switch]$NoSandbox`, `[switch]$SandboxCheck`, `[string]$Reserve` (comma-separated letters) and `[switch]$Release`. A `SandboxCheck` parameter set makes `-Repo` optional there and leaves the default set unchanged.
        *   These fail with a message: `-Reserve` or `-Release` without `-SandboxCheck`; `-SandboxCheck` with `-NoSandbox`; `-Reserve` together with `-Release`.
    *   **`-SandboxCheck` handling:** right after the helper functions (`Quote`, `Get-RuleFiles`, `Restore-RuleFiles`), before `$Repo` is resolved:
        *   import `Sandbox.psm1`;
        *   with `-Release`, call `Remove-SandboxLetters`;
        *   with `-Reserve`, call `Set-SandboxLetters`, then the full check;
        *   otherwise run the full check: `Test-SandboxSupport`, `Get-SandboxRuntime`, and `Invoke-SandboxCanary` when `-Repo` was given (otherwise `canary = "skipped (pass -Repo)"`).
        *   It prints one JSON object and exits 0 if `ok`, 1 otherwise.
    *   **Launch, `cursor` agent, unless `-NoSandbox`:**
        *   **Setup:** import `Sandbox.psm1`, then call `Test-SandboxSupport` (`Fail` with `sandbox: ` plus the problems joined), `Initialize-SandboxLetters`, `Get-SandboxRuntime`, `Get-SandboxSlot` and `New-SandboxRun`. Any throw goes to `Fail` with its message.
        *   **Arguments:** `$cliArgs` is built as today, minus the `powershell.exe -File <launcher>` prefix, with `--workspace $wt`.
        *   **Start:** through `Start-SandboxProcess`. The pid file keeps its format; `childPid` is the sandboxed `node.exe`.
        *   **Wait:** with `[XagentSandbox]::Wait`. On timeout, call `Kill` and set `timedOut = $true`, `exitCode = -1`.
        *   **Finish:** `Stop-SandboxRun` runs in the existing `finally`, and its `notes` go into the summary.
    *   **Unsandboxed path (`-NoSandbox`):** keeps `Start-Process` and the secret denylist. On timeout it runs `try { $proc.Kill($true) } catch {}` instead of `taskkill.exe`.
    *   **Summary and `runs.jsonl`:** add `sandboxed`, `sandbox` (when sandboxed: `{container, slot, runtimeLetter, runtimeVersion, patched}`) and `skillDir` (`$skillDir`).
    *   **`agy`:** unchanged (still disabled). If ever enabled, it runs only with `-NoSandbox`.
    *   **Help comment:** describe the sandbox, the new parameters, and `sandbox.json`.

#### 4. `skills/feature/scripts/feature.ps1` (Modify)

*   **Type / Scope:** the feature state script.
*   **Proposed Changes:**
    *   **Kill helper:** add `Stop-ProcessTree -ProcessId`. It calls `[Diagnostics.Process]::GetProcessById($id).Kill($true)`, ignores "process has exited" and "not found", and waits up to 10 s. Use it at the three `taskkill.exe` sites: the reconcile orphan kill (~line 1806), the `verify` timeout in `Invoke-TaskTestCommand` (~2290), and the `Invoke-DoctorCommand` timeout (~2556).
    *   **`doctor` check:** add a tenth check, `sandbox`. It imports `<delegate dir>\scripts\Sandbox.psm1` in-process and calls `Test-SandboxSupport`. Its fields are `name = 'sandbox'`, `ok`, `required = $false` (so `ready` is unaffected), and `detail`: Cursor version, uv, pattern count, letters, and problems joined, cut to 300 characters. An import failure gives `ok = $false` with the error.

#### 5. `skills/delegate/tests/Sandbox.Tests.ps1` (Create)

*   **Type / Scope:** Pester tests (Pester 5.5 or later). `XAGENT_SANDBOX_ROOT` and `XAGENT_CURSOR_ROOT` point at `TestDrive`.
*   **Proposed Changes:**
    *   **Unit tests (no container):**
        *   **The patch, on synthetic `node.exe` byte files:**
            *   pattern once: patched, and `patch.json` correct;
            *   zero or two times: the named error, and no cache folder left;
            *   a second call: returns without touching `node.exe` (its write time is unchanged);
            *   a changed cached hash: re-copied;
            *   `-UvProbe` returning `1.53.0`: skipped, with `patched:false`.
        *   **Version choice:** a folder set where name order and date order differ.
        *   **Environment array:** contains only the listed names, even when the test sets `GH_TOKEN` and `AWS_SECRET_ACCESS_KEY`.
        *   **Read list:** the refused cases (`~\.ssh`, `~\.ssh\id_ed25519`, the profile root, `AppData\Roaming\x`, a missing path, a mixed-case path) each give the exact message. An allowed entry with `addToPath` lands on `PATH`.
        *   **Refusals:** a repo under `%USERPROFILE%` is refused. `Initialize-SandboxLetters` gives the "no drive letters reserved" message when none are reserved.
    *   **Container tests** (tag `Sandbox`; skipped when `IsAppContainer()` is true or the build is below 26300). They reserve letters from free ones in `BeforeAll` and release them in `AfterAll`.
        *   A worker run with a `pwsh` canary script, covering CUJ 3 without Cursor. It also checks `git status --porcelain` on a clean worktree, and that a Node child with piped output works.
        *   A read-only run cannot write its worktree but can write its run home (G2).
        *   Two concurrent runs (both slots) cannot read each other's worktrees.
        *   A sequential run in the same slot cannot read the previous run's worktree.
        *   **Crash recovery:** a run's `delegate`-side process is killed, and a ledger is left. The next `Get-SandboxSlot` removes those grants, and the old worktree is unreadable from the new run.
        *   A timed-out sleeper tree dies on `Kill`, including a grandchild (CUJ 7).
        *   A third run fails with "no free slot" after its timeout, shortened to 4 s by a parameter.
        *   `Remove-SandboxLetters` refuses while a slot is held.
    *   **Unsandboxed kill test:** a two-level child tree dies on `Stop-ProcessTree`. This test goes in `feature.Tests.ps1` with the helper.
    *   **Live test** (tag `Live`, excluded by default): `delegate.ps1` with a real Cursor worker (`composer-2.5`) on a temporary repo outside the profile, told to read the canaries. It passes when no canary text is in the logs, summary or branch, and `sandboxed` is `true`.

#### 6. `skills/delegate/tests/DelegateLaunch.Tests.ps1` and `skills/delegate/tests/fixtures/fake-cursor/index.js` (Create)

*   **Type / Scope:** Pester tests for the `delegate.ps1` changes, with a fake Cursor CLI.
*   **Proposed Changes:**
    *   **The fixture:** `index.js` prints one line, `{"type":"result","subtype":"success","is_error":false,"result":"{\"status\":\"done\",\"summary\":\"fake\",\"files_changed\":[],\"tests_run\":[],\"open_questions\":[]}","session_id":"fake-session"}`, and exits 0. The test builds `TestDrive\cursor-agent\versions\2099.01.01-abc123\` from a copy of the real `node.exe` and this `index.js`, plus a `cursor-agent.ps1` copy for the unsandboxed path, and sets `XAGENT_CURSOR_ROOT`. No test calls a real model.
    *   **Cases:**
        *   `-NoSandbox` gives `sandboxed: false` and `skillDir`, in the summary and in `runs.jsonl` (with `XAGENT_LOG_DIR` in `TestDrive`).
        *   A sandboxed run (tag `Sandbox`) gives `sandboxed: true` with the `sandbox` fields.
        *   `XAGENT_SANDBOX_FORCE_FAIL=1` gives exit code 1, an `error` starting with `sandbox: forced failure`, no agent process, and no `runs.jsonl` line.
        *   A cache whose pattern bytes are zeroed gives the named patch error under the same conditions.
        *   `-SandboxCheck` without `-Repo` is accepted.
        *   The invalid switch combinations fail.
        *   Existing calls without the new switches still bind (G4).

#### 7. `scripts/test.ps1` (Create)

*   **Type / Scope:** the repo's one test command, for workers and the lead.
*   **Proposed Changes:**
    *   `param([switch]$Fast)`.
    *   It imports Pester with `-MinimumVersion 5.5` and builds `New-PesterConfiguration`:
        *   `Run.Path`: those of `skills/feature/tests` and `skills/delegate/tests` that exist;
        *   `Run.PassThru = $true`;
        *   `TestRegistry.Enabled = $false` (Pester's test registry writes `HKCU\Software\Pester`, which an AppContainer cannot write);
        *   `Filter.ExcludeTag = 'Live'`, plus `'Slow'` with `-Fast`;
        *   `Output.Verbosity = 'Normal'`.
    *   It exits with `[Math]::Min($result.FailedCount, 250)`.

#### 8. `skills/delegate/SKILL.md` (Modify)

*   **Type / Scope:** skill instructions.
*   **Proposed Changes:**
    *   **A "Sandbox" section** covering:
        *   what a run can reach (a short form of the table);
        *   the first-use letter reservation (CUJ 1: the lead asks the user, then runs `-SandboxCheck -Reserve`);
        *   `-SandboxCheck -Release` on request;
        *   the read list in `sandbox.json`;
        *   the limits: `taskkill.exe` hangs (use `Stop-Process -Force`), no SSH remotes, no host `localhost`, workers cannot `git add`/`commit`;
        *   `-NoSandbox` only when the user asks.
    *   **Rules (line 144):** "If `ok` is false: read `stderrTail` and the log files, then retry once" gains: "unless `error` starts with `sandbox:`. That is a setup problem: report it to the user and do not retry."

#### 9. `skills/feature/SKILL.md` and `skills/feature/stages/build.md` (Modify)

*   **Type / Scope:** the `feature` skill's failed-run rules.
*   **Proposed Changes:** the same `sandbox:` exception, next to "retry once" in three places:
    *   `skills/feature/SKILL.md`, "Failed delegate.ps1 runs" (line 237);
    *   `skills/feature/SKILL.md`, the council-seat sentence (line 216);
    *   `skills/feature/stages/build.md`, "Failed runs" (line 58).

    A `sandbox:` failure is a problem stop at once, like a usage limit, and is not counted as a task failure.

#### 10. `skills/feature/templates/task.md` (Modify)

*   **Type / Scope:** worker task template.
*   **Proposed Changes:**
    *   One line is added at the end of "Constraints": "You run in a sandbox: only this worktree, your home and temp folders, and installed tools are readable, and you cannot commit. Don't work around access errors; report them. `taskkill.exe` hangs here: use `Stop-Process -Force`."
    *   `<test, copied exactly>` is unchanged. For this repo, the plan sets each task's `test` to `pwsh -NoProfile -File scripts/test.ps1` (or a narrower command).
    *   The two-part G7 layout is not added to the template. The G7 task file is written by hand, and the template changes only after the comparison.

#### 11. `skills/feature/tests/feature.Tests.ps1` (Modify)

*   **Type / Scope:** existing tests.
*   **Proposed Changes:**
    *   `It 'reports prerequisites'` (~line 2468) expects ten checks, with `sandbox` last.
    *   A new test: the template still has its six headings, plus the sandbox line.
    *   A new test: `Stop-ProcessTree` kills a two-level child tree.

#### 12. `README.md` (Modify)

*   **Type / Scope:** user-facing requirements.
*   **Proposed Changes:**
    *   **Requirements:** Windows 11 build 26300 or later, and Pester 5.5 or later installed for all users.
    *   **Setup:** the first sandboxed run asks for three drive letters, and `-SandboxCheck -Repo <repo>` runs the canary.
    *   **Uninstall:** `-SandboxCheck -Release`.
    *   **A short list of what the sandbox blocks.**

#### 13. `docs/designs/feature-skill.md` (Modify)

*   **Type / Scope:** the first design, as a post-lock amendment.
*   **Proposed Changes:**
    *   **Header:** a second `Amended:` line: `2026-<date>: worker sandboxing shipped (docs/designs/worker-sandbox.md).`
    *   **Risks row "Workers can read any file and reach the network":** its "What remains" cell, which begins "**Unmitigated in v1:** the denylist is best effort…", is replaced by: "**Mitigated by `worker-sandbox`:** runs are confined to their worktree in an AppContainer; network stays on, and the Cursor token in the run home is an accepted risk (see `docs/designs/worker-sandbox.md`, Risks & Mitigations)."
    *   **Future Improvements bullet "Worker sandboxing (high priority, first after v1)…":** replaced by "Worker sandboxing: done in `worker-sandbox`."

#### 14. `docs/test-plan.md` (Modify)

*   **Type / Scope:** test log.
*   **Proposed Changes:** new entries for:
    *   the frozen path and commit (G6);
    *   the canary results (G1, G2);
    *   the in-sandbox suite run;
    *   the overhead measurement;
    *   the token-refresh result;
    *   the G7 comparison.

#### 15. `docs/HANDOFF.md` (Modify)

*   **Type / Scope:** session hand-off.
*   **Proposed Changes:** revise Next item 5 in place to the feature's final state, and keep the existing libuv 1.53 watch item.

### Build order

| Phase | Tasks | Done by | Depends on |
|---|---|---|---|
| 1 | `Stop-ProcessTree` in `feature.ps1` and its test; `scripts/test.ps1`; `taskkill` removed from `delegate.ps1`'s unsandboxed path | worker, `code` profile | — |
| 2 | `SandboxNative.cs`; `Sandbox.psm1`: `Test-SandboxSupport`, `Get-SandboxRuntime`, `Get-SandboxConfig`, `Set-SandboxLetters`, `Initialize-SandboxLetters`, `Remove-SandboxLetters`; their unit tests | worker, `code-hard` profile (fully specified) | — |
| 3 | `Sandbox.psm1`: `Get-SandboxSlot`, `New-SandboxRun`, read list, `Start-SandboxProcess`, `Stop-SandboxRun`, `Remove-SandboxGrants`, `Invoke-SandboxCanary`; container tests. Includes one probe check: Cursor `--version` and a short `-p` run with `--workspace <real path>` and working folder `<slot>:\` | worker, `code-hard` profile (**G7 two-part task file**) | 2 |
| 4 | `delegate.ps1` wiring and parameters; file 6; the `feature.ps1` `doctor` check; file 11 | worker, `code` profile | 1, 3 |
| 5 | Files 8–10 and 12–15; the live canary, in-sandbox suite run, regression, overhead and token-refresh checks | the lead, with one `code` worker task for files 8–10 and 12 | 4 |

Phases 1 and 2 share no files and can run at the same time. Workers in this build are not sandboxed: they use the frozen copy (G6).

### Verification Plan

*   **Unit and container tests:** `pwsh -NoProfile -File scripts/test.ps1` passes: the existing suite (218 test cases as of 2026-11-12) plus the new tests.
*   **The suite inside the sandbox (CUJ 2):** after phase 4, the lead runs one sandboxed worker from `D:\cross-agent-loop\skills\delegate` (the live copy) on a small task in this repo. The worker runs `scripts/test.ps1 -Fast` and reports the results in `result.json`. Pass: the suite passes inside the sandbox, apart from tests tagged `Sandbox`, which skip themselves.
*   **Canary (G1, G2, CUJ 3, CUJ 4):** the `Live` test as a worker, then the same canaries as a `review` lens and a `council` seat. Pass: every attempt is denied, no canary text is in the logs, summary or branch, and the read-only check finds no changes.
*   **Regression (G4):** the `delegate` regression from `docs/designs/feature-skill.md`'s Verification Plan, with the sandbox on. Pass: the same results as the last unsandboxed run recorded in `docs/test-plan.md`.
*   **Failure (G5, CUJ 5):** the two `DelegateLaunch.Tests.ps1` failure cases (forced failure; zeroed pattern). Pass: exit 1, an `error` starting with `sandbox:`, no agent process, no `runs.jsonl` line.
*   **Crash recovery (CUJ 6):** kill a sandboxed run's `delegate.ps1` mid-run, then start another run. Pass: it takes a slot, the old worktree is unreadable from it, and the ledger is gone afterwards. Also: remove the mappings with `subst /D` by hand, and the next run maps them again.
*   **Timeout (CUJ 7):** a worker task that runs `Start-Sleep 600` with `-TimeoutSec 30`. Pass: `timedOut: true` and `exitCode: -1` within 45 s, with no `node.exe` or `pwsh.exe` left from the run.
*   **Overhead:** the time from `delegate.ps1` start to agent start, sandboxed and unsandboxed, over 5 runs each, on this repo. Target: 5 s or less extra (median), after the first run of a Cursor version. Recorded either way.
*   **Token refresh:** after 3 sandboxed runs over at least one day, `cursor-agent status` outside the sandbox still shows the user logged in. If not, merge is blocked until the read-only token is added (see "Cursor login").
*   **G6:** every `runs.jsonl` line with `feature: worker-sandbox` has `skillDir` under `D:\cross-agent-loop.frozen`. No build run fails because of unfinished sandbox code.
*   **G7:** the `docs/test-plan.md` entry for the phase-3 task exists, with its review rounds, readiness findings and the comparison with `fb-stages`.
