-- Level collision for the skate engine. SM64 loads an area's static surfaces
-- in one burst, so every static surface added in one frame is grouped: a big
-- burst is a new area (it replaces the set), a small one is extra static
-- object collision (it is appended).

local S = SK.S
SK.geometry = { tris = {}, count = 0, revision = 0 }
local pending, pendingCount = {}, 0

local skipTypes = {}
for _, name in ipairs({ "SURFACE_INTANGIBLE", "SURFACE_CAMERA_BOUNDARY", "SURFACE_CAMERA_8_DIR", "SURFACE_CAMERA_MIDDLE",
    "SURFACE_CAMERA_ROTATE_LEFT", "SURFACE_CAMERA_ROTATE_RIGHT", "SURFACE_CAMERA_FREE_ROAM", "SURFACE_BOSS_FIGHT_CAMERA",
    "SURFACE_CLOSE_CAMERA" }) do
    if _G[name] ~= nil then skipTypes[_G[name]] = true end
end

local function on_add_surface(s, dynamic)
    if dynamic or s == nil or SK.suppressCapture then return end
    if skipTypes[s.type] then return end
    if SURFACE_FLAG_INTANGIBLE ~= nil and (s.flags & SURFACE_FLAG_INTANGIBLE) ~= 0 then return end
    local a, b, c = s.vertex1, s.vertex2, s.vertex3
    local ax, ay, az, bx, by, bz, cx, cy, cz = a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z
    -- Keep the winding that agrees with the surface normal (the engine uses it for facing).
    local ux, uy, uz, vx, vy, vz = bx - ax, by - ay, bz - az, cx - ax, cy - ay, cz - az
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local n = s.normal
    if nx * n.x + ny * n.y + nz * n.z < 0 then
        bx, by, bz, cx, cy, cz = cx, cy, cz, bx, by, bz
    end
    local t = pending
    local i = #t
    t[i + 1], t[i + 2], t[i + 3] = ax / S, ay / S, az / S
    t[i + 4], t[i + 5], t[i + 6] = bx / S, by / S, bz / S
    t[i + 7], t[i + 8], t[i + 9] = cx / S, cy / S, cz / S
    pendingCount = pendingCount + 1
end

--- Called once per frame: commits the surfaces added since the last call.
function SK.flush_geometry()
    if pendingCount == 0 then return end
    local g = SK.geometry
    local newArea = pendingCount >= 40 or g.count == 0
    if newArea then
        g.tris, g.count = pending, pendingCount
    else
        local t = g.tris
        local n = #t
        for i = 1, #pending do t[n + i] = pending[i] end
        g.count = g.count + pendingCount
    end
    g.revision = g.revision + 1
    SK.log(string.format("collision revision %d: %d triangles (burst %d)", g.revision, g.count, pendingCount))
    pending, pendingCount = {}, 0
    if newArea and SK.on_area_geometry then SK.on_area_geometry() end
end

-- Extra triangles (dropped objects), flat Skate-space list like SK.geometry.tris.
SK.extra = { tris = {}, count = 0, revision = 0 }
local combined = { key = nil, tris = nil, count = 0 }

--- Level plus extra triangles for the engine, and a key that changes when either does.
function SK.engine_geometry()
    local g, e = SK.geometry, SK.extra
    local key = g.revision * 100000 + e.revision
    if combined.key ~= key then
        if e.count == 0 then
            combined.tris, combined.count = g.tris, g.count
        else
            local t = {}
            for i = 1, #g.tris do t[i] = g.tris[i] end
            local n = #t
            for i = 1, #e.tris do t[n + i] = e.tris[i] end
            combined.tris, combined.count = t, g.count + e.count
        end
        combined.key = key
    end
    return combined.tris, combined.count, key
end

local function on_clear_areas()
    SK.geometry = { tris = {}, count = 0, revision = SK.geometry.revision + 1 }
    pending, pendingCount = {}, 0
end

hook_event(HOOK_ON_ADD_SURFACE, SK.safe("add_surface", on_add_surface))
hook_event(HOOK_ON_CLEAR_AREAS, SK.safe("clear_areas", on_clear_areas))
