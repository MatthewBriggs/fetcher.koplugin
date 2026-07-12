-- Fetcher status bar
--
-- A persistent top-anchored bar that stays visible during a sync WITHOUT
-- blocking the reader — page-turns and other gestures pass through to whatever
-- is underneath. Trick: KOReader's UIManager stops event dispatch at the first
-- non-toast top widget; a widget with `toast = true` (the same contract the
-- built-in Notification widget uses) lets events propagate. The toast contract
-- also closes the widget on any event, so an onCloseWidget hook re-shows it on
-- the next UI tick — visually seamless.
--
-- API used by main.lua:
--   bar = StatusBar:new(sources_list, stage_label)
--   bar:show()
--   bar:setStage("Books")                    -- change the leading label
--   bar:addSource(id, display_text)          -- append a pending pill
--   bar:sourceRunning(id, subtitle)          -- ↻ current one
--   bar:sourceProgress(id, percent)          -- 0..100 during download
--   bar:sourceDone(id, ok)                   -- ✓ / ✗ final state
--   bar:finish("All done!", auto_close_sec)  -- swap to summary, self-close

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local StatusBar = {}
StatusBar.__index = StatusBar

local ROW_HEIGHT = Screen:scaleBySize(44)
local ICON_SIZE = Screen:scaleBySize(20)
local PROGRESS_W = Screen:scaleBySize(90)
local PROGRESS_H = Screen:scaleBySize(10)
local GAP = Screen:scaleBySize(10)
local PAD = Screen:scaleBySize(8)

function StatusBar:new()
    local o = setmetatable({}, self)
    o._stage_label = "Fetcher"
    o._pills = {}       -- { { id, display, state, widget, progress, subtitle } }
    o._by_id = {}       -- id -> pill index
    o:_build()
    return o
end

-- Compose the whole bar. Rebuilt whenever the pill list changes.
function StatusBar:_build()
    self._stage_widget = TextWidget:new{
        text = self._stage_label,
        face = Font:getFace("tfont", 18),
    }
    self._pills_group = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = GAP },
    }
    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = PAD },
        self._stage_widget,
        self._pills_group,
    }
    self._frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.default,
        padding = PAD,
        padding_top = PAD / 2,
        padding_bottom = PAD / 2,
        margin = 0,
        radius = 0,
        width = Screen:getWidth(),
        row,
    }
    -- toast = true is the escape hatch: taps/swipes propagate down to the
    -- reader instead of dying at the top of the stack.
    self._frame.toast = true

    -- The toast contract closes the widget on every input event; while we
    -- want it visible, re-show on the next tick. On a real close (finish),
    -- self._closed is set first so this becomes a no-op.
    local self_bar = self
    self._frame.onCloseWidget = function()
        if self_bar._closed then return end
        UIManager:nextTick(function()
            if not self_bar._closed then
                UIManager:show(self_bar._frame)
                self_bar:_redraw()
            end
        end)
    end
end

function StatusBar:_redraw()
    if self._closed or not self._frame then return end
    -- Only repaint the top strip, "fast" (low-flash) so frequent updates
    -- don't ghost the whole reader page. Height is bar height (with border).
    local h = ROW_HEIGHT + 2 * Size.border.default
    UIManager:setDirty(self._frame, "fast", Geom:new{
        x = 0, y = 0, w = Screen:getWidth(), h = h,
    })
end

function StatusBar:_rebuildFromState()
    local prev_showing = not self._closed and self._shown
    -- Preserve the running state, but rebuild widgets from scratch so
    -- HorizontalGroup layout re-runs with the new pill set.
    local saved = self._pills
    self:_build()
    self._pills = saved
    for _, pill in ipairs(self._pills) do
        pill.widget, pill.progress = self:_renderPill(pill)
        table.insert(self._pills_group, pill.widget)
        table.insert(self._pills_group, HorizontalSpan:new{ width = GAP })
    end
    if prev_showing then
        UIManager:show(self._frame)
        self:_redraw()
    end
end

-- A single "pill": [icon] name  or  [icon] name [progress]
function StatusBar:_renderPill(pill)
    local icon_name, dim = "circle", true
    if pill.state == "running" then icon_name, dim = "cre.render.reload", false
    elseif pill.state == "ok"   then icon_name, dim = "check", false
    elseif pill.state == "fail" then icon_name, dim = "close", false
    end
    -- Fall back to plain glyphs if the icon isn't available; check/close/cre
    -- come with KOReader (mdlight), so this rarely triggers.
    local icon
    local ok_icon, w = pcall(function()
        return IconWidget:new{
            icon = icon_name,
            width = ICON_SIZE,
            height = ICON_SIZE,
            dim = dim,
            alpha = true,
        }
    end)
    if ok_icon and w then
        icon = w
    else
        local glyph = "•"
        if pill.state == "running" then glyph = "↻"
        elseif pill.state == "ok"   then glyph = "✓"
        elseif pill.state == "fail" then glyph = "✗"
        end
        icon = TextWidget:new{ text = glyph, face = Font:getFace("smallinfofont", 18) }
    end

    local label_face = Font:getFace("smallinfofont", 18)
    local label = TextWidget:new{
        text = pill.display,
        face = label_face,
        fgcolor = (pill.state == "pending") and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
    }

    local children = {
        align = "center",
        icon,
        HorizontalSpan:new{ width = Size.span.horizontal_small },
        label,
    }

    -- A progress bar attaches only to the currently-running pill.
    local progress
    if pill.state == "running" then
        progress = ProgressWidget:new{
            width = PROGRESS_W,
            height = PROGRESS_H,
            percentage = (pill.percent or 0) / 100,
        }
        table.insert(children, HorizontalSpan:new{ width = Size.span.horizontal_default })
        table.insert(children, progress)
    end

    return HorizontalGroup:new(children), progress
end

-- Public API ---------------------------------------------------------------

function StatusBar:show()
    UIManager:show(self._frame)
    self._shown = true
    self:_redraw()
end

function StatusBar:setStage(label)
    self._stage_label = label
    self:_rebuildFromState()
end

function StatusBar:addSource(id, display)
    if self._by_id[id] then return end
    table.insert(self._pills, { id = id, display = display, state = "pending", percent = 0 })
    self._by_id[id] = #self._pills
    self:_rebuildFromState()
end

function StatusBar:sourceRunning(id, subtitle)
    local i = self._by_id[id]; if not i then return end
    local p = self._pills[i]
    p.state = "running"
    p.subtitle = subtitle
    p.percent = 0
    self:_rebuildFromState()
end

function StatusBar:sourceProgress(id, percent)
    local i = self._by_id[id]; if not i then return end
    local p = self._pills[i]
    p.percent = math.max(0, math.min(100, tonumber(percent) or 0))
    if p.progress and p.progress.setPercentage then
        p.progress:setPercentage(p.percent / 100)
        self:_redraw()
    end
end

function StatusBar:sourceDone(id, ok)
    local i = self._by_id[id]; if not i then return end
    self._pills[i].state = ok and "ok" or "fail"
    self:_rebuildFromState()
end

function StatusBar:finish(summary_label, auto_close_sec)
    self._stage_label = summary_label or "All done!"
    -- Drop the pills so the summary reads cleanly.
    self._pills = {}
    self._by_id = {}
    self:_rebuildFromState()
    if auto_close_sec and auto_close_sec > 0 then
        local self_bar = self
        UIManager:scheduleIn(auto_close_sec, function() self_bar:close() end)
    end
end

function StatusBar:close()
    self._closed = true
    if self._frame then
        UIManager:close(self._frame)
        UIManager:setDirty("all", "ui")
    end
    self._frame = nil
    self._shown = false
end

return StatusBar
