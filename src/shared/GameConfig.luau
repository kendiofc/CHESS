--!strict
-- GameConfig: shared constants. Gameplay-relevant values are read by the
-- server; the client only uses them for display.

local GameConfig = {}

GameConfig.MODES = {
	EchoClear = "EchoClear",
}

GameConfig.DIFFICULTIES = { "Beginner", "Easy", "Medium", "Hard", "Expert" }

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
	Start = "start",
	Move = "move",
	Undo = "undo",
	Restart = "restart",
	Sync = "sync", -- client asks for the current snapshot (e.g. after it loads)
}

return GameConfig
