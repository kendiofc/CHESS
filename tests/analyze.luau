-- Puzzle analysis report for authoring and difficulty grading.
-- Run with: python3 tools/run_tests.py path/to/luau tests/analyze.luau
--
-- For every puzzle it prints the target count, the true minimum number of
-- moves (par), and how many capture orders clear the board versus how many
-- run into a dead end. A low win/dead-end ratio means a harder puzzle.

local BoardState = require(Shared.BoardState)
local PuzzleValidator = require(Shared.PuzzleValidator)
local PuzzleDefinitions = require(Shared.PuzzleDefinitions)

print(string.format("%-10s %-14s %-9s %7s %4s %6s %9s", "id", "name", "level", "targets", "par", "wins", "deadEnds"))
for _, puzzle in ipairs(PuzzleDefinitions.list) do
	local board = BoardState.fromLayout(puzzle.layout)
	local wins, deadEnds = PuzzleValidator.countOrders(board)
	print(
		string.format(
			"%-10s %-14s %-9s %7d %4s %6d %9d",
			puzzle.id,
			puzzle.name,
			puzzle.difficulty,
			BoardState.countColor(board, "black"),
			tostring(PuzzleValidator.minimumMoves(board)),
			wins,
			deadEnds
		)
	)
end
