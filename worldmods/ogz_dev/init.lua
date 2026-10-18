-- Runs tools/ogz/selftest.lua against the whole Sauerbraten map corpus,
-- in-engine.
--
-- The world directory is the repository root (see world.mt) so the mod sandbox
-- allows reading the module, the corpus manifest and the maps. No
-- `secure.trusted_mods` and no insecure environment are involved.
local world = core.get_worldpath()

local function load_module(relpath)
	local handle = assert(io.open(world .. "/" .. relpath, "rb"),
		"cannot read " .. relpath)
	local source = handle:read("*a")
	handle:close()
	local chunk, err = loadstring(source, "@" .. relpath)
	assert(chunk, err)
	return chunk()
end

local function read_manifest(relpath)
	local handle = assert(io.open(world .. "/" .. relpath, "rb"),
		"cannot read " .. relpath)
	local names = {}
	for line in handle:lines() do
		line = line:gsub("#.*$", ""):gsub("%s+$", "")
		if line ~= "" then names[#names + 1] = line end
	end
	handle:close()
	return names
end

core.after(0.2, function()
	print("[ogz] ---- corpus verification ----")
	local ok, ogz = pcall(load_module, "tools/ogz/ogz.lua")
	if not ok then
		print("[ogz] FAIL loading ogz.lua: " .. tostring(ogz))
		return
	end
	local ok2, selftest = pcall(load_module, "tools/ogz/selftest.lua")
	if not ok2 then
		print("[ogz] FAIL loading selftest.lua: " .. tostring(selftest))
		return
	end

	local maps = {}
	for _, name in ipairs(read_manifest("tools/ogz/corpus.txt")) do
		maps[#maps + 1] = world .. "/sauerbraten/packages/base/" .. name .. ".ogz"
	end

	local started = os.clock()
	local ran, result = pcall(selftest, ogz, maps, {
		io = io,
		inflate_raw = function(bytes)
			return core.decompress(bytes, "raw_deflate")
		end,
	})
	if not ran then
		print("[ogz] FAIL selftest raised: " .. tostring(result))
		return
	end
	print(("[ogz] %d failure(s) in %.1fs"):format(#result, os.clock() - started))
	for _, failure in ipairs(result) do
		print("[ogz] FAIL " .. failure)
	end
	if #result == 0 then
		print("[ogz] ALL CHECKS PASSED")
	end
end)
