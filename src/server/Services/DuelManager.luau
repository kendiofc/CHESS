--!strict
-- DuelManager: the Puzzle Duel queue and matches for one server.
--
-- Two players race to clear the same puzzle. They don't take turns: each has
-- their own PuzzleSession on the same starting board, and the server checks
-- every move against that player's own board. The first board clear the
-- server processes wins; the win is re-checked by replaying the server's move
-- log. Nobody clearing the board within the time limit is a draw. Leaving or
-- disconnecting during a match loses it, and the opponent wins by forfeit.
--
-- Everything here is decided by the server. A client can only ask to join or
-- leave the queue, forfeit, or move / undo / restart on its own board; the
-- puzzle, the opponent, the match id, the clock and the result are never read
-- from a client.
--
-- Roblox runs every remote handler on one thread, so two requests never
-- interleave: "simultaneous" finishes are decided by arrival order, and once a
-- match is finished nothing can change its result.
--
-- Like ProfileStore, it takes its clock, ids and outputs as arguments so
-- tests/run.luau can drive whole matches without Roblox. Players are keyed by
-- user id; one user id is one player.
--
-- Matching is per server. Cross-server matchmaking would need MemoryStore
-- queues and teleports, and is not built yet.

local DuelManager = {}
DuelManager.__index = DuelManager

export type Deps = {
	now: () -> number, -- seconds, monotonic
	newId: () -> string, -- unique match ids
	pickPuzzle: (matchNumber: number) -> any, -- a validated catalogue puzzle
	send: (id: number, snapshot: { [string]: any }) -> (),
	-- Records a finished match for one player (Progression "duel" op).
	-- Returns the reward paid, if any, and why nothing was paid, if known.
	record: (id: number, result: { [string]: any }) -> (any, string?),
	modules: { PuzzleSession: any, PuzzleValidator: any, BoardState: any },
	config: { COUNTDOWN: number, TIME_LIMIT: number },
}

type Side = {
	id: number,
	name: string,
	session: any,
	connected: boolean,
	outcome: string?, -- "win" | "loss" | "draw" once finished
	reason: string?,
	reward: any,
	rewardNote: string?,
}

type Match = {
	id: string,
	puzzle: any,
	phase: string, -- "countdown" | "playing" | "finished"
	startsAt: number,
	endsAt: number,
	finishedAt: number?,
	order: { number },
	sides: { [number]: Side },
	winner: number?,
}

function DuelManager.new(deps: Deps)
	return setmetatable({
		deps = deps,
		queue = {} :: { { id: number, name: string } },
		active = {} :: { [number]: Match }, -- player -> their unfinished match
		results = {} :: { [number]: Match }, -- player -> their last finished match
		matches = {} :: { [string]: Match },
		matchCount = 0,
	}, DuelManager)
end

local function opponentOf(match: Match, id: number): Side
	local other = if match.order[1] == id then match.order[2] else match.order[1]
	return match.sides[other]
end

function DuelManager._queueIndex(self: any, id: number): number?
	for index, entry in ipairs(self.queue) do
		if entry.id == id then
			return index
		end
	end
	return nil
end

-- "queued", "countdown", "playing", or nil.
function DuelManager.stateOf(self: any, id: number): string?
	if self:_queueIndex(id) then
		return "queued"
	end
	local match = self.active[id]
	return match and match.phase
end

-- Whether the player is looking at a duel screen: queued, in a match, or on
-- a match result they haven't closed.
function DuelManager.hasScreen(self: any, id: number): boolean
	return self:_queueIndex(id) ~= nil or self.active[id] ~= nil or self.results[id] ~= nil
end

function DuelManager.queueSize(self: any): number
	return #self.queue
end

-- Snapshots ----------------------------------------------------------------------

local function captured(side: Side): number
	local session = side.session
	return session.targetsTotal - session:targetsLeft()
end

function DuelManager.snapshot(self: any, id: number, event: string, err: string?): { [string]: any }
	local now = self.deps.now()
	if self:_queueIndex(id) then
		return {
			event = event,
			error = err,
			mode = "Duel",
			duel = { phase = "queued", waiting = #self.queue },
		}
	end
	local match = self.active[id] or self.results[id]
	if not match then
		return { event = event, error = err, mode = "Duel", duel = { phase = "idle" } }
	end
	local BoardState = self.deps.modules.BoardState
	local side = match.sides[id]
	local other = opponentOf(match, id)
	local session = side.session
	local puzzle = match.puzzle
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
	local clock = match.finishedAt or now
	return {
		event = event,
		error = err,
		mode = "Duel",
		puzzleId = puzzle.id,
		name = puzzle.name,
		difficulty = puzzle.difficulty,
		objective = puzzle.objective,
		par = puzzle.par,
		number = puzzle.number,
		layout = BoardState.toLayout(session.board),
		status = session.status,
		moveCount = session.moveCount,
		targetsTotal = session.targetsTotal,
		targetsLeft = session:targetsLeft(),
		canUndo = match.phase == "playing" and session.status ~= "won" and #session.history > 0,
		elapsed = math.max(0, clock - match.startsAt),
		lastMove = lastMove,
		hintsLeft = 0,
		hintsUsed = 0,
		duel = {
			matchId = match.id,
			phase = match.phase,
			startsIn = math.max(0, match.startsAt - now),
			timeLeft = math.max(0, match.endsAt - clock),
			timeLimit = match.endsAt - match.startsAt,
			opponent = {
				name = other.name,
				captured = captured(other),
				total = other.session.targetsTotal,
				moves = other.session.moveCount,
				connected = other.connected,
				solved = match.winner == other.id,
			},
			outcome = side.outcome,
			reason = side.reason,
			reward = side.reward,
			rewardNote = side.rewardNote,
		},
	}
end

function DuelManager._send(self: any, id: number, event: string, err: string?)
	self.deps.send(id, self:snapshot(id, event, err))
end

-- Queue ----------------------------------------------------------------------------

-- Puts a player in the queue, or matches them with the first player waiting.
-- Returns ok, error code.
function DuelManager.join(self: any, id: number, name: string): (boolean, string?)
	if self:_queueIndex(id) then
		return false, "already_queued"
	end
	if self.active[id] then
		return false, "in_duel"
	end
	self.results[id] = nil
	-- Nobody else is ever this player: the queue holds each id once and the
	-- joining player isn't in it.
	local opponent = table.remove(self.queue, 1)
	if opponent then
		self:_createMatch(opponent, { id = id, name = name })
	else
		table.insert(self.queue, { id = id, name = name })
		self:_send(id, "duel_queued")
	end
	return true, nil
end

function DuelManager.cancel(self: any, id: number): (boolean, string?)
	local index = self:_queueIndex(id)
	if not index then
		return false, "not_queued"
	end
	table.remove(self.queue, index)
	self:_send(id, "duel_cancelled")
	return true, nil
end

function DuelManager._createMatch(self: any, a: { id: number, name: string }, b: { id: number, name: string })
	local deps = self.deps
	self.matchCount += 1
	local puzzle = deps.pickPuzzle(self.matchCount)
	local now = deps.now()
	local match: Match = {
		id = deps.newId(),
		puzzle = puzzle,
		phase = "countdown",
		startsAt = now + deps.config.COUNTDOWN,
		endsAt = now + deps.config.COUNTDOWN + deps.config.TIME_LIMIT,
		finishedAt = nil,
		order = { a.id, b.id },
		sides = {},
		winner = nil,
	}
	assert(self.matches[match.id] == nil, "match ids must be unique")
	for _, entry in ipairs({ a, b }) do
		match.sides[entry.id] = {
			id = entry.id,
			name = entry.name,
			session = deps.modules.PuzzleSession.new(puzzle),
			connected = true,
			outcome = nil,
			reason = nil,
			reward = nil,
			rewardNote = nil,
		}
		self.active[entry.id] = match
		self.results[entry.id] = nil
	end
	self.matches[match.id] = match
	for _, id in ipairs(match.order) do
		self:_send(id, "duel_found")
	end
end

-- Match flow ---------------------------------------------------------------------------

-- Starts matches whose countdown is over and ends those out of time. Call it
-- regularly (the service does, a few times a second).
function DuelManager.update(self: any)
	local now = self.deps.now()
	for _, match in pairs(self.matches) do
		if match.phase == "countdown" and now >= match.startsAt then
			match.phase = "playing"
			for _, id in ipairs(match.order) do
				if match.sides[id].connected then
					self:_send(id, "duel_start")
				end
			end
		end
		if match.phase == "playing" and now >= match.endsAt then
			self:_finish(match, nil, "timeout")
		end
	end
end

function DuelManager._finish(self: any, match: Match, winner: number?, reason: string)
	if match.phase == "finished" then
		return
	end
	match.phase = "finished"
	match.finishedAt = math.min(self.deps.now(), match.endsAt)
	match.winner = winner
	for _, id in ipairs(match.order) do
		local side = match.sides[id]
		local other = opponentOf(match, id)
		if winner == nil then
			side.outcome = "draw"
			side.reason = reason
		elseif winner == id then
			side.outcome = "win"
			side.reason = reason
		else
			side.outcome = "loss"
			side.reason = if reason == "opponent_left" then "left" else "opponent_solved"
		end
		side.reward, side.rewardNote = self.deps.record(id, {
			matchId = match.id,
			outcome = side.outcome,
			reason = side.reason,
			opponent = other.id,
			puzzleId = match.puzzle.id,
		})
		self.active[id] = nil
		if side.connected then
			self.results[id] = match
		end
	end
	self.matches[match.id] = nil
	for _, id in ipairs(match.order) do
		if match.sides[id].connected then
			self:_send(id, "duel_end")
		end
	end
end

-- A move, undo or restart on the player's own board. Returns ok, error code;
-- a rejected request is also answered with a snapshot carrying the error.
function DuelManager.act(self: any, id: number, action: string, data: { [any]: any }): (boolean, string?)
	local match = self.active[id]
	local err: string? = nil
	if not match then
		err = "not_in_duel"
	elseif match.phase == "countdown" then
		err = "not_started"
	elseif match.phase ~= "playing" then
		err = "match_over"
	end
	if err or not match then
		self:_send(id, "rejected", err)
		return false, err
	end
	if self.deps.now() >= match.endsAt then
		-- The clock ran out before update() noticed: the match is a draw.
		self:_finish(match, nil, "timeout")
		self:_send(id, "rejected", "match_over")
		return false, "match_over"
	end
	local side = match.sides[id]
	local session = side.session
	if action == "move" then
		local ok, moveErr = session:tryMove(data.from, data.to)
		if not ok then
			self:_send(id, "rejected", moveErr)
			return false, moveErr
		end
	elseif action == "undo" then
		if not session:undo() then
			self:_send(id, "rejected", "cannot_undo")
			return false, "cannot_undo"
		end
	elseif action == "restart" then
		session:restart()
	else
		self:_send(id, "rejected", "bad_action")
		return false, "bad_action"
	end
	if session.status == "won" then
		-- Re-check the clear from the server's own move log before it counts.
		local BoardState = self.deps.modules.BoardState
		local log = {}
		for _, move in ipairs(session.history) do
			table.insert(log, { BoardState.squareName(session.board, move.from), BoardState.squareName(session.board, move.to) })
		end
		if self.deps.modules.PuzzleValidator.validateSolution(match.puzzle.layout, log) then
			self:_finish(match, id, "solved")
			return true, nil
		end
	end
	self:_send(id, action)
	local other = opponentOf(match, id)
	if other.connected then
		self:_send(other.id, "duel_opponent")
	end
	return true, nil
end

-- Forfeits the current match, or leaves the queue.
function DuelManager.leave(self: any, id: number): (boolean, string?)
	if self:_queueIndex(id) then
		return self:cancel(id)
	end
	local match = self.active[id]
	if not match then
		return false, "not_in_duel"
	end
	self:_finish(match, opponentOf(match, id).id, "opponent_left")
	return true, nil
end

-- The player left the server: out of the queue, and any match is forfeited
-- so the opponent isn't left waiting. Safe to call for anyone.
function DuelManager.disconnect(self: any, id: number)
	local index = self:_queueIndex(id)
	if index then
		table.remove(self.queue, index)
	end
	local match = self.active[id]
	if match then
		match.sides[id].connected = false
		self:_finish(match, opponentOf(match, id).id, "opponent_left")
	end
	self.results[id] = nil
end

-- Closes the result screen. Returns false while the player is queued or in a match.
function DuelManager.exit(self: any, id: number): boolean
	if self:_queueIndex(id) or self.active[id] then
		return false
	end
	self.results[id] = nil
	return true
end

return DuelManager
