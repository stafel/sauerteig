-- Automated Tests for Micronode Chisel
-- Runs on server startup to verify functionality

local M = micronode_chisel
local test_results = {}

local function log_test(name, passed, msg)
	local status = passed and "PASS" or "FAIL"
	table.insert(test_results, {name = name, passed = passed, msg = msg})
	print(string.format("[micronode_chisel TEST] %s: %s - %s", status, name, msg))
end

------------------------------------------------------------------------------
-- Test 1: Grid Creation and Basic Operations
------------------------------------------------------------------------------

local function test_grid_basic()
	-- Create empty grid
	local grid = M.create_empty_grid()
	local pass = (#grid == M.VOXEL_COUNT) and M.is_empty(grid)
	log_test("grid_empty", pass, string.format("Created empty grid with %d voxels", #grid))
	if not pass then return false end

	-- Create filled grid
	grid = M.create_filled_grid(1)
	pass = M.is_full(grid) and (M.count_solid(grid) == M.VOXEL_COUNT)
	log_test("grid_filled", pass, "Created filled grid")
	if not pass then return false end

	-- Set and get voxel
	grid = M.create_empty_grid()
	M.set_voxel(grid, 8, 8, 8, 2)
	pass = (M.get_voxel(grid, 8, 8, 8) == 2)
	log_test("voxel_set_get", pass, "Set and get voxel at (8,8,8)")

	return pass
end

------------------------------------------------------------------------------
-- Test 2: Fill Box
------------------------------------------------------------------------------

local function test_fill_box()
	local grid = M.create_empty_grid()

	-- Fill a 4×4×4 box at center
	M.fill_box(grid, 7, 7, 7, 10, 10, 10, 1)

	local count = M.count_solid(grid)
	local expected = 4 * 4 * 4 -- 64 voxels
	local pass = (count == expected)
	log_test("fill_box", pass, string.format("Filled 4×4×4 box: %d voxels (expected %d)", count, expected))

	-- Verify corners are solid
	pass = pass and M.get_voxel(grid, 7, 7, 7) == 1
	pass = pass and M.get_voxel(grid, 10, 10, 10) == 1
	-- Verify outside is air
	pass = pass and M.get_voxel(grid, 6, 6, 6) == 0
	pass = pass and M.get_voxel(grid, 11, 11, 11) == 0

	return pass
end

------------------------------------------------------------------------------
-- Test 3: RLE Compression
------------------------------------------------------------------------------

local function test_compression()
	-- Test with all-solid grid (should compress very well)
	local grid = M.create_filled_grid(1)
	local ratio, compressed_size = M.get_compression_ratio(grid)
	local pass = ratio > 100 -- Should be >100x for solid block
	log_test("compress_solid", pass,
		string.format("Solid block compression: %.1fx (%d bytes → %d bytes)",
			ratio, M.VOXEL_COUNT, compressed_size))

	-- Test round-trip: compress then decompress
	local compressed = M.compress_grid(grid)
	local decompressed = M.decompress_grid(compressed)
	local match = true
	for i = 1, M.VOXEL_COUNT do
		if grid[i] ~= decompressed[i] then
			match = false
			break
		end
	end
	log_test("compress_roundtrip", match, "Compress/decompress round-trip")

	-- Test with checkerboard pattern (worst case for RLE)
	grid = M.create_empty_grid()
	for z = 1, M.RESOLUTION do
		for y = 1, M.RESOLUTION do
			for x = 1, M.RESOLUTION do
				if (x + y + z) % 2 == 0 then
					M.set_voxel(grid, x, y, z, 1)
				end
			end
		end
	end
	ratio, compressed_size = M.get_compression_ratio(grid)
	log_test("compress_checkerboard", ratio < 2,
		string.format("Checkerboard compression: %.2fx (%d bytes → %d bytes)",
			ratio, M.VOXEL_COUNT, compressed_size))

	return pass and match
end

------------------------------------------------------------------------------
-- Test 4: Palette Management
------------------------------------------------------------------------------

local function test_palette()
	local palette = M.create_palette({"basenodes:stone", "basenodes:dirt"})

	local pass = (palette[1] == "basenodes:stone")
	pass = pass and (palette[2] == "basenodes:dirt")
	pass = pass and (palette[3] == "air")
	pass = pass and (palette[4] == "air")
	log_test("palette_create", pass, "Created palette with 2 materials")

	-- Add material
	local idx = M.palette_add(palette, "basenodes:sand")
	pass = pass and (idx == 3)
	pass = pass and (palette[3] == "basenodes:sand")
	log_test("palette_add", pass, "Added third material")

	-- Add duplicate (should return existing index)
	idx = M.palette_add(palette, "basenodes:stone")
	pass = pass and (idx == 1)
	log_test("palette_duplicate", pass, "Duplicate material returns existing index")

	-- Serialize/deserialize
	local str = M.palette_serialize(palette)
	local palette2 = M.palette_deserialize(str)
	pass = pass and (#palette2 >= #palette)
	log_test("palette_serialize", pass, "Palette serialize/deserialize")

	return pass
end

------------------------------------------------------------------------------
-- Test 5: Rotation and Flip
------------------------------------------------------------------------------

local function test_transforms()
	-- Create a simple pattern: solid only in one corner
	local grid = M.create_empty_grid()
	M.set_voxel(grid, 1, 1, 1, 1) -- Bottom-left-front corner

	-- Rotate 90° CW: (1,1,1) should go to (1,1,16) [front to right]
	local rotated = M.rotate_grid(grid, 1)
	local pass = (M.get_voxel(rotated, 1, 1, 16) == 1)
	log_test("rotate_90", pass, "Rotate 90° CW moves corner voxel")

	-- Rotate 4 times should return to original
	rotated = M.rotate_grid(grid, 4)
	pass = pass and (M.get_voxel(rotated, 1, 1, 1) == 1)
	log_test("rotate_360", pass, "Rotate 4×90° = original")

	-- Flip horizontally: (1,1,1) should go to (16,1,1)
	local flipped = M.flip_grid(grid)
	pass = pass and (M.get_voxel(flipped, 16, 1, 1) == 1)
	log_test("flip_horizontal", pass, "Flip horizontal moves voxel to opposite side")

	return pass
end

------------------------------------------------------------------------------
-- Test 6: Nodebox Generation
------------------------------------------------------------------------------

local function test_nodebox_generation()
	local grid = M.create_filled_grid(1)
	local palette = M.create_palette({"basenodes:stone"})

	local nodeboxes = M.generate_optimized_nodeboxes(grid, palette)
	local pass = (#nodeboxes == 1) -- Should merge into one box
	log_test("nodebox_full_merge", pass,
		string.format("Full block generates %d nodebox(es) (expected 1)", #nodeboxes))

	-- Empty grid should generate no nodeboxes
	grid = M.create_empty_grid()
	nodeboxes = M.generate_optimized_nodeboxes(grid, palette)
	pass = pass and (#nodeboxes == 0)
	log_test("nodebox_empty", pass, "Empty grid generates 0 nodeboxes")

	-- Half-filled grid
	grid = M.create_empty_grid()
	M.fill_box(grid, 1, 1, 1, 16, 8, 16, 1) -- Bottom half
	nodeboxes = M.generate_optimized_nodeboxes(grid, palette)
	pass = pass and (#nodeboxes >= 1)
	log_test("nodebox_half", pass,
		string.format("Half-filled grid generates %d nodebox(es)", #nodeboxes))

	return pass
end

------------------------------------------------------------------------------
-- Test 7: Block Data Serialization
------------------------------------------------------------------------------

local function test_block_data_serialization()
	local palette = M.create_palette({"basenodes:stone", "basenodes:dirt"})
	local grid = M.create_empty_grid()
	M.fill_box(grid, 1, 1, 1, 8, 16, 16, 1)  -- Left half stone
	M.fill_box(grid, 9, 1, 1, 16, 16, 8, 2)  -- Part of right half dirt

	local block_data = M.create_block_data("basenodes:stone", palette, grid, 1)
	local serialized = M.serialize_block_data(block_data)

	-- Deserialize
	local restored = M.deserialize_block_data(serialized)

	local pass = (restored.base == block_data.base)
	pass = pass and (restored.rotation == block_data.rotation)
	pass = pass and (#restored.palette >= #block_data.palette)

	-- Check grid matches
	local match = true
	for i = 1, M.VOXEL_COUNT do
		if restored.grid[i] ~= grid[i] then
			match = false
			break
		end
	end
	pass = pass and match

	log_test("block_data_serialize", pass, "Block data serialize/deserialize round-trip")

	return pass
end

------------------------------------------------------------------------------
-- Test 8: Performance Benchmarks
------------------------------------------------------------------------------

local function test_performance()
	local results = {}

	-- Benchmark: Create filled grid
	local start = core.get_us_time()
	for i = 1, 100 do
		M.create_filled_grid(1)
	end
	results.create_grid_ms = (core.get_us_time() - start) / 1000 / 100

	-- Benchmark: Compress solid grid
	local grid = M.create_filled_grid(1)
	start = core.get_us_time()
	for i = 1, 100 do
		M.compress_grid(grid)
	end
	results.compress_solid_ms = (core.get_us_time() - start) / 1000 / 100

	-- Benchmark: Compress checkerboard (worst case)
	grid = M.create_empty_grid()
	for z = 1, M.RESOLUTION do
		for y = 1, M.RESOLUTION do
			for x = 1, M.RESOLUTION do
				if (x + y + z) % 2 == 0 then
					M.set_voxel(grid, x, y, z, 1)
				end
			end
		end
	end
	start = core.get_us_time()
	for i = 1, 100 do
		M.compress_grid(grid)
	end
	results.compress_checkerboard_ms = (core.get_us_time() - start) / 1000 / 100

	-- Benchmark: Generate nodeboxes
	grid = M.create_filled_grid(1)
	local palette = M.create_palette({"basenodes:stone"})
	start = core.get_us_time()
	for i = 1, 100 do
		M.generate_optimized_nodeboxes(grid, palette)
	end
	results.nodebox_gen_ms = (core.get_us_time() - start) / 1000 / 100

	-- Benchmark: Rotate grid
	start = core.get_us_time()
	for i = 1, 100 do
		M.rotate_grid(grid, 1)
	end
	results.rotate_ms = (core.get_us_time() - start) / 1000 / 100

	print("[micronode_chisel BENCH] Performance Results:")
	print(string.format("[micronode_chisel BENCH]   Create grid: %.3f ms", results.create_grid_ms))
	print(string.format("[micronode_chisel BENCH]   Compress (solid): %.3f ms", results.compress_solid_ms))
	print(string.format("[micronode_chisel BENCH]   Compress (checkerboard): %.3f ms", results.compress_checkerboard_ms))
	print(string.format("[micronode_chisel BENCH]   Nodebox generation: %.3f ms", results.nodebox_gen_ms))
	print(string.format("[micronode_chisel BENCH]   Rotate grid: %.3f ms", results.rotate_ms))

	-- All should be under 1ms for good performance
	local pass = results.create_grid_ms < 1 and
	             results.compress_solid_ms < 1 and
	             results.nodebox_gen_ms < 5 and
	             results.rotate_ms < 5

	log_test("performance", pass, "All operations under performance targets")

	return pass, results
end

------------------------------------------------------------------------------
-- Test 9: Storage Size Benchmarks
------------------------------------------------------------------------------

local function test_storage_sizes()
	local sizes = {}

	-- Solid block
	local grid = M.create_filled_grid(1)
	local compressed = M.compress_grid(grid)
	sizes.solid_bytes = #compressed

	-- Empty block
	grid = M.create_empty_grid()
	compressed = M.compress_grid(grid)
	sizes.empty_bytes = #compressed

	-- Half-filled
	grid = M.create_empty_grid()
	M.fill_box(grid, 1, 1, 1, 16, 8, 16, 1)
	compressed = M.compress_grid(grid)
	sizes.half_bytes = #compressed

	-- Checkerboard (worst case)
	grid = M.create_empty_grid()
	for z = 1, M.RESOLUTION do
		for y = 1, M.RESOLUTION do
			for x = 1, M.RESOLUTION do
				if (x + y + z) % 2 == 0 then
					M.set_voxel(grid, x, y, z, 1)
				end
			end
		end
	end
	compressed = M.compress_grid(grid)
	sizes.checkerboard_bytes = #compressed

	print("[micronode_chisel BENCH] Storage Sizes (compressed):")
	print(string.format("[micronode_chisel BENCH]   Solid block: %d bytes (%.1fx compression)",
		sizes.solid_bytes, M.VOXEL_COUNT / sizes.solid_bytes))
	print(string.format("[micronode_chisel BENCH]   Empty block: %d bytes (%.1fx compression)",
		sizes.empty_bytes, M.VOXEL_COUNT / sizes.empty_bytes))
	print(string.format("[micronode_chisel BENCH]   Half-filled: %d bytes (%.1fx compression)",
		sizes.half_bytes, M.VOXEL_COUNT / sizes.half_bytes))
	print(string.format("[micronode_chisel BENCH]   Checkerboard: %d bytes (%.2fx compression)",
		sizes.checkerboard_bytes, M.VOXEL_COUNT / sizes.checkerboard_bytes))

	-- Solid should be < 100 bytes, checkerboard can be larger
	local pass = sizes.solid_bytes < 100 and sizes.empty_bytes < 100
	log_test("storage_sizes", pass, "Storage sizes within acceptable ranges")

	return pass, sizes
end

------------------------------------------------------------------------------
-- Test 10: Entity rendering (end-to-end visual path)
------------------------------------------------------------------------------

local function test_entity_rendering()
	local pos = vector.new(0, 40, 0)
	core.load_area(pos)

	-- Place a solid stone node
	local stone = M.fallback_material or M.get_fallback_material()
	core.set_node(pos, {name = stone})

	-- Chisel it programmatically
	if not M.api_chisel(pos, stone) then
		log_test("entity_render", false, "api_chisel failed")
		return false
	end

	-- Carve a chunk out to make it partial (triggers entity rendering)
	local ok = M.api_fill_box(pos, 1, 1, 1, 16, 16, 8, "air")
	if not ok then
		log_test("entity_render", false, "api_fill_box failed")
		return false
	end

	-- Count render entities around the block
	local center = vector.add(pos, vector.new(0.5, 0.5, 0.5))
	local count = 0
	for _, obj in ipairs(core.get_objects_inside_radius(center, 1.3)) do
		local lua = obj:get_luaentity()
		if lua and lua.name == "micronode_chisel:box" then
			count = count + 1
		end
	end

	local pass = count >= 1
	log_test("entity_render", pass,
		string.format("Partial block spawned %d render entity/entities (expected >= 1)", count))

	-- Fully carve: entities should be gone (grid empty -> nothing rendered)
	M.api_fill_box(pos, 1, 1, 1, 16, 16, 16, "air")
	count = 0
	for _, obj in ipairs(core.get_objects_inside_radius(center, 1.3)) do
		local lua = obj:get_luaentity()
		if lua and lua.name == "micronode_chisel:box" then
			count = count + 1
		end
	end

	pass = pass and (count == 0)
	log_test("entity_cleanup", pass,
		string.format("Fully-carved block has %d entities (expected 0)", count))

	-- Restore the area
	core.set_node(pos, {name = stone})

	return pass
end

------------------------------------------------------------------------------
-- Run All Tests
------------------------------------------------------------------------------

local function run_all_tests()
	print("[micronode_chisel] ========================================")
	print("[micronode_chisel] Running automated tests...")
	print("[micronode_chisel] ========================================")

	test_grid_basic()
	test_fill_box()
	test_compression()
	test_palette()
	test_transforms()
	test_nodebox_generation()
	test_block_data_serialization()
	test_performance()
	test_storage_sizes()
	test_entity_rendering()

	-- Summary
	print("[micronode_chisel] ========================================")
	print("[micronode_chisel] Test Summary:")
	local passed = 0
	local failed = 0
	for _, r in ipairs(test_results) do
		if r.passed then
			passed = passed + 1
			print(string.format("[micronode_chisel]   PASS: %s", r.name))
		else
			failed = failed + 1
			print(string.format("[micronode_chisel]   FAIL: %s - %s", r.name, r.msg))
		end
	end
	print(string.format("[micronode_chisel] Results: %d passed, %d failed", passed, failed))
	print("[micronode_chisel] ========================================")

	return failed == 0
end

-- Run tests after server initialization
core.after(2.0, function()
	local success = run_all_tests()
	if success then
		print("[micronode_chisel] ALL TESTS PASSED — Micronode chisel ready")
	else
		print("[micronode_chisel] SOME TESTS FAILED — check logs")
	end
end)
