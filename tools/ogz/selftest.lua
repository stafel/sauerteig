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

-- Build a map of one supported version.
--
-- Layout is chosen so every structural case is exercised, including the two
-- that used to be untested and hid a real bug:
--   * octant 3 is a CHILDREN node, whose children have HALF the octant's size;
--     getting that wrong pushes leaves outside the world (bounds assertion).
--   * octant 4 is a LODCUBE node, which carries a (useless) body AND children.
--
-- worldsize 4: the 8 root octants have size 2, their children size 1.
local function fixture_map(version)
	version = version or 33
	local legacy = version <= 31
	local b = Builder.new()
	b:raw("OCTA")
	b:i32(version)
	b:i32(40)                 -- headersize
	b:i32(4)                  -- worldsize
	b:i32(2)                  -- numents
	b:i32(0)                  -- numpvs
	b:i32(0)                  -- lightmaps
	b:i32(0)                  -- blendmap
	b:i32(1)                  -- numvars (one ID_VAR we must skip)
	if version >= 30 then
		b:i32(1)              -- numvslots (one default slot)
	end
	-- v29 has no numvslots field at all (worldio.cpp:1021, `extra`), which is
	-- exactly why the version gate matters.

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

	if version >= 30 then
		-- vslots: one slot with `changed` = SCALE only, then prev index, then
		-- the float scale. (A negative `changed` emits N defaults.)
		b:i32(2 ^ 1)          -- changed = VSLOT_SCALE
		b:i32(-1)             -- prev
		b:f32(1)              -- scale
	end

	-- Texts are identical in every version >= 14.
	local function textures(slot)
		for _ = 1, 6 do b:u16(slot) end
	end

	-- Octant 0: SOLID carrying a material.
	b:u8(2 + 0x40)
	textures(0x20)
	if legacy then
		-- v<=31: material lives in the mask byte's top bit, as an old byte.
		-- Mask 0x80 = material only; any low bit would also request a 16-byte
		-- surface record for that face.
		b:u8(0x80):u8(1)      -- mat=1 -> convert_old_material -> MAT_WATER
	elseif version <= 32 then
		b:u8(1)               -- v32: material is one byte
	else
		b:u16(0x0004)         -- v33: material is a ushort (MAT_WATER)
	end

	-- Octant 1: NORMAL (every span 0..4 -> a half-size box in the corner).
	b:u8(3)
	b:raw(string.rep(string.char(0x40), 12))
	textures(0x21)
	if legacy then
		-- Legacy surface block: face 0 plus normals, and face 0 asks for a
		-- blended layer, which grows the record count from 6 to 7. This is the
		-- only path in the whole format whose length depends on its own data.
		b:u8(0x41)            -- mask: face 0 (0x01) + normals (0x40)
		b:raw(string.rep("\0", 15)):u8(2)   -- 16B surfacecompat, layer&2 set
		b:raw(string.rep("\0", 12))          -- normalscompat: bvec[4] = 12B
		b:raw(string.rep("\0", 16))         -- the extra blended surface
	end

	-- Octant 2: SOLID with a v33-style surface block. Two faces so both skip
	-- paths are covered: face 0 consumes xyz and uv up front (corner override
	-- bits), face 1 leaves them to the per-vertex loop.
	if legacy then
		b:u8(2)
		textures(0x22)
		b:u8(0x00)            -- mask: no material, no faces, no normals
	else
		b:u8(2 + 0x20)
		textures(0x22)
		b:u8(0x03)            -- surfmask: faces 0 and 1
		b:u8(0)               -- totalverts
		b:u8(0):u8(0)         -- lmid[0], lmid[1]
		b:u8(0x47)            -- hasxyz|corner|uvcorner|hasuv
		b:u8(4)
		b:u16(0):u16(0):u16(8):u16(8)   -- 2 corner xyz pairs
		b:u16(0):u16(0):u16(8):u16(8)   -- 2 corner uv pairs
		b:u8(0):u8(0)         -- face 1: lmid
		b:u8(0x44)            -- hasxyz|hasuv, no corner override
		b:u8(2)               -- 2 layer verts
		for _ = 1, 2 do
			b:u16(0):u16(0)   -- xyz
			b:u16(0):u16(0)   -- uv
		end
	end

	-- Octant 3: CHILDREN. The 8 children have size 1 (half of this octant's 2).
	-- Child 0 is solid, the rest are empty.
	b:u8(0)
	for child = 0, 7 do
		if child == 0 then
			b:u8(2)
			textures(0x23)
			if legacy then b:u8(0x00) end
		else
			b:u8(1)
			textures(0)
			if legacy then b:u8(0x00) end
		end
	end

	-- Octant 4: LODCUBE. It carries a body (which must NOT become a leaf) plus
	-- its own 8 children; child 0 is a shaped leaf.
	b:u8(4)
	textures(0x24)
	if legacy then b:u8(0x00) end
	for child = 0, 7 do
		if child == 0 then
			b:u8(3)
			b:raw(string.rep(string.char(0x80), 12))
			textures(0x25)
			if legacy then b:u8(0x00) end
		else
			b:u8(1)
			textures(0)
			if legacy then b:u8(0x00) end
		end
	end

	-- Octants 5..7: empty.
	for _ = 5, 7 do
		b:u8(1)
		textures(0)
		if legacy then b:u8(0x00) end
	end

	return b:build()
end

-- Optional module: the oracle comparator. When present, verify it against our
-- own dump (identity), so that a dump/compare disagreement later is never
-- mistaken for an engine difference.
return function(ogz, maps, opts)
	opts = opts or {}
	local compare = opts.compare
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
	-- Every supported version runs the same fixture, so a version-specific
	-- regression (material width, legacy tail) fails loudly instead of only
	-- showing up on whichever real map happens to use that version.
	print("[ogz] synthetic fixtures")
	local data
	for _, version in ipairs({33, 32, 31, 30, 29}) do
		local label = ("v%d"):format(version)
		local bytes = fixture_map(version)
		if version == 33 then data = bytes end

		local ok, map_or_err = pcall(ogz.parse, bytes)
		check("synthetic_parses_" .. label, ok, not ok and map_or_err or nil)
		if ok then
			local map = map_or_err
			check("stream_complete_" .. label, map.stream_complete,
				("%d bytes"):format(map.decompressed_size))
			check("header_" .. label, map.version == version
					and map.worldsize == 4 and map.gametype == "fps",
				("v%d world %d"):format(map.version, map.worldsize))

			-- The bounds check is the one that catches a wrong child size:
			-- passing the parent's size to read_children pushes leaves out of
			-- the world while still consuming the right number of bytes.
			local outside, worst = 0, nil
			for _, leaf in ipairs(map.leaves) do
				if leaf.x < 0 or leaf.y < 0 or leaf.z < 0
					or leaf.x + leaf.size > map.worldsize
					or leaf.y + leaf.size > map.worldsize
					or leaf.z + leaf.size > map.worldsize then
					outside = outside + 1
					worst = worst or leaf
				end
			end
			check("bounds_" .. label, outside == 0,
				worst and ("(%d,%d,%d)+%d"):format(worst.x, worst.y, worst.z,
					worst.size) or "all inside")

			-- Leaves: octant0 solid, octant1 shaped (NORMAL), octant2 solid,
			-- octant3 child0 solid, octant4 child0 shaped. Empties and the
			-- LODCUBE body are dropped.
			check("leaves_" .. label, #map.leaves == 5,
				#map.leaves .. " leaves")

			local bypos = {}
			for _, leaf in ipairs(map.leaves) do
				bypos[("%d,%d,%d"):format(leaf.x, leaf.y, leaf.z)] = leaf
			end

			local solid = bypos["0,0,0"]
			check("solid_leaf_" .. label, solid ~= nil and solid.size == 2
					and ogz.material_kind(solid.material) == "water",
				solid and ogz.material_kind(solid.material) or "missing")

			local surf = bypos["0,2,0"]
			check("surface_leaf_" .. label, surf ~= nil and surf.size == 2,
				surf and ("size %d"):format(surf.size) or "missing")

			-- Octant 1 is a NORMAL node: a shaped leaf, not dropped.
			local shaped = bypos["2,0,0"]
			check("shaped_leaf_" .. label, shaped ~= nil and shaped.size == 2,
				shaped and ("size %d"):format(shaped.size) or "missing")

			-- The CHILDREN octant is index 3 -> (2,2,0), child 0 keeps that
			-- position at size 1.
			check("children_leaf_" .. label, bypos["2,2,0"] ~= nil
					and bypos["2,2,0"].size == 1,
				bypos["2,2,0"] and ("size %d"):format(bypos["2,2,0"].size)
					or "missing")

			-- The LODCUBE octant is index 4 -> (0,0,2); its body must not be
			-- a leaf, but child 0 must.
			local lod = bypos["0,0,2"]
			check("lodcube_child_" .. label, lod ~= nil and lod.size == 1,
				lod and ("size %d"):format(lod.size) or "missing")

			if lod then
				local x, y, z = lod.corner_pos(1, 1, 1)
				check("corners_" .. label,
					math.abs(x - (lod.x + lod.size)) < 1e-9
						and math.abs(y - (lod.y + lod.size)) < 1e-9
						and math.abs(z - (lod.z + lod.size)) < 1e-9,
					("corner (%g,%g,%g)"):format(x, y, z))
			end

			-- Region filtering keeps the stream position and drops outsiders.
			local near = ogz.parse(bytes,
				{x0 = 0, y0 = 0, z0 = 0, x1 = 1, y1 = 1, z1 = 1})
			check("region_" .. label, near.stream_complete
					and near.stream_pos_end == map.stream_pos_end
					and #near.leaves < #map.leaves,
				("%d of %d leaves"):format(#near.leaves, #map.leaves))
		end
	end

	-- An unsupported version must say so clearly, not desync.
	local old = fixture_map(33):sub(1, 4) .. string.char(24, 0, 0, 0)
		.. fixture_map(33):sub(9)
	local ok_old, err_old = pcall(ogz.parse, old)
	check("synthetic_rejects_v24", not ok_old
			and tostring(err_old):find("29%-33") ~= nil, err_old)

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

	-- 3. Oracle comparator self-check -----------------------------------------
	-- The Option C oracle diffs an engine dump against our leaves. Before it can
	-- be trusted, the comparator must agree with a dump we generate ourselves.
	if compare then
		print("[ogz] oracle comparator")
		local bytes = fixture_map(33)
		local ok_c, map_c = pcall(ogz.parse, bytes)
		if ok_c then
			local dump = compare.format_dump(map_c.leaves)
			local diff, stats = compare.compare(dump, map_c.leaves)
			check("compare_identity", #diff == 0,
				#diff > 0 and diff[1] or nil)
			check("compare_identity_counts", stats
					and stats.expected == stats.actual
					and stats.missing == 0 and stats.extra == 0
					and stats.mismatched == 0,
				stats and ("%d/%d"):format(stats.expected, stats.actual) or "?")

			-- A one-byte difference must be reported, not tolerated.
			local one = map_c.leaves[1]
			local corrupt = map_c.leaves[1].edges:sub(1, 1)
				.. string.char((map_c.leaves[1].edges:byte(2) + 1) % 256)
				.. map_c.leaves[1].edges:sub(3)
			local corrupted_dump = dump:gsub(
				string.format("^%d %d %d %d %02x %02x",
					one.x, one.y, one.z, one.size,
					one.edges:byte(1), one.edges:byte(2)),
				string.format("%d %d %d %d %02x %02x",
					one.x, one.y, one.z, one.size,
					corrupt:byte(1), corrupt:byte(2)), 1)
			local diff2 = compare.compare(corrupted_dump, map_c.leaves)
			check("compare_detects_difference", #diff2 > 0,
				#diff2 > 0 and diff2[1] or "difference was not detected")
		end
	end

	-- 2. Real maps (optional) -------------------------------------------------
	if maps and #maps > 0 then
		print("[ogz] real maps (" .. #maps .. ")")
		if not opts.inflate_raw then
			check("real_maps_need_inflate", false, "no opts.inflate_raw")
		else
			local parsed, skipped, failed = 0, 0, 0
			for _, path in ipairs(maps) do
				local label = path:match("([^/]+)%.ogz$") or path
				local rok, rmap_or_err = pcall(ogz.read, path, opts)
				if not rok then
					local message = tostring(rmap_or_err)
					if message:find("not supported %(supported") then
						-- Older format: out of scope, counted separately.
						skipped = skipped + 1
					else
						failed = failed + 1
						local d = ogz.last_debug or {}
						check("read_" .. label, false,
							("%s | gametype=%q ents=%s vslots=%s octree@%s")
								:format(message, tostring(d.gametype),
									tostring(d.numents), tostring(d.numvslots),
									tostring(d.octree_start)))
					end
				else
					local map = rmap_or_err
					parsed = parsed + 1
					-- Two independent invariants. `stream_complete` proves the
					-- byte accounting; in-bounds leaves prove the octant walk.
					-- The child-size bug satisfied the first and violated the
					-- second, which is why both are asserted.
					local outside, worst = 0, nil
					for _, leaf in ipairs(map.leaves) do
						if leaf.x < 0 or leaf.y < 0 or leaf.z < 0
							or leaf.x + leaf.size > map.worldsize
							or leaf.y + leaf.size > map.worldsize
							or leaf.z + leaf.size > map.worldsize then
							outside = outside + 1
							worst = worst or leaf
						end
					end
					check("map_" .. label, map.stream_complete and outside == 0,
						("%d bytes, v%d world %d, %d leaves%s, %d ents%s")
							:format(map.decompressed_size, map.version,
								map.worldsize, #map.leaves,
								map.stream_complete and "" or " STREAM MISMATCH",
								#map.entities,
								outside == 0 and "" or
									(" %d OUTSIDE e.g. (%d,%d,%d)+%d")
										:format(outside, worst.x, worst.y,
											worst.z, worst.size)))
				end
			end
			print(("[ogz] corpus: %d parsed, %d old-format skipped, %d failed")
				:format(parsed, skipped, failed))
			check("corpus_mostly_parsed", parsed >= (#maps - skipped),
				("%d of %d supported maps"):format(parsed, #maps - skipped))
		end
	end

	return failures
end
