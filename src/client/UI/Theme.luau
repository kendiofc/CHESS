--!strict
-- Theme: colours, fonts and sizes for the Echo Chess UI.

local Theme = {}

-- Midnight indigo screens around a warm wooden board.
Theme.Background = Color3.fromRGB(16, 17, 32)
Theme.BackgroundDeep = Color3.fromRGB(40, 28, 78)
Theme.Panel = Color3.fromRGB(30, 31, 54)
Theme.PanelRaised = Color3.fromRGB(45, 46, 76)
Theme.Stroke = Color3.fromRGB(74, 76, 118)

Theme.Text = Color3.fromRGB(240, 236, 226)
Theme.TextMuted = Color3.fromRGB(160, 162, 192)

Theme.SquareLight = Color3.fromRGB(240, 218, 182)
Theme.SquareDark = Color3.fromRGB(182, 136, 98)
Theme.BlockedBase = Color3.fromRGB(54, 50, 72)
Theme.BlockedHatch = Color3.fromRGB(96, 90, 124)

-- Board frame: a wooden rim with a gold inlay, over a soft shadow.
Theme.BoardRim = Color3.fromRGB(104, 66, 40)
Theme.BoardRimLight = Color3.fromRGB(150, 100, 62)
Theme.BoardInlay = Color3.fromRGB(222, 176, 92)

Theme.Accent = Color3.fromRGB(122, 92, 250)
Theme.AccentPressed = Color3.fromRGB(98, 72, 214)
Theme.Legal = Color3.fromRGB(52, 196, 104)
Theme.Selected = Color3.fromRGB(250, 214, 92)
Theme.LastMove = Color3.fromRGB(246, 222, 120)
Theme.Danger = Color3.fromRGB(232, 84, 84)
Theme.Gold = Color3.fromRGB(246, 198, 72)
Theme.GoldDeep = Color3.fromRGB(196, 134, 30)

-- Piece sprite sheet (assets/pieces.png): 6 x 2 cells of PieceCell pixels,
-- columns K Q B N R P, white row on top. Set to the uploaded image's
-- "rbxassetid://..." to use it; while empty, PieceArt draws its own shapes.
Theme.PieceSheet = "rbxassetid://76170447278040"
Theme.PieceCell = 170
Theme.PieceSheetColumns = { K = 0, Q = 1, B = 2, N = 3, R = 4, P = 5 }
-- The big king on the Home screen (assets/hero-king.png, 512x512, made by
-- tools/build_hero_king.py). While empty, Home uses the sheet's king instead.
Theme.HeroKing = ""

Theme.PieceWhite = { fill = Color3.fromRGB(250, 247, 238), outline = Color3.fromRGB(28, 30, 30) }
Theme.PieceBlack = { fill = Color3.fromRGB(36, 38, 42), outline = Color3.fromRGB(232, 226, 210) }

Theme.DifficultyColors = {
	Beginner = Color3.fromRGB(86, 190, 120),
	Easy = Color3.fromRGB(98, 172, 220),
	Medium = Color3.fromRGB(232, 184, 72),
	Hard = Color3.fromRGB(232, 120, 72),
	Expert = Color3.fromRGB(214, 76, 110),
}

Theme.Font = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
Theme.FontBold = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
Theme.FontHeavy = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)

return Theme
