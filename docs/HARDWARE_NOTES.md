# Eolith: hardware notes

What the board is, from MAME and any other source, each fact with where it came from.

Source: MAME `src/mame/eolith/eolith.cpp` in `E:/mame` at `a2d0f76268e` (`mame0289-661`), and
`mame -listxml` from MAME 0.289. Between the `mame0289` tag and that commit the driver and the E1
core differ only by refactors (`eolith.cpp:713` screen type, one rotate helper in `e132xsop.hxx`),
so captures from the 0.289 binary stand. Line numbers below are `eolith.cpp` unless named.
Everything is MAME's model unless marked otherwise.

## Sets

| Set | Game | Year | Parent | Machine config (CPU) | Init | ROM loaded | MAME flags | ROMs here |
|---|---|---|---|---|---|---|---|---|
| `linkypip` | Linky Pipe | 1998 | | eolith45 (45 MHz) | init_eolith | 18.06 MB | - | yes |
| `ironfort` | Iron Fortress | 1998 | | ironfort (44.9 MHz) | init_eolith | 18.06 MB | - | yes |
| `ironfortc` | Gongtit Jiucoi Iron Fortress (Hong Kong) | 1998 | ironfort | ironfort (44.9 MHz) | init_eolith | 18.06 MB | - | no |
| `hidnctch` | Hidden Catch (pcb ver 3.03) | 1998 | | eolith45 (45 MHz) | init_eolith | 26.06 MB | - | yes |
| `hidnctcha` | Hidden Catch (pcb ver 3.02) | 1998 | hidnctch | eolith45 (45 MHz) | init_eolith | 26.06 MB | - | no |
| `raccoon` | Raccoon World | 1998 | | eolith45 (45 MHz) | init_eolith | 14.06 MB | NOT_WORKING | yes |
| `puzzlekg` | Puzzle King (Dance & Puzzle) | 1998 | | eolith45 (45 MHz) | init_eolith | 34.06 MB | - | yes |
| `candy` | Candy Candy | 1999 | | eolith50 (50 MHz) | init_eolith | 34.06 MB | IMPERFECT_GRAPHICS | yes |
| `hidctch2` | Hidden Catch 2 (pcb ver 3.03, AT89C52 protected) | 1999 | | eolith50 (50 MHz) | init_hidctch2 | 34.03 MB | - | yes |
| `hidctch2a` | Hidden Catch 2 (pcb ver 1.00) | 1999 | hidctch2 | eolith50 (50 MHz) | init_eolith | 34.06 MB | - | no |
| `hidnc2k` | Hidden Catch 2000 (AT89C52 protected) | 1999 | | eolith50 (50 MHz) | init_hidnc2k | 34.53 MB | - | yes |
| `landbrk` | Land Breaker (pcb ver 3.02) | 1999 | | eolith45 (45 MHz) | init_landbrk | 34.06 MB | - | yes |
| `landbrka` | Land Breaker (pcb ver 3.03, AT89C52 protected) | 1999 | landbrk | eolith45 (45 MHz) | init_landbrka | 34.03 MB | - | no |
| `landbrkb` | Land Breaker (pcb ver 1.0, AT89C52 protected) | 1999 | landbrk | eolith45 (45 MHz) | init_landbrkb | 34.03 MB | - | no |
| `nhidctch` | New Hidden Catch (pcb ver 3.02) | 1999 | | eolith45 (45 MHz) | init_eolith | 34.06 MB | - | yes |
| `penfan` | Penfan Girls - Step1. Mild Mind (set 1) | 1999 | | eolith45 (45 MHz) | init_eolith | 34.06 MB | - | yes |
| `penfana` | Penfan Girls - Step1. Mild Mind (set 2) | 1999 | penfan | eolith45 (45 MHz) | init_eolith | 30.06 MB | - | no |
| `stealsee` | Steal See | 2000 | | eolith45 (45 MHz) | init_eolith | 34.06 MB | - | yes |
| `hidctch3` | Hidden Catch 3 (ver 1.00 / pcb ver 3.05) | 2000 | | hidctch3 (50 MHz) | init_eolith | 34.06 MB | - | yes |
| `fort2b` | Fortress 2 Blue Arcade (World) (ver 1.01) | 2001 | | eolith50 (50 MHz) | init_eolith | 34.06 MB | - | yes |
| `fort2ba` | Fortress 2 Blue Arcade (Korea) (ver 1.00) | 2001 | fort2b | eolith50 (50 MHz) | init_eolith | 34.06 MB | - | no |

All ROT0 (1769-1789). Per set: `maincpu` 512 KB, `maindata` up to 32 MB (`ROM_LOAD32_WORD_SWAP`),
sound CPU 32 KB (2 KB substitute for the AT89C52 sets), `sounddata` 512 KB, `qs1000:cpu` 32 KB,
`qs1000` samples 1 MB (`u97` plus the common `qs1001a.u96`); `hidnc2k` also loads an unused 512 KB
`oki` region. Region CRCs compared within each set: the only byte-identical copies are three
2 MB ROMs of `stealsee` that equal `12.u17`. Nothing else is stored twice, so 16 of 21 sets need
more than 32 MB and the core needs a 64 MB module.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| `maincpu` | Hyperstone E1-32N (MAME `E132`: 32-bit bus, 4 KB IRAM at 0xc0000000, `e132xs.cpp:116-118, 269-270`) | 45 / 50 / 44.9 MHz (692, 740, 746) | everything: game logic and all drawing, in software | `Arcade-Vamphalf_MiSTer/rtl/e1/e1_cpu.sv`, written from MAME's interpreter; matches MAME on 8,000,000 E1-32 instructions of `wivernwg`; timer interrupt unverified (its `docs/HACKS.md`) |
| `soundcpu` | 80C301 / GMS90C32 (i8032); AT89C52 on protected sets | 12 MHz (697) | reads the sound latch, sends commands to the QS1000 over the UART | `Arcade-Vamphalf_MiSTer/rtl/qs1000/jt8052` (jt8051 with 256-byte RAM, bit-op fix and a UART); UART unverified there |
| `qs1000:cpu` | 8052 inside the QS1000 | 24 MHz (728) | wavetable firmware, external program ROM (`set_external_rom`) | same `jt8052`: 3,000,000 instructions of Vamphalf's QS1000 firmware with 0 mismatches |
| `qs1000` | QDSP QS1000 (HWA Sound Source), 32 voices; its 8052 takes MIDI at 31.25 kbps on RXD (HWA datasheet) | 24 MHz; stream at clock / 32 = 750 kHz (`qs1000.cpp:233`); datasheet: 48 MHz master clock mode from a 24 MHz crystal | stereo sample playback; filter, LFO and envelope hardware MAME leaves out | Arcade-Vamphalf_MiSTer's `vh_qs1000_voice.sv`: MAME's model with IMA ADPCM, looping and a key-off fade (`docs/QS1000_FEATURES.md`, Register map) |
| `eeprom` | 93C66, 8-bit organisation, 512 B (704-706) | | settings, high scores | jotego `jt9346` (`AW=9, DW=8`), GPL-3.0-or-later, jtcores `5e665515d` |
| `soundlatch` | 8-bit latch, data pending -> sound CPU INT0 (726) | | main -> sound | trivial |
| EV0514-001 | Eolith custom (PCB notes 805) | 14.31818 MHz crystal beside it (785) | video timing and VRAM | none; MAME models only its effect |

## Clocks

| Clock | Source | Use |
|---|---|---|
| 44.9 / 45 / 50 MHz | 692, 740, 746; PCB notes 799, 981, 1051 | E1-32N core clock (no PLL on the non-X part) |
| 24 MHz | 728; PCB notes 803 | QS1000 and its 8052 |
| 12 MHz | 697; PCB notes 800 | sound CPU |
| 14.31818 MHz | PCB notes 785 (no line in MAME's config) | presumed video: 7.15909 MHz dot clock |
| HSync 15.64 kHz, VSync 60 Hz | PCB notes 806-807, measured on a board | |

MAME has no pixel clock: `set_refresh_hz(60)`, `set_size(512, 262)`, `set_visarea(0, 319, 0, 239)`
(714-717) are placeholders. 14.31818 / 2 / 15.64 kHz = 457.7 dots a line, so the dot clock and
H total are not settled by the driver (Open item in the roadmap).

## Video

- **A double-buffered 15-bit frame buffer.** Two 256 KB buffers (header 26; PCB: four
  KM6161002 64K x16, 802/984). `systemcontrol_w` bit 7 selects the buffer the CPU sees at
  0x90000000; the display scans the other (285, 240).
- Display: 320 x 240 from a line stride of 336 halfwords, `pixel & 0x7fff` as RGB555 (236-241,
  721). No layers, no sprites, no palette, no scroll, no flip register.
- CPU writes (206-215): a halfword is stored only when the whole halfword is written and bit 15 is
  clear. Byte writes and bit-15 pixels are dropped. So bit 15 is never stored: 15 bits a pixel.
  The driver's comment says candy needs this and other games "clearly don't", and that candy's
  erasing is wrong with it (header 70-75): a MAME kludge to reproduce and log.
- Header 22 claims "320x340 or 512x384"; no set in MAME uses a second mode.
- CRT registers at 0xfcc00000-0xfcc0005b are written and ignored (381).
- Aspect 4:3; all sets ROT0.

## Memory map

Main CPU (`eolith_map`, 372-384):

| Range | What | E1 area |
|---|---|---|
| 0x00000000-0x001fffff | RAM (2 MB in MAME; `fort2b` runs code here) | MEM0 |
| 0x40000000-0x401fffff | RAM (2 MB in MAME; board: "512Kbyte/1Mega", header 29; four IS61C1024 128K x8, 801/983). Programs run here | MEM1 |
| 0x90000000-0x9003ffff | VRAM window, 16-bit handler (376) | MEM2 |
| 0xc0000000-0xc0000fff | E1 internal RAM, mirrored to 0xdfffffff | IRAM |
| 0xfc000000 | IN0 read: inputs, bit 3 EEPROM DO, bit 6 vblank (line >= 240), bits 8-9 random (268-281) | MEM3 |
| 0xfc400000 | system control write: bit 7 buffer, bits 1-3 EEPROM CS/CLK/DI, bit 0 LED, coin counter bit per set (283-292) | MEM3 |
| 0xfc800000 | sound latch, low byte (379) | MEM3 |
| 0xfca00000 | DSW1 (380) | MEM3 |
| 0xfcc00000-0xfcc0005b | CRT registers, ignored (381) | MEM3 |
| 0xfd000000-0xfeffffff | `maindata` ROM, 32 MB (382) | MEM3 |
| 0xfff80000-0xffffffff | `maincpu` ROM, 512 KB, reset vector (383) | MEM3 |
| `hidctch3`: 0xfc200000 write | pen vibration, ignored (390) | |
| `hidctch3`: 0xfce00000 / 0xfcf00000 (mirror 0x80000) | light pen 1 / 2: `x + y * 336`, x 0-159, y 0-119 (294-302, 392-393, 617-627) | |

Sound CPU: program 0x0000-0x7fff ROM; data 0x0000-0x7fff `sounddata` bank of 32 KB selected by
P1 bits 0-3, 0x8000 latch read (403-412, 311-316). P3.1 (TxD) drives the QS1000 8052's P3 read
(318-322, 360-363); MAME needs `set_perfect_quantum` for that link (702). QS1000 8052: program
0x0000-0x7fff, data 0x0000-0x00ff RAM, 0x0200-0x0211 voice registers (`qs1000.cpp:144-151`); its
P1 read returns 1 (343-347).

## Interrupts

None taken. Nothing is wired from outside the CPU (no `set_vblank_int`, no input lines in 689-735).
Every set leaves FCR = 0xFF7FFFFF (INT1-INT4 and IO1-IO3 inhibited, the timer enabled at priority 6,
`e132xs.cpp:1387-1388`), but TCR stays 0x80000000 and no set takes a timer, INT or IO entry in 3,000
frames: `scripts/mame_irqcount.py` (vector fetches counted by tap; Mission Craft, which takes INT2 at
vblank, gives 785 entries in 598 frames as the positive control). The games poll vblank (IN0 bit 6).

## Inputs, DIPs, EEPROM, protection

- Two players, 8-way joystick, two buttons (three on `linkypip`), Start 1/2, Coin 1 (Coin 2 on
  several), Service, Test (421-465 and per-set ports to 680). `hidctch3`: two light pens.
- DSW1: two 4-switch banks (SW3, SW4); per-set meanings in the input ports.
- The AT89C52 sets (`hidctch2`, `hidnc2k`, `landbrka`, `landbrkb`) run a 2 KB substitute sound
  program marked `BAD_DUMP` and have one branch in the main CPU ROM patched to NOP
  (`patch_mcu_protection`, 1714-1758). That is MAME's kludge, reproduced at load time.
- Coin counter bit: 0x1000 `landbrk`, 0x2000 `landbrka`/`landbrkb`, none elsewhere (1707-1746).

## Bus timing the games program

BCR after boot, decoded per `e132xs.cpp:476-500`: MEM1 (work RAM) and MEM2 (VRAM) 2-cycle access;
MEM3 (ROM and I/O) 8 cycles (BCR 0xF7xxxxxx, all sets but one), 11 cycles on `raccoon`
(0xFA1501C4). MAME logs BCR and ignores it ("No emulation of memory access latency and pipeline",
`e132xs.cpp` TODO), so MAME runs the E1 at about one instruction a clock with every access free:
711,000 instructions a frame on `ironfort` at 44.9 MHz (`scripts/mame_pcprof.py`). MAME's own note
that Raccoon World's "animation & timers seem too fast" (header 77-80) fits a MAME E1 faster than
the board; it is not proof.

## Measured load (MAME 0.289)

`python scripts/mame_load.py <set> --frames 1800 --coin 0|600`, frames 301-1800, attract and play
(coin at 600, then Start, Right held in 2 s bursts, Button 1 pulsed). Work = share of a frame the
main CPU is not in its vblank wait (the set's PC in `eolith_speedup.cpp`); saturated = no wait at
all. Accesses are per frame, 32-bit unless noted.

| Set | Work mean (attract / play) | Frames > 0.4 work (play) | Saturated (play) | Flips/s (play) | VRAM writes max | ROM reads max | Off-screen VRAM read |
|---|---|---|---|---|---|---|---|
| puzzlekg | 0.75 / 0.83 | 96% | 2% | 59.5 | 180,504 | 140,207 | no |
| raccoon | 0.80 / 0.78 | 99% | 11% | 53.6 | 152,575 | 112,280 | no |
| linkypip | 0.64 / 0.73 | 92% | 12% | 52.7 | 111,576 | 115,744 | no |
| ironfort | 0.63 / 0.65 | 66% | 37% | 40.8 | 148,828 | 148,836 | no |
| landbrk | 0.60 / 0.49 | 78% | 5% | 57.3 | 169,615 | 146,936 | no |
| fort2b | 0.51 / 0.45 | 39% | 16% | 50.2 | 105,021 | 51,166 | no |
| hidctch3 | 0.48 / 0.45 | 34% | 16% | 51.6 | 181,646 | 143,306 | no |
| hidnc2k | 0.42 / 0.44 | 27% | 20% | 48.0 | 179,663 | 87,720 | no |
| hidctch2 | 0.39 / 0.44 | 39% | 11% | 53.4 | 112,671 | 107,321 | no |
| hidnctch | 0.31 / 0.42 | 25% | 1% | 58.7 | 260,996 | 110,228 | no |
| stealsee | 0.45 / 0.42 | 67% | 0% | 59.8 | 77,966 | 75,340 | no |
| penfan | 0.32 / 0.42 | 25% | 6% | 56.7 | 117,120 | 118,267 | no |
| candy | 0.47 / 0.41 | 56% | 0% | 59.9 | 120,960 | 133,717 | **yes**, to line 374 |
| nhidctch | 0.31 / 0.41 | 23% | 3% | 58.2 | 220,080 | 115,385 | no |

- VRAM above line 239: 9 of 14 sets write it (clears of the whole 256 KB buffer); only `candy`
  reads it back (up to 19,955 reads in a frame).

## Feasibility

The board is small in chips and large in one place: the CPU does all the drawing, and MAME runs
it with free memory access. Everything except CPU throughput has a plan from parts that exist.

| Block | State |
|---|---|
| ROM, 34.5 MB worst | 64 MB SDRAM module (user decision); DDR3 at load time only |
| VRAM, 2 x 256 KB | Lines 0-239 of both buffers in M10K: 2 x 80,640 halfwords x 15 bits = 240 blocks (43%) at 2K x 5. Lines 240-389 (rarely read, `candy` only) in SDRAM behind a write buffer. All of it in M10K would be 384 blocks (69%) |
| Video out | Scan-out of a frame buffer: no sprite or tile engine. The rule "frame buffer only with driver evidence" is met: the board has one (VRAM, `systemcontrol_w` bit 7) |
| Sound | jt8052 twice (sound CPU, QS1000 CPU) and Vamphalf's QS1000 voice engine (`docs/QS1000_FEATURES.md`) |
| EEPROM | jt9346 |
| CPU function | Vamphalf's `e1_cpu.sv`; matches MAME on 2,000,000 instructions of the `crazywar` boot; no interrupts are used |
| **CPU throughput** | **The blocking unknown, below** |

**CPU throughput.** Vamphalf's E1 RTL takes 2.71 clocks an instruction on a zero-wait bus and
about 6.9 in its full system with SDRAM caches (Vamphalf ROADMAP, Progress). At a ~50 MHz
`clk_sys` that is 18.5 MIPS at best, against MAME's ~43 (45 MHz sets) and ~48 MIPS (50 MHz sets):
0.39-0.43 of MAME's instruction rate before any memory stall. In MAME, 13 of 14 sets spend more
than 0.4 of a frame working in at least a quarter of their play frames, and three (puzzlekg,
raccoon, linkypip) in more than 90% of them. At the current RTL's speed those frames would
overrun, and the games would update less often than in MAME.

What is not known is how fast the board is. MAME ignores the 2-cycle RAM and 8-cycle ROM accesses
the games program into BCR, so the real E1 is slower than MAME by an unmeasured factor; if it is
near the RTL's, the RTL already matches the board.

| Unknown | Measurement that closes it |
|---|---|
| U1. RTL instruction rate on Eolith code | Run `e1_cpu` in Vamphalf's bench on MAME traces of `ironfort` and `puzzlekg` (boot and busy frames): clocks per instruction at zero wait and with the planned cache/SDRAM latencies |
| U2. The board's speed relative to MAME | PCB footage of a CPU-bound scene: `ironfort`'s attract fade (15 fps in MAME, one frame every 4 vblanks), `raccoon` play speed, `puzzlekg` frame rate. Count vblanks per update and compare |
| ~~U3. E1 timer interrupt in the RTL~~ | Closed: no set takes an interrupt (Interrupts, above) |
| U4. Off-screen VRAM use beyond our runs | Longer play runs per set, `mame_load.py` off-screen counters; the hybrid VRAM plan holds regardless |
| U5. Dot clock and H/V totals | A board measurement or footage; until then 7.15909 MHz (14.31818 / 2) |

Nearest existing core: Vamphalf (same CPU family, same QS1000). Its games are sprite-based and
light on the CPU: its busiest demo frame takes 66% of a frame at the RTL's speed. Eolith is the
CPU-heavy end of the same family.

## Other boards of the family

From `eolith16.cpp`, `vegaeo.cpp`, `ghosteo.cpp` in the same tree; loads from `mame_load.py`
(`BOARD` table) over frames 301-1800.

| | `eolith16.cpp` | `vegaeo.cpp` | `ghosteo.cpp` |
|---|---|---|---|
| Sets | `klondkp` (KlonDike+, 1999) | `crazywar` (Crazy War, 2002) | `bballoon`, `hapytour`, `touryuu`, `touryuua` (2003-2005) |
| CPU | E1-16T, 60 MHz, 16-bit bus (169) | GMS30C2132 (E1-32, 4 KB IRAM), 55 MHz (187) | Samsung S3C2410: ARM920T with MMU and 16 KB I/D caches, 200 MHz (`ARM9`, 12 MHz SoC crystal) |
| RAM | 2 MB at 0 (81) | 2 MB at 0 (118) | 32 MB SDRAM at 0x30000000 (417) |
| Program / data | 512 KB + 2 MB `maindata` at 0xff000000 (84) | 512 KB + 32 MB `maindata` at 0xfd000000, as `eolith.cpp` (127-128) | 32-66 MB NAND flash image, booted through the SoC's NAND controller |
| Video | 2 x 64 KB 8-bit buffers, bank by bit 7 of 0xffe80000 (65, 82); 320 x 200; fixed 3-3-2 resistor palette (145-164) | 2 x 80 KB 8-bit buffers, buffer by bit 0 of 0xfca00000 (105); 0xff not written (92); 320 x 240; 256-entry xRGB555 palette RAM (121, 202) | the SoC's LCD controller: 8 bpp palette or 16 bpp RGB565, 320 x 256 in MAME |
| Sound | OKI M6295, 1 MHz, pin 7 high (190) | QS1000 on the main CPU's latch: P1 reads it, latch drives the IRQ, P3 bits 0-2 bank a 512 KB program/data ROM in 64 KB pages, bit 5 acknowledges (77-87, 208-217) | QS1000 on the latch, as `vegaeo` |
| NVRAM | 93C66 | AT28C16, 2 KB parallel, byte lane at 0xfc000000 (120) | 24C16 I2C |
| ROM loaded | ~3 MB | ~34.6 MB | 34-68 MB flash + 1.5 MB sound |
| Interrupts | none taken in 3,000 frames | none taken in 3,000 frames | the SoC's |
| BCR, MEM3 access | 0xF7152584: 8 cycles | 0xF7110089: 8 cycles | n/a |
| Work mean (attract / play) | 0.50 / 0.38 at 60 MHz, 0.1% saturated | 0.25 / 0.30 at 55 MHz, 0.7% saturated | not measured |
| Shares with `eolith.cpp` | E1 (16-bit bus), 93C66, frame-buffer scan-out | E1-32, memory layout, frame-buffer scan-out, QS1000 | QS1000 only |

eolith16's VRAM is MAME's memory share in host order behind a 16-bit bus, read by the screen update as
bytes (132-141): the left dot of each pair is the low byte of the CPU's halfword, so CPU byte x is dot
x ^ 1. Found on klondkp's INSERT COIN text, whose VRAM writes were the same in the core and in MAME
(`debug/sysk/vwlog.txt`, MAME write taps) while the core showed every pixel pair swapped.

### The Gradation 2D sound CPU's traffic

`scripts/mame/sndcpu_load.lua`, 1,800 frames, coin at 400 and Start at 500 (repeated), button 1 pulsed:
reads of the banked `sounddata` window (data 0x0000-0x7fff) by the i8032.

| Set | Banked reads | Most in a frame | Frames with any | Distinct 16-byte lines | Latch commands |
|---|---|---|---|---|---|
| hidnctch | 3,009 | 69 | 233 | 42 | 66 |
| ironfort | 4,232 | 96 | 532 | 223 | 31 |
| puzzlekg | 61,532 | 105 | 1,015 | 2,048 | 28 |

### Crazy War's sound traffic

`scripts/mame/qs1000_load.lua`, frames 1-3000, coin at 400: the attract sends the QS1000 nothing (no
latch write, the 8052 idles in 0x0086-0x0167 with no xdata access). In play: 232 latch writes, 71,394
voice-register writes, 497,941 xdata reads of its RAM (0x0000-0x00ff) and 15,022 of the banked
`bgm.u84` window (0x0100-0xffff), at most 84 in a frame, over 647 distinct 16-byte lines.
