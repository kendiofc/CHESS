--!strict
-- Cosmetics: how equipped Shop items look on this player's own screen.
--
-- The server sends what each slot shows (snapshot.shop.equipped, already
-- checked against coins purchases and verified gamepasses); this only turns
-- those ids into colours and small effects. Nothing here is sent anywhere or
-- touches a puzzle, a move or a timer.

local GameConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GameConfig"))
local ShopCatalog = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ShopCatalog"))
local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))

local Cosmetics = {}

function Cosmetics.color(rgb: { number }?, fallback: Color3): Color3
	if not rgb then
		return fallback
	end
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

-- The item shown in a slot, from a snapshot's shop view.
function Cosmetics.item(equipped: { [string]: string }?, slot: string): ShopCatalog.Item
	local id = equipped and equipped[slot]
	return ShopCatalog.get(slot, id) or ShopCatalog.get(slot, GameConfig.COSMETIC_SLOTS[slot]) :: ShopCatalog.Item
end

-- Light and dark square colours.
function Cosmetics.board(equipped: { [string]: string }?): (Color3, Color3)
	local item = Cosmetics.item(equipped, "board")
	return Cosmetics.color(item.light, Color3.fromRGB(240, 218, 182)), Cosmetics.color(item.dark, Color3.fromRGB(182, 136, 98))
end

-- The player's piece tint and the colour of its glow.
function Cosmetics.pieces(equipped: { [string]: string }?): (Color3, Color3)
	local item = Cosmetics.item(equipped, "pieces")
	return Cosmetics.color(item.tint, Color3.new(1, 1, 1)), Cosmetics.color(item.glow, Color3.fromRGB(246, 198, 72))
end

-- The capture ripple colour, and whether sparks fly.
function Cosmetics.effect(equipped: { [string]: string }?): (Color3, boolean)
	local item = Cosmetics.item(equipped, "effect")
	return Cosmetics.color(item.glow, Color3.fromRGB(246, 198, 72)), item.sparks == true
end

-- A few sparks from one board square (a capture effect).
function Cosmetics.sparks(layer: GuiObject, position: UDim2, size: UDim2, color: Color3)
	local spot = Instance.new("Frame")
	spot.Name = "Sparks"
	spot.BackgroundTransparency = 1
	spot.Position = position
	spot.Size = size
	spot.ZIndex = 4
	spot.Parent = layer
	Anim.burst(spot, color, 8)
	task.delay(1, function()
		spot:Destroy()
	end)
end

-- Royal VIP: a shower of crowns over the win card.
function Cosmetics.crowns(parent: GuiObject)
	for i = 1, 10 do
		local crown = Instance.new("TextLabel")
		crown.Name = "Crown"
		crown.BackgroundTransparency = 1
		crown.Text = "👑"
		crown.TextScaled = true
		crown.AnchorPoint = Vector2.new(0.5, 0.5)
		crown.Size = UDim2.fromOffset(34, 34)
		crown.Position = UDim2.fromScale(0.1 + 0.8 * ((i - 1) / 9), -0.05)
		crown.Rotation = math.random(-20, 20)
		crown.ZIndex = 25
		crown.Parent = parent
		local delay = (i % 5) * 0.08
		task.delay(delay, function()
			if crown.Parent then
				Anim.tween(crown, 1.4, {
					Position = crown.Position + UDim2.fromScale((math.random() - 0.5) * 0.1, 0.75),
					Rotation = crown.Rotation + math.random(-40, 40),
					TextTransparency = 1,
				}, Enum.EasingStyle.Quad).Completed:Connect(function()
					crown:Destroy()
				end)
			end
		end)
	end
end

return Cosmetics
