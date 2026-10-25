-- Engine test suite. Run with: python3 tools/run_tests.py path/to/luau
-- `Shared` and `require` are provided by the runner's module shim.

local BoardState = require(Shared.BoardState)
local ChessRules = require(Shared.ChessRules)
local PuzzleValidator = require(Shared.PuzzleValidator)
local PuzzleSession = require(Shared.PuzzleSession)
local PuzzleDefinitions = require(Shared.PuzzleDefinitions)

local passed, failed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	end
end

local function eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(string.format("%sexpected %s, got %s", if label then label .. ": " else "", tostring(expected), tostring(actual)), 2)
	end
end

local function sq(board, name: string): number
	return assert(BoardState.parseSquare(board, name), "bad square " .. name)
end

-- Sorted destination names for the piece on `from`.
local function dests(board, from: string): string
	local names = {}
	for _, move in ipairs(ChessRules.getLegalMoves(board, sq(board, from))) do
		table.insert(names, BoardState.squareName(board, move.to) .. (if move.capture then "x" else ""))
	end
	table.sort(names)
	return table.concat(names, " ")
end

local function countMoves(layout, from: string): number
	local board = BoardState.fromLayout(layout)
	return #ChessRules.getLegalMoves(board, sq(board, from))
end

local EMPTY8 = { "........", "........", "........", "........", "........", "........", "........", "........" }
local function place(char: string, col: number, row: number): { string }
	local layout = table.clone(EMPTY8)
	local i = 9 - row
	layout[i] = string.sub(layout[i], 1, col - 1) .. char .. string.sub(layout[i], col + 1)
	return layout
end

-- BoardState -----------------------------------------------------------------

test("layout round-trips", function()
	local layout = { "r..#k", "..b..", "#.n.p", "q....", "B.#.." }
	local board = BoardState.fromLayout(layout)
	eq(table.concat(BoardState.toLayout(board), "/"), table.concat(layout, "/"))
	eq(board.width, 5)
	eq(board.height, 5)
end)

test("row 1 is the bottom row of the layout", function()
	local board = BoardState.fromLayout({ "k...", "....", "....", "Q..#" })
	eq(board.pieces[sq(board, "a1")].kind, "Q")
	eq(board.pieces[sq(board, "a1")].color, "white")
	eq(board.pieces[sq(board, "a4")].color, "black")
	eq(board.blocked[sq(board, "d1")], true)
end)

test("square names and indices agree", function()
	local board = BoardState.fromLayout({ "...", "...", "..." })
	for index = 1, 9 do
		eq(BoardState.parseSquare(board, BoardState.squareName(board, index)), index)
	end
	eq(BoardState.parseSquare(board, "d1"), nil, "off-board file")
	eq(BoardState.parseSquare(board, "a4"), nil, "off-board rank")
	eq(BoardState.parseSquare(board, "zz"), nil, "garbage")
end)

test("isValidIndex rejects junk", function()
	local board = BoardState.fromLayout({ "..", ".." })
	eq(BoardState.isValidIndex(board, 1), true)
	eq(BoardState.isValidIndex(board, 4), true)
	eq(BoardState.isValidIndex(board, 0), false)
	eq(BoardState.isValidIndex(board, 5), false)
	eq(BoardState.isValidIndex(board, 1.5), false)
	eq(BoardState.isValidIndex(board, "1"), false)
	eq(BoardState.isValidIndex(board, nil), false)
	eq(BoardState.isValidIndex(board, math.huge), false)
	eq(BoardState.isValidIndex(board, 0 / 0), false)
end)

test("bad layouts are rejected", function()
	eq(pcall(BoardState.fromLayout, { "...", ".." }), false, "ragged rows")
	eq(pcall(BoardState.fromLayout, { "..x" }), false, "unknown char")
	eq(pcall(BoardState.fromLayout, { "........." }), false, "too wide")
end)

-- Movement on an open 8x8 board ------------------------------------------------

test("open-board move counts for every piece", function()
	eq(countMoves(place("Q", 4, 4), "d4"), 27, "queen d4")
	eq(countMoves(place("R", 4, 4), "d4"), 14, "rook d4")
	eq(countMoves(place("B", 4, 4), "d4"), 13, "bishop d4")
	eq(countMoves(place("N", 4, 4), "d4"), 8, "knight d4")
	eq(countMoves(place("N", 1, 1), "a1"), 2, "knight a1")
	eq(countMoves(place("K", 4, 4), "d4"), 8, "king d4")
	eq(countMoves(place("K", 1, 1), "a1"), 3, "king a1")
	eq(countMoves(place("P", 4, 2), "d2"), 1, "pawn d2: single step only")
	eq(countMoves(place("P", 4, 8), "d8"), 0, "pawn on last rank")
end)

test("knight destinations are exact", function()
	local board = BoardState.fromLayout(place("N", 2, 1))
	eq(dests(board, "b1"), "a3 c3 d2")
end)

-- Blocking, captures and walls --------------------------------------------------

test("sliders stop at and capture the first enemy", function()
	local board = BoardState.fromLayout({ "....", "r...", "....", "R..b" })
	eq(dests(board, "a1"), "a2 a3x b1 c1 d1x")
end)

test("sliders cannot pass through or land on walls", function()
	local board = BoardState.fromLayout({ "...", ".#.", "..#", "B.R" })
	-- bishop on a1: b2 then c3; c3 path is clear (b2 empty), wall at b3 not on the diagonal
	eq(dests(board, "a1"), "b2 c3")
	-- rook on c1 is white too: the bishop cannot capture it, and vice versa
	eq(dests(board, "c1"), "b1")
end)

test("wall stops a rook slide", function()
	local board = BoardState.fromLayout({ "k", "#", ".", "R" })
	eq(dests(board, "a1"), "a2")
end)

test("knights jump over walls and pieces but cannot land on walls", function()
	local board = BoardState.fromLayout({ "...", "#..", "##.", "N#." })
	eq(dests(board, "a1"), "b3 c2")
	local walled = BoardState.fromLayout({ "...", "#..", "##.", "N#." })
	walled.blocked[sq(walled, "b3")] = true
	eq(dests(walled, "a1"), "c2")
end)

test("pawn moves forward to empty squares and captures only diagonally forward", function()
	local board = BoardState.fromLayout({ "....", ".r.n", "..P.", "...q" })
	eq(dests(board, "c2"), "b3x c3 d3x")
	local blocked = BoardState.fromLayout({ "..", ".r", ".P" })
	eq(dests(blocked, "b1"), "", "pawn cannot capture straight ahead")
	local behind = BoardState.fromLayout({ "..", ".P", "r." })
	eq(dests(behind, "b2"), "b3", "pawn cannot capture backwards")
end)

test("pieces never capture their own color", function()
	local board = BoardState.fromLayout({ "Q.R" })
	eq(dests(board, "a1"), "b1")
end)

test("findMove rejects illegal destinations", function()
	local board = BoardState.fromLayout({ "...", "...", "R.." })
	eq(ChessRules.findMove(board, sq(board, "a1"), sq(board, "b2")), nil, "rook diagonal")
	eq(ChessRules.findMove(board, sq(board, "a1"), sq(board, "a1")), nil, "null move")
	eq(ChessRules.findMove(board, sq(board, "b2"), sq(board, "b3")), nil, "empty from square")
	assert(ChessRules.findMove(board, sq(board, "a1"), sq(board, "a3")))
end)

-- Echo transformation and undo ----------------------------------------------------

test("capturing echoes the captured kind and undo restores both pieces", function()
	local board = BoardState.fromLayout({ "n", ".", "R" })
	local record = ChessRules.applyMove(board, sq(board, "a1"), sq(board, "a3"), true)
	eq(board.pieces[sq(board, "a3")].kind, "N")
	eq(board.pieces[sq(board, "a3")].color, "white")
	eq(board.pieces[sq(board, "a1")], nil)
	ChessRules.undoMove(board, record)
	eq(table.concat(BoardState.toLayout(board), "/"), "n/./R")
end)

test("quiet moves keep the piece kind", function()
	local board = BoardState.fromLayout({ ".", ".", "R" })
	ChessRules.applyMove(board, sq(board, "a1"), sq(board, "a3"), true)
	eq(board.pieces[sq(board, "a3")].kind, "R")
end)

-- Solver ---------------------------------------------------------------------------

test("solver: trivially solvable and unsolvable boards", function()
	eq(PuzzleValidator.isSolvable(BoardState.fromLayout({ "r", ".", "R" })), true)
	eq(PuzzleValidator.isSolvable(BoardState.fromLayout({ "P", "r" })), false, "target behind a pawn")
	eq(PuzzleValidator.isSolvable(BoardState.fromLayout({ "b#", "#R" })), false, "rook walled in")
	eq(PuzzleValidator.isSolvable(BoardState.fromLayout({ "R" })), true, "nothing to capture")
end)

test("solver: echo chain that needs the transformation", function()
	-- The rook cannot reach the bishop itself; it must become the knight first.
	local board = BoardState.fromLayout({ "b#", "##", "Rn" })
	eq(ChessRules.findMove(board, sq(board, "a1"), sq(board, "a3")), nil)
	eq(PuzzleValidator.isSolvable(board), true)
	-- Same shape with a pawn instead: the pawn on b1 is boxed in, so it fails.
	eq(PuzzleValidator.isSolvable(BoardState.fromLayout({ "b#", "##", "Rp" })), false)
end)

test("solver output always replays legally and clears the board", function()
	local board = BoardState.fromLayout({ "r..#k", "..b..", "#.n.p", "q....", "B.#.." })
	local solution = assert(PuzzleValidator.findSolution(board))
	local names = {}
	for _, pair in ipairs(solution) do
		table.insert(names, { BoardState.squareName(board, pair[1]), BoardState.squareName(board, pair[2]) })
	end
	eq(PuzzleValidator.validateSolution(BoardState.toLayout(board), names), true)
end)

test("minimumMoves on small boards", function()
	eq(PuzzleValidator.minimumMoves(BoardState.fromLayout({ "r", ".", "R" })), 1)
	eq(PuzzleValidator.minimumMoves(BoardState.fromLayout({ ".r", "..", "R." })), 2)
	eq(PuzzleValidator.minimumMoves(BoardState.fromLayout({ "P", "r" })), nil)
end)

-- Puzzle catalogue -------------------------------------------------------------------

for _, puzzle in ipairs(PuzzleDefinitions.list) do
	test("puzzle " .. puzzle.id .. ": definition is complete", function()
		assert(type(puzzle.name) == "string" and #puzzle.name > 0, "name")
		assert(table.find({ "Beginner", "Easy", "Medium", "Hard", "Expert" }, puzzle.difficulty), "difficulty")
		eq(puzzle.mode, "EchoClear")
		assert(#puzzle.hints >= 1, "hints")
		assert(puzzle.reward.xp > 0 and puzzle.reward.coins > 0, "reward")
		assert(puzzle.estimatedSeconds > 0, "estimatedSeconds")
		local board = BoardState.fromLayout(puzzle.layout)
		local whites = 0
		for _, piece in pairs(board.pieces) do
			if piece.color == "white" then
				whites += 1
			end
		end
		eq(whites, 1, "exactly one player piece")
		assert(BoardState.countColor(board, "black") >= 1, "has targets")
		assert(
			BoardState.countColor(board, "black") <= PuzzleValidator.MAX_SOLVER_TARGETS,
			"too many targets for the live solver"
		)
	end)

	test("puzzle " .. puzzle.id .. ": stored solution is valid", function()
		local ok, err = PuzzleValidator.validateSolution(puzzle.layout, puzzle.solution)
		assert(ok, err)
	end)

	test("puzzle " .. puzzle.id .. ": solver agrees it is solvable", function()
		eq(PuzzleValidator.isSolvable(BoardState.fromLayout(puzzle.layout)), true)
	end)

	test("puzzle " .. puzzle.id .. ": par equals the true minimum", function()
		eq(PuzzleValidator.minimumMoves(BoardState.fromLayout(puzzle.layout)), puzzle.par)
		eq(#puzzle.solution, puzzle.par, "stored solution is a shortest one")
	end)

	test("puzzle " .. puzzle.id .. ": validator rejects tampered solutions", function()
		local short = table.clone(puzzle.solution)
		table.remove(short)
		eq((PuzzleValidator.validateSolution(puzzle.layout, short)), false, "missing last move")

		local extra = table.clone(puzzle.solution)
		local last = extra[#extra]
		table.insert(extra, { last[2], last[1] })
		eq((PuzzleValidator.validateSolution(puzzle.layout, extra)), false, "move after clear")

		local skipped = table.clone(puzzle.solution)
		table.remove(skipped, 1)
		eq((PuzzleValidator.validateSolution(puzzle.layout, skipped)), false, "first move skipped")

		eq((PuzzleValidator.validateSolution(puzzle.layout, {})), false, "empty solution")
	end)

	test("puzzle " .. puzzle.id .. ": session plays the solution to a win", function()
		local session = PuzzleSession.new(puzzle)
		for i, pair in ipairs(puzzle.solution) do
			eq(session.status, "playing", "status before move " .. i)
			local ok, err = session:tryMove(sq(session.board, pair[1]), sq(session.board, pair[2]))
			assert(ok, err)
		end
		eq(session.status, "won")
		eq(session.moveCount, #puzzle.solution)
		eq(session:targetsLeft(), 0)
	end)
end

test("every puzzle id is unique and lookups work", function()
	local seen = {}
	for _, puzzle in ipairs(PuzzleDefinitions.list) do
		assert(not seen[puzzle.id], "duplicate " .. puzzle.id)
		seen[puzzle.id] = true
		eq(PuzzleDefinitions.get(puzzle.id), puzzle)
	end
	eq(PuzzleDefinitions.get("nope"), nil)
	eq(PuzzleDefinitions.get(42), nil)
	eq(PuzzleDefinitions.nextAfter(PuzzleDefinitions.list[#PuzzleDefinitions.list].id), PuzzleDefinitions.list[1])
end)

test("prototype set uses all six piece types", function()
	local kinds = {}
	for _, puzzle in ipairs(PuzzleDefinitions.list) do
		for _, line in ipairs(puzzle.layout) do
			for ch in string.gmatch(string.upper(line), "[KQRBNP]") do
				kinds[ch] = true
			end
		end
	end
	for _, kind in ipairs({ "K", "Q", "R", "B", "N", "P" }) do
		assert(kinds[kind], "missing " .. kind)
	end
end)

-- Session rules ----------------------------------------------------------------------

local first = assert(PuzzleDefinitions.get("proto-01"))

test("session rejects bad input without changing state", function()
	local session = PuzzleSession.new(first)
	local before = table.concat(BoardState.toLayout(session.board), "/")
	local b = session.board
	local cases = {
		{ nil, nil, "bad_square" },
		{ "a1", "a4", "bad_square" },
		{ 1.5, 2, "bad_square" },
		{ 0, 1, "bad_square" },
		{ 1, 999, "bad_square" },
		{ sq(b, "d4"), sq(b, "d3"), "not_your_piece" }, -- black bishop
		{ sq(b, "b2"), sq(b, "b3"), "not_your_piece" }, -- empty square
		{ sq(b, "a1"), sq(b, "b3"), "illegal_move" }, -- queen cannot jump like a knight
		{ sq(b, "a1"), sq(b, "c1"), "illegal_move" }, -- c1 is blocked
		{ sq(b, "a1"), sq(b, "a1"), "illegal_move" },
	}
	for i, case in ipairs(cases) do
		local ok, err = session:tryMove(case[1], case[2])
		eq(ok, false, "case " .. i)
		eq(err, case[3], "case " .. i)
	end
	eq(table.concat(BoardState.toLayout(session.board), "/"), before)
	eq(session.moveCount, 0)
	eq(#session.history, 0)
end)

test("rook then bishop is a dead end: failure is detected and blocks moves", function()
	-- Winning orders exist after Qxd2, but becoming the bishop next strands you:
	-- a bishop on d4 can never reach the knight on a4 (opposite square colors).
	local session = PuzzleSession.new(first)
	local b = session.board
	assert(session:tryMove(sq(b, "a1"), sq(b, "a2")))
	assert(session:tryMove(sq(b, "a2"), sq(b, "d2"))) -- Qxd2, now a rook
	eq(session.board.pieces[sq(b, "d2")].kind, "R")
	eq(session.status, "playing")
	assert(session:tryMove(sq(b, "d2"), sq(b, "d4"))) -- Rxd4, now a bishop
	eq(session.board.pieces[sq(b, "d4")].kind, "B")
	eq(session.status, "failed")
	local ok, err = session:tryMove(sq(b, "d4"), sq(b, "c3"))
	eq(ok, false)
	eq(err, "not_playing")
	assert(session:undo())
	eq(session.status, "playing", "undo out of a failed position")
	eq(session.board.pieces[sq(b, "d4")].color, "black", "bishop restored")
end)

test("undo and restart", function()
	local session = PuzzleSession.new(first)
	local b = session.board
	eq(session:undo(), false, "nothing to undo")
	assert(session:tryMove(sq(b, "a1"), sq(b, "a4")))
	eq(session.board.pieces[sq(b, "a4")].kind, "N")
	assert(session:undo())
	eq(session.moveCount, 0)
	eq(session.board.pieces[sq(b, "a1")].kind, "Q")
	eq(session.board.pieces[sq(b, "a4")].kind, "N")
	eq(session.board.pieces[sq(b, "a4")].color, "black")
	assert(session:tryMove(sq(b, "a1"), sq(b, "a4")))
	assert(session:tryMove(sq(session.board, "a4"), sq(session.board, "c3")))
	session:restart()
	eq(session.moveCount, 0)
	eq(#session.history, 0)
	eq(session.status, "playing")
	eq(table.concat(BoardState.toLayout(session.board), "/"), table.concat(first.layout, "/"))
end)

test("a won session cannot be undone or moved", function()
	local session = PuzzleSession.new(first)
	for _, pair in ipairs(first.solution) do
		assert(session:tryMove(sq(session.board, pair[1]), sq(session.board, pair[2])))
	end
	eq(session.status, "won")
	eq(session:undo(), false)
	local ok, err = session:tryMove(sq(session.board, "d4"), sq(session.board, "d3"))
	eq(ok, false)
	eq(err, "not_playing")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("test failures")
end
