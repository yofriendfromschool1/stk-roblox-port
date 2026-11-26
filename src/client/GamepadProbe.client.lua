local UIS = game:GetService("UserInputService")
local function report(tag)
	warn(("[GP:%s] enabled=%s connected=%d"):format(tag, tostring(UIS.GamepadEnabled), #UIS:GetConnectedGamepads()))
	for _, g in ipairs(UIS:GetConnectedGamepads()) do
		warn("  " .. g.Name)
	end
end
report("start")
UIS.GamepadConnected:Connect(function(g)
	warn("[GP] +" .. g.Name)
	report("connected")
end)
UIS.GamepadDisconnected:Connect(function(g)
	warn("[GP] -" .. g.Name)
	report("disconnected")
end)
UIS.InputBegan:Connect(function(io, gpe)
	if io.UserInputType.Name:match("Gamepad") then
		warn(("[GP] %s gpe=%s"):format(io.KeyCode.Name, tostring(gpe)))
	end
end)
task.spawn(function()
	while true do
		for _, gp in ipairs(UIS:GetConnectedGamepads()) do
			local mag = 0
			for _, io in ipairs(UIS:GetGamepadState(gp)) do
				mag = math.max(mag, math.abs(io.Position.X), math.abs(io.Position.Y), math.abs(io.Position.Z))
			end
			if mag > 0.15 then
				warn(("[GP] active: %s mag=%.2f"):format(gp.Name, mag))
			end
		end
		task.wait(0.1)
	end
end)
