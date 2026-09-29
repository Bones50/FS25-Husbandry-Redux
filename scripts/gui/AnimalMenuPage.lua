-- Husbandry Redux -- the base class every page of AR's own menu extends.
--
-- ONLY USED WHEN DISTRIBUTION REDUX IS ABSENT. With DR installed, HerdInspectorPage extends DR's
-- DistributionMenuPage exactly as it always has, so a player running both mods gets bit-for-bit the
-- behaviour they have now. HusbandryRedux picks the base at install time; this is the fallback half.
--
-- A SLIM PORT, NOT A COPY. DR's DistributionMenuPage is 279 lines and roughly a third of it is the
-- Hour/Month/Year period selector and windowStats, which read DR's OWN LEDGERS -- there is nothing
-- for them to read without DR, and HerdInspectorPage overrides initPeriodOption with its own anyway.
-- Porting them would have shipped dead code that looks load-bearing. What is here is exactly what
-- AR's page actually uses:
--   * TabbedMenuFrameElement, the base game's own page class
--   * the footer button plumbing (setMenuButtonInfo / applyFooterButtons)
--   * onFrameOpen focus handling
--   * the timed refresh that drives `self._realtimeLists`
--
-- THE REFRESH PACING IS PORTED IN FULL, and that is deliberate rather than tidy-minded. It is not
-- decoration: DR 5.46 measured a farm where an unthrottled menu refresh froze the game outright, and
-- the duty-cycle rule (never spend more than 5% of wall-clock refreshing) is what keeps a big farm
-- usable. AR's Herd Inspector re-enumerates every barn on the map on the same tick, so it has the
-- same exposure and wants the same governor.

AnimalMenuPage = {}

local AnimalMenuPage_mt = Class(AnimalMenuPage, TabbedMenuFrameElement)

function AnimalMenuPage.new(target, custom_mt)
    local self = TabbedMenuFrameElement.new(target, custom_mt or AnimalMenuPage_mt)
    self.pageName = "ANIMALREDUX_PAGE"
    return self
end

function AnimalMenuPage:initialize()
    self.backButtonInfo = {
        inputAction = InputAction.MENU_BACK,
        text = (g_i18n ~= nil and g_i18n:getText("button_back")) or "Back",
    }
    self.menuButtonInfo = { self.backButtonInfo }
end

function AnimalMenuPage:onFrameOpen()
    AnimalMenuPage:superClass().onFrameOpen(self)
    self:setMenuButtonInfoDirty()
    -- Sound suppressed around the focus, or opening the page plays the list's selection click at the
    -- player for something they did not do.
    self:setSoundSuppressed(true)
    if self.boxLayout ~= nil then
        FocusManager:setFocus(self.boxLayout)
    end
    self:setSoundSuppressed(false)
end

function AnimalMenuPage:onFrameClose()
    AnimalMenuPage:superClass().onFrameClose(self)
end

---The full button set this page could show. Kept so a page can later show a SUBSET without losing
-- the rest -- applyFooterButtons is how it puts a narrowed list up.
---NEVER STORE NIL. TabbedMenu:assignMenuButtonInfo indexes this table without checking it
-- (TabbedMenu.lua:335), so a page left with a nil set throws on EVERY mouse event for as long as it
-- is the current page -- observed as a wall of "attempt to index nil with number". The base class
-- documents nil as "reset", but nothing then puts a usable set back, so reset in practice means
-- crash. Falling back to Back-only keeps the footer honest and the menu alive.
function AnimalMenuPage:setMenuButtonInfo(buttons)
    if buttons == nil then buttons = { self.backButtonInfo or {
        inputAction = InputAction.MENU_BACK,
        text = (g_i18n ~= nil and g_i18n:getText("button_back")) or "Back",
    } } end
    self._allButtons = buttons
    AnimalMenuPage:superClass().setMenuButtonInfo(self, buttons)
end

function AnimalMenuPage:applyFooterButtons(vis)
    self:setMenuButtonInfo(vis)                     -- same nil guard, one path
    if self.setMenuButtonInfoDirty ~= nil then self:setMenuButtonInfoDirty() end
end

---Does this page already carry a usable footer set?
--
-- `menuButtonInfo` is initialised to an EMPTY TABLE by TabbedMenuFrameElement.new, never to nil --
-- so a `== nil` test is always false and reads as "it already has buttons" when it has none. That
-- exact mistake left the Settings and Help pages with an empty footer.
function AnimalMenuPage:hasFooterButtons()
    local b = self.menuButtonInfo
    return type(b) == "table" and #b > 0
end

-- ---------------------------------------------------------------------------
-- THE TIMED REFRESH, and the governor on it
--
-- A page names the lists that carry live figures in `self._realtimeLists`; this re-reads them on a
-- timer. The timer is NOT fixed: it is paced from what a refresh actually COSTS, so a farm big
-- enough to hurt slows its own menu down instead of stuttering (DR 5.46).
--
-- THE RULE IS A DUTY CYCLE, NOT A THRESHOLD. Never spend more than 1/REFRESH_DUTY of wall-clock
-- time refreshing, so the interval is PROPORTIONAL to the cost. DR measured the alternative -- a
-- threshold-and-double scheme sent a merely-large farm straight to the cap, i.e. figures 32 seconds
-- old, where under three would have done.
-- ---------------------------------------------------------------------------
AnimalMenuPage.REALTIME_REFRESH_MS = 500
AnimalMenuPage.REFRESH_DUTY  = 20      -- at most 1/20th (5%) of the time spent refreshing
AnimalMenuPage.MAX_INTERVAL  = 60      -- never stretch beyond a minute
AnimalMenuPage.COST_SMOOTH   = 0.5     -- weight of the newest sample
AnimalMenuPage._refreshCost  = 0

function AnimalMenuPage.resetRefreshPacing()
    AnimalMenuPage._refreshCost = 0
end

---SMOOTHED, so one unlucky frame cannot pin the interval: a single 2 s spike on an otherwise fast
-- farm decays back within a handful of refreshes rather than sticking.
function AnimalMenuPage.noteRefreshCost(sec)
    if type(sec) ~= "number" or sec < 0 then return end
    local s = AnimalMenuPage.COST_SMOOTH
    AnimalMenuPage._refreshCost = (AnimalMenuPage._refreshCost or 0) * (1 - s) + sec * s
end

---Seconds between refreshes, or nil for "do not refresh on a timer at all".
function AnimalMenuPage.refreshSeconds()
    local v = AnimalMenuPage.REALTIME_REFRESH_MS / 1000
    -- The player's rate is a FLOOR, never a ceiling: choosing a fast refresh on a farm that can
    -- afford it still gets it.
    local want = (AnimalMenuPage._refreshCost or 0) * AnimalMenuPage.REFRESH_DUTY
    if want < v then want = v end
    if want > AnimalMenuPage.MAX_INTERVAL then want = AnimalMenuPage.MAX_INTERVAL end
    return want
end

function AnimalMenuPage:refreshRealtimeLists()
    local names = self._realtimeLists
    -- _focusing: a selection event is mid-flight, and reloading under it fights the player's cursor.
    if names == nil or self._focusing then return end
    local t0 = (getTimeSec ~= nil) and getTimeSec() or nil
    if self.rebuildRealtimeData ~= nil then pcall(function() self:rebuildRealtimeData() end) end
    self._focusing = true
    for i = 1, #names do
        local list = self[names[i]]
        if list ~= nil and list.reloadData ~= nil then
            pcall(function() list:reloadData() end)
        end
    end
    self._focusing = false
    -- TIMED AROUND THE WHOLE THING -- the row rebuild AND the cell repopulate -- because that is what
    -- actually costs the frame. Timing only half of it would pace against the cheaper half.
    if t0 ~= nil then AnimalMenuPage.noteRefreshCost(getTimeSec() - t0) end
end

function AnimalMenuPage:update(dt)
    local sc = AnimalMenuPage:superClass()
    if sc.update ~= nil then sc.update(self, dt) end

    local every = AnimalMenuPage.refreshSeconds()
    if self._realtimeLists ~= nil and every ~= nil then
        local now = (getTimeSec ~= nil) and getTimeSec() or nil
        if now ~= nil then
            if self._rtLast == nil or (now - self._rtLast) >= every then
                self._rtLast = now
                pcall(function() self:refreshRealtimeLists() end)
            end
        end
    end
end

-- FULL TEXT ON HOVER for any cell the layout cut short (TextTip.lua, 2026-09-29).
if TextTip ~= nil and TextTip.install ~= nil then TextTip.install(AnimalMenuPage) end
