-- Puzzle analysis report for authoring and difficulty grading.
-- Run with: python3 tools/run_tests.py path/to/luau tests/analyze.luau
--
-- For every puzzle it prints the target count, the true minimum number of
-- moves (par), and how many capture orders clear the board versus how many
-- run into a dead end. A low win/dead-end ratio means a harder puzzle.

local BoardState = require(Shared.BoardState)
local ChessRules = require(Shared.ChessRules)
local PuzzleValidator = require(Shared.PuzzleValidator)
local PuzzleDefinitions = require(Shared.PuzzleDefinitions)

-- Captures reachable from `start` through quiet moves: { [targetSquare] = squareCapturedFrom }.
local function reachableCaptures(board, start: number): { [number]: number }
	local kind = board.pieces[start].kind
	local seen, captures, queue, head = { [start] = true }, {}, { start }, 1
	local scratch = BoardState.clone(board)
	scratch.pieces[start] = nil
	while head <= #queue do
		local square = queue[head]
		head += 1
		scratch.pieces[square] = { kind = kind, color = "white" }
		for _, move in ipairs(ChessRules.getLegalMoves(scratch, square)) do
			if move.capture then
				captures[move.to] = square
			elseif not seen[move.to] then
				seen[move.to] = true
				table.insert(queue, move.to)
			end
		end
		scratch.pieces[square] = nil
	end
	return captures
end

-- Counts complete capture orders: returns wins, deadEnds.
local function countOrders(board, square: number): (number, number)
	if PuzzleValidator.isCleared(board) then
		return 1, 0
	end
	local wins, deadEnds, any = 0, 0, false
	for target, from in pairs(reachableCaptures(board, square)) do
		any = true
		local nextBoard = BoardState.clone(board)
		nextBoard.pieces[square] = nil
		nextBoard.pieces[from] = { kind = board.pieces[square].kind, color = "white" }
		ChessRules.applyMove(nextBoard, from, target, true)
		local w, d = countOrders(nextBoard, target)
		wins += w
		deadEnds += d
	end
	if not any then
		return 0, 1
	end
	return wins, deadEnds
end

print(string.format("%-10s %-14s %-9s %7s %4s %6s %9s", "id", "name", "level", "targets", "par", "wins", "deadEnds"))
for _, puzzle in ipairs(PuzzleDefinitions.list) do
	local board = BoardState.fromLayout(puzzle.layout)
	local wins, deadEnds = countOrders(board, assert(BoardState.findPlayer(board)))
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
