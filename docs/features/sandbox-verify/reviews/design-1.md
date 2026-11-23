# Design review 1: sandbox-verify

Built from:
- `reviews/raw/sandbox-veri-d1-zo-p5.md` (zoom out, grok-4.7-medium)
- `reviews/raw/sandbox-veri-d1-ic-p5.md` (inventive catalyst, glm-5.2-high)
- `reviews/raw/sandbox-veri-d1-cm-p6.md` (comprehension, composer-2.5)
- `reviews/raw/sandbox-veri-d1-dc-p7.md` (design critic, glm-5.2-high)
- `reviews/raw/sandbox-veri-d1-st-p7.md` (structural, grok-4.7-medium)
- `reviews/raw/sandbox-veri-d1-sy-p7.md` (style, glm-5.2-high)
- `reviews/raw/sandbox-veri-d1-zo-p8.md` (zoom out, grok-4.7-medium)
- `reviews/raw/sandbox-veri-d1-ir-p9.md` (implementation readiness, deepseek)
- `reviews/raw/sandbox-veri-d1-cd-p9.md` (codebase details, grok-4.7-medium; first attempt killed by the lead's shell timeout, rerun detached)
- `reviews/raw/sandbox-veri-d1-sy-p9.md` (style, glm-5.2-high)

Each phase's fixes were applied before the next phase ran, so later lenses reviewed the updated design. The codebase lens started before the readiness fixes were committed; its findings were checked against the current text.

## Fixed in the design

| Lens | Finding | Fix |
|---|---|---|
| ZO5 Blocker | The pid file for the cap lived inside the run folder that `Invoke-SandboxCommand` deletes on start. | Pid file is `runs\probe-<hex>.pid`, beside the folder. |
| ZO5 Major, DC7 Major, CD9 Major | `-SandboxRun`'s `output` is the first 40 lines, but failures are judged from the end; `tail` had three meanings; its type was open. | `-SandboxRun` returns `tail` (last 40 lines, array); `test.tail` is that array joined, with the timeout line appended by `verify`; empty when `setup` is set. |
| ZO5 Nit, IC5 Major | Wrapper file written into the worker's worktree (left behind on a hard kill). | Wrapper passed as `-EncodedCommand`; nothing written. |
| IC5 Major | Two `-SandboxRun` orchestration paths. | One helper in `delegate.ps1`; only the probe form removes a worktree (and only a `.probe-` leaf). |
| ZO5 Nit, IC5 Nit | `-NoLogin` widened scope. | Dropped; the login copy is unchanged and documented as a risk with no new exposure. |
| IC5 Major | Scoped "approve the command" alternative missing. | Added to Alternatives, rejected (same exposure as remembering). |
| IC5 Nit | Stored proposal could go stale. | `setup.proposal` is a snapshot; the lead reruns `-SandboxEnv`. |
| CM6 (9 findings) | Stale G3 note, `projects` field, phase host fallback undefined, terms (readiness gate, cap rule, problem stop, size gate) undefined, shared hex, checks without setup. | Terms section; phase flow written out; G3 fixed; fields aligned; shared `<hex>` stated; check setup defined. |
| DC7 Major, ZO8 Major | `.venv` links show as untracked in repos that do not ignore `.venv`, in the scope check and the merge step. | `delegate.ps1` adds `.venv/` to `.git/info/exclude` when it links; risk row for the user's own `.venv`. |
| DC7 Major | Kill path of a hung `delegate.ps1` unspecified. | Risk row: liveness check drops the pid; slot recovered; logs only. |
| DC7 Major | `XAGENT_DELEGATE_SCRIPT` undocumented. | Documented in the delegate skill as test-only; risk row. |
| DC7 Nit | `no free slot` treated as a problem stop. | Lead waits and retries once; second failure stops. |
| DC7 Nit, CM6 Nit | Effective command-line limit, lead-run checks. | About 10,000 characters stated; checks marked lead-run. |
| ST7 Major | Risks under Technical Plan; phase flow without a heading; rejection reasons only "Rejected by author". | Risks is an H2 after Alternatives; "Flow of a phase test" heading; every rejection states its trade-off. |
| SY7 (9 findings) | D4's false `doctor` precedent; uncalibrated "rare", "a few seconds", "minutes later", "most repos", "little else"; Q1/Q2 references. | All rewritten to the evidence. |
| IR9 Blocker | `-OnHost` decision logging: `Invoke-DecisionFeature` exits the process; failure mode open. | `Add-FeatureDecision` helper shared by both; a failed line refuses the run. |
| IR9 Blocker | Argument quoting and host expansion of `$LASTEXITCODE`. | `ProcessStartInfo.ArgumentList`; single-quoted literal; argument-recording fake test. |
| IR9 Major (5) | `where` for setup results; sample fixture; fate of each existing test; path normalization; hang branch untestable; one wrapper. | `where: sandbox` unless `-OnHost`; `verify.json` and `verify-setup.json`; test-by-test list; normalization rule; `hang` mode and `XAGENT_VERIFY_GRACE_SEC`; `New-TaskTestWrapper`. |
| IR9 Nits (8) | `-Base` default, refusal shape, missing override file, flow fields, exclude helper, check 2 setup, file ownership. | Each specified; check 2 is a `Live`-tagged test. |
| CD9 Major (4) | Phase test timeout, `-Quote` already declared, setup results are `ok: true`, `--git-common-dir` is a `.git` folder. | `-TimeoutSec 3600` on phase runs; reuse `-Quote`; `ok: true` stated; common-dir comparison fixed. |
| CD9 Nits, SY9 (M1–M3, N1–N4, N9–N11, N13–N14) | Run-home writes, wording, uncalibrated claims. | Rewritten. |
| Lead | The live check read `$env:USERPROFILE\.gitconfig`, which in the sandbox is the run home's copy and would pass. | The test reads a file at an absolute path in Pester's real `TestDrive`. |

## Author decisions

- D1 (phase tests in the sandbox in every repo) was questioned by ZO5 and ZO8. The author reconfirmed it on 2026-11-20 with the measured cost: this repo's delegate tests fail in the sandbox, so its phases with those tests ask for a host run.

## Left out (logged as dismissals)

IC5 Finding 1 (verify holding a cap slot: task tests are narrow), IC5 Finding 5 (pid file order), DC7 Finding 2 (cap check already in `build.md`), DC7 Finding 6 (structured host-run record: fixed `host run:` prefix instead), ST7 Findings 4 and 6 (heading names, link format), ZO8 Findings 1 and 3 (D1, implementation constants), CD9 blockers (already fixed), CD9 Create/Modify marks, SY9 N5, N12, N15.
