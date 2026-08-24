// mpg_streamer.sv
//
// Sequential sector streamer for MPEG2 video files on MiSTer.
// Uses the hps_io sd_* interface to read sectors on-demand from a mounted
// image file, caching them in a circular BRAM buffer, and feeding bytes
// to the mpeg2video decoder's stream_data/stream_valid interface.
//
// Based on CDi_MiSTer's hps_cd_sector_cache pattern.

module mpg_streamer (
    input             clk,
    input             rst_n,

    // Control
    input             start,        // pulse: begin streaming from sector 0
    input      [63:0] file_size,    // file size in bytes (from img_size)

    // hps_io sd_* interface (directly connected)
    output reg [31:0] sd_lba,
    output reg        sd_rd,
    input             sd_ack,
    input      [13:0] sd_buff_addr, // byte address within sector buffer
    input      [7:0]  sd_buff_dout, // data from HPS (directly 8-bit bytes)
    input             sd_buff_wr,   // write strobe

    // Output to mpeg2video decoder
    output reg  [7:0] stream_data,
    output reg        stream_valid,
    input             busy          // backpressure from decoder
);

// =========================================================================
// Circular BRAM cache
// =========================================================================
// 16KB cache = 2^14 bytes. At 512 bytes/sector, holds 32 sectors.
// We request new sectors when there's room for at least one more.
localparam ADDR_WIDTH = 14;
localparam CACHE_SIZE = 2 ** ADDR_WIDTH;
localparam SECTOR_SIZE = 512;  // MiSTer default sd block size (BLKSZ=2)

reg [7:0] cache_mem [0:CACHE_SIZE-1];

reg [ADDR_WIDTH-1:0] wr_ptr;
reg [ADDR_WIDTH-1:0] rd_ptr;
wire [ADDR_WIDTH-1:0] cache_level = wr_ptr - rd_ptr;
wire cache_has_data = (wr_ptr != rd_ptr);
wire cache_has_room = (cache_level < CACHE_SIZE - SECTOR_SIZE - 1);

// Read port - register output for timing
reg [7:0] cache_rd_data;
always @(posedge clk) begin
    cache_rd_data <= cache_mem[rd_ptr];
end

// Write port - HPS writes sector data here
always @(posedge clk) begin
    if (sd_buff_wr) begin
        cache_mem[wr_ptr + sd_buff_addr[8:0]] <= sd_buff_dout;
    end
end

// =========================================================================
// Track total sectors in file
// =========================================================================
wire [31:0] total_sectors = file_size[31:0] / SECTOR_SIZE +
                            (file_size[8:0] != 0 ? 1 : 0);

// =========================================================================
// Sector request state machine
// =========================================================================
reg        active;
reg [31:0] next_lba;        // next sector to request
reg        sector_pending;  // a sector request is in flight
reg        sd_ack_prev;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        active         <= 1'b0;
        next_lba       <= 32'd0;
        sd_lba         <= 32'd0;
        sd_rd          <= 1'b0;
        sector_pending <= 1'b0;
        wr_ptr         <= 0;
        sd_ack_prev    <= 1'b0;
    end else begin
        sd_ack_prev <= sd_ack;

        // Start signal: reset everything and begin from sector 0
        if (start) begin
            active         <= 1'b1;
            next_lba       <= 32'd0;
            sd_lba         <= 32'd0;
            sd_rd          <= 1'b0;
            sector_pending <= 1'b0;
            wr_ptr         <= 0;
        end else if (active) begin

            // Detect sd_ack falling edge = sector transfer complete
            if (sd_ack_prev && !sd_ack) begin
                sector_pending <= 1'b0;
                wr_ptr         <= wr_ptr + SECTOR_SIZE;
                next_lba       <= next_lba + 1;
            end

            // Request next sector if: active, room in cache, no pending request,
            // and we haven't read past the end of the file
            if (!sector_pending && !sd_ack && cache_has_room &&
                next_lba < total_sectors) begin
                sd_lba         <= next_lba;
                sd_rd          <= 1'b1;
                sector_pending <= 1'b1;
            end

            // Clear sd_rd once acknowledged
            if (sd_ack) begin
                sd_rd <= 1'b0;
            end

            // Stop when we've consumed all data
            if (next_lba >= total_sectors && !sector_pending && !cache_has_data) begin
                active <= 1'b0;
            end
        end
    end
end

// =========================================================================
// Output: feed bytes to decoder
// =========================================================================
// Read one byte from cache per cycle when decoder is not busy and data available.
// We need a 1-cycle delay because cache_rd_data is registered.

reg read_valid_pipe;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stream_data     <= 8'd0;
        stream_valid    <= 1'b0;
        read_valid_pipe <= 1'b0;
        rd_ptr          <= 0;
    end else begin
        // Reset on start signal
        if (start) begin
            rd_ptr          <= 0;
            stream_valid    <= 1'b0;
            read_valid_pipe <= 1'b0;
        end else begin
            // Default: deassert valid
            stream_valid <= 1'b0;

            // Pipeline stage 2: output the registered read data
            if (read_valid_pipe) begin
                stream_data  <= cache_rd_data;
                stream_valid <= 1'b1;
                read_valid_pipe <= 1'b0;
            end

            // Pipeline stage 1: initiate read if decoder ready and data available
            if (!busy && !read_valid_pipe && cache_has_data && active) begin
                rd_ptr          <= rd_ptr + 1;
                read_valid_pipe <= 1'b1;
            end
        end
    end
end

endmodule
