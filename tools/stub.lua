-- Minimal headless Luanti ("core") stubs for tools/headless_qc.py.
--
-- This is the single source of engine behaviour for the QC run: a node store,
-- a node metadata store, an entity store with ObjectRef-ish objects, and JSON
-- helpers that pass Lua tables through unchanged so the audit can inspect what
-- the mod actually spawned.

core = {}

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

core.settings = nil

-------------------------------------------------------------------------------
-- Node registry and node store
-------------------------------------------------------------------------------

core.registered_nodes = {
	air = {walkable = false, drawtype = "airlike", groups = {}, tiles = {}},
	ignore = {walkable = false, drawtype = "airlike", groups = {}, tiles = {}},
	["default:stone"] = {
		walkable = true, drawtype = "normal", groups = {stone = 1, cracky = 3},
		tiles = {"default_stone.png"},
	},
	["default:dirt"] = {
		walkable = true, drawtype = "normal", groups = {crumbly = 3},
		tiles = {"default_dirt.png"},
	},
	["default:sand"] = {
		walkable = true, drawtype = "normal", groups = {crumbly = 3},
		tiles = {"default_sand.png"},
	},
	["default:water_source"] = {
		walkable = false, drawtype = "liquid", groups = {liquid = 1},
		tiles = {"default_water.png"},
	},
	["default:grass_5"] = {
		walkable = false, drawtype = "plantlike", groups = {plant = 1},
		tiles = {"default_grass_5.png"},
	},
}

core.registered_items = {}
for name in pairs(core.registered_nodes) do
	core.registered_items[name] = core.registered_nodes[name]
end

function core.register_node(name, def)
	core.registered_nodes[name] = def or {}
	core.registered_items[name] = def or {}
end

__nodes = {}

local function poskey(p)
	return tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z)
end

function core.get_node(pos)
	local stored = __nodes[poskey(pos)]
	if stored then
		return {name = stored, param1 = 0, param2 = 0}
	end
	return {name = "air", param1 = 0, param2 = 0}
end

function core.set_node(pos, node)
	__nodes[poskey(pos)] = node.name
	if node.name == "air" then
		__meta_store[poskey(pos)] = nil
	end
end

function core.swap_node(pos, node)
	__nodes[poskey(pos)] = node.name
end

function core.remove_node(pos)
	__nodes[poskey(pos)] = nil
	__meta_store[poskey(pos)] = nil
end

function core.add_item() end

-------------------------------------------------------------------------------
-- Node metadata
-------------------------------------------------------------------------------

__meta_store = {}

function core.get_meta(pos)
	local key = poskey(pos)
	local store = __meta_store[key]
	if not store then
		store = {}
		__meta_store[key] = store
	end
	return {
		get_string = function(_, k)
			return store[k] or ""
		end,
		set_string = function(_, k, v)
			if v == nil or v == "" then
				store[k] = nil
			else
				store[k] = v
			end
		end,
	}
end

-------------------------------------------------------------------------------
-- Entities (ObjectRef-ish)
-------------------------------------------------------------------------------

__objects = {}

function core.register_entity() end

function core.write_json(t)
	return t
end

function core.parse_json(s)
	return s
end

function core.add_entity(pos, name, data)
	local obj = {
		pos = {x = pos.x, y = pos.y, z = pos.z},
		name = name,
		data = data,
		removed = false,
	}
	obj.get_pos = function(self)
		return self.pos
	end
	obj.get_luaentity = function(self)
		if self.removed then
			return nil
		end
		return {
			name = self.name,
			block_pos = self.data and self.data.bx
				and {x = self.data.bx, y = self.data.by, z = self.data.bz} or nil,
		}
	end
	obj.remove = function(self)
		self.removed = true
	end
	obj.get_properties = function(self)
		local d = self.data or {}
		return {visual_size = {x = d.sx or 1, y = d.sy or 1, z = d.sz or 1}}
	end
	__objects[#__objects + 1] = obj
	return obj
end

function core.get_objects_inside_radius(center, radius)
	local out = {}
	for _, obj in ipairs(__objects) do
		if not obj.removed then
			local dx = obj.pos.x - center.x
			local dy = obj.pos.y - center.y
			local dz = obj.pos.z - center.z
			if dx * dx + dy * dy + dz * dz <= radius * radius then
				out[#out + 1] = obj
			end
		end
	end
	return out
end

-------------------------------------------------------------------------------
-- Misc stubs
-------------------------------------------------------------------------------

for _, name in ipairs({
	"register_tool", "register_lbm", "register_chatcommand",
	"register_privilege", "register_on_joinplayer", "register_on_leaveplayer",
	"register_on_mods_loaded", "register_globalstep", "after",
	"register_on_player_receive_fields", "show_formspec",
	"register_on_dignode", "register_on_placenode",
	"chat_send_player", "log", "pos_to_string", "load_area",
	"get_player_by_name", "is_protected", "get_item_group",
}) do
	if core[name] == nil then
		core[name] = function() end
	end
end

function core.pos_to_string(p)
	return "(" .. tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z) .. ")"
end

function core.get_us_time()
	return os.clock() * 1e6
end

function core.get_item_group(name, group)
	local def = core.registered_nodes[name]
	if not def or not def.groups then
		return 0
	end
	return def.groups[group] or 0
end

function core.raycast()
	return {next = function() return nil end}
end

function core.get_modpath()
	return ""
end

function core.get_current_modname()
	return "micronode_chisel"
end

function ItemStack(name)
	return {get_name = function() return name end}
end

-------------------------------------------------------------------------------
-- vector
-------------------------------------------------------------------------------

vector = {}

function vector.new(x, y, z)
	if type(x) == "table" then
		return {x = x.x or 0, y = x.y or 0, z = x.z or 0}
	end
	return {x = x or 0, y = y or 0, z = z or 0}
end

function vector.add(a, b)
	return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z}
end

function vector.subtract(a, b)
	return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z}
end

function vector.multiply(a, s)
	return {x = a.x * s, y = a.y * s, z = a.z * s}
end

function vector.equals(a, b)
	return a.x == b.x and a.y == b.y and a.z == b.z
end

function vector.round(a)
	return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)}
end

micronode_chisel = {}
