-- Public API for other mods.
-- Coordinates are 1-based micronode indices (1..RESOLUTION), local to one
-- block; world positions are ordinary node positions.

local M = micronode_chisel

M.API_VERSION = "2.1"

-------------------------------------------------------------------------------
-- Block operations
-------------------------------------------------------------------------------

-- Is there a chiseled block at pos?
function M.api_is_chiseled(pos)
	return M.is_micronode_block(pos)
end

-- Convert the node at pos into a chiseled block that looks identical.
-- Pass base_material to chisel air (creates an empty block of that material).
-- Returns true on success.
function M.api_chisel(pos, base_material)
	if M.is_micronode_block(pos) then
		return true
	end
	if M.chisel_native(pos) then
		M.refresh_block(pos)
		return true
	end
	if base_material then
		local block = M.ensure_chiseled(pos, base_material, true)
		if block then
			M.refresh_block(pos)
			return true
		end
	end
	return false
end

-- Convert a chiseled block back into a plain node of its base material.
-- Returns the node name, or nil when pos is not a chiseled block.
function M.api_unchisel(pos)
	return M.unchisel(pos)
end

function M.api_get_block_data(pos)
	return M.get_block_info(pos)
end

-- Returns grid, palette (grid is a flat array of palette indices, 0 = air).
function M.api_get_grid(pos)
	local block = M.get_block(pos)
	if not block then
		return nil
	end
	return block.grid, block.palette
end

-------------------------------------------------------------------------------
-- Voxel operations
-------------------------------------------------------------------------------

-- Set one micronode. material == nil or "air" clears it.
function M.api_set_voxel(pos, mx, my, mz, material)
	return M.api_fill_box(pos, mx, my, mz, mx, my, mz, material)
end

-- Fill an inclusive local box with a material (nil/"air" carves it out).
function M.api_fill_box(pos, x1, y1, z1, x2, y2, z2, material)
	local block = M.get_block(pos)
	if not block then
		return false
	end
	local fill = material
	if M.is_air_name(fill) then
		fill = nil
	end
	local region = M.ordered_region(x1 - 1, y1 - 1, z1 - 1, x2 - 1, y2 - 1, z2 - 1)
	M.apply_region(pos, region, fill, {create = false, base_material = material})
	return true
end

-- Material name of a micronode ("air" when empty).
function M.api_get_voxel(pos, mx, my, mz)
	local block = M.get_block(pos)
	if not block then
		return "air"
	end
	return M.palette_get(block.palette, M.get_voxel(block.grid, mx, my, mz, M.RESOLUTION))
end

-------------------------------------------------------------------------------
-- Transforms
-------------------------------------------------------------------------------

function M.api_rotate(pos, times)
	return M.rotate_block(pos, times or 1)
end

function M.api_flip(pos)
	return M.flip_block(pos)
end

-------------------------------------------------------------------------------
-- Collision and clipboard
-------------------------------------------------------------------------------

-- Collision approximation of a chiseled block:
-- {shape, node, boxes, iou, recall, fill, recognised} or nil.
function M.api_collision(pos)
	local block = M.get_block(pos)
	if not block then
		return nil
	end
	return M.collision_profile(block.grid)
end

-- Copy the block at `pos` into a clipboard owned by `owner` (any string, so a
-- mod can keep its own blueprint). Returns ok, message.
function M.api_copy(pos, owner)
	return M.copy_block(owner or "@api", pos)
end

-- Paste `owner`'s clipboard at `pos`. opts: rotate (quarter turns), flip,
-- player (name used for protection checks and undo, defaults to `owner`).
function M.api_paste(pos, owner, opts)
	opts = opts or {}
	if not opts.player then
		opts.player = owner or "@api"
	end
	return M.paste_block(owner or "@api", pos, opts)
end

-------------------------------------------------------------------------------
-- Statistics
-------------------------------------------------------------------------------

function M.api_get_stats(pos)
	local info = M.get_block_info(pos)
	if not info then
		return nil
	end
	return {
		solid_voxels = info.solid_count,
		total_voxels = info.total_voxels,
		fill_percent = info.fill_percent,
		stored_bytes = info.stored_bytes,
		compression_ratio = info.compression_ratio,
	}
end

-- Count chiseled blocks in an inclusive area. Expensive: walks every cell.
function M.api_count_chiseled(min_pos, max_pos)
	local count = 0
	for x = min_pos.x, max_pos.x do
		for y = min_pos.y, max_pos.y do
			for z = min_pos.z, max_pos.z do
				if M.is_micronode_block({x = x, y = y, z = z}) then
					count = count + 1
				end
			end
		end
	end
	return count
end

print("[micronode_chisel] API loaded")
