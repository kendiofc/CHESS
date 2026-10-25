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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("test failures")
end
