--!strict
-- Pure helpers shared by the service and the panels: no host calls, so they can be tested with plain `luau`.

local M = {}

M.PLUGIN = "gravityboots/gwallcards" -- must match `id` in plugin.toml (the API has no way to read it)
M.MONO = "mono" -- group for low-saturation (grey / black / white) wallpapers

export type Entry = { path: string, name: string, kind: string, key: string, thumb: string?, group: string? }
export type Group = { name: string, from: number, to: number }

-- { kind = { "ext", ... } } -> { ext = kind }
function M.extensionMap(kinds: { [string]: { string } }): { [string]: string }
	local map = {}
	for kind, list in kinds do
		for _, ext in list do
			map[string.lower((string.gsub(ext, "^%.", "")))] = kind
		end
	end
	return map
end

function M.kindOf(name: string, map: { [string]: string }): string?
	local ext = string.match(name, "%.([^./]+)$")
	return ext and map[string.lower(ext)] or nil
end

-- Stable short id for a file version (djb2 over path + mtime), used for cache file names.
function M.hash(text: string): string
	local h = 5381
	for i = 1, #text do
		h = bit32.band(h * 33 + string.byte(text, i), 0xFFFFFFFF)
	end
	return string.format("%08x", h)
end

-- string_map setting { name = "from-to" } (hue degrees, may wrap past 360) -> groups ordered around the wheel.
function M.parseGroups(map: { [string]: string }): { Group }
	local groups: { Group } = {}
	for name, range in map do
		local a, b = string.match(range, "^%s*(%d+)%s*%-%s*(%d+)%s*$")
		if a and b then
			local from, to = tonumber(a) :: number, tonumber(b) :: number
			if from > to then
				from -= 360 -- e.g. red "345-15" -> -15..15, so it sorts first
			end
			table.insert(groups, { name = name, from = from, to = to })
		end
	end
	table.sort(groups, function(x: Group, y: Group)
		return x.from < y.from
	end)
	return groups
end

local function hsv(r: number, g: number, b: number): (number, number, number)
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local d = max - min
	local h = 0
	if d > 0 then
		if max == r then
			h = 60 * (((g - b) / d) % 6)
		elseif max == g then
			h = 60 * ((b - r) / d + 2)
		else
			h = 60 * ((r - g) / d + 4)
		end
	end
	return h, max > 0 and d / max or 0, max
end

local function groupForHue(h: number, groups: { Group }): string?
	for _, g in groups do
		if (h >= g.from and h < g.to) or (h - 360 >= g.from and h - 360 < g.to) then
			return g.name
		end
	end
	return nil
end

-- Raw rgb24 bytes of a tiny downscale -> the colour group most pixels vote for.
function M.groupOf(rgb: string, groups: { Group }, minSaturation: number): string
	local votes: { [string]: number } = {}
	for i = 1, #rgb - 2, 3 do
		local r, g, b = string.byte(rgb, i, i + 2)
		local h, s, v = hsv(r / 255, g / 255, b / 255)
		local name = (s >= minSaturation and v >= 0.2) and groupForHue(h, groups) or M.MONO
		votes[name] = (votes[name] or 0) + 1
	end
	local best, count = M.MONO, -1
	for name, n in votes do
		if n > count or (n == count and name < best) then
			best, count = name, n
		end
	end
	return best
end

-- Representative swatch colour for a group (its mid hue).
function M.swatch(g: Group): string
	local h = ((g.from + g.to) / 2) % 360
	local c, x = 0.75, 0.75 * (1 - math.abs((h / 60) % 2 - 1))
	local r, gr, b = 0, 0, 0
	if h < 60 then
		r, gr = c, x
	elseif h < 120 then
		r, gr = x, c
	elseif h < 180 then
		gr, b = c, x
	elseif h < 240 then
		gr, b = x, c
	elseif h < 300 then
		r, b = x, c
	else
		r, b = c, x
	end
	local m = 0.15
	return string.format("#%02x%02x%02x", (r + m) * 255, (gr + m) * 255, (b + m) * 255)
end

-- Colour group (in wheel order, mono last), then name.
function M.sort(entries: { Entry }, groups: { Group })
	local rank: { [string]: number } = { [M.MONO] = #groups + 1 }
	for i, g in groups do
		rank[g.name] = i
	end
	table.sort(entries, function(a, b)
		local ga: string, gb: string = a.group or M.MONO, b.group or M.MONO
		local ra, rb = rank[ga] or #groups + 2, rank[gb] or #groups + 2
		if ra ~= rb then
			return ra < rb
		end
		return string.lower(a.name) < string.lower(b.name)
	end)
end

-- Layout of the translating deck around a fractional position `pos` (1-based).
-- Returns { index, weight, opacity } from left to right; `index` may fall outside the list (render a spacer).
export type Slot = { index: number, weight: number, opacity: number }
function M.slots(pos: number, perSide: number, sideRatio: number, dim: number): { Slot }
	local out = {}
	for i = math.floor(pos) - perSide - 1, math.ceil(pos) + perSide + 1 do
		local d = math.abs(i - pos)
		local weight
		if d <= 1 then
			weight = 1 + (sideRatio - 1) * d -- centre card shrinks into a side card
		elseif d <= perSide then
			weight = sideRatio
		else
			weight = sideRatio * math.max(0, perSide + 1 - d) -- edge cards slide in / out
		end
		if weight > 0.001 then
			local edge = math.clamp(perSide + 1 - d, 0, 1)
			table.insert(out, { index = i, weight = weight, opacity = math.max(0, 1 - dim * d) * edge })
		end
	end
	return out
end

return M
