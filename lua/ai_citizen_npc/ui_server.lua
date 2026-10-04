local UI = {}
local agentRemovalRefreshPending = false

local CHANNELS = {
    key = "AICitizenNPC.UI.Key",
    model = "AICitizenNPC.UI.Model",
    npc_model = "AICitizenNPC.UI.NPCModel",
    endpoint = "AICitizenNPC.UI.Endpoint",
    validate = "AICitizenNPC.UI.Validate",
    clear_key = "AICitizenNPC.UI.ClearKey",
    call_name = "AICitizenNPC.UI.CallName",
    slot = "AICitizenNPC.UI.Slot",
    option = "AICitizenNPC.UI.Option",
    select = "AICitizenNPC.UI.Select",
    spawn = "AICitizenNPC.UI.Spawn",
    remove = "AICitizenNPC.UI.Remove",
    status = "AICitizenNPC.UI.Status",
    starfall_attach = "AICitizenNPC.UI.StarfallAttach",
    starfall_remove = "AICitizenNPC.UI.StarfallRemove",
    reply = "AICitizenNPC.UI.Reply"
}

local PROVIDERS = {[1] = "openai", [2] = "openrouter", [3] = "local"}
local OPTIONS = {
    [1] = "ai_citizen_npc_ai_enabled",
    [2] = "ai_citizen_npc_ai_animation_enabled",
    [3] = "ai_citizen_npc_ai_mcp_enabled",
    [4] = "ai_citizen_npc_ai_starfall_enabled",
    [5] = "ai_citizen_npc_ai_vj_actions_enabled",
    [6] = "ai_citizen_npc_ai_mcp_vj_actions_enabled",
    [7] = "ai_citizen_npc_ai_starfall_code_enabled",
    [8] = "ai_citizen_npc_ai_npc_audio_events",
    [9] = "ai_citizen_npc_ai_chat_context",
    [10] = "ai_citizen_npc_ai_mcp_native_enabled",
    [11] = "ai_citizen_npc_ai_toolgun_pickup",
    [12] = "ai_citizen_npc_ai_vj_follow_player",
    [13] = "ai_citizen_npc_ai_vj_use_spawnmenu_weapons"
}

local function isAdmin(ply)
    return IsValid(ply) and ply:IsPlayer() and ply:IsAdmin()
end

local function reply(ply, message)
    if not IsValid(ply) then return end
    net.Start(CHANNELS.reply)
    net.WriteString(string.sub(tostring(message or ""), 1, 180))
    net.Send(ply)
end

local function providerForIndex(index)
    return PROVIDERS[index]
end

local function slotStatus(provider)
    local actors = {}
    for _, actor in ipairs(ents.FindByClass("npc_vj_ai_citizen_npc")) do
        if IsValid(actor) and actor.ACNAgentVJ == true
            and (actor.ACNProviderProfile or actor.ACNProviderSlot or "openai") == provider then
            actors[#actors + 1] = actor:EntIndex()
        end
    end
    local activeActor = actors[1] and Entity(actors[1]) or nil
    return {
        provider = provider,
        model = AICitizenNPC.Providers.Model(provider),
        key_configured = AICitizenNPC.Providers.KeyConfigured(provider),
        key_saved = AICitizenNPC.Providers.KeySaved(provider),
        key_session = AICitizenNPC.Providers.SessionKeyConfigured(provider),
        connection_configured = AICitizenNPC.Providers.ConnectionConfigured(provider),
        validated = AICitizenNPC.Providers.IsValidated(provider),
        enabled = AICitizenNPC.Providers.IsEnabled(provider),
        ready = AICitizenNPC.Providers.SlotReady(provider),
        call_name = AICitizenNPC.Providers.CallName(provider),
        base_url = provider == "local" and AICitizenNPC.Providers.BaseURL(provider) or nil,
        models = AICitizenNPC.Providers.ModelCatalog(provider),
        starfall_attached = AICitizenNPC.Starfall
            and isfunction(AICitizenNPC.Starfall.IsAttached)
            and actors[1] ~= nil and AICitizenNPC.Starfall.IsAttached(Entity(actors[1])) or false,
        npc_count = #actors,
        npc_ent = actors[1] or 0,
        npc_removing = IsValid(activeActor) and activeActor.ACNRemovalPending == true or false
    }
end

local function focusedAgentStatus(actor, ply)
    if not IsValid(actor) or actor:GetClass() ~= "npc_vj_ai_citizen_npc"
        or actor.ACNAgentVJ ~= true then return nil end
    local provider = actor.ACNProviderProfile or actor.ACNProviderSlot or "openai"
    local hasToolgun = false
    if AICitizenNPC.MCP and isfunction(AICitizenNPC.MCP.AgentHasToolgun) then
        local ok, result = pcall(AICitizenNPC.MCP.AgentHasToolgun, actor)
        hasToolgun = ok and result == true
    end
    return {
        entity = actor:EntIndex(),
        provider = provider,
        model = AICitizenNPC.Providers.Model(provider),
        body_model = actor:GetModel(),
        key_configured = AICitizenNPC.Providers.KeyConfigured(provider),
        call_name = AICitizenNPC.Providers.CallName(provider),
        health = actor:Health(),
        max_health = actor:GetMaxHealth(),
        cue = actor.ACNPresentationLastCue or "idle",
        toolgun_held = hasToolgun,
        owner = IsValid(actor.ACNOwner) and actor.ACNOwner:Nick() or "map/server"
    }
end

local function sendStatus(ply, focusedEntIndex)
    if not isAdmin(ply) then return end
    local snapshot = {
        selected_provider = AICitizenNPC.Providers.Selected(),
        npc_model = AICitizenNPC.GetNPCModel and AICitizenNPC.GetNPCModel()
            or AICitizenNPC.Config.model,
        ai_enabled = GetConVar("ai_citizen_npc_ai_enabled"):GetBool(),
        chat_context_enabled = GetConVar("ai_citizen_npc_ai_chat_context"):GetBool(),
        npc_audio_events_enabled = GetConVar("ai_citizen_npc_ai_npc_audio_events"):GetBool(),
        animation_enabled = GetConVar("ai_citizen_npc_ai_animation_enabled"):GetBool(),
        mcp_enabled = GetConVar("ai_citizen_npc_ai_mcp_enabled"):GetBool(),
        native_mcp_enabled = GetConVar("ai_citizen_npc_ai_mcp_native_enabled"):GetBool(),
        starfall_enabled = GetConVar("ai_citizen_npc_ai_starfall_enabled"):GetBool(),
        vj_actions_enabled = GetConVar("ai_citizen_npc_ai_vj_actions_enabled"):GetBool(),
        mcp_vj_actions_enabled = GetConVar("ai_citizen_npc_ai_mcp_vj_actions_enabled"):GetBool(),
        starfall_code_enabled = GetConVar("ai_citizen_npc_ai_starfall_code_enabled"):GetBool(),
        toolgun_pickup_enabled = GetConVar("ai_citizen_npc_ai_toolgun_pickup"):GetBool(),
        vj_follow_player = GetConVar("ai_citizen_npc_ai_vj_follow_player"):GetBool(),
        vj_use_spawnmenu_weapons = GetConVar("ai_citizen_npc_ai_vj_use_spawnmenu_weapons"):GetBool(),
        slots = {slotStatus("openai"), slotStatus("openrouter"), slotStatus("local")}
    }
    if AICitizenNPC.MCP and isfunction(AICitizenNPC.MCP.NativeTransportStatus) then
        snapshot.native_mcp = AICitizenNPC.MCP.NativeTransportStatus()
    end
    if AICitizenNPC.MCP and isfunction(AICitizenNPC.MCP.TransportStatus) then
        snapshot.mcp_transport = AICitizenNPC.MCP.TransportStatus()
    end
    if focusedEntIndex and focusedEntIndex > 0 then
        snapshot.focused = focusedAgentStatus(Entity(focusedEntIndex), ply)
        if not snapshot.focused then
            reply(ply, "That entity is not an active AI Citizen NPC.")
            return
        end
    end
    net.Start(CHANNELS.status)
    net.WriteString(util.TableToJSON(snapshot, false) or "{}")
    net.Send(ply)
end

function UI.Install()
    for _, channel in pairs(CHANNELS) do util.AddNetworkString(channel) end

    hook.Add("EntityRemoved", "AICitizenNPC.UI.AgentRemovedStatus", function(entity)
        if not entity or not isfunction(entity.GetClass)
            or entity:GetClass() ~= "npc_vj_ai_citizen_npc"
            or entity.ACNAgentVJ ~= true then return end
        if agentRemovalRefreshPending then return end

        agentRemovalRefreshPending = true
        timer.Simple(0, function()
            agentRemovalRefreshPending = false
            for _, ply in ipairs(player.GetAll()) do
                if isAdmin(ply) then sendStatus(ply) end
            end
        end)
    end)

    hook.Add("CanTool", "AICitizenNPC.UI.AgentRemovalPending", function(_, trace, mode)
        if mode ~= "remover" or not trace or not IsValid(trace.Entity)
            or trace.Entity:GetClass() ~= "npc_vj_ai_citizen_npc"
            or trace.Entity.ACNAgentVJ ~= true then return end

        local actor = trace.Entity
        timer.Simple(0, function()
            if not IsValid(actor) or actor.ACNAgentVJ ~= true or not actor:GetNoDraw() then return end
            actor.ACNRemovalPending = true
            for _, ply in ipairs(player.GetAll()) do
                if isAdmin(ply) then sendStatus(ply) end
            end
        end)
    end)

    net.Receive(CHANNELS.key, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        local length = net.ReadUInt(10)
        if not isAdmin(ply) then return end
        if not provider or length > 512 or length == 0 or (provider ~= "local" and length < 20) then
            reply(ply, "Key was not saved: choose a provider slot and enter a valid key.")
            return
        end
        local value = length > 0 and (net.ReadData(length) or "") or ""
        local ok, reason = AICitizenNPC.Providers.StoreKey(provider, value)
        if not ok then
            reply(ply, "Key was not saved: " .. tostring(reason))
            return
        end
        reply(ply, provider .. " key saved in server-only DATA storage. Validate this connection before enabling its slot.")
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.clear_key, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        if not isAdmin(ply) or not provider then return end
        local ok, reason = AICitizenNPC.Providers.ClearKey(provider)
        reply(ply, ok and (provider .. " session and saved keys removed; its slot was disabled.")
            or ("Key was not removed: " .. tostring(reason)))
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.model, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        local length = net.ReadUInt(8)
        if not isAdmin(ply) then return end
        if not provider or length < 1 or length > 128 then
            reply(ply, "Model setting was not saved.")
            return
        end
        local model = net.ReadData(length) or ""
        if not string.match(model, "^[%w_%.%-%/:]+$") then
            reply(ply, "Model IDs may contain only letters, numbers, dot, underscore, slash, colon, or hyphen.")
            return
        end
        local ok, reason = AICitizenNPC.Providers.SetModel(provider, model)
        if not ok then reply(ply, "Model was not saved: " .. tostring(reason)) return end
        reply(ply, provider .. " model saved.")
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.npc_model, function(_, ply)
        local length = net.ReadUInt(8)
        if not isAdmin(ply) or length < 8 or length > 240 then
            reply(ply, "NPC model was not saved: enter a valid mounted model path.")
            return
        end
        local value = net.ReadData(length) or ""
        if not AICitizenNPC.SetNPCModel then
            reply(ply, "NPC model selection is unavailable.")
            return
        end
        local ok, result = AICitizenNPC.SetNPCModel(value)
        reply(ply, ok
            and ("New AI Citizen NPCs will use " .. result .. ". Existing NPCs are unchanged.")
            or ("NPC model was not saved: " .. tostring(result)))
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.endpoint, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        local length = net.ReadUInt(9)
        if not isAdmin(ply) or provider ~= "local" or length < 8 or length > 240 then return end
        local value = net.ReadData(length) or ""
        local ok, reason = AICitizenNPC.Providers.SetBaseURL(value)
        reply(ply, ok and "Local provider URL saved. Validate it before enabling the slot." or ("Local URL was not saved: " .. tostring(reason)))
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.validate, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        local length = net.ReadUInt(10)
        if not isAdmin(ply) or not provider then return end
        if length > 512 then
            reply(ply, "Validation failed: key text is too long.")
            return
        end
        local value = length > 0 and (net.ReadData(length) or "") or ""
        local stored, keyReason = AICitizenNPC.Providers.SetSessionKey(provider, value)
        if not stored then
            reply(ply, provider .. " validation failed: " .. tostring(keyReason))
            return
        end
        local queued = AICitizenNPC.Providers.Validate(provider, function(ok, message)
            if not IsValid(ply) then return end
            reply(ply, provider .. (ok and " validation passed; " or " validation failed: ") .. tostring(message))
            sendStatus(ply)
        end)
        if queued then reply(ply, provider .. " model-catalog validation started.") end
    end)

    net.Receive(CHANNELS.call_name, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        local length = net.ReadUInt(5)
        if not isAdmin(ply) or not provider or length < 2 or length > 16 then return end
        local value = net.ReadData(length) or ""
        local ok, reason = AICitizenNPC.Providers.SetCallName(provider, value)
        reply(ply, ok and (provider .. " call name saved as !" .. AICitizenNPC.Providers.CallName(provider) .. ".") or ("Call name was not saved: " .. tostring(reason)))
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.slot, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        local enabled = net.ReadBool()
        if not isAdmin(ply) or not provider then return end
        local ok, reason = AICitizenNPC.Providers.SetEnabled(provider, enabled)
        reply(ply, ok and (provider .. " NPC slot " .. (enabled and "enabled." or "disabled.")) or tostring(reason))
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.option, function(_, ply)
        local option = OPTIONS[net.ReadUInt(4)]
        local enabled = net.ReadBool()
        if not isAdmin(ply) or not option then return end
        RunConsoleCommand(option, enabled and "1" or "0")
        if (option == "ai_citizen_npc_ai_vj_follow_player"
            or option == "ai_citizen_npc_ai_vj_use_spawnmenu_weapons")
            and isfunction(AICitizenNPC.RefreshVJAgentDefinition) then
            AICitizenNPC.RefreshVJAgentDefinition()
        end
        reply(ply, option .. " set to " .. (enabled and "on" or "off") .. ".")
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.select, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        if not isAdmin(ply) or not provider then return end
        RunConsoleCommand("ai_citizen_npc_ai_provider", provider)
        reply(ply, "Default provider set to " .. provider .. ".")
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.spawn, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        if not isAdmin(ply) or not provider then return end
        if not AICitizenNPC.SpawnVJAgent then
            reply(ply, "VJ Base spawn integration is unavailable.")
            return
        end
        AICitizenNPC.SpawnVJAgent(ply, "ai_citizen_npc_ui", provider)
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.remove, function(_, ply)
        local provider = providerForIndex(net.ReadUInt(2))
        if not isAdmin(ply) or not provider then return end
        local removed = false
        for _, actor in ipairs(ents.FindByClass("npc_vj_ai_citizen_npc")) do
            if IsValid(actor) and actor.ACNAgentVJ == true and actor.ACNOwner == ply
                and (actor.ACNProviderProfile or actor.ACNProviderSlot) == provider then
                actor:Remove()
                removed = true
                break
            end
        end
        reply(ply, removed and (provider .. " NPC removed.") or "No NPC owned by you occupies that provider slot.")
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.status, function(_, ply)
        if not isAdmin(ply) then return end
        if net.BytesLeft() < 2 then
            reply(ply, "Status request was incomplete; reopen the settings panel and retry.")
            return
        end
        sendStatus(ply, net.ReadUInt(16))
    end)

    net.Receive(CHANNELS.starfall_attach, function(_, ply)
        local actor = net.ReadEntity()
        if not isAdmin(ply) then return end
        if not AICitizenNPC.Starfall or not isfunction(AICitizenNPC.Starfall.Spawn) then
            reply(ply, "StarfallEx integration is unavailable.")
            return
        end
        local ok, result = AICitizenNPC.Starfall.Spawn(ply, actor)
        if not ok then
            reply(ply, "Starfall attach failed: " .. tostring(result))
            return
        end
        reply(ply, "Starfall expression component attached to VJ NPC " .. result:EntIndex() .. ".")
        if AICitizenNPC.Chat then
            AICitizenNPC.Chat.HandleAgentEvent(result, ply, "starfall_attached",
                "Your Starfall expressive interface is now connected.")
        end
        sendStatus(ply)
    end)

    net.Receive(CHANNELS.starfall_remove, function(_, ply)
        local actor = net.ReadEntity()
        if not isAdmin(ply) then return end
        local ok, reason = AICitizenNPC.Starfall.Remove(ply, actor)
        reply(ply, ok and "Starfall expression component detached; the VJ NPC remains." or tostring(reason))
        sendStatus(ply)
    end)

    print("[AI Citizen NPC] VJ settings bridge installed; keys remain server-side")
end

return UI
