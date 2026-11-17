<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Reading the task file to follow the reviewer persona and instructions.


Spot-checking context files for terms the plan references.
Checking G6 freeze wording in the plan against the design's machine-setup section.
## What this proposes

The plan breaks building **worker-sandbox** into five phases and seven worker tasks. It adds a unified `scripts/test.ps1`, removes `taskkill.exe` from skill scripts, implements AppContainer sandboxing (`SandboxNative.cs`, `Sandbox.psm1`), wires it into `delegate.ps1` and `feature.ps1 doctor`, then updates skill docs and README. Phase 3 is the G7 experiment (Decided / Yours to decide). Lead-only steps cover the G6 frozen `delegate` copy, first-time drive-letter reservation, and post–phase 5 manual verification logged in `docs/test-plan.md` and `docs/HANDOFF.md`. The locked design at `docs/designs/worker-sandbox.md` is authoritative; plan briefs reference design “file N” entries.

## How the existing system works, per this document

Today, `delegate.ps1` launches Cursor CLI agents as the Windows user with full disk access; the feature skill orchestrates builds and reviews without filesystem isolation. Timeouts use `taskkill.exe`. There is no single repo test entrypoint for workers. `code` and `code-hard` profiles in `skills/delegate/models.json` choose delegate models. This build keeps live delegate on a frozen worktree at the design lock commit while agents merge new sandbox code into the main checkout; tests and new code exercise the live tree.

---

### Findings (round 2)

Round 1 fixes appear in the plan: phase 2 depends on `test-runner` only, `Test-SandboxSupport` letter shape is pinned, `Remove-SandboxLetters` no-op, probe rules, fake-Cursor skips, `-Fast` vs full suite split, `doctor-check` after `delegate-wiring`, and similar items are not repeated below.

1. **Severity:** Major  
   **Affected Scope:** Opening summary, LEAD AND USER STEPS (1) / G6 (line 3)  
   **Discrepancy Description & Rationale:** The summary says the lead points `~/.claude/skills/delegate` and `~/.claude/skills/feature` at **it**, where **it** is the frozen worktree root `D:/cross-agent-loop.frozen`. Junctions must target the **per-skill** paths under that worktree (`...\skills\delegate` and `...\skills\feature`), as in the design’s machine-setup steps. Pointing both links at the repo root would break the skill layout. Someone following only the plan’s compressed G6 step could misconfigure the freeze before phase 1.

2. **Severity:** Major  
   **Affected Scope:** `sandbox-run` task, Files column and brief (lines 40–44)  
   **Discrepancy Description & Rationale:** The task allows changes under `skills/delegate/tests/fixtures/`, but the brief’s acceptance scope is design **file 5** only, which does not define any files in `fixtures/`. Phase 4’s `delegate-wiring` task also scopes the same folder and names `fixtures/fake-cursor/` (design file 6). A phase-3 worker cannot tell whether they should add fixture files, leave the folder alone, or only prepare for phase 4, so two workers could make different choices under the same path.

3. **Severity:** Major  
   **Affected Scope:** Phase 4 intro (line 48), `delegate-wiring` test command (lines 52–54), cross-task with `test-runner` (line 17)  
   **Discrepancy Description & Rationale:** Phase 4 explains serial tasks because both runs execute **container tests** (real drive letters). `delegate-wiring` uses `scripts/test.ps1 -Fast`, which the plan defines as excluding tags `Live` and `Slow` only. The plan never states that container tests use the `Sandbox` tag (design file 5), so a reader may believe `-Fast` skips the risky letter-reserving tests and miss why serial execution matters. The link between phase rationale and this task’s test command lives in the design or inference from Pester tags, not in the plan.

4. **Severity:** Nit  
   **Affected Scope:** `sandbox-run` brief, term “access table” (line 44)  
   **Discrepancy Description & Rationale:** The Decided section refers to “the access table’s paths and icacls specs” without naming the design section **“What the sandbox can reach”** (where the table lives). A worker who reads the brief before the design may not know which table is meant until they search the design doc.

5. **Severity:** Nit  
   **Affected Scope:** `sandbox-docs` brief (line 71), design file 11 / existing `feature.Tests.ps1`  
   **Discrepancy Description & Rationale:** The brief says the task template must keep **six headings**. The template has five `##` sections plus the `# Task <id>: <title>` line; the existing template test checks all of those by regex but the plan does not say the sixth is the title line. A worker might add a sixth `##` section and still think they satisfied the brief.

6. **Severity:** Nit  
   **Affected Scope:** LEAD AND USER STEPS (3), line 3  
   **Discrepancy Description & Rationale:** Post–phase 5 checks name “lens and council seat” runs without `-Profile review` / `-Profile council` or pointers to design CUJ 4. A new lead can infer profiles from the design, but the plan alone does not spell how those manual canary runs are invoked.
