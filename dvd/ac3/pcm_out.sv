//============================================================================
//  pcm_out.sv — final output stage (M9): format s16 L/R + output-rate pace/CDC.
//
//  Drains one block of time-domain PCM (imdct_512.pcm_mem, Q8.23, 256 samples
//  per channel, {ch,idx}) into a 16-bit signed L/R sample stream and presents it
//  at the audio sample rate to AUDIO_L/AUDIO_R.  Two clock domains, decoupled by
//  an asynchronous (Gray-pointer) FIFO so the bursty fixed-point datapath can run
//  on the decode clock while the DAC side is paced by a ~48 kHz clock-enable on
//  clk_sys (MiSTer wires AUDIO_S=1 for signed).  The decoder is bursty: a whole
//  block's 256 sample-pairs are produced in a few hundred decode-clock cycles,
//  then read out one pair per `aud_ce` over ~5.3 ms — so the FIFO must hold a
//  full block (>=256 pairs); DEPTH defaults to 512.
//
//  FORMAT (architecture.md §5 — PCM output rounding, pinned at M9):
//    pcm_mem is Q8.23 (32-bit, value = raw/2^23, nominal full-scale +/-1.0).
//    s16 = round_half_up(raw / 2^8) then saturate to [-32768, 32767]:
//      raw = +2^23 (==+1.0) -> +32768 -> saturates to +32767 (the only sat a
//      well-formed in-scope decode hits; out-of-range only from accumulation
//      headroom).  Rounding is round-half-toward-+inf ((raw+128)>>>8): cheap, no
//      DC bias of concern at s16 (the half-LSB add is 2^-16 of full scale).  The
//      bounded-error vs liba52's s16 is measured in the cosim (run_front_cosim).
//
//  HANDSHAKE / domains:
//    decode domain (clk, rst): `start` pulse (driven by imdct_512.done) kicks the
//      drain FSM, which walks idx 0..255, reading L=pcm_mem[{0,idx}] then
//      R=pcm_mem[{1,idx}] over the combinational read port (pcm_rd_addr/data),
//      formatting each to s16 and pushing {L,R} into the async FIFO.  `busy` is
//      high while draining (status/LED).  If the FIFO ever backs up (reader not
//      keeping up) the FSM stalls in D_R — it never drops a sample.
//    audio domain (aud_clk, aud_rst, aud_ce): on each `aud_ce` tick, if the FIFO
//      is non-empty a pair is popped into {audio_l,audio_r} and `aud_valid`
//      pulses; on underflow the last sample is held and `aud_valid` stays low.
//
//  Tie aud_clk=clk (and aud_rst=rst) for a single-clock system; the Gray-pointer
//  CDC then degenerates harmlessly.  Standalone TB: bench/ac3/pcm_out_tb.sv
//  (run_pcm_out.sh) drives the two clocks asynchronously and checks format,
//  saturation, ordering and underflow-hold.
//============================================================================

`timescale 1ns/1ps

module pcm_out #(
    parameter int FIFO_AW = 9            // FIFO depth = 2^AW pairs (512 >= 1 block)
) (
    // ---- decode clock domain ----
    input  logic        clk,
    input  logic        rst,             // synchronous, active-high
    input  logic        start,           // pulse: a block's pcm_mem is ready
    output logic [8:0]  pcm_rd_addr,     // {ch, idx[7:0]} into imdct_512.pcm_mem
    input  logic signed [31:0] pcm_rd_data,  // Q8.23
    output logic        busy,            // drain in progress
    output logic        done,            // 1-cycle pulse: block fully pushed to FIFO

    // ---- audio clock domain ----
    input  logic        aud_clk,
    input  logic        aud_rst,         // synchronous to aud_clk, active-high
    input  logic        aud_ce,          // ~48 kHz sample tick (1-cycle enable)
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        aud_valid        // 1 = a real pair was popped this aud_ce
);

    // ---- Q8.23 -> s16 : round half toward +inf, then saturate ----
    function automatic logic signed [15:0] to_s16(input logic signed [31:0] q);
        logic signed [33:0] r;
        r = (34'(q) + 34'sd128) >>> 8;           // /256 with round-to-nearest
        if      (r >  34'sd32767) to_s16 =  16'sd32767;
        else if (r < -34'sd32768) to_s16 = -16'sd32768;
        else                      to_s16 =  r[15:0];
    endfunction

    function automatic logic [FIFO_AW:0] bin2gray(input logic [FIFO_AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // ===================== drain FSM (decode domain) =======================
    // M15: imdct_512.pcm_mem became an M10K with a REGISTERED read port, so
    // pcm_rd_data lands one clock after pcm_rd_addr is presented.  Each read now
    // has a wait state (D_LW/D_RW) before its data state (D_L/D_R).  (A
    // combinational source — pcm_out_tb / the AC3_COSIM async tap — is unaffected:
    // the value is simply consumed a cycle later, still correct.)
    typedef enum logic [2:0] { D_IDLE, D_LW, D_L, D_RW, D_R } dstate_t;
    dstate_t st;
    logic [7:0]  idx;
    logic signed [15:0] lat_l;
    assign busy = (st != D_IDLE);

    // ================= asynchronous (Gray-pointer) FIFO ====================
    localparam int DEPTH = (1 << FIFO_AW);
    logic [31:0] mem [0:DEPTH-1];            // packed {L[15:0], R[15:0]}

    logic [FIFO_AW:0] wbin, wgray;           // write (decode) domain pointers
    logic [FIFO_AW:0] rbin, rgray;           // read (audio) domain pointers
    logic [FIFO_AW:0] rgray_s1, rgray_s2;    // read ptr synced into write domain
    logic [FIFO_AW:0] wgray_s1, wgray_s2;    // write ptr synced into read domain

    // full when the *next* write gray equals the synced read gray with the top
    // two bits inverted (standard Gray-pointer async-FIFO full test).
    wire fifo_full = (bin2gray(wbin + 1'b1) ==
                      {~rgray_s2[FIFO_AW:FIFO_AW-1], rgray_s2[FIFO_AW-2:0]});
    wire fifo_empty = (rgray == wgray_s2);

    // push is atomic in the decode domain: data, mem-write, and wptr advance all
    // happen the same cycle D_R fires with space available — no skew/desync.
    wire        do_push   = (st == D_R) && !fifo_full;
    wire [31:0] push_data = {lat_l, to_s16(pcm_rd_data)};

    wire fifo_pop  = aud_ce & ~fifo_empty;
    wire [31:0] fifo_rdata = mem[rbin[FIFO_AW-1:0]];

    always_ff @(posedge clk) begin
        if (rst) begin
            st <= D_IDLE; idx <= 8'd0; lat_l <= 16'sd0; pcm_rd_addr <= 9'd0;
            wbin <= '0; wgray <= '0; rgray_s1 <= '0; rgray_s2 <= '0;
            done <= 1'b0;
        end else begin
            done <= 1'b0;                  // default: 1-cycle pulse
            // -- FIFO write side --
            if (do_push) mem[wbin[FIFO_AW-1:0]] <= push_data;
            wbin     <= wbin + (do_push ? 1'b1 : 1'b0);
            wgray    <= bin2gray(wbin + (do_push ? 1'b1 : 1'b0));
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;

            // -- drain FSM --
            case (st)
                D_IDLE: if (start) begin
                    idx         <= 8'd0;
                    pcm_rd_addr <= {1'b0, 8'd0};        // L of sample 0
                    st          <= D_LW;               // wait one cycle for the read
                end
                // registered-read latency: L address presented last cycle.
                D_LW: st <= D_L;
                // L (ch0) on pcm_rd_data this cycle; capture, point at R.
                D_L: begin
                    lat_l       <= to_s16(pcm_rd_data);
                    pcm_rd_addr <= {1'b1, idx};         // R of sample idx
                    st          <= D_RW;               // wait one cycle for the read
                end
                D_RW: st <= D_R;
                // R (ch1) on pcm_rd_data; push {L,R} (stall here while full).
                D_R: if (!fifo_full) begin
                    if (idx == 8'd255) begin
                        st   <= D_IDLE;
                        done <= 1'b1;          // block fully pushed -> meter pulse
                    end else begin
                        idx         <= idx + 8'd1;
                        pcm_rd_addr <= {1'b0, idx + 8'd1};  // L of next sample
                        st          <= D_LW;
                    end
                end
                default: st <= D_IDLE;
            endcase
        end
    end

    // ===================== read side (audio domain) ========================
    always_ff @(posedge aud_clk) begin
        if (aud_rst) begin
            rbin <= '0; rgray <= '0; wgray_s1 <= '0; wgray_s2 <= '0;
            audio_l <= '0; audio_r <= '0; aud_valid <= 1'b0;
        end else begin
            rbin     <= rbin + (fifo_pop ? 1'b1 : 1'b0);
            rgray    <= bin2gray(rbin + (fifo_pop ? 1'b1 : 1'b0));
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
            aud_valid <= 1'b0;
            if (fifo_pop) begin
                audio_l   <= fifo_rdata[31:16];
                audio_r   <= fifo_rdata[15:0];
                aud_valid <= 1'b1;
            end
        end
    end

endmodule
