--[[---------------------------------------------------------
	Shared selectable-ammunition base for ACE launchers.

	Derived weapons declare SWEP.AmmoDefs (presets with their own editable
	parameters), implement BuildAmmoData/ApplyBuiltData, and get:

	  * an R-key menu with a preset list, editable sliders and dropdowns
	  * server-authoritative selection with sanitising and rate limiting
	  * an NWString sync so every player sees the loaded round
	  * HUD/notification summary helpers

	The menu lives in cl_menu.lua, the network glue in init.lua.
-----------------------------------------------------------]]

SWEP.Base = "weapon_ace_base"
SWEP.Spawnable = false
SWEP.PrintName = "ACE Launcher Base"
SWEP.Category = "ACE Weapons"

--- Preset table, filled by EnsureAmmoDefs on the derived weapon.
SWEP.AmmoDefs = {}
--- Ordered list of preset ids used by the menu.
SWEP.AmmoOrder = {}
--- Preset id loaded when nothing else is selected.
SWEP.DefaultAmmo = nil

SWEP.MenuTitle = "Ammunition"
SWEP.MenuSubtitle = ""
SWEP.MenuListHeaders = { "Round", "Speed", "Effect" }

SWEP.AmmoNetChannel = "ACE_AmmoMenu_Apply"
SWEP.AmmoStateKey = "ACE_AmmoMenu_State"

local MAX_PARAMETER = 1000000

local function CopyTable( source )
	local copy = {}

	for key, value in pairs( source or {} ) do
		copy[key] = value
	end

	return copy
end


--- Makes sure the preset table exists. Derived weapons override this when the
-- definitions come from a table that may not be loaded yet (ACE armory data).
-- @return boolean True when the presets are available.
function SWEP:EnsureAmmoDefs()
	return true
end


--- Looks up a preset definition, initialising the preset table if needed.
-- @param ammoType string Preset id.
-- @return table|nil Preset definition.
function SWEP:GetAmmoDef( ammoType )
	self:EnsureAmmoDefs()

	return ammoType and self.AmmoDefs[ammoType] or nil
end


--- Returns the id of the preset that should be loaded by default.
-- @return string|nil Preset id.
function SWEP:GetDefaultAmmoType()
	return self.DefaultAmmo
end


--- Builds a fresh parameter table seeded from a preset.
-- @param ammoType string Preset id.
-- @return table|nil Editable parameters.
function SWEP:GetPresetParams( ammoType )
	local def = self:GetAmmoDef( ammoType )

	if not def then return nil end

	local params = CopyTable( def.preset )
	params.Type = ammoType

	return params
end


--- Clamps and validates a client-supplied parameter table against a preset.
-- @param ammoType string Preset id.
-- @param raw table Raw values from the network or a preset.
-- @return table|nil Safe parameters.
function SWEP:SanitizeParams( ammoType, raw )
	local def = self:GetAmmoDef( ammoType )

	if not def or type( raw ) ~= "table" then return nil end

	local limits = def.limits or {}
	local params = { Type = ammoType }

	for key, value in pairs( def.preset ) do
		if type( value ) == "number" then
			local range = limits[key] or { 0, MAX_PARAMETER }
			local number = tonumber( raw[key] )

			if not number or number ~= number then
				number = value
			end

			params[key] = math.Clamp( number, range[1], range[2] )
		else
			params[key] = raw[key] ~= nil and tostring( raw[key] ) or value
		end
	end

	for _, dropdown in ipairs( def.dropdowns or {} ) do
		local choice = tostring( raw[dropdown.key] or "" )
		local matched

		for _, option in ipairs( dropdown.options ) do
			if tostring( option ) == choice then
				matched = option
				break
			end
		end

		params[dropdown.key] = matched or def.preset[dropdown.key] or dropdown.options[1]
	end

	return params
end


--- Converts parameters into ready-to-use bullet/counter data. Realm aware:
-- the client copy also carries the GUI ranges the sliders read.
-- @param params table Editable parameters.
-- @return table|nil Converted data.
function SWEP:BuildAmmoData( params ) -- luacheck: ignore
	return nil
end


--- Stamps converted data onto the weapon and, on the server, onto the fake
-- crate ACE uses for bullet visuals. Derived weapons may extend this.
-- @param data table Converted data.
function SWEP:ApplyBuiltData( data )
	self.BulletData = data
end


--- Rebuilds the loaded projectile from the current parameters, falling back to
-- the default preset if the conversion fails.
-- @return boolean True when bullet data was rebuilt.
function SWEP:RefreshBulletData()
	local params = self.AmmoParams or self:GetPresetParams( self:GetDefaultAmmoType() )

	if not params then return false end

	local data
	local ok, result = pcall( self.BuildAmmoData, self, params )

	if ok then data = result end

	if not data then
		params = self:GetPresetParams( self:GetDefaultAmmoType() )

		if not params then return false end

		self.AmmoParams = params

		ok, result = pcall( self.BuildAmmoData, self, params )
		if ok then data = result end
	end

	if not data then return false end

	self.BulletData = data
	self:ApplyBuiltData( data )

	return true
end


--- Human readable one-line summary of the loaded round.
-- @return string|nil Summary, or nil to use the base weapon's display.
function SWEP:GetAmmoSummary()
	return nil
end


--- Rows shown in the menu's stat block.
-- @param data table Converted data for the current parameters.
-- @return table List of { title = string, value = string } rows.
function SWEP:GetAmmoStatRows( data ) -- luacheck: ignore
	return {}
end


--- Short description used by the preset list for one entry.
-- @param ammoType string Preset id.
-- @param params table|nil Parameters (defaults to the preset's own values).
-- @return string, string Column values for the list.
function SWEP:GetRowBrief( ammoType, params ) -- luacheck: ignore
	return "", ""
end


--- Applies a sanitised selection, rebuilding the projectile and syncing it.
-- @param ammoType string Preset id.
-- @param params table|nil Sanitised parameters (defaults to the preset).
-- @param owner Player|nil Player to notify.
-- @return boolean True when the selection was accepted.
function SWEP:ApplyAmmo( ammoType, params, owner )
	local def = self:GetAmmoDef( ammoType )
	if not def then return false end

	self.AmmoParams = params or self:GetPresetParams( ammoType )
	self:RefreshBulletData()
	self:PushAmmoState()
	self:DoAmmoStatDisplay()

	if IsValid( owner ) and owner:IsPlayer() then
		owner:EmitSound( "items/ammo_pickup.wav", 60, math.random( 95, 105 ) )
	end

	return true
end


--- Serialises the current selection into an NWString for every realm.
function SWEP:PushAmmoState()
	if not SERVER then return end
	if not self.AmmoParams then return end

	local ok, json = pcall( util.TableToJSON, self.AmmoParams )
	if not ok or type( json ) ~= "string" then return end

	self:SetNWString( self.AmmoStateKey, json )
end


--- Rebuilds the client copy of the projectile from a synced NWString.
-- @param state string Serialised parameters.
function SWEP:ApplyAmmoState( state )
	if type( state ) ~= "string" or state == "" then return end

	local ok, params = pcall( util.JSONToTable, state )
	if not ok or type( params ) ~= "table" then return end

	params = self:SanitizeParams( params.Type, params )
	if not params then return end

	self.AmmoParams = params
	self:RefreshBulletData()
end


--- Seeds the loaded projectile from the default preset.
function SWEP:InitBulletData()
	local ammoType = self.AmmoParams and self.AmmoParams.Type or self:GetDefaultAmmoType()

	self.AmmoParams = self.AmmoParams or self:GetPresetParams( ammoType )

	if self.AmmoParams then
		self:RefreshBulletData()
	else
		self.BulletData = {}
	end
end


--- Notification shown on deploy and when a round is loaded. Derived weapons
-- describe their own round because ACE's stock line assumes a gunpowder shell.
function SWEP:DoAmmoStatDisplay()
	local summary = self:GetAmmoSummary()

	if summary and IsValid( self:GetOwner() ) then
		ACE_SendNotification( self:GetOwner(), summary, 6 )
	end
end


if CLIENT then
	--- Polls the synced NWString and rebuilds the local projectile when it
	-- changes. Keeping this polled (instead of a net.Receive hook) means late
	-- joiners and spectators always converge on the server's selection.
	function SWEP:OnThink()
		if self.AmmoMenuHeldBlock then
			local menuOwner = self:GetOwner()

			if not IsValid( menuOwner ) or not menuOwner:KeyDown( IN_RELOAD ) then
				self.AmmoMenuHeldBlock = false
			end
		end

		if not self.m_bInitialized then return end

		local state = self:GetNWString( self.AmmoStateKey, "" )

		if state == "" or state == self.SyncedAmmoState then return end

		self.SyncedAmmoState = state
		self:ApplyAmmoState( state )
	end


	--- R with a full chamber opens the ammunition menu; otherwise the base
	-- weapon's reload logic runs.
	function SWEP:Reload()
		if self:Clip1() >= ( self.Primary.ClipSize or 0 ) and self.OpenAmmoMenu then
			self:OpenAmmoMenu()

			return
		end

		local base = weapons.Get( "weapon_ace_base" )

		if base and base.Reload then
			return base.Reload( self )
		end
	end


	function SWEP:Holster()
		if self.CloseAmmoMenu then
			self:CloseAmmoMenu()
		end

		local base = weapons.Get( "weapon_ace_base" )

		if base and base.Holster then
			return base.Holster( self )
		end

		return true
	end


	function SWEP:OnRemove()
		if self.CloseAmmoMenu then
			self:CloseAmmoMenu()
		end

		local base = weapons.Get( "weapon_ace_base" )

		if base and base.OnRemove then
			base.OnRemove( self )
		end
	end
end
