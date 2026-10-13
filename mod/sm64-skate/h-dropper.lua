-- Object dropper (Skate 3 style). Pieces are solid for Mario (runtime
-- collision surfaces) and for the skate engine (extra triangles; the rail
-- finder turns their lips into grind rails). Placed pieces are saved per area
-- in skate\data\objects_<level>.txt and come back when you return.
--
-- Controller: left stick move, LB/RB rotate, LT/RT lower/raise, D-pad Left/Right
-- change piece, A place, Y pick up the highlighted piece, X delete it,
-- D-pad Up undo, right stick camera, B exit.
-- Keyboard: arrows move, Q/E rotate, R/F raise/lower, [/] change piece,
-- Enter place, G pick up, Delete remove, U undo, Backspace exit.

local PAD = SK.PAD
local MAX_OBJECTS = 32
local VK = { LEFT = 0x25, UP = 0x26, RIGHT = 0x27, DOWN = 0x28, Q = 0x51, E = 0x45, R = 0x52, F = 0x46, LBR = 0xDB, RBR = 0xDD,
    RETURN = 0x0D, G = 0x47, DELETE = 0x2E, U = 0x55, BACK = 0x08 }

-- ---------------------------------------------------------------- pieces (centimetres = SM64 units; ramps rise toward +Z)
local WOOD, CONCRETE, METAL, DARK, PAINT = { 200, 160, 105 }, { 185, 182, 175 }, { 170, 175, 185 }, { 95, 95, 105 }, { 60, 120, 200 }

local function wedge(mesh, w, len, h, color, z0)
    z0 = z0 or -len / 2
    local z1 = z0 + len
    local x = w / 2
    mesh:quad({ -x, 0, z0 }, { -x, h, z1 }, { x, h, z1 }, { x, 0, z0 }, color)       -- slope
    mesh:quad({ -x, 0, z1 }, { x, 0, z1 }, { x, h, z1 }, { -x, h, z1 }, DARK)        -- back
    mesh:quad({ x, 0, z0 }, { x, h, z1 }, { x, 0, z1 }, { x, 0, z1 }, DARK)          -- right side (triangle)
    mesh:quad({ -x, 0, z0 }, { -x, 0, z1 }, { -x, h, z1 }, { -x, h, z1 }, DARK)      -- left side (triangle)
end

local PIECES = {
    { name = "Kicker", build = function(m) wedge(m, 100, 130, 35, WOOD) end },
    { name = "Big kicker", build = function(m) wedge(m, 170, 240, 95, WOOD) end },
    { name = "Bank ramp", build = function(m) wedge(m, 320, 320, 120, CONCRETE) end },
    { name = "Quarter pipe", build = function(m)
        local w, r, steps = 340, 190, 8
        local x = w / 2
        local prev = { 0, 0 } -- {z, y} along the curve, starting flat at z = -r
        for i = 1, steps do
            local a = (i / steps) * (math.pi / 2)
            local cur = { math.sin(a) * r, (1 - math.cos(a)) * r }
            m:quad({ -x, prev[2], prev[1] - r }, { -x, cur[2], cur[1] - r }, { x, cur[2], cur[1] - r }, { x, prev[2], prev[1] - r }, WOOD)
            m:quad({ x, 0, prev[1] - r }, { x, prev[2], prev[1] - r }, { x, cur[2], cur[1] - r }, { x, 0, cur[1] - r }, DARK)
            m:quad({ -x, 0, prev[1] - r }, { -x, 0, cur[1] - r }, { -x, cur[2], cur[1] - r }, { -x, prev[2], prev[1] - r }, DARK)
            prev = cur
        end
        m:box(0, r - 3, 30, x, 3, 30, WOOD)          -- deck
        m:box(0, r + 2, 2, x, 3, 3, METAL)           -- coping
        m:quad({ -x, 0, 60 }, { x, 0, 60 }, { x, r, 60 }, { -x, r, 60 }, DARK) -- back wall
    end },
    { name = "Funbox", build = function(m)
        m:box(0, 22, 0, 90, 22, 70, CONCRETE)
        wedge(m, 180, 110, 44, CONCRETE, -180)
        local back = SK.mesh(function(p) return m.transform and m.transform({ p[1], p[2], -p[3] }) or { p[1], p[2], -p[3] } end)
        wedge(back, 180, 110, 44, CONCRETE, -180)
        for _, q in ipairs(back.quads) do table.insert(m.quads, { q[1], q[4], q[3], q[2], q[5] }) end
        m:box(0, 45, 0, 90, 1.5, 1.5, METAL)
    end },
    { name = "Ledge", build = function(m)
        m:box(0, 22, 0, 160, 22, 25, CONCRETE)
        m:box(0, 45, 24, 160, 1.5, 1.5, METAL)
        m:box(0, 45, -24, 160, 1.5, 1.5, METAL)
    end },
    { name = "Manual pad", build = function(m) m:box(0, 8, 0, 130, 8, 65, PAINT) end },
    { name = "Flat rail", build = function(m)
        m:box(0, 36, 0, 160, 2.5, 2.5, METAL)
        m:box(-140, 17, 0, 2.5, 17, 2.5, DARK)
        m:box(140, 17, 0, 2.5, 17, 2.5, DARK)
        m:box(-140, 1, 0, 12, 1, 12, DARK)
        m:box(140, 1, 0, 12, 1, 12, DARK)
    end },
}

local function transform(x, y, z, yaw)
    local s, c = math.sin(SK.rad(yaw)), math.cos(SK.rad(yaw))
    return function(p) return { x + p[1] * c + p[3] * s, y + p[2], z - p[1] * s + p[3] * c } end
end

local function piece_mesh(mesh, kind, x, y, z, yaw, tint)
    local sub = SK.mesh(transform(x, y, z, yaw))
    PIECES[kind].build(sub)
    for _, q in ipairs(sub.quads) do
        if tint then q[5] = { math.floor(q[5][1] * tint[1]), math.floor(q[5][2] * tint[2]), math.floor(q[5][3] * tint[3]) } end
        table.insert(mesh.quads, q)
    end
    return sub
end

-- ---------------------------------------------------------------- placed pieces
local placed = {}         -- { kind, x, y, z, yaw }
local surfaces = {}       -- runtime collision surfaces of all placed pieces
local levelKey = nil
local drawable = nil
local ed = nil            -- editor state while the dropper is open

function SK.dropper_count() return #placed end
function SK.dropper_active() return ed ~= nil end

local function current_level()
    local np = gNetworkPlayers[0]
    return np.currLevelNum * 100 + np.currAreaIndex
end

local function rebuild_display()
    local mesh = SK.mesh()
    for i, p in ipairs(placed) do
        local tint = nil
        if ed and ed.highlight == i then tint = { 1.3, 0.55, 0.55 } end
        piece_mesh(mesh, p.kind, p.x, p.y, p.z, p.yaw, tint)
    end
    if ed then piece_mesh(mesh, ed.kind, ed.x, ed.y, ed.z, ed.yaw, { 0.55, 1.35, 0.6 }) end
    if #mesh.quads == 0 then
        if drawable then SK.drawable_place(drawable, nil) end
        return
    end
    local gfx = SK.upload_mesh("sk_dropper", mesh, 1)
    drawable = drawable or SK.drawable("dropper", gfx)
    drawable.gfx = gfx
end

local function show()
    if drawable and (#placed > 0 or ed) then SK.drawable_place(drawable, 0, 0, 0, 0, 0, 0, 1) end
end

--- Collision for Mario and the engine from the placed pieces.
local function rebuild_collision()
    local S = SK.S
    local e = { tris = {}, count = 0, revision = SK.extra.revision + 1 }
    SK.suppressCapture = true
    for _, s in ipairs(surfaces) do smlua_collision_delete_surface(s) end
    surfaces = {}
    for _, p in ipairs(placed) do
        local mesh = SK.mesh()
        local sub = piece_mesh(mesh, p.kind, p.x, p.y, p.z, p.yaw)
        for _, t in ipairs(sub:triangles()) do
            local a, b, c = t[1], t[2], t[3]
            -- Skip degenerate triangles (the wedge sides are triangles stored as quads).
            local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
            local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
            local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
            if nx * nx + ny * ny + nz * nz > 1 then
                local s = smlua_collision_add_surface(false, SURFACE_DEFAULT,
                    { x = a[1], y = a[2], z = a[3] }, { x = b[1], y = b[2], z = b[3] }, { x = c[1], y = c[2], z = c[3] })
                if s then table.insert(surfaces, s) end
                local n = #e.tris
                e.tris[n + 1], e.tris[n + 2], e.tris[n + 3] = a[1] / S, a[2] / S, a[3] / S
                e.tris[n + 4], e.tris[n + 5], e.tris[n + 6] = b[1] / S, b[2] / S, b[3] / S
                e.tris[n + 7], e.tris[n + 8], e.tris[n + 9] = c[1] / S, c[2] / S, c[3] / S
                e.count = e.count + 1
            end
        end
    end
    SK.suppressCapture = false
    SK.extra = e
end

local function save()
    if not SK.native or levelKey == nil then return end
    local lines = {}
    for _, p in ipairs(placed) do table.insert(lines, string.format("%d %.1f %.1f %.1f %d", p.kind, p.x, p.y, p.z, p.yaw)) end
    sk_write("objects_" .. levelKey, table.concat(lines, "\n"))
end

local function load(key)
    placed = {}
    if not SK.native then return end
    local text = sk_read("objects_" .. key)
    if text == nil then return end
    for kind, x, y, z, yaw in text:gmatch("(%d+) (%S+) (%S+) (%S+) (%-?%d+)") do
        kind = tonumber(kind)
        if PIECES[kind] and #placed < MAX_OBJECTS then
            table.insert(placed, { kind = kind, x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw) })
        end
    end
end

-- A new area replaced the static collision (and wiped our surfaces): restore this area's pieces.
function SK.on_area_geometry()
    local key = current_level()
    surfaces = {} -- already gone with the old area
    if key ~= levelKey then
        levelKey = key
        load(key)
    end
    drawable = nil
    rebuild_collision()
    rebuild_display()
end

-- ---------------------------------------------------------------- editor
ACT_SK_EDIT = allocate_mario_action(ACT_GROUP_CUTSCENE | ACT_FLAG_INTANGIBLE | ACT_FLAG_INVULNERABLE)
hook_mario_action(ACT_SK_EDIT, { every_frame = function(m)
    set_character_animation(m, CHAR_ANIM_IDLE_HEAD_CENTER)
    return 0
end })

local function snap(x, y, z)
    local floorY = find_floor_height(x, y + 400, z)
    if floorY < -10000 then return y end
    return floorY
end

function SK.dropper_open(m)
    local yaw = m.faceAngle.y
    local x, z = m.pos.x + math.sin(SK.rad(yaw)) * 400, m.pos.z + math.cos(SK.rad(yaw)) * 400
    ed = {
        kind = 1, x = x, z = z, y = snap(x, m.pos.y, z), lift = 0, yaw = yaw, camYaw = yaw + 0x8000, camDist = 900,
        wasSkating = SK.state.desired, restoreAction = m.action, highlight = nil, rotHold = 0,
    }
    ed.baseY = ed.y
    set_mario_action(m, ACT_SK_EDIT, 0)
    rebuild_display()
    SK.say("Object dropper: A place, D-pad Left/Right change piece, B exit.", 4)
end

local function close(m)
    ed = nil
    rebuild_display()
    save()
    camera_unfreeze()
    set_override_fov(0)
    SK.cameraFrozen = false
    if SK.state.desired then
        set_mario_action(m, ACT_SKATE, 0)
    else
        set_mario_action(m, ACT_IDLE, 0)
    end
end

local function nearest()
    local best, bestD = nil, 300 * 300
    for i, p in ipairs(placed) do
        local d = (p.x - ed.x) ^ 2 + (p.z - ed.z) ^ 2
        if d < bestD then best, bestD = i, d end
    end
    return best
end

function SK.dropper_input(m)
    if ed == nil then return end
    if SK.pressed(PAD.B) or SK.key_pressed(VK.BACK) then close(m) return end
    -- Move relative to the camera.
    local lx, ly = SK.axis(SK.pad.lx), SK.axis(SK.pad.ly)
    if SK.key(VK.LEFT) then lx = -1 elseif SK.key(VK.RIGHT) then lx = 1 end
    if SK.key(VK.UP) then ly = 1 elseif SK.key(VK.DOWN) then ly = -1 end
    local cy = SK.rad(ed.camYaw)
    local fx, fz = -math.sin(cy), -math.cos(cy)
    local rx, rz = -fz, fx
    local speed = 14
    ed.x = ed.x + (fx * ly + rx * lx) * speed
    ed.z = ed.z + (fz * ly + rz * lx) * speed
    -- Height
    local lift = (SK.pad.rt - SK.pad.lt) / 255 * 6
    if SK.key(VK.R) then lift = 6 elseif SK.key(VK.F) then lift = -6 end
    ed.lift = SK.clamp(ed.lift + lift, -100, 600)
    ed.baseY = snap(ed.x, (ed.baseY or m.pos.y) + 200, ed.z)
    ed.y = ed.baseY + ed.lift
    -- Rotation: 15 degree steps, repeating while held.
    local rot = 0
    if SK.down(PAD.LB) or SK.key(VK.Q) then rot = 1 elseif SK.down(PAD.RB) or SK.key(VK.E) then rot = -1 end
    if rot ~= 0 then
        if ed.rotHold == 0 or (ed.rotHold > 10 and ed.rotHold % 4 == 0) then ed.yaw = (ed.yaw + rot * 0xAAA) % 65536 end
        ed.rotHold = ed.rotHold + 1
    else ed.rotHold = 0 end
    -- Piece
    if SK.pressed(PAD.RIGHT) or SK.key_pressed(VK.RBR) then ed.kind = ed.kind % #PIECES + 1 end
    if SK.pressed(PAD.LEFT) or SK.key_pressed(VK.LBR) then ed.kind = (ed.kind - 2) % #PIECES + 1 end
    -- Camera orbit
    ed.camYaw = ed.camYaw - math.floor(SK.axis(SK.pad.rx) * 800)
    ed.camDist = SK.clamp(ed.camDist - SK.axis(SK.pad.ry) * 20, 300, 2500)
    ed.highlight = nearest()
    local changed = false
    if SK.pressed(PAD.A) or SK.key_pressed(VK.RETURN) then
        if #placed >= MAX_OBJECTS then
            SK.say("Limit reached (" .. MAX_OBJECTS .. " pieces).", 2)
        else
            table.insert(placed, { kind = ed.kind, x = ed.x, y = ed.y, z = ed.z, yaw = ed.yaw })
            play_sound(SOUND_GENERAL_BOX_LANDING or SOUND_MENU_CLICK_FILE_SELECT, SK.sound_pos())
            changed = true
        end
    elseif (SK.pressed(PAD.Y) or SK.key_pressed(VK.G)) and ed.highlight then
        local p = table.remove(placed, ed.highlight)
        ed.kind, ed.x, ed.z, ed.yaw = p.kind, p.x, p.z, p.yaw
        ed.baseY = snap(p.x, p.y, p.z)
        ed.lift = p.y - ed.baseY
        changed = true
    elseif (SK.pressed(PAD.X) or SK.key_pressed(VK.DELETE)) and ed.highlight then
        table.remove(placed, ed.highlight)
        play_sound(SOUND_GENERAL_BREAK_BOX or SOUND_MENU_CLICK_FILE_SELECT, SK.sound_pos())
        changed = true
    elseif (SK.pressed(PAD.UP) or SK.key_pressed(VK.U)) and #placed > 0 then
        table.remove(placed)
        changed = true
    end
    if changed then
        rebuild_collision()
        save()
    end
    rebuild_display()
end

local function dropper_frame(m)
    if m.playerIndex ~= 0 then return end
    if levelKey ~= nil and levelKey ~= current_level() and SK.geometry.count > 0 then SK.on_area_geometry() end
    show()
    if ed == nil then return end
    local cy = SK.rad(ed.camYaw)
    local tx, ty, tz = ed.x, ed.y + 60, ed.z
    SK.set_camera(tx + math.sin(cy) * ed.camDist * 0.8, ty + ed.camDist * 0.55, tz + math.cos(cy) * ed.camDist * 0.8, tx, ty, tz, 50)
end
hook_event(HOOK_MARIO_UPDATE, SK.safe("dropper", dropper_frame))

function SK.dropper_hud()
    if ed == nil then return end
    local w, h = djui_hud_get_screen_width(), djui_hud_get_screen_height()
    djui_hud_set_color(0, 0, 0, 150)
    djui_hud_render_rect(0, 0, w, 56)
    SK.hud_text("OBJECT DROPPER", 24, 12, 1.0, 120, 255, 140)
    SK.hud_text("< " .. PIECES[ed.kind].name .. " >", 330, 12, 1.0, 255, 255, 255)
    local count = string.format("%d / %d", #placed, MAX_OBJECTS)
    SK.hud_text(count, w - 24 - djui_hud_measure_text(count), 12, 1.0, 255, 220, 120)
    SK.hud_hints({ { "A", "Place" }, { "L stick", "Move" }, { "LB / RB", "Rotate" }, { "LT / RT", "Height" },
        { "D-pad L/R", "Piece" }, { "Y", "Pick up" }, { "X", "Delete" }, { "D-pad Up", "Undo" }, { "R stick", "Camera" }, { "B", "Exit" } })
end
