AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_menu.lua" )

include( "shared.lua" )

util.AddNetworkString( "ACE_AmmoMenu_Apply" )

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
