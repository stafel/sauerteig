-- Surface extraction for micronode blocks (Cube 2 / Sauerbraten render model).
--
-- The micronode grid is drawn like Sauerbraten draws its octree: only faces
-- where solid meets air exist, and coplanar faces of the same material are
-- greedily merged into as few rectangles as possible. There is no interior
-- geometry, so nothing z-fights *inside* the shape, and the silhouette is
-- exactly the voxel silhouette.
--
-- Each emitted box is the face rectangle extruded slightly INTO the solid, so
-- the box is non-degenerate and its outward plane sits exactly on the voxel
-- boundary. The exact outward plane is what makes neighbouring boxes line up.
--
-- Depth stays well below one micronode: at a full-voxel depth, a one-voxel
-- thick feature (a shelf, a wall) produces two boxes whose *inner* planes
-- coincide exactly. Surface planes are always >= 1/RESOLUTION apart, so a
-- quarter-micronode depth can never coincide with another surface. This is an
-- absolute thickness, not a fraction of a coarse cell: the render-budget
-- fallback meshes at 1/2, 1/4 or 1/8 resolution and its boxes still have to
-- avoid the surface planes of full-resolution neighbours.
--
-- Coplanar overlap between *side* quads is handled on the render side: only the
-- outward face of each box is drawn, the other five are discarded
-- (see render.lua, "ONE OPAQUE FACE PER ENTITY").
--
-- Neighbour culling: faces on a node boundary are dropped when the adjacent
-- node is solid, or -- per voxel -- when the adjacent chiseled block has a
-- solid cell touching that face. Face-plane coordinates are shared between
-- neighbours:
--     axis 1 (x faces): u = y, v = z
--     axis 2 (y faces): u = x, v = z
--     axis 3 (z faces): u = x, v = y
-- so callers build a neighbour mask in that same convention (see edit.lua).

local M = micronode_chisel
local R = M.RESOLUTION

-- Face box thickness, as a fraction of one micronode.
M.FACE_DEPTH_FRACTION = 1 / 4

local SIDES = {
	{axis = 1, dir = 1, key = "px"},
	{axis = 1, dir = -1, key = "nx"},
	{axis = 2, dir = 1, key = "py"},
	{axis = 2, dir = -1, key = "ny"},
	{axis = 3, dir = 1, key = "pz"},
	{axis = 3, dir = -1, key = "nz"},
}
M.SIDES = SIDES

local CUBE_FACE = {
	[1] = {[1] = M.FACE_PX, [-1] = M.FACE_NX},
	[2] = {[1] = M.FACE_PY, [-1] = M.FACE_NY},
	[3] = {[1] = M.FACE_PZ, [-1] = M.FACE_NZ},
}

-- Engine cube/tile index for a face axis/direction.
function M.cube_face(axis, dir)
	return CUBE_FACE[axis] and CUBE_FACE[axis][dir] or M.FACE_PX
end

local function to_xyz(axis, s, u, v)
	if axis == 1 then
		return s, u, v
	elseif axis == 2 then
		return u, s, v
	end
	return u, v, s
end

-- Face-plane mask for one slice: mask[(u-1)*res+v] = palette index of the
-- solid voxel that owns an exposed face there, 0 otherwise.
local function build_mask(grid, res, axis, dir, s, nb)
	local mask = {}
	local any = false
	for u = 1, res do
		local ubase = (u - 1) * res
		for v = 1, res do
			local x, y, z = to_xyz(axis, s, u, v)
			local value = M.get_voxel(grid, x, y, z, res)
			if value > 0 then
				local nx, ny, nz = x, y, z
				if axis == 1 then
					nx = x + dir
				elseif axis == 2 then
					ny = y + dir
				else
					nz = z + dir
				end

				local exposed
				if nx >= 1 and nx <= res and ny >= 1 and ny <= res and nz >= 1 and nz <= res then
					exposed = M.get_voxel(grid, nx, ny, nz, res) == 0
				elseif nb == true then
					exposed = false                     -- solid neighbour node
				elseif type(nb) == "function" then
					exposed = not nb(u, v)              -- per-cell neighbour mask
				else
					exposed = true                      -- open neighbour node
				end

				if exposed then
					mask[ubase + v] = value
					any = true
				end
			end
		end
	end
	if not any then
		return nil
	end
	return mask
end

-- Build the boxes for one grid.
-- Returns an array of:
--   {x0, x1, y0, y1, z0, z1,   -- node-local extents, normalized, -0.5..0.5
--    axis = 1..3, dir = -1|1,  -- which face of the box points outward
--    mat = palette index, material = node name}
function M.build_surface_boxes(grid, palette, neighbors, res)
	res = res or R
	local boxes = {}
	-- Absolute thickness (quarter of a full-resolution micronode), independent
	-- of the mesh resolution; see the header.
	local depth = (1 / math.max(res, R)) * M.FACE_DEPTH_FRACTION

	for _, side in ipairs(SIDES) do
		local axis, dir = side.axis, side.dir
		local nb = neighbors and neighbors[side.key]

		for s = 1, res do
			local mask = build_mask(grid, res, axis, dir, s, nb)
			if mask then
				local visited = {}

				for u = 1, res do
					local ubase = (u - 1) * res
					for v = 1, res do
						-- The mask is sparse (only exposed cells are stored),
						-- so absent entries read as 0 = no face.
						local mat = mask[ubase + v] or 0
						if mat > 0 and not visited[ubase + v] then
							-- extend along v
							local v2 = v
							while v2 < res and mask[ubase + v2 + 1] == mat
								and not visited[ubase + v2 + 1] do
								v2 = v2 + 1
							end

							-- extend along u over the full v span
							local u2 = u
							local can_extend = true
							while u2 < res and can_extend do
								local nbase = u2 * res
								for vv = v, v2 do
									if mask[nbase + vv] ~= mat or visited[nbase + vv] then
										can_extend = false
										break
									end
								end
								if can_extend then
									u2 = u2 + 1
								end
							end

							for uu = u, u2 do
								local mbase = (uu - 1) * res
								for vv = v, v2 do
									visited[mbase + vv] = true
								end
							end

							-- Outward plane sits exactly on the voxel boundary;
							-- the box then extends a little into the solid.
							local plane
							if dir > 0 then
								plane = s / res - 0.5
							else
								plane = (s - 1) / res - 0.5
							end
							local inner = plane - dir * depth
							local p0, p1 = math.min(plane, inner), math.max(plane, inner)

							local a0 = (u - 1) / res - 0.5
							local a1 = u2 / res - 0.5
							local b0 = (v - 1) / res - 0.5
							local b1 = v2 / res - 0.5

							local box = {axis = axis, dir = dir, mat = mat,
								material = M.palette_get(palette, mat)}
							if axis == 1 then
								box.x0, box.x1 = p0, p1
								box.y0, box.y1 = a0, a1
								box.z0, box.z1 = b0, b1
							elseif axis == 2 then
								box.y0, box.y1 = p0, p1
								box.x0, box.x1 = a0, a1
								box.z0, box.z1 = b0, b1
							else
								box.z0, box.z1 = p0, p1
								box.x0, box.x1 = a0, a1
								box.y0, box.y1 = b0, b1
							end
							boxes[#boxes + 1] = box
						end
					end
				end
			end
		end
	end

	return boxes
end

-- Stable signature of a box list (material names included, so re-texturing a
-- palette slot invalidates the cached geometry).
local function quantize(v)
	return math.floor((v + 0.5) * 1000 + 0.5)
end

function M.boxes_hash(boxes)
	local parts = {}
	for _, box in ipairs(boxes) do
		parts[#parts + 1] = table.concat({
			box.axis, box.dir,
			quantize(box.x0), quantize(box.x1),
			quantize(box.y0), quantize(box.y1),
			quantize(box.z0), quantize(box.z1),
			tostring(box.material),
		}, ":")
	end
	return table.concat(parts, "|")
end

print("[micronode_chisel] Surface mesher loaded")
