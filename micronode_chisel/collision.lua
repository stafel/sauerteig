-- Simplified AABB Collision for Micronode Blocks
-- For v1: Use full block collision or empty collision
-- For v2: Generate per-micronode AABB collision

local M = micronode_chisel

------------------------------------------------------------------------------
-- Collision Selection
------------------------------------------------------------------------------

-- Determine collision box type for a micronode block
-- Returns: "full" (solid block), "empty" (air), or "custom" (future)
function M.get_collision_type(grid)
	local solid_count = M.count_solid(grid)

	if solid_count == 0 then
		return "empty"
	elseif solid_count == M.VOXEL_COUNT then
		return "full"
	else
		-- Partial: use full block collision for simplicity (v1)
		-- TODO v2: Generate custom collision mesh
		return "full"
	end
end

-- Get collision boxes for a micronode block
-- v1: Simplified — full block or empty
function M.get_collision_boxes(grid, palette)
	local collision_type = M.get_collision_type(grid)

	if collision_type == "empty" then
		-- No collision (player can walk through)
		return {}
	else
		-- Full block collision
		return {
			{
				type = "regular",
				fixed = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}},
			}
		}
	end
end

-- v2: Generate per-micronode collision (not implemented yet)
-- This would create AABBs for each solid micronode
function M.get_detailed_collision_boxes(grid, palette)
	local boxes = M.generate_optimized_nodeboxes(grid, palette)
	local collision_boxes = {}

	for _, box in ipairs(boxes) do
		table.insert(collision_boxes, {
			type = "regular",
			fixed = {{box.x0, box.y0, box.z0, box.x1, box.y1, box.z1}},
		})
	end

	return collision_boxes
end

print("[micronode_chisel] Collision loaded")
