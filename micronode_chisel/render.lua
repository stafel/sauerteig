-- Micronode Rendering
-- Generates meshes from 16³ voxel data for rendering
-- Uses Luanti's mesh node drawtype

local M = micronode_chisel

------------------------------------------------------------------------------
-- Mesh Generation
------------------------------------------------------------------------------

-- Generate a simple cube mesh for a micronode
-- Returns vertices and faces for a single micronode cube
local function generate_micronode_mesh(material_name, mx, my, mz, size)
	size = size or (1 / M.RESOLUTION)
	local x = (mx - 1) / M.RESOLUTION
	local y = (my - 1) / M.RESOLUTION
	local z = (mz - 1) / M.RESOLUTION

	-- Get texture for material
	local tiles = core.registered_nodes[material_name]
	local texture = "default_stone.png" -- fallback
	if tiles and tiles.tiles and tiles.tiles[1] then
		local tile = tiles.tiles[1]
		if type(tile) == "string" then
			texture = tile
		elseif type(tile) == "table" and tile.name then
			texture = tile.name
		end
	end

	-- Simple cube vertices (8 corners)
	local x0, y0, z0 = x, y, z
	local x1, y1, z1 = x + size, y + size, z + size

	-- We'll use nodebox-style mesh generation instead
	-- For now, return a simple representation
	return {
		min = {x = x0, y = y0, z = z0},
		max = {x = x1, y = y1, z = z1},
		texture = texture,
	}
end

-- Generate nodeboxes from micronode grid
-- This creates a list of nodeboxes that represent the solid micronodes
-- Each solid micronode becomes a small nodebox
function M.generate_nodeboxes(grid, palette)
	local nodeboxes = {}
	local micronode_size = 1 / M.RESOLUTION

	for z = 1, M.RESOLUTION do
		for y = 1, M.RESOLUTION do
			for x = 1, M.RESOLUTION do
				local mat_idx = M.get_voxel(grid, x, y, z)
				if mat_idx > 0 then
					local material = M.palette_get(palette, mat_idx)
					if material and material ~= "air" then
						local x0 = (x - 1) * micronode_size - 0.5
						local y0 = (y - 1) * micronode_size - 0.5
						local z0 = (z - 1) * micronode_size - 0.5
						local x1 = x0 + micronode_size
						local y1 = y0 + micronode_size
						local z1 = z0 + micronode_size

						-- Get texture for this material
						local texture = M.get_texture(material)

						table.insert(nodeboxes, {
							type = "fixed",
							fixed = {{x0, y0, z0, x1, y1, z1}},
						})
					end
				end
			end
		end
	end

	return nodeboxes
end

-- Optimized: Merge adjacent micronodes into larger boxes (greedy meshing)
function M.generate_optimized_nodeboxes(grid, palette)
	local micronode_size = 1 / M.RESOLUTION
	local visited = {}
	local nodeboxes = {}

	local function is_solid(x, y, z)
		if x < 1 or x > M.RESOLUTION or y < 1 or y > M.RESOLUTION or z < 1 or z > M.RESOLUTION then
			return false
		end
		return M.get_voxel(grid, x, y, z) > 0
	end

	local function is_visited(x, y, z)
		local idx = (z - 1) * M.RESOLUTION * M.RESOLUTION + (y - 1) * M.RESOLUTION + x
		return visited[idx] == true
	end

	local function mark_visited(x, y, z)
		local idx = (z - 1) * M.RESOLUTION * M.RESOLUTION + (y - 1) * M.RESOLUTION + x
		visited[idx] = true
	end

	-- Greedy meshing: find largest boxes
	for z = 1, M.RESOLUTION do
		for y = 1, M.RESOLUTION do
			for x = 1, M.RESOLUTION do
				if is_solid(x, y, z) and not is_visited(x, y, z) then
					local mat_idx = M.get_voxel(grid, x, y, z)
					local material = M.palette_get(palette, mat_idx)

					-- Find最大 extent in X direction
					local sx = x
					while sx < M.RESOLUTION and is_solid(sx + 1, y, z) and not is_visited(sx + 1, y, z)
						and M.get_voxel(grid, sx + 1, y, z) == mat_idx do
						sx = sx + 1
					end

					-- Find extent in Y direction
					local sy = y
					local can_extend_y = true
					while sy < M.RESOLUTION and can_extend_y do
						for ix = x, sx do
							if not is_solid(ix, sy + 1, z) or is_visited(ix, sy + 1, z)
								or M.get_voxel(grid, ix, sy + 1, z) ~= mat_idx then
								can_extend_y = false
								break
							end
						end
						if can_extend_y then
							sy = sy + 1
						end
					end

					-- Find extent in Z direction
					local sz = z
					local can_extend_z = true
					while sz < M.RESOLUTION and can_extend_z do
						for iy = y, sy do
							for ix = x, sx do
								if not is_solid(ix, iy, sz + 1) or is_visited(ix, iy, sz + 1)
									or M.get_voxel(grid, ix, iy, sz + 1) ~= mat_idx then
									can_extend_z = false
									break
								end
							end
							if not can_extend_z then break end
						end
						if can_extend_z then
							sz = sz + 1
						end
					end

					-- Mark all voxels in this box as visited
					for iz = z, sz do
						for iy = y, sy do
							for ix = x, sx do
								mark_visited(ix, iy, iz)
							end
						end
					end

					-- Create nodebox
					local x0 = (x - 1) * micronode_size - 0.5
					local y0 = (y - 1) * micronode_size - 0.5
					local z0 = (z - 1) * micronode_size - 0.5
					local x1 = sx * micronode_size - 0.5
					local y1 = sy * micronode_size - 0.5
					local z1 = sz * micronode_size - 0.5

					table.insert(nodeboxes, {
						x0 = x0, y0 = y0, z0 = z0,
						x1 = x1, y1 = y1, z1 = z1,
						material = material,
					})
				end
			end
		end
	end

	return nodeboxes
end

-- Get texture for a material
function M.get_texture(material_name)
	if not material_name or material_name == "air" then
		return "blank.png"
	end

	local node = core.registered_nodes[material_name]
	if not node then
		return "default_stone.png"
	end

	if node.tiles and node.tiles[1] then
		local tile = node.tiles[1]
		if type(tile) == "string" then
			return tile
		elseif type(tile) == "table" then
			if tile.name then
				return tile.name
			elseif tile.image then
				return tile.image
			end
		end
	end

	return "default_stone.png"
end

-- Generate a mesh string for a micronode block
-- This creates a .obj-like mesh that Luanti can use
-- Note: For mod-only implementation, we use nodeboxes instead of custom meshes
-- because custom mesh nodes require mesh files

function M.get_nodebox_list(grid, palette)
	-- Use optimized nodeboxes for better performance
	local boxes = M.generate_optimized_nodeboxes(grid, palette)

	-- Convert to Luanti nodebox format
	local nodeboxes = {}
	for _, box in ipairs(boxes) do
		table.insert(nodeboxes, {
			box.x0, box.y0, box.z0,
			box.x1, box.y1, box.z1,
		})
	end

	-- If no solid voxels, return empty (invisible)
	if #nodeboxes == 0 then
		return {{-0.5, -0.5, -0.5, -0.5, -0.5, -0.5}} -- Degenerate box (invisible)
	end

	return nodeboxes
end

------------------------------------------------------------------------------
-- Surface-Only Meshing (Cube 2 / Sauerbraten style)
------------------------------------------------------------------------------
-- Sauerbraten renders only the *exposed* faces of its octree, merged into
-- large coplanar rectangles. We do the same for the 16^3 micronode grid:
-- a rectangle is emitted only where a solid micronode is adjacent to air,
-- greedily merged per plane and material. No interior geometry, no
-- overlapping solid boxes, no z-fighting.
--
-- solid_outside: {px, nx, py, ny, pz, nz} — whether the neighboring Luanti
-- node on that side is solid. Faces against solid neighbors are never
-- visible and are culled.
--
-- Returns rects: {x0,y0,z0,x1,y1,z1 (nodebox coords, paper-thin on the face
-- plane), material = node name}.

function M.generate_surface_faces(grid, palette, solid_outside, res)
	local R = res or M.RESOLUTION
	local rects = {}

	-- Local voxel access indexed with THIS grid's resolution: M.get_voxel
	-- hardcodes the 16^3 stride and misindexes coarse grids.
	local function voxel(x, y, z)
		if x < 1 or x > R or y < 1 or y > R or z < 1 or z > R then
			return 0
		end
		return grid[(z - 1) * R * R + (y - 1) * R + x] or 0
	end

	local function nb0(c) return (c - 1) / R - 0.5 end
	local function nb1(c) return c / R - 0.5 end

	-- axis: 1 = x, 2 = y, 3 = z; slice s along the axis, (u, v) in-plane
	local function voxel_at(axis, s, u, v)
		if axis == 1 then return s, u, v end
		if axis == 2 then return u, s, v end
		return u, v, s
	end

	local function outside_key(axis, dir)
		if axis == 1 then return dir > 0 and "px" or "nx" end
		if axis == 2 then return dir > 0 and "py" or "ny" end
		return dir > 0 and "pz" or "nz"
	end

	for axis = 1, 3 do
		for _, dir in ipairs({-1, 1}) do
			for s = 1, R do
				-- exposed[mask] per material, 0 = not exposed
				local mask, visited = {}, {}
				for u = 1, R do
					mask[u], visited[u] = {}, {}
					for v = 1, R do
						local x, y, z = voxel_at(axis, s, u, v)
						local mat = voxel(x, y, z)
						visited[u][v] = false
						mask[u][v] = 0
						if mat > 0 then
							local nx, ny, nz = x, y, z
							if axis == 1 then nx = x + dir
							elseif axis == 2 then ny = y + dir
							else nz = z + dir end
							local open
							if nx >= 1 and nx <= R and ny >= 1 and ny <= R
								and nz >= 1 and nz <= R then
								open = voxel(nx, ny, nz) == 0
							else
								-- solid_outside[key] is true when the
								-- neighboring Luanti node is NOT walkable
								open = solid_outside == nil
									or solid_outside[outside_key(axis, dir)] == true
							end
							local material = M.palette_get(palette, mat)
							if open and material and material ~= "air" then
								mask[u][v] = mat
							end
						end
					end
				end

				-- greedy rectangle merge over the exposed mask
				for u = 1, R do
					for v = 1, R do
						local mat = mask[u][v]
						if mat > 0 and not visited[u][v] then
							local v2 = v
							while v2 < R and mask[u][v2 + 1] == mat
								and not visited[u][v2 + 1] do
								v2 = v2 + 1
							end
							local u2 = u
							local can_extend = true
							while u2 < R and can_extend do
								for vv = v, v2 do
									if mask[u2 + 1][vv] ~= mat or visited[u2 + 1][vv] then
										can_extend = false
										break
									end
								end
								if can_extend then u2 = u2 + 1 end
							end
							for uu = u, u2 do
								for vv = v, v2 do
									visited[uu][vv] = true
								end
							end
							-- paper-thin box on the face plane
							local plane = dir > 0 and nb1(s) or nb0(s)
							local rect = nil
							if axis == 1 then
								rect = {x0 = plane, x1 = plane,
									y0 = nb0(u), y1 = nb1(u2),
									z0 = nb0(v), z1 = nb1(v2)}
							elseif axis == 2 then
								rect = {y0 = plane, y1 = plane,
									x0 = nb0(u), x1 = nb1(u2),
									z0 = nb0(v), z1 = nb1(v2)}
							else
								rect = {z0 = plane, z1 = plane,
									x0 = nb0(u), x1 = nb1(u2),
									y0 = nb0(v), y1 = nb1(v2)}
							end
							rect.material = M.palette_get(palette, mat)
							table.insert(rects, rect)
						end
					end
				end
			end
		end
	end
	return rects
end

print("[micronode_chisel] Rendering loaded")
