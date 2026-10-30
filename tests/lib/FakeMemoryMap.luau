--!strict
-- FakeMemoryMap: an in-memory stand-in for a MemoryStore sorted map, shaped
-- like DuelMatchmaker's Map. Several fake servers share one map, as real
-- servers share one MemoryStore. Entries expire on the given clock, values
-- are deep-copied in and out, and calls can be made to fail:
--   failNext   the next N calls raise an error
--   beforeUpdate(key)   runs just before an update reads, to let "another
--                       server" write the same key first

local FakeMemoryMap = {}
FakeMemoryMap.__index = FakeMemoryMap

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

function FakeMemoryMap.new(clock: () -> number)
	return setmetatable({
		clock = clock,
		entries = {} :: { [string]: { value: any, expires: number, sortKey: number? } },
		failNext = 0,
		beforeUpdate = nil :: ((string) -> ())?,
		calls = 0,
	}, FakeMemoryMap)
end

function FakeMemoryMap._call(self: any)
	self.calls += 1
	if self.failNext > 0 then
		self.failNext -= 1
		error("MemoryStore unavailable (fake)")
	end
end

function FakeMemoryMap._live(self: any, key: string): any
	local entry = self.entries[key]
	if entry and entry.expires <= self.clock() then
		self.entries[key] = nil
		return nil
	end
	return entry
end

function FakeMemoryMap.get(self: any, key: string): any
	self:_call()
	local entry = self:_live(key)
	return entry and copy(entry.value)
end

function FakeMemoryMap.set(self: any, key: string, value: any, ttl: number, sortKey: number?)
	self:_call()
	self.entries[key] = { value = copy(value), expires = self.clock() + ttl, sortKey = sortKey }
end

function FakeMemoryMap.update(self: any, key: string, fn: (any) -> any, ttl: number): any
	self:_call()
	local hook = self.beforeUpdate
	if hook then
		hook(key)
	end
	local entry = self:_live(key)
	local new = fn(entry and copy(entry.value))
	if new == nil then
		return nil
	end
	self.entries[key] = { value = copy(new), expires = self.clock() + ttl, sortKey = entry and entry.sortKey }
	return copy(new)
end

function FakeMemoryMap.remove(self: any, key: string)
	self:_call()
	self.entries[key] = nil
end

function FakeMemoryMap.range(self: any, count: number): { { key: string, value: any } }
	self:_call()
	local list: { { key: string, value: any, sortKey: number } } = {}
	for key in pairs(self.entries) do
		local entry = self:_live(key)
		if entry then
			table.insert(list, { key = key, value = copy(entry.value), sortKey = entry.sortKey or 0 })
		end
	end
	table.sort(list, function(a, b)
		if a.sortKey ~= b.sortKey then
			return a.sortKey < b.sortKey
		end
		return a.key < b.key
	end)
	local out = {}
	for i = 1, math.min(count, #list) do
		table.insert(out, { key = list[i].key, value = list[i].value })
	end
	return out
end

return FakeMemoryMap
