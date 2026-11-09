# cross-agent-loop

Run our dev loop with **Claude Code as the lead programmer**, delegating subtasks to **Cursor** and **Google Antigravity** agents — all locally, via their headless CLIs — then reviewing and iterating on the results.

Today the alternatives are Haiku sub-agents or manually copy-pasting instructions between platforms. This project aims to replace that with a Claude Code skill that calls the other two CLIs directly.

## Constraints

- **Local only** (for now): no cloud agents, no Cursor Cloud Agents API, no Gemini Managed Agents.
- **Subscriptions**: Pro-level (~$20/mo) tier on all three: Claude, Cursor, Google (Antigravity).
- **Platform**: Windows 11, PowerShell + Git Bash.

## Layout

| Path | Contents |
|---|---|
| [docs/research.md](docs/research.md) | Research findings (Nov 2026): APIs and CLIs from Cursor and Antigravity, existing harnesses, shared-channel options |
| [docs/design.md](docs/design.md) | Draft design of the `delegate` skill and the dev loop |
| [docs/test-plan.md](docs/test-plan.md) | Feasibility tests to run before building, including the Antigravity subscription-tier question |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | Licenses and attribution for vendored third-party material (Google EGM personas, Apache-2.0) |
| `skills/delegate/` | The Claude Code skill: `SKILL.md` + `scripts/delegate.ps1` (linked into `~/.claude/skills/delegate` via a directory junction) |

## Status

- [x] Research
- [x] Install CLIs and run the feasibility tests (see test plan)
- [x] Draft skill + wrapper script (v0)
- [x] Add permission rule, run T2-T4 edit tests through the script
- [ ] T0 ToS check, background parallel runs, real-repo trial

## License

Apache License 2.0 (see [LICENSE](LICENSE) and [NOTICE](NOTICE)). Third-party material and its attribution are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
