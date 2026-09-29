-- ============================================================================
-- AnimalTradeDialog.lua  (Husbandry Redux)
--
-- BUY AND SELL, in one window, opened from either Herd Inspector view.
--
-- IT IS CONTEXT SENSITIVE, and that is the whole reason it is ours rather than a
-- shortcut to the base game's screen:
--   * opened from the BARN view  -> that barn only, and the barn selector is hidden
--                                   because there is nothing to choose;
--   * opened from the GROUPS view -> every barn, defaulted to the SELECTED ROW's
--                                   barn and, in sell mode, to that row's group.
-- A dialog that made the player find the barn again would be worse than the base
-- screen, not better.
--
-- NOTHING HERE COMPUTES A PRICE. Every figure comes from AnimalTrade, which asks
-- the game's own controller -- see that file for what is measured and what is read.
-- 13.5's lesson is the reason: the cluster's own sell price is the GROSS, and a
-- screen quoting it over-states every sale by the dealer's flat fee.
--
-- THE QUOTE IS RE-ASKED FOR THE ACTUAL AMOUNT, never multiplied up from one animal.
-- Today the price scales linearly, but a dealer that ever discounted a batch would
-- make a multiplied figure a lie at the moment the player commits -- and the quote
-- is what they are agreeing to.
-- ============================================================================

AnimalTradeDialog = {}
local AnimalTradeDialog_mt = Class(AnimalTradeDialog, MessageDialog)

-- THE SELECTOR UNDER "HOW MANY" PICKS THE AMOUNT ITSELF.
--
-- It used to pick a STEP, with the amount changed by footer buttons -- reported as
-- "changing the how many just cycles between STEP 1, 5, 10, 25 and doesn't seem to
-- do anything to vary the number". Which is exactly right: a control sitting under
-- a heading that says HOW MANY must answer that question, not configure some other
-- control that does.
--
-- The list is filtered to what is actually available and always ends in ALL, so it
-- is short enough to arrow through on any herd. The footer keeps +/- 1 for the
-- amounts the list does not name.
-- EVERY NUMBER FROM 1 TO THE MAXIMUM, so the arrows step by ONE (author's call).
-- The earlier list of round quantities meant one press could jump 25, which is not
-- what a control with two arrows looks like it will do.
AnimalTradeDialog.MAX_LISTED = 400

local function l10n(key, fallback)
    if HusbandryRedux ~= nil and HusbandryRedux.l10n ~= nil then return HusbandryRedux.l10n(key, fallback) end
    return fallback
end

local function money(v)
    if type(v) ~= "number" then return "-" end
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, s = pcall(g_i18n.formatMoney, g_i18n, v, 0, true, true)
        if ok and s ~= nil then return tostring(s) end
    end
    return string.format("%d", math.floor(v + 0.5))
end

local function setText(el, txt, r, g, b)
    if el == nil then return end
    if el.setText ~= nil then el:setText(txt or "") end
    if el.setTextColor ~= nil then
        if r ~= nil then el:setTextColor(r, g, b, 1) else el:setTextColor(1, 1, 1, 1) end
    end
end

function AnimalTradeDialog.new(target, custom_mt)
    local self = MessageDialog.new(target, custom_mt or AnimalTradeDialog_mt)
    self.mode, self.barnIndex, self.rowIndex, self.amount = AnimalTrade.MODE_SELL, 1, 1, 1
    self.rows, self.barns, self.quantities = {}, {}, {}
    return self
end

---Open it. `barns` is the list to offer, `lockBarn` hides the selector entirely
-- (the barn view's case), and `preferCluster` defaults the row.
function AnimalTradeDialog.show(barns, lockBarn, preferCluster, mode)
    local d = AnimalTradeDialog._instance
    if d == nil then return false end
    d.barns = barns or {}
    d.lockBarn = lockBarn == true
    d.preferCluster = preferCluster
    d.mode = mode or AnimalTrade.MODE_SELL
    d.barnIndex, d.rowIndex, d.amount = 1, 1, 1
    g_gui:showDialog("AnimalTradeDialog")
    return true
end

---THE DATA SOURCE IS SET IN onOpen, NOT IN onGuiSetupFinished.
--
-- Reported 2026-08-31 on the first build: both lists came up empty, nothing could be
-- selected, and with no row selected there was no quote and therefore no money on
-- screen either. FOUR SYMPTOMS, ONE CAUSE -- the list never had a data source, so it
-- had nothing to ask for rows.
--
-- DistributionInputsDialog does this in onOpen and it works; the setup hook is not a
-- reliable place for it on a dialog loaded through loadGui with a target. It is done
-- in BOTH now: onOpen is the one that is guaranteed, and doing it twice costs a
-- pointer assignment.
function AnimalTradeDialog:onGuiSetupFinished()
    AnimalTradeDialog:superClass().onGuiSetupFinished(self)
    self:bindList()
end

function AnimalTradeDialog:bindList()
    if self.tradeList ~= nil then
        self.tradeList:setDataSource(self)
        self.tradeList:setDelegate(self)
    end
end

function AnimalTradeDialog:onOpen()
    AnimalTradeDialog:superClass().onOpen(self)
    self:bindList()
    self:initSelectors()
    self:rebuild()
end

function AnimalTradeDialog:barn()
    local b = self.barns[self.barnIndex]
    return b, (b ~= nil and b.placeable or nil)
end

function AnimalTradeDialog:initSelectors()
    -- THE MODE TABS. Two peers, so tabs rather than a selector.
    if AnimalTabs ~= nil then
        AnimalTabs.render(self, AnimalTradeDialog.modeLabels(), self.mode)
    end
    local names = {}
    for _, b in ipairs(self.barns) do names[#names + 1] = tostring(b.name or "?") end
    if #names == 0 then names = { l10n("ar_td_noBarn", "no barn") } end
    if self.barnOption ~= nil and self.barnOption.setTexts ~= nil then
        self.barnOption:setTexts(names)
        if self.barnOption.setState ~= nil then
            self.barnOption:setState(math.min(self.barnIndex, #names))
        end
    end
    -- HIDDEN, not disabled, when there is nothing to choose: a control that cannot
    -- do anything is worse than no control (5.74's disabled-button reasoning, one
    -- step further because here the whole choice is absent rather than inert).
    if self.barnBox ~= nil and self.barnBox.setVisible ~= nil then
        self.barnBox:setVisible(not self.lockBarn and #self.barns > 1)
    end
    self:initAmountOption()
end

---The quantities offered for the CURRENT row, which is why it is rebuilt whenever
-- the row or the mode changes: "all" means something different on a group of 4 and a
-- group of 96, and offering 50 on a group of 4 is offering a refusal.
function AnimalTradeDialog:initAmountOption()
    local o = self.amountOption
    if o == nil then return end
    local m = math.min(self:maxAmount(), AnimalTradeDialog.MAX_LISTED)
    self.quantities = {}
    local texts = {}
    for q = 1, m do
        self.quantities[q] = q
        texts[q] = (q == m and m > 1) and string.format(l10n("ar_td_qtyAll", "%d  (all)"), q)
                                       or tostring(q)
    end
    if #texts == 0 then texts = { "0" } end
    if o.setTexts ~= nil then o:setTexts(texts) end
    -- keep the selector on whatever the amount actually IS, so the footer buttons and
    -- this control can never disagree about the number the money is quoted for
    local idx = math.max(1, math.min(self.amount or 1, #self.quantities))
    if o.setState ~= nil then pcall(o.setState, o, idx) end
end



-- ---------------------------------------------------------------------------
function AnimalTradeDialog:rebuild()
    local _, p = self:barn()
    self.rows, self.loadError = {}, nil
    if p ~= nil and AnimalTrade ~= nil then
        local rows, err
        if self.mode == AnimalTrade.MODE_BUY then rows, err = AnimalTrade.buyRows(p)
        else rows, err = AnimalTrade.sellRows(p) end
        self.rows, self.loadError = rows or {}, err
    end

    -- DEFAULT TO THE ROW THE PLAYER CAME FROM. Matched on the CLUSTER OBJECT, not a
    -- name or an index: two groups of the same animal at different ages are a
    -- routine thing on any barn, and a name match would land on whichever came
    -- first (the identity rule 5.37 and DR 6.29 both rest on).
    local matched = false
    if self.mode == AnimalTrade.MODE_SELL and self.preferCluster ~= nil then
        for i, r in ipairs(self.rows) do
            if r.cluster == self.preferCluster then self.rowIndex = i; matched = true; break end
        end
    end
    if self.rowIndex > #self.rows then self.rowIndex = 1 end

    self:clampAmount()
    self:initAmountOption()
    if self.tradeList ~= nil then
        -- GUARDED: setSelectedItem raises the selection callback, which would re-enter
        -- this mid-build and read a row list that is still being replaced. DR's own
        -- dialog carries the same `_refreshing` guard for the same reason.
        self._refreshing = true
        self.tradeList:reloadData()
        if #self.rows > 0 then
            pcall(self.tradeList.setSelectedItem, self.tradeList, 1, self.rowIndex, true)
            -- AND SCROLLED INTO VIEW when it is the group the player came from
            -- (2026-09-13, the Pigs tab's per-row Sell). Selecting a row does not
            -- promise it is on screen, and a list of about eleven rows can hold a
            -- barn's twelfth group below the fold. smoothScrollTo is the list's own
            -- and clamps the offset to the content (SmoothListElement.lua:1185).
            local l = self.tradeList
            local sec = matched and type(l.sections) == "table" and l.sections[1] or nil
            local off = type(sec) == "table" and type(sec.itemOffsets) == "table"
                        and sec.itemOffsets[self.rowIndex] or nil
            if type(off) == "number" and l.smoothScrollTo ~= nil then
                pcall(l.smoothScrollTo, l, off)
            end
        end
        self._refreshing = false
    end
    self:refresh()
end

function AnimalTradeDialog:row() return self.rows[self.rowIndex] end

---How many may be traded at once. SELL is bounded by the group; BUY by the free
-- slots the barn actually has, because the game refuses the rest anyway and a
-- screen that lets a player dial in 40 for a pen with 4 slots is inviting a
-- refusal it could have prevented.
function AnimalTradeDialog:maxAmount()
    local r = self:row()
    if r == nil then return 0 end
    if self.mode == AnimalTrade.MODE_BUY then
        local b = self:barn()
        local free = (b ~= nil and b.free) or 0
        return math.max(0, math.floor(free))
    end
    return math.max(0, math.floor(r.count or 0))
end

function AnimalTradeDialog:clampAmount()
    local m = self:maxAmount()
    if m <= 0 then self.amount = 0; return end
    if type(self.amount) ~= "number" or self.amount < 1 then self.amount = 1 end
    if self.amount > m then self.amount = m end
end

-- ---------------------------------------------------------------------------
function AnimalTradeDialog:refresh()
    local buy = (self.mode == AnimalTrade.MODE_BUY)
    local b = self:barn()

    -- REDRAWN EVERY REFRESH, not only at open: the plate is a separate element
    -- from the button, so a mode change that did not repaint would leave the green
    -- block on the tab the player just left.
    if AnimalTabs ~= nil then AnimalTabs.render(self, AnimalTradeDialog.modeLabels(), self.mode) end

    setText(self.dialogTitleElement, buy and l10n("ar_td_title_buy", "Husbandry Redux - Buy Animals")
                                         or l10n("ar_td_title_sell", "Husbandry Redux - Sell Animals"))
    -- FREE SLOTS BELONGS BESIDE THE BARN NAME, not in a column. It is a property of
    -- the BUILDING and was identical on every row of the buy table, which is a column
    -- carrying no information -- it only told the reader something once, at the cost
    -- of a fifth of the table's width.
    local sub = b ~= nil and tostring(b.name or "") or ""
    if b ~= nil and b.free ~= nil then
        sub = string.format(l10n("ar_td_barnFree", "%s   -   %d free slots"), sub, b.free)
    end
    setText(self.dialogTextElement, sub)
    setText(self.hdrAnimal, buy and l10n("ar_td_col_offered", "OFFERED")
                                or l10n("ar_td_col_animal", "GROUP"))
    setText(self.hdrEachNet, buy and l10n("ar_td_col_eachCost", "COST EACH")
                                 or l10n("ar_td_col_eachNet", "NET EACH"))

    -- THE EMPTY STATE SAYS WHY, because the three reasons want different actions:
    -- a client cannot trade at all, a missing controller is a broken install, and an
    -- empty catalogue is simply nothing on offer today.
    local emptyMsg = nil
    if #self.rows == 0 then
        local can, why = AnimalTrade.canTrade()
        if not can and why == "client" then
            emptyMsg = l10n("ar_td_empty_client", "Trading runs on the server only.")
        elseif not can then
            emptyMsg = l10n("ar_td_empty_noctrl", "The animal dealer is not available in this build.")
        elseif self.loadError ~= nil then
            emptyMsg = tostring(self.loadError)
        elseif buy then
            emptyMsg = l10n("ar_td_empty_buy", "The dealer has nothing this barn can take.")
        else
            emptyMsg = l10n("ar_td_empty_sell", "This barn has no animals to sell.")
        end
    end
    setText(self.emptyNote, emptyMsg or "")
    -- the BOX, not the text: hiding a child of a hidden container achieves nothing,
    -- and the container is what carries the position (see the XML)
    if self.emptyBox ~= nil and self.emptyBox.setVisible ~= nil then
        self.emptyBox:setVisible(emptyMsg ~= nil)
    end

    -- THE QUOTE IS ASKED FOR THE ACTUAL AMOUNT (see the header). nil is UNKNOWN and
    -- shown as a dash, never as zero: a transaction whose price could not be read is
    -- not a free one, and the commit button is disabled rather than guessing.
    local q = nil
    local r = self:row()
    if r ~= nil and (self.amount or 0) >= 1 then
        local _, pl = self:barn()
        q = AnimalTrade.quote(pl, self.mode, r, self.amount)
    end
    self.quote = q

    setText(self.lblGross, buy and l10n("ar_td_lbl_price", "Price") or l10n("ar_td_lbl_value", "Sale value"))
    setText(self.lblFee,   l10n("ar_td_lbl_fee", "Dealer fee"))
    setText(self.lblTotal, buy and l10n("ar_td_lbl_totalCost", "TOTAL COST")
                               or l10n("ar_td_lbl_totalGain", "TOTAL GAINED"))
    if q == nil then
        setText(self.valGross, "-"); setText(self.valFee, "-"); setText(self.valTotal, "-")
    else
        setText(self.valGross, q.gross ~= nil and money(math.abs(q.gross)) or "-")
        -- THE FEE IS SHOWN AS A COST WHICHEVER WAY THE GAME SIGNS IT. 13.5 measured
        -- it arriving negative on a sale; presenting the raw sign would put a minus
        -- on one screen and not the other for the same 100 an animal.
        setText(self.valFee, q.fee ~= nil and ("-" .. money(math.abs(q.fee))) or "-",
                1.00, 0.62, 0.10)
        local net = q.net
        if net ~= nil then
            if buy then setText(self.valTotal, money(math.abs(net)), 0.72, 0.20, 0.17)
            else setText(self.valTotal, money(math.abs(net)), 0.31, 0.72, 0.31) end
        else
            setText(self.valTotal, "-")
        end
    end

    local note = ""
    if r ~= nil and self:maxAmount() <= 0 then
        note = buy and l10n("ar_td_note_full", "This barn has no free slots.")
                    or l10n("ar_td_note_none", "Nothing in this group to sell.")
    elseif self.result ~= nil then
        note = self.result
    end
    setText(self.noteText, note)

    local canCommit = (r ~= nil and (self.amount or 0) >= 1 and q ~= nil and q.net ~= nil)
    if self.commitButton ~= nil and self.commitButton.setDisabled ~= nil then
        pcall(self.commitButton.setDisabled, self.commitButton, not canCommit)
    end
    if self.commitButton ~= nil and self.commitButton.setText ~= nil then
        self.commitButton:setText(buy and l10n("ar_td_buyNow", "Buy") or l10n("ar_td_sellNow", "Sell"))
    end
end

-- ---------------------------------------------------------------------------
-- LIST
-- ---------------------------------------------------------------------------
function AnimalTradeDialog:getNumberOfSections() return 1 end
function AnimalTradeDialog:getNumberOfItemsInSection() return #self.rows end

function AnimalTradeDialog:populateCellForItemInSection(list, section, index, cell)
    local r = self.rows[index]
    if r == nil then return end
    local function set(n, t)
        local e = cell:getAttribute(n)
        if e ~= nil and e.setText ~= nil then e:setText(t or "") end
    end
    local icon = cell:getAttribute("fillIcon")
    if icon ~= nil then
        -- resolved once, when the row was built, so both lists take one path
        local f = r.icon
        -- ACTIVELY HIDDEN when there is no file: SmoothList recycles cells and
        -- setImageFilename on a missing file leaves the PREVIOUS texture in place,
        -- so a row with no picture would wear the last row's (18.17).
        if f ~= nil and icon.setImageFilename ~= nil then
            icon:setImageFilename(f)
            if icon.setVisible ~= nil then icon:setVisible(true) end
        elseif icon.setVisible ~= nil then icon:setVisible(false) end
    end
    -- THE GROUP SIZE RIDES WITH THE NAME on the sell side. It had its own column
    -- while the buy side used that column for free slots -- one column meaning two
    -- different things by mode, which is how a header comes to lie about its cells.
    if self.mode == AnimalTrade.MODE_SELL and (r.count or 0) > 0 then
        set("tdName", string.format(l10n("ar_td_nameCount", "%s   x%d"), r.name, r.count))
    else
        set("tdName", r.name)
    end
    -- THE ITEM'S OWN AGE TEXT FIRST. arTradeDump showed these items carrying `infos`,
    -- which is the list the base screen itself renders -- so where the animal record
    -- has no `age` field, the age is in there already FORMATTED, and reproducing it
    -- from a number would be a second opinion about the same fact.
    set("tdAge", r.ageText or (r.age ~= nil and string.format(l10n("ar_td_months", "%d mo"), r.age)) or "-")
    set("tdEach", r.eachGross ~= nil and money(math.abs(r.eachGross)) or "-")
    set("tdEachNet", r.eachNet ~= nil and money(math.abs(r.eachNet)) or "-")
end

---THE SELECTED ROW, TAKEN FROM THE LIST ITSELF and not from an argument position.
--
-- Reported 2026-08-31: selecting a group changed neither the amount control nor the
-- money. SmoothList's raise site is in the stripped part of the SDK source, so the
-- argument list cannot be read -- and this file already carries the same lesson for
-- ButtonElement (DR 5.64: "scan the varargs for the element carrying that field
-- rather than assuming a position"). A handler that guesses wrong here silently
-- pins every figure on the dialog to row 1, which is exactly what was seen.
--
-- The list's own `selectedIndex` is the authority; the argument is only a hint, used
-- when the element cannot answer.
---THE SELECTED ROW. The CALLBACK ARGUMENT wins where there is one; the element is
-- read only when there is not.
--
-- The order matters and was wrong the other way round. Reported 2026-08-31: "on first
-- click nothing changes, then if you click back it changes, but the numbers are for
-- the LAST selected group" -- the signature of reading a value that has not been
-- updated yet. `onSelectionChanged` is raised BEFORE the list's own `selectedIndex`
-- moves, so reading the element there is always one selection behind; by the next
-- click it has caught up, which is why a second click showed the first click's row.
--
-- The click callback is the opposite case and reads the element correctly, because
-- notifyClick is raised AFTER the selection is applied (DR 6.29). Hence one resolver
-- taking both: the argument if it has one, the element if it does not.
function AnimalTradeDialog:selectedRowIndex(...)
    for _, v in ipairs({ ... }) do
        if type(v) == "number" and v >= 1 and v <= #self.rows then return v end
    end
    local l = self.tradeList
    if l ~= nil then
        local si = l.selectedIndex
        if type(si) == "number" and si >= 1 and si <= #self.rows then return si end
        if l.getSelectedElementIndex ~= nil then
            local ok, v = pcall(l.getSelectedElementIndex, l)
            if ok and type(v) == "number" and v >= 1 and v <= #self.rows then return v end
        end
    end
    return self.rowIndex or 1
end

function AnimalTradeDialog:onRowChanged(list, section, index)
    if self._refreshing then return end
    -- ONLY `index` is handed on: `section` is a number too, and a resolver taking the
    -- first plausible number would take the section every time.
    self.rowIndex = self:selectedRowIndex(index)
    self.result = nil
    -- a different group has a different maximum, so the quantities move with it -- and
    -- an amount that was valid for the old row may not be for this one
    self:clampAmount()
    self:initAmountOption()
    self:refresh()
end
---IT RETURNS NOTHING, AND THAT IS THE WHOLE POINT.
--
-- Reported 2026-08-31: the sell list showed its rows and none of them could be
-- SELECTED. `SmoothListElement:mouseEvent` calls its SUPERCLASS first -- which
-- propagates the click to the row's children -- and then gates its own row-selection
-- handling on `if not eventUsed` (DR 5.64, read from the shipped source). This
-- returned `true`, so the click was consumed and the list never got to select the
-- row underneath it.
--
-- DistributionInputsDialog's equivalent is `function ...onClickInputRow(element) end`
-- -- an empty body returning nil -- and that is not an oversight either.
---RAISED BY THE SMOOTHLIST ITSELF, from notifyClick, AFTER the selection is applied
-- -- which is why it may read the element and why it is the authority here.
--
-- It was on the LIST ITEM until now, and that is a different moment entirely: child
-- propagation runs BEFORE the list selects (DR 6.29), so it read the PREVIOUS row and
-- wrote it over whatever the selection callback had got right. That is the whole of
-- the "one step behind" -- the row highlighted correctly while every figure beside it
-- described the row before.
--
-- It also covers the case the selection callback cannot: a click on an ALREADY
-- selected row changes no selection and raises no selection event at all.
function AnimalTradeDialog:onRowClicked(...)
    if self._refreshing then return end
    self.rowIndex = self:selectedRowIndex()
    self:clampAmount(); self:initAmountOption(); self:refresh()
end

-- ---------------------------------------------------------------------------
-- CONTROLS
-- ---------------------------------------------------------------------------
---THE MODE LABELS, in one place because both the strip and the click handler
-- need them. SELL is index 1 and BUY index 2, matching AnimalTrade's own
-- constants -- the tab ORDER is the enum, not a display choice.
function AnimalTradeDialog.modeLabels()
    return { l10n("ar_td_mode_sell", "SELL ANIMALS"), l10n("ar_td_mode_buy", "BUY ANIMALS") }
end

---A TAB CLICK, bounds-checked against the labels actually drawn.
function AnimalTradeDialog:selectMode(i)
    local m = AnimalTabs ~= nil and AnimalTabs.pick(AnimalTradeDialog.modeLabels(), i) or nil
    if m == nil or m == self.mode then return end
    self.mode = m
    -- the row that was defaulted for a SALE means nothing in the dealer's catalogue
    self.preferCluster, self.rowIndex, self.result = nil, 1, nil
    self:rebuild()
end

function AnimalTradeDialog:onTab1() return self:selectMode(1) end
function AnimalTradeDialog:onTab2() return self:selectMode(2) end

function AnimalTradeDialog:onBarnChanged(state)
    local o = self.barnOption
    if type(state) ~= "number" and o ~= nil and o.getState ~= nil then state = o:getState() end
    if type(state) ~= "number" or state < 1 or state > #self.barns then return end
    self.barnIndex, self.rowIndex, self.result = state, 1, nil
    self.preferCluster = nil
    self:rebuild()
end

function AnimalTradeDialog:onAmountChanged(state)
    local o = self.amountOption
    if type(state) ~= "number" and o ~= nil and o.getState ~= nil then state = o:getState() end
    local q = (self.quantities or {})[state or 0]
    if q == nil then return end
    self.amount, self.result = q, nil
    self:clampAmount(); self:refresh(); return true
end

---+/- ONE, for the amounts the selector does not name. Both routes write the same
-- field and both re-sync the selector, so the control and the money can never
-- disagree about the number being quoted.
---+/- ONE, WRAPPING between 1 and the maximum (author's call): stepping past the top
-- comes back to 1 and stepping below 1 goes to the top, so neither end is a dead stop.
function AnimalTradeDialog:nudge(d)
    local m = self:maxAmount()
    if m <= 0 then self.amount = 0; self:refresh(); return true end
    local v = (self.amount or 1) + d
    if v > m then v = 1 elseif v < 1 then v = m end
    self.amount, self.result = v, nil
    self:initAmountOption()
    self:refresh()
    return true
end
function AnimalTradeDialog:onAmountUp()   return self:nudge(1)  end
function AnimalTradeDialog:onAmountDown() return self:nudge(-1) end
function AnimalTradeDialog:onAmountAll()
    self.amount, self.result = self:maxAmount(), nil
    self:clampAmount(); self:initAmountOption(); self:refresh(); return true
end

---COMMIT. The one irreversible thing this dialog does.
--
-- IT RE-QUOTES NOTHING AND ASSUMES NOTHING: AnimalTrade opens a fresh controller,
-- issues the game's own call and reports what the game said. A call that returns
-- cleanly but never confirms is treated as a FAILURE (13.4) -- that is the one
-- outcome which would otherwise be shown as money that never arrived.
function AnimalTradeDialog:onCommit()
    local r = self:row()
    local _, p = self:barn()
    if r == nil or p == nil or (self.amount or 0) < 1 then return true end
    local n = self.amount

    local ok, msg = AnimalTrade.commit(p, self.mode, r, n)
    if ok then
        self.result = string.format(
            self.mode == AnimalTrade.MODE_BUY and l10n("ar_td_bought", "Bought %d.")
                                               or l10n("ar_td_sold", "Sold %d."), n)
    else
        self.result = string.format(l10n("ar_td_failed", "Refused: %s"), tostring(msg or "?"))
    end
    -- the herd has changed, so every row and every price is stale: rebuild rather
    -- than patch, which is also what makes a partial refusal show honestly
    self.preferCluster = nil
    self:rebuild()
    return true
end

function AnimalTradeDialog:onClickBack()
    self:close()
    return true
end

-- ---------------------------------------------------------------------------
function AnimalTradeDialog.register()
    if AnimalTradeDialog._instance ~= nil then return true end
    if g_gui == nil or HusbandryRedux == nil then return false end
    local d = AnimalTradeDialog.new()
    g_gui:loadGui(HusbandryRedux.MOD_DIR .. "gui/AnimalTradeDialog.xml", "AnimalTradeDialog", d)
    AnimalTradeDialog._instance = d
    return true
end

-- FULL TEXT ON HOVER for any cell the layout cut short (TextTip.lua, 2026-09-29).
if TextTip ~= nil and TextTip.install ~= nil then TextTip.install(AnimalTradeDialog) end
