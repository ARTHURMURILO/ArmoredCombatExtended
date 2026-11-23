#!/usr/bin/env python3
"""Generate ARC9ACE.EFTAmmoMap from the extracted ARC9 EFT attachment sources.

The bridge (Arc9AceBridge/lua/arc9_ace_bridge/sh_*.lua) needs, for every EFT
ammunition attachment shipped by the ARC9 EFT pack, the projectile data ACE
does not have by default:

    cal  = projectile diameter in centimetres (per pellet for shotshells)
    mass = projectile mass in kilograms
    type = "AP" or "HP" (ACE projectile class)
    tracer = true for tracer rounds (optional field)

This script reads the *pack data* (not this repository's runtime config), so
the mapping stays regenerable when the pack is updated:

  Arc9AceBridge/lua/arc9_ace_bridge/sh_config.lua   - token -> calibre,
                                                      mass ratios, shell case
                                                      masses (single source of
                                                      truth, parsed here)
  Weapon_pack_extracted/eft_extract/<workshopid>/...  - unpacked pack Lua

and writes, deterministically:

  Arc9AceBridge/lua/arc9_ace_bridge/sh_eft_ammo_map.lua
  docs/eft-ammo-map.md
  docs/eft-ammo-map.csv

Usage:
    python3 tools/gen_eft_ammo_map.py            # write outputs
    python3 tools/gen_eft_ammo_map.py --check    # verify outputs are current

Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import math
import os
import re
import sys

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULT_CONFIG = os.path.join(
    WORKSPACE, "Arc9AceBridge", "lua", "arc9_ace_bridge", "sh_config.lua"
)
DEFAULT_ROOT = os.path.join(WORKSPACE, "Weapon_pack_extracted", "eft_extract")
DEFAULT_LUA_OUT = os.path.join(
    WORKSPACE, "Arc9AceBridge", "lua", "arc9_ace_bridge", "sh_eft_ammo_map.lua"
)
DEFAULT_DOC_OUT = os.path.join(WORKSPACE, "docs", "eft-ammo-map.md")
DEFAULT_CSV_OUT = os.path.join(WORKSPACE, "docs", "eft-ammo-map.csv")

# The workshop id of the EFT SHARED pack.  It wins shortname collisions against
# the weapon-specific packs.
SHARED_PACK = "2917343547"

# Projectile validation bounds required by the bridge (kg).  sh_convert.lua
# clamps to the same interval at runtime.
MASS_MIN_KG = 0.0002
MASS_MAX_KG = 0.12

# Density of lead in kg/cm^3, used for the "is this pellet physically
# plausible?" cap on shotshell heuristics.
LEAD_DENSITY_KG_CM3 = 0.01134

# Attachment block scanning --------------------------------------------------
LOAD_RE = re.compile(r"ARC9\.LoadAttachment\(\s*(\w+)\s*,\s*\"([^\"]+)\"")
PRINT_RE = re.compile(
    r"ATT\.PrintName\s*=\s*(\"(?:[^\"\\]|\\.)*\"|\[\[.*?\]\])", re.S
)
DESC_RE = re.compile(
    r"ATT\.Description\s*=\s*(\"(?:[^\"\\]|\\.)*\"|\[\[.*?\]\])", re.S
)
CAT_RE = re.compile(r"ATT\.Category\s*=\s*\{([^}]*)\}")
CAT_TOKEN_RE = re.compile(r"\"eft_ammo_([%\w]+)\"")
NUM_RE = re.compile(r"ATT\.Num\s*=\s*(-?[0-9.]+)")
GEN_RE = re.compile(r"GenerateEFTAttachment\(")
WEIGHT_RE = re.compile(r"weight\s*=\s*([0-9.]+)")
PEN_RE = re.compile(r"penetrationPower\s*=\s*([0-9.]+)")
DAMAGE_RE = re.compile(r"damage\s*=\s*([0-9.]+)")
# Manual-stat blocks (no GenerateEFTAttachment) store pen power as
# `ATT.Penetration = <penPower> * 2.54/100/0.0254` (the factor is exactly 1).
MANUAL_PEN_RE = re.compile(
    r"ATT\.Penetration\s*=\s*([0-9.]+)(?:\s*\*\s*2\.54/100/0\.0254)?"
)

GRAM_RE = re.compile(r"([0-9]+(?:\.[0-9]+)?)[\s-]*(?:grams?|g)\b")
GRAIN_RE = re.compile(r"([0-9]+(?:\.[0-9]+)?)[\s-]*(?:grains?|gr\.?)\b")
GRAIN_TO_GRAM = 0.06479891

# Buck tray pellet diameter, e.g. "12/70 5.25mm buckshot", "20/70 7.5mm buckshot".
PELLET_MM_RE = re.compile(r"(\d+(?:\.\d+)?)\s*mm")

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def is_commented(text, pos):
    """True when `pos` sits on a single-line Lua comment."""
    line_start = text.rfind("\n", 0, pos) + 1
    return text[line_start:pos].lstrip().startswith("--")


def matches(text, regex, commented=False):
    return [
        m
        for m in regex.finditer(text)
        if commented or not is_commented(text, m.start())
    ]


def first_match(text, regex):
    found = matches(text, regex)
    return found[0] if found else None


def last_match(text, regex):
    found = matches(text, regex)
    return found[-1] if found else None


def unquote_lua_string(raw):
    """Turn a captured Lua string literal into its plain text value."""
    if raw.startswith("[["):
        return raw[2:-2]
    body = raw[1:-1]
    # Only the escapes used by the pack matter here.
    body = body.replace("\\n", "\n").replace("\\t", "\t")
    body = body.replace('\\"', '"').replace("\\\\", "\\")
    return body


def fmt_number(value, decimals):
    """Fixed-point formatting without trailing zeros (deterministic)."""
    text = f"{value:.{decimals}f}"
    text = text.rstrip("0").rstrip(".")
    if text in ("", "-0"):
        text = "0"
    return text


def lead_sphere_kg(diameter_cm):
    """Mass of a solid lead sphere with the given diameter, in kg."""
    if diameter_cm <= 0:
        return 0.0
    radius = diameter_cm / 2.0
    volume_cm3 = (4.0 / 3.0) * math.pi * radius ** 3
    return volume_cm3 * LEAD_DENSITY_KG_CM3


# ---------------------------------------------------------------------------
# sh_config.lua parsing
# ---------------------------------------------------------------------------

class ConfigError(RuntimeError):
    pass


def find_lua_table(text, name):
    """Return the body of `C.<name> = { ... }` from sh_config.lua."""
    pattern = re.compile(r"C\." + re.escape(name) + r"\s*=\s*\{")
    match = pattern.search(text)
    if not match:
        raise ConfigError(f"sh_config.lua: table C.{name} not found")
    start = match.end()
    depth = 1
    i = start
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i]
        i += 1
    raise ConfigError(f"sh_config.lua: unterminated table C.{name}")


def parse_string_keyed_table(text, name):
    body = find_lua_table(text, name)
    values = {}
    for line in body.splitlines():
        line = line.split("--", 1)[0]
        m = re.search(r'\[\s*"([^"]+)"\s*\]\s*=\s*([0-9.]+)', line)
        if m:
            values[m.group(1)] = float(m.group(2))
    if not values:
        raise ConfigError(f"sh_config.lua: C.{name} parsed empty")
    return values


def parse_number_keyed_table(text, name):
    body = find_lua_table(text, name)
    values = {}
    for line in body.splitlines():
        line = line.split("--", 1)[0]
        m = re.search(r"\[\s*([0-9.]+)\s*\]\s*=\s*([0-9.]+)", line)
        if m:
            values[float(m.group(1))] = float(m.group(2))
    if not values:
        raise ConfigError(f"sh_config.lua: C.{name} parsed empty")
    return values


def parse_bool_keyed_table(text, name):
    body = find_lua_table(text, name)
    values = set()
    for line in body.splitlines():
        line = line.split("--", 1)[0]
        m = re.search(r"\[\s*([0-9.]+)\s*\]\s*=\s*true", line)
        if m:
            values.add(float(m.group(1)))
    if not values:
        raise ConfigError(f"sh_config.lua: C.{name} parsed empty")
    return values


def parse_config(path):
    text = read_text(path)
    config = {
        "caliber_by_token": parse_string_keyed_table(text, "CaliberByToken"),
        "mass_ratio_by_token": parse_string_keyed_table(text, "MassRatioByToken"),
        "shell_case_mass": parse_number_keyed_table(text, "ShellCaseMass"),
        "shotgun_bores": parse_bool_keyed_table(text, "ShotgunBores"),
    }
    fallback = re.search(r"FallbackMassRatio\s*=\s*([0-9.]+)", text)
    if not fallback:
        raise ConfigError("sh_config.lua: C.Defaults.FallbackMassRatio not found")
    config["fallback_mass_ratio"] = float(fallback.group(1))

    # Fail loudly when the config changes shape instead of silently emitting
    # wrong data.  These are tokens the EFT pack definitely uses.
    required = ["556", "545", "76239", "762x51", "762x54r", "338", "9x19",
                "12x70", "20x70", "23x75", "40x46", "50bmg", "556bb"]
    missing = [t for t in required if t not in config["caliber_by_token"]]
    if missing:
        raise ConfigError(
            "sh_config.lua: C.CaliberByToken is missing expected tokens: "
            + ", ".join(missing)
        )
    if len(config["caliber_by_token"]) < 25:
        raise ConfigError("sh_config.lua: C.CaliberByToken looks truncated")
    return config


# ---------------------------------------------------------------------------
# Attachment extraction
# ---------------------------------------------------------------------------

def brace_body(text, open_pos):
    """Return the text of the Lua table starting at/after `open_pos`."""
    start = text.find("{", open_pos)
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def normalize_token(raw_token):
    """Map pack shorthand category tokens onto sh_config.lua tokens.

    The pack uses a few suffixed category tokens for item-slot compatibility;
    they still describe the same cartridge.
    """
    token = raw_token
    for suffix in ("_saiga12only", "_nonubgl"):
        if token.endswith(suffix):
            token = token[: -len(suffix)]
    return token


def collect_attachments(root):
    """Parse every EFT ammo attachment block under the extracted pack tree."""
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for filename in sorted(filenames):
            if filename.endswith(".lua"):
                files.append(os.path.join(dirpath, filename))
    files.sort()

    entries = []
    for path in files:
        text = read_text(path)
        if "eft_ammo_" not in text or "ARC9.LoadAttachment" not in text:
            continue
        rel = os.path.relpath(path, root)
        pack = rel.split(os.sep)[0]

        load_matches = matches(text, LOAD_RE)
        for index, load_match in enumerate(load_matches):
            shortname = load_match.group(2)
            if not shortname.startswith("eft_ammo"):
                continue
            block_start = load_matches[index - 1].end() if index else 0
            block = text[block_start:load_match.start()]

            cat_match = last_match(block, CAT_RE)
            if not cat_match:
                continue
            raw_tokens = CAT_TOKEN_RE.findall(cat_match.group(1))
            if not raw_tokens:
                continue

            print_match = first_match(block, PRINT_RE)
            desc_match = first_match(block, DESC_RE)
            printname = unquote_lua_string(print_match.group(1)) if print_match else ""
            description = unquote_lua_string(desc_match.group(1)) if desc_match else ""

            num_match = last_match(block, NUM_RE)
            num = float(num_match.group(1)) if num_match else None
            if num is not None and num <= 0:
                num = 0.0

            gen_args = None
            gen_match = None
            for candidate in matches(block, GEN_RE):
                gen_match = candidate
            if gen_match is not None:
                gen_args = brace_body(block, gen_match.end())

            weight = None
            pen_power = None
            damage = None
            if gen_args:
                m = WEIGHT_RE.search(gen_args)
                if m:
                    weight = float(m.group(1))
                m = PEN_RE.search(gen_args)
                if m:
                    pen_power = float(m.group(1))
                m = DAMAGE_RE.search(gen_args)
                if m:
                    damage = float(m.group(1))
            if pen_power is None:
                m = first_match(block, MANUAL_PEN_RE)
                if m:
                    pen_power = float(m.group(1))

            entries.append(
                {
                    "shortname": shortname,
                    "pack": pack,
                    "file": rel.replace(os.sep, "/"),
                    "tokens": [normalize_token(t) for t in raw_tokens],
                    "printname": printname,
                    "description": description,
                    "num": num,
                    "weight_kg": weight,
                    "pen_power": pen_power,
                    "damage": damage,
                    "has_generate": gen_args is not None,
                }
            )
    return entries


# ---------------------------------------------------------------------------
# Explicit overrides
# ---------------------------------------------------------------------------

# Calibre overrides that cannot be derived from a category token.
# `(cal_cm, note)`.
CAL_OVERRIDES = {
    # Shotshell pellet diameters are in the attachment name (handled
    # automatically for "X.YYmm buckshot"); the entries below need data that
    # the pack name/description does not carry.
    "eft_ammo_23x75_sh10": (
        0.85,
        "8.5 mm Shrapnel pellets (EFT data); name only says 23x75mm",
    ),
    "eft_ammo_23x75_sh25": (
        0.85,
        "8.5 mm Shrapnel pellets (EFT data); name only says 23x75mm",
    ),
    "eft_ammo_12x70_flechette": (0.25, "flechette dart, ~2.5 mm shaft"),
    "eft_ammo_20x70_flechette": (0.25, "flechette dart, ~2.5 mm shaft"),
    "eft_ammo_20x70_flechplus": (0.25, "flechette dart, ~2.5 mm shaft"),
    "eft_ammo_12x70_pir": (0.25, "steel tacks, ~2.5 mm"),
    # A .50 BMG bullet loaded into a 12/70 hull: sub-calibre projectile.
    "eft_ammo_12x70_50bmg": (1.27, "shortened .50 BMG bullet (12.7 mm)"),
    "eft_ammo_12x70_mixed_50bmg_p3": (1.27, "alternates .50 BMG and Poleva-3 slugs"),
    # 40x46 M576 is a multi-projectile shotshell in a grenade-launcher case.
    "eft_ammo_40x46_m576": (0.70, "M576 24-grain buckshot pellet (EFT data: 7 mm)"),
    "eft_ammo_40x46_m576_nonubgl": (0.70, "M576 24-grain buckshot pellet (EFT data: 7 mm)"),
    # Airsoft BB => 6 mm, despite the 5.56 family category.
    "eft_ammo_556_bb": (0.60, "Airsoft 6 mm BB, name says 6mm"),
}

# Mass overrides in kg for entries whose block has neither a description mass,
# a powder-grain mass, nor a cartridge weight.
# `(mass_kg, note)`.
MASS_OVERRIDES = {
    # 40x46 rounds: the pack generated-stat call is commented out and the item
    # weight is only present as a comment.  EFT item weights: 0.23 kg for the
    # HE/HEDP rounds, 0.12 kg for M576.  The bridge caps projectile mass at
    # 0.12 kg, so the HE values clamp to that ceiling.
    "eft_ammo_40x46_m381": (0.23, "EFT weight comment 0.23 kg"),
    "eft_ammo_40x46_m386": (0.23, "EFT weight comment 0.23 kg"),
    "eft_ammo_40x46_m406": (0.23, "EFT weight comment 0.23 kg"),
    "eft_ammo_40x46_m433": (0.23, "EFT weight comment 0.23 kg"),
    "eft_ammo_40x46_m441": (0.23, "EFT weight comment 0.23 kg"),
    "eft_ammo_40x46_m576": (0.00156, "24-grain (1.56 g) pellet; EFT item description"),
    "eft_ammo_40x46_m576_nonubgl": (0.00156, "24-grain (1.56 g) pellet; EFT item description"),
    # Flechette loads: the shell formula assumes the shot load is most of the
    # shell weight, which is wildly wrong for very light darts (EFT data:
    # 12/70 flechette dart = 0.47 g).
    "eft_ammo_12x70_flechette": (0.00047, "0.47 g flechette dart (EFT data)"),
    "eft_ammo_20x70_flechette": (0.00047, "0.47 g flechette dart (EFT data estimate)"),
    "eft_ammo_20x70_flechplus": (0.00047, "0.47 g flechette dart (EFT data estimate)"),
    "eft_ammo_12x70_pir": (0.00046, "~2.5 mm x 12 mm steel tack estimate"),
    # Removed-from-game 20/70 event rounds: no weight and no generated stats.
    "eft_ammo_20x70_elephant": (0.018, "20 ga hunting slug estimate (18 g)"),
    "eft_ammo_20x70_explosive": (0.018, "20 ga slug with explosive filler estimate (18 g)"),
    # Mixed shell alternates a .50 BMG slug and a Poleva-3 slug every shot;
    # average of the two single-shell shell-formula values.
    "eft_ammo_12x70_mixed_50bmg_p3": (0.045, "average of the two 12/70 slug shell formulas"),
    # Flash-bang cartridge: pyrotechnic payload, no projectile mass in source.
    "eft_ammo_23x75_zvezda": (0.02, "flash-bang payload estimate (20 g)"),
}

# Entries whose attachment is a multi-projectile ("pellet") load but whose
# category token is not a shotgun bore, so the automatic pellet detection
# cannot see it.
EXTRA_PELLET_SHORTNAMES = {
    "eft_ammo_40x46_m576",
    "eft_ammo_40x46_m576_nonubgl",
}

# Multi-projectile counts for entries that do not set ATT.Num.
NUM_OVERRIDES = {
    "eft_ammo_40x46_m576": 5,  # ATT.NumUBGL = 5
}

# Rounds whose names/description hint at expansion but that are actually AP
# (the phrase is "controlled fragmenting projectile", Russian AP design
# wording).  These are not hollow/soft points; classifying them HP would make
# ACE drop their penetration to the HP LimitVel.
FRAGMENT_AP_GUARD = (
    "armor-piercing",
    "armour-piercing",
    "armor piercing",
    "armour piercing",
)

TYPE_OVERRIDES = {}


# ---------------------------------------------------------------------------
# Derivation
# ---------------------------------------------------------------------------

HP_SUBSTRINGS = (
    "hollow",
    "soft point",
    "expansive",
    "warmageddon",
    "quakemaker",
    "predator",
    "devastator",
    "fragment",
    "segmented",
)

# Word-ish HP/SP/RIP markers.  The negative lookarounds stop "SP-6", "SPP",
# "SP13" etc. (Russian "special cartridge" designations, not soft points) from
# being mistaken for soft-point rounds.
HP_WORD_RE = re.compile(r"(?<![a-z])(hp|sp|rip)(?![a-z0-9-])")


def lower_blob(entry):
    return (entry["printname"] + " " + entry["description"]).lower()


def hp_reason(entry):
    """Return a short reason string if the entry looks expanding, else None."""
    blob = lower_blob(entry)
    reasons = []
    for token in HP_SUBSTRINGS:
        if token in blob:
            reasons.append(token)
    word = HP_WORD_RE.search(blob)
    if word:
        reasons.append(word.group(1))
    # "controlled fragmenting projectile" is AP design wording, not expansion.
    if reasons == ["fragment"] and any(g in blob for g in FRAGMENT_AP_GUARD):
        reasons = []
    return ", ".join(reasons) if reasons else None


def shot_slug_ap(entry, blob):
    """True when a shotshell is a slug/sabot/flechette/AP load (=> AP)."""
    markers = ("slug", "sabot", "flechette", "flechet", "ap-20", "armor-piercing",
               "armour-piercing", "armor piercing", "penetrator")
    if any(marker in blob for marker in markers):
        return True
    sn = entry["shortname"].lower()
    return any(marker in sn for marker in ("slug", "sabot", "flechette", "flech"))


def resolve_entry(entry, config):
    """Compute cal/mass/type for one parsed attachment."""
    notes = []
    blob = lower_blob(entry)
    shortname = entry["shortname"]

    # ---- category token ---------------------------------------------------
    token = entry["tokens"][0]
    if token not in config["caliber_by_token"]:
        raise SystemExit(
            f"{shortname}: unknown ammo token {token!r} "
            f"(category tokens: {entry['tokens']})"
        )
    bore_cm = config["caliber_by_token"][token]
    is_shotgun_bore = bore_cm in config["shotgun_bores"]

    # ---- projectile count -------------------------------------------------
    num = entry["num"]
    if num is None:
        num = float(NUM_OVERRIDES.get(shortname, 1))
    if num < 1:
        num = 1.0

    # ---- calibre ----------------------------------------------------------
    cal = bore_cm
    cal_note = "category token"
    if shortname in CAL_OVERRIDES:
        cal, cal_note = CAL_OVERRIDES[shortname]
    elif is_shotgun_bore and "buckshot" in blob:
        pellet = PELLET_MM_RE.search(entry["printname"])
        if pellet:
            cal = float(pellet.group(1)) / 10.0
            cal_note = "pellet diameter from name"

    # ---- projectile mass --------------------------------------------------
    mass = None
    mass_source = None
    mass_detail = None
    shell_raw_g = None
    mass_override_note = None

    gram = GRAM_RE.search(entry["description"])
    grain = GRAIN_RE.search(entry["description"])

    if gram is not None:
        grams = float(gram.group(1))
        mass = grams / 1000.0
        mass_source = "description"
        mass_detail = f"{fmt_number(grams, 4)} g from description"
    elif grain is not None:
        grains = float(grain.group(1))
        mass = grains * GRAIN_TO_GRAM / 1000.0
        mass_source = "grain"
        mass_detail = (
            f"{fmt_number(grains, 4)} grain => {fmt_number(grains * GRAIN_TO_GRAM, 4)} g"
        )
    elif shortname in MASS_OVERRIDES:
        node, mass_override_note = MASS_OVERRIDES[shortname]
        mass = node
        mass_source = "override"
        mass_detail = mass_override_note
    elif is_shotgun_bore and entry["weight_kg"] is not None:
        case = config["shell_case_mass"].get(bore_cm)
        if case is None:
            raise SystemExit(f"{shortname}: no shell case mass for {bore_cm} cm")
        projectile_total = max(entry["weight_kg"] - case, 0.0)
        raw = projectile_total / num
        shell_raw_g = raw * 1000.0
        mass = raw
        mass_source = "shell"
        mass_detail = (
            f"({fmt_number(entry['weight_kg'], 4)} kg shell - "
            f"{fmt_number(case, 4)} kg case) / {fmt_number(num, 0)} = "
            f"{fmt_number(shell_raw_g, 3)} g"
        )

    if mass is None:
        weight = entry["weight_kg"]
        if weight is None:
            raise SystemExit(
                f"{shortname}: no mass source (no description mass, grain, "
                f"weight or override)"
            )
        ratio = config["mass_ratio_by_token"].get(
            token, config["fallback_mass_ratio"]
        )
        mass = weight * ratio
        mass_source = "ratio"
        mass_detail = (
            f"{fmt_number(weight, 4)} kg cartridge * {fmt_number(ratio, 3)} ratio = "
            f"{fmt_number(mass * 1000.0, 3)} g"
        )

    # Shotshell pellet heuristic: EFT cartridge weights are not consistent with
    # the shot load (they include a lot of non-projectile mass), so cap the
    # per-pellet result at the mass of a solid lead sphere of that calibre.
    # Without this cap, 5.25 mm buckshot would come out at ~4.9 g/pellet.
    is_pellet = (
        (is_shotgun_bore and num > 1 and not shot_slug_ap(entry, blob))
        or shortname in EXTRA_PELLET_SHORTNAMES
    )
    if mass_source == "shell" and is_pellet:
        cap_kg = lead_sphere_kg(cal)
        if mass > cap_kg:
            mass = cap_kg
            mass_detail += (
                f"; capped to lead-sphere mass {fmt_number(cap_kg * 1000.0, 3)} g"
            )

    # Global clamp (same interval the bridge enforces) and quantise to the
    # 6 dp precision the generated Lua map exports, so every artefact agrees.
    clamped = min(max(mass, MASS_MIN_KG), MASS_MAX_KG)
    if clamped != mass:
        mass_detail += f"; clamped to {fmt_number(clamped, 6)} kg"
    mass = float(fmt_number(clamped, 6))

    # ---- ACE projectile class --------------------------------------------
    if shortname in TYPE_OVERRIDES:
        ptype = TYPE_OVERRIDES[shortname]
        type_reason = "explicit override"
    else:
        reason = hp_reason(entry)
        if reason:
            ptype = "HP"
            type_reason = f"name/description: {reason}"
        elif entry["pen_power"] is not None and entry["pen_power"] <= 10:
            ptype = "HP"
            type_reason = f"penetrationPower {entry['pen_power']:g} <= 10"
        elif is_pellet:
            if shot_slug_ap(entry, blob):
                ptype = "AP"
                type_reason = "shotshell slug/sabot/flechette"
            else:
                ptype = "HP"
                type_reason = "shotshell pellet load"
        else:
            ptype = "AP"
            type_reason = "default AP (FMJ/ball/core round)"

    # ---- tracer -----------------------------------------------------------
    tracer = "tracer" in blob

    return {
        "shortname": shortname,
        "pack": entry["pack"],
        "file": entry["file"],
        "token": token,
        "printname": entry["printname"].replace("\n", " ").strip(),
        "cal_cm": cal,
        "cal_note": cal_note,
        "mass_kg": mass,
        "mass_source": mass_source,
        "mass_detail": mass_detail,
        "shell_raw_g": shell_raw_g,
        "num": num,
        "type": ptype,
        "type_reason": type_reason,
        "tracer": tracer,
        "weight_kg": entry["weight_kg"],
        "pen_power": entry["pen_power"],
        "damage": entry["damage"],
        "has_generate": entry["has_generate"],
    }


# ---------------------------------------------------------------------------
# Rendering: Lua map
# ---------------------------------------------------------------------------

LUA_HEADER = """\
-- ARC9 Escape From Tarkov pack: ammo attachment -> ACE projectile mapping.
--
-- THIS FILE IS GENERATED by tools/gen_eft_ammo_map.py. Do not edit it by
-- hand; re-run the generator instead. The input is the unpacked workshop Lua
-- plus the token/calibre tables in sh_config.lua.
--
-- Key   = ARC9 attachment shortname (ARC9.LoadAttachment name)
-- Value = {
--   cal    = projectile diameter in centimetres (per pellet for shotshells),
--   mass   = projectile mass in kilograms,
--   type   = "AP" or "HP" (ACE projectile class),
--   tracer = true for tracer rounds (optional).
-- }
--
-- Generated from @ENTRY_COUNT@ EFT ammo attachments; see docs/eft-ammo-map.md
-- for the mass-source breakdown, calibre table and heuristic entries.

ARC9ACE = ARC9ACE or {}
ARC9ACE.EFTAmmoMap = {
"""


def render_lua(resolved):
    lines = [LUA_HEADER.replace("@ENTRY_COUNT@", str(len(resolved)))]
    for entry in sorted(resolved, key=lambda e: e["shortname"]):
        fields = [
            f"cal = {fmt_number(entry['cal_cm'], 4)}",
            f"mass = {fmt_number(entry['mass_kg'], 6)}",
            f'type = "{entry["type"]}"',
        ]
        if entry["tracer"]:
            fields.append("tracer = true")
        lines.append(
            "\t[\"{sn}\"] = {{ {fields} }},\n".format(
                sn=entry["shortname"], fields=", ".join(fields)
            )
        )
    lines.append("}\n")
    return "".join(lines)


# ---------------------------------------------------------------------------
# Rendering: CSV
# ---------------------------------------------------------------------------

CSV_COLUMNS = [
    "shortname",
    "token",
    "cal_cm",
    "mass_kg",
    "mass_g",
    "mass_source",
    "mass_detail",
    "type",
    "tracer",
    "num",
    "pen_power",
    "eft_damage",
    "printname",
    "pack",
    "file",
]


def render_csv(resolved):
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(CSV_COLUMNS)
    for entry in sorted(resolved, key=lambda e: e["shortname"]):
        writer.writerow(
            [
                entry["shortname"],
                entry["token"],
                fmt_number(entry["cal_cm"], 4),
                fmt_number(entry["mass_kg"], 6),
                fmt_number(entry["mass_kg"] * 1000.0, 4),
                entry["mass_source"],
                entry["mass_detail"],
                entry["type"],
                "true" if entry["tracer"] else "false",
                fmt_number(entry["num"], 0),
                "" if entry["pen_power"] is None else fmt_number(entry["pen_power"], 0),
                "" if entry["damage"] is None else fmt_number(entry["damage"], 0),
                entry["printname"],
                entry["pack"],
                entry["file"],
            ]
        )
    return buffer.getvalue()


# ---------------------------------------------------------------------------
# Rendering: docs
# ---------------------------------------------------------------------------

def render_docs(resolved, config, lua_sha256, stats):
    out = []
    w = out.append

    w("# EFT ammo -> ACE projectile map\n")
    w(
        "Generated by [`tools/gen_eft_ammo_map.py`](../tools/gen_eft_ammo_map.py) "
        "from the unpacked ARC9 EFT workshop content and "
        "[`sh_config.lua`](../Arc9AceBridge/lua/arc9_ace_bridge/sh_config.lua). "
        "Do not hand-edit the generated Lua or this document; regenerate instead.\n"
    )
    w("Files:\n")
    w(
        "- [`Arc9AceBridge/lua/arc9_ace_bridge/sh_eft_ammo_map.lua`]"
        "(../Arc9AceBridge/lua/arc9_ace_bridge/sh_eft_ammo_map.lua) - "
        "`ARC9ACE.EFTAmmoMap` consumed by the bridge.\n"
        "- [`docs/eft-ammo-map.csv`](eft-ammo-map.csv) - same data with provenance "
        "columns (mass source/detail, pack, source file).\n"
        "- [`docs/eft-ammo-map.md`](eft-ammo-map.md) - this document.\n"
    )
    w("## Regenerating\n")
    w("```sh\npython3 tools/gen_eft_ammo_map.py\n```\n")
    w(
        "The generator only uses the Python standard library, reads the pack "
        "sources in sorted order and writes the three files above. Output is "
        "deterministic: re-running it produces byte-identical files. "
        "`--check` verifies the checked-in outputs are current:\n"
    )
    w("```sh\npython3 tools/gen_eft_ammo_map.py --check\n```\n")

    w("## How the generator works\n")
    w(
        "1. **Config**: parses `sh_config.lua` for `C.CaliberByToken`, "
        "`C.MassRatioByToken`, `C.ShellCaseMass`, `C.ShotgunBores` and "
        "`C.Defaults.FallbackMassRatio`. The tables are the single source of "
        "truth; the generator fails if they are missing or truncated.\n"
        "2. **Scan**: walks `Weapon_pack_extracted/eft_extract/<workshopid>/lua/...` "
        "in sorted order and splits each `.lua` file on "
        "`ARC9.LoadAttachment(ATT, \"eft_ammo_...\")`, keeping blocks whose "
        "`ATT.Category` contains an `eft_ammo_*` token. This catches the "
        "`attachments_bulk/eft_ammo_*_bulk.lua` files plus the ammo defined "
        "inline in weapon-pack bulk files (shotguns, pistols, snipers, "
        "SMGs, ARs, explosives).\n"
        "3. **Shortnames**: deduplicated by shortname; a collision is resolved "
        "in favour of the EFT SHARED pack (workshop id 2917343547).\n"
        "4. **Calibre**: explicit overrides for shotshell pellets and other "
        "sub-calibre loads; otherwise the `eft_ammo_<token>` category token maps "
        "through `CaliberByToken` (with `_saiga12only` / `_nonubgl` suffix "
        "normalisation). Buckshot pellet diameter is parsed from the attachment "
        "name (e.g. `12/70 5.25mm buckshot` -> 0.525 cm); slugs keep the bore "
        "calibre.\n"
        "5. **Mass**, in order of confidence: first `<n> gram` in "
        "`ATT.Description`; else `<n> grain` / `<n>gr.` (grains x 0.06479891); "
        "else an explicit override for the few blocks with no data at all; else "
        "for shotshells `(weight - C.ShellCaseMass[bore]) / ATT.Num`; else `weight * C.MassRatioByToken[token]` (falling back to "
        "`C.Defaults.FallbackMassRatio`). Multi-projectile blocks without "
        "`ATT.Num` use the documented override count (40x46 M576: `NumUBGL` = 5). "
        "Everything is clamped to the bridge's "
        "projectile-mass interval (0.0002 - 0.12 kg).\n"
        "6. **Pellet sanity cap**: EFT cartridge weights for shotshells include "
        "much more than the shot load (the 5.25 mm shell is listed at 44 g while "
        "its 8 pellets weigh ~7 g total), so the raw shell formula over-estimates "
        "small pellets several-fold. Heuristic **pellet** masses are therefore "
        "capped at the mass of a solid lead sphere of the derived pellet "
        "diameter; the uncapped formula value is still recorded in the CSV and "
        "listed below for review. Slug loads keep the formula value. Flechette "
        "and steel-tack loads use explicit per-dart masses instead.\n"
        "7. **Type** (`AP`/`HP`): `HP` when the name/description says "
        "hollow (point), HP, soft point, SP, RIP, expansive, Warmageddon, "
        "QuakeMaker, Predator, Devastator, fragment or segmented; or when "
        "penetration power <= 10; or for non-slug shotshell pellets. Two "
        "narrow guards applied: \"SP-6\"/\"SPP\"/\"SP13\" (Russian *special "
        "cartridge* designations, not soft points) are not matched as SP, and "
        "\"controlled fragmenting projectile\" paired with \"armor-piercing\" "
        "(Russian AP design wording) is not treated as expansion. Otherwise AP.\n"
        "8. **Validation**: every entry must have a known token, cal > 0, "
        "0.0002 <= mass <= 0.12 kg and type AP/HP; the total entry count must "
        "be 150 or more. The generator exits non-zero on any violation.\n"
    )

    counts = stats["mass_sources"]
    types = stats["types"]
    w("## Counts\n")
    w(f"- **{stats['total']} ammo attachments** in the map, sourced from "
      f"{stats['packs']} of the 10 extracted workshop packs "
      f"(the ARC9 base and MG packs ship weapons only and use the shared ammo).\n")
    w(f"- Mass source: description {counts['description']}, grain "
      f"{counts['grain']}, shell heuristic {counts['shell']}, cartridge ratio "
      f"{counts['ratio']}, explicit override {counts['override']}.\n")
    w(f"- Projectile type: **AP {types['AP']}**, **HP {types['HP']}**.\n")
    w(f"- Tracer rounds: {stats['tracer']}.\n")
    w(f"- Shotshell entries: {stats['shotgun']} "
      f"({stats['pellets']} pellet loads).\n")
    w(f"- Shortname collisions resolved: {stats['duplicates']}. "
      f"Unknown tokens: {stats['unknown_tokens']}.\n")
    w(f"- `sh_eft_ammo_map.lua` SHA-256: `{lua_sha256}`.\n")

    w("## Category token -> calibre used\n")
    w(
        "Calibre for single-projectile rounds comes from "
        "`C.CaliberByToken` in `sh_config.lua`. Shotshell pelleta are "
        "overridden per attachment as described above.\n"
    )
    w("| token | bore cal (cm) | attachments | category used by |")
    w("| --- | ---: | ---: | --- |")
    tokens = sorted(
        {e["token"] for e in resolved},
        key=lambda t: (config["caliber_by_token"][t], t),
    )
    for token in tokens:
        count = sum(1 for e in resolved if e["token"] == token)
        w(
            f"| `{token}` | {fmt_number(config['caliber_by_token'][token], 4)} | "
            f"{count} | `eft_ammo_{token}` |"
        )
    w("")

    shell_overrides = [
        e for e in resolved if e["cal_note"] not in ("category token",)
    ]
    if shell_overrides:
        w("Calibre resolutions beyond the plain category token (shotshell pellets, flechettes, sub-calibre loads):\n")
        w("| shortname | cal (cm) | note |")
        w("| --- | ---: | --- |")
        for entry in sorted(shell_overrides, key=lambda e: e["shortname"]):
            w(f"| `{entry['shortname']}` | {fmt_number(entry['cal_cm'], 4)} | "
              f"{entry['cal_note']} |")
        w("")

    w("## Heuristic and override masses (sanity-check these)\n")
    w(
        "Entries whose mass did not come from a description gram/grain value. "
        "`raw` is the value the shell formula produced before the pellet "
        "physical cap and the global 0.12 kg ceiling; `applied` is what the map "
        "actually exports.\n"
    )
    heuristic = [
        e
        for e in resolved
        if e["mass_source"] != "description" and e["mass_source"] != "grain"
    ]
    w("| shortname | token | source | raw (g) | applied (g) | cal (cm) | detail |")
    w("| --- | --- | --- | ---: | ---: | ---: | --- |")
    for entry in sorted(heuristic, key=lambda e: e["shortname"]):
        raw = (
            fmt_number(entry["shell_raw_g"], 3)
            if entry["shell_raw_g"] is not None
            else "-"
        )
        w(
            f"| `{entry['shortname']}` | `{entry['token']}` | "
            f"{entry['mass_source']} | {raw} | "
            f"{fmt_number(entry['mass_kg'] * 1000.0, 4)} | "
            f"{fmt_number(entry['cal_cm'], 4)} | {entry['mass_detail']} |"
        )
    w("")

    w("## Projectile type rules and counts\n")
    w(f"- AP: {types['AP']} entries; HP: {types['HP']} entries.\n")
    w(
        "HP is set for expanding/soft/frangible designs, low-penetration "
        "rounds (shotshell pellets, weak pistol loads) and the 40x46 HE/HEDP "
        "grenades (their generated stats are commented out in the pack; they "
        "are explosive fragmentation rounds). AP is everything else, including "
        "shotshell slugs/sabots/flechettes and ordinary rifle/pistol FMJ. "
        "This deliberately does not use `penetrationPower < 25` as the HP test: "
        "ordinary 5.56/5.45 FMJ sits in the low 20s and is not a hollow point.\n"
    )

    w("## Example rows\n")
    examples = [
        "eft_ammo_556_m855",
        "eft_ammo_545_bp",
        "eft_ammo_76239_ps",
        "eft_ammo_762x51_m80",
        "eft_ammo_338_ap",
        "eft_ammo_9x19_pst_gzh",
        "eft_ammo_12x70_magnum",
        "eft_ammo_12x70_slug",
        "eft_ammo_40x46_m381",
        "eft_ammo_50bmg_m33",
    ]
    by_name = {entry["shortname"]: entry for entry in resolved}
    w("| shortname | cal (cm) | mass (g) | type | tracer | mass source |")
    w("| --- | ---: | ---: | --- | --- | --- |")
    for shortname in examples:
        entry = by_name.get(shortname)
        if not entry:
            w(f"| `{shortname}` | _missing_ |  |  |  |  |")
            continue
        w(
            f"| `{entry['shortname']}` | {fmt_number(entry['cal_cm'], 4)} | "
            f"{fmt_number(entry['mass_kg'] * 1000.0, 3)} | {entry['type']} | "
            f"{'yes' if entry['tracer'] else 'no'} | {entry['mass_source']} |"
        )
    w("")
    w("Raw Lua for the same rows:\n")
    w("```lua")
    for shortname in examples:
        entry = by_name.get(shortname)
        if not entry:
            continue
        fields = [
            f"cal = {fmt_number(entry['cal_cm'], 4)}",
            f"mass = {fmt_number(entry['mass_kg'], 6)}",
            f'type = "{entry["type"]}"',
        ]
        if entry["tracer"]:
            fields.append("tracer = true")
        w(f'\t["{shortname}"] = {{ {", ".join(fields)} }},')
    w("```\n")

    w("## Validation and deterministic regeneration\n")
    w("Generator validation (all enforced, non-zero exit on failure):\n")
    w(f"- {stats['total']} entries (required: 150+)\n")
    w("- every entry has a known `eft_ammo_<token>` category token\n")
    w("- every entry has `0 < cal` and `0.0002 <= mass <= 0.12` kg\n")
    w("- every entry has `type` AP or HP and a non-empty shortname\n")
    w("- output sorted by shortname, numbers formatted with a fixed routine\n")
    w("")
    w(
        "Deterministic re-run check: `python3 tools/gen_eft_ammo_map.py` twice; "
        "the `.lua`, `.md` and `.csv` outputs are byte-identical "
        "(sha256 of the Lua map is recorded above). "
        "`python3 tools/gen_eft_ammo_map.py --check` exits 0 when the checked-in "
        "files match a fresh generation.\n"
    )
    w("LuaJIT sanity check (the map file only assigns tables, so it can be "
      "loaded outside GMod):\n")
    w("```sh")
    w(
        "luajit -e 'dofile(\"Arc9AceBridge/lua/arc9_ace_bridge/sh_config.lua\"); "
        "dofile(\"Arc9AceBridge/lua/arc9_ace_bridge/sh_eft_ammo_map.lua\"); "
        'local n=0 for _ in pairs(ARC9ACE.EFTAmmoMap) do n=n+1 end '
        "print(\"entries\", n)'"
    )
    w("```")
    w(f"Expected output: `entries {stats['total']}`.\n")

    w("## Known caveats\n")
    w(
        "- The pack's shotshell weights are not physically consistent with the "
        "pellet loads; the shell formula can only be a starting point. Pellet "
        "masses are capped at the lead-sphere mass for the derived diameter and "
        "every heuristic value is listed above for review. Slugs keep the raw "
        "formula result (a 12/70 slug is exported around 45 g).\n"
        "- 40x46 rounds have no generated stats in the pack (`table.Merge` is "
        "commented out), so their masses are explicit overrides: EFT lists the "
        "HE/HEDP rounds at 0.23 kg, which the bridge clamps to its 0.12 kg "
        "projectile-mass ceiling; M576 uses its documented 24-grain pellet.\n"
        "- `eft_ammo_556_bb` is the Airsoft 6 mm BB attachment. It exists in the "
        "pack but is unused in Tarkov; it maps to 0.6 cm / 0.2 g.\n"
        "- The 20/70 \"Elephant killer\", \"explosive\" slug and \"Flechetta "
        "Plus\" rounds are removed-from-game event items with no generated "
        "stats; their masses are documented estimates (20 ga slug ~18 g, "
        "flechette dart 0.47 g).\n"
        "- Calibre/mass cross-checks against EFT item data were used for the "
        "23x75 Shrapnel pellets (8.5 mm), 12/70 flechette darts (2 mm / 0.47 g) "
        "and 40x46 M576 pellets (7 mm / 24 grain). They are hard-coded in the "
        "generator's override tables with comments.\n"
        "- The bridge clamps projectile mass at 0.12 kg; the two 40x46 HE classes "
        "are therefore not physically accurate in-game.\n"
    )
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def build(entries, config):
    """Resolve, deduplicate and validate all attachments. Returns (resolved, stats)."""
    # Deduplicate by shortname; SHARED pack wins.
    grouped = {}
    for entry in entries:
        grouped.setdefault(entry["shortname"], []).append(entry)

    duplicates = 0
    resolved = []
    for shortname in sorted(grouped):
        group = grouped[shortname]
        if len(group) > 1:
            duplicates += len(group) - 1
            group = sorted(
                group,
                key=lambda e: (0 if e["pack"] == SHARED_PACK else 1, e["file"]),
            )
        selected = group[0]
        resolved.append(resolve_entry(selected, config))

    # Validation.
    errors = []
    for entry in resolved:
        sn = entry["shortname"]
        if not sn.startswith("eft_ammo_"):
            errors.append(f"{sn}: unexpected shortname prefix")
        if entry["token"] not in config["caliber_by_token"]:
            errors.append(f"{sn}: unknown token {entry['token']}")
        if not (entry["cal_cm"] > 0.0):
            errors.append(f"{sn}: bad calibre {entry['cal_cm']}")
        if not (MASS_MIN_KG <= entry["mass_kg"] <= MASS_MAX_KG):
            errors.append(f"{sn}: mass {entry['mass_kg']} out of range")
        if entry["type"] not in ("AP", "HP"):
            errors.append(f"{sn}: bad type {entry['type']}")
        if not entry["printname"]:
            errors.append(f"{sn}: empty PrintName")
    if errors:
        raise SystemExit("validation failed:\n  " + "\n  ".join(errors))
    if len(resolved) < 150:
        raise SystemExit(
            f"validation failed: only {len(resolved)} entries (required 150+)"
        )

    mass_sources = {"description": 0, "grain": 0, "shell": 0, "ratio": 0,
                    "override": 0}
    types = {"AP": 0, "HP": 0}
    shotgun = 0
    pellets = 0
    for entry in resolved:
        mass_sources[entry["mass_source"]] += 1
        types[entry["type"]] += 1
        if entry["token"] in ("12x70", "20x70", "23x75", "40x46"):
            shotgun += 1
        if entry["num"] > 1:
            pellets += 1

    packs = sorted({entry["pack"] for entry in entries})
    stats = {
        "total": len(resolved),
        "mass_sources": mass_sources,
        "types": types,
        "tracer": sum(1 for e in resolved if e["tracer"]),
        "shotgun": shotgun,
        "pellets": pellets,
        "duplicates": duplicates,
        "unknown_tokens": sum(
            1 for e in entries for t in e["tokens"]
            if normalize_token(t) not in config["caliber_by_token"]
        ),
        "packs": len(packs),
        "packs_list": packs,
    }
    return resolved, stats


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_or_check(path, content, check_only, quiet):
    if check_only:
        if not os.path.exists(path):
            return False
        return read_text(path) == content
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(content)
    if not quiet:
        print(f"wrote {os.path.relpath(path, WORKSPACE)}")
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=DEFAULT_ROOT,
                        help="extracted pack root (default: Weapon_pack_extracted/eft_extract)")
    parser.add_argument("--config", default=DEFAULT_CONFIG,
                        help="path to sh_config.lua")
    parser.add_argument("--lua-out", default=DEFAULT_LUA_OUT)
    parser.add_argument("--doc-out", default=DEFAULT_DOC_OUT)
    parser.add_argument("--csv-out", default=DEFAULT_CSV_OUT)
    parser.add_argument("--check", action="store_true",
                        help="do not write; fail if outputs are out of date")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    config = parse_config(args.config)
    entries = collect_attachments(args.root)
    resolved, stats = build(entries, config)

    lua_text = render_lua(resolved)
    lua_sha = sha256_text(lua_text)
    csv_text = render_csv(resolved)
    docs_text = render_docs(resolved, config, lua_sha, stats)

    outputs = [
        (args.lua_out, lua_text),
        (args.doc_out, docs_text),
        (args.csv_out, csv_text),
    ]

    ok = True
    for path, content in outputs:
        if not write_or_check(path, content, args.check, args.quiet):
            ok = False
            print(f"out of date: {os.path.relpath(path, WORKSPACE)}",
                  file=sys.stderr)

    if args.check:
        if ok:
            if not args.quiet:
                print(f"up to date: {len(resolved)} entries")
            return 0
        return 1

    if not args.quiet:
        print(f"entries: {len(resolved)}")
        print(
            "mass sources: "
            + ", ".join(f"{k}={v}" for k, v in stats["mass_sources"].items())
        )
        print(f"types: AP={stats['types']['AP']}, HP={stats['types']['HP']}")
        print(f"tracer: {stats['tracer']}, shotshell: {stats['shotgun']}")
        print(
            f"packs: {stats['packs']} ({', '.join(stats['packs_list'])}), "
            f"duplicates resolved: {stats['duplicates']}, "
            f"unknown tokens: {stats['unknown_tokens']}"
        )
        print(f"lua sha256: {lua_sha}")
        print("validation: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
