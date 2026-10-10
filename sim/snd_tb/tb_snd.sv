// Sound bench top: the sound board alone on the real SDRAM controller and a chip model: the QS1000
// (eo_qs1000), and on board 1 the Gradation 2D's sound CPU (eo_sndcpu) in front of it, on SDRAM port 1.
// main.cpp loads the image and the programs, and plays MAME's latch commands into the board.
module tb_snd (
	input             clk,
	input             rst,
	input      [1:0]  board,
	input             dl_we,
	input      [15:0] dl_addr,          // bit 15: the sound CPU's program
	input      [7:0]  dl_data,
	input             latch_wr,
	input      [7:0]  latch_d,
	output            wave_wr,
	output     [4:0]  wave_off,
	output     [7:0]  wave_data,
	output     [15:0] xmiss,
	output     [15:0] drops,
	output     [15:0] stalls,
	output     [7:0]  debtmax,
	output     [31:0] stallclk,
	output     [31:0] cens,
	output     [31:0] noms,
	output            pending,
	output            p3we,
	output     [7:0]  p3,
	output            xrd,
	output     [15:0] xrd_addr,
	output     [7:0]  xrd_data,
	output            sxrd,             // the sound CPU's data reads
	output     [15:0] sxrd_addr,
	output     [7:0]  sxrd_data,
	output     [15:0] sxmiss,
	output            txd_o             // the sound CPU's TxD (the QS1000's RxD)
);
wire        grad = board == 2'd1;
wire [26:1] s0_addr, s1_addr, q1_addr, c1_addr;
wire        s0_req, s0_ack, s1_req, s1_ack, q1_req, c1_req;
wire [63:0] m_dout, m_doutb;
wire        txd;
assign txd_o = txd;
assign s1_addr = grad ? c1_addr : q1_addr;
assign s1_req  = grad ? c1_req : q1_req;
eo_qs1000 u_snd (
	.clk(clk), .rst(rst), .dl_we(dl_we && !dl_addr[15]), .dl_addr(dl_addr[14:0]), .dl_data(dl_data),
	.latch_wr(latch_wr && !grad), .latch_d(latch_d), .bal_pcb(1'b0), .grad(grad), .rxd(txd),
	.smp_addr(s0_addr), .smp_req(s0_req), .smp_ack(s0_ack), .smp_dout(m_dout), .smp_doutb(m_doutb),
	.dat_addr(q1_addr), .dat_req(q1_req), .dat_ack(s1_ack), .dat_dout(m_dout), .dat_doutb(m_doutb),
	.out_l(), .out_r(), .dbg_drops(drops), .dbg_stalls(stalls), .dbg_xmiss(xmiss),
	.wave_wr_o(wave_wr), .wave_off_o(wave_off), .wave_data_o(wave_data), .tick_o(),
	.dbg_debtmax(debtmax), .dbg_stallclk(stallclk), .dbg_cens(cens), .dbg_noms(noms),
	.pending_o(pending), .p3we_o(p3we), .p3_o(p3),
	.xrd_o(xrd), .xrd_addr_o(xrd_addr), .xrd_data_o(xrd_data)
);
eo_sndcpu u_scpu (
	.clk(clk), .rst(rst), .dl_we(dl_we && dl_addr[15]), .dl_addr(dl_addr[14:0]), .dl_data(dl_data),
	.latch_wr(latch_wr && grad), .latch_d(latch_d), .txd(txd),
	.dat_addr(c1_addr), .dat_req(c1_req), .dat_ack(s1_ack), .dat_dout(m_dout), .dat_doutb(m_doutb),
	.dbg_xmiss(sxmiss), .xrd_o(sxrd), .xrd_addr_o(sxrd_addr), .xrd_data_o(sxrd_data), .pending_o()
);
wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
sdram #(.RFS_INTERVAL(10'd223)) u_sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(), .SDRAM_CKE(),
	.init(1'b0), .clk(clk), .rd_adj(2'd0),
	.addr0(s0_addr), .wrl0(1'b0), .wrh0(1'b0), .din0(16'd0), .dout0(m_dout), .req0(s0_req), .ack0(s0_ack), .dbl0(1'b1), .dout0b(m_doutb),
	.addr1(s1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0), .dout1(), .req1(s1_req), .ack1(s1_ack), .dbl1(1'b1), .dout1b(),
	.addr2(26'd0), .wrl2(1'b0), .wrh2(1'b0), .din2(16'd0), .din2x(48'd0), .wrx2(6'd0), .dout2(), .req2(1'b0), .ack2(), .dbl2(1'b0), .dout2b()
);
sdram_chip_model_wide u_chip (
	.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
);
endmodule
