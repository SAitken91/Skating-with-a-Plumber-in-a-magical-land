-- Runtime models: meshes of flat-shaded quads uploaded as display lists and
-- drawn by borrowing a model that never appears in the vanilla game (its
-- display list nodes are pointed at ours). Used for the skateboard and for
-- the object dropper's skatepark pieces.

-- ---------------------------------------------------------------- meshes
local LIGHT = { 0.35, 0.85, 0.4 }
do
    local l = math.sqrt(LIGHT[1] ^ 2 + LIGHT[2] ^ 2 + LIGHT[3] ^ 2)
    LIGHT = { LIGHT[1] / l, LIGHT[2] / l, LIGHT[3] / l }
end

local Mesh = {}
Mesh.__index = Mesh

--- New mesh. transform(p) maps local points to output coordinates (optional).
function SK.mesh(transform)
    return setmetatable({ quads = {}, transform = transform }, Mesh)
end

--- Quad with corners counter-clockwise seen from outside, flat shaded.
function Mesh:quad(a, b, c, d, color)
    local t = self.transform
    if t then a, b, c, d = t(a), t(b), t(c), t(d) end
    local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local vx, vy, vz = d[1] - a[1], d[2] - a[2], d[3] - a[3]
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local l = math.sqrt(nx * nx + ny * ny + nz * nz)
    local shade = 0.6
    if l > 0 then shade = 0.55 + 0.45 * math.max(0, (nx * LIGHT[1] + ny * LIGHT[2] + nz * LIGHT[3]) / l) end
    table.insert(self.quads, { a, b, c, d, { math.floor(color[1] * shade), math.floor(color[2] * shade), math.floor(color[3] * shade) } })
end

--- Axis-aligned box from centre and half extents.
function Mesh:box(cx, cy, cz, hx, hy, hz, color)
    local function p(sx, sy, sz) return { cx + sx * hx, cy + sy * hy, cz + sz * hz } end
    self:quad(p(-1, 1, -1), p(-1, 1, 1), p(1, 1, 1), p(1, 1, -1), color)
    self:quad(p(-1, -1, -1), p(1, -1, -1), p(1, -1, 1), p(-1, -1, 1), color)
    self:quad(p(-1, -1, 1), p(1, -1, 1), p(1, 1, 1), p(-1, 1, 1), color)
    self:quad(p(-1, -1, -1), p(-1, 1, -1), p(1, 1, -1), p(1, -1, -1), color)
    self:quad(p(1, -1, -1), p(1, 1, -1), p(1, 1, 1), p(1, -1, 1), color)
    self:quad(p(-1, -1, -1), p(-1, -1, 1), p(-1, 1, 1), p(-1, 1, -1), color)
end

--- Triangles (for collision) of every quad, in output coordinates.
function Mesh:triangles(out)
    out = out or {}
    for _, q in ipairs(self.quads) do
        table.insert(out, { q[1], q[2], q[3] })
        table.insert(out, { q[1], q[3], q[4] })
    end
    return out
end

--- Uploads the mesh as a display list. scale multiplies every coordinate
--- (vertices are 16-bit, so small models are built at a larger scale).
function SK.upload_mesh(name, mesh, scale)
    local quads = mesh.quads
    scale = scale or 1
    local total = math.max(4, #quads * 4)
    local vtx = vtx_get_from_name(name .. "_vtx")
    if vtx == nil then vtx = vtx_create(name .. "_vtx", total) else vtx_resize(vtx, total) end
    local v = vtx
    for _, q in ipairs(quads) do
        for k = 1, 4 do
            v.x, v.y, v.z = math.floor(q[k][1] * scale + 0.5), math.floor(q[k][2] * scale + 0.5), math.floor(q[k][3] * scale + 0.5)
            v.tu, v.tv = 0, 0
            v.r, v.g, v.b, v.a = q[5][1], q[5][2], q[5][3], 255
            v = vtx_get_next_vertex(v)
        end
    end
    local per_load = 7 -- quads per gsSPVertex (28 vertices)
    local loads = math.ceil(#quads / per_load)
    local length = 9 + loads + #quads
    local gfx = gfx_get_from_name(name)
    if gfx == nil then gfx = gfx_create(name, length) else gfx_resize(gfx, length) end
    local cmd = gfx
    local function put(text, ...)
        gfx_set_command(cmd, text, ...)
        cmd = gfx_get_next_command(cmd)
    end
    put("gsDPPipeSync()")
    put("gsSPClearGeometryMode(G_LIGHTING)")
    put("gsSPClearGeometryMode(G_CULL_BACK)")
    put("gsSPTexture(0xFFFF, 0xFFFF, 0, G_TX_RENDERTILE, G_OFF)")
    put("gsDPSetCombineMode(G_CC_SHADE, G_CC_SHADE)")
    local q = 1
    while q <= #quads do
        local count = math.min(per_load, #quads - q + 1)
        put("gsSPVertex(%v, %i, 0)", vtx_get_vertex(vtx, (q - 1) * 4), count * 4)
        for k = 0, count - 1 do
            local b = k * 4
            put("gsSP2Triangles(%i, %i, %i, 0, %i, %i, %i, 0)", b, b + 1, b + 2, b, b + 2, b + 3)
        end
        q = q + count
    end
    put("gsDPPipeSync()")
    put("gsSPSetGeometryMode(G_LIGHTING)")
    put("gsSPSetGeometryMode(G_CULL_BACK)")
    put("gsSPEndDisplayList()")
    return gfx
end

-- ---------------------------------------------------------------- borrowed models
-- Models that never appear in the vanilla game. Each drawable takes one.
local CANDIDATES = { "E_MODEL_BETA_BOO_KEY", "E_MODEL_ERROR_MODEL", "E_MODEL_BETA_CHEST_LID", "E_MODEL_BETA_CHEST_BOTTOM" }
local taken = {}
local drawables = {}

local function patch_model(obj, gfx)
    local root = obj.header.gfx.sharedChild
    if root == nil then return nil end
    local patched, visited, geoScale = 0, 0, 1
    local empty = gfx_get_from_name("sk_empty_dl") or gfx_create("sk_empty_dl", 1)
    gfx_set_command(empty, "gsSPEndDisplayList()")
    local function walk(node, depth)
        if node == nil or depth > 12 then return end
        local first = node
        repeat
            visited = visited + 1
            if node.type == GRAPH_NODE_TYPE_DISPLAY_LIST or node.type == GRAPH_NODE_TYPE_ANIMATED_PART then
                cast_graph_node(node).displayList = patched == 0 and gfx or empty
                patched = patched + 1
            elseif node.type == GRAPH_NODE_TYPE_SCALE then
                geoScale = geoScale * cast_graph_node(node).scale
            elseif node.type == GRAPH_NODE_TYPE_BILLBOARD then
                return nil
            end
            walk(node.children, depth + 1)
            node = node.next
        until node == nil or node == first or visited > 200
    end
    walk(root, 0)
    if patched == 0 then return nil end
    if geoScale <= 0 then geoScale = 1 end
    SK.log(string.format("model patch: %d nodes, %d display lists, geo scale %.3f", visited, patched, geoScale))
    return geoScale
end

--- A drawable showing gfx. Returns the drawable table (obj may be nil until it spawns).
function SK.drawable(key, gfx)
    local d = drawables[key]
    if d == nil then
        d = { key = key, gfx = gfx }
        drawables[key] = d
    end
    d.gfx = gfx
    return d
end

local function ensure(d)
    if d.obj ~= nil and d.obj.activeFlags ~= ACTIVE_FLAG_DEACTIVATED then return d.obj end
    d.obj = nil
    local m = gMarioStates[0]
    local order = {}
    if d.model then table.insert(order, d.model) end
    for _, name in ipairs(CANDIDATES) do
        -- The key model is known to work; keep it for the board.
        local reserved = name == "E_MODEL_BETA_BOO_KEY" and d.key ~= "board"
        if name ~= d.model and not taken[name] and not reserved then table.insert(order, name) end
    end
    for _, name in ipairs(order) do
        local model = _G[name]
        if model ~= nil then
            local o = spawn_non_sync_object(id_bhvStaticObject, model, m.pos.x, m.pos.y, m.pos.z, nil)
            if o ~= nil then
                local geoScale = patch_model(o, d.gfx)
                if geoScale then
                    d.obj, d.model, d.geoScale = o, name, geoScale
                    taken[name] = d.key
                    o.header.gfx.skipInViewCheck = true
                    o.header.gfx.shadowInvisible = true
                    SK.log(d.key .. " drawn with " .. name)
                    return o
                end
                obj_mark_for_deletion(o)
            end
        end
    end
    return nil
end

--- Shows the drawable at a position, SM64 angles and scale (px nil hides it).
function SK.drawable_place(d, px, py, pz, pitch, yaw, roll, scale)
    if px == nil then
        if d.obj ~= nil then d.obj.header.gfx.node.flags = d.obj.header.gfx.node.flags & ~GRAPH_RENDER_ACTIVE end
        return
    end
    local o = ensure(d)
    if o == nil then return end
    o.oPosX, o.oPosY, o.oPosZ = px, py, pz
    o.oFaceAnglePitch, o.oFaceAngleYaw, o.oFaceAngleRoll = pitch, yaw, roll
    o.oMoveAnglePitch, o.oMoveAngleYaw, o.oMoveAngleRoll = pitch, yaw, roll
    o.oDrawingDistance = 30000
    local g = o.header.gfx
    g.pos.x, g.pos.y, g.pos.z = px, py, pz
    g.angle.x, g.angle.y, g.angle.z = pitch, yaw, roll
    local k = (scale or 1) / (d.geoScale or 1)
    g.scale.x, g.scale.y, g.scale.z = k, k, k
    g.node.flags = g.node.flags | GRAPH_RENDER_ACTIVE
end

hook_event(HOOK_ON_OBJECT_UNLOAD, function(o)
    for _, d in pairs(drawables) do
        if d.obj ~= nil and o == d.obj then d.obj = nil end
    end
end)

-- ---------------------------------------------------------------- the skateboard
-- Board space: X across, Y up, Z along the deck (nose +Z), origin at the deck,
-- matching the engine's SKATEBOARD_ROOT. Built in centimetres (= SM64 units)
-- and uploaded at 10x for vertex precision, then drawn at 0.1 scale.

local function wheel(mesh, cx, cy, cz, radius, width, color)
    local ring = {}
    for i = 0, 7 do
        local a = (i + 0.5) * math.pi / 4
        ring[i] = { math.cos(a) * radius, math.sin(a) * radius }
    end
    local function p(side, i) return { cx + side * width / 2, cy + ring[i][2], cz + ring[i][1] } end
    for i = 0, 7 do
        local j = (i + 1) % 8
        mesh:quad(p(-1, i), p(-1, j), p(1, j), p(1, i), color)
    end
    local cap = { 230, 220, 190 }
    for _, f in ipairs({ { 0, 1, 2, 3 }, { 0, 3, 4, 7 }, { 4, 5, 6, 7 } }) do
        mesh:quad(p(1, f[1]), p(1, f[2]), p(1, f[3]), p(1, f[4]), cap)
        mesh:quad(p(-1, f[4]), p(-1, f[3]), p(-1, f[2]), p(-1, f[1]), cap)
    end
end

local function board_mesh()
    local mesh = SK.mesh()
    -- Deck profile along Z with kicktails: {z, y (top), half width}
    local profile = { { -41, 4.6, 6.5 }, { -38, 3.4, 9.2 }, { -31, 0.7, 10 }, { 31, 0.7, 10 }, { 38, 3.4, 9.2 }, { 41, 4.6, 6.5 } }
    local thick = 1.3
    local grip, wood, graphic = { 45, 45, 50 }, { 205, 160, 95 }, { 215, 30, 30 }
    local function corner(i, side, top)
        local z, y, w = profile[i][1], profile[i][2], profile[i][3]
        return { side * w, y - (top and 0 or thick), z }
    end
    for i = 1, #profile - 1 do
        local j = i + 1
        mesh:quad(corner(i, -1, true), corner(j, -1, true), corner(j, 1, true), corner(i, 1, true), grip)
        mesh:quad(corner(i, -1, false), corner(i, 1, false), corner(j, 1, false), corner(j, -1, false), graphic)
        mesh:quad(corner(i, 1, false), corner(i, 1, true), corner(j, 1, true), corner(j, 1, false), wood)
        mesh:quad(corner(i, -1, false), corner(j, -1, false), corner(j, -1, true), corner(i, -1, true), wood)
    end
    local n = #profile
    mesh:quad(corner(n, -1, false), corner(n, 1, false), corner(n, 1, true), corner(n, -1, true), wood)
    mesh:quad(corner(1, -1, false), corner(1, -1, true), corner(1, 1, true), corner(1, 1, false), wood)
    local metal, dark = { 185, 185, 195 }, { 90, 90, 100 }
    for _, z in ipairs({ 25.9, -25.9 }) do
        mesh:box(0, -1.2, z, 3.5, 0.6, 4.2, dark)
        mesh:box(0, -3.2, z, 8.8, 1.1, 1.3, metal)
        mesh:box(0, -2.2, z, 1.4, 1.2, 1.4, metal)
    end
    for _, z in ipairs({ 24.3, -24.3 }) do
        for _, x in ipairs({ 9.75, -9.75 }) do wheel(mesh, x, -5.2, z, 2.75, 3.4, { 240, 235, 215 }) end
    end
    return mesh
end

SK.board = { visible = false, last = nil }
local boardDrawable = nil

--- Draws the board at a game-space position and SM64 angles (nil hides it).
function SK.board_place(px, py, pz, pitch, yaw, roll)
    local b = SK.board
    if boardDrawable == nil then
        if px == nil then return end
        local mesh = board_mesh()
        boardDrawable = SK.drawable("board", SK.upload_mesh("sk_board", mesh, 10))
        SK.log(string.format("board model: %d quads", #mesh.quads))
    end
    if px == nil then
        b.visible = false
        SK.drawable_place(boardDrawable, nil)
        return
    end
    b.visible = true
    b.last = { px, py, pz, pitch, yaw, roll }
    SK.drawable_place(boardDrawable, px, py, pz, pitch, yaw, roll, 0.1)
end

--- Board from an engine matrix (Skate space), or hidden.
function SK.board_update(show, matrix)
    if not show then return SK.board_place(nil) end
    local px, py, pz = SK.to_game(matrix.p)
    local pitch, yaw, roll = SK.angles(matrix)
    SK.board_place(px, py, pz, pitch, yaw, roll)
end
