// dvd/dts/dts_top.sv -- the DTS core decoder: frames in, s16 stereo PCM out
//
// dts_seq runs the microcode (the frame header, the side information, the control of
// every subsubframe); dts_vec the hardwired loops on one multiplier. A frame is a
// descriptor (fr_len, its byte length) and then exactly that many bytes, as
// dvd_audio_decode's dispatcher routes a frame from audio_ring. PCM pairs leave
// through pcm_* with full back-pressure (a MIXSYN stalls on its pairs). The codebook
// port (cb_*: one 64-bit row a request, answered any number of cycles later) is a
// top-level port: the codebooks are off-chip (docs/dts_decoder.md D4), answered by
// the bench in P1b and by ram2 from P2. clk_sys, 27 MHz. docs/dts_decoder.md sec 10.
//
// AC-3 (codec 1, docs/ac3_engine.md): each block is transformed here too (op 25, the
// IMDCT as a term program, docs/imdct_engine.md). At the op, imdct_req rises with the
// block's side information latched (blk_*) and waits for imdct_go (the caller's pcm_out
// has drained the last block); imdct_fin pulses when PCM slots 0/1 hold the block, which
// the caller reads through pcm_ra -> pcm_q (one cycle) until its next go. While
// imdct_req waits, coef_ra -> coef_q reads X ({slot, bin}, Q1.23 sign-extended to 25):
// the benches score the parse's coefficients there.
//
// MP2 (codec 2, docs/mp2_engine.md): PCM pairs out as DTS's, at the stream's own rate,
// which mp2_fs carries (MFS, op 29: no vector work, latched here).
//
// Telemetry (16-bit counters, saturating): frames decoded; frames refused, with the
// last refusal's code (dts.uasm E_*) and a sticky mask of every code seen; bits read
// past a frame's end (as 0); overflowed block codes decoded leniently (D5); frames
// whose embedded downmix coefficients were ignored (D3).

`default_nettype none

module dts_top (
    input  wire          clk,
    input  wire          rst_n,
    input  wire    [1:0] codec,              // 0 DTS, 1 AC-3, 2 MP2 (change only in reset)

    input  wire   [15:0] fr_len,
    input  wire          fr_valid,
    output logic         fr_ready,
    input  wire    [7:0] in_byte,
    input  wire          in_valid,
    output logic         in_ready,

    output logic         cb_req,
    output logic         cb_sel,
    output logic  [11:0] cb_addr,
    input  wire          cb_valid,
    input  wire   [63:0] cb_data,

    output logic  [15:0] pcm_l,
    output logic  [15:0] pcm_r,
    output logic         pcm_valid,
    input  wire          pcm_ready,

    output logic  [15:0] frames,
    output logic  [15:0] refused,
    output logic   [4:0] last_err,
    output logic  [31:0] err_seen,
    output logic  [15:0] overrun_bits,
    output logic  [15:0] lenient_codes,
    output logic  [15:0] dmix_ignored,
    output logic         frame_end,          // pulse: a frame decoded to its end (FEND)
    output logic         refuse,             // pulse: a frame refused ...
    output logic   [4:0] refuse_code,        // ... with this code

    // AC-3: the IMDCT runs here (op 25, docs/imdct_engine.md); pcm_out reads its output
    output logic         imdct_req,          // a block is ready to transform: waits for go
    input  wire          imdct_go,           // pcm_out has drained the last block
    output logic         imdct_fin,          // pulse: PCM slots 0/1 hold the block
    input  wire    [8:0] pcm_ra,             // {slot, idx}
    output logic  [31:0] pcm_q,
    input  wire   [10:0] coef_ra,            // X while imdct_req waits (benches)
    output logic  [24:0] coef_q,
    output logic   [4:0] blk_blksw,          // a bit a channel
    output logic   [7:0] blk_dynrng,
    output logic   [2:0] blk_acmod,
    output logic         blk_lfeon,
    output logic   [1:0] blk_cmix,
    output logic   [1:0] blk_surmix,

    // MP2: the sampling-frequency index of the stream (MFS's a0, latched as each
    // frame's header is accepted: 0 44.1 kHz, 1 48, 2 32), for the output NCO
    output logic   [1:0] mp2_fs,

    // benches
    output logic         vop_start,
    output logic   [5:0] vop_op,
    output logic         vop_done,
    output logic         tr_valid,
    output logic  [10:0] tr_pc,
    output logic   [1:0] tr_kind,
    output logic  [10:0] tr_addr,
    output logic  [23:0] tr_val
);

    logic [127:0] vop_args;
    logic  [23:0] xq_code;
    logic  [10:0] xq_addr;
    logic         xq_valid, xq_ready;
    logic         err_valid, frame_done, overrun_bit, lenient;
    logic   [4:0] err_code;

    dts_seq u_seq (
        .clk, .rst_n, .codec, .fr_len, .fr_valid, .fr_ready, .in_byte, .in_valid, .in_ready,
        .vop_start, .vop_op, .vop_args, .vop_done, .xq_code, .xq_addr, .xq_valid, .xq_ready,
        .err_valid, .err_code, .frame_done, .overrun_bit, .lenient,
        .tr_valid, .tr_pc, .tr_kind, .tr_addr, .tr_val);

    dts_vec u_vec (
        .clk, .rst_n, .start(vop_start), .op(vop_op), .args(vop_args), .done(vop_done),
        .xq_code, .xq_valid, .xq_ready,
        .cb_req, .cb_sel, .cb_addr, .cb_valid, .cb_data,
        .pcm_l, .pcm_r, .pcm_valid, .pcm_ready,
        .xq_addr, .abort(err_valid), .imdct_req, .imdct_go, .imdct_fin, .pcm_ra, .pcm_q, .coef_ra, .coef_q);

    // AC-3: IMDCT's arguments, the block's side information (ac3.uasm M_DONE), latched
    // on the op's start
    always_ff @(posedge clk)
        if (vop_start && vop_op == 6'd25) begin
            blk_blksw <= vop_args[4:0];      blk_dynrng <= vop_args[23:16];
            blk_acmod <= vop_args[34:32];    blk_lfeon  <= vop_args[48];
            blk_cmix  <= vop_args[65:64];    blk_surmix <= vop_args[81:80];
        end

    // MP2: MFS's a0, the stream's sampling frequency (mp2.uasm issues it as each header
    // is accepted, before the frame's PCM)
    always_ff @(posedge clk)
        if (!rst_n) mp2_fs <= 2'd1;
        else if (vop_start && vop_op == 6'd29) mp2_fs <= vop_args[1:0];

    assign frame_end = frame_done;
    assign refuse = err_valid;
    assign refuse_code = err_code;

    // CNT's counter id is r8 (dts_isa.CNT_DMIX_IGNORED = 0)
    wire cnt_dmix = vop_start && (vop_op == 6'd8) && (vop_args[15:0] == 16'd0);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            frames <= 16'd0; refused <= 16'd0; last_err <= 5'd0; err_seen <= 32'd0;
            overrun_bits <= 16'd0; lenient_codes <= 16'd0; dmix_ignored <= 16'd0;
        end else begin
            if (frame_done && frames != 16'hFFFF) frames <= frames + 16'd1;
            if (err_valid) begin
                if (refused != 16'hFFFF) refused <= refused + 16'd1;
                last_err <= err_code;
                err_seen[err_code] <= 1'b1;
            end
            if (overrun_bit && overrun_bits != 16'hFFFF) overrun_bits <= overrun_bits + 16'd1;
            if (lenient && lenient_codes != 16'hFFFF) lenient_codes <= lenient_codes + 16'd1;
            if (cnt_dmix && dmix_ignored != 16'hFFFF) dmix_ignored <= dmix_ignored + 16'd1;
        end
    end

endmodule
