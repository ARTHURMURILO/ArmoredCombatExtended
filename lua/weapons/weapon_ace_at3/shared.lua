--[[---------------------------------------------------------
	AT-3 - shoulder-fired 9K11 Malyutka launcher.

	Reuses the AT-4's view/world models and shooting feel, but the projectile is
	an ACE missile instead of a dumb rocket. The missile is steered by keeping
	the crosshair on the target: the player's eye position/aim and the aim-point
	are forwarded to whichever ACE guidance package the missile supports.

	Press R with a missile loaded to pick and tune one of the man-portable ATGMs
	(Sagger, Konkurs, Spike-LR). Motor, warhead and guidance parameters are
	editable per missile, AMR-menu style.
-----------------------------------------------------------]]

SWEP.PrintName = "AT-3"
SWEP.Base = "weapon_ace_ammomenu"
SWEP.Category = "ACE Weapons"
SWEP.SubCategory = "Special"
SWEP.Purpose = "Guided anti-tank missile"
SWEP.Instructions = "Left click to fire. Keep your aim on the target to steer the missile. Right click to scope. Press R with a missile loaded to choose an ATGM."
SWEP.Spawnable = true
SWEP.Slot = 4 --Which inventory column the weapon appears in
SWEP.SlotPos = 4 --Priority in which the weapon appears, 1 tries to put it at the top


--Main settings--
SWEP.FireRate = 0.25 --Rounds per second

SWEP.Primary.ClipSize = 1
SWEP.Primary.DefaultClip = 1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "RPG_Round"
SWEP.Primary.Sound = "ace_weapons/sweps/multi_sound/at4_multi.mp3"
SWEP.Primary.LightScale = 200 --Muzzleflash light radius
SWEP.Primary.BulletCount = 1

SWEP.ReloadSound = "Weapon_Pistol.Reload"

SWEP.ZoomFOV = 45
SWEP.HasScope = false


--Recoil (crosshair movement) settings--
SWEP.HeatReductionRate = 25
SWEP.HeatPerShot = 100
SWEP.HeatMax = 100

SWEP.RecoilSideBias = 0.1
SWEP.ZoomRecoilBonus = 0.5
SWEP.CrouchRecoilBonus = 0.5
SWEP.ViewPunchAmount = 200


--Spread (aimcone) settings--
SWEP.BaseSpread = 0
SWEP.MaxSpread = 0
SWEP.MovementSpread = 1.5
SWEP.UnscopedSpread = 0.5

SWEP.CarrySpeedMul = 0.6

--Model settings--
SWEP.ViewModelFlip = false
SWEP.ViewModel = "models/weapons/v_RPG.mdl"
SWEP.WorldModel = "models/weapons/w_rocket_launcher.mdl"
SWEP.HoldType = "rpg"
SWEP.DeployDelay = 4
SWEP.CSMuzzleFlashes = false


--Ammunition menu--
SWEP.DefaultAmmo = "AT-3 ASM"
SWEP.MenuTitle = "AT-3 ammunition"
SWEP.MenuSubtitle = "9K11 Malyutka launcher - beam-riding guidance"
SWEP.MenuListHeaders = { "Missile", "Speed", "Effect" }

local MISSILE_ORDER = { "AT-3 ASM", "9M113 ATGM", "Spike-LR ASM" }

--Default preset values per missile. Motor values come from ACE's missile
--definition; these add the warhead and the balance dials the menu exposes.
local MISSILE_PRESETS = {
	["AT-3 ASM"] = {
		label = "AT-3",
		blurb = "9M14 Malyutka. Very slow, light and nimble: the original Sagger. Keep the crosshair on the target and the missile follows the beam.",
		projLength = 14,
		filler = 1000,
		cone = 50,
		launchKick = 90,
	},
	["9M113 ATGM"] = {
		label = "9M113",
		blurb = "Konkurs. Heavier warhead and a faster motor than the Sagger, at the cost of some agility.",
		projLength = 16,
		filler = 1500,
		cone = 50,
		launchKick = 100,
	},
	["Spike-LR ASM"] = {
		label = "Spike-LR",
		blurb = "Spike LR. Long range and very agile, a good candidate if you want to steer a fast missile onto moving vehicles.",
		projLength = 20,
		filler = 3000,
		cone = 55,
		launchKick = 110,
	},
}

--Human readable labels for ACE's guidance packages.
local GUIDANCE_LABELS = {
	Dumb = "Dumb (fly straight)",
	Wire = "Wire (aim-point, 500 m wire)",
	Beam_Riding = "Beam riding (steer with aim)",
	Laser = "Laser (aim-point, needs line of sight)",
	Infrared = "Infrared (heat seeker)",
	Top_Attack_IR = "Top attack (IR seeker)",
}

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


local function WarheadLabel( params )
	return string.upper( params.Warhead or "HEAT" )
end


--- Rough top speed for the menu: rocket equations are overkill, but thrust,
-- burn time and drag give a usable estimate (terminal speed = sqrt(thrust/drag)).
-- @param params table Selection parameters.
-- @return number Speed in m/s.
function SWEP:GetEstimatedTopSpeed( params )
	local launch = math.max( tonumber( params.LaunchKick ) or 0, 0 )
	local thrust = math.max( tonumber( params.Thrust ) or 0, 0 )
	local burn = math.max( tonumber( params.BurnTime ) or 0, 0 )
	local drag = math.max( tonumber( params.Drag ) or 0.002, 0.0001 )
	local boost = math.max( tonumber( params.BoostAccel ) or 0, 0 ) * math.max( tonumber( params.BoostTime ) or 0, 0 )

	if thrust <= 0 then return launch + boost end

	return math.min( launch + thrust * burn + boost, math.sqrt( thrust / drag ) )
end


--- Builds the preset table from ACE's installed ATGM definitions.
-- @return boolean True when the presets are available.
function SWEP:EnsureAmmoDefs()
	if self.AmmoDefsReady then return true end

	local guns = ACE.Weapons and ACE.Weapons.Guns

	if not guns then return false end

	local defs = {}
	local order = {}

	for _, id in ipairs( MISSILE_ORDER ) do
		local gun = guns[id]
		local special = MISSILE_PRESETS[id]

		if gun and gun.round and special then
			local round = gun.round
			local warheads = {}

			for warhead in pairs( gun.skinindex or {} ) do
				if ACE.RoundTypes[warhead] then
					warheads[#warheads + 1] = warhead
				end
			end

			table.sort( warheads )

			if #warheads == 0 then
				warheads = { "HEAT" }
			elseif warheads[1] ~= "HEAT" then
				--HEAT is the standard warhead; keep it first in the dropdown.
				for index, warhead in ipairs( warheads ) do
					if warhead == "HEAT" then
						table.remove( warheads, index )
						table.insert( warheads, 1, "HEAT" )
						break
					end
				end
			end

			local guidanceOptions = {}

			for index, guidanceName in ipairs( gun.guidance or {} ) do
				guidanceOptions[index] = guidanceName
			end

			if #guidanceOptions == 0 then
				guidanceOptions = { "Dumb" }
			end

			--Prefer the aim-driven packages for a handheld launcher, but fall back
			--to whatever the missile actually supports (Spike-LR has no beam rider).
			local defaultGuidance = guidanceOptions[1]

			for _, candidate in ipairs( { "Beam_Riding", "Laser", "Wire", "Dumb" } ) do
				for _, available in ipairs( guidanceOptions ) do
					if available == candidate then
						defaultGuidance = candidate
						break
					end
				end

				if defaultGuidance == candidate then break end
			end

			local preset = {
				Warhead = warheads[1],
				Guidance = defaultGuidance,
				PropLength = 1,
				ProjLength = special.projLength,
				Data5 = special.filler,
				Data6 = special.cone,
				LaunchKick = special.launchKick or round.launchkick or 10,
				Thrust = round.thrust or 20,
				BurnTime = round.burntime or 8,
				TurnRate = round.turnrate or 30,
				FinEff = round.finefficiency or 0.7,
				ThrusterTurnRate = round.thrusterturnrate or 0,
				BoostAccel = round.boostacceleration or 0,
				BoostTime = round.boostertime or 0,
				Drag = round.dragcoef or 0.002,
			}

			defs[id] = {
				label = special.label,
				name = gun.name,
				blurb = special.blurb,
				gun = gun,
				roundData = round,
				warheads = warheads,
				preset = preset,
				limits = {
					PropLength = { 0.01, 10 },
					ProjLength = { 0.01, 80 },
					Data5 = { 0, 20000 },
					Data6 = { 0, 180 },
					LaunchKick = { 20, 250 },
					Thrust = { 0, 300 },
					BurnTime = { 0, 40 },
					TurnRate = { 0, 600 },
					FinEff = { 0, 1 },
					ThrusterTurnRate = { 0, 200 },
					BoostAccel = { 0, 1200 },
					BoostTime = { 0, 3 },
					Drag = { 0, 0.05 },
				},
				clamped = {
					ProjLength = "ProjLength",
					Data5 = "FillerVol",
					Data6 = "ConeAng",
				},
				dropdowns = {
					{
						key = "Warhead",
						title = "Warhead",
						options = warheads,
						rebuild = true,
					},
					{
						key = "Guidance",
						title = "Guidance",
						options = guidanceOptions,
						optionLabels = GUIDANCE_LABELS,
					},
				},
				sliders = function( swep, params )
					local sliders = {
						{
							key = "ProjLength",
							title = "Warhead length",
							suffix = "cm",
							decimals = 2,
							min = function( data ) return data.MinProjLength or 0.01 end,
							max = function( data ) return math.max( data.MaxProjLength or 20, data.MinProjLength or 0.01 ) end,
							info = function( data )
								return string.format( "%d g warhead body", math.floor( ( data.ProjMass or 0 ) * 1000 + 0.5 ) )
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

					if ( params and params.Warhead or "HEAT" ) == "HEAT" then
						sliders[#sliders + 1] = {
							key = "Data6",
							title = "Cone angle",
							suffix = "deg",
							decimals = 1,
							min = 0,
							max = function( data ) return math.max( data.MaxConeAng or 0, 0.1 ) end,
						}
					end

					sliders[#sliders + 1] = { key = "LaunchKick", title = "Launch booster speed", suffix = "m/s", decimals = 0, min = 20, max = 250 }
					sliders[#sliders + 1] = { key = "Thrust", title = "Motor thrust", suffix = "m/s2", decimals = 0, min = 0, max = 300 }
					sliders[#sliders + 1] = { key = "BurnTime", title = "Motor burn time", suffix = "s", decimals = 1, min = 0, max = 40 }
					sliders[#sliders + 1] = { key = "TurnRate", title = "Airframe turn rate", suffix = "deg", decimals = 0, min = 0, max = 600 }
					sliders[#sliders + 1] = { key = "FinEff", title = "Fin efficiency", suffix = "x", decimals = 2, min = 0, max = 1 }
					sliders[#sliders + 1] = { key = "ThrusterTurnRate", title = "Thruster turn rate", suffix = "deg", decimals = 0, min = 0, max = 200 }
					sliders[#sliders + 1] = { key = "Drag", title = "Drag coefficient", suffix = "x", decimals = 4, min = 0, max = 0.05 }

					return sliders
				end,
				summary = function( swep, data, params )
					local particles = { string.format( "%.0f m/s", swep:GetEstimatedTopSpeed( params ) ) }

					if WarheadLabel( params ) == "HEAT" then
						particles[#particles + 1] = string.format( "%.0f mm pen", SlugPenetration( data ) )
					else
						particles[#particles + 1] = string.format( "%.1f m blast", BlastRadius( data ) )
					end

					if params.Guidance then
						particles[#particles + 1] = string.lower( params.Guidance )
					end

					return table.concat( particles, "  -  " )
				end,
			}

			order[#order + 1] = id
		end
	end

	if #order == 0 then return false end

	self.AmmoDefs = defs
	self.AmmoOrder = order
	self.AmmoDefsReady = true

	return true
end


--- Converts the selected missile into the warhead data ACE detonates at impact.
-- @param params table Selection parameters.
-- @return table|nil Converted bullet data.
function SWEP:BuildAmmoData( params )
	local def = self:GetAmmoDef( params.Type )
	if not def then return nil end

	local warhead = params.Warhead or "HEAT"
	local round = ACE.RoundTypes[warhead]

	if not round then return nil end

	local ok, data = pcall( round.convert, nil, {
		Id = params.Type,
		Type = warhead,
		PropLength = tonumber( params.PropLength ) or 1,
		ProjLength = tonumber( params.ProjLength ) or def.preset.ProjLength,
		Data5 = tonumber( params.Data5 ) or 0,
		Data6 = tonumber( params.Data6 ) or 0,
		Data7 = 0,
		Data8 = 0,
		Tracer = 1,
		TwoPiece = 0,
	} )

	if not ok or type( data ) ~= "table" then return nil end

	data.Id = params.Type
	data.Type = warhead
	data.AmmoType = warhead
	data.Colour = warhead == "HE" and Color( 255, 90, 40 ) or Color( 255, 140, 40 )

	--Warhead numbers are ACE's own conversion results; no hidden multipliers.
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

	local speed = string.format( "%.0f m/s", self:GetEstimatedTopSpeed( preview ) )
	local effect

	if WarheadLabel( preview ) == "HEAT" then
		effect = string.format( "%.0f mm pen", SlugPenetration( data ) )
	else
		effect = string.format( "%.1f m blast", BlastRadius( data ) )
	end

	return speed, effect
end


--- Stat block shown in the menu.
-- @param data table Converted data for the current parameters.
-- @param params table Current parameters.
-- @return table Stat rows.
function SWEP:GetAmmoStatRows( data, params )
	local rows = {
		{ title = "Estimated top speed", value = string.format( "%.0f m/s", self:GetEstimatedTopSpeed( params ) ) },
	}

	local filler = math.floor( ( data.FillerMass or 0 ) * 1000 + 0.5 )

	if WarheadLabel( params ) == "HEAT" then
		rows[#rows + 1] = { title = "Warhead", value = string.format( "HEAT - %d g filler", filler ) }
		rows[#rows + 1] = { title = "Penetration", value = string.format( "%.0f mm", SlugPenetration( data ) ) }
		rows[#rows + 1] = { title = "Blast radius", value = string.format( "%.1f m", BlastRadius( data ) ) }
	else
		rows[#rows + 1] = { title = "Warhead", value = string.format( "HE - %d g filler", filler ) }
		rows[#rows + 1] = { title = "Blast radius", value = string.format( "%.1f m", BlastRadius( data ) ) }
		rows[#rows + 1] = { title = "Fragments", value = tostring( math.floor( data.Fragments or 0 ) ) }
	end

	return rows
end


--- One-line notification shown when a missile is loaded or the weapon deploys.
-- @return string|nil Summary.
function SWEP:GetAmmoSummary()
	local params = self.AmmoParams
	local def = params and self:GetAmmoDef( params.Type )

	if not def then return nil end

	local data = self.BulletData or {}
	local speed = self:GetEstimatedTopSpeed( params )

	if WarheadLabel( params ) == "HEAT" then
		return string.format( "%s - HEAT - %.0f m/s - %.0f mm pen - %.1f m blast",
			def.label, speed, SlugPenetration( data ), BlastRadius( data ) )
	end

	return string.format( "%s - HE - %.0f m/s - %.1f m blast", def.label, speed, BlastRadius( data ) )
end


--- Makes the missile follow the player's eyes and aim-point.
-- ACE's guidance packages read `missile.Launcher`: aim-point packages (Wire,
-- Laser) read Launcher.TargPos, beam riding reads the launcher entity's origin
-- and forward vector, and Configure() re-runs on the missile's first think. A
-- small invisible proxy at the eye position therefore has to *become* the
-- launcher; the player entity itself would aim from the feet and has no TargPos.
-- Damage/ownership stays on DamageOwner/BulletData, so this only affects steering.
-- @param owner Entity The firing player.
-- @param missile Entity The spawned missile.
-- @return boolean True when the proxy was attached.
function SWEP:AttachAimProxy( owner, missile )
	if not SERVER or not IsValid( owner ) or not IsValid( missile ) then return false end

	local proxy = ents.Create( "info_target" )

	if not IsValid( proxy ) then return false end

	proxy:SetPos( owner:GetShootPos() )
	proxy:SetAngles( owner:GetAimVector():Angle() )
	proxy:Spawn()
	proxy:SetNoDraw( true )
	proxy:SetNotSolid( true )
	proxy:SetCollisionGroup( COLLISION_GROUP_IN_VEHICLE )

	local traceData = {
		filter = { owner },
		start = owner:GetShootPos(),
		endpos = owner:GetShootPos() + owner:GetAimVector() * 50000,
	}

	local trace = util.TraceLine( traceData )
	proxy.TargPos = trace.Hit and trace.HitPos or traceData.endpos

	local hookName = "ACE_AT3_AimProxy_" .. proxy:EntIndex()

	hook.Add( "Think", hookName, function()
		if not IsValid( missile ) or not IsValid( proxy ) then
			hook.Remove( "Think", hookName )

			if IsValid( proxy ) then
				proxy:Remove()
			end

			return
		end

		if not IsValid( owner ) or not owner:Alive() then return end

		local shootPos = owner:GetShootPos()
		local aimVector = owner:GetAimVector()

		proxy:SetPos( shootPos )
		proxy:SetAngles( aimVector:Angle() )

		traceData.start = shootPos
		traceData.endpos = shootPos + aimVector * 50000

		local aimTrace = util.TraceLine( traceData )

		proxy.TargPos = aimTrace.Hit and aimTrace.HitPos or traceData.endpos
	end )

	if missile.DeleteOnRemove then
		missile:DeleteOnRemove( proxy )
	end

	missile.Launcher = proxy

	return true
end


--- Launches the selected ATGM as an ACE missile with beam-riding guidance.
-- @param owner Entity The player firing.
function SWEP:LaunchMissile( owner )
	local params = self.AmmoParams
	local def = params and self:GetAmmoDef( params.Type )
	local bdata = self.BulletData

	if not def or not bdata then return end

	local round = def.roundData
	local crate = self.FakeCrate

	if not IsValid( crate ) then
		self:UpdateFakeCrate()
		crate = self.FakeCrate
	end

	if not IsValid( crate ) then return end

	crate:RegisterTo( bdata )
	bdata.Crate = crate:EntIndex()

	local guidance = params.Guidance or "Dumb"

	--Slight loft: the first moments of a slow ATGM would otherwise sink into the
	--ground before the motor builds enough speed for the guidance to hold it up.
	local launchAngle = owner:GetAimVector():Angle() + Angle( -2, 0, 0 )

	local MDat = {
		Owner = owner,
		Launcher = owner,

		Pos = owner:GetShootPos() + owner:GetAimVector() * 200,
		Ang = launchAngle,

		Mdl = round.rocketmdl or def.gun.model,

		TurnRate = tonumber( params.TurnRate ) or 30,
		FinMul = tonumber( params.FinEff ) or 0.7,
		ThrusterTurnRate = tonumber( params.ThrusterTurnRate ) or 0,

		InitialVelocity = tonumber( params.LaunchKick ) or 10,
		Thrust = tonumber( params.Thrust ) or 20,
		BurnTime = tonumber( params.BurnTime ) or 8,
		MotorDelay = round.startdelay or 0,

		BoostThrust = tonumber( params.BoostAccel ) or round.boostacceleration or 0,
		BoostTime = tonumber( params.BoostTime ) or round.boostertime or 0,
		BoostDelay = round.boostdelay or 0,

		Drag = tonumber( params.Drag ) or round.dragcoef or 0.002,

		GuidanceName = guidance,
		FuseName = "Contact",
		HasInertial = round.inertialcapable or false,
		HasDatalink = round.datalink or false,

		ArmDelay = def.gun.armdelay or 0.15,
		DelayPrediction = 0.2,
		ArmorThickness = round.armour or 15,

		MotorSound = "acf_extra/airfx/rocket_fire.wav",
		BoostEffect = def.gun.effectbooster or "ACE_MotorTiny",
		MotorEffect = def.gun.effect or "ACE_MotorTiny",
	}

	local missile = ACE_GenerateMissile( MDat, crate, bdata )

	if not IsValid( missile ) then return end

	--ACE_GenerateMissile hard-codes a 20 s lifetime and clears the guidance
	--delay; restore the definition's numbers so long slow shots survive.
	missile.Lifetime = round.fusetime or 20

	if guidance ~= "Dumb" then
		missile.GuidanceActivationDelay = 0.15
		self:AttachAimProxy( owner, missile )
	end

	self.LastLaunchInfo = string.format( "%s %s guidance=%s kick=%s",
		tostring( params.Type ), tostring( bdata.Type ), string.lower( guidance ),
		tostring( params.LaunchKick ) )

	if GetConVar( "ace_launcher_debug" ):GetBool() then
		print( string.format( "[ACE-LAUNCHER] AT-3 fired %s (%s) guidance=%s booster=%s m/s missile=%s",
			tostring( params.Type ), tostring( bdata.Type ), tostring( guidance ),
			tostring( params.LaunchKick ), tostring( IsValid( missile ) ) ) )
	end
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
		owner:ViewPunch( Angle( -2, 0, 0 ) )
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


--Build the presets eagerly so the first spawn already knows its ammunition.
--If ACE's armory data is not loaded yet, InitBulletData retries lazily.
SWEP:EnsureAmmoDefs()
