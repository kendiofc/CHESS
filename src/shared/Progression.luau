--!strict
-- Progression: the player profile and every rule that changes it. Pure logic
-- with no Roblox services, so the server and the tests share one copy.
--
-- The server never edits a profile directly. Each change is an op (a win, a
-- failed board, a restart, a hint) applied with Progression.apply. The same op
-- is applied twice: once at once to the in-memory profile the player sees, and
-- again inside the DataStore UpdateAsync transform, against whatever is
-- stored at that moment. That keeps saves correct even if another server
-- wrote in between, and makes them safe to retry:
--   * every op carries a unique id, and a profile remembers the ids it has
--     applied, so an op that reaches the store twice only counts once;
--   * rewards are keyed ("journey:<puzzle id>", the daily day number), so a
--     puzzle's reward is paid at most once ever and the daily reward at most
--     once per day, whichever server applies it.

local GameConfig = require(script.Parent.GameConfig)
local PuzzleDefinitions = require(script.Parent.PuzzleDefinitions)

local Progression = {}

Progression.VERSION = 1
Progression.APPLIED_MEMORY = 200 -- op ids remembered for de-duplication
local NONE = 1e9 -- "no best yet"; DataStores cannot store math.huge

export type Completion = {
	bestMoves: number,
	bestSeconds: number,
	solves: number,
	credited: boolean, -- solved in Journey or Daily: counts towards unlocks
}

export type Profile = {
	version: number,
	completed: { [string]: Completion },
	stats: { solves: number, fails: number, restarts: number, hints: number, moves: number },
	xp: number,
	coins: number,
	rewards: { [string]: boolean },
	daily: { day: number, completed: boolean, hintUsed: boolean, rewarded: boolean },
	applied: { string },
}

export type Op = {
	id: string,
	kind: string, -- "win" | "fail" | "restart" | "hint"
	puzzleId: string?,
	mode: string?,
	moves: number?,
	seconds: number?,
	day: number?,
}

export type Reward = { xp: number, coins: number, reason: string }

function Progression.newProfile(): Profile
	return {
		version = Progression.VERSION,
		completed = {},
		stats = { solves = 0, fails = 0, restarts = 0, hints = 0, moves = 0 },
		xp = 0,
		coins = 0,
		rewards = {},
		daily = { day = 0, completed = false, hintUsed = false, rewarded = false },
		applied = {},
	}
end

local function number(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

-- Turns whatever was stored (nil, an older or damaged record) into a valid
-- profile, keeping every field that is usable.
function Progression.normalize(data: any): Profile
	local profile = Progression.newProfile()
	if type(data) ~= "table" then
		return profile
	end
	if type(data.completed) == "table" then
		for id, record in pairs(data.completed) do
			if type(id) == "string" and type(record) == "table" then
				profile.completed[id] = {
					bestMoves = number(record.bestMoves, NONE),
					bestSeconds = number(record.bestSeconds, NONE),
					solves = number(record.solves, 1),
					credited = record.credited == true,
				}
			end
		end
	end
	if type(data.stats) == "table" then
		for key in pairs(profile.stats) do
			profile.stats[key] = number(data.stats[key], 0)
		end
	end
	profile.xp = number(data.xp, 0)
	profile.coins = number(data.coins, 0)
	if type(data.rewards) == "table" then
		for key, value in pairs(data.rewards) do
			if type(key) == "string" and value == true then
				profile.rewards[key] = true
			end
		end
	end
	if type(data.daily) == "table" then
		profile.daily = {
			day = number(data.daily.day, 0),
			completed = data.daily.completed == true,
			hintUsed = data.daily.hintUsed == true,
			rewarded = data.daily.rewarded == true,
		}
	end
	if type(data.applied) == "table" then
		for _, id in ipairs(data.applied) do
			if type(id) == "string" then
				table.insert(profile.applied, id)
			end
		end
	end
	return profile
end

-- Days ------------------------------------------------------------------------

function Progression.dayNumber(unixTime: number): number
	return unixTime // 86400 -- UTC days since 1970-01-01
end

-- The Daily Puzzle for a day: walks the daily pool in a fixed shuffled order
-- so neighbouring days differ in difficulty.
function Progression.dailyPuzzle(day: number): PuzzleDefinitions.Puzzle
	local pool = {}
	for _, difficulty in ipairs(GameConfig.DAILY_DIFFICULTIES) do
		for _, puzzle in ipairs(PuzzleDefinitions.byDifficulty[difficulty]) do
			table.insert(pool, puzzle)
		end
	end
	-- 7 is coprime with the pool size (18), so this visits every puzzle.
	return pool[(day * 7) % #pool + 1]
end

local function rollDaily(profile: Profile, day: number)
	if day > profile.daily.day then
		profile.daily = { day = day, completed = false, hintUsed = false, rewarded = false }
	end
end

-- Unlocks ---------------------------------------------------------------------

-- Highest difficulty index the player may play in Journey (1 = Beginner).
function Progression.unlockedIndex(profile: Profile): number
	local unlocked = 1
	for index = 1, #GameConfig.DIFFICULTIES - 1 do
		local credited = 0
		for _, puzzle in ipairs(PuzzleDefinitions.byDifficulty[GameConfig.DIFFICULTIES[index]]) do
			local record = profile.completed[puzzle.id]
			if record and record.credited then
				credited += 1
			end
		end
		if credited < GameConfig.UNLOCK_REQUIREMENT then
			break
		end
		unlocked = index + 1
	end
	return unlocked
end

-- Whether `puzzle` may be started in `mode` today. Returns ok, error code.
function Progression.canStart(profile: Profile, puzzle: PuzzleDefinitions.Puzzle, mode: string, day: number): (boolean, string?)
	if mode == GameConfig.PLAY_MODES.Practice then
		return true, nil
	elseif mode == GameConfig.PLAY_MODES.Journey then
		if puzzle.difficultyIndex > Progression.unlockedIndex(profile) then
			return false, "locked"
		end
		return true, nil
	elseif mode == GameConfig.PLAY_MODES.Daily then
		if puzzle.id ~= Progression.dailyPuzzle(day).id then
			return false, "not_daily"
		end
		return true, nil
	end
	return false, "bad_mode"
end

-- Hints -----------------------------------------------------------------------

-- How many more hints this attempt may use (math.huge for unlimited).
function Progression.hintsLeft(profile: Profile, mode: string, usedThisAttempt: number, day: number): number
	local allowance = GameConfig.HINTS[mode] or 0
	if mode == GameConfig.PLAY_MODES.Daily then
		local usedToday = profile.daily.day == day and profile.daily.hintUsed
		return if usedToday then 0 else allowance
	end
	return math.max(0, allowance - usedThisAttempt)
end

-- Applying ops ------------------------------------------------------------------

local function remember(profile: Profile, id: string)
	table.insert(profile.applied, id)
	while #profile.applied > Progression.APPLIED_MEMORY do
		table.remove(profile.applied, 1)
	end
end

local function applyWin(profile: Profile, op: Op): Reward?
	local puzzle = PuzzleDefinitions.get(op.puzzleId)
	if not puzzle then
		return nil
	end
	local moves, seconds = number(op.moves, NONE), number(op.seconds, NONE)
	local credited = op.mode == GameConfig.PLAY_MODES.Journey or op.mode == GameConfig.PLAY_MODES.Daily
	local record = profile.completed[puzzle.id]
	if record then
		record.bestMoves = math.min(record.bestMoves, moves)
		record.bestSeconds = math.min(record.bestSeconds, seconds)
		record.solves += 1
		record.credited = record.credited or credited
	else
		profile.completed[puzzle.id] = { bestMoves = moves, bestSeconds = seconds, solves = 1, credited = credited }
	end
	profile.stats.solves += 1
	profile.stats.moves += math.min(moves, 10000)

	local reward: Reward? = nil
	if op.mode == GameConfig.PLAY_MODES.Journey then
		local key = "journey:" .. puzzle.id
		if not profile.rewards[key] then
			profile.rewards[key] = true
			reward = { xp = puzzle.reward.xp, coins = puzzle.reward.coins, reason = "first clear" }
		end
	elseif op.mode == GameConfig.PLAY_MODES.Daily and op.day then
		rollDaily(profile, op.day)
		if profile.daily.day == op.day and puzzle.id == Progression.dailyPuzzle(op.day).id then
			profile.daily.completed = true
			if not profile.daily.rewarded then
				profile.daily.rewarded = true
				reward = { xp = GameConfig.DAILY_REWARD.xp, coins = GameConfig.DAILY_REWARD.coins, reason = "daily puzzle" }
			end
		end
	end
	if reward then
		profile.xp += reward.xp
		profile.coins += reward.coins
	end
	return reward
end

-- Applies one op. Returns whether it was new, and the reward it paid (if any).
function Progression.apply(profile: Profile, op: Op): (boolean, Reward?)
	if table.find(profile.applied, op.id) then
		return false, nil
	end
	remember(profile, op.id)
	if op.kind == "win" then
		return true, applyWin(profile, op)
	elseif op.kind == "fail" then
		profile.stats.fails += 1
	elseif op.kind == "restart" then
		profile.stats.restarts += 1
	elseif op.kind == "hint" then
		profile.stats.hints += 1
		if op.mode == GameConfig.PLAY_MODES.Daily and op.day then
			rollDaily(profile, op.day)
			if profile.daily.day == op.day then
				profile.daily.hintUsed = true
			end
		end
	end
	return true, nil
end

-- What the client needs to draw menus and progress. Never trusted back.
function Progression.summary(profile: Profile, day: number): { [string]: any }
	local completed = {}
	for id, record in pairs(profile.completed) do
		completed[id] = { bestMoves = record.bestMoves, credited = record.credited }
	end
	local today = profile.daily.day == day
	return {
		unlockedIndex = Progression.unlockedIndex(profile),
		unlockRequirement = GameConfig.UNLOCK_REQUIREMENT,
		completed = completed,
		xp = profile.xp,
		coins = profile.coins,
		stats = table.clone(profile.stats),
		daily = {
			day = day,
			puzzleId = Progression.dailyPuzzle(day).id,
			completed = today and profile.daily.completed,
			hintUsed = today and profile.daily.hintUsed,
		},
	}
end

return Progression
