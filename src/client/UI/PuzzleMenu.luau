--!strict
-- PuzzleMenu: the puzzle select screen. Three tabs:
--   Journey   difficulties unlock in order; locked rows say what unlocks them
--   Practice  every puzzle, any difficulty, free hints, no rewards
--   Daily     today's puzzle, with its one free hint
-- It only draws what the server reported (snapshot.progress) and sends start
-- requests; the server checks locks again before starting anything.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PuzzleDefinitions = require(Shared:WaitForChild("PuzzleDefinitions"))

local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local PLAY_MODES = GameConfig.PLAY_MODES
local TABS = { PLAY_MODES.Journey, PLAY_MODES.Practice, PLAY_MODES.Daily }

local PuzzleMenu = {}
PuzzleMenu.__index = PuzzleMenu

local function make(className: string, props: { [string]: any }?, children: { Instance }?): any
	local instance = Instance.new(className)
	for key, value in pairs(props or {}) do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = instance
	end
	if props and props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local function corner(radius: number): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function text(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		FontFace = Theme.Font,
		TextColor3 = Theme.Text,
		TextSize = 16,
		Text = "",
	}
	for key, value in pairs(props) do
		defaults[key] = value
	end
	return make("TextLabel", defaults)
end

-- start(puzzleId, mode) is called when the player picks a puzzle.
function PuzzleMenu.new(playerGui: Instance, start: (string, string) -> ())
	local self = setmetatable({}, PuzzleMenu) :: any
	self.start = start
	self.tab = PLAY_MODES.Journey
	self.progress = nil
	self.currentId = nil

	local gui = make("ScreenGui", {
		Name = "EchoChessMenu",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 3,
		Enabled = false,
		Parent = playerGui,
	})
	self.gui = gui
	local dim = make("TextButton", {
		Name = "Dim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		AutoButtonColor = false,
		Text = "",
		Parent = gui,
	})
	dim.Activated:Connect(function()
		self:close()
	end)
	local panel = make("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -24, 1, -24),
		BackgroundColor3 = Theme.Panel,
		Parent = gui,
	}, {
		corner(16),
		make("UIStroke", { Color = Theme.Stroke, Thickness = 1.5 }),
		make("UISizeConstraint", { MaxSize = Vector2.new(560, 720) }),
	})
	self.panel = panel
	self.scale = make("UIScale", { Parent = panel })

	-- Title row: wallet and close button.
	text({
		Text = "PUZZLES",
		FontFace = Theme.FontHeavy,
		TextSize = 20,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 14),
		Size = UDim2.new(1, -80, 0, 26),
		Parent = panel,
	})
	self.wallet = text({
		Name = "Wallet",
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 40),
		Size = UDim2.new(1, -80, 0, 18),
		Parent = panel,
	})
	local close = make("TextButton", {
		Name = "CloseButton",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(44, 40),
		BackgroundColor3 = Theme.PanelRaised,
		FontFace = Theme.FontBold,
		Text = "X",
		TextColor3 = Theme.Text,
		TextSize = 18,
		Parent = panel,
	}, { corner(10) })
	close.Activated:Connect(function()
		self:close()
	end)

	-- Tabs.
	local tabs = make("Frame", {
		Position = UDim2.fromOffset(12, 66),
		Size = UDim2.new(1, -24, 0, 40),
		BackgroundTransparency = 1,
		Parent = panel,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
	})
	self.tabButtons = {}
	for order, mode in ipairs(TABS) do
		local tab = make("TextButton", {
			Name = mode .. "Tab",
			LayoutOrder = order,
			Size = UDim2.new(1 / 3, -6, 1, 0),
			BackgroundColor3 = Theme.PanelRaised,
			FontFace = Theme.FontBold,
			Text = mode,
			TextColor3 = Theme.Text,
			TextSize = 16,
			Parent = tabs,
		}, { corner(10) })
		tab.Activated:Connect(function()
			self.tab = mode
			self:_render()
		end)
		self.tabButtons[mode] = tab
	end

	self.note = text({
		Name = "Note",
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 112),
		Size = UDim2.new(1, -36, 0, 34),
		Parent = panel,
	})
	self.list = make("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(12, 150),
		Size = UDim2.new(1, -24, 1, -162),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = panel,
	}, {
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10) }),
	})
	return self
end

function PuzzleMenu.open(self: any, mode: string?)
	if mode and table.find(TABS, mode) then
		self.tab = mode
	end
	self.gui.Enabled = true
	self:_render()
	self.scale.Scale = 0.92
	Anim.tween(self.scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

function PuzzleMenu.close(self: any)
	self.gui.Enabled = false
end

function PuzzleMenu.isOpen(self: any): boolean
	return self.gui.Enabled
end

-- Called with every snapshot so the menu always shows current progress.
function PuzzleMenu.update(self: any, snap: any)
	self.progress = snap.progress
	self.currentId = snap.puzzleId
	self.saveStatus = snap.saveStatus
	if self.gui.Enabled then
		self:_render()
	end
end

local function difficultyRow(self: any, order: number, difficulty: string, index: number)
	local progress = self.progress or { unlockedIndex = 1, completed = {}, unlockRequirement = 4 }
	local journey = self.tab == PLAY_MODES.Journey
	local locked = journey and index > progress.unlockedIndex
	local puzzles = PuzzleDefinitions.byDifficulty[difficulty]
	local done = 0
	for _, puzzle in ipairs(puzzles) do
		if progress.completed[puzzle.id] then
			done += 1
		end
	end
	local row = make("Frame", {
		Name = difficulty,
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, 96),
		BackgroundColor3 = Theme.PanelRaised,
		BackgroundTransparency = if locked then 0.5 else 0,
		Parent = self.list,
	}, { corner(12) })
	text({
		Text = string.upper(difficulty),
		FontFace = Theme.FontBold,
		TextSize = 14,
		TextColor3 = Theme.DifficultyColors[difficulty] or Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(0.5, 0, 0, 18),
		Parent = row,
	})
	local previous = GameConfig.DIFFICULTIES[index - 1]
	text({
		Text = if locked and previous
			then string.format("Locked: clear %d %s puzzles", progress.unlockRequirement, previous)
			else string.format("%d / %d cleared", done, #puzzles),
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.new(0.6, 0, 0, 18),
		Parent = row,
	})
	local grid = make("Frame", {
		Position = UDim2.fromOffset(10, 34),
		Size = UDim2.new(1, -20, 0, 52),
		BackgroundTransparency = 1,
		Parent = row,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
	})
	for number, puzzle in ipairs(puzzles) do
		local cleared = progress.completed[puzzle.id] ~= nil
		local current = puzzle.id == self.currentId
		local cell = make("TextButton", {
			Name = puzzle.id,
			LayoutOrder = number,
			Size = UDim2.new(1 / 6, -5, 1, 0),
			BackgroundColor3 = if cleared then Theme.Legal elseif current then Theme.Accent else Theme.Panel,
			BackgroundTransparency = if locked then 0.6 else 0,
			AutoButtonColor = not locked,
			FontFace = Theme.FontBold,
			Text = tostring(number),
			TextColor3 = if cleared then Theme.Background else Theme.Text,
			TextTransparency = if locked then 0.6 else 0,
			TextSize = 18,
			Parent = grid,
		}, { corner(10) })
		if current then
			make("UIStroke", { Color = Theme.Selected, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = cell })
		end
		cell.Activated:Connect(function()
			if locked then
				Anim.shake(row)
				return
			end
			self:close()
			self.start(puzzle.id, self.tab)
		end)
	end
end

local function dailyCard(self: any)
	local daily = self.progress and self.progress.daily
	local puzzle = daily and PuzzleDefinitions.get(daily.puzzleId)
	local card = make("Frame", {
		Name = "DailyCard",
		Size = UDim2.new(1, -8, 0, 170),
		BackgroundColor3 = Theme.PanelRaised,
		Parent = self.list,
	}, { corner(12) })
	if not puzzle then
		text({ Text = "Loading today's puzzle...", Size = UDim2.fromScale(1, 1), Parent = card })
		return
	end
	text({
		Text = "TODAY'S PUZZLE",
		FontFace = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = card,
	})
	text({
		Text = puzzle.name,
		FontFace = Theme.FontBold,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 32),
		Size = UDim2.new(1, -28, 0, 30),
		Parent = card,
	})
	local status = if daily.completed then "Cleared today. Come back tomorrow for a new one." else "Not cleared yet."
	text({
		Text = string.format(
			"%s  ·  %s\n%s",
			puzzle.difficulty,
			if daily.hintUsed then "hint used" else "1 free hint",
			status
		),
		TextSize = 14,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Position = UDim2.fromOffset(14, 66),
		Size = UDim2.new(1, -28, 0, 40),
		Parent = card,
	})
	local play = make("TextButton", {
		Name = "PlayDaily",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -12),
		Size = UDim2.new(1, -28, 0, 44),
		BackgroundColor3 = Theme.Accent,
		FontFace = Theme.FontBold,
		Text = if daily.completed then "Play again" else "Play",
		TextColor3 = Theme.Text,
		TextSize = 18,
		Parent = card,
	}, { corner(12) })
	play.Activated:Connect(function()
		self:close()
		self.start(puzzle.id, PLAY_MODES.Daily)
	end)
end

local NOTES = {
	Journey = "Clear %d puzzles of a difficulty to unlock the next. First clears earn XP and coins.",
	Practice = "Play any puzzle at any difficulty. Hints are free. Practice earns no rewards and doesn't unlock difficulties.",
	Daily = "A new puzzle every day (UTC). You get one free hint per day, and the reward once per day.",
}

function PuzzleMenu._render(self: any)
	for mode, tab in pairs(self.tabButtons) do
		local active = mode == self.tab
		tab.BackgroundColor3 = if active then Theme.Accent else Theme.PanelRaised
	end
	local progress = self.progress
	local wallet = if progress then string.format("%d XP  ·  %d coins", progress.xp, progress.coins) else "Loading progress..."
	if self.saveStatus == "offline" then
		wallet ..= "  ·  progress can't be saved right now"
	end
	self.wallet.Text = wallet
	self.note.Text = string.format(NOTES[self.tab], if progress then progress.unlockRequirement else 4)
	for _, child in ipairs(self.list:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	if self.tab == PLAY_MODES.Daily then
		dailyCard(self)
	else
		for index, difficulty in ipairs(GameConfig.DIFFICULTIES) do
			difficultyRow(self, index, difficulty, index)
		end
	end
end

return PuzzleMenu
