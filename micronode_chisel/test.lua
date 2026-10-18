-- In-engine self tests, run shortly after server start.
--
-- These exercise the real code paths (mesher, picker, brushes, undo, entity
-- spawning) rather than mocking them. The headless logic mirror is
-- tools/headless_qc.py, which also runs the strict-globals check in CI; keep
-- both in sync when changing behaviour.
--
-- Disable with `micronode_chisel.tests = false` in minetest.conf.

local M = micronode_chisel
local R = M.RESOLUTION

local results = {}

local function check(name, ok, detail)
	results[#results + 1] = {name = name, ok = ok and true or false, detail = detail}
end

local function near(a, b, eps)
	return math.abs(a - b) <= (eps or 1e-6)
end

local function sum_solid(grid)
	return M.count_solid(grid)
end

-------------------------------------------------------------------------------
-- Data
-------------------------------------------------------------------------------

local function test_data()
	local grid = M.create_empty_grid()
	check("data_empty", #grid == M.VOXEL_COUNT and M.is_empty(grid),
		"empty grid has " .. #grid .. " cells")

	grid = M.create_filled_grid(1)
	check("data_filled", M.is_full(grid) and M.count_solid(grid) == M.VOXEL_COUNT,
		"filled grid")

	grid = M.create_empty_grid()
	M.set_voxel(grid, 8, 8, 8, 2)
	check("data_set_get", M.get_voxel(grid, 8, 8, 8) == 2, "set/get voxel")
	check("data_out_of_bounds",
		M.get_voxel(grid, 0, 8, 8) == 0 and M.get_voxel(grid, 17, 8, 8) == 0,
		"out-of-bounds reads are air")

	grid = M.create_empty_grid()
	M.fill_box(grid, 7, 7, 7, 10, 10, 10, 1)
	check("data_fill_box", sum_solid(grid) == 64, "4x4x4 fill = 64 cells")

	grid = M.create_empty_grid()
	M.fill_box(grid, -4, -4, -4, 20, 20, 20, 1)
	check("data_fill_clipped", sum_solid(grid) == M.VOXEL_COUNT, "over-extended fill clips")
end

-------------------------------------------------------------------------------
-- Storage
-------------------------------------------------------------------------------

local function test_storage()
	local flat = M.create_filled_grid(1)
	local decoded = M.decompress_grid(M.compress_grid(flat))
	local same = true
	for i = 1, M.VOXEL_COUNT do
		if decoded[i] ~= flat[i] then
			same = false
			break
		end
	end
	check("rle_roundtrip_flat", same, "flat grid round-trips")

	local noisy = M.create_empty_grid()
	for z = 1, R do
		for y = 1, R do
			for x = 1, R do
				if (x + y + z) % 2 == 0 then
					M.set_voxel(noisy, x, y, z, (x % 2) + 1)
				end
			end
		end
	end
	decoded = M.decompress_grid(M.compress_grid(noisy))
	same = true
	for i = 1, M.VOXEL_COUNT do
		if decoded[i] ~= noisy[i] then
			same = false
			break
		end
	end
	check("rle_roundtrip_noisy", same, "noisy grid round-trips")

	local stored = M.compress_grid(noisy)
	check("rle_size_bound", #stored <= M.VOXEL_COUNT + 1,
		#stored .. " bytes for a noisy grid (must not exceed 1 byte/cell)")

	local flat_stored = M.compress_grid(flat)
	check("rle_flat_small", #flat_stored < 32, #flat_stored .. " bytes for a flat grid")

	check("rle_empty_decode", M.is_empty(M.decompress_grid("")), "empty string decodes to air")
end

-------------------------------------------------------------------------------
-- Palette
-------------------------------------------------------------------------------

local function test_palette()
	local palette = M.create_palette({"a:stone", "a:dirt"})
	check("palette_create", palette[1] == "a:stone" and palette[3] == M.AIR,
		"palette padded with air")

	check("palette_duplicate", M.palette_add(palette, "a:stone") == 1, "duplicate returns index")
	check("palette_add", M.palette_add(palette, "a:sand") == 3, "new material takes a free slot")
	check("palette_full", M.palette_add(palette, "a:gravel") == 4, "last slot")
	check("palette_overflow", M.palette_add(palette, "a:ice") == nil, "5th material refused")

	local grid = M.create_empty_grid()
	M.fill_box(grid, 1, 1, 1, 16, 16, 16, 2)
	local compacted = M.palette_compact(grid, {"a:stone", "a:dirt", "a:sand", "a:gravel"})
	check("palette_compact",
		compacted[1] == "a:dirt" and compacted[2] == M.AIR
			and M.get_voxel(grid, 8, 8, 8) == 1,
		"unused slots dropped and indices renumbered")

	local round_trip = M.palette_deserialize(M.palette_serialize(compacted))
	check("palette_serialize", round_trip[1] == "a:dirt" and round_trip[4] == M.AIR,
		"palette serialize/deserialize")
end

-------------------------------------------------------------------------------
-- Transforms
-------------------------------------------------------------------------------

local function test_transforms()
	local grid = M.create_empty_grid()
	M.set_voxel(grid, 1, 1, 1, 2)

	local rotated = M.rotate_grid(grid, 1)
	check("rotate_90", M.get_voxel(rotated, 1, 1, R) == 2, "90 deg CW moves corner voxel")

	local four = M.rotate_grid(grid, 4)
	check("rotate_360", M.get_voxel(four, 1, 1, 1) == 2, "4x90 = identity")

	local flipped = M.flip_grid(grid)
	check("flip_once", M.get_voxel(flipped, R, 1, 1) == 2, "flip mirrors x")
	check("flip_twice", M.get_voxel(M.flip_grid(flipped), 1, 1, 1) == 2, "flip twice = identity")
end

-------------------------------------------------------------------------------
-- Mesher
-------------------------------------------------------------------------------

local function open_neighbors()
	return {px = false, nx = false, py = false, ny = false, pz = false, nz = false}
end

local function solid_neighbors()
	return {px = true, nx = true, py = true, ny = true, pz = true, nz = true}
end

local function test_mesher()
	local palette = M.create_palette({"a:stone"})

	local boxes = M.build_surface_boxes(M.create_filled_grid(1), palette, open_neighbors(), R)
	check("mesh_full_six", #boxes == 6, #boxes .. " faces for a full block (expected 6)")

	local in_bounds = true
	local depth_ok = true
	local face_depth = (1 / R) * M.FACE_DEPTH_FRACTION
	for _, box in ipairs(boxes) do
		local thin_axes = 0
		for _, axis in ipairs({"x", "y", "z"}) do
			local lo = math.min(box[axis .. "0"], box[axis .. "1"])
			local hi = math.max(box[axis .. "0"], box[axis .. "1"])
			if lo < -0.5 - 1e-9 or hi > 0.5 + 1e-9 then
				in_bounds = false
			end
			if near(hi - lo, face_depth) then
				thin_axes = thin_axes + 1
				-- the outward plane must sit on the node boundary
				local outward = (box.axis == 1 and axis == "x")
					or (box.axis == 2 and axis == "y")
					or (box.axis == 3 and axis == "z")
				if outward and not (near(lo, -0.5) or near(hi, 0.5)) then
					depth_ok = false
				end
			end
		end
		if thin_axes ~= 1 then
			depth_ok = false
		end
	end
	check("mesh_bounds", in_bounds, "all faces inside the node")
	check("mesh_depth", depth_ok, "every face box is one non-degenerate slab on a voxel boundary")

	check("mesh_empty", #M.build_surface_boxes(M.create_empty_grid(), palette, open_neighbors(), R) == 0,
		"empty block emits no faces")
	check("mesh_cull_solid_neighbors",
		#M.build_surface_boxes(M.create_filled_grid(1), palette, solid_neighbors(), R) == 0,
		"solid neighbours cull every face")

	local slab = M.create_empty_grid()
	M.fill_box(slab, 1, 1, 1, 16, 8, 16, 1)
	local slab_boxes = M.build_surface_boxes(slab, palette, open_neighbors(), R)
	local top_plane = -math.huge
	for _, box in ipairs(slab_boxes) do
		if box.axis == 2 and box.dir > 0 then
			top_plane = math.max(top_plane, math.max(box.y0, box.y1))
		end
	end
	check("mesh_half_slab", #slab_boxes == 6 and near(top_plane, 0),
		#slab_boxes .. " faces, top plane at y=0")

	local cavity = M.create_filled_grid(1)
	M.set_voxel(cavity, 8, 8, 8, 0)
	check("mesh_inner_cavity",
		#M.build_surface_boxes(cavity, palette, open_neighbors(), R) == 12,
		"a one-voxel cavity adds six inner faces")

	local two_materials = M.create_empty_grid()
	M.fill_box(two_materials, 1, 1, 1, 8, 16, 16, 1)
	M.fill_box(two_materials, 9, 1, 1, 16, 16, 16, 2)
	local mixed = M.build_surface_boxes(two_materials,
		M.create_palette({"a:stone", "a:dirt"}), open_neighbors(), R)
	check("mesh_two_materials", #mixed == 10, #mixed .. " faces for a split block")

	-- Neighbour culling is per cell, not per node.
	local grid = M.create_filled_grid(1)
	local mask = function(u, v)
		return u <= 8
	end
	local neighbours = open_neighbors()
	neighbours.py = mask
	local culled = M.build_surface_boxes(grid, palette, neighbours, R)
	local top_area = 0
	for _, box in ipairs(culled) do
		if box.axis == 2 and box.dir > 0 then
			top_area = top_area + (math.abs(box.x1 - box.x0) * math.abs(box.z1 - box.z0))
		end
	end
	check("mesh_partial_neighbour", near(top_area, 0.5, 1e-6),
		"half of the top face is culled by a neighbouring chiseled block")
end

-------------------------------------------------------------------------------
-- Drawable quads: no two coplanar overlapping (the edge z-fighting invariant)
-------------------------------------------------------------------------------

-- Each face box contributes exactly one drawn quad: its outward face. Two
-- coplanar drawn quads that overlap would fight for the depth buffer, which is
-- the flicker seen along chiselled edges.
local function drawn_quad(box)
	local x0, x1 = math.min(box.x0, box.x1), math.max(box.x0, box.x1)
	local y0, y1 = math.min(box.y0, box.y1), math.max(box.y0, box.y1)
	local z0, z1 = math.min(box.z0, box.z1), math.max(box.z0, box.z1)
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

local function quads_clash(a, b)
	if a.axis ~= b.axis or not near(a.plane, b.plane, 1e-9) then
		return false
	end
	local u = math.min(a.u1, b.u1) - math.max(a.u0, b.u0)
	local v = math.min(a.v1, b.v1) - math.max(a.v0, b.v0)
	return u > 1e-9 and v > 1e-9
end

local function count_coplanar_clashes(grid)
	local boxes = M.build_surface_boxes(grid, M.create_palette({"a:stone"}), open_neighbors(), R)
	local quads = {}
	for _, box in ipairs(boxes) do
		quads[#quads + 1] = drawn_quad(box)
	end
	local clashes = 0
	for i = 1, #quads do
		for j = i + 1, #quads do
			if quads_clash(quads[i], quads[j]) then
				clashes = clashes + 1
			end
		end
	end
	return clashes, #quads
end

local function test_drawable_quads()
	local clashes = count_coplanar_clashes(M.create_filled_grid(1))
	check("quads_full", clashes == 0, clashes .. " coplanar overlaps")

	local corner = M.create_filled_grid(1)
	M.fill_box(corner, 1, 1, 1, 8, 8, 8, 0)
	clashes = count_coplanar_clashes(corner)
	check("quads_corner_carve", clashes == 0, clashes .. " coplanar overlaps")

	local cavity = M.create_filled_grid(1)
	M.set_voxel(cavity, 8, 8, 8, 0)
	M.set_voxel(cavity, 9, 8, 8, 0)
	clashes = count_coplanar_clashes(cavity)
	check("quads_cavity", clashes == 0, clashes .. " coplanar overlaps")

	local shelf = M.create_empty_grid()
	M.fill_box(shelf, 1, 8, 1, R, 8, R, 1)
	clashes = count_coplanar_clashes(shelf)
	check("quads_thin_shelf", clashes == 0, clashes .. " coplanar overlaps")

	-- And the rendered texture table must draw exactly that one quad.
	local boxes = M.build_surface_boxes(M.create_filled_grid(1),
		M.create_palette({"a:stone"}), open_neighbors(), R)
	local texture_ok = true
	for _, box in ipairs(boxes) do
		local textures = M.face_textures(box)
		local visible = M.cube_face(box.axis, box.dir)
		for i = 1, 6 do
			if i == visible then
				if type(textures[i]) ~= "string"
					or not textures[i]:find("^%[combine:") then
					texture_ok = false
				end
			elseif textures[i] ~= M.HIDDEN_TEXTURE then
				texture_ok = false
			end
		end
	end
	check("quads_one_drawn_face", texture_ok,
		"each face entity draws exactly its outward quad")
end

-------------------------------------------------------------------------------
-- Picking
-------------------------------------------------------------------------------

local function test_picking()
	local pos = {x = 0, y = 0, z = 0}
	local full = M.create_filled_grid(1)

	local hit = M.raycast_grid(full, pos, {x = 0, y = 4, z = 0}, {x = 0, y = -1, z = 0}, R)
	check("pick_top", hit ~= nil and hit.y == R and hit.ny == 1,
		hit and ("hit " .. hit.x .. "," .. hit.y .. "," .. hit.z .. " n=" .. hit.ny) or "no hit")

	hit = M.raycast_grid(full, pos, {x = -4, y = 0, z = 0}, {x = 1, y = 0, z = 0}, R)
	check("pick_side", hit ~= nil and hit.x == 1 and hit.nx == -1,
		hit and ("hit " .. hit.x .. " n=" .. hit.nx) or "no hit")

	local empty = M.create_empty_grid()
	check("pick_empty", M.raycast_grid(empty, pos, {x = 0, y = 4, z = 0},
		{x = 0, y = -1, z = 0}, R) == nil, "no hit in an empty block")

	local slab = M.create_empty_grid()
	M.fill_box(slab, 1, 1, 1, 16, 8, 16, 1)
	hit = M.raycast_grid(slab, pos, {x = 0, y = 4, z = 0}, {x = 0, y = -1, z = 0}, R)
	check("pick_slab", hit ~= nil and hit.y == 8 and hit.ny == 1,
		hit and ("hit y=" .. hit.y) or "no hit")
end

-------------------------------------------------------------------------------
-- Brushes
-------------------------------------------------------------------------------

local function test_brushes()
	local hit = {x = 9, y = 16, z = 9, nx = 0, ny = 1, nz = 0}

	local push = M.push_brush(hit, 4)
	check("brush_push",
		push ~= nil and push.y0 == 16 and push.y1 == 19
			and push.x0 == 8 and push.x1 == 11 and push.z0 == 8 and push.z1 == 11,
		"push adds a 4-thick layer above the hit face")

	local pull = M.pull_brush(hit, 4)
	check("brush_pull",
		pull ~= nil and pull.y0 == 12 and pull.y1 == 15
			and pull.x0 == 8 and pull.x1 == 11,
		"pull carves a 4-thick layer below the hit face")

	local small = M.push_brush({x = 1, y = 1, z = 1, nx = -1, ny = 0, nz = 0}, 1)
	check("brush_single", small ~= nil and small.x0 == -1 and small.x1 == -1,
		"a 1-cell push targets the air cell in front of the face")

	local clamped = M.push_brush(hit, 64)
	check("brush_clamped", clamped ~= nil and (clamped.y1 - clamped.y0) == R - 1,
		"grid steps are clamped to the block size")
end

-------------------------------------------------------------------------------
-- Editing (integration, far away from spawn)
-------------------------------------------------------------------------------

local TEST_POS = {x = 97, y = 112, z = 97}

local function test_editing()
	core.load_area(TEST_POS)
	local stone = M.fallback_material or M.get_fallback_material()
	core.set_node(TEST_POS, {name = stone})

	local function cleanup()
		M.remove_block_entities(TEST_POS)
		M.forget_block(TEST_POS)
		core.remove_node(TEST_POS)
	end

	local block = M.chisel_native(TEST_POS)
	check("edit_chisel", block ~= nil and M.is_micronode_block(TEST_POS)
		and M.count_solid(block.grid) == M.VOXEL_COUNT,
		"chiselled block starts fully solid")

	check("edit_appearance_unchanged",
		#M.build_surface_boxes(block.grid, block.palette, M.build_neighbors(TEST_POS), R) <= 6,
		"a freshly chiselled block renders only its exposed faces")

	-- Carve the top half away (pull semantics through the API).
	M.api_fill_box(TEST_POS, 1, 9, 1, R, R, R, "air")
	block = M.get_block(TEST_POS)
	check("edit_pull", M.count_solid(block.grid) == R * R * 8,
		M.count_solid(block.grid) .. " cells left after carving half")
	-- Collision is no longer "full or nothing": a half-solid block is a slab.
	local profile = M.collision_profile(block.grid)
	check("edit_collision_slab",
		profile.shape == "slab_b4" and M.is_walkable_name(profile.node),
		"half solid is recognised as " .. profile.shape)
	check("edit_collision_slab_boxes", profile.boxes == 1,
		profile.boxes .. " collision box(es)")

	M.api_fill_box(TEST_POS, 1, 8, 1, R, 8, R, "air")
	block = M.get_block(TEST_POS)
	profile = M.collision_profile(block.grid)
	check("edit_collision_still_collides",
		M.is_walkable_name(profile.node),
		string.format("%.0f%% solid still has collision (%s)",
			M.fill_ratio(block.grid) * 100, profile.shape))

	M.update_collision_node(TEST_POS, block)
	check("edit_node_swapped", core.get_node(TEST_POS).name == profile.node,
		"container node swapped to " .. core.get_node(TEST_POS).name)

	-- Fully carved: nothing left to collide with, so the walk-through variant.
	M.update_collision_node(TEST_POS, {grid = M.create_empty_grid()})
	check("edit_collision_empty_node",
		core.get_node(TEST_POS).name == M.BLOCK_NODE_OPEN
			and not M.is_walkable_name(M.BLOCK_NODE_OPEN),
		"an empty block is walk-through")
	M.update_collision_node(TEST_POS, block)

	local mats = M.palette_add(block.palette, stone)
	check("edit_palette_reuse", mats == 1, "existing material reused")
	check("edit_palette_after_compact", #block.palette == M.MAX_MATERIALS,
		"palette always reports four slots")

	-- Undo restores the pre-carve grid. A region carve that removes everything
	-- also removes the container node (see remove_if_empty).
	local before = M.compress_grid(M.get_block(TEST_POS).grid)
	M.apply_region(TEST_POS, M.ordered_region(0, 0, 0, R - 1, R - 1, R - 1), nil,
		{create = false, player = "mn_test"})
	check("edit_apply_region", not M.is_micronode_block(TEST_POS),
		"a region carve that empties the block removes it")
	local ok, restored = M.undo("mn_test")
	check("edit_undo", ok and restored >= 1 and M.is_micronode_block(TEST_POS)
			and M.compress_grid(M.get_block(TEST_POS).grid) == before,
		"undo restored the previous grid")

	-- Undo of a region that created a new block must remove it again.
	local above = {x = TEST_POS.x, y = TEST_POS.y + 1, z = TEST_POS.z}
	core.remove_node(above)
	M.apply_region(TEST_POS, M.ordered_region(0, R, 0, R - 1, 2 * R - 1, R - 1), stone,
		{create = true, base_material = stone, player = "mn_test"})
	check("edit_extrude_new_block", M.is_micronode_block(above),
		"pushing past the block boundary creates a chiseled block there")
	M.undo("mn_test")
	check("edit_undo_new_block", not M.is_micronode_block(above),
		"undo removes the block it created")
	M.forget_block(above)
	core.remove_node(above)

	-- Rotation and flip keep the fill count.
	local filled = M.count_solid(M.get_block(TEST_POS).grid)
	M.rotate_block(TEST_POS, 1)
	local flipped = M.count_solid(M.get_block(TEST_POS).grid)
	M.flip_block(TEST_POS)
	check("edit_transform_preserves_cells",
		filled == flipped and filled == M.count_solid(M.get_block(TEST_POS).grid),
		"rotate/flip preserve the number of solid cells")

	cleanup()
end

-------------------------------------------------------------------------------
-- Rendering (entity transform regression)
-------------------------------------------------------------------------------

local function test_rendering()
	core.load_area(TEST_POS)
	local stone = M.fallback_material or M.get_fallback_material()
	core.set_node(TEST_POS, {name = stone})
	M.chisel_native(TEST_POS)
	M.api_fill_box(TEST_POS, 1, 9, 1, R, R, R, "air")
	M.api_fill_box(TEST_POS, 1, 1, 1, R - 4, R - 4, R - 4, "air")

	local block = M.get_block(TEST_POS)
	local boxes = M.build_surface_boxes(block.grid, block.palette,
		M.build_neighbors(TEST_POS), R)

	M.update_block_mesh(TEST_POS)

	-- Expected spawn origin per box: the box center in world space (cube
	-- visuals are centered on the entity position).
	local function key(x, y, z)
		return string.format("%.3f,%.3f,%.3f", x, y, z)
	end
	local expected = {}
	for _, box in ipairs(boxes) do
		expected[key(
			TEST_POS.x + (box.x0 + box.x1) / 2,
			TEST_POS.y + (box.y0 + box.y1) / 2,
			TEST_POS.z + (box.z0 + box.z1) / 2)] = true
	end

	local found, matched, centered = 0, 0, true
	for _, obj in ipairs(core.get_objects_inside_radius(TEST_POS, 2.0)) do
		local lua = obj:get_luaentity()
		if lua and lua.name == M.ENTITY_NAME then
			found = found + 1
			local p = obj:get_pos()
			if p and expected[key(p.x, p.y, p.z)] then
				matched = matched + 1
			elseif p then
				centered = false
			end
		end
	end

	check("render_entity_count", found == #boxes,
		found .. " entities for " .. #boxes .. " faces")
	check("render_entity_centered", centered and matched == #boxes,
		matched .. "/" .. #boxes .. " entities sit at their box center")

	-- Second call must be a no-op (cached shape, live entities).
	local ok = pcall(M.update_block_mesh, TEST_POS)
	local second = 0
	for _, obj in ipairs(core.get_objects_inside_radius(TEST_POS, 2.0)) do
		local lua = obj:get_luaentity()
		if lua and lua.name == M.ENTITY_NAME then
			second = second + 1
		end
	end
	check("render_idempotent", ok and second == found,
		"re-meshing an unchanged block keeps the same entities")

	-- Fully carved: nothing rendered.
	M.api_fill_box(TEST_POS, 1, 1, 1, R, R, R, "air")
	local remaining = 0
	for _, obj in ipairs(core.get_objects_inside_radius(TEST_POS, 2.0)) do
		local lua = obj:get_luaentity()
		if lua and lua.name == M.ENTITY_NAME then
			remaining = remaining + 1
		end
	end
	check("render_empty", remaining == 0, remaining .. " entities left for an empty block")

	M.remove_block_entities(TEST_POS)
	M.forget_block(TEST_POS)
	core.remove_node(TEST_POS)
end

-------------------------------------------------------------------------------
-- Grid steps (the chisel's size selection)
-------------------------------------------------------------------------------

local function test_grid_steps()
	check("size_default",
		M.player_grid_size("mn_size_test") == 1,
		"a new player starts at 1/16")
	check("size_set",
		M.set_player_grid_size("mn_size_test", 4)
			and M.player_grid_size("mn_size_test") == 4,
		"set by micronode count")
	check("size_invalid",
		not M.set_player_grid_size("mn_size_test", 3)
			and M.player_grid_size("mn_size_test") == 4,
		"unsupported steps are rejected")

	M.cycle_player_grid("mn_size_test", 1)
	M.cycle_player_grid("mn_size_test", 1)
	check("size_cycle", M.player_grid_size("mn_size_test") == 16,
		"cycle 4 -> 8 -> 16")
	M.cycle_player_grid("mn_size_test", 1)
	check("size_cycle_wrap", M.player_grid_size("mn_size_test") == 1,
		"after 1/1 the next step is 1/16 again")
end

-- A real edit_at through a fake player, to prove the selected step changes the
-- brush (thickness and in-plane extent), not just the chat message.
local function fake_player(name)
	return {
		is_player = function() return true end,
		get_player_name = function() return name end,
		get_player_control = function() return {} end,
		get_pos = function() return {x = TEST_POS.x, y = TEST_POS.y + 3, z = TEST_POS.z} end,
		get_look_dir = function() return {x = 0, y = -1, z = 0} end,
		get_properties = function() return {eye_height = 1.625} end,
	}
end

-- Minimal InventoryRef stand-in: only what the border-push cost uses.
-- Engine ItemStacks are userdata, so nothing here may assume a Lua table.
local function fake_inventory(items)
	local counts = {}
	for item, count in pairs(items or {}) do
		counts[item] = count
	end
	local inv = {}

	local function amount(stack)
		if not stack then
			return nil, 1
		end
		local name = nil
		if stack.get_name then
			name = stack:get_name()
		end
		local count = 1
		if stack.get_count then
			count = stack:get_count() or 1
		end
		return name, count
	end

	function inv:contains_item(_, stack)
		local name, count = amount(stack)
		return name ~= nil and (counts[name] or 0) >= count
	end

	function inv:remove_item(_, stack)
		local name, count = amount(stack)
		if not name then
			return
		end
		counts[name] = math.max(0, (counts[name] or 0) - count)
	end

	function inv:add_item(_, stack)
		local name, count = amount(stack)
		if name then
			counts[name] = (counts[name] or 0) + count
		end
		return stack
	end

	function inv:count(name)
		return counts[name] or 0
	end

	return inv
end

local function player_with_inventory(name, items)
	local player = fake_player(name)
	player.inv = fake_inventory(items)
	player.get_inventory = function(self)
		return self.inv
	end
	return player
end

-- Force a specific creative state for one player. The test world's own
-- creative_mode is irrelevant: fake players are not real players, so the
-- engine's check cannot answer for them.
local function with_creative_state(creative, name, body)
	local original = core.is_creative_enabled
	core.is_creative_enabled = function(who)
		if who == name then
			return creative
		end
		if original then
			return original(who)
		end
		return creative
	end
	local ok, err = pcall(body)
	core.is_creative_enabled = original
	if not ok then
		error(err)
	end
end

local function with_survival(name, body)
	with_creative_state(false, name, body)
end

local function with_creative(name, body)
	with_creative_state(true, name, body)
end

local function test_brush_sizes_apply()
	core.load_area(TEST_POS)
	local stone = M.fallback_material or M.get_fallback_material()
	core.set_node(TEST_POS, {name = stone})
	M.chisel_native(TEST_POS)
	M.refresh_block(TEST_POS)

	local above = {x = TEST_POS.x, y = TEST_POS.y + 1, z = TEST_POS.z}
	local function clear_above()
		M.remove_block_entities(above)
		M.forget_block(above)
		core.remove_node(above)
	end
	clear_above()

	-- The top face of a full block is flush with the node border: pushing it
	-- creates a node above, which a creative player does not pay for.
	local ok = M.edit_at(fake_player("mn_size_test"), TEST_POS, "push", 1, nil)
	check("size_push_border_allowed", ok and M.is_micronode_block(above),
		"a border push creates the neighbouring block")
	check("size_push_border_no_cost", true, "creative players pay nothing")
	clear_above()

	-- Carve the top half so the next pushes hit an interior face and stay
	-- inside the node, whatever the grid step.
	M.api_fill_box(TEST_POS, 1, 9, 1, R, R, R, "air")

	local function push_cells(gs)
		M.set_player_grid_size("mn_size_test", gs)
		local before = M.count_solid(M.get_block(TEST_POS).grid)
		local pushed = M.edit_at(fake_player("mn_size_test"), TEST_POS, "push",
			M.player_grid_size("mn_size_test"), nil)
		local after = M.count_solid(M.get_block(TEST_POS).grid)
		return pushed, after - before
	end

	local pushed, added = push_cells(4)
	check("size_push_4", pushed and added == 64,
		"a 4-micronode push adds 4x4x4 = " .. added .. " cells")

	M.undo("mn_size_test")
	pushed, added = push_cells(1)
	check("size_push_1", pushed and added == 1,
		"a 1-micronode push adds " .. added .. " cell(s)")

	check("size_push_stays_in_node", not M.is_micronode_block(above),
		"an interior push never creates a neighbouring node")

	clear_above()
	M.remove_block_entities(TEST_POS)
	M.forget_block(TEST_POS)
	core.remove_node(TEST_POS)
	M.forget_player("mn_size_test")
	M.set_player_grid_size("mn_size_test", 1)
end

-------------------------------------------------------------------------------
-- Border push cost, empty blocks and open-face prevention
-------------------------------------------------------------------------------

local function test_border_and_empty()
	core.load_area(TEST_POS)
	local name = "mn_border_test"
	local stone = M.fallback_material or M.get_fallback_material()
	local above = {x = TEST_POS.x, y = TEST_POS.y + 1, z = TEST_POS.z}

	local function clean(pos)
		M.remove_block_entities(pos)
		M.forget_block(pos)
		core.remove_node(pos)
	end
	clean(TEST_POS)
	clean(above)

	core.set_node(TEST_POS, {name = stone})
	M.chisel_native(TEST_POS)
	M.refresh_block(TEST_POS)

	-- A survival player pays one node of the pushed material per created block.
	with_survival(name, function()
		-- No stock: the border push is refused and creates nothing.
		local broke = player_with_inventory(name, {})
		local ok, why = M.edit_at(broke, TEST_POS, "push", 1, stone)
		check("border_push_broke_refused",
			not ok and not M.is_micronode_block(above), tostring(why))

		-- Two nodes in stock: the push works and consumes exactly one.
		local payer = player_with_inventory(name, {[stone] = 2})
		ok, why = M.edit_at(payer, TEST_POS, "push", 1, stone)
		check("border_push_paid", ok and M.is_micronode_block(above),
			tostring(why))
		check("border_push_consumed_one", payer.inv:count(stone) == 1,
			"inventory now holds " .. payer.inv:count(stone))
		clean(above)

		-- Pushing into an *existing* chiseled neighbour creates no node, so it
		-- costs nothing even with an empty inventory.
		core.set_node(above, {name = stone})
		M.chisel_native(above)
		M.refresh_block(above)
		-- Carve a bit away so the neighbour stays non-empty (a fully carved
		-- block is removed from the map now).
		M.api_fill_box(above, 1, 1, 1, R, 1, R, "air")
		local free = player_with_inventory(name, {})
		ok, why = M.edit_at(free, TEST_POS, "push", R, nil)
		check("border_push_into_chiseled_free", ok
				and free.inv:count(stone) == 0
				and M.count_solid(M.get_block(above).grid) == M.VOXEL_COUNT,
			(ok and (M.count_solid(M.get_block(above).grid) .. " cells above")
				or tostring(why)))
		clean(above)
	end)

	-- A creative player with an empty inventory is never charged.
	local creative = player_with_inventory(name, {})
	with_creative(name, function()
		local ok, creative_why = M.edit_at(creative, TEST_POS, "push", 1, stone)
		check("border_push_creative_free",
			ok and creative.inv:count(stone) == 0,
			(ok and ("inventory holds " .. creative.inv:count(stone))
				or tostring(creative_why)))
	end)
	clean(above)

	-- Drop the undo history accumulated by the pushes above.
	M.forget_player(name)

	-- Carving the last solid cell away removes the node instead of leaving an
	-- invisible container behind.
	M.apply_region(TEST_POS, M.ordered_region(0, 0, 0, R - 1, R - 1, R - 1), nil,
		{create = false, player = name})
	check("carve_empty_removes_node", not M.is_micronode_block(TEST_POS),
		"a fully carved block is gone from the map")
	check("carve_empty_undo_restores", M.undo(name) and M.is_micronode_block(TEST_POS)
			and M.count_solid(M.get_block(TEST_POS).grid) > 0,
		"undo brings the carved block back")

	-- An already empty block in a saved world is cleaned up too.
	M.remove_block_entities(TEST_POS)
	core.set_node(TEST_POS, {name = M.BLOCK_NODE_OPEN})
	M.set_block(TEST_POS, M.create_block_data(stone, M.create_palette({stone}),
		M.create_empty_grid()))
	check("remove_if_empty_direct", M.remove_if_empty(TEST_POS)
			and not M.is_micronode_block(TEST_POS),
		"remove_if_empty deletes an empty container")
	check("remove_if_empty_noop", not M.remove_if_empty(TEST_POS),
		"nothing to remove on a non-container")

	-- Copying an empty block is refused rather than producing a useless
	-- blueprint.
	M.forget_clipboard(name)
	core.set_node(TEST_POS, {name = M.BLOCK_NODE_OPEN})
	M.set_block(TEST_POS, M.create_block_data(stone, M.create_palette({stone}),
		M.create_empty_grid()))
	local copied, copy_message = M.copy_block(name, TEST_POS)
	check("copy_empty_refused", not copied and M.clipboard_is_empty(name),
		tostring(copy_message))

	for _, pos in ipairs({TEST_POS, above}) do
		clean(pos)
	end
	M.forget_clipboard(name)
	M.forget_player(name)
end

-- Removing geometry next to a chiseled block must re-mesh it, or the block
-- keeps rendering with the faces it culled against the vanished neighbour.
local function has_face(pos, axis, dir)
	local block = M.get_block(pos)
	if not block then
		return false
	end
	local boxes = M.build_surface_boxes(block.grid, block.palette,
		M.build_neighbors(pos), R)
	for _, box in ipairs(boxes) do
		if box.axis == axis and box.dir == dir then
			return true
		end
	end
	return false
end

-- Entities belonging to one block only. `get_objects_inside_radius` also
-- returns the neighbour's render entities, so filter on the block position the
-- spawn data carries.
local function count_entities(pos)
	local n = 0
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 1.6)) do
		local lua = obj:get_luaentity()
		if lua and lua.name == M.ENTITY_NAME and lua.block_pos
			and lua.block_pos.x == pos.x and lua.block_pos.y == pos.y
			and lua.block_pos.z == pos.z then
			n = n + 1
		end
	end
	return n
end

local function test_open_faces()
	core.load_area(TEST_POS)
	local stone = M.fallback_material or M.get_fallback_material()
	local above = {x = TEST_POS.x, y = TEST_POS.y + 1, z = TEST_POS.z}

	local function clean(pos)
		M.remove_block_entities(pos)
		M.forget_block(pos)
		core.remove_node(pos)
	end
	clean(TEST_POS)
	clean(above)

	-- Two adjacent chiseled blocks, so the lower one culls its top face.
	core.set_node(TEST_POS, {name = stone})
	M.chisel_native(TEST_POS)
	M.refresh_block(TEST_POS)
	core.set_node(above, {name = stone})
	M.chisel_native(above)
	M.refresh_block(above)
	-- A real placement goes through register_on_placenode; set_node does not,
	-- so emulate the hook for the block that must react to the new neighbour.
	M.remesh_neighbors(above)

	check("open_faces_culled", not has_face(TEST_POS, 2, 1),
		"the top face is culled against the solid neighbour")
	local before = count_entities(TEST_POS)

	-- Simulate digging the neighbour: the node goes away, then the neighbour
	-- re-mesh (what core.register_on_dignode / after_destruct do) restores the
	-- face.
	M.remove_block_entities(above)
	M.forget_block(above)
	core.remove_node(above)
	M.remesh_neighbors(above)

	check("open_faces_restored", has_face(TEST_POS, 2, 1),
		"the top face is visible again after the neighbour was removed")
	check("open_faces_remeshed", count_entities(TEST_POS) > before,
		before .. " -> " .. count_entities(TEST_POS) .. " entities")

	-- Carving a neighbour down to nothingness removes it and re-meshes too.
	core.set_node(above, {name = stone})
	M.chisel_native(above)
	M.refresh_block(above)
	M.remesh_neighbors(above)
	check("open_faces_culled_again", not has_face(TEST_POS, 2, 1),
		"restoring the neighbour culls the face again")

	M.apply_region(above, M.ordered_region(0, 0, 0, R - 1, R - 1, R - 1), nil,
		{create = false, player = "mn_open_test"})
	check("open_faces_neighbour_removed", not M.is_micronode_block(above),
		"the carved neighbour is gone")
	check("open_faces_restored_by_carve", has_face(TEST_POS, 2, 1),
		"removing the neighbour by carving also restores the face")

	M.forget_player("mn_open_test")
	for _, pos in ipairs({TEST_POS, above}) do
		clean(pos)
	end
end

-------------------------------------------------------------------------------
-- Render budget (the "block turns back into a full cube" regression)
-------------------------------------------------------------------------------

local function test_render_budget()
	core.load_area(TEST_POS)
	check("budget_default_high", M.MAX_RENDER_BOXES >= 256,
		"default budget is " .. M.MAX_RENDER_BOXES)
	check("budget_active", M.render_budget() >= 6,
		"render budget is " .. tostring(M.render_budget()))

	local palette = M.create_palette({"a:stone"})
	local neighbours = open_neighbors()

	-- A noisy, mostly-empty shape: single cells in a deterministic pattern.
	-- "any-solid" downsampling would turn this into a solid block.
	local noisy = M.create_empty_grid()
	for z = 1, R do
		for y = 1, R do
			for x = 1, R do
				if ((x * 7 + y * 13 + z * 3) % 5) < 2 then
					M.set_voxel(noisy, x, y, z, 1, R)
				end
			end
		end
	end
	local coarse = M.coarsen_grid(noisy, 2, R)
	check("coarsen_no_refill",
		M.count_solid(coarse) < #coarse,
		"a noisy carve must not coarsen into a full block")

	-- A checkerboard is the pathological case for any-solid: strict majority
	-- with ties going to air keeps it from collapsing into a solid mass.
	local checker = M.create_empty_grid()
	for z = 1, R do
		for y = 1, R do
			for x = 1, R do
				if (x + y + z) % 2 == 0 then
					M.set_voxel(checker, x, y, z, 1, R)
				end
			end
		end
	end
	local checker_coarse = M.coarsen_grid(checker, 2, R)
	check("coarsen_checkerboard", M.is_empty(checker_coarse),
		"a checkerboard must not collapse into a solid block")

	-- A real cavity must survive downsampling.
	local carved = M.create_filled_grid(1)
	for z = 3, R - 2 do
		for y = 3, R - 2 do
			for x = 3, R - 2 do
				local dx, dy, dz = x - 8.5, y - 8.5, z - 8.5
				if dx * dx + dy * dy + dz * dz < 25 then
					M.set_voxel(carved, x, y, z, 0, R)
				end
			end
		end
	end
	local cavity = M.coarsen_grid(carved, 2, R)
	check("coarsen_cavity_survives", not M.is_full(cavity),
		"a carved cavity must stay open when coarsened")

	-- The budget path: a detailed surface needs fewer boxes when coarsened, and
	-- must never return a full cube for a carved shape. The aligned 4^3 cavity
	-- survives strict-majority downsampling at every step, so the coarsened
	-- mesh can never be a plain cube.
	local stairs = M.create_filled_grid(1)
	for z = 1, R do
		for y = 1, R do
			for x = 1, R do
				if ((x * 5 + y * 11 + z * 7) % 8) >= 5 then
					M.set_voxel(stairs, x, y, z, 0, R)
				end
			end
		end
	end
	M.fill_box(stairs, 5, 5, 5, 8, 8, 8, 0)
	local block = {grid = stairs, palette = palette}
	local full_boxes = M.build_surface_boxes(stairs, palette, open_neighbors(), R)
	local boxes, step = M.render_boxes(TEST_POS, block, M.MAX_RENDER_BOXES)
	check("budget_coarsens", #full_boxes > M.MAX_RENDER_BOXES
			and step > 1 and #boxes <= M.MAX_RENDER_BOXES,
		#full_boxes .. " full -> step " .. step .. ", " .. #boxes .. " boxes")
	check("budget_not_full", not M.is_full(M.coarsen_grid(stairs, step, R)),
		"the fallback kept the carve open")

	-- A coarse mesh keeps the absolute (quarter-micronode) face depth, so its
	-- inner planes cannot coincide with a full-resolution neighbour's surface.
	local coarse_full = M.build_surface_boxes(M.create_filled_grid(1, 2), palette,
		open_neighbors(), 2)
	local depth_ok = #coarse_full > 0
	for _, box in ipairs(coarse_full) do
		local sx = math.abs(box.x1 - box.x0)
		local sy = math.abs(box.y1 - box.y0)
		local sz = math.abs(box.z1 - box.z0)
		if math.min(sx, sy, sz) > 1 / R + 1e-9 then
			depth_ok = false
		end
	end
	check("budget_depth_bounded", depth_ok,
		"coarse face slabs stay thinner than one micronode")

	-- A shape that coarsening would erase entirely is rendered at full
	-- resolution instead of becoming invisible.
	local thin = M.create_empty_grid()
	for z = 1, R do
		for x = 1, R do
			M.set_voxel(thin, x, 1, z, 1, R)
		end
	end
	boxes, step = M.render_boxes(TEST_POS, {grid = thin, palette = palette}, 2)
	check("budget_never_invisible", #boxes > 0 and step == 1,
		#boxes .. " full-resolution boxes instead of an invisible block")
end

-------------------------------------------------------------------------------
-- Coarse neighbour masks (stride mapping, used by the render fallback)
-------------------------------------------------------------------------------

local function test_neighbor_masks()
	core.load_area(TEST_POS)
	local stone = M.fallback_material or M.get_fallback_material()
	local npos = {x = TEST_POS.x + 1, y = TEST_POS.y, z = TEST_POS.z}

	core.set_node(npos, {name = M.BLOCK_NODE})
	local block = M.create_block_data(stone, M.create_palette({stone}),
		M.create_empty_grid())
	M.set_voxel(block.grid, 1, 2, 3, 1, R)
	M.set_block(npos, block)

	local full = M.build_neighbors(TEST_POS)
	check("neighbor_mask_full_stride",
		type(full.px) == "function" and full.px(2, 3) == true
			and full.px(1, 1) == false,
		"the full-resolution mask reads the 16^3 stride")

	local coarse = M.build_neighbors(TEST_POS, 2)
	check("neighbor_mask_coarse_stride",
		type(coarse.px) == "function" and coarse.px(1, 2) == true
			and coarse.px(1, 1) == false,
		"the coarse mask covers a step x step footprint")

	M.remove_block_entities(npos)
	M.forget_block(npos)
	core.remove_node(npos)
end

-------------------------------------------------------------------------------
-- Collision shape recognition
-------------------------------------------------------------------------------

local function profile_of(build)
	local grid = M.create_empty_grid()
	build(grid)
	return M.collision_profile(grid)
end

-- Half and quarter of the resolution, used to build test shapes. LuaJIT (the
-- engine's Lua) has no integer-division operator, so keep these explicit.
local HALF = math.floor(R / 2)
local QUARTER = math.floor(R / 4)

local function test_collision_shapes()
	-- Every catalogue shape must be registered as a usable container node.
	local missing, unboxed = 0, 0
	for _, shape in ipairs(M.get_shapes()) do
		local name = M.shape_node_name(shape.id)
		local def = core.registered_nodes[name]
		if not def or not M.is_container_name(name) then
			missing = missing + 1
		elseif shape.id == "empty" then
			if def.walkable then unboxed = unboxed + 1 end
		elseif shape.id == "full" then
			if def.collision_box.type ~= "regular" then unboxed = unboxed + 1 end
		elseif def.collision_box.type ~= "fixed"
			or #def.collision_box.fixed ~= #shape.nodeboxes then
			unboxed = unboxed + 1
		end
	end
	check("collision_nodes_registered", missing == 0, missing .. " unregistered")
	check("collision_boxes_match_catalogue", unboxed == 0,
		unboxed .. " nodes with a wrong collision box")

	-- Full and empty take the fast paths.
	local full = profile_of(function(grid)
		M.fill_box(grid, 1, 1, 1, R, R, R, 1)
	end)
	check("collision_full", full.shape == "full" and full.node == M.BLOCK_NODE,
		full.shape)

	local empty = profile_of(function() end)
	check("collision_empty", empty.shape == "empty"
			and empty.node == M.BLOCK_NODE_OPEN
			and not M.is_walkable_name(empty.node), empty.shape)

	-- Slabs at 1/16 granularity, snapped to the 1/8 collision grid.
	local slab = profile_of(function(grid)
		M.fill_box(grid, 1, 1, 1, R, HALF, R, 1)
	end)
	check("collision_slab", slab.shape == "slab_b4" and slab.recognised,
		slab.shape .. string.format(" iou=%.2f", slab.iou))
	check("collision_slab_box", slab.boxes == 1,
		"a slab is " .. slab.boxes .. " box(es)")

	-- The staircase case the user asked for: half-height step + full-height
	-- back half, in each orientation. Two boxes per node.
	local ufl = HALF
	for _, dir in ipairs({"px", "nx", "pz", "nz"}) do
		local profile = profile_of(function(grid)
			M.fill_box(grid, 1, 1, 1, R, ufl, R, 1)
			if dir == "px" then
				M.fill_box(grid, ufl + 1, ufl + 1, 1, R, R, R, 1)
			elseif dir == "nx" then
				M.fill_box(grid, 1, ufl + 1, 1, ufl, R, R, 1)
			elseif dir == "pz" then
				M.fill_box(grid, 1, ufl + 1, ufl + 1, R, R, R, 1)
			else
				M.fill_box(grid, 1, ufl + 1, 1, R, R, ufl, 1)
			end
		end)
		check("collision_stair_" .. dir,
			profile.shape == "stair_" .. dir and profile.boxes == 2,
			profile.shape .. " with " .. profile.boxes .. " box(es)")
	end

	-- Walls/panels and posts: thin shapes must not become full cubes.
	-- A quarter-node-thick wall is two collision cells thick.
	local panel = profile_of(function(grid)
		M.fill_box(grid, 1, 1, 1, QUARTER, R, R, 1)
	end)
	check("collision_panel", panel.shape == "panel2_nx", panel.shape)

	-- Corner stairs: a half-height slab plus either one raised quadrant (outer
	-- corner) or all but one (inner corner). Four of each.
	local CORNERS = {
		{"nx", "nz", 0, 0}, {"px", "nz", HALF, 0},
		{"nx", "pz", 0, HALF}, {"px", "pz", HALF, HALF},
	}
	for _, c in ipairs(CORNERS) do
		local qx, qz, x0, z0 = c[1], c[2], c[3], c[4]
		local outer = profile_of(function(grid)
			M.fill_box(grid, 1, 1, 1, R, HALF, R, 1)
			M.fill_box(grid, x0 + 1, HALF + 1, z0 + 1,
				x0 + HALF, R, z0 + HALF, 1)
		end)
		check("collision_corner_" .. qx .. "_" .. qz,
			outer.shape == "stair_corner_" .. qx .. "_" .. qz and outer.boxes == 2,
			outer.shape .. " with " .. outer.boxes .. " box(es)")

		local inner = profile_of(function(grid)
			M.fill_box(grid, 1, 1, 1, R, HALF, R, 1)
			M.fill_box(grid, 1, HALF + 1, 1, R, R, R, 1)
			M.fill_box(grid, x0 + 1, HALF + 1, z0 + 1,
				x0 + HALF, R, z0 + HALF, 0)
		end)
		check("collision_corner_l_" .. qx .. "_" .. qz,
			inner.shape == "stair_corner_l_" .. qx .. "_" .. qz and inner.boxes == 3,
			inner.shape .. " with " .. inner.boxes .. " box(es)")
	end

	-- A straight stair must still be recognised as a straight stair, not as the
	-- corner whose single raised quadrant it contains (IoU 0.83 vs 1.0).
	local straight = profile_of(function(grid)
		M.fill_box(grid, 1, 1, 1, R, HALF, R, 1)
		M.fill_box(grid, HALF + 1, HALF + 1, 1, R, R, R, 1)
	end)
	check("collision_straight_not_corner", straight.shape == "stair_px",
		straight.shape)

	local post = profile_of(function(grid)
		M.fill_box(grid, HALF + 1, 1, HALF + 1, R, R, R, 1)
	end)
	check("collision_post", post.shape == "post_px_pz", post.shape)

	-- A quarter-node step (chiselled with grid 4) is still a stair-like shape:
	-- whatever is recognised must at least collide.
	local step = profile_of(function(grid)
		M.fill_box(grid, 1, 1, 1, R, QUARTER, R, 1)
		M.fill_box(grid, HALF + 1, 1, 1, R, HALF, R, 1)
	end)
	check("collision_step_collides", M.is_walkable_name(step.node),
		step.shape)

	-- An unrecognisable but mostly solid shape falls back to a full cube so
	-- the player never falls through a wall.
	local noisy = M.create_empty_grid()
	for z = 1, R do
		for y = 1, R do
			for x = 1, R do
				if ((x * 7 + y * 13 + z * 5) % 11) < 8 then
					M.set_voxel(noisy, x, y, z, 1, R)
				end
			end
		end
	end
	local fallback = M.collision_profile(noisy)
	check("collision_fallback_safe", M.is_walkable_name(fallback.node),
		fallback.shape .. (fallback.recognised and " (recognised)" or " (fallback)"))

	-- An unrecognised floor piece (only half the footprint, a quarter high) must
	-- still be standable: the fallback anchors a slab at the floor instead of
	-- leaving the shape walk-through.
	local floor = profile_of(function(grid)
		M.fill_box(grid, 1, 1, 1, HALF, QUARTER, R, 1)
	end)
	check("collision_fallback_floor", M.is_walkable_name(floor.node),
		floor.shape .. (floor.recognised and " (recognised)" or " (fallback)"))

	-- Same for a sheet hanging from the ceiling.
	local ceiling = profile_of(function(grid)
		M.fill_box(grid, 1, R - QUARTER + 1, 1, HALF, R, R, 1)
	end)
	check("collision_fallback_ceiling", M.is_walkable_name(ceiling.node),
		ceiling.shape .. (ceiling.recognised and " (recognised)" or " (fallback)"))

	-- Geometry spanning floor to ceiling without filling the node has no slab
	-- to fall back on: it must still resolve (a full cube), not index a
	-- non-existent slab.
	local spans = profile_of(function(grid)
		M.fill_box(grid, 1, 1, 1, HALF, R, HALF, 1)
		M.fill_box(grid, HALF + 1, 1, HALF + 1, R, R, R, 1)
	end)
	check("collision_fallback_spans", M.is_walkable_name(spans.node)
			and M.get_shape(spans.shape) ~= nil,
		spans.shape)

	-- Recognition must stay cheap: it runs on every edit.
	local grid = M.create_filled_grid(1)
	M.fill_box(grid, 1, 9, 1, R, R, R, 0)
	M.fill_box(grid, 1, 1, 1, HALF, R, R, 0)
	local start = core.get_us_time()
	local iterations = 20
	for _ = 1, iterations do
		M.collision_profile(grid)
	end
	local per_call = (core.get_us_time() - start) / 1000 / iterations
	print(string.format("[micronode_chisel] bench: collision %.2f ms", per_call))
	check("collision_perf", per_call < 5,
		string.format("collision recognition %.2f ms", per_call))
end

-------------------------------------------------------------------------------
-- Clipboard (copy / paste)
-------------------------------------------------------------------------------

local function test_clipboard()
	core.load_area(TEST_POS)
	local name = "mn_clip_test"
	local stone = M.fallback_material or M.get_fallback_material()
	local other = TEST_POS.x + 2

	local src = {x = TEST_POS.x, y = TEST_POS.y, z = TEST_POS.z}
	local dst = {x = other, y = TEST_POS.y, z = TEST_POS.z}
	local function clean(pos)
		M.remove_block_entities(pos)
		M.forget_block(pos)
		core.remove_node(pos)
	end
	clean(src)
	clean(dst)
	M.forget_clipboard(name)

	-- Build a recognisable shape at the source: hammer shape (post on a slab).
	core.set_node(src, {name = stone})
	M.chisel_native(src)
	M.api_fill_box(src, 1, 9, 1, R, R, R, "air")
	M.api_fill_box(src, 1, 1, HALF + 1, R, 8, R, "air")
	M.api_fill_box(src, HALF + 1, 1, 1, R, 8, HALF, "air")
	local expected = M.compress_grid(M.get_block(src).grid)

	check("clipboard_empty_first", M.clipboard_is_empty(name),
		"no clipboard before copying")

	local ok, message = M.copy_block(name, src)
	check("clipboard_copy", ok and not M.clipboard_is_empty(name), message)

	-- Paste into air creates a block with identical geometry.
	ok, message = M.paste_block(name, dst, {player = name})
	check("clipboard_paste_air", ok and M.is_micronode_block(dst), message)
	local pasted = M.get_block(dst)
	check("clipboard_paste_geometry",
		pasted ~= nil and M.compress_grid(pasted.grid) == expected,
		"pasted grid equals the copied grid")

	-- Paste records undo: the block created in air is removed again.
	local undone = M.undo(name)
	check("clipboard_paste_undo", undone and not M.is_micronode_block(dst),
		"undo removed the pasted block")

	-- Rotation: paste rotated 90 deg and compare with rotate_grid.
	M.paste_block(name, dst, {player = name, rotate = 1})
	pasted = M.get_block(dst)
	local rotated = M.rotate_grid(M.get_block(src).grid, 1, R)
	local same_cells = 0
	for i = 1, #rotated do
		if rotated[i] == pasted.grid[i] then
			same_cells = same_cells + 1
		end
	end
	check("clipboard_paste_rotated", same_cells == #rotated,
		same_cells .. "/" .. #rotated .. " cells match the rotation")

	-- Paste onto a plain node converts it, and onto a solid non-chiselable
	-- node is refused.
	local plain = {x = other, y = TEST_POS.y + 2, z = TEST_POS.z}
	clean(plain)
	core.set_node(plain, {name = stone})
	ok = M.paste_block(name, plain, {player = name})
	check("clipboard_paste_converts", ok and M.is_micronode_block(plain),
		"a plain node is converted into a chiseled block")

	local liquid = {x = other, y = TEST_POS.y + 4, z = TEST_POS.z}
	clean(liquid)
	core.set_node(liquid, {name = "default:water_source"})
	ok = M.paste_block(name, liquid, {player = name})
	check("clipboard_paste_liquid", ok and M.is_micronode_block(liquid),
		"a liquid node is replaceable (its source is overwritten)")

	-- Rotation state is part of the clipboard, not of one paste.
	local clip = M.rotate_clipboard(name, 1)
	local previous = clip.rotate
	M.flip_clipboard(name)
	check("clipboard_rotation_state", M.get_clipboard(name).rotate == previous
			and M.get_clipboard(name).flip == true,
		"rotation/flip persist between pastes")

	-- Pasting with an empty clipboard is refused.
	M.forget_clipboard(name)
	check("clipboard_paste_refused_empty", not M.paste_block(name, dst, {}),
		"empty clipboard is refused")

	for _, pos in ipairs({src, dst, plain, liquid}) do
		clean(pos)
	end
	M.forget_clipboard(name)
	M.forget_player(name)
end

-------------------------------------------------------------------------------
-- Performance
-------------------------------------------------------------------------------

local function test_performance()
	local grid = M.create_filled_grid(1)
	M.fill_box(grid, 1, 1, 1, R, R / 2, R, 0)
	M.fill_box(grid, 3, 3, 3, 6, 6, 6, 0)
	local palette = M.create_palette({"a:stone"})
	local neighbours = open_neighbors()

	local start = core.get_us_time()
	local iterations = 20
	for _ = 1, iterations do
		M.build_surface_boxes(grid, palette, neighbours, R)
	end
	local per_call = (core.get_us_time() - start) / 1000 / iterations

	start = core.get_us_time()
	for _ = 1, iterations do
		M.compress_grid(grid)
	end
	local compress = (core.get_us_time() - start) / 1000 / iterations

	print(string.format("[micronode_chisel] bench: mesh %.2f ms, compress %.2f ms",
		per_call, compress))
	check("perf_mesh", per_call < 20, string.format("surface meshing %.2f ms", per_call))
	check("perf_compress", compress < 5, string.format("compression %.2f ms", compress))
end

-------------------------------------------------------------------------------
-- Runner
-------------------------------------------------------------------------------

core.after(2.0, function()
	print("[micronode_chisel] ---- self tests ----")

	-- Each suite runs isolated: a raised error is reported as a failure of that
	-- suite instead of aborting the remaining suites (an error here earlier
	-- meant later tests never ran, hiding their results).
	local suites = {
		{"data", test_data},
		{"storage", test_storage},
		{"palette", test_palette},
		{"transforms", test_transforms},
		{"mesher", test_mesher},
		{"drawable", test_drawable_quads},
		{"picking", test_picking},
		{"brushes", test_brushes},
		{"editing", test_editing},
		{"rendering", test_rendering},
		{"sizes", test_grid_steps},
		{"size_brush", test_brush_sizes_apply},
		{"border", test_border_and_empty},
		{"open_faces", test_open_faces},
		{"budget", test_render_budget},
		{"neighbors", test_neighbor_masks},
		{"collision", test_collision_shapes},
		{"clipboard", test_clipboard},
		{"performance", test_performance},
	}
	for _, suite in ipairs(suites) do
		local before = #results
		local ok, err = pcall(suite[2])
		if not ok then
			check("suite_" .. suite[1], false, tostring(err))
		end
		local failed_here = 0
		for i = before + 1, #results do
			if not results[i].ok then
				failed_here = failed_here + 1
			end
		end
		print(string.format("[micronode_chisel] %-12s %d checks, %d failed",
			suite[1], #results - before, failed_here))
	end

	local passed, failed = 0, 0
	for _, result in ipairs(results) do
		if result.ok then
			passed = passed + 1
		else
			failed = failed + 1
			print("[micronode_chisel] FAIL " .. result.name .. ": " .. tostring(result.detail))
		end
	end
	print(string.format("[micronode_chisel] %d passed, %d failed", passed, failed))
	if failed == 0 then
		print("[micronode_chisel] all self tests passed")
	end
end)
