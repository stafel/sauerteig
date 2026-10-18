# Sauerbraten → Luanti Map/Structure Port — Exploration & Plan

**Status:** exploration complete, no code written yet
**Scope:** converting Sauerbraten (`.ogz`) world geometry into Luanti, first as
a standalone porter, later as a source of structures/dungeon templates for
worldgen (goal.md §6, M4)
**Verification:** every format claim below was read from the engine sources in
`sauerbraten/src/` (file:line given). Anything measured rather than read is
marked **(to measure)**.

---

## 1. What we are actually trying to move

| We want | We do not want |
|---|---|
| World **geometry** (solid vs air) at Sauerbraten's precision | Textures, models, sounds (Sauerbraten media is **not** free — `README.md:118-124`) |
| **Material classes** (stone/metal/wood/water/lava/…) good enough to build dungeons | Per-face texture identity or lightmaps |
| **Structure markers** (spawns, triggers, lights, teleporters) | Gameplay logic, PVS data, BSP |
| Hand-authored room/dungeon shapes as **templates** | Whole-map live streaming of `.ogz` at runtime |

**Licensing is a hard gate on *shipping* converted content.** The engine code is
zlib, but maps are authored works with mixed/absent licences (`README.md`
"License"). The *tool* is unproblematic; any converted map we ship needs explicit
permission. **Fixtures must be maps we author ourselves in Sauerbraten's editor**
(a few rooms, a staircase, a slanted-corner shape, a water pool), which also
gives us ground truth for the converter's precision claims.

---

## 2. Ground truth: the `.ogz` format

### 2.1 Container

`opengzfile` (`sauerbraten/src/engine/worldio.cpp:66`) — the whole file is a
**gzip stream**, little-endian throughout. Magic `"OCTA"`, current
`MAPVERSION 33` (`src/engine/world.h:8`).

Header (`world.h:10-22`): `char magic[4]; int version, headersize, worldsize,
numents, numpvs, lightmaps, blendmap, numvars, numvslots;`

Load order (`worldio.cpp:1002-1242`), which a reader must mirror exactly:

1. header (7 ints), then the *extended* header fields
2. `numvars` variables: `u8 type`, `u16 name_len`, name, value
3. game ident string (v≥16) + `u16 extrasize` + extras
4. **texture MRU list**: `u16 count` + `count × u16` slot indices
5. `numents × sizeof(entity)` — `vec o` (3 float) + `short attr1..5` + `u8 type`
   + `u8 reserved` = 24 bytes (`src/shared/ents.h:8-14`)
6. vslots
7. **the octree**
8. lightmaps, PVS, blendmap (irrelevant to geometry)

### 2.2 Octree

`struct cube` (`octa.h:195-213`): `cube *children`, `uchar edges[12]`,
`ushort texture[6]`, `ushort material`, `uchar merged`, `uchar escaped/visible`.

- **12 edges, one byte each, two 4-bit values in 0..8** — the cube's geometry is
  stored at **1/8-cube precision** (`docs/dev/readme_developer.txt:47-59`).
- Octant index `i` gives `x = i&1`, `y = (i>>1)&1`, `z = (i>>2)&1`
  (`geom.h:1137`), positions growing from 0 to `worldsize` in all axes:
  **Z-up, origin at the corner, `insideworld` is `0 <= v < worldsize`**
  (`shared/iengine.h:210-220`).
- Per-node tag byte (`worldio.cpp:214`): low 3 bits
  `0 children / 1 empty / 2 solid / 3 normal / 4 lodcube`; flags
  `0x20` surfaces present, `0x40` material present, `0x80` merged. Afterwards
  `6 × u16 texture`, optional `u16 material`, optional `merged`, optional
  surface block, then (if `lodcube`) children (`worldio.cpp:501-737`).
- Vertex decode (`octa.cpp:656-688`): the vertex at corner `(x,y,z)` takes its
  **x** from edge `(0, y, z)`, its **y** from edge `(1, z, x)`, its **z** from
  edge `(2, x, y)`. The 12 spans are 12 independent values in 0..8, so a leaf is
  a **general hexahedron**: axis-aligned when spans are consistent, slanted
  when a corner was dragged individually. Not "just a box".
- `F_SOLID = 0x80808080` per axis (all spans 8..8), `F_EMPTY = 0`
  (`octa.h:250-257`).

### 2.3 Materials

`ushort material` is a bitfield on the cube's **empty space**
(`shared/iengine.h:23-36`): volume `MAT_WATER / MAT_LAVA / MAT_GLASS`, clip
`MAT_NOCLIP / MAT_CLIP / MAT_GAMECLIP`, flags `MAT_DEATH`, `MAT_ALPHA`. So
"water" is not a texture — it is a property of the empty cells inside a cube.

### 2.4 Textures vs material names

`texture[6]` holds **slot indices**, and the file's MRU list is also indices. The
*names* only exist in the map's config (`packages/base/abbey.cfg`:
`texture 0 "ik2k/ik_floor_brick128a.jpg"` lines, `texturereset`, `exec` chains).
Resolving index → path means replaying that config. Practical consequence: we
do not need exact identities; a **rule table over the texture path**
(`brick→brick`, `wood→wood`, `metal/tech→steel`, `grass→grass`, `water→water`,
`lava→lava`) plus fallbacks is enough for dungeon building, and stays
configurable.

### 2.5 What already exists in the engine

- `writeobj` (`worldio.cpp:1285-1385`) exports the loaded world to OBJ+MTL with
  one group per texture slot. **It is inside `#ifndef STANDALONE`** and walks
  `valist`, the client-side vertex arrays, so it needs the **OpenGL client**, not
  the dedicated server.
- The dedicated server (`src/sauer_server`) builds from `engine/server.cpp`
  (`#ifdef STANDALONE main()`), has the full octree in memory, and takes no
  `-x` script — but it *is* our own build target, so it can be patched cheaply.

---

## 3. The precision match that makes this attractive

| | Lattice | Note |
|---|---|---|
| Sauerbraten leaf vertex | **1/8 cube** | 12 edge values 0..8 |
| `micronode_chisel` cell | **1/16 node** | 16³ per node, already implemented |

With **1 Sauer cube = 1 Luanti node**, every Sauer vertex lands exactly on a
micronode boundary (even indices 2,4,…,16). So:

- axis-aligned Sauerbraten geometry converts **exactly**, with zero loss;
- individually dragged corners become 1/16 stair-steps (visually equivalent at
  that size);
- the result can be expressed as **one chiseled block per node**, reusing the
  existing mesher, the shape-aware collision (slabs/stairs/corners — exactly the
  vocabulary of Sauerbraten architecture) and the clipboard/stamping code.

This is the strongest argument for the whole feature: the port target already
exists and is tested.

---

## 4. Options

### Option A — Standalone reader + voxelizer (Python), emitting templates
Pure-Python `.ogz` parser (`gzip`, `struct`) → leaf list → voxelizer → writer.

| | |
|---|---|
| ✅ | Fully headless, CI-able, deterministic, no engine build, no GL |
| ✅ | Can emit our own template format (chiseled blocks + entity markers), which `.mts` cannot express |
| ✅ | Fast iteration; failures are debuggable in a debugger, not a game console |
| ⚠️ | Must re-implement the reader; the surface/lightmap block is fiddly to *skip* correctly |
| ⚠️ | Python performance: ~10⁶–10⁷ cells per region — fine with a box fast path, needs care otherwise |

### Option B — Lua importer inside Luanti
Read a `.ogz` at runtime in a mod, slice it, stamp it.

| | |
|---|---|
| ✅ | No extra toolchain; the mod can preview/stamp a region in-game |
| ❌ | **Verified blocker:** the Lua sandbox blocks reads outside the world/mod/mod_data dirs (`src/script/cpp_api/s_security.cpp:869-931`), and `secure.enable_security` is removed in favour of `--insecure-no-sandbox`. Maps would have to be copied under the world dir first |
| ❌ | gzip is not a supported `core.decompress` method (only `deflate`, `raw_deflate`, `zstd`) — the gzip header must be parsed by hand, then `raw_deflate`. Doable, but it is our own format plumbing |
| ❌ | Voxelizing 10⁶+ cells in Lua risks hitches; whole-map conversion is out of the question |

Verdict: **not the converter**; potentially a thin *consumer* later (templates →
worldgen), which does not need `.ogz` at all.

### Option C — Patch the Sauerbraten server to dump leaves (the oracle)
Add ~100 lines to `sauerbraten/src/engine` behind `STANDALONE`: walk `worldroot`,
write a flat dump (`origin, size, 12 edges, 6 textures, material`) or JSON.

| | |
|---|---|
| ✅ | Zero format-parsing risk: the engine's own loader produces the data |
| ✅ | Ideal as **ground truth** to validate Option A across the whole corpus |
| ⚠️ | Requires keeping a patched engine build around; not a CI dependency we want long-term |

Verdict: **build it as a test oracle**, not as the shipping path.

### Option D — Run the graphical client under xvfb and use `writeobj`
| | |
|---|---|
| ✅ | Uses the engine's own face extraction |
| ❌ | Needs X + working GL (llvmpipe), slow, flaky in CI, and OBJ loses the octree's exact lattice |
| ❌ | OBJ gives triangles, so we would voxelize a mesh — strictly harder than voxelizing leaves |

Verdict: reject, except as a one-off sanity check on a single map.

### Recommendation

**A as the converter of record, C as its oracle, B deferred.**

Rationale: the hard part is not "read bytes", it is *correctness of the
voxelization and the material/entity mapping*, and that is best developed and
regression-tested outside the engine. Option C removes the format risk precisely
where it matters (we can diff leaf-for-leaf against the engine), and Option A
produces an artifact the existing Lua mods can consume.

---

## 5. Conversion specification (Option A)

### 5.1 Pipeline

```
.ogz ──gzip──▶ header/vars/ents/vslots ──octree walk──▶ leaves
                                                          │
                     ┌────────────────────────────────────┘
                     ▼
        geometry: 8 corners @1/8 (hexahedron)
                     ▼
        voxelize → solid grid (dense, region-bounded)
                     ▼
        classify cells: air(outside) / air(inside=rooms) / solid(material)
                     ▼
        surface-only trim?  (optional; templates want shells + interiors)
                     ▼
        writer:  .mts (plain)  |  Lua schematic  |  .mntpl (chisel + markers)
```

### 5.2 Geometry

1. Leaf fast path: all spans ∈ {0,8} → plain box fill (`numpy` slice).
2. General case: build the 6 face planes from the 8 vertices, then for each
   cell **centre** in the leaf's bounding box test the 6 half-spaces
   (conservative: also fill cells whose centre is within ε of a plane).
3. Cells owned by overlapping leaves: last writer wins in *octree depth order*
   (deeper leaves are authored later, matching how Sauerbraten edits replace
   geometry).

### 5.3 Air semantics (important for dungeons)

Naive "empty cubes stay air" loses nothing, but we must distinguish:

- **exterior air** (connected to the world border) → keep empty so the dungeon
  can be entered from outside / so the template is not a sealed ball;
- **interior air** (a carved room sealed by walls) → **keep as air**: it *is*
  the dungeon;
- **liquid materials** (`MAT_WATER`, `MAT_LAVA`) → fill that cube's empty space
  with water/lava nodes;
- `MAT_CLIP`/`MAT_GAMECLIP` → optionally convert to a barrier node or drop;
- `MAT_DEATH` → lava or a damage node.

`MAT_GLASS` → glass node.

### 5.4 Coordinates and scale

- Axis swap: `(x, y, z)_sauer → (x, z, y)_luanti` (Z-up → Y-up). **Handedness
  must be verified with an asymmetric fixture** (a map with a known
  left/right asymmetry) — mirroring is the classic silent bug here.
- Default scale **1 cube = 1 node** (lossless; see §3).
- Optional integer scale factors (1:2, 2:1) implemented as grid resampling with
  majority-vote solidity — so gameplay tuning never requires re-converting.

### 5.5 Materials

- Rule table (config file, versioned): ordered regex rules on the texture path
  → Luanti node, plus material-bit overrides.
- Fallback chain: exact rule → keyword rule → `default:stone`, and the fallback
  count is reported per map so bad mappings are visible instead of silent.
- Output records *material classes*, never texture files.

### 5.6 Entities → template markers

| Sauerbraten | Template marker |
|---|---|
| `ET_LIGHT` | `marker:light` with attrs (radius/brightness in template metadata) |
| `ET_MAPMODEL` | `marker:prop` with model id + yaw (asset mapping is a separate decision) |
| `ET_PLAYERSTART` | `marker:spawn` |
| `ET_GAMESPECIFIC` (fpsgame: item/trigger/teleport/monster/elevation) | `marker:*` with the raw type+attrs, so the worldgen stage decides |
| `ET_ENVMAP`, `ET_PARTICLES`, `ET_SOUND`, `ET_SPOTLIGHT` | dropped in v1 |

### 5.7 Output formats

| Format | Carries | Use |
|---|---|---|
| `.mts` / Lua schematic | plain nodes only (**no metadata** — `mg_schematic.h:103` stores content ids only) | quick visual check, worldgen decorations |
| `.mntpl` (new, versioned) | node grid + optional 16³ chisel payload per node + entity markers + source hash | dungeons/structures, reuses `micronode_chisel` RLE |
| direct world write (optional) | nodes at an offset in an existing world | eyeballing a whole map in-game |

`.mntpl` v1 sketch (JSON header + RLE payloads, all integers):

```lua
{ version = 1, size = {x,y,z}, scale = 1,
  source = {map="abbey", region={...}, sha1="..."},
  nodes  = { rle = "...", palette = {"default:stone", ...} },  -- 1 entry/node
  chisels= { [flat_index] = { rle="...", palette={...} } },     -- optional
  markers= { {kind="spawn", pos={..}, yaw=90}, ... } }
```

---

## 6. Validation strategy (the part that makes this trustworthy)

1. **Stream integrity**: after parsing the octree, the read offset must equal the
   computed lightmap/PVS/blendmap size; and the whole file must be consumed.
   This alone catches almost every surface-block parsing bug.
2. **Oracle diff (Option C)**: leaf-for-leaf equality (origin, size, 12 edges,
   6 texture indices, material) on ≥5 maps. This is the acceptance gate for the
   reader.
3. **Volume conservation**: hexahedron volume summed over leaves vs voxel count,
   within a tolerance derived from the 1/16 stair-stepping.
4. **Watertightness**: no cell is solid with all 6 neighbours air *in the
   interior* (isolated speck), and the exterior flood fill must not leak into
   sealed rooms.
5. **Determinism**: same input ⇒ byte-identical `.mntpl` (hash in the manifest).
6. **In-engine acceptance**: load a converted template and reuse the existing
   `micronode_chisel` suites — every solid node must get a recognised collision
   shape, the mesher's no-coplanar-quads invariant must hold, and no block may
   render zero faces. This is a genuinely strong signal that the geometry is
   sane, and it costs us almost nothing.

---

## 7. Milestones

| # | Deliverable | Est. | Gate |
|---|---|---|---|
| M0 | `tools/ogz/` reader: header, vars, ents, texmru, octree; `dump` command; patched-server oracle (Option C) | 2–3 d | oracle diff passes on 5 maps; stream integrity holds on all ~100 maps |
| M1 | Voxelizer with box fast path; axis swap; `.mts`/Lua-schematic writer; ASCII/PNG slice preview | 2–3 d | a converted `box_demo`-like fixture is walkable in-game at 1:1 |
| M2 | General hexahedron rasterizer + slanted-corner fixture; material rules; liquids/clip/death; exterior vs interior air | 3–4 d | fixture with a dragged corner converts with correct silhouette; fallback-material report per map |
| M3 | `.mntpl` writer (node grid + 16³ chisel payloads) + Lua loader + `register_schematic`/stamping | 3–4 d | converted block passes the chisel collision/mesher acceptance checks (§6.6) |
| M4 | Structure extraction: region selection, room detection (flood fill), entity markers | 2–3 d | a hand-built 32³ room extracts as a template and re-stamps identically |
| M5 | Wire into M4 worldgen as a template source; docs; CI job | 2–3 d | CI converts the fixtures on every commit and diffs the hashes |

**Total ≈ 2–3 weeks** of focused work, dominated by M2 (general rasterizer) and
M3 (template + in-engine acceptance).

---

## 7a. M0 progress and measured findings

Answers to §8 taken as decisions: **1:1 scale**, **~10³ region proof of concept
first**, **patched server acceptable as a test-only oracle**.

### Implemented

| Artifact | What it is |
|---|---|
| `tools/ogz/ogz.lua` | The reader: gzip framing, header, vars, game ident, texture MRU, entities, vslots, octree (v29–v33 layouts), lightmap/PVS/blendmap skip, leaf corner decode, region filter. Plain Lua 5.1 (no `bit`, no `//`, no `goto`) so it runs in-engine, under lupa, and in a stock interpreter |
| `tools/ogz/selftest.lua` | Synthetic fixtures for **every supported version** (29–33) plus the real-map corpus layer |
| `tools/ogz/compare.lua` | Oracle comparator: diffs an engine octree dump against our leaves |
| `tools/ogz/corpus.txt` | The acceptance corpus (map names under `sauerbraten/packages/base`) |
| `tools/ogz/world.mt` + `worldmods/ogz_selftest/` | Runs the synthetic layer in-engine |
| `world.mt` + `worldmods/ogz_dev/` (repo root) | Runs the **corpus** in-engine; the world directory is the repo root because the sandbox only allows reads under world/mod/game/mod_data |
| `tools/ogz/oracle/` | Option C patch + procedure (see below) |

Version policy: **v33 is the target**; v32 and v31 were cheap (a one-byte vs
two-byte material, and a fixed-size legacy surface block) and buy 130 extra
corpus maps, so v29–v33 are supported. Anything older is rejected with an
explicit message rather than guessed at.

Two engine facts that make this runnable, both expensive to rediscover:

* **The Lua sandbox forbids reading outside world/mod/game/mod_data**
  (`src/script/cpp_api/s_security.cpp:869-931`) and a mod cannot set `secure.*`
  (`l_settings.cpp:39`). The way in is to make the *world directory* contain the
  files you want to read. No `secure.trusted_mods`, no `--insecure-no-sandbox`.
* `core.decompress` has no gzip method, so `M.gunzip` parses the RFC 1952
  framing and delegates only raw inflate (`opts.inflate_raw`); in-engine that is
  `core.decompress(bytes, "raw_deflate")`.

### Verified

* **Corpus: 171 of 171 supported maps parse with exact byte accounting and every
  leaf inside the world; 34 pre-v29 maps skipped; 0 failures.**
  That is 5,000,000+ leaves across the shipped map set.
* Synthetic fixtures for v29, v30, v31, v32, v33: all pass, including the
  constructs that real maps rarely exercise (`CHILDREN`, `LODCUBE`, the legacy
  surface block with its self-growing record count, material/liquid decode).

### Bugs the tests caught (all fixed)

| Symptom | Cause |
|---|---|
| Pre-v29 maps "unknown var" | The header's `numvslots` field does not exist before v30 |
| Desync right after the game ident | The engine reads **two** `u16`s (`eif` *and* `extrasize`), not one |
| Leaves far outside the world (`x` up to 6× worldsize) while the byte count still matched | `CHILDREN` nodes were read with the parent's size; the engine gives children **half** the size. `stream_complete` alone could never catch this - the in-bounds assertion did |
| `aard3c`, `aqueducts` desync | `normalscompat` is `bvec[4]` and `bvec` is **3 bytes** (`geom.h:1273`), so 12 bytes, not the 4 I assumed |
| Region filter kept everything | Bounds documented inclusive but compared half-open |

### Oracle (Option C): written, not yet executed

`tools/ogz/oracle/` holds the patch and procedure. One finding changed the
design: **`load_world` is client-only** (`worldio.cpp:172-1387` wraps it in
`#ifndef STANDALONE`, and only `fpsgame/client.cpp` and `rpggame/rpg.cpp` call
it), so the dedicated server never loads the octree at all. The oracle must
therefore be a client build with a dump hook, run under a display (or xvfb) -
a manual, test-only check rather than a CI dependency.

This session had no shell and no display, so it was not built. The comparator
itself *is* verified: `compare.lua` reproduces our leaves in the engine's dump
format, asserts identity (0 differences) and asserts that a single corrupt edge
byte is reported.

Why it still matters despite a clean corpus: byte accounting cannot catch a
*wrong but consistent* mapping (e.g. a transposed axis). A leaf-for-leaf diff
against the engine pins the octant walk, child-size rule, corner decode inputs
and material decode at once - which is exactly what M1's voxelizer will depend
on.

---

## 8. Risks and open questions

| Risk / question | Impact | Mitigation / decision needed |
|---|---|---|
| Surface/lightmap block parsing | Wrong geometry or desync | M0 stream-integrity check + oracle diff; skip by length only after the surface block is parsed |
| Handedness of the axis swap | Mirrored maps (subtle, easy to miss) | Asymmetric fixture with a known "left" wall |
| **Player-relative scale** | Sauerbraten's player is ~15 cubes tall (`shared/ents.h:84-86`); Luanti's is ~1.75 nodes. At 1:1 a Sauer corridor is ~8× too tall | Convert at 1:1 (lossless) and treat scale as a *consumer* setting; look at one converted room before committing. Alternative: 1:2 conversion, half the detail |
| Slanted faces | 1/16 stair-steps | Accepted; measure the volume deviation on a slanted fixture |
| Region size | A 1024³ map is 1.07 × 10⁹ cells | Region-bounded conversion + region discovery; never convert a whole map by default |
| Texture → material mapping | Ugly or wrong materials | Rule table + explicit unmapped report; majority-vote material for merged faces |
| Licensing | Cannot ship most ported maps | Fixtures authored by us; per-map permission before any third-party map ships |
| `.mntpl` becomes a second serialization format | Maintenance | Version it from day one and keep payloads in the chisel's existing RLE |
| Rounding of `worldsize` not a power of two | Octree assumptions | Read `worldsize` from the header and require a power of two, failing loudly |

**Decisions I need from you before M1:**
1. Is 1:1 (1 cube = 1 node, oversized architecture) the starting point, or do
   you want the 1:2 compromise from the start?
   1:1 with oversized architecture is good.
2. Do we convert *whole maps* for exploration (slow, big) or go region-first
   (recommended) and only add whole-map export later?
   A proof of concept region (like 10m³) first before doing whole maps.
3. Is a patched Sauerbraten server build acceptable as a *test-only* oracle
   (not shipped, not a CI dependency), or should correctness rest on my own
   fixture maps only?
   A patched server is fine as test-only.

---

## 9. Non-goals for v1

- Textures, models, sounds, lightmaps, PVS, BSP — geometry and markers only.
- Runtime streaming/loading of `.ogz` on a live server.
- Faithful per-face texturing of ported geometry.
- Importing Sauerbraten *game logic* (items, monsters, rules).
