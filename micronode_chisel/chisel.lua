-- Chisel Tool Implementation
-- Converts regular nodes to micronode blocks and allows editing

local M = micronode_chisel

-- Per-player state
local player_state = {}

local function get_state(name)
	local st = player_state[name]
	if not st then
		st = {
			chisel_mode = false,     -- Is player in chisel editing mode?
			target_pos = nil,        -- Position of block being chiseled
			grid_size_idx = 3,       -- Index into M.GRID_SIZES (4 = default)
			material_idx = 1,        -- Active material index (1-4)
			palette = nil,           -- Current palette for editing
			undo_stack = {},         -- Undo history
			undo_idx = 0,
		}
		player_state[name] = st
	end
	return st
end

local function get_grid_size(st)
	return M.GRID_SIZES[st.grid_size_idx]
end

-- Check if a node can be chiseled (is solid)
local function is_chiselable(pos)
	local node = core.get_node(pos)
	local def = core.registered_nodes[node.name]
	if not def then return false end
	if node.name == "air" or node.name == "ignore" then return false end
	-- Check if it's a solid, full cube node
	local drawtype = def.drawtype or "normal"
	if drawtype == "normal" or drawtype == "allfaces" or drawtype == "allfaces_optional" then
		return true
	end
	return false
end

-- Check if a node is a micronode block
function M.is_micronode_block(pos)
	local meta = core.get_meta(pos)
	return meta:get_string(M.META_KEY_DATA) ~= ""
end

-- Convert a regular node to a micronode block
function M.chisel_block(pos, player_name)
	local node = core.get_node(pos)
	local def = core.registered_nodes[node.name]

	if not def then
		core.chat_send_player(player_name, "Cannot chisel unknown node")
		return false
	end

	if node.name == "air" or node.name == "ignore" then
		core.chat_send_player(player_name, "Cannot chisel air")
		return false
	end

	-- Create initial grid: all solid with base material
	local palette = M.create_palette({node.name})
	local grid = M.create_filled_grid(1)  -- All material index 1

	-- Store in node metadata
	local meta = core.get_meta(pos)
	local block_data = M.create_block_data(node.name, palette, grid, 0)
	local serialized = M.serialize_block_data(block_data)

	meta:set_string(M.META_KEY_DATA, serialized.data)
	meta:set_string(M.META_KEY_PALETTE, serialized.palette)
	meta:set_string(M.META_KEY_ROTATION, serialized.rotation)
	meta:set_string(M.META_KEY_BASE, serialized.base)

	-- Change node to micronode container node
	core.swap_node(pos, {name = "micronode_chisel:chiseled_block", param2 = 0})

	-- Update mesh
	M.update_block_mesh(pos)

	core.chat_send_player(player_name, "Block chiseled! 16³ micronodes created.")
	return true
end

-- Update the visual mesh of a micronode block
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

	-- Generate nodeboxes
	local nodeboxes = M.get_nodebox_list(block_data.grid, block_data.palette)

	-- Update the node definition dynamically
	-- Note: This is a simplified approach. In production, we'd use a node with
	-- dynamic nodeboxes via after_place_node or similar

	-- For now, we store the nodebox data in metadata and use a custom on_activate
	meta:set_string("mn_nodeboxes", core.serialize(nodeboxes))

	-- Force mesh update
	core.after(0, function()
		core.after(0.1, function()
			-- Trigger block update by modifying and restoring
			local node = core.get_node(pos)
			core.swap_node(pos, node)
		end)
	end)
end

-- Edit micronodes: add or remove voxels
function M.edit_micronodes(pos, mx, my, mz, grid_size, material_idx, add)
	local meta = core.get_meta(pos)
	local data_str = meta:get_string(M.META_KEY_DATA)
	if data_str == "" then return false end

	local block_data = M.deserialize_block_data({
		data = data_str,
		palette = meta:get_string(M.META_KEY_PALETTE),
		rotation = meta:get_string(M.META_KEY_ROTATION),
		base = meta:get_string(M.META_KEY_BASE),
	})

	-- Save undo state
	M.save_undo(pos, block_data)

	-- Edit the grid
	local gs = grid_size or 1
	local x1 = math.max(1, mx - math.floor((gs - 1) / 2))
	local y1 = math.max(1, my - math.floor((gs - 1) / 2))
	local z1 = math.max(1, mz - math.floor((gs - 1) / 2))
	local x2 = math.min(M.RESOLUTION, x1 + gs - 1)
	local y2 = math.min(M.RESOLUTION, y1 + gs - 1)
	local z2 = math.min(M.RESOLUTION, z1 + gs - 1)

	if add then
		M.fill_box(block_data.grid, x1, y1, z1, x2, y2, z2, material_idx)
	else
		M.fill_box(block_data.grid, x1, y1, z1, x2, y2, z2, 0) -- 0 = air
	end

	-- Save back to metadata
	local serialized = M.serialize_block_data(block_data)
	meta:set_string(M.META_KEY_DATA, serialized.data)
	meta:set_string(M.META_KEY_PALETTE, serialized.palette)
	meta:set_string(M.META_KEY_ROTATION, serialized.rotation)
	meta:set_string(M.META_KEY_BASE, serialized.base)

	-- Update mesh
	M.update_block_mesh(pos)

	return true
end

-- Save undo state
function M.save_undo(pos, block_data)
	local meta = core.get_meta(pos)
	local serialized = M.serialize_block_data(block_data)

	-- Store in a separate metadata key (simplified: just store last state)
	meta:set_string("mn_undo", serialized.data)
	meta:set_string("mn_undo_palette", serialized.palette)
end

-- Undo last edit
function M.undo(pos)
	local meta = core.get_meta(pos)
	local undo_data = meta:get_string("mn_undo")
	if undo_data == "" then return false end

	-- Swap current with undo
	local current_data = meta:get_string(M.META_KEY_DATA)
	local current_palette = meta:get_string(M.META_KEY_PALETTE)

	meta:set_string(M.META_KEY_DATA, undo_data)
	meta:set_string(M.META_KEY_PALETTE, meta:get_string("mn_undo_palette"))

	meta:set_string("mn_undo", current_data)
	meta:set_string("mn_undo_palette", current_palette)

	M.update_block_mesh(pos)
	return true
end

-- Rotate the micronode grid
function M.rotate_block(pos, direction)
	local meta = core.get_meta(pos)
	local data_str = meta:get_string(M.META_KEY_DATA)
	if data_str == "" then return false end

	local block_data = M.deserialize_block_data({
		data = data_str,
		palette = meta:get_string(M.META_KEY_PALETTE),
		rotation = meta:get_string(M.META_KEY_ROTATION),
		base = meta:get_string(M.META_KEY_BASE),
	})

	block_data.rotation = (block_data.rotation + (direction or 1)) % 4
	block_data.grid = M.rotate_grid(block_data.grid, direction or 1)

	local serialized = M.serialize_block_data(block_data)
	meta:set_string(M.META_KEY_DATA, serialized.data)
	meta:set_string(M.META_KEY_ROTATION, serialized.rotation)

	M.update_block_mesh(pos)
	return true
end

-- Get block info for display
function M.get_block_info(pos)
	local meta = core.get_meta(pos)
	local data_str = meta:get_string(M.META_KEY_DATA)
	if data_str == "" then return nil end

	local block_data = M.deserialize_block_data({
		data = data_str,
		palette = meta:get_string(M.META_KEY_PALETTE),
		rotation = meta:get_string(M.META_KEY_ROTATION),
		base = meta:get_string(M.META_KEY_BASE),
	})

	local solid_count = M.count_solid(block_data.grid)
	local ratio = M.get_compression_ratio(block_data.grid)

	return {
		base = block_data.base,
		palette = block_data.palette,
		rotation = block_data.rotation,
		solid_count = solid_count,
		total_voxels = M.VOXEL_COUNT,
		fill_percent = (solid_count / M.VOXEL_COUNT) * 100,
		compression_ratio = ratio,
	}
end

------------------------------------------------------------------------------
-- Chisel Tool Registration
------------------------------------------------------------------------------

core.register_tool("micronode_chisel:chisel", {
	description = "Micronode Chisel\n" ..
		"Left click: Chisel block / Add micronodes\n" ..
		"Right click: Enter chisel mode / Remove micronodes\n" ..
		"Sneak + Left: Cycle grid size\n" ..
		"Sneak + Right: Cycle material\n" ..
		"Aux1 (E) + Left: Rotate block",
	inventory_image = "micronode_chisel_chisel.png",
	groups = {chisel = 1, not_in_creative_inventory = 1},

	on_use = function(itemstack, user, pointed_thing)
		local name = user:get_player_name()
		local st = get_state(name)
		local ctrl = user:get_player_control()

		if pointed_thing.type ~= "node" then
			return
		end

		local pos = pointed_thing.under
		local node = core.get_node(pos)

		-- Sneak + Left: Cycle grid size
		if ctrl.sneak then
			st.grid_size_idx = (st.grid_size_idx % #M.GRID_SIZES) + 1
			local gs = get_grid_size(st)
			core.chat_send_player(name, "Grid size: " .. M.GRID_NAMES[st.grid_size_idx] ..
				" (" .. gs .. " micronodes)")
			return
		end

		-- Rotate (Aux1/E + Left)
		if ctrl.aux1 then
			if M.is_micronode_block(pos) then
				M.rotate_block(pos, 1)
				core.chat_send_player(name, "Block rotated 90°")
			end
			return
		end

		-- If not a micronode block, chisel it
		if not M.is_micronode_block(pos) then
			if is_chiselable(pos) then
				M.chisel_block(pos, name)
				st.chisel_mode = true
				st.target_pos = pos
				st.palette = M.create_palette({node.name})
			else
				core.chat_send_player(name, "Cannot chisel this block")
			end
			return
		end

		-- Micronode block: add voxels
		if st.chisel_mode and st.target_pos and vector.equals(st.target_pos, pos) then
			-- Calculate micronode position from pointed position
			local above = pointed_thing.above
			local dir = vector.subtract(above, pos)

			-- Project onto block face to get 2D coordinates
			local mx, my, mz = 8, 8, 8 -- Default center
			if dir.y == 1 then -- Top face
				mx = math.floor((above.x - pos.x) * M.RESOLUTION) + 1
				mz = math.floor((above.z - pos.z) * M.RESOLUTION) + 1
				my = M.RESOLUTION
			elseif dir.y == -1 then -- Bottom face
				mx = math.floor((above.x - pos.x) * M.RESOLUTION) + 1
				mz = math.floor((above.z - pos.z) * M.RESOLUTION) + 1
				my = 1
			elseif dir.x == 1 then -- Right face
				my = math.floor((above.y - pos.y) * M.RESOLUTION) + 1
				mz = math.floor((above.z - pos.z) * M.RESOLUTION) + 1
				mx = M.RESOLUTION
			elseif dir.x == -1 then -- Left face
				my = math.floor((above.y - pos.y) * M.RESOLUTION) + 1
				mz = math.floor((above.z - pos.z) * M.RESOLUTION) + 1
				mx = 1
			elseif dir.z == 1 then -- Front face
				mx = math.floor((above.x - pos.x) * M.RESOLUTION) + 1
				my = math.floor((above.y - pos.y) * M.RESOLUTION) + 1
				mz = M.RESOLUTION
			else -- dir.z == -1, Back face
				mx = math.floor((above.x - pos.x) * M.RESOLUTION) + 1
				my = math.floor((above.y - pos.y) * M.RESOLUTION) + 1
				mz = 1
			end

			-- Add material
			M.edit_micronodes(pos, mx, my, mz, get_grid_size(st), st.material_idx, true)
			local info = M.get_block_info(pos)
			core.chat_send_player(name, string.format(
				"Added %s micronodes (fill: %.1f%%)",
				M.palette_get(st.palette or {}, st.material_idx),
				info and info.fill_percent or 0))
		end
	end,

	on_place = function(itemstack, user, pointed_thing)
		local name = user:get_player_name()
		local st = get_state(name)
		local ctrl = user:get_player_control()

		if pointed_thing.type ~= "node" then
			return
		end

		local pos = pointed_thing.under

		-- Sneak + Right: Cycle material
		if ctrl.sneak then
			st.material_idx = (st.material_idx % M.MAX_MATERIALS) + 1
			core.chat_send_player(name, "Material slot: " .. st.material_idx)
			return
		end

		-- Remove voxels from micronode block
		if M.is_micronode_block(pos) and st.chisel_mode and st.target_pos
			and vector.equals(st.target_pos, pos) then
			local above = pointed_thing.above
			local dir = vector.subtract(above, pos)

			local mx, my, mz = 8, 8, 8
			if dir.y == 1 then
				mx = math.floor((above.x - pos.x) * M.RESOLUTION) + 1
				mz = math.floor((above.z - pos.z) * M.RESOLUTION) + 1
				my = M.RESOLUTION
			elseif dir.y == -1 then
				mx = math.floor((above.x - pos.x) * M.RESOLUTION) + 1
				mz = math.floor((above.z - pos.z) * M.RESOLUTION) + 1
				my = 1
			elseif dir.x == 1 then
				my = math.floor((above.y - pos.y) * M.RESOLUTION) + 1
				mz = math.floor((above.z - pos.z) * M.RESOLUTION) + 1
				mx = M.RESOLUTION
			elseif dir.x == -1 then
				my = math.floor((above.y - pos.y) * M.RESOLUTION) + 1
				mz = math.floor((above.z - pos.z) * M.RESOLUTION) + 1
				mx = 1
			elseif dir.z == 1 then
				mx = math.floor((above.x - pos.x) * M.RESOLUTION) + 1
				my = math.floor((above.y - pos.y) * M.RESOLUTION) + 1
				mz = M.RESOLUTION
			else
				mx = math.floor((above.x - pos.x) * M.RESOLUTION) + 1
				my = math.floor((above.y - pos.y) * M.RESOLUTION) + 1
				mz = 1
			end

			M.edit_micronodes(pos, mx, my, mz, get_grid_size(st), 0, false)
			local info = M.get_block_info(pos)
			core.chat_send_player(name, string.format(
				"Removed micronodes (fill: %.1f%%)",
				info and info.fill_percent or 0))
		end
	end,

	on_secondary_use = function(itemstack, user, pointed_thing)
		local name = user:get_player_name()
		local st = get_state(name)

		-- Toggle chisel mode info
		if pointed_thing.type == "node" then
			local pos = pointed_thing.under
			if M.is_micronode_block(pos) then
				local info = M.get_block_info(pos)
				if info then
					core.chat_send_player(name, string.format(
						"Chiseled Block Info:\n" ..
						"  Base: %s\n" ..
						"  Fill: %d/%d (%.1f%%)\n" ..
						"  Rotation: %d°\n" ..
						"  Palette: %s\n" ..
						"  Compression: %.1fx",
						info.base,
						info.solid_count, info.total_voxels, info.fill_percent,
						info.rotation * 90,
						table.concat(info.palette, ", "),
						info.compression_ratio))
				end
			end
		end
	end,
})

------------------------------------------------------------------------------
-- Chiseled Block Node Definition
------------------------------------------------------------------------------

core.register_node("micronode_chisel:chiseled_block", {
	description = "Chiseled Block (Micronode)",
	tiles = {"micronode_chisel_placeholder.png"},
	drawtype = "nodebox",
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = true,
	groups = {cracky = 3, chiseled = 1, not_in_creative_inventory = 1},
	sounds = {},

	-- Nodebox will be set dynamically based on micronode data
	-- For now, use a placeholder
	node_box = {
		type = "fixed",
		fixed = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}},
	},

	-- Collision box (simplified)
	collision_box = {
		type = "regular",
	},

	-- When placed, initialize as empty chiseled block
	after_place_node = function(pos, placer, itemstack, pointed_thing)
		-- Initialize with empty grid if no metadata
		local meta = core.get_meta(pos)
		if meta:get_string(M.META_KEY_DATA) == "" then
			local palette = M.create_palette({"air"})
			local grid = M.create_empty_grid()
			local block_data = M.create_block_data("air", palette, grid, 0)
			local serialized = M.serialize_block_data(block_data)
			meta:set_string(M.META_KEY_DATA, serialized.data)
			meta:set_string(M.META_KEY_PALETTE, serialized.palette)
			meta:set_string(M.META_KEY_ROTATION, serialized.rotation)
			meta:set_string(M.META_KEY_BASE, serialized.base)
		end
	end,

	-- Preserve metadata when dug
	preserve_metadata = function(pos, oldnode, oldmeta, drops)
		-- Metadata is preserved automatically by Luanti
	end,

	-- Drop as item with metadata
	on_destruct = function(pos)
		-- Could drop a "chiseled block" item with saved data
	end,

	-- Digging drops the base material
	drop = function(pos)
		local meta = core.get_meta(pos)
		local base = meta:get_string(M.META_KEY_BASE)
		if base ~= "" and core.registered_items[base] then
			return base
		end
		return M.get_fallback_material()
	end,
})

------------------------------------------------------------------------------
-- Chat Commands
------------------------------------------------------------------------------

core.register_chatcommand("chisel", {
	params = "",
	description = "Get the micronode chisel",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local inv = player:get_inventory()
		inv:add_item("main", "micronode_chisel:chisel")
		return true, "Chisel added to inventory"
	end,
})

core.register_chatcommand("mn_info", {
	params = "",
	description = "Show info about targeted chiseled block",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local pointed = player:get_pointed_thing()
		-- Simplified: show info about block at player position - 1
		local pos = vector.subtract(player:get_pos(), vector.new(0, 1, 0))
		pos = vector.round(pos)

		if M.is_micronode_block(pos) then
			local info = M.get_block_info(pos)
			if info then
				return true, string.format(
					"Fill: %.1f%%, Rotation: %d°, Palette: %s",
					info.fill_percent, info.rotation * 90,
					table.concat(info.palette, ", "))
			end
		end
		return false, "Not a chiseled block"
	end,
})

core.register_chatcommand("mn_undo", {
	params = "",
	description = "Undo last micronode edit",
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local pos = vector.subtract(player:get_pos(), vector.new(0, 1, 0))
		pos = vector.round(pos)

		if M.undo(pos) then
			return true, "Undo successful"
		end
		return false, "Nothing to undo"
	end,
})

------------------------------------------------------------------------------
-- Give chisel on join (for testing)
------------------------------------------------------------------------------

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	get_state(name)

	local inv = player:get_inventory()
	if not inv:contains_item("main", "micronode_chisel:chisel") then
		inv:add_item("main", "micronode_chisel:chisel")
		core.chat_send_player(name,
			"Micronode Chisel added! Left-click to chisel, right-click to edit.")
	end
end)

core.register_on_leaveplayer(function(player)
	player_state[player:get_player_name()] = nil
end)

print("[micronode_chisel] Chisel tool loaded")
