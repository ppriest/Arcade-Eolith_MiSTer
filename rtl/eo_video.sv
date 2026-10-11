// The frame buffers and scan-out of the three boards: one VRAM, four banks of 40,960 x 15 bits in
// eo_dpram (240 M10K), port A the CPU's window onto the buffer `vbuf` selects, port B the display.
//
//   board 0, Vega (vegaeo.cpp vram_w/vram_r 89-99, screen_update_vega 173-183): two 320 x 256 byte
//     buffers (0x14000 each); byte k of dword d of buffer b is bank k at d + b * 20480. A byte written as
//     0xff is not stored. The display shows the other buffer through the 256 x xRGB555 palette (at
//     0xfc200000, one entry per dword, low halfword; upper lanes read 0).
//   board 1, Gradation 2D (eolith.cpp eolith_vram_w/r 206-221, screen_update_eolith 234-244): two buffers
//     of 15-bit pixels, a line every 336 halfwords; the CPU's window here is lines 0-239 (halfwords
//     0-80639; eo_cpumem sends the rest to SDRAM). Halfword h of buffer b is bank (h & 3) at
//     h / 4 + b * 20160. A halfword is stored only when written whole with bit 15 clear. The display shows
//     the other buffer as RGB555.
//   board 2, eolith16 (eolith16.cpp 63-71, 124-164): two 64 KB byte buffers, the CPU's chosen by `vbuf`
//     (bit 7 of 0xffe80000, inverted there); byte k of dword d of buffer b is bank k at d + b * 16384.
//     The display always shows buffer 0 (MAME reads m_vram's base), 320 x 200, through the fixed 3-3-2
//     palette, the low byte of each halfword first: dot x is CPU byte x ^ 1. (MAME keeps the share in
//     host order on the 16-bit bus and reads it as bytes, 132-141; the CPU's halfword 0x0109 at x shows
//     0x09 then 0x01. Checked: the core's VRAM writes equal MAME's on hidden text, debug/sysk/vwlog.txt
//     against debug/tmp/textsrc.txt, and only with the swap does the text read as MAME's.)
//
// Raster: HTOTAL x VTOTAL dots at ce_pix, the picture from (0, 0). The drivers give no timing; the sync
// positions are guesses (docs/HACKS.md). vblank_flag is MAME's "vpos >= 240" on every board
// (eolith_speedup.cpp:112), the bit the games poll.
//
// Pipeline: the counters name the dot fetched during the ce_pix period that follows; colour, blanks and
// syncs come out together at the next ce_pix. Needs at least 4 clk between ce_pix.

`default_nettype none

module eo_video #(
	parameter HTOTAL   = 455,
	parameter VTOTAL   = 262,
	parameter HS_START = 336,
	parameter HS_END   = 370,
	parameter VS_START = 244,
	parameter VS_END   = 247
) (
	input  wire        clk,
	input  wire        ce_pix,
	input  wire [1:0]  board,
	input  wire        vbuf,          // the buffer the CPU sees
	input  wire        flip,          // the picture turned 180 degrees (the OSD; no Eolith board has a flip)

	// CPU: one access per clock, read data the clock after
	input  wire        cpu_vram_cs,
	input  wire        cpu_pal_cs,
	input  wire        cpu_we,
	input  wire [3:0]  cpu_be,
	input  wire [17:2] cpu_addr,      // dword address within the window / the palette
	input  wire [31:0] cpu_wdata,
	output reg  [31:0] cpu_rdata,

	// hidctch3's light pens: a cross at each pen's dot (MAME draws the crosshairs in its UI)
	input  wire [1:0]  cross_en,      // P2, P1
	input  wire [8:0]  cx1, cx2,
	input  wire [7:0]  cy1, cy2,

	output wire        vblank_flag,
	output reg  [7:0]  r, g, b,
	output reg         hblank, vblank, hsync, vsync
);

wire vega = board == 2'd0, grad = board == 2'd1, e16 = board == 2'd2;

reg [8:0] hcnt = 9'd0, vcnt = 9'd0;
always @(posedge clk) if (ce_pix) begin
	if (hcnt == HTOTAL - 1) begin
		hcnt <= 9'd0;
		vcnt <= (vcnt == VTOTAL - 1) ? 9'd0 : vcnt + 9'd1;
	end else
		hcnt <= hcnt + 9'd1;
end
assign vblank_flag = vcnt >= 9'd240;

// ---- CPU side: the location and the bank writes ----
wire [15:0] d = cpu_addr[17:2];
wire [15:0] a_loc = grad ? {1'b0, d[15:1]} + (vbuf ? 16'd20160 : 16'd0)
                  : vega ? d + (vbuf ? 16'd20480 : 16'd0)
                  :        d + (vbuf ? 16'd16384 : 16'd0);
wire        wr = cpu_vram_cs & cpu_we;
wire [7:0]  by [0:3];
assign by[0] = cpu_wdata[31:24];
assign by[1] = cpu_wdata[23:16];
assign by[2] = cpu_wdata[15:8];
assign by[3] = cpu_wdata[7:0];
// Gradation 2D: the dword's high halfword (the lower address) to bank 2 * d[0], the low one to the next
wire        g_hi = cpu_be[3] & cpu_be[2] & !cpu_wdata[31];
wire        g_lo = cpu_be[1] & cpu_be[0] & !cpu_wdata[15];
reg  [3:0]  a_we;
reg  [14:0] a_wd [0:3];
integer k;
always @(*) begin
	for (k = 0; k < 4; k = k + 1) begin
		if (grad) begin
			a_we[k]  = wr && (k[1] == d[0]) && (k[0] ? g_lo : g_hi);
			a_wd[k]  = k[0] ? cpu_wdata[14:0] : cpu_wdata[30:16];
		end else begin
			a_we[k]  = wr && cpu_be[3 - k] && (!vega || by[k] != 8'hff);
			a_wd[k]  = {7'd0, by[k]};
		end
	end
end

// ---- display side: the location of the dot the counters name ----
// Flipped, the dot at (x, y) is the source's (319 - x, last line - y): the lines from the last one down, each
// read from its end, the dot within a location mirrored.
localparam [15:0] LAST_V = 16'd19120, LAST_G = 16'd20076, LAST_K = 16'd15920;   // 239 x 80, 239 x 84, 199 x 80
wire [15:0] stride = grad ? 16'd84 : 16'd80;
reg  [15:0] line_base = 16'd0;        // location of (0, vcnt) within a buffer
reg  [15:0] line_base_f = 16'd0;      // flipped: location of the source line shown at vcnt
always @(posedge clk) if (ce_pix && hcnt == HTOTAL - 1) begin
	line_base   <= (vcnt == VTOTAL - 1) ? 16'd0 : line_base + stride;
	line_base_f <= (vcnt == VTOTAL - 1) ? (grad ? LAST_G : e16 ? LAST_K : LAST_V) : line_base_f - stride;
end
wire [15:0] col   = flip ? 16'd79 - {9'd0, hcnt[8:2]} : {9'd0, hcnt[8:2]};
wire [15:0] b_loc = (flip ? line_base_f : line_base) + col
                  + (grad ? (vbuf ? 16'd0 : 16'd20160) : vega ? (vbuf ? 16'd0 : 16'd20480) : 16'd0);

// ---- the four banks: 32K + 8K locations each, bit 15 of the location picks one ----
wire [14:0] a_q [0:3];
wire [14:0] b_q [0:3];
reg         a_hi, b_hi;
always @(posedge clk) begin
	a_hi <= a_loc[15];
	b_hi <= b_loc[15];
end
genvar gk;
generate
	for (gk = 0; gk < 4; gk = gk + 1) begin : bank
		wire [14:0] aq0, aq1, bq0, bq1;
		eo_dpram #(.AW(15), .DW(15)) u_lo (
			.clk(clk), .a_we(a_we[gk] & !a_loc[15]), .a_addr(a_loc[14:0]), .a_wd(a_wd[gk]), .a_rd(aq0),
			.b_addr(b_loc[14:0]), .b_rd(bq0)
		);
		eo_dpram #(.AW(13), .DW(15)) u_hi (
			.clk(clk), .a_we(a_we[gk] & a_loc[15]), .a_addr(a_loc[12:0]), .a_wd(a_wd[gk]), .a_rd(aq1),
			.b_addr(b_loc[12:0]), .b_rd(bq1)
		);
		assign a_q[gk] = a_hi ? aq1 : aq0;
		assign b_q[gk] = b_hi ? bq1 : bq0;
	end
endgenerate

// b_q is the location at b_loc a clock later: valid after the ce1 edge, held to ce_pix
reg        ce1 = 1'b0, ce2 = 1'b0, ce3 = 1'b0;
reg [1:0]  lane1;
always @(posedge clk) begin
	ce1 <= ce_pix;
	ce2 <= ce1;
	ce3 <= ce2;
	if (ce1) lane1 <= {hcnt[1] ^ flip, hcnt[0] ^ flip ^ e16};
end
wire [14:0] dot = b_q[lane1];

// ---- the palette (Vega): port A the CPU, port B the display (the dot's entry a clock later, at ce3) ----
wire [15:0] p_q, p_cpu;
vh_dpram #(.AW(8), .DW(16), .NBE(2)) u_pal (
	.clk(clk), .a_ce(1'b1), .a_we({2{cpu_pal_cs & cpu_we}} & cpu_be[1:0]), .a_addr(cpu_addr[9:2]),
	.a_wd(cpu_wdata[15:0]), .a_rd(p_cpu),
	.b_addr(dot[7:0]), .b_rd(p_q)
);
reg [14:0] dot2;                      // the Gradation 2D's and eolith16's dot, beside the palette read
always @(posedge clk) if (ce2) dot2 <= dot;

// ---- CPU reads ----
reg cs_pal_d, d0_d;
always @(posedge clk) begin
	cs_pal_d <= cpu_pal_cs;
	d0_d     <= d[0];
end
always @(*) begin
	if (cs_pal_d)  cpu_rdata = {16'd0, p_cpu};
	else if (grad) cpu_rdata = d0_d ? {1'b0, a_q[2], 1'b0, a_q[3]} : {1'b0, a_q[0], 1'b0, a_q[1]};
	else           cpu_rdata = {a_q[0][7:0], a_q[1][7:0], a_q[2][7:0], a_q[3][7:0]};
end

// eolith16's palette (eolith16_palette, 145-164): three resistor bits for red and green, two for blue
function [7:0] w3(input [2:0] v);
	w3 = (v[0] ? 8'h21 : 8'h00) + (v[1] ? 8'h47 : 8'h00) + (v[2] ? 8'h97 : 8'h00);
endfunction

// ---- output, at the ce_pix that ends the fetch period: the counters still name that dot ----
reg  [7:0] r_n, g_n, b_n;
wire       hb = hcnt >= 9'd320;
// a 7-dot cross, P1 magenta, P2 cyan, in a black outline a dot wide: {arm, outline}
function [9:0] adiff(input [8:0] a, input [8:0] b);   // |a - b|
	adiff = a >= b ? {1'b0, a} - {1'b0, b} : {1'b0, b} - {1'b0, a};
endfunction
function [1:0] xhair(input [8:0] cx, input [7:0] cy);
	reg [9:0] dx, dy;
	begin
		dx = adiff(hcnt, cx); dy = adiff(vcnt, {1'b0, cy});
		xhair[1] = (dy == 10'd0 && dx <= 10'd3) || (dx == 10'd0 && dy <= 10'd3);
		xhair[0] = (dy <= 10'd1 && dx <= 10'd4) || (dx <= 10'd1 && dy <= 10'd4);
	end
endfunction
// flipped, a pen's dot is shown at (319 - x, 239 - y)
wire [8:0] fx1 = flip ? 9'd319 - cx1 : cx1, fx2 = flip ? 9'd319 - cx2 : cx2;
wire [7:0] fy1 = flip ? 8'd239 - cy1 : cy1, fy2 = flip ? 8'd239 - cy2 : cy2;
wire [1:0] c1 = cross_en[0] ? xhair(fx1, fy1) : 2'b00, c2 = cross_en[1] ? xhair(fx2, fy2) : 2'b00;
wire       vb = vcnt >= (board == 2'd2 ? 9'd200 : 9'd240);
always @(posedge clk) begin
	if (ce3) begin
		if (vega) begin
			r_n <= {p_q[14:10], p_q[14:12]};
			g_n <= {p_q[9:5],   p_q[9:7]};
			b_n <= {p_q[4:0],   p_q[4:2]};
		end else if (grad) begin
			r_n <= {dot2[14:10], dot2[14:12]};
			g_n <= {dot2[9:5],   dot2[9:7]};
			b_n <= {dot2[4:0],   dot2[4:2]};
		end else begin
			r_n <= w3(dot2[2:0]);
			g_n <= w3(dot2[5:3]);
			b_n <= (dot2[6] ? 8'h55 : 8'h00) + (dot2[7] ? 8'haa : 8'h00);
		end
	end
	if (ce_pix) begin
		{r, g, b} <= (hb | vb) ? 24'd0 : c1[1] ? 24'hff00ff : c2[1] ? 24'h00ffff : (c1[0] | c2[0]) ? 24'd0 :
		             {r_n, g_n, b_n};
		hblank <= hb;
		vblank <= vb;
		hsync  <= hcnt >= HS_START && hcnt < HS_END;
		vsync  <= vcnt >= VS_START && vcnt < VS_END;
	end
end

endmodule
