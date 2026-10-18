-- Render entity lifecycle for micronode blocks: one entity per merged face.
--
-- WHY ENTITIES: node definitions (node_box, tiles) are per node *type* and are
-- pushed to clients at registration, so per-block-instance geometry cannot be
-- a nodebox. A `visual = "cube"` entity can be scaled and textured per
-- instance, so each merged face rectangle gets one entity.
--
-- ENTITY TRANSFORM (the rule that matters, verified against the engine):
--   createCubeMesh() builds a cube spanning -0.5..+0.5 node and
--   GenericCAO::addToScene() applies `setScale(visual_size)` to it, so a cube
--   entity is CENTERED on the entity position and spans +-visual_size/2.
-- Node positions are node centers too (the node at `pos` covers pos+-0.5).
-- Therefore a box [x0..x1] in node-local space is spawned at
--   pos + (x0+x1)/2  with  visual_size = x1-x0
-- Spawning at the box's min corner instead displaces every face by
-- (0.5 - size/2) per axis, which renders the block as scattered, disconnected
-- faces. Do not "fix" this with a corner anchor.
--
-- Entities are not persisted (static_save = false). Engine behaviour
-- (`ServerEnvironment::deactivateFarObjects`): a non-static object is kept
-- while its mapblock is loaded in memory and is dropped when the block
-- unloads. That lifetime is exactly what we want because render.lua re-derives
-- every block's geometry from metadata on mapblock activation, so:
--   * no stale geometry survives a code change or a restart, and
--   * no per-block static object budget is consumed
--     (`max_objects_per_block` counts static objects only).

local M = micronode_chisel

M.ENTITY_NAME = "micronode_chisel:box"
M.MAX_RENDER_BOXES = 96

-- poskey -> {hash = string, objs = {ObjectRef}}
local rendered = {}

local function poskey(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function obj_alive(obj)
	if not obj then
		return false
	end
	local ok, lua = pcall(function()
		return obj:get_luaentity()
	end)
	return ok and lua ~= nil
end

function M.render_budget()
	local configured = core.settings and tonumber(core.settings:get("micronode_chisel.max_render_boxes"))
	return configured or M.MAX_RENDER_BOXES
end

local PLACEHOLDER = {"blank.png", "blank.png", "blank.png",
	"blank.png", "blank.png", "blank.png"}

core.register_entity(M.ENTITY_NAME, {
	initial_properties = {
		physical = false,
		collide_with_objects = false,
		pointable = false,        -- raycasts must hit the container node
		visual = "cube",
		visual_size = {x = 1, y = 1, z = 1},
		textures = PLACEHOLDER,
		static_save = false,
		shaded = true,
	},

	on_activate = function(self, staticdata)
		if not staticdata or staticdata == "" then
			self.object:remove()
			return
		end
		local data = core.parse_json(staticdata)
		if type(data) ~= "table" or not data.sx or data.bx == nil then
			-- Unreadable, or written by an older build whose transform math
			-- was wrong: drop it, the LBM re-derives geometry from metadata.
			self.object:remove()
			return
		end
		self.block_pos = {x = data.bx, y = data.by, z = data.bz}
		self.staticdata = staticdata
		self.object:set_properties({
			visual_size = {x = data.sx, y = data.sy, z = data.sz},
			textures = data.texs,
		})
	end,

	get_staticdata = function(self)
		return self.staticdata or ""
	end,
})

-- Remove every render entity belonging to the block at `pos`.
function M.remove_block_entities(pos)
	local key = poskey(pos)
	local entry = rendered[key]
	if entry then
		for _, obj in ipairs(entry.objs or {}) do
			if obj_alive(obj) then
				obj:remove()
			end
		end
		rendered[key] = nil
	end

	-- Sweep as well: after a restart (or with entities left by an older build)
	-- entities may exist that this process never registered.
	for _, obj in ipairs(core.get_objects_inside_radius({x = pos.x, y = pos.y, z = pos.z}, 1.6)) do
		local lua = obj:get_luaentity()
		if lua and lua.name == M.ENTITY_NAME and lua.block_pos
			and lua.block_pos.x == pos.x and lua.block_pos.y == pos.y
			and lua.block_pos.z == pos.z then
			obj:remove()
		end
	end
end

function M.forget_block(pos)
	rendered[poskey(pos)] = nil
end

-- True when the block already renders exactly these boxes and the entities are
-- still alive (used to skip re-spawning on every edit).
function M.is_current(pos, hash)
	local entry = rendered[poskey(pos)]
	if not entry or entry.hash ~= hash then
		return false
	end
	for _, obj in ipairs(entry.objs or {}) do
		if not obj_alive(obj) then
			return false
		end
	end
	return true
end

function M.remember(pos, hash, objs)
	local key = poskey(pos)
	if #objs == 0 then
		rendered[key] = nil
	else
		rendered[key] = {hash = hash, objs = objs}
	end
end

-- Spawn one entity for a face box. World position and size follow the
-- centered-cube rule documented at the top of this file.
function M.spawn_box(pos, box, textures)
	local x0, x1 = math.min(box.x0, box.x1), math.max(box.x0, box.x1)
	local y0, y1 = math.min(box.y0, box.y1), math.max(box.y0, box.y1)
	local z0, z1 = math.min(box.z0, box.z1), math.max(box.z0, box.z1)

	local sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
	if sx <= 0 or sy <= 0 or sz <= 0 then
		return nil
	end

	local origin = {
		x = pos.x + (x0 + x1) / 2,
		y = pos.y + (y0 + y1) / 2,
		z = pos.z + (z0 + z1) / 2,
	}
	local data = core.write_json({
		bx = pos.x, by = pos.y, bz = pos.z,
		sx = sx, sy = sy, sz = sz,
		texs = textures,
	})
	return core.add_entity(origin, M.ENTITY_NAME, data)
end

print("[micronode_chisel] Entity layer loaded")
