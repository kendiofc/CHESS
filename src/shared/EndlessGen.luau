--!strict
-- EndlessGen: the generated boards of Endless mode.
--
-- A run is a seed chosen by the server. Board n of a run is built from the
-- seed and n alone, so the same run always gets the same boards. Boards grow
-- with n (see TIERS): bigger grids, more targets and more walls, up to 8x8
-- with 12 targets from board 40 on. The difficulty shown is the tier's
-- typical PuzzleCheck grade.
--
-- Each candidate is a random layout like tests/lib/BoardGen's, kept only if
-- the solver proves it can be cleared within a state budget, so no board is
-- unsolvable and no check can stall the server. Endless boards have no par:
-- an exact par costs far more than a solvability check on large boards.

local BoardState = require(script.Parent.BoardState)
local GameConfig = require(script.Parent.GameConfig)
local PuzzleValidator = require(script.Parent.PuzzleValidator)

local EndlessGen = {}

-- from: first board of the tier. Targets grow by one every `every` boards
-- inside a tier, up to `maxTargets`.
local TIERS = {
	{ from = 1, size = 4, targets = 2, maxTargets = 3, every = 1, walls = 6, difficulty = "Beginner" },
	{ from = 3, size = 5, targets = 4, maxTargets = 5, every = 2, walls = 10, difficulty = "Easy" },
	{ from = 6, size = 6, targets = 5, maxTargets = 6, every = 2, walls = 12, difficulty = "Easy" },
	{ from = 10, size = 7, targets = 7, maxTargets = 8, every = 3, walls = 12, difficulty = "Medium" },
	{ from = 15, size = 8, targets = 8, maxTargets = 10, every = 4, walls = 14, difficulty = "Medium" },
	{ from = 30, size = 8, targets = 11, maxTargets = 12, every = 10, walls = 15, difficulty = "Hard" },
}

EndlessGen.TIERS = TIERS
EndlessGen.SOLVER_BUDGET = 20000 -- states per candidate
EndlessGen.MAX_TRIES = 300

local KINDS = { "Q", "R", "B", "N", "K", "P" }
local OBJECTIVE = "Clear the board to reach the next one. A dead end or a restart costs a life."

export type Spec = { size: number, targets: number, walls: number, difficulty: string, tier: number }

function EndlessGen.spec(n: number): Spec
	local index = 1
	for i, tier in ipairs(TIERS) do
		if n >= tier.from then
			index = i
		end
	end
	local tier = TIERS[index]
	local targets = math.min(tier.maxTargets, tier.targets + (n - tier.from) // tier.every)
	return { size = tier.size, targets = targets, walls = tier.walls, difficulty = tier.difficulty, tier = index }
end

-- Park-Miller generator, like BoardGen, so boards match on every runtime.
local function rng(seed: number): (number) -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return function(n: number): number
		state = (state * 48271) % 2147483647
		return state % n + 1
	end
end

local function candidate(roll: (number) -> number, spec: Spec): { string }
	local size = spec.size
	local cells = table.create(size * size, ".")
	local free = {}
	for i = 1, size * size do
		table.insert(free, i)
	end
	local function take(): number
		local pick = roll(#free)
		local index = free[pick]
		free[pick] = free[#free]
		free[#free] = nil
		return index
	end
	cells[take()] = KINDS[roll(4)] -- the player starts as a Q, R, B or N
	for _ = 1, spec.targets do
		cells[take()] = string.lower(KINDS[roll(#KINDS)])
	end
	for _ = 1, math.floor(size * size * spec.walls / 100) do
		cells[take()] = "#"
	end
	local layout = {}
	for row = 1, size do
		table.insert(layout, table.concat(cells, "", (row - 1) * size + 1, row * size))
	end
	return layout
end

-- Whether a layout can be cleared, proven within the budget.
function EndlessGen.solvable(layout: { string }): boolean
	local board = BoardState.fromLayout(layout)
	return PuzzleValidator.solve(board, { maxStates = EndlessGen.SOLVER_BUDGET }).status == "solved"
end

-- Board n of the run with this seed, as a puzzle PuzzleSession can play.
-- Returns nil only if no candidate passed (never seen in testing).
function EndlessGen.board(seed: number, n: number): any
	local spec = EndlessGen.spec(n)
	local roll = rng((seed % 1000003) * 7919 + n * 104729 + 1)
	for _ = 1, EndlessGen.MAX_TRIES do
		local layout = candidate(roll, spec)
		if EndlessGen.solvable(layout) then
			return {
				id = "endless-" .. n,
				name = "Board " .. n,
				difficulty = spec.difficulty,
				difficultyIndex = table.find(GameConfig.DIFFICULTIES, spec.difficulty) or 1,
				number = n,
				mode = GameConfig.MODES.EchoClear,
				objective = OBJECTIVE,
				layout = layout,
				solution = {},
				hints = {},
				reward = { xp = 0, coins = 0 },
				par = nil,
				estimatedSeconds = 0,
				endless = true,
			}
		end
	end
	return nil
end

return EndlessGen
