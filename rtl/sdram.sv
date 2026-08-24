// SDRAM Controller for MiSTer DE10-Nano
// Targets IS42S16320D-7TL (32MB, 16-bit, CAS latency 2)
// Simple single-word read/write with auto-refresh
//
// Interface:
//   ADDR[24:0] - byte address (directly mapped: BA[1:0]=ADDR[24:23], ROW=ADDR[22:10], COL=ADDR[9:1])
//   DIN[15:0]  - write data
//   DOUT[15:0] - read data (valid when ACK asserted)
//   RD         - read request (active high, pulse)
//   WR         - write request (active high, pulse)
//   ACK        - read/write acknowledge (1 clock pulse)
//   BUSY       - controller not ready for new request

module sdram (
	output [15:0] DOUT,
	input         CLK,
	input         RESET_N,
	input  [24:0] ADDR,
	input  [15:0] DIN,
	input         RD,
	input         WR,
	output        BUSY,
	output reg    ACK,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output reg    SDRAM_CS_n,
	output reg    SDRAM_WE_n,
	output reg    SDRAM_CAS_n,
	output reg    SDRAM_RAS_n,
	output reg [12:0] SDRAM_A,
	output reg  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output reg    SDRAM_DQML,
	output reg    SDRAM_DQMH
);

// Clock enable — always on
assign SDRAM_CKE = 1'b1;

// SDRAM clock output — 180° phase shifted via DDR output register.
// The SDRAM chip samples data on the rising edge of SDRAM_CLK.
// By inverting the clock (datain_h=0, datain_l=1), the SDRAM sees its
// rising edge at the midpoint between controller transitions, giving
// half a clock period (~4.6 ns at 108 MHz) of setup/hold margin.
altddio_out #(
    .extend_oe_disable("OFF"),
    .intended_device_family("Cyclone V"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
) sdramclk_ddr (
    .datain_h(1'b0),
    .datain_l(1'b1),
    .outclock(CLK),
    .dataout(SDRAM_CLK),
    .aclr(1'b0),
    .aset(1'b0),
    .oe(1'b1),
    .outclocken(1'b1),
    .sclr(1'b0),
    .sset(1'b0)
);

// SDRAM commands {CS_n, RAS_n, CAS_n, WE_n}
localparam CMD_NOP       = 4'b0111;
localparam CMD_ACTIVE    = 4'b0011;
localparam CMD_READ      = 4'b0101;
localparam CMD_WRITE     = 4'b0100;
localparam CMD_PRECHARGE = 4'b0010;
localparam CMD_REFRESH   = 4'b0001;
localparam CMD_LOADMODE  = 4'b0000;
localparam CMD_INHIBIT   = 4'b1111;

// CAS Latency
localparam [3:0] CAS_LATENCY = 4'd2;

// Mode Register: Burst Length=1, Sequential, CAS=2, Standard Operation, Write Burst=Single
localparam MODE_REG = 13'b000_0_00_010_0_000;

// Refresh interval: 64ms / 8192 = 7.8us. At 108MHz = 842 clocks. Use 800 for margin.
localparam REFRESH_INTERVAL = 10'd800;

// States
localparam S_INIT_WAIT   = 4'd0;
localparam S_INIT_PRE    = 4'd1;
localparam S_INIT_REF1   = 4'd2;
localparam S_INIT_REF2   = 4'd3;
localparam S_INIT_MODE   = 4'd4;
localparam S_IDLE        = 4'd5;
localparam S_ACTIVATE    = 4'd6;
localparam S_READ_CMD    = 4'd7;
localparam S_READ_WAIT   = 4'd8;
localparam S_READ_DATA   = 4'd9;
localparam S_WRITE_CMD   = 4'd10;
localparam S_WRITE_DONE  = 4'd11;
localparam S_PRECHARGE   = 4'd12;
localparam S_REFRESH     = 4'd13;
localparam S_WAIT        = 4'd14;

reg [3:0]  state;
reg [15:0] init_counter;
reg [9:0]  refresh_counter;
reg        refresh_needed;
reg [15:0] dq_out;
reg        dq_oe;
reg [15:0] read_data;

// Latched request
reg [24:0] addr_latch;
reg [15:0] din_latch;
reg        rd_latch;
reg        wr_latch;

// Wait counter for timing
reg [3:0]  wait_counter;
reg [3:0]  return_state;

// DQ bus tristate
assign SDRAM_DQ = dq_oe ? dq_out : 16'bZ;
assign DOUT = read_data;
assign BUSY = (state != S_IDLE) || refresh_needed;

// Issue a command
task sdram_cmd;
	input [3:0] cmd;
	begin
		{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= cmd;
	end
endtask

// Address decomposition
wire [1:0]  req_bank = addr_latch[24:23];
wire [12:0] req_row  = addr_latch[22:10];
wire [9:0]  req_col  = {1'b0, addr_latch[9:1]}; // A10=0 (no auto-precharge)

// Refresh counter
always @(posedge CLK or negedge RESET_N) begin
	if (!RESET_N) begin
		refresh_counter <= 0;
		refresh_needed  <= 0;
	end else begin
		if (refresh_counter >= REFRESH_INTERVAL) begin
			refresh_counter <= 0;
			refresh_needed  <= 1;
		end else begin
			refresh_counter <= refresh_counter + 1'd1;
		end
		if (state == S_REFRESH)
			refresh_needed <= 0;
	end
end

// Main state machine
always @(posedge CLK or negedge RESET_N) begin
	if (!RESET_N) begin
		state        <= S_INIT_WAIT;
		init_counter <= 16'd0;
		ACK          <= 1'b0;
		dq_oe        <= 1'b0;
		read_data    <= 16'd0;
		rd_latch     <= 1'b0;
		wr_latch     <= 1'b0;
		wait_counter <= 4'd0;
		SDRAM_A      <= 13'd0;
		SDRAM_BA     <= 2'd0;
		SDRAM_DQML   <= 1'b0;
		SDRAM_DQMH   <= 1'b0;
		{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_INHIBIT;
	end else begin
		ACK   <= 1'b0;
		dq_oe <= 1'b0;
		{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_NOP;

		case (state)
			// ---- INITIALIZATION ----
			S_INIT_WAIT: begin
				// Wait >100us after power-up. At 108MHz, 100us = 10800 clocks.
				init_counter <= init_counter + 1'd1;
				if (init_counter >= 16'd11000)
					state <= S_INIT_PRE;
			end

			S_INIT_PRE: begin
				// Precharge All
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1'b1; // All banks
				wait_counter <= 4'd2; // tRP
				return_state <= S_INIT_REF1;
				state <= S_WAIT;
			end

			S_INIT_REF1: begin
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_REFRESH;
				wait_counter <= 4'd8; // tRC
				return_state <= S_INIT_REF2;
				state <= S_WAIT;
			end

			S_INIT_REF2: begin
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_REFRESH;
				wait_counter <= 4'd8; // tRC
				return_state <= S_INIT_MODE;
				state <= S_WAIT;
			end

			S_INIT_MODE: begin
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_LOADMODE;
				SDRAM_BA <= 2'b00;
				SDRAM_A  <= MODE_REG;
				wait_counter <= 4'd2; // tMRD
				return_state <= S_IDLE;
				state <= S_WAIT;
			end

			// ---- IDLE ----
			S_IDLE: begin
				SDRAM_DQML <= 1'b0;
				SDRAM_DQMH <= 1'b0;
				if (refresh_needed) begin
					state <= S_PRECHARGE;
					return_state <= S_REFRESH;
				end else if (RD || WR) begin
					addr_latch <= ADDR;
					din_latch  <= DIN;
					rd_latch   <= RD;
					wr_latch   <= WR;
					state      <= S_ACTIVATE;
				end
			end

			// ---- ACTIVATE ROW ----
			S_ACTIVATE: begin
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_ACTIVE;
				SDRAM_BA <= req_bank;
				SDRAM_A  <= req_row;
				wait_counter <= 4'd2; // tRCD
				return_state <= rd_latch ? S_READ_CMD : S_WRITE_CMD;
				state <= S_WAIT;
			end

			// ---- READ ----
			S_READ_CMD: begin
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_READ;
				SDRAM_BA    <= req_bank;
				SDRAM_A     <= {3'b000, req_col};
				SDRAM_DQML  <= 1'b0;
				SDRAM_DQMH  <= 1'b0;
				// Wait CAS latency
				wait_counter <= CAS_LATENCY;
				return_state <= S_READ_DATA;
				state <= S_WAIT;
			end

			S_READ_DATA: begin
				read_data <= SDRAM_DQ;
				ACK       <= 1'b1;
				rd_latch  <= 1'b0;
				// Precharge after read
				state <= S_PRECHARGE;
				return_state <= S_IDLE;
			end

			// ---- WRITE ----
			S_WRITE_CMD: begin
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_WRITE;
				SDRAM_BA    <= req_bank;
				SDRAM_A     <= {3'b000, req_col};
				SDRAM_DQML  <= 1'b0;
				SDRAM_DQMH  <= 1'b0;
				dq_out      <= din_latch;
				dq_oe       <= 1'b1;
				state       <= S_WRITE_DONE;
			end

			S_WRITE_DONE: begin
				ACK      <= 1'b1;
				wr_latch <= 1'b0;
				state    <= S_PRECHARGE;
				return_state <= S_IDLE;
			end

			// ---- PRECHARGE ----
			S_PRECHARGE: begin
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1'b1; // All banks
				wait_counter <= 4'd2; // tRP
				state <= S_WAIT;
				// return_state already set by caller
			end

			// ---- REFRESH ----
			S_REFRESH: begin
				{SDRAM_CS_n, SDRAM_RAS_n, SDRAM_CAS_n, SDRAM_WE_n} <= CMD_REFRESH;
				wait_counter <= 4'd8; // tRC
				return_state <= S_IDLE;
				state <= S_WAIT;
			end

			// ---- WAIT (generic delay) ----
			S_WAIT: begin
				if (wait_counter == 0)
					state <= return_state;
				else
					wait_counter <= wait_counter - 1'd1;
			end
		endcase
	end
end

endmodule
