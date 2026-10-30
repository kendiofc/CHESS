--!strict
-- Leaderboards: which global boards exist, how a profile scores on each, and
-- how a score reads. Pure logic, shared by the server (which ranks players)
-- and the client (which only draws what the server sent).
--
-- Every board ranks a number that only ever goes up, so a stored score can
-- only be replaced by a higher one (see LeaderboardService).

local Leaderboards = {}

export type Board = {
	id: string,
	title: string, -- the page heading
	tab: string, -- the short tab label
	unit: string?, -- "boards", "days"... (nil: a bare number, or a duration)
	duration: boolean?, -- the score is seconds of play
	value: (profile: any) -> number,
}

Leaderboards.SIZE = 50 -- entries shown per board
Leaderboards.REFRESH = 120 -- seconds a server keeps a fetched board
Leaderboards.STORE_VERSION = 1

local function stat(profile: any, key: string): number
	return if type(profile.stats) == "table" then profile.stats[key] or 0 else 0
end

Leaderboards.list = {
	{
		id = "endless",
		title = "Best Endless Run",
		tab = "Endless",
		unit = "boards",
		value = function(profile: any): number
			return profile.endless and profile.endless.best or 0
		end,
	},
	{
		id = "playtime",
		title = "Play Time",
		tab = "Play Time",
		duration = true,
		value = function(profile: any): number
			return stat(profile, "playSeconds")
		end,
	},
	{
		id = "solves",
		title = "Puzzles Solved",
		tab = "Solved",
		unit = "puzzles",
		value = function(profile: any): number
			return stat(profile, "solves")
		end,
	},
	{
		id = "xp",
		title = "Total XP",
		tab = "XP",
		unit = "XP",
		value = function(profile: any): number
			return profile.xp or 0
		end,
	},
	{
		id = "streak",
		title = "Longest Daily Streak",
		tab = "Streak",
		unit = "days",
		value = function(profile: any): number
			return profile.streak and profile.streak.longest or 0
		end,
	},
	{
		id = "duels",
		title = "Duel Wins",
		tab = "Duels",
		unit = "wins",
		value = function(profile: any): number
			return profile.duel and profile.duel.wins or 0
		end,
	},
} :: { Board }

Leaderboards.byId = {} :: { [string]: Board }
for _, board in ipairs(Leaderboards.list) do
	Leaderboards.byId[board.id] = board
end

function Leaderboards.get(id: any): Board?
	return if type(id) == "string" then Leaderboards.byId[id] else nil
end

-- The OrderedDataStore a board is kept in.
function Leaderboards.storeName(id: string): string
	return string.format("EchoChessLB_%s_v%d", id, Leaderboards.STORE_VERSION)
end

-- A profile's score on a board: a whole number, never negative.
function Leaderboards.score(board: Board, profile: any): number
	local value = board.value(profile)
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, 2 ^ 52)
end

-- "3h 05m", "12m", "45s".
function Leaderboards.durationText(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local hours, minutes = seconds // 3600, (seconds % 3600) // 60
	if hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	elseif minutes > 0 then
		return string.format("%dm", minutes)
	end
	return string.format("%ds", seconds)
end

-- "1,234,567".
local function grouped(value: number): string
	local digits = tostring(math.floor(value))
	local out = digits
	repeat
		local changed
		out, changed = string.gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
	until changed == 0
	return out
end

-- How a score reads on its board, e.g. "12 boards" or "3h 05m".
function Leaderboards.format(board: Board, value: number): string
	if board.duration then
		return Leaderboards.durationText(value)
	end
	return if board.unit then grouped(value) .. " " .. board.unit else grouped(value)
end

-- Ranks entries ({ userId, value, name? }) high to low; ties go to the lower
-- user id so the order is stable. Zero scores aren't ranked. Returns at most
-- `limit` entries, each with its `rank`.
function Leaderboards.rank(entries: { any }, limit: number?): { any }
	local best: { [number]: any } = {}
	for _, entry in ipairs(entries) do
		if type(entry.userId) == "number" and type(entry.value) == "number" and entry.value > 0 then
			local seen = best[entry.userId]
			if not seen or entry.value > seen.value then
				best[entry.userId] = { userId = entry.userId, value = entry.value, name = entry.name or (seen and seen.name) }
			elseif entry.name and not seen.name then
				seen.name = entry.name
			end
		end
	end
	local ranked: { any } = {}
	for _, entry in pairs(best) do
		table.insert(ranked, entry)
	end
	table.sort(ranked, function(a, b)
		if a.value ~= b.value then
			return a.value > b.value
		end
		return a.userId < b.userId
	end)
	local size = limit or Leaderboards.SIZE
	for index = #ranked, size + 1, -1 do
		ranked[index] = nil
	end
	for index, entry in ipairs(ranked) do
		entry.rank = index
	end
	return ranked
end

return Leaderboards
