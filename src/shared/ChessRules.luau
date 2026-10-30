--!strict
-- ChessRules: piece movement geometry and move application.
--
-- Movement follows standard chess geometry:
--   K  one square in any direction
--   Q  slides any distance orthogonally or diagonally
--   R  slides any distance orthogonally
--   B  slides any distance diagonally
--   N  L-shaped jump; jumps over pieces and blocked squares
--   P  one square forward onto an empty square, or one square diagonally
--      forward onto an enemy piece. White moves up the board (row + 1).
--      No double step, en passant or promotion in puzzle modes.
-- Sliders stop at the first occupied square and may capture it if it is an
-- enemy. Nothing may land on, or slide through, a blocked square.
--
-- There is no check/checkmate logic: in Echo Clear the black pieces never move,
-- so king safety cannot arise. A black king is an ordinary capture target.

local BoardState = require(script.Parent.BoardState)

type Board = BoardState.Board
type Piece = BoardState.Piece

local ChessRules = {}

export type Move = { from: number, to: number, capture: boolean }
export type MoveRecord = {
	from: number,
	to: number,
	moverKind: string,
	captured: Piece?,
}

local ORTHOGONAL = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local DIAGONAL = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local ALL_DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local KNIGHT_JUMPS = { { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 } }

local SLIDE_DIRECTIONS = { Q = ALL_DIRECTIONS, R = ORTHOGONAL, B = DIAGONAL }
local STEP_DIRECTIONS = { K = ALL_DIRECTIONS, N = KNIGHT_JUMPS }

ChessRules.PIECE_NAMES = { K = "King", Q = "Queen", R = "Rook", B = "Bishop", N = "Knight", P = "Pawn" }

-- Classifies a destination square for a piece of the given color.
-- Returns "empty", "capture", or nil if the square cannot be entered.
local function classify(board: Board, color: string, col: number, row: number): string?
	if not BoardState.inBounds(board, col, row) then
		return nil
	end
	local index = BoardState.toIndex(board, col, row)
	if board.blocked[index] then
		return nil
	end
	local occupant = board.pieces[index]
	if not occupant then
		return "empty"
	end
	if occupant.color ~= color then
		return "capture"
	end
	return nil
end

function ChessRules.getLegalMoves(board: Board, from: number): { Move }
	local moves: { Move } = {}
	if not BoardState.isValidIndex(board, from) then
		return moves
	end
	local piece = board.pieces[from]
	if not piece then
		return moves
	end
	local col, row = BoardState.toCoord(board, from)

	local function add(c: number, r: number, kind: string)
		table.insert(moves, { from = from, to = BoardState.toIndex(board, c, r), capture = kind == "capture" })
	end

	local slides = SLIDE_DIRECTIONS[piece.kind]
	local steps = STEP_DIRECTIONS[piece.kind]
	if slides then
		for _, dir in ipairs(slides) do
			local c, r = col + dir[1], row + dir[2]
			while true do
				local kind = classify(board, piece.color, c, r)
				if not kind then
					break
				end
				add(c, r, kind)
				if kind == "capture" then
					break
				end
				c += dir[1]
				r += dir[2]
			end
		end
	elseif steps then
		for _, dir in ipairs(steps) do
			local c, r = col + dir[1], row + dir[2]
			local kind = classify(board, piece.color, c, r)
			if kind then
				add(c, r, kind)
			end
		end
	elseif piece.kind == "P" then
		local forward = if piece.color == "white" then 1 else -1
		if classify(board, piece.color, col, row + forward) == "empty" then
			add(col, row + forward, "empty")
		end
		for _, dc in ipairs({ -1, 1 }) do
			if classify(board, piece.color, col + dc, row + forward) == "capture" then
				add(col + dc, row + forward, "capture")
			end
		end
	end
	return moves
end

-- Returns the matching legal move, or nil if from -> to is not legal.
function ChessRules.findMove(board: Board, from: number, to: number): Move?
	for _, move in ipairs(ChessRules.getLegalMoves(board, from)) do
		if move.to == to then
			return move
		end
	end
	return nil
end

-- Applies a move in place. The caller must have validated it with findMove.
-- With echo = true, a capturing piece becomes the kind of the piece it took.
function ChessRules.applyMove(board: Board, from: number, to: number, echo: boolean): MoveRecord
	local mover = board.pieces[from]
	assert(mover, "applyMove: no piece on the from square")
	local captured = board.pieces[to]
	local record: MoveRecord = { from = from, to = to, moverKind = mover.kind, captured = captured }
	board.pieces[from] = nil
	local kind = if echo and captured then captured.kind else mover.kind
	board.pieces[to] = { kind = kind, color = mover.color }
	return record
end

function ChessRules.undoMove(board: Board, record: MoveRecord)
	local mover = board.pieces[record.to]
	assert(mover, "undoMove: no piece on the to square")
	board.pieces[record.from] = { kind = record.moverKind, color = mover.color }
	board.pieces[record.to] = record.captured
end

return ChessRules
