--!strict
-- BoardState: the board data model shared by server and client.
--
-- A board is a width x height grid (max 8x8). Squares are addressed by a flat
-- index: index = (row - 1) * width + col, with col 1 = file "a" on the left and
-- row 1 = the bottom rank. Each square is empty, blocked, or holds one piece.
--
-- Layouts are written as strings, one per row, TOP row first:
--   "."  empty square
--   "#"  blocked square (cannot be entered or slid through)
--   K Q R B N P  white piece (the player's piece)
--   k q r b n p  black piece (a capture target)

local BoardState = {}

export type Color = "white" | "black"
export type Piece = { kind: string, color: Color }
export type Board = {
	width: number,
	height: number,
	pieces: { [number]: Piece },
	blocked: { [number]: boolean },
}

BoardState.MAX_SIZE = 8
BoardState.KINDS = { K = true, Q = true, R = true, B = true, N = true, P = true }

local FILES = "abcdefgh"

function BoardState.toIndex(board: Board, col: number, row: number): number
	return (row - 1) * board.width + col
end

function BoardState.toCoord(board: Board, index: number): (number, number)
	local col = (index - 1) % board.width + 1
	local row = (index - col) // board.width + 1
	return col, row
end

function BoardState.inBounds(board: Board, col: number, row: number): boolean
	return col >= 1 and col <= board.width and row >= 1 and row <= board.height
end

function BoardState.isValidIndex(board: Board, index: any): boolean
	return type(index) == "number"
		and index == math.floor(index)
		and index >= 1
		and index <= board.width * board.height
end

function BoardState.squareName(board: Board, index: number): string
	local col, row = BoardState.toCoord(board, index)
	return string.sub(FILES, col, col) .. tostring(row)
end

function BoardState.parseSquare(board: Board, name: string): number?
	local file, rank = string.match(name, "^([a-h])(%d)$")
	if not file or not rank then
		return nil
	end
	local col = (string.find(FILES, file, 1, true) :: number)
	local row = tonumber(rank) :: number
	if not BoardState.inBounds(board, col, row) then
		return nil
	end
	return BoardState.toIndex(board, col, row)
end

function BoardState.fromLayout(layout: { string }): Board
	local height = #layout
	assert(height >= 1 and height <= BoardState.MAX_SIZE, "layout must have 1-8 rows")
	local width = #layout[1]
	assert(width >= 1 and width <= BoardState.MAX_SIZE, "layout rows must have 1-8 columns")

	local board: Board = { width = width, height = height, pieces = {}, blocked = {} }
	for i, line in ipairs(layout) do
		assert(#line == width, "layout rows must all have the same length")
		local row = height - i + 1
		for col = 1, width do
			local ch = string.sub(line, col, col)
			local index = BoardState.toIndex(board, col, row)
			if ch == "#" then
				board.blocked[index] = true
			elseif ch ~= "." then
				local upper = string.upper(ch)
				assert(BoardState.KINDS[upper], "unknown layout character: " .. ch)
				board.pieces[index] = { kind = upper, color = if ch == upper then "white" else "black" }
			end
		end
	end
	return board
end

function BoardState.toLayout(board: Board): { string }
	local layout = {}
	for row = board.height, 1, -1 do
		local chars = table.create(board.width)
		for col = 1, board.width do
			local index = BoardState.toIndex(board, col, row)
			local piece = board.pieces[index]
			if board.blocked[index] then
				chars[col] = "#"
			elseif piece then
				chars[col] = if piece.color == "white" then piece.kind else string.lower(piece.kind)
			else
				chars[col] = "."
			end
		end
		table.insert(layout, table.concat(chars))
	end
	return layout
end

function BoardState.clone(board: Board): Board
	local pieces = {}
	for index, piece in pairs(board.pieces) do
		pieces[index] = { kind = piece.kind, color = piece.color }
	end
	return {
		width = board.width,
		height = board.height,
		pieces = pieces,
		blocked = table.clone(board.blocked),
	}
end

-- Returns the index of the single white piece, or nil if there is none.
function BoardState.findPlayer(board: Board): number?
	for index, piece in pairs(board.pieces) do
		if piece.color == "white" then
			return index
		end
	end
	return nil
end

function BoardState.countColor(board: Board, color: Color): number
	local count = 0
	for _, piece in pairs(board.pieces) do
		if piece.color == color then
			count += 1
		end
	end
	return count
end

return BoardState
