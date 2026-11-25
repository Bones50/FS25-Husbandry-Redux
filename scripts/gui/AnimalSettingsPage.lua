-- Husbandry Redux -- the SETTINGS page of this mod's own menu.
--
-- ONLY USED WHEN DISTRIBUTION REDUX IS ABSENT. With DR present the same rows are registered as a tab
-- on DR's settings page (AnimalSettings.install) and this file is never loaded. Both render
-- AnimalSettings.rows(), so there is ONE set of settings with one definition behind it -- including
-- the capability gating, which means the two DR-dependent rows read "(needs Distribution Redux)"
-- here exactly as they would on DR's page with an old DR.
--
-- THE ROWS ARE GENERIC. Eight slots in the XML, filled from whatever rows() returns and the rest
-- hidden -- so adding a setting costs a definition in AnimalSettings and nothing here. That is the
-- opposite of DR's own settings page, where each row is hand authored and a missing one means the
-- setting silently does not appear (DR 5.41), and it is the right trade for a page whose rows are
-- already defined in data.

AnimalSettingsPage = {}
local AnimalSettingsPage_mt = Class(AnimalSettingsPage, AnimalMenuPage)

AnimalSettingsPage.MAX_ROWS = 8

function AnimalSettingsPage.new(target, custom_mt)
    local self = AnimalMenuPage.new(target, custom_mt or AnimalSettingsPage_mt)
    self.pageName = "ANIMALREDUX_SETTINGS"
    self._rows    = {}
    return self
end

function AnimalSettingsPage:onGuiSetupFinished()
    AnimalSettingsPage:superClass().onGuiSetupFinished(self)
end

---Read the rows and paint them. Called on open and after every change, so a setter that alters
-- another row (or refuses) is reflected immediately rather than at the next open.
function AnimalSettingsPage:renderRows()
    -- THE ROWS COME FROM THE CURRENT TAB (AnimalPageTabs, 2026-10-20): HR's own first, then any
    -- mod that registered with HusbandryRedux.API. With no other provider this is exactly
    -- AnimalSettings.rows() and the strip stays hidden, so HR alone is unchanged.
    local rows = {}
    local tabs = (AnimalPageTabs ~= nil) and AnimalPageTabs.tabs("settings") or nil
    if tabs ~= nil then
        local shown = AnimalPageTabs.draw(self, tabs)
        self:applyStripSpace(shown > 0)
        local t = tabs[self.currentTab or 1] or tabs[1]
        if t ~= nil then
            local ok, r = pcall(t.content)
            if ok and type(r) == "table" then rows = r end
        end
    elseif AnimalSettings ~= nil and AnimalSettings.rows ~= nil then
        local ok, r = pcall(AnimalSettings.rows)
        if ok and type(r) == "table" then rows = r end
    end
    self._rows = rows

    local shown = 0
    for i = 1, AnimalSettingsPage.MAX_ROWS do
        if rows[i] ~= nil then shown = shown + 1 end
        local row   = self["arRow" .. i]
        local opt   = self["arOpt" .. i]
        local title = self["arTitle" .. i]
        local tip   = self["arTip" .. i]
        local def   = rows[i]

        if row ~= nil and row.setVisible ~= nil then row:setVisible(def ~= nil) end
        -- THE ALTERNATING TINT, applied HERE rather than from an onCreate.
        --
        -- Without it a row draws its profile's default image colour, which is opaque WHITE -- the
        -- whole block came up as a white slab with the light-on-dark text almost invisible on it.
        -- DR's own settings rows carry onCreate="onCreateSettingRow" for this; ours cannot, because
        -- these rows are SHOWN AND HIDDEN as the row count changes and banding must follow the
        -- VISIBLE order, not the order the elements happen to be declared in (DR 5.88 records the
        -- same reasoning for its extension rows).
        if row ~= nil and row.setImageColor ~= nil then
            local pal = (InGameMenuSettingsFrame ~= nil) and InGameMenuSettingsFrame.COLOR_ALTERNATING or nil
            local band = pal ~= nil and pal[(shown % 2) == 0] or nil
            if band ~= nil then
                pcall(function() row:setImageColor(nil, table.unpack(band)) end)
            else
                -- No palette to borrow: draw nothing rather than the profile's white, so the page
                -- degrades to plain rows on the menu background instead of an unreadable slab.
                pcall(function() row:setImageColor(nil, 0, 0, 0, 0) end)
            end
        end
        if def == nil then
            -- ACTIVELY BLANK AN UNUSED SLOT. These elements persist across renders, so a row left
            -- holding the previous set's text would show it again the moment the count shrank.
            if title ~= nil and title.setText ~= nil then title:setText("") end
            if tip ~= nil and tip.setText ~= nil then tip:setText("") end
        else
            if title ~= nil and title.setText ~= nil then title:setText(tostring(def.title or def.id or "")) end
            if tip ~= nil then
                if tip.setText ~= nil then tip:setText(tostring(def.tooltip or "")) end
                if tip.setVisible ~= nil then tip:setVisible(def.tooltip ~= nil) end
            end
            if opt ~= nil then
                if opt.setTexts ~= nil then pcall(opt.setTexts, opt, def.strings) end
                local state = 1
                if def.get ~= nil then
                    local okG, v = pcall(def.get)
                    if okG and type(v) == "number" then state = v end
                end
                -- ONE ARGUMENT. MultiTextOptionElement:setState(state, forceEvent) RAISES the click
                -- callback when the second is true -- the opposite of the "apply this quietly" it
                -- reads like. With renderRows called from the click handler, a truthy second argument
                -- is an unbounded redraw -> click -> set -> redraw loop; DR 5.88 records it shipping
                -- once and taking the page down with a C stack overflow.
                if opt.setState ~= nil then pcall(opt.setState, opt, state) end
                opt.arRowIndex = i
            end
        end
    end

    -- RE-FLOW after changing visibility, or the surviving rows keep the gaps the hidden ones left.
    if self.boxLayout ~= nil and self.boxLayout.invalidateLayout ~= nil then
        pcall(self.boxLayout.invalidateLayout, self.boxLayout)
    end
end

---MAKE ROOM FOR THE STRIP, only while it shows. fs25_settingsLayout fills the container from the
-- top, so a strip at y=0 would sit on row one. The tabbed profile pins the list to the BOTTOM and
-- shrinks it by 46px, taking the space off the top (DR 5.87b). `with` is read on PROFILES only, so
-- it cannot be an attribute on the element (DR 5.87a).
-- applyProfile then setSize: setSize is what recomputes the anchor deltas, without which the new
-- size is silently discarded on an element already laid out (DR 5.90). Both the list and the
-- slider's wrapper move, or the scrollbar keeps the old height.
function AnimalSettingsPage:applyStripSpace(hasStrip)
    local want = hasStrip and "ARSettingsLayoutTabbed" or "fs25_settingsLayout"
    for _, el in ipairs({ self.boxLayout, self.settingsSliderBox }) do
        if el ~= nil and el.applyProfile ~= nil and el.profile ~= want then
            pcall(el.applyProfile, el, want, false, true)
            if el.setSize ~= nil then pcall(el.setSize, el) end
        end
    end
end

---A and D (the menu asks the page, duck-typed) and the tab clicks.
function AnimalSettingsPage:stepPageTabBy(delta)
    if AnimalPageTabs == nil then return false end
    if not AnimalPageTabs.step(self, AnimalPageTabs.tabs("settings"), delta) then return false end
    self:renderRows()
    return true
end

function AnimalSettingsPage:onTabSlot(n)
    if AnimalPageTabs == nil then return end
    local tabs = AnimalPageTabs.tabs("settings")
    if tabs[n] == nil or n == (self.currentTab or 1) then return end
    self.currentTab = n
    self:renderRows()
end
function AnimalSettingsPage:onTab1() return self:onTabSlot(1) end
function AnimalSettingsPage:onTab2() return self:onTabSlot(2) end
function AnimalSettingsPage:onTab3() return self:onTabSlot(3) end
function AnimalSettingsPage:onTab4() return self:onTabSlot(4) end

function AnimalSettingsPage:onFrameOpen()
    AnimalSettingsPage:superClass().onFrameOpen(self)
    self:renderRows()
end

---A player moved a selector. Hand it to whoever owns the row.
--
-- PCALL'D, and the row is re-read afterwards: a setter may refuse (the capability-gated ones do), and
-- the selector must then snap back rather than sit on a value that is not in effect.
function AnimalSettingsPage:onOptionChanged(state, element)
    local i   = element ~= nil and element.arRowIndex or nil
    local def = i ~= nil and self._rows[i] or nil
    if def == nil or def.set == nil then return end
    pcall(def.set, state)
    self:renderRows()
end
