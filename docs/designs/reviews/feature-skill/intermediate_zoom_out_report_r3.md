# Intermediate zoom-out (stage 8), round 3: focused on `81d4ecd`

**Target:** the lines `81d4ecd` changed (the stage 9 round 2 fixes). `zoom_out` on Grok 4.7 medium, 370 s. Raw report: `.xagent/runs/fr-s8r3/`.

**Verdict:** the design is still the small version. Derived `done`, the id budget, `reaudit`, `reviewRuns`, the schemas files, pid start times and the other derived status fields are the size of the holes they close. No Blocker.

## Resolutions

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Major | The build-council write-up copies `delegate`'s council procedure, which stage 5 had settled as "list only the differences" | **Fixed.** Cut to a delta on `delegate`'s procedure: question contents, seats and ids, two-round limit, consensus and disagreement handling. The cap check moved ahead of it (IR r3 #2) |
| 2 | Nit | `XAGENT_VERIFY_TIMEOUT_SEC` is a config channel only the test uses | **Fixed.** `verify -TimeoutSec` (default 900), like `delegate.ps1` |
| 3 | Nit | `[reaudit]` has two writers | **Fixed.** `reaudit` is the only writer; dropped from `decision`'s kinds |
| 4 | Nit | The id cut is 12 in the plan, 16 in scheduling | **Fixed.** Scheduling points at the item 8 budget |
