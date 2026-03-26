-- ============================================================================
-- event-handler.lua - Main Event Handler & Message Processing
-- ============================================================================
-- PURPOSE: Handles all addon events and incoming messages
--
-- EVENTS HANDLED:
--   - PLAYER_LOGIN: Initialize addon, create slash commands
--   - CHAT_MSG_ADDON: Process incoming RP messages (GIVE, TRADE, SHOW, SYNC, etc.)
--
-- MESSAGE TYPES:
--   - GIVE: GM giving item to player
--   - TRADE: Player trading item to another player
--   - SHOW: Player showing item to another player
--   - DB_SYNC: Database synchronization metadata
--   - DB_CHUNK: Database chunk data
--   - GIVE_ACCEPT/REJECT: Response to GIVE request
--   - TRADE_ACCEPT/REJECT: Response to TRADE request
--   - SHOW_REJECT: Response to SHOW request
--
-- DEPENDENCIES:
--   - EreaRpPlayerDB (SavedVariable)
--   - messaging module (from turtle-rp-common)
--   - objectDatabase module (from turtle-rp-common)
--   - inventory module (from turtle-rp-common)
--   - EreaRpPlayerInventory prototype (from services/inventory.lua)
--   - Log function
--
-- PATTERN: Prototype service + event-driven architecture
--
-- PUBLIC API:
--   - EreaRpPlayerEventHandler:ResetPositions() - Reset frame positions
--   - EreaRpPlayerEventHandler:ShowLog() - Display debug log
--   - EreaRpPlayerEventHandler:CleanupDuplicateSlots() - Remove duplicate items
--   - Global wrappers: EreaRpPlayer_*() in rp-player.lua
-- ============================================================================

-- ============================================================================
-- PROTOTYPE
-- ============================================================================
EreaRpPlayerEventHandler = {}

-- ============================================================================
-- IMPORTS
-- ============================================================================
local messaging = EreaRpLibraries:Messaging()
local objectDatabase = EreaRpLibraries:ObjectDatabase()
local inventory = EreaRpLibraries:Inventory()
local encoding = EreaRpLibraries:Encoding()
local unitUtils = EreaRpLibraries:UnitUtils()
local Log = EreaRpLibraries:Logging("RPPlayer")

-- ============================================================================
-- Constants
-- ============================================================================
local ADDON_PREFIX = messaging.ADDON_PREFIX  -- Use constant from messaging module
-- Version info loaded from version.lua (loaded first in .toc)
-- Show version tag unless it's the default "0.0.0", then show build time
local ADDON_VERSION = (RP_VERSION_TAG and RP_VERSION_TAG ~= "0.0.0") and RP_VERSION_TAG or (RP_BUILD_TIME or "unknown")

-- ============================================================================
-- MAIN EVENT HANDLER (Message Reception)
-- ============================================================================
-- Listens for addon messages and PLAYER_LOGIN event
--
-- EVENTS:
--   - CHAT_MSG_ADDON: Fires when addon message received
--     - arg1: prefix (string) - Addon identifier
--     - arg2: message (string) - Base64-encoded data
--     - arg3: distribution (string) - RAID/PARTY/WHISPER/etc.
--     - arg4: sender (string) - Player name who sent
--
--   - PLAYER_LOGIN: Fires once when character finishes loading
--     - SavedVariables are now available
--     - Safe to access EreaRpPlayerDB
--
-- MESSAGE TYPES HANDLED:
--   - GIVE: GM gives item → Show accept/decline popup
--   - TRADE: Player trades item → Show accept/decline popup
--   - SHOW: Player shows item → Show preview popup (no inventory add)
--   - SHOW_REJECT: Player rejected preview → Notify sender
--   - TRADE_ACCEPT: Player accepted trade → Remove item from our inventory
--   - TRADE_REJECT: Player rejected trade → Keep item in our inventory
--
-- MESSAGE FORMAT: "TYPE^targetName^id^name^icon^tooltip^content^extra"
--   - Caret-delimited fields (^ instead of | to avoid WoW escape sequence conflicts)
--   - Base64-encoded for safe transmission
--
-- PATTERN: Event-driven architecture (observer pattern)
--   - Similar to addEventListener() in JavaScript
--   - Similar to EventHandler in C#
-- ============================================================================
local eventFrame = CreateFrame("Frame")  -- Invisible event listener

Log("Registering event: CHAT_MSG_ADDON")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")  -- Subscribe to addon messages
Log("CHAT_MSG_ADDON registered successfully")

Log("Registering event: PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LOGIN")    -- Subscribe to login event
Log("PLAYER_LOGIN registered successfully")

Log("Setting up OnEvent handler")
Log("ADDON_PREFIX configured as: " .. tostring(ADDON_PREFIX))

eventFrame:SetScript("OnEvent", function()  -- Event handler callback
    if event == "CHAT_MSG_ADDON" then
        -- Extract event parameters (Lua 5.0 uses global arg1, arg2, etc.)
        local prefix, encodedMessage, distribution, sender = arg1, arg2, arg3, arg4

        -- Filter: Only process messages with our addon prefix (silently ignore others like TW_SHOP)
        if prefix ~= ADDON_PREFIX then
            return  -- Ignore messages from other addons
        end

        Log("RECV from " .. tostring(sender) .. ": " .. tostring(encodedMessage))

        -- Parse message using messaging module
        -- Automatically handles Base64 decoding and caret-delimited parsing
        local messageType, parts = messaging.ParseMessage(encodedMessage)

        -- Handle different message types (pattern similar to switch/case)
        if messageType == messaging.MESSAGE_TYPES.DB_SYNC_START then
            -- Format: DB_SYNC_START^messageId^databaseId^databaseName^version^checksum^totalSize
            local messageId = parts[2]
            Log("Received DB_SYNC_START from " .. sender .. " (msgId: " .. messageId .. ")")

            local incomingId   = parts[3]
            local incomingName = parts[4]

            -- Reject: name is empty
            if not incomingName or incomingName == "" then
                Log("DB_SYNC_START rejected: empty database name from " .. sender)
                return
            end

            -- Initialize chunked sync tracking
            EreaRpPlayer_ChunkedSyncs[messageId] = {
                metadata = {
                    id = incomingId,
                    name = incomingName,
                    version = tonumber(parts[5]),
                    checksum = parts[6]
                },
                totalSize = tonumber(parts[7]),
                chunks = {},
                totalChunks = 0,
                sender = sender
            }

            Log("Sync started: " .. incomingName .. " (total size: " .. parts[7] .. " bytes)")

        elseif messageType == messaging.MESSAGE_TYPES.DB_SYNC_CHUNK then
            -- Format: DB_SYNC_CHUNK^messageId^chunkIndex^totalChunks^chunkData
            local messageId = parts[2]
            local chunkIndex = tonumber(parts[3])
            local totalChunks = tonumber(parts[4])
            local chunkData = parts[5]

            Log("Received DB_SYNC_CHUNK " .. chunkIndex .. "/" .. totalChunks .. " (msgId: " .. messageId .. ")")

            if not EreaRpPlayer_ChunkedSyncs[messageId] then
                Log("ERROR: No DB_SYNC_START for message ID: " .. messageId)
                return
            end

            -- Store chunk
            EreaRpPlayer_ChunkedSyncs[messageId].chunks[chunkIndex] = chunkData
            EreaRpPlayer_ChunkedSyncs[messageId].totalChunks = totalChunks

            -- Show progress
            local received = table.getn(EreaRpPlayer_ChunkedSyncs[messageId].chunks)
            Log("Progress: " .. received .. "/" .. totalChunks .. " chunks received")

        elseif messageType == messaging.MESSAGE_TYPES.DB_SYNC_END then
            -- Format: DB_SYNC_END^messageId
            local messageId = parts[2]
            Log("Received DB_SYNC_END (msgId: " .. messageId .. ")")

            if not EreaRpPlayer_ChunkedSyncs[messageId] then
                Log("ERROR: No DB_SYNC_START for message ID: " .. messageId)
                return
            end

            -- Reassemble the database
            local syncedDatabase, reason = objectDatabase.ReassembleChunkedSync(EreaRpPlayer_ChunkedSyncs[messageId])

            if syncedDatabase then
                -- Ensure databases table exists (safety guard for pre-migration SavedVariables)
                if not EreaRpPlayerDB.databases then
                    EreaRpPlayerDB.databases  = {}
                    EreaRpPlayerDB.inventories = {}
                    Log("WARNING: EreaRpPlayerDB.databases was nil at sync time — reinitialised")
                end

                -- Store in multi-tenant databases table
                local dbId = syncedDatabase.metadata.id
                syncedDatabase.metadata.lastSyncTime = time()
                EreaRpPlayerDB.databases[dbId] = syncedDatabase

                -- Count items (hash table indexed by ID)
                local itemCount = 0
                for _ in pairs(syncedDatabase.items) do
                    itemCount = itemCount + 1
                end
                Log("Database synced successfully: " .. syncedDatabase.metadata.name .. " (" .. itemCount .. " items)")

                -- Activate this database (updates syncState + refreshes bag)
                EreaRpPlayer_SetActiveDatabase(dbId)

                -- Clean up chunked sync data
                EreaRpPlayer_ChunkedSyncs[messageId] = nil
            else
                local errMsg = reason or "unknown"
                Log("ERROR: ReassembleChunkedSync failed: " .. errMsg)
                EreaRpPlayer_ChunkedSyncs[messageId] = nil
            end

        elseif messageType == messaging.MESSAGE_TYPES.GIVE then
            -- FORMAT v0.2.2: GIVE^targetName^itemGuid^customMessage^customText^customNumber^additionalText
            local targetName = parts[2]
            local itemGuid = parts[3]
            local customMessage = parts[4] or "A Game Master wants to give you an item."
            local customText = parts[5] or ""
            local customNumber = tonumber(parts[6]) or 0
            local additionalText = parts[7] or ""   -- NEW (v0.2.2): old senders omit this field
            local myName = UnitName("player")

            Log("GIVE - Target: " .. tostring(targetName) .. ", GUID: " .. tostring(itemGuid) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("GIVE not for me")
                return
            end

            -- Look up item by GUID in active database
            local activeDb = EreaRpPlayerDB.activeDatabaseId
                             and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
            if not activeDb or not activeDb.items then
                Log("ERROR: No active database to look up item GUID: " .. itemGuid .. " from " .. sender)
                return
            end

            local objectDef = nil
            for _, dbItem in pairs(activeDb.items) do
                if dbItem.guid == itemGuid then
                    objectDef = dbItem
                    break
                end
            end

            if not objectDef then
                Log("ERROR: Item GUID not found in active database: " .. itemGuid .. " (database: " .. tostring(EreaRpPlayerDB.syncState.databaseName) .. ")")
                return
            end

            -- Check if bag is full
            if inventory.IsBagFull(EreaRpPlayerDB.inventory) then
                Log("Bag is full, cannot receive item: " .. objectDef.name)
                return
            end

            -- v0.2.2: Create instance data only (minimal storage)
            local instance = inventory.CreateItemInstance(itemGuid, customText, additionalText, customNumber)

            -- Store instance + object reference for popup
            EreaRpPlayer_PendingGiveItem = instance
            EreaRpPlayer_PendingGiveObjectDef = objectDef  -- For display during popup
            EreaRpPlayer_PendingGiveSender = sender
            EreaRpPlayer_PendingGiveMessage = customMessage

            -- Show accept/decline popup (only custom message in gold)
            StaticPopup_Show("EreaRpPlayer_GIVE_REQUEST", customMessage)
            Log("Showing GIVE popup for item: " .. objectDef.name)

        elseif messageType == "GIVE_CONTENT" then
            -- DEPRECATED: Old two-part protocol, no longer used
            Log("WARNING: Received deprecated GIVE_CONTENT message - ignoring")

        elseif messageType == messaging.MESSAGE_TYPES.TRADE then
            -- FORMAT v0.2.2: TRADE^targetName^objectGuid^customText^customNumber^additionalText
            local targetName = parts[2]
            local myName = UnitName("player")

            Log("=== TRADE MESSAGE RECEIVED ===")
            Log("TRADE - Target: " .. tostring(targetName) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("TRADE not for me")
                return
            end

            local objectGuid    = parts[3] or ""
            local customText    = parts[4] or ""
            local customNumber  = tonumber(parts[5]) or 0
            local additionalText = parts[6] or ""

            -- Look up object in active database
            local activeDb = EreaRpPlayerDB.activeDatabaseId
                             and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
            local objectDef = nil
            if activeDb and activeDb.items then
                for id, obj in pairs(activeDb.items) do
                    if obj.guid == objectGuid then
                        objectDef = obj
                        break
                    end
                end
            end

            if not objectDef then
                -- Error: object not in database
                Log("TRADE failed: Object " .. objectGuid .. " not found in active database")
                return
            end

            -- v0.2.2: Create instance data with additionalText
            local instance = inventory.CreateItemInstance(objectGuid, customText, additionalText, customNumber)

            Log("TRADE complete - Item: " .. tostring(objectDef.name) .. " from " .. sender)

            -- Check if bag is full (with detailed logging)
            local currentCount = table.getn(EreaRpPlayerDB.inventory)
            local emptySlots = inventory.GetEmptySlotCount(EreaRpPlayerDB.inventory)
            local isFull = inventory.IsBagFull(EreaRpPlayerDB.inventory)
            Log("TRADE inventory check - Current items: " .. currentCount .. ", Empty slots: " .. emptySlots .. ", IsBagFull: " .. tostring(isFull))

            if isFull then
                Log("Bag is full, cannot accept trade")
                -- Debug: Log all items with their slots
                for i, item in ipairs(EreaRpPlayerDB.inventory) do
                    Log("  Item " .. i .. ": guid=" .. tostring(item.guid) .. ", slot=" .. tostring(item.slot))
                end
                return
            end

            -- Store instance + object reference for popup
            EreaRpPlayer_PendingTradeItem = instance
            EreaRpPlayer_PendingTradeObjectDef = objectDef  -- For display during popup
            EreaRpPlayer_PendingTradeSender = sender

            -- Show popup
            StaticPopup_Show("EreaRpPlayer_TRADE_REQUEST", sender, objectDef.name or "an item")
            Log("Showing TRADE_REQUEST popup from " .. sender)

        elseif messageType == "TRADE_CONTENT" then
            -- DEPRECATED: Old two-part protocol, no longer used
            Log("WARNING: Received deprecated TRADE_CONTENT message - ignoring")

        elseif messageType == messaging.MESSAGE_TYPES.SHOW then
            -- FORMAT v0.1.1: SHOW^targetName^objectGuid^customText^customNumber
            local targetName = parts[2]
            local myName = UnitName("player")

            Log("SHOW - Target: " .. tostring(targetName) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("SHOW not for me")
                return
            end

            local objectGuid = parts[3] or ""
            local customText = parts[4] or ""
            local customNumber = tonumber(parts[5]) or 0

            -- Look up object in active database
            local activeDb = EreaRpPlayerDB.activeDatabaseId
                             and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
            local objectDef = nil
            if activeDb and activeDb.items then
                for id, obj in pairs(activeDb.items) do
                    if obj.guid == objectGuid then
                        objectDef = obj
                        break
                    end
                end
            end

            if not objectDef then
                -- Error: object not in database
                Log("SHOW failed: Object " .. objectGuid .. " not found in active database")
                return
            end

            -- Build item from object definition + instance data (don't add to inventory, just for display)
            local item = {
                guid = objectDef.guid,
                name = objectDef.name,
                icon = objectDef.icon,
                tooltip = objectDef.tooltip,
                content = objectDef.content,
                contentTemplate = objectDef.contentTemplate,  -- v0.2.0: Include template for custom text display
                actions = objectDef.actions,  -- Shared reference (read-only)
                customText = customText,
                customNumber = customNumber
            }

            Log("SHOW complete - Item: " .. tostring(item.name) .. " from " .. sender)

            -- Store item and sender for popup callbacks
            EreaRpPlayer_PendingShowItem = item
            EreaRpPlayer_PendingShowSender = sender

            -- Show standard confirmation popup
            StaticPopup_Show("EreaRpPlayer_SHOW_REQUEST", sender, item.name or "an object")
            Log("Showing SHOW_REQUEST popup from " .. sender)

        elseif messageType == "SHOW_CONTENT" then
            -- DEPRECATED: Old two-part protocol, no longer used
            Log("WARNING: Received deprecated SHOW_CONTENT message - ignoring")

        elseif messageType == messaging.MESSAGE_TYPES.SHOW_REJECT then
            -- Format: SHOW_REJECT^targetName^itemName — sender (rejecter) from arg4
            local targetName = parts[2]
            local itemName = parts[3]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("SHOW_REJECT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("SHOW_REJECT received from " .. sender .. " for item: " .. tostring(itemName))
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[RP]|r " .. sender .. " refused to look at |cFFFFFFFF" .. tostring(itemName) .. "|r.")

        elseif messageType == messaging.MESSAGE_TYPES.TRADE_ACCEPT then
            -- Format: TRADE_ACCEPT^targetName^itemName — sender (accepter) from arg4
            local targetName = parts[2]
            local itemName = parts[3]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("TRADE_ACCEPT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("TRADE_ACCEPT received from " .. sender .. " for item: " .. tostring(itemName))

            -- Remove pending outgoing trade if exists
            if EreaRpPlayer_PendingOutgoingTrade then
                -- Debug logging before removal
                local beforeCount = table.getn(EreaRpPlayerDB.inventory)
                Log("TRADE_ACCEPT (outgoing): Before removing item - inventory count: " .. beforeCount .. ", pending slot: " .. tostring(EreaRpPlayer_PendingOutgoingTrade.slot))

                -- Remove from inventory by slot (unique identifier)
                for i, invItem in ipairs(EreaRpPlayerDB.inventory) do
                    if invItem.slot == EreaRpPlayer_PendingOutgoingTrade.slot then
                        table.remove(EreaRpPlayerDB.inventory, i)

                        -- Debug logging after removal
                        local afterCount = table.getn(EreaRpPlayerDB.inventory)
                        Log("TRADE_ACCEPT (outgoing): After removing item - inventory count: " .. afterCount .. " (removed slot " .. tostring(invItem.slot) .. ", guid: " .. tostring(invItem.guid) .. ")")

                        EreaRpPlayerInventory:RefreshBag()
                        break
                    end
                end
                EreaRpPlayer_PendingOutgoingTrade = nil
            end

        elseif messageType == messaging.MESSAGE_TYPES.TRADE_REJECT then
            -- Format: TRADE_REJECT^targetName^itemName — sender (rejecter) from arg4
            local targetName = parts[2]
            local itemName = parts[3]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("TRADE_REJECT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("TRADE_REJECT received from " .. sender .. " for item: " .. tostring(itemName))
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[RP]|r " .. sender .. " refused the trade for |cFFFFFFFF" .. tostring(itemName) .. "|r.")

            -- Clear pending outgoing trade (item stays in inventory)
            EreaRpPlayer_PendingOutgoingTrade = nil

        elseif messageType == messaging.MESSAGE_TYPES.CINEMATIC then
            -- Format: CINEMATIC^cinematicGuid^senderName^customText^additionalText^customNumber^[sv1]^...
            -- senderName may be comma-separated for merge cinematics (e.g. "PlayerA,PlayerB")
            -- speakerName is looked up from cinematicLibrary (not on wire)
            local cinematicGuid  = parts[2] or ""
            local senderName     = parts[3] or sender
            local customText     = parts[4] or ""
            local additionalText = parts[5] or ""
            local customNumber   = tonumber(parts[6]) or 0

            -- Extract script values (all parts after index 6)
            local scriptValues = {}
            for i = 7, table.getn(parts) do
                table.insert(scriptValues, parts[i])
            end

            -- Build natural-language list from comma-separated senders (e.g. "A,B,C" → "A, B and C")
            -- Lua 5.0: use string.gfind instead of string.gmatch
            local function BuildNaturalLanguageList(commaSeparated)
                local names = {}
                for name in string.gfind(commaSeparated, "([^,]+)") do
                    table.insert(names, name)
                end
                local count = table.getn(names)
                if count == 0 then return "" end
                if count == 1 then return names[1] end
                local result = names[1]
                for i = 2, count - 1 do
                    result = result .. ", " .. names[i]
                end
                return result .. " and " .. names[count]
            end

            local playerNameList = BuildNaturalLanguageList(senderName)

            Log("CINEMATIC received cinematicGuid=" .. tostring(cinematicGuid) .. " from " .. tostring(senderName))

            -- Proximity check: show if ANY sender is nearby (~28 yards)
            -- Supports comma-separated sender list for merge cinematics
            local inRange = false
            -- Lua 5.0: use string.gfind instead of string.gmatch
            for name in string.gfind(senderName, "([^,]+)") do
                if unitUtils.CheckPlayerInRangeInspect(name) then
                    inRange = true
                    break
                end
            end

            if not inRange then
                Log("Cinematic not shown: no sender in range (" .. senderName .. ")")
            else
                -- Look up cinematic from active database
                local cinematic = nil
                local activeDb = EreaRpPlayerDB.activeDatabaseId
                                 and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
                if activeDb and activeDb.cinematicLibrary then
                    cinematic = activeDb.cinematicLibrary[cinematicGuid]
                end

                local dialogueText = ""

                if cinematic then
                    -- Resolve placeholders in message template
                    dialogueText = cinematic.messageTemplate or ""
                    -- Apply item placeholders first ({custom-text}, {additional-text}, {item-counter}, {player-name})
                    dialogueText = objectDatabase.ApplyItemPlaceholders(dialogueText, customText, additionalText, customNumber, playerNameList)
                    dialogueText = string.gsub(dialogueText, "{playerName}", playerNameList)
                    dialogueText = string.gsub(dialogueText, "{customText}", customText)
                    
                    -- Replace {script:XXX} placeholders with received script values
                    -- Use explicit scriptReferences field if available
                    local valueIndex = 1
                    if cinematic.scriptReferences and cinematic.scriptReferences ~= "" then
                        -- Parse comma-separated script names (Lua 5.0 compatible)
                        local i = 1
                        while i <= string.len(cinematic.scriptReferences) do
                            local start_name, end_name = string.find(cinematic.scriptReferences, ",", i, true)
                            if start_name then
                                local scriptName = string.sub(cinematic.scriptReferences, i, start_name - 1)
                                local placeholder = "{script:" .. scriptName .. "}"
                                if scriptValues and scriptValues[valueIndex] then
                                    dialogueText = string.gsub(dialogueText, placeholder, scriptValues[valueIndex], 1)
                                end
                                valueIndex = valueIndex + 1
                                i = end_name + 1
                            else
                                -- Last script name
                                local scriptName = string.sub(cinematic.scriptReferences, i)
                                local placeholder = "{script:" .. scriptName .. "}"
                                if scriptValues and scriptValues[valueIndex] then
                                    dialogueText = string.gsub(dialogueText, placeholder, scriptValues[valueIndex], 1)
                                end
                                break
                            end
                        end
                    else
                        -- Fallback: extract from message template for backward compatibility
                        local valueIndex = 1
                        local i = 1
                        while i <= string.len(dialogueText) do
                            local start_script, end_script = string.find(dialogueText, "{script:", i, true)
                            if start_script then
                                local start_name = end_script + 1
                                local end_name = string.find(dialogueText, "}", start_name, true)
                                if end_name then
                                    local scriptName = string.sub(dialogueText, start_name, end_name - 1)
                                    local placeholder = "{script:" .. scriptName .. "}"
                                    if scriptValues and scriptValues[valueIndex] then
                                        dialogueText = string.gsub(dialogueText, placeholder, scriptValues[valueIndex], 1)
                                    end
                                    valueIndex = valueIndex + 1
                                    i = end_name + 1
                                else
                                    break
                                end
                            else
                                break
                            end
                        end
                    end
                    
                    Log("CINEMATIC: resolved from library")
                else
                    -- Fallback: use customText as raw dialogue text
                    dialogueText = customText
                    Log("CINEMATIC: cinematicGuid not found in library, using customText as fallback")
                end

                -- Build config objects for left/right sides
                local leftConfig = nil
                local rightConfig = nil

                if cinematic and cinematic.leftType then
                    -- New format: build configs from stored fields
                    leftConfig = {
                        type = cinematic.leftType or "none",
                        portraitUnit = cinematic.leftPortraitUnit or "player",
                        animationKey = cinematic.leftAnimationKey or "",
                        loopMode = cinematic.leftLoopMode or "pingpong"
                    }
                    rightConfig = {
                        type = cinematic.rightType or "none",
                        portraitUnit = cinematic.rightPortraitUnit or "player",
                        animationKey = cinematic.rightAnimationKey or "",
                        loopMode = cinematic.rightLoopMode or "pingpong"
                    }
                    Log("CINEMATIC: new format, left=" .. tostring(cinematic.leftType) .. " right=" .. tostring(cinematic.rightType))
                else
                    -- Old format backward compat: portrait left, animation right
                    leftConfig = { type = "portrait", portraitUnit = "player" }
                    local animKey = cinematic and cinematic.animationKey or ""
                    if animKey ~= "" then
                        rightConfig = { type = "animation", animationKey = animKey }
                    else
                        rightConfig = { type = "none" }
                    end
                    Log("CINEMATIC: legacy format, anim=" .. tostring(animKey))
                end

                -- Look up speakerName from library and resolve placeholders
                local resolvedSpeaker = objectDatabase.ApplyItemPlaceholders(
                    cinematic and cinematic.speakerName or "",
                    customText, additionalText, customNumber, playerNameList)
                EreaRpCinematicFrame:ShowDialogue(senderName, resolvedSpeaker, dialogueText, leftConfig, rightConfig)
            end

        elseif messageType == messaging.MESSAGE_TYPES.STATUS_REQUEST then
            -- Format: STATUS_REQUEST^requestId
            local requestId = parts[2]
            local myName = UnitName("player")

            Log("STATUS_REQUEST received (reqId: " .. tostring(requestId) .. ")")

            -- Collect current state
            local playerVersion = ADDON_VERSION or "unknown"

            -- Encode sync state
            local syncStateStr = ""
            if EreaRpPlayerDB.syncState then
                syncStateStr = string.format("%s^%s^%d^%s^%d",
                    EreaRpPlayerDB.syncState.databaseId or "",
                    EreaRpPlayerDB.syncState.databaseName or "",
                    EreaRpPlayerDB.syncState.version or 0,
                    EreaRpPlayerDB.syncState.checksum or "",
                    EreaRpPlayerDB.syncState.lastSyncTime or 0)
            end
            local syncStateEncoded = encoding.Base64Encode(syncStateStr)

            -- Encode inventory (16 slots: guid~base64(customText)~customNumber per slot)
            local inventorySlots = {}
            for i = 1, 16 do
                local item = EreaRpPlayerDB.inventory and EreaRpPlayerDB.inventory[i]
                if item and item.guid then
                    local ct = encoding.Base64Encode(item.customText or "")
                    local cn = tostring(item.customNumber or 0)
                    inventorySlots[i] = item.guid .. "~" .. ct .. "~" .. cn
                else
                    inventorySlots[i] = ""
                end
            end
            local inventoryStr = table.concat(inventorySlots, "^")
            local inventoryEncoded = encoding.Base64Encode(inventoryStr)

            -- Encode location: zone name + map coordinates
            local zoneName = GetRealZoneText() or ""
            local playerX, playerY = GetPlayerMapPosition("player")
            local locationStr = zoneName .. "^" ..
                string.format("%.1f", playerX * 100) .. "^" ..
                string.format("%.1f", playerY * 100)
            local locationEncoded = encoding.Base64Encode(locationStr)

            -- Encode registered extensions (comma-separated addon names)
            local cinematicAnims = EreaRpLibraries:CinematicAnimations()
            local extList = cinematicAnims.GetRegisteredExtensions()
            local extensionsStr = table.concat(extList, ",")
            local extensionsEncoded = encoding.Base64Encode(extensionsStr)

            -- Build response message
            local responseMsg = messaging.MESSAGE_TYPES.STATUS_RESPONSE .. "^" ..
                               requestId .. "^" ..
                               playerVersion .. "^" ..
                               syncStateEncoded .. "^" ..
                               inventoryEncoded .. "^" ..
                               locationEncoded .. "^" ..
                               extensionsEncoded

            -- Send response
            local distribution = "RAID"
            if GetNumRaidMembers() == 0 then
                distribution = "PARTY"
            end
            SendAddonMessage(ADDON_PREFIX, responseMsg, distribution)

            Log("STATUS_RESPONSE sent (reqId: " .. tostring(requestId) .. ")")

        elseif messageType == messaging.MESSAGE_TYPES.SCRIPT_REQUEST then
            -- Format: SCRIPT_REQUEST^playerName^scriptName^requestId
            local targetName = parts[2]
            local scriptName = parts[3]
            local requestId  = parts[4]
            local myName = UnitName("player")

            Log("SCRIPT_REQUEST received: target=" .. tostring(targetName) .. " script=" .. tostring(scriptName) .. " reqId=" .. tostring(requestId))

            -- Check if message is for me
            if targetName ~= myName then
                Log("SCRIPT_REQUEST not for me")
                return
            end

            -- Look up script in active database
            local activeDb = EreaRpPlayerDB.activeDatabaseId
                             and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
            local scriptDef = nil
            if activeDb and activeDb.scriptLibrary then
                scriptDef = activeDb.scriptLibrary[scriptName]
            end

            if not scriptDef then
                Log("SCRIPT_REQUEST: script not found: " .. tostring(scriptName))
                messaging.SendScriptResultMessage(requestId, "Error: script not found")
                return
            end

            -- Execute in sandbox
            local fn, compileErr = loadstring(scriptDef.body)
            if not fn then
                Log("SCRIPT_REQUEST: compile error: " .. tostring(compileErr))
                messaging.SendScriptResultMessage(requestId, "Compile error: " .. tostring(compileErr))
                return
            end

            -- Build sandbox environment
            local env = {
                string = string, math = math, table = table,
                tostring = tostring, tonumber = tonumber, type = type,
                pairs = pairs, ipairs = ipairs, unpack = unpack,
                UnitName = UnitName, UnitClass = UnitClass, UnitLevel = UnitLevel,
                UnitRace = UnitRace, UnitSex = UnitSex,
                GetTime = GetTime, date = date, random = math.random,
                GetRealZoneText = GetRealZoneText, GetZoneText = GetZoneText,
                GetSubZoneText = GetSubZoneText,
                GetPlayerMapPosition = GetPlayerMapPosition,
                GetNumRaidMembers = GetNumRaidMembers, GetNumPartyMembers = GetNumPartyMembers,
                UnitIsConnected = UnitIsConnected, UnitIsDeadOrGhost = UnitIsDeadOrGhost,
                player = myName
            }
            setfenv(fn, env)

            local ok, result = pcall(fn)
            if not ok then
                Log("SCRIPT_REQUEST: runtime error: " .. tostring(result))
                messaging.SendScriptResultMessage(requestId, "Runtime error: " .. tostring(result))
                return
            end

            local resultStr = tostring(result or "nil")
            Log("SCRIPT_REQUEST: result=" .. resultStr)
            messaging.SendScriptResultMessage(requestId, resultStr)
        end

    elseif event == "PLAYER_LOGIN" then
        -- Clear log at session start in production builds (RP_PRODUCTION_BUILD set by build.ps1)
        if RP_PRODUCTION_BUILD then
            _G["RPPlayerDebugLog"] = {}
        end
        Log("PLAYER_LOGIN event fired")

        -- Check if EreaRpPlayerDB exists
        if EreaRpPlayerDB then
            Log("EreaRpPlayerDB exists: " .. type(EreaRpPlayerDB))
        else
            Log("EreaRpPlayerDB is nil!")
        end

        -- Migrate inventory to v0.1.1 (add customText and customNumber fields)
        local migrated = false
        for i = 1, table.getn(EreaRpPlayerDB.inventory or {}) do
            local item = EreaRpPlayerDB.inventory[i]

            if not item.customText then
                item.customText = ""
                migrated = true
            end

            if not item.customNumber then
                item.customNumber = 0
                migrated = true
            end
        end

        if migrated then
            Log("Inventory migrated to v0.1.1 format")
        end

        -- Check if system-welcome-db inventory is empty and add welcome item if needed
        local systemDbInventory = EreaRpPlayerDB.inventories["system-welcome-db"] or {}
        if table.getn(systemDbInventory) == 0 then
            Log("system-welcome-db inventory is empty, adding system-welcome-0")
            local welcomeItem = inventory.CreateItemInstance("system-welcome-0", "", "", 0)
            table.insert(systemDbInventory, welcomeItem)
            EreaRpPlayerDB.inventories["system-welcome-db"] = systemDbInventory
            if EreaRpPlayerDB.activeDatabaseId == "system-welcome-db" then
                EreaRpPlayerDB.inventory = systemDbInventory
            end
            Log("Added system-welcome-0 to system-welcome-db inventory")
        else
            Log("system-welcome-db inventory already has items")
        end

        -- Cleanup duplicate slots before refreshing bag
        Log("Running duplicate slot cleanup")
        EreaRpPlayerEventHandler:CleanupDuplicateSlots()

        -- Refresh bag display after initialization
        Log("Calling EreaRpPlayerInventory:RefreshBag()")
        EreaRpPlayerInventory:RefreshBag()
        Log("EreaRpPlayerInventory:RefreshBag() completed")

        -- Unregister this event since we only need to run once per session
        eventFrame:UnregisterEvent("PLAYER_LOGIN")
        Log("PLAYER_LOGIN event unregistered")
    end
end)

-- ============================================================================
-- ResetPositions - Reset frame positions to default
-- ============================================================================
function EreaRpPlayerEventHandler:ResetPositions()
    EreaRpPlayerDB.bagFramePos = nil
    EreaRpPlayerDB.readFramePos = nil

    -- Reset bag frame
    EreaRpPlayerBagFrame:ClearAllPoints()
    EreaRpPlayerBagFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

    -- Reset read frame
    EreaRpPlayerReadFrame:ClearAllPoints()
    EreaRpPlayerReadFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

-- ============================================================================
-- ShowLog - Display debug log viewer using shared log viewer
-- ============================================================================
-- Uses EreaRpLogViewerFrame from turtle-rp-common (prototype pattern)
-- ============================================================================
function EreaRpPlayerEventHandler:ShowLog()
    EreaRpLogViewerFrame:ShowLog("RPPlayer")
end

-- ============================================================================
-- CleanupDuplicateSlots - Remove duplicate items in same slot
-- ============================================================================
-- Keeps only the FIRST item for each slot, removes all others
-- Warns player in chat for each removed item
-- ============================================================================
function EreaRpPlayerEventHandler:CleanupDuplicateSlots()
    if not EreaRpPlayerDB or not EreaRpPlayerDB.inventory then
        return
    end

    local seenSlots = {}  -- Track which slots we've seen: slot -> item
    local toRemove = {}   -- Indices of items to remove

    -- Find duplicates
    for i, item in ipairs(EreaRpPlayerDB.inventory) do
        if item.slot then
            if seenSlots[item.slot] then
                -- Duplicate! Mark for removal
                table.insert(toRemove, i)

                -- Get item name for warning (need to merge with definition)
                local itemName = "Unknown"
                if item.name then
                    -- Old format or system item
                    itemName = item.name
                else
                    -- New format: lookup definition
                    local activeDb = EreaRpPlayerDB.activeDatabaseId
                                     and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
                    local fullItem = inventory.GetFullItem(item, activeDb)
                    if fullItem then
                        itemName = fullItem.name
                    end
                end

                Log("Cleanup: Removed duplicate item '" .. itemName .. "' from slot " .. item.slot)
            else
                -- First occurrence - keep it
                seenSlots[item.slot] = item
            end
        end
    end

    -- Remove duplicates (in reverse order to preserve indices)
    for i = table.getn(toRemove), 1, -1 do
        table.remove(EreaRpPlayerDB.inventory, toRemove[i])
    end

    -- Report results
    local removedCount = table.getn(toRemove)
    if removedCount > 0 then
        Log("Cleanup complete: removed " .. removedCount .. " duplicates")
        EreaRpPlayerInventory:RefreshBag()
    else
        Log("Cleanup: No duplicates found")
    end
end

-- Slash command
SLASH_RPPLAYER1 = "/rpplayer"
SlashCmdList["RPPLAYER"] = function(msg)
    -- Handle log command
    if msg == "log" then
        EreaRpPlayerEventHandler:ShowLog()
        return
    end

    -- Handle clearlog command
    if msg == "clearlog" then
        EreaRpLogViewerFrame:ClearLog("RPPlayer")
        return
    end

    -- Handle clean command
    if msg == "clean" then
        EreaRpPlayerEventHandler:CleanupDuplicateSlots()
        return
    end

    -- Handle reset command
    if msg == "reset" then
        EreaRpPlayerEventHandler:ResetPositions()
        return
    end

    -- Toggle bag
    if EreaRpPlayerBagFrame:IsShown() then
        EreaRpPlayerBagFrame:Hide()
    else
        Log("Opening bag via slash command")
        EreaRpPlayerBagFrame:Show()
        EreaRpPlayerInventory:RefreshBag()
    end
end
