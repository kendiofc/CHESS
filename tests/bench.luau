-- Solver benchmark: the Phase 2 solver (ReferenceSolver) against the current
-- PuzzleValidator on the shipped puzzles and on larger fixed boards.
--
-- CLI:    python3 tools/run_tests.py path/to/luau tests/bench.luau
-- Studio: see README ("Running the benchmark in Studio").
--
-- "states" is the number of search states each solver expanded. The old solver
-- is skipped (marked "-") on the 16-target board, where it takes about 16 s in
-- the CLI, and on the 18-target board, which is over its old 16-target limit.

local BoardState = require(Shared.BoardState)
local PuzzleValidator = require(Shared.PuzzleValidator)
local PuzzleDefinitions = require(Shared.PuzzleDefinitions)
local ReferenceSolver = require(Shared.ReferenceSolver)

local function split(text: string): { string }
	return string.split(text, "/")
end

local cases: { { name: string, layout: { string }, reference: boolean } } = {}
for _, puzzle in ipairs(PuzzleDefinitions.list) do
	table.insert(cases, { name = puzzle.id, layout = puzzle.layout, reference = true })
end
-- Random boards from tests/lib/BoardGen, frozen here so the numbers stay comparable.
local LARGER = {
	{ "6x6 unsolvable", "k..rp./p#k#../..N.q./....../...p.#/q#k..n", true },
	{ "8x8 unsolvable", "......b#/#k....../.p.....p/.....R../...q.##./.#.q...p/....q##./.kp.....", true },
	{ "8x8 unsolvable", ".pN...../k.#...../.#...r##/.rkq.p../.#....../....#..b/qr...q../.....#..", true },
	{ "8x8 solvable", "...##.../...Q..../.#kn..b./rn....../...nr.#./#...p.../..k#p.p./...n.#..", true },
	{ "8x8 solvable", "..qr.r.k/.b.#.#.B/p......./..n....#/.#....##/.qq...n./n#....../b.......", true },
	{ "8x8 unsolvable", "n.....##/#......./p.p.q#../.r..k#../...n..../..#k..bn/..#....n/...R...k", true },
	{ "8x8 unsolvable", "#..#.#../...q.p../......#./Rq...pq./.#....##/......kq/.......k/...kkq.n", true },
	{ "8x8 unsolvable", ".k..b.pR/.q..#r../.......p/..k.r..p/b......n/k.....r./.b....../.......#", true },
	{ "8x8 unsolvable", ".#kr..#q/...n..p./.p.n..../.p..k.../.....k##/.#...Rrr/k...#.../..#bpn..", false },
	{ "8x8 unsolvable", ".r....p#/#kn..p../.pb..#../bb..p.../.p.#..p./n.r..bk./.#....r./.#.Nr...", false },
}
for _, case in ipairs(LARGER) do
	table.insert(cases, { name = case[1], layout = split(case[2]), reference = case[3] })
end

local function timeIt(fn: () -> any): (number, any)
	local started = os.clock()
	local result = fn()
	return os.clock() - started, result
end

print(string.format("%-16s %5s %7s %10s | %10s %8s | %10s %8s | %7s", "board", "size", "targets", "result", "old ms", "states", "new ms", "states", "speedup"))
local totalOld, totalNew = 0, 0
for _, case in ipairs(cases) do
	local board = BoardState.fromLayout(case.layout)
	local size = string.format("%dx%d", board.width, board.height)
	local targets = BoardState.countColor(board, "black")
	local newTime, result = timeIt(function()
		return PuzzleValidator.solve(board)
	end)
	local oldText, oldStates, speedup = "-", "-", "-"
	if case.reference then
		ReferenceSolver.stats.states = 0
		local oldTime, oldSolution = timeIt(function()
			return ReferenceSolver.findSolution(board)
		end)
		assert((oldSolution ~= nil) == (result.status == "solved"), "solvers disagree on " .. case.name)
		oldText = string.format("%.1f", oldTime * 1000)
		oldStates = tostring(ReferenceSolver.stats.states)
		speedup = string.format("%.0fx", oldTime / math.max(newTime, 1e-6))
		totalOld += oldTime
		totalNew += newTime
	end
	print(
		string.format(
			"%-16s %5s %7d %10s | %10s %8s | %10.2f %8d | %7s",
			case.name,
			size,
			targets,
			result.status,
			oldText,
			oldStates,
			newTime * 1000,
			result.states,
			speedup
		)
	)
end
print(string.format("Boards both solvers ran: old %.0f ms total, new %.1f ms total", totalOld * 1000, totalNew * 1000))

-- Exact par (shortest solution) for the shipped puzzles, old BFS against new.
for _, puzzle in ipairs(PuzzleDefinitions.list) do
	local board = BoardState.fromLayout(puzzle.layout)
	local oldTime, oldPar = timeIt(function()
		return (ReferenceSolver.shortestSolution(board))
	end)
	local newTime, newPar = timeIt(function()
		return (PuzzleValidator.shortestSolution(board))
	end)
	assert(oldPar == newPar, "par differs on " .. puzzle.id)
	print(string.format("par %-10s %3d   old %8.1f ms   new %6.2f ms", puzzle.id, newPar, oldTime * 1000, newTime * 1000))
end
