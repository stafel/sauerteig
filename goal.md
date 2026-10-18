# Freeform-Editing Multiplayer Game — Requirements

**One-liner:** A multiplayer action-sandbox game where the core gameplay loop is Sauerbraten-style freeform world editing (select, push/pull, grid-resolve) — as a *player mechanic*, not a dev tool — combined with Minecraft-like block-game worldbuilding, basic monsters and dungeons à la Sauerbraten's singleplayer modes, and a template-based worldgen system authored in a separate editor mode. **The target engine is not predetermined; engine selection is part of this project (Phase 0).**

## 1. Vision & Non-Goals

**Vision:** Sauerbraten proved that in-game octree editing can be instant and fun. This project turns that editing feel into the central gameplay verb of a persistent multiplayer world: players sculpt terrain and structures cooperatively, fight monster invasions in and around what they build, and explore procedurally assembled dungeons.

**Non-goals (v1):**
- No custom engine written from scratch (customization of an existing open-source engine is in scope).
- No MMO-scale content, quests, or progression trees.
- No per-corner vertex dragging *unless* the chosen engine natively supports it (octree engines may); voxel-grid engines approximate it (see §3).

## 2. Phase 0 — Engine Selection (a requirement, not an assumption)

Evaluate, prototype, and decide. The chosen engine must be developed *further* into the game — treat it as a fork-and-extend candidate, not just a modding target.

### 2.1 Evaluation criteria (weight high → low)
1. **Freeform geometry fidelity** — can the push/pull/select/grid-size mechanic be native (octree) or only approximated (uniform voxel volumes)?
2. **Multiplayer maturity** — client/server netcode, lag compensation, co-op editing feasibility (Sauerbraten's "Coop Edit" is the benchmark).
3. **Worldgen & procedurality** — infinite/persistent world, chunk streaming, hooks to inject custom structure generation.
4. **Entity/AI support** — monsters, combat, health/damage, spawn scripting.
5. **Extensibility** — scripting or clean C++/Rust codebase for gameplay work.
6. **Asset licensing** — engine code vs. media licensing (critical: Sauerbraten's *code* is zlib-licensed but its *media is non-free*; a standalone game must recreate all assets).
7. **Project health** — activity, community, documentation.

### 2.2 Candidate shortlist

| Candidate | Strengths | Risks / gaps |
|---|---|---|
| **Cube 2 (Sauerbraten) / Tesseract fork** | Native octree editing = exact target mechanic; built-in multiplayer incl. Coop Edit; DMSP monster-invasion mode and RPG example exist; lag-light netcode | Aging C++; finite maps, no chunked infinite world or procgen; **all media non-free — full asset recreation required** |
| **Luanti** | Mature multiplayer, Lua modding, infinite chunked world, mapgen APIs incl. structure placement, big mod ecosystem | Uniform voxel grid — freeform mechanic must be approximated as snap-step volume brushing; modest entity performance |
| **Veloren** | Modern active Rust codebase (GPL-3.0), MMO-scale multiplayer, strong procgen world, combat & AI already built | No editing mechanic at all — deepest engine work of all options; single integrated game, not an engine |
| **Godot + voxel modules** | Full control, modern tooling, MIT licensing | Everything multiplayer/voxel-scale must be built or assembled; highest effort and risk |

### 2.3 Engine spike (deliverable of Phase 0)
- Prototype the brush select → push/pull mechanic in the top two candidates (expected: Cube 2 fork vs. Luanti).
- Benchmark: batch-edit a ≥16³ region replicated to a connected client within one server tick at 60 Hz sim.
- Test worldgen injection: stamp a hand-made room template into generated terrain.
- **Decision gate:** score candidates against §2.1, write a 1-page decision record, commit. The rest of this document is engine-agnostic; §3 notes the two mechanic variants.

## 3. Core Mechanic — Freeform Editing (adapted per engine)

| Sauerbraten concept | Voxel-engine variant (Luanti-like) | Octree-engine variant (Cube 2-like) |
|---|---|---|
| Edit mode (E) | Editmode tool/privilege | Native edit mode |
| Cube selection | Brush: axis-aligned selection snapped to grid step (1, 2, 4, 8, 16 nodes) | Native cube/face selection |
| Push/pull face (scroll) | Extrude fills with active material / retract carves, one grid step per action | Native push/pull of faces *and corners* |
| Grid size up/down (G + scroll) | Brush resolution step (powers of two) | Native grid power |
| Texture per face (Y + scroll) | Material palette + orientation (facedir/param2) | Native per-face texturing |
| Copy/paste, undo | Node-volume copy/paste, ≥10-level undo | Native |

**Requirement E1–E7 (both variants):**
1. Selection snaps to the active grid step with a visible highlight; steps cycle 1→2→4→8→16→1.
2. Push/pull edits a ≥16³ volume within one server tick (batched writes; no per-cell round-trips).
3. Active material palette; empty ("air") is a valid material.
4. Per-player undo ≥10 levels; copy/paste with 90° rotation.
5. Edits are ordinary world data — persisted with the world, no sidecar format.
6. In survival-flavored play, editing is item-gated and consumes/returns materials; creative mode is unrestricted.
7. Server-authoritative: all edits validated server-side; protected areas and other mods/systems observe every edit.

## 4. Multiplayer

1. Dedicated server with client/server architecture; target 2–32 concurrent players on one world.
2. **Co-op editing:** simultaneous editing by multiple players, with selection visibility (see others' current selection outline) and edit conflict resolution (last-write-wins per region is acceptable for v1).
3. Server-side movement validation and basic anti-cheat on edit and combat actions.
4. Player accounts/persistence per server; player-built structures persist.

## 5. Entities, Monsters & Combat

Model on Sauerbraten's SP/DMSP content (a monster invasion fought on any map) but tuned for co-op multiplayer:

1. **3–5 basic monster archetypes** at launch: melee chaser, ranged shooter, tanky brute, swarm critter, and a spawner/mini-boss for dungeon ends. AI: simple perception → chase → attack state machine; no pathfinding beyond A-grid/waypoint level.
2. **Spawn system:** invasion-style spawn triggers (volume/proximity/region-triggered waves) usable in the world and inside dungeon templates.
3. **Combat:** hitscan or projectile player attacks, health/damage/death, knockback, simple drops (materials or upgrade currency — editing costs create the game loop: fight → loot → build).
4. **Multiplayer tuning:** monster HP and spawn counts scale with connected player count; kills/drops shared or instanced per player (decide in implementation).

## 6. Worldgen & Dungeon Templates (separate Editor Mode)

1. **Template Editor Mode:** a separate in-game editing mode (not the gameplay editmode) for authoring worldgen "chunks" — bounded regions (e.g. 32³) containing geometry, materials, spawn points, and trigger volumes.
2. Templates are saved as versioned, shareable assets (file-based, import/export).
3. **Worldgen integration:** the generator stamps templates into the world by pattern rules — biome/height/bias conditions, density, rotation/mirroring, and nesting (rooms → corridors → full dungeon patterns composed from multiple templates).
4. At least one complete dungeon pattern ships at launch: entrance → rooms → corridor connections → monster spawns → mini-boss chamber → reward/editing-material cache.
5. Templates respect the chosen engine's generation pipeline (e.g. mapgen structure callbacks on Luanti; custom octree paste for a Cube 2 fork) — the Phase 0 spike must prove this injection works.

## 7. Automated Testing (unit / integration / end-to-end)

Testing is a first-class requirement, not an afterthought. All three layers must run headless (CI-friendly, no GPU/display required) and via a single command on a fresh clone.

1. **Unit tests (pure logic, no engine):** brush/grid snapping math, grid-step cycling, volume diff computation (push/pull before/after), undo history semantics, material palette resolution, template serialization/deserialization, and worldgen pattern-rule evaluation. These must not boot the engine — testable as plain library code.
2. **Integration tests (engine, headless server):** run against a real headless server instance — edit operations committed to actual world storage, persistence across server restart, template stamping during worldgen, spawn triggers firing, protection/auth enforcement, damage/kill resolution, and edit-validation server authority (client-forged edit requests rejected).
3. **End-to-end tests (headless server + scripted bot clients):** scripted bot clients connect to a headless dedicated server and play scenarios — two bots co-editing adjacent regions, a bot triggering and clearing a monster wave, a bot exploring until a dungeon template spawns, and the full explore → fight → loot → build loop. Assert outcomes and the performance budgets (§3 E2: a 16³ edit replicates to all clients within one server tick).
4. **CI gate:** all three suites run on every commit; a red build blocks merge. New functional requirements (§3–§6) land together with tests at the same layer(s) they affect.
5. **Budgets as tests:** performance and netcode tick budgets are executable assertions in the e2e suite, not prose.

## 8. Acceptance Criteria

1. Phase 0 decision record exists, scored per §2.1, with the spike benchmarks attached.
2. A new player learns select → push/pull → material change within 5 minutes without docs.
3. Two players edit adjacent regions simultaneously without corruption; each sees the other's selection.
4. A 16³ push/pull replicates to all connected clients within one server tick.
5. A player can trigger, fight, and clear a monster wave; monsters scale with player count.
6. A template authored in Editor Mode appears correctly when its pattern rule triggers during fresh world exploration, including spawns and triggers.
7. All world edits and player builds survive a full server restart.
8. The full loop — explore generated dungeon → fight → loot materials → freeform-build — is playable end-to-end in one session.
9. A fresh clone builds and passes the unit, integration, and e2e suites (§7) with a single command in a headless CI environment; CI green is the merge gate.

## 9. Milestones

1. **M0 — Engine spike & decision** (§2.3).
2. **M1 — Freeform editing MVP** (E1–E5, single player) + headless test harness and unit suite (§7.1).
3. **M2 — Multiplayer + co-op editing** (§4, E6–E7) + integration suite against headless server (§7.2).
4. **M3 — Combat & monsters** (§5) + e2e bot-client scenarios (§7.3).
5. **M4 — Template editor mode + dungeon worldgen** (§6).
6. **M5 — Integration pass** — full loop tuning, anti-grief hardening, performance, CI as merge gate.
7. **Continuous** — every milestone ships with tests at the layers it touches; performance budgets stay executable assertions.
