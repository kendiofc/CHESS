--!strict
-- LeaderboardPage: the menu's Leaderboards. One tab per board (see
-- Leaderboards): the player's own standing, then the top players.
--
-- The page only draws what the server sent. It asks for a board when the tab
-- opens and again once its copy is a minute old; the server keeps its own
-- copy of the global board for a couple of minutes on top of that.
--
-- PuzzleMenu keeps the state (tab, boards received) on itself and calls
-- render() into its list.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Leaderboards = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Leaderboards"))

local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))
local Decor = require(script.Parent:WaitForChild("Decor"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local LeaderboardPage = {}

local STALE = 60 -- seconds before a shown board is asked for again
local ASK_GAP = 5 -- seconds between requests for the same board
local MEDALS = {
	Theme.Gold,
	Color3.fromRGB(196, 202, 216),
	Color3.fromRGB(214, 138, 74),
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

local function headshot(userId: number): string
	if userId <= 0 then
		return "" -- Studio test players have no avatar
	end
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", userId)
end

function LeaderboardPage.init(menu: any)
	menu.lbBoard = Leaderboards.list[1].id
	menu.lbData = {} -- board id -> { view, at }
	menu.lbAsked = {} -- board id -> os.clock() of the last request
end

-- Asks the server for a board, unless that was just done.
function LeaderboardPage.request(menu: any, id: string, force: boolean?)
	local asked = menu.lbAsked[id]
	if not force and asked and os.clock() - asked < ASK_GAP then
		return
	end
	menu.lbAsked[id] = os.clock()
	if menu.handlers.leaderboard then
		menu.handlers.leaderboard(id)
	end
end

-- A board view from the server.
function LeaderboardPage.onData(menu: any, view: any)
	if type(view) ~= "table" or not Leaderboards.get(view.board) or type(view.entries) ~= "table" then
		return
	end
	menu.lbData[view.board] = { view = view, at = os.clock() }
	if menu.view == "Leaderboards" and menu.lbBoard == view.board and menu.gui.Enabled and not menu.closing then
		menu:_render()
	end
end

local function tabs(menu: any, list: Instance, width: number)
	local count = #Leaderboards.list
	local columns = if width >= 540 then count else 3
	local rows = math.ceil(count / columns)
	local frame = make("Frame", {
		Name = "Tabs",
		LayoutOrder = 1,
		Size = UDim2.new(1, -8, 0, rows * 36 + (rows - 1) * 6),
		BackgroundTransparency = 1,
		Parent = list,
	}, {
		make("UIGridLayout", {
			-- One spare pixel per cell, or rounding wraps the last cell to a new row.
			CellSize = UDim2.new(1 / columns, -math.ceil(6 * (columns - 1) / columns) - 1, 0, 36),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index, board in ipairs(Leaderboards.list) do
		local selected = menu.lbBoard == board.id
		local button = make("TextButton", {
			Name = "Tab_" .. board.id,
			LayoutOrder = index,
			BackgroundColor3 = if selected then Theme.Gold else Theme.PanelRaised,
			FontFace = Theme.FontBold,
			Text = board.tab,
			TextColor3 = if selected then Color3.fromRGB(40, 24, 8) else Theme.Text,
			TextScaled = true,
			Parent = frame,
		}, {
			corner(10),
			make("UIStroke", {
				Color = if selected then Theme.Gold else Theme.Stroke,
				Thickness = 1,
				Transparency = if selected then 0 else 0.4,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
			make("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }),
			make("UITextSizeConstraint", { MaxTextSize = 14, MinTextSize = 9 }),
		})
		button.Activated:Connect(function()
			if menu.lbBoard ~= board.id then
				menu.lbBoard = board.id
				menu.lbAnimate = true
				menu.list.CanvasPosition = Vector2.zero
				menu:_render()
			end
		end)
	end
end

-- The round rank badge: a medal colour for the top three.
local function rankBadge(parent: Instance, rank: number?, x: number)
	local medal = rank and MEDALS[rank]
	local badge = make("Frame", {
		Name = "Rank",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, x, 0.5, 0),
		Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = medal or Theme.Panel,
		BackgroundTransparency = if medal then 0 else 0.2,
		Parent = parent,
	}, { corner(17) })
	local label = text({
		Text = if rank then tostring(rank) else "-",
		FontFace = Theme.FontHeavy,
		TextScaled = true,
		TextColor3 = if medal then Color3.fromRGB(36, 24, 10) else Theme.TextMuted,
		Size = UDim2.fromScale(1, 1),
		Parent = badge,
	})
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 5),
		PaddingRight = UDim.new(0, 5),
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		Parent = label,
	})
end

local function avatar(parent: Instance, userId: number, x: number, size: number)
	local frame = make("Frame", {
		Name = "Avatar",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, x, 0.5, 0),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Theme.Panel,
		Parent = parent,
	}, { corner(size // 2) })
	make("ImageLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = headshot(userId),
		Parent = frame,
	}, { corner(size // 2) })
end

-- One player's line: rank, avatar, name, score.
local function row(list: Instance, order: number, board: Leaderboards.Board, entry: any, mine: boolean)
	local frame = make("Frame", {
		Name = "Entry_" .. entry.rank,
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, 50),
		BackgroundColor3 = if mine then Color3.fromRGB(70, 58, 40) else Theme.PanelRaised,
		Parent = list,
	}, {
		corner(10),
		make("UIStroke", {
			Color = if mine then Theme.Gold else Theme.Stroke,
			Thickness = if mine then 1.5 else 1,
			Transparency = if mine then 0.1 else 0.6,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
	})
	frame:SetAttribute("UserId", entry.userId)
	rankBadge(frame, entry.rank, 8)
	avatar(frame, entry.userId, 50, 34)
	text({
		Name = "PlayerName",
		Text = (entry.name or ("Player " .. entry.userId)) .. (if mine then "  (you)" else ""),
		FontFace = Theme.FontBold,
		TextSize = 15,
		TextColor3 = if mine then Theme.Gold else Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(94, 0),
		Size = UDim2.new(1, -(94 + 118), 1, 0),
		Parent = frame,
	})
	text({
		Name = "Score",
		Text = Leaderboards.format(board, entry.value),
		FontFace = Theme.FontBold,
		TextSize = 15,
		TextColor3 = if entry.rank <= 3 then MEDALS[entry.rank] else Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 0),
		Size = UDim2.new(0, 110, 1, 0),
		Parent = frame,
	})
	return frame
end

-- The player's own standing on the board.
local function standing(list: Instance, board: Leaderboards.Board, view: any)
	local me = view.me or {}
	local frame = make("Frame", {
		Name = "Standing",
		LayoutOrder = 3,
		Size = UDim2.new(1, -8, 0, 74),
		BackgroundColor3 = Color3.fromRGB(52, 40, 92),
		Parent = list,
	}, {
		corner(12),
		make("UIStroke", { Color = Theme.Gold, Thickness = 1, Transparency = 0.45 }),
		make("UIGradient", {
			Rotation = 0,
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 160, 210)),
		}),
	})
	Decor.sheen(frame, 0.18)
	avatar(frame, Players.LocalPlayer.UserId, 14, 46)
	text({
		Name = "Heading",
		Text = string.upper(board.title),
		FontFace = Theme.FontBold,
		TextSize = 11,
		TextColor3 = Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(72, 12),
		Size = UDim2.new(1, -190, 0, 14),
		Parent = frame,
	})
	local place = if me.rank
		then "#" .. me.rank
		elseif (me.value or 0) <= 0 then "Not ranked yet"
		else string.format("Outside the top %d", Leaderboards.SIZE)
	text({
		Name = "Place",
		Text = place,
		FontFace = Theme.FontHeavy,
		TextSize = if me.rank then 24 else 17,
		TextColor3 = if me.rank and MEDALS[me.rank] then MEDALS[me.rank] else Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(72, 28),
		Size = UDim2.new(1, -190, 0, 32),
		Parent = frame,
	})
	text({
		Name = "Yours",
		Text = Leaderboards.format(board, me.value or 0),
		FontFace = Theme.FontHeavy,
		TextSize = 18,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(110, 26),
		Parent = frame,
	})
end

local function note(list: Instance, order: number, message: string)
	text({
		Name = "Note",
		LayoutOrder = order,
		Text = message,
		TextSize = 12,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = list,
	})
end

function LeaderboardPage.render(menu: any)
	local list = menu.list
	local board = Leaderboards.get(menu.lbBoard) or Leaderboards.list[1]
	menu.lbBoard = board.id
	tabs(menu, list, list.AbsoluteSize.X - 8)

	local held = menu.lbData[board.id]
	if not held or os.clock() - held.at >= STALE then
		LeaderboardPage.request(menu, board.id)
	end
	if not held then
		text({
			Name = "Loading",
			LayoutOrder = 3,
			Text = "Loading the leaderboard...",
			TextColor3 = Theme.TextMuted,
			Size = UDim2.new(1, -8, 0, 40),
			Parent = list,
		})
		return
	end
	local view = held.view
	standing(list, board, view)
	local myId = Players.LocalPlayer.UserId
	for index, entry in ipairs(view.entries) do
		if type(entry) == "table" and type(entry.userId) == "number" and type(entry.value) == "number" then
			row(list, 10 + index, board, entry, entry.userId == myId)
		end
	end
	if #view.entries == 0 then
		text({
			Name = "Empty",
			LayoutOrder = 10,
			Text = "No scores yet. Be the first!",
			TextColor3 = Theme.TextMuted,
			Size = UDim2.new(1, -8, 0, 40),
			Parent = list,
		})
	end
	if view.scope == "global" then
		note(list, 500, string.format("The top %d players on every server. Scores are added as your progress saves, and the board refreshes every few minutes.", Leaderboards.SIZE))
	else
		note(list, 500, "The global leaderboards can't be reached right now, so this shows the players on this server.")
	end

	-- Rows settle in when a board opens.
	if menu.lbAnimate then
		menu.lbAnimate = false
		local index = 0
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("Frame") and string.sub(child.Name, 1, 6) == "Entry_" then
				index += 1
				local scale = make("UIScale", { Scale = 0.95, Parent = child })
				task.delay(math.min(index, 10) * 0.02, function()
					Anim.tween(scale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back)
				end)
			end
		end
	end
end

return LeaderboardPage
