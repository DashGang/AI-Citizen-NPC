if not CLIENT then return end

local DIALOGUE_NET = "CAL.NPCDialogue"
local DIALOGUE_LOOKUP_NET = "CAL.NPCDialogueLookup"
local DIALOGUE_STATE_NET = "CAL.NPCDialogueState"
local DIALOGUE_READY_NET = "CAL.NPCDialogueReady"
local captureEnabled = false

local function captionText(text)
    text = tostring(text or "")
    text = string.gsub(text, "<clr:[^>]*>", " ")
    text = string.gsub(text, "<sfx>", " ")
    text = string.gsub(text, "</?I>", "")
    text = string.gsub(text, "<cr>", " ")
    text = string.gsub(text, "[%z\1-\8\11\12\14-\31\127]", " ")
    text = string.gsub(text, "[%s\r\n]+", " ")
    return string.Trim(text)
end

local function lookupCaption(soundScript, soundName)
    if not isfunction(GetSimplestSubtitle) then return nil end
    local ok, subtitle = pcall(GetSimplestSubtitle, soundScript, soundName)
    if not ok or not istable(subtitle) or not isstring(subtitle.text) then return nil end
    return captionText(subtitle.text), tonumber(subtitle.range)
end

local function processNpcSound(data)
    if not captureEnabled or not istable(data) or not IsValid(data.Entity) then return end
    local speaker = data.Entity
    local isNpc = speaker:IsNPC() or (isfunction(speaker.IsNextBot) and speaker:IsNextBot())
    if not isNpc or speaker:GetClass() == "npc_vj_ai_citizen_npc" then return end
    local soundScript = isstring(data.OriginalSoundName) and data.OriginalSoundName or ""
    local soundName = isstring(data.SoundName) and data.SoundName or ""
    local text, range = lookupCaption(soundScript, soundName)
    if not text or text == "" then return end
    if not data.ACNServerRouted then
        local listener = LocalPlayer()
        if not IsValid(listener) then return end
        if range and listener:GetPos():DistToSqr(speaker:GetPos()) > range * range then return end
    end

    net.Start(DIALOGUE_NET)
    net.WriteUInt(0, 32)
    net.WriteEntity(speaker)
    net.WriteString(text)
    net.WriteString(soundScript)
    net.WriteString(soundName)
    net.SendToServer()
end

local function processServerRoutedSound(lookupID, soundScript, soundName)
    if not captureEnabled or not isnumber(lookupID) or lookupID <= 0 then return end
    local text = lookupCaption(soundScript, soundName)
    if not text or text == "" then return end
    net.Start(DIALOGUE_NET)
    net.WriteUInt(lookupID, 32)
    net.WriteString(text)
    net.SendToServer()
end

net.Receive(DIALOGUE_STATE_NET, function()
    captureEnabled = net.ReadBool()
end)

net.Receive(DIALOGUE_LOOKUP_NET, function()
    local lookupID = net.ReadUInt(32)
    local soundScript = net.ReadString()
    local soundName = net.ReadString()
    processServerRoutedSound(lookupID, soundScript, soundName)
end)

hook.Add("EntityEmitSound", "AICitizenNPC.SubtitleContext", processNpcSound)

-- Handshake after the server receiver and the subtitle provider have loaded.
timer.Simple(0, function()
    net.Start(DIALOGUE_READY_NET)
    net.SendToServer()
end)

AICitizenNPCDialogue = AICitizenNPCDialogue or {}
AICitizenNPCDialogue._test = {
    CaptionText = captionText,
    ProcessNPCSound = processNpcSound,
    ProcessServerRoutedSound = processServerRoutedSound
}
