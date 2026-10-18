# Throwaway world used only to run tools/ogz/selftest.lua inside the engine.
#
# `worlddir` is set to tools/ogz so the mod sandbox allows reading ogz.lua and
# selftest.lua (reads are only permitted under the world, mod, game and
# mod_data paths - src/script/cpp_api/s_security.cpp:869-931).
gameid = minetest
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
creative_mode = true
enable_damage = false
server_announce = false
mg_name = v7
