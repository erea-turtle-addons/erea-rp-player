-- ============================================================================
-- dialogs.lua - StaticPopup Dialog Definitions
-- ============================================================================
-- PURPOSE: Defines all StaticPopup dialogs used by the player addon
--
-- DIALOGS:
--   - EreaRpPlayer_DELETE_ITEM: Confirm item deletion
--   - EreaRpPlayer_MODIFY_CONTENT: Edit item content (legacy, may be removed)
--   - EreaRpPlayer_SHOW_REQUEST: Accept/decline item show from another player
--   - EreaRpPlayer_GIVE_REQUEST: Accept/decline item from GM
--   - EreaRpPlayer_TRADE_REQUEST: Accept/decline item trade from player
--   - EreaRpPlayer_DRAG_TO_PLAYER: Choose Give or Show when dragging to player
--
-- DEPENDENCIES:
--   - Global state variables (EreaRpPlayer_Pending*)
--   - Global functions (EreaRpPlayer_DeleteItem, EreaRpPlayer_ReadItem, etc.)
--   - messaging module (from turtle-rp-common)
--   - rpActions module (from turtle-rp-common)
--   - EreaRpPlayerDB (SavedVariable)
--   - Log function
--
-- PATTERN: StaticPopup system is WoW's built-in modal dialog framework
-- ============================================================================

-- ============================================================================
-- IMPORTS
-- ============================================================================
local messaging = EreaRpLibraries:Messaging()
local rpActions = EreaRpLibraries:RPActions()
local Log = EreaRpLibraries:Logging("RPPlayer")

-- ============================================================================
-- Delete Item Confirmation Dialog
-- ============================================================================
StaticPopupDialogs["EreaRpPlayer_DELETE_ITEM"] = {
    text = "Delete '%s'?",
    button1 = "Delete",
    button2 = "Cancel",
    OnAccept = function()
        if EreaRpPlayer_PendingDeleteItem then
            EreaRpPlayer_DeleteItem(EreaRpPlayer_PendingDeleteItem)
            EreaRpPlayer_PendingDeleteItem = nil
        end
    end,
    OnCancel = function()
        EreaRpPlayer_PendingDeleteItem = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true
}

-- ============================================================================
-- Modify Content Dialog (Legacy) - May be removed in future
-- ============================================================================
-- NOTE: This dialog may be deprecated in favor of player-actions.lua system
StaticPopupDialogs["EreaRpPlayer_MODIFY_CONTENT"] = {
    text = "Modify '%s':\n\n",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = 1,
    maxLetters = 500,
    OnAccept = function()
        local newContent = getglobal(this:GetParent():GetName().."EditBox"):GetText()
        if not newContent or newContent == "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Content cannot be empty!", 1, 0, 0)
            return
        end

        -- Get item and action from dialog data
        local data = getglobal(this:GetParent():GetName()).data
        if not data or not data.item or not data.action then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Error: Dialog data missing!", 1, 0, 0)
            return
        end

        -- Execute ModifyContent action with new content
        local playerName = UnitName("player")
        local result = rpActions.ExecuteAction(playerName, data.item, data.action.id, {newContent = newContent})

        if result.result == rpActions.ACTION_RESULTS.SUCCESS then
            -- Update item content in inventory by slot (unique identifier)
            for i, invItem in ipairs(EreaRpPlayerDB.inventory) do
                if invItem.slot == data.item.slot then
                    invItem.content = newContent
                    break
                end
            end

            EreaRpPlayer_RefreshBag()
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[RP Player]|r Content modified: " .. data.item.name, 0, 1, 0)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[RP Player]|r Failed to modify content: " .. tostring(result.message), 1, 0, 0)
        end
    end,
    OnShow = function()
        -- Pre-fill with current content
        local data = getglobal(this:GetName()).data
        if data and data.item and data.item.content then
            getglobal(this:GetName().."EditBox"):SetText(data.item.content)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true
}

-- ============================================================================
-- Show Item Request Dialog
-- ============================================================================
-- Another player wants to show you an item (preview without transfer)
StaticPopupDialogs["EreaRpPlayer_SHOW_REQUEST"] = {
    text = "\n|cFF00FFFF%s wants to show you %s\n\n",
    button1 = "Look",
    button2 = "Ignore",
    OnAccept = function()
        if EreaRpPlayer_PendingShowItem then
            -- Show the read frame with the item content, including who showed it
            EreaRpPlayer_ReadItem(EreaRpPlayer_PendingShowItem, EreaRpPlayer_PendingShowSender)

            -- Send acceptance message to chat
            if EreaRpPlayer_PendingShowSender then
                DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You accepted to view '%s' from %s", EreaRpPlayer_PendingShowItem.name, EreaRpPlayer_PendingShowSender), 0, 1, 0)
            end

            EreaRpPlayer_PendingShowItem = nil
            EreaRpPlayer_PendingShowSender = nil
        end
    end,
    OnCancel = function()
        if EreaRpPlayer_PendingShowSender and EreaRpPlayer_PendingShowItem then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r You rejected to view '%s' from %s", EreaRpPlayer_PendingShowItem.name, EreaRpPlayer_PendingShowSender), 1, 0, 0)

            -- Send rejection notification back to sender
            local myName = UnitName("player")
            messaging.SendShowRejectMessage(EreaRpPlayer_PendingShowSender, myName, EreaRpPlayer_PendingShowItem.name)
            Log("Sent SHOW_REJECT to " .. EreaRpPlayer_PendingShowSender)
        end
        EreaRpPlayer_PendingShowItem = nil
        EreaRpPlayer_PendingShowSender = nil
    end,
    timeout = 20,
    whileDead = true,
    hideOnEscape = true
}

-- ============================================================================
-- GIVE Request Dialog (from GM)
-- ============================================================================
-- GM is giving the player an item (like finding a quest item)
StaticPopupDialogs["EreaRpPlayer_GIVE_REQUEST"] = {
    text = "\n|cFFFFD700%s|r\n",
    button1 = "Take it",
    button2 = "Leave it",
    OnAccept = function()
        if EreaRpPlayer_PendingGiveItem and EreaRpPlayer_PendingGiveObjectDef then
            -- Add instance to inventory (v0.2.1: instance data only)
            table.insert(EreaRpPlayerDB.inventory, EreaRpPlayer_PendingGiveItem)
            EreaRpPlayer_RefreshBag()

            -- Send acceptance message
            local myName = UnitName("player")
            messaging.SendGiveAcceptMessage(EreaRpPlayer_PendingGiveSender, myName, EreaRpPlayer_PendingGiveObjectDef.name)
            Log("Sent GIVE_ACCEPT to " .. EreaRpPlayer_PendingGiveSender)

            -- Display message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You accepted '%s' from %s", EreaRpPlayer_PendingGiveObjectDef.name, EreaRpPlayer_PendingGiveSender), 0, 1, 0)

            -- Clear pending
            EreaRpPlayer_PendingGiveItem = nil
            EreaRpPlayer_PendingGiveObjectDef = nil
            EreaRpPlayer_PendingGiveSender = nil
            EreaRpPlayer_PendingGiveMessage = nil
        end
    end,
    OnCancel = function()
        if EreaRpPlayer_PendingGiveSender and EreaRpPlayer_PendingGiveObjectDef then
            -- Send rejection message
            local myName = UnitName("player")
            messaging.SendGiveRejectMessage(EreaRpPlayer_PendingGiveSender, myName, EreaRpPlayer_PendingGiveObjectDef.name)
            Log("Sent GIVE_REJECT to " .. EreaRpPlayer_PendingGiveSender)

            -- Display message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r You declined '%s' from %s", EreaRpPlayer_PendingGiveObjectDef.name, EreaRpPlayer_PendingGiveSender), 1, 0, 0)
        end

        -- Clear pending
        EreaRpPlayer_PendingGiveItem = nil
        EreaRpPlayer_PendingGiveObjectDef = nil
        EreaRpPlayer_PendingGiveSender = nil
        EreaRpPlayer_PendingGiveMessage = nil
    end,
    timeout = 30,
    whileDead = true,
    hideOnEscape = true
}

-- ============================================================================
-- TRADE Request Dialog (from another player)
-- ============================================================================
-- Another player wants to give you an item (player-to-player transfer)
StaticPopupDialogs["EreaRpPlayer_TRADE_REQUEST"] = {
    text = "\n|cFF00FF00%s wants to give you %s\n\n",
    button1 = "Accept",
    button2 = "Decline",
    OnAccept = function()
        if EreaRpPlayer_PendingTradeItem and EreaRpPlayer_PendingTradeObjectDef then
            -- Debug logging before adding item
            local beforeCount = table.getn(EreaRpPlayerDB.inventory)
            Log("TRADE_ACCEPT: Before adding item - inventory count: " .. beforeCount)

            -- Add instance to inventory (v0.2.1: instance data only)
            table.insert(EreaRpPlayerDB.inventory, EreaRpPlayer_PendingTradeItem)

            -- Debug logging after adding item
            local afterCount = table.getn(EreaRpPlayerDB.inventory)
            Log("TRADE_ACCEPT: After adding item - inventory count: " .. afterCount .. " (added guid: " .. tostring(EreaRpPlayer_PendingTradeItem.guid) .. ")")

            EreaRpPlayer_RefreshBag()

            -- Send acceptance message
            local myName = UnitName("player")
            messaging.SendTradeAcceptMessage(EreaRpPlayer_PendingTradeSender, myName, EreaRpPlayer_PendingTradeObjectDef.name)
            Log("Sent TRADE_ACCEPT to " .. EreaRpPlayer_PendingTradeSender)

            -- Display message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFF00FF00[RP Player]|r You accepted '%s' from %s", EreaRpPlayer_PendingTradeObjectDef.name, EreaRpPlayer_PendingTradeSender), 0, 1, 0)

            -- Clear pending
            EreaRpPlayer_PendingTradeItem = nil
            EreaRpPlayer_PendingTradeObjectDef = nil
            EreaRpPlayer_PendingTradeSender = nil
        end
    end,
    OnCancel = function()
        if EreaRpPlayer_PendingTradeSender and EreaRpPlayer_PendingTradeObjectDef then
            -- Send rejection message
            local myName = UnitName("player")
            messaging.SendTradeRejectMessage(EreaRpPlayer_PendingTradeSender, myName, EreaRpPlayer_PendingTradeObjectDef.name)
            Log("Sent TRADE_REJECT to " .. EreaRpPlayer_PendingTradeSender)

            -- Display message
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF0000[RP Player]|r You declined '%s' from %s", EreaRpPlayer_PendingTradeObjectDef.name, EreaRpPlayer_PendingTradeSender), 1, 0, 0)
        end

        -- Clear pending
        EreaRpPlayer_PendingTradeItem = nil
        EreaRpPlayer_PendingTradeObjectDef = nil
        EreaRpPlayer_PendingTradeSender = nil
    end,
    timeout = 30,
    whileDead = true,
    hideOnEscape = true
}

-- ============================================================================
-- Drag-to-Player Dialog
-- ============================================================================
-- When player drags an item to another player's portrait, choose Give or Show
StaticPopupDialogs["EreaRpPlayer_DRAG_TO_PLAYER"] = {
    text = "\n|cFFFFFFFF%s to %s:\n\n",
    button1 = "Give",
    button2 = "Show",
    OnAccept = function()
        if EreaRpPlayer_PendingDragItem and EreaRpPlayer_PendingDragTarget then
            -- Give (trade) the item
            EreaRpPlayer_TradeItem(EreaRpPlayer_PendingDragItem, EreaRpPlayer_PendingDragTarget)

            -- Clear pending
            EreaRpPlayer_PendingDragItem = nil
            EreaRpPlayer_PendingDragTarget = nil
        end
    end,
    OnShow = function()
        -- Override button2's click handler to trigger Show action
        -- In WoW 1.12, button2 normally triggers OnCancel, so we need custom handling
        local dialog = this
        local button2 = getglobal(dialog:GetName().."Button2")
        if button2 then
            button2:SetScript("OnClick", function()
                -- Show action
                if EreaRpPlayer_PendingDragItem and EreaRpPlayer_PendingDragTarget then
                    EreaRpPlayer_ShowItem(EreaRpPlayer_PendingDragItem, EreaRpPlayer_PendingDragTarget)

                    -- Clear pending
                    EreaRpPlayer_PendingDragItem = nil
                    EreaRpPlayer_PendingDragTarget = nil
                end

                -- Hide dialog
                dialog:Hide()
            end)
        end
    end,
    OnCancel = function()
        -- ESC pressed or X clicked - cancel action (do nothing, item stays)
        EreaRpPlayer_PendingDragItem = nil
        EreaRpPlayer_PendingDragTarget = nil
    end,
    OnHide = function()
        -- Final cleanup when dialog closes
        EreaRpPlayer_PendingDragItem = nil
        EreaRpPlayer_PendingDragTarget = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    exclusive = true
}
