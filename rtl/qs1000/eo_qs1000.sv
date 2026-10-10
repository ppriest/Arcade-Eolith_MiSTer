// The QS1000 sound board as vegaeo.cpp wires it (208-217, 69-87, 298-305) and qs1000.cpp has it: an
// 8052 on the 24 MHz oscillator, the main CPU's sound latch, and the wavetable engine reading the sample
// ROM from SDRAM. With `grad`, as eolith.cpp wires it (343-363, 727-732): commands arrive on the 8052's
// RxD from the sound CPU (eo_sndcpu), P1 reads 1, P2 0, P3 only RxD (qs1000_p3_r), and the data space
// is the RAM and the voice registers alone (qs1000_data_map; no bank installed). After Arcade-Vamphalf_MiSTer's rtl/qs1000/vh_qs1000.sv (the same chip on another
// board); the 8052 and the engine are its vendored modules, unchanged.
//
//   8052 program  0x0000-0x7fff  the first 32 KB of bgm.u84, in block RAM (qs1000_prg_map); above, 0xff
//   8052 data     0x0000-0x00ff  RAM
//                 0x0100-0xffff  reads: bgm.u84[bank * 0x10000 + addr], bank = P3 bits 2:0 (the bank
//                                init_vegaeo installs), from SDRAM through a 16-byte line buffer
//                 0x0200-0x0211  writes go to the wavetable engine
//   P1 in         the latch      INT1 is the latch's pending flag: set by the main CPU's write, cleared
//                                by a write to P3 with bit 5 low (qs1000_p3_w)
//
// 24 MHz is 44 enables in 105 clocks of 630/11 MHz, never two in a row (jt8052 requires it). A data
// read of the banked window that misses the line buffer holds the 8052's enables until the line is in;
// the enables it missed are owed and given back, never two in a row, so over time it runs at 24 MHz. The
// engine's 750 kHz tick is every 32nd enable of the undelayed 24 MHz train, so a stall does not move
// it. (MAME's crazywar in play: at most 84 banked reads a frame, over 647 lines in 2,600 frames;
// docs/HARDWARE_NOTES.md.)

module eo_qs1000 #(
	parameter [26:0] SNDPRG_BASE = 27'h2080000,   // bgm.u84 in SDRAM
	parameter [26:0] SMP_BASE    = 27'h2100000,   // the sample region in SDRAM
	parameter [19:0] SMP_LINES   = 20'h28000      // its 16-byte lines held there; above read as zero
) (
	input               clk,
	input               rst,

	input               dl_we,           // the first 32 KB of bgm.u84, while rst is held
	input       [14:0]  dl_addr,
	input       [7:0]   dl_data,

	input               latch_wr,
	input       [7:0]   latch_d,
	input               bal_pcb,         // mix balance: the PCB recording's, or MAME's (vh_qs1000_voice)
	input               grad,            // the Gradation 2D's wiring (static)
	input               rxd,             // with grad: the sound CPU's TxD

	// SDRAM port 0: one 16-byte line of the sample region per request (double read)
	output reg  [26:1]  smp_addr,
	output reg          smp_req,
	input               smp_ack,
	input       [63:0]  smp_dout,
	input       [63:0]  smp_doutb,
	// SDRAM port 1: one 16-byte line of bgm.u84 per request (double read)
	output reg  [26:1]  dat_addr,
	output reg          dat_req,
	input               dat_ack,
	input       [63:0]  dat_dout,
	input       [63:0]  dat_doutb,

	output signed [15:0] out_l,
	output signed [15:0] out_r,

	output      [15:0]  dbg_drops,
	output      [15:0]  dbg_stalls,
	output reg  [15:0]  dbg_xmiss = 16'd0,   // banked reads that waited for SDRAM
	output              wave_wr_o,           // for the benches: the engine's register writes
	output      [4:0]   wave_off_o,
	output      [7:0]   wave_data_o,
	output              tick_o,
	output reg  [7:0]   dbg_debtmax = 8'd0,  // the most enables owed at once
	output reg  [31:0]  dbg_stallclk = 32'd0,// clocks the 8052 waited on a banked read
	output reg  [31:0]  dbg_cens = 32'd0,    // enables given, against the undelayed train's
	output reg  [31:0]  dbg_noms = 32'd0,
	output              pending_o,           // for the benches: the latch's pending flag (INT1, inverted)
	output              p3we_o,              // and the 8052's P3 writes, with the value
	output      [7:0]   p3_o,
	output              xrd_o,               // for the benches: a data read the 8052 takes, its address and byte
	output      [15:0]  xrd_addr_o,
	output      [7:0]   xrd_data_o
);

function [63:0] sw64(input [63:0] g);
	sw64 = {g[7:0], g[15:8], g[23:16], g[31:24], g[39:32], g[47:40], g[55:48], g[63:56]};
endfunction

// ---------------------------------------------------------------- clocks
reg  [6:0]  cacc;
reg         nom;                     // the undelayed 24 MHz train
reg  [4:0]  tdiv;
reg         tick;
reg  [7:0]  debt;
reg         cen;                     // the 8052's enable
wire        stall;
wire        want = nom || debt != 8'd0;
wire        go = want && !stall && !cen;
always @(posedge clk) begin
	tick <= 1'b0;
	if (rst) begin
		cacc <= 7'd0; nom <= 1'b0; tdiv <= 5'd0; debt <= 8'd0; cen <= 1'b0;
	end else begin
		// 8 bits: cacc + 44 reaches 148
		if ({1'b0, cacc} + 8'd44 >= 8'd105) begin cacc <= 7'({1'b0, cacc} + 8'd44 - 8'd105); nom <= 1'b1; end
		else begin cacc <= cacc + 7'd44; nom <= 1'b0; end
		if (nom) begin
			tdiv <= tdiv + 5'd1;
			if (tdiv == 5'd31) tick <= 1'b1;
		end
		cen  <= go;
		debt <= debt + {7'd0, nom} - {7'd0, go};
		if (debt > dbg_debtmax) dbg_debtmax <= debt;
		if (stall) dbg_stallclk <= dbg_stallclk + 32'd1;
		if (go) dbg_cens <= dbg_cens + 32'd1;
		if (nom) dbg_noms <= dbg_noms + 32'd1;
	end
end

// ---------------------------------------------------------------- latch
reg [7:0] latch;
reg       pending;
wire      p3_we;
wire [7:0] p3_latch;
always @(posedge clk) begin
	if (rst) begin
		latch <= 8'd0; pending <= 1'b0;
	end else begin
		if (cen && p3_we && !p3_latch[5]) pending <= 1'b0;   // one enable after the write
		if (latch_wr) begin latch <= latch_d; pending <= 1'b1; end
	end
end

// ---------------------------------------------------------------- the 8052 and its memories
wire [15:0] rom_addr;
wire [7:0]  ram_addr, ram_dout, ram_din;
wire        ram_we;
wire        x_acc, x_wr;
wire [15:0] x_addr;
wire [7:0]  x_dout;
wire [7:0]  x_din;
reg         rom_hi;
wire [7:0]  prg_q;

// program: read on the enable (the byte the core samples at the next one), written by the download
vh_dpram #(.AW(15), .DW(8), .NBE(1)) u_prg (
	.clk(clk), .a_ce(cen | dl_we), .a_we(dl_we), .a_addr(dl_we ? dl_addr : rom_addr[14:0]),
	.a_wd(dl_data), .a_rd(prg_q),
	.b_addr(15'd0), .b_rd()
);

// internal RAM: read and written on the enable (Eolith.sdc gives the 8052's paths into it two clocks)
vh_dpram #(.AW(8), .DW(8), .NBE(1)) u_iram (
	.clk(clk), .a_ce(cen), .a_we(ram_we), .a_addr(ram_addr), .a_wd(ram_dout), .a_rd(ram_din),
	.b_addr(8'd0), .b_rd()
);

// external RAM, 0x0000-0x00ff: read every clock, current at the next enable
reg [7:0] xram [0:255];
reg [7:0] xram_q;
always @(posedge clk) begin
	if (cen) begin
		rom_hi <= rom_addr[15];
		if (x_acc && x_wr && x_addr[15:8] == 8'd0) xram[x_addr[7:0]] <= x_dout;
	end
	xram_q <= xram[x_addr[7:0]];
end

// the banked window through a one-line buffer. The bank is MAME's memory bank: entry 0 from reset, set by
// each write to P3 (qs1000_p3_w), not the P3 latch itself, which resets to 0xff.
reg  [2:0]  bank;
always @(posedge clk) begin
	if (rst) bank <= 3'd0;
	else if (cen && p3_we) bank <= p3_latch[2:0];
end
wire        x_bank = !grad && x_acc && !x_wr && x_addr[15:8] != 8'd0;
reg         lb_v = 1'b0;
reg  [14:0] lb_tag;                  // {bank, addr[15:4]}
reg  [127:0] lb;                     // byte 0 in [127:120]
reg         dat_busy;
wire        lb_hit = lb_v && lb_tag == {bank, x_addr[15:4]};
assign stall = x_bank && !lb_hit;
wire [7:0]  lb_byte = lb[8 * (15 - x_addr[3:0]) +: 8];
assign x_din = x_addr[15:8] == 8'd0 ? xram_q : grad ? 8'h00 : lb_byte;

always @(posedge clk) begin
	if (rst) begin
		lb_v <= 1'b0;
		dat_busy <= 1'b0;
		dat_req <= dat_ack;
	end else if (!dat_busy) begin
		if (stall) begin
			dat_addr <= SNDPRG_BASE[26:1] + {7'd0, bank, x_addr[15:4], 3'b000};
			dat_req  <= ~dat_req;
			dat_busy <= 1'b1;
			lb_tag   <= {bank, x_addr[15:4]};
			lb_v     <= 1'b0;
			dbg_xmiss <= dbg_xmiss + 16'd1;
		end
	end else if (dat_req == dat_ack) begin
		lb <= {sw64(dat_dout), sw64(dat_doutb)};
		lb_v <= 1'b1;
		dat_busy <= 1'b0;
	end
end

jt8052 u_mcu (
	.rst(rst), .clk(clk), .cen(cen),
	.int0n(1'b1), .int1n(grad | ~pending),
	// with grad, P3.2 and P3.3 read 1 here: jt8052 takes the INT pins from them, MAME's lines are separate
	.p0_i(8'hff), .p1_i(grad ? 8'h01 : latch), .p2_i(grad ? 8'h00 : 8'hff),
	.p3_i(grad ? {4'h0, 2'b11, 1'b0, rxd} : 8'hff),
	.p0_o(), .p1_o(), .p2_o(), .p3_o(),
	.rom_data(rom_hi ? 8'hff : prg_q), .rom_addr(rom_addr),
	.ram_din(ram_din), .ram_dout(ram_dout), .ram_addr(ram_addr), .ram_we(ram_we),
	.x_din(x_din), .x_dout(x_dout), .x_addr(x_addr), .x_wr(x_wr), .x_acc(x_acc),
	.p3_we(p3_we), .p3_latch(p3_latch)
);

// ---------------------------------------------------------------- wavetable engine
wire wave_wr = cen && x_acc && x_wr && x_addr[15:5] == 11'h010 && x_addr[4:0] <= 5'h11;
assign wave_wr_o   = wave_wr;
assign wave_off_o  = x_addr[4:0];
assign wave_data_o = x_dout;
assign tick_o      = tick;
assign pending_o   = pending;
assign p3we_o      = cen && p3_we;
assign p3_o        = p3_latch;
assign xrd_o       = cen && x_acc && !x_wr;
assign xrd_addr_o  = x_addr;
assign xrd_data_o  = x_din;

wire         rom_req;
wire [19:0]  rom_line;
reg          rom_ack;
reg  [127:0] rom_data;
vh_qs1000_voice u_voice (
	.clk(clk), .rst(rst),
	.wr(wave_wr), .wr_off(x_addr[4:0]), .wr_data(x_dout),
	.tick(tick), .bal_pcb(bal_pcb),
	.rom_req(rom_req), .rom_line(rom_line), .rom_ack(rom_ack), .rom_data(rom_data),
	.mix_valid(), .mix_l(), .mix_r(),
	.out_l(out_l), .out_r(out_r),
	.dbg_drops(dbg_drops), .dbg_stalls(dbg_stalls)
);

// sample lines from SDRAM; lines past what SMP_BASE holds read as zero without a request
reg smp_busy;
always @(posedge clk) begin
	rom_ack <= 1'b0;
	if (rst) begin
		smp_busy <= 1'b0;
		smp_req <= smp_ack;
	end else if (!smp_busy) begin
		if (rom_req && !rom_ack) begin
			if (rom_line >= SMP_LINES) begin
				rom_data <= 128'd0;
				rom_ack <= 1'b1;
			end else begin
				smp_addr <= SMP_BASE[26:1] + {3'd0, rom_line, 3'b000};
				smp_req <= ~smp_req;
				smp_busy <= 1'b1;
			end
		end
	end else if (smp_req == smp_ack) begin
		rom_data <= {sw64(smp_dout), sw64(smp_doutb)};
		rom_ack <= 1'b1;
		smp_busy <= 1'b0;
	end
end

endmodule
