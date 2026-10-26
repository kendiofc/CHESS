--!strict
-- ConfirmDialog: a modal "are you sure?" card with Cancel and a confirm
-- button, used before actions that throw away the current attempt.
--
--   * A full-screen dim sits above every other GUI and swallows taps and
--     clicks, so nothing behind it can be pressed while it is open.
--   * Both buttons ignore presses for InputRules.DIALOG_ARM_SECONDS after it
--     opens, so the press that opened it (or a fast double tap) can't answer
--     it. Tapping the dim does nothing.
--   * Keyboard and gamepad: Backspace or B cancels; Enter confirms. (Escape
--     is kept by Roblox for its own menu and never reaches the game.)
--   * The answer runs once; the dialog closes before the callback runs.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InputRules = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("InputRules"))
local Anim = require(script.Parent.Parent:WaitForChild("AnimationController"))
local Decor = require(script.Parent:WaitForChild("Decor"))
local Theme = require(script.Parent:WaitForChild("Theme"))

local ConfirmDialog = {}
ConfirmDialog.__index = ConfirmDialog

local CANCEL_ACTION = "EchoChessDialogCancel"
local CONFIRM_ACTION = "EchoChessDialogConfirm"

export type Request = { title: string, body: string, confirm: string, onConfirm: () -> (), onCancel: (() -> ())? }

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

local function dialogButton(name: string, primary: boolean): TextButton
	local b = make("TextButton", {
		Name = name,
		Size = UDim2.new(0.5, -6, 1, 0),
		BackgroundColor3 = if primary then Theme.Danger else Theme.PanelRaised,
		AutoButtonColor = true,
		FontFace = Theme.FontBold,
		TextColor3 = Theme.Text,
		TextSize = 18,
		ZIndex = 52,
	}, { corner(12) })
	Decor.sheen(b, 0.18)
	return b
end

function ConfirmDialog.new(playerGui: Instance)
	local self = setmetatable({}, ConfirmDialog) :: any
	self.request = nil
	self.openedAt = 0
	local gui = make("ScreenGui", {
		Name = "EchoChessDialog",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
		Enabled = false,
		Parent = playerGui,
	})
	self.gui = gui
	local dim = make("TextButton", {
		Name = "Dim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 50,
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
		ZIndex = 51,
		Parent = dim,
	}, {
		corner(16),
		make("UIStroke", { Color = Theme.Stroke, Thickness = 1.5 }),
		make("UISizeConstraint", { MaxSize = Vector2.new(360, math.huge) }),
		make("UIPadding", {
			PaddingTop = UDim.new(0, 18),
			PaddingBottom = UDim.new(0, 16),
			PaddingLeft = UDim.new(0, 18),
			PaddingRight = UDim.new(0, 18),
		}),
		make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 10) }),
	})
	self.scale = make("UIScale", { Parent = card })
	self.title = make("TextLabel", {
		Name = "Title",
		LayoutOrder = 1,
		BackgroundTransparency = 1,
		FontFace = Theme.FontHeavy,
		TextSize = 22,
		TextColor3 = Theme.Text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 52,
		Parent = card,
	})
	self.body = make("TextLabel", {
		Name = "Body",
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		FontFace = Theme.Font,
		TextSize = 15,
		TextColor3 = Theme.TextMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 52,
		Parent = card,
	})
	local buttons = make("Frame", {
		Name = "Buttons",
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 48),
		ZIndex = 52,
		Parent = card,
	}, {
		make("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 12),
		}),
	})
	self.cancelButton = dialogButton("CancelButton", false)
	self.cancelButton.Text = "Cancel"
	self.cancelButton.LayoutOrder = 1
	self.cancelButton.Parent = buttons
	self.confirmButton = dialogButton("ConfirmButton", true)
	self.confirmButton.LayoutOrder = 2
	self.confirmButton.Parent = buttons
	self.cancelButton.Activated:Connect(function()
		if self:_armed() then
			self:answer(false)
		end
	end)
	self.confirmButton.Activated:Connect(function()
		if self:_armed() then
			self:answer(true)
		end
	end)
	return self
end

function ConfirmDialog.isOpen(self: any): boolean
	return self.request ~= nil
end

function ConfirmDialog._armed(self: any): boolean
	return self.request ~= nil and os.clock() - self.openedAt >= InputRules.DIALOG_ARM_SECONDS
end

-- Opens the dialog. A second ask while one is open is ignored.
function ConfirmDialog.ask(self: any, request: Request)
	if self.request then
		return
	end
	self.request = request
	self.openedAt = os.clock()
	self.title.Text = request.title
	self.body.Text = request.body
	self.confirmButton.Text = request.confirm
	self.gui.Enabled = true
	self.scale.Scale = 0.9
	Anim.tween(self.scale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
	-- Keys are bound above the default priority so they don't also reach the
	-- game (or another binding) while the dialog is open.
	ContextActionService:BindActionAtPriority(CANCEL_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin and self:_armed() then
			self:answer(false)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Backspace, Enum.KeyCode.ButtonB)
	ContextActionService:BindActionAtPriority(CONFIRM_ACTION, function(_, state)
		if state == Enum.UserInputState.Begin and self:_armed() then
			self:answer(true)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter)
end

-- Closes the dialog and runs the chosen callback once.
function ConfirmDialog.answer(self: any, confirmed: boolean)
	local request = self.request
	if not request then
		return
	end
	self.request = nil
	self.gui.Enabled = false
	ContextActionService:UnbindAction(CANCEL_ACTION)
	ContextActionService:UnbindAction(CONFIRM_ACTION)
	if confirmed then
		request.onConfirm()
	elseif request.onCancel then
		request.onCancel()
	end
end

return ConfirmDialog
