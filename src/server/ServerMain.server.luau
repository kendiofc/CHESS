--!strict
-- ServerMain: boots server services in dependency order.

local Players = game:GetService("Players")

local PuzzleService = require(script.Parent:WaitForChild("Services"):WaitForChild("PuzzleService"))

PuzzleService.Start()

-- Until the lobby exists the game is GUI-only: keep avatars still so keyboard
-- input meant for the board doesn't walk an invisible character around.
local function freeze(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(freeze)
	if player.Character then
		freeze(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end
