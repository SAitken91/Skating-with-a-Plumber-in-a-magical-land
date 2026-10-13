-- Skate Trainer menu (D-pad Right / 3). Pages: main, physics trainer,
-- collisions and bails, camera and HUD. Settings persist in skate\data\settings.txt.

local PAD = SK.PAD
local VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT, VK_RETURN, VK_BACK, VK_3 = 0x26, 0x28, 0x25, 0x27, 0x0D, 0x08, 0x33

-- Physics multipliers, in the order the host expects (TrainerTuning).
local TUNING = {
    { key = "pop", label = "Ollie height" },
    { key = "boneless", label = "Boneless height" },
    { key = "grindPop", label = "Grind pop" },
    { key = "offboardJump", label = "Off-board jump" },
    { key = "pushSpeed", label = "Push top speed" },
    { key = "pushPower", label = "Push power" },
    { key = "braking", label = "Braking" },
    { key = "steering", label = "Steering" },
    { key = "turnPower", label = "Turn power" },
    { key = "grip", label = "Grip" },
    { key = "wobble", label = "Speed wobble" },
    { key = "manualDrag", label = "Manual drag" },
}

local PRESETS = {
    { name = "Default" },
    { name = "Pro", pop = 1.3, boneless = 1.2, grindPop = 1.2, pushSpeed = 1.25, pushPower = 1.3, steering = 1.15, turnPower = 1.2, grip = 1.1, wobble = 0.5, manualDrag = 0.7 },
    { name = "Big air", pop = 2.4, boneless = 2.2, grindPop = 1.8, offboardJump = 1.8, pushSpeed = 1.2, turnPower = 1.3 },
    { name = "Speed demon", pop = 1.2, pushSpeed = 2.2, pushPower = 2.0, braking = 1.5, steering = 0.9, grip = 1.3, wobble = 0.3 },
    { name = "Chill cruiser", pop = 0.9, pushSpeed = 0.7, pushPower = 0.8, steering = 1.2, grip = 1.4, wobble = 0.2, manualDrag = 0.5 },
    { name = "Moon", pop = 4.0, boneless = 4.0, grindPop = 3.0, offboardJump = 3.0, pushSpeed = 1.5, turnPower = 1.5, manualDrag = 0.3 },
}

local cfg = {
    camera = true, camDist = 1.0, camFov = 1.0, poses = true, combo = true, keyboard = true, volume = 0.8,
    hallOfMeat = false, holdFakie = false, knockOff = true, fallToMarker = true,
    god = false, noclipSpeed = 2, character = 0, preset = 1,
}
for _, t in ipairs(TUNING) do cfg[t.key] = 1.0 end
SK.cfg = cfg

local function send_tuning()
    if not SK.native then return end
    local words = {}
    for i, t in ipairs(TUNING) do words[i] = cfg[t.key] end
    words[13] = cfg.holdFakie and 1 or 0
    words[14] = cfg.hallOfMeat and 1 or 0
    sk_tuning(words)
end

local function apply()
    if SK.state == nil then return end
    SK.state.cameraOn = cfg.camera
    SK.rig.enabled = cfg.poses
    SK.state.keyboard = cfg.keyboard
    send_tuning()
    if SK.apply_character then SK.apply_character(cfg.character) end
end
SK.menu_apply = apply

local function save()
    if not SK.native then return end
    local out = {}
    for k, v in pairs(cfg) do table.insert(out, k .. "=" .. tostring(v)) end
    table.sort(out)
    sk_write("settings", table.concat(out, "\n"))
end

local function load()
    if not SK.native then return end
    local text = sk_read("settings")
    if text == nil then return end
    for k, v in text:gmatch("([%w_]+)=([^\n]+)") do
        if cfg[k] ~= nil then
            if type(cfg[k]) == "boolean" then cfg[k] = (v == "true")
            elseif type(cfg[k]) == "number" then cfg[k] = tonumber(v) or cfg[k] end
        end
    end
end

local function onoff(v) return v and "On" or "Off" end
local function times(v) return string.format("%.1fx", v) end
local function step(v, d, lo, hi) return math.floor(SK.clamp(v + d, lo, hi) * 10 + 0.5) / 10 end
local function toggle(key) return function(d) cfg[key] = not cfg[key] end end
local function multiplier(key, lo, hi)
    return function(d) cfg[key] = step(cfg[key], (d == 0 and 1 or d) * 0.1, lo or 0.1, hi or 5) end
end
local function action(fn) return function(d) if d == 0 then fn() end end end

local CHARACTERS = { "Mario", "Luigi", "Toad", "Waluigi", "Wario" }
local NOCLIP = { "Slow", "Normal", "Fast", "Turbo" }

local pages = {}
local menu = { open = false, page = "main", index = 1, repeatFrames = 0, stack = {} }
local function go(page) return action(function()
    table.insert(menu.stack, { page = menu.page, index = menu.index })
    menu.page, menu.index = page, 1
end) end
local function back()
    local top = table.remove(menu.stack)
    if top then menu.page, menu.index = top.page, top.index else SK.menu_toggle() end
end

pages.main = { title = "SKATE TRAINER", items = {
    { label = "Board", value = function() return SK.state.desired and "Get off" or "Get on" end, change = action(function()
        local m = gMarioStates[0]
        SK.menu_toggle()
        if SK.state.desired then SK.dismount(m, nil) elseif SK.can_mount(m) then SK.mount(m) else SK.say("Can't get on the board right now.", 2) end
    end) },
    { label = "Physics trainer", value = function() return PRESETS[cfg.preset] and PRESETS[cfg.preset].name or "Custom" end, change = go("trainer") },
    { label = "Object dropper", value = function() return SK.dropper_count and (SK.dropper_count() .. " placed") or "" end, change = action(function()
        SK.menu_toggle()
        if SK.dropper_open then SK.dropper_open(gMarioStates[0]) end
    end) },
    { label = "Noclip", value = function() return onoff(SK.noclip_active and SK.noclip_active()) end, change = action(function()
        SK.menu_toggle()
        if SK.noclip_toggle then SK.noclip_toggle(gMarioStates[0]) end
    end) },
    { label = "Noclip speed", value = function() return NOCLIP[cfg.noclipSpeed] end, change = function(d) cfg.noclipSpeed = (cfg.noclipSpeed - 1 + (d == 0 and 1 or d)) % #NOCLIP + 1 end },
    { label = "God mode", value = function() return onoff(cfg.god) end, change = toggle("god") },
    { label = "Character", value = function() return CHARACTERS[cfg.character + 1] end, change = function(d) cfg.character = (cfg.character + (d == 0 and 1 or d)) % #CHARACTERS end },
    { label = "Collisions and bails", value = function() return "" end, change = go("bails") },
    { label = "Camera, HUD and sound", value = function() return "" end, change = go("view") },
    { label = "Set session marker", value = function() return SK.marker and "Set" or "None" end, change = action(function() SK.set_marker(gMarioStates[0]) end) },
    { label = "Go to session marker", value = function() return "" end, change = action(function() SK.menu_toggle(); SK.return_to_marker(gMarioStates[0], false) end) },
    { label = "Clear session marker", value = function() return "" end, change = action(function() SK.marker = nil; SK.say("Marker cleared.", 2) end) },
    { label = "Replay editor", value = function() return "" end, change = action(function() SK.menu_toggle(); SK.replay_open(gMarioStates[0]) end) },
    { label = "Reset score", value = function() return SK.fmt_score(SK.state.score) end, change = action(function() SK.state.score = 0 end) },
    { label = "Close", value = function() return "" end, change = action(function() SK.menu_toggle() end) },
} }

local trainer = {
    { label = "Preset", value = function() return PRESETS[cfg.preset] and PRESETS[cfg.preset].name or "Custom" end, change = function(d)
        local i = cfg.preset
        if PRESETS[i] == nil then i = 1 end
        cfg.preset = (i - 1 + (d == 0 and 1 or d)) % #PRESETS + 1
        local p = PRESETS[cfg.preset]
        for _, t in ipairs(TUNING) do cfg[t.key] = p[t.key] or 1.0 end
    end },
}
for _, t in ipairs(TUNING) do
    local adjust = multiplier(t.key, 0.1, 5)
    table.insert(trainer, { label = t.label, value = function() return times(cfg[t.key]) end, change = function(d)
        adjust(d)
        cfg.preset = 0 -- custom
    end })
end
table.insert(trainer, { label = "Hold fakie", value = function() return onoff(cfg.holdFakie) end, change = toggle("holdFakie") })
table.insert(trainer, { label = "Reset all to default", value = function() return "" end, change = action(function()
    for _, t in ipairs(TUNING) do cfg[t.key] = 1.0 end
    cfg.holdFakie, cfg.preset = false, 1
    SK.say("Physics reset to default.", 2)
end) })
table.insert(trainer, { label = "Back", value = function() return "" end, change = action(back) })
pages.trainer = { title = "PHYSICS TRAINER", items = trainer }

pages.bails = { title = "COLLISIONS AND BAILS", items = {
    { label = "Hall of Meat (bail control)", value = function() return onoff(cfg.hallOfMeat) end, change = toggle("hallOfMeat") },
    { label = "Enemy hits knock you off", value = function() return onoff(cfg.knockOff) end, change = toggle("knockOff") },
    { label = "Falling off the map returns to marker", value = function() return onoff(cfg.fallToMarker) end, change = toggle("fallToMarker") },
    { label = "Back", value = function() return "" end, change = action(back) },
} }

pages.view = { title = "CAMERA, HUD AND SOUND", items = {
    { label = "Skate camera", value = function() return onoff(cfg.camera) end, change = toggle("camera") },
    { label = "Camera distance", value = function() return times(cfg.camDist) end, change = multiplier("camDist", 0.5, 3) },
    { label = "Field of view", value = function() return times(cfg.camFov) end, change = multiplier("camFov", 0.5, 1.6) },
    { label = "Full-body Skate poses", value = function() return onoff(cfg.poses) end, change = toggle("poses") },
    { label = "Combo display", value = function() return onoff(cfg.combo) end, change = toggle("combo") },
    { label = "Skate sounds", value = function() return string.format("%d%%", math.floor(cfg.volume * 100 + 0.5)) end, change = function(d)
        if d == 0 then
            cfg.volume = cfg.volume >= 0.99 and 0 or math.min(1, math.floor((cfg.volume + 0.1) * 10 + 0.5) / 10)
        else
            cfg.volume = SK.clamp(math.floor((cfg.volume + d * 0.1) * 10 + 0.5) / 10, 0, 1)
        end
    end },
    { label = "Keyboard skating (WASD, K, Q/E)", value = function() return onoff(cfg.keyboard) end, change = toggle("keyboard") },
    { label = "Back", value = function() return "" end, change = action(back) },
} }

function SK.menu_open() return menu.open end
function SK.menu_toggle()
    menu.open = not menu.open
    if menu.open then
        menu.page, menu.index, menu.stack = "main", 1, {}
    else
        apply()
        save()
    end
    play_sound(menu.open and SOUND_MENU_PAUSE or SOUND_MENU_PAUSE_2, SK.sound_pos())
end

local function nav(button, vk) return SK.pressed(button) or SK.key_pressed(vk) end

function SK.menu_input(m)
    local items = pages[menu.page].items
    local d = 0
    local ly = SK.axis(SK.pad.ly)
    local up = nav(PAD.UP, VK_UP) or (ly > 0.6 and menu.repeatFrames == 0)
    local down = nav(PAD.DOWN, VK_DOWN) or (ly < -0.6 and menu.repeatFrames == 0)
    if up then menu.index = (menu.index - 2) % #items + 1; menu.repeatFrames = 6 end
    if down then menu.index = menu.index % #items + 1; menu.repeatFrames = 6 end
    if math.abs(ly) < 0.3 then menu.repeatFrames = 0 elseif menu.repeatFrames > 0 then menu.repeatFrames = menu.repeatFrames - 1 end
    if nav(PAD.LEFT, VK_LEFT) then d = -1 end
    if nav(PAD.RIGHT, VK_RIGHT) then d = 1 end
    local item = items[menu.index]
    if d ~= 0 then
        item.change(d)
        apply()
        play_sound(SOUND_MENU_CHANGE_SELECT, SK.sound_pos())
    elseif SK.pressed(PAD.A) or SK.key_pressed(VK_RETURN) then
        item.change(0)
        apply()
        play_sound(SOUND_MENU_CLICK_FILE_SELECT, SK.sound_pos())
    elseif SK.pressed(PAD.B) or SK.key_pressed(VK_BACK) then
        back()
    elseif SK.pressed(PAD.BACK) or SK.key_pressed(VK_3) then
        SK.menu_toggle()
    end
end

function SK.menu_hud()
    if not menu.open then return end
    local page = pages[menu.page]
    local items = page.items
    local w, h = djui_hud_get_screen_width(), djui_hud_get_screen_height()
    local rowH = 32
    local visible = math.min(#items, math.floor((h - 260) / rowH))
    local first = SK.clamp(menu.index - math.floor(visible / 2), 1, math.max(1, #items - visible + 1))
    local bw = 720
    local bh = 80 + visible * rowH + 10
    local x, y = (w - bw) / 2, math.max(20, (h - 90 - bh) / 2)
    djui_hud_set_color(10, 10, 20, 215)
    djui_hud_render_rect(x, y, bw, bh)
    SK.hud_text(page.title, x + 24, y + 16, 1.1, 255, 210, 60)
    for row = 0, visible - 1 do
        local i = first + row
        local item = items[i]
        if item == nil then break end
        local ry = y + 76 + row * rowH
        if i == menu.index then
            djui_hud_set_color(255, 255, 255, 40)
            djui_hud_render_rect(x + 12, ry - 2, bw - 24, rowH)
        end
        local c = i == menu.index and 255 or 195
        SK.hud_text(item.label, x + 28, ry, 0.75, c, c, c)
        local v = item.value()
        if v ~= "" then
            local vw = djui_hud_measure_text(v) * 0.75
            SK.hud_text(v, x + bw - 28 - vw, ry, 0.75, 255, 220, 120)
        end
    end
    if first > 1 then SK.hud_text("^", x + bw / 2, y + 56, 0.6, 200, 200, 200) end
    if first + visible - 1 < #items then SK.hud_text("v", x + bw / 2, y + bh - 58, 0.6, 200, 200, 200) end
    SK.hud_hints({ { "Up / Down", "Select" }, { "Left / Right", "Change" }, { "A", "Choose" }, { "B", "Back" }, { "View", "Close" } })
end

load()
