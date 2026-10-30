--!strict
-- FakeStore: an in-memory stand-in for a Roblox DataStore, for ProfileStore
-- tests. It can fail on purpose:
--   failGets / failUpdates   the next N calls raise an error
--   commitThenFail           the next N UpdateAsync calls write, then raise
--                            (the "did my save go through?" case)
--   beforeUpdate             runs just before a write, to simulate another
--                            server writing the same key first
-- Values are deep-copied in and out, as a real DataStore serialises them.

local FakeStore = {}
FakeStore.__index = FakeStore

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = copy(v)
	end
	return out
end

function FakeStore.new()
	return setmetatable({
		data = {} :: { [string]: any },
		failGets = 0,
		failUpdates = 0,
		commitThenFail = 0,
		beforeUpdate = nil :: ((string) -> ())?,
		gets = 0,
		writes = 0,
	}, FakeStore)
end

function FakeStore.GetAsync(self: any, key: string): any
	self.gets += 1
	if self.failGets > 0 then
		self.failGets -= 1
		error("502: API Services rejected request (fake)")
	end
	return copy(self.data[key])
end

function FakeStore.UpdateAsync(self: any, key: string, transform: (any) -> any): any
	if self.failUpdates > 0 then
		self.failUpdates -= 1
		error("503: DataStore request dropped (fake)")
	end
	if self.beforeUpdate then
		local hook = self.beforeUpdate
		self.beforeUpdate = nil
		hook(key)
	end
	local result = transform(copy(self.data[key]))
	self.data[key] = copy(result)
	self.writes += 1
	if self.commitThenFail > 0 then
		self.commitThenFail -= 1
		error("timeout after write (fake)")
	end
	return copy(result)
end

return FakeStore
