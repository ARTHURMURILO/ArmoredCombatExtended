-- Headless checks for the selectable launcher ammunition (AT-3/AT-4/XM25).
-- Loads ACE's real round definitions, the missile/gun definitions the weapons
-- read at runtime, and the weapons' shared files under LuaJIT with GMod stubs.
-- Exercises presets, conversions, sanitising and the missile MDat builder.
-- Usage: luajit tests/lua/ace_launcher_ammo_selftest.lua <ACE repo>

local root = assert(arg[1], "usage: ace_launcher_ammo_selftest.lua <ACE repo>")

SERVER, CLIENT = false, true

function AddCSLuaFile() end
function include() end
function IsValid( entity ) return entity ~= nil end
function Color( r, g, b, a ) return { r = r, g = g, b = b, a = a or 255 } end
function ACE_SendNotification() end
function Vector( x, y, z ) return { x = x or 0, y = y or 0, z = z or 0 } end

table.Merge = table.Merge or function( target, source )
	for key, value in pairs( source ) do
		target[key] = value
	end
	return target
end

table.Copy = table.Copy or function( source )
	local copy = {}
	for key, value in pairs( source ) do
		copy[key] = value
	end
	return copy
end

math.Max = math.max
math.Min = math.min
math.Clamp = math.Clamp or function( value, minValue, maxValue )
	if value < minValue then return minValue end
	if value > maxValue then return maxValue end
	return value
end
math.Round = math.Round or function( value ) return math.floor( value + 0.5 ) end

list = { Set = function() end }
hook = { Add = function() end, Remove = function() end, Run = function() end }
weapons = { Get = function() return nil end }

ACE = {
	AmmoBlacklist = {},
	RoundTypes = {},
	IdRounds = {},
	Translation = setmetatable( {}, { __index = function() return { "name", "desc" } end } ),
	Weapons = { Guns = {} },
	Classes = { GunClass = { AC = { type = "Gun" }, ATGM = { type = "missile" }, RL = { type = "Gun" } } },
}

--Constants copied from lua/autorun/acf_globals.lua
ACE.PBase = 1050
ACE.PScale = 1
ACE.MVScale = 0.5
ACE.PDensity = 1.6
ACE.PenAreaMod = 0.85
ACE.KEtoRHA = 0.25
ACE.KinFudgeFactor = 2.1
ACE.HEDensity = 1.65
ACE.HEPower = 8000
ACE.HEFrag = 2500
ACE.HEATMVScale = 0.75
ACE.HEATMVScaleTan = 0.75
ACE.ShellPenMul = 1
ACE.HEBlastPenetration = 3500

--Math copied from sh_ace_functions.lua and ace_roundfunctions.lua
local function MuzzleVelocity( propellant, mass )
	local energy = ACE.PBase * ( ( 1 + propellant ) ^ ACE.PScale - 1 )
	return ( ( energy * 2000 / mass ) ^ ACE.MVScale )
end

local function Kinetic( speed, mass, limitVel )
	limitVel = limitVel or 99999
	speed = speed / 39.37
	local energy = {}
	energy.Kinetic = ( mass * ( speed ^ 2 ) ) / 2000
	energy.Momentum = speed * mass
	local ke = ( mass * ( speed ^ ACE.KinFudgeFactor ) ) / 2000 + energy.Momentum
	energy.Penetration = math.max( ke - ( math.max( speed - limitVel, 0 ) ^ 2 ) / ( limitVel * 5 ) * ( ke / 200 ) ^ 0.95, ke * 0.1 )
	return energy
end

local function CalcPenetration( energy, penArea, penMul )
	local energyPen = type( energy ) == "table" and tonumber( energy.Penetration ) or tonumber( energy )
	local area = tonumber( penArea )
	if not energyPen or not area or area <= 0 then return 0 end
	local pen = ( energyPen / area ) * ACE.KEtoRHA
	if penMul then pen = pen * penMul end
	if pen ~= pen then return 0 end
	return math.max( pen, 0 )
end

local function RoundBaseGunpowder( playerData, data, serverData, guiData )
	local gunData = ACE.Weapons.Guns[playerData.Id]
	local bulletMax = gunData.round
	local gunClass = ACE.Classes.GunClass[gunData.gunclass] or {}
	local isMissile = gunClass.type == "missile"

	guiData.MaxTotalLength = bulletMax.maxlength
	data.BodyCaliber = gunData.caliber
	data.WarheadCaliber = data.BodyCaliber
	data.Caliber = data.WarheadCaliber
	data.FrArea = math.pi * ( data.Caliber / 2 ) ^ 2
	data.Tracer = playerData.Tracer > 0 and math.min( data.Caliber / 5, 3 ) or 0
	data.TwoPiece = playerData.TwoPiece > 0 and 1 or 0

	local propMax = ( bulletMax.propweight * 1000 / ACE.PDensity ) / data.FrArea
	local curLength = playerData.ProjLength + math.min( playerData.PropLength, propMax ) + data.Tracer

	guiData.MinPropLength = 0.01
	guiData.MaxPropLength = math.max( math.min( guiData.MaxTotalLength - curLength + playerData.PropLength, propMax ), guiData.MinPropLength )

	local minProjLength = bulletMax.minprojlength or gunData.minprojlength
	if minProjLength == nil then
		local minProjRatio = bulletMax.minprojratio or gunData.minprojratio
		if minProjRatio == nil then minProjRatio = isMissile and 0.5 or 1.5 end
		local minProjCaliber = isMissile and data.BodyCaliber or data.Caliber
		minProjLength = minProjCaliber * minProjRatio
	end

	guiData.MinProjLength = math.max( minProjLength, 0.01 )
	guiData.MaxProjLength = math.max( guiData.MaxTotalLength - curLength + playerData.ProjLength, guiData.MinProjLength )

	local ratio = math.min( 1, ( guiData.MaxTotalLength - data.Tracer ) / ( playerData.ProjLength + math.min( playerData.PropLength, propMax ) ) )

	data.ProjLength = math.Clamp( playerData.ProjLength * ratio, guiData.MinProjLength, guiData.MaxProjLength )
	data.PropLength = math.Clamp( playerData.PropLength * ratio, guiData.MinPropLength, guiData.MaxPropLength )
	data.PropMass = data.FrArea * ( data.PropLength * ACE.PDensity / 1000 )
	guiData.ProjVolume = data.FrArea * data.ProjLength
	data.RoundVolume = data.FrArea * ( data.ProjLength + data.PropLength )

	return playerData, data, serverData, guiData
end

local function RoundShellCapacity( momentum, frArea, caliber, projLength )
	local minWall = 0.2 + ( ( momentum / frArea ) ^ 0.7 ) / 50
	local length = math.max( projLength - minWall, 0 )
	local radius = math.max( ( caliber / 2 ) - minWall, 0 )
	return math.pi * radius ^ 2 * length, length, radius
end

ACE.MuzzleVelocity = MuzzleVelocity
ACE.Kinetic = Kinetic
ACE.CalcPenetration = CalcPenetration
ACE.RoundBaseGunpowder = RoundBaseGunpowder
ACE.RoundShellCapacity = RoundShellCapacity

--------------------------------------------------------------------------------
-- Data the weapons read at runtime (values mirror the real definitions).
--------------------------------------------------------------------------------

ACE.Weapons.Guns["AT-3 ASM"] = {
	name = "AT-3 Sagger Missile",
	model = "models/missiles/at3.mdl",
	gunclass = "ATGM",
	caliber = 12.5,
	weight = 12.5,
	effect = "ACE_MotorTiny",
	effectbooster = "ACE_MotorTiny",
	guidance = { "Dumb", "Wire", "Beam_Riding" },
	fuses = { "Contact", "Optical", "Timed", "Altitude" },
	skinindex = { HEAT = 0, HE = 1 },
	armdelay = 0.15,
	round = {
		maxlength = 55, propweight = 1.2,
		turnrate = 30, finefficiency = 0.7, thrusterturnrate = 60,
		thrust = 13, burntime = 12, startdelay = 0, launchkick = 20,
		boostacceleration = 70, boostertime = 0.2, boostdelay = 0,
		fusetime = 20, dragcoef = 0.002, inertialcapable = false,
		predictiondelay = 0.5, armour = 13,
	},
}

ACE.Weapons.Guns["9M113 ATGM"] = {
	name = "9M113 Konkurs Missile",
	model = "models/missiles/9m113.mdl",
	gunclass = "ATGM",
	caliber = 13.5,
	weight = 14.6,
	effect = "Rocket Motor ATGM",
	effectbooster = "Rocket Motor ATGM",
	guidance = { "Dumb", "Wire", "Beam_Riding" },
	fuses = { "Contact", "Optical", "Timed", "Altitude" },
	skinindex = { HEAT = 0 },
	armdelay = 0.15,
	round = {
		maxlength = 105, propweight = 1,
		turnrate = 5, finefficiency = 1.0, thrusterturnrate = 30,
		thrust = 37, burntime = 8, startdelay = 0, launchkick = 10,
		boostacceleration = 600, boostertime = 0.05, boostdelay = 0,
		fusetime = 20, dragcoef = 0.0035, inertialcapable = false,
		predictiondelay = 0.1, armour = 15,
	},
}

ACE.Weapons.Guns["Spike-LR ASM"] = {
	name = "Spike LR Missile",
	model = "models/missiles/spikelr2.mdl",
	gunclass = "ATGM",
	caliber = 17,
	weight = 13,
	effect = "ACE_MissileSmall",
	effectbooster = "ACE_MissileSmall",
	guidance = { "Dumb", "Beam_Riding" },
	fuses = { "Contact", "Optical", "Timed", "Altitude" },
	skinindex = { HEAT = 0 },
	armdelay = 0.15,
	round = {
		maxlength = 60, propweight = 1,
		turnrate = 200, finefficiency = 1.0, thrusterturnrate = 0,
		thrust = 55, burntime = 6, startdelay = 0, launchkick = 13,
		boostacceleration = 100, boostertime = 0.25, boostdelay = 0,
		fusetime = 20, dragcoef = 0.003, inertialcapable = true,
		datalink = false, predictiondelay = 0.1, armour = 13,
	},
}

-- Data-only gun definitions added with the launcher overhaul.
ACE.Weapons.Guns["84mmAT4"] = {
	name = "84mm Rocket Launcher",
	gunclass = "RL",
	caliber = 8.4,
	round = { maxlength = 42, propweight = 0.35, minprojratio = 0.5 },
}

ACE.Weapons.Guns["25mmAC"] = {
	name = "25mm Light Autocannon",
	gunclass = "AC",
	caliber = 2.5,
	round = { maxlength = 32, propweight = 0.13 },
}

for _, name in ipairs( { "heat", "he", "theat", "smoke", "ap", "aphe", "hp", "hvap", "apds" } ) do
	local ok, err = pcall( dofile, root .. "/lua/acf/shared/rounds/round" .. name .. ".lua" )
	assert( ok, "failed to load round" .. name .. ": " .. tostring( err ) )
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function LoadWeapon( paths )
	SWEP = { Primary = {}, Secondary = {} }

	for _, path in ipairs( paths ) do
		local ok, err = pcall( dofile, root .. path )
		assert( ok, "failed to load " .. path .. ": " .. tostring( err ) )
	end

	SWEP.GetOwner = function() return nil end

	return SWEP
end

local function AssertFinite( value, label )
	assert( type( value ) == "number", label .. " is not a number" )
	assert( value == value, label .. " is NaN" )
	assert( value ~= math.huge and value ~= -math.huge, label .. " is infinite" )
end

local function FindPreset( swep, id )
	return swep.AmmoDefs[id]
end

--------------------------------------------------------------------------------
-- weapon_ace_at3
--------------------------------------------------------------------------------

print( "==> weapon_ace_at3" )

local at3 = LoadWeapon( {
	"/lua/weapons/weapon_ace_ammomenu/shared.lua",
	"/lua/weapons/weapon_ace_at3/shared.lua",
} )

assert( at3:EnsureAmmoDefs(), "AT-3 presets were not built" )
assert( #at3.AmmoOrder == 3, "expected 3 AT-3 presets, got " .. #at3.AmmoOrder )
assert( at3.AmmoOrder[1] == "AT-3 ASM", "Sagger should be the default preset" )
assert( at3.AmmoOrder[2] == "9M113 ATGM", "Konkurs should be the second preset" )
assert( at3.AmmoOrder[3] == "Spike-LR ASM", "Spike-LR should be the third preset" )

for _, id in ipairs( at3.AmmoOrder ) do
	local def = FindPreset( at3, id )
	assert( def, "missing preset " .. id )
	assert( def.preset.Warhead == "HEAT", id .. " should default to a HEAT warhead" )
	assert( def.preset.Guidance == "Beam_Riding", id .. " should default to beam riding" )

	local presetParams = at3:GetPresetParams( id )
	local ok, data = pcall( at3.BuildAmmoData, at3, presetParams )
	assert( ok and type( data ) == "table", id .. " preset failed to convert: " .. tostring( data ) )

	AssertFinite( data.Caliber, id .. " caliber" )
	assert( data.Caliber == ACE.Weapons.Guns[id].caliber, id .. " caliber should come from the missile definition" )
	AssertFinite( data.ProjMass, id .. " projectile mass" )
	AssertFinite( data.MuzzleVel, id .. " muzzle velocity" )
	AssertFinite( data.FillerMass, id .. " filler mass" )
	assert( data.FillerMass > 0.05, id .. " HEAT preset should have a filler charge" )
	assert( data.Type == "HEAT", id .. " converted type should be HEAT" )
	assert( data.Id == id, id .. " converted id should be the missile id" )

	local energy = Kinetic( data.SlugMV * 39.37, data.SlugMass, 999999 )
	local pen = CalcPenetration( energy, data.SlugPenArea )
	assert( pen > 120, string.format( "%s default HEAT should be a real threat, got %.1f mm", id, pen ) )

	local speed = at3:GetEstimatedTopSpeed( def.preset )
	AssertFinite( speed, id .. " estimated speed" )
	assert( speed > 30 and speed < 400, id .. " estimated speed out of range: " .. speed )

	--HE warhead variant converts through the frag round instead.
	local heParams = at3:GetPresetParams( id )
	heParams.Warhead = "HE"
	local heData = at3:BuildAmmoData( heParams )
	assert( type( heData ) == "table", id .. " HE variant failed to convert" )
	assert( heData.Type == "HE", id .. " HE variant should convert as HE" )
	assert( heData.FillerMass > 0.05, id .. " HE variant should have filler" )
	assert( heData.SlugMV == nil, id .. " HE variant should not carry a shaped-charge slug" )
end

--Sanitising keeps clients from sending silly values.
local params = at3:SanitizeParams( "AT-3 ASM", { Warhead = "Laser", Guidance = "Wire", Data5 = -50, WarheadPower = 99 } )
assert( params, "sanitising a valid preset failed" )
assert( params.Warhead == "HEAT", "invalid warhead should fall back to the preset" )
assert( params.Guidance == "Beam_Riding", "invalid guidance should fall back to the preset" )
assert( params.Data5 == 0, "negative filler volume should clamp to 0" )
assert( params.WarheadPower == 4, "warhead power should clamp to 4" )
assert( at3:SanitizeParams( "not a missile", {} ) == nil, "unknown preset should be rejected" )

--Loading a selection rebuilds the live bullet data and params.
assert( at3:ApplyAmmo( "9M113 ATGM", at3:GetPresetParams( "9M113 ATGM" ), nil ) )
assert( at3.AmmoParams.Type == "9M113 ATGM", "ApplyAmmo should store the selected preset" )
assert( at3.BulletData.Id == "9M113 ATGM", "ApplyAmmo should rebuild BulletData" )
assert( at3:GetAmmoSummary():find( "9M113", 1, true ), "summary should name the missile" )

print( "ACE launcher ammo (AT-3) LuaJIT self-test: PASS" )

--------------------------------------------------------------------------------
-- weapon_ace_at4
--------------------------------------------------------------------------------

print( "==> weapon_ace_at4" )

local at4 = LoadWeapon( {
	"/lua/weapons/weapon_ace_ammomenu/shared.lua",
	"/lua/weapons/weapon_ace_at4/shared.lua",
} )

assert( at4:EnsureAmmoDefs(), "AT-4 presets missing" )
assert( #at4.AmmoOrder == 5, "expected 5 AT-4 presets, got " .. #at4.AmmoOrder )
assert( at4.AmmoOrder[1] == "HEAT", "HEAT should be the default warhead" )

for _, id in ipairs( at4.AmmoOrder ) do
	local def = FindPreset( at4, id )
	assert( def, "missing warhead " .. id )

	local data = at4:BuildAmmoData( at4:GetPresetParams( id ) )
	assert( type( data ) == "table", id .. " failed to convert" )
	AssertFinite( data.Caliber, id .. " caliber" )
	assert( data.Caliber == 8.4, id .. " should be an 84mm warhead" )
	AssertFinite( data.ProjMass, id .. " mass" )
	AssertFinite( data.MuzzleVel, id .. " velocity" )
	local expectedType = ({ HEDP = "HEAT", Tandem = "THEAT", Smoke = "SM" })[id] or id
	assert( data.Type == expectedType, id .. " converted with the wrong round type" )

	if id == "HE" then
		assert( data.FillerMass > 0.2, "HE warhead should carry real filler" )
		assert( data.SlugMV == nil, "HE warhead should not be a shaped charge" )
	elseif id == "Smoke" then
		assert( data.Type == "SM", "smoke should convert through the smoke round" )
	elseif id == "Tandem" then
		assert( data.SlugMV2, "tandem should have a second charge" )
	else
		local energy = Kinetic( data.SlugMV * 39.37, data.SlugMass, 999999 )
		local pen = CalcPenetration( energy, data.SlugPenArea )
		assert( pen > 40 and pen < 200, string.format( "%s penetration out of range: %.1f mm", id, pen ) )
	end
end

local at4Summary = at4:ApplyAmmo( "HEAT", at4:GetPresetParams( "HEAT" ), nil ) and at4:GetAmmoSummary()
assert( at4Summary and at4Summary:find( "AT-4", 1, true ), "AT-4 summary should mention the launcher" )

print( "ACE launcher ammo (AT-4) LuaJIT self-test: PASS" )

--------------------------------------------------------------------------------
-- weapon_ace_xm25 (owned by the parallel work stream; checked when present)
--------------------------------------------------------------------------------

local xm25Path = root .. "/lua/weapons/weapon_ace_xm25/shared.lua"

local file = io.open( xm25Path, "r" )

if file then
	file:close()

	print( "==> weapon_ace_xm25" )

	local xm25 = LoadWeapon( {
		"/lua/weapons/weapon_ace_ammomenu/shared.lua",
		"/lua/weapons/weapon_ace_xm25/shared.lua",
	} )

	assert( xm25:EnsureAmmoDefs(), "XM25 presets missing" )
	assert( #xm25.AmmoOrder >= 5, "XM25 should expose its round presets" )

	for _, id in ipairs( xm25.AmmoOrder ) do
		local def = FindPreset( xm25, id )
		local data = xm25:BuildAmmoData( xm25:GetPresetParams( id ) )

		assert( type( data ) == "table", id .. " failed to convert" )
		assert( data.Caliber == 2.5, id .. " should be a 25mm round" )
		AssertFinite( data.ProjMass, id .. " mass" )
		AssertFinite( data.MuzzleVel, id .. " velocity" )
	end

	print( "ACE launcher ammo (XM25) LuaJIT self-test: PASS" )
else
	print( "==> weapon_ace_xm25: skipped (shared.lua not present)" )
end

print( "ACE launcher ammunition LuaJIT self-test: PASS" )
