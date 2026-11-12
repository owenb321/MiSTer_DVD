// lin_junction_tb.sv -- the linear-stream junction (issue #188): ps_demux parks on a
// program end code (0xB9) and dvd/lin_junction.sv releases it once the old stream has
// played out. The real ps_demux and the real controller, wired as emu wires them, on
// a synthetic two-segment MPEG-1 system stream:
//
//   segment A: pack (SCR 10 s), video PES (7 x 0xAA), 00 00 01 B9
//   segment B: pack (SCR 0.2 s, a new time base), video PES (7 x 0xBB)
//
// Scored on what the DECODER receives (the video output) and on the controller's
// pulses, never on a state name. Timers are shrunk by parameter (SETTLE 2^4, WD 2^8,
// FLUSH 2^3 cycles). Stimulus is driven with nonblocking assignments, so the DUT
// samples it on a defined edge (a blocking one-cycle blip raced the sampling edge).
//
//   [1] jn_en: the end code emits the still-frame filler, then PARKS -- no B byte
//       reaches the video output, and the demux takes no input, until `go`
//   [2] the junction waits for a CONTINUOUS drain: a drained blip restarts the
//       settle; exactly one `junction`, then `go` after the flush window
//   [3] after `go` segment B reaches the video output intact
//   [4] no second junction after the release (the jn_wait-still-high cycle)
//   [5] a decoder that never drains: the watchdog fires the flush anyway, counted
//   [6] a pipe reset mid-park ends it with no junction
//   [7] jn_en = 0 (DVD cell mode): no park, no filler -- the old demux, byte for byte
//   [8] a 0xB9 whose next pack's SCR runs ON (a CD-i channel ending, the intro's
//       video at sector 4255 while its audio plays on): no park, no filler
//   [9] the same junction in the MPEG-2 pack/PES layout (SVCD, a flat .mpg)
//
// Run: bench/dvd/run_lin_junction.sh [--red]

`timescale 1ns/1ps
`default_nettype none

module lin_junction_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;          // the pipe reset (emu pipe_rst_n)
    logic jn_en = 1;
    logic aud_drained = 0, vbuf_empty = 0;

    // ---- stream ----
    localparam int MAXB = 256;
    logic [7:0] strm [0:MAXB-1];
    int nbytes = 0, fed = 0;
    task automatic put(input logic [7:0] b); strm[nbytes] = b; nbytes++; endtask
    bit mpeg2 = 0;             // pack/PES layout of the next build
    task automatic pack(input logic [32:0] scr);
        put(8'h00); put(8'h00); put(8'h01); put(8'hBA);
        if (!mpeg2) begin      // MPEG-1: 12 bytes
            put({4'b0010, scr[32:30], 1'b1}); put(scr[29:22]); put({scr[21:15], 1'b1});
            put(scr[14:7]); put({scr[6:0], 1'b1});
            put(8'h80); put(8'h00); put(8'h01);
        end else begin         // MPEG-2: 14 bytes, no stuffing
            put({2'b01, scr[32:30], 1'b1, scr[29:28]}); put(scr[27:20]);
            put({scr[19:15], 1'b1, scr[14:13]}); put(scr[12:5]); put({scr[4:0], 1'b1, 2'b00});
            put(8'h01); put(8'h89); put(8'hC3); put(8'hF8);
        end
    endtask
    task automatic vpes(input logic [7:0] fill);   // video PES, no PTS, + 7 bytes
        put(8'h00); put(8'h00); put(8'h01); put(8'hE0);
        if (!mpeg2) begin put(8'h00); put(8'h08); put(8'h0F); end
        else        begin put(8'h00); put(8'h0A); put(8'h80); put(8'h00); put(8'h00); end
        repeat (7) put(fill);
    endtask
    task automatic build(input logic [32:0] scr_a, input logic [32:0] scr_b);
        nbytes = 0;
        pack(scr_a); vpes(8'hAA);
        put(8'h00); put(8'h00); put(8'h01); put(8'hB9);
        pack(scr_b); vpes(8'hBB);
    endtask
    localparam logic [32:0] SCR_A = 33'd900000;   // 10 s
    localparam logic [32:0] SCR_B = 33'd18000;    // 0.2 s: a new time base

    wire       in_ready;
    wire       in_valid = rst_n && (fed < nbytes);
    wire [7:0] in_byte  = strm[fed];
    always @(posedge clk) if (in_valid && in_ready) fed <= fed + 1;

    wire [7:0] vid_byte;
    wire       vid_valid;
    wire       jn_wait, junction, go;
    wire [7:0] timeouts;

    ps_demux demux (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0), .aud_realign(1'b0),
        .sp_track(3'd0), .sp_enable(1'b0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(1'b1), .vid_mark(),
        .aud_byte(), .aud_valid(), .aud_type(), .aud_frame_start(), .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
        .aud_frame_pts(), .aud_frame_pts_valid(),
        .sp_byte(), .sp_valid(), .sp_frame_start(), .sp_pts(), .sp_pts_valid(),
        .pci_enable(1'b0), .pci_byte(), .pci_valid(), .pci_frame_start(),
        .dsi_enable(1'b0), .dsi_byte(), .dsi_valid(), .dsi_frame_start(),
        .aud_lpcm_quant(), .aud_lpcm_nch_m1(), .aud_lpcm_fs96(), .aud_lpcm_bad(),
        .pes_scrambled(), .pes_hdr_ok(), .saw_pack(),
        .jn_en(jn_en), .jn_go(go), .jn_wait(jn_wait)
    );

    lin_junction #(.SETTLE_W(4), .WD_W(8), .FLUSH_W(3)) ctl (
        .clk(clk), .rst_n(rst_n),
        .jn_wait(jn_wait), .aud_drained(aud_drained), .vbuf_empty(vbuf_empty),
        .junction(junction), .go(go), .timeouts(timeouts)
    );

    // ---- what the decoder receives ----
    int n_aa = 0, n_bb = 0, n_zero = 0, n_junc = 0, n_go = 0;
    int bb_before_go = 0;
    always @(posedge clk) if (rst_n) begin
        if (vid_valid) begin
            if (vid_byte === 8'hAA) n_aa++;
            else if (vid_byte === 8'hBB) begin n_bb++; if (n_go == 0) bb_before_go++; end
            else if (vid_byte === 8'h00) n_zero++;
        end
        if (junction === 1'b1) n_junc++;
        if (go === 1'b1) n_go++;
    end

    int errs = 0;
    task automatic check(input bit ok, input string arm, input string msg);
        if (!ok) begin $display("FAIL %s: %s", arm, msg); errs++; end
    endtask
    task automatic restart;
        rst_n <= 0; aud_drained <= 0; vbuf_empty <= 0;
        repeat (3) @(posedge clk);
        fed = 0; n_aa = 0; n_bb = 0; n_zero = 0; n_junc = 0; n_go = 0; bb_before_go = 0;
        rst_n <= 1;
    endtask

    int fed_at_park;
    initial begin
        build(SCR_A, SCR_B);

        // ---- [1] park ----
        jn_en <= 1; restart;
        for (int i = 0; i < 2000 && jn_wait !== 1'b1; i++) @(posedge clk);
        repeat (40) @(posedge clk);
        fed_at_park = fed;
        check(n_aa == 7,          "[1]", $sformatf("segment A reached the decoder: %0d of 7", n_aa));
        check(n_zero == 24,       "[1]", $sformatf("the still-frame filler: %0d of 24 zeros", n_zero));
        check(n_bb == 0,          "[1]", $sformatf("%0d segment-B bytes passed a parked demux", n_bb));
        check(in_ready === 1'b0,  "[1]", "a parked demux must refuse input");
        repeat (20) @(posedge clk);
        check(fed == fed_at_park, "[1]", "the parked demux consumed input");

        // ---- [2] continuous drain, one junction, then go ----
        aud_drained <= 1; vbuf_empty <= 1;
        repeat (8) @(posedge clk);
        vbuf_empty <= 0;                         // a blip: the settle must restart
        @(posedge clk);
        vbuf_empty <= 1;
        repeat (12) @(posedge clk);
        check(n_junc == 0, "[2]", "junction fired before a CONTINUOUS settle");
        for (int i = 0; i < 2000 && n_go == 0; i++) @(posedge clk);
        check(n_junc == 1, "[2]", $sformatf("%0d junction pulses, want 1", n_junc));
        check(timeouts == 0, "[2]", "a clean drain counted as a watchdog timeout");

        // ---- [3] segment B after the release ----
        repeat (60) @(posedge clk);
        check(bb_before_go == 0, "[3]", "segment B reached the decoder before go");
        check(n_bb == 7,         "[3]", $sformatf("segment B after go: %0d of 7", n_bb));
        check(jn_wait === 1'b0,  "[3]", "still parked after go");

        // ---- [4] no re-arm ----
        repeat (200) @(posedge clk);
        check(n_junc == 1 && n_go == 1, "[4]",
              $sformatf("re-armed after the release: %0d junctions, %0d go", n_junc, n_go));

        // ---- [5] watchdog ----
        restart;
        for (int i = 0; i < 2000 && jn_wait !== 1'b1; i++) @(posedge clk);
        aud_drained <= 1; vbuf_empty <= 0;        // the VBUF never empties
        for (int i = 0; i < 2000 && n_go == 0; i++) @(posedge clk);
        check(n_junc == 1,   "[5]", "the watchdog did not fire the junction");
        check(timeouts == 1, "[5]", $sformatf("timeouts=%0d, want 1", timeouts));

        // ---- [6] a pipe reset mid-park ----
        restart;
        for (int i = 0; i < 2000 && jn_wait !== 1'b1; i++) @(posedge clk);
        aud_drained <= 1; vbuf_empty <= 1;
        repeat (5) @(posedge clk);
        rst_n <= 0;
        repeat (3) @(posedge clk);
        rst_n <= 1;
        repeat (60) @(posedge clk);
        check(n_junc == 0, "[6]", "a reset mid-park still fired the junction");
        check(jn_wait === 1'b0, "[6]", "the reset did not end the park");

        // ---- [7] jn_en <= 0: the old demux ----
        jn_en <= 0; restart;
        repeat (200) @(posedge clk);
        check(jn_wait === 1'b0, "[7]", "parked with jn_en low");
        check(n_aa == 7 && n_bb == 7, "[7]", $sformatf("AA %0d BB %0d, want 7/7", n_aa, n_bb));
        check(n_zero == 0, "[7]", $sformatf("%0d filler bytes with jn_en low", n_zero));
        check(n_junc == 0, "[7]", "junction with jn_en low");

        // ---- [8] a 0xB9 whose next pack runs on: not a junction ----
        build(SCR_A, SCR_A + 33'd1170);   // +13 ms, the CD-i intro's video channel end
        jn_en <= 1; restart;
        repeat (300) @(posedge clk);
        check(n_junc == 0 && jn_wait === 1'b0, "[8]", "parked on a 0xB9 the SCR runs on across");
        check(n_aa == 7 && n_bb == 7, "[8]", $sformatf("AA %0d BB %0d, want 7/7", n_aa, n_bb));
        check(n_zero == 0, "[8]", $sformatf("%0d filler bytes on a continuing stream", n_zero));

        // ---- [9] the MPEG-2 layout ----
        // A pair chosen so the layout matters: a true step back of 1.81 s that an
        // MPEG-1 reading of the same bytes sees as a jump FORWARD (no junction).
        mpeg2 = 1;
        build(33'd268586990, 33'd268424514);
        restart;
        for (int i = 0; i < 2000 && jn_wait !== 1'b1; i++) @(posedge clk);
        repeat (10) @(posedge clk);
        check(jn_wait === 1'b1 && n_bb == 0, "[9]", "an MPEG-2 junction did not park before B");
        aud_drained <= 1; vbuf_empty <= 1;
        for (int i = 0; i < 2000 && n_go == 0; i++) @(posedge clk);
        repeat (60) @(posedge clk);
        check(n_junc == 1 && n_bb == 7 && n_zero == 24, "[9]",
              $sformatf("MPEG-2: junc %0d BB %0d zeros %0d, want 1/7/24", n_junc, n_bb, n_zero));
        mpeg2 = 0;

        if (errs == 0) begin
            $display("PASS: lin_junction_tb -- 9 arms");
            $finish;
        end
        $fatal(1, "lin_junction_tb: %0d failure(s)", errs);
    end

    initial begin
        #2000000;
        $fatal(1, "lin_junction_tb TIMEOUT");
    end

endmodule
`default_nettype wire
