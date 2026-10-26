--!strict
-- PuzzleMenu: the full-screen menu. A sidebar (MenuSidebar) stays on the left;
-- the page beside it is either Home (HomeDashboard) or one of the panels below.
--
--   Home      profile, level and coins, the four modes, Continue, streak, stats
--   Journey   difficulties unlock in order; rows show clears, stars and what
--             unlocks the next difficulty
--   Practice  every puzzle, any difficulty, free hints, no rewards
--   Daily     today's puzzle, its one free hint, the streak and its shield
--   Stats     the server's numbers for this player, and achievements
--   Settings  sound on/off, volume, haptics, drag-to-move, replay tutorial
--
-- It opens on join (showing a loading state until the server's first
-- snapshot) and from the HUD's Menu button. It only draws what the server
-- reported (snapshot.progress) and sends requests; the server checks locks,
-- rewards and settings again before acting on anything.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Achievements = require(Shared:WaitForChild("Achievements"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PuzzleDefinitions = require(Shared:WaitForChild("PuzzleDefinitions"))

local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))
local Sound = require(script.Parent.Parent:WaitForChild("SoundController"))
local Decor = require(script.Parent:WaitForChild("Decor"))
local HomeDashboard = require(script.Parent:WaitForChild("HomeDashboard"))
local MenuSidebar = require(script.Parent:WaitForChild("MenuSidebar"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local PLAY_MODES = GameConfig.PLAY_MODES
local VIEWS = { "Home", "Journey", "Practice", "Daily", "Weekly", "Endless", "Duel", "Stats", "Settings" }

-- Below this screen width the sidebar is a rail of icons, and opening it
-- floats it over the page instead of pushing the page over.
local NARROW = 900

local NAV_ITEMS: { MenuSidebar.Item } = {
	{ id = "Home", icon = "🏠", label = "Home" },
	{ id = "Play", icon = "▶", label = "Play" },
	{ id = "Journey", icon = "🏔", label = "Journey" },
	{ id = "Daily", icon = "📅", label = "Daily Puzzle" },
	{ id = "Weekly", icon = "🏆", label = "Weekly Challenge" },
	{ id = "Endless", icon = "🌀", label = "Endless" },
	{ id = "Practice", icon = "🧩", label = "Practice" },
	{ id = "Duel", icon = "⚔️", label = "Puzzle Duel" },
	{ id = "Stats", icon = "📊", label = "Statistics" },
	{ id = "Tutorial", icon = "🎓", label = "How to Play" },
	{ id = "Settings", icon = "⚙️", label = "Settings", footer = true },
	{ id = "Collapse", icon = "<", label = "Collapse", footer = true },
}

local PuzzleMenu = {}
PuzzleMenu.__index = PuzzleMenu

export type Handlers = {
	start: (puzzleId: string, mode: string) -> (),
	settings: (values: { [string]: any }) -> (),
	tutorial: () -> (),
	duelJoin: () -> (),
	duelCancel: () -> (),
}

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

-- "★★☆" for a 0-3 rating.
local function starText(stars: number): string
	return string.rep("★", stars) .. string.rep("☆", 3 - stars)
end
PuzzleMenu.starText = starText

local function dateOf(day: number): string
	return os.date("!%b %d", day * 86400) :: string
end

local function duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local hours, minutes = seconds // 3600, (seconds % 3600) // 60
	if hours >= 24 then
		return string.format("%dd %02dh", hours // 24, hours % 24)
	elseif hours > 0 then
		return string.format("%dh %02dm", hours, minutes)
	end
	return string.format("%dm %02ds", minutes, seconds % 60)
end

function PuzzleMenu.new(playerGui: Instance, handlers: Handlers)
	local self = setmetatable({}, PuzzleMenu) :: any
	self.handlers = handlers
	self.view = "Home"
	self.progress = nil
	self.snapshot = nil
	self.newlyUnlocked = nil
	self.receivedAt = os.clock()
	self.dragEnabled = true -- kept in step by the HUD, which owns the setting

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
	-- The menu is its own screen: the backdrop covers the board behind it.
	Decor.backdrop(gui)
	self.root = make("Frame", {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	-- The menu fills the screen, but its contents start below Roblox's top
	-- bar so the Roblox buttons never cover the logo or the coins.
	self.topInset = GuiService:GetGuiInset().Y
	pcall(function()
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(function()
			self.topInset = GuiService:GetGuiInset().Y
			self:_layout()
		end)
	end)
	self.sidebarPrefs = { narrow = false, wide = true } -- true = expanded
	self.sidebar = MenuSidebar.new(self.root, NAV_ITEMS, function(id: string)
		self:_navigate(id)
	end)
	-- Tapping the page while the sidebar floats over it folds the sidebar away.
	self.scrim = make("TextButton", {
		Name = "Scrim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.5,
		AutoButtonColor = false,
		Text = "",
		Visible = false,
		ZIndex = 15,
		Parent = self.root,
	})
	self.scrim:SetAttribute("Silent", true)
	self.scrim.Activated:Connect(function()
		self.sidebarPrefs.narrow = false
		self:_layout()
	end)
	local content = make("Frame", {
		Name = "Content",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Parent = self.root,
	})
	self.content = content
	self.scale = make("UIScale", { Parent = content })
	self.home = make("ScrollingFrame", {
		Name = "Home",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.Stroke,
		CanvasSize = UDim2.new(),
		Parent = content,
	})
	local panel = make("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -24, 1, -24),
		BackgroundColor3 = Theme.Panel,
		Parent = content,
	}, {
		corner(16),
		make("UIStroke", { Color = Theme.Stroke, Thickness = 1.5 }),
		make("UISizeConstraint", { MaxSize = Vector2.new(600, 780) }),
	})
	Decor.sheen(panel, 0.3)
	self.panel = panel

	-- Header: back, title, close.
	self.backButton = make("TextButton", {
		Name = "BackButton",
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.fromOffset(44, 44),
		BackgroundColor3 = Theme.PanelRaised,
		FontFace = Theme.FontBold,
		Text = "<",
		TextColor3 = Theme.Text,
		TextSize = 20,
		Parent = panel,
	}, { corner(10) })
	self.backButton.Activated:Connect(function()
		self:show("Home")
	end)
	self.title = text({
		Name = "Title",
		FontFace = Theme.FontHeavy,
		TextSize = 22,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		-- Long titles shrink to fit narrow panels instead of truncating.
		TextScaled = true,
		Position = UDim2.fromOffset(18, 12),
		Size = UDim2.new(1, -130, 0, 28),
		Parent = panel,
	})
	make("UITextSizeConstraint", { MaxTextSize = 22, MinTextSize = 12, Parent = self.title })
	Decor.goldText(self.title)
	self.wallet = text({
		Name = "Wallet",
		TextScaled = true,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 40),
		Size = UDim2.new(1, -130, 0, 18),
		Parent = panel,
	})
	make("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 9, Parent = self.wallet })
	self.closeButton = make("TextButton", {
		Name = "CloseButton",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(44, 44),
		BackgroundColor3 = Theme.PanelRaised,
		FontFace = Theme.FontBold,
		Text = "X",
		TextColor3 = Theme.Text,
		TextSize = 18,
		Parent = panel,
	}, { corner(10) })
	self.closeButton.Activated:Connect(function()
		self:_play()
	end)

	self.note = text({
		Name = "Note",
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(18, 66),
		Size = UDim2.new(1, -36, 0, 56),
		Parent = panel,
	})
	-- On narrow panels a note can wrap to three or four lines; the list
	-- starts below however many it takes.
	self.note:GetPropertyChangedSignal("TextBounds"):Connect(function()
		self:_placeList()
	end)
	self.list = make("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(12, 108),
		Size = UDim2.new(1, -24, 1, -120),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = panel,
	}, {
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10) }),
		make("UIPadding", { PaddingBottom = UDim.new(0, 8) }),
	})

	-- Keep the Daily countdown ticking while it is on screen.
	task.spawn(function()
		while true do
			task.wait(1)
			local label = self.countdown
			if self.gui.Enabled and label and label.Parent and self.snapshot and self.snapshot.nextDailyIn then
				local left = self.snapshot.nextDailyIn - (os.clock() - self.receivedAt)
				label.Text = if left <= 0
					then "A new puzzle is ready. Reopen the menu to load it."
					else "Next puzzle in " .. duration(left)
			end
			local weekly = self.weeklyCountdown
			if self.gui.Enabled and weekly and weekly.Parent and self.snapshot and self.snapshot.nextWeeklyIn then
				local left = self.snapshot.nextWeeklyIn - (os.clock() - self.receivedAt)
				weekly.Text = if left <= 0
					then "A new challenge is ready. Reopen the menu to load it."
					else "New challenge in " .. duration(left)
			end
			local queue = self.queueLabel
			if self.gui.Enabled and queue and queue.Parent and self.queuedAt then
				queue.Text = "Waiting " .. duration(os.clock() - self.queuedAt)
			end
			local badge = self.homeTicking and self.homeTicking.weeklyBadge
			local left = self:_weeklyLeft()
			if self.gui.Enabled and badge and badge.Parent and left then
				badge.Text = "⏱ " .. duration(left)
			end
		end
	end)

	self.root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_layout()
	end)
	-- The Duel card shows how many players are on this server.
	local function playersChanged()
		if self.gui.Enabled and not self.closing then
			self:_render()
		end
	end
	Players.PlayerAdded:Connect(playersChanged)
	Players.PlayerRemoving:Connect(function()
		task.defer(playersChanged)
	end)
	local player = Players.LocalPlayer
	self.playerName = if player then player.DisplayName else "Player"
	if player then
		task.spawn(function()
			local ok, image = pcall(function()
				return Players:GetUserThumbnailAsync(
					player.UserId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size150x150
				)
			end)
			if ok and image then
				self.avatar = image
				if self.gui.Enabled and self.view == "Home" then
					self:_render()
				end
			end
		end)
	end
	self:_layout()
	return self
end

function PuzzleMenu._weeklyLeft(self: any): number?
	if self.snapshot and self.snapshot.nextWeeklyIn then
		return self.snapshot.nextWeeklyIn - (os.clock() - self.receivedAt)
	end
	return nil
end

-- Sidebar width and mode for the screen size, then the page beside it.
-- `fromRender` is set when _render calls this, so it does not render again.
function PuzzleMenu._layout(self: any, fromRender: boolean?)
	local size = self.root.AbsoluteSize
	if size.X <= 0 then
		return
	end
	local narrow = size.X < NARROW
	local expanded = if narrow then self.sidebarPrefs.narrow else self.sidebarPrefs.wide
	local floating = narrow and expanded
	-- On a phone a sub-page needs the whole width (its rows were laid out
	-- for ~300 px), so the rail steps aside and Back returns to Home.
	local pageOnly = narrow and self.view ~= "Home"
	self.sidebar.frame.Visible = not pageOnly
	self.sidebar:setMode(not expanded, floating)
	self.sidebar:setLabel("Collapse", if expanded then "Collapse" else "Expand")
	local collapseEntry = self.sidebar.items.Collapse
	if collapseEntry then
		collapseEntry.icon.Text = if expanded then "<" else ">"
	end
	self.scrim.Visible = floating and not pageOnly
	local rail = if pageOnly then 0
		elseif narrow or not expanded then MenuSidebar.COLLAPSED
		else MenuSidebar.EXPANDED
	local top = self.topInset or 0
	self.sidebar:setTopInset(top)
	self.content.Position = UDim2.new(0.5, rail / 2, 0.5, top / 2)
	self.content.Size = UDim2.new(1, -rail, 1, -top)
	self.sidebar:setDense(size.Y - top < 480)
	local width = size.X - rail
	if self.homeWidth ~= width or self.homeHeight ~= size.Y - top then
		self.homeWidth = width
		self.homeHeight = size.Y - top
		if not fromRender and self.gui.Enabled and self.view == "Home" then
			self:_render()
		end
	end
end

-- A sidebar press.
function PuzzleMenu._navigate(self: any, id: string)
	local narrow = self.root.AbsoluteSize.X < NARROW
	if id == "Collapse" then
		local key = if narrow then "narrow" else "wide"
		self.sidebarPrefs[key] = not self.sidebarPrefs[key]
		self:_layout()
		return
	end
	if narrow and self.sidebarPrefs.narrow then
		-- A floating sidebar folds away once something is picked.
		self.sidebarPrefs.narrow = false
		self:_layout()
	end
	if id == "Play" then
		self:_play()
	elseif id == "Tutorial" then
		if self.progress and not self:isQueued() then
			self.handlers.tutorial()
		end
	elseif table.find(VIEWS, id) then
		self:show(id)
	end
end

-- Leaves the menu for the board. The HUD may start the tutorial instead,
-- for a new player who has not played yet.
function PuzzleMenu._play(self: any)
	if not self:_canClose() then
		return
	end
	if self.handlers.play then
		self.handlers.play()
	else
		self:close()
	end
end

-- Close only when there is a puzzle behind the menu to return to, and not
-- while searching for a duel (Cancel leaves the queue).
function PuzzleMenu._canClose(self: any): boolean
	return self.snapshot ~= nil and not self:isQueued()
end

function PuzzleMenu.isQueued(self: any): boolean
	return self.duelState ~= nil and self.duelState.phase == "queued"
end

-- Duel queue snapshots (no board), or nil once a board snapshot arrives.
function PuzzleMenu.updateDuel(self: any, snap: any)
	local wasQueued = self:isQueued()
	self.duelState = snap and snap.duel
	self.duelError = snap and snap.error
	if self:isQueued() and not wasQueued then
		self.queuedAt = os.clock()
	elseif not self:isQueued() then
		self.queuedAt = nil
	end
	if snap then
		self.progress = snap.progress or self.progress
		self.duelsAllServers = snap.duelsAllServers == true
		self.saveStatus = snap.saveStatus or self.saveStatus
		if self.gui.Enabled and not self.closing then
			self:_render()
		end
	end
end

function PuzzleMenu.open(self: any, view: string?)
	self.view = if view and table.find(VIEWS, view) then view else "Home"
	local wasOpen = self.gui.Enabled
	self.gui.Enabled = true
	self.list.CanvasPosition = Vector2.zero
	self.home.CanvasPosition = Vector2.zero
	self:_render()
	if not wasOpen then
		Sound.play("open")
		self.scale.Scale = 0.94
		Anim.tween(self.scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	end
end

function PuzzleMenu.show(self: any, view: string)
	self.view = view
	self.list.CanvasPosition = Vector2.zero
	self:_render()
end

function PuzzleMenu.close(self: any)
	if not self.gui.Enabled or self.closing then
		return
	end
	self.closing = true
	Anim.tween(self.scale, 0.12, { Scale = 0.96 }).Completed:Connect(function()
		self.closing = false
		self.gui.Enabled = false
		self.scale.Scale = 1
	end)
end

function PuzzleMenu.isOpen(self: any): boolean
	return self.gui.Enabled and not self.closing
end

-- Called with every snapshot so the menu always shows current progress.
function PuzzleMenu.update(self: any, snap: any)
	self.snapshot = snap
	self.receivedAt = os.clock()
	self.progress = snap.progress
	self.duelsAllServers = snap.duelsAllServers == true
	self.saveStatus = snap.saveStatus
	-- The Settings view already shows the player's own changes; redrawing it
	-- when the server confirms them would rebuild buttons mid-click.
	local echo = snap.event == "settings" and self.view == "Settings"
	if self.gui.Enabled and not self.closing and not echo then
		self:_render()
	end
end

-- Marks a difficulty as just unlocked so the Journey list can point it out.
function PuzzleMenu.markUnlocked(self: any, difficulty: string)
	self.newlyUnlocked = difficulty
end

function PuzzleMenu._start(self: any, puzzleId: string, mode: string)
	self:close()
	self.handlers.start(puzzleId, mode)
end

-- Building blocks ------------------------------------------------------------------

local function card(self: any, order: number, height: number, name: string?): Frame
	local frame = make("Frame", {
		Name = name or ("Card" .. order),
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, height),
		BackgroundColor3 = Theme.PanelRaised,
		Parent = self.list,
	}, { corner(12), make("UIStroke", { Color = Theme.Stroke, Thickness = 1, Transparency = 0.5 }) })
	Decor.sheen(frame, 0.16)
	return frame
end

-- A full-width button with a title and a muted line under it.
local function rowButton(self: any, order: number, name: string, title: string, sub: string, color: Color3?): TextButton
	local button = make("TextButton", {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, 64),
		BackgroundColor3 = color or Theme.PanelRaised,
		AutoButtonColor = true,
		Text = "",
		Parent = self.list,
	}, {
		corner(12),
		make("UIStroke", {
			Color = if color then Color3.new(1, 1, 1) else Theme.Stroke,
			Thickness = 1,
			Transparency = if color then 0.7 else 0.5,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
	})
	Decor.sheen(button, if color then 0.24 else 0.16)
	text({
		Name = "Title",
		Text = title,
		FontFace = Theme.FontBold,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -48, 0, 22),
		Parent = button,
	})
	text({
		Name = "Sub",
		Text = sub,
		TextSize = 13,
		TextColor3 = if color then Theme.Text else Theme.TextMuted,
		TextTransparency = if color then 0.15 else 0,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(16, 34),
		Size = UDim2.new(1, -48, 0, 18),
		Parent = button,
	})
	text({
		Text = ">",
		FontFace = Theme.FontBold,
		TextSize = 18,
		TextColor3 = Theme.TextMuted,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(16, 22),
		Parent = button,
	})
	return button
end

-- A piece from the sheet in a round badge on the row's left; the row's
-- text moves over to make room.
local function rowIcon(button: TextButton, kind: string, black: boolean?)
	if Theme.PieceSheet == "" then
		return
	end
	local badge = make("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = Theme.SquareLight,
		Parent = button,
	}, { corner(20) })
	make("ImageLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.78, 0.78),
		BackgroundTransparency = 1,
		Image = Theme.PieceSheet,
		ImageRectSize = Vector2.new(Theme.PieceCell, Theme.PieceCell),
		ImageRectOffset = Vector2.new(
			(Theme.PieceSheetColumns[kind] or 5) * Theme.PieceCell,
			if black then Theme.PieceCell else 0
		),
		ScaleType = Enum.ScaleType.Fit,
		Parent = badge,
	})
	for _, name in ipairs({ "Title", "Sub" }) do
		local line = button:FindFirstChild(name) :: TextLabel?
		if line then
			line.Position = UDim2.fromOffset(64, line.Position.Y.Offset)
			line.Size = UDim2.new(1, -96, 0, line.Size.Y.Offset)
		end
	end
end

local function progressBar(parent: Instance, position: UDim2, size: UDim2, fraction: number, color: Color3)
	local track = make("Frame", {
		Name = "ProgressBar",
		Position = position,
		Size = size,
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
		Parent = parent,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = track,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
end

-- Weekly Challenge ----------------------------------------------------------------------

function PuzzleMenu._renderWeekly(self: any)
	local progress = self.progress
	local weekly = progress and progress.weekly
	if not weekly then
		text({ Text = "Loading this week's challenge...", Size = UDim2.new(1, 0, 0, 40), Parent = self.list })
		return
	end
	local top = card(self, 1, 132, "WeeklyCard")
	text({
		Text = string.format("THIS WEEK  ·  %s – %s", dateOf(weekly.firstDay), dateOf(weekly.firstDay + 6)),
		FontFace = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = top,
	})
	text({
		Name = "Progress",
		Text = if weekly.completed
			then "Challenge complete ✓"
			else string.format("%d / %d cleared", weekly.clearedCount, weekly.size),
		FontFace = Theme.FontBold,
		TextSize = 24,
		TextColor3 = if weekly.completed then Theme.Legal else Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 34),
		Size = UDim2.new(1, -28, 0, 30),
		Parent = top,
	})
	progressBar(top, UDim2.fromOffset(14, 72), UDim2.new(1, -28, 0, 8), weekly.clearedCount / math.max(1, weekly.size), Theme.Gold)
	local countdown = text({
		Name = "Countdown",
		TextSize = 14,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 94),
		Size = UDim2.new(1, -28, 0, 20),
		Parent = top,
	})
	if self.snapshot and self.snapshot.nextWeeklyIn then
		countdown.Text = "New challenge in " .. duration(self.snapshot.nextWeeklyIn - (os.clock() - self.receivedAt))
	end
	self.weeklyCountdown = countdown

	-- Rewards.
	for index, milestone in ipairs(weekly.milestones) do
		local row = card(self, 1 + index, 50, "Milestone" .. index)
		local final = milestone.cleared >= weekly.size
		text({
			Text = if final then string.format("Clear all %d", milestone.cleared) else string.format("Clear %d puzzles", milestone.cleared),
			FontFace = Theme.FontBold,
			TextSize = 15,
			TextColor3 = if milestone.claimed then Theme.Gold else Theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(14, 0),
			Size = UDim2.new(1, -150, 1, 0),
			Parent = row,
		})
		text({
			Text = if milestone.claimed
				then "✓ Collected"
				else string.format("+%d XP  +%d coins", milestone.xp, milestone.coins),
			TextSize = 14,
			TextColor3 = if milestone.claimed then Theme.Legal else Theme.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 0),
			Size = UDim2.new(0, 140, 1, 0),
			Parent = row,
		})
	end

	-- The puzzles, easiest first.
	local order = 10
	for index, id in ipairs(weekly.puzzleIds) do
		local puzzle = PuzzleDefinitions.get(id)
		if puzzle then
			local cleared = weekly.cleared[id] == true
			local record = progress.completed[id]
			local sub = string.format(
				"%s  ·  par %d  ·  %s",
				puzzle.difficulty,
				puzzle.par,
				if cleared then "cleared ✓" else "not cleared"
			)
			if record and record.stars and record.stars > 0 then
				sub ..= "  ·  " .. starText(record.stars)
			end
			local button = rowButton(self, order + index, "WeeklyPuzzle" .. index, string.format("%d.  %s", index, puzzle.name), sub)
			local title = button:FindFirstChild("Title") :: TextLabel?
			if title then
				title.TextColor3 = if cleared then Theme.Legal else Theme.DifficultyColors[puzzle.difficulty] or Theme.Text
			end
			button.Activated:Connect(function()
				self:_start(id, PLAY_MODES.Weekly)
			end)
		end
	end
end

-- Puzzle Duel ----------------------------------------------------------------------------

local DUEL_ERRORS = {
	already_queued = "You're already in the queue.",
	matching = "Matching you with an opponent, one moment.",
	teleport_failed = "Couldn't move you to the match server. Try again.",
	opponent_missing = "Your opponent didn't make it. Try again.",
}

function PuzzleMenu._renderDuel(self: any)
	local progress = self.progress
	local queued = self:isQueued()
	local duel = self.duelState or {}
	-- Matched with a player from another server: on the way to the match server.
	local found = if queued then duel.found else nil
	local joining = found ~= nil and not duel.arriving -- the teleport is under way
	-- On a phone-width panel the body wraps to four lines, so give it room.
	local bodyHeight = if self.list.AbsoluteSize.X < 340 then 72 else 54
	local top = card(self, 1, 122 + bodyHeight, "DuelCard")
	local title = "RACE ANOTHER PLAYER"
	if found then
		title = "OPPONENT FOUND"
	elseif queued then
		title = if duel.allServers then "SEARCHING ALL SERVERS..." else "SEARCHING FOR AN OPPONENT..."
	end
	text({
		Text = title,
		FontFace = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = top,
	})
	local body
	if found and duel.arriving then
		body = string.format("Waiting for %s to arrive. The countdown starts as soon as you're both here.", found)
	elseif found then
		body = string.format("You'll race %s from another server. Moving you both to a match server now...", found)
	elseif queued and duel.allServers then
		body = "Looking for an opponent here and on every other server. When one is found, you'll both get the same puzzle after a short countdown."
	elseif queued then
		local waiting = duel.waiting or 1
		body = string.format(
			"You're in the queue%s. When someone else in this server joins, you'll both get the same puzzle after a short countdown.",
			if waiting > 1 then string.format(" (%d waiting)", waiting) else ""
		)
	else
		body = "Same puzzle, separate boards. The first player to clear their board wins. If nobody clears it in 3 minutes, it's a draw."
	end
	text({
		Name = "Body",
		Text = body,
		TextSize = 14,
		TextColor3 = Theme.Text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(14, 36),
		Size = UDim2.new(1, -28, 0, bodyHeight),
		Parent = top,
	})
	local status = text({
		Name = "Status",
		Text = "",
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 38 + bodyHeight),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = top,
	})
	self.queueLabel = if queued then status else nil
	if queued and self.queuedAt then
		status.Text = "Waiting " .. duration(os.clock() - self.queuedAt)
	elseif self.duelError then
		status.Text = DUEL_ERRORS[self.duelError] or "That didn't go through. Try again."
		status.TextColor3 = Theme.Danger
	end
	local action = make("TextButton", {
		Name = if queued then "CancelDuel" else "FindDuel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -12),
		Size = UDim2.new(1, -28, 0, 48),
		BackgroundColor3 = if queued then Theme.PanelRaised else Theme.Accent,
		AutoButtonColor = not joining,
		FontFace = Theme.FontBold,
		Text = if joining then "Joining match..." else if queued then "Cancel" else "Find opponent",
		TextColor3 = Theme.Text,
		TextSize = 18,
		Parent = top,
	}, { corner(12) })
	Decor.sheen(action, 0.2)
	action.Activated:Connect(function()
		if joining then
			return
		elseif queued then
			self.handlers.duelCancel()
		else
			self.handlers.duelJoin()
		end
	end)

	local stats = progress and progress.duel
	local info = card(self, 2, 108, "DuelStats")
	text({
		Text = "YOUR DUELS",
		FontFace = Theme.FontBold,
		TextSize = 12,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.new(1, -28, 0, 16),
		Parent = info,
	})
	local record = text({
		Name = "Record",
		Text = if stats
			then string.format("%d W  ·  %d L  ·  %d D   (%d played)", stats.wins, stats.losses, stats.draws, stats.played)
			else "Loading...",
		FontFace = Theme.FontBold,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 28),
		Size = UDim2.new(1, -28, 0, 26),
		Parent = info,
	})
	make("UITextSizeConstraint", { MaxTextSize = 20, MinTextSize = 12, Parent = record })
	text({
		Name = "Rewards",
		Text = string.format(
			"Win +%d coins, draw +%d. Rewarded duels left today: %d of %d, one per opponent.",
			GameConfig.DUEL.REWARD_WIN.coins,
			GameConfig.DUEL.REWARD_DRAW.coins,
			if stats then stats.rewardsLeftToday else GameConfig.DUEL.DAILY_REWARDED,
			GameConfig.DUEL.DAILY_REWARDED
		),
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(14, 60),
		Size = UDim2.new(1, -28, 0, 40),
		Parent = info,
	})
end

-- Home ---------------------------------------------------------------------------------

-- What Home's Continue panel offers: the attempt in progress, else the next
-- Journey puzzle, else the Journey list.
function PuzzleMenu._continueData(self: any): HomeDashboard.Continue
	local progress = self.progress
	local snap = self.snapshot
	if progress == nil or self.saveStatus == "loading" then
		return { title = "Loading your progress...", sub = "One moment.", button = "Continue" }
	end
	if snap and snap.status == "playing" and snap.moveCount > 0 and snap.mode ~= GameConfig.DUEL_MODE then
		return {
			title = "Resume",
			sub = string.format(
				"%s  •  %s  •  %d %s in",
				snap.name,
				snap.mode,
				snap.moveCount,
				if snap.moveCount == 1 then "move" else "moves"
			),
			button = "Resume",
			action = function()
				self:_play()
			end,
		}
	end
	local resume = progress.resumeId and PuzzleDefinitions.get(progress.resumeId)
	if resume then
		local group = PuzzleDefinitions.byDifficulty[resume.difficulty] or {}
		local cleared = 0
		for _, puzzle in ipairs(group) do
			local record = progress.completed[puzzle.id]
			if record and record.credited then
				cleared += 1
			end
		end
		return {
			title = if progress.totals.cleared == 0 then "Start Journey" else "Continue Journey",
			sub = string.format("%s %d/%d  •  %s", resume.difficulty, resume.number, #group, resume.name),
			button = if progress.totals.cleared == 0 then "Start" else "Continue",
			fraction = if #group > 0 then cleared / #group else 0,
			action = function()
				self:_start(resume.id, PLAY_MODES.Journey)
			end,
		}
	end
	return {
		title = "Journey complete",
		sub = "Every puzzle cleared. Replay any for more stars.",
		button = "View",
		fraction = 1,
		action = function()
			self:show("Journey")
		end,
	}
end

function PuzzleMenu._renderHome(self: any)
	local left = self:_weeklyLeft()
	self.homeTicking = HomeDashboard.render(self.home, self.home.AbsoluteSize.X, self.home.AbsoluteSize.Y, {
		progress = self.progress,
		loading = self.progress == nil or self.saveStatus == "loading",
		saveStatus = self.saveStatus,
		playerName = self.playerName or "Player",
		avatar = self.avatar,
		queued = self:isQueued(),
		serverPlayers = #Players:GetPlayers(),
		allServers = self.duelsAllServers == true,
		endlessBoard = (function()
			local run = self:_liveRun()
			return run and run.board
		end)(),
		weeklyLeftText = if left then duration(left) else nil,
		continue = self:_continueData(),
	}, {
		open = function(view: string)
			self:show(view)
		end,
	})
end

-- Journey and Practice -----------------------------------------------------------------

local function difficultyRow(self: any, order: number, difficulty: string, index: number)
	local progress = self.progress or { unlockedIndex = 1, completed = {}, unlocks = nil }
	local journey = self.view == PLAY_MODES.Journey
	local locked = journey and index > progress.unlockedIndex
	local puzzles = PuzzleDefinitions.byDifficulty[difficulty]
	-- In Journey only clears that count towards unlocks are shown.
	local function recordOf(puzzle: any): any
		local record = progress.completed[puzzle.id]
		if record and (not journey or record.credited) then
			return record
		end
		return nil
	end
	local done, stars = 0, 0
	for _, puzzle in ipairs(puzzles) do
		local record = recordOf(puzzle)
		if record then
			done += 1
			stars += record.stars or 0
		end
	end
	local row = card(self, order, if locked then 128 else 106, difficulty)
	row.BackgroundTransparency = if locked then 0.4 else 0
	local isNew = journey and self.newlyUnlocked == difficulty
	text({
		Text = string.upper(difficulty) .. (if isNew then "  ·  NEW!" else ""),
		FontFace = Theme.FontBold,
		TextSize = 14,
		TextColor3 = if isNew then Theme.Gold else (Theme.DifficultyColors[difficulty] or Theme.Text),
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(0.5, 0, 0, 18),
		Parent = row,
	})
	local previous = GameConfig.DIFFICULTIES[index - 1]
	local unlockRow = progress.unlocks and previous and progress.unlocks[index - 1]
	text({
		Name = "Summary",
		Text = if locked then "Locked" else string.format("%d/%d cleared  ·  %d/%d★", done, #puzzles, stars, 3 * #puzzles),
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.new(0.6, 0, 0, 18),
		Parent = row,
	})
	if locked and previous then
		local need = if unlockRow then unlockRow.required else GameConfig.UNLOCK_REQUIREMENT
		local have = if unlockRow then math.min(unlockRow.credited, need) else 0
		local unlockNote = text({
			Name = "UnlockNote",
			Text = string.format("Clear %d %s puzzles to unlock  (%d/%d)", need, previous, have, need),
			TextScaled = true,
			TextColor3 = Theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(12, 28),
			Size = UDim2.new(1, -24, 0, 16),
			Parent = row,
		})
		make("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 9, Parent = unlockNote })
		progressBar(row, UDim2.fromOffset(12, 48), UDim2.new(1, -24, 0, 6), have / need, Theme.DifficultyColors[previous] or Theme.Legal)
	end
	local grid = make("Frame", {
		Position = UDim2.new(0, 10, 1, -64),
		Size = UDim2.new(1, -20, 0, 54),
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
		local record = recordOf(puzzle)
		local current = self.snapshot and puzzle.id == self.snapshot.puzzleId
		local cell = make("TextButton", {
			Name = puzzle.id,
			LayoutOrder = number,
			Size = UDim2.new(1 / 6, -5, 1, 0),
			BackgroundColor3 = if record then Theme.Legal elseif current then Theme.Accent else Theme.Panel,
			BackgroundTransparency = if locked then 0.6 else 0,
			AutoButtonColor = not locked,
			Text = "",
			Parent = grid,
		}, { corner(10) })
		local ink = if record then Theme.Background else Theme.Text
		text({
			Text = tostring(number),
			FontFace = Theme.FontBold,
			TextSize = 18,
			TextColor3 = ink,
			TextTransparency = if locked then 0.6 else 0,
			Position = UDim2.fromOffset(0, 5),
			Size = UDim2.new(1, 0, 0, 24),
			Parent = cell,
		})
		text({
			Name = "Stars",
			Text = if record and record.stars and record.stars > 0 then starText(record.stars) elseif record then "✓" else "",
			TextSize = 12,
			TextColor3 = ink,
			Position = UDim2.new(0, 0, 1, -21),
			Size = UDim2.new(1, 0, 0, 16),
			Parent = cell,
		})
		if current then
			make("UIStroke", { Color = Theme.Selected, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = cell })
		end
		cell.Activated:Connect(function()
			if locked then
				Sound.play("invalid")
				Anim.shake(row)
				return
			end
			self:_start(puzzle.id, self.view)
		end)
	end
end

-- Daily ----------------------------------------------------------------------------------

function PuzzleMenu._renderDaily(self: any)
	local progress = self.progress
	local daily = progress and progress.daily
	local puzzle = daily and PuzzleDefinitions.get(daily.puzzleId)
	local top = card(self, 1, 170, "DailyCard")
	if not puzzle then
		text({ Text = "Loading today's puzzle...", Size = UDim2.fromScale(1, 1), Parent = top })
		return
	end
	text({
		Text = "TODAY'S PUZZLE  ·  " .. dateOf(daily.day),
		FontFace = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = top,
	})
	text({
		Text = puzzle.name,
		FontFace = Theme.FontBold,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 32),
		Size = UDim2.new(1, -28, 0, 30),
		Parent = top,
	})
	local record = progress.completed[puzzle.id]
	text({
		Name = "Status",
		Text = string.format(
			"%s  ·  %s  ·  %s%s",
			puzzle.difficulty,
			if daily.hintUsed then "hint used" else "1 free hint",
			if daily.completed then "cleared today ✓" else "not cleared yet",
			if record and record.stars and record.stars > 0 then "  ·  " .. starText(record.stars) else ""
		),
		TextSize = 14,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Position = UDim2.fromOffset(14, 66),
		Size = UDim2.new(1, -28, 0, 36),
		Parent = top,
	})
	local play = make("TextButton", {
		Name = "PlayDaily",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -12),
		Size = UDim2.new(1, -28, 0, 48),
		BackgroundColor3 = Theme.Accent,
		FontFace = Theme.FontBold,
		Text = if daily.completed then "Play again (no reward)" else "Play",
		TextColor3 = Theme.Text,
		TextSize = 18,
		Parent = top,
	}, { corner(12) })
	play.Activated:Connect(function()
		self:_start(puzzle.id, PLAY_MODES.Daily)
	end)

	-- Streak and shield.
	local streak = progress.streak
	local info = make("Frame", {
		Name = "StreakCard",
		LayoutOrder = 2,
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.PanelRaised,
		Parent = self.list,
	}, {
		corner(12),
		make("UIPadding", {
			PaddingTop = UDim.new(0, 12),
			PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 14),
			PaddingRight = UDim.new(0, 14),
		}),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
	})
	local function line(order: number, name: string, value: string, size: number, color: Color3, bold: boolean?): TextLabel
		return text({
			Name = name,
			LayoutOrder = order,
			Text = value,
			FontFace = if bold then Theme.FontBold else Theme.Font,
			TextSize = size,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, size + 2),
			Parent = info,
		})
	end
	line(
		1,
		"Streak",
		if streak.current > 0
			then string.format("🔥 %d-day streak  (best %d)", streak.current, streak.longest)
			else string.format("🔥 No streak right now  (best %d)", streak.longest),
		18,
		Theme.Text,
		true
	)
	local shieldText
	if streak.atRisk then
		shieldText = string.format(
			"🛡 You missed yesterday. Clear today's puzzle and your shield keeps your %d-day streak.",
			streak.current
		)
	elseif streak.shieldReady then
		shieldText = "🛡 Streak shield ready. If you miss one day, clearing the next day's puzzle keeps your streak. You get one shield every 7 days. The missed day earns no reward."
	else
		shieldText = string.format(
			"🛡 Shield used%s. The next one is ready on %s.",
			if streak.protectedDay then " to cover " .. dateOf(streak.protectedDay) else "",
			dateOf(streak.shieldReadyDay)
		)
	end
	line(2, "Shield", shieldText, 14, Theme.TextMuted)
	local countdown = line(3, "Countdown", "", 14, Theme.Gold)
	if self.snapshot and self.snapshot.nextDailyIn then
		countdown.Text = "Next puzzle in " .. duration(self.snapshot.nextDailyIn - (os.clock() - self.receivedAt))
	end
	self.countdown = countdown
end

-- Stats ----------------------------------------------------------------------------------

-- "♥♥♡" for 2 of 3 lives.
function PuzzleMenu.livesText(lives: number, maxLives: number): string
	return string.rep("♥", lives) .. string.rep("♡", math.max(0, maxLives - lives))
end

-- The run in progress, if the player's current puzzle is a live Endless board.
function PuzzleMenu._liveRun(self: any): any
	local snap = self.snapshot
	local run = snap and snap.mode == PLAY_MODES.Endless and snap.endless
	if run and not run.over then
		return run
	end
	return nil
end

function PuzzleMenu._renderEndless(self: any)
	local progress = self.progress
	local stats = progress and progress.endless
	local run = self:_liveRun()
	-- On a phone-width panel the rules wrap to more lines.
	local bodyHeight = if self.list.AbsoluteSize.X < 340 then 76 else 54
	local top = card(self, 1, 132 + bodyHeight, "EndlessCard")
	text({
		Text = if run then "RUN IN PROGRESS" else "HOW FAR CAN YOU GO?",
		FontFace = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = top,
	})
	text({
		Name = "Headline",
		Text = if run
			then string.format("Board %d  ·  %s", run.board, PuzzleMenu.livesText(run.lives, run.maxLives))
			else string.format("Best run: %d %s", stats and stats.best or 0, if stats and stats.best == 1 then "board" else "boards"),
		FontFace = Theme.FontBold,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 32),
		Size = UDim2.new(1, -28, 0, 30),
		Parent = top,
	})
	text({
		Name = "Body",
		Text = string.format(
			"You start with %d lives. Every board is new and solvable, and they get bigger as you go. Your score is the boards you clear.",
			GameConfig.ENDLESS.LIVES
		),
		TextSize = 14,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Position = UDim2.fromOffset(14, 66),
		Size = UDim2.new(1, -28, 0, bodyHeight),
		Parent = top,
	})
	local buttons = make("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -12),
		Size = UDim2.new(1, -28, 0, 48),
		BackgroundTransparency = 1,
		Parent = top,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local function button(name: string, label: string, primary: boolean, order: number, width: UDim, onClick: () -> ())
		local b = make("TextButton", {
			Name = name,
			LayoutOrder = order,
			Size = UDim2.new(width.Scale, width.Offset, 1, 0),
			BackgroundColor3 = if primary then Theme.Accent else Theme.PanelRaised,
			FontFace = Theme.FontBold,
			Text = label,
			TextColor3 = Theme.Text,
			TextSize = 18,
			Parent = buttons,
		}, { corner(12) })
		b.Activated:Connect(onClick)
	end
	if run then
		button("ContinueRun", "Continue", true, 1, UDim.new(0.5, -5), function()
			self:close()
		end)
		button("NewRun", "New run", false, 2, UDim.new(0.5, -5), function()
			self:_start("new", PLAY_MODES.Endless)
		end)
	else
		button("StartRun", "Start run", true, 1, UDim.new(1, 0), function()
			self:_start("new", PLAY_MODES.Endless)
		end)
	end

	local rewardsHeight = if self.list.AbsoluteSize.X < 340 then 60 else 40
	local info = card(self, 2, 68 + rewardsHeight, "EndlessStats")
	text({
		Text = "YOUR ENDLESS RUNS",
		FontFace = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(1, -28, 0, 18),
		Parent = info,
	})
	text({
		Name = "Numbers",
		Text = if stats
			then string.format("Best %d  ·  Runs %d  ·  Boards cleared %d", stats.best, stats.runs, stats.boards)
			else "Loading...",
		FontFace = Theme.FontBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Position = UDim2.fromOffset(14, 36),
		Size = UDim2.new(1, -28, 0, 22),
		Parent = info,
	})
	text({
		Name = "Rewards",
		Text = if stats
			then string.format(
				"+%d XP a board, for %d boards a day (%d left today). Clear 10 and 25 boards in one run for achievement coins.",
				GameConfig.ENDLESS.XP_PER_BOARD,
				GameConfig.ENDLESS.DAILY_REWARDED,
				stats.rewardsLeftToday
			)
			else "",
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Position = UDim2.fromOffset(14, 62),
		Size = UDim2.new(1, -28, 0, rewardsHeight),
		Parent = info,
	})
end

function PuzzleMenu._renderStats(self: any)
	local progress = self.progress
	if not progress then
		text({ Text = "Loading your statistics...", Size = UDim2.new(1, 0, 0, 40), Parent = self.list })
		return
	end
	local stats, totals, streak = progress.stats, progress.totals, progress.streak
	local tiles = {
		{ "Puzzles cleared", string.format("%d / %d", totals.cleared, totals.puzzles) },
		{ "Stars", string.format("%d / %d", totals.stars, totals.maxStars) },
		{ "3-star clears", tostring(totals.perfect) },
		{ "Daily streak", string.format("%d  (best %d)", streak.current, streak.longest) },
		{ "Dailies cleared", tostring(stats.dailies or 0) },
		{ "Weekly challenges", tostring(stats.weeklies or 0) },
		{ "Best Endless run", if progress.endless then string.format("%d boards", progress.endless.best) else "0 boards" },
		{
			"Duels W / L / D",
			if progress.duel
				then string.format("%d / %d / %d", progress.duel.wins, progress.duel.losses, progress.duel.draws)
				else "0 / 0 / 0",
		},
		{ "Solves", tostring(stats.solves) },
		{ "Dead ends", tostring(stats.fails) },
		{ "Restarts", tostring(stats.restarts) },
		{ "Hints used", tostring(stats.hints) },
		{ "Moves played", tostring(stats.moves) },
		{ "XP", tostring(progress.xp) },
		{ "Coins", tostring(progress.coins) },
	}
	local grid = make("Frame", {
		Name = "StatTiles",
		LayoutOrder = 1,
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = self.list,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.new(0.5, -5, 0, 58),
			CellPadding = UDim2.fromOffset(10, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for order, tile in ipairs(tiles) do
		local frame = make("Frame", {
			Name = tile[1],
			LayoutOrder = order,
			BackgroundColor3 = Theme.PanelRaised,
			Parent = grid,
		}, { corner(10) })
		local label = text({
			Text = string.upper(tile[1]),
			FontFace = Theme.FontBold,
			TextScaled = true,
			TextColor3 = Theme.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(10, 8),
			Size = UDim2.new(1, -20, 0, 14),
			Parent = frame,
		})
		make("UITextSizeConstraint", { MaxTextSize = 11, MinTextSize = 8, Parent = label })
		text({
			Name = "Value",
			Text = tile[2],
			FontFace = Theme.FontBold,
			TextSize = 20,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(10, 24),
			Size = UDim2.new(1, -20, 0, 26),
			Parent = frame,
		})
	end

	text({
		LayoutOrder = 2,
		Text = "ACHIEVEMENTS",
		FontFace = Theme.FontHeavy,
		TextSize = 14,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -8, 0, 20),
		Parent = self.list,
	})
	for order, achievement in ipairs(Achievements.list) do
		local earned = progress.achievements[achievement.id] == true
		-- Tall enough for the description to wrap onto a second line on a phone.
		local row = card(self, 2 + order, 62, achievement.id)
		row.BackgroundTransparency = if earned then 0 else 0.45
		text({
			Text = (if earned then "✓  " else "") .. achievement.name,
			FontFace = Theme.FontBold,
			TextSize = 15,
			TextColor3 = if earned then Theme.Gold else Theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(12, 8),
			Size = UDim2.new(1, -110, 0, 18),
			Parent = row,
		})
		text({
			Text = achievement.description,
			TextSize = 12,
			TextColor3 = Theme.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			Position = UDim2.fromOffset(12, 28),
			Size = UDim2.new(1, -110, 0, 28),
			Parent = row,
		})
		text({
			Text = string.format("%s%d coins", if earned then "" else "+", achievement.coins),
			TextSize = 13,
			TextColor3 = if earned then Theme.Legal else Theme.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.fromOffset(90, 18),
			Parent = row,
		})
	end
	text({
		LayoutOrder = 100,
		Text = "Coins will unlock board themes, piece skins and effects in a later update. They are cosmetic only and can't be bought.",
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -8, 0, 16),
		Parent = self.list,
	})
end

-- Settings -------------------------------------------------------------------------------

local function settingRow(self: any, order: number, name: string, label: string, sub: string): Frame
	local row = card(self, order, 72, name)
	text({
		Text = label,
		FontFace = Theme.FontBold,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(1, -160, 0, 22),
		Parent = row,
	})
	text({
		Name = "Sub",
		Text = sub,
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Position = UDim2.fromOffset(14, 36),
		Size = UDim2.new(1, -160, 0, 30),
		Parent = row,
	})
	return row
end

local function pill(parent: Instance, name: string, label: string, on: boolean, enabled: boolean): TextButton
	return make("TextButton", {
		Name = name,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(84, 44),
		BackgroundColor3 = if on then Theme.Legal else Theme.Panel,
		BackgroundTransparency = if enabled then 0 else 0.5,
		AutoButtonColor = enabled,
		FontFace = Theme.FontBold,
		Text = label,
		TextColor3 = if on then Theme.Background else Theme.Text,
		TextTransparency = if enabled then 0 else 0.5,
		TextSize = 16,
		Parent = parent,
	}, { corner(22) })
end

function PuzzleMenu._renderSettings(self: any)
	local settings = Sound.getSettings()
	local function change(values: { [string]: any })
		Sound.setSettings(values)
		self.handlers.settings(values)
		self:_render()
	end

	local soundRow = settingRow(self, 1, "SoundSetting", "Sound effects", "Moves, captures, wins and buttons")
	pill(soundRow, "SoundToggle", if settings.sound then "On" else "Off", settings.sound, true).Activated:Connect(function()
		change({ sound = not settings.sound })
		if not settings.sound then
			Sound.play("click") -- just turned on: let the player hear it
		end
	end)

	local percent = math.floor(settings.volume * 100 + 0.5)
	local volumeRow = settingRow(self, 2, "VolumeSetting", "Volume", string.format("%d%%", percent))
	local function stepper(name: string, label: string, x: number, delta: number)
		make("TextButton", {
			Name = name,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, x, 0.5, 0),
			Size = UDim2.fromOffset(52, 44),
			BackgroundColor3 = Theme.Panel,
			FontFace = Theme.FontBold,
			Text = label,
			TextColor3 = Theme.Text,
			TextSize = 22,
			Parent = volumeRow,
		}, { corner(10) }).Activated:Connect(function()
			local volume = math.clamp(math.floor((settings.volume + delta) * 10 + 0.5) / 10, 0, 1)
			settings.volume = volume
			Sound.setSettings({ volume = volume })
			self.handlers.settings({ volume = volume })
			-- Updated in place, not re-rendered: a rebuilt button under a still
			-- mouse misses the next click, so fast +/- presses were lost.
			local sub = volumeRow:FindFirstChild("Sub") :: TextLabel
			sub.Text = string.format("%d%%", math.floor(volume * 100 + 0.5))
			local fill = volumeRow:FindFirstChild("ProgressBar") and volumeRow.ProgressBar:FindFirstChild("Fill")
			if fill then
				fill.Size = UDim2.fromScale(volume, 1)
			end
		end)
	end
	stepper("VolumeDown", "-", -72, -0.1)
	stepper("VolumeUp", "+", -12, 0.1)
	progressBar(volumeRow, UDim2.new(0, 60, 0, 41), UDim2.new(1, -196, 0, 6), settings.volume, Theme.Accent)

	local supported = Sound.hapticsSupported()
	local hapticRow = settingRow(
		self,
		3,
		"HapticsSetting",
		"Vibration",
		if supported then "Short buzz on captures, wins and invalid moves" else "Not supported on this device"
	)
	local on = supported and settings.haptics
	pill(hapticRow, "HapticsToggle", if on then "On" elseif supported then "Off" else "N/A", on, supported).Activated:Connect(function()
		if supported then
			change({ haptics = not settings.haptics })
			if not settings.haptics then
				Sound.haptic("medium")
			end
		end
	end)
	local dragRow = settingRow(self, 4, "DragSetting", "Drag to move", "Drag your piece onto a square. Tapping always works.")
	pill(dragRow, "DragToggle", if self.dragEnabled then "On" else "Off", self.dragEnabled, true).Activated:Connect(function()
		change({ drag = not self.dragEnabled })
	end)

	local tutorialRow = settingRow(self, 5, "TutorialSetting", "Tutorial", "Replay the guided first puzzle")
	pill(tutorialRow, "ReplayTutorial", "Play", false, true).Activated:Connect(function()
		self.handlers.tutorial()
	end)

	text({
		LayoutOrder = 10,
		Text = "Settings are saved with your progress.",
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -8, 0, 18),
		Parent = self.list,
	})
end

-- Rendering --------------------------------------------------------------------------------

local NOTES = {
	Home = "",
	Journey = "Clear %d puzzles of a difficulty to unlock the next. First clears earn XP and coins. Clear within par for 3 stars.",
	Practice = "Play any puzzle at any difficulty. Hints are free. Practice earns no rewards or stars and doesn't unlock difficulties.",
	Daily = "A new puzzle every day at 00:00 UTC. One free hint and one reward per day.",
	Weekly = "Four puzzles, the same for everyone, new every Monday 00:00 UTC. One hint per attempt. Each reward is paid once.",
	Endless = "Generated boards, one after another, getting harder as you go. No undo or hints. A dead end or a restart costs a life.",
	Duel = "Opponents come from this server first, then from any server. Leaving a duel counts as a loss.",
	Stats = "Your numbers, as the server has them.",
	Settings = "",
}

local TITLES = {
	Home = "ECHO CHESS",
	Journey = "JOURNEY",
	Practice = "PRACTICE",
	Daily = "DAILY PUZZLE",
	Weekly = "WEEKLY CHALLENGE",
	Endless = "ENDLESS",
	Duel = "PUZZLE DUEL",
	Stats = "STATISTICS",
	Settings = "SETTINGS",
}

function PuzzleMenu._placeList(self: any)
	if not self.list then
		return
	end
	local top = 70
	if self.note.Visible then
		top = 66 + math.clamp(self.note.TextBounds.Y, 26, 56) + 16
	end
	self.list.Position = UDim2.fromOffset(12, top)
	self.list.Size = UDim2.new(1, -24, 1, -(top + 12))
end

function PuzzleMenu._render(self: any)
	local home = self.view == "Home"
	if self:isQueued() and self.view ~= "Duel" then
		-- While searching, the menu stays on the Duel page (Cancel leaves the queue).
		self.view = "Duel"
		home = false
	end
	-- Sidebar: the current page, what can be used now, and a dot on Duel
	-- while searching or when someone else is on this server to play.
	local queued = self:isQueued()
	self.sidebar:setSelected(self.view)
	for _, item in ipairs(NAV_ITEMS) do
		local usable = not queued or item.id == "Duel" or item.id == "Collapse"
		if item.id == "Play" then
			usable = self:_canClose()
		elseif item.id == "Tutorial" then
			usable = usable and self.progress ~= nil
		end
		self.sidebar:setEnabled(item.id, usable)
	end
	self.sidebar:setDot("Duel", queued or #Players:GetPlayers() > 1)
	self:_layout(true)
	self.home.Visible = home
	self.panel.Visible = not home
	if home then
		self.countdown = nil
		self.weeklyCountdown = nil
		self.queueLabel = nil
		self:_renderHome()
		return
	end
	self.homeTicking = nil

	self.backButton.Visible = not self:isQueued()
	self.title.Text = TITLES[self.view]
	self.title.Position = UDim2.fromOffset(if home then 18 else 66, 12)
	self.wallet.Position = UDim2.fromOffset(if home then 18 else 66, 40)
	self.closeButton.Visible = self:_canClose()

	-- On a narrow panel the wallet has little room, so drop the streak and
	-- shorten the offline note rather than letting the line get cut off.
	local tightWallet = self.panel.AbsoluteSize.X < 360
	local progress = self.progress
	local wallet = "Loading progress..."
	if progress then
		wallet = string.format("%d XP  ·  %d coins", progress.xp, progress.coins)
		if not tightWallet and progress.streak and progress.streak.current > 0 then
			wallet ..= string.format("  ·  🔥 %d", progress.streak.current)
		end
	end
	if self.saveStatus == "offline" then
		wallet ..= if tightWallet then "  ·  offline" else "  ·  not saving"
	end
	self.wallet.Text = wallet

	local note = string.format(NOTES[self.view], if progress then progress.unlockRequirement else GameConfig.UNLOCK_REQUIREMENT)
	self.note.Text = note
	self.note.Visible = note ~= ""
	self:_placeList()

	self.countdown = nil
	self.weeklyCountdown = nil
	self.queueLabel = nil
	for _, child in ipairs(self.list:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	if self.view == "Daily" then
		self:_renderDaily()
	elseif self.view == "Weekly" then
		self:_renderWeekly()
	elseif self.view == "Endless" then
		self:_renderEndless()
	elseif self.view == "Duel" then
		self:_renderDuel()
	elseif self.view == "Stats" then
		self:_renderStats()
	elseif self.view == "Settings" then
		self:_renderSettings()
	else
		for index, difficulty in ipairs(GameConfig.DIFFICULTIES) do
			difficultyRow(self, index, difficulty, index)
		end
	end
end

return PuzzleMenu
