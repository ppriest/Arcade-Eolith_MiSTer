// The E1's memory system: address decode, the CPU's internal RAM, the caches in front of work RAM and
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

module eo_cpumem #(
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

	// CPU
	input             bus_req,
	input             bus_wr,
	input             bus_io,
	input      [31:0] bus_addr,
	input      [3:0]  bus_be,
	input      [31:0] bus_wdata,
	output            bus_ack,
	output     [31:0] bus_rdata,
	input             la_req,          // the read the CPU is issuing in this clock, at la_addr (e1_pipe)
	input      [31:0] la_addr,

	// CPU instruction port: 8 bytes, byte 0 in [63:56]
	input             if_req,
	input      [31:3] if_addr,
	output            if_ack,
	output     [63:0] if_data,

	// VRAM window and palette (eo_video): one-clock strobes, read data one clock after the address
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

	// ROM download writes (sdram_download), or with dl_g a whole 8-byte granule at dl_addr (the fast load's
	// copy, vh_rom_loader), byte i of dl_gdata at dl_addr + i
	input             dl_req,
	input      [26:0] dl_addr,
	input      [15:0] dl_data,
	input             dl_we16,
	input             dl_g,
	input      [63:0] dl_gdata,
	output reg        dl_busy = 1'b0,

	// sdram.sv port 2
	output reg [26:1] mem_addr,
	output reg        mem_wrl,
	output reg        mem_wrh,
	output reg [15:0] mem_din,
	output reg [47:0] mem_dinx,        // words 1-3 of a burst write, and their byte enables
	output reg  [5:0] mem_wrx,
	output reg        mem_dbl,
	output reg        mem_req = 1'b0,
	input             mem_ack,
	input      [63:0] mem_dout,
	input      [63:0] mem_doutb,

	output reg [31:0] st_imiss = 0,    // counters for the benches
	output reg [31:0] st_dmiss = 0,
	output reg [26:1] dbg_fill_a,      // the first line fill after reset: its SDRAM address
	output reg [63:0] dbg_fill_d,      // and its second granule
	output            dbg_miss,        // one clock per cache miss: dbg_miss_ic, the line in the cached space
	output            dbg_miss_ic,
	output     [25:4] dbg_miss_line
);

// ---------------------------------------------------------------- decode
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

// SDRAM granule (4 little-endian-lane words, lowest address in [15:0]) -> 8 bytes, byte 0 in [63:56]
function [63:0] sw64(input [63:0] g);
	sw64 = {g[7:0], g[15:8], g[23:16], g[31:24], g[39:32], g[47:40], g[55:48], g[63:56]};
endfunction

// ---------------------------------------------------------------- state
localparam [3:0] S_INIT = 0, S_IDLE = 1, S_LOOK = 2, S_WLOOK = 3, S_MISS = 4, S_FILL = 5,
                 S_FILL2 = 6, S_ACK = 7, S_IOW = 8, S_PFW = 9;
localparam [1:0] SRC_REG = 0, SRC_IRAM = 1, SRC_VID = 2;

reg  [3:0]  st;
reg  [10:0] swc;
reg         ack_r;
reg  [1:0]  rsrc;
reg  [31:0] rdata_r;
reg  [25:0] fa;
reg         f_ic;               // the fill is for the I-cache
reg  [63:0] lg0, lg1;           // the line, swapped
reg         line_req, line_done;
reg         dbg_filled = 1'b0;

// D-side next-line prefetch
reg         pf_want, pf_valid, pf_kill, pf_use;
reg  [25:4] pf_want_line, pf_fl_line, pf_line;
reg  [63:0] pf0, pf1;

// write buffer: four 8-byte blocks (byte 0 in [63:56], be[7] its enable), drained in order
(* ramstyle = "logic" *) reg  [25:3] wq_ca [0:3];   // registers: read combinationally; as RAM, reading an entry written in the same clock would depend on bypass logic Quartus may not add
(* ramstyle = "logic" *) reg  [7:0]  wq_be [0:3];
(* ramstyle = "logic" *) reg  [63:0] wq_d  [0:3];
reg  [2:0]  wq_w = 3'd0, wq_r = 3'd0;
wire        wb_valid = wq_w != wq_r;
wire        wb_full  = (wq_w - wq_r) == 3'd4;
wire [25:3] wb_ca = wq_ca[wq_r[1:0]];
wire [7:0]  wb_be = wq_be[wq_r[1:0]];
wire [63:0] wb_d  = wq_d[wq_r[1:0]];
wire [1:0]  wq_t  = wq_w[1:0] - 2'd1;       // the newest entry

wire idle_go = st == S_IDLE && bus_req;
// the CPU's announced read, looked up in this clock (lk_*: in the last)
wire        la_take = st == S_IDLE && !bus_req && la_req && (la_wram || la_rom || la_data);
reg         lk_v = 1'b0;
reg  [25:0] lk_ca;

// ---------------------------------------------------------------- caches
wire        ic_hit, dc_hit;
wire [63:0] ic_q, dc_q;
wire        sweep = st == S_INIT;
wire [7:0]  st_be8 = bus_addr[2] ? {4'b0, be_w} : {be_w, 4'b0};   // be_w: the decode's
// the store as accepted, for its cache update in S_WLOOK (bus_* may be the next access by then)
reg  [25:0] wl_ca;
reg  [7:0]  wl_be;
reg  [31:0] wl_d;
always @(posedge clk) if (idle_go && bus_wr) begin
	wl_ca <= caddr;
	wl_be <= st_be8;
	wl_d  <= bus_wdata;
end
wire        fill_we = st == S_FILL && (line_done || pf_use) || st == S_FILL2;
wire        fill_half = st == S_FILL2;
wire [63:0] fill_d = st == S_FILL2 ? lg1 : lg0;

// the data side has the I-cache's port for a store: the lookup in the request clock, the update in WLOOK
wire        ic_by_d = (idle_go && bus_wr && r_wram) || st == S_WLOOK;
vh_cache #(.AW(26), .LW(10)) u_ic (.clk(clk), .sweep(sweep), .sw_idx(swc[9:0]),
	.la(st == S_WLOOK ? wl_ca : ic_by_d ? caddr : i_caddr), .hit(ic_hit), .q(ic_q),
	.fill_we(fill_we && f_ic), .fill_tag(fill_half), .fa(fa), .fill_half(fill_half), .fill_d(fill_d),
	.st_we(st == S_WLOOK && ic_hit), .st_be(wl_be), .st_d({wl_d, wl_d}));
vh_cache #(.AW(26), .LW(8)) u_dc (.clk(clk), .sweep(sweep), .sw_idx(swc[7:0]),
	.la(st == S_WLOOK ? wl_ca : la_take ? la_ca : caddr), .hit(dc_hit), .q(dc_q),
	.fill_we(fill_we && !f_ic), .fill_tag(fill_half), .fa(fa), .fill_half(fill_half), .fill_d(fill_d),
	.st_we(st == S_WLOOK && dc_hit), .st_be(wl_be), .st_d({wl_d, wl_d}));

// ---------------------------------------------------------------- internal RAM
// 8 bytes wide for the instruction port; the data side has it in its request clock. 4 KB mirrored.
wire [63:0] iram_q;
wire        ir_by_d = idle_go && r_iram;
wire [12:3] ir_da = {1'b0, bus_addr[11:3]}, ir_ia = {1'b0, if_addr[11:3]};
vh_cache_ram #(.AW(10), .DW(64), .NB(8)) u_iram (.clk(clk), .addr(ir_by_d ? ir_da : ir_ia),
	.we(ir_by_d && bus_wr), .be(st_be8), .wd({bus_wdata, bus_wdata}), .q(iram_q));

// ---------------------------------------------------------------- instruction port
wire        i_free = i_sd ? !(sweep || (fill_we && f_ic) || ic_by_d) : i_iram ? !ir_by_d : 1'b1;
reg         i_look = 1'b0;      // if_addr was looked up in the previous clock, as i_la
reg  [31:3] i_la;
reg         i_sd_r, i_iram_r;
reg  [25:0] i_ca_r;
always @(posedge clk) begin
	i_look <= if_req && i_free;
	i_la <= if_addr; i_sd_r <= i_sd; i_iram_r <= i_iram; i_ca_r <= i_caddr;
end
wire        i_cur  = i_look && if_req && i_la == if_addr;
wire        i_miss = i_cur && i_sd_r && !ic_hit;
wire        i_take = st == S_IDLE && !bus_req && i_miss;    // the miss logic fills it
assign if_ack  = i_cur && (!i_sd_r || ic_hit);
assign if_data = i_iram_r ? iram_q : i_sd_r ? ic_q : 64'd0;

// ---------------------------------------------------------------- video RAMs, I/O
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
assign io_wd    = bus_wdata;

wire        look_hit = st == S_LOOK && dc_hit;
wire        lk_read = idle_go && !bus_wr && !bus_io && r_sd && lk_v && lk_ca == caddr;
wire        lk_hit = lk_read && dc_hit;
assign dbg_miss      = (st == S_LOOK && !look_hit) || (lk_read && !dc_hit) || i_take;
assign dbg_miss_ic   = i_take;
assign dbg_miss_line = i_take ? i_ca_r[25:4] : caddr[25:4];
wire        w_fast  = idle_go && bus_wr && (r_io || r_iram || r_vid);
wire        w_store = idle_go && bus_wr && r_wram && (wb_merge || !wb_full);
assign bus_ack   = ack_r || look_hit || lk_hit || w_fast || w_store || (st == S_FILL2 && !f_ic);
assign bus_rdata = (st == S_LOOK || lk_hit) ? (bus_addr[2] ? dc_q[31:0] : dc_q[63:32]) :
                   rsrc == SRC_IRAM ? (bus_addr[2] ? iram_q[31:0] : iram_q[63:32]) :
                   rsrc == SRC_VID ? vid_rd : rdata_r;

// ---------------------------------------------------------------- CPU side and port 2
reg  [2:0]  m_who;              // what port 2 is doing
localparam [2:0] W_NONE = 0, W_DL = 1, W_WB = 2, W_LINE = 4, W_PF = 5;
wire        m_free = m_who == W_NONE;
wire [26:0] wb_sa = sdram_of({wb_ca, 3'd0});
// a store merges into the newest entry if that holds its block and is not being written, or about to be
// (port 2 takes the head in any clock it is free and no download write waits)
wire        wb_head_out = m_who == W_WB || (m_free && !dl_req && !line_req);
wire        wb_merge = wb_valid && wq_ca[wq_t] == caddr[25:3] && !(wq_t == wq_r[1:0] && wb_head_out);
wire [26:0] fa_sa = sdram_of(fa);
// a store to the line being filled is in the write buffer: the fill waits for it
reg         wb_conf;
integer     ci;
always @(*) begin
	wb_conf = 1'b0;
	for (ci = 0; ci < 4; ci = ci + 1)
		if (((ci[2:0] - wq_r) & 3'd3) < wq_w - wq_r && wq_ca[ci][25:4] == fa[25:4]) wb_conf = 1'b1;
end
wire [26:0] pf_sa = sdram_of({pf_want_line, 4'd0});
wire        pf_match = pf_valid && pf_line == caddr[25:4];

// a D-cache miss on caddr: from the prefetch buffer, or waiting for the prefetch of the line, or a fill
task d_miss;
	begin
		fa <= caddr;
		f_ic <= 1'b0;
		st_dmiss <= st_dmiss + 1'd1;
		if (pf_match) begin
			lg0 <= pf0; lg1 <= pf1;
			pf_use <= 1'b1;
			pf_valid <= 1'b0;
			st <= S_FILL;
		end else if (m_who == W_PF && pf_fl_line == caddr[25:4] && !pf_kill) begin
			st <= S_PFW;              // the prefetch of this line is on its way
		end else begin
			if (pf_want && pf_want_line == caddr[25:4]) pf_want <= 1'b0;   // the fill reads it
			st <= S_MISS;
		end
	end
endtask

integer bi;
always @(posedge clk) begin
	line_done <= 1'b0;

	// port 2: one access at a time
	if (prst) begin
		m_who <= W_NONE;
		line_req <= 1'b0;
		dl_busy <= 1'b0;
		wq_w <= 3'd0; wq_r <= 3'd0;
		mem_req <= mem_ack;            // nothing outstanding
	end else if (m_free) begin
		if (dl_req) begin
			mem_addr <= dl_g ? {dl_addr[26:3], 2'd0} : dl_addr[26:1];
			mem_wrl  <= dl_g || dl_we16 || !dl_addr[0];
			mem_wrh  <= dl_g || dl_we16 ||  dl_addr[0];
			mem_din  <= dl_g ? dl_gdata[15:0] : dl_we16 ? dl_data : {dl_data[7:0], dl_data[7:0]};
			mem_dinx <= dl_gdata[63:16];
			mem_wrx  <= dl_g ? 6'h3f : 6'd0;
			mem_dbl  <= 1'b0;
			mem_req  <= ~mem_req;
			dl_busy  <= 1'b1;
			m_who    <= W_DL;
		end else if (line_req) begin
			mem_addr <= {fa_sa[26:4], 3'd0};
			mem_wrl  <= 1'b0;
			mem_wrh  <= 1'b0;
			mem_wrx  <= 6'd0;
			mem_dbl  <= 1'b1;
			mem_req  <= ~mem_req;
			line_req <= 1'b0;
			m_who    <= W_LINE;
		end else if (wb_valid) begin
			// SDRAM word k of the block: byte 2k in [7:0], byte 2k+1 in [15:8]
			mem_addr <= {wb_sa[26:3], 2'd0};
			mem_wrl  <= wb_be[7];
			mem_wrh  <= wb_be[6];
			mem_din  <= {wb_d[55:48], wb_d[63:56]};
			mem_dinx <= {wb_d[7:0], wb_d[15:8], wb_d[23:16], wb_d[31:24], wb_d[39:32], wb_d[47:40]};
			mem_wrx  <= {wb_be[0], wb_be[1], wb_be[2], wb_be[3], wb_be[4], wb_be[5]};
			mem_dbl  <= 1'b0;
			mem_req  <= ~mem_req;
			m_who    <= W_WB;
		end else if (pf_want) begin
			mem_addr <= {pf_sa[26:4], 3'd0};
			mem_wrl  <= 1'b0;
			mem_wrh  <= 1'b0;
			mem_wrx  <= 6'd0;
			mem_dbl  <= 1'b1;
			mem_req  <= ~mem_req;
			pf_want  <= 1'b0;
			pf_fl_line <= pf_want_line;
			pf_kill  <= 1'b0;
			m_who    <= W_PF;
		end
	end else if (mem_ack == mem_req) begin
		case (m_who)
			W_DL:   dl_busy <= 1'b0;
			W_WB:   wq_r <= wq_r + 3'd1;
			W_LINE: begin
				lg0 <= sw64(mem_dout); lg1 <= sw64(mem_doutb); line_done <= 1'b1;
				if (!dbg_filled) begin dbg_filled <= 1'b1; dbg_fill_a <= mem_addr; dbg_fill_d <= sw64(mem_doutb); end
			end
			W_PF:   if (!pf_kill) begin
				pf0 <= sw64(mem_dout); pf1 <= sw64(mem_doutb); pf_line <= pf_fl_line; pf_valid <= 1'b1;
			end
			default: ;
		endcase
		m_who <= W_NONE;
	end

	// CPU side
	ack_r <= 1'b0;
	lk_v <= la_take && !rst;
	lk_ca <= la_ca;
	if (rst) begin
		st  <= S_INIT;
		swc <= 11'd0;
		rsrc <= SRC_REG;
		pf_valid <= 1'b0;
		pf_want <= 1'b0;
		pf_use <= 1'b0;
		pf_kill <= 1'b1;               // a read in flight across the reset is dropped
		dbg_filled <= 1'b0;
	end else case (st)
		S_INIT: begin
			swc <= swc + 11'd1;
			if (swc[10]) st <= S_IDLE;
		end
		S_IDLE: if (bus_req) begin
			rsrc <= SRC_REG;
			if (r_io && io_late && !bus_wr) begin
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
				end
			end else if (r_sd && !bus_wr) begin
				// looked up in the last clock: a hit is acked in this one, a miss starts now
				if (lk_read) begin
					if (!dc_hit) d_miss;
				end else st <= S_LOOK;
			end else if (r_wram && bus_wr) begin
				if (wb_merge || !wb_full) begin
					if (pf_match) pf_valid <= 1'b0;
					if (m_who == W_PF && pf_fl_line == caddr[25:4]) pf_kill <= 1'b1;
					// that prefetch completing in this clock has already taken the line's old data
					if (m_who == W_PF && mem_ack == mem_req && pf_fl_line == caddr[25:4]) pf_valid <= 1'b0;
					if (pf_want && pf_want_line == caddr[25:4]) pf_kill <= 1'b1;   // issued in this clock
					if (wb_merge) begin
						wq_be[wq_t] <= wq_be[wq_t] | st_be8;
						for (bi = 0; bi < 8; bi = bi + 1)
							if (st_be8[bi]) wq_d[wq_t][8*bi +: 8] <= bus_wdata[8*(bi & 3) +: 8];
					end else begin
						wq_ca[wq_w[1:0]] <= caddr[25:3];
						wq_be[wq_w[1:0]] <= st_be8;
						wq_d[wq_w[1:0]]  <= {bus_wdata, bus_wdata};
						wq_w <= wq_w + 3'd1;
					end
					st <= S_WLOOK;
				end
			end else begin
				rdata_r <= 32'd0;
				ack_r <= 1'b1; st <= S_ACK;
			end
		end else if (i_miss) begin            // i_take
			fa <= i_ca_r;
			f_ic <= 1'b1;
			st_imiss <= st_imiss + 1'd1;
			st <= S_MISS;
		end
		S_LOOK: begin
			if (look_hit) st <= S_IDLE;      // acked in this clock
			else d_miss;
		end
		S_PFW: if (m_who != W_PF) begin   // the prefetch has arrived
			if (pf_valid && pf_line == fa[25:4]) begin
				lg0 <= pf0; lg1 <= pf1;
				pf_use <= 1'b1;
				pf_valid <= 1'b0;
				st <= S_FILL;
			end else st <= S_MISS;
		end
		S_WLOOK: begin                    // the caches update on a hit in this clock (acked in S_IDLE)
			st <= S_IDLE;
		end
		S_MISS: if (!wb_conf) begin
			line_req <= 1'b1;
			st <= S_FILL;
		end
		S_FILL: if (line_done || pf_use) begin
			rdata_r <= fa[3] ? (fa[2] ? lg1[31:0] : lg1[63:32]) : (fa[2] ? lg0[31:0] : lg0[63:32]);
			pf_use <= 1'b0;
			if (!f_ic) begin              // the next line, behind anything else on port 2
				pf_want <= 1'b1;
				pf_want_line <= fa[25:4] + 22'd1;
			end
			st <= S_FILL2;
		end
		S_FILL2: begin                    // a data fill is acked in this clock, with rdata_r
			rsrc <= SRC_REG;
			st <= S_IDLE;
		end
		S_ACK: st <= S_IDLE;
		S_IOW: begin
			rdata_r <= io_rdata;
			ack_r <= 1'b1; st <= S_ACK;
		end
		default: st <= S_IDLE;
	endcase
end

endmodule
