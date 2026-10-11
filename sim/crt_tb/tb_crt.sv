// eo_crt on Eolith's raster (rtl/eo_video.sv: 455 x 262 dots, 320 x 240 shown, hsync dots 336-369, vsync lines
// 244-246, 8 clk a dot): where the picture lands, in clk from the HSync rise.
//   ref  : CRT adjust On, H-Size 0 (the module's native-rate path)
//   h+3  : CRT adjust On, H-Size +3, wider (8.75 clk a dot), with H-Position -27: H-Size widens to the right,
//          and the 2,800 clk of picture fit the line only from clk 840 (Seta's bench pairs +10 with -19 likewise)
//   h-4  : CRT adjust On, H-Size -4, narrower (7 clk a dot)
//   pos-8: CRT adjust On, H-Position -8: ref moved 64 clk (8 dots) left
// Every source dot must come out once, in order; the line period stays 455 x 8 = 3,640 clk. (H-Size +10, as
// Seta's bench has it, needs 3,360 clk for the 320 dots: more than this raster's 1,080 clk of blanking allows.)
// After Arcade-Seta_MiSTer's sim/seta_crt_tb.

`timescale 1ns/1ps
`default_nettype none

module crt_probe #(parameter string NAME = "", parameter bit ADJUST = 0,
                   parameter logic [4:0] HSIZE = 5'd0,
                   parameter logic [6:0] HPOS = 7'd0) (
	input  wire         clk,
	input  wire         ce,
	output int          first_c, last_c, npix, hs_period, hs_width,
	output bit          ordered, done
);
	reg  [8:0] hcnt = 9'd0, vcnt = 9'd0;
	always @(posedge clk) if (ce) begin
		hcnt <= (hcnt == 9'd454) ? 9'd0 : hcnt + 9'd1;
		if (hcnt == 9'd454) vcnt <= (vcnt == 9'd261) ? 9'd0 : vcnt + 9'd1;
	end
	wire hb = hcnt >= 9'd320, vb = vcnt >= 9'd240;
	wire hs = hcnt >= 9'd336 && hcnt < 9'd370, vs = vcnt >= 9'd244 && vcnt < 9'd247;

	wire [7:0] r, g, b;
	wire       hs_o, vs_o, hb_o, vb_o, act, ce_o;

	eo_crt u_crt (
		.clk(clk), .ce(ce), .adjust(ADJUST),
		.hsize_idx(HSIZE), .hpos_idx(HPOS), .vshift_idx(6'd0),
		.r_in(hcnt[7:0]), .g_in({7'd0, hcnt[8]}), .b_in(vcnt[7:0]),
		.hs_in(hs), .vs_in(vs), .hb_in(hb), .vb_in(vb),
		.active(act), .ce_out(ce_o),
		.r_out(r), .g_out(g), .b_out(b),
		.hs_out(hs_o), .vs_out(vs_o), .hb_out(hb_o), .vb_out(vb_o)
	);

	int  cyc = 0, hs_rise = 0, prev_rise = 0, lines = 0, expect_px = 0;
	bit  hs_d = 0, hb_d = 1, meas = 0;
	always @(posedge clk) begin
		cyc <= cyc + 1;
		hs_d <= hs_o;
		hb_d <= hb_o;
		if (hs_o & ~hs_d) begin
			prev_rise = hs_rise;
			hs_rise   = cyc;
			lines     = lines + 1;
			if (meas) done <= 1'b1;
			meas = (lines == 2000);     // a picture line in the eighth frame
			if (meas) begin
				hs_period = hs_rise - prev_rise;
				npix = 0; expect_px = 0; ordered = 1;
			end
		end
		if (meas && ~hs_o && hs_d) hs_width = cyc - hs_rise;
		if (meas && ~hb_o && hb_d) first_c = cyc - hs_rise;
		if (meas && hb_o && ~hb_d) last_c = cyc - hs_rise;
		// source dots are hcnt, so each new output dot changes the value
		if (meas && ~hb_o && (npix == 0 || {g[0], r} != 9'(expect_px - 1))) begin
			if ({g[0], r} != 9'(expect_px)) ordered = 0;
			expect_px = {g[0], r} + 1;
			npix = npix + 1;
		end
	end
endmodule

module tb_crt;
	bit clk = 0;
	always #5 clk = ~clk;

	bit [2:0] div = 0;
	always @(posedge clk) div <= div + 3'd1;
	wire ce = (div == 3'd0);

	int f[4], l[4], n[4], hp[4], hw[4];
	bit o[4], d[4];

	crt_probe #(.NAME("ref"), .ADJUST(1)) p_ref (
		.clk(clk), .ce(ce), .first_c(f[0]), .last_c(l[0]), .npix(n[0]),
		.hs_period(hp[0]), .hs_width(hw[0]), .ordered(o[0]), .done(d[0]));
	crt_probe #(.NAME("h+3"), .ADJUST(1), .HSIZE(5'd3), .HPOS(7'd70)) p_hp3 (
		.clk(clk), .ce(ce), .first_c(f[1]), .last_c(l[1]), .npix(n[1]),
		.hs_period(hp[1]), .hs_width(hw[1]), .ordered(o[1]), .done(d[1]));
	crt_probe #(.NAME("h-4"), .ADJUST(1), .HSIZE(5'd28)) p_hm4 (
		.clk(clk), .ce(ce), .first_c(f[3]), .last_c(l[3]), .npix(n[3]),
		.hs_period(hp[3]), .hs_width(hw[3]), .ordered(o[3]), .done(d[3]));
	crt_probe #(.NAME("pos-8"), .ADJUST(1), .HPOS(7'd89)) p_pos (
		.clk(clk), .ce(ce), .first_c(f[2]), .last_c(l[2]), .npix(n[2]),
		.hs_period(hp[2]), .hs_width(hw[2]), .ordered(o[2]), .done(d[2]));

	string names[4] = '{"ref  ", "h+3  ", "pos-8", "h-4  "};
	int fails = 0;
	initial begin
		wait (d[0] && d[1] && d[2] && d[3]);
		for (int i = 0; i < 4; i++)
			$display("%s  active %4d..%4d clk (%4d)  dots %3d  ordered %0d  hsync period %4d width %3d",
			         names[i], f[i], l[i], l[i] - f[i], n[i], o[i], hp[i], hw[i]);
		for (int i = 0; i < 4; i++)
			if (n[i] != 320 || !o[i]) begin $display("FAIL %s: not 320 dots in order", names[i]); fails++; end
		if (f[2] != f[0] - 64 || l[2] != l[0] - 64) begin $display("FAIL pos-8 not ref moved 64 clk left"); fails++; end
		if (l[1] - f[1] <= l[0] - f[0]) begin $display("FAIL h+3 not wider than ref"); fails++; end
		if (l[3] - f[3] >= l[0] - f[0]) begin $display("FAIL h-4 not narrower than ref"); fails++; end
		for (int i = 1; i < 4; i++)
			if (hp[i] != hp[0]) begin $display("FAIL %s line period", names[i]); fails++; end
		if (hp[0] != 3640) begin $display("FAIL line not 455 x 8"); fails++; end
		if (fails) $display("FAIL"); else $display("PASS");
		$finish;
	end
endmodule

`default_nettype wire
