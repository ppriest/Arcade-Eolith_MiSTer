# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `src/mame/eolith/` in `E:/mame` at `a2d0f76268e` (mame0289-661) unless named;
the binary is 0.289 (`docs/HARDWARE_NOTES.md`, header).

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

`crazywar` has no MAME flags. Of the `eolith.cpp` sets, `raccoon` is NOT_WORKING and `candy`
IMPERFECT_GRAPHICS.

## Video

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| A VRAM byte written as 0xff is not stored ("don't write transparent pen") | `vegaeo.cpp:89-94` | copies, `rtl/eo_video.sv` (`a_we`) | — (the board's behaviour as MAME models it; no contrary evidence) |
| No video timing: 512 x 262 at 60 Hz, 320 x 240 shown | `vegaeo.cpp:194-198` | differs: a 455 x 262 raster at 7.15909 MHz (60.05 Hz), vblank from line 240 as MAME's flag (`docs/HACKS.md`) | A board measurement |

## Sound

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| QS1000 volumes: ADPCM x4, PCM x1 | `qs1000.cpp:432-434`, `:479`, `:484-485`, `:513-514` | **differs**: the vendored engine's PCB balance, ADPCM x2, PCM x4 (`Eolith.sv` `.bal_pcb(1'b1)`; the benches keep MAME's). Evidence: Arcade-Vamphalf_MiSTer's `docs/MAME_KLUDGES.md`, a Mission Craft PCB recording; the same chip | A Crazy War PCB recording |
| No envelope or filter | `qs1000.cpp` TODOs | copies (the vendored engine) | A QS1000 datasheet or decap |
| No loop: a voice stops at its loop end; key-off does nothing | `qs1000.cpp:444`, `:465`, `:494` (`#if 0 // Looping disabled until envelopes work`), `:385-386` | **differs**: the voice goes back to its loop start (ADPCM with its saved decoder state) and key-off fades it, one rate for every sample (HACKS.md); `Eolith.sv` `.loop_pcb(1'b1)`, the benches 0. Evidence: Vamphalf's Mission Craft PCB recording (`docs/QS1000_FEATURES.md`, Recording) | The per-sample release rates: descriptor bytes 9-13 |
| Gradation 2D: the QS1000's RxD is low from power-on until the sound CPU first sends a 1 bit (`m_sound_txd` starts at 0; the i8032's reset writes P3 before its UART idles TxD high), so the first command (hidnctch: `B0 0A 40`) arrives misframed and is lost | `eolith.cpp:180`, `:318-322`; `devices/cpu/mcs51/i8051.cpp:1347`, `:1357` | copies, `rtl/qs1000/eo_sndcpu.sv` (`tx_lo`, `tx_up`). Evidence: MAME's QS1000 trace (`debug/snd/qs_pc_f1.txt`) takes two data bytes with no status byte at boot; without the copy the core's register writes differ from MAME's at the second write | On the board TxD is high from reset; a recording of the line, or none needed if MAME is fixed |
| Gradation 2D: the sound CPU's INT1 held asserted | `eolith.cpp:265` | **differs**: `/INT1` high (inactive), `eo_sndcpu.sv`. MAME's timer GATE counts while IE1 is set (`i8051.cpp:832`); the program runs timer 1 gated (TMOD 0xa1) as the UART's baud clock, and the part counts while the pin is high. The program never enables INT1, so the two agree on what it sees | — |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| `{{module}}` | {{MAME behaviour, file:line}} | {{module behaviour, file:line}} | {{silicon-derived / upstream bench / measured}} | {{what would show which describes the chip}} |
