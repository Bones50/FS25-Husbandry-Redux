-- Husbandry Redux -- the USER GUIDE page of this mod's own menu.
--
-- ONLY USED WHEN DISTRIBUTION REDUX IS ABSENT. With DR present the same topics are registered as a
-- tab on DR's User Guide page (AnimalHelp.install), and this file is never loaded. The CONTENT is
-- the same either way: both read AnimalHelp.topics(), so there is one guide, not two.
--
-- TABS: HR's own guide, plus any mod that registered with HusbandryRedux.API (AnimalPageTabs, built
-- 2026-10-20 once Production Redux became the caller 31.0 was waiting for). The strip shows only
-- when there are two or more.

AnimalHelpPage = {}
local AnimalHelpPage_mt = Class(AnimalHelpPage, AnimalMenuPage)

-- Wrap width in CHARACTERS. The body column is 1168px at 16px text; a character averages about 8px
-- there, so ~132 fits. Deliberately conservative: a line that overruns is CLIPPED, not wrapped, and
-- a slightly short line costs nothing while a clipped one loses words off the right edge.
local WRAP_COLS = 128

function AnimalHelpPage.new(target, custom_mt)
    local self = AnimalMenuPage.new(target, custom_mt or AnimalHelpPage_mt)
    self.pageName     = "ANIMALREDUX_HELP"
    self.topicRows    = {}
    self.lines        = {}
    self.currentTopic = 1
    return self
end

---Split `body` into display rows, wrapping at WRAP_COLS and marking headings.
--
-- A LINE IS A ROW, because the body is rendered by a SmoothList rather than a text box: that is what
-- makes a long topic scrollable and what lets a heading be styled differently from its paragraph.
-- Blank lines are KEPT as empty rows -- they are the paragraph spacing, and dropping them runs the
-- whole guide together.
local function buildLines(body, cols)
    local out = {}
    if type(body) ~= "string" then return out end
    for raw in (body .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("%s+$", "")
        -- "## " marks a sub-heading, matching the convention AnimalHelp's guide is written in.
        local head, text = false, line
        local stripped = line:match("^##%s*(.*)$")
        if stripped ~= nil then head, text = true, stripped end

        if text == "" then
            out[#out + 1] = { text = "", head = false }
        else
            -- Greedy word wrap. Never breaks INSIDE a word: a wrapped identifier or a fill-type name
            -- split across two rows is far harder to read than a short line.
            local cur = ""
            for word in text:gmatch("%S+") do
                if cur == "" then
                    cur = word
                elseif #cur + 1 + #word <= cols then
                    cur = cur .. " " .. word
                else
                    out[#out + 1] = { text = cur, head = head }
                    cur = word
                    head = false            -- only the FIRST row of a wrapped heading is styled
                end
            end
            if cur ~= "" then out[#out + 1] = { text = cur, head = head } end
        end
    end
    return out
end

---The CURRENT TAB's topics (AnimalPageTabs, 2026-10-20). With no other provider registered this
-- is exactly AnimalHelp.topics() and the strip stays hidden.
local function topicsOf(page)
    if AnimalPageTabs ~= nil then
        local tabs = AnimalPageTabs.tabs("help")
        local t = tabs[(page ~= nil and page.currentTab) or 1] or tabs[1]
        if t == nil then return {} end
        local ok, r = pcall(t.content)
        if ok and type(r) == "table" then return r end
        return {}
    end
    if AnimalHelp == nil or AnimalHelp.topics == nil then return {} end
    local ok, t = pcall(AnimalHelp.topics)
    if not ok or type(t) ~= "table" then return {} end
    return t
end

function AnimalHelpPage:onGuiSetupFinished()
    AnimalHelpPage:superClass().onGuiSetupFinished(self)
    for _, name in ipairs({ "topicList", "bodyList" }) do
        local list = self[name]
        if list ~= nil then
            list:setDataSource(self)
            list:setDelegate(self)
        end
    end
end

function AnimalHelpPage:selectTopic(index)
    local T = self.topicRows
    if index == nil or T[index] == nil then return end
    self.currentTopic = index
    self.lines = buildLines(T[index].body, WRAP_COLS)
    if self.bodyList ~= nil then self.bodyList:reloadData() end
end

function AnimalHelpPage:onFrameOpen()
    AnimalHelpPage:superClass().onFrameOpen(self)
    -- RE-READ ON EVERY OPEN. AnimalHelp.topics resolves its l10n at call time, so a guide read once
    -- at load would be stuck with whatever language was up then.
    if AnimalPageTabs ~= nil then AnimalPageTabs.draw(self, AnimalPageTabs.tabs("help")) end
    self.topicRows = topicsOf(self)
    local n = #self.topicRows
    if self.currentTopic == nil or self.currentTopic > n then self.currentTopic = 1 end
    if self.topicList ~= nil then self.topicList:reloadData() end
    self:selectTopic(self.currentTopic)

    self:setSoundSuppressed(true)
    if self.topicList ~= nil then FocusManager:setFocus(self.topicList) end
    self:setSoundSuppressed(false)
end

function AnimalHelpPage:getNumberOfItemsInSection(list, section)
    if list == self.topicList then return #self.topicRows end
    return #self.lines
end

function AnimalHelpPage:populateCellForItemInSection(list, section, index, cell)
    if list == self.topicList then
        local t = self.topicRows[index]
        local c = cell:getAttribute("topicName")
        if c ~= nil then c:setText(t ~= nil and tostring(t.title or "?") or "") end
        return
    end
    local row = self.lines[index]
    local c   = cell:getAttribute("bodyLine")
    if c == nil then return end
    if row == nil then c:setText(""); return end
    c:setText(row.text or "")
    -- CELLS ARE RECYCLED by SmoothList, so the non-heading path must actively reset the style or a
    -- paragraph inherits the bold of whichever heading last used that slot (DR 5.7 / 5.57).
    if c.setTextBold ~= nil then pcall(c.setTextBold, c, row.head == true) end
end

---Switch tab: redraw the strip and show the new tab's topics from the first one. Topic 4 of one
-- mod's guide has nothing to do with topic 4 of another's (DR 5.87).
function AnimalHelpPage:showTab(n)
    self.currentTab = n
    if AnimalPageTabs ~= nil then AnimalPageTabs.draw(self, AnimalPageTabs.tabs("help")) end
    self.topicRows = topicsOf(self)
    self.currentTopic = 1
    if self.topicList ~= nil then self.topicList:reloadData() end
    self:selectTopic(1)
end

function AnimalHelpPage:stepPageTabBy(delta)
    if AnimalPageTabs == nil then return false end
    local tabs = AnimalPageTabs.tabs("help")
    local was = self.currentTab or 1
    if not AnimalPageTabs.step(self, tabs, delta) then return false end
    local now = self.currentTab
    self.currentTab = was
    self:showTab(now)
    return true
end

function AnimalHelpPage:onTabSlot(n)
    if AnimalPageTabs == nil then return end
    local tabs = AnimalPageTabs.tabs("help")
    if tabs[n] == nil or n == (self.currentTab or 1) then return end
    self:showTab(n)
end
function AnimalHelpPage:onTab1() return self:onTabSlot(1) end
function AnimalHelpPage:onTab2() return self:onTabSlot(2) end
function AnimalHelpPage:onTab3() return self:onTabSlot(3) end
function AnimalHelpPage:onTab4() return self:onTabSlot(4) end

---A click anywhere in the contents jumps to that topic. Selection alone is enough -- the list is
-- wired to onTopicChanged -- but the callback exists so a click on an ALREADY selected row still
-- rebuilds, which selection-changed does not fire for (DR 6.29).
function AnimalHelpPage:onTopicChanged(list, section, index)
    if list == self.topicList and index ~= nil then self:selectTopic(index) end
end
