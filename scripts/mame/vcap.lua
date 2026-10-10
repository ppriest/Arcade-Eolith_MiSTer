-- Video captures for the frame-buffer model (scripts/eolith_capture.py). One MAME run, many
-- frames. At each frame in VC_FRAMES, in the frame notifier that follows the screen update (so
-- the dumps and the screenshot belong together):
--   f<N>_vram.bin     the driver's whole frame-buffer array (save item VC_VRAM_ITEM), both
--                     buffers, in the item's host byte order (uint8 on vegaeo: address order)
--   f<N>_palette.bin  VC_PAL_N entries, 16-bit big-endian, read through the CPU at VC_PAL_BASE
--                     with a VC_PAL_STEP byte stride, low halfword (vegaeo's umask32 0x0000ffff)
--   f<N>.png          scr:snapshot (visible area)
--   manifest.txt      "frame <N> buffer <b>": b is the save item VC_BUF_ITEM, the buffer the CPU
--                     sees; the screen shows the other
--
--   VC_OUT, VC_FRAMES (comma list), VC_COIN (first coin frame, 0 = none), VC_COINPERIOD,
--   VC_STARTPERIOD, VC_COINLEN, VC_IN_COIN/START/HOLD/PULSE as wtiming.lua
--
-- VC_MIRROR=eolith: eolith.cpp's frame buffer is not a save item MAME's Lua lists (only the driver's
-- "save_data" is), so the dumps come from a copy kept by write taps: 0x90000000-0x9003ffff stored as
-- eolith_vram_w stores (206-215: a whole halfword with bit 15 clear, into the buffer m_buffer), and
-- m_buffer from system control writes (0xfc400000 bit 7, 283-285). Both start at 0, as video_start
-- leaves them. The dump is uint16[0x40000] little-endian, the save item's host order on x86.
--
-- VC_SHARE=<tag> (eolith16: ":vram"): the frame buffer is that memory share, dumped byte by byte in address
-- order, and the buffer the CPU sees is the entry of the memory bank VC_BANK (":vrambank").

local OUT   = assert(os.getenv("VC_OUT"))
local mach  = manager.machine
local cpu   = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local sp    = cpu.spaces[os.getenv("CORE_SPACE") or "program"]
local scr   = mach.screens[":screen"]
local root  = mach.devices[":"]

local VRAM_ITEM = os.getenv("VC_VRAM_ITEM") or "m_vram"
local BUF_ITEM  = os.getenv("VC_BUF_ITEM") or "m_vbuffer"
local PAL_BASE  = tonumber(os.getenv("VC_PAL_BASE") or "0", 16)
local PAL_STEP  = tonumber(os.getenv("VC_PAL_STEP") or "4")
local PAL_N     = tonumber(os.getenv("VC_PAL_N") or "0")
local COIN      = tonumber(os.getenv("VC_COIN") or "0")
local COINLEN   = tonumber(os.getenv("VC_COINLEN") or "5")
local CP        = tonumber(os.getenv("VC_COINPERIOD") or "97")
local SP        = tonumber(os.getenv("VC_STARTPERIOD") or "211")

local function split(s, sep)
    local out = {}
    for tok in string.gmatch(s or "", "([^" .. sep .. "]+)") do out[#out + 1] = tok end
    return out
end

local want, last = {}, 0
for _, t in ipairs(split(os.getenv("VC_FRAMES"), ",")) do
    want[tonumber(t)] = true
    if tonumber(t) > last then last = tonumber(t) end
end

local items = root.items
local function item(name)
    local key
    for k, _ in pairs(items) do
        if k:match("/" .. name .. "$") then key = k end
    end
    return assert(key and emu.item(items[key]), "no save item " .. name)
end
local MIRROR = os.getenv("VC_MIRROR")
local SHARE  = os.getenv("VC_SHARE")
local vram, buf
local mirror, mbuf = {}, 0
local share, bank
if SHARE then
    share = assert(mach.memory.shares[SHARE], "no memory share " .. SHARE)
    bank  = assert(mach.memory.banks[os.getenv("VC_BANK") or ":vrambank"], "no memory bank")
elseif MIRROR == "eolith" then
    for i = 0, 0x3ffff do mirror[i] = 0 end
    _G.__vc_taps = {
        sp:install_write_tap(0x90000000, 0x9003ffff, "vcvram", function(o, d, m)
            local a = o >= 0x90000000 and o - 0x90000000 or o   -- the tap's address, absolute or not
            local h = (a >> 1) & ~1                          -- the dword's first halfword
            local base = mbuf * 0x20000
            if (m & 0xffff0000) == 0xffff0000 and (d & 0x80000000) == 0 then
                mirror[base + h] = (d >> 16) & 0xffff
            end
            if (m & 0x0000ffff) == 0x0000ffff and (d & 0x8000) == 0 then
                mirror[base + h + 1] = d & 0xffff
            end
            return d
        end),
        sp:install_write_tap(0xfc400000, 0xfc400003, "vcctl", function(o, d, m)
            mbuf = (d >> 7) & 1
            return d
        end),
    }
else
    vram, buf = item(VRAM_ITEM), item(BUF_ITEM)
end
local function vram_dump()
    if share then
        local parts = {}
        for i = 0, share.size - 1, 1024 do
            local t = {}
            for j = i, i + 1023 do t[#t + 1] = string.char(share:read_u8(j)) end
            parts[#parts + 1] = table.concat(t)
        end
        return table.concat(parts)
    end
    if not vram then
        local parts = {}
        for i = 0, 0x3ffff, 1024 do
            local t = {}
            for j = i, i + 1023 do t[#t + 1] = string.pack("<I2", mirror[j]) end
            parts[#parts + 1] = table.concat(t)
        end
        return table.concat(parts)
    end
    return vram:read_block(0, vram.count * vram.size)
end
local function cpu_buf()
    if bank then return bank.entry end
    return vram and buf:read(0) or mbuf
end

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end
local f_coin  = field(os.getenv("VC_IN_COIN") or "Coin 1")
local f_start = field(os.getenv("VC_IN_START") or "1 Player Start")
local f_hold  = field(os.getenv("VC_IN_HOLD") or "P1 Right")
local f_pulse = field(os.getenv("VC_IN_PULSE") or "P1 Button 1")

local function wr(name, data)
    local f = assert(io.open(OUT .. "/" .. name, "wb"))
    f:write(data)
    f:close()
end

local man = assert(io.open(OUT .. "/manifest.txt", "w"))
local n = 0
_G.__vc_frame = emu.add_machine_frame_notifier(function()
    local ok, err = pcall(function()
        n = n + 1
        if COIN > 0 then
            local k = n - COIN
            if f_coin then f_coin:set_value((k >= 0 and k % CP < COINLEN) and 1 or 0) end
            if f_start then f_start:set_value((k >= 90 and (k - 90) % SP < COINLEN) and 1 or 0) end
            if k >= 96 then
                if f_hold then f_hold:set_value(((k // 120) % 2 == 0) and 1 or 0) end
                if f_pulse then f_pulse:set_value((k % 20) < 4 and 1 or 0) end
            end
        end
        if want[n] then
            wr(string.format("f%d_vram.bin", n), vram_dump())
            local p = {}
            for i = 0, PAL_N - 1 do
                local v = sp:read_u32(PAL_BASE + i * PAL_STEP) & 0xffff
                p[#p + 1] = string.char(v >> 8, v & 0xff)
            end
            wr(string.format("f%d_palette.bin", n), table.concat(p))
            scr:snapshot(string.format("%s/f%d.png", OUT, n))
            man:write(string.format("frame %d buffer %d\n", n, cpu_buf()))
            man:flush()
        end
        if n >= last then
            man:close()
            print("VCAP_OK")
            mach:exit()
        end
    end)
    if not ok then
        local f = io.open(OUT .. "/lua_error.txt", "w")
        f:write("notifier: " .. tostring(err) .. "\n")
        f:close()
        mach:exit()
    end
end)
