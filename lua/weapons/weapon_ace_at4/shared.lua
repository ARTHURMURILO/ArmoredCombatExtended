--[[---------------------------------------------------------
	AT-4 - 84mm disposable launcher, now with selectable warheads.

	The launcher itself is unchanged: a dumb, unguided rocket. What changed is
	that the warhead is built through ACE's real round conversion instead of a
	hard-coded HEAT table, and the player can pick and tune it from an R-key
	menu (HEAT, HE, HEDP, tandem HEAT and smoke).
-----------------------------------------------------------]]

SWEP.PrintName = "AT-4"
SWEP.Base = "weapon_ace_ammomenu"
SWEP.Category = "ACE Weapons"
SWEP.SubCategory = "Special"
SWEP.Purpose = "Clear Backblast!"
SWEP.Instructions = "Left click to fire. Press R with a round loaded to choose and tune the warhead."
SWEP.Spawnable = true
SWEP.Slot = 4 --Which inventory column the weapon appears in
SWEP.SlotPos = 3 --Priority in which the weapon appears, 1 tries to put it at the top


--Main settings--
SWEP.FireRate = 0.2 --Rounds per second

SWEP.Primary.ClipSize = 1
SWEP.Primary.DefaultClip = 1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "RPG_Round"
SWEP.Primary.Sound = "ace_weapons/sweps/multi_sound/at4_multi.mp3"
SWEP.Primary.LightScale = 200 --Muzzleflash light radius
SWEP.Primary.BulletCount = 1 --Number of bullets to fire each shot, used for shotguns

SWEP.ReloadSound = "Weapon_Pistol.Reload"

SWEP.ZoomFOV = 50
SWEP.HasScope = false --True if the weapon has a sniper-style scope


--Recoil (crosshair movement) settings--
SWEP.HeatReductionRate = 25
SWEP.HeatPerShot = 100
SWEP.HeatMax = 100

SWEP.RecoilSideBias = 0.1

SWEP.ZoomRecoilBonus = 0.5
SWEP.CrouchRecoilBonus = 0.5
SWEP.ViewPunchAmount = 400


--Spread (aimcone) settings--
SWEP.BaseSpread = 0.15
SWEP.MaxSpread = 15
SWEP.MovementSpread = 2
SWEP.UnscopedSpread = 0.5

SWEP.CarrySpeedMul = 0.7

--Model settings--
SWEP.ViewModelFlip = false
SWEP.ViewModel = "models/weapons/v_RPG.mdl"
SWEP.WorldModel = "models/weapons/w_rocket_launcher.mdl"
SWEP.HoldType = "rpg"
SWEP.DeployDelay = 4
SWEP.CSMuzzleFlashes = false


--Ammunition menu--
SWEP.DefaultAmmo = "HEAT"
SWEP.MenuTitle = "AT-4 ammunition"
SWEP.MenuSubtitle = "84mm disposable launcher - dummy-fire rocket"
SWEP.MenuListHeaders = { "Warhead", "Speed", "Effect" }

local WARHEAD_ORDER = { "HEAT", "HE", "HEDP", "Tandem", "Smoke" }

--85mmAT4 is a data-only gun definition (lua/acf/shared/guns/rocketlauncher.lua)
--that supplies the case limits the warhead conversions are clamped against.
local AMMO_GUN_ID = "84mmAT4"
local ROCKET_SPEED = 234
local BLAST_RADIUS_EXPONENT = 0.33
local BLAST_RADIUS_SCALE = 8
local SLUG_LIMIT_VELOCITY = 999999


local function BlastRadius( data )
	local mass = data and ( data.BoomFillerMass or data.FillerMass )

	if not mass or mass <= 0 then return 0 end

	return mass ^ BLAST_RADIUS_EXPONENT * BLAST_RADIUS_SCALE
end


local function SlugPenetration( data )
	if not ( data and data.SlugMV and data.SlugMass and data.SlugPenArea ) then return 0 end

	local energy = ACE.Kinetic( data.SlugMV * 39.37, data.SlugMass, SLUG_LIMIT_VELOCITY )

	return ACE.CalcPenetration( energy, data.SlugPenArea ) or 0
end


--- Presets. Filler volumes are cm3 and cone angles degrees, mirroring the
-- ammo crate sliders; the values land near the AT-4's established punch.
SWEP.AmmoDefs = {
	HEAT = {
		label = "HEAT",
		name = "High Explosive Anti-Tank",
		blurb = "The standard M136 round. A shaped charge with a crush cone; deadly against armour and vehicles.",
		preset = { PropLength = 1, ProjLength = 12, Data5 = 430, Data6 = 50 },
		limits = { PropLength = { 0.01, 10 }, ProjLength = { 0.01, 60 }, Data5 = { 0, 2000 }, Data6 = { 0, 180 } },
		clamped = { ProjLength = "ProjLength", Data5 = "FillerVol", Data6 = "ConeAng" },
	},
	HE = {
		label = "HE",
		name = "High Explosive",
		blurb = "Fragmentation round. No armour penetration, but a large filler charge and a lot of fragments for infantry and light cover.",
		preset = { PropLength = 1, ProjLength = 10, Data5 = 300, Data6 = 0 },
		limits = { PropLength = { 0.01, 10 }, ProjLength = { 0.01, 60 }, Data5 = { 0, 2000 }, Data6 = { 0, 180 } },
		clamped = { ProjLength = "ProjLength", Data5 = "FillerVol" },
	},
	HEDP = {
		roundType = "HEAT",
		label = "HEDP",
		name = "High Explosive Dual Purpose",
		blurb = "Compromise round: a wide shaped charge with most of the case volume given to filler. Less penetration than HEAT, much more blast and fragmentation.",
		preset = { PropLength = 1, ProjLength = 12, Data5 = 430, Data6 = 65 },
		limits = { PropLength = { 0.01, 10 }, ProjLength = { 0.01, 60 }, Data5 = { 0, 2000 }, Data6 = { 0, 180 } },
		clamped = { ProjLength = "ProjLength", Data5 = "FillerVol", Data6 = "ConeAng" },
	},
	Tandem = {
		roundType = "THEAT",
		label = "Tandem",
		name = "Tandem HEAT",
		blurb = "Two shaped charges in one round. The first charge sets off reactive armour, the second one does the actual damage (the AT-4 Proto warhead).",
		preset = { PropLength = 1, ProjLength = 13, Data5 = 450, Data6 = 55, Data13 = 60, Data14 = 0.9 },
		limits = {
			PropLength = { 0.01, 10 },
			ProjLength = { 0.01, 60 },
			Data5 = { 0, 2000 },
			Data6 = { 0, 180 },
			Data13 = { 0, 180 },
			Data14 = { 0, 1 },
		},
		clamped = { ProjLength = "ProjLength", Data5 = "FillerVol", Data6 = "ConeAng" },
	},
	Smoke = {
		roundType = "SM",
		label = "Smoke",
		name = "Smoke",
		blurb = "Smoke warhead for screening pushes. No penetration; area denial and concealment.",
		preset = { PropLength = 1, ProjLength = 10, Data5 = 250, Data6 = 0 },
		limits = { PropLength = { 0.01, 10 }, ProjLength = { 0.01, 60 }, Data5 = { 0, 2000 }, Data6 = { 0, 180 } },
		clamped = { ProjLength = "ProjLength", Data5 = "FillerVol" },
	},
}

SWEP.AmmoOrder = WARHEAD_ORDER


local SLIDERS = {
	{
		key = "ProjLength",
		title = "Warhead length",
		suffix = "cm",
		decimals = 2,
		min = function( data ) return data.MinProjLength or 0.01 end,
		max = function( data ) return math.max( data.MaxProjLength or 40, data.MinProjLength or 0.01 ) end,
		info = function( data )
			return string.format( "%d g projectile", math.floor( ( data.ProjMass or 0 ) * 1000 + 0.5 ) )
		end,
	},
	{
		key = "Data5",
		title = "Filler volume",
		suffix = "cm3",
		decimals = 0,
		min = 0,
		max = function( data ) return math.max( data.MaxFillerVol or 0, 1 ) end,
		info = function( data )
			return string.format( "%d g explosive", math.floor( ( data.FillerMass or 0 ) * 1000 + 0.5 ) )
		end,
	},
}


--- Returns the slider list; the cone angle only matters for shaped charges.
-- @param swep table Weapon class.
-- @param params table Selection parameters.
-- @return table Slider definitions.
local function GetSliders( swep, params )
	local sliders = {}

	for _, slider in ipairs( SLIDERS ) do
		sliders[#sliders + 1] = slider
	end

	if params and ( params.Type == "HEAT" or params.Type == "HEDP" or params.Type == "Tandem" ) then
		sliders[#sliders + 1] = {
			key = "Data6",
			title = "Cone angle",
			suffix = "deg",
			decimals = 1,
			min = 0,
			max = function( data ) return math.max( data.MaxConeAng or 0, 0.1 ) end,
		}
	end

	return sliders
end


for _, def in pairs( SWEP.AmmoDefs ) do
	def.sliders = GetSliders
end


--- Converts the selected warhead into bullet data through ACE's round pipeline.
-- @param params table Selection parameters.
-- @return table|nil Converted bullet data.
function SWEP:BuildAmmoData( params )
	local def = self:GetAmmoDef( params.Type )
	if not def then return nil end

	local roundType = def.roundType or params.Type
	local round = ACE.RoundTypes[roundType]
	if not round then return nil end

	local ok, data = pcall( round.convert, nil, {
		Id = AMMO_GUN_ID,
		Type = roundType,
		PropLength = tonumber( params.PropLength ) or 1,
		ProjLength = tonumber( params.ProjLength ) or 10,
		Data5 = tonumber( params.Data5 ) or 0,
		Data6 = tonumber( params.Data6 ) or 0,
		Data7 = 0,
		Data8 = 0,
		Data13 = tonumber( params.Data13 ) or 0,
		Data14 = tonumber( params.Data14 ) or 0,
		Tracer = 1,
		TwoPiece = 0,
	} )

	if not ok or type( data ) ~= "table" then return nil end

	data.Id = AMMO_GUN_ID
	data.Type = roundType
	data.AmmoType = roundType
	data.Colour = params.Type == "HE" and Color( 255, 90, 40 ) or Color( 255, 140, 40 )

	if not data.BoomFillerMass then
		data.BoomFillerMass = data.FillerMass or 0
	end

	if not data.FillerMass then
		data.FillerMass = 0
	end

	return data
end


--- Stamps the converted warhead onto the weapon and its fake crate.
-- @param data table Converted bullet data.
function SWEP:ApplyBuiltData( data )
	self.BulletData = data

	if SERVER and IsValid( self.FakeCrate ) then
		self.FakeCrate:RegisterTo( data )
		data.Crate = self.FakeCrate:EntIndex()
	end
end


--- Short description used by the preset list.
-- @param ammoType string Preset id.
-- @param params table|nil Parameters to preview (defaults to the preset).
-- @return string, string Speed and effect column values.
function SWEP:GetRowBrief( ammoType, params )
	local def = self:GetAmmoDef( ammoType )

	if not def then return "", "" end

	local preview = params or def.preset
	local ok, data = pcall( self.BuildAmmoData, self, preview )

	if not ok or not data then return "", "" end

	local speed = string.format( "%d m/s", ROCKET_SPEED )
	local effect

	if preview.Type == "Smoke" then
		effect = "smoke screen"
	elseif preview.Type == "HE" then
		effect = string.format( "%.1f m blast", BlastRadius( data ) )
	else
		effect = string.format( "%.0f mm pen", SlugPenetration( data ) )
	end

	return speed, effect
end


--- Stat block shown in the menu.
-- @param data table Converted data for the current parameters.
-- @param params table Current parameters.
-- @return table Stat rows.
function SWEP:GetAmmoStatRows( data, params )
	local rows = {
		{ title = "Rocket velocity", value = string.format( "%d m/s", ROCKET_SPEED ) },
	}

	local filler = math.floor( ( data.FillerMass or 0 ) * 1000 + 0.5 )

	if params.Type == "Smoke" then
		rows[#rows + 1] = { title = "Payload", value = string.format( "%d g smoke", filler ) }
		rows[#rows + 1] = { title = "Projectile mass", value = string.format( "%.2f kg", data.ProjMass or 0 ) }
		rows[#rows + 1] = { title = "Round mass", value = string.format( "%.2f kg", ( data.ProjMass or 0 ) + ( data.PropMass or 0 ) ) }

		return rows
	end

	if params.Type == "HE" then
		rows[#rows + 1] = { title = "HE filler", value = string.format( "%d g", filler ) }
		rows[#rows + 1] = { title = "Blast radius", value = string.format( "%.1f m", BlastRadius( data ) ) }
		rows[#rows + 1] = { title = "Fragments", value = tostring( math.floor( data.Fragments or 0 ) ) }

		return rows
	end

	rows[#rows + 1] = { title = "HEAT filler", value = string.format( "%d g", filler ) }
	rows[#rows + 1] = { title = "Penetration", value = string.format( "%.0f mm", SlugPenetration( data ) ) }
	rows[#rows + 1] = { title = "Blast radius", value = string.format( "%.1f m", BlastRadius( data ) ) }

	if params.Type == "Tandem" and data.SlugMV2 then
		local energy = ACE.Kinetic( data.SlugMV2 * 39.37, data.SlugMass2 or 1, SLUG_LIMIT_VELOCITY )
		local second = ACE.CalcPenetration( energy, data.SlugPenArea2 or 1 ) or 0

		rows[#rows + 1] = { title = "Second charge pen", value = string.format( "%.0f mm", second ) }
	end

	return rows
end


--- One-line notification shown when a round is loaded or the weapon deploys.
-- @return string|nil Summary.
function SWEP:GetAmmoSummary()
	local params = self.AmmoParams
	local def = params and self:GetAmmoDef( params.Type )
	local data = self.BulletData

	if not def or not data then return nil end

	if params.Type == "Smoke" then
		return string.format( "AT-4 - SMOKE - %d m/s - %d g smoke", ROCKET_SPEED,
			math.floor( ( data.FillerMass or 0 ) * 1000 + 0.5 ) )
	end

	if params.Type == "HE" then
		return string.format( "AT-4 - HE - %d m/s - %.1f m blast", ROCKET_SPEED, BlastRadius( data ) )
	end

	return string.format( "AT-4 - %s - %d m/s - %.0f mm pen - %.1f m blast", string.upper( params.Type ),
		ROCKET_SPEED, SlugPenetration( data ), BlastRadius( data ) )
end


--- Launches the selected warhead as a dumb ACE rocket.
-- @param owner Entity The player firing.
function SWEP:LaunchMissile( owner )
	local bdata = self.BulletData
	if not bdata then return end

	local crate = self.FakeCrate

	if not IsValid( crate ) then
		self:UpdateFakeCrate()
		crate = self.FakeCrate
	end

	if not IsValid( crate ) then return end

	crate:RegisterTo( bdata )
	bdata.Crate = crate:EntIndex()

	local MDat = {
		Owner = owner,
		Launcher = owner,

		Pos = owner:GetShootPos() + owner:GetAimVector() * 1500,
		Ang = owner:GetAimVector():Angle(),

		Mdl = "models/munitions/round_100mm_mortar_shot.mdl",

		TurnRate = 0,
		FinMul = 0,
		ThrusterTurnRate = 0,

		InitialVelocity = ROCKET_SPEED,
		Thrust = 0,
		BurnTime = 5,
		MotorDelay = 0,

		BoostThrust = 0,
		BoostTime = 0,
		BoostDelay = 0,

		Drag = 0.003,
		GuidanceName = "Dumb",
		FuseName = "Contact",
		HasInertial = false,
		HasDatalink = false,

		ArmDelay = 0,
		DelayPrediction = 0.1,
		ArmorThickness = 8,

		MotorSound = "acf_extra/airfx/rpg_fire.wav",
		BoostEffect = "rocket_smoke",
		MotorEffect = "rocket_smoke",
	}

	ACE_GenerateMissile( MDat, crate, bdata )
end


function SWEP:PrimaryAttack()
	if self:Clip1() == 0 and self:Ammo1() > 0 then
		self:Reload()

		return
	end

	if not self:CanPrimaryAttack() then return end

	local owner = self:GetOwner()

	if not IsValid( owner ) then return end

	if ( IsFirstTimePredicted() or game.SinglePlayer() ) and owner:IsPlayer() then
		owner:ViewPunch( Angle( -5, 0, 0 ) )
	end

	self:SetNextPrimaryFire( CurTime() + ( 1 / self.FireRate ) )

	if not SERVER then return end

	self:LaunchMissile( owner )

	self:EmitSound( self.Primary.Sound )
	self:SendWeaponAnim( ACT_VM_PRIMARYATTACK )

	if owner:IsPlayer() then
		owner:SetAnimation( PLAYER_ATTACK1 )

		if self:Ammo1() > 0 then
			owner:RemoveAmmo( 1, "RPG_Round" )
			self:SetZoomState( false )
			self:SetOwnerZoomSpeed( false )
		else
			self:TakePrimaryAmmo( 1 )
		end
	end
end
