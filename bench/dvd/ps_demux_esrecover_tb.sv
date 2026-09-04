// ps_demux_esrecover_tb.sv — issue #48: the raw-elementary-stream verdict must not
// be a one-way door.
//
// ps_demux decides "this is a bare .m2v, not a program stream" from the FIRST start
// code it sees after a pipe reset (S_HUNT, code <= 0xB8 with ever_seen_pack == 0).
// ever_seen_pack is cleared by pipe_rst_n, so that decision is retaken after EVERY
// load_flush -- and a flush does not always land on a pack boundary. The in-place
// mode_switch fallback (dvd/mode_realign.sv) flushes without moving the reader at
// all, so the next byte can easily be mid-PES video payload beginning 00 00 01 B3.
// The demux then latched S_ES_PASS, which used to have no exit, and spent the rest
// of the title shoving PES headers, audio, subpicture and NAV packs at the video
// decoder: a permanently mis-framed picture that no seek and no watchdog recovers.
//
// This bench measures a property of the BYTE STREAM, not a restatement of an RTL
// expression: after a mid-PES reset, does correctly-demuxed video come out again,
// and does the audio path come back at all?
//
// MEASURED against the pre-fix RTL (the S_ES_PASS arm reverted to a bare `;`):
//   [1] video bytes after the next pack   48  (expect 12)   FAIL
//   [1] audio bytes after the next pack    0  (expect  4)   FAIL
// 48 is the whole following pack -- pack header, both PES headers, the audio
// payload and the video payload, all of it handed to the video decoder. 0 audio
// bytes is the sharp end of it: in raw-ES mode nothing is routed to audio at all,
// which is the silent, permanently mis-framed picture users saw.
// [2] is the control and passes either way -- a genuine bare ES must stay in ES mode.
`timescale 1ns/1ps
`default_nettype none

module ps_demux_esrecover_tb;
    logic        clk = 0, rst_n = 0;
    logic  [7:0] in_byte;
    logic        in_valid;
    logic        in_ready;
    logic  [7:0] vid_byte;
    logic        vid_valid;
    logic  [7:0] aud_byte;
    logic        aud_valid;
    logic        vid_ready = 1'b1;

    always #5 clk = ~clk;

    ps_demux dut (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0),
        .vid_byte(vid_byte), .vid_valid(vid_valid), .vid_ready(vid_ready),
        .aud_byte(aud_byte), .aud_valid(aud_valid), .aud_type(), .aud_frame_start(),
        .aud_ready(1'b1),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid()
    );

    // ---------------------------------------------------------------- capture
    logic [7:0] vgot [0:1023];
    logic [7:0] agot [0:1023];
    int vi = 0, ai = 0;
    always_ff @(posedge clk) begin
        if (rst_n && vid_valid && vid_ready) begin vgot[vi] <= vid_byte; vi <= vi + 1; end
        if (rst_n && aud_valid)              begin agot[ai] <= aud_byte; ai <= ai + 1; end
    end

    task automatic feed(input logic [7:0] b);
        begin
            in_byte <= b; in_valid <= 1'b1;
            @(posedge clk);
            while (!in_ready) @(posedge clk);
        end
    endtask

    // Drop in_valid before idling. ⚠ Without this the last byte stays presented
    // with in_valid high and is consumed once per idle cycle -- the bench then
    // counts phantom bytes and every expectation is off by the idle length.
    task automatic idle(input int n);
        begin
            in_valid <= 1'b0;
            repeat (n) @(posedge clk);
        end
    endtask

    // A complete pack: pack header (14 B) + video PES (8 B payload) + audio PES
    // (AC-3 substream 0x80, 4 B frame payload after the 4-byte sub-header).
    task automatic feed_pack;
        int k;
        begin
            // 00 00 01 BA + 9 fixed + stuffing length 0
            feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBA);
            feed(8'h44); feed(8'h00); feed(8'h04); feed(8'h00); feed(8'h04);
            feed(8'h01); feed(8'h00); feed(8'h1B); feed(8'hA3); feed(8'hF8);
            // video PES: len = 3 flags + 0 hdr + 8 payload = 11
            feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hE0);
            feed(8'h00); feed(8'h0B); feed(8'h80); feed(8'h00); feed(8'h00);
            feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hB3);
            feed(8'hDE); feed(8'hAD); feed(8'hBE); feed(8'hEF);
            // audio PES (private_stream_1): len = 3 flags + 0 hdr + 4 sub-hdr + 4 data = 11
            feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hBD);
            feed(8'h00); feed(8'h0B); feed(8'h80); feed(8'h00); feed(8'h00);
            feed(8'h80); feed(8'h01); feed(8'h00); feed(8'h00);       // substream 0x80 + 3
            feed(8'h0B); feed(8'h77); feed(8'hAA); feed(8'hBB);       // AC-3 frame bytes
            k = 0;
        end
    endtask

    int errs = 0;
    int vi_mark, ai_mark;
    int i;

    initial begin
        in_valid = 0; in_byte = 0;
        repeat (4) @(posedge clk);
        rst_n = 1; @(posedge clk);

        // ================================================================= [1]
        // A pipe flush lands MID-PES, on video payload that starts 00 00 01 B3.
        // The demux takes the raw-ES verdict; it must give it back at the next
        // pack instead of keeping it for ever.
        $display("=== [1] mid-PES flush must not latch raw-ES mode for ever ===");
        feed_pack();
        idle(4);

        // the flush: pipe_rst_n drops, ever_seen_pack is cleared
        rst_n = 0; repeat (3) @(posedge clk);
        rst_n = 1; @(posedge clk);

        // resume mid-PES: bare video-layer bytes, no pack in front of them
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hB3);   // -> S_ES_EMIT/S_ES_PASS
        feed(8'h11); feed(8'h22); feed(8'h33); feed(8'h44);
        idle(4);

        vi_mark = vi; ai_mark = ai;

        // the reader delivers the next pack; the demux must re-sync on it
        feed_pack();
        idle(20);

        // 12 = the 4 bytes of the pack start code itself, which raw-ES mode had
        // already forwarded by the cycle the escape fires, then the 8 payload
        // bytes of the re-framed video PES. Leaking 00 00 01 BA is DELIBERATE and
        // is the cheaper of the two options: the first three were sent on earlier
        // cycles, so suppressing only the BA would emit a headless 00 00 01 and
        // the decoder would swallow the next real byte as its code. A complete
        // 0xBA is a system start code the VLD's start-code walk skips.
        $display("    video bytes demuxed after the next pack: %0d (expect 12)", vi - vi_mark);
        $display("    audio bytes demuxed after the next pack: %0d (expect 4)", ai - ai_mark);

        if ((vi - vi_mark) != 12) begin
            $display("FAIL [1]: video did not re-frame -- %0d bytes, not 12", vi - vi_mark);
            errs++;
        end else begin
            if (vgot[vi_mark+0] !== 8'h00 || vgot[vi_mark+1] !== 8'h00 ||
                vgot[vi_mark+2] !== 8'h01 || vgot[vi_mark+3] !== 8'hBA) begin
                $display("FAIL [1]: the leaked prefix is not a whole pack start code");
                errs++;
            end
            if (vgot[vi_mark+4] !== 8'h00 || vgot[vi_mark+5] !== 8'h00 ||
                vgot[vi_mark+6] !== 8'h01 || vgot[vi_mark+7] !== 8'hB3 ||
                vgot[vi_mark+8] !== 8'hDE || vgot[vi_mark+9] !== 8'hAD ||
                vgot[vi_mark+10] !== 8'hBE || vgot[vi_mark+11] !== 8'hEF) begin
                $display("FAIL [1]: video payload wrong after recovery"); errs++;
            end
        end

        // The audio path is the sharper test: in raw-ES mode NOTHING is routed to
        // audio, so a non-zero count can only mean the demuxer really came back.
        if ((ai - ai_mark) != 4) begin
            $display("FAIL [1]: audio did not resume -- %0d bytes, not 4", ai - ai_mark);
            errs++;
        end else if (agot[ai_mark] !== 8'h0B || agot[ai_mark+1] !== 8'h77) begin
            $display("FAIL [1]: audio frame not at its sync word"); errs++;
        end

        // ================================================================= [2]
        // Control: a genuine bare elementary stream must STAY in raw-ES mode.
        // Video start codes are 0x00-0xB8, so 00 00 01 BA cannot occur in one --
        // this is the case the escape must not steal.
        $display("=== [2] control: a real bare ES stays in raw-ES mode ===");
        idle(1);
        rst_n = 0; repeat (3) @(posedge clk);
        rst_n = 1; @(posedge clk);
        vi_mark = vi; ai_mark = ai;

        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hB3);
        for (i = 0; i < 32; i++) feed(8'h5A);
        feed(8'h00); feed(8'h00); feed(8'h01); feed(8'hB8);   // GOP
        for (i = 0; i < 16; i++) feed(8'hA5);
        idle(20);

        $display("    video bytes forwarded: %0d (expect 56 = every byte)", vi - vi_mark);
        $display("    audio bytes forwarded: %0d (expect 0)", ai - ai_mark);
        if ((vi - vi_mark) != 56) begin
            $display("FAIL [2]: raw ES must pass through byte for byte"); errs++;
        end
        if ((ai - ai_mark) != 0) begin
            $display("FAIL [2]: raw ES must route nothing to audio"); errs++;
        end

        $display("=== ps_demux ES-recovery testbench: %0d error(s) ===", errs);
        if (errs) $fatal(1, "ps_demux_esrecover_tb FAILED");
        $display("PASS");
        $finish;
    end

    initial begin
        #4_000_000;
        $fatal(1, "ps_demux_esrecover_tb: timeout");
    end
endmodule

`default_nettype wire
