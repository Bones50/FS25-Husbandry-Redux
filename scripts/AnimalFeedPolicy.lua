-- ============================================================================
-- AnimalFeedPolicy -- advanced feeding, switched per barn (author, 2026-09-14)
--
-- THREE LEVELS, and the per-barn switch is only the last of them:
--
--   DR "feed husbandries" OFF   DR feeds no animals at all. Nothing here does anything,
--                               whatever AR's setting or this switch says.
--   AR "Advanced animal feeder" DR feeds every barn by its own quality-first rules; this
--      OFF                      switch is hidden, because there is nothing to choose.
--   both ON                     every barn gets AR's advanced feeding unless the player
--                               switches that barn OFF here, which hands just that barn
--                               back to DR's own rules.
--
-- OFF IS THE EXCEPTION, so only OFF is stored: a barn that has never been touched is ON,
-- and a new barn joins the advanced feeding like every other.
--
-- THE SWITCH NEVER TOUCHES DR. The planner simply declines for a barn switched off, and
-- DR's own contract is that a declined plan is identical to no planner at all -- the
-- same documented mechanism the global setting already uses.
--
-- MULTIPLAYER: stored where AR stores its other policies, which is not replicated. The
-- feed plan runs on the server, so on a multiplayer game only the host's choices count.
-- ============================================================================

AnimalFeedPolicy = AnimalFeedPolicy or {}

AnimalFeedPolicy.HIDDEN    = "HIDDEN"      -- no DR, or AR's advanced feeder is off
AnimalFeedPolicy.DR_OFF    = "DR_OFF"      -- DR installed but not feeding animals at all
AnimalFeedPolicy.AVAILABLE = "AVAILABLE"

-- uid -> false for a barn switched off (absent = on)
AnimalFeedPolicy.off = {}

local function warn(fmt, ...)
    if HusbandryRedux ~= nil and HusbandryRedux.warn ~= nil then return HusbandryRedux.warn(fmt, ...) end
end

---Does this barn take AR's advanced feeding?
function AnimalFeedPolicy.enabled(uid)
    if uid == nil then return true end
    return AnimalFeedPolicy.off[uid] ~= false
end

function AnimalFeedPolicy.setEnabled(uid, on)
    if type(uid) ~= "string" or uid == "" then return false end
    if on then AnimalFeedPolicy.off[uid] = nil else AnimalFeedPolicy.off[uid] = false end
    return true
end

function AnimalFeedPolicy.toggle(uid)
    local now = not AnimalFeedPolicy.enabled(uid)
    AnimalFeedPolicy.setEnabled(uid, now)
    return now
end

---Is DR feeding animals at all? nil when DR cannot be asked.
function AnimalFeedPolicy.drFeedsAnimals()
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    if SD == nil then
        local dr = _G["FS25_Distribution_Redux"]
        SD = dr ~= nil and dr.SmartDistribution or nil
    end
    local st = SD ~= nil and SD.settings or nil
    local g = st ~= nil and st.global or nil
    if g == nil or g.feedHusbandryEnabled == nil then return nil end
    return g.feedHusbandryEnabled == true
end

---What the page may show for the switch.
function AnimalFeedPolicy.toggleState()
    if AnimalSettings == nil or AnimalSettings.advancedFeederEnabled == nil
       or not AnimalSettings.advancedFeederEnabled() then
        return AnimalFeedPolicy.HIDDEN
    end
    if AnimalFeedPolicy.drFeedsAnimals() == false then return AnimalFeedPolicy.DR_OFF end
    return AnimalFeedPolicy.AVAILABLE
end

-- ---------------------------------------------------------------------------
-- PERSISTENCE, beside herdPolicy.
local function saveSection(xml, key)
    local i = 0
    for uid, v in pairs(AnimalFeedPolicy.off) do
        if v == false then
            local k = string.format("%s.barn(%d)", key, i)
            setXMLString(xml, k .. "#uid", uid)
            setXMLBool(xml, k .. "#advancedFeeding", false)
            i = i + 1
        end
    end
end

local function loadSection(xml, key)
    -- UNCONDITIONALLY CLEARED: the chunk re-runs per mission load, and one save's
    -- switches must never leak into another (DR 6.19).
    AnimalFeedPolicy.off = {}
    if xml == nil then return end
    local i = 0
    while true do
        local k = string.format("%s.barn(%d)", key, i)
        if not hasXMLProperty(xml, k) then break end
        local uid = getXMLString(xml, k .. "#uid")
        if type(uid) == "string" and uid ~= "" then
            if getXMLBool(xml, k .. "#advancedFeeding") == false then AnimalFeedPolicy.off[uid] = false end
        else
            warn("feed policy %d dropped on load: no barn", i)
        end
        i = i + 1
    end
end

AnimalFeedPolicy._saveSection, AnimalFeedPolicy._loadSection = saveSection, loadSection

if AnimalPersist ~= nil and AnimalPersist.register ~= nil then
    AnimalPersist.register("feedPolicy", saveSection, loadSection)
end
