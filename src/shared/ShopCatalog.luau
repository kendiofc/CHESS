--!strict
-- ShopCatalog: every cosmetic in the Shop. Pure data plus lookups, shared by
-- the server (which prices, sells and checks them) and the client (which
-- draws them).
--
-- Each item fills one slot of profile.cosmetics.equipped (GameConfig
-- COSMETIC_SLOTS): "board", "pieces" or "effect". An item is either
--   free     the slot's default, always available;
--   coins    bought once with earned coins (Progression "buy" op), then kept in
--            profile.cosmetics.owned;
--   pass     included in a gamepass (GamePassConfig). Never stored as owned:
--            the server checks the pass every session, so it can't be faked.
-- Nothing here changes gameplay. Boards recolour the squares, skins tint the
-- player's own piece and its glow, effects change the capture ripple, and all
-- of it is drawn only on that player's own screen.
--
-- Colours are {r, g, b} so the tests can read them outside Roblox.

local GameConfig = require(script.Parent.GameConfig)

local ShopCatalog = {}

export type Item = {
	id: string,
	slot: string, -- "board" | "pieces" | "effect"
	name: string,
	description: string,
	coins: number?, -- price in coins
	pass: string?, -- GamePassConfig key that includes it
	free: boolean?,
	featured: boolean?,
	-- Looks (client only)
	light: { number }?, -- board: light squares
	dark: { number }?, -- board: dark squares
	tint: { number }?, -- pieces: the player's piece
	glow: { number }?, -- pieces: the aura; effect: the ripple
	sparks: boolean?, -- effect: sparks on capture
	icon: string?,
}

local items: { Item } = {
	-- Boards ------------------------------------------------------------------------
	{
		id = "classic",
		slot = "board",
		name = "Classic Walnut",
		description = "The warm wooden board.",
		free = true,
		light = { 240, 218, 182 },
		dark = { 182, 136, 98 },
	},
	{
		id = "marble",
		slot = "board",
		name = "Marble Hall",
		description = "Cool white and grey stone.",
		coins = 250,
		light = { 236, 236, 242 },
		dark = { 150, 152, 170 },
	},
	{
		id = "emerald",
		slot = "board",
		name = "Emerald Garden",
		description = "Soft green squares.",
		coins = 400,
		featured = true,
		light = { 226, 238, 212 },
		dark = { 96, 146, 100 },
	},
	{
		id = "royal_purple",
		slot = "board",
		name = "Royal Purple",
		description = "Lavender and deep violet.",
		pass = "RoyalBoards",
		featured = true,
		light = { 218, 204, 244 },
		dark = { 120, 90, 182 },
	},
	{
		id = "golden",
		slot = "board",
		name = "Golden",
		description = "Polished gold leaf.",
		pass = "RoyalBoards",
		light = { 252, 236, 178 },
		dark = { 204, 158, 66 },
	},
	{
		id = "ice",
		slot = "board",
		name = "Ice",
		description = "Frosted glass blues.",
		pass = "RoyalBoards",
		light = { 230, 244, 252 },
		dark = { 126, 176, 214 },
	},
	{
		id = "shadow",
		slot = "board",
		name = "Shadow",
		description = "Smoke and slate.",
		pass = "RoyalBoards",
		light = { 150, 146, 172 },
		dark = { 92, 88, 116 },
	},
	{
		id = "royal_throne",
		slot = "board",
		name = "Royal Throne",
		description = "Cream and crimson, for VIPs only.",
		pass = "RoyalVIP",
		light = { 246, 228, 204 },
		dark = { 150, 52, 74 },
	},

	-- Chess skins (the player's piece) ---------------------------------------------
	{
		id = "classic",
		slot = "pieces",
		name = "Classic",
		description = "Ivory pieces with a gold glow.",
		free = true,
		tint = { 255, 255, 255 },
		glow = { 246, 198, 72 },
	},
	{
		id = "ruby",
		slot = "pieces",
		name = "Ruby",
		description = "A rose-red piece with a crimson glow.",
		coins = 500,
		featured = true,
		tint = { 255, 170, 178 },
		glow = { 236, 72, 96 },
	},
	{
		id = "gold",
		slot = "pieces",
		name = "Gold",
		description = "Solid gold, as it should be.",
		pass = "LegendarySkins",
		featured = true,
		tint = { 255, 214, 112 },
		glow = { 255, 196, 60 },
	},
	{
		id = "obsidian",
		slot = "pieces",
		name = "Obsidian",
		description = "Volcanic violet glass.",
		pass = "LegendarySkins",
		tint = { 168, 140, 226 },
		glow = { 150, 96, 255 },
	},
	{
		id = "crystal",
		slot = "pieces",
		name = "Crystal",
		description = "Clear as ice, with a cyan shimmer.",
		pass = "LegendarySkins",
		tint = { 184, 236, 255 },
		glow = { 96, 220, 255 },
	},

	-- Effects (captures) -------------------------------------------------------------
	{
		id = "none",
		slot = "effect",
		name = "Echo Ripple",
		description = "The standard golden ripple.",
		free = true,
		glow = { 246, 198, 72 },
		icon = "⭕",
	},
	{
		id = "stardust",
		slot = "effect",
		name = "Stardust",
		description = "Lilac rings and a few stars.",
		coins = 200,
		glow = { 200, 178, 255 },
		sparks = true,
		icon = "✨",
	},
	{
		id = "verdant",
		slot = "effect",
		name = "Verdant Wave",
		description = "A green echo.",
		coins = 300,
		glow = { 92, 214, 132 },
		icon = "🍃",
	},
	{
		id = "gold_sparks",
		slot = "effect",
		name = "Golden Sparks",
		description = "Gold rings and a burst of sparks.",
		pass = "LegendarySkins",
		glow = { 255, 204, 64 },
		sparks = true,
		icon = "🌟",
	},
	{
		id = "crystal_shards",
		slot = "effect",
		name = "Crystal Shards",
		description = "Icy rings and glittering shards.",
		pass = "LegendarySkins",
		glow = { 120, 226, 255 },
		sparks = true,
		icon = "❄️",
	},
}

ShopCatalog.SLOTS = { "board", "pieces", "effect" }
ShopCatalog.list = items

local bySlot: { [string]: { [string]: Item } } = {}
for _, item in ipairs(items) do
	bySlot[item.slot] = bySlot[item.slot] or {}
	assert(not bySlot[item.slot][item.id], "duplicate item " .. item.slot .. ":" .. item.id)
	assert(item.free or item.coins or item.pass, "item without a source: " .. item.id)
	if item.free then
		assert(GameConfig.COSMETIC_SLOTS[item.slot] == item.id, "the free item must be the slot's default")
	end
	bySlot[item.slot][item.id] = item
end

-- The item in a slot, or nil (never trust a client id without this).
function ShopCatalog.get(slot: any, id: any): Item?
	if type(slot) ~= "string" or type(id) ~= "string" then
		return nil
	end
	local inSlot = bySlot[slot]
	return inSlot and inSlot[id]
end

-- Items bought with coins live in profile.cosmetics.owned under this key,
-- so a board and a skin can share a name.
function ShopCatalog.ownKey(item: Item): string
	return item.slot .. ":" .. item.id
end

-- Every item a pass includes.
function ShopCatalog.forPass(key: string): { Item }
	local out = {}
	for _, item in ipairs(items) do
		if item.pass == key then
			table.insert(out, item)
		end
	end
	return out
end

-- Whether a player may use an item: free, bought with coins, or included in
-- a pass the server has verified (`passes[key] == true`).
function ShopCatalog.usable(item: Item, owned: { [string]: boolean }, passes: { [string]: boolean }?): boolean
	if item.free then
		return true
	elseif item.coins then
		return owned[ShopCatalog.ownKey(item)] == true
	elseif item.pass then
		return passes ~= nil and passes[item.pass] == true
	end
	return false
end

return ShopCatalog
