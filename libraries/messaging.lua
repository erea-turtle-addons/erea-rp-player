-- ============================================================================
-- messaging.lua - Message Protocol Logic for Turtle RP Addons
-- ============================================================================
-- PURPOSE: Item-related message protocol logic
--
-- RESPONSIBILITIES:
--   - Message creation (GIVE, TRADE, SHOW, responses)
--   - Message parsing (caret-delimited protocol)
--   - Message encoding/decoding (Base64 for responses)
--   - Distribution channel selection (RAID/PARTY)
--   - Protocol constants and message types
--
-- NOT INCLUDED:
--   - Database sync messages (see object-database.lua)
--     CreateSyncMessageChunks, ReassembleChunkedSync are in object-database.lua
--     because they're tightly coupled with database serialization
--
-- SEPARATION OF CONCERNS:
--   - This file: Item message protocol, message formatting
--   - object-database.lua: Database sync protocol, serialization
--   - Client code (rp-master/rp-player): Event handling, UI, user interaction
--   - encoding.lua: Base64 implementation details
--
-- USAGE:
--   local messaging = EreaRpLibraries:Messaging()
--   local msg = messaging.CreateGiveMessage("PlayerName", "guid-123", "Custom message")
--   SendAddonMessage(messaging.ADDON_PREFIX, msg, messaging.GetDistribution("PlayerName"))
-- ============================================================================

-- Import encoding library for Base64
local encoding = EreaRpLibraries:Encoding()

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local ADDON_PREFIX = "RPMSTR"
local MESSAGE_DELIMITER = "^"

-- Message type constants
local MESSAGE_TYPES = {
    -- Outgoing from GM to Player
    GIVE = "GIVE",
    TRADE = "TRADE",
    SHOW = "SHOW",

    -- Responses from Player to GM
    GIVE_ACCEPT = "GIVE_ACCEPT",
    GIVE_REJECT = "GIVE_REJECT",
    TRADE_ACCEPT = "TRADE_ACCEPT",
    TRADE_REJECT = "TRADE_REJECT",
    SHOW_REJECT = "SHOW_REJECT",

    -- Database sync protocol
    DB_SYNC_START = "DB_SYNC_START",
    DB_SYNC_CHUNK = "DB_SYNC_CHUNK",
    DB_SYNC_END = "DB_SYNC_END",

    -- Cinematic dialogue
    CINEMATIC = "CINEMATIC",
    CINEMATIC_TRIGGER = "CINEMATIC_TRIGGER",

    -- Merge cinematic (Player -> GM)
    MERGE_TRIGGER = "MERGE_TRIGGER",

    -- Player monitoring protocol
    STATUS_REQUEST = "STATUS_REQUEST",
    STATUS_RESPONSE = "STATUS_RESPONSE",

    -- Script execution protocol
    SCRIPT_REQUEST = "SCRIPT_REQUEST",   -- GM -> Player
    SCRIPT_RESULT = "SCRIPT_RESULT",     -- Player -> GM

    -- Lightweight status update (Player -> GM)
    STATUS_LITE = "STATUS_LITE",

    -- NPC puppet commands (GM -> NPC)
    NPC_CMD    = "NPC_CMD",     -- Single-line say/yell/emote
    NPC_SCRIPT = "NPC_SCRIPT",  -- Multi-line scripted sequence
    NPC_STOP   = "NPC_STOP",    -- Abort running script

    -- NPC chat relay (NPC -> GM)
    NPC_CHAT_RELAY = "NPC_CHAT_RELAY",  -- Nearby chat heard by NPC

    -- Action-triggered NPC/GM commands (Player -> GM -> NPC)
    NPC_ACTION_TRIGGER = "NPC_ACTION_TRIGGER",  -- Player -> GM: tag-based NPC chat
    WHISPER_TRIGGER    = "WHISPER_TRIGGER",      -- Player -> GM: whisper to player
    NPC_CMD_RANGED     = "NPC_CMD_RANGED"        -- GM -> NPC: cmd with range check
}

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- ============================================================================
-- ParseCaretDelimited() - Parse caret-delimited string
-- ============================================================================
-- @param message: String with ^ delimiters
-- @returns: Array of parts
--
-- EXAMPLE: "GIVE^PlayerName^123-456^Message" -> {"GIVE", "PlayerName", "123-456", "Message"}
--
-- IMPORTANT: Preserves empty fields (e.g., "a^^b" -> {"a", "", "b"})
-- ============================================================================
local function ParseCaretDelimited(message)
    if not message or message == "" then return {} end

    local parts = {}
    local lastPos = 1
    local msgLen = string.len(message)

    while lastPos <= msgLen do
        -- Lua 5.0: string.find(haystack, needle, start, plain)
        local caretPos = string.find(message, MESSAGE_DELIMITER, lastPos, true)  -- true = plain text search
        if caretPos then
            local field = string.sub(message, lastPos, caretPos - 1)
            table.insert(parts, field)
            lastPos = caretPos + 1

            -- Lua 5.0: If delimiter is at end of message, add final empty field
            if caretPos == msgLen then
                table.insert(parts, "")
                break
            end
        else
            -- Last field (no more carets)
            local field = string.sub(message, lastPos)
            table.insert(parts, field)
            break
        end
    end

    return parts
end

-- ============================================================================
-- GetDistribution() - Determine best addon message channel
-- ============================================================================
-- @param targetName: Player name (optional, for future WHISPER support)
-- @returns: "RAID" or "PARTY"
--
-- BEHAVIOR:
--   - Returns "RAID" if in raid (GetNumRaidMembers() > 0)
--   - Returns "PARTY" if in party (GetNumPartyMembers() > 0)
--   - Returns "RAID" as fallback (safest option)
--
-- NOTE: WoW 1.12 doesn't support WHISPER distribution for addon messages
-- ============================================================================
local function GetDistribution(targetName)
    -- Check if in raid first (raids take priority over parties)
    if GetNumRaidMembers() > 0 then
        return "RAID"
    -- Check if in party
    elseif GetNumPartyMembers() > 0 then
        return "PARTY"
    else
        -- Fallback: Return RAID even if not in one
        -- (message won't send, but won't cause error)
        return "RAID"
    end
end

-- ============================================================================
-- MESSAGE CREATION FUNCTIONS
-- ============================================================================

-- ============================================================================
-- CreateGiveMessage() - Create GIVE message (GUID-based)
-- ============================================================================
-- @param targetName: Player name to receive item
-- @param itemGuid: Item GUID for lookup in synced database
-- @param customMessage: Optional custom message shown in popup
-- @param customText: Optional instance-specific text (v0.1.1)
-- @param customNumber: Optional instance-specific number (v0.1.1)
-- @param additionalText: Optional second instance-specific text slot (v0.2.2)
-- @returns: Message string
--
-- FORMAT v0.2.2: "GIVE^playerName^itemGuid^customMessage^customText^customNumber^additionalText"
-- EXAMPLE: "GIVE^Malganis^1735056789-12345-a3f2^You found this item!^Sealed by magic^3^Beta"
-- Old clients (6 fields) safely ignore field 7; new clients default field 7 to "".
-- ============================================================================
local function CreateGiveMessage(targetName, itemGuid, customMessage, customText, customNumber, additionalText)
    if not targetName or not itemGuid then
        return nil
    end

    local msg = customMessage or ""
    local cText = customText or ""
    local cNum = tostring(customNumber or 0)
    local aText = additionalText or ""
    return MESSAGE_TYPES.GIVE .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemGuid .. MESSAGE_DELIMITER .. msg .. MESSAGE_DELIMITER .. cText .. MESSAGE_DELIMITER .. cNum .. MESSAGE_DELIMITER .. aText
end

-- ============================================================================
-- CreateTradeMessage() - Create TRADE message (GUID-based)
-- ============================================================================
-- @param targetName: Player name to trade to
-- @param itemGuid: Item GUID for lookup
-- @returns: Message string
--
-- FORMAT: "TRADE^playerName^itemGuid"
-- ============================================================================
local function CreateTradeMessage(targetName, itemGuid)
    if not targetName or not itemGuid then
        return nil
    end

    return MESSAGE_TYPES.TRADE .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemGuid
end

-- ============================================================================
-- CreateShowMessage() - Create SHOW message (GUID-based)
-- ============================================================================
-- @param targetName: Player name to show to
-- @param itemGuid: Item GUID for lookup
-- @returns: Message string
--
-- FORMAT: "SHOW^playerName^itemGuid"
-- ============================================================================
local function CreateShowMessage(targetName, itemGuid)
    if not targetName or not itemGuid then
        return nil
    end

    return MESSAGE_TYPES.SHOW .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemGuid
end

-- ============================================================================
-- RESPONSE MESSAGE FUNCTIONS
-- ============================================================================

-- ============================================================================
-- CreateGiveAcceptMessage() - Player accepted GIVE
-- ============================================================================
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "GIVE_ACCEPT^itemName"
-- NOTE: GM identity comes from arg4 (sender); no targetName needed for GM-only messages
-- ============================================================================
local function CreateGiveAcceptMessage(itemName)
    if not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.GIVE_ACCEPT .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- CreateGiveRejectMessage() - Player declined GIVE
-- ============================================================================
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "GIVE_REJECT^itemName"
-- ============================================================================
local function CreateGiveRejectMessage(itemName)
    if not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.GIVE_REJECT .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- CreateTradeAcceptMessage() - Player accepted TRADE
-- ============================================================================
-- @param targetName: Player who sent the trade (for broadcast filtering)
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "TRADE_ACCEPT^targetName^itemName"
-- ============================================================================
local function CreateTradeAcceptMessage(targetName, itemName)
    if not targetName or not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.TRADE_ACCEPT .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- CreateTradeRejectMessage() - Player declined TRADE
-- ============================================================================
-- @param targetName: Player who sent the trade (for broadcast filtering)
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "TRADE_REJECT^targetName^itemName"
-- ============================================================================
local function CreateTradeRejectMessage(targetName, itemName)
    if not targetName or not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.TRADE_REJECT .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- CreateShowRejectMessage() - Player closed SHOW preview
-- ============================================================================
-- @param targetName: Player who showed the item (for broadcast filtering)
-- @param itemName: Item name for logging
-- @returns: Base64-encoded message string
--
-- FORMAT: "SHOW_REJECT^targetName^itemName"
-- ============================================================================
local function CreateShowRejectMessage(targetName, itemName)
    if not targetName or not itemName then
        return nil
    end

    local rawData = MESSAGE_TYPES.SHOW_REJECT .. MESSAGE_DELIMITER .. targetName .. MESSAGE_DELIMITER .. itemName
    return encoding.Base64Encode(rawData)
end

-- ============================================================================
-- NOTE: DATABASE SYNC MESSAGE CREATION
-- ============================================================================
-- DB sync message creation is handled by object-database.lua:
--   - CreateSyncMessageChunks() - Creates DB_SYNC_START/CHUNK/END messages
--   - ReassembleChunkedSync() - Reassembles received chunks
--
-- messaging.lua only provides MESSAGE_TYPES constants for parsing received
-- DB sync messages. The actual creation logic stays in object-database.lua
-- since it's tightly coupled with database serialization and chunking.
-- ============================================================================

-- ============================================================================
-- MESSAGE PARSING FUNCTIONS
-- ============================================================================

-- ============================================================================
-- ParseMessage() - Parse message and determine type
-- ============================================================================
-- @param message: Message string (already decoded if needed)
-- @returns: messageType (string), parts (array)
--
-- BEHAVIOR:
--   - Automatically detects if message is Base64 encoded
--   - Decodes if needed (for backward compatibility with old clients)
--   - Parses caret-delimited fields
--   - Returns message type and all parts
--
-- MESSAGE TYPES:
--   - GIVE^playerName^itemGuid^customMessage^customText^customNumber
--   - TRADE^playerName^objectGuid^customText^customNumber
--   - SHOW^playerName^objectGuid^customText^customNumber
--   - GIVE_ACCEPT^itemName (Base64)
--   - GIVE_REJECT^itemName (Base64)
--   - TRADE_ACCEPT^targetName^itemName (Base64)
--   - TRADE_REJECT^targetName^itemName (Base64)
--   - SHOW_REJECT^targetName^itemName (Base64)
--   - CINEMATIC_TRIGGER^cinematicGuid^customText^additionalText^customNumber
--   - CINEMATIC^cinematicGuid^senderName^speakerName^customText^additionalText^customNumber^[sv1]^...
--   - MERGE_TRIGGER^mergeGroupId^objectGuid^customNumber
--   - DB_SYNC_START^messageId^databaseId^databaseName^version^checksum^totalSize
--   - DB_SYNC_CHUNK^messageId^chunkIndex^totalChunks^chunkData
--   - DB_SYNC_END^messageId
--
-- @returns: messageType, parts table
-- ============================================================================
local function ParseMessage(message)
    if not message or message == "" then
        return nil, {}
    end

    -- Check if message starts with known protocol commands (plain text)
    -- If not, it might be Base64 encoded (backward compatibility)
    local needsDecode = true
    for _, msgType in pairs(MESSAGE_TYPES) do
        if string.find(message, "^" .. msgType) then
            needsDecode = false
            break
        end
    end

    -- Decode if needed
    local decodedMessage = message
    if needsDecode then
        -- Try to decode as Base64
        local decoded = encoding.Base64Decode(message)
        if decoded and string.len(decoded) > 0 then
            decodedMessage = decoded
        end
    end

    -- Parse caret-delimited fields
    local parts = ParseCaretDelimited(decodedMessage)
    if table.getn(parts) == 0 then
        return nil, {}
    end

    local messageType = parts[1]
    return messageType, parts
end

-- ============================================================================
-- SEND FUNCTIONS - Complete message sending (create + send)
-- ============================================================================
-- These functions encapsulate the entire messaging flow so client code
-- only needs to call one function without touching SendAddonMessage directly

local function SendGiveMessage(targetName, itemGuid, customMessage, customText, customNumber, additionalText)
    local message = CreateGiveMessage(targetName, itemGuid, customMessage, customText, customNumber, additionalText)
    if not message then return false end

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- Player-to-player TRADE: send full item data (receiver doesn't have sender's inventory)
local function SendTradeMessage(targetName, item)
    if not targetName or not item then return false end

    -- Format v0.2.2: TRADE^targetName^objectGuid^customText^customNumber^additionalText
    local message = string.format("TRADE^%s^%s^%s^%s^%s",
        targetName,
        item.guid or "",
        item.customText or "",
        tostring(item.customNumber or 0),
        item.additionalText or "")

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- Player-to-player SHOW: send full item data (receiver doesn't have sender's inventory)
local function SendShowMessage(targetName, item)
    if not targetName or not item then return false end

    -- Format v0.1.1: SHOW^targetName^objectGuid^customText^customNumber
    local message = string.format("SHOW^%s^%s^%s^%s",
        targetName,
        item.guid or "",
        item.customText or "",
        tostring(item.customNumber or 0))

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendGiveAcceptMessage(itemName)
    local message = CreateGiveAcceptMessage(itemName)
    if not message then return false end

    local distribution = GetDistribution()
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendGiveRejectMessage(itemName)
    local message = CreateGiveRejectMessage(itemName)
    if not message then return false end

    local distribution = GetDistribution()
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendTradeAcceptMessage(targetName, itemName)
    local message = CreateTradeAcceptMessage(targetName, itemName)
    if not message then return false end

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendTradeRejectMessage(targetName, itemName)
    local message = CreateTradeRejectMessage(targetName, itemName)
    if not message then return false end

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

local function SendShowRejectMessage(targetName, itemName)
    local message = CreateShowRejectMessage(targetName, itemName)
    if not message then return false end

    local distribution = GetDistribution(targetName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- ============================================================================
-- SendCinematicTriggerMessage - Player triggers a cinematic (Player → GM)
-- ============================================================================
-- @param cinematicGuid: GUID of the cinematic in the library
-- @param customText: Instance-specific custom text from the item
-- @param additionalText: Instance-specific additional text from the item
-- @param customNumber: Instance-specific number from the item
-- @returns: success boolean
--
-- FORMAT: "CINEMATIC_TRIGGER^cinematicGuid^customText^additionalText^customNumber"
-- ============================================================================
local function SendCinematicTriggerMessage(cinematicGuid, customText, additionalText, customNumber)
    if not cinematicGuid or cinematicGuid == "" then
        return false
    end

    local message = MESSAGE_TYPES.CINEMATIC_TRIGGER .. MESSAGE_DELIMITER ..
                   cinematicGuid .. MESSAGE_DELIMITER ..
                   (customText or "") .. MESSAGE_DELIMITER ..
                   (additionalText or "") .. MESSAGE_DELIMITER ..
                   tostring(customNumber or 0)

    local distribution = GetDistribution()
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- ============================================================================
-- SendCinematicBroadcastMessage - GM broadcasts cinematic to group (GM → all)
-- ============================================================================
-- @param cinematicGuid: GUID for player-side library lookup
-- @param senderName: Player(s) who triggered the cinematic (comma-separated for merges)
-- @param customText: Instance-specific custom text
-- @param additionalText: Instance-specific additional text
-- @param customNumber: Instance-specific number
-- @param scriptValues: Array of pre-resolved script values
-- @returns: success boolean
--
-- FORMAT: "CINEMATIC^cinematicGuid^senderName^customText^additionalText^customNumber^[sv1]^..."
-- speakerName is looked up from cinematicLibrary on the player side (not sent on wire)
-- Fields: parts[2]=cinematicGuid, parts[3]=senderName, parts[4]=customText,
--         parts[5]=additionalText, parts[6]=customNumber, parts[7+]=scriptValues
-- ============================================================================
local function SendCinematicBroadcastMessage(cinematicGuid, senderName, customText, additionalText, customNumber, scriptValues)
    if not cinematicGuid or not senderName then
        return false
    end

    local message = MESSAGE_TYPES.CINEMATIC .. MESSAGE_DELIMITER ..
                   cinematicGuid .. MESSAGE_DELIMITER ..
                   senderName .. MESSAGE_DELIMITER ..
                   (customText or "") .. MESSAGE_DELIMITER ..
                   (additionalText or "") .. MESSAGE_DELIMITER ..
                   tostring(customNumber or 0)

    -- Append script values as additional fields (parts[7+])
    if scriptValues then
        for _, value in ipairs(scriptValues) do
            message = message .. MESSAGE_DELIMITER .. (value or "")
        end
    end

    local distribution = GetDistribution()
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- ============================================================================
-- SendMergeTriggerMessage - Notify GM that a merge cinematic was triggered
-- ============================================================================
-- @param mergeGroupId: Merge group identifier
-- @param objectGuid: GUID of the triggering object
-- @param customNumber: Instance-specific number from the item
--
-- FORMAT: "MERGE_TRIGGER^mergeGroupId^objectGuid^customNumber"
-- NOTE: senderName comes from arg4 on the GM side
-- ============================================================================
local function SendMergeTriggerMessage(mergeGroupId, objectGuid, customNumber)
    if not mergeGroupId or mergeGroupId == "" then
        return false
    end

    local message = MESSAGE_TYPES.MERGE_TRIGGER .. MESSAGE_DELIMITER ..
                   mergeGroupId .. MESSAGE_DELIMITER ..
                   (objectGuid or "") .. MESSAGE_DELIMITER ..
                   tostring(customNumber or 0)

    local distribution = GetDistribution()
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- ============================================================================
-- SendScriptRequestMessage - GM requests script execution on player
-- ============================================================================
-- @param playerName: Target player
-- @param scriptName: Name of script in scriptLibrary
-- @param requestId: Unique ID to match response
-- @returns: success boolean
--
-- FORMAT: "SCRIPT_REQUEST^playerName^scriptName^requestId"
-- ============================================================================
local function SendScriptRequestMessage(playerName, scriptName, requestId)
    if not playerName or not scriptName or not requestId then
        return false
    end

    local message = MESSAGE_TYPES.SCRIPT_REQUEST .. MESSAGE_DELIMITER ..
                   playerName .. MESSAGE_DELIMITER ..
                   scriptName .. MESSAGE_DELIMITER ..
                   requestId

    local distribution = GetDistribution(playerName)
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- ============================================================================
-- SendScriptResultMessage - Player sends script result back to GM
-- ============================================================================
-- @param requestId: Request ID from the original request
-- @param result: Script execution result string
-- @returns: success boolean
--
-- FORMAT: Base64("SCRIPT_RESULT^requestId^result")
-- ============================================================================
local function SendScriptResultMessage(requestId, result)
    if not requestId then
        return false
    end

    local rawData = MESSAGE_TYPES.SCRIPT_RESULT .. MESSAGE_DELIMITER ..
                   requestId .. MESSAGE_DELIMITER ..
                   (result or "")
    local message = encoding.Base64Encode(rawData)

    local distribution = GetDistribution()
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- ============================================================================
-- SendStatusLiteMessage - Player sends lightweight status update to GM
-- ============================================================================
-- FORMAT: "STATUS_LITE^zone^coordX^coordY^checksum"
-- NOTE: Called player-side only; reads EreaRpPlayerDB.syncState.checksum
-- ============================================================================
local function SendStatusLiteMessage()
    local zone = GetRealZoneText() or ""
    local cx, cy = GetPlayerMapPosition("player")
    local coordX = string.format("%.1f", (cx or 0) * 100)
    local coordY = string.format("%.1f", (cy or 0) * 100)

    local checksum = ""
    if EreaRpPlayerDB and EreaRpPlayerDB.syncState then
        checksum = EreaRpPlayerDB.syncState.checksum or ""
    end

    local message = MESSAGE_TYPES.STATUS_LITE .. MESSAGE_DELIMITER ..
                   zone .. MESSAGE_DELIMITER ..
                   coordX .. MESSAGE_DELIMITER ..
                   coordY .. MESSAGE_DELIMITER ..
                   checksum

    local distribution = GetDistribution()
    SendAddonMessage(ADDON_PREFIX, message, distribution)
    return true
end

-- ============================================================================
-- NPC PUPPET SEND FUNCTIONS (GM -> NPC)
-- ============================================================================

-- ============================================================================
-- SendNpcCmdMessage - GM sends a single say/yell/emote to an NPC
-- ============================================================================
-- @param targetName: NPC character name
-- @param cmdType:   "say" | "yell" | "emote"
-- @param text:      The line to deliver
-- @returns: success boolean
--
-- FORMAT: "NPC_CMD^targetName^cmdType^text"
-- NOTE: Plain (not Base64) — text must not contain ^ (single chat line, safe)
-- ============================================================================
local function SendNpcCmdMessage(targetName, cmdType, text)
    if not targetName or not cmdType or not text then return false end

    local message = MESSAGE_TYPES.NPC_CMD .. MESSAGE_DELIMITER ..
                    targetName .. MESSAGE_DELIMITER ..
                    cmdType .. MESSAGE_DELIMITER ..
                    text

    SendAddonMessage(ADDON_PREFIX, message, GetDistribution(targetName))
    return true
end

-- ============================================================================
-- SendNpcScriptMessage - GM sends a multi-line script to an NPC
-- ============================================================================
-- @param targetName: NPC character name
-- @param scriptBody: Full script text (may contain ^ so whole message is Base64)
-- @returns: success boolean
--
-- FORMAT: Base64("NPC_SCRIPT^targetName^scriptBody")
-- ============================================================================
local function SendNpcScriptMessage(targetName, scriptBody)
    if not targetName then return false end

    local raw = MESSAGE_TYPES.NPC_SCRIPT .. MESSAGE_DELIMITER ..
                targetName .. MESSAGE_DELIMITER ..
                (scriptBody or "")
    local message = encoding.Base64Encode(raw)

    SendAddonMessage(ADDON_PREFIX, message, GetDistribution(targetName))
    return true
end

-- ============================================================================
-- SendNpcStopMessage - GM aborts the currently running NPC script
-- ============================================================================
-- @param targetName: NPC character name
-- @returns: success boolean
--
-- FORMAT: "NPC_STOP^targetName"
-- ============================================================================
local function SendNpcStopMessage(targetName)
    if not targetName then return false end

    local message = MESSAGE_TYPES.NPC_STOP .. MESSAGE_DELIMITER .. targetName

    SendAddonMessage(ADDON_PREFIX, message, GetDistribution(targetName))
    return true
end

-- ============================================================================
-- SendNpcChatRelayMessage - NPC relays nearby chat back to GM
-- ============================================================================
-- @param chatType: "SAY", "YELL", or "EMOTE"
-- @param senderName: Name of the player/NPC who spoke
-- @param messageText: The chat message content
-- @returns: success boolean
--
-- FORMAT: "NPC_CHAT_RELAY^chatType^senderName^messageText"
-- ============================================================================
local function SendNpcChatRelayMessage(chatType, senderName, messageText)
    if not chatType or not senderName then return false end

    local message = MESSAGE_TYPES.NPC_CHAT_RELAY .. MESSAGE_DELIMITER ..
                    chatType .. MESSAGE_DELIMITER ..
                    senderName .. MESSAGE_DELIMITER ..
                    (messageText or "")

    SendAddonMessage(ADDON_PREFIX, message, GetDistribution())
    return true
end

-- ============================================================================
-- ACTION-TRIGGERED NPC/GM SEND FUNCTIONS (Player -> GM -> NPC)
-- ============================================================================

-- ============================================================================
-- SendNpcActionTriggerMessage - Player requests tag-based NPC chat via GM
-- ============================================================================
-- @param tag:     NPC tag to match (e.g. "innkeeper", "guard")
-- @param cmdType: "say" | "yell" | "emote"
-- @param text:    The line to deliver (placeholders already resolved)
-- @returns: success boolean
--
-- FORMAT: "NPC_ACTION_TRIGGER^tag^cmdType^text"
-- ============================================================================
local function SendNpcActionTriggerMessage(tag, cmdType, text)
    if not tag or not cmdType or not text then return false end

    local message = MESSAGE_TYPES.NPC_ACTION_TRIGGER .. MESSAGE_DELIMITER ..
                    tag .. MESSAGE_DELIMITER ..
                    cmdType .. MESSAGE_DELIMITER ..
                    text

    SendAddonMessage(ADDON_PREFIX, message, GetDistribution())
    return true
end

-- ============================================================================
-- SendWhisperTriggerMessage - Player requests GM to whisper them
-- ============================================================================
-- @param text: The whisper text (placeholders already resolved)
-- @returns: success boolean
--
-- FORMAT: Base64("WHISPER_TRIGGER^text")
-- NOTE: Base64 encoded because text may contain ^
-- ============================================================================
local function SendWhisperTriggerMessage(text)
    if not text then return false end

    local raw = MESSAGE_TYPES.WHISPER_TRIGGER .. MESSAGE_DELIMITER .. text
    local message = encoding.Base64Encode(raw)

    SendAddonMessage(ADDON_PREFIX, message, GetDistribution())
    return true
end

-- ============================================================================
-- SendNpcCmdRangedMessage - GM sends a range-checked cmd to an NPC
-- ============================================================================
-- @param targetName: NPC character name
-- @param cmdType:    "say" | "yell" | "emote"
-- @param text:       The line to deliver
-- @param playerName: Triggering player (NPC checks range before executing)
-- @returns: success boolean
--
-- FORMAT: "NPC_CMD_RANGED^targetName^cmdType^text^playerName"
-- ============================================================================
local function SendNpcCmdRangedMessage(targetName, cmdType, text, playerName)
    if not targetName or not cmdType or not text or not playerName then return false end

    local message = MESSAGE_TYPES.NPC_CMD_RANGED .. MESSAGE_DELIMITER ..
                    targetName .. MESSAGE_DELIMITER ..
                    cmdType .. MESSAGE_DELIMITER ..
                    text .. MESSAGE_DELIMITER ..
                    playerName

    SendAddonMessage(ADDON_PREFIX, message, GetDistribution(targetName))
    return true
end

-- ============================================================================
-- EXPORT FUNCTIONS
-- ============================================================================

-- Lua 5.0: 32 upvalue limit per closure — build export table incrementally
local _messagingExport = {}

-- Constants + distribution
_messagingExport.ADDON_PREFIX = ADDON_PREFIX
_messagingExport.MESSAGE_DELIMITER = MESSAGE_DELIMITER
_messagingExport.MESSAGE_TYPES = MESSAGE_TYPES
_messagingExport.GetDistribution = GetDistribution

-- SEND functions (complete flow: create + send)
_messagingExport.SendGiveMessage = SendGiveMessage
_messagingExport.SendTradeMessage = SendTradeMessage
_messagingExport.SendShowMessage = SendShowMessage
_messagingExport.SendGiveAcceptMessage = SendGiveAcceptMessage
_messagingExport.SendGiveRejectMessage = SendGiveRejectMessage
_messagingExport.SendTradeAcceptMessage = SendTradeAcceptMessage
_messagingExport.SendTradeRejectMessage = SendTradeRejectMessage
_messagingExport.SendShowRejectMessage = SendShowRejectMessage

-- CREATE functions (for advanced use, testing)
_messagingExport.CreateGiveMessage = CreateGiveMessage
_messagingExport.CreateTradeMessage = CreateTradeMessage
_messagingExport.CreateShowMessage = CreateShowMessage

-- Response messages (Player -> GM)
_messagingExport.CreateGiveAcceptMessage = CreateGiveAcceptMessage
_messagingExport.CreateGiveRejectMessage = CreateGiveRejectMessage
_messagingExport.CreateTradeAcceptMessage = CreateTradeAcceptMessage
_messagingExport.CreateTradeRejectMessage = CreateTradeRejectMessage
_messagingExport.CreateShowRejectMessage = CreateShowRejectMessage

-- Cinematic messages
_messagingExport.SendCinematicTriggerMessage = SendCinematicTriggerMessage
_messagingExport.SendCinematicBroadcastMessage = SendCinematicBroadcastMessage
_messagingExport.SendMergeTriggerMessage = SendMergeTriggerMessage

-- Script execution messages
_messagingExport.SendScriptRequestMessage = SendScriptRequestMessage
_messagingExport.SendScriptResultMessage = SendScriptResultMessage

-- Lightweight status update (Player -> GM)
_messagingExport.SendStatusLiteMessage = SendStatusLiteMessage

-- NPC puppet commands (GM -> NPC)
_messagingExport.SendNpcCmdMessage = SendNpcCmdMessage
_messagingExport.SendNpcScriptMessage = SendNpcScriptMessage
_messagingExport.SendNpcStopMessage = SendNpcStopMessage

-- NPC chat relay (NPC -> GM)
_messagingExport.SendNpcChatRelayMessage = SendNpcChatRelayMessage

-- Action-triggered NPC/GM commands (Player -> GM -> NPC)
_messagingExport.SendNpcActionTriggerMessage = SendNpcActionTriggerMessage
_messagingExport.SendWhisperTriggerMessage = SendWhisperTriggerMessage
_messagingExport.SendNpcCmdRangedMessage = SendNpcCmdRangedMessage

-- NOTE: DB sync message creation is in object-database.lua
-- (CreateSyncMessageChunks, ReassembleChunkedSync)

-- Parsing
_messagingExport.ParseMessage = ParseMessage
_messagingExport.ParseCaretDelimited = ParseCaretDelimited

function EreaRpLibraries:Messaging()
    return _messagingExport
end
