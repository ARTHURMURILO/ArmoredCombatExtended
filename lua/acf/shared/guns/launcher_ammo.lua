-- Launcher ammunition definitions.
--
-- These are data-only gun definitions: the handheld launchers use them as the
-- case/shell reference for ACE's round conversion pipeline (the same one ammo
-- crates use), they are not spawned as ACF guns. Keeping the data here means
-- the AT-4 warhead presets and XM25 rounds stay real converted rounds with
-- correct masses, filler capacities, cone limits, blast radii and penetration.

ACE.DefineGunClass("RL", {
	type = "Gun",
	spread = 0.2,
	name = "Rocket Launcher",
	desc = "Shoulder-fired rockets and their ammunition.",
	muzzleflash = "MO",
	rofmod = 1,
	year = 1942,
	sound = "ace_weapons/multi_sound/at4_multi.mp3",
	noloader = true,
})


ACE.DefineGun("84mmAT4", {
	name = "84mm Rocket Launcher",
	desc = "The 84mm recoilless rocket used by the AT-4 family. The casing leaves room for a useful HEAT or HE warhead without pretending to be a gunpowder gun.",
	model = "models/weapons/w_rocket_launcher.mdl",
	sound = "ace_weapons/multi_sound/at4_multi.mp3",
	gunclass = "RL",
	caliber = 8.4,
	weight = 6.7,
	year = 1987,
	round = {
		maxlength = 42,
		propweight = 0.35,
		minprojratio = 0.5,
	},
} )

-- The XM25 fires 25mm rounds. It is not an autocannon, but its selectable
-- ammunition is deliberately built on the 20mm autocannon's case limits
-- (same maxlength/propweight, heavier 25mm projectile) so the rounds stay
-- small, flat-shooting and restricted instead of turning into mini tank
-- shells. Class AC already exists in lua/acf/shared/guns/autocannon.lua.
ACE.DefineGun("25mmAC", {
	name = "25mm Light Autocannon",
	desc = "A 25mm shell in the same compact case as the 20mm autocannon round: a bit heavier than a 20mm, with the same short range restrictions.",
	model = "models/autocannon/autocannon_20mm.mdl",
	sound = "ace_weapons/multi_sound/20mm_multi.mp3",
	gunclass = "AC",
	nomag = true,
	caliber = 2.5,
	weight = 200,
	year = 1980,
	rofmod = 0.5,
	round = {
		maxlength = 32,
		propweight = 0.13
	},
} )
