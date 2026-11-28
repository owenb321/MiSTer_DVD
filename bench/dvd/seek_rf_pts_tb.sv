//============================================================================
//  seek_rf_pts_tb.sv -- DOES A SEEK HAND THE AUDIO GATE THE OLD TIMELINE'S PTS?
//
//  Field report (2026-09-30, Men in Black, D-pad Seek): after about one backward
//  gesture in six, the picture holds ~1.2 s and audio is silent ~2.5 s. Telemetry:
//  audio never takes its scheduled release; the ring fills, backpressure starves
//  the video, and the ~2.5 s arm_timer fallback releases it with play_err reading
//  the landing ~19 s BEHIND the latched play_pts -- i.e. the latch held a PTS from
//  BEFORE the -20 s seek (docs/dvd_nav.md §2h "The stale audio PTS").
//
//  Mechanism. The three reframers reset on the core reset and an audio-track
//  switch only -- a seek never resets them. ac3_reframer emits a frame start on the
//  0x77 of its sync word, stamped with the pending PES PTS; dts_reframer then holds
//  that start (and the PTS) in its 4-byte pipeline until four more audio bytes push
//  it out. On MiB's title 12.5 % of AC-3 packs end EXACTLY 3 bytes after a sync, so
//  when the flush lands after such a pack the old frame start is still inside the
//  pipeline. The ring and decoder are reset, the reframers are not; the landing's
//  first bytes push the old start out, and the fresh ring commits it as its FIRST
//  frame -- stamped with the old PTS, filled with landing bytes. The decoder
//  latches that as play_pts. Backward, it is ~20 s in the future: no release.
//
//  This bench runs the real front half of emu's audio path:
//
//    ps_demux -> ac3_reframer -> dts_reframer -> mp2_reframer -> audio_ring
//      (pipe_rst_n)   (rf_rst_n: core reset + track switch [+ fix: seek flush])
//                                                            (aud_rst_n)
//  with flush_ctl turning a seek_ack into emu's reset pulses. Stream A (the old
//  position) ends N bytes past a frame sync, N swept; the seek flushes; stream B
//  (the landing, every PTS 20 s EARLIER) follows. Every frame the consumer pops
//  after the flush is scored against the decoder's contract:
//    [1] the first one is the landing's first whole frame (0B 77, B's tag)
//    [2] no frame carries a PTS outside B's timeline (the stale latch)
//    [3] the first PTS-tagged one carries B's first PTS exactly
//    [4] non-vacuous: >= 2 frames and a PTS-tagged one arrived after the flush
//
//  Second half of the fix: with the reframers reset, ac3_reframer is UNLOCKED and
//  takes the first 0B77 it sees. The landing's first audio PES starts with the tail
//  of a frame begun before it; a stray in-payload 0B77 there becomes a garbage first
//  frame (a click). So emu also hands ps_demux one aud_realign cycle when it leaves
//  the flush's reset (dmx_rlgn_go), and the demux skips that PES to its
//  first_access_unit_pointer -- the track-switch path. Stream B's tail carries such
//  a stray sync here, so [1] checks it.
//
//  Arms (plusargs):  default = the fix (a registered aud_flush on rf_rst_n, and the
//                    demux realign armed by a hard flush)
//    +PRE     emu's wiring before the fix (neither)             -> [1] [2] [3]
//    +NORLGN  reframers reset, demux realign NOT armed          -> [1] only
//    +RESYNC  the reframer clear keyed to aud_resync, not aud_flush (a seek pulses
//             aud_flush only)                                   -> [2] [3]
//    +NOB     stream B is never sent (proves [4] can fail)      -> [4] only
//
//  iverilog -g2012 -o .sim/seek_rf_pts/sim dvd/ps_demux.sv dvd/ac3_reframer.sv \
//      dvd/dts_reframer.sv dvd/mp2_reframer.sv dvd/flush_ctl.sv dvd/audio_ring.sv \
//      bench/dvd/seek_rf_pts_tb.sv
//  Runner: bench/dvd/run_seek_rf_pts.sh [--red]
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module seek_rf_pts_tb;

logic clk = 0;
always #5 clk = ~clk;
logic rst_n = 0;

bit pre_fix = 0, on_resync = 0, no_b = 0, no_rlgn = 0;
initial begin
    if ($test$plusargs("PRE"))    pre_fix   = 1;
    if ($test$plusargs("NORLGN")) no_rlgn   = 1;
    if ($test$plusargs("RESYNC")) on_resync = 1;
    if ($test$plusargs("NOB"))    no_b      = 1;
end

// ---- byte source (a queue the stimulus appends packs to) --------------------
logic [7:0] src [$];
integer     sp = 0;
wire        in_ready;
logic [7:0] in_byte  = 8'h00;
logic       in_valid = 1'b0;
wire        pipe_rst_n, aud_rst_n, aud_flush, aud_resync;
wire        dmx_rst_n = rst_n & pipe_rst_n;
always @(posedge clk) begin
    if (!dmx_rst_n) begin
        in_valid <= 1'b0;
    end else if (!in_valid || in_ready) begin
        if (sp < src.size()) begin in_byte <= src[sp]; in_valid <= 1'b1; sp <= sp + 1; end
        else                        in_valid <= 1'b0;
    end
end

// ---- emu's reset domains ------------------------------------------------------
logic seek_ack = 1'b0;
logic aud_realign_q = 1'b0;                     // track switch: never pulsed here
always @(posedge clk) aud_realign_q <= 1'b0;
logic rf_flush_q = 1'b0;                        // the fix: a REGISTERED hard flush
always @(posedge clk) rf_flush_q <= on_resync ? aud_resync : aud_flush;
wire  rf_rst_n = pre_fix ? (rst_n & ~aud_realign_q)
                         : (rst_n & ~aud_realign_q & ~rf_flush_q);
// the demux realign on the first clock after the flush's reset (emu's dmx_rlgn_go)
logic dmx_rlgn_arm = 1'b0;
always @(posedge clk)
    if (!rst_n)          dmx_rlgn_arm <= 1'b0;
    else if (aud_flush)  dmx_rlgn_arm <= 1'b1;
    else if (pipe_rst_n) dmx_rlgn_arm <= 1'b0;
wire  dmx_rlgn_go = dmx_rlgn_arm & pipe_rst_n;
wire  dmx_realign = (pre_fix || no_rlgn) ? 1'b0 : dmx_rlgn_go;

flush_ctl fc (
    .clk(clk), .rst_n(rst_n),
    .start_streaming(1'b0), .seek_ack(seek_ack), .jump_ack(1'b0), .mode_switch(1'b0),
    .aud_switch(1'b0), .aud_rephase_req(1'b0), .keep_vbuf(1'b0),
    .jump_cross(1'b0), .cell_seamless(1'b0),
    .load_flush(), .aud_flush(aud_flush), .aud_resync(aud_resync), .seek_flush(),
    .mount_flush(), .soft_flush(), .pipe_rst_n(pipe_rst_n), .aud_rst_n(aud_rst_n)
);

// ---- chain --------------------------------------------------------------------
wire [7:0]  pd_b;  wire pd_v; wire [1:0] pd_t; wire pd_fs;
wire [32:0] pd_pts; wire pd_ptsv;
wire        almost_full;
wire        pd_ready = ~almost_full;            // emu: STD backpressure
wire        pd_xfer  = pd_v && pd_ready;

ps_demux dmx (
    .clk(clk), .rst_n(dmx_rst_n),
    .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
    .aud_drop(1'b0), .aud_track(3'd0), .aud_realign(dmx_realign), .sp_track(5'd0), .sp_enable(1'b0),
    .vid_byte(), .vid_valid(), .vid_mark(), .vid_ready(1'b1),
    .aud_byte(pd_b), .aud_valid(pd_v), .aud_type(pd_t), .aud_frame_start(pd_fs),
    .aud_ready(pd_ready),
    .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
    .aud_frame_pts(pd_pts), .aud_frame_pts_valid(pd_ptsv),
    .pci_enable(1'b0), .pci_byte(), .pci_valid(), .pci_frame_start(),
    .dsi_enable(1'b0), .dsi_byte(), .dsi_valid(), .dsi_frame_start(),
    .sp_byte(), .sp_valid(), .sp_frame_start(), .sp_pts(), .sp_pts_valid(),
    .aud_lpcm_quant(), .pes_scrambled(), .pes_hdr_ok(), .saw_pack()
);

wire [7:0] a_b; wire a_v; wire [1:0] a_t; wire a_fs; wire [32:0] a_p; wire a_pv;
ac3_reframer ar (.clk(clk), .rst_n(rf_rst_n),
    .in_byte(pd_b), .in_valid(pd_xfer), .in_type(pd_t), .in_frame_start(pd_fs),
    .in_frame_pts(pd_pts), .in_frame_pts_valid(pd_ptsv),
    .out_byte(a_b), .out_valid(a_v), .out_type(a_t), .out_frame_start(a_fs),
    .out_frame_pts(a_p), .out_frame_pts_valid(a_pv));
wire [7:0] d_b; wire d_v; wire [1:0] d_t; wire d_fs; wire [32:0] d_p; wire d_pv;
dts_reframer dr (.clk(clk), .rst_n(rf_rst_n),
    .in_byte(a_b), .in_valid(a_v), .in_type(a_t), .in_frame_start(a_fs),
    .in_frame_pts(a_p), .in_frame_pts_valid(a_pv),
    .out_byte(d_b), .out_valid(d_v), .out_type(d_t), .out_frame_start(d_fs),
    .out_frame_pts(d_p), .out_frame_pts_valid(d_pv));
wire [7:0] m_b; wire m_v; wire [1:0] m_t; wire m_fs; wire [32:0] m_p; wire m_pv;
mp2_reframer mr (.clk(clk), .rst_n(rf_rst_n),
    .in_byte(d_b), .in_valid(d_v), .in_type(d_t), .in_frame_start(d_fs),
    .in_frame_pts(d_p), .in_frame_pts_valid(d_pv),
    .out_byte(m_b), .out_valid(m_v), .out_type(m_t), .out_frame_start(m_fs),
    .out_frame_pts(m_p), .out_frame_pts_valid(m_pv));

wire [7:0]  r_b;  wire r_v;  logic r_ready = 0;
wire        f_v;  wire [15:0] f_len; wire [1:0] f_t;
wire [32:0] f_pts; wire f_ptsv;
logic       f_pop = 0;
audio_ring #(.BYTE_DEPTH(32768), .FRAME_DEPTH(128)) ring ( .cp_step(1'b0),
    .clk(clk), .rst_n(aud_rst_n),
    .aud_byte(m_b), .aud_valid(m_v), .aud_type(m_t), .aud_frame_start(m_fs),
    .drop_pulse(1'b0), .aud_frame_pts(m_p), .aud_frame_pts_valid(m_pv), .aud_frame_seamless(1'b0),
    .aud_ready(), .almost_full(almost_full),
    .out_byte(r_b), .out_valid(r_v), .out_ready(r_ready),
    .frame_valid(f_v), .frame_len(f_len), .frame_type(f_t),
    .frame_pts(f_pts), .frame_pts_valid(f_ptsv), .frame_pop(f_pop),
    .frames_available(), .bytes_available(), .overflow_count()
);

// ---- stream construction --------------------------------------------------------
localparam int FLEN  = 768;                 // AC-3 48 kHz, frmsizcod 20 (192 kb/s) -- MiB's track
localparam int FTICK = 2880;                // 32 ms of 90 kHz
localparam int CHUNK = 2000;                // PES payload bytes per pack (DVD: ~2 KB)
localparam [32:0] PTS_A0 = 33'd54000000;    // 10:00
localparam int KA    = 9;                   // whole frames of A before the partial one
localparam int TAILB = 300;                 // landing PES starts with a frame tail...
localparam int STRAY = 120;                 // ...carrying a stray in-payload 0B77 here
localparam int KB    = 6;                   // frames of B
localparam [32:0] PTS_B0 = PTS_A0 + KA*FTICK - 33'd1800000;   // 20 s earlier than A's last
localparam [7:0] TAG_A = 8'hA5, TAG_B = 8'hB5;

logic [7:0] es [$];

task automatic push_frame(input [7:0] tag, input integer idx);
    integer j;
    begin
        es.push_back(8'h0B); es.push_back(8'h77); es.push_back(8'h12); es.push_back(8'h34);
        es.push_back(8'h14);                  // fscod 0, frmsizcod 20 -> 768 bytes
        es.push_back(tag);  es.push_back(idx[7:0]);
        for (j = 7; j < FLEN; j = j + 1) es.push_back(8'h00);
    end
endtask

// one pack carrying one AC-3 PES; pts_v says whether a frame starts in it
task automatic push_pack(input integer off, input integer len, input bit pts_v,
                         input [32:0] pts, input integer fau);
    integer j, plen;
    begin
        src.push_back(8'h00); src.push_back(8'h00); src.push_back(8'h01); src.push_back(8'hBA);
        src.push_back(8'h44); src.push_back(8'h00); src.push_back(8'h04); src.push_back(8'h00);
        src.push_back(8'h04); src.push_back(8'h01); src.push_back(8'h01); src.push_back(8'h89);
        src.push_back(8'hC3); src.push_back(8'hF8);            // pack_stuffing_length 0
        plen = 3 + (pts_v ? 5 : 0) + 4 + len;
        src.push_back(8'h00); src.push_back(8'h00); src.push_back(8'h01); src.push_back(8'hBD);
        src.push_back(plen[15:8]); src.push_back(plen[7:0]);
        src.push_back(8'h81);
        src.push_back(pts_v ? 8'h80 : 8'h00);
        src.push_back(pts_v ? 8'd5 : 8'd0);
        if (pts_v) begin
            src.push_back({4'b0010, pts[32:30], 1'b1});
            src.push_back(pts[29:22]);
            src.push_back({pts[21:15], 1'b1});
            src.push_back(pts[14:7]);
            src.push_back({pts[6:0], 1'b1});
        end
        src.push_back(8'h80);                                 // AC-3, track 0
        src.push_back(pts_v ? 8'd1 : 8'd0);                   // frames starting here
        src.push_back(fau[15:8]); src.push_back(fau[7:0]);
        for (j = 0; j < len; j = j + 1) src.push_back(es[off + j]);
    end
endtask

// chop es[] into packs; a frame whose first byte is at es offset s (s >= base)
// has index (s - base)/FLEN and PTS pts0 + index*FTICK
task automatic packetize(input integer base, input [32:0] pts0);
    integer off, len, s, fi;
    bit     found;
    begin
        off = 0;
        while (off < es.size()) begin
            len = es.size() - off; if (len > CHUNK) len = CHUNK;
            found = 0;
            for (s = off; s < off + len && !found; s = s + 1)
                if (s >= base && ((s - base) % FLEN) == 0) begin found = 1; fi = s; end
            if (found) push_pack(off, len, 1'b1, pts0 + ((fi - base) / FLEN) * FTICK, fi - off + 1);
            else       push_pack(off, len, 1'b0, 33'd0, 0);
            off = off + len;
        end
    end
endtask

// ---- consumer: pop a descriptor, read its bytes (dvd_audio_decode's order) --------
integer cst = 0, left = 0, got = 0;
logic [7:0]  hb [0:7];
logic [32:0] cur_pts; logic cur_ptsv;
bit     after_flush = 0;
integer post_n = 0, post_tagged = 0, errs = 0, errs_n = 0;
logic [32:0] first_tagged_pts;
integer cur_n;

task automatic score();
    begin
        if (after_flush) begin
            if (post_n == 0 && !(hb[0] === 8'h0B && hb[1] === 8'h77 && hb[5] === TAG_B)) begin
                $display("    [1] N=%0d: first frame after the seek is not the landing's first whole frame (%02x %02x tag %02x)",
                         cur_n, hb[0], hb[1], hb[5]);
                errs_n = errs_n + 1;
            end
            if (cur_ptsv === 1'b1 && (cur_pts < PTS_B0 || cur_pts > PTS_B0 + KB*FTICK)) begin
                $display("    [2] N=%0d: frame %0d after the seek carries PTS %0d -- %0.2f s from the landing (stale timeline)",
                         cur_n, post_n, cur_pts, ($itor(cur_pts) - $itor(PTS_B0)) / 90000.0);
                errs_n = errs_n + 1;
            end
            if (cur_ptsv === 1'b1 && post_tagged == 0) begin
                first_tagged_pts = cur_pts;
                if (cur_pts !== PTS_B0) begin
                    $display("    [3] N=%0d: first PTS-tagged frame after the seek carries %0d, want %0d",
                             cur_n, cur_pts, PTS_B0);
                    errs_n = errs_n + 1;
                end
            end
            if (cur_ptsv === 1'b1) post_tagged = post_tagged + 1;
            post_n = post_n + 1;
        end
    end
endtask

always @(posedge clk) begin
    f_pop <= 1'b0;
    case (cst)
    0: if (aud_rst_n && f_v) begin
           left <= f_len; got <= 0; cur_pts <= f_pts; cur_ptsv <= f_ptsv;
           f_pop <= 1'b1; cst <= 1;
       end
    1: begin
           r_ready <= 1'b1;
           if (r_ready && r_v) begin
               if (got < 8) hb[got] = r_b;
               got  <= got + 1;
               left <= left - 1;
               if (left == 1) begin r_ready <= 1'b0; cst <= 2; end
           end
       end
    2: begin score(); cst <= 0; end
    endcase
    if (!aud_rst_n) begin cst <= 0; r_ready <= 1'b0; end
end

// ---- stimulus: one isolated seek per N ----------------------------------------------
integer ns [0:10];
integer t, a;
logic [7:0] dummy;
initial begin
    ns[0]=0; ns[1]=1; ns[2]=2; ns[3]=3; ns[4]=4; ns[5]=5; ns[6]=6; ns[7]=7; ns[8]=8;
    ns[9]=100; ns[10]=767;
    for (t = 0; t <= 10; t = t + 1) begin
        cur_n = ns[t];
        // a cold start per N, so each landing is judged on its own
        rst_n = 0; after_flush = 0;
        src.delete(); sp = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        // stream A: KA whole frames, then the first N bytes of the next
        es.delete();
        for (a = 0; a <= KA; a = a + 1) push_frame(TAG_A, a);
        while (es.size() > KA*FLEN + cur_n) dummy = es.pop_back();
        packetize(0, PTS_A0);
        while (sp < src.size()) @(posedge clk);
        repeat (400) @(posedge clk);            // the chain comes to rest after A
        // the seek: seek_ack -> flush_ctl -> pipe_rst_n + aud_flush -> aud_rst_n
        @(negedge clk); seek_ack = 1'b1;
        @(negedge clk); seek_ack = 1'b0;
        repeat (200) @(posedge clk);
        after_flush = 1; post_n = 0; post_tagged = 0; errs_n = 0;
        // stream B, the landing: a frame tail, then KB whole frames, 20 s earlier
        if (!no_b) begin
            es.delete();
            for (a = 0; a < TAILB; a = a + 1) es.push_back(8'hEE);
            es[STRAY] = 8'h0B; es[STRAY+1] = 8'h77; es[STRAY+4] = 8'h14;   // looks like a 768-byte frame
            for (a = 0; a < KB; a = a + 1) push_frame(TAG_B, a);
            src.delete(); sp = 0;
            packetize(TAILB, PTS_B0);
            while (sp < src.size()) @(posedge clk);
        end
        repeat (30000) @(posedge clk);
        if (post_n < 2 || post_tagged == 0) begin
            $display("    [4] N=%0d: vacuous -- %0d frames (%0d PTS-tagged) after the seek", cur_n, post_n, post_tagged);
            errs_n = errs_n + 1;
        end
        $display("  N=%0d: %0d frames after the seek, first tagged PTS %0d (landing %0d) -> %s",
                 cur_n, post_n, (post_tagged != 0) ? first_tagged_pts : 33'd0, PTS_B0,
                 (errs_n == 0) ? "ok" : "BAD");
        errs = errs + errs_n;
    end
    if (errs == 0) begin $display("SEEK_RF_PTS: PASS"); $finish; end
    $display("SEEK_RF_PTS: FAIL (%0d)", errs);
    $fatal(1);
end

endmodule
