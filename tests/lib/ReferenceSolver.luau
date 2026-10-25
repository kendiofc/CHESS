--!strict
-- ReferenceSolver: the Phase 2 PuzzleValidator, frozen as a test oracle.
--
-- The production solver (PuzzleValidator) was rewritten for speed in Phase 3.
-- This copy is deliberately left slow and simple: tests compare the two on
-- many boards, and the benchmark uses it as the "before" measurement. Do not
-- optimise it.
--
-- Echo Clear objective: capture every black piece with the single white piece.
--
-- Solver: moves onto empty squares never change which targets remain or what
-- kind the player is, so from any position we flood-fill the empty squares the
-- player can reach, collect every capture available from them, and recurse on
-- each capture. A search state is (player square, player kind, targets left);
-- after a capture the square and kind are fixed by the captured piece, so the
-- memo is bounded by targets * 2^targets.

local BoardState = require(script.Parent.BoardState)
local ChessRules = require(script.Parent.ChessRules)

type Board = BoardState.Board

local PuzzleValidator = {}

-- Instrumentation for the benchmark: search states expanded.
PuzzleValidator.stats = { states = 0 }

PuzzleValidator.MAX_SOLVER_TARGETS = 16

function PuzzleValidator.isCleared(board: Board): boolean
	return BoardState.countColor(board, "black") == 0
end

local function targetKey(board: Board): string
	local list = {}
	for index, piece in pairs(board.pieces) do
		if piece.color == "black" then
			table.insert(list, index)
		end
	end
	table.sort(list)
	return table.concat(list, ",")
end

-- Breadth-first search over quiet moves. Returns parent links for every
-- reachable square and the captures available from them (first path found).
local function reachableCaptures(board: Board, start: number): ({ [number]: number }, { ChessRules.Move })
	local kind = (board.pieces[start] :: BoardState.Piece).kind
	local parent: { [number]: number } = { [start] = 0 }
	local captures: { ChessRules.Move } = {}
	local seenCapture: { [number]: boolean } = {}
	local queue = { start }
	local head = 1
	local scratch = BoardState.clone(board)
	scratch.pieces[start] = nil
	while head <= #queue do
		local square = queue[head]
		head += 1
		scratch.pieces[square] = { kind = kind, color = "white" }
		for _, move in ipairs(ChessRules.getLegalMoves(scratch, square)) do
			if move.capture then
				if not seenCapture[move.to] then
					seenCapture[move.to] = true
					table.insert(captures, move)
				end
			elseif parent[move.to] == nil then
				parent[move.to] = square
				table.insert(queue, move.to)
			end
		end
		scratch.pieces[square] = nil
	end
	return parent, captures
end

local function pathTo(parent: { [number]: number }, square: number): { number }
	local path = {}
	local current = square
	while current ~= 0 do
		table.insert(path, 1, current)
		current = parent[current]
	end
	return path
end

-- Finds one sequence of moves that clears the board in Echo Clear.
-- Returns a list of { from, to } pairs, or nil when no solution exists.
function PuzzleValidator.findSolution(board: Board): { { number } }?
	local player = BoardState.findPlayer(board)
	if not player then
		return nil
	end
	if PuzzleValidator.isCleared(board) then
		return {}
	end
	assert(
		BoardState.countColor(board, "black") <= PuzzleValidator.MAX_SOLVER_TARGETS,
		"too many targets for the solver"
	)

	local failed: { [string]: boolean } = {}

	local function search(current: Board, square: number): { { number } }?
		if PuzzleValidator.isCleared(current) then
			return {}
		end
		local key = square .. ":" .. (current.pieces[square] :: BoardState.Piece).kind .. ":" .. targetKey(current)
		if failed[key] then
			return nil
		end
		PuzzleValidator.stats.states += 1
		local parent, captures = reachableCaptures(current, square)
		for _, capture in ipairs(captures) do
			local walk = pathTo(parent, capture.from)
			local nextBoard = BoardState.clone(current)
			local moves: { { number } } = {}
			for i = 2, #walk do
				ChessRules.applyMove(nextBoard, walk[i - 1], walk[i], true)
				table.insert(moves, { walk[i - 1], walk[i] })
			end
			ChessRules.applyMove(nextBoard, capture.from, capture.to, true)
			table.insert(moves, { capture.from, capture.to })
			local rest = search(nextBoard, capture.to)
			if rest then
				table.move(rest, 1, #rest, #moves + 1, moves)
				return moves
			end
		end
		failed[key] = true
		return nil
	end

	return search(BoardState.clone(board), player)
end

-- Fewest moves (quiet moves included) that clear the board, plus one such
-- move list, or nil if it cannot be cleared. Plain BFS over full positions;
-- used offline to set par and check stored solutions, not during play.
function PuzzleValidator.shortestSolution(board: Board): (number?, { { number } }?)
	local start = BoardState.findPlayer(board)
	if not start then
		return nil, nil
	end
	local function key(b: Board, square: number): string
		return square .. ":" .. (b.pieces[square] :: BoardState.Piece).kind .. ":" .. targetKey(b)
	end
	type Node = { board: Board, square: number, parent: any, move: { number }? }
	local seen = { [key(board, start)] = true }
	local frontier: { Node } = { { board = BoardState.clone(board), square = start, parent = nil, move = nil } }
	local depth = 0
	while #frontier > 0 do
		local nextFrontier: { Node } = {}
		for _, node in ipairs(frontier) do
			if PuzzleValidator.isCleared(node.board) then
				local moves = {}
				local current: Node? = node
				while current and current.move do
					table.insert(moves, 1, current.move)
					current = current.parent
				end
				return depth, moves
			end
			for _, move in ipairs(ChessRules.getLegalMoves(node.board, node.square)) do
				local child = BoardState.clone(node.board)
				ChessRules.applyMove(child, move.from, move.to, true)
				local childKey = key(child, move.to)
				if not seen[childKey] then
					seen[childKey] = true
					table.insert(nextFrontier, { board = child, square = move.to, parent = node, move = { move.from, move.to } })
				end
			end
		end
		frontier = nextFrontier
		depth += 1
	end
	return nil, nil
end

function PuzzleValidator.minimumMoves(board: Board): number?
	return (PuzzleValidator.shortestSolution(board))
end

function PuzzleValidator.isSolvable(board: Board): boolean
	return PuzzleValidator.findSolution(board) ~= nil
end

-- Replays a solution given as square names ({ { "a1", "b3" }, ... }) against a
-- layout. Every move must be legal and the board must end cleared, with no
-- moves left over after the last target falls.
function PuzzleValidator.validateSolution(layout: { string }, solution: { { string } }): (boolean, string?)
	local board = BoardState.fromLayout(layout)
	for i, pair in ipairs(solution) do
		if PuzzleValidator.isCleared(board) then
			return false, "moves continue after the board was cleared (move " .. i .. ")"
		end
		local from = BoardState.parseSquare(board, pair[1])
		local to = BoardState.parseSquare(board, pair[2])
		if not from or not to then
			return false, "bad square name at move " .. i
		end
		local piece = board.pieces[from]
		if not piece or piece.color ~= "white" then
			return false, "no player piece on " .. pair[1] .. " at move " .. i
		end
		if not ChessRules.findMove(board, from, to) then
			return false, "illegal move " .. pair[1] .. "-" .. pair[2] .. " at move " .. i
		end
		ChessRules.applyMove(board, from, to, true)
	end
	if not PuzzleValidator.isCleared(board) then
		return false, "board not cleared"
	end
	return true, nil
end

return PuzzleValidator
