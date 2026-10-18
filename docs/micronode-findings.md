# Micronode Chisel — Engineering Findings

Read this before touching the renderer, picker, collision, or entity code.
Everything in §1 and §3 is ground truth taken from the engine sources in this
repository (`luanti/src/...`), not from observation.

---

## 1. Entity visuals: the cube is CENTERED on the entity position

Verified in `luanti/src/client/`:

| File | What it shows |
|---|---|
| `mesh.cpp:43` `createCubeMesh(scale)` | Vertices span **-0.5 .. +0.5**, then `scaleMesh(mesh, v3f(BS,BS,BS))` (BS = 10 = 1 node) |
| `content_cao.cpp:683` (`OBJECTVISUAL_CUBE`) | `m_meshnode->setScale(m_prop.visual_size)` — a scale about the node origin |
| `content_cao.cpp:972` `updateNodePos()` | The parent matrix node is translated to the entity position; the mesh node is a child at the origin |

So a `visual = "cube"` entity spans **pos ± visual_size/2**: it is centered,
exactly like a node (the node at `pos` covers `pos ± 0.5`).

**Consequence for face boxes** (`entities.lua: M.spawn_box`):

```lua
origin     = pos + (x0 + x1) / 2      -- box CENTER, not the min corner
visual_size = {x1 - x0, y1 - y0, z1 - z0}
```

**This is the bug that shipped three times.** The earlier implementation
spawned each face at the box's min corner (`pos + x0 + 0.5`), which displaces
every face by `0.5 - size/2` per axis. Full-size faces land correctly by
coincidence while small faces fly off by up to half a node — the block then
renders as disconnected, scattered faces instead of one solid. §5 has the
history. Do **not** reintroduce a "corner anchor" mode; the misdiagnosis was
caused by treating the integer node position as the node's *min corner*
(it is the *center*).

Also note:

- `visual_size` for `visual = "cube"` is in **node units** (not the 0.1-node
  scale used by `visual = "mesh"` models).
- A cube face maps its **whole texture** onto that face, so per-face texturing
  requires cropping (§3).
- `visual = "node"` (5.12+) exists but renders exactly one node type, so it
  cannot express per-instance chiseled geometry.
- Entity `static_save` is `false` here: render entities are derived data.
  `ServerEnvironment::deactivateFarObjects` keeps a **non-static** object alive
  while its mapblock is loaded in memory and drops it when the block unloads —
  exactly the lifetime we want, because `micronode_chisel:rebuild_meshes`
  (`run_at_every_load = true`) re-derives the geometry from metadata on every
  mapblock activation. Consequences: nothing stale survives a restart or a code
  change, and the per-block static object budget (`max_objects_per_block`,
  minimum 256) is not consumed. Persisting them (`static_save = true`) would
  both fight the LBM and risk that budget in a densely chiselled mapblock.

---

## 2. Architecture (Cube 2 / Sauerbraten model)

Sauerbraten's editing feel comes from three properties, replicated here:

1. **Surface-only rendering.** Only faces where solid borders air exist, and
   coplanar same-material faces are greedily merged into maximal rectangles per
   slice (`mesh.lua: M.build_surface_boxes`). Exactly one *drawn* quad per
   exposed face — no interior geometry, no overlapping solid boxes, no
   coincident coplanar quads (§3).
2. **Exact picking.** A voxel DDA march (Amanatides & Woo) along the look ray
   finds the first solid micronode and its entry-face normal
   (`edit.lua: M.raycast_grid`). Pull carves inward from that face, push adds a
   layer on the air side.
3. **Grid-snapped edits.** The brush is snapped to the active grid step
   (1, 2, 4, 8, 16 micronodes) around the hit cell
   (`edit.lua: M.push_brush` / `M.pull_brush`) — Sauerbraten's `gridpower`.
   The step is per player and selects both layer thickness and in-plane
   extent. It is persisted in player metadata and reachable from the tool
   description, `sneak+left` on a block, `/mn_grid`, and the size menu opened
   by right-clicking air (`/mn_menu`). Do not remove the menu: the key combo
   alone made the feature effectively undiscoverable.

### Modules

| File | Responsibility |
|---|---|
| `data.lua` | 16³ grid, palette, versioned RLE storage, transforms, textures |
| `collision.lua` | collision shape catalogue and recognition, container variant selection |
| `mesh.lua` | exposed-surface extraction, greedy merging, box hash |
| `edit.lua` | block access, DDA picking, brushes, region application, undo |
| `entities.lua` | render entity lifecycle (cube visual, centered transform) |
| `render.lua` | face texture crops, per-block rebuild, mapblock LBM |
| `clipboard.lua` | blueprint copy/paste (compressed payload, rotation, undo) |
| `chisel.lua` | container nodes, chisel tool, per-player size/material state, menus, chat commands |
| `api.lua` | public API for other mods |

### Coordinate spaces

- **block-local**: 1-based cell index `1..RESOLUTION` — the storage layout,
  `index = (z-1)*res*res + (y-1)*res + x`.
- **absolute**: 0-based micronode offset relative to a target block
  (`0..RESOLUTION-1` is that block). Brushes are built in this space and
  `edit.lua: split_region` splits a brush across node boundaries, so a push
  that crosses a border creates/fills the neighbouring chiseled block instead
  of stopping dead at it.
- **node-local render space**: `-0.5 .. 0.5`, what the mesher emits and what
  `spawn_box` consumes.

Grid indexing is the other classic trap: `M.get_voxel`/`M.set_voxel` take an
explicit `res` and the mesher/boundary masks pass theirs. A coarsened grid has
a different stride, and `M.count_solid` is nil-safe because short grids have
nil cells that `v ~= 0` would count as solid.

### Collision: shape recognition, not "solid or not"

In Luanti, `walkable` and `collision_box` belong to a node **type**, not to a
placed node, so per-micronode collision cannot be expressed on one container
node. The engine does support **several boxes per type**: `NodeBox::fixed` is a
`std::vector<aabb3f>` and `MapNode::getCollisionBoxes` (`mapnode.cpp:432`)
emits all of them (falling back to `node_box` only when `fixed` is empty), and
`collision.cpp:add_area_node_boxes` adds every box of every walkable node. A
staircase variant made of two boxes is therefore real engine collision, not a
hack.

Consequence: one container node type per recognised shape. `collision.lua`
holds the catalogue and picks the variant:

1. **Occupancy** is sampled on an 8³ grid (1/8 node = 12.5 cm). A collision
   cell is solid when **any** of its 2³ micronodes is solid. "Any" is
   deliberate: conservative collision means a chiselled floor never lets the
   player fall through, costing at most one collision cell of invisible bulk.
2. **Scoring** is intersection-over-union over each catalogue shape's own cell
   list (≤ 512 lookups), with a cheap `min/max` bound skipping candidates whose
   cell count is incompatible before any lookup.
3. A candidate is accepted only when `iou >= COLLISION_MIN_IOU` **and**
   `recall >= COLLISION_MIN_RECALL` (share of solid geometry covered), so a bad
   match can never turn a floor into a hole.
4. No acceptable match → a **safe fallback**. Geometry that reaches the node
   floor becomes a bottom slab up to its topmost occupied layer (and geometry
   hanging from the ceiling becomes the mirrored top slab). A slab is
   full-footprint, so recall is 1 by construction: an unrecognised floor or
   platform is standable instead of walk-through. Geometry floating mid-node
   keeps the legacy rule (`>= 50 % solid` → full cube, else no collision),
   because boxing in a carved alcove is worse than a passable decoration.

The catalogue is deliberately a fixed set of rudimentary forms rather than an
arbitrary box decomposition: full/empty, bottom and top slabs at 1/8 steps
(1/16-precision geometry snaps to the nearest), straight stairs in 4
orientations plus their inverted (ceiling) forms, **corner stairs** (one raised
quadrant = outer corner, 2 boxes; all but one = inner corner, 3 boxes),
walls/panels of 1/8, 1/4 and 1/2 thickness against a side, mid-node walls, and
corner/centred posts. 53 shapes, i.e. 53 registered container types
(`micronode_chisel:shape_*`, plus the two historical names for `full` and
`empty` so old worlds need no migration).

Corner stairs are why `M.match_shape` must keep preferring the **highest IoU**
and only use the box count as a tie-breaker: a single raised quadrant is
geometrically a subset of a straight stair (IoU 0.83), so a "fewest boxes wins"
rule would misclassify every straight stair as a corner. Symmetrically, the
inner corner is *not* the complement of the outer one (a solid node minus a
quadrant has IoU 0.22 with it), which is why both families are listed
explicitly.

Rules to preserve:

- `full` and `empty` keep the historical node names (`chiseled_block`,
  `chiseled_block_open`). Never rename them: they are in saved worlds.
- The empty/variant selection must keep working for *any* container name:
  classify through `M.CONTAINER_NODES`, never by comparing to two names.
- Collision-only changes must not touch metadata or geometry; the swap is a
  `core.swap_node`, which keeps metadata and skips callbacks.
- The collision LBM in `render.lua` re-picks the variant on mapblock load, so a
  changed catalogue applies to existing worlds without a migration.
- Cost is ~0.04 ms per block (one 4096-cell pass + candidate scoring), the same
  order as the mesher. Do not raise `COLLISION_RES` to 16 without re-measuring:
  at 16³ the occupancy is 4096 cells and every catalogue shape covers far more
  cells, which is where this stops being cheap.

### Clipboard (blueprint copy/paste)

`clipboard.lua` copies one block's **compressed** payload (grid + palette +
base material) into player metadata and stamps it onto other nodes.
Invariants:

- The clipboard stores bytes, never a live `block` table: every paste decodes a
  fresh grid, so one copy can be stamped any number of times without aliasing
  world data.
- Rotation/flip are applied at paste time (`M.rotate_grid`/`M.flip_grid`) and
  the *state* lives in the clipboard, so the same copy can be stamped in four
  orientations and mirrored without re-copying.
- Pasting onto a chiseled block replaces its payload; onto a chiselable plain
  node it converts it; onto air/passable it creates a block. Solid
  non-chiselable nodes are refused, protected nodes are refused.
- **Undo snapshots are taken before the mutation** (`M.begin_undo_entry` →
  `M.add_undo_position` → mutate → `M.commit_undo_entry`). Snapshotting after
  the paste records the new state and makes undo a no-op; that bug shipped once
  and is now covered by tests.

### Border pushes cost a node

A brush aimed at a face that sits on the node border reaches into the
neighbouring node, so applying it creates a chiseled block there
(`edit.lua: M.region_neighbour_blocks`). That is allowed, but it is charged:
one node of the pushed material per block created
(`M.can_pay_for_node` / `M.pay_for_node`), and creative players pay nothing
(`core.is_creative_enabled`). Pushing into an *existing* chiseled neighbour
creates nothing and is free.

- The cost is computed from the split region, so a diagonal brush that touches
  two empty neighbours is charged twice and rolls back completely when the
  player cannot pay (checked before, paid after a successful apply).
- Players without an inventory (the public API, tests, non-player callers) are
  treated as creative rather than denied: an API caller must not need a fake
  inventory to place a block.

### Empty blocks are not nodes

Carving the last solid cell away removes the container node
(`edit.lua: M.remove_if_empty`), because an empty container is an invisible,
walk-through node that still occupies the map and has to be dug away by hand.
`mapblock` LBM also cleans up empties left behind by older builds.

`remove_if_empty` is deliberately **not** called from `refresh_block`: undo and
snapshot restore must be able to put an empty block back exactly as it was.
Copying an empty block is refused for the same reason (the blueprint would be
useless).

### Open faces: who has to be re-meshed

A block culls its faces against its neighbours (whole-face for a solid cube,
per cell for a chiseled block), so **any** change on the other side of a shared
boundary invalidates that culling. `edit.lua: M.remesh_neighbors(pos)` re-meshes
the six neighbours that are chiseled blocks, and is called from:

- `after_destruct` of the container (chiseled block dug or removed),
- `core.register_on_dignode` (a plain node removed next to a block),
- `core.register_on_placenode` (a plain node placed next to a block),
- `M.remove_if_empty` (a neighbour carved to nothingness).

Two engine facts decide where that call may live:

1. `on_destruct` runs **before** the node is replaced with air
   (`serverenvironment.cpp:636`). Re-meshing there makes neighbours cull
   against a block that is about to vanish, i.e. it produces exactly the holes
   it was meant to fix. Use `after_destruct(pos, oldnode)`.
2. `core.set_node` / `core.swap_node` do **not** fire `register_on_placenode`.
   Code that converts or places nodes directly must call
   `M.remesh_neighbors` itself if the culling changes (converting a solid node
   into a full chiseled block does not).

---

## 3. Rendering rules

### Face slabs, not paper-thin quads

Each merged face is emitted as a slab whose **outward plane is exactly on the
voxel boundary** and which extends `FACE_DEPTH_FRACTION` (1/4) of a micronode
into the solid. That keeps the box non-degenerate and makes neighbouring faces
interpenetrate slightly at shared edges.

Depth must stay well below one micronode: at a full-voxel depth, a one-voxel
thick feature (a shelf, a wall) produces two boxes whose *inner* planes
coincide exactly, which z-fights. Surface planes are always ≥ 1/RESOLUTION
apart, so a quarter-micronode depth can never coincide with another surface.
The depth is an **absolute** quarter micronode, not a quarter of a mesh cell:
the render fallback meshes at 1/2, 1/4 or 1/8 resolution, and its slabs still
have to avoid full-resolution surface planes in neighbouring blocks.

Seams between perpendicular faces are *not* what the extrusion fixes — exact
math already makes the faces share edges. The historical "split up parts" look
was the transform bug of §1.

### One drawn quad per face box (the z-fighting rule)

A face box is a cube entity, so it carries six quads, but only its **outward**
quad belongs to the visible surface. The other five must be invisible: the box
of a `+X` face spans `x ∈ [plane-d, plane]` and, at the top of its rectangle,
`y = 0.5` — which is exactly the plane of the `+Y` face box beside it. Two
opaque coplanar quads at the same depth fight for the depth buffer, which is the
flicker seen along every chiselled edge.

`render.lua: M.face_textures` therefore puts the material crop on the outward
face only and `M.HIDDEN_TEXTURE` (`blank.png`) on the rest. That is reliable
because entity cube visuals use `TILE_MATERIAL_BASIC` →
`EMT_TRANSPARENT_ALPHA_CHANNEL_REF` → `USE_DISCARD_REF`, so fragments with
alpha < 0.5 are discarded rather than drawn
(`src/client/shader.cpp:888,807`, `object_shader/opengl_fragment.glsl:383`).
The quads are never rasterised: no blending, no sort order, no depth writes.
Do not "overlap them instead" — offsetting cannot remove a coincident plane,
only hide it under another one.

Invariant to preserve: **each exposed micronode face produces exactly one drawn
quad, and no two drawn quads share a plane with overlapping area.** Both the
in-engine suite (`test_drawable_quads`) and the QC harness
(`[qc] z-fighting invariant`) assert it on a full block, a corner carve, a
cavity and a one-voxel shelf.

### Neighbour culling

Faces on a node boundary are dropped when the adjacent node is a full solid
cube, and **per cell** when the adjacent node is a chiseled block that has solid
cells touching that face (`edit.lua: M.build_neighbors`,
`boundary_mask`). Per-cell culling is required: without it two adjacent
chiseled blocks emit coincident faces along their shared boundary.

Face-plane coordinates are shared between neighbours:

```
axis 1 (x faces): u = y, v = z
axis 2 (y faces): u = x, v = z
axis 3 (z faces): u = x, v = y
```

Unloaded ("ignore") neighbours are treated as **open**, so a block never shows
a hole while the neighbouring mapblock is not loaded.

### Render budget and the coarsening fallback

One entity per merged face is the only per-instance geometry the engine offers,
so a block has an entity budget: `micronode_chisel.max_render_boxes`
(default **512**, `0` = unlimited). The default used to be 96, which ordinary
carved shapes exceeded; the fallback then made the block look like a full cube
again (see §5). `/mn_budget <boxes>` changes the limit for the running server
(requires the `server` privilege) and re-meshes the blocks already rendered;
put the setting in `minetest.conf` to persist it.

When a block is over budget, `render.lua: M.render_boxes` re-meshes a
downsample (`M.coarsen_grid`) at factor 2, 4 or 8, using neighbour masks read
at the same stride (`edit.lua: M.build_neighbors(pos, step)`). Rules:

- **Majority, ties to air, never "any".** "Any-solid" is watertight but fills
  every cavity thinner than a coarse cell, which is exactly the "the node
  turned back into a full block" symptom. Strict majority can lose details
  smaller than a coarse cell, but it cannot invent a solid mass out of a
  mostly-empty region.
- **Never render nothing.** If majority coarsening erases a genuinely thin
  shape, the full-resolution list is used even if it is over budget. An
  invisible block is worse than a dense one.
- The metadata is never touched by the fallback: coarsening is a render-only
  level of detail, and the next edit/LBM re-derives from the full grid.

### Texture crops

A cube face maps its whole texture, so each face gets a crop of the material
texture (`render.lua: M.crop_texture`), which makes the pattern line up across
faces and across blocks (Sauerbraten-style world-aligned texturing):

- normalize first: `tex .. "^[resize:16x16"` (texture-pack agnostic);
- crop with `[combine:WxH:-x,-y=<escaped>` — **negative** blit offsets.
  `[combine` blits at (x,y) *onto* the canvas, so positive offsets land outside
  it and the face becomes fully transparent ("invisible block" bug);
- escape `^` and `:` in the inner texture (`base:gsub("([%^:])", "\\%1")`);
- UV regions follow `createCubeMesh`'s per-face UV winding; texture/tile order
  is **+Y, -Y, +X, -X, +Z, -Z**.

The crop is applied to the outward face only (see above); the remaining five
faces carry `blank.png`.

---

## 4. Voxel DDA picking

`edit.lua: M.raycast_grid(grid, pos, origin, dir, res)`:

- Ray origin is the player eye (`get_pos()` = feet, plus `eye_height`);
- the ray is transformed into block-local voxel units, `0..res` per axis;
- a slab test clips it to the node's AABB, giving `t_enter`, `t_exit` and the
  entry face (used as the first cell's normal);
- Amanatides & Woo marching thereafter; each step's normal is `-step`, i.e. it
  points at the air side of the hit face;
- if the ray starts inside the block, no entry face exists and the normal is
  zero (push then refuses, pull carves the hit cell).

Verified scenarios: straight down on a full block → top cell, `+y`; from -x on
a full block → cell 1, `-x`; half slab → top cell of the slab, `+y`; carved
half → the remaining slab's face; empty grid → nil.

---

## 5. Failure history (what NOT to repeat)

| Symptom | Root cause |
|---|---|
| **Block renders as disconnected, scattered faces** (three rounds) | Face entities spawned at the box's min corner although cube visuals are centered (§1). Each face displaced by `0.5 - size/2` |
| "Everything is half a node off" | Same root cause, opposite compensation: entity placed at `pos + center + 0.5` (treating `node pos` as the min corner) |
| Textures stretched/warped | Cube visual maps the whole texture per face; no crop (§3) |
| Open sides / invisible block | `[combine` blit offsets positive instead of negative, or a reversed extent making the region land outside the canvas |
| Node "refills" at ~12% chiseled | Render-budget fallback spawned one full-block box. The fallback now re-meshes a conservative downsample, never a hull |
| **Chiselled block looked like a full node again after continued carving** | The 96-box render budget was reached and the fallback downsampled with "any-solid", which filled every cavity wall thinner than a coarse cell. Fixed by a 512 default, strict-majority downsampling (ties to air) and coarse neighbour masks. The old fallback also read the neighbour masks at the 16³ stride |
| Block rendered as "split up parts" | Paper-thin quads *plus* the transform bug: the displacement was read as a seam problem and "fixed" by extruding a full voxel, which reintroduced z-fighting on thin features (§3) |
| Rest of node invisible + floating top | Coarse grid read with the 16³ stride (§2) |
| Startup crash ×3 (`solid_outside_sides`, `block_grid`, `voxel` nil) | Multi-step patch scripts: a later step failed after earlier steps had landed, leaving orphaned references |
| Spawned stone block kills player | `test_entity_rendering` placed a node in the spawn column on every world start |
| Edits that silently did nothing | Brush material index written into the grid without registering it in the block palette; palette entries were never compacted, so the 4 slots filled with dead materials |
| Crash `mesh.lua: attempt to compare number with nil` on any non-full block | The per-slice face mask is **sparse** (only exposed cells are stored), so `mask[...]` is `nil` for unexposed cells. `mat > 0` then compares nil. A fully solid block has a dense mask, which is why only slabs/carves crashed. Read masks as `mask[...] or 0` |
| Shimmer / flicker along chiselled edges | Every face box drew all six of its quads, so a slab's side quad sat exactly in the neighbouring face box's outward plane — two opaque coplanar quads z-fighting. Fixed by drawing only the outward quad (§3) |
| **Collision recognition never matched thin shapes** | The occupancy cell index was computed with a stray `+1` while the catalogue used a 0-based scheme. Full blocks still worked (fast path) and full-footprint shapes mostly cancelled the shift out, so only panels/posts/step shapes fell back to "empty". Caught by the shape tests; index both sides from the same formula |
| **Corner stairs were never recognised** | The catalogue only had straight stairs, and a single raised quadrant is a subset of a straight stair, so the nearest match was "stair" by a wide margin. Fixed by adding the outer (one quadrant) and inner (all but one) corner families and keeping the highest IoU as the primary ranking criterion |
| **Paste could not be undone** | The undo snapshot was taken *after* the block was replaced, so it recorded the pasted state. Snapshots must be taken before the mutation (§2, "Clipboard") |
| **Neighbours kept holes after a node next to them was dug** | Nothing re-meshed them. Worse, the first attempt put the re-mesh in `on_destruct`, which runs while the node still exists, so the neighbours culled against it again. Re-mesh belongs in `after_destruct`, plus `register_on_dignode`/`register_on_placenode` for plain nodes (§2, "Open faces") |
| **Carving a block to nothingness left an invisible node** | The container stayed behind, empty and walk-through, so the position had to be dug away manually. `M.remove_if_empty` now deletes it, and the mapblock LBM cleans up old worlds |
| A crash in one self-test hid all later ones | The suites ran unwrapped in a single `core.after` callback, so the first error aborted the run. Each suite is now `pcall`ed and reported individually |
| Process lesson | Never script a multi-part edit where one part can fail after another part was written. Run `python3 tools/headless_qc.py` before pushing — its strict-globals pass catches orphaned references, its render audit catches transform and crop regressions |

---

## 6. Testing and QC

- `micronode_chisel/test.lua` — in-engine self tests, run ~2 s after server
  start (`micronode_chisel.tests = false` disables). Covers data, storage,
  palette, transforms, meshing, the drawable-quad (z-fighting) invariant,
  picking, brushes, editing/undo integration, the entity transform (entity
  positions must equal box centers) and benchmarks. Each suite is `pcall`ed and
  reported separately, so one raised error cannot hide the rest.
- `tools/stub.lua` — headless engine stub: node store, metadata store, entity
  store with ObjectRef-ish objects, JSON passthrough.
- `tools/qc_checks.lua` + `tools/headless_qc.py` — runs the real mod Lua against
  the stub in CI, including:
  - storage round trips and the 1 byte/cell size bound,
  - mesher invariants (count, bounds, outward planes, one thin axis, per-cell
    neighbour culling, material splits, hash sensitivity),
  - the **z-fighting invariant**: no two drawn quads may be coplanar with
    overlapping area, checked on a full block, a staircase, a cavity, a corner
    carve and a one-voxel shelf,
  - render-budget coarsening (strict-majority rule, no refill, cavity survives,
    checkerboard does not collapse, budget path never renders nothing),
  - grid-step selection and that the selected step really changes a pushed
    volume (1³ vs 4³),
  - neighbour masks at both the full and the coarse stride,
  - collision shape recognition: full/empty fast paths, slabs at 1/8 snapping,
    all four straight stair orientations with two boxes each, all four outer
    and all four inner corner stairs, straight-vs-corner disambiguation,
    panels and posts, the floor/ceiling safe fallback, every catalogue shape
    registered with the matching `collision_box`, and a per-call cost budget,
  - border pushes: spill detection, survival cost (one node per created block,
    refused when unaffordable) and creative being free,
  - empty blocks: carve-to-nothingness removes the node, undo restores it, and
    `remove_if_empty` handles containers left by older builds,
  - open faces: a culled face comes back when its neighbour is removed, and the
    neighbour is actually re-meshed (entity count grows by exactly one),
  - clipboard: copy → paste equality, rotated paste equals `rotate_grid`,
    conversion of plain nodes, liquid replacement, persisted rotation/flip,
    empty-clipboard refusal and undo of a paste,
  - DDA picking and brush regions,
  - the **render audit**: chisel → carve → re-mesh, then verify every entity
    sits at its box center with the exact box size, inside the node, drawing
    exactly one face with a parseable `[combine` crop,
  - a strict `_G` pass that raises on undefined global reads.

---

## 7. Known limitations (v1)

| Limitation | Impact | Path forward |
|---|---|---|
| Collision is a recognised shape, snapped to 1/8 node | A shape that matches no catalogue entry gets the safe fallback (floor/ceiling sheets become slabs, mid-node geometry uses the old 50 % rule), so carved detail below 12.5 cm collides as its snapped shape — up to one collision cell of invisible bulk, deliberately conservative so floors never open | Add catalogue entries for the shapes players actually build; engine support for per-node collision boxes |
| Border pushes create a node in the neighbour position | Allowed and charged in survival, free in creative; a full inventory-less API caller is treated as creative | Multi-block brush with a single confirmation, or a placement preview |
| Lighting is per node | A carved cavity still occludes sunlight as if solid | Engine micronode lighting (Phase 3 in `docs/subnode-editing-plan.md`) |
| One entity per merged face | A chaotic carve can reach the budget (`micronode_chisel.max_render_boxes`, default 512) and then renders at a majority-coarsened downsample, which loses features smaller than a coarse cell but never turns the carve back into a full cube | Engine-side per-block mesh; raise the setting or set it to 0 while waiting |
| 4 materials per block | Pushing a 5th material is refused with a message | Palette per face, or engine support |
| Editing crosses node borders by creating neighbours | Pushing into a solid non-chiseled node does not convert it (it stops at the boundary) | Convert-on-push, needs a "was converted" marker for undo |
| `swap_node` keeps metadata | A container node replaced by `/setnode` with leftover metadata is re-initialised empty | — |
| Blueprint is single-node | Copy/paste stamps one node; a multi-node selection is not modelled | Copy a region into several blocks, or paste per node |
