-- Entity-based rendering for micronode blocks
--
-- WHY: Luanti node definitions (node_box etc.) are static per node TYPE and
-- synced to clients once at connect time. There is no per-instance node
-- geometry in the modding API, so a node_box set in metadata never shows.
--
-- HOW: the container node is invisible (empty node_box) but keeps a full
-- selection box (pointing) and collision box (v1 simplified AABB). The
-- micronode geometry is rendered by one static entity per greedy-merged box,
-- scaled via visual_size and textured from the palette material.
-- Entities are static_save'd so they survive server restarts.

local M = micronode_chisel

-- Rendering budget: complex grids can produce hundreds of merged boxes.
-- Past this we fall back to one full-block box (still correct collision).
M.MAX_RENDER_BOXES = 48

local ENTITY_NAME = "micronode_chisel:box"

------------------------------------------------------------------------------
-- Entity definition
------------------------------------------------------------------------------

core.register_entity(ENTITY_NAME, {
	initial_properties = {
		physical = false,
		collide_with_objects = false,
		pointable = false,          -- raycast must hit the container node
		visual = "cube",
		visual_size = {x = 1, y = 1, z = 1},
		textures = {
			"default_stone.png", "default_stone.png", "default_stone.png",
			"default_stone.png", "default_stone.png", "default_stone.png",
		},
		static_save = true,         -- persist with the mapblock
		shaded = true,
	},

	on_activate = function(self, staticdata)
		if staticdata == "" or staticdata == nil then
			self.object:remove()
			return
		end
		local data = core.parse_json(staticdata)
		if not data or not data.sx or not data.texs then
			self.object:remove()
			return
		end
		self.block_pos = data.block_pos
		self._staticdata = staticdata
		self.object:set_properties({
			visual_size = {x = data.sx, y = data.sy, z = data.sz},
			textures = data.texs,
		})
	end,

	get_staticdata = function(self)
		return self._staticdata or ""
	end,
})

------------------------------------------------------------------------------
-- Entity management
------------------------------------------------------------------------------

-- Remove all render entities belonging to the block at pos
function M.remove_block_entities(pos)
	local center = vector.add(pos, vector.new(0.5, 0.5, 0.5))
	for _, obj in ipairs(core.get_objects_inside_radius(center, 1.3)) do
		local lua = obj:get_luaentity()
		if lua and lua.name == ENTITY_NAME and lua.block_pos
			and lua.block_pos.x == pos.x and lua.block_pos.y == pos.y
			and lua.block_pos.z == pos.z then
			obj:remove()
		end
	end
end

-- Spawn one static entity per merged box
-- boxes: list from generate_optimized_nodeboxes (coords in -0.5..0.5)
-- Engine facts (visual = "cube"): visual_size is in node units and the cube
-- is centered on the entity position. Each face maps its whole texture, so
-- textures must be cropped to the box's proportional region of the base
-- texture (like nodebox UV mapping does) to avoid stretching/warping.
local function crop_16(tex, u0, v0, u1, v1)
	-- Normalize to 16px so the crop is texture-pack agnostic
	local base = tex .. "^[resize:16x16"
	local x = math.floor(math.max(0, math.min(1, u0)) * 16 + 0.5)
	local y = math.floor(math.max(0, math.min(1, v0)) * 16 + 0.5)
	local w = math.max(1, math.floor(math.max(0, math.min(1, u1)) * 16 + 0.5) - x)
	local h = math.max(1, math.floor(math.max(0, math.min(1, v1)) * 16 + 0.5) - y)
	local escaped = base:gsub("([%^:])", "\\%1")
		-- [combine:WxH:x,y=tex blits tex at (x,y) ONTO the WxH canvas:
	-- cropping therefore uses negative offsets so the wanted region
	-- lands inside the canvas (see texture-modifier docs).
	return string.format("[combine:%dx%d:%d,%d=%s", w, h, -x, -y, escaped)
end

local function face_textures(tex, box)
	local tx0, tx1 = box.x0 + 0.5, box.x1 + 0.5
	local ty0, ty1 = box.y0 + 0.5, box.y1 + 0.5
	local tz0, tz1 = box.z0 + 0.5, box.z1 + 0.5
	-- Nodebox-style UV regions, texture order: +Y, -Y, +X, -X, +Z, -Z
	return {
		crop_16(tex, tx0, 1 - tz1, tx1, 1 - tz0),
		crop_16(tex, tx0, tz0, tx1, tz1),
		crop_16(tex, tz0, 1 - ty1, tz1, 1 - ty0),
		crop_16(tex, 1 - tz1, 1 - ty1, 1 - tz0, 1 - ty0),
		crop_16(tex, 1 - tx1, 1 - ty1, 1 - tx0, 1 - ty0),
		crop_16(tex, tx0, 1 - ty1, tx1, 1 - ty0),
	}
end

local FACE_EPSILON = 1 / 64

local function spawn_box(pos, box, texture)
	local sx = math.max(box.x1 - box.x0, FACE_EPSILON)
	local sy = math.max(box.y1 - box.y0, FACE_EPSILON)
	local sz = math.max(box.z1 - box.z0, FACE_EPSILON)
	-- Entity sits at the box center; the cube visual extends +/- size/2
	local center = vector.add(pos, vector.new(
		(box.x0 + box.x1) / 2 + 0.5,
		(box.y0 + box.y1) / 2 + 0.5,
		(box.z0 + box.z1) / 2 + 0.5))
	local data = core.write_json({
		block_pos = {x = pos.x, y = pos.y, z = pos.z},
		sx = sx,
		sy = sy,
		sz = sz,
		texs = face_textures(texture, box),
	})
	core.add_entity(center, ENTITY_NAME, data)
end

------------------------------------------------------------------------------
-- Visual refresh (overrides the placeholder in chisel.lua)
------------------------------------------------------------------------------

-- Rebuild the visible geometry of a chiseled block from its metadata
function M.update_block_mesh(pos)
	local meta = core.get_meta(pos)
	local data_str = meta:get_string(M.META_KEY_DATA)
	if data_str == "" then return end

	local block_data = M.deserialize_block_data({
		data = data_str,
		palette = meta:get_string(M.META_KEY_PALETTE),
		rotation = meta:get_string(M.META_KEY_ROTATION),
		base = meta:get_string(M.META_KEY_BASE),
	})

	local node = core.get_node(pos)

	-- Fully carved back out? Return to the base material (metadata is
	-- preserved by swap_node, so it stays a chiseled block underneath).
	if M.is_empty(block_data.grid) then
		M.remove_block_entities(pos)
		return
	end

	-- Fully solid? Swap back to the base node for cheap native rendering.
	if M.is_full(block_data.grid) then
		M.remove_block_entities(pos)
		if node.name ~= block_data.base and core.registered_nodes[block_data.base] then
			core.swap_node(pos, {name = block_data.base})
		end
		return
	end

	-- Partial: make sure the container node is in place, then render boxes
	if node.name ~= "micronode_chisel:chiseled_block" then
		core.swap_node(pos, {name = "micronode_chisel:chiseled_block"})
	end

	M.remove_block_entities(pos)

	local sides = solid_outside_sides(pos)
	local boxes = M.generate_surface_faces(block_data.grid, block_data.palette, sides)

	if #boxes == 0 then
		return
	end

	if #boxes > M.MAX_RENDER_BOXES then
		-- Too complex for the entity budget: render one solid box covering
		-- the block (collision is already full-block in v1).
		core.log("warning", "[micronode_chisel] " .. core.pos_to_string(pos)
			.. ": " .. #boxes .. " boxes exceeds render budget, using full block")
		spawn_box(pos,
			{x0 = -0.5, y0 = -0.5, z0 = -0.5, x1 = 0.5, y1 = 0.5, z1 = 0.5},
			M.get_texture(block_data.base))
		return
	end

	for _, box in ipairs(boxes) do
		spawn_box(pos, box, M.get_texture(box.material))
	end
end

print("[micronode_chisel] Entity rendering loaded")

------------------------------------------------------------------------------
-- Rebuild meshes on load
------------------------------------------------------------------------------

core.register_lbm({
	name = "micronode_chisel:rebuild_meshes",
	label = "Rebuild micronode render entities",
	nodenames = {"micronode_chisel:chiseled_block"},
	run_at_every_load = true,
	action = function(pos)
		M.update_block_mesh(pos)
	end,
})
