--!nonstrict
-- Panel entry: the deck view. All logic lives in lib/view.luau.
local view = require("./lib/view.luau")("deck")
onOpen, onKey, onFrameTick = view.onOpen, view.onKey, view.onFrameTick
