// cdda_screen_tb.sv -- dvd/cdda_screen.sv: visualizer cycle + HUD show/hide.
//
//  [1] reset: copper, HUD hidden
//  [2] outside cdda_mode, Angle and Display change nothing (they belong to the DVD)
//  [3] Angle cycles copper -> xor -> scope -> logo -> copper; the HUD is hidden
//      over every visualizer and SHOWN over the logo
//  [4] Display toggles the HUD over a visualizer AND over the logo
//  [5] a new disc resets the HUD to match the mode, and keeps the mode
//  [6] leaving cdda_mode freezes both
//
// Run: iverilog -g2012 -o /tmp/scr_sim dvd/cdda_screen.sv bench/dvd/cdda_screen_tb.sv
`timescale 1ns/1ps

module cdda_screen_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg cdda = 0, ang = 0, disp = 0, mnt = 0;
    wire [1:0] vm;
    wire       vl, hs;

    cdda_screen dut (.clk(clk), .rst_n(rst_n), .cdda_mode(cdda),
                     .angle_edge(ang), .display_edge(disp), .mount(mnt),
                     .viz_mode(vm), .viz_logo(vl), .hud_show(hs));

    integer errors = 0;
    task chk(input [8*64-1:0] what, input ok);
        if (!ok) begin
            errors = errors + 1;
            $display("  FAIL %0s  (mode=%0d logo=%b hud=%b)", what, vm, vl, hs);
        end else $display("  ok   %0s", what);
    endtask
    task p_ang;  begin @(negedge clk) ang  = 1; @(negedge clk) ang  = 0; end endtask
    task p_disp; begin @(negedge clk) disp = 1; @(negedge clk) disp = 0; end endtask
    task p_mnt;  begin @(negedge clk) mnt  = 1; @(negedge clk) mnt  = 0; end endtask

    initial begin
        repeat (3) @(negedge clk); rst_n = 1; @(negedge clk);
        chk("[1] reset: copper, HUD hidden", vm == 2'd0 && hs == 1'b0);

        p_ang; p_disp;
        chk("[2] outside cdda_mode Angle/Display do nothing", vm == 2'd0 && hs == 1'b0);

        cdda = 1;
        p_ang; chk("[3a] Angle -> xor, HUD hidden",         vm == 2'd1 && hs == 1'b0);
        p_ang; chk("[3b] Angle -> scope, HUD hidden",       vm == 2'd2 && hs == 1'b0);
        p_ang; chk("[3c] Angle -> logo, HUD SHOWN",         vm == 2'd3 && vl && hs == 1'b1);
        p_ang; chk("[3d] Angle wraps to copper, HUD hidden", vm == 2'd0 && !vl && hs == 1'b0);

        p_disp; chk("[4a] Display shows the HUD over a visualizer", hs == 1'b1);
        p_disp; chk("[4b] ...and hides it again",                  hs == 1'b0);
        p_disp;                                                    // shown
        p_mnt;  chk("[5a] new disc re-hides it over a visualizer", hs == 1'b0 && vm == 2'd0);

        p_ang; p_ang; p_ang;                                       // -> logo, shown
        p_disp; chk("[4c] Display hides the HUD over the logo", vm == 2'd3 && hs == 1'b0);
        p_mnt;  chk("[5b] new disc re-shows it over the logo, mode kept", vm == 2'd3 && hs == 1'b1);

        cdda = 0; p_disp; p_ang;
        chk("[6] leaving cdda_mode freezes both", vm == 2'd3 && hs == 1'b1);

        if (errors == 0) $display("CDDA_SCREEN_TB: ALL TESTS PASSED");
        else begin $display("CDDA_SCREEN_TB: FAILED (%0d errors)", errors); $fatal(1); end
        $finish;
    end
endmodule
