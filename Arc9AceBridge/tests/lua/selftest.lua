--[[
	Self-test for the ARC9 <-> ACE bridge conversion layer.

	Runs under LuaJIT through tests/run_tests.py, which provides:
	  * GMod type/helper stubs,
	  * the real ACE_MuzzleVelocity / ACE_Kinetic / ACE_CalcPenetration code,
	  * the bridge config, generated ammo map and conversion module.

	Every assertion prints a PASS line; the script errors out (non-zero exit)
	on the first failure.
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
	local diff = math.abs((actual or 0) - expected)
	ok(diff <= tolerance, label, string.format("got %.4f expected %.4f", actual or 0, expected))
end

local function inRange(actual, lo, hi, label)
	ok(actual ~= nil and actual >= lo and actual <= hi, label,
		string.format("got %s expected [%.4f, %.4f]", tostring(actual), lo, hi))
end

--[[----------------------------------------------------------------------------
	Fake ARC9 environment
]]------------------------------------------------------------------------------

local ATT = {}
function ARC9GetAttTable(name)
	return ATT[name]
end

-- Installed on the server by ARC9 itself; provided here for the test.
ARC9 = { GetAttTable = ARC9GetAttTable, HUToM = 0.0254 }

local function makeAtt(id, name, category, description, extra)
	local att = {
		ShortName = id,
		PrintName = name,
		Category = type(category) == "table" and category or { category },
		Description = description,
	}
	for k, v in pairs(extra or {}) do att[k] = v end
	ATT[id] = att
	return att
end

local function makeSwep(values, slots)
	local swep = { values = values or {}, slots = slots or {} }
	function swep:GetProcessedValue(key) return self.values[key] end
	function swep:GetSubSlotList() return self.slots end
	return swep
end

--[[----------------------------------------------------------------------------
	1. Description mass parsing
]]------------------------------------------------------------------------------

local parse = C.ParseDescriptionMassGrams

near(parse("A cartridge with a 3.6 gram lead core bullet."), 3.6, 1e-6, "parse: plain gram")
near(parse(".50 AE cartridge with a 300 grain flat-nose bullet."), 300 * 0.06479891, 1e-6, "parse: grain")
near(parse("40gr. Jacketed Soft Point Ammo"), 40 * 0.06479891, 1e-6, "parse: gr abbreviation")
near(parse("a 124 grain armor-piercing bullet, in a 12 gram case"), 124 * 0.06479891, 1e-6, "parse: grain first wins")
ok(parse("A 12/70 slug shell for 12 gauge shotguns.") == nil, "parse: no weight returns nil")
ok(parse(nil) == nil, "parse: nil description is nil")
ok(parse("") == nil, "parse: empty description is nil")

--[[----------------------------------------------------------------------------
	2. Category token / calibre table
]]------------------------------------------------------------------------------

ok(C.TokenFromCategory("eft_ammo_556") == "556", "token: 5.56")
ok(C.TokenFromCategory({"eft_ammo_545"}) == "545", "token: 5.45 list")
ok(C.TokenFromCategory("eft_ammo_12x70") == "12x70", "token: 12 gauge")
ok(C.TokenFromCategory("eft_ar15_mag") == nil, "token: non-ammo category")
ok(C.TokenFromCategory(nil) == nil, "token: nil category")
near(C.CaliberByToken["556"], 0.556, 1e-9, "calibre: 5.56 token")
near(C.CaliberByToken["12x70"], 1.85, 1e-9, "calibre: 12ga token")
near(C.CaliberByToken["50bmg"] * 10, 12.7, 1e-9, "calibre: .50 BMG is 12.7mm")

-- Imperial-designated cartridges must be converted to millimetres, not treated
-- as if the inch number were millimetres.
near(C.CaliberByToken["338"] * 10, 8.6, 1e-9, "calibre: .338 LM is 8.6mm")
near(C.CaliberByToken["357"] * 10, 9.07, 1e-9, "calibre: .357 is 9.07mm")
near(C.CaliberByToken["45acp"] * 10, 11.43, 1e-9, "calibre: .45 ACP is 11.43mm")
near(C.CaliberByToken["50ae"] * 10, 12.7, 1e-9, "calibre: .50 AE is 12.7mm")
near(C.CaliberByToken["366"] * 10, 9.55, 1e-9, "calibre: .366 TKM is 9.55mm")
near(C.CaliberByToken["308me"] * 10, 7.82, 1e-9, "calibre: .308 Marlin is 7.82mm")

--[[----------------------------------------------------------------------------
	3. Attachment description (pack data -> projectile profile)
]]------------------------------------------------------------------------------

-- Real values from the EFT pack (5.56x45mm FMJ).
local a556 = makeAtt("eft_ammo_556_fmj", "5.56x45mm FMJ", "eft_ammo_556",
	"A 5.56x45mm NATO FMJ cartridge with a 3.6 gram lead core bullet with a copper jacket.",
	{ PhysBulletMuzzleVelocity = 957 / 0.0254, DamageMax = 57, BallisticCoefficient = 0.252,
	  EFTWeightAdd = 0.012, Penetration = 23 * 1.0, Num = 1 })

local d556 = C.DescribeAttachment(a556)
ok(d556 ~= nil, "describe: 5.56 FMJ")
near(d556.cal, 0.556, 1e-9, "describe: 5.56 calibre")
near(d556.mass, 0.0036, 1e-6, "describe: 5.56 projectile mass")
near(d556.mv, 957, 1e-6, "describe: 5.56 muzzle velocity")
inRange(d556.eftDamage, 1, 500, "describe: 5.56 EFT damage")
inRange(d556.penPower, 20, 30, "describe: 5.56 penetration power")
ok(d556.type == "AP" or d556.type == "HP", "describe: 5.56 projectile class")

-- Real values from the EFT pack (7.62x51 M80).
local a762 = makeAtt("eft_ammo_762x51_m80", "7.62x51mm M80", "eft_ammo_762x51",
	"A 7.62x51mm NATO M80 cartridge with a 9.5 gram bullet with a lead core and a bimetallic jacket.",
	{ PhysBulletMuzzleVelocity = 820 / 0.0254, DamageMax = 80, BallisticCoefficient = 0.398,
	  EFTWeightAdd = 0.024, Penetration = 43, Num = 1 })

local d762 = C.DescribeAttachment(a762)
near(d762.cal, 0.762, 1e-9, "describe: 7.62 calibre")
near(d762.mass, 0.0095, 1e-6, "describe: 7.62 projectile mass")
inRange(d762.penPower, 40, 46, "describe: 7.62 penetration power")

-- Shotgun shell fallback (shell weight - case) / pellets. No gram in text.
local a12 = makeAtt("eft_ammo_12x70_buck", "12/70 8.5mm buckshot", "eft_ammo_12x70",
	"A 12/70 shell loaded with 8.5mm buckshot.",
	{ PhysBulletMuzzleVelocity = 340 / 0.0254, DamageMax = 50, BallisticCoefficient = 0.1,
	  EFTWeightAdd = 0.05, Penetration = 5, Num = 9 })

local d12 = C.DescribeAttachment(a12)
near(d12.cal, 1.85, 1e-9, "describe: 12ga slug fallback calibre")
ok(d12.mass ~= nil and d12.mass > 0, "describe: 12ga mass fallback present")
inRange(d12.mass, 0.0005, 0.06, "describe: 12ga mass fallback sane")

-- Unknown token (non-EFT weapon) still gets a tokenless description; calibre
-- must come from the map or from provided override.
local aUnknown = makeAtt("some_pack_ammo", "Unknown", "other_ammo", "A mystery round with a 5 gram bullet.")
local dUnknown = C.DescribeAttachment(aUnknown)
ok(dUnknown ~= nil, "describe: non-EFT ammo still descriptive")
near(dUnknown.mass, 0.005, 1e-9, "describe: non-EFT mass from description")
ok(dUnknown.cal == nil, "describe: non-EFT calibre unknown")

--[[----------------------------------------------------------------------------
	4. GenerateEFTAttachment semantics: Penetration = penPower * mult (mult = 1)
]]------------------------------------------------------------------------------

local aPen = makeAtt("eft_ammo_545_bp", "5.45x39mm BP", "eft_ammo_545",
	"A 5.45x39mm BP cartridge with a 3.7 gram bullet.",
	{ PhysBulletMuzzleVelocity = 890 / 0.0254, DamageMax = 48, BallisticCoefficient = 0.252,
	  EFTWeightAdd = 0.010, Penetration = 45, Num = 1, EFTRoundName = "eft_ammo_545_bp" })

local dPen = C.DescribeAttachment(aPen)
inRange(dPen.penPower, 40, 50, "describe: penetration power recovered from Penetration")

--[[----------------------------------------------------------------------------
	5. ComputeStats (engine-facing half)
]]------------------------------------------------------------------------------

local swep556 = makeSwep({
	PhysBulletMuzzleVelocity = 957 / 0.0254,
	Num = 1,
	DamageMax = 57,
})

local slots556 = { { Installed = "eft_ammo_556_fmj", Category = {"eft_ammo_556"} } }
swep556.slots = slots556

local stats = C.ComputeStats(swep556)
ok(stats ~= nil, "compute: 5.56 stats")
near(stats.cal, 0.556, 1e-9, "compute: 5.56 calibre")
near(stats.mass, 0.0036, 1e-6, "compute: 5.56 mass")
near(stats.mv, 957, 1e-6, "compute: 5.56 muzzle velocity")
near(stats.num, 1, 1e-9, "compute: 5.56 pellet count")
inRange(stats.frArea, 0.24, 0.25, "compute: 5.56 frontal area")
inRange(stats.penArea, 0.25, 0.31, "compute: 5.56 penetration area")
inRange(stats.dragCoef, 0.001, 0.1, "compute: 5.56 drag coefficient")
inRange(stats.propMass, 0.0005, 0.01, "compute: 5.56 equivalent powder mass")
inRange(stats.ke0, 1.0, 2.0, "compute: 5.56 muzzle energy kJ")

-- ARC9 processes attachment Num overrides: buckshot shell gives pellet count 9.
local swep12 = makeSwep({
	PhysBulletMuzzleVelocity = 340 / 0.0254,
	Num = 9,
	DamageMax = 50,
}, { { Installed = "eft_ammo_12x70_buck", Category = {"eft_ammo_12x70"} } })

local stats12 = C.ComputeStats(swep12)
ok(stats12 ~= nil, "compute: 12ga stats")
near(stats12.num, 9, 1e-9, "compute: 12ga pellet count")

-- Suppressor-style processed muzzle velocity multiplier still applies.
local swepSuppressed = makeSwep({
	PhysBulletMuzzleVelocity = (957 * 0.85) / 0.0254,
	Num = 1,
	DamageMax = 57,
}, slots556)
local statsSup = C.ComputeStats(swepSuppressed)
near(statsSup.mv, 957 * 0.85, 1e-4, "compute: suppressed muzzle velocity")

-- No ammo slot and no trivia -> no mapping (falls back to ARC9).
local statsNone = C.ComputeStats(makeSwep({}, {}))
ok(statsNone == nil, "compute: no ammo slot returns nil")

--[[----------------------------------------------------------------------------
	6. BuildBulletData
]]------------------------------------------------------------------------------

local bd = C.BuildBulletData(stats)
ok(bd.Type == "AP" or bd.Type == "HP", "bullet: Type set")
near(bd.Caliber, 0.556, 1e-9, "bullet: Caliber")
near(bd.ProjMass, 0.0036, 1e-6, "bullet: ProjMass")
near(bd.MuzzleVel, 957, 1e-6, "bullet: MuzzleVel")
near(bd.PenArea, stats.penArea, 1e-12, "bullet: PenArea")
near(bd.DragCoef, stats.dragCoef, 1e-12, "bullet: DragCoef")
near(bd.LimitVel, bd.Type == "HP" and 400 or 750, 1e-9, "bullet: LimitVel")
near(bd.Ricochet, 53, 1e-9, "bullet: Ricochet")
ok(bd.Tracer == 0 or bd.Tracer == 1, "bullet: Tracer flag")
ok(bd.ARC9Bridge == true, "bullet: bridge marker")
near(bd.ARC9KE0, stats.ke0, 1e-12, "bullet: KE0 snapshot")

--[[----------------------------------------------------------------------------
	7. ACE ballistics sanity: muzzle penetration must be plausible for calibre
]]------------------------------------------------------------------------------

local function muzzlePen(s)
	local energy = ACE.Kinetic(s.mv * 39.37, s.mass, s.limitVel)
	return ACE.CalcPenetration(energy, s.penArea)
end

local pen556 = muzzlePen(stats)
inRange(pen556, 3, 40, "ace: 5.56 muzzle RHA penetration (mm)")
print(string.format("     5.56 FMJ  : %.1f mm RHA @ %d m/s, KE=%.2f kJ", pen556, stats.mv, stats.ke0))

local pen12 = muzzlePen(stats12)
inRange(pen12, 0.1, 40, "ace: 12ga pellet muzzle penetration (mm)")
print(string.format("     12ga buck : %.2f mm RHA per pellet @ %d m/s", pen12, stats12.mv))

-- .338 LM AP should be dramatically better than 5.56.
local a338 = makeAtt("eft_ammo_338_ap", ".338 LM AP", "eft_ammo_338",
	"A .338 Lapua Magnum AP cartridge with a 15.4 gram tungsten carbide bullet.",
	{ PhysBulletMuzzleVelocity = 849 / 0.0254, DamageMax = 115, BallisticCoefficient = 0.477,
	  EFTWeightAdd = 0.049, Penetration = 79, Num = 1 })
ATT["eft_ammo_338_ap"] = a338

local swep338 = makeSwep({
	PhysBulletMuzzleVelocity = 849 / 0.0254,
	Num = 1,
	DamageMax = 115,
}, { { Installed = "eft_ammo_338_ap", Category = {"eft_ammo_338"} } })

local stats338 = C.ComputeStats(swep338)
local pen338 = muzzlePen(stats338)
ok(pen338 > pen556 * 1.5, "ace: .338 penetrates much more than 5.56",
	string.format(".338 %.1fmm vs 5.56 %.1fmm", pen338, pen556))
print(string.format("     .338 AP   : %.1f mm RHA @ %d m/s, KE=%.2f kJ", pen338, stats338.mv, stats338.ke0))

-- Penetration classes: steel-core AP gets a 2.2x bonus, tungsten/sabot APCR
-- 3.2x, plain ball 1.0x and expanding rounds are slightly reduced.
ok(C.ResolvePenClass(a556, 23) == "fmj", "penclass: 5.56 FMJ is fmj")
ok(C.ResolvePenClass({ ShortName = "x", PrintName = "Unknown round" }, 45) == "ap",
	"penclass: high-pen unknown round is ap by threshold")
ok(C.ResolvePenClass(a338, 79) == "apcr", "penclass: .338 LM AP is apcr (tungsten core)")
ok(C.ResolvePenClass({ ShortName = "eft_ammo_556_m995", PrintName = "5.56 M995" }, 53) == "apcr",
	"penclass: M995 is apcr")
ok(C.ResolvePenClass({ ShortName = "eft_ammo_762x39_apiz", PrintName = "7.62x39 AP-IZ" }, 57) == "apcr",
	"penclass: AP-IZ is apcr")
ok(C.ResolvePenClass({ ShortName = "x", PrintName = "9x19 subsonic" }, 15) ~= "ap",
	"penclass: subsonic does not match bs marker")

-- 7.62x51 M993 (tungsten AP) should reach ~21 mm RHA at the muzzle.
local aM993 = makeAtt("eft_ammo_762x51_m993", "7.62x51mm M993", "eft_ammo_762x51",
	"A 7.62x51mm NATO M993 cartridge with a 8.2 gram tungsten carbide core bullet.",
	{ PhysBulletMuzzleVelocity = 900 / 0.0254, DamageMax = 90, BallisticCoefficient = 0.36,
	  EFTWeightAdd = 0.024, Penetration = 57, Num = 1 })
ATT["eft_ammo_762x51_m993"] = aM993
local swepM993 = makeSwep({ PhysBulletMuzzleVelocity = 900 / 0.0254, Num = 1, DamageMax = 90,
	Penetration = 57 }, { { Installed = "eft_ammo_762x51_m993", Category = {"eft_ammo_762x51"} } })
local statsM993 = C.ComputeStats(swepM993)
ok(statsM993.penClass == "APCR", "penclass: M993 computed class", tostring(statsM993.penClass))
local penM993 = muzzlePen(statsM993)
inRange(penM993, 16, 26, "ace: 7.62 M993 muzzle RHA ~21mm")
print(string.format("     7.62 M993 : %.1f mm RHA @ %d m/s (%s x%.2f)",
	penM993, statsM993.mv, statsM993.penClass, statsM993.penMul))

-- FMJ/ball and slugs must stay in the ball class, not be promoted by pen alone.
ok(C.ResolvePenClass(a556, 45) == "fmj", "penclass: 5.56 FMJ keeps fmj despite high pen")
ok(C.ResolvePenClass({ ShortName = "eft_ammo_12x70_slug", PrintName = "12/70 lead slug" }, 15) == "fmj",
	"penclass: 12ga slug is fmj not soft")

-- FMJ baseline should stay modest (~5mm) so buffs are meaningful.
inRange(muzzlePen(stats), 4, 7, "ace: 5.56 FMJ muzzle RHA ~5mm")

-- Drag calibration: a 5.56 must retain most of its speed at 300 m, not die
-- inside 100 m like ACE's shell-drag convention did.
local dragCoef = stats.dragCoef
local function velAtRange(v0, dist, drag)
	local v, x = v0, 0
	while x < dist do
		local a = 0.984 * drag * v * v
		v = v - a * 0.0005
		x = x + v * 0.0005
	end
	return v
end
local v300 = velAtRange(stats.mv, 300, dragCoef)
inRange(v300, 600, 760, "ace: 5.56 velocity at 300m ~660 m/s")
print(string.format("     5.56 drag : v(300m) = %.0f m/s (drag %.5f)", v300, dragCoef))

-- Drag must be finite and positive for every sample.
for _, s in ipairs({ stats, stats12, stats338 }) do
	ok(s.dragCoef > 0 and s.dragCoef < 1, "ace: drag coefficient sane for " .. tostring(s.ammo.id))
end

--[[----------------------------------------------------------------------------
	8. Generated ammunition map validation
]]------------------------------------------------------------------------------

local map = C.EFTAmmoMap or {}
local mapCount = 0
local problems = {}
local types = { AP = 0, HP = 0 }

for id, entry in pairs(map) do
	mapCount = mapCount + 1
	if type(entry) ~= "table" then
		problems[#problems + 1] = id .. ": entry not a table"
	else
		if not (tonumber(entry.cal) and entry.cal > 0.1 and entry.cal < 6) then
			problems[#problems + 1] = id .. ": bad cal " .. tostring(entry.cal)
		end
		if not (tonumber(entry.mass) and entry.mass >= 0.0002 and entry.mass <= 0.12) then
			problems[#problems + 1] = id .. ": bad mass " .. tostring(entry.mass)
		end
		if entry.type ~= "AP" and entry.type ~= "HP" then
			problems[#problems + 1] = id .. ": bad type " .. tostring(entry.type)
		end
		if entry.type == "AP" then types.AP = types.AP + 1 elseif entry.type == "HP" then types.HP = types.HP + 1 end
	end
end

if mapCount == 0 then
	print("SKIP  generated ammo map is empty (stub) — run tools/gen_eft_ammo_map.py")
else
	for _, problem in ipairs(problems) do
		print("      map problem: " .. problem)
	end
	ok(#problems == 0, "map: every entry has cal/mass/type", string.format("%d entries", mapCount))
	ok(mapCount >= 140, "map: entry count", tostring(mapCount))
	print(string.format("     map: %d entries (%d AP, %d HP)", mapCount, types.AP, types.HP))

	-- Spot-check a handful of important cartridges if the map has them.
	local expected = {
		eft_ammo_556_fmj = { cal = 0.556, massLo = 0.0025, massHi = 0.0055 },
		eft_ammo_545_ps = { cal = 0.545, massLo = 0.0025, massHi = 0.0050 },
		eft_ammo_762x51_m80 = { cal = 0.762, massLo = 0.0080, massHi = 0.0110 },
		eft_ammo_338_ap = { cal = 0.86, massLo = 0.0120, massHi = 0.0180 },
	}
	for id, want in pairs(expected) do
		local entry = map[id]
		if entry then
			near(entry.cal, want.cal, 1e-9, "map: " .. id .. " calibre")
			inRange(entry.mass, want.massLo, want.massHi, "map: " .. id .. " mass")
		else
			print("WARN  map: missing spot-check entry " .. id)
		end
	end
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then error("selftest failed") end
print("ARC9-ACE bridge selftest OK")
