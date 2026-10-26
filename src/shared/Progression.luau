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
--     once per day, whichever server applies it. Achievements pay under
--     "ach:<id>" the same way;
--   * the Daily streak only moves forward: an op for a day at or before the
--     last counted day changes nothing;
--   * Weekly Challenge milestones pay under "weekly:<week>:<n>", once ever;
--   * a duel is counted once per match id (profile.duel.recent remembers the
--     last ones, on top of the op id), whichever server applies it.

local Achievements = require(script.Parent.Achievements)
local GameConfig = require(script.Parent.GameConfig)
local PuzzleDefinitions = require(script.Parent.PuzzleDefinitions)
local WeeklyChallenge = require(script.Parent.WeeklyChallenge)

local Progression = {}

Progression.VERSION = 1
Progression.APPLIED_MEMORY = 200 -- op ids remembered for de-duplication
local NONE = 1e9 -- "no best yet"; DataStores cannot store math.huge

export type Completion = {
	bestMoves: number,
	bestSeconds: number,
	solves: number,
	credited: boolean, -- solved in Journey or Daily: counts towards unlocks
	stars: number, -- best star rating from a Journey or Daily clear (0 = none)
}

export type Streak = {
	current: number, -- consecutive Daily clears ending on lastDay
	longest: number,
	lastDay: number, -- last UTC day a Daily was cleared (0 = never)
	shieldUsedOn: number, -- day a shield last covered a missed day
	protectedDay: number, -- the missed day that shield covered (0 = none)
}

export type Duel = {
	played: number,
	wins: number,
	losses: number,
	draws: number,
	day: number, -- UTC day the two counters below belong to
	rewardedToday: number, -- duels that paid a reward on `day`
	opponentsToday: { number }, -- user ids of opponents that paid a reward on `day`
	recent: { string }, -- last match ids counted
}

export type Settings = { sound: boolean, volume: number, haptics: boolean, drag: boolean }

export type Profile = {
	version: number,
	completed: { [string]: Completion },
	stats: { solves: number, fails: number, restarts: number, hints: number, moves: number, dailies: number, weeklies: number },
	xp: number,
	coins: number,
	rewards: { [string]: boolean },
	daily: { day: number, completed: boolean, hintUsed: boolean, rewarded: boolean },
	streak: Streak,
	weekly: { week: number, cleared: { [string]: boolean } }, -- the current week's cleared challenge puzzles
	duel: Duel,
	lastJourney: string?, -- last puzzle cleared in Journey (where Continue resumes)
	settings: Settings,
	tutorial: { done: boolean, outcome: string? }, -- "completed" or "skipped"
	cosmetics: { owned: { [string]: boolean }, equipped: { [string]: string } },
	applied: { string },
}

export type Op = {
	id: string,
	kind: string, -- "win" | "fail" | "restart" | "hint" | "settings" | "tutorial" | "duel"
	puzzleId: string?,
	mode: string?,
	moves: number?,
	seconds: number?,
	day: number?,
	settings: { [string]: any }?,
	outcome: string?, -- tutorial ops; duel ops: "win" | "loss" | "draw"
	matchId: string?, -- duel ops
	reason: string?, -- duel ops: "solved" | "timeout" | "opponent_left" | "left"
	opponent: number?, -- duel ops: the opponent's user id
}

-- What one op paid. `items` lists each part (first clear, daily, achievements).
export type Reward = {
	xp: number,
	coins: number,
	reason: string,
	items: { { xp: number, coins: number, reason: string, achievement: string? } },
}

local NO_SHIELD = -NONE -- shieldUsedOn before any shield was used

local function newStreak(): Streak
	return { current = 0, longest = 0, lastDay = 0, shieldUsedOn = NO_SHIELD, protectedDay = 0 }
end

local function newDuel(): Duel
	return { played = 0, wins = 0, losses = 0, draws = 0, day = 0, rewardedToday = 0, opponentsToday = {}, recent = {} }
end

Progression.DUEL_RECENT = 30 -- match ids remembered for de-duplication

function Progression.newProfile(): Profile
	return {
		version = Progression.VERSION,
		completed = {},
		stats = { solves = 0, fails = 0, restarts = 0, hints = 0, moves = 0, dailies = 0, weeklies = 0 },
		xp = 0,
		coins = 0,
		rewards = {},
		daily = { day = 0, completed = false, hintUsed = false, rewarded = false },
		streak = newStreak(),
		weekly = { week = 0, cleared = {} },
		duel = newDuel(),
		lastJourney = nil,
		settings = table.clone(GameConfig.DEFAULT_SETTINGS),
		tutorial = { done = false, outcome = nil },
		cosmetics = { owned = {}, equipped = table.clone(GameConfig.COSMETIC_SLOTS) },
		applied = {},
	}
end

local function number(value: any, default: number): number
	return if type(value) == "number" and value == value then value else default
end

local function wholeNumber(value: any, default: number, low: number, high: number): number
	return math.clamp(math.floor(number(value, default)), low, high)
end

-- Copies the valid fields of `values` into the profile's settings; anything
-- else (wrong types, out of range, unknown keys) is ignored.
function Progression.applySettings(profile: Profile, values: { [string]: any })
	if type(values.sound) == "boolean" then
		profile.settings.sound = values.sound
	end
	if type(values.haptics) == "boolean" then
		profile.settings.haptics = values.haptics
	end
	if type(values.drag) == "boolean" then
		profile.settings.drag = values.drag
	end
	if type(values.volume) == "number" and values.volume == values.volume then
		profile.settings.volume = math.clamp(math.floor(values.volume * 20 + 0.5) / 20, 0, 1)
	end
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
					stars = if record.credited == true then wholeNumber(record.stars, 0, 0, 3) else 0,
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
	if type(data.streak) == "table" then
		local streak = data.streak
		profile.streak = {
			current = wholeNumber(streak.current, 0, 0, NONE),
			longest = wholeNumber(streak.longest, 0, 0, NONE),
			lastDay = wholeNumber(streak.lastDay, 0, 0, NONE),
			shieldUsedOn = wholeNumber(streak.shieldUsedOn, NO_SHIELD, NO_SHIELD, NONE),
			protectedDay = wholeNumber(streak.protectedDay, 0, 0, NONE),
		}
		profile.streak.longest = math.max(profile.streak.longest, profile.streak.current)
	end
	if type(data.weekly) == "table" then
		profile.weekly.week = wholeNumber(data.weekly.week, 0, 0, NONE)
		if type(data.weekly.cleared) == "table" then
			for id, value in pairs(data.weekly.cleared) do
				if type(id) == "string" and value == true and WeeklyChallenge.contains(profile.weekly.week, id) then
					profile.weekly.cleared[id] = true
				end
			end
		end
	end
	if type(data.duel) == "table" then
		local duel = data.duel
		for _, key in ipairs({ "played", "wins", "losses", "draws", "day", "rewardedToday" }) do
			(profile.duel :: any)[key] = wholeNumber(duel[key], 0, 0, NONE)
		end
		if type(duel.opponentsToday) == "table" then
			for _, id in ipairs(duel.opponentsToday) do
				if type(id) == "number" then
					table.insert(profile.duel.opponentsToday, id)
				end
			end
		end
		if type(duel.recent) == "table" then
			for _, id in ipairs(duel.recent) do
				if type(id) == "string" then
					table.insert(profile.duel.recent, id)
				end
			end
		end
	end
	if type(data.lastJourney) == "string" and PuzzleDefinitions.get(data.lastJourney) then
		profile.lastJourney = data.lastJourney
	end
	if type(data.settings) == "table" then
		Progression.applySettings(profile, data.settings)
	end
	if type(data.tutorial) == "table" and data.tutorial.done == true then
		local outcome = data.tutorial.outcome
		profile.tutorial = {
			done = true,
			outcome = if outcome == "completed" or outcome == "skipped" then outcome else nil,
		}
	end
	if type(data.cosmetics) == "table" then
		if type(data.cosmetics.owned) == "table" then
			for id, owned in pairs(data.cosmetics.owned) do
				if type(id) == "string" and owned == true then
					profile.cosmetics.owned[id] = true
				end
			end
		end
		if type(data.cosmetics.equipped) == "table" then
			for slot, default in pairs(GameConfig.COSMETIC_SLOTS) do
				local id = data.cosmetics.equipped[slot]
				-- Only defaults or owned items can be equipped.
				if type(id) == "string" and (id == default or profile.cosmetics.owned[id]) then
					profile.cosmetics.equipped[slot] = id
				end
			end
		end
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

-- Tutorial ----------------------------------------------------------------------

-- Whether to start the tutorial automatically: only for players who have
-- neither finished nor skipped it and haven't cleared any puzzle (so players
-- from before the tutorial existed aren't interrupted).
function Progression.needsTutorial(profile: Profile): boolean
	return not profile.tutorial.done and next(profile.completed) == nil
end

-- Stars -----------------------------------------------------------------------

-- Most moves that still earn 2 stars on `puzzle`.
function Progression.twoStarMoves(puzzle: PuzzleDefinitions.Puzzle): number
	local override = (puzzle :: any).twoStarMoves
	if type(override) == "number" then
		return override
	end
	return puzzle.par + (GameConfig.STAR_SLACK[puzzle.difficulty] or 2)
end

-- Star rating for clearing `puzzle` in `moves` moves. Hints never count.
function Progression.starsFor(puzzle: PuzzleDefinitions.Puzzle, moves: number): number
	if moves <= puzzle.par then
		return 3
	elseif moves <= Progression.twoStarMoves(puzzle) then
		return 2
	end
	return 1
end

-- Level -------------------------------------------------------------------------

-- A level shown on the home screen, worked out from total XP. It's display
-- only: nothing is saved for it and nothing is paid for reaching one. Going
-- from level L to L + 1 takes LEVEL_STEP * L XP, so level 2 is at 100 XP,
-- level 3 at 300, level 4 at 600.
Progression.LEVEL_STEP = 100

function Progression.levelOf(xp: number): { level: number, into: number, needed: number }
	local total = tonumber(xp) or 0
	if total ~= total or total < 0 then
		total = 0
	end
	-- Capped so a corrupt value can't make the loop run forever.
	xp = math.floor(math.min(total, 1e9))
	local level, floor = 1, 0
	while xp >= floor + Progression.LEVEL_STEP * level do
		floor += Progression.LEVEL_STEP * level
		level += 1
	end
	return { level = level, into = xp - floor, needed = Progression.LEVEL_STEP * level }
end

-- Daily streak ------------------------------------------------------------------

local function shieldReady(streak: Streak, day: number): boolean
	return day - streak.shieldUsedOn >= GameConfig.STREAK_SHIELD_DAYS
end

-- Counts a Daily clear on `day`. Returns whether a shield was used.
local function advanceStreak(profile: Profile, day: number): boolean
	local streak = profile.streak
	if day <= streak.lastDay then
		return false -- already counted, or a late op for an earlier day
	end
	local gap = day - streak.lastDay
	local shielded = false
	if streak.lastDay > 0 and gap == 1 then
		streak.current += 1
	elseif streak.lastDay > 0 and gap == 2 and streak.current > 0 and shieldReady(streak, day) then
		-- One missed day, covered by the shield. The missed day pays nothing.
		streak.current += 1
		streak.shieldUsedOn = day
		streak.protectedDay = day - 1
		shielded = true
	else
		streak.current = 1
	end
	streak.lastDay = day
	streak.longest = math.max(streak.longest, streak.current)
	return shielded
end

-- The streak as it stands on `day`, for display. `current` is 0 once the
-- streak can no longer be continued; `atRisk` means yesterday was missed and
-- clearing today will use the shield.
function Progression.streakView(profile: Profile, day: number): { [string]: any }
	local streak = profile.streak
	local gap = day - streak.lastDay
	local alive = streak.lastDay > 0 and streak.current > 0 and (gap <= 1 or (gap == 2 and shieldReady(streak, day)))
	local readyDay = streak.shieldUsedOn + GameConfig.STREAK_SHIELD_DAYS
	return {
		current = if alive then streak.current else 0,
		longest = streak.longest,
		clearedToday = streak.lastDay == day,
		atRisk = alive and gap == 2,
		shieldReady = shieldReady(streak, day),
		shieldReadyDay = if readyDay > day then readyDay else day,
		shieldUsedOn = if streak.shieldUsedOn > 0 then streak.shieldUsedOn else nil,
		protectedDay = if streak.protectedDay > 0 then streak.protectedDay else nil,
	}
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

-- Credited clears per difficulty and what each needs to unlock the next.
function Progression.unlockProgress(profile: Profile): { { [string]: any } }
	local unlocked = Progression.unlockedIndex(profile)
	local rows = {}
	for index, difficulty in ipairs(GameConfig.DIFFICULTIES) do
		local credited = 0
		for _, puzzle in ipairs(PuzzleDefinitions.byDifficulty[difficulty]) do
			local record = profile.completed[puzzle.id]
			if record and record.credited then
				credited += 1
			end
		end
		table.insert(rows, {
			difficulty = difficulty,
			credited = credited,
			total = #PuzzleDefinitions.byDifficulty[difficulty],
			required = GameConfig.UNLOCK_REQUIREMENT,
			unlocked = index <= unlocked,
		})
	end
	return rows
end

-- The Journey puzzle Continue should open: the first puzzle after the last
-- Journey clear (in catalogue order, wrapping round) that is unlocked and not
-- yet cleared in Journey or Daily. nil once every unlocked puzzle is cleared.
function Progression.nextJourneyPuzzle(profile: Profile): PuzzleDefinitions.Puzzle?
	local list = PuzzleDefinitions.list
	local unlocked = Progression.unlockedIndex(profile)
	local last = profile.lastJourney and PuzzleDefinitions.get(profile.lastJourney)
	local start = if last then (table.find(list, last) or 0) else 0
	for step = 1, #list do
		local puzzle = list[(start + step - 1) % #list + 1]
		local record = profile.completed[puzzle.id]
		if puzzle.difficultyIndex <= unlocked and not (record and record.credited) then
			return puzzle
		end
	end
	return nil
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
	elseif mode == GameConfig.PLAY_MODES.Weekly then
		if not WeeklyChallenge.contains(WeeklyChallenge.weekOfDay(day), puzzle.id) then
			return false, "not_weekly"
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
	local credited = op.mode == GameConfig.PLAY_MODES.Journey
		or op.mode == GameConfig.PLAY_MODES.Daily
		or op.mode == GameConfig.PLAY_MODES.Weekly
	-- Stars come from the server's own move count, and only credited clears keep them.
	local stars = if credited then Progression.starsFor(puzzle, moves) else 0
	local record = profile.completed[puzzle.id]
	if record then
		record.bestMoves = math.min(record.bestMoves, moves)
		record.bestSeconds = math.min(record.bestSeconds, seconds)
		record.solves += 1
		record.credited = record.credited or credited
		record.stars = math.max(record.stars, stars)
	else
		profile.completed[puzzle.id] =
			{ bestMoves = moves, bestSeconds = seconds, solves = 1, credited = credited, stars = stars }
	end
	profile.stats.solves += 1
	profile.stats.moves += math.min(moves, 10000)

	local items = {}
	if op.mode == GameConfig.PLAY_MODES.Journey then
		profile.lastJourney = puzzle.id
		local key = "journey:" .. puzzle.id
		if not profile.rewards[key] then
			profile.rewards[key] = true
			table.insert(items, { xp = puzzle.reward.xp, coins = puzzle.reward.coins, reason = "first clear" })
		end
	elseif op.mode == GameConfig.PLAY_MODES.Daily and op.day then
		rollDaily(profile, op.day)
		if profile.daily.day == op.day and puzzle.id == Progression.dailyPuzzle(op.day).id then
			profile.daily.completed = true
			if not profile.daily.rewarded then
				profile.daily.rewarded = true
				profile.stats.dailies += 1
				advanceStreak(profile, op.day)
				table.insert(items, { xp = GameConfig.DAILY_REWARD.xp, coins = GameConfig.DAILY_REWARD.coins, reason = "daily puzzle" })
			end
		end
	elseif op.mode == GameConfig.PLAY_MODES.Weekly and op.day then
		-- The week the attempt started in; a late op for an earlier week counts
		-- for nothing once the profile has moved on.
		local week = WeeklyChallenge.weekOfDay(op.day)
		if week > profile.weekly.week then
			profile.weekly = { week = week, cleared = {} }
		end
		if profile.weekly.week == week and WeeklyChallenge.contains(week, puzzle.id) then
			profile.weekly.cleared[puzzle.id] = true
			local cleared = 0
			for _ in pairs(profile.weekly.cleared) do
				cleared += 1
			end
			for _, milestone in ipairs(WeeklyChallenge.MILESTONES) do
				local key = WeeklyChallenge.rewardKey(week, milestone.cleared)
				if cleared >= milestone.cleared and not profile.rewards[key] then
					profile.rewards[key] = true
					if milestone.cleared >= WeeklyChallenge.SIZE then
						profile.stats.weeklies += 1
					end
					table.insert(items, { xp = milestone.xp, coins = milestone.coins, reason = milestone.reason })
				end
			end
		end
	end
	if credited then
		for _, achievement in ipairs(Achievements.list) do
			local key = Achievements.rewardKey(achievement.id)
			if not profile.rewards[key] and achievement.check(profile) then
				profile.rewards[key] = true
				table.insert(items, { xp = 0, coins = achievement.coins, reason = achievement.name, achievement = achievement.id })
			end
		end
	end
	if #items == 0 then
		return nil
	end
	local reward: Reward = { xp = 0, coins = 0, reason = items[1].reason, items = items }
	for _, item in ipairs(items) do
		reward.xp += item.xp
		reward.coins += item.coins
	end
	profile.xp += reward.xp
	profile.coins += reward.coins
	return reward
end

-- Duels ---------------------------------------------------------------------------

local function rollDuelDay(duel: Duel, day: number)
	if day > duel.day then
		duel.day = day
		duel.rewardedToday = 0
		duel.opponentsToday = {}
	end
end

-- Why a duel finished on `day` against `opponent` would pay nothing, or nil
-- when it can pay: "daily_cap" or "same_opponent".
function Progression.duelRewardBlock(profile: Profile, day: number, opponent: number): string?
	local duel = profile.duel
	if duel.day == day then
		if table.find(duel.opponentsToday, opponent) then
			return "same_opponent"
		elseif duel.rewardedToday >= GameConfig.DUEL.DAILY_REWARDED then
			return "daily_cap"
		end
	elseif day < duel.day then
		return "daily_cap" -- a late op for a day that has passed
	end
	return nil
end

local function applyDuel(profile: Profile, op: Op): Reward?
	local matchId, outcome = op.matchId, op.outcome
	if type(matchId) ~= "string" or matchId == "" then
		return nil
	end
	if outcome ~= "win" and outcome ~= "loss" and outcome ~= "draw" then
		return nil
	end
	local duel = profile.duel
	if table.find(duel.recent, matchId) then
		return nil -- this match was already counted
	end
	table.insert(duel.recent, matchId)
	while #duel.recent > Progression.DUEL_RECENT do
		table.remove(duel.recent, 1)
	end
	duel.played += 1
	if outcome == "win" then
		duel.wins += 1
	elseif outcome == "loss" then
		duel.losses += 1
	else
		duel.draws += 1
	end
	local day, opponent = op.day, op.opponent
	if outcome == "loss" or type(day) ~= "number" or type(opponent) ~= "number" then
		return nil
	end
	if Progression.duelRewardBlock(profile, day, opponent) then
		return nil
	end
	rollDuelDay(duel, day)
	duel.rewardedToday += 1
	table.insert(duel.opponentsToday, opponent)
	-- A win because the opponent left pays like a draw, so leaving on purpose
	-- doesn't hand a second account a full win.
	local full = outcome == "win" and op.reason == "solved"
	local amount = if full then GameConfig.DUEL.REWARD_WIN else GameConfig.DUEL.REWARD_DRAW
	local reason = if full then "duel win" elseif outcome == "win" then "duel win (opponent left)" else "duel draw"
	profile.xp += amount.xp
	profile.coins += amount.coins
	return { xp = amount.xp, coins = amount.coins, reason = reason, items = { { xp = amount.xp, coins = amount.coins, reason = reason } } }
end

-- Applies one op. Returns whether it was new, and the reward it paid (if any).
function Progression.apply(profile: Profile, op: Op): (boolean, Reward?)
	if table.find(profile.applied, op.id) then
		return false, nil
	end
	remember(profile, op.id)
	if op.kind == "win" then
		return true, applyWin(profile, op)
	elseif op.kind == "duel" then
		return true, applyDuel(profile, op)
	elseif op.kind == "fail" then
		profile.stats.fails += 1
	elseif op.kind == "restart" then
		profile.stats.restarts += 1
	elseif op.kind == "tutorial" then
		if op.outcome == "completed" or op.outcome == "skipped" then
			-- A completion is kept over an earlier skip, never the other way.
			if not (profile.tutorial.done and profile.tutorial.outcome == "completed") then
				profile.tutorial = { done = true, outcome = op.outcome }
			end
		end
	elseif op.kind == "settings" then
		if type(op.settings) == "table" then
			Progression.applySettings(profile, op.settings :: any)
		end
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
	local cleared = 0
	for id, record in pairs(profile.completed) do
		completed[id] = {
			bestMoves = record.bestMoves,
			bestSeconds = if record.bestSeconds < NONE then record.bestSeconds else nil,
			credited = record.credited,
			stars = record.stars,
			solves = record.solves,
		}
		if record.credited then
			cleared += 1
		end
	end
	local earned = {}
	for _, achievement in ipairs(Achievements.list) do
		if profile.rewards[Achievements.rewardKey(achievement.id)] then
			earned[achievement.id] = true
		end
	end
	local stars, perfect = Achievements.starTotals(profile)
	local resume = Progression.nextJourneyPuzzle(profile)
	local today = profile.daily.day == day
	return {
		resumeId = resume and resume.id,
		unlocks = Progression.unlockProgress(profile),
		totals = {
			cleared = cleared,
			puzzles = #PuzzleDefinitions.list,
			stars = stars,
			maxStars = 3 * #PuzzleDefinitions.list,
			perfect = perfect,
		},
		streak = Progression.streakView(profile, day),
		achievements = earned,
		settings = table.clone(profile.settings),
		tutorialDone = profile.tutorial.done,
		needsTutorial = Progression.needsTutorial(profile),
		equipped = table.clone(profile.cosmetics.equipped),
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
		weekly = Progression.weeklyView(profile, day),
		duel = {
			played = profile.duel.played,
			wins = profile.duel.wins,
			losses = profile.duel.losses,
			draws = profile.duel.draws,
			rewardsLeftToday = if profile.duel.day == day
				then math.max(0, GameConfig.DUEL.DAILY_REWARDED - profile.duel.rewardedToday)
				else GameConfig.DUEL.DAILY_REWARDED,
		},
	}
end

-- This week's challenge as the player stands in it on `day`.
function Progression.weeklyView(profile: Profile, day: number): { [string]: any }
	local week = WeeklyChallenge.weekOfDay(day)
	local current = profile.weekly.week == week
	local ids, clearedIds, cleared = {}, {}, 0
	for _, puzzle in ipairs(WeeklyChallenge.puzzles(week)) do
		table.insert(ids, puzzle.id)
		if current and profile.weekly.cleared[puzzle.id] then
			clearedIds[puzzle.id] = true
			cleared += 1
		end
	end
	local milestones = {}
	for _, milestone in ipairs(WeeklyChallenge.MILESTONES) do
		table.insert(milestones, {
			cleared = milestone.cleared,
			xp = milestone.xp,
			coins = milestone.coins,
			claimed = profile.rewards[WeeklyChallenge.rewardKey(week, milestone.cleared)] == true,
		})
	end
	return {
		week = week,
		firstDay = WeeklyChallenge.firstDay(week),
		puzzleIds = ids,
		cleared = clearedIds,
		clearedCount = cleared,
		size = #ids,
		completed = cleared >= #ids,
		milestones = milestones,
	}
end

return Progression
