# Plan review round 2

**Target:** `docs/features/worker-sandbox/plan.md` (second import, after `plan-1.md`).
**Built from:**
- `reviews/raw/worker-sandb-p2-cm.md`: comprehension, composer-2.5, completed (3 Major, 3 Nit).
- `reviews/raw/worker-sandb-p2-ir.md`: implementation readiness, deepseek-v41-flash-1017-medium, completed (1 Blocker, 3 Major, 6 Nit).

Both lenses confirmed round 1's fixes landed. Readiness found one round-1 fix incomplete (ir 1 below). The plan was re-imported with the fixes.

## Fixed in the plan

| Finding | Fix |
|---|---|
| ir 1 (Blocker): the zeroed-pattern case is caught first by `Test-SandboxSupport`, with unpinned wording | `sandbox-core` pins the fast check's problem text to the same string `Get-SandboxRuntime` throws, and the `'; '` joiner. `delegate-wiring` accepts the error from either. |
| ir 2: sandboxed test repos in `TestDrive` are under `%USERPROFILE%`, which the sandbox refuses | A shared "test repos" rule in the `sandbox-core`, `sandbox-run` and `delegate-wiring` briefs: a test root on the repo's drive, outside the worktree, removed in `AfterAll`; skip with a reason when that isn't possible. |
| ir 3: full-suite commands run near the 900 s defaults | Plan summary: those three tasks are launched with `-TimeoutSec 2700` and verified with `-TimeoutSec 2400`; workers iterate with a filtered run. |
| ir 4: `-SandboxCheck -NoSandbox` is rejected by the binder, not `Fail` | `-NoSandbox` is declared in both sets. "Still binds" is checked through parameter-set metadata, not a real run. |
| ir 5: the amendment date is unpinned | The day the task runs, as YYYY-MM-DD. |
| ir 6: two more "retry once" sites (`signoff.md` ~43, `design-review.md` ~82) | Added to `sandbox-docs`, with `signoff.md` in its files. This follows the design's rule ("a `sandbox:` error is never retried") into two sites the design's list missed. |
| ir 7: `scripts/test.ps1` has no test of its own | `kill-tree` adds a self-test for `-Fast` exclusion, the exit code and the no-folders case, and may add `-Path` to the script. |
| ir 8: the probe root's clean-up | Deleted at the end of the probe, before the task's test run. |
| ir 9: `Test-LetterFree` is private | Tested with `InModuleScope`, not exported. |
| ir 10: how the kill test gets `Stop-ProcessTree` | Via `Get-FeatureFunctionScript`, as the file's other unit tests do. |
| cm 4: "the access table" | Named as the table under "What the sandbox can reach". |

## Dismissed

- **cm 1:** the junction step "at it" could mean the worktree root. The step is the lead's, not a worker's, and the design's Machine setup gives the per-skill paths. Logged.
- **cm 2:** `fixtures/` is in `sandbox-run`'s files. It lets the phase-3 worker add any fixtures its container tests need. Phase 4 owns `fake-cursor/`. There's no conflict, since phase 4 depends on phase 3. Logged.
- **cm 3, 5, 6:** these could only confuse a reader who skips the design the briefs point to: the `Sandbox` tag, the six template headings (the existing test already checks them), and how the lead invokes the lens and council canaries. Logged.
