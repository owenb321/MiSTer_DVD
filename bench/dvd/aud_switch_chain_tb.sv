//============================================================================
//  aud_switch_chain_tb.sv -- WHAT REACHES THE AC-3 DECODER AFTER A TRACK SWITCH?
//
//  Field report (2026-09-22, Decode mode, after the output de-click): switching
//  between a DD 5.1 and a DD 2.0 track still pops INTERMITTENTLY, and a popping
//  switch sounds like: pop, silence, a blip of correct audio, silence, then the
//  correct audio continues. Seen so far only when landing on a 2.0 track.
//
//  That shape is the decoder being fed bad frames (garbage = pop, then its
//  self-heal reset = silence), not the output step. This bench runs the REAL
//  front half of the audio path emu builds, over a REAL disc slice:
//
//    ps_demux -> ac3_reframer -> dts_reframer -> mp2_reframer -> audio_ring
//                                  (flush_ctl.aud_resync -> aud_rst_n on the ring)
//
//  with emu's reset domains (reframers on the CORE reset, ring on aud_rst_n) and
//  emu's STD backpressure (ps_demux.aud_ready = ~almost_full). A consumer pops
//  frames the way dvd_audio_decode does, and every frame it receives is scored:
//    - starts with the 0x0B77 sync word?
//    - ring length == the length its own header declares (fscod 0, frmsizcod)?
//    - acmod (which track it came from: 7 = the 5.1 track, 2 = a 2.0 track)
//  A frame failing either check would reach ac3_front as garbage.
//
//  Fixture: +VOB=<slice of MEN_IN_BLACK VTS_21_1.VOB>, which interleaves 0x81
//  (acmod 7) with 0x80/0x82/0x83 (acmod 2). Switches alternate 0x81 <-> 0x80.
//============================================================================
`timescale 1ns/1ps
`default_nettype none

module aud_switch_chain_tb;

logic clk = 0;
always #5 clk = ~clk;
logic rst_n = 0;

// ---- source -----------------------------------------------------------------
logic [7:0] src [$];
string      vob_path;
integer     fd, n, i, cap_mb;
logic [7:0] buf8 [0:4095];
initial begin
    if (!$value$plusargs("VOB=%s", vob_path)) vob_path = ".sim/aud_switch/mib21.vob"   // built by run_aud_switch.sh;
    if (!$value$plusargs("MB=%d", cap_mb)) cap_mb = 8;
    fd = $fopen(vob_path, "rb");
    if (fd == 0) begin $display("FATAL: cannot open %0s", vob_path); $fatal(1); end
    while (src.size() < cap_mb*1048576) begin
        n = $fread(buf8, fd);
        if (n <= 0) break;
        for (i = 0; i < n; i = i + 1) src.push_back(buf8[i]);
    end
    $fclose(fd);
    $display("loaded %0d bytes from %0s", src.size(), vob_path);
end

// ---- chain -----------------------------------------------------------------
integer     sp = 0;                  // bytes loaded from the source so far
wire        in_ready;
logic [7:0] in_byte  = 8'h00;
logic       in_valid = 1'b0;
// held valid/ready: a byte is consumed on an edge with in_valid && in_ready
always @(posedge clk) begin
    if (!rst_n) begin
        in_valid <= 1'b0;
    end else if (!in_valid || in_ready) begin
        if (sp < src.size()) begin in_byte <= src[sp]; in_valid <= 1'b1; sp <= sp + 1; end
        else                        in_valid <= 1'b0;
    end
end

logic [2:0] aud_track = 3'd1;        // start on 0x81 (5.1)
logic       aud_switch = 1'b0;

// +PRE=1 rebuilds the PRE-FIX wiring (the RED arm): no demux realign and the
// reframers on the core reset only. Default is emu's wiring: aud_realign =
// aud_switch, reframers reset by a registered copy of it (rf_rst_n).
bit pre_fix = 0, keep_lock = 0;
initial if ($test$plusargs("PRE")) pre_fix = 1;
// +KEEPLOCK: demux realign ON, reframers still on the core reset only (mutation N3)
initial if ($test$plusargs("KEEPLOCK")) keep_lock = 1;
logic aud_realign_q = 1'b0;
always @(posedge clk) aud_realign_q <= aud_switch;
wire  dmx_realign = pre_fix ? 1'b0 : aud_switch;
wire  rf_rst_n    = (pre_fix || keep_lock) ? rst_n : (rst_n & ~aud_realign_q);

wire [7:0]  pd_b;  wire pd_v; wire [1:0] pd_t; wire pd_fs;
wire [32:0] pd_pts; wire pd_ptsv;
wire        almost_full;
wire        pd_ready = ~almost_full;          // emu: STD backpressure (bp armed)
wire        pd_xfer  = pd_v && pd_ready;

ps_demux dmx (
    .clk(clk), .rst_n(rst_n),
    .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
    .aud_track(aud_track), .aud_realign(dmx_realign), .sp_track(5'd0), .sp_enable(1'b0),
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

wire aud_rst_n;
flush_ctl fc (
    .clk(clk), .rst_n(rst_n),
    .start_streaming(1'b0), .seek_ack(1'b0), .jump_ack(1'b0), .mode_switch(1'b0),
    .aud_switch(aud_switch), .disc_rephase(1'b0), .keep_vbuf(1'b0),
    .jump_cross(1'b0), .cell_seamless(1'b0),
    .load_flush(), .aud_flush(), .aud_resync(), .seek_flush(), .mount_flush(),
    .soft_flush(), .pipe_rst_n(), .aud_rst_n(aud_rst_n)
);

wire [7:0]  r_b;  wire r_v;  logic r_ready = 0;
wire        f_v;  wire [15:0] f_len; wire [1:0] f_t;
logic       f_pop = 0;
audio_ring #(.BYTE_DEPTH(32768), .FRAME_DEPTH(128)) ring (
    .clk(clk), .rst_n(aud_rst_n),
    .aud_byte(m_b), .aud_valid(m_v), .aud_type(m_t), .aud_frame_start(m_fs),
    .drop_pulse(1'b0), .aud_frame_pts(m_p), .aud_frame_pts_valid(m_pv),
    .aud_ready(), .almost_full(almost_full),
    .out_byte(r_b), .out_valid(r_v), .out_ready(r_ready),
    .frame_valid(f_v), .frame_len(f_len), .frame_type(f_t),
    .frame_pts(), .frame_pts_valid(), .frame_pop(f_pop),
    .frames_available(), .bytes_available(), .overflow_count()
);

// ---- consumer: pop a descriptor, read its bytes, then "decode" for GAP cycles --
localparam int GAP = 3000;
function automatic integer ac3_len(input [7:0] b4);
    integer w;
    begin
        case (b4[5:1])
            0: w=64;  1: w=80;  2: w=96;  3: w=112; 4: w=128; 5: w=160;
            6: w=192; 7: w=224; 8: w=256; 9: w=320; 10: w=384; 11: w=448;
            12: w=512; 13: w=640; 14: w=768; 15: w=896; 16: w=1024; 17: w=1152;
            18: w=1280; default: w=0;
        endcase
        ac3_len = (b4[7:6] == 2'b00) ? w*2 : -1;
    end
endfunction

integer     cst = 0, left = 0, got = 0, wait_c = 0, flen = 0;
logic [7:0] hb [0:7];
integer     since_switch = -1, sw_n = 0, bad_total = 0, bad_sw = 0;
integer     frames_total = 0;
integer     wrong_trk = 0;      // a good frame of the OLD track after a switch
bit         after_sw = 0;
string      seq;
logic [2:0] want_acmod;

task automatic score(input integer len);
    integer exp; logic [2:0] acm; bit bad; string tag;
    begin
        exp = ac3_len(hb[4]);
        acm = hb[6][7:5];
        bad = !(hb[0] == 8'h0B && hb[1] == 8'h77) || (exp != len);
        frames_total = frames_total + 1;
        if (bad) bad_total = bad_total + 1;
        // Every frame the consumer receives after a switch must be the NEW track:
        // the ring is reset at the switch, so an old-track frame here was
        // committed AFTER the reset (the tail of the old PES leaking through).
        if (after_sw && !bad && acm != want_acmod) begin
            wrong_trk = wrong_trk + 1;
            $display("    OLD-TRACK frame after switch %0d (acmod %0d, wanted %0d)", sw_n, acm, want_acmod);
        end
        if (since_switch >= 0 && since_switch < 12) begin
            if (bad)                     tag = "X";
            else if (acm == 3'd7)        tag = "6";
            else if (acm == 3'd2)        tag = "2";
            else                         tag = "?";
            seq = {seq, tag};
            if (bad) begin
                bad_sw = bad_sw + 1;
                $display("    frame +%0d after switch %0d: BAD sync=%02x%02x len=%0d hdr_len=%0d acmod=%0d",
                         since_switch, sw_n, hb[0], hb[1], len, exp, acm);
            end
            since_switch = since_switch + 1;
            if (since_switch == 12) begin
                $display("  switch %0d -> %s: %s", sw_n, (want_acmod == 3'd7) ? "5.1" : "2.0", seq);
                since_switch = -1;
            end
        end
    end
endtask

always @(posedge clk) begin
    f_pop   <= 1'b0;
    case (cst)
    0: if (aud_rst_n && f_v && f_t == 2'd0) begin
           flen <= f_len; left <= f_len; got <= 0; f_pop <= 1'b1; cst <= 1;
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
    2: begin score(flen); wait_c <= GAP; cst <= 3; end
    3: if (wait_c == 0) cst <= 0; else wait_c <= wait_c - 1;
    endcase
    if (!aud_rst_n) begin cst <= 0; r_ready <= 1'b0; end
end

// ---- stimulus: switch 0x81 <-> 0x80 every ~200 KB, staggered offsets ---------
// DIRECTED mode (+SWAT=<byte> +TO=<track> [+FROM=<track>]): ONE switch at a byte
// offset chosen so the new track's first PES is one whose partial frame carries
// a STRAY 0x0B77 ahead of its real first frame (measured: 5 of 817 AC-3 PES in
// the MiB slice -- 0x81 @ sector 153, 0x82 @ 74, 0x83 @ 2139). Forwarding from
// the payload start makes the reframer accept that stray sync; only skipping
// to first_access_unit_pointer avoids it. The random sweep never lands there.
integer next_sw, k, swat, to_trk, from_trk;
bit     directed = 0;
initial begin
    if ($value$plusargs("SWAT=%d", swat)) begin
        directed = 1;
        if (!$value$plusargs("TO=%d", to_trk))     to_trk = 1;
        if (!$value$plusargs("FROM=%d", from_trk)) from_trk = 0;
        aud_track  = from_trk[2:0];
        want_acmod = 3'd0;
    end
    repeat (20) @(posedge clk);
    rst_n = 1;
    if (directed) begin
        while (sp < swat) @(posedge clk);
        // +SWSUB: land the switch INSIDE the old track's audio sub-header, the few
        // bytes after its substream id matched and before its payload starts --
        // the window only the demux's substream re-check covers.
        if ($test$plusargs("SWSUB"))
            while (!(dmx.state == dmx.S_AUD_SUBHDR && dmx.aud_ssid_r == from_trk[2:0]))
                @(posedge clk);
        @(negedge clk);
        aud_track  = to_trk[2:0];
        want_acmod = (to_trk == 1) ? 3'd7 : 3'd2;
        aud_switch = 1'b1;
        @(negedge clk);
        aud_switch = 1'b0;
        sw_n = 1; seq = ""; since_switch = 0; after_sw = 1;
        while (since_switch >= 0 && since_switch < 6 && sp < src.size() - 16) @(posedge clk);
        repeat (20000) @(posedge clk);
        $display("DIRECTED switch @%0d -> track %0d: first frames %s ; %0d bad, %0d old-track",
                 swat, to_trk, seq, bad_total, wrong_trk);
        if (bad_sw != 0 || wrong_trk != 0) $display("AUD_SWITCH_CHAIN: FAIL");
        else if (seq.len() < 6)            $display("AUD_SWITCH_CHAIN: FAIL (vacuous: no frames after the switch)");
        else                               $display("AUD_SWITCH_CHAIN: PASS");
        $finish;
    end
    next_sw = 400000;
    k = 0;
    while (sp < src.size() - 16) begin
        @(posedge clk);
        if (sp >= next_sw) begin
            @(negedge clk);
            aud_track  = (aud_track == 3'd1) ? 3'd0 : 3'd1;
            want_acmod = (aud_track == 3'd1) ? 3'd7 : 3'd2;
            aud_switch = 1'b1;
            @(negedge clk);
            aud_switch = 1'b0;
            sw_n = sw_n + 1;
            seq = "";
            since_switch = 0;
            after_sw = 1;
            k = k + 1;
            next_sw = next_sw + 200000 + (k * 7919) % 30011;
        end
    end
    repeat (200000) @(posedge clk);
    $display("RESULT: %0d frames, %0d bad in total, %0d bad within 12 frames of %0d switches, %0d old-track frames after a switch",
             frames_total, bad_total, bad_sw, sw_n, wrong_trk);
    if (sw_n < 30 || frames_total < 200)
        $display("AUD_SWITCH_CHAIN: FAIL (vacuous: too few switches/frames)");
    else if (bad_total != 0 || wrong_trk != 0) $display("AUD_SWITCH_CHAIN: FAIL");
    else                $display("AUD_SWITCH_CHAIN: PASS");
    $finish;
end

endmodule
