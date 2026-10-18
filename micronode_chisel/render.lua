-- Texture mapping and mesh rebuild for micronode blocks.
--
-- A cube entity maps its whole texture onto each face, so the face texture is
-- the block-relative crop of the material texture at that face position. Crops
-- use [combine with negative blit offsets on a copy resized to the block
-- resolution, so the pattern lines up across neighbouring faces *and*
-- neighbouring blocks (Sauerbraten-style world-aligned texturing) instead of
-- stretching one copy per merged rectangle.
--
-- [combine blits at (x, y) ONTO the output canvas, so a crop needs negative
-- offsets; positive offsets land outside the canvas and yield a fully
-- transparent face (an invisible block).
--
-- ONE OPAQUE FACE PER ENTITY: a face box is a cube, so it has six quads, but
-- only the outward one belongs to the visible surface. The other five are
-- textured with HIDDEN_TEXTURE and are discarded at render time. This is the
-- same invariant Sauerbraten gets from emitting surface quads only, and it is
-- what keeps chiselled edges from flickering:
--
--   the box of a +X face spans x in [plane-d, plane] and, say, y up to the top
--   of its rectangle; its +Y side quad therefore lies exactly in y = 0.5, the
--   very plane of the +Y face box next to it. Two opaque coplanar quads at the
--   same depth fight for the depth buffer -> the shimmer along every edge.
--   Making the non-outward quads invisible removes the duplicate instead of
--   trying to out-offset it.
--
-- Invisibility is reliable here because entity cube visuals use
-- TILE_MATERIAL_BASIC -> EMT_TRANSPARENT_ALPHA_CHANNEL_REF -> the object shader
-- discards fragments with alpha < 0.5 (shader.cpp:888/807,
-- object_shader/opengl_fragment.glsl:383). blank.png is fully transparent, so
-- those quads are never rasterised - no blending, no sort order, no depth
-- writes.

local M = micronode_chisel
local R = M.RESOLUTION

-- Texture used for the cube faces that must not be drawn.
M.HIDDEN_TEXTURE = "blank.png"

-------------------------------------------------------------------------------
-- Texture cropping
-------------------------------------------------------------------------------

-- u grows to the right of the face texture, v grows downwards, both 0..1.
function M.crop_texture(tile, u0, v0, u1, v1)
	local lo_u, hi_u = math.min(u0, u1), math.max(u0, u1)
	local lo_v, hi_v = math.min(v0, v1), math.max(v0, v1)

	local x = math.floor(lo_u * R + 0.5)
	local y = math.floor(lo_v * R + 0.5)
	local w = math.floor(hi_u * R + 0.5) - x
	local h = math.floor(hi_v * R + 0.5) - y
	if w < 1 then w = 1 end
	if h < 1 then h = 1 end

	local base = (tile or "blank.png") .. "^[resize:" .. R .. "x" .. R
	local escaped = base:gsub("([%^:])", "\\%1")
	return string.format("[combine:%dx%d:%d,%d=%s", w, h, -x, -y, escaped)
end

-- UV region of the outward face of a box, matching createCubeMesh's per-face
-- UVs (node face space: -0.5..0.5 -> 0..1, v growing down).
function M.face_uv(box)
	local x0, x1 = math.min(box.x0, box.x1), math.max(box.x0, box.x1)
	local y0, y1 = math.min(box.y0, box.y1), math.max(box.y0, box.y1)
	local z0, z1 = math.min(box.z0, box.z1), math.max(box.z0, box.z1)

	if box.axis == 1 and box.dir > 0 then      -- +X
		return z0 + 0.5, 0.5 - y1, z1 + 0.5, 0.5 - y0
	elseif box.axis == 1 then                  -- -X
		return 0.5 - z1, 0.5 - y1, 0.5 - z0, 0.5 - y0
	elseif box.axis == 2 and box.dir > 0 then  -- +Y
		return x0 + 0.5, 0.5 - z1, x1 + 0.5, 0.5 - z0
	elseif box.axis == 2 then                  -- -Y
		return x0 + 0.5, 0.5 + z0, x1 + 0.5, 0.5 + z1
	elseif box.axis == 3 and box.dir > 0 then  -- +Z
		return 0.5 - x1, 0.5 - y1, 0.5 - x0, 0.5 - y0
	end
	return x0 + 0.5, 0.5 - y1, x1 + 0.5, 0.5 - y0 -- -Z
end

-- Six-texture array for a face box: the crop on the outward face, nothing on
-- the other five (see the header for why the hidden ones must be discarded
-- rather than drawn).
function M.face_textures(box)
	local tile = M.get_tile(box.material, M.cube_face(box.axis, box.dir))
	local u0, v0, u1, v1 = M.face_uv(box)
	local texture = M.crop_texture(tile, u0, v0, u1, v1)

	local visible = M.cube_face(box.axis, box.dir)
	local textures = {}
	for i = 1, 6 do
		textures[i] = (i == visible) and texture or M.HIDDEN_TEXTURE
	end
	return textures
end

-------------------------------------------------------------------------------
-- Block mesh rebuild
-------------------------------------------------------------------------------

-- Rebuild the visible geometry of one block. Cheap no-op when the shape is
-- unchanged and its entities are still alive.
function M.update_block_mesh(pos)
	local block = M.get_block(pos)
	if not block then
		M.remove_block_entities(pos)
		return
	end

	local neighbors = M.build_neighbors(pos)
	local budget = M.render_budget()
	local boxes = M.build_surface_boxes(block.grid, block.palette, neighbors, R)

	if #boxes > budget then
		-- Emergency path: re-mesh a conservative (any-solid) downsample of the
		-- shape so the block stays closed and recognizable instead of flooding
		-- the world with entities or snapping back to a full cube.
		for _, step in ipairs({2, 4, 8}) do
			local coarse, res = M.coarsen_grid(block.grid, step, R)
			local coarse_boxes = M.build_surface_boxes(coarse, block.palette, neighbors, res)
			if #coarse_boxes <= budget then
				boxes = coarse_boxes
				core.log("action", "[micronode_chisel] " .. core.pos_to_string(pos)
					.. ": rendering " .. #boxes .. " faces at 1/" .. step .. " resolution")
				break
			end
		end
	end

	local hash = M.boxes_hash(boxes)
	if M.is_current(pos, hash) then
		return
	end

	M.remove_block_entities(pos)
	if #boxes == 0 then
		return
	end

	local objs = {}
	for _, box in ipairs(boxes) do
		local obj = M.spawn_box(pos, box, M.face_textures(box))
		if obj then
			objs[#objs + 1] = obj
		end
	end
	M.remember(pos, hash, objs)
end

print("[micronode_chisel] Renderer loaded")

-------------------------------------------------------------------------------
-- Rebuild on mapblock activation
-------------------------------------------------------------------------------

core.register_lbm({
	name = "micronode_chisel:rebuild_meshes",
	label = "Rebuild micronode render entities",
	nodenames = {M.BLOCK_NODE, M.BLOCK_NODE_OPEN},
	run_at_every_load = true,
	action = function(pos)
		M.forget_block(pos)
		M.update_block_mesh(pos)
	end,
})
