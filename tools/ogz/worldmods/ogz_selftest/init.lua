-- Runs tools/ogz/selftest.lua with the engine as the Lua host.
--
-- The world directory IS tools/ogz (see world.mt), which is what lets the mod
-- sandbox read the module at all: reads are only allowed under the world, mod,
-- game and mod_data paths. No `secure.trusted_mods` and no insecure
-- environment are involved.
--
-- Real .ogz files are outside the world path, so this host runs the synthetic
-- layer only. Real-map verification runs through tools/ogz/run.py instead.
local worldpath = core.get_worldpath()

local function load_module(name)
	local handle = assert(io.open(worldpath .. "/" .. name, "rb"),
		"cannot read " .. name)
	local source = handle:read("*a")
	handle:close()
	local chunk, err = loadstring(source, "@" .. name)
	assert(chunk, err)
	return chunk()
end

core.after(0.2, function()
	print("[ogz] ---- in-engine selftest ----")
	local ok, ogz = pcall(load_module, "ogz.lua")
	if not ok then
		print("[ogz] FAIL loading ogz.lua: " .. tostring(ogz))
		return
	end
	local ok2, selftest = pcall(load_module, "selftest.lua")
	if not ok2 then
		print("[ogz] FAIL loading selftest.lua: " .. tostring(selftest))
		return
	end
	local ok3, compare = pcall(load_module, "compare.lua")

	local ran, result = pcall(selftest, ogz, {}, {compare = ok3 and compare or nil})
	if not ran then
		print("[ogz] FAIL selftest raised: " .. tostring(result))
		return
	end
	print(("[ogz] %d failure(s)"):format(#result))
	for _, failure in ipairs(result) do
		print("[ogz] FAIL " .. failure)
	end
	if #result == 0 then
		print("[ogz] ALL CHECKS PASSED")
	end
end)
