local Providers = {}

local DEFINITIONS = {
    openai = {
        id = "openai",
        label = "OpenAI",
        endpoint = "https://api.openai.com/v1/responses",
        modelsEndpoint = "https://api.openai.com/v1/models",
        keyPath = "ai_citizen_npc/openai_api_key.txt",
        modelCvar = "ai_citizen_npc_ai_openai_model",
        enabledCvar = "ai_citizen_npc_slot_openai_enabled",
        callNameCvar = "ai_citizen_npc_slot_openai_call_name",
        defaultModel = "gpt-5-mini",
        defaultCallName = "openai",
        protocol = "responses",
        websocket = true,
        requiresKey = true
    },
    openrouter = {
        id = "openrouter",
        label = "OpenRouter",
        endpoint = "https://openrouter.ai/api/v1/chat/completions",
        modelsEndpoint = "https://openrouter.ai/api/v1/models",
        keyPath = "ai_citizen_npc/openrouter_api_key.txt",
        modelCvar = "ai_citizen_npc_ai_openrouter_model",
        enabledCvar = "ai_citizen_npc_slot_openrouter_enabled",
        callNameCvar = "ai_citizen_npc_slot_openrouter_call_name",
        defaultModel = "openrouter/free",
        defaultCallName = "router",
        protocol = "chat_completions",
        websocket = false,
        requiresKey = true
    },
    ["local"] = {
        id = "local",
        label = "Local (OpenAI-compatible)",
        keyPath = "ai_citizen_npc/local_api_key.txt",
        endpointCvar = "ai_citizen_npc_local_base_url",
        modelCvar = "ai_citizen_npc_ai_local_model",
        enabledCvar = "ai_citizen_npc_slot_local_enabled",
        callNameCvar = "ai_citizen_npc_slot_local_call_name",
        defaultModel = "local-model",
        defaultCallName = "local",
        defaultBaseURL = "http://127.0.0.1:1234/v1",
        protocol = "chat_completions",
        websocket = false,
        requiresKey = false
    }
}

local VALIDATED = {}
local MODEL_CATALOGS = {}
local SESSION_KEYS = {}

local function invalidateCatalog(provider)
    VALIDATED[provider] = false
    MODEL_CATALOGS[provider] = nil
end

local function trim(value)
    return string.Trim(tostring(value or ""))
end

local function validModelID(value)
    return isstring(value) and #value > 0 and #value <= 128
        and not string.find(value, "[%c%s]")
end

local function validBaseURL(value)
    value = trim(value)
    if #value < 8 or #value > 240 or string.find(value, "[%c%s?#@]") then return false end
    local host, suffix = string.match(value, "^https?://([%w%.%-]+)(.*)$")
    if not host then return false end
    if suffix == "" then return true end
    if string.match(suffix, "^:%d+/$") or string.match(suffix, "^:%d+$") then return true end
    if string.match(suffix, "^:%d+/[%w%._%-%/]+$") then return true end
    if string.match(suffix, "^/[%w%._%-%/]*$") then return true end
    return false
end

function Providers.Definitions()
    return DEFINITIONS
end

function Providers.Selected()
    local cv = GetConVar("ai_citizen_npc_ai_provider")
    local id = cv and string.lower(trim(cv:GetString())) or "openai"
    return DEFINITIONS[id] and id or "openai"
end

function Providers.Definition(provider)
    return DEFINITIONS[provider or Providers.Selected()] or DEFINITIONS.openai
end

function Providers.Model(provider)
    local definition = Providers.Definition(provider)
    local cv = GetConVar(definition.modelCvar)
    local model = cv and trim(cv:GetString()) or definition.defaultModel
    if not validModelID(model) then return definition.defaultModel end
    return model
end

function Providers.SetModel(provider, model)
    local definition = DEFINITIONS[provider]
    model = trim(model)
    if not definition or not validModelID(model) then return false, "invalid model ID" end
    if Providers.IsValidated(provider) and not (provider == "openrouter" and model == "openrouter/free") then
        local listed = false
        for _, available in ipairs(Providers.ModelCatalog(provider)) do
            if available == model then listed = true break end
        end
        if not listed then return false, "choose a model from the validated provider catalog" end
    end
    local cv = GetConVar(definition.modelCvar)
    if not cv then return false, "provider model setting is unavailable" end
    cv:SetString(model)
    return true
end

function Providers.SlotReady(provider)
    return Providers.IsEnabled(provider) and Providers.ConnectionReady(provider)
end

function Providers.ConnectionReady(provider)
    if not Providers.IsValidated(provider) or not Providers.ConnectionConfigured(provider) then return false end
    local selectedModel = Providers.Model(provider)
    if provider == "openrouter" and selectedModel == "openrouter/free" then return true end
    for _, model in ipairs(Providers.ModelCatalog(provider)) do
        if model == selectedModel then return true end
    end
    return false
end

function Providers.BaseURL(provider)
    local definition = Providers.Definition(provider)
    if provider ~= "local" then return nil end
    local cv = GetConVar(definition.endpointCvar)
    local value = trim(cv and cv:GetString() or definition.defaultBaseURL):gsub("/+$", "")
    if not validBaseURL(value) then return nil end
    return value
end

function Providers.SetBaseURL(value)
    value = trim(value):gsub("/+$", "")
    if not validBaseURL(value) then return false, "use an HTTP(S) host URL without credentials, query, or fragment" end
    local cv = GetConVar(DEFINITIONS["local"].endpointCvar)
    if not cv then return false, "local endpoint setting is unavailable" end
    cv:SetString(value)
    VALIDATED["local"] = false
    MODEL_CATALOGS["local"] = nil
    return true
end

function Providers.Endpoint(provider)
    local definition = Providers.Definition(provider)
    if provider == "local" then
        local base = Providers.BaseURL(provider)
        return base and (base .. "/chat/completions") or nil
    end
    return definition.endpoint
end

function Providers.ModelsEndpoint(provider)
    local definition = Providers.Definition(provider)
    if provider == "local" then
        local base = Providers.BaseURL(provider)
        return base and (base .. "/models") or nil
    end
    return definition.modelsEndpoint
end

function Providers.ReadKey(provider)
    local definition = Providers.Definition(provider)
    local sessionKey = SESSION_KEYS[provider]
    if isstring(sessionKey) and sessionKey ~= "" then return sessionKey end
    return trim(file.Read(definition.keyPath, "DATA"))
end

function Providers.KeyConfigured(provider)
    local definition = Providers.Definition(provider)
    return (isstring(SESSION_KEYS[provider]) and SESSION_KEYS[provider] ~= "")
        or (file.Exists(definition.keyPath, "DATA") and trim(file.Read(definition.keyPath, "DATA")) ~= "")
end

function Providers.KeySaved(provider)
    local definition = DEFINITIONS[provider]
    return definition ~= nil and file.Exists(definition.keyPath, "DATA")
        and trim(file.Read(definition.keyPath, "DATA")) ~= ""
end

function Providers.SessionKeyConfigured(provider)
    return isstring(SESSION_KEYS[provider]) and SESSION_KEYS[provider] ~= ""
end

function Providers.SetSessionKey(provider, value)
    local definition = DEFINITIONS[provider]
    if not definition then return false, "unsupported provider slot" end
    value = trim(value)
    if value == "" then
        if SESSION_KEYS[provider] ~= nil then
            SESSION_KEYS[provider] = nil
            invalidateCatalog(provider)
        end
        return true
    end
    local minimum = provider == "local" and 1 or 20
    if #value < minimum or #value > 512 or string.find(value, "%s") or string.find(value, "[%c]") then
        return false, "key length is invalid or contains whitespace"
    end
    if SESSION_KEYS[provider] ~= value then
        SESSION_KEYS[provider] = value
        invalidateCatalog(provider)
    end
    return true
end

function Providers.ClearKey(provider)
    local definition = DEFINITIONS[provider]
    if not definition then return false, "unsupported provider slot" end
    SESSION_KEYS[provider] = nil
    file.Delete(definition.keyPath)
    invalidateCatalog(provider)
    if Providers.IsEnabled(provider) then Providers.SetEnabled(provider, false) end
    return true
end

function Providers.ConnectionConfigured(provider)
    local definition = DEFINITIONS[provider]
    if not definition then return false end
    if definition.requiresKey and not Providers.KeyConfigured(provider) then return false end
    if provider == "local" and not Providers.BaseURL(provider) then return false end
    return true
end

function Providers.StoreKey(provider, value)
    local definition = DEFINITIONS[provider]
    if not definition then return false, "unsupported provider slot" end
    value = trim(value)
    if provider == "local" and value == "" then
        return false, "enter a key to save, or use Remove key to clear credentials"
    end
    local minimum = provider == "local" and 1 or 20
    if #value < minimum or #value > 512 or string.find(value, "%s") or string.find(value, "[%c]") then
        return false, "key length is invalid or contains whitespace"
    end
    file.CreateDir("ai_citizen_npc")
    file.Write(definition.keyPath, value)
    if trim(file.Read(definition.keyPath, "DATA")) ~= value then
        return false, "server could not verify the stored key"
    end
    if SESSION_KEYS[provider] ~= value then
        SESSION_KEYS[provider] = value
        invalidateCatalog(provider)
    end
    return true
end

function Providers.CallName(provider)
    local definition = Providers.Definition(provider)
    local cv = GetConVar(definition.callNameCvar)
    local name = string.lower(trim(cv and cv:GetString() or definition.defaultCallName))
    if not string.match(name, "^[a-z][a-z0-9_]*$") or #name > 16 then
        return definition.defaultCallName
    end
    return name
end

function Providers.SetCallName(provider, value)
    local definition = DEFINITIONS[provider]
    value = string.lower(trim(value))
    if not definition or #value < 2 or #value > 16
        or not string.match(value, "^[a-z][a-z0-9_]*$") or value == "agent" then
        return false, "use a unique lowercase name with 2-16 letters, numbers, or underscores"
    end
    if not Providers.IsValidated(provider) then return false, "validate the provider connection before setting its call name" end
    for other in pairs(DEFINITIONS) do
        if other ~= provider and Providers.CallName(other) == value then
            return false, "that call name is already assigned to another provider slot"
        end
    end
    local cv = GetConVar(definition.callNameCvar)
    if not cv then return false, "call-name setting is unavailable" end
    cv:SetString(value)
    return true
end

function Providers.IsValidated(provider)
    return VALIDATED[provider] == true
end

function Providers.IsEnabled(provider)
    local definition = Providers.Definition(provider)
    local cv = GetConVar(definition.enabledCvar)
    return cv and cv:GetBool() or false
end

function Providers.SetEnabled(provider, enabled)
    local definition = DEFINITIONS[provider]
    if not definition then return false, "unsupported provider slot" end
    local cv = GetConVar(definition.enabledCvar)
    if not cv then return false, "provider slot setting is unavailable" end
    if enabled and not Providers.ConnectionReady(provider) then
        return false, "validate the connection and choose a listed model before enabling this NPC slot"
    end
    if enabled then
        local name = Providers.CallName(provider)
        for other in pairs(DEFINITIONS) do
            if other ~= provider and Providers.IsEnabled(other) and Providers.CallName(other) == name then
                return false, "another enabled slot already uses this call name"
            end
        end
    end
    cv:SetBool(enabled == true)
    return true
end

function Providers.ModelCatalog(provider)
    return MODEL_CATALOGS[provider] or {}
end

function Providers.TimeoutSeconds()
    local cv = GetConVar("ai_citizen_npc_ai_request_timeout")
    return math.Clamp(cv and cv:GetInt() or 35, 5, 120)
end

function Providers.OpenRouterPolicy()
    local sort = string.lower(trim(GetConVar("ai_citizen_npc_ai_openrouter_sort"):GetString()))
    if sort ~= "price" and sort ~= "throughput" and sort ~= "latency" then sort = "latency" end
    local policy = {
        sort = sort,
        allow_fallbacks = GetConVar("ai_citizen_npc_ai_openrouter_fallbacks"):GetBool()
    }
    local collection = string.lower(trim(GetConVar("ai_citizen_npc_ai_openrouter_data_collection"):GetString()))
    if collection == "allow" or collection == "deny" then policy.data_collection = collection end
    return policy
end

function Providers.Request(provider, options)
    options = istable(options) and options or {}
    if provider == "local" then
        local bridge = AICitizenNPC and AICitizenNPC.MCP
        if not bridge or not isfunction(bridge.RequestLocalProvider) then
            if isfunction(options.failed) then options.failed("Local provider relay is unavailable; load the AI Citizen NPC MCP bridge") end
            return false
        end
        return bridge.RequestLocalProvider({
            url = options.url,
            method = options.method,
            headers = options.headers,
            body = options.body or "",
            timeout = options.timeout or Providers.TimeoutSeconds()
        }, options)
    end
    return HTTP(options)
end

function Providers.Validate(provider, callback)
    local definition = DEFINITIONS[provider]
    if not definition or not Providers.ConnectionConfigured(provider) then
        if definition then invalidateCatalog(provider) end
        local reason = "configure the provider connection first"
        if definition and definition.requiresKey and not Providers.KeyConfigured(provider) then
            reason = "enter or save an API key for the " .. definition.label .. " slot first"
        elseif provider == "local" and not Providers.BaseURL(provider) then
            reason = "save a valid Local provider URL first"
        end
        if isfunction(callback) then callback(false, reason, {}) end
        return false
    end
    local url = Providers.ModelsEndpoint(provider)
    if not url then
        invalidateCatalog(provider)
        if isfunction(callback) then callback(false, "local endpoint URL is invalid", {}) end
        return false
    end
    local headers = {}
    local key = Providers.ReadKey(provider)
    if key ~= "" then headers.Authorization = "Bearer " .. key end
    if provider == "openrouter" then
        headers["HTTP-Referer"] = "https://github.com/citizen-agent-lab"
        headers["X-Title"] = "AI Citizen NPC"
    end
    Providers.Request(provider, {
        url = url,
        method = "GET",
        headers = headers,
        timeout = Providers.TimeoutSeconds(),
        success = function(code, body)
            if code < 200 or code >= 300 then
                invalidateCatalog(provider)
                if isfunction(callback) then callback(false, "provider returned HTTP " .. tostring(code), {}) end
                return
            end
            if not isstring(body) or #body > 1048576 then
                invalidateCatalog(provider)
                if isfunction(callback) then callback(false, "model catalog response was missing or too large", {}) end
                return
            end
            local payload = util.JSONToTable(body)
            if not istable(payload) or not istable(payload.data) then
                invalidateCatalog(provider)
                if isfunction(callback) then callback(false, "endpoint did not return an OpenAI-compatible model catalog", {}) end
                return
            end
            local models, seen = {}, {}
            for _, entry in ipairs(payload.data) do
                local id = istable(entry) and entry.id or nil
                if validModelID(id) and not seen[id] and #models < 100 then
                    seen[id] = true
                    models[#models + 1] = id
                end
            end
            if #models == 0 then
                invalidateCatalog(provider)
                if isfunction(callback) then callback(false, "endpoint returned no usable model IDs", {}) end
                return
            end
            table.sort(models)
            MODEL_CATALOGS[provider] = models
            VALIDATED[provider] = true
            if isfunction(callback) then callback(true, "connection validated", models) end
        end,
        failed = function(reason)
            invalidateCatalog(provider)
            local detail = string.gsub(tostring(reason or "unknown"), "[%c]", " ")
            if provider == "local" and string.find(string.lower(detail), "local resources are not allowed", 1, true) then
                detail = "GMod blocked HTTP to this private address. The -allowlocalhttp option is dedicated-server-only; this single-player session needs the Local WebSocket relay."
            else
                detail = "connection failed: " .. detail
            end
            if isfunction(callback) then callback(false, detail, {}) end
        end
    })
    return true
end

function Providers.Install()
    CreateConVar("ai_citizen_npc_ai_provider", "openai", FCVAR_ARCHIVE,
        "Default API provider slot: openai, openrouter, or local")
    for provider, definition in pairs(DEFINITIONS) do
        CreateConVar(definition.modelCvar, definition.defaultModel, FCVAR_ARCHIVE,
            "Model ID used by the " .. definition.label .. " provider slot")
        CreateConVar(definition.enabledCvar, "0", FCVAR_ARCHIVE,
            "Enable the " .. definition.label .. " NPC slot after connection validation")
        CreateConVar(definition.callNameCvar, definition.defaultCallName, FCVAR_ARCHIVE,
            "In-game chat call name for the " .. definition.label .. " NPC slot")
    end
    CreateConVar(DEFINITIONS["local"].endpointCvar, DEFINITIONS["local"].defaultBaseURL, FCVAR_ARCHIVE,
        "OpenAI-compatible Local provider base URL")
    CreateConVar("ai_citizen_npc_ai_request_timeout", "35", FCVAR_ARCHIVE,
        "Provider request timeout in seconds (5-120)")
    CreateConVar("ai_citizen_npc_ai_openrouter_sort", "latency", FCVAR_ARCHIVE,
        "OpenRouter provider ordering: latency, throughput, or price")
    CreateConVar("ai_citizen_npc_ai_openrouter_fallbacks", "1", FCVAR_ARCHIVE,
        "Allow OpenRouter to try another compatible provider endpoint")
    CreateConVar("ai_citizen_npc_ai_openrouter_data_collection", "default", FCVAR_ARCHIVE,
        "OpenRouter data policy: default, allow, or deny")

end

return Providers
