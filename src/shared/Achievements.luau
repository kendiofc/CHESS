--!strict
-- Achievements: one-time goals that pay coins. Pure data plus checks over a
-- profile, shared by the server (which pays them) and the client (which lists
-- them).
--
-- Progression checks every achievement after each Journey or Daily win and
-- pays the ones newly met under the reward key "ach:<id>", so each pays at
-- most once, even when the same win reaches the DataStore twice or from two
-- servers. Practice wins never pay; an achievement met through Practice-only
-- progress is impossible anyway, because only Journey and Daily clears are
-- credited and only they save stars.

local GameConfig = require(script.Parent.GameConfig)
local PuzzleDefinitions = require(script.Parent.PuzzleDefinitions)

local Achievements = {}

export type Achievement = {
	id: string,
	name: string,
	description: string,
	coins: number,
	check: (profile: any) -> boolean,
}

local function creditedIn(profile: any, difficulty: string): number
	local count = 0
	for _, puzzle in ipairs(PuzzleDefinitions.byDifficulty[difficulty]) do
		local record = profile.completed[puzzle.id]
		if record and record.credited then
			count += 1
		end
	end
	return count
end

local function starTotals(profile: any): (number, number)
	local stars, perfect = 0, 0
	for _, record in pairs(profile.completed) do
		stars += record.stars or 0
		if record.stars == 3 then
			perfect += 1
		end
	end
	return stars, perfect
end

local list: { Achievement } = {}

for index, difficulty in ipairs(GameConfig.DIFFICULTIES) do
	local coins = ({ 20, 30, 45, 70, 100 })[index]
	table.insert(list, {
		id = string.lower(difficulty) .. "_clear",
		name = difficulty .. " Complete",
		description = string.format("Clear all %s puzzles in Journey.", difficulty),
		coins = coins,
		check = function(profile)
			return creditedIn(profile, difficulty) >= #PuzzleDefinitions.byDifficulty[difficulty]
		end,
	})
end

local function starGoal(id: string, name: string, stars: number, coins: number)
	table.insert(list, {
		id = id,
		name = name,
		description = string.format("Earn %d stars.", stars),
		coins = coins,
		check = function(profile)
			return (starTotals(profile)) >= stars
		end,
	})
end
starGoal("stars_30", "Rising Echo", 30, 25)
starGoal("stars_60", "Bright Echo", 60, 50)
starGoal("stars_90", "Perfect Echo", 3 * #PuzzleDefinitions.list, 120)

table.insert(list, {
	id = "par_10",
	name = "Par Breaker",
	description = "Get 3 stars on 10 puzzles.",
	coins = 40,
	check = function(profile)
		return select(2, starTotals(profile)) >= 10
	end,
})

local function streakGoal(id: string, name: string, days: number, coins: number)
	table.insert(list, {
		id = id,
		name = name,
		description = string.format("Reach a %d-day Daily streak.", days),
		coins = coins,
		check = function(profile)
			return profile.streak.longest >= days
		end,
	})
end
streakGoal("streak_3", "Three in a Row", 3, 20)
streakGoal("streak_7", "Week of Echoes", 7, 50)

table.insert(list, {
	id = "dailies_10",
	name = "Daily Regular",
	description = "Clear 10 Daily Puzzles.",
	coins = 40,
	check = function(profile)
		return profile.stats.dailies >= 10
	end,
})

Achievements.list = list
Achievements.byId = {} :: { [string]: Achievement }
for _, achievement in ipairs(list) do
	Achievements.byId[achievement.id] = achievement
end

function Achievements.rewardKey(id: string): string
	return "ach:" .. id
end

Achievements.starTotals = starTotals

return Achievements
