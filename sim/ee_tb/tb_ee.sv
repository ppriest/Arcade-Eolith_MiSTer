// Bench top for eo_eeprom93cxx as the Gradation 2D has it (93C66, 512 x 8): the module's ports, flat.
module tb_ee (
	input         clk,
	input         rst,
	input         cs,
	input         sk,
	input         di,
	output        dout,
	input  [8:0]  rd_addr,
	output [7:0]  rd_data,
	output        written
);
eo_eeprom93cxx #(.AW(9), .DW(8)) u (
	.clk(clk), .rst(rst), .cs(cs), .sk(sk), .di(di), .dout(dout),
	.load_we(1'b0), .load_addr(9'd0), .load_data(8'd0), .rd_addr(rd_addr), .rd_data(rd_data), .written(written)
);
endmodule
