--!strict
-- src/client/kart/RefereePresentation.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ported from src/graphics/referee.cpp:L55-L324, data/models/referee.xml:L10-L18,
-- src/karts/rescue_animation.cpp:L162-L195, and src/states_screens/race_gui_base.cpp:L172-L186, L478-L518, L565-L575 (STK 1.5)
-- Tick-driven Thunderbird Rescue Bird and Ready/Set/Go Start Referee presentation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FixedStep = require(Shared.sim.FixedStep)
local ItemEffectState = require(Shared.sim.ItemEffectState)
local ItemVisuals = require("../items/ItemVisuals")
local RaceState = require(Shared.sim.RaceState)
local Units = require(Shared.Units)

local RefereePresentation = {}

-- Verified CC-BY-SA 4.0 traffic_light.png UV-rolled variants (models/licenses.txt:L197-L200)
RefereePresentation.TRAFFIC_LIGHT_TEXTURES = table.freeze({
	[0] = "rbxassetid://116341572804380", -- READY (red)
	[1] = "rbxassetid://121128868153438", -- SET (amber)
	[2] = "rbxassetid://78001462400352", -- GO (green)
})

-- referee.cpp:L277-L289
RefereePresentation.LIGHT_COLORS = table.freeze({
	[0] = Color3.new(0.6, 0.0, 0.0),
	[1] = Color3.new(0.7, 0.23, 0.0),
	[2] = Color3.new(0.0, 0.6, 0.0),
})

RefereePresentation.START_OFFSET_STK = Vector3.new(-1.2, 2.0, 2.0) -- referee.xml:L15
RefereePresentation.RESCUE_HEIGHT_ABOVE_KART_M = 0.4 -- referee.cpp:L206
RefereePresentation.RESCUE_ANIM_FPS = 25.0 -- referee.cpp:L319
RefereePresentation.ASCENT_SPEED_MPS = 5.0 -- race_gui_base.cpp:L485

-- Angle to face the kart from start-offset (-1.2, 2, 2): referee.cpp:L90-L93
local START_FACING_YAW_RAD = math.pi + math.atan2(-1.2, 2.0)

export type StartRefereePose = {
	visible: boolean,
	rsg: number,
	heightOffsetM: number,
}

export type RescueBirdHandle = {
	bodyPart: MeshPart,
	localPos: Vector3,
	baseRot: CFrame,
}

export type StartRefereeHandle = {
	model: Model,
	subparts: { ItemVisuals.VisualSubpart },
	trafficPart: MeshPart?,
	pointLight: PointLight?,
	lastRsg: number,
}

function RefereePresentation.computeStartRefereePose(phase: RaceState.RacePhase, raceTick: number): StartRefereePose
	if phase == "READY_PHASE" then
		return { visible = true, rsg = 0, heightOffsetM = 0.0 }
	elseif phase == "SET_PHASE" then
		return { visible = true, rsg = 1, heightOffsetM = 0.0 }
	elseif phase == "GO_PHASE" then
		local goTicks = math.max(0, raceTick - RaceState.GO_TICK)
		local goSec = FixedStep.ticksToTime(goTicks)
		return { visible = true, rsg = 2, heightOffsetM = goSec * RefereePresentation.ASCENT_SPEED_MPS }
	end
	return { visible = false, rsg = 2, heightOffsetM = 0.0 }
end

function RefereePresentation.createRescueBird(parentModel: Model): RescueBirdHandle?
	local created = ItemVisuals.create("referee", "pickup")
	if created == nil then
		return nil
	end
	local bodySub: ItemVisuals.VisualSubpart? = nil
	for _, sub in created.subparts do
		if sub.part.Name == "Body" then
			bodySub = sub
		else
			sub.part:Destroy()
		end
	end
	if bodySub == nil then
		created.model:Destroy()
		return nil
	end
	local mp = bodySub.part
	mp.Name = "RescueBirdBody"
	mp.Transparency = 1.0
	mp.CanCollide = false
	mp.Anchored = true
	mp.Parent = parentModel
	created.model:Destroy()
	return {
		bodyPart = mp,
		localPos = bodySub.localPos,
		baseRot = bodySub.baseRot,
	}
end

function RefereePresentation.updateRescueBird(
	bird: RescueBirdHandle?,
	kartOriginCf: CFrame,
	kartHeightM: number,
	rescueTicks: number,
	totalRescueTicks: number?
)
	if bird == nil then
		return
	end
	if rescueTicks <= 0 then
		bird.bodyPart.Transparency = 1.0
		return
	end
	local totalT = totalRescueTicks or FixedStep.timeToTicks(ItemEffectState.RESCUE_DURATION_SEC)
	local elapsedTicks = math.max(0, totalT - rescueTicks)
	local elapsedSec = FixedStep.ticksToTime(elapsedTicks)
	-- referee.cpp:L315-L324: 25 fps animation phase synchronized with world ticks
	local animPhase = elapsedSec * RefereePresentation.RESCUE_ANIM_FPS * (2.0 * math.pi / 15.0)
	local flapRollRad = math.sin(animPhase) * 0.14
	local bobMeters = math.sin(animPhase) * 0.06
	local mountCf = kartOriginCf
		* CFrame.new(
			0,
			Units.metersToStuds(kartHeightM + RefereePresentation.RESCUE_HEIGHT_ABOVE_KART_M + bobMeters),
			0
		)
		* CFrame.Angles(0, 0, flapRollRad)
	bird.bodyPart.CFrame = mountCf * CFrame.new(bird.localPos) * bird.baseRot
	bird.bodyPart.Transparency = 0.0
end

function RefereePresentation.createStartReferee(): StartRefereeHandle?
	local created = ItemVisuals.create("referee", "pickup")
	if created == nil then
		return nil
	end
	created.model.Name = "OpenKartStartReferee"
	created.model.Parent = nil
	local trafficPart: MeshPart? = nil
	local light: PointLight? = nil
	for _, sub in created.subparts do
		sub.part.CanCollide = false
		sub.part.Anchored = true
		if sub.part.Name == "TrafficLight" then
			trafficPart = sub.part
			local pl = Instance.new("PointLight")
			pl.Range = 8
			pl.Brightness = 2.0
			pl.Color = RefereePresentation.LIGHT_COLORS[0]
			pl.Parent = sub.part
			light = pl
		end
	end
	return {
		model = created.model,
		subparts = created.subparts,
		trafficPart = trafficPart,
		pointLight = light,
		lastRsg = -1,
	}
end

function RefereePresentation.updateStartReferee(
	ctrl: StartRefereeHandle?,
	startCFrame: CFrame,
	phase: RaceState.RacePhase,
	raceTick: number
)
	if ctrl == nil then
		return
	end
	local pose = RefereePresentation.computeStartRefereePose(phase, raceTick)
	if not pose.visible then
		if ctrl.model.Parent ~= nil then
			ctrl.model.Parent = nil
		end
		return
	end
	if ctrl.model.Parent ~= Workspace then
		ctrl.model.Parent = Workspace
	end
	if pose.rsg ~= ctrl.lastRsg then
		ctrl.lastRsg = pose.rsg
		if ctrl.trafficPart ~= nil then
			ctrl.trafficPart.TextureID = RefereePresentation.TRAFFIC_LIGHT_TEXTURES[pose.rsg]
				or RefereePresentation.TRAFFIC_LIGHT_TEXTURES[0]
		end
		if ctrl.pointLight ~= nil then
			ctrl.pointLight.Color = RefereePresentation.LIGHT_COLORS[pose.rsg] or RefereePresentation.LIGHT_COLORS[0]
		end
	end
	-- STK start-offset (-1.2, 2.0, 2.0) -> Roblox (+X=right, +Y=up, -Z=forward)
	local refOrigin = startCFrame
		* CFrame.new(
			Units.metersToStuds(-1.2),
			Units.metersToStuds(2.0 + pose.heightOffsetM),
			Units.metersToStuds(-2.0)
		)
		* CFrame.Angles(0, START_FACING_YAW_RAD, 0)
	for _, sub in ctrl.subparts do
		sub.part.CFrame = refOrigin * CFrame.new(sub.localPos) * sub.baseRot
	end
end

return table.freeze(RefereePresentation)
