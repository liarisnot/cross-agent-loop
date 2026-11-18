<!-- persona: design_critic | agent: cursor | model: glm-5.2-high -->
I have enough context. Here is the full review report.

---

# Design Critic Review — `docs/designs/sandbox-env.md` (Stage 7: structure and style, full document)

Mode: REVIEW. Target standard: Feature Specification Standard. Read-only audit; no files were modified.

The document is well-organized and unusually concrete for a design (named envs, hash scheme, grant spec, probe results). Against the standard, however, it has one structural gap that borders on a Blocker, a recurring attribution pattern that violates the Alternatives Rule, and several unmitigated risks and unbacked assumptions that the standard explicitly requires.

---

## Findings

### 1. Blocker — Missing dedicated "Risks & Mitigations" section
- **Severity:** Blocker (standard compliance gap; downgrade to Major if the orchestrator treats the Probes/Verification scatter as sufficient).
- **Affected Scope:** Whole document; the standard's "Risks & Limits" requirement and the "Risks & Mitigations" example item.
- **Finding & Recommendation:** The Feature Specification Standard requires the spec to "explicitly call out its own constraints … potential failure modes, security implications, scalability limits, and how they will be mitigated," and lists "Risks & Mitigations" as a required area. `sandbox-env.md` has Overview / Problem / Goals / Non-Goals / Open Questions / Technical Plan / Alternatives / Implementation Plan / Verification, but **no Risks & Mitigations section**. Risks are scattered across the Decisions "Why" column, the Probes table (P3, P5), and the Verification live-checks, and several are never mitigated at all (see findings 5–10). Contrast with the sibling design `docs/designs/worker-sandbox.md`, which has an explicit Risks & Mitigations table. Add a dedicated section that enumerates at least: disk pressure / unbounded `.envs` growth; concurrent `-Apply` and prune races; per-repo interpreter duplication; `uv` version skew between host and copied `uv.exe`; slot contention between `-SandboxRun` probes and workers; secrets in tracked `uv.toml` / private indexes; `pip install --user` writing into the run home; hash truncation (48-bit) collision; `.python-version` pinning a full patch version.

### 2. Major — Alternatives rejection rationale names "author" / "review" without linking an issue, discussion, or PR
- **Severity:** Major (Alternatives Rule violation).
- **Affected Scope:** `docs/designs/sandbox-env.md` lines 117–157 (the entire "Alternatives Considered" section).
- **Finding & Recommendation:** The standard: rejection rationales "must not attribute a rejection to a maintainer without linking their issue, discussion, or PR." Every alternative here is closed with "Rejected by author: …" (lines 119, 123, 128, 138, 139, 142, 143, 147, 152) and two with "Rejected after review: …" (lines 139, 152). The technical rationale that follows each is generally concrete (good), but two rejections — "Copy the user's `.venv` … Rejected after review" (line 139) and "A lasting read grant on all of `.envs` … Rejected after review and probe P2" (line 152) — attribute the rejection to a "review" with no link to that review. Drop the "by author / after review" framing and lead with the technical trade-off, or link the review artifact; otherwise the document fails the Alternatives Rule as written.

### 3. Major — Unmitigated disk pressure / unbounded `.envs` growth
- **Severity:** Major.
- **Affected Scope:** Decisions D1, D2 (lines 60–63); "Prune" rule (line 230); G2's 5 GB re-approval (line 33, line 230).
- **Finding & Recommendation:** `.envs` has no cap. The 5 GB re-approval only fires on a *single* build that adds >5 GB; cumulative growth across many projects, many branches (each with a different lockfile hash → a new env folder per D8), and many interpreter versions is unbounded. Pruning only catches environments unused for 14 days, so an active repo with N branches holds N copies of CUDA `torch` (several GB each). The Overview even concedes "disk (no cap; unused environments are pruned after 14 days…)" (line 51) without treating it as a risk. Recommend: a per-repo `.envs` soft cap with a doctor warning, an explicit "prune-on-Apply" guarantee that runs before the build, and a stated worst-case footprint for the motivating private repo (6 projects × N branches × torch).

### 4. Major — Per-repo interpreter duplication across repos
- **Severity:** Major.
- **Affected Scope:** D1, D2 (lines 60–63); "Build (`lock`)" rule (line 230).
- **Finding & Recommendation:** D1 puts `.envs` per repo, and D2 copies every interpreter into `<repo>.xagent\.envs\python\`. The rejected alternative "one root shared by all repos" (line 130) was dismissed on the grounds that "two repos rarely have identical lockfiles, so the saving is close to zero" — but that argument applies to *environments*, not *interpreters*. Ten repos that all use Python 3.12 now hold ten copies of the CPython 3.12 tree. The design never quantifies interpreter size or reuse, and the rejected shared-root alternative explicitly addressed the hard-link-from-`uv`-cache case (line 134). Either justify why per-repo interpreter copies are acceptable (with a measured size), or carve interpreters out of D1 and share them.

### 5. Major — `uv` version skew between host `uv` and the copied `.envs\bin\uv.exe`
- **Severity:** Major.
- **Affected Scope:** "uv itself" rule (line 229); `envs.json` `uvVersion` (line 180); D4 (line 64).
- **Finding & Recommendation:** `.envs\bin\uv.exe` is refreshed only on `-Apply`. Between applies, workers and `-SandboxRun` probes use the stale copy. The design records `uvVersion` in `envs.json` but never checks it before a worker run; a lockfile written by a newer `uv` (new lock format, new resolver) can meet an old `uv.exe` inside the sandbox and fail `uv run` with an opaque error. The Overview even states the rationale ("a lockfile written by a newer `uv` doesn't meet an old copy", line 229) but the mitigation is only "replace on `-Apply`." Recommend: a pre-run `uv --version` check against `envs.json.uvVersion`, with a `sandbox:`-style "uv stale; run -SandboxEnv -Apply" error path, or copy `uv.exe` on every worker run (cheap).

### 6. Major — Slot contention between `-SandboxRun` probes and workers
- **Severity:** Major.
- **Affected Scope:** G1, G5 (lines 32, 36); `-SandboxRun` component (line 91); `stages/build.md` flow (line 108).
- **Finding & Recommendation:** `-SandboxRun` "takes one of the two slots, like any run." Before the build, the lead runs `-SandboxRun` for each phase's test command. If both slots are already held by long workers (from a previous phase, or a parallel `delegate`-only lead), the probe waits up to 60 s and then fails with `no free slot` — a `sandbox:`-style setup error that, per `stages/build.md`, becomes a problem stop. The design does not acknowledge that the pre-build probe can deadlock with the workers it is meant to guard. Recommend: either run probes in a third reserved slot, run them before any worker of that phase starts (sequential, not concurrent with workers), or explicitly state the "no free slot" failure is non-blocking and the build proceeds.

### 7. Major — `git ls-tree` vs `git ls-files` inconsistency for project discovery
- **Severity:** Major (correctness; will affect implementation).
- **Affected Scope:** "What a project is" (line 70) vs "Rules / Projects" (line 224).
- **Finding & Recommendation:** The prose says "Projects are found with `git ls-files`" (line 70), but the Rules section says "From `git -C <repo> ls-tree -r --name-only <ref>`" (line 224). These are different commands: `ls-files` reads the index of the working tree; `ls-tree` reads tracked files at a ref. The whole feature depends on discovering projects *at a ref* (D8: "A run hashes the lockfile in its own worktree"; `-SandboxEnv -Base <ref>`), so `ls-tree` is correct and `ls-files` is wrong as written. Pick one and use it consistently; the test plan should cover discovery at a non-HEAD ref.

### 8. Major — Faulty assumption: `.python-version` always yields major.minor
- **Severity:** Major.
- **Affected Scope:** "What a project is" (line 71); "Interpreter" rule (line 224).
- **Finding & Recommendation:** The rule states "The newest patch release of that minor version is used," and the interpreter rule reads `.python-version` as the first source. `.python-version` files (per `pyenv`/`uv` convention) may pin a full version like `3.12.1`. The design silently treats `.python-version` as major.minor only and ignores any patch pin. A project that intentionally pins `3.12.1` (e.g., a C-extension bug fixed in 3.12.2) will get 3.12.x-latest instead. Recommend: parse `.python-version` as a full version when it has three components, and only fall back to "newest patch of this minor" when it has two.

### 9. Major — Unbacked assertion: "`uv.lock` records wheel sizes"
- **Severity:** Major (faulty assumption about external system).
- **Affected Scope:** `-SandboxEnv` output (line 89); "Estimate" rule (line 229).
- **Finding & Recommendation:** The disk estimate is described as coming "from the wheel sizes `uv.lock` records; nothing is downloaded to estimate it." `uv.lock` records package names, versions, hashes, and source/wheel metadata, but whether it records per-wheel byte sizes is not justified here, and the design's own GoldfishContext note says "`uv` documentation cannot be opened from here." If `uv.lock` does not record sizes, the estimate is unsound and the 5 GB re-approval gate (G2) is built on a number that may be `unknown` for `lock` projects too. Recommend: cite the exact `uv.lock` field the size comes from, or fall back to `uv export --format requirements-txt | uv pip compile --dry-run` style sizing, or label all estimates `unknown` until a probe measures a real build.

### 10. Major — `uv run` inside the sandbox: config and index reachability
- **Severity:** Major.
- **Affected Scope:** D4 (line 64); "Environment variables" rule (line 232); "Inputs" rule (line 230).
- **Finding & Recommendation:** Inside the sandbox, `uv run pytest` is invoked from the worktree, not from `.envs\work\<name>` where `uv.toml` was copied for the build. The design does not say how `uv run` inside the sandbox finds index/source config: the worktree's own `uv.toml` (if tracked) is what `uv` reads, and that file may declare a private index whose token is in `uv.toml` or in `%UV_INDEX_*` env vars. The Non-Goal "No credentials … are copied into the environment" (line 47) does not address credentials that live in *tracked* repo config that the worker can already read. Separately, `UV_NO_SYNC=1` + `UV_FROZEN=1` should stop `uv run` from syncing, but probe P1 only confirmed `uv run pytest` works for a small `numpy`/`pytest` project — it did not exercise a private index or a `[tool.uv.sources]` map. Recommend: state explicitly what `uv run` reads inside the sandbox, and add a probe with the private repo's `pyproject.toml`/`uv.lock` that uses its CUDA index.

### 11. Major — `pip install --user` and other in-home writes bypass the read-only environment
- **Severity:** Major.
- **Affected Scope:** G7 (line 38); "Every worker run and probe" (line 92).
- **Finding & Recommendation:** The design relies on the environment being read-only (`(OI)(CI)RX`) to make `pip install` / `uv add` fail. But `USERPROFILE`/`HOME` inside the sandbox point at `<slot>:\.xagent\sandbox\home` (verified in `Sandbox.psm1` `Get-SandboxEnvironment`, lines 800–803), which is granted `(OI)(CI)M`. A worker that runs `pip install --user <pkg>` or `uv tool install <pkg>` writes into the run home, polluting it for that run (and, since the run home is kept until `-Cleanup`, for any `-Resume`). The Verification step "pip install inside a sandboxed run fails with an access error" (line 270) only tests the default `pip install`. Recommend: set `PIP_USER=0`, `uv`'s `--no-tools` equivalent, or explicitly disable `--user` in the environment, and add a verification case for `pip install --user`.

### 12. Major — Prune race with concurrent linking
- **Severity:** Major.
- **Affected Scope:** "Prune" rule (line 230); "Linking" rule (line 231).
- **Finding & Recommendation:** Prune deletes an environment when "no existing worktree holds a junction to it." Linking creates a junction "if `<worktree>\<project>\.venv` does not exist." These run on different processes (prune on `-Apply`, linking on a worker launch) with no shared lock described for the *environment folder* (the `envs.json` named lock covers writes to `envs.json`, not environment deletion). A worker launch that has just decided its hash maps to env X can race a prune that has just decided no worktree points at X and deletes X. The junction then points at a deleted target. Recommend: hold the `envs.json` lock around prune too, or have linking touch the `linked` stamp *before* checking existence and have prune re-check the stamp under the lock.

### 13. Major — Hash truncation to 12 hex (48 bits) with no collision analysis
- **Severity:** Major.
- **Affected Scope:** D1 (line 60); "Environment name" (line 220); "Hash" (line 182).
- **Finding & Recommendation:** Env folder names use the first 12 hex of a SHA-256 (48 bits). With a birthday bound around ~16 million environments per repo, collision is unlikely for one repo, but the design gives no analysis and a collision would silently link two different lockfiles to the same environment — a correctness bug that passes `ready` and only surfaces as test failures. Recommend: state the collision probability explicitly, or use the full hash for the folder name (filesystems handle 64-char names fine) and keep the 12-hex form only for display.

### 14. Major — `envs.json` write lock is named but not specified
- **Severity:** Major (under-specified interface).
- **Affected Scope:** `envs.json` (line 170); D5/D6.
- **Finding & Recommendation:** "Written only by `-SandboxEnv -Apply`, under a named lock" — the lock name, scope (machine-wide vs per-repo), and behavior on abandonment are not specified. `worker-sandbox`'s ACL lock is `Local\xagent-acl` (machine-wide, abandoned-mutex-safe). If `envs.json`'s lock is per-repo, two leads on the same machine editing two repos don't contend (good); if it's machine-wide, every repo's `-Apply` serializes (bad). Specify the name and the abandoned-mutex handling, mirroring the existing pattern in `Sandbox.psm1`.

### 15. Nit — "Open Questions" settles items in prose, blurring what is still open
- **Severity:** Nit (structure and style, per Stage 7).
- **Affected Scope:** "Open Questions" (line 49–51).
- **Finding & Recommendation:** The section lists one open question (GPU) and then a "Settled since the first draft" paragraph that re-opens and re-closes three more. A reader scanning for open items cannot tell what is still undecided. Split into "Open" and "Settled" subsections.

### 16. Nit — Verification step 7 underspecifies the "older lockfile" branch
- **Severity:** Nit.
- **Affected Scope:** Verification, item 7 (line 272).
- **Finding & Recommendation:** "A worktree on a commit with an older lockfile links the older environment" — the test setup (which commit, how old, whether the older env must already exist) is not pinned down. Given D8's importance, name the exact scenario: an env built for lockfile hash A, then a worktree at a commit whose lockfile is A, while `feature/<name>` has moved to hash B.

### 17. Nit — `doctor -Repo` change not reflected in existing doctor flow
- **Severity:** Nit.
- **Affected Scope:** Files table, `skills/feature/SKILL.md` row (line 257); `feature.ps1` doctor code (verified at line 2982, currently takes no `-Repo`).
- **Finding & Recommendation:** The design's claim "It currently says doctor passes neither" (line 257) is accurate (`skills/feature/SKILL.md` line 32: "`doctor` passes neither `-Repo` nor `-Name`"). The change is consistent. But `Invoke-DoctorFeature` (line 2982) currently builds checks unconditionally with no `-Repo` parameter; the design's Files row says "doctor takes an optional `-Repo`" without specifying how the new `sandbox-env` non-required check behaves when `-Repo` is omitted (skip vs. run against cwd). Specify the omitted-`-Repo` behavior.

### 18. Nit — "where.exe does not find it" (probe P1) is unexplained
- **Severity:** Nit.
- **Affected Scope:**Continuing from finding 18.

### 18. Nit — "where.exe does not find it" (probe P1) is unexplained
- **Severity:** Nit.
- **Affected Scope:** Probes table, P1 (line 161).
- **Finding & Recommendation:** P1 reports `uv` is found via `Get-Command` but "`where.exe` does not find it." This is a real Windows behavior difference (`where.exe` searches `PATH` with `.PATHEXT` and a specific resolution order; `Get-Command` in PowerShell also searches `PATHEXT` but can resolve via the PowerShell function/alias layer), but the design does not say which one workers actually invoke. A worker that shells out to `where uv` will fail to find it. Recommend: state whether `.envs\bin\uv.exe` is found by `where.exe` (and if not, why) and whether that matters for any tool the worker runs.

### 19. Nit — `Get-SandboxEnvironment` extension point not shown in current code
- **Severity:** Nit.
- **Affected Scope:** Components, "Every worker run and probe" (line 92); `Sandbox.psm1` `Get-SandboxEnvironment` (verified at lines 770–808, currently takes only `-Slot` and `-ReadList`).
- **Finding & Recommendation:** The design states "`Get-SandboxEnvironment` takes extra variables and a `PATH` suffix from its caller." The current function signature (line 770) takes only `-Slot` and `-ReadList` and builds `PATH` internally from the read list. The extension is plausible but the design does not specify the new parameter shape (`-ExtraVars`, `-PathSuffix`?) or how `XAGENT_WORKTREE` and the `UV_*` variables are passed without leaking into non-Python runs. Specify the new signature so the `Sandbox.psm1` change is reviewable.

### 20. Nit — Verification step 5 ("pip install fails") overlaps with finding 11
- **Severity:** Nit.
- **Affected Scope:** Verification, item 5 (line 270).
- **Finding & Recommendation:** The live check only covers default `pip install`. Per finding 11, add `pip install --user` and `uv tool install` cases, or state that in-home writes are accepted.

---

## Summary against the standard

- **Problem Statement:** present (lines 14–22).
- **Goals & Non-Goals:** present, clear (lines 24–47).
- **Proposed Architecture:** present and concrete (Decisions, Components, Flow, Rules, Files).
- **Alternatives Considered:** present and broad, but fails the attribution rule (finding 2).
- **Risks & Mitigations:** **absent as a section**; risks are scattered and several are unmitigated (findings 1, 3–6, 10–12). This is the primary standard-compliance failure.

The document's structural style is otherwise strong: a Decisions table with explicit IDs that the rest of the document references, a Probes table that records failures as well as passes, a Files table that ties each change to a goal, and a Verification section with live checks. The gaps are content gaps under the standard, not presentation gaps.

**Recommendation to the orchestrator:** Block until a Risks & Mitigations section is added (finding 1) and the alternatives attribution is fixed (finding 2); the remaining Major findings (3–14) should be addressed in the same revision but can be tracked as follow-ups if the design is otherwise approved.
