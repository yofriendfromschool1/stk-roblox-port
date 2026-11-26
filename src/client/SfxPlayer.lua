--!strict
-- src/client/SfxPlayer.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Client-side Roblox Sound presentation layer: lazy-created pooled Sound instances,
-- SoundGroup separation (engine / sfx / ui), positional parenting to kart BaseParts,
-- and 2D parenting to SoundService. Never touches netcode or replay state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SfxCatalog = require(Shared.audio.SfxCatalog)
local SfxEvents = require(Shared.audio.SfxEvents)

local SfxPlayer = {}

export type KartLoops = {
	[string]: Sound,
}

export type Player = {
	groups: { [string]: SoundGroup },
	loopsByKart: { [string]: KartLoops },
	oneShotPools: { [string]: { Sound } },
	destroyed: boolean,
}

local MAX_POOL_PER_SFX = 4

local function getOrCreateSoundGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	local sg = Instance.new("SoundGroup")
	sg.Name = name
	sg.Volume = 1.0
	sg.Parent = SoundService
	return sg
end

function SfxPlayer.create(): Player
	return {
		groups = {
			engine = getOrCreateSoundGroup("OpenKart_Engine"),
			sfx = getOrCreateSoundGroup("OpenKart_Sfx"),
			ui = getOrCreateSoundGroup("OpenKart_UI"),
		},
		loopsByKart = {},
		oneShotPools = {},
		destroyed = false,
	}
end

local function configureSound(sound: Sound, entry: SfxCatalog.SfxEntry, group: SoundGroup, parent: Instance)
	sound.SoundId = entry.assetId
	sound.Volume = entry.volume
	sound.SoundGroup = group
	if entry.positional then
		local rolloff = math.max(0.05, entry.rolloff)
		sound.RollOffMinDistance = 4.0
		sound.RollOffMaxDistance = math.clamp(40.0 / rolloff, 30.0, 250.0)
	end
	sound.Parent = parent
end

local function acquireOneShotSound(player: Player, entry: SfxCatalog.SfxEntry, parent: Instance): Sound?
	local pool = player.oneShotPools[entry.id]
	if not pool then
		pool = {}
		player.oneShotPools[entry.id] = pool
	end

	for _, snd in pool do
		if not snd.IsPlaying then
			return snd
		end
	end

	if #pool >= MAX_POOL_PER_SFX then
		-- Reuse oldest instance if pool is saturated
		return pool[1]
	end

	local snd = Instance.new("Sound")
	snd.Name = "OneShot_" .. entry.id
	snd.Looped = false
	local group = player.groups[entry.group] or player.groups.sfx
	configureSound(snd, entry, group, parent)
	table.insert(pool, snd)
	return snd
end

local function getOrCreateLoopSound(
	player: Player,
	kartKey: string,
	entry: SfxCatalog.SfxEntry,
	kartPart: BasePart
): Sound
	local kartLoops = player.loopsByKart[kartKey]
	if not kartLoops then
		kartLoops = {}
		player.loopsByKart[kartKey] = kartLoops
	end
	local existing = kartLoops[entry.id]
	if existing then
		if existing.Parent ~= kartPart then
			existing.Parent = kartPart
		end
		return existing
	end

	local snd = Instance.new("Sound")
	snd.Name = "Loop_" .. entry.id
	snd.Looped = true
	local group = player.groups[entry.group] or player.groups.sfx
	configureSound(snd, entry, group, kartPart)
	kartLoops[entry.id] = snd
	return snd
end

function SfxPlayer.playOneShot(player: Player, sfxId: string, kartPart: BasePart?, volumeScale: number?)
	if player.destroyed then
		return
	end
	local entry = SfxCatalog.get(sfxId)
	if not entry or entry.assetId == "" then
		return
	end
	local parent: Instance = if entry.positional and kartPart then kartPart else SoundService
	local snd = acquireOneShotSound(player, entry, parent)
	if not snd then
		return
	end
	local group = player.groups[entry.group] or player.groups.sfx
	configureSound(snd, entry, group, parent)
	snd.Volume = entry.volume * (volumeScale or 1.0)
	snd.PlaybackSpeed = 1.0
	snd:Play()
end

function SfxPlayer.applyStep(player: Player, kartKey: string, stepOut: SfxEvents.StepOutput, kartPart: BasePart?)
	if player.destroyed then
		return
	end

	-- Continuous looping sounds (lazy-created per active loop)
	if kartPart then
		local engineEntry = SfxCatalog.get("engine_large")
		if engineEntry and engineEntry.assetId ~= "" then
			local engSnd = getOrCreateLoopSound(player, kartKey, engineEntry, kartPart)
			engSnd.PlaybackSpeed = stepOut.enginePlaybackSpeed
			if stepOut.engineActive and not engSnd.IsPlaying then
				engSnd:Play()
			elseif not stepOut.engineActive and engSnd.IsPlaying then
				engSnd:Stop()
			end
		end

		local loopStates: { { id: string, active: boolean } } = {
			{ id = "skid", active = stepOut.skidActive },
			{ id = "nitro", active = stepOut.nitroActive },
			{ id = "clock", active = stepOut.bombActive },
		}
		for _, ls in loopStates do
			local entry = SfxCatalog.get(ls.id)
			if entry and entry.assetId ~= "" then
				if ls.active then
					local snd = getOrCreateLoopSound(player, kartKey, entry, kartPart)
					if not snd.IsPlaying then
						snd:Play()
					end
				else
					local kartLoops = player.loopsByKart[kartKey]
					local existing = if kartLoops then kartLoops[ls.id] else nil
					if existing and existing.IsPlaying then
						existing:Stop()
					end
				end
			end
		end
	end

	for _, ev in stepOut.oneShots do
		SfxPlayer.playOneShot(player, ev.id, kartPart, ev.volumeScale)
	end
end

function SfxPlayer.applyAudioSettings(
	player: Player,
	audio: {
		masterMuted: boolean,
		sfxVolume: number,
		engineVolume: number,
		uiVolume: number,
	}
)
	if player.destroyed then
		return
	end
	local muted = audio.masterMuted == true
	if player.groups.engine then
		player.groups.engine.Volume = if muted then 0 else math.clamp(audio.engineVolume, 0, 1)
	end
	if player.groups.sfx then
		player.groups.sfx.Volume = if muted then 0 else math.clamp(audio.sfxVolume, 0, 1)
	end
	if player.groups.ui then
		player.groups.ui.Volume = if muted then 0 else math.clamp(audio.uiVolume, 0, 1)
	end
end

function SfxPlayer.stopAllLoops(player: Player)
	if player.destroyed then
		return
	end
	for _, kartLoops in player.loopsByKart do
		for _, snd in kartLoops do
			snd.Volume = 0
			if snd.IsPlaying then
				snd:Stop()
			end
		end
	end
end

function SfxPlayer.destroy(player: Player)
	if player.destroyed then
		return
	end
	player.destroyed = true
	for _, kartLoops in player.loopsByKart do
		for _, snd in kartLoops do
			snd:Stop()
			snd:Destroy()
		end
	end
	table.clear(player.loopsByKart)
	for _, pool in player.oneShotPools do
		for _, snd in pool do
			snd:Stop()
			snd:Destroy()
		end
	end
	table.clear(player.oneShotPools)
end

return SfxPlayer
