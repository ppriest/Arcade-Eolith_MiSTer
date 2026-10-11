# Eolith state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| VRAM, both buffers (all boards) | `eo_video.sv` `bank[0..3]`, port A is the CPU's | 4 x 15 x 40,960 | 307,200 (15 of 16 bits) | yes, through port A with `vbuf` stepped |
| VRAM above line 239 (Gradation 2D) | SDRAM `SD_VOFF`, through the D-cache | 2 x 256 KB window | 2 x 112,640 used | yes, from SDRAM after the write buffer drains |
| Palette (Vega) | `eo_video.sv` `pal` | 16 x 256 | 512 | yes, CPU port |
| 93C66 array (Gradation 2D) | `eo_eeprom93cxx.sv` `mem` | 8 x 512 | 512 | in the `.nvm`; a savestate also needs it (the `rd_*` port) |
| AT28C16 (Vega) | `eo_main.sv` `ee` | 8 x 64 | 64 | in the `.nvm` |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| Raster counters | `eo_video.sv` `hcnt`, `vcnt`, `line_base` | 9 + 9 + 16 | restore at frame start | screen position |
| CPU's buffer | `eo_main.sv` `vbuf` | 1 | yes | `m_buffer` |
| 93C66 pins and FSM | `eo_main.sv` `e9_cs/sk/di`; `eo_eeprom93cxx.sv` `st`, `cmd`, `nbits`, `shreg`, `addr`, `locked`, `wall`, `busy`, the sweep | ~70 | yes | eeprom_serial_base_device's save_items |
| AT28C16 write cycle | `eo_main.sv` `ee_cnt`, `ee_last` | 14 + 8 | yes | at28c16 |
| IN0 random bits | `eo_main.sv` `rnd` | 16 | no: MAME's are machine().rand() | - |
| Light pens (hidctch3) | `eo_pens.sv` `px`, `py`, `held` per player | 2 x (8 + 7 + 4) | yes | the PEN_X/PEN_Y ports' values |
| M6295 (eolith16) | `eo_oki.sv`: jt6295's channel state, the bridge's held byte, the granule cache (refetchable), `acc` | ~600 | yes, but the cache | okim6295 save_items |
| QS1000 board | `eo_qs1000.sv`: the 8052 (`jt8052`), its RAMs, the latch; `vh_qs1000_voice.sv`: `st_mem` (219 x 32: address, pitch accumulator, IMA ADPCM state, loop start, the IMA state saved there, fade level), `lv/rv/vv_mem`, `kf_mem`/`fe_mem` (the entry's rate, the bent rate), `rel_v`, `env_ctr`, the event queue (drain it), the sample lines (refetchable) | ~7,000 + RAMs | yes, but the queue and lines | qs1000 save_items (Arcade-Vamphalf_MiSTer `docs/STATE.md` lists each) |
| Sound CPU (Gradation 2D) | `eo_sndcpu.sv`: `jt8052` (its registers, SFRs and timer 2), `u_iram` 256 B, `latch`, `pending`, `bank`, the line buffer, `cacc`, `debt`, `tx_lo`/`tx_up` | ~2,300 + 256 B | yes; the line buffer may be refetched | i8032 save_items, `m_sndbank`, `m_sound_txd`, the latch |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| | | | | |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| | |

## Frame alignment

Restore point (normally `frame_start`), and anything whose phase must be saved with it: sprite or
tile double-buffer selection, snapshot ownership bits.
