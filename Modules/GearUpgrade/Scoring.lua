JohnnysGearAdvisor.Scoring = {}
local Scoring = JohnnysGearAdvisor.Scoring
local StatWeights = JohnnysGearAdvisor.StatWeights
local ItemDB = JohnnysGearAdvisor.ItemDB
local TooltipScan = JohnnysGearAdvisor.TooltipScan
local Scanner = JohnnysGearAdvisor.Scanner
local Eligibility = JohnnysGearAdvisor.Eligibility

-- Hit rating is worth full weight up to the character's remaining headroom below
-- their spec's hit cap, and a small residual weight past it (overcapped hit is
-- wasted, but not literally worthless - some fights call for slightly different
-- effective caps). This is evaluated against the character's *current* total hit,
-- not a full re-simulation of the whole loadout with the item swapped in - a
-- reasonable approximation for "don't recommend stacking hit past the cap" without
-- needing to simulate every other equipped slot at once.
local function HitValue(hitRatingPoints, specKey)
	local specData = StatWeights:GetForSpec(specKey)
	local fullWeight = specData and specData.weights.hitRating
	if not fullWeight then
		return 0
	end

	local capInfo = StatWeights:GetHitCapInfo(specKey)
	if not capInfo then
		-- No cap tracked for this spec (e.g. healer role) - treat like any other stat.
		return hitRatingPoints * fullWeight
	end

	local currentPercent = StatWeights:GetCurrentHitPercent(capInfo.ratingType)
	local ratingPerPercent = StatWeights:GetHitRatingPerPercent(capInfo.ratingType)
	local remainingRating = math.max(0, capInfo.capPercent - currentPercent) * ratingPerPercent
	local overflowWeight = fullWeight * 0.05

	if hitRatingPoints <= remainingRating then
		return hitRatingPoints * fullWeight
	end

	local underCap = remainingRating
	local overCap = hitRatingPoints - remainingRating
	return (underCap * fullWeight) + (overCap * overflowWeight)
end

function Scoring:ComputeScore(stats, specKey)
	if not stats then
		return 0
	end
	local specData = StatWeights:GetForSpec(specKey)
	if not specData then
		return 0
	end

	local score = 0
	for statKey, value in pairs(stats) do
		if statKey == "hitRating" then
			score = score + HitValue(value, specKey)
		else
			local weight = specData.weights[statKey]
			if weight then
				score = score + (value * weight)
			end
		end
	end
	return score
end

-- Returns nil if this spec has no item database yet, otherwise:
-- equippedScore (number), candidates (array of { itemId, source, score, delta }
-- sorted best-delta-first). A candidate's score may be 0/omitted-from-list if its
-- item isn't cached client-side yet - it'll appear next time the slot is scored
-- (e.g. next hover) once the game finishes fetching it.
function Scoring:GetUpgradesForSlot(slotName, specKey)
	local specData = StatWeights:GetForSpec(specKey)
	if not specData then
		return nil
	end

	local equippedStats = Scanner:GetEquippedStats(slotName)
	local equippedScore = self:ComputeScore(equippedStats, specKey)

	local dbKey = Scanner:DBKeyForSlot(slotName)
	local dbCandidates = ItemDB:GetCandidatesForSlot(dbKey)

	local candidates = {}
	local pendingCount = 0
	for _, entry in ipairs(dbCandidates) do
		local stats, restrictedClasses = TooltipScan:GetStats(entry.itemId)
		if stats then
			if Eligibility:IsRoleAppropriate(stats, specKey) and Eligibility:IsClassRestrictionSatisfied(restrictedClasses) then
				local score = self:ComputeScore(stats, specKey)
				table.insert(candidates, {
					itemId = entry.itemId,
					source = entry.source,
					cost = entry.cost,
					score = score,
					delta = score - equippedScore,
				})
			end
		else
			pendingCount = pendingCount + 1
		end
	end

	table.sort(candidates, function(a, b)
		return a.delta > b.delta
	end)

	return equippedScore, candidates, pendingCount
end
