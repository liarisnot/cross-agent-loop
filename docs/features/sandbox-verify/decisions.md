# Decisions: sandbox-verify

Append-only. One line per entry: `- <ISO time> [<kind>] <text>`. Written only by feature.ps1.

- 2026-11-20T06:40:02Z [stage] design -> design-review
- 2026-11-20T19:00:56Z [dismiss] zoom_out p5: verify holds a cap slot (IC-1) — task tests are narrow by the size gate, so a check takes a minute or two; kept D5
- 2026-11-20T19:00:56Z [dismiss] inventive_catalyst p5: write the pid file after the slot is taken (IC-5) — the slot is taken inside Invoke-SandboxCommand; a failed slot wait exits within seconds, so the brief over-count is harmless
- 2026-11-20T19:13:55Z [dismiss] design_critic p7: lead must check the cap before verify (DC-2) — already in the build.md row of the Files table (follow the cap rule first)
- 2026-11-20T19:13:55Z [dismiss] design_critic p7: structured state record for host phase runs (DC-6) — decision lines are the committed audit record, as for gates; host-run lines now start with a fixed 'host run:' prefix so they can be searched
- 2026-11-20T19:13:56Z [dismiss] structural p7: rename headings to the standard's area names (ST-4) — the headings follow the EGM design template used by the repo's other designs; every area is present
- 2026-11-20T19:13:57Z [dismiss] structural p7: cross-references are not Markdown links (ST-6) — the repo's designs cite paths in backticks; no link format is required by the standard
- 2026-11-20T19:18:41Z [dismiss] zoom_out p8: keep phase tests on the host outside Python repos (ZO8-1) — author decision D1, reconfirmed on 2026-11-20 with this cost shown
- 2026-11-20T19:18:42Z [dismiss] zoom_out p8: implementation constants (command-line budget, probe leaf check, timeout + 300) are below design altitude (ZO8-3) — kept so the plan leaves no decision to a worker
- 2026-11-20T19:47:37Z [dismiss] codebase_details p9: three blockers (-Base default, existing tests, verify sample) — written against the design before the readiness fixes; all three were already resolved in a31e18a
- 2026-11-20T19:47:38Z [dismiss] codebase_details p9: mark each Files row Create/Modify/Delete — rows say what changes; new files are marked New
- 2026-11-20T19:47:38Z [dismiss] style p9: N5 dense overview sentence, N12 repeated logging pattern, N15 Components tense — no change needed; the reviewer flagged them for awareness only
- 2026-11-20T19:49:41Z [reaudit] d2: phase 9
- 2026-11-20T20:05:05Z [dismiss] codebase_details p9 r1: mark each Files row Create/Modify/Delete — rows say what changes; new files are marked New (raised again)
- 2026-11-20T20:05:05Z [dismiss] codebase_details p9 r1: verify of sbrun-worktree fails in the sandbox (CD11) — phase 1 runs under today's rules, on the host, because the new verify lands in phase 2
- 2026-11-20T20:06:14Z [decision] review design-3: declined by the user
- 2026-11-20T20:06:23Z [gate] design-locked: "Lock the design"
- 2026-11-20T20:06:27Z [stage] design-review -> plan
- 2026-11-20T21:26:08Z [dismiss] comprehension plan-1: sbrun-worktree brief does not enumerate the test cases (CM6) — the design's Files row is locked and the task file carries the cases
- 2026-11-20T21:26:09Z [dismiss] comprehension plan-1: check-in mode not defined in plan.md (CM8) — defined by the feature skill
- 2026-11-20T21:30:57Z [decision] review plan-2: declined by the user
- 2026-11-20T21:30:58Z [gate] plan-approved: "Approve the plan"
- 2026-11-20T21:30:58Z [decision] checkin: on-problems
- 2026-11-20T21:30:59Z [stage] plan -> build
- 2026-11-20T21:38:03Z [decision] sbrun-worktree: kept whole despite split verdict — the tail reader is about 40 lines and delegate.ps1's -SandboxRun output consumes it directly; one unit with one acceptance command
- 2026-11-21T00:49:08Z [fix-up] sbrun-worktree: 1 files, 4 lines — environment-missing container test used the already-built repo; gave it its own unbuilt fixture repo
- 2026-11-21T00:51:05Z [fix-up] sbrun-worktree: 1 files, 1 lines — pass the normalized -Worktree path to the run, not the caller's spelling (state.json uses forward slashes)
- 2026-11-21T01:05:35Z [fix-up] phase 1: 1 files, 2 lines — the timeout test piped an empty tail array to Should; check the key and the array type instead
- 2026-11-21T01:10:24Z [fix-up] build-docs: 1 files, 1 lines — task branch is xagent/<delegateTaskId>
