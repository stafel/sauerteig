# Throwaway world used only to run the tools/ogz harness inside the engine
# (reader corpus verification and region export). See
# docs/sauerbraten-port-plan.md, 7a and tools/ogz/README.md.
#
# The world directory is deliberately the repository root: the mod sandbox only
# permits reads under the world, mod, game and mod_data paths
# (src/script/cpp_api/s_security.cpp:869-931), and the harness needs to read
# both tools/ogz/*.lua and sauerbraten/packages/base/*.ogz. No trusted mod and
# no insecure environment are involved.
#
# What the harness does is chosen by tools/ogz/run.txt, not by settings here:
# world.mt keys are not exposed through `core.settings`.
#
# Delete this file, worldmods/ogz_dev, worldmods/ogzport and the artifacts
# listed in .gitignore when the harness is no longer needed.
gameid = minetest
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
creative_mode = true
enable_damage = false
server_announce = false
mg_name = v7
