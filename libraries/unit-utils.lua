-- ============================================================================
-- unit-utils.lua - Unit and Player Utilities
-- ============================================================================
-- PURPOSE: Common utilities for finding and checking player units
--
-- RESPONSIBILITIES:
--   - Find unit ID by player name (raid/party/self)
--   - Check if player is in range (various distances)
--
-- PATTERN: Library (stateless factory, returned via EreaRpLibraries)
-- ============================================================================

-- ============================================================================
-- FindUnitId - Find unit ID for a player name
-- ============================================================================
-- Iterates raid/party members to find the unit ID for PlayerModel
-- @param playerName: Name of the player to find
-- @returns: unitId string or nil
-- ============================================================================
local function FindUnitId(playerName)
    if not playerName then return nil end

    -- Check self
    if UnitName("player") == playerName then
        return "player"
    end

    -- Check raid members
    local raidCount = GetNumRaidMembers()
    if raidCount > 0 then
        for i = 1, raidCount do
            local name = UnitName("raid" .. i)
            if name == playerName then
                return "raid" .. i
            end
        end
    end

    -- Check party members
    local partyCount = GetNumPartyMembers()
    if partyCount > 0 then
        for i = 1, partyCount do
            local name = UnitName("party" .. i)
            if name == playerName then
                return "party" .. i
            end
        end
    end

    return nil
end

-- ============================================================================
-- CheckPlayerInRangeInspect - Check if player is in inspect range (~28 yards)
-- ============================================================================
-- @param playerName: Name of the player to check
-- @returns: boolean - true if in range, false otherwise
-- ============================================================================
local function CheckPlayerInRangeInspect(playerName)
    local unitId = FindUnitId(playerName)
    if not unitId then return false end
    return CheckInteractDistance(unitId, 1)  -- Inspect distance
end

-- ============================================================================
-- CheckPlayerInRangeTrade - Check if player is in trade range (~11 yards)
-- ============================================================================
-- @param playerName: Name of the player to check
-- @returns: boolean - true if in range, false otherwise
-- ============================================================================
local function CheckPlayerInRangeTrade(playerName)
    local unitId = FindUnitId(playerName)
    if not unitId then return false end
    return CheckInteractDistance(unitId, 2)  -- Trade distance
end

-- ============================================================================
-- CheckPlayerInRangeDuel - Check if player is in duel range (~10 yards)
-- ============================================================================
-- @param playerName: Name of the player to check
-- @returns: boolean - true if in range, false otherwise
-- ============================================================================
local function CheckPlayerInRangeDuel(playerName)
    local unitId = FindUnitId(playerName)
    if not unitId then return false end
    return CheckInteractDistance(unitId, 3)  -- Duel distance
end

-- ============================================================================
-- CheckPlayerInRangeFollow - Check if player is in follow range (~28 yards)
-- ============================================================================
-- @param playerName: Name of the player to check
-- @returns: boolean - true if in range, false otherwise
-- ============================================================================
local function CheckPlayerInRangeFollow(playerName)
    local unitId = FindUnitId(playerName)
    if not unitId then return false end
    return CheckInteractDistance(unitId, 4)  -- Follow distance
end

-- ============================================================================
-- EXPORT
-- ============================================================================

function EreaRpLibraries:UnitUtils()
    return {
        FindUnitId = FindUnitId,
        CheckPlayerInRangeInspect = CheckPlayerInRangeInspect,
        CheckPlayerInRangeTrade = CheckPlayerInRangeTrade,
        CheckPlayerInRangeDuel = CheckPlayerInRangeDuel,
        CheckPlayerInRangeFollow = CheckPlayerInRangeFollow
    }
end
