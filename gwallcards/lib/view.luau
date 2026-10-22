--!nonstrict
-- The card deck shared by both panels. `deck.luau` renders it bare; `info.luau` adds the bottom bar
-- (colour filter, search, file name + type). The selection lives in noctalia.state, so swapping
-- between the two panels keeps your place.
--
-- Returns the host callbacks; the entry script assigns them as its globals (a module's own
-- globals stay private to the module).

local media = require("./media.luau")

-- Small visual constants of the info bar (everything else comes from settings).
local CHIP_SIZE = 22
local BADGE_RADIUS = 6

local function cfg(key)
	return noctalia.getConfig(key)
end

return function(mode: string)
	local other = media.PLUGIN .. ":" .. (mode == "deck" and "info" or "deck")

	local entries, groups = {}, {}
	local shown = {} -- entries after colour filter + search
	local filter, query, searchRev = nil, "", 0
	local sel, pos = 1, 1 -- selected slot and animated position; unbounded when wrapping
	local lastApplied = noctalia.state.get("current")

	-- Entry shown at slot `i` (wraps around the list when `wrap` is on) and a key unique per lap.
	local function at(i)
		local n = #shown
		if n == 0 then
			return nil, "empty" .. i
		end
		if not cfg("wrap") then
			return shown[i], shown[i] and shown[i].path or ("pad" .. i)
		end
		local e = shown[(i - 1) % n + 1]
		return e, e.path .. "#" .. math.floor((i - 1) / n)
	end

	local function selectedPath()
		local e = at(sel)
		return e and e.path
	end

	-- Rebuild `shown`. Keeps the selected file when it survives, unless `toTop` (new search text).
	local function refilter(toTop)
		local keep = not toTop and (selectedPath() or noctalia.state.get("selected") or lastApplied)
		local scores = {}
		shown = {}
		for _, e in entries do
			local score = query == "" and 0 or noctalia.fuzzyScore(query, e.name)
			if score and (filter == nil or e.group == filter) then
				scores[e] = score
				table.insert(shown, e)
			end
		end
		if query ~= "" then -- best match first while searching, colour order otherwise
			table.sort(shown, function(a, b)
				return scores[a] > scores[b]
			end)
		end
		sel = 1
		for i, e in shown do
			if e.path == keep then
				sel = i
			end
		end
		pos = sel -- also re-bases an unbounded wrapped position back into 1..n
	end

	-- ── Actions ───────────────────────────────────────────────────────────────

	-- `close` closes the panel afterwards; `onlyIfNew` (live preview) skips the file already applied.
	local function apply(close, onlyIfNew)
		local path = selectedPath()
		if path and not (onlyIfNew and path == lastApplied) then
			lastApplied = path
			noctalia.state.set("apply", { path = path, n = noctalia.nowMs() })
		end
		if close then
			panel.close()
		end
	end

	local function move(delta)
		sel += delta
		if not cfg("wrap") then
			sel = math.clamp(sel, 1, math.max(1, #shown))
		end
		noctalia.state.set("selected", selectedPath())
		panel.setNeedsFrameTick(true)
	end

	-- ── Rendering ─────────────────────────────────────────────────────────────

	local function card(slot)
		local e, key = at(slot.index)
		local props = {
			key = key,
			flexGrow = slot.weight,
			opacity = e and slot.opacity or 0,
			radius = cfg("card_radius"),
		}
		if not (e and e.thumb) then -- spacer past either end, or a thumbnail still being made
			props.fill = e and "surface_variant" or nil
			return ui.box(props)
		end
		props.path = e.thumb
		props.fit = "cover"
		props.height = cfg("thumbnail_width") / 3 -- decode-size hint only; the row stretches the real height
		props.onClick = function()
			if slot.index == sel then
				apply(true)
			else
				move(slot.index - sel)
			end
		end
		return ui.image(props)
	end

	local function deck()
		local cards = {}
		for _, slot in media.slots(pos, cfg("cards_per_side"), cfg("side_width_ratio"), cfg("dim_per_card")) do
			table.insert(cards, card(slot))
		end
		return ui.row({ flexGrow = 1, gap = cfg("card_gap") }, cards)
	end

	local render

	local function chip(name, fill)
		local active = filter == name
		return ui.box({
			key = "chip-" .. (name or "all"),
			width = CHIP_SIZE,
			height = CHIP_SIZE,
			radius = CHIP_SIZE / 2,
			fill = fill,
			border = active and "on_surface" or "outline",
			borderWidth = active and 2 or 1,
			tooltip = name or noctalia.tr("color.all"),
			onClick = function()
				if active then
					filter = nil
				else
					filter = name
				end
				refilter(false)
				render()
			end,
		})
	end

	local function infoBar()
		local chips = { chip(nil, "surface_variant") }
		for _, g in groups do
			table.insert(chips, chip(g.name, media.swatch(g)))
		end
		table.insert(chips, chip(media.MONO, "outline"))

		local e = shown[sel]
		return ui.row({ gap = 16, align = "center" }, {
			ui.row({ gap = 6, align = "center" }, chips),
			ui.input({
				key = "search-" .. searchRev, -- a fresh key re-creates the input; that is how `f` focuses it
				value = query,
				focus = searchRev > 0,
				placeholder = noctalia.tr("search.placeholder"),
				flexGrow = 1,
				onChange = function(text)
					query = text
					refilter(true)
					render()
				end,
			}),
			ui.row({ gap = 8, align = "center", width = cfg("info_name_width") }, {
				ui.label({ text = e and e.name or "", color = "on_surface_variant", maxLines = 1, flexGrow = 1, textAlign = "end" }),
				ui.row({ fill = "primary", radius = BADGE_RADIUS, paddingH = 8, paddingV = 2, visible = e ~= nil }, {
					ui.label({ text = e and noctalia.tr("kind." .. e.kind) or "", color = "on_primary", fontWeight = "bold" }),
				}),
			}),
		})
	end

	function render()
		if mode == "info" then
			panel.render(ui.column({ flexGrow = 1, gap = cfg("card_gap") }, { deck(), infoBar() }))
		else
			panel.render(deck())
		end
	end

	-- ── Host callbacks ────────────────────────────────────────────────────────

	local keys = {
		Left = function() move(-1) end,
		h = function() move(-1) end,
		Right = function() move(1) end,
		l = function() move(1) end,
		["shift+h"] = function() move(-cfg("cards_per_side")) end,
		["shift+l"] = function() move(cfg("cards_per_side")) end,
		Home = function() move(1 - ((sel - 1) % math.max(1, #shown) + 1)) end,
		End = function() move(#shown - ((sel - 1) % math.max(1, #shown) + 1)) end,
		Return = function() apply(true) end,
		space = function() apply(false) end,
		z = function() noctalia.togglePanel(other) end, -- swap deck <-> info, same position
		f = function()
			if mode == "info" then
				searchRev += 1
				render()
			end
		end,
	}

	local host = {}

	function host.onKey(chord, pressed)
		local action = pressed and keys[chord]
		if action then
			action()
		end
	end

	function host.onFrameTick(deltaMs)
		local dt = tonumber(deltaMs) or 16
		pos += (sel - pos) * (1 - math.exp(-dt * 4 / math.max(1, cfg("animation_ms")))) -- ~settled after animation_ms
		if math.abs(sel - pos) < 0.002 then
			pos = sel
			panel.setNeedsFrameTick(false)
			if cfg("live_preview") then
				apply(false, true)
			end
		end
		render()
	end

	function host.onOpen()
		noctalia.state.set("view", mode) -- the bar widget reopens whichever view you used last
		noctalia.state.set("rescan", noctalia.nowMs())
		searchRev = 0
		refilter(false)
		render()
	end

	noctalia.state.watch("index", function(value)
		entries = value or {}
		refilter(false)
		render()
	end)
	noctalia.state.watch("groups", function(value)
		groups = value or {}
		render()
	end)
	noctalia.state.watch("current", function(value)
		lastApplied = value
	end)

	return host
end
