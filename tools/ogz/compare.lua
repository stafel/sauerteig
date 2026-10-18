-- Leaf-for-leaf comparison against the engine's own octree dump.
--
-- Used by the Option C oracle (tools/ogz/oracle/README.md): that patch makes the
-- Sauerbraten client write every leaf as
--   <x> <y> <z> <size> <12 edge bytes as %02x> <6 texture slots> <material>
-- and this reads the same map with tools/ogz/ogz.lua and diffs the two.
--
-- It is also usable as a self-check: `M.format_dump(leaves)` renders our leaves
-- in that exact format, so compare(our_dump, our_dump) must be empty. That is
-- what the in-engine selftest asserts, which keeps the comparator honest.
local M = {}

local function leaf_key(x, y, z, size)
	return string.format("%d,%d,%d,%d", x, y, z, size)
end

-- Render leaves in the engine dump's format.
function M.format_dump(leaves)
	local out = {}
	for _, leaf in ipairs(leaves) do
		local parts = {
			leaf.x, leaf.y, leaf.z, leaf.size,
		}
		for i = 1, 12 do
			parts[#parts + 1] = string.format("%02x", leaf.edges:byte(i))
		end
		for i = 1, 6 do
			parts[#parts + 1] = tostring(leaf.texture[i])
		end
		parts[#parts + 1] = tostring(leaf.material)
		out[#out + 1] = table.concat(parts, " ")
	end
	return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

-- Parse engine dump text into a key -> record map. Empty leaves are dropped:
-- the reader does not store them, so keeping them would report false extras.
function M.parse_dump(text)
	local records = {}
	local skipped_empty = 0
	for line in text:gmatch("[^\r\n]+") do
		if not line:match("^%s*$") and not line:match("^%s*#") then
			local fields = {}
			for field in line:gmatch("%S+") do fields[#fields + 1] = field end
			if #fields ~= 4 + 12 + 6 + 1 then
				return nil, string.format("malformed dump line (%d fields): %s",
					#fields, line)
			end
			local x, y, z, size = tonumber(fields[1]), tonumber(fields[2]),
				tonumber(fields[3]), tonumber(fields[4])
			if not (x and y and z and size) then
				return nil, "malformed coordinates: " .. line
			end
			local edges = {}
			local all_zero = true
			for i = 1, 12 do
				local byte = tonumber(fields[4 + i], 16)
				if byte == nil then return nil, "bad edge byte: " .. line end
				edges[i] = byte
				if byte ~= 0 then all_zero = false end
			end
			local material = tonumber(fields[#fields])
			if material == nil then return nil, "bad material: " .. line end
			if all_zero and material == 0 then
				skipped_empty = skipped_empty + 1
			else
				local texture = {}
				for i = 1, 6 do texture[i] = tonumber(fields[16 + i]) end
				records[leaf_key(x, y, z, size)] = {
					x = x, y = y, z = z, size = size,
					edges = edges, texture = texture, material = material,
				}
			end
		end
	end
	return records, nil, skipped_empty
end

-- Compare engine dump text against our reader's leaves.
-- opts.max_report limits how many individual mismatches are listed.
-- Returns failures (array of strings), plus a stats table.
function M.compare(dump_text, leaves, opts)
	opts = opts or {}
	local max_report = opts.max_report or 8
	local failures = {}

	local expected, parse_err = M.parse_dump(dump_text)
	if not expected then
		return {"dump unreadable: " .. tostring(parse_err)}, {}
	end

	local actual = {}
	for _, leaf in ipairs(leaves) do
		if not leaf.is_empty() then
			actual[leaf_key(leaf.x, leaf.y, leaf.z, leaf.size)] = leaf
		end
	end

	local missing, extra, mismatched = 0, 0, 0
	local samples = {}
	local function note(text)
		if #samples < max_report then samples[#samples + 1] = text end
	end

	for key, want in pairs(expected) do
		local got = actual[key]
		if not got then
			missing = missing + 1
			note("missing in reader: " .. key)
		else
			local bad = nil
			for i = 1, 12 do
				if got.edges:byte(i) ~= want.edges[i] then
					bad = ("edge[%d] %02x vs %02x"):format(i,
						want.edges[i], got.edges:byte(i))
					break
				end
			end
			if not bad and got.material ~= want.material then
				bad = ("material %d vs %d"):format(want.material, got.material)
			end
			if not bad then
				for i = 1, 6 do
					if got.texture[i] ~= want.texture[i] then
						bad = ("texture[%d] %s vs %s"):format(i,
							tostring(want.texture[i]), tostring(got.texture[i]))
						break
					end
				end
			end
			if bad then
				mismatched = mismatched + 1
				note("mismatch at " .. key .. ": " .. bad)
			end
		end
	end

	for key in pairs(actual) do
		if not expected[key] then
			extra = extra + 1
			note("extra in reader: " .. key)
		end
	end

	local stats = {
		expected = 0, actual = 0,
		missing = missing, extra = extra, mismatched = mismatched,
	}
	for _ in pairs(expected) do stats.expected = stats.expected + 1 end
	for _ in pairs(actual) do stats.actual = stats.actual + 1 end

	if missing + extra + mismatched > 0 then
		failures[#failures + 1] = ("%d missing, %d extra, %d mismatched")
			:format(missing, extra, mismatched)
		for _, sample in ipairs(samples) do
			failures[#failures + 1] = sample
		end
	end
	return failures, stats
end

--- CLI: read a dump, read the map, diff -------------------------------------

-- Standalone use needs a raw-inflate implementation for the map. Lua has none,
-- so the CLI expects the dump plus a *reader dump* produced by whichever host
-- can inflate (the in-engine harness, or tools/ogz/selftest.lua's host).
-- In practice the in-engine harness is the supported path; this function exists
-- so the same comparison can be driven from a script that has inflate.
function M.run(dump_path, ogz, ogz_path, opts)
	opts = opts or {}
	local io_impl = opts.io or io
	local handle = assert(io_impl.open(dump_path, "rb"))
	local dump_text = handle:read("*a")
	handle:close()
	local map = ogz.read(ogz_path, opts)
	return M.compare(dump_text, map.leaves, opts)
end

return M
