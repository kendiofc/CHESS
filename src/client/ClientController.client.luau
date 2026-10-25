--!strict
-- ClientController: connects the puzzle HUD to the server. The client only
-- sends intents; the server's snapshot is always what gets rendered.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local PuzzleHUD = require(script.Parent:WaitForChild("UI"):WaitForChild("PuzzleHUD"))

local ACTIONS = GameConfig.ACTIONS
local remotes = ReplicatedStorage:WaitForChild(GameConfig.REMOTES.Folder)
local actionRemote = remotes:WaitForChild(GameConfig.REMOTES.Action) :: RemoteEvent
local stateRemote = remotes:WaitForChild(GameConfig.REMOTES.State) :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- The game is played entirely in the GUI for now, so hide the mobile
-- thumbstick/jump buttons (they sat on top of Undo/Restart) and stop the
-- hidden avatar from walking around on keyboard input.
GuiService.TouchControlsEnabled = false
task.spawn(function()
	local ok, playerModule = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript) :: any
	end)
	if ok and playerModule then
		playerModule:GetControls():Disable()
	end
end)

local hud = PuzzleHUD.new(playerGui, {
	move = function(from: number, to: number)
		actionRemote:FireServer(ACTIONS.Move, { from = from, to = to })
	end,
	undo = function()
		actionRemote:FireServer(ACTIONS.Undo)
	end,
	restart = function()
		actionRemote:FireServer(ACTIONS.Restart)
	end,
	start = function(puzzleId: string)
		actionRemote:FireServer(ACTIONS.Start, { puzzleId = puzzleId })
	end,
})

stateRemote.OnClientEvent:Connect(function(snapshot)
	hud:render(snapshot)
end)

actionRemote:FireServer(ACTIONS.Sync)
