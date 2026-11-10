# Research: cross-agent coordination (Claude Code ↔ Cursor ↔ Antigravity)

*Researched 2026-11-08. Things move fast; re-verify flags against official docs before relying on them.*

## TL;DR

- Cursor and Antigravity both have **headless CLIs with JSON output**, so Claude Code can call them as sub-agents through Bash. This is the path we're taking (local only).
- Both also have **cloud APIs** (Cursor Cloud Agents API, Gemini Managed Agents). We're deferring these for now.
- **Open question:** whether automated wrapping of `agy` is allowed on a consumer Google subscription (see [Antigravity caveat](#subscription--tos-caveat-important-for-us)).
- Existing harnesses already do this: **hcom** (local messaging between agents) and **Omnigent** (full meta-harness). Worth trying before or alongside building our own.

---

## 1. Cursor

Context: SpaceX acquired Anysphere (Cursor) in an all-stock deal valued at $60B. The deal was announced 2026-06-16 and closed 2026-08-14. Cursor now runs as a subsidiary inside SpaceXAI.

### 1a. Headless CLI (our primary path)

- Install: `curl https://cursor.com/install -fsS | bash`. *(Windows install method still to be checked; see test plan.)*
- The binary is now `agent` (older docs call it `cursor-agent`).
- Key flags:
  - `-p, --print`: non-interactive. Has all tools, including write and shell.
  - `--output-format text|json|stream-json`: only works together with `-p`. With `json`, the final answer is in `.result`.
  - `--stream-partial-output`: character-level deltas (needs `stream-json`).
  - `--force`: **without it, print mode only proposes changes and applies nothing.**
  - `--trust`: trust the workspace without a prompt (headless only).
  - Auth for CI: `CURSOR_API_KEY` env var. Locally, use the logged-in session.
- Example: `agent -p --output-format json "Summarize the open TODOs" | jq -r '.result'`
- Thinking events are never emitted in print mode.
- If `json` mode fails, you get no well-formed JSON plus a non-zero exit. **Check the exit code before parsing.**
- **Known bug:** forum reports of `-p` hanging forever with no output. **Always wrap calls in a timeout.**

### 1b. Cloud Agents API v1 (public beta) — deferred

- Base URL `https://api.cursor.com`. Basic or Bearer auth with a user or service-account API key.
- `POST /v1/agents`: takes `prompt.text`, `repos[]` (url, startingRef), `model`, `autoCreatePR`, `workOnCurrentBranch`, `mcpServers`, `customSubagents`, `mode` (agent/plan), `envVars`.
- `POST /v1/agents/{id}/runs`: follow-up on the same workspace. Returns `409 agent_busy` if a run is already active. `"delivery":"steer"` injects into the running turn.
- `GET /v1/agents/{id}/runs/{runId}`: states are CREATING, RUNNING, WAITING_FOR_BACKGROUND_WORK, then FINISHED, ERROR, CANCELLED or EXPIRED. A finished run has `result`, `durationMs` and `git.branches[].prUrl`.
- `GET .../runs/{runId}/stream`: SSE events (status, assistant, thinking, tool_call, result, error, done).
- Artifacts endpoints return presigned S3 URLs.
- **No webhooks in v1 yet** ("coming soon"; the legacy v0 API had them). Poll or use SSE instead.

### 1c. TypeScript SDK `@cursor/sdk` (public beta since ~Apr 2026)

- `Agent.create()` / `Agent.prompt()`. Same runtime as the IDE. You can open and take over SDK-started tasks in the Cursor UI.
- MCP servers come from `.cursor/mcp.json` or can be passed inline.
- Gap: the first cloud environment setup still has to be done in the dashboard.

### 1d. Integrations

- Slack (`@Cursor`), GitHub, Linear (assign an issue to Cursor), the CLI's `&` prefix (sends to a cloud agent), and an iOS app.

## 2. Google Antigravity

Timeline: v1 launched 2025-11-18. **Antigravity 2.0** launched at I/O on 2026-05-19 with a standalone desktop app (successor to the Agent Manager), the `agy` CLI, an SDK, and Managed Agents in the Gemini API. The `agy` CLI **replaced Gemini CLI**, which sunset for consumer tiers on 2026-06-18. It kept Gemini CLI's skills, hooks and subagents, and renamed extensions to plugins.

### 2a. `agy` headless CLI (our primary path)

- A Go binary. Windows install: `irm https://antigravity.google/cli/install.ps1 | iex`.
- Key flags:
  - `-p, --print, --prompt`: single prompt, non-interactive.
  - `--output-format text|json|stream-json`: with `json`, the answer is in `.response`, alongside `status`, `duration_seconds`, `num_turns` and `usage` (input, output, thinking and cached tokens).
  - `--input-format text|stream-json`: `stream-json` input requires `stream-json` output (NDJSON).
  - `--json-schema <schema|file>`: **enforces structured output**. The root must be `"type":"object"`. Very useful for our result contract.
  - `--disable-slash-commands`
  - `--print-timeout` (default 5m): returns partial output and warns on stderr.
  - `--continue`: chains onto the same conversation, so we can iterate after a review.
  - `--dangerously-skip-permissions`: the unattended mode. There's no `--approve` policy flag.
- Status values: SUCCESS, ERROR, CANCELED, INTERRUPTED, INVALID, WAITING, RUNNING. Exit code 0 means success.
- Diagnostics go to stderr, so stdout stays clean for parsing.
- An unauthenticated non-interactive run exits with an error rather than hanging.
- Full audit log: `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`. Lifecycle hooks are configured in `.agents/hooks.json`.
- Example: `echo "<prompt>" | agy -p - --output-format json --disable-slash-commands`

### Subscription / ToS caveat (important for us)

From the Google AI Developers Forum thread "Is external orchestration of Antigravity CLI headless mode supported with account-based usage?":
- 2026-09-15: a reply from user "Engineer760" said **yes**. Running the official `agy` binary as a child process with its cached Google credentials is supported and draws on the same subscription limits. Extracting OAuth tokens or calling the backend directly is **not** supported. **That user has no staff badge, so this isn't confirmed as Google's position.**
- 2026-10-27: another user said the **current FAQ calls wrapping `agy` in another application unsupported on consumer plans**. No answer yet. Several similar threads are also unresolved.
- **Our action:** (1) read the current Antigravity FAQ and ToS ourselves; (2) test technically that it works on our Pro tier; (3) if the terms forbid it, fall back to an API-key path (Gemini Managed Agents / SDK, pay per token) or keep Antigravity manual.

### 2b. Managed Agents (Gemini Interactions API) — deferred

- Agent `antigravity-preview-09-2026` (Gemini 3.8 Flash; the model can be changed via `agent_config`). The `-05-2026` version was deprecated on 2026-10-05.
- `ai.interactions.create({agent, environment: "remote", input})`: one call provisions a Linux sandbox, runs the agent loop and returns the result. State persists across turns.
- A Files API, a Credentials API (e.g. the GitHub MCP), and custom agents defined with AGENTS.md / SKILL.md.
- Reported pricing: about $0.75 / $3.75 per million tokens (Flash). Billed by API key, separate from the subscription.

### 2c. Antigravity SDK

- The same harness, self-hosted. The package and class names (`pip install google-antigravity`, `AntigravityClient`) come from third-party sites only and haven't been verified.

### 2d. A2A

- Antigravity is reported to support Google's Agent2Agent protocol (now under the Linux Foundation). **Cursor and Claude Code do not support A2A natively**, so A2A can't be the common layer for all three yet.

## 3. Claude Code (the lead)

- Calls the other CLIs via Bash or PowerShell, or through a skill or MCP tool that wraps them.
- Has its own headless mode (`claude -p`), the Agent SDK, and subagents. Has cross-session messaging between Claude sessions only.
- No native Linear assignee integration (anthropics/claude-code#12925). Use the Linear MCP instead.

## 3b. Headroom proxy (our local setup)

Checked 2026-11-08 against local headroom 0.42.0. The proxy listens on `127.0.0.1:8787` with backend=anthropic, mode=cache, and compression ("kompress") on.

**Lead (Claude Code):** routed through headroom via `ANTHROPIC_BASE_URL=http://127.0.0.1:8787` and `ANTHROPIC_CUSTOM_HEADERS: X-Headroom-Session-Token`.
- ⚠️ **Main risk: tool results get compressed.** Headroom compresses large tool outputs before they reach the model (we've seen `[N words compressed…]` markers). Worker results and **diffs that Claude reviews** could reach the lead summarized or cut short. That can make review lossy.
  - Mitigations: workers write results to files; the lead reads diffs in small chunks (per file, `git diff -- <file>`) so each chunk stays under the compression threshold; use `headroom_retrieve` when a marker appears; maybe tune `min_tokens_to_crush` / `protect_analysis_context`. Test this in T6.
- Child processes inherit the env. A `claude -p` subprocess would also go through headroom (fine). `agent` / `agy` ignore the `ANTHROPIC_*` variables.
- Note: the health output shows `tls.process_injected: true` and the env has `HEADROOM_PROCESS_TRUST=1`. Check whether this affects TLS for child CLIs (T6).

**Cursor:** `headroom wrap cursor` only prints IDE settings: *Settings → Models → OpenAI API Key → Override Base URL*. That path only applies to **bring-your-own OpenAI-key** models. Pro-subscription traffic goes to Cursor's own backend, which isn't an OpenAI-compatible API, so **headroom can't compress our Cursor usage**. No interference, but no savings either. Whether the `agent` CLI honors a base-URL override is unknown, and probably not useful on Pro anyway.

**Antigravity:** the headroom help says Antigravity "does not support third-party model providers — agent models are Google-managed." Headroom covers two things for it:
1. **MCP registration** (`headroom mcp install --agent antigravity`): gives the agent headroom's compress/retrieve tools. Harmless and allowed.
2. **A native `POST /v1internal:streamGenerateContent` endpoint** (the Code Assist / cloudcode endpoint that Google-login clients use), plus a `cloudcode_api_url` config. In theory `agy` traffic could be proxied. But that means sending our **subscription OAuth traffic through a third-party proxy**, which sits right next to the ToS gray zone ("calling backend services directly" is unsupported). **Don't do this until the T0 policy check is resolved.**

**Bottom line:** headroom doesn't block the plan. Only the lead gets compressed. Cursor and Antigravity bypass headroom on Pro tiers. The real thing to watch is lossy compression of the results and diffs the lead reviews.

Sources: [Headroom proxy docs](https://headroomlabs-ai.github.io/headroom/proxy/) · [Headroom CLI](https://headroomlabs-ai.github.io/headroom/cli/) · [Integration guide](https://headroomlabs-ai.github.io/headroom/integration-guide/) · local `headroom wrap cursor|antigravity --help`

## 4. Existing harnesses

| Project | What it does | Notes for us |
|---|---|---|
| [hcom](https://github.com/aannoo/hcom) (MIT, ~650★) | Prefix-launch agents (`hcom claude`, `hcom cursor-agent`, `hcom agy`). Uses each tool's hooks and a local SQLite store, so agents can message, watch and spawn each other. Messages arrive mid-turn or wake idle agents. MQTT relay for linking machines. | **Closest to our need, local-first.** Has a Windows installer. Try it early. |
| [Omnigent](https://github.com/omnigent-ai/omnigent) (Apache-2.0, ~11k★, alpha) | Meta-harness with claude-sdk, cursor and antigravity harnesses, a web UI with live sharing, and policies and budgets. Orchestrator "Polly" writes no code itself and sends each diff to a reviewer from a different vendor. | Heavyweight. Polly's documented sub-agents are Claude Code, Codex and Pi. **Degraded on Windows** (no filesystem or network isolation). Collects telemetry by default. |
| [kodo](https://github.com/ikamensh/kodo) | Orchestrator LLM with Claude Code as the "smart worker" and Cursor, Codex or Gemini as "fast workers", plus architect and tester checks. | Similar design idea. |
| ORCH | Typed task queue (todo→in_progress→review→done), retries, messaging between agents, TUI. Supports Claude Code, Codex and Cursor. | |
| [zetbrush/multiagents](https://github.com/zetbrush/multiagents) | Agent teams coordinating via MCP. | Claude, Codex and Gemini CLI. Antigravity untested. |
| Bernstein, Munder Difflin, Vibe Kanban, Claude Squad, Emdash, OpenCastle | Parallel runners and worktree managers. | |

Directory: [bradAGI/awesome-cli-coding-agents](https://github.com/bradagi/awesome-cli-coding-agents)

## 5. Shared communication channel options

Ranked by fit for agent-to-agent coordination:

1. **Git / GitHub issues and PRs.** Every agent can read and write it, the review loop comes built in, and everything is logged. For local mode, git worktrees and branches play the same role.
2. **Linear.** Cursor can be assigned issues natively. Linear's own Agent can run Claude Code. For Claude Code as lead, use the Linear MCP.
3. **Slack.** `@Cursor` and Claude in Slack both work, but bot-to-bot threads are fragile, many bots ignore other bots' messages, and there's no structured status. Better for showing progress to humans.
4. **Google Docs / email.** Slow, no status model, needs polling. Fine as a human-readable log, but not as the control channel.

**Conclusion:** for local mode, the "channel" is the filesystem and git: a task file goes in, a structured JSON result and a diff come back.

## Sources

- Cursor: [Cloud Agents API](https://cursor.com/docs/cloud-agent/api/endpoints) · [Headless CLI](https://cursor.com/docs/cli/headless) · [CLI parameters](https://cursor.com/docs/cli/reference/parameters) · [SDK announcement (MarkTechPost)](https://www.marktechpost.com/2026/04/29/cursor-introduces-a-typescript-sdk-for-building-programmatic-coding-agents-with-sandboxed-cloud-vms-subagents-hooks-and-token-based-pricing/) · [SDK env-setup gap](https://forum.cursor.com/t/cursor-cloud-agents-sdk-start-agent-setup-via-api-or-flag/161634) · [-p hang bug](https://forum.cursor.com/t/cursor-agent-p-print-headless-mode-hangs-indefinitely-and-never-returns/150246) · [Joining SpaceX](https://cursor.com/blog/joining-spacex) · [TechCrunch](https://techcrunch.com/2026/06/16/spacex-to-acquire-cursor-for-60b-in-stock-days-after-blockbuster-ipo/)
- Antigravity: [Headless mode](https://antigravity.google/docs/cli/headless/) · [CLI reference](https://antigravity.google/docs/cli/reference/) · [I/O 2026 highlights](https://blog.google/innovation-and-ai/technology/developers-tools/google-io-2026-developer-highlights/) · [Antigravity agent (Gemini API)](https://ai.google.dev/gemini-api/docs/antigravity-agent) · [Managed agents quickstart](https://ai.google.dev/gemini-api/docs/managed-agents-quickstart) · [Updated harness](https://aistudio.google.com/learn/managed-agents-updated-harness-files-credentials) · [Orchestration/ToS forum thread](https://discuss.ai.google.dev/t/is-external-orchestration-of-antigravity-cli-headless-mode-supported-with-account-based-usage/183051)
- Interop: [A2A vs MCP (Augment)](https://www.augmentcode.com/guides/a2a-vs-mcp) · [Cross-vendor A2A swarms](https://researchut.com/blog/taming_the_ai_agents_part_2_a2a/) · [Linear coding sessions](https://linear.app/changelog/2026-06-11-coding-sessions) · [Linear agents](https://linear.app/integrations/agents) · [claude-code#12925](https://github.com/anthropics/claude-code/issues/12925)
- Harnesses: [hcom](https://github.com/aannoo/hcom) · [Omnigent](https://github.com/omnigent-ai/omnigent) · [kodo](https://github.com/ikamensh/kodo) · [multiagents](https://github.com/zetbrush/multiagents) · [Augment: 9 orchestrators](https://www.augmentcode.com/tools/open-source-agent-orchestrators)

## 6. Google Elephant-Goldfish Model (EGM), evaluated 2026-11-09

[google/elephant-goldfish-model](https://github.com/google/elephant-goldfish-model): Apache-2.0, ~16k★, "not an officially supported Google product". It's a plugin of skills and prompts with no model weights, for Claude Code, Codex, Antigravity, Cursor, Copilot and OpenCode. The idea: the **elephant** (the drafting agent, which has full context) writes the spec, and **goldfish** (reviewers in fresh contexts that know only the document and what it references) review it through specialized lenses: zoom-out, comprehension, design critic, codebase details, implementation readiness, structural, style. A synthesizer dedupes findings into Blocker/Major/Nit. Skills: brainstorm, draft, review, resolve, review-loop, bootstrap, drift-report.

What we adopted:
- **Goldfish preflight of task files.** Our workers are goldfish too. Vendored `implementation_readiness` (+ its standard: "zero-decision rule"), `comprehension` (paraphrase-first) and `design_critic` into `skills/delegate/personas/` with attribution. They run via a new read-only `review` profile on cheap models, which makes them **cross-vendor** goldfish. (EGM itself spawns same-model subagents.)
- **Anti-sycophancy rules** in the council prompt ("critique first, earn your agreement, no flattery").
- The review output format (Blocker/Major/Nit plus a verdict) as `review.schema.json`.

Not adopted (yet): the full EGM design workflow (draft → five-phase review → resolve). For larger features we could install the plugin itself (`claude plugin marketplace add google/elephant-goldfish-model`, then `claude plugin install egm@egm`) and use its `docs/designs/*.md` output as the input we break into delegate task files.

## 7. Landscape survey: similar projects, 2026-11-09

How much of what we build already exists. Only the delegate-skills and kodo READMEs were read in full. Everything else comes from search summaries, so treat star counts and feature claims as rough.

**Delegating to another vendor's CLI, then reviewing the diff** (our `delegate` code profiles). Crowded.
- [amElnagdy/delegate-skills](https://github.com/amElnagdy/delegate-skills) (MIT, ~2.6k★) is the closest twin.
  - It has one `*-delegate` skill per CLI, for 19 CLIs including `cursor-agent` and `agy`. A `relay.mjs` writes `result.json` with status, exit code, the worker's report, `touchedFiles` and a session id.
  - Follow-ups resume the session with a short "delta" brief. The relay never commits, so the lead does.
  - It has named "lanes" (feature/tests/ui) and multi-task queues.
  - It has no worktree management, no council and no benchmarking. Native Windows runs are recorded for cursor and agy.
- [shinpr/sub-agents-skills](https://github.com/shinpr/sub-agents-skills) routes tasks to about 11 backends, with read-only, safe-edit and yolo permission levels.
- Single-vendor versions for agy:
  - [markfulton/claude-antigravity-agents](https://github.com/markfulton/claude-antigravity-agents) runs coding tasks in a worktree and reviews in a read-only sandbox.
  - [yuting0624/antigravity-for-claude-code](https://github.com/yuting0624/antigravity-for-claude-code) includes `/antigravity:review --adversarial`.
  - [SafeMantella/claude-code-agy-CLI-skill](https://github.com/SafeMantella/claude-code-agy-CLI-skill) is another.

**Multi-model council** (our `council`/`review` profiles). Crowded.
- [epicsagas/council](https://github.com/epicsagas/council) is a single skill covering claude, codex, agy and grok. The models answer independently, review each other anonymously (no model reviews its own answer), and a chairman writes the synthesis.
- [WiktorStarczewski/review-council](https://github.com/WiktorStarczewski/review-council) triages findings and fixes them in a loop.
- Others: [OSideMedia/model-council](https://github.com/OSideMedia/model-council) (Gemini via agy), [sshkeda/pi-council](https://github.com/sshkeda/pi-council), [rachittshah/llmcouncil](https://github.com/rachittshah/llmcouncil), [DantesPeak85/the-council](https://github.com/DantesPeak85/the-council), [laurencelwarde/ai-council](https://github.com/laurencelwarde/ai-council).

**Running agents in parallel worktrees** (session managers, not lead-and-reviewer loops): Emdash, Vibe Kanban, Claude Squad, ccmanager, dmux, Craig, diri, Rove, brgr, Friday, Scion and CAO.
- Friday passes work to another agent when one hits its usage limit, which is relevant to budget.
- Concord MCP lets agents claim files, which is relevant to scheduling parallel tasks that must not touch the same files.
- Directories: [andyrewlee/awesome-agent-orchestrators](https://github.com/andyrewlee/awesome-agent-orchestrators), [Agent-Analytics/awesome-multi-agent-orchestrators](https://github.com/Agent-Analytics/awesome-multi-agent-orchestrators), and the bradAGI list in §4.

**Feature-level flow with stages** (our planned `feature` skill).
- Spec-driven frameworks: Superpowers, GitHub Spec Kit, BMAD, OpenSpec and GSD ([comparison, Oct 2026](https://felipefontoura.com/articles/spec-driven-development-tools-compared/)).
  - They cover brainstorm → spec → plan → tasks → build, with gates.
  - Every stage runs on Claude (sub)agents only, with no cross-vendor workers.
  - In that head-to-head test, Superpowers skipped its own brainstorm stage.
- [kodo](https://github.com/ikamensh/kodo) (MIT, ~140★) is the closest to the `feature` skill.
  - Flow: intake/plan → architect survey → workers (Claude as "smart", Cursor/Codex/Gemini as "fast"), in parallel worktrees → tester and architect review with a rejection loop.
  - Runs are saved on disk and can be resumed.
  - Cost is tracked in two buckets: real API spend and subscription use counted as "virtual".
  - Weak points: the README admits there is no independent verification gate, and agents run with permission checks bypassed.

**What is still distinct about ours:**
- An EGM-reviewed design that the user locks before any code exists.
- Native Windows/PowerShell, and workers are other vendors only, to protect the Claude quota.
- Benchmark mode with trial records.
- A feature integration branch, plus a final check of the whole diff against the design.

**Worth borrowing:**
- From delegate-skills: the `touchedFiles` field in results, delta-brief resume, and named lanes.
- From kodo: the real-versus-virtual cost split.
- From Spec Kit: the `tasks.md` shape, for our plan stage.
- From Concord MCP: file claims, for scheduling parallel work.
- From epicsagas/council: anonymized peer review between models before the synthesis.

Sources: the links above, plus the [Augment orchestrator roundup](https://www.augmentcode.com/tools/open-source-agent-orchestrators) and [Nimbalyst on parallel agent tools](https://nimbalyst.com/blog/best-tools-for-running-parallel-ai-coding-agents/).
