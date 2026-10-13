-- Full-body Skate poses on Mario. Mario's animated parts (hierarchy and rest
-- translations) are read from his geo layout; the bridge retargets the engine's
-- 36-bone pose onto them every frame and writes it into the "sk_pose"
-- animation, which Mario plays while skating.

SK.rig = { ready = false, failed = nil, anim = nil, parts = nil, enabled = true, slot = 0 }

local PARTS = 20

--- Depth-first list of Mario's animated parts. A switch draws one of its
--- children and every level-of-detail sibling holds the same body, and each of
--- those alternatives consumes the same animation channels, so only the first
--- one is followed.
local function read_parts(obj)
    local parts, dump = {}, {}
    local visit
    local function visit_children(first, parent, depth)
        if first == nil then return end
        local node, guard, seenLod = first, 0, false
        repeat
            if node.type == GRAPH_NODE_TYPE_LEVEL_OF_DETAIL then
                if not seenLod then visit(node, parent, depth) end
                seenLod = true
            else
                visit(node, parent, depth)
            end
            node = node.next
            guard = guard + 1
        until node == nil or node == first or guard > 64
    end
    visit = function(node, parent, depth)
        if depth > 40 then return end
        table.insert(dump, string.rep(" ", depth) .. tostring(node.type))
        local here = parent
        if node.type == GRAPH_NODE_TYPE_ANIMATED_PART then
            local t = cast_graph_node(node).translation
            table.insert(parts, { parent = parent, x = t.x, y = t.y, z = t.z })
            here = #parts
        end
        if node.type == GRAPH_NODE_TYPE_SWITCH_CASE then
            if node.children ~= nil then visit(node.children, here, depth + 1) end
        else
            visit_children(node.children, here, depth + 1)
        end
    end
    visit_children(obj.header.gfx.sharedChild, 0, 0)
    return parts, dump
end

local function register_output(m)
    if SK.rig.anim ~= nil then return true end
    local divisor = m.marioObj.header.gfx.animInfo.animYTrans
    if divisor == nil or divisor <= 0 then divisor = 189 end
    -- Two frames per channel (previous and current pose); the bridge alternates
    -- them so the renderer can blend. ANIM_FLAG_2 (4) stops automatic advancing.
    local values, index = {}, {}
    local channels = 3 + PARTS * 3
    for c = 0, channels - 1 do
        values[c * 2 + 1], values[c * 2 + 2] = 0, 0
        index[c * 2 + 1] = 2
        index[c * 2 + 2] = c * 2
    end
    smlua_anim_util_register_animation("sk_pose", 4, divisor, 0, 0, 2, values, index)
    return true
end

--- Prepares the rig. Needs one published Skate pose (for the T-pose reference).
function SK.rig_setup(m)
    local r = SK.rig
    if r.ready or r.failed or not SK.native then return r.ready end
    local parts, dump = read_parts(m.marioObj)
    if #parts ~= PARTS then
        r.failed = "Mario has " .. #parts .. " animated parts (expected 20)"
        SK.log(r.failed .. "; geo node types: " .. table.concat(dump, "|"))
        return false
    end
    local parents, rest = {}, {}
    for i, p in ipairs(parts) do
        parents[i] = p.parent - 1
        rest[i * 3 - 2], rest[i * 3 - 1], rest[i * 3] = p.x, p.y, p.z
    end
    register_output(m)
    -- Reference: Mario's A-pose, loaded through the normal animation path.
    local gfx = m.marioObj.header.gfx
    gfx.animInfo.animID = -1
    set_character_animation(m, CHAR_ANIM_A_POSE)
    local reference = gfx.animInfo.curAnim
    smlua_anim_util_set_animation(m.marioObj, "sk_pose")
    local out = gfx.animInfo.curAnim
    local values, indexLen = sk_anim_info(out)
    if values == nil or values < (3 + PARTS * 3) * 2 then
        r.failed = "pose animation not writable"
        SK.log(r.failed)
        return false
    end
    local ok = sk_rig(parents, rest, reference, out)
    if ok ~= true then
        r.failed = tostring(ok)
        SK.log("rig failed: " .. r.failed)
        return false
    end
    r.anim, r.parts, r.ready = out, parts, true
    local text = {}
    for i, p in ipairs(parts) do table.insert(text, string.format("%d<-%d(%d,%d,%d)", i, p.parent, p.x, p.y, p.z)) end
    SK.log("rig parts: " .. table.concat(text, " "))
    return true
end

--- Puts the current Skate pose on Mario. Returns false when the rig is unavailable.
function SK.rig_pose(m)
    local r = SK.rig
    if not r.enabled or not SK.rig_setup(m) then return false end
    local gfx = m.marioObj.header.gfx
    if gfx.animInfo.curAnim ~= r.anim then smlua_anim_util_set_animation(m.marioObj, "sk_pose") end
    r.slot = SK.frame % 2
    sk_rig_apply(r.slot)
    gfx.animInfo.animFrame = r.slot
    gfx.animInfo.animID = -1
    return true
end

--- Writes recorded animation values (replays).
function SK.rig_show(m, values)
    local r = SK.rig
    if not r.ready then return false end
    local gfx = m.marioObj.header.gfx
    if gfx.animInfo.curAnim ~= r.anim then smlua_anim_util_set_animation(m.marioObj, "sk_pose") end
    r.slot = SK.frame % 2
    sk_anim_set(r.anim, values, r.slot)
    gfx.animInfo.animFrame = r.slot
    gfx.animInfo.animID = -1
    return true
end

--- Lets the next vanilla set_mario_animation call load its animation again.
function SK.rig_release(m)
    m.marioObj.header.gfx.animInfo.animID = -1
end
