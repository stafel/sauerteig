-- Turn Sauerbraten texture slots into Luanti node names.
--
-- A `.ogz` stores texture *slot indices*, never names: the names live in the
-- map's config (`packages/base/<map>.cfg`), which is a small scripting dialect
-- (`texturereset`, `texture 0 "path"`, `exec "packages/x/package.cfg"`). This
-- module replays enough of it to map slot -> texture path, then classifies the
-- path by keyword.
--
-- Deliberate limitation: this is a *classifier*, not an importer. We never copy
-- textures (Sauerbraten media is not freely licensed - see
-- docs/sauerbraten-port-plan.md). The map's materials are approximated with
-- Luanti nodes of the same role, which is all the template/dungeon use case
-- needs. Every mapping is a rule below, and unmapped slots are reported so a bad
-- classification is visible instead of silent.

local M = {}

-- Ordered rules: first match wins, so specific patterns must come first.
-- Patterns are Lua patterns matched against the lowercased texture path.
--
-- Note there are no water/lava rules here on purpose. Liquids come from the
-- cube's *material bitfield*, which is authoritative ("a water cube is empty
-- space with a liquid material"). A texture merely *named* water can sit on
-- solid geometry - many maps use `golgotha/water2.jpg` as their default wall
-- texture - and turning that into a liquid node would make solid walls flow
-- away.
M.RULES = {
	{ "sky", "default:glass" },            -- sky textures are never geometry
	{ "glass", "default:glass" },
	{ "ice", "default:ice" },
	{ "snow", "default:snowblock" },
	{ "leaf", "default:leaves" },
	{ "foliage", "default:leaves" },
	{ "tree", "default:tree" },
	{ "log", "default:tree" },
	{ "bark", "default:tree" },
	{ "grass", "default:dirt_with_grass" },
	{ "moss", "default:dirt_with_grass" },
	{ "dirt", "default:dirt" },
	{ "mud", "default:dirt" },
	{ "soil", "default:dirt" },
	{ "sand", "default:sand" },
	{ "gravel", "default:gravel" },
	{ "rubble", "default:gravel" },
	{ "cobble", "default:cobble" },
	{ "pave", "default:cobble" },
	{ "road", "default:cobble" },
	{ "gold", "default:goldblock" },
	{ "copper", "default:copperblock" },
	{ "steel", "default:steelblock" },
	{ "metal", "default:steelblock" },
	{ "iron", "default:steelblock" },
	{ "rust", "default:steelblock" },
	{ "grate", "default:steelblock" },
	{ "plate", "default:steelblock" },
	{ "rivet", "default:steelblock" },
	{ "wood", "default:wood" },
	{ "plank", "default:wood" },
	{ "timber", "default:wood" },
	{ "board", "default:wood" },
	{ "crate", "default:wood" },
	{ "marble", "default:stone" },
	{ "granite", "default:stone" },
	{ "concrete", "default:stone" },
	{ "cement", "default:stone" },
	{ "brick", "default:stonebrick" },
	{ "block", "default:stone" },
	{ "stone", "default:stone" },
	{ "rock", "default:stone" },
	{ "wall", "default:stone" },
	{ "cliff", "default:stone" },
}

-- Used when nothing matches, or when a slot has no resolvable path.
M.FALLBACK = "default:stone"

-- Many maps use opaque texture names (`dg/mur049.jpg`, `tech1soc/sqrlig02bb.jpg`)
-- that carry no material hint at all. Mapping every one of them to stone makes
-- the whole conversion one grey mass, which hides whether the *geometry* came
-- across correctly - the thing being checked. So such paths fall back to a
-- stable pseudo-random pick from a small neutral palette: the same texture
-- always becomes the same node (so a wall stays one material), while different
-- textures stay visually distinct. It is a visibility aid, not a guess at the
-- original material.
M.NEUTRAL = {
	"default:stone",
	"default:stonebrick",
	"default:cobble",
	"default:desert_stone",
	"default:wood",
	"default:steelblock",
	"default:gravel",
	"default:desert_stonebrick",
}

-- Deterministic hash of a string (djb2), used only to index M.NEUTRAL.
local function hash(text)
	local value = 5381
	for i = 1, #text do
		value = (value * 33 + text:byte(i)) % 4294967296
	end
	return value
end

function M.neutral_for(path)
	return M.NEUTRAL[hash(path) % #M.NEUTRAL + 1]
end

-- Resolve one texture path to a Luanti node name.
-- Returns node_name, how, where `how` is the matching rule, or "neutral" for the
-- hash fallback, or nil when there is no path at all.
function M.classify(path, opts)
	if not path or path == "" then
		return M.FALLBACK, nil
	end
	local lower = path:lower()
	for _, rule in ipairs(M.RULES) do
		if lower:find(rule[1]) then
			return rule[2], rule[1]
		end
	end
	if opts and opts.neutral == false then
		return M.FALLBACK, nil
	end
	return M.neutral_for(lower), "neutral"
end

--- Config parsing -----------------------------------------------------------

-- Strip a Sauerbraten comment ("//" to end of line) and surrounding spaces.
local function clean(line)
	local cut = line:find("//", 1, true)
	if cut then line = line:sub(1, cut - 1) end
	return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split a config line into argv-style tokens, honouring "quoted strings".
local function tokenize(line)
	local tokens = {}
	local i = 1
	while i <= #line do
		local c = line:sub(i, i)
		if c == '"' then
			local close = line:find('"', i + 1, true)
			if not close then break end
			tokens[#tokens + 1] = line:sub(i + 1, close - 1)
			i = close + 1
		elseif c:match("%s") then
			i = i + 1
		else
			local stop = line:find("%s", i) or (#line + 1)
			tokens[#tokens + 1] = line:sub(i, stop - 1)
			i = stop
		end
	end
	return tokens
end
M.tokenize = tokenize

-- Replay a config and return the slot -> texture path list.
--
-- `readfile(relpath)` returns the file's text. `exec` targets are resolved
-- relative to the Sauerbraten install root, which is why the caller supplies a
-- resolver rather than a bare open().
--
-- Mirrors `texturereset` (truncate the slot list) and `texture <type> <path>`
-- (append a slot when the type is the diffuse texture - texture.cpp:2031-2060,
-- where a numeric type like "0" degrades to TEX_DIFFUSE).
function M.parse_config(mapname, readfile, opts)
	opts = opts or {}
	local max_depth = opts.max_depth or 8
	local slots = {}
	local seen = {}
	local missing = {}

	local function run(relpath, depth)
		-- Config files are written with the host's separator, often "\" even on
		-- Linux (`exec "packages\blikjebier\snow\package.cfg"`). Normalise.
		relpath = relpath:gsub("\\", "/")
		if depth > max_depth or seen[relpath] then return end
		seen[relpath] = true
		local text = readfile(relpath)
		if not text then
			missing[#missing + 1] = relpath
			return
		end
		for line in text:gmatch("[^\r\n]+") do
			line = clean(line)
			if line ~= "" then
				local tokens = tokenize(line)
				local command = tokens[1]
				if command == "texturereset" then
					local limit = tonumber(tokens[2]) or 0
					for i = #slots, math.max(1, limit + 1), -1 do
						slots[i] = nil
					end
				elseif command == "texture" then
					-- texture <type> "<path>" [rot xoff yoff scale]
					local kind, path = tokens[2], tokens[3]
					if path and (kind == nil or kind:match("^%d+$")) then
						slots[#slots + 1] = path
					end
				elseif command == "exec" then
					local target = tokens[2]
					if target then
						run(target, depth + 1)
					end
				end
			end
		end
	end

	run("packages/base/" .. mapname .. ".cfg", 0)
	return slots, missing
end

-- Build slot -> Luanti node name for a map, plus a report.
-- Returns palette (array, 1-based slot), report {resolved, unmapped, missing}.
function M.build_palette(mapname, readfile, texture_mru, opts)
	local slots, missing = M.parse_config(mapname, readfile, opts)
	local palette, cache = {}, {}
	local report = {
		slots = #slots, resolved = 0, neutral = 0, unmapped = 0,
		missing_files = missing, unmapped_paths = {},
	}

	for slot, path in ipairs(slots) do
		local node, how = M.classify(path, opts)
		if how == "neutral" then
			report.neutral = report.neutral + 1
		elseif how then
			report.resolved = report.resolved + 1
		else
			report.unmapped = report.unmapped + 1
			if #report.unmapped_paths < 12 then
				report.unmapped_paths[#report.unmapped_paths + 1] = path
			end
		end
		palette[slot] = node or M.FALLBACK
		cache[slot] = {path = path, rule = how}
	end

	-- Slots the map actually references but the config never defined would be a
	-- bug in the parser; report them rather than silently using the fallback.
	-- `texture_mru` holds 0-based slots, `palette` is a 1-based array.
	report.mru_unresolved = 0
	for _, slot in ipairs(texture_mru or {}) do
		if palette[slot + 1] == nil then
			report.mru_unresolved = report.mru_unresolved + 1
		end
	end

	return palette, report, cache
end

print("[ogz] materials module loaded")
return M
