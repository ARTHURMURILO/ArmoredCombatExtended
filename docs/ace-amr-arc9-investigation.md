# ACE ⇄ ARC9 investigation

Scope: what it would take to (1) give `weapon_ace_amr` selectable 40 mm ammunition and
(2) make ARC9 weapons fire ACE projectiles.

Repos inspected:

- `ArmoredCombatExtended/` — fork of ACE, branch `master`, HEAD `9e799062` (clean tree).
- `Arc9's base GMA/gmpublisher.gma` — extracted to `Arc9_extracted/` with `tools/gma_extract.py`
  (GMA v3, 1465 files, ARC9 Weapon Base only — **no EFT pack**, so pack-specific tables are
  not available for inspection here).

---

## 1. How an ACE SWEP actually fires

The player-held weapons are plain GMod SWEPs whose base class is `weapon_ace_base`. Nothing
about them uses the `acf_gun` entity; they hand ACE a `BulletData` table and ACE simulates it.

```
SWEP:PrimaryAttack()          weapon_ace_base/shared.lua:303
  └ SWEP:Shoot()              weapon_ace_base/shared.lua:265   (SERVER only)
      └ SWEP:ACEFireBullet()  weapon_ace_base/init.lua:18
          ├ BulletData.Pos/Flight = shooter eye pos + dir * MuzzleVel * 39.37
          ├ BulletData.Owner/Gun/Crate
          └ ACE_CreateBullet(BulletData)   acf/server/sv_acfballistics.lua:237
```

`BulletData` is built once by `SWEP:InitBulletData()` (`weapon_ace_base/shared.lua:122`), which is
called from `SWEP:Initialize()` (`weapon_ace_base/init.lua:146`). Every weapon overrides it with a
hand-tuned table. Each shot reuses that table, but `ACE_CreateBullet` → `ACE_AcquireBullet`
(`sv_acfballistics.lua:168`) **deep-copies the table per bullet**, so changing `self.BulletData`
later never corrupts rounds already in flight.

Damage resolution: `ACE.RoundImpact` → `ACE.Damage` → `ACE_Damage`
(`acf/server/sv_acfbase.lua:141`) which branches to `ACE.SquishyDamage` for players/NPCs
(`sv_acfbase.lua:311`), `ACE.PropDamage` for props, `ACE.VehicleDamage` for vehicles. The round's
`Type` string selects the damage multiplier and the impact behaviour via `ACE.RoundTypes[Type]`.

### The fake crate

Because ACE expects bullets to come from an ammo crate entity, every SWEP spawns an
`acf_fakecrate2` and registers itself to it (`weapon_ace_base/init.lua:9`,
`lua/entities/acf_fakecrate2/init.lua:35`). `RegisterTo` copies `Type`, `Caliber`, `ProjMass`,
`FillerMass`, `DragCoef`, `Tracer`, `Colour` into networked vars. It is called from
`UpdateFakeCrate()`, which is safe to call again at any time — that is the mortar's pattern
(`weapon_ace_portablemortar/shared.lua:620-637`).

---

## 2. Where 40 mm ammunition comes from

ACE does not have "ammo items"; it has **gun definitions** + **round-type definitions**.

- Gun: `ACE.DefineGun("40mmAC", …)` — `acf/shared/guns/autocannon.lua:52-67`.
  `caliber = 4.0` (cm), `round = { maxlength = 45, propweight = 0.9 }` (cm of case, kg of powder).
- Round types: `lua/acf/shared/rounds/round*.lua`, each registering
  `ACE.RoundTypes[Type]`, `ACE.IdRounds[netid]`, and a `list.Set("APRoundTypes"/"HERoundTypes"/…)`.
- The conversion contract used by every ammo crate is:

  ```lua
  local PlayerData = { Id = gunId, Type = roundType,
                       PropLength = …, ProjLength = …, Data5 = …, Data6 = …, Tracer = … }
  self.BulletData = ACE.RoundTypes[roundType].convert(nil, PlayerData)
  ```

  (`lua/entities/acf_ammo/init.lua:617-618`; `PlayerData` built at `:585-607`.)

  `convert` calls `ACE.RoundBaseGunpowder` (`acf/shared/rounds/ace_roundfunctions.lua:10`), which:
  - looks the **gun** up in `ACE.Weapons.Guns[PlayerData.Id]` to get caliber, max round length and
    max powder weight (`:31`),
  - clamps `PropLength`/`ProjLength` to the case (`:33-55`),
  - computes `PropMass`, `FrArea`, `ProjVolume`, `RoundVolume` (`:57-60`).

  Each round file then does its own physics (AP/KHVAP sub-calibre mass, HE filler volume,
  HEAT cone/slug, APHE fuse, …) and returns `Data` (physics) on the server, `Data + GUIData`
  (display) on the client. **The server result is what you fire.**

### `ACE.AmmoBlacklist`

Each round file declares which **gun classes** may use it, e.g.
`ACE.AmmoBlacklist.HE = { "MG", "ECM", "ATR", "SBC" }` (`roundhe.lua:3`). The ACE menu filters gun
classes against this list (`acf/client/cl_acemenu_gui.lua:1273`), so if the AMR is treated as a
40 mm autocannon (`AC`) the legal types are:

| Legal for `AC` | Rejected for `AC` |
|---|---|
| AP, APHE, APDS, APFSDS, HVAP, HP, HE, HEAT | HESH, THEAT, THEATFS, HEATFS, HEFS, FL, SM (smoke), CHAFF, GLATGM, cluster AP/HE/HEAT, FLR |

---

## 3. The AMR as it exists today

`lua/weapons/weapon_ace_amr/shared.lua`

- `Base = weapon_ace_base`, clip size 1, ammo pool `XBowBolt` (`:14-17`).
- `InitBulletData()` at `:69` is a **hand-rolled bullet**, not a round-type conversion. It sets
  `Id = "40mmMG"` then immediately overwrites it with the legacy numeric `Id = 1` (`:71-73`),
  `Type = "HVAP"`, `Caliber = 4.0`, `PropLength = 11`, `ProjLength = 12`, `Data5 = 0.2`, and does
  the sub-calibre mass/pen maths inline (`:80-114`).
- Result today: **1013 m/s, 453 g projectile, ≈89 mm RHA** (measured with the probe below).

Because `Type = "HVAP"` is registered, ACE handles it correctly — the weapon just has exactly one
recipe and no way to change it.

### Measured alternative: real round conversions

`tools/round_probe.lua` loads ACE's real `round*.lua` files under LuaJIT and runs their `convert`
with the AMR's case (11 cm powder, 12 cm projectile, 24 cm max length — identical results whether
the gun is the stock `40mmAC` or a dedicated `40mmAMR` because the case isn't binding at these
lengths). Full output: `tools/round_probe_output.txt`.

| Type | Muzzle vel | Projectile | Filler | KE pen | Blast | Notes |
|---|---|---|---|---|---|---|
| **today's HVAP** | **1013 m/s** | **453 g** | – | **89.1 mm** | – | hand-rolled, current |
| HVAP (standard) | 794 m/s | 186 g | – | 74.9 mm | – | best armour pick of the standard set |
| AP | 624 m/s | 1191 g | – | 34.5 mm | – | full-bore, heavy, slow |
| APHE | 638 m/s | 1141 g | 13 g | 34.1 mm | 1.9 m | 20 ms fuse |
| APDS | 565 m/s | 745 g | – | 33.8 mm | – | pen-area penalty hurts at 40 mm |
| APFSDS | 604 m/s | 573 g | – | 34.1 mm | – | same |
| HP | 670 m/s | 1033 g | – | 4.7 mm | – | anti-personnel |
| HE | 740 m/s | 848 g | **91 g** | 3.1 mm | 3.6 m | 55 cm³ filler |
| HEAT | 771 m/s | 781 g | 63 g | 3.1 mm / **23.7 mm slug** | 3.2 m | 30° cone |
| HESH *(not AC-legal)* | 754 m/s | 816 g | 99 g | 3.1 mm | 3.7 m | 60 cm³ filler |

Two things fall out of this:

1. **The standard HVAP conversion is ~16 % weaker than the AMR's current hand-rolled round.**
   If you want the rifle to keep its current punch, keep today's numbers as a bespoke "AMR HVAP"
   preset and use standard conversions for the new types.
2. At 40 mm, APDS/APFSDS/AP are all *worse* than HVAP (ACE's pen-area and mass-penalty maths
   dominates at this calibre). A curated list of **HVAP, APHE, AP, HE, HEAT, HP** is more useful
   than exposing all eight legal types.

---

## 4. Implementing selectable ammo on the AMR

The mortar is the in-repo precedent: `SWEP.RoundType` + three `InitBulletData` variants + a
key-driven cycle that calls `InitBulletData…()`, `UpdateFakeCrate()` and a NetworkVar for the HUD
(`weapon_ace_portablemortar/shared.lua:80, 264/338/411, 620-637`). We would keep the same shape but
replace the three hand-written tables with round conversions.

### Sketch

```lua
-- shared.lua of weapon_ace_amr
SWEP.AmmoTypes = { "HVAP", "APHE", "AP", "HE", "HEAT", "HP" }   -- curated, AC-legal
SWEP.AmmoIndex = 1

-- one preset per type: everything convert() needs beyond the gun itself
SWEP.AmmoPresets = {
    HVAP  = { PropLength = 11, ProjLength = 12, Data5 = 0.2,  Colour = Color(0,255,0) },
    APHE  = { PropLength = 11, ProjLength = 12, Data5 = 8,    Data6 = 0.02 },
    AP    = { PropLength = 11, ProjLength = 12 },
    HE    = { PropLength = 11, ProjLength = 12, Data5 = 55 },
    HEAT  = { PropLength = 11, ProjLength = 12, Data5 = 55,   Data6 = 30 },
    HP    = { PropLength = 11, ProjLength = 12, Data5 = 20 },
}

function SWEP:SetAmmoType(roundType)
    local round = ACE.RoundTypes[roundType]
    if not round then return end

    local preset = table.Copy(self.AmmoPresets[roundType] or {})
    preset.Id, preset.Type = "40mmAMR", roundType
    preset.Tracer, preset.TwoPiece = preset.Tracer or 0, preset.TwoPiece or 0

    self.BulletData = round.convert(nil, preset)     -- server: physics, client: physics+display
    self.BulletData.Colour = preset.Colour or Color(200,200,200)
    self.BulletData.Crate = IsValid(self.FakeCrate) and self.FakeCrate:EntIndex() or nil

    self.CurrentAmmoType = roundType
    self.Type, self.Caliber = roundType, self.BulletData.Caliber
    self.ProjMass, self.DragCoef, self.FillerMass = self.BulletData.ProjMass, self.BulletData.DragCoef, self.BulletData.FillerMass
    self:UpdateFakeCrate()
    if SERVER then self:DoAmmoStatDisplay() end
end
```

`InitBulletData()` then just calls `self:SetAmmoType(self.CurrentAmmoType or "HVAP")`.

Notes / gotchas found in the code:

- **Realm asymmetry is expected**: `convert` returns physics-only on SERVER and physics + display
  fields (MaxPen, Fragments…) on CLIENT. `PropMass` needed by single-player effects
  (`ACE_NetworkSPEffects`) exists in both. Just don't read GUI fields inside `Shoot()`.
- **`Id` matters**: `convert` resolves the gun through `ACE.Weapons.Guns[PlayerData.Id]`. Pass a
  real gun id. Adding `ACE.DefineGun("40mmAMR", {... caliber = 4.0, gunclass = "AC",
  round = { maxlength = 24, propweight = 0.2212 } })` gives the weapon its own chamber limits
  (and makes future sliders safe), but the stock `40mmAC` id also works with today's presets.
- **Fake crate must be refreshed** after every switch or the shell/tracer visuals keep the old
  colour and filler data.
- **`DoAmmoStatDisplay()`** (base `init.lua:71`) is what prints "40mm HVAP ammo: … pen … blast" to
  the owner; call it after switching so the player gets feedback.
- **In-flight bullets are safe** (copy on acquire, `sv_acfballistics.lua:168`).
- Switching costs nothing ammo-wise right now: the AMR's pool is a single `XBowBolt` count, so all
  types share it. Per-type pools would need custom ammo types + `SWEP.Primary.Ammo` juggling; that
  is a separate (bigger) change.
- UX: the mortar cycles on held `IN_RELOAD` at 0.1 s, which is janky. For the AMR I'd use
  key-down edge detection (one press = one step) and show the type in the notification/HUD, or a
  small DMenu on `R` while the magazine is full. Reload is otherwise a no-op at clip 1 because the
  base auto-reloads after each shot (`weapon_ace_base/shared.lua:364`).

---

## 5. ARC9 side

### The shoot path

```
SWEP:PrimaryAttack            arc9_base/sh_shoot.lua:249
  └ SWEP:DoPrimaryAttack      :353
      ├ RunHook("HookP_BlockFire")      :396   (return true aborts the shot)
      ├ RunHook("Hook_PrimaryAttack")   :403
      ├ TakeAmmo / animations / sounds / recoil / spread
      └ SWEP:DoProjectileAttack(pos, ang, spread)   :633
          ├ ShootEnt? → SWEP:ShootRocket()          :1099   (grenades/RPGs)
          └ otherwise:
              ├ hitscan: owner:FireBullets(...) with a Callback → AfterShotFunction :758
              └ or ARC9:ShootPhysBullet(...)   (arc9/shared/sh_physbullet.lua:70)
```

`DoProjectileAttack` is the single choke point through which **every** bullet of **every** ARC9
weapon passes, after all ammo/recoil/animation bookkeeping and before impact handling. Replacing
it replaces the projectile, and nothing else.

### Why the EFT panel shows "Penetration 1066.8 mm"

ARC9's `Penetration` is **not** RHA millimetres. It is a penetration budget in Hammer units:

- `SWEP.Penetration = 5` — "Units of wood that can be penetrated" (`arc9_base/shared.lua:218`).
- The panel prints it via `i * ARC9.HUToM * 1000` (`arc9/client/cl_autostats.lua:16-22, 63`), i.e.
  it just converts HU → mm. `ARC9.HUToM = 0.0254` (`arc9/common/sh_common.lua:265`), so
  1066.8 mm = **42 HU of pen budget**.
- On impact the budget is spent in 1–4 HU steps scaled by `ARC9.PenTable[material]`
  (`arc9_base/sh_penetration.lua:53, 106`).

Likewise `ArmorPiercing` (the 45 %) is "proportion of damage done directly, ignoring protection"
(`arc9_base/shared.lua:232`), not a penetration chance. Neither number can be copied into ACE —
ACE derives everything from **calibre, projectile mass, powder mass and muzzle velocity**
(`ACE_MuzzleVelocity`, `ACE.Kinetic`, `ACE.CalcPenetration`; `acf/shared/sh_ace_functions.lua:183-222`).

So an ARC9→ACE bridge must build `BulletData` from physical-ish inputs:

| ACE field | ARC9 source |
|---|---|
| `Caliber` (cm) | no first-class field — `SWEP.Caliber` if the pack defines it, else the trivia "Calibre" string (`5.45x39mm`), else a per-ammo lookup table |
| `MuzzleVel` (m/s) | `GetProcessedValue("PhysBulletMuzzleVelocity") * ARC9.HUToM` (the "Muzzle Velocity 920 m/s" stat) |
| `ProjMass` | solve a steel-cylinder mass from calibre + a nominal projectile length, or ditto from `DamageMax` |
| `PropMass` | solved backwards from the desired muzzle velocity through `ACE_MuzzleVelocity`, or a nominal powder mass |
| `PenArea` | `FrArea ^ ACE.PenAreaMod` (like every SWEP) |
| `Ricochet` | `GetProcessedValue("RicochetAngleMax")` maps 1:1 |
| `Type` | default `"AP"` (ACE's generic rifle behaviour); optional per-weapon override |
| `Num`/spread | already computed by ARC9 before `DoProjectileAttack` |
| `Tracer` | `self:ShouldTracer()` (`sh_shoot.lua:915`) |

A useful sanity check on the ACE side: a 5.45 mm, 3.4 g projectile at 920 m/s yields
`Energy.Penetration ≈ 6`, which passes the player ribcage threshold (~1.9) in
`ACE.SquishyDamage` and lands ~20 damage on the torso (`BaseDamage = cal × (4 + 0.1 cal)`,
`sv_acfbase.lua:344`) — i.e. ACE's own player damage scale is sane for ARC9 rifles, not just for
cannon shells.

### Integration options

**A. Full replacement (the "ARC9 fires ACE bullets" idea).**
Wrap `DoProjectileAttack` for ARC9 weapons (patch each stored SWEP at `InitPostEntity`, the same
hook ARC9 itself uses in `arc9/common/sh_patching.lua`):

```lua
local orig = swep.DoProjectileAttack
swep.DoProjectileAttack = function(self, pos, ang, spread)
    if not ShouldUseACE(self) then return orig(self, pos, ang, spread) end
    -- build BulletData from processed stats, then per pellet:
    --   ACE_CreateBullet with Pos = pos, Flight = dir * MuzzleVel * 39.37,
    --   Owner = self:GetOwner(), Gun = self, Filter = {owner, vehicle}
end
```

Keeps ARC9's sounds, animations, recoil, ammo, HUD and attachments; swaps the projectile,
penetration and damage model for ACE's. Loses ARC9's impact decals/`Hook_BulletImpact` side
effects unless re-emitted from the ACE bullet (ACE has its own impact effects keyed off
`BulletData.Type`). Gate it on a convar, and let `ShootEnt`/melee/throwables fall through to the
original.

**B. Hybrid (vehicle-only bridge).** Let ARC9 shoot normally, but when a bullet hits an entity with
`.ACF`, route the damage through `ACE.Damage` instead of ARC9's. Much smaller, no projectile
rewrite, but ARC9 ranges/penetration stay arcade and only vehicles feel the change. Good stepping
stone / fallback if A is too invasive for a public server.

**C. Full ACE missiles for ARC9 launchers.** Out of scope for now: those go through
`SWEP:ShootRocket()` and `arc9_proj_base`, a different system.

Risk notes for A:

- Needs a calibre source for arbitrary packs (the EFT pack isn't in this archive; only ARC9 base
  is). Without a mapping table, bullets would fall back to a guessed calibre.
- `ACE.BulletIndexLimit` caps the sim at 5000 live bullets (`lua/autorun/acf_globals.lua:191`), and ACE traces every bullet
  every tick; a 650 RPM × 32-player server is the same load ACE's own SWEPs already produce, but
  it is heavier than ARC9 hitscan. `ACE_AcquireBullet` copies a table per bullet too.
- ACE bullets only spawn when `ace_gunfire` is on and the addon runs server-side; the bridge must
  be a server+client addon and must no-op cleanly when ACE or ARC9 is missing.

---

## 6. Suggested order of work

1. **AMR ammo switch** (small, self-contained): curated presets + convert + fake-crate refresh +
   key handling + notification. Decide first whether current HVAP stats stay as a bespoke preset.
2. **ARC9 bridge, phase 1 (option B)**: on ACF entities, convert ARC9 hits into `ACE.Damage`
   calls with a stat-derived `BulletData`. Validates the stat→ACE mapping on a live server with
   minimal risk.
3. **ARC9 bridge, phase 2 (option A)**: replace `DoProjectileAttack` behind a convar and compare
   feel on a test map. Keep B as the fallback.

## 7. Open decisions

- AMR: which round types to expose (suggested: HVAP / APHE / AP / HE / HEAT / HP), and whether
  current hand-rolled HVAP numbers are preserved.
- AMR: switch control (`R` press, scoped+`R`, or a small menu).
- AMR: shared `XBowBolt` pool vs per-type ammo pools.
- ARC9: mirror ARC9 damage (players get ARC9-ish lethality) or accept ACE's damage scale for
  everything; and whether to start with hybrid B or go straight for A.
