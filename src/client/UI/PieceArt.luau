--!strict
-- PieceArt: original 2D chess piece silhouettes built from GUI primitives, so
-- they stay crisp at any size and need no uploaded images. (Roblox fonts do not
-- include the Unicode chess glyphs.)
--
-- Each shape is { x, y, w, h, corner, rotation?, detail? } in scale units of
-- the piece's square box: (x, y) is the shape's centre, corner is a UICorner
-- scale (0.5 = fully round), detail shapes are drawn in the contrast colour.
-- Every body shape is drawn twice: a slightly larger outline copy underneath,
-- then the fill, which gives a single clean outline around the silhouette.

local Theme = require(script.Parent.Theme)

local PieceArt = {}

type Shape = { number }

local BASE: { Shape } = {
	{ 0.5, 0.875, 0.66, 0.11, 0.35 },
	{ 0.5, 0.8, 0.52, 0.07, 0.3 },
}

local SHAPES: { [string]: { Shape } } = {
	P = {
		{ 0.5, 0.64, 0.32, 0.3, 0.4 },
		{ 0.5, 0.48, 0.4, 0.07, 0.5 },
		{ 0.5, 0.34, 0.28, 0.28, 0.5 },
	},
	R = {
		{ 0.5, 0.57, 0.42, 0.42, 0.06 },
		{ 0.5, 0.34, 0.56, 0.1, 0.12 },
		{ 0.3, 0.245, 0.14, 0.13, 0.15 },
		{ 0.5, 0.245, 0.14, 0.13, 0.15 },
		{ 0.7, 0.245, 0.14, 0.13, 0.15 },
		{ 0.5, 0.42, 0.42, 0.035, 0, 0, 1 },
	},
	B = {
		{ 0.5, 0.66, 0.3, 0.28, 0.35 },
		{ 0.5, 0.5, 0.42, 0.07, 0.5 },
		{ 0.5, 0.32, 0.3, 0.36, 0.5 },
		{ 0.5, 0.115, 0.12, 0.12, 0.5 },
		{ 0.545, 0.3, 0.045, 0.17, 0.5, 35, 1 },
	},
	N = {
		{ 0.56, 0.63, 0.34, 0.36, 0.25, -12 },
		{ 0.6, 0.33, 0.3, 0.32, 0.3, 10 },
		{ 0.4, 0.38, 0.42, 0.2, 0.35, -32 },
		{ 0.64, 0.17, 0.09, 0.15, 0.4, 18 },
		{ 0.53, 0.31, 0.06, 0.06, 0.5, 0, 1 },
		{ 0.275, 0.47, 0.05, 0.05, 0.5, 0, 1 },
	},
	Q = {
		{ 0.5, 0.64, 0.36, 0.32, 0.3 },
		{ 0.5, 0.48, 0.46, 0.07, 0.5 },
		{ 0.5, 0.37, 0.48, 0.14, 0.2 },
		{ 0.27, 0.27, 0.06, 0.16, 0.3, -22 },
		{ 0.385, 0.25, 0.06, 0.18, 0.3, -10 },
		{ 0.5, 0.245, 0.06, 0.19, 0.3 },
		{ 0.615, 0.25, 0.06, 0.18, 0.3, 10 },
		{ 0.73, 0.27, 0.06, 0.16, 0.3, 22 },
		{ 0.23, 0.18, 0.1, 0.1, 0.5 },
		{ 0.365, 0.15, 0.1, 0.1, 0.5 },
		{ 0.5, 0.135, 0.1, 0.1, 0.5 },
		{ 0.635, 0.15, 0.1, 0.1, 0.5 },
		{ 0.77, 0.18, 0.1, 0.1, 0.5 },
	},
	K = {
		{ 0.5, 0.64, 0.38, 0.32, 0.3 },
		{ 0.5, 0.48, 0.48, 0.07, 0.5 },
		{ 0.5, 0.36, 0.46, 0.17, 0.25 },
		{ 0.5, 0.18, 0.08, 0.22, 0.2 },
		{ 0.5, 0.16, 0.22, 0.08, 0.2 },
	},
}

local OUTLINE = 0.045

local function addShape(parent: Instance, shape: Shape, color: Color3, grow: number, z: number)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(shape[1], shape[2])
	frame.Size = UDim2.fromScale(shape[3] + grow, shape[4] + grow)
	frame.Rotation = shape[6] or 0
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.ZIndex = z
	if shape[5] > 0 then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(shape[5], 0)
		corner.Parent = frame
	end
	frame.Parent = parent
end

-- Returns a transparent Frame (Size 1,1) holding the piece drawing.
function PieceArt.create(kind: string, color: "white" | "black"): Frame
	local palette = if color == "white" then Theme.PieceWhite else Theme.PieceBlack
	local root = Instance.new("Frame")
	root.Name = "Piece"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)

	local shapes = table.clone(BASE)
	for _, shape in ipairs(SHAPES[kind] or SHAPES.P) do
		table.insert(shapes, shape)
	end
	for _, shape in ipairs(shapes) do
		if not shape[7] then
			addShape(root, shape, palette.outline, OUTLINE, 1)
		end
	end
	for _, shape in ipairs(shapes) do
		if shape[7] then
			addShape(root, shape, palette.outline, 0, 3)
		else
			addShape(root, shape, palette.fill, 0, 2)
		end
	end
	return root
end

return PieceArt
