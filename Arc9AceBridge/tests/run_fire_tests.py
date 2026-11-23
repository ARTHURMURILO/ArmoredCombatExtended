#!/usr/bin/env python3
"""Headless integration test for the bridge fire path + player damage model.

Loads the bridge's server modules under LuaJIT with a small Garry's Mod API
stub layer (Vector/Angle maths, entities, convars, ACE_CreateBullet capture) and
simulates an ARC9 weapon firing. This catches wiring errors (nil fields, wrong
argument order, double-fire, unhandled fallbacks) without a game server.

Usage:
    python3 Arc9AceBridge/tests/run_fire_tests.py
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)
ROOT = os.path.dirname(ADDON)

LUAJIT = os.environ.get("LUAJIT", "luajit")

STUBS = r"""
-- /////////////////////////////////////////////////////////////
-- Garry's Mod API stubs (only what the bridge actually touches)
-- /////////////////////////////////////////////////////////////

function isnumber(v) return type(v) == "number" end
function isstring(v) return type(v) == "string" end
function istable(v) return type(v) == "table" end
function isbool(v) return type(v) == "boolean" end
function isfunction(v) return type(v) == "function" end
function isvector(v) return getmetatable(v) == VectorMeta end
function isangle(v) return getmetatable(v) == AngleMeta end

math.Clamp = function(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
math.Round = function(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end

function AddCSLuaFile() end
function ErrorNoHalt(msg) print("ERRORNO HALT " .. tostring(msg)) end

FCVAR_ARCHIVE = 1
HITGROUP_GENERIC = 0
HITGROUP_HEAD = 1
HITGROUP_CHEST = 2
HITGROUP_STOMACH = 3
HITGROUP_LEFTARM = 4
HITGROUP_RIGHTARM = 5
HITGROUP_LEFTLEG = 6
HITGROUP_RIGHTLEG = 7
HITGROUP_GEAR = 10

-- ///// Vector /////
VectorMeta = {}
VectorMeta.__index = VectorMeta
function VectorMeta:Length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
function VectorMeta:LengthSqr() return self.x * self.x + self.y * self.y + self.z * self.z end
function VectorMeta:GetNormalized()
	local l = self:Length()
	if l == 0 then return Vector(0, 0, 0) end
	return Vector(self.x / l, self.y / l, self.z / l)
end
function VectorMeta:__add(o) return Vector(self.x + o.x, self.y + o.y, self.z + o.z) end
function VectorMeta:__sub(o) return Vector(self.x - o.x, self.y - o.y, self.z - o.z) end
function VectorMeta:__mul(o)
	if isnumber(o) then return Vector(self.x * o, self.y * o, self.z * o) end
	return Vector(self.x * o.x, self.y * o.y, self.z * o.z)
end
function VectorMeta:__unm() return Vector(-self.x, -self.y, -self.z) end
function VectorMeta:__tostring() return string.format("(%f %f %f)", self.x, self.y, self.z) end
function Vector(x, y, z)
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VectorMeta)
end

-- ///// Angle /////
AngleMeta = {}
AngleMeta.__index = AngleMeta
function AngleMeta:Add(o) self.p = self.p + o.p self.y = self.y + o.y self.r = self.r + o.r return self end
function AngleMeta:Mul(s) self.p = self.p * s self.y = self.y * s self.r = self.r * s return self end
function AngleMeta:Forward()
	local p, y = math.rad(self.p), math.rad(self.y)
	local cp = math.cos(p)
	return Vector(cp * math.cos(y), cp * math.sin(y), -math.sin(p))
end
function AngleMeta:__tostring() return string.format("(%f %f %f)", self.p, self.y, self.r) end
function Angle(a, b, c)
	if isangle(a) then return Angle(a.p, a.y, a.r) end
	if istable(a) and b == nil then return Angle(a.p or 0, a.y or 0, a.r or 0) end
	return setmetatable({ p = a or 0, y = b or 0, r = c or 0 }, AngleMeta)
end

function Color(r, g, b) return { r = r or 255, g = g or 255, b = b or 255 } end

-- ///// table.Copy (GMod extension) /////
function table.Copy(t, lookup)
	if type(t) ~= "table" then return t end
	lookup = lookup or {}
	if lookup[t] then return lookup[t] end
	local out = {}
	lookup[t] = out
	for k, v in pairs(t) do
		if type(v) == "table" then
			local mt = getmetatable(v)
			if mt == VectorMeta or mt == AngleMeta or v.index ~= nil or v.valid == true then
				out[k] = v
			else
				out[k] = table.Copy(v, lookup)
			end
		else
			out[k] = v
		end
	end
	return out
end

-- ///// convars /////
CONVARS = {}
local ConVarMeta = {}
ConVarMeta.__index = ConVarMeta
function ConVarMeta:GetBool() return self.value ~= 0 and self.value ~= "0" end
function ConVarMeta:GetInt() return math.floor(tonumber(self.value) or 0) end
function ConVarMeta:GetFloat() return tonumber(self.value) or 0 end
function CreateConVar(name, default)
	local cv = setmetatable({ name = name, value = tonumber(default) or 0 }, ConVarMeta)
	CONVARS[name] = cv
	return cv
end
function GetConVar(name) return CONVARS[name] end

-- ///// entities / engine /////
FAKE_ENT_INDEX = 100
function CurTime() return CURTIME end
CURTIME = 100
TICK = 1

engine = {
	TickCount = function() return TICK end,
	ActiveGamemode = function() return "sandbox" end,
}

util = {
	SharedRandom = function(_, a, b) return (a + b) / 2 end,
}

FAKE_ENTITIES = {}
local function NewFakeEntity(class)
	FAKE_ENT_INDEX = FAKE_ENT_INDEX + 1
	local ent = {
		class = class,
		index = FAKE_ENT_INDEX,
		nw = {},
		valid = true,
	}
	function ent:EntIndex() return self.index end
	function ent:GetClass() return self.class end
	function ent:IsValid() return self.valid end
	function ent:Remove() self.valid = false end
	function ent:CPPISetOwner(owner) self.owner = owner end
	function ent:SetNWInt(k, v) self.nw[k] = v end
	function ent:SetNWFloat(k, v) self.nw[k] = v end
	function ent:SetNWString(k, v) self.nw[k] = v end
	function ent:SetNWVector(k, v) self.nw[k] = v end
	function ent:SetColor(c) self.colour = c end
	FAKE_ENTITIES[FAKE_ENT_INDEX] = ent
	return ent
end

ents = {
	Create = function(class) return NewFakeEntity(class) end,
}

function IsValid(ent)
	if ent == nil or ent == false then return false end
	if type(ent) ~= "table" then return false end
	if ent.valid == false then return false end
	return true
end

-- ///// weapon registry /////
WEAPONS = {} -- array of class tables
WEAPON_BASES = {} -- classname -> parent classname

weapons = {
	GetList = function() return WEAPONS end,
	IsBasedOn = function(class, base)
		local seen = {}
		while class and not seen[class] do
			if class == base then return true end
			seen[class] = true
			class = WEAPON_BASES[class]
		end
		return false
	end,
}

-- ///// hooks /////
HOOKS = {}
hook = {
	Add = function(name, id, fn) HOOKS[name .. id] = fn end,
	Run = function(name, ...) return nil end,
	Remove = function() end,
}

-- ///// ACE bullet capture /////
CREATED_BULLETS = {}
ACE_CreateBullet = function(data)
	CREATED_BULLETS[#CREATED_BULLETS + 1] = table.Copy(data)
end

-- ///// ARC9 /////
local ATT = {}
ARC9 = {
	HUToM = 0.0254,
	GetAttTable = function(name) return ATT[name] end,
	CancelMultipliers = {
		[1] = {
			[HITGROUP_HEAD] = 2,
			[HITGROUP_CHEST] = 1,
			[HITGROUP_STOMACH] = 1,
			[HITGROUP_LEFTARM] = 0.25,
			[HITGROUP_RIGHTARM] = 0.25,
			[HITGROUP_LEFTLEG] = 0.25,
			[HITGROUP_RIGHTLEG] = 0.25,
			[HITGROUP_GENERIC] = 1,
			[HITGROUP_GEAR] = 1,
		},
	},
	NoBodyPartsDamageMults = false,
}
function RegisterAtt(id, t)
	t.ShortName = t.ShortName or id
	ATT[id] = t
end
"""

TAIL = r"""
dofile(%r)
dofile(%r)
dofile(%r)
dofile(%r)
dofile(%r)
dofile(%r)
"""


def main():
    selftest = os.path.join(HERE, "lua", "fire_selftest.lua")
    modules = [
        os.path.join(ADDON, "lua", "arc9_ace_bridge", "sh_config.lua"),
        os.path.join(ADDON, "lua", "arc9_ace_bridge", "sh_eft_ammo_map.lua"),
        os.path.join(ADDON, "lua", "arc9_ace_bridge", "sh_convert.lua"),
        os.path.join(ADDON, "lua", "arc9_ace_bridge", "sv_fire.lua"),
        os.path.join(ADDON, "lua", "arc9_ace_bridge", "sv_damage.lua"),
        selftest,
    ]
    lua = STUBS + "\n" + (TAIL % tuple(modules))

    fd, path = tempfile.mkstemp(prefix="arc9ace_fire_", suffix=".lua")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(lua)
        proc = subprocess.run([LUAJIT, path], cwd=ROOT)
        return proc.returncode
    finally:
        os.unlink(path)


if __name__ == "__main__":
    sys.exit(main())
