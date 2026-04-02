-- ============================================================================
-- version.lua - Version information for RPPlayer
-- ============================================================================
-- This file is loaded FIRST by the .toc file to make version info available
-- to all other modules. Separating version info allows CI/CD systems to
-- easily update versions during automated builds.
--
-- USAGE: Other files access these via global variables
-- ============================================================================

RP_VERSION_TAG = "1.1.7"           -- Semantic version (sync with git tag)
RP_BUILD_TIME = "2026-04-02 16:07:37" -- Build timestamp (updated on each build)
RP_PRODUCTION_BUILD = true  -- true in release builds, false in dev

