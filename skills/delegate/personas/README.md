# Goldfish personas (from Google's Elephant-Goldfish Model)

Copied from https://github.com/google/elephant-goldfish-model at commit `b7d9e27` (2026-11-09).
Apache License 2.0 (see `LICENSE-egm`). "Not an officially supported Google product."
Every file is unmodified upstream text except `drift_report.md` and `standards.json`, which are ours.

| File | Use |
|---|---|
| `comprehension.md` | **Task-file preflight**: can a fresh reader paraphrase what's being asked? |
| `implementation_readiness.md` | **Task-file preflight** and plan review: does the text leave zero design decisions to the implementer? |
| `design_critic.md` | Design critique, or an optional goldfish review of a worker's diff |
| `zoom_out.md` | Design review: is this the simplest thing that solves the root problem? |
| `inventive_catalyst.md` | Design review: contradictions and inventive alternatives |
| `codebase_details.md` | Plan review: technical accuracy and reuse of existing code |
| `structural.md` | Design review: document structure |
| `style.md` | Design review: technical writing |
| `drift_report.md` | **Ours, modified from upstream `skills/egm-drift-report/SKILL.md`** (header says how): final check of a design against the whole feature diff |
| `implementation-readiness-standard.md`, `zoom-out-standard.md`, `feature-spec-standard.md` | Standards appended to a persona (upstream `resources/document_standards/`) |
| `standards.json` | **Ours.** The default standard per persona, used when the caller passes no `-Standard`. Personas without an entry get none |

The script passes `Mode: REVIEW`, the standard (under a heading that says it is the one the persona refers to), and the target document. Personas are read-only, and the harness enforces this too (Cursor ask mode, rule files removed, and a tracked-changes check on the worktree).
