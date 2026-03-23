-- ============================================================================
-- logging.lua - Shared Logging System
-- ============================================================================
-- PURPOSE: Provides centralized logging functionality for all addons
--
-- FEATURES:
--   - Timestamped log entries
--   - Circular buffer (max 500 entries to prevent SavedVariables bloat)
--   - Addon-specific prefixes (RPMaster vs RPPlayer)
--   - Automatically references correct SavedVariable per addon
--
-- USAGE:
--   local Log = EreaRpLibraries:Logging("RPMaster")
--   Log("Something happened")
--   -- Output: RPMaster: Something happened
--   -- Stored in: RPMasterDebugLog
--
-- PATTERN: Factory method in EreaRpLibraries namespace
-- ============================================================================

-- ============================================================================
-- EreaRpLibraries:Logging - Create addon-specific logger
-- ============================================================================
-- @param addonName: String - Addon name ("RPMaster" or "RPPlayer")
-- @returns: Function - Log function configured for this addon
--
-- BEHAVIOR:
--   - Returns a Log(message) function
--   - Automatically uses correct SavedVariable (RPMasterDebugLog or RPPlayerDebugLog)
--   - Log entries are prefixed with addon name
--   - Keeps circular buffer of max 500 entries
--
-- EXAMPLE:
--   local Log = EreaRpLibraries:Logging("RPMaster")
--   Log("Player connected")
--   -- Adds to RPMasterDebugLog: "RPMaster: Player connected"
-- ============================================================================
function EreaRpLibraries:Logging(addonName)
    -- Validate parameter
    if not addonName or type(addonName) ~= "string" then
        error("EreaRpLibraries:Logging: addonName must be a string")
    end

    -- Construct SavedVariable name dynamically (e.g., "RPMasterDebugLog")
    local logVarName = addonName .. "DebugLog"

    -- Initialize SavedVariable using _G table (Lua's global environment)
    -- _G["RPMasterDebugLog"] accesses the global RPMasterDebugLog variable
    _G[logVarName] = _G[logVarName] or {}

    -- Return configured Log function
    -- CRITICAL: Access global directly each time via _G, don't cache reference!
    -- SavedVariables may be replaced after PLAYER_LOGIN event
    return function(message)
        -- WoW 1.12: Simple logging without timestamp (time() may not be reliable)
        local logEntry = string.format("%s: %s", addonName, tostring(message))

        -- Access global directly via _G table to handle SavedVariables reloading
        _G[logVarName] = _G[logVarName] or {}
        table.insert(_G[logVarName], logEntry)

        -- Maintain circular buffer (max 500 entries)
        if table.getn(_G[logVarName]) > 500 then
            table.remove(_G[logVarName], 1)
        end
    end
end
