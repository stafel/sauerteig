# Sauerbraten (Cube 2) Spike Results — Phase 0

**Date:** 2026-10-18
**Engine:** Cube 2: Sauerbraten (Collection Edition)
**Source:** `sauerbraten/src/`

---

## Summary

Sauerbraten provides **native octree editing** that exactly matches the target mechanic. However, the spike was limited to **code analysis** because:

1. No display available for graphical client testing
2. No built-in headless test framework
3. Editing is tightly coupled to the rendering loop

**Key Finding:** Sauerbraten has the **best editing fidelity** but requires **significant engine work** for worldgen, infinite worlds, and modern multiplayer features.

---

## Build Status

| Component | Status | Binary |
|-----------|--------|--------|
| Server | ✅ Built | `sauerbraten/src/sauer_server` (569K) |
| Client | ✅ Built | `sauerbraten/src/sauer_client` (3.4M) |
| Master | ⏳ Not built | — |

---

## Native Editing Mechanics (Code Analysis)

### Octree Structure

**File:** `engine/octa.h`

```cpp
struct cube
{
    cube *children;          // 8 children (octree), or NULL for leaf
    union
    {
        uchar edges[12];     // edge deformations (4 bits per edge)
        uint faces[3];       // packed edge data
    };
    ushort texture[6];       // per-face texture indices
    ushort material;         // volumetric material (lava, water, etc.)
};
```

**Key Properties:**
- **True octree**: Cubes subdivide into 8 children recursively
- **Per-face textures**: 6 texture slots per cube
- **Edge deformation**: 12 edges with 4-bit height values (per-corner dragging!)
- **Materials**: Volumetric materials (water, lava, glass, etc.)

### Editing Operations

**File:** `engine/octaedit.cpp` (2,849 lines)

| Operation | Function | Network Message |
|-----------|----------|-----------------|
| Select | `updateselection()` | — |
| Push/pull face | `mpeditface(dir, mode, sel, local)` | `N_EDITF + EDIT_FACE` |
| Delete cube | `mpdelcube(sel, local)` | `N_EDITF + EDIT_DELCUBE` |
| Texture | `mpedittex()` | `N_EDITT` |
| Material | `mpeditmat()` | `N_EDITM` |
| Copy | `copy()` | `N_COPY` |
| Paste | `paste()` | `N_PASTE` |
| Flip | `flip()` | `N_FLIP` |
| Rotate | `rotate()` | `N_ROTATE` |
| Replace | `replace()` | `N_REPLACE` |
| Undo | `undo()` | `N_UNDO` |
| Redo | `redo()` | `N_REDO` |

### Grid System

**File:** `engine/octaedit.cpp:127-131`

```cpp
VARF(gridpower, 0, 3, 12,   // gridpower: 0-12
    if(dragging) return;
    gridsize = 1<<gridpower;  // gridsize: 1, 2, 4, 8, ..., 4096
    if(gridsize>=worldsize) gridsize = worldsize/2;
    cancelsel();
);
```

**Grid sizes:** 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096

This **exactly matches** requirement E1 (grid steps 1→2→4→8→16→1).

### Selection System

**File:** `engine/octaedit.cpp:93-94`

```cpp
selinfo sel, lastsel, savedsel;
```

```cpp
struct selinfo
{
    ivec o;      // origin
    ivec s;      // size (in grid units)
    int grid;    // grid size
    int orient;  // face orientation
    int cx, cxs, cy, cys;  // corner selection
    int corner;
};
```

### Undo System

**File:** `engine/octaedit.cpp:670-709`

```cpp
struct undolist
{
    undoblock *first, *last;
    // ...
};
undolist undos, redos;
```

**Bounded by:** `VARP(undomegs, 0, 5, 100)` — default 5 MB, max 100 MB

**Requirement E4:** "Per-player undo ≥10 levels" — ✅ **Native support** (configurable memory limit)

---

## Multiplayer / Coop Edit

### Implementation

**File:** `fpsgame/client.cpp`

```cpp
// Line 253-255: Coop edit check
if(isconnected() && multiplayer(false) && !m_edit)
{
    conoutf(CON_ERROR, "editing in multiplayer requires coop edit mode (1)");
    return false;
}
```

**Mode variable:** `m_edit` — enables cooperative editing mode

### Network Protocol

**File:** `fpsgame/client.cpp:633-712`

Edits are sent as **selection parameters + operation**, not cube data:

```cpp
// Example: Face edit
addmsg(N_EDITF + op, "ri9i6",
    sel.o.x, sel.o.y, sel.o.z,    // origin
    sel.s.x, sel.s.y, sel.s.z,    // size
    sel.grid, sel.orient,         // grid + orientation
    sel.cx, sel.cxs, sel.cy, sel.cys, sel.corner,  // corner selection
    arg1, arg2);                   // operation args
```

**Server relay:** `fpsgame/server.cpp:1515`

```cpp
msgfilter(-1, N_CONNECT, ..., N_EDITF, N_EDITT, N_EDITM, N_FLIP, N_COPY,
          N_PASTE, N_ROTATE, N_REPLACE, N_DELCUBE, N_EDITVAR, N_EDITVSLOT,
          N_UNDO, N_REDO, ...)
```

**Key Insight:** Each client applies edits **locally** based on selection parameters. This is **extremely efficient** — no cube data is transmitted!

### Message Types (game.h:229)

```cpp
N_EDITMODE, N_EDITENT, N_EDITF, N_EDITT, N_EDITM, N_FLIP, N_COPY,
N_PASTE, N_ROTATE, N_REPLACE, N_DELCUBE, N_REMIP, N_EDITVSLOT,
N_UNDO, N_REDO, N_NEWMAP, N_GETMAP, N_SENDMAP, N_CLIPBOARD, N_EDITVAR,
```

---

## World Persistence

**File:** `engine/worldio.cpp`

| Function | Purpose |
|----------|---------|
| `save_world(const char *mname, bool nolms)` | Save map to file |
| `load_world(const char *mname, const char *cname)` | Load map from file |
| `savevslots(stream *f, int numvslots)` | Save texture slots |
| `loadvslots(stream *f, int numvslots)` | Load texture slots |

**Format:** Binary `.ogz` (gzipped octree) or `.mpz` (zip archive)

**Requirement E5:** "Edits are ordinary world data — persisted with the world" — ✅ **Native support**

---

## World Generation

**Finding:** ❌ **No procedural world generation**

Sauerbraten maps are:
- **Finite size** (default 1024×1024×1024, configurable)
- **Hand-authored** or created with `newmap` command
- **No chunk streaming** — entire map loaded into memory
- **No biome system**
- **No structure placement API**

**File:** `engine/world.cpp:7`

```cpp
VARNR(mapsize, worldsize, 1, 0, 0);  // worldsize set at map creation
```

**Requirement §6 (Worldgen & Dungeon Templates):** ❌ **Not supported natively**

**Workaround:** Would require significant engine modification:
1. Implement chunk-based world streaming
2. Add mapgen hooks (noise-based terrain)
3. Add structure placement API
4. Implement infinite/persistent world

**Estimated effort:** 2-4 weeks of C++ engine work

---

## Entity / Monster System

**File:** `fpsgame/monster.cpp`, `fpsgame/ai.cpp`

| Feature | Status |
|---------|--------|
| Monster AI | ✅ Exists (single-player) |
| Pathfinding | ✅ Waypoint-based (A-grid) |
| Combat | ✅ Hitscan + projectiles |
| Health/damage | ✅ Full system |
| Multiplayer monsters | ⚠️ DMSP mode exists but limited |

**DMSP (Monster Invasion):** `fpsgame/` — wave-based monster spawning

**Requirement §5:** ⚠️ **Partially met** — exists but tuned for SP, needs MP rework

---

## Performance Analysis

### Editing Performance (Estimated)

Based on code analysis:

| Operation | Complexity | Notes |
|-----------|------------|-------|
| `mpeditface` | O(n) where n = cubes in selection | Iterates with `loopselxyz` |
| `mpdelcube` | O(n) | Same iteration |
| Network send | O(1) | Only selection params sent |
| Undo save | O(n) | Copies cube data |

**Estimated 16³ edit:** ~4,096 cubes max (at grid=1)

**Network efficiency:** ⭐⭐⭐⭐⭐ Excellent — only ~40 bytes per edit message

**Local edit speed:** ⭐⭐⭐⭐⭐ Excellent — direct octree manipulation, no per-cube allocation

---

## Licensing

| Component | License | Notes |
|-----------|---------|-------|
| Engine code | **zlib** | ✅ Permissive, can fork/modify |
| Media (textures, models, sounds) | **Non-free** (CC-NC-SA) | ❌ Must recreate all assets |

**Requirement §2.1.6:** ⚠️ **Asset recreation required** — user confirmed willingness

---

## Code Quality Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Editing code | ⭐⭐⭐⭐⭐ | Mature, well-tested, 2,849 lines |
| Networking | ⭐⭐⭐⭐⭐ | Efficient protocol, Coop Edit built-in |
| Code style | ⭐⭐⭐☆☆ | Aging C++ (C++03 era), macros, globals |
| Documentation | ⭐⭐⭐☆☆ | Editing docs exist, engine docs sparse |
| Build system | ⭐⭐⭐☆☆ | Simple Makefile, no CMake |
| Testing | ⭐⭐☆☆☆ | No automated tests |

---

## Risks & Limitations

| Issue | Severity | Impact |
|-------|----------|--------|
| No worldgen/procgen | **High** | Must build from scratch (~2-4 weeks) |
| No infinite world | **High** | Must implement chunk streaming |
| Finite map size | Medium | Limits world scale |
| Aging C++ codebase | Medium | Harder to maintain, no modern features |
| Non-free assets | Medium | Must recreate all art/audio |
| No automated tests | Medium | Harder to verify changes |
| Tight render/edit coupling | Medium | Hard to make headless/testable |

---

## What Would Need to Be Built

If Sauerbraten is chosen, the following **must** be implemented:

1. **Chunk-based world streaming** (replace finite map)
   - Load/unload octree chunks on demand
   - Persist chunks to disk
   - Estimated: 1-2 weeks

2. **Procedural world generation**
   - Noise-based terrain (Perlin/simplex)
   - Biome system
   - Structure placement hooks
   - Estimated: 1-2 weeks

3. **Template system**
   - Save/load bounded regions (like prefabs)
   - Stamp into world during gen
   - Estimated: 3-5 days

4. **Modernize multiplayer**
   - Lag compensation improvements
   - Edit conflict resolution (last-write-wins)
   - Estimated: 3-5 days

5. **Asset recreation**
   - All textures, models, sounds
   - Estimated: Ongoing (art pipeline)

**Total estimated engine work:** 4-6 weeks before gameplay features

---

## Conclusion

**Sauerbraten offers the best editing fidelity** (native octree, per-corner dragging, per-face textures) but requires **significant engine work** for worldgen and infinite worlds.

**Strengths:**
- ✅ Native octree editing (exact target mechanic)
- ✅ Coop Edit built-in (multiplayer editing)
- ✅ Efficient network protocol
- ✅ Full undo/redo, copy/paste, rotate
- ✅ Monster AI and combat exist

**Weaknesses:**
- ❌ No procedural world generation
- ❌ No infinite/chunked world
- ❌ Aging C++ codebase
- ❌ Non-free assets (must recreate)
- ❌ No automated testing
- ❌ Tight render/edit coupling (hard to test headless)

**Verdict:** Viable but **high-effort** for worldgen features. Best if the project scope prioritizes editing fidelity over procedural generation.
