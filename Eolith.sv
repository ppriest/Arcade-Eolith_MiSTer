// SPDX-License-Identifier: GPL-3.0-or-later
//
// Eolith (MAME eolith/vegaeo.cpp so far): the Hyperstone E1 boards of Eolith; sets in
// scripts/build_mra.py SETS.
//
// Framework glue: hps_io, PLL, resets, the ROM download, inputs, the AT28C16's .nvm, and the video
// output. The board is rtl/eo_main.sv (CPU, memory, I/O, frame buffer).
//
// Clocks (rtl/pll): clk_sys 57.272727 MHz (630/11, 8x the 7.15909 MHz dot) for everything, SDRAM
// included; SDRAM_CLK the same lagging by T - 2.98 ns: 73 steps of the 630 MHz VCO (rtl/pll/pll_0002.v).

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

assign AUDIO_S   = 1;
assign AUDIO_MIX = status[48:47];
assign AUDIO_L   = e16 ? oki_out : snd_l;
assign AUDIO_R   = e16 ? oki_out : snd_r;

//////////////////////////////////////////////////////////////////

`include "rtl/eo_sdram_map.svh"
`include "build_id.v"

wire [1:0] ar = status[122:121];

`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif

localparam CONF_STR = {
	"Eolith;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[48:47],Stereo Mix,None,25%,50%,100%;",
	"O[10],Flip Screen,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[82],Pause CPU,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// entry i is joystick bit 4 + i, matching the .mra <buttons>
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Pause,Service Coin,Service Mode;",
	"jn,A,B,X,Y,Start,Select,L,R;",
	"v,0;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1;
wire [15:0] ana0, ana1;                 // analog -127..127: Y [15:8], X [7:0]

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;
wire  [7:0] ioctl_din;
wire        ioctl_upload;
reg         nvram_save = 1'b0;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, DEBUG_MENU_HIDE, 1'b0}),   // H1 Debug

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(ana0),
	.joystick_l_analog_1(ana1),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	// the .mra's <nvram index="2" size="2048"/>: the AT28C16
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_sdram_shifted, pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram_shifted),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram_shifted;

// the dot: 1 in 8; the CPU's 55 MHz timer tick: 121 in 126
reg [2:0] pc8 = 3'd0;
always @(posedge clk_sys) pc8 <= pc8 + 3'd1;
wire ce_pix = pc8 == 3'd0;
reg [6:0] tk = 7'd0;
always @(posedge clk_sys) tk <= (tk == 7'd125) ? 7'd0 : tk + 7'd1;
wire cpu_tick = tk < 7'd121;

///////////////////////   RESET   ////////////////////////////////

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// The game is held until a ROM is in SDRAM (by either path) and while the fast load copies it; the
// memory path is not (LESSONS_LEARNED, "Never hold the memory path in the core reset").
wire ldr_active;
reg  rom_loaded = 1'b0, dl_seen = 1'b0, ldr_active_d = 1'b0;
always @(posedge clk_sys) begin
	ldr_active_d <= ldr_active;
	if (ioctl_wr && ioctl_index == 16'd0) dl_seen <= 1'b1;
	if (dl_seen && !ioctl_download)       rom_loaded <= 1'b1;
	if (ldr_active_d && !ldr_active)      rom_loaded <= 1'b1;   // the copy finished
end
wire core_reset = reset | ioctl_download | ~rom_loaded | ldr_active;

// Fast ROM load (rtl/memory/vh_rom_loader.sv; the trigger as Arcade-Vamphalf_MiSTer's). With
// address="0x30000000" on the .mra's index-0 ROM the HPS puts the image in DDR3 and the download has no
// ioctl_wr; the copy starts on the next reset release, once per index-0 download. A download that
// streams bytes is a byte-path load and is not copied over.
reg  dl0_d = 1'b0, dl0_seen = 1'b0, dl_seen_wr = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0, ldr_done = 1'b0;
wire dl0 = ioctl_download && ioctl_index == 16'd0;
always @(posedge clk_sys) begin
	ldr_start <= 1'b0;
	dl0_d <= dl0;
	if (dl0 && !dl0_d) begin
		dl0_seen   <= 1'b1;
		dl_seen_wr <= 1'b0;
		ldr_done   <= 1'b0;
	end else if (dl0 && ioctl_wr) dl_seen_wr <= 1'b1;
	if (reset) ldr_pending <= 1'b1;
	else if (ldr_pending && !ioctl_download && !ldr_active) begin
		ldr_pending <= 1'b0;
		if (dl0_seen && !dl_seen_wr && !ldr_done) begin
			ldr_start <= 1'b1;
			ldr_done  <= 1'b1;
		end
	end
end

///////////////////   .mra: mod byte   ///////////////////////////

// <rom index="1">: [1:0] board type: 0 Vega, 1 Gradation 2D, 2 eolith16; [2] light pens (hidctch3)
// (scripts/build_mra.py)
reg [7:0] mod_byte = 8'd0;
reg [7:0] dsw = 8'hff;                   // the .mra's <switches> (index 254), DSW1 bits 7:0
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd1 && !ioctl_addr[0]) mod_byte <= ioctl_dout;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd254 && ioctl_addr == 27'd0) dsw <= ioctl_dout;

///////////////////////   INPUTS   ///////////////////////////////

// MiSTer joystick: 0 R, 1 L, 2 D, 3 U, buttons 1-4 at 4-7, Start 8, Coin 9, Pause 10, Service Coin 11,
// Service Mode 12. A byte per player, active low, as MAME's P1_P2 (Vega) and IN0 bits 31:16
// (Gradation 2D): U D L R, buttons 1-3.
function automatic [7:0] eo_port(input [31:0] j);
	eo_port = ~{1'b0, j[6], j[5], j[4], j[0], j[1], j[2], j[3]};
endfunction
wire [31:0] key0, key1;
wire  [1:0] svc_coin;
mame_keys #(.BUTTONS(4), .START(8), .COIN(9), .PAUSE(10), .SERVICE(12)) u_keys (
	.clk(clk_sys), .ps2_key(ps2_key), .key0(key0), .key1(key1), .svc_coin(svc_coin)
);
wire [31:0] joy0 = joystick_0 | key0;
wire [31:0] joy1 = joystick_1 | key1;
wire [15:0] p1p2 = {eo_port(joy1), eo_port(joy0)};
// Active low: COIN1 (P1's coin), COIN2 (P2's), START1, START2, SERVICE1, SERVICE (momentary, as MAME's
// PORT_SERVICE_NO_TOGGLE); eo_main places them per board
wire  [5:0] sys_in = ~{joy0[12] | joy1[12], joy0[11] | joy1[11] | svc_coin[0], joy1[8], joy0[8], joy1[9],
                       joy0[9]};

// hidctch3's light pens from the left analog sticks: X to 0-159 (v * 5 / 8), Y to 0-119 (v * 15 / 32), v the
// stick offset to 0-255; shifts and adds
function automatic [7:0] pen_x(input [7:0] a);
	reg [10:0] v; begin v = {3'd0, a ^ 8'h80}; pen_x = 8'(((v << 2) + v) >> 3); end
endfunction
function automatic [6:0] pen_y(input [7:0] a);
	reg [12:0] v; begin v = {5'd0, a ^ 8'h80}; pen_y = 7'(((v << 4) - v) >> 5); end
endfunction

// flipped, the stick moves the pen the way the turned picture shows it
function automatic [7:0] pen_fx(input [7:0] x); pen_fx = status[10] ? 8'd159 - x : x; endfunction
function automatic [6:0] pen_fy(input [6:0] y); pen_fy = status[10] ? 7'd119 - y : y; endfunction

// Pause: joystick bit 10 (or P) toggles; the Debug page's Pause CPU is ORed in
wire pause_btn = joy0[10] | joy1[10];
reg  pause_btn_d = 1'b0, pause_toggle = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                         pause_toggle <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause_toggle <= ~pause_toggle;
end
wire pause_cpu = pause_toggle | status[82];

///////////////////////   NVRAM   ////////////////////////////////

// The .nvm (index 2) loads the AT28C16 while the core is held; a save is requested a second after the
// game's last write.
wire       ee_load_we = ioctl_download && ioctl_wr && ioctl_index == 16'd2;
wire [7:0] ee_rd_data;
wire       ee_written;
assign ioctl_din = ee_rd_data;
reg  [25:0] ee_quiet = 26'd0;
reg         ee_dirty = 1'b0;
always @(posedge clk_sys) begin
	nvram_save <= 1'b0;
	if (ee_written) begin
		ee_dirty <= 1'b1;
		ee_quiet <= 26'd0;
	end else if (ee_dirty) begin
		ee_quiet <= ee_quiet + 26'd1;
		if (ee_quiet == 26'd57_272_727) begin
			ee_dirty   <= 1'b0;
			nvram_save <= 1'b1;
		end
	end
end

///////////////////////   THE BOARD   ////////////////////////////

wire        dl_req, dl_we16, dl_busy;
wire [26:0] dl_addr;
wire [15:0] dl_data;
wire        bdl_req;
wire [26:0] bdl_addr;
wire        ldl_req;
wire [26:0] ldl_addr;
wire [63:0] ldl_gdata;

sdram_download u_dl (
	.clk(clk_sys), .reset(~pll_locked),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.dl_req(bdl_req), .dl_addr(bdl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(ldr_active ? 1'b0 : dl_busy)
);

// the fast load's copy: DDR3 through ddram_phy into the download port's granule mode, the whole image
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;

assign DDRAM_CLK = clk_sys;
ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(~pll_locked),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);

// the granules replayed byte by byte: the 64 KB from SD_SNDPRG, the QS1000's program (the first 32 KB of
// bgm.u84 on Vega) and the Gradation 2D sound CPU's (block RAM)
wire [27:0] ldr_tap_addr;
wire        ldr_tap = ldr_tap_addr[26:16] == SD_SNDPRG[26:16];
wire        ldr_tb_wr;
wire [26:0] ldr_tb_addr;
wire  [7:0] ldr_tb_dout;

vh_rom_loader u_ldr (
	.clk(clk_sys), .reset(~pll_locked),
	// the mod byte comes first
	.length(mod_byte[1:0] == 2'd1 ? {1'b0, SD_IMAGE_END_G} : mod_byte[1:0] == 2'd2 ? {1'b0, SD_IMAGE_END_K} :
	        {1'b0, SD_IMAGE_END}),
	.start(ldr_start), .busy(ldr_active),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
	.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.dl_req(ldl_req), .dl_addr(ldl_addr), .dl_gdata(ldl_gdata), .dl_busy(ldr_active ? dl_busy : 1'b0),
	.tap_addr(ldr_tap_addr), .tap_want(ldr_tap),
	.tb_wr(ldr_tb_wr), .tb_addr(ldr_tb_addr), .tb_dout(ldr_tb_dout)
);

assign dl_req  = ldr_active ? ldl_req  : bdl_req;
assign dl_addr = ldr_active ? ldl_addr : bdl_addr;

wire [26:1] m2_addr;
wire        m2_wrl, m2_wrh, m2_dbl, m2_req, m2_ack;
wire [15:0] m2_din;
wire [47:0] m2_dinx;
wire  [5:0] m2_wrx;
wire [63:0] m_dout, m_doutb;

wire [7:0]  core_r, core_g, core_b;
wire        core_hs, core_vs, core_hb, core_vb;
wire        dbg_retire, vbuf, vblank_flag, vbl_rd;
wire [31:0] dbg_pc, dbg_imiss, dbg_dmiss;
wire [7:0]  snd_latch;
wire        snd_latch_wr;

// The sound board: the QS1000 (rtl/qs1000/eo_qs1000.sv), and on the Gradation 2D the sound CPU in front of
// it (rtl/qs1000/eo_sndcpu.sv), which then has SDRAM port 1. The programs are caught on their way to
// SDRAM: the HPS's byte stream, or the fast load's replay of those granules.
wire        lb_wr   = ldr_active ? ldr_tb_wr : ioctl_download && ioctl_wr && ioctl_index == 16'd0;
wire [26:0] lb_addr = ldr_active ? ldr_tb_addr : ioctl_addr;
wire  [7:0] lb_dout = ldr_active ? ldr_tb_dout : ioctl_dout;
wire [26:1] s0_addr, s1_addr, q0_addr, q1_addr, c1_addr, k0_addr;
wire        s0_req, s0_ack, s1_req, s1_ack, q0_req, q1_req, c1_req, k0_req;
wire signed [15:0] snd_l, snd_r, oki_out;
wire        grad = mod_byte[1:0] == 2'd1, e16 = mod_byte[1:0] == 2'd2;
wire        snd_txd;
wire        oki_wr;
wire [7:0]  oki_din, oki_dout;
assign s0_addr = e16 ? k0_addr : q0_addr;
assign s0_req  = e16 ? k0_req : q0_req;
assign s1_addr = grad ? c1_addr : q1_addr;
assign s1_req  = grad ? c1_req : q1_req;

eo_qs1000 #(.SNDPRG_BASE(SD_SNDPRG), .SMP_BASE(SD_SMP), .SMP_LINES(20'(({1'b0, SD_IMAGE_END} - {1'b0, SD_SMP}) >> 4))) u_snd (
	.clk(clk_sys), .rst(core_reset),
	.dl_we(lb_wr && lb_addr[26:15] == SD_SNDPRG[26:15]), .dl_addr(lb_addr[14:0]), .dl_data(lb_dout),
	.latch_wr(snd_latch_wr && !grad), .latch_d(snd_latch),
	.bal_pcb(1'b1),     // the balance of Vamphalf's QS1000 PCB recording (docs/MAME_KLUDGES.md, Sound)
	.grad(grad), .rxd(snd_txd),
	.smp_addr(q0_addr), .smp_req(q0_req), .smp_ack(s0_ack), .smp_dout(m_dout), .smp_doutb(m_doutb),
	.dat_addr(q1_addr), .dat_req(q1_req), .dat_ack(s1_ack), .dat_dout(m_dout), .dat_doutb(m_doutb),
	.out_l(snd_l), .out_r(snd_r),
	.dbg_drops(), .dbg_stalls(), .dbg_xmiss(),
	.wave_wr_o(), .wave_off_o(), .wave_data_o(), .tick_o(), .pending_o(), .p3we_o(), .p3_o(), .xrd_o(), .xrd_addr_o(), .xrd_data_o()
);

// eolith16's M6295 (rtl/sound/eo_oki.sv), on SDRAM port 0 in the QS1000's place
eo_oki #(.ROM_BASE(SD_SMP)) u_oki (
	.clk(clk_sys), .rst(core_reset), .dl(ioctl_download || ldr_active),
	.wr(oki_wr), .din(oki_din), .dout(oki_dout),
	.sd_addr(k0_addr), .sd_req(k0_req), .sd_ack(s0_ack), .sd_dout(m_dout),
	.out(oki_out)
);

eo_sndcpu #(.DATA_BASE(SD_SNDDATA)) u_sndcpu (
	.clk(clk_sys), .rst(core_reset),
	.dl_we(lb_wr && lb_addr[26:15] == SD_SNDCPU[26:15]), .dl_addr(lb_addr[14:0]), .dl_data(lb_dout),
	.latch_wr(snd_latch_wr && grad), .latch_d(snd_latch), .txd(snd_txd),
	.dat_addr(c1_addr), .dat_req(c1_req), .dat_ack(s1_ack), .dat_dout(m_dout), .dat_doutb(m_doutb),
	.dbg_xmiss(), .xrd_o(), .xrd_addr_o(), .xrd_data_o(), .pending_o()
);

eo_main u_main (
	.clk(clk_sys), .prst(~pll_locked), .rst(core_reset), .board(mod_byte[1:0]), .pause(pause_cpu), .cpu_tick(cpu_tick),
	.ce_pix(ce_pix), .p1p2(p1p2), .system(sys_in), .dsw(dsw),
	.flip(status[10]),
	.pens(mod_byte[2]), .pen1_x(pen_fx(pen_x(ana0[7:0]))), .pen1_y(pen_fy(pen_y(ana0[15:8]))),
	.pen2_x(pen_fx(pen_x(ana1[7:0]))), .pen2_y(pen_fy(pen_y(ana1[15:8]))),
	.r(core_r), .g(core_g), .b(core_b), .hblank(core_hb), .vblank(core_vb), .hsync(core_hs), .vsync(core_vs),
	.snd_latch(snd_latch), .snd_latch_wr(snd_latch_wr),
	.oki_wr(oki_wr), .oki_din(oki_din), .oki_dout(oki_dout),
	.ee_load_we(ee_load_we), .ee_load_addr(ioctl_addr[10:0]), .ee_load_data(ioctl_dout),
	.ee_rd_addr(ioctl_addr[10:0]), .ee_rd_data(ee_rd_data), .ee_written(ee_written),
	.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_g(ldr_active), .dl_gdata(ldl_gdata),
	.dl_busy(dl_busy),
	.mem_addr(m2_addr), .mem_wrl(m2_wrl), .mem_wrh(m2_wrh), .mem_din(m2_din), .mem_dinx(m2_dinx),
	.mem_wrx(m2_wrx), .mem_dbl(m2_dbl), .mem_req(m2_req), .mem_ack(m2_ack), .mem_dout(m_dout), .mem_doutb(m_doutb),
	.retire(dbg_retire), .retire_pc(dbg_pc), .retire_npc(), .retire_sr(), .st_imiss(dbg_imiss), .st_dmiss(dbg_dmiss),
	.vbuf_out(vbuf), .vblank_flag(vblank_flag), .vbl_rd(vbl_rd)
);

`ifdef DEBUG_ISSP
// Frame-time probes (rtl/debug/eo_perf.sv; field tables in scripts/read_issp.tcl). Instance F: frames and
// frame-buffer flips; instance C: the CPU's spin on vblank, instructions and cache misses per frame. F's
// source bit 0 clears both.
wire [127:0] perf_f, perf_c;
wire [7:0]   issp_src;
eo_perf u_perf (
	.clk(clk_sys), .clear(issp_src[0]), .vblank_flag(vblank_flag), .vbuf(vbuf), .vbl_rd(vbl_rd),
	.retire(dbg_retire), .st_imiss(dbg_imiss), .st_dmiss(dbg_dmiss),
	.probe_f(perf_f), .probe_c(perf_c)
);
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_issp_f (
	.clk(clk_sys), .probe({pll_locked, core_reset, mod_byte[1:0], perf_f[123:0]}), .source(issp_src)
);
issp_probe #(.INSTANCE_ID("C"), .PROBE_W(128), .SOURCE_W(8)) u_issp_c (
	.clk(clk_sys), .probe(perf_c), .source()
);
`endif

// a chip needs a refresh every 7.8125 us, 447 clocks; refreshes alternate between the 128 MB module's chips
sdram #(.RFS_INTERVAL(10'd223)) u_sdram (
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(), .SDRAM_CKE(SDRAM_CKE),
	.init(~pll_locked), .clk(clk_sys), .rd_adj(2'd0),
	.addr0(s0_addr), .wrl0(1'b0), .wrh0(1'b0), .din0(16'd0), .dout0(), .req0(s0_req), .ack0(s0_ack), .dbl0(1'b1), .dout0b(),
	.addr1(s1_addr), .wrl1(1'b0), .wrh1(1'b0), .din1(16'd0), .dout1(), .req1(s1_req), .ack1(s1_ack), .dbl1(1'b1), .dout1b(),
	.addr2(m2_addr), .wrl2(m2_wrl), .wrh2(m2_wrh), .din2(m2_din), .din2x(m2_dinx), .wrx2(m2_wrx),
	.dout2(m_dout), .req2(m2_req), .ack2(m2_ack), .dbl2(m2_dbl), .dout2b(m_doutb)
);

///////////////////////   VIDEO   ////////////////////////////////

wire vga_de_raw;

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(ce_pix),

	.RGB_in({core_r, core_g, core_b}),
	.HBlank(core_hb),
	.VBlank(core_vb),
	.HSync(core_hs),
	.VSync(core_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[68:66])
);

endmodule
