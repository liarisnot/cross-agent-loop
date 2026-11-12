# 001: Vendor EGM's design workflow into the `feature` skill

- **Status:** Accepted in principle 2026-11-09. Details get locked in the `feature` design review.
- **Upstream:** [google/elephant-goldfish-model](https://github.com/google/elephant-goldfish-model), plugin `egm@egm` 0.1.1, commit `b7d9e27` (2026-11-09).

## Context

The `feature` skill's goal is that the user speaks plain language ("review the design", "plan it") and the right stage runs. It should never mean typing a slash command with parameters.

All seven EGM skills (brainstorm, draft, review, resolve, review-loop, bootstrap, drift-report) set `disable-model-invocation: true`. Claude Code then lets only the user start them with a typed `/egm-*` command, and Claude may not reproduce their workflow on its own initiative. A wrapper skill therefore cannot call them.

Options considered:

1. **Vendor** EGM's workflow files into our repo (Apache-2.0, with attribution), so `feature` runs the stages itself. **Chosen.**
2. **Flip the flag** in the installed plugin. Rejected: every plugin update silently reverts it, and the edit lives outside our repo.
3. **Keep EGM manual**, so the design stages need typed commands. Rejected: it defeats the plain-language goal.

## Decision

Vendor the EGM files that `feature` needs (workflow skill text, personas, standards) into this repo. Treat it as **vendor and track**, not a hard fork:

- **Pin.** `THIRD_PARTY_NOTICES.md` records the upstream commit for every vendored file and lists all vendored personas and standards.
- **Mark modifications.** Files we change carry a header saying so (Apache-2.0 §4(b)) and are listed as modified in `THIRD_PARTY_NOTICES.md`. Files we don't change stay byte-identical, so diffing against upstream stays easy.
- **Keep our changes in our own files where possible.** Plain-language routing, `state.json`, cross-vendor reviewers and gates go in our own files that wrap the vendored text, not inside it. That keeps upstream merges mostly copy-over.
- **Sync step.** Run it when the EGM plugin updates, or at least monthly while the project is active:
  1. Diff upstream between the pinned commit and its HEAD, for the vendored paths only.
  2. Copy unmodified files over. Hand-merge modified ones.
  3. Re-run the `feature` smoke tests, then bump the pinned commit in `THIRD_PARTY_NOTICES.md`.

  A small script (`scripts/egm-sync.ps1`) can do steps 1 and 2. This is to be built with `feature`.
- **Keep the plugin installed** as the reference copy and for manual use. Our vendored copy is what `feature` runs.

## When we would switch to a full fork

Declare a fork (stop syncing, rename the vendored workflow, note it here) if any of these happens:
- more than about half of the vendored files carry our modifications;
- upstream changes direction in a way that conflicts with our gates or our cross-vendor reviewers;
- upstream goes quiet (no commits for 6 months).

## Consequences

- `feature` can run every design stage from plain language, and goldfish reviewers can be routed through our cross-vendor `review` profile instead of Claude subagents.
- We take on keeping the copy in sync. The pin, the modification markers and the sync script keep that cheap.
- Licensing: attribution and the license text are already in place (`THIRD_PARTY_NOTICES.md`, `skills/delegate/personas/LICENSE-egm`). Extend the file list as files are vendored.

## Final layout (2026-11-11)

- **EGM workflow (unmodified upstream text):** `skills/feature/egm/` — draft, review, resolve, review-loop skills, synthesizer agent, execution instructions, and `LICENSE-egm`.
- **Personas and standards (vendored into `delegate`):** `skills/delegate/personas/` — goldfish lenses, council-related files, `standards.json`, and standards markdown. **`drift_report.md` is adapted** for the sign-off diff check (three-list output, single design plus diff inputs).
- **Upstream tracking:** each month, compare `git ls-remote https://github.com/google/elephant-goldfish-model HEAD` with the pinned commit `b7d9e27` recorded in `THIRD_PARTY_NOTICES.md`. When HEAD moves, run the sync workflow (diff vendored paths, copy or hand-merge, re-run smoke tests, bump the pin). The helper script `scripts/egm-sync.ps1` is deferred until the first upstream change after v1.
