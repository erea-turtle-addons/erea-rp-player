-- ============================================================================
-- log-viewer.lua - Log Viewer Presenter
-- ============================================================================
-- UI Structure: views/log-viewer.xml
-- Frame: EreaRpLogViewerFrame (defined in XML)
--
-- PURPOSE: Manages the debug log viewer frame behavior
--
-- FEATURES:
--   - Shows debug log for any addon (RPMaster, RPPlayer, etc.)
--   - Dynamically accesses correct SavedVariable using _G table
--   - Clear log functionality
--   - Copy/paste support via EditBox
--
-- METHODS:
--   EreaRpLogViewerFrame:Initialize() - Setup frame references and event handlers
--   EreaRpLogViewerFrame:ShowLog(addonName) - Display debug log for specified addon
--   EreaRpLogViewerFrame:ClearLog(addonName) - Clear debug log for specified addon
--
-- USAGE:
--   EreaRpLogViewerFrame:ShowLog("RPMaster")  -- Shows RPMasterDebugLog
--   EreaRpLogViewerFrame:ShowLog("RPPlayer")  -- Shows RPPlayerDebugLog
--
-- DEPENDENCIES:
--   - EreaRpLogViewerFrame (created by views/log-viewer.xml)
--   - _G table for dynamic SavedVariable access
--
-- PATTERN: Prototype-based OOP for WoW frames
-- ============================================================================

-- ============================================================================
-- Initialize Log Viewer Frame
-- ============================================================================
-- Sets up the log viewer frame with references and event handlers
function EreaRpLogViewerFrame:Initialize()
    -- Get references to XML-defined elements
    self.title = EreaRpLogViewerFrameTitle
    self.editBox = EreaRpLogViewerFrameScrollFrameEditBox
    self.clearBtn = EreaRpLogViewerFrameClearButton

    -- Current addon name (for Clear button callback)
    self.currentAddonName = nil

    -- Setup Clear button click handler
    self.clearBtn:SetScript("OnClick", function()
        if EreaRpLogViewerFrame.currentAddonName then
            EreaRpLogViewerFrame:ClearLog(EreaRpLogViewerFrame.currentAddonName)
        end
    end)
end

-- ============================================================================
-- Show Log
-- ============================================================================
-- Displays debug log for specified addon
-- @param addonName: String - Addon name ("RPMaster" or "RPPlayer")
function EreaRpLogViewerFrame:ShowLog(addonName)
    if not addonName or type(addonName) ~= "string" then
        error("ShowLog: addonName must be a string")
    end

    -- Store current addon name for Clear button
    self.currentAddonName = addonName

    -- Construct SavedVariable name dynamically (e.g., "RPMasterDebugLog")
    local logVarName = addonName .. "DebugLog"

    -- Access log via _G table
    local debugLog = _G[logVarName]

    -- Check if log is empty
    if not debugLog or table.getn(debugLog) == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[" .. addonName .. "]|r Debug log is empty")
        return
    end

    -- Update window title
    self.title:SetText(addonName .. " Debug Log")

    -- Concatenate log entries
    local logContent = table.concat(debugLog, "\n")
    self.editBox:SetText(logContent)
    self.editBox:HighlightText()

    -- Calculate height needed for all text
    local numLines = table.getn(debugLog)
    local lineHeight = 14  -- Approximate height per line
    local totalHeight = numLines * lineHeight + 20
    self.editBox:SetHeight(totalHeight)

    -- Show frame and focus EditBox (for easy copy/paste)
    self:Show()
    self.editBox:SetFocus()
end

-- ============================================================================
-- Clear Log
-- ============================================================================
-- Clears debug log for specified addon
-- @param addonName: String - Addon name ("RPMaster" or "RPPlayer")
function EreaRpLogViewerFrame:ClearLog(addonName)
    if not addonName or type(addonName) ~= "string" then
        error("ClearLog: addonName must be a string")
    end

    -- Construct SavedVariable name dynamically
    local logVarName = addonName .. "DebugLog"

    -- Clear log via _G table
    _G[logVarName] = {}

    -- Show confirmation
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[" .. addonName .. "]|r Debug log cleared")

    -- Hide log viewer
    self:Hide()
end

-- ============================================================================
-- Initialize on load
-- ============================================================================
EreaRpLogViewerFrame:Initialize()
