// Frame-time probes (the Eolith_stp revision): is the CPU finishing a frame's work, and is the game flipping
// its frame buffer at its usual rate? Read over ISSP (Eolith.sv, scripts/read_issp.tcl).
//
// The games take no interrupts; when a frame's work is done they spin reading the port that carries the
// vblank bit (vbl_rd: Vega 0xfcc00000, Gradation 2D 0xfc000000, eolith16 0xffea0000). A frame is from one
// vblank_flag rise (line 240) to the next. Per frame:
//   wait      clocks spent in that spin: the gap before each status read, when it is under 512 clocks (a
//             tight loop; a lone read for the inputs counts its own short gap and nothing more)
//   polls     status reads
//   instr     instructions retired
//   imiss, dmiss  cache misses (eo_cpumem's counters, per frame)
// and, since the last clear:
//   wait_min  the least wait of any frame: the busiest frame's slack
//   busy      frames whose wait was under 4,096 clocks (0.4% of a frame): the CPU worked the whole frame
//   frames, flips    frame-buffer flips (vbuf toggles)
//   gap1..gap4p      flips 1, 2, 3, 4 or more frames after the previous one; max_gap, last_gap
// A game that draws at 60 fps shows gap1 only; one at 30 fps gap2 only; slowdown shows as the next bucket
// up, with busy frames and wait_min near 0.
// `clear` zeroes the counters; the core reset does not, so a reading spans resets.

`default_nettype none

module eo_perf (
	input  wire        clk,
	input  wire        clear,
	input  wire        vblank_flag,
	input  wire        vbuf,
	input  wire        vbl_rd,
	input  wire        retire,
	input  wire [31:0] st_imiss,
	input  wire [31:0] st_dmiss,

	output wire [127:0] probe_f,      // flips (instance F)
	output wire [127:0] probe_c       // CPU (instance C)
);

reg        vb_l = 1'b0, vbuf_l = 1'b0;
wire       frame = vblank_flag && !vb_l;
wire       flip  = vbuf != vbuf_l;

reg [15:0] frames = 0, flips = 0, gap1 = 0, gap2 = 0, gap3 = 0, gap4p = 0, busy = 0;
reg [7:0]  gap = 0, max_gap = 0, last_gap = 0;
reg [19:0] wait_acc = 0, wait_last = 0, wait_min = 20'hfffff;
reg [8:0]  since = 0;
reg [15:0] polls_acc = 0, polls_last = 0;
reg [23:0] instr_acc = 0, instr_last = 0;
reg [31:0] im0 = 0, dm0 = 0;
reg [15:0] imiss_last = 0, dmiss_last = 0;

always @(posedge clk) begin
	vb_l   <= vblank_flag;
	vbuf_l <= vbuf;
	if (since != 9'h1ff) since <= since + 9'd1;
	if (retire) instr_acc <= instr_acc + 24'd1;
	if (vbl_rd) begin
		since <= 9'd0;
		if (since != 9'h1ff) wait_acc <= wait_acc + {11'd0, since} + 20'd1;
		polls_acc <= polls_acc + 16'd1;
	end
	if (frame) begin
		frames     <= frames + 16'd1;
		wait_last  <= wait_acc;
		if (wait_acc < wait_min) wait_min <= wait_acc;
		if (wait_acc < 20'd4096) busy <= busy + 16'd1;
		polls_last <= polls_acc;
		instr_last <= instr_acc;
		imiss_last <= 16'(st_imiss - im0);
		dmiss_last <= 16'(st_dmiss - dm0);
		im0 <= st_imiss;
		dm0 <= st_dmiss;
		wait_acc  <= 20'd0;
		polls_acc <= 16'd0;
		instr_acc <= 24'd0;
		if (gap != 8'hff) gap <= gap + 8'd1;
	end
	if (flip) begin
		flips    <= flips + 16'd1;
		last_gap <= gap;
		if (gap > max_gap) max_gap <= gap;
		case (gap)
			8'd0, 8'd1: gap1 <= gap1 + 16'd1;   // 0: a second flip in the same frame
			8'd2:       gap2 <= gap2 + 16'd1;
			8'd3:       gap3 <= gap3 + 16'd1;
			default:    gap4p <= gap4p + 16'd1;
		endcase
		gap <= 8'd0;
	end
	if (clear) begin
		frames <= 0; flips <= 0; gap1 <= 0; gap2 <= 0; gap3 <= 0; gap4p <= 0; busy <= 0;
		max_gap <= 0; wait_min <= 20'hfffff;
	end
end

assign probe_f = {16'd0, last_gap, max_gap, gap4p, gap3, gap2, gap1, flips, frames};
assign probe_c = {polls_last, imiss_last, dmiss_last, instr_last, busy, wait_min, wait_last};

endmodule
