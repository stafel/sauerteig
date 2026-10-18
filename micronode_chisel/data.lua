-- Micronode Data Structures
-- 16×16×16 = 4,096 micronodes per block (6.25cm resolution)
-- RLE compression for efficient storage

micronode_chisel = micronode_chisel or {}
local M = micronode_chisel

-- Constants
M.RESOLUTION = 16           -- 16×16×16 micronodes per block
M.VOXEL_COUNT = 16 * 16 * 16  -- 4,096 micronodes
M.MAX_MATERIALS = 4         -- Up to 4 materials per chiseled block
M.META_KEY_DATA = "mn_data"      -- Node metadata key for voxel data
M.META_KEY_PALETTE = "mn_palette" -- Node metadata key for material palette
M.META_KEY_ROTATION = "mn_rotation" -- Node metadata key for rotation
M.META_KEY_BASE = "mn_base"       -- Node metadata key for base material

-- Grid sizes for editing (in micronodes)
M.GRID_SIZES = {1, 2, 4, 8, 16}
M.GRID_NAMES = {"1/16", "1/8", "1/4", "1/2", "1/1"}

------------------------------------------------------------------------------
-- Voxel Data Structure
------------------------------------------------------------------------------

-- Create a new empty voxel grid (all air)
function M.create_empty_grid()
	local grid = {}
	for i = 1, M.VOXEL_COUNT do
		grid[i] = 0  -- 0 = air
	end
	return grid
end

-- Create a voxel grid filled with a single material
function M.create_filled_grid(material_idx)
	local grid = {}
	for i = 1, M.VOXEL_COUNT do
		grid[i] = material_idx or 1
	end
	return grid
end

-- Get voxel at position (x, y, z) — 1-indexed, 1..16
function M.get_voxel(grid, x, y, z)
	if x < 1 or x > M.RESOLUTION or y < 1 or y > M.RESOLUTION or z < 1 or z > M.RESOLUTION then
		return 0
	end
	local idx = (z - 1) * M.RESOLUTION * M.RESOLUTION + (y - 1) * M.RESOLUTION + x
	return grid[idx] or 0
end

-- Set voxel at position (x, y, z) — 1-indexed, 1..16
function M.set_voxel(grid, x, y, z, material_idx)
	if x < 1 or x > M.RESOLUTION or y < 1 or y > M.RESOLUTION or z < 1 or z > M.RESOLUTION then
		return false
	end
	local idx = (z - 1) * M.RESOLUTION * M.RESOLUTION + (y - 1) * M.RESOLUTION + x
	grid[idx] = material_idx or 0
	return true
end

-- Fill a box region with a material
function M.fill_box(grid, x1, y1, z1, x2, y2, z2, material_idx)
	x1, x2 = math.min(x1, x2), math.max(x1, x2)
	y1, y2 = math.min(y1, y2), math.max(y1, y2)
	z1, z2 = math.min(z1, z2), math.max(z1, z2)

	for z = z1, z2 do
		for y = y1, y2 do
			for x = x1, x2 do
				M.set_voxel(grid, x, y, z, material_idx)
			end
		end
	end
end

-- Count non-air voxels
function M.count_solid(grid)
	local count = 0
	for i = 1, M.VOXEL_COUNT do
		if grid[i] ~= 0 then
			count = count + 1
		end
	end
	return count
end

-- Check if grid is empty (all air)
function M.is_empty(grid)
	return M.count_solid(grid) == 0
end

-- Check if grid is full (all solid)
function M.is_full(grid)
	return M.count_solid(grid) == M.VOXEL_COUNT
end

------------------------------------------------------------------------------
-- RLE Compression
------------------------------------------------------------------------------

-- Compress voxel grid using Run-Length Encoding
-- Format: [count:2bytes][material:1byte] repeated
-- Max run: 65535 (fits in 2 bytes)
function M.compress_grid(grid)
	local compressed = {}
	local pos = 1

	while pos <= M.VOXEL_COUNT do
		local material = grid[pos]
		local run_length = 1

		-- Count run length
		while pos + run_length <= M.VOXEL_COUNT and grid[pos + run_length] == material and run_length < 65535 do
			run_length = run_length + 1
		end

		-- Store as 3 bytes: 2 bytes count (little-endian) + 1 byte material
		table.insert(compressed, string.char(run_length % 256, math.floor(run_length / 256), material))

		pos = pos + run_length
	end

	return table.concat(compressed)
end

-- Decompress RLE data back to voxel grid
function M.decompress_grid(data)
	local grid = {}
	local pos = 1
	local idx = 1

	while pos <= #data and idx <= M.VOXEL_COUNT do
		local byte1 = string.byte(data, pos)
		local byte2 = string.byte(data, pos + 1)
		local material = string.byte(data, pos + 2)
		local run_length = byte1 + byte2 * 256

		for i = 1, run_length do
			if idx <= M.VOXEL_COUNT then
				grid[idx] = material
				idx = idx + 1
			end
		end

		pos = pos + 3
	end

	-- Fill any remaining with air
	while idx <= M.VOXEL_COUNT do
		grid[idx] = 0
		idx = idx + 1
	end

	return grid
end

-- Calculate compression ratio
function M.get_compression_ratio(grid)
	local compressed = M.compress_grid(grid)
	local original_size = M.VOXEL_COUNT
	local compressed_size = #compressed
	return original_size / compressed_size, compressed_size
end

------------------------------------------------------------------------------
-- Material Palette
------------------------------------------------------------------------------

-- Create a new material palette
function M.create_palette(materials)
	-- materials: array of node names (max 4)
	local palette = {}
	for i = 1, M.MAX_MATERIALS do
		palette[i] = materials and materials[i] or "air"
	end
	return palette
end

-- Add a material to palette (returns index, or nil if full)
function M.palette_add(palette, node_name)
	for i = 1, M.MAX_MATERIALS do
		if palette[i] == node_name then
			return i
		end
	end
	for i = 1, M.MAX_MATERIALS do
		if palette[i] == "air" or palette[i] == "" then
			palette[i] = node_name
			return i
		end
	end
	return nil -- Palette full
end

-- Get material name from palette index
function M.palette_get(palette, idx)
	return palette[idx] or "air"
end

-- Serialize palette to string
function M.palette_serialize(palette)
	return table.concat(palette, ",")
end

-- Deserialize palette from string
function M.palette_deserialize(str)
	local palette = {}
	for name in string.gmatch(str or "", "[^,]+") do
		table.insert(palette, name)
	end
	-- Pad to MAX_MATERIALS
	while #palette < M.MAX_MATERIALS do
		table.insert(palette, "air")
	end
	return palette
end

------------------------------------------------------------------------------
-- Micronode Block Data
------------------------------------------------------------------------------

-- Create a complete micronode block data structure
function M.create_block_data(base_material, palette, grid, rotation)
	return {
		base = base_material or "air",
		palette = palette or M.create_palette({base_material}),
		grid = grid or M.create_filled_grid(1),
		rotation = rotation or 0,  -- 0-3 (0°, 90°, 180°, 270°)
	}
end

-- Serialize complete block data for storage in node metadata
function M.serialize_block_data(block_data)
	local compressed_grid = M.compress_grid(block_data.grid)
	local palette_str = M.palette_serialize(block_data.palette)

	return {
		data = compressed_grid,
		palette = palette_str,
		rotation = tostring(block_data.rotation or 0),
		base = block_data.base or "air",
	}
end

-- Deserialize block data from node metadata
function M.deserialize_block_data(meta_strings)
	local compressed_grid = meta_strings.data or ""
	local grid = M.decompress_grid(compressed_grid)
	local palette = M.palette_deserialize(meta_strings.palette)
	local rotation = tonumber(meta_strings.rotation) or 0
	local base = meta_strings.base or "air"

	return M.create_block_data(base, palette, grid, rotation)
end

------------------------------------------------------------------------------
-- Rotation
------------------------------------------------------------------------------

-- Rotate grid 90° clockwise around Y axis
function M.rotate_grid(grid, times)
	times = (times or 1) % 4
	if times == 0 then return grid end

	local new_grid = {}
	for z = 1, M.RESOLUTION do
		for y = 1, M.RESOLUTION do
			for x = 1, M.RESOLUTION do
				local voxel = M.get_voxel(grid, x, y, z)
				-- Rotate 90° CW: (x, z) -> (z, RESOLUTION - x + 1)
				local nx, nz
				if times == 1 then
					nx, nz = z, M.RESOLUTION - x + 1
				elseif times == 2 then
					nx, nz = M.RESOLUTION - x + 1, M.RESOLUTION - z + 1
				else -- times == 3
					nx, nz = M.RESOLUTION - z + 1, x
				end
				M.set_voxel(new_grid, nx, y, nz, voxel)
			end
		end
	end
	return new_grid
end

-- Flip grid horizontally (mirror X axis)
function M.flip_grid(grid)
	local new_grid = {}
	for z = 1, M.RESOLUTION do
		for y = 1, M.RESOLUTION do
			for x = 1, M.RESOLUTION do
				local voxel = M.get_voxel(grid, x, y, z)
				M.set_voxel(new_grid, M.RESOLUTION - x + 1, y, z, voxel)
			end
		end
	end
	return new_grid
end

------------------------------------------------------------------------------
-- Utility
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Game-agnostic Material Detection
------------------------------------------------------------------------------

-- Find a stone-like material that exists in the current game
-- Checks common stone node names across games (minetest_game, devtest, etc.)
function M.get_fallback_material()
	local candidates = {
		"default:stone",     -- minetest_game
		"basenodes:stone",   -- devtest
		"mcl_core:stone",    -- MineClone2
		"mapgen_stone",      -- engine alias
	}
	for _, name in ipairs(candidates) do
		if core.registered_nodes[name] then
			return name
		end
	end
	-- Last resort: find any registered stone-ish node
	for name, def in pairs(core.registered_nodes) do
		if def.groups and def.groups.stone then
			return name
		end
	end
	return "basenodes:stone" -- ultimate fallback (may be unknown)
end

-- Cache the fallback at startup (after mods loaded)
M.fallback_material = nil

-- Convert micronode coordinates to world position offset
-- mx, my, mz: 1..16
function M.micronode_to_offset(mx, my, mz)
	-- Each micronode is 1/16 of a block
	-- Offset from block origin (0,0,0) to (15/16, 15/16, 15/16)
	return (mx - 1) / M.RESOLUTION, (my - 1) / M.RESOLUTION, (mz - 1) / M.RESOLUTION
end

-- Convert world position within block to micronode coordinates
-- ox, oy, oz: 0..1 (fractional position within block)
function M.offset_to_micronode(ox, oy, oz)
	local mx = math.floor(ox * M.RESOLUTION) + 1
	local my = math.floor(oy * M.RESOLUTION) + 1
	local mz = math.floor(oz * M.RESOLUTION) + 1
	return math.max(1, math.min(M.RESOLUTION, mx)),
	       math.max(1, math.min(M.RESOLUTION, my)),
	       math.max(1, math.min(M.RESOLUTION, mz))
end

print("[micronode_chisel] Data structures loaded")
