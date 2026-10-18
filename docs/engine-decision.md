# Engine Decision Record — Phase 0

**Date:** 2026-10-18
**Project:** Freeform-Editing Multiplayer Game
**Decision:** Engine selection for fork-and-extend development

---

## Candidates Evaluated

| Candidate | Version | License (code) | Status |
|-----------|---------|----------------|--------|
| **Luanti** (formerly Minetest) | 5.18.0-dev | LGPL-2.1+ | ✅ Spike completed |
| **Cube 2: Sauerbraten** | Collection Edition | zlib | ✅ Code analysis completed |
| Veloren | — | GPL-3.0 | ⏭️ Not evaluated (eliminated: no editing, MMO-scale) |
| Godot + voxel modules | — | MIT | ⏭️ Not evaluated (eliminated: too much work) |

---

## Scoring Matrix (§2.1 Criteria)

Weights: 1 (highest) → 7 (lowest)
Scores: 1-5 (5 = best)

| # | Criterion | Weight | Luanti | Sauerbraten | Notes |
|---|-----------|--------|--------|-------------|-------|
| 1 | **Freeform geometry fidelity** | High | **3** | **5** | Luanti: voxel grid, approximated. Sauerbraten: native octree, exact. |
| 2 | **Multiplayer maturity** | High | **5** | **4** | Luanti: mature, 2-32 players, chunk streaming. Sauerbraten: Coop Edit exists but aging. |
| 3 | **Worldgen & procedurality** | High | **5** | **1** | Luanti: full mapgen API, infinite world. Sauerbraten: none, finite maps. |
| 4 | **Entity/AI support** | Medium | **4** | **4** | Luanti: Lua entities, pathfinding. Sauerbraten: C++ monsters, DMSP mode. |
| 5 | **Extensibility** | Medium | **5** | **3** | Luanti: Lua mods, fast iteration. Sauerbraten: C++ only, aging codebase. |
| 6 | **Asset licensing** | Medium | **5** | **2** | Luanti: free assets. Sauerbraten: non-free media, must recreate all. |
| 7 | **Project health** | Low | **5** | **3** | Luanti: very active. Sauerbraten: low activity, aging. |

### Weighted Scores

| Candidate | Raw Score | Weighted Score* | Rank |
|-----------|-----------|-----------------|------|
| **Luanti** | 30/35 | **4.57** | **1** |
| **Sauerbraten** | 22/35 | **3.14** | 2 |

*Weighted by criteria priority (1=highest weight)

---

## Spike Results Summary

### Luanti Spike (✅ Completed)

**Deliverable:** `luanti/games/devtest/mods/freeform_edit/` — Pure Lua mod, no engine changes

| Metric | Result | Target | Status |
|--------|--------|--------|--------|
| 16³ edit latency | **0.17 ms** median | < 16.67 ms (1 tick) | ✅ **98x headroom** |
| 16³ edit p95 | 0.18 ms | < 16.67 ms | ✅ 92x headroom |
| VoxelManip vs bulk_set_node | 1.20 ms vs 0.99 ms | Comparable | ✅ Comparable |
| Grid snapping (1,2,4,8,16) | Works | Required | ✅ Pass |
| Undo system | 10 levels | ≥10 levels | ✅ Pass |
| Worldgen template injection | Works | Required | ✅ Pass |
| Tests passed | **8/8** | All pass | ✅ 100% |

**Key Achievements:**
- Proved brush-based editing is **feasible** as a gameplay mechanic
- Proved **VoxelManip performance** is excellent (98x under budget)
- Proved **worldgen template injection** works
- **Zero engine modifications** required for the spike
- **Fast iteration**: Pure Lua, no compilation

### Sauerbraten Spike (⚠️ Code Analysis Only)

**Deliverable:** `docs/spike-results/sauerbraten-spike.md` — Code analysis

**Limitation:** No display available for graphical client testing. Analysis based on source code review.

| Metric | Result | Target | Status |
|--------|--------|--------|--------|
| Native octree editing | ✅ Exists | Exact mechanic | ✅ Best fidelity |
| Grid snapping (1-4096) | ✅ 13 sizes | 1,2,4,8,16 | ✅ Exceeds |
| Coop Edit | ✅ Built-in | Multiplayer editing | ✅ Native |
| Network efficiency | ✅ ~40 bytes/edit | Efficient | ✅ Excellent |
| Undo system | ✅ Memory-bounded | ≥10 levels | ✅ Pass |
| Worldgen | ❌ None | Required | ❌ **Must build** |
| Infinite world | ❌ Finite maps | Required | ❌ **Must build** |
| Asset licensing | ❌ Non-free media | Free preferred | ❌ Must recreate |

**Key Findings:**
- **Best editing fidelity** (native octree, per-corner dragging, per-face textures)
- **Coop Edit** is fully implemented and efficient
- **No worldgen** — would require 4-6 weeks of engine work
- **Aging C++ codebase** — harder to extend
- **Non-free assets** — must recreate everything

---

## Decision

### 🏆 **Recommended: Luanti**

**Rationale:**

1. **Fastest path to MVP**: Pure Lua modding, no engine compilation, 8/8 spike tests passed
2. **Performance proven**: 98x headroom on the critical 16³ edit benchmark
3. **Worldgen native**: Full procedural generation, infinite world, template injection works
4. **Multiplayer mature**: Built for 2-32 players, chunk streaming, lag-tolerant
5. **Free assets**: No licensing issues
6. **Active project**: Regular updates, large community, good docs
7. **Extensibility**: Lua for gameplay, C++ for engine changes if needed

**Trade-offs accepted:**
- Voxel grid instead of octree (approximated freeform editing)
- No per-corner vertex dragging (acceptable per goal.md §1)
- Uniform 1-node resolution (mitigated by grid-step brushing)

### Sauerbraten (Runner-up)

**When to choose Sauerbraten instead:**
- If **editing fidelity** is the absolute top priority
- If the project scope is **finite maps** (no infinite world needed)
- If willing to invest **4-6 weeks** in engine work for worldgen
- If willing to **recreate all assets**

**Sauerbraten advantages:**
- Native octree editing (exact target mechanic)
- Per-corner vertex dragging
- Per-face texturing
- Efficient Coop Edit networking

---

## Implementation Plan (Luanti)

### Phase 0: ✅ Complete
- [x] Engine spike & benchmarks
- [x] Decision record

### M1 — Freeform Editing MVP (2-3 weeks)
- [ ] Implement copy/paste with 90° rotation (E4)
- [ ] Add selection visualization (HUD overlay)
- [ ] Polish brush tool UX (5-minute learnability test)
- [ ] Unit test suite (pure Lua logic)
- [ ] Headless test harness

### M2 — Multiplayer + Co-op Editing (2-3 weeks)
- [ ] Co-op editing conflict resolution (last-write-wins)
- [ ] Selection visibility (see others' selections)
- [ ] Server-side edit validation (E7)
- [ ] Protected areas
- [ ] Integration tests (headless server)

### M3 — Combat & Monsters (3-4 weeks)
- [ ] 3-5 monster archetypes (Lua entities)
- [ ] Spawn system (volume/proximity triggers)
- [ ] Combat (hitscan/projectile, health/damage)
- [ ] MP scaling (HP/drops by player count)
- [ ] E2E bot-client tests

### M4 — Template Editor + Worldgen (3-4 weeks)
- [ ] Template editor mode (separate from gameplay editmode)
- [ ] Template serialization (versioned, shareable)
- [ ] Worldgen pattern rules (biome/height/density)
- [ ] At least one complete dungeon pattern
- [ ] Nesting (rooms → corridors → dungeons)

### M5 — Integration Pass (2-3 weeks)
- [ ] Full loop tuning (explore → fight → loot → build)
- [ ] Anti-grief hardening
- [ ] Performance optimization
- [ ] CI as merge gate

**Total estimated time to M5:** 12-17 weeks

---

## Appendix: Spike Artifacts

| Artifact | Path |
|----------|------|
| Luanti mod | `luanti/games/devtest/mods/freeform_edit/` |
| Luanti spike results | `docs/spike-results/luanti-spike.md` |
| Sauerbraten spike results | `docs/spike-results/sauerbraten-spike.md` |
| Server config | `luanti/spike-test.conf` |
| Test world | `luanti/worlds/test_spike/` |

---

## Sign-off

**Decision:** Luanti selected as the engine for fork-and-extend development.

**Next action:** Proceed to M1 — Freeform Editing MVP.

**Date:** 2026-10-18
