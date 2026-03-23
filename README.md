# RP Player Addon

This is the RP Player addon for Turtle WoW, which provides a personal RP inventory system for players.

## Features
- 16-slot bag for RP items (separate from regular inventory)
- Receive items from GMs (GIVE messages) with accept/decline popup
- Trade items to other players (TRADE messages) with confirmation
- Show items to others for preview (SHOW messages) without transfer
- Drag-drop reorganization (swap slots)
- Drag-drop to player portraits (quick trade/show)
- Right-click context menu (Read/Show/Give/Delete)
- Range detection (only show nearby raid/party members)
- Position persistence (remembers window locations)
- Debug logging system

## Architecture

This addon has been refactored to separate GUI logic from business logic:

### File Structure
- `rp-player.lua` - Main addon logic and event handling
- `components/` - XML UI components:
  - `rp-bag.xml` - Main bag frame with 16 item slots
  - `rp-read.xml` - Item reading frame

### UI Components
The UI is now defined in XML files using Blizzard's UI XML schema, following the patterns described in the AI Reproduction Guide. The XML files define:
- Frame structures with proper positioning and styling
- Child elements like buttons, textures, and text strings
- Draggable title bars
- Scrollable content areas
- Proper event handling through XML scripts

### Loading Order
The addon loads in the following order:
1. `player-actions.lua` - Action handling logic
2. `rp-player.lua` - Main addon logic
3. `components/rp-read.xml` - Reading frame UI
4. `components/rp-bag.xml` - Bag frame UI
5. `minimap-button.lua` - Minimap button logic

## Usage
- Use `/rpplayer` to open the bag
- Use `/rpplayer log` to view debug logs
- Use `/rpplayer reset` to reset window positions
