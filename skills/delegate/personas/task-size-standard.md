# Task size standard (worker task preflight)

Use this standard only when the target is a worker task file. It adds two checks to the review: a size estimate, and the scope of the acceptance command.

## Size estimate (always report it)

After the paraphrase, add a section headed **Size estimate** with:

- **Lines:** the lines of code and tests the worker will write or change, as a range (for example `300-450`). Count new files in full.
- **Files:** how many files it touches.
- **Hard parts:** anything the worker must discover rather than follow: undocumented platform behaviour, native interop, a protocol it has to probe. Name each one. Each one adds time.
- **Worker minutes:** your estimate of wall time for a coding agent, including its own test runs, as a range.
- **Verdict:** `fits` or `split`.

Calibration from measured runs on this repository:

| Task | Model | Lines | Files | Wall time |
|---|---|---|---|---|
| Replace a process-kill call at 4 sites, plus 2 test groups | Composer 2.5 (`code`) | ~200 | 4 | 17 min |
| Win32 interop layer, an 800-line PowerShell module, 32 tests | Grok 4.7 high (`code-hard`) | ~1,840 | 3 | ~44 min of work, timed out at 50 |

High-reasoning models (`code-hard`) reason through every step: roughly 75 output tokens per second, most of them reasoning, so their time grows with size much faster than a fast model's.

**Verdict `split`** when the estimate is over **20 worker minutes** or over **600 lines**. This is a **Blocker** finding. Propose the split: two to four tasks, each with its own files and its own tests, cut along a seam where one task's output is a stable interface for the next (for example: native layer, then the module functions that call it, then the integration). Every proposed task must still be testable on its own.

## Acceptance command scope

The acceptance command should run only the tests for what this task changes: its own test file, or a Pester filter on its `Describe` names. It should finish in well under a minute.

If it runs a whole suite, or tests the task cannot affect, report a **Major** finding: name the narrower command. The lead runs the full suite after each phase, so a worker doesn't need to.
