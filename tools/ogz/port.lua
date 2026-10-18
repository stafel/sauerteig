-- Voxelize Sauerbraten octree leaves into a Luanti node grid.
--
-- This is the M1 converter: geometry only (see
-- docs/sauerbraten-port-plan.md). The output is a dense byte grid of palette
-- indices plus a small palette of Luanti node names, serialized to a compact
-- binary payload so it can cross the Lua sandbox boundary between two worlds
-- (see "Why a payload" below).
--
-- WHY A PAYLOAD: the mod sandbox only allows reading under the world, mod, game
-- and mod_data paths. The .ogz lives in the engine clone, and the target world
-- lives in the user's worlds directory, so one process cannot do both. The
-- export step therefore writes a payload into `mod_data` (read/write allowed
-- from any world) and the import step reads it from there.
--
-- COORDINATES: Sauerbraten is Z-up with `0 <= v < worldsize`; Luanti is Y-up.
-- The mapping is
--     luanti.x = sauer.x
--     luanti.y = sauer.z
--     luanti.z = -sauer.y
-- The negation is not cosmetic: swapping two axes mirrors the world, and
-- `-y` is what keeps both systems right-handed *and* preserves the conventional
-- "north is -z" in Luanti (sauer x=east, y=north, z=up; luanti x=east,
-- y=up, z=south). A mirrored port would still pass every byte-accounting test,
-- which is exactly why this is written down.

local M = {}

M.PAYLOAD_MAGIC = "OGZP"
M.PAYLOAD_VERSION = 1

--- Coordinates --------------------------------------------------------------

function M.to_luanti(x, y, z)
	return x, z, -y
end

--- Region selection ---------------------------------------------------------

-- Density of solid geometry per coarse cell, as a 3D prefix-sum table so any
-- window sum is O(1). Only solid leaves contribute: empty space is the thing we
-- are looking for (rooms), not what we want to maximize.
local function occupancy_index(map, quant)
	local n = math.max(1, math.ceil(map.worldsize / quant))
	local stride_y = n + 1
	local stride_z = (n + 1) * (n + 1)
	local acc = {}

	for _, leaf in ipairs(map.leaves) do
		if not leaf.is_empty() then
			local x0 = math.floor(leaf.x / quant); local x1 = math.floor((leaf.x + leaf.size - 1) / quant)
			local y0 = math.floor(leaf.y / quant); local y1 = math.floor((leaf.y + leaf.size - 1) / quant)
			local z0 = math.floor(leaf.z / quant); local z1 = math.floor((leaf.z + leaf.size - 1) / quant)
			for z = z0, z1 do
				for y = y0, y1 do
					local base = 1 + y * stride_y + z * stride_z
					for x = x0, x1 do
						acc[base + x] = (acc[base + x] or 0) + 1
					end
				end
			end
		end
	end

	-- 3D prefix sums, in place.
	for z = 0, n - 1 do
		for y = 0, n - 1 do
			local base = 1 + y * stride_y + z * stride_z
			for x = 0, n - 1 do
				local v = acc[base + x] or 0
				if x > 0 then v = v + (acc[base + x - 1] or 0) end
				if y > 0 then v = v + (acc[base - stride_y + x] or 0) end
				if z > 0 then v = v + (acc[base - stride_z + x] or 0) end
				if x > 0 and y > 0 then
					v = v - (acc[base - stride_y + x - 1] or 0)
				end
				if x > 0 and z > 0 then
					v = v - (acc[base - stride_z + x - 1] or 0)
				end
				if y > 0 and z > 0 then
					v = v - (acc[base - stride_z - stride_y + x] or 0)
				end
				if x > 0 and y > 0 and z > 0 then
					v = v + (acc[base - stride_z - stride_y + x - 1] or 0)
				end
				acc[base + x] = v
			end
		end
	end

	local function sum(x0, y0, z0, w)
		-- Inclusive-exclusive box sum over [x0, x0+w) etc.
		local function at(x, y, z)
			if x < 0 or y < 0 or z < 0 then return 0 end
			if x >= n or y >= n or z >= n then
				x = math.min(x, n - 1)
				y = math.min(y, n - 1)
				z = math.min(z, n - 1)
			end
			return acc[1 + y * stride_y + z * stride_z + x] or 0
		end
		return at(x0 + w - 1, y0 + w - 1, z0 + w - 1)
			- at(x0 - 1, y0 + w - 1, z0 + w - 1)
			- at(x0 + w - 1, y0 - 1, z0 + w - 1)
			- at(x0 + w - 1, y0 + w - 1, z0 - 1)
			+ at(x0 - 1, y0 - 1, z0 + w - 1)
			+ at(x0 - 1, y0 + w - 1, z0 - 1)
			+ at(x0 + w - 1, y0 - 1, z0 - 1)
			- at(x0 - 1, y0 - 1, z0 - 1)
	end

	return sum, n
end

-- Find the region with the most *interesting* geometry: high solid count but
-- still mostly open, so the result shows rooms and structures rather than the
-- inside of a mountain or an empty sky.
--
-- Returns a region and a report. Deterministic: ties break towards the lowest
-- coordinates.
function M.find_dense_region(map, size, opts)
	opts = opts or {}
	local min_density = opts.min_density or 0.06
	local max_density = opts.max_density or 0.55
	local quant = math.max(1, math.floor(size / 16))
	local sum, n = occupancy_index(map, quant)
	local w = math.max(1, math.floor(size / quant))
	local total = w * w * w

	local best, best_score, best_solid = nil, -1, 0
	local fallback, fallback_solid = nil, -1
	-- Keep the strongest windows as candidates: density alone cannot tell a
	-- monolith from architecture, so the caller ranks these by material
	-- diversity before deciding. Candidates are stored in WORLD coordinates
	-- (the loop indexes coarse cells, and mixing the two spaces silently points
	-- at empty parts of the map).
	local candidates, wanted = {}, opts.candidates or 16
	local function clamp(v)
		return math.max(0, math.min(map.worldsize - size, v * quant))
	end
	local function world_box(cell)
		local x0, y0, z0 = clamp(cell.x), clamp(cell.y), clamp(cell.z)
		return {
			x0 = x0, y0 = y0, z0 = z0,
			x1 = math.min(map.worldsize, x0 + size),
			y1 = math.min(map.worldsize, y0 + size),
			z1 = math.min(map.worldsize, z0 + size),
		}
	end

	for z = 0, n - w do
		for y = 0, n - w do
			for x = 0, n - w do
				local solid = sum(x, y, z, w)
				if solid > fallback_solid then
					fallback_solid = solid
					fallback = {x = x, y = y, z = z}
				end
				local density = solid / total
				if density >= min_density and density <= max_density
					and solid > best_solid then
					best, best_solid = {x = x, y = y, z = z}, solid
					best_score = density
				end
				if solid > 0 then
					local box = world_box({x = x, y = y, z = z})
					box.solid, box.density = solid, density
					candidates[#candidates + 1] = box
				end
			end
		end
	end
	table.sort(candidates, function(a, b) return a.solid > b.solid end)
	while #candidates > wanted do candidates[#candidates] = nil end

	local picked, picked_solid, picked_density = best, best_solid, best_score
	if not picked then
		picked, picked_solid, picked_density = fallback, fallback_solid,
			fallback_solid / total
	end
	if not picked then
		return nil, "empty world"
	end

	return world_box(picked), nil, {
		solid = picked_solid, density = picked_density,
		quant = quant, total = total,
	}, candidates
end

-- How many distinct texture slots the solid leaves in a region reference.
-- A high count means real architecture (floors, walls, trim) rather than a
-- monolith poured from one texture, which is what makes a ported region
-- recognisable. O(leaves), so it is cheap enough to rank a few candidates.
function M.slot_diversity(map, region)
	local seen, count = {}, 0
	for _, leaf in ipairs(map.leaves) do
		if not leaf.is_empty()
			and leaf.x < region.x1 and leaf.x + leaf.size > region.x0
			and leaf.y < region.y1 and leaf.y + leaf.size > region.y0
			and leaf.z < region.z1 and leaf.z + leaf.size > region.z0 then
			for i = 1, 6 do
				local slot = leaf.texture[i]
				if slot and slot > 0 and not seen[slot] then
					seen[slot] = true
					count = count + 1
				end
			end
		end
	end
	return count
end

-- Pick a region around a playerstart, clamped to the world.
-- `size` is the edge length in cubes. Returns a half-open region in sauer cube
-- coordinates.
function M.region_around_playerstart(map, size, opts)
	opts = opts or {}
	local anchor
	for _, entity in ipairs(map.entities) do
		if entity.type == 3 then                 -- ET_PLAYERSTART
			anchor = entity
			if not opts.skip_first then break end
			-- keep scanning: take the last one if skip_first is set
		end
	end
	if not anchor then
		return nil, "map has no playerstart"
	end

	local half = math.floor(size / 2)
	local ws = map.worldsize
	local function clamp_axis(v)
		local lo = math.floor(v) - half
		lo = math.max(0, math.min(ws - size, lo))
		return lo, lo + size
	end
	local x0, x1 = clamp_axis(anchor.x)
	local y0, y1 = clamp_axis(anchor.y)
	-- Sauerbraten's z is vertical; keep the anchor inside rather than centring
	-- so we always capture floor below the spawn.
	local z0 = math.max(0, math.min(ws - size, math.floor(anchor.z) - math.floor(size / 4)))
	local z1 = z0 + size
	return {x0 = x0, y0 = y0, z0 = z0, x1 = x1, y1 = y1, z1 = z1}, nil, anchor
end

-- Choose a spawn inside `region` that stands on something.
--
-- The centre column is often empty (courtyards, halls), so this takes the solid
-- cell nearest the region centre and spawns two cells above it. O(cells), one
-- pass, no allocation.
-- Returns sauer x, y, z.
function M.pick_spawn(region, size, grid)
	local sx, sy, sz = size.x, size.y, size.z
	local ci, cj, ck = sx / 2, sy / 2, sz / 2
	local best, best_dist
	for k = 0, sz - 1 do
		local dz = k + 0.5 - ck
		for j = 0, sy - 1 do
			local dy = j + 0.5 - cj
			local base = (k * sy + j) * sx
			for i = 0, sx - 1 do
				if (grid[base + i + 1] or 0) ~= 0 then
					local dx = i + 0.5 - ci
					local dist = dx * dx + dy * dy + dz * dz
					if not best_dist or dist < best_dist then
						best_dist = dist
						best = {i, j, k}
					end
				end
			end
		end
	end
	if not best then
		-- Nothing solid at all: start at the top centre and let them fall.
		return region.x0 + math.floor(sx / 2), region.y0 + math.floor(sy / 2),
			region.z0 + sz - 2
	end
	local i, j, k = best[1], best[2], best[3]
	return region.x0 + i, region.y0 + j, region.z0 + math.min(k + 2, sz - 1)
end

--- Rasterization ------------------------------------------------------------

-- Corner sets of the 6 faces, in corner-bit space (octa.cpp GENFACEVERTS,
-- evaluated at 0/1). Faces are 0=-X 1=+X 2=-Y 3=+Y 4=-Z 5=+Z.
local FACE_CORNERS = {
	{ {0, 1, 1}, {0, 1, 0}, {0, 0, 0}, {0, 0, 1} },
	{ {1, 1, 1}, {1, 0, 1}, {1, 0, 0}, {1, 1, 0} },
	{ {1, 0, 1}, {0, 0, 1}, {0, 0, 0}, {1, 0, 0} },
	{ {0, 1, 0}, {0, 1, 1}, {1, 1, 1}, {1, 1, 0} },
	{ {0, 0, 0}, {0, 1, 0}, {1, 1, 0}, {1, 0, 0} },
	{ {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1} },
}

-- Is the leaf an axis-aligned box, and if so what are its 0..8 bounds per axis?
-- Returns minx, miny, minz, maxx, maxy, maxz or nil.
local function leaf_box_bounds(leaf)
	local minv, maxv = {9, 9, 9}, {-1, -1, -1}
	for cx = 0, 1 do
		for cy = 0, 1 do
			for cz = 0, 1 do
				local vx, vy, vz = leaf.corner(cx, cy, cz)
				local v = {vx, vy, vz}
				for axis = 1, 3 do
					if v[axis] < minv[axis] then minv[axis] = v[axis] end
					if v[axis] > maxv[axis] then maxv[axis] = v[axis] end
				end
			end
		end
	end
	-- Every corner must sit exactly on the bounding box, otherwise the leaf has
	-- at least one dragged corner and needs the half-space test.
	for cx = 0, 1 do
		for cy = 0, 1 do
			for cz = 0, 1 do
				local vx, vy, vz = leaf.corner(cx, cy, cz)
				if (vx ~= minv[1] and vx ~= maxv[1])
					or (vy ~= minv[2] and vy ~= maxv[2])
					or (vz ~= minv[3] and vz ~= maxv[3]) then
					return nil
				end
			end
		end
	end
	return minv[1], minv[2], minv[3], maxv[1], maxv[2], maxv[3]
end
M.leaf_box_bounds = leaf_box_bounds

-- Plane through three points, as (nx, ny, nz, d) with n.x = d.
local function plane_from(p1, p2, p3)
	local ax, ay, az = p2[1] - p1[1], p2[2] - p1[2], p2[3] - p1[3]
	local bx, by, bz = p3[1] - p1[1], p3[2] - p1[2], p3[3] - p1[3]
	local nx = ay * bz - az * by
	local ny = az * bx - ax * bz
	local nz = ax * by - ay * bx
	local d = nx * p1[1] + ny * p1[2] + nz * p1[3]
	return nx, ny, nz, d
end

-- Build the 6 inward-facing planes of a (convex) leaf, in leaf-local 0..size
-- units. Returns nil when the leaf is degenerate.
local function leaf_planes(leaf, size)
	local corners = {}
	for cx = 0, 1 do
		for cy = 0, 1 do
			for cz = 0, 1 do
				local vx, vy, vz = leaf.corner(cx, cy, cz)
				corners[cx * 4 + cy * 2 + cz] = {
					vx * size / 8, vy * size / 8, vz * size / 8,
				}
			end
		end
	end
	-- Leaf centre, used to orient each plane inwards.
	local cx, cy, cz = 0, 0, 0
	for i = 0, 7 do
		cx = cx + corners[i][1] / 8
		cy = cy + corners[i][2] / 8
		cz = cz + corners[i][3] / 8
	end

	local planes = {}
	for face, spec in ipairs(FACE_CORNERS) do
		local p1 = corners[spec[1][1] * 4 + spec[1][2] * 2 + spec[1][3]]
		local p2 = corners[spec[2][1] * 4 + spec[2][2] * 2 + spec[2][3]]
		local p3 = corners[spec[3][1] * 4 + spec[3][2] * 2 + spec[3][3]]
		local nx, ny, nz, d = plane_from(p1, p2, p3)
		local len = math.sqrt(nx * nx + ny * ny + nz * nz)
		if len < 1e-9 then
			return nil
		end
		nx, ny, nz, d = nx / len, ny / len, nz / len, d / len
		-- Flip so that the leaf centre is on the negative side.
		if nx * cx + ny * cy + nz * cz - d > 0 then
			nx, ny, nz, d = -nx, -ny, -nz, -d
		end
		planes[face] = {nx, ny, nz, d}
	end
	return planes
end

-- Pick the material for a solid leaf: the most common non-zero texture slot.
-- Merged faces can carry several slots; the majority one is the best single
-- answer when the target format has one material per node.
local function leaf_material_slot(leaf)
	local counts, best, best_count = {}, nil, 0
	for i = 1, 6 do
		local slot = leaf.texture[i]
		if slot and slot > 0 then
			counts[slot] = (counts[slot] or 0) + 1
			if counts[slot] > best_count then
				best, best_count = slot, counts[slot]
			end
		end
	end
	return best
end

-- Voxelize into `out`, a dense byte grid over `region`.
-- Returns stats {cells, solid, liquid, shaped, boxes}.
--
-- `resolve_slot(slot)` maps a texture slot to a palette index (1..n). Index 0 is
-- reserved for air.
function M.voxelize(map, region, resolve_slot, opts)
	opts = opts or {}
	local sx = region.x1 - region.x0
	local sy = region.y1 - region.y0
	local sz = region.z1 - region.z0
	local out = {}
	for i = 1, sx * sy * sz do out[i] = 0 end

	local stats = {cells = sx * sy * sz, solid = 0, liquid = 0, shaped = 0,
		boxes = 0, skipped_air = 0}

	local function index(lx, ly, lz)
		return (lz * sy + ly) * sx + lx + 1
	end

	local function fill(x0, y0, z0, x1, y1, z1, value)
		x0 = math.max(x0, region.x0); x1 = math.min(x1, region.x1)
		y0 = math.max(y0, region.y0); y1 = math.min(y1, region.y1)
		z0 = math.max(z0, region.z0); z1 = math.min(z1, region.z1)
		if x0 >= x1 or y0 >= y1 or z0 >= z1 then return end
		for z = z0, z1 - 1 do
			for y = y0, y1 - 1 do
				local base = index(x0 - region.x0, y - region.y0, z - region.z0)
				for x = 0, x1 - x0 - 1 do
					out[base + x] = value
				end
			end
		end
	end

	for _, leaf in ipairs(map.leaves) do
		if not (leaf.x < region.x1 and leaf.x + leaf.size > region.x0
			and leaf.y < region.y1 and leaf.y + leaf.size > region.y0
			and leaf.z < region.z1 and leaf.z + leaf.size > region.z0) then
			-- Outside the region.
		elseif leaf.is_empty() then
			-- Interior air. Liquids live here: a Sauerbraten "water cube" is
			-- empty space with a liquid material, not a texture.
			local kind = M.material_kind_of(leaf.material)
			if kind then
				local slot = opts.water_slot
				local value = resolve_slot(kind == "lava" and "lava" or "water")
				if value and value > 0 then
					fill(leaf.x, leaf.y, leaf.z, leaf.x + leaf.size,
						leaf.y + leaf.size, leaf.z + leaf.size, value)
					stats.liquid = stats.liquid + 1
				end
			else
				stats.skipped_air = stats.skipped_air + 1
			end
		else
			local value = resolve_slot(leaf_material_slot(leaf))
			if value and value > 0 then
				local bx0, by0, bz0, bx1, by1, bz1 = leaf_box_bounds(leaf)
				local unit = leaf.size / 8
				if bx0 then
					fill(leaf.x + bx0 * unit, leaf.y + by0 * unit,
						leaf.z + bz0 * unit, leaf.x + bx1 * unit,
						leaf.y + by1 * unit, leaf.z + bz1 * unit, value)
					stats.boxes = stats.boxes + 1
					stats.solid = stats.solid + 1
				else
					-- Dragged corner: test each cell centre against the 6
					-- inward planes. Conservative on ties (a cell whose centre
					-- is within EPS of a plane counts as solid) so the result
					-- stays watertight rather than developing pinholes.
					local planes = leaf_planes(leaf, leaf.size)
					stats.shaped = stats.shaped + 1
					if planes then
						local eps = 1e-6
						local lx0 = math.max(leaf.x, region.x0)
						local ly0 = math.max(leaf.y, region.y0)
						local lz0 = math.max(leaf.z, region.z0)
						local lx1 = math.min(leaf.x + leaf.size, region.x1)
						local ly1 = math.min(leaf.y + leaf.size, region.y1)
						local lz1 = math.min(leaf.z + leaf.size, region.z1)
						for z = lz0, lz1 - 1 do
							local pz = z - leaf.z + 0.5
							for y = ly0, ly1 - 1 do
								local py = y - leaf.y + 0.5
								local base = index(lx0 - region.x0, y - region.y0,
									z - region.z0)
								for x = lx0, lx1 - 1 do
									local px = x - leaf.x + 0.5
									local inside = true
									for f = 1, 6 do
										local p = planes[f]
										if p[1] * px + p[2] * py + p[3] * pz
											- p[4] > eps then
											inside = false
											break
										end
									end
									if inside then
										out[base + (x - lx0)] = value
									end
								end
							end
						end
					end
				end
			end
		end
	end

	return out, stats
end

-- Material bitfield -> "water" / "lava" / nil. Kept here so port.lua does not
-- depend on ogz.lua for this one decision.
function M.material_kind_of(material)
	local volume = math.floor(material / 4) % 8
	if volume == 1 then return "water" end
	if volume == 2 then return "lava" end
	if volume == 3 then return "water" end   -- glass behaves like a solid block
	return nil
end

--- Payload ------------------------------------------------------------------

local function u8(v) return string.char(v % 256) end

local function u16(v)
	return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
	return string.char(v % 256, math.floor(v / 256) % 256,
		math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function i32(v)
	if v < 0 then v = v + 0x100000000 end
	return u32(v)
end

-- One shared char string per byte value, so `bytes_of` allocates nothing per
-- cell beyond the table slot itself.
local BYTE_CHAR = {}
for i = 0, 255 do BYTE_CHAR[i] = string.char(i) end

local function bytes_of(grid)
	local chars = {}
	local n = #grid
	for i = 1, n do
		chars[i] = BYTE_CHAR[grid[i] or 0] or "\0"
	end
	return chars
end

-- Serialize a payload. `grid` is the dense byte grid, `names` the palette of
-- Luanti node names (index 1..n, index 0 is air), `meta` extra key/values.
function M.encode(grid, names, region, meta)
	local parts = {
		M.PAYLOAD_MAGIC, u8(M.PAYLOAD_VERSION), u8(0),
		i32(region.x0), i32(region.y0), i32(region.z0),
		i32(region.x1 - region.x0), i32(region.y1 - region.y0),
		i32(region.z1 - region.z0),
		u16(#names),
	}
	for _, name in ipairs(names) do
		parts[#parts + 1] = u16(#name) .. name
	end
	for key, value in pairs(meta or {}) do
		local text = tostring(value)
		parts[#parts + 1] = u16(#key) .. key .. u16(#text) .. text
	end
	parts[#parts + 1] = u16(0)              -- end of meta

	-- Grid as one byte per cell. `table.concat` on a table of numbers would
	-- write their DECIMAL TEXT ("26" for a 26), so every value has to go through
	-- string.char. Sharing one char string per byte value keeps this to a single
	-- pass with no per-cell allocation of its own.
	parts[#parts + 1] = table.concat(bytes_of(grid))
	return table.concat(parts)
end

-- Read a u16 at `pos`; returns value, next_pos.
local function read_u16(data, pos)
	local a, b = data:byte(pos, pos + 1)
	if not b then error("[ogz] payload truncated", 0) end
	return a + b * 256, pos + 2
end

local function read_i32(data, pos)
	local a, b, c, d = data:byte(pos, pos + 3)
	if not d then error("[ogz] payload truncated", 0) end
	local v = a + b * 256 + c * 65536 + d * 16777216
	if v >= 0x80000000 then v = v - 0x100000000 end
	return v, pos + 4
end

-- Deserialize a payload into {region, size, names, meta, grid}.
function M.decode(data)
	if data:sub(1, 4) ~= M.PAYLOAD_MAGIC then
		error("[ogz] not an ogz payload", 0)
	end
	local version = data:byte(5)
	if version ~= M.PAYLOAD_VERSION then
		error(("[ogz] payload version %d, expected %d")
			:format(version, M.PAYLOAD_VERSION), 0)
	end
	local pos = 7
	local region = {}
	region.x0, pos = read_i32(data, pos)
	region.y0, pos = read_i32(data, pos)
	region.z0, pos = read_i32(data, pos)
	local sx, sy, sz
	sx, pos = read_i32(data, pos)
	sy, pos = read_i32(data, pos)
	sz, pos = read_i32(data, pos)
	region.x1, region.y1, region.z1 =
		region.x0 + sx, region.y0 + sy, region.z0 + sz

	local count
	count, pos = read_u16(data, pos)
	local names = {}
	for i = 1, count do
		local len
		len, pos = read_u16(data, pos)
		names[i] = data:sub(pos, pos + len - 1)
		pos = pos + len
	end

	local meta = {}
	while true do
		local klen
		klen, pos = read_u16(data, pos)
		if klen == 0 then break end
		local key = data:sub(pos, pos + klen - 1)
		pos = pos + klen
		local vlen
		vlen, pos = read_u16(data, pos)
		meta[key] = data:sub(pos, pos + vlen - 1)
		pos = pos + vlen
	end

	local cells = sx * sy * sz
	local grid = {}
	for i = 1, cells do
		grid[i] = data:byte(pos + i - 1) or 0
	end

	return {
		region = region,
		size = {x = sx, y = sy, z = sz},
		names = names,
		meta = meta,
		grid = grid,
	}
end

--- Preview ------------------------------------------------------------------

-- ASCII slices of the voxelized grid, stacked along the vertical (Sauerbraten
-- z) axis. The grid keeps Sauerbraten axis order - index = (z*sy + y)*sx + x -
-- so a slice is one z layer, rows advance along y and columns along x.
-- Empty cells print '.', water '~', lava '*', everything else by palette digit.
function M.preview(payload, slices, max_cells)
	slices = slices or 3
	max_cells = max_cells or 64
	local size = payload.size
	local stride = math.max(1,
		math.floor(math.max(size.x, size.y) / max_cells))
	local names = payload.names
	local symbol = {[0] = "."}
	for i = 1, #names do
		local name = names[i]
		if name:find("water") then
			symbol[i] = "~"
		elseif name:find("lava") then
			symbol[i] = "*"
		else
			local index = ((i - 1) % 36) + 1
			symbol[i] = ("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
				:sub(index, index)
		end
	end

	local out = {}
	local step = math.max(1, math.floor(size.z / slices))
	for z = 0, size.z - 1, step do
		out[#out + 1] = ("--- sauer z = +%d (luanti y = %d) ---")
			:format(z, z)
		for y = 0, size.y - 1, stride do
			local row = {}
			for x = 0, size.x - 1, stride do
				row[#row + 1] = symbol[payload.grid[(z * size.y + y) * size.x + x + 1]]
					or "?"
			end
			out[#out + 1] = table.concat(row)
		end
	end
	return out
end

print("[ogz] port module loaded")
return M
