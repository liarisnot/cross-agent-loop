# Decisions: sandbox-verify

Append-only. One line per entry: `- <ISO time> [<kind>] <text>`. Written only by feature.ps1.

- 2026-11-20T06:40:02Z [stage] design -> design-review
- 2026-11-20T19:00:56Z [dismiss] zoom_out p5: verify holds a cap slot (IC-1) — task tests are narrow by the size gate, so a check takes a minute or two; kept D5
- 2026-11-20T19:00:56Z [dismiss] inventive_catalyst p5: write the pid file after the slot is taken (IC-5) — the slot is taken inside Invoke-SandboxCommand; a failed slot wait exits within seconds, so the brief over-count is harmless
- 2026-11-20T19:13:55Z [dismiss] design_critic p7: lead must check the cap before verify (DC-2) — already in the build.md row of the Files table (follow the cap rule first)
