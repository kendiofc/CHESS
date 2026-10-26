--!strict
-- Decor: purely visual touches shared by the HUD and menus. Nothing here
-- takes input or changes layout; every piece is a child that can be
-- destroyed with its parent.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent:WaitForChild("Theme"))

local Decor = {}

local function make(className: string, props: { [string]: any }): any
	local instance = Instance.new(className)
	local parent = props.Parent
	for key, value in pairs(props) do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	instance.Parent = parent
	return instance
end

local function forever(instance: Instance, seconds: number, goals: { [string]: any }, reverses: boolean, delay: number?)
	local info = TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, reverses, delay or 0)
	TweenService:Create(instance, info, goals):Play()
end

-- A top-to-bottom shade over a GuiObject's own fill (and text). `amount` is
-- how much darker the bottom is, 0..1.
function Decor.sheen(object: GuiObject, amount: number?): UIGradient
	local low = 1 - (amount or 0.14)
	return make("UIGradient", {
		Name = "Sheen",
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(low, low, low)),
		Rotation = 90,
		Parent = object,
	})
end

-- Gold shimmer for headline text.
function Decor.goldText(object: GuiObject): UIGradient
	return make("UIGradient", {
		Name = "Gold",
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 232, 150)),
			ColorSequenceKeypoint.new(0.55, Theme.Gold),
			ColorSequenceKeypoint.new(1, Theme.GoldDeep),
		}),
		Rotation = 90,
		Parent = object,
	})
end

-- Full-screen background: a deep gradient, two soft glows and a few faint
-- chess pieces drifting slowly.
function Decor.backdrop(gui: ScreenGui)
	local base = make("Frame", {
		Name = "Base",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = gui,
	})
	make("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Background),
			ColorSequenceKeypoint.new(0.6, Theme.Background:Lerp(Theme.BackgroundDeep, 0.55)),
			ColorSequenceKeypoint.new(1, Theme.BackgroundDeep),
		}),
		Rotation = 115,
		Parent = base,
	})

	-- Soft glows: stacked translucent circles read as one blurred blob.
	local function glow(x: number, y: number, color: Color3, period: number)
		local holder = make("Frame", {
			Name = "Glow",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(x, y),
			Size = UDim2.fromScale(0.7, 0.7),
			BackgroundTransparency = 1,
			Parent = base,
		})
		make("UIAspectRatioConstraint", { AspectRatio = 1, Parent = holder })
		for i = 1, 10 do
			local scale = 1.1 - i * 0.1
			local circle = make("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(scale, scale),
				BackgroundColor3 = color,
				BackgroundTransparency = 0.984,
				BorderSizePixel = 0,
				Parent = holder,
			})
			make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = circle })
		end
		forever(holder, period, { Position = UDim2.fromScale(x + 0.06, y - 0.05) }, true)
	end
	glow(0.15, 0.2, Theme.Accent, 14)
	glow(0.88, 0.85, Theme.Gold, 17)

	if Theme.PieceSheet == "" then
		return
	end
	-- { x, y, size (px), kind, rotation, drift period }
	local drifting = {
		{ 0.07, 0.62, 150, "N", -12, 19 },
		{ 0.2, 0.92, 96, "P", 8, 15 },
		{ 0.27, 0.12, 110, "R", 10, 21 },
		{ 0.8, 0.14, 130, "Q", -8, 18 },
		{ 0.94, 0.48, 104, "B", 14, 16 },
		{ 0.74, 0.8, 86, "K", -6, 22 },
	}
	for _, d in ipairs(drifting) do
		local image = make("ImageLabel", {
			Name = "Drift",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(d[1], d[2]),
			Size = UDim2.fromOffset(d[3], d[3]),
			Rotation = d[5],
			BackgroundTransparency = 1,
			Image = Theme.PieceSheet,
			ImageRectSize = Vector2.new(Theme.PieceCell, Theme.PieceCell),
			ImageRectOffset = Vector2.new((Theme.PieceSheetColumns[d[4]] or 5) * Theme.PieceCell, 0),
			ImageColor3 = Color3.fromRGB(200, 196, 255),
			ImageTransparency = 0.95,
			Parent = base,
		})
		forever(image, d[6], {
			Position = UDim2.new(d[1], 0, d[2], -28),
			Rotation = d[5] + 8,
		}, true)
	end
end

-- Wooden rim with a gold inlay and a drop shadow around a board frame.
-- The board's own layers must sit above ZIndex 2.
function Decor.boardFrame(board: GuiObject)
	local shadow = make("Frame", {
		Name = "Shadow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 8),
		Size = UDim2.new(1, 26, 1, 26),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		ZIndex = 0,
		Parent = board,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 16), Parent = shadow })
	local rim = make("Frame", {
		Name = "Rim",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 16, 1, 16),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = board,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 10), Parent = rim })
	make("UIGradient", {
		Color = ColorSequence.new(Theme.BoardRimLight, Theme.BoardRim),
		Rotation = 90,
		Parent = rim,
	})
	make("UIStroke", {
		Color = Theme.BoardInlay,
		Thickness = 1.5,
		Transparency = 0.35,
		Parent = rim,
	})
	local inlay = make("Frame", {
		Name = "Inlay",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 4, 1, 4),
		BackgroundColor3 = Theme.BoardInlay,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = board,
	})
	make("UICorner", { CornerRadius = UDim.new(0, 3), Parent = inlay })
end

-- A dark copy of a piece image, offset down-right, as its shadow.
function Decor.pieceShadow(art: GuiObject)
	if not art:IsA("ImageLabel") then
		return
	end
	local shadow = art:Clone()
	shadow.Name = "Shadow"
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ImageTransparency = 0.62
	shadow.Position = art.Position + UDim2.fromScale(0.035, 0.045)
	shadow.ZIndex = art.ZIndex - 1
	shadow.Parent = art.Parent
end

-- The player's piece: a steady golden glow with an echo ring that keeps
-- spreading out from it. Both sit under the art (ZIndex 3) and its shadow (2).
function Decor.aura(holder: GuiObject)
	local glow = make("Frame", {
		Name = "Aura",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.8),
		BackgroundColor3 = Theme.Gold,
		BackgroundTransparency = 0.72,
		BorderSizePixel = 0,
		ZIndex = 1,
		Parent = holder,
	})
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = glow })
	make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 0.8),
		}),
		Rotation = 90,
		Parent = glow,
	})
	forever(glow, 1.4, { BackgroundTransparency = 0.82 }, true)
	local echo = make("Frame", {
		Name = "Echo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		BackgroundTransparency = 1,
		ZIndex = 1,
		Parent = holder,
	})
	make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = echo })
	local ring = make("UIStroke", { Color = Theme.Gold, Thickness = 2.5, Transparency = 0.2, Parent = echo })
	local info = TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, -1, false, 0.5)
	TweenService:Create(echo, info, { Size = UDim2.fromScale(1.05, 1.05) }):Play()
	TweenService:Create(ring, info, { Transparency = 1 }):Play()
end

-- Rings spreading from a captured square: the "echo" of the taken piece.
function Decor.ripple(layer: GuiObject, position: UDim2, size: UDim2, color: Color3)
	for i = 0, 1 do
		local ring = make("Frame", {
			Name = "Ripple",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = position + UDim2.fromScale(size.X.Scale / 2, size.Y.Scale / 2),
			Size = UDim2.fromScale(size.X.Scale * 0.5, size.Y.Scale * 0.5),
			BackgroundTransparency = 1,
			ZIndex = 1,
			Parent = layer,
		})
		make("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = ring })
		local line = make("UIStroke", { Color = color, Thickness = 4 - i, Parent = ring })
		local info = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, i * 0.12)
		TweenService:Create(ring, info, { Size = UDim2.fromScale(size.X.Scale * 1.7, size.Y.Scale * 1.7) }):Play()
		local fade = TweenService:Create(line, info, { Transparency = 1 })
		fade.Completed:Connect(function()
			ring:Destroy()
		end)
		fade:Play()
	end
end

return Decor
