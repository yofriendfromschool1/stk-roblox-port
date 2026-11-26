--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from data/skins/classic/stkskin.xml and data/stk_config.xml:L539-L541 (STK 1.5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MenuIcons = require(Shared.menu.MenuIcons)

local ClassicSkin = {}

-- Closest Roblox built-in equivalents to STK's SigmarOne.otf (digit-ttf) & Cantarell-Regular.otf (normal-ttf).
-- Uploading raw .ttf/.otf is blocked by Roblox (logged in docs/divergences.md).
ClassicSkin.FONT_TITLE = Enum.Font.FredokaOne
ClassicSkin.FONT_BODY = Enum.Font.Ubuntu

ClassicSkin.COLOR_TEXT_NEUTRAL = Color3.fromRGB(0, 0, 0) -- stkskin.xml:L240
ClassicSkin.COLOR_TEXT_FOCUSED = Color3.fromRGB(255, 255, 255) -- stkskin.xml:L244
ClassicSkin.COLOR_TEXT_BRIGHT = Color3.fromRGB(255, 145, 0) -- stkskin.xml:L241
ClassicSkin.COLOR_TEXT_CREDITS = Color3.fromRGB(65, 15, 0) -- stkskin.xml:L247
ClassicSkin.COLOR_TEXT_EMPHASIS = Color3.fromRGB(0, 0, 180) -- stkskin.xml:L250
ClassicSkin.COLOR_HEADER_TOP = Color3.fromRGB(255, 128, 0) -- stkskin.xml:L278
ClassicSkin.COLOR_HEADER_BOTTOM = Color3.fromRGB(255, 220, 15) -- stkskin.xml:L279

function ClassicSkin.applyHeaderGradient(label: TextLabel)
	label.Font = ClassicSkin.FONT_TITLE
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(45, 18, 0)
	label.TextStrokeTransparency = 0.15
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, ClassicSkin.COLOR_HEADER_TOP),
		ColorSequenceKeypoint.new(1, ClassicSkin.COLOR_HEADER_BOTTOM),
	})
	grad.Rotation = 90
	grad.Parent = label
end

function ClassicSkin.makeGlassBox(parent: Instance, name: string, pos: UDim2, size: UDim2, zIndex: number?): ImageLabel
	local box = Instance.new("ImageLabel")
	box.Name = name
	box.Position = pos
	box.Size = size
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.Image = MenuIcons.SkinGlassSection
	box.ScaleType = Enum.ScaleType.Slice
	box.SliceCenter = Rect.new(15, 15, 49, 48)
	box.ZIndex = zIndex or 8
	box.Parent = parent
	return box
end

function ClassicSkin.makeGlassButton(
	parent: Instance,
	name: string,
	text: string,
	pos: UDim2,
	size: UDim2,
	trackConn: (RBXScriptConnection) -> ()
): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Position = pos
	btn.Size = size
	btn.BackgroundTransparency = 1
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.ZIndex = 12
	btn.Parent = parent

	local bg = Instance.new("ImageLabel")
	bg.Name = "SkinBg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundTransparency = 1
	bg.Image = MenuIcons.SkinGlassButton
	bg.ScaleType = Enum.ScaleType.Slice
	bg.SliceCenter = Rect.new(40, 12, 216, 77)
	bg.ZIndex = 11
	bg.Parent = btn

	local label = Instance.new("TextLabel")
	label.Name = "BtnText"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = ClassicSkin.FONT_BODY
	label.TextSize = 15
	label.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
	label.Text = text
	label.ZIndex = 13
	label.Parent = btn

	trackConn(btn.MouseEnter:Connect(function()
		bg.Image = MenuIcons.SkinGlassButtonFocused
		label.TextColor3 = ClassicSkin.COLOR_TEXT_FOCUSED
	end))
	trackConn(btn.MouseLeave:Connect(function()
		if not btn:GetAttribute("Selected") then
			bg.Image = MenuIcons.SkinGlassButton
			label.TextColor3 = ClassicSkin.COLOR_TEXT_NEUTRAL
		end
	end))

	return btn
end

function ClassicSkin.setButtonText(btn: TextButton, text: string)
	local lbl = btn:FindFirstChild("BtnText")
	if lbl and lbl:IsA("TextLabel") then
		lbl.Text = text
	end
end

function ClassicSkin.setButtonSelected(btn: TextButton, selected: boolean)
	btn:SetAttribute("Selected", selected)
	local bg = btn:FindFirstChild("SkinBg")
	if bg and bg:IsA("ImageLabel") then
		bg.Image = if selected then MenuIcons.SkinGlassButtonFocused else MenuIcons.SkinGlassButton
	end
	local lbl = btn:FindFirstChild("BtnText")
	if lbl and lbl:IsA("TextLabel") then
		lbl.TextColor3 = if selected then ClassicSkin.COLOR_TEXT_FOCUSED else ClassicSkin.COLOR_TEXT_NEUTRAL
	end
end

return ClassicSkin
