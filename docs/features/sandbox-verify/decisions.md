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
