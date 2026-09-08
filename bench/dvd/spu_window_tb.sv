// =============================================================================
// bench/dvd/spu_window_tb.sv — SPU DISPLAY-ORDER commit (PR #63 regression gate)
// =============================================================================
// PR #63 moved the STC from a parse-front clock that LED the display by the VBUF
// depth onto the displayed picture itself. spu_decode was not touched, but its
// `stc` input changed meaning: a subpicture unit arriving at the parse front now
// commits a show window ~a VBUF depth in the FUTURE, and because there is a single
// bitmap the arriving unit destroys the one on screen before its authored window
// has expired.
//
// What this bench measures is what the SCREEN gets — `sp_active`, sampled every
// tick — never a signal the fix names, so it cannot become a golden model that
// agrees with its RTL by construction.
//
//   [A] THE REPORTED DEFECT, to the disc's own numbers. The Matrix's "Follow the
//       White Rabbit" icon: MEASURED as one FSTA_DSP at PTS 101885 and one STP_DSP
//       at 866659 (8.4975 s), with the same unit re-sent BYTE-IDENTICALLY 8 times,
//       90090 ticks (1.001 s) apart, and NO intermediate stop. A conforming player
//       shows one unbroken icon. RED: the icon blinks once per re-send.
//   [B] SUBTITLES, the same bug quietly truncating every line: an authored gap
//       between two lines must be preserved — line A must keep its full window
//       instead of being blanked when line B arrives early.
//   [C] THE HOLD'S BOUND IS A PROMISE: a unit arriving no sooner than the hold
//       bound after the previous one is never lost. (Real subtitle units are never
//       closer than 1034 ms — n=36, median 2369 ms — which is why the bound is set
//       below that.)
//   [D] CONTROL: an authored gap that is genuinely long must still go dark. A fix
//       that simply never blanks would pass [A] and [B] and be wrong.
//
// 1 STC tick per clock here (the real ratio is clk_sys/300) so a 1 s VBUF lead is
// 90k cycles rather than 27 M; HOLD_CYCLES is scaled to match (700 ms in ticks).
// =============================================================================
`timescale 1ns/1ps
module spu_window_tb;

    // ---- scaled timing -------------------------------------------------------
    localparam int TICK_HOLD = 63000;      // 700 ms in 90 kHz ticks = the real bound
    localparam int LEAD      = 90000;      // 1 s VBUF lead (parse front vs display)
    localparam int RESEND    = 90090;      // 1.001 s — the disc's measured re-send period
    localparam int GAP       = 30000;      // 0.33 s authored gap between subtitle lines.
                                           // Deliberately SHORTER than LEAD, so line B
                                           // arrives while line A is still on screen —
                                           // if it arrived after A had expired the arm
                                           // would pass against broken RTL.
    localparam int DUR_A     = 184320;     // 180<<10 ticks ~ 2.05 s: line A's window
    localparam logic [32:0] P0 = 33'd101885;   // the disc's own first icon PTS

    logic clk=0, rst_n=0;
    always #5 clk=~clk;

    logic [7:0]  sp_byte = 8'd0;
    logic        sp_valid=0, sp_frame_start=0, sp_pts_valid=0;
    logic [32:0] sp_pts = 0;
    logic [32:0] stc = 0;
    logic        enable = 1'b1, menu_mode = 1'b0;
    logic [11:0] q_x=0, q_y=0;
    wire  [1:0]  q_idx;  wire q_inside, sp_active;
    wire [3:0]   alpha0, alpha1, alpha2, alpha3, col0, col1, col2, col3;

    spu_decode #(.HOLD_CYCLES(TICK_HOLD)) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .interlaced(1'b0),
        .menu_mode(menu_mode),
        .sp_byte(sp_byte), .sp_valid(sp_valid), .sp_frame_start(sp_frame_start),
        .sp_pts(sp_pts), .sp_pts_valid(sp_pts_valid),
        .stc(stc), .q_x(q_x), .q_y(q_y), .q_idx(q_idx), .q_inside(q_inside),
        .alpha0(alpha0), .alpha1(alpha1), .alpha2(alpha2), .alpha3(alpha3),
        .col0(col0), .col1(col1), .col2(col2), .col3(col3),
        .sp_active(sp_active)
    );

    // the display clock: one 90 kHz tick per cycle (see the header)
    logic stc_run = 1'b0;
    always @(posedge clk) if (stc_run) stc <= stc + 33'd1;

    int errors = 0;

    // ---- synthetic SPU builder ----------------------------------------------
    // Minimal but format-real: 2 lines of "fill to end of line" RLE (four zero
    // nibbles) and a DCSQ carrying STA_DSP + SET_DAREA + SET_DSPXA, optionally a
    // second DCSQ carrying STP_DSP at a delay. Only visibility is under test, so
    // the bitmap content is deliberately trivial.
    byte unsigned spu [0:255];
    int spu_len;
    task automatic mk_spu(input bit has_stp, input int stp_delay);
        int p, dcsq0, dcsq1;
        begin
            spu[4]=8'h00; spu[5]=8'h00;          // top-field RLE    -> fill line
            spu[6]=8'h00; spu[7]=8'h00;          // bottom-field RLE -> fill line
            dcsq0 = 8;
            spu[2]=dcsq0[15:8]; spu[3]=dcsq0[7:0];
            p = dcsq0 + 4;                        // after delay(2) + next(2)
            spu[p]=8'h01; p++;                                     // STA_DSP
            spu[p]=8'h05; p++;                                     // SET_DAREA 0..15 x 0..1
            spu[p]=8'h00; p++; spu[p]=8'h00; p++; spu[p]=8'h0F; p++;
            spu[p]=8'h00; p++; spu[p]=8'h00; p++; spu[p]=8'h01; p++;
            spu[p]=8'h06; p++;                                     // SET_DSPXA top=4 bot=6
            spu[p]=8'h00; p++; spu[p]=8'h04; p++;
            spu[p]=8'h00; p++; spu[p]=8'h06; p++;
            spu[p]=8'hFF; p++;                                     // end of this DCSQ
            if (!has_stp) begin
                spu[dcsq0]=8'h00; spu[dcsq0+1]=8'h00;              // delay 0
                spu[dcsq0+2]=dcsq0[15:8]; spu[dcsq0+3]=dcsq0[7:0]; // next == self => end
            end else begin
                dcsq1 = p;
                spu[dcsq0]=8'h00; spu[dcsq0+1]=8'h00;
                spu[dcsq0+2]=dcsq1[15:8]; spu[dcsq0+3]=dcsq1[7:0];
                // DCSQ delay is in 1/90000 s units scaled by 1024 (spu_decode: <<10)
                spu[dcsq1]   = (stp_delay >> 8) & 8'hFF;
                spu[dcsq1+1] =  stp_delay       & 8'hFF;
                spu[dcsq1+2] = dcsq1[15:8]; spu[dcsq1+3] = dcsq1[7:0];  // next == self
                p = dcsq1 + 4;
                spu[p]=8'h02; p++;                                 // STP_DSP
                spu[p]=8'hFF; p++;
            end
            spu_len = p;
            spu[0]=spu_len[15:8]; spu[1]=spu_len[7:0];             // SPDSZ
        end
    endtask

    task automatic feed(input logic [32:0] ptsval);
        for (int i=0;i<spu_len;i++) begin
            @(negedge clk);
            sp_byte = spu[i]; sp_valid = 1'b1;
            sp_frame_start = (i==0);
            sp_pts = ptsval; sp_pts_valid = (i==0);
        end
        @(negedge clk); sp_valid=0; sp_frame_start=0; sp_pts_valid=0;
    endtask

    // run the display clock until it reaches `target`, watching sp_active
    int    act_falls, act_rises; logic act_prev; logic saw_active;
    logic  watch_en;
    always @(posedge clk) begin
        if (watch_en) begin
            if ( act_prev && !sp_active) act_falls++;
            if (!act_prev &&  sp_active) act_rises++;
            if (sp_active) saw_active <= 1'b1;
            act_prev <= sp_active;
        end
    end
    task automatic watch_reset; begin
        act_falls=0; act_rises=0; saw_active=0; act_prev=sp_active; watch_en=1'b1;
    end endtask
    task automatic run_to(input logic [32:0] target);
        begin stc_run = 1'b1; while (stc < target) @(posedge clk); end
    endtask

    initial begin
        watch_en = 0; act_prev = 0;
        repeat (4) @(posedge clk); rst_n = 1;

        // =====================================================================
        // [A] the white-rabbit re-send chain, to the disc's measured numbers
        // =====================================================================
        stc = P0 - LEAD; stc_run = 1'b0;
        mk_spu(1'b0, 0);                                   // persistent: no STP_DSP
        feed(P0);                                          // unit 0, a lead early
        run_to(P0);                                        // its authored show time
        if (!sp_active) begin
            $display("  FAIL [A] icon never appeared at its authored PTS"); errors++;
        end
        watch_reset();
        for (int k=1; k<8; k++) begin                      // units 1..7, identical
            run_to(P0 + (k*RESEND) - LEAD);
            feed(P0 + (k*RESEND));
            run_to(P0 + (k*RESEND));
        end
        run_to(P0 + (8*RESEND));
        if (act_falls != 0) begin
            $display("  FAIL [A] icon BLINKED %0d times across 7 identical re-sends (authored: one solid 8.5 s display)", act_falls); errors++;
        end else
            $display("  [A] white-rabbit re-send chain: icon SOLID across 7 re-sends");

        // =====================================================================
        // [B] a subtitle's authored window survives the next line arriving early
        // =====================================================================
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1;
        stc_run = 1'b0; stc = 33'd1_000_000;
        begin : arm_b
            logic [32:0] pa, pb; int dur_a;
            pa = 33'd1_100_000;
            dur_a = 180;                                   // 180<<10 = DUR_A ticks
            pb = pa + DUR_A + GAP;                         // an authored gap after A
            mk_spu(1'b1, dur_a);
            feed(pa);                                      // A arrives a lead early
            run_to(pa + 33'd10);
            if (!sp_active) begin
                $display("  FAIL [B] line A never showed"); errors++; end
            // B arrives a full lead before its own show time, while A is still up.
            // ⚠ ARM THE WATCHER BEFORE FEEDING B. The blank this arm exists to catch
            // happens AT B's commit, so a watch_reset() afterwards samples an already
            // -low sp_active and the arm passes against broken RTL -- which is exactly
            // what run_spu_window.sh's red-hold arm reported the first time.
            run_to(pb - LEAD);
            watch_reset();
            mk_spu(1'b1, dur_a);
            feed(pb);
            run_to(pa + DUR_A - 33'd200);                  // still inside A's window
            if (!sp_active) begin
                $display("  FAIL [B] line A is dark inside its own authored window"); errors++;
            end
            if (act_falls != 0) begin
                $display("  FAIL [B] line A was blanked %0d times early by B's arrival", act_falls); errors++;
            end else
                $display("  [B] subtitle A kept its authored window despite B arriving early");
        end

        // =====================================================================
        // [D] CONTROL: the authored gap must still go dark
        // =====================================================================
        run_to(33'd1_100_000 + DUR_A + (GAP/2));
        if (sp_active) begin
            $display("  FAIL [D] the authored gap after A did not go dark (a fix that never blanks is not a fix)"); errors++;
        end else
            $display("  [D] authored gap between the two lines still goes dark");
        run_to(33'd1_100_000 + DUR_A + GAP + 33'd10);
        if (!sp_active) begin
            $display("  FAIL [D] line B never showed at its authored time"); errors++;
        end else
            $display("  [D] line B appeared at its authored time");

        // =====================================================================
        // [C] the hold's bound is a promise: a unit arriving >= the bound after
        //     the previous one is never lost
        // =====================================================================
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1;
        stc_run = 1'b0; stc = 33'd2_000_000;
        begin : arm_c
            logic [32:0] pc, pd;
            pc = 33'd2_100_000;
            pd = pc + TICK_HOLD + 33'd2000;                // just past the bound
            mk_spu(1'b0, 0);
            feed(pc);
            run_to(pd - LEAD);
            mk_spu(1'b0, 0);
            feed(pd);
            run_to(pd + 33'd2000);
            if (dut.c_pts !== pd) begin
                $display("  FAIL [C] the second unit was LOST (c_pts=%0d, expected %0d)", dut.c_pts, pd); errors++;
            end else
                $display("  [C] a unit arriving past the hold bound is not lost");
        end

        if (errors==0) $display("RESULT: PASS (spu_window)");
        else           $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin #400_000_000; $display("RESULT: FAIL timeout"); $finish; end
endmodule
