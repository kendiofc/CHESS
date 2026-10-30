--!strict
-- ClientController: connects the puzzle HUD to the server. The client only
-- sends intents; the server's snapshot is always what gets rendered.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Lang = require(script.Parent:WaitForChild("UI"):WaitForChild("Lang"))
local PuzzleHUD = require(script.Parent:WaitForChild("UI"):WaitForChild("PuzzleHUD"))

local ACTIONS = GameConfig.ACTIONS
local remotes = ReplicatedStorage:WaitForChild(GameConfig.REMOTES.Folder)
local actionRemote = remotes:WaitForChild(GameConfig.REMOTES.Action) :: RemoteEvent
local stateRemote = remotes:WaitForChild(GameConfig.REMOTES.State) :: RemoteEvent
local leaderboardRemote = remotes:WaitForChild(GameConfig.REMOTES.Leaderboard) :: RemoteEvent

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

-- Every screen of the game is shown in the player's language (see Lang).
-- Until their saved choice arrives, that is their Roblox language if the
-- game has it.
Lang.set(Lang.suggested())
local function watchScreen(child: Instance)
	if child:IsA("ScreenGui") and string.sub(child.Name, 1, 9) == "EchoChess" then
		Lang.watch(child)
	end
end
for _, child in ipairs(playerGui:GetChildren()) do
	watchScreen(child)
end
playerGui.ChildAdded:Connect(watchScreen)

-- The game is played entirely in the GUI for now, so hide the mobile
-- thumbstick/jump buttons; they sat on top of Undo/Restart. (ServerMain keeps
-- the hidden avatar from moving.)
GuiService.TouchControlsEnabled = false

-- Settings changes are batched so tapping volume +/- quickly sends one request.
local pendingSettings: { [string]: any }? = nil
local function sendSettings(values: { [string]: any })
	local first = pendingSettings == nil
	pendingSettings = pendingSettings or {}
	for key, value in pairs(values) do
		(pendingSettings :: any)[key] = value
	end
	if first then
		task.delay(0.6, function()
			local batch = pendingSettings
			pendingSettings = nil
			actionRemote:FireServer(ACTIONS.Settings, batch)
		end)
	end
end

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
	hint = function()
		actionRemote:FireServer(ACTIONS.Hint)
	end,
	start = function(puzzleId: string, mode: string)
		actionRemote:FireServer(ACTIONS.Start, { puzzleId = puzzleId, mode = mode })
	end,
	settings = sendSettings,
	tutorial = function(outcome: string)
		actionRemote:FireServer(ACTIONS.Tutorial, { outcome = outcome })
	end,
	sync = function()
		actionRemote:FireServer(ACTIONS.Sync)
	end,
	duelJoin = function()
		actionRemote:FireServer(ACTIONS.DuelJoin)
	end,
	duelCancel = function()
		actionRemote:FireServer(ACTIONS.DuelCancel)
	end,
	duelLeave = function()
		actionRemote:FireServer(ACTIONS.DuelLeave)
	end,
	duelExit = function()
		actionRemote:FireServer(ACTIONS.DuelExit)
	end,
	-- The server checks the item, its price and the player's coins or passes.
	shopBuy = function(slot: string, item: string)
		actionRemote:FireServer(ACTIONS.ShopBuy, { slot = slot, item = item })
	end,
	shopEquip = function(slot: string, item: string)
		actionRemote:FireServer(ACTIONS.ShopEquip, { slot = slot, item = item })
	end,
	leaderboard = function(board: string)
		actionRemote:FireServer(ACTIONS.Leaderboard, { board = board })
	end,
})

stateRemote.OnClientEvent:Connect(function(snapshot)
	hud:render(snapshot)
end)

leaderboardRemote.OnClientEvent:Connect(function(view)
	hud.menu:updateLeaderboard(view)
end)

actionRemote:FireServer(ACTIONS.Sync)
