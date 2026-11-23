AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_menu.lua" )

include( "shared.lua" )

util.AddNetworkString( "ACE_AmmoMenu_Apply" )

CreateConVar( "ace_launcher_debug", "1", FCVAR_ARCHIVE,
	"Print launcher ammunition/guidance debug lines to the server console." )

-- Diagnostics the player can request in chat: prints the loaded selection and
-- the last launch result to their console so bugs can be reported precisely.
hook.Add( "PlayerSay", "ACE_LauncherAmmoDiagnostics", function( ply, text )
	local command = string.lower( string.Trim( text or "" ) )

	if command ~= "!launcher" and command ~= "!ammo" then return end

	local weapon = ply:GetActiveWeapon()

	if not IsValid( weapon ) or not weapon.AmmoDefs then
		ply:PrintMessage( HUD_PRINTCONSOLE, "[ACE-Launcher] no launcher equipped" )

		return ""
	end

	local params = weapon.AmmoParams or {}
	local data = weapon.BulletData or {}

	ply:PrintMessage( HUD_PRINTCONSOLE, string.format(
		"[ACE-Launcher] %s | selection=%s | guidance=%s | calibre=%s cm | mv=%s m/s | last=%s",
		weapon:GetClass(),
		tostring( params.Type ),
		tostring( params.Guidance or "-" ),
		tostring( data.Caliber ),
		tostring( data.MuzzleVel and math.floor( data.MuzzleVel ) or "-" ),
		tostring( weapon.LastLaunchInfo or "none" ) ) )

	return ""
end )

net.Receive( "ACE_AmmoMenu_Apply", function( _, ply )
	local weapon = net.ReadEntity()

	if not IsValid( weapon ) or not weapon.ApplyAmmo or not weapon.SanitizeParams then return end
	if weapon:GetOwner() ~= ply then return end
	if weapon.NextAmmoSwap and weapon.NextAmmoSwap > CurTime() then return end

	weapon.NextAmmoSwap = CurTime() + 0.2

	local ammoType = net.ReadString()
	local raw = net.ReadString()
	local ok, params = pcall( util.JSONToTable, raw )

	if not ok or type( params ) ~= "table" then return end

	params = weapon:SanitizeParams( ammoType, params )

	if params then
		weapon:ApplyAmmo( ammoType, params, ply )
	end
end )

DEFINE_BASECLASS( "weapon_ace_base" )

function SWEP:Initialize()
	BaseClass.Initialize( self )
	self:PushAmmoState()
end
