# Decisions: worker-sandbox

Append-only. One line per entry: `- <ISO time> [<kind>] <text>`. Written only by feature.ps1.

- 2026-11-14T08:03:29Z [stage] design -> design-review
- 2026-11-14T21:06:52Z [decision] design-1 D1: launch node.exe index.js directly (probed config; no promote-staged)
- 2026-11-14T21:06:53Z [decision] design-1 D2: per-run grants only, no shared capabilities
- 2026-11-14T21:06:53Z [decision] design-1 D3: three reserved drive letters (runtime + 2 slots), per-slot mutex, -Release
