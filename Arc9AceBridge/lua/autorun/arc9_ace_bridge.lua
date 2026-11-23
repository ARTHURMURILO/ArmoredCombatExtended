--[[
	ARC9 <-> ACE bridge — bootstrap.

	Server-side only: clients keep stock ARC9 (sounds, animations, recoil,
	attachment UI, prediction effects). The server replaces the projectile with
	an ACE bullet, so penetration, armour, vehicles and ballistics are ACE's.

	Addon: addons/arc9_ace_bridge/
	Requires: ARC9 Weapon Base (workshop 2910505837), ACE (workshop 3333669763)
	Optional: ARC9 Escape From Tarkov packs (this is the first mapped pack).
]]

ARC9ACE = ARC9ACE or {}

if CLIENT then return end

local function loadModule(path)
	if file.Exists(path, "LUA") then
		include(path)
		return true
	end
	print("[ARC9-ACE] missing module: " .. path)
	return false
end

loadModule("arc9_ace_bridge/sh_config.lua")
loadModule("arc9_ace_bridge/sh_convert.lua")
loadModule("arc9_ace_bridge/sh_eft_ammo_map.lua")
loadModule("arc9_ace_bridge/sv_fire.lua")
loadModule("arc9_ace_bridge/sv_damage.lua")

hook.Add("InitPostEntity", "ARC9ACE_Bootstrap", function()
	if not ARC9 then
		print("[ARC9-ACE] ARC9 not found, bridge inactive")
		return
	end
	if not ACE or not ACE_CreateBullet then
		print("[ARC9-ACE] ACE not found, bridge inactive")
		return
	end

	ARC9ACE.InitConVars()
	ARC9ACE.InitDamageConVars()
	ARC9ACE.PatchWeapons()
	ARC9ACE.InstallDamageOverride()
	ARC9ACE.InstallCleanup()
	ARC9ACE.InstallChatDiagnostics()

	print(string.format(
		"[ARC9-ACE] 40K/Tarkov ACE projectile bridge ACTIVE (scope=%s, player damage=%s)",
		GetConVar("arc9ace_scope"):GetInt() == 1 and "EFT pack" or "all ARC9",
		GetConVar("arc9ace_player_damage"):GetBool() and "EFT/ARC9" or "ACE"
	))

	-- Give the server a couple of seconds to finish loading addons, then dump
	-- the mapping audit into the journal.
	timer.Simple(5, function()
		local ok, err = pcall(ARC9ACE.Audit)
		if not ok then
			print("[ARC9-ACE] audit failed: " .. tostring(err))
		end
	end)
end)
