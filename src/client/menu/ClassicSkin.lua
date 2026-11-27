--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from data/skins/{classic,cartoon}*/stkskin.xml and data/stk_config.xml:L539-L541 (STK 1.5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MenuIcons = require(Shared.menu.MenuIcons)
local SettingsSchema = require(Shared.settings.SettingsSchema)
local SkinIconResolver = require(Shared.menu.SkinIconResolver)
local SkinVariantPalette = require(Shared.settings.SkinVariantPalette)

export type VariantPalette = {
	headerTop: Color3,
	headerBottom: Color3,
	textNeutral: Color3,
	textFocused: Color3,
	textBright: Color3,
	textEmphasis: Color3,
	textCredits: Color3,
	boxTint: Color3,
	buttonTint: Color3,
	buttonFocusTint: Color3,
	bottomBarTint: Color3,
	backdropTint: Color3,
}

local function toColor3(c: SkinVariantPalette.RgbColor): Color3
	return Color3.fromRGB(c.r, c.g, c.b)
end

local VARIANT_PALETTES: { [string]: VariantPalette } = {}
for _, vName in ipairs(SkinVariantPalette.VARIANT_ORDER) do
	local spec = SkinVariantPalette.getPalette(vName)
	VARIANT_PALETTES[vName] = {
		headerTop = toColor3(spec.headerTop),
		headerBottom = toColor3(spec.headerBottom),
		textNeutral = toColor3(spec.textNeutral),
		textFocused = toColor3(spec.textFocused),
		textBright = toColor3(spec.textBright),
		textEmphasis = toColor3(spec.textEmphasis),
		textCredits = toColor3(spec.textCredits),
		boxTint = toColor3(spec.boxTint),
		buttonTint = toColor3(spec.buttonTint),
		buttonFocusTint = toColor3(spec.buttonFocusTint),
		bottomBarTint = toColor3(spec.bottomBarTint),
		backdropTint = toColor3(spec.backdropTint),
	}
end
local PEACH_PALETTE: VariantPalette = VARIANT_PALETTES["Peach"]

local ClassicSkin = {}

-- Closest Roblox built-in equivalents to STK's SigmarOne.otf (digit-ttf) & Cantarell-Regular.otf (normal-ttf).
-- Uploading raw .ttf/.otf is blocked by Roblox (logged in docs/divergences.md).
ClassicSkin.FONT_TITLE = Enum.Font.FredokaOne
ClassicSkin.FONT_BODY = Enum.Font.Ubuntu

ClassicSkin.COLOR_TEXT_NEUTRAL = PEACH_PALETTE.textNeutral
ClassicSkin.COLOR_TEXT_FOCUSED = PEACH_PALETTE.textFocused
ClassicSkin.COLOR_TEXT_BRIGHT = PEACH_PALETTE.textBright
ClassicSkin.COLOR_TEXT_CREDITS = PEACH_PALETTE.textCredits
ClassicSkin.COLOR_TEXT_EMPHASIS = PEACH_PALETTE.textEmphasis
ClassicSkin.COLOR_HEADER_TOP = PEACH_PALETTE.headerTop
ClassicSkin.COLOR_HEADER_BOTTOM = PEACH_PALETTE.headerBottom

local activePalette: VariantPalette = PEACH_PALETTE
local activeBodyFont: Enum.Font = ClassicSkin.FONT_BODY
local activeSkinName: SettingsSchema.SkinName = "Classic"

function ClassicSkin.getPalette(variant: SettingsSchema.SkinVariantName?): VariantPalette
	if variant ~= nil and VARIANT_PALETTES[variant] ~= nil then
		return VARIANT_PALETTES[variant]
	end
	return PEACH_PALETTE
end

function ClassicSkin.applyHeaderGradient(label: TextLabel)
	label.Font = ClassicSkin.FONT_TITLE
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeColor3 = Color3.fromRGB(45, 18, 0)
	label.TextStrokeTransparency = 0.15
	label:SetAttribute("OpenKartSkinRole", "Header")
	local existing = label:FindFirstChildOfClass("UIGradient")
	local grad = if existing then existing else Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, activePalette.headerTop),
		ColorSequenceKeypoint.new(1, activePalette.headerBottom),
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
	box.ImageColor3 = activePalette.boxTint
	box.ScaleType = Enum.ScaleType.Slice
	box.SliceCenter = Rect.new(15, 15, 49, 48)
	box.ZIndex = zIndex or 8
	box:SetAttribute("OpenKartSkinRole", "Box")
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
	btn:SetAttribute("OpenKartSkinRole", "Button")
	btn.Parent = parent

	local bg = Instance.new("ImageLabel")
	bg.Name = "SkinBg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundTransparency = 1
	bg.Image = MenuIcons.SkinGlassButton
	bg.ImageColor3 = activePalette.buttonTint
	bg.ScaleType = Enum.ScaleType.Slice
	bg.SliceCenter = Rect.new(40, 12, 216, 77)
	bg.ZIndex = 11
	bg.Parent = btn

	local label = Instance.new("TextLabel")
	label.Name = "BtnText"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = activeBodyFont
	label.TextSize = 15
	label.TextColor3 = activePalette.textNeutral
	label.Text = text
	label.ZIndex = 13
	label:SetAttribute("OpenKartBaseTextSize", 15)
	label:SetAttribute("OpenKartSkinRole", "ButtonText")
	label.Parent = btn

	trackConn(btn.MouseEnter:Connect(function()
		bg.Image = MenuIcons.SkinGlassButtonFocused
		bg.ImageColor3 = activePalette.buttonFocusTint
		label.TextColor3 = activePalette.textFocused
	end))
	trackConn(btn.MouseLeave:Connect(function()
		if not btn:GetAttribute("Selected") then
			bg.Image = MenuIcons.SkinGlassButton
			bg.ImageColor3 = activePalette.buttonTint
			label.TextColor3 = activePalette.textNeutral
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
		bg.ImageColor3 = if selected then activePalette.buttonFocusTint else activePalette.buttonTint
	end
	local lbl = btn:FindFirstChild("BtnText")
	if lbl and lbl:IsA("TextLabel") then
		lbl.TextColor3 = if selected then activePalette.textFocused else activePalette.textNeutral
	end
end

function ClassicSkin.applyTheme(
	root: Instance,
	skin: SettingsSchema.SkinName,
	variant: SettingsSchema.SkinVariantName,
	fontScale: number
): VariantPalette
	local pal = ClassicSkin.getPalette(variant)
	activePalette = pal
	activeSkinName = skin
	activeBodyFont = if skin == "Cartoon" then Enum.Font.Cartoon else Enum.Font.Ubuntu
	ClassicSkin.COLOR_TEXT_NEUTRAL = pal.textNeutral
	ClassicSkin.COLOR_TEXT_FOCUSED = pal.textFocused
	ClassicSkin.COLOR_TEXT_BRIGHT = pal.textBright
	ClassicSkin.COLOR_TEXT_CREDITS = pal.textCredits
	ClassicSkin.COLOR_TEXT_EMPHASIS = pal.textEmphasis
	ClassicSkin.COLOR_HEADER_TOP = pal.headerTop
	ClassicSkin.COLOR_HEADER_BOTTOM = pal.headerBottom

	local scale = math.clamp(fontScale, 0.75, 1.35)
	for _, desc in ipairs(root:GetDescendants()) do
		local role = desc:GetAttribute("OpenKartSkinRole")
		if role == "Header" and desc:IsA("TextLabel") then
			ClassicSkin.applyHeaderGradient(desc)
			desc.TextStrokeTransparency = if activeSkinName == "Cartoon" then 0.0 else 0.15
		elseif role == "Box" and desc:IsA("ImageLabel") then
			desc.ImageColor3 = pal.boxTint
		elseif role == "BottomBar" and desc:IsA("ImageLabel") then
			desc.ImageColor3 = pal.bottomBarTint
		elseif role == "Button" and desc:IsA("TextButton") then
			local sel = desc:GetAttribute("Selected") == true
			ClassicSkin.setButtonSelected(desc, sel)
		elseif desc:IsA("ImageLabel") or desc:IsA("ImageButton") then
			local iconKey = desc:GetAttribute("OpenKartMenuIconKey")
			if type(iconKey) == "string" and #iconKey > 0 then
				local resolved = SkinIconResolver.getMenuIcon(iconKey, skin)
				if resolved ~= "" then
					if desc:IsA("ImageLabel") then
						desc.Image = resolved
					else
						(desc :: ImageButton).Image = resolved
					end
				end
			end
		elseif desc:IsA("TextLabel") and role ~= "Header" then
			if desc.Font ~= Enum.Font.Code and desc.Font ~= ClassicSkin.FONT_TITLE then
				desc.Font = activeBodyFont
			end
			if role == "BodyText" then
				desc.TextColor3 = pal.textNeutral
			elseif role == "EmphasisText" then
				desc.TextColor3 = pal.textEmphasis
			elseif role == "CreditsText" then
				desc.TextColor3 = pal.textCredits
			elseif role == "FocusedText" then
				desc.TextColor3 = pal.textFocused
			end
			local baseSz = desc:GetAttribute("OpenKartBaseTextSize")
			if type(baseSz) ~= "number" and not desc.TextScaled then
				baseSz = desc.TextSize
				desc:SetAttribute("OpenKartBaseTextSize", baseSz)
			end
			if type(baseSz) == "number" and not desc.TextScaled then
				desc.TextSize = math.max(10, math.round(baseSz * scale))
			end
		end
	end
	return pal
end

return ClassicSkin
