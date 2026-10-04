-- Default expressive module for the Starfall body.
-- AI-authored replacements must return this module contract.
local function setFaceFlex(actor, name, weight)
    if not actor then return false end
    local id = actor:getFlexByName(name)
    if type(id) ~= "number" or id < 0 then return false end
    local minimum, maximum = actor:getFlexBounds(id)
    if type(minimum) ~= "number" or type(maximum) ~= "number" then return false end
    actor:setFlexWeight(id, math.max(minimum, math.min(maximum, weight)))
    return true
end

local function soundsPositive(reply)
    local text = string.lower(reply or "")
    for _, cue in ipairs({"glad", "happy", "great", "thanks", "wonderful", "good to hear"}) do
        if string.find(text, cue, 1, true) then return true end
    end
    return false
end

return {
    onGameEvent = function(event, actor)
        if string.find(event or "", "damage", 1, true) then
            setFaceFlex(actor, "jaw_drop", 0.02)
            setFaceFlex(actor, "smile", 0)
        elseif string.find(event or "", "command_spawn", 1, true) then
            setFaceFlex(actor, "jaw_drop", 0)
            setFaceFlex(actor, "smile", 0.22)
        end
        return event
    end,
    onAgentExpression = function(expression, actor)
        local presets = {
            neutral = {jaw = 0, smile = 0.08},
            speaking = {jaw = 0.08, smile = 0.06},
            curious = {jaw = 0.02, smile = 0.22},
            positive = {jaw = 0, smile = 0.32},
            concerned = {jaw = 0.03, smile = 0}
        }
        local preset = presets[expression]
        if not preset then return "unsupported" end
        local jaw = setFaceFlex(actor, "jaw_drop", preset.jaw)
        local smile = setFaceFlex(actor, "smile", preset.smile)
        if not jaw or not smile then return "flex_unavailable" end
        return expression
    end,
    onPlayerMessage = function(message, actor)
        setFaceFlex(actor, "jaw_drop", 0)
        return message
    end,
    onModelReplyDelta = function(chunk, actor)
        setFaceFlex(actor, "jaw_drop", 0.08)
        return chunk
    end,
    onModelReply = function(reply, actor)
        setFaceFlex(actor, "jaw_drop", 0)
        setFaceFlex(actor, "smile", soundsPositive(reply) and 0.32 or 0.08)
        return reply
    end
}
