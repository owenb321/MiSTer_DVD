// nav_dsi.sv - DVD NAV-pack DSI (Data Search Information) capture.
//
// Phase-7 DVD navigation foundation. Consumes the DSI byte stream ps_demux
// forwards for private_stream_2 substream 0x01 (dsi_byte/dsi_valid/
// dsi_frame_start, accept-always, the twin of the PCI path -> nav_pci). Parses
// the presentation-time <-> disc-sector data that Phase 8 (seek/scrub/chapter)
// and Phase 9 (multi-angle) sit on. This phase EXPOSES the fields; the seek /
// angle consumers land later.
//
// Byte index is relative to the DSI DATA start (the byte after the 0x01
// substream id), matching how nav_pci indexes PCI. Field layout verified
// against libdvdread nav_types.h (dsi_gi_t / sml_agli_t / vobu_sri_t) and the
// real MiB fixture via tools/nav_extract.py --dsi (byte-exact):
//   dsi_gi @0x00:  nv_pck_scr@00 nv_pck_lbn@04 vobu_ea@08
//                  vobu_1stref_ea@0C  vob_idn u16@18  c_idn u8@1B
//                  c_eltm dvd_time_t(hh mm ss ff, BCD)@1C
//   sml_agli @0xB4: data[9] x {address u32, size u16}  (angle offsets)
//   vobu_sri @0xEA: next_video@EA fwda[19]@EE next_vobu@13A
//                   prev_vobu@13E bwda[19]@142 prev_video@18E
//
// FIT DISCIPLINE (see dvd-iso-navigator / pgc-cell-timeline memories): the
// 19+19 seek-table entries and 9 angle offsets live in ONE sync-read M10K
// (dsi_tbl), never an async register file. Scalars are plain registers.

module nav_dsi (
    input  wire        clk,           // clk_sys
    input  wire        rst_n,         // pipe_rst_n: a load/seek/jump clears state

    // DSI byte stream from ps_demux (accept-always)
    input  wire  [7:0] dsi_byte,
    input  wire        dsi_valid,
    input  wire        dsi_frame_start,

    // ---- parsed scalar fields (registers) ----
    output reg  [31:0] dsi_nv_pck_lbn,   // this VOBU's sector address (LBN)
    output reg  [31:0] dsi_vobu_ea,      // VOBU end address (sectors, rel. to nav pack)
    output reg  [31:0] dsi_1stref_ea,    // end of 1st reference image (I-frame masking)
    output reg  [15:0] dsi_vob_idn,      // VOB id number
    output reg  [7:0]  dsi_c_idn,        // cell id number
    output reg  [31:0] dsi_c_eltm,       // cell elapsed time (BCD: {hh,mm,ss,ff|rate})
    output reg  [31:0] dsi_next_vobu,    // vobu_sri.next_vobu (+1 pointer)
    output reg  [31:0] dsi_prev_vobu,    // vobu_sri.prev_vobu (-1 pointer)
    output reg  [31:0] dsi_next_video,   // vobu_sri.next_video
    output reg  [31:0] dsi_prev_video,   // vobu_sri.prev_video

    // ---- sml_pbi.category (Phase 9, multi-angle ILVU flags) ----
    // category@0x20 (u16 BE). The DSI_ILVU flag nibble (bits 15:12) marks
    // whether this VOBU sits in an interleaved (angle) block and whether it is
    // the last VOBU of an ILVU -- see dvdnav_internal.h:
    //   PRE=1<<15  BLOCK=1<<14  FIRST=1<<13  LAST=1<<12  MASK=0xf000
    // These are exposed for a UI "angle block" indicator and as the golden
    // cross-check for dvd_iso_reader's own NV_PCK peek (which drives the fetch;
    // nav_dsi sits DOWNSTREAM of the reader cache so it LAGS the fetch pointer
    // and must NOT drive the angle jump -- see docs/dvd_nav.md "Multi-angle").
    output reg  [15:0] dsi_category,      // raw sml_pbi.category
    output reg         dsi_ilvu_block,    // category & BLOCK  (in an ILVU block)
    output reg         dsi_ilvu_last,     // (category & 0xF000)==(BLOCK|LAST)
    output reg         dsi_commit,       // 1-cycle pulse: a DSI packet finished parsing

    // ---- seek / angle table read port (Phase 8/9 consumer) ----
    // dsi_tbl map:  0..18 = fwda[0..18], 19..37 = bwda[0..18],
    //               38..46 = sml_agli address[0..8]
    input  wire  [5:0] tbl_raddr,
    output reg  [31:0] tbl_rdata
);

localparam [5:0] BWDA_BASE  = 6'd19;
localparam [5:0] ANGLE_BASE = 6'd38;

// ---- seek/angle table BRAM (sync read + sync write, one M10K) ----
reg [31:0] dsi_tbl [0:63];
reg        tbl_we;
reg [5:0]  tbl_waddr;
reg [31:0] tbl_wdata;
always @(posedge clk) begin
    if (tbl_we) dsi_tbl[tbl_waddr] <= tbl_wdata;
    tbl_rdata <= dsi_tbl[tbl_raddr];
end

// ---- byte walker ----
reg [10:0] idx;                 // DSI data byte index (0 = nv_pck_scr byte 0)
wire [10:0] cur = dsi_frame_start ? 11'd0 : idx;
reg [23:0] facc;                // rolling BE assembly (holds the last 3 bytes)
wire [31:0] acc32 = {facc, dsi_byte};   // BE u32 ending at THIS byte
wire [15:0] acc16 = {facc[7:0], dsi_byte};

// sml_agli region walk (0xB4..0xE9, stride 6 = {addr u32, size u16})
reg [3:0]  agl_i;               // 0..8
reg [2:0]  agl_ph;              // byte phase within the 6-byte entry

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        idx            <= 11'd0;
        facc           <= 24'd0;
        agl_i          <= 4'd0;
        agl_ph         <= 3'd0;
        tbl_we         <= 1'b0;
        tbl_waddr      <= 6'd0;
        tbl_wdata      <= 32'd0;
        dsi_commit     <= 1'b0;
        dsi_nv_pck_lbn <= 32'd0;
        dsi_vobu_ea    <= 32'd0;
        dsi_1stref_ea  <= 32'd0;
        dsi_vob_idn    <= 16'd0;
        dsi_c_idn      <= 8'd0;
        dsi_c_eltm     <= 32'd0;
        dsi_next_vobu  <= 32'd0;
        dsi_prev_vobu  <= 32'd0;
        dsi_next_video <= 32'd0;
        dsi_prev_video <= 32'd0;
        dsi_category   <= 16'd0;
        dsi_ilvu_block <= 1'b0;
        dsi_ilvu_last  <= 1'b0;
    end else begin
        dsi_commit <= 1'b0;     // default: one-cycle pulse
        tbl_we     <= 1'b0;

        if (dsi_valid) begin
            idx  <= cur + 11'd1;
            facc <= {facc[15:0], dsi_byte};

            // ---- scalar fields (captured at the field's LAST byte) ----
            case (cur)
            11'h007: dsi_nv_pck_lbn <= acc32;   // 04..07
            11'h00B: dsi_vobu_ea    <= acc32;   // 08..0B
            11'h00F: dsi_1stref_ea  <= acc32;   // 0C..0F
            11'h019: dsi_vob_idn    <= acc16;   // 18..19
            11'h01B: dsi_c_idn      <= dsi_byte;
            11'h01F: dsi_c_eltm     <= acc32;   // 1C..1F (BCD dvd_time)
            11'h021: begin                       // 20..21 sml_pbi.category (u16 BE)
                dsi_category   <= acc16;
                dsi_ilvu_block <= acc16[14];                         // BLOCK
                dsi_ilvu_last  <= (acc16[15:12] == 4'b0101);         // BLOCK|LAST
            end
            11'h0ED: dsi_next_video <= acc32;   // EA..ED
            11'h13D: dsi_next_vobu  <= acc32;   // 13A..13D
            11'h141: dsi_prev_vobu  <= acc32;   // 13E..141
            11'h191: begin
                dsi_prev_video <= acc32;        // 18E..191
                dsi_commit     <= 1'b1;         // packet parsed through vobu_sri
            end
            default: ;
            endcase

            // ---- fwda[19] @0xEE..0x139  (stride 4, completes at idx==1 mod 4)
            if (cur >= 11'h0EE && cur <= 11'h139 && cur[1:0] == 2'b01) begin
                tbl_we    <= 1'b1;
                tbl_waddr <= (cur - 11'h0F1) >> 2;          // 0..18
                tbl_wdata <= acc32;
            end
            // ---- bwda[19] @0x142..0x18D (stride 4, completes at idx==1 mod 4)
            else if (cur >= 11'h142 && cur <= 11'h18D && cur[1:0] == 2'b01) begin
                tbl_we    <= 1'b1;
                tbl_waddr <= BWDA_BASE + ((cur - 11'h145) >> 2);  // 19..37
                tbl_wdata <= acc32;
            end
            // ---- sml_agli address[9] @0xB4.. (stride 6 = {addr u32, size u16};
            //      the offset we expose is the u32 address, completing at ph==3).
            //      The region's first byte (0xB4) re-inits the sub-walk, so stale
            //      agl_i/agl_ph from the previous packet can't corrupt it.
            else if (cur >= 11'h0B4 && cur <= 11'h0E9) begin
                if (cur == 11'h0B4) begin
                    agl_i  <= 4'd0;
                    agl_ph <= 3'd1;                              // consumed addr byte 0
                end else if (agl_ph == 3'd3) begin
                    tbl_we    <= 1'b1;
                    tbl_waddr <= ANGLE_BASE + {2'd0, agl_i};     // 38..46
                    tbl_wdata <= acc32;                          // address u32
                    agl_ph    <= 3'd4;
                end else if (agl_ph == 3'd5) begin
                    agl_ph <= 3'd0;                              // roll to next entry
                    agl_i  <= agl_i + 4'd1;
                end else
                    agl_ph <= agl_ph + 3'd1;
            end
        end
    end
end

endmodule
