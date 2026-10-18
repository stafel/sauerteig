-- Reader for Cube 2: Sauerbraten `.ogz` map files, in plain Lua 5.1/LuaJIT.
--
-- SCOPE: geometry only. Textures, lightmaps, PVS and blend maps are parsed
-- solely so the byte stream stays aligned and can be proven fully consumed;
-- their contents are discarded.
--
-- WHY LUA: exactly one implementation, usable from three hosts -
--   * in-engine (a trusted dev mod, see docs/sauerbraten-port-plan.md),
--   * headless local verification through `luantiheadless`,
--   * CI through tools/headless_qc.py + lupa (plain Lua, no engine).
-- The one thing we cannot do portably in Lua (raw inflate) is injected as a
-- callback instead of reimplemented per host: see `M.read` / `M.parse_gzip`.
--
-- Every format statement below was read from the engine sources in
-- `sauerbraten/src/` (references inline). The load-bearing safety net is
-- `map.stream_complete`: octree + lightmaps + PVS + blend map must add up to
-- exactly the decompressed size, otherwise every coordinate that follows is
-- garbage and nothing else matters.
--
-- BIT TESTS: Lua 5.1 has no bitwise operators and lupa's Lua may or may not
-- ship `bit`, so all flag tests go through `hasbit()`. Never write `x >= 0x40`
-- as a substitute for a bit test; the flags combine.

local M = {}

--- Engine constants ---------------------------------------------------------

M.MAPVERSION = 33              -- src/engine/world.h:8
M.LM_PACKW = 512               -- src/engine/lightmap.h:5
M.LM_PACKH = 512               -- src/engine/lightmap.h:6

local LM_BUMPMAP1 = 2
local LM_TYPE = 0x0F
local LM_ALPHA = 2 ^ 4         -- src/engine/lightmap.h:33-38

-- src/engine/worldio.cpp:214
local OCTSAV_CHILDREN = 0
local OCTSAV_EMPTY = 1
local OCTSAV_SOLID = 2
local OCTSAV_NORMAL = 3
local OCTSAV_LODCUBE = 4

local OCTSAV_SURFS = 0x20
local OCTSAV_MATERIAL = 0x40
local OCTSAV_MERGED = 0x80

local MAXFACEVERTS = 15        -- src/engine/octa.h:56
local LAYER_DUP = 0x80         -- src/engine/octa.h:52

M.MAT_AIR = 0                  -- src/shared/iengine.h:23-36
M.MAT_WATER = 1 * 2 ^ 2
M.MAT_LAVA = 2 * 2 ^ 2
M.MAT_GLASS = 3 * 2 ^ 2

-- src/shared/ents.h:6
M.ET_EMPTY = 0
M.ET_LIGHT = 1
M.ET_MAPMODEL = 2
M.ET_PLAYERSTART = 3
M.ET_ENVMAP = 4
M.ET_PARTICLES = 5
M.ET_SOUND = 6
M.ET_SPOTLIGHT = 7
M.ET_GAMESPECIFIC = 8

local ET_NAMES = {
	[0] = "empty", "light", "mapmodel", "playerstart", "envmap",
	"particles", "sound", "spotlight", "gamespecific",
}

-- src/engine/texture.h:577-587
local VSLOT_SHPARAM = 0
local VSLOT_SCALE = 1
local VSLOT_ROTATION = 2
local VSLOT_OFFSET = 3
local VSLOT_SCROLL = 4
local VSLOT_LAYER = 5
local VSLOT_ALPHA = 6
local VSLOT_COLOR = 7

-- src/engine/blend.cpp:5-7, 48
local BM_BRANCH = 0
local BM_SOLID = 1
local BM_IMAGE = 2
local BM_IMAGE_SIZE = 64

--- Small helpers ------------------------------------------------------------

-- True when bit `n` (0-based) is set in `value`.
local function hasbit(value, n)
	return math.floor(value / 2 ^ n) % 2 == 1
end
M.hasbit = hasbit

function M.entity_type_name(type_id)
	return ET_NAMES[type_id] or ("type" .. tostring(type_id))
end

-- Liquid/clip classification of a cube's empty-space material bitfield.
function M.material_kind(material)
	local volume = math.floor(material / 4) % 8
	if volume == 1 then return "water" end
	if volume == 2 then return "lava" end
	if volume == 3 then return "glass" end
	local clip = math.floor(material / 32) % 8
	if clip == 1 then return "noclip" end
	if clip == 2 then return "clip" end
	if clip == 3 then return "gameclip" end
	return "air"
end

function M.is_deadly(material)
	return hasbit(material, 8)
end

function M.is_alpha(material)
	return hasbit(material, 10)
end

local function is_power_of_two(n)
	if n < 1 then return false end
	while n % 2 == 0 do n = n / 2 end
	return n == 1
end

--- Byte reader --------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

local function new_reader(data, pos)
	return setmetatable({data = data, pos = pos or 1, len = #data}, Reader)
end
M.new_reader = new_reader

function Reader:remaining()
	return self.len - self.pos + 1
end

function Reader:at_end()
	return self.pos > self.len
end

function Reader:fail(what)
	error(string.format("[ogz] %s at byte %d (of %d)", what, self.pos, self.len), 0)
end

function Reader:take(n)
	if n < 0 then self:fail("negative read " .. n) end
	local last = self.pos + n - 1
	if last > self.len then
		self:fail(string.format("truncated: wanted %d bytes, %d left",
			n, self.len - self.pos + 1))
	end
	local chunk = self.data:sub(self.pos, last)
	self.pos = last + 1
	return chunk
end

function Reader:skip(n)
	if n < 0 then self:fail("negative skip " .. n) end
	local last = self.pos + n - 1
	if last > self.len then
		self:fail(string.format("truncated: wanted to skip %d bytes, %d left",
			n, self.len - self.pos + 1))
	end
	self.pos = last + 1
end

function Reader:u8()
	local v = self.data:byte(self.pos)
	if not v then self:fail("truncated u8") end
	self.pos = self.pos + 1
	return v
end

function Reader:u16()
	local a, b = self.data:byte(self.pos, self.pos + 1)
	if not b then self:fail("truncated u16") end
	self.pos = self.pos + 2
	return a + b * 256
end

function Reader:i16()
	local a, b = self.data:byte(self.pos, self.pos + 1)
	if not b then self:fail("truncated i16") end
	self.pos = self.pos + 2
	local v = a + b * 256
	if v >= 0x8000 then v = v - 0x10000 end
	return v
end

function Reader:u32()
	local a, b, c, d = self.data:byte(self.pos, self.pos + 3)
	if not d then self:fail("truncated u32") end
	self.pos = self.pos + 4
	return a + b * 256 + c * 65536 + d * 16777216
end

function Reader:i32()
	local v = self:u32()
	if v >= 0x80000000 then v = v - 0x100000000 end
	return v
end

-- IEEE-754 little-endian single. Floats only appear in entity positions.
function Reader:f32()
	local b1, b2, b3, b4 = self.data:byte(self.pos, self.pos + 3)
	if not b4 then self:fail("truncated f32") end
	self.pos = self.pos + 4
	local sign = hasbit(b4, 7) and -1 or 1
	local exponent = math.floor(b4 % 128) * 2 + math.floor(b3 / 128)
	local mantissa = ((b3 % 128) * 65536 + b2 * 256 + b1) / 8388608
	if exponent == 0 then
		return sign * mantissa * 2 ^ -126
	elseif exponent == 255 then
		return 0 / 0
	end
	return sign * (1 + mantissa) * 2 ^ (exponent - 127)
end

--- Header -------------------------------------------------------------------

local function read_header(r)
	local magic = r:take(4)
	if magic ~= "OCTA" then
		r:fail(string.format("bad magic %q, expected OCTA", magic))
	end
	local h = {
		magic = magic,
		version = r:i32(),
		headersize = r:i32(),
		worldsize = r:i32(),
		numents = r:i32(),
		numpvs = r:i32(),
		lightmaps = r:i32(),
	}
	if h.worldsize <= 0 or h.numents < 0 then
		r:fail(string.format("malformed header: worldsize=%d numents=%d",
			h.worldsize, h.numents))
	end
	if h.version > M.MAPVERSION then
		r:fail(string.format("map version %d needs a newer engine (max %d)",
			h.version, M.MAPVERSION))
	end

	if h.version <= 28 then
		-- worldio.cpp:1013-1017 reads the pre-29 compatheader, which also packs
		-- the map's lighting settings inline. Out of scope on purpose: the
		-- corpus we care about is v31+ and every v31+ file uses the modern
		-- header, so supporting dead formats would only add untested paths.
		r:fail(string.format(
			"map version %d is older than 29 and not supported (supported: 29-33)",
			h.version))
	end

	-- v30+: blendmap, numvars, numvslots (worldio.cpp:1022)
	h.blendmap = r:i32()
	h.numvars = r:i32()
	h.numvslots = (h.version <= 29) and 0 or r:i32()
	return h
end

local function skip_vars(r, count)
	-- worldio.cpp:1077-1116
	for _ = 1, count do
		local type_id = r:u8()
		local name_len = r:u16()
		r:skip(name_len)
		if type_id == 0 or type_id == 1 then
			r:skip(4)
		elseif type_id == 2 then
			r:skip(r:u16())
		else
			r:fail("unknown map var type " .. type_id)
		end
	end
end

local function read_entities(r, count, entskip)
	local ents = {}
	for i = 1, count do
		local x, y, z = r:f32(), r:f32(), r:f32()
		local attrs = {r:i16(), r:i16(), r:i16(), r:i16(), r:i16()}
		ents[i] = {x = x, y = y, z = z, attrs = attrs,
			type = r:u8(), reserved = r:u8()}
		-- A map saved by another game stores extra per-entity data
		-- (worldio.cpp:1173-1180: when the game ident differs, the engine skips
		-- `eif` bytes after every entity).
		if entskip > 0 then
			r:skip(entskip)
		end
	end
	return ents
end

local function skip_vslots(r, count)
	-- worldio.cpp:853-875: a negative `changed` emits that many default slots.
	while count > 0 do
		local changed = r:i32()
		if changed < 0 then
			count = count + changed
		else
			r:skip(4)                       -- prev index
			if hasbit(changed, VSLOT_SHPARAM) then
				for _ = 1, r:u16() do
					r:skip(r:u16() + 16)    -- name + 4 floats
				end
			end
			if hasbit(changed, VSLOT_SCALE) then r:skip(4) end
			if hasbit(changed, VSLOT_ROTATION) then r:skip(4) end
			if hasbit(changed, VSLOT_OFFSET) then r:skip(8) end
			if hasbit(changed, VSLOT_SCROLL) then r:skip(8) end
			if hasbit(changed, VSLOT_LAYER) then r:skip(4) end
			if hasbit(changed, VSLOT_ALPHA) then r:skip(8) end
			if hasbit(changed, VSLOT_COLOR) then r:skip(12) end
			count = count - 1
		end
	end
end

--- Surface block ------------------------------------------------------------

-- Skip a v33 surface block exactly (worldio.cpp:623-722).
-- We do not need per-vertex data (texture displacement and lightmap UVs), but
-- it has no length prefix, so it must be walked precisely or the octree
-- desynchronises. The subtle part is that a corner override consumes the
-- *whole* per-vertex loop that would otherwise follow.
local function skip_surfaces(r)
	local surfmask = r:u8()
	r:skip(1)                              -- totalverts: only sizes an alloc
	for face = 0, 5 do
		if hasbit(surfmask, face) then
			r:skip(2)                      -- lmid[0], lmid[1]
			local vertmask = r:u8()
			local numverts_raw = r:u8()
			local layerverts = numverts_raw % 16
			local dup = hasbit(numverts_raw, 7)
			local numverts = dup and layerverts * 2 or layerverts
			if numverts > 0 then
				local hasxyz = hasbit(vertmask, 2)
				local hasuv = hasbit(vertmask, 6)
				local hasnorm = hasbit(vertmask, 7)

				if layerverts == 4 then
					if hasxyz and hasbit(vertmask, 0) then
						r:skip(8)          -- 4 x u16
						hasxyz = false
					end
					if hasuv and hasbit(vertmask, 1) then
						r:skip(dup and 16 or 8)
						hasuv = false
					end
				end
				if hasnorm and hasbit(vertmask, 3) then
					r:skip(2)
					hasnorm = false
				end
				if hasxyz or hasuv or hasnorm then
					for _ = 1, layerverts do
						if hasxyz then r:skip(4) end
						if hasuv then r:skip(4) end
						if hasnorm then r:skip(2) end
					end
				end
				if dup then
					for _ = 1, layerverts do
						if hasuv then r:skip(4) end
					end
				end
			end
		end
	end
end

--- Leaves -------------------------------------------------------------------

-- A leaf is a general hexahedron: 12 edge spans at 1/8-cube precision
-- (src/engine/octa.h:200-204). span(edge, coord) picks the low or high nibble.
local function make_leaf(x, y, z, size, edges, texture, material, merged)
	local leaf = {
		x = x, y = y, z = z, size = size,
		edges = edges, texture = texture, material = material,
		merged = merged or 0,
	}
	local bytes = {edges:byte(1, 12)}

	function leaf.span(edge_index, coord)
		local byte = bytes[edge_index + 1]
		if coord ~= 0 then
			return math.floor(byte / 16)
		end
		return byte % 16
	end

	-- Corner in 0..8 units (src/engine/octa.cpp:656-671): the vertex at (x,y,z)
	-- takes x from edge (0,y,z), y from edge (1,z,x), z from edge (2,x,y),
	-- because cubeedge(c,d,a,b) = edges[(d*4) + (b*2) + a].
	function leaf.corner(cx, cy, cz)
		return leaf.span(2 * cz + cy, cx),
			leaf.span(4 + 2 * cx + cz, cy),
			leaf.span(8 + 2 * cy + cx, cz)
	end

	-- World position of a 0..8 corner, in cubes.
	function leaf.corner_pos(cx, cy, cz)
		local vx, vy, vz = leaf.corner(cx, cy, cz)
		local scale = size / 8
		return x + vx * scale, y + vy * scale, z + vz * scale
	end

	function leaf.is_empty()
		for i = 1, 12 do
			if bytes[i] ~= 0 then return false end
		end
		return true
	end

	function leaf.is_solid()
		for i = 1, 12 do
			if bytes[i] ~= 0x88 then return false end
		end
		return true
	end

	-- Nothing to convert: all-air with no liquid/clip material.
	function leaf.is_void()
		return leaf.is_empty() and material == M.MAT_AIR
	end

	function leaf.kind()
		if leaf.is_empty() then return "empty" end
		if leaf.is_solid() then return "solid" end
		return "shaped"
	end

	return leaf
end
M.make_leaf = make_leaf

-- Does a leaf's bounding box intersect the region [x0,x1) x [y0,y1) x [z0,z1)?
-- The region is half-open, like every other box in the engine.
local function intersects(leaf, region)
	if not region then return true end
	return leaf.x < region.x1 and leaf.x + leaf.size > region.x0
		and leaf.y < region.y1 and leaf.y + leaf.size > region.y0
		and leaf.z < region.z1 and leaf.z + leaf.size > region.z0
end
M.intersects = intersects

--- Legacy node tail (map versions <= 31) -------------------------------------

-- The engine keeps the map version in a global that every node reader consults
-- (`mapversion`, worldio.cpp:517-620) because the node layout changed between
-- versions. Mirror that: one module-level value, set by M.parse before any node
-- is read. Declared here so both the legacy and the modern readers can see it.
local mapversion = M.MAPVERSION

-- worldio.cpp:496-499. The pre-33 material byte packs volume, clip and flags
-- into 3/2/3 bits; convert it to the modern bitfield so downstream code has one
-- representation.
local function convert_old_material(mat)
	local volume = mat % 8
	local clip = math.floor(mat / 8) % 4
	local flags = math.floor(mat / 32) % 8
	return volume * 4 + clip * 32 + flags * 256
end
M.convert_old_material = convert_old_material

-- Skip the pre-32 node tail and return material, merged.
--
-- Two structural differences from v32/33 (worldio.cpp:519-610):
--   * a mask byte is ALWAYS present, and the material lives in its top bit
--     rather than in the node tag;
--   * surfaces are a fixed 16-byte `surfacecompat` record instead of a
--     variable-length per-vertex block, but the loop bound grows: a face whose
--     `layer` has bit 1 set appends an extra blended surface at index 6..11.
local function read_legacy_node_tail(r, tag)
	local mask = r:u8()

	local material = M.MAT_AIR
	if hasbit(mask, 7) then
		material = convert_old_material(r:u8())
	end

	local merged = 0
	if mask % 64 ~= 0 then                       -- mask & 0x3F: faces with data
		local numsurfs = 6
		local i = 0
		while i < numsurfs do
			if i >= 6 or hasbit(mask, i) then
				local record = r:take(16)        -- surfacecompat
				if i < 6 then
					if hasbit(mask, 6) then      -- mask & 0x40: normals follow
						-- normalscompat is `bvec normals[4]`, and bvec is
						-- THREE bytes (x, y, z uchar) - geom.h:1273-1280.
						-- Four bvecs are 12 bytes, not 4.
						r:skip(12)
					end
					local layer = record:byte(16)
					if math.floor(layer / 2) % 2 == 1 then
						numsurfs = numsurfs + 1
					end
				end
			end
			i = i + 1
		end
	end

	-- worldio.cpp:578-607: an old-style merge block may follow.
	if mapversion >= 20 and hasbit(tag, 7) then
		local merged_byte = r:u8()
		merged = merged_byte % 64                 -- c.merged = merged & 0x3F
		if hasbit(merged_byte, 7) then
			local merge_mask = r:u8()
			if merge_mask ~= 0 then
				for i = 0, 5 do
					if hasbit(merge_mask, i) then
						r:skip(8)                -- mergecompat: 4 x u16
					end
				end
			end
		end
	end

	return material, merged
end

--- Octree -------------------------------------------------------------------

local read_octree

-- `size` is the extent of EACH child (not of the parent): loadchildren() in
-- worldio.cpp:728-737 places child i at co + bit(i)*size with that same size.
local function read_children(r, x, y, z, size, out, region)
	for i = 0, 7 do
		read_octree(r,
			x + (i % 2) * size,
			y + (math.floor(i / 2) % 2) * size,
			z + (math.floor(i / 4) % 2) * size,
			size, out, region)
	end
end

read_octree = function(r, x, y, z, size, out, region)
	local tag = r:u8()
	local kind = tag % 8

	if kind == OCTSAV_CHILDREN then
		-- worldio.cpp:507-509: children of a node of size S have size S/2.
		-- `read_children`'s size argument is the CHILD size, so halve here.
		read_children(r, x, y, z, math.floor(size / 2), out, region)
		return
	end

	local haschildren = false
	local edges
	if kind == OCTSAV_LODCUBE then
		haschildren = true
		edges = string.rep("\0", 12)
	elseif kind == OCTSAV_EMPTY then
		edges = string.rep("\0", 12)
	elseif kind == OCTSAV_SOLID then
		edges = string.rep("\136", 12)     -- 0x88: every span 8..8
	elseif kind == OCTSAV_NORMAL then
		edges = r:take(12)
	else
		-- Tag 5..7 does not exist, so this is really a stream desync caused by
		-- an earlier construct this version uses and we do not implement yet.
		-- Report the version, it is the first thing to check.
		r:fail(string.format(
			"bad octree node tag %d (map version %d); the stream desynced "
			.. "earlier - that version's node layout or my skip logic is wrong",
			kind, mapversion))
	end

	local texture = {}
	for i = 1, 6 do texture[i] = r:u16() end

	local material, merged
	if mapversion <= 31 then
		material, merged = read_legacy_node_tail(r, tag)
	else
		-- worldio.cpp:611-723
		material = M.MAT_AIR
		merged = 0
		if hasbit(tag, 6) then              -- OCTSAV_MATERIAL
			if mapversion <= 32 then
				material = convert_old_material(r:u8())
			else
				material = r:u16()
			end
		end
		if hasbit(tag, 7) then              -- OCTSAV_MERGED
			merged = r:u8()
		end
		if hasbit(tag, 5) then              -- OCTSAV_SURFS
			skip_surfaces(r)
		end
	end

	-- Interior leaves carry no geometry of their own; dropping them keeps the
	-- leaf list (and everything downstream) small.
	if not haschildren then
		local leaf = make_leaf(x, y, z, size, edges, texture, material, merged)
		if not leaf.is_void() and intersects(leaf, region) then
			out[#out + 1] = leaf
		end
	end

	if haschildren then
		-- Children are half the size of this node (worldio.cpp:725).
		read_children(r, x, y, z, math.floor(size / 2), out, region)
	end
end

--- Trailing sections --------------------------------------------------------

local function skip_lightmaps(r, count, version)
	local start = r.pos
	for _ = 1, count do
		local lm_type = 0
		if version >= 17 then
			lm_type = r:u8()
			if version >= 20 and hasbit(lm_type, 7) then
				r:skip(4)                  -- unlitx, unlity (u16 each)
			end
		end
		local alpha = hasbit(lm_type, 4)
		local mapped = lm_type % 16
		local bpp = (alpha and mapped ~= LM_BUMPMAP1) and 4 or 3
		r:skip(bpp * M.LM_PACKW * M.LM_PACKH)
	end
	return r.pos - start
end

local function skip_pvs(r, numpvs)
	-- src/engine/pvs.cpp:1293-1312
	local start = r.pos
	local totallen = r:u32()
	if hasbit(totallen, 31) then
		totallen = totallen - 0x80000000
		local waterplanes = r:u32()
		for _ = 1, waterplanes do
			if r:i32() < 0 then break end
		end
	end
	for _ = 1, numpvs do
		r:u16()
	end
	r:skip(totallen)
	local function walk()
		local leafmask = r:u8()
		for i = 0, 7 do
			if hasbit(leafmask, i) then
				r:skip(4)
			else
				walk()
			end
		end
	end
	walk()
	return r.pos - start
end

local function skip_blendmap(r)
	-- src/engine/blend.cpp:795-827
	local start = r.pos
	local function walk()
		local type_id = r:u8()
		if type_id == BM_SOLID then
			r:skip(1)
		elseif type_id == BM_IMAGE then
			r:skip(BM_IMAGE_SIZE * BM_IMAGE_SIZE)
		elseif type_id == BM_BRANCH then
			for _ = 1, 4 do walk() end
		else
			r:fail("bad blendmap node type " .. type_id)
		end
	end
	walk()
	return r.pos - start
end

--- Public: parse ------------------------------------------------------------

-- Parse a decompressed map.
-- `region` = {x0=,y0=,z0=,x1=,y1=,z1=}, half-open, keeps only intersecting
-- leaves. The stream is still walked end to end: the format has no index, so
-- there is no way to skip an octree subtree without decoding it.
function M.parse(data, region)
	local r = new_reader(data)
	local h = read_header(r)
	mapversion = h.version
	if not is_power_of_two(h.worldsize) then
		r:fail("worldsize " .. h.worldsize .. " is not a power of two")
	end

	skip_vars(r, h.numvars)

	local gametype = ""
	local entity_extra = 0
	if h.version >= 16 then
		local name_len = r:u8()
		gametype = r:take(name_len + 1):match("^[^%z]*") or ""
		entity_extra = r:u16()             -- eif: per-entity size of that game's
		r:skip(r:u16())                    -- extras
	end

	local texture_mru = {}
	if h.version < 14 then
		r:skip(256)
	else
		for i = 1, r:u16() do texture_mru[i] = r:u16() end
	end

	local entities = read_entities(r, h.numents,
		(gametype == "fps") and 0 or entity_extra)
	skip_vslots(r, h.numvslots)

	-- Diagnostics for a desync: where the octree started, so a "bad tag at
	-- byte N" can be attributed to the header/entity region or to a node tail.
	M.last_debug = {
		gametype = gametype,
		eif = entity_extra,
		numents = h.numents,
		numvslots = h.numvslots,
		octree_start = r.pos,
	}

	local leaves = {}
	read_children(r, 0, 0, 0, math.floor(h.worldsize / 2), leaves, region)
	local after_octree = r.pos

	local lightmap_bytes = 0
	if h.version >= 7 then
		lightmap_bytes = skip_lightmaps(r, h.lightmaps, h.version)
	end
	local pvs_bytes = 0
	if h.version >= 25 and h.numpvs > 0 then
		pvs_bytes = skip_pvs(r, h.numpvs)
	end
	local blendmap_bytes = 0
	if h.version >= 28 and h.blendmap ~= 0 then
		blendmap_bytes = skip_blendmap(r)
	end

	return {
		magic = h.magic,
		version = h.version,
		headersize = h.headersize,
		worldsize = h.worldsize,
		numents = h.numents,
		numpvs = h.numpvs,
		lightmaps = h.lightmaps,
		blendmap = h.blendmap,
		numvars = h.numvars,
		numvslots = h.numvslots,
		gametype = gametype,
		entities = entities,
		leaves = leaves,
		texture_mru = texture_mru,
		decompressed_size = #data,
		stream_pos_after_octree = after_octree,
		stream_pos_end = r.pos,
		lightmap_bytes = lightmap_bytes,
		pvs_bytes = pvs_bytes,
		blendmap_bytes = blendmap_bytes,
		stream_complete = (r.pos == #data + 1),
	}
end

-- Split a gzip stream (RFC 1952) and hand its deflate payload to `inflate_raw`.
-- Only raw inflation is delegated: in-engine that is
-- `core.decompress(bytes, "raw_deflate")`, in CI it is Python's zlib.
function M.gunzip(raw, inflate_raw)
	if #raw < 18 or raw:byte(1) ~= 0x1f or raw:byte(2) ~= 0x8b then
		error("[ogz] not a gzip stream", 0)
	end
	if raw:byte(3) ~= 8 then
		error("[ogz] unsupported gzip compression method " .. raw:byte(3), 0)
	end
	local flg = raw:byte(4)
	local pos = 11

	if hasbit(flg, 2) then                        -- FEXTRA
		local xlen = (raw:byte(pos) or 0) + (raw:byte(pos + 1) or 0) * 256
		pos = pos + 2 + xlen
	end
	if hasbit(flg, 3) then                        -- FNAME
		while pos <= #raw and raw:byte(pos) ~= 0 do pos = pos + 1 end
		pos = pos + 1
	end
	if hasbit(flg, 4) then                        -- FCOMMENT
		while pos <= #raw and raw:byte(pos) ~= 0 do pos = pos + 1 end
		pos = pos + 1
	end
	if hasbit(flg, 1) then                        -- FHCRC
		pos = pos + 2
	end
	if pos > #raw - 8 then
		error("[ogz] gzip stream too short after its header", 0)
	end
	return inflate_raw(raw:sub(pos, #raw - 8))
end

-- Parse a gzip-compressed .ogz from a string.
-- opts.inflate_raw(deflated) -> bytes is required.
function M.parse_gzip(raw, region, opts)
	opts = opts or {}
	if not opts.inflate_raw then
		error("[ogz] parse_gzip needs opts.inflate_raw", 0)
	end
	return M.parse(M.gunzip(raw, opts.inflate_raw), region, opts)
end

-- Read and parse a .ogz from disk.
-- opts.io          : table with open(path, "rb") (defaults to `io`)
-- opts.inflate_raw : function(deflated) -> bytes (required)
function M.read(path, opts)
	opts = opts or {}
	local io_impl = opts.io or io
	if not io_impl then
		error("[ogz] no io available; pass opts.io (in-engine use a trusted "
			.. "mod's insecure environment)", 0)
	end
	local handle = assert(io_impl.open(path, "rb"))
	local raw = handle:read("*a")
	handle:close()
	return M.parse_gzip(raw, opts.region, opts)
end

--- Reporting ----------------------------------------------------------------

function M.summary(map)
	local counts = {solid = 0, empty = 0, shaped = 0}
	for _, leaf in ipairs(map.leaves) do
		counts[leaf.kind()] = counts[leaf.kind()] + 1
	end
	local scale = 0
	while 2 ^ scale < map.worldsize do scale = scale + 1 end
	return {
		version = map.version,
		worldsize = map.worldsize,
		mapscale = scale,
		gametype = map.gametype,
		entities = #map.entities,
		leaves = #map.leaves,
		leaves_solid = counts.solid,
		leaves_empty = counts.empty,
		leaves_shaped = counts.shaped,
		texture_slots = #map.texture_mru,
		decompressed_bytes = map.decompressed_size,
		octree_end = map.stream_pos_after_octree,
		stream_end = map.stream_pos_end,
		stream_complete = map.stream_complete,
		lightmap_bytes = map.lightmap_bytes,
		pvs_bytes = map.pvs_bytes,
		blendmap_bytes = map.blendmap_bytes,
	}
end

function M.format_summary(map)
	local out = {}
	for _, key in ipairs({"version", "worldsize", "mapscale", "gametype",
		"entities", "leaves", "leaves_solid", "leaves_empty", "leaves_shaped",
		"texture_slots", "decompressed_bytes", "octree_end", "stream_end",
		"stream_complete", "lightmap_bytes", "pvs_bytes", "blendmap_bytes"}) do
		out[#out + 1] = string.format("%22s: %s", key, tostring(M.summary(map)[key]))
	end
	return table.concat(out, "\n")
end

-- ASCII slice along one axis, for eyeballing a conversion without a client.
function M.ascii_slice(map, axis, layer, max_cells)
	max_cells = max_cells or 72
	local n = math.max(1, math.floor(map.worldsize / math.max(1,
		math.floor(map.worldsize / max_cells))))
	local stride = math.max(1, math.floor(map.worldsize / n))
	local grid = {}
	for row = 1, n do
		grid[row] = {}
		for col = 1, n do grid[row][col] = "." end
	end
	for _, leaf in ipairs(map.leaves) do
		if not leaf.is_empty() then
			local lo = (axis == "x") and leaf.x or (axis == "y") and leaf.y or leaf.z
			if lo <= layer and layer < lo + leaf.size then
				for a = 0, leaf.size - 1, stride do
					for b = 0, leaf.size - 1, stride do
						local gx, gy
						if axis == "z" then
							gx, gy = leaf.x + a, leaf.y + b
						elseif axis == "y" then
							gx, gy = leaf.x + a, leaf.z + b
						else
							gx, gy = leaf.y + a, leaf.z + b
						end
						local col = math.floor(gx / stride) + 1
						local row = n - math.floor(gy / stride)
						if grid[row] and grid[row][col] then
							grid[row][col] = "#"
						end
					end
				end
			end
		end
	end
	local rows = {}
	for row = 1, n do rows[row] = table.concat(grid[row]) end
	return rows
end

return M
