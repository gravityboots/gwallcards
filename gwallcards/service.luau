--!nonstrict
-- Background service: indexes wallpapers, makes thumbnails + colour groups, and applies the chosen one.
--
-- How switching works (the whole model, kept deliberately small):
--   * Noctalia's own wallpaper is always on. Images are applied with noctalia.setWallpaper, so they get
--     Noctalia's transitions and colour scheme.
--   * A video/gif first sets its extracted frame as the Noctalia wallpaper (same transition, colours follow),
--     then a single gSlapper process plays the video on top of that identical frame.
--   * Leaving a video kills gSlapper, which reveals that frame; Noctalia then transitions to the next image.
--   * Video -> video just tells the running gSlapper to change file.
-- Noctalia's wallpaper surface is never switched off and there is only ever one gSlapper, so there is nothing
-- to get out of sync. Every step is written to gwallcards.log in the plugin data folder.
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

-- ── Diagnostics ───────────────────────────────────────────────────────────────

local logPath = data .. "/gwallcards.log"
local logLines = {}

-- Appends a timestamped line to gwallcards.log (last 400 lines kept).
local function trace(msg)
	table.insert(logLines, string.format("%s.%03d  %s", os.date("%H:%M:%S"), noctalia.nowMs() % 1000, msg))
	if #logLines > 400 then
		table.remove(logLines, 1)
	end
	noctalia.writeFile(logPath, table.concat(logLines, "\n") .. "\n")
end

-- Runs a command, logging what ran and how it ended.
local function run(argv, cb)
	local label = type(argv) == "table" and table.concat(argv, " ") or argv
	noctalia.runAsync(argv, function(r)
		local out = noctalia.string.trim(r.stdout .. " " .. r.stderr)
		trace(string.format("   exit %d  %s%s", r.exitCode, label, out ~= "" and ("  -> " .. out) or ""))
		if cb then
			cb(r)
		end
	end, 5000)
end

-- ── Applying ──────────────────────────────────────────────────────────────────

local socket = sockets .. "/gslapper.sock" -- the one gSlapper this plugin owns (target "*" or the configured outputs)
local killArgv = { "pkill", "-f", "--", "gslapper .*--ipc-socket " .. sockets .. "/" }
local gen = 0 -- bumps on every apply; a delayed step from an older apply sees the mismatch and stops
local playing = false -- our gSlapper is running

local function outputs()
	if cfg("output") ~= "" then
		return { cfg("output") }
	end
	local names = {}
	for _, o in noctalia.outputs() do
		table.insert(names, o.name)
	end
	return names
end

local function setNoctaliaWallpaper(path)
	trace("noctalia wallpaper -> " .. path)
	for _, conn in outputs() do
		noctalia.setWallpaper(conn, path)
	end
end

-- Noctalia's transition length, so a video only appears once Noctalia has finished fading to its frame.
local function transitionMs()
	return (tonumber(noctalia.getSetting("wallpaper.transition_duration")) or 1500) + 100
end

local function killVideo(done)
	trace("stop gSlapper")
	run(killArgv, function()
		noctalia.removeFile(socket)
		playing = false
		if done then
			done()
		end
	end)
end

local function launchVideo(path)
	local gst = noctalia.string.trim(cfg("scale") .. " no-audio" .. (cfg("loop") and " loop" or "") .. " " .. cfg("gst_options"))
	local target = cfg("output") ~= "" and cfg("output") or "*" -- gSlapper takes one output or '*' (all)
	local argv = { "gslapper", "--fork", "--no-save-state", "--ipc-socket", socket, "--layer", cfg("video_layer"), "--fps-cap", cfg("fps_cap"), "--gst-options", gst }
	if cfg("when_hidden") ~= "none" then
		table.insert(argv, "--" .. cfg("when_hidden"))
	end
	table.insert(argv, target)
	table.insert(argv, path)
	trace("start gSlapper on " .. target)
	playing = true
	run(argv)
end

-- Asks the running gSlapper to switch file; restarts it if it does not answer OK.
local function changeVideo(path)
	trace("change gSlapper -> " .. path)
	run("printf '%s\\n' " .. quote("change " .. path) .. " | socat -T 2 - UNIX-CONNECT:" .. quote(socket), function(r)
		if r.exitCode ~= 0 or string.sub(r.stdout, 1, 2) ~= "OK" then
			killVideo(function()
				launchVideo(path)
			end)
		end
	end)
end

local function applyImage(path)
	if playing then
		killVideo(function() -- reveals the video's frame, then Noctalia transitions from it to the image
			setNoctaliaWallpaper(path)
		end)
	else
		setNoctaliaWallpaper(path)
	end
end

local function applyVideo(path, frame)
	local g = gen
	setNoctaliaWallpaper(frame)
	if playing then
		changeVideo(path)
		return
	end
	trace(string.format("waiting %d ms for Noctalia's transition", transitionMs()))
	run({ "sleep", tostring(transitionMs() / 1000) }, function()
		if g == gen then
			launchVideo(path)
		else
			trace("skipped: a newer apply took over")
		end
	end)
end

local function kindOf(path)
	return media.kindOf(path, media.extensionMap({
		image = cfg("image_extensions"),
		video = cfg("video_extensions"),
		gif = cfg("gif_extensions"),
	}))
end

local function apply(path)
	local kind = kindOf(path)
	local info = kind and noctalia.fileInfo(path)
	if not info then
		trace("apply ignored (not a wallpaper): " .. tostring(path))
		return
	end
	gen += 1
	trace(string.format("apply #%d %s %s (video playing: %s)", gen, kind, path, tostring(playing)))
	current = { path = path, kind = kind }
	noctalia.writeFile(currentPath, noctalia.json.encode(current))
	noctalia.state.set("current", path)

	if kind == "image" then
		applyImage(path)
		return
	end
	local frame = frames .. "/" .. media.hash(path .. ":" .. info.mtime) .. ".jpg"
	if noctalia.fileExists(frame) then
		applyVideo(path, frame)
	else
		local g = gen
		run({ "ffmpeg", "-v", "error", "-y", "-i", path, "-vf", "thumbnail=30", "-frames:v", "1", "-q:v", "2", frame }, function()
			if g == gen then
				applyVideo(path, frame)
			end
		end)
	end
end

-- Writes what is running right now to the log: our gSlapper processes, its own status, Noctalia's wallpaper.
local function status()
	trace("status: current = " .. tostring(current.path) .. ", video playing = " .. tostring(playing))
	for _, conn in outputs() do
		trace("   noctalia wallpaper " .. conn .. " = " .. tostring(noctalia.wallpaperPath(conn)))
	end
	run({ "pgrep", "-af", "gslapper" })
	run("printf 'query\\n' | socat -T 2 - UNIX-CONNECT:" .. quote(socket))
end

-- ── Wiring ────────────────────────────────────────────────────────────────────

noctalia.state.watch("apply", function(req)
	if req and req.path then
		apply(req.path)
	end
end)
noctalia.state.watch("rescan", scan)

-- Settings that need gSlapper restarted (so toggling a settings section does not restart the video).
local function playbackSettings()
	local parts = {}
	for _, key in { "output", "scale", "fps_cap", "loop", "when_hidden", "gst_options", "video_layer" } do
		table.insert(parts, tostring(cfg(key)))
	end
	return table.concat(parts, "|")
end
local playback = playbackSettings()

function onConfigChanged()
	scan()
	local now = playbackSettings()
	if now ~= playback and playing then
		trace("playback settings changed")
		killVideo(function()
			launchVideo(current.path)
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
		gen += 1
		killVideo()
	elseif event == "rescan" then
		scan()
	elseif event == "status" then
		status()
	end
end

function onExit(_signal, reason)
	if reason ~= "reload" then
		noctalia.runAsync(killArgv) -- no callback: it has to outlive this runtime
	end
end

trace("---- service started; log: " .. logPath)
for _, o in noctalia.outputs() do
	noctalia.setWallpaperEnabled(o.name, true) -- undo older gwallcards builds that switched it off
end
scan()
noctalia.state.set("current", current.path or noctalia.wallpaperPath(noctalia.focusedOutputName() or ""))
killVideo(function() -- clear any gSlapper left from a crash, then bring the video back
	if current.kind and current.kind ~= "image" then
		apply(current.path)
	end
end)
