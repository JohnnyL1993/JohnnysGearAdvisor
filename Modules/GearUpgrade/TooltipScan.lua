-- 3.3.5a has no GetItemStats API, so we read an item's stats the same way the
-- bundled Pawn addon does: render it into a hidden tooltip and pattern-match the
-- text lines. Used both for the currently-equipped items and for ItemDB candidates
-- we don't own, so stat numbers always come from the live tooltip (accurate for
-- this exact server) instead of hand-typed data that could drift or be wrong.
JohnnysGearAdvisor.TooltipScan = {}
local TooltipScan = JohnnysGearAdvisor.TooltipScan

local scanTooltip = CreateFrame("GameTooltip", "GearAdvisorScanTooltip", nil, "GameTooltipTemplate")
scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

-- Order matters: check more specific patterns (e.g. "Spell Power") before ones
-- that could partially overlap. All patterns are case-sensitive to the English
-- client tooltip text used in 3.3.5a.
local LINE_PATTERNS = {
	{ key = "spellPower", pattern = "Increases spell power by (%d+)" },
	{ key = "spellPower", pattern = "^%+(%d+) Spell Power" },
	{ key = "attackPower", pattern = "Increases attack power by (%d+)" },
	{ key = "hitRatingSpell", pattern = "Improves your chance to hit with spells by [%d%.]+%%.-%((%d+)%)" },
	{ key = "hitRating", pattern = "Improves hit rating by (%d+)" },
	{ key = "hitRating", pattern = "Increases your hit rating by (%d+)" },
	{ key = "critRating", pattern = "Improves critical strike rating by (%d+)" },
	{ key = "critRating", pattern = "Increases your critical strike rating by (%d+)" },
	{ key = "hasteRating", pattern = "Improves haste rating by (%d+)" },
	{ key = "hasteRating", pattern = "Increases your haste rating by (%d+)" },
	{ key = "expertiseRating", pattern = "Increases your expertise rating by (%d+)" },
	{ key = "armorPenRating", pattern = "Increases your armor penetration rating by (%d+)" },
	-- PVP gear detection (Modules\RaidCompUI\UI.lua's GearScore lookup section)
	-- keys off this - any
	-- equipped item with a resilience line is treated as a PVP piece.
	{ key = "resilienceRating", pattern = "Improves your resilience rating by (%d+)" },
	{ key = "resilienceRating", pattern = "Increases your resilience rating by (%d+)" },
	-- Tank avoidance stats (Protection Warrior/Paladin, Blood DK, Feral bear Druid).
	{ key = "defenseRating", pattern = "Increases defense rating by (%d+)" },
	{ key = "dodgeRating", pattern = "Increases dodge rating by (%d+)" },
	{ key = "parryRating", pattern = "Increases parry rating by (%d+)" },
	{ key = "blockRating", pattern = "Increases your shield block rating by (%d+)" },
	{ key = "blockValue", pattern = "Increases the block value of your shield by (%d+)" },
	{ key = "armor", pattern = "^%+(%d+) Armor" },
	{ key = "mp5", pattern = "Restores (%d+) mana per 5 sec" },
	{ key = "stamina", pattern = "^%+(%d+) Stamina" },
	{ key = "intellect", pattern = "^%+(%d+) Intellect" },
	{ key = "spirit", pattern = "^%+(%d+) Spirit" },
	{ key = "strength", pattern = "^%+(%d+) Strength" },
	{ key = "agility", pattern = "^%+(%d+) Agility" },
	-- Weapon DPS ("(36.1 damage per second)") was previously not read at all, so
	-- two weapons were compared purely on their secondary stat lines - a weapon
	-- with genuinely higher damage could still score as "worse" if it happened to
	-- roll fewer/smaller bonus stats. This picks up the game's own precomputed
	-- DPS figure directly off the tooltip.
	{ key = "weaponDps", pattern = "%(([%d%.]+) damage per second%)" },
}

-- "Use:" effects and "Chance on hit/cast" procs grant a *temporary* buff (e.g. "Use:
-- Increases your critical strike rating by 920 for 20 sec"), not a permanent stat.
-- Without this filter, the number in a temporary proc line gets counted as if it
-- were a flat, permanent stat on the item - wildly overvaluing on-use trinkets like
-- Nevermelting Ice Crystal over items that are actually better equipped full-time.
local function IsTemporaryEffectLine(text)
	return text:find("^Use:") or text:find("Chance on") or text:find(" for %d+ sec")
end

-- Builds a minimal item link from a bare item ID, good enough for SetHyperlink to
-- resolve base item stats (random-enchant/socket-bonus items aren't relevant to
-- our curated ItemDB candidates, only to equipped-item fallback scanning).
local function LinkFromItemId(itemId)
	return ("item:%d:0:0:0:0:0:0:0"):format(itemId)
end

-- Some armor (mainly tier-token gear) is hard-locked to one specific class the
-- same way weapon proficiency is, shown on the tooltip as e.g. "Classes: Mage".
-- Most armor has no such line (any wearer of that armor type can equip it), so
-- this is only present on the minority of pieces that are actually restricted.
local CLASS_RESTRICTION_PATTERN = "^Classes: (.+)$"

-- Scans an item (by itemId or an existing item link) and returns a stats table,
-- e.g. { intellect = 91, spirit = 78, spellPower = 92, hitRating = 40, ... },
-- plus the raw "Classes: X, Y" restriction text as a second value (nil if the
-- item isn't class-restricted). Returns nil if the item isn't cached client-side
-- yet. Calling GetItemInfo below queues a server request for it; 3.3.5a has no
-- "item info received" event, so callers displaying this in the UI should just
-- retry after a short delay (see UI.lua's ScheduleRefresh).
function TooltipScan:GetStats(itemIdOrLink)
	local link = itemIdOrLink
	if type(itemIdOrLink) == "number" then
		local name = GetItemInfo(itemIdOrLink)
		if not name then
			return nil -- not cached yet
		end
		link = LinkFromItemId(itemIdOrLink)
	end

	scanTooltip:ClearLines()
	scanTooltip:SetHyperlink(link)

	local stats = {}
	local restrictedClasses
	for i = 2, scanTooltip:NumLines() do
		local fontString = _G["GearAdvisorScanTooltipTextLeft" .. i]
		local text = fontString and fontString:GetText()
		if text then
			restrictedClasses = restrictedClasses or text:match(CLASS_RESTRICTION_PATTERN)
			if not IsTemporaryEffectLine(text) then
				for _, entry in ipairs(LINE_PATTERNS) do
					local value = text:match(entry.pattern)
					if value then
						local key = entry.key
						-- Spell/melee hit rating share the same "hitRating" bucket; a caster
						-- item will only ever emit one of the two hit-rating patterns.
						if key == "hitRatingSpell" then
							key = "hitRating"
						end
						stats[key] = (stats[key] or 0) + tonumber(value)
					end
				end
			end
		end
	end

	return stats, restrictedClasses
end
