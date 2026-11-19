# Plan review 1: sandbox-env

Built from:
- `reviews/raw/sandbox-env-p1-cm.md` (comprehension, composer-2.5)
- `reviews/raw/sandbox-env-p1-ir.md` (implementation readiness, deepseek)

Both reviewed the first import of the plan. The plan was re-imported with the fixes below (10 tasks, 5 phases, unchanged shape).

## Fixed in the plan

| Lens | Finding | Fix |
|---|---|---|
| IR Blocker 1 | `XAGENT_WORKTREE` had no owner; the slot letter isn't known when links are made. | `New-SandboxRun` sets it from the slot it binds whenever `-EnvPaths` is given; callers never pass it. |
| IR Blocker 2 | The `Invoke-SandboxCommand` test relied on a process stub that doesn't exist. | The test is a real sandboxed run, tagged `Sandbox` and skipped like `run lifecycle`. |
| IR Blocker 3 | `docs/test-plan.md`, `docs/HANDOFF.md` and the live checks had no task. | The summary says the lead does them at sign-off. |
| IR Major 1 | Function contracts between tasks unnamed. | Each brief names its exported functions, parameters and return shapes (`Get-SandboxEnvProjects`, `Get-SandboxEnvReport`, `Invoke-SandboxEnvApply`, `Test-SandboxEnvReady`, `Add-SandboxEnvLinks`, `Remove-SandboxEnvLinks`, `Invoke-SandboxLocked`, `Invoke-SandboxCommand`). |
| IR Major 2 | Nothing assembled `pruned` or the `-Apply` output. | `Invoke-SandboxEnvApply` returns `built`, `failedNow`, `pruned`; `-SandboxEnv -Apply` prints a fresh report with them added. |
| IR Major 3, CM 3 | Project name per environment path had no mechanism. | `-EnvPaths` items are `@{path; project}`; the message is built in `Get-SandboxGrantList`. |
| IR Major 4 | CLI refusals unspecified; `-NoSandbox` not in the new sets. | Exact strings given; `-NoSandbox` declared in both new sets so `Fail` can refuse it. |
| IR Major 5, CM 4 | Probe log folder undefined. | `-RunName probe-<hex>` (same hex as the worktree); `stdout.txt` and `stderr.txt`, created by `Invoke-SandboxCommand`. |
| IR Major 6 | Fake `uv` contract split across phases. | The full fake `uv` contract is in `env-discover`; later tasks only add. |
| IR Major 7 | Resolve build's working folder contradicted the lock build's. | Every build runs in `.envs\work\<name>\<project>` with the same variables and `--python`. |
| IR Major 8 | Design-listed test cases missing from briefs. | Added to `env-report`, `env-build`, `env-link`, `dlg-launch-gate`. |
| IR Major 9 | Report field choices open. | One `warning` string joined with `; `; `-Apply` keys absent from a plain report; `envsBytes` from `envs.json`; `-Rebuild` errors given. |
| IR Nits 1, 2, 3, 4, 5 | Fixture paths, the canary filter, `.pth` numbering, the `-NoSandbox` test home, small strings. | Fixed. |
| CM 2 | `build.md` wording dropped `-Repo`. | Full commands given. |
| CM 7 | `plan.md` rendered a phase's second task row as text. | Generator fixed on `main` (briefs after the table) and merged in. |
| CM 8, 11 | Sandbox test skip and read-only detection not named. | `Get-LaunchSkipReason -Kind Sandbox`; `$readOnly`. |

## Left out (logged as dismissals)

CM 1 (canary unlink: the canary links nothing, so only the reparse-point skip applies), CM 5 and 6 (profile and check-in mode are defined by the skills, not the plan), CM 9 (status order now names `unsupported`), CM 10 (the last phase runs the full suite by the plan rule), CM 12 (task files carry the test details).
