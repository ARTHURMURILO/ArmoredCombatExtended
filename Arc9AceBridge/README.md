# ARC9 ⇄ ACE projectile bridge

Server-side Garry's Mod addon that makes **ARC9 weapons fire real ACE (Armored
Combat Extended) projectiles**. The first mapped pack is **ARC9 Escape From
Tarkov** (workshop collection `2952911209`): every EFT gun spawns an ACE bullet
built from the *actually installed ammunition attachment* (calibre, projectile
mass, muzzle velocity, ballistic coefficient), so EFT ammo selection, magazines,
attachments, sounds, animations and recoil keep working while penetration,
armour, vehicle damage and ballistics come from ACE.

Stock ACE rounds derive their external ballistics from a gunpowder/case model.
ARC9 knows the real numbers, so the bridge builds the ACE projectile directly
and only uses ACE's physics, damage-to-armour and vehicle pipeline.

```
ARC9 DoProjectileAttack  (stock: hitscan / ARC9 phys bullets)
        │  patched per SWEP class at InitPostEntity
        ▼
ARC9-ACE bridge ── installed ammo attachment (eft_ammo_* shortname)
        │            ├─ calibre  (generated EFT ammo map / category token)
        │            ├─ mass     (description bullet weight / shell data)
        │            ├─ muzzle velocity (processed ARC9 stat, silencers incl.)
        │            └─ BC       (drag normalisation)
        ▼
ACE_CreateBullet  (BulletData with Caliber/ProjMass/MuzzleVel/PenArea/DragCoef)
        ├─ ACE traces, drag, gravity, penetration, ricochet, spalling
        ├─ players/NPCs: EFT damage + ARC9 hitgroup multipliers (default)
        └─ props/vehicles: pure ACE armour + damage pipeline
```

## Install (server)

1. Copy the `Arc9AceBridge` folder into `garrysmod/addons/arc9_ace_bridge/`
   (the folder must contain `lua/autorun/arc9_ace_bridge.lua`).
2. Make sure the server has **ARC9 Weapon Base** (workshop `2910505837`),
   **ACE** (workshop `3333669763`) and the ARC9 EFT packs you want.
3. Restart the server. The journal should show:

   ```
   [ARC9-ACE] patched 1 ARC9 projectile function(s): 189 ARC9 weapon classes registered, 1 own DoProjectileAttack
   [ARC9-ACE] player damage model: EFT/ARC9
   [ARC9-ACE] 40K/Tarkov ACE projectile bridge ACTIVE (scope=EFT pack, player damage=EFT/ARC9)
   [ARC9-ACE] ammunition mapping: 197/197 EFT ammo attachments resolved (0 unresolved)
   [ARC9-ACE] weapon coverage: NN/NN EFT weapons have a mappable default ammo slot
   ```

No client files: clients keep stock ARC9 for prediction effects. Only the server
runs the bridge.

## ConVars

| ConVar | Default | Meaning |
|---|---|---|
| `arc9ace_enable` | `1` | Master switch. `0` restores stock ARC9 projectiles instantly (no restart). |
| `arc9ace_scope` | `1` | `1` = EFT pack only (`arc9_eft_base` weapons). `2` = every ARC9 weapon that resolves a calibre. |
| `arc9ace_player_damage` | `1` | `1` = EFT/ARC9 damage model vs players/NPCs. `0` = pure ACE squishy damage (mostly useless for rifle calibres against unarmoured players). |
| `arc9ace_player_damage_mult` | `1` | Global multiplier on bridged damage to players/NPCs. |
| `arc9ace_drag_mult` | `1` | Drag multiplier for bridged bullets (default = real G1-BC ballistics). `1.5`–`2.5` compresses ranges (more drop/velocity loss), `>6` ≈ the old cannon-shell behaviour. |
| `arc9ace_pen_mult` | `1` | Global multiplier on top of the per-ammo penetration class (FMJ ×1.0, AP ×2.2, APCR ×3.2). |
| `arc9ace_audit` | `1` | Print the ammunition/weapon mapping audit at startup. |
| `arc9ace_debug` | `0` | Log every bridged shot's projectile data. |

## Mapping

The pack is "mapped" in two layers:

* **Runtime** (`sh_convert.lua`): reads the weapon's installed `eft_ammo_*`
  attachment, its processed muzzle velocity / damage / pellet count, and the
  cartridge description, then produces ACE `BulletData` fields. This means new
  EFT ammo added by the pack keeps working when the pack follows the same
  conventions.
* **Generated table** (`sh_eft_ammo_map.lua`, produced by
  `tools/gen_eft_ammo_map.py`): per-attachment calibre + projectile mass + AP/HP
  class for all 150+ EFT cartridges, verified against the real pack sources.
  This is the authoritative override and the place to fix a specific cartridge.

### How the numbers are derived

| ACE field | Source |
|---|---|
| `Caliber` (cm) | `ATT.Category` → `eft_ammo_<token>` → calibre table (shotguns: pellet diameter from the shell name/description) |
| `ProjMass` (kg) | generated map, else first "N gram"/"N grain" in `ATT.Description`, else shotgun `(shell weight - case)/pellets`, else cartridge ratio |
| `MuzzleVel` (m/s) | `SWEP:GetProcessedValue("PhysBulletMuzzleVelocity") * 0.0254` (includes suppressor/barrel modifiers) |
| `PenArea` | `(π (cal/2)²)^ACE.PenAreaMod` (same as ACE's own SWEPs) |
| `DragCoef` | Calibrated from the cartridge's real G1 BC (ACE quadratic drag, 0.30 BC ≈ 0.00106); realistic velocity retention instead of ACE's shell-drag convention |
| `PenArea` (pen class) | `(π(cal/2)²)^ACE.PenAreaMod / penMul` — FMJ ×1.0, AP ×2.2 (LimitVel 800), APCR ×3.2 (LimitVel 1000), HP/soft ×0.8 |
| `LimitVel` | 750 m/s AP, 400 m/s HP (ACE round conventions) |
| `Ricochet` / `ShovePower` / `KETransfert` | ACE AP round values (53° / 0.2 / 0.3) |
| `Type` | `"AP"` for FMJ/AP/APCR projectiles, `"HP"` for expanding/soft (buckshot, HP/SP/RIP/expanding) |
| player damage | ARC9 `GetDamageAtRange` curve (or the EFT exponential fallback with its 58.3 % floor), hitgroup multipliers, sandbox-multiplier cancellation |

## In-game diagnostics

A player holding an ARC9 weapon can type `!acebridge` in chat to print the
resolved projectile profile (ammo name, calibre, mass, velocity, pellets, RHA
penetration, AP/HP) to their chat and the server journal.

## Testing

```bash
# Pure conversion layer + real ACE ballistics maths (91 assertions)
python3 Arc9AceBridge/tests/run_tests.py

# Fire path + player damage layers with a GMod API stub layer (42 assertions)
python3 Arc9AceBridge/tests/run_fire_tests.py
```

Both harnesses run under LuaJIT, extract `ACE_Kinetic`/`ACE_CalcPenetration`
verbatim from the ACE fork, and use the generated ammunition map.

## Current limitations

* **Grenade/rocket weapons** (`SWEP.ShootEnt`) are not bridged — M32A1, FN40GL,
  M203 UBGL, thrown grenades keep their ARC9 implementation.
* **Client prediction effects**: because the addon is server-only, clients still
  play ARC9's predicted hitscan tracer/impact effects locally while the server
  simulates the ACE bullet. Short-range feel is identical; at long range the
  client tracer can arrive before the real projectile. Shipping the addon as a
  workshop item would let clients suppress/replace prediction later.
* **Ricochet/penetration vs players** uses ARC9's damage model, not ACE's body
  armour abstraction (GMod players have no armour hitboxes beyond `Armor()`).
* A weapon firing while the player changes ammo mid-flight uses the newest
  shot's profile for the still-travelling bullets (sub-second window).
* See [docs/arc9-ace-bridge.md](../docs/arc9-ace-bridge.md) for the full design,
  verification results and the recipe for mapping another ARC9 pack.
