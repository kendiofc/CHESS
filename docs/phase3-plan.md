# Phase 3 plan: puzzle collection, difficulty, hints, validation

Phase 2 was audited on 2026-10-25 (see the PR for the test log). This note sets
out what Phase 3 builds on and the order to build it in. Multiplayer,
monetization and other modes stay out of scope.

## What already exists

- `PuzzleDefinitions.Puzzle` has every field the catalogue needs: `id`, `name`,
  `difficulty`, `mode`, `objective`, `layout`, `solution`, `hints`, `reward`,
  `par` and `estimatedSeconds`.
- `GameConfig.DIFFICULTIES` lists Beginner, Easy, Medium, Hard and Expert, and
  `Theme.DifficultyColors` has a colour for each.
- `PuzzleValidator` can replay a stored solution (`validateSolution`), check
  that a position is solvable (`findSolution`), and find the true minimum
  (`shortestSolution` / `minimumMoves`).
- `tests/run.luau` already checks every puzzle in the list: the solution
  replays, par is the BFS minimum, and the target count is within
  `MAX_SOLVER_TARGETS`. New puzzles get these checks for free.
- `tests/analyze.luau` reports win and dead-end capture orders per puzzle,
  which is the raw material for difficulty grading.

## Order of work

1. **Solver speed first.** The search is exhaustive and copies the board for
   every capture. An unsolvable 11-target board takes about 0.6 s in the CLI.
   The server runs it after every move to detect a dead end, so this must be
   fixed before larger puzzles arrive:
   - key the memo on a bitmask of remaining targets instead of a sorted string
   - reuse one scratch board with apply/undo instead of cloning
   - keep `MAX_SOLVER_TARGETS` (16) as a hard cap, enforced by the tests
   - add a benchmark test with a time budget for the worst puzzle
2. **Difficulty grading.** Turn `analyze.luau` into a shared `PuzzleGrader`
   module with a score from target count, par, the win/dead-end ratio and how
   many piece kinds the solution passes through. A test asserts that each
   puzzle's stated difficulty matches its graded band, so the labels can't
   drift.
3. **The 30 puzzles.** Six per difficulty. Author them as layouts and let the
   solver produce `solution` and `par`, then check them with the existing tests
   plus the grader. Use a generator script only to propose candidates; every
   shipped puzzle stays handcrafted and reviewed.
4. **Hints, server-side.** Add a `hint` action. The server picks the hint from
   the player's current position, not the start: it runs `findSolution` from
   the live board and reveals the next capture target, then the square to
   capture from. Hints used are counted in the snapshot and on the result card.
   Rate-limit hints separately from moves.
5. **Solution validation on completion.** The server already decides the win
   from its own board. Before awarding anything, also re-check the move log
   with `validateSolution`, and reject any result whose server time is below a
   floor (for example 1 s per move).
6. **UI.** A puzzle select screen grouped by difficulty, a Hint button next to
   Undo/Restart, and hint text in the message line. Puzzles unlock in order
   within each difficulty.

## Open questions for Kendi

- Should hints cost anything (lower stars, no par bonus) or be free?
- Should all difficulties be open from the start, or unlock as you clear the
  previous tier?
- Is progress saved between sessions in Phase 3 (DataStore), or later?
