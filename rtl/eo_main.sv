// The main board: E1 CPU, its memory system (eo_cpumem), the frame buffer and palette (eo_video), and
// the memory-mapped I/O at 0xfc000000. `board` 0, Vega (vegaeo.cpp vega_map 116-129):
//
//   0xfc000000-0xfc0000ff  AT28C16, data in bits 7:0 (umask32 0x000000ff): offsets 0-63 only
//   0xfc400000-0xfc40005b  CRT registers: writes ignored, reads 0 (nopw)
//   0xfc600000             sound latch write, bits 7:0
//   0xfca00000             vega_misc_w: the CPU's buffer = data & 1
//   0xfcc00000             SYSTEM read: COIN1 (either coin input), -, START1, START2, SERVICE1, SERVICE,
//                          vblank (bit 6, low in vblank), -; the rest of the dword reads 1 (IP_ACTIVE_LOW)
//   0xfce00000             P1_P2 read, bits 15:0 (no button 3); bits 31:16 read 1
//   anything else in 0xfc reads 0; the palette (0xfc200000) is eo_cpumem's
//
// `board` 1, Gradation 2D (eolith.cpp eolith_map 371-383, inputs 405-456):
//
//   0xfc000000             IN0 read: START1, START2, -, EEPROM DO, COIN1, COIN2, vblank (bit 6, low in
//                          vblank), -, random bits 9:8, -, SERVICE1, SERVICE; P1 bits 23:16 and P2 bits
//                          31:24 (U D L R, buttons 1-3); IP_ACTIVE_LOW bits read 1
//   0xfc400000             system control write: the CPU's buffer = bit 7; EEPROM CS bit 1, CLK bit 2,
//                          DI bit 3; coin counter and LED (bit 0) not kept
//   0xfc800000             sound latch write, bits 7:0
//   0xfca00000             DSW1 read, bits 7:0; bits 31:8 read 1
//   anything else in 0xfc reads 0, writes are dropped (0xfcc00000, the CRT registers)
//
// `board` 2, eolith16 (eolith16.cpp eolith16_map 79-92, inputs 94-122), a 16-bit bus: a halfword at a dword's
// address is bits 31:16 of it
//
//   0xffe40001             the OKI M6295, bits 23:16 (eo_oki)
//   0xffe80000             eeprom_w, bits 31:16: the CPU's buffer = !bit 7; EEPROM CS bit 4, CLK bit 5, DI
//                          bit 6; coin counter (bit 0) not kept
//   0xffea0000             SPECIAL read, bits 31:16: EEPROM DO bit 4, vblank bit 7 (low in vblank); SYSTEM,
//                          bits 15:0: COIN1, -, START1, -, -, SERVICE1, SERVICE; IP_ACTIVE_LOW bits read 1
//   0xffec0000             bits 31:16 read 0 (nopr); INPUTS, bits 15:0: U D L R, button 1
//   anything else in 0xffe reads 0, writes are dropped
//
// hidctch3 (hidctch3_map 387-394, inputs 579-596): each pen at 0xfce00000 / 0xfcf00000 (mirror 0x80000) reads
// x + y * 336 (hidctch3_pen_r 294-302), x 0-159, y 0-119; IN0 bits 23:16 are all P1's pen button, 31:24 P2's.
// The core shows a cross at each pen (eo_video).
//
// COIN2 is read on every Gradation 2D set; MAME declares it on hidnctch, hidctch2 and candy and leaves
// the bit IPT_UNUSED (reads 1 when not pressed, as here) on the others.
//
// The AT28C16 as MAME's at28c16.cpp: a write of a byte that differs from the stored one stores it and
// starts a 200 us write cycle; during it writes are ignored and reads return the written byte with
// bit 7 inverted. The CPU reaches 64 bytes, kept in registers; the .nvm image is the part's 2 KB, the
// other bytes 0xff. Contents survive the core reset (an EEPROM).
//
// No interrupts: no Eolith game takes one (docs/HARDWARE_NOTES.md, Interrupts).

module eo_main (
	input             clk,
	input             prst,            // power-up reset of the memory side (not the core reset)
	input             rst,
	input      [1:0]  board,           // 0 Vega, 1 Gradation 2D, 2 eolith16 (the .mra's mod byte)
	input             pause,
	input             cpu_tick,        // the CPU's clock as an enable: drives its timer
	input      [5:0]  ws_mem3, ws_mem, // memory wait states, clocks per access (rtl/eo_busws.sv)
	input             ce_pix,

	input      [15:0] p1p2,            // active low, a byte per player: U D L R, buttons 1-3, 1
	input      [5:0]  system,          // active low: COIN1, COIN2, START1, START2, SERVICE1, SERVICE
	input      [7:0]  dsw,             // DSW1 (Gradation 2D), as MAME's port
	input             flip,            // the picture turned 180 degrees (eo_video)
	input             pens,            // hidctch3: light pens (the .mra's mod byte bit 2)
	input      [7:0]  pen1_x, pen2_x,  // 0-159
	input      [6:0]  pen1_y, pen2_y,  // 0-119
	input      [1:0]  xh_en,           // the crosses drawn at the pens: P2, P1

	output     [7:0]  r, g, b,
	output            hblank, vblank, hsync, vsync,

	output reg [7:0]  snd_latch,
	output reg        snd_latch_wr,
	output            oki_wr,          // eolith16: the M6295, one-clock strobe
	output     [7:0]  oki_din,
	input      [7:0]  oki_dout,

	// the .nvm (AT28C16 on Vega, 93C66 on the others): load (core in reset), read back for the save
	input             ee_load_we,
	input      [10:0] ee_load_addr,
	input      [7:0]  ee_load_data,
	input      [10:0] ee_rd_addr,
	output     [7:0]  ee_rd_data,
	output reg        ee_written,

	// ROM download writes, and SDRAM port 2
	input             dl_req,
	input      [26:0] dl_addr,
	input      [15:0] dl_data,
	input             dl_we16,
	input             dl_g,
	input      [63:0] dl_gdata,
	output            dl_busy,
	output     [26:1] mem_addr,
	output            mem_wrl,
	output            mem_wrh,
	output     [15:0] mem_din,
	output     [47:0] mem_dinx,
	output      [5:0] mem_wrx,
	output            mem_dbl,
	output            mem_req,
	input             mem_ack,
	input      [63:0] mem_dout,
	input      [63:0] mem_doutb,

	// for the benches and probes
	output            retire,
	output     [31:0] retire_pc,
	output     [31:0] retire_npc,
	output     [31:0] retire_sr,
	output     [31:0] st_imiss,
	output     [31:0] st_dmiss,
	output            vbuf_out,
	output            vblank_flag,
	output            vbl_rd,          // a read of the port with the vblank bit (rtl/debug/eo_perf.sv)
	output     [1:0]  dbg_pen_rd,      // the CPU reads pen 2 / pen 1's port (probes, Eolith_stp)
	output            dbg_trig_rd      // it reads IN0 with P1's pen button down
);

`include "eo_sdram_map.svh"

// ---------------------------------------------------------------- CPU
wire        bus_req, bus_wr, bus_io, bus_ack;
wire        if_req, if_ack;
wire [31:3] if_addr;
wire [63:0] if_data;
wire [31:0] bus_addr, bus_wdata, bus_rdata;
wire [3:0]  bus_be;
wire        la_req;                // the load being issued, a clock before bus_req
wire [31:0] la_addr;

// Vamphalf's pipelined E1 (rtl/e1/e1_pipe.sv: fetch and operand read ahead of execute)
e1_pipe u_cpu (
	.la_req(la_req), .la_addr(la_addr),
	.clk(clk), .reset(rst), .cen(1'b1),
	.bus_req(bus_req), .bus_wr(bus_wr), .bus_io(bus_io), .bus_addr(bus_addr),
	.bus_be(bus_be), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.irq_in(7'd0), .irq_ack(), .pause(pause), .tick(cpu_tick), .tick2(1'b0),
	.retire(retire), .retire_pc(retire_pc), .retire_npc(retire_npc), .retire_sr(retire_sr),
	.dbg_rf_we(), .dbg_rf_wa(), .dbg_rf_wd()
);

// ---------------------------------------------------------------- memory
// the board's memory timing (rtl/eo_busws.sv): the memory unit sees the request late
wire        mem_bus_req;
eo_busws u_ws (
	.clk(clk), .rst(rst), .req(bus_req), .ack(bus_ack), .io(bus_io), .addr(bus_addr[31:29]),
	.ws_mem3(ws_mem3), .ws_mem(ws_mem), .req_o(mem_bus_req)
);

wire        vid_vram_cs, vid_pal_cs, vid_we;
wire [3:0]  vid_be;
wire [17:2] vid_addr;
wire [31:0] vid_wd, vid_rd;
wire        io_rd, io_wr;
wire [23:0] io_addr;
wire [3:0]  io_be;
wire [31:0] io_wd;
reg  [31:0] io_rdata;

eo_cpumem #(.DATA_BASE(SD_DATA), .ROM_BASE(SD_PRG), .WRAM_BASE(SD_WRAM), .WRAM4_BASE(SD_WRAM4),
            .VOFF_BASE(SD_VOFF)) u_mem (
	.clk(clk), .prst(prst), .rst(rst), .board(board), .vbuf(vbuf),
	.bus_req(mem_bus_req), .bus_wr(bus_wr), .bus_io(bus_io), .bus_addr(bus_addr),
	.bus_be(bus_be), .bus_wdata(bus_wdata), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.la_req(la_req), .la_addr(la_addr),
	.if_req(if_req), .if_addr(if_addr), .if_ack(if_ack), .if_data(if_data),
	.vid_vram_cs(vid_vram_cs), .vid_pal_cs(vid_pal_cs), .vid_we(vid_we), .vid_be(vid_be),
	.vid_addr(vid_addr), .vid_wd(vid_wd), .vid_rd(vid_rd),
	.io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_be(io_be), .io_wd(io_wd),
	.io_rdata(io_rdata), .io_late(1'b0),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_g(dl_g),
	.dl_gdata(dl_gdata), .dl_busy(dl_busy),
	.mem_addr(mem_addr), .mem_wrl(mem_wrl), .mem_wrh(mem_wrh), .mem_din(mem_din),
	.mem_dinx(mem_dinx), .mem_wrx(mem_wrx), .mem_dbl(mem_dbl),
	.mem_req(mem_req), .mem_ack(mem_ack), .mem_dout(mem_dout), .mem_doutb(mem_doutb),
	.st_imiss(st_imiss), .st_dmiss(st_dmiss), .dbg_fill_a(), .dbg_fill_d(),
	.dbg_miss(), .dbg_miss_ic(), .dbg_miss_line()
);

// ---------------------------------------------------------------- video
reg vbuf = 1'b0;
assign vbuf_out = vbuf;

eo_video u_video (
	.clk(clk), .ce_pix(ce_pix), .board(board), .vbuf(vbuf), .flip(flip),
	.cpu_vram_cs(vid_vram_cs), .cpu_pal_cs(vid_pal_cs), .cpu_we(vid_we), .cpu_be(vid_be),
	.cpu_addr(vid_addr), .cpu_wdata(vid_wd), .cpu_rdata(vid_rd),
	.cross_en({2{grad && pens}} & xh_en),
	.cx1({pen1_x, 1'b0}), .cy1({pen1_y, 1'b0}), .cx2({pen2_x, 1'b0}), .cy2({pen2_y, 1'b0}),
	.vblank_flag(vblank_flag),
	.r(r), .g(g), .b(b), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync)
);

// ---------------------------------------------------------------- I/O
wire vega   = board == 2'd0, grad = board == 2'd1;
wire a_ee   = vega && io_addr[23:8] == 16'h0000;
wire a_snd  = vega && io_addr[23:2] == 22'h180000;    // 0xfc600000
wire a_misc = vega && io_addr[23:2] == 22'h280000;    // 0xfca00000
wire a_sys  = vega && io_addr[23:2] == 22'h300000;    // 0xfcc00000
wire a_p12  = vega && io_addr[23:2] == 22'h380000;    // 0xfce00000
wire g_in0  = grad && io_addr[23:2] == 22'h000000;    // 0xfc000000
wire g_ctl  = grad && io_addr[23:2] == 22'h100000;    // 0xfc400000
wire g_snd  = grad && io_addr[23:2] == 22'h200000;    // 0xfc800000
wire g_dsw  = grad && io_addr[23:2] == 22'h280000;    // 0xfca00000
wire g_pen1 = grad && pens && io_addr[23:20] == 4'he && io_addr[18:2] == 17'd0;   // 0xfce00000, 0xfce80000
wire g_pen2 = grad && pens && io_addr[23:20] == 4'hf && io_addr[18:2] == 17'd0;   // 0xfcf00000, 0xfcf80000
// x + y * 336 as shifts: 336 = 256 + 64 + 16
function [31:0] pen_pos(input [7:0] x, input [6:0] y);
	pen_pos = {24'd0, x} + {17'd0, y, 8'd0} + {19'd0, y, 6'd0} + {21'd0, y, 4'd0};
endfunction
wire e16    = board == 2'd2;
wire k_oki  = e16 && io_addr[23:2] == 22'h390000;     // 0xffe40000
wire k_ctl  = e16 && io_addr[23:2] == 22'h3a0000;     // 0xffe80000
wire k_spc  = e16 && io_addr[23:2] == 22'h3a8000;     // 0xffea0000
wire k_inp  = e16 && io_addr[23:2] == 22'h3b0000;     // 0xffec0000
assign oki_wr  = io_wr && k_oki && io_be[2];
assign vbl_rd  = io_rd && (a_sys || g_in0 || k_spc);
assign dbg_pen_rd  = {io_rd && g_pen2, io_rd && g_pen1};
assign dbg_trig_rd = io_rd && g_in0 && pens && !p1p2[4];
assign oki_din = io_wd[23:16];

// MAME's machine().rand() & 0x300: a free-running LFSR
reg  [15:0] rnd = 16'hace1;
always @(posedge clk) rnd <= {rnd[14:0], rnd[15] ^ rnd[13] ^ rnd[12] ^ rnd[10]};

// 93C66 (Gradation 2D)
reg         e9_cs = 1'b0, e9_sk = 1'b0, e9_di = 1'b0;
wire        e9_do;
wire [7:0]  e9_rd;
wire        e9_written;
eo_eeprom93cxx #(.AW(9), .DW(8)) u_e9 (
	.clk(clk), .rst(rst), .cs(e9_cs), .sk(e9_sk), .di(e9_di), .dout(e9_do),
	.load_we(ee_load_we && !vega && ee_load_addr[10:9] == 2'd0), .load_addr(ee_load_addr[8:0]),
	.load_data(ee_load_data), .rd_addr(ee_rd_addr[8:0]), .rd_data(e9_rd), .written(e9_written)
);

// AT28C16: 200 us at 630/11 MHz is 11,454.5 clocks
localparam [13:0] EE_BUSY = 14'd11455;
reg  [7:0]  ee [0:63];
reg  [13:0] ee_cnt = 14'd0;
reg  [7:0]  ee_last;
wire        ee_busy = ee_cnt != 14'd0;
wire [5:0]  ee_off = io_addr[7:2];
integer i;
initial for (i = 0; i < 64; i = i + 1) ee[i] = 8'hff;

always @(posedge clk) begin
	snd_latch_wr <= 1'b0;
	ee_written   <= e9_written;
	if (ee_busy) ee_cnt <= ee_cnt - 14'd1;
	if (ee_load_we && vega && ee_load_addr[10:6] == 5'd0) ee[ee_load_addr[5:0]] <= ee_load_data;
	if (rst) begin
		vbuf  <= 1'b0;
		e9_cs <= 1'b0;
		e9_sk <= 1'b0;
		e9_di <= 1'b0;
	end else if (io_wr) begin
		if (a_ee && io_be[0] && !ee_busy && ee[ee_off] != io_wd[7:0]) begin
			ee[ee_off] <= io_wd[7:0];
			ee_last    <= io_wd[7:0];
			ee_cnt     <= EE_BUSY;
			ee_written <= 1'b1;
		end
		if ((a_snd || g_snd) && io_be[0]) begin
			snd_latch    <= io_wd[7:0];
			snd_latch_wr <= 1'b1;
		end
		if (a_misc) vbuf <= io_be[0] & io_wd[0];
		// systemcontrol_w takes the whole dword whatever the lanes
		if (g_ctl) begin
			vbuf  <= io_wd[7];
			e9_cs <= io_wd[1];
			e9_sk <= io_wd[2];
			e9_di <= io_wd[3];
		end
		if (k_ctl && io_be[3:2] != 2'b00) begin
			vbuf  <= !io_wd[23];
			e9_cs <= io_wd[20];
			e9_sk <= io_wd[21];
			e9_di <= io_wd[22];
		end
	end
end
assign ee_rd_data = !vega ? e9_rd : ee_rd_addr[10:6] == 5'd0 ? ee[ee_rd_addr[5:0]] : 8'hff;

always @(*) begin
	io_rdata = 32'd0;
	if (a_ee)   io_rdata = {24'd0, ee_busy ? ee_last ^ 8'h80 : ee[ee_off]};
	if (a_sys)  io_rdata = {24'hffffff, 1'b1, ~vblank_flag, system[5:2], 1'b1, system[1] & system[0]};
	if (a_p12)  io_rdata = {16'hffff, p1p2 | 16'h4040};
	if (g_in0)  io_rdata = {pens ? {{8{p1p2[12]}}, {8{p1p2[4]}}} : p1p2, system[5:4], 4'hf, rnd[1:0], 1'b1,
	                        ~vblank_flag, system[1:0], e9_do, 1'b1, system[3:2]};
	if (g_pen1) io_rdata = pen_pos(pen1_x, pen1_y);
	if (g_pen2) io_rdata = pen_pos(pen2_x, pen2_y);
	if (g_dsw)  io_rdata = {24'hffffff, dsw};
	if (k_oki)  io_rdata = {8'h00, oki_dout, 16'h0000};
	if (k_spc)  io_rdata = {8'hff, ~vblank_flag, 2'b11, e9_do, 4'hf,
	                        9'h1ff, system[5:4], 2'b11, system[2], 1'b1, system[1] & system[0]};
	if (k_inp)  io_rdata = {16'h0000, 11'h7ff, p1p2[4:0]};
end

endmodule
