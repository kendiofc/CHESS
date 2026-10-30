--!strict
-- PuzzleCheck: validates puzzle definitions and grades their difficulty.
--
-- check(puzzle) returns a list of problems (empty when the puzzle is good):
--   * the definition is complete and the layout parses, with one player piece
--     and at least one target
--   * the stored solution replays under the real rules (ChessRules, not the
--     solver) and clears the board
--   * every prefix of the solution, every solution with one move swapped for an
--     illegal one, and the solution with an extra move are all rejected
--   * the solver finds a solution, and that solution replays too
--   * par is the true minimum and the stored solution is that long
--   * the live solver budget settles the start position
--   * hints only name squares that hold targets, and never more than two, so a
--     hint can guide but not play the puzzle
--   * the graded difficulty matches the band the puzzle is filed under
-- checkCatalog(list) adds catalogue-wide checks (unique ids, names, layouts).
--
-- tests/run.luau runs both on every shipped puzzle. Puzzle authors can run
-- tests/analyze.luau to see the grade numbers.

local BoardState = require(script.Parent.BoardState)
local ChessRules = require(script.Parent.ChessRules)
local GameConfig = require(script.Parent.GameConfig)
local PuzzleSession = require(script.Parent.PuzzleSession)
local PuzzleValidator = require(script.Parent.PuzzleValidator)

local PuzzleCheck = {}

export type Grade = {
	targets: number,
	par: number,
	wins: number, -- capture orders that clear the board
	deadEnds: number, -- capture orders that get stuck
	score: number,
	difficulty: string,
}

-- Lowest score of each band after Beginner. A puzzle's score is its target
-- count, plus 1.5 for every halving of the share of capture orders that win,
-- plus a quarter of its par: more pieces, fewer working orders and longer
-- solutions all make a puzzle harder.
PuzzleCheck.BAND_FLOORS = { Easy = 8, Medium = 12, Hard = 16, Expert = 21 }

function PuzzleCheck.score(targets: number, par: number, wins: number, deadEnds: number): number
	return targets + 1.5 * math.log((wins + deadEnds) / wins, 2) + par / 4
end

function PuzzleCheck.bandFor(score: number): string
	local band = GameConfig.DIFFICULTIES[1]
	for _, difficulty in ipairs(GameConfig.DIFFICULTIES) do
		local floor = PuzzleCheck.BAND_FLOORS[difficulty]
		if floor and score >= floor then
			band = difficulty
		end
	end
	return band
end

-- Grades a solvable layout. Returns nil for an unsolvable one.
function PuzzleCheck.grade(layout: { string }): Grade?
	local board = BoardState.fromLayout(layout)
	local par = PuzzleValidator.minimumMoves(board)
	if not par then
		return nil
	end
	local wins, deadEnds = PuzzleValidator.countOrders(board)
	local targets = BoardState.countColor(board, "black")
	local score = PuzzleCheck.score(targets, par, wins, deadEnds)
	return {
		targets = targets,
		par = par,
		wins = wins,
		deadEnds = deadEnds,
		score = score,
		difficulty = PuzzleCheck.bandFor(score),
	}
end

local function nonEmptyString(value: any): boolean
	return type(value) == "string" and #value > 0
end

-- Replays `count` moves of a solution and returns the board, or nil if a move
-- along the way is illegal.
local function replay(layout: { string }, solution: { { string } }, count: number): BoardState.Board?
	local board = BoardState.fromLayout(layout)
	for i = 1, count do
		local from = BoardState.parseSquare(board, solution[i][1])
		local to = BoardState.parseSquare(board, solution[i][2])
		if not from or not to or not ChessRules.findMove(board, from, to) then
			return nil
		end
		ChessRules.applyMove(board, from, to, true)
	end
	return board
end

local function checkRejections(puzzle: any, problems: { string })
	local layout, solution = puzzle.layout, puzzle.solution
	for length = 0, #solution - 1 do
		local prefix = table.move(solution, 1, length, 1, {})
		if PuzzleValidator.validateSolution(layout, prefix) then
			table.insert(problems, "an incomplete solution (" .. length .. " moves) was accepted")
		end
	end
	local extra = table.clone(solution)
	local last = solution[#solution]
	table.insert(extra, { last[2], last[1] })
	if PuzzleValidator.validateSolution(layout, extra) then
		table.insert(problems, "a move after the board was cleared was accepted")
	end
	-- Swap each move's destination for one square it cannot legally reach.
	for i, move in ipairs(solution) do
		local board = replay(layout, solution, i - 1)
		if board then
			local from = BoardState.parseSquare(board, move[1]) :: number
			for square = 1, board.width * board.height do
				if not ChessRules.findMove(board, from, square) then
					local tampered = table.clone(solution)
					tampered[i] = { move[1], BoardState.squareName(board, square) }
					if PuzzleValidator.validateSolution(layout, tampered) then
						table.insert(problems, "an illegal move at step " .. i .. " was accepted")
					end
					break
				end
			end
		end
	end
end

local function checkHints(puzzle: any, board: BoardState.Board, problems: { string })
	if type(puzzle.hints) ~= "table" or #puzzle.hints < 2 then
		table.insert(problems, "needs at least two hints")
		return
	end
	for i, hint in ipairs(puzzle.hints) do
		if not nonEmptyString(hint) then
			table.insert(problems, "hint " .. i .. " is empty")
			continue
		end
		local named = 0
		for name in string.gmatch(hint, "%f[%w](%l%d)%f[%W]") do
			named += 1
			local square = BoardState.parseSquare(board, name)
			local piece = square and board.pieces[square]
			if not piece or piece.color ~= "black" then
				table.insert(problems, "hint " .. i .. " names " .. name .. ", which holds no target")
			end
		end
		if named > 2 then
			table.insert(problems, "hint " .. i .. " names more than two squares")
		end
	end
end

function PuzzleCheck.check(puzzle: any): { string }
	local problems: { string } = {}
	if not nonEmptyString(puzzle.id) then
		table.insert(problems, "missing id")
	end
	if not nonEmptyString(puzzle.name) then
		table.insert(problems, "missing name")
	end
	if not table.find(GameConfig.DIFFICULTIES, puzzle.difficulty) then
		table.insert(problems, "unknown difficulty " .. tostring(puzzle.difficulty))
	end
	if puzzle.mode ~= GameConfig.MODES.EchoClear then
		table.insert(problems, "unknown mode " .. tostring(puzzle.mode))
	end
	if type(puzzle.reward) ~= "table" or not (puzzle.reward.xp > 0 and puzzle.reward.coins > 0) then
		table.insert(problems, "reward must be positive")
	end
	if type(puzzle.solution) ~= "table" or #puzzle.solution == 0 then
		table.insert(problems, "missing solution")
		return problems
	end

	local parsed, board = pcall(BoardState.fromLayout, puzzle.layout)
	if not parsed then
		table.insert(problems, "layout does not parse: " .. tostring(board))
		return problems
	end
	local whites = 0
	for _, piece in pairs(board.pieces) do
		if piece.color == "white" then
			whites += 1
		end
	end
	if whites ~= 1 then
		table.insert(problems, "needs exactly one player piece, found " .. whites)
		return problems
	end
	if BoardState.countColor(board, "black") == 0 then
		table.insert(problems, "has no targets")
		return problems
	end
	checkHints(puzzle, board, problems)

	local replays, why = PuzzleValidator.validateSolution(puzzle.layout, puzzle.solution)
	if not replays then
		table.insert(problems, "stored solution fails: " .. tostring(why))
	end
	checkRejections(puzzle, problems)

	local result = PuzzleValidator.solve(board)
	if result.status ~= "solved" then
		table.insert(problems, "solver says " .. result.status)
		return problems
	end
	local names = {}
	for _, move in ipairs(result.solution :: { { number } }) do
		table.insert(names, { BoardState.squareName(board, move[1]), BoardState.squareName(board, move[2]) })
	end
	if not PuzzleValidator.validateSolution(puzzle.layout, names) then
		table.insert(problems, "the solver's own solution does not replay")
	end
	local live = PuzzleValidator.solve(board, { maxStates = PuzzleSession.SOLVER_BUDGET })
	if live.status ~= "solved" then
		table.insert(problems, "the live solver budget cannot settle the start position")
	end

	local grade = PuzzleCheck.grade(puzzle.layout) :: Grade
	if grade.par ~= puzzle.par or #puzzle.solution ~= puzzle.par then
		table.insert(
			problems,
			string.format("par is %s, solution has %d moves, true minimum is %d", tostring(puzzle.par), #puzzle.solution, grade.par)
		)
	end
	if grade.difficulty ~= puzzle.difficulty then
		table.insert(
			problems,
			string.format("filed as %s but grades as %s (score %.1f)", tostring(puzzle.difficulty), grade.difficulty, grade.score)
		)
	end
	return problems
end

function PuzzleCheck.checkCatalog(list: { any }): { string }
	local problems: { string } = {}
	local ids, names, layouts = {}, {}, {}
	for _, puzzle in ipairs(list) do
		local layout = table.concat(puzzle.layout, "/")
		if ids[puzzle.id] then
			table.insert(problems, "duplicate id " .. puzzle.id)
		end
		if names[puzzle.name] then
			table.insert(problems, "duplicate name " .. puzzle.name)
		end
		if layouts[layout] then
			table.insert(problems, puzzle.id .. " repeats the layout of " .. layouts[layout])
		end
		ids[puzzle.id], names[puzzle.name], layouts[layout] = true, true, puzzle.id
	end
	return problems
end

return PuzzleCheck
