// SDRAM layout (byte addresses), the source of truth for scripts/build_mra.py, which writes the
// index-0 download in this order. 64 MB module.
//
//   SD_DATA     32 MB    maindata (ROM_LOAD32_WORD_SWAP pairs, as MAME's region; eolith16: 2 MB, a
//                        ROM_LOAD16_WORD_SWAP, as MAME's region)
//   SD_PRG      512 KB   main CPU program ROM
//   SD_SNDPRG   512 KB   Vega: the QS1000 8052's program and data pages (bgm.u84)
//                        Gradation 2D: the QS1000 8052's program (32 KB), then at SD_SNDCPU the sound
//                        CPU's program (32 KB)
//   SD_SMP      2.5 MB   the QS1000 sample region from 0 (Vega: 0x280000 of it; Gradation 2D: 1 MB);
//                        eolith16: the M6295's "oki" region, 512 KB
//   SD_SNDDATA  512 KB   Gradation 2D: the sound CPU's banked sounddata
//   SD_WRAM     2 MB     work RAM at 0 (not downloaded)
//   SD_WRAM4    2 MB     Gradation 2D: work RAM at 0x40000000
//   SD_VOFF     512 KB   Gradation 2D: VRAM above line 239, both buffers
localparam [26:0] SD_DATA    = 27'h0000000;
localparam [26:0] SD_PRG     = 27'h2000000;
localparam [26:0] SD_SNDPRG  = 27'h2080000;
localparam [26:0] SD_SNDCPU  = 27'h2088000;
localparam [26:0] SD_SMP     = 27'h2100000;
localparam [26:0] SD_SNDDATA = 27'h2380000;
localparam [26:0] SD_WRAM    = 27'h2400000;
localparam [26:0] SD_WRAM4   = 27'h2600000;
localparam [26:0] SD_VOFF    = 27'h2800000;
localparam [26:0] SD_IMAGE_END   = 27'h2380000;   // Vega: end of the downloaded image
localparam [26:0] SD_IMAGE_END_G = 27'h2400000;   // Gradation 2D
localparam [26:0] SD_IMAGE_END_K = 27'h2180000;   // eolith16
