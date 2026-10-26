--!strict
-- ShopPage: the menu's Shop. Cosmetics only: board themes, chess skins (the
-- player's own piece) and capture effects, bought with earned coins or
-- included in a gamepass.
--
-- The page only asks. Coin purchases and equips are requests the server checks
-- against its own catalogue, coins and verified passes; a gamepass is offered
-- through Roblox's own purchase prompt and granted only after the server has
-- confirmed it with Roblox. Prices shown for passes come from Roblox when the
-- pass is configured, and are labelled as suggestions while it isn't (and
-- then nothing can be bought).
--
-- PuzzleMenu keeps the state (tab, notice, pending request) on itself and
-- calls render() into its list.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GamePassConfig = require(Shared:WaitForChild("GamePassConfig"))
local ShopCatalog = require(Shared:WaitForChild("ShopCatalog"))

local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))
local Sound = require(script.Parent.Parent:WaitForChild("SoundController"))
local Cosmetics = require(script.Parent:WaitForChild("Cosmetics"))
local Decor = require(script.Parent:WaitForChild("Decor"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local ShopPage = {}

-- Dark purple and gold.
local PURPLE = Color3.fromRGB(56, 30, 100)
local PURPLE_DEEP = Color3.fromRGB(32, 18, 60)
local PURPLE_STROKE = Color3.fromRGB(118, 82, 190)
local ROBUX = Color3.fromRGB(196, 150, 255)
local DISABLED = Color3.fromRGB(60, 56, 84)

ShopPage.TABS = {
	{ id = "Featured", label = "Featured" },
	{ id = "Gamepasses", label = "Gamepasses" },
	{ id = "pieces", label = "Chess Skins" },
	{ id = "board", label = "Board Themes" },
	{ id = "effect", label = "Effects" },
}

local ERRORS = {
	not_enough_coins = "You don't have enough coins for that yet.",
	owned = "You already own that.",
	not_owned = "You don't own that yet.",
	needs_pass = "That item comes with a gamepass you don't have.",
	unknown_item = "That item isn't available.",
	not_for_coins = "That item can't be bought with coins.",
	not_loaded = "Your progress is still loading. Try again in a moment.",
	rate_limited = "Too fast! Give it a moment.",
	purchase_cancelled = "Purchase cancelled. Nothing was charged and nothing changed.",
	purchase_unconfirmed = "Roblox hasn't confirmed that purchase yet, so nothing is unlocked. It's checked again every time you join.",
}

local NOT_SAVED = " Saving is unavailable right now, so this isn't saved yet. The game keeps trying."

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
		TextSize = 14,
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for key, value in pairs(props) do
		defaults[key] = value
	end
	return make("TextLabel", defaults)
end

local function fitText(label: TextLabel, max: number, min: number)
	label.TextScaled = true
	make("UITextSizeConstraint", { MaxTextSize = max, MinTextSize = min, Parent = label })
end

local function coinsText(amount: number): string
	return "🪙 " .. tostring(amount)
end

-- A card button. `style` is "gold" (buy), "accent" (equip), "done" (equipped
-- or owned: shown, not pressable) or "off" (not available).
local function actionButton(parent: Instance, name: string, label: string, style: string, onClick: (() -> ())?): TextButton
	local enabled = onClick ~= nil
	local background = if style == "gold"
		then Theme.Gold
		elseif style == "accent" then Theme.Accent
		elseif style == "done" then PURPLE_DEEP
		else DISABLED
	local button = make("TextButton", {
		Name = name,
		BackgroundColor3 = background,
		AutoButtonColor = enabled,
		FontFace = Theme.FontBold,
		Text = label,
		TextColor3 = if style == "gold" then Color3.fromRGB(40, 24, 8)
			elseif style == "done" then Theme.Gold
			elseif style == "off" then Theme.TextMuted
			else Theme.Text,
		Parent = parent,
	}, { corner(10) })
	fitText(button, 15, 10)
	make("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), Parent = button })
	if style == "done" then
		make("UIStroke", { Color = Theme.Gold, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = button })
	elseif style == "gold" then
		Decor.sheen(button, 0.3)
	end
	button:SetAttribute("Enabled", enabled)
	if onClick then
		button.Activated:Connect(onClick)
	end
	return button
end

-- Previews -------------------------------------------------------------------------------

local function boardPreview(parent: Instance, item: ShopCatalog.Item)
	local light = Cosmetics.color(item.light, Theme.SquareLight)
	local dark = Cosmetics.color(item.dark, Theme.SquareDark)
	local holder = make("Frame", {
		Name = "Preview",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.9),
		BackgroundColor3 = Theme.BoardRim,
		Parent = parent,
	}, {
		corner(6),
		make("UIAspectRatioConstraint", { AspectRatio = 1 }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, 3),
			PaddingBottom = UDim.new(0, 3),
			PaddingLeft = UDim.new(0, 3),
			PaddingRight = UDim.new(0, 3),
		}),
		make("UIGridLayout", {
			CellSize = UDim2.fromScale(0.25, 0.25),
			CellPadding = UDim2.new(),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for i = 0, 15 do
		local row, column = i // 4, i % 4
		make("Frame", {
			LayoutOrder = i,
			BackgroundColor3 = if (row + column) % 2 == 0 then light else dark,
			BorderSizePixel = 0,
			Parent = holder,
		})
	end
end

local function piecesPreview(parent: Instance, item: ShopCatalog.Item)
	local glow = Cosmetics.color(item.glow, Theme.Gold)
	local disc = make("Frame", {
		Name = "Preview",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.9),
		BackgroundColor3 = PURPLE_DEEP,
		Parent = parent,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		make("UIAspectRatioConstraint", { AspectRatio = 1 }),
		make("UIStroke", { Color = glow, Thickness = 2.5, Transparency = 0.1 }),
	})
	make("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.8),
		BackgroundColor3 = glow,
		BackgroundTransparency = 0.75,
		Parent = disc,
	}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
	if Theme.PieceSheet ~= "" then
		make("ImageLabel", {
			Name = "Piece",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.78, 0.78),
			BackgroundTransparency = 1,
			Image = Theme.PieceSheet,
			ImageRectSize = Vector2.new(Theme.PieceCell, Theme.PieceCell),
			ImageRectOffset = Vector2.new(Theme.PieceSheetColumns.Q * Theme.PieceCell, 0),
			ImageColor3 = Cosmetics.color(item.tint, Color3.new(1, 1, 1)),
			ScaleType = Enum.ScaleType.Fit,
			Parent = disc,
		})
	end
end

local function effectPreview(parent: Instance, item: ShopCatalog.Item)
	local glow = Cosmetics.color(item.glow, Theme.Gold)
	local disc = make("Frame", {
		Name = "Preview",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.9),
		BackgroundColor3 = PURPLE_DEEP,
		Parent = parent,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		make("UIAspectRatioConstraint", { AspectRatio = 1 }),
	})
	for i, scale in ipairs({ 0.92, 0.66, 0.4 }) do
		make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(scale, scale),
			BackgroundTransparency = 1,
			Parent = disc,
		}, {
			make("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
			make("UIStroke", { Color = glow, Thickness = 2, Transparency = 0.15 + i * 0.2 }),
		})
	end
	local icon = text({
		Text = item.icon or "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.36, 0.36),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = disc,
	})
	icon.TextScaled = true
end

local PREVIEWS = { board = boardPreview, pieces = piecesPreview, effect = effectPreview }

-- State ----------------------------------------------------------------------------------

local function cardName(item: ShopCatalog.Item): string
	return "Item_" .. item.slot .. "_" .. item.id
end

local function setNotice(menu: any, message: string, tone: string)
	menu.shopNotice = { text = message, tone = tone }
end

local function savedNote(menu: any): string
	return if menu.saveStatus == "ok" then "" else NOT_SAVED
end

-- Live gamepass price and sale state from Roblox, fetched once per session.
local function passInfo(menu: any, key: string): any
	if not GamePassConfig.isConfigured(key) then
		return nil
	end
	menu.passInfo = menu.passInfo or {}
	local info = menu.passInfo[key]
	if info == nil then
		menu.passInfo[key] = "loading"
		task.spawn(function()
			local ok, result = pcall(function()
				return MarketplaceService:GetProductInfo(GamePassConfig.PASSES[key].id, Enum.InfoType.GamePass)
			end)
			if ok and type(result) == "table" then
				menu.passInfo[key] = {
					price = if type(result.PriceInRobux) == "number" then result.PriceInRobux else nil,
					forSale = result.IsForSale == true,
				}
			else
				menu.passInfo[key] = "failed"
			end
			if menu.view == "Shop" and menu.gui.Enabled then
				menu:_render()
			end
		end)
		return "loading"
	end
	return info
end

-- Hooks the Roblox purchase prompt once, so the page knows when it closes.
-- (The server decides what the purchase unlocks; this only clears "waiting".)
function ShopPage.init(menu: any)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, _passId: number, purchased: boolean)
		if player ~= Players.LocalPlayer or not menu.passPrompt then
			return
		end
		if purchased then
			setNotice(menu, "Checking your purchase with Roblox...", "info")
		end
		menu.passPrompt = nil
		if menu.view == "Shop" and menu.gui.Enabled then
			menu:_render()
		end
	end)
	-- The grid's columns follow the panel width (which changes with the screen).
	menu.list:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if menu.view == "Shop" and menu.gui.Enabled and menu.shopWidth ~= menu.list.AbsoluteSize.X then
			task.defer(function()
				menu:_render()
			end)
		end
	end)
end

-- Every snapshot passes through here before the page redraws: it turns the
-- server's answer to a Shop request into the notice line.
function ShopPage.onSnapshot(menu: any, snap: any)
	local before = menu.shopState and menu.shopState.passes or {}
	menu.shopState = snap.shop or menu.shopState
	local pending = menu.shopPending
	local event, err = snap.event, snap.error
	if event == "shop_pass" then
		local passes = menu.shopState and menu.shopState.passes or {}
		for _, key in ipairs(GamePassConfig.ORDER) do
			if passes[key] and not before[key] then
				setNotice(menu, GamePassConfig.PASSES[key].name .. " is unlocked. Thank you for supporting Echo Chess!", "good")
				menu.shopCelebrate = "Pass_" .. key
				Sound.play("unlock")
				Sound.haptic("medium")
			end
		end
		menu.passPrompt = nil
	elseif pending and (event == "shop_bought" or event == "shop_equipped") then
		local item = ShopCatalog.get(pending.slot, pending.item)
		local name = if item then item.name else "That"
		if event == "shop_bought" then
			setNotice(menu, string.format("Bought %s and put it on.", name) .. savedNote(menu), "good")
			Sound.play("unlock")
			Sound.haptic("medium")
		else
			setNotice(menu, string.format("%s equipped.", name) .. savedNote(menu), "good")
		end
		if item then
			menu.shopCelebrate = cardName(item)
		end
		menu.shopPending = nil
	elseif err and (pending or err == "purchase_cancelled" or err == "purchase_unconfirmed") and ERRORS[err] then
		setNotice(menu, ERRORS[err], "bad")
		menu.shopPending = nil
		if err == "purchase_cancelled" or err == "purchase_unconfirmed" then
			menu.passPrompt = nil
		end
	end
end

local function request(menu: any, kind: string, item: ShopCatalog.Item)
	if menu.shopPending then
		return
	end
	local token = {}
	menu.shopPending = { kind = kind, slot = item.slot, item = item.id, token = token }
	menu.shopConfirm = nil
	menu.shopNotice = nil
	if kind == "buy" then
		menu.handlers.shopBuy(item.slot, item.id)
	else
		menu.handlers.shopEquip(item.slot, item.id)
	end
	menu:_render()
	task.delay(8, function()
		local still = menu.shopPending
		if still and still.token == token then
			menu.shopPending = nil
			setNotice(menu, "No answer from the server. Nothing changed; try again.", "bad")
			if menu.view == "Shop" and menu.gui.Enabled then
				menu:_render()
			end
		end
	end)
end

local function promptPass(menu: any, key: string)
	-- Unconfigured passes never get here (their button is disabled), but check anyway.
	if not GamePassConfig.isConfigured(key) or menu.passPrompt then
		return
	end
	menu.passPrompt = key
	menu.shopNotice = nil
	local ok = pcall(function()
		MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, GamePassConfig.PASSES[key].id :: number)
	end)
	if not ok then
		menu.passPrompt = nil
		setNotice(menu, "Couldn't open the Roblox purchase window. Try again in a moment.", "bad")
	end
	menu:_render()
end

-- Rendering ------------------------------------------------------------------------------

local function header(list: Instance, order: number, label: string)
	text({
		Name = "Header" .. order,
		LayoutOrder = order,
		Text = label,
		FontFace = Theme.FontBold,
		TextSize = 13,
		TextColor3 = Theme.Gold,
		Size = UDim2.new(1, -8, 0, 22),
		Parent = list,
	})
end

local function tabs(menu: any, list: Instance, width: number)
	local columns = if width >= 540 then 5 else 3
	local rows = math.ceil(#ShopPage.TABS / columns)
	local frame = make("Frame", {
		Name = "Tabs",
		LayoutOrder = 1,
		Size = UDim2.new(1, -8, 0, rows * 36 + (rows - 1) * 6),
		BackgroundTransparency = 1,
		Parent = list,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.new(1 / columns, -6 * (columns - 1) / columns, 0, 36),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index, tab in ipairs(ShopPage.TABS) do
		local selected = menu.shopTab == tab.id
		local button = make("TextButton", {
			Name = "Tab" .. tab.id,
			LayoutOrder = index,
			BackgroundColor3 = if selected then Theme.Gold else PURPLE,
			FontFace = Theme.FontBold,
			Text = tab.label,
			TextColor3 = if selected then Color3.fromRGB(40, 24, 8) else Theme.Text,
			Parent = frame,
		}, {
			corner(10),
			make("UIStroke", {
				Color = if selected then Theme.Gold else PURPLE_STROKE,
				Thickness = 1,
				Transparency = if selected then 0 else 0.4,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
			make("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }),
		})
		fitText(button, 14, 9)
		button.Activated:Connect(function()
			if menu.shopTab ~= tab.id then
				menu.shopTab = tab.id
				menu.shopConfirm = nil
				menu.shopAnimate = true
				menu.list.CanvasPosition = Vector2.zero
				menu:_render()
			end
		end)
	end
end

local function notice(menu: any, list: Instance)
	local current = menu.shopNotice
	local pending = menu.shopPending
	local message, tone
	if pending then
		message, tone = if pending.kind == "buy" then "Buying..." else "Equipping...", "info"
	elseif menu.passPrompt then
		message, tone = "Finish or close the Roblox purchase window to continue.", "info"
	elseif current then
		message, tone = current.text, current.tone
	else
		return
	end
	local color = if tone == "good" then Theme.Legal elseif tone == "bad" then Theme.Danger else Theme.Gold
	local frame = make("Frame", {
		Name = "Notice",
		LayoutOrder = 2,
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PURPLE_DEEP,
		Parent = list,
	}, {
		corner(10),
		make("UIStroke", { Color = color, Thickness = 1.5, Transparency = 0.2 }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
	})
	text({
		Name = "Text",
		Text = message,
		TextSize = 14,
		TextColor3 = color,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = frame,
	})
end

-- The item's button: what the player can do with it right now.
local function itemButton(menu: any, card: Frame, item: ShopCatalog.Item, ctx: any): TextButton
	local equipped = ctx.equipped[item.slot] == item.id
	local usable = ShopCatalog.usable(item, ctx.owned, ctx.passes)
	local pending = menu.shopPending
	local busy = pending ~= nil and pending.slot == item.slot and pending.item == item.id
	local button
	if busy then
		button = actionButton(card, "Action", "...", "off", nil)
	elseif equipped then
		button = actionButton(card, "Action", "Equipped ✓", "done", nil)
	elseif usable then
		button = actionButton(card, "Action", "Equip", "accent", function()
			request(menu, "equip", item)
		end)
	elseif item.coins then
		local key = ShopCatalog.ownKey(item)
		if ctx.coins >= item.coins then
			local confirming = menu.shopConfirm and menu.shopConfirm.key == key
			button = actionButton(card, "Action", if confirming then "Tap to confirm" else "Buy " .. coinsText(item.coins), "gold", function()
				if menu.shopConfirm and menu.shopConfirm.key == key then
					request(menu, "buy", item)
				else
					local token = {}
					menu.shopConfirm = { key = key, token = token }
					menu:_render()
					task.delay(4, function()
						if menu.shopConfirm and menu.shopConfirm.token == token then
							menu.shopConfirm = nil
							if menu.view == "Shop" and menu.gui.Enabled then
								menu:_render()
							end
						end
					end)
				end
			end)
		else
			button = actionButton(card, "Action", string.format("Need %s more", coinsText(item.coins - ctx.coins)), "off", nil)
		end
	elseif item.pass then
		-- Not a purchase: it shows the pass that includes the item.
		button = actionButton(card, "Action", "View pass", "accent", function()
			menu.shopTab = "Gamepasses"
			menu.shopAnimate = true
			menu.list.CanvasPosition = Vector2.zero
			menu:_render()
		end)
	else
		button = actionButton(card, "Action", "Unavailable", "off", nil)
	end
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -10)
	button.Size = UDim2.new(1, -20, 0, 34)
	return button
end

local function itemCard(menu: any, grid: Instance, order: number, item: ShopCatalog.Item, ctx: any)
	local equipped = ctx.equipped[item.slot] == item.id
	local usable = ShopCatalog.usable(item, ctx.owned, ctx.passes)
	local card = make("Frame", {
		Name = cardName(item),
		LayoutOrder = order,
		BackgroundColor3 = PURPLE,
		Parent = grid,
	}, {
		corner(12),
		make("UIStroke", {
			Color = if equipped then Theme.Gold else PURPLE_STROKE,
			Thickness = if equipped then 2 else 1,
			Transparency = if equipped then 0 else 0.45,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
	})
	Decor.sheen(card, 0.18)
	local stage = make("Frame", {
		Name = "Stage",
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 84),
		BackgroundColor3 = PURPLE_DEEP,
		Parent = card,
	}, { corner(10) })
	PREVIEWS[item.slot](stage, item)
	if usable and not item.free then
		local tag = text({
			Name = "OwnedTag",
			Text = "OWNED",
			FontFace = Theme.FontBold,
			TextSize = 10,
			TextColor3 = Color3.fromRGB(40, 24, 8),
			TextXAlignment = Enum.TextXAlignment.Center,
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Gold,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 6),
			Size = UDim2.fromOffset(48, 16),
			ZIndex = 3,
			Parent = stage,
		})
		corner(8).Parent = tag
	end
	local name = text({
		Name = "ItemName",
		Text = item.name,
		FontFace = Theme.FontBold,
		Position = UDim2.fromOffset(10, 100),
		Size = UDim2.new(1, -20, 0, 18),
		Parent = card,
	})
	fitText(name, 15, 10)
	text({
		Name = "Description",
		Text = item.description,
		TextSize = 12,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(10, 120),
		Size = UDim2.new(1, -20, 0, 30),
		Parent = card,
	})
	local source, sourceColor
	if item.free then
		source, sourceColor = "Free", Theme.TextMuted
	elseif item.coins then
		source, sourceColor = coinsText(item.coins) .. " coins", Theme.Gold
	else
		local pass = GamePassConfig.PASSES[item.pass :: string]
		source, sourceColor = "R$  ·  " .. (if pass then pass.name else "Gamepass"), ROBUX
	end
	local sourceLabel = text({
		Name = "Price",
		Text = source,
		FontFace = Theme.FontBold,
		TextColor3 = sourceColor,
		Position = UDim2.fromOffset(10, 152),
		Size = UDim2.new(1, -20, 0, 16),
		Parent = card,
	})
	fitText(sourceLabel, 13, 9)
	itemButton(menu, card, item, ctx)
	return card
end

local function itemGrid(menu: any, list: Instance, order: number, items: { ShopCatalog.Item }, ctx: any, width: number)
	local columns = if width >= 520 then 3 else 2
	local cellHeight = 214
	local rows = math.ceil(#items / columns)
	local grid = make("Frame", {
		Name = "Grid",
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, rows * cellHeight + math.max(0, rows - 1) * 10),
		BackgroundTransparency = 1,
		Parent = list,
	}, {
		make("UIGridLayout", {
			CellSize = UDim2.new(1 / columns, -10 * (columns - 1) / columns, 0, cellHeight),
			CellPadding = UDim2.fromOffset(10, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	for index, item in ipairs(items) do
		itemCard(menu, grid, index, item, ctx)
	end
end

local function passButton(menu: any, card: Frame, key: string, owned: boolean): TextButton
	local button
	if owned then
		button = actionButton(card, "Action", "Owned ✓", "done", nil)
	elseif not GamePassConfig.isConfigured(key) then
		button = actionButton(card, "Action", "Not available yet", "off", nil)
	elseif menu.passPrompt == key then
		button = actionButton(card, "Action", "Waiting for Roblox...", "off", nil)
	else
		local info = passInfo(menu, key)
		if info == "loading" then
			button = actionButton(card, "Action", "Loading...", "off", nil)
		elseif type(info) == "table" and not info.forSale then
			button = actionButton(card, "Action", "Not on sale", "off", nil)
		else
			local label = if type(info) == "table" and info.price then "Buy  ·  R$ " .. info.price else "Buy with Robux"
			button = actionButton(card, "Action", label, "gold", if menu.passPrompt
				then nil
				else function()
					promptPass(menu, key)
				end)
		end
	end
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -14)
	button.Size = UDim2.new(1, -28, 0, 40)
	return button
end

local function passCard(menu: any, list: Instance, order: number, key: string, ctx: any)
	local pass = GamePassConfig.PASSES[key]
	local owned = ctx.passes[key] == true
	local configured = GamePassConfig.isConfigured(key)
	local height = 96 + #pass.perks * 20 + 64
	local card = make("Frame", {
		Name = "Pass_" .. key,
		LayoutOrder = order,
		Size = UDim2.new(1, -8, 0, height),
		BackgroundColor3 = PURPLE,
		Parent = list,
	}, {
		corner(14),
		make("UIStroke", {
			Color = Theme.Gold,
			Thickness = if owned then 2.5 else 1.5,
			Transparency = if owned then 0 else 0.35,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
		make("UIGradient", {
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 130, 190)),
			Rotation = 90,
		}),
	})
	local badge = make("Frame", {
		Name = "Badge",
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.fromOffset(60, 60),
		BackgroundColor3 = Theme.Gold,
		Parent = card,
	}, {
		make("UICorner", { CornerRadius = UDim.new(0.5, 0) }),
		make("UIGradient", {
			Color = ColorSequence.new(Color3.fromRGB(255, 232, 150), Theme.GoldDeep),
			Rotation = 90,
		}),
	})
	local icon = text({
		Text = pass.icon,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.6, 0.6),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = badge,
	})
	icon.TextScaled = true
	local title = text({
		Name = "PassName",
		Text = pass.name,
		FontFace = Theme.FontHeavy,
		Position = UDim2.fromOffset(86, 14),
		Size = UDim2.new(1, -100, 0, 24),
		Parent = card,
	})
	fitText(title, 20, 12)
	Decor.goldText(title)
	local tagline = text({
		Text = pass.tagline,
		TextColor3 = Theme.TextMuted,
		Position = UDim2.fromOffset(86, 40),
		Size = UDim2.new(1, -100, 0, 16),
		Parent = card,
	})
	fitText(tagline, 13, 9)
	-- The live price once the pass exists; until then a labelled suggestion.
	local priceText
	if owned then
		priceText = "You own this pass"
	elseif not configured then
		priceText = string.format("R$ %d  ·  suggested price, not on sale yet", pass.suggestedPrice)
	else
		local info = passInfo(menu, key)
		priceText = if type(info) == "table" and info.price then "R$ " .. info.price else "Price from Roblox"
	end
	local price = text({
		Name = "PassPrice",
		Text = priceText,
		FontFace = Theme.FontBold,
		TextColor3 = if owned then Theme.Legal else ROBUX,
		Position = UDim2.fromOffset(86, 58),
		Size = UDim2.new(1, -100, 0, 16),
		Parent = card,
	})
	fitText(price, 13, 9)
	for index, perk in ipairs(pass.perks) do
		local line = text({
			Name = "Perk" .. index,
			Text = "✦  " .. perk,
			TextColor3 = Theme.Text,
			Position = UDim2.fromOffset(18, 86 + (index - 1) * 20),
			Size = UDim2.new(1, -36, 0, 18),
			Parent = card,
		})
		fitText(line, 13, 9)
	end
	passButton(menu, card, key, owned)
end

local function legend(list: Instance, order: number)
	text({
		Name = "Legend",
		LayoutOrder = order,
		Text = "🪙 items are bought once with coins you earn by playing. R$ items come with a gamepass. Everything here is cosmetic.",
		TextSize = 12,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = list,
	})
end

local function anyConfigured(): boolean
	for _, key in ipairs(GamePassConfig.ORDER) do
		if GamePassConfig.isConfigured(key) then
			return true
		end
	end
	return false
end

function ShopPage.render(menu: any)
	local list = menu.list
	local progress = menu.progress
	if not progress then
		text({ Text = "Loading the Shop...", Size = UDim2.new(1, 0, 0, 40), Parent = list })
		return
	end
	menu.shopTab = menu.shopTab or "Featured"
	local shop = menu.shopState or {}
	local ctx = {
		coins = progress.coins or 0,
		owned = progress.owned or {},
		passes = shop.passes or {},
		equipped = shop.equipped or {},
	}
	menu.shopWidth = list.AbsoluteSize.X
	local width = list.AbsoluteSize.X - 8
	tabs(menu, list, width)
	notice(menu, list)
	local tab = menu.shopTab
	if tab == "Featured" then
		passCard(menu, list, 3, "RoyalVIP", ctx)
		header(list, 4, "FEATURED ITEMS")
		local featured = {}
		for _, item in ipairs(ShopCatalog.list) do
			if item.featured then
				table.insert(featured, item)
			end
		end
		itemGrid(menu, list, 5, featured, ctx, width)
		legend(list, 6)
	elseif tab == "Gamepasses" then
		if not anyConfigured() then
			text({
				Name = "PassesNote",
				LayoutOrder = 3,
				Text = "Gamepasses aren't on sale yet. Prices shown are suggestions only.",
				TextSize = 13,
				TextColor3 = Theme.TextMuted,
				TextWrapped = true,
				Size = UDim2.new(1, -8, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Parent = list,
			})
		end
		for index, key in ipairs(GamePassConfig.ORDER) do
			passCard(menu, list, 3 + index, key, ctx)
		end
		text({
			Name = "PassesFairness",
			LayoutOrder = 20,
			Text = "Passes are cosmetic: they never change puzzles, hints, timers, rewards or duels. Purchases are made in Roblox's own window and unlock once Roblox confirms them.",
			TextSize = 12,
			TextColor3 = Theme.TextMuted,
			TextWrapped = true,
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = list,
		})
	else
		local items = {}
		for _, item in ipairs(ShopCatalog.list) do
			if item.slot == tab then
				table.insert(items, item)
			end
		end
		legend(list, 3)
		itemGrid(menu, list, 4, items, ctx, width)
	end

	-- Light motion: cards settle in when a tab opens, and a new purchase sparkles.
	if menu.shopAnimate then
		menu.shopAnimate = false
		local index = 0
		for _, child in ipairs(list:GetDescendants()) do
			if child:IsA("Frame") and (string.sub(child.Name, 1, 5) == "Item_" or string.sub(child.Name, 1, 5) == "Pass_") then
				index += 1
				local scale = make("UIScale", { Scale = 0.94, Parent = child })
				task.delay(math.min(index, 8) * 0.025, function()
					Anim.tween(scale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
				end)
			end
		end
	end
	local celebrate = menu.shopCelebrate
	menu.shopCelebrate = nil
	if celebrate then
		local target = list:FindFirstChild(celebrate, true)
		if target and target:IsA("GuiObject") then
			Anim.burst(target, Theme.Gold, 12)
			local scale = make("UIScale", { Parent = target })
			Anim.pulse(scale, 1.05, 0.3)
		end
	end
end

return ShopPage
