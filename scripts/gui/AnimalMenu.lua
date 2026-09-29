-- Husbandry Redux -- this mod's own full-screen menu.
--
-- ONLY BUILT WHEN DISTRIBUTION REDUX IS ABSENT. With DR installed, AR registers its pages into DR's
-- menu exactly as it always has (API.addMenuPage) and none of this loads, so a player running both
-- sees no change whatever. HusbandryRedux.installStandaloneMenu is the single gate.
--
-- PORTED FROM DR's DistributionMenu, which is the shape this game wants a modded TabbedMenu to be:
--   * extends TabbedMenu; the XML is chrome only and every page is a FrameReference
--   * onGuiSetupFinished -> setupPages(): registerPage + addPageTab + per-page footer buttons
--   * opened with g_gui:showGui("AnimalMenu"), closed with changeScreen(nil)
--
-- WHY NOT INJECT A TAB INTO THE BASE IN-GAME MENU INSTEAD, which sounds tidier: the base menu's own
-- Lua is 96% stripped (CLAUDE.md 8.1 -- InGameMenu.lua has 2 surviving functions), so the shape of
-- what to hook cannot be READ and would have to be probed at runtime. A standalone TabbedMenu needs
-- none of that: TabbedMenu itself is present and DR has been shipping this exact pattern for a year.

AnimalMenu = {}
local AnimalMenu_mt = Class(AnimalMenu, TabbedMenu)

function AnimalMenu.new(target, custom_mt)
    return TabbedMenu.new(target, custom_mt or AnimalMenu_mt)
end

function AnimalMenu:onGuiSetupFinished()
    AnimalMenu:superClass().onGuiSetupFinished(self)
    self:setupPages()
end

---Which pages exist, in tab order, with the footer buttons each one wants.
function AnimalMenu:setupPages()
    local always = function() return true end
    -- "Back" IS THE BASE GAME'S OWN KEY, not ours: button_back is translated into every language the
    -- game ships, so borrowing it costs nothing and gains 20-odd translations (DR 5.60 records the
    -- same reasoning for its own footer).
    local backText = (g_i18n ~= nil and g_i18n:getText("button_back")) or "Back"
    local back = {
        inputAction    = InputAction.MENU_BACK,
        text           = backText,
        callback       = self:makeSelfCallback(self.onClickBack),
        showWhenPaused = true,
    }

    -- ---------------------------------------------------------------------------------------
    -- THE PAGE IS THE FRAME INSTANCE, NOT THE <FrameReference> ELEMENT.
    --
    -- Measured, after two wrong theories (a broken Class chain, then load order -- both probed and
    -- both green). The FrameReference in AnimalMenu.xml resolves to a PLACEHOLDER GuiElement, not to
    -- the HerdInspectorPage instance we handed g_gui:loadGui:
    --
    --     pageHerd==instance? false | pageHerd has the API: dirty=false custom=false
    --     instance has the API:                             dirty=true  custom=true
    --
    -- TabbedMenu then calls isMenuButtonInfoDirty / getHasCustomMenuButtons on that placeholder
    -- EVERY FRAME and throws, which is why the page was blank and the footer showed five ESC
    -- buttons: the throw happens before the footer ever reads the page's real buttons.
    -- registerPage wants the frame itself -- it calls pageFrameElement:class() and reads
    -- .elements[1] (TabbedMenu.lua:704).
    --
    -- SO: take the placeholder's GEOMETRY, drop it, and put the real frame in its place. The
    -- placeholder is worth keeping in the XML for exactly that one reason -- DR 5.66 records that a
    -- runtime-added page draws at the default position because parenting does not apply geometry,
    -- and DR's addMenuPage solves it by copying from a page the game already placed. AR's menu has
    -- only one page, so there is no sibling to copy from; the placeholder IS that reference.
    -- ---------------------------------------------------------------------------------------
    -- Each entry: the frame INSTANCE, the placeholder its geometry comes from, and its tab icon.
    -- HerdInspectorPage keeps its instance on the class because install() builds it before the menu
    -- exists; the two simple pages are constructed here, since nothing else needs them.
    local defs = {
        { page = HerdInspectorPage ~= nil and HerdInspectorPage._page or nil,
          slot = self.pageHerd,     icon = "gui.icon_ingameMenu_animals",
          -- OUR OWN PICTURE, the same one the DR-hosted tab uses (DR 5.86 / API v10). The stock
          -- slice stays as the fallback: iconFile is applied only if the file resolves, so a
          -- build that somehow ships without it still shows a tab rather than a blank square.
          -- ABSOLUTE PATH -- GuiOverlay does no mod-relative resolution (DR 5.80).
          iconFile = (HusbandryRedux.MOD_DIR or "") .. "gui/icon_herdInspector.dds" },
        { page = HusbandryRedux ~= nil and HusbandryRedux._settingsPage or nil,
          slot = self.pageSettings, icon = "gui.icon_options_generalSettings2", buttons = { back } },
        { page = HusbandryRedux ~= nil and HusbandryRedux._helpPage or nil,
          slot = self.pageHelp,     icon = "gui.icon_options_help2",           buttons = { back } },
    }

    self.tabIndexByPage = {}
    local n = 0
    for _, d in ipairs(defs) do
        local page, slot = d.page, d.slot
        if page == nil then
            print("[HusbandryRedux] setupPages: a page instance is missing (its load failed?)")
        else
            -- SWAP THE PLACEHOLDER FOR THE REAL FRAME. The <FrameReference> resolves to a plain
            -- GuiElement, NOT to the instance handed to loadGui -- measured, after the standalone
            -- menu came up blank with TabbedMenu throwing "missing method isMenuButtonInfoDirty"
            -- every frame. registerPage wants the frame itself (TabbedMenu.lua:704).
            --
            -- The placeholder is still worth having for its GEOMETRY: DR 5.66 records that a
            -- runtime-added page draws at the default position because parenting does not apply
            -- geometry, and its addMenuPage copies from a page the game already placed. Here the
            -- placeholder IS that reference.
            if slot ~= nil and self.pagingElement ~= nil then
                local pos  = slot.position ~= nil and { slot.position[1], slot.position[2] } or nil
                local size = slot.size ~= nil and { slot.size[1], slot.size[2] } or nil
                pcall(function() self.pagingElement:removeElement(slot) end)
                pcall(function() self.pagingElement:addElement(page) end)
                if pos ~= nil and page.setPosition ~= nil then page:setPosition(pos[1], pos[2]) end
                if size ~= nil and page.setSize ~= nil then page:setSize(size[1], size[2]) end
                if page.updateAbsolutePosition ~= nil then
                    pcall(function() page:updateAbsolutePosition() end)
                end
                -- VERIFY, do not assume: DR 5.66 records a page the paging element silently refused,
                -- which then threw on every frame with the menu already half built.
                local okId = false
                if self.pagingElement.getPageIdByElement ~= nil then
                    local id = self.pagingElement:getPageIdByElement(page)
                    okId = (id ~= nil) and (self.pagingElement:getPageById(id) ~= nil)
                end
                if not okId then
                    print("[HusbandryRedux] setupPages: the paging element did not accept a page")
                end
            end

            n = n + 1
            self:registerPage(page, n, always)
            self:addPageTab(page, nil, nil, d.icon)
            self._tabIconSlices = self._tabIconSlices or {}
            self._tabIconSlices[page] = d.icon
            -- AFTER addPageTab, which is what creates the tab; the button only exists to be
            -- overridden once the tab is there. Guarded on the file RESOLVING, so a missing asset
            -- leaves the stock slice in place instead of an empty tab -- and pcall'd because a
            -- menu that cannot take a file icon must still get its tab.
            if d.iconFile ~= nil and fileExists ~= nil and fileExists(d.iconFile) then
                self._tabIconFiles = self._tabIconFiles or {}
                self._tabIconFiles[page] = d.iconFile
                -- PUT THE FILE ON THE TAB RECORD TOO. The inherited populate re-applies the icon
                -- from this record on every populate; while it still named the atlas slice, each
                -- populate swapped the slice back in and ours swapped the PNG back, so the
                -- filename changed every time and the PNG was reloaded from disk on each one
                -- (GuiOverlay.createOverlay only skips an UNCHANGED filename). With both naming the
                -- same file the reload is skipped. DR 6.44.
                local tab = (self.pageTabs or {})[page]
                if tab ~= nil then
                    tab.iconSliceId  = nil
                    tab.iconFilename = d.iconFile
                    if Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
                        tab.iconUVs = (table.clone ~= nil) and table.clone(Overlay.DEFAULT_UVS)
                                      or Overlay.DEFAULT_UVS
                    end
                end
            end
            self.tabIndexByPage[page] = n
            -- HerdInspectorPage.install already applied its real set (Back, Buy/Sell, Schedule and
            -- the two rules dialogs); overwriting it with { back } would silently throw four buttons
            -- away. The two simple pages have none of their own, so they take the default.
            -- `menuButtonInfo` starts as an EMPTY TABLE, not nil (TabbedMenuFrameElement.new), so
            -- test for CONTENT. Testing `== nil` reads as "already has buttons" when it has none,
            -- which is what left these two pages with an empty footer.
            local has = page.hasFooterButtons ~= nil and page:hasFooterButtons()
                        or (type(page.menuButtonInfo) == "table" and #page.menuButtonInfo > 0)
            if d.buttons ~= nil and not has and page.setMenuButtonInfo ~= nil then
                page:setMenuButtonInfo(d.buttons)
            end
        end
    end

    self:rebuildTabList()
end

---Paint a tab's own icon FILE over the stock slice it was registered with.
--
-- A PORT OF DR's, and it has to be: this menu is AR's own TabbedMenu subclass, so DR's override
-- (which does the same job inside DR's menu) is not in the chain here. Kept deliberately small --
-- there is no badge on this menu, because every tab in it is ours and a badge exists to mark ONE
-- tab as belonging to somebody else (DR 5.86).
--
-- WHY A FILE: the tab icon is normally `iconSliceId` on the button, and the atlas lives inside
-- dataS.gar where a mod cannot add a slice. ButtonElement:setImageFilename(nil, icon) is the way
-- in, and an `imageFilename` attribute in the layout could not name a mod file anyway (DR 5.80).
--
-- BOTH BRANCHES ARE EXPLICIT because cells are RECYCLED: a file left on a cell would follow
-- whichever tab reuses it, and putting a cell back means re-applying the slice its page was
-- registered with, not clearing anything.
function AnimalMenu:populateCellForItemInSection(list, section, index, cell)
    AnimalMenu:superClass().populateCellForItemInSection(self, list, section, index, cell)
    if cell == nil or cell.getDescendantByName == nil then return end

    local page = (self.enabledPages or {})[index]
    if page == nil then return end

    local ok, btn = pcall(cell.getDescendantByName, cell, "tabButton")
    if not ok or btn == nil then return end

    local file = (self._tabIconFiles or {})[page]
    if file ~= nil and btn.setImageFilename ~= nil then
        pcall(btn.setImageFilename, btn, nil, file)
        -- THE UVs MUST BE RESET TO THE WHOLE TEXTURE, and this was the whole bug: the
        -- button's icon overlay still carries the UV window of the ATLAS SLICE it was
        -- registered with, and setImageFilename does not touch it. createOverlay only swaps
        -- the image handle, deleteOverlay never looks at uvs, and loadOverlay sets
        -- DEFAULT_UVS only when uvs is nil. So a standalone picture was sampled through a
        -- small sub-rectangle of the atlas and stretched across the tab -- which renders as a
        -- washed out smear rather than as nothing, and THAT is the tell that the file was
        -- loading correctly all along.
        -- The base game states this exact case at MapOverlayGenerator.lua:602: "default crop
        -- type icons are separate files, use full texture".
        -- CLONED, never assigned by reference: DEFAULT_UVS is a shared global and Overlay.lua
        -- clones it for that reason. No literal fallback either -- its assignment is in the
        -- stripped part of the source, so a guessed UV set would fail looking exactly like the
        -- bug being fixed.
        if btn.setImageUVs ~= nil and Overlay ~= nil and Overlay.DEFAULT_UVS ~= nil then
            local uvs = (table.clone ~= nil) and table.clone(Overlay.DEFAULT_UVS)
                        or Overlay.DEFAULT_UVS
            pcall(btn.setImageUVs, btn, nil, uvs)
        end
    else
        local slice = (self._tabIconSlices or {})[page]
        if slice ~= nil and btn.setImageSlice ~= nil then
            pcall(btn.setImageSlice, btn, nil, slice)
        end
    end
end

---Is a MEANINGFUL modifier held (ctrl / alt / shift / meta), as opposed to a lock bit?
--
-- MEASURED BY DR AND WORTH NOT RE-LEARNING: every menu key press arrives with
-- modifier = 4096, a Num Lock bit, so a `modifier == 0` guard rejects EVERYTHING and the
-- key silently never fires (DR 5.64, and it cost two builds there). The test has to be on
-- the bits that matter.
--
-- The mask is assembled from whichever constants this build actually defines, and if none
-- resolve it reports "clear" -- failing toward the key WORKING rather than silently dead.
local function realModifierHeld(modifier)
    if type(modifier) ~= "number" or bit32 == nil or Input == nil then return false end
    local mask = 0
    for _, n in ipairs({ "MOD_LCTRL", "MOD_RCTRL", "MOD_LALT", "MOD_RALT",
                         "MOD_LSHIFT", "MOD_RSHIFT", "MOD_LMETA", "MOD_RMETA" }) do
        local v = Input[n]
        if type(v) == "number" then mask = bit32.bor(mask, v) end
    end
    if mask == 0 then return false end
    return bit32.band(modifier, mask) ~= 0
end

---A AND D STEP THE CURRENT PAGE'S TABS, exactly as they do in Distribution Redux's menu.
--
-- THE SAME CONTRACT, so a page behaves identically in either menu: the page is asked,
-- duck-typed, for stepPageTabBy(delta), and the key is claimed only if a tab actually moved.
-- Without this the keys would work on the Herd Inspector inside DR's menu and do nothing on
-- the same page in AR's own, which is the kind of split that makes a shared page feel broken.
--
-- HANDLED AT THE MENU, not the page: Gui:keyEvent dispatches to g_gui.currentListener and its
-- target only and never walks down to a frame, so an override on a PAGE is not reliably
-- reached (DR 5.64). This screen IS the currentListener.
function AnimalMenu:keyEvent(unicode, sym, modifier, isDown, eventUsed)
    local step = nil
    if isDown and Input ~= nil and not realModifierHeld(modifier) then
        if Input.KEY_a ~= nil and sym == Input.KEY_a then step = -1
        elseif Input.KEY_d ~= nil and sym == Input.KEY_d then step = 1 end
    end
    if step ~= nil then
        local p = self.currentPage
        if p ~= nil and type(p.stepPageTabBy) == "function" then
            local ok, moved = pcall(p.stepPageTabBy, p, step)
            if ok and moved == true then return true end
        end
    end
    return AnimalMenu:superClass().keyEvent(self, unicode, sym, modifier, isDown, eventUsed)
end

function AnimalMenu:onClickBack()
    if g_gui ~= nil then g_gui:changeScreen(nil) end
    return true
end

function AnimalMenu:onOpen()
    AnimalMenu:superClass().onOpen(self)
    -- Re-evaluate the tab predicates against the current settings, exactly as DR does: a tab whose
    -- feature has been switched off since the menu was last opened must not still be there.
    pcall(function() self:rebuildTabList() end)
end
