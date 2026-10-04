local Presentation = {}

local CUE_IDS = {
    acknowledge = true,
    disagree = true,
    explain = true,
    greet = true,
    point = true
}

local PACKS = {}
local BACKENDS = {}

local function validPackID(value)
    return isstring(value) and #value > 0 and #value <= 48
        and string.match(value, "^[%w_%.%-]+$") ~= nil
end

-- Playback backends are registered by trusted addon Lua. The model can only
-- request CUE_IDS; it cannot select a backend or pass backend arguments.
function Presentation.RegisterPlaybackBackend(backendID, version, backend)
    if not validPackID(backendID) or not isstring(version) or #version == 0 or #version > 32 then
        return false, "invalid animation backend identity"
    end
    if not istable(backend) or not isfunction(backend.resolve) or not isfunction(backend.play)
        or not isfunction(backend.stop) or not isfunction(backend.is_active) then
        return false, "backend must provide resolve, play, stop, and is_active methods"
    end
    BACKENDS[backendID] = {
        id = backendID,
        version = version,
        resolve = backend.resolve,
        play = backend.play,
        stop = backend.stop,
        is_active = backend.is_active
    }
    return true
end

-- Optional animation addons are discovery-only until their NPC playback contract
-- is verified. Never call addon functions here: a mounted player animation pack
-- does not imply that its sequences are available on a VJ Base NPC.
local OPTIONAL_ADDON_TITLES = {
    dynabase = {
        ["[wos] dynabase - dynamic animation manager"] = true,
        ["[wos] dynabase legacy extensions"] = true
    },
    animation_extension = {
        ["[wos] animation extension - base  (code only)"] = true,
        ["[wos] the ultimate animation pack"] = true
    }
}

function Presentation.DiscoverOptionalSources()
    local found = {
        dynabase = {mounted = false, addon_ids = {}, api_namespace = false},
        animation_extension = {mounted = false, addon_ids = {}, api_namespace = false}
    }
    if isfunction(engine.GetAddons) then
        for id, addon in pairs(engine.GetAddons() or {}) do
            local title = isstring(addon.title) and string.lower(addon.title) or ""
            for source, titles in pairs(OPTIONAL_ADDON_TITLES) do
                if titles[title] and addon.mounted == true then
                    found[source].mounted = true
                    found[source].addon_ids[#found[source].addon_ids + 1] = tostring(id)
                end
            end
        end
    end
    table.sort(found.dynabase.addon_ids)
    table.sort(found.animation_extension.addon_ids)
    found.dynabase.api_namespace = istable(wOS) and istable(wOS.DynaBase)
    found.animation_extension.api_namespace = istable(wOS) and istable(wOS.AnimExtension)
    return found
end

local function isAgent(actor)
    if not IsValid(actor) or actor:GetClass() ~= "npc_vj_ai_citizen_npc"
        or actor.ACNAgentVJ ~= true then return false end

    local model = actor:GetModel()
    local configuredModel = AICitizenNPC.Config and AICitizenNPC.Config.model
    return isstring(model) and model ~= ""
        and isstring(configuredModel) and configuredModel ~= ""
        and string.lower(model) == string.lower(configuredModel)
        and isfunction(actor.PlayAnim)
        and isfunction(actor.LookupSequence)
        and isfunction(actor.SequenceDuration)
end

function Presentation.RegisterContentPack(packID, version, definitions, priority)
    if not validPackID(packID) or not isstring(version) or #version == 0 or #version > 32 then
        return false, "invalid animation content pack identity"
    end
    if not istable(definitions) then return false, "content pack definitions must be a table" end

    local clean = {}
    for cue, candidates in pairs(definitions) do
        if not CUE_IDS[cue] or not istable(candidates) or #candidates > 16 then
            return false, "content pack contains an unsupported cue or candidate list"
        end
        clean[cue] = {}
        for _, candidate in ipairs(candidates) do
            if not istable(candidate)
                or (candidate.sequence ~= nil and (not isstring(candidate.sequence)
                    or #candidate.sequence == 0 or #candidate.sequence > 64
                    or not string.match(candidate.sequence, "^[%w_%.%-]+$")))
                or (candidate.backend ~= nil and not validPackID(candidate.backend))
                or (candidate.asset_id ~= nil and (not isstring(candidate.asset_id)
                    or #candidate.asset_id == 0 or #candidate.asset_id > 96
                    or not string.match(candidate.asset_id, "^[%w_%.:/%-]+$")))
                or (candidate.sequence == nil and candidate.asset_id == nil)
                or (candidate.model ~= nil and (not isstring(candidate.model) or #candidate.model > 128)) then
                return false, "content pack animation candidate is malformed"
            end
            clean[cue][#clean[cue] + 1] = {
                sequence = candidate.sequence,
                backend = candidate.backend or "vj_base",
                asset_id = candidate.asset_id,
                model = isstring(candidate.model) and string.lower(candidate.model) or nil
            }
        end
    end

    priority = tonumber(priority) or 0
    if priority ~= math.floor(priority) or priority < -100 or priority > 100 then
        return false, "content pack priority must be an integer from -100 to 100"
    end
    PACKS[packID] = {id = packID, version = version, priority = priority, definitions = clean}
    return true
end

Presentation.RegisterContentPack("stock_female_citizen", "1", {
    acknowledge = {{sequence = "hg_nod_yes"}},
    disagree = {{sequence = "hg_nod_no"}},
    greet = {{sequence = "g_wave"}},
    point = {{sequence = "g_point_l"}},
    explain = {{sequence = "g_palm_up_high_l"}}
})

Presentation.RegisterPlaybackBackend("vj_base", "1", {
    resolve = function(actor, candidate)
        if not isAgent(actor) or not isstring(candidate.sequence) then return nil end
        local sequenceID = actor:LookupSequence(candidate.sequence)
        if not isnumber(sequenceID) or sequenceID < 0 then return nil end
        local duration = actor:SequenceDuration(sequenceID)
        if not isnumber(duration) or duration <= 0 or duration > 4 then return nil end
        return {sequence = candidate.sequence, sequence_id = sequenceID, duration = duration}
    end,
    play = function(actor, resolved)
        -- VJ Base's AddGestureSequence path can reuse an overlay slot that its
        -- client animation update also owns (for example, turnright). Allocate
        -- a priority layer explicitly so this validated gesture replicates.
        local ok, layer = pcall(actor.AddLayeredSequence, actor, resolved.sequence_id, 2)
        if not ok or not isnumber(layer) or layer < 0 then
            return false, "GMod could not allocate a gesture overlay layer"
        end
        local configured = pcall(function()
            actor:SetLayerCycle(layer, 0)
            actor:SetLayerPlaybackRate(layer, 0.5)
            actor:SetLayerWeight(layer, 1)
        end)
        if not configured then
            pcall(actor.RemoveLayer, actor, layer)
            return false, "GMod could not configure the gesture overlay layer"
        end
        local playback = {
            sequence = resolved.sequence,
            sequence_id = resolved.sequence_id,
            duration = resolved.duration,
            layer_id = layer
        }
        -- Match VJ Base's half-speed gesture rate for a coherent pace.
        return true, math.min(resolved.duration / 0.5, 8), playback
    end,
    stop = function(actor, resolved)
        if not IsValid(actor) or not istable(resolved) then return end
        local layer = resolved.layer_id
        if isnumber(layer) and layer >= 0 then
            local readOK, activeSequence = pcall(actor.GetLayerSequence, actor, layer)
            if readOK and activeSequence == resolved.sequence_id then pcall(actor.RemoveLayer, actor, layer) end
        end
    end,
    is_active = function(actor, resolved)
        if not IsValid(actor) or not istable(resolved) or not isnumber(resolved.layer_id) then return false end
        local ok, sequenceID = pcall(actor.GetLayerSequence, actor, resolved.layer_id)
        local cycleOK, cycle = pcall(actor.GetLayerCycle, actor, resolved.layer_id)
        return ok and sequenceID == resolved.sequence_id and cycleOK and isnumber(cycle) and cycle < 1
    end
})

local function resolveCue(actor, cue)
    local packs = {}
    for _, pack in pairs(PACKS) do packs[#packs + 1] = pack end
    table.sort(packs, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.id < b.id
    end)

    for _, pack in ipairs(packs) do
        for _, candidate in ipairs(pack.definitions[cue] or {}) do
            if not candidate.model or candidate.model == string.lower(actor:GetModel()) then
                local backend = BACKENDS[candidate.backend]
                if backend then
                    local ok, resolved = pcall(backend.resolve, actor, candidate)
                    if ok and istable(resolved) and isnumber(resolved.duration)
                        and resolved.duration > 0 and resolved.duration <= 8 then
                        return {
                            cue = cue,
                            sequence = candidate.sequence,
                            asset_id = candidate.asset_id,
                            duration = resolved.duration,
                            resolved = resolved,
                            pack = pack.id,
                            pack_version = pack.version,
                            backend = backend.id,
                            backend_version = backend.version
                        }
                    end
                end
            end
        end
    end
end

function Presentation.AvailableCues(actor)
    local result = {}
    if not isAgent(actor) then return result end

    for cue in pairs(CUE_IDS) do
        local resolved = resolveCue(actor, cue)
        if resolved then
            result[#result + 1] = {
                cue = resolved.cue,
                sequence = resolved.sequence,
                asset_id = resolved.asset_id,
                duration = resolved.duration,
                pack = resolved.pack,
                pack_version = resolved.pack_version,
                backend = resolved.backend,
                backend_version = resolved.backend_version
            }
        end
    end
    table.sort(result, function(a, b) return a.cue < b.cue end)
    return result
end

local function startsWithPhrase(message, phrase)
    if string.sub(message, 1, #phrase) ~= phrase then return false end
    local nextCharacter = string.sub(message, #phrase + 1, #phrase + 1)
    return nextCharacter == "" or not string.match(nextCharacter, "[%w_]")
end

local function classifyPlayerMessage(text)
    local message = string.lower(string.sub(tostring(text or ""), 1, 256))
    message = string.gsub(message, "[%c]+", " ")
    message = string.Trim(message)

    for _, phrase in ipairs({"hi", "hello", "hey", "greetings", "good morning",
        "good afternoon", "good evening", "goodbye", "bye", "see you"}) do
        if startsWithPhrase(message, phrase) then return "greet" end
    end

    for _, phrase in ipairs({"no", "nope", "nah", "not really", "i disagree",
        "i don't agree", "i don't think", "that's wrong", "that is wrong"}) do
        if startsWithPhrase(message, phrase) then return "disagree" end
    end

    for _, phrase in ipairs({"thanks", "thank you", "yes", "yeah", "yep", "sure",
        "okay", "ok", "great", "sounds good"}) do
        if startsWithPhrase(message, phrase) then return "acknowledge" end
    end

    local questionStarts = {"what", "why", "how", "where", "when", "who", "which",
        "can", "could", "would", "will", "do", "does", "did", "is", "are", "am",
        "have", "has"}
    for _, phrase in ipairs(questionStarts) do
        if startsWithPhrase(message, phrase) then return "explain" end
    end
    if string.find(message, "?", 1, true) then return "explain" end
    return "acknowledge"
end

local function classifyNpcVoiceCue(text)
    local cue = string.lower(tostring(text or ""))
    if string.find(cue, "question", 1, true) or string.find(cue, "asking", 1, true)
        or string.find(cue, "ask_", 1, true) then
        return "explain"
    end
    if string.find(cue, "greet", 1, true) or string.find(cue, "hello", 1, true)
        or string.match(cue, "[/_%-]hi[%d%.%-]") then
        return "greet"
    end
    if string.find(cue, "disagree", 1, true) or string.find(cue, "reject", 1, true)
        or string.match(cue, "[/_%-]no[%d%.%-]") then
        return "disagree"
    end
    if string.find(cue, "thank", 1, true) or string.find(cue, "agree", 1, true)
        or string.find(cue, "affirm", 1, true) or string.match(cue, "[/_%-]yes[%d%.%-]") then
        return "acknowledge"
    end
end

function Presentation.BuildFrame(actor, context)
    if not isAgent(actor) or not istable(context) then return nil end
    local cue
    if context.kind == "player_message" then
        cue = classifyPlayerMessage(context.text)
    elseif context.kind == "game_event" then
        if context.event == "command_spawn" then
            cue = "greet"
        elseif context.event == "player_interaction" then
            cue = "acknowledge"
        elseif context.event == "npc_audio_cue" then
            cue = classifyNpcVoiceCue(context.text)
        end
    end
    if not cue then return nil end

    return {
        schema_version = 1,
        agent_id = tostring(actor:EntIndex()),
        cue = cue,
        context = context.kind,
        channel = "gesture",
        priority = 20,
        expires_at = CurTime() + 2
    }
end

local function clearActiveCue(actor, reason)
    if not IsValid(actor) or not actor.ACNPresentationBackend then return false end

    local backend = BACKENDS[actor.ACNPresentationBackend]
    if backend and istable(actor.ACNPresentationResolved) then
        pcall(backend.stop, actor, actor.ACNPresentationResolved)
    end

    timer.Remove("AICitizenNPC.Presentation." .. actor:EntIndex())
    actor.ACNPresentationBusyUntil = CurTime()
    actor.ACNPresentationSequence = nil
    actor.ACNPresentationLastCue = nil
    actor.ACNPresentationPriority = nil
    actor.ACNPresentationFrame = nil
    actor.ACNPresentationBackend = nil
    actor.ACNPresentationResolved = nil
    actor.ACNPresentationInterruptReason = reason
    return true
end

function Presentation.Interrupt(actor, reason)
    if not isAgent(actor) then return false end
    return clearActiveCue(actor, isstring(reason) and string.sub(reason, 1, 32) or "interrupted")
end

function Presentation.Play(actor, cue, frame)
    if not isAgent(actor) then return false, "the active body is not the AI Citizen NPC" end
    if not isstring(cue) or #cue > 32 or not CUE_IDS[cue] then
        return false, "cue must be a supported semantic ID"
    end

    local available = resolveCue(actor, cue)
    if not available then return false, "the requested animation cue is unavailable on this model" end
    if IsValid(actor:GetEnemy()) then return false, "combat has priority over presentation cues" end

    local now = CurTime()
    local priority = istable(frame) and tonumber(frame.priority) or 60
    priority = math.Clamp(priority or 60, 0, 100)
    if (tonumber(actor.ACNPresentationBusyUntil) or 0) > now then
        local activePriority = tonumber(actor.ACNPresentationPriority) or 0
        if actor.ACNPresentationLastCue == cue and priority >= activePriority then
            return true, string.format("cue=%s pack=%s@%s backend=%s sequence=%s already_active=true",
                cue, available.pack, available.pack_version, available.backend,
                available.sequence or available.asset_id or "backend-managed")
        end
        if priority <= activePriority then return false, "another higher-priority presentation cue is active" end
        clearActiveCue(actor, "higher_priority")
    end

    local backend = BACKENDS[available.backend]
    if not backend then return false, "the selected animation backend is unavailable" end
    local ok, played, duration, resolved = pcall(backend.play, actor, available.resolved, cue, frame)
    if not ok or played ~= true or not isnumber(duration) or duration <= 0 or not istable(resolved) then
        return false, "the selected animation backend could not play the validated cue"
    end

    actor.ACNPresentationBusyUntil = now + math.min(duration, 8)
    actor.ACNPresentationSequence = available.sequence or available.asset_id or "backend-managed"
    actor.ACNPresentationLastCue = cue
    actor.ACNPresentationPriority = priority
    actor.ACNPresentationFrame = istable(frame) and frame or nil
    actor.ACNPresentationBackend = available.backend
    actor.ACNPresentationResolved = resolved

    local timerName = "AICitizenNPC.Presentation." .. actor:EntIndex()
    timer.Create(timerName, 0.1, 0, function()
        if not IsValid(actor) then timer.Remove(timerName) return end
        if (tonumber(actor.ACNPresentationBusyUntil) or 0) <= CurTime() then
            clearActiveCue(actor, "completed")
        elseif IsValid(actor:GetEnemy()) then
            clearActiveCue(actor, "combat")
        else
            local currentBackend = BACKENDS[actor.ACNPresentationBackend]
            local activeOK, active = false, false
            if currentBackend then
                activeOK, active = pcall(currentBackend.is_active, actor, actor.ACNPresentationResolved)
            end
            if not activeOK or not active then
                clearActiveCue(actor, "layer_ended")
            end
        end
    end)

    return true, string.format("cue=%s pack=%s@%s backend=%s sequence=%s duration=%.2f",
        cue, available.pack, available.pack_version, available.backend,
        available.sequence or available.asset_id or "backend-managed", duration)
end

local function playContextFrame(actor, frame)
    if not frame then return false, "no local presentation rule matched" end
    if IsValid(actor:GetEnemy()) then return false, "combat has priority over conversation presentation" end

    local now = CurTime()
    if actor.ACNPresentationContextCue == frame.cue
        and (tonumber(actor.ACNPresentationContextAt) or 0) + 5 > now then
        return false, "the same context cue was recently played"
    end

    local played, result = Presentation.Play(actor, frame.cue, frame)
    if played then
        actor.ACNPresentationContextCue = frame.cue
        actor.ACNPresentationContextAt = now
    end
    return played, result
end

function Presentation.OnPlayerMessage(actor, text)
    return playContextFrame(actor, Presentation.BuildFrame(actor, {kind = "player_message", text = text}))
end

function Presentation.OnGameEvent(actor, eventName, text)
    return playContextFrame(actor, Presentation.BuildFrame(actor, {
        kind = "game_event", event = eventName, text = text
    }))
end

function Presentation.IsCue(cue)
    return isstring(cue) and CUE_IDS[cue] == true
end

hook.Add("EntityTakeDamage", "AICitizenNPC.PresentationDamageInterrupt", function(target)
    if isAgent(target) then Presentation.Interrupt(target, "damage") end
end)

Presentation._test = {
    cues = CUE_IDS,
    packs = PACKS,
    backends = BACKENDS,
    isAgent = isAgent,
    resolveCue = resolveCue,
    classifyPlayerMessage = classifyPlayerMessage,
    classifyNpcVoiceCue = classifyNpcVoiceCue
}

concommand.Add("ai_citizen_npc_ai_animation_sources", function(ply)
    if IsValid(ply) and not ply:IsAdmin() then return end
    local sources = Presentation.DiscoverOptionalSources()
    for name, source in pairs(sources) do
        print(string.format("[AI Citizen NPC Animation] source=%s mounted=%s addon_ids=%s api_namespace=%s wos_adapter_registered=false",
            name, tostring(source.mounted), table.concat(source.addon_ids, ","),
            tostring(source.api_namespace)))
    end
end)

return Presentation
