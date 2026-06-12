# PaperLine.spoon

<img width="290" height="59" alt="image" src="https://github.com/user-attachments/assets/eecb2ec6-7003-4c96-abd5-58c5981151f7" />


A Hammerspoon spoon that lives in the system menu bar and shows the app icons of
your currently focused PaperWM windows, in the same order as
`PaperWM.state.windowList(space)` — left-to-right across columns, top-to-bottom
within each column.

The whole row is composited into a single menu bar icon. The focused window's
icon is highlighted with a border. Clicking the item drops down a menu listing
every window, and selecting one focuses it. The item follows Mission Control
space changes and respects PaperWM's tiling order in real time.

Because the system menu bar is a single, global element, PaperLine mirrors one
screen's windows at a time (the main screen by default). See
[Choosing a screen](#choosing-a-screen).

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

`PaperLine:toggle()` is also exposed for binding to other gestures. Toggling
removes the item from the menu bar and returns it.

## Configuration

Set these on the `PaperLine` module before or after `:start()`. The item will
re-read them on the next redraw.

| Key              | Default            | Description                                                       |
| ---------------- | ------------------ | ----------------------------------------------------------------- |
| `icon_padding`   | `3`                | Gap between icons, and the inset above/below each icon. Icons fill the fixed menu bar height minus this padding, so a smaller value means larger icons. |
| `active_color`   | white @ 0.75 alpha | Border color for the focused window's icon                        |
| `inactive_alpha` | `1`                | Alpha for non-focused icons                                       |
| `max_icons`      | `nil`              | Max icons to draw; `nil` = all                                    |
| `menu_icon_size` | `16`               | Icon size in the dropdown menu                                    |
| `click_to_focus` | `true`             | Click a menu entry to focus that window                           |
| `show_titles`    | `true`             | Show window titles next to app names in the menu                  |
| `screen`         | `nil`              | Which screen's windows to mirror; `nil` = main                    |
| `autosave_name`  | `"PaperLine"`      | Menu bar autosave name (macOS restores position)                  |
| `start_hidden`   | `false`            | If true, start with the item hidden                               |

The menu bar has a fixed height, so the icon size is not directly configurable —
icons are always drawn as large as the bar allows. Lower `icon_padding` for
bigger icons, raise it for smaller ones with more breathing room.

Example:

```lua
PaperLine.icon_padding = 2
PaperLine.show_titles = false
PaperLine:start()
```

## Choosing a screen

The system menu bar is a single, global UI element, so PaperLine cannot draw a
different row per display. Instead it mirrors the windows of one screen's active
space. By default that is the main screen (`hs.screen.mainScreen()`).

To pin it to a specific display, set `PaperLine.screen` to a screen identifier.
The value is matched, in order, against:

1. the screen's UUID (`hs.screen:getUUID()`),
2. its name (`hs.screen:name()`),
3. its numeric id as a string (`tostring(hs.screen:id())`).

Prefer UUID or name — both are stable across reboots, whereas numeric ids are
not. If the requested screen isn't connected, PaperLine falls back to the main
screen. Run this in the Hammerspoon console to list your screens:

```lua
for i, s in ipairs(hs.screen.allScreens()) do
    print(string.format("  [%d] %s  (UUID: %s)", i, s:name(), s:getUUID()))
end
```

Example output:

```
  [1] Built-in Retina Display  (UUID: 37D8832A-2D66-02CA-B9F7-8F30A301B230)
  [2] GF270M                   (UUID: A127AC03-26F1-452E-A399-51B091E616F7)
```

```lua
PaperLine.screen = "Built-in Retina Display"
PaperLine:start()
```

## How it works

PaperLine subscribes to window, space, screen, and app events, and on each
change queries `PaperWM.state.windowList(space)` for the active space on the
chosen screen. The result is laid out and rendered into an off-screen
`hs.canvas`, rasterised to a single `hs.image` with `imageFromCanvas()`, and set
as the icon of an `hs.menubar` item. A dropdown menu is built alongside, with one
entry per window.

Icons are loaded once per (bundle id, size) via `hs.image.imageFromAppBundle`
and cached in memory. Selecting a menu entry calls `window:focus()` on the
corresponding PaperWM-tracked window.

If PaperWM isn't loaded, the item is removed from the menu bar with a warning.
Start PaperWM and it will reappear on the next event (or call
`PaperLine:refresh()`).

## Limitations

- The content is driven by PaperWM's window list. Windows that are floating (per
  `PaperWM.floating.isFloating`) are not shown.
- The menu bar is global, so only one screen's windows can be shown at a time.
  Use `PaperLine.screen` to choose which.
- Icons are loaded lazily. The first time a bundle id appears the icon may take
  a moment to render.
- Clicking the menu bar item opens the dropdown; per-icon click-to-focus is not
  possible because the row is a single composited image. Focus a window by
  selecting it from the dropdown instead.
