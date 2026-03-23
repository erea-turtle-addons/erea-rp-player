-- ============================================================================
-- read-frame.lua - EreaRpPlayerReadFrame Controller
-- ============================================================================
-- UI Structure: components/read-frame.xml
-- Frame: EreaRpPlayerReadFrame (defined in XML)
--
-- PURPOSE: Manages the item reading frame behavior
--
-- METHODS:
--   EreaRpPlayerReadFrame:Initialize() - Setup frame, load position, configure dragging
--   EreaRpPlayerReadFrame:ShowItem(item, shownBy) - Display item content in read frame
--   EreaRpPlayerReadFrame:SavePosition() - Persist frame position to SavedVariables
--   EreaRpPlayerReadFrame:LoadPosition() - Restore frame position from SavedVariables
--
-- DEPENDENCIES:
--   - EreaRpPlayerReadFrame (created by components/read-frame.xml)
--   - EreaRpPlayerDB (SavedVariable)
--   - objectDatabase module (from turtle-rp-common)
--
-- PATTERN: Prototype-based OOP for WoW frames
-- ============================================================================

-- ============================================================================
-- IMPORTS
-- ============================================================================
local objectDatabase = EreaRpLibraries:ObjectDatabase()

-- ============================================================================
-- Initialize Read Frame
-- ============================================================================
-- Sets up the read frame with dragging and position loading
function EreaRpPlayerReadFrame:Initialize()
    -- Get references to XML-defined elements
    self.title = EreaRpPlayerReadFrameTitle
    self.icon = EreaRpPlayerReadFrameIcon
    self.itemName = EreaRpPlayerReadFrameItemName
    self.itemDesc = EreaRpPlayerReadFrameItemDesc
    self.separator = EreaRpPlayerReadFrameSeparator
    self.scrollFrame = RPReadScrollFrame
    self.scrollChild = RPReadScrollFrameScrollChild
    self.text = RPReadScrollFrameScrollChildText
    
    -- Setup draggable title bar (XML-defined frame)
    local readTitleBar = EreaRpPlayerReadFrameTitleBar
    readTitleBar:RegisterForDrag("LeftButton")
    readTitleBar:SetScript("OnDragStart", function()
        EreaRpPlayerReadFrame:StartMoving()
    end)
    readTitleBar:SetScript("OnDragStop", function()
        EreaRpPlayerReadFrame:StopMovingOrSizing()
        EreaRpPlayerReadFrame:SavePosition()
    end)
    
    -- Load saved position or use default
    self:LoadPosition()
end

-- ============================================================================
-- Show Item
-- ============================================================================
-- Displays an item's content in the read frame
-- @param item: Table - Item object with guid, name, icon, tooltip, content, customText
-- @param shownBy: String (optional) - Player name who showed this item
function EreaRpPlayerReadFrame:ShowItem(item, shownBy)
    -- Set title based on context
    if shownBy then
        self.title:SetText("An item shown by " .. shownBy)
        self.title:Show()
    else
        self.title:SetText("")
        self.title:Hide()
    end
    
    -- Set icon
    if item.icon and item.icon ~= "" then
        self.icon:SetTexture(item.icon)
    else
        self.icon:SetTexture("Interface\Icons\INV_Misc_QuestionMark")
    end
    
    -- Set item name (apply placeholder substitution)
    self.itemName:SetText(objectDatabase.ApplyItemPlaceholders(
        item.name or "Unknown Item", item.customText, item.additionalText, item.customNumber))

    -- Set description/tooltip (apply placeholder substitution)
    if item.tooltip and item.tooltip ~= "" then
        self.itemDesc:SetText(objectDatabase.ApplyItemPlaceholders(
            item.tooltip, item.customText, item.additionalText, item.customNumber))
    else
        self.itemDesc:SetText("")
    end

    -- Set content text (business logic delegated to objectDatabase.RenderItemContent)
    local activeDb = EreaRpPlayerDB.activeDatabaseId
                     and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
    local displayContent = objectDatabase.RenderItemContent(
        item.guid,
        item.customText,
        item.additionalText,
        item.customNumber,
        activeDb
    )
    self.text:SetText(displayContent)

    -- Update scroll child and text width based on current frame width
    local frameWidth = self:GetWidth() or 450
    local scrollChildWidth = frameWidth - 70  -- Account for padding and scrollbar
    self.scrollChild:SetWidth(scrollChildWidth)
    self.text:SetWidth(scrollChildWidth)

    -- Force scroll frame to update layout (WoW 1.12 requirement)
    -- This ensures GetHeight() returns accurate height after text wrapping
    self.scrollFrame:UpdateScrollChildRect()

    -- Calculate height needed for text (must be done AFTER setting width for wrapping)
    local textHeight = self.text:GetHeight()
    if textHeight and textHeight > 0 then
        self.scrollChild:SetHeight(textHeight + 20)  -- Add padding
    else
        -- Fallback to a reasonable default
        self.scrollChild:SetHeight(400)
    end

    -- Force scroll frame to update again after height change
    self.scrollFrame:UpdateScrollChildRect()

    -- Reset scroll position to top when showing new item
    self.scrollFrame:SetVerticalScroll(0)

    self:Show()
end

-- ============================================================================
-- Save Position
-- ============================================================================
-- Saves the current frame position to EreaRpPlayerDB.readFramePos
function EreaRpPlayerReadFrame:SavePosition()
    local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
    EreaRpPlayerDB.readFramePos = {point, relativePoint, xOfs, yOfs}
end

-- ============================================================================
-- Load Position
-- ============================================================================
-- Restores the frame position from EreaRpPlayerDB.readFramePos (if saved)
function EreaRpPlayerReadFrame:LoadPosition()
    if EreaRpPlayerDB.readFramePos then
        self:ClearAllPoints()
        self:SetPoint(EreaRpPlayerDB.readFramePos[1], UIParent, EreaRpPlayerDB.readFramePos[2], EreaRpPlayerDB.readFramePos[3], EreaRpPlayerDB.readFramePos[4])
    end
end
