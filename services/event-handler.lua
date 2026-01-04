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
--   - RPPlayerInventory prototype (from services/inventory.lua)
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

        Log("OnEvent triggered - event type: " .. tostring(event))
        Log("CHAT_MSG_ADDON received - prefix: " .. tostring(prefix) .. ", distribution: " .. tostring(distribution) .. ", sender: " .. tostring(sender))
        Log("  message length: " .. tostring(string.len(encodedMessage or "")))
        Log("Message: " .. encodedMessage)

        -- Parse message using messaging module
        -- Automatically handles Base64 decoding and caret-delimited parsing
        local messageType, parts = messaging.ParseMessage(encodedMessage)

        Log("Message type: " .. tostring(messageType) .. ", parts count: " .. table.getn(parts))

        -- Log all parts for debugging
        for i = 1, table.getn(parts) do
            Log("Part " .. i .. ": " .. tostring(parts[i]))
        end

        -- Handle different message types (pattern similar to switch/case)
        if messageType == messaging.MESSAGE_TYPES.DB_SYNC_START then
            -- Format: DB_SYNC_START^messageId^databaseId^databaseName^version^checksum^totalSize
            local messageId = parts[2]
            Log("Received DB_SYNC_START from " .. sender .. " (msgId: " .. messageId .. ")")

            -- Initialize chunked sync tracking
            EreaRpPlayer_ChunkedSyncs[messageId] = {
                metadata = {
                    id = parts[3],
                    name = parts[4],
                    version = tonumber(parts[5]),
                    checksum = parts[6]
                },
                totalSize = tonumber(parts[7]),
                chunks = {},
                totalChunks = 0,
                sender = sender
            }

            Log("Sync started: " .. parts[4] .. " (total size: " .. parts[7] .. " bytes)")

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
            local syncedDatabase = objectDatabase.ReassembleChunkedSync(EreaRpPlayer_ChunkedSyncs[messageId])

            if syncedDatabase then
                -- Store synced database in SavedVariables
                EreaRpPlayerDB.syncedDatabase = syncedDatabase

                -- Update sync state metadata
                EreaRpPlayerDB.syncState = {
                    databaseId = syncedDatabase.metadata.id,
                    databaseName = syncedDatabase.metadata.name,
                    version = syncedDatabase.metadata.version,
                    checksum = syncedDatabase.metadata.checksum,
                    lastSyncTime = time()
                }

                -- Count items (hash table indexed by ID)
                local itemCount = 0
                for _ in pairs(syncedDatabase.items) do
                    itemCount = itemCount + 1
                end
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r Database synced from %s: '%s' (%d items)",
                    sender, syncedDatabase.metadata.name, itemCount), 0, 1, 0)
                Log("Database synced successfully: " .. syncedDatabase.metadata.name .. " (" .. itemCount .. " items)")

                -- Refresh bag UI to show database name
                RPPlayerInventory:RefreshBag()

                -- Clean up chunked sync data
                EreaRpPlayer_ChunkedSyncs[messageId] = nil
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Failed to reassemble database sync from " .. sender, 1, 0, 0)
                Log("ERROR: Failed to reassemble DB_SYNC chunks")
            end

        elseif messageType == messaging.MESSAGE_TYPES.GIVE then
            -- FORMAT v0.1.1: GIVE^targetName^itemGuid^customMessage^customText^customNumber
            local targetName = parts[2]
            local itemGuid = parts[3]
            local customMessage = parts[4] or "A Game Master wants to give you an item."
            local customText = parts[5] or ""
            local customNumber = tonumber(parts[6]) or 0
            local myName = UnitName("player")

            Log("GIVE - Target: " .. tostring(targetName) .. ", GUID: " .. tostring(itemGuid) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("GIVE not for me")
                return
            end

            -- Look up item by GUID in synced database
            if not EreaRpPlayerDB.syncedDatabase or not EreaRpPlayerDB.syncedDatabase.items then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r No database synced from GM!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Ask " .. sender .. " to click 'Sync to Raid' first.", 1, 1, 0)
                Log("ERROR: No synced database to look up item GUID: " .. itemGuid .. " from " .. sender)
                return
            end

            local objectDef = nil
            for _, dbItem in pairs(EreaRpPlayerDB.syncedDatabase.items) do
                if dbItem.guid == itemGuid then
                    objectDef = dbItem
                    break
                end
            end

            if not objectDef then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Item not found in database!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Ask " .. sender .. " to click 'Sync to Raid' to update your database.", 1, 1, 0)
                Log("ERROR: Item GUID not found in synced database: " .. itemGuid .. " (database: " .. tostring(EreaRpPlayerDB.syncState.databaseName) .. ")")
                return
            end

            -- Check if bag is full
            if inventory.IsBagFull(EreaRpPlayerDB.inventory) then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Bag is full! Cannot receive item.", 1, 0, 0)
                Log("Bag is full, cannot receive item: " .. objectDef.name)
                return
            end

            -- v0.2.1: Create instance data only (minimal storage)
            local instance = inventory.CreateItemInstance(itemGuid, customText, customNumber)

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
            -- FORMAT v0.1.1: TRADE^targetName^objectGuid^customText^customNumber
            local targetName = parts[2]
            local myName = UnitName("player")

            Log("=== TRADE MESSAGE RECEIVED ===")
            Log("TRADE - Target: " .. tostring(targetName) .. ", MyName: " .. tostring(myName))

            if targetName ~= myName then
                Log("TRADE not for me")
                return
            end

            local objectGuid = parts[3] or ""
            local customText = parts[4] or ""
            local customNumber = tonumber(parts[5]) or 0

            -- Look up object in syncedDatabase
            local objectDef = nil
            if EreaRpPlayerDB.syncedDatabase and EreaRpPlayerDB.syncedDatabase.items then
                for id, obj in pairs(EreaRpPlayerDB.syncedDatabase.items) do
                    if obj.guid == objectGuid then
                        objectDef = obj
                        break
                    end
                end
            end

            if not objectDef then
                -- Error: object not in database
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Object not found in database!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Ask GM to 'Sync to Raid' first.", 1, 1, 0)
                Log("TRADE failed: Object " .. objectGuid .. " not found in syncedDatabase")
                return
            end

            -- v0.2.1: Create instance data only (minimal storage)
            local instance = inventory.CreateItemInstance(objectGuid, customText, customNumber)

            Log("TRADE complete - Item: " .. tostring(objectDef.name) .. " from " .. sender)

            -- Check if bag is full (with detailed logging)
            local currentCount = table.getn(EreaRpPlayerDB.inventory)
            local emptySlots = inventory.GetEmptySlotCount(EreaRpPlayerDB.inventory)
            local isFull = inventory.IsBagFull(EreaRpPlayerDB.inventory)
            Log("TRADE inventory check - Current items: " .. currentCount .. ", Empty slots: " .. emptySlots .. ", IsBagFull: " .. tostring(isFull))

            if isFull then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Bag is full! Cannot accept trade.", 1, 0, 0)
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

            -- Look up object in syncedDatabase
            local objectDef = nil
            if EreaRpPlayerDB.syncedDatabase and EreaRpPlayerDB.syncedDatabase.items then
                for id, obj in pairs(EreaRpPlayerDB.syncedDatabase.items) do
                    if obj.guid == objectGuid then
                        objectDef = obj
                        break
                    end
                end
            end

            if not objectDef then
                -- Error: object not in database
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Object not found in database!", 1, 0, 0)
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFFAA00[RP Player]|r Ask GM to 'Sync to Raid' first.", 1, 1, 0)
                Log("SHOW failed: Object " .. objectGuid .. " not found in syncedDatabase")
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
            -- Format: SHOW_REJECT^targetName^rejecterName^itemName
            local targetName = parts[2]
            local rejecterName = parts[3]
            local itemName = parts[4]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("SHOW_REJECT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("SHOW_REJECT received from " .. rejecterName .. " for item: " .. tostring(itemName))

            -- Display rejection message to the shower
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r %s rejected to view '%s'", rejecterName, itemName), 1, 0.5, 0)

        elseif messageType == messaging.MESSAGE_TYPES.TRADE_ACCEPT then
            -- Format: TRADE_ACCEPT^senderName^receiverName^itemName
            local targetName = parts[2]
            local accepterName = parts[3]
            local itemName = parts[4]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("TRADE_ACCEPT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("TRADE_ACCEPT received from " .. accepterName .. " for item: " .. tostring(itemName))

            -- Display acceptance message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r %s accepted your gift: '%s'", accepterName, itemName), 0, 1, 0)

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

                        RPPlayerInventory:RefreshBag()
                        break
                    end
                end
                EreaRpPlayer_PendingOutgoingTrade = nil
            end

        elseif messageType == "TRADE_REJECT" then
            -- Format: TRADE_REJECT^senderName^receiverName^itemName
            local targetName = parts[2]
            local rejecterName = parts[3]
            local itemName = parts[4]
            local myName = UnitName("player")

            -- Check if message is for me
            if targetName ~= myName then
                Log("TRADE_REJECT not for me (target: " .. tostring(targetName) .. ", me: " .. tostring(myName) .. ")")
                return
            end

            Log("TRADE_REJECT received from " .. rejecterName .. " for item: " .. tostring(itemName))

            -- Display rejection message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r %s declined your gift: '%s'", rejecterName, itemName), 1, 0.5, 0)

            -- Clear pending outgoing trade (item stays in inventory)
            EreaRpPlayer_PendingOutgoingTrade = nil

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

            -- Encode inventory (16 slots, GUIDs only)
            local inventoryGuids = {}
            for i = 1, 16 do
                local item = EreaRpPlayerDB.inventory and EreaRpPlayerDB.inventory[i]
                if item and item.guid then
                    inventoryGuids[i] = item.guid
                else
                    inventoryGuids[i] = ""
                end
            end
            local inventoryStr = table.concat(inventoryGuids, "^")
            local inventoryEncoded = encoding.Base64Encode(inventoryStr)

            -- Build response message
            local responseMsg = messaging.MESSAGE_TYPES.STATUS_RESPONSE .. "^" ..
                               requestId .. "^" ..
                               playerVersion .. "^" ..
                               syncStateEncoded .. "^" ..
                               inventoryEncoded

            -- Send response
            local distribution = "RAID"
            if GetNumRaidMembers() == 0 then
                distribution = "PARTY"
            end
            SendAddonMessage(ADDON_PREFIX, responseMsg, distribution)

            Log("STATUS_RESPONSE sent (reqId: " .. tostring(requestId) .. ")")
        end

    elseif event == "PLAYER_LOGIN" then
        Log("PLAYER_LOGIN event fired")

        -- This event fires once after SavedVariables are loaded
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[RP Player] Version: " .. ADDON_VERSION .. "|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FFFF[RP Player]|r Commands: /rpplayer, /rpplayer log, /rpplayer clean", 0, 1, 1)
        Log("Version message displayed")

        -- Check if EreaRpPlayerDB exists
        if EreaRpPlayerDB then
            Log("EreaRpPlayerDB exists: " .. type(EreaRpPlayerDB))
            if EreaRpPlayerDB.inventory then
                Log("EreaRpPlayerDB.inventory exists, count: " .. table.getn(EreaRpPlayerDB.inventory))
            else
                Log("EreaRpPlayerDB.inventory is nil!")
            end
        else
            Log("EreaRpPlayerDB is nil!")
        end

        -- Ensure inventory table exists
        EreaRpPlayerDB.inventory = EreaRpPlayerDB.inventory or {}
        Log("After safety check, inventory count: " .. table.getn(EreaRpPlayerDB.inventory))

        -- Migrate inventory to v0.1.1 (add customText and customNumber fields)
        local migrated = false
        for i = 1, table.getn(EreaRpPlayerDB.inventory) do
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
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Inventory migrated to v0.1.1", 0, 1, 0)
        end

        -- Add welcome item if inventory is empty (first time use)
        if table.getn(EreaRpPlayerDB.inventory) == 0 then
            Log("Inventory is empty, creating welcome letter")
            local welcomeItem = {
                id = 0,
                name = "Welcome to RP Player",
                icon = "Interface\\Icons\\INV_Misc_Note_01",
                tooltip = "Quick start guide",
                content = "RP PLAYER GUIDE\n\n" ..
                    "Left-click items to read. Right-click for options.\n\n" ..
                    "Drag items to player portraits to give or show.\n\n" ..
                    "Use /rpplayer to open bag.",
                guid = "system-welcome-0",
                customText = "",  -- v0.1.1: Instance-specific text
                customNumber = 0  -- v0.1.1: Instance-specific number
            }
            table.insert(EreaRpPlayerDB.inventory, welcomeItem)
            Log("Welcome letter inserted, new count: " .. table.getn(EreaRpPlayerDB.inventory))
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Welcome letter added to inventory", 0, 1, 0)
        else
            Log("Inventory not empty, count: " .. table.getn(EreaRpPlayerDB.inventory))
        end

        -- Cleanup duplicate slots before refreshing bag
        Log("Running duplicate slot cleanup")
        EreaRpPlayerEventHandler:CleanupDuplicateSlots()

        -- Refresh bag display after initialization
        Log("Calling RPPlayerInventory:RefreshBag()")
        RPPlayerInventory:RefreshBag()
        Log("RPPlayerInventory:RefreshBag() completed")

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

    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Frame positions reset to default", 0, 1, 0)
end

-- ============================================================================
-- ShowLog - Display debug log viewer using shared log viewer
-- ============================================================================
-- Uses RPLogViewerFrame from turtle-rp-common (prototype pattern)
-- ============================================================================
function EreaRpPlayerEventHandler:ShowLog()
    RPLogViewerFrame:ShowLog("RPPlayer")
end

-- ============================================================================
-- CleanupDuplicateSlots - Remove duplicate items in same slot
-- ============================================================================
-- Keeps only the FIRST item for each slot, removes all others
-- Warns player in chat for each removed item
-- ============================================================================
function EreaRpPlayerEventHandler:CleanupDuplicateSlots()
    if not EreaRpPlayerDB or not EreaRpPlayerDB.inventory then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r No inventory to clean")
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
                    local fullItem = inventory.GetFullItem(item, EreaRpPlayerDB.syncedDatabase)
                    if fullItem then
                        itemName = fullItem.name
                    end
                end

                -- Warn player (orange text)
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF9900[RP Player]|r More than one item in slot %d, removed '%s'", item.slot, itemName), 1, 0.6, 0)
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
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r Cleanup complete: removed %d duplicate item(s)", removedCount), 0, 1, 0)
        Log("Cleanup complete: removed " .. removedCount .. " duplicates")
        RPPlayerInventory:RefreshBag()
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r No duplicates found", 0, 1, 0)
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
        RPLogViewerFrame:ClearLog("RPPlayer")
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
        RPPlayerInventory:RefreshBag()
    end
end
