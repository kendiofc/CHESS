--!strict
-- EndlessRun: one player's Endless run. Pure rules (in Shared so the tests can
-- reach them; only the server uses them): PuzzleService owns one per player in Endless.
--
-- The server picks the run id and seed; board n is EndlessGen.board(seed, n).
-- A run starts with GameConfig.ENDLESS.LIVES lives:
--   * clearing the board scores it, and only then may the run advance;
--   * a dead end costs a life, and replaying that board afterwards is free;
--   * restarting a board with moves on it costs a life;
--   * the run is over when the last life is gone. Nothing moves after that.
-- The client never says which board it is on or how many lives are left.

local GameConfig = require(script.Parent.GameConfig)
local EndlessGen = require(script.Parent.EndlessGen)
local PuzzleDefinitions = require(script.Parent.PuzzleDefinitions)

local EndlessRun = {}
EndlessRun.__index = EndlessRun

-- Board n, or a catalogue puzzle of the same difficulty in the (never seen)
-- case that no generated candidate passed the solver.
local function boardFor(seed: number, n: number): any
	local puzzle = EndlessGen.board(seed, n)
	if puzzle then
		return puzzle
	end
	local spec = EndlessGen.spec(n)
	local pool = PuzzleDefinitions.byDifficulty[spec.difficulty]
	local fallback = table.clone(pool[(seed + n) % #pool + 1])
	fallback.id = "endless-" .. n
	fallback.name = "Board " .. n
	fallback.number = n
	fallback.par = nil
	fallback.endless = true
	return fallback
end

function EndlessRun.new(runId: string, seed: number)
	return setmetatable({
		runId = runId,
		seed = seed,
		board = 1,
		lives = GameConfig.ENDLESS.LIVES,
		cleared = 0, -- boards cleared in this run (the score)
		over = false,
		paid = false, -- the current board's dead end has already cost a life
		puzzle = boardFor(seed, 1),
	}, EndlessRun)
end

-- The current board was cleared (the server has checked the win). Returns
-- the progression op that records it, or nil if it was already scored.
function EndlessRun.clear(self: any, day: number): any
	if self.over or self.cleared >= self.board then
		return nil
	end
	self.cleared = self.board
	return { id = "endless:" .. self.runId .. ":" .. self.board, kind = "endless", board = self.board, day = day }
end

-- Moves on to the next board. False unless the current one was cleared.
function EndlessRun.advance(self: any): boolean
	if self.over or self.cleared < self.board then
		return false
	end
	self.board += 1
	self.paid = false
	self.puzzle = boardFor(self.seed, self.board)
	return true
end

function EndlessRun._loseLife(self: any)
	self.lives = math.max(0, self.lives - 1)
	if self.lives == 0 then
		self.over = true
	end
end

-- The board just reached a dead end: costs a life (once per attempt).
function EndlessRun.deadEnd(self: any)
	if self.over or self.paid then
		return
	end
	self.paid = true
	self:_loseLife()
end

-- The player wants the current board again. `moved` is whether the attempt
-- has moves on it, `failed` whether it is at a dead end. Returns whether the
-- board may be replayed (false once the run is over).
function EndlessRun.retry(self: any, moved: boolean, failed: boolean): boolean
	if self.over then
		return false
	end
	if moved and not failed and not self.paid then
		self:_loseLife()
		if self.over then
			return false
		end
	end
	self.paid = false
	return true
end

-- What the client shows. `best` is the player's saved best run.
function EndlessRun.view(self: any, best: number): { [string]: any }
	return {
		board = self.board,
		lives = self.lives,
		maxLives = GameConfig.ENDLESS.LIVES,
		cleared = self.cleared,
		over = self.over,
		best = math.max(best, self.cleared),
	}
end

return EndlessRun
