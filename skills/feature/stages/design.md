# Design

Draft `docs/designs/<name>.md` one section at a time, and move to design review when every section is approved.

When this file applies: the stage is `design`, or the user asked to design a feature and no feature is selected. This file starts with `new` in that second case.

`feature.ps1 <subcommand>` means `pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 <subcommand>`. `<skill dir>`, `<repo>` and `<name>` are defined in SKILL.md.

## Name and create

If no feature is selected:

1. Propose a short name from the request. Lowercase kebab-case, matching `^[a-z0-9][a-z0-9-]{0,30}$`. For example, `export` for "an export-to-PDF feature".
2. Ask the user to confirm or change it.
3. On a clear name, run `feature.ps1 new -Repo <repo> -Name <proposed name>`.

Read `name` and `branch`. On failure, show `error` and stop. `new` refuses when the working tree has uncommitted changes (the user commits or stashes first) or when another feature is in progress. On success it creates `feature/<name>` from `main` and checks that branch out in `<repo>`.

`<name>` is the name you passed. Run `feature.ps1 status -Repo <repo> -Name <name> -Cwd <current folder>` and read `selected` before you draft.

## Draft

Read and follow `<skill dir>/egm/skills/egm-draft/SKILL.md`, with these differences:

- Write to `docs/designs/<name>.md` in `<repo>`, not to `design_draft.md`. Draft it in place with `Status: Draft`. There is no separate draft file to copy at the end.
- After each approved section, run `feature.ps1 commit-design -Repo <repo> -Name <name> -Section "<section heading>"`. Read `commit`. A section approval is a chat question, not a recorded gate.
- Skip EGM Step 6.2 (picking the target folder). The file is already `docs/designs/<name>.md`.
- If the problem statement is missing, ask for it in chat.
- Do not ask the user to type a slash command.

## Council

When you face a choice that is hard to reverse or contested, offer a council as in SKILL.md under "On-request and design/plan councils". Run it only if the user agrees.

## Move to design review

When all sections are approved, run `feature.ps1 stage -Repo <repo> -Name <name> -To design-review`. Read `from` and `to`. Tell the user the feature is in design review. Stop. Do not start the review until they ask to review the design, or say continue.
