--!strict
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Ported from data/skins/classic/stkskin.xml and src/states_screens/main_menu_screen.cpp (STK 1.5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MenuIcons = require(Shared.menu.MenuIcons)

export type Backdrop = {
	frame: Frame,
	viewport: ViewportFrame,
	setActive: (active: boolean, showKart: boolean?) -> (),
	setViewportRect: (pos: UDim2, size: UDim2) -> (),
	setKart: (kartId: string) -> (),
	setTint: (color: Color3) -> (),
	destroy: () -> (),
}

local MenuBackdrop = {}

function MenuBackdrop.create(parent: Instance): Backdrop
	local frame = Instance.new("Frame")
	frame.Name = "StkMenuBackdrop"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(28, 72, 134)
	frame.BorderSizePixel = 0
	frame.ZIndex = 1
	frame.Parent = parent

	-- data/skins/common/background.jpg (data/skins/classic/stkskin.xml:L18)
	local bgImg = Instance.new("ImageLabel")
	bgImg.Name = "ClassicBackground"
	bgImg.Size = UDim2.fromScale(1, 1)
	bgImg.BackgroundTransparency = 1
	bgImg.BorderSizePixel = 0
	bgImg.Image = MenuIcons.SkinBackground
	bgImg.ScaleType = Enum.ScaleType.Crop
	bgImg.ZIndex = 1
	bgImg.Parent = frame

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "TuxViewport"
	viewport.Size = UDim2.fromScale(0.46, 0.46)
	viewport.Position = UDim2.fromScale(0.50, 0.04)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(190, 200, 220)
	viewport.LightColor = Color3.fromRGB(255, 245, 225)
	viewport.LightDirection = Vector3.new(-0.5, -1, -0.4)
	viewport.ZIndex = 3
	viewport.Parent = frame

	local world = Instance.new("WorldModel")
	world.Parent = viewport

	local cam = Instance.new("Camera")
	cam.FieldOfView = 40
	cam.Parent = viewport
	viewport.CurrentCamera = cam

	local kartPivot: Model? = nil
	local currentKartId = ""
	local previewSeq = 0

	local function loadKartIntoViewport(kartId: string)
		previewSeq += 1
		local mySeq = previewSeq
		currentKartId = kartId
		task.spawn(function()
			local assets = ReplicatedStorage:FindFirstChild("Assets") or ReplicatedStorage:WaitForChild("Assets", 5)
			local kartsFolder = if assets then assets:FindFirstChild("Karts") else nil
			local template = if kartsFolder then kartsFolder:FindFirstChild(kartId) else nil
			if template == nil then
				return
			end
			if template:GetAttribute("MeshesHydrated") ~= true then
				local remotes = ReplicatedStorage:FindFirstChild("OpenKartRemotes")
				local hydrateRf = if remotes then remotes:FindFirstChild("HydrateKart") else nil
				if hydrateRf and hydrateRf:IsA("RemoteFunction") then
					pcall(function()
						(hydrateRf :: RemoteFunction):InvokeServer(kartId)
					end)
				end
			end
			if mySeq ~= previewSeq then
				return
			end
			if kartPivot ~= nil then
				kartPivot:Destroy()
				kartPivot = nil
			end
			if not (template:IsA("Model") and template:GetAttribute("MeshesHydrated") == true) then
				return
			end
			local clone = template:Clone()
			for _, desc in clone:GetDescendants() do
				if desc:IsA("BasePart") then
					desc.Anchored = true
					desc.CanCollide = false
					desc.CanQuery = false
				end
			end
			clone.Parent = world
			local cf, size = clone:GetBoundingBox()
			local center = cf.Position
			if clone.PrimaryPart == nil then
				local anchor = Instance.new("Part")
				anchor.Name = "TurntablePivot"
				anchor.Size = Vector3.new(0.2, 0.2, 0.2)
				anchor.Transparency = 1
				anchor.Anchored = true
				anchor.CanCollide = false
				anchor.CFrame = CFrame.new(center)
				anchor.Parent = clone
				clone.PrimaryPart = anchor
			end
			local dist = math.max(size.Magnitude * 1.15, 5.2)
			cam.CFrame = CFrame.lookAt(center + Vector3.new(dist * 0.45, dist * 0.28, -dist * 0.85), center)
			kartPivot = clone
		end)
	end

	loadKartIntoViewport("tux")

	local active = true
	local showViewport = true
	local yaw = 0.0
	local renderConn: RBXScriptConnection? = nil

	renderConn = RunService.RenderStepped:Connect(function(dt: number)
		if not active or not showViewport or kartPivot == nil then
			return
		end
		yaw = (yaw + dt * 0.55) % (math.pi * 2)
		local pivot = kartPivot:GetPivot()
		kartPivot:PivotTo(CFrame.new(pivot.Position) * CFrame.Angles(0, yaw, 0))
	end)

	local function setActive(isActive: boolean, showKart: boolean?)
		active = isActive == true
		showViewport = if showKart ~= nil then showKart else active
		frame.Visible = active
		viewport.Visible = active and showViewport
	end

	local function setViewportRect(pos: UDim2, size: UDim2)
		viewport.Position = pos
		viewport.Size = size
	end

	local function destroy()
		if renderConn ~= nil then
			renderConn:Disconnect()
			renderConn = nil
		end
		frame:Destroy()
	end

	local function setKart(kartId: string)
		if kartId == currentKartId and kartPivot ~= nil then
			return
		end
		loadKartIntoViewport(kartId)
	end

	local function setTint(color: Color3)
		bgImg.ImageColor3 = color
	end

	return {
		frame = frame,
		viewport = viewport,
		setActive = setActive :: any,
		setViewportRect = setViewportRect,
		setKart = setKart,
		setTint = setTint,
		destroy = destroy,
	}
end

return MenuBackdrop
