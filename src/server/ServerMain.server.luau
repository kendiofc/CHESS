--!strict
-- ServerMain: boots server services in dependency order.

local PuzzleService = require(script.Parent:WaitForChild("Services"):WaitForChild("PuzzleService"))

PuzzleService.Start()
