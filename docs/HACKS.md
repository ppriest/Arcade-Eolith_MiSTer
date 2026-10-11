# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does: a stand-in, a shortcut, a value chosen to make something work, a workaround for a
tool. Each entry is added in the commit that introduces the hack and removed in the commit that
removes it.

This is not `MAME_KLUDGES.md`. That file lists MAME's own guesses that the core reproduces on
purpose because MAME is the reference. This file lists what is ours.

Rules:

- An entry cites `file:line` (or a module and signal name if the line moves often), and the
  evidence column says what was measured, or "unverified".
- "What would make it correct" names the work, not "fix later".
- A hack whose entry is missing is a bug. A hack whose entry is stale is worse: update it in the
  same commit as the code.
- Severity is what a player or a verifier would see: **visible** (wrong pixels, wrong sound, wrong
  timing a game can hit), **latent** (wrong only for input no in-scope set produces), **tooling**
  (affects the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| `sys_tb` accepts a retired PC of MAME's + 2 when MAME's instruction is a TRAP | `sim/sys_tb/main.cpp` (`mame_trap`) | The vendored `e1_cpu` reports a TRAP's `retire_pc` as the halfword after it; execution matches MAME (the next PCs agree) | Vamphalf's `e1_cpu` reporting the TRAP's own address | crazywar instruction 44614 (TRAP 37 at 0xfffffd1c) | tooling |
| The 8052's timer 2 without its counter input (C/T2), T2EX (EXEN2) or the baud-rate modes (RCLK, TCLK) | `rtl/qs1000/jt8052/jt8052_periph.v` (`[EO]`, `tick2`) | Added for the Gradation 2D sound CPU, which runs it as a 10 ms timer (T2CON 0, RCAP2 0xd8ef); jt8052 had no timer 2 | The remaining modes, as MAME's `i8052.cpp` `update_timer_t2`, if a program uses them | hidnctch: 4,711 of 4,711 QS1000 register writes as MAME's (`sim/snd_tb`) | latent |
| Raster 455 x 262 dots at 7.15909 MHz; hsync dots 336-369, vsync lines 244-246 | `rtl/eo_video.sv` parameters | MAME gives no timing (`vegaeo.cpp:195-198` are placeholders); the dot clock is half the 14.31818 MHz crystal by inference, the totals and sync positions are chosen | A measurement of the board's dot clock, H/V totals and sync positions, or PCB footage with known timing | Unverified. 60.05 Hz against MAME's 60 Hz; vblank starts at line 240 as MAME's vblank flag | visible |
| The QS1000's key-off fade has one rate for every sample: env -= env >> 8 on every 732nd tick, a time constant of 0.25 s; the voice stops below -48 dB | `rtl/qs1000/vh_qs1000_voice.sv` `env`, `env_ctr`, `rel_v` (`loop_pcb`, vendored from Vamphalf) | The Mission Craft recording shows fades that differ by sample (`docs/QS1000_FEATURES.md`, Recording: one instrument still sounding 0.5-1.5 s after key-off, others gone within 150 ms), with different descriptor bytes 9-13; three samples do not decode those bytes | The rate from descriptor bytes 9-13, measured on more instruments | Notes keyed off in their first pass fade over 200-400 ms on average in the recording | visible (audible: release times) |
| Memory wait states: clocks added to each CPU data access, by E1 memory area (MEM3: ROM and I/O, MEM0-2: RAM and VRAM), from the `.mra` (bytes 1-2 of index 1, `build_mra.py` `WAITS`) or the Debug page when set; raccoon 15 and 2, the other sets 0 | `rtl/eo_busws.sv`, `Eolith.sv` (`ws3_mra`, `ws3_of`) | The board's E1 has no data cache and runs each access at the timing its BCR sets; the core's cache answers in a clock. raccoon's BCR (0xfa1501c4: MEM0-2 2 cycles, MEM3 11 + 1 hold, at 45 MHz) scaled to 57.27 MHz gives 15 and 2; the other sets' BCRs (MEM3 8 + 1, RAM 2) are not applied. Instruction fetches are not delayed | Every set's waits from its BCR and CPU clock, the instruction side too, checked against measured frame rates (PCB footage) | raccoon at 15 and 2: about the right speed on the board (the user); at 0, several times too fast. sys_tb: its loop from 1 frame to 3 | visible |
| Hidden Catch 3's `.mra` carries a default EEPROM, language English | `scripts/build_mra.py` `EEPROM_DEFAULT` (sent as `<rom index="2">` before `<nvram>`) | A board or MAME starts from a blank 93C66 and the game writes its own defaults, language Korea; ours is that default with byte 0x06 = 1 (English), the counters and the pens' offsets written as zero | Nothing to fix while English is wanted; a blank start is the hardware's | MAME from blank: `cb 06 03 02 00 01 00 00` at 0x00 (debug/hc3cal); the board's save after MAIN SETUP's English: 0x06 = `01` | visible |

<!-- Examples of the shape, from sibling cores:
| Sound mailbox is a stub that answers the power-on test | `rtl/gx_snd_stub.sv` | No sound CPU yet; the stub returns the reply the test expects and a heartbeat | Phase 3: the real sound board | The game's RAM check passes with it; nothing else is exercised | visible |
| Sound-command spin of 800 CPU clocks after a latch write | `rtl/cpu/…_bus.sv:NNN` | Copies MAME's 40 us wait; the real board's mechanism is unknown | A measurement of the latch on hardware | Without it the second byte overwrote the first (commit) | latent |
| Sound CPU reset held 1,024 clocks | `rtl/….sv:NNN` | MAME's pulse is zero-length; the T80 needs to see it | The measured reset length | A PCB measurement says about one second | latent |
| Screen timing from one game used for every game | `rtl/video/…crtc.sv` | MAME declares 60 Hz with no comment; the one PCB-verified rate is used for all | Per-game timing from PCB measurement | 0.043% from the verified rate | visible |
-->

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|
