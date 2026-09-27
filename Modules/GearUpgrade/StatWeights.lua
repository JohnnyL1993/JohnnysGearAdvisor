JohnnysGearAdvisor.StatWeights = {}
local StatWeights = JohnnysGearAdvisor.StatWeights
local SpecDetect = JohnnysGearAdvisor.SpecDetect

-- Per-spec equivalency-point tables: higher = more valuable per point of that stat.
-- Only specs with a real item database get an entry here; UI falls back to "no data
-- yet" for anything else.
--
-- weaponDps note (applies to every melee/ranged dps spec below): 1 point of attack
-- power = 1/14 DPS on a swing (damage per swing = AP/14 * weapon speed, so the
-- per-second contribution cancels the speed term out), i.e. 1 DPS = 14 AP. Special
-- attacks scale off normalized weapon damage too, not just auto-attacks, so weapon
-- DPS matters more than the AP-only math implies - weighted well above what pure
-- AP-equivalence would suggest, without letting it swamp every other stat.
--
-- Tanks (Protection Warrior/Paladin, Blood DK) are scored on stamina + avoidance
-- (defense/dodge/parry/block) rather than damage stats. This is a simpler model
-- than DPS scoring - it doesn't account for avoidance diminishing returns or the
-- exact defense-rating "capped" threshold (536 defense rating for the old 3.3.5
-- crit-immunity cap), just relative value per point, so treat tank recommendations
-- as a rougher guide than the DPS/healer ones.
local WEIGHTS = {
	-- ============================== Warlock (Cloth) ==============================
	Affliction = {
		role = "dps",
		weights = {
			spellPower  = 1.00,
			hitRating   = 0.90,
			hasteRating = 0.65,
			critRating  = 0.55,
			intellect   = 0.35,
			spirit      = 0.10,
			stamina     = 0.05,
		},
	},
	Demonology = {
		role = "dps",
		weights = {
			spellPower  = 1.00,
			hitRating   = 0.85,
			critRating  = 0.65,
			hasteRating = 0.55,
			intellect   = 0.35,
			spirit      = 0.10,
			stamina     = 0.05,
		},
	},
	Destruction = {
		role = "dps",
		weights = {
			spellPower  = 1.00,
			hitRating   = 0.85,
			critRating  = 0.65,
			hasteRating = 0.60,
			intellect   = 0.35,
			spirit      = 0.10,
			stamina     = 0.05,
		},
	},

	-- ============================== Priest (Cloth) ==============================
	Discipline = {
		role = "healer",
		weights = {
			spellPower  = 1.00,
			hasteRating = 0.65,
			critRating  = 0.45,
			mp5         = 0.55,
			intellect   = 0.30,
			spirit      = 0.40,
			stamina     = 0.05,
		},
	},
	Holy = { -- shared key: Priest Holy AND Paladin Holy both use this archetype name
		role = "healer",
		weights = {
			spellPower  = 1.00,
			hasteRating = 0.70,
			critRating  = 0.40,
			mp5         = 0.50,
			intellect   = 0.30,
			spirit      = 0.45,
			stamina     = 0.05,
		},
	},
	Shadow = {
		role = "dps",
		weights = {
			spellPower  = 1.00,
			hitRating   = 0.90,
			hasteRating = 0.65,
			critRating  = 0.55,
			intellect   = 0.35,
			spirit      = 0.05,
			stamina     = 0.05,
		},
	},

	-- ============================== Mage (Cloth) ==============================
	Arcane = {
		role = "dps",
		weights = {
			spellPower  = 1.00,
			hitRating   = 0.95,
			intellect   = 0.40,
			hasteRating = 0.55,
			critRating  = 0.45,
			spirit      = 0.05,
			stamina     = 0.05,
		},
	},
	Fire = {
		role = "dps",
		weights = {
			spellPower  = 1.00,
			hitRating   = 0.85,
			critRating  = 0.70,
			hasteRating = 0.60,
			intellect   = 0.35,
			spirit      = 0.05,
			stamina     = 0.05,
		},
	},
	Frost = { -- shared key: Mage Frost AND Death Knight Frost both use this archetype name
		role = "dps",
		weights = {
			-- Caster stats (Mage Frost)
			spellPower      = 1.00,
			hitRating       = 0.85,
			critRating      = 0.55,
			hasteRating     = 0.55,
			intellect       = 0.35,
			spirit          = 0.05,
			-- Melee stats (Death Knight Frost) - harmless overlap, an item will only
			-- ever have one set of these present so they never both contribute.
			weaponDps       = 10.00,
			strength        = 1.00,
			expertiseRating = 0.65,
			armorPenRating  = 0.60,
			attackPower     = 0.35,
			stamina         = 0.05,
		},
	},

	-- ============================== Druid (Leather) ==============================
	Balance = {
		role = "dps",
		weights = {
			spellPower  = 1.00,
			hitRating   = 0.85,
			hasteRating = 0.65,
			critRating  = 0.55,
			intellect   = 0.35,
			spirit      = 0.15,
			stamina     = 0.05,
		},
	},
	Feral = {
		role = "dps",
		weights = {
			-- No weaponDps: cat/bear form auto-attacks use a fixed damage value
			-- derived from attack power, not the equipped weapon's actual damage/
			-- speed, so unlike Rogues a Druid's weapon choice is really just about
			-- its stat budget.
			agility         = 1.00,
			hitRating       = 0.85,
			expertiseRating = 0.70,
			critRating      = 0.60,
			hasteRating     = 0.50,
			armorPenRating  = 0.50,
			attackPower     = 0.35,
			stamina         = 0.05,
		},
	},
	Restoration = { -- shared key: Druid AND Shaman Restoration both use this archetype name
		role = "healer",
		weights = {
			spellPower  = 1.00,
			hasteRating = 0.65,
			critRating  = 0.35,
			mp5         = 0.45,
			intellect   = 0.25,
			spirit      = 0.45,
			stamina     = 0.05,
		},
	},

	-- ============================== Warrior (Plate) ==============================
	Arms = {
		role = "dps",
		weights = {
			weaponDps       = 10.00,
			strength        = 1.00,
			hitRating       = 0.85,
			expertiseRating = 0.70,
			critRating      = 0.65,
			armorPenRating  = 0.65,
			hasteRating     = 0.40,
			attackPower     = 0.35,
			stamina         = 0.05,
		},
	},
	Fury = {
		role = "dps",
		weights = {
			weaponDps       = 10.00,
			strength        = 1.00,
			hitRating       = 0.85,
			expertiseRating = 0.70,
			critRating      = 0.55,
			armorPenRating  = 0.60,
			hasteRating     = 0.50,
			attackPower     = 0.35,
			stamina         = 0.05,
		},
	},
	Protection = { -- shared key: Warrior AND Paladin Protection both use this archetype name
		role = "tank",
		weights = {
			stamina         = 1.00,
			defenseRating   = 0.90,
			dodgeRating     = 0.55,
			parryRating     = 0.55,
			blockRating     = 0.55,
			blockValue      = 0.45,
			expertiseRating = 0.50,
			hitRating       = 0.30,
			strength        = 0.20,
			armor           = 0.05,
		},
	},

	-- ============================== Hunter (Mail) ==============================
	BeastMastery = {
		role = "dps",
		weights = {
			weaponDps      = 8.00, -- pet damage carries a lot of BM's output, so raw weapon DPS matters slightly less than for MM/Survival
			agility        = 1.00,
			hitRating      = 0.85,
			critRating     = 0.55,
			hasteRating    = 0.55,
			armorPenRating = 0.45,
			attackPower    = 0.35,
			stamina        = 0.05,
		},
	},
	Marksmanship = {
		role = "dps",
		weights = {
			weaponDps      = 10.00,
			agility        = 1.00,
			hitRating      = 0.85,
			critRating     = 0.65,
			hasteRating    = 0.55,
			armorPenRating = 0.55,
			attackPower    = 0.35,
			stamina        = 0.05,
		},
	},
	Survival = {
		role = "dps",
		weights = {
			weaponDps      = 9.00,
			agility        = 1.00,
			hitRating      = 0.85,
			critRating     = 0.60,
			hasteRating    = 0.55,
			armorPenRating = 0.55,
			attackPower    = 0.35,
			stamina        = 0.05,
		},
	},

	-- ============================== Shaman (Mail) ==============================
	Elemental = {
		role = "dps",
		weights = {
			spellPower  = 1.00,
			hitRating   = 0.85,
			hasteRating = 0.65,
			critRating  = 0.55,
			intellect   = 0.35,
			spirit      = 0.10,
			stamina     = 0.05,
		},
	},
	Enhancement = {
		role = "dps",
		weights = {
			weaponDps       = 10.00,
			agility         = 1.00,
			hitRating       = 0.85,
			expertiseRating = 0.70,
			critRating      = 0.55,
			hasteRating     = 0.60,
			armorPenRating  = 0.50,
			attackPower     = 0.35,
			stamina         = 0.05,
		},
	},

	-- ============================== Paladin (Plate) ==============================
	Retribution = {
		role = "dps",
		weights = {
			weaponDps       = 10.00,
			strength        = 1.00,
			hitRating       = 0.85,
			expertiseRating = 0.65,
			critRating      = 0.60,
			hasteRating     = 0.55,
			armorPenRating  = 0.45,
			attackPower     = 0.35,
			stamina         = 0.05,
		},
	},

	-- ============================== Death Knight (Plate) ==============================
	Blood = {
		role = "tank",
		weights = {
			stamina         = 1.00,
			defenseRating   = 0.85,
			dodgeRating     = 0.55,
			parryRating     = 0.55,
			expertiseRating = 0.55,
			hitRating       = 0.35,
			strength        = 0.30,
			armor           = 0.05,
		},
	},
	Unholy = {
		role = "dps",
		weights = {
			weaponDps       = 10.00,
			strength        = 1.00,
			hitRating       = 0.85,
			expertiseRating = 0.65,
			hasteRating     = 0.60,
			critRating      = 0.50,
			armorPenRating  = 0.55,
			attackPower     = 0.35,
			stamina         = 0.05,
		},
	},

	-- ============================== Rogue (Leather) ==============================
	-- All three specs share the same leather-DPS gear itemization (there's no
	-- separate "healer roll" the way cloth has), so ItemDB.lua lists one shared
	-- rogue gear pool for all three - only the weights and hit cap differ per spec.
	Combat = {
		role = "dps",
		weights = {
			weaponDps        = 10.00,
			agility          = 1.00,
			hitRating        = 0.85,
			expertiseRating  = 0.75,
			hasteRating      = 0.70,
			armorPenRating   = 0.65,
			critRating       = 0.55,
			attackPower      = 0.35,
			stamina          = 0.05,
		},
	},
	Assassination = {
		role = "dps",
		weights = {
			weaponDps        = 10.00,
			agility          = 1.00,
			hitRating        = 0.85,
			critRating       = 0.70,
			expertiseRating  = 0.70,
			armorPenRating   = 0.60,
			hasteRating      = 0.45,
			attackPower      = 0.35,
			stamina          = 0.05,
		},
	},
	Subtlety = {
		role = "dps",
		weights = {
			weaponDps        = 10.00,
			agility          = 1.00,
			hitRating        = 0.80,
			expertiseRating  = 0.65,
			critRating       = 0.60,
			hasteRating      = 0.55,
			armorPenRating   = 0.50,
			attackPower      = 0.35,
			stamina          = 0.05,
		},
	},
}

-- Spell/melee/ranged hit caps vs. a raid boss (3 levels above an 80), reduced by
-- talents that lower the amount of hit needed. tabIndex must match the tab order
-- used in SpecDetect.lua for that class. Melee specs are "dual-wield aware": the
-- cap is 8% single-wielded but 27% dual-wielded, checked by looking at whether the
-- off-hand slot holds an actual weapon (a shield/held item does NOT trigger the
-- dual-wield miss penalty, so Protection specs always stay at the single-wield
-- cap even though their off-hand slot is filled).
local HIT_CAPS = {
	Affliction = {
		ratingType = "spell", basePercent = 17,
		talentReductions = { { tabIndex = 1, talentName = "Suppression", perPoint = 1 } },
	},
	-- Suppression lives on the Affliction tab but reduces spell hit needed
	-- regardless of which tree is actively played, so a Demonology/Destruction
	-- warlock also benefits from it. GetTalentTabInfo only reliably reports the
	-- *active* tab's points in this client, so rather than reading tab 1 for a
	-- character who isn't specced into it, these two read a manual value the
	-- player sets themselves (see the Suppression stepper in UI.lua).
	Demonology = {
		ratingType = "spell", basePercent = 17,
		talentReductions = { { source = "manual", perPoint = 1 } },
	},
	Destruction = {
		ratingType = "spell", basePercent = 17,
		talentReductions = { { source = "manual", perPoint = 1 } },
	},
	Shadow = { ratingType = "spell", basePercent = 17, talentReductions = {} },
	Arcane = { ratingType = "spell", basePercent = 17, talentReductions = {} },
	Fire = { ratingType = "spell", basePercent = 17, talentReductions = {} },
	Elemental = { ratingType = "spell", basePercent = 17, talentReductions = {} },
	Balance = {
		ratingType = "spell", basePercent = 17,
		talentReductions = { { tabIndex = 1, talentName = "Balance of Power", perPoint = 1.5 } },
	},

	Combat = {
		ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27,
		talentReductions = { { tabIndex = 2, talentName = "Precision", perPoint = 1 } },
	},
	Assassination = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} },
	Subtlety = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} },
	Arms = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} },
	Fury = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} },
	Retribution = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} },
	Feral = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} },
	Enhancement = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} },
	Frost = { ratingType = "spell", basePercent = 17, talentReductions = {} },
	-- Frost is shared between Mage (spell) and DK (melee): the entry above is the
	-- Mage spell-hit cap; Death Knight Frost overrides it with the melee cap below
	-- by class, resolved in GetHitCapInfo (a caster spec never reads the melee cap
	-- and vice versa since Scoring.lua only ever asks for the current spec's own
	-- cap).
	Unholy = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} },

	-- Tanks always fight with a one-hand weapon + shield, never dual-wielding.
	Protection = { ratingType = "melee", basePercent = 8, talentReductions = {} },
	Blood = { ratingType = "melee", basePercent = 8, talentReductions = {} },

	-- Hunters only ever have a single ranged weapon slot - no dual-wield variant.
	BeastMastery = { ratingType = "ranged", basePercent = 8, talentReductions = {} },
	Marksmanship = { ratingType = "ranged", basePercent = 8, talentReductions = {} },
	Survival = { ratingType = "ranged", basePercent = 8, talentReductions = {} },
}

-- Death Knight Frost shares its WEIGHTS key with Mage Frost (both named "Frost"),
-- but needs its own melee hit cap distinct from Mage Frost's spell hit cap. Since
-- HIT_CAPS is keyed by spec name and both specs are literally called "Frost", we
-- can't have two entries under one key - so Death Knight Frost's cap is resolved
-- separately by class in GetHitCapInfo below.
local DEATHKNIGHT_FROST_CAP = { ratingType = "melee", dualWieldAware = true, singleWieldPercent = 8, dualWieldPercent = 27, talentReductions = {} }

function StatWeights:GetForSpec(specKey)
	return WEIGHTS[specKey]
end

-- Off-hand slot counts as "dual-wielding a weapon" only if it actually holds a
-- weapon (INVTYPE_WEAPON/INVTYPE_WEAPONOFFHAND) - a shield or a "Held in Off-hand"
-- item (INVTYPE_SHIELD/INVTYPE_HOLDABLE) does not increase miss chance the way a
-- second weapon does.
local function IsDualWieldingWeapon()
	local link = GetInventoryItemLink("player", GetInventorySlotInfo("SecondaryHandSlot"))
	if not link then
		return false
	end
	local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
	return equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONOFFHAND"
end

-- Returns nil if this spec has no hit cap to track (e.g. pure healers).
function StatWeights:GetHitCapInfo(specKey)
	local cap = HIT_CAPS[specKey]
	if specKey == "Frost" then
		local _, classFile = UnitClass("player")
		if classFile == "DEATHKNIGHT" then
			cap = DEATHKNIGHT_FROST_CAP
		end
	end
	if not cap then
		return nil
	end

	local percent = cap.basePercent
	if cap.dualWieldAware then
		percent = IsDualWieldingWeapon() and cap.dualWieldPercent or cap.singleWieldPercent
	end

	for _, reduction in ipairs(cap.talentReductions) do
		local rank
		if reduction.source == "manual" then
			rank = math.min(2, math.max(0, JohnnysGearAdvisor.db.profile.suppressionPoints or 0))
		else
			rank = SpecDetect:GetTalentRankByName(reduction.tabIndex, reduction.talentName)
		end
		percent = percent - (rank * reduction.perPoint)
	end

	return {
		ratingType = cap.ratingType,
		capPercent = percent,
	}
end

-- Current hit percent for the given rating type, read live from the game so we
-- never need to hardcode a rating-per-percent conversion constant.
function StatWeights:GetCurrentHitPercent(ratingType)
	if ratingType == "spell" then
		return GetCombatRatingBonus(CR_HIT_SPELL) or 0
	elseif ratingType == "ranged" then
		return GetCombatRatingBonus(CR_HIT_RANGED) or 0
	else
		return GetCombatRatingBonus(CR_HIT_MELEE) or 0
	end
end

-- Rating needed for 1% of the given hit type, derived live from the character's
-- current rating/percent pair (WotLK hit conversion is linear, no diminishing
-- returns, so this ratio is exact). Falls back to the well-known level-80 constant
-- only when the character currently has zero of that rating to derive a ratio from.
function StatWeights:GetHitRatingPerPercent(ratingType)
	local ratingId, fallback
	if ratingType == "spell" then
		ratingId, fallback = CR_HIT_SPELL, 26.232
	elseif ratingType == "ranged" then
		ratingId, fallback = CR_HIT_RANGED, 32.79
	else
		ratingId, fallback = CR_HIT_MELEE, 32.79
	end

	local rating = GetCombatRating(ratingId) or 0
	local percent = GetCombatRatingBonus(ratingId) or 0
	if rating > 0 and percent > 0 then
		return rating / percent
	end
	return fallback
end
