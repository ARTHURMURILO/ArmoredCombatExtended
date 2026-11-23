#!/usr/bin/env python3
"""Headless test runner for the ARC9 <-> ACE bridge.

Runs the bridge's pure conversion layer under LuaJIT with the *real* ACE
ballistics formulas, extracted verbatim from the ACE fork so the test can never
drift from the server's maths.

Usage:
    python3 Arc9AceBridge/tests/run_tests.py [--verbose]

Exit code 0 = all assertions passed.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)
ROOT = os.path.dirname(ADDON)

ACE_FUNCS = os.path.join(ROOT, "ArmoredCombatExtended", "lua", "acf", "shared", "sh_ace_functions.lua")
if not os.path.exists(ACE_FUNCS):
    # Same files when this addon lives inside the ACE fork itself.
    ACE_FUNCS = os.path.join(ROOT, "lua", "acf", "shared", "sh_ace_functions.lua")
LUAJIT = os.environ.get("LUAJIT", "luajit")

WANTED = ["ACE_MuzzleVelocity", "ACE_Kinetic", "ACE_CalcPenetration"]

STUBS = r"""
-- Minimal Garry's Mod / ACE environment for the pure conversion layer.
function isnumber(v) return type(v) == "number" end
function isstring(v) return type(v) == "string" end
function istable(v) return type(v) == "table" end
function isbool(v) return type(v) == "boolean" end
function isfunction(v) return type(v) == "function" end
function isvector(v) return type(v) == "Vector" end
math.Clamp = function(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
math.Round = function(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end
function AddCSLuaFile() end

ACE = {
	PenAreaMod = 0.85,
	PBase = 1050,
	PScale = 1,
	MVScale = 0.5,
	KinFudgeFactor = 2.1,
	KEtoRHA = 0.25,
	DragDiv = 40,
	VelScale = 1,
	PDensity = 1.6,
}
"""


def extract_functions(path, names):
    """Pull top-level `function ACE_x(...)` blocks out of the ACE source."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()

    out = []
    for name in names:
        start = None
        for i, line in enumerate(lines):
            if re.match(r"^function %s\s*\(" % re.escape(name), line):
                start = i
                break
        if start is None:
            raise SystemExit("could not find %s in %s" % (name, path))

        depth = 0
        block = []
        for line in lines[start:]:
            block.append(line.rstrip("\n"))
            stripped = line.strip()
            # Cheap block-depth tracking: only top-level helper functions are
            # flat enough for this, which is true for the three we need.
            depth += len(re.findall(r"\b(function|do|if|for|while)\b", stripped))
            depth -= len(re.findall(r"\bend\b", stripped))
            if depth <= 0:
                break
        out.append("\n".join(block))
    return "\n\n".join(out)


def build_lua(selftest_path):
    source = extract_functions(ACE_FUNCS, WANTED)

    # Route ACE.X -> ACE_X the same way the live addon does (metatable fallback).
    alias = """
setmetatable(ACE, {
	__index = function(_, key) return rawget(_G, "ACE_" .. key) end,
})

dofile(%r)
dofile(%r)
dofile(%r)
dofile(%r)
""" % (
        os.path.join(ADDON, "lua", "arc9_ace_bridge", "sh_config.lua"),
        os.path.join(ADDON, "lua", "arc9_ace_bridge", "sh_eft_ammo_map.lua"),
        os.path.join(ADDON, "lua", "arc9_ace_bridge", "sh_convert.lua"),
        selftest_path,
    )

    return STUBS + "\n" + source + "\n" + alias


def main():
    selftest = os.path.join(HERE, "lua", "selftest.lua")
    lua = build_lua(selftest)

    fd, path = tempfile.mkstemp(prefix="arc9ace_", suffix=".lua")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(lua)
        proc = subprocess.run([LUAJIT, path], cwd=ROOT)
        return proc.returncode
    finally:
        os.unlink(path)


if __name__ == "__main__":
    sys.exit(main())
