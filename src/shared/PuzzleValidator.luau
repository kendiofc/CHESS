--!strict
-- PuzzleValidator: objective checks, the Echo Clear solver and solution replay.
--
-- Echo Clear objective: capture every black piece with the single white piece.
--
-- Solver model. Black pieces never move, so a position is fully described by
-- the player's square, the player's kind and which targets are still on the
-- board. Quiet moves change only the square, so the search works capture by
-- capture: from the current square it flood-fills every square the player can
-- reach with quiet moves, collects the captures available from them, and
-- recurses on each. After a capture the player stands on the captured square
-- and has become that piece, so every state below the root is exactly
-- (captured square, targets left), and memoising on that key is safe.
--
-- Speed. The board is compiled once per search: each square gets its move
-- rays for each piece kind with walls and edges already removed, targets become
-- numbered bits in a mask, and the flood fill reuses preallocated arrays. The
-- hot loop allocates almost nothing and never calls ChessRules. tests/run.luau
-- checks the compiled moves against ChessRules.getLegalMoves move for move,
-- and checks every search result against the original solver.
--
-- Pruning. Before searching, the solver builds a capture graph: which targets
-- each piece could ever capture next, assuming every other target were gone.
-- That over-approximates every real position, so when the remaining targets
-- cannot even form a path through that graph (see hopeless), no real move
-- order can clear them either and the state is cut. Nothing else is cut.
--
-- There is no target limit. Callers that need a quick answer (the server,
-- after a move) pass maxStates; running out returns "unknown", never
-- "unsolvable", so a solvable puzzle is never failed because of the budget.

local BoardState = require(script.Parent.BoardState)
local ChessRules = require(script.Parent.ChessRules)

type Board = BoardState.Board

local PuzzleValidator = {}

export type SolveStatus = "solved" | "unsolvable" | "unknown"
export type SolveResult = {
	status: SolveStatus,
	solution: { { number } }?, -- { from, to } pairs, when solved
	states: number, -- search states expanded
}

function PuzzleValidator.isCleared(board: Board): boolean
	return BoardState.countColor(board, "black") == 0
end

-- Compiled board ---------------------------------------------------------------

-- Ray modes: MIXED rays move onto empty squares and capture the first target
-- they meet (sliders, and single-square rays for king and knight). The pawn
-- has a QUIET forward ray and CAPTURE-only diagonal rays.
local MIXED, QUIET, CAPTURE = 0, 1, 2

local ORTHOGONAL = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local DIAGONAL = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local ALL_DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local KNIGHT_JUMPS = { { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 } }
local SLIDES = { Q = ALL_DIRECTIONS, R = ORTHOGONAL, B = DIAGONAL }
local STEPS = { K = ALL_DIRECTIONS, N = KNIGHT_JUMPS }

type SquareMoves = { rays: { { number } }, modes: { number } }

type Context = {
	board: Board,
	size: number,
	count: number, -- number of targets
	targetAt: { [number]: number }, -- square -> target id (1-based)
	targetSquare: { number },
	targetKind: { string },
	bitLo: { number }, -- mask bit of each target (ids 1-32 in lo, 33+ in hi)
	bitHi: { number },
	tables: { [string]: { SquareMoves } },
	alive: { boolean },
	-- flood fill scratch, reused between calls
	epoch: number,
	stamp: { number },
	dist: { number },
	parent: { number },
	queue: { number },
	seenTarget: { number },
}

local function compileSquare(board: Board, kind: string, square: number): SquareMoves
	local rays: { { number } } = {}
	local modes: { number } = {}
	local col, row = BoardState.toCoord(board, square)
	local function open(c: number, r: number): number?
		if not BoardState.inBounds(board, c, r) then
			return nil
		end
		local index = BoardState.toIndex(board, c, r)
		return if board.blocked[index] then nil else index
	end
	local slides, steps = SLIDES[kind], STEPS[kind]
	if slides then
		for _, dir in ipairs(slides) do
			local ray = {}
			local c, r = col + dir[1], row + dir[2]
			local index = open(c, r)
			while index do
				table.insert(ray, index)
				c += dir[1]
				r += dir[2]
				index = open(c, r)
			end
			if #ray > 0 then
				table.insert(rays, ray)
				table.insert(modes, MIXED)
			end
		end
	elseif steps then
		for _, dir in ipairs(steps) do
			local index = open(col + dir[1], row + dir[2])
			if index then
				table.insert(rays, { index })
				table.insert(modes, MIXED)
			end
		end
	elseif kind == "P" then
		-- The solver only moves the white piece, which moves up the board.
		local forward = open(col, row + 1)
		if forward then
			table.insert(rays, { forward })
			table.insert(modes, QUIET)
		end
		for _, dc in ipairs({ -1, 1 }) do
			local diagonal = open(col + dc, row + 1)
			if diagonal then
				table.insert(rays, { diagonal })
				table.insert(modes, CAPTURE)
			end
		end
	end
	return { rays = rays, modes = modes }
end

local function movesFor(ctx: Context, kind: string): { SquareMoves }
	local cached = ctx.tables[kind]
	if cached then
		return cached
	end
	local list = table.create(ctx.size)
	for square = 1, ctx.size do
		list[square] = compileSquare(ctx.board, kind, square)
	end
	ctx.tables[kind] = list
	return list
end

local function compile(board: Board): Context
	local size = board.width * board.height
	local ctx: Context = {
		board = board,
		size = size,
		count = 0,
		targetAt = {},
		targetSquare = {},
		targetKind = {},
		bitLo = {},
		bitHi = {},
		tables = {},
		alive = {},
		epoch = 0,
		stamp = table.create(size, 0),
		dist = table.create(size, 0),
		parent = table.create(size, 0),
		queue = table.create(size, 0),
		seenTarget = {},
	}
	for square = 1, size do
		local piece = board.pieces[square]
		if piece and piece.color == "black" then
			ctx.count += 1
			local id = ctx.count
			ctx.targetAt[square] = id
			ctx.targetSquare[id] = square
			ctx.targetKind[id] = piece.kind
			ctx.alive[id] = true
			ctx.seenTarget[id] = 0
			ctx.bitLo[id] = if id <= 32 then bit32.lshift(1, id - 1) else 0
			ctx.bitHi[id] = if id > 32 then bit32.lshift(1, id - 33) else 0
		end
	end
	return ctx
end

-- Flood-fills quiet moves for `kind` from `start` and returns the captures
-- available as a flat list of (target id, square captured from, quiet moves to
-- get there). BFS order means each target is listed with its nearest square.
-- ctx.parent holds the quiet paths until the next call.
local function explore(ctx: Context, start: number, kind: string): { number }
	ctx.epoch += 1
	local epoch = ctx.epoch
	local stamp, dist, parent, queue = ctx.stamp, ctx.dist, ctx.parent, ctx.queue
	local alive, targetAt, seenTarget = ctx.alive, ctx.targetAt, ctx.seenTarget
	local moves = movesFor(ctx, kind)
	local captures = {}
	stamp[start] = epoch
	dist[start] = 0
	parent[start] = 0
	queue[1] = start
	local head, tail = 1, 1
	while head <= tail do
		local square = queue[head]
		head += 1
		local entry = moves[square]
		local rays, modes = entry.rays, entry.modes
		for r = 1, #rays do
			local ray, mode = rays[r], modes[r]
			for j = 1, #ray do
				local to = ray[j]
				local target = targetAt[to]
				if target and alive[target] then
					if mode ~= QUIET and seenTarget[target] ~= epoch then
						seenTarget[target] = epoch
						local n = #captures
						captures[n + 1] = target
						captures[n + 2] = square
						captures[n + 3] = dist[square]
					end
					break
				end
				if mode == CAPTURE then
					break
				end
				if stamp[to] ~= epoch then
					stamp[to] = epoch
					dist[to] = dist[square] + 1
					parent[to] = square
					tail += 1
					queue[tail] = to
				end
			end
		end
	end
	return captures
end

local function quietPath(ctx: Context, square: number): { number }
	local path = {}
	local current = square
	while current ~= 0 do
		table.insert(path, 1, current)
		current = ctx.parent[current]
	end
	return path
end

-- Turns a capture order into full moves by replaying it with quiet paths.
local function expandOrder(ctx: Context, start: number, startKind: string, order: { number }): { { number } }
	local moves: { { number } } = {}
	local square, kind = start, startKind
	for _, target in ipairs(order) do
		local captures = explore(ctx, square, kind)
		local from: number? = nil
		for i = 1, #captures, 3 do
			if captures[i] == target then
				from = captures[i + 1]
				break
			end
		end
		assert(from, "solver: capture order does not replay")
		local path = quietPath(ctx, from)
		for i = 2, #path do
			table.insert(moves, { path[i - 1], path[i] })
		end
		table.insert(moves, { from, ctx.targetSquare[target] })
		ctx.alive[target] = false
		square, kind = ctx.targetSquare[target], ctx.targetKind[target]
	end
	for _, target in ipairs(order) do
		ctx.alive[target] = true
	end
	return moves
end

-- Memo keyed by (hi mask, square) then lo mask.
local function memoGet(memo: { [number]: { [number]: any } }, hi: number, square: number, lo: number): any
	local row = memo[hi * 64 + square]
	return row and row[lo]
end

local function memoSet(memo: { [number]: { [number]: any } }, hi: number, square: number, lo: number, value: any)
	local key = hi * 64 + square
	local row = memo[key]
	if not row then
		row = {}
		memo[key] = row
	end
	row[lo] = value
end

local function initialMasks(ctx: Context): (number, number)
	local lo, hi = 0, 0
	for id = 1, ctx.count do
		lo = bit32.bor(lo, ctx.bitLo[id])
		hi = bit32.bor(hi, ctx.bitHi[id])
	end
	return lo, hi
end

-- Pruning ----------------------------------------------------------------------

-- Targets a piece of `kind` on `start` could capture if every other target
-- were already gone. Removing targets only opens more squares, so this is a
-- superset of what it can ever capture from there: an edge missing here is
-- missing in every position.
local function reachableTargets(ctx: Context, start: number, kind: string, self: number): (number, number)
	ctx.epoch += 1
	local epoch = ctx.epoch
	local stamp, queue, targetAt = ctx.stamp, ctx.queue, ctx.targetAt
	local moves = movesFor(ctx, kind)
	local lo, hi = 0, 0
	stamp[start] = epoch
	queue[1] = start
	local head, tail = 1, 1
	while head <= tail do
		local square = queue[head]
		head += 1
		local entry = moves[square]
		local rays, modes = entry.rays, entry.modes
		for r = 1, #rays do
			local ray, mode = rays[r], modes[r]
			for j = 1, #ray do
				local to = ray[j]
				local target = targetAt[to]
				if target and target ~= self and mode ~= QUIET then
					lo = bit32.bor(lo, ctx.bitLo[target])
					hi = bit32.bor(hi, ctx.bitHi[target])
				end
				if mode == CAPTURE then
					break
				end
				if stamp[to] ~= epoch then
					stamp[to] = epoch
					tail += 1
					queue[tail] = to
				end
			end
		end
	end
	return lo, hi
end

-- The capture graph: node 0 is the starting position, node t is "just captured
-- target t". out[u] holds every target u could ever capture next and in[v]
-- every target that could ever capture v.
type Graph = { outLo: { number }, outHi: { number }, inLo: { number }, inHi: { number } }

local function captureGraph(ctx: Context, start: number, startKind: string): Graph
	local graph: Graph = { outLo = {}, outHi = {}, inLo = {}, inHi = {} }
	graph.outLo[0], graph.outHi[0] = reachableTargets(ctx, start, startKind, 0)
	for v = 1, ctx.count do
		graph.inLo[v], graph.inHi[v] = 0, 0
	end
	for u = 1, ctx.count do
		local lo, hi = reachableTargets(ctx, ctx.targetSquare[u], ctx.targetKind[u], u)
		graph.outLo[u], graph.outHi[u] = lo, hi
		for v = 1, ctx.count do
			if bit32.band(lo, ctx.bitLo[v]) ~= 0 or bit32.band(hi, ctx.bitHi[v]) ~= 0 then
				graph.inLo[v] = bit32.bor(graph.inLo[v], ctx.bitLo[u])
				graph.inHi[v] = bit32.bor(graph.inHi[v], ctx.bitHi[u])
			end
		end
	end
	return graph
end

-- True when the targets in (lo, hi) provably cannot all be captured starting
-- from `node`. A clearing order is a path through the capture graph that
-- starts at `node` and visits every remaining target, so:
--   * `node` needs an edge to some remaining target;
--   * every remaining target needs an edge in, from `node` or another
--     remaining target;
--   * at most one remaining target (the last one) may have no edge out to
--     another remaining target.
local function hopeless(ctx: Context, graph: Graph, node: number, lo: number, hi: number): boolean
	local outLo, outHi, inLo, inHi = graph.outLo, graph.outHi, graph.inLo, graph.inHi
	local nodeLo, nodeHi = outLo[node], outHi[node]
	if bit32.band(nodeLo, lo) == 0 and bit32.band(nodeHi, hi) == 0 then
		return true
	end
	local alive, bitLo, bitHi = ctx.alive, ctx.bitLo, ctx.bitHi
	local stuck = 0
	for id = 1, ctx.count do
		if alive[id] then
			if bit32.band(outLo[id], lo) == 0 and bit32.band(outHi[id], hi) == 0 then
				stuck += 1
				if stuck > 1 then
					return true
				end
			end
			if
				bit32.band(inLo[id], lo) == 0
				and bit32.band(inHi[id], hi) == 0
				and bit32.band(nodeLo, bitLo[id]) == 0
				and bit32.band(nodeHi, bitHi[id]) == 0
			then
				return true
			end
		end
	end
	-- Every remaining target must be reachable from `node` through remaining
	-- targets only.
	local reachLo, reachHi = bit32.band(nodeLo, lo), bit32.band(nodeHi, hi)
	local grown = true
	while grown do
		grown = false
		for id = 1, ctx.count do
			if
				alive[id]
				and (bit32.band(reachLo, bitLo[id]) ~= 0 or bit32.band(reachHi, bitHi[id]) ~= 0)
			then
				local newLo = bit32.bor(reachLo, bit32.band(outLo[id], lo))
				local newHi = bit32.bor(reachHi, bit32.band(outHi[id], hi))
				if newLo ~= reachLo or newHi ~= reachHi then
					reachLo, reachHi, grown = newLo, newHi, true
				end
			end
		end
	end
	return reachLo ~= lo or reachHi ~= hi
end

-- Search ---------------------------------------------------------------------

export type SolveOptions = { maxStates: number? }

-- Looks for any sequence of moves that clears the board.
function PuzzleValidator.solve(board: Board, options: SolveOptions?): SolveResult
	local start = BoardState.findPlayer(board)
	if not start then
		return { status = "unsolvable", solution = nil, states = 0 }
	end
	local ctx = compile(board)
	if ctx.count == 0 then
		return { status = "solved", solution = {}, states = 0 }
	end
	local startKind = (board.pieces[start] :: BoardState.Piece).kind
	local maxStates = if options and options.maxStates then options.maxStates else math.huge
	local graph = captureGraph(ctx, start, startKind)
	local alive, targetSquare, targetKind = ctx.alive, ctx.targetSquare, ctx.targetKind
	local bitLo, bitHi = ctx.bitLo, ctx.bitHi
	local lo, hi = initialMasks(ctx)
	local remaining = ctx.count
	local failed = {}
	local states = 0
	local aborted = false
	local order: { number } = {}

	local function search(node: number, square: number, kind: string): boolean
		if remaining == 0 then
			return true
		end
		if memoGet(failed, hi, square, lo) or hopeless(ctx, graph, node, lo, hi) then
			return false
		end
		if states >= maxStates then
			aborted = true
			return false
		end
		states += 1
		local captures = explore(ctx, square, kind)
		for i = 1, #captures, 3 do
			local target = captures[i]
			alive[target] = false
			lo, hi = bit32.bxor(lo, bitLo[target]), bit32.bxor(hi, bitHi[target])
			remaining -= 1
			local found = search(target, targetSquare[target], targetKind[target])
			alive[target] = true
			lo, hi = bit32.bxor(lo, bitLo[target]), bit32.bxor(hi, bitHi[target])
			remaining += 1
			if found then
				table.insert(order, 1, target)
				return true
			end
			if aborted then
				return false
			end
		end
		memoSet(failed, hi, square, lo, true)
		return false
	end

	if search(0, start, startKind) then
		return { status = "solved", solution = expandOrder(ctx, start, startKind, order), states = states }
	end
	return { status = if aborted then "unknown" else "unsolvable", solution = nil, states = states }
end

-- Finds one sequence of moves that clears the board in Echo Clear.
-- Returns a list of { from, to } pairs, or nil when no solution exists.
function PuzzleValidator.findSolution(board: Board): { { number } }?
	return PuzzleValidator.solve(board).solution
end

function PuzzleValidator.isSolvable(board: Board): boolean
	return PuzzleValidator.solve(board).status == "solved"
end

-- Fewest moves (quiet moves included) that clear the board, plus one such
-- move list, or nil if it cannot be cleared. Each capture costs the quiet
-- moves to the nearest square that attacks it plus one, so the minimum is a
-- shortest path through the same capture states the search uses. Exact, with
-- no budget: meant for authoring and tests, not for live play.
function PuzzleValidator.shortestSolution(board: Board): (number?, { { number } }?)
	local start = BoardState.findPlayer(board)
	if not start then
		return nil, nil
	end
	local ctx = compile(board)
	local startKind = (board.pieces[start] :: BoardState.Piece).kind
	local graph = captureGraph(ctx, start, startKind)
	local alive, targetSquare, targetKind = ctx.alive, ctx.targetSquare, ctx.targetKind
	local bitLo, bitHi = ctx.bitLo, ctx.bitHi
	local lo, hi = initialMasks(ctx)
	local remaining = ctx.count
	local cost = {}
	local choice = {}

	local function best(node: number, square: number, kind: string): number
		if remaining == 0 then
			return 0
		end
		local known = memoGet(cost, hi, square, lo)
		if known then
			return known
		end
		if hopeless(ctx, graph, node, lo, hi) then
			return math.huge
		end
		local bestCost, bestTarget = math.huge, 0
		local captures = explore(ctx, square, kind)
		for i = 1, #captures, 3 do
			local target = captures[i]
			alive[target] = false
			lo, hi = bit32.bxor(lo, bitLo[target]), bit32.bxor(hi, bitHi[target])
			remaining -= 1
			local total = captures[i + 2] + 1 + best(target, targetSquare[target], targetKind[target])
			alive[target] = true
			lo, hi = bit32.bxor(lo, bitLo[target]), bit32.bxor(hi, bitHi[target])
			remaining += 1
			if total < bestCost then
				bestCost, bestTarget = total, target
			end
		end
		memoSet(cost, hi, square, lo, bestCost)
		memoSet(choice, hi, square, lo, bestTarget)
		return bestCost
	end

	local total = best(0, start, startKind)
	if total == math.huge then
		return nil, nil
	end
	-- Follow the recorded choices to get the capture order.
	local order = {}
	local square = start
	while remaining > 0 do
		local target = memoGet(choice, hi, square, lo)
		table.insert(order, target)
		lo, hi = bit32.bxor(lo, bitLo[target]), bit32.bxor(hi, bitHi[target])
		remaining -= 1
		square = targetSquare[target]
	end
	local moves = expandOrder(ctx, start, startKind, order)
	assert(#moves == total, "solver: shortest path length mismatch")
	return total, moves
end

function PuzzleValidator.minimumMoves(board: Board): number?
	return (PuzzleValidator.shortestSolution(board))
end

-- Counts complete capture orders from the start: how many clear the board and
-- how many get stuck with targets left. Used to grade difficulty. Unpruned,
-- so every dead end is counted.
function PuzzleValidator.countOrders(board: Board): (number, number)
	local start = BoardState.findPlayer(board)
	if not start then
		return 0, 0
	end
	local ctx = compile(board)
	local alive, targetSquare, targetKind = ctx.alive, ctx.targetSquare, ctx.targetKind
	local bitLo, bitHi = ctx.bitLo, ctx.bitHi
	local lo, hi = initialMasks(ctx)
	local remaining = ctx.count
	local memo = {}

	local function count(square: number, kind: string): (number, number)
		if remaining == 0 then
			return 1, 0
		end
		local known = memoGet(memo, hi, square, lo)
		if known then
			return known[1], known[2]
		end
		local wins, deadEnds = 0, 0
		local captures = explore(ctx, square, kind)
		for i = 1, #captures, 3 do
			local target = captures[i]
			alive[target] = false
			lo, hi = bit32.bxor(lo, bitLo[target]), bit32.bxor(hi, bitHi[target])
			remaining -= 1
			local w, d = count(targetSquare[target], targetKind[target])
			alive[target] = true
			lo, hi = bit32.bxor(lo, bitLo[target]), bit32.bxor(hi, bitHi[target])
			remaining += 1
			wins += w
			deadEnds += d
		end
		if #captures == 0 then
			deadEnds = 1
		end
		memoSet(memo, hi, square, lo, { wins, deadEnds })
		return wins, deadEnds
	end

	return count(start, (board.pieces[start] :: BoardState.Piece).kind)
end

-- The player's moves from `square` as the solver sees them, as { to = capture }.
-- Exposed so tests can prove the compiled tables match ChessRules exactly.
function PuzzleValidator.compiledMoves(board: Board, square: number): { [number]: boolean }
	local piece = board.pieces[square]
	assert(piece and piece.color == "white", "compiledMoves: no player piece on that square")
	local ctx = compile(board)
	local result = {}
	-- Same walk as explore, from a single square.
	local entry = movesFor(ctx, piece.kind)[square]
	for r, ray in ipairs(entry.rays) do
		local mode = entry.modes[r]
		for _, to in ipairs(ray) do
			local target = ctx.targetAt[to]
			if target then
				if mode ~= QUIET then
					result[to] = true
				end
				break
			end
			if mode == CAPTURE then
				break
			end
			result[to] = false
		end
	end
	return result
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
