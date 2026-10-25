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

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoardState = require(Shared:WaitForChild("BoardState"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local PuzzleDefinitions = require(Shared:WaitForChild("PuzzleDefinitions"))
local PuzzleHints = require(Shared:WaitForChild("PuzzleHints"))
local PuzzleSession = require(Shared:WaitForChild("PuzzleSession"))
local PuzzleValidator = require(Shared:WaitForChild("PuzzleValidator"))
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
	tokens: number,
	refilledAt: number,
	throttled: boolean,
}

local PuzzleService = {}

local states: { [Player]: PlayerState } = {}
local profiles: any
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

-- Token bucket: returns false when the player is sending actions too fast.
local function consumeToken(state: PlayerState): boolean
	local now = os.clock()
	local limit = GameConfig.RATE_LIMIT
	state.tokens = math.min(limit.BURST, state.tokens + (now - state.refilledAt) * limit.PER_SECOND)
	state.refilledAt = now
	if state.tokens < 1 then
		return false
	end
	state.tokens -= 1
	return true
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
		hintsUsed = state.hintsUsed,
		hintsLeft = (function()
			local left = Progression.hintsLeft(profileOf(player), state.mode, state.hintsUsed, state.day)
			return if left == math.huge then -1 else left
		end)(),
		reward = if event == "move" then state.reward else nil,
		progress = Progression.summary(profileOf(player), today()),
		saveStatus = profiles:status(player.UserId) or "loading",
	}
end

local function send(player: Player, state: PlayerState, event: string, err: string?)
	stateRemote:FireClient(player, snapshot(player, state, event, err))
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
		tokens = if previous then previous.tokens else GameConfig.RATE_LIMIT.BURST,
		refilledAt = if previous then previous.refilledAt else now,
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
	if not consumeToken(state) then
		-- Tell the client once per throttled burst; don't answer every spammed call.
		if not state.throttled then
			state.throttled = true
			send(player, state, "rejected", "rate_limited")
		end
		return
	end
	state.throttled = false
	if type(action) ~= "string" then
		return
	end
	local data = if type(payload) == "table" then payload :: { [any]: any } else {}

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
		send(player, state, "settings")
	elseif action == ACTIONS.Tutorial then
		local outcome = data.outcome
		if outcome ~= "completed" and outcome ~= "skipped" then
			send(player, state, "rejected", "bad_tutorial")
			return
		end
		record(player, { kind = "tutorial", outcome = outcome })
		send(player, state, "tutorial")
	elseif action == ACTIONS.Sync then
		-- The first puzzle starts when the player joins, before their client has
		-- loaded; don't count loading time against an untouched attempt.
		if state.session.moveCount == 0 and #state.session.history == 0 then
			state.startedAt = os.clock()
		end
		send(player, state, "sync")
	end
end

function PuzzleService.Start()
	ensureRemotes()
	createProfiles()
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
		states[player] = nil
		profiles:release(player.UserId)
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
