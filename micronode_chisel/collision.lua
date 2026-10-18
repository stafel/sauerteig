-- Collision behaviour of chiseled blocks.
--
-- A Luanti node carries exactly one collision box, so per-micronode collision
-- cannot be expressed for a container node. The approximation used here:
--
--   solid cells >= COLLISION_SOLID_RATIO  -> M.BLOCK_NODE       (full block)
--   otherwise                             -> M.BLOCK_NODE_OPEN  (no collision)
--
-- This makes carving a doorway usable (you carve more than half of the blocks
-- and then walk through), at the cost of a mostly-empty block never blocking
-- movement. Per-cell collision would need engine support (see
-- docs/subnode-editing-plan.md, "Collision for micronodes").
--
-- Why a second node type instead of `walkable = false` on one type: walkability
-- is a per-type property, so it cannot vary per placed block.

local M = micronode_chisel

M.COLLISION_SOLID_RATIO = 0.5

-- Solid fraction of a grid, 0..1.
function M.fill_ratio(grid)
	local volume = #grid
	if volume <= 0 then
		return 0
	end
	return M.count_solid(grid) / volume
end

-- Container node name a block with this grid should use.
function M.collision_variant(grid)
	if M.fill_ratio(grid) >= M.COLLISION_SOLID_RATIO then
		return M.BLOCK_NODE
	end
	return M.BLOCK_NODE_OPEN
end

-- Swap the container node to the variant matching the current grid.
function M.update_collision_node(pos, block)
	local want = M.collision_variant(block.grid)
	if core.get_node(pos).name ~= want then
		core.swap_node(pos, {name = want})
	end
end

print("[micronode_chisel] Collision model loaded")
