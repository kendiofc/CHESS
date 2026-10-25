--!strict
-- PuzzleService: the authoritative puzzle state for every player.
--
-- Clients only send intents (start / move / undo / restart). The server owns a
-- PuzzleSession per player, validates every move with the shared rules, decides
-- win/failure, times the attempt with its own clock, and sends back a full
-- snapshot after every action. Nothing the client says about legality,
-- completion or time is trusted.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoardState = require(Shared:WaitForChild("BoardState"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PuzzleDefinitions = require(Shared:WaitForChild("PuzzleDefinitions"))
local PuzzleSession = require(Shared:WaitForChild("PuzzleSession"))

local ACTIONS = GameConfig.ACTIONS

type PlayerState = {
	session: PuzzleSession.PuzzleSession,
	startedAt: number,
	finishedAt: number?,
	tokens: number,
	refilledAt: number,
}

local PuzzleService = {}

local states: { [Player]: PlayerState } = {}
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

local function snapshot(state: PlayerState, event: string, err: string?)
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
	}
end

local function send(player: Player, state: PlayerState, event: string, err: string?)
	stateRemote:FireClient(player, snapshot(state, event, err))
end

local function startPuzzle(player: Player, puzzle: PuzzleDefinitions.Puzzle)
	local now = os.clock()
	local previous = states[player]
	local state: PlayerState = {
		session = PuzzleSession.new(puzzle),
		startedAt = now,
		finishedAt = nil,
		tokens = if previous then previous.tokens else GameConfig.RATE_LIMIT.BURST,
		refilledAt = if previous then previous.refilledAt else now,
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
		send(player, state, "rejected", "rate_limited")
		return
	end
	if type(action) ~= "string" then
		return
	end
	local data = if type(payload) == "table" then payload :: { [any]: any } else {}

	if action == ACTIONS.Start then
		local puzzle = PuzzleDefinitions.get(data.puzzleId)
		if not puzzle then
			send(player, state, "rejected", "unknown_puzzle")
			return
		end
		startPuzzle(player, puzzle)
	elseif action == ACTIONS.Move then
		local session = state.session
		local ok, err = session:tryMove(data.from, data.to)
		if not ok then
			send(player, state, "rejected", err)
			return
		end
		if session.status == "won" then
			state.finishedAt = os.clock()
			print(
				string.format(
					"[PuzzleService] %s cleared %s in %d moves (%.1fs)",
					player.Name,
					session.puzzle.id,
					session.moveCount,
					elapsed(state)
				)
			)
		end
		send(player, state, "move")
	elseif action == ACTIONS.Undo then
		if not state.session:undo() then
			send(player, state, "rejected", "cannot_undo")
			return
		end
		send(player, state, "undo")
	elseif action == ACTIONS.Restart then
		startPuzzle(player, state.session.puzzle)
	elseif action == ACTIONS.Sync then
		send(player, state, "sync")
	end
end

function PuzzleService.Start()
	ensureRemotes()
	actionRemote.OnServerEvent:Connect(onAction)

	local function onPlayerAdded(player: Player)
		startPuzzle(player, PuzzleDefinitions.list[1])
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
end

return PuzzleService
