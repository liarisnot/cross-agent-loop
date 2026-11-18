<!-- persona: inventive_catalyst | agent: cursor | model: glm-5.2-high -->
# Inventive Catalyst Review — `sandbox-env` design (Stage 5 re-check)

I read the target document (`docs/designs/sandbox-env.md`), the prior round's resolutions (`docs/features/sandbox-env/reviews/design-1.md`), and the surrounding sandbox code (`Sandbox.psm1`, `delegate.ps1`, `feature.ps1` doctor, `delegate/SKILL.md`, `stages/build.md`, `worker-sandbox.md`). The prior round's resolutions (per-run grants D6, dropping the no-lockfile copy path, the `XAGENT_WORKTREE` `.pth` rewrite, the `linked` stamp file, `uv-missing` report) all hold in the current text. Below are the new false compromises I found that the doc accepts as laws but are not.

---

## Finding 1 — Major

**Affected Scope:** Goals G2 / G6 and Decision D5 ("ask once per repo, then rebuilds run without asking").

**False Compromise:** The design treats "first-setup approval" and "rebuild approval" as the same thing. They are not. G2 says the user approves the disk/time cost of the first setup once; afterwards, "rebuilds for a changed lockfile run without asking and are reported in one line." But a lockfile change can add dependencies on the order of gigabytes (the design's own motivating example is a CUDA `torch` of "several gigabytes"). The cost the user approved at first setup is therefore not the cost incurred by later rebuilds, and the design's dismissal of a disk ceiling (review finding 5, "14-day prune + show total size of `.envs`") only bounds *staleness*, not *growth* — the size shown is reported *after* the rebuild, not before. The accepted "law" is: "fast flow requires forfeiting per-rebuild cost consent." That is a real contradiction between flow speed (D5) and user cost autonomy (G2's "nothing is created until the user says yes"), and the doc resolves it by silently extending a one-time yes to every future rebuild.

**Proposed Resolution:** **Beforehand Cushioning** — keep the one-approval default for the *first* build and for rebuilds whose estimated delta is below a threshold, but treat a rebuild whose wheel-size estimate (the same `uv.lock` wheel sizes already used for the first proposal) exceeds a stated delta (e.g., +1 GB or +20% over the last approved total) as a *new proposal* that stops and asks once, the same way the first setup does. The estimate is already computed for free from `uv.lock`; reuse it as the cushion trigger. This dissolves the contradiction: small rebuilds keep the no-ask flow, large rebuilds restore the consent gate the user actually granted.

**Secondary Liabilities:** A second question to the user on large rebuilds (rare, but it stalls the run); a threshold constant that must be set in the build task and tested; a rebuild that grows by exactly the threshold is a boundary condition the tests must pin.

---

## Finding 2 — Major

**Affected Scope:** Decision D1 ("Environments live per repo in `<repo>.xagent\.envs\`") and the Alternatives section "One root shared by all repos" / "`%LOCALAPPDATA%\xagent\envs\`".

**False Compromise:** The doc asserts that sharing a root across repos "saves almost nothing: lockfiles rarely match, and `uv`'s cache is on another drive, so packages are copied either way," and rejects the `LOCALAPPDATA` location solely because it is "inside the folder the read list refuses." The accepted "law" is: "sandbox-safety (no grants under the profile) requires forfeiting all cross-repo sharing of environment bytes." That conflates two independent axes: *where the grant ledger refuses to read* and *where bytes can be hard-linked*. A `LOCALAPPDATA` location is refused only because `Resolve-SandboxReadEntry` puts `AppData\Roaming` and the sandbox's own `<Root>` on the refuse list — but `<Root>` is `%LOCALAPPDATA%\xagent`, not `%LOCALAPPDATA%\xagent\envs` specifically, and the refuse check is a path-prefix test, not a property of the filesystem. The contradiction (disk duplication vs. grant-safety) is resolvable because the grant surface is determined by *which paths the per-run grant list names*, not by *where the bytes physically live*. The design already proves this: D6 grants environments per run regardless of where they sit. So a shared root outside the refused prefixes is achievable, and the "saves almost nothing" claim is asserted, not measured — no probe measures hard-link reuse across repos on the same drive as `uv`'s cache.

**Proposed Resolution:** **Segmentation** with a shared *content store* and per-repo *links*. Place environment contents under a single non-refused root (e.g. `<Root>\envs\`, which is already under the sandbox's own folder and is refused for *read-list* entries but is not refused for *per-run grant rows* — D6 grants `.envs\bin` today without going through `Resolve-SandboxReadEntry`). Per-repo `.envs` becomes a directory of junctions/hardlinks into the shared store, keyed by the existing content hash. Environments with identical lockfiles collapse to one set of bytes; per-run grants still name the per-repo junction paths, so isolation is unchanged. The 14-day prune now operates on the shared store with reference counts from per-repo links.

**Secondary Liabilities:** A second location to manage and prune; reference-counting across repo junctions is more failure-prone than per-repo deletion (a crashed run leaves a dangling link); hardlinks across drives do not work, so a repo on a different drive from the store still copies (the design's "packages are copied either way" caveat returns for that case); the grant path seen by the container is the per-repo junction, so a tool that resolves the junction to its real target and then tries to read a sibling outside its grant will be denied — same failure mode D7 already handles for `uv run`, but it now applies to more paths.

---

## Finding 3 — Major

**Affected Scope:** "Components — `delegate.ps1 -SandboxRun`" and G5 ("before the build starts, `feature` runs each phase's test command once in the sandbox").

**False Compromise:** `-SandboxRun` is documented as a full sandboxed run: it "Creates a detached worktree, links the environments, runs the command in a sandbox slot with the same grants and `PATH` a worker gets... It takes one of the two slots, like any run." The accepted "law" is: "validating a phase test command requires the same isolation and slot cost as a real worker." But a *test command probe* and a *worker run* have different trust profiles: the probe runs a command the lead already trusts (the phase's declared `test`), for seconds, with no agent. It does not need a Cursor allowance, a run home, a copied login, or a job object that kills a Cursor process tree. Coupling the probe to the full `New-SandboxRun` path means the probe competes with workers for the two slots, inherits the ~5 s setup cost per phase per run, and — most importantly — inherits the failure mode where a missing/stale environment is *not* a probe failure but a `sandboxNotes` line, so a phase test can be reported as `ok` while silently running against a missing `.venv`. The contradiction is "probe fidelity vs. probe cost," and the doc resolves it by paying full worker cost for every probe and still getting a weaker signal than a worker.

**Proposed Resolution:** **Extraction / Taking Out** — extract the probe into its own lightweight path (`Invoke-SandboxCommand`, which the Files table already lists as new in `Sandbox.psm1`) that does *not* go through `New-SandboxRun`: it takes a slot, grants only the worktree + linked environments + `.envs\bin`, runs `pwsh -NoProfile -Command <cmd>`, and returns `exitCode`/output/`diagnosis`. Crucially, a missing or stale environment for the project whose test command is being probed must be a *probe failure* (`module-missing` or `environment-missing`), not a `sandboxNotes` line — the probe's purpose is to catch exactly that. The worker path keeps `New-SandboxRun` with its login copy and job object; the probe path does not.

**Secondary Liabilities:** A second run path to test and keep in sync with the grant ledger; the probe must still unlink junctions before worktree removal (P5), so the cleanup code is shared, not duplicated; a probe that fails on a missing environment now stops the build before any worker, which is the intended behaviour but is a behaviour change from the doc's current "missing environment doesn't stop the run."

---

## Finding 4 — Nit

**Affected Scope:** "What a project is" + "Build (`resolve`)" rule + Non-Goal "Dependency management."

**False Compromise:** For a `resolve` project, the doc says "copy it (and only it) into `.envs\work\<name>`, `uv lock` there." The accepted "law" is: "a fresh resolve is the only automatic answer that doesn't guess where installed packages came from." But `pyproject.toml` frequently declares custom indexes via `[tool.uv.index]` and `[tool.uv.sources]`, and a project may also have a sibling `uv.toml` or workspace-level config. Copying *only* `pyproject.toml` silently drops any index/source config not in that one file, so the fresh resolve can pull from the wrong index (e.g. plain PyPI instead of PyTorch's CUDA index) and produce an environment that imports fine but runs on the wrong `torch` backend. The contradiction is "don't guess the user's installed set" vs. "guess the user's index config," and the doc only resolves the first half.

**Proposed Resolution:** **Preliminary Action** — before the resolve build, copy the full set of `uv`-config files the project declares (the project's `pyproject.toml` plus any `uv.toml` in the project folder or repo root, and the workspace-root `pyproject.toml` for a workspace), not just `pyproject.toml`. The build task should enumerate the exact set copied and the tests should fixture a project whose index lives in `uv.toml` to prove the index is preserved. This is a small widening of the existing copy step, not a new component.

**Secondary Liabilities:** More files to find and copy (and to clean up in `.envs\work\<name>`); a workspace-root `pyproject.toml` may declare indexes for subprojects the resolve project does not use, so `uv lock` may resolve extra sources (harmless but slower); the test fixture set grows.

---

## Finding 5 — Nit

**Affected Scope:** "Components — `SandboxEnv.psm1`" and the `uv` copy rule ("The host's `uv` is found with `Get-Command uv` and copied into `.envs\bin` when the build runs").

**False Compromise:** The pinned `uv.exe` copy is never refreshed after the first build, so a worker on a months-old environment runs a months-old `uv` against a current `uv.lock` format. The accepted "law" is: "reproducibility requires a pinned `uv`." But reproducibility only requires pinning *at build time*; it does not require the copy to *stay* pinned across rebuilds. The contradiction is "reproducible builds vs. `uv`/lock-format drift," and the doc resolves it by never refreshing the copy, which means a `uv.lock` produced by a newer host `uv` (with a schema the old copy can't parse) fails the rebuild with an opaque `uv` error instead of a proposal.

**Proposed Resolution:** **Self-Service** — at each `-Apply`, re-copy the host's `uv.exe` into `.envs\bin` (overwriting) and record its version in `envs.json` (`"uv": "<path>"` already exists; add `"uvVersion"`). If the host's `uv` is older than the one recorded, keep the newer copy and note it. This keeps builds reproducible per-run (the copy used for one `uv sync` is one binary) while preventing drift across rebuilds.

**Secondary Liabilities:** A rebuild silently changes the `uv` binary, which could change `uv sync` behaviour for an otherwise-unchanged lockfile (rare, but it weakers bit-for-bit reproducibility across rebuilds); one more field in `envs.json` to version and test.

---

## Summary

The prior round's resolutions hold. The remaining false compromises are: (1) the one-approval model silently extends to unbounded rebuild costs; (2) per-repo environment duplication is presented as unavoidable when the refuse-list reason only blocks one specific shared location; (3) the probe is coupled to the full worker run path, paying worker cost for a sub-second check and reporting a missing environment as non-fatal; plus two nits around `resolve`-project index config and `uv.exe` drift. None of these require abandoning the architecture; each is resolvable with a named pattern whose secondary cost I've stated above.
