-- Public API for micronode_chisel
-- Other mods can use this to interact with chiseled blocks

local M = micronode_chisel

-- API version
M.API_VERSION = "1.0"

------------------------------------------------------------------------------
-- Block Operations
------------------------------------------------------------------------------

--- Check if position has a chiseled block
function M.api_is_chiseled(pos)
	return M.is_micronode_block(pos)
end

--- Chisel a block at position
-- @param pos: position vector
-- @param base_material: optional base material name (default: current node)
-- @return: success boolean
function M.api_chisel(pos, base_material)
	local node = core.get_node(pos)
	local material = base_material or node.name

	if not is_chiselable(pos) and not base_material then
		return false
	end

	local palette = M.create_palette({material})
	local grid = M.create_filled_grid(1)

	local meta = core.get_meta(pos)
	local block_data = M.create_block_data(material, palette, grid, 0)
	local serialized = M.serialize_block_data(block_data)

	meta:set_string(M.META_KEY_DATA, serialized.data)
	meta:set_string(M.META_KEY_PALETTE, serialized.palette)
	meta:set_string(M.META_KEY_ROTATION, serialized.rotation)
	meta:set_string(M.META_KEY_BASE, serialized.base)

	core.swap_node(pos, {name = "micronode_chisel:chiseled_block", param2 = 0})
	M.update_block_mesh(pos)

	return true
end

--- Unchisel a block (convert back to regular node)
-- @param pos: position vector
-- @return: base material name or nil
function M.api_unchisel(pos)
	if not M.is_micronode_block(pos) then
		return nil
	end

	local meta = core.get_meta(pos)
	local base = meta:get_string(M.META_KEY_BASE)
	if base == "" then
		base = M.get_fallback_material()
	end

	core.swap_node(pos, {name = base})
	return base
end

--- Get block data
function M.api_get_block_data(pos)
	if not M.is_micronode_block(pos) then
		return nil
	end
	return M.get_block_info(pos)
end

--- Get raw grid data
function M.api_get_grid(pos)
	local meta = core.get_meta(pos)
	local data_str = meta:get_string(M.META_KEY_DATA)
	if data_str == "" then return nil end

	local block_data = M.deserialize_block_data({
		data = data_str,
		palette = meta:get_string(M.META_KEY_PALETTE),
		rotation = meta:get_string(M.META_KEY_ROTATION),
		base = meta:get_string(M.META_KEY_BASE),
	})
	return block_data.grid, block_data.palette
end

------------------------------------------------------------------------------
-- Voxel Operations
------------------------------------------------------------------------------

--- Set voxel at micronode position
-- @param pos: block position
-- @param mx, my, mz: micronode coordinates (1-16)
-- @param material: material name (or "air" to remove)
-- @return: success
function M.api_set_voxel(pos, mx, my, mz, material)
	if not M.is_micronode_block(pos) then return false end

	local meta = core.get_meta(pos)
	local block_data = M.deserialize_block_data({
		data = meta:get_string(M.META_KEY_DATA),
		palette = meta:get_string(M.META_KEY_PALETTE),
		rotation = meta:get_string(M.META_KEY_ROTATION),
		base = meta:get_string(M.META_KEY_BASE),
	})

	-- Find or add material to palette
	local mat_idx = 0
	if material and material ~= "air" then
		mat_idx = M.palette_add(block_data.palette, material)
		if not mat_idx then
			return false -- Palette full
		end
	end

	M.set_voxel(block_data.grid, mx, my, mz, mat_idx)

	-- Save
	local serialized = M.serialize_block_data(block_data)
	meta:set_string(M.META_KEY_DATA, serialized.data)
	meta:set_string(M.META_KEY_PALETTE, serialized.palette)

	M.update_block_mesh(pos)
	return true
end

--- Fill a box region with material
-- @param pos: block position
-- @param x1, y1, z1: start micronode coords (1-16)
-- @param x2, y2, z2: end micronode coords (1-16)
-- @param material: material name (or "air")
-- @return: success
function M.api_fill_box(pos, x1, y1, z1, x2, y2, z2, material)
	if not M.is_micronode_block(pos) then return false end

	local meta = core.get_meta(pos)
	local block_data = M.deserialize_block_data({
		data = meta:get_string(M.META_KEY_DATA),
		palette = meta:get_string(M.META_KEY_PALETTE),
		rotation = meta:get_string(M.META_KEY_ROTATION),
		base = meta:get_string(M.META_KEY_BASE),
	})

	local mat_idx = 0
	if material and material ~= "air" then
		mat_idx = M.palette_add(block_data.palette, material)
		if not mat_idx then
			return false
		end
	end

	M.fill_box(block_data.grid, x1, y1, z1, x2, y2, z2, mat_idx)

	local serialized = M.serialize_block_data(block_data)
	meta:set_string(M.META_KEY_DATA, serialized.data)
	meta:set_string(M.META_KEY_PALETTE, serialized.palette)

	M.update_block_mesh(pos)
	return true
end

--- Get voxel material at position
-- @param pos: block position
-- @param mx, my, mz: micronode coordinates (1-16)
-- @return: material name or "air"
function M.api_get_voxel(pos, mx, my, mz)
	local grid, palette = M.api_get_grid(pos)
	if not grid then return "air" end

	local mat_idx = M.get_voxel(grid, mx, my, mz)
	return M.palette_get(palette, mat_idx)
end

------------------------------------------------------------------------------
-- Transform Operations
------------------------------------------------------------------------------

--- Rotate chiseled block
-- @param pos: block position
-- @param times: number of 90° rotations (default 1)
-- @return: success
function M.api_rotate(pos, times)
	return M.rotate_block(pos, times)
end

--- Flip chiseled block horizontally
-- @param pos: block position
-- @return: success
function M.api_flip(pos)
	if not M.is_micronode_block(pos) then return false end

	local meta = core.get_meta(pos)
	local block_data = M.deserialize_block_data({
		data = meta:get_string(M.META_KEY_DATA),
		palette = meta:get_string(M.META_KEY_PALETTE),
		rotation = meta:get_string(M.META_KEY_ROTATION),
		base = meta:get_string(M.META_KEY_BASE),
	})

	block_data.grid = M.flip_grid(block_data.grid)

	local serialized = M.serialize_block_data(block_data)
	meta:set_string(M.META_KEY_DATA, serialized.data)

	M.update_block_mesh(pos)
	return true
end

------------------------------------------------------------------------------
-- Statistics
------------------------------------------------------------------------------

--- Get statistics about a chiseled block
function M.api_get_stats(pos)
	local info = M.get_block_info(pos)
	if not info then return nil end

	return {
		solid_voxels = info.solid_count,
		total_voxels = info.total_voxels,
		fill_percent = info.fill_percent,
		compression_ratio = info.compression_ratio,
		estimated_storage_bytes = #M.compress_grid(
			M.decompress_grid(core.get_meta(pos):get_string(M.META_KEY_DATA))
		),
	}
end

--- Count all chiseled blocks in an area
function M.api_count_chiseled(min_pos, max_pos)
	local count = 0
	local vm = VoxelManip(min_pos, max_pos)
	vm:read_from_map(min_pos, max_pos)
	-- Note: This is expensive for large areas
	-- In production, maintain a spatial index

	for x = min_pos.x, max_pos.x do
		for y = min_pos.y, max_pos.y do
			for z = min_pos.z, max_pos.z do
				local pos = vector.new(x, y, z)
				if M.is_micronode_block(pos) then
					count = count + 1
				end
			end
		end
	end

	return count
end

print("[micronode_chisel] API loaded")
