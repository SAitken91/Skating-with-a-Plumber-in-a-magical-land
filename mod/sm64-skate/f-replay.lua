-- Replay editor (D-pad Down / 2): the last 60 seconds, always recording.
-- The world keeps running; Mario is intangible while the replay plays, and the
-- skate engine is paused, so closing the replay resumes the session exactly.
--
-- Controller: A play/pause, RT/LT fast-forward/rewind (analog), LB/RB playback
-- speed, D-pad Left/Right frame step, X camera, right stick orbit, left stick
-- moves the tripod, Y hide HUD, B or D-pad Down exit.
-- Keyboard: P play/pause, ,/. step, [/] speed, C camera, H HUD, Backspace or 2 exit.

local S = SK.S
local PAD = SK.PAD
local MAX = 30 * 60
local SPEEDS = { 0.25, 0.5, 1, 2 }
local CAMERAS = { "Skate cam", "Orbit", "Tripod", "Low follow" }
local VK = { P = 0x50, C = 0x43, H = 0x48, COMMA = 0xBC, PERIOD = 0xBE, LBR = 0xDB, RBR = 0xDD, BACK = 0x08, TWO = 0x32,
    LEFT = 0x25, RIGHT = 0x27 }

ACT_SKATE_REPLAY = allocate_mario_action(ACT_GROUP_CUTSCENE | ACT_FLAG_INTANGIBLE | ACT_FLAG_INVULNERABLE)
hook_mario_action(ACT_SKATE_REPLAY, { every_frame = function(m) return 0 end })

local ring = { frames = {}, head = 0, count = 0 }
local rp = nil -- active replay state

function SK.replay_active() return rp ~= nil end
function SK.replay_owns_action(action) return action == ACT_SKATE_REPLAY end
function SK.replay_clear() ring = { frames = {}, head = 0, count = 0 } end

-- ---------------------------------------------------------------- recording
local lastTricks = -1
function SK.replay_record(m)
    if rp ~= nil then return end
    local gfx = m.marioObj.header.gfx
    local f = {
        gfx.pos.x, gfx.pos.y, gfx.pos.z, gfx.angle.x, gfx.angle.y, gfx.angle.z,
        animID = gfx.animInfo.animID, animFrame = gfx.animInfo.animFrame,
    }
    local st = SK.state
    if SK.rig.ready and gfx.animInfo.curAnim == SK.rig.anim then f.rig = sk_anim_get(SK.rig.anim, SK.rig.slot) end
    local b = SK.board
    if b.visible and b.last then f.board = { table.unpack(b.last) } end
    local l = gLakituState
    f.cam = { l.pos.x, l.pos.y, l.pos.z, l.focus.x, l.focus.y, l.focus.z }
    if st.desired and SK.valid_pose() and st.pose.camera then f.fov = st.pose.camera[13] end
    if st.desired and SK.valid_pose() then
        local p = st.pose
        if (p.flags & 1) ~= 0 then f.trick, f.live, f.mult = SK.chain_text(), p.live, p.multiplier end
        if p.tricks ~= lastTricks then
            local name = SK.trick_name(p.trick, p.flags)
            if lastTricks >= 0 and name ~= "" then f.event = name end
            lastTricks = p.tricks
        end
    end
    ring.head = ring.head % MAX + 1
    ring.frames[ring.head] = f
    ring.count = math.min(ring.count + 1, MAX)
end

local function ordered()
    local out = {}
    local start = ring.head - ring.count
    for i = 1, ring.count do out[i] = ring.frames[(start + i - 1) % MAX + 1] end
    return out
end

-- ---------------------------------------------------------------- open / close
function SK.replay_open(m)
    if ring.count < 15 then
        SK.say("Nothing recorded yet.", 2)
        return
    end
    local st = SK.state
    local frames = ordered()
    rp = {
        frames = frames, cursor = math.max(1, #frames - 30 * 10), playing = true, speed = 3, camera = 1, hud = true,
        orbitYaw = m.faceAngle.y + 0x8000, orbitPitch = 0x0C00, orbitDist = 600,
        wasSkating = st.desired, restore = {
            x = m.pos.x, y = m.pos.y, z = m.pos.z, yaw = m.faceAngle.y,
            vx = m.vel.x, vy = m.vel.y, vz = m.vel.z, fwd = m.forwardVel, action = m.action,
        },
    }
    set_mario_action(m, ACT_SKATE_REPLAY, 0)
    play_sound(SOUND_MENU_CAMERA_ZOOM_IN, SK.sound_pos())
end

local function close(m)
    local r = rp
    rp = nil
    SK.rig_release(m)
    if r.wasSkating and SK.state.desired then
        set_mario_action(m, ACT_SKATE, 0)
    else
        local s = r.restore
        m.pos.x, m.pos.y, m.pos.z = s.x, s.y, s.z
        m.vel.x, m.vel.y, m.vel.z = s.vx, s.vy, s.vz
        m.forwardVel = s.fwd
        m.faceAngle.y = s.yaw
        vec3f_copy(m.marioObj.header.gfx.pos, m.pos)
        vec3s_set(m.marioObj.header.gfx.angle, 0, s.yaw, 0)
        SK.board_place(nil)
        camera_unfreeze()
        set_override_fov(0)
        SK.cameraFrozen = false
        local floorY = find_floor_height(s.x, s.y + 100, s.z)
        set_mario_action(m, (s.y - floorY > 40) and ACT_FREEFALL or ACT_IDLE, 0)
    end
    play_sound(SOUND_MENU_CAMERA_ZOOM_OUT, SK.sound_pos())
end

-- ---------------------------------------------------------------- controls
function SK.replay_input(m)
    local r = rp
    if r == nil then return end
    if SK.pressed(PAD.B) or SK.pressed(PAD.DOWN) or SK.key_pressed(VK.BACK) or SK.key_pressed(VK.TWO) then
        close(m)
        return
    end
    if SK.pressed(PAD.A) or SK.key_pressed(VK.P) then
        if not r.playing and r.cursor >= #r.frames then r.cursor = 1 end
        r.playing = not r.playing
    end
    if SK.pressed(PAD.LB) or SK.key_pressed(VK.LBR) then r.speed = math.max(1, r.speed - 1) end
    if SK.pressed(PAD.RB) or SK.key_pressed(VK.RBR) then r.speed = math.min(#SPEEDS, r.speed + 1) end
    if SK.pressed(PAD.LEFT) or SK.key_pressed(VK.COMMA) then r.playing = false; r.cursor = math.max(1, math.floor(r.cursor) - 1) end
    if SK.pressed(PAD.RIGHT) or SK.key_pressed(VK.PERIOD) then r.playing = false; r.cursor = math.min(#r.frames, math.floor(r.cursor) + 1) end
    if SK.pressed(PAD.X) or SK.key_pressed(VK.C) then
        r.camera = r.camera % #CAMERAS + 1
        if CAMERAS[r.camera] == "Tripod" then
            local l = gLakituState
            r.tripod = { l.pos.x, l.pos.y, l.pos.z }
        end
    end
    if SK.pressed(PAD.Y) or SK.key_pressed(VK.H) then r.hud = not r.hud end
    -- Scrubbing with the triggers overrides playback while held.
    local lt, rt = SK.pad.lt / 255, SK.pad.rt / 255
    r.scrub = 0
    if rt > 0.1 then r.scrub = 1 + rt * 3 elseif lt > 0.1 then r.scrub = -(1 + lt * 3) end
    if SK.key(VK.RIGHT) then r.scrub = 3 elseif SK.key(VK.LEFT) then r.scrub = -3 end
    -- Camera sticks.
    local rx, ry = SK.axis(SK.pad.rx), SK.axis(SK.pad.ry)
    r.orbitYaw = r.orbitYaw - math.floor(rx * 900)
    r.orbitPitch = SK.clamp(r.orbitPitch + math.floor(ry * 600), -0x3000, 0x3800)
    if r.tripod then
        local lx, ly = SK.axis(SK.pad.lx), SK.axis(SK.pad.ly)
        local yaw = SK.rad(gLakituState.yaw)
        r.tripod[1] = r.tripod[1] + (math.cos(yaw) * lx + math.sin(yaw) * ly) * 25
        r.tripod[3] = r.tripod[3] + (-math.sin(yaw) * lx + math.cos(yaw) * ly) * 25
        if SK.down(PAD.LB) and SK.down(PAD.RB) then r.tripod[2] = r.tripod[2] + 15 end
    end
end

-- ---------------------------------------------------------------- playback
local function lerp_values(a, b, t)
    if b == nil or t <= 0 then return a end
    local out = {}
    out[1], out[2], out[3] = SK.lerp(a[1], b[1], t), SK.lerp(a[2], b[2], t), SK.lerp(a[3], b[3], t)
    for i = 4, #a do out[i] = SK.lerp_angle(a[i], b[i], t) end
    for i = 1, 3 do out[i] = math.floor(out[i] + 0.5) end
    return out
end

local function sample(r)
    local n = #r.frames
    local i = SK.clamp(math.floor(r.cursor), 1, n)
    local t = SK.clamp(r.cursor - i, 0, 1)
    return r.frames[i], r.frames[math.min(i + 1, n)], t, i
end

function SK.replay_play(m)
    local r = rp
    if r == nil then return end
    local n = #r.frames
    local rate = r.scrub ~= 0 and r.scrub or (r.playing and SPEEDS[r.speed] or 0)
    r.cursor = SK.clamp(r.cursor + rate, 1, n)
    if r.cursor >= n and r.playing and r.scrub == 0 then r.playing = false end

    local a, b, t = sample(r)
    local x, y, z = SK.lerp(a[1], b[1], t), SK.lerp(a[2], b[2], t), SK.lerp(a[3], b[3], t)
    m.pos.x, m.pos.y, m.pos.z = x, y, z
    m.vel.x, m.vel.y, m.vel.z = 0, 0, 0
    local gfx = m.marioObj.header.gfx
    vec3f_set(gfx.pos, x, y, z)
    vec3s_set(gfx.angle, SK.lerp_angle(a[4], b[4], t), SK.lerp_angle(a[5], b[5], t), SK.lerp_angle(a[6], b[6], t))
    if a.rig then
        SK.rig_show(m, lerp_values(a.rig, b.rig, t))
    elseif a.animID ~= nil and a.animID >= 0 then
        if gfx.animInfo.animID ~= a.animID or gfx.animInfo.curAnim == SK.rig.anim then
            gfx.animInfo.animID = -1
            set_mario_animation(m, a.animID)
        end
        set_anim_to_frame(m, a.animFrame)
    end
    if a.board then
        local q = b.board or a.board
        SK.board_place(SK.lerp(a.board[1], q[1], t), SK.lerp(a.board[2], q[2], t), SK.lerp(a.board[3], q[3], t),
            SK.lerp_angle(a.board[4], q[4], t), SK.lerp_angle(a.board[5], q[5], t), SK.lerp_angle(a.board[6], q[6], t))
    else
        SK.board_place(nil)
    end

    -- Camera
    local mode = CAMERAS[r.camera]
    local tx, ty, tz = x, y + 80, z
    if mode == "Skate cam" then
        local c, d = a.cam, b.cam
        SK.set_camera(SK.lerp(c[1], d[1], t), SK.lerp(c[2], d[2], t), SK.lerp(c[3], d[3], t),
            SK.lerp(c[4], d[4], t), SK.lerp(c[5], d[5], t), SK.lerp(c[6], d[6], t), a.fov)
        if a.fov == nil then set_override_fov(0) end
    elseif mode == "Orbit" then
        local yaw, pitch = SK.rad(r.orbitYaw), SK.rad(r.orbitPitch)
        local d = r.orbitDist
        SK.set_camera(tx + math.sin(yaw) * math.cos(pitch) * d, ty + math.sin(pitch) * d, tz + math.cos(yaw) * math.cos(pitch) * d,
            tx, ty, tz, 50)
    elseif mode == "Tripod" then
        local p = r.tripod or { gLakituState.pos.x, gLakituState.pos.y, gLakituState.pos.z }
        r.tripod = p
        SK.set_camera(p[1], p[2], p[3], tx, ty, tz, 45)
    else
        local yaw = SK.rad(a[5])
        local fx, fz = math.sin(yaw), math.cos(yaw)
        SK.set_camera(x - fx * 230, y + 40, z - fz * 230, x + fx * 150, y + 30, z + fz * 150, 80)
    end
end

-- ---------------------------------------------------------------- HUD
function SK.replay_hud()
    local r = rp
    if r == nil or not r.hud then return end
    local w, h = djui_hud_get_screen_width(), djui_hud_get_screen_height()
    local n = #r.frames
    local a = sample(r)
    -- Top bar
    djui_hud_set_color(0, 0, 0, 150)
    djui_hud_render_rect(0, 0, w, 56)
    local status = r.scrub ~= 0 and string.format("%s %.1fx", r.scrub > 0 and ">>" or "<<", math.abs(r.scrub))
        or (r.playing and string.format("PLAY %gx", SPEEDS[r.speed]) or "PAUSED")
    SK.hud_text("REPLAY", 24, 12, 1.0, 255, 80, 80)
    SK.hud_text(status, 180, 12, 1.0, 255, 255, 255)
    SK.hud_text(string.format("%.1f / %.1f s", (r.cursor - 1) / 30, (n - 1) / 30), 420, 12, 1.0, 220, 220, 220)
    local cam = "Camera: " .. CAMERAS[r.camera]
    SK.hud_text(cam, w - 24 - djui_hud_measure_text(cam), 12, 1.0, 255, 220, 120)
    -- Trick text as it was shown
    if a.trick and a.trick ~= "" then
        SK.hud_centered(a.trick, h - 290, 1.1, 255, 255, 255)
        local line = SK.fmt_score(a.live or 0)
        if a.mult and a.mult > 1.01 then line = line .. string.format("  x%.1f", a.mult) end
        SK.hud_centered(line, h - 245, 1.0, 255, 220, 80)
    end
    SK.hud_hints({ { "A", "Play / pause" }, { "RT / LT", "Scrub" }, { "LB / RB", "Speed" }, { "D-pad L/R", "Step" },
        { "X", "Camera" }, { "R stick", "Orbit" }, { "Y", "Hide HUD" }, { "B", "Exit" } })
    -- Timeline with trick markers
    local x0, x1, y = 40, w - 40, SK.hudBottom - 30
    djui_hud_set_color(255, 255, 255, 60)
    djui_hud_render_rect(x0, y, x1 - x0, 8)
    djui_hud_set_color(255, 220, 80, 230)
    for i, f in ipairs(r.frames) do
        if f.event then djui_hud_render_rect(x0 + (x1 - x0) * (i - 1) / math.max(1, n - 1) - 1, y - 6, 3, 20) end
    end
    local cx = x0 + (x1 - x0) * (r.cursor - 1) / math.max(1, n - 1)
    djui_hud_set_color(255, 80, 80, 255)
    djui_hud_render_rect(cx - 3, y - 10, 6, 28)
end
