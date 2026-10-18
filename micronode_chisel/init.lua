-- Micronode Chisel Mod
-- Sub-node editing with 16³ micronodes (6.25cm resolution) per block
-- Vintage Story-style chiseling for Luanti
--
-- Features:
--   - 16×16×16 = 4,096 micronodes per block
--   - Up to 4 materials per chiseled block
--   - RLE compression (up to 512x for solid blocks)
--   - Grid sizes: 1, 2, 4, 8, 16 micronodes
--   - Rotation and flip
--   - Simplified AABB collision (v1)
--   - Full Lua API for other mods

micronode_chisel = {}

-- Load modules in order
dofile(core.get_modpath("micronode_chisel") .. "/data.lua")
dofile(core.get_modpath("micronode_chisel") .. "/render.lua")
dofile(core.get_modpath("micronode_chisel") .. "/collision.lua")
dofile(core.get_modpath("micronode_chisel") .. "/chisel.lua")
dofile(core.get_modpath("micronode_chisel") .. "/api.lua")
dofile(core.get_modpath("micronode_chisel") .. "/entities.lua")
dofile(core.get_modpath("micronode_chisel") .. "/test.lua")

-- Mod info
local mod_version = "1.0.0"
local mod_name = core.get_current_modname()

print("[micronode_chisel] ========================================")
print("[micronode_chisel] Micronode Chisel v" .. mod_version)
print("[micronode_chisel] Resolution: 16³ = 4,096 micronodes per block")
print("[micronode_chisel] Precision: 6.25cm (1/16 meter)")
print("[micronode_chisel] Max materials per block: 4")
print("[micronode_chisel] ========================================")

-- Register privilege for chisel usage
core.register_privilege("chisel", {
	description = "Can use micronode chisel to edit blocks",
	give_to_singleplayer = true,
	give_to_admin = true,
})

-- Cache game-agnostic fallback material once all mods are loaded
core.register_on_mods_loaded(function()
	micronode_chisel.fallback_material = micronode_chisel.get_fallback_material()
	print("[micronode_chisel] Fallback material: " .. micronode_chisel.fallback_material)
end)

-- Export for other mods
_G.micronode_chisel = micronode_chisel
