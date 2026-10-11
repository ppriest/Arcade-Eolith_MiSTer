// Memory wait states between the E1 and the memory unit: each data access waits a number of clocks, by the
// E1's memory area, before the memory unit sees its request.
//
// The board's E1 has no data cache and runs every access at the timing its BCR sets per area (MAME's
// update_bus_control decodes it; raccoon writes 0xfa1501c4: MEM0-2 two cycles, MEM3 eleven plus one hold,
// at 45 MHz). The core's memory answers a cache hit in one clock. The counts are an experiment, set on the
// OSD (docs/HACKS.md); 0 passes the request straight through.
//
// The E1's areas: MEM0 0x00000000, MEM1 0x40000000, MEM2 0x80000000, IRAM 0xc0000000, MEM3 0xe0000000; the
// I/O space is counted as MEM3. The CPU may raise its next request in the clock the last is acked, so an
// access starts at a request after an ack, not at a rising edge.
module eo_busws (
	input             clk,
	input             rst,
	input             req,             // the CPU's bus_req, held until ack
	input             ack,             // the memory unit's bus_ack
	input             io,
	input      [31:29] addr,
	input      [5:0]  ws_mem3,         // clocks added to a MEM3 (and I/O) access
	input      [5:0]  ws_mem,          // clocks added to a MEM0-2 access
	output            req_o            // to the memory unit
);

reg        busy = 1'b0;                // the access in progress has been counted in
reg  [5:0] cnt = 6'd0;
wire       m3 = io || addr == 3'b111;
wire [5:0] ws = m3 ? ws_mem3 : (addr[31:30] == 2'b11 ? 6'd0 : ws_mem);

always @(posedge clk) begin
	if (rst) begin
		busy <= 1'b0; cnt <= 6'd0;
	end else if (ack) begin
		busy <= 1'b0;
	end else if (req && !busy) begin
		busy <= 1'b1; cnt <= ws == 6'd0 ? 6'd0 : ws - 6'd1;   // the first clock is one of them
	end else if (busy && cnt != 6'd0)
		cnt <= cnt - 6'd1;
end

// with no wait the request passes in its first clock, as before; otherwise once the count has run out
assign req_o = req && (busy ? cnt == 6'd0 : ws == 6'd0);

endmodule
