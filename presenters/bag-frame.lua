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
--   EreaRpPlayerBagFrame:CreateItemSlots() - Create the 16 slot frames
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

    -- Hide the static FontString label; a dropdown replaces it visually
    EreaRpPlayerBagFrameDbLabel:Hide()

    -- Database-selector dropdown (declared in bag-frame.xml)
    local dd = EreaRpPlayerBagFrameDbDropdown
    UIDropDownMenu_SetWidth(171, dd)  -- 200 + 25 internal = 225px total (5px from each side border)
    self.dbDropdown = dd

    UIDropDownMenu_Initialize(dd, function()
        if EreaRpPlayerDB.databases then
            for dbId, db in pairs(EreaRpPlayerDB.databases) do
                local info = {}
                info.text  = db.metadata and db.metadata.name or dbId
                info.value = dbId
                do
                    local id   = dbId
                    local name = db.metadata and db.metadata.name or dbId
                    info.func  = function()
                        UIDropDownMenu_SetSelectedValue(dd, id)
                        UIDropDownMenu_SetText(name, dd)
                        EreaRpPlayer_SetActiveDatabase(id)
                    end
                end
                UIDropDownMenu_AddButton(info)
            end
        end
        if not EreaRpPlayerDB.activeDatabaseId then
            local info = {}
            info.text  = "(No database)"
            info.value = ""
            info.func  = function() end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetText("(No database)", dd)

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

    -- Populate dropdown with current active database (if any)
    self:UpdateDatabaseLabel()

end

-- ============================================================================
-- Create Item Slots
-- ============================================================================
-- Creates the 16 dynamic slot frames for the bag
-- This is GUI logic that belongs in the presenter layer
function EreaRpPlayerBagFrame:CreateItemSlots()
    local slotsContainer = EreaRpPlayerBagFrameSlotsContainer
    local MAX_SLOTS = 16
    local SLOT_SIZE = 47
    local ICON_SIZE = 26
    local SLOT_SPACING = 3

    self.itemSlots = {}

    for i = 1, MAX_SLOTS do
        local row = math.floor((i - 1) / 4)
        local col = math.mod(i - 1, 4)

        local slotName = "RPBagSlot"..i
        local slot = CreateFrame("Button", slotName, slotsContainer)
        slot:SetWidth(SLOT_SIZE)
        slot:SetHeight(SLOT_SIZE)
        slot:SetPoint("TOPLEFT", col * (SLOT_SIZE + SLOT_SPACING), -row * (SLOT_SIZE + SLOT_SPACING))
        slot:EnableMouse(true)
        slot:RegisterForClicks("LeftButtonUp", "RightButtonDown", "RightButtonUp")
        slot.slotName = slotName

        -- Empty slot background
        local bg = slot:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\UI-EmptySlot")
        slot.bg = bg

        -- Item icon texture (centered, smaller than slot)
        local icon = slot:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(ICON_SIZE)
        icon:SetHeight(ICON_SIZE)
        icon:SetPoint("CENTER", slot, "CENTER", 0, 0)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        icon:Hide()
        slot.icon = icon

        -- Counter text (like WoW's item count display)
        local count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
        count:SetJustifyH("RIGHT")
        count:Hide()
        slot.count = count

        -- Glow frame: tightly wraps the icon, used for forge/hover border highlight
        local glowFrame = CreateFrame("Frame", nil, slot)
        glowFrame:SetWidth(ICON_SIZE + 8)
        glowFrame:SetHeight(ICON_SIZE + 8)
        glowFrame:SetPoint("CENTER", slot, "CENTER", 0, 0)
        glowFrame:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
        })
        glowFrame:SetBackdropBorderColor(0, 0, 0, 0)
        slot.glowFrame = glowFrame

        slot.item = nil
        self.itemSlots[i] = slot
    end
end

-- ============================================================================
-- Update Database Label
-- ============================================================================
-- Drives the database dropdown to reflect the currently active campaign.
function EreaRpPlayerBagFrame:UpdateDatabaseLabel()
    local dd = self.dbDropdown
    if not dd then return end
    local dbId = EreaRpPlayerDB.activeDatabaseId
    if dbId and EreaRpPlayerDB.databases and EreaRpPlayerDB.databases[dbId] then
        local name = EreaRpPlayerDB.databases[dbId].metadata.name
        UIDropDownMenu_SetSelectedValue(dd, dbId)
        UIDropDownMenu_SetText(name, dd)
    else
        UIDropDownMenu_SetText("(No database)", dd)
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
