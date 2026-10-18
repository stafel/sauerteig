#!/usr/bin/env python3
"""Headless QC for the micronode_chisel mod.

Runs the *real* mod Lua files against a stubbed Luanti API (tools/stub.lua) and
then executes tools/qc_checks.lua, which drives the actual implementations:

  * grid/palette/storage round trips and size bounds
  * surface meshing (face count, bounds, one-voxel inward depth, neighbour
    culling, per-material splits, hash signature)
  * render-budget coarsening
  * voxel DDA picking and brush regions
  * collision shape recognition (slabs, stairs, panels, posts, fallbacks) and
    the node variants that carry it
  * clipboard copy/paste, rotation and undo
  * the full render path: chiselling, carving, entity spawn positions/sizes and
    texture crops (this is what catches the "disconnected faces" class of bug)
  * dig/drop wiring

A second pass loads every file with a strict `_G` metatable that raises on
undefined global reads, which catches orphaned references (the class of bug
behind several earlier startup crashes).
"""
import os
import sys

import lupa

HERE = os.path.dirname(os.path.abspath(__file__))
MOD_DIR = os.path.join(HERE, "..", "micronode_chisel")

# Load order must match init.lua.
MOD_FILES = [
    "data.lua",
    "collision.lua",
    "mesh.lua",
    "edit.lua",
    "entities.lua",
    "render.lua",
    "clipboard.lua",
    "chisel.lua",
    "api.lua",
]

FAILURES = []


def fail(message):
    FAILURES.append(message)
    print(f"FAIL: {message}")


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def strict_prelude():
    return read(os.path.join(HERE, "stub.lua")) + r"""
setmetatable(_G, {
    __index = function(_, key)
        error("undefined global read: " .. tostring(key), 2)
    end,
})
"""


def load_mod_file(runtime, name):
    source = read(os.path.join(MOD_DIR, name))
    runtime.execute("(function()\n" + source + "\nend)()")


def run_functional_checks():
    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(read(os.path.join(HERE, "stub.lua")))

    for name in MOD_FILES:
        try:
            load_mod_file(runtime, name)
        except Exception as exc:  # noqa: BLE001 - report and abort
            fail(f"{name} raised while loading: {exc}")
            return False

    checks = read(os.path.join(HERE, "qc_checks.lua"))
    try:
        result = runtime.eval("(function()\n" + checks + "\nend)()")
    except Exception as exc:  # noqa: BLE001
        fail(f"qc_checks.lua raised: {exc}")
        return False

    if result is not None:
        for index in range(1, len(result) + 1):
            fail(str(result[index]))
    return True


def run_strict_globals():
    runtime = lupa.LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(strict_prelude())
    ok = True
    for name in MOD_FILES:
        try:
            load_mod_file(runtime, name)
            print(f"  ok: {name} loads under strict globals")
        except Exception as exc:  # noqa: BLE001
            fail(f"{name} (strict globals): {str(exc).splitlines()[0]}")
            ok = False
    return ok


def main():
    print("== micronode_chisel headless QC ==")
    print("[qc] functional checks")
    functional = run_functional_checks()
    print("[qc] strict globals")
    strict = run_strict_globals()

    print()
    if FAILURES or not functional or not strict:
        print(f"QC FAILED: {len(FAILURES)} failure(s)")
        return 1
    print("QC PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
