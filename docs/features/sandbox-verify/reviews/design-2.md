# Design review 2: sandbox-verify (phase 9 re-check)

By the author's choice, round 2 re-ran only phase 9 on the final text of round 1, instead of all ten lenses.

Built from:
- `reviews/raw/sandbox-veri-d2-ir-p9-r1.md` (implementation readiness, deepseek)
- `reviews/raw/sandbox-veri-d2-cd-p9-r1.md` (codebase details, grok-4.7-medium)
- `reviews/raw/sandbox-veri-d2-sy-p9-r1.md` (style, glm-5.2-high)

## Fixed in the design

| Lens | Finding | Fix |
|---|---|---|
| IR Major 3 | The readiness gate follows `HEAD`, so a task that changes `uv.lock`, `pyproject.toml`, `requirements*.txt` or `.python-version` is tested against environments that do not match it, and the failure looks like a bug. | New rule "Environment inputs and uncommitted changes": the lead commits the task branch, rebuilds with `-SandboxEnv -Base xagent/<task> -Apply`, and verifies again; the plan keeps such changes in their own task. |
| IR Major 2 | The sandbox's outer `pwsh` re-encodes the inner shell's UTF-8 output in the console code page. | The `-Command` text sets `[Console]::OutputEncoding` to UTF-8 first; non-ASCII tests through the fake and the live test. |
| IR Major 1 | `no free slot` told apart only by message text. | New `setup.status` value `slot-busy`; the lead branches on `status`. |
| IR Major 4, CD Blocker 2 | The schema test lists samples by name, so `verify-setup.json` would not be checked. | Add it to `$validSamples`. |
| IR Major 5, CD Major 6 | Two existing tests unaccounted for; refusal order could change a message. | Both tests placed; refusal order fixed with `-TimeoutSec` first. |
| IR Major 6, CD Major 8 | The live test shared the fake's Describe; its skip helper depended on six other helpers. | Its own Describe with the variable removed; skip on `delegate.ps1 -SandboxCheck` and a writable drive root. |
| IR Major 7 | Nothing checked that `verify` passes `-Feature`, `-Repo`, `-Worktree`, `-TimeoutSec`. | The recorded-arguments test asserts each. |
| CD Blocker 1 | "Same as the worker-launch check" did not match that check. | The normalization rule is stated on its own. |
| CD Blocker 3 | "Nothing is written into the worktree" contradicted the run home. | Reworded: `verify` writes nothing; the sandbox writes its run home under `.xagent\sandbox\`, as for every run (G4 too). |
| CD Major 5, IR Nit 1 | Three `Add-SandboxEnvLinks` call sites vs one helper; the exclude's condition. | Two call sites, the exclude inside the same "ready" condition. |
| CD Major 7 | Host and sandbox tails read lines differently. | Stated and accepted (400-character cut on the sandbox side only). |
| CD Major 9 | The `.venv` exclude test needs a built environment. | Uses the fixture with `-SandboxEnv -Apply` first; asserts no line before the build. |
| CD Major 10 | The fake's outputs were not fixed; new tests not tagged. | Every mode's exact JSON given; new tests tagged `Slow`. |
| CD Major 11 | Phase test lacked the slot retry; `proposal.needsApproval` not named. | Both added to the `build.md` row. |
| IR Nits 2–6, CD Nit 12 | Newline before the exclude line; `-Worktree` run name and hex; read mechanism; phase 1 under today's rules; numbering; timeout line join. | All specified. Phase 1 and phase 2's task checks run under today's rules; the first sandboxed run is phase 2's phase test (the lead also found its own sign-off check 1 assumed otherwise, and fixed it). |
| SY 1–6 | "small", "harmless", "machinery", D2's wording, a hedge, a fragment. | Rewritten. |

## Left out (logged as dismissals)

CD Major 4 (Create/Modify/Delete marks, raised again), CD Major 11's first part (`verify` of `sbrun-worktree` in the sandbox: phase 1 runs under today's rules).
