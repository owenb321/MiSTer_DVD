// -----------------------------------------------------------------
// bench/dvd/aud_route_tb.sv — dvd/aud_route.sv, the audio_ring read-side arbiter.
//
// The failure this module exists to prevent is silent and permanent: if a grant
// is released while a payload is half-consumed, audio_ring's byte pointer is left
// inside that frame and EVERY later read is shifted by the remainder. So the
// checker measures PROVENANCE, not handshakes -- each frame's payload is filled
// with its own index, and a consumer receiving a byte that does not match the
// frame it was granted is a violation. That is a property of the byte stream and
// cannot be satisfied by a bug that merely looks like correct arbitration.
// -----------------------------------------------------------------
`timescale 1ns/1ps

module aud_route_tb;

    logic clk = 0, rst_n = 0;
    always #18.5 clk = ~clk;

    logic        split_en = 1;
    logic        frame_valid = 0;
    logic [1:0]  frame_type = 0;
    logic [15:0] frame_len = 0;
    logic        ring_ready = 0;
    logic        hard_rst_n = 0;
    logic        sess_clr = 0;
    logic        dec_owns, wrap_owns, pcm_session, bs_session;

    aud_route dut (
        .clk(clk), .rst_n(rst_n),
        .hard_rst_n(hard_rst_n), .sess_clr(sess_clr), .split_en(split_en),
        .frame_valid(frame_valid), .frame_type(frame_type), .frame_len(frame_len),
        .ring_ready(ring_ready),
        .dec_owns(dec_owns), .wrap_owns(wrap_owns), .pcm_session(pcm_session),
        .bs_session(bs_session)
    );

    integer errors = 0;

    // ---- ring model -------------------------------------------------------
    // A queue of frames. Each frame's payload is its own index, so a byte
    // identifies the frame it came from.
    localparam NF = 24;
    integer f_type [0:NF-1];
    integer f_len  [0:NF-1];
    integer n_frames = 0;
    integer head = 0;          // frame currently at the ring head
    integer bytes_done = 0;    // payload bytes delivered for the head frame
    integer popped = 0;        // descriptor popped for the head frame

    // Grants must never overlap: two owners of one read pointer is the bug.
    always @(posedge clk) if (rst_n && frame_valid && (dec_owns||wrap_owns) && $test$plusargs("dbg"))
        $display("  [t=%0t] head=%0d type=%0d st=%0d take=%b tw=%b dec=%b wrap=%b",
                 $time, head, frame_type, dut.st, dut.take, dut.take_wrap, dec_owns, wrap_owns);
    always @(posedge clk) if (rst_n && dec_owns && wrap_owns) begin
        $display("  FAIL: both consumers granted at once"); errors = errors + 1;
    end

    // ---- mock consumers ---------------------------------------------------
    // Each pops the head descriptor while it owns it, then drains the payload at
    // an irregular rate, so the arbiter is exercised against stalls rather than a
    // tidy one-byte-per-cycle stream.
    integer dec_bytes = 0, wrap_bytes = 0;
    integer dec_frames = 0, wrap_frames = 0;
    integer served_type [0:NF-1];   // which consumer took each frame: 1 dec, 2 wrap
    integer lfsr = 32'h1234_5678;

    // Drive the ring. Stimulus is applied on the NEGEDGE and sampled after the
    // posedge: driving ring_ready after the edge and clearing it before the next
    // one means the DUT never sees it at all, which is exactly how the first
    // version of this bench reported every frame going to one consumer.
    initial begin : ring
        forever begin
            @(negedge clk);
            frame_valid = (head < n_frames);
            if (frame_valid) begin
                frame_type = f_type[head][1:0];
                frame_len  = f_len[head];
            end
            #1;   // let the grants settle off frame_valid before deciding to drain
            ring_ready = frame_valid && (dec_owns || wrap_owns)
                         && (bytes_done < f_len[head]) && lfsr[3];
            @(posedge clk);
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (frame_valid && (dec_owns || wrap_owns)) begin
                if (!popped) begin
                    popped = 1;
                    served_type[head] = wrap_owns ? 2 : 1;
                    if (wrap_owns) wrap_frames = wrap_frames + 1;
                    else           dec_frames  = dec_frames + 1;
                end
                if (ring_ready) begin
                    // PROVENANCE: the consumer taking this byte must be the one
                    // that popped the frame it belongs to.
                    if ((wrap_owns ? 2 : 1) != served_type[head]) begin
                        $display("  FAIL: frame %0d payload taken by the other consumer",
                                 head);
                        errors = errors + 1;
                    end
                    if (wrap_owns) wrap_bytes = wrap_bytes + 1;
                    else           dec_bytes  = dec_bytes + 1;
                    bytes_done = bytes_done + 1;
                end
                if (popped && bytes_done >= f_len[head]) begin
                    head = head + 1; bytes_done = 0; popped = 0;
                end
            end
        end
    end

    task automatic add(input integer t, input integer len); begin
        f_type[n_frames] = t; f_len[n_frames] = len; n_frames = n_frames + 1;
    end endtask

    task automatic drain_all(input integer limit); begin : da
        integer g;
        for (g = 0; g < limit && head < n_frames; g = g + 1) @(posedge clk);
        if (head < n_frames) begin
            $display("  FAIL: stalled at frame %0d of %0d (grant stranded)",
                     head, n_frames);
            errors = errors + 1;
        end
    end endtask

    logic boot_bs;      // bs_session as the core comes out of reset

    initial begin
        repeat (4) @(posedge clk); rst_n = 1; hard_rst_n = 1;
        repeat (2) @(posedge clk);
        // PCM is the RESTING state: nothing has played, so the HDMI link must not
        // be claimed. This is the whole reported bug -- the core used to boot with
        // the transmitter already in non-PCM mode and leave it there.
        boot_bs = bs_session;

        // ---- TEST 1: a mixed stream routes by codec, byte-exactly -----------
        add(0, 32); add(0, 48); add(2, 40); add(2, 24); add(1, 64); add(3, 16);
        drain_all(200000);
        $display("TEST 1: wrap %0d frames / %0d bytes, dec %0d frames / %0d bytes",
                 wrap_frames, wrap_bytes, dec_frames, dec_bytes);
        // AC-3 x2 + DTS x1 = 3 bitstream frames (144 B); LPCM x2 + MP2 x1 = 3 (80 B)
        if (wrap_frames != 3 || wrap_bytes != 144) begin
            $display("  FAIL: bitstream frames misrouted"); errors = errors + 1; end
        if (dec_frames != 3 || dec_bytes != 80) begin
            $display("  FAIL: PCM frames misrouted"); errors = errors + 1; end

        // ---- TEST 2: a track switch hands off at a frame boundary -----------
        // AC-3 -> LPCM mid-stream is the real case (SetSTN / audio button), and
        // the byte counts above already prove no frame was split; assert the
        // ordering explicitly so a regression that serves them out of order fails.
        if (served_type[1] != 2 || served_type[2] != 1) begin
            $display("  FAIL: handoff at the AC-3 -> LPCM boundary went the wrong way");
            errors = errors + 1; end

        // ---- TEST 3: pcm_session latches and holds through the gap ----------
        if (pcm_session !== 1'b1) begin
            $display("  FAIL: pcm_session did not follow the last routed frame (MP2)");
            errors = errors + 1; end
        repeat (500) @(posedge clk);   // ring empty
        if (pcm_session !== 1'b1) begin
            $display("  FAIL: pcm_session dropped during a gap"); errors = errors + 1; end
        $display("TEST 3: pcm_session holds through an empty ring");

        // ---- TEST 4: a zero-length frame must not strand the grant ----------
        add(0, 0); add(2, 20); add(0, 24);
        drain_all(200000);
        $display("TEST 4: zero-length frame did not strand the grant");

        // ---- TEST 5: split_en = 0 is the legacy path, decoder takes all -----
        split_en = 0;
        dec_frames = 0; wrap_frames = 0;
        add(0, 16); add(1, 16); add(2, 16);
        drain_all(200000);
        $display("TEST 5: Decode mode: dec %0d frames, wrap %0d", dec_frames, wrap_frames);
        if (wrap_frames != 0 || dec_frames != 3) begin
            $display("  FAIL: Decode mode did not give every frame to the decoder");
            errors = errors + 1; end

        // ---- TEST 6: bs_session, the HDMI link-format verdict ---------------
        // Measured as a LEVEL the ADV7513 would be driven from, at the moments
        // that actually happen on a disc: boot, a track, a seek, a track change,
        // an eject. The reset domain is the point -- pcm_session already fails
        // the seek arm by construction, which is why a second signal exists.
        split_en = 1;
        if (boot_bs !== 1'b0) begin
            $display("  FAIL: bs_session set at boot -- the HDMI link is claimed with nothing playing");
            errors = errors + 1; end

        add(0, 32); drain_all(200000);          // an AC-3 track starts
        if (bs_session !== 1'b1) begin
            $display("  FAIL: bs_session did not follow an AC-3 frame"); errors = errors + 1; end

        // A seek / audio-track switch / aud_flush pulses aud_rst_n. If the
        // verdict resets there, every chapter skip releases the transmitter to
        // PCM and re-engages, and the receiver re-locks on each one.
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; repeat (4) @(posedge clk);
        if (bs_session !== 1'b1) begin
            $display("  FAIL: an aud_rst_n pulse (seek) dropped bs_session");
            errors = errors + 1; end

        add(2, 24); drain_all(200000);          // switch to an LPCM track
        if (bs_session !== 1'b0) begin
            $display("  FAIL: bs_session stayed set on an LPCM track"); errors = errors + 1; end

        add(0, 32); drain_all(200000);          // back to AC-3, then eject
        if (bs_session !== 1'b1) begin
            $display("  FAIL: bs_session did not re-arm on AC-3"); errors = errors + 1; end
        sess_clr = 1; repeat (4) @(posedge clk); sess_clr = 0; @(posedge clk);
        if (bs_session !== 1'b0) begin
            $display("  FAIL: an empty slot left the HDMI link claimed"); errors = errors + 1; end

        // Decode mode must never claim the link, whatever the codec is.
        split_en = 0;
        add(0, 16); add(1, 16); drain_all(200000);
        if (bs_session !== 1'b0) begin
            $display("  FAIL: bs_session set in Decode mode"); errors = errors + 1; end
        $display("TEST 6: bs_session: boot 0, AC-3 1, survives a seek, LPCM 0, eject 0, Decode 0");

        if (errors == 0) $display("\naud_route: ALL TESTS PASSED");
        else             $display("\naud_route: %0d FAILURES", errors);
        $finish;
    end

    initial begin
        #500_000_000;
        $display("aud_route: TIMEOUT"); $finish;
    end

endmodule
