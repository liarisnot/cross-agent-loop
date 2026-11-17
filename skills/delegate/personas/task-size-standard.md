# Task size standard (worker task preflight)

Use this standard only when the target is a worker task file. It adds two checks to the review: a size estimate, and the scope of the acceptance command.

## Size estimate (always report it)

After the paraphrase, add a section headed **Size estimate** with:

- **Lines:** the lines of code and tests the worker will write or change, as a range (for example `300-450`). Count new files in full.
- **Files:** how many files it touches.
- **Hard parts:** anything the worker must discover rather than follow: undocumented platform behaviour, native interop, a protocol it has to probe. Name each one. Each one adds time.
- **Worker minutes:** your estimate of wall time for a coding agent, including its own test runs, as a range.
- **Cohesion:** can this task be cut into parts that are each testable on their own and that still make sense alone? Name the seam if there is one (one part's output is a stable interface for the next). Say `cohesive` if every cut would leave a part that proves nothing alone (for example, a test harness and the one test that proves it).
- **Verdict:** `fits` or `split`.

Calibration from measured runs on this repository. "Coding time" leaves out the acceptance-suite run, because tasks now run only their own tests (seconds):

| Task | Model | Lines | Files | Wall time | Coding time |
|---|---|---|---|---|---|
| Replace a process-kill call at 4 sites, plus 2 test groups | Composer 2.5 (`code`) | ~200 | 4 | 17 min | ~7-8 min (9.5 min was a full-suite run) |
| Win32 interop layer, an 800-line PowerShell module, 32 tests | Grok 4.7 high (`code-hard`) | ~1,840 | 3 | 50 min, timed out | ~38 min (32 writing, 7 probing an undocumented Windows rule) |
| Sandbox run functions (`run-fns`), estimated 22-32 min | Grok 4.7 high (`code-hard`) | | | 17 min | |
| Sandbox slot handling (`slots`), estimated 18-26 min | Grok 4.7 high (`code-hard`) | | | 22 min | |

The first two work out to roughly **30-60 lines a minute**, so 600 lines is about 12-20 minutes. Estimate from that rate plus a few minutes for each hard part. Don't extrapolate from wall time: it includes test runs. High-reasoning models (`code-hard`) emit about 75 tokens per second, most of them reasoning, so a task full of discovery runs slower than the rate. But well-specified `code-hard` tasks on Grok 4.7 high landed at or below the low end of the estimate (the last two rows, 2026-11-15): for those, give the low end.

**Verdict `split`** when the estimate is over **20 worker minutes** or over **600 lines** and the task has a seam. Report it as a **Major** finding: it is advice, and the lead decides. Propose the split: two to four tasks, each with its own files and its own tests, cut along that seam (for example: native layer, then the module functions that call it, then the integration). Every proposed task must still be testable on its own. When the task is big but `cohesive`, give `fits` and say why: never propose a cut that leaves a part that proves nothing alone.

## Acceptance command scope

The acceptance command should run only the tests for what this task changes: its own test file, or a Pester filter on its `Describe` names. It should finish in well under a minute.

If it runs a whole suite, or tests the task cannot affect, report a **Major** finding: name the narrower command. The lead runs the full suite after each phase, so a worker doesn't need to.
