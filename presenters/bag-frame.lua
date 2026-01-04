-- ============================================================================
-- bag-frame.lua - EreaRpPlayerBagFrame Controller
-- ============================================================================
-- UI Structure: components/bag-frame.xml
-- Frame: EreaRpPlayerBagFrame (defined in XML)
--
-- PURPOSE: Manages the player's RP inventory bag frame behavior
--
-- METHODS:
--   EreaRpPlayerBagFrame:Initialize() - Setup frame, load position, configure dragging
--   EreaRpPlayerBagFrame:UpdateDatabaseLabel() - Update database sync status display
--   EreaRpPlayerBagFrame:SavePosition() - Persist frame position to SavedVariables
--   EreaRpPlayerBagFrame:LoadPosition() - Restore frame position from SavedVariables
--
-- DEPENDENCIES:
--   - EreaRpPlayerBagFrame (created by components/bag-frame.xml)
--   - EreaRpPlayerDB (SavedVariable)
--
-- PATTERN: Prototype-based OOP for WoW frames
-- ============================================================================

-- ============================================================================
-- Initialize Bag Frame
-- ============================================================================
-- Sets up the bag frame with title, database label, dragging, and position
function EreaRpPlayerBagFrame:Initialize()
    -- Get references to XML-defined child elements
    local title = EreaRpPlayerBagFrameTitle
    title:SetText("RP Player")
    
    local dbLabel = EreaRpPlayerBagFrameDbLabel
    
    -- Store reference for later updates
    self.dbLabel = dbLabel
    
    -- Setup draggable title bar (XML-defined frame)
    local bagTitleBar = EreaRpPlayerBagFrameTitleBar
    bagTitleBar:RegisterForDrag("LeftButton")
    bagTitleBar:SetScript("OnDragStart", function()
        EreaRpPlayerBagFrame:StartMoving()
    end)
    bagTitleBar:SetScript("OnDragStop", function()
        EreaRpPlayerBagFrame:StopMovingOrSizing()
        EreaRpPlayerBagFrame:SavePosition()
    end)
    
    -- Load saved position or use default
    self:LoadPosition()
    
    -- Set initial database label
    self:UpdateDatabaseLabel()
end

-- ============================================================================
-- Update Database Label
-- ============================================================================
-- Updates the database sync status label (Green = synced, Orange = not synced)
function EreaRpPlayerBagFrame:UpdateDatabaseLabel()
    local dbLabel = self.dbLabel or EreaRpPlayerBagFrameDbLabel
    
    if EreaRpPlayerDB and EreaRpPlayerDB.syncState and EreaRpPlayerDB.syncState.databaseName and EreaRpPlayerDB.syncState.databaseName ~= "" then
        dbLabel:SetText("Database: " .. EreaRpPlayerDB.syncState.databaseName)
        dbLabel:SetTextColor(0, 1, 0)  -- Green = synced
    else
        dbLabel:SetText("Database: None")
        dbLabel:SetTextColor(1, 0.5, 0)  -- Orange = not synced
    end
end

-- ============================================================================
-- Save Position
-- ============================================================================
-- Saves the current frame position to EreaRpPlayerDB.bagFramePos
function EreaRpPlayerBagFrame:SavePosition()
    local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
    EreaRpPlayerDB.bagFramePos = {point, relativePoint, xOfs, yOfs}
end

-- ============================================================================
-- Load Position
-- ============================================================================
-- Restores the frame position from EreaRpPlayerDB.bagFramePos (if saved)
function EreaRpPlayerBagFrame:LoadPosition()
    if EreaRpPlayerDB.bagFramePos then
        self:ClearAllPoints()
        self:SetPoint(EreaRpPlayerDB.bagFramePos[1], UIParent, EreaRpPlayerDB.bagFramePos[2], EreaRpPlayerDB.bagFramePos[3], EreaRpPlayerDB.bagFramePos[4])
    end
end
