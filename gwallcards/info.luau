--!nonstrict
-- Panel entry: the info view. All logic lives in lib/view.luau.
local view = require("./lib/view.luau")("info")
onOpen, onKey, onFrameTick = view.onOpen, view.onKey, view.onFrameTick
