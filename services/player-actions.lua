-- ============================================================================
-- player-actions.lua - Player-side Action GUI for Turtle RP Player
-- ============================================================================
-- PURPOSE: Handle all GUI aspects of action execution on the player side
--
-- RESPONSIBILITIES:
--   - Display REQUEST_INPUT dialogs (Set Custom Text)
--   - Update inventory on DESTROY_ITEM and UPDATE_ITEM
--   - Handle CREATE_OBJECT requests
--   - Display messages for action results
--
-- ARCHITECTURE:
--   - rp-common/rp-actions.lua: Pure business logic (ExecuteAction)
--   - player-actions.lua: Player-side GUI (THIS FILE)
--   - Calls EreaRpPlayer_RefreshBag() to update inventory display
--   - Uses StaticPopupDialogs for user input
--
-- PATTERN: Prototype service - stateful, global prototype, accessed via wrappers
--
-- PUBLIC API:
--   - EreaRpPlayerActions:ExecuteAction(item, action) - Execute action and handle GUI result
--   - Global wrapper: EreaRpPlayer_ExecuteAction() in rp-player.lua
-- ============================================================================

-- ============================================================================
-- PROTOTYPE
-- ============================================================================
EreaRpPlayerActions = {}

-- Import dependencies (lazy loading to avoid initialization order issues)
local rpActions = nil
local function GetRPActions()
    if not rpActions then
        rpActions = EreaRpLibraries:RPActions()
    end
    return rpActions
end

local inventory = nil
local function GetInventory()
    if not inventory then
        inventory = EreaRpLibraries:Inventory()
    end
    return inventory
end

-- ============================================================================
-- Log() - Local logging function wrapper
-- ============================================================================
local function Log(message)
    if EreaRpPlayerDebugLog then
        -- WoW 1.12: No date() function, use simple logging
        local logEntry = string.format("RPPlayer: %s", tostring(message))
        table.insert(EreaRpPlayerDebugLog, logEntry)
        if table.getn(EreaRpPlayerDebugLog) > 500 then
            table.remove(EreaRpPlayerDebugLog, 1)
        end
    end
end

-- ============================================================================
-- STATIC POPUP DIALOGS
-- ============================================================================

-- ============================================================================
-- REQUEST_INPUT Dialog - For "Set Custom Text" action
-- ============================================================================
-- Shows popup asking for user input, stores directly in customText
-- Template formatting (contentTemplate with {custom-text}) happens on display
-- ============================================================================
StaticPopupDialogs["EreaRpPlayer_REQUEST_INPUT"] = {
    text = "%s",  -- Will be set dynamically in OnShow
    button1 = "OK",
    button2 = "Cancel",
    hasEditBox = 1,
    maxLetters = 150,  -- Match customText max length
    OnAccept = function()
        local userInput = getglobal(this:GetParent():GetName().."EditBox"):GetText()
        if not userInput or userInput == "" then
            return
        end

        -- Get item from global state (WoW 1.12 compat)
        if not EreaRpPlayer_PendingInputItem then
            return
        end

        -- Store user input directly in customText (no template substitution here)
        -- Template formatting happens when displaying via contentTemplate
        if string.len(userInput) > 150 then
            userInput = string.sub(userInput, 1, 150)
        end

        -- v0.2.1: Update instance customText in inventory (instances have only {guid, customText, customNumber, slot})
        for i, instance in ipairs(EreaRpPlayerDB.inventory) do
            if instance.slot == EreaRpPlayer_PendingInputItem.slot then
                instance.customText = userInput
                break
            end
        end

        -- Refresh UI to show updated text
        if EreaRpPlayer_RefreshBag then
            EreaRpPlayer_RefreshBag()
        end

        -- Clear global state
        EreaRpPlayer_PendingInputItem = nil
        EreaRpPlayer_PendingInputAction = nil
        EreaRpPlayer_PendingInputInstruction = nil
    end,
    OnShow = function()
        -- Clear edit box on show
        getglobal(this:GetName().."EditBox"):SetText("")

        -- Get instruction from global state (WoW 1.12 compat)
        if EreaRpPlayer_PendingInputInstruction then
            getglobal(this:GetName().."Text"):SetText(EreaRpPlayer_PendingInputInstruction)
        else
            getglobal(this:GetName().."Text"):SetText("Enter custom text for '" .. (EreaRpPlayer_PendingInputItem and EreaRpPlayer_PendingInputItem.name or "item") .. "':")
        end
    end,
    OnCancel = function()
        -- Clear global state
        EreaRpPlayer_PendingInputItem = nil
        EreaRpPlayer_PendingInputAction = nil
        EreaRpPlayer_PendingInputInstruction = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true
}

-- ============================================================================
-- GLOBAL STATE (WoW 1.12 StaticPopup compatibility)
-- ============================================================================
-- WoW 1.12: StaticPopup 4th parameter unreliable, use globals instead
EreaRpPlayer_PendingInputItem = nil
EreaRpPlayer_PendingInputAction = nil
EreaRpPlayer_PendingInputInstruction = nil

-- ============================================================================
-- RESULT HANDLERS
-- ============================================================================

-- ============================================================================
-- HandleRequestInput - Show input dialog for Set Custom Text
-- ============================================================================
local function HandleRequestInput(item, action, result)
    -- WoW 1.12: Use global variables instead of dialog data parameter
    EreaRpPlayer_PendingInputItem = item
    EreaRpPlayer_PendingInputAction = action
    EreaRpPlayer_PendingInputInstruction = result.data.instruction or "Enter custom text:"

    StaticPopup_Show("EreaRpPlayer_REQUEST_INPUT", item.name)
end

-- ============================================================================
-- HandleCreateObject - Create object instance in inventory
-- ============================================================================
local function HandleCreateObject(item, action, result)
    local objectGuid = result.data.objectGuid
    local customText = result.data.customText or ""
    local additionalText = result.data.additionalText or ""
    local customNumber = tonumber(result.data.customNumber) or 0

    -- Look up object definition from active database
    local activeDb = EreaRpPlayerDB and EreaRpPlayerDB.activeDatabaseId
                     and EreaRpPlayerDB.databases[EreaRpPlayerDB.activeDatabaseId]
    local objectDef = nil
    if activeDb and activeDb.items then
        for id, obj in pairs(activeDb.items) do
            if obj.guid == objectGuid then
                objectDef = obj
                break
            end
        end
    end

    if not objectDef then
        return
    end

    -- Check if bag is full
    local inventoryModule = GetInventory()
    if inventoryModule.IsBagFull(EreaRpPlayerDB.inventory) then
        return
    end

    -- Create instance (minimal data: guid, customText, additionalText, customNumber)
    local instance = inventoryModule.CreateItemInstance(objectGuid, customText, additionalText, customNumber)

    -- Add to inventory (auto-assigns slot)
    local success, assignedSlot = inventoryModule.AddItemToInventory(EreaRpPlayerDB.inventory, instance)
    if not success then
        return
    end

    -- Refresh UI
    if EreaRpPlayer_RefreshBag then
        EreaRpPlayer_RefreshBag()
    end

    -- Silent - no message needed for item creation
end

-- ============================================================================
-- HandleDestroyItem - Remove item from inventory and refresh UI
-- ============================================================================
local function HandleDestroyItem(item, action, result)
    -- Remove item from inventory
    if EreaRpPlayer_DeleteItem then
        EreaRpPlayer_DeleteItem(item)
    end
end

-- ============================================================================
-- HandleUpdateItem - Refresh UI to show updated item (e.g. charges)
-- ============================================================================
local function HandleUpdateItem(item, action, result)
    -- Update item in inventory if result.data contains updates
    if result.data then
        for i, invItem in ipairs(EreaRpPlayerDB.inventory) do
            if invItem.slot == item.slot then
                -- Update customNumber if provided (e.g. ConsumeCharge)
                if result.data.customNumber then
                    invItem.customNumber = result.data.customNumber
                end
                -- Update customText if provided
                if result.data.customText then
                    invItem.customText = result.data.customText
                end
                break
            end
        end
    end

    -- Refresh UI to show updated item
    if EreaRpPlayer_RefreshBag then
        EreaRpPlayer_RefreshBag()
    end

    -- Silent - no message needed for item updates (charges, etc.)
end

-- ============================================================================
-- HandleSuccess - Generic success message
-- ============================================================================
local function HandleSuccess(item, action, result)
end

-- ============================================================================
-- HandleFail - Action failed (not an error, just failed validation)
-- ============================================================================
local function HandleFail(item, action, result)
end

-- ============================================================================
-- HandleError - Execution error
-- ============================================================================
local function HandleError(item, action, result)
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================

-- ============================================================================
-- ExecuteAction - Execute action and handle GUI for result
-- ============================================================================
-- @param item: Table - Item object with actions
-- @param action: Table - Action object to execute
-- @returns: void
--
-- FLOW:
--   1. Call rpActions.ExecuteAction (business logic)
--   2. Handle result.result type (GUI logic)
--   3. Update inventory/UI as needed
-- ============================================================================
function EreaRpPlayerActions:ExecuteAction(item, action)
    Log("ExecuteAction called - Item: " .. tostring(item.name) .. ", Action: " .. tostring(action.id))

    local playerName = UnitName("player")
    local rpActions = GetRPActions()  -- Lazy load
    local result = rpActions.ExecuteAction(playerName, item, action.id)

    if not result then
        return
    end

    -- Dispatch to appropriate handler based on result type
    if result.result == "MULTIPLE" then
        -- Multiple results from sequential methods - process each
        if result.data and result.data.results then
            for i = 1, table.getn(result.data.results) do
                local subResult = result.data.results[i]
                -- Recursively process each result
                if subResult.result == rpActions.RESULT_TYPES.CREATE_OBJECT then
                    HandleCreateObject(item, action, subResult)
                elseif subResult.result == rpActions.RESULT_TYPES.DESTROY_ITEM then
                    HandleDestroyItem(item, action, subResult)
                elseif subResult.result == rpActions.RESULT_TYPES.UPDATE_ITEM then
                    HandleUpdateItem(item, action, subResult)
                elseif subResult.result == rpActions.RESULT_TYPES.SUCCESS then
                    HandleSuccess(item, action, subResult)
                elseif subResult.result == rpActions.RESULT_TYPES.FAIL then
                    HandleFail(item, action, subResult)
                elseif subResult.result == rpActions.RESULT_TYPES.ERROR then
                    HandleError(item, action, subResult)
                end
            end
        end

    elseif result.result == rpActions.RESULT_TYPES.REQUEST_INPUT then
        HandleRequestInput(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.CREATE_OBJECT then
        HandleCreateObject(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.DESTROY_ITEM then
        HandleDestroyItem(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.UPDATE_ITEM then
        HandleUpdateItem(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.SUCCESS then
        HandleSuccess(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.FAIL then
        HandleFail(item, action, result)

    elseif result.result == rpActions.RESULT_TYPES.ERROR then
        HandleError(item, action, result)

    end
end
