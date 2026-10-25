--!strict
-- TutorialCoach: the tutorial's on-screen card and pointer. It only draws;
-- the HUD feeds it TutorialFlow steps and decides when it shows.
--
--   * The card holds the step text, an "n/5" count, Skip, and Next for the
--     step that waits for the player to read.
--   * The pointer is a pulsing ring placed over a target the HUD names (the
--     player's square or the Hint button). It never takes input, so it can't
--     block a tap on what it points at.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent:WaitForChild("Theme"))

local TutorialCoach = {}
TutorialCoach.__index = TutorialCoach

export type Callbacks = { skip: () -> (), next: () -> () }

local function make(className: string, props: { [string]: any }?, children: { Instance }?): any
	local instance = Instance.new(className)
	for key, value in pairs(props or {}) do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	for _, childInstance in ipairs(children or {}) do
		childInstance.Parent = instance
	end
	if props and props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local function corner(radius: number): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function smallButton(name: string, label: string, primary: boolean): TextButton
	return make("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(76, 34),
		BackgroundColor3 = if primary then Theme.Accent else Theme.PanelRaised,
		AutoButtonColor = true,
		FontFace = Theme.FontBold,
		Text = label,
		TextColor3 = Theme.Text,
		TextSize = 15,
		ZIndex = 21,
	}, { corner(10) })
end

function TutorialCoach.new(parent: Instance, callbacks: Callbacks)
	local self = setmetatable({}, TutorialCoach) :: any
	local frame = make("Frame", {
		Name = "TutorialCoach",
		BackgroundColor3 = Theme.Panel,
		Visible = false,
		ZIndex = 20,
		Parent = parent,
	}, {
		corner(12),
		make("UIStroke", { Color = Theme.Gold, Thickness = 2 }),
	})
	self.frame = frame
	self.count = make("TextLabel", {
		Name = "Count",
		BackgroundTransparency = 1,
		FontFace = Theme.FontHeavy,
		TextSize = 12,
		TextColor3 = Theme.Gold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -104, 0, 14),
		ZIndex = 21,
		Parent = frame,
	})
	self.text = make("TextLabel", {
		Name = "StepText",
		BackgroundTransparency = 1,
		FontFace = Theme.Font,
		TextSize = 14,
		TextColor3 = Theme.Text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(12, 22),
		Size = UDim2.new(1, -104, 1, -26),
		ZIndex = 21,
		Parent = frame,
	}, { make("UITextSizeConstraint", { MinTextSize = 11, MaxTextSize = 14 }) })
	self.text.TextScaled = true
	local buttons = make("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(76, 74),
		BackgroundTransparency = 1,
		ZIndex = 21,
		Parent = frame,
	}, {
		make("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 6),
		}),
	})
	self.nextButton = smallButton("NextStep", "Next", true)
	self.nextButton.LayoutOrder = 1
	self.nextButton.Parent = buttons
	self.skipButton = smallButton("SkipTutorial", "Skip", false)
	self.skipButton.LayoutOrder = 2
	self.skipButton.Parent = buttons
	self.nextButton.Activated:Connect(callbacks.next)
	self.skipButton.Activated:Connect(callbacks.skip)

	-- The pointer ring. Its pulse runs forever; it is simply hidden when unused.
	local ring = make("Frame", {
		Name = "TutorialPointer",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 10, 1, 10),
		BackgroundTransparency = 1,
		Active = false,
		Visible = false,
		ZIndex = 20,
	}, { make("UICorner", { CornerRadius = UDim.new(0, 12) }) })
	local ringStroke = make("UIStroke", { Color = Theme.Gold, Thickness = 5, Parent = ring })
	TweenService:Create(
		ringStroke,
		TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Transparency = 0.55 }
	):Play()
	self.ring = ring
	return self
end

-- Shows `step` (a TutorialFlow step) as number `index` of `total`.
function TutorialCoach.show(self: any, step: any, index: number, total: number)
	self.frame.Visible = true
	self.count.Text = string.format("HOW TO PLAY  ·  %d/%d", index, total)
	self.text.Text = step.text
	self.nextButton.Visible = step.waitFor == "next"
end

function TutorialCoach.hide(self: any)
	self.frame.Visible = false
	self:pointAt(nil)
end

function TutorialCoach.isShowing(self: any): boolean
	return self.frame.Visible
end

-- Rings `target` (a GuiObject), or hides the ring when nil.
function TutorialCoach.pointAt(self: any, target: GuiObject?)
	if target then
		self.ring.Parent = target
		self.ring.Visible = true
	else
		self.ring.Visible = false
		self.ring.Parent = nil
	end
end

return TutorialCoach
