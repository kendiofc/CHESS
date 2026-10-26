--!strict
-- GameConfig: shared constants. Gameplay-relevant values are read by the
-- server; the client only uses them for display.

local GameConfig = {}

-- Rule sets. Every puzzle is an Echo Clear puzzle for now.
GameConfig.MODES = {
	EchoClear = "EchoClear",
}

GameConfig.DIFFICULTIES = { "Beginner", "Easy", "Medium", "Hard", "Expert" }

GameConfig.DIFFICULTY_SETTINGS = {
	Beginner = { reward = { xp = 20, coins = 5 }, estimatedSeconds = 60 },
	Easy = { reward = { xp = 35, coins = 8 }, estimatedSeconds = 120 },
	Medium = { reward = { xp = 50, coins = 12 }, estimatedSeconds = 240 },
	Hard = { reward = { xp = 80, coins = 18 }, estimatedSeconds = 420 },
	Expert = { reward = { xp = 120, coins = 25 }, estimatedSeconds = 600 },
}

-- How a puzzle was started. This decides hints, unlocks and rewards.
--   Journey   the main ladder: only unlocked difficulties, completions unlock
--             the next difficulty and pay the puzzle's reward once
--   Practice  any difficulty, free hints, no rewards and no unlock progress
--   Daily     one puzzle per UTC day, one free hint, reward once per day
--   Weekly    the week's fixed set of puzzles (WeeklyChallenge), milestone
--             rewards once per week
-- Puzzle Duels are not a play mode: a client can't start one with "start".
-- The server creates them from its queue (see GameConfig.DUEL).
GameConfig.PLAY_MODES = {
	Journey = "Journey",
	Practice = "Practice",
	Daily = "Daily",
	Weekly = "Weekly",
}

-- The mode name duel snapshots carry.
GameConfig.DUEL_MODE = "Duel"

-- Hints allowed per attempt (math.huge = unlimited). Daily hints are counted
-- per day, not per attempt, so restarting does not refill them. A competitive
-- mode added later must be listed with 0.
GameConfig.HINTS = {
	Journey = math.huge,
	Practice = math.huge,
	Daily = 1,
	Weekly = 1,
	Duel = 0,
}

-- Completed puzzles of a difficulty (in Journey or Daily) needed to unlock the next.
GameConfig.UNLOCK_REQUIREMENT = 4

-- The Daily Puzzle is drawn from these difficulties.
GameConfig.DAILY_DIFFICULTIES = { "Easy", "Medium", "Hard" }
GameConfig.DAILY_REWARD = { xp = 60, coins = 15 }

-- Star rating for a clear, decided by moves only (hints never cost stars):
--   3 stars  within par (par is the proven minimum)
--   2 stars  at most `slack` moves over par
--   1 star   any other clear
-- A puzzle can override the 2-star limit with `twoStarMoves` in its catalogue
-- entry. Stars are saved from Journey and Daily clears; Practice shows them on
-- the result card but does not save them.
GameConfig.STAR_SLACK = {
	Beginner = 1,
	Easy = 2,
	Medium = 3,
	Hard = 4,
	Expert = 5,
}

-- Daily streak protection: one shield per rolling 7 days. A shield covers a
-- single missed day (clearing on day N+2 after a clear on day N keeps the
-- streak) and pays nothing for the missed day. Days are UTC day numbers.
GameConfig.STREAK_SHIELD_DAYS = 7

-- Cosmetics are earned with coins later (board themes, piece skins, effects).
-- Nothing is for sale yet; this lists the slots and the free defaults so saved
-- profiles already have a place for them. Cosmetics never change gameplay.
GameConfig.COSMETIC_SLOTS = {
	board = "classic",
	pieces = "classic",
	effect = "none",
}

-- Player settings the server stores. Volume is 0..1.
GameConfig.DEFAULT_SETTINGS = {
	sound = true,
	volume = 0.7,
	haptics = true,
	drag = true, -- drag-to-move on top of tap-to-move
}

-- Remote rate limit per player: a bucket of BURST actions refilled at
-- PER_SECOND tokens per second.
GameConfig.RATE_LIMIT = {
	BURST = 8,
	PER_SECOND = 6,
}

-- Puzzle Duel: two players in the same server race to clear the same puzzle.
GameConfig.DUEL = {
	DIFFICULTIES = { "Easy", "Medium" }, -- the server picks the puzzle from these
	COUNTDOWN = 3, -- seconds between "opponent found" and the start
	TIME_LIMIT = 180, -- seconds; nobody clearing the board in time is a draw
	REWARD_WIN = { xp = 25, coins = 6 },
	REWARD_DRAW = { xp = 10, coins = 2 }, -- also a win because the opponent left
	DAILY_REWARDED = 5, -- rewarded duels per player per UTC day
	-- Searching other servers (MemoryStore tickets, then a teleport to a reserved
	-- server). Off in Studio, where MemoryStore and teleports aren't available
	-- without API access; players there are matched on their own server.
	CROSS_SERVER = {
		ENABLED = true,
		POLL = 2, -- seconds between matchmaking steps
		TICKET_TTL = 30, -- a ticket nobody refreshes is gone after this
		STALE = 10, -- a ticket not refreshed for this long isn't offered
		MATCH_TTL = 600, -- seconds the match record lives
		RANGE = 50, -- tickets read per search
		ARRIVAL_WAIT = 45, -- seconds the match server waits for both players
	},
	-- A player is paid for at most one duel per opponent per UTC day, so
	-- matching the same second account again and again earns nothing.
}

GameConfig.REMOTES = {
	Folder = "Remotes",
	Action = "PuzzleAction", -- client -> server: (action: string, payload: table?)
	State = "PuzzleState", -- server -> client: (snapshot: table)
}

GameConfig.ACTIONS = {
	Start = "start", -- { puzzleId, mode } or { mode = "Daily" }
	Move = "move",
	Undo = "undo",
	Restart = "restart",
	Hint = "hint",
	Settings = "settings", -- { sound: boolean?, volume: number?, haptics: boolean?, drag: boolean? }
	Tutorial = "tutorial", -- { outcome = "completed" | "skipped" }
	Sync = "sync", -- client asks for the current snapshot (e.g. after it loads)
	DuelJoin = "duel_join", -- enter the duel queue
	DuelCancel = "duel_cancel", -- leave the queue before a match starts
	DuelLeave = "duel_leave", -- forfeit the current match
	DuelExit = "duel_exit", -- close the result screen and go back to puzzles
}

return GameConfig
