-- ============================================================================
-- rp-business.lua - Business Logic Layer for Turtle RP Addons
-- ============================================================================
-- PURPOSE: Centralized business logic shared between rp-master and rp-player
--
-- ARCHITECTURE:
--   This file contains business logic EXCEPT messaging (see messaging.lua):
--   - GUID lookup
--   - Database synchronization helpers
--   - Item validation
--
-- SEPARATION OF CONCERNS:
--   Business Logic (this file) vs GUI Layer (ItemLibrary.lua, RPPlayer.lua)
--   - Business logic: Pure functions, data manipulation, validation
--   - GUI layer: Frames, event handlers, user interaction, chat messages
--   - Messaging: Message protocol, encoding (see messaging.lua)
--
-- USAGE:
--   local rpBusiness = RequireRPBusiness()
--   local item = rpBusiness.FindItemByGuid(database, guid)
-- ============================================================================

-- ============================================================================
-- GUID LOOKUP
-- ============================================================================

-- ============================================================================
-- FindItemByGuid() - Find item in database by GUID
-- ============================================================================
-- @param database: Database table {items: [...], metadata: {...}}
-- @param guid: Item GUID to find
-- @returns: Item or nil
--
-- PERFORMANCE: O(n) linear search
-- OPTIMIZATION (future): Build GUID index for O(1) lookup
-- ============================================================================
local function FindItemByGuid(database, guid)
    if not database or not database.items or not guid then
        return nil
    end

    -- Linear search through items array
    for _, item in ipairs(database.items) do
        if item.guid == guid then
            return item
        end
    end

    return nil
end

-- ============================================================================
-- DATABASE SYNCHRONIZATION HELPERS
-- ============================================================================

-- ============================================================================
-- GetSyncStatus() - Compare player's sync state with GM's database
-- ============================================================================
-- @param playerSyncState: Player's current sync state {databaseId, checksum, ...}
-- @param gmDatabaseMetadata: GM's database metadata {id, checksum, ...}
-- @returns: "synced", "out_of_sync", or "not_synced"
-- ============================================================================
local function GetSyncStatus(playerSyncState, gmDatabaseMetadata)
    if not playerSyncState or not gmDatabaseMetadata then
        return "not_synced"
    end

    -- Compare checksums (most reliable)
    if playerSyncState.checksum and gmDatabaseMetadata.checksum then
        if playerSyncState.checksum == gmDatabaseMetadata.checksum then
            return "synced"
        else
            return "out_of_sync"
        end
    end

    -- Fallback: Compare database IDs
    if playerSyncState.databaseId == gmDatabaseMetadata.id then
        return "synced"
    end

    return "not_synced"
end

-- ============================================================================
-- NeedsDatabaseSync() - Check if player needs to sync with GM's database
-- ============================================================================
-- @param playerSyncState: Player's current sync state
-- @param gmDatabaseMetadata: GM's database metadata
-- @returns: needsSync (boolean), reason (string)
-- ============================================================================
local function NeedsDatabaseSync(playerSyncState, gmDatabaseMetadata)
    local status = GetSyncStatus(playerSyncState, gmDatabaseMetadata)

    if status == "out_of_sync" then
        return true, "Database version mismatch"
    elseif status == "not_synced" then
        return true, "No database synced"
    end

    return false, "Up to date"
end

-- ============================================================================
-- ITEM VALIDATION
-- ============================================================================

-- ============================================================================
-- ValidateItemMetadata() - Validate item metadata
-- ============================================================================
-- @param item: Item table {name, icon, tooltip, ...}
-- @returns: success (boolean), errorMessage (string or nil)
--
-- NOTE: With GUID-based protocol, metadata validation is less critical
--       Messages are tiny (GIVE^PlayerName^GUID^Message)
-- ============================================================================
local function ValidateItemMetadata(item)
    if not item then
        return false, "Item is nil"
    end

    if not item.name or item.name == "" then
        return false, "Item name is required"
    end

    if not item.guid or item.guid == "" then
        return false, "Item GUID is required"
    end

    return true, nil
end

-- ============================================================================
-- MODULE EXPORT
-- ============================================================================
-- Lua 5.0 module pattern: Global function returns table of functions
-- ============================================================================
-- ============================================================================
-- EreaRpLibraries:RPBusiness - Get RP business logic utilities
-- ============================================================================
-- @returns: Table - Business logic utilities
--
-- USAGE:
--   local rpBusiness = EreaRpLibraries:RPBusiness()
--   local item = rpBusiness.FindItemByGuid(database, "guid-123")
-- ============================================================================
function EreaRpLibraries:RPBusiness()
    return {
        -- GUID Lookup
        FindItemByGuid = FindItemByGuid,

        -- Database Sync Helpers
        GetSyncStatus = GetSyncStatus,
        NeedsDatabaseSync = NeedsDatabaseSync,

        -- Item Validation
        ValidateItemMetadata = ValidateItemMetadata
    }
end
