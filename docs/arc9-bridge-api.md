# ARC9 APIs needed by the server-side ACE projectile bridge

Answer to the 9-item checklist backing `Arc9AceBridge/` (server-only addon that replaces
`SWEP:DoProjectileAttack` with ACE projectile creation). Every claim below is cited to the
extracted sources in this workspace:

- `Arc9_extracted/` — ARC9 Weapon Base 2910505837 (`lua/arc9/**`, `lua/weapons/arc9_base/**`).
- `Weapon_pack_extracted/eft_extract/<workshopid>/` — EFT SHARED 2917343547 (`arc9_eft_base`,
  `lua/arc9/common/sh_eft_shared.lua`, ammo bulks) plus the 8 weapon packs.
- `ArmoredCombatExtended/` — ACE fork (server ballistics, `ACE_SquishyDamage`, fake crate, round types).
- GMod API facts are cited to the Facepunch wiki/GitHub (`weapons.lua`, `baseclass.lua`,
  gmod-issues #1899) where the engine behaviour is not visible in those trees.

Method: static reading only — no live GMod server was available. Anything that cannot be
settled from source is labelled **needs live test** rather than guessed.

---

## Verdicts

| # | Question | Verdict | One line |
|---|---|---|---|
| 1 | Patching `weapons.GetStored(class).DoProjectileAttack` at `InitPostEntity` | **NOT OK as written** | The *technique* is the supported one (ARC9 itself uses it), but stored tables do **not** carry inherited functions, so `sv_fire.lua:238` bails on every EFT class → **0 classes patched**. Fix the original-resolution and patch classes explicitly. |
| 2 | Server-side ammo attachment lookup + stale cache | **OK (with one edge case)** | `ARC9.GetAttTable` + `SWEP:GetSubSlotList` are fully server-side; ammo changes invalidate every relevant cache. The first-match search can pick the UBGL ammo attachment instead of the main one on UBGL-capable rifles. |
| 3 | `GetProcessedValue` for the requested stats at fire time | **OK** | All requested stats exist on both realms and are computed server-side; caches are per-entity and invalidated on attachment/UBGL/deploy changes. `isstatic` is a *cache* flag, not "client-only". |
| 4 | UBGL / launcher `ShootEnt` | **OK** | `GetProcessedValue("ShootEnt", true)` is UBGL-condition aware and the EFT launchers/UBGLs return their grenade entity class → falling back to stock `DoProjectileAttack` → `ShootRocket()` is correct. |
| 5 | Client prediction duplicates/mismatch | **CAUTION (known, unsolvable server-side)** | Clients run the stock predicted `DoProjectileAttack` (hitscan tracer + predicted impact effects, or predicted ARC9 phys bullets). They will duplicate/mismatch the ACE bullet visuals; ACE still renders its own networked bullet. Only a client stub can remove them. |
| 6 | Inheritance / class naming | **CAUTION** | All guns and the 3 launchers derive from `arc9_eft_base`, but the 13 EFT throwables derive from `arc9_base_nade`, not `arc9_eft_base`. Nothing overrides `DoProjectileAttack`; `GetClass()` is the registration class name. |
| 7 | Ammo switching + what invalidates stats | **OK** | Customize tree is sent client→server, `BuildSubAttachments` then `DoInvalidateCache` (clears `StatCache`, `PV_Cache`, `PV_CacheLong`, `GetSubSlotListCache`) and `PostModify`. A `GetProcessedValue` read is therefore fresh by the next tick. |
| 8 | Wrapper gotchas | **CAUTION** | No recursion; NPC path also calls `DoProjectileAttack`; a `Num <= 0` guard is missing; `ShouldTracer` is server-safe but unused; `Deploy`/`Holster` invalidate caches; the old ARC9 impact/penetration/AP systems no longer run server-side. |
| 9 | Crate cleanup | **OK** | `SWEP:OnRemove` exists (`sh_init.lua:244`), but `EntityRemoved` + 15 s timer matches ACE's own `weapon_ace_base` precedent exactly. Also refresh the crate owner if the weapon changes hands. |

---

## 1. Patching a stored SWEP class at `InitPostEntity`

### What GMod guarantees

`weapons.GetStored(class)` / `weapons.GetList()` return the **real** stored tables; they are not
copies and do not inherit base-class fields (`weapons.Get` is the version that walks `.Base`):

- `weapons.Register` stores the file's own table and sets `ClassName` on it:
  [Facepunch/garrysmod weapons.lua — Register](https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/includes/modules/weapons.lua).
- `weapons.GetStored` docs: "Gets the REAL weapon table, not a copy. The produced table does
  *not* inherit fields from the weapon's base class, unlike `weapons.Get`. Modifying this table
  will modify what is stored by the weapons library."
  ([wiki](https://wiki.facepunch.com/gmod/weapons.GetStored)).
- At the end of weapon loading, `weapons.OnLoaded()` does `baseclass.Set(k, weapons.Get(k))` once
  (merged snapshot, [weapons.lua](https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/includes/modules/weapons.lua)),
  and each spawned entity receives its own per-entity Lua table (SWEPs included:
  [gmod-issues #1899](https://github.com/Facepunch/garrysmod-issues/issues/1899)); class-level
  *table* values are shared references unless reassigned per entity (see the
  [`gmod_tool` comment](https://github.com/Facepunch/garrysmod/blob/master/garrysmod/gamemodes/sandbox/entities/weapons/gmod_tool/shared.lua#L1)).

### What ARC9 itself does

`ARC9.PatchWeapons` is the exact pattern the bridge copies — monkey-patch each stored SWEP table
from `InitPostEntity`:

```lua
-- Arc9_extracted/lua/arc9/common/sh_patching.lua:19-53
for _, wep in ipairs(weapons.GetList()) do
    local classname = wep.ClassName
    if weapons.IsBasedOn(classname, "arc9_base") then
        local origswep = weapons.GetStored(classname)
        ...
        origswep[stat] = value
    end
end
hook.Add("InitPostEntity", "ARC9_PatchWeapons", ARC9.PatchWeapons)
```

ARC9 also re-writes stored tables at `InitPostEntity` in
`Arc9_extracted/lua/arc9/shared/sh_npc.lua:184` (`weapons.GetStored(class).ARC9WeaponCategory = weptype`,
hook at `:194`). This is the established community convention for SWEP monkey patching
(e.g. ArcCW's developer recommends `InitPostEntity` + `weapons.GetStored`).

### The two important consequences

1. **Only entities created after the patch pick it up.** Weapon entities alive at
   `InitPostEntity` keep the function they were spawned with. On a normal server that is fine —
   players are given their weapons after map load — but map-placed/NPC weapons and any
   `ents.Create`d weapon that already exists must be patched directly on the entity.
2. **`weapons.GetList()` tables do not contain inherited functions.** Every EFT weapon file only
   sets `SWEP.Base`; the pack defines no `DoProjectileAttack` at all:

   ```text
   grep DoProjectileAttack in Weapon_pack_extracted/eft_extract → only ARC9 base matches
   Arc9_extracted/.../sh_shoot.lua:633   function SWEP:DoProjectileAttack(...)
   Arc9_extracted/.../sh_shoot.lua:523   self:DoProjectileAttack(...)      -- player path
   Arc9_extracted/.../sh_npc.lua:20      self:DoProjectileAttack(...)      -- NPC path
   ```

   So for e.g. `arc9_eft_ak74` the *stored* table has `Base = "arc9_eft_base"` but
   `DoProjectileAttack == nil`. `sv_fire.lua:238` (`if not wep.DoProjectileAttack then return false end`)
   therefore rejects every class; `C.PatchedCount` will be 0 and the bridge silently does nothing.
   The only class with an own `DoProjectileAttack` is `arc9_base`, and `weapons.IsBasedOn("arc9_base", "arc9_base")`
   is `false` (a class is not based on itself), so it is skipped too.

### Correct recipe

```lua
-- inside WrapClass(wep), for every class where weapons.IsBasedOn(class, "arc9_base") OR class == "arc9_base"
local stored  = weapons.GetStored(class) or wep
local merged  = weapons.Get(class) or stored          -- has the inherited DoProjectileAttack
local original = merged.DoProjectileAttack
if type(original) ~= "function" then return false end

local function wrapper(self, pos, ang, spread) ... end
wrapper.ARC9ACEOriginal = original                   -- guard against double wrapping

stored.DoProjectileAttack = wrapper                  -- future spawns (stored-table route)
local bc = baseclass.Get(class)                      -- engine class table route
if bc then bc.DoProjectileAttack = wrapper end
for _, ent in ipairs(ents.FindByClass(class)) do     -- already-spawned entities
    if IsValid(ent) and ent:IsWeapon() then ent.DoProjectileAttack = wrapper end
end
```

Patching `arc9_base` alone would cover every inherited class under the merge-at-spawn model, but
assigning an own key per class (plus the live-entity loop) is cheap and survives either engine
implementation. Re-run the patch on `hook.Add("OnReloaded", ...)`; `arc9_reloadatts` only reloads
attachments, not weapon classes.

**Risk to test live:** whether a patch to the stored table at `InitPostEntity` reaches entities
created later depends on the engine taking the stored/merged table at spawn time (`baseclass.Set`
is called earlier with a merged snapshot). The convention above says yes; verify with one
`print("wrapped " .. class)` inside the wrapper during the first in-game test. Patching
`baseclass.Get(class)` + live entities covers the alternative behaviour.

---

## 2. Ammo attachment lookup on the server

### Availability

Both APIs live in shared files loaded on the server, so they are available at
`InitPostEntity`/spawn/fire time:

- `ARC9.GetAttTable(name)` — `Arc9_extracted/lua/arc9/shared/sh_atts.lua:233-242`. Accepts a
  shortname string or numeric ID; returns `nil` for unknown ids. `ARC9.Attachments` is filled by
  `ARC9.LoadAtts()`, which runs at load time (`sh_atts.lua:361`, hook `OnReloaded` at `:314`).
- `SWEP:GetSubSlotList()` — `Arc9_extracted/lua/weapons/arc9_base/sh_subatts.lua:44-57`. Flattens
  `self.Attachments` recursively with `AttTreeToList` (`:29-41`).
- `SWEP:GetFinalAttTable(slot)` — `sh_0_stats.lua:149-151` (same data with ToggleStats merged),
  if you want the *effective* attachment stats rather than the raw table.

### Slot fields

`GetSubSlotList` returns the slot tables themselves (`self.Attachments[i]` and nested
`SubAttachments` copies). Fields the bridge may use:

| Field | Meaning | Citation |
|---|---|---|
| `Installed` | shortname of installed attachment, or `nil`/`false` | `sh_subatts.lua:228`, `sh_attach.lua:17` |
| `Category` | string or list of accepted categories, e.g. `{"eft_ammo_556"}` | `2962829818/.../arc9_eft_mdr556.lua:167-171` |
| `ToggleNum` | 1-based toggle index for multi-mode attachments (default 1) | `sh_subatts.lua:106`, `:170` |
| `SubAttachments` | nested child slots (recursive) | `sh_subatts.lua:208`, `:237` |
| `Integral` | integral attachment shortname; `FillIntegralSlots` installs it | `sh_subatts.lua:306-320` |
| `Address`, `ParentAddress` | 1-based slot address used by Attach/Detach | `sh_subatts.lua:8-27` |

### Reliable EFT ammo detection

Real EFT ballistic ammo attachments carry `HasAmmoooooooo = true` and a phrase-based
`EFTRoundName`, with `Category = {"eft_ammo_<token>"}` or a string of the same form:

```lua
-- Weapon_pack_extracted/eft_extract/2917343547/lua/arc9/common/attachments_bulk/eft_ammo_556_bulk.lua:19-25
ATT.HasAmmoooooooo = true
ATT.EFTRoundName = ARC9:GetPhrase("eft_ammo_556_warma.printname")
ATT.Category = {"eft_ammo_556"}
```

`HasAmmoooooooo` is a hard-coded boolean, so it is reliable on the server even if
`ARC9:GetPhrase` returns `nil` there. Grenade ammo (40x46) uses a *different* flag and field name
(`HasGranataAmmo`, `EFTRoundName2`, `ShootEntUBGL`; `eft_ammo_40x46_bulk.lua:17-29`), which is
why `C.GetAmmoAttachment` currently does not mistake it for a ballistic round.

Grenade-launcher ammo is nested under the UBGL attachment's own slot:

```lua
-- Weapon_pack_extracted/eft_extract/3010049092/lua/arc9/common/attachments_bulk/eft_ubgl_bulk.lua:643-651
ATT.Attachments = {
    { PrintName = ..., Category = "eft_ammo_40x46", Integral = "eft_ammo_40x46_m406", ... },
}
```

### Caching / staleness (important for the bridge)

- `GetSubSlotList` caches its flattened list in `self.GetSubSlotListCache` and only uses the cache
  when `CacheLastInvalidation + 3 < CurTime()` (`sh_subatts.lua:44-57`) — i.e. right after an
  invalidation it rebuilds every call for 3 s, afterwards it reuses the (already new) list.
- `SWEP:DoInvalidateCache()` (`sh_0_stats.lua:89-113`) clears `StatCache`, `PV_Cache`,
  `PV_CacheLong`, `AttTableCache`, `HookCache`, `AffectorsCache`, `ElementsCache`,
  **`GetSubSlotListCache`**, and sets `CacheLastInvalidation = CurTime()` (`:109-110`).
- It runs synchronously on the server when the customize tree is committed
  (`sh_net.lua:130`, `:142`) and via `PostModify` → `InvalidateCache` → deferred to
  `Think` (`sh_attach.lua:102-103`, `sh_think.lua:191-193`).
- `SWEP:ToggleUBGL` and `SWEP:Deploy` additionally call `ClearLongCache()`
  (`sh_ubgl.lua:49-51`, `sh_deploy.lua:14`), i.e. `PV_CacheLong = {}` only.

Conclusion: after the player changes ammo the next `GetSubSlotList()`/`ARC9.GetAttTable()` read is
fresh; there is no multi-second stale window to work around. The one genuine lookup bug is the
first-match issue below.

### Edge case: nested UBGL ammo before main ammo

`AttTreeToList` appends each installed attachment's children right after it, so on an AR whose
handguard slot (with a UBGL and its nested 40x46 ammo) comes before the receiver/mag/ammo slots,
the flattened list contains the UBGL ammo attachment before the main ammo attachment. Because
the 40x46 ammo uses `HasGranataAmmo`/`EFTRoundName2`, `C.GetAmmoAttachment` does not return it
directly — but its `visualOnly` fallback (`C.TokenFromCategory(40x46)` exists in
`CaliberByToken`) can still select the grenade attachment when the main ammo slot is empty.
Restrict the fallback to the calibre the weapon is expected to feed (weapon trivia/damage stats),
or drop the fallback and rely on `HasAmmoooooooo`/`EFTRoundName` only.

---

## 3. Processed stats on the server at fire time

`SWEP:GetProcessedValue(val, isstatic, base)` is defined in
`Arc9_extracted/lua/weapons/arc9_base/sh_0_stats.lua:457-675` and runs on both realms. It is safe to
call from a server `DoProjectileAttack` wrapper **after** `DoPrimaryAttack` has done
`SetBaseSettings`/`TakeAmmo` (`sh_shoot.lua:394-406`), because all inputs are networked data
tables (`self.dt.*` — GMod data-table aliases created by `SetupDataTables`, see
[`Entity:DTVar`](https://wiki.facepunch.com/gmod/Entity:DTVar); `sh_0_stats.lua:457-458`, `shared.lua:1503`).

Requested stats — all present on the server:

| Stat | Where defined / notes |
|---|---|
| `PhysBulletMuzzleVelocity` | `arc9_base/shared.lua:301` (HU/s, default 150000; EFT ammo sets it via `GenerateEFTAttachment`, `sh_eft_shared.lua:543`, `= initialSpeed / 0.0254`) |
| `Num` | `shared.lua:211` (also `NumUBGL:212`); shotgun ammo attachments override it per shell, e.g. `2922999549/.../eft_ammo_12x70_bulk.lua:21,66` |
| `DamageMax` / `DamageMin` | `shared.lua:171-172`; EFT ammo sets both from `DamageLookupTable` (`sh_eft_shared.lua:548-549`) |
| `Penetration` / `PenetrationDelta` | `shared.lua:218-219`; EFT sets `Penetration = penetrationPower * ARC9EFT.PenetrationStatMult` (`sh_eft_shared.lua:536,552`; `PenetrationStatMult` is exactly 1.0) |
| `BodyDamageMults` | `shared.lua:241` |
| `HeadshotDamage`, `ChestDamage`, `StomachDamage`, `ArmDamage`, `LegDamage` | `shared.lua:235-239` |
| `DamageLookupTable` | `shared.lua:190`; EFT ammo generates a 10-entry table in HU + damage (`sh_eft_shared.lua:516-534,547`); consumed by `SWEP:GetDamageAtRange` (`sh_shoot.lua:982-1036`) |
| `ShootEnt` | `shared.lua:267` |
| `UseDispersion`, `DispersionSpread` | `shared.lua:574-575` |
| `ShouldTracer` | **not a stat** — method `SWEP:ShouldTracer()` at `sh_shoot.lua:915-927`; server-safe (only reads `TracerNum`, `GetNthShot()`, `Clip1()`) |

`isstatic` semantics (`sh_0_stats.lua:457-481,667-672`): `true` caches in `PV_CacheLong` (persists
until `DoInvalidateCache`/`ClearLongCache`) and **skips the dynamic conditioning block**
(burst/nth shot/sight/heat/move/…, `:505-665`). `false`/omitted uses a one-tick `PV_Cache` plus all
dynamic conditions. This matters for parity with ARC9's own calls:

```lua
-- ARC9's own DoProjectileAttack (Arc9_extracted/.../sh_shoot.lua)
swepGetProcessedValue(self, "ShootEnt", true)                    -- :634
local numm = swepGetProcessedValue(self, "Num")                 -- :654  dynamic
swepGetProcessedValue(self, "UseDispersion", true)              -- :616
swepGetProcessedValue(self, "DispersionSpread")                 -- :620  dynamic
swepGetProcessedValue(self, "PhysBulletMuzzleVelocity", true)   -- :626  (phys bullet path)
```

Everything is server-safe: `self.dt` is a GMod data-table alias (not client-only), the
`quickmodifiers` convars (`arc9_mod_damage`, `arc9_mod_muzzlevelocity`, …) are created on both
realms by the shared convar file (`arc9/common/sh_0_convar.lua:1018-1035`; e.g.
`bullet_physics:390`, `mod_damage:695`, `mod_bodydamagecancel:225`, `npc_equality:263`,
`truenames:23`), and the EFT damage-multiplier/range convars the generator reads while attachments
load are also created on both realms (`sh_eft_shared.lua:416-459`).

None of the listed fire-time stats is client-only for the EFT pack: weapon files and attachment
bulks are shared Lua (loaded on both realms), and the values above are plain SWEP/affector fields.
A third-party pack that defines a stat only in a `cl_*.lua` file would return `nil` server-side;
this does not affect the EFT content. (Convars created with `CreateClientConVar` on the client get
a same-named server convar through the shared convar list, so `getValue`'s convar reads are safe.)

**Caching caveat for the bridge:** `PV_CacheLong` lives on the weapon entity and is cleared by
ammo changes/UBGL toggle/deploy — good. But `ARC9ACE_LastShot` stores the shot profile separately
(see §Corrections); ACE resolves damage at impact time, so a profile change while rounds are in
flight uses the new profile for old bullets.

---

## 4. UBGL / grenade launchers: `ShootEnt`

`GetProcessedValue("ShootEnt", true)` is UBGL-aware because the UBGL condition is applied before
the `isstatic` short-circuit. `GetProcessedValue` calls
`getValue(self, "ShootEnt", stat, "UBGL")` whenever `self.dt.UBGL` is set
(`sh_0_stats.lua:499-503`), and `getValue` resolves the suffixed key `ShootEntUBGL` on every
affector. EFT UBGL attachments define exactly that key:

```lua
-- Weapon_pack_extracted/eft_extract/3010049092/lua/arc9/common/attachments_bulk/eft_ubgl_bulk.lua:132-133
ATT.ShootEntUBGL = "arc9_eft_vog25_bang"
ATT.ShootEntForceUBGL = 4000
```

For the dedicated launchers the base weapon itself has `ShootEnt` plus a `ShootEntHook` that
returns the installed ammo's UBGL entity:

```lua
-- Weapon_pack_extracted/eft_extract/3010049092/lua/weapons/arc9_eft_fn40gl.lua:66-68
SWEP.ShootEnt = "arc9_eft_40mm_m433_bang"
SWEP.ShootEntForce = 4000
SWEP.ShootEntHook = function(swep, old) return swep:GetValue("ShootEntUBGL") end
```

(`arc9_eft_m32a1.lua:69-71` is identical; `sh_0_stats.lua:424-427` runs `val.."Hook"..condition`.)
The returned value is a string entity class name, so the truthiness test in
`sv_fire.lua:160` works. The fallback is correct: stock `DoProjectileAttack` re-checks `ShootEnt`
and calls `SWEP:ShootRocket()` (`sh_shoot.lua:633-635,1099-1172`), which is server-only
(`sh_shoot.lua:1100` `if CLIENT then return end`).

Notes:
- The EFT throwables (F1/M67/VOG-25/RShG-2/etc.) are based on `arc9_base_nade` (see §6) and never
  reach `DoProjectileAttack` anyway; `PrimaryAttack` returns early for `Throwable`
  (`sh_shoot.lua:259-261`).
- M32A1 / FN40GL / M203 UBGL therefore keep stock ARC9 projectile entities (`ShootRocket` →
  `ents.Create(ShootEnt)`), not ACE projectiles. That is the intended "explosives keep ARC9"
  fallback.

---

## 5. Client prediction: the duplicate-effects problem

**Yes, the client runs the stock `DoPrimaryAttack` → `DoProjectileAttack` for the local player's
weapon even with a server-only bridge.** Weapon `PrimaryAttack` is predicted by the engine; ARC9
does not gate the projectile code behind `CLIENT` except for effects. Exact guards in
`Arc9_extracted/lua/weapons/arc9_base/sh_shoot.lua`:

| Line | Guard | Effect on the bridge |
|---|---|---|
| `:523` | none — `self:DoProjectileAttack(...)` inside `DoPrimaryAttack` | runs on server *and* client prediction |
| `:614-615` | `ShootPhysBulletBinding`: `if SERVER or (CLIENT and IsFirstTimePredicted())` | client predicted phys bullets run on the first frame of each shot |
| `:690`, `:741` | `if sp and SERVER then self:CallOnClient(...)` | singleplayer tracer bookkeeping only |
| `:758-759` | `AfterShotFunction`: `if !IsFirstTimePredicted() and !sp then return end` | first predicted frame plays **impact decals/sounds/effects** from the client's own trace (`:868-901`) |
| `sh_effects.lua:1-2` | `DoEffects`: `if !IsFirstTimePredicted() then return end` | muzzle flash on client already happens normally |
| `sh_physbullet.lua:70-159` | `ARC9:ShootPhysBullet(..., pred=true)` | on CLIENT inserts an imaginary bullet that is simulated and impacts client-side; `:479` calls `AfterShotFunction` for predicted impacts |

Consequences for a server-only addon:

1. Server damage is not duplicated — replaced `DoProjectileAttack` never calls `FireBullets` or
   `AfterShotFunction` server-side, and client `FireBullets` cannot damage.
2. The client still plays its **predicted ARC9 tracer and impact effects** along the stock
   trajectory (hitscan or ARC9 drag/gravity bullet). The server spawns ACE bullets, which the
   client also renders (ACE's own client effect list, driven by the networked fake crate). So
   players see two tracer systems and may see impact decals/audio in the wrong places. Explosion
   effects from `AfterShotFunction` can also appear beside the real ACE impact.
3. Only a client-side stub can remove this cleanly (e.g. a tiny client file that no-ops
   `DoProjectileAttack` when the server signals "ACE bridge active" via a net message). Without a
   client addon the cosmetic mismatch is unavoidable; it does not affect hit registration.
4. Mismatch grows with range: ACE bullets lose velocity to drag while the client's predicted
   hitscan line is straight. It is not fixable by changing the shared-spread seeds — the bridge
   deliberately reuses ARC9's exact spread maths and seeds (`sv_fire.lua:111-120,189-196` vs
   `sh_shoot.lua:593-603,616-622`), so the *initial direction* already matches.

Documented limitation for the server-only deployment: accept duplicate tracers/decals, or add an
optional client stub. Note the earlier investigation (`docs/ace-amr-arc9-investigation.md:301-303`)
had already flagged that option A wants a server+client addon.

---

## 6. Weapon classes, inheritance, `GetClass()`

- `SWEP:GetClass()` returns the registration class name (the `lua/weapons/<class>.lua` file name),
  for example `arc9_eft_ak74`. Stored tables carry `ClassName` because `weapons.Register` sets it.
- `arc9_eft_base.lua` (`2917343547/lua/weapons/arc9_eft_base.lua:1-6`):
  `SWEP.Base = "arc9_base"`, `SWEP.Spawnable = false`. It is registered as a class (weapon file)
  but never a spawnable weapon; `weapons.IsBasedOn(class, "arc9_eft_base")` is the right scope check.
- All EFT **guns** and the 3 launchers inherit `arc9_eft_base` (94 direct + intermediates such as
  `arc9_eft_m4a1`, `arc9_eft_aps`, `arc9_eft_akm`, …; M32A1/FN40GL/RShG2 check out as direct
  children). Nothing in the EFT packs overrides `DoProjectileAttack`, `DoPrimaryAttack` or
  `PrimaryAttack`.
- **Exception:** all 13 EFT throwables use `SWEP.Base = "arc9_eft_grenade_base"`, which itself is
  `SWEP.Base = "arc9_base_nade"` → `arc9_base` (`3010049092/lua/weapons/arc9_eft_grenade_base.lua:1`,
  `2910505837/lua/weapons/arc9_base_nade.lua:1`). `IsBasedOn(class, "arc9_eft_base")` is **false**
  for them, so `C.IsInScope` excludes them. That is harmless (throwables never reach
  `DoProjectileAttack`) but the phrase "every EFT weapon is based on arc9_eft_base" is inaccurate.
- `arc9_base` itself is `Spawnable = false` (`arc9_base/shared.lua:3`) and `weapons.IsBasedOn`
  returns false for a class against itself, so a scope check will never patch `arc9_base`
  directly; patch it separately if scope 2 must cover base-only ARC9 content.

---

## 7. Ammunition switching and cache invalidation

Flow (server side of the customize menu):

1. Client builds the attachment tree in the customize UI and sends it
   (`Arc9_extracted/lua/weapons/arc9_base/sh_net.lua:1-24` `SendWeapon`/`SendAttachmentTree`).
2. Server `SWEP:ReceiveWeapon` reads it back (`sh_net.lua:74-125`), validates inventory/blacklist
   (`:86-125`), then `self:BuildSubAttachments(tbl)` (`sh_net.lua:127`,
   `sh_subatts.lua:217-244`) — this rewrites `self.Attachments[i].Installed/ToggleNum/SubAttachments`
   and rebuilds addresses.
3. Server calls `self:DoInvalidateCache()` and `self:PruneAttachments()`
   (`sh_net.lua:142-144`), `SendWeapon()` (`:145`), `PostModify()` (`:146`).
4. `PostModify` calls `InvalidateCache()` again (`sh_attach.lua:102-103`) and the actual clear
   happens in `Think` (`sh_think.lua:191-193`). `InvalidateCache` sets `WantToInvalidateCache`
   (`sh_0_stats.lua:80-86`); `DoInvalidateCache` clears all stat/attachment caches (`:89-113`).
5. `SWEP:Attach`/`SWEP:Detach` (`sh_attach.lua:5-55`) are the low-level mutators; they also
   `PostModify()`.

So `GetProcessedValue` and `GetSubSlotList`/`GetAttTable` return post-change data; the bridge does
not need its own invalidation hook. Only caveat: the deferred `Think` clear means a shot fired in
the same frame as the menu commit could see the previous long cache; not reachable via normal
input.

`ARC9.Attachments` can be rebuilt by the admin command `arc9_reloadatts`
(`sh_atts.lua:314-352`); the bridge re-reads `ARC9.GetAttTable` on every shot, so it stays correct.
Don't cache attachment tables across reloads in the bridge.

---

## 8. Gotchas for a `DoProjectileAttack` wrapper

- **No recursion.** `DoProjectileAttack` is a leaf: it calls `ShootRocket` (ShootEnt) or the
  hitscan/phys paths; `ShootPhysBulletBinding`/`ARC9:ShootPhysBullet` never call back into
  `DoProjectileAttack`. Call sites are only `sh_shoot.lua:523` (players) and `sh_npc.lua:20`
  (NPCs). `SWEP:SecondaryAttack` → `DoPrimaryAttack` when `UBGLInsteadOfSights` is set
  (`arc9_base/shared.lua:1649-1656`) — still one call.
- **NPC owners are covered too.** `NPC_PrimaryAttack` (`arc9_base/sh_npc.lua:1-21`) calls
  `DoProjectileAttack`; a class-level patch therefore converts NPC fire as well. `ACE_CreateBullet`
  accepts an NPC `Owner`; `sv_damage` already reproduces ARC9's ×0.25 NPC nerf. If NPC fire should
  stay stock, return `false` when `owner:IsNPC()`.
- **`Num <= 0`.** Stock `DoProjectileAttack` does nothing when processed `Num <= 0`
  (`sh_shoot.lua:654-655`); the bridge clamps `num` to 1 in `sh_convert.lua:281-283`, so a
  zero-pellet weapon would start firing one ACE bullet. Return "not handled" when
  `GetProcessedValue("Num") <= 0`.
- **`AlwaysPhysBullet` / `NeverPhysBullet` / `arc9_bullet_physics*`** are irrelevant to bridged
  fire (the wrapper replaces both branches); they still affect what clients predict (§5).
- **`ShouldTracer`** (`sh_shoot.lua:915-927`) is safe server-side and should be consulted for the
  tracer flag; the bridge currently derives tracer only from the ammo map/name
  (`sh_convert.lua:156-161`), so EFT tracer rounds that rely on `TracerNum`/mag-end behaviour are
  approximated.
- **`Deploy`/`Holster`** invalidate caches and reset UBGL (`sh_deploy.lua:4-14,49`); no state in
  the bridge needs special handling, but a cached `ARC9ACE_LastShot` survives holstering by design.
- **ARC9's own impact systems stop running server-side** for bridged shots: `AfterShotFunction`
  (penetration budget, `PenetrationDelta`, `ArmorPiercing`/kevlar AP, `Hook_BulletImpact` handlers,
  explosion fields, `DistributeDamage`, EFT bleed hooks) only executes from the stock path
  (`sh_shoot.lua:758-913`). ACE's impact/penetration replaces it; EFT bleed and ARC9 impact hooks
  will not fire on server-side hits. That is the expected trade-off, but should be stated in the
  release notes.
- **Damage type / kill credit:** the bridge's player-damage override calls
  `entity:TakeDamage(dmg, inflictor, gun)` exactly like ACE's own `ACE_SquishyDamage`
  (`ArmoredCombatExtended/lua/acf/server/sv_acfbase.lua:462-465`), so kill credit behaves like
  ACE, not ARC9.
- **`GetShootPos`/`GetShootDir` are already resolved** by `DoPrimaryAttack`; the wrapper receives
  `pos/ang/spread`, so it must not recompute them (client/server agreement).
- **Missing ammo/attachment mapping** returns `false` → stock ARC9 path (including stock ARC9
  damage) for that shot. This is intended fallback behaviour; log it once per class to avoid
  silent per-shot differences.

---

## 9. Crate cleanup

- ARC9 base already has `SWEP:OnRemove` (`Arc9_extracted/lua/weapons/arc9_base/sh_init.lua:244-250`,
  EndLoop + shield cleanup) and `SWEP:OnDrop` (`:231-236`, invalidates cache). Since it is
  inherited, a function patch has the same "stored table has no own key" problem (§1); hooking
  `EntityRemoved` avoids it entirely.
- The canonical ACE cleanup for a per-weapon fake crate is `SWEP:OnRemove` + 15 s delayed
  `crate:Remove()`:
  `ArmoredCombatExtended/lua/weapons/weapon_ace_base/init.lua:128-142`. The bridge's
  `InstallCleanup` (`sv_fire.lua:278-287`) reproduces that timing from `EntityRemoved`, which is
  correct: the hook fires for every removal path (player disconnect, weapon remove, cleanup);
  `EntityRemoved` fires after `OnRemove`; ARC9's `OnRemove` does not touch any bridge state, so the ordering does not matter (only the crate entity is touched).
- `EntityRemoved` receives an already-removed entity, but its Lua table (and thus
  `ent.ARC9ACE_Crate`) is still readable; if paranoid, read via `ent:GetTable()`
  (`Entity:GetTable`, [wiki](https://wiki.facepunch.com/gmod/Entity:GetTable)) or wrap
  `SWEP:OnRemove` directly on live entities.
- In-flight bullets reference only `BulletData.Crate` (an entindex) and the client-side ACE
  bullet effect reads the crate's NW vars at creation time
  (`ArmoredCombatExtended/lua/effects/ace_bulleteffect/init.lua:88-118`), so 15 s is enough for
  bullets that are already airborne.
- If the weapon changes hands, refresh the crate owner (`CPPISetOwner`) on the next shot; the
  current `EnsureCrate` sets it only at creation (`sv_fire.lua:75-88`).

---

## Corrections for the bridge implementation

Ordered by severity. File paths relative to the workspace root; do not treat these as edits made
in this task — they are findings for the implementation owner.

### C1 — `sv_fire.lua:234-254` (fatal): the class patch never reaches any EFT weapon

`WrapClass` reads `wep.DoProjectileAttack` from `weapons.GetList()` entries. Those are *stored*
tables and do not contain inherited fields (`weapons.GetStored` contract, §1), so the guard at
`sv_fire.lua:238` returns `false` for every EFT class. `C.PatchedCount` will be `0` and
`TryAttack` is never called.

Fix:

```lua
local merged = weapons.Get(class) or wep          -- inherited copy for the original
local original = merged.DoProjectileAttack
if type(original) ~= "function" then return false end
-- assign wrapper to weapons.GetStored(class), baseclass.Get(class)
-- and every existing entity of that class (see §1 recipe)
```

Also patch `arc9_base` explicitly (scope 2) because `weapons.IsBasedOn("arc9_base", "arc9_base")`
is false, and re-run the patch from `OnReloaded` to survive Lua hot reloads.

### C2 — `sv_fire.lua:244-251`: wrapper needs a re-wrap guard

Store the original on the wrapper (`wrapper.ARC9ACEOriginal = original`) and skip wrapping when
`stored.DoProjectileAttack.ARC9ACEOriginal` exists; otherwise a second `PatchWeapons` run (reload,
`OnReloaded`, a second `InitPostEntity` on map change in listen-server flows) recursively wraps the
wrapper. `C.PatchedClasses` is a module-level table that only guards the current Lua state.

### C3 — `sh_convert.lua:281-283` (gameplay): zero-pellet guard missing

Stock ARC9 skips the shot when processed `Num <= 0` (`sh_shoot.lua:654-655`). The bridge clamps to
`math.Clamp(num, 1, D.MaxPellets)` and fires one ACE projectile. Return `nil, "no-pellets"` (or
have `TryAttack` return `false`) when `num <= 0`.

### C4 — `sh_convert.lua:260` (parity): wrong cache flavour for muzzle velocity

`swep:GetProcessedValue("PhysBulletMuzzleVelocity")` uses the per-tick dynamic cache and dynamic
conditions. ARC9's own physical-bullet path calls the same stat with `true` (`sh_shoot.lua:626`),
which uses `PV_CacheLong` and skips burst/sight/heat conditioning. Use
`swep:GetProcessedValue("PhysBulletMuzzleVelocity", true)` for identical numbers, and let the long
cache be cleared by ARC9's invalidation (already covered by §7).

### C5 — `sh_convert.lua:310-314` (damage): raw `att.DamageMax` bypasses ARC9 processing

Seeding `eftDamage` from the attachment table (`att.DamageMax`) ignores: attachment
overrides/hooks, the `arc9_mod_damage` quickmodifier (`sh_0_stats.lua:34-37,343-351`), and the fact
that `DamageMax` is the LUT's 5 m entry, not the muzzle value (`sh_eft_shared.lua:548`). Use
`swep:GetProcessedValue("DamageMax", true)` for the base and/or `swep:GetDamageAtRange(range)` for
the actual range (see C6).

### C6 — `sv_damage.lua:49-57` (damage model): falloff does not match EFT

`dmg = shot.damage * sqrt(KE/KE0)` (clamped to 2 %) is not ARC9's damage curve. EFT's
`DamageLookupTable` is exponential with a **58.3 % floor** over 5–1000 m
(`Arc9_extracted` → `sh_eft_shared.lua:516-534`; consumed by `GetDamageAtRange`,
`sh_shoot.lua:982-1036`). Long-range bridged shots will therefore be far weaker than the same
round in stock ARC9. Fix: store the processed `DamageLookupTable` (and `DamageMin`/`RangeMin`/
`RangeMax`, or simply `gun:GetDamageAtRange`) in `ARC9ACE_LastShot` at fire time, and compute the
impact range from a stored muzzle position. Passive approach: add
`ARC9BridgePos0 = pos` to the BulletData in `sh_convert.BuildBulletData`/`sv_fire.FirePellet`,
then in `sv_damage.PlayerDamage` use `flight-start distance` (ACE exposes the bullet table's
`Pos`/`SimPos` only to round callbacks; simplest is `BulletData.ARC9BridgePos0:Distance(hitPos)`
if the hit position is available — otherwise fall back to the current energy approximation and
document the reduced long-range damage).

### C7 — `sh_convert.lua:191-217` (edge case): first-match ammo lookup can pick UBGL ammo

See §2. For a rifle with a UBGL installed, the flattened slot list can contain the nested 40x46
ammo attachment before the main ammo slot. It is mostly filtered by the
`HasGranataAmmo`/`EFTRoundName2` naming, but the `visualOnly` token fallback (`:207-215`) can still
return the grenade attachment. Restrict the fallback to attachments whose `Category` matches the
weapon's expected cartridge family, or remove the fallback (EFT guns ship an `Integral` ammo
attachment, so the main slot is normally never empty).

### C8 — `sv_fire.lua:90-105` (visuals): crate NW data is a subset of ACE's contract

`UpdateCrate` mirrors `acf_fakecrate2:RegisterTo` (`ArmoredCombatExtended/lua/entities/acf_fakecrate2/init.lua:35-56`)
for Caliber/ProjMass/FillerMass/DragCoef/AmmoType/Tracer/Color/TracerColour/SetColor, but omits
`SetNWString("Sound")`, `SetNWFloat("WPMass")`, `SetNWFloat("Accel")` and
`SetNWString("BulletModel")`. The client ACE bullet effect reads `BulletModel` (default
`models/munitions/round_100mm_shot.mdl`, `ace_bulleteffect/init.lua:111`), so every bridged round
will be drawn as a 100 mm shell and its tracer/crack sizing uses defaults. Populate the missing
fields (a per-calibre model lookup, or at least `SetNWString("BulletModel", ...)` with a rifle
round model). Note the crate is deliberately never `Spawn()`ed — that is what ACE's own
`weapon_ace_base` does (`init.lua:9-16`) — so do not "fix" that without live testing.

### C9 — `sv_fire.lua:168-170` (state): crate owner only set at creation

`EnsureCrate` sets `CPPISetOwner(owner)` once. After a weapon pickup/drop/transfer the crate owner
is stale (affects ACE's bullet filtering/attribution). Re-apply the owner on every shot (cheap) or
wrap ARC9's `OwnerChanged` (`sh_init.lua:238`).

### C10 — `sh_convert.lua:156-161` (parity): tracer flag ignores `SWEP:ShouldTracer`

Use `swep:ShouldTracer()` (server-safe, `sh_shoot.lua:915-927`) in addition to the ammo-name
heuristic; that is the exact function ARC9 uses (`:637`) and it covers `TracerNum`, mag-end traces
and per-shot tracer cycling. Also set `Tracer` to a number (canonical rounds use a cm length, e.g.
`math.min(caliber/5, 3)` in `ace_roundfunctions.lua:27`), not just 0/1.

### C11 — `sv_damage.lua:121-128` (ACE semantics): `Loss = 1` is a deliberate-looking choice to verify

The returned table claims the entire impact energy is lost. ACE consumes `Loss` in
`ACE.GetPostPenetration` (`ArmoredCombatExtended/lua/acf/server/sv_acfdamage.lua:410-425`) and in
`ACE.KEShove` (`sv_acfdamage.lua:998-1000`): `Loss = 1` means no residual energy (bullet stops in
the target) and maximal shove. That is reasonable for a body hit but should be a conscious choice;
returning `0` would let rounds continue through players. Document the choice in the file header.

### C12 — `sv_damage.lua:45-101` (missing feature): no ARC9 AP/kevlar model

For players, ARC9 additionally applies `ArmorPiercing` (`sh_shoot.lua:817-855`) and the custom AP
health-removal hook. The bridge's `TakeDamage`-only path cannot reproduce it; EFT armour-piercing
ammo will therefore not behave like stock ARC9 against players. Either accept (ACE-style squishy
damage) or state it explicitly in the config description.

### C13 — `sv_fire.lua:301-338` (diagnostics, minor): dead `cvAudit` check

`Audit()` prints the summary/samples and only then checks `if cvAudit and not cvAudit:GetBool() then return end`
(`:337`). The check is inert. Move it to the top of the function if the cvar is meant to gate output.

### C14 — `sv_fire.lua:270-276` (dead code): `RemoveCrateFor` is unused

`InstallCleanup` uses its own logic; delete or use it.

### C15 — `autorun/arc9_ace_bridge.lua:42-47`: patch order vs ARC9's own `InitPostEntity` hooks

Both ARC9 (`sh_patching.lua:53`, `sh_npc.lua:194`) and the bridge hook `InitPostEntity`; hook order
depends on addon load order but the two touch disjoint tables (ARC9 patches stats, the bridge
patches functions), so there is no conflict. Do not assume the bridge runs after ARC9's hooks; it
does not need to. `ARC9.Attachments` is ready before `InitPostEntity` because `ARC9.LoadAtts()`
runs at file load (`sh_atts.lua:361`).

### C17 — `sh_convert.lua:222-233` (minor): read Trivia through `GetValue`

`C.GetTriviaCaliber` reads `swep.Trivia` directly. The canonical accessor is
`swep:GetValue("Trivia")` (same table plus affector/hook overrides; ARC9 itself reads it that way
for the customize UI, `cl_customize_ui_trivia.lua:130`). Not a correctness problem today (EFT
weapon files set raw phrase keys and no affector overrides `Trivia`), but `GetValue` is the
supported path. All 101 EFT `Trivia` calibre entries use raw phrase keys such as
`"eft_trivia_calibr_556x45"`, which is exactly what `C.TriviaCaliberToken` keys on — do not
localise them before matching.

### C16 — mapping data gap, not API: `sh_eft_ammo_map.lua` is a stub

`Arc9AceBridge/lua/arc9_ace_bridge/sh_eft_ammo_map.lua:18` defines an empty `EFTAmmoMap`.
`DescribeAttachment` then derives mass from English descriptions / cartridge-weight ratios, and
calibre from the token table in `sh_config.lua`. The pack generator
(`ARC9EFT.GenerateEFTAttachment`) does not write projectile mass at all — descriptions are the only
reliable source (e.g. `"a 3.6 gram lead core ... bullet"` in
`2917343547/.../eft_ammo_556_bulk.lua:16`). Run `tools/gen_eft_ammo_map.py` before deployment, or
expect per-round mass errors (and therefore ACE penetration/energy errors) for rounds whose
description does not state a gram weight.

---

## Appendix A — processed-stat reference for the wrapper

What ARC9's own `DoProjectileAttack`/`ShootPhysBulletBinding` uses, and the bridge equivalent:

| ARC9 use | Line | Bridge |
|---|---|---|
| `ShootEnt` (static) | `sh_shoot.lua:634` | `sv_fire.lua:160` — fallback, OK |
| `Num` (dynamic) | `:654` | `sh_convert.lua:281` — matches minus C3 |
| `ShouldTracer()` | `:637,915` | not used — C10 |
| `UseDispersion` (static) | `:616,678` | `sv_fire.lua:189` — OK |
| `DispersionSpread` (dynamic) | `:620,682` | `sv_fire.lua:193` — OK |
| `PhysBulletMuzzleVelocity` (static) | `:626` | `sh_convert.lua:260` — C4 |
| spread/tracer/impact-force | `:692-704` | not needed (ACE owns impact) |
| `DamageMax` | `:712` | `sh_convert.lua:310` — C5 |
| `BodyDamageMults`, hitgroup mults | `:798-815` | `sv_damage.lua:60-77` — OK |
| `DamageType` | `:765` | n/a (ACE damage) |
| `Penetration`, `PenetrationDelta` | `:780-786` | n/a (ACE penetration) |
| `ArmorPiercing` | `:818-855` | missing — C12 |
| `ImpactDecal/Effect/Sound`, `Explosion*` | `:868-902` | missing (ACE effects instead) |

## Appendix B — cache/invalidation map relevant to the bridge

| Cache | Written by | Cleared by |
|---|---|---|
| `SWEP.StatCache` | `getValue` (`sh_0_stats.lua:333,433,447`) | `DoInvalidateCache` (`:92`) |
| `SWEP.PV_Cache` (1 tick) | `GetProcessedValue` (`:670`) | tick rollover (`:478-480`), `ClearLongCache`, `DoInvalidateCache` |
| `SWEP.PV_CacheLong` (`isstatic`) | `GetProcessedValue` (`:668`) | `ClearLongCache` (`:74-77`), `DoInvalidateCache` (`:93`) |
| `SWEP.GetSubSlotListCache` | `GetSubSlotList` (`sh_subatts.lua:54`) | `DoInvalidateCache` (`sh_0_stats.lua:109`) |
| `SWEP.AttTableCache` | `getFinalAttTable` (`sh_0_stats.lua:139`) | `DoInvalidateCache` (`:95`) |
| `SWEP.HookCache` / `AffectorsCache` | `runHook`/`getAllAffectors` (`:289,234`) | `DoInvalidateCache` (`:97,:100`) |
| bridge `swep.ARC9ACE_Crate` | `EnsureCrate` (`sv_fire.lua:86`) | `EntityRemoved` cleanup (`sv_fire.lua:279-287`) |
| bridge `swep.ARC9ACE_LastShot` | every shot (`sv_fire.lua:175-183`) | overwritten by next shot only — see C6 §3 caveat |

## Appendix C — things to verify on a live server

1. That a stored-class patch at `InitPostEntity` reaches subsequently spawned player weapons
   (expected yes; print inside the wrapper once). Fallback: patch live entities too (in recipe).
2. Whether `acf_fakecrate2` NW data reaches clients while the crate is never `Spawn()`ed — ACE
   relies on the same pattern, but confirm bridged tracers/bullet models appear.
3. Client-side duplicate tracer/impact severity (§5) and whether a client stub is acceptable.
4. ACE `BulletIndexLimit` load (`ArmoredCombatExtended/lua/autorun/acf_globals.lua` — 5000 live
   bullets) under full-auto EFT fire; ACE copies a BulletData table per bullet
   (`sv_acfballistics.lua:168` `ACE_AcquireBullet`).
5. Long-range damage after C6 is implemented (compare a 100 m and 500 m hit against the EFT LUT).
