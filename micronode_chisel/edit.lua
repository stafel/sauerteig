-- Edit core for micronode_chisel: block access, picking, brushes, undo.
--
-- Editing follows the Cube 2 model: a selection snapped to the active grid
-- step, then push (extrude a face outward) or pull (carve a layer inward).
-- One difference to Sauerbraten: the world is made of 1 m nodes, so a brush
-- that crosses a node boundary is split per node. Pushing into air creates a
-- new chiseled block there, which is what makes extruding a face feel
-- continuous across node borders instead of stopping dead at them.
--
-- Coordinate spaces used here:
--  * "block-local": 1-based voxel index 1..RESOLUTION, the grid storage space
--  * "absolute":    0-based micronode offset relative to the target block,
--                   so 0..RESOLUTION-1 is the target block itself and
--                   -1 is the last cell of the block on the -x side

local M = micronode_chisel
local R = M.RESOLUTION

M.UNDO_DEPTH = 20

-------------------------------------------------------------------------------
-- Small helpers
-------------------------------------------------------------------------------

function M.pos_key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local AXIS_NAME = {[1] = "x", [2] = "y", [3] = "z"}

function M.offset(pos, axis, dir)
	local out = {x = pos.x, y = pos.y, z = pos.z}
	out[AXIS_NAME[axis]] = out[AXIS_NAME[axis]] + dir
	return out
end

function M.is_container_name(name)
	return name == M.BLOCK_NODE or name == M.BLOCK_NODE_OPEN
end

-- A node whose whole volume is opaque geometry: safe to cull faces against.
local SOLID_DRAWTYPES = {
	normal = true,
	allfaces = true,
	allfaces_optional = true,
}

function M.is_solid_cube(name)
	if M.is_container_name(name) then
		return false
	end
	local def = core.registered_nodes and core.registered_nodes[name]
	if not def or def.walkable == false then
		return false
	end
	return SOLID_DRAWTYPES[def.drawtype or "normal"] == true
end

function M.is_chiselable(pos)
	local node = core.get_node(pos)
	if node.name == "air" or node.name == "ignore" or M.is_container_name(node.name) then
		return false
	end
	local def = core.registered_nodes and core.registered_nodes[node.name]
	if not def then
		return false
	end
	if def.groups and def.groups.liquid then
		return false
	end
	return SOLID_DRAWTYPES[def.drawtype or "normal"] == true
end

-------------------------------------------------------------------------------
-- Block storage
-------------------------------------------------------------------------------

function M.is_micronode_block(pos)
	return M.is_container_name(core.get_node(pos).name)
end

-- Returns block data or nil. `meta` is re-fetched on writes; the metadata
-- object is not part of the returned data on purpose (it can go stale after a
-- node swap).
function M.get_block(pos)
	if not M.is_micronode_block(pos) then
		return nil
	end
	local meta = core.get_meta(pos)
	local data = meta:get_string(M.META_KEY_DATA)
	if data == "" then
		return nil
	end
	return M.deserialize_block_data({
		data = data,
		palette = meta:get_string(M.META_KEY_PALETTE),
		base = meta:get_string(M.META_KEY_BASE),
	})
end

function M.set_block(pos, block)
	local meta = core.get_meta(pos)
	local serialized = M.serialize_block_data(block)
	meta:set_string(M.META_KEY_DATA, serialized.data)
	meta:set_string(M.META_KEY_PALETTE, serialized.palette)
	meta:set_string(M.META_KEY_BASE, serialized.base)
end

function M.clear_block(pos)
	local meta = core.get_meta(pos)
	meta:set_string(M.META_KEY_DATA, "")
	meta:set_string(M.META_KEY_PALETTE, "")
	meta:set_string(M.META_KEY_BASE, "")
end

-- Convert a regular full cube node into a chiseled block that reproduces it
-- exactly (solid grid, single material). This is what the chisel does on the
-- first hit; visually the block does not change, because the mesher emits the
-- same surfaces with the same textures.
function M.chisel_native(pos)
	if not M.is_chiselable(pos) then
		return nil
	end
	local name = core.get_node(pos).name
	local block = M.create_block_data(name,
		M.create_palette({name}),
		M.create_filled_grid(1))
	core.swap_node(pos, {name = M.BLOCK_NODE})
	M.set_block(pos, block)
	return block
end

-- Get (or create) the chiseled block at `pos`.
--  * existing chiseled block -> returned as is
--  * air / passable node with create = true -> new empty chiseled block
--  * solid non-chiseled node -> refused (never silently converts world nodes)
function M.ensure_chiseled(pos, base_material, create)
	local node = core.get_node(pos)
	if M.is_container_name(node.name) then
		local block = M.get_block(pos)
		if block then
			return block
		end
		-- container without data (e.g. placed by /setnode): start empty
		block = M.create_block_data(base_material or M.fallback_material_or_default(),
			M.create_palette(nil), M.create_empty_grid())
		M.set_block(pos, block)
		return block
	end
	if not create then
		return nil
	end
	local def = core.registered_nodes and core.registered_nodes[node.name]
	local passable = node.name == "air" or node.name == "ignore"
		or (def and def.walkable == false)
		or (def and def.groups and def.groups.liquid)
	if not passable then
		return nil
	end
	local block = M.create_block_data(base_material or M.fallback_material_or_default(),
		M.create_palette(nil), M.create_empty_grid())
	core.swap_node(pos, {name = M.BLOCK_NODE_OPEN})
	M.set_block(pos, block)
	return block
end

-------------------------------------------------------------------------------
-- Neighbour culling
-------------------------------------------------------------------------------

local function boundary_mask(grid, axis, dir)
	local layer = (dir > 0) and 1 or R
	local cache = {}
	return function(u, v)
		local key = (u - 1) * R + v
		local hit = cache[key]
		if hit == nil then
			local x, y, z
			if axis == 1 then
				x, y, z = layer, u, v
			elseif axis == 2 then
				x, y, z = u, layer, v
			else
				x, y, z = u, v, layer
			end
			hit = M.get_voxel(grid, x, y, z, R) > 0
			cache[key] = hit
		end
		return hit
	end
end

-- Neighbour descriptor for the mesher: true = solid (cull the whole face),
-- function = per-cell culling mask, false/nil = open.
function M.build_neighbors(pos)
	local neighbors = {}
	for _, side in ipairs(M.SIDES) do
		local name = core.get_node(M.offset(pos, side.axis, side.dir)).name
		if M.is_container_name(name) then
			local block = M.get_block(M.offset(pos, side.axis, side.dir))
			if block then
				neighbors[side.key] = boundary_mask(block.grid, side.axis, side.dir)
			else
				neighbors[side.key] = false
			end
		elseif M.is_solid_cube(name) then
			neighbors[side.key] = true
		else
			-- Includes "ignore": keep the face visible rather than punching a
			-- hole in the block while the neighbour chunk is unloaded.
			neighbors[side.key] = false
		end
	end
	return neighbors
end

-------------------------------------------------------------------------------
-- Snapshots and undo (per player)
-------------------------------------------------------------------------------

local undo_stacks = {}

function M.snapshot(pos)
	local node = core.get_node(pos)
	local snap = {x = pos.x, y = pos.y, z = pos.z, name = node.name}
	if M.is_container_name(node.name) then
		local meta = core.get_meta(pos)
		snap.data = meta:get_string(M.META_KEY_DATA)
		snap.palette = meta:get_string(M.META_KEY_PALETTE)
		snap.base = meta:get_string(M.META_KEY_BASE)
	end
	return snap
end

function M.restore_snapshot(snap)
	local pos = {x = snap.x, y = snap.y, z = snap.z}
	M.remove_block_entities(pos)
	if snap.data and snap.data ~= "" then
		-- swap_node keeps metadata, which is exactly what we then overwrite;
		-- it also avoids running construct/destruct callbacks.
		core.swap_node(pos, {name = snap.name})
		local meta = core.get_meta(pos)
		meta:set_string(M.META_KEY_DATA, snap.data)
		meta:set_string(M.META_KEY_PALETTE, snap.palette or "")
		meta:set_string(M.META_KEY_BASE, snap.base or M.AIR)
	else
		-- Non-container target: set_node drops any metadata at this position.
		if snap.name == "air" or snap.name == "ignore" then
			core.remove_node(pos)
		else
			core.set_node(pos, {name = snap.name})
		end
	end
	M.refresh_block(pos)
end

local function begin_undo()
	return {blocks = {}, seen = {}}
end

local function record_undo(entry, pos)
	local key = M.pos_key(pos)
	if entry.seen[key] then
		return
	end
	entry.seen[key] = true
	entry.blocks[#entry.blocks + 1] = M.snapshot(pos)
end

local function commit_undo(player_name, entry)
	if not player_name or not entry or #entry.blocks == 0 then
		return
	end
	local stack = undo_stacks[player_name]
	if not stack then
		stack = {}
		undo_stacks[player_name] = stack
	end
	stack[#stack + 1] = entry
	while #stack > M.UNDO_DEPTH do
		table.remove(stack, 1)
	end
end

-- Undo the player's most recent edit. Returns success and the number of
-- blocks restored.
function M.undo(player_name)
	local stack = undo_stacks[player_name]
	if not stack or #stack == 0 then
		return false, 0
	end
	local entry = table.remove(stack)
	for i = #entry.blocks, 1, -1 do
		M.restore_snapshot(entry.blocks[i])
	end
	return true, #entry.blocks
end

function M.undo_depth(player_name)
	local stack = undo_stacks[player_name]
	return stack and #stack or 0
end

function M.forget_player(player_name)
	undo_stacks[player_name] = nil
end

-------------------------------------------------------------------------------
-- Refresh (geometry + collision variant, see collision.lua)
-------------------------------------------------------------------------------

-- Re-render one block (and re-pick its collision variant).
function M.refresh_block(pos)
	local block = M.get_block(pos)
	if not block then
		M.remove_block_entities(pos)
		return
	end
	M.update_collision_node(pos, block)
	M.update_block_mesh(pos)
end

-------------------------------------------------------------------------------
-- Regions and brushes
-------------------------------------------------------------------------------

-- Split an absolute, inclusive micronode region into per-block sub-regions.
-- cb(block_offset_x, block_offset_y, block_offset_z, lx0, ly0, lz0, lx1, ly1, lz1)
local function split_region(region, cb)
	local bx0, bx1 = math.floor(region.x0 / R), math.floor(region.x1 / R)
	local by0, by1 = math.floor(region.y0 / R), math.floor(region.y1 / R)
	local bz0, bz1 = math.floor(region.z0 / R), math.floor(region.z1 / R)
	for bx = bx0, bx1 do
		local lx0 = math.max(region.x0, bx * R) - bx * R + 1
		local lx1 = math.min(region.x1, bx * R + R - 1) - bx * R + 1
		for by = by0, by1 do
			local ly0 = math.max(region.y0, by * R) - by * R + 1
			local ly1 = math.min(region.y1, by * R + R - 1) - by * R + 1
			for bz = bz0, bz1 do
				local lz0 = math.max(region.z0, bz * R) - bz * R + 1
				local lz1 = math.min(region.z1, bz * R + R - 1) - bz * R + 1
				cb(bx, by, bz, lx0, ly0, lz0, lx1, ly1, lz1)
			end
		end
	end
end
M.split_region = split_region

local function ordered_region(x0, y0, z0, x1, y1, z1)
	return {
		x0 = math.min(x0, x1), y0 = math.min(y0, y1), z0 = math.min(z0, z1),
		x1 = math.max(x0, x1), y1 = math.max(y0, y1), z1 = math.max(z0, z1),
	}
end
M.ordered_region = ordered_region

local function normal_axis(hit)
	if hit.nx ~= 0 then return 1 end
	if hit.ny ~= 0 then return 2 end
	if hit.nz ~= 0 then return 3 end
	return nil
end

-- Push: add a grid-thick layer on the air side of the hit face, in-plane
-- extent snapped to the grid step.
function M.push_brush(hit, gs)
	gs = math.max(1, math.min(R, gs or 1))
	local h = {hit.x - 1, hit.y - 1, hit.z - 1}
	local axis = normal_axis(hit)
	if not axis then
		return nil
	end
	local n = {hit.nx, hit.ny, hit.nz}

	local lo, hi = {}, {}
	for a = 1, 3 do
		if a == axis then
			local start = h[a] + n[a]
			lo[a], hi[a] = start, start + n[a] * (gs - 1)
		else
			local start = math.floor(h[a] / gs) * gs
			lo[a], hi[a] = start, start + gs - 1
		end
	end
	return ordered_region(lo[1], lo[2], lo[3], hi[1], hi[2], hi[3])
end

-- Pull: carve a grid-thick layer inward from the hit face, in-plane extent
-- snapped to the grid step.
function M.pull_brush(hit, gs)
	gs = math.max(1, math.min(R, gs or 1))
	local h = {hit.x - 1, hit.y - 1, hit.z - 1}
	local axis = normal_axis(hit)
	local n = {0, 0, 0}
	if axis then
		n = {hit.nx, hit.ny, hit.nz}
	else
		-- no face information (ray started inside the block): carve the cell
		axis = 1
		gs = 1
	end

	local lo, hi = {}, {}
	for a = 1, 3 do
		if a == axis then
			local stop = h[a] - n[a] * (gs - 1)
			lo[a], hi[a] = h[a], stop
		else
			local start = math.floor(h[a] / gs) * gs
			lo[a], hi[a] = start, start + gs - 1
		end
	end
	return ordered_region(lo[1], lo[2], lo[3], hi[1], hi[2], hi[3])
end

-------------------------------------------------------------------------------
-- Applying a region
-------------------------------------------------------------------------------

-- Fill `region` (absolute micronode coords relative to `origin`) with
-- `material`, or with air when `material` is nil.
-- opts:
--   create         allow creating chiseled blocks in passable nodes (push)
--   base_material  material name for a newly created block
--   player         player name, enables undo
-- Returns the list of changed block positions.
function M.apply_region(origin, region, material, opts)
	opts = opts or {}
	local changed = {}
	local dirty = {}
	local undo = opts.player and begin_undo() or nil

	local function mark_dirty(pos)
		dirty[M.pos_key(pos)] = pos
	end

	split_region(region, function(bx, by, bz, lx0, ly0, lz0, lx1, ly1, lz1)
		local pos = {x = origin.x + bx, y = origin.y + by, z = origin.z + bz}
		-- Server authority: protected nodes are never edited.
		if opts.player and core.is_protected and core.is_protected(pos, opts.player) then
			return
		end
		if undo then
			record_undo(undo, pos)
		end

		local block = M.ensure_chiseled(pos, material or opts.base_material, opts.create)
		if not block then
			return
		end

		local mat_idx = 0
		if material then
			mat_idx = M.palette_add(block.palette, material)
			if not mat_idx then
				return -- palette full: skip this block rather than corrupt it
			end
		end

		M.fill_box(block.grid, lx0, ly0, lz0, lx1, ly1, lz1, mat_idx)
		block.palette = M.palette_compact(block.grid, block.palette)
		M.set_block(pos, block)

		changed[#changed + 1] = pos

		-- Neighbours on a touched node boundary need a re-mesh: their face
		-- culling depends on the cells we just changed.
		if lx0 == 1 then mark_dirty(M.offset(pos, 1, -1)) end
		if lx1 == R then mark_dirty(M.offset(pos, 1, 1)) end
		if ly0 == 1 then mark_dirty(M.offset(pos, 2, -1)) end
		if ly1 == R then mark_dirty(M.offset(pos, 2, 1)) end
		if lz0 == 1 then mark_dirty(M.offset(pos, 3, -1)) end
		if lz1 == R then mark_dirty(M.offset(pos, 3, 1)) end
	end)

	local changed_set = {}
	for _, pos in ipairs(changed) do
		M.refresh_block(pos)
		changed_set[M.pos_key(pos)] = true
	end
	for key, pos in pairs(dirty) do
		if not changed_set[key] and M.is_micronode_block(pos) then
			M.update_block_mesh(pos)
		end
	end

	commit_undo(opts.player, undo)
	return changed
end

-------------------------------------------------------------------------------
-- Picking (voxel DDA, Amanatides & Woo)
-------------------------------------------------------------------------------

-- March the ray through one block's grid.
-- Returns {x, y, z, nx, ny, nz} (1-based cell + unit face normal pointing at
-- air) or nil.
function M.raycast_grid(grid, pos, origin, dir, res)
	res = res or R

	local a = {
		x = (origin.x - (pos.x - 0.5)) * res,
		y = (origin.y - (pos.y - 0.5)) * res,
		z = (origin.z - (pos.z - 0.5)) * res,
	}
	local d = {x = dir.x * res, y = dir.y * res, z = dir.z * res}

	-- Slab test against [0, res]^3
	local t_enter, t_exit = 0, math.huge
	local enter_axis, enter_sign = nil, nil
	for axis = 1, 3 do
		local name = AXIS_NAME[axis]
		local o, dd = a[name], d[name]
		if math.abs(dd) < 1e-9 then
			if o < 0 or o > res then
				return nil
			end
		else
			local t1 = -o / dd
			local t2 = (res - o) / dd
			local near_t, far_t = math.min(t1, t2), math.max(t1, t2)
			if near_t > t_enter then
				t_enter = near_t
				enter_axis = name
				enter_sign = (dd > 0) and -1 or 1
			end
			if far_t < t_exit then
				t_exit = far_t
			end
		end
	end
	if t_enter > t_exit then
		return nil
	end

	local cell = {}
	for axis = 1, 3 do
		local name = AXIS_NAME[axis]
		local at = a[name] + t_enter * d[name]
		local c = math.floor(at)
		if c < 0 then c = 0 end
		if c > res - 1 then c = res - 1 end
		cell[name] = c
	end

	local step, next_t, delta_t = {}, {}, {}
	for axis = 1, 3 do
		local name = AXIS_NAME[axis]
		local dd = d[name]
		local at = a[name] + t_enter * dd
		if dd > 1e-9 then
			step[name] = 1
			next_t[name] = t_enter + ((cell[name] + 1) - at) / dd
			delta_t[name] = 1 / dd
		elseif dd < -1e-9 then
			step[name] = -1
			next_t[name] = t_enter + (cell[name] - at) / dd
			delta_t[name] = -1 / dd
		else
			step[name] = 0
			next_t[name] = math.huge
			delta_t[name] = math.huge
		end
	end

	local normal = {x = 0, y = 0, z = 0}
	if enter_axis then
		normal[enter_axis] = enter_sign
	end

	for _ = 1, 3 * res + 3 do
		if cell.x < 0 or cell.x >= res or cell.y < 0 or cell.y >= res
			or cell.z < 0 or cell.z >= res then
			return nil
		end
		local idx = (cell.z * res + cell.y) * res + cell.x + 1
		if (grid[idx] or 0) > 0 then
			return {x = cell.x + 1, y = cell.y + 1, z = cell.z + 1,
				nx = normal.x, ny = normal.y, nz = normal.z}
		end

		local axis
		if next_t.x <= next_t.y and next_t.x <= next_t.z then
			axis = "x"
		elseif next_t.y <= next_t.z then
			axis = "y"
		else
			axis = "z"
		end
		if next_t[axis] == math.huge or next_t[axis] > t_exit + 1e-9 then
			return nil
		end
		cell[axis] = cell[axis] + step[axis]
		next_t[axis] = next_t[axis] + delta_t[axis]
		normal = {x = 0, y = 0, z = 0}
		normal[axis] = -step[axis]
	end
	return nil
end

function M.eye_pos(player)
	local base = player:get_pos()
	local eye_height = 1.625
	if type(player.get_properties) == "function" then
		local props = player:get_properties()
		if props and props.eye_height then
			eye_height = props.eye_height
		end
	end
	return {x = base.x, y = base.y + eye_height, z = base.z}
end

function M.raycast_block(block, player, pos)
	local dir = player:get_look_dir()
	if not dir then
		return nil
	end
	return M.raycast_grid(block.grid, pos, M.eye_pos(player), dir, R)
end

-- The chiseled block the player is looking at, or nil. Used by commands; the
-- tool itself uses pointed_thing.under plus M.raycast_block.
function M.get_pointed_block(player, range)
	if not core.raycast then
		return nil
	end
	local eye = M.eye_pos(player)
	local dir = player:get_look_dir()
	if not dir then
		return nil
	end
	range = range or 10
	local target = {
		x = eye.x + dir.x * range,
		y = eye.y + dir.y * range,
		z = eye.z + dir.z * range,
	}
	local hit = core.raycast(eye, target, false, false):next()
	if hit and hit.type == "node" and M.is_micronode_block(hit.under) then
		return hit.under
	end
	return nil
end

-------------------------------------------------------------------------------
-- Whole edit operation (pick + brush + apply)
-------------------------------------------------------------------------------

-- mode: "push" (add material on the hit face) or "pull" (carve into it).
-- Returns ok, message-or-count.
function M.edit_at(player, pos, mode, gs, material)
	local name = player:get_player_name()
	local block = M.get_block(pos)
	if not block then
		return false, "not a chiseled block"
	end

	local hit = M.raycast_block(block, player, pos)
	if not hit then
		return false, "no micronode surface under the crosshair"
	end

	if mode == "push" then
		local region = M.push_brush(hit, gs)
		if not region then
			return false, "aim at a face"
		end
		local active = material
		if not active then
			active = M.palette_get(block.palette,
				M.get_voxel(block.grid, hit.x, hit.y, hit.z, R))
		end
		if M.is_air_name(active) then
			active = block.base
		end
		if M.is_air_name(active) then
			active = M.fallback_material_or_default()
		end
		if not M.palette_has(block.palette, active) then
			return false, tostring(active) ..
				" needs a free palette slot: this block already holds 4 materials"
		end
		local changed = M.apply_region(pos, region, active,
			{create = true, base_material = active, player = name})
		if #changed == 0 then
			return false, "nothing added: the neighbouring block is solid or protected"
		end
		return true, #changed
	end

	local region = M.pull_brush(hit, gs)
	local changed = M.apply_region(pos, region, nil, {create = false, player = name})
	if #changed == 0 then
		return false, "nothing removed: protected block?"
	end
	return true, #changed
end

-------------------------------------------------------------------------------
-- Block transforms / conversion
-------------------------------------------------------------------------------

function M.rotate_block(pos, times)
	local block = M.get_block(pos)
	if not block then
		return false
	end
	block.grid = M.rotate_grid(block.grid, times or 1, R)
	block.palette = M.palette_compact(block.grid, block.palette)
	M.set_block(pos, block)
	M.refresh_block(pos)
	return true
end

function M.flip_block(pos)
	local block = M.get_block(pos)
	if not block then
		return false
	end
	block.grid = M.flip_grid(block.grid, R)
	block.palette = M.palette_compact(block.grid, block.palette)
	M.set_block(pos, block)
	M.refresh_block(pos)
	return true
end

-- Convert a chiseled block back into a plain node of its base material.
function M.unchisel(pos)
	local block = M.get_block(pos)
	if not block then
		return nil
	end
	local base = block.base
	if M.is_air_name(base) or not (core.registered_nodes and core.registered_nodes[base]) then
		base = M.fallback_material_or_default()
	end
	M.remove_block_entities(pos)
	core.swap_node(pos, {name = base})
	M.clear_block(pos)
	return base
end

function M.get_block_info(pos)
	local block = M.get_block(pos)
	if not block then
		return nil
	end
	local solid = M.count_solid(block.grid)
	local ratio, stored = M.get_compression_ratio(block.grid)
	return {
		base = block.base,
		palette = block.palette,
		solid_count = solid,
		total_voxels = #block.grid,
		fill_percent = (#block.grid > 0) and (solid / #block.grid * 100) or 0,
		compression_ratio = ratio,
		stored_bytes = stored,
	}
end

print("[micronode_chisel] Edit core loaded")
