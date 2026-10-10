// The Gradation 2D's sound CPU as eolith.cpp wires it (eolith45 689-735, sound maps 397-412, 261-266,
// 311-322): an i8032 on 12 MHz that takes the main CPU's sound latch and sends the QS1000 its commands
// over the UART. The 8052 is Vamphalf's vendored jt8052, unchanged, as in eo_qs1000.
//
//   program  0x0000-0x7fff  the 32 KB soundcpu ROM, in block RAM; above, 0xff
//   data     0x0000-0x7fff  reads: sounddata[bank * 0x8000 + addr], bank = the last P1 written, bits 3:0
//                           (sound_p1_w; entry 0 until then), from SDRAM through a 16-byte line buffer
//            0x8000         reads the latch and clears its pending flag (generic_latch_8_device::read)
//            the rest       reads 0; writes are dropped (no RAM on the bus)
//   INT0     the latch's pending flag (data_pending_callback 726)
//   INT1     high (inactive). MAME holds the line asserted (machine_reset 265) because its timer GATE
//            counts while IE1 is set (i8051.cpp 832); the program runs timer 1 gated (TMOD 0xa1) as the
//            UART's baud clock, which on the part counts while /INT1 is high (docs/MAME_KLUDGES.md)
//   TxD      P3.1 (sound_p3_w), to the QS1000's RxD; low from reset until the first 1 bit sent, as
//            MAME's line is from power-on (docs/MAME_KLUDGES.md)
//
// 12 MHz is 22 enables in 105 clocks of 630/11 MHz. A data read that misses the line buffer holds the
// enables until the line is in, and the enables missed are given back later, never two in a row, as in
// eo_qs1000. (MAME, 1,800 frames: at most 105 banked reads a frame, puzzlekg; docs/HARDWARE_NOTES.md.)

module eo_sndcpu #(
	parameter [26:0] DATA_BASE = 27'h2380000     // sounddata in SDRAM
) (
	input               clk,
	input               rst,

	input               dl_we,           // the program, while rst is held
	input       [14:0]  dl_addr,
	input       [7:0]   dl_data,

	input               latch_wr,
	input       [7:0]   latch_d,
	output              txd,

	// SDRAM: one 16-byte line of sounddata per request (double read)
	output reg  [26:1]  dat_addr,
	output reg          dat_req,
	input               dat_ack,
	input       [63:0]  dat_dout,
	input       [63:0]  dat_doutb,

	output reg  [15:0]  dbg_xmiss = 16'd0,   // banked reads that waited for SDRAM
	output              xrd_o,               // for the benches: a data read the CPU takes, its address and byte
	output      [15:0]  xrd_addr_o,
	output      [7:0]   xrd_data_o,
	output              pending_o
);

function [63:0] sw64(input [63:0] g);
	sw64 = {g[7:0], g[15:8], g[23:16], g[31:24], g[39:32], g[47:40], g[55:48], g[63:56]};
endfunction

// ---------------------------------------------------------------- clock
reg  [6:0]  cacc;
reg         nom;                     // the undelayed 12 MHz train
reg  [7:0]  debt;
reg         cen;
wire        stall;
wire        go = (nom || debt != 8'd0) && !stall && !cen;
always @(posedge clk) begin
	if (rst) begin
		cacc <= 7'd0; nom <= 1'b0; debt <= 8'd0; cen <= 1'b0;
	end else begin
		if (cacc + 7'd22 >= 7'd105) begin cacc <= cacc + 7'd22 - 7'd105; nom <= 1'b1; end
		else begin cacc <= cacc + 7'd22; nom <= 1'b0; end
		cen  <= go;
		debt <= debt + {7'd0, nom} - {7'd0, go};
	end
end

// ---------------------------------------------------------------- the 8032 and its memories
wire [15:0] rom_addr;
wire [7:0]  ram_addr, ram_dout, ram_din;
wire        ram_we;
wire        x_acc, x_wr;
wire [15:0] x_addr;
wire [7:0]  x_dout, x_din;
wire [7:0]  p1_o, p3_o;
reg         rom_hi;
wire [7:0]  prg_q;

vh_dpram #(.AW(15), .DW(8), .NBE(1)) u_prg (
	.clk(clk), .a_ce(cen | dl_we), .a_we(dl_we), .a_addr(dl_we ? dl_addr : rom_addr[14:0]),
	.a_wd(dl_data), .a_rd(prg_q),
	.b_addr(15'd0), .b_rd()
);
vh_dpram #(.AW(8), .DW(8), .NBE(1)) u_iram (
	.clk(clk), .a_ce(cen), .a_we(ram_we), .a_addr(ram_addr), .a_wd(ram_dout), .a_rd(ram_din),
	.b_addr(8'd0), .b_rd()
);
always @(posedge clk) if (cen) rom_hi <= rom_addr[15];

// latch
reg  [7:0]  latch;
reg         pending;
wire        x_latch = x_acc && !x_wr && x_addr == 16'h8000;
always @(posedge clk) begin
	if (rst) begin
		latch <= 8'd0; pending <= 1'b0;
	end else begin
		if (cen && x_latch) pending <= 1'b0;
		if (latch_wr) begin latch <= latch_d; pending <= 1'b1; end
	end
end

// the bank: MAME's memory bank, set by each P1 write; jt8052 shows the P1 latch only, so a write is seen
// as a change of it (P1 resets to 0xff, the bank to entry 0)
reg  [7:0]  p1_l;
reg  [3:0]  bank;
always @(posedge clk) begin
	if (rst) begin
		p1_l <= 8'hff; bank <= 4'd0;
	end else begin
		p1_l <= p1_o;
		if (p1_o != p1_l) bank <= p1_o[3:0];
	end
end

// the banked window through a one-line buffer
wire        x_bank = x_acc && !x_wr && !x_addr[15];
reg         lb_v = 1'b0;
reg  [14:0] lb_tag;                  // {bank, addr[14:4]}
reg  [127:0] lb;                     // byte 0 in [127:120]
reg         dat_busy;
wire        lb_hit = lb_v && lb_tag == {bank, x_addr[14:4]};
assign stall = x_bank && !lb_hit;
// by address alone: jt8052 takes the byte in a later step than the one that drives x_acc
assign x_din = !x_addr[15] ? lb[8 * (15 - x_addr[3:0]) +: 8] : x_addr == 16'h8000 ? latch : 8'h00;

always @(posedge clk) begin
	if (rst) begin
		lb_v <= 1'b0;
		dat_busy <= 1'b0;
		dat_req <= dat_ack;
	end else if (!dat_busy) begin
		if (stall) begin
			dat_addr <= DATA_BASE[26:1] + {7'd0, bank, x_addr[14:4], 3'b000};
			dat_req  <= ~dat_req;
			dat_busy <= 1'b1;
			lb_tag   <= {bank, x_addr[14:4]};
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
	.int0n(~pending), .int1n(1'b1),
	.p0_i(8'hff), .p1_i(8'hff), .p2_i(8'hff), .p3_i(8'hff),
	.p0_o(), .p1_o(p1_o), .p2_o(), .p3_o(p3_o),
	.rom_data(rom_hi ? 8'hff : prg_q), .rom_addr(rom_addr),
	.ram_din(ram_din), .ram_dout(ram_dout), .ram_addr(ram_addr), .ram_we(ram_we),
	.x_din(x_din), .x_dout(x_dout), .x_addr(x_addr), .x_wr(x_wr), .x_acc(x_acc),
	.p3_we(), .p3_latch()
);
// MAME's m_sound_txd starts at 0 (eolith.cpp 180) and the i8032's reset writes P3 before its UART idles
// the pin high (i8051.cpp 1347, 1357), so the QS1000 sees RxD low until the first transmit(1): the first
// command (B0 0A 40 on hidnctch) arrives misframed and is lost there. On the board TxD is high from reset.
reg         tx_lo = 1'b0, tx_up = 1'b0;
always @(posedge clk) begin
	if (rst) begin
		tx_lo <= 1'b0; tx_up <= 1'b0;
	end else begin
		if (!p3_o[1]) tx_lo <= 1'b1;
		if (tx_lo && p3_o[1]) tx_up <= 1'b1;
	end
end
assign txd        = tx_up & p3_o[1];
assign xrd_o      = cen && x_acc && !x_wr;
assign xrd_addr_o = x_addr;
assign xrd_data_o = x_din;
assign pending_o  = pending;

endmodule
