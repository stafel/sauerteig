# Micronode Chisel — Engineering Findings

Read this before touching the renderer, picker, or entity code. Everything in
§1 and §3 is ground truth taken from the engine sources in this repository
(`luanti/src/...`), not from observation.

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
   slice (`mesh.lua: M.build_surface_boxes`). No interior geometry, no
   overlapping solid boxes, no z-fighting inside the shape.
2. **Exact picking.** A voxel DDA march (Amanatides & Woo) along the look ray
   finds the first solid micronode and its entry-face normal
   (`edit.lua: M.raycast_grid`). Pull carves inward from that face, push adds a
   layer on the air side.
3. **Grid-snapped edits.** The brush is snapped to the active grid step
   (1, 2, 4, 8, 16 micronodes) around the hit cell
   (`edit.lua: M.push_brush` / `M.pull_brush`) — Sauerbraten's `gridpower`.

### Modules

| File | Responsibility |
|---|---|
| `data.lua` | 16³ grid, palette, versioned RLE storage, transforms, textures |
| `collision.lua` | solid vs walk-through container variant, fill ratio |
| `mesh.lua` | exposed-surface extraction, greedy merging, box hash |
| `edit.lua` | block access, DDA picking, brushes, region application, undo |
| `entities.lua` | render entity lifecycle (cube visual, centered transform) |
| `render.lua` | face texture crops, per-block rebuild, mapblock LBM |
| `chisel.lua` | container nodes, chisel tool, chat commands |
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
apart, so a quarter-voxel depth can never coincide with another surface.

Seams between perpendicular faces are *not* what the extrusion fixes — exact
math already makes the faces share edges. The historical "split up parts" look
was the transform bug of §1.

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

Only the outward face of a slab is ever visible, so the same crop is reused for
all six cube faces (cheaper texture strings, no media cost — modifiers are
resolved client-side).

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
| Block rendered as "split up parts" | Paper-thin quads *plus* the transform bug: the displacement was read as a seam problem and "fixed" by extruding a full voxel, which reintroduced z-fighting on thin features (§3) |
| Rest of node invisible + floating top | Coarse grid read with the 16³ stride (§2) |
| Startup crash ×3 (`solid_outside_sides`, `block_grid`, `voxel` nil) | Multi-step patch scripts: a later step failed after earlier steps had landed, leaving orphaned references |
| Spawned stone block kills player | `test_entity_rendering` placed a node in the spawn column on every world start |
| Edits that silently did nothing | Brush material index written into the grid without registering it in the block palette; palette entries were never compacted, so the 4 slots filled with dead materials |
| Crash `mesh.lua: attempt to compare number with nil` on any non-full block | The per-slice face mask is **sparse** (only exposed cells are stored), so `mask[...]` is `nil` for unexposed cells. `mat > 0` then compares nil. A fully solid block has a dense mask, which is why only slabs/carves crashed. Read masks as `mask[...] or 0` |
| A crash in one self-test hid all later ones | The suites ran unwrapped in a single `core.after` callback, so the first error aborted the run. Each suite is now `pcall`ed and reported individually |
| Process lesson | Never script a multi-part edit where one part can fail after another part was written. Run `python3 tools/headless_qc.py` before pushing — its strict-globals pass catches orphaned references, its render audit catches transform and crop regressions |

---

## 6. Testing and QC

- `micronode_chisel/test.lua` — in-engine self tests, run ~2 s after server
  start (`micronode_chisel.tests = false` disables). Covers data, storage,
  palette, transforms, meshing, picking, brushes, editing/undo integration, the
  entity transform (entity positions must equal box centers) and benchmarks.
- `tools/stub.lua` — headless engine stub: node store, metadata store, entity
  store with ObjectRef-ish objects, JSON passthrough.
- `tools/qc_checks.lua` + `tools/headless_qc.py` — runs the real mod Lua against
  the stub in CI, including:
  - storage round trips and the 1 byte/cell size bound,
  - mesher invariants (count, bounds, outward planes, one thin axis, per-cell
    neighbour culling, material splits, hash sensitivity),
  - render-budget coarsening,
  - DDA picking and brush regions,
  - the **render audit**: chisel → carve → re-mesh, then verify every entity
    sits at its box center with the exact box size, inside the node, with
    parseable `[combine` crops,
  - a strict `_G` pass that raises on undefined global reads.

---

## 7. Known limitations (v1)

| Limitation | Impact | Path forward |
|---|---|---|
| Collision is per block, not per cell | A block below 50 % solid becomes walk-through, above it collides as a full cube | Engine support for per-node collision boxes, or invisible physical entities |
| Lighting is per node | A carved cavity still occludes sunlight as if solid | Engine micronode lighting (Phase 3 in `docs/subnode-editing-plan.md`) |
| One entity per merged face | A chaotic carve can reach the budget (`micronode_chisel.max_render_boxes`, default 96) and then renders at a conservative downsample | Engine-side per-block mesh |
| 4 materials per block | Pushing a 5th material is refused with a message | Palette per face, or engine support |
| Editing crosses node borders by creating neighbours | Pushing into a solid non-chiseled node does not convert it (it stops at the boundary) | Convert-on-push, needs a "was converted" marker for undo |
| `swap_node` keeps metadata | A container node replaced by `/setnode` with leftover metadata is re-initialised empty | — |
