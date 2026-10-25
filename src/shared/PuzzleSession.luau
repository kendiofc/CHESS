--!strict
-- PuzzleSession: one attempt at one puzzle. Owns the board, move history and
-- status, and is the only thing that mutates a board during play. The server
-- runs one session per player; tests drive it directly.
--
-- Status values:
--   "playing"  moves are accepted
--   "won"      every black piece has been captured
--   "failed"   the remaining targets can no longer all be captured
-- Undo is allowed from "playing" and "failed" (practice rules), and moves a
-- failed session back to "playing".

local BoardState = require(script.Parent.BoardState)
local ChessRules = require(script.Parent.ChessRules)
local PuzzleValidator = require(script.Parent.PuzzleValidator)

type Board = BoardState.Board

export type Status = "playing" | "won" | "failed"

local PuzzleSession = {}
PuzzleSession.__index = PuzzleSession

export type PuzzleSession = typeof(setmetatable(
	{} :: {
		puzzle: any,
		board: Board,
		history: { ChessRules.MoveRecord },
		status: Status,
		moveCount: number,
		targetsTotal: number,
	},
	PuzzleSession
))

function PuzzleSession.new(puzzle: any): PuzzleSession
	local board = BoardState.fromLayout(puzzle.layout)
	local self = setmetatable({
		puzzle = puzzle,
		board = board,
		history = {},
		status = "playing" :: Status,
		moveCount = 0,
		targetsTotal = BoardState.countColor(board, "black"),
	}, PuzzleSession)
	return self
end

function PuzzleSession.targetsLeft(self: PuzzleSession): number
	return BoardState.countColor(self.board, "black")
end

function PuzzleSession.evaluate(self: PuzzleSession)
	if PuzzleValidator.isCleared(self.board) then
		self.status = "won"
	elseif PuzzleValidator.isSolvable(self.board) then
		self.status = "playing"
	else
		self.status = "failed"
	end
end

-- Attempts a move. Returns ok, plus an error code when rejected.
function PuzzleSession.tryMove(self: PuzzleSession, from: any, to: any): (boolean, string?)
	if self.status ~= "playing" then
		return false, "not_playing"
	end
	if not BoardState.isValidIndex(self.board, from) or not BoardState.isValidIndex(self.board, to) then
		return false, "bad_square"
	end
	local piece = self.board.pieces[from]
	if not piece or piece.color ~= "white" then
		return false, "not_your_piece"
	end
	if not ChessRules.findMove(self.board, from, to) then
		return false, "illegal_move"
	end
	local record = ChessRules.applyMove(self.board, from, to, true)
	table.insert(self.history, record)
	self.moveCount += 1
	self:evaluate()
	return true, nil
end

function PuzzleSession.undo(self: PuzzleSession): boolean
	if self.status == "won" then
		return false
	end
	local record = table.remove(self.history)
	if not record then
		return false
	end
	ChessRules.undoMove(self.board, record)
	self.moveCount -= 1
	self:evaluate()
	return true
end

function PuzzleSession.restart(self: PuzzleSession)
	self.board = BoardState.fromLayout(self.puzzle.layout)
	self.history = {}
	self.moveCount = 0
	self.status = "playing"
end

function PuzzleSession.lastMove(self: PuzzleSession): ChessRules.MoveRecord?
	return self.history[#self.history]
end

return PuzzleSession
