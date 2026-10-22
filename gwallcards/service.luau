--!nonstrict
-- Background service: indexes wallpapers, makes thumbnails + colour groups, and applies the chosen one.
-- Images go through Noctalia's own wallpaper (so the colour scheme follows); videos and gifs run in gSlapper
-- with an extracted frame set as the Noctalia wallpaper underneath for colours.
--
-- Shared state it publishes: "index" (sorted entries), "groups" (colour groups), "current" (applied path).
-- Shared state it reads:     "apply" ({ path, n }) and "rescan" (any changing value), both set by the panels.

local media = require("./lib/media.luau")

local data = noctalia.pluginDataDir()
local thumbs, frames = data .. "/thumbs", data .. "/frames"
local sockets = (noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/gwallcards"
local cachePath, currentPath = data .. "/colors.json", data .. "/current.json"
for _, dir in { thumbs, frames, sockets } do
	noctalia.mkdirAll(dir)
end

local colors = noctalia.json.decode(noctalia.readFile(cachePath) or "{}") or {} -- key -> group
local current = noctalia.json.decode(noctalia.readFile(currentPath) or "{}") or {} -- { path, kind }
local index = {}

local function cfg(key)
	return noctalia.getConfig(key)
end

local function quote(s)
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- ── Indexing ──────────────────────────────────────────────────────────────────

local function groups()
	return media.parseGroups(cfg("color_groups") or {})
end

local function publish()
	media.sort(index, groups())
	noctalia.state.set("index", index)
end

-- Thumbnail jobs run a few at a time; each makes a thumbnail, then samples it for the colour group.
local queue, running = {}, 0

local function pump()
	while running < cfg("thumbnail_jobs") and #queue > 0 do
		local e = table.remove(queue, 1)
		running += 1
		local thumb, sample = thumbs .. "/" .. e.key .. ".jpg", thumbs .. "/" .. e.key .. ".rgb"
		local scale = "thumbnail=30,scale=" .. cfg("thumbnail_width") .. ":-2"
		noctalia.runAsync({ "ffmpeg", "-v", "error", "-y", "-i", e.path, "-vf", scale, "-frames:v", "1", "-q:v", "3", thumb }, function(r)
			if r.exitCode ~= 0 then
				noctalia.log("gwallcards: thumbnail failed for " .. e.path .. ": " .. r.stderr)
				running -= 1
				pump()
				return
			end
			noctalia.runAsync({ "ffmpeg", "-v", "error", "-y", "-i", thumb, "-vf", "scale=8:8", "-f", "rawvideo", "-pix_fmt", "rgb24", sample }, function()
				local rgb = noctalia.readFile(sample)
				noctalia.removeFile(sample)
				e.thumb = thumb
				e.group = rgb and media.groupOf(rgb, groups(), cfg("color_min_saturation")) or media.MONO
				colors[e.key] = e.group
				running -= 1
				if #queue == 0 and running == 0 then
					noctalia.writeFile(cachePath, noctalia.json.encode(colors))
				end
				publish()
				pump()
			end)
		end)
	end
end

local function folders()
	local list = cfg("folders") or {}
	if #list == 0 then
		list = { noctalia.wallpaperDirectory() } -- empty if Noctalia has no wallpaper folder either
	end
	return list
end

local function scan()
	local kinds = media.extensionMap({
		image = cfg("image_extensions"),
		video = cfg("video_extensions"),
		gif = cfg("gif_extensions"),
	})
	index, queue = {}, {}
	for _, folder in folders() do
		local dir = noctalia.expandPath(folder)
		for _, name in noctalia.listDir(dir) or {} do
			local kind = media.kindOf(name, kinds)
			local path = dir .. "/" .. name
			local info = kind and noctalia.fileInfo(path)
			if info and not info.isDir then
				local key = media.hash(path .. ":" .. info.mtime)
				local thumb = thumbs .. "/" .. key .. ".jpg"
				local e = { path = path, name = name, kind = kind, key = key }
				if colors[key] and noctalia.fileExists(thumb) then
					e.thumb, e.group = thumb, colors[key]
				else
					table.insert(queue, e)
				end
				table.insert(index, e)
			end
		end
	end
	noctalia.state.set("groups", groups())
	publish()
	pump()
end

-- ── Applying ──────────────────────────────────────────────────────────────────

-- { connector names Noctalia draws on, gSlapper targets } for the configured outputs (empty = all).
local function targets()
	local chosen = cfg("outputs") or {}
	if #chosen > 0 then
		return chosen, chosen
	end
	local names = {}
	for _, o in noctalia.outputs() do
		table.insert(names, o.name)
	end
	return names, { "*" }
end

local function socketFor(target)
	return sockets .. "/" .. (target == "*" and "all" or target) .. ".sock"
end

local function send(target, command, cb)
	local sh = "printf '%s\\n' " .. quote(command) .. " | socat -T 2 - UNIX-CONNECT:" .. quote(socketFor(target))
	noctalia.runAsync(sh, function(r)
		if cb then
			cb(r.exitCode == 0 and string.sub(r.stdout, 1, 2) == "OK")
		end
	end, 3000)
end

-- Stops every gSlapper instance this plugin started, then calls `done` once they are gone.
local function stopVideo(done)
	local socks = noctalia.listDir(sockets) or {}
	local pending = #socks
	for _, conn in (targets()) do
		noctalia.setWallpaperEnabled(conn, true)
	end
	if pending == 0 and done then
		done()
	end
	for _, name in socks do
		local sock = sockets .. "/" .. name
		noctalia.runAsync("printf 'stop\\n' | socat -T 2 - UNIX-CONNECT:" .. quote(sock) .. "; rm -f " .. quote(sock), function()
			pending -= 1
			if pending == 0 and done then
				done()
			end
		end)
	end
end

local function launch(target, path)
	local gst = noctalia.string.trim(cfg("scale") .. " no-audio" .. (cfg("loop") and " loop" or "") .. " " .. cfg("gst_options"))
	local argv = { "gslapper", "--fork", "--no-save-state", "--ipc-socket", socketFor(target), "--fps-cap", cfg("fps_cap"), "--gst-options", gst }
	if cfg("when_hidden") ~= "none" then
		table.insert(argv, "--" .. cfg("when_hidden"))
	end
	table.insert(argv, target)
	table.insert(argv, path)
	noctalia.removeFile(socketFor(target)) -- stale socket from a crashed instance
	noctalia.runAsync(argv, function(r)
		if r.exitCode ~= 0 then
			noctalia.notifyError("gwallcards", "gSlapper failed: " .. r.stderr)
			stopVideo()
		end
	end)
end

local function setNoctaliaWallpaper(conns, path)
	for _, conn in conns do
		noctalia.setWallpaper(conn, path)
	end
end

local function applyVideo(path, key)
	local conns, gtargets = targets()
	local frame = frames .. "/" .. key .. ".jpg"
	local function play()
		setNoctaliaWallpaper(conns, frame) -- drives the colour scheme; hidden under gSlapper
		for _, t in gtargets do
			send(t, "change " .. path, function(ok)
				if not ok then
					launch(t, path)
				end
			end)
		end
		for _, conn in conns do
			noctalia.setWallpaperEnabled(conn, false)
		end
	end
	if noctalia.fileExists(frame) then
		play()
	else
		noctalia.runAsync({ "ffmpeg", "-v", "error", "-y", "-i", path, "-vf", "thumbnail=30", "-frames:v", "1", "-q:v", "2", frame }, play)
	end
end

local function apply(path)
	local kind = media.kindOf(path, media.extensionMap({
		image = cfg("image_extensions"),
		video = cfg("video_extensions"),
		gif = cfg("gif_extensions"),
	}))
	local info = kind and noctalia.fileInfo(path)
	if not info then
		return
	end
	if kind == "image" then
		stopVideo()
		setNoctaliaWallpaper((targets()), path)
	else
		applyVideo(path, media.hash(path .. ":" .. info.mtime))
	end
	current = { path = path, kind = kind }
	noctalia.writeFile(currentPath, noctalia.json.encode(current))
	noctalia.state.set("current", path)
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

noctalia.state.watch("apply", function(req)
	if req and req.path then
		apply(req.path)
	end
end)
noctalia.state.watch("rescan", scan)

-- Settings that need gSlapper relaunched when they change (toggling a settings section must not restart the video).
local function playbackSettings()
	local parts = {}
	for _, key in { "scale", "fps_cap", "loop", "when_hidden", "gst_options" } do
		table.insert(parts, tostring(cfg(key)))
	end
	table.insert(parts, table.concat(cfg("outputs") or {}, ","))
	return table.concat(parts, "|")
end
local playback = playbackSettings()

function onConfigChanged()
	scan()
	local now = playbackSettings()
	if now ~= playback and current.kind and current.kind ~= "image" then
		stopVideo(function()
			apply(current.path) -- relaunch with the new gSlapper options
		end)
	end
	playback = now
end

function onIpc(event, payload)
	if event == "toggle" then -- open/close whichever view was used last (one keybind for both)
		noctalia.togglePanel(media.PLUGIN .. ":" .. (noctalia.state.get("view") or cfg("default_view")))
	elseif event == "apply" and payload then
		apply(payload)
	elseif event == "stop" then
		stopVideo()
	elseif event == "rescan" then
		scan()
	end
end

function onExit(_signal, reason)
	if reason ~= "reload" then
		stopVideo()
	end
end

scan()
noctalia.state.set("current", current.path or noctalia.wallpaperPath(noctalia.focusedOutputName() or ""))
if current.kind and current.kind ~= "image" then
	apply(current.path) -- bring the video back after a restart
end
