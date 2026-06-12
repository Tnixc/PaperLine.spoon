--- === PaperLine.spoon ===
---
--- A menu bar item that displays PaperWM's window ordering as a row of app
--- icons. Mirrors `PaperWM.state.windowList(space)` — left-to-right across
--- columns, top-to-bottom within each column — and renders the row as a single
--- composited image in the system menu bar. Clicking the item drops down a menu
--- listing every window so you can jump straight to one.
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
--- - `PaperLine.icon_padding`   gap between icons, also the inset above/below each icon (default: 3). Icons fill the fixed menu bar height minus this padding, so a smaller padding means larger icons.
--- - `PaperLine.active_color`   highlight color for the focused window's icon (default: white @ 0.75 alpha)
--- - `PaperLine.inactive_alpha` alpha for non-focused icons (default: 1)
--- - `PaperLine.max_icons`      max icons to draw; `nil` = all
--- - `PaperLine.menu_icon_size` icon size in the dropdown menu (default: 16)
--- - `PaperLine.click_to_focus` clicking a menu entry focuses that window (default: true)
--- - `PaperLine.show_titles`    show window titles next to app names in the menu (default: true)
--- - `PaperLine.screen`         which screen's windows to mirror; `nil` = main screen (see below)
--- - `PaperLine.autosave_name`  menu bar autosave name so macOS restores position (default: "PaperLine")
--- - `PaperLine.start_hidden`   start with the item hidden (default: false)
--- - `PaperLine.paperwm_source_fn` override the PaperWM source for tests (see below)
---
--- # Choosing a screen
---
--- The system menu bar is a single, global UI element, so PaperLine cannot draw a
--- different row per display. Instead, it mirrors the windows of one screen's
--- active space. By default that is the main screen (`hs.screen.mainScreen()`).
---
--- To pin it to a specific display, set `PaperLine.screen` to a screen
--- identifier. The value is matched, in order, against the screen's UUID
--- (`hs.screen:getUUID()`), its name (`hs.screen:name()`), and finally its
--- numeric id as a string. UUID and name are stable across reboots; numeric ids
--- are not.
---
--- Run this in the Hammerspoon console to list your screens:
---
--- ```lua
--- for i, s in ipairs(hs.screen.allScreens()) do
---     print(string.format("  [%d] %s  (UUID: %s)", i, s:name(), s:getUUID()))
--- end
--- ```
---
--- ```lua
--- PaperLine.screen = "Built-in Retina Display"
--- ```
---
--- # Test seam
---
--- `PaperLine.paperwm_source_fn` is the only seam exposed for testing. It
--- defaults to a function that loads PaperWM via `hs.loadSpoon` and returns a
--- source with `:windowList(space) → items`. Tests can override it to return a
--- fake source that responds to the same method.
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
local Menubar <const> = hs.menubar
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
PaperLine.version = "2.0"
PaperLine.author = "tnixc"
PaperLine.license = "MIT"
PaperLine.homepage = "https://github.com/.../PaperLine.spoon"

PaperLine.logger = Logger.new(PaperLine.name)

-- The system menu bar has a fixed thickness, so the composite image height is
-- not configurable. Icons are sized to fill that height minus padding, so they
-- are always as large as the menu bar allows.
local BAR_HEIGHT <const> = 22

-- configuration with sensible defaults
PaperLine.icon_padding = 3
PaperLine.active_color = { red = 1, green = 1, blue = 1, alpha = 0.75 }
PaperLine.inactive_alpha = 1
PaperLine.max_icons = nil
PaperLine.menu_icon_size = 16
PaperLine.click_to_focus = true
PaperLine.show_titles = true
-- which screen's windows to mirror; nil = main screen. May be a UUID, name, or
-- numeric id as a string.
PaperLine.screen = nil
PaperLine.autosave_name = "PaperLine"
PaperLine.start_hidden = false
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

-- config snapshot — read once at :redraw entry, threaded downstream
local function read_cfg()
    local padding = PaperLine.icon_padding
    -- icons fill the fixed bar height minus padding above and below, so they
    -- are always as large as the menu bar allows.
    local icon_size = math.max(1, BAR_HEIGHT - padding * 2)
    return {
        height = BAR_HEIGHT,
        icon_size = icon_size,
        icon_padding = padding,
        bg_color = { red = 0, green = 0, blue = 0, alpha = 0 },
        active_color = PaperLine.active_color,
        inactive_alpha = PaperLine.inactive_alpha,
        max_icons = PaperLine.max_icons,
        menu_icon_size = PaperLine.menu_icon_size,
        click_to_focus = PaperLine.click_to_focus,
        show_titles = PaperLine.show_titles,
        screen = PaperLine.screen,
    }
end

-- resolve which screen to mirror. nil/"main" selects the main screen; otherwise
-- the value is matched against each screen's UUID, name, then numeric id.
---@param cfg table
---@return userdata|nil hs.screen
local function resolve_screen(cfg)
    local want = cfg.screen
    if not want or want == "main" then
        return Screen.mainScreen()
    end
    want = tostring(want)
    for _, screen in ipairs(Screen.allScreens()) do
        local candidates = {}
        if screen.getUUID then
            candidates[#candidates + 1] = screen:getUUID()
        end
        if screen.name then
            candidates[#candidates + 1] = screen:name()
        end
        candidates[#candidates + 1] = tostring(screen:id())
        for _, key in ipairs(candidates) do
            if key == want then
                return screen
            end
        end
    end
    -- requested screen is not currently connected; fall back to main
    return Screen.mainScreen()
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

-- PaperWM source — real seam. The default adapter wraps the live module;
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

-- =====================================================================
-- (1) LAYOUT
-- =====================================================================

-- (1a) layout_slots — pure-ish, data-in / data-out.
-- Walks items in PaperWM order, decides per-item geometry, and emits a list
-- of project-specific "slots". No canvas DSL knowledge lives here. The image
-- contracts to its content: width is the icons plus symmetric padding.
---@param items table[]
---@param focused_id number|nil
---@param cfg table
---@param icon_resolver fun(bundle_id: string|nil, size: number): userdata|nil
---@return table[] slots, number content_w
local function layout_slots(items, focused_id, cfg, icon_resolver)
    local slots = {}
    local limit = cfg.max_icons and math.min(#items, cfg.max_icons) or #items
    local content_w = cfg.icon_padding + limit * (cfg.icon_size + cfg.icon_padding)
    slots[#slots + 1] = { kind = "background", x = 0, y = 0, w = content_w, h = cfg.height }
    local x_cursor = cfg.icon_padding
    local y_icon = math.floor((cfg.height - cfg.icon_size) / 2)
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
    return slots, content_w
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
            }
        elseif s.kind == "fallback" then
            elements[#elements + 1] = {
                type = "rectangle",
                fillColor = { red = 0.25, green = 0.25, blue = 0.25, alpha = 0.8 },
                frame = { x = s.x, y = s.y, w = s.w, h = s.h },
                id = s.id,
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

-- (1c) composite_image — render the slots into an off-screen canvas and grab
-- the result as a single hs.image suitable for a menu bar icon. The canvas is
-- never shown; it exists only to be rasterised.
---@param items table[]
---@param focused_id number|nil
---@param cfg table
---@return userdata|nil hs.image, number content_w
local function composite_image(items, focused_id, cfg)
    local slots, content_w = layout_slots(items, focused_id, cfg, cached_icon)
    local elements = render_slots(slots, cfg)
    local c = Canvas.new({ x = 0, y = 0, w = content_w, h = cfg.height })
    c:replaceElements(elements)
    local img = c:imageFromCanvas()
    c:delete()
    return img, content_w
end

-- (1d) build_menu — the dropdown listing every window. Each entry shows the
-- app icon and (optionally) the window title, and focuses the window on click.
---@param items table[]
---@param cfg table
---@return table[] menuTable
local function build_menu(items, cfg)
    local menu = {}
    for _, item in ipairs(items) do
        local name = (item.app and item.app:name()) or "?"
        local title = name
        if cfg.show_titles and item.title and item.title ~= "" then
            title = name .. " — " .. item.title
        end
        local entry = {
            title = title,
            image = cached_icon(item.bundle_id, cfg.menu_icon_size),
        }
        if cfg.click_to_focus then
            local window = item.window
            entry.fn = function()
                if window then
                    window:focus()
                end
            end
        else
            entry.disabled = true
        end
        menu[#menu + 1] = entry
    end
    return menu
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
-- (2) MENU BAR MANAGER — owns the single system menu bar item
-- =====================================================================

local MenubarManager = {}
MenubarManager.__index = MenubarManager

function MenubarManager.new()
    return setmetatable({ _item = nil, _in_bar = false, _items = {} }, MenubarManager)
end

-- lazily create the underlying hs.menubar item
---@param cfg table
---@return userdata|nil menubar item
function MenubarManager:ensure(cfg)
    if self._item then
        return self._item
    end
    if not Menubar then
        return nil
    end
    self._item = Menubar.new(true, cfg.autosave_name or PaperLine.autosave_name)
    self._in_bar = self._item ~= nil
    return self._item
end

-- update the menu bar item with a fresh composite icon and dropdown menu
---@param items table[]
---@param image userdata|nil hs.image
---@param menu table[]
---@param cfg table
function MenubarManager:show_with(items, image, menu, cfg)
    local item = self:ensure(cfg)
    if not item then
        return
    end
    if not self._in_bar then
        item:returnToMenuBar()
        self._in_bar = true
    end
    item:setTitle(nil)
    item:setIcon(image, false) -- false: keep app-icon color (not a template)
    item:setMenu(menu)
    self._items = items
end

-- pull the item out of the menu bar (e.g. nothing to show, or hidden)
function MenubarManager:hide()
    if self._item and self._in_bar then
        self._item:removeFromMenuBar()
        self._in_bar = false
    end
    self._items = {}
end

-- destroy the item entirely
function MenubarManager:destroy()
    if self._item then
        self._item:delete()
        self._item = nil
    end
    self._in_bar = false
    self._items = {}
end

---@return table[]
function MenubarManager:items()
    return self._items
end

---@return boolean
function MenubarManager:in_bar()
    return self._in_bar
end

-- =====================================================================
-- INSTANCE
-- =====================================================================

local menubar_manager = MenubarManager.new()

-- =====================================================================
-- PAPERLINE METHODS
-- =====================================================================

---redraw the menu bar item from the chosen screen's active space
function PaperLine:redraw()
    if not is_started then
        return
    end
    local cfg = read_cfg()
    cfg.autosave_name = PaperLine.autosave_name

    if not is_visible then
        menubar_manager:hide()
        return
    end

    local source = PaperLine.paperwm_source_fn and PaperLine.paperwm_source_fn() or nil
    if not source then
        menubar_manager:hide()
        self.logger.w("PaperWM.spoon not loaded — PaperLine bar will be empty")
        return
    end

    local screen = resolve_screen(cfg)
    local space = screen and Spaces.activeSpaceOnScreen(screen)
    local items = space and collect_windows(source, space) or {}

    if #items == 0 then
        menubar_manager:hide()
        return
    end

    local focused_window = Window.focusedWindow()
    local focused_id = focused_window and focused_window:id() or nil

    local image = composite_image(items, focused_id, cfg)
    local menu = build_menu(items, cfg)
    menubar_manager:show_with(items, image, menu, cfg)
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

---stop watching for events and remove the menu bar item
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
    menubar_manager:destroy()
    return self
end

---toggle the menu bar item's visibility
function PaperLine:toggle()
    is_visible = not is_visible
    if is_visible then
        self:redraw()
    else
        menubar_manager:hide()
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
    print(string.format("in_menubar: %s", tostring(menubar_manager:in_bar())))
    print(string.format("cached icons: %d", count(icon_cache)))
    local items = menubar_manager:items()
    print(string.format("items (%d):", #items))
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
    print("-----------------------")
end

return PaperLine
