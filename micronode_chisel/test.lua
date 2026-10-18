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
	check("edit_collision_threshold", M.collision_variant(block.grid) == M.BLOCK_NODE,
		"exactly half solid still collides")

	M.api_fill_box(TEST_POS, 1, 8, 1, R, 8, R, "air")
	block = M.get_block(TEST_POS)
	check("edit_collision_open", M.collision_variant(block.grid) == M.BLOCK_NODE_OPEN,
		string.format("%.0f%% solid becomes walk-through", M.fill_ratio(block.grid) * 100))

	M.update_collision_node(TEST_POS, block)
	check("edit_node_swapped", core.get_node(TEST_POS).name == M.BLOCK_NODE_OPEN,
		"container node swapped to the open variant")

	local mats = M.palette_add(block.palette, stone)
	check("edit_palette_reuse", mats == 1, "existing material reused")
	check("edit_palette_after_compact", #block.palette == M.MAX_MATERIALS,
		"palette always reports four slots")

	-- Undo restores the pre-carve grid.
	local before = M.compress_grid(M.get_block(TEST_POS).grid)
	M.apply_region(TEST_POS, M.ordered_region(0, 0, 0, R - 1, R - 1, R - 1), nil,
		{create = false, player = "mn_test"})
	check("edit_apply_region", M.is_empty(M.get_block(TEST_POS).grid), "region carve empties the block")
	local ok, restored = M.undo("mn_test")
	check("edit_undo", ok and restored >= 1
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
		{"picking", test_picking},
		{"brushes", test_brushes},
		{"editing", test_editing},
		{"rendering", test_rendering},
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
