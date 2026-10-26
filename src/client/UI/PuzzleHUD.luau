--!strict
-- PuzzleHUD: the puzzle screen. Builds the GUI, renders server snapshots and
-- turns clicks/taps into move intents. Legal-move highlights are computed
-- locally with the shared rules purely for display; the server re-validates
-- every move and its snapshot is always what gets drawn.
--
-- Input: tap your piece, then tap a square; or (when the drag setting is on)
-- drag your piece onto a square. A press only becomes a drag after it moves
-- InputRules.DRAG_THRESHOLD pixels, and taps right after a drag are ignored,
-- so one press is never read as both. Leaving an attempt with moves in it
-- (Restart, the puzzle arrows, starting another puzzle) asks first.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoardState = require(Shared:WaitForChild("BoardState"))
local ChessRules = require(Shared:WaitForChild("ChessRules"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local InputRules = require(Shared:WaitForChild("InputRules"))
local PuzzleDefinitions = require(Shared:WaitForChild("PuzzleDefinitions"))
local TutorialFlow = require(Shared:WaitForChild("TutorialFlow"))

local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))
local Sound = require(script.Parent.Parent:WaitForChild("SoundController"))
local ConfirmDialog = require(script.Parent:WaitForChild("ConfirmDialog"))
local Decor = require(script.Parent:WaitForChild("Decor"))
local PieceArt = require(script.Parent:WaitForChild("PieceArt"))
local PlayDesk = require(script.Parent:WaitForChild("PlayDesk"))
local PuzzleMenu = require(script.Parent:WaitForChild("PuzzleMenu"))
local Theme = require(script.Parent:WaitForChild("Theme"))
local TutorialCoach = require(script.Parent:WaitForChild("TutorialCoach"))

export type Handlers = {
	move: (from: number, to: number) -> (),
	undo: () -> (),
	restart: () -> (),
	hint: () -> (),
	start: (puzzleId: string, mode: string) -> (),
	settings: (values: { [string]: any }) -> (),
	tutorial: (outcome: string) -> (),
	sync: () -> (),
	duelJoin: () -> (),
	duelCancel: () -> (),
	duelLeave: () -> (),
	duelExit: () -> (),
}

local PLAY_MODES = GameConfig.PLAY_MODES
local DUEL_MODE = GameConfig.DUEL_MODE

local PIECE_NAMES = ChessRules.PIECE_NAMES

local ERROR_MESSAGES = {
	illegal_move = "Your %s can't reach that square.",
	not_your_piece = "You can only move your white piece.",
	not_playing = "This attempt is over. Undo or restart.",
	rate_limited = "Too fast! Give it a moment.",
	cannot_undo = "Nothing to undo.",
	unknown_puzzle = "That puzzle isn't available.",
	bad_square = "That move wasn't accepted.",
	locked = "That difficulty is still locked. Clear more puzzles to open it.",
	not_daily = "That isn't today's Daily Puzzle.",
	bad_mode = "That mode isn't available.",
	no_hints = "No hints left for this puzzle.",
	bad_tutorial = "That wasn't accepted.",
	not_weekly = "That puzzle isn't in this week's challenge.",
	in_duel = "Finish or leave your duel first.",
	not_started = "Wait for the countdown.",
	match_over = "The duel is over.",
	not_in_duel = "You're not in a duel.",
	already_queued = "You're already looking for an opponent.",
	not_queued = "You're not in the duel queue.",
	bad_action = "That action isn't available in a duel.",
	matching = "Matching you with an opponent, one moment.",
	teleport_failed = "Couldn't move you to the match server. Try again.",
	opponent_missing = "Your opponent didn't make it to the match. Try again.",
}

-- Duel result lines, by the server's reason.
local DUEL_REASONS = {
	solved = "You cleared the board first.",
	opponent_solved = "%s cleared the board first.",
	timeout = "Time's up. Nobody cleared the board.",
	opponent_left = "%s left the match.",
	left = "You left the match.",
}

local DUEL_REWARD_NOTES = {
	same_opponent = "No reward: you already earned one against this player today.",
	daily_cap = "No reward: today's rewarded duels are used up.",
}

-- True while a duel snapshot is on screen but its board isn't live yet (or anymore).
local function duelLocked(snap: any): boolean
	return snap ~= nil and snap.duel ~= nil and snap.duel.phase ~= "playing"
end

local MARGIN = 12
local GAP = 10
local HEADER_HEIGHT = 70
local STATS_HEIGHT = 62
local MESSAGE_HEIGHT = 52
local CONTROLS_HEIGHT = 54
local COACH_HEIGHT = 100 -- the tutorial card takes the message's place while shown
local MAX_COLUMN_WIDTH = 720

local PuzzleHUD = {}
PuzzleHUD.__index = PuzzleHUD

-- Instance helper: make("Frame", { props }, { children })
local function make(className: string, props: { [string]: any }?, children: { Instance }?): any
	local instance = Instance.new(className)
	for key, value in pairs(props or {}) do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	for _, childInstance in ipairs(children or {}) do
		childInstance.Parent = instance
	end
	if props and props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local function corner(radius: number): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function round(): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0.5, 0) })
end

local function stroke(color: Color3, thickness: number, transparency: number?): UIStroke
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function label(props: { [string]: any }): TextLabel
	local defaults = {
		BackgroundTransparency = 1,
		FontFace = Theme.Font,
		TextColor3 = Theme.Text,
		TextSize = 16,
		TextWrapped = true,
		Text = "",
	}
	for key, value in pairs(props) do
		defaults[key] = value
	end
	return make("TextLabel", defaults)
end

local function button(text: string, primary: boolean): TextButton
	local b = make("TextButton", {
		Size = UDim2.new(0, 150, 1, 0),
		BackgroundColor3 = if primary then Theme.Accent else Theme.PanelRaised,
		AutoButtonColor = true,
		FontFace = Theme.FontBold,
		Text = text,
		TextColor3 = Theme.Text,
		TextSize = 18,
	}, {
		corner(12),
		stroke(if primary then Theme.AccentPressed else Theme.Stroke, 1.5, if primary then 0 else 0.3),
	})
	Decor.sheen(b, if primary then 0.2 else 0.16)
	return b
end

-- Bottom-row button: shares the row's width but never grows past MaxSize.
local function controlButton(text: string, primary: boolean): TextButton
	local b = button(text, primary)
	b.Size = UDim2.new(1 / 3, -8, 1, 0)
	make("UISizeConstraint", { MaxSize = Vector2.new(170, math.huge), Parent = b })
	return b
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function article(word: string): string
	return if string.find(word, "^[AEIOU]") then "an " .. word else "a " .. word
end

function PuzzleHUD.new(playerGui: Instance, handlers: Handlers)
	local self = setmetatable({}, PuzzleHUD) :: any
	self.handlers = handlers
	self.snapshot = nil
	self.board = nil
	self.playerSquare = nil
	self.selected = nil
	self.legal = {}
	self.pending = false
	self.squares = {}
	self.receivedAt = os.clock()
	self.dragEnabled = GameConfig.DEFAULT_SETTINGS.drag
	self.press = nil -- the board press being tracked for a drag
	self.dragEndedAt = 0
	self.tutorial = nil -- { state: TutorialFlow.State, awaitingStart: boolean }
	Sound.init()
	self.dialog = ConfirmDialog.new(playerGui)
	self:_build(playerGui)
	self.menu = PuzzleMenu.new(playerGui, {
		start = function(puzzleId: string, mode: string)
			if self.tutorialDue and mode == PLAY_MODES.Journey then
				-- A new player's first Journey puzzle is the tutorial.
				self:startTutorial()
				return
			end
			self:_confirmLeave(function()
				self.handlers.start(puzzleId, mode)
			end)
		end,
		play = function()
			if self.tutorialDue then
				self:startTutorial()
			else
				self.menu:close()
			end
		end,
		settings = function(values: { [string]: any })
			-- Once the player changes a setting, this session keeps their choice.
			self.settingsTouched = true
			if type(values.drag) == "boolean" then
				self:_setDrag(values.drag)
			end
			self.handlers.settings(values)
		end,
		tutorial = function()
			self:_confirmLeave(function()
				self:startTutorial()
			end)
		end,
		-- The puzzle behind the menu is kept on the server and comes back
		-- after the duel, so joining needs no confirmation.
		duelJoin = function()
			self.handlers.duelJoin()
		end,
		duelCancel = function()
			self.handlers.duelCancel()
		end,
	})
	self.menu.dragEnabled = self.dragEnabled
	UserInputService.InputChanged:Connect(function(input)
		self:_pressMoved(input)
	end)
	UserInputService.InputEnded:Connect(function(input)
		self:_pressEnded(input)
	end)
	for _, name in ipairs({ "EchoChessHUD", "EchoChessResult", "EchoChessMenu", "EchoChessDialog", "EchoChessPlayNav" }) do
		Sound.watchButtons(playerGui:WaitForChild(name))
	end
	-- The home screen is the first thing a player sees; it shows a loading
	-- state until the server's first snapshot arrives.
	self.menu:open("Home")

	RunService.Heartbeat:Connect(function()
		self:_updateTimer()
	end)
	return self
end

function PuzzleHUD._build(self: any, playerGui: Instance)
	-- Full-bleed background (ignores the top bar inset).
	local backdrop = make("ScreenGui", {
		Name = "EchoChessBackdrop",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 0,
		Parent = playerGui,
	})
	Decor.backdrop(backdrop)

	local gui = make("ScreenGui", {
		Name = "EchoChessHUD",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 1,
		Parent = playerGui,
	})
	self.gui = gui

	-- Children are placed by _layout() from the container's size, so the
	-- screen can switch between a stacked (portrait/desktop) and a
	-- side-by-side (short landscape, e.g. phones) arrangement.
	local container = make("Frame", {
		Name = "Container",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = gui,
	})
	self.container = container

	-- Header: brand, puzzle name, difficulty and puzzle switcher.
	local header = make("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		BackgroundTransparency = 1,
		Parent = container,
	})
	self.brandLabel = label({
		Text = "ECHO CHESS",
		FontFace = Theme.FontHeavy,
		TextSize = 13,
		TextColor3 = Color3.new(1, 1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -160, 0, 18),
		Parent = header,
	})
	Decor.goldText(self.brandLabel)
	self.titleLabel = label({
		FontFace = Theme.FontBold,
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextWrapped = false,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, -160, 0, 34),
		Parent = header,
	})
	self.difficultyPill = make("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.fromOffset(150, 22),
		BackgroundColor3 = Theme.PanelRaised,
		FontFace = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Background,
		Parent = header,
	}, { round() })
	local switcher = make("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 26),
		Size = UDim2.fromOffset(150, 44),
		BackgroundTransparency = 1,
		Parent = header,
	})
	local prev = button("<", false)
	prev.Name = "PrevPuzzle"
	prev.Size = UDim2.fromOffset(44, 44)
	prev.Parent = switcher
	local nextButton = button(">", false)
	nextButton.Name = "NextPuzzle"
	nextButton.AnchorPoint = Vector2.new(1, 0)
	nextButton.Position = UDim2.fromScale(1, 0)
	nextButton.Size = UDim2.fromOffset(44, 44)
	nextButton.Parent = switcher
	local menuButton = button("Menu", false)
	menuButton.Name = "MenuButton"
	menuButton.Position = UDim2.fromOffset(48, 0)
	menuButton.Size = UDim2.new(1, -96, 1, 0)
	menuButton.TextSize = 14
	menuButton.Parent = switcher
	menuButton.Activated:Connect(function()
		local snap = self.snapshot
		if snap and snap.duel and snap.duel.phase ~= "finished" then
			self:_confirmForfeit()
			return
		end
		self.menu:open("Home")
	end)
	self.menuButton = menuButton
	self.prevButton, self.nextButton = prev, nextButton
	prev.Activated:Connect(function()
		self:_confirmLeave(function()
			self:_switchPuzzle(-1)
		end)
	end)
	nextButton.Activated:Connect(function()
		self:_confirmLeave(function()
			self:_switchPuzzle(1)
		end)
	end)

	-- Stats: moves, captured progress, time.
	local stats = make("Frame", {
		Name = "Stats",
		Size = UDim2.new(1, 0, 0, STATS_HEIGHT),
		BackgroundTransparency = 1,
		Parent = container,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 10),
		}),
	})
	local function statCard(order: number, title: string): (Frame, TextLabel, TextLabel, TextLabel)
		local card = make("Frame", {
			LayoutOrder = order,
			Size = UDim2.new(1 / 3, -7, 1, 0),
			BackgroundColor3 = Theme.Panel,
			Parent = stats,
		}, { corner(12), stroke(Theme.Stroke, 1, 0.35) })
		Decor.sheen(card, 0.22)
		local heading = label({
			Text = title,
			TextSize = 12,
			FontFace = Theme.FontBold,
			TextColor3 = Theme.TextMuted,
			Position = UDim2.fromOffset(12, 8),
			Size = UDim2.new(1, -24, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = card,
		})
		local value = label({
			FontFace = Theme.FontBold,
			TextSize = 22,
			Position = UDim2.fromOffset(12, 24),
			Size = UDim2.new(1, -24, 0, 28),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = card,
		})
		local sub = label({
			TextSize = 13,
			TextColor3 = Theme.TextMuted,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 30),
			Size = UDim2.new(0.5, 0, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = card,
		})
		return card, value, sub, heading
	end
	local _, movesValue, parLabel = statCard(1, "MOVES")
	local capturedCard, capturedValue, _ = statCard(2, "CAPTURED")
	local _, timeValue, _, timeTitle = statCard(3, "TIME")
	self.timeTitle = timeTitle
	self.movesValue, self.parLabel = movesValue, parLabel
	self.capturedValue, self.timeValue = capturedValue, timeValue
	local track = make("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -8),
		Size = UDim2.new(1, -24, 0, 4),
		BackgroundColor3 = Theme.PanelRaised,
		BorderSizePixel = 0,
		Parent = capturedCard,
	}, { round() })
	self.progressFill = make("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Legal,
		BorderSizePixel = 0,
		Parent = track,
	}, { round() })

	-- Board area takes whatever height is left.
	local boardArea = make("Frame", {
		Name = "BoardArea",
		BackgroundTransparency = 1,
		Parent = container,
	})
	self.boardFrame = make("Frame", {
		Name = "Board",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = boardArea,
	})
	Decor.boardFrame(self.boardFrame) -- rim and shadow sit under the layers below
	-- Large screens get the desktop dress around the board (PlayDesk).
	self.desk = PlayDesk.new(playerGui, container, {
		nav = function(id: string)
			self:_deskNav(id)
		end,
		switch = function(offset: number)
			self:_confirmLeave(function()
				self:_switchPuzzle(offset)
			end)
		end,
		openView = function(view: string)
			self:_deskNav(view)
		end,
	})
	self.desk:attachBoard(self.boardFrame)
	self.aspect = make("UIAspectRatioConstraint", {
		AspectRatio = 1,
		AspectType = Enum.AspectType.FitWithinMaxSize,
		Parent = self.boardFrame,
	})
	self.squareLayer = make("Frame", {
		Name = "Squares",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = self.boardFrame,
	})
	self.pieceLayer = make("Frame", {
		Name = "Pieces",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 4,
		Parent = self.boardFrame,
	})

	-- Duel countdown: a big number over the board.
	self.countdownLabel = label({
		Name = "Countdown",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 0.5),
		FontFace = Theme.FontHeavy,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.4,
		Visible = false,
		ZIndex = 20,
		Parent = boardArea,
	})
	make("UITextSizeConstraint", { MaxTextSize = 140, Parent = self.countdownLabel })
	Decor.goldText(self.countdownLabel)

	self.messageLabel = label({
		Name = "Message",
		TextSize = 16,
		TextColor3 = Theme.TextMuted,
		Parent = container,
	})

	local controls = make("Frame", {
		Name = "Controls",
		BackgroundTransparency = 1,
		Parent = container,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 12),
		}),
	})
	self.undoButton = controlButton("↩  Undo", false)
	self.undoButton.Name = "UndoButton"
	self.undoButton.LayoutOrder = 1
	self.undoButton.Parent = controls
	self.undoButton.Activated:Connect(function()
		if self.snapshot and self.snapshot.canUndo and not self.pending then
			self.pending = true
			self.handlers.undo()
		end
	end)
	self.hintButton = controlButton("💡  Hint", false)
	self.hintButton.Name = "HintButton"
	self.hintButton.LayoutOrder = 2
	self.hintButton.Parent = controls
	self.hintButton.Activated:Connect(function()
		local snap = self.snapshot
		if snap and snap.status ~= "won" and not snap.duel and not self.pending then
			self.handlers.hint()
		end
	end)
	local restartButton = controlButton("🔄  Restart", true)
	restartButton.Name = "RestartButton"
	restartButton.LayoutOrder = 3
	restartButton.Parent = controls
	restartButton.Activated:Connect(function()
		self:_confirmRestart()
	end)

	self.coach = TutorialCoach.new(container, {
		skip = function()
			self:_tutorialEvent("skip")
		end,
		next = function()
			self:_tutorialEvent("next")
		end,
	})

	self.parts = {
		header = header,
		stats = stats,
		boardArea = boardArea,
		message = self.messageLabel,
		controls = controls,
		coach = self.coach.frame,
	}
	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_layout()
	end)
	gui:GetAttributeChangedSignal("SimulatedSize"):Connect(function()
		self:_layout()
	end)
	self:_layout()

	-- The result card gets its own full-bleed ScreenGui so the dim covers the top bar too.
	self:_buildResultCard(make("ScreenGui", {
		Name = "EchoChessResult",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 2,
		Parent = playerGui,
	}))
end

function PuzzleHUD._buildResultCard(self: any, gui: ScreenGui)
	local dim = make("TextButton", {
		Name = "ResultOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.4,
		AutoButtonColor = false,
		Text = "",
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	})
	dim:SetAttribute("Silent", true)
	-- The card grows with its lines (AutomaticSize) and is scaled down to fit
	-- short screens (see _fitResultCard).
	local card = make("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		ZIndex = 11,
		Parent = dim,
	}, {
		corner(18),
		make("UISizeConstraint", { MaxSize = Vector2.new(420, math.huge) }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, 22),
			PaddingBottom = UDim.new(0, 20),
			PaddingLeft = UDim.new(0, 20),
			PaddingRight = UDim.new(0, 20),
		}),
		make("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 8),
		}),
	})
	local cardStroke = stroke(Theme.Gold, 2)
	cardStroke.Parent = card
	Decor.sheen(card, 0.3)
	local cardScale = make("UIScale", { Parent = card })
	local function line(order: number, name: string, props: { [string]: any }): TextLabel
		local defaults: { [string]: any } = {
			Name = name,
			LayoutOrder = order,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			ZIndex = 12,
			Parent = card,
		}
		for key, value in pairs(props) do
			defaults[key] = value
		end
		return label(defaults)
	end
	local title = line(1, "Title", { FontFace = Theme.FontHeavy, TextSize = 30 })
	local titleGradient = make("UIGradient", { Parent = title })
	local stars = line(2, "Stars", { FontFace = Theme.FontBold, TextSize = 38, TextColor3 = Theme.Gold })
	local subtitle = line(3, "Subtitle", { TextSize = 15, TextColor3 = Theme.TextMuted })
	local statsLine = line(4, "Stats", { FontFace = Theme.FontBold, TextSize = 18 })
	local detail = line(5, "Detail", { TextSize = 13, TextColor3 = Theme.TextMuted })
	local rewardLine =
		line(6, "Reward", { FontFace = Theme.FontBold, TextSize = 15, TextColor3 = Theme.Legal, RichText = true })
	local banner = make("TextLabel", {
		Name = "UnlockBanner",
		LayoutOrder = 7,
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = Theme.Gold,
		FontFace = Theme.FontHeavy,
		TextSize = 17,
		TextColor3 = Theme.Background,
		Visible = false,
		ZIndex = 12,
		Parent = card,
	}, { corner(12) })
	local bannerScale = make("UIScale", { Parent = banner })
	local progressLine = line(8, "Progress", { TextSize = 14, TextColor3 = Theme.Text })
	local buttons = make("Frame", {
		Name = "Buttons",
		LayoutOrder = 9,
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundTransparency = 1,
		ZIndex = 12,
		Parent = card,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 12),
		}),
	})
	local primary = button("", true)
	primary.Name = "PrimaryButton"
	primary.LayoutOrder = 1
	primary.Size = UDim2.new(0.5, -6, 1, 0)
	primary.ZIndex = 12
	primary.Parent = buttons
	local secondary = button("", false)
	secondary.Name = "SecondaryButton"
	secondary.LayoutOrder = 2
	secondary.Size = UDim2.new(0.5, -6, 1, 0)
	secondary.ZIndex = 12
	secondary.Parent = buttons

	primary.Activated:Connect(function()
		local snap = self.snapshot
		if not snap then
			return
		end
		if snap.duel and snap.duel.phase == "finished" then
			self.handlers.duelJoin()
		elseif snap.status == "won" then
			local _, action = self:_nextAfterWin()
			action()
		elseif snap.status == "failed" then
			self.pending = true
			self.handlers.undo()
		end
	end)
	secondary.Activated:Connect(function()
		local snap = self.snapshot
		if snap and snap.duel and snap.duel.phase == "finished" then
			self.handlers.duelExit()
			return
		end
		self.handlers.restart()
	end)

	self.result = {
		gui = gui,
		dim = dim,
		card = card,
		stroke = cardStroke,
		scale = cardScale,
		fit = 1,
		title = title,
		gradient = titleGradient,
		stars = stars,
		subtitle = subtitle,
		stats = statsLine,
		detail = detail,
		reward = rewardLine,
		banner = banner,
		bannerScale = bannerScale,
		progress = progressLine,
		primary = primary,
		secondary = secondary,
	}
end

-- Scale the card down when its natural height doesn't fit the screen
-- (phones in landscape).
function PuzzleHUD._fitResultCard(self: any)
	local r = self.result
	local natural = r.card.AbsoluteSize.Y / math.max(r.scale.Scale, 0.01)
	local available = r.dim.AbsoluteSize.Y - 24
	r.fit = if natural > 0 and available > 0 then math.min(1, available / natural) else 1
end

-- Layout -----------------------------------------------------------------------

local function place(frame: GuiObject, x: number, y: number, w: number, h: number)
	frame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	frame.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
end

-- Short, wide screens (phones in landscape) put the board on the left and the
-- panels in a column on the right; everything else stacks vertically.
function PuzzleHUD._layout(self: any)
	-- In Studio a "SimulatedSize" attribute (Vector2) on the HUD lays it out
	-- for another screen size, for layout checks.
	local simulated = if RunService:IsStudio() then self.gui:GetAttribute("SimulatedSize") else nil
	if typeof(simulated) ~= "Vector2" then
		simulated = nil
	end
	local screen = simulated or self.gui.AbsoluteSize
	if screen.X <= 0 or screen.Y <= 0 then
		return
	end
	local p = self.parts
	local desk = PlayDesk.fits(screen)
	if desk ~= self.desk.visible then
		self.desk:setVisible(desk)
		for _, coord in ipairs(self.innerCoords or {}) do
			coord.Visible = not desk
		end
	end
	p.header.Visible = not desk
	if desk then
		local sidebarW = self.desk:sidebarWidth(screen.X, GuiService:GetGuiInset().Y)
		self.container.Size = if simulated
			then UDim2.fromOffset(screen.X - sidebarW, screen.Y)
			else UDim2.new(1, -sidebarW, 1, 0)
		self.container.Position = UDim2.new(0.5, sidebarW / 2, 0.5, 0)
		self.layoutMode = "desk"
		local coaching = p.coach.Visible
		p.message.Visible = not coaching
		p.stats.Visible = false
		local rects = self.desk:layout(screen.X - sidebarW, screen.Y, coaching)
		place(p.boardArea, rects.board.x, rects.board.y, rects.board.w, rects.board.h)
		place(p.coach, rects.coach.x, rects.coach.y, rects.coach.w, rects.coach.h)
		place(p.message, rects.message.x, rects.message.y, rects.message.w, rects.message.h)
		place(p.controls, rects.controls.x, rects.controls.y, rects.controls.w, rects.controls.h)
		if self.snapshot then
			self:_renderHighlights()
		end
		return
	end
	self.container.Size = if simulated then UDim2.fromOffset(screen.X, screen.Y) else UDim2.fromScale(1, 1)
	self.container.Position = UDim2.fromScale(0.5, 0.5)
	local size = self.container.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	local w = size.X - MARGIN * 2
	local h = size.Y - MARGIN * 2
	local wide = size.X >= size.Y * 1.3 and size.Y < 640
	self.layoutMode = if wide then "wide" else "tall"
	-- The tutorial card replaces the message line while it is shown.
	local coaching = p.coach.Visible
	p.message.Visible = not coaching
	p.stats.Visible = true
	local messageHeight = if coaching then COACH_HEIGHT else MESSAGE_HEIGHT
	if wide then
		local sideW = math.clamp(w * 0.4, 260, 380)
		local boardW = math.min(h, w - sideW - GAP * 2)
		local x = MARGIN + (w - (boardW + GAP * 2 + sideW)) / 2
		local sx = x + boardW + GAP * 2
		place(p.boardArea, x, MARGIN, boardW, h)
		place(p.header, sx, MARGIN, sideW, HEADER_HEIGHT)
		place(p.stats, sx, MARGIN + HEADER_HEIGHT + GAP, sideW, STATS_HEIGHT)
		local messageY = MARGIN + HEADER_HEIGHT + STATS_HEIGHT + GAP * 2
		local messageSpace = h + MARGIN - CONTROLS_HEIGHT - GAP - messageY
		place(p.message, sx, messageY, sideW, messageSpace)
		if coaching and messageSpace < COACH_HEIGHT then
			-- Short landscape screens: the card also takes the stats row
			-- while the tutorial runs, so its text has room.
			local statsY = MARGIN + HEADER_HEIGHT + GAP
			p.stats.Visible = false
			place(p.coach, sx, statsY, sideW, math.min(messageY + messageSpace - statsY, 160))
		else
			place(p.coach, sx, messageY, sideW, math.clamp(messageSpace, 64, 130))
		end
		place(p.controls, sx, MARGIN + h - CONTROLS_HEIGHT, sideW, CONTROLS_HEIGHT)
	else
		local cw = math.min(w, MAX_COLUMN_WIDTH)
		local x = MARGIN + (w - cw) / 2
		local boardY = MARGIN + HEADER_HEIGHT + STATS_HEIGHT + GAP * 2
		local bottom = MARGIN + h
		place(p.header, x, MARGIN, cw, HEADER_HEIGHT)
		place(p.stats, x, MARGIN + HEADER_HEIGHT + GAP, cw, STATS_HEIGHT)
		place(p.controls, x, bottom - CONTROLS_HEIGHT, cw, CONTROLS_HEIGHT)
		place(p.message, x, bottom - CONTROLS_HEIGHT - GAP - MESSAGE_HEIGHT, cw, MESSAGE_HEIGHT)
		place(p.coach, x, bottom - CONTROLS_HEIGHT - GAP - COACH_HEIGHT, cw, COACH_HEIGHT)
		place(p.boardArea, x, boardY, cw, bottom - CONTROLS_HEIGHT - messageHeight - GAP * 3 - boardY)
	end
	if self.snapshot then
		-- Ring thickness depends on the square size.
		self:_renderHighlights()
	end
end

-- Board construction ---------------------------------------------------------

function PuzzleHUD._squareRect(self: any, index: number): (UDim2, UDim2)
	local board = self.board
	local col, row = BoardState.toCoord(board, index)
	return UDim2.fromScale((col - 1) / board.width, (board.height - row) / board.height),
		UDim2.fromScale(1 / board.width, 1 / board.height)
end

local function addHatch(square: GuiObject)
	local group = make("CanvasGroup", {
		Name = "Hatch",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.BlockedBase,
		BorderSizePixel = 0,
		Parent = square,
	})
	for _, rotation in ipairs({ 45, -45 }) do
		for k = -3, 3 do
			make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5 + k * 0.25, 0.5),
				Size = UDim2.fromScale(1.8, 0.06),
				Rotation = rotation,
				BackgroundColor3 = Theme.BlockedHatch,
				BackgroundTransparency = 0.25,
				BorderSizePixel = 0,
				Parent = group,
			})
		end
	end
end

function PuzzleHUD._buildSquares(self: any)
	self.squareLayer:ClearAllChildren()
	self.squares = {}
	self.innerCoords = {}
	local board = self.board
	self.desk:setBoardSize(board.width, board.height)
	self.aspect.AspectRatio = board.width / board.height
	for index = 1, board.width * board.height do
		local col, row = BoardState.toCoord(board, index)
		local isDark = (col + row) % 2 == 0
		local base = if isDark then Theme.SquareDark else Theme.SquareLight
		-- Walls keep their coordinates too, in light text over the hatching.
		local coordColor = if board.blocked[index]
			then Theme.Text
			elseif isDark then Theme.SquareLight
			else Theme.SquareDark
		local position, size = self:_squareRect(index)
		local square = make("TextButton", {
			Name = BoardState.squareName(board, index),
			Position = position,
			Size = size,
			BackgroundColor3 = base,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Parent = self.squareLayer,
		})
		Decor.sheen(square, 0.09)
		if board.blocked[index] then
			addHatch(square)
		end
		local tint = make("Frame", {
			Name = "Tint",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.LastMove,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = square,
		})
		local dot = make("Frame", {
			Name = "Dot",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.28, 0.28),
			BackgroundColor3 = Theme.Legal:Lerp(Color3.new(0, 0, 0), 0.25),
			BackgroundTransparency = 0.2,
			Visible = false,
			ZIndex = 3,
			Parent = square,
		}, { round() })
		local ringStroke = stroke(Theme.Legal, 4)
		local ring = make("Frame", {
			Name = "Ring",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.86, 0.86),
			BackgroundTransparency = 1,
			Visible = false,
			ZIndex = 3,
			Parent = square,
		}, { round(), ringStroke })
		if col == 1 then
			table.insert(self.innerCoords, label({
				Name = "Coord",
				Visible = not self.desk.visible,
				Text = tostring(row),
				FontFace = Theme.FontBold,
				TextSize = 12,
				TextColor3 = coordColor,
				Position = UDim2.fromOffset(4, 2),
				Size = UDim2.fromOffset(14, 14),
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 2,
				Parent = square,
			}))
		end
		if row == 1 then
			table.insert(self.innerCoords, label({
				Name = "Coord",
				Visible = not self.desk.visible,
				Text = string.sub("abcdefgh", col, col),
				FontFace = Theme.FontBold,
				TextSize = 12,
				TextColor3 = coordColor,
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -4, 1, -2),
				Size = UDim2.fromOffset(14, 14),
				TextXAlignment = Enum.TextXAlignment.Right,
				ZIndex = 2,
				Parent = square,
			}))
		end
		square:SetAttribute("Silent", true) -- squares play their own sounds
		square.Activated:Connect(function()
			self:_onSquare(index)
		end)
		square.InputBegan:Connect(function(input)
			self:_pressBegan(index, input)
		end)
		self.squares[index] = { button = square, tint = tint, dot = dot, ring = ring, ringStroke = ringStroke }
	end
end

function PuzzleHUD._pieceFrame(self: any, index: number, kind: string, color: "white" | "black"): Frame
	local position, size = self:_squareRect(index)
	local holder = make("Frame", {
		Name = BoardState.squareName(self.board, index),
		Position = position,
		Size = size,
		BackgroundTransparency = 1,
		Parent = self.pieceLayer,
	})
	local art = PieceArt.create(kind, color)
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, 0.52)
	art.Size = UDim2.fromScale(0.84, 0.84)
	art.ZIndex = 3
	art.Parent = holder
	Decor.pieceShadow(art)
	make("UIScale", { Parent = holder })
	return holder
end

-- Rendering ------------------------------------------------------------------------

function PuzzleHUD.render(self: any, snap: any)
	local previous = self.snapshot
	if snap.mode == DUEL_MODE then
		if not snap.layout then
			-- Queue states have no board: they live in the menu's Duel page.
			self.menu:updateDuel(snap)
			if snap.duel.phase == "queued" then
				self.result.dim.Visible = false
				self.countdownLabel.Visible = false
				if not self.menu:isOpen() or self.menu.view ~= "Duel" then
					self.menu:open("Duel")
				end
			elseif previous and previous.mode == DUEL_MODE then
				-- Back from the queue: fetch the puzzle that was left behind.
				self.handlers.sync()
			end
			if snap.error then
				Sound.play("invalid")
			end
			return
		end
		if
			snap.event == "duel_opponent"
			and previous
			and previous.duel
			and previous.duel.matchId == snap.duel.matchId
		then
			-- Only the opponent's progress changed; don't redraw (or interrupt a drag).
			previous.duel.opponent = snap.duel.opponent
			self:_renderDuelMessage(previous)
			return
		end
		if snap.event == "duel_found" then
			self.menu:close()
			Sound.play("unlock")
			Sound.haptic("medium")
		elseif snap.event == "duel_start" then
			Sound.play("hint")
			Sound.haptic("light")
		end
	end
	self.menu:updateDuel(nil)
	local newPuzzle = not previous or previous.puzzleId ~= snap.puzzleId or snap.event == "start"
	-- Only the winning move's snapshot carries the rating and reward. A later
	-- snapshot for the same finished attempt (tutorial saved, settings, a
	-- rejected request) keeps them, so the win card doesn't lose its lines.
	if
		snap.status == "won"
		and snap.event ~= "move"
		and not newPuzzle
		and previous.status == "won"
		and snap.result == nil
	then
		snap.result = previous.result
		snap.reward = snap.reward or previous.reward
	end
	self.snapshot = snap
	self.receivedAt = os.clock()
	self.pending = false
	-- A new snapshot redraws the pieces, so a drag in progress ends here.
	self.press = nil
	self.board = BoardState.fromLayout(snap.layout)
	self.playerSquare = BoardState.findPlayer(self.board)

	if newPuzzle or #self.squares ~= self.board.width * self.board.height then
		self:_buildSquares()
	end

	if snap.status == "playing" and (snap.event == "move" or snap.event == "undo") then
		self.selected = self.playerSquare
	elseif snap.event == "start" or snap.status ~= "playing" then
		self.selected = nil
	end
	if duelLocked(snap) then
		self.selected = nil
		self:_cancelDrag()
	end

	if snap.progress and snap.progress.settings and not self.settingsTouched then
		Sound.setSettings(snap.progress.settings)
		if type(snap.progress.settings.drag) == "boolean" then
			self:_setDrag(snap.progress.settings.drag)
		end
	end
	self.menu:update(snap)
	self:_renderHeader(snap)
	self:_renderPieces(snap)
	self.droppedOn = nil
	self:_renderHighlights()
	self:_renderMessage(snap)
	self:_feedback(snap)
	self:_trackTutorial(snap)
	self:_renderResult(snap, previous)
end

-- Sound, haptics and the hint highlight for one snapshot. Each snapshot
-- arrives once, so each event plays once.
function PuzzleHUD._feedback(self: any, snap: any)
	if snap.error then
		Sound.play("invalid")
		Sound.haptic("light")
		return
	end
	if snap.event == "hint" then
		Sound.play("hint")
		local square = snap.hintSquare and self.squares[snap.hintSquare]
		if square then
			Anim.flash(square.button, Theme.Selected, 0.7)
			task.delay(0.75, function()
				if square.button.Parent then
					Anim.flash(square.button, Theme.Selected, 0.7)
				end
			end)
		end
	elseif snap.event == "move" then
		if snap.status == "failed" then
			Sound.play("fail")
			Sound.haptic("medium")
		elseif snap.lastMove and snap.lastMove.capturedKind then
			Sound.play("capture")
			Sound.haptic("light")
		else
			Sound.play("move")
		end
	elseif snap.event == "undo" then
		Sound.play("move")
	end
end

function PuzzleHUD._renderHeader(self: any, snap: any)
	self.titleLabel.Text = snap.name
	self.difficultyPill.BackgroundColor3 = Theme.DifficultyColors[snap.difficulty] or Theme.PanelRaised
	local group = PuzzleDefinitions.byDifficulty[snap.difficulty]
	self.difficultyPill.Text = string.format("%s  %d/%d", string.upper(snap.difficulty), snap.number or 1, if group then #group else 1)
	-- Narrow headers (phones) only have room for the mode name.
	local mode = if snap.mode == DUEL_MODE then "PUZZLE DUEL" else string.upper(snap.mode or PLAY_MODES.Journey)
	self.brandLabel.Text = if self.parts.header.AbsoluteSize.X < 340 then mode else "ECHO CHESS  ·  " .. mode
	-- Daily, Weekly and Duel puzzles have no neighbours to step to.
	local fixed = snap.mode == PLAY_MODES.Daily or snap.mode == PLAY_MODES.Weekly or snap.mode == DUEL_MODE
	self.prevButton.Visible = not fixed
	self.nextButton.Visible = not fixed
	local dueling = snap.duel ~= nil and snap.duel.phase ~= "finished"
	self.menuButton.Text = if dueling then "Leave" else "Menu"
	self.timeTitle.Text = if snap.duel then "TIME LEFT" else "TIME"
	local hintsLeft = snap.hintsLeft or 0
	local hintsOn = hintsLeft ~= 0 and snap.status ~= "won"
	self.hintButton.Text = if hintsLeft > 0 then string.format("💡  Hint (%d)", hintsLeft) else "💡  Hint"
	self.hintButton.BackgroundTransparency = if hintsOn then 0 else 0.6
	self.hintButton.TextTransparency = if hintsOn then 0 else 0.5
	self.movesValue.Text = tostring(snap.moveCount)
	self.parLabel.Text = "Par " .. tostring(snap.par)
	local captured = snap.targetsTotal - snap.targetsLeft
	self.capturedValue.Text = string.format("%d / %d", captured, snap.targetsTotal)
	Anim.tween(self.progressFill, 0.3, { Size = UDim2.fromScale(captured / math.max(1, snap.targetsTotal), 1) })
	self.undoButton.BackgroundTransparency = if snap.canUndo then 0 else 0.6
	self.undoButton.TextTransparency = if snap.canUndo then 0 else 0.5
	self.desk:render(snap)
	self.desk:setNav(if snap.mode == DUEL_MODE then "Duel" else snap.mode, dueling)
	-- The dots row comes and goes with the mode, which moves the board.
	if self.desk.visible then
		self:_layout()
	end
	self:_updateTimer()
end

function PuzzleHUD._updateTimer(self: any)
	local snap = self.snapshot
	if not snap then
		return
	end
	local since = os.clock() - self.receivedAt
	local duel = snap.duel
	if duel then
		local left = duel.timeLeft
		if duel.phase == "playing" then
			left -= since
		end
		self.timeValue.Text = formatTime(math.ceil(math.max(0, left)))
		self.timeValue.TextColor3 = if duel.phase == "playing" and left < 30 then Theme.Danger else Theme.Text
		self.desk:setTime(self.timeValue.Text, self.timeValue.TextColor3)
		local count = self.countdownLabel
		if duel.phase == "countdown" then
			local startsIn = duel.startsIn - since
			count.Visible = true
			count.Text = if startsIn > 0 then tostring(math.ceil(startsIn)) else "GO!"
		elseif duel.phase == "playing" and since < 0.8 and snap.event == "duel_start" then
			count.Visible = true
			count.Text = "GO!"
		else
			count.Visible = false
		end
		return
	end
	self.countdownLabel.Visible = false
	self.timeValue.TextColor3 = Theme.Text
	local seconds = snap.elapsed
	if snap.status == "playing" then
		seconds += since
	end
	self.timeValue.Text = formatTime(seconds)
	self.desk:setTime(self.timeValue.Text, Theme.Text)
end

function PuzzleHUD._renderPieces(self: any, snap: any)
	self.coach:pointAt(nil) -- the pointer may sit on a piece about to be cleared
	self.pieceLayer:ClearAllChildren()
	self.playerFrame = nil
	for index, piece in pairs(self.board.pieces) do
		local frame = self:_pieceFrame(index, piece.kind, piece.color)
		if piece.color == "white" then
			frame.ZIndex = 2
			self.playerFrame = frame
			Decor.aura(frame)
		end
	end

	local move = snap.lastMove
	if snap.event == "move" and move and self.playerFrame then
		-- A dragged piece is already where it landed; only taps slide it over.
		if self.droppedOn ~= move.to then
			local target = self.playerFrame.Position
			self.playerFrame.Position = (self:_squareRect(move.from))
			Anim.tween(self.playerFrame, 0.18, { Position = target })
		end
		if move.capturedKind then
			local position, size = self:_squareRect(move.to)
			Decor.ripple(self.pieceLayer, position, size, Theme.Gold)
			local ghost = self:_pieceFrame(move.to, move.capturedKind, "black")
			ghost.ZIndex = 1
			local ghostScale = ghost:FindFirstChildOfClass("UIScale") :: UIScale
			Anim.tween(ghostScale, 0.3, { Scale = 1.35 })
			for _, part in ipairs(ghost:GetDescendants()) do
				if part:IsA("ImageLabel") then
					Anim.tween(part, 0.3, { ImageTransparency = 1 })
				elseif part:IsA("Frame") then
					Anim.tween(part, 0.3, { BackgroundTransparency = 1 })
				end
			end
			task.delay(0.32, function()
				ghost:Destroy()
			end)
			task.delay(0.16, function()
				local scale = self.playerFrame and self.playerFrame:FindFirstChildOfClass("UIScale")
				if scale then
					Anim.pulse(scale, 1.25, 0.35)
				end
			end)
		end
	end
end

function PuzzleHUD._renderHighlights(self: any)
	local snap = self.snapshot
	local board = self.board
	self.legal = {}
	if self.selected and snap.status == "playing" then
		for _, move in ipairs(ChessRules.getLegalMoves(board, self.selected)) do
			self.legal[move.to] = move
		end
	end
	local move = snap.lastMove
	for index, square in pairs(self.squares) do
		local legal = self.legal[index]
		square.dot.Visible = legal ~= nil and not legal.capture
		square.ring.Visible = legal ~= nil and legal.capture
		if square.ring.Visible then
			square.ringStroke.Thickness = math.max(3, square.button.AbsoluteSize.X * 0.05)
		end
		if index == self.selected then
			square.tint.BackgroundColor3 = Theme.Selected
			square.tint.BackgroundTransparency = 0.35
		elseif move and (index == move.from or index == move.to) then
			square.tint.BackgroundColor3 = Theme.LastMove
			square.tint.BackgroundTransparency = 0.6
		else
			square.tint.BackgroundTransparency = 1
		end
	end
end

-- The duel's message line: what the opponent is up to (never their board).
function PuzzleHUD._renderDuelMessage(self: any, snap: any)
	local duel = snap.duel
	local opponent = duel.opponent
	local text
	if duel.phase == "countdown" then
		text = string.format("Opponent found: %s. Same puzzle, separate boards. Get ready!", opponent.name)
	elseif not opponent.connected then
		text = string.format("%s left the match.", opponent.name)
	else
		text = string.format(
			"vs %s  ·  %d / %d captured  ·  %d %s",
			opponent.name,
			opponent.captured,
			opponent.total,
			opponent.moves,
			if opponent.moves == 1 then "move" else "moves"
		)
	end
	self.messageLabel.Text = text
	self.messageLabel.TextColor3 = if opponent.connected then Theme.TextMuted else Theme.Gold
end

function PuzzleHUD._renderMessage(self: any, snap: any)
	if snap.duel and not snap.error and snap.event ~= "move" and snap.status ~= "failed" then
		self:_renderDuelMessage(snap)
		return
	end
	local text
	local color = Theme.TextMuted
	local playerPiece = self.playerSquare and self.board.pieces[self.playerSquare]
	local playerName = if playerPiece then PIECE_NAMES[playerPiece.kind] else "piece"
	if snap.error then
		text = string.format(ERROR_MESSAGES[snap.error] or "That action wasn't accepted.", string.lower(playerName))
		color = Theme.Danger
		Anim.shake(self.boardFrame)
	elseif snap.event == "hint" and snap.hint then
		text = "Hint: " .. snap.hint
		color = Theme.Selected
	elseif snap.status == "won" then
		text = "Board cleared!"
		color = Theme.Gold
	elseif snap.status == "failed" then
		text = "No way left to clear the board."
		color = Theme.Danger
	elseif snap.event == "move" and snap.lastMove and snap.lastMove.capturedKind then
		local left = snap.targetsLeft
		text = string.format(
			"You echoed into %s. %d left.",
			article(PIECE_NAMES[snap.lastMove.newKind]),
			left
		)
		color = Theme.Legal
	elseif snap.event == "undo" then
		text = "Move undone."
	elseif snap.event == "move" then
		text = "Your " .. string.lower(playerName) .. " moved."
	else
		text = snap.objective .. " Tap your piece to begin."
	end
	self.messageLabel.Text = text
	self.messageLabel.TextColor3 = color
	if snap.duel and snap.duel.phase == "playing" and snap.status == "playing" then
		-- Move feedback is brief in a duel; then the opponent's progress comes back.
		task.delay(2.5, function()
			if self.snapshot == snap and snap.duel.phase == "playing" then
				self:_renderDuelMessage(snap)
			end
		end)
	end
end

-- The win card's lines about stars.
local function starDetail(snap: any, result: any): string
	local parts = {}
	if result.stars == 3 then
		table.insert(parts, "Cleared at par: top rating.")
	elseif result.stars == 2 then
		table.insert(parts, string.format("Clear in %d moves for 3 stars.", snap.par))
	else
		table.insert(parts, string.format("%d moves or fewer for 2 stars, %d for 3.", result.twoStarMoves or snap.par, snap.par))
	end
	if result.previousBest then
		table.insert(parts, string.format("Best before: %d moves.", result.previousBest))
	end
	if not result.starsSaved then
		table.insert(parts, "Practice stars aren't saved.")
	elseif result.newStars and result.bestStars and result.bestStars > 0 then
		-- Only say "saved" when saving works; offline it's kept for this session.
		table.insert(parts, if snap.saveStatus == "offline" then "New star record." else "New star record saved.")
	end
	return table.concat(parts, " ")
end

local function rewardText(snap: any): string
	local reward = snap.reward
	if reward then
		local lines = {}
		local xp, coins = 0, 0
		for _, item in ipairs(reward.items or { reward }) do
			if item.achievement then
				table.insert(lines, string.format("Achievement: %s  +%d coins", item.reason, item.coins))
			else
				xp += item.xp
				coins += item.coins
			end
		end
		if xp > 0 or coins > 0 then
			table.insert(lines, 1, string.format("+%d XP   +%d coins", xp, coins))
		end
		return table.concat(lines, "\n")
	end
	if snap.mode == PLAY_MODES.Practice then
		return "Practice: no rewards"
	elseif snap.mode == PLAY_MODES.Daily then
		return "Today's reward was already collected."
	elseif snap.mode == PLAY_MODES.Weekly then
		return "No new weekly reward for this clear."
	end
	return "Reward already collected. Replays can still earn stars."
end

-- Rewards are applied at once but saved a little later. When saving isn't
-- working, say so instead of implying they're safe.
local function saveNote(snap: any): string
	if snap.saveStatus == "offline" then
		-- Gold, not the reward's green, so it doesn't read as confirmed. The
		-- reward label is RichText for this.
		return '\n<font color="#F6C648">Saving is unavailable right now, so this isn\'t saved yet.</font>'
	end
	return ""
end

-- Where the player stands after a win: unlock progress in Journey, the
-- streak in Daily.
local function progressText(snap: any, result: any): string
	local progress = snap.progress
	if not progress then
		return ""
	end
	if snap.mode == PLAY_MODES.Daily then
		local streak = progress.streak
		local text = string.format("🔥 %d-day Daily streak", streak.current)
		if result.shieldUsed then
			text ..= "\n🛡 Your streak shield covered the day you missed."
		end
		return text
	elseif snap.mode == PLAY_MODES.Weekly and progress.weekly then
		local weekly = progress.weekly
		if weekly.completed then
			return string.format("Weekly Challenge complete: %d / %d ✓", weekly.clearedCount, weekly.size)
		end
		local nextMilestone = nil
		for _, milestone in ipairs(weekly.milestones) do
			if not milestone.claimed then
				nextMilestone = milestone
				break
			end
		end
		local text = string.format("Weekly Challenge: %d / %d cleared", weekly.clearedCount, weekly.size)
		if nextMilestone then
			text ..= string.format("\nClear %d for +%d coins.", nextMilestone.cleared, nextMilestone.coins)
		end
		return text
	elseif snap.mode == PLAY_MODES.Journey and progress.unlocks then
		local index = table.find(GameConfig.DIFFICULTIES, snap.difficulty)
		local here = index and progress.unlocks[index]
		local nextRow = index and progress.unlocks[index + 1]
		if result.unlocked then
			return result.unlocked .. " puzzles are now open in Journey."
		elseif here and nextRow and not nextRow.unlocked then
			return string.format(
				"%s: %d/%d clears to unlock %s",
				snap.difficulty,
				math.min(here.credited, here.required),
				here.required,
				nextRow.difficulty
			)
		elseif here then
			return string.format("%s: %d/%d cleared", snap.difficulty, here.credited, here.total)
		end
	end
	return ""
end

function PuzzleHUD._renderDuelResult(self: any, snap: any, previous: any)
	local r = self.result
	local duel = snap.duel
	local wasShowing = r.dim.Visible and previous and previous.duel and previous.duel.matchId == duel.matchId
	r.dim.Visible = true
	local outcome = duel.outcome
	local color = if outcome == "win" then Theme.Gold elseif outcome == "loss" then Theme.Danger else Theme.Text
	r.title.Text = if outcome == "win" then "VICTORY!" elseif outcome == "loss" then "DEFEAT" else "DRAW"
	r.title.TextColor3 = if outcome == "win" then Color3.new(1, 1, 1) else color
	r.gradient.Enabled = outcome == "win"
	r.gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Theme.GoldDeep),
		ColorSequenceKeypoint.new(0.5, Theme.Gold),
		ColorSequenceKeypoint.new(1, Theme.GoldDeep),
	})
	r.stroke.Color = color
	r.stars.Visible = false
	r.banner.Visible = false
	r.subtitle.Text = string.format(DUEL_REASONS[duel.reason or ""] or "The duel is over.", duel.opponent.name)
	r.stats.Text = string.format(
		"You: %d / %d captured in %d %s",
		snap.targetsTotal - snap.targetsLeft,
		snap.targetsTotal,
		snap.moveCount,
		if snap.moveCount == 1 then "move" else "moves"
	)
	r.detail.Visible = true
	r.detail.Text = string.format(
		"%s: %d / %d captured in %d %s",
		duel.opponent.name,
		duel.opponent.captured,
		duel.opponent.total,
		duel.opponent.moves,
		if duel.opponent.moves == 1 then "move" else "moves"
	)
	r.reward.Visible = true
	local rewardLine
	if duel.reward then
		rewardLine = string.format("+%d XP   +%d coins", duel.reward.xp, duel.reward.coins) .. saveNote(snap)
	elseif outcome == "loss" then
		rewardLine = "No reward for a loss. The result is in your Duel stats."
	else
		rewardLine = DUEL_REWARD_NOTES[duel.rewardNote or ""] or "No reward this time."
	end
	r.reward.Text = rewardLine
	r.reward.TextColor3 = if duel.reward then Theme.Legal else Theme.TextMuted
	local stats = snap.progress and snap.progress.duel
	r.progress.Visible = stats ~= nil
	if stats then
		r.progress.Text = string.format("Duels: %d W  ·  %d L  ·  %d D", stats.wins, stats.losses, stats.draws)
	end
	r.primary.Text = "Duel again"
	r.secondary.Text = "Back to puzzles"
	if not wasShowing then
		r.dim.BackgroundTransparency = 1
		Anim.tween(r.dim, 0.25, { BackgroundTransparency = 0.4 })
		r.scale.Scale = 0.85
		task.defer(function()
			self:_fitResultCard()
			r.scale.Scale = r.fit * 0.85
			Anim.tween(r.scale, 0.35, { Scale = r.fit }, Enum.EasingStyle.Back)
		end)
		if outcome == "win" then
			Anim.burst(r.dim, Theme.Gold, 18)
			Sound.play("win")
			Sound.haptic("heavy")
		else
			Sound.play(if outcome == "loss" then "fail" else "open")
			Sound.haptic("medium")
		end
	end
end

function PuzzleHUD._renderResult(self: any, snap: any, previous: any)
	local r = self.result
	if snap.duel then
		if snap.duel.phase == "finished" then
			self:_renderDuelResult(snap, previous)
			return
		elseif snap.status ~= "failed" then
			r.dim.Visible = false
			return
		end
	end
	if snap.status == "playing" then
		r.dim.Visible = false
		return
	end
	local wasShowing = r.dim.Visible and previous and previous.status == snap.status
	r.dim.Visible = true
	local result = snap.result
	local unlocked = nil
	if snap.status == "won" then
		r.title.Text = "PUZZLE CLEARED"
		r.title.TextColor3 = Color3.new(1, 1, 1)
		r.gradient.Enabled = true
		r.gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.GoldDeep),
			ColorSequenceKeypoint.new(0.5, Theme.Gold),
			ColorSequenceKeypoint.new(1, Theme.GoldDeep),
		})
		r.stroke.Color = Theme.Gold
		r.subtitle.Text = snap.name .. " solved." .. (if result and result.newBest then "  New best!" else "")
		r.stats.Text = string.format("Moves %d (par %d)    Time %s", snap.moveCount, snap.par, formatTime(snap.elapsed))
		r.stars.Visible = result ~= nil
		r.detail.Visible = result ~= nil
		if result then
			r.stars.Text = PuzzleMenu.starText(result.stars)
			r.detail.Text = starDetail(snap, result)
			unlocked = result.unlocked
		end
		r.reward.Visible = true
		r.reward.Text = rewardText(snap) .. (if snap.reward then saveNote(snap) else "")
		r.reward.TextColor3 = if snap.reward then Theme.Legal else Theme.TextMuted
		local progressLine = if result then progressText(snap, result) else ""
		r.progress.Text = progressLine
		r.progress.Visible = progressLine ~= ""
		r.primary.Text = (self:_nextAfterWin())
		r.secondary.Text = "Play again"
	else
		r.title.Text = "NO WAY THROUGH"
		r.title.TextColor3 = Theme.Danger
		r.gradient.Enabled = false
		r.stroke.Color = Theme.Danger
		r.stars.Visible = false
		r.subtitle.Text = "The pieces left can't all be captured from here."
		r.stats.Text = string.format("Moves %d    Captured %d / %d", snap.moveCount, snap.targetsTotal - snap.targetsLeft, snap.targetsTotal)
		r.detail.Visible = true
		r.detail.Text = if snap.duel
			then "Undo your last capture and try another. The clock is still running!"
			else "Undo your last capture and try another, or tap Hint for a free explanation."
		r.reward.Visible = false
		r.progress.Visible = false
		r.primary.Text = "Undo move"
		r.secondary.Text = "Restart"
	end
	r.banner.Visible = unlocked ~= nil
	if unlocked then
		r.banner.Text = string.upper(unlocked) .. " UNLOCKED!"
		r.banner.BackgroundColor3 = Theme.DifficultyColors[unlocked] or Theme.Gold
		self.menu:markUnlocked(unlocked)
	end
	if not wasShowing then
		r.dim.BackgroundTransparency = 1
		Anim.tween(r.dim, 0.25, { BackgroundTransparency = 0.4 })
		r.scale.Scale = 0.85
		task.defer(function()
			self:_fitResultCard()
			r.scale.Scale = r.fit * 0.85
			Anim.tween(r.scale, 0.35, { Scale = r.fit }, Enum.EasingStyle.Back)
		end)
		if snap.status == "won" then
			-- Sparks go on the overlay: the card's list layout would place them as rows.
			Anim.burst(r.dim, Theme.Gold, 18)
			Sound.play("win")
			Sound.haptic("heavy")
			if unlocked then
				task.delay(0.9, function()
					Sound.play("unlock")
					Sound.haptic("medium")
					Anim.burst(r.dim, Theme.DifficultyColors[unlocked] or Theme.Gold, 24)
					Anim.pulse(r.bannerScale, 1.18, 0.45)
				end)
			end
		end
	end
end

-- Input ----------------------------------------------------------------------------

function PuzzleHUD._onSquare(self: any, index: number)
	local snap = self.snapshot
	if not snap or self.pending or snap.status ~= "playing" or self.dialog:isOpen() or duelLocked(snap) then
		return
	end
	-- The release of a drag, not a tap. A button's Activated can fire before
	-- or after UserInputService.InputEnded, so check both the live drag and
	-- one that just ended.
	if (self.press and self.press.dragging) or os.clock() - self.dragEndedAt < InputRules.TAP_SUPPRESS_SECONDS then
		return
	end
	if index == self.playerSquare then
		self.selected = if self.selected == index then nil else index
		local scale = self.playerFrame and self.playerFrame:FindFirstChildOfClass("UIScale")
		if scale and self.selected then
			Anim.pulse(scale, 1.12, 0.25)
			Sound.play("select")
		end
		self:_renderHighlights()
		if self.selected then
			self:_tutorialEvent("select")
		end
		return
	end
	if self.selected and self.legal[index] then
		self:_sendMove(self.selected, index)
		return
	end
	self:_rejectSquare(index)
end

function PuzzleHUD._sendMove(self: any, from: number, to: number)
	local snap = self.snapshot
	self.pending = true
	self.handlers.move(from, to)
	task.delay(3, function()
		-- Never leave input locked if a response is lost.
		if self.snapshot == snap then
			self.pending = false
		end
	end)
end

-- Feedback for a tap or drop on a square the piece can't reach.
function PuzzleHUD._rejectSquare(self: any, index: number)
	local square = self.squares[index]
	if square then
		Anim.flash(square.button, Theme.Danger)
	end
	Sound.play("invalid")
	local playerPiece = self.playerSquare and self.board.pieces[self.playerSquare]
	if not self.selected then
		self.messageLabel.Text = "Tap your white piece first."
	elseif playerPiece then
		self.messageLabel.Text = string.format(ERROR_MESSAGES.illegal_move, string.lower(PIECE_NAMES[playerPiece.kind]))
	end
	self.messageLabel.TextColor3 = Theme.Danger
end

-- Drag-to-move --------------------------------------------------------------------

local function isPointer(input: InputObject): boolean
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

-- Whether `input` continues `press` (the same finger, or the mouse).
local function continues(press: any, input: InputObject, mouseType: Enum.UserInputType): boolean
	if press.input.UserInputType == Enum.UserInputType.Touch then
		return input == press.input
	end
	return input.UserInputType == mouseType
end

function PuzzleHUD._setDrag(self: any, enabled: boolean)
	self.dragEnabled = enabled
	if self.menu then
		self.menu.dragEnabled = enabled
	end
	if not enabled then
		self:_cancelDrag()
	end
end

function PuzzleHUD._pressBegan(self: any, index: number, input: InputObject)
	local snap = self.snapshot
	if
		not isPointer(input)
		or not self.dragEnabled
		or self.press
		or not snap
		or snap.status ~= "playing"
		or duelLocked(snap)
		or self.pending
		or self.dialog:isOpen()
		or index ~= self.playerSquare
	then
		return
	end
	self.press = { input = input, origin = Vector2.new(input.Position.X, input.Position.Y), dragging = false }
end

function PuzzleHUD._pressMoved(self: any, input: InputObject)
	local press = self.press
	if not press or not continues(press, input, Enum.UserInputType.MouseMovement) then
		return
	end
	local point = Vector2.new(input.Position.X, input.Position.Y)
	if not press.dragging then
		local delta = point - press.origin
		if not InputRules.isDrag(delta.X, delta.Y) then
			return
		end
		press.dragging = true
		if self.selected ~= self.playerSquare then
			self.selected = self.playerSquare
			Sound.play("select")
			self:_renderHighlights()
			self:_tutorialEvent("select")
		end
		if self.playerFrame then
			self.playerFrame.ZIndex = 5
		end
	end
	local frame = self.playerFrame
	if frame then
		local layer = self.pieceLayer.AbsolutePosition
		local size = frame.AbsoluteSize
		frame.Position = UDim2.fromOffset(point.X - layer.X - size.X / 2, point.Y - layer.Y - size.Y / 2)
	end
end

function PuzzleHUD._pressEnded(self: any, input: InputObject)
	local press = self.press
	if not press or not continues(press, input, Enum.UserInputType.MouseButton1) then
		return
	end
	self.press = nil
	if not press.dragging then
		return -- a tap; the square's Activated handles it
	end
	self.dragEndedAt = os.clock()
	local layer = self.squareLayer
	local size = layer.AbsoluteSize
	local target = nil
	if size.X > 0 and size.Y > 0 then
		local relative = (Vector2.new(input.Position.X, input.Position.Y) - layer.AbsolutePosition) / size
		target = InputRules.squareAt(self.board, relative.X, relative.Y)
	end
	local snap = self.snapshot
	local playable = snap and snap.status == "playing" and not self.pending and not self.dialog:isOpen()
	if playable and target and self.playerSquare and self.legal[target] then
		self.droppedOn = target
		self:_sendMove(self.playerSquare, target)
		return
	end
	self:_snapBack()
	if playable and target and target ~= self.playerSquare then
		self:_rejectSquare(target)
	end
end

-- Puts a dragged piece back on its square.
function PuzzleHUD._snapBack(self: any)
	local frame = self.playerFrame
	if frame and self.playerSquare then
		frame.ZIndex = 2
		Anim.tween(frame, 0.15, { Position = (self:_squareRect(self.playerSquare)) })
	end
end

function PuzzleHUD._cancelDrag(self: any)
	local press = self.press
	self.press = nil
	if press and press.dragging then
		self.dragEndedAt = os.clock()
		self:_snapBack()
	end
end

-- Confirmation -----------------------------------------------------------------------

-- Runs `action` now, or once the player confirms when it would throw away an
-- attempt that has moves in it.
function PuzzleHUD._confirmLeave(self: any, action: () -> ())
	local snap = self.snapshot
	if not InputRules.needsConfirm(snap) then
		action()
		return
	end
	self:_cancelDrag()
	self.dialog:ask({
		title = "Leave this puzzle?",
		body = string.format("Your %d %s on %s will be lost.", snap.moveCount, if snap.moveCount == 1 then "move" else "moves", snap.name),
		confirm = "Leave",
		onConfirm = action,
	})
end

-- A desk sidebar press or card tap. Every page lives in the menu; a live
-- duel asks to forfeit first, as the Menu button does.
function PuzzleHUD._deskNav(self: any, id: string)
	if id == "Collapse" then
		self.desk:toggleSidebar()
		self:_layout()
		return
	end
	local snap = self.snapshot
	if snap and snap.duel and snap.duel.phase ~= "finished" then
		self:_confirmForfeit()
		return
	end
	if id == "Tutorial" then
		if snap then
			self:_confirmLeave(function()
				self:startTutorial()
			end)
		end
		return
	end
	self.menu:open(id)
end

function PuzzleHUD._confirmForfeit(self: any)
	self:_cancelDrag()
	self.dialog:ask({
		title = "Leave this duel?",
		body = "Leaving counts as a loss, and your opponent wins.",
		confirm = "Leave",
		onConfirm = function()
			self.handlers.duelLeave()
		end,
	})
end

function PuzzleHUD._confirmRestart(self: any)
	local snap = self.snapshot
	if not InputRules.needsConfirm(snap) then
		self.handlers.restart()
		return
	end
	self:_cancelDrag()
	self.dialog:ask({
		title = "Restart puzzle?",
		body = string.format("Your %d %s on this attempt will be lost.", snap.moveCount, if snap.moveCount == 1 then "move" else "moves"),
		confirm = "Restart",
		onConfirm = function()
			self.handlers.restart()
		end,
	})
end

-- Tutorial ------------------------------------------------------------------------------

-- Starts (or replays) the tutorial on its puzzle in Journey.
function PuzzleHUD.startTutorial(self: any)
	self.tutorialOffered = true
	self.tutorialDue = false
	self.tutorial = { state = TutorialFlow.new(), awaitingStart = true }
	self.menu:close()
	self.handlers.start(TutorialFlow.PUZZLE_ID, PLAY_MODES.Journey)
	self:_renderTutorial()
end

function PuzzleHUD._tutorialEvent(self: any, event: string)
	local tutorial = self.tutorial
	if not tutorial or not TutorialFlow.advance(tutorial.state, event) then
		return
	end
	local finished = tutorial.state.finished
	if finished then
		self.tutorial = nil
		-- An interrupted tutorial isn't saved, so it is offered again next time.
		if finished ~= "interrupted" then
			self.handlers.tutorial(finished)
		end
	end
	self:_renderTutorial()
end

-- Feeds one snapshot to the tutorial, and starts it for new players.
function PuzzleHUD._trackTutorial(self: any, snap: any)
	local tutorial = self.tutorial
	if tutorial then
		local onPuzzle = snap.puzzleId == TutorialFlow.PUZZLE_ID and snap.mode == PLAY_MODES.Journey
		if tutorial.awaitingStart then
			if onPuzzle and snap.event == "start" then
				tutorial.awaitingStart = false
			end
		elseif not onPuzzle then
			self:_tutorialEvent("leave")
		elseif snap.status == "won" then
			self:_tutorialEvent("win")
		elseif snap.event == "move" and snap.lastMove and snap.lastMove.capturedKind then
			self:_tutorialEvent("capture")
		elseif snap.event == "hint" then
			self:_tutorialEvent("hint")
		end
	end
	-- Everyone lands on the main menu. Players who have never finished or
	-- skipped the tutorial and haven't cleared a puzzle get it once per
	-- session when they first leave the menu to play Journey.
	if not self.tutorialOffered and snap.progress and snap.saveStatus ~= "loading" then
		self.tutorialOffered = true
		self.tutorialDue = snap.progress.needsTutorial == true
	end
	self:_renderTutorial()
end

function PuzzleHUD._renderTutorial(self: any)
	local tutorial = self.tutorial
	local snap = self.snapshot
	local step = tutorial and TutorialFlow.current(tutorial.state)
	local showing = self.coach:isShowing()
	local show = step ~= nil
		and snap ~= nil
		and not tutorial.awaitingStart
		and snap.puzzleId == TutorialFlow.PUZZLE_ID
		and snap.status == "playing"
	if show then
		self.coach:show(step, tutorial.state.step, #TutorialFlow.STEPS)
		local target = nil
		if step.target == "player" then
			target = self.playerFrame
		elseif step.target == "hint" then
			target = self.hintButton
		end
		self.coach:pointAt(target)
	else
		self.coach:hide()
	end
	if showing ~= self.coach:isShowing() then
		self:_layout()
	end
end

-- The puzzle `offset` steps away in the catalogue, or nil when it is past the
-- end, the current mode has no neighbours (Daily), or Journey has it locked.
function PuzzleHUD._neighbour(self: any, offset: number): any
	local snap = self.snapshot
	if not snap or snap.mode ~= PLAY_MODES.Journey and snap.mode ~= PLAY_MODES.Practice then
		return nil
	end
	local list = PuzzleDefinitions.list
	local current = PuzzleDefinitions.get(snap.puzzleId)
	local index = current and table.find(list, current)
	local candidate = index and list[index + offset]
	if not candidate then
		return nil
	end
	local unlocked = snap.progress and snap.progress.unlockedIndex or 1
	if snap.mode == PLAY_MODES.Journey and candidate.difficultyIndex > unlocked then
		return nil
	end
	return candidate
end

function PuzzleHUD._switchPuzzle(self: any, offset: number)
	local snap = self.snapshot
	if not snap then
		return
	end
	local target = self:_neighbour(offset)
	if target then
		self.handlers.start(target.id, snap.mode)
	elseif offset > 0 and snap.mode == PLAY_MODES.Journey then
		self.messageLabel.Text = "The next difficulty is locked. Open Menu > Journey to see what unlocks it."
		self.messageLabel.TextColor3 = Theme.TextMuted
	else
		self.menu:open(snap.mode)
	end
end

-- What the win card's main button does: Journey goes to the next unsolved
-- puzzle (the server's resume pick), Practice to the next in the catalogue,
-- Weekly to the next uncleared challenge puzzle, Daily back to the Daily page.
function PuzzleHUD._nextAfterWin(self: any): (string, () -> ())
	local snap = self.snapshot
	if snap.mode == PLAY_MODES.Journey then
		local nextId = snap.progress and snap.progress.resumeId
		if nextId then
			return "Next puzzle", function()
				self.handlers.start(nextId, PLAY_MODES.Journey)
			end
		end
		return "Menu", function()
			self.menu:open("Journey")
		end
	elseif snap.mode == PLAY_MODES.Practice then
		local nextPuzzle = self:_neighbour(1)
		if nextPuzzle then
			return "Next puzzle", function()
				self.handlers.start(nextPuzzle.id, PLAY_MODES.Practice)
			end
		end
		return "Menu", function()
			self.menu:open("Practice")
		end
	elseif snap.mode == PLAY_MODES.Weekly then
		local weekly = snap.progress and snap.progress.weekly
		if weekly then
			for _, id in ipairs(weekly.puzzleIds) do
				if not weekly.cleared[id] then
					return "Next challenge", function()
						self.handlers.start(id, PLAY_MODES.Weekly)
					end
				end
			end
		end
		return "Menu", function()
			self.menu:open("Weekly")
		end
	end
	return "Menu", function()
		self.menu:open("Daily")
	end
end

return PuzzleHUD
