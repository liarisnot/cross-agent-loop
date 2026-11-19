<!-- persona: inventive_catalyst | agent: cursor | model: glm-5.2-high -->
# Inventive Catalyst Goldfish — REVIEW of `docs/designs/sandbox-env.md`

## Preamble

I read the target document and the four Goldfish context files (`worker-sandbox.md`, `delegate` SKILL.md, `delegate.ps1`, `Sandbox.psm1`) plus `feature.ps1`'s `Invoke-DoctorFeature` and `stages/build.md`. A genuine technical contradiction exists in the document; the architecture is not balanced as written. Findings below.

---

## Finding 1 — Major

**Affected Scope:** "Grants" bullet (Components) and the "Grant `.envs` per run, like other read-list entries" alternative.

**False Compromise:** The document justifies a *lasting* read grant on `<repo>.xagent\.envs` for both slot identities by claiming "`icacls` rewrites every file below the folder on each grant and each removal," and that a CUDA `torch` environment has "tens of thousands of files," so per-run grants are unaffordable. It then accepts, as the cost of that lasting grant, that "a worker for one repo could read another repo's `.envs`."

This rationale contradicts the parent design's own proven mechanism. `worker-sandbox.md` ("How grants are applied") and `Sandbox.psm1` (`Remove-SandboxGrants`, `New-SandboxRun`) grant the *worktree* with `(OI)(CI)M` **without `/T`** precisely so that `icacls` does *not* walk every file: NTFS inheritance propagates the inheritable ACE to new children, and removing the parent entry removes the inherited copies. The as-built note in `worker-sandbox.md` says the real cost is "rewrite whole access lists" on the *folder's* DACL (one object), serialized by `Local\xagent-acl` — not a per-file rewrite. A large worktree (with `node_modules`, tens of thousands of files) is already granted this way on every run, and the parent design treats that as a 5-second budget item. The sandbox-env document's "rewrites every file" premise is the same problem the parent already solved for worktrees.

The cross-repo leak is therefore accepted against a cost model that the parent design's implementation contradicts. It is also a direct erosion of `worker-sandbox.md`'s G1 ("Files outside the worktree are out of reach"): once repo A's `.envs` is granted to slot S's SID, *any* process in slot S — including a worker for repo B — can read repo A's `.envs` for the lifetime of that grant, which the design itself says is only undone by an explicit `-SandboxCheck -Release`. The dismissal "third-party package files only" is unexamined: package trees carry `direct_url.json` (private index URLs), `.pth` files, `entry_points.txt`, and any code/data a compromised or malicious wheel planted there.

**Proposed Resolution:** **Segmentation + Intermediary.** Grant per *environment folder* (one `<repo>.xagent\.envs\py3.12-<hash>`, not the whole `.envs` tree), per run, only for the environments actually linked into this worktree, using the same `(OI)(CI)RX`-without-`/T` mechanism the parent already uses for worktrees. This (a) eliminates the cross-repo read path, because repo B's worker is never granted repo A's environment folders; (b) keeps the per-run grant lifecycle that `worker-sandbox.md`'s ledger/crash-recovery model already assumes; and (c) makes the cost proportional to this run's projects, not to every environment ever built on the machine. Keep Probe P2, but reframe it to measure the *no-`/T` inheritable* grant on a single environment folder — the same shape the parent already measured for worktrees — rather than the strawman "rewrite every file" model the document currently argues against.

**Secondary Liabilities:** Per-run grants on N environment folders add N `icacls` calls (each holding `Local\xagent-acl`) to setup and teardown; if a repo has many projects this serializes behind the same machine-wide lock the parent uses for the worktree grant, adding latency before the agent starts. A junction target whose DACL is mid-edit by another run's teardown can also produce a transient access-denied during linking; the linker should treat a grant-still-propagating failure as retryable, not as `sandboxNotes`.

---

## Finding 2 — Major

**Affected Scope:** "Open Questions" (Disk) and the prune rule in "Rules" / "Detailed Implementation Plan."

**False Compromise:** The document states "one environment per project with CUDA `torch` costs several gigabytes, copied, not hard-linked … there is no cap," and the prune rule is purely *time-based* (delete when `lastLinked` is older than 14 days or null). The architecture accepts unbounded disk growth as the price of "never ask the user twice." This is a false compromise between "no per-rebuild prompts" (G2/G5) and "the machine stays usable" — those two parameters are not actually in conflict; a disk budget reconciles them.

A user with many CUDA-torch repos (the document's own motivating example is exactly such a repo) accumulates one multi-GB environment per project per repo, and nothing notices until the disk fills; the proposal only "states the estimate" per build. The 14-day clock also does not start until `lastLinked` is updated, so an idle branch with an old lockfile keeps its environment indefinitely even when disk is full.

**Proposed Resolution:** **Dynamics.** Make the prune rule *disk-pressure-driven*, not purely time-driven: track total `.envs` bytes in `envs.json`, and when a new build's estimate would exceed a configurable ceiling (defaulting to, say, 20 GB or a fraction of free space), evict least-recently-`lastLinked` environments first (regardless of the 14-day floor), reporting each eviction in the one-line rebuild notice. The 14-day floor becomes the *grace* period below which nothing is evicted unless the ceiling is hit. This keeps G2 (no per-rebuild prompt) while bounding disk, and it converts the current "silent unbounded consumption" into "bounded, with a visible eviction log line."

**Secondary Liabilities:** A disk ceiling introduces a new failure mode: a build that needs more space than the ceiling allows after eviction (a single env larger than the budget). The proposal must then either ask once (a genuine scope/cost escalation, which the design already routes to the user) or fail with a named `sandbox:`-style error. The eviction order also must never delete an environment a live worktree currently links, which means the linker's `lastLinked` write and the evictor's read must share a lock on `envs.json` (see Finding 4).

---

## Finding 3 — Major

**Affected Scope:** "Non-Goals" ("Dependency management … does not write lockfiles") versus "Decisions so far" D3 copy path and "Build (copy)" in Rules.

**False Compromise:** The Non-Goals say the skill "installs what a project already declares … does not resolve, pin or upgrade dependencies." But the D3 *copy path* — for a project with no `uv.lock` but a `.venv` in the checkout — reconstructs an environment by copying `site-packages` file-by-file onto a copied interpreter, regenerating entry points from `dist-info\entry_points.txt`, and rewriting editable `.pth`/`direct_url.json` paths. That path does not "install what a project declares"; the project declared nothing (no lockfile). It reverse-engineers a declared environment from the user's `.venv`, which is the very thing the rejected alternative "Read the packages installed in the user's `.venv` and reinstall them" was refused for ("the installed list doesn't record which index each package came from"). The copy path is that rejected alternative with the index problem sidestepped by copying bytes instead of resolving — at the cost of substantial custom fix-up code whose size is itself an open question (P4, "the one-task limit").

The contradiction is between "v1 is Python-only and minimal" (Non-Goals, and the lock-first design) and "v1 must also support the no-lockfile copy path." The first real repo cited uses lockfiles. The copy path is speculative generalization that the design's own Non-Goals say is out of scope, and it carries the most fragile code in the whole feature (path rewriting, entry-point regeneration).

**Proposed Resolution:** **Extraction / Taking Out.** Ship v1 with the *lock path only*; for a project with no `uv.lock`, report `unsupported (no-lock)` and stop at a proposal that says "commit a `uv.lock` (run `uv lock`) and retry." Defer the entire copy path — the `kind: "copy"` arm of `envs.json`, the `Build (copy)` rule, P4, and the copy-path fixtures/tests — to a follow-up that is justified by a real repo that needs it. This removes the most fragile subsystem from v1, shrinks `SandboxEnv.psm1` materially, and makes the Non-Goals true. The fallback the design already names ("install from `requirements.txt` or `pyproject.toml`") can stay as the v2 candidate, evaluated against a real caller rather than a probe.

**Secondary Liabilities:** A real caller with a no-lockfile project now gets a stop-and-commit-a-lockfile instead of an automatic setup, which is a worse UX for that case. If such a caller exists and matters, that is the evidence that should re-introduce the copy path; until then it is ungrounded complexity. The `unsupported (no-lock-no-venv)` and `unsupported (python-version-unknown)` statuses remain, so the report still explains the situation plainly.

---

## Finding 4 — Nit

**Affected Scope:** "Data" (`envs.json`), "Build," "Prune," "Linking," and the `SandboxEnv.psm1` exported functions list.

**False Compromise:** The document says `envs.json` is "written only by `SandboxEnv.psm1`," but two leads can run `-SandboxEnv -Apply` at once (the `feature` skill caps at two concurrent sandboxed runs, and a `delegate`-only lead plus a `feature` lead is explicitly possible per G5). Nothing in the design serializes `envs.json` reads/writes, environment folder creation, or the prune step. The parent design serializes *ACL* edits with `Local\xagent-acl`, but `envs.json` and the `.envs` folder tree are a separate shared resource not covered by that lock. The architecture treats "one writer" as a sufficient invariant when there are demonstrably two concurrent writers possible.

**Proposed Resolution:** **Intermediary.** Hold a named mutex `Local\xagent-envs-<repo>` around every `envs.json` read-modify-write and around the prune step, mirroring the parent's `Local\xagent-acl` pattern. Linking (per-run, read-only on `envs.json` plus a `lastLinked` update) can take the same lock briefly. This is a small addition to `SandboxEnv.psm1` and removes a class of "two `-Apply` runs raced and one environment was deleted under a live worktree" failures that would otherwise show up as `sandboxNotes` or a missing `.venv` mid-run.

**Secondary Liabilities:** One more named mutex to name, acquire with `AbandonedMutexException` handling (the parent already has the `Open-SandboxSlotMutex` pattern to copy), and a potential 120 s wait if a prior `-Apply` hung. A hung writer should surface as a named `sandbox:`-style error, not a silent stall.

---

## Finding 5 — Nit

**Affected Scope:** "Every sandboxed run" — `UV_CACHE_DIR` inside the run's own home.

**False Compromise:** Each run's `UV_CACHE_DIR` is set to `<slot>:\.xagent\sandbox\uv-cache`, which is per-worktree and starts empty. The contradiction is between "the environment is read-only and never changes" (good) and "every `uv run` pays a cold-cache metadata resolution." The design accepts a cold cache per run to keep writes inside the run home. But `uv run` against a frozen, already-built environment still consults the cache for wheel metadata; a cold cache means re-fetching metadata (and, for the copy path, re-reading dist-info) on every run.

**Proposed Resolution:** **Preliminary Action.** Point `UV_CACHE_DIR` at a shared, read-only cache under `<repo>.xagent\.envs\uv-cache` (populated at build time by the `uv sync`/`uv python install` that already runs), and set `UV_NO_SYNC=1` + `UV_FROZEN=1` (already present) so `uv run` never writes to it. Workers get a warm metadata cache without any per-run write path. If a worker ever needs to write to the cache (it should not, given the frozen flags), the resulting access error is itself the correct signal that something tried to mutate the environment.

**Secondary Liabilities:** A shared cache is one more thing to prune (it should be covered by the same disk-ceiling rule from Finding 2), and a cache miss for a wheel not present at build time would currently be a network fetch the sandbox allows (network is on) — confirm that is intended, or set `UV_PYTHON_DOWNLOADS=never` (already set) plus an offline flag for the run path.

---

## Summary

The document's foundational architecture is inventive and largely sound: detect-before-run (G1), one-approval-per-repo (G2/D5), per-environment naming by lockfile hash (D1), and the junction-link approach (D4) are well-reasoned, and the alternatives section is genuinely evaluative. The two findings that rise above advisory are **Finding 1** (the lasting-grant rationale contradicts the parent's own proven grant mechanism and erodes G1) and **Finding 3** (the copy path contradicts the document's own Non-Goals and carries the feature's most fragile code for a caller that may not exist in v1). **Finding 2** (no disk cap) is a latent operational hazard that the design itself flags as an open question but treats as settled. Findings 4 and 5 are advisory.

No contradiction was manufactured where none exists; the lock-path core, the probe-first methodology, and the alternatives evaluation are not in dispute.
