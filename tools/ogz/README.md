# tools/ogz — Sauerbraten `.ogz` reader and porter

Reads Cube 2: Sauerbraten maps and converts a region into Luanti nodes. See
`docs/sauerbraten-port-plan.md` for the design and the reasons behind each
decision.

Status: **M0 (reader) and M1 (region porter) work.** `docs/…-plan.md` §7a lists
what is verified and what is still approximated.

## Files

| File | Purpose |
|---|---|
| `ogz.lua` | Reader. Versions 29–33. Plain Lua 5.1: no `bit`, no `//`, no `goto`, so it runs in-engine, under lupa and in a stock interpreter |
| `materials.lua` | Replays a map's config to get texture slot → path, then classifies the path into a Luanti node |
| `port.lua` | Region selection (density + material diversity), voxelizer, payload encode/decode, spawn picking, ASCII preview |
| `compare.lua` | Leaf-for-leaf diff against an engine octree dump (the Option C oracle) |
| `selftest.lua` | Synthetic fixtures for every supported version, plus the real-map corpus layer |
| `corpus.txt` | The map corpus the reader is verified against |
| `world.mt`, `worldmods/ogz_selftest/` | Runs the synthetic layer inside the engine |
| `oracle/` | The engine patch and procedure for the oracle |

## Running things

Everything runs through the in-engine harness, because a mod may only read under
its own world, the mod directories, the game and `mod_data`
(`luanti/src/script/cpp_api/s_security.cpp:869-931`). The trick used throughout:
**make the world directory the directory that contains what you want to read.**

### Reader self-test (synthetic, no external files)

```sh
luantiheadless --worlddir tools/ogz        # world.mt here is the synthetic harness
```

### Corpus verification (all shipped maps)

The harness world is the repository root (`./world.mt`), because that is the only
directory containing both `tools/ogz/*.lua` and `sauerbraten/packages/*`.

```sh
echo "corpus" > tools/ogz/run.txt
luantiheadless --worlddir .                # expect: 171 parsed, 34 skipped, 0 failed
```

### Scan: what would a map give?

```sh
echo "scan 128 abbey venice monastery stemple" > tools/ogz/run.txt
luantiheadless --worlddir .
```

Reports, per map: the chosen region, how many distinct textures it uses, how much
of it is solid, and the resulting Luanti materials. Use it to pick a region worth
porting — a region poured from one texture looks like a monolith no matter how
correct the geometry is, so the selector ranks candidates by material diversity,
not just density.

### Export + import a region

```sh
echo "export abbey 128" > tools/ogz/run.txt
luantiheadless --worlddir .                # writes mod_data/ogzport/payload.bin
```

Then start the target world, whose `worldmods/ogzport` reads the payload from
`mod_data` and writes it into that world's map:

```sh
luantiheadless --worlddir ~/.minetest/worlds/sauerbraten_port
```

The importer verifies itself: it reads the map back and compares both the non-air
count and a checksum of content ids against what it wrote, and prints
`<-- MISMATCH` otherwise.

### Oracle (needs an engine build)

See `oracle/README.md`. Note that `load_world` is client-only, so the oracle
cannot be the dedicated server.

## Coordinate mapping

Sauerbraten is Z-up; Luanti is Y-up.

```
luanti.x = sauer.x
luanti.y = sauer.z
luanti.z = -sauer.y
```

The negation is what keeps both systems right-handed while preserving Luanti's
"north is −z". Dropping it produces a mirrored world that still passes every
byte-accounting test, which is why the oracle matters.

## Known approximations

- Materials come from a keyword classifier over texture *paths*, with a stable
  hash fallback for opaque names (`dg/mur049.jpg`). It keeps different textures
  visually distinct and consistent; it does not reproduce the original colours.
- Liquids come only from a cube's material bitfield (authoritative). A texture
  merely *named* water is not treated as liquid, because solid geometry is often
  textured with it and static liquids would flow.
- Entities (lights, mapmodels, teleports, spawns) are not imported yet.
