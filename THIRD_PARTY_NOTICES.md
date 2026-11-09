# Third-party notices

This repository includes material from the following third-party projects.

## Elephant-Goldfish Model (EGM)

- **Source:** https://github.com/google/elephant-goldfish-model (commit `b7d9e27`, retrieved 2026-11-09)
- **License:** Apache License 2.0. Full text in [`skills/delegate/personas/LICENSE-egm`](skills/delegate/personas/LICENSE-egm).
- **Copyright:** Google LLC and EGM contributors. The upstream project states it is "not an officially supported Google product." Nothing in this repository implies endorsement by Google; names are used only to identify the source (Apache-2.0 §6).
- **Files included, unmodified:**
  - `skills/delegate/personas/implementation_readiness.md`
  - `skills/delegate/personas/comprehension.md`
  - `skills/delegate/personas/design_critic.md`
  - `skills/delegate/personas/implementation-readiness-standard.md`
- **Upstream NOTICE file:** none at the retrieved commit.
- **How they are used:** at runtime, `skills/delegate/scripts/delegate.ps1` reads these files and adds caller parameters and a target document before sending them to a model. The files themselves are distributed unchanged. If any of them is modified in the future, the modified file must carry a prominent notice saying so (Apache-2.0 §4(b)), and this list must be updated.

Ideas adapted from EGM without copying text: the anti-sycophancy rules in the council prompt, and the Blocker/Major/Nit review format (`skills/delegate/review.schema.json`).
