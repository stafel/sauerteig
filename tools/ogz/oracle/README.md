# Oracle (Option C): diff our reader against the engine itself

**Status: written, not yet executed.** This session had no shell and no display,
so the engine could not be patched, built or run. Everything below is ready for
someone with a build environment; the acceptance step is a single command.

## Why an oracle at all

The corpus run already proves a lot (171/171 supported maps consume exactly the
right number of bytes *and* place every leaf inside the world). What it cannot
prove is **semantic** agreement: that our corner decode,
`octant index -> position`, material interpretation and merge flags mean the
same thing as the engine's. A mirrored or transposed axis mapping would pass
every byte-accounting check and still produce a wrong world. The dump below
answers exactly that, leaf for leaf.

## Finding that shapes the design

`load_world` lives inside `#ifndef STANDALONE` (`src/engine/worldio.cpp:172` to
`:1387`), and the only callers are `fpsgame/client.cpp` and `rpggame/rpg.cpp`.
**The dedicated server never loads the octree at all** — it only tracks the map
name. So the oracle cannot be `sauer_server`; it has to be the client, which
means a GL context. That is acceptable for a test-only artifact (the decision in
§8 was "patched server is fine as test-only"; this is the client variant of the
same idea) but it does mean the oracle is a manual, occasional check, not a CI
dependency.

## Procedure

```sh
cd sauerbraten
git apply ../tools/ogz/oracle/dumpoctree.patch      # or patch -p1 < ...
make -C src client                                   # needs SDL2 + OpenGL

SAUER_DUMP_OCTREE=/tmp/abbey.dump \
  ./src/sauer_client -q. -t0 -w640 -h480 abbey       # loads the map, dumps, quits
```

`-t0` keeps it windowed; under a headless machine use `xvfb-run -s "-screen 0
640x480x24"`. The dump is written the moment the octree has been validated,
before any rendering, so a slow first frame does not matter.

Then:

```sh
luanti tools/ogz/compare.lua /tmp/abbey.dump sauerbraten/packages/base/abbey.ogz
```

or from the in-engine harness (`worldmods/ogz_dev`), which passes the engine's
`core.decompress` for raw inflate.

## Dump format

One line per **leaf** (a node with no children), in the engine's own coordinates:

```
<x> <y> <z> <size> <e0..e11 as %02x> <t0..t5> <material>
```

Example:

```
0 0 0 512 80 80 80 80 80 80 80 80 80 80 80 80 0 0 0 0 0 0 0
```

Children of a leaf are never present, empty leaves *are* included (our reader
drops them, so the comparator drops them too - that is the only normalisation
applied). Nothing is rounded, so a mismatch is a real disagreement, not a
formatting artifact.

## What a pass means

For each map: identical leaf sets (position, size, all 12 edge bytes), identical
texture slots, identical material. That pins the octant walk, the child-size
rule, the corner decode inputs and the material decode simultaneously.

## Cost estimate

~60 lines of C++ (a recursive writer plus a `getenv` hook after `validatec`),
one client build, one run per map. Maps here load in well under a second each.
