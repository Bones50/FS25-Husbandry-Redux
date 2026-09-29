-- Husbandry Redux -- the husbandry summary panel, drawn on this mod's OWN page.
--
-- PORTED FROM DISTRIBUTION REDUX 2026-09-07, for the standalone plan. DR wrote this renderer
-- (DR 5.81 / 5.84 / 5.85a) and still owns the copy that draws the panel on ITS Animal Husbandry
-- tab; this is AR's copy, for AR's Herd Inspector page. The two are independent from here on.
--
-- WHY A SECOND COPY EXISTS AT ALL. AR used to call SmartDistribution.drawHusbandryPanel to draw
-- into AR's own markup -- which works beautifully and means the page renders NOTHING without DR
-- installed. Two independently-installable mods cannot share a 370-line renderer without one
-- depending on the other, so the duplication is the price of the split rather than an oversight.
--
-- IT IS USED ALWAYS, NOT ONLY WHEN DR IS ABSENT, and that is deliberate. A fallback that runs only
-- in the rare configuration is a fallback nobody exercises: it would rot silently and fail the
-- first time a player without DR opened the page. One path, always tested.
--
-- THE PANEL'S CHILD NAMES ARE THE CONTRACT, and they are shared with DR's copy: the same markup is
-- declared in DR's DistributionHusbandryPage.xml and AR's HerdInspectorPage.xml, and
-- tools/husbandrypanel.lua parses BOTH and requires them to declare the same children. Renaming one
-- draws nothing and reports nothing.
--
-- WHAT MUST STAY IN STEP WITH DR: the panel DATA contract (the table the provider returns) and the
-- child names. The LAYOUT and the palette are now AR's own -- changing a colour here does not
-- change DR's tab, and it should not.
--
-- DO NOT "TIDY" THE ARITHMETIC. Everything here was measured rather than chosen: the palette is
-- validated for colour-blind separation against the track colour (DR 5.81), a COW's feed bar is
-- tiers-not-segments because stacking a serial animal draws 2.0, and every geometry figure is in
-- NORMALISED units, never px -- DR 5.81 records four separate bugs from that one confusion.

AnimalPanel = {}

---Money, whole units. AR's GUI files each carry a local  of their own; this is the
-- module-scoped one the panel needs, kept here so the port has no reach into them.
function AnimalPanel.formatMoney(v)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(function() return g_i18n:formatMoney(v, 0, true, false) end)
        if ok and type(s) == "string" then return s end
    end
    return string.format("%s%d", v < 0 and "-" or "", math.floor(math.abs(v) + 0.5))
end

AnimalPanel.PANEL_MAX_GROUPS = 6
AnimalPanel.PANEL_COLOURS = {
    { 0.224, 0.529, 0.898 },   -- 1 blue     #3987e5
    { 0.851, 0.349, 0.149 },   -- 2 orange   #d95926
    { 0.098, 0.620, 0.439 },   -- 3 aqua     #199e70
    { 0.788, 0.522, 0.000 },   -- 4 yellow   #c98500
    { 0.835, 0.318, 0.506 },   -- 5 magenta  #d55181
    { 0.000, 0.514, 0.000 },   -- 6 green    #008300
}

-- The two-pixel gap the mark specs ask for between stacked segments, so a boundary reads as a
-- boundary rather than two hues touching. Taken off the RIGHT of each segment except the last.
AnimalPanel.PANEL_SEG_GAP = 2

---px -> normalized (x, y). Returns nil on a build without GuiUtils rather than guessing.
function AnimalPanel._pxNorm(x, y)
    if GuiUtils == nil or GuiUtils.getNormalizedScreenValues == nil then return nil, nil end
    local ok, v = pcall(GuiUtils.getNormalizedScreenValues, string.format("%dpx %dpx", x, y))
    if not ok or type(v) ~= "table" then return nil, nil end
    return v[1], v[2]
end

---Find a named child of the panel.
--
-- `getAttribute` IS NOT A GuiElement METHOD. Every other named-child lookup in this mod is on a
-- SmoothList CELL, where it works -- the base game calls it the same way (SmoothListElement.lua:912)
-- and its definition is in the stripped part of the source (8.1), so it was easy to assume it was
-- general. It is not: the panel container is a plain GuiElement, `root.getAttribute` is nil, and the
-- first build's guard `if root.getAttribute == nil then return false end` therefore made
-- drawHusbandryPanel return before drawing a single thing -- with no error, with the data arriving
-- correctly, and with the strip simply blank.
--
-- `GuiElement:getDescendantByName` is the right call and is PRESENT in the shipped source: recursive,
-- depth-first, returns the element or nil. getAttribute is kept as a fallback so this same helper
-- still works if it is ever pointed at a list cell.
function AnimalPanel._panelEl(root, name)
    if root == nil then return nil end
    if root.getDescendantByName ~= nil then
        local ok, e = pcall(root.getDescendantByName, root, name)
        if ok then return e end
    end
    if root.getAttribute ~= nil then return root:getAttribute(name) end
    return nil
end

function AnimalPanel._panelText(root, name, text, r, g, b)
    local e = AnimalPanel._panelEl(root, name)
    if e == nil then return end
    if e.setText ~= nil then e:setText(text or "") end
    -- ALWAYS set the colour, both branches. These elements are not recycled the way list cells are,
    -- but they ARE reused across buildings, so a red "past peak" note left on a healthy barn is the
    -- same class of bug (5.7 / 5.57) with a slower trigger.
    if e.setTextColor ~= nil then
        if r ~= nil then e:setTextColor(r, g, b, 1) else e:setTextColor(1, 1, 1, 1) end
    end
    if e.setVisible ~= nil then e:setVisible(text ~= nil and text ~= "") end
end

---Fill `name` to `frac` of the track `bgName` names.
function AnimalPanel._panelFill(root, name, frac, bgName)
    local e = AnimalPanel._panelEl(root, name)
    if e == nil then return end
    local full = AnimalPanel._panelTrackW(root, bgName)
    frac = math.max(0, math.min(1, frac or 0))
    if e.setSize ~= nil and full > 0 then e:setSize(full * frac, nil) end
    if e.setVisible ~= nil then e:setVisible(frac > 0 and full > 0) end
end

---Hide every optional element, so a barn that answers with less than the last one does not inherit
-- its neighbour's figures. Called first on every draw.
function AnimalPanel._panelReset(root)
    for i = 1, AnimalPanel.PANEL_MAX_GROUPS do
        for _, n in ipairs({ "apSeg" .. i, "apTier" .. i, "apLegSw" .. i }) do
            local e = AnimalPanel._panelEl(root, n)
            if e ~= nil and e.setVisible ~= nil then e:setVisible(false) end
        end
        AnimalPanel._panelText(root, "apLegTx" .. i, "")
    end
end

---The NORMALIZED width of a track, read off the element itself. setSize and setPosition work in
-- normalized screen units, NOT the px the XML is written in -- px are converted at load, and on an
-- ultrawide the 6.15 widening multiplies them again, so a px figure hardcoded here would be wrong by
-- the widen factor as well as by the reference scale. drawStorageBar has always read absSize for
-- exactly this reason; `size` is the same figure before layout has resolved and is the safe fallback.
function AnimalPanel._panelTrackW(root, bgName)
    local bg = AnimalPanel._panelEl(root, bgName)
    if bg == nil then return 0 end
    local w = (bg.absSize ~= nil and bg.absSize[1]) or 0
    if w <= 0 then w = (bg.size ~= nil and bg.size[1]) or 0 end
    return w
end

---WHOLE UNITS. PORTED FROM DR, AND ITS ABSENCE IS WHY THE PROFIT BLOCK WAS BLANK.
--
-- Reported 2026-09-09: the profit headline drew NOTHING on every cow barn, while the
-- chicken pen drew "-" -- and once the pen had drawn its dash, the cow barns showed
-- that dash too. That sequence is the whole diagnosis. A barn with a real profit takes
-- the branch that calls signed() -> formatMoneyFine -> fmtMoney; a pen whose profit
-- cannot be computed takes the `else` branch, which writes "-" directly and calls
-- neither. So the failing path was the one that formats a NUMBER.
--
-- When AnimalPanel took over rendering this strip on 2026-09-07 (so the page would
-- draw with DR uninstalled), formatMoneyFine came across and `fmtMoney` did not -- it
-- is a file-LOCAL in SmartDistribution.lua, not a field, so there was nothing to
-- qualify and nothing to notice. The name then resolved to a nil GLOBAL and threw on
-- every call. Profit is the last block drawn, and the page wraps the whole draw in a
-- pcall, so blocks A to C survived and D silently never ran: no error, no log line,
-- an empty space.
--
-- `luac -p` CANNOT SEE THIS. Calling an undeclared global is valid syntax; it throws
-- only when reached. DR records the same trap three times (5.44, 5.57, 5.59) and this
-- is its port-shaped variant: copy a function, leave its dependency behind.
--
-- EXPOSED AS A FIELD TOO, exactly as DR does it. formatMoneyFine's own caller reads
-- `AnimalPanel.formatMoneyFine or AnimalPanel.formatMoney`, and that fallback was
-- equally undefined -- so the intended safety net was not there either.
local function fmtMoney(v)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, t = pcall(function() return g_i18n:formatMoney(v, 0, true, false) end)
        if ok and type(t) == "string" then return t end
    end
    return string.format("%s%d", v < 0 and "-" or "", math.floor(math.abs(v) + 0.5))
end
AnimalPanel.formatMoney = fmtMoney

---A SMALL FIGURE IS NOT A ZERO. fmtMoney rounds to whole units, which is right for
-- the sums this mod usually prints and wrong for a rate: manure and slurry are
-- 0.033/L, so a pen making 2 L an hour earns 0.066 -- and at 0 decimal places that
-- printed as a flat "0" and read as "this product is worthless" (reported
-- 2026-08-31). Below 10 the figure gets two decimals, so a REAL zero and a small
-- one are different on screen. That is nil-is-not-zero applied to ROUNDING.
--
-- SEPARATE FROM fmtMoney ON PURPOSE: that one is called from ~40 sites printing
-- totals and sale values, where two decimals would be noise.
function AnimalPanel.formatMoneyFine(v)
    if type(v) ~= "number" then return "-" end
    if v == 0 or math.abs(v) >= 10 then return fmtMoney(v) end
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, t = pcall(function() return g_i18n:formatMoney(v, 2, true, false) end)
        if ok and type(t) == "string" then return t end
    end
    return string.format("%s%.2f", v < 0 and "-" or "", math.abs(v))
end

---Draw the panel for one barn. `root` is the animalPanel container; `d` is API v4 data or nil.
-- Returns true if anything was drawn, so the caller can hide the whole strip on nil.
--
-- `opts` is OPTIONAL and exists for one thing: a page carrying its own timescale
-- selector. `profitScale` multiplies the profit block (which the provider states per
-- MONTH) and `profitLabel` renames it to match. Omitting it leaves the block exactly
-- per month, which is what DR's own Animal Husbandry tab wants -- that tab's period
-- selector scopes historical LEDGER windows, and a forward projection is not one of
-- those, so the two are deliberately not wired together.
function AnimalPanel.drawHusbandryPanel(root, d, opts)
    -- NOT gated on getAttribute: see _panelEl. A plain GuiElement has no such method, and requiring it
    -- is what made the first build draw nothing at all.
    if root == nil then return false end
    if d == nil then
        if root.setVisible ~= nil then root:setVisible(false) end
        return false
    end
    if root.setVisible ~= nil then root:setVisible(true) end
    AnimalPanel._panelReset(root)

    local L = HusbandryRedux.l10n
    local COL = AnimalPanel.PANEL_COLOURS
    local function pct(v) return string.format("%d%%", math.floor((v or 0) * 100 + 0.5)) end

    -- ---- block A: the herd ---------------------------------------------------------------------
    -- A COUNT IS A NUMBER, NOT A CHART. It has no magnitude worth encoding and no parts, so it is
    -- set as a hero figure with the capacity bar beneath it carrying the only comparison there is.
    local herd = d.herd or {}
    AnimalPanel._panelText(root, "apHerdLabel", L("dr_panel_animals", "ANIMALS"))
    if herd.count ~= nil then
        local txt = tostring(math.floor(herd.count + 0.5))
        if herd.max ~= nil and herd.max > 0 then
            txt = txt .. "  / " .. tostring(math.floor(herd.max + 0.5))
        end
        AnimalPanel._panelText(root, "apCount", txt)
        AnimalPanel._panelFill(root, "apCapFill", (herd.max ~= nil and herd.max > 0) and (herd.count / herd.max) or 0, "apCapBg")
    else
        AnimalPanel._panelText(root, "apCount", "-")
        AnimalPanel._panelFill(root, "apCapFill", 0, "apCapBg")
    end

    if herd.health ~= nil then
        AnimalPanel._panelText(root, "apHealthLabel", L("dr_panel_health", "HEALTH") .. "   " .. pct(herd.health))
        AnimalPanel._panelFill(root, "apHealthFill", herd.health, "apHealthBg")
        -- STATUS COLOURS ARE RESERVED and never reused as a series hue: the health fill is the only
        -- place a good/warning/critical reading is expressed, and it never appears in the feed
        -- legend. Bands match the Overview's own MET_TARGET / NEAR_TARGET convention.
        local e = AnimalPanel._panelEl(root, "apHealthFill")
        if e ~= nil and e.setImageColor ~= nil then
            if herd.health >= 0.75 then e:setImageColor(nil, 0.31, 0.72, 0.31, 1)
            elseif herd.health >= 0.50 then e:setImageColor(nil, 1.00, 0.62, 0.10, 1)
            else e:setImageColor(nil, 0.72, 0.20, 0.17, 1) end
        end
    else
        AnimalPanel._panelText(root, "apHealthLabel", L("dr_panel_health", "HEALTH") .. "   -")
        AnimalPanel._panelFill(root, "apHealthFill", 0, "apHealthBg")
    end

    -- PRODUCTIVITY -- the base game's OWN headline (globalProductionFactor x
    -- productionFactor, exactly as getConditionInfos computes it). Deliberately its own bar rather
    -- than a number folded into the feed block: it is NOT the food factor, food is one input to it,
    -- so a barn can be perfectly fed and still sit at 15% for a reason nothing else here would show.
    -- Same status bands as HEALTH, because it is the same kind of reading.
    -- THE TWO ADVICE LINES. The text is the provider's (it owns the vocabulary);
    -- the PALETTE is DR's, so the tone arrives as a word and is mapped here. Same
    -- status bands as the bars they sit beside -- an advice line is a status
    -- reading, and the categorical palette stays reserved for the feed groups.
    local function advice(name, a)
        if type(a) ~= "table" or a.text == nil then
            AnimalPanel._panelText(root, name, "")
            return
        end
        if a.tone == "good" then AnimalPanel._panelText(root, name, a.text, 0.31, 0.72, 0.31)
        elseif a.tone == "warn" then AnimalPanel._panelText(root, name, a.text, 1.00, 0.62, 0.10)
        elseif a.tone == "bad" then AnimalPanel._panelText(root, name, a.text, 0.72, 0.20, 0.17)
        else AnimalPanel._panelText(root, name, a.text) end
    end
    advice("apHerdAdvice", herd.advice)

    local prodLbl = L("dr_panel_productivity", "PRODUCTIVITY")
    if herd.prodApplies == false then
        -- the base game hides this for horses and pigs, which is a different fact from zero
        AnimalPanel._panelText(root, "apProdLabel", prodLbl .. "   " .. L("dr_panel_na", "n/a"))
        AnimalPanel._panelFill(root, "apProdFill", 0, "apProdBg")
    elseif herd.productivity ~= nil then
        AnimalPanel._panelText(root, "apProdLabel", prodLbl .. "   " .. pct(herd.productivity))
        AnimalPanel._panelFill(root, "apProdFill", herd.productivity, "apProdBg")
        local e = AnimalPanel._panelEl(root, "apProdFill")
        if e ~= nil and e.setImageColor ~= nil then
            if herd.productivity >= 0.75 then e:setImageColor(nil, 0.31, 0.72, 0.31, 1)
            elseif herd.productivity >= 0.50 then e:setImageColor(nil, 1.00, 0.62, 0.10, 1)
            else e:setImageColor(nil, 0.72, 0.20, 0.17, 1) end
        end
    else
        AnimalPanel._panelText(root, "apProdLabel", prodLbl .. "   -")
        AnimalPanel._panelFill(root, "apProdFill", 0, "apProdBg")
    end

    -- ---- block B: feed -------------------------------------------------------------------------
    local feed = d.feed or {}
    AnimalPanel._panelText(root, "apFeedLabel", L("dr_panel_feed", "FEED"))
    local title = L("dr_panel_noFeedData", "no feed data")
    if feed.factor ~= nil then
        title = string.format(L("dr_panel_foodFactor", "Food factor %s"), pct(feed.factor))
        if feed.serial and feed.activeTitle ~= nil then
            title = title .. "   -   " .. feed.activeTitle
        end
        if feed.grazes then
            -- A MEADOW FEEDS OUTSIDE THE TROUGH, so the groups below can all read 0 L while the
            -- factor is well above zero. Said on the panel rather than left as a contradiction.
            title = title .. "   (" .. L("dr_panel_grazing", "grazing") .. ")"
        end
    end
    AnimalPanel._panelText(root, "apFeedTitle", title)
    advice("apFeedAdvice", feed.advice)

    local groups = feed.groups or {}
    -- the segments and the tier marks are CHILDREN of apFeedBg, so they are positioned and sized in
    -- that element's own normalized width, exactly as the storage bar's marks are
    local W = AnimalPanel._panelTrackW(root, "apFeedBg")
    if feed.serial then
        -- SERIAL (a cow): the tiers are ALTERNATIVES, so there is nothing to stack. One fill to the
        -- factor actually achieved, and a tick where each tier sits, which is what turns the bar
        -- into "you are on Silage, TMR is the one above". Stacking these would draw
        -- 0.4 + 0.8 + 0.8 = 2.0 for a barn holding grass and hay and silage.
        local seg = AnimalPanel._panelEl(root, "apSeg1")
        if seg ~= nil then
            if seg.setImageColor ~= nil then seg:setImageColor(nil, COL[1][1], COL[1][2], COL[1][3], 1) end
            if seg.setPosition ~= nil then seg:setPosition(0, nil) end
            AnimalPanel._panelFill(root, "apSeg1", feed.factor or 0, "apFeedBg")
        end
        for i, g in ipairs(groups) do
            if i <= AnimalPanel.PANEL_MAX_GROUPS then
                local m = AnimalPanel._panelEl(root, "apTier" .. i)
                if m ~= nil then
                    if m.setPosition ~= nil then
                        -- keep the mark inside the track, using the mark's OWN width: the figure
                        -- here is normalized, so the "2" this was written with (2 PIXELS) was twice
                        -- the screen and inverted the clamp
                        local mw = (m.absSize ~= nil and m.absSize[1]) or (m.size ~= nil and m.size[1]) or 0
                        m:setPosition(math.min(W * math.max(0, math.min(1, g.share)),
                                               math.max(0, W - mw)), nil)
                    end
                    if m.setVisible ~= nil then m:setVisible(true) end
                end
                -- A TIER THAT IS NOT IN THE TROUGH IS DIMMED. Without this the legend lists four
                -- tiers at their headline values (Grass 40%, Silage 80%, TMR 100%) whatever the barn
                -- actually holds, so a factor of 0 sits beside four healthy-looking percentages with
                -- nothing explaining the gap. Presence is what decides a SERIAL factor, so it is the
                -- one thing this legend has to show.
                local present = (g.met or 0) > 0
                local sw = AnimalPanel._panelEl(root, "apLegSw" .. i)
                if sw ~= nil then
                    if sw.setImageColor ~= nil then
                        if present then sw:setImageColor(nil, COL[1][1], COL[1][2], COL[1][3], 1)
                        else sw:setImageColor(nil, 1, 1, 1, 0.18) end
                    end
                    if sw.setVisible ~= nil then sw:setVisible(true) end
                end
                if present then
                    AnimalPanel._panelText(root, "apLegTx" .. i,
                        string.format("%s  %s", g.title, pct(g.share)))
                else
                    AnimalPanel._panelText(root, "apLegTx" .. i,
                        string.format("%s  %s", g.title, pct(g.share)), 0.55, 0.55, 0.55)
                end
            end
        end
    else
        -- PARALLEL: each group contributes production x met and the sum IS the factor, so the
        -- stacked bar is literally the arithmetic rather than a picture of it.
        local x = 0
        -- the surface gap between stacked segments, converted from px to this track's own units
        local gap = 0
        do
            local _, _ = nil, nil
            local gx = select(1, AnimalPanel._pxNorm(AnimalPanel.PANEL_SEG_GAP, 0))
            if type(gx) == "number" then gap = gx end
        end
        for i, g in ipairs(groups) do
            if i <= AnimalPanel.PANEL_MAX_GROUPS then
                local ci = math.floor(g.colourIndex or i)
                if ci < 1 or ci > #COL then ci = ((i - 1) % #COL) + 1 end
                local contributes = (g.share or 0) * (g.met or 0)
                local w = W * math.max(0, math.min(1, contributes))
                local seg = AnimalPanel._panelEl(root, "apSeg" .. i)
                if seg ~= nil then
                    if seg.setImageColor ~= nil then
                        seg:setImageColor(nil, COL[ci][1], COL[ci][2], COL[ci][3], 1)
                    end
                    if seg.setPosition ~= nil then seg:setPosition(x, nil) end
                    -- the 2px surface gap goes on the RIGHT of every segment but the last, so the
                    -- run of colours never ends short of the value it represents
                    if seg.setSize ~= nil then seg:setSize(math.max(0, w - gap), nil) end
                    if seg.setVisible ~= nil then seg:setVisible(w > 1e-5) end
                end
                x = x + w
                local sw = AnimalPanel._panelEl(root, "apLegSw" .. i)
                if sw ~= nil then
                    if sw.setImageColor ~= nil then
                        sw:setImageColor(nil, COL[ci][1], COL[ci][2], COL[ci][3], 1)
                    end
                    if sw.setVisible ~= nil then sw:setVisible(true) end
                end
                -- DIRECT LABELS, so identity is never colour alone: the legend names the group AND
                -- what it is actually contributing, which is the number the bar encodes.
                AnimalPanel._panelText(root, "apLegTx" .. i, string.format("%s  %s", g.title, pct(contributes)))
            end
        end
    end

    -- ---- block C: herd value -------------------------------------------------------------------
    local val = d.value or {}
    AnimalPanel._panelText(root, "apValueLabel", L("dr_panel_herdValue", "HERD VALUE"))
    if val.current ~= nil then
        AnimalPanel._panelText(root, "apValueMain", AnimalPanel.formatMoney ~= nil
                  and AnimalPanel.formatMoney(val.current) or tostring(math.floor(val.current)))
        local pot = val.potential
        if pot ~= nil and pot > 0 then
            AnimalPanel._panelFill(root, "apValueFill", val.current / pot, "apValueBg")
            AnimalPanel._panelText(root, "apValueOf", string.format(L("dr_panel_ofPeak", "of %s at peak age"),
                      AnimalPanel.formatMoney ~= nil and AnimalPanel.formatMoney(pot)
                      or tostring(math.floor(pot))))
        else
            AnimalPanel._panelFill(root, "apValueFill", 0, "apValueBg")
            AnimalPanel._panelText(root, "apValueOf", "")
        end
    else
        AnimalPanel._panelText(root, "apValueMain", "-")
        AnimalPanel._panelFill(root, "apValueFill", 0, "apValueBg")
        AnimalPanel._panelText(root, "apValueOf", "")
    end
    -- PAST PEAK is a state, not a series, so it gets a status colour and a WORD rather than being
    -- encoded in the bar: only cows decline with age, and a falling bar with no explanation reads
    -- as something the player did wrong rather than as "sell these now".
    -- THE HERD VALUE ADVICE takes this line when the provider sends one (2026-09-14):
    -- profit in green, a loss in red with the fix. It supersedes the past-peak note,
    -- which is one of the fixes it can name.
    if type(val.advice) == "table" and val.advice.text ~= nil then
        advice("apValueNote", val.advice)
    elseif val.pastPeak then
        AnimalPanel._panelText(root, "apValueNote", L("dr_panel_pastPeak", "past peak - value falls with age"),
                  1.00, 0.62, 0.10)
    else
        AnimalPanel._panelText(root, "apValueNote", "")
    end

    -- ---- block D: profit -----------------------------------------------------------------------
    -- WHAT THE BARN MAKES, per month, under the value it is made of:
    --     increase in animal value + outputs sold - inputs bought
    --
    -- SIGNED AND COLOURED, because the sign is the whole message and a reader must
    -- not have to compare two figures to find out which way it went. The green and
    -- the red are the panel's own STATUS colours (the health bands), not series
    -- hues -- profitable or not is a status reading, and the categorical palette
    -- stays reserved for the feed groups so a legend swatch never means "good".
    --
    -- A MISSING TERM SHOWS A DASH, NOT A NUMBER. `complete` is false whenever any
    -- of the four terms could not be priced, and a profit quoted without its feed
    -- cost or without its capital side is not a smaller profit -- it is a different
    -- figure wearing the same label (5.46c's nil-is-not-zero, and 15.7 of Animal
    -- Redux, which shipped exactly this bug once).
    local pr = d.profit or {}
    local o = opts or {}
    local scale = (type(o.profitScale) == "number" and o.profitScale > 0) and o.profitScale or 1
    -- "EST. FORECAST" IS PART OF THE LABEL, not a footnote. Every term in this block is
    -- today's rate at today's price projected forward; none of it is a measurement of
    -- anything that has happened, and a money figure with no such qualifier reads as one.
    -- THE LABEL IS EMITTED FURTHER DOWN, once `signed` exists: it now carries the
    -- PROSPECTIVE figure, and formatting that needs the helper. Calling it up here
    -- would resolve to a nil upvalue -- valid syntax, so luac -p passes, and it throws
    -- only when reached (the 5.44 / 5.57 trap, and the one that blanked this very
    -- block for two days).
    -- FINE formatting here, not fmtMoney: at a one-hour period a term can be a few
    -- cents, and a whole-unit round would print it as "+0" beside three figures
    -- that are not zero either
    local money = AnimalPanel.formatMoneyFine or AnimalPanel.formatMoney
    local function signed(v)
        if v == nil then return "-" end
        v = v * scale
        local t = (money ~= nil) and money(math.abs(v)) or tostring(math.floor(math.abs(v)))
        if v < 0 then return "-" .. t end
        return "+" .. t
    end
    -- THE ARITHMETIC SITS DIRECTLY ABOVE THE HEADLINE IT EXPLAINS. It first went in
    -- the dead strip under blocks A and B, which is where the space was; on screen
    -- it read as a stray line under HEALTH with no visible connection to the figure
    -- it decomposes (reported from a screenshot). Two rows of two, in this column.
    local function part(name, key, fallback, v)
        AnimalPanel._panelText(root, name, L(key, fallback) .. " " .. signed(v))
    end
    -- THE SECOND FIGURE RIDES IN THE LABEL, and that is a space decision rather than a
    -- preference: block C is full to both edges (the value bar above it, the four
    -- breakdown cells below), so a fifth element would have to take height from blocks
    -- A or B -- and this markup is duplicated in DR's copy, so every new child is a
    -- two-mod change that tools/husbandrypanel.lua then has to hold in step. The label
    -- has the room and costs neither.
    --
    -- SHOWN ONLY WHEN THE TWO DIFFER, which is exactly when it is worth reading: they
    -- differ only while the pen is destroying births, and the suffix vanishes the
    -- moment the player makes room. So its ABSENCE is the "nothing is being wasted"
    -- signal, and a healthy barn keeps a clean label.
    local baseLabel = o.profitLabel or L("dr_panel_profit", "EST. PROFIT / MO")
    if pr.complete and pr.perMonth ~= nil and pr.perMonthProspective ~= nil
       and math.abs(pr.perMonthProspective - pr.perMonth) >= 0.5 then
        baseLabel = baseLabel .. "  " .. L("dr_panel_pfCleared", "if cleared:")
                    .. " " .. signed(pr.perMonthProspective)
    end
    AnimalPanel._panelText(root, "apProfitLabel", baseLabel)

    if pr.complete and pr.perMonth ~= nil then
        local v = pr.perMonth * scale
        if v >= 0 then
            AnimalPanel._panelText(root, "apProfitMain", signed(pr.perMonth), 0.31, 0.72, 0.31)
        else
            AnimalPanel._panelText(root, "apProfitMain", signed(pr.perMonth), 0.72, 0.20, 0.17)
        end
        part("apProfitP1", "dr_panel_pfOutputs", "outputs", pr.outputs)
        -- INPUTS ARE NEGATED FOR DISPLAY. The provider reports a cost as a positive
        -- number because that is what it is; the row reads as money leaving, so it
        -- carries the sign a reader expects to see beside the three terms that add.
        part("apProfitP2", "dr_panel_pfInputs", "inputs", pr.inputs ~= nil and -pr.inputs or nil)
        part("apProfitP3", "dr_panel_pfAgeing", "ageing", pr.ageing)
        part("apProfitP4", "dr_panel_pfBirths", "births", pr.births)
    else
        AnimalPanel._panelText(root, "apProfitMain", "-")
        for _, n in ipairs({ "apProfitP1", "apProfitP2", "apProfitP3", "apProfitP4" }) do
            AnimalPanel._panelText(root, n, "")
        end
    end
    return true
end

---Volumes, litres below 1,000 and KILOLITRES above (ported from DR 5.56).
--
-- PORTED RATHER THAN BORROWED so this page reads the same with or without DR. The old fallback was
-- a bare "%d L", so a standalone player would have seen 600000 L where a DR player saw 600 kL --
-- the same figure written two ways depending on which mods happen to be installed.
--
-- Three decimals is exactly one litre of resolution, so the kL form loses nothing: it is the same
-- number with the point moved, which is why the switchover can be silent rather than a rounding
-- cliff. Rounded to whole litres FIRST and then tested against the threshold, or 999.6 would read
-- "1,000 L" on one branch and "1 kL" on the other.
function AnimalPanel.formatVolume(v)
    if type(v) ~= "number" or v ~= v then return "-" end          -- nil / NaN
    if v >= math.huge or v <= -math.huge then return "-" end
    local n = math.floor(math.abs(v) + 0.5)
    local sign = (v < 0 and n > 0) and "-" or ""
    local s, unit
    if n < 1000 then
        s, unit = tostring(n), HusbandryRedux.l10n("ar_unit_litre", " L")
    else
        s = string.format("%.3f", n / 1000)
        s = s:gsub("0+$", "")                                     -- drop extraneous zeros: 600.000 -> 600.
        s = s:gsub("%.$", "")                                     -- ...and the bare point it can leave
        unit = HusbandryRedux.l10n("ar_unit_kilolitre", " kL")
    end
    -- thousands separators on the integer part (1,234.567 kL); the decimals must not be grouped
    local int, freq = s:match("^(%d+)"), nil
    if int ~= nil and #int > 3 then
        local grouped = int
        repeat grouped, freq = grouped:gsub("^(%d+)(%d%d%d)", "%1,%2") until freq == 0
        s = grouped .. s:sub(#int + 1)
    end
    return sign .. s .. unit
end
