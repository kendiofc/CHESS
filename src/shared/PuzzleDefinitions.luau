--!strict
-- PuzzleDefinitions: the Echo Clear puzzle catalogue, 6 puzzles for each of the
-- five difficulties.
--
-- Entries are written compactly and expanded below:
--   layout    rows top first, separated by "/" (format documented in BoardState)
--   solution  one shortest solution as "from-to" moves
--   hints     two hand-written hints: a strategic one, then a first step
-- Difficulty-wide settings (reward, estimated time) live in GameConfig.
--
-- How the puzzles were made: candidate boards came from tests/lib/BoardGen and
-- were scored with the solver (target count, par, share of capture orders that
-- clear the board). Each one was then picked by hand for its difficulty band,
-- named, and given hints written from its solution structure.
--
-- tests/run.luau checks every entry with PuzzleCheck: the solution replays
-- under the real rules, par is the true minimum, the solver and the original
-- Phase 2 solver both agree it is solvable, and its graded difficulty matches
-- the band it is filed under.

local GameConfig = require(script.Parent.GameConfig)

local PuzzleDefinitions = {}

export type Puzzle = {
	id: string,
	name: string,
	difficulty: string,
	difficultyIndex: number,
	number: number, -- position within its difficulty, from 1
	mode: string,
	objective: string,
	layout: { string },
	solution: { { string } },
	hints: { string },
	reward: { xp: number, coins: number },
	par: number,
	estimatedSeconds: number,
}

type Entry = { id: string, name: string, layout: string, solution: string, hints: { string } }

local CATALOG: { [string]: { Entry } } = {
	Beginner = {
		{
			id = "beginner-01",
			name = "Open Door",
			layout = "..r./#.r./.kQ./....",
			solution = "c2-b2 b2-c3 c3-c4",
			hints = {
				"Every order works here. Capture everything you can reach.",
				"The king right next to you is a fine first capture.",
			},
		},
		{
			id = "beginner-02",
			name = "Two Steps",
			layout = "...#/...n/..B./q...",
			solution = "c2-d3 d3-c1 c1-b3 b3-a1",
			hints = {
				"Your bishop can't reach the queen yet. Become something that can.",
				"Capture the knight on d3 first.",
			},
		},
		{
			id = "beginner-03",
			name = "Order Matters",
			layout = ".pr./...Q/..../....",
			solution = "d3-c4 c4-b4",
			hints = {
				"A pawn only moves up. Don't become one while there is still work to do.",
				"Take the rook on c4 first.",
			},
		},
		{
			id = "beginner-04",
			name = "First Echo",
			layout = "n..b/..../...r/Q.#.",
			solution = "a1-a4 a4-c3 c3-b1 b1-d2 d2-d4",
			hints = {
				"Your queen can reach all three pieces. Think about what you become after each capture.",
				"If you take the bishop first, take the rook straight after it.",
			},
		},
		{
			id = "beginner-05",
			name = "Long Way Round",
			layout = ".k.b/...N/..../.r..",
			solution = "d3-b4 b4-b3 b3-b2 b2-b1 b1-d1 d1-d4",
			hints = {
				"Quiet moves are free. Walk your piece to where it needs to be.",
				"Becoming the rook on b1 lets you sweep the bottom row.",
			},
		},
		{
			id = "beginner-06",
			name = "Pawn Last",
			layout = "k.../..N#/..p./.q..",
			solution = "c3-b1 b1-a1 a1-a4 a4-b3 b3-c2",
			hints = {
				"Once you become the pawn you can only move up. Save it for last.",
				"Start with the queen on b1.",
			},
		},
	},
	Easy = {
		{
			id = "easy-01",
			name = "Narrow Gate",
			layout = "..#k./b#pb#/...../..B../q....",
			solution = "c2-a4 a4-b5 b5-c4 c4-d5 d5-d4 d4-a1",
			hints = {
				"The walls split the board. Work out which piece gets you past them.",
				"Capture the pawn on c4 first.",
			},
		},
		{
			id = "easy-02",
			name = "Queen's Court",
			layout = "...../##B../p..q./...qk/#..k.",
			solution = "c4-d3 d3-e2 e2-d1 d1-d2 d2-b2 b2-a3",
			hints = {
				"The pawn on a3 has to be your last capture.",
				"Take the queen on d3 first.",
			},
		},
		{
			id = "easy-03",
			name = "Crowded Row",
			layout = "..Q../.qbrn/...../.#.#./p.#..",
			solution = "c5-c4 c4-d5 d5-e4 e4-c3 c3-d5 d5-b4 b4-d4 d4-a4 a4-a1",
			hints = {
				"Five pieces stand together. Pick an order that never leaves you stranded.",
				"Start with the pawn on a1, while there is room to climb.",
			},
		},
		{
			id = "easy-04",
			name = "Corner Knight",
			layout = "...b./.#..#/B..../q..../n.#pk",
			solution = "a3-b2 b2-a1 a1-c2 c2-e3 e3-d5 d5-a2 a2-d2 d2-e1 e1-d1",
			hints = {
				"The pawn on d1 must be the last capture.",
				"Capture the knight in the corner first.",
			},
		},
		{
			id = "easy-05",
			name = "Two Bishops",
			layout = ".b..#/....q/..R#./b..r./p....",
			solution = "c3-b3 b3-b5 b5-c4 c4-a2 a2-d5 d5-e4 e4-b4 b4-d2 d2-a2 a2-a1",
			hints = {
				"Finish on the pawn on a1 or the bishop on b5.",
				"Start with the bishop on a2.",
			},
		},
		{
			id = "easy-06",
			name = "Wall Garden",
			layout = ".q.#./..p.n/#.b../....k/R.#..",
			solution = "a1-a2 a2-e2 e2-d3 d3-c4 c4-b5 b5-b4 b4-e4 e4-c3",
			hints = {
				"The bishop in the middle should be your final capture.",
				"Once you are a pawn, the queen is your only way out.",
			},
		},
	},
	Medium = {
		{
			id = "medium-01",
			name = "Bishop Line",
			layout = "....b./..b#n./..b.../R....#/..p.../...#..",
			solution = "a3-a5 a5-c5 c5-d6 d6-e5 e5-c4 c4-d3 d3-f5 f5-e6 e6-f5 f5-c2",
			hints = {
				"Only one first capture works, and the pawn on c2 comes last.",
				"Begin with the bishop on c5.",
			},
		},
		{
			id = "medium-02",
			name = "Six Voices",
			layout = "r..#k/..b../#.n.p/q..../B.#..",
			solution = "a1-c3 c3-e4 e4-d2 d2-c4 c4-a2 a2-d2 d2-a5 a5-a4 a4-e4 e4-e5 e5-e4 e4-e3",
			hints = {
				"Start with the knight.",
				"Becoming the pawn early leaves you stuck. Take it last.",
			},
		},
		{
			id = "medium-03",
			name = "Royal Escort",
			layout = "...#p./...p../..k..#/kN.#b./....k./#.#...",
			solution = "b3-d4 d4-e2 e2-e3 e3-c5 c5-a3 a3-b3 b3-c4 c4-d5 d5-e6",
			hints = {
				"Kings are slow, but they can step anywhere. Use them to reposition.",
				"Capture the bishop on e3 first.",
			},
		},
		{
			id = "medium-04",
			name = "Far Corner",
			layout = ".k..##/.Qb.p./p...../.n#.../....../....n.",
			solution = "b5-a4 a4-a5 a5-b6 b6-b5 b5-b4 b4-b3 b3-c5 c5-f2 f2-e1 e1-f3 f3-e5",
			hints = {
				"The pawn on e5 must be the last capture.",
				"Start with the pawn on a4, while there is room to climb.",
			},
		},
		{
			id = "medium-05",
			name = "Knight School",
			layout = "#.#.#p/.....n/..nk.B/....../...n../.p.q#.",
			solution = "f4-d2 d2-b1 b1-b2 b2-b3 b3-c4 c4-d6 d6-f5 f5-e3 e3-d1 d1-d4 d4-e5 e5-f6",
			hints = {
				"Knights jump over walls. Use them to cross the board.",
				"Capture the knight on d2 first.",
			},
		},
		{
			id = "medium-06",
			name = "Last Light",
			layout = "b.p#../....b./...p../..#..#/....Qn/....b.",
			solution = "e2-e1 e1-d2 d2-e3 e3-d4 d4-e5 e5-d4 d4-f2 f2-d3 d3-b4 b4-a6 a6-b5 b5-c6",
			hints = {
				"Only two orders work. The pawn on c6 is the last capture.",
				"Start with the pawn on d4.",
			},
		},
	},
	Hard = {
		{
			id = "hard-01",
			name = "Rook Gate",
			layout = ".....p#/.rk.#b./#n.p.../.....#./....r../#..#.B./k......",
			solution = "f2-e3 e3-g3 g3-g6 g6-f6 f6-a1 a1-b2 b2-b3 b3-c4 c4-d5 d5-c6 c6-b6 b6-b5 b5-d6 d6-f7",
			hints = {
				"There is only one good first capture. The pawn on f7 comes last.",
				"Take the rook on e3 first.",
			},
		},
		{
			id = "hard-02",
			name = "Queen's Descent",
			layout = "p....Q./.b..#.#/##.r.../...#k../.#...../.#q.p../.....k.",
			solution = "f7-f1 f1-e1 e1-d1 d1-c2 c2-e4 e4-e3 e3-e2 e2-e3 e3-e4 e4-d5 d5-d6 d6-b6 b6-a7",
			hints = {
				"The pawn on a7 is on the top rank, so it must be last.",
				"Begin with the queen on c2.",
			},
		},
		{
			id = "hard-03",
			name = "Knight Fork",
			layout = "k.#..#./q....#./N....p./......./.b...#./p....../.p#.b.#",
			solution = "a5-b7 b7-c5 c5-d3 d3-e1 e1-f2 f2-a7 a7-a6 a6-d3 d3-b1 b1-a2 a2-b3 b3-e6 e6-f5",
			hints = {
				"Keep the pawn on f5 for last.",
				"Capture the bishop on e1 first.",
			},
		},
		{
			id = "hard-04",
			name = "Pawn Storm",
			layout = "......./...q.n./#..b.b./....p.#/......p/#.rn.../Rp.##..",
			solution = "a1-b1 b1-c2 c2-d2 d2-c4 c4-d6 d6-d5 d5-e6 e6-f5 f5-e4 e4-e5 e5-f6 f6-e4 e4-g3",
			hints = {
				"You have to become a pawn straight away. Plan where it climbs.",
				"Capture the pawn on b1 first.",
			},
		},
		{
			id = "hard-05",
			name = "Bishop's Gambit",
			layout = "#...##p/n....../..r..b./.....q./...r..k/....B../..p....",
			solution = "e2-g4 g4-f5 f5-e6 e6-c4 c4-a6 a6-c5 c5-c1 c1-c2 c2-d3 d3-g3 g3-f4 f4-g4 g4-g7",
			hints = {
				"The pawn on g7 can't move once you become it. Leave it for the end.",
				"Take the bishop on f5 first.",
			},
		},
		{
			id = "hard-06",
			name = "Long Diagonal",
			layout = "b..#..p/.....r./..##.../..k..../.b....p/.qp.#../B.....r",
			solution = "a1-b2 b2-c2 c2-b3 b3-c4 c4-b5 b5-b6 b6-a7 a7-b6 b6-c7 c7-g3 g3-g4 g4-g5 g5-f6 f6-g6 g6-g1 g1-g7",
			hints = {
				"Only one first capture works. The pawn on g7 comes last.",
				"Capture the queen on b2 first.",
			},
		},
	},
	Expert = {
		{
			id = "expert-01",
			name = "Watchtower",
			layout = "R...##../...#..../...n.#../#p....../...bp#.#/p.....b./.p...p../..#b...k",
			solution = "a8-c8 c8-c3 c3-d3 d3-d1 d1-f3 f3-h1 h1-h2 h2-g3 g3-f2 f2-f3 f3-e4 e4-e5 e5-d6 d6-f5 f5-d4 d4-b2 b2-a3 a3-a4 a4-b5",
			hints = {
				"The pawn on b5 must be your final capture.",
				"Starting with the pawn on e4 works.",
			},
		},
		{
			id = "expert-02",
			name = "Crossroads",
			layout = "...#..../...k..../n#p...../....Q.../.bpq#.b./......#./p.##..../b.......",
			solution = "e5-a5 a5-a2 a2-a3 a3-b4 b4-c3 c3-a1 a1-d4 d4-a1 a1-a6 a6-b8 b8-c6 c6-d7 d7-e6 e6-f5 f5-g4 g4-e6 e6-c4",
			hints = {
				"The pawn on c4 must be the last capture.",
				"Starting with the pawn on a2 works.",
			},
		},
		{
			id = "expert-03",
			name = "Kingsway",
			layout = ".#b..../.#q..pr/......./r.....p/.p.N.../.k...../.p.....",
			solution = "d3-e5 e5-g6 g6-g7 g7-c7 c7-e5 e5-b2 b2-b3 b3-b4 b4-b5 b5-c6 c6-c2 c2-b1 b1-b2 b2-b3 b3-a4 a4-g4 g4-g5 g5-f6",
			hints = {
				"Save the pawn on f6 for last.",
				"Starting with the bishop on c7 works.",
			},
		},
		{
			id = "expert-04",
			name = "Stone Garden",
			layout = "qr#B..##/.....#../..r...../....b.../..##...#/#...#r#./.#.#..../.rpnpq..",
			solution = "d8-f6 f6-e5 e5-b8 b8-a8 a8-a4 a4-d1 d1-f2 f2-d3 d3-e1 e1-e2 e2-f3 f3-f6 f6-c6 c6-f6 f6-f1 f1-f5 f5-b1 b1-c1",
			hints = {
				"Only one first capture works, and the pawn on c1 comes last.",
				"Capture the bishop on e5 first.",
			},
		},
		{
			id = "expert-05",
			name = "Narrow Path",
			layout = "p....#../#.#Rq.../.p.p#.#./.n...b#./#.....#./......#./.#b.p#.r/...#..p.",
			solution = "d7-d6 d6-e7 e7-b4 b4-e1 e1-g1 g1-h2 h2-h1 h1-e1 e1-e2 e2-e3 e3-e4 e4-f5 f5-c2 c2-d3 d3-b5 b5-d6 d6-c4 c4-b6 b6-b7 b7-a8",
			hints = {
				"Only four orders clear this board. The pawn on a8 is last.",
				"Take the pawn on d6 first.",
			},
		},
		{
			id = "expert-06",
			name = "Echo Chamber",
			layout = "..b..#.#/..nb..../B.#..p#./#p..#.##/q.p.#.../......../.#..k.../.b.p.p#.",
			solution = "a6-c8 c8-d7 d7-h3 h3-f1 f1-e2 e2-d2 d2-c2 c2-b1 b1-c2 c2-a4 a4-d1 d1-d2 d2-d3 d3-c4 c4-b5 b5-b6 b6-c7 c7-e8 e8-f6",
			hints = {
				"Only four orders clear this board. The pawn on f6 is last.",
				"Capture the bishop on c8 first.",
			},
		},
	},
}

local OBJECTIVE = "Capture every black piece. You become whatever you capture."

local function expand(entry: Entry, difficulty: string, difficultyIndex: number, number: number): Puzzle
	local solution = {}
	for from, to in string.gmatch(entry.solution, "(%a%d)%-(%a%d)") do
		table.insert(solution, { from, to })
	end
	local settings = GameConfig.DIFFICULTY_SETTINGS[difficulty]
	return {
		id = entry.id,
		name = entry.name,
		difficulty = difficulty,
		difficultyIndex = difficultyIndex,
		number = number,
		mode = GameConfig.MODES.EchoClear,
		objective = OBJECTIVE,
		layout = string.split(entry.layout, "/"),
		solution = solution,
		hints = entry.hints,
		reward = settings.reward,
		par = #solution,
		estimatedSeconds = settings.estimatedSeconds,
	}
end

local list: { Puzzle } = {}
local byId: { [string]: Puzzle } = {}
local byDifficulty: { [string]: { Puzzle } } = {}
for difficultyIndex, difficulty in ipairs(GameConfig.DIFFICULTIES) do
	byDifficulty[difficulty] = {}
	for number, entry in ipairs(CATALOG[difficulty] or {}) do
		local puzzle = expand(entry, difficulty, difficultyIndex, number)
		assert(not byId[puzzle.id], "duplicate puzzle id " .. puzzle.id)
		table.insert(list, puzzle)
		table.insert(byDifficulty[difficulty], puzzle)
		byId[puzzle.id] = puzzle
	end
end

PuzzleDefinitions.list = list
PuzzleDefinitions.byDifficulty = byDifficulty

function PuzzleDefinitions.get(id: any): Puzzle?
	if type(id) ~= "string" then
		return nil
	end
	return byId[id]
end

-- Returns the puzzle after the given one, wrapping to the first.
function PuzzleDefinitions.nextAfter(id: string): Puzzle
	for i, puzzle in ipairs(list) do
		if puzzle.id == id then
			return list[i % #list + 1]
		end
	end
	return list[1]
end

return PuzzleDefinitions
