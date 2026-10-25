--!strict
-- SoundController: sound effects and haptics for the client UI.
--
--   * One Sound per event (UI/SoundConfig), in a SoundGroup whose volume is
--     the player's master volume. An event with no asset id stays silent.
--   * The same event can't start twice within DEDUPE_SECONDS, so a sound
--     triggered by two code paths for one action plays once.
--   * Haptics are used only when HapticService reports the device supports
--     them; otherwise they do nothing. The game never depends on them: every
--     haptic goes with a sound and a visual change.
--   * Buttons click when pressed unless they carry the "Silent" attribute
--     (board squares and dim overlays, which play their own sounds or none).

local HapticService = game:GetService("HapticService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local SoundConfig = require(script.Parent:WaitForChild("UI"):WaitForChild("SoundConfig"))

local SoundController = {}

local DEDUPE_SECONDS = 0.08

local group: SoundGroup? = nil
local sounds: { [string]: Sound } = {}
local lastPlayed: { [string]: number } = {}
local settings = { sound = true, volume = 0.7, haptics = true }

local HAPTICS = {
	light = { intensity = 0.25, seconds = 0.05 },
	medium = { intensity = 0.5, seconds = 0.08 },
	heavy = { intensity = 0.9, seconds = 0.18 },
}

function SoundController.init()
	if group then
		return
	end
	local newGroup = Instance.new("SoundGroup")
	newGroup.Name = "EchoChessSfx"
	newGroup.Volume = settings.volume
	newGroup.Parent = SoundService
	group = newGroup
	for name, spec in pairs(SoundConfig) do
		if spec.id then
			local sound = Instance.new("Sound")
			sound.Name = name
			sound.SoundId = "rbxassetid://" .. spec.id
			sound.Volume = spec.volume
			sound.PlaybackSpeed = spec.pitch or 1
			sound.SoundGroup = newGroup
			sound.Parent = newGroup
			sounds[name] = sound
		end
	end
end

function SoundController.setSettings(values: { [string]: any })
	if type(values.sound) == "boolean" then
		settings.sound = values.sound
	end
	if type(values.volume) == "number" then
		settings.volume = math.clamp(values.volume, 0, 1)
	end
	if type(values.haptics) == "boolean" then
		settings.haptics = values.haptics
	end
	if group then
		group.Volume = settings.volume
	end
end

function SoundController.getSettings(): { sound: boolean, volume: number, haptics: boolean }
	return table.clone(settings)
end

function SoundController.play(name: string)
	if not settings.sound or settings.volume <= 0 then
		return
	end
	local sound = sounds[name]
	if not sound then
		return
	end
	local now = os.clock()
	if lastPlayed[name] and now - lastPlayed[name] < DEDUPE_SECONDS then
		return
	end
	lastPlayed[name] = now
	sound.TimePosition = 0
	sound:Play()
end

-- The input types that can vibrate on this device right now.
local function hapticTargets(): { Enum.UserInputType }
	local targets = {}
	local candidates = {}
	if UserInputService.TouchEnabled then
		table.insert(candidates, Enum.UserInputType.Touch)
	end
	if UserInputService.GamepadEnabled then
		table.insert(candidates, Enum.UserInputType.Gamepad1)
	end
	for _, inputType in ipairs(candidates) do
		local ok, supported = pcall(function()
			return HapticService:IsVibrationSupported(inputType)
				and HapticService:IsMotorSupported(inputType, Enum.VibrationMotor.Small)
		end)
		if ok and supported then
			table.insert(targets, inputType)
		end
	end
	return targets
end

function SoundController.hapticsSupported(): boolean
	return #hapticTargets() > 0
end

function SoundController.haptic(strength: string)
	local spec = HAPTICS[strength]
	if not settings.haptics or not spec then
		return
	end
	for _, inputType in ipairs(hapticTargets()) do
		local ok = pcall(function()
			HapticService:SetMotor(inputType, Enum.VibrationMotor.Small, spec.intensity)
		end)
		if ok then
			task.delay(spec.seconds, function()
				pcall(function()
					HapticService:SetMotor(inputType, Enum.VibrationMotor.Small, 0)
				end)
			end)
		end
	end
end

-- Plays the click sound for every button under `root`, now and later.
function SoundController.watchButtons(root: Instance)
	local function hook(instance: Instance)
		if instance:IsA("GuiButton") then
			instance.Activated:Connect(function()
				if not instance:GetAttribute("Silent") then
					SoundController.play("click")
				end
			end)
		end
	end
	for _, descendant in ipairs(root:GetDescendants()) do
		hook(descendant)
	end
	root.DescendantAdded:Connect(hook)
end

return SoundController
