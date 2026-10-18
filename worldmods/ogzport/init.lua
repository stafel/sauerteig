-- Export half of the Sauerbraten -> Luanti porter (docs/sauerbraten-port-plan.md).
--
-- Runs with the REPOSITORY ROOT as the world directory (see ./world.mt), which
-- is what lets the mod sandbox read both `tools/ogz/*.lua` and
-- `sauerbraten/packages/*`. Writes a compact payload into mod_data, because
-- mod_data is the one place a *different* world (the real savegame) can also
-- read from.
--
-- Driven by tools/ogz/run.txt, a directive file the mod reads itself: world.mt
-- keys are not exposed through `core.settings`, so passing tool arguments
-- through there does not work.
--
--     export <map> <size>              voxelize and write a payload
--     scan <size> <map> <map> ...      report what each map would give
--
-- This is a build-time tool, not gameplay code: it is inert without a directive.

-- Bumped whenever the *conversion* changes shape (voxelizer, axis mapping,
-- material rules). The payload id carries it, so an importer that already wrote
-- an older conversion redoes the region instead of keeping stale geometry.
local CONVERTER_REVISION = 9

local world = core.get_worldpath()

local function read_directive()
	local handle = io.open(world .. "/tools/ogz/run.txt", "rb")
	if not handle then return nil end
	local found
	for line in handle:lines() do
		line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
		local mode, rest = line:match("^(%a+)%s+(.*)$")
		if mode == "export" then
			local mapname, size = rest:match("^(%S+)%s+(%d+)")
			if mapname then
				found = {mode = "export", map = mapname, size = tonumber(size)}
			end
		elseif mode == "scan" then
			local size, maps = rest:match("^(%d+)%s+(.*)$")
			if size then
				local list = {}
				for name in maps:gmatch("%S+") do list[#list + 1] = name end
				found = {mode = "scan", size = tonumber(size), maps = list}
			end
		end
	end
	handle:close()
	return found
end

local directive = read_directive()
if not directive then
	return
end

-- MUST be called at file scope: `core.get_mod_data_path()` derives the mod name
-- from a value the engine only sets while the mod is being loaded
-- (ScriptApiBase::loadMod), so inside a callback it returns nil.
local modpath = assert(core.get_mod_data_path(), "no mod data path")
local size = directive.size

local function load_module(relpath)
	local handle = assert(io.open(world .. "/" .. relpath, "rb"),
		"cannot read " .. relpath)
	local source = handle:read("*a")
	handle:close()
	local chunk, err = loadstring(source, "@" .. relpath)
	assert(chunk, err)
	return chunk()
end

local function readfile(relpath)
	local handle = io.open(world .. "/sauerbraten/" .. relpath, "rb")
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

core.after(0.2, function()
	local started = os.clock()
	local ogz = load_module("tools/ogz/ogz.lua")
	local materials = load_module("tools/ogz/materials.lua")
	local port = load_module("tools/ogz/port.lua")

	-- Load a map and its material palette, and build the slot -> palette index
	-- resolver plus the Luanti node name table.
	local function prepare(mapname)
		local map = ogz.read(world .. "/sauerbraten/packages/base/" .. mapname
			.. ".ogz", {
			io = io,
			inflate_raw = function(bytes)
				return core.decompress(bytes, "raw_deflate")
			end,
		})
		if not map.stream_complete then
			return nil, "stream did not complete"
		end

		local palette_names, report = materials.build_palette(mapname,
			readfile, map.texture_mru)

		local names, index_of = {}, {}
		local function intern(node_name)
			if not index_of[node_name] then
				names[#names + 1] = node_name
				index_of[node_name] = #names
			end
			return index_of[node_name]
		end
		-- Sauerbraten texture slots are 0-based; the palette array is 1-based.
		-- Keep the leaf's own numbering as the table key so no call site has to
		-- remember which convention it is holding.
		local slot_index = {}
		for slot = 0, #palette_names - 1 do
			slot_index[slot] = intern(palette_names[slot + 1]
				or materials.FALLBACK)
		end
		local liquid_index = {
			water = intern("default:water_source"),
			lava = intern("default:lava_source"),
		}

		local function resolve_slot(key)
			if type(key) == "string" then
				return liquid_index[key] or 0
			end
			if not key then
				return intern(materials.FALLBACK)
			end
			return slot_index[key] or intern(materials.FALLBACK)
		end

		return {
			map = map, names = names, report = report,
			slot_index = slot_index, resolve_slot = resolve_slot,
			palette_names = palette_names,
		}
	end

	-- Pick a region by density, then re-rank the dense candidates by material
	-- diversity: a region poured from one texture looks like a monolith no
	-- matter how correct the geometry is, so diversity is what makes a port
	-- recognisable.
	local function choose_region(map, port, slot_index)
		local region, err, report, candidates = port.find_dense_region(map, size)
		if not region then
			return nil, err
		end
		local best, best_diversity, best_density = region, -1, report.density
		for _, candidate in ipairs(candidates or {}) do
			local diversity = port.slot_diversity(map, candidate)
			if diversity > best_diversity then
				best_diversity, best_density = diversity, candidate.density
				best = candidate
			end
		end
		return best, nil, best_diversity, best_density
	end

	local function histogram_of(grid, names)
		local counts, total = {}, 0
		for i = 1, #grid do
			local value = grid[i]
			if value ~= 0 then
				counts[value] = (counts[value] or 0) + 1
				total = total + 1
			end
		end
		local order = {}
		for value in pairs(counts) do order[#order + 1] = value end
		table.sort(order, function(a, b) return counts[a] > counts[b] end)
		local parts = {}
		for i = 1, math.min(#order, 6) do
			local value = order[i]
			parts[#parts + 1] = ("%s=%d"):format(names[value] or "?", counts[value])
		end
		return total, #order, table.concat(parts, " ")
	end

	--- scan: report what each map would give, without writing anything ------
	if directive.mode == "scan" then
		print(("[ogzport] scan %d maps at size %d"):format(#directive.maps, size))
		for _, mapname in ipairs(directive.maps) do
			local ok, prepared, err = pcall(prepare, mapname)
			if not ok then
				-- An unsupported map version must not abort the whole scan.
				print(("[ogzport] %-16s SKIPPED: %s"):format(mapname,
					tostring(prepared)))
			elseif not prepared then
				print(("[ogzport] %-16s FAILED: %s"):format(mapname,
					tostring(err)))
			else
				local map = prepared.map
				local region, region_err, diversity, density =
					choose_region(map, port, prepared.slot_index)
				if not region then
					print(("[ogzport] %-16s no region: %s"):format(mapname,
						tostring(region_err)))
				else
					local grid, stats = port.voxelize(map, region,
						prepared.resolve_slot)
					local total, distinct, top = histogram_of(grid, prepared.names)
					print(("[ogzport] %-16s v%d w%-5d slots=%-4d distinct=%-2d "
						.. "solid=%-6d shaped=%-3d  %s")
						:format(mapname, map.version, map.worldsize,
							prepared.report.slots, distinct, total, stats.shaped,
							top))
				end
			end
		end
		print(("[ogzport] SCAN DONE in %.1fs"):format(os.clock() - started))
		return
	end

	--- export ---------------------------------------------------------------
	local mapname = directive.map
	print(("[ogzport] export %s, region %d"):format(mapname, size))
	local prepared, err = prepare(mapname)
	if not prepared then
		print("[ogzport] FAIL " .. tostring(err))
		return
	end
	local map, names, report = prepared.map, prepared.names, prepared.report
	print(("[ogzport] map v%d world %d, %d leaves, %d ents")
		:format(map.version, map.worldsize, #map.leaves, #map.entities))
	print(("[ogzport] materials: %d slots, %d keyword-matched, %d hash-fallback")
		:format(report.slots, report.resolved, report.neutral))

	local region, region_err, diversity, density =
		choose_region(map, port, prepared.slot_index)
	if not region then
		print("[ogzport] FAIL no region: " .. tostring(region_err))
		return
	end
	print(("[ogzport] region x%d..%d y%d..%d z%d..%d (%d textures, %.0f%% coverage)")
		:format(region.x0, region.x1, region.y0, region.y1, region.z0,
			region.z1, diversity, density * 100))

	local grid, stats = port.voxelize(map, region, prepared.resolve_slot)
	local solid, distinct, top = histogram_of(grid, names)
	print(("[ogzport] voxelized %d cells: %d solid (%.1f%%), %d shaped, %d liquid")
		:format(stats.cells, solid, solid / stats.cells * 100, stats.shaped,
			stats.liquid))
	print(("[ogzport] materials used: %d distinct; %s"):format(distinct, top))

	local spawn_x, spawn_y, spawn_z = port.pick_spawn(region,
		{x = region.x1 - region.x0, y = region.y1 - region.y0,
			z = region.z1 - region.z0}, grid)
	local lx, ly, lz = port.to_luanti(spawn_x, spawn_y, spawn_z)
	print(("[ogzport] spawn: sauer %d,%d,%d -> luanti %d,%d,%d")
		:format(spawn_x, spawn_y, spawn_z, lx, ly, lz))

	-- The payload keeps Sauerbraten axis order (the leaves' own space) and the
	-- importer applies `to_luanti` per axis. Converting here would mean
	-- negating an axis while keeping the same array stride, which only invites
	-- a transposed world.
	local payload = port.encode(grid, names, region, {
		map = mapname,
		spawn_luanti = string.format("%d,%d,%d", lx, ly, lz),
		payload_id = string.format("r%d:%s:%d:%d,%d,%d", CONVERTER_REVISION,
			mapname, solid, lx, ly, lz),
		region_sauer = string.format("%d,%d,%d - %d,%d,%d", region.x0,
			region.y0, region.z0, region.x1, region.y1, region.z1),
		worldsize = map.worldsize,
		version = map.version,
	})

	local out = assert(io.open(modpath .. "/payload.bin", "wb"),
		"cannot write payload")
	out:write(payload)
	out:close()
	print(("[ogzport] wrote %s (%.1f KiB) in %.1fs")
		:format(modpath .. "/payload.bin", #payload / 1024, os.clock() - started))

	local meta = assert(io.open(modpath .. "/meta.txt", "wb"))
	meta:write(("map=%s\nspawn_luanti=%d,%d,%d\nsize=%d\nsolid=%d\nversion=%d\n")
		:format(mapname, lx, ly, lz, size, solid, map.version))
	meta:close()

	for _, line in ipairs(port.preview({
		size = {x = region.x1 - region.x0, y = region.y1 - region.y0,
			z = region.z1 - region.z0},
		grid = grid, names = names,
	}, 4, 56)) do
		print("[ogzport] " .. line)
	end
	print("[ogzport] EXPORT DONE")
end)
