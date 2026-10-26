--!strict
-- PlayDesk: the puzzle screen's desktop dress. On a large screen the HUD
-- puts a sidebar on the left, the player's level and coins along the top, a
-- title and stats strip above the board, and cards for the puzzle goal, the
-- Daily streak and the Weekly Challenge on the right. Phones keep the HUD's
-- own compact layout, and this module stays hidden there.
--
-- It only draws. The HUD places the board, tutorial card, message and
-- buttons in the rectangles layout() returns, and passes snapshots to
-- render(). Sidebar presses and card taps go back through `actions`.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))
local PuzzleDefinitions = require(Shared:WaitForChild("PuzzleDefinitions"))

local Decor = require(script.Parent:WaitForChild("Decor"))
local HomeDashboard = require(script.Parent:WaitForChild("HomeDashboard"))
local MenuSidebar = require(script.Parent:WaitForChild("MenuSidebar"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local PLAY_MODES = GameConfig.PLAY_MODES
local DUEL_MODE = GameConfig.DUEL_MODE

local PlayDesk = {}
PlayDesk.__index = PlayDesk

-- The desk layout needs this much screen; smaller screens use the HUD's own.
PlayDesk.MIN_WIDTH = 1000
PlayDesk.MIN_HEIGHT = 640

local NAV_ITEMS: { MenuSidebar.Item } = {
	{ id = "Home", icon = "🏠", label = "Home" },
	{ id = "Journey", icon = "🏔", label = "Journey" },
	{ id = "Daily", icon = "📅", label = "Daily Puzzle" },
	{ id = "Weekly", icon = "🏆", label = "Weekly Challenge" },
	{ id = "Endless", icon = "🌀", label = "Endless" },
	{ id = "Duel", icon = "⚔️", label = "Puzzle Duel" },
	{ id = "Practice", icon = "🧩", label = "Practice" },
	{ id = "Stats", icon = "📊", label = "Statistics" },
	{ id = "Tutorial", icon = "🎓", label = "How to Play" },
	{ id = "Settings", icon = "⚙️", label = "Settings", footer = true },
	{ id = "Collapse", icon = "<", label = "Collapse", footer = true },
}

local PAD = 24
local TOP_H = 60
local TITLE_H = 50
local STATS_H = 60
local DOTS_H = 30
local CONTROLS_H = 58
local COACH_H = 92
local MESSAGE_H = 40
local GAP = 14

local GOAL_H = 178
local STREAK_H = 158
local WEEKLY_H = 138

export type Actions = {
	nav: (id: string) -> (),
	switch: (offset: number) -> (),
	openView: (view: string) -> (),
}

export type Rects = { board: Rect, coach: Rect, message: Rect, controls: Rect }
export type Rect = { x: number, y: number, w: number, h: number }

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

local function stroke(color: Color3, thickness: number, transparency: number?): UIStroke
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function text(props: { [string]: any }): TextLabel
	local defaults = {
		BackgroundTransparency = 1,
		FontFace = Theme.Font,
		TextColor3 = Theme.Text,
		TextSize = 14,
	}
	for key, value in pairs(props) do
		defaults[key] = value
	end
	return make("TextLabel", defaults)
end

local function place(frame: GuiObject, x: number, y: number, w: number, h: number)
	frame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	frame.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
end

-- A dark rounded card with a coloured edge.
local function card(name: string, parent: Instance, edge: Color3): Frame
	local frame = make("TextButton", {
		Name = name,
		BackgroundColor3 = Color3.fromRGB(26, 22, 50),
		BackgroundTransparency = 0.05,
		AutoButtonColor = false,
		Text = "",
		Parent = parent,
	}, { corner(16), stroke(edge, 2, 0.1) })
	make("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(44, 34, 78), Color3.fromRGB(22, 20, 44)),
		Rotation = 90,
		Parent = frame,
	})
	return frame
end

local function cardHeading(parent: Instance, icon: string, title: string, color: Color3): TextLabel
	text({
		Name = "Icon",
		Position = UDim2.fromOffset(18, 14),
		Size = UDim2.fromOffset(30, 30),
		FontFace = Theme.FontBold,
		Text = icon,
		TextSize = 24,
		Parent = parent,
	})
	return text({
		Name = "Heading",
		Position = UDim2.fromOffset(58, 14),
		Size = UDim2.new(1, -76, 0, 30),
		FontFace = Theme.FontHeavy,
		Text = title,
		TextColor3 = color,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = parent,
	})
end

local function divider(parent: Instance, y: number)
	make("Frame", {
		Name = "Divider",
		Position = UDim2.fromOffset(18, y),
		Size = UDim2.new(1, -36, 0, 1),
		BackgroundColor3 = Theme.Gold,
		BackgroundTransparency = 0.75,
		BorderSizePixel = 0,
		Parent = parent,
	})
end

local function bar(parent: Instance, name: string, colors: { Color3 }): (Frame, Frame)
	local track = make("Frame", {
		Name = name,
		BackgroundColor3 = Color3.fromRGB(56, 52, 90),
		BorderSizePixel = 0,
		Parent = parent,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = track,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		make("UIGradient", { Color = ColorSequence.new(colors[1], colors[2]) }),
	})
	return track, fill
end

function PlayDesk.new(playerGui: Instance, container: Instance, actions: Actions)
	local self = setmetatable({}, PlayDesk) :: any
	self.actions = actions
	self.visible = false
	self.expanded = nil -- the sidebar's state; nil until the first layout picks one

	-- The sidebar runs to the top of the screen, under Roblox's own buttons.
	self.navGui = make("ScreenGui", {
		Name = "EchoChessPlayNav",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 1,
		Enabled = false,
		Parent = playerGui,
	})
	self.sidebar = MenuSidebar.new(self.navGui, NAV_ITEMS, function(id: string)
		actions.nav(id)
	end)

	local root = make("Frame", {
		Name = "Desk",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = container,
	})
	self.root = root
	self:_buildTopBar(root)
	self:_buildTitle(root)
	self:_buildStats(root)
	self:_buildDots(root)
	self:_buildCards(root)

	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(
				Players.LocalPlayer.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size150x150
			)
		end)
		if ok and image then
			self.avatar.Image = image
		end
	end)
	return self
end

-- Top bar: avatar, name, level and XP, coins ---------------------------------------------

function PlayDesk._buildTopBar(self: any, root: Frame)
	local top = make("Frame", { Name = "TopBar", BackgroundTransparency = 1, Parent = root })
	self.top = top
	self.avatar = make("ImageLabel", {
		Name = "Avatar",
		Position = UDim2.fromOffset(0, 2),
		Size = UDim2.fromOffset(54, 54),
		BackgroundColor3 = Theme.PanelRaised,
		Parent = top,
	}, { corner(12), stroke(Theme.Stroke, 1.5, 0.1) })
	local player = Players.LocalPlayer
	self.nameLabel = text({
		Name = "PlayerName",
		Position = UDim2.fromOffset(70, 0),
		Size = UDim2.fromOffset(220, 58),
		FontFace = Theme.FontHeavy,
		Text = if player.DisplayName ~= "" then player.DisplayName else player.Name,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = top,
	})
	make("UITextSizeConstraint", { MaxTextSize = 24, MinTextSize = 12, Parent = self.nameLabel })

	local xp = make("Frame", { Name = "XP", BackgroundTransparency = 1, Parent = top })
	self.xp = xp
	self.levelPill = text({
		Name = "Level",
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.fromOffset(76, 28),
		BackgroundColor3 = Theme.Accent,
		BackgroundTransparency = 0,
		FontFace = Theme.FontHeavy,
		TextSize = 15,
		Text = "Lv. 1",
		Parent = xp,
	})
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = self.levelPill })
	self.xpAmount = text({
		Name = "Amount",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 4),
		Size = UDim2.new(1, -90, 0, 20),
		FontFace = Theme.FontBold,
		Text = "",
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = xp,
	})
	local track, fill = bar(xp, "Bar", { Color3.fromRGB(150, 110, 255), Theme.Accent })
	track.Position = UDim2.fromOffset(90, 30)
	track.Size = UDim2.new(1, -90, 0, 12)
	self.xpFill = fill

	local coins = make("Frame", {
		Name = "Coins",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(170, 50),
		BackgroundColor3 = Color3.fromRGB(20, 20, 40),
		BackgroundTransparency = 0.1,
		Parent = top,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }), stroke(Theme.Stroke, 1.5, 0.2) })
	local coin = make("Frame", {
		Name = "Coin",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 9, 0.5, 0),
		Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = Color3.new(1, 1, 1),
		Parent = coins,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		make("UIGradient", { Color = ColorSequence.new(Color3.fromRGB(255, 226, 120), Theme.GoldDeep), Rotation = 60 }),
		stroke(Color3.fromRGB(255, 240, 180), 1.5, 0.3),
	})
	make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = coin,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }), stroke(Color3.fromRGB(170, 110, 20), 2, 0.2) })
	self.coinAmount = text({
		Name = "Amount",
		Position = UDim2.fromOffset(54, 0),
		Size = UDim2.new(1, -66, 1, 0),
		FontFace = Theme.FontHeavy,
		Text = "...",
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = coins,
	})
	-- Rewards still show while saving is off, but nothing claims they're stored.
	self.saveNote = text({
		Name = "SaveStatus",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 52),
		Size = UDim2.fromOffset(220, 14),
		Text = "Not saving right now",
		TextColor3 = Theme.Danger:Lerp(Theme.Text, 0.3),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = top,
	})
end

-- Title: mode, puzzle name between gold rules, difficulty ------------------------------

function PlayDesk._buildTitle(self: any, root: Frame)
	local row = make("Frame", { Name = "TitleRow", BackgroundTransparency = 1, Parent = root })
	self.titleRow = row
	self.modeLabel = text({
		Name = "Mode",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(1, 0, 0, 14),
		FontFace = Theme.FontHeavy,
		TextSize = 12,
		TextColor3 = Theme.Gold,
		Parent = row,
	})
	self.title = text({
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.new(0, 0, 0, 38),
		AutomaticSize = Enum.AutomaticSize.X,
		FontFace = Theme.FontHeavy,
		TextSize = 34,
		Parent = row,
	})
	-- Gold rules with a diamond, either side of the name.
	local function rule(side: number): Frame
		local holder = make("Frame", {
			Name = if side < 0 then "RuleLeft" else "RuleRight",
			AnchorPoint = Vector2.new(if side < 0 then 1 else 0, 0.5),
			Size = UDim2.fromOffset(110, 10),
			BackgroundTransparency = 1,
			Parent = row,
		})
		make("Frame", {
			Name = "Line",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = if side < 0 then UDim2.fromScale(0, 0.5) else UDim2.new(0, 8, 0.5, 0),
			Size = UDim2.new(1, -8, 0, 2),
			BackgroundColor3 = Theme.Gold,
			BorderSizePixel = 0,
			Parent = holder,
		}, {
			make("UIGradient", {
				Transparency = if side < 0 then NumberSequence.new(1, 0) else NumberSequence.new(0, 1),
			}),
		})
		make("Frame", {
			Name = "Diamond",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = if side < 0 then UDim2.new(1, -4, 0.5, 0) else UDim2.new(0, 4, 0.5, 0),
			Size = UDim2.fromOffset(8, 8),
			Rotation = 45,
			BackgroundColor3 = Theme.Gold,
			BorderSizePixel = 0,
			Parent = holder,
		})
		return holder
	end
	self.ruleLeft = rule(-1)
	self.ruleRight = rule(1)
	self.pill = text({
		Name = "Difficulty",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(150, 30),
		BackgroundColor3 = Theme.Legal,
		BackgroundTransparency = 0,
		FontFace = Theme.FontHeavy,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(16, 30, 20),
		Parent = row,
	})
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = self.pill })
	self.title:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_placeRules()
	end)
end

function PlayDesk._placeRules(self: any)
	local half = self.title.AbsoluteSize.X / 2 + 16
	local mid = self.titleMid or 31
	self.ruleLeft.Position = UDim2.new(0.5, -half, 0, mid)
	self.ruleRight.Position = UDim2.new(0.5, half, 0, mid)
	-- The difficulty sits just past the right rule, or at the row's edge
	-- when a long name leaves no room.
	local rowW = self.titleRow.AbsoluteSize.X
	local x = math.min(rowW / 2 + half + 110 + 24 + 75, rowW - 75)
	self.pill.Position = UDim2.fromOffset(x, mid)
end

-- Stats strip: moves, captured, time, par ----------------------------------------------

function PlayDesk._buildStats(self: any, root: Frame)
	local strip = make("Frame", {
		Name = "StatsStrip",
		BackgroundColor3 = Color3.fromRGB(22, 20, 44),
		BackgroundTransparency = 0.1,
		Parent = root,
	}, { corner(14), stroke(Theme.Stroke, 1.5, 0.1) })
	self.strip = strip
	local cells = {}
	for i, heading in ipairs({ "MOVES", "CAPTURED", "TIME", "PAR" }) do
		local cell = make("Frame", {
			Name = heading,
			Position = UDim2.fromScale((i - 1) / 4, 0),
			Size = UDim2.fromScale(1 / 4, 1),
			BackgroundTransparency = 1,
			Parent = strip,
		})
		if i > 1 then
			make("Frame", {
				Name = "Divider",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(0, 1, 0.56, 0),
				BackgroundColor3 = Theme.Stroke,
				BorderSizePixel = 0,
				Parent = cell,
			})
		end
		local head = text({
			Name = "Heading",
			Position = UDim2.fromOffset(0, 8),
			Size = UDim2.new(1, 0, 0, 14),
			FontFace = Theme.FontBold,
			Text = heading,
			TextColor3 = Theme.TextMuted,
			TextSize = 12,
			Parent = cell,
		})
		local value = text({
			Name = "Value",
			Position = UDim2.fromOffset(0, 24),
			Size = UDim2.new(1, 0, 0, 30),
			FontFace = Theme.FontHeavy,
			TextSize = 24,
			Parent = cell,
		})
		cells[heading] = { head = head, value = value }
	end
	self.cells = cells
end

-- Progress dots: where this puzzle sits in its difficulty, with < and > ----------------

function PlayDesk._buildDots(self: any, root: Frame)
	local row = make("Frame", { Name = "Dots", BackgroundTransparency = 1, Parent = root })
	self.dotsRow = row
	local function arrow(name: string, glyph: string, offset: number): TextButton
		local button = make("TextButton", {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = Theme.PanelRaised,
			BackgroundTransparency = 0.2,
			FontFace = Theme.FontHeavy,
			Text = glyph,
			TextColor3 = Theme.Text,
			TextSize = 16,
			Parent = row,
		}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
		button.Activated:Connect(function()
			self.actions.switch(offset)
		end)
		return button
	end
	self.prevArrow = arrow("PrevPuzzle", "<", -1)
	self.nextArrow = arrow("NextPuzzle", ">", 1)
	self.dotLine = make("Frame", {
		Name = "Line",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Theme.Stroke,
		BorderSizePixel = 0,
		Parent = row,
	})
	self.dots = {}
end

function PlayDesk._renderDots(self: any, snap: any)
	local group = PuzzleDefinitions.byDifficulty[snap.difficulty]
	local fixed = snap.mode == PLAY_MODES.Daily
		or snap.mode == PLAY_MODES.Weekly
		or snap.mode == PLAY_MODES.Endless
		or snap.mode == DUEL_MODE
	self.dotsRow.Visible = group ~= nil and not fixed
	if not self.dotsRow.Visible then
		return
	end
	local count = #group
	local spacing = 64
	local width = (count - 1) * spacing
	self.dotLine.Size = UDim2.fromOffset(width, 2)
	self.prevArrow.Position = UDim2.new(0.5, -width / 2 - 44, 0.5, 0)
	self.nextArrow.Position = UDim2.new(0.5, width / 2 + 44, 0.5, 0)
	for _, dot in ipairs(self.dots) do
		dot:Destroy()
	end
	self.dots = {}
	local completed = snap.progress and snap.progress.completed or {}
	for i, puzzle in ipairs(group) do
		local current = puzzle.id == snap.puzzleId
		local cleared = completed[puzzle.id] ~= nil
		local size = if current then 18 else 14
		local dot = make("Frame", {
			Name = "Dot" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, -width / 2 + (i - 1) * spacing, 0.5, 0),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = if current then Theme.Gold elseif cleared then Theme.Legal else Color3.fromRGB(30, 28, 56),
			Parent = self.dotsRow,
		}, {
			make("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			stroke(if current then Color3.fromRGB(255, 236, 160) else Theme.TextMuted, if current then 2 else 1.5, if current then 0 else 0.3),
		})
		table.insert(self.dots, dot)
	end
end

-- Right column: puzzle goal, Daily streak, Weekly Challenge ------------------------------

function PlayDesk._buildCards(self: any, root: Frame)
	local column = make("Frame", { Name = "SideCards", BackgroundTransparency = 1, Parent = root })
	self.column = column

	local goal = card("GoalCard", column, Theme.Gold)
	goal.Size = UDim2.new(1, 0, 0, GOAL_H)
	cardHeading(goal, "🎯", "PUZZLE GOAL", Theme.Gold)
	divider(goal, 58)
	if Theme.PieceSheet ~= "" then
		make("ImageLabel", {
			Name = "Rook",
			Position = UDim2.fromOffset(22, 72),
			Size = UDim2.fromOffset(34, 34),
			BackgroundTransparency = 1,
			Image = Theme.PieceSheet,
			ImageRectSize = Vector2.new(Theme.PieceCell, Theme.PieceCell),
			ImageRectOffset = Vector2.new(Theme.PieceSheetColumns.R * Theme.PieceCell, 0),
			ScaleType = Enum.ScaleType.Fit,
			Parent = goal,
		})
	end
	self.goalCapture = text({
		Name = "Capture",
		Position = UDim2.fromOffset(70, 72),
		Size = UDim2.new(1, -84, 0, 34),
		RichText = true,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = goal,
	})
	divider(goal, 118)
	text({
		Name = "Flag",
		Position = UDim2.fromOffset(22, 130),
		Size = UDim2.fromOffset(34, 34),
		FontFace = Theme.FontBold,
		Text = "🚩",
		TextSize = 24,
		Parent = goal,
	})
	self.goalPar = text({
		Name = "Par",
		Position = UDim2.fromOffset(70, 130),
		Size = UDim2.new(1, -84, 0, 34),
		RichText = true,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = goal,
	})
	self.goal = goal

	local streak = card("StreakCard", column, Theme.Accent)
	streak.Size = UDim2.new(1, 0, 0, STREAK_H)
	cardHeading(streak, "🔥", "DAILY STREAK", Theme.Gold)
	self.streakDays = text({
		Name = "Days",
		Position = UDim2.fromOffset(20, 50),
		Size = UDim2.new(1, -100, 0, 40),
		FontFace = Theme.FontHeavy,
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = streak,
	})
	local calendar = text({
		Name = "Calendar",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 26),
		Size = UDim2.fromOffset(56, 56),
		BackgroundColor3 = Theme.PanelRaised,
		BackgroundTransparency = 0.1,
		FontFace = Theme.FontBold,
		Text = "📅",
		TextSize = 28,
		Parent = streak,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 12), Parent = calendar })
	make("UIStroke", { Color = Theme.Stroke, Thickness = 1.5, Parent = calendar })
	self.streakBoxes = make("Frame", {
		Name = "Week",
		Position = UDim2.fromOffset(20, 104),
		Size = UDim2.new(1, -40, 0, 34),
		BackgroundTransparency = 1,
		Parent = streak,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
		make("UISizeConstraint", { MaxSize = Vector2.new(7 * 34 + 6 * 6, 34) }),
	})
	streak.Activated:Connect(function()
		self.actions.openView("Daily")
	end)
	self.streak = streak

	local weekly = card("WeeklyCard", column, Theme.Accent)
	weekly.Size = UDim2.new(1, 0, 0, WEEKLY_H)
	cardHeading(weekly, "🏆", "WEEKLY CHALLENGE", Theme.Gold)
	self.weeklyCount = text({
		Name = "Count",
		Position = UDim2.fromOffset(20, 50),
		Size = UDim2.new(1, -80, 0, 40),
		FontFace = Theme.FontHeavy,
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = weekly,
	})
	text({
		Name = "Chevron",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 6),
		Size = UDim2.fromOffset(30, 40),
		FontFace = Theme.FontBold,
		Text = ">",
		TextColor3 = Theme.TextMuted,
		TextSize = 26,
		Parent = weekly,
	})
	local track, fill = bar(weekly, "Bar", { Color3.fromRGB(150, 110, 255), Theme.Accent })
	track.Position = UDim2.fromOffset(20, 100)
	track.Size = UDim2.new(1, -80, 0, 14)
	self.weeklyFill = fill
	weekly.Activated:Connect(function()
		self.actions.openView("Weekly")
	end)
	self.weekly = weekly
end

local BOX_STYLES = {
	done = { bg = Color3.fromRGB(46, 170, 90), edge = Color3.fromRGB(120, 230, 150), glyph = "✓" },
	shield = { bg = Color3.fromRGB(70, 110, 190), edge = Color3.fromRGB(150, 190, 255), glyph = "🛡" },
	today = { bg = Color3.fromRGB(30, 28, 56), edge = Theme.Gold, glyph = "" },
	none = { bg = Color3.fromRGB(30, 28, 56), edge = Theme.Stroke, glyph = "" },
}

function PlayDesk._renderStreak(self: any, progress: any)
	for _, child in ipairs(self.streakBoxes:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local days = HomeDashboard.streakDays(progress and progress.streak, progress and progress.daily and progress.daily.day or 0)
	for i, state in ipairs(days) do
		local style = BOX_STYLES[state] or BOX_STYLES.none
		local box = text({
			Name = "Day" .. i,
			LayoutOrder = i,
			-- Seven boxes share the card's width, at most 34 px each.
			Size = UDim2.new(1 / 7, -6, 1, 0),
			BackgroundColor3 = style.bg,
			BackgroundTransparency = 0,
			FontFace = Theme.FontHeavy,
			Text = style.glyph,
			TextSize = 16,
			Parent = self.streakBoxes,
		})
		make("UICorner", { CornerRadius = UDim.new(0, 7), Parent = box })
		make("UIStroke", { Color = style.edge, Thickness = 1.5, Parent = box })
	end
	local current = if progress and progress.streak then progress.streak.current else 0
	self.streakDays.Text = if progress == nil
		then "..."
		else string.format("%d day streak", current)
end

-- Board frame: a gold rim with a glow, and the coordinates outside the squares --------

-- Adds the desk rim to the HUD's board frame. It sits under the wooden rim
-- the board already has, and only shows in the desk layout.
function PlayDesk.attachBoard(self: any, board: GuiObject)
	local rim = make("Frame", {
		Name = "DeskRim",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, -6, 0.5, 6),
		Size = UDim2.new(1, 60, 1, 60),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 0,
		Parent = board,
	}, { corner(18) })
	make("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(240, 196, 100)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(176, 120, 48)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(226, 172, 76)),
		}),
		Rotation = 45,
		Parent = rim,
	})
	make("UIStroke", { Color = Color3.fromRGB(255, 214, 120), Thickness = 3, Transparency = 0.15, Parent = rim })
	-- A soft halo around it (a sibling drawn first, so it stays behind).
	self.halo = make("Frame", {
		Name = "DeskHalo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, -6, 0.5, 6),
		Size = UDim2.new(1, 84, 1, 84),
		BackgroundColor3 = Theme.Gold,
		BackgroundTransparency = 0.86,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = -1,
		Parent = board,
	}, { corner(30) })
	local inner = make("Frame", {
		Name = "Inner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 6, 0.5, -6),
		Size = UDim2.new(1, -40, 1, -40),
		BackgroundColor3 = Color3.fromRGB(60, 38, 22),
		BorderSizePixel = 0,
		ZIndex = 0,
		Parent = rim,
	}, { corner(8) })
	self.rim = rim
	self.rimInner = inner
	self.coords = make("Frame", {
		Name = "Coords",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 5,
		Parent = board,
	})
end

-- Rebuilds the outside coordinates for a board of `width` x `height`.
function PlayDesk.setBoardSize(self: any, width: number, height: number)
	if not self.coords then
		return
	end
	self.coords:ClearAllChildren()
	for row = 1, height do
		text({
			Name = "Rank" .. row,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0, -20, (height - row + 0.5) / height, 0),
			Size = UDim2.fromOffset(20, 20),
			FontFace = Theme.FontHeavy,
			Text = tostring(row),
			TextColor3 = Color3.fromRGB(60, 34, 12),
			TextSize = 15,
			ZIndex = 5,
			Parent = self.coords,
		})
	end
	for col = 1, width do
		text({
			Name = "File" .. col,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new((col - 0.5) / width, 0, 1, 20),
			Size = UDim2.fromOffset(20, 20),
			FontFace = Theme.FontHeavy,
			Text = string.sub("abcdefgh", col, col),
			TextColor3 = Color3.fromRGB(60, 34, 12),
			TextSize = 15,
			ZIndex = 5,
			Parent = self.coords,
		})
	end
end

-- Visibility and layout --------------------------------------------------------------

-- Whether a screen of this size gets the desk layout.
function PlayDesk.fits(size: Vector2): boolean
	return size.X >= PlayDesk.MIN_WIDTH and size.Y >= PlayDesk.MIN_HEIGHT
end

function PlayDesk.setVisible(self: any, visible: boolean)
	self.visible = visible
	self.root.Visible = visible
	self.navGui.Enabled = visible
	if self.rim then
		self.rim.Visible = visible
		self.halo.Visible = visible
		self.coords.Visible = visible
	end
end

-- The sidebar's width for a screen `screenWidth` wide. It starts expanded on
-- wide screens and as a rail of icons otherwise; Collapse toggles it.
function PlayDesk.sidebarWidth(self: any, screenWidth: number, topInset: number): number
	if self.expanded == nil then
		self.expanded = screenWidth >= 1400
	end
	self.sidebar:setTopInset(topInset)
	self.sidebar:setMode(not self.expanded, false)
	self.sidebar:setLabel("Collapse", if self.expanded then "Collapse" else "Expand")
	local collapse = self.sidebar.items.Collapse
	if collapse then
		collapse.icon.Text = if self.expanded then "<" else ">"
	end
	return if self.expanded then MenuSidebar.EXPANDED else MenuSidebar.COLLAPSED
end

function PlayDesk.toggleSidebar(self: any)
	self.expanded = not self.expanded
end

-- Places the desk's own parts in a `w` x `h` area and returns where the HUD
-- should put the board, the tutorial card, the message line and the buttons.
function PlayDesk.layout(self: any, w: number, h: number, coaching: boolean): Rects
	-- A laptop-height screen gets a tighter column so the board stays large.
	local short = h < 860
	local titleH = if short then 38 else TITLE_H
	local statsH = if short then 50 else STATS_H
	local dotsH = if short then 24 else DOTS_H
	local controlsH = if short then 50 else CONTROLS_H
	local messageH = if short then 30 else MESSAGE_H
	local step = if short then 4 else 6
	self.modeLabel.Visible = not short
	self.title.TextSize = if short then 28 else 34
	self.title.Position = UDim2.new(0.5, 0, 0, if short then 2 else 12)
	self.titleMid = if short then 19 else 31
	for _, cell in pairs(self.cells) do
		cell.value.TextSize = if short then 20 else 24
		cell.value.Position = UDim2.fromOffset(0, if short then 20 else 24)
		cell.head.Position = UDim2.fromOffset(0, if short then 5 else 8)
	end
	local sideW = math.clamp(math.floor(w * 0.25), 270, 380)
	local centreW = w - PAD * 3 - sideW
	local cx = PAD

	place(self.top, PAD, 10, w - PAD * 2, TOP_H)
	local nameW = math.clamp(math.floor((w - PAD * 2) * 0.2), 120, 240)
	self.nameLabel.Size = UDim2.fromOffset(nameW, 58)
	local xpX = 70 + nameW + 20
	place(self.xp, xpX, 6, math.min(440, w - PAD * 2 - xpX - 210), 46)

	local y = 10 + TOP_H + step
	place(self.titleRow, cx, y, centreW, titleH)
	self:_placeRules()
	y += titleH + step
	local stripW = math.min(centreW, 680)
	place(self.strip, cx + (centreW - stripW) / 2, y, stripW, statsH)
	y += statsH + step
	local dotsShown = self.dotsRow.Visible
	place(self.dotsRow, cx, y, centreW, dotsH)
	if dotsShown then
		y += dotsH + step
	end

	local bottom = h - (if short then 8 else 12)
	local controls = { x = cx + (centreW - math.min(centreW, 680)) / 2, y = bottom - controlsH, w = math.min(centreW, 680), h = controlsH }
	-- On a short screen the tutorial card and the status line move to the
	-- side column, under the goal card, so the board keeps the height.
	local below = if short then 0 elseif coaching then COACH_H else messageH
	local coachW = math.min(centreW, 840)
	local coach = { x = cx + (centreW - coachW) / 2, y = controls.y - GAP - COACH_H, w = coachW, h = COACH_H }
	local message = { x = cx, y = controls.y - GAP - messageH, w = centreW, h = messageH }
	-- The board leaves room for its rim (24 px above, 36 below) and the
	-- coordinates outside it.
	local boardTop = y + 26
	local boardBottom = controls.y - (if short then 0 else GAP) - below - 40
	local board = { x = cx + 30, y = boardTop, w = centreW - 60, h = math.max(120, boardBottom - boardTop) }

	-- Side cards, top-aligned with the title.
	local sx = w - PAD - sideW
	local colTop = 10 + TOP_H + 26
	local room = h - colTop - 8
	place(self.column, sx, colTop, sideW, room)
	self.goal.Position = UDim2.fromOffset(0, 0)
	local cy = GOAL_H + 18
	if short then
		if coaching then
			coach = { x = sx, y = colTop + cy, w = sideW, h = 150 }
			cy += 150 + 18
		else
			message = { x = sx, y = colTop + cy, w = sideW, h = 60 }
			cy += 60 + 18
		end
	end
	-- The lower cards show only when they fit whole.
	for _, c in ipairs({ self.streak, self.weekly }) do
		local fits = cy + c.Size.Y.Offset <= room
		c.Visible = fits
		if fits then
			c.Position = UDim2.fromOffset(0, cy)
			cy += c.Size.Y.Offset + 18
		end
	end

	return { board = board, coach = coach, message = message, controls = controls }
end

-- Rendering -------------------------------------------------------------------------

function PlayDesk.render(self: any, snap: any, saveStatus: string?)
	local progress = snap.progress
	if progress then
		local level = Progression.levelOf(progress.xp)
		self.levelPill.Text = "Lv. " .. level.level
		self.xpAmount.Text = string.format("%s / %s XP", HomeDashboard.commas(level.into), HomeDashboard.commas(level.needed))
		self.xpFill.Size = UDim2.fromScale(math.clamp(level.into / level.needed, 0, 1), 1)
		self.coinAmount.Text = HomeDashboard.commas(progress.coins)
	end
	self.saveNote.Visible = (saveStatus or snap.saveStatus) == "offline"

	local modeName = if snap.mode == DUEL_MODE then "PUZZLE DUEL" else string.upper(snap.mode or PLAY_MODES.Journey)
	self.modeLabel.Text = "ECHO CHESS  ·  " .. modeName
	self.title.Text = snap.name
	local group = PuzzleDefinitions.byDifficulty[snap.difficulty]
	local run = snap.endless
	self.pill.Text = if run
		then string.upper(snap.difficulty)
		else string.format("%s %d/%d", string.upper(snap.difficulty), snap.number or 1, if group then #group else 1)
	self.pill.BackgroundColor3 = Theme.DifficultyColors[snap.difficulty] or Theme.PanelRaised

	local captured = snap.targetsTotal - snap.targetsLeft
	self.cells.MOVES.value.Text = tostring(snap.moveCount)
	self.cells.CAPTURED.value.Text = string.format("%d / %d", captured, snap.targetsTotal)
	-- Endless boards have no par: that cell shows the run's lives instead.
	self.cells.PAR.head.Text = if run then "LIVES" else "PAR"
	self.cells.PAR.value.Text = if run
		then string.rep("♥", run.lives) .. string.rep("♡", math.max(0, run.maxLives - run.lives))
		else tostring(snap.par)
	self.cells.TIME.head.Text = if snap.duel then "TIME LEFT" else "TIME"

	self.goalCapture.Text = string.format("Capture <b>%d / %d</b> pieces", captured, snap.targetsTotal)
	self.goalPar.Text = if run
		then string.format("Score <b>%d</b>  ·  best <b>%d</b>", run.cleared, run.best)
		else string.format("Par: <b>%d</b> moves", snap.par)

	self:_renderDots(snap)
	self:_renderStreak(progress)
	local weekly = progress and progress.weekly
	if weekly then
		self.weeklyCount.Text = string.format("%d / %d", weekly.clearedCount, weekly.size)
		self.weeklyFill.Size = UDim2.fromScale(math.clamp(weekly.clearedCount / math.max(1, weekly.size), 0, 1), 1)
	else
		self.weeklyCount.Text = "..."
	end
end

-- The HUD's timer ticks this every frame.
function PlayDesk.setTime(self: any, value: string, color: Color3)
	local cell = self.cells.TIME
	cell.value.Text = "⏱ " .. value
	cell.value.TextColor3 = color
end

-- Sidebar state: the page the player is on, and what can be pressed now.
function PlayDesk.setNav(self: any, selected: string?, dueling: boolean)
	self.sidebar:setSelected(selected)
	for _, item in ipairs(NAV_ITEMS) do
		-- In a live duel every page but this one asks to forfeit first, so the
		-- items stay pressable; the HUD shows that question.
		self.sidebar:setEnabled(item.id, true)
	end
	self.sidebar:setDot("Duel", dueling)
end

return PlayDesk
