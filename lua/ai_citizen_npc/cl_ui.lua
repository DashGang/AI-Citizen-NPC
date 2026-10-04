if not CLIENT then return end

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
local SLOT_IDS = {openai = 1, openrouter = 2, ["local"] = 3}
local SLOT_LABELS = {openai = "OpenAI", openrouter = "OpenRouter", ["local"] = "Local"}
local OPTION_IDS = {
    ai_citizen_npc_ai_enabled = 1,
    ai_citizen_npc_ai_animation_enabled = 2,
    ai_citizen_npc_ai_mcp_enabled = 3,
    ai_citizen_npc_ai_starfall_enabled = 4,
    ai_citizen_npc_ai_vj_actions_enabled = 5,
    ai_citizen_npc_ai_mcp_vj_actions_enabled = 6,
    ai_citizen_npc_ai_starfall_code_enabled = 7,
    ai_citizen_npc_ai_npc_audio_events = 8,
    ai_citizen_npc_ai_chat_context = 9,
    ai_citizen_npc_ai_mcp_native_enabled = 10,
    ai_citizen_npc_ai_toolgun_pickup = 11,
    ai_citizen_npc_ai_vj_follow_player = 12,
    ai_citizen_npc_ai_vj_use_spawnmenu_weapons = 13
}

local activeControls = {}
local keyDrafts = {}
local mountedNPCModels = {}
local mountedNPCModelSet = {}
local mountedNPCModelScanStarted = false
local mountedNPCModelScanFinished = false

local function addMountedNPCModel(path)
    if not isstring(path) or #path > 240 or not string.match(string.lower(path), "^models/.+%.mdl$") then return end
    local key = string.lower(path)
    if mountedNPCModelSet[key] then return end
    mountedNPCModelSet[key] = true
    mountedNPCModels[#mountedNPCModels + 1] = path
end

for _, gender in ipairs({"Female", "Male"}) do
    for index = 1, 9 do
        local path = string.format("models/Humans/Group03/%s_%02d.mdl", gender, index)
        if file.Exists(path, "GAME") then addMountedNPCModel(path) end
    end
end

local function refreshNPCModelChoices(controls)
    if not controls or not IsValid(controls.npcModelCombo) then return end
    local query = IsValid(controls.npcModelSearch)
        and string.lower(string.Trim(controls.npcModelSearch:GetValue() or "")) or ""
    local combo = controls.npcModelCombo
    combo:Clear()

    local shown, found = 0, 0
    for _, path in ipairs(mountedNPCModels) do
        local lowerPath = string.lower(path)
        local isCommonNPCModel = false
        if query == "" then
            for _, term in ipairs({"citizen", "human", "female", "male", "player", "character", "mara"}) do
                if string.find(lowerPath, term, 1, true) then isCommonNPCModel = true break end
            end
        end
        if (query == "" and isCommonNPCModel) or (query ~= "" and string.find(lowerPath, query, 1, true)) then
            found = found + 1
            if shown < 100 then
                combo:AddChoice(path, path)
                shown = shown + 1
            end
        end
    end

    if query == "" then
        combo:SetValue("Choose a stock Citizen or search mounted models")
        controls.npcModelSearchHelp:SetText(mountedNPCModelScanFinished
            and ("Indexed " .. #mountedNPCModels .. " mounted .mdl files. Showing common human paths; enter a folder or name to filter all models.")
            or (tostring(#mountedNPCModels) .. " common citizen models listed. Focus search to index all mounted .mdl files."))
    else
        combo:SetValue(found == 0 and "No matching mounted model" or (tostring(found) .. " matches; choose below"))
        controls.npcModelSearchHelp:SetText(mountedNPCModelScanFinished
            and ("Showing " .. shown .. " of " .. found .. " matches.")
            or ("Indexing mounted models; " .. found .. " matches so far (showing " .. shown .. ")."))
    end
end

local function startMountedNPCModelScan()
    if mountedNPCModelScanStarted then return end
    mountedNPCModelScanStarted = true
    local queue, visited = {"models/"}, {}
    local queueIndex = 1
    timer.Create("AICitizenNPC.MountedNPCModelCatalog", 0, 0, function()
        local processed = 0
        while queueIndex <= #queue and processed < 15 do
            local path = queue[queueIndex]
            queueIndex = queueIndex + 1
            if not visited[path] then
                visited[path] = true
                local files, directories = file.Find(path .. "*", "GAME")
                for _, name in ipairs(files or {}) do
                    if string.lower(string.GetExtensionFromFilename(name) or "") == "mdl" then
                        addMountedNPCModel(path .. name)
                    end
                end
                for _, name in ipairs(directories or {}) do
                    queue[#queue + 1] = path .. name .. "/"
                end
                processed = processed + 1
            end
        end

        if queueIndex > #queue then
            timer.Remove("AICitizenNPC.MountedNPCModelCatalog")
            table.sort(mountedNPCModels, function(a, b) return string.lower(a) < string.lower(b) end)
            mountedNPCModelScanFinished = true
            if activeControls and IsValid(activeControls.panel) then
                refreshNPCModelChoices(activeControls)
            end
        elseif activeControls and IsValid(activeControls.panel) then
            refreshNPCModelChoices(activeControls)
        end
    end)
end

local function releaseGameplayCursorAfterClose(chatJustFinished)
    timer.Simple(0, function()
        if IsValid(g_SpawnMenu) and g_SpawnMenu:IsVisible() then return end
        if IsValid(g_ContextMenu) and g_ContextMenu:IsVisible() then return end
        if gui.IsGameUIVisible() or gui.IsConsoleVisible() then return end
        if chatJustFinished then
            local focused = vgui.GetKeyboardFocus()
            if IsValid(focused) and focused:GetName() ~= "ChatInput" then return end
        end
        if vgui.CursorVisible() then gui.EnableScreenClicker(false) end
    end)
end

hook.Add("OnSpawnMenuClose", "AICitizenNPC.ReleaseSpawnMenuCursor", function()
    releaseGameplayCursorAfterClose(false)
end)
hook.Add("FinishChat", "AICitizenNPC.ReleaseChatCursor", function()
    releaseGameplayCursorAfterClose(true)
end)

local function askStatus()
    net.Start(CHANNELS.status)
    net.WriteUInt(0, 16)
    net.SendToServer()
end

local function sendOption(name, value)
    local id = OPTION_IDS[name]
    if not id then return end
    net.Start(CHANNELS.option)
    net.WriteUInt(id, 4)
    net.WriteBool(value == true)
    net.SendToServer()
end

local function createPage(panel, pageKind)
    local controls = {panel = panel, slots = {}, checkboxes = {}, applying = false, provider = "openai"}
    activeControls[controls] = true
    panel.OnRemove = function()
        activeControls[controls] = nil
    end

    if pageKind == "spawn" then
        panel:Help("Configure a provider slot, NPC appearance, and chat call name, then spawn its VJ Base human NPC.")
        panel:Help("Validate uses the key in this box for this game session. Save it only if you want it available after restarting. Keys stay server-side and are never returned to this menu.")
        panel:Help("After spawning, try public chat: Hello !john, can you hear me? Use the call name shown for your provider slot.")
        panel:Help("If chat says AI is disabled, open AI Citizen NPC Config and enable 'provider chat and game events'.")

    panel:Help("NPC appearance: search all mounted .mdl files and select a model, or enter its path. Choose a male/female citizen-style model with a VJ-compatible ValveBiped rig. The server checks that the file exists, not the rig. Changes apply to new NPCs only.")
    local npcModelEntry = vgui.Create("DTextEntry")
    npcModelEntry:SetPlaceholderText("models/Humans/Group03/Female_02.mdl")
    npcModelEntry:SetUpdateOnType(false)
    panel:AddItem(npcModelEntry)
    controls.npcModelEntry = npcModelEntry

    local npcModelSearch = vgui.Create("DTextEntry")
    npcModelSearch:SetPlaceholderText("Search mounted models by folder or name")
    npcModelSearch:SetUpdateOnType(true)
    npcModelSearch.OnGetFocus = startMountedNPCModelScan
    npcModelSearch.OnValueChange = function()
        startMountedNPCModelScan()
        refreshNPCModelChoices(controls)
    end
    panel:AddItem(npcModelSearch)
    controls.npcModelSearch = npcModelSearch
    local npcModelSearchHelp = panel:Help("Focus the search field to index mounted model files. The first full scan can take a short while.")
    controls.npcModelSearchHelp = npcModelSearchHelp

    local npcModelCombo = vgui.Create("DComboBox")
    npcModelCombo:SetValue("Choose a stock Citizen or search mounted models")
    npcModelCombo:SetSortItems(false)
    for _, path in ipairs(mountedNPCModels) do npcModelCombo:AddChoice(path, path) end
    npcModelCombo.OnSelect = function(_, _, _, path)
        if IsValid(npcModelEntry) then npcModelEntry:SetValue(path) end
    end
    panel:AddItem(npcModelCombo)
    controls.npcModelCombo = npcModelCombo
    refreshNPCModelChoices(controls)

    local saveNPCModel = vgui.Create("DButton")
    saveNPCModel:SetText("Save NPC appearance for future spawns")
    saveNPCModel.DoClick = function()
        local value = IsValid(npcModelEntry) and string.Trim(npcModelEntry:GetValue()) or ""
        if #value < 8 or #value > 240 then
            chat.AddText(Color(255, 130, 90), "[AI Citizen NPC] Enter a valid mounted .mdl path.")
            return
        end
        net.Start(CHANNELS.npc_model)
        net.WriteUInt(#value, 8)
        net.WriteData(value, #value)
        net.SendToServer()
    end
    panel:AddItem(saveNPCModel)
    controls.saveNPCModel = saveNPCModel

    local providerCombo = vgui.Create("DComboBox")
    providerCombo:SetValue("Select provider slot")
    providerCombo:AddChoice("OpenAI", "openai")
    providerCombo:AddChoice("OpenRouter", "openrouter")
    providerCombo:AddChoice("Local (OpenAI-compatible)", "local")
    providerCombo.OnSelect = function(_, _, _, provider)
        local slotID = SLOT_IDS[provider]
        if not slotID then return end
        controls.provider = provider
        if IsValid(controls.keyEntry) then
            controls.keyEntry:SetText(keyDrafts[provider] or "")
        end
        net.Start(CHANNELS.select)
        net.WriteUInt(slotID, 2)
        net.SendToServer()
        if controls.snapshot then
            controls.applying = true
            controls.applySlot(controls.snapshot)
            controls.applying = false
        end
    end
    panel:AddItem(providerCombo)
    controls.providerCombo = providerCombo

    local modelEntry = vgui.Create("DTextEntry")
    modelEntry:SetPlaceholderText("Provider model ID")
    modelEntry:SetUpdateOnType(false)
    panel:AddItem(modelEntry)
    controls.modelEntry = modelEntry

    local modelCombo = vgui.Create("DComboBox")
    modelCombo:SetValue("Validate connection to load available models")
    modelCombo:SetSortItems(false)
    panel:AddItem(modelCombo)
    controls.modelCombo = modelCombo

    local saveModel = vgui.Create("DButton")
    saveModel:SetText("Save model for selected provider")
    saveModel.DoClick = function()
        local provider = controls.provider
        local model = IsValid(modelCombo) and modelCombo:GetValue() or ""
        if model == "" and IsValid(modelEntry) then model = modelEntry:GetValue() end
        if not SLOT_IDS[provider] or #model < 1 or #model > 128 then return end
        net.Start(CHANNELS.model)
        net.WriteUInt(SLOT_IDS[provider], 2)
        net.WriteUInt(#model, 8)
        net.WriteData(model, #model)
        net.SendToServer()
    end
    panel:AddItem(saveModel)
    controls.saveModel = saveModel

    local callNameEntry = vgui.Create("DTextEntry")
    callNameEntry:SetPlaceholderText("NPC chat name, for example citizen")
    callNameEntry:SetUpdateOnType(false)
    panel:AddItem(callNameEntry)
    controls.callNameEntry = callNameEntry

    local saveCallName = vgui.Create("DButton")
    saveCallName:SetText("Save chat call name")
    saveCallName.DoClick = function()
        local provider = controls.provider
        local value = IsValid(callNameEntry) and callNameEntry:GetValue() or ""
        if not SLOT_IDS[provider] or #value < 2 or #value > 16 then return end
        net.Start(CHANNELS.call_name)
        net.WriteUInt(SLOT_IDS[provider], 2)
        net.WriteUInt(#value, 5)
        net.WriteData(value, #value)
        net.SendToServer()
    end
    panel:AddItem(saveCallName)
    controls.saveCallName = saveCallName

    local endpointEntry = vgui.Create("DTextEntry")
    endpointEntry:SetPlaceholderText("Local base URL, e.g. http://127.0.0.1:1234/v1")
    endpointEntry:SetUpdateOnType(false)
    panel:AddItem(endpointEntry)
    controls.endpointEntry = endpointEntry

    local saveEndpoint = vgui.Create("DButton")
    saveEndpoint:SetText("Save Local base URL")
    saveEndpoint.DoClick = function()
        local value = IsValid(endpointEntry) and endpointEntry:GetValue() or ""
        if #value < 8 or #value > 240 then return end
        net.Start(CHANNELS.endpoint)
        net.WriteUInt(SLOT_IDS["local"], 2)
        net.WriteUInt(#value, 9)
        net.WriteData(value, #value)
        net.SendToServer()
    end
    panel:AddItem(saveEndpoint)
    controls.saveEndpoint = saveEndpoint

    local validate = vgui.Create("DButton")
    validate:SetText("Validate key and load models (session only)")
    validate.DoClick = function()
        local provider = controls.provider
        if not SLOT_IDS[provider] then return end
        local key = IsValid(controls.keyEntry) and controls.keyEntry:GetValue() or ""
        local minimum = provider == "local" and 1 or 20
        if key ~= "" and (#key < minimum or #key > 512 or string.find(key, "%s")) then
            chat.AddText(Color(255, 130, 90), "[AI Citizen NPC] Enter a valid key, or leave the box empty to use a saved key.")
            return
        end
        keyDrafts[provider] = key
        net.Start(CHANNELS.validate)
        net.WriteUInt(SLOT_IDS[provider], 2)
        net.WriteUInt(#key, 10)
        if #key > 0 then net.WriteData(key, #key) end
        net.SendToServer()
    end
    panel:AddItem(validate)
    controls.validateButton = validate

    local keyEntry = vgui.Create("DTextEntry")
    keyEntry:SetPlaceholderText("Paste provider API key (20-512 characters)")
    keyEntry:SetUpdateOnType(true)
    keyEntry:SetHistoryEnabled(false)
    keyEntry:SetText(keyDrafts[controls.provider] or "")
    keyEntry.OnValueChange = function(_, value)
        keyDrafts[controls.provider] = value or ""
    end
    panel:AddItem(keyEntry)
    controls.keyEntry = keyEntry
    local keyHelp = panel:Help("The key remains in this box for the current game session. A blank box uses a saved key if one exists. Use Remove key to clear both session and saved credentials.")
    controls.keyHelp = keyHelp

    local saveKey = vgui.Create("DButton")
    saveKey:SetText("Save key for future sessions")
    saveKey.DoClick = function()
        local provider = controls.provider
        local key = IsValid(keyEntry) and keyEntry:GetValue() or ""
        local minimum = provider == "local" and 1 or 20
        if not SLOT_IDS[provider] or #key < minimum or #key > 512 or string.find(key, "%s") then
            chat.AddText(Color(255, 130, 90), "[AI Citizen NPC] Enter a valid 20-512 character cloud key or 1-512 character Local key before saving.")
            return
        end
        net.Start(CHANNELS.key)
        net.WriteUInt(SLOT_IDS[provider], 2)
        net.WriteUInt(#key, 10)
        if #key > 0 then net.WriteData(key, #key) end
        net.SendToServer()
        keyDrafts[provider] = key
    end
    panel:AddItem(saveKey)

    local clearKey = vgui.Create("DButton")
    clearKey:SetText("Remove session and saved key")
    clearKey.DoClick = function()
        local provider = controls.provider
        if not SLOT_IDS[provider] then return end
        Derma_Query("Remove the " .. SLOT_LABELS[provider] .. " key from this session and saved server data? The provider slot will be disabled.",
            "Remove provider key", "Remove key", function()
                keyDrafts[provider] = nil
                if IsValid(keyEntry) then keyEntry:SetText("") end
                net.Start(CHANNELS.clear_key)
                net.WriteUInt(SLOT_IDS[provider], 2)
                net.SendToServer()
                timer.Simple(0.25, askStatus)
            end,
            "Cancel", function() end)
    end
    panel:AddItem(clearKey)

    local slotHelp = panel:Help("Each provider slot can own one NPC. Enter a key and validate, optionally save it for future sessions, choose a listed model, set a unique call name, enable the slot, and spawn. Local providers must be reachable from the game server.")
    controls.slotHelp = slotHelp
    for _, provider in ipairs({"openai", "openrouter", "local"}) do
        local label = panel:Help(SLOT_LABELS[provider] .. ": checking server key and NPC status...")
        local enabled = vgui.Create("DCheckBoxLabel")
        enabled:SetText("Enable " .. SLOT_LABELS[provider] .. " NPC slot")
        enabled:SetValue(0)
        enabled:SizeToContents()
        enabled.OnChange = function(_, value)
            if controls.applying then return end
            net.Start(CHANNELS.slot)
            net.WriteUInt(SLOT_IDS[provider], 2)
            net.WriteBool(value == true)
            net.SendToServer()
        end
        panel:AddItem(enabled)
        local spawn = vgui.Create("DButton")
        spawn:SetText("Spawn " .. SLOT_LABELS[provider] .. " Citizen NPC")
        spawn:SetEnabled(false)
        spawn.DoClick = function()
            net.Start(CHANNELS.spawn)
            net.WriteUInt(SLOT_IDS[provider], 2)
            net.SendToServer()
            timer.Simple(0.5, askStatus)
        end
        panel:AddItem(spawn)
        local remove = vgui.Create("DButton")
        remove:SetText("Remove my " .. SLOT_LABELS[provider] .. " NPC")
        remove:SetEnabled(false)
        remove.DoClick = function()
            net.Start(CHANNELS.remove)
            net.WriteUInt(SLOT_IDS[provider], 2)
            net.SendToServer()
            timer.Simple(0.5, askStatus)
        end
        panel:AddItem(remove)
        controls.slots[provider] = {label = label, enabled = enabled, spawn = spawn, remove = remove}
    end
    end

    if pageKind == "config" then
    panel:Help("These switches configure AI Citizen NPC and selected VJ Base behavior. VJ Base continues to own its general NPC behavior, Equipment tool, and Spawner tool.")
    panel:Help("Follow behavior and spawn-menu weapon overrides apply to newly spawned AI Citizens. Weapon overrides default off so an unrelated selected weapon is not assigned at spawn.")
    panel:Help("Dropped Universal Toolgun pickup is an optional bridge to the separate Universal Toolgun addon; it only considers unowned world weapons.")
    panel:Help("AI and tool switches are server settings. Start with AI chat and animation; enable MCP or Starfall only after configuring those services.")
    panel:Help("Native MCP listens on loopback for local tools. It requires the MCP switch, a pairing token, and the native module; it does not make a private game reachable from hosted providers.")
    controls.transportHelp = panel:Help("MCP transport: checking server status...")
    for _, entry in ipairs({
        {name = "ai_citizen_npc_ai_enabled", label = "Enable provider chat and game events"},
        {name = "ai_citizen_npc_ai_chat_context", label = "Include recent public chat in addressed AI turns (players are notified)"},
        {name = "ai_citizen_npc_ai_npc_audio_events", label = "Send nearby NPC voice cues to the agent"},
        {name = "ai_citizen_npc_ai_animation_enabled", label = "Enable context and requested gestures"},
        {name = "ai_citizen_npc_ai_mcp_enabled", label = "Enable configured MCP bridge"},
        {name = "ai_citizen_npc_ai_mcp_native_enabled", label = "Enable native loopback MCP listener"},
        {name = "ai_citizen_npc_ai_starfall_enabled", label = "Enable StarfallEx expression component"},
        {name = "ai_citizen_npc_ai_vj_actions_enabled", label = "Allow direct-provider VJ actions"},
        {name = "ai_citizen_npc_ai_mcp_vj_actions_enabled", label = "Allow MCP VJ/entity actions"},
        {name = "ai_citizen_npc_ai_starfall_code_enabled", label = "Allow model-authored Starfall behavior (sandboxed)"},
        {name = "ai_citizen_npc_ai_toolgun_pickup", label = "Allow pickup of dropped Universal Toolguns"},
        {name = "ai_citizen_npc_ai_vj_follow_player", label = "Enable VJ Base follow behavior when the owner presses Use"},
        {name = "ai_citizen_npc_ai_vj_use_spawnmenu_weapons", label = "Allow VJ Base spawn-menu weapon overrides on new AI Citizens"}
    }) do
        local check = vgui.Create("DCheckBoxLabel")
        check:SetText(entry.label)
        check:SetValue(0)
        check:SizeToContents()
        check.OnChange = function(_, value)
            if not controls.applying then sendOption(entry.name, value) end
        end
        panel:AddItem(check)
        controls.checkboxes[entry.name] = check
    end

    local refresh = vgui.Create("DButton")
    refresh:SetText("Refresh server status")
    refresh.DoClick = askStatus
    panel:AddItem(refresh)
    end

    if pageKind == "spawn" then
    controls.applySlot = function(snapshot)
        local provider = controls.provider or snapshot.selected_provider or "openai"
        local selectedSlot
        for _, slot in ipairs(snapshot.slots or {}) do
            if slot.provider == provider then selectedSlot = slot break end
        end
        if not selectedSlot then return end
        local changedProvider = controls.lastAppliedProvider ~= provider
        local changedNPCModel = controls.lastAppliedNPCModel ~= snapshot.npc_model
        controls.lastAppliedProvider = provider
        controls.lastAppliedNPCModel = snapshot.npc_model
        if changedProvider and IsValid(controls.keyEntry) then
            controls.keyEntry:SetText(keyDrafts[provider] or "")
        end
        if IsValid(controls.npcModelEntry)
            and (changedNPCModel or controls.npcModelEntry:GetValue() == "") then
            controls.npcModelEntry:SetValue(snapshot.npc_model or "models/Humans/Group03/Female_02.mdl")
        end
        local validated = selectedSlot.validated == true
        local isLocal = provider == "local"
        if IsValid(controls.callNameEntry) then
            controls.callNameEntry:SetVisible(validated)
            controls.callNameEntry:SetPlaceholderText("NPC chat name: !" .. tostring(selectedSlot.call_name or "name_id"))
            if changedProvider or controls.callNameEntry:GetValue() == "" then
                controls.callNameEntry:SetValue(selectedSlot.call_name or "")
            end
        end
        if IsValid(controls.saveCallName) then controls.saveCallName:SetVisible(validated) end
        if IsValid(controls.modelCombo) then
            controls.modelCombo:SetVisible(validated)
            controls.modelCombo:Clear()
            for _, model in ipairs(selectedSlot.models or {}) do
                controls.modelCombo:AddChoice(model, model)
            end
            controls.modelCombo:SetValue(selectedSlot.model or "")
            if #((selectedSlot.models) or {}) == 0 then
                controls.modelCombo:SetValue("No model catalog; validate connection")
            end
        end
        if IsValid(controls.modelEntry) then
            controls.modelEntry:SetVisible(validated)
            if changedProvider or controls.modelEntry:GetValue() == "" then
                controls.modelEntry:SetValue(selectedSlot.model or "")
            end
        end
        if IsValid(controls.saveModel) then controls.saveModel:SetVisible(validated) end
        if IsValid(controls.endpointEntry) then
            controls.endpointEntry:SetVisible(isLocal)
            if selectedSlot.base_url and (changedProvider or controls.endpointEntry:GetValue() == "") then
                controls.endpointEntry:SetValue(selectedSlot.base_url)
            end
        end
        if IsValid(controls.saveEndpoint) then controls.saveEndpoint:SetVisible(isLocal) end
        local selectedRow = controls.slots[provider]
        if selectedRow and IsValid(selectedRow.enabled) then
            selectedRow.enabled:SetVisible(true)
            selectedRow.enabled:SetValue(selectedSlot.enabled and 1 or 0)
        end
        if IsValid(controls.keyHelp) then
            controls.keyHelp:SetText(isLocal
                and "A Local key is optional. Validate uses this box for the current session; Save key stores it server-side for future sessions."
                or "Validate uses this key for the current session. Save key stores it server-side for future sessions; the key is never sent back to this menu.")
        end
        if IsValid(controls.keyEntry) then
            controls.keyEntry:SetPlaceholderText(isLocal
                and "Optional Local bearer key"
                or "Paste provider API key (20-512 characters)")
        end
        if IsValid(controls.panel) then controls.panel:InvalidateLayout(true) end
    end
    end
    askStatus()
end

local function createSpawnPage(panel)
    createPage(panel, "spawn")
end

local function createConfigPage(panel)
    createPage(panel, "config")
end

net.Receive(CHANNELS.status, function()
    local raw = net.ReadString()
    local snapshot = util.JSONToTable(raw or "")
    if not istable(snapshot) then return end
    AICitizenNPC = AICitizenNPC or {}
    AICitizenNPC.UIStatus = snapshot
    if istable(snapshot.focused) then
        local focused = snapshot.focused
        chat.AddText(Color(90, 210, 255), string.format(
            "[AI Citizen NPC] ent %d | %s / %s | body %s | HP %d/%d | cue %s | key %s | Toolgun %s",
            tonumber(focused.entity) or 0,
            tostring(focused.provider or "unknown"),
            tostring(focused.model or "unknown"),
            tostring(focused.body_model or "unknown"),
            tonumber(focused.health) or 0,
            tonumber(focused.max_health) or 0,
            tostring(focused.cue or "idle"),
            focused.key_configured and "configured" or "missing",
            focused.toolgun_held and "held" or "not held"
        ))
    end
    for controls in pairs(activeControls) do
    if IsValid(controls.panel) then
    controls.snapshot = snapshot
    controls.applying = true
    local selected = snapshot.selected_provider
    controls.provider = selected
    if IsValid(controls.providerCombo) then
        controls.providerCombo:SetValue(SLOT_LABELS[selected] or "Select provider slot")
    end
    if isfunction(controls.applySlot) then controls.applySlot(snapshot) end
    for _, slot in ipairs(snapshot.slots or {}) do
        local row = controls.slots[slot.provider]
        if row and IsValid(row.label) then
            local keyText = slot.provider == "local"
                and (slot.connection_configured and "endpoint configured" or "endpoint missing")
                or (slot.key_configured and (slot.key_session and (slot.key_saved and "session key active (saved)" or "session key active") or "saved key configured") or "no key configured")
            local validationText = slot.validated and "validated" or "not validated"
            local enabledText = slot.enabled and "slot enabled" or "slot disabled"
            local bodyText = slot.npc_removing and "NPC removal in progress"
                or slot.npc_count > 0 and ("NPC active (ent " .. tostring(slot.npc_ent) .. ")")
                or "no active NPC"
            row.label:SetText(string.format("%s — %s, %s, %s, %s, model %s, call !%s", SLOT_LABELS[slot.provider], keyText, validationText, enabledText, bodyText, tostring(slot.model), tostring(slot.call_name or "")))
            row.spawn:SetEnabled(slot.ready and slot.npc_count == 0)
            row.remove:SetEnabled(slot.npc_count > 0 and slot.npc_ent > 0 and not slot.npc_removing)
            row.enabled:SetVisible(true)
            row.enabled:SetValue(slot.enabled and 1 or 0)
        end
    end
    if IsValid(controls.transportHelp) then
        local transport = snapshot.mcp_transport or {}
        local native = snapshot.native_mcp or {}
        local socketState = transport.connection or "unavailable"
        local nativeState = native.listening and "listening"
            or native.enabled and "enabled, waiting for bind" or "disabled"
        controls.transportHelp:SetText(string.format(
            "MCP: %s, sidecar %s, native %s on 127.0.0.1:%d",
            snapshot.mcp_enabled and "enabled" or "disabled",
            socketState,
            nativeState,
            tonumber(native.port) or 0
        ))
    end
    for name, check in pairs(controls.checkboxes) do
        local field = name == "ai_citizen_npc_ai_enabled" and "ai_enabled"
            or name == "ai_citizen_npc_ai_animation_enabled" and "animation_enabled"
            or name == "ai_citizen_npc_ai_mcp_enabled" and "mcp_enabled"
            or name == "ai_citizen_npc_ai_mcp_native_enabled" and "native_mcp_enabled"
            or name == "ai_citizen_npc_ai_starfall_enabled" and "starfall_enabled"
            or name == "ai_citizen_npc_ai_vj_actions_enabled" and "vj_actions_enabled"
            or name == "ai_citizen_npc_ai_mcp_vj_actions_enabled" and "mcp_vj_actions_enabled"
            or name == "ai_citizen_npc_ai_npc_audio_events" and "npc_audio_events_enabled"
            or name == "ai_citizen_npc_ai_chat_context" and "chat_context_enabled"
            or name == "ai_citizen_npc_ai_toolgun_pickup" and "toolgun_pickup_enabled"
            or name == "ai_citizen_npc_ai_vj_follow_player" and "vj_follow_player"
            or name == "ai_citizen_npc_ai_vj_use_spawnmenu_weapons" and "vj_use_spawnmenu_weapons"
            or "starfall_code_enabled"
        check:SetValue(snapshot[field] and 1 or 0)
    end
    for _, slot in ipairs(snapshot.slots or {}) do
        if slot.provider == selected and IsValid(controls.modelEntry) and controls.modelEntry:GetValue() == "" then
            controls.modelEntry:SetValue(slot.model or "")
        end
    end
    controls.applying = false
    else
        activeControls[controls] = nil
    end
    end
end)

net.Receive(CHANNELS.reply, function()
    local message = net.ReadString()
    chat.AddText(Color(90, 210, 255), message)
end)

hook.Add("PopulateToolMenu", "AICitizenNPC.VJSettings", function()
    if not spawnmenu or not spawnmenu.AddToolMenuOption then return end
    -- AddToolMenuOption appends entries, so remove only our own IDs first.
    -- This keeps hot reloads and repeated PopulateToolMenu calls idempotent.
    local tools = isfunction(spawnmenu.GetTools) and spawnmenu.GetTools() or {}
    for _, tab in ipairs(tools) do
        if tab.Name == "DrVrej" then
            for _, category in ipairs(tab.Items or {}) do
                if category.ItemName == "Plugins" then
                    for i = #category, 1, -1 do
                        local entry = category[i]
                        if entry.ItemName == "ai_citizen_npc_spawn"
                            or entry.ItemName == "ai_citizen_npc_config" then
                            table.remove(category, i)
                        end
                    end
                end
            end
        end
    end
    spawnmenu.AddToolMenuOption("DrVrej", "Plugins", "ai_citizen_npc_spawn",
        "AI Citizen NPC Spawn", "", "", createSpawnPage)
    spawnmenu.AddToolMenuOption("DrVrej", "Plugins", "ai_citizen_npc_config",
        "AI Citizen NPC Config", "", "", createConfigPage)
end)

local function canShowAgentProperty(ent, ply)
    -- ACNAgentVJ and ACNOwner are server-only Lua fields, so clients cannot
    -- use them to decide whether this networked entity should expose a menu.
    -- The server handlers revalidate the class, owner, and admin permission.
    return IsValid(ent) and ent:GetClass() == "npc_vj_ai_citizen_npc"
        and IsValid(ply) and ply:IsAdmin()
end

if properties and properties.Add then
    properties.Add("ai_citizen_npc_status", {
        MenuLabel = "Check AI Citizen NPC status",
        Order = 900,
        MenuIcon = "icon16/information.png",
        Filter = function(_, ent, ply)
            return canShowAgentProperty(ent, ply)
        end,
        Action = function(_, ent)
            if not IsValid(ent) then return end
            net.Start(CHANNELS.status)
            net.WriteUInt(ent:EntIndex(), 16)
            net.SendToServer()
        end
    })
    properties.Add("ai_citizen_npc_starfall_attach", {
        MenuLabel = "Attach Starfall expression component",
        Order = 901,
        MenuIcon = "icon16/connect.png",
        Filter = function(_, ent, ply)
            return canShowAgentProperty(ent, ply)
        end,
        Action = function(_, ent)
            if not IsValid(ent) then return end
            net.Start(CHANNELS.starfall_attach)
            net.WriteEntity(ent)
            net.SendToServer()
        end
    })
    properties.Add("ai_citizen_npc_starfall_remove", {
        MenuLabel = "Detach Starfall expression component",
        Order = 902,
        MenuIcon = "icon16/disconnect.png",
        Filter = function(_, ent, ply)
            return canShowAgentProperty(ent, ply)
        end,
        Action = function(_, ent)
            if not IsValid(ent) then return end
            net.Start(CHANNELS.starfall_remove)
            net.WriteEntity(ent)
            net.SendToServer()
        end
    })
end

return true
