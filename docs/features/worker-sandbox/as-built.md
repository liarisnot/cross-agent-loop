# `worker-sandbox`: as built

The design `docs/designs/worker-sandbox.md` is locked, so the build's findings are recorded here instead. Each item says what differs from, or adds to, the design.

## Changes from the design

- **Read access (RA) on folders goes through `NtSetSecurityObject`.** `icacls` cannot grant a bare RA on a folder without propagating it to the children. The sandbox adds one non-inheriting ACE with `NtSetSecurityObject` instead. Where `icacls` is still used, it needs the `(RA)` form with parentheses.
- **The container environment includes `SystemDrive` and `ProgramData`.** Without `SystemDrive`, Windows wrote its shell caches into the worktree under a literal `%SystemDrive%` folder. The full list is `SystemRoot`, `windir`, `SystemDrive`, `ProgramData`, `ComSpec`, `PATHEXT`, `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE` and `OS`.
- **`delegate.ps1` splits a comma-separated `-Reserve`.** `pwsh -File` passes `-Reserve Z,Y,X` as one string, not an array.
- **`doctor`'s `sandbox` check is `ok` only when letters are reserved.** It is not required, so an unreserved machine still passes `doctor`.

## Accepted limits

- **Node tools on the read list need `--preserve-symlinks`.** A Node tool started from a read-list entry under the user profile fails on `require`, because Node's realpath calls `lstat` on `C:\`. Granting RA on `C:\` would fix it. The user deferred that until a worker needs it (option C, 2026-11-15).
- **`HKCU\Environment` is readable from the container.** User environment variables, including the user `PATH`, can be read by a worker. The user accepted this as a risk until it becomes a problem (option A, 2026-11-15). The README tells users not to keep secrets there. Cursor's failed attempt to add itself to the user `PATH` quotes that `PATH` into each run's stderr log.
- **The reserved drives show the host drive's label** (for example "OS") in File Explorer. Windows cannot give a `subst` drive its own label or icon without clearing the host volume's label. Tried and removed: `HKCU` `DriveIcons` `DefaultLabel` and `DefaultIcon`. The README explains the drives instead.

## Measured

- Overhead: median 2.95 s sandboxed against 1.24 s unsandboxed (+1.7 s; target 5 s).
- Token refresh: after a day of sandboxed runs, the host Cursor login is still valid (2026-11-16).
- In-sandbox fast suite: 245 passed, 0 failed, 25 skipped (container-only).

Details are in `docs/test-plan.md`, "Phases 3-5 and the phase-5 checks".
