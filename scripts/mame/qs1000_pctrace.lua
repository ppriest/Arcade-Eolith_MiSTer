-- PC trace of the QS1000 8052 (":qs1000:cpu", or QP_CPU: ":soundcpu" on the Gradation 2D) over a window of frames, for debugging the sound board
-- against the core. MAME must run with -debug. COIN1 and START1 as qs1000_wave.lua (WV_COIN, WV_START,
-- WV_COINREP, WV_STARTREP); the trace runs from frame QP_FROM to QP_TO into QP_OUT, MAME's loop folding
-- kept; frame ends are marked "# V <frame>" and the main CPU's latch writes "# L <data>" (WV_LATCH).
local mach  = manager.machine
local dbg   = mach.debugger
local OUT   = assert(os.getenv("QP_OUT"))
local FROM  = tonumber(os.getenv("QP_FROM") or "500")
local TO    = tonumber(os.getenv("QP_TO") or "506")
local LATCH = tonumber(os.getenv("WV_LATCH") or "fc600000", 16)
local COIN  = tonumber(os.getenv("WV_COIN") or "-1")
local START = tonumber(os.getenv("WV_START") or "-1")
local CREP  = tonumber(os.getenv("WV_COINREP") or "0")
local SREP  = tonumber(os.getenv("WV_STARTREP") or "0")
local CPU   = os.getenv("QP_CPU") or ":qs1000:cpu"
local function pressed(k, at, rep)
    if at < 0 or k < at then return false end
    if rep > 0 then return (k - at) % rep < 6 end
    return k < at + 6
end
dbg.visible_cpu = mach.devices[CPU]
local tracing, n = false, 0
if FROM <= 1 then                      -- from power-on
    dbg:command(string.format("trace %s,%s", OUT, CPU))
    tracing = true
end
dbg:command("go")
_G.__qpl = mach.devices[":maincpu"].spaces["program"]:install_write_tap(LATCH, LATCH + 3, "qpl", function(o, d, m)
    if tracing then dbg:command(string.format('tracelog "# L %02x\n"', d & 0xff)) end
    return d
end)
local function field(name)
    for _, p in pairs(mach.ioport.ports) do if p.fields[name] then return p.fields[name] end end
end
local fc, fs = field("Coin 1"), field("1 Player Start")
_G.__qpf = emu.add_machine_frame_notifier(function()
    n = n + 1
    local k = n + 1
    if fc then fc:set_value(pressed(k, COIN, CREP) and 1 or 0) end
    if fs then fs:set_value(pressed(k, START, SREP) and 1 or 0) end
    if n == FROM - 1 then
        dbg:command(string.format("trace %s,%s", OUT, CPU))
        tracing = true
    elseif tracing then
        dbg:command(string.format('tracelog "# V %d\n"', n))
    end
    if n == TO then
        dbg:command(string.format("trace off,%s", CPU))
        print("QPTRACE_OK")
        mach:exit()
    end
end)
