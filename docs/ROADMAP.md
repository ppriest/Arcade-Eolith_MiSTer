# Eolith — MiSTer Core Roadmap

**Scope approved by the user: Crazy War first, then the `eolith.cpp` sets, `eolith16.cpp` after. A
phase whose scope changes goes back for approval.**

## Context

Goal: one DE10-nano core for MAME's Eolith Hyperstone boards: `vegaeo.cpp` (Vega), `eolith.cpp`
(Gradation 2D) and `eolith16.cpp`, as one Quartus 17.0.2 project, one `.rbf`, a `.mra` per set, the
board type in the `.mra` mod byte. `ghosteo.cpp` is out (an ARM920T SoC at 200 MHz;
[`HARDWARE_NOTES.md`](HARDWARE_NOTES.md), "Other boards of the family").

What sets the shape: the CPU and the sound chip exist in `Arcade-Vamphalf_MiSTer`, verified against
MAME and running on the board. Every board here is a CPU drawing into a frame buffer, so the video is
a scan-out, not an engine. New work:

1. Board glue per type: address decode, inputs, NVRAM (AT28C16 on Vega, 93C66 on the others).
2. Frame-buffer scan-out: 8-bit with a palette RAM (Vega), 15-bit RGB (Gradation 2D), 8-bit with a
   fixed palette (`eolith16`).
3. The QS1000 board in two wirings: on the main CPU's latch with a 512 KB banked ROM (Vega), and
   behind a sound CPU over the 8052 UART (Gradation 2D).
4. CPU throughput: the games draw every pixel in software; the RTL runs at about 0.4 of MAME's
   instruction rate (open item 1). Vamphalf is speeding up the E1; this core takes those changes.

Cross-cutting findings: [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md). Working practice:
[`WORKFLOW.md`](WORKFLOW.md).

## Progress

**Phases 0-4 done in simulation; Crazy War and Hidden Catch play on the board (user reports). Phase 5
(eolith16) works in simulation; the core with it meets timing at 57.27 MHz and is released
(`20261010`).**

- Build of `3f882db` (the three boards, the flip screen, hidctch3's pens; `e1_pipe` timing changes,
  `rtl/e1/PROVENANCE.md`): clk_sys setup slack +0.867 ns at seed 2, +1.120 ns at seed 1; 30,445 ALMs
  (73%), 439 M10K (79%), 46 DSP. Deployed (seed 2) with every `.mra`, KlonDike+ and Hidden Catch 3
  included (their zips on the device, MD5 checked). On the board (user reports): Hidden Catch 3 works, and
  a quick test of a number of the other sets ran them all. Released as
  `releases/Arcade-Eolith_20261010.rbf` (the deployed seed 2 bitstream, MD5 `4f0e678f`).

- Build of `ba71e9f` (Phase 4 through step 5, the Gradation 2D board and hidnctch's `.mra`): clk_sys setup
  slack +0.234 ns, 434 M10K (78%), 45 DSP. Deployed with hidnctch's `.mra` and `hidnctch.zip` (MD5
  checked). hidnctch runs on the board: its title screen 25 s after launch
  (`debug/hw/hidnctch_boot.png`); the user reports it playing correctly.
- On the device with that core: every `eolith.cpp` set's `.mra` but hidctch3's (its pens came later) and
  their ROM zips (`scripts/deploy_roms.py`, MD5 checked). Only hidnctch has run there; the others carry
  MAME's generic button names.
- Build of `6d63dac` (pipelined E1, the QS1000 board, fast load), seed 2: clk_sys setup slack
  +0.903 ns, 319 M10K (58%), 44 DSP; seed 1 failed by 0.439 ns inside `e1_pipe`. Deployed.
- Phase 4 steps 1-2 in simulation: the memory decode per board (`2e155de`) and one VRAM for the
  three boards (`4d7ac26`); Crazy War unchanged (video_check 40/40, sys_tb 2,000,000 PCs).
- Phase 4 steps 3-4 in simulation: the Gradation 2D I/O and the 93C66 (`rtl/eo_eeprom93cxx.sv`, the
  Vamphalf 93C46 model sized by parameters, in place of `jt9346`, which neither refuses locked writes
  nor goes busy). `sim/ee_tb` replays MAME's pin traffic for hidnctch (1,200 frames, from blank): all
  12,112 DO reads agree, and the final array equals MAME's saved one but for the two coin counters
  (9 coins in the logged run, none in the saved one). `sys_tb +board=1` on hidnctch: every data access
  agrees with MAME's bus trace up to the first vblank poll (instruction 415,698, where the timing
  differs); Crazy War: 178,383 of 178,383 data accesses agree. hidctch3's pens are not wired.
- Phase 4 step 5 in simulation: the Gradation 2D sound board (`rtl/qs1000/eo_sndcpu.sv`, the QS1000 in
  its `grad` mode). `sim/snd_tb +board=1` on MAME's latch log for hidnctch (1,200 frames, coin and
  start): 4,711 of 4,711 QS1000 register writes and 1,805 of 1,805 sound CPU data reads as MAME's.
  `jt8052_periph.v` gained timer 2 (vendor mode `track`); MAME's power-on RxD level is copied
  (`docs/MAME_KLUDGES.md`).
- Phase 4 step 6: an `.mra` for every `eolith.cpp` set but `raccoon` (MAME NOT_WORKING): 21 sets, clones
  under `_alternatives`, MAME's protection patch on the four AT89C52 sets (hidctch2 and landbrka checked
  against MAME's CPU view). hidctch3's light pens from the left analog sticks, with a cross drawn at each
  (mod byte bit 2); not checked against MAME. Button names come from the games' how-to-play screens; the
  sets still on MAME's generic names fail `validate_mra.py` and are held back from the device.
- Phase 5 in simulation: eolith16's I/O (`rtl/eo_main.sv`), the M6295 (`rtl/sound/eo_oki.sv`: jt6295 with
  Vamphalf's ROM bridge and granule cache, vendored unchanged), klondkp's `.mra`. `sys_tb +board=2`: the
  retired PCs agree with MAME's for 1,664,401 instructions, to the first vblank poll; scan-out
  (`video_tb`, `eolith_capture.py klondkp`) pixel-identical on 6 of 6 frames, attract and play. The
  M6295's output is not compared with MAME's.
- Gradation 2D scan-out: `sim/video_tb` on MAME's frame buffer (`scripts/eolith_capture.py hidnctch`, the
  buffer copied by write taps in `vcap.lua`: eolith.cpp's `m_vram` is not a save item Lua lists) is
  pixel-identical on 6 of 6 frames, attract and play (frames 300-1800). The whole-board bench runs
  hidnctch through its ROM check to the attract (`debug/sysg/`, 600 frames).

- E1 vendored from Vamphalf `c0d8a76` (`scripts/vendor.json`, `vendor_sync.py`: 0 local edits).
- `sim/e1_tb` on `crazywar` from reset (`scripts/mame_e1_trace.py crazywar 2000000`, about three
  frames of the boot): 2,000,000 of 2,000,000 instructions match MAME (PC, SR, globals, locals, every
  bus access) at 0 and 3 wait states; 2.13 and 2.51 clocks an instruction.
- No interrupts: over 3,000 frames, 0 timer, INT1-4 or IO entries on all 16 sets of the three drivers
  (`scripts/mame_irqcount.py`; Mission Craft as the positive control, 785 INT2 entries in 598
  frames). The games poll vblank; the E1 timer is not on this core's path.
- Phase 2 in simulation: `sim/sys_tb` runs `rtl/eo_main.sv` (E1, `rtl/eo_cpumem.sv` generated from
  Vamphalf's memory unit by `scripts/gen_eo_cpumem.py`, `eo_video`, the Vega I/O) on the real
  `sdram.sv` and a chip model, from the `.mra` image (`scripts/build_mra.py`, proved equal to
  `ROM_START` and, by `scripts/mame_cpuview.py`, to MAME's CPU view). The retired PCs of all 2,000,000
  traced instructions agree with MAME. 900 frames reach the attract's ship scene (`debug/sys900/`), at
  3.83 clocks an instruction; the RTL is behind MAME (MAME shows "Galaxy 544year" by frame 195 and the
  ship by 420; the bench at 300 and 600).
- First build (`7c95a06`): Quartus successful, clk_sys setup slack +1.552 ns, 22,531 ALMs (54%),
  431 M10K (78%), 40 DSP. 324 of the M10K were `eo_video`, which Quartus had stored twice; `b9f2c7c`
  moves VRAM and palette into `vh_dpram` (160 + 1 expected). Deployed with its `.mra`; `crazywar.zip`
  copied to `/media/fat/games/mame` (MD5 checked).
- Phase 1 met: `scripts/render_model.py` (`screen_update_vega` transcribed) and the scan-out RTL
  `rtl/eo_video.sv` (`sim/video_tb`, `scripts/video_check.py`) are each pixel-identical to MAME on 40
  of 40 captured `crazywar` frames, attract and play (`scripts/eolith_capture.py`, frames 120-3045).

## Game scope

| Set | Driver | Board | CPU | Loaded | MAME flags | Phase |
|---|---|---|---|---|---|---|
| `crazywar` | vegaeo | Vega II | GMS30C2132, 55 MHz | 34.56 MB | - | 0-3 |
| 14 parents, 7 clones | eolith | Gradation 2D | E1-32N, 44.9/45/50 MHz | 14-34.5 MB | `raccoon` NOT_WORKING, `candy` IMPERFECT_GRAPHICS | 4 |
| `klondkp` | eolith16 | 9812C | E1-16T, 60 MHz | 3 MB | - | 5 |

### Scope decision

- **First target: `crazywar`.** Its sound is Vamphalf's QS1000 wiring; its CPU load in MAME is the
  lowest of the family (0.25 / 0.30 of a frame, attract / play, 0.7% of play frames saturated); its
  memory map is `eolith.cpp`'s.
- **Second: the `eolith.cpp` sets**, starting with the lightest in MAME (`hidnctch`, `nhidctch`,
  `penfan`, `stealsee`).
- **Out:** `ghosteo.cpp` (no path to a 200 MHz ARM920T with MMU; shares only the QS1000).
- **Memory:** 64 MB SDRAM module (user decision); `crazywar` and 16 of 21 `eolith.cpp` sets exceed
  32 MB with no duplicate ROMs.

## Hardware reality: Crazy War (`vegaeo.cpp`)

### Chips

| Part | Clock | Source | Role |
|---|---|---|---|
| GMS30C2132 (E1-32, 32-bit bus, 4 KB IRAM) | 55 MHz | 187; `e132xs.cpp:330` | everything |
| QS1000 + internal 8052 | 24 MHz | 212 | sound |
| AT28C16 | | 191 | 2 KB NVRAM |
| EV0514-001 | 14.31818 MHz crystal (PCB 239) | | video |

### Clocks

MAME has no pixel clock (`set_size(512, 262)`, `set_refresh_hz(60)`, 195-198). The crystal beside
the video chip is 14.31818 MHz; the dot clock is taken as half of it, 7.15909 MHz, with H total 455,
V total 262 (60.05 Hz) until a board measurement says otherwise (open item 2).

**`clk_sys` = 57.2727 MHz (630/11), 8x the dot clock; SDRAM on the same clock.** 7x (50.11 MHz,
nearest the ~48 MHz default) is below the 55 MHz CPU clock, so 8x is the lowest multiple that
satisfies "at least every board clock". The E1 RTL's throughput scales with it. Vamphalf meets
56 MHz with +0.897 ns (its build `5970f0d`); 57.27 MHz is 0.40 ns shorter. The first build confirms.

| Enable | From 57.2727 MHz | Ratio |
|---|---|---|
| dot | 7.15909 MHz | 1/8, exact |
| E1 timer tick | 55 MHz | 121/126 |
| 8052 oscillator | 24 MHz | 44/105 (never two in a row, as jt8052 needs) |
| QS1000 tick | 750 kHz | every 32nd 8052 enable |

### Interrupts

None taken. FCR = 0xFF7FFFFF enables only the timer, but TCR stays 0x80000000 and no timer entry
occurs in 3,000 frames (`mame_irqcount.py`). Vblank is polled at 0xfcc00000 bit 6.

### Memory map (`vega_map`, 116-129)

| Range | What |
|---|---|
| 0x00000000-0x001fffff | RAM, 2 MB in MAME (PCB: two 256K x16 DRAMs, 1 MB); code runs here (idle PC 0x8cf8) |
| 0x80000000-0x80013fff | VRAM window: 80 KB of the buffer selected by 0xfca00000 bit 0; byte 0xff not written (89-99) |
| 0xc0000000-0xc0000fff | E1 internal RAM |
| 0xfc000000-0xfc0000ff | AT28C16, low byte lane (120) |
| 0xfc200000-0xfc2003ff | palette, 256 x xRGB555, low halfword lane (121, 202) |
| 0xfc400000-0xfc40005b | CRT registers, ignored (122) |
| 0xfc600000 | sound latch, low byte (123) |
| 0xfca00000 | bit 0: buffer the CPU sees; the display shows the other (101-106, 179) |
| 0xfcc00000 | SYSTEM: coin, starts, service, test, bit 6 vblank (125, 132-141) |
| 0xfce00000 | P1/P2 joysticks and two buttons each (126, 143-160) |
| 0xfd000000-0xfeffffff | `maindata`, 32 MB (127) |
| 0xfff80000-0xffffffff | program ROM `u7`, 512 KB (128) |

### Video

Two 320 x 256 byte buffers (0x14000 each, 164-171); 320 x 240 shown through a 256-entry xRGB555
palette (173-183). No layers, sprites, scroll or flip. Aspect 4:3, ROT0. The frame buffer is the
board's own (two buffers, a select bit), which is the evidence the standing rule asks for.

### Sound

QS1000 on the main CPU's latch (208-217): the latch's pending flag is the 8052's IRQ; P1 reads the
latch; P3 bits 0-2 select a 64 KB page of `bgm.u84` (512 KB) for data reads at 0x0100-0xffff
(77-87, 298-303); P3 bit 5 low acknowledges. Program reads are the first 32 KB of `bgm.u84`
(`qs1000.cpp:144`). Samples: `effect.u85` 1 MB at 0, `qs1001a.u86` at 0x200000.

### Per-game configuration

One set; the board type byte selects Vega. No DIPs in MAME (TODO at 12): settings live in the AT28C16.

## Component reuse map

| block | plan | source |
|---|---|---|
| E1 CPU | vendored, unchanged; resynced when Vamphalf's speed-up lands (`scripts/vendor_sync.py`) | `Arcade-Vamphalf_MiSTer/rtl/e1/` at `c0d8a76`; written from MAME's E1 interpreter (BSD-3-Clause), project GPL-3.0 |
| E1 bench and MAME trace tools | vendored, retargeted to `regions.json` | Vamphalf `sim/e1_tb`, `scripts/mame_e1_trace.py`, `scripts/mame/e1trace.lua`, `scripts/e1trace_convert.py` |
| CPU memory unit (caches, IRAM, write buffer, instruction port) | Vamphalf's `vh_cpumem.sv` as the starting point, with this board's decode; VRAM, palette and I/O bypass the caches | Vamphalf `rtl/vh_cpumem.sv`, `rtl/vh_cache.sv` |
| 8052 | vendored | Vamphalf `rtl/qs1000/jt8052` (jotego JT8051, GPL-3.0-or-later, with Vamphalf's changes in its `PROVENANCE.md`) |
| QS1000 voice engine | vendored, unchanged | Vamphalf `rtl/qs1000/vh_qs1000_voice.sv` |
| QS1000 board | Vamphalf's `vh_qs1000.sv` with the program in BRAM (32 KB) and the banked data reads from SDRAM | Vamphalf `rtl/qs1000/vh_qs1000.sv` |
| SDRAM controller, download, DDR3 loader | vendored | Vamphalf `rtl/memory/` (Sorgelig's `sdram.sv` lineage via KonamiGX; see its `PROVENANCE.md`) |
| Debug probe and trace | vendored | Vamphalf `rtl/debug/` |
| CRT Adjust, rotation | vendored | Vamphalf `rtl/video/crt_adjust.sv`, `screen_rotate_two.sv` |
| Frame-buffer scan-out, palette | written from the driver | `vegaeo.cpp:173-183` |
| AT28C16 | written from the driver | `machine/at28c16.cpp` |
| 93C66 (Phase 4, 5) | `rtl/eo_eeprom93cxx.sv`, `AW=9, DW=8`: Vamphalf's 93C46 model (MAME's lock, busy and read timing; `jt9346` has neither) with the size as parameters and the array in block RAM | Vamphalf `rtl/vh_eeprom93c46.v` (from Arcade-KonamiGX_MiSTer), GPL-3.0-or-later |
| OKI M6295 (Phase 5) | Vamphalf's `jt6295` | Vamphalf `rtl/sound/` |

## On-chip RAM budget (Crazy War)

| Memory | Size | M10K |
|---|---|---|
| VRAM, 2 x 80 KB x 8 | 1,310,720 bits | 160 (1K x 8) |
| QS1000 program, first 32 KB of `bgm.u84` | 262,144 bits | 32 |
| E1 IRAM 4 KB | | 4 |
| CPU caches (Vamphalf's sizes: 16 KB I, 4 KB D, tags) | | ~24 |
| palette 256 x 16, AT28C16 2 KB, 8052 RAM, voice state | | ~6 |
| Framework, CRT Adjust (without V-Size) | | from the first build |

About 226 of 553 blocks (41%) before the framework. The one to watch is VRAM: the Gradation 2D's
15-bit VRAM needs 240 blocks for lines 0-239 and the same array is reused there.

## Memory plan

64 MB SDRAM on `clk_sys`, Vamphalf's controller (burst-4 granules, 16-byte double read). Layout in
`rtl/eo_sdram_map.svh` when written; the `.mra` generator reads it.

| What | Size | Where |
|---|---|---|
| `maindata` | 32 MB | SDRAM |
| program `u7` | 512 KB | SDRAM, through the I-cache |
| work RAM | 2 MB | SDRAM, through the caches |
| `bgm.u84` | 512 KB | SDRAM (data pages); first 32 KB also in BRAM (program) |
| samples | 2.5 MB (0-0x27ffff) | SDRAM |
| VRAM, palette | 161 KB | BRAM: the CPU writes every pixel, and the scan-out reads it every dot |

Ports, fixed priority: 0 the QS1000 sample lines (a 750 kHz deadline), 1 the 8052's page reads, 2 the
CPU and the download. DDR3: the HDMI rotator only (the games are ROT0); fast ROM loading at load time.

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** Each goes in
`docs/MAME_KLUDGES.md` when implemented.

**Where a vendored module and MAME disagree, record it and keep the module.**

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands.

**Transcribe the reference literally first, then look for the chip.**

**One `.rbf` for all games.** Board type and per-set differences are `.mra` mod bytes.

**Two Quartus revisions, `Eolith_stp` and `Eolith`,** differing only by `DEBUG_ISSP`.

**Licence: GPL-3.0.** The E1 and QS1000 come from a GPL-3.0 core; jotego's modules are
GPL-3.0-or-later. `sys/` is never edited.

**A frame buffer, because the boards have one.** `vegaeo.cpp:168` (two 0x14000 buffers),
`vega_misc_w` bit 0 (105); `eolith.cpp:227` and `systemcontrol_w` bit 7 (285). No sprite engine.

**VRAM in BRAM.** The CPU writes 29,000-95,000 VRAM dwords a frame on Crazy War (`mame_load.py`);
behind the SDRAM those writes would compete with the CPU's own misses.

**The E1 is a vendored copy, not a fork.** It is changed only in Vamphalf and copied here; local
needs go in the glue around it. `scripts/vendor_sync.py` reports when Vamphalf's copy has moved.

**The E1 runs unthrottled; its timer ticks at the board's clock.** As Vamphalf (its `HACKS.md`): the
RTL is slower than MAME's E1, so a clock enable would only slow it further. MAME's E1 ignores the
wait states the games program into BCR (MEM3 8 cycles), so the board is slower than MAME by an
unmeasured factor (open item 1).

**No multiplies, no divides** in the video path or the glue.

## Pitfalls that already bind decisions here

| Entry | What it binds here |
|---|---|
| Vamphalf `LESSONS_LEARNED.md`: register-write queue pushes under constant indices | The vendored E1 is not edited; Quartus and Verilator read the old form differently |
| Vamphalf: vblank is INT2, not INT1 | Here no external interrupt is used at all (FCR); the timer path is the one to verify |
| "Suspect your own integration before any vendored module" | A divergence from MAME is looked for in the new glue first |

## Phased roadmap

**Phase 0 — Vendoring and the CPU on Crazy War. The gate.**

1. Vendor the E1, its bench and the MAME trace tools; `vendor_sync.py` reports zero drift.
2. **The E1 bench matches MAME on `crazywar` from reset**, PC/SR/registers after every instruction
   and every bus access, at 0 and 3 wait states. — Met for the boot: 2,000,000 instructions. Attract
   is covered by the whole-board bench's retired-PC comparison (Phase 2): a full trace is about 1 KB
   an instruction and E: has 8 GB free.
3. **CPI on `crazywar` code**, zero-wait and with the planned latencies. — Boot: 2.13 / 2.51 (0 / 3
   waits). Game code with the real memory unit: Phase 2's `sys_tb`.
4. **Interrupts.** — Met: none taken by any set in 3,000 frames; the timer is wired (tick at 55 MHz)
   and not checked further.
5. Vendor jt8052, the voice engine and the memory modules; their own benches pass unchanged.

**Phase 1 — Video against MAME.** `mame_capture.py` frames of VRAM, palette and the buffer bit; a
`render_model.py` that reproduces `screen_update_vega`; the scan-out RTL pixel-identical to it on
captured frames. Exit: 30 or more captured frames identical in simulation.

**Phase 2 — The board in simulation, then on the DE10-nano.** Top level with the CPU memory unit,
SDRAM, download, `.mra`, inputs, AT28C16 to `.nvm`, the probe and debug page. Then the standard
feature set: CRT Adjust, hiscore, fast DDR loading, HDMI scaling and crop, rotation, audio mix,
HDMI-only options hidden under direct video, CRT parameters hidden until enabled, flip screen
(no flip register on the board: a fake DIP, one video path, checked against the unflipped frame
turned 180 degrees), Pause. Exit: Crazy War boots and plays on the board, silent; its frame rate
against MAME's measured.

**Phase 3 — Sound.** The QS1000 board with the Vega wiring. Exit: register writes in the same order as
MAME's over 600 frames in the whole-board bench; judged by ear on the board.

**Phase 4 — The `eolith.cpp` sets.** Board type 1 in the mod byte. In order:

1. `eo_cpumem` decode per board (`gen_eo_cpumem.py`): work RAM at 0 and at 0x40000000, VRAM window
   at 0x90000000, the rest as Vega.
2. One VRAM for every board: four banks of 40,960 x 15 bits (240 M10K). Vega's bytes one a location;
   the Gradation 2D's 15-bit pixels for lines 0-239 of both buffers; `eolith16`'s 2 x 64 KB. Lines
   240-389 of the Gradation 2D's buffers in SDRAM through the D-cache, the buffer bit in the cached
   address (only `candy` reads them back). The write rule: a whole halfword with bit 15 clear.
3. I/O: IN0 (inputs, EEPROM DO bit 3, vblank bit 6, random bits 8-9), system control (buffer bit 7,
   EEPROM bits 1-3, coin counter per set), the latch at 0xfc800000, DSW1; `hidctch3`'s pens.
4. 93C66 (`rtl/eo_eeprom93cxx.sv`, `AW=9, DW=8`).
5. Sound: the i8032 (a second `jt8052`, 12 MHz) with its 32 KB program in block RAM and the banked
   `sounddata` from SDRAM through a line buffer (at most 105 reads a frame in MAME, HARDWARE_NOTES);
   the latch on INT0, INT1 held asserted (`machine_reset`); its TxD into the QS1000's RxD. The QS1000
   in a second mode of `eo_qs1000`: serial in, P1 reads 1, no bank.
6. `.mra` per set: maindata layout, the protection patch for the four AT89C52 sets (checked against
   MAME's CPU view), the mod byte.
First set: `hidnctch` (light in MAME, no protection).

**Phase 5 — `eolith16.cpp`.** 16-bit bus, 8-bit VRAM with the fixed palette, OKI M6295.

**Phase 6 — Savestates, state dumps and cheats.** Optional; the RTL keeps state reachable from Phase 1.

## Verification strategy

- MAME drives the references from scripts: E1 traces, VRAM/palette captures, QS1000 register logs.
- The vendored modules' own benches are their regression; this core's benches cover the glue.
- `.mra` files are generated and read back byte for byte against `ROM_START`.

## Open items

1. **CPU throughput and the speed target.** The RTL is at about 0.4 of MAME's instruction rate;
   the board is slower than MAME by an unmeasured factor. Closed by the Phase 0 CPI, Phase 2's frame
   rate on the board, and PCB footage of a CPU-bound scene.
2. **Dot clock and totals.** 7.15909 MHz, 455 x 262 assumed; a board measurement or footage closes it.
3. **`clk_sys` at 57.27 MHz with three boards: met** from `3f882db` (+0.867 ns seed 2, +1.120 ns seed 1).
   With eolith16 added it had missed by up to 0.575 ns (`7b80205`), every failing path inside `e1_pipe`'s
   register-write queue and operand forwarding (`docs/LESSONS_LEARNED.md`, Timing closure, `[Eolith]`).
   The worst path now runs into the queue entries (`debug/worst_paths_build14.rpt`).
4. **`e1_pipe.sv` is a tracked copy** with this core's timing changes (`[EO]`, `rtl/e1/PROVENANCE.md`):
   Vamphalf's later changes are merged by hand, and each merge reruns the conformance suite
   (`scripts/e1_regress.py --replay --pipe` on Vamphalf's traces copied to `debug/e1`), Phase 0 item 2
   and the `sys_tb` PC comparisons. The `[EO]` changes could go to Vamphalf, which runs the CPU at
   56 MHz; editing Vamphalf from this session was refused by the permission check.
5. **Button 2's name.** The tutorial labels button 1 "SHOT"; button 2 has not been seen named.
6. **Button names** for the `eolith.cpp` sets other than the Hidden Catch games, from manuals or the games'
   own screens; `validate_mra.py` holds them back until then.

## Next steps

1. KlonDike+ and the flip screen on the board (Hidden Catch 3 works there, user report).
2. Sound judged by ear on the board (Phase 3's exit): Crazy War and Hidden Catch.
3. The other `eolith.cpp` sets on the board; their button names (Open items 6).
4. The standard features still missing: CRT Adjust, hiscore, direct-video menu hiding. Done: DIPs,
   Pause, NVRAM, fast load, audio mix, flip (simulation). HDMI rotation does not apply (every set is
   ROT0).
5. Frame-time readings on the board with the stp revision (`rtl/debug/eo_perf.sv`) against
   `scripts/mame_flips.py`.
6. Phase 6 (optional).
