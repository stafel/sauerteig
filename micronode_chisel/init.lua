-- micronode_chisel: sub-node editing for Luanti.
--
-- A 1 m node is replaced by a chiseled block that stores a 16^3 grid of
-- micronodes (6.25 cm) plus a palette of up to 4 materials. Editing is
-- Sauerbraten-flavoured: pick a grid step, then push (extrude a face) or pull
-- (carve into it); only exposed surfaces are rendered, greedily merged, so a
-- chiseled block reads as one continuous solid and each edit is a small
-- metadata write.
--
-- Module map:
--   data.lua      grid, palette, RLE storage, transforms, textures
--   collision.lua solid vs walk-through container variant
--   mesh.lua      exposed-surface extraction and greedy merging
--   edit.lua      block access, picking, brushes, undo, region application
--   entities.lua  render entity lifecycle (cube visual, centered transform)
--   render.lua    face texture crops and per-block mesh rebuild
--   chisel.lua    container nodes, chisel tool, commands
--   api.lua       public API for other mods
--   test.lua      in-engine self tests (server start)
--
-- Engineering notes, ground truth about entity visuals and the failure history
-- of earlier attempts: docs/micronode-findings.md

micronode_chisel = {}
local M = micronode_chisel

M.VERSION = "2.3.0"

local modpath = core.get_modpath("micronode_chisel")
for _, file in ipairs({
	"data.lua",
	"collision.lua",
	"mesh.lua",
	"edit.lua",
	"entities.lua",
	"render.lua",
	"clipboard.lua",
	"chisel.lua",
	"api.lua",
}) do
	dofile(modpath .. "/" .. file)
end

core.register_privilege("chisel", {
	description = "Can use the micronode chisel to edit blocks",
	give_to_singleplayer = true,
	give_to_admin = true,
})

-- Resolve the game-agnostic fallback material once everything is loaded.
core.register_on_mods_loaded(function()
	M.fallback_material = M.get_fallback_material()
	print("[micronode_chisel] fallback material: " .. tostring(M.fallback_material))
end)

local run_tests = true
if core.settings then
	run_tests = core.settings:get_bool("micronode_chisel.tests", true)
end
if run_tests then
	dofile(modpath .. "/test.lua")
end

print("[micronode_chisel] v" .. M.VERSION .. " loaded ("
	.. M.RESOLUTION .. "^3 micronodes per block, "
	.. M.MAX_MATERIALS .. " materials per block)")

-- Export for other mods
_G.micronode_chisel = M
