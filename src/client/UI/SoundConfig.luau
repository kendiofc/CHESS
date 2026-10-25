--!strict
-- SoundConfig: the audio asset for each sound event. Edit ids here to swap a
-- sound; set `id = nil` to leave an event silent.
--
-- Every id below was checked in Studio on 2026-10-25 with
-- MarketplaceService:GetProductInfo: each is an Audio asset (AssetTypeId 3)
-- published by Roblox or by ProSoundEffects, whose library Roblox licenses
-- for use in any experience. Don't add an id that hasn't been checked the
-- same way.

export type SoundSpec = {
	id: number?,
	volume: number, -- before the player's master volume
	pitch: number?,
	name: string, -- the asset's name, for reference
}

local SoundConfig: { [string]: SoundSpec } = {
	click = { id = 15675032796, volume = 0.45, name = "Roblox_UI_Small_Click (Roblox)" },
	select = { id = 15675059323, volume = 0.4, name = "Roblox_UI_Bright_Click (Roblox)" },
	move = { id = 9126266369, volume = 0.45, pitch = 1.2, name = "Wood Hit Cast Iron Weight Knocks Against Wood 1 (ProSoundEffects)" },
	capture = { id = 15675055424, volume = 0.6, name = "Roblox_UI_Cute_Pop (Roblox)" },
	invalid = { id = 15675075163, volume = 0.45, name = "Roblox_UI_Delete (Roblox)" },
	hint = { id = 15675085146, volume = 0.5, name = "Roblox_UI_Indicator (Roblox)" },
	win = { id = 12222253, volume = 0.55, name = "victory.wav (Roblox)" },
	fail = { id = 15675062723, volume = 0.5, name = "Roblox_UI_Whistle_Low (Roblox)" },
	unlock = { id = 15675043410, volume = 0.6, name = "Roblox_UI_Tonal_Stinger (Roblox)" },
	open = { id = 15675024286, volume = 0.3, name = "Roblox_UI_Whoosh_01 (Roblox)" },
}

return SoundConfig
