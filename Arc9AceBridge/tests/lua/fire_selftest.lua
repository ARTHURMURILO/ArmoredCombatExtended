--[[
	Integration self-test for the bridge fire path and player damage model.

	Runs under LuaJIT through tests/run_fire_tests.py. The runner provides
	Vector/Angle maths, a tiny entity system, convars, a weapon registry and an
	ACE_CreateBullet capture table. This script registers a fake ARC9 EFT
	weapon, runs SWEP:DoProjectileAttack and inspects what the bridge fired.
]]

local C = ARC9ACE
local passed, failed = 0, 0

local function ok(cond, label, detail)
	if cond then
		passed = passed + 1
		print(string.format("PASS  %-62s %s", label, detail or ""))
	else
		failed = failed + 1
		print(string.format("FAIL  %-62s %s", label, detail or ""))
		error("assertion failed: " .. label)
	end
end

local function near(actual, expected, tolerance, label)
	ok(math.abs((actual or -1e9) - expected) <= tolerance, label,
		string.format("got %.4f expected %.4f", actual or -1e9, expected))
end

local function ConVar(name, value)
	return CONVARS[name]
end

--[[----------------------------------------------------------------------------
	Fake ARC9 objects
]]------------------------------------------------------------------------------

local CLASS_BY_NAME = {}

local function RegisterWeapon(class, base)
	local wep = {
		ClassName = class,
		Base = base,
		DoProjectileAttack = function(self, pos, ang, spread)
			self.stockCalls = (self.stockCalls or 0) + 1
		end,
	}
	WEAPON_BASES[class] = base
	WEAPONS[#WEAPONS + 1] = wep
	CLASS_BY_NAME[class] = wep
	return wep
end

RegisterWeapon("arc9_eft_base", "arc9_base")
RegisterWeapon("arc9_base", nil)

local FAKE_OWNER = {
	valid = true,
	GetVehicle = function() return nil end,
	IsPlayer = function() return true end,
	Nick = function() return "Tester" end,
	IsNPC = function() return false end,
}

local function MakeWeaponEntity(class, values, slots)
	local classTable = CLASS_BY_NAME[class]
	local ent = {
		valid = true,
		index = 500,
		owner = FAKE_OWNER,
		values = values or {},
		slots = slots or {},
	}
	local metatable = {
		__index = function(_, key)
			local fn = classTable[key]
			if fn ~= nil then return fn end
			return nil
		end,
	}
	function ent:GetClass() return class end
	function ent:EntIndex() return self.index end
	function ent:GetOwner() return self.owner end
	function ent:IsValid() return true end
	function ent:GetProcessedValue(key) return self.values[key] end
	function ent:GetSubSlotList() return self.slots end
	function ent:Remove() self.valid = false end

	return setmetatable(ent, metatable)
end

-- EFT ammo table for the fake weapon.
RegisterAtt("eft_ammo_556_fmj", {
	PrintName = "5.56x45mm FMJ",
	Category = { "eft_ammo_556" },
	Description = "A 5.56x45mm NATO FMJ cartridge with a 3.6 gram lead core bullet.",
	PhysBulletMuzzleVelocity = 957 / 0.0254,
	DamageMax = 57,
	BallisticCoefficient = 0.252,
	EFTWeightAdd = 0.012,
	EFTRoundName = "eft_ammo_556_fmj",
})

RegisterWeapon("arc9_eft_testrifle", "arc9_eft_base")
RegisterWeapon("arc9_other_gun", "arc9_base")

local RIFLE_VALUES = {
	PhysBulletMuzzleVelocity = 957 / 0.0254,
	Num = 1,
	DamageMax = 57,
}
local RIFLE_SLOTS = {
	{ Installed = "eft_ammo_556_fmj", Category = { "eft_ammo_556" } },
}

--[[----------------------------------------------------------------------------
	Patch + fire
]]------------------------------------------------------------------------------

C.InitConVars()
C.InitDamageConVars()
C.PatchWeapons()

ok(C.PatchedCount >= 3, "patch: all arc9-based classes wrapped", tostring(C.PatchedCount))

local rifle = MakeWeaponEntity("arc9_eft_testrifle", RIFLE_VALUES, RIFLE_SLOTS)
CREATED_BULLETS = {}

local shotPos = Vector(10, 20, 30)
rifle:DoProjectileAttack(shotPos, Angle(0, 0, 0), 0)

ok(rifle.stockCalls == nil, "fire: stock ARC9 path not used for bridged shot")
ok(#CREATED_BULLETS == 1, "fire: one ACE bullet created", tostring(#CREATED_BULLETS))

local bullet = CREATED_BULLETS[1]
ok(bullet ~= nil, "fire: bullet captured")
near(bullet.Caliber, 0.556, 1e-9, "fire: Caliber")
near(bullet.ProjMass, 0.0036, 1e-6, "fire: ProjMass")
near(bullet.MuzzleVel, 957, 1e-6, "fire: MuzzleVel")
near(bullet.Flight:Length(), 957 * 39.37, 1e-3, "fire: Flight length = muzzle velocity")
near(bullet.Pos.x, 10, 1e-9, "fire: Pos from ARC9 shot")
ok(bullet.Owner == FAKE_OWNER, "fire: Owner set")
ok(bullet.Gun == rifle, "fire: Gun set to the ARC9 weapon")
ok(isnumber(bullet.Crate), "fire: Crate index set")
ok(istable(bullet.Filter) and #bullet.Filter >= 3, "fire: trace filter populated")
ok(bullet.ARC9Bridge == true, "fire: bullet marked as bridged")

-- Crate should have been created and registered with the ammo data.
local crate = FAKE_ENTITIES[bullet.Crate]
ok(crate ~= nil and crate.class == "acf_fakecrate2", "fire: fake crate spawned")
ok(crate.nw.AmmoType == bullet.Type, "fire: crate ammo type synced")
ok(crate.nw.Tracer == 0, "fire: crate tracer flag synced")
near(crate.nw.Caliber, 0.556, 1e-9, "fire: crate calibre synced (cm)")

-- Second shot must reuse the crate and fire again.
rifle:DoProjectileAttack(shotPos, Angle(0, 0, 0), 0)
ok(#CREATED_BULLETS == 2, "fire: second shot creates a second bullet", tostring(#CREATED_BULLETS))
ok(CREATED_BULLETS[2].Crate == bullet.Crate, "fire: crate reused across shots")

--[[----------------------------------------------------------------------------
	Pellet count (shotgun)
]]------------------------------------------------------------------------------

local shotgun = MakeWeaponEntity("arc9_eft_testrifle", {
	PhysBulletMuzzleVelocity = 340 / 0.0254,
	Num = 8,
	DamageMax = 50,
}, {
	{ Installed = "eft_ammo_12x70_buck", Category = { "eft_ammo_12x70" } },
})

RegisterAtt("eft_ammo_12x70_buck", {
	PrintName = "12/70 8.5mm buckshot",
	Category = { "eft_ammo_12x70" },
	Description = "A 12/70 shell loaded with 8.5mm buckshot.",
	PhysBulletMuzzleVelocity = 340 / 0.0254,
	DamageMax = 50,
	BallisticCoefficient = 0.1,
	EFTWeightAdd = 0.05,
	Num = 9,
	EFTRoundName = "eft_ammo_12x70_buck",
})

CREATED_BULLETS = {}
shotgun:DoProjectileAttack(shotPos, Angle(0, 0, 0), 0)
ok(#CREATED_BULLETS == 8, "fire: shotgun spawns one bullet per ARC9 pellet", tostring(#CREATED_BULLETS))
ok(CREATED_BULLETS[1].Caliber == CREATED_BULLETS[8].Caliber, "fire: pellets share projectile profile")

--[[----------------------------------------------------------------------------
	Fallbacks must call the original ARC9 path
]]------------------------------------------------------------------------------

-- 1) ShootEnt (rockets/grenades)
local launcher = MakeWeaponEntity("arc9_eft_testrifle", {
	ShootEnt = "sent_test_grenade",
	Num = 1,
	DamageMax = 100,
}, RIFLE_SLOTS)
CREATED_BULLETS = {}
launcher:DoProjectileAttack(shotPos, Angle(0, 0, 0), 0)
ok(#CREATED_BULLETS == 0 and launcher.stockCalls == 1, "fallback: ShootEnt uses stock ARC9")

-- 2) Out of scope (non-EFT ARC9 weapon while scope = EFT only)
local other = MakeWeaponEntity("arc9_other_gun", RIFLE_VALUES, RIFLE_SLOTS)
CREATED_BULLETS = {}
other:DoProjectileAttack(shotPos, Angle(0, 0, 0), 0)
ok(#CREATED_BULLETS == 0 and other.stockCalls == 1, "fallback: out-of-scope weapon uses stock ARC9")

-- 3) No resolvable ammo slot
local bare = MakeWeaponEntity("arc9_eft_testrifle", { Num = 1, DamageMax = 50 }, {})
CREATED_BULLETS = {}
bare:DoProjectileAttack(shotPos, Angle(0, 0, 0), 0)
ok(#CREATED_BULLETS == 0 and bare.stockCalls == 1, "fallback: missing ammo uses stock ARC9")

-- 4) Bridge disabled by convar
ConVar("arc9ace_enable").value = 0
CREATED_BULLETS = {}
rifle.stockCalls = nil
rifle:DoProjectileAttack(shotPos, Angle(0, 0, 0), 0)
ok(#CREATED_BULLETS == 0 and rifle.stockCalls == 1, "fallback: arc9ace_enable 0 uses stock ARC9")
ConVar("arc9ace_enable").value = 1

--[[----------------------------------------------------------------------------
	Damage layers: projectile-impact interceptor + squishy fallback
]]------------------------------------------------------------------------------

local FALLBACK_CALLS = 0
local ORIGINAL_IMPACT_CALLS = 0

ACE = ACE or {}
ACE.VelScale = 1
ACE.Kinetic = function(speed, mass)
	local v = speed / 39.37
	return { Kinetic = mass * v * v / 2000 }
end
ACE.RoundTypes = {
	AP = {
		propimpact = function() ORIGINAL_IMPACT_CALLS = ORIGINAL_IMPACT_CALLS + 1 return false end,
	},
	HP = {
		propimpact = function() ORIGINAL_IMPACT_CALLS = ORIGINAL_IMPACT_CALLS + 1 return false end,
	},
}
ACE.SquishyDamage = function()
	FALLBACK_CALLS = FALLBACK_CALLS + 1
	return { fallback = true }
end

ok(C.InstallDamageOverride() == true, "damage: override installed")
ok(ACE.RoundTypes.AP.ARC9ACE_Intercepted == true, "damage: AP impact interceptor installed")
ok(ACE.RoundTypes.HP.ARC9ACE_Intercepted == true, "damage: HP impact interceptor installed")

local TAKEN = nil
local target = {
	valid = true,
	IsPlayer = function() return true end,
	TakeDamage = function(self, dmg) TAKEN = dmg end,
	HasGodMode = function() return false end,
}

-- Build a real bridged bullet from the fake weapon's processed stats.
local impactGun = MakeWeaponEntity("arc9_eft_testrifle", {
	BodyDamageMults = {
		[HITGROUP_HEAD] = 2.5,
		[HITGROUP_CHEST] = 1.25,
		[HITGROUP_STOMACH] = 1,
		[HITGROUP_LEFTARM] = 1,
		[HITGROUP_RIGHTARM] = 1,
		[HITGROUP_LEFTLEG] = 0.9,
		[HITGROUP_RIGHTLEG] = 0.9,
	},
	HeadshotDamage = 1,
	ChestDamage = 1,
	StomachDamage = 1,
	ArmDamage = 1,
	LegDamage = 1,
}, RIFLE_SLOTS)
local impactStats = C.ComputeStats(impactGun)
ok(impactStats ~= nil, "damage: stats for impact test")
local impactBullet = C.BuildBulletData(impactStats)
impactBullet.Owner = FAKE_OWNER
impactBullet.Gun = impactGun
impactBullet.Flight = Vector(957 * 39.37, 0, 0)
ok(impactBullet.ARC9BodyMults ~= nil, "damage: bullet carries hitgroup multipliers")

local ret = ACE.RoundTypes.AP.propimpact(1, impactBullet, target, nil, nil, HITGROUP_HEAD)
ok(ret == false, "damage: interceptor stops the bullet")
ok(TAKEN ~= nil, "damage: interceptor applied damage")
near(TAKEN, 57 * 2.5 / 2, 1e-6, "damage: interceptor headshot damage")
ok(ORIGINAL_IMPACT_CALLS == 0, "damage: interceptor bypassed ACE damage")

-- Chest hit
TAKEN = nil
ACE.RoundTypes.AP.propimpact(1, impactBullet, target, nil, nil, HITGROUP_CHEST)
near(TAKEN, 57 * 1.25, 1e-6, "damage: interceptor chest damage")

-- Falloff: quarter energy -> half damage
TAKEN = nil
impactBullet.Flight = Vector(957 * 39.37 * 0.5, 0, 0)
ACE.RoundTypes.AP.propimpact(1, impactBullet, target, nil, nil, HITGROUP_CHEST)
near(TAKEN, 57 * 0.583 * 1.25, 1e-6, "damage: interceptor long-range floor (58.3%)")
impactBullet.Flight = Vector(957 * 39.37, 0, 0)

-- Non-bridged bullet falls through to ACE
TAKEN = nil
local plainBullet = { ARC9Bridge = nil, Owner = FAKE_OWNER, Gun = impactGun }
ACE.RoundTypes.AP.propimpact(1, plainBullet, target, nil, nil, HITGROUP_HEAD)
ok(TAKEN == nil and ORIGINAL_IMPACT_CALLS == 1, "damage: non-bridged bullet uses ACE damage")

-- God mode blocks bridged damage (falls through to ACE)
TAKEN = nil
target.HasGodMode = function() return true end
ACE.RoundTypes.AP.propimpact(1, impactBullet, target, nil, nil, HITGROUP_HEAD)
ok(TAKEN == nil and ORIGINAL_IMPACT_CALLS == 2, "damage: god mode blocks bridged damage")
target.HasGodMode = function() return false end

-- Pure ACE mode: interceptor falls through even for bridged bullets
ConVar("arc9ace_player_damage").value = 0
TAKEN = nil
ACE.RoundTypes.AP.propimpact(1, impactBullet, target, nil, nil, HITGROUP_HEAD)
ok(TAKEN == nil and ORIGINAL_IMPACT_CALLS == 3, "damage: arc9ace_player_damage 0 uses ACE model")
ConVar("arc9ace_player_damage").value = 1

-- ARC9 lookup-table damage: when the weapon exposes GetDamageAtRange, its
-- value is used instead of the fallback approximation.
local lutGun = MakeWeaponEntity("arc9_eft_testrifle", {}, RIFLE_SLOTS)
lutGun.GetDamageAtRange = function(self, range) return 42 end
local lutStats = C.ComputeStats(impactGun)
local lutBullet = C.BuildBulletData(lutStats)
lutBullet.Owner = FAKE_OWNER
lutBullet.Gun = lutGun
lutBullet.Flight = Vector(957 * 39.37, 0, 0)
lutBullet.FlightTime = 0.2
TAKEN = nil
ACE.RoundTypes.AP.propimpact(1, lutBullet, target, nil, nil, HITGROUP_CHEST)
near(TAKEN, 42 * 1.25, 1e-6, "damage: ARC9 GetDamageAtRange used when available")

-- Squishy fallback still works for the direct ACE path.
local gun = MakeWeaponEntity("arc9_eft_testrifle", {}, RIFLE_SLOTS)
gun.ARC9ACE_LastShot = impactStats
local savedShot = gun.ARC9ACE_LastShot

TAKEN = nil
local hitres = ACE.SquishyDamage(target, { Kinetic = impactStats.ke0 }, 0.3, 0, FAKE_OWNER, HITGROUP_HEAD, gun, "AP")
ok(hitres and hitres.Kill == false and hitres.Loss == 1, "damage: squishy fallback hit result contract")

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error("fire selftest failed") end
print("ARC9-ACE fire path selftest OK")
