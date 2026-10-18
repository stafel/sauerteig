-- Chisel tool, container nodes and commands.
--
-- Player verbs (Cube 2 flavoured: left = push, right = pull):
--   left click on a plain cube   -> convert it to a chiseled block
--   left click on a chiseled block -> push: add a grid-thick layer on the face
--   right click on a chiseled block -> pull: carve a grid-thick layer inwards
--   sneak + left                 -> cycle grid step (1 2 4 8 16 micronodes)
--   right click in air           -> open the size/clipboard menu
--   sneak + right                -> pick the material of the targeted node, or
--                                   cycle the palette of a chiseled block
--   aux1 + left / aux1 + right   -> rotate 90 deg / flip the block
--   sneak + aux1 + left          -> copy the targeted chiseled block
--   sneak + aux1 + right         -> paste it (current rotation/flip)
--
-- The grid step is per player, applied to the brush (both the layer thickness
-- and the in-plane extent), and persisted in player metadata so it survives a
-- reconnect. The clipboard (clipboard.lua) is persisted the same way.

local M = micronode_chisel

local META_GRID_INDEX = "micronode_chisel:grid_index"
local META_MATERIAL = "micronode_chisel:material"
local SIZE_FORMNAME = "micronode_chisel:size"

local state = {}

local function grid_size(st)
	return M.GRID_SIZES[st.grid_idx] or 1
end

local function tell(name, text)
	core.chat_send_player(name, "[chisel] " .. text)
end

local function grid_label(idx)
	return M.GRID_NAMES[idx] .. " (" .. M.GRID_SIZES[idx] .. " micronodes)"
end

-- Player metadata is optional: tests and non-player callers do not have it.
local function save_state(name)
	local st = state[name]
	local player = core.get_player_by_name and core.get_player_by_name(name)
	if not st or not player or not player.get_meta then
		return
	end
	local meta = player:get_meta()
	meta:set_string(META_GRID_INDEX, tostring(st.grid_idx))
	meta:set_string(META_MATERIAL, st.material or "")
end

local function get_state(name)
	local st = state[name]
	if st then
		return st
	end
	st = {grid_idx = 1, material = nil, palette_idx = 0}
	local player = core.get_player_by_name and core.get_player_by_name(name)
	if player and player.get_meta then
		local meta = player:get_meta()
		local idx = tonumber(meta:get_string(META_GRID_INDEX))
		if idx and M.GRID_SIZES[idx] then
			st.grid_idx = idx
		end
		local material = meta:get_string(META_MATERIAL)
		if material and material ~= "" then
			st.material = material
		end
	end
	state[name] = st
	return st
end

-------------------------------------------------------------------------------
-- Grid-step selection (also used by tests and other mods)
-------------------------------------------------------------------------------

function M.player_grid_index(name)
	return get_state(name).grid_idx
end

function M.player_grid_size(name)
	return grid_size(get_state(name))
end

-- Set the step by micronode count (1, 2, 4, 8, 16). Returns false when the
-- value is not one of the supported steps.
function M.set_player_grid_size(name, step)
	for idx, size in ipairs(M.GRID_SIZES) do
		if size == step then
			get_state(name).grid_idx = idx
			save_state(name)
			return true
		end
	end
	return false
end

-- Cycle the step (delta=1 follows the 1 -> 2 -> 4 -> 8 -> 16 -> 1 order).
function M.cycle_player_grid(name, delta)
	local st = get_state(name)
	local count = #M.GRID_SIZES
	st.grid_idx = ((st.grid_idx - 1 + (delta or 1)) % count) + 1
	save_state(name)
	return st.grid_idx
end

function M.set_player_material(name, material)
	get_state(name).material = material
	save_state(name)
end

-------------------------------------------------------------------------------
-- Size menu
-------------------------------------------------------------------------------
-- Opened by right-clicking air. The sneaking key combos stay available, but
-- this makes the sizes visible and clickable instead of hidden behind a
-- gesture (the earlier implementation only exposed them that way).

function M.show_size_menu(player)
	local name = player:get_player_name()
	local st = get_state(name)
	local parts = {
		"formspec_version[4]",
		"size[8.6,7.0]",
		"label[0.4,0.3;Chisel size]",
	}
	local x = 0.4
	for idx, label in ipairs(M.GRID_NAMES) do
		local marked = (idx == st.grid_idx) and " *" or ""
		parts[#parts + 1] = string.format(
			"button[%.2f,0.8;1.55,0.9;size_%d;%s%s]",
			x, idx, label, marked)
		x = x + 1.6
	end
	parts[#parts + 1] = "label[0.4,2.0;1/16 = one micronode (6.25 cm), 1/1 = the whole node]"
	parts[#parts + 1] = "label[0.4,2.5;Material: " .. tostring(st.material or "(surface or picked)") .. "]"
	parts[#parts + 1] = "label[0.4,3.0;Left click: push / chisel.  Right click: carve.]"
	parts[#parts + 1] = "label[0.4,3.5;Sneak+Left on a block still cycles the size.]"
	parts[#parts + 1] = "label[0.4,4.2;Clipboard: " .. M.clipboard_label(name) .. "]"
	parts[#parts + 1] = "button[0.4,4.6;2.4,0.8;clip_rot;Rotate 90]"
	parts[#parts + 1] = "button[3.0,4.6;2.4,0.8;clip_flip;Flip]"
	parts[#parts + 1] = "label[0.4,5.6;Sneak+Aux1+Left copies, Sneak+Aux1+Right pastes.]"
	parts[#parts + 1] = "button_exit[2.8,6.2;3,0.6;close;Close]"
	core.show_formspec(name, SIZE_FORMNAME, table.concat(parts))
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
-- The container is invisible (airlike) and holds the grid in metadata. One node
-- type per recognised collision shape: a collision box is a per-type property
-- and the engine supports a list of boxes per type, so a recognised staircase
-- is a variant with two boxes (see collision.lua). The empty shape is the one
-- non-walkable variant, which is what makes a carved-out block passable.

local function drop_base(pos)
	local block = M.get_block(pos)
	local base = block and block.base
	if base and not M.is_air_name(base) and core.registered_items[base] then
		return base
	end
	return M.fallback_material_or_default()
end

-- `nodeboxes` is a list of node-local aabbs for the collision shape. A
-- collision box is a per-node-*type* property, so each recognised shape gets
-- its own variant node (see collision.lua); several boxes per type are
-- supported by the engine (`collision_box = {type = "fixed", fixed = {...}}`).
local function container_def(description, walkable, nodeboxes)
	local def = {
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
		-- Pointable across the whole node volume: otherwise the empty part of a
		-- carved block would not be clickable and could not be pushed into.
		selection_box = {type = "regular"},

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

	-- Collision only applies to walkable nodes, so the empty variant simply has
	-- no collision box of its own.
	if walkable then
		if nodeboxes and #nodeboxes > 0 then
			def.collision_box = {type = "fixed", fixed = nodeboxes}
		else
			def.collision_box = {type = "regular"}
		end
	end
	return def
end

core.register_node(M.BLOCK_NODE, container_def("Chiseled Block", true))
core.register_node(M.BLOCK_NODE_OPEN, container_def("Chiseled Block (open)", false))

-- One variant per recognised collision shape (slabs, stairs, panels, posts...).
for _, shape in ipairs(M.get_shapes()) do
	if not M.CONTAINER_NODES[M.shape_node_name(shape.id)] then
		error("shape node " .. M.shape_node_name(shape.id) .. " is not a container")
	end
	if shape.id ~= "full" and shape.id ~= "empty" then
		local label = "Chiseled Block (" .. shape.id:gsub("_", " ") .. ")"
		core.register_node(M.shape_node_name(shape.id),
			container_def(label, true, shape.nodeboxes))
	end
end

-------------------------------------------------------------------------------
-- Tool
-------------------------------------------------------------------------------

core.register_tool("micronode_chisel:chisel", {
	description = "Micronode Chisel\n" ..
		"Left: chisel block / push material\n" ..
		"Right: carve material\n" ..
		"Right-click air: size and clipboard menu\n" ..
		"Sneak+Left: cycle size\n" ..
		"Sneak+Right: pick or cycle material\n" ..
		"Aux1+Left: rotate, Aux1+Right: flip\n" ..
		"Sneak+Aux1+Left: copy block\n" ..
		"Sneak+Aux1+Right: paste block",
	inventory_image = "micronode_chisel_chisel.png",
	groups = {chisel = 1},

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

		-- sneak+aux1+left copies the targeted block. Checked before the plain
		-- sneak/aux1 verbs so the modifier combination wins.
		if ctrl.sneak and ctrl.aux1 then
			local ok, message = M.copy_block(name, pos)
			tell(name, message)
			if ok then
				tell(name, "Paste with sneak+aux1+right (" .. M.clipboard_label(name) .. ")")
			end
			return
		end

		if ctrl.sneak then
			M.cycle_player_grid(name, 1)
			tell(name, "Grid step: " .. grid_label(M.player_grid_index(name)))
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
			M.set_player_material(name, block.base)
			M.refresh_block(pos)
			tell(name, "Chiseled " .. block.base .. " (size "
				.. grid_label(M.player_grid_index(name)) .. ")"
				.. " - left adds, right carves, right-click air opens the size menu")
			return
		end

		local ok, info = M.edit_at(user, pos, "push", grid_size(st), st.material)
		if ok then
			tell(name, "Pushed " .. grid_label(M.player_grid_index(name))
				.. " (" .. info .. " block touched)")
		else
			tell(name, tostring(info))
		end
	end,

	-- Right-click in air opens the size menu. Pointing at a node goes through
	-- on_place instead, so this does not steal the push/pull verbs.
	on_secondary_use = function(itemstack, user)
		if not user or not user:is_player() then
			return itemstack
		end
		local name = user:get_player_name()
		M.show_size_menu(user)
		tell(name, "Current size: " .. grid_label(M.player_grid_index(name)))
		return itemstack
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

		-- sneak+aux1+right pastes the clipboard, overwriting or converting the
		-- targeted node.
		if ctrl.sneak and ctrl.aux1 then
			local ok, message = M.paste_block(name, pos, {player = name})
			tell(name, message)
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
							M.set_player_material(name, candidate)
							break
						end
					end
					tell(name, "Material: " .. tostring(st.material))
				end
			else
				local picked = core.get_node(pos).name
				if not M.is_air_name(picked) then
					M.set_player_material(name, picked)
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
				tell(name, "Carved " .. grid_label(M.player_grid_index(name))
					.. " (" .. info .. " block touched)")
			else
				tell(name, tostring(info))
			end
		end
		return itemstack
	end,
})

-- Size menu clicks. Re-rendering the menu after a click keeps the active step
-- and the clipboard state visible without closing and reopening it.
core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= SIZE_FORMNAME then
		return false
	end
	local name = player:get_player_name()
	if fields.clip_rot then
		M.rotate_clipboard(name, 1)
		M.show_size_menu(player)
		return true
	end
	if fields.clip_flip then
		M.flip_clipboard(name)
		M.show_size_menu(player)
		return true
	end
	for idx = 1, #M.GRID_SIZES do
		if fields["size_" .. idx] then
			get_state(name).grid_idx = idx
			save_state(name)
			M.show_size_menu(player)
			return true
		end
	end
	return false
end)

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

core.register_chatcommand("mn_menu", {
	params = "",
	description = "Open the chisel size menu",
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		M.show_size_menu(player)
		return true, "Current size: " .. grid_label(M.player_grid_index(name))
	end,
})

core.register_chatcommand("mn_grid", {
	params = "[step]",
	description = "Show or set the chisel grid step (1, 2, 4, 8, 16 micronodes or 1/16 .. 1/1)",
	func = function(name, param)
		if param and param ~= "" then
			local step = tonumber(param)
			if not step then
				for idx, label in ipairs(M.GRID_NAMES) do
					if label == param then
						step = M.GRID_SIZES[idx]
						break
					end
				end
			end
			if not step or not M.set_player_grid_size(name, step) then
				return false, "Grid step must be 1, 2, 4, 8, 16 or 1/16, 1/8, 1/4, 1/2, 1/1"
			end
		end
		return true, "Grid step: " .. grid_label(M.player_grid_index(name))
	end,
})

local function budget_label()
	local budget = M.render_budget()
	if budget == math.huge then
		return "unlimited"
	end
	return tostring(budget)
end

core.register_chatcommand("mn_budget", {
	params = "[boxes]",
	description = "Show or set the per-block render box budget (0 = unlimited)",
	func = function(name, param)
		if core.check_player_privs
			and not core.check_player_privs(name, {server = true}) then
			return false, "You need the 'server' privilege"
		end
		if not param or param == "" then
			return true, "Render budget: " .. budget_label()
				.. " boxes/block (0 = unlimited)"
		end
		local value = tonumber(param)
		if not value or value < 0 then
			return false, "Budget must be a number >= 0 (0 = unlimited)"
		end
		if not core.settings then
			return false, "No settings available on this server"
		end
		core.settings:set("micronode_chisel.max_render_boxes",
			tostring(math.floor(value)))
		local refreshed = M.refresh_all_rendered()
		return true, "Render budget: " .. budget_label()
			.. " boxes/block for this session; re-meshed " .. refreshed
			.. " block(s). Set micronode_chisel.max_render_boxes in minetest.conf to persist."
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
			M.set_player_material(name, param)
		end
		return true, "Material: " .. tostring(st.material or "(surface material)")
	end,
})

core.register_chatcommand("mn_copy", {
	params = "",
	description = "Copy the chiseled block you are pointing at",
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local pos = M.get_pointed_block(player)
		if not pos then
			return false, "Point at a chiseled block"
		end
		local ok, message = M.copy_block(name, pos)
		return ok, message
	end,
})

core.register_chatcommand("mn_paste", {
	params = "[0|90|180|270] [flip]",
	description = "Paste the copied block onto the node you are pointing at",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		if M.clipboard_is_empty(name) then
			return false, "Clipboard is empty: /mn_copy a chiseled block first"
		end
		local pos = M.get_pointed_node(player)
		if not pos then
			return false, "Point at a node"
		end

		local rotate, flip = M.get_clipboard(name).rotate or 0, nil
		for word in string.gmatch(param or "", "%S+") do
			local degrees = tonumber(word)
			if degrees then
				if degrees % 90 ~= 0 then
					return false, "Rotation must be 0, 90, 180 or 270"
				end
				rotate = math.floor(degrees / 90) % 4
			elseif word == "flip" then
				flip = true
			else
				return false, "Usage: /mn_paste [0|90|180|270] [flip]"
			end
		end

		return M.paste_block(name, pos, {player = name, rotate = rotate, flip = flip})
	end,
})

core.register_chatcommand("mn_clip", {
	params = "[rot|flip]",
	description = "Show the clipboard, or cycle its rotation / toggle its flip",
	func = function(name, param)
		if param == "rot" then
			local clip = M.rotate_clipboard(name, 1)
			return true, "Paste rotation: " .. tostring(clip.rotate * 90) .. " deg"
		elseif param == "flip" then
			local clip = M.flip_clipboard(name)
			return true, "Paste flip: " .. (clip.flip and "on" or "off")
		end
		return true, "Clipboard: " .. M.clipboard_label(name)
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
			"base=%s fill=%d/%d (%.1f%%) palette=%s stored=%d bytes collision=%s "
				.. "(%d box(es)%s)",
			info.base, info.solid_count, info.total_voxels, info.fill_percent,
			table.concat(info.palette, ","), info.stored_bytes,
			info.collision_shape, info.collision_boxes,
			info.collision_recognised
				and string.format(", %.0f%% match", info.collision_iou * 100)
				or ", fill-ratio fallback")
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
		tell(name, "Chisel added. Left click a block to chisel it, right-click air for the size menu.")
	end
	tell(name, "Chisel size: " .. grid_label(M.player_grid_index(name))
		.. " - sneak+left or right-click air changes it.")
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	save_state(name)
	state[name] = nil
	M.forget_clipboard(name)
	M.forget_player(name)
end)

print("[micronode_chisel] Chisel tool loaded")
