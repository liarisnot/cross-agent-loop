<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Reading the target design doc and referenced context files for the comprehension audit.


## Paraphrase

### What this proposes

The design adds **sandbox-env**: tooling so sandboxed `delegate` workers can run Python tests when interpreters, `uv`, and virtualenvs normally sit outside what the Windows AppContainer may read. Discovery finds per-repo Python “projects” (lockfile or resolve layouts), reports readiness under `<repo>.xagent\.envs`, and on user approval builds host-side, sandbox-readable environments with `uv`, copies managed interpreters there, and at each worker or probe run junction-links them into the worktree as `.venv` and adds **per-run** read grants (not wider profile access). New entry points are `delegate.ps1 -SandboxEnv` (report / `-Apply` build / prune) and `-SandboxRun` (run a shell command in the sandbox and classify failure). `feature.ps1 doctor` and pre-build steps in `build.md` and the delegate SKILL are meant to run these checks before the first worker.

### How the existing system works, per this document

With **worker-sandbox** (linked at the top), workers, review lenses, and council seats run in an AppContainer that can reach the git worktree, standard Windows locations, optional **read-list** paths from `%LOCALAPPDATA%\xagent\sandbox.json` (with `addToPath`), and the network—not the user profile, not arbitrary `C:\` roots, and not `AppData\Roaming` on the read list by policy. Tooling is exposed via a fixed **PATH** plus any read-list `addToPath` entries. Workers use fresh detached worktrees; sandbox runs use reserved drive-letter **slots** and a **per-run grant list** for temporary ACLs. Python repos that keep `.venv` and `uv` under the profile or custom `C:\` paths therefore fail inside the sandbox until someone hand-edits `sandbox.json`; this feature replaces that with repo-local `.envs`, junctions, and grants scoped to linked environments only.

---

## Findings

### 1. Severity: Major

**Affected scope:** Open Questions — “Settled since the first draft” (lines 52–53), before Technical Plan.

**Discrepancy description & rationale:** That bullet cites **probe P3**, **D3**, and editable-install behavior before the document defines decision IDs or probe IDs (Decisions table ~lines 58–67; Probes ~lines 158–167). A reader going top to bottom hits unexplained shorthand (“P3”, “D3”) at a point where those labels have no meaning in-document yet. Either move the settled items below the Probes/Decisions sections, spell them out in plain language here, or drop the IDs in this early summary.

---

### 2. Severity: Major

**Affected scope:** Components — `delegate.ps1 -SandboxEnv` (lines 90–91); Data — `envs.json` (lines 171–191); Files table.

**Discrepancy description & rationale:** The on-disk **`envs.json`** schema is specified in detail, but the **stdout JSON** from `-SandboxEnv` (per-project `ready` / `missing` / `stale` / `unsupported`, proposals, estimates, `.envs` size) is only described in prose. There is no field list, nesting, or examples comparable to `-SandboxRun`’s `exitCode` / `diagnosis` list or to `envs.json`. Implementers, `feature.ps1 doctor`, and Pester stubs need a stable contract; without it, “prints one JSON object” is under-specified for a design that treats CLI JSON as the integration surface.

---

### 3. Severity: Major

**Affected scope:** Rules — “`-SandboxRun` diagnosis” (line 217) vs Components — `-SandboxRun` (line 92).

**Discrepancy description & rationale:** The Components section says diagnosis may include **`environment-missing`** when a project has no ready environment and **the command is not run**. The Rules diagnosis enumeration (line 217) lists `ok`, `command-not-found`, `module-missing`, `access-denied`, `timeout`, and `other` but **omits `environment-missing`**. That reads as an internal contradiction about whether probe callers must handle a distinct diagnosis or map it to something else.

---

### 4. Severity: Major

**Affected scope:** Goals G5 (line 35); Components / `stages/build.md` (lines 94–95, 234); Flow (line 106).

**Discrepancy description & rationale:** G5 and the planned `build.md` change say **`feature` runs each phase’s test command** once via `-SandboxRun` before workers start. This document does not define what a “phase” is, where the test command lives, or how many commands run (one per phase vs one for the whole build). That structure lives in `skills/feature/stages/plan.md` (`phases[].test` in `feature.json`), which is not linked here. Someone implementing only from `sandbox-env.md` cannot tell how `-SandboxRun` is invoked in a multi-phase feature without opening another doc.

---

### 5. Severity: Major

**Affected scope:** Rules — Interpreter (lines 201–203); Decision D8 (line 67); Verification live checks (lines 243–245).

**Discrepancy description & rationale:** Status and builds are evaluated at **`<ref>`** (often `feature/<name>` in a worktree), but interpreter fallback uses **`version_info` from the user’s checkout** `<project>\.venv\pyvenv.cfg` when lock/metadata are ambiguous. The doc does not say what happens when checkout and feature-branch worktree disagree (common under D8). A reader cannot tell whether stale checkout venv metadata can pick the wrong Python for a branch-specific lockfile.

---

### 6. Severity: Major

**Affected scope:** Goals G1 (line 31); Overview / Problem (throughout).

**Discrepancy description & rationale:** G1 states the canary-style probe “uses no **Cursor allowance**.” **Cursor allowance** is not defined or linked in this document (usage limits, billing, or similar). Without that, the cost/rationale of preferring `-SandboxRun` over launching a worker is only partly understandable from the text alone.

---

### 7. Severity: Minor (Nit)

**Affected scope:** Components diagram (lines 77–87, especially line 79).

**Discrepancy description & rationale:** The ASCII block shows `-SandboxEnv [-Apply]` without **`-Repo`**, while every normative description uses `-SandboxEnv -Repo <repo> [-Base <ref>]`. Easy to copy the wrong invocation from the diagram.

---

### 8. Severity: Minor (Nit)

**Affected scope:** Probes table (lines 162–167).

**Discrepancy description & rationale:** Rows are **P1, P2, P3, P5** with **no P4**. Later text does not say P4 was dropped or merged. Readers auditing probe coverage may assume a missing row or editing error.

---

### 9. Severity: Minor (Nit)

**Affected scope:** Data — Hash (line 193).

**Discrepancy description & rationale:** Hashing for lockfiles uses **`Get-SandboxFileHash`**, a project helper in `Sandbox.psm1`, with no brief behavior note or pointer. A builder who does not already know worker-sandbox internals cannot tell algorithm, encoding, or path normalization from this doc alone.

---

### 10. Severity: Minor (Nit)

**Affected scope:** Goals G5; delegate-only path (line 35).

**Discrepancy description & rationale:** **`A lead using delegate alone`** should run “the same probe” before the first worker, but the ordered steps (`-SandboxEnv` then which `-SandboxRun` commands, from where) are fully spelled out only for the **feature build** path in the Files table, not in a single delegate-only recipe in this doc. The intended SKILL.md changes are named, but this design file alone does not close that loop for delegate-only use.

---

### 11. Severity: Minor (Nit)

**Affected scope:** Path placeholder `<repo>.xagent\.envs\` (throughout).

**Discrepancy description & rationale:** **`.xagent`** under the repo is used as the anchor for worktrees, runs, and `.envs` but is not defined in this document (contrast worker-sandbox, which describes run homes under worktree `.xagent`). Reasonable for repo insiders; a cold reader may not know whether `.envs` lives in the primary checkout only or also in detached worktrees.

---

**Note:** Concepts such as **AppContainer**, **read list**, **slots**, **review lens**, **council seat**, and **lead** are inherited from `worker-sandbox.md` and `delegate` SKILL material referenced in GoldfishContext; the Overview links worker-sandbox. **`uv`** is treated as known external tooling per caller instructions. No finding is raised for general terms (junction, `pytest`, `icacls`, etc.).
