--!strict
-- PuzzleDefinitions: handcrafted puzzles. Layout format is documented in
-- BoardState. Every puzzle here is checked by tests/run.luau: the stored
-- solution must replay legally and clear the board, and the solver must agree
-- the start position is solvable.
--
-- Prototype set (Phase 2). The full 30-puzzle catalogue arrives in Phase 3.

local PuzzleDefinitions = {}

export type Puzzle = {
	id: string,
	name: string,
	difficulty: string,
	mode: string,
	objective: string,
	layout: { string },
	solution: { { string } },
	hints: { string },
	reward: { xp: number, coins: number },
	par: number,
	estimatedSeconds: number,
}

local list: { Puzzle } = {
	{
		id = "proto-01",
		name = "First Echo",
		difficulty = "Beginner",
		mode = "EchoClear",
		objective = "Capture every black piece. You become whatever you capture.",
		layout = {
			"n..b",
			"....",
			"...r",
			"Q.#.",
		},
		solution = { { "a1", "a4" }, { "a4", "c3" }, { "c3", "b1" }, { "b1", "d2" }, { "d2", "d4" } },
		hints = {
			"Your queen can reach all three pieces. Think about what you become after each capture.",
			"If you take the bishop first, take the rook straight after it.",
		},
		reward = { xp = 20, coins = 5 },
		par = 5,
		estimatedSeconds = 60,
	},
	{
		id = "proto-02",
		name = "Wall Garden",
		difficulty = "Easy",
		mode = "EchoClear",
		objective = "Capture every black piece. You become whatever you capture.",
		layout = {
			".q.#.",
			"..p.n",
			"#.b..",
			"....k",
			"R.#..",
		},
		solution = {
			{ "a1", "b1" },
			{ "b1", "b4" },
			{ "b4", "c4" },
			{ "c4", "b5" },
			{ "b5", "e2" },
			{ "e2", "e3" },
			{ "e3", "e4" },
			{ "e4", "c3" },
		},
		hints = {
			"The bishop in the middle should be your final capture.",
			"Once you are a pawn, the queen is your only way out.",
		},
		reward = { xp = 35, coins = 8 },
		par = 8,
		estimatedSeconds = 120,
	},
	{
		id = "proto-03",
		name = "Six Voices",
		difficulty = "Medium",
		mode = "EchoClear",
		objective = "Capture every black piece. You become whatever you capture.",
		layout = {
			"r..#k",
			"..b..",
			"#.n.p",
			"q....",
			"B.#..",
		},
		solution = {
			{ "a1", "c3" },
			{ "c3", "e4" },
			{ "e4", "d2" },
			{ "d2", "b3" },
			{ "b3", "a5" },
			{ "a5", "c5" },
			{ "c5", "c4" },
			{ "c4", "a2" },
			{ "a2", "b2" },
			{ "b2", "e5" },
			{ "e5", "e4" },
			{ "e4", "e3" },
		},
		hints = {
			"Start with the knight.",
			"Becoming the pawn early leaves you stuck. Take it last.",
		},
		reward = { xp = 50, coins = 12 },
		par = 12,
		estimatedSeconds = 240,
	},
}

PuzzleDefinitions.list = list

local byId: { [string]: Puzzle } = {}
for _, puzzle in ipairs(list) do
	assert(not byId[puzzle.id], "duplicate puzzle id " .. puzzle.id)
	byId[puzzle.id] = puzzle
end

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
