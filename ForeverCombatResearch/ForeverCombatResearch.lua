local addonName = ...

-- Forever Combat Research intentionally records only values that can be safely
-- inspected by insecure addon Lua. See docs/API_LIMITS.md before interpreting
-- any session as a combat-table measurement.

local SCHEMA_VERSION = 1
local DEFAULT_MAX_RECORDS = 75000
local SAMPLE_INTERVAL_SECONDS = 0.10
local ACTION_SLOT_MAX = 180
local ENGLISH_HEROIC_STRIKE = "heroic strike"

local frame = CreateFrame("Frame")
local initialized = false
local db
local activeSession
local sampleElapsed = 0
local slotsDirty = true
local autoSlots = {}
local lastAutoDiscovery = 0
local lastHSState

local combatChatEvents = {
    "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_HITS",
    "CHAT_MSG_COMBAT_CREATURE_VS_CREATURE_MISSES",
    "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_HITS",
    "CHAT_MSG_COMBAT_CREATURE_VS_PARTY_MISSES",
    "CHAT_MSG_COMBAT_FACTION_CHANGE",
    "CHAT_MSG_COMBAT_GUILD_XP_GAIN",
    "CHAT_MSG_COMBAT_HONOR_GAIN",
    "CHAT_MSG_COMBAT_MISC_INFO",
    "CHAT_MSG_COMBAT_PARTY_HITS",
    "CHAT_MSG_COMBAT_PARTY_MISSES",
    "CHAT_MSG_COMBAT_PET_HITS",
    "CHAT_MSG_COMBAT_PET_MISSES",
    "CHAT_MSG_COMBAT_SELF_HITS",
    "CHAT_MSG_COMBAT_SELF_MISSES",
    "CHAT_MSG_COMBAT_XP_GAIN",
}

local equipmentSlots = {
    { name = "head", slot = 1 }, { name = "neck", slot = 2 },
    { name = "shoulder", slot = 3 }, { name = "shirt", slot = 4 },
    { name = "chest", slot = 5 }, { name = "waist", slot = 6 },
    { name = "legs", slot = 7 }, { name = "feet", slot = 8 },
    { name = "wrist", slot = 9 }, { name = "hands", slot = 10 },
    { name = "finger1", slot = 11 }, { name = "finger2", slot = 12 },
    { name = "trinket1", slot = 13 }, { name = "trinket2", slot = 14 },
    { name = "back", slot = 15 }, { name = "mainHand", slot = 16 },
    { name = "offHand", slot = 17 }, { name = "ranged", slot = 18 },
}

local function plainError(err)
    local ok, text = pcall(tostring, err)
    if ok and type(text) == "string" then
        return text
    end
    return "unprintable error"
end

local function isSecret(value)
    if type(_G.issecretvalue) ~= "function" then
        return false
    end
    local ok, result = pcall(_G.issecretvalue, value)
    return ok and result == true
end

-- Returns a SavedVariables-safe primitive or a marker. Never calls tostring on
-- a Secret Value, which would amount to trying to inspect protected data.
local function persistable(value)
    if isSecret(value) then
        return { state = "secret" }
    end
    local kind = type(value)
    if kind == "nil" then
        return { state = "nil" }
    end
    if kind == "string" or kind == "number" or kind == "boolean" then
        return value
    end
    return { state = "unsupported", valueType = kind }
end

local function callOne(fn, ...)
    if type(fn) ~= "function" then
        return { state = "unavailable" }
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return { state = "error", message = plainError(value) }
    end
    return persistable(value)
end

local function callBoolean(fn, ...)
    if type(fn) ~= "function" then
        return nil, "unavailable"
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil, "error: " .. plainError(value)
    end
    if isSecret(value) then
        return nil, "secret"
    end
    if type(value) ~= "boolean" then
        return nil, "unexpected " .. type(value)
    end
    return value, "ok"
end

local function safeString(value)
    if isSecret(value) or type(value) ~= "string" then
        return nil
    end
    return value
end

local function clientTime()
    local wall = callOne(_G.date, "%Y-%m-%dT%H:%M:%S")
    local uptime = callOne(_G.GetTimePreciseSec or _G.GetTime)
    return { wall = wall, uptime = uptime }
end

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[copy(key, seen)] = copy(item, seen)
    end
    return result
end

local function chat(message)
    local text = "|cff70d6ffFCR:|r " .. message
    local delivered = false
    local maxFrames = tonumber(_G.NUM_CHAT_WINDOWS) or 10
    local probes = {
        "CHAT_MSG_COMBAT_SELF_HITS",
        "CHAT_MSG_COMBAT_SELF_MISSES",
        "CHAT_MSG_COMBAT_MISC_INFO",
    }

    -- The Combat Log can be moved or renamed, so do not assume ChatFrame2.
    -- Instead, use the frame currently subscribed to combat-message events.
    for index = 1, maxFrames do
        local chatFrame = _G["ChatFrame" .. index]
        if chatFrame and type(chatFrame.IsEventRegistered) == "function" and type(chatFrame.AddMessage) == "function" then
            local isCombatLog = false
            for _, eventName in ipairs(probes) do
                local ok, registered = pcall(chatFrame.IsEventRegistered, chatFrame, eventName)
                if ok and registered then
                    isCombatLog = true
                    break
                end
            end
            if isCombatLog then
                chatFrame:AddMessage(text, 0.44, 0.84, 1.00)
                delivered = true
            end
        end
    end

    if not delivered then
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(text)
        else
            print(text)
        end
    end
end

local function appendRecord(kind, payload)
    if not activeSession then
        return false
    end
    if #activeSession.records >= activeSession.maxRecords then
        activeSession.droppedRecords = activeSession.droppedRecords + 1
        activeSession.truncated = true
        return false
    end
    payload = payload or {}
    payload.kind = kind
    payload.time = clientTime()
    table.insert(activeSession.records, payload)
    return true
end

local function serializeArgs(...)
    local count = select("#", ...)
    local values = { count = count, values = {} }
    for index = 1, count do
        values.values[index] = persistable(select(index, ...))
    end
    return values
end

local function tryUnitExists(unit)
    local exists, state = callBoolean(_G.UnitExists, unit)
    if state ~= "ok" then
        return nil, state
    end
    return exists, "ok"
end

local function multiUnitClass(unit)
    if type(_G.UnitClass) ~= "function" then
        return { localized = { state = "unavailable" }, token = { state = "unavailable" } }
    end
    local ok, localized, token = pcall(_G.UnitClass, unit)
    if not ok then
        return { localized = { state = "error", message = plainError(localized) }, token = { state = "unavailable" } }
    end
    return { localized = persistable(localized), token = persistable(token) }
end

local function multiUnitStat(index)
    if type(_G.UnitStat) ~= "function" then
        return { state = "unavailable" }
    end
    local ok, base, effective, positive, negative = pcall(_G.UnitStat, "player", index)
    if not ok then
        return { state = "error", message = plainError(base) }
    end
    return {
        base = persistable(base), effective = persistable(effective),
        positive = persistable(positive), negative = persistable(negative),
    }
end

local function playerEquipment()
    local result = {}
    for _, entry in ipairs(equipmentSlots) do
        result[entry.name] = {
            slot = entry.slot,
            itemID = callOne(_G.GetInventoryItemID, "player", entry.slot),
            itemLink = callOne(_G.GetInventoryItemLink, "player", entry.slot),
        }
    end
    return result
end

local function playerSnapshot()
    return {
        source = "player",
        name = callOne(_G.UnitName, "player"),
        guid = callOne(_G.UnitGUID, "player"),
        class = multiUnitClass("player"),
        level = callOne(_G.UnitLevel, "player"),
        race = callOne(_G.UnitRace, "player"),
        equipment = playerEquipment(),
        primaryStats = {
            strength = multiUnitStat(1), agility = multiUnitStat(2),
            stamina = multiUnitStat(3), intellect = multiUnitStat(4),
            spirit = multiUnitStat(5),
        },
        combatStats = {
            attackPower = callOne(_G.GetAttackPowerForStat, 1),
            critChance = callOne(_G.GetCritChance),
            haste = callOne(_G.GetHaste),
            mastery = callOne(_G.GetMasteryEffect),
            versatility = callOne(_G.GetVersatilityBonus),
            expertise = callOne(_G.GetExpertise),
        },
    }
end

local function targetSnapshot()
    local exists, existsState = tryUnitExists("target")
    if existsState ~= "ok" then
        return { source = "target", state = existsState }
    end
    if not exists then
        return { source = "target", state = "none" }
    end
    return {
        source = "target",
        state = "present",
        name = callOne(_G.UnitName, "target"),
        guid = callOne(_G.UnitGUID, "target"),
        class = multiUnitClass("target"),
        level = callOne(_G.UnitLevel, "target"),
        classification = callOne(_G.UnitClassification, "target"),
        creatureType = callOne(_G.UnitCreatureType, "target"),
        creatureFamily = callOne(_G.UnitCreatureFamily, "target"),
        isPlayer = callOne(_G.UnitIsPlayer, "target"),
        canAttack = callOne(_G.UnitCanAttack, "player", "target"),
    }
end

local function spellNameForAction(actionID)
    if _G.C_Spell and type(_G.C_Spell.GetSpellInfo) == "function" then
        local ok, info = pcall(_G.C_Spell.GetSpellInfo, actionID)
        if ok and type(info) == "table" then
            return safeString(info.name)
        end
    end
    if type(_G.GetSpellInfo) == "function" then
        local ok, name = pcall(_G.GetSpellInfo, actionID)
        if ok then
            return safeString(name)
        end
    end
    return nil
end

local function spellNameForMacro(macroID)
    if type(_G.GetMacroSpell) ~= "function" then
        return nil
    end
    local ok, first, second = pcall(_G.GetMacroSpell, macroID)
    if not ok then
        return nil
    end
    if type(second) == "number" then
        return spellNameForAction(second)
    end
    return safeString(first)
end

local function actionInfo(slot)
    if _G.C_ActionBar and type(_G.C_ActionBar.GetActionInfo) == "function" then
        local ok, actionType, actionID = pcall(_G.C_ActionBar.GetActionInfo, slot)
        if ok then
            -- Some current-client builds return an action-info table, while
            -- older/compatibility builds return separate values.
            if type(actionType) == "table" then
                actionID = actionType.actionID or actionType.id
                actionType = actionType.actionType or actionType.type
            end
            return safeString(actionType), actionID, "C_ActionBar.GetActionInfo"
        end
    end
    if type(_G.GetActionInfo) == "function" then
        local ok, actionType, actionID = pcall(_G.GetActionInfo, slot)
        if ok then
            return safeString(actionType), actionID, "GetActionInfo"
        end
    end
    return nil, nil, "unavailable"
end

local function discoverHeroicStrikeSlots()
    autoSlots = {}
    for slot = 1, ACTION_SLOT_MAX do
        local actionType, actionID = actionInfo(slot)
        local name
        if actionType == "spell" and type(actionID) == "number" then
            name = spellNameForAction(actionID)
        elseif actionType == "macro" and type(actionID) == "number" then
            name = spellNameForMacro(actionID)
        end
        if name and string.lower(name) == ENGLISH_HEROIC_STRIKE then
            table.insert(autoSlots, slot)
        end
    end
    slotsDirty = false
    lastAutoDiscovery = tonumber(callOne(_G.GetTime)) or 0
    if db then
        db.runtime.autoDetectedHeroicStrikeSlots = copy(autoSlots)
    end
end

local function configuredSlots()
    if db and db.settings and type(db.settings.heroicStrikeSlots) == "table" and #db.settings.heroicStrikeSlots > 0 then
        return db.settings.heroicStrikeSlots, "configured"
    end
    local now = tonumber(callOne(_G.GetTime)) or 0
    if slotsDirty or now - lastAutoDiscovery > 2 then
        discoverHeroicStrikeSlots()
    end
    return autoSlots, "auto"
end

local function currentAction(slot)
    if _G.C_ActionBar and type(_G.C_ActionBar.IsActionCurrent) == "function" then
        local active, state = callBoolean(_G.C_ActionBar.IsActionCurrent, slot)
        return active, state, "C_ActionBar.IsActionCurrent"
    end
    if _G.C_ActionBar and type(_G.C_ActionBar.IsCurrentAction) == "function" then
        local active, state = callBoolean(_G.C_ActionBar.IsCurrentAction, slot)
        return active, state, "C_ActionBar.IsCurrentAction"
    end
    if type(_G.IsCurrentAction) == "function" then
        local active, state = callBoolean(_G.IsCurrentAction, slot)
        return active, state, "IsCurrentAction"
    end
    return nil, "unavailable", "none"
end

local function scanHeroicStrike(reason)
    local slots, source = configuredSlots()
    local observation = { source = source, reason = reason, slots = {} }
    if #slots == 0 then
        observation.state = "unknown"
        observation.detail = "no configured slot; English-name auto-discovery found none"
        return observation
    end
    local hasUsableResult = false
    local hasUnknownResult = false
    for _, slot in ipairs(slots) do
        local active, state, api = currentAction(slot)
        table.insert(observation.slots, { slot = slot, active = persistable(active), result = state, api = api })
        if state == "ok" then
            hasUsableResult = true
            if active then
                observation.state = "active"
            end
        else
            hasUnknownResult = true
        end
    end
    if observation.state ~= "active" then
        if hasUsableResult and not hasUnknownResult then
            observation.state = "inactive"
        else
            observation.state = "unknown"
        end
    end
    return observation
end

local function recordHSState(reason, force)
    if not activeSession then
        return
    end
    local observation = scanHeroicStrike(reason)
    local changed = observation.state ~= lastHSState
    if force or changed then
        appendRecord("hs_transition", observation)
        lastHSState = observation.state
    end
    if changed then
        chat("Heroic Strike queue: " .. string.upper(observation.state) .. ".")
    end
end

local function register(event)
    local ok, err = pcall(frame.RegisterEvent, frame, event)
    db.runtime.eventRegistration[event] = ok and true or { state = "error", message = plainError(err) }
end

local function buildCapabilities()
    local build = { state = "unavailable" }
    if type(_G.GetBuildInfo) == "function" then
        local ok, version, buildNumber, date, toc = pcall(_G.GetBuildInfo)
        if ok then
            build = { version = persistable(version), build = persistable(buildNumber), date = persistable(date), interface = persistable(toc) }
        else
            build = { state = "error", message = plainError(version) }
        end
    end
    return {
        observedAt = clientTime(),
        build = build,
        heroStrikeQueue = {
            currentActionModern = type(_G.C_ActionBar) == "table" and type(_G.C_ActionBar.IsCurrentAction) == "function",
            currentActionModernRenamed = type(_G.C_ActionBar) == "table" and type(_G.C_ActionBar.IsActionCurrent) == "function",
            currentActionLegacy = type(_G.IsCurrentAction) == "function",
            actionInfoModern = type(_G.C_ActionBar) == "table" and type(_G.C_ActionBar.GetActionInfo) == "function",
            actionInfoLegacy = type(_G.GetActionInfo) == "function",
            spellInfoModern = type(_G.C_Spell) == "table" and type(_G.C_Spell.GetSpellInfo) == "function",
            spellInfoLegacy = type(_G.GetSpellInfo) == "function",
            autoDetection = "English Heroic Strike name only; configure slots for localized clients",
        },
        combatOutcomes = {
            rawCombatLog = "not registered: current Midnight guidance says unavailable to addons",
            combatChatMessages = "subscribed; raw text saved only when non-secret",
            perSwingMainHandOffHand = "unavailable: no validated addon API",
            parsedOutcome = "not produced: KString/Secret Values must not be parsed",
        },
        savedVariables = "client writes on clean shutdown; addon never writes arbitrary files",
        eventRegistration = {},
    }
end

local function snapshot(reason)
    if not activeSession then
        chat("No active session. Use /fcr start first.")
        return
    end
    appendRecord("snapshot", { reason = reason, player = playerSnapshot(), target = targetSnapshot() })
end

local function enableCombatFileLogging()
    local wasEnabled, initialState = callBoolean(_G.LoggingCombat)
    local isEnabled, resultState = callBoolean(_G.LoggingCombat, true)
    local outcome = "unavailable"
    if resultState == "ok" then
        if isEnabled then
            outcome = wasEnabled and "already_enabled" or "enabled"
        else
            outcome = "refused_or_disabled"
        end
    elseif resultState == "secret" then
        outcome = "secret_result"
    elseif string.find(resultState, "error:") then
        outcome = "error"
    end
    return {
        api = "LoggingCombat",
        before = persistable(wasEnabled), beforeResult = initialState,
        after = persistable(isEnabled), result = resultState,
        outcome = outcome,
        policy = "enabled at session start; never disabled automatically",
    }
end

local function startSession(label)
    if activeSession then
        chat("A session is already active: " .. activeSession.id)
        return
    end
    local sequence = #db.sessions + 1
    local id = string.format("session-%04d-%s", sequence, tostring(callOne(_G.time)))
    activeSession = {
        id = id,
        label = label or "",
        startedAt = clientTime(),
        endedAt = nil,
        maxRecords = db.settings.maxRecords or DEFAULT_MAX_RECORDS,
        records = {},
        droppedRecords = 0,
        truncated = false,
        capabilities = copy(db.runtime.capabilities),
    }
    table.insert(db.sessions, activeSession)
    db.activeSessionID = id
    lastHSState = nil
    local combatFileLogging = enableCombatFileLogging()
    appendRecord("combat_file_logging", combatFileLogging)
    snapshot("session_start")
    appendRecord("session_start", { label = activeSession.label })
    recordHSState("session_start", true)
    if combatFileLogging.outcome == "enabled" then
        chat("Client combat-file logging enabled.")
    elseif combatFileLogging.outcome == "already_enabled" then
        chat("Client combat-file logging was already enabled.")
    else
        chat("Client combat-file logging was not confirmed: " .. combatFileLogging.outcome .. ".")
    end
    chat("Started " .. id .. ".")
end

local function stopSession()
    if not activeSession then
        chat("No active session.")
        return
    end
    recordHSState("session_stop", false)
    appendRecord("session_stop", { droppedRecords = activeSession.droppedRecords, truncated = activeSession.truncated })
    activeSession.endedAt = clientTime()
    db.activeSessionID = nil
    chat("Stopped " .. activeSession.id .. " (" .. #activeSession.records .. " records; " .. activeSession.droppedRecords .. " dropped).")
    activeSession = nil
    lastHSState = nil
end

local function parseSlotList(argument)
    local slots = {}
    for token in string.gmatch(argument or "", "[^,%s]+") do
        local slot = tonumber(token)
        if not slot or slot < 1 or slot > ACTION_SLOT_MAX or slot % 1 ~= 0 then
            return nil, "Slots must be whole numbers from 1 to " .. ACTION_SLOT_MAX .. "."
        end
        table.insert(slots, slot)
    end
    if #slots == 0 then
        return nil, "Specify at least one slot, e.g. /fcr slots 1"
    end
    return slots
end

local function showStatus()
    local slots, source = configuredSlots()
    local state = scanHeroicStrike("status")
    local session = activeSession and activeSession.id or "none"
    chat("Session: " .. session .. "; HS source: " .. source .. "; slots: " .. (#slots > 0 and table.concat(slots, ",") or "none") .. "; latest state: " .. state.state .. ".")
    if activeSession and activeSession.truncated then
        chat("WARNING: session reached its record cap; " .. activeSession.droppedRecords .. " records dropped.")
    end
    chat("Raw combat events and per-swing MH/OH are not claimed by this build; see docs/API_LIMITS.md.")
end

local function slashCommand(message)
    local command, argument = string.match(message or "", "^(%S*)%s*(.-)%s*$")
    command = string.lower(command or "")
    if command == "start" then
        startSession(argument)
    elseif command == "stop" then
        stopSession()
    elseif command == "status" or command == "" then
        showStatus()
    elseif command == "snapshot" then
        snapshot("manual")
    elseif command == "slots" then
        if string.lower(argument or "") == "auto" then
            db.settings.heroicStrikeSlots = {}
            slotsDirty = true
            discoverHeroicStrikeSlots()
            if #autoSlots > 0 then
                chat("Auto-discovery found Heroic Strike in action slot(s): " .. table.concat(autoSlots, ",") .. ".")
            else
                chat("Auto-discovery found no Heroic Strike slot. Ensure the spell, not an empty button, is on an action bar and run /fcr slots auto again.")
            end
        else
            local slots, err = parseSlotList(argument)
            if not slots then
                chat(err)
                return
            end
            db.settings.heroicStrikeSlots = slots
            chat("Configured Heroic Strike slots: " .. table.concat(slots, ",") .. ".")
            if activeSession then
                recordHSState("slot_configuration", true)
            end
        end
    else
        chat("Commands: /fcr start [label], stop, status, snapshot, slots N[,N], slots auto")
    end
end

local function initialize()
    if initialized then
        return
    end
    initialized = true
    ForeverCombatResearchDB = ForeverCombatResearchDB or {}
    db = ForeverCombatResearchDB
    db.schemaVersion = SCHEMA_VERSION
    db.settings = db.settings or {}
    db.settings.maxRecords = db.settings.maxRecords or DEFAULT_MAX_RECORDS
    db.settings.heroicStrikeSlots = db.settings.heroicStrikeSlots or {}
    db.sessions = db.sessions or {}
    db.runtime = db.runtime or {}
    db.runtime.eventRegistration = {}
    db.runtime.capabilities = buildCapabilities()

    register("PLAYER_LOGIN")
    register("PLAYER_TARGET_CHANGED")
    register("PLAYER_REGEN_DISABLED")
    register("PLAYER_REGEN_ENABLED")
    register("PLAYER_EQUIPMENT_CHANGED")
    register("UNIT_INVENTORY_CHANGED")
    register("ACTIONBAR_SLOT_CHANGED")
    register("ACTIONBAR_UPDATE_STATE")
    register("SPELL_UPDATE_USABLE")
    register("UNIT_SPELLCAST_START")
    register("UNIT_SPELLCAST_SUCCEEDED")
    register("UNIT_SPELLCAST_STOP")
    register("UNIT_SPELLCAST_INTERRUPTED")
    register("UNIT_SPELLCAST_FAILED")
    for _, event in ipairs(combatChatEvents) do
        register(event)
    end

    SLASH_FOREVERCOMBATRESEARCH1 = "/fcr"
    SlashCmdList.FOREVERCOMBATRESEARCH = slashCommand
end

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnUpdate", function(_, elapsed)
    if not activeSession then
        return
    end
    sampleElapsed = sampleElapsed + elapsed
    if sampleElapsed >= SAMPLE_INTERVAL_SECONDS then
        sampleElapsed = 0
        recordHSState("sample", false)
    end
end)

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName == addonName then
            initialize()
        end
        return
    end
    if not initialized then
        return
    end
    if event == "PLAYER_LOGIN" then
        slotsDirty = true
        discoverHeroicStrikeSlots()
    elseif event == "PLAYER_TARGET_CHANGED" then
        if activeSession then
            snapshot("target_changed")
            recordHSState("target_changed", false)
        end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        appendRecord("combat_boundary", { event = event })
        recordHSState(event, false)
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_UPDATE_STATE" or event == "SPELL_UPDATE_USABLE" then
        slotsDirty = true
        recordHSState(event, false)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "UNIT_INVENTORY_CHANGED" then
        local unit = ...
        if event == "PLAYER_EQUIPMENT_CHANGED" or unit == "player" then
            snapshot("equipment_changed")
        end
    elseif string.find(event, "^UNIT_SPELLCAST_") then
        local unit = ...
        if unit == "player" then
            appendRecord("player_spellcast", { event = event, arguments = serializeArgs(...) })
        end
    elseif string.find(event, "^CHAT_MSG_COMBAT_") then
        appendRecord("combat_chat", { event = event, arguments = serializeArgs(...) })
    end
end)
