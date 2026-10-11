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
assign FB_FORCE_BLANK = 0;

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

// HDMI rotation for a monitor turned on its side (every set is ROT0): the aspect follows it
wire [1:0] rot_sel    = status[64:63];
wire       rotate_en  = rot_sel != 2'd0;
wire       rotate_ccw = rot_sel == 2'd2;
wire [11:0] base_arx  = rotate_en ? 12'd3 : 12'd4;
wire [11:0] base_ary  = rotate_en ? 12'd4 : 12'd3;

`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif

localparam CONF_STR = {
	"Eolith;;",
	"-;",
	// H5: the HDMI scaler's options, hidden under direct video, where they do nothing
	"H5O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H5O[64:63],Rotation,Off,CW,CCW;",
	"H5O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"H5O[70:69],Crop,Off,216 lines,224 lines;",
	"H5O[75:71],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H5O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[94],CRT Adjust,Off,On;",
	"H3O[99:95],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[106:100],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[112:107],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"O[48:47],Stereo Mix,None,25%,50%,100%;",
	"O[10],Flip Screen,Off,On;",
	// light pens (hidctch3, H2): per player, the left stick aims (Aim: light guns report through it), steps like
	// the d-pad (D-pad), or both, a full deflection stepping and a partial one aiming (Auto: arcade sticks on
	// gamepad encoders); the mouse is off unless given to a player
	"H2-;",
	"H2O[12:11],Crosshair,P1+P2,P1,P2,Off;",
	"H2O[14:13],P1 stick,Aim,Auto,D-pad;",
	"H2O[16:15],P2 stick,Aim,Auto,D-pad;",
	"H2O[18:17],Mouse aims,Off,P1,P2;",
	"-;",
	"DIP;",
	"-;",
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[82],Pause CPU,Off,On;",
	"H1P1O[21:19],MEM3 wait (ROM I/O),0,4,8,12,15,20,24,32;",
	"H1P1O[23:22],MEM0-2 wait (RAM),0,1,2,3;",
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
wire direct_video;
wire  [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;                 // [24] toggles a packet; Y [23:16], X [15:8], their signs [5], [4]; buttons [1:0]
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
	.status_menumask({10'd0, direct_video, 1'b0, ~status[94], ~mod_byte[2], DEBUG_MENU_HIDE, 1'b0}),   // H1 Debug, H2 light pens,
	                                                                                         // H3 CRT adjust, H5 HDMI scaler
	.direct_video(direct_video),

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

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse)
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

// <rom index="1">: byte 0 [1:0] board type: 0 Vega, 1 Gradation 2D, 2 eolith16; [2] light pens (hidctch3);
// bytes 1, 2: the set's memory wait states, clocks per MEM3 and per MEM0-2 access (rtl/eo_busws.sv), absent
// = none (scripts/build_mra.py)
reg [7:0] mod_byte = 8'd0, ws3_mra = 8'd0, ws_mra = 8'd0;
reg [7:0] dsw = 8'hff;                   // the .mra's <switches> (index 254), DSW1 bits 7:0
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd1) begin
		if (ioctl_addr == 27'd0) begin mod_byte <= ioctl_dout; ws3_mra <= 8'd0; ws_mra <= 8'd0; end
		if (ioctl_addr == 27'd1) ws3_mra <= ioctl_dout;
		if (ioctl_addr == 27'd2) ws_mra <= ioctl_dout;
	end
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
// hidctch3: the mouse's left button is the Pen button of the player it aims for (OSD H2)
wire  [1:0] ms_to = mod_byte[2] ? (status[18:17] == 2'd1 ? 2'b01 : status[18:17] == 2'd2 ? 2'b10 : 2'b00) : 2'b00;
wire [31:0] joy0 = joystick_0 | key0 | {27'd0, ms_to[0] & ps2_mouse[0], 4'd0};
wire [31:0] joy1 = joystick_1 | key1 | {27'd0, ms_to[1] & ps2_mouse[0], 4'd0};
wire [15:0] p1p2 = {eo_port(joy1), eo_port(joy0)};
// Active low: COIN1 (P1's coin), COIN2 (P2's), START1, START2, SERVICE1, SERVICE (momentary, as MAME's
// PORT_SERVICE_NO_TOGGLE); eo_main places them per board
wire  [5:0] sys_in = ~{joy0[12] | joy1[12], joy0[11] | joy1[11] | svc_coin[0], joy1[8], joy0[8], joy1[9],
                       joy0[9]};

// hidctch3's light pens (rtl/eo_pens.sv): the d-pad steps a pen, the left stick as the OSD's H2 page says
wire        core_hs, core_vs, core_hb, core_vb;
reg         core_vb_d = 1'b0, ms_tog = 1'b0;
always @(posedge clk_sys) begin core_vb_d <= core_vb; ms_tog <= ps2_mouse[24]; end
wire  [7:0] pen1_x, pen2_x;
wire  [6:0] pen1_y, pen2_y;
eo_pens u_pens (
	.clk(clk_sys), .reset(core_reset), .frame(core_vb && !core_vb_d), .flip(status[10]),
	.ana0(ana0), .ana1(ana1), .dir0({joy0[3], joy0[2], joy0[1], joy0[0]}), .dir1({joy1[3], joy1[2], joy1[1], joy1[0]}),
	.mode0(status[14:13]), .mode1(status[16:15]),
	.ms_ev(ps2_mouse[24] ^ ms_tog), .ms_dx({ps2_mouse[4], ps2_mouse[15:8]}), .ms_dy({ps2_mouse[5], ps2_mouse[23:16]}),
	.ms_to(ms_to),
	.pen1_x(pen1_x), .pen1_y(pen1_y), .pen2_x(pen2_x), .pen2_y(pen2_y)
);

// memory wait states (rtl/eo_busws.sv): the .mra's, or the Debug page's when set; MEM3's clocks per access
function automatic [5:0] ws3_of(input [2:0] s);
	case (s)
		3'd0: ws3_of = 6'd0;  3'd1: ws3_of = 6'd4;  3'd2: ws3_of = 6'd8;  3'd3: ws3_of = 6'd12;
		3'd4: ws3_of = 6'd15; 3'd5: ws3_of = 6'd20; 3'd6: ws3_of = 6'd24; default: ws3_of = 6'd32;
	endcase
endfunction

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

// the fast load's copy: DDR3 through ddram_phy (muxed with the HDMI rotator, VIDEO) into the download port's
// granule mode, the whole image
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;
wire [7:0]  ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
wire [63:0] ldr_DDRAM_DIN;

ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(~pll_locked),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT),
	.DDRAM_ADDR(ldr_DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(ldr_DDRAM_RD),
	.DDRAM_DIN(ldr_DDRAM_DIN), .DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
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
wire        dbg_retire, vbuf, vblank_flag, vbl_rd, dbg_trig_rd;
wire  [1:0] dbg_pen_rd;
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
	.loop_pcb(1'b1),    // looping and the key-off fade, from the same recording (docs/QS1000_FEATURES.md)
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
	// the .mra's wait states unless the Debug page sets its own
	.ws_mem3(status[21:19] != 3'd0 ? ws3_of(status[21:19]) : ws3_mra[5:0]),
	.ws_mem(status[23:22] != 2'd0 ? {4'd0, status[23:22]} : ws_mra[5:0]),
	.ce_pix(ce_pix), .p1p2(p1p2), .system(sys_in), .dsw(dsw),
	.flip(status[10]),
	.pens(mod_byte[2]), .pen1_x(pen1_x), .pen1_y(pen1_y), .pen2_x(pen2_x), .pen2_y(pen2_y),
	.xh_en(status[12:11] == 2'd0 ? 2'b11 : status[12:11] == 2'd1 ? 2'b01 : status[12:11] == 2'd2 ? 2'b10 : 2'b00),
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
	.vbuf_out(vbuf), .vblank_flag(vblank_flag), .vbl_rd(vbl_rd), .dbg_pen_rd(dbg_pen_rd), .dbg_trig_rd(dbg_trig_rd)
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
// Instance P: hidctch3's pens, the inputs and what the game reads (field table in scripts/read_issp.tcl). F's
// source bit 0 clears the counts.
reg  [15:0] pp_rd1 = 16'd0, pp_rd2 = 16'd0, pp_trig = 16'd0;
reg  [7:0]  pp_press = 8'd0, pp_lx = 8'd0;
reg  [6:0]  pp_ly = 7'd0;
reg         pp_b1_d = 1'b0;
always @(posedge clk_sys) begin
	pp_b1_d <= joy0[4];
	if (issp_src[0]) begin
		pp_rd1 <= 16'd0; pp_rd2 <= 16'd0; pp_trig <= 16'd0; pp_press <= 8'd0;
	end else begin
		if (dbg_pen_rd[0]) begin pp_rd1 <= pp_rd1 + 16'd1; pp_lx <= pen1_x; pp_ly <= pen1_y; end
		if (dbg_pen_rd[1]) pp_rd2 <= pp_rd2 + 16'd1;
		if (dbg_trig_rd) pp_trig <= pp_trig + 16'd1;
		if (joy0[4] && !pp_b1_d) pp_press <= pp_press + 8'd1;
	end
end
issp_probe #(.INSTANCE_ID("P"), .PROBE_W(128), .SOURCE_W(8)) u_issp_p (
	.clk(clk_sys),
	.probe({pp_rd2, pp_press, pp_ly, pp_lx, pp_trig, pp_rd1, mod_byte[2], ps2_mouse[1:0], joy0[7:0], ana0,
	        pen2_y, pen2_x, pen1_y, pen1_x}),
	.source()
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

// CRT adjust (rtl/video/eo_crt.sv, crt_adjust.sv vendored): H-Size, H-Position and V-Shift through a line buffer,
// the syncs native; off under a forced scandoubler
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb, crt_on, crt_ce;
eo_crt u_crt (
	.clk(clk_sys), .ce(ce_pix),
	.adjust(status[94] & ~forced_scandoubler),
	.hsize_idx(status[99:95]), .hpos_idx(status[106:100]), .vshift_idx(status[112:107]),
	.r_in(core_r), .g_in(core_g), .b_in(core_b),
	.hs_in(core_hs), .vs_in(core_vs), .hb_in(core_hb), .vb_in(core_vb),
	.active(crt_on), .ce_out(crt_ce),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

arcade_video #(.WIDTH(320), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_ce : ce_pix),

	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : {core_r, core_g, core_b}),
	.HBlank(crt_on ? crt_hb : core_hb),
	.VBlank(crt_on ? crt_vb : core_vb),
	.HSync(crt_on ? crt_hs : core_hs),
	.VSync(crt_on ? crt_vs : core_vs),

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
	.ARX((!ar) ? base_arx : (ar - 1'd1)),
	.ARY((!ar) ? base_ary : 12'd0),
	.CROP_SIZE(status[70:69] == 2'd1 ? 12'd216 : status[70:69] == 2'd2 ? 12'd224 : 12'd0),
	.CROP_OFF(status[75:71]),
	.SCALE(status[68:66])
);

// HDMI rotation: screen_rotate_two writes the output into DDR3 for the HPS framebuffer; the analog output keeps
// the native raster. Its flip is not used: Flip Screen goes through eo_video. While the fast load copies, the
// copy has DDR3 and the rotator sees it busy (it has no reset and counts a write as taken whenever BUSY is low:
// Arcade-Vamphalf_MiSTer, from Arcade-Seta_MiSTer).
wire        rot_DDRAM_CLK, rot_DDRAM_WE, rot_DDRAM_RD;
wire [7:0]  rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;
assign DDRAM_CLK      = ldr_active ? clk_sys            : rot_DDRAM_CLK;
assign DDRAM_BURSTCNT = ldr_active ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_active ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_active ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_active ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_active ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_active ? ldr_DDRAM_RD       : rot_DDRAM_RD;
screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(1'b0),
	.two_screen(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_active),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR(rot_DDRAM_ADDR),
	.DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE),
	.DDRAM_WE(rot_DDRAM_WE),
	.DDRAM_RD(rot_DDRAM_RD)
);

endmodule
