// System bench top: the main board (eo_main) on the real SDRAM controller and a command-decoding chip
// model, with the clock enables Eolith.sv makes. main.cpp loads the download image into the chip
// model's array and drives the inputs.

module tb_sys (
	input             clk,
	input             prst,
	input             rst,
	input      [1:0]  board,
	input             pause,
	input      [15:0] p1p2,
	input      [5:0]  system,
	input      [7:0]  dsw,
	input             pens,             // hidctch3's light pens, at pen1_x/y
	input      [7:0]  pen1_x,
	input      [6:0]  pen1_y,

	output            ce_pix,
	output     [7:0]  vid_r,
	output     [7:0]  vid_g,
	output     [7:0]  vid_b,
	output            hblank,
	output            vblank,
	output            vblank_flag,
	output            vbuf,

	output            retire,
	output     [31:0] retire_pc,
	output     [31:0] st_imiss,
	output     [31:0] st_dmiss,
	output     [127:0] perf_f,          // rtl/debug/eo_perf.sv, as the stp revision's probes
	output     [127:0] perf_c,
	output            snd_latch_wr,
	output     [7:0]  snd_latch,

	input             snd_dl_we,        // the programs into the sound board while rst is held
	input      [15:0] snd_dl_addr,      // bit 15: the Gradation 2D sound CPU's
	input      [7:0]  snd_dl_data,
	output            snd_wave_wr,
	output     [4:0]  snd_wave_off,
	output     [7:0]  snd_wave_data,
	output            snd_tick,
	output     [15:0] snd_xmiss,
	output signed [15:0] snd_l,
	output signed [15:0] snd_r
);

// clk_sys 630/11 MHz: the dot 1 in 8; the CPU's 55 MHz timer tick 121 in 126
reg [2:0] pc8 = 3'd0;
always @(posedge clk) pc8 <= pc8 + 3'd1;
assign ce_pix = pc8 == 3'd0;
reg [6:0] tk = 7'd0;
always @(posedge clk) tk <= (tk == 7'd125) ? 7'd0 : tk + 7'd1;
wire cpu_tick = tk < 7'd121;

wire [26:1] m2_addr;
wire        m2_wrl, m2_wrh, m2_dbl, m2_req, m2_ack;
wire [15:0] m2_din;
wire [47:0] m2_dinx;
wire  [5:0] m2_wrx;
wire [63:0] m2_dout, m2_doutb;
wire [26:1] s0_addr, s1_addr, q0_addr, q1_addr, c1_addr, k0_addr;
wire        s0_req, s0_ack, s1_req, s1_ack, q0_req, q1_req, c1_req, k0_req;
wire        grad = board == 2'd1, e16 = board == 2'd2;
wire        snd_txd;
wire        oki_wr;
wire [7:0]  oki_din, oki_dout;
assign s0_addr = e16 ? k0_addr : q0_addr;
assign s0_req  = e16 ? k0_req : q0_req;
assign s1_addr = grad ? c1_addr : q1_addr;
assign s1_req  = grad ? c1_req : q1_req;

eo_main u_main (
	.clk(clk), .prst(prst), .rst(rst), .board(board), .pause(pause), .cpu_tick(cpu_tick), .ce_pix(ce_pix),
	.p1p2(p1p2), .system(system), .dsw(dsw),
	.flip(1'b0), .pens(pens), .pen1_x(pen1_x), .pen1_y(pen1_y), .pen2_x(8'd0), .pen2_y(7'd0),
	.r(vid_r), .g(vid_g), .b(vid_b), .hblank(hblank), .vblank(vblank), .hsync(), .vsync(),
	.snd_latch(snd_latch), .snd_latch_wr(snd_latch_wr),
	.oki_wr(oki_wr), .oki_din(oki_din), .oki_dout(oki_dout),
	.ee_load_we(1'b0), .ee_load_addr(11'd0), .ee_load_data(8'd0), .ee_rd_addr(11'd0), .ee_rd_data(), .ee_written(),
	.dl_req(1'b0), .dl_addr(27'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_g(1'b0), .dl_gdata(64'd0), .dl_busy(),
	.mem_addr(m2_addr), .mem_wrl(m2_wrl), .mem_wrh(m2_wrh), .mem_din(m2_din), .mem_dinx(m2_dinx),
	.mem_wrx(m2_wrx), .mem_dbl(m2_dbl), .mem_req(m2_req), .mem_ack(m2_ack),
	.mem_dout(m2_dout), .mem_doutb(m2_doutb),
	.retire(retire), .retire_pc(retire_pc), .retire_npc(), .retire_sr(),
	.st_imiss(st_imiss), .st_dmiss(st_dmiss), .vbuf_out(vbuf), .vblank_flag(vblank_flag), .vbl_rd(vbl_rd)
);
wire vbl_rd;
eo_perf u_perf (
	.clk(clk), .clear(1'b0), .vblank_flag(vblank_flag), .vbuf(vbuf), .vbl_rd(vbl_rd),
	.retire(retire), .st_imiss(st_imiss), .st_dmiss(st_dmiss), .probe_f(perf_f), .probe_c(perf_c)
);

eo_qs1000 u_snd (
	.clk(clk), .rst(rst),
	.dl_we(snd_dl_we && !snd_dl_addr[15]), .dl_addr(snd_dl_addr[14:0]), .dl_data(snd_dl_data),
	.latch_wr(snd_latch_wr && !grad), .latch_d(snd_latch), .bal_pcb(1'b0),   // MAME's balance: the benches' reference
	.grad(grad), .rxd(snd_txd),
	.smp_addr(q0_addr), .smp_req(q0_req), .smp_ack(s0_ack), .smp_dout(m2_dout), .smp_doutb(m2_doutb),
	.dat_addr(q1_addr), .dat_req(q1_req), .dat_ack(s1_ack), .dat_dout(m2_dout), .dat_doutb(m2_doutb),
	.out_l(snd_l), .out_r(snd_r),
	.dbg_drops(), .dbg_stalls(), .dbg_xmiss(snd_xmiss),
	.wave_wr_o(snd_wave_wr), .wave_off_o(snd_wave_off), .wave_data_o(snd_wave_data), .tick_o(snd_tick),
	.pending_o(), .p3we_o(), .p3_o(), .xrd_o(), .xrd_addr_o(), .xrd_data_o()
);

eo_oki #(.ROM_BASE(27'h2100000)) u_oki (
	.clk(clk), .rst(rst), .dl(1'b0),
	.wr(oki_wr), .din(oki_din), .dout(oki_dout),
	.sd_addr(k0_addr), .sd_req(k0_req), .sd_ack(s0_ack), .sd_dout(m2_dout),
	.out()
);

eo_sndcpu u_sndcpu (
	.clk(clk), .rst(rst),
	.dl_we(snd_dl_we && snd_dl_addr[15]), .dl_addr(snd_dl_addr[14:0]), .dl_data(snd_dl_data),
	.latch_wr(snd_latch_wr && grad), .latch_d(snd_latch), .txd(snd_txd),
	.dat_addr(c1_addr), .dat_req(c1_req), .dat_ack(s1_ack), .dat_dout(m2_dout), .dat_doutb(m2_doutb),
	.dbg_xmiss(), .xrd_o(), .xrd_addr_o(), .xrd_data_o(), .pending_o()
);

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

// a chip needs a refresh every 7.8125 us, 447 clocks; the two chips alternate
sdram #(.RFS_INTERVAL(10'd223)) u_sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
	.init(1'b0), .clk(clk), .rd_adj(2'd0),
	.addr0(s0_addr), .wrl0(1'b0), .wrh0(1'b0), .din0(16'd0), .dout0(), .req0(s0_req), .ack0(s0_ack), .dbl0(1'b1), .dout0b(),
	.addr1(s1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0), .dout1(), .req1(s1_req), .ack1(s1_ack), .dbl1(1'b1), .dout1b(),
	.addr2(m2_addr), .wrl2(m2_wrl), .wrh2(m2_wrh), .din2(m2_din), .din2x(m2_dinx), .wrx2(m2_wrx),
	.dout2(m2_dout), .req2(m2_req), .ack2(m2_ack), .dbl2(m2_dbl), .dout2b(m2_doutb)
);

sdram_chip_model_wide u_chip (
	.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
);

endmodule
