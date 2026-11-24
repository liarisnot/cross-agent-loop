# cross-agent-loop

Run our dev loop with **Claude Code as the lead programmer**, delegating coding and review subtasks to **Cursor** through its headless CLI, then reviewing and iterating on the results.

Today the alternatives are Haiku sub-agents or manually copy-pasting instructions between platforms. This project replaces that with Claude Code skills: `delegate` for one-off tasks and `feature` for a full design-to-merge flow, whose design and review stages build on Google's [Elephant-Goldfish Model](https://github.com/google/elephant-goldfish-model) (see [below](#built-on-googles-elephant-goldfish-model-egm)).

## Why this project

We develop on Windows and wanted one workflow: Claude Code leads, other vendors' models write and review the code in isolated worktrees, and a feature goes from design to merge with the user approving each major step. Before building, we surveyed similar projects ([research §4 and §7](docs/research.md#7-landscape-survey-similar-projects-2026-11-09), November 2026). Parts of the loop existed, but nothing covered it end to end, and the most complete tools assumed Linux or macOS:

- Delegating to another vendor's CLI was well covered. The closest match, delegate-skills, even records native Windows runs, but it has no worktrees, council or design-to-merge flow.
- The feature-level frameworks (Superpowers, GitHub Spec Kit, BMAD and others) run every stage on Claude only. kodo, the closest to our `feature` skill, has no independent verification gate and bypasses permission checks.
- The heavier orchestrators that isolate workers do it with Linux or macOS sandboxing. Omnigent, for example, is documented as degraded on Windows, with no filesystem or network isolation.

So we built it for native Windows and PowerShell. That includes a worker sandbox based on Windows AppContainers.

**Built with itself.** Every part of this repo after the first `delegate` draft was built with the skills while they were still being written. Cursor workers wrote the code through `delegate`, and goldfish lenses reviewed the designs and task files. The later features (`worker-sandbox`, `sandbox-env`, `sandbox-verify`) each ran through `feature`, from design to merge. Their records are in `docs/features/`. What went wrong along the way, and what it fixed, is logged in the [test plan](docs/test-plan.md) (the "Dogfooding `delegate`" rows D1-D28 and the `feature` manual checklist).

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
- `uv` on the host for repos with Python projects run in the sandbox (the skill builds their environments with it and does not install it).

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
| `skills/feature/` | Claude Code skill: router, stages, `feature.ps1`, schemas, and the vendored EGM workflow (`egm/`) |

## Status

- [x] Research and feasibility tests (see the [test plan](docs/test-plan.md))
- [x] T0 Antigravity policy check (consumer plan: no `agy` in third-party agents)
- [x] `delegate` skill: workers, goldfish review lenses and a model council through the Cursor CLI
- [x] `feature` skill v1: design, review, plan, build and sign-off with recorded gates
- [x] Worker sandbox (Windows AppContainer), per-repo Python environments, tests run in the sandbox
- [ ] First trial on a real repo outside this one
- [ ] Swappable models through one config file (vendor-neutral role names)
- [ ] Plugin packaging

### Known issues

- A killed `-SandboxRun` probe leaves its `<repo>.xagent\.probe-<hex>` worktree behind; remove it by hand (`git worktree remove`).
- Pester's HKCU test registry is denied inside the sandbox; sandboxed task tests set `TestRegistry.Enabled = $false`.
- This repo's own full test suite needs a host run (some `delegate` tests read the host drive), which `feature` asks you to approve.
- Cursor's bundled Node hangs on piped child spawns inside an AppContainer; the sandbox runtime uses a patched copy of `node.exe` until Node ships libuv 1.53.

## The `feature` skill

`feature` takes one feature from a problem statement to a merge into `main`. You speak in plain language; Claude Code is the lead, Cursor workers code through `delegate`, and you approve each major gate. State lives in the repo (`feature/<name>`, `docs/features/<name>/`, `docs/designs/<name>.md`), so work survives `/clear` and new sessions.

### Built on Google's Elephant-Goldfish Model (EGM)

The design half of `feature`, and the reviewer personas in `delegate`, come from **[Elephant-Goldfish Model (EGM)](https://github.com/google/elephant-goldfish-model)**, an Apache-2.0 Claude Code plugin published by Google. We vendored it at commit `b7d9e27` (2026-11-09). EGM is "not an officially supported Google product", and nothing here implies endorsement by Google or its authors. The full file list, upstream paths and license are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the reasoning is in [decision 001](docs/decisions/001-vendor-egm-workflow.md).

**EGM terms you will see in this repo:**

| Term | Meaning |
|---|---|
| Elephant | The lead (Claude Code here), which holds the whole conversation's context. |
| Goldfish | A reviewer or worker that sees only one document or task file and no conversation history, so it notices what the elephant left unsaid. |
| Lens / persona | One goldfish reviewer's angle: zoom out, comprehension, design critic, implementation readiness, inventive catalyst, codebase details, structural, style. Each is a prompt file in `skills/delegate/personas/`. |
| Standard | A checklist a persona applies (implementation readiness, zoom out, feature spec). |
| Synthesizer | Merges the lenses' findings into one deduplicated report ranked Blocker / Major / Nit. |
| Phases 5-9 | EGM's review phases: 5 initial zoom out, 6 comprehension, 7 critic, 8 intermediate zoom out, 9 implementation readiness. Review records name them ("stage 9 round 2"). |
| Drift report | A check of what was built against the design. |

**What we use unchanged:** EGM's draft, review, review-loop and resolve workflows, the synthesizer, the execution instructions (all under `skills/feature/egm/`), the eight reviewer personas and three standards (under `skills/delegate/personas/`). These files are byte-identical to upstream.

**What we changed, and why:**

- **Wrapped, not edited.** EGM's skills set `disable-model-invocation`, so only a typed `/egm-*` command can start them. To keep plain-language entry, `feature` ships a copy of the workflow text, and its own stage files (`skills/feature/stages/design.md`, `design-review.md`) tell the lead to follow it "with these differences": write into the feature's design doc instead of `design_draft.md`, commit each approved section, never ask for a slash command.
- **Reviewers from other model families.** Where EGM spawns a Claude subagent for each lens, `feature` runs each lens through `delegate` on a Cursor model (Grok, GLM, DeepSeek), read-only and sandboxed, so the reviewer does not share the author's blind spots. The lead does the synthesizer's job itself, following EGM's synthesizer text.
- **Recorded gates.** EGM's checkpoint questions stay chat questions. Only three gates (design-locked, plan-approved, signed-off) are recorded, with the user's own words, so work resumes from disk.
- **One adapted file.** `skills/delegate/personas/drift_report.md` is rewritten from EGM's drift-report skill into a single read-only pass over the locked design and the branch diff, returning missing, added and changed behaviour for sign-off. Its header states the changes (Apache-2.0 §4(b)).
- **Ideas reused without copying text:** the Blocker / Major / Nit format (`skills/delegate/review.schema.json`) and the anti-sycophancy rules in the council prompt. `delegate`'s goldfish preflight applies the goldfish idea to worker task files: a no-context model reads the task file before a worker runs.
- **Ours, not EGM's:** EGM stops at a reviewed design doc. The plan, build and sign-off stages, `feature.ps1` (state, resume after a killed session, locks), the multi-model council and the worker sandbox are this project's.

**Tracking upstream:** each month we compare upstream `HEAD` with `b7d9e27`, per vendored file. Unchanged files are copied over when upstream changes; the adapted file is merged by hand.

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
