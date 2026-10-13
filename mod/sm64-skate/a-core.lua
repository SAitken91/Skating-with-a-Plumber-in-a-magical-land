-- Shared state and helpers for Skate 64. Files load alphabetically; everything
-- shared between them lives in the global SK table.

SK = {
    S = 100,            -- SM64 units per metre (Mario is about 1.6 m tall)
    native = type(sk_version) == "function",
    frame = 0,
    errors = 0,
    messages = {},
}

local S = SK.S

--- Runs fn(...) and logs (once per call site) instead of letting an error kill the hook.
function SK.safe(name, fn)
    local reported = false
    return function(...)
        local ok, a, b, c = pcall(fn, ...)
        if not ok then
            SK.errors = SK.errors + 1
            if not reported then
                reported = true
                local msg = "[" .. name .. "] " .. tostring(a)
                if SK.native then sk_log(msg) end
                SK.say("Skate error: " .. msg, 8)
            end
            return nil
        end
        return a, b, c
    end
end

function SK.log(msg)
    if SK.native then sk_log(msg) end
end

--- Short on-screen message (bottom-left), newest last.
function SK.say(text, seconds)
    table.insert(SK.messages, { text = text, until_frame = SK.frame + math.floor((seconds or 3) * 30) })
    while #SK.messages > 4 do table.remove(SK.messages, 1) end
end

function SK.sound_pos()
    return gMarioStates[0].marioObj.header.gfx.cameraToObject
end

-- ---------------------------------------------------------------- math
function SK.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

function SK.s16(radians)
    local v = math.floor(radians * 32768 / math.pi + 0.5)
    return ((v + 32768) % 65536) - 32768
end
function SK.rad(s16) return s16 * math.pi / 32768 end

--- Column-major 4x4 (glam to_cols_array) to basis vectors and position.
function SK.mat(a, offset)
    local o = offset or 0
    return {
        x = { a[o + 1], a[o + 2], a[o + 3] },
        y = { a[o + 5], a[o + 6], a[o + 7] },
        z = { a[o + 9], a[o + 10], a[o + 11] },
        p = { a[o + 13], a[o + 14], a[o + 15] },
    }
end

--- SM64 object angles (pitch, yaw, roll) for a basis. SM64 draws objects with
--- R = Ry(yaw) * Rx(pitch) * Rz(roll); local +Z is forward and +Y is up, the same
--- axes the skate engine uses.
function SK.angles(m)
    local f, x, y = m.z, m.x, m.y
    local yaw = math.atan(f[1], f[3])
    local pitch = math.atan(-f[2], math.sqrt(f[1] * f[1] + f[3] * f[3]))
    local roll = math.atan(x[2], y[2])
    return SK.s16(pitch), SK.s16(yaw), SK.s16(roll)
end

--- Skate-space metres to SM64 units.
function SK.to_game(p) return p[1] * S, p[2] * S, p[3] * S end

function SK.lerp(a, b, t) return a + (b - a) * t end

--- Shortest-path blend of two s16 angles.
function SK.lerp_angle(a, b, t)
    local d = ((b - a + 32768) % 65536) - 32768
    return math.floor(a + d * t + 0.5)
end

function SK.fmt_score(v)
    local s = tostring(math.floor(v + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return out
end

-- ---------------------------------------------------------------- controller (XInput, read by the bridge)
SK.PAD = {
    UP = 0x0001, DOWN = 0x0002, LEFT = 0x0004, RIGHT = 0x0008,
    START = 0x0010, BACK = 0x0020, LS = 0x0040, RS = 0x0080,
    LB = 0x0100, RB = 0x0200, A = 0x1000, B = 0x2000, X = 0x4000, Y = 0x8000,
}
SK.pad = { buttons = 0, lt = 0, rt = 0, lx = 0, ly = 0, rx = 0, ry = 0, present = false }
SK.padPrev = { buttons = 0 }
SK.keys = {}
SK.keysPrev = {}

function SK.poll_input()
    SK.padPrev = SK.pad
    local p = { buttons = 0, lt = 0, rt = 0, lx = 0, ly = 0, rx = 0, ry = 0, present = false }
    if SK.native then
        local b, lt, rt, lx, ly, rx, ry = sk_pad()
        if b ~= nil then
            p = { buttons = b, lt = lt, rt = rt, lx = lx, ly = ly, rx = rx, ry = ry, present = true }
        end
    end
    SK.pad = p
    SK.keysPrev = SK.keys
    SK.keys = {}
end

function SK.down(button) return (SK.pad.buttons & button) ~= 0 end
function SK.pressed(button) return (SK.pad.buttons & button) ~= 0 and (SK.padPrev.buttons & button) == 0 end
function SK.released(button) return (SK.pad.buttons & button) == 0 and (SK.padPrev.buttons & button) ~= 0 end

--- Keyboard key (virtual-key code), only while the game window has focus.
function SK.key(vk)
    local v = SK.keys[vk]
    if v == nil then
        v = SK.native and sk_key(vk) or false
        SK.keys[vk] = v
    end
    return v
end
function SK.key_pressed(vk)
    local was = SK.keysPrev[vk]
    if was == nil then was = false end
    return SK.key(vk) and not was
end
function SK.key_released(vk)
    local was = SK.keysPrev[vk]
    return (not SK.key(vk)) and was == true
end

--- Stick axis with dead zone, -1..1.
function SK.axis(v)
    local f = v / 32767
    if math.abs(f) < 0.24 then return 0 end
    return SK.clamp(f, -1, 1)
end
