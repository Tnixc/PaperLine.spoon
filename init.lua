--- === PaperLine.spoon ===
---
--- A status bar that displays PaperWM's window ordering as a row of app
--- icons at the top of the screen. Mirrors `PaperWM.state.windowList(space)`
--- — left-to-right across columns, top-to-bottom within each column.
---
--- # Usage
---
--- PaperLine depends on PaperWM.spoon. Load PaperWM first, then:
---
--- ```lua
--- PaperWM = hs.loadSpoon("PaperWM")
--- PaperWM:start()
---
--- PaperLine = hs.loadSpoon("PaperLine")
--- PaperLine:start()
--- ```
---
--- # Configuration
---
--- Set these on the `PaperLine` module before or after `:start()`:
---
--- - `PaperLine.height`             bar height in pixels (default: 32)
--- - `PaperLine.icon_size`          icon size in pixels (default: 22)
--- - `PaperLine.icon_padding`       gap between icons (default: 6)
--- - `PaperLine.bg_color`           bar background color table
--- - `PaperLine.active_color`       highlight color for the focused window's icon
--- - `PaperLine.inactive_alpha`     alpha for non-focused icons (default: 0.7)
--- - `PaperLine.max_icons`          max icons to draw; `nil` = all
--- - `PaperLine.click_to_focus`     clicking an icon focuses that window (default: true)
--- - `PaperLine.show_on_all_screens` show on every screen (default: true)
--- - `PaperLine.position`           "top" (default, overlays menubar) or "below_menubar"
--- - `PaperLine.x_offset`           horizontal offset in pixels from default position (default: 0)
--- - `PaperLine.y_offset`           vertical offset in pixels from default position (default: 0)
--- - `PaperLine.start_hidden`       start with bar hidden (default: false)
---
--- # Hotkeys
---
--- ```lua
--- PaperLine:bindHotkeys({
---     toggle  = { { "cmd", "shift" }, "p" },
---     refresh = { { "cmd", "shift" }, "r" },
--- })
--- ```
local Canvas <const> = hs.canvas
local Screen <const> = hs.screen
local Spaces <const> = hs.spaces
local Timer <const> = hs.timer
local Window <const> = hs.window
local Image <const> = hs.image
local Logger <const> = hs.logger
local WindowFilter <const> = hs.window.filter

local PaperLine = {}
PaperLine.__index = PaperLine

PaperLine.name = "PaperLine"
PaperLine.version = "1.0"
PaperLine.author = "tnixc"
PaperLine.license = "MIT"
PaperLine.homepage = "https://github.com/.../PaperLine.spoon"

PaperLine.logger = Logger.new(PaperLine.name)

-- configuration with sensible defaults
PaperLine.height = 48
PaperLine.icon_size = 28
PaperLine.icon_padding = 6
PaperLine.bg_color = { red = 0, green = 0, blue = 0, alpha = 0 }
PaperLine.active_color = { red = 1, green = 0.55, blue = 0.10, alpha = 0.95 }
PaperLine.inactive_alpha = 1
PaperLine.max_icons = nil
PaperLine.click_to_focus = true
PaperLine.show_on_all_screens = true
PaperLine.position = "top"
PaperLine.x_offset = 970
PaperLine.y_offset = -2
PaperLine.start_hidden = false
PaperLine.default_hotkeys = {
    toggle = { { "cmd", "shift" }, "p" },
    refresh = { { "cmd", "shift" }, "r" },
}

-- internal state
local canvas_per_screen = {}     -- [screen_id:number] = canvas
local canvas_position_key = {}   -- [screen_id:number] = string identifying position config
local last_items = {}           -- [screen_id:number] = items table (for click-to-focus)
local icon_cache = {}           -- [bundle_id@size] = hs.image
local refresh_timer = nil
local is_started = false
local is_visible = true
local window_filter = nil
local screen_watcher = nil
local space_watcher = nil
local app_watcher = nil

---compute a stable key for the current position-affecting config
---@return string
local function position_key()
    return string.format("%s|%d|%d",
        PaperLine.position or "top",
        PaperLine.x_offset or 0,
        PaperLine.y_offset or 0)
end

---find the loaded PaperWM module (returns nil if not loaded)
---@return table|nil
local function get_paperwm()
    local ok, mod = pcall(hs.loadSpoon, "PaperWM")
    if not ok or not mod then return nil end
    return mod
end

---get an app icon, cached by (bundle id, size)
---@param bundle_id string|nil
---@param size number
---@return userdata|nil hs.image
local function cached_icon(bundle_id, size)
    if not bundle_id or bundle_id == "" then return nil end
    local key = bundle_id .. "@" .. size
    if icon_cache[key] then return icon_cache[key] end
    if not (Image and Image.imageFromAppBundle) then return nil end
    local img = Image.imageFromAppBundle(bundle_id)
    if not img then return nil end
    if img.setSize then img = img:setSize({ w = size, h = size }) end
    icon_cache[key] = img
    return img
end

---collect windows in PaperWM order for a space
---@param paperwm table
---@param space number
---@return table[] items: { window, app, bundle_id, title, space, col, row }
local function collect_windows(paperwm, space)
    local out = {}
    if not paperwm or not space then return out end
    local list = paperwm.state.windowList(space)
    if not list then return out end
    for col, rows in ipairs(list) do
        for row, w in ipairs(rows) do
            local app = w:application()
            table.insert(out, {
                window = w,
                app = app,
                bundle_id = app and app:bundleID() or nil,
                title = w:title(),
                space = space,
                col = col,
                row = row,
            })
        end
    end
    return out
end

---return the full screen frame, including the menubar/dock area
---compatible with both old (frame = full) and new (fullFrame = full) Hammerspoon
---@param screen userdata hs.screen
---@return userdata hs.geometry.rect
local function full_frame(screen)
    if screen.fullFrame then return screen:fullFrame() end
    return screen:frame()
end

---return the visible screen frame, excluding the menubar/dock area
---compatible with both old (visibleFrame = visible) and new (frame = visible) Hammerspoon
---@param screen userdata hs.screen
---@return userdata hs.geometry.rect
local function visible_frame(screen)
    if screen.visibleFrame then return screen:visibleFrame() end
    return screen:frame()
end

---create a new canvas for a screen and wire up its click handler
---@param screen userdata hs.screen
---@return userdata canvas
local function make_canvas(screen)
    local visible = visible_frame(screen)
    local full = full_frame(screen)
    local base_x, base_y
    if PaperLine.position == "top" then
        base_x = full.x
        base_y = full.y
    else
        base_x = visible.x
        base_y = visible.y
    end
    local c = Canvas.new({
        x = base_x + (PaperLine.x_offset or 0),
        y = base_y + (PaperLine.y_offset or 0),
        w = visible.w,
        h = PaperLine.height,
    })
    c:behavior({
        hs.canvas.windowBehaviors.canJoinAllSpaces,
        hs.canvas.windowBehaviors.stationary,
        hs.canvas.windowBehaviors.ignoresCycle,
    })
    c:level(Canvas.windowLevels.status)
    c:mouseCallback(function(canvas, event, id, _)
        if event == "mouseUp" and PaperLine.click_to_focus and type(id) == "string" then
            local prefix, idx_str = id:match("^(icon_)(%d+)$")
            if prefix then
                local idx = tonumber(idx_str)
                local items = last_items[screen:id()]
                if items and idx and idx >= 1 and idx <= #items then
                    local target = items[idx]
                    if target and target.window then target.window:focus() end
                end
            end
        end
    end)
    return c
end

---build the canvas element list for a set of items
---@param items table[]
---@param focused_id number|nil
---@param canvas_w number
---@return table[] elements
local function build_elements(items, focused_id, canvas_w)
    local elements = {}

    table.insert(elements, {
        type = "rectangle",
        fillColor = PaperLine.bg_color,
        strokeColor = { red = 0, green = 0, blue = 0, alpha = 0 },
        frame = { x = 0, y = 0, w = canvas_w, h = PaperLine.height },
    })

    local x_cursor = PaperLine.icon_padding
    local y_icon = math.floor((PaperLine.height - PaperLine.icon_size) / 2)
    local limit = PaperLine.max_icons and math.min(#items, PaperLine.max_icons) or #items

    for i = 1, limit do
        local item = items[i]
        local is_focused = focused_id and item.window and item.window:id() == focused_id

        if is_focused then
            table.insert(elements, {
                type = "rectangle",
                fillColor = { red = 0, green = 0, blue = 0, alpha = 0 },
                strokeColor = PaperLine.active_color,
                strokeWidth = 2,
                frame = {
                    x = x_cursor - 2,
                    y = y_icon - 2,
                    w = PaperLine.icon_size + 4,
                    h = PaperLine.icon_size + 4,
                },
            })
        end

        local icon = cached_icon(item.bundle_id, PaperLine.icon_size)
        if icon then
            table.insert(elements, {
                type = "image",
                image = icon,
                frame = {
                    x = x_cursor,
                    y = y_icon,
                    w = PaperLine.icon_size,
                    h = PaperLine.icon_size,
                },
                imageAlpha = is_focused and 1.0 or PaperLine.inactive_alpha,
                id = "icon_" .. i,
                trackMouseUp = PaperLine.click_to_focus,
            })
        else
            local name = (item.app and item.app:name()) or "?"
            local letter = name:sub(1, 1):upper()
            table.insert(elements, {
                type = "rectangle",
                fillColor = { red = 0.25, green = 0.25, blue = 0.25, alpha = 0.8 },
                frame = {
                    x = x_cursor,
                    y = y_icon,
                    w = PaperLine.icon_size,
                    h = PaperLine.icon_size,
                },
                id = "icon_" .. i,
                trackMouseUp = PaperLine.click_to_focus,
            })
            table.insert(elements, {
                type = "text",
                text = letter,
                textColor = { white = 1, alpha = 0.9 },
                textSize = math.floor(PaperLine.icon_size * 0.65),
                textAlignment = "center",
                frame = {
                    x = x_cursor,
                    y = y_icon,
                    w = PaperLine.icon_size,
                    h = PaperLine.icon_size,
                },
            })
        end

        x_cursor = x_cursor + PaperLine.icon_size + PaperLine.icon_padding
    end

    return elements
end

---redraw a single screen's bar
---@param screen userdata hs.screen
---@param paperwm table|nil
local function redraw_screen(screen, paperwm)
    local sid = screen:id()
    local space = Spaces.activeSpaceOnScreen(screen)
    local items = paperwm and space and collect_windows(paperwm, space) or {}

    if #items == 0 or not is_visible then
        if canvas_per_screen[sid] then
            canvas_per_screen[sid]:delete()
            canvas_per_screen[sid] = nil
        end
        canvas_position_key[sid] = nil
        last_items[sid] = nil
        return
    end

    local focused_window = Window.focusedWindow()
    local focused_id = focused_window and focused_window:id() or nil

    local canvas = canvas_per_screen[sid]
    local key = position_key()
    if not canvas or canvas_position_key[sid] ~= key then
        if canvas then canvas:delete() end
        canvas = make_canvas(screen)
        canvas_per_screen[sid] = canvas
        canvas_position_key[sid] = key
    end

    local canvas_w = canvas:frame().w
    canvas:replaceElements(build_elements(items, focused_id, canvas_w))
    canvas:show()
    last_items[sid] = items
end

---redraw the bar on all configured screens
function PaperLine:redraw()
    if not is_started then return end
    local paperwm = get_paperwm()
    if not paperwm then
        for sid, canvas in pairs(canvas_per_screen) do
            canvas:delete()
            canvas_per_screen[sid] = nil
        end
        last_items = {}
        self.logger.w("PaperWM.spoon not loaded — PaperLine bar will be empty")
        return
    end

    local screens = PaperLine.show_on_all_screens and Screen.allScreens() or { Screen.mainScreen() }
    local alive = {}
    for _, screen in ipairs(screens) do
        alive[screen:id()] = true
        redraw_screen(screen, paperwm)
    end
    for sid, canvas in pairs(canvas_per_screen) do
        if not alive[sid] then
            canvas:delete()
            canvas_per_screen[sid] = nil
            canvas_position_key[sid] = nil
            last_items[sid] = nil
        end
    end
end

---debounced redraw — coalesces bursts of events into one repaint
function PaperLine:refresh()
    if refresh_timer and refresh_timer:running() then return end
    refresh_timer = Timer.doAfter(0.05, function()
        refresh_timer = nil
        self:redraw()
    end)
end

---start watching for window, space, screen, and app events
---@return PaperLine
function PaperLine:start()
    if is_started then return self end
    is_started = true
    is_visible = not PaperLine.start_hidden

    window_filter = WindowFilter.new()
    window_filter:subscribe({
        WindowFilter.windowVisible,
        WindowFilter.windowNotVisible,
        WindowFilter.windowDestroyed,
        WindowFilter.windowFocused,
        WindowFilter.windowFullscreened,
        WindowFilter.windowUnfullscreened,
    }, function() PaperLine:refresh() end)

    screen_watcher = Screen.watcher.new(function() PaperLine:refresh() end):start()
    space_watcher = Spaces.watcher.new(function() PaperLine:refresh() end):start()
    app_watcher = hs.application.watcher.new(function() PaperLine:refresh() end):start()

    self:redraw()
    return self
end

---stop watching for events and hide the bar
---@return PaperLine
function PaperLine:stop()
    if not is_started then return self end
    is_started = false
    if window_filter then window_filter:unsubscribeAll() window_filter = nil end
    if screen_watcher then screen_watcher:stop() screen_watcher = nil end
    if space_watcher then space_watcher:stop() space_watcher = nil end
    if app_watcher then app_watcher:stop() app_watcher = nil end
    for sid, canvas in pairs(canvas_per_screen) do
        canvas:delete()
        canvas_per_screen[sid] = nil
        canvas_position_key[sid] = nil
    end
    last_items = {}
    return self
end

---toggle the bar's visibility
function PaperLine:toggle()
    is_visible = not is_visible
    if is_visible then
        self:redraw()
    else
        for sid, canvas in pairs(canvas_per_screen) do
            canvas:delete()
            canvas_per_screen[sid] = nil
            canvas_position_key[sid] = nil
        end
    end
end

---bind hotkeys to PaperLine actions
---@param mapping table action name -> hotkey table
function PaperLine:bindHotkeys(mapping)
    local actions = {
        toggle = function() self:toggle() end,
        refresh = function() self:refresh() end,
    }
    for name, key in pairs(mapping or {}) do
        if actions[name] then
            hs.hotkey.bind(key[1], key[2], actions[name])
        end
    end
end

---print the current internal state for debugging
function PaperLine:dump()
    print("--- PaperLine State ---")
    print(string.format("is_started: %s", tostring(is_started)))
    print(string.format("is_visible: %s", tostring(is_visible)))
    print(string.format("cached icons: %d", (function() local n=0 for _ in pairs(icon_cache) do n=n+1 end return n end)()))
    for sid, items in pairs(last_items) do
        print(string.format("screen %d items (%d):", sid, #items))
        for i, item in ipairs(items) do
            print(string.format("  [%d] c%d r%d %s — %s",
                i, item.col, item.row,
                item.app and item.app:name() or "?",
                item.title))
        end
    end
    print("-----------------------")
end

return PaperLine
