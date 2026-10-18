-- Blueprint clipboard: copy one chiseled block and stamp it onto other nodes.
--
-- The clipboard holds the *compressed* block payload (grid + palette + base
-- material), so copying a detailed block costs a few hundred bytes and stays
-- inside player metadata across reconnects. Pasting decodes a fresh copy, so
-- the clipboard is never aliased into world data and can be stamped any number
-- of times.
--
-- Rotation/flip are applied at paste time (`M.rotate_grid` / `M.flip_grid`),
-- which is why the clipboard only stores a rotation index: the same copy can be
-- stamped in four orientations without re-copying.
--
-- Every paste records an undo entry (see edit.lua: M.commit_positions_undo), so
-- a misplaced stamp is one `/mn_undo` away - including removing a block that
-- the paste created in air.

local M = micronode_chisel
local R = M.RESOLUTION

local META = {
	data = "micronode_chisel:clipboard_data",
	palette = "micronode_chisel:clipboard_palette",
	base = "micronode_chisel:clipboard_base",
	rotate = "micronode_chisel:clipboard_rotate",
	flip = "micronode_chisel:clipboard_flip",
}

-- name -> clipboard table
local clipboards = {}

local function player_meta(name)
	local player = core.get_player_by_name and core.get_player_by_name(name)
	if player and player.get_meta then
		return player:get_meta()
	end
	return nil
end

local function save(name, clip)
	local meta = player_meta(name)
	if not meta then
		return
	end
	meta:set_string(META.data, clip.data or "")
	meta:set_string(META.palette, clip.palette or "")
	meta:set_string(META.base, clip.base or M.AIR)
	meta:set_string(META.rotate, tostring(clip.rotate or 0))
	meta:set_string(META.flip, clip.flip and "1" or "0")
end

-- Clipboard of a player (empty table when nothing has been copied yet).
function M.get_clipboard(name)
	local clip = clipboards[name]
	if clip then
		return clip
	end
	clip = {
		data = "", palette = "", base = M.AIR,
		rotate = 0, flip = false, cells = 0,
	}
	local meta = player_meta(name)
	if meta then
		clip.data = meta:get_string(META.data)
		clip.palette = meta:get_string(META.palette)
		local base = meta:get_string(META.base)
		if base ~= "" then
			clip.base = base
		end
		clip.rotate = (tonumber(meta:get_string(META.rotate)) or 0) % 4
		clip.flip = meta:get_string(META.flip) == "1"
	end
	clipboards[name] = clip
	return clip
end

function M.clipboard_is_empty(name)
	return M.get_clipboard(name).data == ""
end

function M.forget_clipboard(name)
	clipboards[name] = nil
end

local function rotation_label(rotate)
	return tostring((rotate or 0) % 4 * 90) .. " deg"
end

-- Copy the chiseled block at `pos` into the player's clipboard.
-- Returns ok, message.
function M.copy_block(name, pos)
	if not name then
		return false, "No player"
	end
	local block = M.get_block(pos)
	if not block then
		return false, "Point at a chiseled block to copy it"
	end

	local serialized = M.serialize_block_data(block)
	local cells = M.count_solid(block.grid)
	if cells == 0 then
		return false, "That block is empty: nothing to copy"
	end

	local clip = M.get_clipboard(name)
	clip.data = serialized.data
	clip.palette = serialized.palette
	clip.base = serialized.base
	clip.cells = cells
	save(name, clip)

	return true, string.format("Copied %d/%d micronodes (%s)",
		clip.cells, M.VOXEL_COUNT, clip.palette)
end

-- Cycle the paste rotation by `delta` quarter turns. Returns the new state.
function M.rotate_clipboard(name, delta)
	local clip = M.get_clipboard(name)
	clip.rotate = ((clip.rotate or 0) + (delta or 1)) % 4
	save(name, clip)
	return clip
end

-- Toggle the horizontal mirror used when pasting. Returns the new state.
function M.flip_clipboard(name)
	local clip = M.get_clipboard(name)
	clip.flip = not clip.flip
	save(name, clip)
	return clip
end

function M.clipboard_label(name)
	local clip = M.get_clipboard(name)
	if clip.data == "" then
		return "empty"
	end
	return string.format("%d cells, %s%s",
		clip.cells, rotation_label(clip.rotate), clip.flip and ", flipped" or "")
end

-- Node `pos` may receive a paste: an existing chiseled block, a chiselable
-- plain node (converted), or a passable node (a new block is created).
-- Returns true, or false plus a reason.
local function can_paste_onto(pos)
	local node = core.get_node(pos)
	if M.is_container_name(node.name) then
		return true
	end
	if M.is_chiselable(pos) then
		return true
	end
	local def = core.registered_nodes and core.registered_nodes[node.name]
	if node.name == "air" or node.name == "ignore"
		or (def and def.walkable == false)
		or (def and def.groups and def.groups.liquid) then
		return true
	end
	return false, "cannot paste into " .. node.name
end

-- Paste the clipboard at `pos`.
-- opts.rotate: quarter turns (defaults to the clipboard's stored rotation)
-- opts.flip:   mirror (defaults to the clipboard's stored flip)
-- opts.player: player name, enables protection checks and undo
-- Returns ok, message.
function M.paste_block(name, pos, opts)
	opts = opts or {}
	local clip = M.get_clipboard(name)
	if clip.data == "" then
		return false, "Clipboard is empty: copy a block with sneak+aux1+left or /mn_copy"
	end
	if (opts.player or name) and core.is_protected
		and core.is_protected(pos, opts.player or name) then
		return false, "This node is protected"
	end

	local ok, why = can_paste_onto(pos)
	if not ok then
		return false, why
	end

	local was_container = M.is_container_name(core.get_node(pos).name)
	-- Snapshot before mutating: undo must restore the state the paste replaced.
	local undo = (opts.player or name) and M.begin_undo_entry() or nil
	M.add_undo_position(undo, pos)

	if not was_container then
		-- Convert or create; swap_node keeps metadata and skips callbacks, and
		-- the collision variant is re-picked by refresh_block below.
		core.swap_node(pos, {name = M.BLOCK_NODE})
	end

	local block = M.deserialize_block_data({
		data = clip.data,
		palette = clip.palette,
		base = clip.base,
	})

	local rotate = (opts.rotate or clip.rotate or 0) % 4
	if rotate ~= 0 then
		block.grid = M.rotate_grid(block.grid, rotate, R)
	end
	local flip = opts.flip
	if flip == nil then
		flip = clip.flip
	end
	if flip then
		block.grid = M.flip_grid(block.grid, R)
	end
	if rotate ~= 0 or flip then
		block.palette = M.palette_compact(block.grid, block.palette)
	end

	M.set_block(pos, block)
	M.refresh_block(pos)
	M.commit_undo_entry(opts.player or name, undo)

	return true, string.format("Pasted %d micronodes (%s%s)",
		M.count_solid(block.grid), rotation_label(rotate), flip and ", flipped" or "")
end

print("[micronode_chisel] Clipboard loaded")
