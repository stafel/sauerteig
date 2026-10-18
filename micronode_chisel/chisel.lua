-- Chisel tool, container nodes and commands.
--
-- Player verbs (Cube 2 flavoured: left = push, right = pull):
--   left click on a plain cube   -> convert it to a chiseled block
--   left click on a chiseled block -> push: add a grid-thick layer on the face
--   right click on a chiseled block -> pull: carve a grid-thick layer inwards
--   sneak + left                 -> cycle grid step (1 2 4 8 16 micronodes)
--   sneak + right                -> pick the material of the targeted node, or
--                                   cycle the palette of a chiseled block
--   aux1 + left / aux1 + right   -> rotate 90 deg / flip the block

local M = micronode_chisel

local state = {}

local function get_state(name)
	local st = state[name]
	if not st then
		st = {grid_idx = 1, material = nil, palette_idx = 0}
		state[name] = st
	end
	return st
end

local function grid_size(st)
	return M.GRID_SIZES[st.grid_idx] or 1
end

local function tell(name, text)
	core.chat_send_player(name, "[chisel] " .. text)
end

-- The tool is the instrument, the `chisel` privilege is the permission.
local function can_edit(name)
	if not core.check_player_privs then
		return true
	end
	return core.check_player_privs(name, {chisel = true}) == true
end

-------------------------------------------------------------------------------
-- Container nodes
-------------------------------------------------------------------------------
-- The container is invisible (airlike) and holds the grid in metadata. Two
-- variants exist because a node can only carry one collision behaviour:
--  * chiseled_block       solid cells >= COLLISION_SOLID_RATIO -> collidable
--  * chiseled_block_open  mostly carved -> walk-through (a doorway you carved
--                         is actually usable). Per-cell collision for nodes is
--                         not expressible in the Luanti node API.

local function drop_base(pos)
	local block = M.get_block(pos)
	local base = block and block.base
	if base and not M.is_air_name(base) and core.registered_items[base] then
		return base
	end
	return M.fallback_material_or_default()
end

local function container_def(description, walkable)
	return {
		description = description,
		drawtype = "airlike",
		paramtype = "light",
		sunlight_propagates = false,
		is_ground_content = false,
		walkable = walkable,
		pointable = true,
		tiles = {"micronode_chisel_placeholder.png"},
		groups = {cracky = 2, oddly_breakable_by_hand = 1,
			micronode_block = 1, not_in_creative_inventory = 1},
		selection_box = {type = "regular"},
		-- Collision only applies to walkable nodes, so the open variant simply
		-- has no collision box of its own (see collision.lua).
		collision_box = walkable and {type = "regular"} or nil,

		on_construct = function(pos)
			local meta = core.get_meta(pos)
			if meta:get_string(M.META_KEY_DATA) == "" then
				M.set_block(pos, M.create_block_data(M.fallback_material_or_default(),
					M.create_palette(nil), M.create_empty_grid()))
			end
		end,

		on_destruct = function(pos)
			M.remove_block_entities(pos)
			M.forget_block(pos)
		end,

		-- Drop the base material instead of the invisible container node.
		drop = "",

		on_dig = function(pos, node, digger)
			local base = drop_base(pos)
			M.remove_block_entities(pos)
			M.forget_block(pos)
			core.remove_node(pos)
			if digger and digger:is_player() then
				local stack = ItemStack(base)
				local inv = digger:get_inventory()
				if inv and inv:room_for_item("main", stack) then
					inv:add_item("main", stack)
				else
					core.add_item(pos, stack)
				end
			end
			return true
		end,
	}
end

core.register_node(M.BLOCK_NODE, container_def("Chiseled Block", true))
core.register_node(M.BLOCK_NODE_OPEN, container_def("Chiseled Block (open)", false))

-------------------------------------------------------------------------------
-- Tool
-------------------------------------------------------------------------------

core.register_tool("micronode_chisel:chisel", {
	description = "Micronode Chisel\n" ..
		"Left: chisel block / push material\n" ..
		"Right: pull (carve) material\n" ..
		"Sneak+Left: grid step\n" ..
		"Sneak+Right: pick or cycle material\n" ..
		"Aux1+Left: rotate, Aux1+Right: flip",
	inventory_image = "micronode_chisel_chisel.png",
	groups = {chisel = 1, not_in_creative_inventory = 1},

	on_use = function(itemstack, user, pointed_thing)
		if not user or not user:is_player() then
			return
		end
		local name = user:get_player_name()
		local st = get_state(name)
		if not pointed_thing or pointed_thing.type ~= "node" then
			return
		end
		local pos = pointed_thing.under
		local ctrl = user:get_player_control() or {}

		if not can_edit(name) then
			tell(name, "You need the 'chisel' privilege to edit blocks")
			return
		end

		if ctrl.sneak then
			st.grid_idx = (st.grid_idx % #M.GRID_SIZES) + 1
			tell(name, "Grid step: " .. M.GRID_NAMES[st.grid_idx]
				.. " (" .. grid_size(st) .. " micronodes)")
			return
		end

		if ctrl.aux1 then
			if M.rotate_block(pos, 1) then
				tell(name, "Block rotated 90 degrees")
			else
				tell(name, "Nothing to rotate here")
			end
			return
		end

		if not M.is_micronode_block(pos) then
			if not M.is_chiselable(pos) then
				tell(name, "This node cannot be chiseled")
				return
			end
			local block = M.chisel_native(pos)
			if not block then
				tell(name, "This node cannot be chiseled")
				return
			end
			st.material = block.base
			M.refresh_block(pos)
			tell(name, "Chiseled " .. block.base
				.. " - left adds, right carves, sneak+left changes the grid step")
			return
		end

		local ok, info = M.edit_at(user, pos, "push", grid_size(st), st.material)
		if ok then
			tell(name, "Pushed (" .. info .. " block touched)")
		else
			tell(name, tostring(info))
		end
	end,

	on_place = function(itemstack, user, pointed_thing)
		if not user or not user:is_player() then
			return itemstack
		end
		local name = user:get_player_name()
		local st = get_state(name)
		if not pointed_thing or pointed_thing.type ~= "node" then
			return itemstack
		end
		local pos = pointed_thing.under
		local ctrl = user:get_player_control() or {}

		if not can_edit(name) then
			tell(name, "You need the 'chisel' privilege to edit blocks")
			return itemstack
		end

		if ctrl.sneak then
			if M.is_micronode_block(pos) then
				local block = M.get_block(pos)
				if block then
					-- Cycle through the block's live palette slots.
					for _ = 1, M.MAX_MATERIALS do
						st.palette_idx = (st.palette_idx % M.MAX_MATERIALS) + 1
						local candidate = M.palette_get(block.palette, st.palette_idx)
						if not M.is_air_name(candidate) then
							st.material = candidate
							break
						end
					end
					tell(name, "Material: " .. tostring(st.material))
				end
			else
				local picked = core.get_node(pos).name
				if not M.is_air_name(picked) then
					st.material = picked
					tell(name, "Material: " .. picked)
				end
			end
			return itemstack
		end

		if ctrl.aux1 then
			if M.flip_block(pos) then
				tell(name, "Block flipped")
			else
				tell(name, "Nothing to flip here")
			end
			return itemstack
		end

		if M.is_micronode_block(pos) then
			local ok, info = M.edit_at(user, pos, "pull", grid_size(st), nil)
			if ok then
				tell(name, "Carved (" .. info .. " block touched)")
			else
				tell(name, tostring(info))
			end
		end
		return itemstack
	end,
})

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

core.register_chatcommand("chisel", {
	params = "",
	description = "Get the micronode chisel",
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local inv = player:get_inventory()
		if inv then
			inv:add_item("main", "micronode_chisel:chisel")
		end
		return true, "Chisel added to inventory"
	end,
})

core.register_chatcommand("mn_grid", {
	params = "[step]",
	description = "Show or set the chisel grid step (1, 2, 4, 8 or 16 micronodes)",
	func = function(name, param)
		local st = get_state(name)
		local step = tonumber(param)
		if step then
			for idx, size in ipairs(M.GRID_SIZES) do
				if size == step then
					st.grid_idx = idx
					break
				end
			end
		end
		return true, "Grid step: " .. M.GRID_NAMES[st.grid_idx]
			.. " (" .. grid_size(st) .. " micronodes)"
	end,
})

core.register_chatcommand("mn_material", {
	params = "[node]",
	description = "Show or set the material used when pushing",
	func = function(name, param)
		local st = get_state(name)
		if param and param ~= "" then
			if not core.registered_nodes[param] then
				return false, "Unknown node: " .. param
			end
			st.material = param
		end
		return true, "Material: " .. tostring(st.material or "(surface material)")
	end,
})

core.register_chatcommand("mn_info", {
	params = "",
	description = "Show info about the chiseled block you are pointing at",
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local pos = M.get_pointed_block(player)
		if not pos then
			return false, "Point at a chiseled block"
		end
		local info = M.get_block_info(pos)
		if not info then
			return false, "Point at a chiseled block"
		end
		return true, string.format(
			"base=%s fill=%d/%d (%.1f%%) palette=%s stored=%d bytes",
			info.base, info.solid_count, info.total_voxels, info.fill_percent,
			table.concat(info.palette, ","), info.stored_bytes)
	end,
})

core.register_chatcommand("mn_undo", {
	params = "",
	description = "Undo your last micronode edit",
	func = function(name)
		local ok, blocks = M.undo(name)
		if not ok then
			return false, "Nothing to undo"
		end
		return true, "Restored " .. blocks .. " block(s)"
	end,
})

core.register_chatcommand("mn_unchisel", {
	params = "",
	description = "Convert the chiseled block you are pointing at back to a plain node",
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local pos = M.get_pointed_block(player)
		if not pos then
			return false, "Point at a chiseled block"
		end
		local base = M.unchisel(pos)
		if not base then
			return false, "Point at a chiseled block"
		end
		return true, "Converted back to " .. base
	end,
})

-------------------------------------------------------------------------------
-- Session plumbing
-------------------------------------------------------------------------------

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	get_state(name)
	local inv = player:get_inventory()
	if inv and not inv:contains_item("main", "micronode_chisel:chisel") then
		inv:add_item("main", "micronode_chisel:chisel")
		tell(name, "Chisel added. Left click a block to chisel it.")
	end
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	state[name] = nil
	M.forget_player(name)
end)

print("[micronode_chisel] Chisel tool loaded")
