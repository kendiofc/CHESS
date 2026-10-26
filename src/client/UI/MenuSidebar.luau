--!strict
-- MenuSidebar: the menu's left navigation. Expanded it shows icons and
-- labels; collapsed it is a rail of icons. PuzzleMenu decides the width and
-- whether it pushes the page over or floats above it (on narrow screens).

local TweenService = game:GetService("TweenService")

local Decor = require(script.Parent:WaitForChild("Decor"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local MenuSidebar = {}
MenuSidebar.__index = MenuSidebar

MenuSidebar.EXPANDED = 236
MenuSidebar.COLLAPSED = 72

export type Item = { id: string, icon: string, label: string, footer: boolean? }

local ITEM_HEIGHT = 48
local DENSE_ITEM_HEIGHT = 38
local LOGO_HEIGHT = 76
local DENSE_LOGO_HEIGHT = 52

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

-- `onSelect(id)` runs when an enabled item is pressed.
function MenuSidebar.new(parent: Instance, items: { Item }, onSelect: (string) -> ())
	local self = setmetatable({}, MenuSidebar) :: any
	self.items = {}
	self.selected = nil
	self.collapsed = false
	self.dense = false
	self.topInset = 0

	local frame = make("Frame", {
		Name = "Sidebar",
		Size = UDim2.new(0, MenuSidebar.EXPANDED, 1, 0),
		BackgroundColor3 = Color3.fromRGB(13, 13, 28),
		BackgroundTransparency = 0.04,
		BorderSizePixel = 0,
		ZIndex = 20,
		Parent = parent,
	})
	self.frame = frame
	-- A thin edge on the right, and a shadow that only shows while the
	-- sidebar floats over the page.
	make("Frame", {
		Name = "Edge",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 1, 1, 0),
		BackgroundColor3 = Theme.Stroke,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ZIndex = 21,
		Parent = frame,
	})
	self.shadow = make("Frame", {
		Name = "Shadow",
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 24, 1, 0),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 19,
		Parent = frame,
	}, {
		make("UIGradient", {
			Transparency = NumberSequence.new(0.45, 1),
		}),
	})

	-- Logo: a gold king and the name.
	local logo = make("Frame", {
		Name = "Logo",
		Size = UDim2.new(1, 0, 0, 76),
		BackgroundTransparency = 1,
		ZIndex = 21,
		Parent = frame,
	})
	if Theme.PieceSheet ~= "" then
		self.logoIcon = make("ImageLabel", {
			Name = "Crest",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(36, 40),
			Size = UDim2.fromOffset(36, 36),
			BackgroundTransparency = 1,
			Image = Theme.PieceSheet,
			ImageRectSize = Vector2.new(Theme.PieceCell, Theme.PieceCell),
			ImageRectOffset = Vector2.new(Theme.PieceSheetColumns.K * Theme.PieceCell, 0),
			ImageColor3 = Theme.Gold,
			ScaleType = Enum.ScaleType.Fit,
			ZIndex = 22,
			Parent = logo,
		})
	end
	self.logoText = make("TextLabel", {
		Name = "Name",
		Position = UDim2.fromOffset(62, 24),
		Size = UDim2.new(1, -72, 0, 32),
		BackgroundTransparency = 1,
		FontFace = Theme.FontHeavy,
		Text = "Echo Chess",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 22,
		Parent = logo,
	})
	Decor.goldText(self.logoText)

	-- Main items scroll if the screen is short; footer items stay at the bottom.
	local footerCount = 0
	for _, item in ipairs(items) do
		if item.footer then
			footerCount += 1
		end
	end
	self.footerCount = footerCount
	local footerHeight = footerCount * (ITEM_HEIGHT + 6) + 22
	local list = make("ScrollingFrame", {
		Name = "Items",
		Position = UDim2.fromOffset(0, 80),
		Size = UDim2.new(1, 0, 1, -(80 + footerHeight)),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Theme.Stroke,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ZIndex = 21,
		Parent = frame,
	}, {
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
		make("UIPadding", {
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 8),
		}),
	})
	self.list = list
	local footer = make("Frame", {
		Name = "Footer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, footerHeight),
		BackgroundTransparency = 1,
		ZIndex = 21,
		Parent = frame,
	}, {
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),
		make("UIPadding", {
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
			PaddingTop = UDim.new(0, 12),
		}),
	})
	self.footer = footer
	self.logo = logo
	self.divider = make("Frame", {
		Name = "Divider",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, -footerHeight + 4),
		Size = UDim2.new(1, -36, 0, 1),
		BackgroundColor3 = Theme.Stroke,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		ZIndex = 22,
		Parent = frame,
	})

	for order, item in ipairs(items) do
		local button = make("TextButton", {
			Name = item.id .. "Nav",
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, ITEM_HEIGHT),
			BackgroundColor3 = Theme.Accent,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = "",
			ZIndex = 22,
			Parent = if item.footer then footer else list,
		}, { corner(12) })
		local fill = make("UIGradient", {
			Color = ColorSequence.new(Color3.fromRGB(150, 118, 255), Theme.AccentPressed),
			Rotation = 90,
			Enabled = false,
			Parent = button,
		})
		local icon = make("TextLabel", {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(24, ITEM_HEIGHT / 2),
			Size = UDim2.fromOffset(32, 32),
			BackgroundTransparency = 1,
			FontFace = Theme.FontBold,
			Text = item.icon,
			TextColor3 = Theme.Text,
			TextSize = 22,
			ZIndex = 23,
			Parent = button,
		})
		local label = make("TextLabel", {
			Name = "Label",
			Position = UDim2.fromOffset(50, 0),
			Size = UDim2.new(1, -78, 1, 0),
			BackgroundTransparency = 1,
			FontFace = Theme.FontBold,
			Text = item.label,
			TextColor3 = Theme.Text,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 23,
			Parent = button,
		})
		local dot = make("Frame", {
			Name = "Dot",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, -18, 0.5, 0),
			Size = UDim2.fromOffset(10, 10),
			BackgroundColor3 = Theme.Legal,
			Visible = false,
			ZIndex = 24,
			Parent = button,
		}, { make("UICorner", { CornerRadius = UDim.new(0.5, 0) }) })
		local entry = {
			item = item,
			button = button,
			fill = fill,
			icon = icon,
			label = label,
			dot = dot,
			enabled = true,
			hover = false,
		}
		self.items[item.id] = entry
		button.MouseEnter:Connect(function()
			entry.hover = true
			self:_paint(entry)
		end)
		button.MouseLeave:Connect(function()
			entry.hover = false
			self:_paint(entry)
		end)
		button.Activated:Connect(function()
			if entry.enabled then
				onSelect(item.id)
			end
		end)
		self:_paint(entry)
	end
	return self
end

function MenuSidebar._paint(self: any, entry: any)
	local selected = self.selected == entry.item.id
	entry.fill.Enabled = selected
	local transparency = if selected then 0 elseif entry.hover and entry.enabled then 0.85 else 1
	TweenService:Create(entry.button, TweenInfo.new(0.12), { BackgroundTransparency = transparency }):Play()
	local dim = if entry.enabled then 0 else 0.6
	entry.icon.TextTransparency = dim
	entry.label.TextTransparency = dim
	entry.label.TextColor3 = if selected then Color3.new(1, 1, 1) else Theme.Text
end

function MenuSidebar.setSelected(self: any, id: string?)
	self.selected = id
	for _, entry in pairs(self.items) do
		self:_paint(entry)
	end
end

function MenuSidebar.setEnabled(self: any, id: string, enabled: boolean)
	local entry = self.items[id]
	if entry and entry.enabled ~= enabled then
		entry.enabled = enabled
		entry.button.AutoButtonColor = false
		self:_paint(entry)
	end
end

function MenuSidebar.setDot(self: any, id: string, visible: boolean)
	local entry = self.items[id]
	if entry then
		entry.dot.Visible = visible
	end
end

function MenuSidebar.setLabel(self: any, id: string, label: string)
	local entry = self.items[id]
	if entry then
		entry.label.Text = label
	end
end

-- Dense: shorter rows and a shorter logo, so every item fits on a screen
-- that is not tall (a phone held sideways).
function MenuSidebar.setDense(self: any, dense: boolean)
	if self.dense == dense then
		return
	end
	self.dense = dense
	local itemH = if dense then DENSE_ITEM_HEIGHT else ITEM_HEIGHT
	local logoH = if dense then DENSE_LOGO_HEIGHT else LOGO_HEIGHT
	local footerHeight = self.footerCount * (itemH + 6) + (if dense then 14 else 22)
	if self.logoIcon then
		self.logoIcon.Size = UDim2.fromOffset(if dense then 28 else 36, if dense then 28 else 36)
		self.logoIcon.Position = UDim2.fromOffset(self.logoIcon.Position.X.Offset, logoH / 2)
	end
	self.logoText.Position = UDim2.fromOffset(62, logoH / 2 - 16)
	self.logoText.TextSize = if dense then 18 else 22
	self.footer.Size = UDim2.new(1, 0, 0, footerHeight)
	-- On a short screen the rail has to scroll, so make the bar easy to see.
	self.list.ScrollBarThickness = if dense then 5 else 3
	self.list.ScrollBarImageColor3 = if dense then Theme.Accent else Theme.Stroke
	self.list.ScrollBarImageTransparency = if dense then 0.15 else 0
	self.divider.Position = UDim2.new(0.5, 0, 1, -footerHeight + 4)
	for _, entry in pairs(self.items) do
		entry.button.Size = UDim2.new(1, 0, 0, itemH)
		entry.icon.TextSize = if dense then 19 else 22
		entry.label.TextSize = if dense then 15 else 16
	end
	self:_place()
	self:setMode(self.collapsed, self.floating or false)
end

-- The panel runs to the top of the screen, under Roblox's own buttons;
-- `top` pushes the logo and items down below them.
function MenuSidebar.setTopInset(self: any, top: number)
	if self.topInset ~= top then
		self.topInset = top
		self:_place()
	end
end

function MenuSidebar._place(self: any)
	local itemH = if self.dense then DENSE_ITEM_HEIGHT else ITEM_HEIGHT
	local logoH = if self.dense then DENSE_LOGO_HEIGHT else LOGO_HEIGHT
	local footerHeight = self.footerCount * (itemH + 6) + (if self.dense then 14 else 22)
	self.logo.Position = UDim2.fromOffset(0, self.topInset)
	self.logo.Size = UDim2.new(1, 0, 0, logoH)
	self.list.Position = UDim2.fromOffset(0, self.topInset + logoH + 4)
	self.list.Size = UDim2.new(1, 0, 1, -(self.topInset + logoH + 4 + footerHeight))
end

-- Collapsed: icons only, centred in the rail, with the dot on the icon.
-- `floating`: drawn over the page with a shadow (narrow screens).
function MenuSidebar.setMode(self: any, collapsed: boolean, floating: boolean)
	self.collapsed = collapsed
	self.floating = floating
	local itemH = if self.dense then DENSE_ITEM_HEIGHT else ITEM_HEIGHT
	local width = if collapsed then MenuSidebar.COLLAPSED else MenuSidebar.EXPANDED
	self.frame.Size = UDim2.new(0, width, 1, 0)
	self.shadow.Visible = floating and not collapsed
	self.logoText.Visible = not collapsed
	if self.logoIcon then
		self.logoIcon.Position =
			UDim2.fromOffset(if collapsed then MenuSidebar.COLLAPSED / 2 else 36, self.logo.Size.Y.Offset / 2)
	end
	for _, entry in pairs(self.items) do
		entry.label.Visible = not collapsed
		entry.icon.Position = UDim2.fromOffset(if collapsed then (MenuSidebar.COLLAPSED - 24) / 2 else 24, itemH / 2)
		entry.dot.Position = if collapsed then UDim2.new(1, -8, 0, 10) else UDim2.new(1, -18, 0.5, 0)
	end
end

return MenuSidebar
