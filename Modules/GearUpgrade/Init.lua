-- AceAddon lifecycle hooks for JohnnysGearAdvisor - the addon object itself
-- is the module now (standalone addon, no Hub sub-module lookup needed).

function JohnnysGearAdvisor:OnEnable()
	self:RegisterEvent("PLAYER_TALENT_UPDATE", "OnSpecChanged")
	self:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED", "OnSpecChanged")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnSpecChanged")
end

function JohnnysGearAdvisor:OnDisable()
	self:UnregisterAllEvents()
end

function JohnnysGearAdvisor:OnSpecChanged()
	if JohnnysGearAdvisor.UI then
		JohnnysGearAdvisor.UI:OnSpecChanged()
	end
end

function JohnnysGearAdvisor:Toggle()
	JohnnysGearAdvisor.UI:Toggle()
end
