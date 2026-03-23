-- ============================================================================
-- rp-actions.lua - Item Action System for Turtle RP Addons (v0.2.0)
-- ============================================================================
-- PURPOSE: Define and execute multi-method actions with parameters
--
-- RESPONSIBILITIES:
--   - Method registry (schema-driven parameter definitions)
--   - Multi-method action execution (sequential)
--   - Built-in action methods (DestroyObject, CreateObject, AddText, etc.)
--   - Action validation and parameter schema
--
-- ARCHITECTURE (v0.2.0):
--   - Actions contain multiple methods (methods array)
--   - Each method has paramSchema defining GUI and validation
--   - ExecuteAction runs methods sequentially
--   - Uses item.customText and item.customNumber for instance data
--
-- USAGE:
--   local rpActions = EreaRpLibraries:RPActions()
--   rpActions.ExecuteAction(playerName, item, actionId)
-- ============================================================================

-- Import dependencies
local messaging = EreaRpLibraries:Messaging()
local objectDatabase = EreaRpLibraries:ObjectDatabase()
local Log = EreaRpLibraries:Logging("RPActions")

-- ============================================================================
-- CONSTANTS
-- ============================================================================

local RESULT_TYPES = {
    SUCCESS = "SUCCESS",
    DESTROY_ITEM = "DESTROY_ITEM",
    UPDATE_ITEM = "UPDATE_ITEM",
    REQUEST_INPUT = "REQUEST_INPUT",
    CREATE_OBJECT = "CREATE_OBJECT",
    FAIL = "FAIL",
    ERROR = "ERROR"
}

-- ============================================================================
-- METHOD REGISTRY (v0.2.0)
-- ============================================================================
-- Schema-driven method definitions with parameter requirements
-- ============================================================================

local METHOD_REGISTRY = {
    -- ========================================================================
    -- DestroyObject - Remove item from inventory
    -- ========================================================================
    DestroyObject = {
        name = "Destroy Object",
        description = "Removes this object from inventory",
        requiresParams = false,
        paramSchema = {},
        execute = function(playerName, item, params)
            return {
                result = RESULT_TYPES.DESTROY_ITEM,
                message = item.name .. " has been destroyed",
                data = {}
            }
        end
    },

    -- ========================================================================
    -- CreateObject - Create new object in player inventory
    -- ========================================================================
    CreateObject = {
        name = "Create Object",
        description = "Creates a new object in player inventory",
        requiresParams = true,
        paramSchema = {
            {
                key = "objectGuid",
                type = "object_dropdown",
                label = "Object to create",
                required = true
            },
            {
                key = "customText",
                type = "text_with_placeholder",
                label = "Custom text for new object",
                required = false,
                placeholder = "{custom-text}"
            },
            {
                key = "additionalText",
                type = "text_with_placeholder",
                label = "Additional text for new object",
                required = false,
                placeholder = "{additional-text}"
            },
            {
                key = "customNumber",
                type = "number",
                label = "Counter for new object",
                required = false,
                placeholder = "{item-counter}"
            }
        },
        execute = function(playerName, item, params)
            if not params.objectGuid then
                return {
                    result = RESULT_TYPES.FAIL,
                    message = "No object GUID specified",
                    data = {}
                }
            end

            -- Resolve {custom-text}, {additional-text}, {item-counter}, {player-name} placeholders from source item
            local customText    = objectDatabase.ApplyItemPlaceholders(params.customText    or "", item.customText, item.additionalText, item.customNumber, playerName)
            local additionalText = objectDatabase.ApplyItemPlaceholders(params.additionalText or "", item.customText, item.additionalText, item.customNumber, playerName)

            -- customNumber param may contain {item-counter} — resolve then convert to number
            local customNumberStr = objectDatabase.ApplyItemPlaceholders(tostring(params.customNumber or ""), item.customText, item.additionalText, item.customNumber, playerName)
            local customNumber = tonumber(customNumberStr) or 0

            return {
                result = RESULT_TYPES.CREATE_OBJECT,
                message = "Creating object...",
                data = {
                    objectGuid = params.objectGuid,
                    customText = customText,
                    additionalText = additionalText,
                    customNumber = customNumber
                }
            }
        end
    },

    -- ========================================================================
    -- AddText - Request user input to set customText
    -- ========================================================================
    -- Uses item.contentTemplate for display formatting with {custom-text} placeholder
    AddText = {
        name = "Set Custom Text",
        description = "Prompts user for custom text input",
        requiresParams = true,
        paramSchema = {
            {
                key = "instruction",
                type = "text",
                label = "Instruction text (shown to user)",
                required = true
            }
        },
        execute = function(playerName, item, params)
            return {
                result = RESULT_TYPES.REQUEST_INPUT,
                message = "Requesting user input...",
                data = {
                    instruction = params.instruction or "Enter custom text:"
                }
            }
        end
    },

    -- ========================================================================
    -- ConsumeCharge - Decrement customNumber, destroy at 0
    -- ========================================================================
    ConsumeCharge = {
        name = "Consume Charge",
        description = "Decrements customNumber, destroys item at 0",
        requiresParams = false,
        paramSchema = {},
        execute = function(playerName, item, params)
            if not item.customNumber or item.customNumber <= 0 then
                return {
                    result = RESULT_TYPES.FAIL,
                    message = "No charges remaining",
                    data = {}
                }
            end

            item.customNumber = item.customNumber - 1

            if item.customNumber == 0 then
                return {
                    result = RESULT_TYPES.DESTROY_ITEM,
                    message = item.name .. " has been consumed (no charges remaining)",
                    data = {}
                }
            else
                return {
                    result = RESULT_TYPES.UPDATE_ITEM,
                    message = "Charges remaining: " .. item.customNumber,
                    data = {
                        customNumber = item.customNumber
                    }
                }
            end
        end
    },

    -- ========================================================================
    -- DisplayCinematic - Broadcast cinematic dialogue to nearby players
    -- ========================================================================
    DisplayCinematic = {
        name = "Display Cinematic",
        description = "Shows cinematic dialogue with 3D portrait to nearby players",
        requiresParams = true,
        paramSchema = {
            {
                key = "cinematicId",
                type = "cinematic_editor",
                label = "Cinematic",
                required = true
            }
        },
        execute = function(playerName, item, params)
            if not params.cinematicId or params.cinematicId == "" then
                return {
                    result = RESULT_TYPES.FAIL,
                    message = "Cinematic ID is required",
                    data = {}
                }
            end

            -- Send trigger to GM; GM will look up cinematic and broadcast
            messaging.SendCinematicTriggerMessage(
                params.cinematicId,
                item.customText    or "",
                item.additionalText or "",
                item.customNumber  or 0
            )

            return {
                result = RESULT_TYPES.SUCCESS,
                message = "Cinematic trigger sent",
                data = {}
            }
        end
    },

    -- ========================================================================
    -- MergeCinematic - Sends a merge trigger to the GM for group merging
    -- ========================================================================
    MergeCinematic = {
        name = "Merge Cinematic",
        description = "Notifies the GM of a merge trigger. When enough players trigger the same group, a merged cinematic is sent.",
        requiresParams = true,
        paramSchema = {
            {
                key = "mergeGroup",
                type = "merge_group_dropdown",
                label = "Merge Group",
                required = true,
                tooltip = "Select which merge group this item belongs to"
            }
        },
        execute = function(playerName, item, params)
            if not params.mergeGroup or params.mergeGroup == "" then
                return {
                    result = RESULT_TYPES.FAIL,
                    message = "Merge group is required",
                    data = {}
                }
            end

            Log("MergeCinematic: sending MERGE_TRIGGER for " .. playerName .. " mergeGroup=" .. params.mergeGroup)
            local sent = messaging.SendMergeTriggerMessage(params.mergeGroup, item.guid or "", item.customNumber or 0)
            Log("MergeCinematic: MERGE_TRIGGER sent=" .. tostring(sent))

            return {
                result = RESULT_TYPES.SUCCESS,
                message = "Merge trigger sent",
                data = {}
            }
        end
    }
}

-- ============================================================================
-- CORE ACTION SYSTEM
-- ============================================================================

-- ============================================================================
-- FindActionById - Find action definition in item's actions array
-- ============================================================================
local function FindActionById(item, actionId)
    if not item or not item.actions then
        return nil
    end

    for i = 1, table.getn(item.actions) do
        local action = item.actions[i]
        if action.id == actionId then
            return action
        end
    end

    return nil
end

-- ============================================================================
-- ValidateAction - Validate action definition (v0.2.0: supports methods array)
-- ============================================================================
local function ValidateAction(action)
    if not action then
        return false, "Action is nil"
    end

    if not action.id or action.id == "" then
        return false, "Action missing id"
    end

    -- v0.2.0: Check for methods array
    if not action.methods then
        return false, "Action missing methods array"
    end

    if table.getn(action.methods) == 0 then
        return false, "Action has no methods"
    end

    -- Validate each method
    for i = 1, table.getn(action.methods) do
        local method = action.methods[i]

        if not method.type or method.type == "" then
            return false, "Method " .. i .. " missing type"
        end

        if not METHOD_REGISTRY[method.type] then
            return false, "Unknown method type: " .. tostring(method.type)
        end
    end

    return true, nil
end

-- ============================================================================
-- ExecuteAction - Main entry point for executing multi-method actions (v0.2.0)
-- ============================================================================
-- @param playerName: Player executing the action
-- @param item: Item object with actions
-- @param actionId: ID of action to execute
-- @returns: { result, message, data }
--
-- FLOW:
--   1. Find action in item.actions by actionId
--   2. Validate action definition
--   3. Execute each method sequentially
--   4. Return result (early exit on REQUEST_INPUT)
-- ============================================================================
local function ExecuteAction(playerName, item, actionId)
    -- Find action definition
    local action = FindActionById(item, actionId)
    if not action then
        return {
            result = RESULT_TYPES.ERROR,
            message = "Action not found: " .. tostring(actionId),
            data = nil
        }
    end

    -- Validate action
    local valid, errorMsg = ValidateAction(action)
    if not valid then
        return {
            result = RESULT_TYPES.ERROR,
            message = errorMsg,
            data = nil
        }
    end

    -- Send lightweight status if action requests it (at beginning of execution)
    if action.sendStatus then
        messaging.SendStatusLiteMessage()
    end

    -- Execute methods sequentially
    local results = {}
    for i = 1, table.getn(action.methods) do
        local method = action.methods[i]
        local methodDef = METHOD_REGISTRY[method.type]

        if methodDef then
            -- Merge method params with default params
            local params = method.params or {}

            -- Execute method
            local success, result = pcall(methodDef.execute, playerName, item, params)

            if not success then
                -- Handler threw error
                return {
                    result = RESULT_TYPES.ERROR,
                    message = "Method execution failed: " .. tostring(result),
                    data = nil
                }
            end

            table.insert(results, result)

            -- Early exit for REQUEST_INPUT (player needs to provide input first)
            if result.result == RESULT_TYPES.REQUEST_INPUT then
                return result
            end

            -- Early exit for errors
            if result.result == RESULT_TYPES.ERROR or result.result == RESULT_TYPES.FAIL then
                return result
            end
        end
    end

    -- Return results (if multiple, wrap in MULTIPLE array)
    if table.getn(results) == 0 then
        return {
            result = RESULT_TYPES.SUCCESS,
            message = "Action completed",
            data = {}
        }
    elseif table.getn(results) == 1 then
        return results[1]
    else
        -- Multiple results - return array
        return {
            result = "MULTIPLE",
            message = "Multiple actions executed",
            data = {
                results = results
            }
        }
    end
end

-- ============================================================================
-- GetMethodRegistry - Get complete method registry
-- ============================================================================
local function GetMethodRegistry()
    return METHOD_REGISTRY
end

-- ============================================================================
-- GetMethodSchema - Get parameter schema for a method type
-- ============================================================================
local function GetMethodSchema(methodType)
    local method = METHOD_REGISTRY[methodType]
    return method and method.paramSchema or {}
end

-- ============================================================================
-- GetAvailableMethods - Get list of available method types for GUI
-- ============================================================================
local function GetAvailableMethods()
    local methods = {}
    for methodType, methodDef in pairs(METHOD_REGISTRY) do
        table.insert(methods, {
            type = methodType,
            name = methodDef.name,
            description = methodDef.description
        })
    end
    return methods
end

-- ============================================================================
-- SanitizeItemLibrary - Remove obsolete method types from all items
-- ============================================================================
-- @param itemLibrary: EreaRpMasterDB.itemLibrary hash table
-- @returns: { methodsRemoved = N, actionsRemoved = N }
-- ============================================================================
local function SanitizeItemLibrary(itemLibrary)
    local result = { methodsRemoved = 0, actionsRemoved = 0 }
    if not itemLibrary then return result end

    for itemId, item in pairs(itemLibrary) do
        if item and item.actions then
            local cleanedActions = {}

            for i = 1, table.getn(item.actions) do -- Lua 5.0: no # operator
                local action = item.actions[i]
                if action and action.methods then
                    local cleanedMethods = {}

                    for j = 1, table.getn(action.methods) do -- Lua 5.0: no # operator
                        local method = action.methods[j]
                        if method and method.type and METHOD_REGISTRY[method.type] then
                            table.insert(cleanedMethods, method)
                        elseif method and method.type then
                            result.methodsRemoved = result.methodsRemoved + 1
                            Log("SanitizeItemLibrary: removed obsolete method '" ..
                                tostring(method.type) .. "' from action '" ..
                                tostring(action.label or action.id) .. "' on item '" ..
                                tostring(item.name or itemId) .. "'"
                            )
                        end
                    end

                    action.methods = cleanedMethods

                    if table.getn(cleanedMethods) > 0 then -- Lua 5.0: no # operator
                        table.insert(cleanedActions, action)
                    else
                        result.actionsRemoved = result.actionsRemoved + 1
                        Log("SanitizeItemLibrary: removed empty action '" ..
                            tostring(action.label or action.id) .. "' from item '" ..
                            tostring(item.name or itemId) .. "' (no valid methods remaining)"
                        )
                    end
                elseif action then
                    table.insert(cleanedActions, action)
                end
            end

            item.actions = cleanedActions
        end
    end

    return result
end

-- ============================================================================
-- EXPORT FUNCTIONS
-- ============================================================================

-- ============================================================================
-- EreaRpLibraries:RPActions - Get RP actions system
-- ============================================================================
-- @returns: Table - RP actions utilities
--
-- USAGE:
--   local rpActions = EreaRpLibraries:RPActions()
--   rpActions.ExecuteAction(playerName, item, actionId)
-- ============================================================================
function EreaRpLibraries:RPActions()
    return {
        -- Core execution
        ExecuteAction = ExecuteAction,
        FindActionById = FindActionById,
        ValidateAction = ValidateAction,

        -- Method registry
        GetMethodRegistry = GetMethodRegistry,
        GetMethodSchema = GetMethodSchema,
        GetAvailableMethods = GetAvailableMethods,

        -- Database maintenance
        SanitizeItemLibrary = SanitizeItemLibrary,

        -- Constants
        RESULT_TYPES = RESULT_TYPES
    }
end
