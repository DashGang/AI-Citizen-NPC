local MCP = {}

local ROOT = "ai_citizen_npc/mcp"
local COMMANDS = ROOT .. "/commands"
local RESULTS = ROOT .. "/results"
local STATE_PATH = ROOT .. "/state.txt"
local TOKEN_PATH = ROOT .. "/bridge_token.txt"
local GAME_BRIDGE_PATH = "/citizen-agent-game"
local MAX_EVENTS = 20
local MAX_EVENT_BYTES = 320
local MAX_COMMAND_BYTES = 1024 * 1024
local MAX_GAME_BRIDGE_BYTES = 6 * 1024 * 1024
local POLL_INTERVAL = 0.15
local STATE_INTERVAL = 0.5
local events = {}
local authorizationOwner
local authorizationExpires = 0
local stateExpiresAtUnix = 0
local MCP_EXPRESSIONS = {neutral = true, speaking = true, curious = true, positive = true, concerned = true}
local MAX_VISIBLE_ENTITIES = 12
local VISIBLE_BUTTON_RANGE = 640
local BUTTON_USE_RANGE = 160
local VISIBLE_PROP_RANGE = 512
local NATIVE_TOOLGUN_CLASS = "gmod_tool"
local ENTITY_ADAPTERS = {}
local gameSocket
local socketState = "closed"
local socketGeneration = 0
local localProviderRequests = {}
local localProviderQueue = {}
local localProviderSequence = 0
local lastStatePublishAt
local nativeModule
local nativePort
local nativeLoadErrorReported
local nativeRetryPort
local nativeRetryAt = 0
local nativeRetryDelay = 1
local nativeLastStartFailure

local function cvarBool(name)
    local cv = GetConVar(name)
    return cv and cv:GetBool() or false
end

local function cleanText(value, limit)
    local text = tostring(value or "")
    text = string.gsub(text, "[%z\1-\8\11\12\14-\31\127]", " ")
    text = string.gsub(text, "[%c]+", " ")
    text = string.Trim(text)
    if #text > limit then text = string.sub(text, 1, limit) end
    return text
end

local function xyz(vector)
    return {x = math.Round(vector.x, 1), y = math.Round(vector.y, 1), z = math.Round(vector.z, 1)}
end

local function distanceBetween(actor, target)
    if isfunction(actor.GetRangeTo) then
        local ok, distance = pcall(actor.GetRangeTo, actor, target)
        if ok and isnumber(distance) then return distance end
    end
    return actor:GetPos():Distance(target:GetPos())
end

local function activeBody()
    local actor = AICitizenNPC.Starfall.GetActor()
    if IsValid(actor) then return actor, true end
    for _, bot in ipairs(ents.FindByClass("npc_vj_ai_citizen_npc")) do
        if IsValid(bot) and bot.ACNAgentVJ == true then return bot, false end
    end
end

local function visibleContacts(actor)
    local contacts = {}
    if not IsValid(actor) then return contacts end
    local origin = actor:EyePos()
    for _, ent in ipairs(ents.FindInSphere(actor:GetPos(), AICitizenNPC.Config.sensorRange)) do
        if #contacts >= 12 then break end
        if IsValid(ent) and ent ~= actor and (ent:IsPlayer() or ent:IsNPC()) then
            if not ent:IsPlayer() or ent:Alive() then
                local trace = util.TraceLine({
                    start = origin,
                    endpos = ent:WorldSpaceCenter(),
                    filter = {actor, ent},
                    mask = MASK_VISIBLE_AND_NPCS
                })
                if not trace.Hit then
                    contacts[#contacts + 1] = {
                        id = ent:EntIndex(),
                        name = ent:IsPlayer() and cleanText(ent:Nick(), 48) or cleanText(ent:GetClass(), 48),
                        kind = ent:IsPlayer() and "player" or "npc",
                        distance = math.Round(distanceBetween(actor, ent), 1)
                    }
                end
            end
        end
    end
    table.sort(contacts, function(a, b) return a.distance < b.distance end)
    return contacts
end

function MCP.GetOwnedAgentComponents(actor)
    local components = {}
    if not IsValid(actor) or actor:GetClass() ~= "npc_vj_ai_citizen_npc"
        or actor.ACNAgentVJ ~= true then return components end
    for _, component in ipairs(ents.FindByClass("prop_physics")) do
        if IsValid(component) and component.ACNAgentComponent == true
            and component.ACNAgentComponentOwner == actor then
            components[#components + 1] = {
                entity_id = component:EntIndex(),
                model = component:GetModel(),
                distance = math.Round(actor:GetPos():Distance(component:WorldSpaceCenter()), 1)
            }
        end
    end
    table.sort(components, function(a, b) return a.entity_id < b.entity_id end)
    return components
end

function MCP.GetVisibleOwnedAgentComponents(actor)
    local visible = {}
    if not IsValid(actor) then return visible end
    for _, item in ipairs(MCP.GetOwnedAgentComponents(actor)) do
        local component = Entity(item.entity_id)
        if IsValid(component) and item.distance <= VISIBLE_PROP_RANGE then
            local trace = util.TraceLine({
                start = actor:EyePos(),
                endpos = component:WorldSpaceCenter(),
                filter = {actor, component},
                mask = MASK_VISIBLE_AND_NPCS
            })
            if not trace.Hit then visible[#visible + 1] = item end
        end
    end
    return visible
end

local function spawnOwnedAgentComponent(ply, actor, model)
    if not MCP.CanControlVJ(ply, actor) then
        return false, "component spawning requires the admin-owned active VJ agent and enabled MCP actions"
    end
    if not isstring(model) or model == "" or not util.IsValidModel(model) then
        return false, "GMod does not recognize this model"
    end

    local directions = {actor:GetForward(), actor:GetRight(), -actor:GetRight(), -actor:GetForward()}
    local position
    for _, direction in ipairs(directions) do
        local candidate = actor:GetPos() + direction * 80 + Vector(0, 0, 48)
        if util.IsInWorld(candidate) then
            local trace = util.TraceHull({
                start = actor:WorldSpaceCenter(),
                endpos = candidate,
                mins = Vector(-10, -10, 0),
                maxs = Vector(10, 10, 24),
                filter = {actor, ply},
                mask = MASK_SOLID
            })
            if not trace.StartSolid and not trace.AllSolid and not trace.Hit then
                position = candidate
                break
            end
        end
    end
    if not position then return false, "all nearby component placement points are obstructed" end

    local component = ents.Create("prop_physics")
    if not IsValid(component) then return false, "GMod could not create the component entity" end
    component:SetModel(model)
    component:SetPos(position)
    component:SetAngles(Angle(0, actor:GetAngles().y, 0))
    component.ACNAgentComponent = true
    component.ACNAgentComponentOwner = actor
    component.ACNAgentComponentOwnerID = actor:EntIndex()
    component:SetCreator(ply)
    component:Spawn()
    component:Activate()
    if not IsValid(component) or not IsValid(component:GetPhysicsObject()) then
        if IsValid(component) then component:Remove() end
        return false, "the spawned component has no valid physics object"
    end
    MCP.RecordEvent("agent_component_spawned", "Agent spawned component " .. cleanText(model, 128), ply:Nick())
    MCP.PublishState()
    return true, "component_id=" .. component:EntIndex() .. " model=" .. cleanText(model, 128)
end

local function removeOwnedAgentComponent(ply, actor, entityID)
    if not MCP.CanControlVJ(ply, actor) then
        return false, "component removal requires the admin-owned active VJ agent and enabled MCP actions"
    end
    if not isnumber(entityID) or entityID ~= math.floor(entityID) or entityID < 1 or entityID > 8192 then
        return false, "component entity ID is invalid"
    end
    local component = Entity(entityID)
    if not IsValid(component) or component:GetClass() ~= "prop_physics"
        or component.ACNAgentComponent ~= true or component.ACNAgentComponentOwner ~= actor then
        return false, "the requested entity is not owned by this exact agent"
    end
    local distance = actor:GetPos():Distance(component:WorldSpaceCenter())
    if distance > VISIBLE_PROP_RANGE then return false, "the component is outside the agent interaction range" end
    local trace = util.TraceLine({
        start = actor:EyePos(),
        endpos = component:WorldSpaceCenter(),
        filter = {actor, component},
        mask = MASK_VISIBLE_AND_NPCS
    })
    if trace.Hit then return false, "the component is no longer visible to the agent" end
    local modelID = component:GetModel()
    component:Remove()
    MCP.RecordEvent("agent_component_removed", "Agent removed its owned component " .. cleanText(modelID, 128), ply:Nick())
    MCP.PublishState()
    return true, "component_removed=" .. entityID
end

function MCP.AgentHasToolgun(actor)
    if not IsValid(actor) or actor:GetClass() ~= "npc_vj_ai_citizen_npc"
        or actor.ACNAgentVJ ~= true then return false end
    local weapon = actor:GetActiveWeapon()
    local definition = weapons.GetStored(NATIVE_TOOLGUN_CLASS)
    return IsValid(weapon) and weapon:GetClass() == NATIVE_TOOLGUN_CLASS
        and weapon:GetOwner() == actor and istable(definition)
        and definition.CALUniversalToolgun == true
end

function MCP.HandleAgentToolgunAttack(weapon)
    if not IsValid(weapon) then
        return false, "the NPC Toolgun weapon is invalid"
    end
    local actor = weapon:GetOwner()
    local class = weapon:GetClass()
    local definition = class == NATIVE_TOOLGUN_CLASS and weapons.GetStored(NATIVE_TOOLGUN_CLASS)
    local supportedClass = class == NATIVE_TOOLGUN_CLASS
        and istable(definition) and definition.CALUniversalToolgun == true
    if not supportedClass then return false, "the NPC Toolgun weapon is invalid" end
    if not MCP.AgentHasToolgun(actor) or actor:GetActiveWeapon() ~= weapon then
        return false, "the Toolgun is not actively held by a AI Citizen NPC"
    end
    local pending = actor.ACNPendingToolgunAction
    actor.ACNPendingToolgunAction = nil
    if not istable(pending) then return false, "the Toolgun has no authorized pending MCP action" end
    local owner = actor.ACNOwner
    if not MCP.CanControlVJ(owner, actor) then return false, "MCP authorization expired before Toolgun use" end

    local ok, result
    if pending.action == "spawn" and isstring(pending.model) then
        ok, result = spawnOwnedAgentComponent(owner, actor, pending.model)
    elseif pending.action == "remove" and isnumber(pending.entity_id) then
        ok, result = removeOwnedAgentComponent(owner, actor, pending.entity_id)
    else
        return false, "the Toolgun action schema is invalid"
    end
    actor.ACNLastToolgunResult = {ok = ok == true, result = cleanText(result, 180), at = CurTime()}
    return ok, result
end

function MCP.UseAgentToolgun(ply, actor, action)
    if not MCP.CanControlVJ(ply, actor) then return false, "Toolgun use is not authorized for this VJ agent" end
    if not MCP.AgentHasToolgun(actor) then return false, "the agent must pick up and hold its Toolgun first" end
    if not istable(action) or (action.action ~= "spawn" and action.action ~= "remove") then
        return false, "Toolgun action is invalid"
    end
    if actor.ACNPendingToolgunAction then return false, "the agent Toolgun is already processing an action" end

    actor.ACNPendingToolgunAction = table.Copy(action)
    local weapon = actor:GetActiveWeapon()
    local called, accepted, result = pcall(weapon.NPCShoot_Primary, weapon, actor:GetShootPos(), actor:GetAimVector())
    actor.ACNPendingToolgunAction = nil
    if not called then return false, "NPC Toolgun callback failed" end
    if accepted ~= true then return false, result or "NPC Toolgun callback rejected the action" end
    return true, result
end

function MCP.SpawnOwnedAgentComponent(ply, actor, model)
    if not isstring(model) or model == "" or not util.IsValidModel(model) then
        return false, "GMod does not recognize this model"
    end
    return MCP.UseAgentToolgun(ply, actor, {action = "spawn", model = model})
end

function MCP.RemoveOwnedAgentComponent(ply, actor, entityID)
    if not isnumber(entityID) or entityID ~= math.floor(entityID) or entityID < 1 or entityID > 8192 then
        return false, "component entity ID is invalid"
    end
    return MCP.UseAgentToolgun(ply, actor, {action = "remove", entity_id = entityID})
end

-- Adapters are registered by trusted server addon code. They publish only
-- bounded capability metadata; all action handlers still re-resolve entities.
function MCP.RegisterEntityAdapter(adapter)
    local duplicateTool = false
    if istable(adapter) and istable(adapter.tool) and isstring(adapter.tool.name) then
        for _, current in pairs(ENTITY_ADAPTERS) do
            if current.tool.name == adapter.tool.name then duplicateTool = true break end
        end
    end
    if not istable(adapter) or not isstring(adapter.class)
        or #adapter.class > 64 or not string.match(adapter.class, "^[%w_]+$")
        or not isstring(adapter.capability)
        or #adapter.capability > 80 or not string.match(adapter.capability, "^[%w_%.%-]+$")
        or not istable(adapter.tool) or not isstring(adapter.tool.name)
        or #adapter.tool.name > 64 or not string.match(adapter.tool.name, "^[%w_]+$")
        or not isstring(adapter.tool.description) or #adapter.tool.description > 400
        or not istable(adapter.tool.inputSchema)
        or not isfunction(adapter.validateArguments) or duplicateTool
        or not isfunction(adapter.observe) or not isfunction(adapter.execute)
        or ENTITY_ADAPTERS[adapter.capability] then
        return false, "invalid or duplicate entity capability adapter"
    end
    adapter.maxVisible = math.Clamp(math.floor(tonumber(adapter.maxVisible) or MAX_VISIBLE_ENTITIES), 1, MAX_VISIBLE_ENTITIES)
    ENTITY_ADAPTERS[adapter.capability] = adapter
    return true
end

function MCP.GetEntityAdapterCatalog()
    local catalog = {}
    for capability, adapter in pairs(ENTITY_ADAPTERS) do
        catalog[#catalog + 1] = {
            capability = capability,
            class = adapter.class,
            action = "invoke_entity_capability",
            tool = table.Copy(adapter.tool)
        }
    end
    table.sort(catalog, function(a, b) return a.capability < b.capability end)
    return catalog
end

local function visibleEntityCapabilities(actor)
    local results = {}
    if not IsValid(actor) then return results end
    for capability, adapter in pairs(ENTITY_ADAPTERS) do
        local entities = ents.FindByClass(adapter.class)
        local count = 0
        for _, ent in ipairs(entities) do
            if count >= adapter.maxVisible then break end
            if IsValid(ent) then
                local ok, observation = pcall(adapter.observe, actor, ent)
                if ok and istable(observation) and isnumber(observation.distance)
                    and observation.distance >= 0 and observation.distance <= 100000 then
                    results[#results + 1] = {
                        id = ent:EntIndex(),
                        class = adapter.class,
                        capability = capability,
                        distance = math.Round(observation.distance, 1)
                    }
                    count = count + 1
                end
            end
        end
    end
    table.sort(results, function(a, b) return (a.distance or math.huge) < (b.distance or math.huge) end)
    return results
end

function MCP.VisibleEntityCapabilities(actor)
    return visibleEntityCapabilities(actor)
end

local function visibleButtons(actor, capabilities)
    local buttons = {}
    for _, item in ipairs(capabilities or visibleEntityCapabilities(actor)) do
        if item.capability == "map_button.press" then
            buttons[#buttons + 1] = {id = item.id, class = item.class, distance = item.distance}
        end
    end
    return buttons
end

function MCP.VisibleButtons(actor)
    return visibleButtons(actor)
end

local function makeState()
    local actor, isStarfall = activeBody()
    local entityCapabilities = visibleEntityCapabilities(actor)
    local owner = isStarfall and AICitizenNPC.Starfall.GetOwner()
        or (IsValid(actor) and actor.ACNOwner or nil)
    local ownerIsAdmin = IsValid(owner) and owner:IsAdmin() or false
    local scriptAuthorized = authorizationExpires > CurTime()
        and owner == authorizationOwner and ownerIsAdmin
        and cvarBool("ai_citizen_npc_ai_mcp_enabled")
        and AICitizenNPC.Starfall.CanInstallBehavior(owner)
    local state = {
        schema_version = 1,
        timestamp_unix = os.time(),
        mcp_enabled = cvarBool("ai_citizen_npc_ai_mcp_enabled"),
        starfall_enabled = cvarBool("ai_citizen_npc_ai_starfall_enabled"),
        starfall_code_enabled = cvarBool("ai_citizen_npc_ai_starfall_code_enabled"),
        vj_actions_enabled = cvarBool("ai_citizen_npc_ai_mcp_vj_actions_enabled"),
        toolgun_ready = IsValid(actor) and MCP.AgentHasToolgun(actor) or false,
        animation_enabled = cvarBool("ai_citizen_npc_ai_animation_enabled"),
        starfall_active = isStarfall == true and IsValid(actor),
        -- Starfall is an attached expression runtime, not a replacement body.
        -- Keep the actor's VJ Base runtime label stable so VJ/Toolgun MCP tools
        -- remain available while its Starfall component is attached.
        body_runtime = IsValid(actor) and (actor.IsVJBaseSNPC and "vj_base" or "unknown") or "none",
        owner_is_admin = ownerIsAdmin,
        script_authorized_until_unix = scriptAuthorized and stateExpiresAtUnix or 0,
        visible_contacts = visibleContacts(actor),
        visible_buttons = visibleButtons(actor, entityCapabilities),
        entity_capabilities = entityCapabilities,
        entity_capability_catalog = MCP.GetEntityAdapterCatalog(),
        owned_components = IsValid(actor) and MCP.GetVisibleOwnedAgentComponents(actor) or {},
        presentation_cues = IsValid(actor) and AICitizenNPC.Presentation
            and AICitizenNPC.Presentation.AvailableCues(actor) or {},
        recent_events = table.Copy(events)
    }
    if IsValid(actor) then
        state.agent = {
            entity_id = actor:EntIndex(),
            class = actor:GetClass(),
            model = actor:GetModel(),
            position = xyz(actor:GetPos()),
            yaw = math.Round(actor:GetAngles().y, 1),
            health = actor:Health(),
            following_owner = actor.IsFollowing == true and actor.FollowData ~= nil
                and actor.FollowData.Target == owner or false,
            presentation_cue = (tonumber(actor.ACNPresentationBusyUntil) or 0) > CurTime()
                and actor.ACNPresentationLastCue or nil,
            presentation_remaining_s = math.Round(math.max(0,
                (tonumber(actor.ACNPresentationBusyUntil) or 0) - CurTime()), 2),
            speed = math.Round(actor:GetVelocity():Length(), 1)
        }
    end
    return state
end

function MCP.PublishState()
    if not cvarBool("ai_citizen_npc_ai_mcp_enabled") then
        -- Remove the last live snapshot so the sidecar cannot keep serving stale world state.
        if lastStatePublishAt ~= false then
            file.Delete(STATE_PATH)
            lastStatePublishAt = false
        end
        return false
    end

    file.CreateDir(ROOT)
    local encoded = util.TableToJSON(makeState(), false)
    if not encoded or #encoded > 128 * 1024 then return false end
    file.Write(STATE_PATH, encoded)
    lastStatePublishAt = CurTime()
    return true
end

function MCP.TransportStatus()
    return {
        enabled = cvarBool("ai_citizen_npc_ai_mcp_enabled"),
        connection = socketState,
        token_ready = file.Exists(TOKEN_PATH, "DATA"),
        state_age_seconds = lastStatePublishAt and math.max(0, CurTime() - lastStatePublishAt) or -1
    }
end

function MCP.NativeTransportStatus()
    local enabled = cvarBool("ai_citizen_npc_ai_mcp_native_enabled")
    local listening = false
    if nativeModule and isfunction(nativeModule.isListening) then
        local ok, result = pcall(nativeModule.isListening)
        listening = ok and result == true
    end
    return {
        enabled = enabled,
        listening = listening,
        port = GetConVar("ai_citizen_npc_ai_mcp_native_port")
            and GetConVar("ai_citizen_npc_ai_mcp_native_port"):GetInt() or 0
    }
end

function MCP.RecordEvent(kind, text, speaker)
    events[#events + 1] = {
        time_unix = os.time(),
        kind = cleanText(kind, 32),
        speaker = cleanText(speaker, 48),
        text = cleanText(text, MAX_EVENT_BYTES)
    }
    while #events > MAX_EVENTS do table.remove(events, 1) end
end

function MCP.AuthorizeBehaviorRequest(ply)
    local owner = AICitizenNPC.Starfall.GetOwner()
    if not IsValid(ply) or not ply:IsAdmin() or owner ~= ply
        or not cvarBool("ai_citizen_npc_ai_mcp_enabled")
        or not AICitizenNPC.Starfall.CanInstallBehavior(ply) then
        return false
    end
    authorizationOwner = ply
    authorizationExpires = CurTime() + 120
    stateExpiresAtUnix = os.time() + 120
    MCP.PublishState()
    timer.Create("AICitizenNPC.MCPAuthorizationExpiry", 120, 1, function()
        authorizationOwner = nil
        authorizationExpires = 0
        stateExpiresAtUnix = 0
        MCP.PublishState()
    end)
    return true
end

function MCP.RevokeBehaviorRequest(ply)
    if ply and authorizationOwner ~= ply then return false end
    authorizationOwner = nil
    authorizationExpires = 0
    stateExpiresAtUnix = 0
    timer.Remove("AICitizenNPC.MCPAuthorizationExpiry")
    MCP.PublishState()
    return true
end

function MCP.CanControlVJ(ply, actor)
    return IsValid(ply) and ply:IsAdmin() and IsValid(actor)
        and actor:GetClass() == "npc_vj_ai_citizen_npc"
        and actor.ACNAgentVJ == true and actor.ACNOwner == ply
        and cvarBool("ai_citizen_npc_ai_mcp_enabled")
        and cvarBool("ai_citizen_npc_ai_mcp_vj_actions_enabled")
end

function MCP.CanUseDirectVJActions(ply, actor)
    return IsValid(ply) and ply:IsAdmin() and IsValid(actor)
        and actor:GetClass() == "npc_vj_ai_citizen_npc"
        and actor.ACNAgentVJ == true and actor.ACNOwner == ply
        and cvarBool("ai_citizen_npc_ai_enabled")
        and cvarBool("ai_citizen_npc_ai_vj_actions_enabled")
end

function MCP.CanControlVJAnimation(ply, actor)
    return IsValid(ply) and ply:IsAdmin() and IsValid(actor)
        and actor:GetClass() == "npc_vj_ai_citizen_npc"
        and actor.ACNAgentVJ == true and actor.ACNOwner == ply
        and cvarBool("ai_citizen_npc_ai_mcp_enabled")
        and cvarBool("ai_citizen_npc_ai_animation_enabled")
end

function MCP.CanUseDirectVJAnimation(ply, actor)
    return IsValid(ply) and ply:IsAdmin() and IsValid(actor)
        and actor:GetClass() == "npc_vj_ai_citizen_npc"
        and actor.ACNAgentVJ == true and actor.ACNOwner == ply
        and cvarBool("ai_citizen_npc_ai_enabled")
        and cvarBool("ai_citizen_npc_ai_animation_enabled")
end

function MCP.PlayVJAnimation(ply, actor, cue, origin)
    local authorized = origin == "api"
        and MCP.CanUseDirectVJAnimation(ply, actor)
        or origin ~= "api" and MCP.CanControlVJAnimation(ply, actor)
    if not authorized then return false, "animation cues are not enabled for this admin-owned VJ agent" end
    if not isstring(cue) or not AICitizenNPC.Presentation.IsCue(cue) then
        return false, "the requested semantic animation cue is unsupported"
    end
    local ok, played, message = pcall(AICitizenNPC.Presentation.Play, actor, cue)
    if not ok then return false, "VJ animation dispatch failed" end
    if played then
        MCP.RecordEvent("agent_animation_played", message, ply:Nick())
    end
    MCP.PublishState()
    return played, message
end

function MCP.SetVJFollowing(ply, actor, enabled, origin)
    local authorized = origin == "api"
        and MCP.CanUseDirectVJActions(ply, actor)
        or origin ~= "api" and MCP.CanControlVJ(ply, actor)
    if not authorized then
        return false, "VJ following is not enabled for this admin-owned agent"
    end
    if not isbool(enabled) then return false, "enabled must be a boolean" end
    if not isfunction(actor.Follow) then return false, "VJ Base follow support is unavailable" end

    if enabled then
        if not ply:Alive() then return false, "the agent owner must be alive to follow" end
        -- The VJ Follow API rejects hostile/neutral targets. Keep the spawned
        -- owner relationship explicitly friendly before asking it to follow.
        actor:AddEntityRelationship(ply, D_LI, 10)
        local ok, accepted = pcall(actor.Follow, actor, ply)
        if not ok then return false, "VJ Base rejected the follow request" end
        if accepted ~= true and not (actor.IsFollowing and actor.FollowData and actor.FollowData.Target == ply) then
            return false, "VJ Base could not start following this owner"
        end
        MCP.RecordEvent("agent_follow_started", "The VJ agent started following its owner", ply:Nick())
        MCP.PublishState()
        return true, "following_owner=true"
    end

    if actor.IsFollowing and actor.FollowData and actor.FollowData.Target == ply then
        local ok = pcall(actor.Follow, actor, ply, true)
        if not ok then return false, "VJ Base rejected the stop-following request" end
    end
    if actor.IsFollowing and actor.FollowData and actor.FollowData.Target == ply then
        return false, "VJ Base has not stopped following yet"
    end
    MCP.RecordEvent("agent_follow_stopped", "The VJ agent stopped following its owner", ply:Nick())
    MCP.PublishState()
    return true, "following_owner=false"
end

function MCP.PressVisibleButton(ply, actor, entityID)
    if not MCP.CanControlVJ(ply, actor) then
        return false, "VJ button interaction is not enabled for this admin-owned agent"
    end
    if not isnumber(entityID) or entityID ~= math.floor(entityID) then
        return false, "entity_id must be an integer"
    end
    local button = Entity(entityID)
    if not IsValid(button) or button:GetClass() ~= "func_button" then
        return false, "the requested entity is not a live func_button"
    end
    if actor:GetPos():Distance(button:WorldSpaceCenter()) > BUTTON_USE_RANGE then
        return false, "the button is outside the agent's interaction range"
    end
    local trace = util.TraceLine({
        start = actor:EyePos(),
        endpos = button:WorldSpaceCenter(),
        filter = actor,
        mask = MASK_VISIBLE_AND_NPCS
    })
    if trace.Hit and trace.Entity ~= button then
        return false, "the button is not currently visible to the agent"
    end
    local ok = pcall(button.Fire, button, "Press", "", 0, ply, actor)
    if not ok then return false, "GMod could not deliver the button input" end
    MCP.RecordEvent("mcp_button_pressed", "Agent pressed a visible func_button", ply:Nick())
    MCP.PublishState()
    return true, "button_press_sent=entity_id:" .. tostring(entityID)
end

function MCP.ExecuteEntityCapability(ply, actor, capability, entityID, arguments)
    local adapter = ENTITY_ADAPTERS[capability]
    if not adapter or not isnumber(entityID) or entityID ~= math.floor(entityID) then
        return false, "entity capability or entity reference is invalid"
    end
    if not MCP.CanControlVJ(ply, actor) then
        return false, "entity capabilities require the admin-owned active VJ agent"
    end
    if not istable(arguments) then return false, "entity capability arguments must be an object" end
    local validatorOK, argsValid, argumentError = pcall(adapter.validateArguments, arguments)
    if not validatorOK or argsValid ~= true then
        return false, argumentError or "entity capability arguments are invalid"
    end
    local target = Entity(entityID)
    if not IsValid(target) or target:GetClass() ~= adapter.class then
        return false, "the referenced entity does not match the capability adapter"
    end
    local visible = false
    local ok, observation = pcall(adapter.observe, actor, target)
    if ok and istable(observation) then visible = true end
    if not visible then return false, "the entity is no longer visible to this agent" end
    local executed, accepted, message = pcall(adapter.execute, ply, actor, target, arguments)
    if not executed then return false, "entity capability handler failed" end
    return accepted == true, message or "entity capability completed"
end

MCP.RegisterEntityAdapter({
    class = "func_button",
    capability = "map_button.press",
    maxVisible = MAX_VISIBLE_ENTITIES,
    tool = {
        name = "press_visible_button",
        description = "Press a currently visible func_button near the admin-owned VJ agent. The game rechecks entity class, visibility, and distance; only call this when the admin asked for the in-game interaction.",
        inputSchema = {
            type = "object",
            properties = {entity_id = {type = "integer", minimum = 1, maximum = 8192}},
            required = {"entity_id"},
            additionalProperties = false
        },
        annotations = {readOnlyHint = false, destructiveHint = true}
    },
    validateArguments = function(arguments)
        if not istable(arguments) or table.Count(arguments) ~= 1
            or not isnumber(arguments.entity_id) or arguments.entity_id ~= math.floor(arguments.entity_id)
            or arguments.entity_id < 1 or arguments.entity_id > 8192 then
            return false, "entity_id must be an integer from 1 to 8192"
        end
        return true
    end,
    observe = function(actor, button)
        if not IsValid(actor) or not IsValid(button) then return end
        local distance = actor:GetPos():Distance(button:WorldSpaceCenter())
        if distance > VISIBLE_BUTTON_RANGE then return end
        local trace = util.TraceLine({
            start = actor:EyePos(),
            endpos = button:WorldSpaceCenter(),
            filter = actor,
            mask = MASK_VISIBLE_AND_NPCS
        })
        if trace.Hit and trace.Entity ~= button then return end
        return {distance = math.Round(distance, 1)}
    end,
    execute = function(ply, actor, button, arguments)
        if arguments.entity_id ~= button:EntIndex() then
            return false, "entity_id did not match the resolved button"
        end
        return MCP.PressVisibleButton(ply, actor, button:EntIndex())
    end
})

MCP.RegisterEntityAdapter({
    class = "prop_physics",
    capability = "world_prop.inspect",
    maxVisible = MAX_VISIBLE_ENTITIES,
    tool = {
        name = "inspect_visible_prop",
        description = "Read bounded details about a currently visible nearby physics prop. This tool does not move or modify the prop.",
        inputSchema = {
            type = "object",
            properties = {entity_id = {type = "integer", minimum = 1, maximum = 8192}},
            required = {"entity_id"},
            additionalProperties = false
        },
        annotations = {readOnlyHint = true, destructiveHint = false}
    },
    validateArguments = function(arguments)
        if not istable(arguments) or table.Count(arguments) ~= 1
            or not isnumber(arguments.entity_id) or arguments.entity_id ~= math.floor(arguments.entity_id)
            or arguments.entity_id < 1 or arguments.entity_id > 8192 then
            return false, "entity_id must be an integer from 1 to 8192"
        end
        return true
    end,
    observe = function(actor, prop)
        if not IsValid(actor) or not IsValid(prop) then return end
        local distance = actor:GetPos():Distance(prop:WorldSpaceCenter())
        if distance > VISIBLE_PROP_RANGE then return end
        local trace = util.TraceLine({
            start = actor:EyePos(),
            endpos = prop:WorldSpaceCenter(),
            filter = {actor, prop},
            mask = MASK_VISIBLE_AND_NPCS
        })
        if trace.Hit then return end
        return {distance = math.Round(distance, 1)}
    end,
    execute = function(ply, actor, prop, arguments)
        if arguments.entity_id ~= prop:EntIndex() then
            return false, "entity_id did not match the resolved prop"
        end
        local model = cleanText(prop:GetModel(), 128)
        local mass = "unknown"
        local phys = prop:GetPhysicsObject()
        if IsValid(phys) then mass = tostring(math.Round(phys:GetMass(), 1)) end
        local health = prop:Health()
        return true, "class=prop_physics model=" .. model .. " mass=" .. mass .. " health=" .. tostring(health)
    end
})

local function writeResult(id, ok, result)
    local encoded = util.TableToJSON({ok = ok == true, result = cleanText(result, 900)}, false)
    if encoded then file.Write(RESULTS .. "/" .. id .. ".txt", encoded) end
end

local function applyCommand(command, expectedId)
    local id = expectedId or (istable(command) and command.id or "")
    local function makeReply(ok, message)
        return {schema_version = 1, id = id, ok = ok == true, result = cleanText(message, 900)}
    end
    if not string.match(id, "^[%x%-]+$") or #id ~= 36 then
        return makeReply(false, "MCP behavior command identifier was invalid")
    end
    if not istable(command) or command.schema_version ~= 1 or command.id ~= id then
        return makeReply(false, "MCP action command did not match the game schema")
    end
    if command.action == "install_starfall_behavior" then
        if table.Count(command) ~= 5 or not isstring(command.source) then
            return makeReply(false, "MCP behavior command did not match the game schema")
        end
        if #command.source < 1 then return makeReply(false, "Starfall behavior source is empty") end
    elseif command.action == "set_agent_expression" then
        if table.Count(command) ~= 5 or not isstring(command.expression)
            or not MCP_EXPRESSIONS[command.expression] then
            return makeReply(false, "MCP expression command did not match the supported preset schema")
        end
    elseif command.action == "set_agent_following" then
        if table.Count(command) ~= 5 or not isbool(command.enabled) then
            return makeReply(false, "MCP VJ follow command did not match the supported schema")
        end
    elseif command.action == "play_agent_animation" then
        if table.Count(command) ~= 5 or not isstring(command.cue)
            or not AICitizenNPC.Presentation.IsCue(command.cue) then
            return makeReply(false, "MCP animation command did not match the supported cue schema")
        end
    elseif command.action == "spawn_agent_component" then
        if table.Count(command) ~= 5 or not isstring(command.model)
            or command.model == "" or not util.IsValidModel(command.model) then
            return makeReply(false, "MCP component spawn command did not match the GMod model schema")
        end
    elseif command.action == "remove_agent_component" then
        if table.Count(command) ~= 5 or not isnumber(command.entity_id)
            or command.entity_id ~= math.floor(command.entity_id)
            or command.entity_id < 1 or command.entity_id > 8192 then
            return makeReply(false, "MCP component removal command did not match the entity-ID schema")
        end
    elseif command.action == "press_visible_button" then
        if table.Count(command) ~= 5 or not isnumber(command.entity_id)
            or command.entity_id ~= math.floor(command.entity_id) then
            return makeReply(false, "MCP button command did not match the supported schema")
        end
    elseif command.action == "invoke_entity_capability" then
        if table.Count(command) ~= 7 or not isstring(command.capability)
            or not isnumber(command.entity_id) or command.entity_id ~= math.floor(command.entity_id)
            or not istable(command.arguments) then
            return makeReply(false, "MCP entity capability command did not match the supported schema")
        end
    else
        return makeReply(false, "MCP action is not supported by the game")
    end
    if tonumber(command.expires_at_unix or 0) < os.time() then
        return makeReply(false, "MCP behavior command expired before the game consumed it")
    end
    if command.action == "set_agent_following" then
        if not cvarBool("ai_citizen_npc_ai_mcp_enabled")
            or not cvarBool("ai_citizen_npc_ai_mcp_vj_actions_enabled") then
            return makeReply(false, "VJ agent actions are disabled in the live game")
        end
        local actor = activeBody()
        local owner = IsValid(actor) and actor.ACNOwner or nil
        local applied, message = MCP.SetVJFollowing(owner, actor, command.enabled)
        return makeReply(applied, message)
    end
    if command.action == "play_agent_animation" then
        if not cvarBool("ai_citizen_npc_ai_mcp_enabled")
            or not cvarBool("ai_citizen_npc_ai_animation_enabled") then
            return makeReply(false, "agent animation cues are disabled in the live game")
        end
        local actor = activeBody()
        local owner = IsValid(actor) and actor.ACNOwner or nil
        local applied, message = MCP.PlayVJAnimation(owner, actor, command.cue)
        return makeReply(applied, message)
    end
    if command.action == "spawn_agent_component" or command.action == "remove_agent_component" then
        if not cvarBool("ai_citizen_npc_ai_mcp_enabled")
            or not cvarBool("ai_citizen_npc_ai_mcp_vj_actions_enabled") then
            return makeReply(false, "MCP agent component actions are disabled in the live game")
        end
        local actor = activeBody()
        if not IsValid(actor) or actor:GetClass() ~= "npc_vj_ai_citizen_npc" then
            return makeReply(false, "agent components are supported only by the AI Citizen NPC")
        end
        local owner = IsValid(actor) and actor.ACNOwner or nil
        local applied, message
        if command.action == "spawn_agent_component" then
            applied, message = MCP.SpawnOwnedAgentComponent(owner, actor, command.model)
        else
            applied, message = MCP.RemoveOwnedAgentComponent(owner, actor, command.entity_id)
        end
        return makeReply(applied, message)
    end
    if command.action == "press_visible_button" then
        if not cvarBool("ai_citizen_npc_ai_mcp_enabled")
            or not cvarBool("ai_citizen_npc_ai_mcp_vj_actions_enabled") then
            return makeReply(false, "VJ agent actions are disabled in the live game")
        end
        local actor = activeBody()
        local owner = IsValid(actor) and actor.ACNOwner or nil
        local applied, message = MCP.ExecuteEntityCapability(owner, actor, "map_button.press", command.entity_id,
            {entity_id = command.entity_id})
        return makeReply(applied, message)
    end
    if command.action == "invoke_entity_capability" then
        if not cvarBool("ai_citizen_npc_ai_mcp_enabled")
            or not cvarBool("ai_citizen_npc_ai_mcp_vj_actions_enabled") then
            return makeReply(false, "VJ agent actions are disabled in the live game")
        end
        local actor = activeBody()
        local owner = IsValid(actor) and actor.ACNOwner or nil
        local applied, message = MCP.ExecuteEntityCapability(owner, actor, command.capability,
            command.entity_id, command.arguments)
        return makeReply(applied, message)
    end
    if not cvarBool("ai_citizen_npc_ai_mcp_enabled") or authorizationExpires <= CurTime()
        or authorizationOwner ~= AICitizenNPC.Starfall.GetOwner()
        or not AICitizenNPC.Starfall.CanInstallBehavior(authorizationOwner) then
        return makeReply(false, "The live admin authorization or Starfall gate is no longer active")
    end

    local owner = authorizationOwner
    if command.action == "set_agent_expression" then
        local ok, applied, message = pcall(AICitizenNPC.Starfall.SetAgentExpression, owner, command.expression)
        if not ok then
            MCP.RecordEvent("mcp_expression_failed", "Starfall expression dispatch raised a server error", owner:Nick())
            return makeReply(false, "Starfall expression dispatch raised a server error")
        end
        if applied ~= true then return makeReply(false, message or "Starfall expression was rejected") end
        MCP.RecordEvent("mcp_expression_set", "Starfall expression set to " .. command.expression, owner:Nick())
        MCP.PublishState()
        return makeReply(true, "expression=" .. command.expression)
    end

    authorizationOwner = nil
    authorizationExpires = 0
    stateExpiresAtUnix = 0
    timer.Remove("AICitizenNPC.MCPAuthorizationExpiry")

    local ok, applied, message = pcall(AICitizenNPC.Starfall.ApplyBehavior, owner, command.source)
    if not ok then
        message = "Starfall behavior installation raised a server error"
        MCP.RecordEvent("mcp_tool_failed", "Starfall behavior installation raised an error", owner:Nick())
    else
        local success = applied == true
        MCP.RecordEvent(success and "mcp_tool_installed" or "mcp_tool_rejected", message, owner:Nick())
        message = makeReply(success, message)
    end
    MCP.PublishState()
    if not ok then return makeReply(false, message) end
    return message
end

local function processCommand(filename)
    if not string.match(filename, "^[%x%-]+%.txt$") then return end
    local id = string.sub(filename, 1, -5)
    if #id ~= 36 then return end
    local commandPath = COMMANDS .. "/" .. filename
    local raw = file.Read(commandPath, "DATA")
    file.Delete(commandPath)
    if not raw or #raw > MAX_COMMAND_BYTES then
        writeResult(id, false, "MCP behavior command was missing or oversized")
        return
    end
    local command = util.JSONToTable(raw)
    local reply = applyCommand(command, id)
    writeResult(id, reply.ok, reply.result)
end

local function nativeTool(name, description, properties, required, annotations)
    return {
        name = name,
        description = description,
        inputSchema = {type = "object", properties = properties or {}, required = required or {}, additionalProperties = false},
        annotations = annotations or {readOnlyHint = true, destructiveHint = false}
    }
end

local function nativeBehaviorAuthorized(state)
    return istable(state) and state.starfall_active == true
        and state.starfall_enabled == true and state.starfall_code_enabled == true
        and state.owner_is_admin == true
        and (tonumber(state.script_authorized_until_unix) or 0) > os.time()
end

local function activeNativeBehaviorOwner()
    local owner = authorizationOwner
    if authorizationExpires <= CurTime() or not IsValid(owner) or not owner:IsAdmin()
        or owner ~= AICitizenNPC.Starfall.GetOwner()
        or not cvarBool("ai_citizen_npc_ai_mcp_enabled")
        or not AICitizenNPC.Starfall.CanInstallBehavior(owner) then return nil end
    return owner
end

local function nativeTools(state)
    if not state.mcp_enabled then return {} end
    local tools = {
        nativeTool("get_agent_state", "Read the bounded active agent and game state."),
        nativeTool("list_visible_contacts", "List players and NPCs currently visible to the active agent."),
        nativeTool("list_visible_buttons", "List map buttons currently visible to the active agent."),
        nativeTool("read_recent_events", "Read up to 20 recent events from the agent session.",
            {limit = {type = "integer", minimum = 1, maximum = 20}})
    }
    if nativeBehaviorAuthorized(state) then
        tools[#tools + 1] = nativeTool("set_agent_expression",
            "Set one supported facial expression on the active owner-controlled StarfallEx instance.",
            {expression = {type = "string", enum = {"neutral", "speaking", "curious", "positive", "concerned"}}},
            {"expression"}, {readOnlyHint = false, destructiveHint = false})
        tools[#tools + 1] = nativeTool("install_starfall_behavior",
            "Install a Starfall Lua behavior module on the active owner-controlled StarfallEx instance. Use StarfallEx libraries under the instance's normal permissions and quotas; this does not execute GLua.",
            {source = {type = "string", minLength = 1}}, {"source"},
            {readOnlyHint = false, destructiveHint = true})
    end
    if state.body_runtime == "vj_base" and state.vj_actions_enabled and state.owner_is_admin then
        tools[#tools + 1] = nativeTool("set_agent_following",
            "Ask the admin-owned VJ Base agent to follow its owner or stop following.",
            {enabled = {type = "boolean"}}, {"enabled"}, {readOnlyHint = false, destructiveHint = false})
        if state.toolgun_ready then
            tools[#tools + 1] = nativeTool("spawn_agent_component",
                "Use the NPC-held Toolgun to spawn a physics component beside the agent using any model path recognized by this GMod installation.",
                {model = {type = "string"}}, {"model"},
                {readOnlyHint = false, destructiveHint = true})
        end
        if state.toolgun_ready and istable(state.owned_components) and #state.owned_components > 0 then
            tools[#tools + 1] = nativeTool("remove_agent_component",
                "Use the NPC-held Toolgun to remove one currently owned component by its fresh entity ID. Other world entities cannot be removed.",
                {entity_id = {type = "integer", minimum = 1, maximum = 8192}}, {"entity_id"},
                {readOnlyHint = false, destructiveHint = true})
        end
        for _, adapter in ipairs(state.entity_capability_catalog or {}) do
            local visible = false
            for _, item in ipairs(state.entity_capabilities or {}) do
                if item.class == adapter.class and item.capability == adapter.capability then visible = true break end
            end
            if visible and istable(adapter.tool) then tools[#tools + 1] = table.Copy(adapter.tool) end
        end
    end
    if state.body_runtime == "vj_base" and state.animation_enabled and state.owner_is_admin
        and istable(state.presentation_cues) and #state.presentation_cues > 0 then
        local cues = {}
        for _, item in ipairs(state.presentation_cues) do cues[#cues + 1] = item.cue end
        tools[#tools + 1] = nativeTool("play_agent_animation",
            "Play one currently supported semantic gesture on the admin-owned VJ Base agent. The game checks the active model and gives combat priority.",
            {cue = {type = "string", enum = cues}}, {"cue"},
            {readOnlyHint = false, destructiveHint = false})
    end
    return tools
end

local function nativeToolResult(ok, text)
    return {content = {{type = "text", text = cleanText(text, 64 * 1024)}}, isError = ok ~= true}
end

local function dispatchNativeTool(name, arguments)
    arguments = istable(arguments) and arguments or {}
    local count = table.Count(arguments)
    if name == "get_agent_state" and count == 0 then
        return true, util.TableToJSON(makeState(), false) or "state unavailable"
    elseif name == "list_visible_contacts" and count == 0 then
        local state = makeState()
        return true, util.TableToJSON(state.visible_contacts or {}, false) or "[]"
    elseif name == "list_visible_buttons" and count == 0 then
        local state = makeState()
        return true, util.TableToJSON(state.visible_buttons or {}, false) or "[]"
    elseif name == "read_recent_events" and (count == 0 or (count == 1 and isnumber(arguments.limit)
        and arguments.limit == math.floor(arguments.limit) and arguments.limit >= 1 and arguments.limit <= 20)) then
        local result = {}
        local limit = arguments.limit or 20
        for index = math.max(1, #events - limit + 1), #events do result[#result + 1] = events[index] end
        return true, util.TableToJSON(result, false) or "[]"
    end

    local state = makeState()
    if name == "set_agent_expression" then
        if count ~= 1 or not isstring(arguments.expression) or not MCP_EXPRESSIONS[arguments.expression] then
            return false, "set_agent_expression arguments did not match a supported preset"
        end
        if not nativeBehaviorAuthorized(state) then
            return false, "Starfall expression tools require an active admin-authorized script request"
        end
        local owner = activeNativeBehaviorOwner()
        if not owner then return false, "the Starfall owner authorization or feature gate is no longer active" end
        local called, applied, message = pcall(AICitizenNPC.Starfall.SetAgentExpression, owner, arguments.expression)
        if not called then return false, "Starfall expression dispatch failed" end
        if applied ~= true then return false, message or "Starfall rejected the expression" end
        MCP.RecordEvent("mcp_expression_set", "Starfall expression set to " .. arguments.expression, owner:Nick())
        MCP.PublishState()
        return true, "expression=" .. arguments.expression
    elseif name == "install_starfall_behavior" then
        if count ~= 1 or not isstring(arguments.source) or arguments.source == "" then
            return false, "install_starfall_behavior requires a nonempty Starfall source string"
        end
        if not nativeBehaviorAuthorized(state) then
            return false, "Starfall behavior installation requires an active admin-authorized script request"
        end
        local owner = activeNativeBehaviorOwner()
        if not owner then return false, "the Starfall owner authorization or feature gate is no longer active" end
        MCP.RevokeBehaviorRequest(owner)
        local called, applied, actorOrError = pcall(AICitizenNPC.Starfall.ApplyBehavior, owner, arguments.source)
        if not called then
            MCP.RecordEvent("mcp_tool_failed", "Starfall behavior installation raised an error", owner:Nick())
            return false, "Starfall behavior installation failed"
        end
        if applied ~= true then
            MCP.RecordEvent("mcp_tool_rejected", "Starfall rejected the requested behavior module", owner:Nick())
            return false, tostring(actorOrError or "Starfall rejected the requested behavior module")
        end
        local actor = AICitizenNPC.Starfall.GetActor()
        local result = "behavior_installed=true actor=" .. (IsValid(actor) and tostring(actor:EntIndex()) or "unknown")
        MCP.RecordEvent("mcp_tool_installed", "Starfall behavior module installed through native MCP", owner:Nick())
        MCP.PublishState()
        return true, result
    end
    if name == "set_agent_following" and count == 1 and isbool(arguments.enabled)
        and state.body_runtime == "vj_base" and state.vj_actions_enabled then
        local actor = activeBody()
        local owner = IsValid(actor) and actor.ACNOwner or nil
        local ok, message = MCP.SetVJFollowing(owner, actor, arguments.enabled)
        return ok, message
    end
    if name == "spawn_agent_component" and count == 1 and isstring(arguments.model)
        and arguments.model ~= "" and util.IsValidModel(arguments.model)
        and state.body_runtime == "vj_base" and state.vj_actions_enabled and state.toolgun_ready then
        local actor = activeBody()
        local owner = IsValid(actor) and actor.ACNOwner or nil
        local ok, message = MCP.SpawnOwnedAgentComponent(owner, actor, arguments.model)
        return ok, message
    end
    if name == "remove_agent_component" then
        if count ~= 1 or not isnumber(arguments.entity_id)
            or arguments.entity_id ~= math.floor(arguments.entity_id)
            or state.body_runtime ~= "vj_base" or not state.vj_actions_enabled or not state.toolgun_ready then
            return false, "remove_agent_component is unavailable for this session or argument"
        end
        for _, component in ipairs(state.owned_components or {}) do
            if component.entity_id == arguments.entity_id then
                local actor = activeBody()
                local owner = IsValid(actor) and actor.ACNOwner or nil
                return MCP.RemoveOwnedAgentComponent(owner, actor, arguments.entity_id)
            end
        end
        return false, "component ID is not in the active agent's current owned-component list"
    end
    if name == "play_agent_animation" and count == 1 and isstring(arguments.cue)
        and state.body_runtime == "vj_base" and state.animation_enabled then
        local cueAvailable = false
        for _, item in ipairs(state.presentation_cues or {}) do
            if item.cue == arguments.cue then cueAvailable = true break end
        end
        if not cueAvailable then return false, "the requested cue is not available on the active model" end
        local actor = activeBody()
        local owner = IsValid(actor) and actor.ACNOwner or nil
        local ok, message = MCP.PlayVJAnimation(owner, actor, arguments.cue)
        return ok, message
    end

    if count == 1 and isnumber(arguments.entity_id) and arguments.entity_id == math.floor(arguments.entity_id)
        and state.vj_actions_enabled and state.body_runtime == "vj_base" then
        for _, adapter in ipairs(state.entity_capability_catalog or {}) do
            if istable(adapter.tool) and adapter.tool.name == name then
                local actor = activeBody()
                local owner = IsValid(actor) and actor.ACNOwner or nil
                local ok, message = MCP.ExecuteEntityCapability(owner, actor, adapter.capability,
                    arguments.entity_id, arguments)
                return ok, message
            end
        end
    end
    return false, "unknown tool or arguments did not match the tool schema"
end

local function handleNativeHttp(request)
    local function httpReply(status, body, contentType)
        return status, { ["Content-Type"] = contentType or "application/json" }, body or ""
    end
    local function rpcError(status, id, code, message, data)
        local response = {jsonrpc = "2.0", error = {code = code, message = message}}
        if id ~= nil then response.id = id end
        if data ~= nil then response.error.data = data end
        return httpReply(status, util.TableToJSON(response, false) or "")
    end
    local function completeResult(result)
        result.resultType = "complete"
        result._meta = { ["io.modelcontextprotocol/serverInfo"] = {
            name = "citizen-agent-gmod", version = "0.2.0"
        } }
        return result
    end
    if request.method ~= "POST" then return httpReply(405, "", "") end
    if not cvarBool("ai_citizen_npc_ai_mcp_enabled") then return httpReply(503, "MCP is disabled") end
    if not isstring(request.body) or #request.body > MAX_COMMAND_BYTES then
        return rpcError(413, nil, -32600, "request too large")
    end
    local message = util.JSONToTable(request.body)
    if not istable(message) then return rpcError(400, nil, -32700, "parse error") end
    if message.jsonrpc ~= "2.0" or not isstring(message.method) then
        return rpcError(400, message.id, -32600, "invalid JSON-RPC request")
    end
    local hasID = isstring(message.id) or isnumber(message.id)
    if message.id ~= nil and not hasID then return rpcError(400, nil, -32600, "invalid JSON-RPC id") end
    if not hasID then return rpcError(400, nil, -32600, "client notifications are not supported on this stateless HTTP endpoint") end

    local params = istable(message.params) and message.params or nil
    local meta = params and params._meta or nil
    local headers = istable(request.headers) and request.headers or {}
    local headerVersion = headers["mcp-protocol-version"]
    local headerMethod = headers["mcp-method"]
    local requestedVersion = istable(meta) and meta["io.modelcontextprotocol/protocolVersion"] or nil
    local clientCapabilities = istable(meta) and meta["io.modelcontextprotocol/clientCapabilities"] or nil
    local function headerMismatch(reason)
        return rpcError(400, message.id, -32020, "HTTP header mismatch: " .. reason)
    end
    if not isstring(headerVersion) or not isstring(headerMethod) then
        return headerMismatch("MCP-Protocol-Version and Mcp-Method are required")
    end
    if headerMethod ~= message.method then return headerMismatch("Mcp-Method does not match request method") end
    if not istable(meta) or not isstring(requestedVersion) or not istable(clientCapabilities) then
        return rpcError(400, message.id, -32602, "request metadata requires protocolVersion and clientCapabilities")
    end
    if headerVersion ~= requestedVersion then return headerMismatch("MCP-Protocol-Version does not match request metadata") end
    local supportedVersions = {"2026-07-28"}
    if requestedVersion ~= supportedVersions[1] then
        return rpcError(400, message.id, -32022, "unsupported protocol version",
            {supported = supportedVersions, requested = requestedVersion})
    end
    if message.method == "tools/call" then
        local callParams = params
        if not isstring(headers["mcp-name"]) or not istable(callParams) or headers["mcp-name"] ~= callParams.name then
            return headerMismatch("Mcp-Name is required and must match params.name for tools/call")
        end
    end

    local result, errorObject, statusCode
    if message.method == "server/discover" then
        result = completeResult({
            supportedVersions = supportedVersions,
            -- GLua's JSON encoder serializes an empty Lua table as an array.
            -- Emit a real JSON object for the required MCP tools capability.
            capabilities = {tools = {listChanged = false}},
            instructions = "Read game state or use explicitly exposed, server-validated NPC actions."
        })
    elseif message.method == "ping" then
        result = completeResult({})
    elseif message.method == "tools/list" then
        result = completeResult({tools = nativeTools(makeState())})
    elseif message.method == "tools/call" then
        if not isstring(params.name) or (params.arguments ~= nil and not istable(params.arguments)) then
            errorObject = {code = -32602, message = "invalid tool parameters"}
            statusCode = 400
        else
            local ok, output = dispatchNativeTool(params.name, params.arguments)
            result = completeResult(nativeToolResult(ok, output))
        end
    else
        errorObject = {code = -32601, message = "method not found"}
        statusCode = 404
    end
    local response = {jsonrpc = "2.0", id = message.id}
    if errorObject then response.error = errorObject else response.result = result end
    local encoded = util.TableToJSON(response, false)
    if not encoded then return rpcError(500, message.id, -32603, "response encoding failed") end
    return httpReply(statusCode or 200, encoded)
end

local function updateNativeTransport()
    if not cvarBool("ai_citizen_npc_ai_mcp_native_enabled")
        or not cvarBool("ai_citizen_npc_ai_mcp_enabled") then
        if nativeModule and nativeModule.isListening() then nativeModule.stop() end
        nativePort = nil
        nativeRetryPort = nil
        nativeRetryAt = 0
        nativeRetryDelay = 1
        nativeLastStartFailure = nil
        return
    end
    if not nativeModule then
        local ok, module = pcall(require, "citizen_agent_mcp_native")
        if not ok then
            if not nativeLoadErrorReported then
                ErrorNoHalt("[AI Citizen NPC MCP] native module unavailable: " .. tostring(module) .. "\n")
                nativeLoadErrorReported = true
            end
            return
        end
        nativeModule = istable(GModMCP) and GModMCP or (istable(module) and module or nil)
    end
    if not nativeModule or not isfunction(nativeModule.start) or nativeModule.isListening() then return end
    local port = GetConVar("ai_citizen_npc_ai_mcp_native_port"):GetInt()
    if nativeRetryPort ~= port then
        nativeRetryPort = port
        nativeRetryAt = 0
        nativeRetryDelay = 1
        nativeLastStartFailure = nil
    end
    if SysTime() < nativeRetryAt then return end

    local function retryAfterFailure(reason)
        local signature = tostring(port) .. ":" .. tostring(reason)
        if signature ~= nativeLastStartFailure then
            ErrorNoHalt("[AI Citizen NPC MCP] native listener failed: " .. tostring(reason) .. "\n")
        end
        nativeLastStartFailure = signature
        nativeRetryAt = SysTime() + nativeRetryDelay
        nativeRetryDelay = math.min(nativeRetryDelay * 2, 30)
    end

    local token = string.Trim(file.Read(TOKEN_PATH, "DATA") or "")
    if #token < 40 and isfunction(nativeModule.generateToken) then
        local generated, value = pcall(nativeModule.generateToken)
        if generated and isstring(value) and #value == 43 then
            file.CreateDir(ROOT)
            file.Write(TOKEN_PATH, value)
            token = value
        end
    end
    if #token < 40 or #token > 64 or not string.match(token, "^[%w_%-]+$") then
        retryAfterFailure("native listener requires the sidecar-generated bearer token at " .. TOKEN_PATH)
        return
    end
    local ok, boundPort = pcall(nativeModule.start, port, token, handleNativeHttp)
    if not ok then
        retryAfterFailure(boundPort)
        return
    end
    nativePort = boundPort
    nativeRetryAt = 0
    nativeRetryDelay = 1
    nativeLastStartFailure = nil
    print("[AI Citizen NPC MCP] native Streamable HTTP listener bound to 127.0.0.1:" .. tostring(boundPort) .. "/mcp")
end

local function handleSocketMessage(raw)
    raw = tostring(raw or "")
    if #raw > MAX_GAME_BRIDGE_BYTES then return end
    local command = util.JSONToTable(raw)
    if not istable(command) then return end
    if command.type == "local_provider_delta" then
        local pending = isstring(command.id) and localProviderRequests[command.id] or nil
        if not pending or not isstring(command.delta) or command.delta == ""
            or #command.delta > MAX_COMMAND_BYTES then return end
        if isfunction(pending.delta) then pcall(pending.delta, command.delta) end
        return
    end
    if command.type == "local_provider_response" then
        local pending = isstring(command.id) and localProviderRequests[command.id] or nil
        if not pending or not isnumber(command.status) or command.status < 0 or command.status > 599
            or not isstring(command.body) or #command.body > MAX_COMMAND_BYTES then return end
        localProviderRequests[command.id] = nil
        timer.Remove(pending.timerName)
        if command.status == 0 then
            local reason = string.gsub(tostring(command.error or "Local provider relay failed"), "[%c]", " ")
            if isfunction(pending.failed) then pcall(pending.failed, string.sub(reason, 1, 240)) end
        elseif isfunction(pending.success) then
            pcall(pending.success, command.status, command.body)
        end
        return
    end
    local reply = applyCommand(command)
    local encoded = util.TableToJSON(reply, false)
    if encoded and gameSocket and socketState == "connected" then
        pcall(gameSocket.write, gameSocket, encoded)
    end
end

local function connectGameBridge()
    if socketState == "connecting" or socketState == "connected"
        or (not cvarBool("ai_citizen_npc_ai_mcp_enabled") and next(localProviderRequests) == nil) then return end
    if not GWSockets then
        local ok, module = pcall(require, "gwsockets")
        if not ok then return end
        GWSockets = module or GWSockets
    end
    if not GWSockets or not isfunction(GWSockets.createWebSocket) then return end
    local token = string.Trim(file.Read(TOKEN_PATH, "DATA") or "")
    if not string.match(token, "^[%w_%-]+$") or #token < 40 or #token > 64 then return end
    local port = GetConVar("ai_citizen_npc_ai_mcp_bridge_port"):GetInt()
    if port < 1 or port > 65535 then return end

    socketGeneration = socketGeneration + 1
    local generation = socketGeneration
    local ok, socket = pcall(GWSockets.createWebSocket, "ws://127.0.0.1:" .. port .. GAME_BRIDGE_PATH, true)
    if not ok or not socket then return end
    gameSocket = socket
    socketState = "connecting"
    local headerOk = pcall(socket.setHeader, socket, "Authorization", "Bearer " .. token)
    if not headerOk then
        gameSocket = nil
        socketState = "closed"
        pcall(socket.closeNow, socket)
        return
    end
    function socket:onConnected()
        if generation ~= socketGeneration then return end
        socketState = "connected"
        print("[AI Citizen NPC MCP] authenticated local game bridge connected")
        local queued = localProviderQueue
        localProviderQueue = {}
        for _, request in ipairs(queued) do
            if localProviderRequests[request.id] then
                local encoded = util.TableToJSON(request, false)
                if encoded and #encoded <= MAX_GAME_BRIDGE_BYTES then
                    local wrote = pcall(gameSocket.write, gameSocket, encoded)
                    if not wrote then
                        local pending = localProviderRequests[request.id]
                        if pending then
                            localProviderRequests[request.id] = nil
                            timer.Remove(pending.timerName)
                            if isfunction(pending.failed) then pcall(pending.failed, "could not send request to the Local provider relay") end
                        end
                    end
                else
                    local pending = localProviderRequests[request.id]
                    if pending then
                        localProviderRequests[request.id] = nil
                        timer.Remove(pending.timerName)
                        if isfunction(pending.failed) then pcall(pending.failed, "Local provider request exceeded the bridge message limit") end
                    end
                end
            end
        end
    end
    function socket:onMessage(message)
        if generation == socketGeneration then handleSocketMessage(message) end
    end
    function socket:onError(reason)
        if generation ~= socketGeneration then return end
        socketGeneration = socketGeneration + 1
        gameSocket = nil
        socketState = "closed"
        pcall(socket.closeNow, socket)
        print("[AI Citizen NPC MCP] local bridge error: " .. string.gsub(tostring(reason or "unknown"), "[%c]", " "))
    end
    function socket:onDisconnected()
        if generation ~= socketGeneration then return end
        socketGeneration = socketGeneration + 1
        gameSocket = nil
        socketState = "closed"
    end
    local opened = pcall(socket.open, socket, true)
    if not opened then
        gameSocket = nil
        socketState = "closed"
    end
end

local function stopGameBridge()
    if not gameSocket and socketState == "closed" then return end
    socketGeneration = socketGeneration + 1
    local socket = gameSocket
    gameSocket = nil
    socketState = "closed"
    if socket then pcall(socket.closeNow, socket) end
end

local function sendLocalProviderRequest(request)
    if socketState ~= "connected" or not gameSocket then
        localProviderQueue[#localProviderQueue + 1] = request
        connectGameBridge()
        return true
    end
    local encoded = util.TableToJSON(request, false)
    if not encoded or #encoded > MAX_GAME_BRIDGE_BYTES then return false end
    local ok = pcall(gameSocket.write, gameSocket, encoded)
    return ok
end

function MCP.RequestLocalProvider(options, callbacks)
    callbacks = istable(callbacks) and callbacks or {}
    if not istable(options) or not isstring(options.url)
        or (options.method ~= "GET" and options.method ~= "POST")
        or not istable(options.headers) or not isnumber(options.timeout)
        or not isfunction(callbacks.success) or not isfunction(callbacks.failed)
        or (callbacks.delta ~= nil and not isfunction(callbacks.delta)) then
        if isfunction(callbacks.failed) then callbacks.failed("invalid Local provider relay request") end
        return false
    end
    local body = options.body or ""
    if not isstring(body) or #body > MAX_COMMAND_BYTES
        or (options.method == "GET" and body ~= "")
        or (options.method == "POST" and body == "") then
        callbacks.failed("Local provider request body is invalid or too large")
        return false
    end

    localProviderSequence = localProviderSequence + 1
    local id = "local-" .. tostring(os.time()) .. "-" .. tostring(localProviderSequence)
    local request = {
        type = "local_provider_request",
        id = id,
        method = options.method,
        url = options.url,
        headers = options.headers,
        body = body,
        timeout_ms = math.Clamp(math.floor(options.timeout * 1000), 5000, 120000)
    }
    local pending = {
        success = callbacks.success,
        failed = callbacks.failed,
        delta = callbacks.delta,
        timerName = "AICitizenNPC.LocalProvider." .. id
    }
    localProviderRequests[id] = pending
    timer.Create(pending.timerName, request.timeout_ms / 1000 + 2, 1, function()
        if localProviderRequests[id] ~= pending then return end
        localProviderRequests[id] = nil
        if isfunction(pending.failed) then pcall(pending.failed, "Local provider relay request timed out; check that the sidecar and model server are running") end
    end)

    if not sendLocalProviderRequest(request) then
        localProviderRequests[id] = nil
        timer.Remove(pending.timerName)
        callbacks.failed("could not send request to the Local provider relay")
        return false
    end
    return true
end

local function pollCommands()
    -- The file-backed MCP command path is opt-in. Avoid waking the file
    -- system 6-7 times per second while MCP is disabled (the default).
    if not cvarBool("ai_citizen_npc_ai_mcp_enabled") then return end
    file.CreateDir(COMMANDS)
    file.CreateDir(RESULTS)
    local files = file.Find(COMMANDS .. "/*.txt", "DATA")
    for index = 1, math.min(#files, 4) do
        local ok, err = pcall(processCommand, files[index])
        if not ok then print("[AI Citizen NPC MCP] command dispatch failed: " .. tostring(err)) end
    end
end

function MCP.Install()
    CreateConVar("ai_citizen_npc_ai_mcp_enabled", "0", FCVAR_ARCHIVE,
        "Allow the configured private MCP tunnel to read the agent session and broker Starfall behavior")
    CreateConVar("ai_citizen_npc_ai_mcp_bridge_port", "42682", FCVAR_ARCHIVE,
        "Loopback MCP sidecar WebSocket port")
    CreateConVar("ai_citizen_npc_ai_mcp_native_enabled", "0", FCVAR_ARCHIVE,
        "Enable the optional native loopback MCP HTTP listener")
    CreateConVar("ai_citizen_npc_ai_mcp_native_port", "42683", FCVAR_ARCHIVE,
        "Loopback port for the native MCP HTTP listener")
    CreateConVar("ai_citizen_npc_ai_mcp_vj_actions_enabled", "0", FCVAR_ARCHIVE,
        "Allow MCP tools to control the admin-owned AI Citizen follow behavior")
    CreateConVar("ai_citizen_npc_ai_animation_enabled", "0", FCVAR_ARCHIVE,
        "Allow model tools to request validated semantic gestures on the admin-owned AI Citizen NPC")
    CreateConVar("ai_citizen_npc_ai_vj_actions_enabled", "0", FCVAR_ARCHIVE,
        "Allow direct provider function tools to control the admin-owned AI Citizen NPC")
    cvars.RemoveChangeCallback("ai_citizen_npc_ai_mcp_enabled", "AICitizenNPC.MCPStatePrivacy")
    cvars.AddChangeCallback("ai_citizen_npc_ai_mcp_enabled", function()
        MCP.PublishState()
    end, "AICitizenNPC.MCPStatePrivacy")
    timer.Create("AICitizenNPC.MCPFiles", POLL_INTERVAL, 0, pollCommands)
    timer.Create("AICitizenNPC.MCPSocket", 2, 0, function()
        if cvarBool("ai_citizen_npc_ai_mcp_enabled") or next(localProviderRequests) ~= nil then
            connectGameBridge()
        else
            stopGameBridge()
        end
    end)
    timer.Create("AICitizenNPC.MCPNative", 1, 0, updateNativeTransport)
    timer.Create("AICitizenNPC.MCPState", STATE_INTERVAL, 0, MCP.PublishState)
    hook.Add("PlayerDisconnected", "AICitizenNPC.MCPAuthorization", function(ply)
        if ply == authorizationOwner then
            authorizationOwner = nil
            authorizationExpires = 0
            stateExpiresAtUnix = 0
            timer.Remove("AICitizenNPC.MCPAuthorizationExpiry")
            MCP.PublishState()
        end
    end)
    MCP.PublishState()
end

MCP._test = {MakeState = makeState, ProcessCommand = processCommand, ApplyCommand = applyCommand,
    HandleNativeHttp = handleNativeHttp, NativeTools = nativeTools, MaxCommandBytes = MAX_COMMAND_BYTES,
    DispatchNativeTool = dispatchNativeTool, HandleSocketMessage = handleSocketMessage,
    LocalProviderRequests = localProviderRequests}
return MCP
