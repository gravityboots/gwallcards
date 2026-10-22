# gwallcards

A keyboard-first card deck for image, video and gif wallpapers on [Noctalia](https://github.com/noctalia-dev/noctalia) v5.

![gwallcards](https://raw.githubusercontent.com/gravityboots/gwallcards/main/assets/screenshot.png)

Scroll through your wallpapers as a row of cards. The centre card is the selection, and the cards
beside it shrink and fade. Press Enter to apply.

- **Images** go through Noctalia's own wallpaper, so your colour scheme follows them.
- **Videos and gifs** play in [gSlapper](https://github.com/Nomadcxx/gSlapper). A frame from each one
  is set as the Noctalia wallpaper underneath, so the colour scheme follows those too.
- **Two views**, swapped with `z`:
  - **deck**: just the cards, in a panel that wraps them.
  - **info**: the cards plus a bar with colour filters, fuzzy search, and the file name with an
    image / video / gif badge.
- Wallpapers are sorted by colour, then by name, and the deck loops around at the ends.

Tested on Hyprland with Noctalia v5.

## Requirements

- Noctalia v5 (plugin API 25 or newer)
- [`gslapper`](https://github.com/Nomadcxx/gSlapper) 1.5+ plays video and gif wallpapers
- `ffmpeg` makes thumbnails, picks colours, and extracts video frames
- `socat` sends commands to gSlapper

On Arch / CachyOS:

```sh
sudo pacman -S ffmpeg socat
yay -S gslapper
```

If you use the community **gSlapper Wallpaper** plugin, disable it. The two would fight over gSlapper.

## Install

Add this repo as a plugin source and enable the plugin:

```sh
noctalia msg plugins source add gravityboots git https://github.com/gravityboots/gwallcards
noctalia msg plugins enable gravityboots/gwallcards
```

Or install it by hand: copy the `gwallcards/` folder to `~/.local/share/noctalia/plugins/gwallcards`,
then enable **gwallcards** in Settings → Plugins.

There is also an optional bar widget: add **gwallcards** to your bar in Noctalia's settings.

## Hyprland keybind

One bind opens and closes the panel, in whichever view (deck or info) you used last. Add it to
`~/.config/hypr/hyprland.conf`, or to whichever file holds your binds:

```conf
bind = SUPER, W, exec, noctalia msg plugin gravityboots/gwallcards:service all toggle
```

Change `SUPER, W` to any free key, then reload Hyprland with `hyprctl reload`.

To open a specific view directly instead:

```conf
bind = SUPER, W, exec, noctalia msg panel-toggle gravityboots/gwallcards:deck
bind = SUPER SHIFT, W, exec, noctalia msg panel-toggle gravityboots/gwallcards:info
```

## Keys

| Key | Action |
| --- | --- |
| `←` `→` / `h` `l` | Previous / next |
| `Shift+h` `Shift+l` | Jump by the number of side cards |
| `Home` `End` | First / last wallpaper |
| `Enter` | Apply and close |
| `Space` | Apply and keep browsing |
| `z` | Swap between the deck and info views |
| `f` | Search (info view). Arrows and Enter still work while you type |
| `Esc` | Close |

You can also click a side card to move to it, or click the centre card to apply it. In the info
view, click a colour circle to show only that colour group, and click it again to show all.

## Settings

Settings → Plugins → gwallcards. Noctalia's settings page has no section headers, so each group
starts with a toggle that expands it:

| Group | What's in it |
| --- | --- |
| Deck | first view, cards per side, loop around, slide speed, live preview |
| Cards & preview | side card width, dimming, gap, corner radius, info bar name width, thumbnail size |
| Video playback | output (empty = all), start delay, video layer, scaling, FPS cap, loop, pause/stop when covered |
| Colour groups | hue ranges for each colour and the cut-off for "mono" |
| Files & thumbnails | folders (empty = Noctalia's wallpaper folder), extensions per type, thumbnail jobs |
| Extra gSlapper options | anything else to pass to gSlapper's `-o` |

**Panel size** is the one thing that isn't a setting. Noctalia reads a panel's size from the
manifest only, so edit the `width` / `height` of the two `[[panel]]` entries at the top of
`gwallcards/plugin.toml`. Keep the info panel 60 px taller than the deck so the cards stay the same
size when you swap views. The cards resize to fill the panel, and a size bigger than the screen is
clamped to the screen.

## Command line

```sh
noctalia msg plugin gravityboots/gwallcards:service all toggle            # open/close the last used view
noctalia msg plugin gravityboots/gwallcards:service all apply /path/to/file
noctalia msg plugin gravityboots/gwallcards:service all stop              # stop gSlapper, back to Noctalia's wallpaper
noctalia msg plugin gravityboots/gwallcards:service all rescan
noctalia msg plugin gravityboots/gwallcards:service all status            # write what's running to the log
```

## How switching works

Noctalia's own wallpaper stays on the whole time, and there is only ever one gSlapper.

| From → to | What happens |
| --- | --- |
| image → image | Noctalia switches with its normal transition. |
| image → video | Noctalia transitions to a frame of the video and gSlapper starts on top straight away (or after *Video start delay*). |
| video → video | The running gSlapper switches file. |
| video → image | gSlapper is stopped, which reveals that frame, then Noctalia transitions to the image. |

The frame also drives your colour scheme, so colours follow videos as well.

## Troubleshooting

Every switch is logged, step by step, with timings and each command's result:

```sh
tail -f ~/.local/state/noctalia/plugins/data/gravityboots/gwallcards/gwallcards.log
```

Keep that open, switch wallpapers, and the log shows what happened at each step. For a snapshot of
what is running right now (gSlapper processes, gSlapper's own status, Noctalia's wallpaper per
output), run:

```sh
noctalia msg plugin gravityboots/gwallcards:service all status
```

- **Video never appears** (you only see its still frame): your compositor stacks Noctalia's wallpaper
  above gSlapper. Set *Video playback → Video layer* to **Bottom**.
- **More than one `gslapper` in the status output**: something else started one (another plugin or an
  autostart). gwallcards only stops the ones it started.

## Files

```
gwallcards/
├── plugin.toml           manifest, panel sizes, settings
├── service.luau          finds wallpapers, makes thumbnails, sorts by colour, applies them
├── deck.luau, info.luau  the two panels (one line each)
├── lib/view.luau         the card deck and info bar, keys, animation
├── lib/media.luau        small helpers: file types, colour groups, sorting, card layout
├── widget.luau           bar widget
└── translations/en.json  all text
```

Thumbnails and video frames are cached in the plugin's data folder, so only new or changed files
are processed.

## Credits

- Inspired by [Wallcards](https://github.com/noctalia-dev/legacy-v4-plugins/tree/main/wallcards) by
  [tonigineer](https://github.com/tonigineer), a Noctalia v4 plugin (MIT). It was the reference for the
  card-deck idea and the key layout. gwallcards is a from-scratch rewrite for Noctalia v5's plugin
  API and shares no code with it.
- Video playback by [gSlapper](https://github.com/Nomadcxx/gSlapper) (GPL-3.0). gwallcards runs it as
  a separate program and doesn't include it.
- Built for [Noctalia](https://github.com/noctalia-dev/noctalia) (MIT).

## License

[MIT](LICENSE)
