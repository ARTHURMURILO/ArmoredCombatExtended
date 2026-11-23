--[[
	ARC9 <-> ACE bridge: shared configuration.

	Everything in this file is data plus small pure helpers. It is intentionally
	free of engine APIs so that the conversion layer can be exercised by the
	LuaJIT test harness outside Garry's Mod.
]]

ARC9ACE = ARC9ACE or {}

local C = ARC9ACE

C.Version = "0.1.0"

-- GMod Hammer units per metre. ARC9 stores projectile velocities in HU/s,
-- ACE stores them in m/s. ARC9.HUToM is the same constant but ARC9 may not be
-- loaded when this file is included, so keep a local copy.
C.HUToM = 0.0254
C.MPerHU = 1 / 39.37

-- Fallbacks for ACE global constants in case they are read before ACE loads.
C.Defaults = {
	PenAreaMod = 0.85, -- ACE.PenAreaMod
	PBase = 1050, -- ACE.PBase (kj produced by 1 kg of propellant)
	DragDiv = 40, -- ACE.DragDiv
	LimitVel = 750, -- ACE AP "most efficient penetration speed" (m/s)
	Ricochet = 53, -- ACE AP base ricochet angle (degrees)
	ShovePower = 0.2,
	KETransfert = 0.3,
	MuzzleVel = 800, -- m/s, only used when a weapon reports nothing
	ReferenceBC = 0.30, -- G1 BC treated as "typical" for drag normalisation
	DragBCMin = 0.55, -- clamp on ReferenceBC / BC
	DragBCMax = 2.2,
	FallbackMassRatio = 0.40, -- bullet mass / cartridge mass when nothing better exists
	MaxPellets = 64,
	PenMultiplier = 1.0, -- global scale on the pen-class multiplier (arc9ace_pen_mult)
	DragCalibration = 0.00106, -- ACE drag coefficient for a 0.30 G1 BC projectile
	DragBCMin = 0.4,
	DragBCMax = 3.0,
}

--[[
	EFT ammunition category token -> bore diameter in centimetres.

	ARC9 EFT ammo attachments live in categories named "eft_ammo_<token>",
	e.g. ATT.Category = {"eft_ammo_556"}. The token is the pack's own shorthand
	for the cartridge family. This table is the pack-level part of the mapping:
	it tells ACE what bore the pack means.

	Shotgun shells are stored as their nominal bore here; per-shell pellet
	diameters are overridden by the generated ammunition map.
]]
C.CaliberByToken = {
	["4630"] = 0.46, -- 4.6x30mm
	["57"] = 0.57, -- 5.7x28mm
	["9x18"] = 0.90, -- 9x18mm PM
	["9x19"] = 0.90, -- 9x19mm Parabellum
	["9x21"] = 0.90, -- 9x21mm Gyurza
	["9x39"] = 0.90, -- 9x39mm
	["45acp"] = 1.143, -- .45 ACP (11.43 mm)
	["50ae"] = 1.270, -- .50 AE (12.7 mm)
	["357"] = 0.907, -- .357 Magnum (9.07 mm)
	["12755"] = 1.27, -- 12.7x55mm
	["12x70"] = 1.85, -- 12/70 bore
	["20x70"] = 1.56, -- 20/70 bore
	["23x75"] = 2.30, -- 23x75mm (KS-23)
	["26x75"] = 2.60, -- 26x75mm flare
	["40x46"] = 4.00, -- 40x46mm grenade
	["366"] = 0.955, -- .366 TKM (9.55 mm)
	["545"] = 0.545, -- 5.45x39mm
	["556"] = 0.556, -- 5.56x45mm
	["556bb"] = 0.556, -- 5.56 blank / BB
	["58x42"] = 0.58, -- 5.8x42mm
	["68x51"] = 0.68, -- 6.8x51mm
	["76239"] = 0.762, -- 7.62x39mm
	["762x51"] = 0.762, -- 7.62x51mm
	["762x54r"] = 0.762, -- 7.62x54mmR
	["762x25tt"] = 0.762, -- 7.62x25mm Tokarev
	["300blk"] = 0.762, -- .300 BLK
	["308me"] = 0.782, -- .308 Marlin Express (7.82 mm)
	["338"] = 0.860, -- .338 Lapua Magnum (8.6 mm)
	["93x64"] = 0.93, -- 9.3x64mm
	["50bmg"] = 1.27, -- .50 BMG
}

--[[
	Cartridge-family bullet/cartridge mass ratios, used only when the
	projectile mass cannot be read from the attachment description and the
	generated ammunition map has no entry. Keyed by token.
]]
C.MassRatioByToken = {
	["4630"] = 0.36,
	["57"] = 0.36,
	["9x18"] = 0.55,
	["9x19"] = 0.58,
	["9x21"] = 0.55,
	["9x39"] = 0.50,
	["45acp"] = 0.53,
	["50ae"] = 0.63,
	["357"] = 0.55,
	["12755"] = 0.55,
	["366"] = 0.47,
	["545"] = 0.31,
	["556"] = 0.32,
	["556bb"] = 0.32,
	["58x42"] = 0.32,
	["68x51"] = 0.42,
	["76239"] = 0.49,
	["762x51"] = 0.40,
	["762x54r"] = 0.40,
	["762x25tt"] = 0.55,
	["300blk"] = 0.45,
	["308me"] = 0.40,
	["338"] = 0.42,
	["93x64"] = 0.42,
	["50bmg"] = 0.43,
}

--[[
	Weapon Trivia calibre phrase key -> pack ammo token.

	EFT weapon files store the calibre only as a localisation phrase such as
	ARC9:GetPhrase("eft_trivia_calibr_556x45"). This mapping lets the bridge
	recover a calibre for a weapon whose ammo slot is empty.
]]
C.TriviaCaliberToken = {
	["eft_trivia_calibr_545x39"] = "545",
	["eft_trivia_calibr_556x45"] = "556",
	["eft_trivia_calibr_58x42"] = "58x42",
	["eft_trivia_calibr_68x51"] = "68x51",
	["eft_trivia_calibr_762x39"] = "76239",
	["eft_trivia_calibr_762x51"] = "762x51",
	["eft_trivia_calibr_762x54"] = "762x54r",
	["eft_trivia_calibr_762x25"] = "762x25tt",
	["eft_trivia_calibr_762x35"] = "300blk",
	["eft_trivia_calibr_9x18"] = "9x18",
	["eft_trivia_calibr_9x19"] = "9x19",
	["eft_trivia_calibr_9x21"] = "9x21",
	["eft_trivia_calibr_9x39"] = "9x39",
	["eft_trivia_calibr_357"] = "357",
	["eft_trivia_calibr_45acp"] = "45acp",
	["eft_trivia_calibr_50ae"] = "50ae",
	["eft_trivia_calibr_46x30"] = "4630",
	["eft_trivia_calibr_57x28"] = "57",
	["eft_trivia_calibr_127x55"] = "12755",
	["eft_trivia_calibr_338lm"] = "338",
	["eft_trivia_calibr_93x64"] = "93x64",
	["eft_trivia_calibr_50bmg"] = "50bmg",
	["eft_trivia_calibr_20x1"] = "20x70",
}

--[[
	Nominal projectile masses (kg) per cartridge token, used when a cartridge
	has no readable weight in its description and no generated map entry
	(modded/extra EFT ammo packs). Values are typical service projectiles.
]]
C.NominalMassByToken = {
	["4630"] = 0.0020,
	["57"] = 0.0024,
	["9x18"] = 0.0060,
	["9x19"] = 0.0075,
	["9x21"] = 0.0076,
	["9x39"] = 0.0160,
	["45acp"] = 0.0149,
	["50ae"] = 0.0194,
	["357"] = 0.0100,
	["12755"] = 0.0180,
	["366"] = 0.0120,
	["545"] = 0.0035,
	["556"] = 0.0040,
	["556bb"] = 0.0020,
	["58x42"] = 0.0050,
	["68x51"] = 0.0087,
	["76239"] = 0.0079,
	["762x51"] = 0.0095,
	["762x54r"] = 0.0096,
	["762x25tt"] = 0.0055,
	["300blk"] = 0.0120,
	["308me"] = 0.0096,
	["338"] = 0.0154,
	["93x64"] = 0.0160,
	["50bmg"] = 0.0460,
}

--[[
	Penetration classes for ACE conversion.

	EFT's ARC9 attachment exposes a "penetration power" (shown in-game as the
	meaningless ARC9 stat). The bridge classifies each cartridge into one of
	these classes and scales ACE's penetration area accordingly
	(pen = energy / PenArea * KEtoRHA, so PenArea / penMul = pen x penMul).

	  soft : expanding / hollow point / fragmenting (HP class round)
	  fmj  : standard ball ammunition
	  ap   : steel-core / hardened penetrator ammunition
	  apcr : tungsten-carbide / sabot / APCR-class penetrators (ACE HVAP-like)

	LimitVel is ACE's "most efficient penetration speed"; raising it for AP
	classes removes ACE's high-velocity penetration penalty, matching how
	sub-calibre penetrators behave.
]]
C.PenClasses = {
	soft = { penMul = 0.80, limitVel = 400, bulletType = "HP", label = "HP" },
	fmj  = { penMul = 1.00, limitVel = 750, bulletType = "AP", label = "FMJ" },
	ap   = { penMul = 2.20, limitVel = 800, bulletType = "AP", label = "AP" },
	apcr = { penMul = 3.20, limitVel = 1000, bulletType = "AP", label = "APCR" },
}

-- Classification markers, checked in this order: APCR, AP, soft, FMJ.
C.PenClassMarkers = {
	apcr = {
		"m995", "ssaap", "m993", "apiz", "ap-iz", "ppbs", "7n39", "slap",
		"m903", "sabot", "tungsten", "apcr", "flechette", "pab-9", "322",
		"lm ap", -- .338 LM AP (tungsten core)
	},
	ap = {
		" ap", "ap ", "_ap", "bp", "bs", "bt", "7n", "penetrator", "steel core",
		"ps12b", "spp", "sp-6", "m855a1", "armor-piercing", "armour-piercing",
	},
	soft = {
		" hp", "hp ", "hollow", " sp", "sp ", "soft point", "rip ", "rip_",
		"expansive", "warmageddon", "quakemaker", "predator", "devastator",
		"fragmenting", "segmented",
	},
	fmj = {
		"fmj", "m80", "m33", "m62", "ball", "slug", "lead",
	},
}

-- Penetration-power thresholds used only when no marker matches at all
-- (modded ammunition with arbitrary names). Tuned against EFT's own values:
-- EFT FMJ rounds sit around 23-33, AP rounds around 40-60, APCR above 55.
C.PenPowerThresholds = {
	apcr = 60,
	ap = 45,
	fmj = 25,
}

--[[
	Mass of a shotgun shell's non-projectile parts (hull + wad + powder), in kg.
	Used to recover pellet mass for shells whose description does not name a
	pellet weight: pelletMass = (shellWeight - caseMass) / pelletCount.
]]
C.ShellCaseMass = {
	[1.85] = 0.0045, -- 12/70
	[1.56] = 0.0040, -- 20/70
	[2.30] = 0.0090, -- 23x75
}

-- Calibres (cm) that are shotgun bores rather than single projectiles.
C.ShotgunBores = {
	[1.85] = true,
	[1.56] = true,
	[2.30] = true,
}

--[[ Numeric helpers ]]--
function C.Clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function C.Round(v, decimals)
	local m = 10 ^ (decimals or 0)
	return math.floor(v * m + 0.5) / m
end

-- Convert a pack ammo category (string or list) into a token, e.g.
-- "eft_ammo_556" -> "556". Returns nil for non-ammo categories.
function C.TokenFromCategory(cat)
	if istable(cat) then
		for _, c in ipairs(cat) do
			local token = C.TokenFromCategory(c)
			if token then return token end
		end
		return nil
	end

	if not isstring(cat) then return nil end
	return string.match(cat, "^eft_ammo_([%w]+)$")
end

--- Strip the numeric marker noise from an attachment id/name for matching.
local function lowerText(att)
	if not att then return "" end
	return string.lower(tostring(att.ShortName or "") .. " " .. tostring(att.PrintName or ""))
end

--- Classify a cartridge into a penetration class.
-- @tparam table att ARC9 attachment table.
-- @tparam number penPower EFT penetration power (or processed ARC9 Penetration).
-- @treturn string class key into C.PenClasses.
-- Match a marker in the lower-cased id/name. Short alphabetic markers ("ap",
-- "bp", "bs", ...) need word boundaries so "subsonic" does not match "bs".
local function containsMarker(text, marker)
	if #marker <= 4 and string.find(marker, "^[%a%d]+$") then
		return string.find(text, "%f[%w]" .. marker .. "%f[%W]") ~= nil
	end
	return string.find(text, marker, 1, true) ~= nil
end

function C.ResolvePenClass(att, penPower)
	local text = lowerText(att)

	-- Explicit markers win (M995, AP-IZ, PAB-9, APCR, sabot, ...).
	for _, marker in ipairs(C.PenClassMarkers.apcr) do
		if containsMarker(text, marker) then return "apcr" end
	end

	for _, marker in ipairs(C.PenClassMarkers.ap) do
		if containsMarker(text, marker) then return "ap" end
	end

	for _, marker in ipairs(C.PenClassMarkers.soft) do
		if containsMarker(text, marker) then return "soft" end
	end

	for _, marker in ipairs(C.PenClassMarkers.fmj) do
		if containsMarker(text, marker) then return "fmj" end
	end

	local power = tonumber(penPower)
	if power then
		if power >= C.PenPowerThresholds.apcr then return "apcr" end
		if power >= C.PenPowerThresholds.ap then return "ap" end
		if power >= C.PenPowerThresholds.fmj then return "fmj" end
	end

	return "soft"
end

function C.CaliberCmForToken(token)
	if not token then return nil end
	return C.CaliberByToken[token]
end
