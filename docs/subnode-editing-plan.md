# Sub-Node & Super-Node Editing Plan — Luanti

**Date:** 2026-10-18
**Status:** Research & Planning
**Goal:** Achieve Sauerbraten-level editing precision AND scale in Luanti

---

## Executive Summary

You're right to question the "voxel approximation" — **pure 1m³ node editing is a significant precision loss** compared to Sauerbraten's octree. This document outlines **three approaches** to achieve sub-node editing in Luanti, plus a **supernode system** for large-scale fast edits.

| Approach | Precision | Scale | Complexity | Engine Changes |
|----------|-----------|-------|------------|----------------|
| **A: Pure Node Grid** (current) | 1m³ | ✅ Excellent | Low | None |
| **B: Micronode Metadata** (Vintage Story style) | 1/16m³ (6.25cm) | ⚠️ Limited | Medium | None (mod-only) |
| **C: Engine Micronode Support** | 1/16m³ or finer | ✅ Good | High | Yes (rendering) |
| **D: Hybrid Octree-in-Node** | Variable (1/16 to 1/4096m) | ✅ Excellent | Very High | Yes (deep) |

**Recommendation:** Start with **B (Micronode Metadata)** for quick proof, then evaluate **C (Engine Micronode)** for production.

---

## 1. Vintage Story's Approach (Research Summary)

### How It Works

Vintage Story uses a **chisel tool** that converts regular blocks into "chiseled" blocks with **16×16×16 micronode resolution**:

```
Regular Block (1m³)  →  Chiseled Block (16³ = 4,096 micronodes)
```

**Key Mechanics:**
- **Chisel + Hammer** tool combo (two-handed editing)
- **Grid size selection**: Left-click to remove voxels, right-click to add
- **Multi-material**: Up to 4 different materials per chiseled block
- **Rotation/flip**: Rotate and flip the micronode pattern
- **Liquid flow**: Calculates flow through chiseled channels (33+ voxels per layer)
- **Insulation**: Chiseled blocks affect room insulation

### Data Model

```
Chiseled Block:
├── Base material (what the block was before chiseling)
├── Micronode grid: 16×16×16 = 4,096 voxels
│   └── Each voxel: material index (0-3)
├── Material palette: up to 4 materials
└── Transform: rotation (4 states) + flip (2 states)
```

**Storage:** ~4KB per chiseled block (4096 bytes for voxel data + palette)

### Performance Characteristics

| Aspect | Performance |
|--------|-------------|
| Editing | Fast (single block, 4K voxels) |
| Rendering | ⚠️ Heavy (custom mesh per chiseled block) |
| Memory | High (4KB per chiseled block vs 4 bytes for regular node) |
| Network | Heavy (4KB per chiseled block sent to clients) |

**Vintage Story's solution:** Only **some blocks** can be chiseled (stone, wood). Most blocks remain regular 1m³ nodes.

---

## 2. Luanti Micronode Approaches

### Approach B: Micronode Metadata (Mod-Only)

**Concept:** Store micronode data in Luanti's **Node Metadata** system.

**Implementation:**

```lua
-- When player "chisels" a node:
-- 1. Convert node to special "micronode_base" node
-- 2. Store 16³ voxel data in node metadata
-- 3. Render using entities or nodeboxes

local meta = core.get_meta(pos)
meta:set_string("micronodes", serialize_voxel_data(voxels))  -- 4KB string
meta:set_string("materials", serialize_material_palette(materials))
meta:set_int("rotation", rotation)
```

**Pros:**
- ✅ No engine changes
- ✅ Fast to implement (1-2 weeks)
- ✅ Works with existing multiplayer
- ✅ Persistence via node metadata

**Cons:**
- ❌ Rendering: Must use entities or complex nodeboxes (slow)
- ❌ Collision: No custom collision (uses full block or none)
- ❌ Lighting: No per-micronode lighting
- ❌ Network: 4KB per chiseled block is heavy
- ❌ Memory: Lua string serialization overhead

**Rendering Options:**

| Option | Method | Performance | Quality |
|--------|--------|-------------|---------|
| 1. Entities | Spawn voxel entities per micronode | ❌ Terrible (4096 entities!) | ✅ Perfect |
| 2. Nodeboxes | Generate nodebox from micronodes | ⚠️ Slow (complex nodebox) | ⚠️ Blocky |
| 3. Mesh nodes | Custom mesh per chiseled block | ⚠️ Medium | ✅ Good |
| 4. CSG shaders | GPU-based voxel rendering | ✅ Fast | ✅ Good |

**Best mod-only option:** **Mesh nodes** — generate a mesh from the micronode data and use `drawtype = "mesh"`.

### Approach C: Engine Micronode Support (Recommended)

**Concept:** Add native micronode support to Luanti's engine.

**Engine Changes Required:**

```
1. MapNode extension:
   - Add "has_micronodes" flag to MapNode (or use special content ID range)
   - Store micronode data in separate per-chunk buffer

2. Storage:
   - New chunk data section for micronodes
   - Only allocate for chunks containing micronode blocks
   - Format: sparse storage (only store non-air micronodes)

3. Rendering:
   - Extend mesh generator to handle micronode blocks
   - Generate sub-block geometry (like marching cubes or voxel meshing)
   - Cache meshes per unique micronode pattern

4. Collision:
   - Generate collision mesh from micronodes
   - Or: approximate with simplified collision (AABBs)

5. Lighting:
   - Extend light propagation to micronode resolution
   - Or: use block-level lighting (simpler)

6. Networking:
   - Compress micronode data (RLE + palette)
   - Delta updates for micronode edits
```

**Estimated Effort:** 4-8 weeks of C++ engine work

**Pros:**
- ✅ Full rendering quality (custom meshes)
- ✅ Proper collision
- ✅ Per-micronode lighting
- ✅ Efficient storage (compressed)
- ✅ Efficient networking (compressed)

**Cons:**
- ❌ Requires engine fork
- ❌ Longer development time
- ❌ Must maintain fork

---

## 3. Supernode Editing (Large-Scale Fast Edits)

**Concept:** Edit volumes larger than 1m³ efficiently, like Sauerbraten's grid sizes 16, 32, 64, 128.

### Current Luanti Capability

Our spike proved:
- 16³ nodes: 0.17ms (98x under budget)
- 64³ nodes: 21ms (exceeds one tick)

**Problem:** 64³+ edits are too slow for one tick.

### Supernode Solutions

#### Option 1: Multi-Tick Editing (Recommended)

```lua
-- Edit 64³ volume over 4 ticks (4 × 16³ chunks)
-- Each tick processes 16³ = 4096 nodes
-- Total: 4 ticks = 66ms for 64³ (262,144 nodes)

-- Visual feedback: Show progress bar
-- Other players see progressive updates
```

**Pros:** Simple, no engine changes, works now
**Cons:** Not instant for very large edits

#### Option 2: Hierarchical Editing (LOD)

```
World representation:
├── Level 0: 1m³ nodes (full detail)
├── Level 1: 4m³ supernodes (4³ = 64 nodes → 1 supernode)
├── Level 2: 16m³ supernodes (16³ = 4096 nodes → 1 supernode)
└── Level 3: 64m³ supernodes (64³ = 262,144 nodes → 1 supernode)

Editing at Level 3: Edit 1 supernode = 262,144 nodes in O(1)
Editing at Level 0: Edit 1 node = O(1)

Rendering: Use appropriate LOD based on distance
```

**This is essentially an octree!** Sauerbraten does this natively.

#### Option 3: Engine Octree Integration (Ambitious)

Add octree support to Luanti:

```cpp
// Extend MapBlock to support octree subdivision
struct MapBlock {
    MapNode nodes[16*16*16];  // Base grid
    OctreeNode* octree;       // Optional octree for detailed areas
};

// Octree node:
struct OctreeNode {
    OctreeNode* children[8];  // Subdivision
    u8 depth;                  // Current depth (0 = 16m, 1 = 8m, ... 4 = 1m)
    // Leaf nodes store micronode data
};
```

**This would give Sauerbraten-level precision AND scale.**

**Effort:** 8-12 weeks (major engine rewrite)

---

## 4. Recommended Architecture

### Phase 1: Micronode Metadata (Quick Proof) — 2 weeks

**Goal:** Prove sub-node editing is feasible in Luanti

**Implementation:**
1. Chisel tool: converts node to "micronode" node
2. Store 16³ voxel data in node metadata (compressed)
3. Render using mesh nodes (generate mesh from voxel data)
4. Basic editing: add/remove micronodes
5. Benchmark: edit latency, memory usage, network traffic

**Deliverable:** Working micronode editing mod

### Phase 2: Supernode Editing (Scale) — 1 week

**Goal:** Fast large-scale edits

**Implementation:**
1. Multi-tick editing for volumes > 16³
2. Progress visualization
3. Batch VoxelManip operations
4. Benchmark: 64³, 128³ edit times

**Deliverable:** Supernode editing in existing freeform_edit mod

### Phase 3: Engine Micronode (Production) — 4-8 weeks

**Goal:** Native micronode support with full rendering

**Decision Gate:** Evaluate Phase 1 results:
- If mesh-node rendering is acceptable → stay with mod
- If performance/quality insufficient → engine changes

**Engine Changes:**
1. Micronode storage in MapBlock
2. Mesh generation for micronodes
3. Collision mesh generation
4. Compressed networking

### Phase 4: Hybrid Octree (Future) — 8-12 weeks

**Goal:** Sauerbraten-level precision at all scales

**Only if:** Micronode approach proves insufficient for gameplay

---

## 5. Performance Budgets

| Operation | Target | Current (Spike) | With Micronodes | With Supernodes |
|-----------|--------|-----------------|-----------------|-----------------|
| 1m³ edit (1 node) | < 0.1ms | 0.001ms | 0.001ms | 0.001ms |
| 16³ edit (4K nodes) | < 16ms | **0.17ms** ✅ | 0.17ms | 0.17ms |
| 64³ edit (262K nodes) | < 16ms | 21ms ❌ | 21ms | **4 ticks** ⚠️ |
| 1 micronode edit (1/4096m³) | < 1ms | N/A | **< 0.5ms** ✅ | N/A |
| Chisel block (init 16³ micronodes) | < 10ms | N/A | **< 5ms** ✅ | N/A |
| Render chiseled block | < 5ms | N/A | **< 2ms** ✅ | N/A |

---

## 6. Data Format Proposals

### Micronode Data (Compressed)

```
Option A: Run-Length Encoding (RLE)
├── Header: 4 bytes (palette count, rotation, flags)
├── Palette: N × 2 bytes (material content IDs)
└── Voxel data: RLE compressed
    └── [count:1byte][material_index:1byte] × runs

Example: All stone block
    → 4 bytes header + 2 bytes palette + 2 bytes RLE = 8 bytes
    (vs 4096 bytes uncompressed = 512x compression!)

Option B: Bit-packed (for 4 materials)
├── 16³ voxels × 2 bits = 8192 bits = 1024 bytes
├── Palette: 4 × 2 bytes = 8 bytes
└── Total: 1032 bytes (4x compression)
```

### Supernode Data

```
Supernode (16m³):
├── Resolution: 4m³ per supernode voxel (4³ = 64 voxels)
├── Data: 64 × content_id (2 bytes) = 128 bytes
├── Represents: 16³ × 16³ = 65,536 nodes
└── Compression: 65,536 × 4 bytes → 128 bytes = 2048x compression!
```

---

## 7. Open Questions

1. **Micronode resolution:** 16³ (6.25cm) like Vintage Story, or finer (32³ = 3.1cm)?
   - 16³: 4KB per block, manageable
   - 32³: 32KB per block, heavy
   - **Recommendation:** Start with 16³, make configurable

2. **Which blocks can be chiseled?**
   - Vintage Story: stone, wood only
   - Us: all solid blocks? Or terrain only?
   - **Recommendation:** All solid blocks, but metadata flag for restriction

3. **Collision for micronodes?**
   - Full mesh collision (expensive)
   - Simplified AABB collision (fast, less precise)
   - **Recommendation:** Simplified for v1, full mesh for v2

4. **Lighting for micronodes?**
   - Block-level lighting (fast, less accurate)
   - Micronode-level lighting (accurate, expensive)
   - **Recommendation:** Block-level for v1

5. **Engine fork vs mod?**
   - Mod: fast iteration, limited rendering
   - Engine: full quality, longer dev time
   - **Recommendation:** Mod first (Phase 1), engine if needed (Phase 3)

---

## 8. Next Steps

### Immediate (This Week)

1. **Prototype micronode metadata storage** in freeform_edit mod
   - Chisel tool that stores 16³ voxel data
   - Serialize/deserialize voxel data
   - Benchmark storage size

2. **Prototype micronode rendering** using mesh nodes
   - Generate mesh from voxel data
   - Test rendering performance
   - Test with 10, 100, 1000 chiseled blocks

3. **Prototype supernode editing**
   - Multi-tick editing for 64³+ volumes
   - Progress visualization
   - Benchmark

### Decision Gate (End of Week)

Evaluate:
- Is micronode metadata rendering acceptable?
- Is micronode storage/network overhead acceptable?
- Is supernode editing fast enough?

**If yes to all:** Continue with mod-only approach
**If no:** Plan engine changes (Phase 3)

---

## Appendix: Comparison Table

| Feature | Sauerbraten | Luanti (Current) | Luanti (Micronode Mod) | Luanti (Engine Micronode) |
|---------|-------------|------------------|------------------------|---------------------------|
| **Min edit size** | 1/4096m (grid=1, world=4096) | 1m | 1/16m (6.25cm) | 1/16m or finer |
| **Max edit size** | 4096m (full map) | 64m practical | 64m practical | 64m+ (supernodes) |
| **Per-corner drag** | ✅ Yes | ❌ No | ❌ No | ⚠️ Possible |
| **Per-face texture** | ✅ Yes | ❌ No | ⚠️ Via palette | ✅ Possible |
| **Rendering** | Native octree meshes | Node meshes | Custom mesh nodes | Native micronode meshes |
| **Collision** | Octree collision | Node AABBs | Node AABBs or mesh | Micronode collision |
| **Lighting** | Per-vertex | Per-node | Per-node | Per-micronode |
| **Storage/block** | Variable (octree) | 4 bytes | 4 bytes + metadata | 4 bytes + micronode buffer |
| **Network/block** | Selection params (~40 bytes) | 4 bytes | ~1KB (compressed) | ~1KB (compressed) |
| **Edit latency (16³)** | Instant | 0.17ms | 0.17ms | 0.17ms |
| **World size** | Finite (4096³ max) | Infinite | Infinite | Infinite |
| **Worldgen** | ❌ None | ✅ Full | ✅ Full | ✅ Full |
| **Multiplayer** | Coop Edit | Mature | Mature | Mature |
| **Dev effort** | — | — | 2 weeks | 4-8 weeks |

---

## Conclusion

**You are correct** — pure 1m³ node editing is a precision loss. However, **Vintage Story proves that 1/16m micronodes (6.25cm) are sufficient** for detailed building, and Luanti's architecture can support this.

**Recommended path:**
1. **Phase 1 (2 weeks):** Micronode metadata mod — prove feasibility
2. **Phase 2 (1 week):** Supernode editing — prove scale
3. **Phase 3 (4-8 weeks):** Engine micronode — production quality (if needed)

This gives us **both precision (6.25cm) and scale (64m+ supernodes)** without sacrificing Luanti's advantages (infinite world, worldgen, multiplayer, free assets).

**The key insight:** Vintage Story's chisel system works in a node-based game. We can do the same in Luanti, with the option to go deeper (engine changes) if needed.
