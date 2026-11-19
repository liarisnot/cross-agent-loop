<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Checking the plan for undefined terms and cross-referencing key references.
## What this proposes

The plan implements **sandbox-env**: Python toolchain environments built beside each repo under `<repo>.xagent\.envs\`, linked into worker worktrees as `.venv` junctions, granted per run, so sandboxed delegates can run tests without widening the AppContainer or hand-editing `sandbox.json`. Work is split into five phases and ten delegate tasks: extend `Sandbox.psm1` (grants, env vars, mutex lock helper, `Invoke-SandboxCommand`, canary behavior), add `SandboxEnv.psm1` (discovery, reporting, build/apply, prune, link/unlink, readiness gate), wire `delegate.ps1` (`-SandboxEnv`, `-SandboxRun`, launch gate, cleanup unlinking), then extend `feature.ps1` doctor and update skill/README text. Each task names files, a Pester filter or string check, design rule pointers, and dependencies; phases checkpoint with `scripts/test.ps1` (mostly `-Fast`).

## How the existing system works, per this document

Today, sandboxed workers get a fixed `PATH`, a small read surface, and optional read-list paths; they do not see the user’s `.venv`, `uv`, or interpreters under the profile. The design (referenced throughout) adds host-side builds under `.xagent\.envs\`, records them in `envs.json`, and at run time links junctions plus per-run `(OI)(CI)RX` grants. `delegate.ps1` already launches workers in AppContainer slots via `Sandbox.psm1`; this plan layers environment detection and setup before launch, refuses sandboxed starts when projects are not `ready`, and runs phase tests through `-SandboxRun` instead of the host checkout. With no `-EnvPaths` / linking, behavior must stay as it is today.

---

### Findings

1. **Severity:** Major  
   **Affected Scope:** Phase 1, **sbx-command** (line 18–20); opening summary (lines 3–9)  
   **Discrepancy Description & Rationale:** The locked design’s Phase 1 and `Sandbox.psm1` file row require **Invoke-SandboxCanary to unlink `.venv` junctions before worktree removal** as well as skipping reparse points in the fallback walk. The plan’s task title, table row, and brief only mandate the **reparse-point skip**. A worker who follows only the plan can ship Phase 1 while omitting canary unlinking, which the design ties to safe worktree teardown (junction leftovers).

2. **Severity:** Major  
   **Affected Scope:** **skill-docs** (line 80), `build.md` instructions  
   **Discrepancy Description & Rationale:** The brief tells the author to document “before the first worker `-SandboxEnv -Base feature/<name>`” but elsewhere (e.g. **dlg-commands**, design Components) **`-SandboxEnv` requires `-Repo`**. A reader updating `build.md` from this sentence alone can document an invalid invocation.

3. **Severity:** Major  
   **Affected Scope:** **sbx-envpaths** (line 17), Grant refusal message  
   **Discrepancy Description & Rationale:** The refusal template includes `run -SandboxEnv -Apply -Rebuild <project>` with a note that “the caller passes the project name per path; without one, omit the clause.” The plan does not say **which function is the caller**, how each **EnvPaths** entry maps to a **project** name, or who supplies that mapping when `Get-SandboxGrantList` throws. Implementing the message and tests without guessing requires design excavation (D6 / Grant rule), not the plan alone.

4. **Severity:** Major  
   **Affected Scope:** **sbx-command** (line 20), log directory  
   **Discrepancy Description & Rationale:** Logs go to `<repo>\.xagent\runs\<run name>\`, but **run name** is not defined here. The design’s `Invoke-SandboxCommand` / `-SandboxRun` flow uses a concrete **`probe-<hex>`** run folder tied to the probe worktree name. A naive implementer cannot tell what to pass or assert without reconciling two documents.

5. **Severity:** Major  
   **Affected Scope:** Task tables, **Profile** column (`code`, `code-hard`)  
   **Discrepancy Description & Rationale:** Every task lists a profile, but the plan never states that this is the **delegate worker profile** (model selection from `skills/delegate/models.json`, e.g. `code` vs `code-hard`). Someone scheduling work only from the plan may treat it as an informal label.

6. **Severity:** Major  
   **Affected Scope:** Line 5, `Check-in mode: on-problems`  
   **Discrepancy Description & Rationale:** The mode is stated but **not defined** in the plan (when the lead must stop vs continue across phases). The meaning lives in the feature skill/schemas (`on-problems` vs `every-phase`); the plan does not point there, so a new lead reading only `plan.md` cannot tell what behavior this line commits to.

7. **Severity:** Major  
   **Affected Scope:** All phase task tables (e.g. lines 15–18, 30–33, …)  
   **Discrepancy Description & Rationale:** Each phase puts a **bold task brief between two table rows**, with the **second task’s `| id |` row immediately after the previous brief with no blank line**. In common Markdown renderers the second row is not a reliable table row (it reads as part of the prose block). Id, Depends on, Files, and Test for the second task in each phase are easy to miss when scanning rendered HTML.

8. **Severity:** Major  
   **Affected Scope:** **dlg-launch-gate** (line 65), tests  
   **Discrepancy Description & Rationale:** Tests should “skip when sandbox support is missing, like the existing sandboxed Describes,” but the plan does not name the mechanism (**`Get-LaunchSkipReason -Kind Sandbox`** early-return pattern in `DelegateLaunch.Tests.ps1`). A worker without prior sandbox test literacy must discover this by spelunking rather than from the task brief.

9. **Severity:** Nit  
   **Affected Scope:** **env-report** (line 35), status ordering  
   **Discrepancy Description & Rationale:** Status order is given as `uv-missing, ready, install-failed, stale, missing`. The design’s **Status** rule uses **`unsupported`** (with reasons like `workspace`, `python-version-unknown`) as a distinct outcome, not only `uv-missing`. The shorthand is probably intentional but can mislead someone who does not cross-read Rules **Status**.

10. **Severity:** Nit  
    **Affected Scope:** Phase 5 (lines 71–72) vs Phases 1–4  
    **Discrepancy Description & Rationale:** Phase 5’s checkpoint is `scripts/test.ps1` **without** `-Fast`, while earlier phases use `-Fast`. The plan does not say why (e.g. doctor’s Slow-tagged checks). A lead may wonder whether phase 5 intentionally runs the full suite or this is accidental.

11. **Severity:** Nit  
    **Affected Scope:** **dlg-launch-gate** (line 65), “review and council runs”  
    **Discrepancy Description & Rationale:** The plan says these runs skip the gate but does not state **how delegate distinguishes them** (e.g. `-Profile review` / council). The design mentions review lenses and council seats; the plan assumes that vocabulary without tying it to delegate launch parameters in this file.

12. **Severity:** Nit  
    **Affected Scope:** **sbx-command** (line 20), Pester guidance  
    **Discrepancy Description & Rationale:** “Via the existing command-line helpers” and “stubbed process where the existing tests stub one” point at **Sandbox.Tests.ps1** patterns without naming a **Describe** or **It** block. Usable for veterans, vague for a worker told they only see their task file unless the lead copies more context.
