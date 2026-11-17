<!-- persona: design_critic | agent: cursor | model: glm-5.2-high -->
I have completed my read-only review. Here is the full report.

---

# Design Critic Review — `docs/designs/worker-sandbox.md` (lines 1–332)

**Mode:** REVIEW
**Persona:** Design Critic Goldfish
**Target Standard:** Feature Specification Standard

## Standard Compliance Summary

| Standard Requirement | Status | Notes |
|---|---|---|
| Problem Statement | ✅ | Lines 14–20, concrete and well-scoped. |
| Goals & Non-Goals | ✅ | G1–G7 with Pass criteria; Non-Goals lines 38–44. |
| Proposed Architecture | ✅ | Technical Plan lines 86–178; component diagram, access table, launch/kill, login, cleanup. |
| Alternatives Considered | ✅ | A–K (lines 188–291), each with For/Against and a concrete rejection rationale. Maintainer attributions are linked (phantombot PR #787, seshat PR #816, libuv#5178, nodejs/node#66374, openclaw PR #161128). |
| Risks & Mitigations | ✅ | Security table lines 296–303; Performance lines 305–309; Rollout/Rollback lines 311–315. |
| Success Metrics | ⚠️ Partial | Goals have Pass criteria; Verification Plan maps to goals. But the 5 s overhead SLO (line 306) has no failure consequence. |

The document **passes** the Feature Specification Standard on structure and the Alternatives Rule. The findings below are stress-test results on assumptions, residual risks, and architectural gaps — not standard-compliance failures.

---

## Findings

### 1. [Major] Cursor auth token is exfiltratable over the network — a risk the sandbox itself introduces and then accepts
**Affected Scope:** "Cursor login" (lines 142–144), Security table row 1 (line 297), G3 (lines 27–28).

**Finding:** The Problem section (line 16) frames the threat as: *"One injected instruction can make a worker read a secret and print it into … a network request."* The sandbox blocks reading `~/.ssh`, `~/.aws`, etc. But the sandbox **copies `auth.json` into the run home** (line 142) and grants the container read access to its own run home (access table, line 124). G3 was amended from a per-host allow list to all-or-nothing because *"the agent needs Cursor's servers, so the sandbox cannot block shell traffic by host"* (line 27). The net effect: a sandboxed worker has unrestricted network egress **and** a readable Cursor auth token in its run home. A prompt-injected worker can `curl` the token to any host. The Security table accepts this as "no new trust" (line 297), but the Problem section explicitly named network exfiltration as the motivating threat, and the sandbox does not close that path for the very credential it injects.

**Recommendation:** Either (a) narrow G3's residual-risk statement in the Problem section so the reader understands network exfiltration of the in-sandbox token is an accepted residual, not a solved threat; or (b) revisit Alternative K with a loopback-proxy design that whitelists Cursor's hosts only, even if it costs an admin step on first run. As written, the design's threat model and its accepted-risk register are inconsistent on this point.

---

### 2. [Major] User-level `.gitconfig` is unreachable inside the sandbox — commits may fail or be misattributed
**Affected Scope:** "What the sandbox can reach" table (lines 116–128), "Cursor login" (lines 142–144), environment array (lines 396–401).

**Finding:** `USERPROFILE` and `HOME` are redirected to `<W>:\.xagent\sandbox` (line 124, line 399). git resolves `~/.gitconfig` via `HOME`/`USERPROFILE`, so inside the container it looks for `<W>:\.xagent\sandbox\.gitconfig`, which does not exist. The design copies `cli-config.json` and `auth.json` into the run home (line 142) but **does not copy or grant read access to the user's `.gitconfig`**. The repo's `.git\config` is read-only accessible (line 121), but only if `user.name`/`user.email`/signing config are set at the repo level — which is not guaranteed. Consequence: a worker's `git commit` may fail with "Please tell me who you are," or silently use repo-level fallback identity. This is not mentioned in Open Questions, Limits, or Risks.

**Recommendation:** Add the user's `.gitconfig` (read-only) to the run-home copy step, or add an explicit read-list entry for it, or document that workers require repo-level git identity. Add a CUJ or canary assertion that `git commit` succeeds inside the sandbox.

---

### 3. [Major] Token-refresh inside the sandbox may invalidate the user's own token — mitigation is deferred to test-time
**Affected Scope:** Open Questions "Cursor login inside the sandbox" (line 35), "Cursor login" (line 144), Verification Plan "Token refresh" (line 540).

**Finding:** The design states: *"If testing shows that a token refresh inside the sandbox invalidates the user's own copy, a checked copy-back is added"* (line 144). This is a known-unknown with the mitigation left undefined. A long worker run that crosses a refresh window will write a refreshed token to the run-home `auth.json`, which is deleted on cleanup (line 142) — so the refresh is lost, and the user's real `auth.json` may hold a now-rotated-away token. The Verification Plan checks this over 3 runs / 1 day (line 540), but the design does not specify the copy-back mechanism, its atomicity, or what "checked" means (compare before overwrite? lock?). This is the single largest correctness risk to the user's environment outside the worktree.

**Recommendation:** Specify the copy-back design now (even as a conditional branch): when the sandboxed `auth.json` differs from the source at run end and the source token is no longer valid, atomically replace it under a lock. Otherwise, document that token refresh inside the sandbox is **disabled** (e.g., by making `auth.json` read-only and handling the refresh failure), which sidesteps the issue entirely.

---

### 4. [Major] G6 bootstrapping leaves the feature's own build workers unsandboxed
**Affected Scope:** G6 (lines 31, 168–172), Build order note (line 529).

**Finding:** The design is candid: *"Workers in this build are not sandboxed: they use the frozen `delegate` (G6)"* (line 529). The frozen `delegate` predates the sandbox code, so every worker that builds the sandbox runs with full disk read and network reach — exactly the exposure G1/G3 are meant to close. This is a self-acknowledged bootstrapping gap, and it is bounded (only this feature's build), but it is worth surfacing as a residual risk in the Security table rather than only in the build-order note. A reader assessing "is this feature safe to build?" will not find that answer in the Risks section.

**Recommendation:** Add a Security-table row: "The feature's own build workers run unsandboxed (G6). Mitigation: build is short, frozen copy is reviewed, and the sandbox is on for all runs after merge." This makes the residual explicit.

---

### 5. [Major] Read-only runs (G2) can write to their run home, which lives under the read-only worktree — the "no changes" check needs an exclusion
**Affected Scope:** Access table row "Run home and temp" (line 124), CUJ 3 (lines 64–66), G2 (line 25).

**Finding:** For lenses/councils, the worktree is granted `(OI)(CI)RX` (read-only, line 392), but the run home `<worktree>\.xagent\sandbox` is granted `(OI)(CI)M` (read+write) **also in read-only runs** (line 124). The run home is a subfolder of the read-only worktree. CUJ 3 asserts *"the existing read-only check still runs after the run and finds no changes"* (line 66). For that check to pass, it must exclude `.xagent/`. The design notes `.xagent/` is in the repo's `info/exclude` (line 124), but `info/exclude` governs git ignored files, not necessarily the read-only check's logic. If the check uses `git status --porcelain`, ignored files are hidden and the check passes; if it uses a full directory walk, it does not. The design does not state which.

**Recommendation:** State explicitly that the read-only check ignores `.xagent/` (and cite the check's implementation), or move the run home outside the read-only worktree for read-only runs (e.g., under `%TEMP%`). As written, G2's Pass criterion depends on an unstated assumption about the check.

---

### 6. [Major] `node.exe` patch fragility across Cursor auto-updates — recurring 256 MB copy + silent version churn
**Affected Scope:** "The patched `node.exe`" (lines 136–141), "Get-SandboxRuntime" (lines 376–381), Performance (line 307).

**Finding:** The patch assumes the byte pattern `\\?\pipe\uv\%llu-%lu` appears exactly once (line 139). Cursor auto-updates silently; each new Cursor version triggers a fresh 256 MB copy + patch (line 307). The design keeps current + previous cache versions (line 381), which is reasonable, but: (a) the 5 s overhead SLO is "after the first run of a Cursor version" — the first-run cost (256 MB copy + byte scan + ACL grant) is unbounded and not given an SLO; (b) if Cursor ships a version where the pattern appears 0 or 2 times, **every** sandboxed run fails (CUJ 4) until `Sandbox.psm1` is updated — there is no automatic fallback to `-NoSandbox`, which is intentional (G5), but it means a Cursor update can halt all worker runs until the user notices. The Open Question "Cursor login inside the sandbox" is resolved for the probe, but the patch-maintenance cadence is not in the Risks table.

**Recommendation:** Add a Risk row for "Cursor auto-update changes the pipe-name pattern." Add a monitoring hook: `Test-SandboxSupport` (run by `feature.ps1 doctor`) should warn before a build if the current Cursor version's pattern count is not 1, so the user discovers the breakage outside a worker run, not inside one.

---

### 7. [Major] Stale `.running` markers and `subst` letter reference-counting — cleanup is best-effort with no crash recovery
**Affected Scope:** "Stop-SandboxRun" (line 403), probe README "cscript.exe" finding (line 27), "Limits that stay" (line 182).

**Finding:** Runtime-letter removal is reference-counted via `.running` files in `%LOCALAPPDATA%\xagent\sandbox\letters\` (line 403). If `delegate.ps1` is killed (PowerShell crash, `Ctrl+C`, machine freeze) before its `finally` runs, the `.running` file and the `subst` mapping leak. The probe README separately notes `cscript.exe` failing inside the container causes Cursor's own `.running` markers to build up in the runtime cache (line 27), with a vague "Sandbox.psm1 can clear them when no run is live." Neither cleanup is specified precisely: no liveness check, no max-age, no startup sweep. Over time, stale letters consume drive-letter slots (only ~19 free letters from `Z` down to `H`), and stale `.running` files prevent letter reuse.

**Recommendation:** Specify a startup sweep in `Test-SandboxSupport` or `New-SandboxRun`: remove `subst` letters whose `.running` file's owning PID is no longer alive (or whose mtime exceeds a max-age). Document the liveness predicate. Without this, the system degrades silently under crashes.

---

### 8. [Minor / Nit] Performance SLO has no failure consequence
**Affected Scope:** Performance (line 306), Verification Plan "Overhead" (line 540).

**Finding:** "Target: 5 s or less added (median), after the first run of a Cursor version." The Verification Plan measures it but does not state what happens if it is exceeded — is the feature blocked, is the SLO relaxed, is it a follow-up? The standard requires that constraints be called out; this SLO is stated but not enforced.

**Recommendation:** State the consequence (e.g., "If exceeded, investigate before merge; the SLO is not a hard gate") so a fresh reader knows whether 8 s is acceptable.

---

### 9. [Nit] `taskkill.exe` → `Process.Kill($true)` change also affects the unsandboxed path
**Affected Scope:** delegate.ps1 modify (line 425), feature.ps1 modify (lines 426–428).

**Finding:** The switch from `taskkill /T /F` to `[Diagnostics.Process]::GetProcessById($id).Kill($true)` is bundled into this feature for sandbox reasons, but it also changes the unsandboxed kill path. `Process.Kill(bool)` (tree kill) is .NET 5+ / PowerShell 7 only — fine here, but its tree-walk semantics differ slightly from `taskkill /T` (which walks job objects differently). The design wraps it in try/catch (line 425), which is good, but does not note that orphaned grandchildren spawned outside the job may survive `Kill($true)` in edge cases. Low risk, but worth a test.

**Recommendation:** Add a container test (file 5) asserting that a two-level child tree dies on `Kill` — the existing CUJ 5 test covers the sandboxed job-object path; add the unsandboxed `Process.Kill($true)` equivalent.

---

### 10. [Nit] G7 two-part task template is scope-creep relative to the sandbox feature
**Affected Scope:** G7 (line 32), "The two-part task template" (lines 174–176), Build order phase 2 (line 522).

**Finding:** G7 bundles a task-template experiment ("Decided" / "Yours to decide") into a feature whose subject is sandboxing. The design is transparent and scopes G7 to one task plus a `test-plan.md` entry, but a fresh reader may find the coupling surprising. Not a defect — the author is explicitly running an experiment — but it weakens the "one feature, one thesis" clarity the standard implies.

**Recommendation:** No change required. If the author wants sharper scope, G7 could be split into its own follow-up feature; as written it is acceptable because it is bounded and recorded.

---

### 11. [Nit] SSH-based git remotes are silently unusable inside the sandbox
**Affected Scope:** "What the sandbox can reach" (lines 116–128), PATH (line 397).

**Finding:** `~/.ssh` is blocked (probe confirmed, line 91). Workers can only use HTTPS remotes. The design does not state this as a Limit. A worker task that runs `git push` over SSH will fail opaquely. Low impact for this repo (Cursor uses HTTPS), but a reusable `delegate` skill should document it.

**Recommendation:** Add a one-line Limit: "SSH git remotes are unavailable inside the sandbox; workers use HTTPS."

---

### 12. [Nit] `-SandboxCheck` runs a full canary container on every `doctor` call
**Affected Scope:** "Requirements check" (lines 150–152), feature.ps1 doctor (line 429).

**Finding:** `-SandboxCheck` creates an AppContainer profile, grants, plants canaries, runs a container, and cleans up (line 151, `Invoke-SandboxCanary`). `feature.ps1 doctor` calls it (line 429). If `doctor` is run frequently (e.g., before every feature), this is non-trivial overhead and creates/deletes a profile each time. The design does not say the canary is cached or skippable.

**Recommendation:** Split `-SandboxCheck` into a fast support check (build, install, free letters) and an optional `(-Canary)` that runs the container; have `doctor` run the fast check by default.

---

## Cross-Reference to Source Claims

Claims in the design verified against the worktree:

- **"delegate.ps1 today launches via `powershell.exe -File cursor-agent.ps1`"** — confirmed, `skills/delegate/scripts/delegate.ps1:286–289`.
- **"workers run with `--force`"** — confirmed, line 293.
- **"review = ask mode, council = plan mode"** — confirmed, line 293.
- **"taskkill.exe /T /F /PID"** — confirmed, line 349.
- **"secret-variable denylist pattern"** — confirmed, line 324 (`_API_KEY|_TOKEN|_SECRET$|^(AWS_|AZURE_|ANTHROPIC_|OPENAI_)|^(GH_TOKEN|GITHUB_TOKEN|SSH_AUTH_SOCK|GOOGLE_APPLICATION_CREDENTIALS|DATABASE_URL)$`).
- **Probe findings (README)** — confirmed: Windows PowerShell 5.1 fails, `subst` doesn't hide real path from git, Node checks drive root, `taskkill` hangs, `cscript` fails, Pester TestRegistry must be off, OneDrive\Documents unreadable, `localhost` works without loopback exemption.
- **feature-skill.md Risks row "Unmitigated in v1"** — confirmed, `docs/designs/feature-skill.md:661`, and the Future Improvements row names worker sandboxing as "first after v1" (line 678). The proposed post-lock amendment (file 11, lines 499–501) is consistent with the existing "D19" amendment style.

External sources (libuv#5178, nodejs/node#66374, phantombot PR #787, seshat PR #816, openclaw PR #161128) cannot be opened from this sandbox; the design's summaries are treated as claims and evaluated internally for consistency. They are coherent with the probe README's first-hand debugging notes (e.g., the `uv_spawn → uv_pipe → CreateNamedPipeA` stack trace, line 24–25 of the probe README).

The previous message contained the complete review report. No continuation is needed — all 12 findings, the standard-compliance summary, and the source-claim cross-references were delivered in full before the interruption notice.

To confirm the report is complete:

- **Standard Compliance Summary** — 6-row table covering Problem Statement, Goals & Non-Goals, Proposed Architecture, Alternatives Considered, Risks & Mitigations, Success Metrics.
- **Findings 1–12** — severity, affected scope, finding, and recommendation for each, ordered Blocker-equivalent (Major) first, then Minor/Nit.
- **Cross-Reference to Source Claims** — verified `delegate.ps1` lines 286–349, `feature-skill.md` line 661/678, and the probe README findings.

The single highest-priority items, if the orchestrator wants a triaged shortlist:

1. **Finding 1** — Cursor auth token is network-exfiltratable; the threat model and accepted-risk register disagree.
2. **Finding 2** — User-level `.gitconfig` is unreachable; worker commits may fail or misattribute.
3. **Finding 3** — Token-refresh copy-back is deferred to test-time with no specified mechanism.
4. **Finding 6** — `node.exe` patch fragility across Cursor auto-updates can halt all worker runs with no pre-flight warning.

The document **passes** the Feature Specification Standard. The findings above are architectural stress-test results, not standard-compliance failures.
