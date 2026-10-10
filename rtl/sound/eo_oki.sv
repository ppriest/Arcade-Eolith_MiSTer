// eolith16.cpp's sound (eolith16 186-188, map 85): an OKI M6295 on 1 MHz, pin 7 high, on the main CPU's
// bus at 0xffe40001, no bank. jt6295 unchanged; its ROM (MAME's "oki" region; the chip addresses the first
// 256 KB) is read from SDRAM at ROM_BASE through Vamphalf's bridge and granule cache, as
// Arcade-Vamphalf_MiSTer's rtl/sound/vh_ymoki.sv does (rtl/sound/PROVENANCE.md).
//
// The enable is a 32-bit phase accumulator: 1 MHz over 630/11 MHz, times 2^32. MAME routes the chip at 1.0
// to each side; its M6295 reaches full scale with one voice at full volume, jt6295's sum is 14 bits with a
// voice at 12, so it is scaled by 16 (as vh_ymoki).

module eo_oki #(
	parameter [26:0] ROM_BASE = 27'h2100000
) (
	input               clk,
	input               rst,
	input               dl,               // the ROM is being downloaded: invalidate the cache

	input               wr,               // one-clock strobe
	input       [7:0]   din,
	output      [7:0]   dout,

	// SDRAM: one 64-bit granule per request
	output reg  [26:1]  sd_addr,
	output reg          sd_req,
	input               sd_ack,
	input       [63:0]  sd_dout,

	output signed [15:0] out
);

reg  [31:0] acc = 32'd0;
reg         cen = 1'b0;
always @(posedge clk) {cen, acc} <= {1'b0, acc} + 33'h0_0478_4784;

wire        [17:0] rom_addr;
wire        [7:0]  rom_data;
wire               rom_ok;
wire signed [13:0] snd;
jt6295 #(.INTERPOL(0)) u_oki (
	.rst(rst), .clk(clk), .cen(cen), .ss(1'b1),
	.wrn(~wr), .din(din), .dout(dout),
	.rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
	.sound(snd), .sample()
);

wire        br_req, br_valid;
wire [19:0] br_addr;
wire [7:0]  br_data;
oki_rom_bridge u_bridge (
	.clk(clk), .reset(rst),
	.rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok), .bank(2'd0),
	.req(br_req), .addr(br_addr), .valid(br_valid), .data(br_data)
);

wire        g_req;
wire [25:0] g_addr;
reg         g_valid;
reg  [63:0] g_data;
sample_cache #(.ENTRIES(8)) u_cache (
	.clk(clk), .reset(rst), .inval(dl),
	.req(br_req), .addr({6'd0, br_addr}), .valid(br_valid), .data(br_data),
	.g_req(g_req), .g_addr(g_addr), .g_valid(g_valid), .g_data(g_data)
);

reg sd_busy;
always @(posedge clk) begin
	g_valid <= 1'b0;
	if (rst) begin
		sd_busy <= 1'b0;
		sd_req <= sd_ack;
	end else if (!sd_busy) begin
		if (g_req && !g_valid) begin
			sd_addr <= ROM_BASE[26:1] + {1'b0, g_addr[25:1]};
			sd_req <= ~sd_req;
			sd_busy <= 1'b1;
		end
	end else if (sd_req == sd_ack) begin
		g_data <= sd_dout;
		g_valid <= 1'b1;
		sd_busy <= 1'b0;
	end
end

wire signed [17:0] x16 = {snd, 4'd0};
assign out = (x16 > 18'sd32767) ? 16'sd32767 : (x16 < -18'sd32768) ? -16'sd32768 : x16[15:0];

endmodule
