--!strict
-- src/shared/hud/HudNotifications.lua
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Pure-Luau edge-triggered in-race HUD toast state machine.
-- Start boost produces VFX/SFX only (no text toast, matching skid release).
-- Resets edge state on match start/restart and across rescue transitions so
-- reconciliation or rescue never re-fires prior bonus/lap toasts.

export type NotificationSnapshot = {
	inRacing: boolean,
	racePhase: string,
	raceTick: number,
	resetSeq: number,
	lap: number,
	totalLaps: number,
	raceFinished: boolean,
	startupPenaltyTicks: number,
	rescueTicks: number,
}

export type NotificationState = {
	initialized: boolean,
	prevLap: number,
	prevPenaltyActive: boolean,
	prevRescueActive: boolean,
	prevRaceTick: number,
	prevResetSeq: number,
	lapToastText: string,
	lapToastExpirySec: number,
	subToastText: string,
	subToastExpirySec: number,
}

local HudNotifications = {}

function HudNotifications.createState(): NotificationState
	return {
		initialized = false,
		prevLap = -1,
		prevPenaltyActive = false,
		prevRescueActive = false,
		prevRaceTick = 0,
		prevResetSeq = 0,
		lapToastText = "",
		lapToastExpirySec = 0.0,
		subToastText = "",
		subToastExpirySec = 0.0,
	}
end

function HudNotifications.reset(state: NotificationState, snap: NotificationSnapshot?): ()
	if snap ~= nil then
		state.initialized = true
		state.prevLap = snap.lap
		state.prevPenaltyActive = snap.startupPenaltyTicks > 0
		state.prevRescueActive = snap.rescueTicks > 0
		state.prevRaceTick = snap.raceTick
		state.prevResetSeq = snap.resetSeq
	else
		state.initialized = false
		state.prevLap = -1
		state.prevPenaltyActive = false
		state.prevRescueActive = false
		state.prevRaceTick = 0
		state.prevResetSeq = 0
	end
	state.lapToastText = ""
	state.lapToastExpirySec = 0.0
	state.subToastText = ""
	state.subToastExpirySec = 0.0
end

function HudNotifications.step(state: NotificationState, snap: NotificationSnapshot, nowSec: number): ()
	if not snap.inRacing then
		HudNotifications.reset(state, nil)
		return
	end

	-- Match start, restart, or server hard reset: sync previous state without firing edges
	if not state.initialized or snap.raceTick < state.prevRaceTick or snap.resetSeq ~= state.prevResetSeq then
		HudNotifications.reset(state, snap)
		return
	end

	state.prevRaceTick = snap.raceTick
	state.prevResetSeq = snap.resetSeq

	local rescueActive = snap.rescueTicks > 0
	local penaltyActive = snap.startupPenaltyTicks > 0

	-- Rescue active or exiting rescue: suppress edge firing and re-sync previous state
	if rescueActive or state.prevRescueActive then
		state.prevLap = snap.lap
		state.prevPenaltyActive = penaltyActive
		state.prevRescueActive = rescueActive
		state.subToastText = ""
		state.subToastExpirySec = 0.0
		return
	end

	-- Lap increment edge (linear_world.cpp:L414-L461)
	if snap.lap > state.prevLap then
		if state.prevLap >= 0 and snap.lap > 0 and not snap.raceFinished then
			if snap.lap + 1 == snap.totalLaps then
				state.lapToastText = "FINAL LAP!"
				state.lapToastExpirySec = nowSec + 3.0
			else
				state.lapToastText = string.format("LAP %d", snap.lap + 1)
				state.lapToastExpirySec = nowSec + 2.0
			end
		end
		state.prevLap = snap.lap
	elseif snap.lap < state.prevLap then
		state.prevLap = snap.lap
		state.lapToastText = ""
		state.lapToastExpirySec = 0.0
	end

	-- False-start penalty edge (start phases only)
	local inStartPhase = snap.racePhase == "READY_PHASE" or snap.racePhase == "SET_PHASE"
	if penaltyActive and not state.prevPenaltyActive and inStartPhase then
		state.subToastText = "FALSE START!"
		state.subToastExpirySec = nowSec + 1.5
	end
	state.prevPenaltyActive = penaltyActive
	state.prevRescueActive = false
end

return HudNotifications
