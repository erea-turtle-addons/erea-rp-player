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
local inventory      = EreaRpLibraries:Inventory()
local objectDatabase = EreaRpLibraries:ObjectDatabase()
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

    -- If we have a target slot (dropped within bag), check for forge or reorganize
    if draggedItem and dragSourceSlot and targetSlot then
        Log("Dropped item in slot " .. targetSlot)

        local sourceInstance = inventory.GetItemAtSlot(EreaRpPlayerDB.inventory, dragSourceSlot)
        local targetInstance = inventory.GetItemAtSlot(EreaRpPlayerDB.inventory, targetSlot)

        -- Check if the two items form a recipe (drag-shortcut forge)
        if sourceInstance and targetInstance then
            local activeDb = EreaRpPlayerDB.activeDatabaseId
                             and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
            local activeDbItems = activeDb and activeDb.items or nil
            local outputItem = activeDbItems and
                objectDatabase.FindRecipeForPair(sourceInstance.guid, targetInstance.guid, activeDbItems)

            if outputItem then
                -- Found a recipe — skip reorganization, show forge confirm dialog
                local sourceItemName = ""
                local targetItemName = ""
                if activeDbItems then
                    for _, def in pairs(activeDbItems) do
                        if def.guid == sourceInstance.guid then sourceItemName = def.name or "?" end
                        if def.guid == targetInstance.guid then targetItemName = def.name or "?" end
                    end
                end

                local forgeCk = outputItem.recipe.cinematicKey
                EreaRpPlayer_ForgeOutputGuid      = outputItem.guid
                EreaRpPlayer_ForgeIngredientSlots = { dragSourceSlot, targetSlot }
                EreaRpPlayer_ForgeCinematicKey    = (forgeCk and forgeCk ~= "") and forgeCk or nil
                EreaRpPlayer_ForgeNotifyGm        = outputItem.recipe.notifyGm and true or false

                local discovered = EreaRpPlayerDB.discoveredCombinations
                                   and EreaRpPlayerDB.discoveredCombinations[outputItem.guid] == true
                if discovered then
                    StaticPopupDialogs["EreaRpPlayer_FORGE_CONFIRM"].text = "Combine %s\ninto %s?"
                    StaticPopup_Show("EreaRpPlayer_FORGE_CONFIRM",
                        sourceItemName .. " + " .. targetItemName, outputItem.name)
                else
                    StaticPopupDialogs["EreaRpPlayer_FORGE_CONFIRM"].text = "Combine %s?"
                    StaticPopup_Show("EreaRpPlayer_FORGE_CONFIRM",
                        sourceItemName .. " + " .. targetItemName)
                end

                -- Clear drag state and return (no reorganization)
                draggedItem    = nil
                dragSourceSlot = nil
                return
            end
        end

        -- No recipe found — do normal slot swap
        if sourceInstance then
            sourceInstance.slot = targetSlot
        end
        if targetInstance then
            targetInstance.slot = dragSourceSlot
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
