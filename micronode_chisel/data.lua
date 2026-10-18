-- Micronode data model and storage for micronode_chisel.
--
-- One node holds a RESOLUTION^3 grid of micronodes (16^3 = 4096 cells, i.e.
-- 6.25 cm at the default 1 m node size) plus a palette of at most
-- MAX_MATERIALS node names. A cell value of 0 means air, 1..MAX_MATERIALS
-- indexes into the palette.
--
-- Storage lives in node metadata as a single string per block:
--   "\1" + RLE runs of [count_lo][count_hi][material]   (preferred)
--   "\2" + one byte per cell                            (used when RLE is
--                                                       larger, e.g. a
--                                                       checkerboard carve)
--
-- Why a raw escape hatch: RLE costs 3 bytes per run, so a maximally noisy
-- 16^3 pattern is 3x *larger* than one byte per cell. Choosing the smaller
-- encoding keeps the worst case bounded at 1 byte/cell.
--
-- Persistence rules and rendering contracts are documented in
-- docs/micronode-findings.md.

micronode_chisel = micronode_chisel or {}
local M = micronode_chisel

-- Constants
M.RESOLUTION = 16
M.VOXEL_COUNT = M.RESOLUTION * M.RESOLUTION * M.RESOLUTION
M.MAX_MATERIALS = 4
M.AIR = "air"

-- Container node names. Kept here (not in chisel.lua) so the data/edit layers
-- can classify nodes without depending on registration order.
M.BLOCK_NODE = "micronode_chisel:chiseled_block"
M.BLOCK_NODE_OPEN = "micronode_chisel:chiseled_block_open"

-- Node metadata keys. These are a new, version-tagged format: the previous
-- (broken) implementation stored unversioned RLE under "mn_data" and is
-- deliberately not migrated.
M.META_KEY_DATA = "mn_grid"
M.META_KEY_PALETTE = "mn_palette"
M.META_KEY_BASE = "mn_base"

-- Edit grid steps, in micronodes. Cycle order matches requirement E1
-- (1 -> 2 -> 4 -> 8 -> 16 -> 1).
M.GRID_SIZES = {1, 2, 4, 8, 16}
M.GRID_NAMES = {"1/16", "1/8", "1/4", "1/2", "1/1"}

local R = M.RESOLUTION

local function is_air_name(name)
	return name == nil or name == "" or name == M.AIR
end
M.is_air_name = is_air_name

-------------------------------------------------------------------------------
-- Grid access
-------------------------------------------------------------------------------
-- Layout is x-major: index = (z-1)*res*res + (y-1)*res + x, all 1-based.
-- Any function that may see a coarsened grid takes an explicit `res`; the
-- default is the full resolution. Never rely on the 16^3 stride implicitly.

function M.index(x, y, z, res)
	res = res or R
	return (z - 1) * res * res + (y - 1) * res + x
end

function M.in_bounds(x, y, z, res)
	res = res or R
	return x >= 1 and x <= res and y >= 1 and y <= res and z >= 1 and z <= res
end

function M.get_voxel(grid, x, y, z, res)
	if not M.in_bounds(x, y, z, res) then
		return 0
	end
	return grid[M.index(x, y, z, res)] or 0
end

function M.set_voxel(grid, x, y, z, value, res)
	if not M.in_bounds(x, y, z, res) then
		return false
	end
	grid[M.index(x, y, z, res)] = value or 0
	return true
end

function M.create_empty_grid(res)
	res = res or R
	local grid = {}
	for i = 1, res * res * res do
		grid[i] = 0
	end
	return grid
end

function M.create_filled_grid(material_idx, res)
	res = res or R
	local value = material_idx or 1
	local grid = {}
	for i = 1, res * res * res do
		grid[i] = value
	end
	return grid
end

-- Fill an inclusive box. Coordinates outside the grid are clipped, so callers
-- may pass brush extents that hang over a block boundary.
function M.fill_box(grid, x1, y1, z1, x2, y2, z2, material_idx, res)
	res = res or R
	x1, x2 = math.max(1, math.min(x1, x2)), math.min(res, math.max(x1, x2))
	y1, y2 = math.max(1, math.min(y1, y2)), math.min(res, math.max(y1, y2))
	z1, z2 = math.max(1, math.min(z1, z2)), math.min(res, math.max(z1, z2))
	local value = material_idx or 0
	local changed = 0
	for z = z1, z2 do
		for y = y1, y2 do
			local base = (z - 1) * res * res + (y - 1) * res
			for x = x1, x2 do
				grid[base + x] = value
				changed = changed + 1
			end
		end
	end
	return changed
end

-- Count of non-air cells. Nil-safe: coarsened grids may be shorter than the
-- full resolution and a nil cell means air.
function M.count_solid(grid)
	local count = 0
	for i = 1, #grid do
		local v = grid[i]
		if v and v ~= 0 then
			count = count + 1
		end
	end
	return count
end

function M.is_empty(grid)
	return M.count_solid(grid) == 0
end

function M.is_full(grid)
	local n = #grid
	return n > 0 and M.count_solid(grid) == n
end

-------------------------------------------------------------------------------
-- Serialization (RLE with a raw fallback)
-------------------------------------------------------------------------------

local TAG_RLE = "\1"
local TAG_RAW = "\2"

function M.compress_grid(grid)
	local n = #grid

	-- RLE: runs longer than 65535 are split (the format stores u16 counts)
	local runs = {}
	local i = 1
	while i <= n do
		local value = grid[i] or 0
		local run = 1
		while i + run <= n and (grid[i + run] or 0) == value and run < 65535 do
			run = run + 1
		end
		runs[#runs + 1] = string.char(run % 256, math.floor(run / 256), math.floor(value))
		i = i + run
	end
	local rle = TAG_RLE .. table.concat(runs)

	-- Raw: one byte per cell
	local bytes = {}
	for k = 1, n do
		bytes[k] = string.char(math.floor(grid[k] or 0))
	end
	local raw = TAG_RAW .. table.concat(bytes)

	if #rle <= #raw then
		return rle
	end
	return raw
end

function M.decompress_grid(data)
	local grid = {}
	if type(data) ~= "string" or data == "" then
		return M.create_empty_grid()
	end

	local tag = data:sub(1, 1)
	if tag == TAG_RAW then
		local n = #data - 1
		for k = 1, n do
			grid[k] = data:byte(k + 1) or 0
		end
	else
		local start = (tag == TAG_RLE) and 2 or 1
		local pos = start
		local idx = 1
		while pos <= #data do
			local lo = data:byte(pos) or 0
			local hi = data:byte(pos + 1) or 0
			local value = data:byte(pos + 2) or 0
			local run = lo + hi * 256
			if run <= 0 then
				break
			end
			for _ = 1, run do
				grid[idx] = value
				idx = idx + 1
			end
			pos = pos + 3
		end
	end

	-- Normalize to the full resolution (padding and truncating)
	for i = 1, M.VOXEL_COUNT do
		if grid[i] == nil then
			grid[i] = 0
		end
	end
	for i = M.VOXEL_COUNT + 1, #grid do
		grid[i] = nil
	end
	return grid
end

function M.get_compression_ratio(grid)
	local stored = M.compress_grid(grid)
	local original = #grid
	if #stored == 0 then
		return 0, 0
	end
	return original / #stored, #stored
end

-------------------------------------------------------------------------------
-- Material palette
-------------------------------------------------------------------------------
-- Palette slots hold node names; empty slots hold M.AIR. Air is never a
-- palette entry: grid value 0 already means air.

function M.create_palette(materials)
	local palette = {}
	for i = 1, M.MAX_MATERIALS do
		local name = materials and materials[i]
		palette[i] = is_air_name(name) and M.AIR or name
	end
	return palette
end

-- Returns the palette index for `node_name`, allocating a free slot when
-- needed, or nil when the palette is full (only MAX_MATERIALS distinct
-- materials may be referenced by one block).
function M.palette_add(palette, node_name)
	if is_air_name(node_name) then
		return 0
	end
	for i = 1, M.MAX_MATERIALS do
		if palette[i] == node_name then
			return i
		end
	end
	for i = 1, M.MAX_MATERIALS do
		if is_air_name(palette[i]) then
			palette[i] = node_name
			return i
		end
	end
	return nil
end

function M.palette_get(palette, idx)
	if not idx or idx <= 0 then
		return M.AIR
	end
	local name = palette and palette[idx]
	return is_air_name(name) and M.AIR or name
end

-- True when `node_name` can be stored in this palette without dropping
-- something else (already present, or a free slot exists).
function M.palette_has(palette, node_name)
	if is_air_name(node_name) then
		return true
	end
	for i = 1, M.MAX_MATERIALS do
		if palette[i] == node_name or is_air_name(palette[i]) then
			return true
		end
	end
	return false
end

function M.palette_serialize(palette)
	local out = {}
	for i = 1, M.MAX_MATERIALS do
		out[i] = M.palette_get(palette, i)
	end
	return table.concat(out, ",")
end

function M.palette_deserialize(str)
	local palette = {}
	if type(str) == "string" and str ~= "" then
		for name in string.gmatch(str, "[^,]+") do
			palette[#palette + 1] = name
		end
	end
	for i = #palette + 1, M.MAX_MATERIALS do
		palette[i] = M.AIR
	end
	return palette
end

-- Drop unreferenced palette entries and renumber the grid accordingly.
-- Without this, carving a material away keeps its slot occupied forever and
-- the 4-slot palette fills up with dead entries.
function M.palette_compact(grid, palette)
	local used = {}
	for i = 1, #grid do
		local v = grid[i]
		if v and v > 0 then
			used[v] = true
		end
	end

	local order = {}
	for idx = 1, M.MAX_MATERIALS do
		if used[idx] then
			order[#order + 1] = idx
		end
	end

	local remap = {}
	local out = {}
	for new_idx, old_idx in ipairs(order) do
		remap[old_idx] = new_idx
		out[new_idx] = M.palette_get(palette, old_idx)
	end
	for i = #out + 1, M.MAX_MATERIALS do
		out[i] = M.AIR
	end

	for i = 1, #grid do
		local v = grid[i]
		if v and v > 0 then
			grid[i] = remap[v] or 0
		else
			grid[i] = 0
		end
	end

	return out
end

-------------------------------------------------------------------------------
-- Block data
-------------------------------------------------------------------------------

function M.create_block_data(base_material, palette, grid)
	return {
		base = is_air_name(base_material) and M.AIR or base_material,
		palette = palette or M.create_palette(nil),
		grid = grid or M.create_empty_grid(),
	}
end

function M.serialize_block_data(block_data)
	return {
		data = M.compress_grid(block_data.grid),
		palette = M.palette_serialize(block_data.palette),
		base = block_data.base or M.AIR,
	}
end

function M.deserialize_block_data(strings)
	return M.create_block_data(
		strings.base,
		M.palette_deserialize(strings.palette),
		M.decompress_grid(strings.data)
	)
end

-------------------------------------------------------------------------------
-- Transforms (applied directly to the grid; there is no stored rotation)
-------------------------------------------------------------------------------

-- Rotate 90 degrees clockwise per step, around the Y axis.
function M.rotate_grid(grid, times, res)
	res = res or R
	times = (times or 1) % 4
	if times == 0 then
		return grid
	end
	local out = M.create_empty_grid(res)
	for z = 1, res do
		for y = 1, res do
			for x = 1, res do
				local value = M.get_voxel(grid, x, y, z, res)
				local nx, nz
				if times == 1 then
					nx, nz = z, res - x + 1
				elseif times == 2 then
					nx, nz = res - x + 1, res - z + 1
				else
					nx, nz = res - z + 1, x
				end
				M.set_voxel(out, nx, y, nz, value, res)
			end
		end
	end
	return out
end

-- Mirror along X.
function M.flip_grid(grid, res)
	res = res or R
	local out = M.create_empty_grid(res)
	for z = 1, res do
		for y = 1, res do
			for x = 1, res do
				M.set_voxel(out, res - x + 1, y, z, M.get_voxel(grid, x, y, z, res), res)
			end
		end
	end
	return out
end

-------------------------------------------------------------------------------
-- Render-budget coarsening (emergency path only)
-------------------------------------------------------------------------------
-- Downsample by an integer factor for the render-budget fallback. A coarse
-- cell is solid only when a strict majority of the source cells it covers are
-- solid; ties go to air.
--
-- Majority, NOT "any": with "any", every carved cavity whose walls are thinner
-- than one coarse cell gets filled in, so a heavily chiselled block visibly
-- reverted to a full cube after enough detail accumulated (the "node refills"
-- bug). Strict majority (ties to air) also stops a checkerboard or a thin
-- lattice from collapsing into a solid mass. It can drop features smaller than
-- one coarse cell, but it never invents solid geometry out of a mostly-empty
-- region.
function M.coarsen_grid(grid, step, res)
	res = res or R
	if step <= 1 then
		return grid, res
	end
	local ores = math.ceil(res / step)
	local out = M.create_empty_grid(ores)
	for z = 1, ores do
		for y = 1, ores do
			for x = 1, ores do
				local solid, samples = 0, 0
				for dz = 0, step - 1 do
					local sz = (z - 1) * step + dz + 1
					if sz <= res then
						for dy = 0, step - 1 do
							local sy = (y - 1) * step + dy + 1
							if sy <= res then
								for dx = 0, step - 1 do
									local sx = (x - 1) * step + dx + 1
									if sx <= res then
										samples = samples + 1
										if M.get_voxel(grid, sx, sy, sz, res) > 0 then
											solid = solid + 1
										end
									end
								end
							end
						end
					end
				end
				local value = (samples > 0 and solid * 2 > samples) and 1 or 0
				M.set_voxel(out, x, y, z, value, ores)
			end
		end
	end
	return out, ores
end

-------------------------------------------------------------------------------
-- Materials and textures
-------------------------------------------------------------------------------

-- First existing stone-like node name across common games.
function M.get_fallback_material()
	local candidates = {
		"default:stone",    -- minetest_game
		"basenodes:stone",  -- devtest
		"mcl_core:stone",   -- MineClone2
		"mapgen_stone",     -- engine alias
	}
	for _, name in ipairs(candidates) do
		if core.registered_nodes[name] then
			return name
		end
	end
	for name, def in pairs(core.registered_nodes or {}) do
		if def and def.groups and def.groups.stone then
			return name
		end
	end
	return "basenodes:stone"
end

-- Cache filled in on_mods_loaded (see init.lua); also resolves lazily so the
-- first call from a tool always has a usable value.
function M.fallback_material_or_default()
	return M.fallback_material or M.get_fallback_material()
end

-- Cube faces, in the engine's cube/tile order: +Y, -Y, +X, -X, +Z, -Z.
M.FACE_PY, M.FACE_NY, M.FACE_PX, M.FACE_NX, M.FACE_PZ, M.FACE_NZ = 1, 2, 3, 4, 5, 6

local function tile_name(tile)
	if type(tile) == "string" then
		return tile
	end
	if type(tile) == "table" then
		return tile.name or tile.image
	end
	return nil
end

-- Texture for one cube face of a material, following node `tiles` rules:
-- 1 tile = all faces, 2 = top/bottom plus one side, 3 = top/bottom/side,
-- 6 = per face.
function M.get_tile(material_name, face)
	face = face or M.FACE_PX
	if is_air_name(material_name) then
		return "blank.png"
	end
	local def = core.registered_nodes and core.registered_nodes[material_name]
	local tiles = def and def.tiles
	if not tiles then
		return "default_stone.png"
	end

	local tile = tiles[face]
	if tile == nil then
		if face <= 2 then
			tile = tiles[face]        -- dedicated top / bottom tile
		end
		if tile == nil then
			tile = tiles[3] or tiles[1] -- shared side tile, then any tile
		end
	end
	local name = tile and tile_name(tile)
	return name or "default_stone.png"
end

-- Side texture, kept for API compatibility.
function M.get_texture(material_name)
	return M.get_tile(material_name, M.FACE_PX)
end

print("[micronode_chisel] Data model loaded")
