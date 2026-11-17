# `worker-sandbox`: as built

The design `docs/designs/worker-sandbox.md` was locked during the build, so the build's findings were recorded here. After sign-off (2026-11-16) they were folded into the design, marked "(as built)". This note keeps the full list.

## Changes from the design

- **Read access (RA) on folders goes through `NtSetSecurityObject`.** `icacls` cannot grant a bare RA on a folder without propagating it to the children. The sandbox adds one non-inheriting ACE with `NtSetSecurityObject` instead. Where `icacls` is still used, it needs the `(RA)` form with parentheses.
- **The container environment includes `SystemDrive` and `ProgramData`.** Without `SystemDrive`, Windows wrote its shell caches into the worktree under a literal `%SystemDrive%` folder. The full list is `SystemRoot`, `windir`, `SystemDrive`, `ProgramData`, `ComSpec`, `PATHEXT`, `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE` and `OS`.
- **`delegate.ps1` splits a comma-separated `-Reserve`.** `pwsh -File` passes `-Reserve Z,Y,X` as one string, not an array.
- **`doctor`'s `sandbox` check is `ok` only when letters are reserved.** It is not required, so an unreserved machine still passes `doctor`.

## Accepted limits

- **Node tools on the read list need `--preserve-symlinks`.** A Node tool started from a read-list entry under the user profile fails on `require`, because Node's realpath calls `lstat` on `C:\`. Granting RA on `C:\` would fix it. The user deferred that until a worker needs it (option C, 2026-11-15).
- **`HKCU\Environment` is readable from the container.** User environment variables, including the user `PATH`, can be read by a worker. The user accepted this as a risk until it becomes a problem (option A, 2026-11-15). The README tells users not to keep secrets there. Cursor's failed attempt to add itself to the user `PATH` quotes that `PATH` into each run's stderr log.
- **The reserved drives show the host drive's label** (for example "OS") in File Explorer. Windows cannot give a `subst` drive its own label or icon without clearing the host volume's label. Tried and removed: `HKCU` `DriveIcons` `DefaultLabel` and `DefaultIcon`. The README explains the drives instead.

## Smaller differences found by the sign-off drift check

- The secret-variable denylist still runs before a sandboxed launch. The fresh container environment is built after it, so it changes nothing in the container. It is kept as defence in depth.
- Rebuilding the runtime cache deletes the old version folder before the `.partial` copy finishes. A failed copy leaves no cache, and the next run rebuilds it.
- `-SandboxCheck` skips the canary and adds `error` when the fast check fails. Read-list entries can also be refused as "not a valid path" or "not an absolute path". `-Release` removes leftover ledger grants first.
- The canary starts PowerShell with `-ExecutionPolicy Bypass`. `scripts/test.ps1` takes `-Path`.
- Overhead was measured as `delegate.ps1` wall time with grant removal included, not start-to-agent-start plus separate removal.
- The `sandbox:` no-retry sentence also appears in `signoff.md` and in a second `design-review.md` paragraph.
- **Not yet run:** G2 (canary as a `review` lens and a `council` seat) and G4 (the `delegate` regression with the sandbox on). Both need the skill junctions pointed at the live skills, which happens after sign-off. The two-part task template (G7) waits for the process rework.

## G1 write and list probe (sign-off, 2026-11-16)

The canary and the `Live` test read the two canaries, but neither tried to write outside the worktree or list the home folder, as G1's pass line asks. At sign-off a real sandboxed worker (Composer 2.5) was told to write a file in the user profile, at `D:\`, and in the main checkout, and to list the profile. All four were denied, and none of the files exist. Its write in its own worktree succeeded.

One side finding: the worker's second attempt used the worktree's real path in PowerShell and was denied with "Access to the path 'D:\' is denied". Writes through the slot drive or relative paths work, as the in-sandbox suite showed. Workers that use the real worktree path in PowerShell may hit this.

## Measured

- Overhead: median 2.95 s sandboxed against 1.24 s unsandboxed (+1.7 s; target 5 s).
- Token refresh: after a day of sandboxed runs, the host Cursor login is still valid (2026-11-16).
- In-sandbox fast suite: 245 passed, 0 failed, 25 skipped (container-only).

Details are in `docs/test-plan.md`, "Phases 3-5 and the phase-5 checks".
