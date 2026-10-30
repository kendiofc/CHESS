--!strict
-- AnimationController: small tween helpers shared by the client UI.

local TweenService = game:GetService("TweenService")

local AnimationController = {}

function AnimationController.tween(
	instance: Instance,
	seconds: number,
	goals: { [string]: any },
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?
): Tween
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
	local tween = TweenService:Create(instance, info, goals)
	tween:Play()
	return tween
end

-- Grows a UIScale to `peak` and settles it back to 1.
function AnimationController.pulse(scale: UIScale, peak: number, seconds: number)
	scale.Scale = peak
	AnimationController.tween(scale, seconds, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Quick horizontal shake used for rejected input. Overlapping calls are
-- ignored so the frame always returns to its true resting position.
function AnimationController.shake(frame: GuiObject)
	if frame:GetAttribute("Shaking") then
		return
	end
	frame:SetAttribute("Shaking", true)
	local origin = frame.Position
	task.spawn(function()
		for _, dx in ipairs({ 8, -7, 5, -3, 0 }) do
			frame.Position = origin + UDim2.fromOffset(dx, 0)
			task.wait(0.035)
		end
		frame.Position = origin
		frame:SetAttribute("Shaking", nil)
	end)
end

-- Briefly tints a frame with `color`, then fades the tint away.
function AnimationController.flash(parent: GuiObject, color: Color3, seconds: number?)
	local overlay = Instance.new("Frame")
	overlay.Name = "Flash"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = color
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 5
	overlay.Parent = parent
	AnimationController.tween(overlay, seconds or 0.45, { BackgroundTransparency = 1 }).Completed:Connect(function()
		overlay:Destroy()
	end)
end

-- Sparks flying outward from the centre of `parent` (used for victories).
function AnimationController.burst(parent: GuiObject, color: Color3, count: number)
	for i = 1, count do
		local spark = Instance.new("Frame")
		spark.AnchorPoint = Vector2.new(0.5, 0.5)
		spark.Position = UDim2.fromScale(0.5, 0.4)
		spark.Size = UDim2.fromOffset(10, 10)
		spark.Rotation = 45
		spark.BackgroundColor3 = color
		spark.BorderSizePixel = 0
		spark.ZIndex = 20
		spark.Parent = parent
		local angle = (i / count) * math.pi * 2 + math.random() * 0.3
		local distance = 0.45 + math.random() * 0.25
		local goal = UDim2.fromScale(0.5 + math.cos(angle) * distance, 0.4 + math.sin(angle) * distance)
		AnimationController.tween(spark, 0.9, {
			Position = goal,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(4, 4),
			Rotation = 225,
		}, Enum.EasingStyle.Quint).Completed:Connect(function()
			spark:Destroy()
		end)
	end
end

return AnimationController
