# ARC9 → ACE projectile bridge (Tarkov pack, implementation notes)

Design, verification and deployment notes for the server addon in
[`Arc9AceBridge/`](../Arc9AceBridge/README.md). Companion to the earlier
feasibility study [`ace-amr-arc9-investigation.md`](ace-amr-arc9-investigation.md).

## What it does

Every ARC9 shot funnels through `SWEP:DoProjectileAttack`. The bridge patches
that function on the ARC9 base SWEP table (so every weapon that inherits it gets
the wrapper) and, for mapped weapons, spawns an ACE projectile instead of
ARC9's hitscan/phys bullet:

```
ARC9 PrimaryAttack → DoPrimaryAttack (ammo, sounds, recoil, spread, animations)
                   → DoProjectileAttack   ← wrapped by the bridge
                       ├─ ShootEnt weapons (M32A1/FN40GL/M203/throwables)
                       │    → stock ARC9 rockets                     (unchanged)
                       └─ everything else
                            → resolve installed eft_ammo_* attachment
                            → build ACE BulletData
                            → ACE_CreateBullet per pellet
```

ACE then owns drag, gravity, travel time, penetration, ricochet, spalling,
armour plates, vehicles and props. ARC9 still owns everything before the
projectile: ammo count, reload, sounds, animations, recoil, dispersion,
attachments and the customize menu.

## Mapping the EFT pack

The EFT pack exposes real cartridge data on each ammo attachment
(`ARC9EFT.GenerateEFTAttachment`, `sh_eft_shared.lua:538`): initial speed,
ballistic coefficient, damage, penetration power, projectile weight text and
pellet count. The bridge converts that into ACE's model:

| ACE `BulletData` | Source |
|---|---|
| `Caliber` | `ATT.Category` → `eft_ammo_<token>` → token table (`sh_config.lua`); shotshells use the pellet diameter from the shell name |
| `ProjMass` | generated map → first "N gram"/"N grain" in `ATT.Description` → shell `(weight - hull)/Num` → cartridge mass ratio |
| `MuzzleVel` | `swep:GetProcessedValue("PhysBulletMuzzleVelocity", true) * 0.0254` (attachment/suppressor processed, same value ARC9's own physical bullets use) |
| `PenArea` | `(π·(cal/2)²)^ACE.PenAreaMod` — identical to ACE's own SWEP convention |
| `DragCoef` | Calibrated from the cartridge's real G1 BC (ACE quadratic drag; 0.30 BC ≈ 0.00106). The old ACE AP convention `(FrArea/10000)/ProjMass` is ~8× too draggy for bullets |
| `LimitVel` | per penetration class: APCR 1000, AP 800, FMJ 750, soft 400 m/s |
| `PenArea` / class | `(π(cal/2)²)^ACE.PenAreaMod / penMul`; FMJ ×1.0, AP ×2.2, APCR ×3.2, HP/soft ×0.8. Classification by cartridge name/id markers (M995/M993/AP-IZ/sabot/tungsten → APCR; BP/BS/7N/M855A1/AP → AP; FMJ/M80/M33/slug → FMJ; HP/SP/RIP → soft), falling back to the processed ARC9 penetration stat with thresholds |
| `Ricochet`, `ShovePower`, `KETransfert` | ACE AP round values |
| `Type` | `"AP"` for FMJ/AP/APCR, `"HP"` for soft/expanding rounds (client bullet effect compatibility) |
| player damage | ARC9's own `GetDamageAtRange` when the weapon is alive, ARC9 hitgroup multipliers, `arc9_mod_bodydamagecancel` handling, EFT damage fallback with the pack's 58.3 % floor |

The per-ammo table is generated from the unpacked workshop Lua:
[`tools/gen_eft_ammo_map.py`](../tools/gen_eft_ammo_map.py) →
[`sh_eft_ammo_map.lua`](../Arc9AceBridge/lua/arc9_ace_bridge/sh_eft_ammo_map.lua)
(197 attachments) plus a full report in [`eft-ammo-map.md`](eft-ammo-map.md) and
per-entry provenance in [`eft-ammo-map.csv`](eft-ammo-map.csv).

**To map another ARC9 pack**, add its ammo category tokens to
`C.CaliberByToken` / `C.TriviaCaliberToken` in `sh_config.lua` and run the
generator against that pack's unpacked Lua. The runtime resolver already falls
back to the attachment description when the generated table has no entry, so
the minimum viable mapping is a token → bore table.

## Damage model

Two layers, both server-side:

1. **Impact interceptor (primary).** `ACE.RoundTypes.AP.propimpact` and
   `.HP.propimpact` are wrapped. When a bridged bullet hits a player/NPC, the
   bridge applies ARC9-equivalent damage itself and stops the bullet. This is
   independent of ACE's `ACE.Check`/squishy activation, and it uses data stored
   per bullet (`ARC9Damage`, `ARC9KE0`, hitgroup multipliers), so it keeps
   working if the weapon was dropped or the target moved.
2. **Squishy override (fallback).** `ACE.SquishyDamage` is shadowed for
   bridged weapons in case another ACE path reaches it.

Set `arc9ace_player_damage 0` to let pure ACE damage handle players instead
(ACE's model is tuned for cannon shells; rifle rounds barely damage unarmoured
players that way).

## Verification

Headless harnesses (LuaJIT, extracted ACE ballistics code, real pack data):

```bash
python3 Arc9AceBridge/tests/run_tests.py        # 91 assertions: mapping + pen classes + drag + ballistics
python3 Arc9AceBridge/tests/run_fire_tests.py   # 42 assertions: fire path, fallbacks, damage layers
```

Pen class targets (muzzle → 300 m): 7.62x51 M993 21.7→14.8 mm, .338 LM AP 30.4→22.8 mm, 5.56 M995 18.5→9.1 mm, 5.56 M855A1 13.0→7.4 mm, 7.62x39 BP 10.5→6.3 mm, 5.56 FMJ 5.2→3.2 mm. Drag: 5.56 retains 659 m/s at 300 m (old shell-drag behaviour: 67 m/s).

Explorer notes on ARC9 internals are in [`arc9-bridge-api.md`](arc9-bridge-api.md)
(including the stored-SWEP patching gotcha that this implementation fixes and
17 review corrections).

Server startup audit prints the mapping coverage, for example:

```
[ARC9-ACE] patched 1 ARC9 projectile function(s): 189 ARC9 weapon classes registered, 1 own DoProjectileAttack, N existing weapon entities
[ARC9-ACE] ammunition mapping: 197/197 EFT ammo attachments resolved (0 unresolved)
[ARC9-ACE] weapon coverage: NN/NN EFT weapons have a mappable default ammo slot
```

In game, `!acebridge` prints the projectile profile of the held weapon;
`arc9ace_debug 1` logs every bridged shot's calibre/mass/velocity/drag/pen.

## Deployment on this server

* Addon path: `/mnt/data/gmodds/garrysmod/addons/arc9_ace_bridge/`.
* Deploy/replace: `./tools/deploy_arc9_bridge.sh` (packs, uploads, restarts and
  waits for the boot audit; old copies are moved to
  `/mnt/data/gmodds/addon_backups/`, **not** left inside `addons/` because GMod
  mounts every folder there as an addon).
* This box runs GMod in `sv_lan 1` behind a UDP relay
  (`gmod-relay.service`); clients connect to **`<game-server>:27016`**.
* Cold boot runs under FEX-Emu and includes an HTTPS/UDP Steam login. Repeated
  restarts can hit Steam's anonymous game-server login rate limit, after which
  the engine sits forever on `Initializing Steam libraries for secure Internet
  server` (this is an engine/host issue, not the addon — reproduced with the
  addon removed). If it happens: stop `gmod` and `gmod-healthcheck.timer`,
  wait ~30 minutes without any login attempts, then start once.
* Keep `gmod-healthcheck.timer` enabled in normal operation (it restarts the
  unit after 3 missed A2S checks; pause it only during the Steam cooldown
  above).

### In-game test recipe

1. Join `<game-server>:27016`, spawn any EFT gun (e.g. M4A1, AK-74, M700).
2. Change the ammo attachment in the ARC9 customize menu; the HUD ammo name
   changes as usual.
3. Type `!acebridge` in chat — it prints the resolved projectile profile
   (ammo name, calibre, mass, muzzle velocity, pellets, muzzle RHA penetration,
   AP/HP) to chat and the server journal.
4. Fire at a wall/prop: ACE impact effects replace ARC9's instant hitscan;
   bullets now have travel time and drop.
5. Fire at an ACF vehicle/prop with armour: penetration follows ACE's model
   (holes/spall), driven by the EFT calibre/mass/velocity.
6. Fire at a player: by default damage equals the EFT/ARC9 damage curve and
   hitgroups (`arc9ace_player_damage 1`). Set `arc9ace_player_damage 0` to
   compare against pure ACE damage.
7. Optional: `arc9ace_debug 1` logs each shot's calibre/mass/velocity/drag/pen
   to the server journal.
8. Tuning knobs as rcON/admin commands: `arc9ace_drag_mult`,
   `arc9ace_player_damage_mult`, `arc9ace_scope`, `arc9ace_enable`.

## Known limitations

* **Client prediction duplication.** Clients keep running stock ARC9 because
  this is a server-only addon: predicted hitscan tracers/decals/impact sounds
  play alongside the authoritative ACE projectile. Damage is server-side only.
  Removing this needs a client-side stub delivered by Workshop.
* **Grenades/rockets** (`SWEP.ShootEnt`) are intentionally not bridged.
* **Player armour/kevlar** is not modelled; bridged player damage follows
  ARC9's hitgroups (GMod players have no ACE armour plates).
* ARC9's own penetration/AP/bleed/impact-hook systems stop applying to bridged
  shots; ACE replaces them.
* A weapon fired, then re-ammoed mid-flight, uses the newest shot profile for
  the still-travelling bullets (sub-second window).
* ACE's `BulletIndexLimit` (5000 live bullets) applies; full-auto shotgun
  spam with many players could hit it.
