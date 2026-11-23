--[[---------------------------------------------------------
	XM25 - 25mm airburst grenade launcher with selectable ammunition.

	The launcher itself is unchanged: right click lases a range and sets the
	round's fuse delay so the shell bursts over cover. What changed is the
	ammunition: every round is built through ACE's real round conversion
	against a data-only gun definition, and the player picks and tunes the
	round from an R-key menu (HEAT, HE, AP, APHE, HP, HVAP and APDS).
-----------------------------------------------------------]]

SWEP.PrintName = "XM25"
SWEP.Base = "weapon_ace_ammomenu"
SWEP.Category = "ACE Weapons"
SWEP.SubCategory = "Special"
SWEP.Purpose = "Lob HE behind cover"
SWEP.Instructions	= "Left click to shoot. Right click while sprinting to scope, Right click to lase. Press R with a round loaded to open the ammunition menu."
SWEP.Spawnable = true
SWEP.Slot = 3 --Which inventory column the weapon appears in
SWEP.SlotPos = 1 --Priority in which the weapon appears, 1 tries to put it at the top


--Main settings--
SWEP.FireRate = 3 --Rounds per second

SWEP.Primary.ClipSize = 5
SWEP.Primary.DefaultClip = 40
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "SMG1_Grenade"
SWEP.Primary.Sound = "ace_weapons/sweps/multi_sound/scout_multi.mp3"
SWEP.Primary.LightScale = 500 --Muzzleflash light radius
SWEP.Primary.BulletCount = 1 --Number of bullets to fire each shot, used for shotguns

SWEP.ReloadSound = "weapons/ar2/npc_ar2_reload.wav" --Sound other players hear when you reload - this is NOT your first-person sound
										--Most models have a built-in first-person reload sound

SWEP.ZoomFOV = 35
SWEP.HasScope = true --True if the weapon has a sniper-style scope


--Recoil (crosshair movement) settings--
--"Heat" is a number that represents how long you've been firing, affecting how quickly your crosshair moves upwards
SWEP.HeatReductionRate = 12 --Heat loss per second when not firing
SWEP.HeatReductionDelay = 0
SWEP.HeatPerShot = 8 --Heat generated per shot
SWEP.HeatMax = 8 --Maximum heat - determines max rate at which recoil is applied to eye angles
				--Also determines point at which random spread is at its highest intensity
				--HeatMax divided by HeatPerShot gives you how many shots until you reach MaxSpread

SWEP.RecoilSideBias = 0.3 --How much the recoil is biased to one side proportional to vertical recoil
						--Positive numbers bias to the right, negative to the left

SWEP.ZoomRecoilBonus = 0.45 --Reduce recoil by this amount when zoomed or scoped
SWEP.CrouchRecoilBonus = 0.5 --Reduce recoil by this amount when crouching
SWEP.ViewPunchAmount = 2 --Degrees to punch the view upwards each shot - does not actually move crosshair, just a visual effect


--Spread (aimcone) settings--
SWEP.BaseSpread = 0 --First-shot random spread, in degrees
SWEP.MaxSpread = 4 --Maximum added random spread from heat value, in degrees
					--If HeatMax is 0 this will be ignored and only BaseSpread will be taken into account (AT4 for example)
SWEP.MovementSpread = 2 --Increase aimcone to this many degrees when sprinting at full speed
SWEP.UnscopedSpread = 0.75 --Spread, in degrees, when unscoped with a scoped weapon


--Model settings--
SWEP.ViewModelFlip = false
SWEP.ViewModel = "models/weapons/v_xm25.mdl"
SWEP.WorldModel = "models/weapons/w_xm25.mdl"
SWEP.HoldType = "ar2"
SWEP.DeployDelay = 4 --Time before you can fire after deploying the weapon
SWEP.CSMuzzleFlashes = true

SWEP.FuseDelay = 0

SWEP.CarrySpeedMul			= 0.6

--Resolved at call time so the base weapon's table is available no matter how
--the loader reorders weapon files.
local BASE_WEAPON = "weapon_ace_base"

local function GetBaseWeapon()
	return weapons.Get( BASE_WEAPON ) or {}
end

function SWEP:SetupDataTables()
	local base = GetBaseWeapon()

	if base.SetupDataTables then
		base.SetupDataTables( self )
	end

	self:NetworkVar("Float", 0, "FuseDelay")
	self:NetworkVar("Float", 1, "Distance")
	self:NetworkVar("Float", 2, "Px")
--	self:NetworkVar("Float", 3, "Py") --Unused Var
	self:NetworkVar("Float", 3, "Pg")
end

--- Speed used for the laser range-finder's airburst timing.
-- @return number Projectile speed in m/s.
function SWEP:GetFuseVelocity()
	return math.max( self.BulletData and self.BulletData.MuzzleVel or 184.871, 1 )
end


function SWEP:OnPrimaryAttack()
	self.BulletData.Owner = self:GetOwner()
	self.BulletData.Gun = self
	self.BulletData.FuseLength = self.FuseDelay

end

function SWEP:SecondaryAttack()
	local owner = self:GetOwner()

	if owner:IsSprinting() then
		self:OnSecondaryAttack()

		if SERVER and not self.Reloading then
			local ZS = not self:GetZoomState()
			self:SetZoomState(ZS)
			self:SetOwnerZoomSpeed(ZS)
			owner:EmitSound("npc/turret_floor/click1.wav",75,75)
		end

	else

			if CLIENT then return end

		--self:EmitSound("acf_extra/airfx/satellite_target.wav",35,35)
		owner:EmitSound("npc/turret_floor/ping.wav",100,21)

			local RangeTrace = util.QuickTrace(owner:GetShootPos(), owner:GetAimVector() * 50000, {owner})

			if RangeTrace.Hit then
				local difpos = RangeTrace.HitPos - owner:GetShootPos()
				local XM25dist = difpos:Length() / 39.37
				local Xdist = ( difpos * Vector(1,1,0) ):Length() / 39.37
	--			local Ydist = ( (owner:GetShootPos().z) - RangeTrace.HitPos.z ) / 39.37 --unused
				local fuseVelocity = self:GetFuseVelocity()
				local time = (XM25dist + 2.5) / fuseVelocity

				self.FuseDelay = time > 0.07 and time or 0
				self:SetFuseDelay(self.FuseDelay)
				self:SetDistance(XM25dist)
				self:SetPx(Xdist)
	--			self:SetPy(Ydist) --unused
				self:SetPg(GetConVar("sv_gravity"):GetInt() * -1)
			end

			ACE_SendNotification(owner, "Fuse Delay: " .. (self.FuseDelay > 0 and (math.Round(self.FuseDelay * self:GetFuseVelocity()) .. " m") or "None"), 2)
			return

	end
end


--Ammunition--
--Every round is converted through ACE's round conversion pipeline, the same
--one ammo crates use, against a data-only gun definition. "25mmAC"
--(lua/acf/shared/guns/launcher_ammo.lua) reuses the 20mm autocannon's compact
--case limits with a heavier 25mm bore, which is what bounds the lengths and
--powder charges below.
local AMMO_GUN_ID = "25mmAC"
local METERS_TO_INCHES = 39.37
local BLAST_RADIUS_EXPONENT = 0.33
local BLAST_RADIUS_SCALE = 8
local SLUG_LIMIT_VELOCITY = 999999

local function FormatMass( mass )
	if mass >= 1 then return string.format( "%.2f kg", mass ) end

	return string.format( "%d g", math.floor( mass * 1000 + 0.5 ) )
end

SWEP.DefaultAmmo = "HEAT"
SWEP.AmmoOrder = { "HEAT", "HE", "AP", "APHE", "HP", "HVAP", "APDS" }

SWEP.MenuTitle = "XM25 ammunition"
SWEP.MenuSubtitle = "25mm grenade launcher - autocannon-pattern rounds"
SWEP.MenuListHeaders = { "Round", "Velocity", "Effect" }


--Sliders are shared between presets; the ranges come from the converted round
--so the editor can never offer more than the case and shell walls allow.
local PROJECTILE_LENGTH_SLIDER = {
	key = "ProjLength",
	title = "Projectile length",
	suffix = "cm",
	decimals = 1,
	min = function( data ) return data.MinProjLength or 0.01 end,
	max = function( data ) return math.max( data.MaxProjLength or 32, data.MinProjLength or 0.01 ) end,
	info = function( data )
		return string.format( "%d g projectile", math.floor( ( data.ProjMass or 0 ) * 1000 + 0.5 ) )
	end,
}

local PROPELLANT_LENGTH_SLIDER = {
	key = "PropLength",
	title = "Propellant length",
	suffix = "cm",
	decimals = 1,
	min = function( data ) return data.MinPropLength or 0.01 end,
	max = function( data ) return math.max( data.MaxPropLength or 40, data.MinPropLength or 0.01 ) end,
	info = function( data )
		return string.format( "%d g propellant", math.floor( ( data.PropMass or 0 ) * 1000 + 0.5 ) )
	end,
}

local FILLER_SLIDER = {
	key = "Data5",
	title = "Filler volume",
	suffix = "cm3",
	decimals = 1,
	min = 0,
	max = function( data ) return math.max( data.MaxFillerVol or 0, 0.1 ) end,
	info = function( data )
		return string.format( "%d g filler", math.floor( ( data.FillerMass or 0 ) * 1000 + 0.5 ) )
	end,
}

local CAVITY_SLIDER = {
	key = "Data5",
	title = "Hollow point cavity",
	suffix = "cm3",
	decimals = 1,
	min = 0,
	max = function( data ) return math.max( data.MaxCavVol or 0, 0.1 ) end,
	info = function( data )
		return string.format( "%.1f mm expanded", ( data.ExpCaliber or 0 ) * 10 )
	end,
}

local CONE_ANGLE_SLIDER = {
	key = "Data6",
	title = "Cone angle",
	suffix = "deg",
	decimals = 0,
	min = 0,
	max = function( data ) return math.max( math.ceil( data.MaxConeAng or 0 ), 1 ) end,
	info = function( data, swep )
		local stats = swep:GetRoundStats( data )

		return string.format( "%.0f mm slug", stats.slugPenetration or 0 )
	end,
}

local SUBCALIBRE_SLIDER = {
	key = "Data5",
	title = "Sub-calibre size",
	suffix = "x",
	decimals = 2,
	min = function( data ) return data.MinCalMult or 0.25 end,
	max = function( data ) return data.MaxCalMult or 1 end,
	info = function( data )
		local dart = ( data.Caliber or 2.5 ) * ( data.SCalMult or 1 ) * 10

		return string.format( "%.0f mm dart", dart )
	end,
}


--Presets only seed the editable values below; everything can be tuned after
--picking one. `clamped` maps an editor field to the field the round returns
--once it has clamped the value against the case/shell limits, and `limits`
--is what the server uses to reject silly client values.
SWEP.AmmoDefs = {
	HEAT = {
		label = "HEAT",
		name = "High Explosive Anti-Tank",
		blurb = "Shaped charge and the launcher's default round. Lase a roof and burst it over thin top armour; penetration is lost across an air gap, so avoid skirts.",
		colour = Color( 240, 110, 70 ),
		preset = { PropLength = 10, ProjLength = 12, Data5 = 18, Data6 = 45 },
		limits = { PropLength = { 0, 40 }, ProjLength = { 0, 40 }, Data5 = { 0, 2000 }, Data6 = { 0, 90 } },
		clamped = { ProjLength = "ProjLength", Data5 = "FillerVol", Data6 = "ConeAng" },
		sliders = { PROJECTILE_LENGTH_SLIDER, FILLER_SLIDER, CONE_ANGLE_SLIDER },
	},

	HE = {
		label = "HE",
		name = "High Explosive",
		blurb = "Maximum fragmentation for infantry and soft cover. Lase the range and airburst it: the fill is all blast and no armour piercing.",
		colour = Color( 245, 150, 70 ),
		preset = { PropLength = 10, ProjLength = 12, Data5 = 20 },
		limits = { PropLength = { 0, 40 }, ProjLength = { 0, 40 }, Data5 = { 0, 2000 } },
		clamped = { ProjLength = "ProjLength", Data5 = "FillerVol" },
		sliders = { PROJECTILE_LENGTH_SLIDER, FILLER_SLIDER },
	},

	AP = {
		label = "AP",
		name = "Armour Piercing",
		blurb = "Solid steel shot. Flat trajectory and cheap, but against anything past light armour the 25mm bore runs out of punch.",
		colour = Color( 230, 200, 110 ),
		preset = { PropLength = 14, ProjLength = 10 },
		limits = { PropLength = { 0, 40 }, ProjLength = { 0, 40 } },
		clamped = { ProjLength = "ProjLength", PropLength = "PropLength" },
		sliders = { PROJECTILE_LENGTH_SLIDER, PROPELLANT_LENGTH_SLIDER },
	},

	APHE = {
		label = "APHE",
		name = "Armour Piercing High Explosive",
		blurb = "Armour-piercing shot with a bursting charge. Punches through light plate and detonates inside instead of wasting the round on impact.",
		colour = Color( 235, 170, 100 ),
		preset = { PropLength = 14, ProjLength = 12, Data5 = 16 },
		limits = { PropLength = { 0, 40 }, ProjLength = { 0, 40 }, Data5 = { 0, 2000 } },
		clamped = { ProjLength = "ProjLength", PropLength = "PropLength", Data5 = "FillerVol" },
		sliders = { PROJECTILE_LENGTH_SLIDER, PROPELLANT_LENGTH_SLIDER, FILLER_SLIDER },
	},

	HP = {
		label = "HP",
		name = "Hollow Point",
		blurb = "Expanding projectile with a large cavity. Devastating against infantry, pointless against anything armoured.",
		colour = Color( 230, 120, 110 ),
		preset = { PropLength = 14, ProjLength = 12, Data5 = 20 },
		limits = { PropLength = { 0, 40 }, ProjLength = { 0, 40 }, Data5 = { 0, 2000 } },
		clamped = { ProjLength = "ProjLength", PropLength = "PropLength", Data5 = "CavVol" },
		sliders = { PROJECTILE_LENGTH_SLIDER, PROPELLANT_LENGTH_SLIDER, CAVITY_SLIDER },
	},

	HVAP = {
		label = "HVAP",
		name = "High-Velocity Armour Piercing",
		blurb = "Tungsten dart in a light sabot. Slower than APDS because the sabot costs powder, but its dart out-penetrates solid AP shot.",
		colour = Color( 120, 220, 140 ),
		preset = { PropLength = 14, ProjLength = 14, Data5 = 0.35 },
		limits = { PropLength = { 0, 40 }, ProjLength = { 0, 40 }, Data5 = { 0.1, 1 } },
		clamped = { ProjLength = "ProjLength", PropLength = "PropLength", Data5 = "SCalMult" },
		sliders = { PROJECTILE_LENGTH_SLIDER, PROPELLANT_LENGTH_SLIDER, SUBCALIBRE_SLIDER },
	},

	APDS = {
		label = "APDS",
		name = "Armour Piercing Discarding Sabot",
		blurb = "Sub-calibre discarding sabot. The fastest round the compact 25mm case can throw and the best kinetic penetrator in the menu.",
		colour = Color( 140, 200, 230 ),
		preset = { PropLength = 14, ProjLength = 14, Data5 = 0.30 },
		limits = { PropLength = { 0, 40 }, ProjLength = { 0, 40 }, Data5 = { 0.1, 1 } },
		clamped = { ProjLength = "ProjLength", PropLength = "PropLength", Data5 = "SCalMult" },
		sliders = { PROJECTILE_LENGTH_SLIDER, PROPELLANT_LENGTH_SLIDER, SUBCALIBRE_SLIDER },
	},
}


--- The XM25's presets are a static table in this file.
-- @return boolean Always true.
function SWEP:EnsureAmmoDefs()
	return true
end


--- Converts the editable parameters into a ready-to-fire ACE bullet table.
-- Runs on both realms: the server gets physics data, the client also gets the
-- GUI range fields the ammunition menu reads.
-- @param params table Editable round parameters (see SWEP.AmmoDefs).
-- @return table|nil BulletData, or nil when the round type is unavailable.
function SWEP:BuildAmmoData( params )
	local round = ACE.RoundTypes[params.Type]
	if not round then return nil end

	local def = self.AmmoDefs[params.Type]

	local playerData = {
		Id = AMMO_GUN_ID,
		Type = params.Type,
		PropLength = params.PropLength or 0,
		ProjLength = params.ProjLength or 0,
		Data5 = params.Data5 or 0,
		Data6 = params.Data6 or 0,
		Tracer = 1,
		TwoPiece = 0,
	}

	local ok, data = pcall( round.convert, nil, playerData )
	if not ok or type( data ) ~= "table" then return nil end

	--convert() only carries Id/Type in its server branch, and the client branch
	--only carries the GUI ranges, so stamp the common fields on in either realm.
	data.Id = AMMO_GUN_ID
	data.Type = params.Type
	data.AmmoType = params.Type
	data.Colour = def and def.colour or Color( 200, 200, 200 )

	--The HE branch has no BoomFillerMass, but the fake crate and the blast
	--stat rows need one.
	if not data.FillerMass then data.FillerMass = 0 end
	if not data.BoomFillerMass then data.BoomFillerMass = data.FillerMass end

	return data
end


--- Stamps converted data onto the weapon and the fake crate ACE uses for
-- bullet visuals, and mirrors the fields weapon_ace_base reads off the weapon.
-- @param data table Converted data.
function SWEP:ApplyBuiltData( data )
	self.BulletData = data

	self.Type = data.Type
	self.Caliber = data.Caliber
	self.ProjMass = data.ProjMass
	self.FillerMass = data.FillerMass
	self.BoomFillerMass = data.BoomFillerMass
	self.DragCoef = data.DragCoef
	self.Tracer = data.Tracer
	self.Colour = data.Colour

	if SERVER and IsValid( self.FakeCrate ) then
		self.FakeCrate:RegisterTo( data )
		data.Crate = self.FakeCrate:EntIndex()
	end
end


--- Collects the numbers the menu and the notifications show for a converted
-- round.
-- @param data table Round data from ACE.RoundTypes[type].convert.
-- @return table Stats table (velocity, penetration, slugPenetration, blast, filler, projectileMass, roundMass, roundLength).
function SWEP:GetRoundStats( data )
	local stats = {}
	stats.velocity = data.MuzzleVel or 0
	stats.projectileMass = data.ProjMass or 0
	stats.propellantMass = data.PropMass or 0
	stats.filler = data.FillerMass or 0
	stats.roundMass = stats.projectileMass + stats.propellantMass
	stats.roundLength = ( data.PropLength or 0 ) + ( data.ProjLength or 0 ) + ( data.Tracer or 0 )

	local blastMass = data.BoomFillerMass or stats.filler
	stats.blast = blastMass > 0 and blastMass ^ BLAST_RADIUS_EXPONENT * BLAST_RADIUS_SCALE or 0

	if data.PenArea and stats.velocity > 0 then
		local energy = ACE.Kinetic( stats.velocity * METERS_TO_INCHES, stats.projectileMass, data.LimitVel or SLUG_LIMIT_VELOCITY )
		stats.penetration = ACE.CalcPenetration( energy, data.PenArea )
	end

	if data.SlugPenArea and data.SlugMass and data.SlugMV then
		local energy = ACE.Kinetic( data.SlugMV * METERS_TO_INCHES, data.SlugMass, SLUG_LIMIT_VELOCITY )
		stats.slugPenetration = ACE.CalcPenetration( energy, data.SlugPenArea )
	end

	return stats
end


--- Short description used by the preset list for one entry.
-- @param ammoType string Preset id.
-- @param params table|nil Parameters (defaults to the preset's own values).
-- @return string, string Column values for the list.
function SWEP:GetRowBrief( ammoType, params )
	local def = self:GetAmmoDef( ammoType )

	if not def then return "", "" end

	local preview = params or self:GetPresetParams( ammoType )
	local ok, data = pcall( self.BuildAmmoData, self, preview )

	if not ok or not data then return "", "" end

	local stats = self:GetRoundStats( data )
	local velocity = string.format( "%d m/s", math.floor( stats.velocity + 0.5 ) )
	local effect

	if ammoType == "HEAT" then
		effect = string.format( "%.0f mm pen", stats.slugPenetration or 0 )
	elseif ammoType == "HE" then
		effect = string.format( "%.1f m blast", stats.blast )
	elseif ammoType == "HP" then
		effect = string.format( "%.0f mm expanded", ( data.ExpCaliber or 0 ) * 10 )
	else
		effect = string.format( "%.0f mm pen", stats.penetration or 0 )
	end

	return velocity, effect
end


--- Rows shown in the menu's stat block.
-- @param data table Converted data for the current parameters.
-- @param params table Current selection parameters.
-- @return table List of { title = string, value = string } rows.
function SWEP:GetAmmoStatRows( data, params )
	local ammoType = params and params.Type or data.Type
	local stats = self:GetRoundStats( data )
	local rows = {
		{ title = "Muzzle velocity", value = string.format( "%d m/s", math.floor( stats.velocity + 0.5 ) ) },
	}

	if ammoType == "HEAT" then
		rows[#rows + 1] = { title = "Shaped-charge pen", value = string.format( "%.0f mm", stats.slugPenetration or 0 ) }
		rows[#rows + 1] = { title = "HEAT filler", value = FormatMass( stats.filler ) }
		rows[#rows + 1] = { title = "Blast radius", value = string.format( "%.1f m", stats.blast ) }
	elseif ammoType == "HE" then
		rows[#rows + 1] = { title = "Blast radius", value = string.format( "%.1f m", stats.blast ) }
		rows[#rows + 1] = { title = "HE filler", value = FormatMass( stats.filler ) }
		rows[#rows + 1] = { title = "Projectile mass", value = FormatMass( stats.projectileMass ) }
	elseif ammoType == "APHE" then
		rows[#rows + 1] = { title = "Penetration", value = string.format( "%.0f mm", stats.penetration or 0 ) }
		rows[#rows + 1] = { title = "HE filler", value = FormatMass( stats.filler ) }
		rows[#rows + 1] = { title = "Projectile mass", value = FormatMass( stats.projectileMass ) }
	elseif ammoType == "HP" then
		rows[#rows + 1] = { title = "Expanded caliber", value = string.format( "%.0f mm", ( data.ExpCaliber or 0 ) * 10 ) }
		rows[#rows + 1] = { title = "Projectile mass", value = FormatMass( stats.projectileMass ) }
		rows[#rows + 1] = { title = "Round mass", value = FormatMass( stats.roundMass ) }
	elseif ammoType == "HVAP" or ammoType == "APDS" then
		rows[#rows + 1] = { title = "Penetration", value = string.format( "%.0f mm", stats.penetration or 0 ) }
		rows[#rows + 1] = { title = "Dart caliber", value = string.format( "%.0f mm", ( data.Caliber or 2.5 ) * ( data.SCalMult or 1 ) * 10 ) }
		rows[#rows + 1] = { title = "Projectile mass", value = FormatMass( stats.projectileMass ) }
	else
		rows[#rows + 1] = { title = "Penetration", value = string.format( "%.0f mm", stats.penetration or 0 ) }
		rows[#rows + 1] = { title = "Projectile mass", value = FormatMass( stats.projectileMass ) }
		rows[#rows + 1] = { title = "Round mass", value = FormatMass( stats.roundMass ) }
	end

	return rows
end


--- One-line summary of the currently loaded round, used by the deploy notification.
-- @return string Human readable ammunition summary.
function SWEP:GetAmmoSummary()
	local ammoType = self.AmmoParams and self.AmmoParams.Type or self.DefaultAmmo
	local def = self.AmmoDefs[ammoType]

	if not def or not self.BulletData then return "25mm ammunition" end

	local stats = self:GetRoundStats( self.BulletData )
	local label = "25mm " .. def.label
	local velocity = math.floor( stats.velocity + 0.5 )

	if ammoType == "HEAT" then
		return string.format( "%s - %d m/s - %.0f mm slug - %s filler", label, velocity,
			stats.slugPenetration or 0, FormatMass( stats.filler ) )
	elseif ammoType == "HE" then
		return string.format( "%s - %d m/s - %.1f m blast - %s filler", label, velocity, stats.blast, FormatMass( stats.filler ) )
	elseif ammoType == "APHE" then
		return string.format( "%s - %d m/s - %.0f mm pen - %s filler", label, velocity,
			stats.penetration or 0, FormatMass( stats.filler ) )
	elseif ammoType == "HP" then
		return string.format( "%s - %d m/s - %.0f mm expanded", label, velocity, ( self.BulletData.ExpCaliber or 0 ) * 10 )
	end

	return string.format( "%s - %d m/s - %.0f mm pen", label, velocity, stats.penetration or 0 )
end
