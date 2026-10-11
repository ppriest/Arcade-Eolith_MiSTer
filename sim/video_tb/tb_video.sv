// Bench top for eo_video: the module's ports, flat.
module tb_video (
	input             clk,
	input             ce_pix,
	input      [1:0]  board,
	input             vbuf,
	input             flip,
	input             cpu_vram_cs,
	input             cpu_pal_cs,
	input             cpu_we,
	input      [3:0]  cpu_be,
	input      [17:2] cpu_addr,
	input      [31:0] cpu_wdata,
	output     [31:0] cpu_rdata,
	input      [1:0]  cross_en,
	input      [8:0]  cx1, cx2,
	input      [7:0]  cy1, cy2,
	output            vblank_flag,
	output     [7:0]  r, g, b,
	output            hblank, vblank, hsync, vsync
);
eo_video u (.*);
endmodule
