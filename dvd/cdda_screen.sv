//============================================================================
//  dvd/cdda_screen.sv -- what an audio CD / WAV puts on screen.
//
//  Two pieces of user-facing state, extracted from emu.sv for the usual reason
//  (emu has no bench -- same as flush_ctl, css_detect, dpad_seek):
//
//   viz_mode  0 copper, 1 xor, 2 scope, 3 the idle logo. Angle cycles it; Angle
//             does nothing else on a CD (the angle switch needs cell_ready).
//             Survives a new disc; an OSD Reset returns to copper.
//   hud_show  whether the status line + progress bar are HELD UP. A visualizer
//             hides them (it is the picture), the logo shows them, and Display
//             toggles them in any mode (user request 2026-09-10). Transport
//             events still pop them for a couple of seconds -- that is
//             transport_hud's and seek_bar's own auto-show, untouched here.
//
//  Rules (bench/dvd/cdda_screen_tb.sv):
//   - cycling INTO a visualizer hides the HUD and cycling into the logo shows
//     it: the default follows what is now on screen, instead of carrying a
//     Display press made over a different picture
//   - a new disc (mount) resets hud_show to match the current mode
//   - nothing changes outside cdda_mode -- those buttons belong to the DVD
//============================================================================

`timescale 1ns/1ps
`default_nettype none

module cdda_screen (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       cdda_mode,
    input  wire       angle_edge,
    input  wire       display_edge,
    input  wire       mount,          // start_streaming
    output reg  [1:0] viz_mode,
    output wire       viz_logo,
    output reg        hud_show
);

    assign viz_logo = (viz_mode == 2'd3);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            viz_mode <= 2'd0;
            hud_show <= 1'b0;
        end else begin
            if (cdda_mode && angle_edge) begin
                viz_mode <= viz_mode + 2'd1;
                hud_show <= (viz_mode == 2'd2);      // the NEXT mode is the logo
            end else if (cdda_mode && display_edge) begin
                hud_show <= ~hud_show;
            end
            if (mount)
                hud_show <= viz_logo;
        end
    end

endmodule

`default_nettype wire
