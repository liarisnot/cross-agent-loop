<!-- persona: comprehension | agent: cursor | model: composer-2.5 -->
Reading the task file and following the reviewer persona and instructions.


## What this proposes

The document designs a **worker sandbox** for the `delegate` workflow on Windows 11 Home: every Cursor CLI agent run launched by `delegate.ps1` (workers, review lenses, council seats) should run inside a **Windows AppContainer** so it can only read and write allowed paths—primarily its git worktree, a synthetic run home under the worktree, shared read-only repo `.git` data, and system or user-configured tool paths. Shell and agent file access outside that set should fail; network access is either on or off per run (not a per-host allow list). The design keeps `delegate.ps1`’s outward contract (parameters, JSON summary, worktree/branch layout) while adding `Sandbox.psm1`, a patched copy of Cursor’s bundled `node.exe` (libuv pipe fix), `subst` drive letters for worktree and runtime cache, job-object-based kill instead of `taskkill`, and explicit recording of `sandboxed` in outputs. During implementation, the build must use a **frozen** copy of `delegate`/`feature` skills (G6) and the first `code-hard` task trials a two-part task template (G7).

## How the existing system works, per this document

Today, `delegate.ps1` starts Cursor CLI agents as the **user’s Windows account** with `--force`, so shell commands need no approval and file tools can read **any path**; nothing ties the agent to its assigned git worktree. Review lenses (`ask` mode) and council seats (`plan` mode) are “read-only” in the sense of not editing, but they can still read the whole machine. Cursor’s own `--sandbox` does not provide filesystem isolation on native Windows, and the agent’s built-in read tool can still see the disk per Cursor settings. That leaves prompt-injection and mistake scenarios where workers could read secrets (e.g. under the user profile or other repos), write outside the worktree without the lead seeing it in diffs, or use the network freely; a prior mitigations pass only stripped **environment** secrets, not files or network. The lead (Claude Code) still orchestrates via `delegate.ps1` and the `feature` skill; workers produce branches and `result.json` for review.

---

### Findings

**1.**  
**Severity:** Major  
**Affected Scope:** Goals (G7), Verification Plan (G7), lines 32, 177, 541–542 — term **`fb-stages`**  
**Discrepancy Description & Rationale:** G7 and verification require comparing the first `code-hard` run to an earlier tightly specified `code-hard` run named `fb-stages`. The document never says what `fb-stages` is (task id, feature name, test-plan entry, or repo path). A new reader cannot interpret the success criterion or what “comparison” should contain.

**2.**  
**Severity:** Major  
**Affected Scope:** The Problem, line 19 — **`build step 1`** and **secret-variable denylist**  
**Discrepancy Description & Rationale:** The problem statement assumes a prior build step that added a “secret-variable denylist” and contrasts it with file/network gaps. Neither the denylist’s behavior nor “build step 1” is defined anywhere in this document. Someone reading only this design cannot understand what is already mitigated versus what the sandbox replaces.

**3.**  
**Severity:** Major  
**Affected Scope:** CUJ 3, lines 68–69 — **“existing read-only check”**  
**Discrepancy Description & Rationale:** CUJ 3 says the sandbox prevents writes and that “the existing read-only check still runs after the run and finds no changes.” The check is not named, located, or described (script, skill step, git diff, etc.). The journey mixes new sandbox behavior with an unspecified legacy mechanism.

**4.**  
**Severity:** Major  
**Affected Scope:** Build order and Verification Plan, lines 523–524, 529, 534 — **`code-hard`**, **`code`**, **`lead`** as task profiles  
**Discrepancy Description & Rationale:** Phases assign work to profiles `code`, `code-hard`, and `lead`, and G7 hinges on the first `code-hard` task. The document does not define what these profiles mean (how tasks are launched, constraints, or how they differ from `-Profile review` / `-Profile council` on `delegate.ps1`). A naive reader cannot map the build table to an executable workflow without the `feature` skill doc.

**5.**  
**Severity:** Major  
**Affected Scope:** Overview and CUJ 1, lines 11, 54 — **`feature` in `build`**, **`feature` skill**  
**Discrepancy Description & Rationale:** CUJ 1 assumes “a feature in `build`” and multiple sections say the `feature` skill calls `delegate` unchanged. The lifecycle states (`build`, planned `code` task, plan stage for G7 template) are not explained in this file. The sandbox’s fit into that lifecycle is implied rather than self-contained.

**6.**  
**Severity:** Nit  
**Affected Scope:** Non-Goals, line 39 — **`T0`** and **`agy`**  
**Discrepancy Description & Rationale:** “Antigravity. `agy` stays refused (T0)” uses an unexplained priority label `T0` and an abbreviated agent name without saying what Antigravity/`agy` would have been. Non-goals are still readable at a high level, but the line assumes insider vocabulary.

**7.**  
**Severity:** Nit  
**Affected Scope:** Detailed Implementation Plan §11, line 502 — **`D19`**  
**Discrepancy Description & Rationale:** The proposed amendment to `feature-skill.md` should match “the same style as D19,” but `D19` is not identified in this document (decision id, section, or line). An implementer editing that file without cross-reading may guess wrong.

**8.**  
**Severity:** Nit  
**Affected Scope:** Alternative I, line 271 — **`phantombot`**  
**Discrepancy Description & Rationale:** The text says “phantombot moved from this design to drive letters for the same reason,” which reads like an internal changelog reference. The link to phantomyard PR is in Additional Resources, but the inline name is not defined as a prior design iteration or author alias.

**9.**  
**Severity:** Nit  
**Affected Scope:** Verification Plan (Failure), line 537 — **`runs.jsonl` on failed sandbox start**  
**Discrepancy Description & Rationale:** The pass criterion says “nothing written to `runs.jsonl` as sandboxed,” which is ambiguous: no line at all, or a line with `sandboxed: false`, or no erroneous `sandboxed: true`. Failure behavior for logging is not fully precise.

**10.**  
**Severity:** Nit  
**Affected Scope:** Components diagram and CUJ 1, lines 96–99, 55 — **`cursor-agent.ps1`**  
**Discrepancy Description & Rationale:** Launch describes today’s path via `powershell.exe -File cursor-agent.ps1`, while the sandboxed path goes straight to patched `node.exe index.js`. The role of `cursor-agent.ps1` in the unsandboxed path (wrapper vs. full launcher) is not stated, which slightly weakens the before/after mental model.

**11.**  
**Severity:** Nit  
**Affected Scope:** Open Questions, line 47; Cursor login, lines 153–154 — **token refresh risk**  
**Discrepancy Description & Rationale:** The document marks token refresh inside the sandbox as an open risk and proposes a conditional “checked copy-back.” Verification only says to check login after three runs over a day. A reader cannot tell whether partial invalidation is acceptable or a hard fail without a stated decision rule.

**12.**  
**Severity:** Nit  
**Affected Scope:** Table “What the sandbox can reach”, line 122 — **`read attributes only, this folder only`** on repo parents  
**Discrepancy Description & Rationale:** The ACL intent for parent folders is subtle (git path walks vs. no listing). The doc explains why in “Why drive letters” partly, but the table alone may leave readers unsure what “read attributes only, this folder only” means in practice (per-directory RA without inheritance vs. traverse-only).

---

### Paraphrase / coherence note (not a separate finding)

The narrative is largely coherent: problem → goals (including the amended G3) → AppContainer decision → path/capability model → patch/kill/login → alternatives → implementation phases. The **G6 build exception** (workers during this feature build use frozen, non-sandboxed `delegate`) is stated in multiple places and matches “sandbox on by default after merge” in rollout; I did not treat that as a contradiction. Cross-references to `docs/designs/feature-skill.md`, `docs/HANDOFF.md`, and `docs/designs/worker-sandbox-probe/` are explicit links for material outside this file; I did not flag general Windows/AppContainer/git terms or well-known external issues (e.g. nodejs/node#66374) as gaps.
