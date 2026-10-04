local Realtime = {}

local URL = "wss://api.openai.com/v1/responses"
local STREAM_ID = "ai_citizen_npc"
local MAX_EVENT_BYTES = 512 * 1024
local MAX_OUTSTANDING = 16
local TIMEOUT_NAME = "AICitizenNPC.ResponsesWebSocket.Timeout"

local function requestTimeout()
    local cv = GetConVar("ai_citizen_npc_ai_request_timeout")
    return math.Clamp(cv and cv:GetInt() or 35, 5, 120)
end
local socket
local socketState = "closed"
local pending
local queue = {}
local generation = 0

local function safeJson(value)
    return util.TableToJSON(value, false)
end

local function safeCall(callback, ...)
    if not isfunction(callback) then return end
    local ok, err = pcall(callback, ...)
    if not ok then print("[AI Citizen NPC WebSocket] callback failed: " .. tostring(err)) end
end

local function failPending(reason)
    local item = pending
    pending = nil
    timer.Remove(TIMEOUT_NAME)
    if item then safeCall(item.failed, reason) end
end

local function failAll(reason)
    failPending(reason)
    local waiting = queue
    queue = {}
    for _, item in ipairs(waiting) do safeCall(item.failed, reason) end
end

local function sendNext()
    if socketState ~= "connected" or pending or #queue == 0 then return end
    pending = table.remove(queue, 1)
    local event = table.Copy(pending.request)
    event.type = "response.create"
    event.stream_id = STREAM_ID
    local body = safeJson(event)
    if not body or #body > MAX_EVENT_BYTES then
        failPending("request serialization failed or exceeded the event limit")
        sendNext()
        return
    end
    local ok, err = pcall(socket.write, socket, body)
    if not ok then
        failPending("socket write failed: " .. tostring(err))
        if socket then pcall(socket.closeNow, socket) end
        sendNext()
        return
    end
    local thisGeneration = generation
    timer.Create(TIMEOUT_NAME, requestTimeout(), 1, function()
        if thisGeneration ~= generation or not pending then return end
        local oldSocket = socket
        generation = generation + 1
        socket, socketState = nil, "closed"
        failAll("WebSocket request timed out")
        if oldSocket then pcall(oldSocket.closeNow, oldSocket) end
    end)
end

local function connect()
    if socketState == "connecting" or socketState == "connected" then return true end
    if socketState == "closing" then return false end
    if not GWSockets or not isfunction(GWSockets.createWebSocket) then return false end

    generation = generation + 1
    local thisGeneration = generation
    local ok, result = pcall(GWSockets.createWebSocket, URL, true)
    if not ok or not result then
        socketState = "closed"
        return false
    end
    socket = result
    socketState = "connecting"
    socket:setHeader("Authorization", "Bearer " .. Realtime.apiKey)

    function socket:onConnected()
        if thisGeneration ~= generation then return end
        socketState = "connected"
        print("[AI Citizen NPC WebSocket] connected to OpenAI Responses")
        sendNext()
    end

    function socket:onMessage(raw)
        if thisGeneration ~= generation then return end
        raw = tostring(raw or "")
        if #raw > MAX_EVENT_BYTES then
            failAll("provider event exceeded the event limit")
            return
        end
        local event = util.JSONToTable(raw)
        if not istable(event) then
            failAll("provider sent invalid JSON")
            return
        end
        if event.type == "response.completed" then
            timer.Remove(TIMEOUT_NAME)
            local item = pending
            pending = nil
            if item then
                local response = event.response or {}
                safeCall(item.success, 200, safeJson(response) or "{}")
            end
            sendNext()
        elseif event.type == "response.output_text.delta" then
            if pending then safeCall(pending.delta, tostring(event.delta or "")) end
        elseif event.type == "response.failed" or event.type == "response.incomplete" or event.type == "error" then
            local message = event.error and (event.error.message or event.error.code) or event.type
            failPending("provider event " .. tostring(message or "failed"))
            sendNext()
        end
    end

    function socket:onError(reason)
        if thisGeneration ~= generation then return end
        socketState = "closing"
        print("[AI Citizen NPC WebSocket] transport error: " .. string.gsub(tostring(reason or "unknown"), "[%c]", " "))
        failAll("WebSocket transport failed")
    end

    function socket:onDisconnected()
        if thisGeneration ~= generation then return end
        generation = generation + 1
        socket, socketState = nil, "closed"
        failAll("WebSocket disconnected")
    end

    local opened, openError = pcall(socket.open, socket, true)
    if not opened then
        socketState = "closed"
        socket = nil
        failAll("WebSocket open failed: " .. tostring(openError))
        return false
    end
    return true
end

function Realtime.Initialize(apiKey)
    Realtime.apiKey = apiKey
    if not GWSockets then
        local ok, result = pcall(require, "gwsockets")
        if not ok then
            print("[AI Citizen NPC WebSocket] gwsockets module unavailable; HTTPS transport remains available")
            return false, "module unavailable"
        end
        GWSockets = result or GWSockets
    end
    if not GWSockets or not isfunction(GWSockets.createWebSocket) then
        return false, "module did not expose GWSockets.createWebSocket"
    end
    return connect()
end

function Realtime.Request(request, success, failed, delta)
    if not Realtime.apiKey then return false, "API key not initialized" end
    local outstanding = #queue + (pending and 1 or 0)
    if outstanding >= MAX_OUTSTANDING then
        safeCall(failed, "WebSocket request queue is full")
        return true
    end
    queue[#queue + 1] = {request = table.Copy(request), success = success, failed = failed, delta = delta}
    if not connect() then
        table.remove(queue)
        return false, "WebSocket module unavailable"
    end
    sendNext()
    return true
end

function Realtime.Close()
    generation = generation + 1
    local oldSocket = socket
    socket, socketState = nil, "closed"
    failAll("WebSocket transport closed")
    if oldSocket then pcall(oldSocket.closeNow, oldSocket) end
end

function Realtime.State()
    return socketState
end

return Realtime
