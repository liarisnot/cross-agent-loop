<!-- persona: zoom_out | agent: cursor | model: grok-4.7-medium -->
I'll read the task file and follow its reviewer persona exactly.The task is a Stage 8 zoom-out review of the worker-sandbox design. I'll read the design, the earlier reviews, and the cited context so I can judge architecture, YAGNI, and reuse.Context is sufficient. The objective is to stop `delegate` agents, which run as the user with `--force`, from reading or writing outside their worktree on this Windows 11 Home machine. An AppContainer is still the smallest mechanism that does that and can run this repo's Windows tests. This pass does not repeat the earlier zoom-out findings (the network switch with no caller, a second Cursor bootstrap, parent-folder grants, the Pester 6 jump, G7 on the security task, or the G2 wording).

## Findings

### 1. Shared capabilities are a second permission system

**Severity:** Major

**Affected scope:** "What the sandbox can reach" (lines 121–129); Clean-up (lines 163–167); `Grant-RepoAccess`, `Remove-SandboxGrants`, and `repos.json` (lines 383–385, 408).

**Simplicity rationale:** Each run already gets its own container SID, and the plan already puts that SID on the worktree and on `.git\worktrees\<wtName>`. The runtime capability and the per-repo capability exist only so several runs can share two directories. That adds a named SID, a permanent ACE, a registry of repos, and a removal command, and it is why the Security table has a row for grants that outlive the feature. Putting the same container SID on the runtime cache and on the common `.git` directory, and taking it off in the cleanup the script already runs, is the same ACL edit the worktree grant already does. No shared SID, no `repos.json`.

### 2. The `.git` grant does not match the layout the probe actually ran

**Severity:** Major

**Affected scope:** Decision (lines 88–91); access table (lines 120–122); the concurrent-worker sentence (line 129); Security row "The worker edits files in the user's repo through `.git`" (line 299).

**Simplicity rationale:** The probe's git commit ran inside `D:\xagent-ac-probe`, and that whole folder was granted to the container. `delegate` does not use that layout. A worker gets a linked worktree; the common `.git` stays in the user's repo, and `skills/delegate/SKILL.md` says the lead commits, not the worker. CUJ 1 only needs `git status` and `git diff`.

The table then grants `(OI)(CI)` read on all of `.git`. Inheritance covers every sibling `.git\worktrees\<otherTask>`, so one run can read another run's index even though line 129 says concurrent workers cannot read each other's work. The tempting correction, making `.git` writable so it matches the probe, reopens the hook and config write that Alternative A was rejected for.

Grant read on the common git data this worktree actually uses, do not inherit that grant into `.git\worktrees`, and grant this run's own worktree git directory only. Do not widen the common directory to write in order to imitate the probe.

### 3. Reusing one runtime drive letter is a lease protocol

**Severity:** Major

**Affected scope:** Components diagram (lines 103–107); "Why drive letters" (lines 131–133); `Get-FreeDriveLetter`, `New-SandboxRun`, and `Stop-SandboxRun` (lines 386–393, 402).

**Simplicity rationale:** `subst` exists so Node can treat the cache and the worktree as drive roots. Sharing one runtime letter across runs then needs a mutex, a `.running` lease directory, and a rule that the last run out is the one that removes the letter. Parallel runs here are few, and the letter pool from `H` to `Z` is not a measured limit. Each run should map its own letters and remove them when it ends. If two runs pick the same letter, the next free letter is enough. That deletes the lease and the global mutex, which a non-elevated token cannot create anyway.

### 4. G6 rewrites the live skill junctions; the install notes already say to use a copy

**Severity:** Major

**Affected scope:** G6 (line 31); "Freezing `delegate` for this build" (lines 169–173); Machine setup (lines 338–342).

**Simplicity rationale:** G6 is not file isolation. It is a build procedure that hardcodes `D:\cross-agent-loop` and `D:\cross-agent-loop.frozen` and retargets `~\.claude\skills\delegate` and `~\.claude\skills\feature` for every session. `README.md` installation step 2 already says to use a copy when a feature will change `skills/` itself, and to leave the junctions on a checkout only when edits should apply immediately. A copy of the lock commit, used by the lead for this build, satisfies "do not run half-built `delegate`" without a new goal, a junction swap, or machine paths in the design.

### 5. The read list is an opt-in hole before any toolchain needs it

**Severity:** Nit

**Affected scope:** Access table (line 126); Limits (line 183); read-list file (line 409); Future Improvements (line 330).

**Simplicity rationale:** Git, PowerShell 7, and an AllUsers Pester install are already readable under `C:\Program Files` and `C:\Windows`. The user-wide `sandbox.json` list, `addToPath`, and the profile-root refusal rules are a policy surface whose job is to punch holes in G1. Nothing in this repo's test command needs a per-user toolchain. Ship with no list. Add one path when a real run is blocked on it. The per-repo list is already deferred; the user-wide file can wait with it.

### 6. `doctor` does not need a full sandbox boot

**Severity:** Nit

**Affected scope:** File 4, `feature.ps1` `doctor` (line 435); Requirements check (lines 155–157).

**Simplicity rationale:** Every sandboxed run already refuses to start when the build, the patched runtime, or a free drive letter is missing. `doctor` today is a short prerequisite probe. Pointing it at `delegate.ps1 -SandboxCheck` adds a cache copy and an in-container canary to that probe. The canary belongs on the explicit check, not on every `doctor` run.

## Reuse checked

There is no existing AppContainer, ACL-grant, or `subst` helper in this repo. `SandboxNative.cs` still belongs as a cut-down of the probe's `AC` class, not as a general sandbox library. The container SID the plan already applies per run is the thing the shared capabilities duplicate. `README.md`'s "use a copy when a feature edits `skills/`" is the existing answer to G6. `SKILL.md`'s rule that workers do not commit is what makes a read-only common `.git` the right target, so the probe's full-folder grant should not be copied forward.
