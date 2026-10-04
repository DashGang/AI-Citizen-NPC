local P = {}
local function canSee(observer, target)
    if isfunction(observer.IsInViewCone) then
        local ok, inView = pcall(observer.IsInViewCone, observer, target)
        if ok and not inView then return false end
    end
    if isfunction(observer.Visible) then
        local ok, visible = pcall(observer.Visible, observer, target)
        if ok then return visible == true end
    end
    local tr = util.TraceLine({start = observer:EyePos(), endpos = target:WorldSpaceCenter(),
        filter = {observer, target}, mask = MASK_VISIBLE_AND_NPCS})
    return not tr.Hit
end

local function rangeBetween(observer, target)
    if isfunction(observer.GetRangeTo) then
        local ok, distance = pcall(observer.GetRangeTo, observer, target)
        if ok and isnumber(distance) then return distance end
    end
    return observer:GetPos():Distance(target:GetPos())
end

function P.Measure(bot, focusPlayer)
    local grounded
    if isfunction(bot.IsOnGround) then
        local ok, value = pcall(bot.IsOnGround, bot)
        if ok then grounded = value end
    end
    local out = {time = CurTime(), origin = bot:GetPos(), grounded = grounded,
        range = tonumber(AICitizenNPC.Config.sensorRange) or 640,
        player = nil, visiblePlayerSet = {}, props = {}, threat = nil}
    if isfunction(bot.GetEnemy) then
        local ok, enemy = pcall(bot.GetEnemy, bot)
        if ok and IsValid(enemy) then
            local distance = rangeBetween(bot, enemy)
            out.threat = {entity = enemy, index = enemy:EntIndex(), distance = distance,
                visible = canSee(bot, enemy), current = true}
        end
    end
    local activeEnemy = out.threat and out.threat.entity or nil
    local closest = math.huge
    for _, ent in ipairs(ents.FindInSphere(out.origin, AICitizenNPC.Config.sensorRange)) do
        if IsValid(ent) and ent ~= bot then
            if ent:IsPlayer() and ent:Alive() then
                local d = rangeBetween(bot, ent)
                local disposition = bot.Disposition and bot:Disposition(ent) or D_NU
                if d < closest or disposition == D_HT or ent == focusPlayer then
                    local visible
                    if ent == activeEnemy then
                        visible = out.threat.visible
                    else
                        visible = canSee(bot, ent)
                    end
                    if visible then
                        out.visiblePlayerSet[ent] = true
                        if d < closest then
                            closest, out.player = d, {entity = ent, distance = d}
                        end
                    end
                    if visible and disposition == D_HT
                        and (not out.threat or (not out.threat.current and d < out.threat.distance)) then
                        out.threat = {entity = ent, index = ent:EntIndex(), distance = d,
                            visible = true, current = false}
                    end
                end
            elseif ent:IsNPC() and ent:Health() > 0 then
                local disposition = ent.Disposition and ent:Disposition(bot) or D_NU
                if disposition == D_HT then
                    local d = rangeBetween(bot, ent)
                    local visible
                    if ent == activeEnemy then
                        visible = out.threat.visible
                    else
                        visible = canSee(bot, ent)
                    end
                    if visible
                        and (not out.threat or (not out.threat.current and d < out.threat.distance)) then
                        out.threat = {entity = ent, index = ent:EntIndex(), distance = d,
                            visible = true, current = false}
                    end
                end
            else
                local phys = ent:GetPhysicsObject()
                if IsValid(phys) and phys:IsMotionEnabled() and ent:GetModel() and ent:GetModel() ~= "" then
                    local d = rangeBetween(bot, ent)
                    if d <= AICitizenNPC.Config.propRange and canSee(bot, ent) then
                        local moving
                        local ok, velocity = pcall(phys.GetVelocity, phys)
                        if ok and isvector(velocity) then
                            moving = velocity:LengthSqr() > 256
                        end
                        out.props[#out.props + 1] = {entity = ent, index = ent:EntIndex(),
                            class = ent:GetClass(), model = ent:GetModel(), distance = d,
                            moving = moving}
                    end
                end
            end
        end
    end
    table.sort(out.props, function(a, b) return a.distance < b.distance end)
    while #out.props > 8 do table.remove(out.props) end
    return out
end
return P
