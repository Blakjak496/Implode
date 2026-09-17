local defaults = {
	enabled = true,
	alert = true,
	sound = 2,
}

local function InitDB()
	ImplodeDB = ImplodeDB or {}
	for key, value in pairs(defaults) do
		if ImplodeDB[key] == nil then
			ImplodeDB[key] = value
		end
	end
end
InitDB()

-- UTILS --
local LibButtonGlow = LibStub("LibButtonGlow-1.0")

local function ShowGlow(overlay)
	LibButtonGlow.ShowOverlayGlow(overlay)
end

local function HideGlow(overlay)
	LibButtonGlow.HideOverlayGlow(overlay)
end

local DEMONOLOGY_SPEC_ID = 266

local function IsDemonologySpecActive()
	if not GetSpecialization or not GetSpecializationInfo then return false end
	local specIndex = GetSpecialization()
	if not specIndex then return false end
	return GetSpecializationInfo(specIndex) == DEMONOLOGY_SPEC_ID
end

-- SETTINGS --
local SOUND_CHOICES = {
	{ id = 1, name = "Summon Imp", kit = 6096 },
	{ id = 2, name = "Ship Bell Chime", kit = 320443 },
	{ id = 3, name = "Horde Bell Toll", kit = 6595 },
}

local function GetSoundOptions()
	local container = Settings.CreateControlTextContainer()
	for _, choice in ipairs(SOUND_CHOICES) do
		container:Add(choice.id, choice.name)
	end
	return container:GetData()
end

local function GetSound()
	for _, choice in ipairs(SOUND_CHOICES) do
		if choice.id == ImplodeDB.sound then return choice end
	end
	return SOUND_CHOICES[1]
end

local function PlayReadySound()
	if not ImplodeDB.alert then return end
	PlaySound(GetSound().kit, "Master")
end

local category = Settings.RegisterVerticalLayoutCategory("Implode")
Settings.RegisterAddOnCategory(category)

local enabledSetting = Settings.RegisterAddOnSetting(category, "ImplodeEnabled", "enabled", ImplodeDB, "boolean", "Enabled", ImplodeDB.enabled)
Settings.CreateCheckbox(category, enabledSetting, "Enable")
enabledSetting:SetValueChangedCallback(function(setting, value)
	ImplodeDB.enabled = value
end)

local alertSetting = Settings.RegisterAddOnSetting(category, "ImplodeAlert", "alert", ImplodeDB, "boolean", "Alerts", ImplodeDB.alert)
Settings.CreateCheckbox(category, alertSetting, "Enable")
alertSetting:SetValueChangedCallback(function(setting, value)
	ImplodeDB.alert = value
end)

local soundSetting = Settings.RegisterAddOnSetting(category, "ImplodeSound", "sound", ImplodeDB, "number", "Alert Sound", ImplodeDB.sound)
Settings.CreateDropdown(category, soundSetting, GetSoundOptions, "Select an alert sound")
soundSetting:SetValueChangedCallback(function(setting, value)
	ImplodeDB.sound = value
	PlayReadySound()
end)

-- CONFIG --

local IMPLOSION_SPELL_ID = 196277
local HAND_OF_GULDAN_SPELL_ID = 105174
local RUINATION_SPELL_ID = 434635
local TO_HELL_AND_BACK_TALENT_ID = 1281511
local IMP_THRESHOLD = 6
local IMPS_PER_HAND_OF_GULDAN = 3
local IMPS_REMOVED_PER_IMPLOSION = 6

local FEL_FIREBOLT_CAST_TIME = 2.0
local CASTS_PER_IMP = 6
local LIFESPAN_CAP = 40

local IMPLOSION_COOLDOWN = 15

-- HASTE CACHE --
local hasteMultiplier = 1.0
local function RefreshCachedHaste()
	if InCombatLockdown() or UnitAffectingCombat("player") then return end
	local ok, h = pcall(GetHaste)
	if ok and h and not issecretvalue(h) then
		hasteMultiplier = 1 + (h / 100)
	end
end



-- SPAWN STATE --
local activeGroups = {}
local nextImplosionReadyAt = 0
local lastTick = nil
local IMP_SPAWN_STAGGER = 0.3

local function HasToHellAndBack()
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		return C_SpellBook.IsSpellKnown(TO_HELL_AND_BACK_TALENT_ID)
	end
	if IsPlayerSpell then return IsPlayerSpell(TO_HELL_AND_BACK_TALENT_ID) end
	return false
end

local function AddImps(count, now, lifespanCap)
	if count <= 0 then return end
	local baseTime = now or GetTime()
	for i = 1, count do
		table.insert(activeGroups, {
			count = 1,
			spawnedAt = baseTime + (i - 1) * IMP_SPAWN_STAGGER,
			completedCasts = 0,
			castProgress = 0,
			lifespanCap = lifespanCap or LIFESPAN_CAP
		})
	end
end

local function AdvanceDecay(now)
	if not lastTick then
		lastTick = now
		return
	end
	local dt = now - lastTick
	lastTick = now
	if dt <= 0 then return end
	
	local inCombat = UnitAffectingCombat("player")
	
	for i = #activeGroups, 1, -1 do
		local group = activeGroups[i]
		if inCombat then
			group.castProgress = group.castProgress + (dt * hasteMultiplier)
			while group.castProgress >= FEL_FIREBOLT_CAST_TIME do
				group.castProgress = group.castProgress - FEL_FIREBOLT_CAST_TIME
				group.completedCasts = group.completedCasts + 1
			end
		end
		local finishedCasts = group.completedCasts >= CASTS_PER_IMP
		local groupExpired = (now - group.spawnedAt) >= (group.lifespanCap or LIFESPAN_CAP)
		if finishedCasts or groupExpired then
			table.remove(activeGroups, i)
		end
	end
end

local function GetImpCount(now)
	AdvanceDecay(now or GetTime())
	local total = 0
	for i = 1, #activeGroups do
		total = total + activeGroups[i].count
	end
	return total
end

local function Implode(now)
	local removed = 0
	for i = #activeGroups, 1, -1 do
		local group = activeGroups[i]
		if removed >= IMPS_REMOVED_PER_IMPLOSION then break end
		local toRemove = math.min(IMPS_REMOVED_PER_IMPLOSION - removed, group.count)
		group.count = group.count - toRemove
		removed = removed + toRemove
		if group.count <= 0 then table.remove(activeGroups, i) end
	end
	if removed > 0 and HasToHellAndBack() then
		AddImps(math.floor(removed / 2), now)
	end
	nextImplosionReadyAt = now + IMPLOSION_COOLDOWN
end

-- INNER DEMONS --
local INNER_DEMONS_SPELL_ID = 267216
local INNER_DEMONS_INTERVAL = 12
local INNER_DEMONS_LIFESPAN_CAP = 20
local nextInnerDemonsSummonAt = nil
local innerDemonsTicker = nil

local function HasInnerDemons()
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		return C_SpellBook.IsSpellKnown(INNER_DEMONS_SPELL_ID)
	end
	if IsPlayerSpell then return IsPlayerSpell(INNER_DEMONS_SPELL_ID) end
	return false
end


local function ProcessInnerDemons(now)
	if not nextInnerDemonsSummonAt then return end
	while now >= nextInnerDemonsSummonAt do
		AddImps(1, nextInnerDemonsSummonAt, INNER_DEMONS_LIFESPAN_CAP)
		nextInnerDemonsSummonAt = nextInnerDemonsSummonAt + INNER_DEMONS_INTERVAL
	end
end

local function StartInnerDemonsTicker(now)
	if innerDemonsTicker then return end
	nextInnerDemonsSummonAt = now + INNER_DEMONS_INTERVAL
	innerDemonsTicker = C_Timer.NewTicker(INNER_DEMONS_INTERVAL, function()
		ProcessInnerDemons(GetTime())
	end)
end

local function StopInnerDemonsTicker()
	if innerDemonsTicker then
		innerDemonsTicker:Cancel()
		innerDemonsTicker = nil
	end
	nextInnerDemonsSummonAt = nil
end

local function EstablishInnerDemonsProcess()
	if IsDemonologySpecActive() and HasInnerDemons() then
		StartInnerDemonsTicker(GetTime())
	else
		StopInnerDemonsTicker()
	end
end

-- OVERLAY --
local overlayFrame

local function GetImplosionFrame()
	if not EssentialCooldownViewer or not EssentialCooldownViewer.GetItemFrames then
		return nil
	end
	for _, itemFrame in ipairs(EssentialCooldownViewer:GetItemFrames()) do
		local ok, spellID = pcall(itemFrame.GetSpellID, itemFrame)
		if ok and spellID == IMPLOSION_SPELL_ID then
			return itemFrame
		end
	end
	return nil
end

local function EnsureOverlayExists()
	local itemFrame = GetImplosionFrame()
	if not itemFrame then
		if overlayFrame then overlayFrame:Hide() end
		return nil
	end
	if not overlayFrame then
		overlayFrame = CreateFrame("Frame", "ImplodeHighlightOverlay", itemFrame)
	end
	if overlayFrame:GetParent() ~= itemFrame then
		overlayFrame:SetParent(itemFrame)
	end
	local anchor = itemFrame.Icon or itemFrame
	overlayFrame:ClearAllPoints()
	overlayFrame:SetAllPoints(anchor)
	return overlayFrame
end

local wasReady = false


local ACTION_BAR_PREFIXES = {
	"ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
	"MultiBarRightButton", "MultiBarLeftButton", "MultiBar5Button",
	"MultiBar6Button", "MultiBar7Button",
}

local actionButtonOverlays = {}
local implosionActionButtons = {}

local function GetImplosionActionButtons()
	local matches = {}
	for _, prefix in ipairs(ACTION_BAR_PREFIXES) do
		for i = 1, 12 do
			local button = _G[prefix .. i]
			if button then
				local actionSlot = button.action
				if actionSlot then
					local actionType, id = GetActionInfo(actionSlot)
					if actionType == "spell" and id == IMPLOSION_SPELL_ID then
						table.insert(matches, button)
					end
				end
			end
		end
	end
	return matches
end

local function UpdateActionButtonGlows(ready)
	local stillActive = {}

	for _, button in ipairs(implosionActionButtons) do
		stillActive[button] = true
		if ready then
			LibButtonGlow.ShowOverlayGlow(button)
		else
			LibButtonGlow.HideOverlayGlow(button)
		end
	end

	for button in pairs(actionButtonOverlays) do
		if not stillActive[button] then
			LibButtonGlow.HideOverlayGlow(button)
			actionButtonOverlays[button] = nil
		end
	end
	for button in pairs(stillActive) do
		actionButtonOverlays[button] = true
	end
end

local function DiscardPartialCastProgress()
	for i = 1, #activeGroups do
		activeGroups[i].castProgress = 0
	end
end

-- RESYNC --

local WILD_IMP_SPELL_ID = 296553
local RESYNC_MIN_PROGRESS_FRACTION = 0.3
local RESYNC_MAX_PROGRESS_FRACTION = 0.8

local function IsPoolPureInnerDemons()
	if #activeGroups == 0 then
		return false
	end
	for i = 1, #activeGroups do
		if activeGroups[i].lifespanCap ~= INNER_DEMONS_LIFESPAN_CAP then
			return false
		end
	end
	return true
end

local function GetRealWildImpCount()
	if InCombatLockdown() or UnitAffectingCombat("player") then
		return nil
	end
	local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, WILD_IMP_SPELL_ID)
	if not ok then
		return nil
	end

	if not aura then
		return 0
	end

	if issecretvalue(aura.applications) then
		return nil
	end

	return aura.applications
end

local function GetGroupRemaining(group, now)
	local castsLeft = CASTS_PER_IMP - group.completedCasts
	local combatRemaining = (castsLeft * FEL_FIREBOLT_CAST_TIME) - group.castProgress
	local lifespanRemaining = (group.lifespanCap or LIFESPAN_CAP) - (now - group.spawnedAt)
	return math.min(combatRemaining, lifespanRemaining)
end

local function ResyncFromRealAura(now, bypassInnerDemonsGate)
	if IsPoolPureInnerDemons() and not bypassInnerDemonsGate then return end

	local real = GetRealWildImpCount()
	if not real then return end

	local estimated = GetImpCount(now)
	if real == estimated then return end

	if real == 0 then
		wipe(activeGroups)
		return
	end

	if real > estimated then
		local deficit = real - estimated
		for i = 1, deficit do
			local fraction = RESYNC_MIN_PROGRESS_FRACTION + math.random() * (RESYNC_MAX_PROGRESS_FRACTION - RESYNC_MIN_PROGRESS_FRACTION)
			local assumedCasts = math.floor(CASTS_PER_IMP * fraction)
			table.insert(activeGroups, {
				count = 1,
				spawnedAt = now,
				completedCasts = assumedCasts,
				castProgress = 0,
				lifespanCap = LIFESPAN_CAP,
			})
		end
		return
	end

	
	local order = {}
	for i = 1, #activeGroups do order[i] = i end
	table.sort(order, function(a,b)
		return GetGroupRemaining(activeGroups[a], now) < GetGroupRemaining(activeGroups[b], now)
	end)
	local difference = estimated - real
	for _, idx in ipairs(order) do
		if difference <= 0 then break end
		local group = activeGroups[idx]
		local toRemove = math.min(difference, group.count)
		group.count = group.count - toRemove
		difference = difference - toRemove
	end

	for i = #activeGroups, 1, -1 do
		if activeGroups[i].count <= 0 then
			table.remove(activeGroups, i)
		end
	end
end

-- UPDATE --

local function UpdateHighlight()
	local overlay = EnsureOverlayExists()

	if not ImplodeDB.enabled or not overlay then
		if overlay then HideGlow(overlay) end
		wasReady = false
		return
	end

	local now = GetTime()
	local ready = GetImpCount(now) >= IMP_THRESHOLD and now >= nextImplosionReadyAt

	if not overlay then return end

	if ready then
		ShowGlow(overlay)
		UpdateActionButtonGlows(ready)
		if not wasReady then
			PlayReadySound()
		end
	else
		HideGlow(overlay)
		UpdateActionButtonGlows(ready)
	end
	wasReady = ready
end

-- TICKERS --

local ticker
local shutdownTicker

local function GetActiveGroupCount()
	local activeGroupCount = 0
	for _ in pairs(activeGroups) do
		activeGroupCount = activeGroupCount + 1
	end
	return activeGroupCount
end

-- EVENTS --
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
eventFrame:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
eventFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

local function IsActionbarEvent(event)
	return event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED" or event == "UPDATE_BONUS_ACTIONBAR"
end

eventFrame:SetScript("OnEvent", function(self, event, unit, castGUID, spellID)
	if event == "PLAYER_ENTERING_WORLD" then
		InitDB()
		RefreshCachedHaste()
		ResyncFromRealAura(GetTime(), true)
		EstablishInnerDemonsProcess()
		if EssentialCooldownViewer and not EssentialCooldownViewer.ImplodeHighlightHooked then
			EssentialCooldownViewer.ImplodeHighlightHooked = true
			hooksecurefunc(EssentialCooldownViewer, "Layout", function()
				overlayFrame = nil
				UpdateHighlight()
			end)
		end
		UpdateHighlight()
		return
	end

	if event == "PLAYER_REGEN_ENABLED" or (event == "PLAYER_SPECIALIZATION_CHANGED" and unit == "player") then
		RefreshCachedHaste()
	end

	if event == "PLAYER_SPECIALIZATION_CHANGED" and unit == "player" then
		wipe(activeGroups)
		EstablishInnerDemonsProcess()
	end

	if event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_PAGE_CHANGED" or event == "UPDATE_BONUS_ACTIONBAR" or event == "PLAYER_SPECIALIZATION_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
		implosionActionButtons = GetImplosionActionButtons()
	end

	if event == "PLAYER_REGEN_DISABLED" then
		if shutdownTicker then
			shutdownTicker:Cancel()
			shutdownTicker = nil
		end
		if not ticker then
			ticker = C_Timer.NewTicker(0.3, UpdateHighlight)
		end
		UpdateHighlight()
	end

	if event == "PLAYER_REGEN_ENABLED" then
		DiscardPartialCastProgress()
		ResyncFromRealAura(GetTime(), false)
		if not shutdownTicker then
			shutdownTicker = C_Timer.NewTicker(0.3, function()
				local groupsStillActive = GetActiveGroupCount()
				if groupsStillActive <= 0 then 
					ticker:Cancel()
					ticker = nil
					shutdownTicker:Cancel()
					shutdownTicker = nil
					lastTick = nil
					UpdateHighlight()
				end
			end)
		end
	end


	if unit and unit ~= "player" and not IsActionbarEvent(event) then return end
	local now = GetTime()

	if spellID == HAND_OF_GULDAN_SPELL_ID or spellID == RUINATION_SPELL_ID then
		AddImps(IMPS_PER_HAND_OF_GULDAN, now)
	elseif spellID == IMPLOSION_SPELL_ID then
		Implode(now)
	end
	UpdateHighlight()
end)