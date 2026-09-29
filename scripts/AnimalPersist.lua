-- ============================================================================
-- AnimalPersist.lua -- ONE savegame file for Husbandry Redux, and the four traps
-- that make per-savegame persistence in FS25 harder than it looks.
--
-- AR had NO persistence of any kind before this (grepped: not one saveToXMLFile
-- or loadFromXMLFile anywhere), and its own roadmap lists this as step 1 for
-- auto-sell as well as auto-buy. So this owns the FILE and lets each feature
-- register a SECTION, rather than being the buy schedule's private store.
--
--   AnimalPersist.register(name, saveFn, loadFn)
--     saveFn(xml, key)   write your subtree under `key`
--     loadFn(xml, key)   read it back -- SEE THE UNCONDITIONAL-LOAD RULE BELOW
--
-- ---------------------------------------------------------------------------
-- TRAP 1 -- FS25 SAVES BY FOLDER SWAP.
-- The game does not write into savegame<N>/. It builds a fresh tempsavegame/,
-- writes the whole savegame into it, and swaps that folder over savegame<N>/.
-- Anything sitting in savegame<N>/ that was not ALSO written into tempsavegame/
-- is destroyed by the swap. So this file must be written from the save hook,
-- with the missionInfo that hook is handed, because during a save the engine
-- points missionInfo.savegameDirectory at tempsavegame/. (DR 5.59.)
--
-- TRAP 2 -- A GUESSED PATH IS NOT PROOF A FILE IS ABSENT.
-- On a DEDICATED SERVER missionInfo.savegameDirectory is nil at
-- loadMission00Finished but populated by the time a save runs. The resolver
-- therefore returns a second value saying whether the answer is AUTHORITATIVE
-- (the engine's own field) or a GUESS rebuilt from savegameIndex. Concluding
-- "no file, so this is a new save" from a guess is how a live farm's state gets
-- overwritten with defaults.
--
-- TRAP 3 -- A NEW GAME HAS NO SAVEGAME FOLDER UNTIL THE FIRST SAVE CREATES IT.
-- So the load defers, and if the SAVE then also skipped because the load never
-- completed, the folder swap leaves the new savegame with no file at all and
-- everything reverts. Deferral applies only to non-authoritative callers; the
-- game's own save always resolves the situation first through adoptPending().
--
-- TRAP 4 -- THE MOD CHUNK RE-RUNS ON EVERY MISSION LOAD, and file-scope state
-- survives it. A loader that returns early when its section is absent leaves
-- the PREVIOUS savegame's data in memory and shows one save's schedules on
-- another save's barns. Hence: EVERY registered loadFn IS CALLED ON EVERY LOAD,
-- including when the file or the section is missing (xml is then nil). Loading
-- a world replaces the world.
-- ============================================================================

AnimalPersist = {}

AnimalPersist.FILE    = "husbandryRedux.xml"

---THE NAME THIS FILE HAD BEFORE THE MOD WAS RENAMED (2026-09-20).
--
-- The savegame file is keyed by NAME, not by the mod folder, so renaming it would have
-- orphaned the animal data in every existing save -- schedules, sell rules, herd policy,
-- the lot -- with no error and nothing in the log, because an absent file is a legitimate
-- state that means "a fresh world" (trap 4 below).
--
-- So the old name is still READ when the new one is absent, and the next SAVE writes the
-- new one. One-way and self-completing: after a single save-and-reload the old file is
-- simply ignored, and it is never written to again.
AnimalPersist.FILE_LEGACY = "husbandryRedux.xml"

---The file to READ from `dir`, preferring the current name and falling back to the old
-- one. Returns the path and whether it was the legacy file, or nil if neither is there.
function AnimalPersist.resolveReadPath(dir)
    if dir == nil or fileExists == nil then return nil, false end
    local cur = dir .. AnimalPersist.FILE
    if fileExists(cur) then return cur, false end
    local old = dir .. AnimalPersist.FILE_LEGACY
    if fileExists(old) then return old, true end
    return nil, false
end
AnimalPersist.ROOT    = "husbandryRedux"
-- Bumped only when a written shape changes incompatibly. It is READ on load, so
-- a future migration has something to branch on -- DR shipped a version that was
-- written from the first build and never once read, which is worth nothing.
AnimalPersist.VERSION = 1

AnimalPersist._sections = {}     -- name -> { save = fn, load = fn }
AnimalPersist._order    = {}     -- registration order, so the file is stable
AnimalPersist._loaded   = false
AnimalPersist._version  = AnimalPersist.VERSION

-- PROGRESS IS DEBUG, FAILURE IS ALWAYS. `say` reports that the layer is working
-- (loaded, saved, started empty), which is diagnostic chatter a player should not
-- be reading; `hard` reports that it is NOT working, which they must see whatever
-- the debug setting says, because it is how a lost savegame gets noticed.
--
-- The debug flag is read from the savegame by AnimalSettings, which happens
-- INSIDE this very load -- so the lines emitted before that point follow the flag
-- from the PREVIOUS session's default. Turning debug on therefore shows the load
-- chatter from the next load onward, which is what a persisted flag can honestly
-- promise.
local function say(fmt, ...)
    if HusbandryRedux == nil or HusbandryRedux.debug ~= true then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print("[HusbandryRedux persist] " .. (ok and msg or tostring(fmt)))
end

local function hard(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    print("[HusbandryRedux persist] " .. (ok and msg or tostring(fmt)))
end

---Register a section. Re-registering a name REPLACES it rather than appending,
-- because the mod chunk re-runs per mission load and a growing list would write
-- the same subtree several times.
function AnimalPersist.register(name, saveFn, loadFn)
    if type(name) ~= "string" or name == "" then return false end
    if type(saveFn) ~= "function" or type(loadFn) ~= "function" then return false end
    if AnimalPersist._sections[name] == nil then
        AnimalPersist._order[#AnimalPersist._order + 1] = name
    end
    AnimalPersist._sections[name] = { save = saveFn, load = loadFn }
    return true
end

-- ---------------------------------------------------------------------------
---The savegame folder, and whether the answer is authoritative.
--
-- DR EXPOSES ITS OWN RESOLVER AS A PUBLIC FIELD FOR EXACTLY THIS, and its
-- comment says why: a second private copy is how a writer and a reader come to
-- disagree about where a file lives, which is the dedicated-server bug it was
-- written to fix. AR requires DR, so DR's is preferred and the local copy is a
-- fallback for a DR too old to expose it -- not a second opinion.
function AnimalPersist.saveDir(missionInfo)
    local SD = HusbandryRedux ~= nil and HusbandryRedux.DR or nil
    if SD ~= nil and type(SD.getSaveDir) == "function" then
        local ok, dir, authoritative = pcall(SD.getSaveDir, missionInfo)
        if ok then return dir, authoritative == true end
    end
    local mi = missionInfo or (g_currentMission ~= nil and g_currentMission.missionInfo) or nil
    if mi == nil then return nil, false end
    if mi.savegameDirectory ~= nil and mi.savegameDirectory ~= "" then
        return mi.savegameDirectory .. "/", true
    end
    if mi.savegameIndex ~= nil and getUserProfileAppPath ~= nil then
        return getUserProfileAppPath() .. "savegame" .. tostring(mi.savegameIndex) .. "/", false
    end
    return nil, false
end

-- ALWAYS A FRESH DOCUMENT, deliberately -- and this is the one place AR does not
-- copy DR. DR reuses the existing file so unknown keys (an older build's, or a
-- hand edit) survive a rewrite. That is right for a settings file of flat
-- attributes and WRONG for a file holding LISTS: a schedule removed by the player
-- would leave its <schedule> element behind, and the next load would read it back.
-- Removing a subtree would be the alternative, but `removeXMLProperty` appears
-- nowhere in the readable base-game source, so it is not a call to lean on
-- (8.1 -- an absence proves nothing, and that cuts both ways). Every section is
-- written in the same pass, so nothing of ours is lost by starting clean.
local function openForWrite(path)
    return createXMLFile("HusbandryRedux", path, AnimalPersist.ROOT)
end

---Hand every registered section its subtree. `xml` may be nil, and that is not
-- an error path: it is trap 4's clearing pass.
function AnimalPersist._readAll(xml)
    AnimalPersist._version = AnimalPersist.VERSION
    if xml ~= nil then
        local v = getXMLInt(xml, AnimalPersist.ROOT .. "#version")
        if v ~= nil then AnimalPersist._version = v end
    end
    for _, name in ipairs(AnimalPersist._order) do
        local s = AnimalPersist._sections[name]
        if s ~= nil then
            local ok, err = pcall(s.load, xml, AnimalPersist.ROOT .. "." .. name)
            if not ok then hard("section '%s' failed to load: %s", name, tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------------------
---The save hook's escape from trap 3. Called only when the game's own save
-- fires while the load is still pending.
--
--   no file anywhere          -> NEW save. The in-memory state is the player's
--                                (a change applies to memory even when the write
--                                was skipped), so write it.
--   a real file we never read -> ADOPT it: read, hand it to every section, and
--                                let the normal write put it back unchanged. That
--                                also repairs the SESSION, which until now had
--                                been running on nothing.
--   unreadable                -> skip. Never overwrite a file that failed to read.
--
-- The discriminator is the LIVE savegame folder rebuilt from savegameIndex. It
-- cannot come from saveDir(): during a save that points at tempsavegame/, which
-- is where we are writing TO, never where the existing file lives.
function AnimalPersist.adoptPending()
    local mi  = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    local idx = mi ~= nil and mi.savegameIndex or nil
    if idx == nil or getUserProfileAppPath == nil then
        hard("SAVE skipped: load still pending and the live savegame folder is unresolved")
        return false
    end
    local liveDir  = getUserProfileAppPath() .. "savegame" .. tostring(idx) .. "/"
    local livePath = AnimalPersist.resolveReadPath(liveDir)
    if livePath ~= nil then
        local xml = loadXMLFile("HusbandryRedux", livePath)
        if xml == nil or xml == 0 then
            hard("SAVE skipped: load pending and %s could not be read", tostring(livePath))
            return false
        end
        AnimalPersist._readAll(xml)
        delete(xml)
        AnimalPersist._loaded = true
        say("SAVE: adopted the pending file before writing -> %s", tostring(livePath))
        return true
    end
    AnimalPersist._loaded = true
    say("SAVE: no file for this savegame (NEW save) -- writing the current state")
    return true
end

-- ---------------------------------------------------------------------------
function AnimalPersist.save(missionInfo)
    -- A CLIENT PERSISTS NOTHING. The server owns this state and a client writing
    -- its own copy is how two machines come to disagree.
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil then
        local okS, isServer = pcall(g_currentMission.getIsServer, g_currentMission)
        if okS and isServer == false then return end
    end
    if #AnimalPersist._order == 0 then return end     -- nothing registered; nothing to write

    local dir, authoritative = AnimalPersist.saveDir(missionInfo)
    if dir == nil then
        hard("SAVE skipped: savegame directory unresolved")
        return
    end
    if not AnimalPersist._loaded then
        -- Deferral protects a LIVE farm from an ad-hoc write during the window
        -- where the file has not been read yet. It must never apply to the game's
        -- own save: skipping that does not preserve the old file, the folder swap
        -- DESTROYS it.
        if not authoritative then
            hard("SAVE skipped: state not loaded yet (deferred load pending)")
            return
        end
        if not AnimalPersist.adoptPending() then return end
    end
    -- A brand-new career may not have its folder yet. Creating one that exists is
    -- a no-op. Gated on an authoritative path so a guess can never conjure a
    -- savegameN folder that is not the one in use.
    if authoritative then createFolder(dir) end

    local path = dir .. AnimalPersist.FILE
    local xml = openForWrite(path)
    if xml == nil or xml == 0 then
        hard("SAVE FAILED: could not open %s", tostring(path))
        return
    end
    setXMLInt(xml, AnimalPersist.ROOT .. "#version", AnimalPersist.VERSION)
    for _, name in ipairs(AnimalPersist._order) do
        local s = AnimalPersist._sections[name]
        if s ~= nil then
            local ok, err = pcall(s.save, xml, AnimalPersist.ROOT .. "." .. name)
            if not ok then hard("section '%s' failed to save: %s", name, tostring(err)) end
        end
    end
    saveXMLFile(xml)
    delete(xml)
    say("SAVED -> %s", tostring(path))
end

function AnimalPersist.load()
    if AnimalPersist._loaded then return end

    -- A CLIENT owns none of this; the server is authoritative. Mark the load done
    -- so nothing defers forever, and clear every section so a client that just
    -- left another world is not still showing its schedules.
    if g_currentMission ~= nil and g_currentMission.getIsServer ~= nil then
        local okS, isServer = pcall(g_currentMission.getIsServer, g_currentMission)
        if okS and isServer == false then
            AnimalPersist._readAll(nil)
            AnimalPersist._loaded = true
            return
        end
    end

    local dir, authoritative = AnimalPersist.saveDir()
    if dir == nil then
        -- Dedicated server: the path resolves later. Leave _loaded false so the
        -- hourly retry picks it up, and so nothing may be SAVED meanwhile.
        say("LOAD deferred: savegame directory unresolved -- will retry")
        return
    end
    local path, legacy = AnimalPersist.resolveReadPath(dir)
    if legacy then
        say("LOAD: reading the pre-rename %s; the next save writes %s",
            AnimalPersist.FILE_LEGACY, AnimalPersist.FILE)
    end
    if path == nil then
        path = dir .. AnimalPersist.FILE        -- for the message below
        if not authoritative then
            say("LOAD deferred: %s absent but the path was GUESSED -- will retry", tostring(path))
            return
        end
        AnimalPersist._readAll(nil)          -- trap 4: a fresh world starts empty, explicitly
        AnimalPersist._loaded = true
        say("LOAD: no file for this savegame -- starting empty")
        return
    end
    local xml = loadXMLFile("HusbandryRedux", path)
    if xml == nil or xml == 0 then
        hard("LOAD FAILED: could not open %s", tostring(path))
        return
    end
    AnimalPersist._readAll(xml)
    delete(xml)
    AnimalPersist._loaded = true
    say("LOAD fired: %s (v%s)", tostring(path), tostring(AnimalPersist._version))
end

---The deferred-load retry. Driven from the hourly tick rather than a timer of
-- its own, so there is one clock in the mod.
function AnimalPersist.retryIfPending()
    if not AnimalPersist._loaded then AnimalPersist.load() end
end

-- ---------------------------------------------------------------------------
-- HOOKS. The save one is what makes any of this persist at all (trap 1).
if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function(self, ...)
            pcall(AnimalPersist.save, self)
        end)
else
    print("[HusbandryRedux persist] SAVE HOOK NOT ATTACHED -- FSCareerMissionInfo.saveToXMLFile missing")
end

if Mission00 ~= nil and Mission00.loadMission00Finished ~= nil then
    Mission00.loadMission00Finished = Utils.appendedFunction(
        Mission00.loadMission00Finished,
        function() pcall(AnimalPersist.load) end)
end
