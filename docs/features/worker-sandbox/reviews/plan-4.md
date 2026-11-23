# Plan review round 4

**Target:** `docs/features/worker-sandbox/plan.md`, after `sandbox-access`'s preflight size gate stopped it (comprehension: 550-900 lines, 30-50 min, partly from a mis-calibrated standard, fixed on `main` in `548c884`). `sandbox-access` is split into `sandbox-readlist` and `sandbox-grants`; nothing else changed.
**Built from:**
- `reviews/raw/worker-sandb-p4-cm.md`: comprehension, composer-2.5, completed (3 Major, Nits), 55 s.
- `reviews/raw/worker-sandb-p4-ir.md`: implementation readiness, deepseek-v41-flash-1017-medium, completed (4 Major, 3 Minor, 4 Nit), 139 s.

Both lenses found nothing lost or duplicated in the split and the order sound. Readiness estimates both halves inside the gate:

| Task | Changed lines | Worker minutes |
|---|---|---|
| `sandbox-readlist` | 220-320 | 10-14 |
| `sandbox-grants` | 300-430 | 15-22 |

## Fixed in the task files (at build time)

The findings are contracts between the split halves and the later tasks. They go into the two task files, which get their own preflight before a worker starts:

- **ir 1:** `Test-SandboxReadList` and the `Test-SandboxSupport` check share one per-entry validator; the first throws on the first refusal, the second adds one problem per refused entry.
- **ir 2, cm 1:** the parameter lists of `Get-SandboxGrantList`, `Get-SandboxEnvironment` and `Assert-SandboxOutsideProfile`.
- **ir 3:** `Get-SandboxGrantList` takes the entries `Test-SandboxReadList` returned and adds each entry's rows and its ancestor `RA` rows; the row test includes one read-list entry.
- **ir 4:** the unremovable-grant mechanism. The lead tested it on 2026-11-14: a deny on `OWNER RIGHTS` (`S-1-3-4`) for `WDAC` makes `icacls /remove` fail with "Access is denied", and deleting the file still works for clean-up. (A deny on the current user does not work: the owner keeps `WRITE_DAC`.)
- **ir 5:** the protected folders and the profile root come from the real environment, never from `XAGENT_CURSOR_ROOT` or `XAGENT_SANDBOX_ROOT`; `<Root>` stays configurable.
- **ir 6:** `Read-SandboxLedger` and the phase-2 ledger readers must agree on the file; one test checks it.
- **ir 7:** `Get-SandboxGrantList` does no profile refusal, so its test may use `TestDrive`.

## Dismissed

- **cm 2:** the `sandbox-grants` size claim is doubtful. Readiness's estimate (300-430 lines, 15-22 min) answers it, and the build-time size gate checks it again.
- **cm 3:** the `sandbox-readlist` Decided wording. The task file's Decided list replaces the brief's boilerplate.
- **ir 9:** drop `fixtures/` from both rows. Harmless scope, and a fixture may still be useful; no change.
- **Other Nits:** labels and wording, no effect on what a worker builds.
