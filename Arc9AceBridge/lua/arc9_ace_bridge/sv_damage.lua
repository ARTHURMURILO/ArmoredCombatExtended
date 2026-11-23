--[[
	ARC9 <-> ACE bridge: player damage model.

	ACE handles everything that is armour, vehicles and props. Players and NPCs
	still deserve the pack's own damage numbers, so bridged shots use the
	EFT/Tarkov damage of the loaded cartridge (the same value ARC9 would use)
	with ARC9's hitgroup multipliers and its sandbox-multiplier cancellation.

	Two layers:
	  * Primary: the projectile-impact interceptor. ACE dispatches impacts via
	    `ACE.RoundTypes[Type].propimpact`; we wrap the AP/HP handlers on the
	    server and resolve bridged bullets hitting players/NPCs ourselves. This
	    is independent of ACE's `ACE.Check`/squishy activation.
	  * Fallback: `ACE.SquishyDamage` is also shadowed for bridged weapons, in
	    case some other ACE path reaches the squishy branch first.

	Set `arc9ace_player_damage 0` to use pure ACE damage instead.
]]

ARC9ACE = ARC9ACE or {}
local C = ARC9ACE

local cvPlayerDamage, cvDamageMult

function C.InitDamageConVars()
	cvPlayerDamage = CreateConVar("arc9ace_player_damage", "1", FCVAR_ARCHIVE,
		"1 = bridged bullets use the pack's own (EFT/ARC9) damage against players/NPCs. 0 = pure ACE damage.")
	cvDamageMult = CreateConVar("arc9ace_player_damage_mult", "1", FCVAR_ARCHIVE,
		"Damage multiplier for bridged bullets against players/NPCs.")
end

local function PlayerDamageEnabled()
	return cvPlayerDamage ~= nil and cvPlayerDamage:GetBool()
end

local function DamageMultiplier()
	if not cvDamageMult then return 1 end
	local v = cvDamageMult:GetFloat()
	if v ~= v then return 1 end
	return math.max(v, 0)
end

local function CancelTable()
	local mode = engine.ActiveGamemode()
	local mults = ARC9 and ARC9.CancelMultipliers
	if not mults then return nil end
	return mults[mode] or mults[1]
end

--- Can this hit be applied at all? Mirrors ACE's god mode / PlayerShouldTakeDamage.
local function CanDamageTarget(target, attacker)
	if target:IsPlayer() then
		if target.HasGodMode and target:HasGodMode() then return false end
		if hook.Run("PlayerShouldTakeDamage", target, attacker) == false then return false end
	end
	return true
end

--- Cancel the engine's sandbox hitgroup multiplier, exactly like ARC9 does
--- (`arc9_mod_bodydamagecancel` defaults to 1).
local function CancelEngineMultiplier(dmg, hitgroup)
	local cancel = GetConVar("arc9_mod_bodydamagecancel")
	if cancel and not cancel:GetBool() then return dmg end
	if not hitgroup then return dmg end

	local mults = CancelTable()
	local mult = mults and mults[hitgroup]
	if mult and mult > 0 then
		return dmg / mult
	end
	return dmg
end

--- ARC9 hitgroup multipliers (BodyDamageMults + per-part multipliers).
local function ApplyHitgroupMultipliers(dmg, bullet, hitgroup)
	if ARC9 and ARC9.NoBodyPartsDamageMults then return dmg end
	if not hitgroup then return dmg end

	local body = bullet.ARC9BodyMults
	if istable(body) and body[hitgroup] then
		dmg = dmg * body[hitgroup]
	end

	if hitgroup == HITGROUP_HEAD then
		dmg = dmg * (bullet.ARC9HeadMult or 1)
	elseif hitgroup == HITGROUP_CHEST then
		dmg = dmg * (bullet.ARC9ChestMult or 1)
	elseif hitgroup == HITGROUP_STOMACH then
		dmg = dmg * (bullet.ARC9StomachMult or 1)
	elseif hitgroup == HITGROUP_LEFTARM or hitgroup == HITGROUP_RIGHTARM then
		dmg = dmg * (bullet.ARC9ArmMult or 1)
	elseif hitgroup == HITGROUP_LEFTLEG or hitgroup == HITGROUP_RIGHTLEG then
		dmg = dmg * (bullet.ARC9LegMult or 1)
	end

	return dmg
end

--- Compute and apply ARC9-equivalent damage for one bullet hitting a squishy
--- target. Uses only data carried on the bullet, so it works after the weapon
--- has been dropped/removed.
-- @tparam table bullet ACE bullet (carries the bridge fields).
-- @tparam Entity target Player or NPC.
-- @tparam number hitgroup Hitgroup index from the ACE trace.
-- @treturn number|nil damage dealt
function C.ApplyPlayerDamage(bullet, target, hitgroup)
	if not PlayerDamageEnabled() then return nil end
	if not (IsValid(target) and (target:IsPlayer() or target:IsNPC())) then return nil end

	local attacker = bullet.Owner
	if not CanDamageTarget(target, attacker) then return nil end

	-- Range damage: prefer ARC9's own lookup table when the weapon entity is
	-- still alive. The travelled range is reconstructed from the ACE flight
	-- time and the average of muzzle/impact velocity.
	local damage
	local gun = bullet.Gun
	if IsValid(gun) and type(gun.GetDamageAtRange) == "function"
		and bullet.FlightTime and bullet.ARC9MuzzleVel and ACE then
		local speed = bullet.Flight:Length() / (ACE.VelScale or 1) / 39.37 -- m/s
		local rangeHU = ((bullet.ARC9MuzzleVel + speed) * 0.5) * bullet.FlightTime * 39.37
		local ok, ranged = pcall(gun.GetDamageAtRange, gun, rangeHU)
		if ok and isnumber(ranged) and ranged > 0 then
			damage = ranged
		end
	end

	-- Fallback: approximate ARC9's exponential damage curve. The EFT LUT has a
	-- 58.3% floor and never exceeds the muzzle value.
	if not damage then
		local base = bullet.ARC9Damage or 50
		local num = bullet.ARC9Num or 1
		if num > 1 then base = base / num end

		local factor = 1
		local ke0 = bullet.ARC9KE0
		if ke0 and ke0 > 0 and ACE and ACE.Kinetic then
			local speed = bullet.Flight:Length() / (ACE.VelScale or 1)
			local energy = ACE.Kinetic(speed, bullet.ProjMass, bullet.LimitVel)
			local ke = energy and energy.Kinetic
			if ke then
				factor = C.Clamp(math.sqrt(C.Clamp(ke / ke0, 0.02, 1)), 0.583, 1)
			end
		end
		damage = base * factor
	end

	damage = ApplyHitgroupMultipliers(damage, bullet, hitgroup)

	-- ARC9's NPC damage nerf.
	if IsValid(attacker) and attacker:IsNPC() then
		local equality = GetConVar("arc9_npc_equality")
		if not (equality and equality:GetBool()) then
			damage = damage * 0.25
		end
	end

	damage = damage * DamageMultiplier()
	damage = CancelEngineMultiplier(damage, hitgroup)

	if not (damage > 0) then return nil end

	-- Conventional (damage, inflictor, attacker) order so kill credit lands on
	-- the player/NPC rather than the weapon entity.
	target:TakeDamage(damage, bullet.Gun, attacker)
	return damage
end

--[[----------------------------------------------------------------------------
	Primary layer: projectile impact interceptor
]]------------------------------------------------------------------------------

local ROUND_TYPES = { "AP", "HP" }

--- Redirect bridged AP/HP bullet impacts on players/NPCs to the ARC9 damage
--- model. Non-bridged bullets fall through untouched.
function C.InstallHitInterceptor()
	if not (ACE and ACE.RoundTypes) then return false end

	local wrapped = 0
	for _, kind in ipairs(ROUND_TYPES) do
		local round = ACE.RoundTypes[kind]
		if round and type(round.propimpact) == "function" and not round.ARC9ACE_Intercepted then
			local original = round.propimpact

			round.propimpact = function(index, bullet, target, normal, pos, bone)
				if bullet and bullet.ARC9Bridge and IsValid(target)
					and (target:IsPlayer() or target:IsNPC()) then
					local applied = C.ApplyPlayerDamage(bullet, target, bone)
					if applied then
						-- Bullet stops in the body; ACE's own damage is skipped.
						return false
					end
				end

				return original(index, bullet, target, normal, pos, bone)
			end

			round.ARC9ACE_Intercepted = true
			wrapped = wrapped + 1
		end
	end

	if wrapped > 0 then
		print(string.format("[ARC9-ACE] player hit interceptor installed on %d round types", wrapped))
	end
	return wrapped > 0
end

--[[----------------------------------------------------------------------------
	Fallback layer: squishy damage override
]]------------------------------------------------------------------------------

--- Shadow ACE's squishy-damage entry point for bridged weapons.
-- ACE resolves `ACE.SquishyDamage` through a metatable falling back to the
-- global `ACE_SquishyDamage`; writing a raw key shadows it for every caller
-- (ACE_Damage -> ACE.SquishyDamage).
function C.InstallSquishyOverride()
	if not ACE then return false end

	local original = rawget(ACE, "SquishyDamage") or rawget(_G, "ACE_SquishyDamage")
	if not original then
		print("[ARC9-ACE] ACE_SquishyDamage not found, squishy override skipped")
		return false
	end

	ACE.SquishyDamage = function(entity, energy, frArea, angle, inflictor, bone, gun, kind)
		local shot = IsValid(gun) and gun.ARC9ACE_LastShot or nil
		if PlayerDamageEnabled() and shot and CanDamageTarget(entity, inflictor) then
			-- No bullet table here (ACE reached the squishy branch directly);
			-- reuse the weapon's latest shot profile, which carries the same
			-- per-shot hitgroup multipliers as the bullets it produced.
			local damage = shot.ARC9Damage or shot.damage or 50
			local ke = energy and energy.Kinetic
			if ke and shot.ARC9KE0 and shot.ARC9KE0 > 0 then
				damage = damage * math.sqrt(C.Clamp(ke / shot.ARC9KE0, 0.02, 1))
			end
			damage = ApplyHitgroupMultipliers(damage, shot, bone)
			damage = damage * DamageMultiplier()
			damage = CancelEngineMultiplier(damage, bone)

			if damage > 0 then
				entity:TakeDamage(damage, gun, inflictor)
				return {
					Damage = damage,
					Overkill = 0,
					Loss = 1,
					Kill = false,
					Ricochet = false,
					RicochetSelected = false,
				}
			end
		end

		return original(entity, energy, frArea, angle, inflictor, bone, gun, kind)
	end

	print("[ARC9-ACE] squishy damage override installed (fallback)")
	return true
end

--- Install both damage layers.
function C.InstallDamageOverride()
	local interceptor = C.InstallHitInterceptor()
	local fallback = C.InstallSquishyOverride()
	return interceptor or fallback
end
