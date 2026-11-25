-- ============================================================================
-- AnimalPageTabs.lua  (Husbandry Redux) -- tabs on HR's OWN Settings and Guide pages.
--
-- WHY THIS EXISTS NOW. HR's standalone Settings and User Guide pages had no tab strip,
-- deliberately: "a registry so a THIRD mod could add one is deliberately not built: there is
-- no such mod" (31.0). Production Redux (2026-10-20) is that mod. Without this, a player
-- running HR + PR without Distribution Redux got PR's settings and guide as two EXTRA left
-- icons in HR's menu instead of tabs beside HR's own -- reported on the first test.
--
-- THE CONTRACT IS DISTRIBUTION REDUX'S, field for field (DR 5.88 / 5.88a), so a mod that
-- already registers with DR can hand HR the very same rows and topics:
--
--   HusbandryRedux.API.registerSettingsTab(modName, label, defs)
--   HusbandryRedux.API.registerHelpTab(modName, label, topics)
--   HusbandryRedux.API.unregisterSettingsTab(modName) / unregisterHelpTab(modName)
--
--   label   the tab caption, ALREADY LOCALISED (HR cannot resolve another mod's namespace)
--   defs    array (or a function returning one) of
--           { id, title, tooltip, strings = {...}, get = fn() -> index, set = fn(index) }
--   topics  array (or a function returning one) of { title, body }
--
-- ONLY USED WHEN HR BUILDS ITS OWN MENU. With DR present HR's settings and guide are tabs on
-- DR's pages, and another mod registers with DR directly -- so this registry is empty and
-- nothing here draws.
--
-- HR's OWN TAB IS ALWAYS FIRST, and the strip only appears once a second provider
-- registers -- the author's rule, the same one DR's pages follow (DR 5.90). HR alone looks
-- exactly as it did.
--
-- A PROVIDER IS UNTRUSTED CODE IN HR's GUI: its function forms are pcall'd and one that
-- throws three times is struck out for the session, DR's rule. A throw inside a populate
-- shows as an empty page with nothing in the log.
-- ============================================================================

AnimalPageTabs = {}

AnimalPageTabs.MAX = 4          -- slots declared on each page's strip
AnimalPageTabs.STRIKES = 3

-- key ("settings" | "help") -> array of { modName, label, content, strikes }
AnimalPageTabs._reg = { settings = {}, help = {} }

local function warn(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then return HusbandryRedux.warn(fmt, ...) end
end

local function l10n(key, fallback)
    if HusbandryRedux ~= nil and HusbandryRedux.l10n ~= nil then return HusbandryRedux.l10n(key, fallback) end
    return fallback
end

---Re-registering by the same mod REPLACES its entry (the chunk re-runs per mission load).
local function register(key, modName, label, content)
    if type(modName) ~= "string" or modName == "" or type(label) ~= "string" then return false end
    if type(content) ~= "table" and type(content) ~= "function" then return false end
    local list = AnimalPageTabs._reg[key]
    for i, e in ipairs(list) do
        if e.modName == modName then
            list[i] = { modName = modName, label = label, content = content, strikes = 0 }
            return true
        end
    end
    -- One slot is HR's own; refuse a provider there is no slot to draw.
    if #list + 1 >= AnimalPageTabs.MAX then
        warn("%s tab for '%s' refused: no free slot", key, modName)
        return false
    end
    list[#list + 1] = { modName = modName, label = label, content = content, strikes = 0 }
    return true
end

local function unregister(key, modName)
    local list = AnimalPageTabs._reg[key]
    for i = #list, 1, -1 do
        if list[i].modName == modName then table.remove(list, i) end
    end
    return true
end

---Every tab for a page, HR's own first. Each: { label, own, content = fn() -> table }.
function AnimalPageTabs.tabs(key)
    local tabs = {}
    if key == "settings" then
        tabs[1] = { own = true, label = l10n("ar_set_tab", "HUSBANDRY REDUX"),
                    content = function() return AnimalSettings ~= nil and AnimalSettings.rows() or {} end }
    else
        tabs[1] = { own = true, label = l10n("ar_help_tab", "HUSBANDRY REDUX"),
                    content = function() return AnimalHelp ~= nil and AnimalHelp.topics() or {} end }
    end
    for _, e in ipairs(AnimalPageTabs._reg[key] or {}) do
        if e.strikes < AnimalPageTabs.STRIKES then
            tabs[#tabs + 1] = { own = false, label = e.label, entry = e, content = function()
                local c = e.content
                if type(c) == "function" then
                    local ok, r = pcall(c)
                    if not ok then
                        e.strikes = e.strikes + 1
                        warn("%s tab of '%s' threw (%d/%d): %s", key, e.modName, e.strikes,
                             AnimalPageTabs.STRIKES, tostring(r))
                        if e.strikes >= AnimalPageTabs.STRIKES then
                            warn("%s tab of '%s' STRUCK OUT for this session", key, e.modName)
                        end
                        return {}
                    end
                    c = r
                end
                return type(c) == "table" and c or {}
            end }
        end
    end
    return tabs
end

-- ---------------------------------------------------------------------------
-- THE PUBLIC FACE. On HusbandryRedux, because that is the table other mods already resolve
-- (FS25_Husbandry_Redux.HusbandryRedux). A capability test is `API.registerSettingsTab ~= nil`.
HusbandryRedux.API = HusbandryRedux.API or {}
HusbandryRedux.API.VERSION = 1
HusbandryRedux.API.registerSettingsTab   = function(m, l, d) return register("settings", m, l, d) end
HusbandryRedux.API.unregisterSettingsTab = function(m) return unregister("settings", m) end
HusbandryRedux.API.registerHelpTab       = function(m, l, t) return register("help", m, l, t) end
HusbandryRedux.API.unregisterHelpTab     = function(m) return unregister("help", m) end

-- ---------------------------------------------------------------------------
-- THE PAGE SIDE, shared by both pages so they cannot drift (DR 6.18).

---Draw the strip on `page` and return how many tabs show. A strip of ONE is hidden: one tab is
-- not a choice (DR 5.90).
function AnimalPageTabs.draw(page, tabs)
    if AnimalTabs == nil then return 0 end
    local labels = {}
    if #tabs >= 2 then
        for i, t in ipairs(tabs) do labels[i] = t.label end
    end
    local cur = page.currentTab or 1
    if cur > #tabs then cur = 1; page.currentTab = 1 end
    return AnimalTabs.render(page, labels, cur)
end

---Step the current tab, wrapping. Returns true only if it moved, so A / D are never keys
-- that silently do nothing (the menu claims the key only on true).
function AnimalPageTabs.step(page, tabs, delta)
    local n = #tabs
    if n < 2 or type(delta) ~= "number" or delta == 0 then return false end
    local cur = page.currentTab or 1
    local want = ((cur - 1 + delta) % n) + 1
    if want == cur then return false end
    page.currentTab = want
    return true
end

-- ===========================================================================
-- THE OVERVIEW, WITHOUT DISTRIBUTION REDUX (2026-10-20, author's call: "mirror DR's").
--
-- Under DR the Overview is DR's page and each mod adds a tab to it (DR API v13 / v15); HR's tab is
-- a real page (the Herd Inspector's Animals / Breeds views, MODE_OVERVIEW). With DR absent there
-- was no Overview at all, so those views stayed on the Herd Inspector and another mod had nowhere
-- to put an overview tab. Now HR's OWN MENU carries an Overview icon that behaves like DR's:
--
--   tab 1  HUSBANDRY REDUX   HR's MODE_OVERVIEW page (HerdInspectorPage._overviewPage)
--   tab N  another mod       a PAGE it supplies, hidden from the left list and reached from the
--                            strip -- exactly how DR treats a page tab (DR 5.119)
--
--   HusbandryRedux.API.registerOverviewTab(modName, label, { page = frame })
--   HusbandryRedux.API.overviewTabs()       -> copies { label, owner, page = true }
--   HusbandryRedux.API.selectOverviewTab(i) -> goes to that tab's page
--
-- PAGE TABS ONLY. DR also takes { placeholder = text } and draws the caption itself; HR has no
-- page of its own to draw a caption on, so a mod with nothing to show yet supplies a small page.
-- Register BEFORE adding the page to the menu, so it never shows as a left row of its own.
-- ===========================================================================

AnimalPageTabs._overview = {}       -- foreign entries { modName, label, page }

function AnimalPageTabs.overviewList()
    local list = {}
    local own = (HerdInspectorPage ~= nil) and HerdInspectorPage._overviewPage or nil
    if own ~= nil then
        list[1] = { owner = (HusbandryRedux ~= nil and HusbandryRedux.MOD_NAME) or "FS25_Husbandry_Redux",
                    label = l10n("ar_overview_tab", "HUSBANDRY REDUX"), page = own, own = true }
    end
    for _, e in ipairs(AnimalPageTabs._overview) do
        list[#list + 1] = { owner = e.modName, label = e.label, page = e.page }
    end
    return list
end

---Is `page` a FOREIGN overview tab page? Those are dropped from the left list; HR's own overview
-- page is the Overview's row and stays.
function AnimalPageTabs.isOverviewTabPage(page)
    if page == nil then return false end
    for _, e in ipairs(AnimalPageTabs._overview) do
        if e.page == page then return true end
    end
    return false
end

HusbandryRedux.API.registerOverviewTab = function(modName, label, content)
    if type(modName) ~= "string" or modName == "" or type(label) ~= "string" then return false end
    if type(content) ~= "table" or type(content.page) ~= "table" then
        warn("overview tab for '%s' refused: HR takes page tabs only ({ page = frame })", tostring(modName))
        return false
    end
    local list = AnimalPageTabs._overview
    for i, e in ipairs(list) do
        if e.modName == modName then list[i] = { modName = modName, label = label, page = content.page }; return true end
    end
    if #list + 1 >= AnimalPageTabs.MAX then
        warn("overview tab for '%s' refused: no free slot", modName)
        return false
    end
    list[#list + 1] = { modName = modName, label = label, page = content.page }
    return true
end

HusbandryRedux.API.unregisterOverviewTab = function(modName)
    local list = AnimalPageTabs._overview
    for i = #list, 1, -1 do if list[i].modName == modName then table.remove(list, i) end end
    return true
end

---COPIES, never the entries: a caller must not be able to edit HR's registry through them.
HusbandryRedux.API.overviewTabs = function()
    local out = {}
    for i, t in ipairs(AnimalPageTabs.overviewList()) do
        out[i] = { label = t.label, owner = t.owner, own = t.own == true, page = true }
    end
    return out
end

HusbandryRedux.API.selectOverviewTab = function(i)
    local t = AnimalPageTabs.overviewList()[i]
    local menu = HusbandryRedux ~= nil and HusbandryRedux._standaloneMenu or nil
    if t == nil or menu == nil or menu.goToPage == nil then return false end
    if menu.currentPage ~= t.page then pcall(menu.goToPage, menu, t.page) end
    return true
end
