-- Engine test suite. Run with: python3 tools/run_tests.py path/to/luau
-- `Shared` and `require` are provided by the runner's module shim.

local BoardState = require(Shared.BoardState)
local ChessRules = require(Shared.ChessRules)
local PuzzleValidator = require(Shared.PuzzleValidator)
local PuzzleSession = require(Shared.PuzzleSession)
local PuzzleDefinitions = require(Shared.PuzzleDefinitions)
local ReferenceSolver = require(Shared.ReferenceSolver)
local BoardGen = require(Shared.BoardGen)
local PuzzleCheck = require(Shared.PuzzleCheck)
local GameConfig = require(Shared.GameConfig)

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

-- Solver against the rules and the Phase 2 solver ---------------------------------
-- ReferenceSolver is the original, unoptimised solver kept as an oracle. These
-- tests are the proof that the faster solver kept the exact rules.

local function namesOf(board, moves): { { string } }
	local names = {}
	for _, pair in ipairs(moves) do
		table.insert(names, { BoardState.squareName(board, pair[1]), BoardState.squareName(board, pair[2]) })
	end
	return names
end

local function randomBoard(seed: number): (any, { string })
	local width, height = 2 + seed % 5, 2 + (seed // 5) % 5
	local targets = math.min(1 + seed % 8, width * height - 2)
	local layout = BoardGen.layout(seed, width, height, targets, (seed % 4) * 8)
	return BoardState.fromLayout(layout), layout
end

test("solver move tables match ChessRules for every piece on every square", function()
	for seed = 1, 150 do
		local board = randomBoard(seed)
		local player = assert(BoardState.findPlayer(board))
		board.pieces[player] = nil
		for _, kind in ipairs({ "K", "Q", "R", "B", "N", "P" }) do
			for square = 1, board.width * board.height do
				if not board.pieces[square] and not board.blocked[square] then
					board.pieces[square] = { kind = kind, color = "white" }
					local compiled = PuzzleValidator.compiledMoves(board, square)
					local count = 0
					for _, move in ipairs(ChessRules.getLegalMoves(board, square)) do
						count += 1
						eq(compiled[move.to], move.capture, "seed " .. seed .. " " .. kind)
					end
					local compiledCount = 0
					for _ in pairs(compiled) do
						compiledCount += 1
					end
					eq(compiledCount, count, "move count, seed " .. seed .. " " .. kind)
					board.pieces[square] = nil
				end
			end
		end
	end
end)

test("solver agrees with the Phase 2 solver on 600 random boards", function()
	for seed = 1, 600 do
		local board, layout = randomBoard(seed)
		local result = PuzzleValidator.solve(board)
		eq(result.status == "solved", ReferenceSolver.isSolvable(board), "solvable, seed " .. seed)
		if result.solution then
			local ok, err = PuzzleValidator.validateSolution(layout, namesOf(board, result.solution))
			assert(ok, "seed " .. seed .. ": " .. tostring(err))
		end
	end
end)

test("solver agrees with the Phase 2 solver on larger 8x8 boards", function()
	for seed = 1, 24 do
		local layout = BoardGen.layout(seed * 31 + 5, 8, 8, 9 + seed % 3, 4 + seed % 16)
		local board = BoardState.fromLayout(layout)
		local result = PuzzleValidator.solve(board)
		eq(result.status == "solved", ReferenceSolver.isSolvable(board), "8x8 seed " .. seed)
		if result.solution then
			assert(PuzzleValidator.validateSolution(layout, namesOf(board, result.solution)))
		end
	end
end)

test("shortest solution equals the Phase 2 full-position BFS", function()
	for seed = 1, 600 do
		local board, layout = randomBoard(seed)
		if BoardState.countColor(board, "black") <= 6 then
			local length, moves = PuzzleValidator.shortestSolution(board)
			eq(length, (ReferenceSolver.shortestSolution(board)), "par, seed " .. seed)
			if moves then
				eq(#moves, length)
				assert(PuzzleValidator.validateSolution(layout, namesOf(board, moves)))
			end
		end
	end
end)

test("countOrders matches plain enumeration of capture orders", function()
	-- Unmemoised count straight from the rules: try every capture reachable by
	-- quiet moves, recurse, and count finished and stuck orders.
	local function naive(board, square): (number, number)
		if PuzzleValidator.isCleared(board) then
			return 1, 0
		end
		local kind = board.pieces[square].kind
		local seen, queue, head, from = { [square] = true }, { square }, 1, {}
		local scratch = BoardState.clone(board)
		scratch.pieces[square] = nil
		while head <= #queue do
			local at = queue[head]
			head += 1
			scratch.pieces[at] = { kind = kind, color = "white" }
			for _, move in ipairs(ChessRules.getLegalMoves(scratch, at)) do
				if move.capture then
					from[move.to] = from[move.to] or at
				elseif not seen[move.to] then
					seen[move.to] = true
					table.insert(queue, move.to)
				end
			end
			scratch.pieces[at] = nil
		end
		local wins, stuck, any = 0, 0, false
		for target, at in pairs(from) do
			any = true
			local nextBoard = BoardState.clone(board)
			nextBoard.pieces[square] = nil
			nextBoard.pieces[at] = { kind = kind, color = "white" }
			ChessRules.applyMove(nextBoard, at, target, true)
			local w, s = naive(nextBoard, target)
			wins += w
			stuck += s
		end
		return wins, if any then stuck else 1
	end
	for seed = 1, 300 do
		local board = randomBoard(seed)
		if BoardState.countColor(board, "black") <= 6 then
			local wins, stuck = PuzzleValidator.countOrders(board)
			local expectWins, expectStuck = naive(board, assert(BoardState.findPlayer(board)))
			eq(wins, expectWins, "wins, seed " .. seed)
			eq(stuck, expectStuck, "dead ends, seed " .. seed)
		end
	end
end)

test("a state budget gives 'unknown', never a wrong answer", function()
	local board = BoardState.fromLayout(PuzzleDefinitions.get("medium-02").layout)
	eq(PuzzleValidator.solve(board, { maxStates = 2 }).status, "unknown")
	eq(PuzzleValidator.solve(board, { maxStates = 1000 }).status, "solved")
	for seed = 1, 300 do
		local random = randomBoard(seed)
		local truth = PuzzleValidator.solve(random).status
		local limited = PuzzleValidator.solve(random, { maxStates = 1 }).status
		assert(limited == "unknown" or limited == truth, "seed " .. seed)
	end
end)

test("no target limit: 39 targets solve and replay", function()
	local layout = { "rrrrrrrr", "rrrrrrrr", "rrrrrrrr", "rrrrrrrr", "Rrrrrrrr" }
	local board = BoardState.fromLayout(layout)
	local result = PuzzleValidator.solve(board)
	eq(result.status, "solved")
	assert(PuzzleValidator.validateSolution(layout, namesOf(board, assert(result.solution))))
	-- A second white-free row of knights the rook can never reach: unsolvable.
	local stuck = BoardState.fromLayout({ "n#n#n#n#", "########", "Rrrrrrrr" })
	eq(PuzzleValidator.solve(stuck).status, "unsolvable")
end)

test("session status after every move matches a full solver check", function()
	-- Random play on random boards, with undos. The session skips the solver
	-- after reversible quiet moves and on undo; this checks that shortcut.
	local roll = 12345
	local function nextRoll(n: number): number
		roll = (roll * 48271) % 2147483647
		return roll % n + 1
	end
	for seed = 1, 200 do
		local start, layout = randomBoard(seed)
		-- Shipped puzzles always start solvable (checked above), and the
		-- session relies on that, so only those boards are used here.
		local session = PuzzleSession.new({ layout = layout })
		for _ = 1, if PuzzleValidator.isSolvable(start) then 12 else 0 do
			if session.status == "won" then
				break
			end
			if session.status == "failed" or nextRoll(5) == 1 then
				session:undo()
			else
				local player = assert(BoardState.findPlayer(session.board))
				local moves = ChessRules.getLegalMoves(session.board, player)
				if #moves == 0 then
					break
				end
				local move = moves[nextRoll(#moves)]
				assert(session:tryMove(move.from, move.to))
			end
			local expected = if PuzzleValidator.isCleared(session.board)
				then "won"
				elseif PuzzleValidator.isSolvable(session.board) then "playing"
				else "failed"
			eq(session.status, expected, "seed " .. seed)
		end
	end
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

	test("puzzle " .. puzzle.id .. ": PuzzleCheck finds no problems", function()
		local problems = PuzzleCheck.check(puzzle)
		assert(#problems == 0, table.concat(problems, "; "))
	end)

	test("puzzle " .. puzzle.id .. ": the Phase 2 solver independently agrees", function()
		local board = BoardState.fromLayout(puzzle.layout)
		eq(ReferenceSolver.isSolvable(board), true)
		if BoardState.countColor(board, "black") <= 6 then
			eq((ReferenceSolver.shortestSolution(board)), puzzle.par, "par by full-position BFS")
		end
	end)
end

test("catalogue: 6 puzzles per difficulty, in difficulty order, no repeats", function()
	local problems = PuzzleCheck.checkCatalog(PuzzleDefinitions.list)
	assert(#problems == 0, table.concat(problems, "; "))
	eq(#PuzzleDefinitions.list, 30)
	for index, difficulty in ipairs(GameConfig.DIFFICULTIES) do
		local group = PuzzleDefinitions.byDifficulty[difficulty]
		eq(#group, 6, difficulty)
		for number, puzzle in ipairs(group) do
			eq(puzzle.difficultyIndex, index)
			eq(puzzle.number, number)
		end
	end
	local lastIndex = 0
	for _, puzzle in ipairs(PuzzleDefinitions.list) do
		assert(puzzle.difficultyIndex >= lastIndex, "list is not in difficulty order")
		lastIndex = puzzle.difficultyIndex
	end
end)

test("PuzzleCheck catches broken puzzles", function()
	local good = assert(PuzzleDefinitions.get("easy-02"))
	local function broken(change: (any) -> ()): { string }
		local copy = table.clone(good)
		change(copy)
		return PuzzleCheck.check(copy)
	end
	assert(#broken(function(p)
		p.solution = table.move(good.solution, 1, #good.solution - 1, 1, {})
		p.par = #p.solution
	end) > 0, "short solution")
	assert(#broken(function(p)
		p.solution = table.clone(good.solution)
		p.solution[1] = { p.solution[1][1], "a5" }
	end) > 0, "illegal first move")
	assert(#broken(function(p)
		p.par = good.par + 1
	end) > 0, "wrong par")
	assert(#broken(function(p)
		p.difficulty = "Expert"
	end) > 0, "wrong difficulty band")
	assert(#broken(function(p)
		p.hints = { "Go c1 c2 c3 then win.", "x" }
	end) > 0, "hint giving away squares")
	assert(#broken(function(p)
		p.layout = { "Q...", "....", "....", "...Q" }
	end) > 0, "two player pieces")
	assert(#broken(function(p)
		p.layout = { "P", "r" }
		p.solution = { { "a2", "a1" } }
		p.par = 1
	end) > 0, "unsolvable layout")
end)

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

test("catalogue uses all six piece types", function()
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

local first = assert(PuzzleDefinitions.get("beginner-04")) -- "First Echo", the Phase 2 opener

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

-- Progression -----------------------------------------------------------------------

local Progression = require(Shared.Progression)
local PuzzleHints = require(Shared.PuzzleHints)
local ProfileStore = require(Shared.ProfileStore)
local FakeStore = require(Shared.FakeStore)
local MODES = GameConfig.PLAY_MODES

local nextOpId = 0
local function opId(): string
	nextOpId += 1
	return "op-" .. nextOpId
end

local function win(puzzleId: string, mode: string, day: number?): any
	return { id = opId(), kind = "win", puzzleId = puzzleId, mode = mode, moves = 10, seconds = 30, day = day }
end

test("journey unlocks the next difficulty after enough credited clears", function()
	local profile = Progression.newProfile()
	eq(Progression.unlockedIndex(profile), 1)
	local easy = PuzzleDefinitions.byDifficulty.Easy[1]
	eq(select(2, Progression.canStart(profile, easy, MODES.Journey, 1)), "locked")
	eq((Progression.canStart(profile, easy, MODES.Practice, 1)), true, "practice ignores locks")
	-- Practice clears never count towards unlocks.
	for i = 1, 6 do
		Progression.apply(profile, win(PuzzleDefinitions.byDifficulty.Beginner[i].id, MODES.Practice))
	end
	eq(Progression.unlockedIndex(profile), 1)
	for i = 1, GameConfig.UNLOCK_REQUIREMENT - 1 do
		Progression.apply(profile, win(PuzzleDefinitions.byDifficulty.Beginner[i].id, MODES.Journey))
	end
	eq(Progression.unlockedIndex(profile), 1, "one short")
	Progression.apply(profile, win(PuzzleDefinitions.byDifficulty.Beginner[6].id, MODES.Journey))
	eq(Progression.unlockedIndex(profile), 2)
	eq((Progression.canStart(profile, easy, MODES.Journey, 1)), true)
	local medium = PuzzleDefinitions.byDifficulty.Medium[1]
	eq(select(2, Progression.canStart(profile, medium, MODES.Journey, 1)), "locked", "still sequential")
	eq(select(2, Progression.canStart(profile, easy, "Ranked", 1)), "bad_mode")
end)

test("journey reward is paid once per puzzle, practice pays nothing", function()
	local profile = Progression.newProfile()
	local puzzle = PuzzleDefinitions.list[1]
	local _, reward = Progression.apply(profile, win(puzzle.id, MODES.Practice))
	eq(reward, nil)
	local _, first = Progression.apply(profile, win(puzzle.id, MODES.Journey))
	eq(first.xp, puzzle.reward.xp)
	local _, again = Progression.apply(profile, win(puzzle.id, MODES.Journey))
	eq(again, nil, "second clear")
	eq(profile.xp, puzzle.reward.xp)
	eq(profile.coins, puzzle.reward.coins)
	eq(profile.completed[puzzle.id].solves, 3)
	eq(profile.stats.solves, 3)
end)

test("the same op applied twice only counts once", function()
	local profile = Progression.newProfile()
	local op = win(PuzzleDefinitions.list[1].id, MODES.Journey)
	eq((Progression.apply(profile, op)), true)
	eq((Progression.apply(profile, op)), false)
	eq(profile.stats.solves, 1)
end)

test("daily puzzle: one reward and one hint per day, reset the next day", function()
	local day = 20386
	local daily = Progression.dailyPuzzle(day)
	assert(table.find(GameConfig.DAILY_DIFFICULTIES, daily.difficulty), "daily comes from the daily pool")
	assert(Progression.dailyPuzzle(day + 1) ~= daily, "a new puzzle each day")
	local profile = Progression.newProfile()
	eq(select(2, Progression.canStart(profile, PuzzleDefinitions.list[1], MODES.Daily, day)), "not_daily")
	eq((Progression.canStart(profile, daily, MODES.Daily, day)), true)
	eq(Progression.hintsLeft(profile, MODES.Daily, 0, day), 1)
	Progression.apply(profile, { id = opId(), kind = "hint", mode = MODES.Daily, day = day })
	eq(Progression.hintsLeft(profile, MODES.Daily, 0, day), 0, "used today, even in a new attempt")
	local _, reward = Progression.apply(profile, win(daily.id, MODES.Daily, day))
	eq(reward.xp, GameConfig.DAILY_REWARD.xp)
	local _, again = Progression.apply(profile, win(daily.id, MODES.Daily, day))
	eq(again, nil, "second daily clear the same day")
	eq(profile.xp, GameConfig.DAILY_REWARD.xp)
	-- A late op from yesterday must not touch today's state.
	local tomorrow = day + 1
	eq(Progression.hintsLeft(profile, MODES.Daily, 0, tomorrow), 1, "new day, new hint")
	local _, next = Progression.apply(profile, win(Progression.dailyPuzzle(tomorrow).id, MODES.Daily, tomorrow))
	eq(next.xp, GameConfig.DAILY_REWARD.xp, "tomorrow pays again")
	local _, late = Progression.apply(profile, win(daily.id, MODES.Daily, day))
	eq(late, nil, "a late op for yesterday pays nothing")
	eq(profile.daily.day, tomorrow)
	-- Daily clears count towards unlocks.
	assert(profile.completed[daily.id].credited)
end)

test("hint allowances: unlimited in journey and practice", function()
	local profile = Progression.newProfile()
	eq(Progression.hintsLeft(profile, MODES.Practice, 10, 1), math.huge)
	eq(Progression.hintsLeft(profile, MODES.Journey, 10, 1), math.huge)
	eq(Progression.hintsLeft(profile, "Ranked", 0, 1), 0, "unknown or competitive modes get none")
end)

test("damaged stored data is normalised, not trusted", function()
	local profile = Progression.normalize({
		xp = "lots",
		coins = 0 / 0,
		completed = { ["beginner-01"] = { bestMoves = 3, credited = true }, [5] = {}, bad = "x" },
		rewards = { ["journey:x"] = true, y = 1 },
		applied = { "a", 5 },
		stats = { solves = 2, fails = "x" },
	})
	eq(profile.xp, 0)
	eq(profile.coins, 0)
	eq(profile.completed["beginner-01"].bestMoves, 3)
	eq(profile.completed.bad, nil)
	eq(profile.rewards.y, nil)
	eq(#profile.applied, 1)
	eq(profile.stats.solves, 2)
	eq(profile.stats.fails, 0)
	eq(Progression.normalize(nil).version, Progression.VERSION)
end)

-- ProfileStore -------------------------------------------------------------------------

local function makeStore(store: any, logLines: { string }?)
	local clock = { t = 0 }
	local deps = {
		store = store,
		progression = Progression,
		now = function()
			return clock.t
		end,
		wait = function(seconds: number)
			clock.t += seconds
		end,
		newId = opId,
		log = function(line: string)
			if logLines then
				table.insert(logLines, line)
			end
		end,
	}
	return ProfileStore.new(deps), clock, deps
end

test("profile store: load, record, save round trip", function()
	local store = FakeStore.new()
	local profiles = makeStore(store)
	profiles:load(1)
	eq(profiles:status(1), "ok")
	local puzzle = PuzzleDefinitions.list[1]
	local reward = profiles:record(1, win(puzzle.id, MODES.Journey))
	eq(reward.xp, puzzle.reward.xp)
	eq(profiles:pendingCount(1), 1)
	assert(profiles:save(1))
	eq(profiles:pendingCount(1), 0)
	eq(store.data.player_1.xp, puzzle.reward.xp)
	-- A fresh server sees the same profile.
	local other = makeStore(store)
	eq(other:load(1).xp, puzzle.reward.xp)
end)

test("profile store: failed load plays offline, then the first save heals it", function()
	local store = FakeStore.new()
	store.data.player_2 = { xp = 500, coins = 40, rewards = { ["journey:beginner-01"] = true } }
	store.failGets = 99
	local logLines = {}
	local profiles = makeStore(store, logLines)
	local profile = profiles:load(2)
	eq(profiles:status(2), "offline")
	eq(profile.xp, 0, "blank view while offline")
	assert(#logLines >= ProfileStore.LOAD_ATTEMPTS, "each failed attempt is logged")
	-- The offline view thinks beginner-01 has no reward yet...
	local shown = profiles:record(2, win("beginner-01", MODES.Journey))
	assert(shown ~= nil)
	assert(profiles:save(2))
	eq(profiles:status(2), "ok")
	-- ...but the stored ledger wins: no double reward, nothing lost.
	eq(store.data.player_2.xp, 500)
	eq(store.data.player_2.coins, 40)
	eq(profiles:get(2).xp, 500, "view replaced by the merged profile")
	eq(store.data.player_2.completed["beginner-01"].solves, 1)
end)

test("profile store: a save that wrote but reported an error is not applied twice", function()
	local store = FakeStore.new()
	local profiles = makeStore(store)
	profiles:load(3)
	profiles:record(3, win("beginner-02", MODES.Journey))
	store.commitThenFail = 1
	assert(profiles:save(3), "the retry succeeds")
	eq(store.writes, 2, "written twice")
	eq(store.data.player_3.stats.solves, 1, "but counted once")
	eq(store.data.player_3.xp, PuzzleDefinitions.get("beginner-02").reward.xp)
end)

test("profile store: two servers saving the same player never double-pay", function()
	local store = FakeStore.new()
	local a = makeStore(store)
	local b = makeStore(store)
	a:load(4)
	b:load(4)
	local id = "beginner-03"
	assert(a:record(4, win(id, MODES.Journey)) ~= nil)
	assert(b:record(4, win(id, MODES.Journey)) ~= nil, "each server's view pays")
	assert(a:save(4))
	assert(b:save(4))
	local reward = PuzzleDefinitions.get(id).reward
	eq(store.data.player_4.xp, reward.xp, "the store pays once")
	eq(store.data.player_4.stats.solves, 2, "both clears are counted")
	eq(b:get(4).xp, reward.xp, "b's view corrected after its save")
end)

test("profile store: concurrent write between read and save is merged", function()
	local store = FakeStore.new()
	local profiles = makeStore(store)
	profiles:load(5)
	profiles:record(5, win("beginner-01", MODES.Journey))
	store.beforeUpdate = function(key)
		-- Another server writes a different clear first.
		store.data[key] = { completed = { ["beginner-05"] = { bestMoves = 6, solves = 1, credited = true } } }
	end
	assert(profiles:save(5))
	assert(store.data.player_5.completed["beginner-01"])
	assert(store.data.player_5.completed["beginner-05"], "the other server's write survives")
end)

test("profile store: failed saves keep ops queued and leave stored data alone", function()
	local store = FakeStore.new()
	local profiles = makeStore(store)
	profiles:load(6)
	assert(profiles:save(6))
	profiles:record(6, win("beginner-01", MODES.Journey))
	store.failUpdates = ProfileStore.SAVE_ATTEMPTS
	eq(profiles:save(6), false)
	eq(profiles:pendingCount(6), 1)
	eq(store.data.player_6, nil, "nothing written")
	eq(profiles.failedSaves, 1)
	assert(profiles:save(6), "next save gets through")
	eq(profiles:pendingCount(6), 0)
	eq(store.data.player_6.stats.solves, 1)
end)

test("profile store: writes to one key are spaced out", function()
	local store = FakeStore.new()
	local profiles, clock = makeStore(store)
	profiles:load(7)
	profiles:record(7, win("beginner-01", MODES.Journey))
	assert(profiles:save(7))
	local firstWrite = clock.t
	profiles:record(7, win("beginner-02", MODES.Journey))
	assert(profiles:save(7))
	assert(clock.t - firstWrite >= ProfileStore.MIN_SAVE_INTERVAL, "second write waited")
end)

test("profile store: waits for request budget before calling", function()
	local store = FakeStore.new()
	local profiles, clock, deps = makeStore(store)
	local budget = 0
	deps.budget = function()
		budget += 0.25
		return budget
	end
	profiles:load(8)
	assert(clock.t >= 3, "waited for budget")
	eq(store.gets, 1)
end)

test("profile store: leaving saves with extra retries", function()
	local store = FakeStore.new()
	local profiles = makeStore(store)
	profiles:load(9)
	profiles:record(9, win("beginner-01", MODES.Journey))
	store.failUpdates = ProfileStore.FINAL_SAVE_ATTEMPTS - 1
	assert(profiles:release(9))
	eq(store.data.player_9.stats.solves, 1)
	eq(profiles:get(9), nil, "forgotten after leaving")
end)

test("profile store: a permanent DataStore error stops further calls", function()
	local store = FakeStore.new()
	store.GetAsync = function()
		error("502: API Services rejected request with error. Error code: 7 Reason: Studio access to APIs is not allowed.")
	end
	local profiles = makeStore(store)
	profiles:load(10)
	eq(profiles:status(10), "offline")
	assert(profiles.disabled, "store disabled after the first permanent error")
	profiles:record(10, win("beginner-01", MODES.Journey))
	eq(profiles:save(10), false)
	eq(store.writes, 0, "no write attempted")
	eq(profiles:get(10).stats.solves, 1, "play continues in memory")
end)

-- Hints ---------------------------------------------------------------------------------

test("hints: written hints first, then a live hint naming a target", function()
	for _, puzzle in ipairs(PuzzleDefinitions.list) do
		local board = BoardState.fromLayout(puzzle.layout)
		eq(PuzzleHints.forLevel(puzzle, board, "playing", 1), puzzle.hints[1])
		eq(PuzzleHints.forLevel(puzzle, board, "playing", 2), puzzle.hints[2])
		local live = PuzzleHints.forLevel(puzzle, board, "playing", 3)
		local name = assert(string.match(live, "on (%l%d) next%.$"), puzzle.id .. ": " .. live)
		local target = assert(BoardState.parseSquare(board, name))
		assert(board.pieces[target] and board.pieces[target].color == "black", puzzle.id .. " names a target")
	end
	local stuck = BoardState.fromLayout({ "P", "r" })
	assert(string.find(PuzzleHints.forLevel({ hints = { "a", "b" } }, stuck, "failed", 1), "Undo"))
end)

test("hints: a live hint is a capture some solution makes next", function()
	-- After a couple of solution moves, the live hint must still lead to a win.
	for _, puzzle in ipairs(PuzzleDefinitions.list) do
		local session = PuzzleSession.new(puzzle)
		for i = 1, math.min(2, #puzzle.solution - 1) do
			assert(session:tryMove(sq(session.board, puzzle.solution[i][1]), sq(session.board, puzzle.solution[i][2])))
		end
		local live = PuzzleHints.forLevel(puzzle, session.board, session.status, 3)
		local name = string.match(live, "on (%l%d) next%.$")
		if name then
			local target = sq(session.board, name)
			-- Remove the target as if captured and become it; still solvable.
			local board = BoardState.clone(session.board)
			local player = assert(BoardState.findPlayer(board))
			board.pieces[target] = { kind = board.pieces[target].kind, color = "white" }
			board.pieces[player] = nil
			eq(PuzzleValidator.isSolvable(board), true, puzzle.id)
		end
	end
end)

-- Phase 4: stars, achievements, streaks, resume, settings -------------------------------

local Achievements = require(Shared.Achievements)

local function winIn(puzzleId: string, mode: string, moves: number, day: number?): any
	return { id = opId(), kind = "win", puzzleId = puzzleId, mode = mode, moves = moves, seconds = 30, day = day }
end

local function clearAll(profile: any, difficulty: string, mode: string)
	for _, puzzle in ipairs(PuzzleDefinitions.byDifficulty[difficulty]) do
		Progression.apply(profile, winIn(puzzle.id, mode, puzzle.par))
	end
end

test("stars: 3 within par, 2 within the difficulty's slack, 1 beyond", function()
	for _, puzzle in ipairs(PuzzleDefinitions.list) do
		local slack = GameConfig.STAR_SLACK[puzzle.difficulty]
		assert(slack and slack >= 1, "slack for " .. puzzle.difficulty)
		eq(Progression.starsFor(puzzle, puzzle.par), 3, puzzle.id)
		eq(Progression.starsFor(puzzle, puzzle.par + 1), 2, puzzle.id)
		eq(Progression.starsFor(puzzle, puzzle.par + slack), 2, puzzle.id)
		eq(Progression.starsFor(puzzle, puzzle.par + slack + 1), 1, puzzle.id)
		eq(Progression.starsFor(puzzle, puzzle.par + slack + 1), Progression.starsFor(puzzle, puzzle.par + slack + 1), "deterministic")
	end
	local custom = table.clone(PuzzleDefinitions.list[1]) :: any
	custom.twoStarMoves = custom.par + 10
	eq(Progression.starsFor(custom, custom.par + 10), 2, "per-puzzle override")
	eq(Progression.starsFor(custom, custom.par + 11), 1)
end)

test("stars: best rating is kept, saved only from Journey and Daily, and replays pay nothing", function()
	local profile = Progression.newProfile()
	local puzzle = PuzzleDefinitions.byDifficulty.Beginner[2]
	Progression.apply(profile, winIn(puzzle.id, MODES.Practice, puzzle.par))
	eq(profile.completed[puzzle.id].stars, 0, "practice saves no stars")
	local _, first = Progression.apply(profile, winIn(puzzle.id, MODES.Journey, puzzle.par + 50))
	eq(profile.completed[puzzle.id].stars, 1)
	eq(first.coins, puzzle.reward.coins)
	local _, better = Progression.apply(profile, winIn(puzzle.id, MODES.Journey, puzzle.par))
	eq(profile.completed[puzzle.id].stars, 3, "improved")
	eq(better, nil, "a better replay pays nothing")
	Progression.apply(profile, winIn(puzzle.id, MODES.Journey, puzzle.par + 50))
	eq(profile.completed[puzzle.id].stars, 3, "a worse replay keeps the best")
	eq(profile.coins, puzzle.reward.coins)
end)

test("stars: hints never lower the rating", function()
	local profile = Progression.newProfile()
	local puzzle = PuzzleDefinitions.byDifficulty.Beginner[3]
	for _ = 1, 5 do
		Progression.apply(profile, { id = opId(), kind = "hint", puzzleId = puzzle.id, mode = MODES.Journey })
	end
	Progression.apply(profile, winIn(puzzle.id, MODES.Journey, puzzle.par))
	eq(profile.completed[puzzle.id].stars, 3)
	eq(profile.stats.hints, 5)
end)

test("achievements: paid once, never from Practice, never twice for the same op", function()
	local profile = Progression.newProfile()
	clearAll(profile, "Beginner", MODES.Practice)
	eq(profile.rewards[Achievements.rewardKey("beginner_clear")], nil, "practice clears don't count")
	eq(profile.coins, 0)
	local beginners = PuzzleDefinitions.byDifficulty.Beginner
	for i = 1, #beginners - 1 do
		Progression.apply(profile, winIn(beginners[i].id, MODES.Journey, beginners[i].par))
	end
	local last = winIn(beginners[#beginners].id, MODES.Journey, beginners[#beginners].par)
	local _, reward = Progression.apply(profile, last)
	local paid = 0
	for _, item in ipairs(reward.items) do
		if item.achievement == "beginner_clear" then
			paid += item.coins
		end
	end
	eq(paid, Achievements.byId.beginner_clear.coins)
	eq(reward.coins, beginners[#beginners].reward.coins + paid, "items add up")
	local coins = profile.coins
	Progression.apply(profile, last)
	clearAll(profile, "Beginner", MODES.Journey)
	eq(profile.coins, coins, "replays and repeated ops pay nothing more")
	local expected = 0
	for _, puzzle in ipairs(beginners) do
		expected += puzzle.reward.coins
	end
	eq(profile.coins, expected + paid)
end)

test("achievements: two servers paying the same achievement store it once", function()
	local store = FakeStore.new()
	local a = makeStore(store)
	local b = makeStore(store)
	a:load(40)
	b:load(40)
	local beginners = PuzzleDefinitions.byDifficulty.Beginner
	for _, profiles in ipairs({ a, b }) do
		for _, puzzle in ipairs(beginners) do
			profiles:record(40, winIn(puzzle.id, MODES.Journey, puzzle.par))
		end
	end
	assert(a:save(40))
	assert(b:save(40))
	local expected = Achievements.byId.beginner_clear.coins
	for _, puzzle in ipairs(beginners) do
		expected += puzzle.reward.coins
	end
	eq(store.data.player_40.coins, expected)
	eq(store.data.player_40.stats.solves, 12)
end)

test("every achievement can be reached and has coins", function()
	local profile = Progression.newProfile()
	for _, difficulty in ipairs(GameConfig.DIFFICULTIES) do
		clearAll(profile, difficulty, MODES.Journey)
	end
	local day = 30000
	for i = 0, 9 do
		Progression.apply(profile, winIn(Progression.dailyPuzzle(day + i).id, MODES.Daily, 99, day + i))
	end
	for _, achievement in ipairs(Achievements.list) do
		assert(achievement.coins > 0, achievement.id)
		assert(profile.rewards[Achievements.rewardKey(achievement.id)], "not reached: " .. achievement.id)
	end
end)

local function daily(profile: any, day: number): any
	local _, reward = Progression.apply(profile, winIn(Progression.dailyPuzzle(day).id, MODES.Daily, 30, day))
	return reward
end

test("streak: consecutive days count, replays and late ops do not", function()
	local profile = Progression.newProfile()
	local day = 20400
	eq(Progression.streakView(profile, day).current, 0)
	daily(profile, day)
	daily(profile, day + 1)
	eq(profile.streak.current, 2)
	eq(daily(profile, day + 1), nil, "same-day replay pays nothing")
	eq(profile.streak.current, 2, "same-day replay doesn't count")
	daily(profile, day) -- a late op for an earlier day
	eq(profile.streak.current, 2)
	eq(profile.stats.dailies, 2)
	local op = winIn(Progression.dailyPuzzle(day + 2).id, MODES.Daily, 30, day + 2)
	Progression.apply(profile, op)
	Progression.apply(profile, op)
	eq(profile.streak.current, 3, "a doubled op counts once")
	eq(profile.streak.longest, 3)
end)

test("streak: the shield covers one missed day once per rolling 7 days", function()
	local profile = Progression.newProfile()
	local day = 20500
	daily(profile, day)
	daily(profile, day + 1)
	local view = Progression.streakView(profile, day + 3)
	eq(view.current, 2, "yesterday missed, streak still alive")
	eq(view.atRisk, true)
	eq(view.shieldReady, true)
	-- Miss day+2, clear day+3: the shield is used.
	local reward = daily(profile, day + 3)
	eq(reward.items[1].reason, "daily puzzle", "only today's reward")
	eq(profile.streak.current, 3)
	eq(profile.streak.shieldUsedOn, day + 3)
	eq(profile.streak.protectedDay, day + 2)
	eq(profile.daily.day, day + 3)
	eq(profile.stats.dailies, 3, "the missed day is not counted as cleared")
	eq(profile.xp, 3 * GameConfig.DAILY_REWARD.xp, "the missed day paid nothing")
	-- A second miss inside the same 7 days breaks the streak.
	eq(Progression.streakView(profile, day + 5).shieldReady, false)
	eq(Progression.streakView(profile, day + 5).current, 0, "no shield: broken")
	daily(profile, day + 5)
	eq(profile.streak.current, 1, "reset")
	eq(profile.streak.longest, 3)
	eq(profile.streak.shieldUsedOn, day + 3, "no second shield")
	-- Seven days after the shield was used, a new one is ready.
	for d = day + 6, day + 9 do
		daily(profile, d)
	end
	eq(Progression.streakView(profile, day + 9).shieldReady, false, "day+9 is 6 days after")
	eq(Progression.streakView(profile, day + 10).shieldReady, true, "day+10 is 7 days after")
	daily(profile, day + 11) -- missed day+10
	eq(profile.streak.current, 6, "second shield, a week later")
	eq(profile.streak.shieldUsedOn, day + 11)
end)

test("streak: two missed days always reset, and a fresh start has nothing to shield", function()
	local profile = Progression.newProfile()
	local day = 20600
	daily(profile, day)
	daily(profile, day + 1)
	eq(Progression.streakView(profile, day + 4).current, 0)
	daily(profile, day + 4)
	eq(profile.streak.current, 1)
	eq(profile.streak.shieldUsedOn < 0, true, "the shield was not spent on a lost streak")
	local fresh = Progression.newProfile()
	daily(fresh, day + 2)
	eq(fresh.streak.current, 1)
	eq(fresh.streak.shieldUsedOn < 0, true)
end)

test("streak: practice and journey clears of the daily puzzle don't count", function()
	local profile = Progression.newProfile()
	local day = 20700
	local puzzle = Progression.dailyPuzzle(day)
	Progression.apply(profile, winIn(puzzle.id, MODES.Practice, 30, day))
	Progression.apply(profile, winIn(puzzle.id, MODES.Journey, 30, day))
	eq(profile.streak.current, 0)
	eq(profile.stats.dailies, 0)
	-- A Daily op naming another puzzle is ignored.
	Progression.apply(profile, winIn(PuzzleDefinitions.list[1].id, MODES.Daily, 30, day))
	eq(profile.streak.current, 0)
end)

test("resume: Continue opens the next unsolved unlocked Journey puzzle", function()
	local profile = Progression.newProfile()
	local list = PuzzleDefinitions.list
	eq(Progression.nextJourneyPuzzle(profile).id, list[1].id, "new player")
	Progression.apply(profile, winIn(list[1].id, MODES.Journey, 3))
	Progression.apply(profile, winIn(list[2].id, MODES.Journey, 4))
	eq(Progression.nextJourneyPuzzle(profile).id, list[3].id)
	-- Skipping ahead resumes after the latest clear, then wraps to what was skipped.
	Progression.apply(profile, winIn(list[5].id, MODES.Journey, 6))
	eq(Progression.nextJourneyPuzzle(profile).id, list[6].id)
	Progression.apply(profile, winIn(list[6].id, MODES.Journey, 6))
	eq(Progression.unlockedIndex(profile), 2, "4 clears unlock Easy")
	eq(Progression.nextJourneyPuzzle(profile).id, list[7].id, "on into Easy")
	-- Practice clears neither move Continue nor count as done.
	Progression.apply(profile, winIn(list[7].id, MODES.Practice, 6))
	eq(Progression.nextJourneyPuzzle(profile).id, list[7].id)
	-- Locked difficulties are never offered.
	local fresh = Progression.newProfile()
	for _, puzzle in ipairs(PuzzleDefinitions.byDifficulty.Beginner) do
		if puzzle.number <= 3 then
			Progression.apply(fresh, winIn(puzzle.id, MODES.Journey, 9))
		end
	end
	fresh.lastJourney = list[3].id
	eq(Progression.nextJourneyPuzzle(fresh).id, list[4].id)
	local done = Progression.newProfile()
	for _, difficulty in ipairs(GameConfig.DIFFICULTIES) do
		clearAll(done, difficulty, MODES.Journey)
	end
	eq(Progression.nextJourneyPuzzle(done), nil, "everything cleared")
end)

test("unlock progress counts credited clears per difficulty", function()
	local profile = Progression.newProfile()
	local beginners = PuzzleDefinitions.byDifficulty.Beginner
	for i = 1, 3 do
		Progression.apply(profile, winIn(beginners[i].id, MODES.Journey, 9))
	end
	Progression.apply(profile, winIn(beginners[4].id, MODES.Practice, 9))
	local rows = Progression.unlockProgress(profile)
	eq(#rows, #GameConfig.DIFFICULTIES)
	eq(rows[1].credited, 3)
	eq(rows[1].required, GameConfig.UNLOCK_REQUIREMENT)
	eq(rows[1].unlocked, true)
	eq(rows[2].unlocked, false)
	Progression.apply(profile, winIn(beginners[4].id, MODES.Journey, 9))
	eq(Progression.unlockProgress(profile)[2].unlocked, true)
end)

test("settings: valid values are stored, junk is ignored", function()
	local profile = Progression.newProfile()
	eq(profile.settings.sound, GameConfig.DEFAULT_SETTINGS.sound)
	Progression.apply(profile, { id = opId(), kind = "settings", settings = { sound = false, volume = 0.33, haptics = false } })
	eq(profile.settings.sound, false)
	eq(profile.settings.volume, 0.35, "rounded to 5% steps")
	eq(profile.settings.haptics, false)
	Progression.apply(profile, { id = opId(), kind = "settings", settings = { sound = "yes", volume = 7, extra = 1 } })
	eq(profile.settings.sound, false)
	eq(profile.settings.volume, 1, "clamped")
	eq((profile.settings :: any).extra, nil)
	Progression.apply(profile, { id = opId(), kind = "settings", settings = { volume = 0 / 0 } })
	eq(profile.settings.volume, 1, "NaN ignored")
	Progression.apply(profile, { id = opId(), kind = "settings", settings = "loud" })
	eq(profile.settings.volume, 1)
end)

test("phase 3 profiles load with the new fields defaulted", function()
	local old = {
		version = 1,
		completed = { ["beginner-01"] = { bestMoves = 3, bestSeconds = 20, solves = 2, credited = true } },
		stats = { solves = 2, fails = 1, restarts = 0, hints = 0, moves = 6 },
		xp = 20,
		coins = 5,
		rewards = { ["journey:beginner-01"] = true },
		daily = { day = 20000, completed = true, hintUsed = false, rewarded = true },
		applied = { "x" },
	}
	local profile = Progression.normalize(old)
	eq(profile.completed["beginner-01"].stars, 0, "no stars until replayed")
	eq(profile.stats.dailies, 0)
	eq(profile.streak.current, 0)
	eq(profile.lastJourney, nil)
	eq(profile.settings.volume, GameConfig.DEFAULT_SETTINGS.volume)
	eq(profile.cosmetics.equipped.board, GameConfig.COSMETIC_SLOTS.board)
	eq(profile.xp, 20)
	eq(Progression.nextJourneyPuzzle(profile).id, "beginner-02")
	local damaged = Progression.normalize({
		completed = { ["beginner-01"] = { stars = 9, credited = true }, ["beginner-02"] = { stars = 3 } },
		streak = { current = "many", longest = -4, lastDay = 1.5, shieldUsedOn = "x" },
		lastJourney = "nope",
		settings = { volume = "max" },
		cosmetics = { owned = { gold = true, bad = 1 }, equipped = { board = "gold", pieces = "stolen" } },
	})
	eq(damaged.completed["beginner-01"].stars, 3, "clamped")
	eq(damaged.completed["beginner-02"].stars, 0, "uncredited records hold no stars")
	eq(damaged.streak.current, 0)
	eq(damaged.streak.longest, 0)
	eq(damaged.streak.lastDay, 1)
	eq(damaged.lastJourney, nil)
	eq(damaged.cosmetics.equipped.board, "gold", "owned item")
	eq(damaged.cosmetics.equipped.pieces, GameConfig.COSMETIC_SLOTS.pieces, "unowned item refused")
	eq(damaged.cosmetics.owned.bad, nil)
end)

test("summary carries what the menus draw", function()
	local profile = Progression.newProfile()
	local puzzle = PuzzleDefinitions.list[1]
	Progression.apply(profile, winIn(puzzle.id, MODES.Journey, puzzle.par))
	local summary = Progression.summary(profile, 20800)
	eq(summary.resumeId, PuzzleDefinitions.list[2].id)
	eq(summary.completed[puzzle.id].stars, 3)
	eq(summary.completed[puzzle.id].bestSeconds, 30)
	eq(summary.totals.cleared, 1)
	eq(summary.totals.stars, 3)
	eq(summary.totals.maxStars, 90)
	eq(summary.totals.perfect, 1)
	eq(#summary.unlocks, 5)
	eq(summary.streak.current, 0)
	eq(summary.stats.dailies, 0)
	eq(summary.settings.sound, true)
	eq(next(summary.achievements), nil)
end)

-- Phase 5: input rules, tutorial flow, tutorial progress -----------------------

local InputRules = require(Shared.InputRules)
local TutorialFlow = require(Shared.TutorialFlow)

test("squareAt maps board fractions to squares", function()
	local board = BoardState.fromLayout(EMPTY8)
	eq(InputRules.squareAt(board, 0, 0), sq(board, "a8"), "top-left")
	eq(InputRules.squareAt(board, 0.999, 0.999), sq(board, "h1"), "bottom-right")
	eq(InputRules.squareAt(board, 0.125, 0.875), sq(board, "b1"), "a cell edge belongs to the next cell")
	eq(InputRules.squareAt(board, 0.5, 0.5), sq(board, "e4"))
	local small = BoardState.fromLayout({ "..r.", "#.r.", ".kQ.", "...." })
	eq(InputRules.squareAt(small, 0.6, 0.6), sq(small, "c2"), "4x4 board")
end)

test("squareAt rejects points off the board", function()
	local board = BoardState.fromLayout(EMPTY8)
	eq(InputRules.squareAt(board, -0.01, 0.5), nil)
	eq(InputRules.squareAt(board, 0.5, -0.01), nil)
	eq(InputRules.squareAt(board, 1, 0.5), nil, "right edge")
	eq(InputRules.squareAt(board, 0.5, 1), nil, "bottom edge")
	eq(InputRules.squareAt(board, 0 / 0, 0.5), nil, "NaN")
	eq(InputRules.squareAt(board, math.huge, 0.5), nil, "inf")
end)

test("isDrag uses the pixel threshold", function()
	local t = InputRules.DRAG_THRESHOLD
	eq(InputRules.isDrag(0, 0), false)
	eq(InputRules.isDrag(t - 1, 0), false)
	eq(InputRules.isDrag(6, 6), false, "8.5 px diagonal")
	eq(InputRules.isDrag(t, 0), true)
	eq(InputRules.isDrag(-8, -8), true, "11.3 px diagonal")
end)

test("needsConfirm only guards an attempt with moves", function()
	eq(InputRules.needsConfirm(nil), false)
	eq(InputRules.needsConfirm({ status = "playing", moveCount = 0 }), false, "nothing to lose")
	eq(InputRules.needsConfirm({ status = "playing" }), false)
	eq(InputRules.needsConfirm({ status = "playing", moveCount = 2 }), true)
	eq(InputRules.needsConfirm({ status = "won", moveCount = 3 }), false, "finished")
	eq(InputRules.needsConfirm({ status = "failed", moveCount = 3 }), false, "already lost")
end)

test("tutorial puzzle exists and fits the steps", function()
	local puzzle = assert(PuzzleDefinitions.get(TutorialFlow.PUZZLE_ID))
	eq(puzzle.difficulty, "Beginner")
	eq(PuzzleDefinitions.list[1].id, TutorialFlow.PUZZLE_ID, "first Journey puzzle")
	eq(#TutorialFlow.STEPS, 5)
	for _, step in ipairs(TutorialFlow.STEPS) do
		assert(#step.text > 0 and #step.text <= 90, step.id .. " text length")
	end
end)

test("tutorial walks its steps in order", function()
	local state = TutorialFlow.new()
	local order = {}
	for _, event in ipairs({ "select", "capture", "next", "hint" }) do
		table.insert(order, (assert(TutorialFlow.current(state))).id)
		eq(TutorialFlow.advance(state, event), true, event)
	end
	eq(table.concat(order, ","), "select,capture,echo,hint")
	eq((assert(TutorialFlow.current(state))).id, "finish")
	eq(TutorialFlow.advance(state, "win"), true)
	eq(state.finished, "completed")
	eq(TutorialFlow.current(state), nil)
end)

test("tutorial ignores repeats and skips ahead", function()
	local state = TutorialFlow.new()
	eq(TutorialFlow.advance(state, "next"), true, "Next pressed early jumps past echo")
	eq((assert(TutorialFlow.current(state))).id, "hint")
	eq(TutorialFlow.advance(state, "select"), false, "an earlier step does nothing")
	eq(TutorialFlow.advance(state, "capture"), false)
	eq(TutorialFlow.advance(state, "bogus"), false)
	eq((assert(TutorialFlow.current(state))).id, "hint")
	local early = TutorialFlow.new()
	TutorialFlow.advance(early, "capture")
	eq((assert(TutorialFlow.current(early))).id, "echo", "capture without a separate select")
end)

test("tutorial skip, leave and win end it once", function()
	for event, outcome in pairs({ skip = "skipped", leave = "interrupted", win = "completed" }) do
		local state = TutorialFlow.new()
		TutorialFlow.advance(state, "select")
		eq(TutorialFlow.advance(state, event), true, event)
		eq(state.finished, outcome)
		for _, later in ipairs({ "skip", "leave", "win", "hint", "select" }) do
			eq(TutorialFlow.advance(state, later), false, event .. " then " .. later)
		end
		eq(state.finished, outcome, "outcome unchanged")
	end
end)

test("needsTutorial is for new players only", function()
	local fresh = Progression.newProfile()
	eq(Progression.needsTutorial(fresh), true, "new player")
	local returning = Progression.newProfile()
	Progression.apply(returning, win("beginner-02", MODES.Practice))
	eq(Progression.needsTutorial(returning), false, "has cleared a puzzle before")
	-- Profiles saved before the tutorial existed have no tutorial field.
	local old = Progression.normalize({ version = 1, completed = { ["beginner-01"] = { bestMoves = 3 } } })
	eq(old.tutorial.done, false)
	eq(Progression.needsTutorial(old), false, "Phase 4 player not interrupted")
	local oldNew = Progression.normalize({ version = 1 })
	eq(Progression.needsTutorial(oldNew), true, "saved but never played")
end)

test("tutorial ops save once and keep a completion", function()
	local profile = Progression.newProfile()
	eq((Progression.apply(profile, { id = "tut-1", kind = "tutorial", outcome = "skipped" })), true)
	eq(profile.tutorial.done, true)
	eq(profile.tutorial.outcome, "skipped")
	eq(Progression.needsTutorial(profile), false)
	eq((Progression.apply(profile, { id = "tut-1", kind = "tutorial", outcome = "completed" })), false, "same id twice")
	eq(profile.tutorial.outcome, "skipped")
	Progression.apply(profile, { id = "tut-2", kind = "tutorial", outcome = "completed" })
	eq(profile.tutorial.outcome, "completed", "replayed to the end")
	Progression.apply(profile, { id = "tut-3", kind = "tutorial", outcome = "skipped" })
	eq(profile.tutorial.outcome, "completed", "a later skip keeps the completion")
	local other = Progression.newProfile()
	Progression.apply(other, { id = "tut-4", kind = "tutorial", outcome = "interrupted" })
	Progression.apply(other, { id = "tut-5", kind = "tutorial", outcome = 7 })
	eq(other.tutorial.done, false, "only completed or skipped are saved")
	local summary = Progression.summary(profile, 20800)
	eq(summary.tutorialDone, true)
	eq(summary.needsTutorial, false)
	eq(Progression.summary(other, 20800).needsTutorial, true)
end)

test("tutorial and drag settings survive normalize", function()
	local saved = Progression.normalize({ version = 1, tutorial = { done = true, outcome = "completed" }, settings = { drag = false } })
	eq(saved.tutorial.outcome, "completed")
	eq(saved.settings.drag, false)
	local damaged = Progression.normalize({ version = 1, tutorial = { done = "yes", outcome = "completed" }, settings = { drag = "off" } })
	eq(damaged.tutorial.done, false, "done must be true")
	eq(damaged.settings.drag, true, "default kept")
	local odd = Progression.normalize({ version = 1, tutorial = { done = true, outcome = "hacked" } })
	eq(odd.tutorial.done, true)
	eq(odd.tutorial.outcome, nil)
	eq(Progression.newProfile().settings.drag, GameConfig.DEFAULT_SETTINGS.drag)
	local profile = Progression.newProfile()
	Progression.apply(profile, { id = "set-drag", kind = "settings", settings = { drag = false } })
	eq(profile.settings.drag, false)
end)

-- Weekly Challenge -----------------------------------------------------------------

local WeeklyChallenge = require(Shared.WeeklyChallenge)

-- 2026-10-26 00:00:00 UTC is a Monday.
local MONDAY = 1792972800
local MONDAY_DAY = MONDAY // 86400

test("weekly: weeks start on Monday 00:00 UTC", function()
	eq(os.date("!%A", MONDAY), "Monday", "fixture is a Monday")
	local week = WeeklyChallenge.weekOf(MONDAY)
	eq(WeeklyChallenge.weekOf(MONDAY - 1), week - 1, "Sunday 23:59:59 is the previous week")
	eq(WeeklyChallenge.weekOf(MONDAY + 7 * 86400 - 1), week, "next Sunday 23:59:59 is still this week")
	eq(WeeklyChallenge.weekOf(MONDAY + 7 * 86400), week + 1)
	eq(WeeklyChallenge.firstDay(week), MONDAY_DAY)
	eq(WeeklyChallenge.secondsLeft(MONDAY), 7 * 86400)
	eq(WeeklyChallenge.secondsLeft(MONDAY + 7 * 86400 - 1), 1)
	eq(WeeklyChallenge.weekOf(0), 0, "1970-01-01 (Thursday) is week 0")
	eq(WeeklyChallenge.weekOfDay(3), 0, "Sunday 1970-01-04")
	eq(WeeklyChallenge.weekOfDay(4), 1, "Monday 1970-01-05")
	for day = MONDAY_DAY - 20, MONDAY_DAY + 20 do
		eq(WeeklyChallenge.weekOfDay(day), WeeklyChallenge.weekOf(day * 86400 + 43200))
	end
end)

test("weekly: the same week always gives the same ordered set", function()
	local week = WeeklyChallenge.weekOf(MONDAY)
	local a, b = WeeklyChallenge.puzzles(week), WeeklyChallenge.puzzles(week)
	eq(#a, WeeklyChallenge.SIZE)
	for i = 1, #a do
		eq(a[i].id, b[i].id)
	end
	local differs = false
	for i, puzzle in ipairs(WeeklyChallenge.puzzles(week + 1)) do
		differs = differs or puzzle.id ~= a[i].id
	end
	assert(differs, "next week is a different set")
end)

test("weekly: every set for two years is 4 distinct, solvable catalogue puzzles, easiest first", function()
	local order = { Easy = 2, Medium = 3, Hard = 4 }
	for week = 2900, 3004 do
		local seen = {}
		local last = 0
		for _, puzzle in ipairs(WeeklyChallenge.puzzles(week)) do
			assert(PuzzleDefinitions.get(puzzle.id) == puzzle, "catalogue puzzle")
			assert(not seen[puzzle.id], "distinct in week " .. week)
			seen[puzzle.id] = true
			local rank = assert(order[puzzle.difficulty], "difficulty " .. puzzle.difficulty)
			assert(rank >= last, "ordered by difficulty")
			last = rank
			assert(WeeklyChallenge.contains(week, puzzle.id))
		end
	end
	-- The solver proves every puzzle that can appear is solvable, and its stored solution replays.
	local used = {}
	for week = 0, 5 do
		for _, puzzle in ipairs(WeeklyChallenge.puzzles(week)) do
			used[puzzle.id] = puzzle
		end
	end
	local count = 0
	for _, puzzle in pairs(used) do
		count += 1
		eq(PuzzleValidator.isSolvable(BoardState.fromLayout(puzzle.layout)), true, puzzle.id)
		eq((PuzzleValidator.validateSolution(puzzle.layout, puzzle.solution)), true, puzzle.id)
	end
	eq(count, 18, "the rotation uses all Easy, Medium and Hard puzzles over 6 weeks")
end)

test("weekly: only this week's puzzles can be started in Weekly mode", function()
	local profile = Progression.newProfile()
	local week = WeeklyChallenge.weekOfDay(MONDAY_DAY)
	local set = WeeklyChallenge.puzzles(week)
	for _, puzzle in ipairs(set) do
		eq((Progression.canStart(profile, puzzle, MODES.Weekly, MONDAY_DAY)), true, "no unlock needed")
	end
	local outside = nil
	for _, puzzle in ipairs(PuzzleDefinitions.list) do
		if not WeeklyChallenge.contains(week, puzzle.id) then
			outside = puzzle
			break
		end
	end
	eq(select(2, Progression.canStart(profile, outside, MODES.Weekly, MONDAY_DAY)), "not_weekly")
	-- Sunday night still belongs to last week.
	eq(select(2, Progression.canStart(profile, set[1], MODES.Weekly, MONDAY_DAY - 1)) == nil, WeeklyChallenge.contains(week - 1, set[1].id))
	eq(Progression.hintsLeft(profile, MODES.Weekly, 0, MONDAY_DAY), 1)
	eq(Progression.hintsLeft(profile, MODES.Weekly, 1, MONDAY_DAY), 0)
end)

test("weekly: milestones pay once; replays and repeated ops pay nothing", function()
	local profile = Progression.newProfile()
	local week = WeeklyChallenge.weekOfDay(MONDAY_DAY)
	local set = WeeklyChallenge.puzzles(week)
	local half, full = WeeklyChallenge.MILESTONES[1], WeeklyChallenge.MILESTONES[2]
	local _, reward = Progression.apply(profile, winIn(set[1].id, MODES.Weekly, set[1].par, MONDAY_DAY))
	eq(reward, nil, "one clear: no milestone yet")
	eq(Progression.weeklyView(profile, MONDAY_DAY).clearedCount, 1)
	-- Replaying the same puzzle doesn't count twice.
	_, reward = Progression.apply(profile, winIn(set[1].id, MODES.Weekly, set[1].par, MONDAY_DAY))
	eq(reward, nil)
	eq(Progression.weeklyView(profile, MONDAY_DAY).clearedCount, 1)
	_, reward = Progression.apply(profile, winIn(set[2].id, MODES.Weekly, set[2].par, MONDAY_DAY + 2))
	eq(reward.coins, half.coins)
	eq(reward.xp, half.xp)
	local coins = profile.coins
	-- The same op delivered again (a retried save) is ignored.
	local op = winIn(set[3].id, MODES.Weekly, set[3].par, MONDAY_DAY + 3)
	Progression.apply(profile, op)
	eq(select(1, Progression.apply(profile, op)), false)
	eq(profile.coins, coins)
	_, reward = Progression.apply(profile, winIn(set[4].id, MODES.Weekly, set[4].par, MONDAY_DAY + 6))
	eq(reward.coins, full.coins)
	eq(profile.stats.weeklies, 1)
	local view = Progression.weeklyView(profile, MONDAY_DAY + 6)
	eq(view.completed, true)
	eq(view.milestones[1].claimed and view.milestones[2].claimed, true)
	-- Replaying every puzzle after completion pays nothing more.
	coins = profile.coins
	for _, puzzle in ipairs(set) do
		local _, again = Progression.apply(profile, winIn(puzzle.id, MODES.Weekly, puzzle.par, MONDAY_DAY + 6))
		eq(again, nil)
	end
	eq(profile.coins, coins)
	eq(profile.stats.weeklies, 1)
	-- Weekly clears are credited like Daily clears (stars saved).
	eq(profile.completed[set[1].id].credited, true)
	eq(profile.completed[set[1].id].stars, 3)
end)

test("weekly: a new week starts fresh; a late op for last week counts nothing", function()
	local profile = Progression.newProfile()
	local week = WeeklyChallenge.weekOfDay(MONDAY_DAY)
	local set = WeeklyChallenge.puzzles(week)
	Progression.apply(profile, winIn(set[1].id, MODES.Weekly, 99, MONDAY_DAY))
	Progression.apply(profile, winIn(set[2].id, MODES.Weekly, 99, MONDAY_DAY))
	eq(Progression.weeklyView(profile, MONDAY_DAY).clearedCount, 2)
	local nextMonday = MONDAY_DAY + 7
	local view = Progression.weeklyView(profile, nextMonday)
	eq(view.week, week + 1)
	eq(view.clearedCount, 0, "next week's view starts at 0")
	eq(view.milestones[1].claimed, false)
	local nextSet = WeeklyChallenge.puzzles(week + 1)
	Progression.apply(profile, winIn(nextSet[1].id, MODES.Weekly, 99, nextMonday))
	eq(profile.weekly.week, week + 1)
	-- An op from an attempt started last week arrives late.
	local _, reward = Progression.apply(profile, winIn(set[3].id, MODES.Weekly, 99, MONDAY_DAY + 6))
	eq(reward, nil)
	eq(profile.weekly.week, week + 1, "the week never moves backwards")
	eq(profile.weekly.cleared[set[3].id], nil)
end)

test("weekly: a Weekly clear doesn't touch the Daily streak or Daily state", function()
	local profile = Progression.newProfile()
	local daily = Progression.dailyPuzzle(MONDAY_DAY - 1)
	Progression.apply(profile, win(daily.id, MODES.Daily, MONDAY_DAY - 1))
	eq(profile.streak.current, 1)
	local set = WeeklyChallenge.puzzles(WeeklyChallenge.weekOfDay(MONDAY_DAY))
	for _, puzzle in ipairs(set) do
		Progression.apply(profile, win(puzzle.id, MODES.Weekly, MONDAY_DAY))
	end
	eq(profile.streak.current, 1)
	eq(profile.streak.lastDay, MONDAY_DAY - 1)
	eq(profile.daily.day, MONDAY_DAY - 1)
	eq(profile.stats.dailies, 1)
	eq(Progression.streakView(profile, MONDAY_DAY).current, 1, "today's Daily can still extend it")
end)

test("weekly: Practice and Journey clears of a weekly puzzle don't count for the week", function()
	local profile = Progression.newProfile()
	local set = WeeklyChallenge.puzzles(WeeklyChallenge.weekOfDay(MONDAY_DAY))
	for _, puzzle in ipairs(set) do
		Progression.apply(profile, win(puzzle.id, MODES.Practice, MONDAY_DAY))
		Progression.apply(profile, win(puzzle.id, MODES.Journey, MONDAY_DAY))
	end
	eq(Progression.weeklyView(profile, MONDAY_DAY).clearedCount, 0)
	-- A Weekly op without a day (a forged or broken op) changes nothing for the week.
	Progression.apply(profile, { id = opId(), kind = "win", puzzleId = set[1].id, mode = MODES.Weekly, moves = 5, seconds = 5 })
	eq(Progression.weeklyView(profile, MONDAY_DAY).clearedCount, 0)
end)

test("weekly: weekly and duel data survive normalize, and old profiles get defaults", function()
	local old = Progression.normalize({ version = 1, xp = 10, stats = { solves = 2 } })
	eq(old.weekly.week, 0)
	eq(next(old.weekly.cleared), nil)
	eq(old.stats.weeklies, 0)
	eq(old.duel.played, 0)
	local week = WeeklyChallenge.weekOfDay(MONDAY_DAY)
	local set = WeeklyChallenge.puzzles(week)
	local saved = Progression.normalize({
		weekly = { week = week, cleared = { [set[1].id] = true, ["beginner-01"] = true, [set[2].id] = "yes" } },
		duel = { played = 3, wins = 2, losses = 1, draws = "x", day = 5, rewardedToday = 2, opponentsToday = { 7, "8" }, recent = { "m1", 5 } },
	})
	eq(saved.weekly.cleared[set[1].id], true)
	eq(saved.weekly.cleared["beginner-01"], nil, "not in that week's set")
	eq(saved.weekly.cleared[set[2].id], nil, "must be true")
	eq(saved.duel.wins, 2)
	eq(saved.duel.draws, 0)
	eq(#saved.duel.opponentsToday, 1)
	eq(#saved.duel.recent, 1)
	local damaged = Progression.normalize({ weekly = "x", duel = 4 })
	eq(damaged.weekly.week, 0)
	eq(damaged.duel.played, 0)
end)

test("weekly: rewards stay single when the same week is saved from two servers", function()
	local store = FakeStore.new()
	local a = makeStore(store)
	local b = makeStore(store)
	a:load(40)
	b:load(40)
	local set = WeeklyChallenge.puzzles(WeeklyChallenge.weekOfDay(MONDAY_DAY))
	for _, puzzle in ipairs(set) do
		a:record(40, win(puzzle.id, MODES.Weekly, MONDAY_DAY))
		b:record(40, win(puzzle.id, MODES.Weekly, MONDAY_DAY))
	end
	assert(a:save(40))
	assert(b:save(40))
	local total = 0
	for _, milestone in ipairs(WeeklyChallenge.MILESTONES) do
		total += milestone.coins
	end
	-- Each puzzle's first-clear coins don't apply in Weekly; only milestones (and achievements) pay.
	local stored = store.data.player_40
	eq(stored.stats.weeklies, 1)
	local ach = 0
	for key in pairs(stored.rewards) do
		if string.sub(key, 1, 4) == "ach:" then
			ach += 1
		end
	end
	eq(ach, 0, "no achievement is reachable from one week")
	eq(stored.coins, total)
end)

-- Puzzle Duel -----------------------------------------------------------------------

local DuelManager = require(Shared.DuelManager)
local RateLimiter = require(Shared.RateLimiter)

local DUEL_DAY = MONDAY_DAY
local DUEL_PUZZLE = assert(PuzzleDefinitions.get("beginner-01")) -- solution c2-b2 b2-c3 c3-c4

-- A manager with a fake clock. Every finished match is recorded as a real
-- Progression "duel" op on an in-memory profile per player.
local function makeDuels(puzzle: any?)
	local env = { t = 100, sent = {}, records = {}, profiles = {}, ids = 0, day = DUEL_DAY }
	local function profileFor(id: number): any
		env.profiles[id] = env.profiles[id] or Progression.newProfile()
		return env.profiles[id]
	end
	env.profileFor = profileFor
	env.duels = DuelManager.new({
		now = function()
			return env.t
		end,
		newId = function()
			env.ids += 1
			return "match-" .. env.ids
		end,
		pickPuzzle = function()
			return puzzle or DUEL_PUZZLE
		end,
		send = function(id: number, snap: any)
			env.sent[id] = env.sent[id] or {}
			table.insert(env.sent[id], snap)
		end,
		record = function(id: number, result: any)
			table.insert(env.records, { id = id, result = result })
			local profile = profileFor(id)
			local block = if result.outcome ~= "loss" then Progression.duelRewardBlock(profile, env.day, result.opponent) else nil
			local _, reward = Progression.apply(profile, {
				id = "duel:" .. result.matchId .. ":" .. id,
				kind = "duel",
				matchId = result.matchId,
				outcome = result.outcome,
				reason = result.reason,
				opponent = result.opponent,
				day = env.day,
			})
			return reward, block
		end,
		modules = { PuzzleSession = PuzzleSession, PuzzleValidator = PuzzleValidator, BoardState = BoardState },
		config = GameConfig.DUEL,
	})
	function env.last(id: number): any
		local list = env.sent[id]
		return list and list[#list]
	end
	function env.move(id: number, from: string, to: string): (boolean, string?)
		local board = BoardState.fromLayout(DUEL_PUZZLE.layout)
		return env.duels:act(id, "move", { from = sq(board, from), to = sq(board, to) })
	end
	function env.start()
		env.t += GameConfig.DUEL.COUNTDOWN
		env.duels:update()
	end
	return env
end

local function matched(env: any, a: number, b: number)
	assert(env.duels:join(a, "P" .. a))
	assert(env.duels:join(b, "P" .. b))
end

test("duel: join, waiting state and cancel", function()
	local env = makeDuels()
	local duels = env.duels
	eq((duels:join(1, "Ann")), true)
	eq(duels:stateOf(1), "queued")
	eq(env.last(1).duel.phase, "queued")
	eq(env.last(1).layout, nil, "no board while waiting")
	eq((duels:cancel(1)), true)
	eq(duels:stateOf(1), nil)
	eq(env.last(1).duel.phase, "idle")
	eq(select(2, duels:cancel(1)), "not_queued")
	-- Joining again after cancelling works.
	eq((duels:join(1, "Ann")), true)
	eq(duels:queueSize(), 1)
end)

test("duel: a player can't queue twice or be matched with themselves", function()
	local env = makeDuels()
	local duels = env.duels
	assert(duels:join(1, "Ann"))
	eq(select(2, duels:join(1, "Ann")), "already_queued")
	eq(duels:queueSize(), 1)
	eq(duels:stateOf(1), "queued", "still waiting, never matched with self")
	eq(#env.records, 0)
end)

test("duel: two players are matched on the same puzzle with a countdown", function()
	local env = makeDuels()
	local duels = env.duels
	matched(env, 1, 2)
	eq(duels:queueSize(), 0)
	eq(duels:stateOf(1), "countdown")
	eq(duels:stateOf(2), "countdown")
	local a, b = env.last(1), env.last(2)
	eq(a.event, "duel_found")
	eq(a.duel.matchId, b.duel.matchId, "same match")
	eq(a.puzzleId, b.puzzleId, "same puzzle")
	eq(table.concat(a.layout, "/"), table.concat(b.layout, "/"), "same board")
	eq(a.duel.opponent.name, "P2")
	eq(b.duel.opponent.name, "P1")
	eq(a.duel.startsIn, GameConfig.DUEL.COUNTDOWN)
	eq(a.hintsLeft, 0, "no hints in a duel")
	-- Neither can join another match while in this one.
	eq(select(2, duels:join(1, "Ann")), "in_duel")
	-- Moves before the start are refused.
	eq(select(2, env.move(1, "c2", "b2")), "not_started")
	eq(env.last(1).error, "not_started")
	env.start()
	eq(duels:stateOf(1), "playing")
	eq(env.last(1).event, "duel_start")
	eq(env.last(2).event, "duel_start")
end)

test("duel: three players joining at once make one match and one waiter", function()
	local env = makeDuels()
	local duels = env.duels
	for id = 1, 3 do
		assert(duels:join(id, "P" .. id))
	end
	eq(duels:stateOf(1), "countdown")
	eq(duels:stateOf(2), "countdown")
	eq(duels:stateOf(3), "queued")
	assert(duels:join(4, "P4"))
	eq(duels:stateOf(4), "countdown")
	assert(env.last(3).duel.matchId ~= env.last(1).duel.matchId, "unique match ids")
end)

test("duel: each move is checked against the mover's own board", function()
	local env = makeDuels()
	matched(env, 1, 2)
	env.start()
	eq(select(2, env.move(1, "c2", "a1")), "illegal_move")
	eq(env.last(1).error, "illegal_move")
	eq(select(2, env.move(1, "c4", "c3")), "not_your_piece")
	eq(select(2, env.duels:act(1, "move", { from = "c2", to = "b2" })), "bad_square")
	eq(select(2, env.duels:act(1, "move", { from = 1.5, to = {} })), "bad_square")
	assert(env.move(1, "c2", "b2"))
	eq(env.last(1).moveCount, 1)
	eq(env.last(1).targetsLeft, 2)
	-- The opponent sees progress, never the board or moves.
	local seen = env.last(2)
	eq(seen.event, "duel_opponent")
	eq(seen.duel.opponent.captured, 1)
	eq(seen.duel.opponent.moves, 1)
	eq(table.concat(seen.layout, "/"), table.concat(DUEL_PUZZLE.layout, "/"), "player 2's own board is untouched")
	eq(seen.lastMove, nil)
	-- Undo and restart only touch your own board.
	assert(env.duels:act(1, "undo", {}))
	eq(env.last(1).moveCount, 0)
	eq(select(2, env.duels:act(1, "undo", {})), "cannot_undo")
	assert(env.move(1, "c2", "b2"))
	assert(env.duels:act(1, "restart", {}))
	eq(env.last(1).moveCount, 0)
	eq(select(2, env.duels:act(1, "hint", {})), "bad_action")
end)

test("duel: the first valid clear wins and both get results", function()
	local env = makeDuels()
	matched(env, 1, 2)
	env.start()
	assert(env.move(2, "c2", "b2"))
	assert(env.move(1, "c2", "b2"))
	assert(env.move(1, "b2", "c3"))
	assert(env.move(1, "c3", "c4"))
	local a, b = env.last(1), env.last(2)
	eq(a.event, "duel_end")
	eq(a.duel.phase, "finished")
	eq(a.duel.outcome, "win")
	eq(a.duel.reason, "solved")
	eq(b.duel.outcome, "loss")
	eq(b.duel.reason, "opponent_solved")
	eq(b.duel.opponent.solved, true)
	eq(#env.records, 2)
	eq(a.duel.reward.coins, GameConfig.DUEL.REWARD_WIN.coins)
	eq(b.duel.reward, nil)
	eq(env.profiles[1].duel.wins, 1)
	eq(env.profiles[2].duel.losses, 1)
	-- The loser can't keep playing or overturn it.
	eq(select(2, env.move(2, "b2", "c3")), "not_in_duel")
	eq(env.duels:stateOf(1), nil)
	eq(#env.records, 2, "recorded once")
end)

test("duel: simultaneous finishing moves are settled by arrival order", function()
	local env = makeDuels()
	matched(env, 1, 2)
	env.start()
	for _, id in ipairs({ 1, 2 }) do
		assert(env.move(id, "c2", "b2"))
		assert(env.move(id, "b2", "c3"))
	end
	-- Both send the final move in the same instant; player 2's arrives first.
	assert(env.move(2, "c3", "c4"))
	eq(select(2, env.move(1, "c3", "c4")), "not_in_duel")
	eq(env.last(2).duel.outcome, "win")
	eq(env.last(1).duel.outcome, "loss")
	eq(env.profiles[1].duel.wins, 0)
	eq(#env.records, 2)
end)

test("duel: a client can't declare a win or pick the winner", function()
	local env = makeDuels()
	matched(env, 1, 2)
	env.start()
	for _, action in ipairs({ "win", "finish", "result", "solve" }) do
		eq(select(2, env.duels:act(1, action, { winner = 1, matchId = "match-1", won = true })), "bad_action")
	end
	-- Extra fields on a move are ignored.
	assert(env.duels:act(1, "move", { from = sq(BoardState.fromLayout(DUEL_PUZZLE.layout), "c2"), to = sq(BoardState.fromLayout(DUEL_PUZZLE.layout), "b2"), status = "won", targetsLeft = 0 }))
	eq(env.duels:stateOf(1), "playing")
	eq(#env.records, 0)
end)

test("duel: players outside a match can't act on it", function()
	local env = makeDuels()
	matched(env, 1, 2)
	env.start()
	eq(select(2, env.move(3, "c2", "b2")), "not_in_duel")
	eq(env.last(3).error, "not_in_duel")
	eq(select(2, env.duels:leave(3)), "not_in_duel")
	eq(env.last(1).moveCount, 0, "nothing reached player 1's board")
	eq(env.duels:stateOf(1), "playing")
end)

test("duel: nobody clearing in time is a draw", function()
	local env = makeDuels()
	matched(env, 1, 2)
	env.start()
	assert(env.move(1, "c2", "b2"))
	env.t += GameConfig.DUEL.TIME_LIMIT - 1
	env.duels:update()
	eq(env.duels:stateOf(1), "playing")
	env.t += 1
	env.duels:update()
	eq(env.last(1).duel.outcome, "draw")
	eq(env.last(2).duel.outcome, "draw")
	eq(env.last(1).duel.reason, "timeout")
	eq(env.last(1).duel.timeLeft, 0)
	eq(env.profiles[1].duel.draws, 1)
	eq(env.last(1).duel.reward.coins, GameConfig.DUEL.REWARD_DRAW.coins)
end)

test("duel: a move after the time limit can't win, even before the timer ticks", function()
	local env = makeDuels()
	matched(env, 1, 2)
	env.start()
	assert(env.move(1, "c2", "b2"))
	assert(env.move(1, "b2", "c3"))
	env.t += GameConfig.DUEL.TIME_LIMIT
	eq(select(2, env.move(1, "c3", "c4")), "match_over")
	eq(env.last(2).duel.outcome, "draw")
	eq(env.profiles[1].duel.wins, 0)
end)

test("duel: disconnects never leave the other player stuck", function()
	-- In the queue.
	local env = makeDuels()
	assert(env.duels:join(1, "Ann"))
	env.duels:disconnect(1)
	eq(env.duels:queueSize(), 0)
	-- During the countdown.
	matched(env, 2, 3)
	env.duels:disconnect(2)
	eq(env.last(3).duel.outcome, "win")
	eq(env.last(3).duel.reason, "opponent_left")
	eq(env.last(3).duel.opponent.connected, false)
	eq(env.profiles[2].duel.losses, 1, "leaving counts as a loss")
	eq(env.duels:stateOf(3), nil, "free to queue again")
	-- During play.
	matched(env, 4, 5)
	env.start()
	assert(env.move(4, "c2", "b2"))
	env.duels:disconnect(5)
	eq(env.last(4).duel.outcome, "win")
	-- A forfeit win pays like a draw.
	eq(env.last(4).duel.reward.coins, GameConfig.DUEL.REWARD_DRAW.coins)
	-- Nothing more is sent to the player who left, and disconnecting twice is harmless.
	local count = #env.sent[5]
	env.duels:disconnect(5)
	env.duels:update()
	eq(#env.sent[5], count)
	eq(env.duels:snapshot(5, "sync").duel.phase, "idle")
end)

test("duel: forfeiting with Leave", function()
	local env = makeDuels()
	matched(env, 1, 2)
	env.start()
	assert(env.duels:leave(1))
	eq(env.last(1).duel.outcome, "loss")
	eq(env.last(1).duel.reason, "left")
	eq(env.last(2).duel.outcome, "win")
	eq(select(2, env.duels:leave(1)), "not_in_duel")
	-- Leave while queued just cancels.
	assert(env.duels:join(1, "Ann"))
	assert(env.duels:leave(1))
	eq(env.duels:stateOf(1), nil)
end)

test("duel: result screen stays until exit; exit is refused mid-match", function()
	local env = makeDuels()
	matched(env, 1, 2)
	eq(env.duels:exit(1), false)
	env.start()
	assert(env.duels:leave(2))
	eq(env.duels:snapshot(1, "sync").duel.phase, "finished")
	eq(env.duels:exit(1), true)
	eq(env.duels:snapshot(1, "sync").duel.phase, "idle")
	eq(env.duels:hasScreen(1), false)
	eq(env.duels:hasScreen(2), true, "player 2 hasn't closed theirs")
	-- Re-sending exit or results never records again.
	env.duels:exit(1)
	eq(#env.records, 2)
end)

test("duel: rewards are paid once per match and capped per day and per opponent", function()
	local profile = Progression.newProfile()
	local function duelOp(matchId: string, outcome: string, opponent: number, day: number, reason: string?): any
		return { id = opId(), kind = "duel", matchId = matchId, outcome = outcome, reason = reason or "solved", opponent = opponent, day = day }
	end
	local _, reward = Progression.apply(profile, duelOp("m1", "win", 50, DUEL_DAY))
	eq(reward.coins, GameConfig.DUEL.REWARD_WIN.coins)
	eq(reward.xp, GameConfig.DUEL.REWARD_WIN.xp)
	-- The same match delivered again under another op id (a second server) is ignored.
	local coins = profile.coins
	_, reward = Progression.apply(profile, duelOp("m1", "win", 50, DUEL_DAY))
	eq(reward, nil)
	eq(profile.coins, coins)
	eq(profile.duel.played, 1)
	-- The same opponent again today: counted, not paid.
	_, reward = Progression.apply(profile, duelOp("m2", "win", 50, DUEL_DAY))
	eq(reward, nil)
	eq(Progression.duelRewardBlock(profile, DUEL_DAY, 50), "same_opponent")
	eq(profile.duel.wins, 2)
	-- Losses never pay; draws pay a little.
	_, reward = Progression.apply(profile, duelOp("m3", "loss", 51, DUEL_DAY))
	eq(reward, nil)
	_, reward = Progression.apply(profile, duelOp("m4", "draw", 52, DUEL_DAY, "timeout"))
	eq(reward.coins, GameConfig.DUEL.REWARD_DRAW.coins)
	-- Daily cap.
	for i = 1, 10 do
		Progression.apply(profile, duelOp("cap" .. i, "win", 100 + i, DUEL_DAY))
	end
	eq(profile.duel.rewardedToday, GameConfig.DUEL.DAILY_REWARDED)
	eq(Progression.duelRewardBlock(profile, DUEL_DAY, 999), "daily_cap")
	eq(Progression.summary(profile, DUEL_DAY).duel.rewardsLeftToday, 0)
	-- A new UTC day pays again, including the same opponent.
	_, reward = Progression.apply(profile, duelOp("next", "win", 50, DUEL_DAY + 1))
	eq(reward.coins, GameConfig.DUEL.REWARD_WIN.coins)
	-- A late op for a day that has passed doesn't pay.
	_, reward = Progression.apply(profile, duelOp("late", "win", 77, DUEL_DAY))
	eq(reward, nil)
	-- Garbage ops change nothing.
	local played = profile.duel.played
	Progression.apply(profile, { id = opId(), kind = "duel", matchId = "", outcome = "win" })
	Progression.apply(profile, { id = opId(), kind = "duel", matchId = "x", outcome = "victory" })
	eq(profile.duel.played, played)
	local summary = Progression.summary(profile, DUEL_DAY + 1)
	eq(summary.duel.played, played)
	eq(summary.duel.wins + summary.duel.losses + summary.duel.draws, played)
end)

test("duel: matching the same account all day earns one reward", function()
	local env = makeDuels()
	for _ = 1, 6 do
		matched(env, 1, 2)
		env.start()
		for _, m in ipairs({ { "c2", "b2" }, { "b2", "c3" }, { "c3", "c4" } }) do
			assert(env.move(1, m[1], m[2]))
		end
		env.duels:exit(1)
		env.duels:exit(2)
	end
	eq(env.profiles[1].duel.wins, 6)
	eq(env.profiles[1].coins, GameConfig.DUEL.REWARD_WIN.coins, "paid for the first match only")
	eq(env.profiles[2].coins, 0)
	local notes = {}
	for _, list in pairs({ env.sent[1] }) do
		for _, snap in ipairs(list) do
			if snap.event == "duel_end" then
				table.insert(notes, snap.duel.rewardNote or "paid")
			end
		end
	end
	eq(notes[1], "paid")
	eq(notes[2], "same_opponent")
end)

test("duel: duel records survive the profile store round trip once", function()
	local store = FakeStore.new()
	local a = makeStore(store)
	a:load(60)
	local op = { kind = "duel", matchId = "match-x", outcome = "win", reason = "solved", opponent = 61, day = DUEL_DAY }
	op.id = "duel:match-x:60"
	a:record(60, op)
	a:record(60, op) -- recorded twice by mistake
	assert(a:save(60))
	local b = makeStore(store)
	b:load(60)
	b:record(60, { id = "duel:match-x:60:retry", kind = "duel", matchId = "match-x", outcome = "win", reason = "solved", opponent = 61, day = DUEL_DAY })
	assert(b:save(60))
	eq(store.data.player_60.duel.wins, 1)
	eq(store.data.player_60.coins, GameConfig.DUEL.REWARD_WIN.coins)
end)

test("duel: Duel is not a play mode a client can start", function()
	eq(GameConfig.PLAY_MODES.Duel, nil)
	eq(GameConfig.PLAY_MODES[GameConfig.DUEL_MODE], nil)
	eq(select(2, Progression.canStart(Progression.newProfile(), DUEL_PUZZLE, "Duel", DUEL_DAY)), "bad_mode")
	eq(GameConfig.HINTS.Duel, 0)
end)

test("duel: the server's duel pool is validated puzzles only", function()
	for _, difficulty in ipairs(GameConfig.DUEL.DIFFICULTIES) do
		for _, puzzle in ipairs(PuzzleDefinitions.byDifficulty[difficulty]) do
			eq(#PuzzleCheck.check(puzzle), 0, puzzle.id)
		end
	end
end)

test("rate limiter: bursts are allowed, floods are refused, then it refills", function()
	local limit = RateLimiter.new(GameConfig.RATE_LIMIT.BURST, GameConfig.RATE_LIMIT.PER_SECOND, 0)
	local allowed = 0
	for _ = 1, 50 do
		if limit:take(0) then
			allowed += 1
		end
	end
	eq(allowed, GameConfig.RATE_LIMIT.BURST, "50 requests in one instant: only the burst passes")
	eq(limit:take(0.05), false)
	eq(limit:take(1), true, "a second later there are tokens again")
	-- A steady stream at the refill rate is never refused.
	local steady = RateLimiter.new(8, 6, 10)
	for i = 1, 100 do
		eq(steady:take(10 + i / 6), true)
	end
	-- A clock going backwards never adds tokens.
	local odd = RateLimiter.new(2, 6, 100)
	odd:take(100)
	odd:take(100)
	eq(odd:take(50), false)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("test failures")
end
