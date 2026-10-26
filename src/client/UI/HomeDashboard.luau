--!strict
-- HomeDashboard: the menu's Home page. It is drawn from scratch for a given
-- width (PuzzleMenu redraws it on every snapshot and resize):
--
--   top bar     avatar, name, level and XP, coins, save status
--   hero        crown, title, tagline (and a big king on wide screens)
--   mode cards  Journey, Puzzle Duel, Daily Puzzle, Weekly Challenge
--   continue    the next Journey puzzle (or the attempt in progress)
--   streak      the Daily streak over the last 7 days
--   stats       duel wins, puzzles solved, stars, this week's progress
--
-- Everything shown comes from the server's snapshot (`data.progress`);
-- buttons only call back into PuzzleMenu, which sends requests as before.

local TweenService = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Progression = require(Shared:WaitForChild("Progression"))

local Theme = require(script.Parent:WaitForChild("Theme"))

local HomeDashboard = {}

-- Show "Lv. N" worked out from XP (Progression.levelOf). Off shows XP only.
HomeDashboard.SHOW_LEVEL = true

export type Continue = {
	title: string,
	sub: string,
	button: string,
	fraction: number?,
	action: (() -> ())?,
}

export type Data = {
	progress: any,
	loading: boolean,
	saveStatus: string?,
	playerName: string,
	avatar: string?,
	queued: boolean,
	serverPlayers: number,
	weeklyLeftText: string?,
	continue: Continue,
}

export type Actions = {
	open: (view: string) -> (),
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

local function stroke(color: Color3, thickness: number, transparency: number?): UIStroke
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function gradient(top: Color3, bottom: Color3): UIGradient
	return make("UIGradient", { Color = ColorSequence.new(top, bottom), Rotation = 90 })
end

-- 4320 -> "4,320"
local function commas(value: number): string
	local digits = tostring(math.floor(value))
	local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (out:gsub("^,", ""))
end
HomeDashboard.commas = commas

local function piece(kind: string, props: { [string]: any }): ImageLabel?
	if Theme.PieceSheet == "" then
		return nil
	end
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		Image = Theme.PieceSheet,
		ImageRectSize = Vector2.new(Theme.PieceCell, Theme.PieceCell),
		ImageRectOffset = Vector2.new((Theme.PieceSheetColumns[kind] or 5) * Theme.PieceCell, 0),
		ScaleType = Enum.ScaleType.Fit,
	}
	for key, value in pairs(props) do
		defaults[key] = value
	end
	return make("ImageLabel", defaults)
end

-- A soft round glow: stacked translucent circles, like Decor's backdrop.
local function glow(parent: Instance, center: Vector2, size: number, color: Color3)
	local holder = make("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(center.X, center.Y),
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	for i = 1, 10 do
		local scale = 1.1 - i * 0.1
		make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(scale, scale),
			BackgroundColor3 = color,
			BackgroundTransparency = 0.965,
			BorderSizePixel = 0,
			Parent = holder,
		}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	end
end

-- Grows a little under the pointer, like the reference's raised cards.
local function hoverLift(button: GuiButton)
	local scale = make("UIScale", { Parent = button })
	button.MouseEnter:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.15), { Scale = 1.025 }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(scale, TweenInfo.new(0.15), { Scale = 1 }):Play()
	end)
end

local function progressBar(parent: Instance, position: UDim2, size: UDim2, fraction: number, colors: { Color3 })
	local track = make("Frame", {
		Name = "Bar",
		Position = position,
		Size = size,
		BackgroundColor3 = Color3.fromRGB(26, 26, 48),
		BorderSizePixel = 0,
		Parent = parent,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	local fill = make("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Visible = fraction > 0,
		Parent = track,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	make("UIGradient", { Color = ColorSequence.new(colors[1], colors[2] or colors[1]), Parent = fill })
	return track
end

-- A small rounded label in a card's top-right corner.
local function badge(parent: Instance, label: string, color: Color3, filled: boolean): TextLabel
	local chip = text({
		Name = "Badge",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = if filled then color else Color3.fromRGB(16, 16, 34),
		BackgroundTransparency = if filled then 0 else 0.2,
		FontFace = Theme.FontBold,
		Text = label,
		TextColor3 = if filled then Color3.new(1, 1, 1) else color,
		TextSize = 13,
		ZIndex = 3,
		Parent = parent,
	}, nil)
	make("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = chip })
	corner(13).Parent = chip
	stroke(color, 1.5, if filled then 1 else 0.1).Parent = chip
	return chip
end

-- Mode cards -------------------------------------------------------------------------------

local CARD_STYLES = {
	Journey = { top = Color3.fromRGB(96, 72, 34), bottom = Color3.fromRGB(40, 32, 40), edge = Theme.Gold, width = 2.5 },
	Duel = { top = Color3.fromRGB(72, 54, 142), bottom = Color3.fromRGB(34, 30, 72), edge = Color3.fromRGB(132, 106, 240), width = 1.5 },
	Daily = { top = Color3.fromRGB(42, 62, 132), bottom = Color3.fromRGB(24, 30, 68), edge = Color3.fromRGB(92, 124, 232), width = 1.5 },
	Weekly = { top = Color3.fromRGB(92, 54, 164), bottom = Color3.fromRGB(40, 26, 90), edge = Color3.fromRGB(166, 116, 255), width = 1.5 },
}

local function modeCard(
	parent: Instance,
	name: string,
	rect: { x: number, y: number, w: number, h: number },
	content: { icon: string, title: string, desc: string, status: string },
	small: boolean,
	onPress: () -> ()
): TextButton
	local style = CARD_STYLES[name]
	local card = make("TextButton", {
		Name = name .. "Card",
		Position = UDim2.fromOffset(rect.x, rect.y),
		Size = UDim2.fromOffset(rect.w, rect.h),
		BackgroundColor3 = Color3.new(1, 1, 1),
		AutoButtonColor = false,
		Text = "",
		Parent = parent,
	}, { corner(18), gradient(style.top, style.bottom), stroke(style.edge, style.width, 0.05) })
	hoverLift(card)
	text({
		Name = "Icon",
		Position = UDim2.fromOffset(0, if small then 18 else 26),
		Size = UDim2.new(1, 0, 0, if small then 48 else 62),
		FontFace = Theme.FontBold,
		Text = content.icon,
		TextSize = if small then 40 else 54,
		Parent = card,
	})
	local title = text({
		Name = "Title",
		Position = UDim2.fromOffset(10, if small then 72 else 96),
		Size = UDim2.new(1, -20, 0, if small then 26 else 32),
		FontFace = Theme.FontHeavy,
		Text = content.title,
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
		Parent = card,
	})
	make("UITextSizeConstraint", { MaxTextSize = if small then 20 else 26, MinTextSize = 12, Parent = title })
	text({
		Name = "Desc",
		Position = UDim2.fromOffset(12, if small then 102 else 134),
		Size = UDim2.new(1, -24, 0, if small then 36 else 42),
		Text = content.desc,
		TextColor3 = Theme.TextMuted,
		TextSize = if small then 12 else 15,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = card,
	})
	text({
		Name = "Status",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -12),
		Size = UDim2.new(1, -20, 0, 18),
		FontFace = Theme.FontBold,
		Text = content.status,
		TextColor3 = style.edge:Lerp(Color3.new(1, 1, 1), 0.35),
		TextSize = if small then 12 else 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = card,
	})
	card.Activated:Connect(onPress)
	return card
end

-- Streak -----------------------------------------------------------------------------------

-- The last 7 UTC days, oldest first: "done", "shield" (missed but covered
-- by the shield), "today" (not cleared yet) or "none".
function HomeDashboard.streakDays(streak: any, day: number): { string }
	local days = {}
	local current = streak and streak.current or 0
	local last
	if current > 0 then
		if streak.clearedToday then
			last = day
		elseif streak.atRisk then
			last = day - 2
		else
			last = day - 1
		end
	end
	for i = 1, 7 do
		local d = day - (7 - i)
		local state = "none"
		if last and d <= last and d > last - current then
			state = if streak.protectedDay == d then "shield" else "done"
		elseif d == day then
			state = "today"
		end
		days[i] = state
	end
	return days
end

-- Build --------------------------------------------------------------------------------------

-- Draws the page into `holder` (a ScrollingFrame) for a content `width`.
-- Returns labels PuzzleMenu keeps ticking.
function HomeDashboard.render(holder: ScrollingFrame, width: number, data: Data, actions: Actions): { [string]: any }
	for _, child in ipairs(holder:GetChildren()) do
		child:Destroy()
	end
	local progress = data.progress
	local loading = data.loading or progress == nil
	local pad = if width >= 760 then 32 elseif width >= 360 then 14 else 10
	local W = math.max(180, width - pad * 2)
	local tiny = W < 320
	local compact = W < 600
	local wide = W >= 880
	local gap = if compact then 12 else 18
	local page = make("Frame", {
		Name = "Page",
		Position = UDim2.fromOffset(pad, if compact then 14 else 22),
		Size = UDim2.fromOffset(W, 0),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	local y = 0
	local ticking = {}

	-- Top bar ----------------------------------------------------------------------------
	local avatarSize = if compact then 48 else 60
	local avatar = make("ImageLabel", {
		Name = "Avatar",
		Size = UDim2.fromOffset(avatarSize, avatarSize),
		BackgroundColor3 = Theme.PanelRaised,
		Image = data.avatar or "",
		ScaleType = Enum.ScaleType.Crop,
		Parent = page,
	}, { corner(14), stroke(Theme.Stroke, 1.5) })
	if not data.avatar and Theme.PieceSheet ~= "" then
		piece("P", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.7, 0.7),
			Parent = avatar,
		})
	end
	local coinsW = if tiny then 92 elseif compact then 116 else 150
	local coinsH = if compact then 40 else 50
	local nameX = avatarSize + 12
	local nameW = if compact then W - nameX - coinsW - 8 else 230
	text({
		Name = "Welcome",
		Position = UDim2.fromOffset(nameX, if compact then 2 else 6),
		Size = UDim2.fromOffset(nameW, 18),
		Text = "Welcome back,",
		TextColor3 = Theme.TextMuted,
		TextSize = if tiny then 11 elseif compact then 13 else 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = page,
	})
	local nameLabel = text({
		Name = "PlayerName",
		Position = UDim2.fromOffset(nameX, if compact then 20 else 26),
		Size = UDim2.fromOffset(nameW, if compact then 24 else 30),
		FontFace = Theme.FontHeavy,
		Text = data.playerName,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = page,
	})
	-- Long names shrink to fit beside the coins rather than being cut off.
	make("UITextSizeConstraint", { MaxTextSize = if compact then 19 else 24, MinTextSize = 10, Parent = nameLabel })

	-- Coins (cosmetic currency; nothing can be bought, so there's no "+").
	local coins = make("Frame", {
		Name = "Coins",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromOffset(W, if compact then 4 else 6),
		Size = UDim2.fromOffset(coinsW, coinsH),
		BackgroundColor3 = Color3.fromRGB(20, 20, 40),
		BackgroundTransparency = 0.1,
		Parent = page,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }), stroke(Theme.Stroke, 1.5, 0.2) })
	local coinSize = coinsH - 16
	local coin = make("Frame", {
		Name = "Coin",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromOffset(coinSize, coinSize),
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
	text({
		Name = "Amount",
		Position = UDim2.fromOffset(coinSize + 16, 0),
		Size = UDim2.new(1, -(coinSize + 24), 1, 0),
		FontFace = Theme.FontHeavy,
		Text = if loading then "..." else commas(progress.coins),
		TextSize = if compact then 17 else 21,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = false,
		Parent = coins,
	})
	if data.saveStatus == "offline" then
		-- Rewards still show, but nothing claims they're stored.
		text({
			Name = "SaveStatus",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromOffset(W, (if compact then 4 else 6) + coinsH + 4),
			Size = UDim2.fromOffset(coinsW + 40, 16),
			Text = "Not saving right now",
			TextColor3 = Theme.Danger:Lerp(Theme.Text, 0.3),
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = page,
		})
	end

	-- Level and XP.
	local xpX, xpY, xpW
	if compact then
		xpX, xpY, xpW = 0, avatarSize + 26, W
	else
		xpX, xpY = nameX + nameW + 16, 8
		xpW = math.min(340, W - xpX - coinsW - 32)
	end
	if xpW >= 140 then
		local xp = make("Frame", {
			Name = "XP",
			Position = UDim2.fromOffset(xpX, xpY),
			Size = UDim2.fromOffset(xpW, 44),
			BackgroundTransparency = 1,
			Parent = page,
		})
		local levelText, amountText, fraction = "XP", "Loading...", 0
		if not loading then
			if HomeDashboard.SHOW_LEVEL then
				local level = Progression.levelOf(progress.xp)
				levelText = "Lv. " .. level.level
				amountText = string.format("%s / %s XP", commas(level.into), commas(level.needed))
				fraction = level.into / level.needed
			else
				amountText = commas(progress.xp) .. " XP"
			end
		end
		local pill = text({
			Name = "Level",
			Size = UDim2.fromOffset(0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = Theme.Accent,
			BackgroundTransparency = 0,
			FontFace = Theme.FontHeavy,
			Text = levelText,
			TextSize = 14,
			Parent = xp,
		})
		make("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = pill })
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = pill })
		text({
			Name = "Amount",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(1, -90, 0, 24),
			FontFace = Theme.FontBold,
			Text = amountText,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = xp,
		})
		if HomeDashboard.SHOW_LEVEL then
			progressBar(xp, UDim2.fromOffset(0, 32), UDim2.new(1, 0, 0, 10), fraction, {
				Color3.fromRGB(150, 110, 255),
				Theme.Accent,
			})
		end
	end
	y = if compact then avatarSize + 78 else 76

	-- Hero ---------------------------------------------------------------------------------
	local heroH = if compact then 132 else 206
	if wide and Theme.PieceSheet ~= "" then
		-- A big lit king on the right, as in the reference.
		-- It stands on the cards' top edge, clear of the coins above it.
		local kingSize = math.min(230, math.floor(W * 0.17))
		local center = Vector2.new(W - kingSize * 0.6, y + heroH - kingSize * 0.5)
		glow(page, center, kingSize * 1.6, Theme.Accent)
		piece("K", {
			Name = "HeroKing",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(center.X, center.Y),
			Size = UDim2.fromOffset(kingSize, kingSize),
			ImageColor3 = Color3.fromRGB(236, 226, 255),
			Parent = page,
		})
	end
	text({
		Name = "Crown",
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.new(1, 0, 0, if compact then 40 else 62),
		FontFace = Theme.FontBold,
		Text = "👑",
		TextSize = if compact then 34 else 56,
		Parent = page,
	})
	local title = text({
		Name = "Title",
		Position = UDim2.fromOffset(0, y + (if compact then 38 else 60)),
		Size = UDim2.new(1, 0, 0, if compact then 52 else 92),
		FontFace = Theme.FontHeavy,
		RichText = true,
		Text = 'Echo <font color="#F6C648">Chess</font>',
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = if compact then 44 else 84,
		Parent = page,
	})
	make("UITextSizeConstraint", { MaxTextSize = if compact then 44 else 84, Parent = title })
	title.TextScaled = W < 420
	text({
		Name = "Tagline",
		Position = UDim2.fromOffset(0, y + (if compact then 92 else 156)),
		Size = UDim2.new(1, 0, 0, if compact then 36 else 30),
		Text = if compact
			then "Chess Puzzles  ·  Daily  ·  Duel  ·  Progression"
			else "Chess Puzzles   •   Daily Challenges   •   Duel   •   Progression",
		TextColor3 = Theme.TextMuted,
		TextSize = if compact then 13 else 21,
		TextWrapped = true,
		Parent = page,
	})
	y += heroH

	-- Mode cards ---------------------------------------------------------------------------
	local columns = if wide then 4 elseif W >= 260 then 2 else 1
	local cardW = math.floor((W - gap * (columns - 1)) / columns)
	local cardH = if wide then 236 elseif compact then 188 else 214
	local small = cardW < 200
	local function cardRect(index: number)
		local column = (index - 1) % columns
		local row = (index - 1) // columns
		return { x = column * (cardW + gap), y = y + row * (cardH + gap), w = cardW, h = cardH }
	end
	local unlocked = if loading then "Beginner" else GameConfig.DIFFICULTIES[progress.unlockedIndex] or "Beginner"
	local journeyCard = modeCard(page, "Journey", cardRect(1), {
		icon = "🏔",
		title = "Journey",
		desc = "Progress through curated puzzles",
		status = if loading
			then "Loading..."
			elseif small then string.format("%s  ·  %d / %d", unlocked, progress.totals.cleared, progress.totals.puzzles)
			else string.format("%s unlocked  ·  %d / %d", unlocked, progress.totals.cleared, progress.totals.puzzles),
	}, small, function()
		actions.open("Journey")
	end)
	local duel = if loading then nil else progress.duel
	local duelCard = modeCard(page, "Duel", cardRect(2), {
		icon = "⚔️",
		title = "Puzzle Duel",
		desc = "Race another player on the same puzzle",
		status = if duel then string.format("%d W  ·  %d L  ·  %d D", duel.wins, duel.losses, duel.draws) else "",
	}, small, function()
		actions.open("Duel")
	end)
	if data.queued then
		badge(duelCard, "SEARCHING", Theme.Gold, false)
	elseif data.serverPlayers > 1 then
		badge(duelCard, string.format("● %d HERE", data.serverPlayers), Theme.Legal, false)
	else
		badge(duelCard, "● JUST YOU", Theme.TextMuted, false)
	end
	local daily = if loading then nil else progress.daily
	local dailyCard = modeCard(page, "Daily", cardRect(3), {
		icon = "📅",
		title = "Daily Puzzle",
		desc = "A new puzzle every day",
		status = if daily == nil then "" elseif daily.completed then "Cleared today ✓" else "Not cleared yet today",
	}, small, function()
		actions.open("Daily")
	end)
	if daily and daily.completed then
		badge(dailyCard, "✓", Theme.Legal, true)
	elseif daily then
		badge(dailyCard, "!", Theme.Danger, true)
	end
	local weekly = if loading then nil else progress.weekly
	local weeklyCard = modeCard(page, "Weekly", cardRect(4), {
		icon = "🏆",
		title = "Weekly Challenge",
		desc = "Complete 4 puzzles for bigger rewards",
		status = if weekly == nil
			then ""
			elseif weekly.completed then "Complete ✓"
			else string.format("%d / %d cleared", weekly.clearedCount, weekly.size),
	}, small, function()
		actions.open("Weekly")
	end)
	if data.weeklyLeftText then
		ticking.weeklyBadge = badge(weeklyCard, "⏱ " .. data.weeklyLeftText, Color3.fromRGB(196, 170, 255), false)
	end
	journeyCard.Name = "JourneyCard"
	y += math.ceil(4 / columns) * (cardH + gap) + (if compact then 4 else 10)

	-- Continue and streak --------------------------------------------------------------------
	local side = wide
	local continueW = if side then math.floor(W * 0.62) else W
	local continueH = if compact then 178 else 140
	local streakW = if side then W - continueW - gap else W
	local cont = data.continue
	local panel = make("TextButton", {
		Name = "ContinuePanel",
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.fromOffset(continueW, continueH),
		BackgroundColor3 = Color3.new(1, 1, 1),
		AutoButtonColor = false,
		Text = "",
		Parent = page,
	}, {
		corner(18),
		gradient(Color3.fromRGB(42, 36, 62), Color3.fromRGB(26, 24, 44)),
		stroke(Theme.Gold, 2, 0.15),
	})
	local rookSize = if compact then 72 else 104
	piece("R", {
		Name = "Rook",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = if compact then UDim2.fromOffset(10, 52) else UDim2.new(0, 18, 0.5, 0),
		Size = UDim2.fromOffset(rookSize, rookSize),
		ImageColor3 = Color3.fromRGB(240, 200, 120),
		Parent = panel,
	})
	local textX = rookSize + (if compact then 18 else 34)
	local buttonW = if compact then continueW - 28 else 176
	local textW = if compact then continueW - textX - 14 else continueW - textX - buttonW - 40
	text({
		Name = "Title",
		Position = UDim2.fromOffset(textX, if compact then 18 else 26),
		Size = UDim2.fromOffset(textW, 30),
		FontFace = Theme.FontHeavy,
		Text = cont.title,
		TextSize = if compact then 20 else 26,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = panel,
	})
	text({
		Name = "Sub",
		Position = UDim2.fromOffset(textX, if compact then 48 else 62),
		Size = UDim2.fromOffset(textW, 22),
		Text = cont.sub,
		TextColor3 = Theme.TextMuted,
		TextSize = if compact then 14 else 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = panel,
	})
	if cont.fraction then
		progressBar(
			panel,
			UDim2.fromOffset(textX, if compact then 80 else 100),
			UDim2.fromOffset(textW, 10),
			cont.fraction,
			{ Color3.fromRGB(80, 220, 130), Theme.Legal }
		)
	end
	-- The gradient would tint the button's own text, so the label is a child.
	local go = make("TextButton", {
		Name = "ContinueButton",
		AnchorPoint = if compact then Vector2.new(0, 1) else Vector2.new(1, 0.5),
		Position = if compact then UDim2.new(0, 14, 1, -14) else UDim2.new(1, -22, 0.5, 0),
		Size = UDim2.fromOffset(buttonW, if compact then 48 else 56),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = if cont.action then 0 else 0.5,
		AutoButtonColor = false,
		Text = "",
		Parent = panel,
	}, {
		corner(14),
		gradient(Color3.fromRGB(150, 118, 255), Theme.AccentPressed),
	})
	hoverLift(go)
	text({
		Name = "Label",
		Size = UDim2.fromScale(1, 1),
		FontFace = Theme.FontHeavy,
		Text = cont.button .. "  ▶",
		TextColor3 = Color3.new(1, 1, 1),
		TextTransparency = if cont.action then 0 else 0.4,
		TextSize = if compact then 17 else 19,
		Parent = go,
	})
	local function runContinue()
		if cont.action then
			cont.action()
		end
	end
	go.Activated:Connect(runContinue)
	panel.Activated:Connect(runContinue)
	panel:SetAttribute("Silent", true)

	local streakY = if side then y else y + continueH + gap
	local streakTop = 18
	local boxes = HomeDashboard.streakDays(if loading then nil else progress.streak, if loading then 0 else progress.daily.day)
	local boxGap = 8
	local boxRight = streakW >= 7 * 30 + 6 * boxGap + 190
	local boxSize = if boxRight then 30 else math.min(32, math.floor((streakW - 32 - 6 * boxGap) / 7))
	local streakH = if side then continueH elseif boxRight then 116 else 140
	local streak = make("TextButton", {
		Name = "StreakPanel",
		Position = UDim2.fromOffset(if side then continueW + gap else 0, streakY),
		Size = UDim2.fromOffset(streakW, streakH),
		BackgroundColor3 = Color3.new(1, 1, 1),
		AutoButtonColor = false,
		Text = "",
		Parent = page,
	}, {
		corner(18),
		gradient(Color3.fromRGB(46, 36, 40), Color3.fromRGB(28, 24, 36)),
		stroke(Theme.Gold, 2, 0.25),
	})
	hoverLift(streak)
	text({
		Name = "Flame",
		Position = UDim2.fromOffset(16, streakTop),
		Size = UDim2.fromOffset(32, 32),
		FontFace = Theme.FontBold,
		Text = "🔥",
		TextSize = 26,
		Parent = streak,
	})
	text({
		Name = "Label",
		Position = UDim2.fromOffset(56, streakTop + 4),
		Size = UDim2.new(1, -70, 0, 24),
		FontFace = Theme.FontBold,
		Text = "Daily Streak",
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = streak,
	})
	local current = if loading then 0 else progress.streak.current
	text({
		Name = "Days",
		Position = UDim2.fromOffset(56, streakTop + 34),
		Size = UDim2.fromOffset(150, 36),
		FontFace = Theme.FontHeavy,
		Text = if loading then "..." else string.format("%d %s", current, if current == 1 then "day" else "days"),
		TextSize = if compact then 26 else 30,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = streak,
	})
	local rowW = 7 * boxSize + 6 * boxGap
	local boxX = if boxRight then streakW - rowW - 20 else math.floor((streakW - rowW) / 2)
	local boxY = if boxRight then streakTop + 38 else streakTop + 80
	for i, state in ipairs(boxes) do
		local box = make("Frame", {
			Name = "Day" .. i,
			Position = UDim2.fromOffset(boxX + (i - 1) * (boxSize + boxGap), boxY),
			Size = UDim2.fromOffset(boxSize, boxSize),
			BackgroundColor3 = if state == "done" then Theme.Legal else Color3.fromRGB(24, 22, 40),
			Parent = streak,
		}, { corner(7) })
		if state == "today" then
			stroke(Theme.Gold, 1.5, 0.1).Parent = box
		elseif state ~= "done" then
			stroke(Theme.Stroke, 1.5, 0.2).Parent = box
		end
		local mark = if state == "done" then "✓" elseif state == "shield" then "🛡" else ""
		if mark ~= "" then
			text({
				Size = UDim2.fromScale(1, 1),
				FontFace = Theme.FontHeavy,
				Text = mark,
				TextSize = math.floor(boxSize * 0.62),
				Parent = box,
			})
		end
	end
	streak.Activated:Connect(function()
		actions.open("Daily")
	end)
	y = streakY + streakH + gap + (if compact then 2 else 6)

	-- Stats ------------------------------------------------------------------------------------
	local statColumns = if wide then 4 elseif W >= 300 then 2 else 1
	local statW = math.floor((W - gap * (statColumns - 1)) / statColumns)
	local statH = if compact then 76 else 92
	local totals = if loading then nil else progress.totals
	-- Short labels where the tiles are narrow (two columns on a phone).
	local short = statW < 190
	local stats = {
		{ "🏆", if short then "Duel wins" else "Wins (Duel)", if duel then commas(duel.wins) else "-", "Duel" },
		{
			"📊",
			if short then "Solved" else "Puzzles Solved",
			if totals then string.format("%d / %d", totals.cleared, totals.puzzles) else "-",
			"Stats",
		},
		{ "⭐", if short then "Stars" else "Total Stars", if totals then string.format("%d / %d", totals.stars, totals.maxStars) else "-", "Stats" },
		{
			"📅",
			if short then "This week" else "Current Week",
			if weekly then string.format("%d / %d", weekly.clearedCount, weekly.size) else "-",
			"Weekly",
		},
	}
	for index, stat in ipairs(stats) do
		local column = (index - 1) % statColumns
		local row = (index - 1) // statColumns
		local tile = make("TextButton", {
			Name = "Stat" .. index,
			Position = UDim2.fromOffset(column * (statW + gap), y + row * (statH + gap)),
			Size = UDim2.fromOffset(statW, statH),
			BackgroundColor3 = Color3.new(1, 1, 1),
			AutoButtonColor = false,
			Text = "",
			Parent = page,
		}, {
			corner(16),
			gradient(Color3.fromRGB(34, 34, 60), Color3.fromRGB(24, 24, 44)),
			stroke(Theme.Stroke, 1.5, 0.35),
		})
		hoverLift(tile)
		local iconSize = if compact then 26 else 34
		text({
			Name = "Icon",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, if compact then 12 else 22, 0.5, 0),
			Size = UDim2.fromOffset(iconSize + 6, iconSize + 6),
			FontFace = Theme.FontBold,
			Text = stat[1],
			TextSize = iconSize,
			Parent = tile,
		})
		local textX = if compact then 50 else 76
		text({
			Name = "Label",
			Position = UDim2.fromOffset(textX, if compact then 14 else 20),
			Size = UDim2.new(1, -(textX + 8), 0, 18),
			Text = stat[2],
			TextColor3 = Theme.TextMuted,
			TextSize = if compact then 12 else 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = tile,
		})
		text({
			Name = "Value",
			Position = UDim2.fromOffset(textX, if compact then 34 else 42),
			Size = UDim2.new(1, -(textX + 8), 0, if compact then 28 else 34),
			FontFace = Theme.FontHeavy,
			Text = stat[3],
			TextSize = if compact then 21 else 28,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = tile,
		})
		local view = stat[4]
		tile.Activated:Connect(function()
			actions.open(view)
		end)
	end
	y += math.ceil(#stats / statColumns) * (statH + gap)

	page.Size = UDim2.fromOffset(W, y)
	holder.CanvasSize = UDim2.fromOffset(0, y + (if compact then 14 else 22) + 16)
	return ticking
end

return HomeDashboard
