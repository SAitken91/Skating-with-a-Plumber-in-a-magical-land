-- Trainer extras: noclip, god mode, characters, knockback options and the
-- Skate 3 board sounds (rolling and grind loops, pops, landings, pushes, bails).

local PAD = SK.PAD
local VK_Q, VK_E = 0x51, 0x45

-- ---------------------------------------------------------------- noclip
ACT_SK_NOCLIP = allocate_mario_action(ACT_GROUP_AIRBORNE | ACT_FLAG_AIR | ACT_FLAG_INTANGIBLE | ACT_FLAG_INVULNERABLE)
local NOCLIP_SPEED = { 10, 25, 55, 120 }

function SK.noclip_active() return gMarioStates[0].action == ACT_SK_NOCLIP end

function SK.noclip_toggle(m)
    if m.action == ACT_SK_NOCLIP then
        local floorY = find_floor_height(m.pos.x, m.pos.y + 100, m.pos.z)
        if floorY > -10000 and m.pos.y - floorY < 60 then m.pos.y = floorY end
        set_mario_action(m, ACT_FREEFALL, 0)
        SK.say("Noclip off.", 2)
        return
    end
    if SK.state.desired then SK.dismount(m, nil) end
    set_mario_action(m, ACT_SK_NOCLIP, 0)
    SK.say("Noclip on: stick moves, A/E up, Z/B/Q down, X or R faster.", 4)
end

hook_mario_action(ACT_SK_NOCLIP, { every_frame = SK.safe("noclip", function(m)
    if m.playerIndex ~= 0 then return 0 end
    local speed = NOCLIP_SPEED[SK.cfg.noclipSpeed] or 25
    local buttons = m.controller.buttonDown
    if (buttons & (X_BUTTON | R_TRIG)) ~= 0 then speed = speed * 2.5 end
    -- Same direction Mario would run (stick relative to the camera).
    local mag = SK.clamp(m.intendedMag / 32, 0, 1)
    local yaw = SK.rad(m.intendedYaw)
    local dx, dz = math.sin(yaw) * mag, math.cos(yaw) * mag
    local up = 0
    if (buttons & A_BUTTON) ~= 0 or SK.key(VK_E) then up = 1 end
    if (buttons & (Z_TRIG | B_BUTTON)) ~= 0 or SK.key(VK_Q) then up = -1 end
    m.pos.x = m.pos.x + dx * speed
    m.pos.z = m.pos.z + dz * speed
    m.pos.y = m.pos.y + up * speed
    m.vel.x, m.vel.y, m.vel.z = 0, 0, 0
    m.forwardVel = 0
    if math.abs(dx) + math.abs(dz) > 0.1 then m.faceAngle.y = SK.s16(math.atan(dx, dz)) end
    set_character_animation(m, CHAR_ANIM_IDLE_HEAD_CENTER)
    vec3f_copy(m.marioObj.header.gfx.pos, m.pos)
    vec3s_set(m.marioObj.header.gfx.angle, 0, m.faceAngle.y, 0)
    m.peakHeight = m.pos.y
    return 0
end) })

-- ---------------------------------------------------------------- god mode / knockback
local DAMAGE = {}
for _, name in ipairs({ "INTERACT_DAMAGE", "INTERACT_SHOCK", "INTERACT_FLAME", "INTERACT_SNUFIT_BULLET", "INTERACT_MR_BLIZZARD",
    "INTERACT_CLAM_OR_BUBBA", "INTERACT_UNKNOWN_08", "INTERACT_STRONG_WIND", "INTERACT_BULLY" }) do
    if _G[name] ~= nil then DAMAGE[_G[name]] = true end
end

hook_event(HOOK_ALLOW_INTERACT, function(m, o, interactType)
    if m.playerIndex ~= 0 then return end
    if not DAMAGE[interactType] then return end
    if SK.cfg.god then return false end
    if SK.state.desired and not SK.cfg.knockOff then return false end
end)

hook_event(HOOK_ALLOW_HAZARD_SURFACE, function(m, hazard)
    if m.playerIndex == 0 and SK.cfg.god then return false end
end)

hook_event(HOOK_MARIO_UPDATE, function(m)
    if m.playerIndex ~= 0 or not SK.cfg.god then return end
    m.health = 0x880
    m.hurtCounter = 0
    m.healCounter = 0
end)

-- ---------------------------------------------------------------- characters
local currentCharacter = nil
function SK.apply_character(index)
    if index == currentCharacter then return end
    currentCharacter = index
    gNetworkPlayers[0].overrideModelIndex = index
    -- A different body: read its parts again on the next pose.
    SK.rig.ready, SK.rig.failed = false, nil
end

-- ---------------------------------------------------------------- sounds
local samples = {}
local function sample_set(base, count)
    local list = {}
    for i = 1, count do
        local name = i == 1 and (base .. ".ogg") or string.format("%s_%d.ogg", base, i)
        local s = audio_sample_load(name)
        if s ~= nil then table.insert(list, s) end
    end
    return list
end
local loaded = false
local roll, grind = nil, nil
local function load_sounds()
    if loaded then return end
    loaded = true
    samples.pop = sample_set("board_pop", 4)
    samples.land = sample_set("board_land", 4)
    samples.push = sample_set("board_push", 4)
    samples.bail = sample_set("board_bail", 2)
    roll = audio_stream_load("board_roll.ogg")
    grind = audio_stream_load("board_grind.ogg")
    if roll then audio_stream_set_looping(roll, true) end
    if grind then audio_stream_set_looping(grind, true) end
    SK.log(string.format("sounds: %d pops, %d landings, %d pushes, %d bails, roll %s, grind %s",
        #samples.pop, #samples.land, #samples.push, #samples.bail, tostring(roll ~= nil), tostring(grind ~= nil)))
end

local function play(list, volume)
    if list == nil or #list == 0 or SK.cfg.volume <= 0 then return end
    local s = list[math.random(#list)]
    audio_sample_play(s, gMarioStates[0].pos, SK.clamp(volume * SK.cfg.volume, 0, 1))
end

local snd = { state = "", rolling = false, grinding = false, bails = 0, lastPush = 0 }
local function stop_loops()
    if roll and snd.rolling then audio_stream_pause(roll) end
    if grind and snd.grinding then audio_stream_pause(grind) end
    snd.rolling, snd.grinding = false, false
end

local function update_sounds(m)
    local st = SK.state
    if not st.desired or not SK.valid_pose() or SK.replay_active() or SK.menu_open() or is_game_paused() then
        stop_loops()
        snd.state = ""
        return
    end
    load_sounds()
    local p = st.pose
    local state = p.state
    local v = p.velocity
    local speed = math.sqrt(v[1] * v[1] + v[3] * v[3])
    local air = state:find("Air") ~= nil or state == "Boneless"
    local grinding = state:find("^Grind") ~= nil
    local onBoard = not state:find("^Biped") and state ~= "OffBoardPushing" and not state:find("Wipeout")
    local was = snd.state
    if was ~= "" then
        local wasAir = was:find("Air") ~= nil or was == "Boneless"
        if air and not wasAir and v[2] > 0.5 then play(samples.pop, 0.9) end
        if not air and wasAir and onBoard then play(samples.land, SK.clamp(0.5 + snd.fall / 8, 0.5, 1)) end
        if grinding and not was:find("^Grind") then play(samples.land, 0.7) end
    end
    if air then snd.fall = math.max(snd.fall or 0, -v[2]) else snd.fall = 0 end
    if p.bailed ~= snd.bails then
        if snd.bails ~= 0 or p.bailed == 1 then play(samples.bail, 1) end
        snd.bails = p.bailed
    end
    -- Pushes: A (or W) on the ground.
    if not air and onBoard and (SK.pressed(PAD.A) or SK.key_pressed(0x57)) and SK.frame - snd.lastPush > 8 then
        play(samples.push, 0.8)
        snd.lastPush = SK.frame
    end
    -- Loops: rolling grain follows speed; the grind loop runs while grinding.
    local vol = SK.cfg.volume
    local rolling = onBoard and not air and not grinding and speed > 0.3
    if roll then
        if rolling then
            local level = SK.clamp(speed / 8, 0.15, 1) * vol
            if not snd.rolling then audio_stream_play(roll, false, level) end
            audio_stream_set_volume(roll, level)
            audio_stream_set_frequency(roll, SK.clamp(0.7 + speed / 12, 0.7, 1.5))
        elseif snd.rolling then audio_stream_pause(roll) end
    end
    if grind then
        if grinding then
            if not snd.grinding then audio_stream_play(grind, true, 0.8 * vol) end
            audio_stream_set_volume(grind, 0.8 * vol)
        elseif snd.grinding then audio_stream_pause(grind) end
    end
    snd.rolling, snd.grinding = rolling, grinding
    snd.state = state
end

hook_event(HOOK_MARIO_UPDATE, SK.safe("sounds", function(m)
    if m.playerIndex == 0 then update_sounds(m) end
end))
