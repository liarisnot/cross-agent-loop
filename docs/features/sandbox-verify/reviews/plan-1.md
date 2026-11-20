# Plan review 1: sandbox-verify

Built from:
- `reviews/raw/sandbox-veri-p1-cm.md` (comprehension, composer-2.5)
- `reviews/raw/sandbox-veri-p1-ir.md` (implementation readiness, deepseek)

Both reviewed the first import (2 phases, 4 tasks). The plan was re-imported with the fixes below, same shape.

## Fixed in the plan

| Lens | Finding | Fix |
|---|---|---|
| IR Major 1 | Where the host-run decision line sits relative to the refusals and the scope check (the design contradicts itself). | `verify-host` fixes the order: refusals, then the decision line, then the scope check, then the test; no line when a refusal fires. |
| IR Major 2 | `setup` field types open; only one new sample. | Types and required fields pinned; `verify-error.json` added beside `verify-setup.json`. |
| IR Major 3, CM Major 3, CM Nit 7 | Phase tests differ from the design's Phases rows; the design says no host run at phase 2. | The summary names the deviation and the expected phase-2 host run with its decision text. |
| IR Major 4 | Which of `verify-host`'s tests `verify-sandbox` flips. | Listed in the `verify-sandbox` brief. |
| IR Major 5 | UTF-8 when reading `delegate.ps1`'s output. | `StandardOutputEncoding`/`StandardErrorEncoding` set to UTF-8. |
| IR Major 6 | The "no trailing newline" exclude case cannot be staged the obvious way. | Pre-seed `.git/info/exclude` with `.xagent/` and no terminator. |
| IR Nit 7 | The command-length measure. | One formula: item lengths plus 3 per item; a 40,000-character test. |
| IR Nit 8 | Recording bound parameters makes the argument test vacuous. | The fake records `[Environment]::CommandLine`. |
| IR Nit 9, CM Major 5 | `build-docs`'s test did not read the docs. | Its test now checks the key strings and the removal of the old Python-only rule (dry-run on today's docs fails as expected). |
| IR Nit 10 | `-Quote` one line, empty `-Quote`. | `Assert-OneLine`; empty counts as missing. |
| CM Major 1 | `where` value in `samples/verify.json` at `verify-host`. | `sandbox` (the final contract; the schema allows both). |
| CM Major 2 | `slot-busy` vs the generic `ok: false` rule. | `slot-busy` is checked first (summary and `verify-sandbox` brief). |
| CM Major 4 | `build-docs` may merge before `verify-sandbox`. | The lead follows the new `build.md` only after `verify-sandbox` merges. |

## Left out (logged as dismissals)

CM Nit 6 (the `sbrun-worktree` brief points at the design's Files row instead of repeating it; the task file will carry the cases), CM Nit 8 (check-in mode is defined by the feature skill).
