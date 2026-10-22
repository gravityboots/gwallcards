--!nonstrict
-- Bar widget: opens whichever view (deck or info) was used last.
local media = require("./lib/media.luau")

barWidget.setGlyph(noctalia.getConfig("glyph"))

function onClick()
	noctalia.togglePanel(media.PLUGIN .. ":" .. (noctalia.state.get("view") or noctalia.getConfig("default_view")))
end
