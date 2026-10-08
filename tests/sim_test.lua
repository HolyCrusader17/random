-- Offline simulation of the RoNUltrakill mod: stands in for UE4SS and Ready or Not with fake objects,
-- drives a raid through all three modes and checks the meter, the HUD and the events sent to the helper.
-- This tests the mod's own logic only; the real game's class and property names are checked in game.
--   lua5.4 tests/sim_test.lua
local here = debug.getinfo(1, "S").source:match("^@(.*)/tests/") or "."
package.path = here .. "/mod/RoNUltrakill/Scripts/?.lua;" .. package.path

local tmp = os.getenv("SIM_TMP") or "/tmp/ronuk-sim"
os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp .. "/RoNUltrakill")
local real_getenv = os.getenv
os.getenv = function(k) if k == "LOCALAPPDATA" then return tmp end return real_getenv(k) end
os.execute = function(cmd) print("(os.execute suppressed) " .. cmd) return true end
-- a live helper heartbeat, so the mod doesn't try to start UKAudio.exe
do local f = io.open(tmp .. "/RoNUltrakill/helper.alive", "w"); f:write(tostring(os.time())); f:close() end

---------------------------------------------------------------------------------------------- fakes
local next_addr = 1000
local function obj(class, fields)
    next_addr = next_addr + 1
    local o = fields or {}
    local addr = next_addr
    o.__class = class
    function o:IsValid() return true end
    function o:GetAddress() return addr end
    function o:GetClass()
        return { GetFName = function() return { ToString = function() return class end } end }
    end
    return o
end

local clock = 0
local hud_text = {}
local widgets = {}
local function widget(class, name)
    local w = obj(class, {})
    w.name = name
    w.Font = { Size = 0 }
    function w:SetFont(f) self.Font = f end
    function w:SetShadowOffset() end
    function w:SetShadowColorAndOpacity() end
    function w:SetText(t) hud_text[self.name] = t.text end
    function w:SetColorAndOpacity() end
    function w:SetPercent(p) hud_text[self.name .. ".percent"] = p end
    function w:SetFillColorAndOpacity() end
    function w:SetVisibility(v) hud_text.visibility = v end
    function w:AddToViewport() self.in_viewport = true end
    function w:AddChildToCanvas()
        return { SetAnchors = function() end, SetPosition = function() end, SetSize = function() end }
    end
    widgets[#widgets + 1] = w
    return w
end

local function character(class, x, y)
    local c = obj(class, {
        loc = { X = x, Y = y, Z = 0 },
        arrested = false, surrendered = false, incap = false, dead = false, Health = 100,
    })
    function c:K2_GetActorLocation() return self.loc end
    function c:IsArrested() return self.arrested end
    function c:IsSurrendered() return self.surrendered end
    function c:IsIncapacitated() return self.incap end
    function c:IsDeadNotUnconscious() return self.dead end
    function c:IsPlayerControlled() return self.__class == "PlayerCharacter_C" end
    c.Mesh = obj("SkeletalMeshComponent", {})
    c.Mesh.GlobalAnimRateScale = 1.0
    function c.Mesh:DoesSocketExist(n) return n == "head" end
    function c.Mesh:GetSocketLocation() return { X = c.loc.X, Y = c.loc.Y, Z = c.loc.Z + 0 } end
    return c
end

local player = character("PlayerCharacter_C", 0, 0)
player.CharacterMovement = obj("CharacterMovementComponent", { MaxWalkSpeed = 400 })
local firing = false
local pc = obj("ReadyOrNotPlayerController", { Pawn = player })
pc.PlayerCameraManager = obj("PlayerCameraManager", {})
function pc.PlayerCameraManager:GetCameraLocation() return { X = 0, Y = 0, Z = 0 } end
function pc.PlayerCameraManager:GetCameraRotation() return { Pitch = 0, Yaw = 0, Roll = 0 } end
function pc:IsInputKeyDown(k) return firing and k.KeyName == "LeftMouseButton" end

local map = "RIDGELINE"
local gs = obj("ReadyOrNotGameState", {})
function gs:GetServerWorldTimeSeconds() return clock end

local chars = {}
local suspects = {
    character("SuspectCharacter_C", 1000, 0),   -- 1 straight ahead
    character("SuspectCharacter_C", 200, 0),    -- 2 within reach
    character("SuspectCharacter_C", 1500, 30),  -- 3 ahead
    character("SuspectCharacter_C", 1500, -30), -- 4 ahead
    character("SuspectCharacter_C", 0, 3000),   -- 5 far to the side (squad's)
}
local civ = character("CivilianCharacter_C", 1200, 10)
for _, s in ipairs(suspects) do chars[#chars + 1] = s end
chars[#chars + 1] = civ
chars[#chars + 1] = player

local binds = {}
Key = { F7 = "F7", F8 = "F8", F9 = "F9" }
function RegisterKeyBind(k, fn) binds[k] = fn end
function FName(s) return s end
function FText(s) return { text = s } end
local world_reads = 0
function FindAllOf(c)
    world_reads = world_reads + 1
    if c == "Character" then return chars end
    if c == "PlayerController" then return { pc } end
end
function FindFirstOf(c)
    if c == "GameStateBase" then return gs end
    if c == "GameInstance" then return obj("GameInstance", {}) end
end
function StaticFindObject(path) return obj("Class", { path = path }) end
function StaticConstructObject(cls, outer, name) return widget(cls.path, name) end
function ForEachUObject(fn)
    local f = obj("Function", {})
    function f:GetFName() return { ToString = function() return "ApplyUnauthorizedPenalty" end } end
    function f:GetFullName() return "Function /Script/ReadyOrNot.Scoring:ApplyUnauthorizedPenalty" end
    fn(f)
end
local loop_fn
function LoopAsync(ms, fn) loop_fn = fn end
function ExecuteInGameThread(fn) fn() end

local logs = {}
local real_print = print
print = function(s) logs[#logs + 1] = s; if os.getenv("SIM_VERBOSE") then real_print((s:gsub("\n$", ""))) end end

local world_id = 1
function pc:GetWorld()
    return {
        GetFName = function() return { ToString = function() return map end } end,
        GetAddress = function() return world_id end,
    }
end

---------------------------------------------------------------------------------------------- run
dofile(here .. "/mod/RoNUltrakill/Scripts/main.lua")
local S = require("sheets")

local function step(n, dt)
    for _ = 1, (n or 1) do clock = clock + (dt or 0.1); loop_fn() end
end
local function events()
    local t = {}
    for line in io.lines(tmp .. "/RoNUltrakill/events.log") do t[#t + 1] = line end
    return t
end
local function has_event(kind, arg)
    for _, l in ipairs(events()) do
        local _, k, a = l:match("^(%d+)\t([^\t]*)\t(.*)$")
        if k == kind and (arg == nil or a == arg) then return true end
    end
    return false
end
local function logged(pat)
    for _, l in ipairs(logs) do if l:find(pat, 1, true) then return true end end
    return false
end
local fails = 0
local function check(cond, what)
    if cond then real_print("  ok   " .. what) else fails = fails + 1; real_print("  FAIL " .. what) end
end
local function rank() return hud_text["RoNUK_letter"] end

real_print("== start")
step(25) -- the first world is read after settings.load_resume_ms
check(hud_text["RoNUK_mode"] == "CLEAN", "starts in Clean mode, shown on the meter")
check(rank() == "D", "starts at rank D")
check(has_event("hello", "lua") and has_event("music", "calm") and has_event("mission_start", "RIDGELINE"), "helper told: hello, calm music, mission start")
check(logged("character class SuspectCharacter_C -> suspect") and logged("character class CivilianCharacter_C -> civilian"), "classes sorted by the hooks sheet")

real_print("== Clean: takedown, arrest chain, unauthorized kill")
firing = true; step(1); firing = false
suspects[1].incap = true; step(1)
check(logged("event takedown +110"), "takedown of the suspect the player shot at: +110")
check(rank() == "C", "rank C after the takedown")
suspects[2].surrendered = true; step(1)
suspects[2].arrested = true; step(1)
check(logged("event fast_clear +90") and logged("event arrest +150"), "arrest within reach right after: fast clear + arrest")
check(rank() == "B", "rank B")
check(has_event("sfx", "sfx_rank_up") and has_event("music", "drive"), "rank-up sound and music moved to 'drive'")
suspects[5].arrested = true; step(1)
check(logged("event squad_arrest +40"), "far-away arrest counts as the squad's: +40")
firing = true; step(1); firing = false
civ.dead = true; step(1)
check(logged("event unauthorized_kill +0"), "killing the civilian the player shot is unauthorized")
check(rank() == "D", "Clean: unauthorized kill drops to D")
check(has_event("sfx", "sfx_rank_down"), "rank-down sound sent")

real_print("== ULTRAKILL Rules: headshot multi-kill")
binds.F7(); step(1)
check(hud_text["RoNUK_mode"] == "ULTRAKILL RULES", "F7 switches to ULTRAKILL Rules")
check(has_event("mode", "ultrakill") and has_event("sfx", "sfx_mode_switch"), "mode switch sent to the helper with its sound")
firing = true; step(1); firing = false
suspects[3].dead = true; step(1)
suspects[4].dead = true; step(1)
check(logged("event kill +70") and logged("event headshot +50") and logged("event multikill +120"), "kill, headshot and multikill score")
check(logged("event multikill +120 -> 359 (B)"), "a headshot double kill reaches B (360 points less decay)")
check(logged("event level_clear +250") and hud_text["RoNUK_banner"] == "AREA SECURED", "every suspect down: area secured")
check(rank() == "A", "rank A after area secured")

real_print("== Power: buffs and the ULTRAKILL-rank hit absorb")
binds.F7(); step(1)
check(hud_text["RoNUK_mode"] == "POWER", "F7 again switches to Power")
check(player.CharacterMovement.MaxWalkSpeed > 400, "Power at rank A makes the player faster (" .. player.CharacterMovement.MaxWalkSpeed .. ")")
check(player.Mesh.GlobalAnimRateScale > 1, "Power at rank A speeds up animations such as reloads")
-- push to ULTRAKILL rank with a run of takedowns
for i = 1, 12 do
    local s = character("SuspectCharacter_C", 150, i); chars[#chars + 1] = s; step(1)
    s.incap = true; step(1)
end
check(has_event("music", "combat"), "music moved to 'combat' at S")
check(rank() == "ULTRAKILL", "a chain of takedowns reaches ULTRAKILL rank")
check(has_event("sfx", "sfx_rank_ultrakill") and has_event("music", "ultra"), "ULTRAKILL rank sound and 'ultra' music")
player.Health = 60; step(1)
check(player.Health == 100, "Power at ULTRAKILL rank: the hit is cancelled")
check(rank() == "SSS", "... and the rank drops one")
player.Health = 70; step(1)
check(player.Health == 70, "the next hit at SSS lands normally")
check(rank() == "SS", "... and drops one more rank")
binds.F7(); step(1)
check(player.CharacterMovement.MaxWalkSpeed == 400 and math.abs(player.Mesh.GlobalAnimRateScale - 1) < 1e-9, "leaving Power restores speed and animation rate")

real_print("== decay, HUD toggle, recon, mission end")
step(600)
check(rank() == "D", "style decays back to D within a minute")
binds.F8(); step(1)
check(hud_text.visibility == 1, "F8 hides the meter")
binds.F8(); step(1)
check(hud_text.visibility == 4, "F8 shows it again")
binds.F9(); step(1)
check(logged("penalty_suppress candidate: Function /Script/ReadyOrNot.Scoring:ApplyUnauthorizedPenalty"), "F9 recon lists penalty functions")
check(logged("hook state_arrested ok via IsArrested (call)"), "hook results are logged for verification")
map = "Station"; step(1)
check(has_event("mission_end"), "map change ends the mission and tells the helper")
check((hud_text["RoNUK_banner"] or ""):find("BEST RANK ULTRAKILL", 1, true) ~= nil, "end banner shows the best rank: " .. tostring(hud_text["RoNUK_banner"]))
check(not logged("event level_clear +400"), "no free 'area secured' on the next map before anyone is neutralized")

real_print("== map loads")
world_id = 2; map = "RIDGELINE"; step(1); local reads = world_reads; step(10)
check(world_reads == reads, "a new world is not read right after the load")
check(logged("new world: reading it in"), "the world change is noticed")
step(15)
check(world_reads > reads and logged("map RIDGELINE"), "reading resumes shortly after the load")
check(hud_text.visibility == 4, "the meter is rebuilt on the new map")

real_print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
