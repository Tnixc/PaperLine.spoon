# PaperLine.spoon

<img width="290" height="59" alt="image" src="https://github.com/user-attachments/assets/eecb2ec6-7003-4c96-abd5-58c5981151f7" />


A Hammerspoon spoon that draws a status bar at the top of the screen with the
app icons of your currently focused PaperWM windows, in the same order as
`PaperWM.state.windowList(space)` — left-to-right across columns, top-to-bottom
within each column.

The focused window's icon is highlighted with a border, and clicking an icon
focuses that window. The bar appears on every screen, follows Mission Control
space changes, and respects PaperWM's tiling order in real time.

## Install

**! INSTALL THIS FIRST** https://github.com/mogenson/PaperWM.spoon

Clone to your Hammerspoon Spoons directory:

```sh
git clone https://github.com/tnixc/PaperLine.spoon ~/.hammerspoon/Spoons/PaperLine.spoon
```

## Usage

PaperLine depends on PaperWM.spoon. Load PaperWM first, then PaperLine:

```lua
PaperWM = hs.loadSpoon("PaperWM")
PaperWM:start()

PaperLine = hs.loadSpoon("PaperLine")
PaperLine:start()
```

## Hotkeys

```lua
PaperLine:bindHotkeys({
    toggle  = { { "cmd", "shift" }, "p" },
    refresh = { { "cmd", "shift" }, "r" },
})
```

`PaperLine:toggle()` is also exposed for binding to other gestures or menubar
items.

## Configuration

Set these on the `PaperLine` module before or after `:start()`. The bar will
re-read them on the next redraw.

| Key                    | Default                       | Description                                       |
| ---------------------- | ----------------------------- | ------------------------------------------------- |
| `height`               | `48`                          | Bar height in pixels                              |
| `icon_size`            | `25`                          | Icon size in pixels                               |
| `icon_padding`         | `8`                           | Gap between icons (also left/right edge padding)  |
| `bg_color`             | fully transparent             | Bar background color table                        |
| `active_color`         | white @ 0.75 alpha            | Border color for the focused window's icon        |
| `inactive_alpha`       | `1`                           | Alpha for non-focused icons                       |
| `max_icons`            | `nil`                         | Max icons to draw; `nil` = all                    |
| `click_to_focus`       | `true`                        | Click an icon to focus that window                |
| `show_on_all_screens`  | `true`                        | Show on every screen                              |
| `position`             | `"top"`                       | `"top"` (overlays menubar) or `"below_menubar"`   |
| `x_offset`             | `960`                         | Horizontal offset in pixels from default position |
| `y_offset`             | `-3`                          | Vertical offset in pixels from default position   |
| `start_hidden`         | `false`                       | If true, start with bar hidden                    |

Example:

```lua
PaperLine.height = 28
PaperLine.icon_size = 18
PaperLine.x_offset = 100    -- 100px from the left edge
PaperLine.y_offset = -4     -- 4px above the default position
PaperLine.bg_color = { red = 0.1, green = 0.1, blue = 0.1, alpha = 0.75 }
PaperLine:start()
```

## How it works

PaperLine subscribes to window, space, screen, and app events, and on each
change queries `PaperWM.state.windowList(space)` for the active space on each
screen. The result is drawn into a per-screen `hs.canvas` that sits just
below the system menu bar at `hs.canvas.windowLevels.status` (floating, on
all spaces, above the menubar).

Icons are loaded once per (bundle id, size) via `hs.image.imageFromAppBundle`
and cached in memory. Clicks on icons call `window:focus()` on the
corresponding PaperWM-tracked window.

If PaperWM isn't loaded, the bar is hidden with a warning. Start PaperWM and
the bar will appear on the next event (or call `PaperLine:refresh()`).

## Limitations

- The bar's content is driven by PaperWM's window list. Windows that are
  floating (per `PaperWM.floating.isFloating`) are not shown.
- Visibility in fullscreen apps follows macOS's normal window layering. Apps
  that aggressively hide other windows (some games, fullscreen video) may
  cover the bar.
- Icons are loaded lazily. The first time a bundle id appears the icon
  may take a moment to render.
