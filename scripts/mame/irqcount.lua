-- Interrupt entries of the E1, counted from MAME's fetches of the vector words, for
-- scripts/mame_irqcount.py. An interrupt is the CPU jumping to its trap vector, so a read of a
-- vector address while executing (side effects on, not the debugger) marks one entry.
-- Vectors (e132xs.cpp get_trap_addr): table in MEM3 at 0xffffff00 + 4 * trapno, else at
-- <entry> + 4 * (63 - trapno) with entry 0, 0x40000000, 0x80000000 or 0xc0000000.
-- Traps counted: 55 timer, 53 INT1, 52 INT2, 51 INT3, 50 INT4.
--
--   IC_OUT, IC_FRAMES; writes per frame "F <n> <timer> <int1> <int2> <int3> <int4>" and at the end
--   the TR, TCR, TPR, FCR, MCR values.

local OUT    = os.getenv("IC_OUT")
local FRAMES = tonumber(os.getenv("IC_FRAMES") or "3000")
local mach = manager.machine
local cpu  = mach.devices[os.getenv("CORE_CPU") or ":maincpu"]
local prog = cpu.spaces[os.getenv("CORE_SPACE") or "program"]
local f = assert(io.open(OUT, "w"))

local TRAPS = { 55, 53, 52, 51, 50 }
local slot = {}   -- address -> index into cnt
for i, t in ipairs(TRAPS) do
    slot[0xffffff00 + 4 * t] = i
    for _, e in ipairs({ 0x00000000, 0x40000000, 0x80000000, 0xc0000000 }) do
        slot[e + 4 * (63 - t)] = i
    end
end
local cnt = { 0, 0, 0, 0, 0 }
local pcst = cpu.state["PC"]
local BYTES = tonumber(os.getenv("CORE_BYTES") or "4")   -- taps span one bus word
_G.__ic_taps = {}
for addr, i in pairs(slot) do
    _G.__ic_taps[#_G.__ic_taps + 1] = prog:install_read_tap(addr, addr + BYTES - 1, "ic_" .. addr, function(offset, data, mask)
        -- the fetch at the vector, not a data read of it: PC is the vector address
        if not mach:side_effects_disabled() and pcst.value == addr then cnt[i] = cnt[i] + 1 end
        return data
    end)
end

local n = 0
_G.__ic_frame = emu.add_machine_frame_notifier(function()
    n = n + 1
    f:write(string.format("F %d %d %d %d %d %d\n", n, cnt[1], cnt[2], cnt[3], cnt[4], cnt[5]))
    cnt = { 0, 0, 0, 0, 0 }
    if n == FRAMES then
        for _, r in ipairs({ "TR", "TCR", "TPR", "FCR", "MCR" }) do
            local st = cpu.state[r]
            if st then f:write(string.format("reg %s %08X\n", r, st.value)) end
        end
        f:write("done\n")
        f:close()
        mach:exit()
    end
end)
