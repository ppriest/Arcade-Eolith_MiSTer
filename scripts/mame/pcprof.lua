-- PC-only trace of the main CPU over a window of frames, for scripts/mame_pcprof.py.
-- MAME must run with -debug -nodrc (the debugger's instruction hook).
--
--   PP_OUT     trace file
--   PP_START   first frame traced
--   PP_FRAMES  frames traced
--   PP_COIN    frame of the first coin (0 = attract only), inputs as in load.lua
--
-- The trace keeps MAME's loop folding ("(loops for N instructions)"), so an idle loop costs one
-- line. Frame ends are marked "# V <frame>", reads of 0xfc000000 "# R", buffer flips "# S".

local OUT    = os.getenv("PP_OUT")
local START  = tonumber(os.getenv("PP_START") or "600")
local FRAMES = tonumber(os.getenv("PP_FRAMES") or "60")
local COIN   = tonumber(os.getenv("PP_COIN") or "0")

local mach = manager.machine
local dbg  = mach.debugger
local cpu  = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog = cpu.spaces[os.getenv("CORE_SPACE") or "program"]

local tracing, buffer = false, 0
dbg:command("go")

_G.__pp_taps = {
    prog:install_read_tap(0xfc000000, 0xfc000003, "pp_custom_r", function(offset, data, mask)
        if tracing and not mach:side_effects_disabled() then dbg:command('tracelog "# R\n"') end
        return data
    end),
    prog:install_write_tap(0xfc400000, 0xfc400003, "pp_sysctl_w", function(offset, data, mask)
        local b = (data >> 7) & 1
        if tracing and b ~= buffer then dbg:command('tracelog "# S\n"') end
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
local f_coin  = field(os.getenv("PP_IN_COIN") or "Coin 1")
local f_start = field(os.getenv("PP_IN_START") or "1 Player Start")
local f_hold  = field(os.getenv("PP_IN_HOLD") or "P1 Right")
local f_pulse = field(os.getenv("PP_IN_PULSE") or "P1 Button 1")

local n = 0
_G.__pp_frame = emu.add_machine_frame_notifier(function()
    n = n + 1
    if COIN > 0 then
        local k = n - COIN
        if f_coin then f_coin:set_value((k >= 0 and k % 97 < 5) and 1 or 0) end
        if f_start then f_start:set_value((k >= 90 and (k - 90) % 211 < 5) and 1 or 0) end
        if k >= 96 then
            if f_hold then f_hold:set_value(((k // 120) % 2 == 0) and 1 or 0) end
            if f_pulse then f_pulse:set_value((k % 20) < 4 and 1 or 0) end
        end
    end
    if n == START then
        dbg:command(string.format("trace %s,maincpu", OUT))
        tracing = true
    elseif tracing then
        dbg:command(string.format('tracelog "# V %d\n"', n))
    end
    if n == START + FRAMES then
        tracing = false
        dbg:command("trace off,maincpu")
        local f = io.open(OUT .. ".done", "w")
        f:write("done\n")
        f:close()
        mach:exit()
    end
end)
