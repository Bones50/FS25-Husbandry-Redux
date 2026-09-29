-- ============================================================================
-- AnimalHelp.lua  (Husbandry Redux)
--
-- Husbandry Redux's user guide, shown as a TAB on Distribution Redux's User Guide
-- page through DR's registerHelpTab (API v9).
--
-- EXACTLY THE SHAPE AnimalSettings TAKES, deliberately: AR supplies content and
-- DR owns the page. The tab is registered from HERE, so a player who removes
-- Husbandry Redux sees DR's guide exactly as it was, with one tab -- no check
-- anywhere, the tab simply is never registered.
--
-- THE TEXT IS A PLACEHOLDER AND SAYS SO. The author is writing the real guide;
-- what matters now is that the tab exists, is reachable, and renders. A tab that
-- came up BLANK would be indistinguishable from a broken one, which is the whole
-- reason this is one honest topic rather than an empty table.
--
-- WRITING THE REAL GUIDE
--   * Add entries to GUIDE below: { slug, title, paras = { "...", "..." } }.
--     One string per PARAGRAPH; a line beginning "## " is a sub-heading.
--   * DO NOT HAND-WRAP. The page word-wraps to its own column count, so a
--     pre-wrapped paragraph renders ragged. Write each paragraph as one long line.
--   * DR re-reads `topics` on every page open (the registration hands it a
--     FUNCTION, not a table), so editing this file and reopening the tab needs no
--     restart of anything but the game itself.
--
-- THE PARAGRAPH KEYS ARE NOT IN translation_en.xml YET, and that is deliberate
-- rather than an omission: the text below is a placeholder about to be rewritten,
-- and generating ~8 translation entries for prose with a short life is churn a
-- translator would then have to redo. l10n() returns the English fallback for a
-- key nobody has written, which is exactly the designed degradation -- so the tab
-- is fully readable today and simply not translatable yet.
--
-- WHEN THE REAL GUIDE IS WRITTEN, do BOTH of these together or the bijection
-- check will fail: add ar_help_<slug>_title and ar_help_<slug>_<n> to
-- translations/translation_en.xml, AND teach tools/check_l10n_animal.py to
-- SYNTHESISE those keys from this GUIDE table. The checker matches quoted string
-- literals, and these keys are built with string.format -- so a key defined in the
-- XML and only ever referenced through a format string reads to it as an ORPHAN.
-- DR's own checker already does this for DR's guide (its 6.14); copy that.
-- ============================================================================

AnimalHelp = {}

AnimalHelp.MOD_NAME = "FS25_Husbandry_Redux"

local function l10n(key, fallback)
    if HusbandryRedux ~= nil and HusbandryRedux.l10n ~= nil then return HusbandryRedux.l10n(key, fallback) end
    return fallback
end

local function warn(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then return HusbandryRedux.warn(fmt, ...) end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[HusbandryRedux] " .. (ok and msg or tostring(fmt)))
end

-- ---------------------------------------------------------------------------
-- THE GUIDE.
--
-- ONE KEY PER PARAGRAPH, which is DR's convention (its 6.14) and is not a style
-- choice: an XML attribute VALUE is newline-normalised, so a whole multi-line body
-- in text="..." loses every line break and comes out as one run-on paragraph. The
-- alternative is &#10; escapes, which no translator should have to write.
--
-- KEYS ARE ar_help_<slug>_title and ar_help_<slug>_<n>, n counting NON-BLANK
-- paragraphs from 1. The slug comes from the topic, not its position, so
-- reordering topics costs nothing; the one hazard is INSERTING a paragraph in the
-- middle, which shifts every later key in that topic.
--
-- THE ENGLISH HERE IS THE SOURCE OF TRUTH AND THE FALLBACK, exactly as DR's TOPICS
-- table is. A missing key, a partial translation or no language file at all all
-- degrade to this text rather than to a blank tab or a raw key on screen.
local GUIDE = {
    {
        slug  = "intro",
        title = "Husbandry Redux",
        paras = {
            "Husbandry Redux extends Distribution Redux with animal husbandry: what a barn is actually fed, what its herd is worth, and what it earns.",
            "## This guide is still being written",
            "The pages are in place and the mod works; the written guide is not finished yet. Until it is, the screens themselves carry the explanation - every column header has a tooltip, and the Husbandry Redux tab in Settings describes what each option does.",
            "## Where things are",
            "The Animals tab in this menu holds three views: ANIMALS lists every group on the farm, BARN examines one building, and BREEDS shows what each breed is kept for and what the engine makes of that.",
            "The barn strip on Distribution Redux's Animal Husbandry tab shows the same herd at a glance - health, productivity, feed by group, herd value and an estimated monthly profit.",
            "## Settings",
            "Husbandry Redux's options live on their own tab of the Settings page. Each one turns a whole feature off rather than tuning it, so anything you switch off simply stops appearing.",
        },
    },
}

---Assemble one topic's body from its per-paragraph keys.
--
-- BLANK LINE BETWEEN PARAGRAPHS, because that is what the renderer splits on.
-- string.char(10) rather than an escape so this survives being generated or
-- pasted through tooling that mangles backslashes.
local function bodyOf(t)
    local NL = string.char(10)
    local out = {}
    for i, fallback in ipairs(t.paras) do
        out[i] = l10n(string.format("ar_help_%s_%d", t.slug, i), fallback)
    end
    return table.concat(out, NL .. NL)
end

---The guide DR draws. A FUNCTION, not a table, so l10n is resolved when the PAGE
-- OPENS rather than when this chunk loads: l10n is not necessarily up at load, and
-- a title captured too early would be the English fallback for the whole session.
-- Same reason AnimalSettings.rows is a function.
function AnimalHelp.topics()
    local topics = {}
    for _, t in ipairs(GUIDE) do
        topics[#topics + 1] = {
            -- string.format, NOT concatenation. tools/check_l10n_animal.py matches
            -- quoted literals, and a bare "ar_help_" fragment reads to it as a key
            -- in its own right -- it reported exactly that. Building the key in one
            -- format call leaves no fragment to misread, and matches how the
            -- paragraph keys above are built.
            title = l10n(string.format("ar_help_%s_title", t.slug), t.title),
            body  = bodyOf(t),
        }
    end
    return topics
end

-- ---------------------------------------------------------------------------
---Register the tab on DR's User Guide page.
--
-- GATED ON THE CALL EXISTING rather than on a version number, so a DR that gains
-- this in a later build works without a bump here -- the rule the husbandry panel
-- and the settings tab both follow. A DR too old simply has no AR guide tab, and
-- nothing else about the mod changes.
function AnimalHelp.install(SD)
    if SD == nil or SD.API == nil or SD.API.registerHelpTab == nil then
        if SD == nil then
            -- STANDALONE. Not a fault and not the same thing as an old DR: AR has its own
            -- menu, and this tab simply has no DR page to attach to.
            warn("no Distribution Redux; the guide stays on AR's own menu")
        else
            warn("Distribution Redux has no User Guide tab API (needs v9+); AR shows it on its own menu instead")
        end
        return false
    end
    -- THE FUNCTION, not AnimalHelp.topics() -- DR calls it per page open.
    local ok, res = pcall(SD.API.registerHelpTab, AnimalHelp.MOD_NAME,
                          l10n("ar_help_tab", "HUSBANDRY REDUX"), AnimalHelp.topics)
    if ok and res then
        warn("user guide tab added to the Distribution Redux guide page")
        return true
    end
    warn("user guide tab NOT added: %s", tostring(res))
    return false
end
