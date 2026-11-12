# Calculator extensions

Add subtraction and division to the sandbox `calc` module.

## Functions

### `subtract(a, b)`

Returns `a - b` for numeric operands.

### `divide(a, b)`

Returns `a / b` for numeric operands. When `b` is zero, raise `ValueError` with a clear message (do not return a sentinel).

## Tests

In `test_calc.py`, add one `unittest` method per new function:

- `test_subtract` checks a typical case (for example `subtract(7, 3)` is `4`).
- `test_divide` checks a typical case (for example `divide(8, 2)` is `4.0`).
- `test_divide_by_zero` expects `ValueError` when dividing by zero.

The test command remains `python -m unittest -q` in the sandbox folder.
