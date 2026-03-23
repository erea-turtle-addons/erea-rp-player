-- ============================================================================
-- video-player.lua - Shared Sprite-Sheet Video Player
-- ============================================================================
-- PURPOSE: Plug-and-play video player that wraps CinematicAnimations with a
--          simple object API. Consumer provides a texture, gets back a player
--          with Play/Stop/IsPlaying. Internally creates a hidden helper frame
--          for OnUpdate ticking (shown during playback, hidden on stop).
--
-- USAGE:
--   local vp = EreaRpLibraries:VideoPlayer()
--   local player = vp.New(myTexture)
--   player:Play("lit_candle")
--   player:Stop()
--   player:IsPlaying()
--
-- PATTERN: Library (stateless factory, returned via EreaRpLibraries)
-- ============================================================================

local cinematicAnims = EreaRpLibraries:CinematicAnimations()

-- Counter for unique helper frame names
local helperCounter = 0

-- ============================================================================
-- New(texture) - Create a new video player bound to a texture
-- ============================================================================
-- @param texture: WoW Texture widget to animate
-- @returns: player object with Play, Stop, IsPlaying methods
-- ============================================================================
local function New(texture)
    local player = {}
    local animState = nil

    -- Create hidden helper frame for OnUpdate ticking
    helperCounter = helperCounter + 1
    local helperName = "EreaRpVideoPlayerHelper" .. helperCounter
    local helperFrame = CreateFrame("Frame", helperName, UIParent)
    helperFrame:Hide()

    -- Lua 5.0: SetScript callbacks use `this` not `self`, elapsed is arg1
    helperFrame:SetScript("OnUpdate", function()
        if animState then
            cinematicAnims.UpdateAnimation(animState, arg1, texture)
        end
    end)

    -- ========================================================================
    -- Play(animKey) - Start playing a registered animation
    -- ========================================================================
    function player:Play(animKey, loopMode)
        -- Stop any running animation first
        if animState then
            cinematicAnims.StopAnimation(animState, texture)
            animState = nil
        end

        if not animKey or animKey == "" then
            helperFrame:Hide()
            return
        end

        animState = cinematicAnims.StartAnimation(texture, animKey, loopMode)
        if animState then
            helperFrame:Show()
        else
            helperFrame:Hide()
        end
    end

    -- ========================================================================
    -- Stop() - Stop playback and hide texture
    -- ========================================================================
    function player:Stop()
        if animState then
            cinematicAnims.StopAnimation(animState, texture)
            animState = nil
        end
        helperFrame:Hide()
    end

    -- ========================================================================
    -- IsPlaying() - Check if an animation is currently playing
    -- ========================================================================
    function player:IsPlaying()
        return animState ~= nil
    end

    return player
end

-- ============================================================================
-- EXPORT
-- ============================================================================

function EreaRpLibraries:VideoPlayer()
    return {
        New = New
    }
end
