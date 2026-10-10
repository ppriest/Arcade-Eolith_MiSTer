/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 93Cxx serial EEPROM as MAME's eeprom_serial_93cxx_device behaves (eepromser.cpp): Vamphalf's
 * rtl/vh_eeprom93c46.v (from Arcade-KonamiGX_MiSTer) with the size as parameters and the array in
 * block RAM. Eolith: EEPROM_93C66_8BIT, 512 x 8, 9 address bits, write and erase 250 us (eolith.cpp
 * 704-706, eolith16.cpp 174-176); WRITEALL and ERASEALL keep MAME's 8 ms (eeprom.cpp 45-48).
 *
 *   S_RESET  until CS rises
 *   S_START  DO = ready; a rising CLK with DI = 1 starts a command (not while busy)
 *   S_CMD    2 opcode + AW address bits, on rising CLK
 *   S_READ   DO starts at the dummy 0; the first rising CLK loads the word (MSB first), later ones
 *            shift in 1s (no streaming)
 *   S_DATA   DW data bits on rising CLK, then the write
 *   S_DONE   until CS falls
 * CS falling always returns to S_RESET. DO is 1 in every state but S_START and S_READ.
 * Commands: 10 READ, 01 WRITE, 11 ERASE; 00 + the top two address bits: 00 LOCK, 01 WRITEALL (ANDed into
 * every word, as eeprom_base_device::write_all), 10 ERASEALL, 11 UNLOCK. A refused write or erase
 * (locked) goes to S_RESET; the part powers up locked.
 *
 * The pins come from one control register. MAME applies a write's bits in order CS, CLK, DI, so a
 * CLK edge samples DI as it was before the write (di_l), and a CLK edge in the write that raises CS
 * is not a start bit.
 *
 * WRITEALL and ERASEALL sweep the array, two clocks a word, inside the busy time. load_* writes the
 * array (the .nvm, the core held); rd_* reads it for the save, data a clock later. `written` pulses
 * when a command changes it. Powers up all ones (eeprom_base_device's default fill).
 */

`default_nettype none

module eo_eeprom93cxx #(
	parameter AW       = 9,
	parameter DW       = 8,
	parameter CLK_KHZ  = 57273,
	parameter WRITE_US = 250,
	parameter ERASE_US = 250,
	parameter ALL_US   = 8000
) (
	input  wire          clk,
	input  wire          rst,
	input  wire          cs,
	input  wire          sk,
	input  wire          di,
	output wire          dout,

	input  wire          load_we,
	input  wire [AW-1:0] load_addr,
	input  wire [DW-1:0] load_data,
	input  wire [AW-1:0] rd_addr,
	output reg  [DW-1:0] rd_data,
	output reg           written
);

localparam [2:0] S_RESET = 0, S_START = 1, S_CMD = 2, S_READ = 3, S_DATA = 4, S_DONE = 5;
localparam CW = AW + 2;
localparam [19:0] T_WRITE = CLK_KHZ * WRITE_US / 1000, T_ERASE = CLK_KHZ * ERASE_US / 1000,
                  T_ALL = CLK_KHZ * ALL_US / 1000;

reg  [2:0]    st;
reg           cs_l, sk_l, di_l, locked, wall;
reg  [CW-1:0] cmd;
reg  [4:0]    nbits;
reg  [DW-1:0] shreg;
reg  [AW-1:0] addr;
reg  [19:0]   busy;
wire          ready = busy == 20'd0;
reg           sweeping, sw_ph, sw_ones;
reg  [AW-1:0] sw_addr;
reg  [DW-1:0] sw_data;

wire          cs_rise = cs && !cs_l, cs_fall = !cs && cs_l;
wire          sk_rise = sk && !sk_l;
wire [CW-1:0] cmd_n   = {cmd[CW-2:0], di_l};
wire          cmd_done  = !cs_fall && st == S_CMD && sk_rise && nbits == CW - 1;
wire          data_done = !cs_fall && st == S_DATA && sk_rise && nbits == DW - 1;
wire [1:0]    opc  = cmd_n[CW-1:CW-2];
wire [1:0]    opx  = cmd_n[AW-1:AW-2];
wire [DW-1:0] word = {shreg[DW-2:0], di_l};

assign dout = st == S_READ ? shreg[DW-1] : st == S_START ? ready : 1'b1;

// ---- the array: port A the state machine, the sweeps and the load; port B the save ----
reg  [DW-1:0] mem [0:(1 << AW) - 1];
reg  [DW-1:0] mq;
integer i;
initial for (i = 0; i < (1 << AW); i = i + 1) mem[i] = {DW{1'b1}};

wire [AW-1:0] a_addr = load_we ? load_addr : sweeping ? sw_addr : cmd_done ? cmd_n[AW-1:0] : addr;
wire          w_erase = cmd_done && opc == 2'b11 && !locked;
wire          w_write = data_done && !wall && !locked;
wire          a_we   = load_we || (sweeping && sw_ph) || w_erase || w_write;
wire [DW-1:0] a_wd   = load_we ? load_data : sweeping ? (sw_ones ? {DW{1'b1}} : mq & sw_data)
                     : w_erase ? {DW{1'b1}} : word;
always @(posedge clk) begin
	if (a_we) mem[a_addr] <= a_wd;
	mq      <= mem[a_addr];
	rd_data <= mem[rd_addr];
end

always @(posedge clk) begin
	written <= 1'b0;
	if (!ready) busy <= busy - 20'd1;
	if (sweeping) begin
		sw_ph <= !sw_ph;
		if (sw_ph) begin
			sw_addr <= sw_addr + 1'd1;
			if (&sw_addr) sweeping <= 1'b0;
		end
	end
	if (rst) begin
		st     <= S_RESET;
		cs_l   <= 1'b0;
		sk_l   <= 1'b0;
		di_l   <= 1'b0;
		locked <= 1'b1;
		busy   <= 20'd0;
	end else begin
		cs_l <= cs;
		sk_l <= sk;
		di_l <= di;
		if (cs_fall) st <= S_RESET;
		else case (st)
			S_RESET: if (cs_rise) st <= S_START;
			S_START: if (sk_rise && di_l && ready) begin
				cmd   <= {CW{1'b0}};
				nbits <= 5'd0;
				st    <= S_CMD;
			end
			S_CMD: if (sk_rise) begin
				cmd   <= cmd_n;
				nbits <= nbits + 5'd1;
				if (cmd_done) begin
					nbits <= 5'd0;
					addr  <= cmd_n[AW-1:0];
					shreg <= {DW{1'b0}};
					case (opc)
						2'b10: st <= S_READ;
						2'b01: begin wall <= 1'b0; st <= S_DATA; end
						2'b11: begin
							if (!locked) begin written <= 1'b1; busy <= T_ERASE; end
							st <= locked ? S_RESET : S_DONE;
						end
						default: case (opx)
							2'b00: begin locked <= 1'b1; st <= S_RESET; end
							2'b01: begin wall <= 1'b1; st <= S_DATA; end
							2'b10: begin
								if (!locked) begin
									sweeping <= 1'b1; sw_ph <= 1'b0; sw_addr <= {AW{1'b0}}; sw_ones <= 1'b1;
									written  <= 1'b1;
									busy     <= T_ALL;
								end
								st <= locked ? S_RESET : S_DONE;
							end
							default: begin locked <= 1'b0; st <= S_RESET; end
						endcase
					endcase
				end
			end
			S_READ: if (sk_rise) begin
				nbits <= nbits + 5'd1;
				shreg <= nbits == 5'd0 ? mq : {shreg[DW-2:0], 1'b1};
			end
			S_DATA: if (sk_rise) begin
				shreg <= word;
				nbits <= nbits + 5'd1;
				if (data_done) begin
					if (!locked) begin
						if (wall) begin
							sweeping <= 1'b1; sw_ph <= 1'b0; sw_addr <= {AW{1'b0}}; sw_ones <= 1'b0;
							sw_data  <= word;
						end
						written <= 1'b1;
						busy    <= wall ? T_ALL : T_WRITE;
					end
					st <= locked ? S_RESET : S_DONE;
				end
			end
			default: ;          // S_DONE: until CS falls
		endcase
	end
end

endmodule
