local Integration = {}

local TOOLGUN_CLASS = "gmod_tool"
local PICKUP_TIMER = "AICitizenNPC.ToolgunPickup"
local PICKUP_CVAR = "ai_citizen_npc_ai_toolgun_pickup"
local PRIMARY_ACTION_HOOK = "UniversalToolgunNPCPrimaryAction"
local PRIMARY_ACTION_HOOK_ID = "AICitizenNPC.UniversalToolgunPrimaryAction"

local function toolgunAddonAvailable()
    local definition = weapons.GetStored(TOOLGUN_CLASS)
    return istable(definition) and definition.CALUniversalToolgun == true
end

function Integration.Install(agentClass)
    if not GetConVar(PICKUP_CVAR) then
        CreateConVar(PICKUP_CVAR, "1", FCVAR_ARCHIVE,
            "Allow AI Citizens to pick up dropped Universal Toolguns")
    end
    timer.Remove(PICKUP_TIMER)
    agentClass = isstring(agentClass) and agentClass or "npc_vj_ai_citizen_npc"

    hook.Add(PRIMARY_ACTION_HOOK, PRIMARY_ACTION_HOOK_ID, function(actor, weapon)
        if not IsValid(actor) or actor:GetClass() ~= agentClass
            or actor.ACNAgentVJ ~= true or not IsValid(weapon)
            or not istable(actor.ACNPendingToolgunAction) then
            return
        end

        local mcp = AICitizenNPC and AICitizenNPC.MCP
        if not mcp or not isfunction(mcp.HandleAgentToolgunAttack) then
            return true, false, "AI Citizen NPC Toolgun handler is unavailable"
        end

        local accepted, result = mcp.HandleAgentToolgunAttack(weapon)
        return true, accepted, result
    end)

    timer.Create(PICKUP_TIMER, 0.25, 0, function()
        local lab = AICitizenNPC
        local mcp = lab and lab.MCP
        local pickupSetting = GetConVar(PICKUP_CVAR)
        if not pickupSetting or not pickupSetting:GetBool() then return end
        if not mcp or not isfunction(mcp.AgentHasToolgun) or not toolgunAddonAvailable() then return end

        for _, agent in ipairs(ents.FindByClass(agentClass)) do
            if IsValid(agent) and agent.ACNAgentVJ == true
                and IsValid(agent.ACNOwner) and agent.ACNOwner:IsAdmin()
                and not mcp.AgentHasToolgun(agent) then
                for _, dropped in ipairs(ents.FindByClass(TOOLGUN_CLASS)) do
                    -- A weapon entity can be returned while held by a player
                    -- or another NPC. Only an unowned world prop is eligible.
                    if IsValid(dropped) and not IsValid(dropped:GetOwner())
                        and dropped ~= agent and not dropped.ACNPickupInProgress
                        and agent:GetPos():DistToSqr(dropped:WorldSpaceCenter()) <= 96 * 96 then
                        local trace = util.TraceLine({
                            start = agent:EyePos(),
                            endpos = dropped:WorldSpaceCenter(),
                            filter = {agent, dropped},
                            mask = MASK_VISIBLE_AND_NPCS
                        })
                        if not trace.Hit and isfunction(dropped.CanBePickedUpByNPCs)
                            and dropped:CanBePickedUpByNPCs(agent)
                            and IsValid(dropped) and not IsValid(dropped:GetOwner()) then
                            -- Recheck ownership immediately before transfer so
                            -- a player cannot lose a weapon during a pickup race.
                            local class = dropped:GetClass()
                            dropped.ACNPickupInProgress = true
                            local given, weapon = pcall(agent.Give, agent, class)
                            if given and IsValid(weapon) and weapon:GetOwner() == agent then
                                agent:SelectWeapon(class)
                            end

                            if mcp.AgentHasToolgun(agent) then
                                dropped:Remove()
                                print("[AI Citizen NPC Toolgun] agent=" .. agent:EntIndex() .. " picked up " .. class)
                                if mcp.PublishState then mcp.PublishState() end
                                break
                            elseif IsValid(weapon) then
                                weapon:Remove()
                                dropped.ACNPickupInProgress = nil
                            else
                                dropped.ACNPickupInProgress = nil
                            end
                        end
                    end
                end
            end
        end
    end)

    return true
end

return Integration
