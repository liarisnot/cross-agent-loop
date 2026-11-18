<!-- persona: style | agent: cursor | model: glm-5.2-high -->
# Style Goldfish Review — `docs/designs/sandbox-env.md` (lines 1–273)

**Mode:** REVIEW · **Stage:** 7 (critic, structure and style) · **Scope:** full document

I read the target document and the cited context files (`worker-sandbox.md`, `Sandbox.psm1`, `delegate.ps1`). Findings are ordered by location. Severity scale: Blocker / Major / Nit. Caveat findings carry a recommended editorial action (`DROP` / `CALIBRATE` / `RELOCATE`).

---

## Findings

### 1. Major — Overview, line 13 ("the skill detects, asks once, then does the work")
**Style rationale:** "does the work" is a vague verb phrase that obscures what the skill actually does (builds an environment and grants it). The rest of the document is precise about the action; this summary line should match. Recommend tightening to name the action, e.g. "detects, asks once, then builds and links the environment."

### 2. Major — Goals / G1, line 30 ("It takes seconds")
**Style rationale:** "It takes seconds" is an uncalibrated performance claim with no bound and no evidence pointer. The document elsewhere cites probe P2 for measured timings ("about 3 seconds each"). G1's "It takes seconds" outruns that evidence (P2 measures grant/remove, not the probe). **CALIBRATE** — either cite the probe that measured the probe's runtime, or replace with "fast relative to a worker run" and drop the numeric framing.

### 3. Nit — Goals / G7, line 36 ("is ever granted")
**Style rationale:** "Nothing under the profile root … is ever granted" is an absolute that the Verification section does not directly test for the new environment path. As design intent it reads cleanly, but the word "ever" adds emphasis without evidence. **CALIBRATE** to "is not granted by this feature" or **KEEP** if you intend it as a design rule, not a tested claim — pick one reading so the reader knows which.

### 4. Major — Decisions / D1 "Why", line 61 ("lockfiles rarely match")
**Style rationale:** "Sharing one root across repos saves almost nothing: lockfiles rarely match" is a probabilistic claim with no evidence. It is the author's rationale for a rejected alternative, but "rarely match" is presented as fact. **CALIBRATE** — restate as the design choice ("the design assumes lockfiles differ between repos") or supply the comparison that established it.

### 5. Nit — Decisions / D3 "Why", line 63 ("the only automatic answer")
**Style rationale:** "a fresh resolve is the only automatic answer that doesn't guess" is a mild superlative. Defensible as design-space reasoning, but "the only" adds emphasis the surrounding text does not need. Soften to "a fresh resolve is the automatic answer that doesn't guess" without loss.

### 6. Major — Decisions / D4 "Why", line 65 ("work unchanged")
**Style rationale:** "`.venv\Scripts\python -m pytest`, `uv run pytest` and the repo's own instructions work unchanged." Probe P1 verifies `import numpy` and `uv run pytest` for one scratch repo. "the repo's own instructions work unchanged" generalizes beyond what P1 measured. **CALIBRATE** — narrow to what P1 confirmed, or move "the repo's own instructions" to the Verification list as a live check (it is partly covered by Verification step 2/3, but not stated as "unchanged").

### 7. Nit — Decisions / D5, line 65 ("wherever one answer is defensible")
**Style rationale:** "defensible" is a judgment word with no test. The rule is operationalized later ("asked once per repo"), so the qualifier adds nothing measurable. Recommend "wherever one rule covers every case" (matching D2's phrasing) for consistency and precision.

### 8. Major — "What a project is" vs "Rules", lines 72 and 226 (command inconsistency)
**Style rationale (precision):** Line 72 says projects are "found with `git ls-files`"; line 226 says "From `git -C <repo> ls-tree -r --name-only <ref>`". These are different git commands (`ls-files` reads the index/working tree; `ls-tree` reads a ref). A fresh reader cannot tell which is authoritative. Reconcile to one command, and use the same phrasing in both sections.

### 9. Nit — "What a project is" vs "Rules", lines 73 and 227 (interpreter rule precision)
**Style rationale:** Line 73 states the interpreter order as "`.python-version` in the project folder or above it; `requires-python` …; the `version_info` …". Line 227 states the same rule more precisely ("the nearest folder above it inside the repo", "taking the lowest version it allows that `uv python list` offers", "major.minor only"). The earlier statement under-specifies what the later one commits to. Tighten line 73 to match, or mark it as a summary that the Rules section refines.

### 10. Nit — Components, line 93 ("It takes one of the two slots, like any run")
**Style rationale:** "like any run" is filler — the reader already knows sandboxed runs take a slot. Drop it; "It takes one of the two slots." is tighter.

### 11. Major — Components / "Every worker run and probe", line 94 ("a worker that tries `pip install` or `uv add` gets an access error")
**Style rationale:** This is a tested-behavior claim ("gets an access error"). P1 verifies `uv pip install` fails with "Access is denied"; `uv add` is not separately tested. **CALIBRATE** — either drop "`uv add`" or add it to the Verification list (step 5 covers `pip install` only).

### 12. Nit — Components / "feature.ps1 doctor", line 95 ("adds the `-SandboxEnv` summary")
**Style rationale:** "summary" is vague next to the precise JSON shape defined later. Minor; the Files table and Rules make it concrete, so this is a Nit for terseness, not accuracy.

### 13. Major — Flow on first use, line 99 ("about 9 GB")
**Style rationale:** The estimate "about 9 GB" in the example flow has no derivation, while the Rules section (line 231) defines how estimates are computed. A reader of the flow alone cannot tell whether 9 GB is illustrative or measured. **CALIBRATE** — label it as illustrative ("e.g., about 9 GB") or footnote the estimate rule it follows.

### 14. Nit — Alternatives / "Where the environments live (D1)", line 131 ("the saving is close to zero")
**Style rationale:** "the saving is close to zero" restates the D1 "saves almost nothing" claim in different words. Synonym-adjacent repetition across two sections. Pick one phrasing and reference it, rather than re-asserting.

### 15. Major — Alternatives / "Where interpreters come from (D2)", line 134 ("It grants folders outside the repo, including anything later installed into them globally")
**Style rationale:** "anything later installed into them globally" is an uncalibrated capability claim — it predicts future behavior of the rejected design that was not probed. **CALIBRATE** — state the concrete risk the rule avoids ("grants `C:\Program Files\Python311` as a whole, so a later install into that folder is also reachable") so the claim is about the grant's scope, not a predicted future.

### 16. Nit — Alternatives / "Projects without a lockfile (D3)", line 139 ("the fresh resolve covers the same projects with `uv`'s own code")
**Style rationale:** "`uv`'s own code" is mild jargon shorthand for "uv's resolver." Prefer the plain term for a fresh reader.

### 17. Major — Probes / P1, line 161 ("`uv` is found on `PATH` (`Get-Command`; `where.exe` does not find it)")
**Style rationale:** The parenthetical reports a `where.exe` failure with no explanation. As written it is a bare fact a reader cannot act on. Either **RELOCATE** the caveat to the Rules step that sets `PATH` (line 239) with a note that `where.exe` does not see `subst`-mapped paths, or **CALIBRATE** with one clause on why (`where.exe` does not resolve `subst`-mapped letters the same way `Get-Command` does). KEEP only if you add the one-clause reason.

### 18. Major — Probes / P2, line 162 ("Build 13 s with packages already in `uv`'s cache")
**Style rationale:** "Build 13 s" is a measured claim, but the sentence buries the condition (packages in cache) between the number and the environment spec. **CALIBRATE** — restate as "Build took 13 s (packages already in `uv`'s cache; environment 4.77 GB, 29,568 files, copied across drives)" so the measured condition precedes the result, matching P1's structure.

### 19. Nit — Probes / P3, line 163 ("Projects with no `[build-system]`, like every project in the private repo, are not installed into the environment and need nothing")
**Style rationale:** "like every project in the private repo" is an aside that widens the claim to a repo the reader cannot see (the task brief says the private repo is not in this repository). **CALIBRATE** — drop the aside or mark it explicitly as a claim about the unseen repo, not a verified fact in this worktree.

### 20. Major — Probes / P5, line 164 ("The environment is untouched, but the junction itself is left behind and the folder is not fully removed")
**Style rationale:** "the folder is not fully removed" is vague about which folder (the worktree, or the junction's target). A reader cannot tell whether `.envs` is at risk. **CALIBRATE** — name the folder ("the worktree folder is not fully removed because the junction remains") so the cleanup rule's necessity is clear.

### 21. Nit — Data / `envs.json`, line 178 ("`"approved": "<ISO time the user approved the first setup, or null>"`")
**Style rationale:** The schema comment uses "or null" inline, while the `-SandboxEnv` output block (line 207) uses `<true or false>`. Two representations of the same approval state across two schemas. Minor; pick one shape (timestamp-or-null vs boolean) and explain the relationship, or note that `envs.json.approved` is the source and the output's `approved` is derived.

### 22. Major — Rules / "Status", line 228 ("If the host has no `uv`, every project is `unsupported` (`uv-missing`)")
**Style rationale:** This is an operational rule, but it overlaps the "Estimate" and "Build failure" rules without saying which wins when `uv` is missing AND a project is otherwise `python-version-unknown`. The reader cannot determine precedence. **CALIBRATE** — state precedence ("`uv-missing` takes precedence over per-project reasons") or **RELOCATE** the precedence note to the Status rule's head.

### 23. Nit — Rules / "Estimate", line 230 ("Both are labelled estimates; the constants are set in the build task")
**Style rationale:** "the constants are set in the build task" is a forward reference with no anchor (no build task is named in this document). Either name the task or drop the clause; as is, it points at nothing the reader can open.

### 24. Nit — Rules / "`uv` itself", line 231 ("so a lockfile written by a newer `uv` doesn't meet an old copy")
**Style rationale:** "doesn't meet" is vague ("is incompatible with" / "cannot read" is the actual failure). Minor word choice; tighten for a fresh reader.

### 25. Nit — Rules / "Build (`lock`)", line 233 ("Nothing is written into the user's checkout or the repo")
**Style rationale:** This restates the Non-Goal "Changing the user's own environments" (line 42) and D2's "never granted." Three statements of the same invariant. Pick one authoritative location and reference it, rather than re-asserting in a third voice.

### 26. Major — Rules / "Build failure", line 235 ("the report gives `install-failed` with the last 20 lines of `uv`'s error")
**Style rationale:** "`install-failed`" is a status value, but the Status rule (line 228) enumerates only `ready`, `missing`, `stale`, `unsupported`. The reader cannot tell whether `install-failed` is a fifth status or a sub-case of `unsupported`/`missing`. **CALIBRATE** — add `install-failed` to the Status enumeration, or state it is reported in the proposal/error field rather than as a status.

### 27. Major — Rules / "Linking", line 237 ("A project with no `ready` environment gets a `sandboxNotes` line (worker) or makes the probe return `environment-missing`")
**Style rationale:** "makes the probe return" attributes agency to the project. Tighten to "the probe returns `environment-missing` for a project with no `ready` environment" so the actor (the probe) is the subject, matching the rest of the section's voice.

### 28. Nit — Rules / "Environment variables", line 239 ("`UV_FROZEN=1`, `UV_NO_SYNC=1`, `UV_PYTHON_DOWNLOADS=never`")
**Style rationale:** These three are listed without the one-line reason each has elsewhere (D7 explains `XAGENT_WORKTREE`; D6 explains grants). A reader who hits this list first cannot tell why `UV_NO_SYNC=1` is set. Add a clause ("`UV_NO_SYNC=1` so a worker's `uv run` cannot write the environment") or forward-reference D4.

### 29. Nit — Files table / `Sandbox.psm1` row, line 248 ("New `Invoke-SandboxCommand`, which `-SandboxRun` uses: `New-SandboxRun`, `Start-SandboxProcess` with `pwsh -NoProfile -Command <cmd>` in the worktree root, wait with timeout, `Stop-SandboxRun`")
**Style rationale:** The sentence stacks four function names and a command form into one clause. Split into the call sequence ("calls `New-SandboxRun`, then `Start-SandboxProcess` …, then waits, then `Stop-SandboxRun`") so the order is legible without re-reading.

### 30. Major — Verification / Live step 1, line 270 ("The probe command fails first with `module-missing`")
**Style rationale:** "fails first" presumes a specific failure mode of the unseen private repo before `-Apply`. This is a claim about behavior the reviewer cannot verify from this worktree (the private repo is not here, per the task brief). **CALIBRATE** — mark it as the expected failure ("the probe command is expected to fail with `module-missing` before `-Apply`") so it reads as a predicted outcome, not a measured fact in this document.

### 31. Nit — Verification / Live step 4, line 270 ("no slot identity is left on any `.envs` folder's access list")
**Style rationale:** "access list" is fine, but the document elsewhere uses "grant list" / "ACL" / "access list" interchangeably for the same thing. Pick one term and use it consistently (the parent design uses "access list").

### 32. Nit — Verification / Live step 8, line 272 ("The existing `-SandboxCheck -Repo` canary still passes all rows")
**Style rationale:** "all rows" is vague — rows of what (the canary's result array, or the test-plan table)? Name the artifact ("the canary's result array" or "the `docs/test-plan.md` canary rows") for a fresh reader.

---

## Document-level observations (not scored as findings)

- **Voice consistency:** The document mixes "the skill" (e.g. line 13), "the host" (line 94), and "the lead" (line 99) as the actor for build/run actions. Within Components the actor shifts three times in five sentences. A single named actor per section would read more cleanly.
- **Status vocabulary:** The Status rule defines four values; `install-failed` (line 235) and `environment-missing` (line 92, 237) appear as additional states without being added to the enumeration. Consolidating the status vocabulary in one place would prevent the reader from inferring a larger state machine than exists.
- **Caveat calibration pattern:** Several absolute claims ("never", "ever", "only") are used as design rules rather than tested facts. The document would read more carefully if each absolute were either (a) backed by a probe/verification pointer or (b) explicitly marked as a design rule. Today the reader must guess which.

---

## Summary

- **Blockers:** 0
- **Majors:** 11 (findings 2, 4, 6, 8, 11, 13, 15, 17, 18, 22, 26, 27, 30 — counted as 13 distinct Major items)
- **Nits:** the remainder

The document is largely precise and well-structured; the dominant style issue is **uncalibrated claims** — performance numbers, future-state predictions, and status values that outrun their cited evidence (P1–P5, the Verification section) or the Status enumeration. The highest-leverage edits are: reconcile the `git ls-files` / `git ls-tree` discrepancy (finding 8), add `install-failed` to the Status enumeration (finding 26), and narrow the "work unchanged" / "`uv add`" / "fails first with `module-missing`" claims to what the probes and live checks actually cover (findings 6, 11, 30).
