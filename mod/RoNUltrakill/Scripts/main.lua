-- Ready or Not x ULTRAKILL: the style meter, its three modes and the bridge to the ULTRAKILL audio helper.
-- All numbers, names and texts come from sheets.lua (generated from sheets/*.json by tools/gen.py).
-- Engine reads run on the game thread and every read is wrapped in pcall (see game_info notes).

local S = require("sheets")

local TAG = "[RoNUK] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end
local function cfg(id) return S.settings_by_id[id].value end
local function hookrow(id) return S.hooks_by_id[id] end

---------------------------------------------------------------------------------------------------
-- Paths and the audio helper bridge
---------------------------------------------------------------------------------------------------
local LOCALAPPDATA = (os.getenv("LOCALAPPDATA") or "."):gsub("\\", "/")
local function path(id) return (cfg(id):gsub("{localappdata}", LOCALAPPDATA)) end

local MOD_DIR = (function()
    local src = debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.*)[/\\]Scripts[/\\]main%.lua$")
    return dir or "Mods/RoNUltrakill"
end)()

local function read_kv(file)
    local t = {}
    local f, err = io.open(file, "r")
    if not f then log("cannot read " .. file .. ": " .. tostring(err)); return t end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then t[k] = v end
    end
    f:close()
    return t
end

local seq = 0
local emit_failed = false
local function emit(kind, arg)
    -- one line per event, tailed by UKAudio.exe; the first write of a game session empties the file
    local f, err = io.open(path("events_file"), seq == 0 and "w" or "a")
    if not f then
        if not emit_failed then emit_failed = true; log("cannot write events: " .. tostring(err)) end
        return
    end
    seq = seq + 1
    f:write(string.format("%d\t%s\t%s\n", seq, kind, arg or ""))
    f:close()
end

local function helper_alive()
    local f = io.open(path("heartbeat_file"), "r")
    if not f then return false end
    local t = tonumber(f:read("l") or "")
    f:close()
    return t ~= nil and math.abs(os.time() - t) <= 5
end

local helper_tried = false
local function ensure_helper()
    -- Melty starts UKAudio.exe alongside the game (recipe.together). This only covers a game started
    -- some other way, e.g. straight from Steam.
    if helper_tried or helper_alive() then return end
    helper_tried = true
    local exe = MOD_DIR .. "/bin/UKAudio.exe"
    local f = io.open(exe, "rb")
    if not f then log("audio helper not found at " .. exe); return end
    f:close()
    local uk = read_kv(path("settings_file")).ULTRAKILL_DIR
        or read_kv((cfg("settings_file_mod"):gsub("{mod}", MOD_DIR))).ULTRAKILL_DIR or ""
    log("ULTRAKILL folder: " .. (uk ~= "" and uk or "(none)"))
    local cmd = string.format('start "" "%s" --ultrakill "%s"', exe:gsub("/", "\\"), uk)
    log("starting audio helper: " .. cmd)
    os.execute(cmd)
end

---------------------------------------------------------------------------------------------------
-- Reading Ready or Not: every name comes from a hooks row, tried in order, cached per class
---------------------------------------------------------------------------------------------------
local hook_ok = {}       -- hook id -> "name (how)" once it answered
local hook_cache = {}    -- hook id -> class name -> {how, name} or false
local classes_seen = {}  -- class name -> category
local cached_pc = nil    -- the local player's controller (see player_controller)

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v
end

local function class_name(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

-- Breadcrumbs: each distinct step is logged once before it runs, so the last line in UE4SS.log names the
-- call that took the game down if an engine read crashes (UE4SS.log is flushed up to the crash).
local crumbs = {}
local function crumb(s)
    if cfg("trace_steps") and not crumbs[s] then crumbs[s] = true; log("trace " .. s) end
end

local function note_ok(id, how, name, cls)
    if not hook_ok[id] then
        hook_ok[id] = name .. " (" .. how .. ")"
        log(string.format("hook %s ok via %s (%s) on %s", id, name, how, cls or "-"))
    end
end

-- Reads a bool/number via a hooks row (method call_or_property or property). nil = unknown.
local function read_state(o, id)
    local row = hookrow(id)
    local cls = class_name(o)
    hook_cache[id] = hook_cache[id] or {}
    local hit = hook_cache[id][cls]
    if hit == false then return nil end
    if hit then
        local ok, v
        if hit.how == "property" then
            ok, v = pcall(function() return o[hit.name] end)
        else
            ok, v = pcall(function() return o[hit.name](o) end)
        end
        if ok and (type(v) == "boolean" or type(v) == "number") then return v end
        return nil
    end
    for _, name in ipairs(row.candidates) do
        crumb(string.format("%s: read %s.%s", id, cls, name))
        local ok, v = pcall(function() return o[name] end)
        if ok and (type(v) == "boolean" or type(v) == "number") then
            hook_cache[id][cls] = { how = "property", name = name }
            note_ok(id, "property", name, cls)
            return v
        end
        local vcls = (ok and type(v) == "userdata" and valid(v)) and class_name(v) or nil
        log(string.format("probe %s %s.%s -> %s", id, cls, name,
            ok and (vcls or type(v)) or ("error " .. tostring(v))))
        -- only real UFunctions are called; a component or struct under that name is left alone
        if row.method ~= "property" and ok and (type(v) == "function" or vcls == "Function") then
            crumb(string.format("%s: call %s:%s()", id, cls, name))
            ok, v = pcall(function() return o[name](o) end)
            if ok and (type(v) == "boolean" or type(v) == "number") then
                hook_cache[id][cls] = { how = "call", name = name }
                note_ok(id, "call", name, cls)
                return v
            end
        end
    end
    hook_cache[id][cls] = false
    return nil
end

local function write_number(o, id, value)
    local hit = hook_cache[id] and hook_cache[id][class_name(o)]
    if hit and hit.how == "property" then
        pcall(function() o[hit.name] = value end)
    end
end

local function categorize(o)
    local cls = class_name(o)
    local cat = classes_seen[cls]
    if cat then return cat end
    cat = "other"
    for _, pair in ipairs({ { "class_swat", "swat" }, { "class_civilian", "civilian" }, { "class_suspect", "suspect" } }) do
        for _, frag in ipairs(hookrow(pair[1]).candidates) do
            if cls:find(frag, 1, true) then cat = pair[2]; note_ok(pair[1], "class", frag, cls); break end
        end
        if cat ~= "other" then break end
    end
    classes_seen[cls] = cat
    log("character class " .. cls .. " -> " .. cat)
    return cat
end

local function is_dead(o)
    local d = read_state(o, "state_dead")
    if type(d) == "boolean" then return d end
    local h = read_state(o, "health_props")
    if type(h) == "number" then return h <= 0 end
    return false
end

local function flag(o, id)
    local v = read_state(o, id)
    return v == true
end

---------------------------------------------------------------------------------------------------
-- Vector helpers (Unreal: centimetres, X forward, Z up)
---------------------------------------------------------------------------------------------------
local function vsub(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function vlen(a) return math.sqrt(a.X * a.X + a.Y * a.Y + a.Z * a.Z) end
local function forward(rot)
    local p, y = math.rad(rot.Pitch), math.rad(rot.Yaw)
    return { X = math.cos(p) * math.cos(y), Y = math.cos(p) * math.sin(y), Z = math.sin(p) }
end
local function angle_to(cam_loc, fwd, target)
    local d = vsub(target, cam_loc)
    local l = vlen(d)
    if l < 1 then return 0, l end
    local dot = (d.X * fwd.X + d.Y * fwd.Y + d.Z * fwd.Z) / l
    return math.deg(math.acos(math.max(-1, math.min(1, dot)))), l
end

local function actor_loc(o)
    local ok, v = pcall(function() return o:K2_GetActorLocation() end)
    if ok and v then return { X = v.X, Y = v.Y, Z = v.Z } end
    return nil
end

local head_socket = nil
local function head_loc(o)
    local ok, mesh = pcall(function() return o.Mesh end)
    if not ok or not valid(mesh) then return nil end
    if head_socket == nil then
        for _, name in ipairs(hookrow("aim_head").candidates) do
            crumb("aim_head: DoesSocketExist " .. name)
            local ok2, has = pcall(function() return mesh:DoesSocketExist(FName(name)) end)
            if ok2 and has then head_socket = name; note_ok("aim_head", "socket", name, class_name(o)); break end
        end
        if head_socket == nil then head_socket = false end
    end
    if not head_socket then return nil end
    local ok3, v = pcall(function() return mesh:GetSocketLocation(FName(head_socket)) end)
    if ok3 and v then return { X = v.X, Y = v.Y, Z = v.Z } end
    return nil
end

---------------------------------------------------------------------------------------------------
-- Style meter
---------------------------------------------------------------------------------------------------
local M = {
    mode = 1, style = 0, rank = 1, best = 1, tier = nil,
    feed = {}, banner = "", banner_until = 0,
    last_kill = -100, last_neutralize = -100, last_fire = -100,
    map = nil, cleared = false, scored = false, hud_visible = true,
    player_health = nil, base_speed = nil, base_anim = nil, buffed_pawn = nil,
}
local tick_clock = 0

local function now()
    local ok, t = pcall(function()
        local gs = FindFirstOf("GameStateBase")
        if valid(gs) then return gs:GetServerWorldTimeSeconds() end
    end)
    if ok and type(t) == "number" then note_ok("server_clock", "call", "GetServerWorldTimeSeconds"); return t end
    return tick_clock
end

local function mode() return S.modes[M.mode] end

local function rank_for(style)
    local r = 1
    for i, row in ipairs(S.ranks) do if style >= row.threshold then r = i end end
    return r
end

local function push_feed(text)
    table.insert(M.feed, 1, text)
    while #M.feed > cfg("feed_lines") do table.remove(M.feed) end
end

local function set_banner(text, secs)
    M.banner = text
    M.banner_until = now() + (secs or 4)
end

local function on_rank_change(old, new)
    if new > old then
        emit("sfx", S.ranks[new].up_sound)
    elseif new < old then
        emit("sfx", "sfx_rank_down")
    end
    if new > M.best then M.best = new end
    local tier = S.ranks[new].music_tier
    if tier ~= M.tier then M.tier = tier; emit("music", tier) end
end

local function set_style(v)
    M.style = math.max(0, math.min(cfg("style_cap"), v))
    local r = rank_for(M.style)
    if r ~= M.rank then
        local old = M.rank
        M.rank = r
        on_rank_change(old, r)
    end
end

local function fire(event_id)
    local ev = S.style_events_by_id[event_id]
    local m = mode().id
    local pts = ev["points_" .. m]
    local effect = ev["effect_" .. m]
    -- an effect replaces the points (preflight keeps those cells at 0)
    if effect == "drop_to_d" then
        set_style(0)
    elseif effect == "drop_one_rank" then
        local lower = S.ranks[M.rank - 1]
        set_style(lower and (lower.threshold + S.ranks[M.rank].threshold) / 2 or 0)
    end
    if pts ~= 0 or effect ~= "none" then
        set_style(M.style + pts)
        if event_id ~= "hit_taken" then M.scored = true end
        push_feed(ev.feed_text)
        log(string.format("event %s %+d -> %d (%s)", event_id, pts, math.floor(M.style), S.ranks[M.rank].letter))
    end
end

local function decay(dt)
    set_style(M.style - S.ranks[M.rank].decay_per_s * dt)
end

---------------------------------------------------------------------------------------------------
-- Power mode buffs
---------------------------------------------------------------------------------------------------
local function apply_buffs(pawn)
    if not valid(pawn) then return end
    local on = mode().power_buffs
    local row = S.ranks[M.rank]
    local move = on and row.power_move_mult or 1.0
    local anim = on and row.power_anim_mult or 1.0
    if M.buffed_pawn ~= pawn:GetAddress() then
        M.buffed_pawn = pawn:GetAddress()
        M.base_speed, M.base_anim = nil, nil
    end
    crumb("move_speed: CharacterMovement.MaxWalkSpeed")
    pcall(function()
        local cm = pawn.CharacterMovement
        if valid(cm) then
            M.base_speed = M.base_speed or cm.MaxWalkSpeed
            cm.MaxWalkSpeed = M.base_speed * move
            note_ok("move_speed", "property", "MaxWalkSpeed", class_name(pawn))
        end
    end)
    crumb("anim_rate: Mesh.GlobalAnimRateScale")
    pcall(function()
        local mesh = pawn.Mesh
        if valid(mesh) then
            M.base_anim = M.base_anim or mesh.GlobalAnimRateScale
            mesh.GlobalAnimRateScale = M.base_anim * anim
            note_ok("anim_rate", "property", "GlobalAnimRateScale", class_name(pawn))
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- HUD: built at runtime from stock UMG classes, no editor
---------------------------------------------------------------------------------------------------
local HUD = { widget = nil, parts = {} }

local function linear(hex)
    local function c(i) return (tonumber(hex:sub(i, i + 1), 16) / 255) ^ 2.2 end
    return { R = c(2), G = c(4), B = c(6), A = 1.0 }
end

local function construct(class_path, outer, name)
    local cls = StaticFindObject(class_path)
    if not valid(cls) then error("class not found: " .. class_path) end
    return StaticConstructObject(cls, outer, FName(name))
end

local function build_hud()
    local gi = FindFirstOf("GameInstance")
    if not valid(gi) then return end
    local paths = hookrow("hud_widget").candidates
    crumb("hud: construct widgets")
    local widget = construct(paths[1], gi, "RoNUK_StyleMeter")
    local tree = construct(paths[2], widget, "RoNUK_Tree")
    widget.WidgetTree = tree
    local canvas = construct(paths[3], tree, "RoNUK_Canvas")
    tree.RootWidget = canvas
    HUD.parts = {}
    for _, row in ipairs(S.hud) do
        local w
        if row.widget == "TextBlock" then
            w = construct(paths[4], tree, "RoNUK_" .. row.id)
            pcall(function()
                local font = w.Font
                font.Size = row.font_size
                w:SetFont(font)
            end)
            pcall(function() w:SetShadowOffset({ X = 2, Y = 2 }) end)
            pcall(function() w:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.85 }) end)
        else
            w = construct(paths[5], tree, "RoNUK_" .. row.id)
        end
        local slot = canvas:AddChildToCanvas(w)
        slot:SetAnchors({ Minimum = { X = 1, Y = 0 }, Maximum = { X = 1, Y = 0 } })
        slot:SetPosition({ X = -row.x, Y = row.y })
        slot:SetSize({ X = row.w, Y = row.h })
        HUD.parts[row.shows] = w
    end
    crumb("hud: AddToViewport")
    widget:AddToViewport(50)
    HUD.widget = widget
    note_ok("hud_widget", "call", "StaticConstructObject+AddToViewport")
    log("style meter built")
end

local function set_text(shows, text, color)
    local w = HUD.parts[shows]
    if not valid(w) then return end
    pcall(function() w:SetText(FText(text)) end)
    if color then pcall(function() w:SetColorAndOpacity({ SpecifiedColor = linear(color), ColorUseRule = 0 }) end) end
end

local function draw_hud()
    if not valid(HUD.widget) then
        HUD.widget = nil
        local ok, err = pcall(build_hud)
        if not ok then log("HUD build failed: " .. tostring(err)); return end
    end
    if not HUD.widget then return end
    pcall(function() HUD.widget:SetVisibility(M.hud_visible and 4 or 1) end) -- 4 = SelfHitTestInvisible, 1 = Collapsed
    local r = S.ranks[M.rank]
    local nxt = S.ranks[M.rank + 1]
    set_text("mode_label", mode().label, "#FFFFFF")
    set_text("rank_letter", r.letter, r.color)
    set_text("rank_name", r.name, r.color)
    set_text("feed", table.concat(M.feed, "\n"), "#FFFFFF")
    set_text("banner", now() < M.banner_until and M.banner or "", "#FFD700")
    local bar = HUD.parts["rank_progress"]
    if valid(bar) then
        local p = nxt and (M.style - r.threshold) / (nxt.threshold - r.threshold)
            or (M.style - r.threshold) / (cfg("style_cap") - r.threshold)
        pcall(function() bar:SetPercent(math.max(0, math.min(1, p))) end)
        pcall(function() bar:SetFillColorAndOpacity(linear(r.color)) end)
    end
end

---------------------------------------------------------------------------------------------------
-- Watching characters
---------------------------------------------------------------------------------------------------
local tracked = {} -- address -> state
local function reset_map()
    tracked = {}
    M.cleared = false
    M.scored = false
    M.best = M.rank
end

local function fire_held(pc)
    for _, cand in ipairs(hookrow("fire_input").candidates) do
        local key = cand:match(":(.+)$")
        crumb("fire_input: IsInputKeyDown " .. key)
        local ok, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(key) }) end)
        if ok and down then note_ok("fire_input", "call", cand); return true end
    end
    return false
end

local function scan(pc, pawn, t)
    crumb("camera: PlayerCameraManager")
    local cam = pc.PlayerCameraManager
    local cam_loc, fwd
    if valid(cam) then
        crumb("camera: GetCameraLocation/Rotation")
        local ok, l = pcall(function() return cam:GetCameraLocation() end)
        local ok2, r = pcall(function() return cam:GetCameraRotation() end)
        if ok and ok2 and l and r then
            cam_loc, fwd = { X = l.X, Y = l.Y, Z = l.Z }, forward(r)
            note_ok("camera", "call", "GetCameraLocation/GetCameraRotation")
        end
    end
    local firing = fire_held(pc)
    if firing then M.last_fire = t end
    crumb("pawn: K2_GetActorLocation")
    local player_loc = actor_loc(pawn) or cam_loc

    crumb("characters: FindAllOf Character")
    local chars = FindAllOf("Character") or {}
    if #chars > 0 then note_ok("characters", "find_all", "Character") end
    local pawn_addr = pawn:GetAddress()
    local suspects_total, suspects_down = 0, 0

    for _, o in ipairs(chars) do
        if valid(o) and o:GetAddress() ~= pawn_addr then
            local cat = categorize(o)
            if cat == "suspect" or cat == "civilian" then
                local addr = o:GetAddress()
                local cur = {
                    dead = is_dead(o),
                    arrested = flag(o, "state_arrested"),
                    surrendered = flag(o, "state_surrendered"),
                    incap = flag(o, "state_incapacitated"),
                }
                crumb("characters: K2_GetActorLocation " .. class_name(o))
                local loc = actor_loc(o)
                local dist = (loc and player_loc) and vlen(vsub(loc, player_loc)) or math.huge
                local prev = tracked[addr]
                if not prev then
                    prev = { cat = cat, targeted = -100, head = -100, was_compliant = cur.surrendered or cur.arrested }
                    for k, v in pairs(cur) do prev[k] = v end
                    tracked[addr] = prev
                end
                -- who is under the crosshair while the trigger is held
                if firing and cam_loc and fwd and loc then
                    local a = angle_to(cam_loc, fwd, loc)
                    if a <= cfg("aim_cone_deg") then prev.targeted = t end
                    local h = head_loc(o)
                    if h and angle_to(cam_loc, fwd, h) <= cfg("headshot_cone_deg") then prev.head = t end
                end
                local by_player_fire = (t - prev.targeted) <= cfg("fire_window_s")
                local by_player_reach = dist <= cfg("player_reach_cm")

                if cur.dead and not prev.dead then
                    if by_player_fire then
                        local unauthorized = (cat == "civilian") or prev.was_compliant
                        if unauthorized then
                            fire("unauthorized_kill")
                        else
                            fire("kill")
                            if (t - prev.head) <= cfg("fire_window_s") then fire("headshot") end
                            if (t - M.last_kill) <= cfg("multikill_window_s") then fire("multikill") end
                            M.last_kill = t
                        end
                    end
                elseif cur.arrested and not prev.arrested and not cur.dead then
                    if by_player_reach then
                        if (t - M.last_neutralize) <= cfg("chain_window_s") then fire("fast_clear") end
                        fire("arrest")
                        M.last_neutralize = t
                    else
                        fire("squad_arrest")
                    end
                elseif cur.incap and not prev.incap and not cur.dead and cat == "suspect" then
                    if by_player_fire or by_player_reach then
                        if (t - M.last_neutralize) <= cfg("chain_window_s") then fire("fast_clear") end
                        fire("takedown")
                        M.last_neutralize = t
                    end
                end
                if cur.surrendered and not prev.surrendered and cat == "suspect" and cam_loc and fwd and loc then
                    if angle_to(cam_loc, fwd, loc) <= cfg("aim_cone_deg") * 3 then fire("compliance") end
                end
                if cur.surrendered or cur.arrested then prev.was_compliant = true end
                for k, v in pairs(cur) do prev[k] = v end

                if cat == "suspect" then
                    suspects_total = suspects_total + 1
                    if cur.dead or cur.arrested or cur.incap then suspects_down = suspects_down + 1 end
                end
            end
        end
    end
    if not M.cleared and M.scored and suspects_total > 0 and suspects_down == suspects_total then
        M.cleared = true
        fire("level_clear")
        set_banner("AREA SECURED", 4)
    end
end

local function watch_health(pawn)
    local h = read_state(pawn, "player_health")
    if type(h) ~= "number" then return end
    if M.player_health and h < M.player_health - 0.01 then
        local r = S.ranks[M.rank]
        if mode().power_buffs and r.power_absorb_hit then
            write_number(pawn, "player_health", M.player_health)
            h = M.player_health
            set_banner("ULTRAKILL ABSORBED THE HIT", 2)
        end
        fire("hit_taken")
    end
    M.player_health = h
end

---------------------------------------------------------------------------------------------------
-- Map changes and the end-of-mission banner
---------------------------------------------------------------------------------------------------
local function current_map(pc)
    -- GameplayStatics:GetCurrentLevelName (FString return) crashes UE4SS 3.0.1 in Ready or Not (UE 5.3);
    -- the UWorld's own name is the map name and is read natively by UE4SS.
    crumb("map_name: GetWorld():GetFName()")
    local ok, name = pcall(function() return pc:GetWorld():GetFName():ToString() end)
    if ok and type(name) == "string" and name ~= "" then note_ok("map_name", "call", "GetWorld():GetFName()"); return name end
    return nil
end

local function on_map(pc)
    local map = current_map(pc)
    if map == nil or map == M.map then return end
    if M.map then
        local best = S.ranks[M.best].letter
        local msg = mode().end_score == "best_rank" and ("SCORE: BEST RANK " .. best)
            or ("BEST RANK " .. best .. " (Ready or Not score on the report)")
        log("mission end on " .. M.map .. ": " .. msg)
        emit("mission_end", best)
        set_banner(msg, 10)
    end
    M.map = map
    log("map " .. map)
    emit("mission_start", map)
    M.player_health = nil
    set_style(0)
    reset_map()
    HUD.widget = nil
end

---------------------------------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------------------------------
local want_mode_switch, want_recon = false, false
local function bind(setting_id, hook_id, fn)
    local k = Key[cfg(setting_id)]
    if not k then log("unknown key " .. tostring(cfg(setting_id))); return end
    RegisterKeyBind(k, fn)
    note_ok(hook_id, "keybind", cfg(setting_id))
end
bind("hotkey_mode", "key_mode", function() want_mode_switch = true end)
bind("hotkey_hud", "key_hud", function()
    M.hud_visible = not M.hud_visible
    log("meter " .. (M.hud_visible and "shown" or "hidden"))
end)
bind("hotkey_recon", "key_recon", function() want_recon = true end)

local function switch_mode()
    M.mode = M.mode % #S.modes + 1
    local m = mode()
    log("mode " .. m.id)
    emit("mode", m.id)
    emit("sfx", m.switch_sound)
    set_banner(m.label .. "\n" .. m.summary, 3)
end

-- Lists the properties and functions of o's class chain whose names contain one of the fragments.
local function list_members(o, frags)
    local okc, cls = pcall(function() return o:GetClass() end)
    local depth = 0
    while okc and valid(cls) and depth < 12 do
        local cname = cls:GetFName():ToString()
        pcall(function()
            cls:ForEachProperty(function(p)
                local n = p:GetFName():ToString()
                for _, f in ipairs(frags) do
                    if n:lower():find(f:lower(), 1, true) then
                        log(string.format("member %s.%s (%s)", cname, n, p:GetClass():GetFName():ToString())); break
                    end
                end
            end)
        end)
        pcall(function()
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                for _, f in ipairs(frags) do
                    if n:lower():find(f:lower(), 1, true) then log(string.format("member %s:%s()", cname, n)); break end
                end
            end)
        end)
        okc, cls = pcall(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
end

local function recon()
    log("---- recon ----")
    for cls, cat in pairs(classes_seen) do log("class " .. cls .. " = " .. cat) end
    local pc = cached_pc
    if valid(pc) and valid(pc.Pawn) then
        log("members of the player pawn " .. class_name(pc.Pawn) .. ":")
        local words = {}
        for w in cfg("recon_member_words"):gmatch("[^|]+") do words[#words + 1] = w end
        list_members(pc.Pawn, words)
    end
    for _, row in ipairs(S.hooks) do
        log(string.format("hook %-20s %s", row.id, hook_ok[row.id] or "NOT SEEN"))
    end
    local frags = hookrow("penalty_suppress").candidates
    local found = 0
    ForEachUObject(function(obj)
        if found >= 200 then return end
        local ok, cls = pcall(function() return obj:GetClass():GetFName():ToString() end)
        if ok and cls == "Function" then
            local name = obj:GetFName():ToString()
            for _, f in ipairs(frags) do
                if name:find(f, 1, true) then
                    found = found + 1
                    log("penalty_suppress candidate: " .. obj:GetFullName())
                    break
                end
            end
        end
    end)
    log("---- recon done (" .. found .. " penalty candidates) ----")
end

---------------------------------------------------------------------------------------------------
-- Main loop
---------------------------------------------------------------------------------------------------
local last_t = nil
local err_count = 0

-- UE4SS 3.0.1's UEHelpers.GetPlayerController calls an undefined global (Print) or errors while no pawn
-- exists (main menu, loading), so the mod finds the local player's controller itself.
local function player_controller()
    if valid(cached_pc) and valid(cached_pc.Pawn) then return cached_pc end
    cached_pc = nil
    crumb("player: FindAllOf PlayerController")
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        crumb("player: " .. class_name(c) .. ".Pawn")
        local ok, mine = pcall(function() return valid(c) and valid(c.Pawn) and c.Pawn:IsPlayerControlled() end)
        if ok and mine then cached_pc = c; break end
    end
    return cached_pc
end

---------------------------------------------------------------------------------------------------
-- Map loads: the mod keeps its hands off the world while a level is torn down and loaded
---------------------------------------------------------------------------------------------------
-- UE4SS 3.0.1's RegisterLoadMapPreHook/PostHook threw inside the engine at startup in Ready or Not, so a
-- load is noticed instead: the player controller lives in a different UWorld after every map load.
local tick_n = 0
local resume_at = 0   -- tick number after which a freshly loaded world is read again
local world_addr = nil

local function world_changed(pc)
    local ok, addr = pcall(function() return pc:GetWorld():GetAddress() end)
    if not ok or addr == nil or addr == world_addr then return false end
    note_ok("world_change", "call", "GetWorld():GetAddress()")
    world_addr = addr
    cached_pc, tracked, crumbs = nil, {}, {}
    HUD.widget, HUD.parts = nil, {}
    M.buffed_pawn, M.player_health = nil, nil
    resume_at = tick_n + math.ceil(cfg("load_resume_ms") / cfg("poll_ms"))
    log("new world: reading it in " .. cfg("load_resume_ms") .. " ms")
    return true
end

local function tick()
    tick_n = tick_n + 1
    if tick_n < resume_at then return end
    if cfg("trace_steps") and (tick_n <= 3 or tick_n % 50 == 0) then log("trace tick " .. tick_n) end
    tick_clock = tick_clock + cfg("poll_ms") / 1000
    local pc = player_controller()
    if not valid(pc) then return end -- main menu
    if world_changed(pc) then return end
    note_ok("player", "find_all", "PlayerController")
    crumb("tick: on_map")
    on_map(pc)
    if want_mode_switch then want_mode_switch = false; switch_mode() end
    if want_recon then want_recon = false; recon() end
    local pawn = pc.Pawn
    local t = now()
    local dt = last_t and math.max(0, math.min(1, t - last_t)) or 0
    last_t = t
    if valid(pawn) then
        crumb("tick: scan")
        scan(pc, pawn, t)
        crumb("tick: watch_health")
        watch_health(pawn)
        crumb("tick: apply_buffs")
        apply_buffs(pawn)
    end
    decay(dt)
    crumb("tick: draw_hud")
    draw_hud()
    crumb("tick: complete")
end

log("loaded; " .. #S.ranks .. " ranks, " .. #S.modes .. " modes, " .. #S.style_events .. " style events")
log("data dir " .. path("data_dir") .. ", mod dir " .. MOD_DIR)
emit("hello", "lua")
ensure_helper()
emit("mode", mode().id)
emit("music", S.ranks[M.rank].music_tier)
M.tier = S.ranks[M.rank].music_tier

-- One tick in flight at a time: while the game thread is busy (a level load) ticks are not queued up
-- to replay all at once against the fresh world.
local queued = false
LoopAsync(cfg("poll_ms"), function()
    if queued then return false end
    queued = true
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        queued = false
        if not ok then
            err_count = err_count + 1
            if err_count <= 20 or err_count % 100 == 0 then log("tick error: " .. tostring(err)) end
        end
    end)
    return false
end)
