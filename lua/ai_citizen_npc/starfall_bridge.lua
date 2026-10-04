local Bridge = {}

local SCRIPT_PATH = "addons/ai_citizen_npc/lua/ai_citizen_npc/starfall/agent_component.lua"
local DEFAULT_BEHAVIOR_PATH = "addons/ai_citizen_npc/lua/ai_citizen_npc/starfall/behavior.lua"
local AUDIT_PATH = "ai_citizen_npc/starfall/behavior_latest.txt"
local MAX_AGENT_EXPRESSION = 16
local AGENT_EXPRESSIONS = {neutral = true, speaking = true, curious = true, positive = true, concerned = true}
local activeProcessor
local activeOwner
local activeAgent
local activeBehaviorSource
local compileInProgress = false
local runtimeRecoveryPending = false
local bindingRecoveryAttempted = false
local bindingRecoveryError
local lastAgentExpressionAt = 0

local function say(text)
    print("[AI Citizen NPC Starfall] " .. tostring(text))
end

local function isAdmin(ply)
    return IsValid(ply) and ply:IsPlayer() and ply:IsAdmin()
end

local function recoverActiveBinding()
    if IsValid(activeProcessor) then return true end
    if bindingRecoveryAttempted then return false, bindingRecoveryError end
    bindingRecoveryAttempted = true

    local matches = {}
    for _, processor in ipairs(ents.FindByClass("starfall_processor")) do
        local instance = processor.instance
        local owner = instance and instance.player or nil
        local outputs = processor.Outputs
        local output = istable(outputs) and outputs.AgentBody or nil
        local actor = output and output.Value or nil
        if processor.ACNAgentStarfall == true
            and instance and instance.entity == processor
            and isAdmin(owner) and SF and owner ~= SF.Superuser
            and IsValid(actor) and actor:GetClass() == "npc_vj_ai_citizen_npc"
            and actor.ACNAgentVJ == true and actor.ACNOwner == owner
            and processor:GetParent() == actor then
            matches[#matches + 1] = {processor = processor, owner = owner, actor = actor}
        end
    end

    if #matches > 1 then
        bindingRecoveryError = "multiple tagged Starfall processors match AI Citizen NPCs owned by the current player; refusing ambiguous recovery"
        say(bindingRecoveryError)
        return false, bindingRecoveryError
    end
    if #matches == 0 then return false end

    local match = matches[1]
    activeProcessor = match.processor
    activeOwner = match.owner
    activeAgent = match.actor
    -- Prefer the bridge's committed marker. For a chip created before that marker
    -- existed, recover source only when processor data matches the live instance's
    -- compiled source exactly; never trust the mutable DATA audit file by itself.
    activeBehaviorSource = isstring(activeProcessor.ACNAgentBehaviorSource)
        and activeProcessor.ACNAgentBehaviorSource or nil
    if not activeBehaviorSource then
        local sfdataFiles = activeProcessor.sfdata and activeProcessor.sfdata.files
        local instanceFiles = activeProcessor.instance and activeProcessor.instance.source
        local savedSource = istable(sfdataFiles) and sfdataFiles["behavior.lua"] or nil
        local compiledSource = istable(instanceFiles) and instanceFiles["behavior.lua"] or nil
        if isstring(savedSource) and savedSource ~= "" and savedSource == compiledSource then
            activeBehaviorSource = savedSource
            activeProcessor.ACNAgentBehaviorSource = savedSource
            say("recovered committed Starfall behavior source from the matching live instance")
        end
    end
    say(string.format("recovered tagged processor=%d npc=%d owner-instance=normal behavior-source-known=%s",
        activeProcessor:EntIndex(), activeAgent:EntIndex(), tostring(activeBehaviorSource ~= nil)))
    return true
end

local function getActor()
    recoverActiveBinding()
    if not IsValid(activeProcessor) or not istable(activeProcessor.Outputs) then return nil end
    local output = activeProcessor.Outputs.AgentBody
    local actor = output and output.Value
    if not IsValid(actor) or actor:GetClass() ~= "npc_vj_ai_citizen_npc"
        or actor ~= activeAgent or actor.ACNAgentVJ ~= true then return nil end
    if not activeProcessor.instance or activeProcessor.instance.entity ~= activeProcessor then return nil end
    return actor
end

local function readSource(path, label)
    local source = file.Read(path, "GAME")
    if not isstring(source) or source == "" then return nil, label .. " is missing from the mounted addon" end
    return source
end

local function makeSFData(owner, behaviorSource)
    local main, mainError = readSource(SCRIPT_PATH, "Starfall expression component")
    if not main then return nil, mainError end
    return {
        owner = owner,
        files = {
            ["main"] = main,
            ["behavior.lua"] = behaviorSource
        },
        mainfile = "main",
        superuser = false
    }
end

local function clearLatchedChatInputs(processor)
    if not istable(processor.Inputs) then return true end
    for _, name in ipairs({"PlayerMessage", "GameEvent", "ModelReplyDelta", "ModelReply", "AgentExpression"}) do
        local input = processor.Inputs[name]
        if input then
            if input.Type ~= "STRING" then
                return false, "Starfall chat input " .. name .. " is not a string port"
            end
            -- StarfallEx replays each Wire input after Compile. Do not let a new
            -- behavior module process a stale player message or model reply.
            input.Value = ""
        end
    end
    return true
end

local function compileBehavior(processor, owner, source)
    local sfdata, dataError = makeSFData(owner, source)
    if not sfdata then return false, dataError end
    if processor == activeProcessor then
        local cleared, clearError = clearLatchedChatInputs(processor)
        if not cleared then return false, clearError end
    end
    compileInProgress = true
    local ok, err = pcall(processor.Compile, processor, sfdata)
    compileInProgress = false
    if not ok then return false, tostring(err) end
    if not processor.instance or processor.instance.player ~= owner or processor.instance.player == SF.Superuser then
        return false, processor.error and processor.error.message or "Starfall did not create a normal owner instance"
    end
    if not processor.TriggerInput then return false, "Starfall Wire input bridge is unavailable" end
    local inputOK, inputError = pcall(processor.TriggerInput, processor, "Agent", activeAgent)
    if not inputOK then return false, "could not bind the VJ NPC to Starfall: " .. tostring(inputError) end
    local actor = getActor()
    if not IsValid(actor) then return false, "Starfall program did not publish the bound VJ NPC output" end
    return true, actor
end

function Bridge.GetActor()
    return getActor()
end

function Bridge.IsAttached(actor)
    return IsValid(actor) and actor == getActor()
end

function Bridge.GetProcessor()
    recoverActiveBinding()
    if IsValid(activeProcessor) then return activeProcessor end
end

function Bridge.GetOwner()
    recoverActiveBinding()
    if IsValid(activeOwner) then return activeOwner end
end

function Bridge.IsOwnedBy(owner)
    getActor()
    return IsValid(activeProcessor) and activeOwner == owner
        and activeProcessor.instance and activeProcessor.instance.player == owner
        and activeProcessor.instance.player ~= SF.Superuser
end

function Bridge.CanInstallBehavior(owner)
    getActor()
    return GetConVar("ai_citizen_npc_ai_starfall_enabled"):GetBool()
        and GetConVar("ai_citizen_npc_ai_starfall_code_enabled"):GetBool()
        and isAdmin(owner) and activeBehaviorSource ~= nil
        and Bridge.IsOwnedBy(owner) and IsValid(getActor())
end

function Bridge.CanControlExpression(owner)
    return GetConVar("ai_citizen_npc_ai_starfall_enabled"):GetBool()
        and isAdmin(owner) and Bridge.IsOwnedBy(owner) and IsValid(getActor())
end

function Bridge.GetNearbyActor(ply, maxDistance)
    local actor = getActor()
    if not IsValid(actor) or not IsValid(ply) then return nil end
    if ply:GetPos():DistToSqr(actor:GetPos()) > (maxDistance * maxDistance) then return nil end
    return actor
end

local function sendInput(inputName, value)
    local actor = getActor()
    if not actor then return false, "Starfall agent is not running" end
    if not isstring(value) then return false, "input must be text" end
    if not activeProcessor.TriggerInput then return false, "Starfall Wire inputs are unavailable" end

    local ok, err = pcall(activeProcessor.TriggerInput, activeProcessor, inputName, value)
    if not ok then
        say("input " .. inputName .. " failed: " .. tostring(err))
        return false, "Starfall input failed"
    end
    return true
end

function Bridge.SendPlayerMessage(value)
    return sendInput("PlayerMessage", value)
end

function Bridge.SendGameEvent(value)
    return sendInput("GameEvent", value)
end

function Bridge.SendModelReply(value)
    return sendInput("ModelReply", value)
end

function Bridge.SendModelReplyDelta(value)
    return sendInput("ModelReplyDelta", value)
end

function Bridge.SetAgentExpression(owner, expression)
    if not Bridge.CanControlExpression(owner) then
        return false, "agent expression control is disabled or the requester does not own the Starfall agent"
    end
    if not isstring(expression) or #expression > MAX_AGENT_EXPRESSION or not AGENT_EXPRESSIONS[expression] then
        return false, "unsupported agent expression"
    end
    local now = CurTime()
    if lastAgentExpressionAt > 0 and now - lastAgentExpressionAt < 1 then
        return false, "agent expression requests are limited to one per second"
    end
    local sent, reason = sendInput("AgentExpression", expression, MAX_AGENT_EXPRESSION)
    if sent then
        lastAgentExpressionAt = now
        return true, "expression=" .. expression
    end
    return false, reason
end

function Bridge.Spawn(owner, actor)
    local _, recoveryError = recoverActiveBinding()
    if recoveryError then return false, recoveryError end
    if not GetConVar("ai_citizen_npc_ai_starfall_enabled"):GetBool() then
        return false, "Starfall agent runtime is disabled"
    end
    if not isAdmin(owner) then return false, "an admin player must own the Starfall instance" end
    if not IsValid(actor) or actor:GetClass() ~= "npc_vj_ai_citizen_npc"
        or actor.ACNAgentVJ ~= true then
        return false, "look at an active AI Citizen NPC to attach its Starfall expression component"
    end
    if actor.ACNOwner ~= owner then return false, "you must own the selected AI Citizen NPC" end
    if IsValid(activeProcessor) then return false, "a Starfall agent processor is already active" end
    if not SF or not SF.Instance or not isfunction(SF.Instance.Compile) then
        return false, "StarfallEx server runtime is unavailable"
    end
    if not WireLib then return false, "Wiremod is required for the typed chat bridge" end

    local behaviorSource, behaviorError = readSource(DEFAULT_BEHAVIOR_PATH, "Default Starfall behavior")
    if not behaviorSource then return false, behaviorError end
    local sfdata, dataError = makeSFData(owner, behaviorSource)
    if not sfdata then return false, dataError end
    activeAgent = actor

    local processor = ents.Create("starfall_processor")
    if not IsValid(processor) then activeAgent = nil return false, "Starfall processor creation failed" end
    processor:SetModel("models/spacecode/sfchip.mdl")
    processor:SetPos(actor:GetPos() + Vector(0, 0, 24))
    processor:SetCreator(owner)
    if CPPI then processor:CPPISetOwner(owner) end
    processor:Spawn()
    processor:Activate()
    processor:SetParent(actor)
    processor:SetLocalPos(Vector(0, 0, 24))
    processor:SetNoDraw(true)
    processor:SetNotSolid(true)

    local ok, err = pcall(processor.Compile, processor, sfdata)
    if not ok or not processor.instance then
        local detail = processor.error and processor.error.message or err or "Starfall compile or permission check failed"
        processor:Remove()
        activeAgent = nil
        return false, tostring(detail)
    end

    activeProcessor = processor
    activeOwner = owner
    activeBehaviorSource = behaviorSource
    processor.ACNAgentStarfall = true
    processor.ACNAgentBehaviorSource = behaviorSource
    local inputOK, inputError = pcall(processor.TriggerInput, processor, "Agent", actor)
    if not inputOK then
        processor:Remove()
        activeProcessor = nil
        activeOwner = nil
        activeAgent = nil
        activeBehaviorSource = nil
        return false, "Starfall compiled but its NPC Wire binding failed: " .. tostring(inputError)
    end
    local actor = getActor()
    if not IsValid(actor) then
        processor:Remove()
        activeProcessor = nil
        activeOwner = nil
        activeAgent = nil
        activeBehaviorSource = nil
        return false, "Starfall script did not publish the bound VJ NPC output"
    end

    say(string.format("attached processor=%d npc=%d owner=%s superuser=false",
        processor:EntIndex(), actor:EntIndex(), owner:Nick()))
    return true, actor
end

function Bridge.ApplyBehavior(owner, source)
    if not Bridge.CanInstallBehavior(owner) then return false, "model-authored Starfall behavior is disabled or the requester does not own the agent" end
    if not isstring(source) or #source == 0 then return false, "behavior source is empty" end
    file.CreateDir("ai_citizen_npc/starfall")
    file.Write(AUDIT_PATH, source)
    if file.Read(AUDIT_PATH, "DATA") ~= source then
        return false, "could not store the behavior source for server-side review"
    end

    local processor = activeProcessor
    local previous = activeBehaviorSource
    local ok, actorOrError = compileBehavior(processor, owner, source)
    if ok then
        activeBehaviorSource = source
        processor.ACNAgentBehaviorSource = source
        say(string.format("installed model-authored behavior on processor=%d actor=%d bytes=%d sha256=%s owner=%s",
            processor:EntIndex(), actorOrError:EntIndex(), #source, util.SHA256(source), owner:Nick()))
        return true, actorOrError
    end

    local failure = tostring(actorOrError)
    local restored, restoreResult = compileBehavior(processor, owner, previous)
    if restored then
        activeBehaviorSource = previous
        say("model-authored behavior failed; restored last known good Starfall module")
        return false, "compile failed and previous behavior was restored: " .. failure
    end

    activeProcessor = nil
    activeOwner = nil
    activeAgent = nil
    activeBehaviorSource = nil
    if IsValid(processor) then processor:Remove() end
    say("behavior compile and rollback failed; removed the Starfall expression processor")
    return false, "compile failed (" .. failure .. "); rollback also failed (" .. tostring(restoreResult) .. ")"
end

function Bridge.Remove(owner, actor)
    if not isAdmin(owner) then return false, "only an admin can remove the Starfall agent" end
    if not IsValid(activeProcessor) then
        activeProcessor = nil
        activeOwner = nil
        activeAgent = nil
        activeBehaviorSource = nil
        return false, "no Starfall agent processor is active"
    end
    if owner ~= activeOwner or (IsValid(actor) and actor ~= activeAgent) then
        return false, "the selected NPC is not bound to your Starfall component"
    end
    local processor = activeProcessor
    activeProcessor = nil
    activeOwner = nil
    activeAgent = nil
    activeBehaviorSource = nil
    processor:Remove()
    say("removed the separate Starfall expression processor; the VJ NPC remains")
    return true
end

function Bridge.Install()
    CreateConVar("ai_citizen_npc_ai_starfall_enabled", "0", FCVAR_ARCHIVE,
        "Allow the admin-owned Starfall expression component for a AI Citizen")
    CreateConVar("ai_citizen_npc_ai_starfall_code_enabled", "0", FCVAR_ARCHIVE,
        "Allow admin-requested model-authored behavior modules in the Starfall sandbox")

    recoverActiveBinding()

    concommand.Add("ai_citizen_npc_sf_spawn", function(ply)
        if not isAdmin(ply) then return end
        local trace = ply:GetEyeTrace()
        local ok, result = Bridge.Spawn(ply, trace.Entity)
        if not ok then ply:ChatPrint("[AI Citizen NPC Starfall] " .. tostring(result)) end
        if ok and AICitizenNPC.Chat then
            AICitizenNPC.Chat.HandleAgentEvent(result, ply, "command_spawn",
                "An administrator enabled your Starfall expression component.")
        end
    end)

    concommand.Add("ai_citizen_npc_sf_remove", function(ply)
        if not isAdmin(ply) then return end
        local ok, result = Bridge.Remove(ply, ply:GetEyeTrace().Entity)
        if not ok then ply:ChatPrint("[AI Citizen NPC Starfall] " .. tostring(result)) end
    end)

    hook.Add("EntityTakeDamage", "AICitizenNPC.StarfallDamageEvent", function(target, damage)
        if target ~= getActor() or not IsValid(target) then return end
        local owner = activeOwner
        if not IsValid(owner) or not AICitizenNPC.Chat then return end
        local amount = math.Clamp(math.floor(tonumber(damage:GetDamage()) or 0), 0, 100000)
        timer.Simple(0, function()
            if not IsValid(target) or not IsValid(owner) or getActor() ~= target then return end
            local health = math.Clamp(math.floor(target:Health()), 0, 100000)
            AICitizenNPC.Chat.HandleAgentEvent(target, owner, "damage",
                string.format("You took %d damage and now have %d health remaining.", amount, health))
        end)
    end)

    hook.Add("EntityRemoved", "AICitizenNPC.StarfallAgentRemoved", function(entity)
        if entity ~= activeAgent then return end
        local processor = activeProcessor
        activeProcessor = nil
        activeOwner = nil
        activeAgent = nil
        activeBehaviorSource = nil
        if IsValid(processor) then processor:Remove() end
        say("detached the Starfall expression processor because its VJ NPC was removed")
    end)

    hook.Add("StarfallError", "AICitizenNPC.StarfallRecovery", function(processor)
        if processor ~= activeProcessor or compileInProgress or runtimeRecoveryPending then return end
        runtimeRecoveryPending = true
        timer.Simple(0, function()
            runtimeRecoveryPending = false
            if processor ~= activeProcessor or not IsValid(processor) or processor.instance then return end
            local owner = activeOwner
            if not isAdmin(owner) then
                activeProcessor = nil
                activeOwner = nil
                activeAgent = nil
                activeBehaviorSource = nil
                processor:Remove()
                say("detached a Starfall expression processor after its owner became unavailable")
                return
            end

            local fallback, fallbackError = readSource(DEFAULT_BEHAVIOR_PATH, "Default Starfall behavior")
            if fallback then
                local recovered, recoveryResult = compileBehavior(processor, owner, fallback)
                if recovered then
                    activeBehaviorSource = fallback
                    processor.ACNAgentBehaviorSource = fallback
                    say("Starfall behavior raised a runtime error; restored the fixed default module")
                    return
                end
                fallbackError = recoveryResult
            end

            activeProcessor = nil
            activeOwner = nil
            activeAgent = nil
            activeBehaviorSource = nil
            processor:Remove()
            say("removed Starfall expression processor after runtime recovery failed: " .. tostring(fallbackError))
        end)
    end)
end

Bridge._test = {
    SendInput = sendInput,
    ScriptPath = SCRIPT_PATH,
    MaxAgentExpression = MAX_AGENT_EXPRESSION,
    AuditPath = AUDIT_PATH
}

return Bridge
