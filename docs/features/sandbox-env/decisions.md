# Decisions: sandbox-env

Append-only. One line per entry: `- <ISO time> [<kind>] <text>`. Written only by feature.ps1.

- 2026-11-18T03:57:09Z [decision] design D1: environments live per repo in <repo>.xagent\.envs\, named py<ver>-<lockhash>; chosen over a shared root (sharing across repos is rare and D: copies anyway)
- 2026-11-18T03:59:16Z [decision] design D2: interpreters always copied with uv into <repo>.xagent\.envs\python\<version>\; never grant the user's installed Pythons
- 2026-11-18T04:16:08Z [decision] design D3: projects with uv.lock install with uv sync --frozen; without a lock, copy the .venv site-packages onto the copied Python and fix up launchers and editable installs; if that fix-up grows past one normal task, fall back to installing from requirements/pyproject (B); never reinstall from a read of the .venv
- 2026-11-18T04:20:41Z [decision] design D4: before each sandboxed run the host links every project's environment into the worktree as a .venv junction; a copy of uv.exe goes on the sandbox PATH; principle: decide automatically and correctly, ask the user only for cost approval
- 2026-11-18T05:19:28Z [stage] design -> design-review
