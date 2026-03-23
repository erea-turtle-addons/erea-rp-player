-- ============================================================================
-- INVENTORY MANAGEMENT
-- ============================================================================
-- MOVED FROM: RPPlayer.lua (FindNextAvailableSlot, GetItemAtSlot)
-- NEW: AddItemToInventory, RemoveItemFromInventory, SwapItemSlots, IsBagFull
-- ============================================================================

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local MAX_INVENTORY_SLOTS = 16  -- Maximum number of slots in RP bag

-- ============================================================================
-- FindNextAvailableSlot() - Find first empty slot in inventory
-- ============================================================================
-- @param inventory: Array of items (with slot field)
-- @returns: Slot number (1-16) or nil if full
-- ============================================================================
local function FindNextAvailableSlot(inventory)
    if not inventory then return nil end

    local usedSlots = {}

    -- Mark all used slots
    for _, item in ipairs(inventory) do
        if item.slot then
            usedSlots[item.slot] = true
        end
    end

    -- Find first empty slot
    for i = 1, MAX_INVENTORY_SLOTS do
        if not usedSlots[i] then
            return i
        end
    end

    return nil -- Bag is full
end

-- ============================================================================
-- GetItemAtSlot() - Get item at specific slot
-- ============================================================================
-- @param inventory: Array of items
-- @param slotIndex: Slot number (1-16)
-- @returns: Item or nil
-- ============================================================================
local function GetItemAtSlot(inventory, slotIndex)
    if not inventory or not slotIndex then return nil end

    for _, item in ipairs(inventory) do
        if item.slot == slotIndex then
            return item
        end
    end

    return nil
end

-- ============================================================================
-- IsSlotEmpty() - Check if slot is empty
-- ============================================================================
-- @param inventory: Array of items
-- @param slotIndex: Slot number
-- @returns: boolean
-- ============================================================================
local function IsSlotEmpty(inventory, slotIndex)
    return GetItemAtSlot(inventory, slotIndex) == nil
end

-- ============================================================================
-- AddItemToInventory() - Add item to inventory
-- ============================================================================
-- @param inventory: Array of items
-- @param item: Item to add
-- @param slotIndex: Optional slot (auto-assigned if nil)
-- @returns: success (boolean), assignedSlot (number or nil)
-- ============================================================================
local function AddItemToInventory(inventory, item, slotIndex)
    if not inventory or not item then
        return false, nil
    end

    -- Auto-assign slot if not specified
    if not slotIndex then
        slotIndex = FindNextAvailableSlot(inventory)
        if not slotIndex then
            return false, nil  -- Bag full
        end
    end

    -- Check if slot is occupied
    if not IsSlotEmpty(inventory, slotIndex) then
        return false, nil  -- Slot occupied
    end

    -- Add slot to item
    item.slot = slotIndex
    table.insert(inventory, item)

    return true, slotIndex
end

-- ============================================================================
-- RemoveItemFromInventory() - Remove item from inventory
-- ============================================================================
-- @param inventory: Array of items
-- @param slotIndex: Slot to clear
-- @returns: removedItem or nil
-- ============================================================================
local function RemoveItemFromInventory(inventory, slotIndex)
    if not inventory or not slotIndex then return nil end

    for i, item in ipairs(inventory) do
        if item.slot == slotIndex then
            table.remove(inventory, i)
            return item
        end
    end

    return nil
end

-- ============================================================================
-- SwapItemSlots() - Swap items between two slots
-- ============================================================================
-- @param inventory: Array of items
-- @param slot1: First slot
-- @param slot2: Second slot
-- @returns: success (boolean)
-- ============================================================================
local function SwapItemSlots(inventory, slot1, slot2)
    if not inventory or not slot1 or not slot2 then
        return false
    end

    local item1 = GetItemAtSlot(inventory, slot1)
    local item2 = GetItemAtSlot(inventory, slot2)

    if item1 then
        item1.slot = slot2
    end
    if item2 then
        item2.slot = slot1
    end

    return true
end

-- ============================================================================
-- GetUsedSlots() - Get number of used slots
-- ============================================================================
-- @param inventory: Array of items
-- @returns: count
-- ============================================================================
local function GetUsedSlots(inventory)
    if not inventory then return 0 end

    local count = 0
    for _, item in ipairs(inventory) do
        if item.slot then
            count = count + 1
        end
    end
    return count
end

-- ============================================================================
-- GetEmptySlotCount() - Get number of empty slots
-- ============================================================================
-- @param inventory: Array of items
-- @returns: count
-- ============================================================================
local function GetEmptySlotCount(inventory)
    return MAX_INVENTORY_SLOTS - GetUsedSlots(inventory)
end

-- ============================================================================
-- IsBagFull() - Check if bag is full
-- ============================================================================
-- @param inventory: Array of items
-- @returns: boolean
-- ============================================================================
local function IsBagFull(inventory)
    return GetEmptySlotCount(inventory) == 0
end

-- ============================================================================
-- CreateItemInstance() - Create instance data (minimal storage)
-- ============================================================================
-- @param guid: Object GUID
-- @param customText: Instance-specific text (default "")
-- @param additionalText: Second instance-specific text slot (default "")
-- @param customNumber: Instance-specific number (default 0)
-- @param slot: Slot index (optional, auto-assigned if nil)
-- @returns: Item instance table
--
-- PURPOSE: Store only instance-specific data in inventory
-- Object definition (name, icon, content, actions) stored separately in syncedDatabase
-- ============================================================================
local function CreateItemInstance(guid, customText, additionalText, customNumber, slot)
    return {
        guid = guid,
        customText = customText or "",
        additionalText = additionalText or "",
        customNumber = customNumber or 0,
        slot = slot
    }
end

-- ============================================================================
-- GetFullItem() - Merge instance data + object definition
-- ============================================================================
-- @param instance: Item instance from inventory {guid, customText, customNumber, slot}
-- @param syncedDatabase: Full database {items: {[guid]: objectDef}}
-- @returns: Full item table (merged) or nil if object not found
--
-- PURPOSE: At runtime, merge instance data with object definition
-- Allows GM to update definitions without affecting player instances
-- ============================================================================
local function GetFullItem(instance, syncedDatabase)
    if not instance or not instance.guid then
        return nil
    end

    -- Look up object definition by GUID
    local objectDef = nil
    if syncedDatabase and syncedDatabase.items then
        for id, obj in pairs(syncedDatabase.items) do
            if obj.guid == instance.guid then
                objectDef = obj
                break
            end
        end
    end

    if not objectDef then
        -- Object not found in database (might be system item or out of sync)
        return nil
    end

    -- Merge definition + instance data
    return {
        guid = instance.guid,
        name = objectDef.name,
        icon = objectDef.icon,
        tooltip = objectDef.tooltip,
        content = objectDef.content,
        contentTemplate = objectDef.contentTemplate,
        actions = objectDef.actions,  -- Shared reference (read-only)
        recipe = objectDef.recipe,    -- Shared reference (read-only)
        customText = instance.customText,
        additionalText = instance.additionalText,
        customNumber = instance.customNumber,
        slot = instance.slot
    }
end


-- ============================================================================
-- Export Functions
-- ============================================================================

-- ============================================================================
-- EreaRpLibraries:Inventory - Get inventory management utilities
-- ============================================================================
-- @returns: Table - Inventory utilities and constants
--
-- USAGE:
--   local inventory = EreaRpLibraries:Inventory()
--   local slot = inventory.FindNextAvailableSlot(playerInventory)
--   inventory.AddItemToInventory(playerInventory, item)
-- ============================================================================
function EreaRpLibraries:Inventory()
    return {
        -- Inventory operations
        FindNextAvailableSlot = FindNextAvailableSlot,
        GetItemAtSlot = GetItemAtSlot,
        IsSlotEmpty = IsSlotEmpty,
        AddItemToInventory = AddItemToInventory,
        RemoveItemFromInventory = RemoveItemFromInventory,
        SwapItemSlots = SwapItemSlots,
        GetUsedSlots = GetUsedSlots,
        GetEmptySlotCount = GetEmptySlotCount,
        IsBagFull = IsBagFull,

        -- Instance data management (v0.2.1: minimize SavedVariables size)
        CreateItemInstance = CreateItemInstance,
        GetFullItem = GetFullItem,

        -- Constants
        MAX_INVENTORY_SLOTS = MAX_INVENTORY_SLOTS
    }
end