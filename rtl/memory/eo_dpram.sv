// One clock, two ports, any width: A reads and writes the whole word, B reads, every clock.
// vh_dpram's shape (rtl/memory/vh_dpram.sv: altsyncram in BIDIR_DUAL_PORT, one M10K copy for both
// readers, the behavioural model for the benches) without byte enables, so the width need not be a
// multiple of 8: the frame buffer's 15-bit banks. MAXD caps the depth of one M10K slice: 2048 makes
// the 2K x 5 slices, three per 2K words at 15 bits (8K x 1 would take 15 per 8K, a quarter more).
module eo_dpram #(
	parameter AW   = 13,
	parameter DW   = 15,
	parameter MAXD = 2048
) (
	input               clk,
	input               a_we,
	input   [AW-1:0]    a_addr,
	input   [DW-1:0]    a_wd,
	output  [DW-1:0]    a_rd,
	input   [AW-1:0]    b_addr,
	output  [DW-1:0]    b_rd
);

`ifndef ALTERA_RESERVED_QIS
reg [DW-1:0] mem [0:(1 << AW) - 1];
reg [DW-1:0] qa, qb;
always @(posedge clk) begin
	if (a_we) mem[a_addr] <= a_wd;
	qa <= mem[a_addr];
end
always @(posedge clk) qb <= mem[b_addr];
assign a_rd = qa;
assign b_rd = qb;
`else
altsyncram #(
	.operation_mode("BIDIR_DUAL_PORT"),
	.ram_block_type("M10K"),
	.maximum_depth(MAXD),
	.intended_device_family("Cyclone V"),
	.lpm_type("altsyncram"),
	.numwords_a(1 << AW), .widthad_a(AW), .width_a(DW),
	.numwords_b(1 << AW), .widthad_b(AW), .width_b(DW),
	.width_byteena_a(1), .width_byteena_b(1),
	.outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
	.address_reg_b("CLOCK1"), .indata_reg_b("CLOCK1"), .wrcontrol_wraddress_reg_b("CLOCK1"),
	.clock_enable_input_a("BYPASS"), .clock_enable_output_a("BYPASS"),
	.clock_enable_input_b("BYPASS"), .clock_enable_output_b("BYPASS"),
	.outdata_aclr_a("NONE"), .outdata_aclr_b("NONE"),
	.read_during_write_mode_mixed_ports("DONT_CARE"),
	.read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
	.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
	.power_up_uninitialized("FALSE")
) u_ram (
	.clock0(clk), .clocken0(1'b1), .address_a(a_addr), .data_a(a_wd), .wren_a(a_we), .byteena_a(1'b1), .q_a(a_rd),
	.clock1(clk), .clocken1(1'b1), .address_b(b_addr), .data_b({DW{1'b0}}), .wren_b(1'b0), .q_b(b_rd),
	.aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0), .byteena_b(1'b1),
	.clocken2(1'b1), .clocken3(1'b1), .rden_a(1'b1), .rden_b(1'b1), .eccstatus()
);
`endif

endmodule
