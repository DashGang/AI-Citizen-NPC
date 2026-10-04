AICitizenNPC = AICitizenNPC or {}
local Lab = AICitizenNPC
local addonRoot = "addons/ai_citizen_npc/lua/"
local NATIVE_TOOLGUN_CLASS = "gmod_tool"

local function agentToolgunAvailable()
    local definition = weapons.GetStored(NATIVE_TOOLGUN_CLASS)
    return istable(definition) and definition.CALUniversalToolgun == true
end

local function loadAddonLua(relative)
    local source = file.Read(addonRoot .. relative, "GAME")
    if not source then return include(relative) end
    local chunk = CompileString(source, relative, false)
    if isstring(chunk) then error(chunk) end
    return chunk()
end

if SERVER then
    AddCSLuaFile("autorun/ai_citizen_npc.lua")
    AddCSLuaFile("ai_citizen_npc/config.lua")
    AddCSLuaFile("ai_citizen_npc/cl_ui.lua")
    AddCSLuaFile("ai_citizen_npc/cl_dialogue.lua")
end
loadAddonLua("ai_citizen_npc/config.lua")

local VJ_AGENT_CLASS = "npc_vj_ai_citizen_npc"
local NPC_MODEL_CVAR = "ai_citizen_npc_ai_npc_model"
if SERVER and not GetConVar(NPC_MODEL_CVAR) then
    CreateConVar(NPC_MODEL_CVAR, Lab.Config.model, FCVAR_ARCHIVE,
        "Model path for newly spawned AI Citizens")
end
if SERVER and not GetConVar("ai_citizen_npc_ai_vj_follow_player") then
    CreateConVar("ai_citizen_npc_ai_vj_follow_player", "1", FCVAR_ARCHIVE,
        "Let AI Citizens follow allied players when they press Use; applies to newly spawned NPCs")
end
if SERVER and not GetConVar("ai_citizen_npc_ai_vj_use_spawnmenu_weapons") then
    CreateConVar("ai_citizen_npc_ai_vj_use_spawnmenu_weapons", "0", FCVAR_ARCHIVE,
        "Allow VJ Base spawn-menu weapon overrides on newly spawned AI Citizens")
end
local modelSetting = GetConVar(NPC_MODEL_CVAR)
if SERVER and modelSetting and util.IsValidModel(modelSetting:GetString()) then
    Lab.Config.model = modelSetting:GetString()
end

local function setNativeNPCClass(npc)
    if not IsValid(npc) or not isfunction(npc.SetNPCClass) then return false end
    npc:SetNPCClass(CLASS_PLAYER_ALLY)
    return npc:Classify() == CLASS_PLAYER_ALLY
end

local function bindVJAgent(npc, ply, requestedProvider)
    if not IsValid(npc) or npc:GetClass() ~= VJ_AGENT_CLASS then
        return false, "Invalid AI Citizen entity."
    end
    local owner = IsValid(ply) and ply
        or (IsValid(npc.ACNOwner) and npc.ACNOwner)
        or (IsValid(npc:GetCreator()) and npc:GetCreator())
    if IsValid(owner) and not owner:IsAdmin() then
        return false, "Only admins can spawn an AI Citizen."
    end

    local providers = Lab.Providers
    local provider = requestedProvider or npc.ACNProviderProfile or npc.ACNProviderSlot
        or (providers and providers.Selected and providers.Selected())
    if not providers or not provider or not providers.Definitions()[provider] then
        return false, "No supported provider slot is selected."
    end
    if not providers.SlotReady(provider) then
        return false, "Validate and enable the selected provider slot in AI Citizen NPC Config first."
    end
    for _, existing in ipairs(ents.FindByClass(VJ_AGENT_CLASS)) do
        if existing ~= npc and IsValid(existing) and existing.ACNAgentVJ == true
            and (existing.ACNProviderProfile or existing.ACNProviderSlot or "openai") == provider then
            return false, "That provider slot already has an active AI Citizen."
        end
    end

    npc.ACNAgentVJ = true
    npc.ACNOwner = owner
    npc.ACNProviderProfile = provider
    npc.ACNProviderSlot = provider
    if IsValid(owner) then
        npc:SetCreator(owner)
        npc:AddEntityRelationship(owner, D_LI, 10)
    end
    setNativeNPCClass(npc)
    return true, provider
end

local function registerVJAgent()
    if VJ and isfunction(VJ.AddPlugin) then
        local registered = false
        for _, plugin in ipairs(VJ.Plugins or {}) do
            if plugin.Name == "AI Citizen NPC" then registered = true break end
        end
        if not registered then VJ.AddPlugin("AI Citizen NPC", "AI Citizen NPC", "Beta 1") end
    end
    if not scripted_ents.GetStored("npc_vj_human_base") then return false end
    local definition = {
        Base = "npc_vj_human_base",
        Type = "ai",
        PrintName = "AI Citizen NPC (VJ Human)",
        Category = "AI Citizen NPC",
        Spawnable = true,
        AdminOnly = true,
        Model = {Lab.Config.model},
        StartHealth = 100,
        -- VJ Base forcibly strips weapons from passive human NPCs. Neutral
        -- keeps the agent allied with players, lets it defend itself if
        -- provoked, and permits the MCP Toolgun pickup/use path.
        Behavior = VJ_BEHAVIOR_NEUTRAL,
        VJ_NPC_Class = {"CLASS_PLAYER_ALLY"},
        AlliedWithPlayerAllies = true,
        Weapon_Disabled = false,
        Weapon_IgnoreSpawnMenu = not GetConVar("ai_citizen_npc_ai_vj_use_spawnmenu_weapons"):GetBool(),
        FollowPlayer = GetConVar("ai_citizen_npc_ai_vj_follow_player"):GetBool(),
        CanChatMessage = false,
        HasMeleeAttack = false,
        HasGrenadeAttack = false,
        HasFootstepSounds = false,
        VJ_ID_Civilian = true,
        PreInit = function(self)
            self.ACNAgentVJ = true
            if not SERVER then return end
            local creator = self:GetCreator()
            local requestedProvider = self.ACNProviderProfile or self.ACNProviderSlot
            if not IsValid(creator) and not requestedProvider then return end
            local ok, reason = bindVJAgent(self, creator, requestedProvider)
            if not ok then
                self.ACNAgentVJ = false
                self.ACNSpawnRejected = true
                timer.Simple(0, function()
                    if IsValid(self) then
                        -- VJ Base's continuous Spawner installs this callback
                        -- after Spawn() returns; remove it before rejecting the
                        -- actor so an unconfigured provider cannot respawn-loop.
                        if isfunction(self.RemoveCallOnRemove) then
                            self:RemoveCallOnRemove("vj_spawner_remove")
                        end
                        self:Remove()
                    end
                    if IsValid(creator) then creator:ChatPrint("[AI Citizen NPC] " .. reason) end
                end)
            end
        end
    }
    scripted_ents.Register(definition, VJ_AGENT_CLASS)
    -- Reconcile existing agents on autorun reload as well as new spawns.
    for _, existing in ipairs(ents.FindByClass(VJ_AGENT_CLASS)) do
        if existing.ACNAgentVJ == true then setNativeNPCClass(existing) end
    end
    if VJ and isfunction(VJ.AddNPC_HUMAN) then
        VJ.AddNPC_HUMAN("AI Citizen NPC (VJ Human)", VJ_AGENT_CLASS, {}, "AI Citizen NPC", {AdminOnly = true})
    end
    -- Also list this entity in Sandbox's built-in NPC creation tab. The
    -- PlayerSpawnedNPC hook below binds the selected provider slot and owner.
    list.Set("NPC", VJ_AGENT_CLASS, {
        Name = "AI Citizen NPC (VJ Human)",
        Class = VJ_AGENT_CLASS,
        Category = "AI Citizen NPC",
        AdminOnly = true,
        Weapons = {}
    })
    return true
end
Lab.RefreshVJAgentDefinition = registerVJAgent

local function ensureVJAgentRegistered()
    if registerVJAgent() then return end
    hook.Add("InitPostEntity", "AICitizenNPC.RegisterVJHuman", function()
        if registerVJAgent() then hook.Remove("InitPostEntity", "AICitizenNPC.RegisterVJHuman") end
    end)
end
ensureVJAgentRegistered()

function Lab.GetNPCModel()
    return Lab.Config.model
end

function Lab.SetNPCModel(value)
    value = string.Trim(tostring(value or "")):gsub("\\", "/")
    if #value < 8 or #value > 240
        or not string.match(value, "^models/[%w_/%-%.]+%.mdl$")
        or string.find(value, "..", 1, true) then
        return false, "enter a mounted .mdl path under models/ without parent-directory segments"
    end
    if not util.IsValidModel(value) then
        return false, "that model is missing or invalid on the game server"
    end
    local cv = GetConVar(NPC_MODEL_CVAR)
    if not cv then return false, "the NPC model setting is unavailable" end
    cv:SetString(value)
    Lab.Config.model = value
    if not registerVJAgent() then
        return false, "model saved, but VJ Base is not loaded yet"
    end
    return true, value
end

if SERVER then
    Lab.Identity = loadAddonLua("ai_citizen_npc/identity.lua")
    Lab.Perception = loadAddonLua("ai_citizen_npc/perception.lua")
    Lab.Telemetry = loadAddonLua("ai_citizen_npc/telemetry.lua")
    Lab.Starfall = loadAddonLua("ai_citizen_npc/starfall_bridge.lua")
    Lab.Presentation = loadAddonLua("ai_citizen_npc/presentation.lua")
    Lab.MCP = loadAddonLua("ai_citizen_npc/mcp_bridge.lua")
    Lab.Realtime = loadAddonLua("ai_citizen_npc/realtime_transport.lua")
    Lab.Providers = loadAddonLua("ai_citizen_npc/providers.lua")
    Lab.Chat = loadAddonLua("ai_citizen_npc/chat.lua")
    Lab.UI = loadAddonLua("ai_citizen_npc/ui_server.lua")
    Lab.ToolgunIntegration = loadAddonLua("ai_citizen_npc/toolgun_integration.lua")

    local function allowed(ply)
        return not IsValid(ply) or ply:IsAdmin()
    end
    local function spawnPosition(ply)
        if not IsValid(ply) then return Vector(0, 0, 16) end
        return ply:GetEyeTrace().HitPos + Vector(0, 0, 8)
    end

    local function spawnVJAgent(ply, spawnCommand, providerSlot)
        if not allowed(ply) then return end
        local provider = providerSlot or Lab.Providers.Selected()
        if not Lab.Providers.Definitions()[provider] then
            if IsValid(ply) then ply:ChatPrint("[AI Citizen NPC] Unsupported provider slot.") end
            return
        end
        if not Lab.Providers.SlotReady(provider) then
            if IsValid(ply) then ply:ChatPrint("[AI Citizen NPC] Validate and enable this provider slot in AI Citizen NPC Config first.") end
            return
        end
        for _, existing in ipairs(ents.FindByClass(VJ_AGENT_CLASS)) do
            if IsValid(existing) and existing.ACNAgentVJ == true
                and (existing.ACNProviderProfile or existing.ACNProviderSlot or "openai") == provider then
                if IsValid(ply) then ply:ChatPrint("[AI Citizen NPC] That provider key slot already has an active NPC.") end
                return
            end
        end
        if not registerVJAgent() then
            local message = "VJ Base npc_vj_human_base is not loaded; install/enable VJ Base first."
            if IsValid(ply) then ply:ChatPrint("[AI Citizen NPC] " .. message) else print("[AI Citizen NPC] " .. message) end
            return
        end
        local bot = ents.Create(VJ_AGENT_CLASS)
        if not IsValid(bot) then print("[AI Citizen NPC] AI Citizen creation failed") return end
        if IsValid(ply) then
            bot.ACNOwner = ply
            bot:SetCreator(ply)
        end
        bot:SetPos(spawnPosition(ply))
        bot.ACNProviderProfile = provider
        bot.ACNProviderSlot = provider
        bot:Spawn()
        bot:Activate()
        bot.ACNAgentVJ = true
        setNativeNPCClass(bot)
        if IsValid(ply) then bot:AddEntityRelationship(ply, D_LI, 10) end
        print("[AI Citizen NPC] spawned AI Citizen ent=" .. bot:EntIndex())
        if IsValid(ply) then
            spawnCommand = spawnCommand or "ai_citizen_npc_spawn"
            Lab.Chat.HandleAgentEvent(bot, ply, "command_spawn",
                "An administrator spawned you with " .. spawnCommand .. ".")
        end
    end
    Lab.SpawnVJAgent = spawnVJAgent
    concommand.Add("ai_citizen_npc_spawn", function(ply) spawnVJAgent(ply, "ai_citizen_npc_spawn") end)

    concommand.Add("ai_citizen_npc_toolgun_drop", function(ply)
        if not allowed(ply) then return end
        local trace = IsValid(ply) and ply:GetEyeTrace() or nil
        if not trace or not trace.Hit then return end
        local toolgunClass = agentToolgunAvailable() and NATIVE_TOOLGUN_CLASS or nil
        local dropped = toolgunClass and ents.Create(toolgunClass) or nil
        if not IsValid(dropped) then
            if IsValid(ply) then ply:ChatPrint("[AI Citizen NPC] Install the separate Universal Toolgun addon first.") end
            return
        end
        dropped:SetPos(trace.HitPos + Vector(0, 0, 12))
        dropped:Spawn()
        dropped:Activate()
        dropped:SetCollisionGroup(COLLISION_GROUP_WEAPON)
        if IsValid(ply) then ply:ChatPrint("[AI Citizen NPC] Dropped " .. toolgunClass .. " for nearby agent pickup.") end
    end)

    concommand.Add("ai_citizen_npc_vj_remove", function(ply)
        if not allowed(ply) then return end
        for _, bot in ipairs(ents.FindByClass(VJ_AGENT_CLASS)) do
            if IsValid(bot) and bot.ACNAgentVJ then bot:Remove() end
        end
        print("[AI Citizen NPC] removed AI Citizens")
    end)

    hook.Add("PlayerSpawnedNPC", "AICitizenNPC.ProviderSlotBinding", function(ply, npc)
        if not IsValid(ply) or not IsValid(npc) or npc:GetClass() ~= VJ_AGENT_CLASS
            or npc.ACNSpawnRejected == true then return end
        local ok, reason = bindVJAgent(npc, ply)
        if not ok then
            npc:Remove()
            ply:ChatPrint("[AI Citizen NPC] " .. reason)
        end
    end)

    hook.Add("EntityTakeDamage", "AICitizenNPC.VJDamageEvent", function(target, damage)
        if not IsValid(target) or target.ACNAgentVJ ~= true then return end
        local owner = target.ACNOwner
        if not IsValid(owner) or not Lab.Chat then return end
        local amount = math.Clamp(math.floor(tonumber(damage:GetDamage()) or 0), 0, 100000)
        timer.Simple(0, function()
            if not IsValid(target) or not IsValid(owner) or target.ACNAgentVJ ~= true then return end
            local health = math.Clamp(math.floor(target:Health()), 0, 100000)
            Lab.Chat.HandleAgentEvent(target, owner, "damage",
                string.format("You took %d damage and now have %d health remaining.", amount, health))
        end)
    end)

    hook.Add("PlayerUse", "AICitizenNPC.VJPlayerInteraction", function(ply, target)
        if not IsValid(ply) or not ply:IsPlayer() or not ply:KeyPressed(IN_USE)
            or not IsValid(target) or target:GetClass() ~= VJ_AGENT_CLASS
            or target.ACNAgentVJ ~= true or target.ACNOwner ~= ply or not ply:IsAdmin()
            or not Lab.Chat then return end
        local distance = math.floor(ply:GetPos():Distance(target:GetPos()))
        local eventText = "Your owner pressed Use on your body; distance_units=" .. tostring(distance) .. "."
        if Lab.Chat.HandleAgentEvent(target, ply, "player_interaction", eventText)
            and Lab.MCP and Lab.MCP.RecordEvent then
            Lab.MCP.RecordEvent("player_interaction", eventText, "owner")
        end
    end)

    concommand.Add("ai_citizen_npc_ragdoll", function(ply)
        if not allowed(ply) then return end
        local ragdoll = ents.Create("prop_ragdoll")
        if not IsValid(ragdoll) then print("[AI Citizen NPC] prop_ragdoll creation failed") return end
        ragdoll:SetModel(Lab.Config.model)
        ragdoll:SetPos(spawnPosition(ply))
        ragdoll:Spawn()
        ragdoll:Activate()
        print(string.format("[AI Citizen NPC] spawned ragdoll ent=%d phys_bones=%d",
            ragdoll:EntIndex(), ragdoll:GetPhysicsObjectCount()))
    end)

    concommand.Add("ai_citizen_npc_dump", function(ply, _, args)
        if not allowed(ply) then return end
        local requested = tonumber(args[1] or "")
        if requested then Lab.Telemetry.Dump(Entity(requested)) return end
        local count = 0
        for _, bot in ipairs(ents.FindByClass(VJ_AGENT_CLASS)) do
            if IsValid(bot) and bot.ACNAgentVJ then
                Lab.Telemetry.Dump(bot)
                count = count + 1
            end
        end
        if count == 0 then print("[AI Citizen NPC] no active AI Citizens") end
    end)

    concommand.Add("ai_citizen_npc_ai_status", function(ply, _, args)
        if not allowed(ply) then return end
        local mcp = Lab.MCP and Lab.MCP.TransportStatus and Lab.MCP.TransportStatus() or {}
        local requested = tonumber(args and args[1] or "")
        local agents = ents.FindByClass(VJ_AGENT_CLASS)
        local agent
        if requested then
            agent = Entity(math.floor(requested))
        else
            for _, candidate in ipairs(agents) do
                if IsValid(candidate) and candidate.ACNAgentVJ == true then
                    if IsValid(agent) then
                        agent = nil
                        break
                    end
                    agent = candidate
                end
            end
        end
        if requested and (not IsValid(agent) or agent:GetClass() ~= VJ_AGENT_CLASS
            or agent.ACNAgentVJ ~= true) then
            if IsValid(ply) then ply:ChatPrint("[AI Citizen NPC] That is not an active AI Citizen.") end
            return
        end
        local provider = IsValid(agent) and agent.ACNProviderProfile or Lab.Providers.Selected()
        local report = string.format(
            "[AI Citizen NPC] enabled=%s provider=%s model=%s key_configured=%s vj_agents=%d npc_ent=%s npc_health=%s npc_cue=%s npc_toolgun=%s starfall_actor=%s websocket_state=%s mcp_enabled=%s mcp_connection=%s",
            tostring(GetConVar("ai_citizen_npc_ai_enabled"):GetBool()),
            provider,
            Lab.Providers.Model(provider),
            tostring(Lab.Providers.KeyConfigured(provider)),
            #agents,
            IsValid(agent) and tostring(agent:EntIndex()) or "none",
            IsValid(agent) and tostring(agent:Health()) or "n/a",
            IsValid(agent) and tostring(agent.ACNPresentationLastCue or "idle") or "n/a",
            IsValid(agent) and tostring(Lab.MCP.AgentHasToolgun(agent)) or "n/a",
            tostring(IsValid(Lab.Starfall.GetActor())),
            tostring(Lab.Realtime and Lab.Realtime.State() or "unavailable"),
            tostring(mcp.enabled == true),
            tostring(mcp.connection or "unavailable"))
        if IsValid(ply) then ply:ChatPrint(report) else print(report) end
    end)

    Lab.Starfall.Install()
    Lab.MCP.Install()
    Lab.Chat.Install()
    Lab.UI.Install()
    if Lab.ToolgunIntegration and isfunction(Lab.ToolgunIntegration.Install) then
        Lab.ToolgunIntegration.Install(VJ_AGENT_CLASS)
    end
else
    loadAddonLua("ai_citizen_npc/cl_ui.lua")
    loadAddonLua("ai_citizen_npc/cl_dialogue.lua")
end
