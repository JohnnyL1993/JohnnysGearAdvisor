-- Gear Advisor window, in the suite's "workshop rack" look.
--
-- Upgrades tab: every gear slot is listed on the left with what's equipped
-- and its best available upgrade, biggest gain first - so "what should I get
-- next?" is answered without clicking through 17 slots. Selecting a slot
-- lists all its candidates on the right, filterable by where they come from.
-- Tracking tab: the items you've chosen to go after, their emblem cost
-- against what you hold, and which ones you now own.
--
-- Plain CreateFrame-based UI (no AceGUI - its widget/layout system was
-- causing the panel to hang the whole client on open).
JohnnysGearAdvisor.UI = {}
local UI = JohnnysGearAdvisor.UI
local Skin = JohnnysGearAdvisor.Skin
local SpecDetect = JohnnysGearAdvisor.SpecDetect
local StatWeights = JohnnysGearAdvisor.StatWeights
local Scoring = JohnnysGearAdvisor.Scoring
local Scanner = JohnnysGearAdvisor.Scanner
local C = Skin.C

local FRAME_WIDTH, FRAME_HEIGHT = 880, 580
local PAD = 14
local CONTENT_TOP = 96
local CONTENT_WIDTH = FRAME_WIDTH - PAD * 2
local SLOT_LIST_WIDTH = 350
local SLOT_ROW_HEIGHT = 26
local RIGHT_X = SLOT_LIST_WIDTH + 16
-- Scrollbars render just outside a scrollframe's own width.
local CAND_WIDTH = CONTENT_WIDTH - RIGHT_X - 24
local TRACK_WIDTH = CONTENT_WIDTH - 24
local ITEM_ROW_HEIGHT = 46
-- A score difference this small is a wash, not an upgrade.
local UPGRADE_EPSILON = 0.5
-- Slots are scored one at a time on a short timer rather than all in one
-- frame: scoring reads every candidate's tooltip, and the first pass also
-- asks the server for any item the client hasn't seen yet.
local SCAN_INTERVAL = 0.12
local RETRY_SECONDS = 1.5

local SLOT_LABELS = {
	HeadSlot = "Head", NeckSlot = "Neck", ShoulderSlot = "Shoulder", BackSlot = "Back",
	ChestSlot = "Chest", WristSlot = "Wrist", HandsSlot = "Hands", WaistSlot = "Waist",
	LegsSlot = "Legs", FeetSlot = "Feet", Finger0Slot = "Ring 1", Finger1Slot = "Ring 2",
	Trinket0Slot = "Trinket 1", Trinket1Slot = "Trinket 2", MainHandSlot = "Main Hand",
	SecondaryHandSlot = "Off Hand", RangedSlot = "Ranged",
}

-- The two ring and two trinket slots draw on the same candidates, so an item
-- already worn in one must not be offered as an upgrade for the other.
local SIBLING_SLOT = {
	Finger0Slot = "Finger1Slot", Finger1Slot = "Finger0Slot",
	Trinket0Slot = "Trinket1Slot", Trinket1Slot = "Trinket0Slot",
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

-- Where a candidate comes from, for the source filters. Emblem purchases are
-- the entries with a `cost` (see ItemDB.lua); raid and dungeon drops carry
-- their size in the source text; crafted items, tokens and reputation rewards
-- fall under "other".
local SOURCE_FILTERS = {
	{ key = "emblem", label = "Emblems", width = 66 },
	{ key = "r10", label = "10-Man", width = 58 },
	{ key = "r25", label = "25-Man", width = 58 },
	{ key = "other", label = "Other", width = 52 },
}

local function SourceKind(cand)
	if cand.cost then
		return "emblem"
	end
	local source = cand.source or ""
	if string.find(source, "25-Man", 1, true) then
		return "r25"
	elseif string.find(source, "10-Man", 1, true) then
		return "r10"
	end
	return "other"
end

-- Emblems are currencies on this client; GetItemCount on the emblem's item id
-- reports the amount held, with the currency list as a fallback by name.
local CURRENCY_ITEMS = { Frost = 49426, Triumph = 47241, Conquest = 45624, Valor = 40753, Heroism = 40752 }
local EXTRA_ITEMS = { ["1 Trophy of the Crusade"] = 47242 }

local function HeldCurrency(currency)
	local id = CURRENCY_ITEMS[currency]
	local held = (id and GetItemCount(id)) or 0
	if held == 0 and GetCurrencyListSize then
		local want = "Emblem of " .. currency
		for i = 1, GetCurrencyListSize() do
			local name, isHeader, _, _, _, count = GetCurrencyListInfo(i)
			if not isHeader and name == want then
				return count or 0
			end
		end
	end
	return held
end

local function IsOwned(itemId)
	return ((GetItemCount(itemId, true) or 0) > 0) or (IsEquippedItem(itemId) and true or false)
end

local mainFrame, crumbText, capText, capBar, scanText
local suppressionRow, suppressionValueText
local upgradesTab, trackingTab
local candHeading, candEquipped, candEmpty, candidatesScroll, candidatesContent
local totalsLabel, trackingScroll, trackingContent, trackingEmpty
local slotRows = {}
local candidateRows = {}
local trackingRows = {}
local filterButtons = {}
local specTabButtons = {}
local sourceButtons = {}
local upgradesOnlyBtn
local sortButtons = {}
local mainTabs = {}
local activeMainTab = "Upgrades"

local selectedSlot
local slotSort = "gain" -- or "slot"
local trackingFilter -- nil = show all
local previewSpecKey -- nil = follow the character's actual active talent spec

-- [slotName] = result of ScoreSlot, filled in by the scan queue.
local slotResults = {}
local scanQueue = {}
local scanElapsed, retryElapsed = 0, 0
local trackingDirty = false

local function Filters()
	local profile = JohnnysGearAdvisor.db.profile
	if not profile.filters then
		profile.filters = { upgradesOnly = true, emblem = true, r10 = true, r25 = true, other = true }
	end
	return profile.filters
end

local function Body(parent, color)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetJustifyH("LEFT")
	color = color or C.text
	fs:SetTextColor(color[1], color[2], color[3])
	return fs
end

-- A Skin button that stays lit (lime border, lighter fill) while selected.
local function PaintToggle(btn, on)
	if on then
		btn:SetBackdropColor(0.122, 0.153, 0.169, 0.95)
		btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 1)
		btn.text:SetTextColor(C.text[1], C.text[2], C.text[3])
	else
		btn:SetBackdropColor(C.panel[1], C.panel[2], C.panel[3], 0.95)
		btn:SetBackdropBorderColor(C.rule2[1], C.rule2[2], C.rule2[3], 1)
		local dimmed = btn.dimmed and C.dim or C.muted
		btn.text:SetTextColor(dimmed[1], dimmed[2], dimmed[3])
	end
end

-- StyleButton's own OnMouseUp repaints the idle fill, so toggles re-apply
-- their look from there as well.
local function MakeToggle(btn, isOn)
	btn.isOn = isOn
	btn:SetScript("OnMouseUp", function(self) PaintToggle(self, self.isOn()) end)
	PaintToggle(btn, isOn())
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

-- Gain shown as "how much better than what you're wearing" - the raw score
-- difference means nothing on its own. An empty slot has nothing to be a
-- percentage of, so it falls back to the raw figure.
local function GainText(cand, equippedScore)
	local delta = cand.delta
	if equippedScore and equippedScore > 0 then
		local pct = delta / equippedScore * 100
		if delta > UPGRADE_EPSILON then
			return string.format("|cffb9e24a+%.1f%%|r", pct)
		elseif delta < -UPGRADE_EPSILON then
			return string.format("|cffff7366%.1f%%|r", pct)
		end
		return "|cff9aa8a6same|r"
	end
	if delta > UPGRADE_EPSILON then
		return string.format("|cffb9e24a+%.0f|r", delta)
	end
	return "|cff9aa8a6same|r"
end

-- Only vendor/token-purchased items carry a `cost` (see ItemDB.lua); boss drops
-- and reputation rewards have none, so there's nothing to display for those.
local function CostText(cost)
	if not cost then
		return nil
	end
	local text = string.format("%d Emblem%s of %s", cost.amount, cost.amount == 1 and "" or "s", cost.currency)
	if cost.extra then
		text = text .. " + " .. cost.extra
	end
	return text
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

----------------------------------------------------------------------------
-- Scoring a slot, and the queue that works through all of them
----------------------------------------------------------------------------
local function ScoreSlot(slotName)
	local _, specKey = GetSpec()
	local result = { candidates = {}, pending = 0 }
	if not specKey then
		result.noDatabase = true
		return result
	end

	local equippedScore, candidates, pendingCount = Scoring:GetUpgradesForSlot(slotName, specKey)
	if not equippedScore then
		result.noDatabase = true
		return result
	end
	result.equippedScore = equippedScore
	result.pending = pendingCount or 0

	local equippedId = GetInventoryItemID("player", GetInventorySlotInfo(slotName))
	local sibling = SIBLING_SLOT[slotName]
	local siblingId = sibling and GetInventoryItemID("player", GetInventorySlotInfo(sibling))

	-- Already sorted best-first by Scoring.
	for _, cand in ipairs(candidates) do
		if cand.itemId ~= equippedId and cand.itemId ~= siblingId then
			cand.kind = SourceKind(cand)
			table.insert(result.candidates, cand)
		end
	end
	return result
end

local function PassesSource(cand)
	return Filters()[cand.kind] ~= false
end

-- The best candidate for a slot under the current source filters, or nil if
-- nothing there beats what's equipped.
local function BestUpgrade(result)
	if not result or result.noDatabase then
		return nil
	end
	for _, cand in ipairs(result.candidates) do
		if PassesSource(cand) then
			if cand.delta > UPGRADE_EPSILON then
				return cand
			end
			return nil
		end
	end
	return nil
end

local function QueueSlot(slotName)
	for _, queued in ipairs(scanQueue) do
		if queued == slotName then
			return
		end
	end
	table.insert(scanQueue, slotName)
end

local function QueueAllSlots(reset)
	if reset then
		slotResults = {}
	end
	-- The selected slot first, so its candidate list fills in immediately.
	if selectedSlot then
		QueueSlot(selectedSlot)
	end
	for _, slotName in ipairs(Scanner.SLOT_NAMES) do
		QueueSlot(slotName)
	end
end

----------------------------------------------------------------------------
-- Header: spec and hit cap
----------------------------------------------------------------------------
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

-- Hit against the cap as a short line and a meter. Hidden for healer-role
-- specs, since heals can't miss.
local function RefreshCapLabel()
	local classFile, specKey, specName, role = GetSpec()
	capBar:Hide()
	if not specKey then
		crumbText:SetText("")
		capText:SetText("Unrecognised class or spec.")
		suppressionRow:Hide()
		return
	end
	crumbText:SetText(string.upper(specName) .. "  /  " .. string.upper(tostring(role)))
	if not StatWeights:GetForSpec(specKey) then
		capText:SetText("No item database yet for this spec.")
		suppressionRow:Hide()
		return
	end

	RefreshSuppressionRow(specKey)

	local capInfo = StatWeights:GetHitCapInfo(specKey)
	if not capInfo then
		capText:SetText("Hit cap doesn't apply to this spec.")
		return
	end

	local current = StatWeights:GetCurrentHitPercent(capInfo.ratingType)
	local remaining = capInfo.capPercent - current
	local status, color
	if remaining < -0.05 then
		status, color = string.format("%.1f%% over cap", -remaining), C.short
	elseif remaining < 0.05 then
		status, color = "at cap", C.accent
	else
		status, color = string.format("%.1f%% below cap", remaining), { 1, 0.85, 0.40 }
	end
	capText:SetText(string.format("HIT  %.1f%% / %.1f%%   |cff%02x%02x%02x%s|r", current, capInfo.capPercent,
		color[1] * 255, color[2] * 255, color[3] * 255, status))

	local fraction = (capInfo.capPercent > 0) and math.min(1, math.max(0, current / capInfo.capPercent)) or 0
	if fraction <= 0 then
		capBar.fill:Hide()
	else
		capBar.fill:Show()
		capBar.fill:SetWidth(math.max(1, (capBar:GetWidth() - 2) * fraction))
		capBar.fill:SetVertexColor(color[1], color[2], color[3], 1)
	end
	capBar:Show()
end

----------------------------------------------------------------------------
-- Upgrades tab
----------------------------------------------------------------------------
local RefreshSlotList, RefreshCandidates

local function CreateSlotRow(parent, index)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(SLOT_LIST_WIDTH, SLOT_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -26 - (index - 1) * SLOT_ROW_HEIGHT)

	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetTexture(Skin.WHITE)
	row.bg:SetVertexColor(0.122, 0.153, 0.169, 1)
	row.bg:Hide()

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture(Skin.WHITE)
	highlight:SetVertexColor(1, 1, 1, 0.06)

	row.bar = Skin:Solid(row, "ARTWORK", C.accent)
	row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
	row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
	row.bar:SetWidth(2)
	row.bar:Hide()

	local rule = Skin:Solid(row, "BORDER", C.rule)
	rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
	rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
	rule:SetHeight(1)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(20, 20)
	row.icon:SetPoint("LEFT", row, "LEFT", 8, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.slot = Body(row, C.muted)
	row.slot:SetPoint("LEFT", row, "LEFT", 34, 0)
	row.slot:SetWidth(66)

	row.gain = Body(row, C.text)
	row.gain:SetPoint("RIGHT", row, "RIGHT", -8, 0)
	row.gain:SetJustifyH("RIGHT")
	row.gain:SetWidth(54)

	row.best = Body(row, C.text)
	row.best:SetPoint("LEFT", row, "LEFT", 102, 0)
	row.best:SetWidth(SLOT_LIST_WIDTH - 102 - 66)
	row.best:SetHeight(11)
	if row.best.SetWordWrap then
		row.best:SetWordWrap(false)
	end

	row:SetScript("OnClick", function(self)
		if self.slotName then
			UI:ShowCandidatesForSlot(self.slotName)
		end
	end)
	row:SetScript("OnEnter", function(self)
		if not self.slotName then
			return
		end
		local link = GetInventoryItemLink("player", GetInventorySlotInfo(self.slotName))
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		if link then
			GameTooltip:SetHyperlink(link)
		else
			GameTooltip:SetText(SLOT_LABELS[self.slotName] .. " (empty)")
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	return row
end

RefreshSlotList = function()
	if not upgradesTab then
		return
	end

	local order = {}
	for i, slotName in ipairs(Scanner.SLOT_NAMES) do
		local result = slotResults[slotName]
		local best = BestUpgrade(result)
		table.insert(order, { slotName = slotName, index = i, result = result, best = best })
	end
	if slotSort == "gain" then
		table.sort(order, function(a, b)
			local ad = a.best and a.best.delta or -1
			local bd = b.best and b.best.delta or -1
			if ad ~= bd then
				return ad > bd
			end
			return a.index < b.index
		end)
	end

	for i, entry in ipairs(order) do
		local row = slotRows[i]
		if not row then
			row = CreateSlotRow(upgradesTab, i)
			slotRows[i] = row
		end
		row.slotName = entry.slotName
		row.slot:SetText(SLOT_LABELS[entry.slotName])

		local texture = GetInventoryItemTexture("player", GetInventorySlotInfo(entry.slotName))
		row.icon:SetTexture(texture or "Interface\\PaperDollInfoFrame\\UI-GearManager-LeaveItem-Slot")

		local result = entry.result
		if not result then
			row.best:SetText("Checking...")
			row.best:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
			row.gain:SetText("")
		elseif result.noDatabase then
			row.best:SetText("No item database for this spec")
			row.best:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
			row.gain:SetText("")
		elseif entry.best then
			local name = GetItemInfo(entry.best.itemId)
			row.best:SetText(name or ("Item #" .. entry.best.itemId))
			row.best:SetTextColor(C.text[1], C.text[2], C.text[3])
			row.gain:SetText(GainText(entry.best, result.equippedScore))
		else
			if result.pending > 0 and #result.candidates == 0 then
				row.best:SetText("Loading items...")
			else
				row.best:SetText("Nothing better found")
			end
			row.best:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
			row.gain:SetText("")
		end

		if entry.slotName == selectedSlot then
			row.bg:Show()
			row.bar:Show()
		else
			row.bg:Hide()
			row.bar:Hide()
		end
		row:Show()
	end

	for key, btn in pairs(sortButtons) do
		PaintToggle(btn, key == slotSort)
	end

	if #scanQueue > 0 then
		scanText:SetText(string.format("Checking slots... %d left", #scanQueue))
	else
		scanText:SetText("")
	end
end

local function CreateItemRow(parent, width)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(width, ITEM_ROW_HEIGHT)
	row:EnableMouse(true)

	local highlight = row:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetTexture(Skin.WHITE)
	highlight:SetVertexColor(1, 1, 1, 0.05)

	local rule = Skin:Solid(row, "BORDER", C.rule)
	rule:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
	rule:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
	rule:SetHeight(1)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(28, 28)
	row.icon:SetPoint("LEFT", 4, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	row.text = Body(row, C.text)
	row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.text:SetWidth(width - 44 - 150)

	row.tag = Body(row, C.accent)
	row.tag:SetPoint("RIGHT", row, "RIGHT", -84, 0)
	row.tag:SetJustifyH("RIGHT")

	row.action = Skin:CreateButton(row, 72, 22, "")
	row.action:SetPoint("RIGHT", -4, 0)

	row:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		if self.itemLink then
			GameTooltip:SetHyperlink(self.itemLink)
			if self.scoreNote then
				GameTooltip:AddLine(self.scoreNote, 0.6, 0.66, 0.65)
			end
		else
			GameTooltip:SetText("Loading item...")
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return row
end

local function LayoutRows(rows, parent, count)
	for i = 1, count do
		rows[i]:ClearAllPoints()
		rows[i]:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(i - 1) * ITEM_ROW_HEIGHT)
	end
	parent:SetHeight(math.max(20, count * ITEM_ROW_HEIGHT))
end

RefreshCandidates = function()
	if not upgradesTab then
		return
	end
	for _, row in ipairs(candidateRows) do
		row:Hide()
	end
	candEmpty:Hide()

	local filters = Filters()
	PaintToggle(upgradesOnlyBtn, filters.upgradesOnly ~= false)
	for key, btn in pairs(sourceButtons) do
		PaintToggle(btn, filters[key] ~= false)
	end

	if not selectedSlot then
		candHeading:SetText("PICK A SLOT")
		candEquipped:SetText("Choose a slot on the left to see everything that could go in it.")
		candidatesContent:SetHeight(20)
		return
	end

	local label = SLOT_LABELS[selectedSlot] or selectedSlot
	candHeading:SetText(string.upper(label))
	local equippedLink = GetInventoryItemLink("player", GetInventorySlotInfo(selectedSlot))
	candEquipped:SetText(equippedLink and ("Equipped: " .. equippedLink) or "Nothing equipped in this slot.")

	local result = slotResults[selectedSlot]
	local function Empty(text)
		candEmpty:SetText(text)
		candEmpty:Show()
		candidatesContent:SetHeight(20)
	end
	if not result then
		Empty("Checking this slot...")
		return
	end
	if result.noDatabase then
		Empty("There is no item database yet for this spec.")
		return
	end

	local shown, hidden = 0, 0
	for _, cand in ipairs(result.candidates) do
		local passes = PassesSource(cand) and (filters.upgradesOnly == false or cand.delta > UPGRADE_EPSILON)
		if not passes then
			hidden = hidden + 1
		else
			shown = shown + 1
			local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(cand.itemId)
			local row = candidateRows[shown]
			if not row then
				row = CreateItemRow(candidatesContent, CAND_WIDTH)
				candidateRows[shown] = row
			end
			row.itemLink = link
			row.scoreNote = string.format("Advisor score %+.1f against your equipped item", cand.delta)
			row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")

			local lines = { (name or ("Item #" .. cand.itemId)) .. "   " .. GainText(cand, result.equippedScore) }
			table.insert(lines, "|cff9aa8a6" .. (cand.source or "") .. "|r")
			local cost = CostText(cand.cost)
			if cost then
				table.insert(lines, "|cffe6ecea" .. cost .. "|r")
			end
			row.text:SetText(table.concat(lines, "\n"))
			row.tag:SetText("")

			local tracked = IsTracked(cand.itemId, selectedSlot)
			row.action.text:SetText(tracked and "Tracked" or "Track")
			PaintToggle(row.action, tracked)
			local slotName = selectedSlot
			row.action:SetScript("OnMouseUp", function(self) PaintToggle(self, IsTracked(cand.itemId, slotName)) end)
			row.action:SetScript("OnClick", function()
				if IsTracked(cand.itemId, slotName) then
					for idx, entry in ipairs(TrackingList()) do
						if entry.itemId == cand.itemId and entry.slot == slotName then
							UI:RemoveFromTracking(idx)
							break
						end
					end
				else
					UI:AddToTracking(cand.itemId, slotName, cand.source, cand.cost)
				end
				RefreshCandidates()
			end)
			row:Show()
		end
	end

	LayoutRows(candidateRows, candidatesContent, shown)

	if shown == 0 then
		if result.pending > 0 and #result.candidates == 0 then
			Empty("Loading item data from the server, one moment...")
		elseif #result.candidates == 0 then
			-- Weapon slots in particular can have no candidates at all for a
			-- class nobody has curated weapons for yet.
			Empty("The database has no other items for this slot and class.")
		elseif filters.upgradesOnly ~= false then
			Empty("Nothing here beats what you have equipped. Turn off \"Upgrades only\" to see all " .. hidden .. " items.")
		else
			Empty("All " .. hidden .. " items for this slot are hidden by the source filters above.")
		end
	end
end

function UI:ShowCandidatesForSlot(slotName)
	selectedSlot = slotName
	if not slotResults[slotName] then
		-- Jump the queue so this slot's list fills in first.
		table.insert(scanQueue, 1, slotName)
	end
	RefreshSlotList()
	RefreshCandidates()
end

local function BuildUpgradesTab(parent)
	upgradesTab = parent

	local sortLabel = Skin:Heading(parent, 10, C.muted)
	sortLabel:SetPoint("TOPLEFT", 0, -5)
	sortLabel:SetText("ORDER")
	local anchor = sortLabel
	for i, def in ipairs({ { "gain", "Biggest gain" }, { "slot", "By slot" } }) do
		local btn = Skin:CreateButton(parent, 86, 20, def[2])
		btn:SetPoint("LEFT", anchor, "RIGHT", (i == 1) and 8 or 2, 0)
		btn:SetScript("OnClick", function()
			slotSort = def[1]
			RefreshSlotList()
		end)
		btn:SetScript("OnMouseUp", function(self) PaintToggle(self, slotSort == def[1]) end)
		sortButtons[def[1]] = btn
		anchor = btn
	end

	scanText = Body(parent, C.dim)
	scanText:SetPoint("LEFT", anchor, "RIGHT", 10, 0)

	-- Right column: the selected slot's candidates.
	candHeading = Skin:Heading(parent, 13, C.text)
	candHeading:SetPoint("TOPLEFT", RIGHT_X, -3)

	candEquipped = Body(parent, C.muted)
	candEquipped:SetPoint("LEFT", candHeading, "RIGHT", 10, 0)
	candEquipped:SetWidth(CAND_WIDTH - 110)
	candEquipped:SetHeight(11)
	if candEquipped.SetWordWrap then
		candEquipped:SetWordWrap(false)
	end

	local filters = Filters()
	upgradesOnlyBtn = Skin:CreateButton(parent, 98, 20, "Upgrades only")
	upgradesOnlyBtn:SetPoint("TOPLEFT", RIGHT_X, -24)
	upgradesOnlyBtn:SetScript("OnClick", function()
		filters.upgradesOnly = not (filters.upgradesOnly ~= false)
		RefreshCandidates()
	end)
	MakeToggle(upgradesOnlyBtn, function() return filters.upgradesOnly ~= false end)

	local sourceLabel = Skin:Heading(parent, 10, C.muted)
	sourceLabel:SetPoint("LEFT", upgradesOnlyBtn, "RIGHT", 14, 0)
	sourceLabel:SetText("FROM")
	local prev = sourceLabel
	for i, def in ipairs(SOURCE_FILTERS) do
		local btn = Skin:CreateButton(parent, def.width, 20, def.label)
		btn:SetPoint("LEFT", prev, "RIGHT", (i == 1) and 8 or 2, 0)
		btn:SetScript("OnClick", function()
			filters[def.key] = not (filters[def.key] ~= false)
			-- Source filters change which item is "best" for every slot.
			RefreshSlotList()
			RefreshCandidates()
		end)
		MakeToggle(btn, function() return filters[def.key] ~= false end)
		sourceButtons[def.key] = btn
		prev = btn
	end

	candidatesScroll = CreateFrame("ScrollFrame", "GearAdvisorCandidatesScroll", parent, "UIPanelScrollFrameTemplate")
	candidatesScroll:SetPoint("TOPLEFT", RIGHT_X, -50)
	candidatesScroll:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", RIGHT_X, 0)
	candidatesScroll:SetWidth(CAND_WIDTH)
	candidatesContent = CreateFrame("Frame", nil, candidatesScroll)
	candidatesContent:SetSize(CAND_WIDTH, 20)
	candidatesScroll:SetScrollChild(candidatesContent)

	candEmpty = Body(parent, C.muted)
	candEmpty:SetPoint("TOPLEFT", candidatesScroll, "TOPLEFT", 6, -10)
	candEmpty:SetWidth(CAND_WIDTH - 12)
	candEmpty:Hide()
end

----------------------------------------------------------------------------
-- Tracking tab
----------------------------------------------------------------------------
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

-- Emblem cost of the tracked items you don't own yet, per currency, against
-- what you currently hold. Items with no `cost` (boss drops, reputation
-- rewards) simply don't contribute.
local function BuildTotalsText(list)
	local totals, extras, hasAny = {}, {}, false
	local owned = 0
	for _, entry in ipairs(list) do
		if IsOwned(entry.itemId) then
			owned = owned + 1
		elseif entry.cost then
			hasAny = true
			totals[entry.cost.currency] = (totals[entry.cost.currency] or 0) + entry.cost.amount
			if entry.cost.extra then
				extras[entry.cost.extra] = (extras[entry.cost.extra] or 0) + 1
			end
		end
	end

	local parts = {}
	for currency, amount in pairs(totals) do
		local held = HeldCurrency(currency)
		local color = (held >= amount) and "b9e24a" or "ff7366"
		table.insert(parts, string.format("Emblem of %s: %d needed, |cff%s%d held|r", currency, amount, color, held))
	end
	for extra, count in pairs(extras) do
		local itemId = EXTRA_ITEMS[extra]
		local label = string.gsub(extra, "^%d+%s*", "")
		if itemId then
			local held = GetItemCount(itemId, true) or 0
			local color = (held >= count) and "b9e24a" or "ff7366"
			table.insert(parts, string.format("%s: %d needed, |cff%s%d held|r", label, count, color, held))
		else
			table.insert(parts, string.format("%s: %d needed", label, count))
		end
	end
	table.sort(parts)

	local text
	if #list == 0 then
		text = "Nothing tracked yet. On the Upgrades tab, press Track on any item you plan to go after."
	elseif not hasAny then
		text = "None of the tracked items you still need has an emblem cost."
	else
		text = table.concat(parts, "\n")
	end
	if owned > 0 then
		text = text .. string.format("\n|cffb9e24a%d tracked item%s already owned|r - not counted above.", owned, owned == 1 and "" or "s")
	end
	return text
end

-- Rows show the tracking list filtered to `trackingFilter` (a FILTER_CATEGORIES
-- value, or nil for "show everything"). row.trackIndex always points at the
-- entry's real position in the full (unfiltered) tracking list, so Remove still
-- deletes the right item regardless of what's currently filtered out of view.
function UI:RefreshTracking()
	if not trackingTab then
		return
	end
	local list = TrackingList()
	totalsLabel:SetText(BuildTotalsText(list))
	if mainTabs.Tracking then
		mainTabs.Tracking.button.text:SetText(string.format("02  TRACKING (%d)", #list))
	end

	for _, row in ipairs(trackingRows) do
		row:Hide()
	end

	local shown = 0
	for i, entry in ipairs(list) do
		if not trackingFilter or FilterCategoryForSlot(entry.slot) == trackingFilter then
			local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(entry.itemId)
			if not name then
				trackingDirty = true
			end
			shown = shown + 1
			local row = trackingRows[shown]
			if not row then
				row = CreateItemRow(trackingContent, TRACK_WIDTH)
				row.action.text:SetText("Remove")
				row.action:SetScript("OnClick", function()
					UI:RemoveFromTracking(row.trackIndex)
					RefreshCandidates()
				end)
				trackingRows[shown] = row
			end
			row.trackIndex = i
			row.itemLink = link
			row.scoreNote = nil
			row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")

			local lines = { name or ("Item #" .. entry.itemId) }
			table.insert(lines, "|cff9aa8a6" .. (SLOT_LABELS[entry.slot] or entry.slot) .. "  -  " .. (entry.source or "") .. "|r")
			local cost = CostText(entry.cost)
			if cost then
				table.insert(lines, "|cffe6ecea" .. cost .. "|r")
			end
			row.text:SetText(table.concat(lines, "\n"))
			row.tag:SetText(IsOwned(entry.itemId) and "OWNED" or "")
			row:Show()
		end
	end

	LayoutRows(trackingRows, trackingContent, shown)

	if shown == 0 and #list > 0 then
		trackingEmpty:SetText("No tracked items in this slot. Choose All to see the whole list.")
		trackingEmpty:Show()
	else
		trackingEmpty:Hide()
	end

	for cat, btn in pairs(filterButtons) do
		PaintToggle(btn, cat == (trackingFilter or "All"))
	end
end

function UI:SetTrackingFilter(category)
	trackingFilter = category
	self:RefreshTracking()
end

local function BuildTrackingTab(parent)
	trackingTab = parent

	totalsLabel = Body(parent, C.text)
	totalsLabel:SetPoint("TOPLEFT", 0, -2)
	totalsLabel:SetWidth(CONTENT_WIDTH)
	totalsLabel:SetJustifyV("TOP")
	totalsLabel:SetHeight(58)

	-- Filter buttons: "All" plus one per slot category, to narrow the tracking
	-- list down (e.g. just Head, just Rings) without losing the rest.
	local filterNames = { "All" }
	for _, cat in ipairs(FILTER_CATEGORIES) do
		table.insert(filterNames, cat)
	end
	for i, name in ipairs(filterNames) do
		local btn = Skin:CreateButton(parent, 50, 20, name)
		btn:SetWidth(math.max(40, btn.text:GetStringWidth() + 16))
		filterButtons[name] = btn
	end
	local x = 0
	for _, name in ipairs(filterNames) do
		local btn = filterButtons[name]
		btn:SetPoint("TOPLEFT", x, -64)
		x = x + btn:GetWidth() + 2
		btn:SetScript("OnClick", function() UI:SetTrackingFilter(name ~= "All" and name or nil) end)
		btn:SetScript("OnMouseUp", function(self) PaintToggle(self, name == (trackingFilter or "All")) end)
	end

	trackingScroll = CreateFrame("ScrollFrame", "GearAdvisorTrackingScroll", parent, "UIPanelScrollFrameTemplate")
	trackingScroll:SetPoint("TOPLEFT", 0, -92)
	trackingScroll:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
	trackingScroll:SetWidth(TRACK_WIDTH)
	trackingContent = CreateFrame("Frame", nil, trackingScroll)
	trackingContent:SetSize(TRACK_WIDTH, 20)
	trackingScroll:SetScrollChild(trackingContent)

	trackingEmpty = Body(parent, C.muted)
	trackingEmpty:SetPoint("TOPLEFT", trackingScroll, "TOPLEFT", 6, -10)
	trackingEmpty:SetWidth(TRACK_WIDTH - 12)
	trackingEmpty:Hide()
end

----------------------------------------------------------------------------
-- Spec preview
----------------------------------------------------------------------------
local function RefreshSpecTabs()
	local _, activeKey = SpecDetect:GetActiveSpec()
	local highlightKey = previewSpecKey or activeKey
	for key, btn in pairs(specTabButtons) do
		PaintToggle(btn, key == highlightKey)
	end
end

function UI:SetPreviewSpec(specKey)
	local classFile, activeKey = SpecDetect:GetActiveSpec()
	previewSpecKey = (specKey == activeKey) and nil or specKey
	RefreshSpecTabs()
	RefreshCapLabel()
	QueueAllSlots(true)
	RefreshSlotList()
	RefreshCandidates()
end

function UI:RefreshOpenCandidates()
	if mainFrame and mainFrame:IsShown() then
		RefreshSlotList()
		RefreshCandidates()
		self:RefreshTracking()
	end
end

function UI:OnSpecChanged()
	-- An actual in-game respec supersedes whatever spec tab was being previewed.
	previewSpecKey = nil
	if mainFrame and mainFrame:IsShown() then
		RefreshSpecTabs()
		RefreshCapLabel()
		QueueAllSlots(true)
		RefreshSlotList()
		RefreshCandidates()
	end
end

----------------------------------------------------------------------------
-- Window shell
----------------------------------------------------------------------------
local function SelectMainTab(name)
	activeMainTab = name
	for tabName, tab in pairs(mainTabs) do
		if tabName == name then
			tab.frame:Show()
			tab.button.text:SetTextColor(C.text[1], C.text[2], C.text[3])
			tab.button.bar:Show()
		else
			tab.frame:Hide()
			tab.button.text:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
			tab.button.bar:Hide()
		end
	end
	if name == "Tracking" then
		UI:RefreshTracking()
	else
		RefreshSlotList()
		RefreshCandidates()
	end
end

-- A numbered text tab ("01  UPGRADES") with a lime underline when active.
local function CreateMainTab(parent, index, name)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(130, 24)
	btn.text = Skin:Heading(btn, 12, C.muted)
	btn.text:SetPoint("LEFT", btn, "LEFT", 4, 0)
	btn.text:SetText(string.format("%02d  %s", index, string.upper(name)))
	btn.bar = Skin:Solid(btn, "ARTWORK", C.accent)
	btn.bar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
	btn.bar:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
	btn.bar:SetHeight(2)
	btn.bar:Hide()
	btn:SetScript("OnEnter", function(self)
		self.text:SetTextColor(C.text[1], C.text[2], C.text[3])
	end)
	btn:SetScript("OnLeave", function(self)
		if activeMainTab ~= name then
			self.text:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
		end
	end)
	btn:SetScript("OnClick", function() SelectMainTab(name) end)
	return btn
end

-- Works through the scan queue one slot at a time, re-queues slots whose
-- items were still loading (3.3.5a has no "item info received" event), and
-- repaints the tracking list when bags change.
local function OnTick(self, elapsed)
	scanElapsed = scanElapsed + elapsed
	if scanElapsed >= SCAN_INTERVAL then
		scanElapsed = 0
		local slotName = table.remove(scanQueue, 1)
		if slotName then
			slotResults[slotName] = ScoreSlot(slotName)
			if activeMainTab == "Upgrades" then
				RefreshSlotList()
				if slotName == selectedSlot then
					RefreshCandidates()
				end
			end
		end
	end

	retryElapsed = retryElapsed + elapsed
	if retryElapsed >= RETRY_SECONDS then
		retryElapsed = 0
		if #scanQueue == 0 then
			for _, slotName in ipairs(Scanner.SLOT_NAMES) do
				local result = slotResults[slotName]
				if result and not result.noDatabase and result.pending > 0 then
					QueueSlot(slotName)
				end
			end
		end
		if trackingDirty then
			trackingDirty = false
			if activeMainTab == "Tracking" then
				UI:RefreshTracking()
			end
		end
	end
end

local function BuildFrame()
	mainFrame = CreateFrame("Frame", "GearAdvisorFrame", UIParent)
	mainFrame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	mainFrame:SetPoint("RIGHT", UIParent, "RIGHT", -20, 0)
	mainFrame:SetFrameStrata("DIALOG")
	mainFrame:SetMovable(true)
	mainFrame:EnableMouse(true)
	mainFrame:RegisterForDrag("LeftButton")
	mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
	mainFrame:SetScript("OnDragStop", mainFrame.StopMovingOrSizing)
	Skin:StylePanel(mainFrame, 0.95)
	mainFrame:Hide()

	-- Per-window scale/opacity (see Modules\WindowSettings.lua). Guarded so a
	-- stale .toc (client not fully restarted after the file was added) just
	-- skips the feature instead of erroring the whole window.
	if JohnnysGearAdvisor.WindowSettings then
		JohnnysGearAdvisor.WindowSettings:Register(mainFrame, "main", "Gear Advisor")
	end

	local title = Skin:AddHeader(mainFrame, "Gear Advisor")
	crumbText = Skin:Heading(mainFrame, 12, C.muted)
	crumbText:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 10, 1)

	local close = Skin:CreateButton(mainFrame, 20, 20, "X")
	close:SetPoint("TOPRIGHT", -4, -4)
	close:SetScript("OnClick", function() UI:Toggle() end)

	-- The update notice anchors itself to its host's top-left corner, which
	-- the title occupies, so give it a host left of the Cfg button.
	local noticeHost = CreateFrame("Frame", nil, mainFrame)
	noticeHost:SetSize(220, Skin.HEADER_HEIGHT)
	noticeHost:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -76, 2)
	JohnnysGearAdvisor.VersionCheck:AttachNotice(noticeHost)

	if JohnnysGearAdvisor.WindowSettings then
		JohnnysGearAdvisor.WindowSettings:AttachButton(mainFrame)
	end

	-- Spec-preview tabs: one per spec archetype the class has (e.g. all three for
	-- Rogue), even if some don't have a real item database yet - those are
	-- dimmed and just report "no item database". Lets you preview another
	-- spec's recommendations without actually respeccing. Hit-cap numbers
	-- still reflect your real, currently active talents/gear since we can't
	-- know hypothetical talent choices for a spec you're not actually in.
	local classFile = (SpecDetect:GetActiveSpec())
	local archetypes = SpecDetect:GetArchetypesForClass(classFile)
	if #archetypes > 1 then
		local tabX = PAD
		for _, archetype in ipairs(archetypes) do
			local btn = Skin:CreateButton(mainFrame, 100, 20, archetype.name)
			btn:SetPoint("TOPLEFT", tabX, -36)
			btn.dimmed = not StatWeights:GetForSpec(archetype.key)
			btn:SetScript("OnClick", function() UI:SetPreviewSpec(archetype.key) end)
			btn:SetScript("OnMouseUp", function(self)
				local _, activeKey = SpecDetect:GetActiveSpec()
				PaintToggle(self, archetype.key == (previewSpecKey or activeKey))
			end)
			specTabButtons[archetype.key] = btn
			tabX = tabX + 102
		end
	end

	-- Hit against the cap: a meter on the right with the figures beside it.
	capBar = CreateFrame("Frame", nil, mainFrame)
	capBar:SetSize(150, 10)
	capBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PAD, -41)
	Skin:StylePanel(capBar, 1)
	capBar:SetBackdropColor(C.panel[1], C.panel[2], C.panel[3], 1)
	capBar.fill = capBar:CreateTexture(nil, "ARTWORK")
	capBar.fill:SetTexture(Skin.WHITE)
	capBar.fill:SetPoint("TOPLEFT", 1, -1)
	capBar.fill:SetPoint("BOTTOMLEFT", 1, 1)
	capBar:Hide()

	capText = Body(mainFrame, C.text)
	capText:SetPoint("RIGHT", capBar, "LEFT", -10, 0)
	capText:SetJustifyH("RIGHT")

	-- Manual Suppression-points stepper for Demonology/Destruction (see
	-- RefreshSuppressionRow); hidden for every other spec.
	suppressionRow = CreateFrame("Frame", nil, mainFrame)
	suppressionRow:SetSize(196, 20)
	suppressionRow:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -PAD, -62)
	local suppressionLabel = Body(suppressionRow, C.muted)
	suppressionLabel:SetPoint("LEFT", 0, 0)
	suppressionLabel:SetText("Suppression points:")
	local suppressionMinus = Skin:CreateButton(suppressionRow, 20, 20, "-")
	suppressionMinus:SetPoint("LEFT", suppressionLabel, "RIGHT", 8, 0)
	suppressionMinus:SetScript("OnClick", function()
		local points = JohnnysGearAdvisor.db.profile.suppressionPoints or 0
		JohnnysGearAdvisor.db.profile.suppressionPoints = math.max(0, points - 1)
		RefreshCapLabel()
	end)
	suppressionValueText = Body(suppressionRow, C.text)
	suppressionValueText:SetPoint("LEFT", suppressionMinus, "RIGHT", 8, 0)
	suppressionValueText:SetWidth(14)
	suppressionValueText:SetJustifyH("CENTER")
	local suppressionPlus = Skin:CreateButton(suppressionRow, 20, 20, "+")
	suppressionPlus:SetPoint("LEFT", suppressionValueText, "RIGHT", 8, 0)
	suppressionPlus:SetScript("OnClick", function()
		local points = JohnnysGearAdvisor.db.profile.suppressionPoints or 0
		JohnnysGearAdvisor.db.profile.suppressionPoints = math.min(2, points + 1)
		RefreshCapLabel()
	end)
	suppressionRow:Hide()

	-- Main tabs.
	local tabRule = Skin:Solid(mainFrame, "ARTWORK", C.rule)
	tabRule:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 1, -86)
	tabRule:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -1, -86)
	tabRule:SetHeight(1)

	for index, name in ipairs({ "Upgrades", "Tracking" }) do
		local btn = CreateMainTab(mainFrame, index, name)
		btn:SetPoint("TOPLEFT", PAD + (index - 1) * 138, -62)
		local tabFrame = CreateFrame("Frame", nil, mainFrame)
		tabFrame:SetPoint("TOPLEFT", PAD, -CONTENT_TOP)
		tabFrame:SetPoint("BOTTOMRIGHT", -PAD, PAD)
		tabFrame:Hide()
		mainTabs[name] = { button = btn, frame = tabFrame }
	end
	BuildUpgradesTab(mainTabs.Upgrades.frame)
	BuildTrackingTab(mainTabs.Tracking.frame)

	mainFrame:SetScript("OnUpdate", OnTick)

	-- Swapping gear changes every slot's baseline; bag changes can mean a
	-- tracked item was just obtained or emblems were earned.
	local watcher = CreateFrame("Frame", nil, mainFrame)
	watcher:RegisterEvent("UNIT_INVENTORY_CHANGED")
	watcher:RegisterEvent("BAG_UPDATE")
	watcher:SetScript("OnEvent", function(self, event, unit)
		if not mainFrame:IsShown() then
			return
		end
		if event == "UNIT_INVENTORY_CHANGED" then
			if unit == "player" then
				RefreshCapLabel()
				QueueAllSlots(false)
			end
		else
			trackingDirty = true
		end
	end)
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
	RefreshSpecTabs()
	RefreshCapLabel()
	QueueAllSlots(false)
	self:RefreshTracking()
	SelectMainTab(activeMainTab)
end
