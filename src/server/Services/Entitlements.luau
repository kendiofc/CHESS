--!strict
-- Entitlements: which gamepasses each player on this server owns.
--
-- Only the server decides, by asking Roblox (MarketplaceService
-- UserOwnsGamePassAsync, passed in as `owns`). A client can prompt a purchase,
-- but nothing it says about prices, ownership or a finished purchase is ever
-- used: after PromptGamePassPurchaseFinished the server asks Roblox again and
-- grants the pass only if Roblox confirms it.
--
-- Unconfigured passes (no id in GamePassConfig) are never checked or granted.
-- A failed check never grants anything and never takes away a pass already
-- confirmed this session; the player keeps the free game either way.
--
-- Pure, like DuelManager: Roblox calls, waiting and the config are passed in,
-- so tests/run.luau can drive it.

local Entitlements = {}
Entitlements.__index = Entitlements

export type Deps = {
	owns: (userId: number, passId: number) -> boolean, -- may yield and throw
	wait: (seconds: number) -> (),
	config: any, -- GamePassConfig
	log: (message: string) -> (),
	-- Seconds to wait between checks after a purchase: Roblox can take a moment
	-- to report a pass bought seconds ago.
	purchaseRetries: { number }?,
}

function Entitlements.new(deps: Deps)
	return setmetatable({
		deps = deps,
		owned = {} :: { [number]: { [string]: boolean } }, -- players on this server
		checking = {} :: { [number]: boolean },
	}, Entitlements)
end

-- The verified passes of a player, as { [key] = true }. A copy.
function Entitlements.passes(self: any, userId: number): { [string]: boolean }
	return table.clone(self.owned[userId] or {})
end

function Entitlements.has(self: any, userId: number, key: string): boolean
	local owned = self.owned[userId]
	return owned ~= nil and owned[key] == true
end

-- Asks Roblox about one pass. Returns true, false, or nil when the check failed.
function Entitlements._check(self: any, userId: number, key: string): boolean?
	local config = self.deps.config
	if not config.isConfigured(key) then
		return nil
	end
	local ok, result = pcall(self.deps.owns, userId, config.PASSES[key].id)
	if not ok then
		self.deps.log(string.format("ownership check for %s failed: %s", key, tostring(result)))
		return nil
	end
	return result == true
end

-- Grants only to players still on this server (a check can finish after they leave).
function Entitlements._grant(self: any, userId: number, key: string): boolean
	local owned = self.owned[userId]
	if not owned then
		return false
	end
	owned[key] = true
	return true
end

-- A player joined: start tracking them (with no passes until checked).
function Entitlements.join(self: any, userId: number)
	self.owned[userId] = self.owned[userId] or {}
end

-- Checks every configured pass (on join). Yields. Returns true if anything
-- new was granted.
function Entitlements.refresh(self: any, userId: number): boolean
	local changed = false
	for _, key in ipairs(self.deps.config.ORDER) do
		if not self:has(userId, key) and self:_check(userId, key) == true and self:_grant(userId, key) then
			changed = true
		end
	end
	return changed
end

-- PromptGamePassPurchaseFinished on the server. `purchased` is Roblox's own
-- flag; a cancelled prompt grants nothing. A completed one is confirmed with
-- Roblox (retrying a few times) before anything is granted. Returns the pass
-- key when it was granted now.
function Entitlements.purchaseFinished(self: any, userId: number, passId: any, purchased: boolean): string?
	local key = self.deps.config.keyForId(passId)
	if not key or not purchased then
		return nil
	end
	if self:has(userId, key) then
		return nil
	end
	if self.checking[userId] then
		return nil -- one confirmation at a time per player
	end
	self.checking[userId] = true
	local delays = self.deps.purchaseRetries or { 0, 2, 4, 8 }
	local granted = nil
	for _, delay in ipairs(delays) do
		if delay > 0 then
			self.deps.wait(delay)
		end
		if self.owned[userId] == nil then
			break -- they left meanwhile
		end
		if self:_check(userId, key) == true then
			granted = if self:_grant(userId, key) then key else nil
			break
		end
	end
	self.checking[userId] = nil
	if not granted and self.owned[userId] then
		self.deps.log(string.format("purchase of %s by %d was not confirmed by Roblox; nothing granted", key, userId))
	end
	return granted
end

-- Studio only (the caller makes sure): pretend a player owns a pass, to test
-- how owned items look without spending Robux.
function Entitlements.override(self: any, userId: number, key: string, owned: boolean)
	if owned then
		self:join(userId)
		self:_grant(userId, key)
	elseif self.owned[userId] then
		self.owned[userId][key] = nil
	end
end

function Entitlements.forget(self: any, userId: number)
	self.owned[userId] = nil
end

return Entitlements
