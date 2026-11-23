--[[
	ARC9 <-> ACE bridge: server fire path.

	Every ARC9 bullet (hitscan or phys) funnels through `SWEP:DoProjectileAttack`.
	We replace that function on every registered ARC9 SWEP class with a thin
	wrapper that, for mapped weapons, spawns ACE projectiles instead. All the
	ARC9 bookkeeping that happens earlier in `DoPrimaryAttack` (ammo, sounds,
	animations, recoil, spread calculation, fire rate) is untouched.

	Only the server runs this. Clients keep running stock ARC9, so prediction
	effects still play locally; the damage is entirely server-side ACE.
]]

ARC9ACE = ARC9ACE or {}
local C = ARC9ACE
local D = C.Defaults

C.PatchedClasses = C.PatchedClasses or {}
C.PatchedCount = 0
C.WrappedFunctions = setmetatable({}, { __mode = "k" })

--[[----------------------------------------------------------------------------
	ConVars / scope
]]------------------------------------------------------------------------------

local cvEnable, cvScope, cvDragMult, cvDebug, cvAudit, cvPenMult

function C.InitConVars()
	cvEnable = CreateConVar("arc9ace_enable", "1", FCVAR_ARCHIVE,
		"1 = ARC9 weapons fire full ACE projectiles (server-side).")
	cvScope = CreateConVar("arc9ace_scope", "1", FCVAR_ARCHIVE,
		"1 = only the EFT pack (arc9_eft_base weapons). 2 = every ARC9 weapon with a resolvable calibre.")
	cvDragMult = CreateConVar("arc9ace_drag_mult", "1", FCVAR_ARCHIVE,
		"Multiplier on ACE drag for bridged bullets. >1 = velocity bleeds off faster, <1 = flatter.")
	cvDebug = CreateConVar("arc9ace_debug", "0", FCVAR_ARCHIVE,
		"Log each bridged shot's projectile data to the server console.")
	cvAudit = CreateConVar("arc9ace_audit", "1", FCVAR_ARCHIVE,
		"Print the ammunition mapping audit at startup.")
	cvPenMult = CreateConVar("arc9ace_pen_mult", "1", FCVAR_ARCHIVE,
		"Global multiplier on bridged-projectile penetration (AP classes already get a class bonus).")
end

function C.Enabled()
	return cvEnable ~= nil and cvEnable:GetBool()
end

function C.DebugEnabled()
	return cvDebug ~= nil and cvDebug:GetBool()
end

function C.DragMultiplier()
	if not cvDragMult then return 1 end
	return math.max(cvDragMult:GetFloat(), 0.05)
end

--- Global penetration multiplier (stacks on the per-ammo-class bonus).
function C.GetPenMultiplier()
	if not cvPenMult then return 1 end
	local v = cvPenMult:GetFloat()
	if v ~= v or v <= 0 then return 1 end
	return v
end

--- Is this weapon inside the current bridge scope?
-- @tparam Entity swep
-- @treturn boolean
function C.IsInScope(swep)
	if swep.ARC9ACE_Disabled then return false end

	local class = swep:GetClass()
	if not class then return false end

	if not cvScope or cvScope:GetInt() == 1 then
		return weapons.IsBasedOn(class, "arc9_eft_base") and true or false
	end
	return weapons.IsBasedOn(class, "arc9_base") and true or false
end

--[[----------------------------------------------------------------------------
	Fake crate (projectile visuals / tracer data on the client)
]]------------------------------------------------------------------------------

local TRACER_COLOUR = Color(255, 140, 40)
local PLAIN_COLOUR = Color(0, 0, 0)

local function EnsureCrate(swep, owner)
	local crate = swep.ARC9ACE_Crate
	if IsValid(crate) then return crate end

	crate = ents.Create("acf_fakecrate2")
	if not IsValid(crate) then return nil end

	if IsValid(owner) and crate.CPPISetOwner then
		crate:CPPISetOwner(owner)
	end

	swep.ARC9ACE_Crate = crate
	return crate
end

local function UpdateCrate(crate, stats, owner)
	if not IsValid(crate) then return end

	-- Weapons change hands; the fake crate follows its current owner.
	if IsValid(owner) and crate.CPPISetOwner then
		local current
		if crate.CPPIGetOwner then
			local ok, result = pcall(crate.CPPIGetOwner, crate)
			if ok then current = result end
		end
		if current ~= owner then
			crate:CPPISetOwner(owner)
		end
	end

	-- Mirrors acf_fakecrate2:RegisterTo, but with the bridge's data.
	-- NWFloat (not NWInt) is used on purpose: the client bullet-effect code
	-- reads these with GetNWFloat, and truncating sub-1 values to integers
	-- would desync the client-side tracer simulation from the server bullet.
	crate:SetNWFloat("Caliber", stats.cal or 10)
	crate:SetNWFloat("ProjMass", stats.mass or 10)
	crate:SetNWFloat("FillerMass", 0)
	crate:SetNWFloat("DragCoef", stats.dragCoef or 1)
	crate:SetNWString("AmmoType", stats.type or "AP")
	crate:SetNWFloat("Tracer", stats.tracer and math.min((stats.cal or 5.56) / 5, 3) or 0)
	crate:SetNWString("BulletModel", "models/munitions/round_100mm_shot.mdl")

	local colour = stats.tracer and TRACER_COLOUR or PLAIN_COLOUR
	crate:SetNWVector("Color", Vector(colour.r, colour.g, colour.b))
	crate:SetNWVector("TracerColour", Vector(colour.r, colour.g, colour.b))
	crate:SetColor(colour)
end

--[[----------------------------------------------------------------------------
	Spread (same maths ARC9 uses for its own projectiles)
]]------------------------------------------------------------------------------

local function CalcSpreadDir(seed, ang, spread)
	local ang2 = Angle(ang)

	local a = util.SharedRandom("arc9_physbullet", 0, 360, seed)
	local angleRand = Angle(math.sin(a), math.cos(a), 0)
	angleRand:Mul(spread * util.SharedRandom("arc9_physbullet2", 0, 45, seed) * 1.4142135623730)
	ang2:Add(angleRand)

	return ang2:Forward()
end

--[[----------------------------------------------------------------------------
	Shot
]]------------------------------------------------------------------------------

--- Build one ACE BulletData for a single pellet.
-- @tparam Entity swep
-- @tparam table stats
-- @tparam table base BulletData template from `BuildBulletData`
-- @tparam Vector pos
-- @tparam Vector dir
-- @tparam Entity owner
-- @tparam table crate
-- @tparam table filter
local function FirePellet(swep, stats, base, pos, dir, owner, crate, filter)
	local data = table.Copy(base)
	data.Pos = pos
	data.Flight = dir * stats.mv * 39.37
	data.Owner = owner
	data.Gun = swep
	data.Crate = crate:EntIndex()
	data.Filter = table.Copy(filter)
	ACE_CreateBullet(data)
	return data
end

--- Try to replace a stock ARC9 shot with ACE projectiles.
-- Returns true when the shot was handled. Any failure returns false so the
-- caller can fall back to the original ARC9 implementation.
-- @tparam Entity swep
-- @tparam Vector pos
-- @tparam Angle ang
-- @tparam number spread
-- @treturn boolean handled
function C.TryAttack(swep, pos, ang, spread)
	if not C.Enabled() then return false end
	if not C.IsInScope(swep) then return false end

	-- Rockets/grenades/throwables keep their ARC9 implementation.
	if swep:GetProcessedValue("ShootEnt", true) then return false end

	local stats = C.ComputeStats(swep)
	if not stats then return false end

	-- Stock ARC9 skips the shot entirely when the processed pellet count is 0.
	-- Do the same instead of clamping it up to one pellet.
	if stats.num <= 0 then return false end

	local owner = swep:GetOwner()
	if not IsValid(owner) then return false end

	local crate = EnsureCrate(swep, owner)
	if not IsValid(crate) then return false end
	UpdateCrate(crate, stats, owner)

	-- Remember the shot profile for the player-damage model. Ammunition can
	-- only change at a menu, so the latest shot is the right profile for
	-- every projectile of that shot (and any still travelling).
	swep.ARC9ACE_LastShot = {
		time = CurTime(),
		mv = stats.mv,
		mass = stats.mass,
		damage = stats.eftDamage,
		ke0 = stats.ke0,
		ammo = stats.ammo.id,
		name = stats.ammo.name,
		ARC9Damage = stats.eftDamage,
		ARC9KE0 = stats.ke0,
		ARC9BodyMults = stats.bodyMults,
		ARC9HeadMult = stats.headMult,
		ARC9ChestMult = stats.chestMult,
		ARC9StomachMult = stats.stomachMult,
		ARC9ArmMult = stats.armMult,
		ARC9LegMult = stats.legMult,
	}

	local ang2 = Angle(ang)

	-- ARC9 applies the weapon's dispersion to the whole shot before the
	-- per-pellet spread. Do exactly the same so accuracy feels identical.
	if swep:GetProcessedValue("UseDispersion", true) then
		local seed = 1337 + swep:EntIndex() + engine.TickCount()
		local a = util.SharedRandom("arc9_physbullet3", 0, 360, seed)
		local angleRand = Angle(math.sin(a), math.cos(a), 0)
		angleRand:Mul(math.max(0, swep:GetProcessedValue("DispersionSpread"))
			* util.SharedRandom("arc9_physbullet4", 0, 45, seed) * 1.4142135623730)
		ang2:Add(angleRand)
	end

	local filter = { owner, swep, crate }
	if owner:IsPlayer() then
		local veh = owner:GetVehicle()
		if IsValid(veh) then table.insert(filter, veh) end
	end

	local base = C.BuildBulletData(stats)
	local num = stats.num
	local seedBase = swep:EntIndex() + engine.TickCount()

	local firstData
	for i = 1, num do
		local dir = CalcSpreadDir(i + seedBase, ang2, spread)
		local data = FirePellet(swep, stats, base, pos, dir, owner, crate, filter)
		firstData = firstData or data
	end

	if C.DebugEnabled() then
		local pen = 0
		if ACE and ACE.CalcPenetration and ACE.Kinetic then
			pen = ACE.CalcPenetration(ACE.Kinetic(stats.mv * 39.37, stats.mass, stats.limitVel), stats.penArea) or 0
		end
		print(string.format(
			"[ARC9-ACE] %s (%s) x%d | %.2fmm %.1fg %.0fm/s BC=%s drag=%.5f pen~%.1fmm %s x%.2f",
			swep:GetClass(), stats.ammo.id or "?", num,
			stats.cal * 10, stats.mass * 1000, stats.mv,
			stats.bc and string.format("%.3f", stats.bc) or "?", stats.dragCoef, pen,
			stats.penClass or stats.type, stats.penMul or 1))
	end

	return firstData ~= nil
end

--[[----------------------------------------------------------------------------
	Patching
]]------------------------------------------------------------------------------

local function WrapClass(wep)
	local class = wep.ClassName
	if not class or C.PatchedClasses[class] then return false end
	if class ~= "arc9_base" and not weapons.IsBasedOn(class, "arc9_base") then return false end

	-- Only the table that actually *defines* DoProjectileAttack needs the
	-- wrapper. Individual weapon tables usually just set SWEP.Base and inherit
	-- the function later through weapons.Get()'s TableInherit chain, so the
	-- stored weapon table is nil here by design.
	local original = rawget(wep, "DoProjectileAttack")
	if type(original) ~= "function" then return false end

	C.PatchedClasses[class] = true

	local wrapper = function(self, pos, ang, spread)
		local ok, handled = pcall(C.TryAttack, self, pos, ang, spread)
		if ok and handled then return end
		if not ok then
			ErrorNoHalt("[ARC9-ACE] bridge error, falling back to ARC9: " .. tostring(handled) .. "\n")
		end
		return original(self, pos, ang, spread)
	end
	C.WrappedFunctions[wrapper] = true

	wep.DoProjectileAttack = wrapper

	return true
end

--- Patch every registered ARC9 SWEP base table.
-- Patching `arc9_base` is enough for every weapon that inherits it, because
-- weapons.Get() TableInherit-copies the (already patched) function into each
-- spawned weapon entity's table.
function C.PatchWeapons()
	local list = weapons.GetList() or {}
	local arc9Classes, ownFunctions, patched = 0, 0, 0

	for _, wep in ipairs(list) do
		local class = wep.ClassName
		if class then
			if class == "arc9_base" or weapons.IsBasedOn(class, "arc9_base") then
				arc9Classes = arc9Classes + 1
			end
			if type(rawget(wep, "DoProjectileAttack")) == "function" then
				ownFunctions = ownFunctions + 1
			end
		end

		if WrapClass(wep) then patched = patched + 1 end
	end

	C.PatchedCount = patched

	-- Also wrap any weapons that already exist (map-placed, loadout entities
	-- created during startup).
	local entitiesPatched = 0
	if ents and ents.GetAll then
		for _, ent in ipairs(ents.GetAll()) do
			if ent:IsWeapon() and C.PatchEntity(ent) then
				entitiesPatched = entitiesPatched + 1
			end
		end
	end

	print(string.format(
		"[ARC9-ACE] patched %d ARC9 projectile function(s): %d ARC9 weapon classes registered, %d own DoProjectileAttack, %d existing weapon entities",
		patched, arc9Classes, ownFunctions, entitiesPatched))
end

--- Wrap one weapon entity's own DoProjectileAttack.
-- The stored SWEP table is shared by all instances of a class, so the class
-- patch is normally enough. This also covers engine/weapon-addon setups that
-- clone the SWEP table per entity (cheap and safe: wrapped functions carry a
-- marker so they can never be wrapped twice).
-- @tparam Entity ent
function C.PatchEntity(ent)
	if not IsValid(ent) then return false end
	if ent.ARC9ACE_EntityPatched then return false end

	local class = ent:GetClass()
	if not class or not weapons.IsBasedOn(class, "arc9_base") then return false end

	local original = ent.DoProjectileAttack
	if type(original) ~= "function" then return false end
	if C.WrappedFunctions[original] then
		ent.ARC9ACE_EntityPatched = true
		return false
	end

	local wrapper = function(self, pos, ang, spread)
		local ok, handled = pcall(C.TryAttack, self, pos, ang, spread)
		if ok and handled then return end
		if not ok then
			ErrorNoHalt("[ARC9-ACE] bridge error, falling back to ARC9: " .. tostring(handled) .. "\n")
		end
		return original(self, pos, ang, spread)
	end
	C.WrappedFunctions[wrapper] = true

	ent.DoProjectileAttack = wrapper
	ent.ARC9ACE_EntityPatched = true
	return true
end

--- Wrap weapons that are created after InitPostEntity (players, NPCs, map).
function C.InstallWeaponSpawnHook()
	hook.Add("EntityCreated", "ARC9ACE_WeaponSpawn", function(ent)
		if not ent:IsWeapon() then return end
		-- Weapon tables are initialised by the engine after EntityCreated.
		timer.Simple(0, function()
			if IsValid(ent) then C.PatchEntity(ent) end
		end)
	end)
end

--[[----------------------------------------------------------------------------
	Cleanup
]]------------------------------------------------------------------------------

function C.InstallCleanup()
	hook.Add("EntityRemoved", "ARC9ACE_CrateCleanup", function(ent)
		if not ent.ARC9ACE_Crate then return end
		local crate = ent.ARC9ACE_Crate
		timer.Simple(15, function()
			if IsValid(crate) then crate:Remove() end
		end)
		ent.ARC9ACE_Crate = nil
	end)
end

--[[----------------------------------------------------------------------------
	Audit / diagnostics
]]------------------------------------------------------------------------------

local function FormatPen(stats)
	if not (ACE and ACE.CalcPenetration and ACE.Kinetic) then return "?" end
	local energy = ACE.Kinetic(stats.mv * 39.37, stats.mass, stats.limitVel)
	local pen = ACE.CalcPenetration(energy, stats.penArea)
	return string.format("%.1f", pen or 0)
end

--- Print what the bridge could map. Useful in the server journal after a start.
function C.Audit()
	if cvAudit and not cvAudit:GetBool() then
		print("[ARC9-ACE] audit disabled by arc9ace_audit")
		return
	end

	local total, mapped, unresolved = 0, 0, 0
	local samples = {}

	print(string.format("[ARC9-ACE] audit: %d registered weapon classes, %d ARC9 attachments, %d patched projectile functions",
		#(weapons.GetList() or {}), (function()
			local n = 0
			for _ in pairs(ARC9.Attachments or {}) do n = n + 1 end
			return n
		end)(), C.PatchedCount or 0))

	for _, att in pairs(ARC9.Attachments or {}) do
		if (att.EFTRoundName or att.HasAmmoooooooo) and C.TokenFromAttachment(att) then
			total = total + 1
			local info = C.DescribeAttachment(att)
			if info and info.cal and info.mass then
				mapped = mapped + 1
				if #samples < 6 then
					local stats = {
						mv = info.mv or D.MuzzleVel,
						mass = info.mass,
						cal = info.cal,
						penArea = math.pi * (info.cal / 2) ^ 2,
						limitVel = info.type == "HP" and 400 or D.LimitVel,
					}
					samples[#samples + 1] = string.format(
						"  %-28s %-22s %4.2fmm %5.1fg %4.0fm/s pen~%smm %s",
						info.id, tostring(info.name), info.cal * 10, info.mass * 1000,
						stats.mv, FormatPen(stats), info.type)
				end
			else
				unresolved = unresolved + 1
				if unresolved <= 5 then
					print("[ARC9-ACE] unresolved ammo attachment: " .. tostring(att.ShortName or "?"))
				end
			end
		end
	end

	print(string.format("[ARC9-ACE] ammunition mapping: %d/%d EFT ammo attachments resolved (%d unresolved)",
		mapped, total, unresolved))
	for _, line in ipairs(samples) do print(line) end

	-- Weapon coverage: every EFT weapon's default ammo slot should resolve to a
	-- calibre + projectile mass, using the same resolution the fire path uses.
	local eftWeapons, weaponMapped, weaponUnmapped = 0, 0, 0
	local weaponSamples = {}
	for _, wep in ipairs(weapons.GetList()) do
		local class = wep.ClassName
		if class and weapons.IsBasedOn(class, "arc9_eft_base") then
			eftWeapons = eftWeapons + 1
			local att = C.FindDefaultAmmoAttachment(wep)
			local info = C.DescribeAttachment(att)
			if info and info.cal and info.mass then
				weaponMapped = weaponMapped + 1
				if #weaponSamples < 8 then
					local mv = info.mv or D.MuzzleVel
					weaponSamples[#weaponSamples + 1] = string.format(
						"  %-34s %-26s %4.2fmm %5.1fg %4.0fm/s",
						class, info.id or "?", info.cal * 10, info.mass * 1000, mv)
				end
			else
				weaponUnmapped = weaponUnmapped + 1
				if weaponUnmapped <= 10 then
					print("[ARC9-ACE] weapon without mappable default ammo: " .. class)
				end
			end
		end
	end
	print(string.format("[ARC9-ACE] weapon coverage: %d/%d EFT weapons have a mappable default ammo slot",
		weaponMapped, eftWeapons))
	for _, line in ipairs(weaponSamples) do print(line) end
end

--- Find the ammo attachment a weapon spawns with, from its stored Attachments
--- slot tree. Used by the startup audit (no entity needed).
-- @tparam table wep Stored SWEP table.
-- @treturn table|nil att
function C.FindDefaultAmmoAttachment(wep)
	local function scan(list, depth)
		if not istable(list) or depth > 8 then return nil end

		for _, slot in ipairs(list) do
			if istable(slot) then
				local installed = slot.Installed
				local token = C.TokenFromCategory(slot.Category)
				if installed and token then
					local att = ARC9.GetAttTable(installed)
					if att then return att end
				end

				local found = scan(slot.SubAttachments, depth + 1)
				if found then return found end
			end
		end
		return nil
	end

	return scan(wep and wep.Attachments, 0)
end

--[[----------------------------------------------------------------------------
	Chat diagnostic (players can check the gun they are holding)
]]------------------------------------------------------------------------------

function C.InstallChatDiagnostics()
	local function describe(ply)
		local wep = ply:GetActiveWeapon()
		if not IsValid(wep) or not weapons.IsBasedOn(wep:GetClass(), "arc9_base") then
			ply:ChatPrint("[ARC9-ACE] Hold an ARC9 weapon first.")
			return
		end

		local stats, reason = C.ComputeStats(wep)
		if not stats then
			ply:ChatPrint("[ARC9-ACE] no mapping for this weapon (" .. tostring(reason) .. ").")
			return
		end

		local pen = 0
		if ACE and ACE.CalcPenetration and ACE.Kinetic then
			pen = ACE.CalcPenetration(ACE.Kinetic(stats.mv * 39.37, stats.mass, stats.limitVel), stats.penArea) or 0
		end

		local msg = string.format(
			"[ARC9-ACE] %s | ammo %s | %.2fmm %.1fg %.0fm/s | %d pellet(s) | pen~%.1fmm | %s (x%.2f)",
			stats.ammo.name, tostring(stats.ammo.id), stats.cal * 10, stats.mass * 1000,
			stats.mv, stats.num, pen, stats.penClass or stats.type, stats.penMul or 1)
		ply:ChatPrint(msg)
		print("[ARC9-ACE] " .. ply:Nick() .. ": " .. msg)
	end

	hook.Add("PlayerSay", "ARC9ACE_ChatDiag", function(ply, text)
		local cmd = string.lower(text or "")
		if cmd == "!acebridge" or cmd == "!aceammo" then
			describe(ply)
			return ""
		end
	end)
end
