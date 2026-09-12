//============================================================================
//  dvd/cdda_screen.sv -- what an audio CD / WAV puts on screen.
//
//  Two pieces of user-facing state, extracted from emu.sv for the usual reason
//  (emu has no bench -- same as flush_ctl, css_detect, dpad_seek):
//
//   viz_mode  0 the bouncing idle logo, 1 copper bars. Angle cycles the two;
//             Angle does nothing else on a CD (the angle switch needs
//             cell_ready). Survives a new disc; an OSD Reset returns to 0.
//             ★ THE LOGO IS MODE 0 AND THEREFORE THE DEFAULT (user decision
//             2026-09-12): a CD boots to the logo and Angle opts INTO the
//             visualizer. Numbering it this way, rather than resetting a
//             copper-is-0 register to 1, keeps "reset value = default" true.
//   hud_show  whether the status line + progress bar are HELD UP. The
//             visualizer hides them (it is the picture), the logo shows them,
//             and Display toggles them in either mode (user request
//             2026-09-10). It therefore resets SHOWN, matching the logo.
//             Transport events still pop the HUD for a couple of seconds --
//             that is transport_hud's and seek_bar's own auto-show, untouched.
//
//  ⛔ THE CYCLE HAS SHRUNK TWICE, and the wrap is load-bearing each time. It was
//  four stops (copper / xor / scope / logo), then three when the scope went
//  (2026-09-11), and is now TWO after the XOR pattern went as well (2026-09-12)
//  -- both on logic-budget grounds. viz_mode is still 2 bits because emu passes
//  it straight through, so it MUST be wrapped explicitly: letting the counter
//  roll on its width would leave dead modes 2 and 3 in the cycle and Angle would
//  land on a blank screen, which reads as the player having hung.
//
//  Rules (bench/dvd/cdda_screen_tb.sv):
//   - cycling INTO the visualizer hides the HUD and cycling into the logo shows
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

    assign viz_logo = (viz_mode == 2'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            viz_mode <= 2'd0;           // the logo: the default screen
            hud_show <= 1'b1;           // ...and the HUD shows over it
        end else begin
            if (cdda_mode && angle_edge) begin
                viz_mode <= (viz_mode == 2'd0) ? 2'd1 : 2'd0;
                hud_show <= (viz_mode == 2'd1);      // the NEXT mode is the logo
            end else if (cdda_mode && display_edge) begin
                hud_show <= ~hud_show;
            end
            if (mount)
                hud_show <= viz_logo;
        end
    end

endmodule

`default_nettype wire
