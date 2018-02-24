-- Copyright (C) 2018  The Dota IMBA Development Team
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- Editors:
--     suthernfriend
--

-----------------------------------
-- Utility and configuration
-----------------------------------

-- print utility functions
TeamSelectionDebugEnabled = TeamSelectionSettings.debug

function tsprint(msg)
	if TeamSelectionDebugEnabled then
		print("[team-select] " .. msg)
	end
end

-- list of names of the events
local TeamSelectionEvents = {
	hostReady = "imba_teamselect_host_ready",
	compute = "imba_teamselect_compute",
	computeComplete = "imba_teamselect_compute_complete",
	complete = "imba_teamselect_complete",
	joinTeam = "imba_teamselect_join_team",
	failure = "imba_teamselect_failure"
}

-- Utility function to recieve a list of all player steamids
function TeamSelectionGetAllPlayers()
	local playerIds = {}
	for i = 0, PlayerResource:GetPlayerCount() - 1 do
		table.insert(playerIds, tostring(PlayerResource:GetSteamID(i)))
	end
	return playerIds
end

-- set all players to no team
function TeamSelectionUnassignTeams()
	for i = 0, PlayerResource:GetPlayerCount() - 1 do
		local player = PlayerResource:GetPlayer(i)
		-- set team to no_team
		player:SetTeam(DOTA_TEAM_NOTEAM)
	end
end

-----------------------------------
-- Starting point
-----------------------------------

-- Called in DOTA_GAMERULES_STATE_CUSTOM_GAME_SETUP
function InitializeTeamSelection()

	tsprint("Initializing team selection")

	-- 5v5                will use complete random
	-- 10v10              parties will be kept
	-- frantic, imbathrow normal manual procedure

	if GetMapName() == "imba_standard" then
		Random5v5TeamSelection()
	elseif GetMapName() == "imba_10v10" then
		KeepTeams10v10TeamSelection()
	else
		ManualTeamSelection()
	end
end

-----------------------------------
-- Manual Selection
-----------------------------------

function ManualTeamSelection()
	tsprint("Initializing manual team selection")
	tsprint("Skipping. Manual Team Selection is performed by legacy code")
end

-----------------------------------
-- 5v5 Random
-----------------------------------

local PlayerWithHostPrivileges = nil
local TeamSelectionListeners = {}

function Random5v5TeamSelection()

	tsprint("Initializing 5v5 random team selection")

	-- wait until the player with host privileges notifies us that he is ready
	-- register the host-ready event
	TeamSelectionListeners.hostReady = CustomGameEventManager:RegisterListener(
		TeamSelectionEvents.hostReady,
		Random5v5TeamSelectionReady
	)

end

function Random5v5TeamSelectionReady(obj, event)

	-- unregister host-ready listener
	CustomGameEventManager:UnregisterListener(TeamSelectionListeners.hostReady)

	-- Make request
	ImbaApiAutoOrderImr5v5Random(
		TeamSelectionGetAllPlayers(),
		Random5v5TeamSelectionFinalize
	)
end

function Random5v5TeamSelectionFinalize(response)

	tsprint("recieved response from server")

	-- catch errors
	if not response.ok then
		tsprint("error")
		TeamSelectionFallbackAssignment()
		return
	end

	-- assign teams based on response
	for _, steamid in ipairs(response.data.teams[1]) do
		local player = nil
		for i = 0, PlayerResource:GetPlayerCount() - 1 do
			local sid = tostring(PlayerResource:GetSteamID(i))
			if sid == steamid then
				PlayerResource:GetPlayer(i):SetTeam(DOTA_TEAM_GOODGUYS)
			end
		end
	end

	for _, steamid in ipairs(response.data.teams[2]) do
		local player = nil
		for i = 0, PlayerResource:GetPlayerCount() - 1 do
			local sid = tostring(PlayerResource:GetSteamID(i))
			if sid == steamid then
				PlayerResource:GetPlayer(i):SetTeam(DOTA_TEAM_BADGUYS)
			end
		end
	end

	-- send the complete event
	-- will cleanup event handlers on the client / ui changes
	CustomGameEventManager:Send_ServerToAllClients(TeamSelectionEvents.complete, nil)
end

-----------------------------------
-- 10v10 Keep Teams
-----------------------------------

local TeamSelectionComputed = {}
local TeamSelectionComputedCount = 0
local TeamSelectionComputedTotal = TeamSelectionSettings.computationIterations

function KeepTeams10v10TeamSelection()

	tsprint("Initializing keep-teams 10v10 team selection")

	-- wait until the player with host privileges notifies us that he is ready
	-- register the host-ready event
	TeamSelectionListeners.hostReady = CustomGameEventManager:RegisterListener(
		TeamSelectionEvents.hostReady,
		KeepTeams10v10TeamSelectionReady
	)

end

function KeepTeams10v10TeamSelectionReady(obj, event)
	tsprint("We got notification from host")

	-- save the playerid of the privileged client / volvos function is unreliable
	PlayerWithHostPrivileges = event.PlayerID
	local player = PlayerResource:GetPlayer(PlayerWithHostPrivileges)

	-- unregister host-ready listener
	CustomGameEventManager:UnregisterListener(TeamSelectionListeners.hostReady)

	-- register the compute-complete event listener
	TeamSelectionListeners.computeComplete = CustomGameEventManager:RegisterListener(
		TeamSelectionEvents.computeComplete,
		KeepTeams10v10TeamSelectionComputeRound
	)

	-- unassign the teams
	TeamSelectionUnassignTeams()

	-- fire the first compute request
	CustomGameEventManager:Send_ServerToPlayer(player, TeamSelectionEvents.compute, nil)
end

function KeepTeams10v10TeamSelectionGetTeamComposition()

	local composition = {}

	-- create team tables
	for i = 0, PlayerResource:GetPlayerCount() - 1 do

		-- i know: this -1 is a hack but whatever
		local team = PlayerResource:GetTeam(i) - 1
		composition[team] = {}
	end

	-- create a snapshot of the team composition
	for i = 0, PlayerResource:GetPlayerCount() - 1 do
		local player = tostring(PlayerResource:GetSteamID(i))

		-- -1 hack
		local team = PlayerResource:GetTeam(i) - 1
		table.insert(composition[team], player)
	end

	return composition
end

function KeepTeams10v10TeamSelectionComputeRound(obj, event)

	tsprint("Compute complete")

	-- gather team composition by creating a snapshot
	local comp = KeepTeams10v10TeamSelectionGetTeamComposition();
	table.insert(TeamSelectionComputed, comp)

	-- increment our count
	TeamSelectionComputedCount = TeamSelectionComputedCount + 1

	-- unassign the teams
	TeamSelectionUnassignTeams()

	-- if we dont have enough data fire next event
	if TeamSelectionComputedCount < TeamSelectionComputedTotal then

		-- send another compute request to the privileged client
		local player = PlayerResource:GetPlayer(PlayerWithHostPrivileges)
		CustomGameEventManager:Send_ServerToPlayer(player, TeamSelectionEvents.compute, nil)
	else
		-- we are done and dont need more computations
		KeepTeams10v10TeamSelectionDone()
	end
end

function KeepTeams10v10TeamSelectionDone()

	tsprint("Team selection complete")

	-- unregister listener and send complete event
	CustomGameEventManager:UnregisterListener(TeamSelectionListeners.computeComplete)

	-- perform api request
	ImbaApiAutoOrderImr10v10KeepTeams(
		TeamSelectionGetAllPlayers(),
		TeamSelectionComputed,
		KeepTeams10v10TeamSelectionFinalize
	)
end

function TeamSelectionFallbackAssignment()

	-- unassign teams
	tsprint("Unassigning teams")
	TeamSelectionUnassignTeams()

	-- send failure event
	tsprint("Sending failure event to clients")
	CustomGameEventManager:Send_ServerToAllClients(TeamSelectionEvents.failure, nil)
end

function KeepTeams10v10TeamSelectionFinalize(response)

	tsprint("recieved response from server")

	-- catch errors
	if not response.ok then
		tsprint("error")
		TeamSelectionFallbackAssignment()
		return
	end

	-- assign teams based on response
	for _, steamid in ipairs(response.data.teams[1]) do
		local player = nil
		for i = 0, PlayerResource:GetPlayerCount() - 1 do
			local sid = tostring(PlayerResource:GetSteamID(i))
			if sid == steamid then
				PlayerResource:GetPlayer(i):SetTeam(DOTA_TEAM_GOODGUYS)
			end
		end
	end

	for _, steamid in ipairs(response.data.teams[2]) do
		local player = nil
		for i = 0, PlayerResource:GetPlayerCount() - 1 do
			local sid = tostring(PlayerResource:GetSteamID(i))
			if sid == steamid then
				PlayerResource:GetPlayer(i):SetTeam(DOTA_TEAM_BADGUYS)
			end
		end
	end

	-- send the complete event
	-- will cleanup event handlers on the client / ui changes
	CustomGameEventManager:Send_ServerToAllClients(TeamSelectionEvents.complete, nil)
end

























