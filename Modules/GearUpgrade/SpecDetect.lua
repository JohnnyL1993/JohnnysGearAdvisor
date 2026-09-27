-- Maps (class, talent-tab-index) -> spec archetype key + display name + role.
-- Tab order is fixed per class in 3.3.5a (left-to-right as shown in the talent UI).
local ARCHETYPES = {
	WARRIOR = {
		{ key = "Arms", name = "Arms", role = "dps" },
		{ key = "Fury", name = "Fury", role = "dps" },
		{ key = "Protection", name = "Protection", role = "tank" },
	},
	PALADIN = {
		{ key = "Holy", name = "Holy", role = "healer" },
		{ key = "Protection", name = "Protection", role = "tank" },
		{ key = "Retribution", name = "Retribution", role = "dps" },
	},
	HUNTER = {
		{ key = "BeastMastery", name = "Beast Mastery", role = "dps" },
		{ key = "Marksmanship", name = "Marksmanship", role = "dps" },
		{ key = "Survival", name = "Survival", role = "dps" },
	},
	ROGUE = {
		{ key = "Assassination", name = "Assassination", role = "dps" },
		{ key = "Combat", name = "Combat", role = "dps" },
		{ key = "Subtlety", name = "Subtlety", role = "dps" },
	},
	PRIEST = {
		{ key = "Discipline", name = "Discipline", role = "healer" },
		{ key = "Holy", name = "Holy", role = "healer" },
		{ key = "Shadow", name = "Shadow", role = "dps" },
	},
	SHAMAN = {
		{ key = "Elemental", name = "Elemental", role = "dps" },
		{ key = "Enhancement", name = "Enhancement", role = "dps" },
		{ key = "Restoration", name = "Restoration", role = "healer" },
	},
	MAGE = {
		{ key = "Arcane", name = "Arcane", role = "dps" },
		{ key = "Fire", name = "Fire", role = "dps" },
		{ key = "Frost", name = "Frost", role = "dps" },
	},
	WARLOCK = {
		{ key = "Affliction", name = "Affliction", role = "dps" },
		{ key = "Demonology", name = "Demonology", role = "dps" },
		{ key = "Destruction", name = "Destruction", role = "dps" },
	},
	DRUID = {
		{ key = "Balance", name = "Balance", role = "dps" },
		{ key = "Feral", name = "Feral Combat", role = "dps" },
		{ key = "Restoration", name = "Restoration", role = "healer" },
	},
	DEATHKNIGHT = {
		{ key = "Blood", name = "Blood", role = "tank" },
		{ key = "Frost", name = "Frost", role = "dps" },
		{ key = "Unholy", name = "Unholy", role = "dps" },
	},
}

JohnnysGearAdvisor.SpecDetect = {}
local SpecDetect = JohnnysGearAdvisor.SpecDetect

-- Returns classFile, specKey, specName, role, pointsSpentInTree
function SpecDetect:GetActiveSpec()
	local _, classFile = UnitClass("player")
	local classArchetypes = ARCHETYPES[classFile]
	if not classArchetypes then
		return classFile, nil, nil, nil, 0
	end

	local bestTab, bestPoints = 1, -1
	for tabIndex = 1, GetNumTalentTabs() do
		local _, _, pointsSpent = GetTalentTabInfo(tabIndex)
		pointsSpent = pointsSpent or 0
		if pointsSpent > bestPoints then
			bestTab, bestPoints = tabIndex, pointsSpent
		end
	end

	local archetype = classArchetypes[bestTab]
	if not archetype then
		return classFile, nil, nil, nil, 0
	end

	return classFile, archetype.key, archetype.name, archetype.role, bestPoints
end

-- Returns how many points are spent in a specific talent, identified by
-- (tabIndex, talentIndex) as shown in the in-game talent frame.
function SpecDetect:GetTalentRank(tabIndex, talentIndex)
	local _, _, _, _, rank = GetTalentInfo(tabIndex, talentIndex)
	return rank or 0
end

-- Returns the ordered { key, name, role } archetype list for a class (used to
-- build the spec-preview tabs in UI.lua), or an empty table if unrecognized.
function SpecDetect:GetArchetypesForClass(classFile)
	return ARCHETYPES[classFile] or {}
end

-- Looks a talent up by its exact name instead of a hardcoded grid index, since
-- Blizzard's internal talent ordering within a tab isn't guaranteed to match
-- visual left-to-right/top-to-bottom layout. Safer than hardcoding indices.
function SpecDetect:GetTalentRankByName(tabIndex, talentName)
	local numTalents = GetNumTalents(tabIndex) or 0
	for i = 1, numTalents do
		local name, _, _, _, rank = GetTalentInfo(tabIndex, i)
		if name == talentName then
			return rank or 0
		end
	end
	return 0
end
