-- Collision for chiseled blocks: shape recognition, not just "solid or not".
--
-- WHY NODE VARIANTS: in Luanti walkability and collision boxes are properties
-- of a node *type*, not of a placed node, so per-micronode collision cannot be
-- expressed on one container node. The engine does support several boxes per
-- type though (`collision_box = {type = "fixed", fixed = {...}}`; in the engine
-- NodeBox::fixed is a vector and MapNode::getCollisionBoxes emits all of it),
-- so a variant can be a staircase made of two boxes. This module recognises the
-- block's shape and swaps the container to the variant that carries it.
--
-- RECOGNITION (performant by construction):
--   1. Occupancy is sampled on a COLLISION_RES^3 grid (8^3 = 1/8 node =
--      12.5 cm cells). A cell is solid when ANY full-resolution cell in its
--      2^3 footprint is solid. "Any" is deliberate: conservative collision
--      means a chiselled floor never lets the player fall through, at the cost
--      of up to one collision cell of invisible bulk.
--   2. Every catalogue shape is scored against that occupancy with
--      intersection-over-union over its own cells only (<= 512 lookups per
--      candidate), and candidates whose cell count is too far from the
--      occupancy are skipped before any lookup.
--   3. A candidate is only accepted when it also *covers* the solid geometry
--      (`recall`), so a bad match can never turn a floor into a hole.
--   4. No acceptable match -> a safe fallback: floor/ceiling sheets become
--      slabs (recall 1), mid-node geometry keeps the legacy fill-ratio rule
--      (>= 50 % solid = full cube, else no collision). See fallback_shape.
--
-- The catalogue is deliberately a fixed set of rudimentary forms (slabs,
-- stairs, panels, posts) at 1/8 node granularity: it is what players build,
-- each entry is a handful of boxes at most, and the whole thing costs one pass
-- over the 4096 cells plus a few dozen candidate scores - the same order as
-- the surface mesher (see docs/micronode-findings.md, "Collision").

local M = micronode_chisel
local R = M.RESOLUTION

-- Collision grid: cells per node axis. 8 -> 12.5 cm, which resolves the
-- half-node steps of a staircase and quarter-node slabs.
M.COLLISION_RES = 8
local CR = M.COLLISION_RES
local STEP = math.floor(R / CR)

-- Legacy fallback threshold and recognition thresholds.
M.COLLISION_SOLID_RATIO = 0.5
M.COLLISION_MIN_IOU = 0.7
M.COLLISION_MIN_RECALL = 0.75

M.SHAPE_PREFIX = "micronode_chisel:shape_"

-- x (1..R) -> collision cell index (1..CR), precomputed to keep the occupancy
-- pass free of per-cell divisions.
local CELL_OF = {}
for i = 1, R do
	CELL_OF[i] = math.floor((i - 1) / STEP) + 1
end

-- Solid fraction of a grid, 0..1.
function M.fill_ratio(grid)
	local volume = #grid
	if volume <= 0 then
		return 0
	end
	return M.count_solid(grid) / volume
end

-------------------------------------------------------------------------------
-- Shape catalogue
-------------------------------------------------------------------------------
-- Boxes are given in collision-cell coordinates, 0-based and inclusive
-- (0..CR-1), which keeps the table readable: `bx(0, 0, 0, 7, 3, 7)` is the
-- bottom half of the node.

local function bx(x0, y0, z0, x1, y1, z1)
	return {x0, y0, z0, x1, y1, z1}
end

local SHAPE_LIST = {}
local SHAPE_BY_ID = {}

local function add_shape(id, boxes)
	local shape = {
		id = id,
		boxes = boxes or {},
		nodeboxes = {},   -- node-local boxes for the node definition
		cells = {},       -- unique collision-cell indices, 1-based
		cell_count = 0,
	}
	local seen = {}
	for _, b in ipairs(shape.boxes) do
		local x0, y0, z0, x1, y1, z1 = b[1], b[2], b[3], b[4], b[5], b[6]
		shape.nodeboxes[#shape.nodeboxes + 1] = {
			x0 / CR - 0.5, y0 / CR - 0.5, z0 / CR - 0.5,
			(x1 + 1) / CR - 0.5, (y1 + 1) / CR - 0.5, (z1 + 1) / CR - 0.5,
		}
		for z = z0, z1 do
			for y = y0, y1 do
				for x = x0, x1 do
					local cell = (z * CR + y) * CR + x + 1
					if not seen[cell] then
						seen[cell] = true
						shape.cells[#shape.cells + 1] = cell
					end
				end
			end
		end
	end
	shape.cell_count = #shape.cells
	SHAPE_LIST[#SHAPE_LIST + 1] = shape
	SHAPE_BY_ID[id] = shape
	return shape
end

local function build_catalogue()
	local last = CR - 1
	local half = math.floor(CR / 2)

	-- Raised half of a stair, per ascent direction: x0, z0, x1, z1. Derived
	-- from the collision resolution so changing COLLISION_RES cannot silently
	-- leave the stairs pointing at the wrong half.
	local RAISED = {
		px = {half, 0, last, last},
		nx = {0, 0, half - 1, last},
		pz = {0, half, last, last},
		nz = {0, 0, last, half - 1},
	}

	add_shape("empty", {})
	add_shape("full", {bx(0, 0, 0, last, last, last)})

	-- Slabs: bottom `h` cells and top `h` cells, h = 1/8 .. 7/8 node.
	for h = 1, CR - 1 do
		add_shape("slab_b" .. h, {bx(0, 0, 0, last, h - 1, last)})
		add_shape("slab_t" .. h, {bx(0, last - h + 1, 0, last, last, last)})
	end

	-- Stairs: a half-height slab over the whole footprint plus the raised half
	-- at full height (and the vertically mirrored variant for ceiling steps).
	for _, dir in ipairs({"px", "nx", "pz", "nz"}) do
		local r = RAISED[dir]
		add_shape("stair_" .. dir, {
			bx(0, 0, 0, last, half - 1, last),
			bx(r[1], half, r[2], r[3], last, r[4]),
		})
		add_shape("stair_inv_" .. dir, {
			bx(0, half, 0, last, last, last),
			bx(r[1], 0, r[2], r[3], half - 1, r[4]),
		})
	end

	-- Panels / walls: full height, `t` cells thick against one side.
	for _, t in ipairs({1, 2, 4}) do
		add_shape("panel" .. t .. "_px", {bx(CR - t, 0, 0, last, last, last)})
		add_shape("panel" .. t .. "_nx", {bx(0, 0, 0, t - 1, last, last)})
		add_shape("panel" .. t .. "_pz", {bx(0, 0, CR - t, last, last, last)})
		add_shape("panel" .. t .. "_nz", {bx(0, 0, 0, last, last, t - 1)})
	end

	-- Free-standing walls through the middle of the node.
	for _, t in ipairs({2, 4}) do
		local lo = half - math.floor(t / 2)
		add_shape("wall" .. t .. "_x", {bx(lo, 0, 0, lo + t - 1, last, last)})
		add_shape("wall" .. t .. "_z", {bx(0, 0, lo, last, last, lo + t - 1)})
	end

	-- Posts: full-height columns in a corner (half-width) and centred.
	add_shape("post_nx_nz", {bx(0, 0, 0, half - 1, last, half - 1)})
	add_shape("post_px_nz", {bx(half, 0, 0, last, last, half - 1)})
	add_shape("post_nx_pz", {bx(0, 0, half, half - 1, last, last)})
	add_shape("post_px_pz", {bx(half, 0, half, last, last, last)})
	local q = math.floor(CR / 4)
	add_shape("pillar", {bx(q, 0, q, CR - q - 1, last, CR - q - 1)})
end

build_catalogue()

-- Node name that carries a shape. "full" and "empty" keep the historical node
-- names so existing worlds keep working without a migration.
function M.shape_node_name(id)
	if id == "full" then
		return M.BLOCK_NODE
	elseif id == "empty" then
		return M.BLOCK_NODE_OPEN
	end
	return M.SHAPE_PREFIX .. id
end

function M.get_shape(id)
	return SHAPE_BY_ID[id]
end

function M.get_shapes()
	return SHAPE_LIST
end

-- Every container node name, in registration order. Used for registration,
-- the mapblock LBM and node classification.
M.CONTAINER_NODES = {
	[M.BLOCK_NODE] = true,
	[M.BLOCK_NODE_OPEN] = true,
}
local CONTAINER_NAMES = {M.BLOCK_NODE, M.BLOCK_NODE_OPEN}
for _, shape in ipairs(SHAPE_LIST) do
	local name = M.shape_node_name(shape.id)
	if not M.CONTAINER_NODES[name] then
		M.CONTAINER_NODES[name] = true
		CONTAINER_NAMES[#CONTAINER_NAMES + 1] = name
	end
end

function M.container_node_names()
	return CONTAINER_NAMES
end

-------------------------------------------------------------------------------
-- Occupancy
-------------------------------------------------------------------------------

-- Sample the grid onto the collision resolution.
-- Returns occ (cell index -> true), occupancy cell count, solid cell count.
-- A collision cell is solid when any full-resolution cell inside it is solid.
function M.collision_occupancy(grid)
	local counts = {}
	local solid = 0
	for z = 1, R do
		local cz = CELL_OF[z]
		local zbase = (z - 1) * R * R
		for y = 1, R do
			local cy = CELL_OF[y]
			-- Cell index base for this (z, y) row, matching add_shape's 0-based
			-- scheme: ((cz-1)*CR + (cy-1))*CR + (cx-1), stored +1.
			local row = ((cz - 1) * CR + (cy - 1)) * CR
			local base = zbase + (y - 1) * R
			for x = 1, R do
				local value = grid[base + x]
				if value and value > 0 then
					local cell = row + CELL_OF[x]
					counts[cell] = (counts[cell] or 0) + 1
					solid = solid + 1
				end
			end
		end
	end

	local occ = {}
	local occupied = 0
	local total = CR * CR * CR
	for cell = 1, total do
		if counts[cell] then
			occ[cell] = true
			occupied = occupied + 1
		end
	end
	return occ, occupied, solid
end

-------------------------------------------------------------------------------
-- Recognition
-------------------------------------------------------------------------------

-- Best catalogue match for an occupancy.
-- Returns shape, iou, recall. No acceptable match returns nil.
function M.match_shape(occ, occupied)
	local best, best_iou, best_boxes, best_recall
	for _, shape in ipairs(SHAPE_LIST) do
		local count = shape.cell_count
		if count > 0 and occupied > 0 then
			-- IoU can never exceed min/max, so this prunes most candidates
			-- without touching their cells.
			local mn = math.min(count, occupied)
			local mx = math.max(count, occupied)
			if mn / mx >= M.COLLISION_MIN_IOU then
				local inter = 0
				local cells = shape.cells
				for i = 1, #cells do
					if occ[cells[i]] then
						inter = inter + 1
					end
				end
				if inter > 0 then
					local union = occupied + count - inter
					local iou = inter / union
					local recall = inter / occupied
					if iou >= M.COLLISION_MIN_IOU and recall >= M.COLLISION_MIN_RECALL then
						-- Prefer the higher IoU; break ties towards the shape
						-- with fewer boxes (cheaper, simpler collision).
						local boxes = #shape.nodeboxes
						if not best or iou > best_iou + 1e-9
							or (math.abs(iou - best_iou) <= 1e-9 and boxes < best_boxes) then
							best, best_iou, best_boxes, best_recall = shape, iou, boxes, recall
						end
					end
				end
			end
		end
	end
	return best, best_iou, best_recall
end

-- Vertical extent of an occupancy, in 1-based collision layers.
local function vertical_extent(occ)
	local lo, hi = CR + 1, 0
	for cell in pairs(occ) do
		local layer = math.floor((cell - 1) / CR) % CR + 1
		if layer < lo then lo = layer end
		if layer > hi then hi = layer end
	end
	return lo, hi
end

-- Fallback for shapes the catalogue does not know.
--
-- Safety rule: collision must never under-cover. When the geometry reaches the
-- node floor, a bottom slab up to the topmost occupied layer covers *every*
-- cell of it (a slab is full-footprint, so recall is 1 by construction) and is
-- standable at the right height. The mirrored rule applies to geometry that
-- hangs from the ceiling. That makes an unrecognised floor or platform walkable
-- instead of walk-through, which is the failure that hurts.
--
-- Geometry floating in the middle of the node has no such anchor, so it keeps
-- the legacy rule (>= 50 % solid -> full cube, else no collision): boxing in a
-- carved alcove would be worse than letting a decoration be passable.
local function fallback_shape(occ, fill)
	if next(occ) == nil then
		return SHAPE_BY_ID.empty
	end
	local lo, hi = vertical_extent(occ)
	if lo == 1 then
		-- Spans floor to ceiling without filling the node: no slab exists for
		-- that height, so the full cube is the recall-1 choice.
		if hi >= CR then
			return SHAPE_BY_ID.full
		end
		return SHAPE_BY_ID["slab_b" .. hi]
	elseif hi == CR then
		return SHAPE_BY_ID["slab_t" .. (CR - lo + 1)]
	end
	return (fill >= M.COLLISION_SOLID_RATIO) and SHAPE_BY_ID.full or SHAPE_BY_ID.empty
end

-- Recognise the collision shape of a grid.
-- Returns a profile table:
--   shape     shape id (string)
--   node      container node name carrying that shape
--   boxes     number of collision boxes
--   iou       match quality (0 when the fill-ratio fallback decided)
--   recall    share of solid cells covered (0 for the fallback)
--   fill      solid fraction of the full grid
--   recognised  true when a catalogue shape matched
function M.collision_profile(grid)
	local occ, occupied, solid = M.collision_occupancy(grid)
	local volume = R * R * R
	local fill = volume > 0 and (solid / volume) or 0

	local shape, iou, recall
	if occupied == 0 then
		shape = SHAPE_BY_ID.empty
	elseif occupied == CR * CR * CR then
		shape, iou, recall = SHAPE_BY_ID.full, 1, 1
	else
		shape, iou, recall = M.match_shape(occ, occupied)
	end

	local recognised = shape ~= nil
	if not shape then
		shape = fallback_shape(occ, fill)
		iou, recall = 0, 0
	end

	return {
		shape = shape.id,
		node = M.shape_node_name(shape.id),
		boxes = #shape.nodeboxes,
		iou = iou,
		recall = recall,
		fill = fill,
		recognised = recognised,
	}
end

-- Container node name a block with this grid should use.
function M.collision_variant(grid)
	return M.collision_profile(grid).node
end

-- Is this node type collidable at all?
function M.is_walkable_name(name)
	local def = core.registered_nodes and core.registered_nodes[name]
	return def ~= nil and def.walkable ~= false
end

-- Swap the container node to the variant matching the current grid.
-- Returns the chosen node name.
function M.update_collision_node(pos, block)
	local want = M.collision_variant(block.grid)
	if core.get_node(pos).name ~= want then
		core.swap_node(pos, {name = want})
	end
	return want
end

print("[micronode_chisel] Collision model loaded ("
	.. #SHAPE_LIST .. " shapes, 1/" .. CR .. " node resolution)")
