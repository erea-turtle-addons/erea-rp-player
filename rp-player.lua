-- ============================================================================
-- RPPlayer.lua - Player Addon for RP Item Inventory
-- ============================================================================
-- PURPOSE: Provides a personal RP inventory system for players
--          Receives items from GMs, trades with other players, shows items
--
-- FEATURES:
--   - 16-slot bag for RP items (separate from regular inventory)
--   - Receive items from GMs (GIVE messages) with accept/decline popup
--   - Trade items to other players (TRADE messages) with confirmation
--   - Show items to others for preview (SHOW messages) without transfer
--   - Drag-drop reorganization (swap slots)
--   - Drag-drop to player portraits (quick trade/show)
--   - Right-click context menu (Read/Show/Give/Delete)
--   - Range detection (only show nearby raid/party members)
--   - Position persistence (remembers window locations)
--   - Debug logging system
--
-- ARCHITECTURE:
--   - Monolithic file (not modular like RPMaster)
--   - Creates 2 main windows: Bag frame + Read frame
--   - Listens for addon messages via CHAT_MSG_ADDON event
--   - Uses Base64 encoding for safe message transmission
--
-- COMMUNICATION:
--   - Receives: GIVE, TRADE, SHOW (from GMs or players)
--   - Sends: GIVE_ACCEPT, GIVE_REJECT, TRADE_ACCEPT, TRADE_REJECT, SHOW_REJECT
--   - Distribution: RAID, PARTY, or WHISPER (auto-selected)
--   - Delimiter: ^ (caret) instead of | (pipe) to avoid WoW escape sequence conflicts
--
-- DATA PERSISTENCE:
--   - EreaRpPlayerDB (SavedVariablesPerCharacter) stores inventory per character
--   - EreaRpPlayerDebugLog (SavedVariablesPerCharacter) stores debug logs
--
-- LUA 5.0 NOTES:
--   - Use table.getn(t) instead of #t
--   - Use string.gfind instead of string.gmatch
--   - Use math.mod instead of % for modulo
--   - Global event variables: event, arg1, arg2, arg3, etc.
-- ============================================================================

-- ============================================================================
-- IMPORTS - Business logic from turtle-rp-common
-- ============================================================================
local objectDatabase = EreaRpLibraries:ObjectDatabase()
local rpBusiness = EreaRpLibraries:RPBusiness()
local inventory = EreaRpLibraries:Inventory()
local encoding = EreaRpLibraries:Encoding()
local messaging = EreaRpLibraries:Messaging()
local rpActions = EreaRpLibraries:RPActions()
local Log = EreaRpLibraries:Logging("RPPlayer")

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local ADDON_NAME = "RPPlayer"
local ADDON_PREFIX = messaging.ADDON_PREFIX  -- Use constant from messaging module
-- Version info loaded from version.lua (loaded first in .toc)
-- Show version tag unless it's the default "0.0.0", then show build time
local ADDON_VERSION = (RP_VERSION_TAG and RP_VERSION_TAG ~= "0.0.0") and RP_VERSION_TAG or (RP_BUILD_TIME or "unknown")
local MAX_SLOTS = inventory.MAX_INVENTORY_SLOTS  -- Use constant from inventory module

-- NOTE: RegisterAddonMessagePrefix() doesn't exist in WoW 1.12
-- Addon messages work without explicit registration in Vanilla WoW

-- ============================================================================
-- GLOBAL PENDING STATE VARIABLES
-- ============================================================================
-- These MUST be global (not local) because WoW's StaticPopup system can't
-- access local variables from callback functions (Lua 5.0 limitation)
--
-- PATTERN: Store pending operation data globally, clear after completion
-- SIMILAR TO: Static/singleton pattern for temporary state
-- ============================================================================

-- GIVE request state (from GM)
EreaRpPlayer_PendingGiveItem = nil      -- Item instance being offered (v0.2.1: instance data only)
EreaRpPlayer_PendingGiveObjectDef = nil -- Object definition (for display during popup)
EreaRpPlayer_PendingGiveSender = nil    -- GM who sent it
EreaRpPlayer_PendingGiveMessage = nil   -- Custom message from GM

-- TRADE request state (from another player)
EreaRpPlayer_PendingTradeItem = nil     -- Item instance being offered (v0.2.1: instance data only)
EreaRpPlayer_PendingTradeObjectDef = nil-- Object definition (for display during popup)
EreaRpPlayer_PendingTradeSender = nil   -- Player who sent it

-- Outgoing TRADE state (waiting for recipient to accept)
EreaRpPlayer_PendingOutgoingTrade = nil -- Item we're giving away

-- Chunked database sync state (for receiving multi-part DB_SYNC messages)
EreaRpPlayer_ChunkedSyncs = EreaRpPlayer_ChunkedSyncs or {}  -- {messageId -> {metadata, chunks, totalChunks}}

-- NOTE: Two-part message assembly removed - new GUID-based protocol doesn't need it

-- ============================================================================
-- DEBUG LOGGING SYSTEM - Moved to turtle-rp-common/logging.lua
-- ============================================================================
-- EreaRpPlayerDebugLog is initialized by EreaRpLibraries:Logging("RPPlayer")
-- Log function is imported above: local Log = EreaRpLibraries:Logging("RPPlayer")

-- ============================================================================
-- SAVED VARIABLES INITIALIZATION (Per-Character Database)
-- ============================================================================
-- EreaRpPlayerDB is a SavedVariablesPerCharacter (persisted to disk per character)
-- Declared in .toc file: ## SavedVariablesPerCharacter: EreaRpPlayerDB
--
-- PATTERN: EreaRpPlayerDB = EreaRpPlayerDB or { default structure }
--   - If EreaRpPlayerDB exists (loaded from SavedVariables), keep it
--   - Otherwise initialize with default structure (first time use)
--
-- STRUCTURE:
--   - inventory: Array of item objects
--   - bagFramePos: Window position [point, relativePoint, x, y]
--   - readFramePos: Window position [point, relativePoint, x, y]
--   - syncedDatabaseId: ID of currently synced Master database (e.g., "1234567890-5432")
--   - syncedDatabaseName: Name of currently synced database (e.g., "Dragon Campaign")
--   - syncedDatabaseVersion: Version timestamp of synced database (for tracking updates)
--   - databases: Array of available databases from different Masters
--
-- DATABASE SYNC DESIGN:
--   - Player can receive items from multiple RPMasters (different database IDs)
--   - Only one database is "active" at a time (shown in UI)
--   - Future: May track multiple databases separately per Master
--
-- DEFAULT ITEM:
--   - First-time users get a welcome letter with user instructions
--   - guid = "system-welcome-0" prevents duplicates
--
-- SIMILAR TO: localStorage in JavaScript, SharedPreferences in Android
-- ============================================================================
Log("RPPlayer.lua file loading...")
EreaRpPlayerDB = EreaRpPlayerDB or {
    inventory = {
        {
            id = 0,  -- System item (not from GM)
            name = "Welcome to RP Player",
            icon = "Interface\\Icons\\INV_Misc_Note_01",
            tooltip = "Quick start guide",
            content = "RP PLAYER GUIDE\n\n" ..
                "Left-click items to read. Right-click for options.\n\n" ..
                "Drag items to player portraits to give or show.\n\n" ..
                "Use /rpplayer to open bag.",
            guid = "system-welcome-0"
        }
    },
    bagFramePos = nil,
    readFramePos = nil,
    -- NEW: Stores entire GM database locally for GUID lookup
    syncedDatabase = nil,         -- Full database {items: [...], metadata: {...}}
    syncState = {                 -- Sync status tracking
        databaseId = nil,
        databaseName = nil,
        version = nil,
        checksum = nil,
        lastSyncTime = nil
    }
}
Log("EreaRpPlayerDB initialized, inventory count: " .. table.getn(EreaRpPlayerDB.inventory))

-- ============================================================================
-- ENSURE DATABASE FIELDS EXIST (for existing saved variables)
-- ============================================================================
-- Migrate old SavedVariables structure to new GUID-based protocol structure
-- ============================================================================
if not EreaRpPlayerDB.syncedDatabase then
    EreaRpPlayerDB.syncedDatabase = nil
    Log("Added syncedDatabase field to EreaRpPlayerDB")
end
if not EreaRpPlayerDB.syncState then
    EreaRpPlayerDB.syncState = {
        databaseId = nil,
        databaseName = nil,
        version = nil,
        checksum = nil,
        lastSyncTime = nil
    }
    Log("Added syncState field to EreaRpPlayerDB")
end

-- Backward compatibility: migrate old fields to new structure if they exist
if EreaRpPlayerDB.syncedDatabaseId or EreaRpPlayerDB.syncedDatabaseName or EreaRpPlayerDB.syncedDatabaseVersion then
    if not EreaRpPlayerDB.syncState.databaseId then
        EreaRpPlayerDB.syncState.databaseId = EreaRpPlayerDB.syncedDatabaseId
        EreaRpPlayerDB.syncState.databaseName = EreaRpPlayerDB.syncedDatabaseName
        EreaRpPlayerDB.syncState.version = EreaRpPlayerDB.syncedDatabaseVersion
        Log("Migrated old database sync fields to new syncState structure")
    end
    -- Clean up old fields
    EreaRpPlayerDB.syncedDatabaseId = nil
    EreaRpPlayerDB.syncedDatabaseName = nil
    EreaRpPlayerDB.syncedDatabaseVersion = nil
    EreaRpPlayerDB.databases = nil
end

-- ============================================================================
-- PUBLIC API - Thin wrappers to service prototypes
-- ============================================================================
-- These global functions exist for:
--   - Backward compatibility with existing code
--   - StaticPopup callbacks (can't access prototype methods)
--   - Event handlers and XML scripts
-- ============================================================================

function EreaRpPlayer_ShowItem(item, targetName, silent)
    EreaRpPlayerInventory:ShowItem(item, targetName, silent)
end

function EreaRpPlayer_DeleteItem(item)
    EreaRpPlayerInventory:DeleteItem(item)
end

function EreaRpPlayer_TradeItem(item, targetName)
    EreaRpPlayerInventory:TradeItem(item, targetName)
end

function EreaRpPlayer_ReadItem(item, shownBy)
    EreaRpPlayerInventory:ReadItem(item, shownBy)
end

function EreaRpPlayer_ExecuteAction(item, action)
    EreaRpPlayerActions:ExecuteAction(item, action)
end

function EreaRpPlayer_ShowContextMenu(item, anchorFrame)
    EreaRpPlayerInventory:ShowContextMenu(item, anchorFrame)
end

function EreaRpPlayer_RefreshBag()
    EreaRpPlayerInventory:RefreshBag()
end

-- Helper to create item slots (called during initialization)
function CreateItemSlots()
    EreaRpPlayerInventory:CreateItemSlots()
end

-- Wrappers for EreaRpPlayerEventHandler (for slash commands and compatibility)
function EreaRpPlayer_ShowLog()
    EreaRpPlayerEventHandler:ShowLog()
end

function EreaRpPlayer_CleanupDuplicateSlots()
    EreaRpPlayerEventHandler:CleanupDuplicateSlots()
end

function EreaRpPlayer_ResetPositions()
    EreaRpPlayerEventHandler:ResetPositions()
end

-- ============================================================================
-- UI FRAME REFERENCES (frames created in XML files)
-- ============================================================================
-- EreaRpPlayerBagFrame is defined in components/bag-frame.xml
-- EreaRpPlayerReadFrame is defined in components/read-frame.xml
-- Controllers are in controllers/bag-frame.lua and controllers/read-frame.lua
--
-- Initialize bag frame (title, database label, dragging, position)
EreaRpPlayerBagFrame:Initialize()

-- Get slots container (XML-defined)
local slotsContainer = EreaRpPlayerBagFrameSlotsContainer


-- ============================================================================
-- ITEM SLOTS - Created dynamically by libraries/item-slots.lua
-- ============================================================================
CreateItemSlots()
-- Initialize read frame (dragging, position)
EreaRpPlayerReadFrame:Initialize()


-- ============================================================================
-- Drag & Drop System moved to libraries/drag-drop.lua
-- ============================================================================
-- StartDrag() and StopDrag() functions are now in libraries/drag-drop.lua

-- Pending drag-to-player action (global state for dialogs)
EreaRpPlayer_PendingDragItem = nil
EreaRpPlayer_PendingDragTarget = nil

-- Global variables to store pending items (WoW 1.12 compatibility)
EreaRpPlayer_PendingDeleteItem = nil
EreaRpPlayer_PendingShowItem = nil
EreaRpPlayer_PendingShowSender = nil

-- ============================================================================
-- StaticPopup Dialogs moved to libraries/dialogs.lua
-- ============================================================================
-- All dialog definitions (GIVE, TRADE, SHOW, DELETE, DRAG_TO_PLAYER, etc.)
-- are now in libraries/dialogs.lua for better organization

-- ============================================================================
-- EreaRpPlayer_RefreshBag() - Rebuild entire bag UI from inventory data
-- ============================================================================
-- @returns: void
--
-- CALLED:
--   - After adding/removing items
--   - After slot reorganization (drag-drop)
--   - On PLAYER_LOGIN (initial display)
--   - When opening bag via /rpplayer command
--
-- PROCESS:
--   1. Auto-assign slots to items that don't have one
--   2. Clear all slot visuals and event handlers
--   3. Rebuild each slot with current item
--   4. Attach event handlers (tooltip, clicks, drag-drop)
--
-- SLOT ASSIGNMENT:
--   - Items have optional 'slot' field (1-16)
--   - Items without slot get auto-assigned to first available
--   - Allows items to remember position after reorganization
--
-- PATTERN: Similar to React's render() - rebuilds entire UI from state
-- ============================================================================

-- ============================================================================
-- EreaRpPlayer_RefreshBag moved to libraries/item-slots.lua
-- ============================================================================

-- ============================================================================
-- EVENT HANDLER moved to libraries/event-handler.lua
-- ============================================================================
