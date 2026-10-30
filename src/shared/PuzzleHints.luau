--!strict
-- PuzzleHints: picks the hint text for a player's next hint request.
--
-- Hints get more specific each time, and never play the puzzle for you:
--   1, 2   the puzzle's two hand-written hints (a strategy, then a first step)
--   3+     a live hint from the current position: the next piece to capture,
--          found by the solver. It names one target only, so the player
--          still has to find the route and every capture after it.
-- On a board that can no longer be cleared, the hint says so and points at
-- Undo instead. A live hint also returns the target's square index so the
-- client can highlight it.

local BoardState = require(script.Parent.BoardState)
local ChessRules = require(script.Parent.ChessRules)
local PuzzleValidator = require(script.Parent.PuzzleValidator)

local PuzzleHints = {}

PuzzleHints.LIVE_BUDGET = 10000 -- solver states for a live hint

function PuzzleHints.forLevel(puzzle: any, board: BoardState.Board, status: string, level: number): (string, number?)
	if status == "failed" then
		return "This position can't be cleared any more. Undo your last capture and try another."
	end
	local written = puzzle.hints[level]
	if written then
		return written
	end
	local result = PuzzleValidator.solve(board, { maxStates = PuzzleHints.LIVE_BUDGET })
	if result.status == "solved" then
		for _, move in ipairs(result.solution :: { { number } }) do
			local target = board.pieces[move[2]]
			if target and target.color == "black" then
				local name = string.lower(ChessRules.PIECE_NAMES[target.kind])
				return string.format("Capture the %s on %s next.", name, BoardState.squareName(board, move[2])), move[2]
			end
		end
	elseif result.status == "unsolvable" then
		return "This position can't be cleared any more. Undo your last capture and try another."
	end
	return puzzle.hints[#puzzle.hints]
end

return PuzzleHints
