-- ============================================================================
-- cinematic-frame.lua - Cinematic Dialogue Frame Presenter (Shared)
-- ============================================================================
-- PURPOSE: Controller for the cinematic dialogue frame that shows configurable
--          left/right sides (portrait, animation, or nothing) with speaker
--          name and dialogue text in the center.
--
-- RESPONSIBILITIES:
--   - Show/hide cinematic dialogue with speaker info
--   - Display 3D player model (portrait) on either side
--   - Display sprite-sheet animation on either side
--   - Each side independently configurable as portrait/animation/none
--   - Auto-hide after timeout
--
-- NOTE: Proximity checking is the caller's responsibility. This frame
--       simply displays whatever it's told to display.
--
-- LAYOUT:  Left (portrait|animation|none) | Text (center) | Right (portrait|animation|none)
--
-- PATTERN: Presenter (methods added to XML-created global frame)
-- ============================================================================

-- ============================================================================
-- IMPORTS
-- ============================================================================
local Log = EreaRpLibraries:Logging("RPCommon")
local videoPlayer = EreaRpLibraries:VideoPlayer()
local unitUtils = EreaRpLibraries:UnitUtils()

-- ============================================================================
-- Constants
-- ============================================================================
local AUTO_HIDE_SECONDS = 10
local TALK_SEQUENCE_ID = 60
local PORTRAIT_SCALE = 3.4
local PORTRAIT_POSITION_Y = -0.8

-- ============================================================================
-- State
-- ============================================================================
local autoHideTimer = 0
local isTimerRunning = false
local pendingLeftPortraitZoom = false
local pendingRightPortraitZoom = false
local leftAnimPlayer = nil   -- VideoPlayer instance for left side
local rightAnimPlayer = nil  -- VideoPlayer instance for right side

-- ============================================================================
-- UpdateTextAnchors - Unified anchor logic for speaker name and dialogue text
-- ============================================================================
-- Handles all 4 combinations of left visible / right visible.
-- Uses invisible anchor frames defined in XML ($parentTextOrigin,
-- $parentTextRightEdge) so all margin values live in the view.
--
-- Left: left side visible -> right of left border; else -> TextOrigin
-- Right: right side visible -> left of right border; else -> TextRightEdge
-- ============================================================================
local function UpdateTextAnchors(frame, leftVisible, rightVisible)
    local speakerName = frame.speakerNameText
    local dialogueText = frame.dialogueText

    speakerName:ClearAllPoints()
    dialogueText:ClearAllPoints()

    -- Left anchor for speaker name
    if leftVisible then
        speakerName:SetPoint("TOPLEFT", frame.leftBorder, "TOPRIGHT", 10, -5)
    else
        speakerName:SetPoint("TOPLEFT", frame.textOrigin, "TOPLEFT", 0, 0)
    end

    -- Right anchor for speaker name
    if rightVisible then
        speakerName:SetPoint("RIGHT", frame.rightBorder, "LEFT", -10, 0)
    else
        speakerName:SetPoint("RIGHT", frame.textRightEdge, "RIGHT", 0, 0)
    end

    -- Dialogue text anchors follow speaker name
    dialogueText:SetPoint("TOPLEFT", speakerName, "BOTTOMLEFT", 0, -8)

    if rightVisible then
        dialogueText:SetPoint("RIGHT", frame.rightBorder, "LEFT", -10, 0)
    else
        dialogueText:SetPoint("RIGHT", frame.textRightEdge, "RIGHT", 0, 0)
    end
end

-- ============================================================================
-- ApplyPortraitZoom - Apply zoom settings to a portrait model
-- ============================================================================
local function ApplyPortraitZoom(portrait)
    portrait:SetModelScale(PORTRAIT_SCALE)
    portrait:SetPosition(0, 0, PORTRAIT_POSITION_Y)
    portrait:SetCamera(0)

    -- Check if model is loaded (GetModel returns path once loaded)
    if portrait:GetModel() then
        portrait:SetSequence(TALK_SEQUENCE_ID)
        return true  -- Zoom complete
    end
    return false  -- Still loading
end

-- ============================================================================
-- Initialize - Cache frame references and set up timer
-- ============================================================================
function EreaRpCinematicFrame:Initialize()
    -- Left side
    self.leftPortrait = EreaRpCinematicFrameLeftPortrait
    self.leftAnimation = EreaRpCinematicFrameLeftAnimation
    self.leftBorder = EreaRpCinematicFrameLeftBorder

    -- Right side
    self.rightPortrait = EreaRpCinematicFrameRightPortrait
    self.rightAnimation = EreaRpCinematicFrameRightAnimation
    self.rightBorder = EreaRpCinematicFrameRightBorder

    -- Text elements
    self.speakerNameText = EreaRpCinematicFrameSpeakerName
    self.dialogueText = EreaRpCinematicFrameDialogueText
    self.closeButton = EreaRpCinematicFrameCloseButton
    self.textOrigin = EreaRpCinematicFrameTextOrigin
    self.textRightEdge = EreaRpCinematicFrameTextRightEdge

    -- Create VideoPlayers for each side's animation texture
    leftAnimPlayer = videoPlayer.New(self.leftAnimation)
    rightAnimPlayer = videoPlayer.New(self.rightAnimation)

    -- OnUpdate handles auto-hide timer and deferred portrait zooms.
    -- Lua 5.0: SetScript callbacks use `this` not `self`
    self:SetScript("OnUpdate", function()
        -- Deferred left portrait zoom
        if pendingLeftPortraitZoom then
            if ApplyPortraitZoom(EreaRpCinematicFrameLeftPortrait) then
                pendingLeftPortraitZoom = false
            end
        end

        -- Deferred right portrait zoom
        if pendingRightPortraitZoom then
            if ApplyPortraitZoom(EreaRpCinematicFrameRightPortrait) then
                pendingRightPortraitZoom = false
            end
        end

        -- Auto-hide timer
        if not isTimerRunning then return end

        autoHideTimer = autoHideTimer - arg1
        if autoHideTimer <= 0 then
            isTimerRunning = false
            EreaRpCinematicFrame:Hide()

            -- Stop animations when frame hides
            if leftAnimPlayer then
                leftAnimPlayer:Stop()
            end
            if rightAnimPlayer then
                rightAnimPlayer:Stop()
            end
        end
    end)

    Log("CinematicFrame initialized")
end

-- ============================================================================
-- SetupSide - Configure one side (left or right) based on config
-- ============================================================================
-- @param side: "left" or "right"
-- @param config: { type = "portrait"|"animation"|"none", portraitUnit = "player"|"target", animationKey = "..." } or nil
-- @param senderName: Name of the sender (for portrait unit resolution)
-- @returns: boolean - Whether this side is visible
-- ============================================================================
local function SetupSide(frame, side, config, senderName)
    local portrait, animation, border, pendingZoomSetter, animPlayerRef

    if side == "left" then
        portrait = frame.leftPortrait
        animation = frame.leftAnimation
        border = frame.leftBorder
        animPlayerRef = leftAnimPlayer
    else
        portrait = frame.rightPortrait
        animation = frame.rightAnimation
        border = frame.rightBorder
        animPlayerRef = rightAnimPlayer
    end

    -- Stop any previous animation on this side
    if animPlayerRef then
        animPlayerRef:Stop()
    end

    -- Default: hide everything
    if not config or config.type == "none" then
        portrait:Hide()
        animation:Hide()
        border:Hide()
        if side == "left" then
            pendingLeftPortraitZoom = false
        else
            pendingRightPortraitZoom = false
        end
        return false
    end

    if config.type == "portrait" then
        -- Determine unit ID based on portraitUnit setting
        local unitId = nil
        if config.portraitUnit == "target" then
            -- Find sender's unit, then use their target
            local senderUnitId = unitUtils.FindUnitId(senderName)
            if senderUnitId then
                unitId = senderUnitId .. "target"
            end
        else
            -- Default: "player" means the sender
            unitId = unitUtils.FindUnitId(senderName)
        end

        if unitId then
            portrait:Show()
            border:Show()
            animation:Hide()
            portrait:SetUnit(unitId)
            -- Defer zoom to OnUpdate (SetUnit loads model async)
            if side == "left" then
                pendingLeftPortraitZoom = true
            else
                pendingRightPortraitZoom = true
            end
            return true
        else
            portrait:Hide()
            animation:Hide()
            border:Hide()
            if side == "left" then
                pendingLeftPortraitZoom = false
            else
                pendingRightPortraitZoom = false
            end
            return false
        end

    elseif config.type == "animation" then
        portrait:Hide()
        if side == "left" then
            pendingLeftPortraitZoom = false
        else
            pendingRightPortraitZoom = false
        end

        local animKey = config.animationKey
        if animKey and animKey ~= "" and animPlayerRef then
            animPlayerRef:Play(animKey, config.loopMode)
            if animPlayerRef:IsPlaying() then
                border:Show()
                return true
            end
        end

        animation:Hide()
        border:Hide()
        return false
    end

    -- Unknown type: hide everything
    portrait:Hide()
    animation:Hide()
    border:Hide()
    return false
end

-- ============================================================================
-- ShowDialogue - Display cinematic dialogue
-- ============================================================================
-- New signature with config objects:
-- @param senderName: Player who triggered the cinematic
-- @param speakerName: Name displayed as the speaker
-- @param dialogueText: The dialogue text to display
-- @param leftConfig: { type, portraitUnit, animationKey } or nil
-- @param rightConfig: { type, portraitUnit, animationKey } or nil
--
-- Backward compat: If leftConfig is a string ("0"/"1"), convert to old behavior
-- ============================================================================
function EreaRpCinematicFrame:ShowDialogue(senderName, speakerName, dialogueText, leftConfig, rightConfig)
    -- Initialize refs if not yet done
    if not self.leftPortrait then
        self:Initialize()
    end

    -- Backward compat: detect old-style call where 4th arg is "0"/"1" string
    if type(leftConfig) == "string" then
        local showPortrait = leftConfig
        local animationKey = rightConfig  -- 5th arg was animationKey in old API

        -- Convert to new config objects
        if showPortrait == "1" then
            leftConfig = { type = "portrait", portraitUnit = "player" }
        else
            leftConfig = { type = "none" }
        end

        if animationKey and animationKey ~= "" then
            rightConfig = { type = "animation", animationKey = animationKey, loopMode = "pingpong" }
        else
            rightConfig = { type = "none" }
        end
    end

    -- Set speaker name and dialogue text
    self.speakerNameText:SetText(speakerName or "")
    self.dialogueText:SetText(dialogueText or "")

    -- Stop any previous animations
    if leftAnimPlayer then
        leftAnimPlayer:Stop()
    end
    if rightAnimPlayer then
        rightAnimPlayer:Stop()
    end

    -- Setup each side
    local leftVisible = SetupSide(self, "left", leftConfig, senderName)
    local rightVisible = SetupSide(self, "right", rightConfig, senderName)

    -- Unified text anchor update
    UpdateTextAnchors(self, leftVisible, rightVisible)

    -- Start auto-hide timer
    autoHideTimer = AUTO_HIDE_SECONDS
    isTimerRunning = true

    -- Show the frame
    self:Show()

    Log("Cinematic shown: speaker=" .. tostring(speakerName) .. " from=" .. tostring(senderName))
end
