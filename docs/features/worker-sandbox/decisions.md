# Decisions: worker-sandbox

Append-only. One line per entry: `- <ISO time> [<kind>] <text>`. Written only by feature.ps1.

- 2026-11-14T08:03:29Z [stage] design -> design-review
- 2026-11-14T21:06:52Z [decision] design-1 D1: launch node.exe index.js directly (probed config; no promote-staged)
- 2026-11-14T21:06:53Z [decision] design-1 D2: per-run grants only, no shared capabilities
- 2026-11-14T21:06:53Z [decision] design-1 D3: three reserved drive letters (runtime + 2 slots), per-slot mutex, -Release
- 2026-11-14T21:06:54Z [decision] design-1 D4: read list kept, fully specified (MyApp/ComfyUI per-user Python)
- 2026-11-14T21:06:55Z [decision] design-1 D5: G7 two-part template moves to the phase-3 code-hard task
- 2026-11-14T21:06:56Z [decision] design-1 D6: freeze by junction swap to D:/cross-agent-loop.frozen; skillDir field
- 2026-11-14T21:06:57Z [decision] design-1 D7: G3 restated (network on); permanent per-slot containers; host-localhost exemption proven by probe 2026-11-14, not granted
- 2026-11-14T21:06:57Z [decision] design-1 D8: token refresh measured first; read-only token if login breaks
