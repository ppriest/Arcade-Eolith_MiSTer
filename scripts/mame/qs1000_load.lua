-- Sound traffic of a QS1000 board in play: the main CPU's latch writes (VC_LATCH, hex), the QS1000
-- 8052's xdata reads below and above 0x100 (the banked ROM window on Vega), with the most in one frame
-- and the distinct 16-byte lines, and its voice-register writes (0x200-0x211). Coin at frame 400,
-- Start from 490, button 1 pulsed. Writes one line to OUTF at frame 3000. Run directly:
--   mame <set> -nodebug -video none -sound none -nothrottle -autoboot_script scripts/mame/qs1000_load.lua
--   with OUTF=<file> (and VC_LATCH=fc600000 for vegaeo) in the environment.
local mach = manager.machine
local LATCH = tonumber(os.getenv("VC_LATCH") or "fc600000", 16)
local cpu = mach.devices[":qs1000:cpu"]
local xs = cpu.spaces["xdata"]
local c = { latch = 0, xlo = 0, xhi = 0, wave = 0, maxhi = 0, per = 0 }
local lines = {}
_G.t1 = mach.devices[":maincpu"].spaces["program"]:install_write_tap(LATCH, LATCH + 3, "l", function(o, d, m) c.latch = c.latch + 1; return d end)
_G.t2 = xs:install_read_tap(0, 0xffff, "r", function(o, d, m)
  if o < 0x100 then c.xlo = c.xlo + 1 else c.xhi = c.xhi + 1; c.per = c.per + 1; lines[o >> 4] = true end
  return d end)
_G.t3 = xs:install_write_tap(0x200, 0x211, "w", function(o, d, m) c.wave = c.wave + 1; return d end)
local function field(name) for _, p in pairs(mach.ioport.ports) do if p.fields[name] then return p.fields[name] end end end
local fc, fs, fb = field("Coin 1"), field("1 Player Start"), field("P1 Button 1")
local n = 0
_G.s = emu.add_machine_frame_notifier(function()
  n = n + 1
  local k = n - 400
  if fc then fc:set_value((k >= 0 and k % 97 < 5) and 1 or 0) end
  if fs then fs:set_value((k >= 90 and (k - 90) % 211 < 5) and 1 or 0) end
  if fb then fb:set_value((k >= 96 and k % 20 < 4) and 1 or 0) end
  if c.per > c.maxhi then c.maxhi = c.per end
  c.per = 0
  if n == 3000 then
    local nl = 0; for _ in pairs(lines) do nl = nl + 1 end
    local f = io.open(os.getenv("OUTF"), "w")
    f:write(string.format("latch writes %d; xdata reads <0x100 %d, >=0x100 %d (max %d in a frame, %d distinct 16-byte lines); wave writes %d\n",
      c.latch, c.xlo, c.xhi, c.maxhi, nl, c.wave))
    f:close(); mach:exit()
  end
end)
