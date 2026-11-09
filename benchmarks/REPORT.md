# Benchmark report: Cursor vs Antigravity workers
_Generated 2026-11-09 13:09 from 0 head-to-head task(s). Raw data: records.jsonl, runs.jsonl._

## Totals per agent / model

| agent / model | tasks | wins | first-try pass | final pass | avg review rounds | in scope | avg rubric (1-5) | avg tokens excl. cache | avg tokens incl. cache | avg wall time |
|---|---|---|---|---|---|---|---|---|---|---|

## Per-task log

## Method

- Both workers get the identical task file, base commit, profile tier and timeout.
- **first-try pass**: lead reruns the tests (including held-out acceptance tests the workers never saw, when `heldOutTests` is true) before any review feedback.
- **rubric** (lead's judgment, 1-5): correctness, instruction-following/scope, code quality.
- Tokens are as reported by each CLI. Subscription plans don't expose a $ cost, so token counts are the comparable cost proxy. The CLIs report caching differently (Cursor splits out cache reads; agy has so far reported 0 cached), so compare **incl. cache** totals for volume; cache reads are usually billed/quota-weighted lower.
- Small sample sizes: treat early numbers as directional.
