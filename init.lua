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
--- - `PaperLine.height`             bar height in pixels (default: 48)
--- - `PaperLine.icon_size`          icon size in pixels (default: 25)
--- - `PaperLine.icon_padding`       gap between icons (default: 8)
--- - `PaperLine.bg_color`           bar background color table (default: fully transparent)
--- - `PaperLine.active_color`       highlight color for the focused window's icon (default: white @ 0.75 alpha)
--- - `PaperLine.inactive_alpha`     alpha for non-focused icons (default: 1)
--- - `PaperLine.max_icons`          max icons to draw; `nil` = all
--- - `PaperLine.click_to_focus`     clicking an icon focuses that window (default: true)
--- - `PaperLine.show_on_all_screens` show on every screen (default: true)
--- - `PaperLine.position`           "top" (default, overlays menubar) or "below_menubar"
--- - `PaperLine.x_offset`           horizontal offset in pixels from default position (default: 960)
--- - `PaperLine.y_offset`           vertical offset in pixels from default position (default: -3)
--- - `PaperLine.start_hidden`       start with bar hidden (default: false)
--- - `PaperLine.per_screen`         per-monitor config overrides (default: `{}`, see below)
--- - `PaperLine.paperwm_source_fn`  override the PaperWM source for tests (see below)
---
--- # Per-monitor configuration
---
--- `PaperLine.per_screen` maps a screen identifier to a table of config
--- overrides. Any of the fields above may be overridden per monitor; an
--- unspecified field falls back to the top-level default. The screen
--- identifier is matched, in order, against the screen's UUID
--- (`hs.screen:getUUID()`), its name (`hs.screen:name()`), and finally its
--- numeric id as a string. UUID and name are stable across reboots; numeric
--- ids are not.
---
--- ```lua
--- PaperLine.per_screen = {
---     ["Built-in Retina Display"] = { icon_size = 18, height = 32, x_offset = 600 },
---     ["LG UltraFine"]            = { icon_size = 32, y_offset = 0 },
--- }
--- ```
---
--- # Test seam
---
--- `PaperLine.paperwm_source_fn` is the only seam exposed for testing. It
--- defaults to a function that loads PaperWM via `hs.loadSpoon` and returns a
--- source with `:windowList(space) → items`. Tests can override it to return a
--- fake source that responds to the same method. The fake adapter is the
--- second adapter that turns the seam from hypothetical to real.
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
PaperLine.icon_size = 25
PaperLine.icon_padding = 8
PaperLine.bg_color = { red = 0, green = 0, blue = 0, alpha = 0 }
PaperLine.active_color = { red = 1, green = 1, blue = 1, alpha = 0.75 }
PaperLine.inactive_alpha = 1
PaperLine.max_icons = nil
PaperLine.click_to_focus = true
PaperLine.show_on_all_screens = true
PaperLine.position = "top"
PaperLine.x_offset = 960
PaperLine.y_offset = -3
PaperLine.start_hidden = false
-- per-monitor overrides: screen identifier (UUID, name, or numeric id as
-- string) -> table of any of the config fields above
PaperLine.per_screen = {}
PaperLine.default_hotkeys = {
    toggle = { { "cmd", "shift" }, "p" },
    refresh = { { "cmd", "shift" }, "r" },
}

-- =====================================================================
-- ADAPTERS / SHIMS
-- =====================================================================

-- module-level state
local is_started = false
local is_visible = true
local refresh_timer = nil
local window_filter = nil
local screen_watcher = nil
local space_watcher = nil
local app_watcher = nil
local icon_cache = {}

-- (4) config snapshot — read once at :redraw entry, threaded downstream
local function read_cfg()
    return {
        height = PaperLine.height,
        icon_size = PaperLine.icon_size,
        icon_padding = PaperLine.icon_padding,
        bg_color = PaperLine.bg_color,
        active_color = PaperLine.active_color,
        inactive_alpha = PaperLine.inactive_alpha,
        max_icons = PaperLine.max_icons,
        click_to_focus = PaperLine.click_to_focus,
        show_on_all_screens = PaperLine.show_on_all_screens,
        position = PaperLine.position,
        x_offset = PaperLine.x_offset,
        y_offset = PaperLine.y_offset,
    }
end

-- compute a stable key for the current position-affecting config
---@param cfg table
---@return string
local function position_key(cfg)
    return string.format("%s|%d|%d", cfg.position or "top", cfg.x_offset or 0, cfg.y_offset or 0)
end

-- resolve the per-monitor override table for a screen. Matches the screen's
-- UUID, then its name, then its numeric id (as a string) against the keys of
-- PaperLine.per_screen. Returns nil when no entry matches.
---@param screen userdata hs.screen
---@return table|nil
local function screen_override(screen)
    local overrides = PaperLine.per_screen
    if type(overrides) ~= "table" then
        return nil
    end
    local candidates = {}
    if screen.getUUID then
        candidates[#candidates + 1] = screen:getUUID()
    end
    if screen.name then
        candidates[#candidates + 1] = screen:name()
    end
    candidates[#candidates + 1] = tostring(screen:id())
    for _, key in ipairs(candidates) do
        if key and overrides[key] then
            return overrides[key]
        end
    end
    return nil
end

-- shallow-merge a per-monitor override onto the base config. Override values
-- win; unspecified fields fall back to the base. Returns base unchanged when
-- there is no override.
---@param base table
---@param override table|nil
---@return table
local function merge_cfg(base, override)
    if not override then
        return base
    end
    local merged = {}
    for k, v in pairs(base) do
        merged[k] = v
    end
    for k, v in pairs(override) do
        merged[k] = v
    end
    return merged
end

---@param screen userdata hs.screen
---@return userdata hs.geometry.rect
local function full_frame(screen)
    if screen.fullFrame then
        return screen:fullFrame()
    end
    return screen:frame()
end

---@param screen userdata hs.screen
---@return userdata hs.geometry.rect
local function visible_frame(screen)
    if screen.visibleFrame then
        return screen:visibleFrame()
    end
    return screen:frame()
end

-- icon source — memoised per (bundle id, size)
---@param bundle_id string|nil
---@param size number
---@return userdata|nil hs.image
local function cached_icon(bundle_id, size)
    if not bundle_id or bundle_id == "" then
        return nil
    end
    local key = bundle_id .. "@" .. size
    if icon_cache[key] then
        return icon_cache[key]
    end
    if not (Image and Image.imageFromAppBundle) then
        return nil
    end
    local img = Image.imageFromAppBundle(bundle_id)
    if not img then
        return nil
    end
    if img.setSize then
        img = img:setSize({ w = size, h = size })
    end
    icon_cache[key] = img
    return img
end

-- (3) PaperWM source — real seam. The default adapter wraps the live module;
-- tests can override PaperLine.paperwm_source_fn to plug in a fake.
local function default_paperwm_source()
    local ok, mod = pcall(hs.loadSpoon, "PaperWM")
    if not ok or not mod then
        return nil
    end
    return {
        windowList = function(_, space)
            return mod.state.windowList(space)
        end,
    }
end
PaperLine.paperwm_source_fn = default_paperwm_source

-- canvas factory — produces a configured hs.canvas with click handler wired
---@param screen userdata hs.screen
---@param cfg table
---@param click_to_focus_getter fun(): boolean
---@param on_click fun(id: string)
---@return userdata canvas
local function make_canvas(screen, cfg, click_to_focus_getter, on_click)
    local visible = visible_frame(screen)
    local full = full_frame(screen)
    local base_x, base_y
    if cfg.position == "top" then
        base_x = full.x
        base_y = full.y
    else
        base_x = visible.x
        base_y = visible.y
    end
    local c = Canvas.new({
        x = base_x + (cfg.x_offset or 0),
        y = base_y + (cfg.y_offset or 0),
        w = visible.w,
        h = cfg.height,
    })
    c:behavior({
        hs.canvas.windowBehaviors.canJoinAllSpaces,
        hs.canvas.windowBehaviors.stationary,
        hs.canvas.windowBehaviors.ignoresCycle,
    })
    c:level(Canvas.windowLevels.status)
    c:mouseCallback(function(_canvas, event, id, _)
        if event == "mouseUp" and click_to_focus_getter() and type(id) == "string" then
            on_click(id)
        end
    end)
    return c
end

-- =====================================================================
-- (1) LAYOUT
-- =====================================================================

-- (1a) layout_slots — pure-ish, data-in / data-out.
-- Walks items in PaperWM order, decides per-item geometry, and emits a list
-- of project-specific "slots". No canvas DSL knowledge lives here.
---@param items table[]
---@param focused_id number|nil
---@param canvas_w number
---@param cfg table
---@param icon_resolver fun(bundle_id: string|nil, size: number): userdata|nil
---@return table[]
local function layout_slots(items, focused_id, canvas_w, cfg, icon_resolver)
    local slots = {}
    slots[#slots + 1] = { kind = "background", x = 0, y = 0, w = canvas_w, h = cfg.height }
    local x_cursor = cfg.icon_padding
    local y_icon = math.floor((cfg.height - cfg.icon_size) / 2)
    local limit = cfg.max_icons and math.min(#items, cfg.max_icons) or #items
    for i = 1, limit do
        local item = items[i]
        local is_focused = focused_id and item.window and item.window:id() == focused_id
        if is_focused then
            slots[#slots + 1] = {
                kind = "focusRing",
                x = x_cursor - 0.5,
                y = y_icon - 0.5,
                w = cfg.icon_size + 1,
                h = cfg.icon_size + 1,
            }
        end
        local icon = icon_resolver(item.bundle_id, cfg.icon_size)
        if icon then
            slots[#slots + 1] = {
                kind = "icon",
                x = x_cursor,
                y = y_icon,
                w = cfg.icon_size,
                h = cfg.icon_size,
                image = icon,
                alpha = is_focused and 1.0 or cfg.inactive_alpha,
                id = "icon_" .. i,
            }
        else
            local name = (item.app and item.app:name()) or "?"
            slots[#slots + 1] = {
                kind = "fallback",
                x = x_cursor,
                y = y_icon,
                w = cfg.icon_size,
                h = cfg.icon_size,
                letter = name:sub(1, 1):upper(),
                id = "icon_" .. i,
            }
        end
        x_cursor = x_cursor + cfg.icon_size + cfg.icon_padding
    end
    return slots
end

-- (1b) render_slots — the only place that knows the Hammerspoon canvas DSL.
-- Flattens project-specific slots into canvas element tables.
---@param slots table[]
---@param cfg table
---@return table[]
local function render_slots(slots, cfg)
    local elements = {}
    for _, s in ipairs(slots) do
        if s.kind == "background" then
            elements[#elements + 1] = {
                type = "rectangle",
                fillColor = cfg.bg_color,
                strokeColor = { red = 0, green = 0, blue = 0, alpha = 0 },
                frame = { x = s.x, y = s.y, w = s.w, h = s.h },
            }
        elseif s.kind == "focusRing" then
            elements[#elements + 1] = {
                type = "rectangle",
                fillColor = { red = 0, green = 0, blue = 0, alpha = 0 },
                strokeColor = cfg.active_color,
                strokeWidth = 1.5,
                roundedRectRadii = { xRadius = 6, yRadius = 6 },
                frame = { x = s.x, y = s.y, w = s.w, h = s.h },
            }
        elseif s.kind == "icon" then
            elements[#elements + 1] = {
                type = "image",
                image = s.image,
                frame = { x = s.x, y = s.y, w = s.w, h = s.h },
                imageAlpha = s.alpha,
                id = s.id,
                trackMouseUp = cfg.click_to_focus,
            }
        elseif s.kind == "fallback" then
            elements[#elements + 1] = {
                type = "rectangle",
                fillColor = { red = 0.25, green = 0.25, blue = 0.25, alpha = 0.8 },
                frame = { x = s.x, y = s.y, w = s.w, h = s.h },
                id = s.id,
                trackMouseUp = cfg.click_to_focus,
            }
            elements[#elements + 1] = {
                type = "text",
                text = s.letter,
                textColor = { white = 1, alpha = 0.9 },
                textSize = math.floor(s.h * 0.65),
                textAlignment = "center",
                frame = { x = s.x, y = s.y, w = s.w, h = s.h },
            }
        end
    end
    return elements
end

-- transform a source's window list into the item shape the layout expects
---@param source table|nil
---@param space number
---@return table[]
local function collect_windows(source, space)
    local out = {}
    if not source or not space then
        return out
    end
    local list = source:windowList(space)
    if not list then
        return out
    end
    for col, rows in ipairs(list) do
        for row, w in ipairs(rows) do
            local app = w:application()
            out[#out + 1] = {
                window = w,
                app = app,
                bundle_id = app and app:bundleID() or nil,
                title = w:title(),
                space = space,
                col = col,
                row = row,
            }
        end
    end
    return out
end

-- =====================================================================
-- (2) CANVAS MANAGER — owns the three per-screen maps
-- =====================================================================

local CanvasManager = {}
CanvasManager.__index = CanvasManager

function CanvasManager.new()
    return setmetatable({ _canvas = {}, _key = {}, _items = {} }, CanvasManager)
end

-- ensure a canvas exists for `screen`, recreating it when position config
-- changed since the last build. The click routing is wired at creation.
---@param screen userdata hs.screen
---@param cfg table
---@return userdata canvas
function CanvasManager:get_or_create(screen, cfg)
    local sid = screen:id()
    local key = position_key(cfg)
    local canvas = self._canvas[sid]
    if canvas and self._key[sid] == key then
        return canvas
    end
    if canvas then
        canvas:delete()
    end
    local mgr = self
    canvas = make_canvas(screen, cfg, function()
        return PaperLine.click_to_focus
    end, function(id)
        local prefix, idx_str = id:match("^(icon_)(%d+)$")
        if not prefix then
            return
        end
        local idx = tonumber(idx_str)
        local items = mgr._items[sid]
        if items and idx and idx >= 1 and idx <= #items then
            local target = items[idx]
            if target and target.window then
                target.window:focus()
            end
        end
    end)
    self._canvas[sid] = canvas
    self._key[sid] = key
    return canvas
end

-- render new elements on the screen's canvas, persist items for click routing
---@param screen userdata hs.screen
---@param items table[]
---@param elements table[]
---@param cfg table
function CanvasManager:show_with(screen, items, elements, cfg)
    local canvas = self:get_or_create(screen, cfg)
    canvas:replaceElements(elements)
    canvas:show()
    self._items[screen:id()] = items
end

---@param sid number
function CanvasManager:evict_screen(sid)
    if self._canvas[sid] then
        self._canvas[sid]:delete()
        self._canvas[sid] = nil
        self._key[sid] = nil
        self._items[sid] = nil
    end
end

function CanvasManager:evict_all()
    for sid in pairs(self._canvas) do
        self:evict_screen(sid)
    end
end

---@param alive_sids table number → true
function CanvasManager:gc_to(alive_sids)
    for sid in pairs(self._canvas) do
        if not alive_sids[sid] then
            self:evict_screen(sid)
        end
    end
end

---@param sid number
---@return table[]|nil
function CanvasManager:items_for(sid)
    return self._items[sid]
end

-- exposed for :dump
---@return table
function CanvasManager:all_items()
    return self._items
end

-- =====================================================================
-- INSTANCE
-- =====================================================================

local canvas_manager = CanvasManager.new()

-- =====================================================================
-- PAPERLINE METHODS
-- =====================================================================

---@param screen userdata hs.screen
---@param source table
---@param cfg table
local function redraw_screen(screen, source, cfg)
    local sid = screen:id()
    cfg = merge_cfg(cfg, screen_override(screen))
    local space = Spaces.activeSpaceOnScreen(screen)
    local items = space and collect_windows(source, space) or {}

    if #items == 0 or not is_visible then
        canvas_manager:evict_screen(sid)
        return
    end

    local focused_window = Window.focusedWindow()
    local focused_id = focused_window and focused_window:id() or nil

    local canvas_w = visible_frame(screen).w
    local slots = layout_slots(items, focused_id, canvas_w, cfg, cached_icon)
    local elements = render_slots(slots, cfg)
    canvas_manager:show_with(screen, items, elements, cfg)
end

---redraw the bar on all configured screens
function PaperLine:redraw()
    if not is_started then
        return
    end
    local cfg = read_cfg()
    local source = PaperLine.paperwm_source_fn and PaperLine.paperwm_source_fn() or nil
    if not source then
        canvas_manager:evict_all()
        self.logger.w("PaperWM.spoon not loaded — PaperLine bar will be empty")
        return
    end

    local screens = cfg.show_on_all_screens and Screen.allScreens() or { Screen.mainScreen() }
    local alive = {}
    for _, screen in ipairs(screens) do
        alive[screen:id()] = true
        redraw_screen(screen, source, cfg)
    end
    canvas_manager:gc_to(alive)
end

---debounced redraw — coalesces bursts of events into one repaint
function PaperLine:refresh()
    if refresh_timer and refresh_timer:running() then
        return
    end
    refresh_timer = Timer.doAfter(0.05, function()
        refresh_timer = nil
        self:redraw()
    end)
end

---start watching for window, space, screen, and app events
---@return PaperLine
function PaperLine:start()
    if is_started then
        return self
    end
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
    }, function()
        PaperLine:refresh()
    end)

    screen_watcher = Screen.watcher
        .new(function()
            PaperLine:refresh()
        end)
        :start()
    space_watcher = Spaces.watcher
        .new(function()
            PaperLine:refresh()
        end)
        :start()
    app_watcher = hs.application.watcher
        .new(function()
            PaperLine:refresh()
        end)
        :start()

    self:redraw()
    return self
end

---stop watching for events and hide the bar
---@return PaperLine
function PaperLine:stop()
    if not is_started then
        return self
    end
    is_started = false
    if window_filter then
        window_filter:unsubscribeAll()
        window_filter = nil
    end
    if screen_watcher then
        screen_watcher:stop()
        screen_watcher = nil
    end
    if space_watcher then
        space_watcher:stop()
        space_watcher = nil
    end
    if app_watcher then
        app_watcher:stop()
        app_watcher = nil
    end
    canvas_manager:evict_all()
    return self
end

---toggle the bar's visibility
function PaperLine:toggle()
    is_visible = not is_visible
    if is_visible then
        self:redraw()
    else
        canvas_manager:evict_all()
    end
end

---bind hotkeys to PaperLine actions
---@param mapping table action name -> hotkey table
function PaperLine:bindHotkeys(mapping)
    local actions = {
        toggle = function()
            self:toggle()
        end,
        refresh = function()
            self:refresh()
        end,
    }
    for name, key in pairs(mapping or {}) do
        if actions[name] then
            hs.hotkey.bind(key[1], key[2], actions[name])
        end
    end
end

---print the current internal state for debugging
function PaperLine:dump()
    local function count(t)
        local n = 0
        for _ in pairs(t) do
            n = n + 1
        end
        return n
    end
    print("--- PaperLine State ---")
    print(string.format("is_started: %s", tostring(is_started)))
    print(string.format("is_visible: %s", tostring(is_visible)))
    print(string.format("cached icons: %d", count(icon_cache)))
    for sid, items in pairs(canvas_manager:all_items()) do
        print(string.format("screen %d items (%d):", sid, #items))
        for i, item in ipairs(items) do
            print(
                string.format(
                    "  [%d] c%d r%d %s — %s",
                    i,
                    item.col,
                    item.row,
                    item.app and item.app:name() or "?",
                    item.title
                )
            )
        end
    end
    print("-----------------------")
end

return PaperLine
