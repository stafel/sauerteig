core = {}
core.settings = nil
core.registered_nodes = { air = {walkable = false},
    ["default:stone"] = {walkable = true, tiles = {"default_stone.png"}},
    ["default:sand"] = {walkable = true, tiles = {"default_sand.png"}} }
core.registered_items = {}
function core.get_node(p) return {name = "air"} end
__meta_store = {}
function core.get_meta(p)
    local key = tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z)
    local store = __meta_store[key]
    if not store then
        store = {}
        __meta_store[key] = store
    end
    return {
        get_string = function(_, k) return store[k] or "" end,
        set_string = function(_, k, v) store[k] = v end,
    }
end
for _, n in ipairs({"register_node","register_tool","register_entity","register_lbm",
    "register_chatcommand","register_privilege","register_on_joinplayer",
    "register_on_leaveplayer","register_on_mods_loaded"}) do
    core[n] = function() end
end
function core.chat_send_player() end
function core.pos_to_string(p) return "" end
function core.log() end
function core.write_json(t) return "" end
function core.parse_json(s) return nil end
function core.add_entity() end
function core.get_objects_inside_radius() return {} end
function core.swap_node() end
function core.load_area() end
function core.set_node() end
vector = {}
function vector.new(x, y, z)
    if type(x) == "table" then return {x = x.x or 0, y = x.y or 0, z = x.z or 0} end
    return {x = x or 0, y = y or 0, z = z or 0}
end
function vector.add(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end
function vector.subtract(a, b) return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z} end
function vector.multiply(a, s) return {x = a.x * s, y = a.y * s, z = a.z * s} end
function vector.equals(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function vector.round(a)
    return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)}
end
micronode_chisel = {}
