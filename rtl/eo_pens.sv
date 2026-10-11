// hidctch3's light pens, from the MiSTer pad: held positions in the game's units (MAME's PORT_MINMAX, X 0-159,
// Y 0-119), kept as the picture shows them and turned the game's way when the picture is flipped.
//
// A direction steps a pen once a frame: 1 unit for the first SLOW frames it is held, then FAST. The d-pad always
// steps; the left stick as the player's mode says (the OSD's H2 page): Aim (the default) puts the pen where the
// stick points whenever the stick moves, no dead zone, as a light gun reporting through the stick needs, and
// leaves it where the d-pad or the mouse put it while the stick is still; Auto aims from a partial deflection
// past a dead zone and steps on a full one (an arcade stick on a gamepad encoder gives only full ones); D-pad
// makes any deflection past the dead zone a direction. Axes are independent. A PS/2 mouse, off by default,
// moves the pen of the player it is given to by its counts, a unit a count, clamped.
//
// The aim mapping: X to 0-159 (v * 5 / 8), Y to 0-119 (v * 15 / 32), v the offset to 0-255; shifts and adds.
module eo_pens #(
	parameter [7:0] DEAD = 8'd8,      // an axis below this is at rest
	parameter [7:0] FULL = 8'd96,     // at or above it, Auto steps
	parameter [3:0] SLOW = 4'd12,     // frames at 1 unit before FAST
	parameter [7:0] FAST = 8'd3,
	parameter [7:0] MOVE = 8'd2       // Aim: a change of the stick this large moves the pen
) (
	input             clk,
	input             reset,
	input             frame,           // one clock a frame
	input             flip,            // the picture turned 180 degrees
	input      [15:0] ana0, ana1,      // the left sticks, hps_io's signed bytes: Y [15:8] (negative up), X [7:0]
	input      [3:0]  dir0, dir1,      // the d-pads: up, down, left, right
	input      [1:0]  mode0, mode1,    // 0 Aim, 1 Auto, 2 D-pad
	input             ms_ev,           // one clock a mouse packet
	input      [8:0]  ms_dx, ms_dy,    // its counts, signed; Y positive up
	input      [1:0]  ms_to,           // the player the mouse moves: P2, P1
	output     [7:0]  pen1_x, pen2_x,  // the game's 0-159
	output     [6:0]  pen1_y, pen2_y   // the game's 0-119
);

function automatic [7:0] aim_x(input [7:0] a);
	reg [10:0] v; begin v = {3'd0, a ^ 8'h80}; aim_x = 8'(((v << 2) + v) >> 3); end
endfunction
function automatic [6:0] aim_y(input [7:0] a);
	reg [12:0] v; begin v = {5'd0, a ^ 8'h80}; aim_y = 7'(((v << 4) - v) >> 5); end
endfunction
function automatic [7:0] mag(input [7:0] v); mag = v[7] ? 8'd0 - v : v; endfunction
// one step along an axis (up: towards top), clamped to 0-top
function automatic [7:0] step(input [7:0] v, input up, input [3:0] held, input [7:0] top);
	reg [7:0] d;
	begin
		d = held == SLOW ? FAST : 8'd1;
		if (up) step = (v > top - d) ? top : v + d;
		else    step = (v < d) ? 8'd0 : v - d;
	end
endfunction

// add a mouse count, clamped to 0-top
function automatic [7:0] nudge(input [7:0] v, input [9:0] d, input [7:0] top);
	reg signed [10:0] s;
	begin
		s = $signed({3'b000, v}) + $signed({d[9], d});
		nudge = s < 0 ? 8'd0 : s > $signed({3'b000, top}) ? top : s[7:0];
	end
endfunction

// the stick has moved this far from the value last applied (signed bytes)
function automatic moved(input [7:0] a, input [7:0] b);
	reg signed [8:0] d;
	begin d = $signed({a[7], a}) - $signed({b[7], b}); moved = (d >= $signed({1'b0, MOVE})) || (d <= -$signed({1'b0, MOVE})); end
endfunction

reg  [7:0] px [0:1];
reg  [6:0] py [0:1];
reg  [7:0] lx_a [0:1], ly_a [0:1];  // the stick's X and Y when last applied
reg  [3:0] held [0:1];             // frames a direction has been held, to SLOW
wire [3:0] dir [0:1];              // up, down, left, right
wire [1:0] aim [0:1];              // the stick aims: Y, X
genvar g;
generate
	for (g = 0; g < 2; g = g + 1) begin : in
		wire [15:0] a  = g ? ana1 : ana0;
		wire [1:0]  md = g ? mode1 : mode0;
		wire        lx = mag(a[7:0]) >= DEAD, ly = mag(a[15:8]) >= DEAD;
		// a deflection steps: any past the dead zone (D-pad), a full one (Auto), none (Aim)
		wire        sx = md == 2'd2 ? lx : md == 2'd1 ? mag(a[7:0]) >= FULL : 1'b0;
		wire        sy = md == 2'd2 ? ly : md == 2'd1 ? mag(a[15:8]) >= FULL : 1'b0;
		assign dir[g] = (g ? dir1 : dir0) | {a[15] & sy, ~a[15] & sy, a[7] & sx, ~a[7] & sx};
		// the stick aims: when it moves (Aim), a partial deflection past the dead zone (Auto)
		assign aim[g] = md == 2'd0 ? {moved(a[15:8], ly_a[g]), moved(a[7:0], lx_a[g])} : {ly & ~sy, lx & ~sx};
	end
endgenerate

always @(posedge clk) begin
	for (int i = 0; i < 2; i++) begin
		if (reset) begin
			px[i] <= 8'd80; py[i] <= 7'd60; held[i] <= 4'd0; lx_a[i] <= 8'd0; ly_a[i] <= 8'd0;
		end else if (ms_ev && ms_to[i]) begin
			px[i] <= nudge(px[i], {ms_dx[8], ms_dx}, 8'd159);
			py[i] <= 7'(nudge({1'b0, py[i]}, 10'd0 - {ms_dy[8], ms_dy}, 8'd119));
		end else begin
			if (frame) begin
				if (dir[i] == 4'd0) held[i] <= 4'd0;
				else if (held[i] != SLOW) held[i] <= held[i] + 4'd1;
			end
			if (dir[i][1:0] != 2'd0) begin
				if (frame && dir[i][0]) px[i] <= step(px[i], 1'b1, held[i], 8'd159);
				if (frame && dir[i][1]) px[i] <= step(px[i], 1'b0, held[i], 8'd159);
			end else if (aim[i][0]) begin
				px[i] <= aim_x(i ? ana1[7:0] : ana0[7:0]);
				lx_a[i] <= i ? ana1[7:0] : ana0[7:0];
			end
			if (dir[i][3:2] != 2'd0) begin
				if (frame && dir[i][2]) py[i] <= 7'(step({1'b0, py[i]}, 1'b1, held[i], 8'd119));
				if (frame && dir[i][3]) py[i] <= 7'(step({1'b0, py[i]}, 1'b0, held[i], 8'd119));
			end else if (aim[i][1]) begin
				py[i] <= aim_y(i ? ana1[15:8] : ana0[15:8]);
				ly_a[i] <= i ? ana1[15:8] : ana0[15:8];
			end
		end
	end
end

assign pen1_x = flip ? 8'd159 - px[0] : px[0];
assign pen2_x = flip ? 8'd159 - px[1] : px[1];
assign pen1_y = flip ? 7'd119 - py[0] : py[0];
assign pen2_y = flip ? 7'd119 - py[1] : py[1];

endmodule
