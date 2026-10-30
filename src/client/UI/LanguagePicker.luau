--!strict
-- LanguagePicker: the "choose your language" card. Shown on a player's first
-- join (until they pick one) and from Settings.
--
-- Picking switches the screens at once (Lang.set) and asks the server to save
-- the choice with the player's settings. On first join the card can't be
-- closed without picking; the language the player's Roblox account uses is
-- marked as the suggestion.

local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))
local Decor = require(script.Parent:WaitForChild("Decor"))
local Lang = require(script.Parent:WaitForChild("Lang"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local LanguagePicker = {}
LanguagePicker.__index = LanguagePicker

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

-- `onPick(code)` runs when a language is chosen.
function LanguagePicker.new(playerGui: Instance, onPick: (string) -> ())
	local self = setmetatable({}, LanguagePicker) :: any
	self.onPick = onPick
	local gui = make("ScreenGui", {
		Name = "EchoChessLanguage",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 6,
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
	dim:SetAttribute("Silent", true)
	local card = make("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -32, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		Parent = dim,
	}, {
		corner(18),
		make("UIStroke", { Color = Theme.Gold, Thickness = 1.5, Transparency = 0.3 }),
		make("UISizeConstraint", { MaxSize = Vector2.new(420, math.huge) }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, 18),
			PaddingBottom = UDim.new(0, 18),
			PaddingLeft = UDim.new(0, 18),
			PaddingRight = UDim.new(0, 18),
		}),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }),
	})
	Decor.sheen(card, 0.14)
	self.card = card
	self.scale = make("UIScale", { Parent = card })
	make("TextLabel", {
		Name = "Globe",
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
		FontFace = Theme.FontBold,
		Text = "🌐",
		TextSize = 34,
		TextColor3 = Theme.Text,
		Parent = card,
	})
	self.title = make("TextLabel", {
		Name = "Title",
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		FontFace = Theme.FontHeavy,
		Text = "Choose your language",
		TextSize = 22,
		TextColor3 = Theme.Gold,
		TextWrapped = true,
		Parent = card,
	})
	make("TextLabel", {
		Name = "Sub",
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		FontFace = Theme.Font,
		Text = "You can change it any time in Settings.",
		TextSize = 13,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		Parent = card,
	})
	self.buttons = {}
	for index, language in ipairs(Lang.LANGUAGES) do
		local button = make("TextButton", {
			Name = "Lang_" .. language.code,
			LayoutOrder = 10 + index,
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundColor3 = Theme.PanelRaised,
			AutoButtonColor = true,
			Text = "",
			Parent = card,
		}, {
			corner(12),
			make("UIStroke", { Name = "Stroke", Color = Theme.Stroke, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
		})
		-- Each language is named in its own language, whatever is shown.
		make("TextLabel", {
			Name = "Native",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(1, -120, 1, 0),
			FontFace = Theme.FontBold,
			Text = language.name,
			TextSize = 18,
			TextColor3 = Theme.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = button,
		})
		local tag = make("TextLabel", {
			Name = "Tag",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Size = UDim2.fromOffset(110, 20),
			FontFace = Theme.FontBold,
			Text = "",
			TextSize = 12,
			TextColor3 = Theme.Gold,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = button,
		})
		button.Activated:Connect(function()
			if os.clock() - self.openedAt < 0.3 then
				return -- the press that opened the card
			end
			self:close()
			self.onPick(language.code)
		end)
		self.buttons[language.code] = { button = button, tag = tag }
	end
	self.closeButton = make("TextButton", {
		Name = "Close",
		LayoutOrder = 100,
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = Theme.Panel,
		AutoButtonColor = true,
		FontFace = Theme.FontBold,
		Text = "Cancel",
		TextSize = 16,
		TextColor3 = Theme.TextMuted,
		Parent = card,
	}, { corner(12) })
	self.closeButton.Activated:Connect(function()
		self:close()
	end)
	self.openedAt = 0
	return self
end

-- `required`: the first-join card, which has no Cancel.
function LanguagePicker.open(self: any, selected: string?, required: boolean?)
	local suggested = Lang.suggested()
	for code, entry in pairs(self.buttons) do
		local isSelected = code == selected
		entry.button.BackgroundColor3 = if isSelected then Color3.fromRGB(70, 58, 40) else Theme.PanelRaised
		local stroke = entry.button:FindFirstChild("Stroke") :: UIStroke
		stroke.Color = if isSelected then Theme.Gold else Theme.Stroke
		entry.tag.Text = if isSelected then "✓" elseif code == suggested and required then "Suggested" else ""
	end
	self.closeButton.Visible = not required
	self.openedAt = os.clock()
	self.gui.Enabled = true
	self.scale.Scale = 0.92
	Anim.tween(self.scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

function LanguagePicker.close(self: any)
	self.gui.Enabled = false
end

function LanguagePicker.isOpen(self: any): boolean
	return self.gui.Enabled
end

return LanguagePicker
