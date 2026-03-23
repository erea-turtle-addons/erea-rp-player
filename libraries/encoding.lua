-- Base64 character set (for encoding/decoding)
local base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- ============================================================================
-- BASE64 ENCODING/DECODING
-- ============================================================================
-- MOVED FROM: Core.lua (Base64Decode) and RPPlayer.lua (both functions)
-- WHY: Eliminate code duplication
-- ============================================================================

-- ============================================================================
-- Base64Decode() - Decode Base64 string to original bytes
-- ============================================================================
-- @param data: Base64-encoded string
-- @returns: Decoded string
--
-- ALGORITHM:
--   1. Build reverse lookup table (char -> 0-63)
--   2. Process 4 Base64 chars at a time
--   3. Each 4 chars = 24 bits = 3 bytes
--   4. Handle padding ('=') for partial groups
--
-- EXAMPLE: "SGVsbG8=" -> "Hello"
-- ============================================================================
local function Base64Decode(data)
    if not data or data == "" then return "" end

    -- Create reverse lookup table: Maps each Base64 char to its numeric value (0-63)
    -- Example: 'A' -> 0, 'B' -> 1, 'z' -> 51, '9' -> 61
    local decode_table = {}
    for i = 1, string.len(base64_chars) do
        decode_table[string.sub(base64_chars, i, i)] = i - 1  -- Lua is 1-indexed, Base64 is 0-indexed
    end

    local result = {}  -- Array to collect decoded bytes
    local len = string.len(data)

    -- Process 4 Base64 characters at a time (each chunk decodes to 3 bytes)
    for i = 1, len, 4 do
        -- Extract 4 Base64 chars and convert to numeric values (0-63)
        local c1 = decode_table[string.sub(data, i, i)] or 0
        local c2 = decode_table[string.sub(data, i + 1, i + 1)] or 0
        local c3 = decode_table[string.sub(data, i + 2, i + 2)] or 0
        local c4 = decode_table[string.sub(data, i + 3, i + 3)] or 0

        -- Combine 4 six-bit values into one 24-bit number
        local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4

        -- Extract 3 bytes from the 24-bit number
        -- Lua 5.0: Use math.mod() instead of % operator for modulo
        local b1 = math.mod(math.floor(n / 65536), 256)  -- First byte (bits 16-23)
        local b2 = math.mod(math.floor(n / 256), 256)    -- Second byte (bits 8-15)
        local b3 = math.mod(n, 256)                       -- Third byte (bits 0-7)

        -- Always output first byte
        table.insert(result, string.char(b1))

        -- Only output second byte if not padding
        if string.sub(data, i + 2, i + 2) ~= "=" then
            table.insert(result, string.char(b2))
        end

        -- Only output third byte if not padding
        if string.sub(data, i + 3, i + 3) ~= "=" then
            table.insert(result, string.char(b3))
        end
    end

    return table.concat(result)  -- Join array of chars into single string
end

-- ============================================================================
-- Base64Encode() - Encode string to Base64
-- ============================================================================
-- @param data: String to encode
-- @returns: Base64-encoded string
--
-- ALGORITHM:
--   1. Process 3 bytes at a time
--   2. Each 3 bytes = 24 bits = 4 Base64 chars (6 bits each)
--   3. Handle partial groups with padding ('=')
--
-- EXAMPLE: "Hello" -> "SGVsbG8="
-- ============================================================================
local function Base64Encode(data)
    if not data or data == "" then return "" end

    local result = {}
    local len = string.len(data)

    -- Process 3 bytes at a time
    for i = 1, len, 3 do
        local b1 = string.byte(data, i)
        local b2 = string.byte(data, i + 1) or 0
        local b3 = string.byte(data, i + 2) or 0

        -- Combine 3 bytes into one 24-bit number
        local n = b1 * 65536 + b2 * 256 + b3

        -- Extract 4 six-bit values (0-63) and convert to Base64 chars
        -- Lua 5.0: Use math.mod() instead of % operator
        local c1 = math.mod(math.floor(n / 262144), 64) + 1  -- +1 because Lua is 1-indexed
        local c2 = math.mod(math.floor(n / 4096), 64) + 1
        local c3 = math.mod(math.floor(n / 64), 64) + 1
        local c4 = math.mod(n, 64) + 1

        -- Always output first 2 chars
        table.insert(result, string.sub(base64_chars, c1, c1))
        table.insert(result, string.sub(base64_chars, c2, c2))

        -- Output third char or padding
        if i + 1 <= len then
            table.insert(result, string.sub(base64_chars, c3, c3))
        else
            table.insert(result, "=")
        end

        -- Output fourth char or padding
        if i + 2 <= len then
            table.insert(result, string.sub(base64_chars, c4, c4))
        else
            table.insert(result, "=")
        end
    end

    return table.concat(result)
end

-- ============================================================================
-- EreaRpLibraries:Encoding - Get encoding utilities
-- ============================================================================
-- @returns: Table - Encoding utilities (Base64Decode, Base64Encode)
--
-- USAGE:
--   local encoding = EreaRpLibraries:Encoding()
--   local encoded = encoding.Base64Encode("Hello")
--   local decoded = encoding.Base64Decode(encoded)
-- ============================================================================
function EreaRpLibraries:Encoding()
    return {
        Base64Decode = Base64Decode,
        Base64Encode = Base64Encode,
    }
end