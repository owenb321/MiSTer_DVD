module emu (
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,
	output        VGA_DISABLE,

	output        CLK_SYS,
	output        CLK_MEM,

	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nWE,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,

	input  [1:0]  BUTTONS,

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output        AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,


	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	output [6:0]  USER_OUT,
	input  [6:0]  USER_IN,

	input         OSD_STATUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,

	input         CLK_AUDIO,
	output        LOCKED
);

// =========================================================================
// Default assignments for unused interfaces
// =========================================================================
assign VIDEO_ARX    = 13'd4;
assign VIDEO_ARY    = 13'd3;

assign VGA_F1       = 0;
assign VGA_SL       = 0;
assign VGA_SCALER   = 1; // Enable scaler for universal HDMI compatibility
assign VGA_DISABLE  = 0;
assign HDMI_FREEZE      = 0;
assign HDMI_BLACKOUT    = 0;
assign HDMI_BOB_DEINT   = 0;

// LED and status assignments consolidated at the end of module

assign AUDIO_S      = 0;
assign AUDIO_MIX    = 0;
assign AUDIO_L      = 0;
assign AUDIO_R      = 0;

assign SD_SCK       = 0;
assign SD_MOSI      = 0;
assign SD_CS        = 1;

// SDRAM Interface -- Unused
assign SDRAM_CLK    = 0;
assign SDRAM_CKE    = 0;
assign SDRAM_A      = 0;
assign SDRAM_BA     = 0;
assign SDRAM_DQ     = 16'bZ;
assign SDRAM_DQML   = 0;
assign SDRAM_DQMH   = 0;
assign SDRAM_nCS    = 1;
assign SDRAM_nWE    = 1;
assign SDRAM_nCAS   = 1;
assign SDRAM_nRAS   = 1;

assign UART_RTS     = 1;
assign UART_DTR     = 1;
// assign UART_TXD     = 1;

// Debug: Stream loading status on USER_OUT pins
// assign USER_OUT     = {3'b0, streamer_active, streamer_sd_rd, streamer_sd_ack, streamer_has_data};

// =========================================================================
// Clocks and Reset
// =========================================================================
wire clk_sys, clk_mem, clk_vid, locked;

sys_pll sys_pll (
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),  // 27 MHz
    .outclk_1 (clk_mem),  // 108 MHz
    .outclk_2 (clk_vid),  // 25.175 MHz
    .locked   (locked)
);

// DDR3 interface clock: use clk_mem (108 MHz).
// This eliminates the CDC between the f2sdram bridge and our FSM since the
// MPEG2 memory request FIFOs are internally driven by clk_mem.
wire clk_100m_hps = HPS_BUS[43];  // 100 MHz from HPS
assign DDRAM_CLK = clk_mem;

// Active-low reset for the mpeg2video core
// The core's internal reset module handles watchdog_rst independently,
// so we must NOT feed watchdog_rst back into rst to avoid a latch-up:
// watchdog fires -> reset_n LOW -> async_rst LOW -> hard_rst LOW -> watchdog stuck
wire watchdog_rst;
wire reset_n = locked & ~RESET;

// 108 MHz / 4 = 27 MHz pixel clock enable for internal modules
reg [1:0] ce_cnt;
always @(posedge clk_mem) ce_cnt <= ce_cnt + 1'b1;
wire ce_pixel = (ce_cnt == 2'b00);

// The MiSTer HDMI/VGA PHY natively clocks at CLK_VIDEO frequency. 
// For NTSC 480i/p video, this must be exactly 27.0 MHz.
assign CLK_VIDEO = clk_sys;  // 27 MHz
assign CE_PIXEL  = 1'b1;     // Fully utilized 27 MHz clock

// =========================================================================
// HPS IO — OSD menu and file loading
// =========================================================================
parameter CONF_STR = {
    "MPEG2;;",
    "S0,MPG M2V,Load Video;",
    "O1,Aspect Ratio,4:3,16:9;",
    "O[10],Direct Video,Off,On;",
    "R0,Reset;",
    "V,v1.0;"
};

wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wr;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wait = 1'b0;
wire        direct_video;

wire  [1:0] buttons;
wire [31:0] status;
wire [31:0] joystick_0;

// SD sector interface signals
wire [31:0] sd_lba;
wire        sd_rd;
wire        sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire        sd_buff_wr;
wire  [0:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR)) hps_io_inst (
    .clk_sys        (clk_sys),
    .HPS_BUS        (HPS_BUS),

    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_index    (ioctl_index),
    .ioctl_wait     (ioctl_wait),

    .buttons        (buttons),
    .status         (status),
    .joystick_0     (joystick_0),

    .forced_scandoubler(),
    .gamma_bus(),
    .direct_video   (direct_video),

    // SD sector-level access (virtual disk for MPG streaming)
    .sd_lba         ('{sd_lba}),
    .sd_blk_cnt     ('{6'd0}),
    .sd_rd          (sd_rd),
    .sd_wr          (1'b0),
    .sd_ack         (sd_ack),
    .sd_buff_addr   (sd_buff_addr),
    .sd_buff_dout   (sd_buff_dout),
    .sd_buff_din    ('{8'd0}),
    .sd_buff_wr     (sd_buff_wr),

    // Image mount detection
    .img_mounted    (img_mounted),
    .img_readonly   (img_readonly),
    .img_size       (img_size)
);

// =========================================================================
// MPG Sector Streamer: sd_* interface -> stream_data for mpeg2video
// =========================================================================
wire [7:0] stream_data;
wire       stream_valid;
wire       core_busy;

// Detect image mount event (start streaming)
reg        img_mounted_prev;
wire       start_streaming = img_mounted[0] && !img_mounted_prev;
reg [63:0] current_file_size;

always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        img_mounted_prev  <= 1'b0;
        current_file_size <= 64'd0;
    end else begin
        img_mounted_prev <= img_mounted[0];
        if (img_mounted[0])
            current_file_size <= img_size;
    end
end

wire streamer_active, streamer_sd_rd, streamer_sd_ack, streamer_has_data;
wire [15:0] streamer_file_size, streamer_total_sectors, streamer_next_lba;

mpg_streamer mpg_streamer_inst (
    .clk            (clk_sys),
    .rst_n          (reset_n),

    .start          (start_streaming),
    .file_size      (current_file_size),

    .sd_lba         (sd_lba),
    .sd_rd          (sd_rd),
    .sd_ack         (sd_ack),
    .sd_buff_addr   (sd_buff_addr),
    .sd_buff_dout   (sd_buff_dout),
    .sd_buff_wr     (sd_buff_wr),

    .stream_data    (stream_data),
    .stream_valid   (stream_valid),
    .busy           (core_busy),

    .debug_active         (streamer_active),
    .debug_sd_rd          (streamer_sd_rd),
    .debug_sd_ack         (streamer_sd_ack),
    .debug_cache_has_data (streamer_has_data),
    .debug_file_size      (streamer_file_size),
    .debug_total_sectors  (streamer_total_sectors),
    .debug_next_lba       (streamer_next_lba)
);

// =========================================================================
// MPEG2 Video Decoder Core
// =========================================================================
wire [1:0]  core_mem_cmd;
wire [21:0] core_mem_addr;
wire [63:0] core_mem_dta_out;
wire        core_mem_en;
wire        core_mem_valid;
wire [63:0] shim_mem_dta;
wire        shim_mem_en;
wire        shim_mem_almost_full;

wire [7:0] core_r, core_g, core_b;
wire       core_h_sync, core_v_sync;
wire [11:0] core_h_pos, core_v_pos;
wire [8:0]  core_init_cnt;
wire        core_sync_rst;
wire        core_vbw_almost_full;
wire       core_pixel_en;
wire [3:0]  shim_debug_state;
wire [1:0]  shim_debug_saved_cmd;
wire        shim_debug_sdram_busy;
wire        shim_debug_sdram_ack;
wire [15:0] shim_debug_rd_count;
wire [15:0] shim_debug_wr_count;
wire [15:0] shim_debug_rsp_count;
wire [15:0] shim_debug_read_pend_cycles;

mpeg2video mpeg2video_inst (
    .clk        (clk_sys),   // 27 MHz — matches prior-working-config; 4× lower mem request rate
    .mem_clk    (clk_mem),   // 108 MHz — FIFO: wr=27MHz rd=108MHz, read-faster safe CDC
    .dot_clk    (clk_sys),   // 27MHz native dot clock (cleanly drives MiSTer HDMI PHY)
    .dot_ce     (1'b1),      // No clock enable needed when using native 27MHz
    .rst        (reset_n),

    .stream_data  (stream_data),
    .stream_valid (stream_valid),

    .reg_addr   (4'b0),
    .reg_wr_en  (1'b0),
    .reg_dta_in (32'b0),
    .reg_rd_en  (1'b0),

    .busy       (core_busy),
    .error      (vld_err),
    .interrupt  (),
    .watchdog_rst (watchdog_rst),

    .r          (core_r),
    .g          (core_g),
    .b          (core_b),
    .y          (),
    .u          (),
    .v          (),
    .pixel_en   (core_pixel_en),
    .h_sync     (core_h_sync),
    .v_sync     (core_v_sync),
    .c_sync     (),
    .h_pos      (core_h_pos),
    .v_pos      (core_v_pos),

    .mem_req_rd_cmd   (core_mem_cmd),
    .mem_req_rd_addr  (core_mem_addr),
    .mem_req_rd_dta   (core_mem_dta_out),
    .mem_req_rd_en    (core_mem_en),
    .mem_req_rd_valid (core_mem_valid),

    .mem_res_wr_dta          (shim_mem_dta),
    .mem_res_wr_en           (shim_mem_en),
    .mem_res_wr_almost_full  (shim_mem_almost_full),

    .testpoint_dip    (4'b0),
    .testpoint_dip_en (1'b0),
    .init_cnt_out     (core_init_cnt),
    .sync_rst_out     (core_sync_rst),
    .vbw_almost_full_out (core_vbw_almost_full)
);

// =========================================================================
// Memory Shim: 64-bit core <-> 64-bit DDR3
// =========================================================================
mem_shim mem_shim_inst (
    .clk              (clk_mem),  // 108 MHz — same domain as FIFOs and f2sdram bridge
    .rst_n            (reset_n),  // Soft reset — resets FSM and FIFOs
    .hard_rst_n       (locked & ~RESET), // Hard reset — resets hardware tracking counters

    .mem_req_rd_cmd   (core_mem_cmd),
    .mem_req_rd_addr  (core_mem_addr),
    .mem_req_rd_dta   (core_mem_dta_out),
    .mem_req_rd_en    (core_mem_en),
    .mem_req_rd_valid (core_mem_valid),

    .mem_res_wr_dta          (shim_mem_dta),
    .mem_res_wr_en           (shim_mem_en),
    .mem_res_wr_almost_full  (shim_mem_almost_full),

    // DDR3 Avalon-MM Interface
    .ddr3_addr          (DDRAM_ADDR),
    .ddr3_burstcnt      (DDRAM_BURSTCNT),
    .ddr3_read          (DDRAM_RD),
    .ddr3_write         (DDRAM_WE),
    .ddr3_writedata     (DDRAM_DIN),
    .ddr3_byteenable    (DDRAM_BE),
    .ddr3_readdata      (DDRAM_DOUT),
    .ddr3_readdatavalid (DDRAM_DOUT_READY),
    .ddr3_waitrequest   (DDRAM_BUSY),

    .debug_state      (shim_debug_state),
    .debug_saved_cmd  (shim_debug_saved_cmd),
    .debug_sdram_busy (shim_debug_sdram_busy),
    .debug_sdram_ack  (shim_debug_sdram_ack),
    .debug_rd_count   (shim_debug_rd_count),
    .debug_wr_count   (shim_debug_wr_count),
    .debug_rsp_count  (shim_debug_rsp_count),
    .debug_read_pend_cycles (shim_debug_read_pend_cycles)
);

// =========================================================================
// Core Video Active Detection (for debug / uart_debug only)
// =========================================================================
// Tracks vsync edges to know when the core's syncgen is running.
// No longer used for a video mux — VGA is wired directly from the core.

reg [2:0]  core_vs_edge_cnt = 0;
reg        core_vs_prev = 0;
wire       core_video_active = (core_vs_edge_cnt >= 3'd3);
reg [15:0] core_frame_cnt = 0;  // free-running frame counter (all vsync rising edges)

// core_v_sync is in clk_mem domain (dot_clk=clk_mem), so sample here on clk_mem
always @(posedge clk_mem or negedge reset_n) begin
    if (!reset_n) begin
        core_vs_edge_cnt <= 0;
        core_vs_prev     <= 0;
        core_frame_cnt   <= 0;
    end else begin
        core_vs_prev <= core_v_sync;
        // Count rising edges of core vsync
        if (~core_vs_prev & core_v_sync & ~core_video_active)
            core_vs_edge_cnt <= core_vs_edge_cnt + 1'd1;
        // Free-running frame counter (all vsync edges, wraps at 65535)
        if (~core_vs_prev & core_v_sync)
            core_frame_cnt <= core_frame_cnt + 1'd1;
    end
end

// =========================================================================
// Video Output — direct from MPEG2 core (no fallback mux)
// =========================================================================
// The fallback VGA generator ran on clk_vid (25.175 MHz) but CLK_VIDEO =
// clk_mem (108 MHz). Sampling clk_vid signals on clk_mem caused metastable
// sync signals that the MiSTer scaler could never lock to → permanent black.
// The MPEG2 core's outputs are already on clk_mem (dot_clk=clk_mem), so
// wiring them directly is clean. Before a stream is decoded, the core
// outputs black (Y=16, Cb=Cr=128), which is fine — "no signal" until play.

assign VGA_R  = core_r;
assign VGA_G  = core_g;
assign VGA_B  = core_b;
assign VGA_HS = core_h_sync;
assign VGA_VS = core_v_sync;
assign VGA_DE = core_pixel_en;


uart_debug debug_inst (
    .clk(clk_sys),
    .rst_n(reset_n),
    .tx_pin(UART_TXD),
    .locked(locked),
    .active(core_video_active),
    .arx({1'b0, core_h_pos}),
    .ary({1'b0, core_v_pos}),
    .busy(core_busy),
    .valid(stream_valid),
    // Additional debug signals from mpeg2video core internals
    .init_cnt(core_init_cnt),
    .sync_rst(core_sync_rst),
    .vbw_almost_full(core_vbw_almost_full),
    .mem_req_en(core_mem_en),
    .mem_req_valid(core_mem_valid),
    .mem_res_almost_full(shim_mem_almost_full),
    // DDR3 debug (mapped through mem_shim debug outputs)
    .shim_state(shim_debug_state),          // M: {cmd[1:0],saved_valid,state}
    .shim_saved_cmd(shim_debug_saved_cmd),  // SC: skid buffer cmd type
    .sdram_busy(shim_debug_sdram_busy),     // U: ddr3_waitrequest
    .sdram_ack(shim_debug_sdram_ack),       // K: ddr3 transaction accepted
    // MPG streamer debug
    .streamer_active(streamer_active),
    .streamer_sd_rd(streamer_sd_rd),
    .streamer_sd_ack(streamer_sd_ack),
    .streamer_has_data(streamer_has_data),
    .streamer_file_size(streamer_file_size),
    .streamer_total_sectors(streamer_total_sectors),
    .streamer_next_lba(streamer_next_lba),
    // Memory read/write counters
    .mem_rd_count(shim_debug_rd_count),     // P: DDR3 read completions
    .mem_wr_count(shim_debug_wr_count),     // W: DDR3 write completions
    .mem_rsp_count(shim_debug_rsp_count),   // RP: readdatavalid pulses received
    .mem_pend_cycles(shim_debug_read_pend_cycles), // PC: cycles in READ_PEND
    .hdmi_lock(vld_err),               // G: VLD decoder error
    .watchdog_rst(watchdog_rst),       // O: decoder watchdog fired (latched)
    .core_vs_edge_cnt(core_vs_edge_cnt), // N: vsync edges seen before active
    .core_frame_cnt(core_frame_cnt),   // FC: free-running frame counter
    .mem_addr(DDRAM_ADDR)
);

assign CLK_SYS = clk_sys;
assign CLK_MEM = clk_mem;

// =========================================================================
// LEDs and Debug
// =========================================================================
assign LED_POWER    = 2'b00; // Let system control
assign LED_DISK     = {streamer_active, stream_valid}; // LED indicates: streaming active, data flowing
assign LOCKED       = locked;

reg [24:0] heartbeat;
always @(posedge clk_sys) heartbeat <= heartbeat + 1'b1;
assign LED_USER     = heartbeat[24]; // Toggle ~1Hz @ 27MHz

// Route UART TX to User IO (Pin 0/1 usually, adapting for standard cable)
// User IO pin mapping usually: [0]=TX, [1]=RX or vice versa depending on cable.
// emu connects to sys_top user_out/user_in.
assign USER_OUT = {6'b0, UART_TXD};

endmodule

