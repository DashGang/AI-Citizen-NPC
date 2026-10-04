--@name AI Citizen NPC Expression Component
--@author AI Citizen NPC
--@server
--@include behavior.lua

-- A separate, normally permissioned Starfall processor for an existing VJ NPC.
-- This program does not create, replace, or schedule the NPC.
local processor = chip()
local actor
local behavior = require("behavior.lua")
if type(behavior) ~= "table" then error("behavior.lua must return a table") end

wire.adjustInputs(
    {"Agent", "PlayerMessage", "GameEvent", "ModelReplyDelta", "ModelReply", "AgentExpression"},
    {"ENTITY", "STRING", "STRING", "STRING", "STRING", "STRING"}
)
wire.adjustOutputs(
    {"AgentBody", "LastPlayerMessage", "LastGameEvent", "LastModelReplyDelta", "LastModelReply", "LastAgentExpression"},
    {"ENTITY", "STRING", "STRING", "STRING", "STRING", "STRING"}
)

wire.triggerOutput(processor, "LastPlayerMessage", "")
wire.triggerOutput(processor, "LastGameEvent", "")
wire.triggerOutput(processor, "LastModelReplyDelta", "")
wire.triggerOutput(processor, "LastModelReply", "")
wire.triggerOutput(processor, "LastAgentExpression", "")

local function validAgent(value)
    return value and value:isValid() and value:getClass() == "npc_vj_ai_citizen_npc"
end

hook.add("input", "ai_citizen_npc_expression_bridge", function(name, value)
    if name == "Agent" then
        actor = validAgent(value) and value or nil
        if actor then wire.triggerOutput(processor, "AgentBody", actor) end
        return
    end
    if not validAgent(actor) then return end

    if name == "PlayerMessage" then
        local result = behavior.onPlayerMessage and behavior.onPlayerMessage(value, actor) or value
        if type(result) ~= "string" then result = value end
        wire.triggerOutput(processor, "LastPlayerMessage", result)
    elseif name == "GameEvent" then
        local result = behavior.onGameEvent and behavior.onGameEvent(value, actor) or value
        if type(result) ~= "string" then result = value end
        wire.triggerOutput(processor, "LastGameEvent", result)
    elseif name == "ModelReplyDelta" then
        local result = behavior.onModelReplyDelta and behavior.onModelReplyDelta(value, actor) or value
        if type(result) ~= "string" then result = value end
        wire.triggerOutput(processor, "LastModelReplyDelta", result)
    elseif name == "ModelReply" then
        local result = behavior.onModelReply and behavior.onModelReply(value, actor) or value
        if type(result) ~= "string" then result = value end
        wire.triggerOutput(processor, "LastModelReply", result)
    elseif name == "AgentExpression" then
        local result = behavior.onAgentExpression and behavior.onAgentExpression(value, actor) or "unsupported"
        if type(result) ~= "string" then result = "unsupported" end
        wire.triggerOutput(processor, "LastAgentExpression", string.sub(result, 1, 24))
    end
end)
