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
GameConfig.PLAY_MODES = {
	Journey = "Journey",
	Practice = "Practice",
	Daily = "Daily",
}

-- Hints allowed per attempt (math.huge = unlimited). Daily hints are counted
-- per day, not per attempt, so restarting does not refill them. A competitive
-- mode added later must be listed with 0.
GameConfig.HINTS = {
	Journey = math.huge,
	Practice = math.huge,
	Daily = 1,
}

-- Completed puzzles of a difficulty (in Journey or Daily) needed to unlock the next.
GameConfig.UNLOCK_REQUIREMENT = 4

-- The Daily Puzzle is drawn from these difficulties.
GameConfig.DAILY_DIFFICULTIES = { "Easy", "Medium", "Hard" }
GameConfig.DAILY_REWARD = { xp = 60, coins = 15 }

-- Remote rate limit per player: a bucket of BURST actions refilled at
-- PER_SECOND tokens per second.
GameConfig.RATE_LIMIT = {
	BURST = 8,
	PER_SECOND = 6,
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
	Sync = "sync", -- client asks for the current snapshot (e.g. after it loads)
}

return GameConfig
