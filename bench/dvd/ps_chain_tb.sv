// ps_chain_tb.sv — Integration testbench for ps_stream_fifo + ps_demux
//
// Proves the input adapter (ps_stream_fifo) bridges mpg_streamer's one-cycle
// pulse interface to ps_demux's held valid/ready handshake WITHOUT dropping,
// duplicating, or reordering bytes, even under heavy output backpressure.
//
// Two identical chains are fed the same source bytes:
//   REF — no backpressure (core_busy held low): the timing-independent result.
//   DUT — core_busy toggles every cycle (worst case for the held handshake).
// Both producers model mpg_streamer's read_valid_pipe latency (one byte still in
// flight after `busy` raises). The forwarded video elementary streams must be
// byte-for-byte identical: demux output is a pure function of the input byte
// sequence, so any divergence means the FIFO/backpressure path corrupted it.
// This equivalence check works for ARBITRARY input, so real VOB data can be fed
// without knowing the expected payloads in advance.
//
// Source selection (first that works):
//   1. +VOB=<path>           plusarg
//   2. bench/dvd/test_vobs/sample.hex   (if present)
//   3. built-in synthetic Program Stream (also byte-exact checked)
//
// Generate a real VOB extract as space/newline-separated hex bytes:
//   od -An -v -tx1 VIDEO_TS/VTS_01_1.VOB | head -c 200000 > bench/dvd/test_vobs/sample.hex
//   (od -tx1, NOT `xxd -p` — $readmemh/%h need one hex byte per token)
//
//   iverilog -g2012 -o bench/dvd/ps_chain_sim \
//       dvd/ps_demux.sv dvd/ps_stream_fifo.sv bench/dvd/ps_chain_tb.sv
//   vvp bench/dvd/ps_chain_sim                 # synthetic
//   vvp bench/dvd/ps_chain_sim +VOB=bench/dvd/test_vobs/sample.hex

`timescale 1ns/1ps
`default_nettype none

module ps_chain_tb;

logic clk = 0, rst_n;
always #9.26 clk = ~clk;   // ~54 MHz

// ---------------------------------------------------------------------------
// Source stream (queue so it works for both synthetic and file-loaded data)
// ---------------------------------------------------------------------------
logic [7:0] src [$];
logic       loaded_from_file = 1'b0;

// Built-in synthetic stream: pack header + AC-3 PES + two video PESs
function automatic void load_synthetic();
    src = {
        // --- Pack header ---
        8'h00,8'h00,8'h01,8'hBA, 8'h44,8'h00,8'h04,8'h00,
        8'h04,8'h01,8'h01,8'hBE, 8'hFF,8'hF8,
        // --- AC-3 audio PES (private stream 1) ---
        8'h00,8'h00,8'h01,8'hBD, 8'h00,8'h08, 8'h80,8'h00,8'h00,
        8'h80, 8'h01, 8'h00,8'h00, 8'hAB,
        // --- Video PES with PTS ---
        8'h00,8'h00,8'h01,8'hE0, 8'h00,8'h0D, 8'h80,8'h80,8'h05,
        8'h21,8'h00,8'h91,8'hAB,8'h03,
        8'h00,8'h00,8'h01,8'hB3,8'h00,
        // --- Second video PES (no PTS) ---
        8'h00,8'h00,8'h01,8'hE0, 8'h00,8'h08, 8'h80,8'h00,8'h00,
        8'h00,8'h00,8'h01,8'hB8,8'h12
    };
endfunction

// Expected video ES for the synthetic stream (payload bytes, headers stripped)
logic [7:0] expected [$] = '{
    8'h00,8'h00,8'h01,8'hB3,8'h00,    // video PES #1 payload (with PTS)
    8'h00,8'h00,8'h01,8'hB8,8'h12     // video PES #2 payload (no PTS)
};

// Load space/newline-separated hex bytes from `path` into src; 1 on success.
function automatic bit load_hex_file(input string path);
    int    fd, code, b;
    fd = $fopen(path, "r");
    if (fd == 0) return 0;
    src.delete();
    forever begin
        code = $fscanf(fd, "%h", b);
        if (code != 1) break;          // EOF or malformed token
        src.push_back(b[7:0]);
    end
    $fclose(fd);
    return (src.size() > 0);
endfunction

// ===========================================================================
// One chain instance: ps_stream_fifo -> ps_demux, with a pulse producer that
// models mpg_streamer's read_valid_pipe. `bp` selects backpressure behaviour.
// Captured video bytes land in the module-level queue passed by the harness.
// ===========================================================================

// ---- REF chain (no backpressure) ----
logic [7:0] r_pd; logic r_pv; wire r_full;
wire [7:0]  r_inb; wire r_inv, r_inr;
wire [7:0]  r_vb;  wire r_vv;
wire [7:0]  r_ab;  wire r_av; wire [1:0] r_at; wire r_afs;
wire [32:0] r_vpts, r_apts; wire r_vptsv, r_aptsv;
logic [7:0] ref_vid [$];
int r_idx; logic r_rvp; logic [7:0] r_pend;
int aud_frames, aud_bytes, pts_prints;

ps_stream_fifo r_fifo (
    .clk(clk), .rst_n(rst_n),
    .wr_data(r_pd), .wr_en(r_pv), .almost_full(r_full),
    .out_byte(r_inb), .out_valid(r_inv), .out_ready(r_inr));

ps_demux r_dut (
    .clk(clk), .rst_n(rst_n),
    .in_byte(r_inb), .in_valid(r_inv), .in_ready(r_inr), .aud_track(3'd0),
    .vid_byte(r_vb), .vid_valid(r_vv), .vid_ready(1'b1),       // never stalled
    .aud_byte(r_ab), .aud_valid(r_av), .aud_type(r_at),
    .aud_frame_start(r_afs), .aud_ready(1'b1),
    .vid_pts(r_vpts), .vid_pts_valid(r_vptsv),
    .aud_pts(r_apts), .aud_pts_valid(r_aptsv));

always_ff @(posedge clk) begin
    if (!rst_n) begin
        r_pv <= 0; r_pd <= 0; r_idx <= 0; r_rvp <= 0; r_pend <= 0;
    end else begin
        r_pv <= 0;
        if (r_rvp) begin r_pd <= r_pend; r_pv <= 1; r_rvp <= 0; end
        if (!r_full && !r_rvp && r_idx < src.size()) begin
            r_pend <= src[r_idx]; r_idx <= r_idx + 1; r_rvp <= 1;
        end
    end
end

// Capture REF outputs + audio/PTS reporting
always_ff @(posedge clk) begin
    if (!rst_n) begin aud_frames <= 0; aud_bytes <= 0; pts_prints <= 0; end
    else begin
        if (r_vv)               ref_vid.push_back(r_vb);
        if (r_av) begin
            aud_bytes <= aud_bytes + 1;
            if (r_afs) begin
                aud_frames <= aud_frames + 1;
                $display("[%0t] audio frame %0d, type=%0d (0=AC3,1=DTS,2=LPCM,3=?)",
                         $time, aud_frames + 1, r_at);
            end
        end
        if ((r_vptsv || r_aptsv) && pts_prints < 8) begin
            pts_prints <= pts_prints + 1;
            if (r_vptsv) $display("[%0t] video PTS=%0d (%.3fs)", $time, r_vpts, real'(r_vpts)/90000.0);
            if (r_aptsv) $display("[%0t] audio PTS=%0d (%.3fs)", $time, r_apts, real'(r_apts)/90000.0);
        end
    end
end

// ---- DUT chain (cycle-by-cycle backpressure) ----
logic [7:0] d_pd; logic d_pv; wire d_full;
wire [7:0]  d_inb; wire d_inv, d_inr;
wire [7:0]  d_vb;  wire d_vv;
logic       core_busy;
logic [7:0] dut_vid [$];
int d_idx; logic d_rvp; logic [7:0] d_pend;

ps_stream_fifo d_fifo (
    .clk(clk), .rst_n(rst_n),
    .wr_data(d_pd), .wr_en(d_pv), .almost_full(d_full),
    .out_byte(d_inb), .out_valid(d_inv), .out_ready(d_inr));

ps_demux d_dut (
    .clk(clk), .rst_n(rst_n),
    .in_byte(d_inb), .in_valid(d_inv), .in_ready(d_inr), .aud_track(3'd0),
    .vid_byte(d_vb), .vid_valid(d_vv), .vid_ready(~core_busy),
    .aud_byte(), .aud_valid(), .aud_type(), .aud_frame_start(), .aud_ready(1'b1),
    .vid_pts(), .vid_pts_valid(), .aud_pts(), .aud_pts_valid());

always_ff @(posedge clk) begin
    if (!rst_n) core_busy <= 0;
    else        core_busy <= ~core_busy;   // worst-case churn
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        d_pv <= 0; d_pd <= 0; d_idx <= 0; d_rvp <= 0; d_pend <= 0;
    end else begin
        d_pv <= 0;
        if (d_rvp) begin d_pd <= d_pend; d_pv <= 1; d_rvp <= 0; end
        if (!d_full && !d_rvp && d_idx < src.size()) begin
            d_pend <= src[d_idx]; d_idx <= d_idx + 1; d_rvp <= 1;
        end
    end
end

// Capture the byte mpeg2video would actually latch (vid_valid & ~core_busy)
always_ff @(posedge clk)
    if (d_vv && ~core_busy) dut_vid.push_back(d_vb);

// ===========================================================================
// Run
// ===========================================================================
string vob_path;
int    errors = 0;

initial begin
    // ---- choose source ----
    if ($value$plusargs("VOB=%s", vob_path)) begin
        if (load_hex_file(vob_path)) begin
            loaded_from_file = 1; $display("Loaded %0d bytes from %s", src.size(), vob_path);
        end else begin
            $display("FAIL: could not read VOB hex file '%s'", vob_path); $finish;
        end
    end else if (load_hex_file("bench/dvd/test_vobs/sample.hex")) begin
        loaded_from_file = 1;
        $display("Loaded %0d bytes from bench/dvd/test_vobs/sample.hex", src.size());
    end else begin
        load_synthetic();
        $display("Using built-in synthetic stream (%0d bytes)", src.size());
    end

    // ---- reset & run ----
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    wait (r_idx == src.size() && d_idx == src.size());
    repeat (400) @(posedge clk);   // flush both pipelines

    // ---- checks ----
    $display("\n=== ps_chain_tb results ===");
    $display("source bytes        : %0d", src.size());
    $display("REF video bytes     : %0d", ref_vid.size());
    $display("DUT video bytes     : %0d", dut_vid.size());
    $display("audio frames        : %0d  (audio bytes: %0d)", aud_frames, aud_bytes);

    // (1) backpressure invariance: DUT must equal REF for any input
    if (dut_vid.size() != ref_vid.size()) begin
        $display("FAIL: REF/DUT video byte count differs (%0d vs %0d) — backpressure dropped/duplicated bytes",
                 ref_vid.size(), dut_vid.size());
        errors++;
    end else begin
        for (int i = 0; i < ref_vid.size(); i++)
            if (ref_vid[i] !== dut_vid[i]) begin
                $display("FAIL: REF/DUT mismatch at %0d: ref=%02h dut=%02h", i, ref_vid[i], dut_vid[i]);
                errors++;
                break;
            end
    end

    // (2) sanity: a valid Program Stream must yield some video
    if (ref_vid.size() == 0) begin
        $display("FAIL: no video bytes forwarded (bad stimulus or demux stuck)");
        errors++;
    end

    // (3) synthetic stream: also check exact expected payloads
    if (!loaded_from_file) begin
        if (ref_vid.size() != expected.size()) begin
            $display("FAIL: synthetic video count %0d != expected %0d", ref_vid.size(), expected.size());
            errors++;
        end else for (int i = 0; i < expected.size(); i++)
            if (ref_vid[i] !== expected[i]) begin
                $display("FAIL: synthetic mismatch at %0d: exp=%02h got=%02h", i, expected[i], ref_vid[i]);
                errors++;
                break;
            end
    end

    if (errors == 0)
        $display("PASS: video stream identical under worst-case backpressure (%0d bytes)%s",
                 ref_vid.size(), loaded_from_file ? " [real VOB]" : " [synthetic]");
    else
        $display("RESULT: %0d error(s)", errors);
    $finish;
end

// Timeout scales with input size (real VOBs are large)
initial begin
    #2_000_000_000;
    $display("TIMEOUT");
    $finish;
end

endmodule

`default_nettype wire
