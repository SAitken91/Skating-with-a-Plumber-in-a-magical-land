-- name: Skate 64
-- description: Skate 3's skating engine in Super Mario 64.\n\nY: get on / off the board\nHold D-pad Up: set session marker\nTap D-pad Up: return to marker\nD-pad Down: replay editor\nD-pad Right: skate menu\n\nNeeds the Skate 64 bridge (discord_game_sdk.dll) and host.

local S = SK.S
local PAD = SK.PAD
local VK_J, VK_1, VK_2, VK_3 = 0x4A, 0x31, 0x32, 0x33

ACT_SKATE = allocate_mario_action(ACT_GROUP_MOVING | ACT_FLAG_MOVING | ACT_FLAG_ATTACKING)

local st = {
    desired = false,      -- skating requested (engine session active)
    epoch = 0,            -- engine session counter; a new one restarts the skater
    spawn = { 0, 0, 0, 0 },
    pose = nil,           -- latest published pose (sk_pose)
    mountFrame = 0,
    sentRevision = -1,
    lastSafe = nil,       -- last grounded spot, for falls out of the level
    cameraOn = true,
    keyboard = true,
    score = 0,            -- session score (landed lines)
    popup = nil,          -- { text, color, until }
    lastTricks = 0, lastLanded = 0, lastBailed = 0,
    leaving = false,
}
SK.state = st

-- ---------------------------------------------------------------- helpers
local function valid_pose()
    local p = st.pose
    return p ~= nil and p.status == 1 and p.epoch == st.epoch and p.published == 1
end
SK.valid_pose = valid_pose

local function heading_of(m) return SK.rad(m.faceAngle.y) end

local function aspect()
    local w, h = djui_hud_get_screen_width(), djui_hud_get_screen_height()
    if w and h and h > 0 then return w / h end
    return 16 / 9
end

local function level_key()
    local np = gNetworkPlayers[0]
    return np.currLevelNum * 100 + np.currAreaIndex
end

function SK.can_mount(m)
    if m.playerIndex ~= 0 then return false end
    if (m.action & (ACT_FLAG_SWIMMING | ACT_FLAG_INTANGIBLE | ACT_FLAG_ON_POLE | ACT_FLAG_HANGING)) ~= 0 then return false end
    local group = m.action & ACT_GROUP_MASK
    if group == ACT_GROUP_CUTSCENE or group == ACT_GROUP_SUBMERGED then return false end
    if m.heldObj ~= nil or m.riddenObj ~= nil then return false end
    if m.health < 0x100 then return false end
    return true
end

-- ---------------------------------------------------------------- mount / dismount
function SK.start_session(m, x, y, z, heading)
    st.epoch = st.epoch + 1
    st.spawn = { x / S, y / S, z / S, heading }
    st.mountFrame = SK.frame
    st.pose = nil
end

function SK.mount(m, x, y, z, heading)
    if not SK.native then
        SK.say("Skate bridge not loaded (discord_game_sdk.dll).", 5)
        return false
    end
    if SK.geometry.count == 0 then
        SK.say("No level collision captured yet. Re-enter the level and try again.", 5)
        return false
    end
    if not sk_start() then
        SK.say("Could not start the skate host. See skate\\bridge.log.", 6)
        return false
    end
    st.desired = true
    st.leaving = false
    SK.start_session(m, x or m.pos.x, y or m.pos.y, z or m.pos.z, heading or heading_of(m))
    m.pos.x, m.pos.y, m.pos.z = x or m.pos.x, y or m.pos.y, z or m.pos.z
    set_mario_action(m, ACT_SKATE, 0)
    return true
end

--- Ends the session and hands Mario back to his own moveset, keeping momentum.
function SK.dismount(m, reason, keepAction)
    if not st.desired then return end
    st.desired = false
    st.leaving = true
    SK.rig_release(m)
    camera_unfreeze()
    set_override_fov(0)
    SK.board_update(false)
    local p = st.pose
    if not keepAction and m.action == ACT_SKATE then
        local vx, vy, vz = 0, 0, 0
        if valid_pose() then vx, vy, vz = p.velocity[1] * S / 30, p.velocity[2] * S / 30, p.velocity[3] * S / 30 end
        local speed = math.sqrt(vx * vx + vz * vz)
        m.faceAngle.x, m.faceAngle.z = 0, 0
        if speed > 1 then m.faceAngle.y = SK.s16(math.atan(vx, vz)) end
        local floorY = find_floor_height(m.pos.x, m.pos.y + 100, m.pos.z)
        if m.pos.y - floorY > 40 then
            m.vel.y = vy
            m.forwardVel = speed
            set_mario_action(m, ACT_FREEFALL, 0)
        else
            m.pos.y = math.max(m.pos.y, floorY)
            m.forwardVel = speed
            set_mario_action(m, speed > 4 and ACT_WALKING or ACT_IDLE, 0)
        end
    end
    st.leaving = false
    if reason then SK.say(reason, 3) end
end

--- The engine's skater is off the board, walking with it.
function SK.carrying_board()
    local p = st.pose
    return p ~= nil and p.state ~= nil and p.state:find("^Biped") ~= nil
end

-- ---------------------------------------------------------------- engine exchange (once per frame)
local function exchange(m)
    SK.flush_geometry()
    if not SK.native then return end
    if st.desired then
        local tris, count, key = SK.engine_geometry()
        if st.sentRevision ~= key and count > 0 and sk_geometry(tris, count) then st.sentRevision = key end
    end
    if not sk_running() then
        st.pose = nil
        return
    end
    -- The host stays paused (no heartbeat) during replays and while editing objects.
    if SK.replay_active() or (SK.dropper_active and SK.dropper_active()) then return end
    local ui = SK.menu_open()
    local s = st.spawn
    local engineY = (st.engineYFrames or 0) > 0
    if engineY then st.engineYFrames = st.engineYFrames - 1 end
    sk_frame(st.desired, st.epoch, s[1], s[2], s[3], s[4], ui, aspect(), st.keyboard, engineY)
    st.pose = sk_pose()
    local p = st.pose
    -- A session can start with the skater off the board, carrying it (the engine
    -- keeps that across restarts): tap the engine's own Y once to get back on.
    if st.desired and valid_pose() and SK.carrying_board() and st.remountedEpoch ~= st.epoch then
        st.remountedEpoch = st.epoch
        st.engineYFrames = 4
    end
    if st.desired and p.status == 3 and p.epoch == st.epoch then
        SK.dismount(m, "Skate engine error: " .. tostring(p.error), false)
    end
end

-- ---------------------------------------------------------------- the skating action
local FALLBACK = {
    air = CHAR_ANIM_JUMP_RIDING_SHELL,
    ground = CHAR_ANIM_RIDING_SHELL,
    wipeout = CHAR_ANIM_AIRBORNE_ON_STOMACH,
    walk = CHAR_ANIM_WALKING,
    idle = CHAR_ANIM_IDLE_HEAD_CENTER,
}
local function classic_animation(m, state, speed)
    local anim = FALLBACK.ground
    if state:find("Air") or state == "Boneless" then anim = FALLBACK.air
    elseif state:find("Wipeout") then anim = FALLBACK.wipeout
    elseif state:find("^Biped") or state == "OffBoardPushing" then anim = speed > 0.5 and FALLBACK.walk or FALLBACK.idle end
    set_character_animation(m, anim)
end

local function act_skate(m)
    if m.playerIndex ~= 0 then return 0 end
    if not st.desired then
        set_mario_action(m, ACT_IDLE, 0)
        return 1
    end
    m.vel.x, m.vel.y, m.vel.z = 0, 0, 0
    if not valid_pose() then
        -- Waiting for the engine (first mount loads the skater: a few seconds).
        set_character_animation(m, CHAR_ANIM_START_RIDING_SHELL)
        vec3f_copy(m.marioObj.header.gfx.pos, m.pos)
        vec3s_set(m.marioObj.header.gfx.angle, 0, m.faceAngle.y, 0)
        m.forwardVel = 0
        if SK.frame - st.mountFrame > 30 * 25 then
            SK.dismount(m, "Skate engine did not start. See skate\\host.log.")
            return 1
        end
        return 0
    end
    local p = st.pose
    local root = SK.mat(p.root)
    local x, y, z = SK.to_game(root.p)
    m.pos.x, m.pos.y, m.pos.z = x, y, z
    local pitch, yaw, roll = SK.angles(root)
    m.faceAngle.y = yaw
    local v = p.velocity
    m.vel.x, m.vel.y, m.vel.z = v[1] * S / 30, v[2] * S / 30, v[3] * S / 30
    m.forwardVel = math.sqrt(m.vel.x * m.vel.x + m.vel.z * m.vel.z)
    m.peakHeight = m.pos.y
    local gfx = m.marioObj.header.gfx
    vec3f_copy(gfx.pos, m.pos)
    vec3s_set(gfx.angle, pitch, yaw, roll)
    if not SK.rig_pose(m) then classic_animation(m, p.state, math.sqrt(v[1] * v[1] + v[3] * v[3])) end
    SK.board_update(true, SK.mat(p.board))

    -- Falling out of the level: back to the marker, or to the last grounded spot.
    local floorY = find_floor_height(x, y + 150, z)
    local deathPlane = m.floor ~= nil and m.floor.type == SURFACE_DEATH_PLANE and y < m.floorHeight + 2048
    if floorY < -10000 or deathPlane then
        if not (SK.cfg.fallToMarker and SK.return_to_marker(m, true)) and st.lastSafe ~= nil then
            local s = st.lastSafe
            SK.start_session(m, s[1], s[2], s[3], s[4])
            SK.say("Bailed off the map.", 2)
        end
    elseif not p.state:find("Air") and not p.state:find("Wipeout") and y - floorY < 30 and SK.frame % 15 == 0 then
        st.lastSafe = { x, y, z, SK.rad(yaw) }
    end
    return 0
end
hook_mario_action(ACT_SKATE, { every_frame = SK.safe("act_skate", act_skate) }, INT_FAST_ATTACK_OR_SHELL)

-- Anything else that takes Mario out of the skate action (damage, stars,
-- cutscenes, warps) ends the session.
hook_event(HOOK_ON_SET_MARIO_ACTION, SK.safe("set_action", function(m)
    if m.playerIndex ~= 0 or not st.desired or st.leaving then return end
    if m.action ~= ACT_SKATE and not SK.replay_owns_action(m.action) and m.action ~= ACT_SK_EDIT then
        SK.dismount(m, nil, true)
    end
end))

-- ---------------------------------------------------------------- Skate camera
local function skate_camera(m)
    if not st.desired or not st.cameraOn or not valid_pose() or st.pose.camera == nil then
        if SK.cameraFrozen and not SK.replay_active() then
            camera_unfreeze()
            set_override_fov(0)
            SK.cameraFrozen = false
        end
        return
    end
    local c = st.pose.camera
    local px, py, pz = c[1] * S, c[2] * S, c[3] * S
    local dx, dy, dz = c[10], c[11], c[12]
    -- Camera distance: slide along the view ray, keeping what it looks at.
    local k = SK.cfg.camDist or 1
    if k ~= 1 then
        local root = st.pose.root
        local tx, ty, tz = root[13] * S, root[14] * S + 100, root[15] * S
        local along = (tx - px) * dx + (ty - py) * dy + (tz - pz) * dz
        local back = along * (k - 1)
        px, py, pz = px - dx * back, py - dy * back, pz - dz * back
    end
    SK.set_camera(px, py, pz, px + dx * 500, py + dy * 500, pz + dz * 500, c[13] * (SK.cfg.camFov or 1))
end

--- Positions the game camera directly. fov: vertical degrees (nil keeps the game's).
function SK.set_camera(px, py, pz, fx, fy, fz, fov)
    camera_freeze()
    SK.cameraFrozen = true
    local l = gLakituState
    vec3f_set(l.pos, px, py, pz)
    vec3f_set(l.focus, fx, fy, fz)
    vec3f_set(l.curPos, px, py, pz)
    vec3f_set(l.curFocus, fx, fy, fz)
    vec3f_set(l.goalPos, px, py, pz)
    vec3f_set(l.goalFocus, fx, fy, fz)
    l.roll = 0
    l.yaw = SK.s16(math.atan(fx - px, fz - pz))
    if fov ~= nil then set_override_fov(SK.clamp(fov, 20, 120)) end
end

-- ---------------------------------------------------------------- session marker (Skate 4 style)
SK.marker = nil
local holdFrames = 0
local HOLD_TO_SET = 14

function SK.set_marker(m)
    SK.marker = {
        x = m.pos.x, y = m.pos.y, z = m.pos.z, yaw = m.faceAngle.y,
        skating = st.desired, level = level_key(),
    }
    play_sound(SOUND_MENU_CLICK_FILE_SELECT, SK.sound_pos())
    SK.say("Session marker set.", 2)
end

--- Returns to the marker. quiet: no message when there is none.
function SK.return_to_marker(m, quiet)
    local k = SK.marker
    if k == nil then
        if not quiet then SK.say("No session marker. Hold D-pad Up to set one.", 2) end
        return false
    end
    if k.level ~= level_key() then
        if not quiet then SK.say("The marker is in another area.", 2) end
        return false
    end
    play_sound(SOUND_MENU_CAMERA_ZOOM_IN, SK.sound_pos())
    if k.skating then
        if st.desired then
            SK.start_session(m, k.x, k.y, k.z, SK.rad(k.yaw))
            m.pos.x, m.pos.y, m.pos.z = k.x, k.y, k.z
        else
            m.faceAngle.y = k.yaw
            SK.mount(m, k.x, k.y, k.z, SK.rad(k.yaw))
        end
    else
        if st.desired then SK.dismount(m, nil) end
        m.pos.x, m.pos.y, m.pos.z = k.x, k.y, k.z
        m.vel.x, m.vel.y, m.vel.z = 0, 0, 0
        m.forwardVel = 0
        m.faceAngle.y = k.yaw
        set_mario_action(m, ACT_IDLE, 0)
        reset_camera(m.area.camera)
    end
    return true
end

local function marker_input(m)
    local up = SK.down(PAD.UP) or SK.key(VK_1)
    if up then
        holdFrames = holdFrames + 1
        if holdFrames == HOLD_TO_SET then SK.set_marker(m) end
    else
        if holdFrames > 0 and holdFrames < HOLD_TO_SET then SK.return_to_marker(m, false) end
        holdFrames = 0
    end
end
function SK.marker_hold() return holdFrames, HOLD_TO_SET end

-- ---------------------------------------------------------------- controller for Mario on foot
-- coopdx's own gamepad input may not see the controller; feed the XInput
-- state (read by the bridge) into Mario's controller. The D-pad and Y stay
-- with the skate features.
local padPrevDown = 0
local function feed_controller(m)
    local pad = SK.pad
    if not pad.present then return end
    local c = m.controller
    local down = 0
    local b = pad.buttons
    if (b & PAD.A) ~= 0 then down = down | A_BUTTON end
    if (b & PAD.B) ~= 0 then down = down | B_BUTTON end
    if (b & PAD.X) ~= 0 then down = down | (X_BUTTON or B_BUTTON) end
    if (b & PAD.START) ~= 0 then down = down | START_BUTTON end
    if (b & PAD.LB) ~= 0 then down = down | L_TRIG end
    if (b & PAD.RB) ~= 0 or pad.rt > 60 then down = down | R_TRIG end
    if pad.lt > 60 or (b & PAD.LS) ~= 0 then down = down | Z_TRIG end
    local rx, ry = SK.axis(pad.rx), SK.axis(pad.ry)
    if rx > 0.5 then down = down | R_CBUTTONS elseif rx < -0.5 then down = down | L_CBUTTONS end
    if ry > 0.5 then down = down | U_CBUTTONS elseif ry < -0.5 then down = down | D_CBUTTONS end
    local lx, ly = SK.axis(pad.lx), SK.axis(pad.ly)
    local sx, sy = lx * 64, ly * 64
    local mag = math.min(64, math.sqrt(sx * sx + sy * sy))
    if mag > c.stickMag then
        c.stickX, c.stickY, c.stickMag = sx, sy, mag
        c.rawStickX, c.rawStickY = math.floor(lx * 80), math.floor(ly * 80)
    end
    local pressed = down & ~padPrevDown
    local released = padPrevDown & ~down
    padPrevDown = down
    c.buttonDown = c.buttonDown | down
    c.buttonPressed = c.buttonPressed | pressed
    c.buttonReleased = c.buttonReleased | released
end

-- ---------------------------------------------------------------- per-frame driver
local function before_mario_update(m)
    if m.playerIndex ~= 0 then return end
    SK.frame = SK.frame + 1
    SK.poll_input()
    if not SK.menu_open() and not SK.replay_active() and not SK.dropper_active() then feed_controller(m) end
    exchange(m)
    if SK.replay_active() then
        SK.replay_input(m)
        return
    end
    if SK.menu_open() then
        SK.menu_input(m)
        return
    end
    if SK.dropper_active and SK.dropper_active() then
        SK.dropper_input(m)
        return
    end
    -- Board on/off: Y (controller) or J (keyboard).
    if SK.pressed(PAD.Y) or SK.key_pressed(VK_J) then
        if st.desired and valid_pose() and SK.carrying_board() then
            st.engineYFrames = 4 -- back onto the board (engine's own Y)
        elseif st.desired then SK.dismount(m, nil)
        elseif SK.can_mount(m) then SK.mount(m)
        else SK.say("Can't get on the board right now.", 2) end
    end
    marker_input(m)
    if SK.pressed(PAD.DOWN) or SK.key_pressed(VK_2) then SK.replay_open(m) end
    if SK.pressed(PAD.RIGHT) or SK.key_pressed(VK_3) then SK.menu_toggle() end
end

local function mario_update(m)
    if m.playerIndex ~= 0 then return end
    if SK.replay_active() then
        SK.replay_play(m)
        return
    end
    if SK.dropper_active() then return end
    if not st.desired then SK.board_update(false) end
    skate_camera(m)
    SK.replay_record(m)
end

hook_event(HOOK_BEFORE_MARIO_UPDATE, SK.safe("before_mario_update", before_mario_update))
hook_event(HOOK_MARIO_UPDATE, SK.safe("mario_update", mario_update))
hook_event(HOOK_ON_LEVEL_INIT, SK.safe("level_init", function()
    local m = gMarioStates[0]
    if st.desired then SK.dismount(m, nil, true) end
    st.lastSafe = nil
    SK.replay_clear()
end))

-- Keep coopdx's C-button camera from fighting the skate camera.
hook_event(HOOK_ON_SET_CAMERA_MODE, function(c, mode, frames)
    if st.desired and st.cameraOn and valid_pose() then return false end
end)

-- ---------------------------------------------------------------- HUD
local function text(t, x, y, scale, r, g, b, a)
    djui_hud_set_color(0, 0, 0, (a or 255) * 0.6)
    djui_hud_print_text(t, x + 2 * scale, y + 2 * scale, scale)
    djui_hud_set_color(r, g, b, a or 255)
    djui_hud_print_text(t, x, y, scale)
end
local function centered(t, y, scale, r, g, b, a)
    local w = djui_hud_measure_text(t) * scale
    text(t, (djui_hud_get_screen_width() - w) / 2, y, scale, r, g, b, a)
end
SK.hud_text, SK.hud_centered = text, centered

--- Control hints in a bar at the bottom: { {"A", "Play / pause"}, ... }.
--- Wraps onto extra rows; SK.hudBottom becomes the top of the bar.
function SK.hud_hints(list)
    local w, h = djui_hud_get_screen_width(), djui_hud_get_screen_height()
    local scale, gap, rowH, margin = 0.7, 34, 30, 24
    local rows, row, x = {}, {}, margin
    for _, item in ipairs(list) do
        local width = (djui_hud_measure_text(item[1]) + djui_hud_measure_text(" " .. item[2])) * scale
        if x + width > w - margin and #row > 0 then
            table.insert(rows, row)
            row, x = {}, margin
        end
        table.insert(row, { item[1], item[2], x })
        x = x + width + gap
    end
    if #row > 0 then table.insert(rows, row) end
    local top = h - #rows * rowH - 16
    djui_hud_set_color(0, 0, 0, 160)
    djui_hud_render_rect(0, top - 8, w, h - top + 8)
    for r, items in ipairs(rows) do
        local y = top + (r - 1) * rowH
        for _, it in ipairs(items) do
            text(it[1], it[3], y, scale, 255, 215, 90)
            text(" " .. it[2], it[3] + djui_hud_measure_text(it[1]) * scale, y, scale, 235, 235, 240)
        end
    end
    SK.hudBottom = math.min(SK.hudBottom or h, top - 8)
end

-- Trick chain for the current line ("Kickflip + 50-50 + Manual").
SK.chain = {}
function SK.chain_text()
    local c = SK.chain
    if #c == 0 then return "" end
    local first = math.max(1, #c - 4)
    local text = table.concat(c, " + ", first, #c)
    if first > 1 then text = "... + " .. text end
    return text
end

local function score_hud()
    local p = st.pose
    if not valid_pose() then return end
    if p.tricks ~= st.lastTricks then
        if (p.flags & 1) ~= 0 and #SK.chain > 0 and not st.chainActive then SK.chain = {} end
        local name = SK.trick_name(p.trick, p.flags)
        if name ~= "" and SK.chain[#SK.chain] ~= name then table.insert(SK.chain, name) end
        st.lastTricks = p.tricks
    end
    if (p.flags & 1) ~= 0 then st.chainActive = true
    elseif st.chainActive then st.chainActive = false; st.chainClear = SK.frame + 60 end
    if st.chainClear and SK.frame > st.chainClear and not st.chainActive then SK.chain = {}; st.chainClear = nil end
    -- Count landings and bails from the host's counters.
    if p.landed ~= st.lastLanded then
        if p.banked > 0 then
            st.score = st.score + p.banked
            st.popup = { text = "+" .. SK.fmt_score(p.banked), r = 120, g = 255, b = 120, untilFrame = SK.frame + 60 }
        end
        st.lastLanded = p.landed
    end
    if p.bailed ~= st.lastBailed then
        st.popup = { text = "Bail!", r = 255, g = 90, b = 90, untilFrame = SK.frame + 60 }
        st.lastBailed = p.bailed
    end
    local h = djui_hud_get_screen_height()
    if not SK.cfg.combo then return end
    if (p.flags & 1) ~= 0 then
        local name = SK.chain_text()
        if name ~= "" then centered(name, h - 190, 1.2, 255, 255, 255) end
        local line = SK.fmt_score(p.live)
        if p.multiplier > 1.01 then line = line .. string.format("  x%.1f", p.multiplier) end
        centered(line, h - 130, 1.3, 255, 220, 80)
    elseif st.popup and SK.frame < st.popup.untilFrame then
        centered(st.popup.text, h - 150, 1.6, st.popup.r, st.popup.g, st.popup.b)
    end
    local stance = ""
    if (p.flags & 2) ~= 0 then stance = "Switch" elseif (p.flags & 4) ~= 0 then stance = "Fakie" end
    text("Score " .. SK.fmt_score(st.score), 24, 20, 1.0, 255, 255, 255)
    if stance ~= "" then text(stance, 24, 52, 0.8, 200, 200, 255) end
end

local function on_hud()
    djui_hud_set_resolution(RESOLUTION_DJUI)
    djui_hud_set_font(FONT_NORMAL)
    SK.hudBottom = djui_hud_get_screen_height()
    if SK.replay_active() then
        SK.replay_hud()
    else
        if st.desired then
            if valid_pose() then score_hud()
            else centered("Getting on the board...", djui_hud_get_screen_height() * 0.7, 1.2, 255, 255, 255) end
        end
        local held, need = SK.marker_hold()
        if held > 3 and held < need then
            centered("Setting marker " .. string.rep("|", held), djui_hud_get_screen_height() * 0.25, 1.0, 255, 255, 120)
        end
        SK.menu_hud()
        if SK.dropper_hud then SK.dropper_hud() end
    end
    local y = SK.hudBottom - 40
    for i = #SK.messages, 1, -1 do
        local msg = SK.messages[i]
        if SK.frame < msg.until_frame then
            text(msg.text, 24, y, 0.8, 255, 255, 255)
            y = y - 30
        end
    end
end
hook_event(HOOK_ON_HUD_RENDER, SK.safe("hud", on_hud))

SK.menu_apply()

if not SK.native then
    SK.say("Skate 64: bridge not loaded. Copy discord_game_sdk.dll from the Skate 64 package.", 10)
else
    SK.log("Skate 64 mod loaded, bridge v" .. tostring(sk_version()))
    SK.say("Skate 64 ready. Press Y (or J) to get on the board.", 6)
end
