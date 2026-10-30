--!strict
-- LeaderboardService: the global leaderboards (see Leaderboards for the list).
--
-- Each board is an OrderedDataStore keyed by user id. A player's scores are
-- written from their saved profile as they play and when they leave, and a
-- stored score is only ever replaced by a higher one, so an older server
-- can't lower it. Only profiles that loaded from the DataStore are written:
-- an offline profile starts from zero and would say nothing true.
--
-- Reading a board costs a DataStore request, so each server keeps the top
-- entries for self.deps.boards.REFRESH seconds and lays its own players' current
-- scores over them, which keeps them up to date on their own screen.
--
-- When the DataStores can't be reached (Studio without API access, an
-- outage), a board shows the players on this server instead and says so.
--
-- Roblox services and the shared Leaderboards module come in through `deps`,
-- so the tests can run it.

local LeaderboardService = {}
LeaderboardService.__index = LeaderboardService

LeaderboardService.RETRY_AFTER = 300 -- seconds to leave the stores alone after a failure
LeaderboardService.FETCH_WAIT = 10 -- seconds a request waits for a fetch already running

export type Entry = { userId: number, value: number, name: string? }

export type Deps = {
	boards: any, -- the shared Leaderboards module
	orderedStore: (name: string) -> any, -- may error
	userNames: (userIds: { number }) -> { [number]: string }, -- may error
	now: () -> number,
	wait: (seconds: number) -> (),
	log: ((message: string) -> ())?,
}

function LeaderboardService.new(deps: Deps)
	local self = setmetatable({}, LeaderboardService) :: any
	self.deps = deps
	self.stores = {} -- board id -> OrderedDataStore
	self.sent = {} -- user id -> { [board id]: score last written }
	self.names = {} -- user id -> display name
	self.cache = {} -- board id -> { at: number, entries: { Entry }?, global: boolean }
	self.fetching = {} -- board id -> true while a fetch runs
	self.unavailableUntil = -math.huge
	return self
end

function LeaderboardService._log(self: any, message: string)
	local log = self.deps.log
	if log then
		log("[Leaderboards] " .. message)
	end
end

function LeaderboardService._store(self: any, id: string): any
	local store = self.stores[id]
	if not store then
		store = self.deps.orderedStore(self.deps.boards.storeName(id))
		self.stores[id] = store
	end
	return store
end

function LeaderboardService.available(self: any): boolean
	return self.deps.now() >= self.unavailableUntil
end

function LeaderboardService._failed(self: any, what: string, err: any)
	if self:available() then
		self:_log(string.format("%s failed (%s); showing this server's players for a while", what, tostring(err)))
	end
	self.unavailableUntil = self.deps.now() + LeaderboardService.RETRY_AFTER
end

-- Writes the player's scores that went up since the last write. Yields.
-- Call it only with a profile that loaded from the DataStore.
function LeaderboardService.submit(self: any, userId: number, profile: any)
	if not self:available() then
		return
	end
	local sent = self.sent[userId] or {}
	self.sent[userId] = sent
	for _, board in ipairs(self.deps.boards.list) do
		local score = self.deps.boards.score(board, profile)
		if score > (sent[board.id] or 0) then
			local ok, err = pcall(function()
				self:_store(board.id):UpdateAsync(tostring(userId), function(stored: any): number?
					if type(stored) == "number" and stored >= score then
						return nil -- keep the higher score already there
					end
					return score
				end)
			end)
			if not ok then
				self:_failed("writing " .. board.id, err)
				return
			end
			sent[board.id] = score
		end
	end
end

function LeaderboardService.forget(self: any, userId: number)
	self.sent[userId] = nil
end

-- Remembers names the server already knows (its own players).
function LeaderboardService.setName(self: any, userId: number, name: string)
	self.names[userId] = name
end

function LeaderboardService._fillNames(self: any, entries: { Entry })
	local missing = {}
	for _, entry in ipairs(entries) do
		if not self.names[entry.userId] and entry.userId > 0 then
			table.insert(missing, entry.userId)
		end
	end
	if #missing > 0 then
		local ok, found = pcall(self.deps.userNames, missing)
		if ok and type(found) == "table" then
			for userId, name in pairs(found) do
				if type(userId) == "number" and type(name) == "string" then
					self.names[userId] = name
				end
			end
		end
	end
end

function LeaderboardService._fetchGlobal(self: any, id: string): { Entry }?
	if not self:available() then
		return nil
	end
	local ok, result = pcall(function()
		local pages = self:_store(id):GetSortedAsync(false, self.deps.boards.SIZE)
		return pages:GetCurrentPage()
	end)
	if not ok then
		self:_failed("reading " .. id, result)
		return nil
	end
	local entries = {}
	for _, item in ipairs(result) do
		local userId = tonumber(item.key)
		if userId and type(item.value) == "number" then
			table.insert(entries, { userId = userId, value = item.value })
		end
	end
	self:_fillNames(entries)
	return entries
end

-- The board as this server shows it: the cached global top entries with
-- `live` (this server's players and their current scores) laid over them,
-- or only `live` when the global board can't be read. Yields.
function LeaderboardService.view(self: any, id: string, live: { Entry }): { [string]: any }?
	if not self.deps.boards.get(id) then
		return nil
	end
	local now = self.deps.now()
	local cached = self.cache[id]
	if not cached or now - cached.at >= self.deps.boards.REFRESH then
		if self.fetching[id] then
			-- Someone else is already fetching it: wait for theirs.
			local deadline = now + LeaderboardService.FETCH_WAIT
			while self.fetching[id] and self.deps.now() < deadline do
				self.deps.wait(0.2)
			end
		else
			self.fetching[id] = true
			local entries = self:_fetchGlobal(id)
			self.cache[id] = { at = self.deps.now(), entries = entries }
			self.fetching[id] = nil
		end
		cached = self.cache[id]
	end
	local global = cached ~= nil and cached.entries ~= nil
	local merged = {}
	if global then
		for _, entry in ipairs(cached.entries) do
			table.insert(merged, { userId = entry.userId, value = entry.value })
		end
	end
	for _, entry in ipairs(live) do
		if entry.name then
			self.names[entry.userId] = entry.name
		end
		table.insert(merged, { userId = entry.userId, value = entry.value })
	end
	local ranked = self.deps.boards.rank(merged)
	for _, entry in ipairs(ranked) do
		entry.name = self.names[entry.userId]
	end
	return {
		board = id,
		scope = if global then "global" else "server",
		entries = ranked,
		age = if cached then math.max(0, math.floor(self.deps.now() - cached.at)) else 0,
	}
end

return LeaderboardService
