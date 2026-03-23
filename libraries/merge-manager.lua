-- ============================================================================
-- merge-manager.lua - Merge Cinematic Manager
-- ============================================================================
-- PURPOSE: Track merge cinematic triggers and send merged results
--
-- RESPONSIBILITIES:
--   - Buffer merge triggers by group
--   - Detect when enough unique objects have triggered within the time window
--   - Look up merged result from central library (EreaRpMasterDB.mergeLibrary)
--   - Send merged CINEMATIC with comma-separated sender list
--   - Clean up stale buffer entries
--
-- DEPENDENCIES:
--   - EreaRpLibraries:Messaging()
--   - EreaRpLibraries:Logging()
--   - EreaRpMasterDB.mergeLibrary (initialized in rp-master.lua)
-- ============================================================================

-- ============================================================================
-- IMPORTS
-- ============================================================================
local Log = EreaRpLibraries:Logging("EreaRpMaster")
local messaging = EreaRpLibraries:Messaging()

-- ============================================================================
-- SERVICE TABLE
-- ============================================================================
EreaRpMergeManager = {}

-- ============================================================================
-- STATE (ephemeral, not persisted)
-- ============================================================================
local mergeBuffer = {}
-- mergeBuffer["fire_ice"] = {
--     triggers = {
--         { senderName = "PlayerA", timestamp = 12345.6 },
--         { senderName = "PlayerB", timestamp = 12347.8 }
--     }
-- }

local MERGE_WINDOW_SECONDS = 5

-- ============================================================================
-- PRIVATE FUNCTIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Remove buffer entries older than the merge window
-- ----------------------------------------------------------------------------
local function CleanupStaleEntries(mergeGroup)
    local group = mergeBuffer[mergeGroup]
    if not group then return end

    local now = GetTime()
    local beforeCount = table.getn(group.triggers) -- Lua 5.0: table.getn
    local fresh = {}
    for i = 1, beforeCount do
        local age = now - group.triggers[i].timestamp
        if age <= MERGE_WINDOW_SECONDS then
            table.insert(fresh, group.triggers[i])
        else
            Log("CleanupStaleEntries: removing stale trigger for " .. mergeGroup .. " sender=" .. group.triggers[i].senderName .. " age=" .. string.format("%.1f", age) .. "s")
        end
    end

    local afterCount = table.getn(fresh) -- Lua 5.0: table.getn
    if beforeCount ~= afterCount then
        Log("CleanupStaleEntries: " .. mergeGroup .. " " .. beforeCount .. " -> " .. afterCount .. " triggers")
    end

    if afterCount == 0 then
        mergeBuffer[mergeGroup] = nil
    else
        group.triggers = fresh
    end
end

-- ----------------------------------------------------------------------------
-- Build comma-separated sender list from buffer triggers (for message field)
-- ----------------------------------------------------------------------------
local function BuildSenderList(triggers)
    local names = {}
    for i = 1, table.getn(triggers) do -- Lua 5.0: table.getn
        table.insert(names, triggers[i].senderName)
    end
    return table.concat(names, ",")
end

-- ----------------------------------------------------------------------------
-- Build natural language player list for placeholder resolution
-- e.g. "PlayerA and PlayerB" or "PlayerA, PlayerB and PlayerC"
-- ----------------------------------------------------------------------------
local function BuildPlayerNameList(triggers)
    local count = table.getn(triggers) -- Lua 5.0: table.getn
    if count == 0 then return "" end
    if count == 1 then return triggers[1].senderName end

    local result = ""
    for i = 1, count do
        if i == count then
            result = result .. " and " .. triggers[i].senderName
        elseif i == 1 then
            result = triggers[i].senderName
        else
            result = result .. ", " .. triggers[i].senderName
        end
    end
    return result
end

-- ----------------------------------------------------------------------------
-- Execute a merge: look up library, send merged CINEMATIC, clear buffer
-- ----------------------------------------------------------------------------
local function ExecuteMerge(mergeGroup)
    if not EreaRpMasterDB or not EreaRpMasterDB.mergeLibrary then
        Log("ExecuteMerge: mergeLibrary not initialized")
        return
    end

    local libraryEntry = EreaRpMasterDB.mergeLibrary[mergeGroup]
    if not libraryEntry then
        Log("ExecuteMerge: no library entry for mergeGroup=" .. tostring(mergeGroup))
        return
    end

    local group = mergeBuffer[mergeGroup]
    if not group then return end

    -- Build combined sender list
    local combinedSenders = BuildSenderList(group.triggers)

    -- Resolve scripts specified in scriptReferences (comma-separated, Lua 5.0 compatible)
    local scriptValues = {}
    if libraryEntry.scriptReferences and libraryEntry.scriptReferences ~= "" then
        local refs = libraryEntry.scriptReferences
        local i = 1
        while i <= string.len(refs) do
            local commaPos = string.find(refs, ",", i, true)
            local scriptName
            if commaPos then
                scriptName = string.sub(refs, i, commaPos - 1)
                i = commaPos + 1
            else
                scriptName = string.sub(refs, i)
                i = string.len(refs) + 1
            end
            local script = EreaRpMasterDB.scriptLibrary and EreaRpMasterDB.scriptLibrary[scriptName]
            if script then
                local context = {playerName = group.triggers[1].senderName, customText = ""}
                local ok, result = EreaRpMasterScriptLibrary:ExecuteScriptBody(script.body, context)
                table.insert(scriptValues, ok and result or "[error]")
            else
                table.insert(scriptValues, "[script not found]")
            end
        end
    end

    Log("ExecuteMerge: mergeGroup=" .. mergeGroup .. " senders=" .. combinedSenders)

    -- Send merged CINEMATIC broadcast (mergeGroup serves as cinematicGuid for player-side lookup)
    -- speakerName and message text are resolved on player side from cinematicLibrary
    Log("ExecuteMerge: sending merged CINEMATIC broadcast now")
    messaging.SendCinematicBroadcastMessage(mergeGroup, combinedSenders, "", "", 0, scriptValues)
    Log("ExecuteMerge: merged CINEMATIC broadcast sent")

    -- Clear buffer for this group
    mergeBuffer[mergeGroup] = nil
end

-- ============================================================================
-- PUBLIC FUNCTIONS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- RegisterMergeTrigger - Called when a MERGE_TRIGGER message is received.
-- Buffers the trigger and fires the merge if ready.
--
-- @param mergeGroup: Merge group identifier (string)
-- @param senderName: Player who triggered the action (string, from arg4)
-- @param objectGuid: GUID of the triggering object (string)
-- @param customNumber: Instance-specific number (number)
-- ----------------------------------------------------------------------------
function EreaRpMergeManager:RegisterMergeTrigger(mergeGroup, senderName, objectGuid, customNumber)
    if not mergeGroup or mergeGroup == "" then
        Log("RegisterMergeTrigger: empty mergeGroup")
        return
    end
    if not senderName or senderName == "" then
        Log("RegisterMergeTrigger: empty senderName")
        return
    end

    -- Clean stale entries first
    CleanupStaleEntries(mergeGroup)

    -- Initialize group if needed
    if not mergeBuffer[mergeGroup] then
        mergeBuffer[mergeGroup] = { triggers = {} }
    end

    -- Add trigger
    table.insert(mergeBuffer[mergeGroup].triggers, {
        senderName = senderName,
        objectGuid = objectGuid or "",
        customNumber = customNumber or 0,
        timestamp = GetTime()
    })

    Log("RegisterMergeTrigger: mergeGroup=" .. mergeGroup .. " sender=" .. senderName
        .. " count=" .. table.getn(mergeBuffer[mergeGroup].triggers)) -- Lua 5.0: table.getn

    -- Check if merge is ready (requires `amount` total triggers, default 2)
    local requiredAmount = 2
    if EreaRpMasterDB and EreaRpMasterDB.mergeLibrary then
        local libraryEntry = EreaRpMasterDB.mergeLibrary[mergeGroup]
        if libraryEntry and libraryEntry.amount then
            requiredAmount = libraryEntry.amount
        end
    end
    local currentCount = table.getn(mergeBuffer[mergeGroup].triggers) -- Lua 5.0: table.getn
    Log("RegisterMergeTrigger: checking merge ready - count=" .. currentCount .. " required=" .. requiredAmount)
    if currentCount >= requiredAmount then
        Log("RegisterMergeTrigger: MERGE READY - calling ExecuteMerge for " .. mergeGroup)
        ExecuteMerge(mergeGroup)
    else
        Log("RegisterMergeTrigger: waiting for more triggers (" .. currentCount .. "/" .. requiredAmount .. ")")
    end
end

-- ============================================================================
-- CLEANUP TIMER
-- Periodically clears stale buffer entries to prevent memory leaks
-- ============================================================================
local cleanupFrame = CreateFrame("Frame")
local cleanupElapsed = 0
local CLEANUP_INTERVAL = 10

cleanupFrame:SetScript("OnUpdate", function()
    -- Lua 5.0: SetScript uses `arg1` for elapsed time
    cleanupElapsed = cleanupElapsed + arg1
    if cleanupElapsed < CLEANUP_INTERVAL then return end
    cleanupElapsed = 0

    for mergeGroup, _ in pairs(mergeBuffer) do
        CleanupStaleEntries(mergeGroup)
    end
end)
