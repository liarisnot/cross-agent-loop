# cross-agent-loop

Run our dev loop with **Claude Code as the lead programmer**, delegating coding and review subtasks to **Cursor** through its headless CLI, then reviewing and iterating on the results.

Today the alternatives are Haiku sub-agents or manually copy-pasting instructions between platforms. This project replaces that with Claude Code skills: `delegate` for one-off tasks and `feature` for a full design-to-merge flow.

**Workers in v1:** only the Cursor CLI (`agent`). We do not call Google Antigravity (`agy`) from agents. Google's Antigravity FAQ (checked 2026-11-10, [T0 in the test plan](docs/test-plan.md#t0-policy-check-antigravity)) forbids wrapping `agy` inside third-party coding agents on consumer plans and names Claude Code as an example. That is the policy reason; the Google Pro subscription stays for your own interactive use.

## Constraints

- **Local only** (for now): no cloud agents, no Cursor Cloud Agents API.
- **Subscriptions**: Pro-level (~$20/mo) on Claude and Cursor for the automated loop.
- **Platform**: Windows 11 build 26300 or later, PowerShell 7 + Git Bash.
- **Pester**: 5.5 or later, installed for all users (needed to run the test suites).

## Sandbox

### Requirements

- Windows 11 build 26300 or later (AppContainer support).
- Pester 5.5+ for all users.
- A Cursor CLI install under `%LOCALAPPDATA%\cursor-agent`.
- Three free drive letters (`D`–`Z`) reserved on first use.

### Setup

The first sandboxed `delegate.ps1` run fails until drive letters are reserved. Approve three letters, then run:

```text
pwsh -NoProfile -File <skills dir>/delegate/scripts/delegate.ps1 -SandboxCheck -Reserve <a>,<b>,<c> -Repo <repo>
```

`<skills dir>` is the folder `### Installation` installs the skills into. With `-Repo`, the command also runs the sandbox canary in a detached worktree. Add per-user toolchain paths in `%LOCALAPPDATA%\xagent\sandbox.json` if workers need them.

**In File Explorer** the three reserved drives (for example Z, Y and X) show the name of the drive they live on, such as "OS". They belong to the sandbox: the first is the Cursor runtime, the other two are run slots, mapped with `subst` into `%LOCALAPPDATA%\xagent\sandbox`. Windows can't give a `subst` drive its own name or icon without clearing the host drive's label, so they keep it. `-SandboxCheck -Release` removes them.

### What it blocks

- Reading or writing outside the worktree, the run home, installed system tools and paths on the read list.
- The user's profile, other repos, other drives and `~\.ssh`.
- Host `localhost` (unless an admin loopback exemption was added for a slot).
- `git add`, `git commit` and hook or config changes under `.git`.
- `taskkill.exe` inside the container (it hangs; use `Stop-Process -Force`).

It does **not** block the network; reading the user's registry (including user environment variables — do not keep secrets there); or the Cursor login copied into each run's home for the session.

### Uninstall

When you no longer want sandboxing:

```text
pwsh -NoProfile -File <skills dir>/delegate/scripts/delegate.ps1 -SandboxCheck -Release
```

This removes the letter mappings, slot containers and runtime cache. It keeps the read list in `sandbox.json` and prints any loopback exemption still registered for a slot SID, with the admin command to remove it.

## Layout

| Path | Contents |
|---|---|
| [docs/research.md](docs/research.md) | Research findings (Nov 2026): APIs and CLIs, existing harnesses, shared-channel options |
| [docs/design.md](docs/design.md) | Draft design of the `delegate` skill and the dev loop |
| [docs/designs/feature-skill.md](docs/designs/feature-skill.md) | Locked design of the `feature` skill |
| [docs/test-plan.md](docs/test-plan.md) | Feasibility tests and the `feature` manual checklist |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | Licenses and attribution for vendored third-party material (Google EGM, Apache-2.0) |
| `skills/delegate/` | Claude Code skill: `SKILL.md` + `scripts/delegate.ps1` |
| `skills/feature/` | Claude Code skill: router, stages, `feature.ps1`, schemas, EGM workflow copy |

## Status

- [x] Research
- [x] Install CLIs and run the feasibility tests (see test plan)
- [x] Draft `delegate` skill + wrapper script (v0)
- [x] Add permission rule, run T2–T4 edit tests through the script
- [x] T0 Antigravity policy check (consumer plan: no `agy` in third-party agents)
- [ ] Background parallel runs, real-repo trial

## The `feature` skill

`feature` takes one feature from a problem statement to a merge into `main`. You speak in plain language; Claude Code is the lead, Cursor workers code through `delegate`, and you approve each major gate. State lives in the repo (`feature/<name>`, `docs/features/<name>/`, `docs/designs/<name>.md`), so work survives `/clear` and new sessions.

**Example entry phrases** (paraphrases count; the skill must not fire on sentences that only mention a feature):

- design a feature for X
- let's design X
- review the design
- lock the design
- plan it
- plan the feature
- approve the plan
- build it
- continue
- check in every phase
- test and sign off
- sign off
- where are we?
- status
- get a second opinion on …
- convene a council
- go back to the design
- go back to the plan
- abandon this feature

**Stages and gates:**

```text
design --> design-review --[GATE design-locked]--> plan --[GATE plan-approved]-->
build (phase 1..n) --> signoff --[GATE signed-off]--> done
                       any stage --> abandoned (user asks)
```

| Stage | Done when | Gate to leave |
|---|---|---|
| `design` | all sections of `docs/designs/<name>.md` approved | none |
| `design-review` | goldfish findings resolved | **design-locked** |
| `plan` | the plan imported and readiness-checked | **plan-approved** |
| `build` | every task merged into `feature/<name>` and each phase's test passes | none (opt-in phase check-ins and problem stops pause it) |
| `signoff` | full tests pass and the final check is shown | **signed-off**, then merge into `main` |

### Installation

1. Copy or clone this repo anywhere (`<repo>`).
2. Link or copy `skills/delegate` and `skills/feature` into `~\.claude\skills\`. Junctions point at your checkout so skill edits in a feature apply immediately; use a copy if a feature will change `skills/` itself.
   - `New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\feature" -Target "<repo>\skills\feature"`
   - Same for `delegate`.
3. Run `pwsh -NoProfile -File <repo>/skills/feature/scripts/feature.ps1 doctor` and add the two permission rules it prints (one for `feature.ps1`, one for `delegate.ps1`).
4. Optional for the manual sandbox only: a real `python` on `PATH` (not the Windows Store alias).

Logs from `delegate` land in `%LOCALAPPDATA%\xagent\` regardless of where the skills are installed.

## License

Apache License 2.0 (see [LICENSE](LICENSE) and [NOTICE](NOTICE)). Third-party material and its attribution are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
