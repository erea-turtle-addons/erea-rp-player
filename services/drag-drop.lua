-- ============================================================================
-- drag-drop.lua - Drag & Drop System
-- ============================================================================
-- PURPOSE: Handles item dragging within bag and to other players
--
-- FEATURES:
--   - Cursor-following drag frame
--   - Drag within bag to reorganize (swap slots)
--   - Drag to player portrait to trade/show
--   - Visual feedback during drag
--
-- DEPENDENCIES:
--   - inventory module (from turtle-rp-common)
--   - EreaRpPlayerDB (SavedVariable)
--   - EreaRpPlayer_RefreshBag() function
--   - StaticPopup "EreaRpPlayer_DRAG_TO_PLAYER" (from dialogs.lua)
--
-- GLOBAL STATE:
--   - EreaRpPlayer_PendingDragItem: Item being dragged to player
--   - EreaRpPlayer_PendingDragTarget: Target player name
--
-- PATTERN: Prototype service - stateful, global prototype, accessed via inventory.lua
--
-- PUBLIC API:
--   - RPPlayerDragDrop:StartDrag(item, sourceSlot)
--   - RPPlayerDragDrop:StopDrag(targetSlot)
--   - RPPlayerDragDrop:IsDragging()
--   - RPPlayerDragDrop:GetDraggedItem()
-- ============================================================================

-- ============================================================================
-- PROTOTYPE
-- ============================================================================
RPPlayerDragDrop = {}

-- ============================================================================
-- IMPORTS
-- ============================================================================
local inventory = EreaRpLibraries:Inventory()
local Log = EreaRpLibraries:Logging("RPPlayer")

-- ============================================================================
-- Constants
-- ============================================================================
local SLOT_SIZE = 47  -- Must match slot size in rp-player.lua
local ICON_SIZE = 26  -- Must match icon size in rp-player.lua

-- ============================================================================
-- Internal State
-- ============================================================================
local draggedItem = nil
local dragFrame = nil
local dragSourceSlot = nil

-- ============================================================================
-- Create Drag Frame
-- ============================================================================
-- Creates a cursor-following frame that displays the dragged item's icon
-- @returns: The drag frame
local function CreateDragFrame()
    if not dragFrame then
        dragFrame = CreateFrame("Frame", "RPDragFrame", UIParent)
        dragFrame:SetWidth(SLOT_SIZE)
        dragFrame:SetHeight(SLOT_SIZE)
        dragFrame:SetFrameStrata("TOOLTIP")
        dragFrame:Hide()

        -- Icon texture (centered, smaller than slot to match bag slots)
        local icon = dragFrame:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(ICON_SIZE)
        icon:SetHeight(ICON_SIZE)
        icon:SetPoint("CENTER", dragFrame, "CENTER", 0, 0)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        dragFrame.icon = icon

        dragFrame:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            dragFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale, y / scale)
        end)
    end
    return dragFrame
end

-- ============================================================================
-- StartDrag - Initiates a drag operation
-- ============================================================================
-- @param item: The item being dragged
-- @param sourceSlot: The slot index the item is being dragged from
function RPPlayerDragDrop:StartDrag(item, sourceSlot)
    draggedItem = item
    dragSourceSlot = sourceSlot
    local frame = CreateDragFrame()
    frame.icon:SetTexture(item.icon)
    frame:Show()
    Log("Started dragging item: " .. item.name .. " from slot " .. sourceSlot)
end

-- ============================================================================
-- StopDrag - Ends a drag operation and handles the drop action
-- ============================================================================
-- @param targetSlot: The slot index where the item was dropped (nil if dropped elsewhere)
function RPPlayerDragDrop:StopDrag(targetSlot)
    if dragFrame then
        dragFrame:Hide()
    end

    -- Check if hovering over another player
    if draggedItem and UnitExists("mouseover") and UnitIsPlayer("mouseover") then
        local targetName = UnitName("mouseover")
        if targetName and targetName ~= UnitName("player") then
            -- Check if target is in our group (raid or party)
            local targetInGroup = false
            if GetNumRaidMembers() > 0 then
                -- Check raid members
                for i = 1, 40 do
                    if UnitName("raid"..i) == targetName then
                        targetInGroup = true
                        break
                    end
                end
            else
                -- Check party members
                for i = 1, 4 do
                    if UnitName("party"..i) == targetName then
                        targetInGroup = true
                        break
                    end
                end
            end

            if not targetInGroup then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF9900[RP Player]|r You can only trade with people in your group", 1, 0.6, 0)
                draggedItem = nil
                dragSourceSlot = nil
                return
            end

            -- Store pending drag action (global state for dialog)
            EreaRpPlayer_PendingDragItem = draggedItem
            EreaRpPlayer_PendingDragTarget = targetName

            -- Show confirmation dialog (Give or Show)
            StaticPopup_Show("EreaRpPlayer_DRAG_TO_PLAYER", draggedItem.name, targetName)

            -- Clear drag state
            draggedItem = nil
            dragSourceSlot = nil
            return
        end
    end

    -- If we have a target slot (dropped within bag), reorganize
    if draggedItem and dragSourceSlot and targetSlot then
        Log("Dropped item in slot " .. targetSlot)

        -- Swap items between source and target slots
        local sourceItem = inventory.GetItemAtSlot(EreaRpPlayerDB.inventory, dragSourceSlot)
        local targetItem = inventory.GetItemAtSlot(EreaRpPlayerDB.inventory, targetSlot)

        if sourceItem then
            sourceItem.slot = targetSlot
        end
        if targetItem then
            targetItem.slot = dragSourceSlot
        end

        EreaRpPlayer_RefreshBag()
    end

    -- Clear drag state
    draggedItem = nil
    dragSourceSlot = nil
end

-- ============================================================================
-- IsDragging - Check if currently dragging an item
-- ============================================================================
-- @returns: true if currently dragging an item, false otherwise
function RPPlayerDragDrop:IsDragging()
    return draggedItem ~= nil
end

-- ============================================================================
-- GetDraggedItem - Get the item currently being dragged
-- ============================================================================
-- @returns: The item currently being dragged, or nil
function RPPlayerDragDrop:GetDraggedItem()
    return draggedItem
end
