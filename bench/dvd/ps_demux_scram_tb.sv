// ps_demux_scram_tb.sv — CSS-scramble marker detection (pes_scrambled/pes_hdr_ok).
//
// A CSS-encrypted rip carries PES_scrambling_control != 0 (bits [5:4] of the first
// PES-flags byte — that byte itself is never scrambled). ps_demux pulses
// pes_scrambled once per such PES, and pes_hdr_ok once per CHECKABLE PES header
// (scrambled or not) as the denominator dvd/css_detect.sv divides into it.
//
// ★ WHAT THIS BENCH IS FOR (issue #59). The old version fed ONE pack followed by
// FOUR PES packets and asserted "exactly 2 pulses". That stimulus is not DVD: a
// DVD pack is 2048 bytes and carries exactly ONE checkable PES, so the old bench
// could not distinguish "a marker on a real pack" from "a marker on something the
// demux found while it had lost framing" -- which is how a clean disc came to show
// CSS ENCRYPTED and lose all audio. T2/T4 are that distinction, and they FAIL
// against the pre-fix RTL on purpose (bench/dvd/run_css.sh --red).
//
// Arms:
//   T1 four packs, one PES each: clean E0, scrambled E0, scrambled BD, clean BD
//   T2 the OLD stimulus verbatim (one pack, four PES) -- only the first counts
//   T3 a false start code inside a payload the length field covers -> invisible
//   T4 a PES that ends early, then planted false headers in the same pack, then a
//      genuine pack + scrambled E0 -- the desync case: 0 during garbage, 1 after
//   T5 a NAV pack's BB/BF/BF do not consume the pack's arm
//   T6 MP2 C0-C7: the selected track is checkable, an unselected one is not
//   T8 a bad '10' marker pulses neither output
//   T7 runs continuously: pes_scrambled implies pes_hdr_ok, totals ordered
`timescale 1ns/1ps
`default_nettype none

module ps_demux_scram_tb;
    logic        clk = 0, rst_n = 0;
    logic  [7:0] in_byte;
    logic        in_valid;
    logic        in_ready;
    logic        scram;
    logic        hdr_ok;
    logic  [2:0] aud_track = 3'd0;

    always #5 clk = ~clk;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(aud_track),
        .vid_byte(), .vid_valid(), .vid_ready(1'b1),
        .aud_byte(), .aud_valid(), .aud_type(), .aud_frame_start(), .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
`ifndef NO_HDR_OK
        .pes_hdr_ok(hdr_ok),
`endif
        .pes_scrambled(scram)
    );
`ifdef NO_HDR_OK
    assign hdr_ok = 1'b0;          // pre-fix RTL has no denominator to connect
`endif

    // ---------------- instruments ----------------
    int pulses = 0, hdrs = 0, fails = 0;
    always_ff @(posedge clk) if (rst_n) begin
        if (scram)  pulses <= pulses + 1;
        if (hdr_ok) hdrs   <= hdrs   + 1;
        // [T7] the numerator can never fire without the denominator
        if (scram && !hdr_ok) begin
`ifndef NO_HDR_OK
            $display("FAIL [T7]: pes_scrambled without pes_hdr_ok");
            fails <= fails + 1;
`endif
        end
    end

    // ---------------- stimulus builder ----------------
    logic [7:0] stim [0:1023];
    int n = 0;
    int base_p, base_h;

    task push(input [7:0] b); begin stim[n] = b; n = n + 1; end endtask

    // A DVD pack header: 00 00 01 BA, 9 bytes (top nibble 0100 = MPEG-2), stuffing 0.
    task push_pack; begin
        push(8'h00); push(8'h00); push(8'h01); push(8'hBA);
        repeat (9) push(8'h44);
        push(8'h00);
    end endtask

    // A PES with no optional header and `pay` payload bytes of 8'hA5.
    task push_pes(input [7:0] sid, input [7:0] flags1, input int pay);
        int len; begin
        len = 3 + pay;
        push(8'h00); push(8'h00); push(8'h01); push(sid);
        push(len[15:8]); push(len[7:0]);
        push(flags1); push(8'h00); push(8'h00);
        repeat (pay) push(8'hA5);
    end endtask

    // private_stream_1: substream id + 3 AC-3 sub-header bytes, then `pay` payload.
    task push_pes_bd(input [7:0] flags1, input int pay);
        int len; begin
        len = 3 + 4 + pay;
        push(8'h00); push(8'h00); push(8'h01); push(8'hBD);
        push(len[15:8]); push(len[7:0]);
        push(flags1); push(8'h00); push(8'h00);
        push(8'h80); push(8'h01); push(8'h00); push(8'h01);
        repeat (pay) push(8'hA5);
    end endtask

    // A PES header pattern planted as raw bytes -- no payload follows it here, so
    // whether it is ever parsed depends entirely on where the demux is looking.
    task push_fake_hdr(input [7:0] sid, input [7:0] flags1); begin
        push(8'h00); push(8'h00); push(8'h01); push(sid);
        push(8'h00); push(8'h03);
        push(flags1); push(8'h00); push(8'h00);
    end endtask

    task send;
        int i; begin
        for (i = 0; i < n; i++) begin
            in_byte  <= stim[i];
            in_valid <= 1'b1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
        end
        in_valid <= 1'b0;
        repeat (20) @(posedge clk);
    end endtask

    task start_arm; begin n = 0; base_p = pulses; base_h = hdrs; end endtask

    task check(input string name, input int exp_p, input int exp_h);
        int gp, gh; begin
        gp = pulses - base_p;
        gh = hdrs   - base_h;
        $display("  %-38s pulses=%0d (exp %0d)  hdr_ok=%0d (exp %0d)",
                 name, gp, exp_p, gh, exp_h);
        if (gp !== exp_p) begin
            $display("  FAIL %s: pes_scrambled %0d, expected %0d", name, gp, exp_p);
            fails = fails + 1;
        end
`ifndef NO_HDR_OK
        if (gh !== exp_h) begin
            $display("  FAIL %s: pes_hdr_ok %0d, expected %0d", name, gh, exp_h);
            fails = fails + 1;
        end
`endif
    end endtask

    initial begin
        in_valid = 0; in_byte = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        $display("=== ps_demux CSS-scramble marker detection ===");

        // ---- T1: DVD-shaped. One PES per pack; two of the four are scrambled.
        start_arm;
        push_pack; push_pes(8'hE0, 8'h80, 4);      // clean video
        push_pack; push_pes(8'hE0, 8'hB0, 4);      // scrambled video  (sc=11)
        push_pack; push_pes_bd(8'h90, 2);          // scrambled audio  (sc=01)
        push_pack; push_pes_bd(8'h80, 2);          // clean audio
        send; check("T1 one PES per pack", 2, 4);

        // ---- T2: the OLD stimulus. Four PES crammed into one pack -- only the
        // first can carry a genuine CSS marker, so the two later "scrambled"
        // headers must be ignored. RED against the pre-fix RTL (it counts 2).
        start_arm;
        push_pack;
        push_pes(8'hE0, 8'h80, 4);
        push_pes(8'hE0, 8'hB0, 4);
        push_pes_bd(8'h90, 2);
        push_pes_bd(8'h80, 2);
        send; check("T2 four PES in one pack", 0, 1);

        // ---- T3: a false start code sitting INSIDE a payload the length field
        // covers. Framing holds, so the demux never looks at it.
        start_arm;
        push_pack;
        n = n;                                     // build the PES by hand
        push(8'h00); push(8'h00); push(8'h01); push(8'hE0);
        push(8'h00); push(8'h0C);                  // len 12 = 3 + 9 payload
        push(8'h80); push(8'h00); push(8'h00);
        push(8'h00); push(8'h00); push(8'h01); push(8'hE0);   // planted, as payload
        push(8'h00); push(8'h07); push(8'hB0); push(8'h00); push(8'h00);
        push(8'hA5);
        send; check("T3 false header inside payload", 0, 1);

        // ---- T4: the desync. The real PES ends early, the demux returns to
        // S_HUNT inside the same pack and finds planted headers there. Post-fix
        // the pack's arm is already spent, so none of them can score; the
        // genuine pack that follows still does. RED pre-fix (it counts 2 then 3).
        start_arm;
        push_pack;
        push_pes(8'hE0, 8'h80, 2);                 // real, clean, ends here
        push_fake_hdr(8'hE0, 8'hB0);               // planted scrambled video
        push_fake_hdr(8'hBD, 8'h90);               // planted scrambled audio
        // hdr_ok is 1, not 0: the pack's own clean E0 is a legitimate checkable
        // header and belongs in the denominator. It is the two PLANTED headers
        // that must score nothing -- pre-fix they scored 2.
        send; check("T4 planted headers after a PES", 0, 1);
        start_arm;
        push_pack; push_pes(8'hE0, 8'hB0, 4);      // a genuine one still scores
        send; check("T4b genuine pack after the garbage", 1, 1);

        // ---- T5: a NAV pack's non-checkable packets must not consume the arm.
        start_arm;
        push_pack;
        push_fake_hdr(8'hBB, 8'h00);               // system header
        push_fake_hdr(8'hBF, 8'h00);               // PCI
        push_fake_hdr(8'hBF, 8'h00);               // DSI
        push_pes(8'hE0, 8'hB0, 4);                 // scrambled video, same pack
        send; check("T5 BB/BF/BF do not disarm", 1, 1);

        // ---- T6: MP2. Only the SELECTED track reaches the flags byte.
        aud_track = 3'd1;
        start_arm;
        push_pack; push_pes(8'hC1, 8'hB0, 4);      // selected   -> checkable
        send; check("T6a MP2 selected track", 1, 1);
        start_arm;
        push_pack; push_pes(8'hC2, 8'hB0, 4);      // unselected -> skipped
        send; check("T6b MP2 unselected track", 0, 0);
        aud_track = 3'd0;

        // ---- T8: marker bits are still load-bearing.
        start_arm;
        push_pack; push_pes(8'hE0, 8'h30, 4);      // marker '00', sc=11
        send; check("T8 bad '10' marker", 0, 0);

        // ---- T7 totals
        $display("  totals: pes_scrambled=%0d pes_hdr_ok=%0d", pulses, hdrs);
`ifndef NO_HDR_OK
        if (pulses > hdrs) begin
            $display("  FAIL [T7]: more markers than checkable headers");
            fails = fails + 1;
        end
`endif

        if (fails != 0) begin
            $display("FAIL: %0d check(s) failed", fails);
            $fatal(1);
        end
        $display("PASS: markers scored only on the first checkable PES of a pack");
        $finish;
    end
endmodule
`default_nettype wire
