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

-- Every container type (one per collision shape, see collision.lua) counts as
-- a chiseled block; M.CONTAINER_NODES is built there so this stays a single
-- table lookup instead of an ever-growing comparison.
function M.is_container_name(name)
	return M.CONTAINER_NODES[name] == true
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

-- Per-cell culling mask for one face of a neighbouring chiseled block.
-- `res` is the neighbour's source resolution and `step` the coarsening factor
-- of the mesh being built (1 = full resolution). A coarse cell is culled when
-- *any* source cell in its footprint touches the shared boundary; culling
-- aggressively avoids coincident quads with the neighbour, at the cost of
-- possibly hiding a thin sliver in the emergency coarse path.
local function boundary_mask(grid, axis, dir, res, step)
	res = res or R
	step = math.max(1, step or 1)
	local ores = math.ceil(res / step)
	local layer = (dir > 0) and 1 or res
	local cache = {}
	return function(u, v)
		local key = (u - 1) * ores + v
		local hit = cache[key]
		if hit == nil then
			hit = false
			local u0 = (u - 1) * step + 1
			local v0 = (v - 1) * step + 1
			for su = u0, math.min(u0 + step - 1, res) do
				for sv = v0, math.min(v0 + step - 1, res) do
					local x, y, z
					if axis == 1 then
						x, y, z = layer, su, sv
					elseif axis == 2 then
						x, y, z = su, layer, sv
					else
						x, y, z = su, sv, layer
					end
					if M.get_voxel(grid, x, y, z, res) > 0 then
						hit = true
						break
					end
				end
				if hit then
					break
				end
			end
			cache[key] = hit
		end
		return hit
	end
end

-- Neighbour descriptor for the mesher: true = solid (cull the whole face),
-- function = per-cell culling mask, false/nil = open. `step` selects the
-- coarsening factor of the mesh being built, so the per-cell masks are read at
-- the matching stride instead of the full-resolution one.
function M.build_neighbors(pos, step)
	step = step or 1
	local neighbors = {}
	for _, side in ipairs(M.SIDES) do
		local npos = M.offset(pos, side.axis, side.dir)
		local name = core.get_node(npos).name
		if M.is_container_name(name) then
			local block = M.get_block(npos)
			if block then
				neighbors[side.key] = boundary_mask(block.grid, side.axis, side.dir, R, step)
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

-- Explicit undo entries for operations that replace a whole block (paste).
-- Snapshots MUST be taken before the block is modified, so callers open an
-- entry, record the affected positions, mutate, then commit it.
function M.begin_undo_entry()
	return begin_undo()
end

function M.add_undo_position(entry, pos)
	if entry then
		record_undo(entry, pos)
	end
	return entry
end

function M.commit_undo_entry(player_name, entry)
	commit_undo(player_name, entry)
end

-- Convenience for callers that only need "restore these positions": snapshots
-- the current state immediately. Do not call it after the mutation.
function M.commit_positions_undo(player_name, positions)
	if not player_name or not positions then
		return 0
	end
	local entry = begin_undo()
	for _, pos in ipairs(positions) do
		record_undo(entry, pos)
	end
	commit_undo(player_name, entry)
	return #entry.blocks
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

-- A block with no solid cells left is not chiseled geometry: remove the
-- container node entirely instead of leaving an invisible, walk-through node
-- that still occupies the map position (and would need to be dug away).
-- `core.remove_node` fires on_destruct (drop the render entities) and
-- after_destruct (re-mesh the neighbours); the explicit calls here keep the
-- behaviour identical when the caller already cleared the render cache.
-- Deliberately *not* called from refresh_block: undo/restore must be able to
-- put an empty block back exactly as it was.
function M.remove_if_empty(pos)
	local block = M.get_block(pos)
	if not block or not M.is_empty(block.grid) then
		return false
	end
	M.remove_block_entities(pos)
	M.forget_block(pos)
	core.remove_node(pos)
	M.remesh_neighbors(pos)
	return true
end

-- Re-mesh every chiseled block touching `pos`.
--
-- Face culling is per cell against the neighbour: a block drops the faces
-- whose neighbouring cell is solid, so ANY change on the other side of a shared
-- boundary invalidates the culled geometry. Whenever a node disappears or
-- appears next to a chiseled block - a plain node dug or placed, or a chiseled
-- block dug or carved to nothingness - the neighbour has to be re-meshed or it
-- keeps rendering with holes where the removed geometry used to be.
function M.remesh_neighbors(pos)
	local remeshed = 0
	for _, side in ipairs(M.SIDES) do
		local npos = M.offset(pos, side.axis, side.dir)
		if M.is_micronode_block(npos) then
			M.update_block_mesh(npos)
			remeshed = remeshed + 1
		end
	end
	return remeshed
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

-- Blocks other than the origin block that an absolute region touches.
-- Each split block contributes one entry, so the result is small (a brush
-- spans at most a handful of nodes).
function M.region_neighbour_blocks(origin, region)
	local out = {}
	split_region(region, function(bx, by, bz)
		if bx ~= 0 or by ~= 0 or bz ~= 0 then
			out[#out + 1] = {x = origin.x + bx, y = origin.y + by, z = origin.z + bz}
		end
	end)
	return out
end

-- Returns nil when the region only touches the origin block and existing
-- chiseled blocks, or the first position where applying it would create a new
-- chiseled node.
function M.region_spills_into_new_block(origin, region)
	for _, pos in ipairs(M.region_neighbour_blocks(origin, region)) do
		if not M.is_micronode_block(pos) then
			return pos
		end
	end
	return nil
end

-------------------------------------------------------------------------------
-- Paying for border pushes
-------------------------------------------------------------------------------
-- Pushing a face that sits on the node border creates a chiseled node in the
-- neighbouring position, so the player is charged one node of the pushed
-- material for it. Creative players pay nothing. Callers without an inventory
-- (the public API, tests, a fake player) are treated like creative: they are
-- not silently denied.

local function player_inventory(player)
	if not player or type(player.get_inventory) ~= "function" then
		return nil
	end
	local ok, inv = pcall(player.get_inventory, player)
	if ok then
		return inv
	end
	return nil
end

local function is_creative(player)
	local name = player and player.get_player_name and player:get_player_name()
	if not name or not core.is_creative_enabled then
		-- No creative switch (test stub): treat as creative so behaviour does
		-- not depend on engine features being present.
		return true
	end
	local ok, creative = pcall(core.is_creative_enabled, name)
	return ok and creative == true
end

local function material_stack(material, count)
	local stack = ItemStack(material)
	if count and count > 1 and type(stack.set_count) == "function" then
		stack:set_count(count)
	end
	return stack
end

-- Can this player afford to create `count` chiseled nodes of `material`?
-- Returns true, or false plus a message.
function M.can_pay_for_node(player, material, count)
	count = math.max(1, count or 1)
	if is_creative(player) then
		return true
	end
	local inv = player_inventory(player)
	if not inv then
		return true
	end
	if M.is_air_name(material) then
		return false, "no material selected"
	end
	if not inv:contains_item("main", material_stack(material, count)) then
		return false, string.format("you need %d %s in your inventory",
			count, material)
	end
	return true
end

-- Take `count` nodes of `material` from the player. Returns the number actually
-- removed (0 in creative or without an inventory).
function M.pay_for_node(player, material, count)
	count = math.max(1, count or 1)
	if is_creative(player) or M.is_air_name(material) then
		return 0
	end
	local inv = player_inventory(player)
	if not inv then
		return 0
	end
	local paid = 0
	for _ = 1, count do
		if not inv:contains_item("main", ItemStack(material)) then
			break
		end
		inv:remove_item("main", ItemStack(material))
		paid = paid + 1
	end
	return paid
end

-- Give back nodes taken by M.pay_for_node (used when the edit failed).
function M.refund_node(player, material, count)
	if not count or count <= 0 or M.is_air_name(material) then
		return
	end
	local inv = player_inventory(player)
	if not inv then
		return
	end
	inv:add_item("main", material_stack(material, count))
end

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
		-- Carving the last solid cell away leaves an invisible, walk-through
		-- node behind; remove it so the position is genuinely empty again.
		M.remove_if_empty(pos)

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

-- The node the player is looking at (any type), or nil. Needed by commands that
-- accept plain nodes, e.g. pasting onto a solid node to convert it.
function M.get_pointed_node(player, range)
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
	if hit and hit.type == "node" then
		return hit.under
	end
	return nil
end

-- The chiseled block the player is looking at, or nil. Used by commands; the
-- tool itself uses pointed_thing.under plus M.raycast_block.
function M.get_pointed_block(player, range)
	local pos = M.get_pointed_node(player, range)
	if pos and M.is_micronode_block(pos) then
		return pos
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

		-- A face flush with the node border pushes into the neighbouring node,
		-- which means creating a new chiseled node there. That is allowed, but
		-- it costs one node of the pushed material per block created (creative
		-- pays nothing).
		local missing = {}
		for _, npos in ipairs(M.region_neighbour_blocks(pos, region)) do
			if not M.is_micronode_block(npos) then
				missing[#missing + 1] = npos
			end
		end
		if #missing > 0 then
			local ok, why = M.can_pay_for_node(player, active, #missing)
			if not ok then
				return false, why .. string.format(
					" (that face is on the node border and would place %d new node(s))",
					#missing)
			end
		end

		local changed = M.apply_region(pos, region, active,
			{create = #missing > 0, base_material = active, player = name})
		if #changed == 0 then
			return false, "nothing added: the target block is protected"
		end
		if #missing > 0 then
			-- Charge only for the blocks that actually got created: a partly
			-- protected brush may have skipped some of them.
			local created = 0
			for _, npos in ipairs(missing) do
				if M.is_micronode_block(npos) then
					created = created + 1
				end
			end
			if created > 0 then
				M.pay_for_node(player, active, created)
			end
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
	local collision = M.collision_profile(block.grid)
	return {
		base = block.base,
		palette = block.palette,
		solid_count = solid,
		total_voxels = #block.grid,
		fill_percent = (#block.grid > 0) and (solid / #block.grid * 100) or 0,
		compression_ratio = ratio,
		stored_bytes = stored,
		collision_shape = collision.shape,
		collision_boxes = collision.boxes,
		collision_recognised = collision.recognised,
		collision_iou = collision.iou,
		collision_node = collision.node,
	}
end

print("[micronode_chisel] Edit core loaded")
