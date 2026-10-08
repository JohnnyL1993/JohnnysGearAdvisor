-- Plain CreateFrame-based UI (no AceGUI). AceGUI's widget/layout system was
-- causing the panel to hang the whole client on open, so the panel here is built
-- directly from stock Blizzard frame templates instead (same approach the
-- bundled GearPlanner addon uses successfully on this client).
JohnnysGearAdvisor.UI = {}
local UI = JohnnysGearAdvisor.UI
local SpecDetect = JohnnysGearAdvisor.SpecDetect
local StatWeights = JohnnysGearAdvisor.StatWeights
local Scoring = JohnnysGearAdvisor.Scoring
local Scanner = JohnnysGearAdvisor.Scanner

local SLOT_LABELS = {
	HeadSlot = "Head", NeckSlot = "Neck", ShoulderSlot = "Shoulder", BackSlot = "Back",
	ChestSlot = "Chest", WristSlot = "Wrist", HandsSlot = "Hands", WaistSlot = "Waist",
	LegsSlot = "Legs", FeetSlot = "Feet", Finger0Slot = "Ring 1", Finger1Slot = "Ring 2",
	Trinket0Slot = "Trinket 1", Trinket1Slot = "Trinket 2", MainHandSlot = "Main Hand",
	SecondaryHandSlot = "Off Hand", RangedSlot = "Ranged",
}

-- Tracking-list filter categories. The two ring/trinket physical slots are
-- collapsed into one category each, since you don't usually care which ring
-- slot a tracked item would go in, just that it's a ring.
local FILTER_CATEGORIES = {
	"Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist",
	"Legs", "Feet", "Rings", "Trinkets", "Main Hand", "Off Hand", "Ranged",
}

local function FilterCategoryForSlot(slotName)
	if slotName == "Finger0Slot" or slotName == "Finger1Slot" then
		return "Rings"
	elseif slotName == "Trinket0Slot" or slotName == "Trinket1Slot" then
		return "Trinkets"
	end
	return SLOT_LABELS[slotName] or slotName
end

local mainFrame, capLabel, candidatesHeading, candidatesScroll, candidatesContent, totalsLabel, trackingScroll, trackingContent
local suppressionRow, suppressionValueText
local slotButtons = {}
local candidateRows = {}
local trackingRows = {}
local filterButtons = {}
local specTabButtons = {}
local selectedSlot
local trackingFilter -- nil/false = show all
local previewSpecKey -- nil = follow the character's actual active talent spec

-- 3.3.5a has no "item info received" event, so uncached items (names/icons still
-- showing as placeholders) are retried with a one-shot delayed refresh instead.
local retryTicker = CreateFrame("Frame")
retryTicker:Hide()
local retryElapsed = 0
retryTicker:SetScript("OnUpdate", function(self, elapsed)
	retryElapsed = retryElapsed + elapsed
	if retryElapsed >= 1 then
		retryElapsed = 0
		self:Hide()
		UI:RefreshOpenCandidates()
	end
end)

local function ScheduleRefresh()
	retryElapsed = 0
	retryTicker:Show()
end

-- Returns (classFile, specKey, specName, role) - normally your actual active
-- talent spec, but overridden by SetPreviewSpec so you can preview
-- recommendations for a spec you aren't currently talented into.
local function GetSpec()
	local classFile, activeKey, activeName, activeRole = SpecDetect:GetActiveSpec()
	if not previewSpecKey or previewSpecKey == activeKey then
		return classFile, activeKey, activeName, activeRole
	end
	for _, archetype in ipairs(SpecDetect:GetArchetypesForClass(classFile)) do
		if archetype.key == previewSpecKey then
			return classFile, archetype.key, archetype.name, archetype.role
		end
	end
	return classFile, activeKey, activeName, activeRole
end

local function FormatDelta(delta)
	if delta > 0.5 then
		return "|cff40ff40+" .. string.format("%.1f", delta) .. "|r"
	elseif delta < -0.5 then
		return "|cffff4040" .. string.format("%.1f", delta) .. "|r"
	end
	return "|cffaaaaaa~" .. string.format("%.1f", delta) .. "|r"
end

-- Only vendor/token-purchased items carry a `cost` (see ItemDB.lua); boss drops
-- and reputation rewards have none, so there's nothing to display for those.
local function FormatCost(cost)
	if not cost then
		return ""
	end
	local text = string.format("%d %s Emblem%s", cost.amount, cost.currency, cost.amount == 1 and "" or "s")
	if cost.extra then
		text = text .. " + " .. cost.extra
	end
	return "\n|cffffd200" .. text .. "|r"
end

local function TrackingList()
	return JohnnysGearAdvisor.db.profile.trackingList
end

local function IsTracked(itemId, slotName)
	for _, entry in ipairs(TrackingList()) do
		if entry.itemId == itemId and entry.slot == slotName then
			return true
		end
	end
	return false
end

function UI:AddToTracking(itemId, slotName, source, cost)
	if IsTracked(itemId, slotName) then
		return
	end
	table.insert(TrackingList(), { itemId = itemId, slot = slotName, source = source, cost = cost })
	self:RefreshTracking()
end

function UI:RemoveFromTracking(index)
	table.remove(TrackingList(), index)
	self:RefreshTracking()
end

-- Demonology/Destruction can't read Suppression's rank live off the Affliction
-- tab the way Affliction itself does (see StatWeights.lua's "manual" reduction
-- source), so this shows a stepper for the player to set it themselves. Hidden
-- for every other spec/class, which keeps their automatic detection untouched.
local function RefreshSuppressionRow(specKey)
	if specKey ~= "Demonology" and specKey ~= "Destruction" then
		suppressionRow:Hide()
		return
	end
	suppressionRow:Show()
	suppressionValueText:SetText(tostring(JohnnysGearAdvisor.db.profile.suppressionPoints or 0))
end

-- Hidden entirely (blank text) for healer-role specs, since heals can't miss.
local function RefreshCapLabel()
	local classFile, specKey, specName, role = GetSpec()
	if not specKey then
		capLabel:SetText("Unrecognized class/spec.")
		suppressionRow:Hide()
		return
	end
	if not StatWeights:GetForSpec(specKey) then
		capLabel:SetText(specName .. " (" .. role .. "): no item database yet for this spec.")
		suppressionRow:Hide()
		return
	end

	RefreshSuppressionRow(specKey)

	local capInfo = StatWeights:GetHitCapInfo(specKey)
	if not capInfo then
		capLabel:SetText(specName .. " (" .. role .. ") - hit cap not applicable.")
		return
	end

	local current = StatWeights:GetCurrentHitPercent(capInfo.ratingType)
	local remaining = capInfo.capPercent - current
	local status
	if remaining < -0.05 then
		status = "|cffff4040" .. string.format("%.1f%% OVER cap", -remaining) .. "|r"
	elseif remaining < 0.05 then
		status = "|cff40ff40at cap|r"
	else
		status = "|cffffff40" .. string.format("%.1f%% below cap", remaining) .. "|r"
	end
	capLabel:SetText(string.format("%s - Hit: %.1f%% / %.1f%% cap (%s)", specName, current, capInfo.capPercent, status))
end

local function CreateItemRow(parent, withCheckbox)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(560, 46)
	row:EnableMouse(true)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(28, 28)
	row.icon:SetPoint("LEFT", 2, 0)

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.text:SetJustifyH("LEFT")
	row.text:SetWidth(withCheckbox and 380 or 460)

	if withCheckbox then
		row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		row.check:SetSize(24, 24)
		row.check:SetPoint("RIGHT", -4, 0)
	else
		row.remove = JohnnysGearAdvisor.Skin:CreateButton(row, 70, 22, "Remove")
		row.remove:SetPoint("RIGHT", -4, 0)
	end

	row:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if self.itemLink then
			GameTooltip:SetHyperlink(self.itemLink)
		else
			GameTooltip:SetText("Loading item...")
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	return row
end

local function LayoutRows(rows, parent, yStart, rowHeight)
	for i, row in ipairs(rows) do
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, yStart - (i - 1) * rowHeight)
	end
end

function UI:ShowCandidatesForSlot(slotName)
	selectedSlot = slotName
	candidatesHeading:SetText("|cffffd200" .. (SLOT_LABELS[slotName] or slotName) .. " - candidates|r")

	local classFile, specKey = GetSpec()
	local equippedScore, allCandidates, pendingCount = Scoring:GetUpgradesForSlot(slotName, specKey)

	for _, row in ipairs(candidateRows) do
		row:Hide()
	end

	if not equippedScore then
		candidatesHeading:SetText("|cffffd200" .. (SLOT_LABELS[slotName] or slotName) .. "|r - no item database yet for this spec.")
		candidatesContent:SetHeight(20)
		return
	end

	if pendingCount and pendingCount > 0 then
		ScheduleRefresh()
	end

	-- Show every candidate in the database for this slot/class, upgrade or not -
	-- deltas are only as good as the stat-weight model behind them, so a downgrade
	-- or wash is left visible (in red/grey via FormatDelta) rather than hidden,
	-- in case the score for a genuine upgrade is being computed wrong.
	local candidates = allCandidates

	if #candidates == 0 then
		if pendingCount and pendingCount > 0 then
			candidatesHeading:SetText("|cffffd200" .. (SLOT_LABELS[slotName] or slotName) .. "|r - no cached candidates yet, one moment...")
		else
			-- Weapon slots in particular can have zero candidates at all for a
			-- class we haven't curated weapons for.
			candidatesHeading:SetText("|cffffd200" .. (SLOT_LABELS[slotName] or slotName) .. "|r - no candidates in the database yet for this slot/class.")
		end
		candidatesContent:SetHeight(20)
		return
	end

	for i, cand in ipairs(candidates) do
		local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(cand.itemId)
		if not name then
			ScheduleRefresh()
		end

		local row = candidateRows[i]
		if not row then
			row = CreateItemRow(candidatesContent, true)
			candidateRows[i] = row
		end

		row.itemLink = link
		row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		row.text:SetText(string.format("%s  %s\n|cff888888%s|r%s", name or ("Item #" .. cand.itemId), FormatDelta(cand.delta), cand.source, FormatCost(cand.cost)))
		row.check:SetChecked(IsTracked(cand.itemId, slotName))
		row.check:SetScript("OnClick", function(self)
			if self:GetChecked() then
				UI:AddToTracking(cand.itemId, slotName, cand.source, cand.cost)
			else
				for idx, entry in ipairs(TrackingList()) do
					if entry.itemId == cand.itemId and entry.slot == slotName then
						UI:RemoveFromTracking(idx)
						break
					end
				end
			end
		end)
		row:Show()
	end

	LayoutRows(candidateRows, candidatesContent, -2, 48)
	candidatesContent:SetHeight(math.max(20, #candidates * 48 + 4))
end

-- Sums each tracked item's emblem cost by currency (Frost/Triumph), plus a count
-- of any non-numeric "extra" requirement (e.g. Trophy of the Crusade tokens).
-- Items with no `cost` (boss drops, reputation rewards) simply don't contribute.
local function BuildTotalsText(list)
	local totals, extras, hasAny = {}, {}, false
	for _, entry in ipairs(list) do
		if entry.cost then
			hasAny = true
			totals[entry.cost.currency] = (totals[entry.cost.currency] or 0) + entry.cost.amount
			if entry.cost.extra then
				extras[entry.cost.extra] = (extras[entry.cost.extra] or 0) + 1
			end
		end
	end

	if not hasAny then
		return "No emblem cost among tracked items yet."
	end

	local parts = {}
	for currency, amount in pairs(totals) do
		table.insert(parts, string.format("%d %s Emblems", amount, currency))
	end
	for extra, count in pairs(extras) do
		table.insert(parts, string.format("%dx %s", count, extra))
	end
	table.sort(parts)
	return "|cffffd200Total cost: " .. table.concat(parts, "  +  ") .. "|r"
end

-- Rows show the tracking list filtered to `trackingFilter` (a FILTER_CATEGORIES
-- value, or nil for "show everything"). row.trackIndex always points at the
-- entry's real position in the full (unfiltered) tracking list, so Remove still
-- deletes the right item regardless of what's currently filtered out of view.
function UI:RefreshTracking()
	local list = TrackingList()
	totalsLabel:SetText(BuildTotalsText(list))

	for _, row in ipairs(trackingRows) do
		row:Hide()
	end

	local shown = {}
	for i, entry in ipairs(list) do
		if not trackingFilter or FilterCategoryForSlot(entry.slot) == trackingFilter then
			local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(entry.itemId)
			if not name then
				ScheduleRefresh()
			end

			local row = trackingRows[#shown + 1]
			if not row then
				row = CreateItemRow(trackingContent, false)
				row.remove:SetScript("OnClick", function()
					UI:RemoveFromTracking(row.trackIndex)
				end)
				trackingRows[#shown + 1] = row
			end

			row.trackIndex = i
			row.itemLink = link
			row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			row.text:SetText(string.format("%s\n|cff888888%s - %s|r%s", name or ("Item #" .. entry.itemId), SLOT_LABELS[entry.slot] or entry.slot, entry.source, FormatCost(entry.cost)))
			row:Show()
			table.insert(shown, row)
		end
	end

	if #shown == 0 then
		trackingContent:SetHeight(20)
		return
	end

	LayoutRows(shown, trackingContent, -2, 48)
	trackingContent:SetHeight(#shown * 48 + 4)
end

function UI:SetTrackingFilter(category)
	trackingFilter = category
	for cat, btn in pairs(filterButtons) do
		if cat == (category or "All") then
			btn:LockHighlight()
		else
			btn:UnlockHighlight()
		end
	end
	self:RefreshTracking()
end

function UI:SetPreviewSpec(specKey)
	local classFile, activeKey = SpecDetect:GetActiveSpec()
	previewSpecKey = (specKey == activeKey) and nil or specKey

	local highlightKey = previewSpecKey or activeKey
	for key, btn in pairs(specTabButtons) do
		if key == highlightKey then
			btn:LockHighlight()
		else
			btn:UnlockHighlight()
		end
	end

	RefreshCapLabel()
	if selectedSlot then
		self:ShowCandidatesForSlot(selectedSlot)
	end
end

function UI:RefreshOpenCandidates()
	if mainFrame and mainFrame:IsShown() and selectedSlot then
		self:ShowCandidatesForSlot(selectedSlot)
	end
	if mainFrame and mainFrame:IsShown() then
		self:RefreshTracking()
	end
end

function UI:OnSpecChanged()
	-- An actual in-game respec supersedes whatever spec tab was being previewed.
	previewSpecKey = nil
	local _, activeKey = SpecDetect:GetActiveSpec()
	for key, btn in pairs(specTabButtons) do
		if key == activeKey then
			btn:LockHighlight()
		else
			btn:UnlockHighlight()
		end
	end

	if mainFrame and mainFrame:IsShown() then
		RefreshCapLabel()
		if selectedSlot then
			self:ShowCandidatesForSlot(selectedSlot)
		end
	end
end

local function BuildFrame()
	mainFrame = CreateFrame("Frame", "GearAdvisorFrame", UIParent)
	mainFrame:SetSize(620, 1000)
	mainFrame:SetPoint("RIGHT", UIParent, "RIGHT", -20, 0)
	mainFrame:SetFrameStrata("DIALOG")
	mainFrame:SetMovable(true)
	mainFrame:EnableMouse(true)
	mainFrame:RegisterForDrag("LeftButton")
	mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
	mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
	JohnnysGearAdvisor.Skin:StylePanel(mainFrame, 0.92)
	mainFrame:Hide()

	-- Per-window scale/opacity (see Modules\WindowSettings.lua). Guarded so a
	-- stale .toc (client not fully restarted after the file was added) just
	-- skips the feature instead of erroring the whole window.
	if JohnnysGearAdvisor.WindowSettings then
		JohnnysGearAdvisor.WindowSettings:Register(mainFrame, "main", "Gear Advisor")
	end

	local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("Gear Advisor - Gear Upgrade")

	local close = JohnnysGearAdvisor.Skin:CreateButton(mainFrame, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() UI:Toggle() end)

	JohnnysGearAdvisor.VersionCheck:AttachNotice(mainFrame)

	if JohnnysGearAdvisor.WindowSettings then
		JohnnysGearAdvisor.WindowSettings:AttachButton(mainFrame)
	end

	-- Spec-preview tabs: one per spec archetype the class has (e.g. all three for
	-- Rogue, Affliction/Demonology/Destruction for Warlock), even if some don't
	-- have a real item database yet - clicking one of those just shows "no item
	-- database yet for this spec" rather than being unavailable. Lets you preview
	-- another spec's recommendations without actually respeccing. Hit-cap numbers
	-- still reflect your real, currently active talents/gear since we can't know
	-- hypothetical talent choices for a spec you're not actually in.
	local classFile = (SpecDetect:GetActiveSpec())
	local archetypes = SpecDetect:GetArchetypesForClass(classFile)
	if #archetypes > 1 then
		local tabX = 20
		for _, archetype in ipairs(archetypes) do
			local btn = JohnnysGearAdvisor.Skin:CreateButton(mainFrame, 100, 20, archetype.name)
			btn:SetPoint("TOPLEFT", tabX, -38)
			if not StatWeights:GetForSpec(archetype.key) then
				btn.text:SetTextColor(0.5, 0.5, 0.5)
			end
			btn:SetScript("OnClick", function() UI:SetPreviewSpec(archetype.key) end)
			specTabButtons[archetype.key] = btn
			tabX = tabX + 102
		end
		local _, activeKey = SpecDetect:GetActiveSpec()
		if specTabButtons[activeKey] then
			specTabButtons[activeKey]:LockHighlight()
		end
	end

	capLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	capLabel:SetPoint("TOP", 0, -62)

	-- Manual Suppression-points stepper for Demonology/Destruction (see
	-- RefreshSuppressionRow); hidden for every other spec.
	suppressionRow = CreateFrame("Frame", nil, mainFrame)
	suppressionRow:SetSize(230, 20)
	suppressionRow:SetPoint("TOP", 0, -84)

	local suppressionLabel = suppressionRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	suppressionLabel:SetPoint("LEFT", 0, 0)
	suppressionLabel:SetText("Suppression points:")

	local suppressionMinus = JohnnysGearAdvisor.Skin:CreateButton(suppressionRow, 20, 20, "-")
	suppressionMinus:SetPoint("LEFT", suppressionLabel, "RIGHT", 8, 0)
	suppressionMinus:SetScript("OnClick", function()
		local points = JohnnysGearAdvisor.db.profile.suppressionPoints or 0
		JohnnysGearAdvisor.db.profile.suppressionPoints = math.max(0, points - 1)
		RefreshCapLabel()
	end)

	suppressionValueText = suppressionRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	suppressionValueText:SetPoint("LEFT", suppressionMinus, "RIGHT", 8, 0)
	suppressionValueText:SetWidth(14)
	suppressionValueText:SetJustifyH("CENTER")

	local suppressionPlus = JohnnysGearAdvisor.Skin:CreateButton(suppressionRow, 20, 20, "+")
	suppressionPlus:SetPoint("LEFT", suppressionValueText, "RIGHT", 8, 0)
	suppressionPlus:SetScript("OnClick", function()
		local points = JohnnysGearAdvisor.db.profile.suppressionPoints or 0
		JohnnysGearAdvisor.db.profile.suppressionPoints = math.min(2, points + 1)
		RefreshCapLabel()
	end)

	local slotsLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	slotsLabel:SetPoint("TOPLEFT", 20, -106)
	slotsLabel:SetTextColor(1, 1, 1)
	slotsLabel:SetText("Equipped Gear (click a slot):")

	-- 6 columns (not 9) at an 80px pitch - labels like "Main Hand"/"Off Hand" are
	-- wider than the 36px icon, so packing 9 columns into the frame's width left
	-- no room between them and adjacent labels ran into each other. Row height
	-- (58) leaves room for the icon (36) plus its label below with breathing
	-- room on both sides.
	local COLUMNS = 6
	for i, slotName in ipairs(Scanner.SLOT_NAMES) do
		local col = (i - 1) % COLUMNS
		local row = math.floor((i - 1) / COLUMNS)

		local btn = CreateFrame("Button", nil, mainFrame)
		btn:SetSize(36, 36)
		btn:SetPoint("TOPLEFT", 20 + col * 80, -124 - row * 58)

		btn.icon = btn:CreateTexture(nil, "ARTWORK")
		btn.icon:SetAllPoints()
		btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

		btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		btn.label:SetPoint("TOP", btn, "BOTTOM", 0, -4)
		btn.label:SetTextColor(1, 1, 1)
		btn.label:SetText(SLOT_LABELS[slotName])

		btn:SetScript("OnEnter", function(self)
			local slotId = GetInventorySlotInfo(slotName)
			local link = GetInventoryItemLink("player", slotId)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if link then
				GameTooltip:SetHyperlink(link)
			else
				GameTooltip:SetText(SLOT_LABELS[slotName] .. " (empty)")
			end
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		btn:SetScript("OnClick", function() UI:ShowCandidatesForSlot(slotName) end)

		slotButtons[slotName] = btn
	end

	candidatesHeading = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	candidatesHeading:SetPoint("TOPLEFT", 20, -296)
	candidatesHeading:SetText("Click a gear slot above to see upgrade candidates.")

	candidatesScroll = CreateFrame("ScrollFrame", "GearAdvisorCandidatesScroll", mainFrame, "UIPanelScrollFrameTemplate")
	candidatesScroll:SetPoint("TOPLEFT", 20, -316)
	candidatesScroll:SetSize(560, 220)

	candidatesContent = CreateFrame("Frame", nil, candidatesScroll)
	candidatesContent:SetSize(560, 20)
	candidatesScroll:SetScrollChild(candidatesContent)

	local trackingLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	trackingLabel:SetPoint("TOPLEFT", 20, -554)
	trackingLabel:SetText("|cffffd200Tracking List|r")

	totalsLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	totalsLabel:SetPoint("TOPLEFT", 20, -572)
	totalsLabel:SetPoint("TOPRIGHT", -20, -572)
	totalsLabel:SetJustifyH("LEFT")

	-- Filter buttons: "All" plus one per slot category, to narrow the tracking
	-- list down (e.g. just Head, just Rings) without losing the rest.
	local FILTER_COLUMNS = 8
	local filterNames = { "All" }
	for _, cat in ipairs(FILTER_CATEGORIES) do
		table.insert(filterNames, cat)
	end
	for i, name in ipairs(filterNames) do
		local col = (i - 1) % FILTER_COLUMNS
		local row = math.floor((i - 1) / FILTER_COLUMNS)
		local btn = JohnnysGearAdvisor.Skin:CreateButton(mainFrame, 68, 20, name)
		btn:SetPoint("TOPLEFT", 20 + col * 70, -592 - row * 22)
		btn:SetScript("OnClick", function() UI:SetTrackingFilter(name == "All" and nil or name) end)
		filterButtons[name] = btn
	end
	filterButtons["All"]:LockHighlight()

	trackingScroll = CreateFrame("ScrollFrame", "GearAdvisorTrackingScroll", mainFrame, "UIPanelScrollFrameTemplate")
	trackingScroll:SetPoint("TOPLEFT", 20, -636)
	trackingScroll:SetPoint("BOTTOMRIGHT", -32, 20)

	trackingContent = CreateFrame("Frame", nil, trackingScroll)
	trackingContent:SetSize(560, 20)
	trackingScroll:SetScrollChild(trackingContent)
end

local function RefreshSlotIcons()
	for slotName, btn in pairs(slotButtons) do
		local slotId = GetInventorySlotInfo(slotName)
		local texture = GetInventoryItemTexture("player", slotId)
		btn.icon:SetTexture(texture or "Interface\\PaperDollInfoFrame\\UI-GearManager-LeaveItem-Slot")
	end
end

function UI:Toggle()
	if not mainFrame then
		BuildFrame()
	end

	if mainFrame:IsShown() then
		mainFrame:Hide()
		return
	end

	mainFrame:Show()
	RefreshSlotIcons()
	RefreshCapLabel()
	self:RefreshTracking()
	if selectedSlot then
		self:ShowCandidatesForSlot(selectedSlot)
	end
end
