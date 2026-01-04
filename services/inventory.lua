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
local itemSlots = {}  -- Array of slot frames

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

-- Create the 16 dynamic slot frames
function EreaRpPlayerInventory:CreateItemSlots()
    local slotsContainer = EreaRpPlayerBagFrameSlotsContainer

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

        -- Counter text (like WoW's item count display)
        local count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        count:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -2, 2)
        count:SetJustifyH("RIGHT")
        count:Hide()

        slot.icon = icon
        slot.count = count
        slot.item = nil
        itemSlots[i] = slot
    end

    Log("Created " .. MAX_SLOTS .. " item slots")
end

-- Rebuild entire bag UI from inventory data
function EreaRpPlayerInventory:RefreshBag()
    Log("RefreshBag called, inventory count: " .. table.getn(EreaRpPlayerDB.inventory))

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
        slot.icon:Hide()
        slot.count:Hide()
        slot.item = nil

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
                item = inventory.GetFullItem(instance, EreaRpPlayerDB.syncedDatabase)
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

                -- Object name always in white
                GameTooltip:AddLine(currentItem.name, 1, 1, 1)  -- White

                if currentItem.tooltip and currentItem.tooltip ~= "" then
                    GameTooltip:AddLine(currentItem.tooltip, 1, 0.82, 0, 1)
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
            end)

            slot:SetScript("OnLeave", function()
                GameTooltip:Hide()
                GameTooltip:ClearAllPoints()
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
        if not slot.item then
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
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Failed to send show message!", 1, 0, 0)
        Log("ERROR: Failed to send SHOW message")
        return
    end

    Log("SHOW message sent for item: " .. item.name)

    -- Display feedback to user (unless silent for batch operations)
    if not silent then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FFFF[RP Player]|r Offering to show '%s' to %s (waiting for response)...", item.name, targetName), 0, 1, 1)
    end
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
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r You deleted: %s", item.name), 1, 0.5, 0)
    Log("Item deleted successfully")
end

-- Trade item with another player
function EreaRpPlayerInventory:TradeItem(item, targetName)
    Log("TradeItem called - Item: " .. tostring(item.name) .. ", Target: " .. tostring(targetName))

    -- Send message (messaging.lua handles creation + distribution + sending)
    -- Pass full item for player-to-player (receiver doesn't have sender's inventory)
    local success = messaging.SendTradeMessage(targetName, item)

    if not success then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Failed to send trade message!", 1, 0, 0)
        Log("ERROR: Failed to send TRADE message")
        return
    end

    Log("TRADE message sent for item: " .. item.name)

    -- Store pending trade (will be removed on acceptance)
    -- Global state in rp-player.lua
    EreaRpPlayer_PendingOutgoingTrade = item

    -- Display feedback to user
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r Offering '%s' to %s (waiting for response)...", item.name, targetName), 0, 1, 0)
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

    -- Store item for use in callbacks
    RPPlayerContextMenuFrame.contextItem = item
    RPPlayerContextMenuFrame.raidMembers = raidMembers
    RPPlayerContextMenuFrame.totalMembers = table.getn(allMembers)

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
                    local playerNames = {}
                    for _, playerName in ipairs(RPPlayerContextMenuFrame.raidMembers) do
                        EreaRpPlayerInventory:ShowItem(item, playerName, true)  -- silent = true to suppress individual messages
                        table.insert(playerNames, playerName)
                    end
                    if table.getn(playerNames) > 0 then
                        local namesList = table.concat(playerNames, ", ")
                        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FFFF[RP Player]|r Offering to show '%s' to: %s (waiting for responses)...", item.name, namesList), 0, 1, 1)
                    else
                        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FFFF[RP Player]|r No nearby players to show '%s'", item.name), 0, 1, 1)
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
