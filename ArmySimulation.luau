-- Connected Discord-GitHub
--!strict
--!native
--!optimize 2
local RunService = game:GetService("RunService")
local enginetypes = require("@engine/enginetypes")
local packetSchema = require("@engine/render/packetSchema")
local armyutils = require("@engine/sim/army/armyutils")
local STATE = require("@engine/sim/states/STATE")

local config = require("@engine/sim/config")
local simtypes = require("@engine/sim/army/simtypes")
local simutils = require("@engine/sim/simutils")
local ACTIONSTATE = require("@engine/sim/states/ACTIONSTATE")
local troopcatalog = require("@features/troops/troopcatalog")
local Types = require("@shared/networking/Blink/Types")

local MAX = config.MAX
const U8 = 1
local U16 = 2
local F32 = 4

local wu8 = buffer.writeu8
local ru8 = buffer.readu8
local wu16 = buffer.writeu16
local ru16 = buffer.readu16
local wi16 = buffer.writei16
local ri16 = buffer.readi16
local wf32 = buffer.writef32
local rf32 = buffer.readf32

local ArmySimulation = {}
ArmySimulation.__index = ArmySimulation

local isClient = RunService:IsClient()

function ArmySimulation.new(context: enginetypes.IPlayfieldContext): simtypes.ArmySimulation
	local self =
		setmetatable({} :: simtypes.ArmySimulationData, { __index = ArmySimulation :: simtypes.ArmySimulationMethods })

	self.context = context

	--[[
		Initializes freed entities array
		The freed id is added when an entity is removed from the simulation
	]]
	self.freedentitycount = 0
	self.freedentities = buffer.create(MAX * U16)

	--[[
		Tracks recent added and removed, then flushes it when it was used for sending packet to the client
	]]
	self.recent = {
		added = { b = buffer.create(MAX * U16), count = 0 },
		removed = { b = buffer.create(MAX * U16), count = 0 },
	}

	return self
end

function ArmySimulation.add(self: simtypes.ArmySimulation, troopid: number, x: number, z: number, team: number): ()
	-- The actual reason why I initialize variables like this was to reduce dictionary lookup
	local freedentities = self.freedentities
	local freedentitycount = self.freedentitycount
	local recent = self.recent

	-- components comes from the playfield context. The component is a SoA (Structure of Arrays) based buffer, kinda built like ECS.
	local comps = self.context.components

	-- these are buffers
	local troopids = comps.troopId
	local entitiesdense = comps.entitiesdense
	local entitiesmap = comps.entitiesmap

	-- If there's a free entity id in the freedentities buffer, it pops out on the front and use that existing id instead of creating a new one based on entitycount
	-- Since it's a buffer, the way I pop it out is to get the id first by getting the first index of the bufer and get the last id and replace the first id with that id then reduce the entity count.
	-- This is using a O(1) method called swap remove.
	local isFree = freedentitycount > 0
	local freeId = if isFree then ru16(freedentities, 0) else 0
	if isFree then
		-- buffers start at index 0 which is the start of the offset unlike luau tables which starts at 1
		local lastId = ru16(freedentities, (freedentitycount - 1) * U16)
		wu16(freedentities, 0, lastId)
		self.freedentitycount -= 1
	end

	-- entity troop has been added, add entitycount.
	comps.entitycount += 1

	local entitycount = comps.entitycount

	-- if the freeId exists use that. else the entitycount
	local id = isFree and freeId or entitycount

	-- need the buffer offset so we have to reduce any increment to 1
	local off = entitycount - 1
	-- multiply the off by U16. U16 is 2 bytes. If the offset index is 1, it becomes 1 * 2. that's why we reduce the increment
	-- entitiesdense is a dense lookup. entitiesmap is an id lookup that has the dense id. The reason why I did this is for easy lookup and swap remove process.
	wu16(entitiesdense, off * U16, id)
	wu16(entitiesmap, (id - 1) * U16, entitycount)

	-- A troop id starts at 1. it is used for troopcatalog definition lookup
	wu16(troopids, (id - 1) * U16, troopid)

	local def = troopcatalog[troopid]

	-- Sets values easily, instead of dealing with writing buffers manually. Those are the default values when the entity got added
	self:setValue(id, {
		posX = x,
		posZ = z,
		velX = 0,
		velZ = team == 1 and -5 or 5,
		yaw = if team == 1 then 0 else math.pi,
		health = def.health,
		state = STATE.ADVANCING,
		team = team,
		targetId = 0,
		actionState = ACTIONSTATE.NONE,
		combatPhase = 0,
		combatTimer = 0,
	})

	-- Add the id to the added tracker. Last time the `not isClient` field is added because the army simulation code was used for client dead reckoning. 

	if not isClient then
		wu16(recent.added.b, recent.added.count * U16, id)
		recent.added.count += 1
	end

	-- fire to a signal that a troop got added
	self.context.troopAdded:Fire(id)
end

-- was used for client dead reckoning before too
function ArmySimulation.appendEntityId(
	self: simtypes.ArmySimulation,
	troopid: number,
	entity_id: number,
	values: simtypes.EntityValues
)
	local comps = self.context.components

	local entitiesdense = comps.entitiesdense
	local entitiesmap = comps.entitiesmap

	local troopids = comps.troopId

	-- checks if the id exists in the buffer. if it's 0, it means it's empty or invalid
	local denseid = ru16(entitiesmap, (entity_id - 1) * U16)
	assert(denseid == 0, `{entity_id} exists in entities map!!`)

	comps.entitycount += 1

	local entitycount = comps.entitycount

	local off = entitycount - 1
	wu16(entitiesdense, off * U16, entity_id)
	wu16(entitiesmap, (entity_id - 1) * U16, entitycount)

	-- sets the value based on the `values` input. it was used when the client side uses the system and it needs the values from the packet the server sent.
	self:setValue(entity_id, {
		posX = values.posX or 0,
		posZ = values.posZ or 0,
		velX = values.velX or 0,
		velZ = values.velZ or 0,
		state = values.state or 0,
		team = values.team or 0,
	})

	wu16(troopids, (entity_id - 1) * U16, troopid)

	self.context.troopAdded:Fire(entity_id)
end

function ArmySimulation.remove(self: simtypes.ArmySimulation, entity_id: number): ()
	local freedentities = self.freedentities
	local recent = self.recent

	local comps = self.context.components

	local entitiesdense = comps.entitiesdense
	local entitiesmap = comps.entitiesmap

	local entitycount = comps.entitycount

	-- checks if the id exists in the buffer. if it's 0, it means it's empty or invalid. id removal process is stopped because the id is nonexistent, duh
	local idoff = entity_id - 1
	local denseid = ru16(entitiesmap, idoff * U16)
	if denseid == 0 then
		warn(`Dense id from {entity_id} is 0!`)
		return
	end

	-- add up the freed entity since the id is going to get removed from the simulation
	self.freedentitycount += 1

	wu16(freedentities, (self.freedentitycount - 1) * U16, entity_id)

	-- Swap remove process
	-- get the last entry of the buffer first
	local countOff = (entitycount - 1)
	local lastId = ru16(entitiesdense, countOff * U16)
	-- then use the denseid as the offset and replace the current entry with the last entry id
	wu16(entitiesdense, (denseid - 1) * U16, lastId)
	-- after that, remove the last entry
	wu16(entitiesdense, countOff * U16, 0)

	-- this statement is used if the last id entry is not the same as the entity id input. it's ignored if the entity id is the only one in the buffer array
	if lastId ~= entity_id then
		wu16(entitiesmap, (lastId - 1) * U16, denseid)
	end
	-- erase from entities map
	wu16(entitiesmap, idoff * U16, 0)

	-- add the id to the removed tracker
	if not isClient then
		wu16(recent.removed.b, recent.removed.count * U16, entity_id)
		recent.removed.count += 1
	end

	-- exit the combat state of the entity id input, also does a swap remove in the function
	armyutils.exitCombat(comps, entity_id)

	comps.entitycount -= 1

	self.context.troopRemoved:Fire(entity_id)
	-- No need to write the components i think, that's to save computation
end

function ArmySimulation.setValue(self: simtypes.ArmySimulation, entity_id: number, values: simtypes.EntityValues): ()
	local comps = self.context.components

	local off = entity_id - 1

	-- Write off each fields depending what exists on the values input. could've find a better way to do this but i go towards optimization lol
	if values.posX then
		wf32(comps.posX, off * F32, values.posX)
	end
	if values.posZ then
		wf32(comps.posZ, off * F32, values.posZ)
	end
	if values.velX then
		wf32(comps.velX, off * F32, values.velX)
	end
	if values.velZ then
		wf32(comps.velZ, off * F32, values.velZ)
	end
	if values.yaw then
		wf32(comps.yaw, off * F32, values.yaw)
	end
	if values.health then
		wf32(comps.health, off * F32, values.health)
	end
	if values.state ~= nil then
		wu8(comps.state, off, values.state)
	end
	if values.team ~= nil then
		wu8(comps.team, off, values.team)
	end
	if values.targetId then
		wu16(comps.targetId, off * U16, values.targetId)
	end
	if values.actionState ~= nil then
		wu8(comps.actionState, off, values.actionState)
	end
	if values.combatPhase ~= nil then
		wu8(comps.combatPhase, off, values.combatPhase)
	end
	if values.combatTimer then
		wf32(comps.combatTimer, off * F32, values.combatTimer)
	end
end

function ArmySimulation.handleState(self: simtypes.ArmySimulation): () -- called every beat
	debug.profilebegin("ArmySimulation handleState")

	local context = self.context
	local comps = context.components

	local count = comps.entitycount
	local dense = comps.entitiesdense
	local map = comps.entitiesmap
	local troopIds = comps.troopId

	local posX = comps.posX
	local posZ = comps.posZ

	local stateB = comps.state
	local lastStateB = comps.lastState
	local actStateB = comps.actionState
	local lastActStateB = comps.lastActionState

	local targetId = comps.targetId
	local health = comps.health
	local teamB = comps.team
	local combatPhase = comps.combatPhase

	-- start up the loop from 1 to the entitycount
	for i = 1, count do
		-- get the id from the dense (since dense buffer uses entitycount as the offset)
		local id = ru16(dense, (i - 1) * U16)
		-- if id is 0 somehow, ignore
		if id == 0 then
			continue
		end

		local off = id - 1

		-- get the troop stats data
		local troopid = ru16(troopIds, (id - 1) * U16)
		local def = troopcatalog[troopid]

		-- get current state and the last state, along with the act states as the separate state from the system
		local curState = ru8(stateB, off)
		local lastState = ru8(lastStateB, off)
		local actState = ru8(actStateB, off)
		local lastActState = ru8(lastActStateB, off)

		-- TARGETING and FOCUSING are part of the engaged states, but two of them does differ from their purpose
		const isEngagedState = curState == STATE.TARGETING or curState == STATE.FOCUSING

		--target check
		local target = ru16(targetId, off * U16)
		if target ~= 0 then
			local toff = target - 1
			-- check if the current target id assigned is still valid by checking if health is over 0, the map doesn't return 0, and it's the opposing team
			local valid = rf32(health, toff * F32) > 0
				and ru16(map, toff * U16) ~= 0
				and ru8(teamB, toff) ~= ru8(teamB, off)
			if not valid then
				-- empty those offset values if the target just went not valid suddenly. then set state to advancing and the act state to none because no target to fight
				wu16(targetId, off * U16, 0)
				wu8(actStateB, off, ACTIONSTATE.NONE)
				wu8(combatPhase, off, 0)
				curState = STATE.ADVANCING
				wu8(stateB, off, curState)
				actState = ACTIONSTATE.NONE
			end
		end

		--if branchs

		-- check if it's on the engaged state but no action state because it's far away from the target. set state to focusing if near the target distance, since it's now focused to attacking the opposing troop
		if isEngagedState and actState == ACTIONSTATE.NONE then
			target = ru16(targetId, off * U16)
			if target ~= 0 then
				local toff = target - 1

				local x = rf32(posX, off * F32)
				local z = rf32(posZ, off * F32)
				local targetx = rf32(posX, toff * F32)
				local targetz = rf32(posZ, toff * F32)

				-- check whether the current position of the troop is within a given radius of the targeted troop
				if (targetx - x) ^ 2 + (targetz - z) ^ 2 <= def.range then
					wu8(stateB, off, STATE.FOCUSING)
					wu8(actStateB, off, ACTIONSTATE.ATTACKING)
				end
			end
		end

		-- state enter/exit

		if curState ~= lastState then
			-- set curstate to the last state
			wu8(lastStateB, off, curState)
		end
		if actState ~= lastActState then
			--ENTER
			if actState == ACTIONSTATE.ATTACKING then
				-- add the entity id to the active combat system when it attacks
				armyutils.enterCombat(comps, id)
			end
			if actState == ACTIONSTATE.NONE then
				-- remove the entity id from the active combat system when it's out of attacking
				armyutils.exitCombat(comps, id)
			end
			--EXIT
			-- if lastActState == ACTIONSTATE.ATTACKING then armyutils.exitCombat(comps, id) end
			wu8(lastActStateB, off, actState)
		end
	end
	debug.profileend()
end

function ArmySimulation.handleStats(self: simtypes.ArmySimulation): ()
	debug.profilebegin("ArmySimulation handleStats")

	local context = self.context
	local comps = context.components

	local count = comps.entitycount
	local dense = comps.entitiesdense

	local health = comps.health

	for i = count, 1, -1 do
		local id = ru16(dense, (i - 1) * U16)
		if id == 0 then
			continue
		end

		local off = id - 1

		-- if health is below than or same as 0, declare it as dead and remove the id
		if rf32(health, off * F32) <= 0 then
			self:remove(id)
		end
	end

	debug.profileend()
end

-- get creation data of all troops on join, though rarely have any uses?
function ArmySimulation.getAllCreationData(self: simtypes.ArmySimulation): Types.Troops_CreateData
	local comps = self.context.components

	local entitiesdense = comps.entitiesdense

	local troopIds = comps.troopId

	local team = comps.team

	local b = entitiesdense
	local c = comps.entitycount

	-- PacketSchema is an entity AoS (Array of Structures) schema registry, and we're going to pack all these data into AoS in order to reduce garbage collection when sending to the client side
	const stride = packetSchema.Spawn.stride
	const fields = packetSchema.Spawn.fields
	const idOff = fields.id.offset
	const troopIdOff = fields.troopId.offset
	const teamOff = fields.team.offset

	-- Creating a packet to the client side. if this was SoA, this table would look bigger
	const packet: Types.Troops_CreateData = {
		count = c,
		rows = buffer.create(stride * c),
	}

	const rows = packet.rows

	for i = 1, c do
		local id = ru16(b, (i - 1) * U16)
		if id == 0 then
			warn("Id == 0 when flushing creation")
			continue
		end

		local off = i - 1
		const eOff = id - 1
		const s = off * stride

		-- assign the values to the row. the row offset is based on the loop idx and is multiplied by the stride of the schema after the idx is decremented

		wu16(rows, s + idOff, id)

		wu16(rows, s + troopIdOff, ru16(troopIds, eOff * U16))

		wu8(rows, s + teamOff, ru8(team, eOff))
	end

	return packet
end

function ArmySimulation.flushCreation(self: simtypes.ArmySimulation): Types.Troops_CreateData
	-- Like getAllCreationData, but flushes the recent.added entries
	debug.profilebegin("ArmySimulation flushCreation")
	local recent = self.recent

	local comps = self.context.components

	local troopIds = comps.troopId

	local team = comps.team

	local b = recent.added.b
	local c = recent.added.count

	const stride = packetSchema.Spawn.stride
	const fields = packetSchema.Spawn.fields
	const idOff = fields.id.offset
	const troopIdOff = fields.troopId.offset
	const teamOff = fields.team.offset

	local packet: Types.Troops_CreateData = {
		count = c,
		rows = buffer.create(stride * c),
	}

	const rows = packet.rows

	for i = 1, c do
		local id = ru16(b, (i - 1) * U16)
		if id == 0 then
			warn("Id == 0 when flushing creation")
			continue
		end

		local off = i - 1
		const eOff = id - 1
		const s = off * stride

		wu16(rows, s + idOff, id)

		wu16(rows, s + troopIdOff, ru16(troopIds, eOff * U16))

		wu8(rows, s + teamOff, ru8(team, eOff))
	end

	debug.profileend()

	-- no need to loop over the recent.added table
	recent.added.count = 0
	return packet
end

-- returns a list of removed entities id packed in buffers for the client
function ArmySimulation.flushRemoval(self: simtypes.ArmySimulation): { ids: buffer, count: number }
	debug.profilebegin("ArmySimulation flushRemoval")
	local recent = self.recent

	local b = recent.removed.b
	local c = recent.removed.count

	local idsb = buffer.create(c * U16)

	-- buffer copy the recent removed buffer to the idsb value. 
	-- I do this because the removed buffer is occupied by MAX, while the buffer packet will be send will be compressed to the current removed count
	buffer.copy(idsb, 0, b, 0, c * U16)

	local result = {
		ids = idsb,
		count = recent.removed.count,
	}

	debug.profileend()

	recent.removed.count = 0
	return result
end

-- get the snapshot data for all entities live in the simulation and let the client know that there's a new snapshot to add into the snapshot circular buffer for every 10Hz
function ArmySimulation.getSnapshot(self: simtypes.ArmySimulation, tick: number): Types.Troops_SnapshotData
	debug.profilebegin("ArmySimulation getSnapshot")
	local comps = self.context.components
	local entitiesdense = comps.entitiesdense
	local posX = comps.posX
	local posZ = comps.posZ
	const yawB = comps.yaw
	local stateB = comps.state

	local count = comps.entitycount

	const packX = simutils.packX
	const packZ = simutils.packZ
	const packRadian = simutils.packRadian

	const stride = packetSchema.Snapshot.stride
	const fields = packetSchema.Snapshot.fields
	const idOff = fields.id.offset
	const posXOff = fields.posX.offset
	const posZOff = fields.posZ.offset
	const yawOff = fields.yaw.offset
	const stateOff = fields.state.offset

	-- This time it has the tick field, in purpose for snapshot interpolation to work
	local packet: Types.Troops_SnapshotData = {
		tick = tick,
		count = count,
		rows = buffer.create(stride * count),
	}

	const rows = packet.rows

	local validCount = 0
	for i = 1, count do
		const id = ru16(entitiesdense, (i - 1) * U16)
		if id == 0 then
			continue
		end

		const eOff = id - 1
		const j = validCount
		const s = j * stride

		wu16(rows, s + idOff, id)

		-- PACK the floats to uint. since the spatial grid starts at (0,0), uint can be used here instead of int with negs
		wu16(rows, s + posXOff, packX(rf32(posX, eOff * F32)))
		wu16(rows, s + posZOff, packZ(rf32(posZ, eOff * F32)))
		-- Pack the radian to u8
		wu8(rows, s + yawOff, packRadian(rf32(yawB, eOff * F32)))

		wu8(rows, s + stateOff, ru8(stateB, eOff))

		validCount += 1
	end

	debug.profileend()

	packet.count = validCount
	return packet
end

return ArmySimulation
