// Bench top for eo_pens: the module's ports, flat.
module tb_pens (
	input         clk,
	input         reset,
	input         frame,
	input         flip,
	input  [15:0] ana0, ana1,
	input  [3:0]  dir0, dir1,
	input  [1:0]  mode0, mode1,
	input         ms_ev,
	input  [8:0]  ms_dx, ms_dy,
	input  [1:0]  ms_to,
	output [7:0]  pen1_x, pen2_x,
	output [6:0]  pen1_y, pen2_y
);
eo_pens u (
	.clk(clk), .reset(reset), .frame(frame), .flip(flip), .ana0(ana0), .ana1(ana1), .dir0(dir0), .dir1(dir1),
	.mode0(mode0), .mode1(mode1), .ms_ev(ms_ev), .ms_dx(ms_dx), .ms_dy(ms_dy), .ms_to(ms_to), .pen1_x(pen1_x), .pen1_y(pen1_y), .pen2_x(pen2_x), .pen2_y(pen2_y)
);
endmodule
