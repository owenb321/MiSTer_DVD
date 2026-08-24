// mp2_chain_tb.sv — full-chain MP2 test: a DVD-spec VOB (MPEG-2 PS, MP2 audio
// on stream_id 0xC0) through the REAL pipeline
//     ps_demux -> ac3_reframer -> dts_reframer -> mp2_reframer -> audio_ring
//     -> dvd_audio_decode (mp2_decode inside)
// with the PCM output compared BIT-EXACT against tools/mp2_ref.py's decode of
// the same audio ES. Proves the emu.sv wiring contract end to end: 0xC0
// routing + track select, PES-granular->frame-granular start regeneration,
// ring descriptor/type plumbing, dispatcher codec mux.
//
// Fixtures (generated, gitignored — bench/dvd/run_mp2.sh builds them):
//   bench/dvd/test_mp2/vobchain.vob        ffmpeg -f dvd mux (mpeg1video+mp2)
//   bench/dvd/test_mp2/vobchain/           mp2_ref.py fixture of the ES
// Regen: see run_mp2.sh (gen_chain_fix).
//
// dvd_audio_decode runs free (sched_en=0 bypasses the PTS drain gate; genlock
// trim=0), aud_ce every AUD_DIV cycles; capture on the module's audio_l/r via
// a change-detect on each aud_ce boundary is NOT reliable (held outputs), so
// we snoop the mp2 core's aud_valid through the dispatcher output latch: the
// TB captures audio_l/r one cycle after active aud_valid, exactly like the
// output mux latches them.
//
// Run (repo root):
//   iverilog -g2012 -I dvd/ac3 -o bench/dvd/mp2_chain_sim \
//     dvd/ps_demux.sv dvd/ac3_reframer.sv dvd/dts_reframer.sv dvd/mp2_reframer.sv \
//     dvd/audio_ring.sv dvd/dvd_audio_decode.sv dvd/lpcm_unpack.sv \
//     dvd/mp2/mp2_decode.sv dvd/ac3/*.sv bench/dvd/mp2_chain_tb.sv
//   vvp bench/dvd/mp2_chain_sim

`timescale 1ns/1ps
`default_nettype none

module mp2_chain_tb;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0;

    // ---- VOB feed -> ps_demux ----
    localparam int MAXB = 1 << 21;
    logic [7:0] vob [0:MAXB-1];
    int nbytes, fed = 0;

    // Registered prefetch feed: reading the big fixture array combinationally
    // (vob[fed] in always_comb) makes iverilog elaborate a 512K-entry mux and
    // the compile takes tens of minutes — clocked indexed reads are cheap.
    logic [7:0] in_byte;
    wire        in_ready;
    logic       prefetched = 0;
    wire        in_valid = prefetched && rst_n && (fed < nbytes);
    always @(posedge clk) begin
        if (!rst_n) begin
            fed <= 0; prefetched <= 0;
        end else if (!prefetched) begin
            in_byte <= vob[0]; prefetched <= 1;
        end else if (in_valid && in_ready) begin
            in_byte <= vob[fed + 1];
            fed     <= fed + 1;
        end
    end

    wire [7:0]  ps_aud_byte;
    wire        ps_aud_valid, ps_aud_ready;
    wire [1:0]  ps_aud_type;
    wire        ps_aud_frame_start;
    wire [32:0] ps_aud_frame_pts;
    wire        ps_aud_frame_pts_valid;

    ps_demux demux (
        .clk(clk), .rst_n(rst_n),
        .in_byte(in_byte), .in_valid(in_valid), .in_ready(in_ready),
        .aud_track(3'd0),
        .sp_track(3'd0), .sp_enable(1'b0),
        .vid_byte(), .vid_valid(), .vid_ready(1'b1),
        .aud_byte(ps_aud_byte), .aud_valid(ps_aud_valid), .aud_type(ps_aud_type),
        .aud_frame_start(ps_aud_frame_start), .aud_ready(ps_aud_ready),
        .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid(),
        .aud_frame_pts(ps_aud_frame_pts), .aud_frame_pts_valid(ps_aud_frame_pts_valid),
        .sp_byte(), .sp_valid(), .sp_frame_start(), .sp_pts(), .sp_pts_valid(),
        .pci_enable(1'b0), .pci_byte(), .pci_valid(), .pci_frame_start(),
        .dsi_enable(1'b0), .dsi_byte(), .dsi_valid(), .dsi_frame_start(),
        .aud_lpcm_quant(), .pes_scrambled()
    );

    // handshake-qualified transfer, exactly as emu.sv does (ps_aud_valid is a
    // held level; see the HANDSHAKE FIX comment there)
    wire ps_aud_xfer = ps_aud_valid && ps_aud_ready;

    // ---- reframer chain (identical wiring to emu.sv) ----
    wire [7:0]  ar_b;  wire ar_v;  wire [1:0] ar_t;  wire ar_s;
    wire [32:0] ar_p;  wire ar_pv;
    ac3_reframer u_ar (
        .clk(clk), .rst_n(rst_n),
        .in_byte(ps_aud_byte), .in_valid(ps_aud_xfer), .in_type(ps_aud_type),
        .in_frame_start(ps_aud_frame_start),
        .in_frame_pts(ps_aud_frame_pts), .in_frame_pts_valid(ps_aud_frame_pts_valid),
        .out_byte(ar_b), .out_valid(ar_v), .out_type(ar_t),
        .out_frame_start(ar_s), .out_frame_pts(ar_p), .out_frame_pts_valid(ar_pv)
    );
    wire [7:0]  dr_b;  wire dr_v;  wire [1:0] dr_t;  wire dr_s;
    wire [32:0] dr_p;  wire dr_pv;
    dts_reframer u_dr (
        .clk(clk), .rst_n(rst_n),
        .in_byte(ar_b), .in_valid(ar_v), .in_type(ar_t), .in_frame_start(ar_s),
        .in_frame_pts(ar_p), .in_frame_pts_valid(ar_pv),
        .out_byte(dr_b), .out_valid(dr_v), .out_type(dr_t),
        .out_frame_start(dr_s), .out_frame_pts(dr_p), .out_frame_pts_valid(dr_pv)
    );
    wire [7:0]  rf_b;  wire rf_v;  wire [1:0] rf_t;  wire rf_s;
    wire [32:0] rf_p;  wire rf_pv;
    mp2_reframer u_mr (
        .clk(clk), .rst_n(rst_n),
        .in_byte(dr_b), .in_valid(dr_v), .in_type(dr_t), .in_frame_start(dr_s),
        .in_frame_pts(dr_p), .in_frame_pts_valid(dr_pv),
        .out_byte(rf_b), .out_valid(rf_v), .out_type(rf_t),
        .out_frame_start(rf_s), .out_frame_pts(rf_p), .out_frame_pts_valid(rf_pv)
    );

    // ---- audio_ring ----
    wire [7:0]  ring_byte;
    wire        ring_valid, ring_ready;
    wire        frame_valid, frame_pop;
    wire [15:0] frame_len;
    wire [1:0]  frame_type;
    wire [32:0] frame_pts;
    wire        frame_pts_valid;
    wire        ring_almost_full;

    audio_ring #(.BYTE_DEPTH(32768), .FRAME_DEPTH(128)) u_ring (
        .clk(clk), .rst_n(rst_n),
        .aud_byte(rf_b), .aud_valid(rf_v), .aud_type(rf_t),
        .aud_frame_start(rf_s),
        .aud_frame_pts(rf_p), .aud_frame_pts_valid(rf_pv),
        .aud_ready(),
        .almost_full(ring_almost_full),
        .drop_pulse(1'b0),
        .out_byte(ring_byte), .out_valid(ring_valid), .out_ready(ring_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(frame_type),
        .frame_pts(frame_pts), .frame_pts_valid(frame_pts_valid),
        .frame_pop(frame_pop),
        .frames_available(), .bytes_available(), .overflow_count()
    );
    // demux backpressure exactly as emu: stall the stream when the ring is
    // nearly full (drain watchdog not modelled; the decoder always drains here)
    assign ps_aud_ready = ~ring_almost_full;

    // ---- dvd_audio_decode (free-running: sched_en=0) ----
    localparam int AUD_DIV = 64;
    int ce_cnt = 0;
    logic aud_ce_ext = 0;
    always @(posedge clk) begin
        ce_cnt <= (ce_cnt == AUD_DIV-1) ? 0 : ce_cnt + 1;
        aud_ce_ext <= (ce_cnt == AUD_DIV-1);
    end
    // dvd_audio_decode has its own NCO; to make the sim fast we can't inject a
    // CE — instead run with the real NCO (562.5 clk/sample) but a faster clock
    // is pointless in sim... we accept the real NCO rate: 1152 samples/frame *
    // 562.5 = 648k cycles per frame. For a 12-frame fixture that is ~7.8M
    // cycles — acceptable. (aud_ce_ext above is unused; kept for reference.)

    wire signed [15:0] audio_l, audio_r;

    dvd_audio_decode dut (
        .clk(clk), .rst_n(rst_n),
        .enable(1'b1),
        .pause(1'b0),
        .ring_byte(ring_byte), .ring_valid(ring_valid), .ring_ready(ring_ready),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_type(frame_type),
        .lpcm_quant(2'd0),
        .frame_pts(frame_pts), .frame_pts_valid(frame_pts_valid),
        .frame_pop(frame_pop),
        .nco_trim(22'sd0),
        .dispatch_pts(), .dispatch_pts_valid(),
        .sched_en(1'b0),                     // free-run (no PTS gate)
        .stc_anchored(1'b0),
        .arr_pts(33'd0), .arr_pts_valid(1'b0),
        .video_live(1'b0),
        .stc(33'd0),
        .av_ofs(18'sd0),
        .audio_l(audio_l), .audio_r(audio_r),
        .ac3_synced(), .ac3_err(),
        .dbg_ac3_resets(), .dbg_ac3_err_resets(),
        .dbg_draining(), .dbg_play_pts_valid(), .dbg_armed_data(),
        .dbg_skip_run(), .dbg_play_pts(),
        .dbg_rearm_cnt(), .dbg_fbrel_cnt(), .dbg_skip_cnt(), .dbg_play_err()
    );

    // capture: the mp2 core's aud_valid marks each new pair landing in the
    // output latch one cycle later
    wire mp2_avalid = dut.mp2_aud_valid;
    logic mp2_avalid_d;
    always @(posedge clk) mp2_avalid_d <= mp2_avalid;

    localparam int MAXS = 1 << 16;
    logic [31:0] golden [0:MAXS-1];
    int nsamp;
    int got = 0, errs = 0;

    always @(posedge clk) begin
        if (mp2_avalid_d) begin
            if (got < nsamp && {audio_r, audio_l} !== golden[got]) begin
                if (errs < 10)
                    $display("MISMATCH s%0d: dut {r,l}=%04x%04x golden=%08x",
                             got, audio_r & 16'hffff, audio_l & 16'hffff, golden[got]);
                errs++;
            end
            got++;
        end
    end

    initial begin
        $readmemh("bench/dvd/test_mp2/vobchain.vob.hex", vob);
        $readmemh("bench/dvd/test_mp2/vobchain/pcm_golden.hex", golden);
        nbytes = 0;
        while (nbytes < MAXB && !$isunknown(vob[nbytes])) nbytes++;
        nsamp = 0;
        while (nsamp < MAXS && !$isunknown(golden[nsamp])) nsamp++;
        if (nbytes == 0 || nsamp == 0)
            $fatal(1, "fixtures missing (run bench/dvd/run_mp2.sh)");
        $display("chain fixture: %0d VOB bytes, %0d golden samples", nbytes, nsamp);

        repeat (8) @(posedge clk);
        rst_n = 1;
        wait (got >= nsamp);
        repeat (100) @(posedge clk);
        if (errs == 0) begin
            $display("PASS: mp2_chain_tb — %0d samples BIT-EXACT through the full chain", got);
            $finish;
        end else begin
            $display("RESULT: %0d error(s)", errs);
            $fatal(1, "mp2_chain_tb failed");
        end
    end

    initial begin
        #200_000_000_0;   // 200M cycles
        $display("TIMEOUT: got %0d / %0d", got, nsamp);
        $fatal(1, "mp2_chain_tb timeout");
    end

endmodule

`default_nettype wire
