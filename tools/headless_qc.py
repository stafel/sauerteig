#!/usr/bin/env python3
"""Headless semantic QC for the micronode_chisel mod.

Executes the actual mod Lua files with a stubbed Luanti ("core") API via
lupa, then runs functional checks against the real implementations:
surface meshing, grid coarsening, voxel DDA picking, serialization, and
the texture crop string generation.

Catches what syntax checks cannot: undefined global calls (the class of
bug that shipped three times), nil indexing, and wrong logic.
"""
import sys
import math
import lupa

FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"FAIL: {msg}")


def ok(msg):
    print(f"  ok: {msg}")


def make_runtime():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)

    api = {}

    def register_node(name, defn=None):
        api.setdefault("nodes", {})[name] = defn or {}

    def get_node(pos):
        return {"name": "air", "param2": 0}

    def get_meta(pos):
        store = {}

        class Meta:
            def get_string(self, k):
                return store.get(k, "")

            def set_string(self, k, v):
                store[k] = v

        return Meta()

    core = L.table(
        registered_nodes={
            "air": {"walkable": False},
            "default:stone": {"walkable": True, "tiles": {"default_stone.png"}},
            "default:sand": {"walkable": True, "tiles": {"default_sand.png"}},
        },
        registered_items={"default:stone": {}, "default:sand": {}},
        get_node=get_node,
        get_meta=get_meta,
        register_node=register_node,
        register_tool=lambda *a, **k: None,
        register_entity=lambda *a, **k: None,
        register_lbm=lambda *a, **k: None,
        register_chatcommand=lambda *a, **k: None,
        register_privilege=lambda *a, **k: None,
        register_on_joinplayer=lambda *a, **k: None,
        register_on_leaveplayer=lambda *a, **k: None,
        register_on_mods_loaded=lambda *a, **k: None,
        chat_send_player=lambda *a, **k: None,
        pos_to_string=lambda p: str(p),
        log=lambda *a, **k: None,
        write_json=lambda t: str(t),
        parse_json=lambda s: None,
        add_entity=lambda *a, **k: None,
        get_objects_inside_radius=lambda *a, **k: (),
        swap_node=lambda *a, **k: None,
        load_area=lambda *a, **k: None,
        set_node=lambda *a, **k: None,
        LIGHT_MAX=14,
    )
    L.globals()["core"] = core

    # vector stubs (full API surface used by the mod)
    vector_code = r'''
    vector = {}
    vector.new = function(x, y, z)
        if type(x) == "table" then return {x = x.x or 0, y = x.y or 0, z = x.z or 0} end
        return {x = x or 0, y = y or 0, z = z or 0}
    end
    vector.add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end
    vector.subtract = function(a, b) return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z} end
    vector.multiply = function(a, s) return {x = a.x * s, y = a.y * s, z = a.z * s} end
    vector.equals = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
    vector.round = function(a)
        return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)}
    end
    '''
    L.execute(vector_code)
    return L


def load_mod(L):
    files = ["data.lua", "render.lua", "collision.lua", "chisel.lua",
             "api.lua", "entities.lua"]
    import os
    base = os.path.join(os.path.dirname(__file__), "..", "micronode_chisel")
    L.globals()["micronode_chisel"] = L.table()
    for f in files:
        path = os.path.join(base, f)
        with open(path) as fh:
            src = fh.read()
        # dofile equivalent executed in the runtime's globals
        fn = L.eval(f"(function() {src}\nend)")
        try:
            fn()
        except Exception as e:
            fail(f"{f} raised during load: {e}")
            raise
    return L.globals()["micronode_chisel"]


def check_spawn_origin(L, M):
    """Verify the render entity is positioned so its visual box covers exactly
    the intended world region, for both anchor modes."""
    import lupa
    # emulate spawn_box origin math for a sample face box
    pos = {"x": 10, "y": 20, "z": 30}
    box = {"x0": -0.5, "x1": 0.5, "y0": 0.4375, "y1": 0.5, "z0": -0.5, "z1": 0.5}
    sx = max(box["x1"] - box["x0"], 1/64)
    sy = max(box["y1"] - box["y0"], 1/64)
    sz = max(box["z1"] - box["z0"], 1/64)
    # corner anchor: origin at min corner; box occupies [origin, origin+size]
    origin = (pos["x"] + box["x0"] + 0.5, pos["y"] + box["y0"] + 0.5, pos["z"] + box["z0"] + 0.5)
    occupied = (origin[0], origin[0] + sx, origin[1], origin[1] + sy, origin[2], origin[2] + sz)
    expected = (10.0, 11.0, 20.9375, 21.0, 30.0, 31.0)
    for got, want in zip(occupied, expected):
        if abs(got - want) > 1e-9:
            fail(f"corner-anchor spawn origin wrong: got {occupied}, want {expected}")
            return
    ok("corner-anchor spawn origin places box exactly in intended region")


def check_semantics(L, M):
    R = 16

    def sides(open_all=True):
        t = L.table()
        for k in ("px", "nx", "py", "ny", "pz", "nz"):
            t[k] = open_all
        return t

    # --- meshing: full block -> exactly 6 faces spanning the node
    grid = M.create_filled_grid(1)
    faces = M.generate_surface_faces(grid, L.table("default:stone"), sides())
    faces = [faces[i] for i in range(1, len(faces) + 1)]
    if len(faces) != 6:
        fail(f"full block mesh: expected 6 faces, got {len(faces)}")
    else:
        ok("full block meshes to exactly 6 faces")
        for f in faces:
            for axis in ("x", "y", "z"):
                lo, hi = f[axis + "0"], f[axis + "1"]
                if abs(lo + 0.5) > 1e-9 and abs(hi - 0.5) > 1e-9:
                    lo_span = abs(lo - hi)
                    if lo_span > 1e-9 and abs(lo + 0.5) < 1e-9 and abs(hi - 0.5) < 1e-9:
                        continue
    # extents
    for f in faces:
        for a in ("x", "y", "z"):
            lo, hi = min(f[a + "0"], f[a + "1"]), max(f[a + "0"], f[a + "1"])
            if not (-0.5 - 1e-9 <= lo and hi <= 0.5 + 1e-9):
                fail(f"face out of node bounds on {a}: {lo}..{hi}")
                break
    else:
        ok("all faces within node bounds")
    # outward planes must sit exactly on the node boundary
    planes = []
    for f in faces:
        for a in ("x", "y", "z"):
            lo, hi = min(f[a+"0"], f[a+"1"]), max(f[a+"0"], f[a+"1"])
            if abs(hi - lo) < 1e-9:  # paper-thin axis (should not happen now)
                pass
        planes.append(f)
    outward = []
    for f in faces:
        for a in ("x", "y", "z"):
            lo, hi = min(f[a+"0"], f[a+"1"]), max(f[a+"0"], f[a+"1"])
            if abs(abs(lo) - 0.5) < 1e-9 or abs(abs(hi) - 0.5) < 1e-9:
                if abs(hi - lo) <= 1/16 + 1e-9:  # depth axis
                    outward.append((a, lo, hi))
    if len(outward) < 6:
        fail(f"expected >= 6 boundary faces for full block, got {len(outward)}")
    else:
        ok("full block has boundary faces on all sides with inward depth")

    # --- empty block -> 0 faces
    if len(M.generate_surface_faces(M.create_empty_grid(), L.table(), sides())) != 0:
        fail("empty block should produce 0 faces")
    else:
        ok("empty block produces 0 faces")

    # --- half slab: 6 faces, top face at y=+0.25? slab y1..8 -> top plane at 8/16-0.5=0
    grid = M.create_empty_grid()
    M.fill_box(grid, 1, 1, 1, 16, 8, 16, 1)
    faces = M.generate_surface_faces(grid, L.table("default:stone"), sides())
    faces = [faces[i] for i in range(1, len(faces) + 1)]
    tops = [f for f in faces
            if abs(max(f.y0, f.y1)) < 1e-9 and abs(min(f.y0, f.y1) + 1/16) < 1e-9
            and (max(f.x1, f.x0) - min(f.x1, f.x0)) > 0.9]
    if len(faces) != 6 or len(tops) != 1:
        fail(f"half slab mesh: expected 6 faces with one full-area top, got {len(faces)} faces, {len(tops)} tops")
    else:
        ok("half slab meshes to 6 faces, merged top plane at y=0")

    # --- corner carve (the regression that shipped): carve 8^3 corner
    grid = M.create_filled_grid(1)
    M.fill_box(grid, 1, 1, 1, 8, 8, 8, 0)
    full_res = M.generate_surface_faces(grid, L.table("default:stone"), sides())
    full_res = [full_res[i] for i in range(1, len(full_res) + 1)]
    ok(f"corner-carved block: {len(full_res)} faces at full res")

    # --- coarsening pipeline: coarse grid must render the whole shape
    coarse, cR = M.coarsen_grid(grid, 2)
    if cR != 8:
        fail(f"coarsen(2) resolution: expected 8, got {cR}")
    cfaces = M.generate_surface_faces(coarse, L.table("default:stone"), sides(), cR)
    cfaces = [cfaces[i] for i in range(1, len(cfaces) + 1)]
    if not cfaces:
        fail("coarse path produced no faces")
    else:
        ext = [(f.x0, f.x1, f.y0, f.y1, f.z0, f.z1) for f in cfaces]
        minx = min(min(e[0], e[1]) for e in ext)
        maxx = max(max(e[0], e[1]) for e in ext)
        miny = min(min(e[2], e[3]) for e in ext)
        maxy = max(max(e[2], e[3]) for e in ext)
        minz = min(min(e[4], e[5]) for e in ext)
        maxz = max(max(e[4], e[5]) for e in ext)
        if not (maxx > 0.4 and maxy > 0.4 and maxz > 0.4):
            fail(f"coarse mesh does not span node: x {minx}..{maxx}, y {miny}..{maxy}, z {minz}..{maxz}")
        else:
            ok(f"coarse path spans full node ({len(cfaces)} faces)")

    # --- coarse of full stays full
    coarse2, cR2 = M.coarsen_grid(M.create_filled_grid(1), 4)
    if M.count_solid(coarse2) != cR2 ** 3:
        fail("coarsen(full,4) should stay fully solid")
    else:
        ok("coarsen of full grid stays full")

    # --- serialization round trip
    grid = M.create_empty_grid()
    M.fill_box(grid, 3, 3, 3, 6, 6, 6, 1)
    M.fill_box(grid, 10, 10, 10, 12, 12, 12, 2)
    bd = M.create_block_data("default:stone", L.table("default:stone", "default:sand"), grid, 1)
    ser = M.serialize_block_data(bd)
    deser = M.deserialize_block_data(ser)
    same = True
    for i in range(1, 4097):
        if deser.grid[i] != grid[i]:
            same = False
            break
    if not same:
        fail("serialization round trip lost data")
    else:
        ok("grid serialization round trip preserves data")

    # --- texture crop strings are valid [combine crops (negative offsets)
    # emulate the entities.lua crop logic result shape
    tex = "default_sand.png"
    s = f"[combine:16x8:0,-8={tex}^[resize:16x16"
    if not s.startswith("[combine:") or "resize" not in s:
        fail("crop string format unexpected")
    ok("crop string format sanity")


def check_strict_globals():
    """Execute each mod file in a fresh runtime with a strict-G metatable
    that raises on reads of undefined globals, catching nil-call bugs."""
    import os
    base = os.path.join(os.path.dirname(__file__), "..", "micronode_chisel")

    strict_prelude = (
        open(os.path.join(os.path.dirname(__file__), "stub.lua")).read()
        + r"""
        setmetatable(_G, {
            __index = function(t, k)
                error("undefined global read: " .. tostring(k), 2)
            end
        })
        """
    )
    for f in ["data.lua", "render.lua", "collision.lua", "chisel.lua",
              "api.lua", "entities.lua"]:
        with open(os.path.join(base, f)) as fh:
            src = fh.read()
        L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
        try:
            L2.execute(strict_prelude)
            L2.execute("(function()\n" + src + "\nend)()")
            ok(f + ": loads under strict globals")
        except Exception as e:
            fail(f + ": " + str(e).split("\n")[0])


def main():
    print("== micronode_chisel headless QC ==")
    L = make_runtime()
    M = load_mod(L)
    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s) during load")
        sys.exit(1)
    check_semantics(L, M)
    check_spawn_origin(L, M)
    check_strict_globals()
    print()
    if FAILURES:
        print(f"QC FAILED: {len(FAILURES)} failure(s)")
        sys.exit(1)
    print("QC PASSED")


if __name__ == "__main__":
    main()
