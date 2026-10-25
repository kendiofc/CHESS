--!strict
-- PuzzleHUD: the puzzle screen. Builds the GUI, renders server snapshots and
-- turns clicks/taps into move intents. Legal-move highlights are computed
-- locally with the shared rules purely for display; the server re-validates
-- every move and its snapshot is always what gets drawn.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BoardState = require(Shared:WaitForChild("BoardState"))
local ChessRules = require(Shared:WaitForChild("ChessRules"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PuzzleDefinitions = require(Shared:WaitForChild("PuzzleDefinitions"))

local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))
local PieceArt = require(script.Parent:WaitForChild("PieceArt"))
local PuzzleMenu = require(script.Parent:WaitForChild("PuzzleMenu"))
local Theme = require(script.Parent:WaitForChild("Theme"))

export type Handlers = {
	move: (from: number, to: number) -> (),
	undo: () -> (),
	restart: () -> (),
	hint: () -> (),
	start: (puzzleId: string, mode: string) -> (),
}

local PLAY_MODES = GameConfig.PLAY_MODES

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
}

local MARGIN = 12
local GAP = 10
local HEADER_HEIGHT = 62
local STATS_HEIGHT = 62
local MESSAGE_HEIGHT = 52
local CONTROLS_HEIGHT = 54
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
	return make("TextButton", {
		Size = UDim2.new(0, 150, 1, 0),
		BackgroundColor3 = if primary then Theme.Accent else Theme.PanelRaised,
		AutoButtonColor = true,
		FontFace = Theme.FontBold,
		Text = text,
		TextColor3 = Theme.Text,
		TextSize = 18,
	}, {
		corner(12),
		stroke(if primary then Theme.AccentPressed else Theme.Stroke, 1.5),
	})
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
	self:_build(playerGui)
	self.menu = PuzzleMenu.new(playerGui, function(puzzleId: string, mode: string)
		self.handlers.start(puzzleId, mode)
	end)

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
	make("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = backdrop,
	}, {
		make("UIGradient", {
			Color = ColorSequence.new(Theme.Background, Theme.BackgroundDeep),
			Rotation = 115,
		}),
	})

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
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -160, 0, 18),
		Parent = header,
	})
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
		Size = UDim2.fromOffset(150, 36),
		BackgroundTransparency = 1,
		Parent = header,
	})
	local prev = button("<", false)
	prev.Name = "PrevPuzzle"
	prev.Size = UDim2.fromOffset(44, 36)
	prev.Parent = switcher
	local nextButton = button(">", false)
	nextButton.Name = "NextPuzzle"
	nextButton.AnchorPoint = Vector2.new(1, 0)
	nextButton.Position = UDim2.fromScale(1, 0)
	nextButton.Size = UDim2.fromOffset(44, 36)
	nextButton.Parent = switcher
	local menuButton = button("Puzzles", false)
	menuButton.Name = "MenuButton"
	menuButton.Position = UDim2.fromOffset(48, 0)
	menuButton.Size = UDim2.new(1, -96, 1, 0)
	menuButton.TextSize = 13
	menuButton.Parent = switcher
	menuButton.Activated:Connect(function()
		self.menu:open(self.snapshot and self.snapshot.mode)
	end)
	self.prevButton, self.nextButton = prev, nextButton
	prev.Activated:Connect(function()
		self:_switchPuzzle(-1)
	end)
	nextButton.Activated:Connect(function()
		self:_switchPuzzle(1)
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
	local function statCard(order: number, title: string): (Frame, TextLabel, TextLabel)
		local card = make("Frame", {
			LayoutOrder = order,
			Size = UDim2.new(1 / 3, -7, 1, 0),
			BackgroundColor3 = Theme.Panel,
			Parent = stats,
		}, { corner(12), stroke(Theme.Stroke, 1) })
		label({
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
		return card, value, sub
	end
	local _, movesValue, parLabel = statCard(1, "MOVES")
	local capturedCard, capturedValue, _ = statCard(2, "CAPTURED")
	local _, timeValue, _ = statCard(3, "TIME")
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
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
		Parent = boardArea,
	}, { stroke(Theme.Stroke, 4) })
	self.aspect = make("UIAspectRatioConstraint", {
		AspectRatio = 1,
		AspectType = Enum.AspectType.FitWithinMaxSize,
		Parent = self.boardFrame,
	})
	self.squareLayer = make("Frame", {
		Name = "Squares",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 1,
		Parent = self.boardFrame,
	})
	self.pieceLayer = make("Frame", {
		Name = "Pieces",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = self.boardFrame,
	})

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
	self.undoButton = controlButton("Undo", false)
	self.undoButton.Name = "UndoButton"
	self.undoButton.LayoutOrder = 1
	self.undoButton.Parent = controls
	self.undoButton.Activated:Connect(function()
		if self.snapshot and self.snapshot.canUndo and not self.pending then
			self.pending = true
			self.handlers.undo()
		end
	end)
	self.hintButton = controlButton("Hint", false)
	self.hintButton.Name = "HintButton"
	self.hintButton.LayoutOrder = 2
	self.hintButton.Parent = controls
	self.hintButton.Activated:Connect(function()
		local snap = self.snapshot
		if snap and snap.status ~= "won" and not self.pending then
			self.handlers.hint()
		end
	end)
	local restartButton = controlButton("Restart", true)
	restartButton.Name = "RestartButton"
	restartButton.LayoutOrder = 3
	restartButton.Parent = controls
	restartButton.Activated:Connect(function()
		self.handlers.restart()
	end)

	self.parts = { header = header, stats = stats, boardArea = boardArea, message = self.messageLabel, controls = controls }
	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
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
	local card = make("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0.9, 0, 0, 290),
		BackgroundColor3 = Theme.Panel,
		ZIndex = 11,
		Parent = dim,
	}, {
		corner(18),
		make("UISizeConstraint", { MaxSize = Vector2.new(400, 290) }),
	})
	local cardStroke = stroke(Theme.Gold, 2)
	cardStroke.Parent = card
	local cardScale = make("UIScale", { Parent = card })
	local title = label({
		FontFace = Theme.FontHeavy,
		TextSize = 30,
		Position = UDim2.fromOffset(20, 26),
		Size = UDim2.new(1, -40, 0, 38),
		ZIndex = 12,
		Parent = card,
	})
	local titleGradient = make("UIGradient", { Parent = title })
	local subtitle = label({
		TextSize = 15,
		TextColor3 = Theme.TextMuted,
		Position = UDim2.fromOffset(24, 68),
		Size = UDim2.new(1, -48, 0, 40),
		ZIndex = 12,
		Parent = card,
	})
	local statsLine = label({
		FontFace = Theme.FontBold,
		TextSize = 18,
		Position = UDim2.fromOffset(20, 114),
		Size = UDim2.new(1, -40, 0, 88),
		ZIndex = 12,
		Parent = card,
	})
	local buttons = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -22),
		Size = UDim2.new(1, -40, 0, 52),
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
		if snap.status == "won" then
			local nextPuzzle = self:_neighbour(1)
			if nextPuzzle then
				self.handlers.start(nextPuzzle.id, snap.mode)
			else
				self.menu:open(snap.mode)
			end
		elseif snap.status == "failed" then
			self.pending = true
			self.handlers.undo()
		end
	end)
	secondary.Activated:Connect(function()
		self.handlers.restart()
	end)

	self.result = {
		dim = dim,
		card = card,
		stroke = cardStroke,
		scale = cardScale,
		title = title,
		gradient = titleGradient,
		subtitle = subtitle,
		stats = statsLine,
		primary = primary,
		secondary = secondary,
	}
end

-- Layout -----------------------------------------------------------------------

local function place(frame: GuiObject, x: number, y: number, w: number, h: number)
	frame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	frame.Size = UDim2.fromOffset(math.floor(w), math.floor(h))
end

-- Short, wide screens (phones in landscape) put the board on the left and the
-- panels in a column on the right; everything else stacks vertically.
function PuzzleHUD._layout(self: any)
	local size = self.container.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	local p = self.parts
	local w = size.X - MARGIN * 2
	local h = size.Y - MARGIN * 2
	local wide = size.X >= size.Y * 1.3 and size.Y < 640
	self.layoutMode = if wide then "wide" else "tall"
	if wide then
		local sideW = math.clamp(w * 0.4, 260, 380)
		local boardW = math.min(h, w - sideW - GAP * 2)
		local x = MARGIN + (w - (boardW + GAP * 2 + sideW)) / 2
		local sx = x + boardW + GAP * 2
		place(p.boardArea, x, MARGIN, boardW, h)
		place(p.header, sx, MARGIN, sideW, HEADER_HEIGHT)
		place(p.stats, sx, MARGIN + HEADER_HEIGHT + GAP, sideW, STATS_HEIGHT)
		local messageY = MARGIN + HEADER_HEIGHT + STATS_HEIGHT + GAP * 2
		place(p.message, sx, messageY, sideW, h + MARGIN - CONTROLS_HEIGHT - GAP - messageY)
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
		place(p.boardArea, x, boardY, cw, bottom - CONTROLS_HEIGHT - MESSAGE_HEIGHT - GAP * 3 - boardY)
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
	local board = self.board
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
			Size = UDim2.fromScale(0.3, 0.3),
			BackgroundColor3 = Theme.Legal,
			BackgroundTransparency = 0.1,
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
			label({
				Text = tostring(row),
				FontFace = Theme.FontBold,
				TextSize = 12,
				TextColor3 = coordColor,
				Position = UDim2.fromOffset(4, 2),
				Size = UDim2.fromOffset(14, 14),
				TextXAlignment = Enum.TextXAlignment.Left,
				ZIndex = 2,
				Parent = square,
			})
		end
		if row == 1 then
			label({
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
			})
		end
		square.Activated:Connect(function()
			self:_onSquare(index)
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
	art.Parent = holder
	make("UIScale", { Parent = holder })
	return holder
end

-- Rendering ------------------------------------------------------------------------

function PuzzleHUD.render(self: any, snap: any)
	local previous = self.snapshot
	local newPuzzle = not previous or previous.puzzleId ~= snap.puzzleId or snap.event == "start"
	self.snapshot = snap
	self.receivedAt = os.clock()
	self.pending = false
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

	self.menu:update(snap)
	self:_renderHeader(snap)
	self:_renderPieces(snap)
	self:_renderHighlights()
	self:_renderMessage(snap)
	self:_renderResult(snap, previous)
end

function PuzzleHUD._renderHeader(self: any, snap: any)
	self.titleLabel.Text = snap.name
	self.difficultyPill.BackgroundColor3 = Theme.DifficultyColors[snap.difficulty] or Theme.PanelRaised
	local group = PuzzleDefinitions.byDifficulty[snap.difficulty]
	self.difficultyPill.Text = string.format("%s  %d/%d", string.upper(snap.difficulty), snap.number or 1, if group then #group else 1)
	self.brandLabel.Text = "ECHO CHESS  ·  " .. string.upper(snap.mode or PLAY_MODES.Journey)
	local daily = snap.mode == PLAY_MODES.Daily
	self.prevButton.Visible = not daily
	self.nextButton.Visible = not daily
	local hintsLeft = snap.hintsLeft or 0
	local hintsOn = hintsLeft ~= 0 and snap.status ~= "won"
	self.hintButton.Text = if hintsLeft > 0 then string.format("Hint (%d)", hintsLeft) else "Hint"
	self.hintButton.BackgroundTransparency = if hintsOn then 0 else 0.6
	self.hintButton.TextTransparency = if hintsOn then 0 else 0.5
	self.movesValue.Text = tostring(snap.moveCount)
	self.parLabel.Text = "Par " .. tostring(snap.par)
	local captured = snap.targetsTotal - snap.targetsLeft
	self.capturedValue.Text = string.format("%d / %d", captured, snap.targetsTotal)
	Anim.tween(self.progressFill, 0.3, { Size = UDim2.fromScale(captured / math.max(1, snap.targetsTotal), 1) })
	self.undoButton.BackgroundTransparency = if snap.canUndo then 0 else 0.6
	self.undoButton.TextTransparency = if snap.canUndo then 0 else 0.5
	self:_updateTimer()
end

function PuzzleHUD._updateTimer(self: any)
	local snap = self.snapshot
	if not snap then
		return
	end
	local seconds = snap.elapsed
	if snap.status == "playing" then
		seconds += os.clock() - self.receivedAt
	end
	self.timeValue.Text = formatTime(seconds)
end

function PuzzleHUD._renderPieces(self: any, snap: any)
	self.pieceLayer:ClearAllChildren()
	self.playerFrame = nil
	for index, piece in pairs(self.board.pieces) do
		local frame = self:_pieceFrame(index, piece.kind, piece.color)
		if piece.color == "white" then
			frame.ZIndex = 2
			self.playerFrame = frame
		end
	end

	local move = snap.lastMove
	if snap.event == "move" and move and self.playerFrame then
		local target = self.playerFrame.Position
		self.playerFrame.Position = (self:_squareRect(move.from))
		Anim.tween(self.playerFrame, 0.18, { Position = target })
		if move.capturedKind then
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

function PuzzleHUD._renderMessage(self: any, snap: any)
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
end

function PuzzleHUD._renderResult(self: any, snap: any, previous: any)
	local r = self.result
	if snap.status == "playing" then
		r.dim.Visible = false
		return
	end
	local wasShowing = r.dim.Visible and previous and previous.status == snap.status
	r.dim.Visible = true
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
		r.subtitle.Text = snap.name .. " solved."
		local parNote = if snap.moveCount <= snap.par then "  (par!)" else string.format("  (par %d)", snap.par)
		local rewardLine = if snap.reward
			then string.format("\n+%d XP   +%d coins", snap.reward.xp, snap.reward.coins)
			elseif snap.mode == PLAY_MODES.Practice then "\nPractice: no rewards"
			else ""
		r.stats.Text = string.format("Moves  %d%s\nTime  %s%s", snap.moveCount, parNote, formatTime(snap.elapsed), rewardLine)
		r.primary.Text = if self:_neighbour(1) then "Next puzzle" else "Puzzles"
		r.secondary.Text = "Play again"
	else
		r.title.Text = "NO WAY THROUGH"
		r.title.TextColor3 = Theme.Danger
		r.gradient.Enabled = false
		r.stroke.Color = Theme.Danger
		r.subtitle.Text = "The pieces left can't all be captured from here."
		r.stats.Text = string.format("Moves  %d\nCaptured  %d / %d", snap.moveCount, snap.targetsTotal - snap.targetsLeft, snap.targetsTotal)
		r.primary.Text = "Undo move"
		r.secondary.Text = "Restart"
	end
	if not wasShowing then
		r.dim.BackgroundTransparency = 1
		Anim.tween(r.dim, 0.25, { BackgroundTransparency = 0.4 })
		r.scale.Scale = 0.85
		Anim.tween(r.scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		if snap.status == "won" then
			Anim.burst(r.card, Theme.Gold, 18)
		end
	end
end

-- Input ----------------------------------------------------------------------------

function PuzzleHUD._onSquare(self: any, index: number)
	local snap = self.snapshot
	if not snap or self.pending or snap.status ~= "playing" then
		return
	end
	local square = self.squares[index]
	if index == self.playerSquare then
		self.selected = if self.selected == index then nil else index
		local scale = self.playerFrame and self.playerFrame:FindFirstChildOfClass("UIScale")
		if scale and self.selected then
			Anim.pulse(scale, 1.12, 0.25)
		end
		self:_renderHighlights()
		return
	end
	if self.selected and self.legal[index] then
		self.pending = true
		self.handlers.move(self.selected, index)
		task.delay(3, function()
			-- Never leave input locked if a response is lost.
			if self.snapshot == snap then
				self.pending = false
			end
		end)
		return
	end
	Anim.flash(square.button, Theme.Danger)
	local playerPiece = self.playerSquare and self.board.pieces[self.playerSquare]
	if not self.selected then
		self.messageLabel.Text = "Tap your white piece first."
	elseif playerPiece then
		self.messageLabel.Text = string.format(ERROR_MESSAGES.illegal_move, string.lower(PIECE_NAMES[playerPiece.kind]))
	end
	self.messageLabel.TextColor3 = Theme.Danger
end

-- The puzzle `offset` steps away in the catalogue, or nil when it is past the
-- end, the current mode has no neighbours (Daily), or Journey has it locked.
function PuzzleHUD._neighbour(self: any, offset: number): any
	local snap = self.snapshot
	if not snap or snap.mode == PLAY_MODES.Daily then
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
		self.messageLabel.Text = "The next difficulty is locked. Open Puzzles to see what unlocks it."
		self.messageLabel.TextColor3 = Theme.TextMuted
	else
		self.menu:open(snap.mode)
	end
end

return PuzzleHUD
