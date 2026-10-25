--!strict
-- ProfileStore: loads and saves player profiles in a DataStore.
--
-- It takes its DataStore, clock and scheduler as arguments instead of reaching
-- for Roblox services, so tests/run.luau can drive it with a fake store that
-- fails, throttles and races on purpose.
--
-- How a profile moves:
--   load     GetAsync with retries. If every attempt fails the player still
--            plays on a blank profile marked "offline". Nothing is lost: saves
--            merge into the stored data (below), and the first save that gets
--            through replaces the blank view with the real merged profile.
--   record   an op (Progression) is applied to the in-memory profile at once,
--            so rewards show immediately, and queued for the next save.
--   save     UpdateAsync applies the queued ops to whatever is stored right
--            then. Op ids make a retried or doubled save harmless, and reward
--            keys stop a reward being paid twice even across two servers.
--            Ops recorded while a save is in flight wait for the next one.
--   pacing   at most one write per key every MIN_SAVE_INTERVAL seconds (the
--            DataStore limit is one per 6 s), waits for request budget before
--            calling, and backs off exponentially between failed attempts.
--   leaving  a final save with extra retries; BindToClose saves everyone.
-- Ops that still cannot be saved stay queued (and are counted) rather than
-- being dropped, and a failed save never overwrites stored data.

local ProfileStore = {}
ProfileStore.__index = ProfileStore

ProfileStore.KEY_PREFIX = "player_"
ProfileStore.MIN_SAVE_INTERVAL = 7
ProfileStore.AUTOSAVE_INTERVAL = 60
ProfileStore.LOAD_ATTEMPTS = 4
ProfileStore.SAVE_ATTEMPTS = 3
ProfileStore.FINAL_SAVE_ATTEMPTS = 5
ProfileStore.BACKOFF = 1 -- seconds before the first retry; doubles each time
ProfileStore.BUDGET_WAIT = 10 -- longest wait for request budget per attempt

export type Status = "loading" | "ok" | "offline"

type Record = {
	key: string,
	profile: any,
	pending: { any },
	status: Status,
	saving: boolean,
	saveAgain: boolean,
	lastWrite: number, -- clock time of the last write attempt
	released: boolean,
}

-- Errors that retrying cannot fix: the place has no DataStore access (Studio
-- with API access off, or an unpublished place). After one of these the store
-- stops calling the DataStore for the rest of the server's life.
local PERMANENT_ERRORS = { "StudioAccessToApisNotAllowed", "Studio access to APIs is not allowed", "must publish" }

local function isPermanent(err: any): boolean
	local message = tostring(err)
	for _, fragment in ipairs(PERMANENT_ERRORS) do
		if string.find(message, fragment, 1, true) then
			return true
		end
	end
	return false
end

export type Deps = {
	store: any, -- GetAsync(key) and UpdateAsync(key, transform), like a DataStore
	progression: any, -- the Progression module
	now: () -> number,
	wait: (number) -> (),
	newId: () -> string,
	budget: ((string) -> number)?, -- request budget for "GetAsync" / "UpdateAsync"
	log: ((string) -> ())?,
}

function ProfileStore.new(deps: Deps)
	local self = setmetatable({
		deps = deps,
		records = {} :: { [number]: Record },
		failedSaves = 0,
		disabled = false, -- set after a permanent DataStore error
	}, ProfileStore)
	return self
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = deepCopy(v)
	end
	return copy
end

function ProfileStore._log(self: any, message: string)
	if self.deps.log then
		self.deps.log("[ProfileStore] " .. message)
	end
end

-- Waits (bounded) until the DataStore has budget for this request type.
function ProfileStore._waitForBudget(self: any, requestType: string)
	local budget = self.deps.budget
	if not budget then
		return
	end
	local waited = 0
	while budget(requestType) < 1 and waited < ProfileStore.BUDGET_WAIT do
		self.deps.wait(1)
		waited += 1
	end
end

-- Calls fn up to `attempts` times with exponential backoff. Returns ok, result.
function ProfileStore._retry(self: any, requestType: string, attempts: number, fn: () -> any): (boolean, any)
	local delay = ProfileStore.BACKOFF
	local lastError = nil
	for attempt = 1, attempts do
		if self.disabled then
			return false, "DataStore access is disabled for this server"
		end
		self:_waitForBudget(requestType)
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastError = result
		self:_log(string.format("%s failed (attempt %d/%d): %s", requestType, attempt, attempts, tostring(result)))
		if isPermanent(result) then
			self.disabled = true
			self:_log("DataStores are not available here; progress will not be saved on this server")
			return false, result
		end
		if attempt < attempts then
			self.deps.wait(delay)
			delay *= 2
		end
	end
	return false, lastError
end

-- Loads a player's profile. Yields. Always returns a usable profile.
function ProfileStore.load(self: any, userId: number): any
	local progression = self.deps.progression
	local record: Record = {
		key = ProfileStore.KEY_PREFIX .. userId,
		profile = progression.newProfile(),
		pending = {},
		status = "loading",
		saving = false,
		saveAgain = false,
		lastWrite = -math.huge,
		released = false,
	}
	self.records[userId] = record
	local ok, data = self:_retry("GetAsync", ProfileStore.LOAD_ATTEMPTS, function()
		return self.deps.store:GetAsync(record.key)
	end)
	if record.released then
		return record.profile
	end
	if ok then
		local profile = progression.normalize(data)
		-- Ops recorded while the load was running still count.
		for _, op in ipairs(record.pending) do
			progression.apply(profile, op)
		end
		record.profile = profile
		record.status = "ok"
	else
		record.status = "offline"
		self:_log("could not load " .. record.key .. "; playing offline until a save gets through")
	end
	return record.profile
end

function ProfileStore.get(self: any, userId: number): any
	local record = self.records[userId]
	return record and record.profile
end

function ProfileStore.status(self: any, userId: number): Status?
	local record = self.records[userId]
	return record and record.status
end

function ProfileStore.pendingCount(self: any, userId: number): number
	local record = self.records[userId]
	return if record then #record.pending else 0
end

-- Applies an op now and queues it for saving. Returns the reward it paid.
function ProfileStore.record(self: any, userId: number, op: any): any
	local record = self.records[userId]
	if not record then
		return nil
	end
	op.id = op.id or self.deps.newId()
	local _, reward = self.deps.progression.apply(record.profile, op)
	table.insert(record.pending, op)
	return reward
end

-- Saves queued ops. Yields. `final` uses more retries and ignores pacing.
-- Returns true when everything queued at the start was written.
function ProfileStore.save(self: any, userId: number, final: boolean?): boolean
	local record = self.records[userId]
	if not record then
		return true
	end
	if record.saving then
		record.saveAgain = true
		return false
	end
	if #record.pending == 0 and record.status ~= "offline" then
		return true
	end
	record.saving = true
	local progression = self.deps.progression
	local saved = false
	repeat
		record.saveAgain = false
		if not final then
			local ready = record.lastWrite + ProfileStore.MIN_SAVE_INTERVAL
			local now = self.deps.now()
			if now < ready then
				self.deps.wait(ready - now)
			end
		end
		local batch = table.clone(record.pending)
		local attempts = if final then ProfileStore.FINAL_SAVE_ATTEMPTS else ProfileStore.SAVE_ATTEMPTS
		local ok, result = self:_retry("UpdateAsync", attempts, function()
			record.lastWrite = self.deps.now()
			return self.deps.store:UpdateAsync(record.key, function(stored: any)
				local merged = progression.normalize(stored)
				for _, op in ipairs(batch) do
					progression.apply(merged, op)
				end
				return merged
			end)
		end)
		if ok then
			-- Drop the ops that were written; keep any recorded meanwhile.
			local written = {}
			for _, op in ipairs(batch) do
				written[op.id] = true
			end
			local remaining = {}
			for _, op in ipairs(record.pending) do
				if not written[op.id] then
					table.insert(remaining, op)
				end
			end
			local view = progression.normalize(deepCopy(result))
			for _, op in ipairs(remaining) do
				progression.apply(view, op)
			end
			record.pending = remaining
			record.profile = view
			record.status = "ok"
			saved = #remaining == 0
		else
			self.failedSaves += 1
			self:_log(string.format("save of %s failed; %d ops stay queued", record.key, #record.pending))
			break
		end
	until not record.saveAgain or final
	record.saving = false
	return saved
end

-- Final save when the player leaves, then forget them.
function ProfileStore.release(self: any, userId: number): boolean
	local record = self.records[userId]
	if not record then
		return true
	end
	record.released = true
	while record.saving do
		self.deps.wait(0.1)
	end
	local ok = self:save(userId, true)
	if not ok and #record.pending > 0 then
		self:_log(string.format("%d ops for %s could not be saved", #record.pending, record.key))
	end
	self.records[userId] = nil
	return ok
end

function ProfileStore.userIds(self: any): { number }
	local ids = {}
	for userId in pairs(self.records) do
		table.insert(ids, userId)
	end
	return ids
end

return ProfileStore
