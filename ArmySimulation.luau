--!strict
-- by @rorutop on Discord and RorutopThe2nd on Github
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

	self.freedentitycount = 0
	self.freedentities = buffer.create(MAX * U16)

	self.recent = {
		added = { b = buffer.create(MAX * U16), count = 0 },
		removed = { b = buffer.create(MAX * U16), count = 0 },
	}

	return self
end

function ArmySimulation.add(self: simtypes.ArmySimulation, troopid: number, x: number, z: number, team: number): ()
	local freedentities = self.freedentities
	local freedentitycount = self.freedentitycount
	local recent = self.recent

	local comps = self.context.components

	local troopids = comps.troopId
	local entitiesdense = comps.entitiesdense
	local entitiesmap = comps.entitiesmap

	local isFree = freedentitycount > 0
	local freeId = if isFree then ru16(freedentities, 0) else 0
	if isFree then
		local lastId = ru16(freedentities, (freedentitycount - 1) * U16)
		wu16(freedentities, 0, lastId)
		self.freedentitycount -= 1
	end

	comps.entitycount += 1

	local entitycount = comps.entitycount

	local id = isFree and freeId or entitycount

	local off = entitycount - 1
	wu16(entitiesdense, off * U16, id)
	wu16(entitiesmap, (id - 1) * U16, entitycount)

	wu16(troopids, (id - 1) * U16, troopid)

	local def = troopcatalog[troopid]

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

	if not isClient then
		wu16(recent.added.b, recent.added.count * U16, id)
		recent.added.count += 1
	end

	self.context.troopAdded:Fire(id)
end

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

	local denseid = ru16(entitiesmap, (entity_id - 1) * U16)
	assert(denseid == 0, `{entity_id} exists in entities map!!`)

	comps.entitycount += 1

	local entitycount = comps.entitycount

	local off = entitycount - 1
	wu16(entitiesdense, off * U16, entity_id)
	wu16(entitiesmap, (entity_id - 1) * U16, entitycount)

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

	local idoff = entity_id - 1
	local denseid = ru16(entitiesmap, idoff * U16)
	if denseid == 0 then
		warn(`Dense id from {entity_id} is 0!`)
		return
	end

	self.freedentitycount += 1

	wu16(freedentities, (self.freedentitycount - 1) * U16, entity_id)

	local countOff = (entitycount - 1)
	local lastId = ru16(entitiesdense, countOff * U16)
	wu16(entitiesdense, (denseid - 1) * U16, lastId)
	wu16(entitiesdense, countOff * U16, 0)

	if lastId ~= entity_id then wu16(entitiesmap, (lastId - 1) * U16, denseid) end
	wu16(entitiesmap, idoff * U16, 0)

	if not isClient then
		wu16(recent.removed.b, recent.removed.count * U16, entity_id)
		recent.removed.count += 1
	end

	armyutils.exitCombat(comps, entity_id)

	comps.entitycount -= 1

	self.context.troopRemoved:Fire(entity_id)
	-- No need to write the components i think
end

function ArmySimulation.setValue(self: simtypes.ArmySimulation, entity_id: number, values: simtypes.EntityValues): ()
	local comps = self.context.components

	local off = entity_id - 1

	if values.posX then wf32(comps.posX, off * F32, values.posX) end
	if values.posZ then wf32(comps.posZ, off * F32, values.posZ) end
	if values.velX then wf32(comps.velX, off * F32, values.velX) end
	if values.velZ then wf32(comps.velZ, off * F32, values.velZ) end
	if values.yaw then wf32(comps.yaw, off * F32, values.yaw) end
	if values.health then wf32(comps.health, off * F32, values.health) end
	if values.state ~= nil then wu8(comps.state, off, values.state) end
	if values.team ~= nil then wu8(comps.team, off, values.team) end
	if values.targetId then wu16(comps.targetId, off * U16, values.targetId) end
	if values.actionState ~= nil then wu8(comps.actionState, off, values.actionState) end
	if values.combatPhase ~= nil then wu8(comps.combatPhase, off, values.combatPhase) end
	if values.combatTimer then wf32(comps.combatTimer, off * F32, values.combatTimer) end
end

function ArmySimulation.handleState(self: simtypes.ArmySimulation): ()
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

	for i = 1, count do
		local id = ru16(dense, (i - 1) * U16)
		if id == 0 then continue end

		local off = id - 1

		local troopid = ru16(troopIds, (id - 1) * U16)
		local def = troopcatalog[troopid]

		local curState = ru8(stateB, off)
		local lastState = ru8(lastStateB, off)
		local actState = ru8(actStateB, off)
		local lastActState = ru8(lastActStateB, off)

		const isEngagedState = curState == STATE.TARGETING or curState == STATE.FOCUSING

		--target check
		local target = ru16(targetId, off * U16)
		if target ~= 0 then
			local toff = target - 1
			local valid = rf32(health, toff * F32) > 0
				and ru16(map, toff * U16) ~= 0
				and ru8(teamB, toff) ~= ru8(teamB, off)
			if not valid then
				wu16(targetId, off * U16, 0)
				wu8(actStateB, off, ACTIONSTATE.NONE)
				wu8(combatPhase, off, 0)
				curState = STATE.ADVANCING
				wu8(stateB, off, curState)
				actState = ACTIONSTATE.NONE
			end
		end

		--if branchs

		if isEngagedState and actState == ACTIONSTATE.NONE then
			target = ru16(targetId, off * U16)
			if target ~= 0 then
				local toff = target - 1

				local x = rf32(posX, off * F32)
				local z = rf32(posZ, off * F32)
				local targetx = rf32(posX, toff * F32)
				local targetz = rf32(posZ, toff * F32)

				if (targetx - x) ^ 2 + (targetz - z) ^ 2 <= def.range then
					wu8(stateB, off, STATE.FOCUSING)
					wu8(actStateB, off, ACTIONSTATE.ATTACKING)
				end
			end
		end

		-- state enter/exit

		if curState ~= lastState then wu8(lastStateB, off, curState) end
		if actState ~= lastActState then
			--ENTER
			if actState == ACTIONSTATE.ATTACKING then armyutils.enterCombat(comps, id) end
			if actState == ACTIONSTATE.NONE then armyutils.exitCombat(comps, id) end
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
		if id == 0 then continue end

		local off = id - 1

		if rf32(health, off * F32) <= 0 then self:remove(id) end
	end

	debug.profileend()
end

function ArmySimulation.getAllCreationData(self: simtypes.ArmySimulation): Types.Troops_CreateData
	local comps = self.context.components

	local entitiesdense = comps.entitiesdense

	local troopIds = comps.troopId

	local team = comps.team

	local b = entitiesdense
	local c = comps.entitycount

	const stride = packetSchema.Spawn.stride
	const fields = packetSchema.Spawn.fields
	const idOff = fields.id.offset
	const troopIdOff = fields.troopId.offset
	const teamOff = fields.team.offset

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

		wu16(rows, s + idOff, id)

		wu16(rows, s + troopIdOff, ru16(troopIds, eOff * U16))

		wu8(rows, s + teamOff, ru8(team, eOff))
	end

	return packet
end

function ArmySimulation.flushCreation(self: simtypes.ArmySimulation): Types.Troops_CreateData
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

	recent.added.count = 0
	return packet
end

function ArmySimulation.flushRemoval(self: simtypes.ArmySimulation): { ids: buffer, count: number }
	debug.profilebegin("ArmySimulation flushRemoval")
	local recent = self.recent

	local b = recent.removed.b
	local c = recent.removed.count

	local idsb = buffer.create(c * U16)

	buffer.copy(idsb, 0, b, 0, c * U16)

	local result = {
		ids = idsb,
		count = recent.removed.count,
	}

	debug.profileend()

	recent.removed.count = 0
	return result
end

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

	local packet: Types.Troops_SnapshotData = {
		tick = tick,
		count = count,
		rows = buffer.create(stride * count),
	}

	const rows = packet.rows

	local validCount = 0
	for i = 1, count do
		const id = ru16(entitiesdense, (i - 1) * U16)
		if id == 0 then continue end

		const eOff = id - 1
		const j = validCount
		const s = j * stride

		wu16(rows, s + idOff, id)

		wu16(rows, s + posXOff, packX(rf32(posX, eOff * F32)))
		wu16(rows, s + posZOff, packZ(rf32(posZ, eOff * F32)))
		wu8(rows, s + yawOff, packRadian(rf32(yawB, eOff * F32)))

		wu8(rows, s + stateOff, ru8(stateB, eOff))

		validCount += 1
	end

	debug.profileend()

	packet.count = validCount
	return packet
end

function ArmySimulation.getPosition(self: simtypes.ArmySimulation, entity_id: number): (number, number)
	local comps = self.context.components

	local posX = comps.posX
	local posZ = comps.posZ

	local off = entity_id - 1
	return rf32(posX, off * F32), rf32(posZ, off * F32)
end

function ArmySimulation.getVelocity(self: simtypes.ArmySimulation, entity_id: number): (number, number)
	local comps = self.context.components

	local velX = comps.velX
	local velZ = comps.velZ

	local off = entity_id - 1
	return rf32(velX, off * F32), rf32(velZ, off * F32)
end

function ArmySimulation.getEntityIds(self: simtypes.ArmySimulation): (buffer, number)
	local comps = self.context.components

	local entitiesdense = comps.entitiesdense
	local entitycount = comps.entitycount

	local ids = buffer.create(entitycount * U16)
	buffer.copy(ids, 0, entitiesdense, 0, entitycount * U16)
	return ids, entitycount
end

return ArmySimulation
