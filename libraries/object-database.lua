-- ============================================================================
-- objectDatabase.lua - Shared database logic for RP Master and Player addons
-- ============================================================================
-- PURPOSE: Common database operations and structures used by both addons
-- ============================================================================

-- ============================================================================
-- Database Structure Definitions
-- ============================================================================

-- ============================================================================
-- GUID Generation Functions
-- ============================================================================

-- Generate a globally unique identifier for an item
-- Incorporates checksum of name to ensure uniqueness
local function GenerateGUID(name)
    local timestamp = time()  -- WoW global: Unix timestamp
    local random = math.random(10000000, 99999999)  -- 8-digit random number (existing approach)
    
    -- Create a simple checksum from the name if provided
    local checksum = ""
    if name then
        -- Simple hash function using basic string operations for Lua 5.0 compatibility
        local hash = 2166136261  -- FNV offset basis
        local prime = 16777619   -- FNV prime
        
        for i = 1, string.len(name) do
            local byte = string.byte(name, i)
            -- Manual XOR implementation without using ~ operator
            -- This is a simplified approach that should work in WoW's Lua 5.0
            hash = hash + byte * prime
            -- Keep hash within reasonable bounds to prevent overflow issues
            -- Lua 5.0: No hex literals, use decimal (2147483647 = 2^31 - 1)
            if hash > 2147483647 then
                hash = math.mod(hash, 2147483647)
            end
        end
        checksum = string.format("%08x", hash)
    end
    
    return timestamp .. "-" .. random .. (checksum ~= "" and "-" .. checksum or "")
end

-- ============================================================================
-- Base64 Encoding (for message transmission)
-- ============================================================================
-- ALGORITHM: Encodes binary data → printable ASCII (safe for addon messages)
-- INPUT: Plain text string
-- OUTPUT: Base64-encoded string (uses alphabet: A-Za-z0-9+/)
-- PADDING: Uses '=' for incomplete 3-byte groups
-- ============================================================================

local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Helper: Extract single character from base64 alphabet by index
local function base64char(index)
    return string.sub(base64_chars, index + 1, index + 1)  -- Lua 5.0: 1-indexed
end

-- ============================================================================
-- Checksum Functions
-- ============================================================================

-- Calculate a simple checksum for database consistency verification
-- This is a basic implementation - can be enhanced for better security if needed
local function CalculateDatabaseChecksum(databaseItems)
    if not databaseItems then return "" end

    -- Create a string representation of the database items
    local dbString = ""
    for id, item in pairs(databaseItems) do
        -- Serialize actions for checksum (v0.2.0: include methods)
        -- Lua 5.0: Use pairs() for robustness against hash tables
        local actionsStr = ""
        if item.actions then
            for i = 1, table.getn(item.actions) do
                local action = item.actions[i]
                actionsStr = actionsStr .. (action.id or "") .. ":" .. (action.label or "")

                -- Include methods in checksum
                if action.methods then
                    actionsStr = actionsStr .. "["
                    for j, method in pairs(action.methods) do
                        if type(j) == "number" and method.type then
                            actionsStr = actionsStr .. method.type
                        end
                    end
                    actionsStr = actionsStr .. "]"
                end

                -- Include sendStatus in checksum
                if action.sendStatus then
                    actionsStr = actionsStr .. ":sendStatus"
                end
            end
        end

        local recipeStr = ""
        if item.recipe and item.recipe.ingredients then
            recipeStr = tostring(item.recipe.ingredients[1] or "") ..
                ":" .. tostring(item.recipe.ingredients[2] or "") ..
                ":" .. tostring(item.recipe.cinematicKey or "") ..
                ":" .. tostring(item.recipe.notifyGm or false)
        end

        dbString = dbString ..
            tostring(id) ..
            "|" .. tostring(item.name or "") ..
            "|" .. tostring(item.icon or "") ..
            "|" .. tostring(item.tooltip or "") ..
            "|" .. tostring(item.content or "") ..
            "|" .. tostring(item.contentTemplate or "") ..
            "|" .. tostring(item.defaultHandoutText or "") ..
            "|" .. tostring(item.initialCounter or 0) ..
            "|" .. tostring(item.initialCustomText or "") ..
            "|" .. tostring(item.guid or "") ..
            "|" .. recipeStr ..
            "|" .. actionsStr
    end
    
    -- Simple hash function using basic string operations for Lua 5.0 compatibility
    local hash = 2166136261  -- FNV offset basis
    local prime = 16777619   -- FNV prime
    
    for i = 1, string.len(dbString) do
        local byte = string.byte(dbString, i)
        -- Simple hash calculation without XOR operator for full WoW Lua 5.0 compatibility
        hash = hash + byte * prime
        -- Keep hash within reasonable bounds to prevent overflow issues
        -- Lua 5.0: No hex literals, use decimal (2147483647 = 2^31 - 1)
        if hash > 2147483647 then
            hash = math.mod(hash, 2147483647)
        end
    end
    
    return string.format("%08x", hash)
end

-- ============================================================================
-- Database Operations
-- ============================================================================

-- Create an object based on the ITEM_SCHEMA structure
local function CreateObject(guid, name, icon, tooltip, content, actions, contentTemplate, initialCounter, defaultHandoutText, recipe)
    -- Validate required fields
    if not name then
        error("Object creation failed: 'name' is required")
    end

    return {
        guid = guid or GenerateGUID(name),
        name = name,
        icon = icon or "",
        tooltip = tooltip or "",
        content = content or "",
        contentTemplate = contentTemplate or "",
        actions = actions or {},
        initialCounter = tonumber(initialCounter) or 0,
        defaultHandoutText = defaultHandoutText or "You found this item, check /rpplayer",
        recipe = recipe or nil  -- recipe = { ingredients = {"guidA","guidB"}, cinematicKey = "", notifyGm = false }
    }
end

-- Create a database with metadata based on DATABASE_METADATA structure
local function CreateDatabase(guid, name, version, checksum)
    -- Validate required fields
    if not name then
        error("Database creation failed: 'name' is required")
    end
    if not version then
        error("Database creation failed: 'version' is required")
    end
    
    return {
        guid = guid or GenerateGUID(name),
        name = name,
        version = version,
        checksum = checksum or ""
    }
end

-- Create a committed snapshot of the database with metadata
-- databaseId: stable GUID for this campaign; generated once and reused across commits
local function CreateCommittedDatabase(itemLibrary, databaseName, cinematicLibrary, scriptLibrary, databaseId)
    -- Create a deep copy of the item library
    local committedCopy = {}
    for id, item in pairs(itemLibrary) do
        -- Deep copy actions array (v0.2.0: include methods array)
        -- Lua 5.0: Use pairs() for robustness against hash tables
        local actionsCopy = {}
        if item.actions then
            for i = 1, table.getn(item.actions) do
                local action = item.actions[i]

                -- Deep copy methods array
                local methodsCopy = {}
                if action.methods then
                    for j = 1, table.getn(action.methods) do
                        local method = action.methods[j]
                        local methodCopy = {
                            type = method.type
                        }

                        -- Deep copy params
                        if method.params then
                            methodCopy.params = {}
                            for key, value in pairs(method.params) do
                                methodCopy.params[key] = value
                            end
                        end

                        table.insert(methodsCopy, methodCopy)
                    end
                end

                -- Deep copy conditions (v0.2.1)
                local conditionsCopy = {
                    customTextEmpty = false,
                    counterGreaterThanZero = false
                }
                if action.conditions then
                    conditionsCopy.customTextEmpty = action.conditions.customTextEmpty and true or false
                    conditionsCopy.counterGreaterThanZero = action.conditions.counterGreaterThanZero and true or false
                end

                local actionCopy = {
                    id = action.id,
                    label = action.label,
                    sendStatus = action.sendStatus or false,
                    methods = methodsCopy,
                    conditions = conditionsCopy
                }

                table.insert(actionsCopy, actionCopy)
            end
        end

        -- Deep copy recipe (if present)
        local recipeCopy = nil
        if item.recipe then
            recipeCopy = {
                ingredients = {},
                cinematicKey = item.recipe.cinematicKey or "",
                notifyGm = item.recipe.notifyGm and true or false
            }
            if item.recipe.ingredients then
                for ri = 1, table.getn(item.recipe.ingredients) do -- Lua 5.0: table.getn
                    table.insert(recipeCopy.ingredients, item.recipe.ingredients[ri])
                end
            end
        end

        committedCopy[id] = {
            id = item.id,
            guid = item.guid,
            name = item.name,
            icon = item.icon,
            tooltip = item.tooltip,
            content = item.content,
            contentTemplate = item.contentTemplate,  -- v0.2.0: Include contentTemplate
            defaultHandoutText = item.defaultHandoutText or "",
            initialCustomText = item.initialCustomText or "",
            actions = actionsCopy,
            initialCounter = item.initialCounter or 0,
            recipe = recipeCopy
        }
    end
    
    -- Deep copy cinematic library
    local cinematicsCopy = {}
    if cinematicLibrary then
        for id, cinematic in pairs(cinematicLibrary) do
            cinematicsCopy[id] = {
                speakerName = cinematic.speakerName or "",
                messageTemplate = cinematic.messageTemplate or "",
                animationKey = cinematic.animationKey or "",
                leftType = cinematic.leftType,
                leftPortraitUnit = cinematic.leftPortraitUnit,
                leftAnimationKey = cinematic.leftAnimationKey,
                leftLoopMode = cinematic.leftLoopMode,
                rightType = cinematic.rightType,
                rightPortraitUnit = cinematic.rightPortraitUnit,
                rightAnimationKey = cinematic.rightAnimationKey,
                rightLoopMode = cinematic.rightLoopMode
            }
        end
    end

    -- Deep copy script library
    local scriptsCopy = {}
    if scriptLibrary then
        for name, script in pairs(scriptLibrary) do
            scriptsCopy[name] = {
                name = script.name or name,
                description = script.description or "",
                body = script.body or ""
            }
        end
    end

    -- Calculate checksum
    local checksum = CalculateDatabaseChecksum(committedCopy)

    -- Return database with metadata
    return {
        items = committedCopy,
        cinematicLibrary = cinematicsCopy,
        scriptLibrary = scriptsCopy,
        metadata = {
            id = databaseId or string.format("%d-%d", time(), math.random(10000000, 99999999)),
            name = databaseName or "Unnamed Database",
            version = time(),
            checksum = checksum
        }
    }
end

-- Verify database integrity using checksum
local function VerifyDatabaseIntegrity(databaseItems, expectedChecksum)
    if not databaseItems or not expectedChecksum then return false end
    
    local calculatedChecksum = CalculateDatabaseChecksum(databaseItems)
    return calculatedChecksum == expectedChecksum
end

-- ============================================================================
-- Serialization/Deserialization Functions
-- ============================================================================

-- Escape special characters in strings for safe serialization
-- Lua 5.0: No string:gsub method, use string.gsub instead
local function EscapeString(str)
    if not str then return "" end

    -- Escape delimiters that we use for serialization
    -- Order matters: escape the escape character first
    local result = string.gsub(tostring(str), "\\", "\\\\")  -- Escape backslash
    result = string.gsub(result, ":", "\\:")                  -- Escape colon (action part delimiter)
    result = string.gsub(result, "|~|", "\\|\\~\\|")         -- Escape field separator
    result = string.gsub(result, "%^~%^", "\\^\\~\\^")       -- Escape item separator
    result = string.gsub(result, "#~#", "\\#\\~\\#")         -- Escape database separator

    return result
end

-- Unescape special characters after deserialization
-- Lua 5.0: Use string.gsub instead of string:gsub
local function UnescapeString(str)
    if not str then return "" end

    -- Unescape in reverse order
    local result = string.gsub(str, "\\#\\~\\#", "#~#")      -- Unescape database separator
    result = string.gsub(result, "\\%^\\~\\%^", "^~^")       -- Unescape item separator
    result = string.gsub(result, "\\|\\~\\|", "|~|")         -- Unescape field separator
    result = string.gsub(result, "\\:", ":")                  -- Unescape colon
    result = string.gsub(result, "\\\\", "\\")               -- Unescape backslash

    return result
end

-- Serialize a single item to string format
-- Format: guid|~|name|~|icon|~|tooltip|~|content|~|actions|~|contentTemplate
local function SerializeItem(item)
    if not item then return "" end

    -- Serialize actions array (v0.2.0: multi-method support)
    -- Format: action1@~@action2@~@action3
    -- Each action: id:label:[method1_type~method1_params|method2_type~method2_params]
    -- Params: key=value&key=value
    local actionsStr = ""
    if item.actions and table.getn(item.actions) > 0 then
        for i = 1, table.getn(item.actions) do
            local action = item.actions[i]
            if i > 1 then
                actionsStr = actionsStr .. "@~@"
            end

            -- Serialize action ID and label
            local actionStr = EscapeString(action.id or "") .. ":" ..
                            EscapeString(action.label or "") .. ":"

            -- Serialize methods array (v0.2.0)
            -- Lua 5.0: Use pairs() instead of table.getn() for robustness
            -- (SavedVariables can corrupt array structure on save/load)
            local methodsStr = "["
            if action.methods then
                local methodCount = 0
                local methodsArray = {}

                -- Collect methods from table (handles both array and hash table)
                for idx, method in pairs(action.methods) do
                    if type(idx) == "number" and method.type then
                        table.insert(methodsArray, {idx = idx, method = method})
                        methodCount = methodCount + 1
                    end
                end

                -- Sort by index to preserve order
                table.sort(methodsArray, function(a, b) return a.idx < b.idx end)

                -- Serialize sorted methods
                for i = 1, table.getn(methodsArray) do
                    local method = methodsArray[i].method
                    if i > 1 then
                        methodsStr = methodsStr .. "|"
                    end

                    -- Serialize method type
                    methodsStr = methodsStr .. EscapeString(method.type or "")

                    -- Serialize params if present
                    if method.params then
                        methodsStr = methodsStr .. "~"
                        local first = true
                        for key, value in pairs(method.params) do
                            if not first then
                                methodsStr = methodsStr .. "&"
                            end
                            methodsStr = methodsStr .. EscapeString(key) .. "=" .. EscapeString(tostring(value))
                            first = false
                        end
                    end
                end
            end
            methodsStr = methodsStr .. "]"

            actionStr = actionStr .. methodsStr

            -- Serialize conditions (v0.2.1)
            -- Format: :customTextEmpty,counterGreaterThanZero
            local conditionsStr = ":"
            if action.conditions then
                if action.conditions.customTextEmpty then
                    conditionsStr = conditionsStr .. "customTextEmpty"
                end
                if action.conditions.counterGreaterThanZero then
                    if conditionsStr ~= ":" then
                        conditionsStr = conditionsStr .. ","
                    end
                    conditionsStr = conditionsStr .. "counterGreaterThanZero"
                end
            end

            actionStr = actionStr .. conditionsStr

            -- Serialize sendStatus flag (v0.2.2)
            -- Format: :sendStatus (true/false)
            local sendStatusStr = ":"
            if action.sendStatus then
                sendStatusStr = sendStatusStr .. "sendStatus"
            end
            actionStr = actionStr .. sendStatusStr

            actionsStr = actionsStr .. actionStr
        end
    end

    -- Serialize recipe (9th field, optional — backward compat: old clients ignore extra field)
    -- Format: "guidA,guidB|cinematicKey|notifyGm"  or "" if no recipe
    local recipeStr = ""
    if item.recipe and item.recipe.ingredients and table.getn(item.recipe.ingredients) >= 2 then -- Lua 5.0: table.getn
        -- Build comma-separated ingredient GUIDs
        local ingStr = item.recipe.ingredients[1]
        for ri = 2, table.getn(item.recipe.ingredients) do -- Lua 5.0: table.getn
            ingStr = ingStr .. "," .. item.recipe.ingredients[ri]
        end
        recipeStr = EscapeString(ingStr) .. "|" ..
                    EscapeString(item.recipe.cinematicKey or "") .. "|" ..
                    (item.recipe.notifyGm and "1" or "0")
    end

    local parts = {
        EscapeString(item.guid or ""),
        EscapeString(item.name or ""),
        EscapeString(item.icon or ""),
        EscapeString(item.tooltip or ""),
        EscapeString(item.content or ""),
        actionsStr,  -- Don't escape the whole actions string as it contains structure
        EscapeString(item.contentTemplate or ""),
        EscapeString(tostring(item.initialCounter or 0)),
        recipeStr  -- 9th field: recipe (empty string if none — backward compat)
    }

    -- Lua 5.0: Manual concatenation instead of table.concat
    local result = parts[1]
    for i = 2, table.getn(parts) do
        result = result .. "|~|" .. parts[i]
    end

    return result
end

-- Deserialize a string back to an item
local function DeserializeItem(serialized)
    if not serialized or serialized == "" then return nil end

    -- Split by field separator |~|
    local parts = {}
    local current = ""
    local i = 1
    local len = string.len(serialized)

    -- Lua 5.0: Manual string parsing
    while i <= len do
        local char = string.sub(serialized, i, i)

        -- Check for field separator |~|
        if char == "|" and i + 2 <= len then
            local next3 = string.sub(serialized, i, i + 2)
            if next3 == "|~|" then
                table.insert(parts, current)
                current = ""
                i = i + 3
            else
                current = current .. char
                i = i + 1
            end
        else
            current = current .. char
            i = i + 1
        end
    end

    -- Add the last part
    if current ~= "" then
        table.insert(parts, current)
    end

    -- Lua 5.0: Use table.getn instead of #
    if table.getn(parts) < 5 then return nil end

    -- Parse actions (part 6, optional)
    local actions = {}
    if table.getn(parts) >= 6 and parts[6] ~= "" then
        -- Split actions by @~@
        local actionStrings = {}
        local current = ""
        local i = 1
        local len = string.len(parts[6])

        while i <= len do
            local char = string.sub(parts[6], i, i)

            if char == "@" and i + 2 <= len then
                local next3 = string.sub(parts[6], i, i + 2)
                if next3 == "@~@" then
                    table.insert(actionStrings, current)
                    current = ""
                    i = i + 3
                else
                    current = current .. char
                    i = i + 1
                end
            else
                current = current .. char
                i = i + 1
            end
        end

        if current ~= "" then
            table.insert(actionStrings, current)
        end

        -- Parse each action string (v0.2.0: multi-method support)
        for idx = 1, table.getn(actionStrings) do
            local actionStr = actionStrings[idx]

            -- Split by : to get id, label, methods_serialized
            local actionParts = {}
            current = ""
            i = 1
            len = string.len(actionStr)

            while i <= len do
                local char = string.sub(actionStr, i, i)
                if char == "\\" and i < len and string.sub(actionStr, i + 1, i + 1) == ":" then
                    current = current .. "\\:"  -- Keep escaped colon, do not split
                    i = i + 2
                elseif char == ":" then
                    table.insert(actionParts, current)
                    current = ""
                    i = i + 1
                else
                    current = current .. char
                    i = i + 1
                end
            end

            if current ~= "" then
                table.insert(actionParts, current)
            end

            if table.getn(actionParts) >= 3 then
                local action = {
                    id = UnescapeString(actionParts[1]),
                    label = UnescapeString(actionParts[2]),
                    methods = {}
                }

                -- Parse methods array (part 3): [method1_type~params|method2_type~params]
                local methodsStr = actionParts[3]
                if methodsStr and string.len(methodsStr) > 2 then
                    -- Strip [ and ]
                    methodsStr = string.sub(methodsStr, 2, string.len(methodsStr) - 1)

                    -- Split by | to get individual methods
                    local methodStrings = {}
                    current = ""
                    i = 1
                    len = string.len(methodsStr)

                    while i <= len do
                        local char = string.sub(methodsStr, i, i)
                        if char == "|" then
                            table.insert(methodStrings, current)
                            current = ""
                            i = i + 1
                        else
                            current = current .. char
                            i = i + 1
                        end
                    end

                    if current ~= "" then
                        table.insert(methodStrings, current)
                    end

                    -- Parse each method string (type~params)
                    for midx = 1, table.getn(methodStrings) do
                        local methodStr = methodStrings[midx]

                        -- Split by ~ to get type and params
                        local tildaPos = string.find(methodStr, "~")
                        local methodType = ""
                        local paramsStr = ""

                        if tildaPos then
                            methodType = string.sub(methodStr, 1, tildaPos - 1)
                            paramsStr = string.sub(methodStr, tildaPos + 1)
                        else
                            methodType = methodStr
                        end

                        local method = {
                            type = UnescapeString(methodType),
                            params = {}
                        }

                        -- Parse params if present (key=value&key=value)
                        if paramsStr and paramsStr ~= "" then
                            -- Split by & to get key=value pairs
                            local paramPairs = {}
                            current = ""
                            i = 1
                            len = string.len(paramsStr)

                            while i <= len do
                                local char = string.sub(paramsStr, i, i)
                                if char == "&" then
                                    table.insert(paramPairs, current)
                                    current = ""
                                    i = i + 1
                                else
                                    current = current .. char
                                    i = i + 1
                                end
                            end

                            if current ~= "" then
                                table.insert(paramPairs, current)
                            end

                            -- Parse each key=value pair
                            for pidx = 1, table.getn(paramPairs) do
                                local pair = paramPairs[pidx]
                                local eqPos = string.find(pair, "=")
                                if eqPos then
                                    local key = UnescapeString(string.sub(pair, 1, eqPos - 1))
                                    local value = UnescapeString(string.sub(pair, eqPos + 1))
                                    method.params[key] = value
                                end
                            end
                        end

                        table.insert(action.methods, method)
                    end
                end

                -- Parse conditions (v0.2.1) - part 4 if present
                action.conditions = {
                    customTextEmpty = false,
                    counterGreaterThanZero = false
                }
                if table.getn(actionParts) >= 4 and actionParts[4] ~= "" then
                    local conditionsStr = actionParts[4]
                    -- Parse comma-separated condition names
                    if string.find(conditionsStr, "customTextEmpty") then
                        action.conditions.customTextEmpty = true
                    end
                    if string.find(conditionsStr, "counterGreaterThanZero") then
                        action.conditions.counterGreaterThanZero = true
                    end
                end

                -- Parse sendStatus (v0.2.2) - part 5 if present
                action.sendStatus = false
                if table.getn(actionParts) >= 5 and actionParts[5] ~= "" then
                    local sendStatusStr = actionParts[5]
                    if string.find(sendStatusStr, "sendStatus") then
                        action.sendStatus = true
                    end
                end

                table.insert(actions, action)
            end
        end
    end

    -- Parse recipe (9th field, optional — backward compat)
    -- Format: "guidA,guidB|cinematicKey|notifyGm"
    local recipe = nil
    if table.getn(parts) >= 9 and parts[9] ~= "" then -- Lua 5.0: table.getn
        local recipeStr = parts[9]
        -- Split by first | to get ingredients_str
        local pipe1 = string.find(recipeStr, "|", 1, true)
        if pipe1 then
            local ingStr = string.sub(recipeStr, 1, pipe1 - 1)
            local rest   = string.sub(recipeStr, pipe1 + 1)
            -- Split rest by second | to get cinematicKey and notifyGm
            local pipe2 = string.find(rest, "|", 1, true)
            local cinematicKey = ""
            local notifyGmStr  = "0"
            if pipe2 then
                cinematicKey = string.sub(rest, 1, pipe2 - 1)
                notifyGmStr  = string.sub(rest, pipe2 + 1)
            else
                cinematicKey = rest
            end
            -- Parse ingredient GUIDs (comma-separated)
            local ingredients = {}
            local commaPos = string.find(ingStr, ",", 1, true)
            if commaPos then
                table.insert(ingredients, UnescapeString(string.sub(ingStr, 1, commaPos - 1)))
                table.insert(ingredients, UnescapeString(string.sub(ingStr, commaPos + 1)))
            end
            if table.getn(ingredients) >= 2 then -- Lua 5.0: table.getn
                recipe = {
                    ingredients  = ingredients,
                    cinematicKey = UnescapeString(cinematicKey),
                    notifyGm     = notifyGmStr == "1"
                }
            end
        end
    end

    return {
        guid = UnescapeString(parts[1]),
        name = UnescapeString(parts[2]),
        icon = UnescapeString(parts[3]),
        tooltip = UnescapeString(parts[4]),
        content = UnescapeString(parts[5]),
        actions = actions,
        contentTemplate = parts[7] and UnescapeString(parts[7]) or "",
        initialCounter = parts[8] and tonumber(UnescapeString(parts[8])) or 0,
        recipe = recipe
    }
end

-- Serialize an entire database including metadata and all items
-- Format: metadata#~#item1^~^item2^~^item3...
local function SerializeDatabase(database)
    if not database then return "" end

    -- Serialize metadata
    local metadata = database.metadata or {}
    local metadataParts = {
        EscapeString(metadata.id or ""),
        EscapeString(metadata.name or ""),
        EscapeString(tostring(metadata.version or "")),
        EscapeString(metadata.checksum or "")
    }

    -- Lua 5.0: Manual concatenation
    local metadataStr = metadataParts[1]
    for i = 2, table.getn(metadataParts) do
        metadataStr = metadataStr .. "|~|" .. metadataParts[i]
    end

    -- Serialize items
    local itemsStr = ""
    local items = database.items or {}
    local first = true

    -- Lua 5.0: pairs iteration
    for id, item in pairs(items) do
        if not first then
            itemsStr = itemsStr .. "^~^"
        end
        itemsStr = itemsStr .. SerializeItem(item)
        first = false
    end

    -- Serialize cinematic library
    -- Format: id|~|speakerName|~|messageTemplate|~|animationKey|~|leftType|~|leftPortraitUnit|~|leftAnimationKey|~|rightType|~|rightPortraitUnit|~|rightAnimationKey
    -- per cinematic, separated by ^~^
    local cinematicsStr = ""
    local cinematicLibrary = database.cinematicLibrary or {}
    local cFirst = true

    for id, cinematic in pairs(cinematicLibrary) do
        if not cFirst then
            cinematicsStr = cinematicsStr .. "^~^"
        end
        cinematicsStr = cinematicsStr ..
            EscapeString(id) .. "|~|" ..
            EscapeString(cinematic.speakerName or "") .. "|~|" ..
            EscapeString(cinematic.messageTemplate or "") .. "|~|" ..
            EscapeString(cinematic.animationKey or "") .. "|~|" ..
            EscapeString(cinematic.leftType or "") .. "|~|" ..
            EscapeString(cinematic.leftPortraitUnit or "") .. "|~|" ..
            EscapeString(cinematic.leftAnimationKey or "") .. "|~|" ..
            EscapeString(cinematic.rightType or "") .. "|~|" ..
            EscapeString(cinematic.rightPortraitUnit or "") .. "|~|" ..
            EscapeString(cinematic.rightAnimationKey or "") .. "|~|" ..
            EscapeString(cinematic.scriptReferences or "") .. "|~|" ..
            EscapeString(cinematic.leftLoopMode or "") .. "|~|" ..
            EscapeString(cinematic.rightLoopMode or "")
        cFirst = false
    end

    -- Serialize script library (4th section)
    -- Format: name|~|description|~|body per script, separated by ^~^
    local scriptsStr = ""
    local scriptLibrary = database.scriptLibrary or {}
    local sFirst = true

    for name, script in pairs(scriptLibrary) do
        if not sFirst then
            scriptsStr = scriptsStr .. "^~^"
        end
        scriptsStr = scriptsStr ..
            EscapeString(script.name or name) .. "|~|" ..
            EscapeString(script.description or "") .. "|~|" ..
            EscapeString(script.body or "")
        sFirst = false
    end

    -- Combine metadata, items, cinematics, and scripts (4 sections separated by #~#)
    return metadataStr .. "#~#" .. itemsStr .. "#~#" .. cinematicsStr .. "#~#" .. scriptsStr
end

-- Deserialize a database from string format
local function DeserializeDatabase(serialized)
    if not serialized or serialized == "" then return nil end

    -- Split into sections by #~# (metadata, items, cinematics, scripts)
    -- Parse all sections by splitting on #~#
    local sections = {}
    local secCurrent = ""
    local secI = 1
    local secLen = string.len(serialized)

    while secI <= secLen do
        local char = string.sub(serialized, secI, secI)
        if char == "#" and secI + 2 <= secLen then
            local next3 = string.sub(serialized, secI, secI + 2)
            if next3 == "#~#" then
                table.insert(sections, secCurrent)
                secCurrent = ""
                secI = secI + 3
            else
                secCurrent = secCurrent .. char
                secI = secI + 1
            end
        else
            secCurrent = secCurrent .. char
            secI = secI + 1
        end
    end
    table.insert(sections, secCurrent)

    -- Lua 5.0: table.getn
    if table.getn(sections) < 2 then return nil end

    local metadataStr = sections[1]
    local itemsStr = sections[2]
    local cinematicsStr = sections[3] or ""
    local scriptsStr = sections[4] or ""

    -- Parse metadata
    local metadataParts = {}
    local current = ""
    local i = 1
    local len = string.len(metadataStr)

    while i <= len do
        local char = string.sub(metadataStr, i, i)

        if char == "|" and i + 2 <= len then
            local next3 = string.sub(metadataStr, i, i + 2)
            if next3 == "|~|" then
                table.insert(metadataParts, current)
                current = ""
                i = i + 3
            else
                current = current .. char
                i = i + 1
            end
        else
            current = current .. char
            i = i + 1
        end
    end

    if current ~= "" then
        table.insert(metadataParts, current)
    end

    -- Lua 5.0: Use table.getn
    if table.getn(metadataParts) < 4 then return nil end

    local metadata = {
        id = UnescapeString(metadataParts[1]),
        name = UnescapeString(metadataParts[2]),
        version = tonumber(UnescapeString(metadataParts[3])) or 0,
        checksum = UnescapeString(metadataParts[4])
    }

    -- Parse items
    local items = {}
    if itemsStr ~= "" then
        -- Split items by ^~^
        local itemStrings = {}
        current = ""
        i = 1
        len = string.len(itemsStr)

        while i <= len do
            local char = string.sub(itemsStr, i, i)

            if char == "^" and i + 2 <= len then
                local next3 = string.sub(itemsStr, i, i + 2)
                if next3 == "^~^" then
                    table.insert(itemStrings, current)
                    current = ""
                    i = i + 3
                else
                    current = current .. char
                    i = i + 1
                end
            else
                current = current .. char
                i = i + 1
            end
        end

        if current ~= "" then
            table.insert(itemStrings, current)
        end

        -- Deserialize each item
        for idx = 1, table.getn(itemStrings) do
            local item = DeserializeItem(itemStrings[idx])
            if item then
                items[idx] = item
            end
        end
    end

    -- Parse cinematic library (third section, optional for backward compatibility)
    local cinematicLibrary = {}
    if cinematicsStr ~= "" then
        -- Split by ^~^
        local cinematicStrings = {}
        current = ""
        i = 1
        len = string.len(cinematicsStr)

        while i <= len do
            local char = string.sub(cinematicsStr, i, i)

            if char == "^" and i + 2 <= len then
                local next3 = string.sub(cinematicsStr, i, i + 2)
                if next3 == "^~^" then
                    table.insert(cinematicStrings, current)
                    current = ""
                    i = i + 3
                else
                    current = current .. char
                    i = i + 1
                end
            else
                current = current .. char
                i = i + 1
            end
        end

        if current ~= "" then
            table.insert(cinematicStrings, current)
        end

        -- Parse each cinematic: id|~|speakerName|~|messageTemplate|~|animationKey[|~|leftType|~|leftPortraitUnit|~|leftAnimationKey|~|rightType|~|rightPortraitUnit|~|rightAnimationKey]
        for idx = 1, table.getn(cinematicStrings) do -- Lua 5.0: table.getn
            local cStr = cinematicStrings[idx]
            local cParts = {}
            current = ""
            i = 1
            len = string.len(cStr)

            while i <= len do
                local char = string.sub(cStr, i, i)
                if char == "|" and i + 2 <= len then
                    local next3 = string.sub(cStr, i, i + 2)
                    if next3 == "|~|" then
                        table.insert(cParts, current)
                        current = ""
                        i = i + 3
                    else
                        current = current .. char
                        i = i + 1
                    end
                else
                    current = current .. char
                    i = i + 1
                end
            end

            if current ~= "" then
                table.insert(cParts, current)
            end

            if table.getn(cParts) >= 4 then -- Lua 5.0: table.getn
                local cinematicId = UnescapeString(cParts[1])
                local entry = {
                    speakerName = UnescapeString(cParts[2]),
                    messageTemplate = UnescapeString(cParts[3]),
                    animationKey = UnescapeString(cParts[4])
                }

                -- New fields (10 total parts): backward compat if < 10
                if table.getn(cParts) >= 10 then -- Lua 5.0: table.getn
                    local lt = UnescapeString(cParts[5])
                    if lt ~= "" then entry.leftType = lt end
                    local lpu = UnescapeString(cParts[6])
                    if lpu ~= "" then entry.leftPortraitUnit = lpu end
                    local lak = UnescapeString(cParts[7])
                    if lak ~= "" then entry.leftAnimationKey = lak end
                    local rt = UnescapeString(cParts[8])
                    if rt ~= "" then entry.rightType = rt end
                    local rpu = UnescapeString(cParts[9])
                    if rpu ~= "" then entry.rightPortraitUnit = rpu end
                    local rak = UnescapeString(cParts[10])
                    if rak ~= "" then entry.rightAnimationKey = rak end
                end

                -- Script references (11th part, optional for backward compatibility)
                if table.getn(cParts) >= 11 then -- Lua 5.0: table.getn
                    local sr = UnescapeString(cParts[11])
                    if sr ~= "" then entry.scriptReferences = sr end
                end

                -- Loop modes (fields 12-13, optional for backward compatibility)
                if table.getn(cParts) >= 13 then -- Lua 5.0: table.getn
                    local llm = UnescapeString(cParts[12])
                    if llm ~= "" then entry.leftLoopMode = llm end
                    local rlm = UnescapeString(cParts[13])
                    if rlm ~= "" then entry.rightLoopMode = rlm end
                end

                cinematicLibrary[cinematicId] = entry
            end
        end
    end

    -- Parse script library (4th section, optional for backward compatibility)
    local scriptLibrary = {}
    if scriptsStr ~= "" then
        -- Split by ^~^
        local scriptStrings = {}
        current = ""
        i = 1
        len = string.len(scriptsStr)

        while i <= len do
            local char = string.sub(scriptsStr, i, i)
            if char == "^" and i + 2 <= len then
                local next3 = string.sub(scriptsStr, i, i + 2)
                if next3 == "^~^" then
                    table.insert(scriptStrings, current)
                    current = ""
                    i = i + 3
                else
                    current = current .. char
                    i = i + 1
                end
            else
                current = current .. char
                i = i + 1
            end
        end

        if current ~= "" then
            table.insert(scriptStrings, current)
        end

        -- Parse each script: name|~|description|~|body
        for idx = 1, table.getn(scriptStrings) do -- Lua 5.0: table.getn
            local sStr = scriptStrings[idx]
            local sParts = {}
            current = ""
            i = 1
            len = string.len(sStr)

            while i <= len do
                local char = string.sub(sStr, i, i)
                if char == "|" and i + 2 <= len then
                    local next3 = string.sub(sStr, i, i + 2)
                    if next3 == "|~|" then
                        table.insert(sParts, current)
                        current = ""
                        i = i + 3
                    else
                        current = current .. char
                        i = i + 1
                    end
                else
                    current = current .. char
                    i = i + 1
                end
            end

            if current ~= "" then
                table.insert(sParts, current)
            end

            if table.getn(sParts) >= 3 then -- Lua 5.0: table.getn
                local scriptName = UnescapeString(sParts[1])
                scriptLibrary[scriptName] = {
                    name = scriptName,
                    description = UnescapeString(sParts[2]),
                    body = UnescapeString(sParts[3])
                }
            end
        end
    end

    return {
        metadata = metadata,
        items = items,
        cinematicLibrary = cinematicLibrary,
        scriptLibrary = scriptLibrary
    }
end

-- Compare two checksums to determine if database needs to be sent
local function NeedsDatabaseSync(localChecksum, remoteChecksum)
    -- If no remote checksum, sync is needed
    if not remoteChecksum or remoteChecksum == "" then
        return true
    end

    -- If no local checksum, something is wrong
    if not localChecksum or localChecksum == "" then
        return false
    end

    -- Compare checksums
    return localChecksum ~= remoteChecksum
end

-- ============================================================================
-- Chunked Transmission Functions
-- ============================================================================
-- WoW 1.12 SendAddonMessage has 255 byte limit - need to chunk large messages

local CHUNK_SIZE = 200  -- Safe limit under 255 bytes

-- Split a string into chunks
local function ChunkString(str, chunkSize)
    if not str then return {} end

    local chunks = {}
    local len = string.len(str)
    local pos = 1

    while pos <= len do
        local chunk = string.sub(str, pos, pos + chunkSize - 1)
        table.insert(chunks, chunk)
        pos = pos + chunkSize
    end

    return chunks
end

-- Create chunked DB_SYNC messages
-- Returns array of messages: DB_SYNC_START, DB_SYNC_CHUNK, DB_SYNC_END
local function CreateSyncMessageChunks(committedDatabase)
    if not committedDatabase or not committedDatabase.metadata then
        return nil
    end

    local encoding = EreaRpLibraries:Encoding()
    local meta = committedDatabase.metadata

    -- Serialize the database
    local serializedData = SerializeDatabase(committedDatabase)

    if not serializedData or serializedData == "" then
        return nil
    end

    -- Base64 encode the ENTIRE serialized data first to avoid pipe character issues
    -- The serialization uses |~| and ^~^ delimiters which WoW interprets as escape codes
    local encodedData = encoding.Base64Encode(serializedData)

    -- Generate a unique message ID for this sync operation
    local messageId = GenerateGUID("sync")

    -- Create header with metadata
    local header = "DB_SYNC_START^" ..
                   messageId .. "^" ..
                   (meta.id or "") .. "^" ..
                   (meta.name or "") .. "^" ..
                   tostring(meta.version or 0) .. "^" ..
                   (meta.checksum or "") .. "^" ..
                   tostring(string.len(encodedData))

    -- Split BASE64-ENCODED data into chunks (no pipe characters in Base64)
    local dataChunks = ChunkString(encodedData, CHUNK_SIZE)
    local totalChunks = table.getn(dataChunks)

    -- Build message array
    local messages = {}

    -- 1. Start message with metadata
    table.insert(messages, header)

    -- 2. Data chunks (already Base64 encoded, safe for SendAddonMessage)
    for i = 1, totalChunks do
        local chunkMsg = "DB_SYNC_CHUNK^" .. messageId .. "^" .. i .. "^" .. totalChunks .. "^" .. dataChunks[i]
        table.insert(messages, chunkMsg)
    end

    -- 3. End message
    local endMsg = "DB_SYNC_END^" .. messageId
    table.insert(messages, endMsg)

    return messages
end

-- Reassemble chunked database sync messages
-- Takes a table of received chunks and returns the full database
local function ReassembleChunkedSync(chunksTable)
    if not chunksTable or not chunksTable.metadata then
        return nil, "no chunksTable or metadata"
    end

    -- Check if all chunks received
    if table.getn(chunksTable.chunks) ~= chunksTable.totalChunks then
        return nil, "chunk count mismatch: got " .. table.getn(chunksTable.chunks) .. " expected " .. chunksTable.totalChunks
    end

    local encoding = EreaRpLibraries:Encoding()

    -- Reassemble Base64-encoded data in order
    local reassembledEncoded = ""
    for i = 1, chunksTable.totalChunks do
        if not chunksTable.chunks[i] then
            return nil, "missing chunk " .. i
        end
        reassembledEncoded = reassembledEncoded .. chunksTable.chunks[i]
    end

    -- Base64 decode the reassembled data
    local reassembledDecoded = encoding.Base64Decode(reassembledEncoded)

    if not reassembledDecoded or reassembledDecoded == "" then
        return nil, "Base64 decode failed (encoded length: " .. string.len(reassembledEncoded) .. ")"
    end

    -- Deserialize the database
    local database = DeserializeDatabase(reassembledDecoded)

    if not database or not database.items then
        return nil, "DeserializeDatabase failed"
    end

    return {
        items = database.items,
        cinematicLibrary = database.cinematicLibrary,
        scriptLibrary = database.scriptLibrary,
        metadata = chunksTable.metadata
    }
end

-- Prepare database for transmission (serialized string)
local function PrepareTransmission(database)
    if not database then return nil end

    return SerializeDatabase(database)
end

-- Receive and reconstruct database from transmission
local function ReceiveTransmission(serializedData)
    if not serializedData or serializedData == "" then
        return nil, "No data provided"
    end

    local database = DeserializeDatabase(serializedData)

    -- Check if deserialization failed
    if not database then
        return nil, "Failed to deserialize database"
    end

    -- Verify integrity if checksum is present
    if database.metadata and database.metadata.checksum then
        local valid = VerifyDatabaseIntegrity(database.items, database.metadata.checksum)
        if not valid then
            return nil, "Checksum verification failed"
        end
    end

    return database
end

-- ============================================================================
-- ApplyItemPlaceholders - Substitute all instance placeholders in any string
-- ============================================================================
-- @param text: String - Template text containing placeholders (may be nil or "")
-- @param customText: String - Value for {custom-text}
-- @param additionalText: String - Value for {additional-text}
-- @param customNumber: Number - Value for {item-counter}
-- @param playerName: String - Value for {player-name} (optional; falls back to UnitName("player"))
-- @return String - Text with all placeholders substituted
-- NOTE: Lua 5.0: hyphens in gsub patterns must be escaped as %-
-- ============================================================================
local function ApplyItemPlaceholders(text, customText, additionalText, customNumber, playerName)
    if not text or text == "" then return text or "" end
    text = string.gsub(text, "{custom%-text}",     customText                        or "")
    text = string.gsub(text, "{additional%-text}", additionalText                    or "")
    text = string.gsub(text, "{item%-counter}",    tostring(customNumber             or 0))
    text = string.gsub(text, "{player%-name}",     playerName or UnitName("player")  or "")
    return text
end

-- ============================================================================
-- RenderItemContent - Render item content with custom text substitution
-- ============================================================================
-- PURPOSE: Pure business logic for rendering item content (NO GUI code)
-- @param guid: String - Object GUID to look up in database
-- @param customText: String - Custom text to substitute for {custom-text} (may be nil or "")
-- @param additionalText: String - Text for {additional-text} placeholder (may be nil or "")
-- @param customNumber: Number - Value for {item-counter} placeholder (may be nil or 0)
-- @param database: Table - Database to look up object definition
-- @return String - Rendered content ready for display
-- ============================================================================
local function RenderItemContent(guid, customText, additionalText, customNumber, database)
    if not guid or not database or not database.items then
        return "This item has no content to read."
    end

    -- Look up object definition by GUID
    local objectDef = nil
    for _, obj in pairs(database.items) do
        if obj.guid == guid then
            objectDef = obj
            break
        end
    end

    if not objectDef then
        return "This item has no content to read."
    end

    -- Apply template substitution logic
    local displayContent = ""

    local hasCustomText = customText and customText ~= ""
    local hasAdditional = additionalText and additionalText ~= ""

    if (hasCustomText or hasAdditional) and objectDef.contentTemplate and objectDef.contentTemplate ~= "" then
        -- At least one text field set and template exists: substitute all placeholders
        displayContent = ApplyItemPlaceholders(objectDef.contentTemplate, customText, additionalText, customNumber)
    elseif hasCustomText then
        -- No template, fall back to showing customText directly
        displayContent = customText
    else
        -- No custom text fields set, use default content (still apply placeholders)
        displayContent = ApplyItemPlaceholders(objectDef.content or "", customText, additionalText, customNumber)
    end

    if displayContent == "" then
        return "This item has no content to read."
    end

    return displayContent
end

-- ============================================================================
-- Item CRUD Operations (for item library management)
-- ============================================================================

-- Update an existing item in the library
-- @param itemLibrary table - The item library array
-- @param itemId number - ID of item to update
-- @param updates table - Fields to update (name, icon, tooltip, content, etc.)
-- @return boolean, string - Success flag and error message if failed
local function UpdateItem(itemLibrary, itemId, updates)
    if not itemLibrary then return false, "No item library provided" end
    if not itemId then return false, "No item ID provided" end
    if not updates then return false, "No updates provided" end

    -- Lua 5.0: Use table.getn for array length
    for i = 1, table.getn(itemLibrary) do
        if itemLibrary[i] and itemLibrary[i].id == itemId then
            for key, value in pairs(updates) do
                -- Protect immutable fields
                if key ~= "id" and key ~= "guid" then
                    itemLibrary[i][key] = value
                end
            end
            return true, nil
        end
    end
    return false, "Item not found"
end

-- Delete an item from the library
-- @param itemLibrary table - The item library array
-- @param itemId number - ID of item to delete
-- @return boolean, table - Success flag and deleted item (or nil)
local function DeleteItem(itemLibrary, itemId)
    if not itemLibrary then return false, nil end
    if not itemId then return false, nil end

    -- Lua 5.0: Use table.getn for array length
    for i = 1, table.getn(itemLibrary) do
        if itemLibrary[i] and itemLibrary[i].id == itemId then
            local deleted = table.remove(itemLibrary, i)
            return true, deleted
        end
    end
    return false, nil
end

-- Get an item by ID
-- @param itemLibrary table - The item library array
-- @param itemId number - ID of item to retrieve
-- @return table|nil - Item or nil if not found
local function GetItem(itemLibrary, itemId)
    if not itemLibrary then return nil end
    if not itemId then return nil end

    -- Lua 5.0: Use table.getn for array length
    for i = 1, table.getn(itemLibrary) do
        if itemLibrary[i] and itemLibrary[i].id == itemId then
            return itemLibrary[i]
        end
    end
    return nil
end

-- Get all items (returns reference, not copy)
-- @param itemLibrary table - The item library array
-- @return table - All items
local function GetAllItems(itemLibrary)
    return itemLibrary or {}
end

-- Filter items by predicate function
-- @param itemLibrary table - The item library array
-- @param predicate function - Function(item) returns true to include
-- @return table - Filtered items (new array)
local function FilterItems(itemLibrary, predicate)
    if not itemLibrary then return {} end
    if not predicate then return {} end

    local results = {}
    -- Lua 5.0: Use table.getn for array length
    for i = 1, table.getn(itemLibrary) do
        if itemLibrary[i] and predicate(itemLibrary[i]) then
            table.insert(results, itemLibrary[i])
        end
    end
    return results
end

-- Generate next auto-increment ID
-- @param itemLibrary table - The item library array
-- @return number - Next available ID
local function GenerateNextItemId(itemLibrary)
    if not itemLibrary then return 1 end

    local maxId = 0
    -- Lua 5.0: Use table.getn for array length
    for i = 1, table.getn(itemLibrary) do
        if itemLibrary[i] and itemLibrary[i].id and itemLibrary[i].id > maxId then
            maxId = itemLibrary[i].id
        end
    end
    return maxId + 1
end

-- ============================================================================
-- Recipe / Forging Helper Functions
-- ============================================================================

-- FindRecipesContaining - Find all output items whose recipe includes itemGuid as ingredient
-- @param itemGuid: string - GUID of the ingredient to search for
-- @param items:    table  - Items table from synced database (keyed by numeric index)
-- @returns: array of { outputItem, otherIngredientGuids[] }
local function FindRecipesContaining(itemGuid, items)
    if not itemGuid or not items then return {} end
    local results = {}
    for _, item in pairs(items) do
        if item.recipe and item.recipe.ingredients then
            for _, ingGuid in ipairs(item.recipe.ingredients) do
                if ingGuid == itemGuid then
                    -- Collect the other ingredient GUIDs
                    local otherGuids = {}
                    for _, ingGuid2 in ipairs(item.recipe.ingredients) do
                        if ingGuid2 ~= itemGuid then
                            table.insert(otherGuids, ingGuid2)
                        end
                    end
                    table.insert(results, { outputItem = item, otherIngredientGuids = otherGuids })
                    break  -- each item appears once per output
                end
            end
        end
    end
    return results
end

-- GetRecipeSummaries - Build display summaries for all recipes the player can participate in
-- @param inv:   array  - Player inventory (instances with {guid, slot, ...})
-- @param items: table  - Items table from synced database
-- @returns: array of {
--   outputItem, sourceGuid, sourceSlot,
--   partnerGuid, partnerSlot (nil if not in inventory), partnerName,
--   cinematicKey, notifyGm
-- }
local function GetRecipeSummaries(inv, items)
    if not inv or not items then return {} end
    local results = {}

    for _, instance in ipairs(inv) do
        local itemGuid = instance.guid
        local recipes  = FindRecipesContaining(itemGuid, items)

        for _, recipeEntry in ipairs(recipes) do
            local outputItem = recipeEntry.outputItem

            for _, otherGuid in ipairs(recipeEntry.otherIngredientGuids) do
                -- Look up partner definition name
                local partnerName = ""
                for _, def in pairs(items) do
                    if def.guid == otherGuid then
                        partnerName = def.name or ""
                        break
                    end
                end

                -- Check if partner is present in inventory
                local partnerSlot = nil
                for _, partnerInstance in ipairs(inv) do
                    if partnerInstance.guid == otherGuid then
                        partnerSlot = partnerInstance.slot
                        break
                    end
                end

                table.insert(results, {
                    outputItem   = outputItem,
                    sourceGuid   = itemGuid,
                    sourceSlot   = instance.slot,
                    partnerGuid  = otherGuid,
                    partnerSlot  = partnerSlot,
                    partnerName  = partnerName,
                    cinematicKey = outputItem.recipe.cinematicKey or "",
                    notifyGm     = outputItem.recipe.notifyGm and true or false
                })
            end
        end
    end

    return results
end

-- FindRecipeForPair - Find output item whose recipe exactly uses both guidA and guidB
-- @param guidA: string - First item GUID
-- @param guidB: string - Second item GUID
-- @param items: table  - Items table from synced database
-- @returns: output item definition, or nil if no matching recipe
local function FindRecipeForPair(guidA, guidB, items)
    if not guidA or not guidB or not items then return nil end
    for _, item in pairs(items) do
        if item.recipe and item.recipe.ingredients then
            local hasA = false
            local hasB = false
            for _, ingGuid in ipairs(item.recipe.ingredients) do
                if ingGuid == guidA then hasA = true end
                if ingGuid == guidB then hasB = true end
            end
            if hasA and hasB then
                return item
            end
        end
    end
    return nil
end

-- ============================================================================
-- Export Functions
-- ============================================================================

-- ============================================================================
-- EreaRpLibraries:ObjectDatabase - Get object database utilities
-- ============================================================================
-- @returns: Table - Object database utilities
--
-- USAGE:
--   local objectDatabase = EreaRpLibraries:ObjectDatabase()
--   local guid = objectDatabase.GenerateGUID("ItemName")
--   local database = objectDatabase.CreateDatabase()
-- ============================================================================
function EreaRpLibraries:ObjectDatabase()
    return {
        -- Object creation
        CreateObject = CreateObject,
        CreateDatabase = CreateDatabase,

        -- GUID and checksums
        GenerateGUID = GenerateGUID,
        CalculateDatabaseChecksum = CalculateDatabaseChecksum,

        -- Database operations
        CreateCommittedDatabase = CreateCommittedDatabase,
        VerifyDatabaseIntegrity = VerifyDatabaseIntegrity,

        -- Serialization functions
        SerializeItem = SerializeItem,
        DeserializeItem = DeserializeItem,
        SerializeDatabase = SerializeDatabase,
        DeserializeDatabase = DeserializeDatabase,

        -- Transmission functions
        NeedsDatabaseSync = NeedsDatabaseSync,
        PrepareTransmission = PrepareTransmission,
        ReceiveTransmission = ReceiveTransmission,

        -- Chunked transmission functions (for 255 byte limit)
        CreateSyncMessageChunks = CreateSyncMessageChunks,
        ReassembleChunkedSync = ReassembleChunkedSync,

        -- String utility functions (exposed for testing)
        EscapeString = EscapeString,
        UnescapeString = UnescapeString,

        -- Content rendering (business logic)
        ApplyItemPlaceholders = ApplyItemPlaceholders,
        RenderItemContent = RenderItemContent,

        -- Item CRUD operations (for item library management)
        UpdateItem = UpdateItem,
        DeleteItem = DeleteItem,
        GetItem = GetItem,
        GetAllItems = GetAllItems,
        FilterItems = FilterItems,
        GenerateNextItemId = GenerateNextItemId,

        -- Recipe / forging helpers
        FindRecipesContaining = FindRecipesContaining,
        GetRecipeSummaries    = GetRecipeSummaries,
        FindRecipeForPair     = FindRecipeForPair
    }
end
