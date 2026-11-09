# Goldfish personas (vendored from Google's Elephant-Goldfish Model)

Copied unmodified from https://github.com/google/elephant-goldfish-model at commit `b7d9e27` (2026-11-09).
Apache License 2.0 (see `LICENSE-egm`). "Not an officially supported Google product."

| File | Use in the delegate skill |
|---|---|
| `implementation_readiness.md` + `implementation-readiness-standard.md` | **Task-file preflight**: does the task leave zero design decisions to the worker? |
| `comprehension.md` | **Task-file preflight**: can a fresh reader paraphrase what's being asked? |
| `design_critic.md` | Optional goldfish code/design critique of a worker's diff or a design doc |

The script passes `Mode: REVIEW` and the target document. Personas are read-only, and the harness enforces this too (plan mode plus a worktree check).
