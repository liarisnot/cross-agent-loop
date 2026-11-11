# Third-party notices

This repository includes material from the following third-party projects.

## Elephant-Goldfish Model (EGM)

- **Source:** https://github.com/google/elephant-goldfish-model (commit `b7d9e27`, retrieved 2026-11-09)
- **License:** Apache License 2.0. Full text in [`skills/delegate/personas/LICENSE-egm`](skills/delegate/personas/LICENSE-egm) and [`skills/feature/egm/LICENSE-egm`](skills/feature/egm/LICENSE-egm).
- **Copyright:** Google LLC and EGM contributors. The upstream project states it is "not an officially supported Google product." Nothing in this repository implies endorsement by Google; names are used only to identify the source (Apache-2.0 §6).
- **Files included, unmodified:**
  - `skills/delegate/personas/implementation_readiness.md`
  - `skills/delegate/personas/comprehension.md`
  - `skills/delegate/personas/design_critic.md`
  - `skills/delegate/personas/implementation-readiness-standard.md`
  - `skills/delegate/personas/zoom_out.md`
  - `skills/delegate/personas/inventive_catalyst.md`
  - `skills/delegate/personas/codebase_details.md`
  - `skills/delegate/personas/structural.md`
  - `skills/delegate/personas/style.md`
  - `skills/delegate/personas/zoom-out-standard.md` (upstream `resources/document_standards/zoom-out-standard.md`)
  - `skills/delegate/personas/feature-spec-standard.md` (upstream `resources/document_standards/feature-spec-standard.md`)
  - `skills/feature/egm/skills/egm-draft/SKILL.md` (upstream `skills/egm-draft/SKILL.md`)
  - `skills/feature/egm/skills/egm-draft/references/design_doc.md` (upstream `skills/egm-draft/references/design_doc.md`)
  - `skills/feature/egm/skills/egm-review/SKILL.md` (upstream `skills/egm-review/SKILL.md`)
  - `skills/feature/egm/skills/egm-resolve/SKILL.md` (upstream `skills/egm-resolve/SKILL.md`)
  - `skills/feature/egm/skills/egm-review-loop/SKILL.md` (upstream `skills/egm-review-loop/SKILL.md`)
  - `skills/feature/egm/resources/execution_instructions.md` (upstream `resources/execution_instructions.md`)
  - `skills/feature/egm/agents/synthesizer.md` (upstream `agents/synthesizer.md`)
  - `skills/feature/egm/LICENSE-egm` (upstream `LICENSE`)
- **Upstream NOTICE file:** none at the retrieved commit.
- **Files adapted (modified, Apache-2.0 §4(b)):** `skills/delegate/personas/drift_report.md` (adapted from upstream `skills/egm-drift-report/SKILL.md`; its header comment says what changed).
- **How they are used:** at runtime, `skills/delegate/scripts/delegate.ps1` reads the files under `skills/delegate/personas/` and adds caller parameters and a target document before sending them to a model. The files themselves are distributed unchanged. If any of them is modified in the future, the modified file must carry a prominent notice saying so (Apache-2.0 §4(b)), and this list must be updated.
- **Feature workflow text:** the files under `skills/feature/egm/` are workflow text that the `feature` skill's stage files tell the lead (Claude Code) to read and follow; they are distributed unchanged.
- **Upstream check:** the pinned commit is checked monthly with `git ls-remote https://github.com/google/elephant-goldfish-model HEAD`; a sync script is written when the first upstream change arrives (decision 001 in `docs/decisions/`).

Ideas adapted from EGM without copying text: the anti-sycophancy rules in the council prompt, and the Blocker/Major/Nit review format (`skills/delegate/review.schema.json`).
