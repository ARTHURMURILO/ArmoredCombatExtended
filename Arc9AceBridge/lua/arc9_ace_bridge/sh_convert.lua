--[[
	ARC9 <-> ACE bridge: ammunition resolution and BulletData conversion.

	The bridge turns an ARC9 weapon's *currently installed ammunition
	attachment* plus its processed stats into an ACE BulletData table:

	   Attachment (EFT pack)            ACE projectile
	   -------------------------------- -------------------------------
	   calibre (from category)          Caliber (cm)
	   projectile mass (description /  ProjMass (kg)
	     generated map / shell data)
	   PhysBulletMuzzleVelocity (HU/s)  MuzzleVel (m/s) + Flight vector
	   BallisticCoefficient (G1)        DragCoef (ACE quadratic drag)
	   penetration power                LimitVel / Type (AP or HP)
	   damage (EFT scale)               player damage model (sv_damage)

	The pure/table-only functions (`DescribeAttachment`, `BuildBulletData`)
	have no engine dependency so they can be tested with LuaJIT.
]]

ARC9ACE = ARC9ACE or {}
local C = ARC9ACE
local D = C.Defaults

--[[----------------------------------------------------------------------------
	Small helpers
]]------------------------------------------------------------------------------

local function toNumber(v)
	return isnumber(v) and v or tonumber(v)
end

-- Read the first "<n> gram" or "<n> grain"/"gr" occurrence in an attachment
-- description. EFT pack descriptions always lead with the projectile weight
-- ("... with a 3.6 gram lead core bullet"). Returns grams or nil.
function C.ParseDescriptionMassGrams(desc)
	if not isstring(desc) or desc == "" then return nil end

	local gramPos, _, gramVal = string.find(desc, "([%d%.]+)%s*gram")
	local grainPos, _, grainVal = string.find(desc, "([%d%.]+)%s*grain")
	local grPos, _, grVal = string.find(desc, "([%d%.]+)%s*gr%p")

	-- Pick whichever unit appears first in the sentence, but prefer "gram"
	-- over "grain" when they start at the same place.
	local bestPos, grams
	if gramPos and (not grainPos or gramPos <= grainPos) then
		bestPos = gramPos
		grams = tonumber(gramVal)
	elseif grainPos then
		bestPos = grainPos
		grams = tonumber(grainVal) * 0.06479891
	elseif grPos then
		bestPos = grPos
		grams = tonumber(grVal) * 0.06479891
	end

	if not grams or grams <= 0 then return nil end
	return grams
end

function C.TokenFromAttachment(att)
	if not att then return nil end
	return C.TokenFromCategory(att.Category)
end

local function shortname(att)
	return att and (att.ShortName or att.FullName)
end

function C.MapEntry(att)
	local id = shortname(att)
	if id and C.EFTAmmoMap then return C.EFTAmmoMap[id] end
	return nil
end

--[[----------------------------------------------------------------------------
	Attachment -> ammo description (pack data only, no engine calls)
]]------------------------------------------------------------------------------

--- Describe an ARC9 EFT ammunition attachment.
-- @tparam table att ARC9 attachment table (must be an EFT ammo attachment).
-- @treturn table|nil info `{id, token, cal, mass, mv, bc, eftDamage, penPower, type, tracer, massSource}`
function C.DescribeAttachment(att)
	if not att then return nil end

	local id = shortname(att)
	local map = C.MapEntry(att) or {}
	local token = map.token or C.TokenFromAttachment(att)

	-- Calibre: generated map override first (shotgun pellets), then the pack
	-- category token table.
	local cal = map.cal or C.CaliberCmForToken(token)

	-- Fallback muzzle velocity (HU/s converted to m/s) from the attachment.
	local mv
	local rawVel = toNumber(att.PhysBulletMuzzleVelocity)
	if rawVel and rawVel > 0 then mv = rawVel * C.HUToM end

	local bc = toNumber(att.BallisticCoefficient) or map.bc
	local eftDamage = toNumber(att.DamageMax)
	local penPower = toNumber(att.EFTPenetrationPower)
	if not penPower then
		-- GenerateEFTAttachment stores Penetration = penPower * statmult.
		local pen = toNumber(att.Penetration)
		local statMult = (ARC9EFT and toNumber(ARC9EFT.PenetrationStatMult)) or 1.0
		if pen and statMult > 0 then penPower = pen / statMult end
	end

	-- Projectile mass (kg), in order of confidence.
	local mass, massSource
	if map.mass then
		mass = map.mass
		massSource = "map"
	end

	if not mass then
		local grams = C.ParseDescriptionMassGrams(att.Description)
		if grams then
			mass = grams / 1000
			massSource = "description"
		end
	end

	local num = tonumber(att.Num) or 1
	if not mass and C.ShotgunBores[cal] and toNumber(att.EFTWeightAdd) then
		-- Shell weight minus hull/wad/powder, split over the pellet count.
		local case = C.ShellCaseMass[cal] or 0.004
		local projectileTotal = math.max(toNumber(att.EFTWeightAdd) - case, 0.001)
		mass = projectileTotal / math.max(num, 1)
		massSource = "shell"
	end

	if not mass then
		local weight = toNumber(att.EFTWeightAdd)
		if weight and weight > 0 then
			local ratio = C.MassRatioByToken[token] or D.FallbackMassRatio
			mass = weight * ratio
			massSource = "cartridge-ratio"
		end
	end

	-- Last resort: nominal service projectile mass for the calibre. This is
	-- what makes modded/extra EFT ammo (e.g. EFT Extras' API Z) behave instead
	-- of failing with "no projectile mass".
	if not mass and token then
		mass = C.NominalMassByToken[token]
		massSource = mass and "nominal" or massSource
	end

	if mass then mass = C.Clamp(mass, 0.0002, 0.12) end

	-- Projectile class for ACE: AP for penetrating projectiles, HP for
	-- expanding/soft ones. Cannon FMJ is not a hollow point, so this is driven
	-- by the cartridge's own naming/description rather than penetration alone.
	-- The generated map can override this.
	local kind = map.type
	if not kind then
		kind = "AP"
		local lower = string.lower(tostring(att.PrintName or "") .. " " .. tostring(att.Description or "") .. " ")
		if penPower and penPower <= 10 then
			kind = "HP"
		elseif string.find(lower, "hollow", 1, true)
			or string.find(lower, " hp", 1, true)
			or string.find(lower, "hp ", 1, true)
			or string.find(lower, "soft point", 1, true)
			or string.find(lower, " sp", 1, true)
			or string.find(lower, "rip ", 1, true)
			or string.find(lower, "expansive", 1, true)
			or string.find(lower, "warmageddon", 1, true)
			or string.find(lower, "quakemaker", 1, true)
			or string.find(lower, "predator", 1, true)
			or string.find(lower, "devastator", 1, true)
			or string.find(lower, "fragment", 1, true)
			or string.find(lower, "segmented", 1, true) then
			kind = "HP"
		end
		if C.ShotgunBores[cal] and kind == "AP" then
			-- Pellets are soft lead; slug/sabot/flechette rounds stay AP.
			local idLower = string.lower(tostring(att.ShortName or ""))
			local isSlug = string.find(lower, "slug", 1, true) or string.find(lower, "sabot", 1, true)
				or string.find(lower, "flechette", 1, true) or string.find(lower, "ap-20", 1, true)
				or string.find(idLower, "slug", 1, true) or string.find(idLower, "sabot", 1, true)
				or string.find(idLower, "flechette", 1, true) or string.find(idLower, "ap20", 1, true)
				or string.find(idLower, "poleva", 1, true)
			if not isSlug then kind = "HP" end
		end
	end

	local tracer = map.tracer
	if tracer == nil then
		tracer = string.find(string.lower(id or ""), "tracer", 1, true) ~= nil
			or (id and (string.sub(id, -3) == "_t" or string.find(id, "t45m", 1, true) ~= nil
				or string.find(id, "t46m", 1, true) ~= nil))
	end

	return {
		id = id,
		name = att.PrintName or id,
		token = token,
		cal = cal,
		mass = mass,
		massSource = massSource,
		mv = mv,
		bc = bc,
		eftDamage = eftDamage,
		penPower = penPower,
		type = kind,
		tracer = tracer,
		num = num,
	}
end

--[[----------------------------------------------------------------------------
	Weapon-side resolution
]]------------------------------------------------------------------------------

--- Find the currently installed EFT ammunition attachment on an ARC9 weapon.
-- Iterates the weapon's attachment slots (same list ARC9 uses for rendering
-- and stat processing) and returns the installed attachment whose category is
-- an EFT ammo category.
-- @tparam Entity swep ARC9 weapon entity.
-- @treturn table|nil att
-- @treturn table|nil slot
function C.GetAmmoAttachment(swep)
	if not swep then return nil end

	local list = swep:GetSubSlotList()
	if not list then return nil end

	local visualOnly
	for _, slot in ipairs(list) do
		local installed = slot.Installed
		if installed then
			local att = ARC9 and ARC9.GetAttTable and ARC9.GetAttTable(installed) or nil
			if att then
				-- UBGL/grenade rounds must never shadow the primary rifle
				-- cartridge; they are handled by ARC9's rocket path instead.
				local isGrenade = att.HasGranataAmmo or att.EFTRoundName2

				if not isGrenade and (att.EFTRoundName or att.HasAmmoooooooo) then
					return att, slot
				end

				local token = C.TokenFromAttachment(att) or C.TokenFromCategory(slot.Category)
				if token and not isGrenade then
					visualOnly = visualOnly or { att, slot }
				end
			end
		end
	end

	if visualOnly then return visualOnly[1], visualOnly[2] end
	return nil
end

--- Recover a calibre from weapon trivia when the ammo slot is empty.
-- @tparam Entity swep ARC9 weapon entity.
-- @treturn number|nil calibre in cm
function C.GetTriviaCaliber(swep)
	if not swep then return nil end

	local trivia = swep.Trivia
	if type(swep.GetValue) == "function" then
		local value = swep:GetValue("Trivia")
		if istable(value) then trivia = value end
	end
	if not istable(trivia) then return nil end

	for _, value in pairs(trivia) do
		if isstring(value) then
			local token = C.TriviaCaliberToken[value]
			if token then return C.CaliberByToken[token], token end
		end
	end
	return nil
end

--- Build the numeric projectile profile for the weapon's current ammunition.
-- This is the engine-facing half: it reads ARC9 processed stats (which include
-- every installed attachment, e.g. suppressor muzzle velocity modifiers) and
-- combines them with the pack-level data from `DescribeAttachment`.
-- @tparam Entity swep ARC9 weapon entity.
-- @treturn table|nil stats
function C.ComputeStats(swep)
	local att = C.GetAmmoAttachment(swep)
	local info = C.DescribeAttachment(att)
	if not info then return nil, "no-ammo" end

	-- Calibre fallback: weapon trivia phrase.
	if not info.cal then
		local cal, token = C.GetTriviaCaliber(swep)
		if cal then
			info.cal = cal
			info.token = info.token or token
			info.massSource = info.massSource or "trivia-caliber"
		end
	end
	if not info.cal then return nil, "no-caliber" end

	-- Processed muzzle velocity (HU/s -> m/s). This is what ARC9 uses for its
	-- own physical bullets, so suppressors/barrel attachments are included.
	local mv
	local rawVel = swep:GetProcessedValue("PhysBulletMuzzleVelocity", true)
	if isnumber(rawVel) and rawVel > 0 then
		mv = rawVel * C.HUToM
	elseif info.mv then
		mv = info.mv
	else
		mv = D.MuzzleVel
	end

	-- Projectile mass fallback: derive from the cartridge mass ratio if the
	-- attachment gave us nothing usable.
	if not info.mass then
		local weight = toNumber(att.EFTWeightAdd)
		if weight and weight > 0 then
			local ratio = C.MassRatioByToken[info.token] or D.FallbackMassRatio
			info.mass = weight * ratio
			info.massSource = "cartridge-ratio"
		end
	end
	if not info.mass then return nil, "no-mass" end

	local num = swep:GetProcessedValue("Num")
	num = isnumber(num) and math.floor(num + 0.5) or 1
	num = math.Clamp(num, 1, D.MaxPellets)

	-- Penetration class: use the weapon's processed ARC9 penetration stat when
	-- available (modded ammo included), else the attachment's EFT value.
	local penPower = info.penPower
	local processedPen = swep:GetProcessedValue("Penetration", true)
	if isnumber(processedPen) and processedPen > 0 then penPower = processedPen end

	local penClassKey = info.penClass or C.ResolvePenClass(att, penPower)
	local penClass = C.PenClasses[penClassKey] or C.PenClasses.fmj

	local penMul = penClass.penMul
	if C.GetPenMultiplier then penMul = penMul * C.GetPenMultiplier() end
	if penMul <= 0 then penMul = 1 end

	local limitVel = penClass.limitVel or D.LimitVel
	local bulletType = penClass.bulletType or "AP"

	local frArea = math.pi * (info.cal / 2) ^ 2 -- cm^2
	local penAreaMod = (ACE and tonumber(ACE.PenAreaMod)) or D.PenAreaMod
	-- ACE penetration is energy / PenArea, so dividing the area by the class
	-- multiplier scales the penetration directly (AP ~2.2x, APCR ~3.2x).
	local penArea = (frArea ^ penAreaMod) / penMul

	-- ACE's AP convention ((FrArea/10000)/ProjMass) is calibrated for cannon
	-- shells and makes rifle/pistol bullets lose velocity far too fast
	-- (a 5.56 would drop below 500 m/s inside 100 m). Calibrate from the real
	-- G1 ballistic coefficient instead: ACE uses quadratic drag, so the
	-- velocity curve is v(x) = v0 * exp(-k x) with k ~= 0.984 * DragCoef.
	-- A 0.30 BC projectile gets k ~= 0.00104 (5.56 keeps ~660 m/s at 300 m).
	local refBC = D.ReferenceBC
	local bcFactor = 1
	if info.bc and info.bc > 0 then
		bcFactor = C.Clamp(refBC / info.bc, D.DragBCMin, D.DragBCMax)
	end
	local dragMult = 1
	if C.DragMultiplier then dragMult = C.DragMultiplier() end
	local dragCoef = D.DragCalibration * bcFactor * dragMult



	-- Equivalent powder charge: keeps ACE's muzzle velocity -> energy display,
	-- fake-crate data and any explosion/boom bookkeeping consistent.
	local pBase = (ACE and tonumber(ACE.PBase)) or D.PBase
	local propMass = (mv * mv * info.mass / 2000) / pBase

	-- Prefer the processed damage value: it includes arc9_mod_damage and any
	-- weapon-side damage hooks, exactly like ARC9's own damage path.
	local eftDamage = swep:GetProcessedValue("DamageMax", true)
	if not isnumber(eftDamage) then
		eftDamage = info.eftDamage
	end
	if not isnumber(eftDamage) then eftDamage = 50 end

	local tracer = info.tracer
	if not tracer and type(swep.ShouldTracer) == "function" then
		tracer = swep:ShouldTracer() and true or false
	end
	info.tracer = tracer

	-- Hitgroup multipliers, captured per shot so the player-damage model does
	-- not depend on the weapon entity still being valid/alive at impact time.
	local bodyMults = swep:GetProcessedValue("BodyDamageMults", true)
	if not istable(bodyMults) then bodyMults = nil end

	return {
		ammo = info,
		penClass = penClass.label,
		penClassKey = penClassKey,
		penMul = penMul,
		bodyMults = bodyMults,
		headMult = swep:GetProcessedValue("HeadshotDamage", true) or 1,
		chestMult = swep:GetProcessedValue("ChestDamage", true) or 1,
		stomachMult = swep:GetProcessedValue("StomachDamage", true) or 1,
		armMult = swep:GetProcessedValue("ArmDamage", true) or 1,
		legMult = swep:GetProcessedValue("LegDamage", true) or 1,
		cal = info.cal,
		mass = info.mass,
		mv = mv,
		bc = info.bc,
		type = bulletType,
		tracer = info.tracer,
		num = num,
		frArea = frArea,
		penArea = penArea,
		dragCoef = dragCoef,
		limitVel = limitVel,
		propMass = propMass,
		eftDamage = eftDamage,
		ke0 = 0.5 * info.mass * mv * mv / 1000, -- kJ at the muzzle
	}
end

--[[----------------------------------------------------------------------------
	BulletData construction
]]------------------------------------------------------------------------------

--- Build the engine-independent half of an ACE BulletData table.
-- `Pos`, `Flight`, `Owner`, `Gun`, `Crate` and `Filter` are filled in by the
-- fire path (they need Vector/entity context).
-- @tparam table stats Result of `ComputeStats`.
-- @tparam table colour Optional Color-like table `{r,g,b}`.
-- @treturn table data
function C.BuildBulletData(stats, colour)
	local data = {
		Id = "ARC9-" .. (stats.ammo.id or "ammo"),
		Type = stats.type,
		AmmoType = stats.type,
		Caliber = stats.cal,
		FrArea = stats.frArea,
		ProjMass = stats.mass,
		PropMass = stats.propMass,
		MuzzleVel = stats.mv,
		PenArea = stats.penArea,
		DragCoef = stats.dragCoef,
		LimitVel = stats.limitVel,
		Ricochet = D.Ricochet,
		ShovePower = D.ShovePower,
		KETransfert = D.KETransfert,
		BoomPower = stats.propMass,
		FuseLength = 0,
		Tracer = stats.tracer and math.min(stats.cal / 5, 3) or 0,
		Colour = colour or { r = 255, g = 140, b = 40 },
		-- Non-ACE fields, used by the bridge's player-damage model.
		ARC9Bridge = true,
		ARC9Damage = stats.eftDamage,
		ARC9MuzzleVel = stats.mv,
		ARC9KE0 = stats.ke0,
		ARC9Num = stats.num,
		ARC9AmmoName = stats.ammo.name,
		ARC9BodyMults = stats.bodyMults,
		ARC9HeadMult = stats.headMult,
		ARC9ChestMult = stats.chestMult,
		ARC9StomachMult = stats.stomachMult,
		ARC9ArmMult = stats.armMult,
		ARC9LegMult = stats.legMult,
	}
	return data
end
