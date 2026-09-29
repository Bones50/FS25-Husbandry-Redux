-- ============================================================================
-- AnimalTabs.lua  (Husbandry Redux) -- a horizontal tab strip, ONE implementation.
--
-- Requested 2026-09-01: switch between pages with tabs across the top, the way
-- the base game's settings screen does, rather than with a selector.
--
-- ---------------------------------------------------------------------------
-- IT IS NOW THE BASE GAME'S OWN TAB, and the first version was not because of a
-- claim that turned out to be false. See CLAUDE.md 25.1a / 25.1b: the stock GUI
-- profiles are NOT locked inside dataS.gar -- they are on disk, complete, in
-- `sdk\xmlDoku\guiProfiles.xml` (512 of them). This widget was built from
-- primitives on the belief that they were unreadable, which was never checked.
--
-- WHAT THE PROFILES GIVE, and it is the whole visual difference:
--
--   fs25_subCategorySelectorTabbedTabBg   a THREE PART background --
--       gui.tab_selected_left (12px cap) | gui.tab_selected_middle (stretched) |
--       gui.tab_selected_right (12px cap). A real tab shape rather than the flat
--       green block this drew before.
--   fs25_subCategorySelectorTabbedTab     18px bold uppercase centred, with the
--       game's own $preset_fs25_colorMainLight, going colorMainDark when selected.
--
-- SELECTION IS A STATE, NOT A PAINT. `GuiElement:getOverlayState` returns
-- STATE_SELECTED whenever `getIsSelected()` is true (second only to disabled), and
-- GuiOverlay resolves every *Selected* slice and colour off that. So one
-- `setSelected(bool)` per element drives the background AND the text colour, and
-- there are no hand-picked colours left in this file to drift from the game's.
--
-- AND UNSELECTED DRAWS NOTHING BY CONSTRUCTION: the TabBg profile declares only
-- the SELECTED slices, its caps are `gui.empty`, and it extends `emptyPanel` whose
-- imageSliceId is "noSlice". Nothing has to be hidden for the inactive tabs to
-- disappear -- though visibility is still set, see below.
--
-- ---------------------------------------------------------------------------
-- WHY THE PIECES ARE SAFE, since 18.7 and DR 5.64 both record what an invented or
-- mis-sized profile costs:
--   the TAG      `<ThreePartBitmap>` is PROVEN in AR's own working layouts -- these
--                same two dialogs already use it for fs25_dialogBgMiddleSmall and
--                fs25_listSliderBox, and they render. (Tag registration is stripped
--                from the shipped source, so an empirical example is the only proof
--                available; DR 5.70 established `<TextInput>` the same way.)
--   the PROFILES are read from guiProfiles.xml, not guessed.
--   the SIZE     is where the care is needed. These carry 12px start/end caps, so a
--                tab must stay comfortably wider than 24px, and the profile's
--                `textAutoWidth` is switched OFF in the XML so its auto fit cannot
--                override the widths each layout tiles by hand.
--
-- THE BACKGROUND IS DECLARED BEFORE ITS BUTTON in every layout, because children
-- draw in order and the label has to sit ON the background (DR 5.86).
--
-- ONE IMPLEMENTATION, THREE SURFACES. The page and both dialogs call this rather
-- than carrying a copy: a widget with a background, a selected state and a
-- visibility rule is exactly the thing DR 5.69 promoted out of a GUI file after
-- 6.18 recorded three regressions caused by copying helpers between pages.
-- ============================================================================

AnimalTabs = {}

---How many tab slots the layouts declare. Every surface declares this many and
-- hides the ones it does not use, so nothing is ever repositioned at runtime
-- (DR 5.37).
AnimalTabs.MAX = 8   -- 8 since the Herd Inspector gained a tab per animal type (2026-09-24);
                     -- the render is nil-guarded per slot, so a surface declaring fewer is unaffected

---Set an element's selected state, if it has one.
--
-- BOTH THE BACKGROUND AND THE BUTTON GET IT. The background needs it for its
-- three part art; the BUTTON needs it for `textSelectedColor`, because
-- `TextElement:getColor` prefers the selected colour whenever the element is in
-- that state (DR 5.77b, 16.6) -- which is precisely the mechanism being used here
-- rather than fought.
local function select(el, on)
    if el ~= nil and type(el.setSelected) == "function" then
        pcall(el.setSelected, el, on == true)
    end
end

---Draw the strip. `owner` is the page or dialog holding `arTabBtn1..N` and
-- `arTabBg1..N`; `labels` is what to show; `active` is which is current.
---Returns how many tabs are showing, so a caller can assert its own layout.
function AnimalTabs.render(owner, labels, active)
    if owner == nil or type(labels) ~= "table" then return 0 end
    local shown = 0
    for i = 1, AnimalTabs.MAX do
        local btn   = owner["arTabBtn" .. i]
        local bg    = owner["arTabBg" .. i]
        local label = labels[i]
        local on    = (i == active)

        -- A tab is ONLY selected if it is both the active one AND actually in use.
        local live = (on and label ~= nil)

        if btn ~= nil and btn.setVisible ~= nil then btn:setVisible(label ~= nil) end
        -- A HIDDEN TAB'S BACKGROUND MUST BE HIDDEN TOO. Belt and brace: an
        -- unselected background already draws nothing (no normal state slice), but
        -- a strip that shrinks from three tabs to two must not leave a selected
        -- background standing where the third used to be.
        if bg ~= nil and bg.setVisible ~= nil then bg:setVisible(label ~= nil) end

        -- BOTH DESELECT OUTSIDE THE LABEL GUARD, and this is not symmetry for its
        -- own sake. The first version selected the button INSIDE the guard, so a
        -- tab whose label went away kept `selected` from the previous render --
        -- leaving its text painted in textSelectedColor with no background under
        -- it. Caught by the harness, never seen on screen.
        select(bg, live)
        select(btn, live)

        -- GUARDED ON THE BUTTON, not only on the label. A surface asking for more
        -- labels than its layout declares slots is a mistake, but it must not be a
        -- CRASH inside a GUI populate -- which aborts the page mid-render and shows
        -- as an empty screen, nothing like its cause (5.44 / 5.57).
        if label ~= nil and btn ~= nil then
            shown = shown + 1
            if btn.setText ~= nil then btn:setText(tostring(label)) end
        end
    end

    -- THE A / D HINTS, where the surface declares them. Optional: the two dialogs share this
    -- renderer and have no arrows, so both are nil-guarded and nothing changes for them.
    -- Shown only when there is somewhere to step -- a single tab cannot be cycled.
    --
    -- THE LETTERS ARE NOT TRANSLATED. They name a hardcoded key, so translating them would
    -- promise a rebinding that does not exist (DR 5.100).
    --
    -- POSITION IS STATIC, unlike DR's, because every surface that has these arrows draws a FIXED
    -- number of tabs. Give one a variable count and the next arrow will need placing against the
    -- last visible slot, the way DR's drawPageTabs does it.
    local prev, nxt = owner.arTabPrev, owner.arTabNext
    if prev ~= nil then
        if prev.setText ~= nil then prev:setText("< A") end
        if prev.setVisible ~= nil then prev:setVisible(shown > 1) end
    end
    if nxt ~= nil then
        if nxt.setText ~= nil then nxt:setText("D >") end
        if nxt.setVisible ~= nil then nxt:setVisible(shown > 1) end
    end
    return shown
end

---Turn a tab click into an index, for a handler that knows which slot it is.
-- Bounds-checked against the labels the strip was last drawn with, so a click on
-- a slot the current surface does not use can never select a page it does not
-- have.
function AnimalTabs.pick(labels, i)
    if type(labels) ~= "table" or labels[i] == nil then return nil end
    return i
end
