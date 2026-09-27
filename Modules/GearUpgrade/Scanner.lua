JohnnysGearAdvisor.Scanner = {}
local Scanner = JohnnysGearAdvisor.Scanner

local SLOT_NAMES = {
	"HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "WristSlot",
	"HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot",
	"Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}
Scanner.SLOT_NAMES = SLOT_NAMES

-- Both finger/trinket slots share one set of ItemDB candidates since either
-- physical slot can hold either item.
function Scanner:DBKeyForSlot(slotName)
	if slotName == "Finger0Slot" or slotName == "Finger1Slot" then
		return "FingerSlot"
	elseif slotName == "Trinket0Slot" or slotName == "Trinket1Slot" then
		return "TrinketSlot"
	end
	return slotName
end

-- Returns { [slotName] = { slotId, itemId, link } } for all 17 gear slots.
function Scanner:GetEquipped()
	local equipped = {}
	for _, slotName in ipairs(SLOT_NAMES) do
		local slotId = GetInventorySlotInfo(slotName)
		equipped[slotName] = {
			slotId = slotId,
			itemId = GetInventoryItemID("player", slotId),
			link = GetInventoryItemLink("player", slotId),
		}
	end
	return equipped
end

-- Stats for the item currently in a slot, scanned as the bare base item (gems and
-- enchants excluded) or nil if the slot is empty. ItemDB candidates are always
-- scored bare too (TooltipScan:LinkFromItemId), since we don't simulate hypothetical
-- gems/enchants on unowned items - scoring the equipped piece bare as well keeps the
-- comparison apples-to-apples instead of penalizing a genuinely better candidate for
-- not having the enchant/gems already applied to the equipped item.
function Scanner:GetEquippedStats(slotName)
	local slotId = GetInventorySlotInfo(slotName)
	local itemId = GetInventoryItemID("player", slotId)
	if not itemId then
		return nil
	end
	return JohnnysGearAdvisor.TooltipScan:GetStats(itemId)
end

-- Live combat-rating snapshot used for the hit-cap readout and cap-aware scoring.
function Scanner:GetCurrentRatings()
	return {
		hitSpell = GetCombatRatingBonus(CR_HIT_SPELL) or 0,
		hitMelee = GetCombatRatingBonus(CR_HIT_MELEE) or 0,
		hitRanged = GetCombatRatingBonus(CR_HIT_RANGED) or 0,
		critSpell = GetCombatRatingBonus(CR_CRIT_SPELL) or 0,
		hasteSpell = GetCombatRatingBonus(CR_HASTE_SPELL) or 0,
		expertise = CR_EXPERTISE and (GetCombatRatingBonus(CR_EXPERTISE) or 0) or 0,
	}
end
