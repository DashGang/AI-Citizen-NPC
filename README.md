# AI Citizen NPC

AI Citizen NPC is a [Garry’s Mod](https://store.steampowered.com/app/4000/Garrys_Mod/) addon for spawning a conversational citizen character whose appearance and AI provider are configured by the server administrator. VJ Base supplies the NPC body, movement, and schedules; the addon connects that character to an LLM and the active game world.

## Capabilities

- **Provider choices:** configure separate OpenAI, OpenRouter, and OpenAI-compatible Local slots. Validate a connection, load available models, select a model, and give each slot a chat call name. OpenRouter's free router may select a moderation model instead of a conversational model; selecting a specific listed chat model is more predictable.
- **Flexible appearance:** select a mounted model through the spawn settings. Native game models can be used when their rig and VJ Base behavior are compatible.
- **In-game conversation:** address an NPC in public chat with `!agent` or a configured name preceded by '!'. The address can appear anywhere in the line, and the original player message stays visible to everyone.
- **World awareness:** for an addressed turn, the NPC can receive a bounded snapshot of its health and movement, visible players, its current threat, and nearby visible movable props. Damage, owner interaction, and optional NPC voice cues can provide additional context.
- **Base behavior:** the NPC uses VJ Base movement and schedules, can follow its owner when enabled, and can use configured spawn-menu weapon overrides.


## Optional Features

- **StarfallEx:** [StarfallEx](https://github.com/thegrb93/StarfallEx) can provide facial and expressive behavior through a separate Starfall instance. Optional MCP tools can expose selected game-state and entity actions; the Universal Toolgun integration enables its physical tool path. This action bridge requires a [Universal Tool Gun](https://steamcommunity.com/sharedfiles/filedetails/?id=3809948410) build that exposes the generic `UniversalToolgunNPCPrimaryAction` hook. These features are separately gated and are not required for ordinary chat.
- **Response transport:** the addon uses asynchronous provider requests and can use a persistent OpenAI Responses WebSocket when the optional GWSockets module is installed.

## Requirements

- [VJ Base](https://github.com/DrVrej/VJ-Base)

Set VJ Base as a Required Item on the Steam Workshop page. StarfallEx, Wiremod, Universal Toolgun, GWSockets, and the MCP sidecar are optional and are needed only for their respective features. The Local provider needs the separate relay process to reach a local model server; OpenAI and OpenRouter do not.

## Setup

Install AI Citizen NPC and VJ Base. Open **Spawn Menu → DrVrej → Plugins → AI Citizen NPC Spawn**. Choose a mounted model and provider, enter the provider key or Local endpoint, and select **Validate key and load models**. Validation keeps the entered key in server memory for the current game session; it does not require saving. **Save key for future sessions** is optional and stores it in server-side Garry's Mod data. Choose a model, set the chat call name, enable the slot, and spawn. Then open **AI Citizen NPC Config** and enable **provider chat and game events**. In public chat, try `Hello !<call_name>, can you hear me?` (for example, `Hello !john, can you hear me?`).

Provider keys are entered in-game and remain in server memory only for the current session unless the user saves them. **Remove session and saved key** clears both forms and disables that provider slot. Never commit or share keys. By default, only explicitly addressed chat is sent to the provider. The optional recent-chat context feature holds a short buffer in memory; the addon does not write chat history to disk.

## Compatibility and limits

Custom models must be mounted on the server and use a skeleton and behavior compatible with VJ Base, typically a citizen/ValveBiped rig. Animation and flex support vary by model. Provider models also differ in support for tool calls and response streaming. Local-provider access requires the relay; enabling Local mode alone does not make a local model reachable.

## Future direction

A future goal is richer, command-based building: for example, interpreting a player’s request to build a simple device or scene, planning the steps, and carrying them out through game tools. A general construction mechanic is **not part of this release**. The current optional MCP path exposes only specific configured actions, such as selected entity interactions or component operations, with the game rechecking those actions.

This is an early beta release. The core chat and world-awareness loop has received initial gameplay testing; broader testing across providers, models, maps, and multiplayer sessions is still welcome.
