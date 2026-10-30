-- Puzzle analysis report for authoring and difficulty grading.
-- Run with: python3 tools/run_tests.py path/to/luau tests/analyze.luau
--
-- For every puzzle it prints the target count, the true minimum number of
-- moves (par), how many capture orders clear the board versus how many run
-- into a dead end, and the difficulty score PuzzleCheck grades it by.

local BoardState = require(Shared.BoardState)
local PuzzleValidator = require(Shared.PuzzleValidator)
local PuzzleDefinitions = require(Shared.PuzzleDefinitions)
local PuzzleCheck = require(Shared.PuzzleCheck)

print(string.format("%-12s %-16s %-9s %4s %7s %4s %7s %9s %6s  %s", "id", "name", "filed", "size", "targets", "par", "wins", "deadEnds", "score", "grades as"))
for _, puzzle in ipairs(PuzzleDefinitions.list) do
	local board = BoardState.fromLayout(puzzle.layout)
	local grade = assert(PuzzleCheck.grade(puzzle.layout), puzzle.id .. " is unsolvable")
	print(
		string.format(
			"%-12s %-16s %-9s %4s %7d %4d %7d %9d %6.1f  %s",
			puzzle.id,
			puzzle.name,
			puzzle.difficulty,
			board.width .. "x" .. board.height,
			grade.targets,
			grade.par,
			grade.wins,
			grade.deadEnds,
			grade.score,
			grade.difficulty
		)
	)
end
