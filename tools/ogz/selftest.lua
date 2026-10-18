-- Self-test for tools/ogz/ogz.lua.
--
-- Two layers, both runnable with a plain Lua interpreter (CI, lupa) and the
-- first also inside the engine:
--
--   1. SYNTHETIC: hand-built map bytes that exercise the whole parse path -
--      header, vars, game ident, texture MRU, entities, vslots, octree
--      (children/empty/solid/normal + material/merged/surface flags), the
--      lightmap/PVS/blendmap skip, corner decoding and region filtering.
--      No external files, so this is the regression suite.
--   2. REAL MAPS: optional, needs .ogz paths. Only this layer can catch a
--      misreading of the on-disk layout; the synthetic layer proves the code
--      implements *our* understanding of it.
--
-- Returned value: array of failure strings (empty = pass).

local Builder = {}
Builder.__index = Builder

function Builder.new()
	return setmetatable({parts = {}}, Builder)
end

function Builder:raw(s)
	self.parts[#self.parts + 1] = s
	return self
end

function Builder:u8(v)
	self.parts[#self.parts + 1] = string.char(v % 256)
	return self
end

function Builder:u16(v)
	self.parts[#self.parts + 1] = string.char(v % 256, math.floor(v / 256) % 256)
	return self
end

function Builder:i16(v)
	if v < 0 then v = v + 0x10000 end
	return self:u16(v)
end

function Builder:u32(v)
	self.parts[#self.parts + 1] = string.char(
		v % 256, math.floor(v / 256) % 256,
		math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
	return self
end

function Builder:i32(v)
	if v < 0 then v = v + 0x100000000 end
	return self:u32(v)
end

-- Only the float values used by the fixtures: 0.0 and small integers.
function Builder:f32(v)
	if v == 0 then return self:raw(string.rep("\0", 4)) end
	-- 1.0 .. 2.0 range via exponent 127
	local sign, exponent, mantissa = 0, 127, 0
	if v < 0 then
		sign = 1
		v = -v
	end
	while v >= 2 do
		v = v / 2
		exponent = exponent + 1
	end
	while v < 1 do
		v = v * 2
		exponent = exponent - 1
	end
	mantissa = math.floor((v - 1) * 8388608 + 0.5)
	local b3 = math.floor(mantissa / 65536)
	local packed = sign * 0x80000000 + exponent * 0x800000 + mantissa
	return self:u32(packed)
end

function Builder:build()
	return table.concat(self.parts)
end

local function fixture_map()
	-- worldsize 4 -> the root is implied and its 8 octants have size 2.
	local b = Builder.new()
	b:raw("OCTA")
	b:i32(33)                 -- version
	b:i32(40)                 -- headersize
	b:i32(4)                  -- worldsize
	b:i32(2)                  -- numents
	b:i32(0)                  -- numpvs
	b:i32(0)                  -- lightmaps
	b:i32(0)                  -- blendmap
	b:i32(1)                  -- numvars (one ID_VAR we must skip)
	b:i32(1)                  -- numvslots (one default slot)

	-- var: type 0, u16 name length, name, i32 value
	b:u8(0):u16(4):raw("test"):i32(7)

	-- game ident: u8 len, len+1 bytes, then u16 eif + u16 extrasize
	-- (worldio.cpp:1123-1140 reads both, then skips extrasize bytes)
	b:u8(3):raw("fps\0"):u16(0):u16(0)

	-- texture MRU: u16 count + count u16
	b:u16(2):u16(0x15):u16(0x16)

	-- entities: 3 f32 + 5 i16 + u8 type + u8 reserved = 24 bytes each
	b:f32(0):f32(0):f32(0):i16(0):i16(0):i16(0):i16(0):i16(0):u8(1):u8(0)
	b:f32(2):f32(0):f32(0):i16(90):i16(0):i16(0):i16(0):i16(0):u8(3):u8(0)

	-- vslots: one slot with `changed` = SCALE only, then prev index, then the
	-- float scale. (A negative `changed` emits N defaults.)
	b:i32(2 ^ 1)              -- changed = VSLOT_SCALE
	b:i32(-1)                 -- prev
	b:f32(1)                  -- scale

	-- Octree: the 8 root octants, size 2 each.
	--  0: SOLID with a material and a merge flag
	b:u8(2 + 0x40 + 0x80)
	for _ = 1, 6 do b:u16(0x20) end
	b:u16(0x0004)             -- material: MAT_WATER
	b:u8(0)                   -- merged
	--  1: NORMAL, every span 0..4 (a half-size box in the corner)
	b:u8(3)
	b:raw(string.rep(string.char(0x40), 12))
	for _ = 1, 6 do b:u16(0x21) end
	--  2: SOLID with a surface block we must skip exactly. Two faces, so both
	--     skip paths are covered: face 0 consumes xyz and uv up front (corner
	--     override bits), face 1 leaves them to the per-vertex loop.
	b:u8(2 + 0x20)
	for _ = 1, 6 do b:u16(0x22) end
	b:u8(0x03)                -- surfmask: faces 0 and 1
	b:u8(0)                   -- totalverts
	-- face 0: vertmask hasxyz|corner|uvcorner|hasuv, 4 layer verts
	b:u8(0):u8(0)             -- lmid[0], lmid[1]
	b:u8(0x47)                -- hasxyz|0x01|0x02|hasuv
	b:u8(4)
	b:u16(0):u16(0):u16(8):u16(8)      -- 2 corner xyz pairs (4 x u16 = 8B)
	b:u16(0):u16(0):u16(8):u16(8)      -- 2 corner uv pairs  (4 x u16 = 8B)
	-- face 1: hasxyz|hasuv, 2 layer verts -> per-vertex loop, 2*(4+4) bytes
	b:u8(0):u8(0)
	b:u8(0x44)                -- hasxyz|hasuv, no corner override
	b:u8(2)                   -- 2 layer verts
	for _ = 1, 2 do
		b:u16(0):u16(0)       -- xyz
		b:u16(0):u16(0)       -- uv
	end
	--  3..7: EMPTY
	for _ = 3, 7 do
		b:u8(1)
		for _ = 1, 6 do b:u16(0) end
	end

	return b:build()
end

return function(ogz, maps, opts)
	opts = opts or {}
	local failures = {}
	local function check(name, ok, detail)
		if ok then
			print(("  ok: %s%s"):format(name, detail and (" (" .. detail .. ")") or ""))
		else
			local message = name .. (detail and (" (" .. tostring(detail) .. ")") or "")
			failures[#failures + 1] = message
			print("FAIL: " .. message)
		end
	end

	-- 1. Synthetic -------------------------------------------------------------
	print("[ogz] synthetic fixture")
	local data = fixture_map()
	local ok, map_or_err = pcall(ogz.parse, data)
	check("synthetic_parses", ok, not ok and map_or_err or nil)

	if ok then
		local map = map_or_err
		check("synthetic_stream_complete", map.stream_complete,
			("parsed %d of %d bytes"):format(map.decompressed_size,
				map.decompressed_size))
		check("synthetic_header",
			map.version == 33 and map.worldsize == 4 and map.gametype == "fps",
			("v%d world %d gametype %q"):format(map.version, map.worldsize,
				map.gametype))
		check("synthetic_entities", #map.entities == 2
				and map.entities[1].type == ogz.ET_LIGHT
				and map.entities[2].type == ogz.ET_PLAYERSTART
				and map.entities[2].x == 2 and map.entities[2].attrs[1] == 90,
			("%d entities"):format(#map.entities))
		check("synthetic_texture_mru", #map.texture_mru == 2
				and map.texture_mru[1] == 0x15,
			#map.texture_mru .. " slots")

		-- Empties are dropped; the solid, the shaped leaf and the
		-- surface-carrying solid survive.
		check("synthetic_leaves", #map.leaves == 3,
			#map.leaves .. " leaves")
		local solid, shaped, solid_surf
		for _, leaf in ipairs(map.leaves) do
			if leaf.is_solid() then
				-- Two solid octants exist; the first carries a material, the
				-- second a surface block.
				if not solid then solid = leaf else solid_surf = leaf end
			elseif not leaf.is_empty() then
				shaped = leaf
			end
		end
		check("synthetic_solid_leaf", solid ~= nil
				and solid.x == 0 and solid.y == 0 and solid.z == 0
				and solid.size == 2
				and ogz.material_kind(solid.material) == "water",
			solid and ("(%d,%d,%d)+%d %s"):format(solid.x, solid.y, solid.z,
				solid.size, ogz.material_kind(solid.material)) or "missing")
		check("synthetic_surface_leaf", solid_surf ~= nil
				and solid_surf.x == 0 and solid_surf.y == 2
				and solid_surf.size == 2,
			solid_surf and ("(%d,%d,%d)+%d"):format(solid_surf.x,
				solid_surf.y, solid_surf.z, solid_surf.size) or "missing")

		-- Corner decode: every span is 0..4, so corner (1,1,1) sits at half
		-- the leaf size.
		check("synthetic_shaped_leaf", shaped ~= nil
				and shaped.x == 2 and shaped.size == 2,
			shaped and ("(%d,%d,%d)+%d"):format(shaped.x, shaped.y, shaped.z,
				shaped.size) or "missing")
		if shaped then
			local x, y, z = shaped.corner_pos(1, 1, 1)
			check("synthetic_corners",
				math.abs(x - (shaped.x + shaped.size / 2)) < 1e-9
					and math.abs(y - (shaped.y + shaped.size / 2)) < 1e-9
					and math.abs(z - (shaped.z + shaped.size / 2)) < 1e-9,
				("corner (%g,%g,%g)"):format(x, y, z))
			local x0, y0, z0 = shaped.corner_pos(0, 0, 0)
			check("synthetic_corner_origin",
				x0 == shaped.x and y0 == shaped.y and z0 == shaped.z,
				("corner (%g,%g,%g)"):format(x0, y0, z0))
		end

		-- Region filtering keeps the stream position and drops outside leaves.
		local near = ogz.parse(data, {x0 = 0, y0 = 0, z0 = 0, x1 = 2, y1 = 2, z1 = 2})
		check("synthetic_region", near.stream_complete
				and near.stream_pos_end == map.stream_pos_end
				and #near.leaves < #map.leaves,
			("%d of %d leaves"):format(#near.leaves, #map.leaves))
	end

	-- A truncated file must raise, not silently return garbage.
	local truncated = data:sub(1, #data - 3)
	check("synthetic_truncated", not pcall(ogz.parse, truncated))
	check("synthetic_bad_magic",
		not pcall(ogz.parse, "XXXX" .. data:sub(5)))

	-- gzip framing: header parse + payload slice, with a stub inflater.
	local payload = "PAYLOAD"
	local gz = "\31\139\8\0" .. string.rep("\0", 6) .. payload
		.. string.rep("\0", 8)
	local got = ogz.gunzip(gz, function(bytes) return bytes end)
	check("synthetic_gunzip", got == payload, ("%q"):format(got))

	local gz_named = "\31\139\8\8" .. string.rep("\0", 6) .. "map.ogz\0"
		.. payload .. string.rep("\0", 8)
	check("synthetic_gunzip_fname",
		ogz.gunzip(gz_named, function(bytes) return bytes end) == payload)

	-- 2. Real maps (optional) -------------------------------------------------
	if maps and #maps > 0 then
		print("[ogz] real maps")
		if not opts.inflate_raw then
			check("real_maps_need_inflate", false, "no opts.inflate_raw")
		else
			for _, path in ipairs(maps) do
				local label = path:match("([^/]+)%.ogz$") or path
				local rok, rmap_or_err = pcall(ogz.read, path, opts)
				if not rok then
					check("read_" .. label, false, rmap_or_err)
				else
					local map = rmap_or_err
					check("stream_" .. label, map.stream_complete,
						("parsed %d of %d bytes%s"):format(
							map.stream_pos_end - 1, map.decompressed_size,
							map.stream_complete and "" or " MISMATCH"))
					check("read_" .. label, map.version <= ogz.MAPVERSION,
						("v%d world %d, %d leaves, %d ents"):format(
							map.version, map.worldsize, #map.leaves,
							#map.entities))

					local outside, first, minx, maxx = 0, nil, math.huge, -math.huge
					for _, leaf in ipairs(map.leaves) do
						if leaf.x < minx then minx = leaf.x end
						if leaf.x > maxx then maxx = leaf.x end
						if leaf.x < 0 or leaf.y < 0 or leaf.z < 0
							or leaf.x + leaf.size > map.worldsize
							or leaf.y + leaf.size > map.worldsize
							or leaf.z + leaf.size > map.worldsize then
							outside = outside + 1
							first = first or leaf
						end
					end
					check("bounds_" .. label, outside == 0,
						("%d outside (world %d, x %s..%s, first %s)")
							:format(outside, map.worldsize, tostring(minx),
								tostring(maxx),
								first and ("(%d,%d,%d)+%d"):format(first.x,
									first.y, first.z, first.size) or "-"))
				end
			end
		end
	end

	return failures
end
