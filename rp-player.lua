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
    databases = { 
        ["system-welcome-db"] = {  
            metadata = { id = "system", name = "RP Player Guide" }, 
            items = {
                [1] = {
                    id = 1,
                    guid = "system-welcome-0",
                    name = "Welcome to RP Player",
                    icon = "Interface\\Icons\\INV_Misc_Note_01",
                    tooltip = "Quick start guide",
                    content = "WELCOME TO RP PLAYER\n\n" ..
                        "This bag holds your roleplay items. " ..
                        "Items are given to you by a Game Master " ..
                        "or other players during RP events.\n\n" ..
                        "— OPENING YOUR BAG —\n" ..
                        "Type /rpplayer to open or close the bag " ..
                        "at any time.\n\n" ..
                        "— READING AN ITEM —\n" ..
                        "Left-click any item to open it and read " ..
                        "its contents. Some items have dynamic " ..
                        "text written into them by other players.\n\n" ..
                        "— USING AN ITEM —\n" ..
                        "When you open an item, action buttons " ..
                        "may appear at the bottom. Actions vary " ..
                        "by item: consume a charge, write text " ..
                        "into it, trigger a scene, or destroy it. " ..
                        "Some actions require another player " ..
                        "to act at the same time.\n\n" ..
                        "— GIVING AN ITEM —\n" ..
                        "Right-click an item for options including " ..
                        "Give and Show. Giving transfers the item " ..
                        "to another player's bag. Showing shares " ..
                        "a read-only view without transferring.\n\n" ..
                        "— CHARGES —\n" ..
                        "Some items have a limited number of uses " ..
                        "shown as a number on the item icon. " ..
                        "When charges reach zero the item " ..
                        "is automatically removed.\n\n" ..
                        "— STORY ARCS & GMs —\n" ..
                        "The dropdown at the top of your bag " ..
                        "shows which GM database is currently " ..
                        "active. Your GM will select the correct " ..
                        "arc for you — no action needed on " ..
                        "your part.",
                    contentTemplate = "",
                    defaultHandoutText = "",
                    actions = {},
                    initialCounter = 0
                }
            },
            cinematicLibrary = {}, 
            scriptLibrary = {} 
        } 
    },
    inventories = {
        ["system-welcome-db"] = {}
    },
    inventory   = {},
    activeDatabaseId = "system-welcome-db"
}

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

-- ============================================================================
-- MULTI-TENANT DATABASE MIGRATION (v0.3.0+)
-- ============================================================================
-- Moves old single-slot syncedDatabase into per-GM databases table.
-- Runs once: when databases field is absent (nil) in saved variables.
-- ============================================================================
if not EreaRpPlayerDB.databases then
    EreaRpPlayerDB.databases  = {}
    EreaRpPlayerDB.inventories = {}
    if EreaRpPlayerDB.syncedDatabase and EreaRpPlayerDB.syncedDatabase.metadata then
        local id = EreaRpPlayerDB.syncedDatabase.metadata.id
        EreaRpPlayerDB.databases[id]   = EreaRpPlayerDB.syncedDatabase
        EreaRpPlayerDB.inventories[id] = EreaRpPlayerDB.inventory
        EreaRpPlayerDB.activeDatabaseId = id
        Log("Migrated syncedDatabase to databases[" .. tostring(id) .. "]")
    end
    EreaRpPlayerDB.syncedDatabase = nil
end
if not EreaRpPlayerDB.inventories then
    EreaRpPlayerDB.inventories = {}
end
if not EreaRpPlayerDB.inventory then
    EreaRpPlayerDB.inventory = {}
end
if not EreaRpPlayerDB.discoveredCombinations then
    EreaRpPlayerDB.discoveredCombinations = {}
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
end

-- ============================================================================
-- MIGRATION FROM turtle-rp-player (RPPlayerDB → EreaRpPlayerDB)
-- ============================================================================
-- Runs once on first install of erea-rp-player when a turtle-rp-player
-- SavedVariable is detected. Copies inventory items and sync state across.
-- Items are stored as full objects in the old format, which inventory.lua
-- already handles via the 'if instance.name then' branch.
-- ============================================================================
if RPPlayerDB and not EreaRpPlayerDB.migratedFromRPPlayerDB then
    Log("Migrating inventory from RPPlayerDB (turtle-rp-player)...")

    if RPPlayerDB.inventory and table.getn(RPPlayerDB.inventory) > 0 then
        -- Replace the default welcome-only inventory with the real items
        EreaRpPlayerDB.inventory = RPPlayerDB.inventory
        Log("Migrated " .. table.getn(RPPlayerDB.inventory) .. " items from RPPlayerDB")
    end

    if RPPlayerDB.syncState then
        EreaRpPlayerDB.syncState = {
            databaseId   = RPPlayerDB.syncState.databaseId,
            databaseName = RPPlayerDB.syncState.databaseName,
            version      = RPPlayerDB.syncState.version,
            checksum     = RPPlayerDB.syncState.checksum,
            lastSyncTime = RPPlayerDB.syncState.lastSyncTime
        }
        Log("Migrated syncState from RPPlayerDB")
    end

    EreaRpPlayerDB.migratedFromRPPlayerDB = true
    Log("Migration from RPPlayerDB complete")
end

-- ============================================================================
-- SetActiveDatabase - Switch active RP campaign
-- ============================================================================
-- Flushes current inventory back to its slot, loads the requested campaign's
-- inventory, updates syncState for backward compat, and refreshes the bag UI.
-- Called by DB_SYNC_END handler and the bag-frame dropdown.
-- ============================================================================
function EreaRpPlayer_SetActiveDatabase(dbId)
    -- 1. Flush current inventory back to its stored slot
    if EreaRpPlayerDB.activeDatabaseId then
        EreaRpPlayerDB.inventories[EreaRpPlayerDB.activeDatabaseId] = EreaRpPlayerDB.inventory
    end
    -- 2. Load new campaign's inventory
    EreaRpPlayerDB.inventory = EreaRpPlayerDB.inventories[dbId] or {}
    EreaRpPlayerDB.activeDatabaseId = dbId
    -- 3. Keep syncState populated for backward compat (STATUS_REQUEST etc.)
    local meta = EreaRpPlayerDB.databases[dbId].metadata
    EreaRpPlayerDB.syncState = {
        databaseId   = meta.id,
        databaseName = meta.name,
        version      = meta.version,
        checksum     = meta.checksum
    }
    -- 4. Refresh UI
    EreaRpPlayerBagFrame:UpdateDatabaseLabel()
    EreaRpPlayerInventory:RefreshBag()
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

function EreaRpPlayer_ExecuteForge()
    EreaRpPlayerInventory:ExecuteForge()
end

function EreaRpPlayer_CancelForge()
    EreaRpPlayerInventory:ExitForgeMode()
end

function EreaRpPlayer_BroadcastForge()
    EreaRpPlayerInventory:BroadcastForge()
end

-- Helper to create item slots (called during initialization)
-- Now calls the presenter's method instead of the service's
function CreateItemSlots()
    EreaRpPlayerBagFrame:CreateItemSlots()
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
-- FORGE GLOBAL STATE (WoW 1.12 StaticPopup compatibility)
-- ============================================================================
-- Stores pending forge operation across dialog callbacks.
EreaRpPlayer_ForgeOutputGuid      = nil   -- GUID of output item definition
EreaRpPlayer_ForgeIngredientSlots = nil   -- { slot1, slot2 } of the two ingredients
EreaRpPlayer_ForgeCinematicKey    = nil   -- cinematicKey from recipe (may be nil)
EreaRpPlayer_ForgeNotifyGm        = false -- whether to notify GM after forging

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
