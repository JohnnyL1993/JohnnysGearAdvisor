-- Determines whether an ItemDB candidate is actually usable by the current
-- character, so ItemDB entries don't need manual per-spec tagging - just an
-- armor type (for gear) or an explicit class list (for weapons, since weapon
-- proficiency is class-specific in a way that doesn't reduce to a simple type
-- check the way armor does). Once an item passes eligibility, Scoring.lua's
-- per-spec stat weights decide whether it's actually a good pick.
JohnnysGearAdvisor.Eligibility = {}
local Eligibility = JohnnysGearAdvisor.Eligibility

-- The armor type each class is actually itemized for at level 80. Several
-- classes can technically equip a lower type, but it would never be a real
-- upgrade, so we only ever match a class's one "correct" type.
local ARMOR_TYPE_BY_CLASS = {
	WARLOCK = "Cloth", PRIEST = "Cloth", MAGE = "Cloth",
	ROGUE = "Leather", DRUID = "Leather",
	HUNTER = "Mail", SHAMAN = "Mail",
	WARRIOR = "Plate", PALADIN = "Plate", DEATHKNIGHT = "Plate",
}

-- Slots where armor-type proficiency actually applies (per WoW's own equip
-- rules). Neck/back/finger/trinket have no armor type at all - anyone can wear
-- any cloak/ring/trinket/necklace regardless of class.
local ARMOR_RESTRICTED_SLOTS = {
	HeadSlot = true, ShoulderSlot = true, ChestSlot = true, WristSlot = true,
	HandsSlot = true, WaistSlot = true, LegsSlot = true, FeetSlot = true,
}

-- Only true weapons require explicit class tagging. SecondaryHandSlot is shared
-- by actual off-hand weapons (rare, e.g. a warrior's second axe) AND "Held in
-- Off-Hand" items (tomes, orbs, etc.) which aren't proficiency-restricted at all
-- - since those account for nearly everything in that slot, it defaults to
-- universal like neck/back/ring/trinket unless an entry explicitly opts into
-- class restriction via `classes`.
local WEAPON_SLOTS = {
	MainHandSlot = true, RangedSlot = true,
}

function Eligibility:ArmorTypeForClass(classFile)
	return ARMOR_TYPE_BY_CLASS[classFile]
end

-- Primary-stat category per spec, used only to keep universal slots (neck/back/
-- ring/trinket - see IsEligible below) from recommending another role's gear.
-- WotLK itemizes Hit/Crit/Haste Rating and Stamina identically across every
-- role, so those alone don't disqualify an off-role item in Scoring.lua; this
-- checks the one thing that actually distinguishes itemization: which primary
-- stat (intellect/strength/agility) the piece was itemized around.
local STAT_CATEGORY_BY_SPEC = {
	-- Casters (int)
	Affliction = "int", Demonology = "int", Destruction = "int",
	Discipline = "int", Holy = "int", Shadow = "int",
	Arcane = "int", Fire = "int", -- Frost handled below (Mage vs DK)
	Balance = "int", Restoration = "int",
	-- Strength melee/tank
	Arms = "str", Fury = "str", Protection = "str", Retribution = "str",
	Blood = "str", Unholy = "str",
	-- Agility melee/ranged
	BeastMastery = "agi", Marksmanship = "agi", Survival = "agi",
	Feral = "agi", Enhancement = "agi",
	Combat = "agi", Assassination = "agi", Subtlety = "agi",
}

-- Returns true if `stats` (as fetched by TooltipScan) is a sensible pick for
-- the given spec, filtering out items itemized for an entirely different
-- role's primary stat. Only meaningful for universal slots; called from
-- Scoring.lua once tooltip stats are known.
function Eligibility:IsRoleAppropriate(stats, specKey)
	local category = STAT_CATEGORY_BY_SPEC[specKey]
	if specKey == "Frost" then
		local _, classFile = UnitClass("player")
		category = (classFile == "DEATHKNIGHT") and "str" or "int"
	end
	if not category or not stats then
		return true -- unknown spec or no stats yet: fail open, don't filter
	end

	local hasInt = (stats.intellect or 0) > 0
	local hasStr = (stats.strength or 0) > 0
	local hasAgi = (stats.agility or 0) > 0
	if not (hasInt or hasStr or hasAgi) then
		return true -- pure secondary-stat/proc item: universal
	end

	if category == "int" then return hasInt end
	if category == "str" then return hasStr end
	if category == "agi" then return hasAgi end
	return true
end

-- Checks the "Classes: X, Y" line TooltipScan scrapes live off an item's
-- tooltip (see TooltipScan.lua). armorType/classes in ItemDB.lua only encode
-- armor-type proficiency and weapon proficiency - they say nothing about the
-- minority of armor pieces (mainly tier-token gear) that are hard-locked to one
-- specific class the same way a weapon is, e.g. a Warlock-only or Priest-only
-- cloth chest that a Mage's "Cloth" armorType match would otherwise let through.
-- Returns true when the item has no such restriction, or when the restriction
-- includes the character's own class.
function Eligibility:IsClassRestrictionSatisfied(restrictedClassesText)
	if not restrictedClassesText then
		return true -- most gear isn't class-locked at all
	end

	local _, classFile = UnitClass("player")
	local localizedName = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile])
		or (LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classFile])
	if not localizedName then
		return true -- can't resolve our own class name: fail open
	end

	for name in restrictedClassesText:gmatch("[^,]+") do
		if name:match("^%s*(.-)%s*$") == localizedName then
			return true
		end
	end
	return false
end

-- Returns true if `entry` (an ItemDB row) is usable by the current character
-- in the given slot.
function Eligibility:IsEligible(entry, slotName)
	local _, classFile = UnitClass("player")

	if entry.classes then
		-- Weapons (and anything else explicitly restricted to specific classes,
		-- since weapon proficiency isn't a simple type check).
		for _, c in ipairs(entry.classes) do
			if c == classFile then
				return true
			end
		end
		return false
	end

	if WEAPON_SLOTS[slotName] then
		return false -- weapons must always carry an explicit `classes` list
	end

	if not ARMOR_RESTRICTED_SLOTS[slotName] then
		return true -- neck/back/ring/trinket: universal, no armor type to check
	end

	local myArmorType = ARMOR_TYPE_BY_CLASS[classFile]
	return myArmorType ~= nil and entry.armorType == myArmorType
end
