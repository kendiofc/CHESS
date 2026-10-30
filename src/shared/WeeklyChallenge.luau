--!strict
-- WeeklyChallenge: which puzzles make up each week's challenge. Pure logic,
-- shared by the server (which decides) and the client (which displays).
--
-- Weeks run Monday 00:00 UTC to the next Monday 00:00 UTC and are numbered
-- from the week of 1970-01-01 (a Thursday), so every server agrees on the week
-- from its own clock. Each week is a fixed sequence of catalogue puzzles,
-- easiest first: one Easy, two Medium, one Hard. The catalogue is validated by
-- PuzzleCheck, and tests/run.luau also runs the solver over many weeks' sets.
--
-- Rewards (paid by Progression under profile.rewards keys, so once ever):
--   weekly:<week>:<n>  for each milestone in MILESTONES (n = puzzles cleared)

local PuzzleDefinitions = require(script.Parent.PuzzleDefinitions)

local WeeklyChallenge = {}

WeeklyChallenge.SIZE = 4

-- Rewards for clearing n of the week's puzzles. The last one is completion.
WeeklyChallenge.MILESTONES = {
	{ cleared = 2, xp = 30, coins = 10, reason = "weekly halfway" },
	{ cleared = 4, xp = 100, coins = 30, reason = "weekly challenge" },
}

-- UTC week number for a UTC day number (days since 1970-01-01).
function WeeklyChallenge.weekOfDay(day: number): number
	return (day + 3) // 7
end

function WeeklyChallenge.weekOf(unixTime: number): number
	return WeeklyChallenge.weekOfDay(unixTime // 86400)
end

-- First UTC day (a Monday) of a week.
function WeeklyChallenge.firstDay(week: number): number
	return week * 7 - 3
end

-- Seconds from `unixTime` until the next week starts.
function WeeklyChallenge.secondsLeft(unixTime: number): number
	return WeeklyChallenge.firstDay(WeeklyChallenge.weekOf(unixTime) + 1) * 86400 - unixTime
end

-- The week's puzzles in play order. Each difficulty has 6 puzzles; the two
-- Medium picks are 3 apart so they always differ, and a puzzle comes back in
-- the same slot every 6 weeks.
function WeeklyChallenge.puzzles(week: number): { PuzzleDefinitions.Puzzle }
	local by = PuzzleDefinitions.byDifficulty
	local function pick(difficulty: string, offset: number): PuzzleDefinitions.Puzzle
		local group = by[difficulty]
		return group[(week + offset) % #group + 1]
	end
	return {
		pick("Easy", 0),
		pick("Medium", 1),
		pick("Medium", 4),
		pick("Hard", 2),
	}
end

function WeeklyChallenge.contains(week: number, puzzleId: any): boolean
	for _, puzzle in ipairs(WeeklyChallenge.puzzles(week)) do
		if puzzle.id == puzzleId then
			return true
		end
	end
	return false
end

function WeeklyChallenge.rewardKey(week: number, cleared: number): string
	return string.format("weekly:%d:%d", week, cleared)
end

return WeeklyChallenge
