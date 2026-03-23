-- ============================================================================
-- inventory.lua - Complete Inventory Management
-- ============================================================================
-- PURPOSE: Manages the entire player inventory system including:
--   - 16-slot bag UI (creation and rendering)
--   - Context menu (right-click options)
--   - Item operations (show, trade, delete, read)
--   - Drag-drop handlers
--
-- PATTERN: Prototype-based OOP
--   EreaRpPlayerInventory:MethodName() - All logic in prototype methods
--   Global wrappers in rp-player.lua redirect to prototype
--
-- DEPENDENCIES:
--   - EreaRpPlayerBagFrameSlotsContainer (XML-defined)
--   - EreaRpPlayerDB (SavedVariable)
--   - Global state in rp-player.lua (EreaRpPlayer_Pending* variables)
--   - messaging, inventory, playerActions modules
--   - drag-drop.lua (StartDrag, StopDrag)
--   - dialogs.lua (StaticPopup definitions)
-- ============================================================================

-- ============================================================================
-- IMPORTS
-- ============================================================================
local inventory = EreaRpLibraries:Inventory()
local messaging = EreaRpLibraries:Messaging()
local objectDatabase = EreaRpLibraries:ObjectDatabase()
local Log = EreaRpLibraries:Logging("RPPlayer")

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local MAX_SLOTS = inventory.MAX_INVENTORY_SLOTS
local SLOT_SIZE = 47
local ICON_SIZE = 26
local SLOT_SPACING = 3

-- ============================================================================
-- PROTOTYPE TABLE
-- ============================================================================
EreaRpPlayerInventory = {}

-- ============================================================================
-- MODULE STATE
-- ============================================================================
-- itemSlots is now stored on the presenter (EreaRpPlayerBagFrame.itemSlots)
-- This service does not manage UI elements

-- ============================================================================
-- HELPER: Get active synced database items
-- ============================================================================
local function GetActiveDatabaseItems()
    local activeDb = EreaRpPlayerDB.activeDatabaseId
                     and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
    return activeDb and activeDb.items or nil
end

-- Forge mode state
local forgeModeActive = false
local forgeSummary    = nil   -- current recipe summary being forged
local hoverGlowSlots  = {}    -- {slotIndex} list of slots with active hover border glow

-- Check if a forge output has been discovered (player has successfully forged it before)
local function IsDiscovered(outputGuid)
    if not outputGuid then return false end
    if not EreaRpPlayerDB.discoveredCombinations then return false end
    return EreaRpPlayerDB.discoveredCombinations[outputGuid] == true
end

-- ============================================================================
-- HELPER FUNCTIONS (Local - internal use only)
-- ============================================================================

-- Check if item has any actions that pass conditions
local function HasAvailableActions(item)
    if not item.actions or table.getn(item.actions) == 0 then
        return false
    end

    -- Check each action's conditions
    for i = 1, table.getn(item.actions) do
        local action = item.actions[i]
        local isAvailable = true

        if action.conditions then
            -- Check customTextEmpty condition
            if action.conditions.customTextEmpty then
                local customText = item.customText or ""
                if customText ~= "" then
                    isAvailable = false
                end
            end

            -- Check counterGreaterThanZero condition
            if action.conditions.counterGreaterThanZero and isAvailable then
                local customNumber = item.customNumber or 0
                if customNumber <= 0 then
                    isAvailable = false
                end
            end
        end

        -- If this action is available, return true
        if isAvailable then
            return true
        end
    end

    -- No available actions found
    return false
end

-- Check if item has readable content
local function IsItemReadable(item)
    -- Has regular content
    if item.content and item.content ~= "" then
        return true
    end

    -- Has custom template + custom text
    if item.contentTemplate and item.contentTemplate ~= "" and
       item.customText and item.customText ~= "" then
        return true
    end

    return false
end

-- Check if a unit is in range (approximately 28 yards, like /say)
local function IsPlayerInRange(unitId)
    if not unitId or not UnitExists(unitId) then
        return false
    end

    -- CheckInteractDistance(unitId, distanceIndex)
    -- 1 = Inspect (28 yards) - closest to /say range (~25 yards)
    -- 2 = Trade (11.11 yards)
    -- 3 = Duel (9.9 yards)
    -- 4 = Follow (28 yards)
    -- Using 1 (Inspect) as it's approximately /say range
    return CheckInteractDistance(unitId, 1)
end

-- ============================================================================
-- PUBLIC METHODS - Slot Management
-- ============================================================================

-- Get the item slots from the presenter layer
-- This service does not create or manage UI elements
function EreaRpPlayerInventory:GetItemSlots()
    -- Access slots from the presenter (frame object)
    return EreaRpPlayerBagFrame.itemSlots or {}
end

-- Rebuild entire bag UI from inventory data
function EreaRpPlayerInventory:RefreshBag()
    Log("RefreshBag called, inventory count: " .. table.getn(EreaRpPlayerDB.inventory))

    -- Get slots from presenter layer
    local itemSlots = self:GetItemSlots()

    -- STEP 1: Auto-assign slots to items that don't have them
    -- (New items don't have slot field yet)
    -- v0.2.1: inventory contains instances (guid only), not full items
    for _, instance in ipairs(EreaRpPlayerDB.inventory) do
        if not instance.slot then
            local nextSlot = inventory.FindNextAvailableSlot(EreaRpPlayerDB.inventory)
            if nextSlot then
                instance.slot = nextSlot
                Log("Auto-assigned slot " .. nextSlot .. " to instance: " .. tostring(instance.guid))
            else
                Log("ERROR: No available slots for instance: " .. tostring(instance.guid))
            end
        end
    end

    -- Clear all slot visuals and scripts
    for i = 1, MAX_SLOTS do
        local slot = itemSlots[i]
        if slot then
            slot.icon:Hide()
            slot.count:Hide()
            slot.item = nil

            -- Reset border glow (forge/hover)
            slot.glowFrame:SetBackdropBorderColor(0, 0, 0, 0)

            -- Clear scripts
            slot:SetScript("OnEnter", nil)
            slot:SetScript("OnLeave", nil)
            slot:SetScript("OnClick", nil)
            slot:SetScript("OnMouseDown", nil)
            slot:SetScript("OnMouseUp", nil)
            slot:SetScript("OnDragStart", nil)
            slot:SetScript("OnDragStop", nil)
            slot:SetScript("OnReceiveDrag", nil)
            slot:EnableMouse(true)  -- Keep mouse enabled for empty slots
        end
    end

    -- Reset hover glow tracking table after clearing
    hoverGlowSlots = {}

    Log("All slots cleared")

    -- Place items in their assigned slots
    for _, instance in ipairs(EreaRpPlayerDB.inventory) do
        if instance.slot and instance.slot <= MAX_SLOTS then
            local slotIndex = instance.slot
            local slot = itemSlots[slotIndex]

            -- v0.2.1: Merge instance + definition (or use full item for system items)
            local item = nil
            if instance.name then
                -- Old format or system item (has full data already)
                item = instance
            else
                -- New format: instance data only, lookup definition
                local activeDb = EreaRpPlayerDB.activeDatabaseId
                                 and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
                item = inventory.GetFullItem(instance, activeDb)
            end

            -- Skip if object not found in database
            if item then
                Log("Placing item '" .. item.name .. "' in slot " .. slotIndex)
            slot.item = item
            slot.icon:SetTexture(item.icon)
            slot.icon:Show()

            -- Show counter if customNumber > 0
            if item.customNumber and item.customNumber > 0 then
                slot.count:SetText(tostring(item.customNumber))
                slot.count:Show()
            else
                slot.count:Hide()
            end

            -- Create closure-safe local references
            local currentItem = item
            local currentSlotIndex = slotIndex
            local currentSlotName = slot.slotName

            -- Tooltip
            slot:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                GameTooltip:ClearLines()

                -- Object name always in white (apply placeholder substitution)
                GameTooltip:AddLine(
                    objectDatabase.ApplyItemPlaceholders(currentItem.name, currentItem.customText, currentItem.additionalText, currentItem.customNumber),
                    1, 1, 1)

                if currentItem.tooltip and currentItem.tooltip ~= "" then
                    GameTooltip:AddLine(
                        objectDatabase.ApplyItemPlaceholders(currentItem.tooltip, currentItem.customText, currentItem.additionalText, currentItem.customNumber),
                        1, 0.82, 0, 1)
                end

                -- Show "Actions available" only if item has available actions (after condition checks)
                if HasAvailableActions(currentItem) then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Actions available", 0.4, 0.6, 1)  -- Blue
                end

                -- Show "Customized" if customText present
                if currentItem.customText and currentItem.customText ~= "" then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Customized", 0.8, 0.4, 1)  -- Purple
                end

                -- Show custom number if > 0 (v0.1.1)
                if currentItem.customNumber and currentItem.customNumber > 0 then
                    GameTooltip:AddLine("Charges: " .. currentItem.customNumber, 1, 1, 1)
                end

                GameTooltip:AddLine(" ")
                if currentItem.content and currentItem.content ~= "" then
                    GameTooltip:AddLine("Left-click to read", 0, 1, 0)
                end
                GameTooltip:AddLine("Right-click for options", 0, 1, 0)
                GameTooltip:ClearAllPoints()
                GameTooltip:SetPoint("BOTTOMRIGHT", currentSlotName, "TOPLEFT", 10, -10)
                GameTooltip:Show()

                -- Passive hover highlight: glow partner slots for any recipe this item is in
                -- (only when not already in forge mode to avoid conflicting overlays)
                if not forgeModeActive then
                    local activeDbItems = GetActiveDatabaseItems()
                    if activeDbItems then
                        local allSummaries = objectDatabase.GetRecipeSummaries(
                            EreaRpPlayerDB.inventory, activeDbItems)
                        hoverGlowSlots = {}
                        local anyPartner = false
                        for _, summary in ipairs(allSummaries) do
                            if summary.sourceSlot == currentSlotIndex and summary.partnerSlot then
                                local partnerSlot = itemSlots[summary.partnerSlot]
                                if partnerSlot then
                                    partnerSlot.glowFrame:SetBackdropBorderColor(0.2, 1, 0.2, 1)
                                    table.insert(hoverGlowSlots, summary.partnerSlot)
                                    anyPartner = true
                                end
                            end
                        end
                        -- Also glow the hovered slot itself
                        if anyPartner then
                            local selfSlot = itemSlots[currentSlotIndex]
                            if selfSlot then
                                selfSlot.glowFrame:SetBackdropBorderColor(0.2, 1, 0.2, 1)
                                table.insert(hoverGlowSlots, currentSlotIndex)
                            end
                        end
                    end
                end
            end)

            slot:SetScript("OnLeave", function()
                GameTooltip:Hide()
                GameTooltip:ClearAllPoints()

                -- Remove hover glow from partner slots
                for _, glowSlotIdx in ipairs(hoverGlowSlots) do
                    local glowSlot = itemSlots[glowSlotIdx]
                    if glowSlot then
                        glowSlot.glowFrame:SetBackdropBorderColor(0, 0, 0, 0)
                    end
                end
                hoverGlowSlots = {}
            end)

            -- Left click: Read item (if has content)
            -- Right click: Show context menu
            slot:SetScript("OnClick", function(self, button)
                local clickButton = button or arg1

                if clickButton == "LeftButton" then
                    -- Read item if it has content
                    if currentItem.content and currentItem.content ~= "" then
                        Log("Left click detected, reading item")
                        EreaRpPlayerInventory:ReadItem(currentItem)
                    else
                        Log("Left click ignored - item has no content")
                    end
                elseif clickButton == "RightButton" then
                    Log("Right click detected, showing menu")
                    EreaRpPlayerInventory:ShowContextMenu(currentItem, self)
                end
            end)

            -- Drag handlers for reorganizing and drag-to-player
            slot:SetScript("OnDragStart", function(self)
                RPPlayerDragDrop:StartDrag(currentItem, currentSlotIndex)
            end)

            slot:SetScript("OnDragStop", function(self)
                -- Check if we're hovering over this slot or another slot
                local mouseoverSlot = nil
                for i = 1, MAX_SLOTS do
                    if MouseIsOver(itemSlots[i]) then
                        mouseoverSlot = i
                        break
                    end
                end

                RPPlayerDragDrop:StopDrag(mouseoverSlot)
            end)

            -- Allow receiving drags (for reorganization)
            slot:SetScript("OnReceiveDrag", function(self)
                -- Same as OnDragStop - handle the drop
                local mouseoverSlot = nil
                for i = 1, MAX_SLOTS do
                    if MouseIsOver(itemSlots[i]) then
                        mouseoverSlot = i
                        break
                    end
                end

                RPPlayerDragDrop:StopDrag(mouseoverSlot)
            end)

            slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            slot:RegisterForDrag("LeftButton")
            else
                Log("ERROR: Object not found for GUID: " .. tostring(instance.guid))
            end
        end
    end

    -- Enable empty slots to receive drags for reorganization
    for i = 1, MAX_SLOTS do
        local slot = itemSlots[i]
        if slot and not slot.item then
            local emptySlotIndex = i

            -- Allow receiving drags on empty slots
            slot:SetScript("OnReceiveDrag", function(self)
                RPPlayerDragDrop:StopDrag(emptySlotIndex)
            end)
        end
    end

    -- Update database label (shows which GM database is synced)
    EreaRpPlayerBagFrame:UpdateDatabaseLabel()
end

-- ============================================================================
-- PUBLIC METHODS - Item Operations
-- ============================================================================

-- Show item to a specific player (visual preview, no transfer)
-- silent: if true, don't show feedback message (used when showing to "All")
function EreaRpPlayerInventory:ShowItem(item, targetName, silent)
    if not targetName then
        Log("ERROR: ShowItem called without targetName")
        return
    end

    Log("ShowItem called - Item: " .. tostring(item.name) .. ", Target: " .. tostring(targetName))

    -- Send message (messaging.lua handles creation + distribution + sending)
    -- Pass full item for player-to-player (receiver doesn't have sender's inventory)
    local success = messaging.SendShowMessage(targetName, item)

    if not success then
        Log("ERROR: Failed to send SHOW message")
        return
    end

    Log("SHOW message sent for item: " .. item.name)
end

-- Delete item from inventory
function EreaRpPlayerInventory:DeleteItem(item)
    Log("DeleteItem called - Item: " .. tostring(item.name) .. ", Slot: " .. tostring(item.slot))

    -- Remove from inventory by slot (unique identifier for item instances)
    for i, invItem in ipairs(EreaRpPlayerDB.inventory) do
        if invItem.slot == item.slot then
            table.remove(EreaRpPlayerDB.inventory, i)
            break
        end
    end

    self:RefreshBag()
    Log("Item deleted successfully")
end

-- Trade item with another player
function EreaRpPlayerInventory:TradeItem(item, targetName)
    Log("TradeItem called - Item: " .. tostring(item.name) .. ", Target: " .. tostring(targetName))

    -- Send message (messaging.lua handles creation + distribution + sending)
    -- Pass full item for player-to-player (receiver doesn't have sender's inventory)
    local success = messaging.SendTradeMessage(targetName, item)

    if not success then
        Log("ERROR: Failed to send TRADE message")
        return
    end

    Log("TRADE message sent for item: " .. item.name)

    -- Store pending trade (will be removed on acceptance)
    -- Global state in rp-player.lua
    EreaRpPlayer_PendingOutgoingTrade = item
end

-- Read item (open read frame)
-- Optional shownBy parameter indicates who showed you this item
function EreaRpPlayerInventory:ReadItem(item, shownBy)
    EreaRpPlayerReadFrame:ShowItem(item, shownBy)
end

-- Execute an action on an item (delegates to services/player-actions.lua)
function EreaRpPlayerInventory:ExecuteAction(item, action)
    EreaRpPlayerActions:ExecuteAction(item, action)
end

-- ============================================================================
-- PUBLIC METHODS - Forge Mode
-- ============================================================================

-- EnterForgeMode - Highlight partner slot, dim all others
function EreaRpPlayerInventory:EnterForgeMode(summary)
    if forgeModeActive then
        self:ExitForgeMode()
    end
    forgeModeActive = true
    forgeSummary    = summary
    Log("EnterForgeMode: partner slot=" .. tostring(summary.partnerSlot))

    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD700[RP]|r Click |cFFFFFFFF" .. (summary.partnerName or "the glowing item") .. "|r to combine, or press |cFFFFFFFFEscape|r to cancel.")

    local itemSlots = self:GetItemSlots()

    -- Glow the partner slot's border
    local partnerSlot = itemSlots[summary.partnerSlot]
    if partnerSlot then
        partnerSlot.glowFrame:SetBackdropBorderColor(1, 0.85, 0, 1)
    end

    -- Override click behaviour for all slots while in forge mode
    for i = 1, MAX_SLOTS do
        local slot = itemSlots[i]
        if slot then
            local slotIndex = i  -- closure-safe
            slot:SetScript("OnClick", function(self, button)
                EreaRpPlayerInventory:HandleForgeModeClick(slotIndex)
            end)
        end
    end

    -- Register Escape key to cancel forge mode
    EreaRpPlayerBagFrame:EnableKeyboard(true)  -- Must be enabled to receive OnKeyDown
    EreaRpPlayerBagFrame:SetScript("OnKeyDown", function()
        local key = arg1  -- Lua 5.0: global arg1
        if key == "ESCAPE" then
            EreaRpPlayerInventory:ExitForgeMode()
        end
    end)
end

-- ExitForgeMode - Restore all slot visuals and clear state
function EreaRpPlayerInventory:ExitForgeMode()
    if not forgeModeActive then return end

    -- Save partner slot index before clearing state
    local partnerSlotIndex = forgeSummary and forgeSummary.partnerSlot

    forgeModeActive = false
    forgeSummary    = nil
    Log("ExitForgeMode")

    -- Reset partner slot border glow
    if partnerSlotIndex then
        local itemSlots = self:GetItemSlots()
        local partnerSlot = itemSlots[partnerSlotIndex]
        if partnerSlot then
            partnerSlot.glowFrame:SetBackdropBorderColor(0, 0, 0, 0)
        end
    end

    -- Clear Escape key handler and disable keyboard capture
    EreaRpPlayerBagFrame:SetScript("OnKeyDown", nil)
    EreaRpPlayerBagFrame:EnableKeyboard(false)

    -- Rebuild bag to restore proper slot scripts
    self:RefreshBag()
end

-- HandleForgeModeClick - Process a slot click while in forge mode
function EreaRpPlayerInventory:HandleForgeModeClick(slotIndex)
    if not forgeModeActive or not forgeSummary then
        self:ExitForgeMode()
        return
    end

    if slotIndex == forgeSummary.partnerSlot then
        -- Player clicked the glowing partner slot → show confirm dialog
        local outputItem = forgeSummary.outputItem
        local outputName = outputItem and outputItem.name or "?"

        -- Find ingredient names
        local items     = GetActiveDatabaseItems()
        local ing1Name  = "Item 1"
        local ing2Name  = "Item 2"
        if items then
            for _, def in pairs(items) do
                if def.guid == forgeSummary.sourceGuid  then ing1Name = def.name or "?" end
                if def.guid == forgeSummary.partnerGuid then ing2Name = def.name or "?" end
            end
        end

        -- Populate global forge state for dialogs
        EreaRpPlayer_ForgeOutputGuid      = outputItem and outputItem.guid
        EreaRpPlayer_ForgeIngredientSlots = { forgeSummary.sourceSlot, forgeSummary.partnerSlot }
        EreaRpPlayer_ForgeCinematicKey    = forgeSummary.cinematicKey ~= "" and forgeSummary.cinematicKey or nil
        EreaRpPlayer_ForgeNotifyGm        = forgeSummary.notifyGm

        local outGuid = outputItem and outputItem.guid
        Log("HandleForgeModeClick: outputGuid=" .. tostring(outGuid) .. " discovered=" .. tostring(IsDiscovered(outGuid)))
        if IsDiscovered(outGuid) then
            StaticPopupDialogs["EreaRpPlayer_FORGE_CONFIRM"].text = "Combine %s\ninto %s?"
            StaticPopup_Show("EreaRpPlayer_FORGE_CONFIRM", ing1Name .. " + " .. ing2Name, outputName)
        else
            StaticPopupDialogs["EreaRpPlayer_FORGE_CONFIRM"].text = "Combine %s?"
            StaticPopup_Show("EreaRpPlayer_FORGE_CONFIRM", ing1Name .. " + " .. ing2Name)
        end
    else
        -- Clicked a non-partner slot → cancel forge mode
        self:ExitForgeMode()
    end
end

-- ExecuteForge - Remove ingredients, add output item, clean up
function EreaRpPlayerInventory:ExecuteForge()
    Log("ExecuteForge called")

    if not EreaRpPlayer_ForgeOutputGuid or not EreaRpPlayer_ForgeIngredientSlots then
        self:ExitForgeMode()
        return
    end

    local slots = EreaRpPlayer_ForgeIngredientSlots

    -- Remove ingredient slots in descending order to preserve indices
    local slot1 = slots[1]
    local slot2 = slots[2]
    if slot1 < slot2 then
        slot1, slot2 = slot2, slot1  -- remove higher slot first
    end

    for _, slotToRemove in ipairs({slot1, slot2}) do
        for i, instance in ipairs(EreaRpPlayerDB.inventory) do
            if instance.slot == slotToRemove then
                table.remove(EreaRpPlayerDB.inventory, i)
                break
            end
        end
    end

    -- Add output item instance to inventory
    local newInstance = inventory.CreateItemInstance(EreaRpPlayer_ForgeOutputGuid, "", "", 0)
    local success, assignedSlot = inventory.AddItemToInventory(EreaRpPlayerDB.inventory, newInstance)
    if not success then
        Log("ERROR: ExecuteForge - bag full, could not add output item")
    end

    local cinematicKey = EreaRpPlayer_ForgeCinematicKey
    local notifyGm     = EreaRpPlayer_ForgeNotifyGm
    local outputGuid   = EreaRpPlayer_ForgeOutputGuid
    Log("ExecuteForge: outputGuid=" .. tostring(outputGuid))

    self:ExitForgeMode()
    self:RefreshBag()

    -- Mark this combination as discovered (player now knows what it produces)
    if not EreaRpPlayerDB.discoveredCombinations then
        EreaRpPlayerDB.discoveredCombinations = {}
        Log("ExecuteForge: initialized missing discoveredCombinations table")
    end
    if outputGuid then
        EreaRpPlayerDB.discoveredCombinations[outputGuid] = true
        Log("ExecuteForge: marked discovered outputGuid=" .. tostring(outputGuid))
    else
        Log("ExecuteForge: ERROR - outputGuid is nil, cannot mark discovered")
    end

    -- Clear forge globals
    EreaRpPlayer_ForgeOutputGuid      = nil
    EreaRpPlayer_ForgeIngredientSlots = nil
    EreaRpPlayer_ForgeNotifyGm        = false
    -- Note: ForgeCinematicKey is cleared after broadcast dialog

    -- Offer cinematic broadcast if recipe has one
    if cinematicKey and cinematicKey ~= "" then
        EreaRpPlayer_ForgeCinematicKey = cinematicKey
        StaticPopup_Show("EreaRpPlayer_FORGE_BROADCAST")
    else
        EreaRpPlayer_ForgeCinematicKey = nil
    end

    Log("ExecuteForge complete")
end

-- BroadcastForge - Broadcast the creation cinematic to the raid
function EreaRpPlayerInventory:BroadcastForge()
    local cinematicKey = EreaRpPlayer_ForgeCinematicKey
    if not cinematicKey or cinematicKey == "" then
        Log("BroadcastForge: no cinematicKey set")
        return
    end

    local playerName = UnitName("player")
    messaging.SendCinematicBroadcastMessage(cinematicKey, playerName, "", "", 0)
    Log("BroadcastForge sent cinematic: " .. cinematicKey)

    EreaRpPlayer_ForgeCinematicKey = nil
end

-- ============================================================================
-- PUBLIC METHODS - Context Menu
-- ============================================================================

-- Show context menu for item
function EreaRpPlayerInventory:ShowContextMenu(item, anchorFrame)
    Log("ShowContextMenu called for item: " .. tostring(item.name))

    -- Create dropdown frame if it doesn't exist
    if not RPPlayerContextMenuFrame then
        RPPlayerContextMenuFrame = CreateFrame("Frame", "RPPlayerContextMenuFrame", UIParent, "UIDropDownMenuTemplate")
        Log("Created new dropdown frame")
    end

    -- Get raid members alphabetically, filtered by range
    local raidMembers = {}
    local allMembers = {}  -- Track all members for counting

    if GetNumRaidMembers() > 0 then
        Log("In raid mode, scanning " .. GetNumRaidMembers() .. " members")
        for i = 1, GetNumRaidMembers() do
            local name = GetRaidRosterInfo(i)
            Log("Raid slot " .. i .. ": " .. tostring(name) .. " (me: " .. tostring(UnitName("player")) .. ")")
            if name and name ~= UnitName("player") then
                table.insert(allMembers, name)
                -- Check if player is in range
                local unitId = "raid" .. i
                Log("Checking range for " .. unitId .. " (" .. name .. ")")
                if IsPlayerInRange(unitId) then
                    table.insert(raidMembers, name)
                    Log("Player " .. name .. " is in range")
                else
                    Log("Player " .. name .. " is OUT OF RANGE")
                end
            end
        end
    elseif GetNumPartyMembers() > 0 then
        -- In party (not raid)
        for i = 1, GetNumPartyMembers() do
            local name = UnitName("party"..i)
            if name then
                table.insert(allMembers, name)
                local unitId = "party" .. i
                if IsPlayerInRange(unitId) then
                    table.insert(raidMembers, name)
                    Log("Player " .. name .. " is in range")
                else
                    Log("Player " .. name .. " is OUT OF RANGE")
                end
            end
        end
    end

    -- Sort alphabetically
    table.sort(raidMembers)
    Log("Found " .. table.getn(raidMembers) .. " in-range players out of " .. table.getn(allMembers) .. " total")

    -- Compute recipe summaries for this item's slot
    local activeDbItems = GetActiveDatabaseItems()
    local itemSummaries = {}
    if activeDbItems then
        local allSummaries = objectDatabase.GetRecipeSummaries(EreaRpPlayerDB.inventory, activeDbItems)
        for _, summary in ipairs(allSummaries) do
            if summary.sourceSlot == item.slot
               and IsDiscovered(summary.outputItem and summary.outputItem.guid) then
                table.insert(itemSummaries, summary)
            end
        end
    end
    Log("Recipe summaries for slot " .. tostring(item.slot) .. ": " .. table.getn(itemSummaries))

    -- Store item for use in callbacks
    RPPlayerContextMenuFrame.contextItem    = item
    RPPlayerContextMenuFrame.raidMembers    = raidMembers
    RPPlayerContextMenuFrame.totalMembers   = table.getn(allMembers)
    RPPlayerContextMenuFrame.recipeSummaries = itemSummaries

    -- Initialize dropdown with proper WoW 1.12 syntax
    UIDropDownMenu_Initialize(RPPlayerContextMenuFrame, function(level)
        -- In WoW 1.12, level might be in UIDROPDOWNMENU_MENU_LEVEL global
        local menuLevel = level or UIDROPDOWNMENU_MENU_LEVEL or 1
        Log("UIDropDownMenu_Initialize callback, level param: " .. tostring(level) .. ", UIDROPDOWNMENU_MENU_LEVEL: " .. tostring(UIDROPDOWNMENU_MENU_LEVEL) .. ", using: " .. tostring(menuLevel))

        if menuLevel == 1 then
            -- Actions first (always show if item has actions, grey out unavailable ones)
            if RPPlayerContextMenuFrame.contextItem.actions and table.getn(RPPlayerContextMenuFrame.contextItem.actions) > 0 then
                -- Add each action (v0.2.1: check conditions, grey out if unavailable)
                for i = 1, table.getn(RPPlayerContextMenuFrame.contextItem.actions) do
                    local action = RPPlayerContextMenuFrame.contextItem.actions[i]

                    -- Check conditions (v0.2.1)
                    local isAvailable = true
                    if action.conditions then
                        -- Check customTextEmpty condition
                        if action.conditions.customTextEmpty then
                            local customText = RPPlayerContextMenuFrame.contextItem.customText or ""
                            if customText ~= "" then
                                isAvailable = false  -- Custom text not empty, action unavailable
                            end
                        end

                        -- Check counterGreaterThanZero condition
                        if action.conditions.counterGreaterThanZero and isAvailable then
                            local customNumber = RPPlayerContextMenuFrame.contextItem.customNumber or 0
                            if customNumber <= 0 then
                                isAvailable = false  -- Counter not > 0, action unavailable
                            end
                        end
                    end

                    -- Always add action, but grey out if unavailable
                    local actionCopy = action
                    UIDropDownMenu_AddButton({
                        text = actionCopy.label,
                        func = isAvailable and function()
                            EreaRpPlayerInventory:ExecuteAction(RPPlayerContextMenuFrame.contextItem, actionCopy)
                        end or nil,
                        disabled = not isAvailable and 1 or nil,
                        notCheckable = 1
                    })
                end

                -- Add separator after actions
                UIDropDownMenu_AddButton({
                    text = "----------",
                    disabled = 1,
                    notCheckable = 1
                })
            end

            -- Combine (forge) entries — one per recipe this item participates in
            local summaries = RPPlayerContextMenuFrame.recipeSummaries
            if summaries and table.getn(summaries) > 0 then -- Lua 5.0: table.getn
                for si = 1, table.getn(summaries) do -- Lua 5.0: table.getn
                    local summary = summaries[si]
                    local summaryCopy = summary  -- closure-safe copy
                    if summary.partnerSlot then
                        -- Partner present: entry is enabled — forge immediately, no confirm dialog
                        local outLabel = IsDiscovered(summary.outputItem and summary.outputItem.guid)
                                         and ("Combine -> " .. summary.outputItem.name) or "Combine"
                        UIDropDownMenu_AddButton({
                            text = outLabel,
                            func = function()
                                local s = summaryCopy
                                EreaRpPlayer_ForgeOutputGuid      = s.outputItem and s.outputItem.guid
                                EreaRpPlayer_ForgeIngredientSlots = { s.sourceSlot, s.partnerSlot }
                                EreaRpPlayer_ForgeCinematicKey    = (s.cinematicKey and s.cinematicKey ~= "") and s.cinematicKey or nil
                                EreaRpPlayer_ForgeNotifyGm        = s.notifyGm and true or false
                                EreaRpPlayerInventory:ExecuteForge()
                            end,
                            notCheckable = 1
                        })
                    else
                        -- Partner absent: entry is greyed out
                        local outLabelMissing = IsDiscovered(summary.outputItem and summary.outputItem.guid)
                                                and ("Combine -> " .. summary.outputItem.name) or "Combine"
                        UIDropDownMenu_AddButton({
                            text = outLabelMissing .. " (missing: " .. summary.partnerName .. ")",
                            disabled = 1,
                            notCheckable = 1
                        })
                    end
                end
                UIDropDownMenu_AddButton({
                    text = "----------",
                    disabled = 1,
                    notCheckable = 1
                })
            end

            -- Read option (if item has readable content or custom template + text)
            if IsItemReadable(RPPlayerContextMenuFrame.contextItem) then
                UIDropDownMenu_AddButton({
                    text = "Read",
                    func = function()
                        EreaRpPlayerInventory:ReadItem(RPPlayerContextMenuFrame.contextItem)
                    end,
                    notCheckable = 1
                })
            end

            -- Show to nearby submenu
            if table.getn(RPPlayerContextMenuFrame.raidMembers) > 0 then
                UIDropDownMenu_AddButton({
                    text = "Show to",
                    hasArrow = 1,
                    notCheckable = 1,
                    value = "showto"
                })
            else
                -- Determine correct message: "not in group" vs "no one in range"
                local disabledText = "Show to (not in group)"
                if RPPlayerContextMenuFrame.totalMembers > 0 then
                    disabledText = "Show to (no one in range)"
                end
                UIDropDownMenu_AddButton({
                    text = disabledText,
                    disabled = 1,
                    notCheckable = 1
                })
            end

            -- Give to submenu
            if table.getn(RPPlayerContextMenuFrame.raidMembers) > 0 then
                UIDropDownMenu_AddButton({
                    text = "Give to",
                    hasArrow = 1,
                    notCheckable = 1,
                    value = "giveto"
                })
            else
                -- Determine correct message: "not in group" vs "no one in range"
                local disabledText = "Give to (not in group)"
                if RPPlayerContextMenuFrame.totalMembers > 0 then
                    disabledText = "Give to (no one in range)"
                end
                UIDropDownMenu_AddButton({
                    text = disabledText,
                    disabled = 1,
                    notCheckable = 1
                })
            end

            -- Delete option
            UIDropDownMenu_AddButton({
                text = "Delete",
                func = function()
                    -- Global state in rp-player.lua
                    EreaRpPlayer_PendingDeleteItem = RPPlayerContextMenuFrame.contextItem
                    StaticPopup_Show("EreaRpPlayer_DELETE_ITEM", RPPlayerContextMenuFrame.contextItem.name)
                end,
                notCheckable = 1
            })
        elseif menuLevel == 2 and UIDROPDOWNMENU_MENU_VALUE == "showto" then
            -- Show to submenu: All option first
            UIDropDownMenu_AddButton({
                text = "All",
                func = function()
                    -- Show to all players in range (iterate through the list)
                    local item = RPPlayerContextMenuFrame.contextItem
                    for _, playerName in ipairs(RPPlayerContextMenuFrame.raidMembers) do
                        EreaRpPlayerInventory:ShowItem(item, playerName, true)  -- silent = true to suppress individual messages
                    end
                end,
                notCheckable = 1
            }, 2)

            -- Separator
            UIDropDownMenu_AddButton({
                text = "----------",
                disabled = 1,
                notCheckable = 1
            }, 2)

            -- Individual player names
            for _, playerName in ipairs(RPPlayerContextMenuFrame.raidMembers) do
                -- Create closure-safe local copy
                local targetPlayer = playerName
                UIDropDownMenu_AddButton({
                    text = targetPlayer,
                    func = function()
                        EreaRpPlayerInventory:ShowItem(RPPlayerContextMenuFrame.contextItem, targetPlayer)
                    end,
                    notCheckable = 1
                }, 2)
            end

        elseif menuLevel == 2 and UIDROPDOWNMENU_MENU_VALUE == "giveto" then
            -- Give to submenu with player names
            for _, playerName in ipairs(RPPlayerContextMenuFrame.raidMembers) do
                -- Create closure-safe local copy
                local targetPlayer = playerName
                UIDropDownMenu_AddButton({
                    text = targetPlayer,
                    func = function()
                        EreaRpPlayerInventory:TradeItem(RPPlayerContextMenuFrame.contextItem, targetPlayer)
                    end,
                    notCheckable = 1
                }, 2)
            end
        end
    end, "MENU")

    Log("Calling ToggleDropDownMenu")
    -- WoW 1.12: ToggleDropDownMenu(level, value, dropdownFrame, anchorName, xOffset, yOffset)
    -- Use "cursor" as anchor to show at mouse position
    ToggleDropDownMenu(1, nil, RPPlayerContextMenuFrame, "cursor", 0, 0)
    Log("Menu should be visible now")
end
