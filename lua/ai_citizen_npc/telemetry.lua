local T = {}
function T.Dump(bot)
    if not IsValid(bot) then print("[AI Citizen NPC] no valid agent") return end
    local f, o, p = bot.ACNLastFrame, bot.ACNLastOutcome or {}, bot.ACNPathDebug
    local target = f and IsValid(f.target) and f.target:EntIndex() or -1
    local targetClass = f and IsValid(f.target) and f.target:GetClass() or "none"
    local retryIn, failedApproaches
    retryIn, failedApproaches = nil, 0
    if bot.ACNMemory and bot.ACNMemory.props then
        for _, entry in pairs(bot.ACNMemory.props) do
            if entry.failedApproaches then failedApproaches = failedApproaches + 1 end
            if entry.retryAfter then
                local candidate = math.max(0, entry.retryAfter - CurTime())
                if retryIn == nil or candidate < retryIn then retryIn = candidate end
            end
        end
    end
    if retryIn == nil and o.retryAfter then retryIn = math.max(0, o.retryAfter - CurTime()) end
    print(string.format("[AI Citizen NPC] ent=%d pos=%s vel=%s action=%s kind=%s target=%d/%s score=%.3f result=%s moved=%.1f remaining=%.1f retry_in=%.1f failed_approaches=%d memory=%d",
        bot:EntIndex(), tostring(bot:GetPos()), tostring(bot.loco:GetVelocity()),
        f and f.action or "none", f and f.targetKind or "none", target, targetClass,
        f and f.score or 0, o.result or "pending", o.moved or 0, o.remaining or 0, retryIn or 0, failedApproaches,
        bot.ACNMemory and table.Count(bot.ACNMemory.props) or 0))
    if p then
        print(string.format("  path_goal=%s length=%.1f age=%.2f updates=%d",
            tostring(p.goal), p.length or 0, p.age or 0, p.updates or 0))
    end
    if f and f.candidates then
        for _, c in ipairs(f.candidates) do
            print(string.format("  candidate=%s score=%.3f", c.action, c.score))
        end
    end
end
return T
