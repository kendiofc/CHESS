--!strict
-- GamePassConfig: the one place to set Echo Chess's gamepass IDs.
--
-- Each pass's `id` is its numeric ID from the Creator Dashboard (Monetization
-- > Passes). A pass with `id = nil` is UNCONFIGURED: the Shop shows it as
-- "Not available yet", never prompts a purchase, and the server never checks
-- or grants it. The Shop reads each pass's price from Roblox; `suggestedPrice`
-- is only shown while it can't.
-- Never put an ID here that isn't a real pass of this experience.
--
-- Everything a pass gives is cosmetic. No pass may change puzzles, moves,
-- hints, timers, rewards or duels.

local GamePassConfig = {}

export type Pass = {
	key: string,
	id: number?, -- nil = UNCONFIGURED
	name: string,
	icon: string,
	suggestedPrice: number, -- Robux, for display and planning only
	tagline: string,
	perks: { string },
}

GamePassConfig.PASSES = {
	RoyalVIP = {
		key = "RoyalVIP",
		id = 2062481267,
		name = "Royal VIP",
		icon = "👑",
		suggestedPrice = 299,
		tagline = "The full royal treatment",
		perks = {
			"Gold VIP frame on your profile",
			"VIP title next to your name",
			"Crown shower when you clear a puzzle",
			"Exclusive Royal Throne board",
		},
	},
	LegendarySkins = {
		key = "LegendarySkins",
		id = 2060238963,
		name = "Legendary Chess Skins",
		icon = "💎",
		suggestedPrice = 149,
		tagline = "Gold, Obsidian and Crystal pieces",
		perks = {
			"Gold, Obsidian and Crystal piece skins",
			"Golden Sparks and Crystal Shards capture effects",
		},
	},
	RoyalBoards = {
		key = "RoyalBoards",
		id = 2060364254,
		name = "Royal Board Collection",
		icon = "🏰",
		suggestedPrice = 99,
		tagline = "Four premium boards",
		perks = {
			"Royal Purple, Golden, Ice and Shadow boards",
		},
	},
} :: { [string]: Pass }

-- Display order.
GamePassConfig.ORDER = { "RoyalVIP", "LegendarySkins", "RoyalBoards" }

-- Whether a pass has a real ID and may be offered and checked.
function GamePassConfig.isConfigured(key: string): boolean
	local pass = GamePassConfig.PASSES[key]
	local id = pass and pass.id
	return type(id) == "number" and id > 0 and id == math.floor(id)
end

-- The configured pass with this ID, or nil.
function GamePassConfig.keyForId(id: any): string?
	if type(id) ~= "number" then
		return nil
	end
	for key, pass in pairs(GamePassConfig.PASSES) do
		if GamePassConfig.isConfigured(key) and pass.id == id then
			return key
		end
	end
	return nil
end

return GamePassConfig
