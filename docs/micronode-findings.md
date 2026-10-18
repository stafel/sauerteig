# Micronode Chisel — Engineering Findings

Accumulated findings from the micronode_chisel development rounds (2026-10-18).
Read this before touching the renderer, picker, or entity code.

---

## 1. Luanti 5.17.0 entity engine semantics (empirically verified)

### Cube entity visual (`visual = "cube"`)

- `visual_size` is in **node units** (NOT the 0.1-node scale used for
  `visual = "mesh"` models; do not multiply by 10).
- **The anchor point is the min corner**: the rendered cube extends
  **+size** from the entity position (observed behavior on 5.17.0).
  The engine source (`createCubeMesh` + `setScale`) reads as if the cube
  were centered, but three independent in-game observations proved the
  effective anchor is the corner:
  1. Full 1×1×1 box spawned at box-center → rendered +0.5 in every axis.
  2. Thin (1/16) carve walls nearly correct while a 1×1 top face was
     offset +0.5 → shift = +size/2, i.e. corner anchor.
  3. After surface meshing, every face displaced by half its extent.
  A center-anchored client would have shown zero offset in all three.
- Consequence in `spawn_box` (entities.lua): entity position must be
  `pos + (box.x0 + 0.5, box.y0 + 0.5, box.z0 + 0.5)` — the box's min
  corner in world space.
- Calibration valve: setting `micronode_chisel.anchor`
  (`"corner"` default, `"center"` alternative) recalibrates without a
  code change if a future engine build anchors differently.
- Each face of a cube visual maps its **whole texture** onto that face
  regardless of box size → textures must be cropped per face with
  `[combine` (see §3 texture crops).

### `visual = "node"` exists (5.12+) but was not used
It renders exactly one node type — not usable for arbitrary chiseled
geometry. Cube visuals + per-face crops is the current approach.

### Entities and persistence

- `static_save = true` entities are persisted in the map; buggy render
  entities from old code **survive code fixes** and reappear every load.
  Render entities now use `static_save = false`; an LBM
  (`micronode_chisel:rebuild_meshes`, `run_at_every_load = true`)
  re-meshes from metadata on every mapblock activation.
- Legacy entity cleanup: `on_activate` removes any entity whose
  staticdata lacks the current format field (`texs`); removal radius
  widened to 8 nodes.

### Raycast / pointed_thing

- `pointed_thing.above/under` carry only **integer node positions**;
  they cannot locate a micronode. Precise hits require either
  `core.raycast` (gives `intersection_point`) or — the final solution —
  a voxel DDA march through the block's own grid (see §4).
- Player eye height used: `player:get_pos() + (0, 1.475, 0)`.

---

## 2. Architecture (Cube 2 / Sauerbraten model)

Research sources: `docs/spike-results/sauerbraten-spike.md`,
https://github.com/embeddedc/sauerbraten (engine/octa*.cpp).
Sauerbraten's editing quality comes from three properties we replicate:

1. **Surface-only rendering**: only faces where solid borders air are
   emitted; faces are greedily merged into maximal coplanar rectangles
   per slice/material. No interior geometry, no overlapping solid boxes,
   no z-fighting. (`M.generate_surface_faces`, render.lua)
2. **Exact picking**: a DDA march of the look ray through the voxel grid
   finds the first solid micronode and its entry-face normal
   (`pick_micronode`, chisel.lua). Remove carves the hit voxel; add
   grows on the air side of the hit face (Sauerbraten `mpeditface`
   semantics).
3. **Instant local feedback**: edits apply to grid + metadata, then
   re-mesh; no geometry data crosses the network.

### Grid indexing gotcha (bit us once)

`M.get_voxel` hardcodes the 16³ stride
`(z-1)*16*16 + (y-1)*16 + x` (1-based, +x — correct for full-res grids).
Coarse grids (see below) have a **different stride**. The mesher must
use its own resolution-local accessor (`voxel()` inside
`generate_surface_faces`), not `M.get_voxel`.

Also: `M.count_solid` must be **nil-safe** (`grid[i] ~= 0` is TRUE for
nil entries — coarse grids are shorter than 4096 and miscounted).

### Progressive coarsening (render budget)

`M.MAX_RENDER_BOXES = 48` entities per block. When the full-res surface
exceeds it, `update_block_mesh` re-meshes from `M.coarsen_grid(grid,
step)` at step = 2, 4, 8, 16 (majority-fill downsampling). The coarse
grid has resolution `oR = ceil(16/step)` and is laid out with oR³
stride; `coarsen_grid` returns `(grid, oR)` and the mesher receives `oR`
as its `res` parameter. **Never** fall back to a full-block box — that
was the "node refills at ~12% chiseled" bug (any carve exceeding 48
rects snapped the block back to solid).

---

## 3. Texture crops

Per-face textures are produced in `entities.lua`:

- Normalize first: `tex .. "^[resize:16x16"` (texture-pack agnostic).
- Crop with `[combine:WxH:-x,-y=<escaped>` — **negative** blit offsets.
  `[combine` blits at (x,y) ONTO the canvas; positive offsets place the
  texture outside the canvas → fully transparent face ("open sides"
  bug). Escaping: `base:gsub("([%^:])", "\\%1")`.
- UV regions follow nodebox conventions (match
  `convertNodeboxesToMesh` in engine `mesh.cpp`); texture order:
  +Y, -Y, +X, -X, +Z, -Z.

---

## 4. Voxel DDA picking (Amanatides–Woo)

`pick_micronode(pos, player, grid)` in chisel.lua:

- Ray origin: eye, block-relative, scaled to voxel units (`× R`).
- Voxel i covers `[(i-1)/R, i/R)` — 1-based indices.
- Boundary distance: `(boundary - o[axis]) / d[axis]` where boundary is
  `c` when stepping positive and `c - 1` when negative. Zero-direction
  components use `math.huge` (early-out `t[axis] > 512`).
- Returns hit voxel + entry-face unit normal (air side).
- Verified scenarios: top-center look on full block → (9,16,9)/+y;
  half-slab top → y=8/+y; side look → x=16/+x; empty grid → nil.

---

## 5. Failure history (what NOT to repeat)

| Symptom | Root cause |
|---|---|
| Progress % wrong / hits not where clicked | Picking used `pointed_thing.above` integer math with unclamped per-face formulas |
| Geometry half-node offset (3 rounds) | Wrong cube-visual anchor assumption (center vs corner, §1) |
| Textures stretched/warped | Cube visual maps whole texture per face; no crop (§3) |
| Open sides (invisible faces) | `[combine` blit offsets positive instead of negative |
| Node "refills" at ~12% chiseled | Render-budget fallback spawned one full-block box |
| Rest of node invisible + floating top | Mesher read coarse grid with 16³ stride (§2 gotcha) |
| Startup crash ×3 (`solid_outside_sides`, `block_grid`, `voxel` nil) | Multi-step patch scripts: a later step's `assert` failure rolled back part of an edit while another step's changes had already landed |
| Spawned stone block kills player | `test_entity_rendering` placed a node at (0,40,0) — the spawn column — on every world start |

**Process lesson**: every shipped crash class (orphaned reference) came
from scripted multi-block edits. Rules:

1. Never script a multi-part edit where one part can fail after another
   has been written. Apply the whole edit atomically or verify
   afterwards with the QC harness before committing.
2. Always run `python3 tools/headless_qc.py` before pushing. Its
   strict-globals check would have caught all three orphaned-reference
   crashes.
3. CI (`.github/workflows/qc.yml`) runs syntax + headless QC on every
   push; keep it green.

---

## 6. QC infrastructure

- `tools/stub.lua` — minimal headless `core`/`vector` stubs.
- `tools/headless_qc.py` (needs `pip install lupa`, real Lua 5.5):
  - loads all six mod files with stubs,
  - **strict globals**: every file executed under a `_G` metatable that
    raises on undefined global reads — catches orphaned references at
    load time,
  - functional checks against the real Lua code: full block → 6 faces
    in bounds; empty → 0; half slab → 6 faces with merged top at y=0;
    corner carve → 12 faces; coarse path spans full node; coarsen of
    full stays full; serialization round-trip preserves 4096 voxels;
    spawn-origin check (corner anchor places box exactly in region).
- Python ports of mesher/DDA (used during development to verify logic
  before committing Lua) are in the session history; prefer extending
  the lupa harness since it exercises the actual Lua code.

## 7. Known open items / v2 candidates

- Collision is v1 full-block AABB (`collision.lua`); per-micronode
  collision is the planned v2 (`get_detailed_collision_boxes` exists
  as a stub).
- `MAX_RENDER_BOXES = 48` is per-block; watch entity counts if
  raising.
- The `micronode_chisel.anchor` setting defaults to `corner`; if a
  future engine release changes cube anchoring, recalibrate via
  minetest.conf instead of code.
