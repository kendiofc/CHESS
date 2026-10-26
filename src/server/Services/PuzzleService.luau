--!strict
-- PuzzleService: the authoritative puzzle state for every player.
--
-- Clients only send intents (start / move / undo / restart / hint). The
-- server owns a PuzzleSession per player, validates every move with the shared
-- rules, decides win/failure, times the attempt with its own clock, checks
-- unlocks and hint allowances, pays rewards, and sends back a full snapshot
-- after every action. Nothing the client says about legality, completion,
-- time, unlocks or rewards is trusted.
--
-- Progress is kept by ProfileStore (DataStore). A win is re-checked by
-- replaying the server's own move log before it is recorded.
--
-- Puzzle Duels (DuelManager) use the same remotes and rate limit. While a
-- player is in a duel, their move / undo / restart go to the duel board, and
-- single-player actions that would change what they see are refused.
-- Players left waiting are also offered to other servers (DuelMatchmaker);
-- a cross-server match is played on a reserved server both are teleported to.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoardState = require(Shared:WaitForChild("BoardState"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local PuzzleDefinitions = require(Shared:WaitForChild("PuzzleDefinitions"))
local PuzzleHints = require(Shared:WaitForChild("PuzzleHints"))
local PuzzleSession = require(Shared:WaitForChild("PuzzleSession"))
local PuzzleValidator = require(Shared:WaitForChild("PuzzleValidator"))
local RateLimiter = require(Shared:WaitForChild("RateLimiter"))
local WeeklyChallenge = require(Shared:WaitForChild("WeeklyChallenge"))
local DuelManager = require(script.Parent:WaitForChild("DuelManager"))
local DuelMatchmaker = require(script.Parent:WaitForChild("DuelMatchmaker"))
local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))

local ACTIONS = GameConfig.ACTIONS
local PLAY_MODES = GameConfig.PLAY_MODES
local DATASTORE_NAME = "EchoChessProfiles_v1"

type PlayerState = {
	session: PuzzleSession.PuzzleSession,
	mode: string,
	day: number, -- UTC day the attempt started (decides the Daily Puzzle)
	startedAt: number,
	finishedAt: number?,
	hintsUsed: number,
	hint: string?,
	hintSquare: number?,
	reward: any,
	result: any, -- the win summary for the result card (stars, best, unlock, streak)
	userStarted: boolean, -- the player picked a puzzle themselves
	limiter: RateLimiter.RateLimiter,
	throttled: boolean,
}

local PuzzleService = {}

local states: { [Player]: PlayerState } = {}
local profiles: any
local duels: any
local matchmaker: any -- nil when cross-server matching is off
local synced: { [number]: boolean } = {} -- players whose client has loaded
local stateRemote: RemoteEvent
local actionRemote: RemoteEvent

local function ensureRemote(folder: Instance, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	return remote
end

local function ensureRemotes()
	local folder = ReplicatedStorage:FindFirstChild(GameConfig.REMOTES.Folder)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = GameConfig.REMOTES.Folder
		folder.Parent = ReplicatedStorage
	end
	actionRemote = ensureRemote(folder :: Instance, GameConfig.REMOTES.Action)
	stateRemote = ensureRemote(folder :: Instance, GameConfig.REMOTES.State)
end

local function elapsed(state: PlayerState): number
	return (state.finishedAt or os.clock()) - state.startedAt
end

local function today(): number
	return Progression.dayNumber(os.time())
end

-- A DataStore that always fails, used when DataStores are unavailable (an
-- unpublished place, or Studio without API access). ProfileStore treats it
-- like an outage: the player plays offline and nothing is written.
local unavailableStore = {
	GetAsync = function()
		error("DataStores are not available in this place")
	end,
	UpdateAsync = function()
		error("DataStores are not available in this place")
	end,
}

local function createProfiles()
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if not ok then
		warn("[PuzzleService] DataStore unavailable, progress will not be saved: " .. tostring(store))
		store = unavailableStore
	end
	profiles = ProfileStore.new({
		store = store,
		progression = Progression,
		now = os.clock,
		wait = function(seconds: number)
			task.wait(seconds)
		end,
		newId = function()
			return HttpService:GenerateGUID(false)
		end,
		budget = if ok
			then function(requestType: string): number
				local enum = if requestType == "GetAsync"
					then Enum.DataStoreRequestType.GetAsync
					else Enum.DataStoreRequestType.UpdateAsync
				return DataStoreService:GetRequestBudgetForRequestType(enum)
			end
			else nil,
		log = warn,
	})
end

local function profileOf(player: Player): any
	return profiles:get(player.UserId) or Progression.newProfile()
end

local function record(player: Player, op: any): any
	local reward = profiles:record(player.UserId, op)
	return reward
end

local function requestSave(player: Player)
	task.spawn(function()
		profiles:save(player.UserId)
	end)
end

local function snapshot(player: Player, state: PlayerState, event: string, err: string?)
	local session = state.session
	local puzzle = session.puzzle
	local last = session:lastMove()
	local lastMove = nil
	if last and event == "move" then
		local landed = session.board.pieces[last.to]
		lastMove = {
			from = last.from,
			to = last.to,
			moverKind = last.moverKind,
			capturedKind = if last.captured then last.captured.kind else nil,
			newKind = if landed then landed.kind else last.moverKind,
		}
	end
	local index = table.find(PuzzleDefinitions.list, puzzle) or 1
	return {
		event = event,
		error = err,
		puzzleId = puzzle.id,
		puzzleIndex = index,
		puzzleCount = #PuzzleDefinitions.list,
		name = puzzle.name,
		difficulty = puzzle.difficulty,
		objective = puzzle.objective,
		par = puzzle.par,
		layout = BoardState.toLayout(session.board),
		status = session.status,
		moveCount = session.moveCount,
		targetsTotal = session.targetsTotal,
		targetsLeft = session:targetsLeft(),
		canUndo = session.status ~= "won" and #session.history > 0,
		elapsed = elapsed(state),
		lastMove = lastMove,
		mode = state.mode,
		number = puzzle.number,
		hint = if event == "hint" then state.hint else nil,
		hintSquare = if event == "hint" then state.hintSquare else nil,
		result = if event == "move" then state.result else nil,
		nextDailyIn = (today() + 1) * 86400 - os.time(),
		nextWeeklyIn = WeeklyChallenge.secondsLeft(os.time()),
		hintsUsed = state.hintsUsed,
		hintsLeft = (function()
			local left = Progression.hintsLeft(profileOf(player), state.mode, state.hintsUsed, state.day)
			return if left == math.huge then -1 else left
		end)(),
		reward = if event == "move" then state.reward else nil,
		progress = Progression.summary(profileOf(player), today()),
		saveStatus = profiles:status(player.UserId) or "loading",
		duelsAllServers = matchmaker ~= nil,
	}
end

local function send(player: Player, state: PlayerState, event: string, err: string?)
	stateRemote:FireClient(player, snapshot(player, state, event, err))
end

-- Duel snapshots carry the same progress and save status as puzzle ones.
local function sendDuel(player: Player, snap: { [string]: any })
	snap.progress = Progression.summary(profileOf(player), today())
	snap.saveStatus = profiles:status(player.UserId) or "loading"
	snap.nextDailyIn = (today() + 1) * 86400 - os.time()
	snap.nextWeeklyIn = WeeklyChallenge.secondsLeft(os.time())
	snap.duelsAllServers = matchmaker ~= nil
	stateRemote:FireClient(player, snap)
end

-- Answers on the screen the player is looking at: the duel screen while they
-- are queued, in a match or on a duel result, otherwise their puzzle.
local function reply(player: Player, state: PlayerState, event: string, err: string?)
	if duels:hasScreen(player.UserId) then
		sendDuel(player, duels:snapshot(player.UserId, event, err))
	else
		send(player, state, event, err)
	end
end

local function startPuzzle(player: Player, puzzle: PuzzleDefinitions.Puzzle, mode: string, day: number, byPlayer: boolean?)
	local now = os.clock()
	local previous = states[player]
	local state: PlayerState = {
		session = PuzzleSession.new(puzzle),
		mode = mode,
		day = day,
		startedAt = now,
		finishedAt = nil,
		hintsUsed = 0,
		hint = nil,
		hintSquare = nil,
		reward = nil,
		result = nil,
		userStarted = byPlayer == true or (previous ~= nil and previous.userStarted),
		limiter = if previous
			then previous.limiter
			else RateLimiter.new(GameConfig.RATE_LIMIT.BURST, GameConfig.RATE_LIMIT.PER_SECOND, now),
		throttled = false,
	}
	states[player] = state
	send(player, state, "start")
end

local function onAction(player: Player, action: unknown, payload: unknown)
	local state = states[player]
	if not state then
		return
	end
	if not state.limiter:take(os.clock()) then
		-- Tell the client once per throttled burst; don't answer every spammed call.
		if not state.throttled then
			state.throttled = true
			reply(player, state, "rejected", "rate_limited")
		end
		return
	end
	state.throttled = false
	if type(action) ~= "string" then
		return
	end
	local data = if type(payload) == "table" then payload :: { [any]: any } else {}
	local userId = player.UserId

	-- Puzzle Duel ----------------------------------------------------------
	if action == ACTIONS.DuelJoin then
		local ok, err = duels:join(userId, player.DisplayName)
		if not ok then
			reply(player, state, "rejected", err)
		elseif matchmaker and duels:stateOf(userId) == "queued" then
			-- Nobody here was waiting: look on other servers too.
			matchmaker:publish(userId, player.DisplayName)
		end
		return
	elseif action == ACTIONS.DuelCancel then
		local ok, err = duels:cancel(userId)
		if not ok then
			reply(player, state, "rejected", err)
		end
		return
	elseif action == ACTIONS.DuelLeave then
		local ok, err = duels:leave(userId)
		if not ok then
			reply(player, state, "rejected", err)
		end
		return
	elseif action == ACTIONS.DuelExit then
		if duels:exit(userId) then
			send(player, state, "sync")
		else
			reply(player, state, "rejected", "in_duel")
		end
		return
	end
	if action == ACTIONS.Sync then
		-- The client has loaded: on a cross-server match server, that's arrival.
		synced[userId] = true
		duels:arrive(userId)
	end
	local duelState = duels:stateOf(userId)
	if duelState == "countdown" or duelState == "playing" then
		if action == ACTIONS.Move or action == ACTIONS.Undo or action == ACTIONS.Restart then
			duels:act(userId, action, data)
			return
		end
	end
	if action == ACTIONS.Start then
		-- Starting a puzzle closes a duel result screen, but never leaves the
		-- queue or a match by accident.
		if not duels:exit(userId) then
			reply(player, state, "rejected", "in_duel")
			return
		end
	elseif duels:hasScreen(userId) then
		if action == ACTIONS.Settings or action == ACTIONS.Tutorial or action == ACTIONS.Sync then
			-- Handled below; the answer goes to the duel screen.
		else
			reply(player, state, "rejected", "in_duel")
			return
		end
	end

	if action == ACTIONS.Start then
		local mode = data.mode
		if mode == nil then
			mode = PLAY_MODES.Journey
		end
		if type(mode) ~= "string" or not PLAY_MODES[mode] then
			send(player, state, "rejected", "bad_mode")
			return
		end
		local day = today()
		local puzzle = if mode == PLAY_MODES.Daily
			then Progression.dailyPuzzle(day)
			else PuzzleDefinitions.get(data.puzzleId)
		if not puzzle then
			send(player, state, "rejected", "unknown_puzzle")
			return
		end
		local allowed, why = Progression.canStart(profileOf(player), puzzle, mode, day)
		if not allowed then
			send(player, state, "rejected", why)
			return
		end
		startPuzzle(player, puzzle, mode, day, true)
	elseif action == ACTIONS.Move then
		local session = state.session
		local wasPlaying = session.status == "playing"
		local ok, err = session:tryMove(data.from, data.to)
		if not ok then
			send(player, state, "rejected", err)
			return
		end
		state.reward = nil
		state.result = nil
		if session.status == "won" then
			state.finishedAt = os.clock()
			-- Re-check the win from the server's own move log before recording it.
			local log = {}
			for _, move in ipairs(session.history) do
				table.insert(log, { BoardState.squareName(session.board, move.from), BoardState.squareName(session.board, move.to) })
			end
			local valid, why = PuzzleValidator.validateSolution(session.puzzle.layout, log)
			if valid then
				-- Compare the profile before and after so the card shows what changed.
				local profile = profileOf(player)
				local puzzleId = session.puzzle.id
				local before = profile.completed[puzzleId]
				local bestBefore = if before then before.bestMoves else nil
				local starsBefore = if before then before.stars else 0
				local unlockedBefore = Progression.unlockedIndex(profile)
				local shieldBefore = profile.streak.shieldUsedOn
				state.reward = record(player, {
					kind = "win",
					puzzleId = session.puzzle.id,
					mode = state.mode,
					day = state.day,
					moves = session.moveCount,
					seconds = math.floor(elapsed(state) * 10) / 10,
				})
				profile = profileOf(player)
				local unlockedAfter = Progression.unlockedIndex(profile)
				local credited = state.mode ~= PLAY_MODES.Practice
				state.result = {
					stars = Progression.starsFor(session.puzzle, session.moveCount),
					starsSaved = credited,
					bestStars = if profile.completed[puzzleId] then profile.completed[puzzleId].stars else 0,
					newStars = credited and Progression.starsFor(session.puzzle, session.moveCount) > starsBefore,
					previousBest = bestBefore,
					newBest = bestBefore ~= nil and session.moveCount < bestBefore,
					twoStarMoves = Progression.twoStarMoves(session.puzzle),
					unlocked = if unlockedAfter > unlockedBefore then GameConfig.DIFFICULTIES[unlockedAfter] else nil,
					shieldUsed = profile.streak.shieldUsedOn ~= shieldBefore,
				}
				requestSave(player)
			else
				warn("[PuzzleService] win by " .. player.Name .. " failed the replay check: " .. tostring(why))
			end
			print(
				string.format(
					"[PuzzleService] %s cleared %s (%s) in %d moves (%.1fs)%s",
					player.Name,
					session.puzzle.id,
					state.mode,
					session.moveCount,
					elapsed(state),
					if state.reward then string.format(", +%d xp", state.reward.xp) else ""
				)
			)
		elseif wasPlaying and session.status == "failed" then
			record(player, { kind = "fail", puzzleId = session.puzzle.id, mode = state.mode })
		end
		send(player, state, "move")
	elseif action == ACTIONS.Undo then
		if not state.session:undo() then
			send(player, state, "rejected", "cannot_undo")
			return
		end
		send(player, state, "undo")
	elseif action == ACTIONS.Restart then
		if state.session.moveCount > 0 then
			record(player, { kind = "restart", puzzleId = state.session.puzzle.id, mode = state.mode })
		end
		startPuzzle(player, state.session.puzzle, state.mode, state.day)
	elseif action == ACTIONS.Hint then
		local session = state.session
		if session.status == "won" then
			send(player, state, "rejected", "not_playing")
			return
		end
		if session.status == "failed" then
			-- Pointing out a dead end is free: it costs no hint.
			state.hint, state.hintSquare = PuzzleHints.forLevel(session.puzzle, session.board, session.status, 1)
			send(player, state, "hint")
			return
		end
		if Progression.hintsLeft(profileOf(player), state.mode, state.hintsUsed, state.day) < 1 then
			send(player, state, "rejected", "no_hints")
			return
		end
		state.hintsUsed += 1
		state.hint, state.hintSquare = PuzzleHints.forLevel(session.puzzle, session.board, session.status, state.hintsUsed)
		record(player, { kind = "hint", puzzleId = session.puzzle.id, mode = state.mode, day = state.day })
		send(player, state, "hint")
	elseif action == ACTIONS.Settings then
		-- Progression.applySettings keeps only valid values; nothing else is read.
		local values = {}
		for _, key in ipairs({ "sound", "volume", "haptics", "drag" }) do
			values[key] = data[key]
		end
		record(player, { kind = "settings", settings = values })
		reply(player, state, "settings")
	elseif action == ACTIONS.Tutorial then
		local outcome = data.outcome
		if outcome ~= "completed" and outcome ~= "skipped" then
			send(player, state, "rejected", "bad_tutorial")
			return
		end
		record(player, { kind = "tutorial", outcome = outcome })
		reply(player, state, "tutorial")
	elseif action == ACTIONS.Sync then
		-- The first puzzle starts when the player joins, before their client has
		-- loaded; don't count loading time against an untouched attempt.
		if state.session.moveCount == 0 and #state.session.history == 0 then
			state.startedAt = os.clock()
		end
		reply(player, state, "sync")
	end
end

local function pickDuelPuzzle(): PuzzleDefinitions.Puzzle
	local pool = {}
	for _, difficulty in ipairs(GameConfig.DUEL.DIFFICULTIES) do
		for _, puzzle in ipairs(PuzzleDefinitions.byDifficulty[difficulty]) do
			table.insert(pool, puzzle)
		end
	end
	return pool[math.random(1, #pool)]
end

local function createDuels()
	duels = DuelManager.new({
		now = os.clock,
		newId = function()
			return HttpService:GenerateGUID(false)
		end,
		pickPuzzle = function()
			return pickDuelPuzzle()
		end,
		send = function(userId: number, snap: { [string]: any })
			local player = Players:GetPlayerByUserId(userId)
			if player and states[player] then
				sendDuel(player, snap)
			end
		end,
		record = function(userId: number, result: { [string]: any }): (any, string?)
			-- Only players with a profile on this server (not the Studio test bot).
			local profile = profiles:get(userId)
			if not profile then
				return nil, nil
			end
			local day = today()
			local block = if result.outcome ~= "loss" then Progression.duelRewardBlock(profile, day, result.opponent) else nil
			local reward = profiles:record(userId, {
				-- One id per player per match: a repeated record is ignored.
				id = "duel:" .. result.matchId .. ":" .. userId,
				kind = "duel",
				matchId = result.matchId,
				outcome = result.outcome,
				reason = result.reason,
				opponent = result.opponent,
				day = day,
			})
			print(string.format("[PuzzleService] duel %s: %d %s (%s)", result.matchId, userId, result.outcome, result.reason))
			task.spawn(function()
				profiles:save(userId)
			end)
			return reward, block
		end,
		modules = { PuzzleSession = PuzzleSession, PuzzleValidator = PuzzleValidator, BoardState = BoardState },
		config = GameConfig.DUEL,
	})
end

local function sortedMap(name: string): DuelMatchmaker.Map
	local map = MemoryStoreService:GetSortedMap(name)
	return {
		get = function(_, key: string): any
			return map:GetAsync(key)
		end,
		set = function(_, key: string, value: any, ttl: number, sortKey: number?)
			map:SetAsync(key, value, ttl, sortKey)
		end,
		update = function(_, key: string, fn: (any) -> any, ttl: number): any
			return map:UpdateAsync(key, function(value: any, sortKey: any)
				local new = fn(value)
				if new == nil then
					return nil
				end
				return new, sortKey
			end, ttl)
		end,
		remove = function(_, key: string)
			map:RemoveAsync(key)
		end,
		range = function(_, count: number): { { key: string, value: any } }
			local list = {}
			for _, item in ipairs(map:GetRangeAsync(Enum.SortDirection.Ascending, count)) do
				table.insert(list, { key = item.key, value = item.value })
			end
			return list
		end,
	}
end

-- A reserved server made by the matchmaker (not a player's private server).
local function isMatchServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

-- Cross-server matching needs MemoryStore and teleports, which Studio doesn't
-- have without API access, so Studio keeps same-server matching only.
local function createMatchmaker()
	local config = GameConfig.DUEL.CROSS_SERVER
	if not config.ENABLED or RunService:IsStudio() or game.PlaceId == 0 then
		return
	end
	matchmaker = DuelMatchmaker.new({
		tickets = sortedMap("EchoChessDuelTickets_v1"),
		matches = sortedMap("EchoChessDuelMatches_v1"),
		now = os.time,
		serverId = game.JobId,
		newId = function()
			return HttpService:GenerateGUID(false)
		end,
		reserve = function()
			return TeleportService:ReserveServer(game.PlaceId)
		end,
		teleport = function(userId: number, accessCode: string): boolean
			local player = Players:GetPlayerByUserId(userId)
			if not player then
				return false
			end
			local options = Instance.new("TeleportOptions")
			options.ReservedServerAccessCode = accessCode
			local ok, err = pcall(function()
				TeleportService:TeleportAsync(game.PlaceId, { player }, options)
			end)
			if not ok then
				warn("[PuzzleService] duel teleport failed: " .. tostring(err))
			end
			return ok
		end,
		pickPuzzleId = function()
			return pickDuelPuzzle().id
		end,
		duels = duels,
		log = function(message: string)
			warn("[PuzzleService] " .. message)
		end,
		config = config,
	})
	duels.crossServer = true

	TeleportService.TeleportInitFailed:Connect(function(player: Player)
		matchmaker:teleportFailed(player.UserId)
	end)
	task.spawn(function()
		while true do
			task.wait(config.POLL)
			matchmaker:step()
		end
	end)

	if isMatchServer() then
		task.spawn(function()
			local serverKey = game.PrivateServerId
			local record = nil
			for _ = 1, 5 do
				local ok, result = pcall(matchmaker.hostedMatch, matchmaker, serverKey)
				if ok then
					record = result
					break
				end
				task.wait(1)
			end
			if not record then
				return -- an ordinary reserved server; nothing to host
			end
			-- Only puzzles a duel may use; the record is ours, but check anyway.
			local puzzle = PuzzleDefinitions.get(record.puzzleId)
			if not (puzzle and table.find(GameConfig.DUEL.DIFFICULTIES, puzzle.difficulty)) then
				puzzle = pickDuelPuzzle()
			end
			duels:expect(record.matchId, puzzle, record.players, config.ARRIVAL_WAIT)
			for _, entry in ipairs(record.players) do
				if synced[entry.id] then
					duels:arrive(entry.id)
				end
			end
			-- Stop waiting early if the other server says its player isn't coming.
			while duels.pending do
				task.wait(3)
				local ok, declined = pcall(matchmaker.declined, matchmaker, serverKey)
				if ok and declined and duels.pending then
					duels:abandonPending()
				end
			end
		end)
	end
end

-- Studio only: a server-side BindableFunction that adds a test opponent (user
-- id -1) driven from Studio's command bar, so one person can play a whole duel
-- in Studio. It doesn't exist in a live game, and clients can't call it.
local function createStudioDuelHook()
	if not RunService:IsStudio() then
		return
	end
	local BOT = -1
	local hook = Instance.new("BindableFunction")
	hook.Name = "EchoChessDuelTestHook"
	hook.OnInvoke = function(command: string, a: any, b: any): any
		if command == "join" then
			return duels:join(BOT, "Studio Bot")
		elseif command == "move" then
			local snap = duels:snapshot(BOT, "sync")
			if not snap.layout then
				return false, "not_in_duel"
			end
			local board = BoardState.fromLayout(snap.layout)
			return duels:act(BOT, "move", { from = BoardState.parseSquare(board, a), to = BoardState.parseSquare(board, b) })
		elseif command == "leave" then
			return duels:leave(BOT)
		elseif command == "disconnect" then
			duels:disconnect(BOT)
			return true
		elseif command == "state" then
			return duels:snapshot(if type(a) == "number" then a else BOT, "sync")
		elseif command == "timeout" then
			-- Ends every running match as if its time ran out.
			for _, match in pairs(duels.matches) do
				match.endsAt = os.clock()
			end
			duels:update()
			return true
		end
		return nil
	end
	hook.Parent = ServerStorage
end

function PuzzleService.Start()
	ensureRemotes()
	createProfiles()
	createDuels()
	createMatchmaker()
	createStudioDuelHook()
	actionRemote.OnServerEvent:Connect(onAction)

	local function onPlayerAdded(player: Player)
		startPuzzle(player, PuzzleDefinitions.list[1], PLAY_MODES.Journey, today())
		profiles:load(player.UserId)
		local state = states[player]
		if not (state and player.Parent) then
			return
		end
		-- Returning players resume their Journey instead of Beginner 1, unless
		-- they already picked something while the profile was loading.
		local resume = Progression.nextJourneyPuzzle(profileOf(player))
		if not state.userStarted and state.session.moveCount == 0 and resume and resume ~= state.session.puzzle then
			startPuzzle(player, resume, PLAY_MODES.Journey, today())
		else
			send(player, state, "sync")
		end
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		-- Settle any duel first, so the leaver's loss is saved with their profile
		-- and the opponent gets their result straight away.
		duels:disconnect(player.UserId)
		synced[player.UserId] = nil
		states[player] = nil
		profiles:release(player.UserId)
	end)

	-- Duel clock: starts matches after the countdown and ends them on time.
	task.spawn(function()
		while true do
			task.wait(0.2)
			duels:update()
		end
	end)

	-- Autosave: ops are also saved soon after every win.
	task.spawn(function()
		while true do
			task.wait(ProfileStore.AUTOSAVE_INTERVAL)
			for _, userId in ipairs(profiles:userIds()) do
				task.spawn(function()
					profiles:save(userId)
				end)
			end
		end
	end)
end

-- Saves everyone before the server shuts down (game:BindToClose).
function PuzzleService.Shutdown()
	local userIds = profiles:userIds()
	local remaining = #userIds
	for _, userId in ipairs(userIds) do
		task.spawn(function()
			profiles:release(userId)
			remaining -= 1
		end)
	end
	local deadline = os.clock() + 25
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.2)
	end
end

return PuzzleService
