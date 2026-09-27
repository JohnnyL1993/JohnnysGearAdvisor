JohnnysGearAdvisor = LibStub("AceAddon-3.0"):NewAddon("JohnnysGearAdvisor", "AceConsole-3.0", "AceEvent-3.0")

local defaults = {
	profile = {
		trackingList = {},
		-- Per-window scale/opacity (see Modules\WindowSettings.lua).
		windowSettings = {},
		-- Manual Suppression talent points for Demonology/Destruction hit-cap
		-- math (see StatWeights.lua's HIT_CAPS "manual" reduction source).
		suppressionPoints = 0,
	},
}

function JohnnysGearAdvisor:OnInitialize()
	-- Per-character (name + realm) profile, so each character/realm keeps its own
	-- tracking list without any custom realm-switch handling. NOTE: passing `true`
	-- here (as opposed to omitting the argument) tells AceDB-3.0 to use a single
	-- shared profile literally named "Default" for every character - the opposite
	-- of what we want. Leaving the argument out makes it fall back to a
	-- per-character/realm profile key automatically.
	self.db = LibStub("AceDB-3.0"):New("JohnnysGearAdvisorDB", defaults)

	self:RegisterChatCommand("gearadvisor", "OnSlashCommand")
	self:RegisterChatCommand("ga", "OnSlashCommand")
end

function JohnnysGearAdvisor:OnSlashCommand(input)
	self:Toggle()
end
