# Design

Draft the design doc (`<design doc>`) one section at a time, and move to design review when every section is approved.

When this file applies: the stage is `design`, or the user asked to design a feature and no feature is selected. This file starts with `new` in that second case.

`feature.ps1 <subcommand>` means `pwsh -NoProfile -File <skill dir>/scripts/feature.ps1 <subcommand>`. `<skill dir>`, `<repo>` and `<name>` are defined in SKILL.md.

## Name and create

If no feature is selected:

1. Propose a short name from the request. Lowercase kebab-case, matching `^[a-z0-9][a-z0-9-]{0,30}$`. For example, `export` for "an export-to-PDF feature".
2. Ask the user to confirm or change it.
3. On a clear name, run `feature.ps1 new -Repo <repo> -Name <proposed name>`. When the user brought an existing design (see [Starting from an existing doc](#starting-from-an-existing-doc)), add `-DesignDoc <its repo-relative path>`. When the repo keeps its designs in another folder (for example `docs/design/`), you may also pass `-DesignDoc <that folder>/<name>.md` for a new doc.

Read `name`, `branch`, `designDoc` and `designDocExists`. On failure, show `error` and stop. `new` refuses when the working tree has uncommitted changes (the user commits or stashes first), when another feature is in progress, or, without `-DesignDoc`, when `docs/designs/<name>.md` already exists: ask the user whether that file is their design (rerun with `-DesignDoc docs/designs/<name>.md` to adopt it) or an unrelated one (pick another name). On success it creates `feature/<name>` from `main` and checks that branch out in `<repo>`.

`<name>` is the name you passed. Run `feature.ps1 status -Repo <repo> -Name <name> -Cwd <current folder>` and read `selected` and `designDoc` before you draft.

## Starting from an existing doc

When the user gives a design they already wrote (a path, or a doc they point at, half done or nearly done), respect it. Do not redraft it into EGM's template and do not re-ask for sections they already wrote. Skip [Draft](#draft) for the sections it covers.

The doc must be inside `<repo>` (copy it in first only if it lives outside the repo, after asking where it should go). Never copy a doc that is already in the repo: two copies drift apart.

1. **Adopt it in place.** Create the feature with `new -DesignDoc <its repo-relative path>`, so `<design doc>` is that file, wherever it lives and whatever it is called. Keep its headings, order and wording. Add a `Status: Draft` line under the title if it has none; that is the only mechanical change. Commit with `feature.ps1 commit-design -Repo <repo> -Name <name> -Section "imported"`.
2. **Gap check, not a rewrite.** Read it against what the later stages need, not against EGM's headings:
   - a problem statement, and goals or non-goals clear enough to say what is out of scope;
   - enough detail to plan from: the files or components that change, interfaces other code depends on, and how it is tested;
   - an implementation section the review can tell apart from the spec (a heading such as `Detailed Implementation Plan`, `Implementation Plan`, `Work Breakdown` or `Implementation Steps`).
   Show the user a short list: what is there, and what is missing or too thin to plan from. Quote their headings.
3. **Bulk approval of what is there.** Ask once whether to keep the existing sections as they are. Edits they ask for are made in place.
4. **Draft only the gaps.** For each missing or thin item, draft that section the way [Draft](#draft) says (one approval gate per section, `commit-design` after each), placed where it fits the user's structure. Use EGM's template only for sections the doc lacks.
5. Then [move to design review](#move-to-design-review) as usual. The review lenses run on the doc as it stands; they judge the design, not its headings.

## Draft

Read and follow `<skill dir>/egm/skills/egm-draft/SKILL.md`, with these differences:

- Write to `<design doc>` in `<repo>`, not to `design_draft.md`. Draft it in place with `Status: Draft`. There is no separate draft file to copy at the end.
- After each approved section, run `feature.ps1 commit-design -Repo <repo> -Name <name> -Section "<section heading>"`. Read `commit`. A section approval is a chat question, not a recorded gate.
- Skip EGM Step 6.2 (picking the target folder). The file is already `<design doc>`.
- If the problem statement is missing, ask for it in chat.
- Do not ask the user to type a slash command.

## Council

When you face a choice that is hard to reverse or contested, offer a council as in SKILL.md under "On-request and design/plan councils". Run it only if the user agrees.

## Move to design review

When all sections are approved, run `feature.ps1 stage -Repo <repo> -Name <name> -To design-review`. Read `from` and `to`. Tell the user the feature is in design review. Stop. Do not start the review until they ask to review the design, or say continue.
