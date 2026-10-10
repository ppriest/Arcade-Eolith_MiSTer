#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate rtl/eo_cpumem.sv from Vamphalf's rtl/vh_cpumem.sv.

    python scripts/gen_eo_cpumem.py [COMMIT]      default: Vamphalf's HEAD

Applies this board's decode, cached-space layout and video/I/O ports as exact text substitutions,
each asserted to match once, so the caches, write buffer, prefetch and port-2 logic stay Vamphalf's
text. When an assertion fails after an upstream change, edit the substitution here, not the output.
Afterwards set rtl/eo_cpumem.sv's commit in scripts/vendor.json to COMMIT.
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import load_env  # noqa: E402

VAMPHALF = Path(load_env().get("MISTER_CORES_ROOT") or REPO.parent) / "Arcade-Vamphalf_MiSTer"
COMMIT = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
s = subprocess.run(["git", "-C", str(VAMPHALF), "show", f"{COMMIT}:rtl/vh_cpumem.sv"],
                   capture_output=True, check=True).stdout.decode()


def rep(a, b, count=1):
    global s
    n = s.count(a)
    assert n == count, (n, a[:80])
    s = s.replace(a, b)


a = s[:s.index("module vh_cpumem")]
rep(a, """// The E1's memory system: address decode, the CPU's internal RAM, the caches in front of work RAM and
// the ROMs (in SDRAM), the video RAM port, the memory-mapped I/O, and the owner of sdram.sv's port 2.
// From Arcade-Vamphalf_MiSTer rtl/vh_cpumem.sv (scripts/vendor.json, mode track): the decode, the
// cached-space layout and the video/I/O ports are this board's; the caches, write buffer, prefetch and
// port-2 logic are Vamphalf's and are merged from it.
//
// Program space, per board (e132xs.cpp iram_4k_map for all):
//   all       0x00000000-0x001fffff  work RAM, 2 MB     SDRAM WRAM_BASE, through the caches
//             0xc0000000-0xdfffffff  internal RAM, 4 KB mirrored
//             0xfff80000-0xffffffff  program ROM 512 KB SDRAM ROM_BASE, through the caches
//   Vega      0x80000000-0x80013fff  VRAM window        eo_video (vid_*), the buffer it selects
//   (vegaeo)  0xfc200000-0xfc2003ff  palette            eo_video (vid_*)
//             0xfc000000-0xfcffffff  the rest: I/O      io_* (eo_main)
//             0xfd000000-0xfeffffff  maindata, 32 MB    SDRAM DATA_BASE, through the D-cache, read only
//   Gradation 0x40000000-0x401fffff  work RAM, 2 MB     SDRAM WRAM4_BASE, through the caches
//   (eolith)  0x90000000-0x90027fff  VRAM, lines 0-239  eo_video (vid_*), the buffer `vbuf` selects
//             0x90027600-0x9003ffff  VRAM, lines 240-  SDRAM VOFF_BASE + vbuf * 256 KB, through the caches;
//                                                       written as eolith_vram_w writes (be_w)
//             0xfc000000-0xfcffffff  I/O; 0xfd000000-0xfeffffff maindata, as Vega
//   eolith16  0x50000000-0x5000ffff  VRAM window        eo_video (vid_*)
//             0xff000000-0xff1fffff  maindata, 2 MB     SDRAM DATA_BASE, through the D-cache
//             0xffe00000-0xffefffff  I/O                io_* (eo_main)
//   anything else reads 0, writes are dropped; so is the E1's I/O space, which no Eolith board uses
//
// Caches: I 16 KB, D 4 KB, direct-mapped, 16-byte lines filled by one double read. Instruction fetches
// have their own port (if_*, 8 bytes) so fetch-ahead does not wait behind loads and stores. Stores to
// work RAM are written through: they update whichever cache holds the line and enter a four-entry
// write buffer (wq_*), each entry written as one burst. A miss waits for the buffer only while it holds a
// store to the missed line; otherwise its fill goes to SDRAM before the buffer.
// After every D-cache fill the next line is read into a 16-byte prefetch buffer when port 2 is idle; a D
// miss on that line fills from it in two clocks, waiting for it if it is on its way (S_PFW). A store to the
// buffered line, or to the line in flight (including in the clock it arrives), discards it. Port 2 serves
// the write buffer before the prefetch, so the prefetch never holds data older than a store.
//
// CPU bus timing (e1_cpu: req held until ack): a write is acked in its request clock, combinationally: one
// that takes effect in that clock (I/O, internal and video RAM), or a store the write buffer can take, whose
// cache and buffer update follows in S_WLOOK, from the address, lanes and data registered in the request
// clock (wl_*): e1_pipe holds bus_* through S_WLOOK only for Vamphalf's cached regions (ST_MWAIT) and
// otherwise issues a two-access job's second access in the ack clock. Reads of I/O and internal/video RAM ack from a
// register one clock after the request; a cache hit (S_LOOK) and a data fill (S_FILL2) ack combinationally.
// A read the CPU announced on la_* in the clock before its request, while the D-cache was free, was looked
// up then: a hit acks in the request clock.
// Instruction port: if_addr is looked up in every clock in which the data side, a fill or the sweep does
// not hold the RAM it needs (i_free); if_ack comes in the clock after a lookup of the address still
// requested, so a lookup of an address the CPU has since changed is dropped. An I-cache miss is filled by
// the data side's miss logic when that has no request. Fetches outside work RAM, program ROM and the
// internal RAM read 0.
// A store updates the I-cache in S_WLOOK, the clock it is acked in; the CPU drops any fetched 8 bytes the
// store hits, and every later lookup reads the new data.
//
// SDRAM port 2 (sdram.sv's toggle protocol, burst writes), in priority order: download writes (dl_*), line
// fills, the write buffer, the prefetch. It is reset only by prst (the PLL's lock), never by the core
// reset: MiSTer holds the core reset for the whole download (LESSONS_LEARNED, "Never hold the memory path
// in the core reset").
// SDRAM words hold the even byte in [7:0]; the CPU is big-endian, so data is byte-swapped at this seam.

""")
rep("""module vh_cpumem #(
	parameter [26:0] ROM_BASE  = 27'h0000000,
	parameter [26:0] WRAM_BASE = 27'h1800000,
	parameter [26:0] SPRHI_BASE = 27'h1a00000,
	parameter [26:0] PRGLO_BASE = 27'h0700000,
	parameter [26:0] AOHPRG_BASE = 27'h0300000
) (
	input             clk,
	input             prst,            // power-up only: the port-2 side
	input             rst,
	input             prg2,            // a 2 MB program: ROM from 0xffe00000
	input             aoh,             // aoh_map
	input      [31:0] aoh_sys,         // aoh's SYSTEM and P1_P2 ports, read at 0x8021xxxx and 0x8022xxxx
	input      [31:0] aoh_p12,
""", """module eo_cpumem #(
	parameter [26:0] DATA_BASE  = 27'h0000000,
	parameter [26:0] ROM_BASE   = 27'h2000000,
	parameter [26:0] WRAM_BASE  = 27'h2400000,
	parameter [26:0] WRAM4_BASE = 27'h2600000,
	parameter [26:0] VOFF_BASE  = 27'h2800000
) (
	input             clk,
	input             prst,            // power-up only: the port-2 side
	input             rst,
	input      [1:0]  board,           // 0 Vega, 1 Gradation 2D, 2 eolith16 (the .mra's mod byte)
	input             vbuf,            // the Gradation 2D's buffer the CPU sees (its VRAM above line 239)
""")
rep("""	// video RAMs (vh_video): registered reads, data one clock after the address
	output            spr_we,
	output     [3:0]  spr_be,
	output     [13:0] spr_addr,
	output     [31:0] spr_wd,
	input      [31:0] spr_rd,
	output            pal_we,
	output     [3:0]  pal_be,
	output     [13:0] pal_addr,
	output     [31:0] pal_wd,
	input      [31:0] pal_rd,

	// I/O: one-clock pulses; io_rdata is sampled in the clock of io_rd
	output            io_rd,
	output            io_wr,
	output     [18:0] io_port,         // bus_addr >> 13
	output     [31:0] io_wd,
	input      [31:0] io_rdata,
	input             io_late,         // this read's io_rdata is valid a clock after io_rd (a block RAM)
""", """	// VRAM window and palette (eo_video): one-clock strobes, read data one clock after the address
	output            vid_vram_cs,
	output            vid_pal_cs,
	output            vid_we,
	output     [3:0]  vid_be,
	output     [17:2] vid_addr,
	output     [31:0] vid_wd,
	input      [31:0] vid_rd,

	// memory-mapped I/O at 0xfc000000: one-clock pulses; io_rdata is sampled in the clock of io_rd
	output            io_rd,
	output            io_wr,
	output     [23:0] io_addr,
	output     [3:0]  io_be,
	output     [31:0] io_wd,
	input      [31:0] io_rdata,
	input             io_late,         // this read's io_rdata is valid a clock after io_rd (a block RAM)
""")
rep("""	output            dbg_miss_ic,
	output     [23:4] dbg_miss_line,
	output            xflip_we         // a write to 0xe000xxxx (jmpbreak_flipscreen_w): bus_wdata, bus_be
);""", """	output            dbg_miss_ic,
	output     [25:4] dbg_miss_line
);""")

a = s[s.index("// ---------------------------------------------------------------- decode"):s.index("// SDRAM granule")]
rep(a, """// ---------------------------------------------------------------- decode
// per board (board: 0 Vega, 1 Gradation 2D, 2 eolith16), the same for the data side, the instruction
// port and the CPU's look-ahead
localparam [2:0] RG_NONE = 0, RG_DATA = 1, RG_WRAM0 = 2, RG_WRAM4 = 3, RG_VOFF = 4, RG_ROM = 5;
function [2:0] sd_region(input [31:0] a, input [1:0] bd);
	if (a[31:19] == 13'h1fff)                                       sd_region = RG_ROM;
	else if (a[31:21] == 11'd0)                                     sd_region = RG_WRAM0;
	else if (bd != 2'd2 && (a[31:24] == 8'hfd || a[31:24] == 8'hfe)) sd_region = RG_DATA;
	else if (bd == 2'd2 && a[31:21] == 11'h7f8)                     sd_region = RG_DATA;   // 0xff000000, 2 MB
	else if (bd == 2'd1 && a[31:21] == 11'h200)                     sd_region = RG_WRAM4;  // 0x40000000
	else if (bd == 2'd1 && a[31:18] == 14'h2400 && a[17:0] >= 18'h27600) sd_region = RG_VOFF;
	else                                                            sd_region = RG_NONE;
endfunction
// the cached space: 0x0000000 maindata, 0x2000000 work RAM at 0, 0x2200000 work RAM at 0x40000000,
// 0x2400000 the Gradation 2D's VRAM above line 239 (the buffer the CPU sees, then the window offset),
// 0x3f80000 program ROM
function [25:0] cached(input [31:0] a, input [1:0] bd, input vb);
	reg [25:0] dofs;
	begin
		dofs = a[25:0] - 26'h1000000;                                // 0xfd000000 -> 0
		case (sd_region(a, bd))
			RG_WRAM0: cached = {5'b10000, a[20:0]};
			RG_WRAM4: cached = {5'b10001, a[20:0]};
			RG_VOFF:  cached = {7'b1001000, vb, a[17:0]};
			RG_ROM:   cached = {7'b1111111, a[18:0]};
			default:  cached = bd == 2'd2 ? {5'b00000, a[20:0]} : {1'b0, dofs[24:0]};
		endcase
	end
endfunction

wire mem    = !bus_io;
wire [2:0] rg = mem ? sd_region(bus_addr, board) : RG_NONE;
wire r_wram = rg == RG_WRAM0 || rg == RG_WRAM4 || rg == RG_VOFF;   // cached and writable
wire r_voff = rg == RG_VOFF;
wire r_rom  = rg == RG_ROM;
wire r_data = rg == RG_DATA;
wire r_iram = mem && bus_addr[31:29] == 3'b110;
wire r_vram = mem && (board == 2'd0 ? bus_addr[31:17] == 15'h4000 && bus_addr[16:2] < 15'h5000
                    : board == 2'd1 ? bus_addr[31:18] == 14'h2400 && bus_addr[17:0] < 18'h27600
                    :                 bus_addr[31:16] == 16'h5000);
wire r_pal  = mem && board == 2'd0 && bus_addr[31:10] == 22'h3f0800;
wire r_io   = mem && !r_pal && (board == 2'd2 ? bus_addr[31:20] == 12'hffe : bus_addr[31:24] == 8'hfc);
wire r_vid  = r_vram || r_pal;
wire r_sd   = r_wram || r_rom || r_data;  // through the caches
wire [25:0] caddr = cached(bus_addr, board, vbuf);
// the Gradation 2D's VRAM write rule above line 239 as below it: a whole halfword with bit 15 clear
wire [3:0]  be_w = r_voff ? {{2{bus_be[3] & bus_be[2] & !bus_wdata[31]}}, {2{bus_be[1] & bus_be[0] & !bus_wdata[15]}}}
                          : bus_be;

wire [31:0] ifa    = {if_addr, 3'b000};
wire [2:0]  i_rg   = sd_region(ifa, board);
wire        i_wram = i_rg == RG_WRAM0 || i_rg == RG_WRAM4;
wire        i_rom  = i_rg == RG_ROM;
wire        i_iram = ifa[31:29] == 3'b110;
wire        i_sd   = i_wram || i_rom;
wire [25:0] i_caddr = cached(ifa, board, vbuf);
wire [2:0]  la_rg   = sd_region(la_addr, board);
wire        la_wram = la_rg == RG_WRAM0 || la_rg == RG_WRAM4 || la_rg == RG_VOFF;
wire        la_rom  = la_rg == RG_ROM;
wire        la_data = la_rg == RG_DATA;
wire [25:0] la_ca   = cached(la_addr, board, vbuf);

function [26:0] sdram_of(input [25:0] ca);
	sdram_of = !ca[25]                  ? DATA_BASE  + {2'd0, ca[24:0]}
	         : ca[25:21] == 5'b10000    ? WRAM_BASE  + {6'd0, ca[20:0]}
	         : ca[25:21] == 5'b10001    ? WRAM4_BASE + {6'd0, ca[20:0]}
	         : ca[25:19] == 7'b1001000  ? VOFF_BASE  + {8'd0, ca[18:0]}
	         :                            ROM_BASE   + {8'd0, ca[18:0]};
endfunction

""")
rep("localparam [1:0] SRC_REG = 0, SRC_IRAM = 1, SRC_SPR = 2, SRC_PAL = 3;",
    "localparam [1:0] SRC_REG = 0, SRC_IRAM = 1, SRC_VID = 2;")
rep("wire        ic_by_d = (idle_go && bus_wr && !bus_io && (r_wram || r_sprh)) || st == S_WLOOK;",
    "wire        ic_by_d = (idle_go && bus_wr && r_wram) || st == S_WLOOK;")
rep("vh_cache #(.AW(24), .LW(10)) u_ic", "vh_cache #(.AW(26), .LW(10)) u_ic")
rep("vh_cache #(.AW(24), .LW(8)) u_dc", "vh_cache #(.AW(26), .LW(8)) u_dc")
rep("""// 8 bytes wide for the instruction port; the data side has it in its request clock. 4 KB mirrored, 8 KB on aoh.
wire [63:0] iram_q;
wire        ir_by_d = idle_go && !bus_io && r_iram;
wire [12:3] ir_da = {aoh && bus_addr[12], bus_addr[11:3]}, ir_ia = {aoh && if_addr[12], if_addr[11:3]};""",
"""// 8 bytes wide for the instruction port; the data side has it in its request clock. 4 KB mirrored.
wire [63:0] iram_q;
wire        ir_by_d = idle_go && r_iram;
wire [12:3] ir_da = {1'b0, bus_addr[11:3]}, ir_ia = {1'b0, if_addr[11:3]};""")
rep("""// ---------------------------------------------------------------- video RAMs, I/O
assign spr_we   = idle_go && bus_wr && !bus_io && r_spr;
assign xflip_we = idle_go && bus_wr && !bus_io && bus_addr[31:16] == 16'he000;
assign spr_be   = bus_be;
assign spr_addr = bus_addr[15:2];
assign spr_wd   = bus_wdata;
assign pal_we   = idle_go && bus_wr && !bus_io && r_pal;
assign pal_be   = bus_be;
assign pal_addr = bus_addr[15:2];
assign pal_wd   = bus_wdata;
assign io_rd    = idle_go && bus_io && !bus_wr;
assign io_wr    = idle_go && bus_io && bus_wr;
assign io_port  = bus_addr[31:13];
assign io_wd    = bus_wdata;""",
"""// ---------------------------------------------------------------- video RAMs, I/O
assign vid_vram_cs = idle_go && r_vram;
assign vid_pal_cs  = idle_go && r_pal;
assign vid_we      = bus_wr;
assign vid_be      = bus_be;
assign vid_addr    = bus_addr[17:2];
assign vid_wd      = bus_wdata;
assign io_rd    = idle_go && r_io && !bus_wr;
assign io_wr    = idle_go && r_io && bus_wr;
assign io_addr  = bus_addr[23:0];
assign io_be    = bus_be;
assign io_wd    = bus_wdata;""")
rep("                   rsrc == SRC_SPR ? spr_rd : rsrc == SRC_PAL ? pal_rd : rdata_r;",
    "                   rsrc == SRC_VID ? vid_rd : rdata_r;")
rep("""wire        w_fast  = idle_go && bus_wr && (bus_io || r_iram || r_spr || r_pal);
wire        w_store = idle_go && bus_wr && !bus_io && (r_wram || r_sprh) && (wb_merge || !wb_full);""",
"""wire        w_fast  = idle_go && bus_wr && (r_io || r_iram || r_vid);
wire        w_store = idle_go && bus_wr && r_wram && (wb_merge || !wb_full);""")
rep("""			if (bus_io && io_late && !bus_wr) begin
				st <= S_IOW;
			end else if (bus_io) begin
				if (!bus_wr) begin                // a write was acked in this clock (w_fast)
					rdata_r <= io_rdata;
					ack_r <= 1'b1; st <= S_ACK;
				end
			end else if (r_inp) begin
				rdata_r <= bus_addr[17] ? aoh_p12 : aoh_sys;
				ack_r <= 1'b1; st <= S_ACK;
			end else if (r_iram || r_spr || r_pal) begin
				if (!bus_wr) begin                // a write was acked in this clock (w_fast)
					rsrc <= r_iram ? SRC_IRAM : r_spr ? SRC_SPR : SRC_PAL;
					ack_r <= 1'b1; st <= S_ACK;
				end""",
"""			if (r_io && io_late && !bus_wr) begin
				st <= S_IOW;
			end else if (r_io) begin
				if (!bus_wr) begin                // a write was acked in this clock (w_fast)
					rdata_r <= io_rdata;
					ack_r <= 1'b1; st <= S_ACK;
				end
			end else if (r_iram || r_vid) begin
				if (!bus_wr) begin                // a write was acked in this clock (w_fast)
					rsrc <= r_iram ? SRC_IRAM : SRC_VID;
					ack_r <= 1'b1; st <= S_ACK;
				end""")
rep("			end else if ((r_wram || r_sprh) && bus_wr) begin", "			end else if (r_wram && bus_wr) begin")
rep("wire [7:0]  st_be8 = bus_addr[2] ? {4'b0, bus_be} : {bus_be, 4'b0};",
    """wire [7:0]  st_be8 = bus_addr[2] ? {4'b0, be_w} : {be_w, 4'b0};   // be_w: the decode's
// the store as accepted, for its cache update in S_WLOOK (bus_* may be the next access by then)
reg  [25:0] wl_ca;
reg  [7:0]  wl_be;
reg  [31:0] wl_d;
always @(posedge clk) if (idle_go && bus_wr) begin
	wl_ca <= caddr;
	wl_be <= st_be8;
	wl_d  <= bus_wdata;
end""")
rep("""	.la(ic_by_d ? caddr : i_caddr), .hit(ic_hit), .q(ic_q),""",
    """	.la(st == S_WLOOK ? wl_ca : ic_by_d ? caddr : i_caddr), .hit(ic_hit), .q(ic_q),""")
rep("""	.la(la_take ? la_ca : caddr), .hit(dc_hit), .q(dc_q),""",
    """	.la(st == S_WLOOK ? wl_ca : la_take ? la_ca : caddr), .hit(dc_hit), .q(dc_q),""")
rep("""	.st_we(st == S_WLOOK && ic_hit), .st_be(st_be8), .st_d({bus_wdata, bus_wdata}));""",
    """	.st_we(st == S_WLOOK && ic_hit), .st_be(wl_be), .st_d({wl_d, wl_d}));""")
rep("""	.st_we(st == S_WLOOK && dc_hit), .st_be(st_be8), .st_d({bus_wdata, bus_wdata}));""",
    """	.st_we(st == S_WLOOK && dc_hit), .st_be(wl_be), .st_d({wl_d, wl_d}));""")
rep("wire        la_take = st == S_IDLE && !bus_req && la_req && (la_wram || la_rom || la_sprh);",
    "wire        la_take = st == S_IDLE && !bus_req && la_req && (la_wram || la_rom || la_data);")
# the cached space is 26 bits here (32 MB maindata), 24 in Vamphalf: its widths and slices
s = re.sub(r"(reg|wire)(\s+)\[23:([034])\]", r"\1\2[25:\3]", s)
s = re.sub(r"(caddr|fa|i_ca_r|la_ca|lk_ca|wq_ca\[[^\]]+\]|pf_\w+_line|pf_line)\[23:([34])\]", r"\1[25:\2]", s)
rep("+ 20'd1;", "+ 22'd1;")
for tok in ["aoh", "prg2", "spr_", "pal_rd", "r_sprh", "r_inp", "xflip", "[23:"]:
    if tok in s:
        print("left:", tok, [ln for ln in s.splitlines() if tok in ln][:3])
(REPO / "rtl" / "eo_cpumem.sv").write_text(s, encoding="utf-8")
print(f"rtl/eo_cpumem.sv from vh_cpumem.sv at {COMMIT}: {len(s.splitlines())} lines")
