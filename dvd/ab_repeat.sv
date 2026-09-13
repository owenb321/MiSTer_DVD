// ============================================================================
// dvd/ab_repeat.sv -- A-B repeat (B17)
// ============================================================================
// Press once to mark A, again to mark B, again to clear. While armed, the
// playhead reaching B jumps back to A.
//
// It issues through scrub_ctrl's EXISTING jump port (base/offset/direction),
// the same one dvd/dpad_seek.sv uses, so the title-span clamp and the single
// proven raw-RBN seek are inherited rather than re-implemented.
//
// ⚠⚠ THE STALE-TABLE TRAP APPLIES HERE VERBATIM, and it is the reason this
// module takes dsi_commit/nav_flush at all. nav_dsi's rst_n is pipe_rst_n, so
// EVERY seek clears dsi_nv_pck_lbn to 0 while the DSI tables keep the previous
// VOBU's contents. A-B repeat seeks by construction -- that is the whole
// feature -- so it spends most of its life in exactly that window:
//   * marking A or B against a stale 0 would store a bogus point, and
//   * comparing the playhead against B while it reads 0 would fire a jump the
//     instant the loop-back seek completed, i.e. an infinite seek storm.
// So both the MARK and the COMPARE require dsi_fresh, set by dsi_commit and
// cleared by nav_flush -- the contract nav_dsi.sv's header records for exactly
// this class of consumer.
//
// ⚠ A second guard on top: after issuing the loop-back jump the module ARMS a
// re-entry lockout until the playhead has actually come back past A, so a
// playhead still reading near B for the few frames before the seek lands
// cannot fire a second jump.
//
// ⛔ Deliberately NOT gated on the OSD's D-Pad Seek bit. That option exists to
// stop the D-PAD fighting a game disc that wants directional input; A-B sits on
// its own dedicated button, which has no such conflict -- the same reasoning
// emu.sv applies to the keyboard Fast Fwd/Rewind keys.
// ============================================================================

`default_nettype none

module ab_repeat (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        ab_edge,          // B17 press
    input  wire        in_title,         // a seekable title is playing
    input  wire [31:0] cur_rbn,          // playhead (VTSTT_VOBS RBN)
    input  wire        dsi_commit,       // 1-cyc: a DSI packet finished parsing
    input  wire        nav_flush,        // load_flush: scalars cleared, tables stale
    input  wire        cancel,           // mount / context change: drop everything

    output reg         jump_fire,        // 1-cyc into scrub_ctrl's jump port
    output reg  [31:0] jump_base,
    output reg  [31:0] jump_off,
    output reg         jump_dir,         // 1 = backward
    output reg  [1:0]  state_o,          // 0 off, 1 A set, 2 armed  (HUD)
    output reg         evt               // 1-cyc: state changed (HUD popup)
);

    localparam [1:0] S_OFF = 2'd0, S_A = 2'd1, S_ARMED = 2'd2;

    reg        dsi_fresh;
    reg [31:0] pt_a, pt_b;
    reg        lockout;                  // waiting for the loop-back to land

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dsi_fresh <= 1'b0;
        end else begin
            if (nav_flush)       dsi_fresh <= 1'b0;
            else if (dsi_commit) dsi_fresh <= 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_o   <= S_OFF;
            pt_a      <= 32'd0;
            pt_b      <= 32'd0;
            lockout   <= 1'b0;
            jump_fire <= 1'b0;
            jump_base <= 32'd0;
            jump_off  <= 32'd0;
            jump_dir  <= 1'b0;
            evt       <= 1'b0;
        end else begin
            jump_fire <= 1'b0;
            evt       <= 1'b0;

            if (cancel || !in_title) begin
                state_o <= S_OFF;
                lockout <= 1'b0;
            end else if (ab_edge) begin
                case (state_o)
                    S_OFF: if (dsi_fresh) begin
                               pt_a    <= cur_rbn;
                               state_o <= S_A;
                               evt     <= 1'b1;
                           end
                    S_A:   // B must be strictly after A, or the "loop" is empty
                           // or inverted; an early second press just re-marks A.
                           if (dsi_fresh) begin
                               if (cur_rbn > pt_a) begin
                                   pt_b    <= cur_rbn;
                                   state_o <= S_ARMED;
                                   lockout <= 1'b0;
                               end else begin
                                   pt_a    <= cur_rbn;
                               end
                               evt <= 1'b1;
                           end
                    default: begin
                               state_o <= S_OFF;
                               lockout <= 1'b0;
                               evt     <= 1'b1;
                           end
                endcase
            end else if (state_o == S_ARMED && dsi_fresh) begin
                if (lockout) begin
                    // clear the lockout once the playhead is genuinely back
                    // inside the loop, not merely because a seek was issued
                    if (cur_rbn < pt_b) lockout <= 1'b0;
                end else if (cur_rbn >= pt_b) begin
                    jump_fire <= 1'b1;
                    jump_base <= cur_rbn;
                    jump_off  <= cur_rbn - pt_a;
                    jump_dir  <= 1'b1;          // backward
                    lockout   <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
