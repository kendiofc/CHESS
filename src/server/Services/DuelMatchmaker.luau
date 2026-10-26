--!strict
-- DuelMatchmaker: finds Puzzle Duel opponents on other servers.
--
-- DuelManager matches players on the same server straight away. Anyone left
-- waiting gets a ticket in a shared MemoryStore sorted map, keyed by user id
-- and sorted by when they joined. Every server runs step() every few seconds
-- for its own waiting players:
--
--   1. Refresh the ticket (tickets expire, so a crashed server's players drop
--      out on their own; a ticket not refreshed lately isn't offered).
--   2. If another server has set up a match on the ticket, teleport the player
--      to it.
--   3. Otherwise look for an older, live, unclaimed ticket from another server.
--      Only the newer of two players makes the claim, so two servers never
--      claim each other at once. Both tickets are claimed with UpdateAsync,
--      which only one server can win; a lost claim is released and retried.
--   4. Reserve a server, store the match record (match id, puzzle id, players)
--      under its private server id, write the match on both tickets, and
--      teleport our player.
--
-- The reserved server reads that record by its own PrivateServerId, never
-- from a client or teleport data, and hands it to DuelManager:expect(). The
-- match is then played and recorded exactly like a same-server one.
--
-- Takes its stores, clock and Roblox calls as arguments, like DuelManager, so
-- tests/run.luau can drive it with in-memory maps. Store calls yield and can
-- throw; a failure leaves the player waiting on their own server.

local DuelMatchmaker = {}
DuelMatchmaker.__index = DuelMatchmaker

-- A MemoryStore sorted map, or an in-memory fake. Values are tables.
export type Map = {
	get: (self: any, key: string) -> any,
	set: (self: any, key: string, value: any, ttl: number, sortKey: number?) -> (),
	-- fn gets the current value (nil if none) and returns the new one, or nil
	-- to leave it as it is. Returns the stored value, or nil if nothing changed.
	update: (self: any, key: string, fn: (any) -> any, ttl: number) -> any,
	remove: (self: any, key: string) -> (),
	range: (self: any, count: number) -> { { key: string, value: any } }, -- ascending sort key
}

export type Config = {
	TICKET_TTL: number, -- seconds a ticket lives without a refresh
	STALE: number, -- a ticket not refreshed for this long isn't offered
	MATCH_TTL: number, -- seconds the match record lives
	RANGE: number, -- tickets read per search
}

export type Deps = {
	tickets: Map,
	matches: Map,
	now: () -> number, -- wall clock seconds, the same on every server
	serverId: string,
	newId: () -> string,
	reserve: () -> (string, string), -- access code, private server id
	teleport: (userId: number, accessCode: string) -> boolean,
	pickPuzzleId: () -> string,
	duels: any, -- this server's DuelManager
	log: (message: string) -> (),
	config: Config,
}

type Link = { accessCode: string, matchId: string, server: string, opponent: string }

type Mine = {
	name: string,
	joinedAt: number,
	written: boolean,
	link: Link?, -- set once the player is on their way to a match
}

function DuelMatchmaker.new(deps: Deps)
	return setmetatable({
		deps = deps,
		mine = {} :: { [number]: Mine }, -- this server's tickets
	}, DuelMatchmaker)
end

local function keyOf(userId: number): string
	return tostring(userId)
end

-- a joined before b (ties go to the lower user id).
local function older(a: any, b: any): boolean
	if a.joinedAt ~= b.joinedAt then
		return a.joinedAt < b.joinedAt
	end
	return a.userId < b.userId
end

-- Offers a player who is waiting in DuelManager to other servers. The ticket
-- is written on the next step.
function DuelMatchmaker.publish(self: any, userId: number, name: string)
	if not self.mine[userId] then
		self.mine[userId] = { name = name, joinedAt = self.deps.now(), written = false, link = nil }
	end
end

function DuelMatchmaker.waitingCount(self: any): number
	local count = 0
	for _ in pairs(self.mine) do
		count += 1
	end
	return count
end

-- Tells the reserved server that this match won't happen.
function DuelMatchmaker._decline(self: any, link: Link)
	self.deps.matches:update(link.server, function(record: any): any
		if record then
			record.declined = true
			return record
		end
		return nil
	end, self.deps.config.MATCH_TTL)
end

-- The teleport to the match server failed after it started.
function DuelMatchmaker.teleportFailed(self: any, userId: number)
	local mine = self.mine[userId]
	if not (mine and mine.link) then
		return
	end
	self.mine[userId] = nil
	self.deps.duels:dropQueued(userId, "teleport_failed")
	local link = mine.link :: Link
	pcall(function()
		self:_decline(link)
		self.deps.tickets:remove(keyOf(userId))
	end)
end

function DuelMatchmaker._handoff(self: any, userId: number, mine: Mine, link: Link)
	if mine.link then
		return
	end
	local duels = self.deps.duels
	if not duels:markFound(userId, link.opponent) then
		-- They stopped waiting (cancelled, matched here, or left).
		self.mine[userId] = nil
		self:_decline(link)
		return
	end
	mine.link = link
	if not self.deps.teleport(userId, link.accessCode) then
		self:teleportFailed(userId)
	end
end

-- Withdraws the ticket of a player who stopped waiting. A match already set
-- up on it is declined so the other player isn't kept waiting.
function DuelMatchmaker._withdraw(self: any, userId: number, mine: Mine)
	self.mine[userId] = nil
	if mine.link then
		-- They left for the match server: the ticket just expires.
		return
	end
	if not mine.written then
		return
	end
	local tickets = self.deps.tickets
	local key = keyOf(userId)
	-- Mark it cancelled first so nobody claims it while it's removed.
	tickets:update(key, function(ticket: any): any
		if ticket and not ticket.claimedBy then
			ticket.cancelled = true
			return ticket
		end
		return nil
	end, self.deps.config.TICKET_TTL)
	local ticket = tickets:get(key)
	if ticket and ticket.match then
		self:_decline(ticket.match)
	end
	tickets:remove(key)
end

local function claim(tickets: Map, key: string, matchId: string, ttl: number): boolean
	local result = tickets:update(key, function(ticket: any): any
		if ticket and not ticket.claimedBy and not ticket.cancelled and not ticket.match then
			ticket.claimedBy = matchId
			return ticket
		end
		return nil
	end, ttl)
	return result ~= nil
end

local function release(tickets: Map, key: string, matchId: string, ttl: number)
	pcall(function()
		tickets:update(key, function(ticket: any): any
			if ticket and ticket.claimedBy == matchId and not ticket.match then
				ticket.claimedBy = nil
				return ticket
			end
			return nil
		end, ttl)
	end)
end

local function setMatch(tickets: Map, key: string, matchId: string, link: Link, ttl: number): boolean
	local result = tickets:update(key, function(ticket: any): any
		if ticket and ticket.claimedBy == matchId then
			ticket.match = link
			return ticket
		end
		return nil
	end, ttl)
	return result ~= nil
end

-- Looks for an opponent for our waiting player and sets up the match.
function DuelMatchmaker._pair(self: any, userId: number, mine: Mine, own: any)
	local deps = self.deps
	local config = deps.config
	local tickets = deps.tickets
	if own.claimedBy then
		return -- another server is claiming us
	end
	local now = deps.now()
	local target: any = nil
	for _, item in ipairs(tickets:range(config.RANGE)) do
		local ticket = item.value
		if
			type(ticket) == "table"
			and ticket.userId ~= userId
			and ticket.server ~= deps.serverId
			and not ticket.claimedBy
			and not ticket.cancelled
			and not ticket.match
			and now - (ticket.seenAt or 0) <= config.STALE
			and older(ticket, own)
		then
			target = ticket
			break
		end
	end
	if not target then
		return
	end
	if not deps.duels:lockQueued(userId) then
		return
	end
	local matchId = deps.newId()
	local ownKey, targetKey = keyOf(userId), keyOf(target.userId)
	local claimedOwn, claimedTarget = false, false
	local sent: Link? = nil -- the match written on their ticket
	local ok, err = pcall(function()
		claimedOwn = claim(tickets, ownKey, matchId, config.TICKET_TTL)
		if not claimedOwn then
			return
		end
		claimedTarget = claim(tickets, targetKey, matchId, config.TICKET_TTL)
		if not claimedTarget then
			return
		end
		local accessCode, serverKey = deps.reserve()
		deps.matches:set(serverKey, {
			matchId = matchId,
			puzzleId = deps.pickPuzzleId(),
			players = {
				{ id = target.userId, name = target.name },
				{ id = userId, name = mine.name },
			},
			createdAt = now,
		}, config.MATCH_TTL)
		local link = { accessCode = accessCode, matchId = matchId, server = serverKey, opponent = mine.name }
		if not setMatch(tickets, targetKey, matchId, link, config.TICKET_TTL) then
			-- Their ticket vanished (they left): nobody is coming.
			self:_decline(link)
			claimedTarget = false
			return
		end
		sent = link
		local ours = { accessCode = accessCode, matchId = matchId, server = serverKey, opponent = target.name }
		-- Our own ticket is ours to write; a failure here is a store error.
		setMatch(tickets, ownKey, matchId, ours, config.TICKET_TTL)
		self:_handoff(userId, mine, ours)
	end)
	if mine.link then
		return
	end
	if not ok then
		deps.log("duel matchmaking failed: " .. tostring(err))
	end
	if sent then
		-- They'll be told to come, but we won't: let the match server know.
		pcall(self._decline, self, sent)
	end
	if claimedOwn then
		release(tickets, ownKey, matchId, config.TICKET_TTL)
	end
	if claimedTarget then
		release(tickets, targetKey, matchId, config.TICKET_TTL)
	end
	deps.duels:unlockQueued(userId)
end

function DuelMatchmaker._stepOne(self: any, userId: number, mine: Mine)
	local deps = self.deps
	local config = deps.config
	if mine.link then
		return -- on their way to the match server
	end
	if not deps.duels:queuedName(userId) then
		self:_withdraw(userId, mine)
		return
	end
	local key = keyOf(userId)
	local now = deps.now()
	local own = nil
	if mine.written then
		own = deps.tickets:update(key, function(ticket: any): any
			if ticket then
				ticket.seenAt = now
				return ticket
			end
			return nil
		end, config.TICKET_TTL)
	end
	if not own then
		-- New, or expired while the store was unreachable.
		own = {
			userId = userId,
			name = mine.name,
			server = deps.serverId,
			joinedAt = mine.joinedAt,
			seenAt = now,
		}
		deps.tickets:set(key, own, config.TICKET_TTL, mine.joinedAt)
		mine.written = true
	end
	if own.match then
		self:_handoff(userId, mine, own.match)
		return
	end
	self:_pair(userId, mine, own)
end

-- One round for every player this server is offering. Call it every few seconds.
function DuelMatchmaker.step(self: any)
	local ids = {}
	for userId in pairs(self.mine) do
		table.insert(ids, userId)
	end
	for _, userId in ipairs(ids) do
		local mine = self.mine[userId]
		if mine then
			local ok, err = pcall(self._stepOne, self, userId, mine)
			if not ok then
				self.deps.log("duel ticket step failed: " .. tostring(err))
			end
		end
	end
end

-- Reserved server side --------------------------------------------------------------

-- The match record this reserved server was made for, or nil.
function DuelMatchmaker.hostedMatch(self: any, serverKey: string): any
	local record: any = self.deps.matches:get(serverKey)
	if type(record) ~= "table" or type(record.players) ~= "table" or #record.players ~= 2 then
		return nil
	end
	for _, player in ipairs(record.players) do
		if type(player) ~= "table" or type(player.id) ~= "number" or type(player.name) ~= "string" then
			return nil
		end
	end
	if record.players[1].id == record.players[2].id or type(record.matchId) ~= "string" then
		return nil
	end
	return record
end

-- Whether a player's server said they aren't coming.
function DuelMatchmaker.declined(self: any, serverKey: string): boolean
	local record = self.deps.matches:get(serverKey)
	return type(record) == "table" and record.declined == true
end

return DuelMatchmaker
