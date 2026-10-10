-- Per-frame CPU load and memory traffic of an Eolith set, for scripts/mame_load.py.
--
--   LD_OUT      output file
--   LD_FRAMES   frames to run in total
--   LD_COIN     frame of the first coin (0 = attract only); Start follows, then HOLD held and
--               PULSE pulsed so play goes on (regions.json "inputs")
--   LD_IDLE_PC  hex PC of the game's vblank-wait read of 0xfc000000 (eolith_speedup.cpp table)
--
-- Idle time: a read from LD_IDLE_PC before line 240 enters the vblank wait (MAME's speed-up then
-- spins the CPU to line 240); the first such read at or after line 240 leaves it. Time between
-- the two is idle, everything else is work.
--
-- One line per frame:
--   F <n> <idle> <vram_w> <vram_hw> <vram_drop> <vram_r> <rom_r> <rom_bytes> <flips> <off_w> <off_r>
--     idle: fraction of the frame spent in the vblank wait; VRAM write accesses, halfwords
--     stored, halfwords dropped by eolith_vram_w (byte lane or bit 15 set), VRAM read accesses,
--     data-ROM read accesses and bytes, buffer flips, halfwords stored and read accesses at or
--     beyond line 240 (halfword offset 336 * 240)
-- and at the end the highest VRAM halfword offset stored and read, the bus/timer control
-- registers, and the PCs that read 0xfc000000.

local OUT    = os.getenv("LD_OUT")
local FRAMES = tonumber(os.getenv("LD_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("LD_COIN") or "0")
local IDLE   = tonumber(os.getenv("LD_IDLE_PC") or "0", 16)
-- Board addresses, eolith.cpp's by default; mame_load.py overrides them for vegaeo and eolith16.
local function hexenv(k, d) return tonumber(os.getenv(k) or d, 16) end
local VRAM_LO, VRAM_HI = hexenv("LD_VRAM_LO", "90000000"), hexenv("LD_VRAM_HI", "9003ffff")
local ROM_LO, ROM_HI   = hexenv("LD_ROM_LO", "fd000000"), hexenv("LD_ROM_HI", "feffffff")
local CUSTOM           = hexenv("LD_CUSTOM", "fc000000")
local CUSTOM_HI        = hexenv("LD_CUSTOM_HI", string.format("%x", CUSTOM + 3))
local FLIP_ADDR        = hexenv("LD_FLIP", "fc400000")
local FLIP_BIT         = tonumber(os.getenv("LD_FLIP_BIT") or "7")

local mach = manager.machine
local cpu  = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog = cpu.spaces[os.getenv("CORE_SPACE") or "program"]
local pcst = cpu.state["PC"]
local scr  = mach.screens[":screen"]

local f = assert(io.open(OUT, "w"))
local function now() return mach.time:as_double() end

-- The scanline from time_until_pos, as in wtiming.lua (0.28x's screen binding has no vpos).
local frame_period = 1.0 / scr.refresh
local line_period
for _ = 1, 64 do
    local d = scr:time_until_pos(1) - scr:time_until_pos(0)
    if d > 0 and (line_period == nil or d < line_period) then line_period = d end
end
local vtotal = math.floor(frame_period / line_period + 0.5)
local function cur_line()
    return math.floor((frame_period - scr:time_until_pos(0)) / line_period + 0.5) % vtotal
end

local VIS = 336 * 240
local vram_w, vram_hw, vram_drop, vram_r, rom_r, rom_bytes, flips = 0, 0, 0, 0, 0, 0, 0
local off_w, off_r = 0, 0
local buffer = 0
local vmax, vrmax = -1, -1
local idle, t_enter, idle_acc = false, 0, 0
local pcs = {}

local function popcount_bytes(mask)
    local n = 0
    for i = 0, 3 do
        if ((mask >> (i * 8)) & 0xff) ~= 0 then n = n + 1 end
    end
    return n
end

-- eolith_vram_w stores a halfword only when the whole halfword is written and bit 15 is clear.
local function vram_half(off_hw, data16, mask16)
    if mask16 == 0 then return end
    if mask16 == 0xffff and (data16 & 0x8000) == 0 then
        vram_hw = vram_hw + 1
        if off_hw >= VIS then off_w = off_w + 1 end
        if off_hw > vmax then vmax = off_hw end
    else
        vram_drop = vram_drop + 1
    end
end

_G.__ld_taps = {
    prog:install_write_tap(VRAM_LO, VRAM_HI, "ld_vram_w", function(offset, data, mask)
        vram_w = vram_w + 1
        local hw = (offset - VRAM_LO) >> 1
        -- big-endian: the high half of the dword is the lower address
        vram_half(hw,     (data >> 16) & 0xffff, (mask >> 16) & 0xffff)
        vram_half(hw + 1,  data        & 0xffff,  mask        & 0xffff)
        return data
    end),
    prog:install_read_tap(VRAM_LO, VRAM_HI, "ld_vram_r", function(offset, data, mask)
        vram_r = vram_r + 1
        local hw = (offset - VRAM_LO) >> 1
        if hw >= VIS then off_r = off_r + 1 end
        if hw > vrmax then vrmax = hw end
        return data
    end),
    prog:install_read_tap(ROM_LO, ROM_HI, "ld_rom_r", function(offset, data, mask)
        rom_r = rom_r + 1
        rom_bytes = rom_bytes + popcount_bytes(mask)
        return data
    end),
    prog:install_read_tap(CUSTOM, CUSTOM_HI, "ld_custom_r", function(offset, data, mask)
        local pc = pcst.value
        pcs[pc] = (pcs[pc] or 0) + 1
        if pc == IDLE then
            local before_vblank = cur_line() < 240
            if before_vblank and not idle then
                idle, t_enter = true, now()
            elseif not before_vblank and idle then
                idle_acc = idle_acc + (now() - t_enter)
                idle = false
            end
        end
        return data
    end),
    prog:install_write_tap(FLIP_ADDR, FLIP_ADDR + 3, "ld_sysctl_w", function(offset, data, mask)
        local b = (data >> FLIP_BIT) & 1
        if b ~= buffer then flips = flips + 1 end
        buffer = b
        return data
    end),
}

local function field(name)
    for _, port in pairs(mach.ioport.ports) do
        local fl = port.fields[name]
        if fl then return fl end
    end
    return nil
end
local f_coin  = field(os.getenv("LD_IN_COIN") or "Coin 1")
local f_start = field(os.getenv("LD_IN_START") or "1 Player Start")
local f_hold  = field(os.getenv("LD_IN_HOLD") or "P1 Right")
local f_pulse = field(os.getenv("LD_IN_PULSE") or "P1 Button 1")
local CP = tonumber(os.getenv("LD_COIN_PERIOD") or "97")
local SP = tonumber(os.getenv("LD_START_PERIOD") or "211")
local PL = tonumber(os.getenv("LD_PRESS_LEN") or "5")

local n = 0
emu.register_frame_done(function()
    n = n + 1
    local t = now()
    if idle then idle_acc = idle_acc + (t - t_enter); t_enter = t end
    f:write(string.format("F %d %.4f %d %d %d %d %d %d %d %d %d\n", n, idle_acc / frame_period,
                          vram_w, vram_hw, vram_drop, vram_r, rom_r, rom_bytes, flips, off_w, off_r))
    vram_w, vram_hw, vram_drop, vram_r, rom_r, rom_bytes, flips = 0, 0, 0, 0, 0, 0, 0
    off_w, off_r, idle_acc = 0, 0, 0
    if COIN > 0 then
        local k = n - COIN
        if f_coin then f_coin:set_value((k >= 0 and k % CP < PL) and 1 or 0) end
        if f_start then f_start:set_value((k >= 90 and (k - 90) % SP < PL) and 1 or 0) end
        if k >= 96 then
            if f_hold then f_hold:set_value(((k // 120) % 2 == 0) and 1 or 0) end
            if f_pulse then f_pulse:set_value((k % 20) < 4 and 1 or 0) end
        end
    end
    if n == FRAMES then
        f:write(string.format("vmax %d %d\n", vmax, vrmax))
        for _, r in ipairs({ "BCR", "MCR", "TPR", "TCR", "FCR", "SR" }) do
            local st = cpu.state[r]
            if st then f:write(string.format("reg %s %08X\n", r, st.value)) end
        end
        for pc, c in pairs(pcs) do f:write(string.format("pc %08X %d\n", pc, c)) end
        f:write("done\n")
        f:close()
        mach:exit()
    end
end)
