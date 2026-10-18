-- Functional QC checks for micronode_chisel, run by tools/headless_qc.py
-- against the real mod code with tools/stub.lua standing in for the engine.
--
-- Returns a table of failure strings (empty = pass). Every check prints one
-- line so CI logs show what was actually exercised.

local M = micronode_chisel
local R = M.RESOLUTION
local failures = {}

local function check(name, ok, detail)
	if ok then
		print("  ok: " .. name)
	else
		local message = name .. (detail and (" (" .. tostring(detail) .. ")") or "")
		failures[#failures + 1] = message
		print("FAIL: " .. message)
	end
end

local function near(a, b, eps)
	return math.abs(a - b) <= (eps or 1e-9)
end

local function open_neighbors()
	return {px = false, nx = false, py = false, ny = false, pz = false, nz = false}
end

local function solid_neighbors()
	return {px = true, nx = true, py = true, ny = true, pz = true, nz = true}
end

local function stone_palette()
	return M.create_palette({"default:stone"})
end

local function box_key(box)
	return string.format("%.6f:%.6f:%.6f:%.6f:%.6f:%.6f", box.x0, box.x1, box.y0, box.y1, box.z0, box.z1)
end

-------------------------------------------------------------------------------
print("[qc] data model")
-------------------------------------------------------------------------------

do
	local grid = M.create_empty_grid()
	check("grid_empty", #grid == M.VOXEL_COUNT and M.is_empty(grid), #grid)

	grid = M.create_filled_grid(1)
	check("grid_filled", M.is_full(grid) and M.count_solid(grid) == M.VOXEL_COUNT)

	grid = M.create_empty_grid()
	M.set_voxel(grid, 8, 8, 8, 2)
	check("grid_set_get", M.get_voxel(grid, 8, 8, 8) == 2)
	check("grid_ooo", M.get_voxel(grid, 0, 1, 1) == 0 and M.get_voxel(grid, 17, 1, 1) == 0)

	grid = M.create_empty_grid()
	M.fill_box(grid, 7, 7, 7, 10, 10, 10, 1)
	check("grid_fill_box", M.count_solid(grid) == 64, M.count_solid(grid))

	grid = M.create_empty_grid()
	M.fill_box(grid, -9, -9, -9, 99, 99, 99, 1)
	check("grid_fill_clipped", M.count_solid(grid) == M.VOXEL_COUNT)

	check("count_solid_nil_safe", M.count_solid({1, 0, 2, 0}) == 2)
end

-------------------------------------------------------------------------------
print("[qc] storage")
-------------------------------------------------------------------------------

do
	local flat = M.create_filled_grid(1)
	local decoded = M.decompress_grid(M.compress_grid(flat))
	local same = true
	for i = 1, M.VOXEL_COUNT do
		if decoded[i] ~= flat[i] then same = false break end
	end
	check("storage_flat_roundtrip", same)
	check("storage_flat_small", #M.compress_grid(flat) < 32, #M.compress_grid(flat))

	local noisy = M.create_empty_grid()
	for z = 1, R do
		for y = 1, R do
			for x = 1, R do
				if (x + y * 2 + z * 3) % 3 == 0 then
					M.set_voxel(noisy, x, y, z, (x % 4) + 1)
				end
			end
		end
	end
	decoded = M.decompress_grid(M.compress_grid(noisy))
	same = true
	for i = 1, M.VOXEL_COUNT do
		if decoded[i] ~= noisy[i] then same = false break end
	end
	local stored = M.compress_grid(noisy)
	check("storage_noisy_roundtrip", same)
	check("storage_size_bound", #stored <= M.VOXEL_COUNT + 1, #stored)

	local block = M.create_block_data("default:stone",
		M.create_palette({"default:stone", "default:dirt"}), noisy)
	local restored = M.deserialize_block_data(M.serialize_block_data(block))
	local grid_ok, palette_ok = true, restored.palette[1] == "default:stone"
	for i = 1, M.VOXEL_COUNT do
		if restored.grid[i] ~= noisy[i] then grid_ok = false break end
	end
	check("block_data_roundtrip", grid_ok and palette_ok and restored.base == "default:stone")

	check("storage_empty_string", M.is_empty(M.decompress_grid("")), "empty string decodes to air")
end

-------------------------------------------------------------------------------
print("[qc] palette")
-------------------------------------------------------------------------------

do
	local palette = M.create_palette({"default:stone", "default:dirt"})
	check("palette_create", palette[1] == "default:stone" and palette[3] == M.AIR)
	check("palette_duplicate", M.palette_add(palette, "default:stone") == 1)
	check("palette_add", M.palette_add(palette, "default:sand") == 3)
	check("palette_overflow", M.palette_add(palette, "default:gravel") == nil)

	local grid = M.create_empty_grid()
	M.fill_box(grid, 1, 1, 1, 16, 16, 16, 3)
	local compacted = M.palette_compact(grid, palette)
	check("palette_compact",
		compacted[1] == "default:sand" and compacted[2] == M.AIR
			and M.get_voxel(grid, 5, 5, 5) == 1,
		compacted[1] .. "/" .. tostring(M.get_voxel(grid, 5, 5, 5)))

	local round_trip = M.palette_deserialize(M.palette_serialize(compacted))
	check("palette_serialize", round_trip[1] == "default:sand" and round_trip[4] == M.AIR)
end

-------------------------------------------------------------------------------
print("[qc] transforms")
-------------------------------------------------------------------------------

do
	local grid = M.create_empty_grid()
	M.set_voxel(grid, 1, 1, 1, 2)
	check("rotate_90", M.get_voxel(M.rotate_grid(grid, 1), 1, 1, R) == 2)
	check("rotate_360", M.get_voxel(M.rotate_grid(grid, 4), 1, 1, 1) == 2)
	local flipped = M.flip_grid(grid)
	check("flip", M.get_voxel(flipped, R, 1, 1) == 2
		and M.get_voxel(M.flip_grid(flipped), 1, 1, 1) == 2)
end

-------------------------------------------------------------------------------
print("[qc] surface mesher")
-------------------------------------------------------------------------------

do
	local palette = stone_palette()

	local boxes = M.build_surface_boxes(M.create_filled_grid(1), palette, open_neighbors(), R)
	check("mesh_full_six", #boxes == 6, #boxes)

	local bounds_ok, depth_ok, planes_ok = true, true, true
	local face_depth = (1 / R) * M.FACE_DEPTH_FRACTION
	for _, box in ipairs(boxes) do
		local thin_axes = 0
		for _, axis in ipairs({"x", "y", "z"}) do
			local lo = math.min(box[axis .. "0"], box[axis .. "1"])
			local hi = math.max(box[axis .. "0"], box[axis .. "1"])
			if lo < -0.5 - 1e-9 or hi > 0.5 + 1e-9 then
				bounds_ok = false
			end
			if near(hi - lo, face_depth) then
				thin_axes = thin_axes + 1
				local outward = (box.axis == 1 and axis == "x")
					or (box.axis == 2 and axis == "y")
					or (box.axis == 3 and axis == "z")
				if outward then
					local plane = (box.dir > 0) and hi or lo
					if not near(math.abs(plane), 0.5) then
						planes_ok = false
					end
				end
			end
		end
		if thin_axes ~= 1 then
			depth_ok = false
		end
	end
	check("mesh_bounds", bounds_ok)
	check("mesh_depth_one_slab", depth_ok, "each face box has exactly one thin axis")
	check("mesh_outward_planes", planes_ok, "outward planes on the node boundary")

	-- Perpendicular faces must overlap into the solid at their shared edge:
	-- that overlap is what keeps the block reading as one continuous solid.
	local top, right
	for _, box in ipairs(boxes) do
		if box.axis == 2 and box.dir > 0 then top = box end
		if box.axis == 1 and box.dir > 0 then right = box end
	end
	check("mesh_faces_overlap",
		top and right
			and (math.min(top.y0, top.y1) < 0.5 - 1e-9)
			and (math.min(right.x0, right.x1) < 0.5 - 1e-9),
		"faces extend into the solid so neighbouring boxes interpenetrate")

	check("mesh_empty", #M.build_surface_boxes(M.create_empty_grid(), palette, open_neighbors(), R) == 0)
	check("mesh_solid_neighbors",
		#M.build_surface_boxes(M.create_filled_grid(1), palette, solid_neighbors(), R) == 0)

	local slab = M.create_empty_grid()
	M.fill_box(slab, 1, 1, 1, 16, 8, 16, 1)
	local slab_boxes = M.build_surface_boxes(slab, palette, open_neighbors(), R)
	local top_plane = -1
	for _, box in ipairs(slab_boxes) do
		if box.axis == 2 and box.dir > 0 then
			top_plane = math.max(box.y0, box.y1)
		end
	end
	check("mesh_half_slab", #slab_boxes == 6 and near(top_plane, 0), #slab_boxes .. "@" .. top_plane)

	local cavity = M.create_filled_grid(1)
	M.set_voxel(cavity, 8, 8, 8, 0)
	check("mesh_inner_cavity",
		#M.build_surface_boxes(cavity, palette, open_neighbors(), R) == 12,
		#M.build_surface_boxes(cavity, palette, open_neighbors(), R))

	local split = M.create_empty_grid()
	M.fill_box(split, 1, 1, 1, 8, 16, 16, 1)
	M.fill_box(split, 9, 1, 1, 16, 16, 16, 2)
	check("mesh_two_materials",
		#M.build_surface_boxes(split, M.create_palette({"default:stone", "default:dirt"}),
			open_neighbors(), R) == 10)

	local masked = open_neighbors()
	masked.py = function(u) return u <= 8 end
	local culled = M.build_surface_boxes(M.create_filled_grid(1), palette, masked, R)
	local area = 0
	for _, box in ipairs(culled) do
		if box.axis == 2 and box.dir > 0 then
			area = area + math.abs(box.x1 - box.x0) * math.abs(box.z1 - box.z0)
		end
	end
	check("mesh_neighbour_mask", near(area, 0.5, 1e-6), area)

	-- hash signature must react to geometry and material changes
	local h1 = M.boxes_hash(boxes)
	local h2 = M.boxes_hash(M.build_surface_boxes(slab, palette, open_neighbors(), R))
	check("mesh_hash_differs", h1 ~= h2)
	local renamed = M.build_surface_boxes(M.create_filled_grid(1),
		M.create_palette({"default:dirt"}), open_neighbors(), R)
	check("mesh_hash_material", M.boxes_hash(boxes) ~= M.boxes_hash(renamed))
end

-------------------------------------------------------------------------------
print("[qc] coarsening (render budget fallback)")
-------------------------------------------------------------------------------

do
	local coarse, res = M.coarsen_grid(M.create_filled_grid(1), 4, R)
	check("coarsen_resolution", res == 4, res)
	check("coarsen_full_stays_full", M.is_full(coarse), M.count_solid(coarse))

	local carved = M.create_filled_grid(1)
	M.fill_box(carved, 1, 1, 1, 8, 8, 8, 0)
	local cgrid, cres = M.coarsen_grid(carved, 2, R)
	check("coarsen_any_solid_watertight",
		M.get_voxel(cgrid, 1, 1, 1, cres) == 1 and M.get_voxel(cgrid, 8, 8, 8, cres) == 1,
		"conservative downsampling never opens a hole")
	check("coarsen_meshes", #M.build_surface_boxes(cgrid, stone_palette(), open_neighbors(), cres) > 0)
end

-------------------------------------------------------------------------------
print("[qc] picking (voxel DDA)")
-------------------------------------------------------------------------------

do
	local pos = {x = 0, y = 0, z = 0}
	local full = M.create_filled_grid(1)

	local hit = M.raycast_grid(full, pos, {x = 0, y = 4, z = 0}, {x = 0, y = -1, z = 0}, R)
	check("pick_top", hit and hit.y == R and hit.ny == 1,
		hit and (hit.x .. "," .. hit.y .. "," .. hit.z .. " n" .. hit.ny) or "nil")

	hit = M.raycast_grid(full, pos, {x = -4, y = 0, z = 0}, {x = 1, y = 0, z = 0}, R)
	check("pick_side", hit and hit.x == 1 and hit.nx == -1,
		hit and ("x=" .. hit.x .. " n=" .. hit.nx) or "nil")

	check("pick_empty", M.raycast_grid(M.create_empty_grid(), pos,
		{x = 0, y = 4, z = 0}, {x = 0, y = -1, z = 0}, R) == nil)

	local slab = M.create_empty_grid()
	M.fill_box(slab, 1, 1, 1, 16, 8, 16, 1)
	hit = M.raycast_grid(slab, pos, {x = 0, y = 4, z = 0}, {x = 0, y = -1, z = 0}, R)
	check("pick_slab_top", hit and hit.y == 8 and hit.ny == 1, hit and hit.y or "nil")

	-- Carve the near half: the ray must pass through the empty cells and hit the
	-- far wall (exercises slicing a partially exposed grid, where the per-slice
	-- mask is sparse).
	local carved = M.create_filled_grid(1)
	M.fill_box(carved, 1, 1, 1, 8, 16, 16, 0)
	hit = M.raycast_grid(carved, pos, {x = -4, y = 0, z = 0}, {x = 1, y = 0, z = 0}, R)
	check("pick_carved_face", hit and hit.x == 9 and hit.nx == -1,
		hit and ("x=" .. hit.x .. " n=" .. hit.nx) or "nil")
end

-------------------------------------------------------------------------------
print("[qc] brushes")
-------------------------------------------------------------------------------

do
	local hit = {x = 9, y = 16, z = 9, nx = 0, ny = 1, nz = 0}
	local push = M.push_brush(hit, 4)
	check("brush_push", push and push.y0 == 16 and push.y1 == 19
		and push.x0 == 8 and push.x1 == 11 and push.z0 == 8 and push.z1 == 11,
		push and (push.x0 .. ".." .. push.x1 .. "," .. push.y0 .. ".." .. push.y1))

	local pull = M.pull_brush(hit, 4)
	check("brush_pull", pull and pull.y0 == 12 and pull.y1 == 15
		and pull.x0 == 8 and pull.x1 == 11,
		pull and (pull.y0 .. ".." .. pull.y1))

	local single = M.push_brush({x = 1, y = 1, z = 1, nx = -1, ny = 0, nz = 0}, 1)
	check("brush_single", single and single.x0 == -1 and single.x1 == -1)

	local clamped = M.push_brush(hit, 64)
	check("brush_clamped", clamped and (clamped.y1 - clamped.y0) == R - 1)

	local off_face = M.push_brush({x = 5, y = 5, z = 5, nx = 0, ny = 0, nz = 0}, 1)
	check("brush_no_normal", off_face == nil)
end

-------------------------------------------------------------------------------
print("[qc] z-fighting invariant (no two drawn quads are coplanar)")
-------------------------------------------------------------------------------
-- Every drawn quad is the outward face of one face box. Two drawn quads in the
-- same plane that also overlap would fight for the depth buffer. This walks a
-- carved shape and asserts that never happens for the boxes the mesher emits.
do
	local function drawn_quad(box)
		local x0, x1 = math.min(box.x0, box.x1), math.max(box.x0, box.x1)
		local y0, y1 = math.min(box.y0, box.y1), math.max(box.y0, box.y1)
		local z0, z1 = math.min(box.z0, box.z1), math.max(box.z0, box.z1)
		-- Only the outward face of a box is drawn; its plane is the outward one
		local plane
		if box.axis == 1 then
			plane = (box.dir > 0) and x1 or x0
		elseif box.axis == 2 then
			plane = (box.dir > 0) and y1 or y0
		else
			plane = (box.dir > 0) and z1 or z0
		end
		local quad = {axis = box.axis, plane = plane}
		if box.axis == 1 then
			quad.u0, quad.u1, quad.v0, quad.v1 = y0, y1, z0, z1
		elseif box.axis == 2 then
			quad.u0, quad.u1, quad.v0, quad.v1 = x0, x1, z0, z1
		else
			quad.u0, quad.u1, quad.v0, quad.v1 = x0, x1, y0, y1
		end
		return quad
	end

	local function overlaps(a, b)
		if a.axis ~= b.axis then
			return false
		end
		if not near(a.plane, b.plane, 1e-9) then
			return false
		end
		local u = math.min(a.u1, b.u1) - math.max(a.u0, b.u0)
		local v = math.min(a.v1, b.v1) - math.max(a.v0, b.v0)
		-- touching edges (u == 0) are fine; a positive area is a real overlap
		return u > 1e-9 and v > 1e-9
	end

	local function audit(label, grid)
		local boxes = M.build_surface_boxes(grid, stone_palette(), open_neighbors(), R)
		local quads = {}
		for _, box in ipairs(boxes) do
			quads[#quads + 1] = drawn_quad(box)
		end
		local clashes = 0
		for i = 1, #quads do
			for j = i + 1, #quads do
				if overlaps(quads[i], quads[j]) then
					clashes = clashes + 1
				end
			end
		end
		check("zfighting_" .. label, clashes == 0,
			clashes .. " coplanar overlapping drawn quads out of " .. #quads)
	end

	audit("full", M.create_filled_grid(1))

	local combs = M.create_filled_grid(1)
	for i = 1, 6 do
		M.fill_box(combs, 1, 1, 1, 2 * i, R, R, 0)
	end
	audit("stairs", combs)

	local cavity = M.create_filled_grid(1)
	M.set_voxel(cavity, 8, 8, 8, 0)
	M.set_voxel(cavity, 9, 8, 8, 0)
	audit("cavity", cavity)

	-- The reported symptom: a chiselled edge, i.e. a box corner on the surface.
	local corner = M.create_filled_grid(1)
	M.fill_box(corner, 1, 1, 1, 8, 8, 8, 0)
	audit("corner_carve", corner)

	local shelf = M.create_empty_grid()
	M.fill_box(shelf, 1, 8, 1, R, 8, R, 1)
	audit("one_voxel_shelf", shelf)
end

-------------------------------------------------------------------------------
print("[qc] collision variant")
-------------------------------------------------------------------------------
do
	local grid = M.create_filled_grid(1)
	check("collision_full_solid", M.collision_variant(grid) == M.BLOCK_NODE)
	M.fill_box(grid, 1, 1, 1, 16, 16, 12, 0)
	check("collision_open", M.collision_variant(grid) == M.BLOCK_NODE_OPEN,
		string.format("%.2f solid", M.fill_ratio(grid)))
	check("collision_ratio", near(M.fill_ratio(M.create_filled_grid(1)), 1))
	check("collision_empty", M.collision_variant(M.create_empty_grid()) == M.BLOCK_NODE_OPEN)
end

-------------------------------------------------------------------------------
print("[qc] render audit (entity transforms and textures)")
-------------------------------------------------------------------------------

do
	local pos = {x = 10, y = 20, z = 30}
	core.set_node(pos, {name = "default:stone"})

	local block = M.chisel_native(pos)
	check("render_chisel", block ~= nil and core.get_node(pos).name == M.BLOCK_NODE)
	check("render_chisel_full", M.count_solid(M.get_block(pos).grid) == M.VOXEL_COUNT)

	M.refresh_block(pos)

	local function live_objects()
		local out = {}
		for _, obj in ipairs(core.get_objects_inside_radius(pos, 2.0)) do
			if not obj.removed and obj.name == M.ENTITY_NAME then
				out[#out + 1] = obj
			end
		end
		return out
	end

	local function audit(label)
		local b = M.get_block(pos)
		local boxes = M.build_surface_boxes(b.grid, b.palette, M.build_neighbors(pos), R)
		local objs = live_objects()
		check(label .. "_count", #objs == #boxes, #objs .. "/" .. #boxes)

		local wanted = {}
		for _, box in ipairs(boxes) do
			local cx = pos.x + (box.x0 + box.x1) / 2
			local cy = pos.y + (box.y0 + box.y1) / 2
			local cz = pos.z + (box.z0 + box.z1) / 2
			wanted[string.format("%.6f:%.6f:%.6f", cx, cy, cz)] = {
				sx = math.abs(box.x1 - box.x0),
				sy = math.abs(box.y1 - box.y0),
				sz = math.abs(box.z1 - box.z0),
				face = M.cube_face(box.axis, box.dir),
			}
		end

		local placed, sized, inside, single_face = 0, 0, true, 0
		for _, obj in ipairs(objs) do
			local key = string.format("%.6f:%.6f:%.6f", obj.pos.x, obj.pos.y, obj.pos.z)
			local want = wanted[key]
			if want then
				placed = placed + 1
				local d = obj.data
				if near(d.sx, want.sx, 1e-6) and near(d.sy, want.sy, 1e-6)
					and near(d.sz, want.sz, 1e-6) then
					sized = sized + 1
				end
				-- the entity's cube (centered) must stay within the node
				if math.abs(obj.pos.x - pos.x) + d.sx / 2 > 0.5 + 1e-6
					or math.abs(obj.pos.y - pos.y) + d.sy / 2 > 0.5 + 1e-6
					or math.abs(obj.pos.z - pos.z) + d.sz / 2 > 0.5 + 1e-6 then
					inside = false
				end

				-- Exactly ONE drawn face (the outward one) and the crop must be
				-- a valid [combine landing inside its canvas. Coplanar duplicate
				-- quads are the z-fighting bug this invariant prevents.
				local visible = want.face
				local drawn, bad = 0, false
				for i = 1, 6 do
					local tex = d.texs[i]
					if i == visible then
						drawn = drawn + 1
						if type(tex) ~= "string" or not tex:find("^%[combine:") then
							bad = true
						else
							local dims, rest = tex:match("^%[combine:(%d+x%d+):(.+)$")
							local w, h = 0, 0
							if dims then
								w, h = dims:match("(%d+)x(%d+)")
								w, h = tonumber(w), tonumber(h)
							end
							local bx, by = rest and rest:match("^(%-?%d+),(%-?%d+)=")
							bx, by = tonumber(bx), tonumber(by)
							if not w or w < 1 or not h or h < 1 or not bx or not by
								or bx >= w or by >= h or bx <= -R * 4 or by <= -R * 4 then
								bad = true
							end
						end
					elseif tex ~= M.HIDDEN_TEXTURE then
						bad = true
					end
				end
				if drawn == 1 and not bad then
					single_face = single_face + 1
				end
			end
		end
		check(label .. "_positions", placed == #boxes, placed .. "/" .. #boxes)
		check(label .. "_sizes", sized == #boxes, sized .. "/" .. #boxes)
		check(label .. "_inside_node", inside, "centered cube transform")
		check(label .. "_one_drawn_face", single_face == #boxes,
			single_face .. "/" .. #boxes .. " entities draw exactly one face")
	end

	audit("render_full")

	-- Carve a corner: the classic case that used to render as scattered faces.
	M.apply_region(pos, M.ordered_region(0, 0, 0, 7, 7, 7), nil, {create = false})
	audit("render_corner_carve")

	-- Idempotent re-mesh must not duplicate entities.
	local before = #live_objects()
	M.update_block_mesh(pos)
	check("render_idempotent", #live_objects() == before, #live_objects() .. "/" .. before)

	-- Half slab carve, then a full carve (nothing left to render).
	M.apply_region(pos, M.ordered_region(0, 0, 0, R - 1, R / 2 - 1, R - 1), nil, {create = false})
	audit("render_slab")

	M.apply_region(pos, M.ordered_region(0, 0, 0, R - 1, R - 1, R - 1), nil, {create = false})
	check("render_empty_block", #live_objects() == 0, #live_objects() .. " entities left")

	-- Pushing into air creates a neighbour block and renders it.
	core.remove_node({x = pos.x, y = pos.y + 1, z = pos.z})
	M.apply_region(pos, M.ordered_region(0, R, 0, R - 1, R, R - 1), "default:dirt",
		{create = true, base_material = "default:dirt"})
	check("render_cross_block_push",
		M.is_micronode_block({x = pos.x, y = pos.y + 1, z = pos.z})
			and #core.get_objects_inside_radius({x = pos.x, y = pos.y + 1, z = pos.z}, 2.0) > 0)
end

-------------------------------------------------------------------------------
print("[qc] dig / drop")
-------------------------------------------------------------------------------

do
	local pos = {x = -4, y = 7, z = 2}
	core.set_node(pos, {name = "default:stone"})
	M.chisel_native(pos)
	check("dig_setup", M.is_micronode_block(pos))
	local def = core.registered_nodes[M.BLOCK_NODE]
	check("dig_has_on_dig", type(def.on_dig) == "function")
	check("dig_drop_base", M.get_block(pos).base == "default:stone")
	core.remove_node(pos)
	check("dig_removed", core.get_node(pos).name == "air" and M.get_block(pos) == nil)
end

return failures
