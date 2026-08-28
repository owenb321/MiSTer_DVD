// =============================================================================
// dvd/mem_shim_burst.sv — burst f2sdram (DDRAM) bridge with a SET-ASSOCIATIVE
// read cache (ao486 L2-style)
// =============================================================================
// Drop-in replacement for dvd/mem_shim.sv (identical port list). Read throughput
// is dominated by CACHE HIT RATE, not burst size or clock — proven by the ao486
// core (rtl/cache/l2_cache.v + forum "ao486 core and SDRAM performance", t=1654):
// it runs DDR at the SAME 90 MHz with the SAME 8x64-bit bursts we do, yet sustains
// the most bandwidth-hungry MiSTer core because its L2 cache (4-way, 128 lines,
// 8-word, LRU) covers >95% of all reads. The author: "all performance-critical
// reads go through the very large L1/L2 cache ... Writing to DDR3 is transparent."
//
// HISTORY on this board: the first burst bridge used a DIRECT-MAPPED 16-line cache.
// It decoded correct-color video but sheared, because the interleaved access
// streams (display scan-out + motion-comp reference reads + recon-frame writes)
// alias in a direct-mapped cache and evict each other -> low hit rate -> scan-out
// starves. Raising the clock (108) wedged f2sdram; widening the line (LINEW=16)
// made it WORSE (more thrash, 2x miss cost). So this goes set-associative with
// many more lines, mirroring ao486, keeping the proven 8-beat burst @90 MHz.
//
// GEOMETRY (params): NSETS sets x ASSOC ways x LINEW words.
//   defaults: LINEW=8 (burst beats), NSETS=128, ASSOC=4  => 32 KB (ao486-exact)
// Address[21:0] (64-bit word address):  [21:10] tag | [9:3] set | [2:0] off
//
// STORAGE (reworked 2026-08-27, feature/mem-shim-tag-bram — the ALM reclaim):
//   - DATA (32 KB): M10K BRAM since the first burst bridge (it won't fit in
//     flops — an earlier version that read the array straight into the shared
//     mem_res_wr_dta register failed Quartus inference, error 276003). Clean
//     SIMPLE-DUAL-PORT RAM: one registered read port, one FSM-muxed write port.
//   - TAGS + LRU: now ALSO M10K (this module's recurring-LUT-RAM-pattern
//     paydown, cf. M19/parse_buf). Before: 12b x 128 sets x 4 ways of tag flops
//     + 2b x 512 LRU flops read through per-set 128:1 async muxes ~= 4.9k ALMs
//     — the third-largest block in the design. Now: tag_ram = NSETS x
//     (ASSOC*TAG_W) and lru_ram = NSETS x (ASSOC*ASW), each sync-read (one set
//     = all ways per read), written whole-word via captured set snapshots so no
//     byte-enables are needed. The 1-cycle read latency is absorbed by a third
//     pipeline stage in the hit loop (see PIPELINE below) — still 1 word/cycle,
//     and the miss/write paths enter their slow states in the SAME cycle count
//     as the flop-tag version (fast-path entry from the stream stage).
//   - VALID: stays in flops (ASSOC x NSETS = 512 FFs, cheap) so S_INIT
//     invalidation and the victim-invalidate-before-fill rule keep their
//     simple, reset-friendly semantics — BRAM has no reset.
//
// REPLACEMENT: true LRU via per-set rank counters (0 = MRU .. ASSOC-1 = LRU),
// exactly ao486's scheme, BIT-EXACT vs the flop implementation (gated by
// bench/dvd/mem_shim_ab_tb.sv against the frozen pre-BRAM copy). A sync-read
// rank store needs read-after-write consistency for back-to-back same-set hits:
// a 2-deep bypass (the stage-B touch being written THIS cycle + a last-write
// register lw_*) forwards ranks the RAM can't return yet. Mixed-port
// read-during-write on M10K is undefined => any same-cycle same-set write is
// bypassed by construction, so the undefined value is never consumed.
// A wrong victim only lowers hit rate, never returns wrong data — correctness
// rests entirely on the tag/valid check + fill.
//
// COHERENCE: write-through to DDR (single beat) + UPDATE the cached word on a
// write hit (ao486-style: a write hit doesn't cost a later miss). On a read miss
// the victim way is INVALIDATED before the fill and only re-validated when all
// LINEW beats land, so a fill timeout can never leave a stale/partial valid line.
// Strict in-order processing => responses in request order, and a write is never
// issued while a read burst is in flight (the rule that kept f2sdram alive).
//
// Address formula (DENSE, fixes the 24 MB TrustZone boundary): DDR word address
// {7'b0011000, word_addr[21:0]} puts window 3 (HPS byte 0x30000000) in bits[28:25]
// with no left-shift. Burst base = the line-aligned word address.
// =============================================================================
module mem_shim_burst #(
    parameter [21:0]  ADDR_ERR = 22'h077FFF, // MP@ML sentinel (dvd/mem_override/mem_codes.v)
    // cache geometry (defaults = ao486 L2: 4-way, 128 sets, 8-word lines = 32 KB).
    // LINEW = burst beats (hardware-proven at 8). ASSOC>=2.
    parameter integer LINEW    = 8,
    parameter integer NSETS    = 128,
    parameter integer ASSOC    = 4
)(
    input             clk,
    input             rst_n,
    input             hard_rst_n,   // unused (same as rst_n in emu.sv); kept for port compat
    input             cwf_en,       // O-toggle: CRITICAL-WORD early-serve (emit the miss's
                                    // requested word the instant its burst beat lands, instead
                                    // of after all LINEW beats + drain). Safe: same single burst,
                                    // same victim/in-order discipline; 0 = legacy serve-at-end.
    input             dual_en,      // O-toggle: PAIRED DUAL-OUTSTANDING miss fills. On a read
                                    // miss, peek the next command; if it is ALSO a read miss to
                                    // a DIFFERENT set, issue both bursts (A then B) so the two
                                    // DDR command latencies overlap, then collect+serve A then B
                                    // in order. 0 = single-outstanding (the proven baseline).

    // MPEG2 core memory request FIFO (read side) — clocked on clk (mem_clk)
    input       [1:0] mem_req_rd_cmd,
    input      [21:0] mem_req_rd_addr,
    input      [63:0] mem_req_rd_dta,
    output            mem_req_rd_en,
    input             mem_req_rd_valid,

    // MPEG2 core memory response FIFO (write side) — clocked on clk (mem_clk)
    output reg [63:0] mem_res_wr_dta,
    output reg        mem_res_wr_en,
    input             mem_res_wr_almost_full,

    // DDR3 controller interface (Avalon-MM 64-bit, f2sdram)
    output reg [28:0] ddr3_addr,
    output reg  [7:0] ddr3_burstcnt,
    output reg        ddr3_read,
    output reg        ddr3_write,
    output reg [63:0] ddr3_writedata,
    output      [7:0] ddr3_byteenable,
    input      [63:0] ddr3_readdata,
    input             ddr3_readdatavalid,
    input             ddr3_waitrequest,

    // Debug outputs (same set as mem_shim.sv so emu/uart/overlay wiring is reused)
    output     [3:0]  debug_state,
    output      [1:0] debug_saved_cmd,
    output            debug_sdram_busy,
    output            debug_sdram_ack,
    output    [15:0]  debug_rd_count,
    output    [15:0]  debug_wr_count,
    output    [15:0]  debug_rsp_count,
    output    [15:0]  debug_read_pend_cycles,
    output    [15:0]  debug_cache_missrate    // {miss_pct[7:0], reads_hi[7:0]} per window
);
    localparam CMD_NOOP    = 2'd0;
    localparam CMD_REFRESH = 2'd1;
    localparam CMD_READ    = 2'd2;
    localparam CMD_WRITE   = 2'd3;

    // ---- cache geometry (derived) ----
    localparam integer LOFF_W = $clog2(LINEW);   // addr[2:0]   word-in-line  (LINEW=8 -> 3)
    localparam integer SET_W  = $clog2(NSETS);   // addr[9:3]   set index     (NSETS=128 -> 7)
    localparam integer ASW    = $clog2(ASSOC);   // way index                 (ASSOC=4 -> 2)
    localparam integer TAG_W  = 22 - LOFF_W - SET_W;          // addr[21:10] -> 12 bits
    localparam integer DIDX_W = SET_W + ASW + LOFF_W;         // cache_data index -> 12 bits
    localparam integer TAGV_W = ASSOC * TAG_W;                // one set's tag word -> 48 bits
    localparam integer LRUV_W = ASSOC * ASW;                  // one set's rank word -> 8 bits

    assign ddr3_byteenable = 8'hFF;

    // ---- cache storage ----
    // DATA: simple-dual-port BRAM (M10K). Written ONLY via the single muxed write
    // port below, read ONLY via the dedicated registered port — this clean
    // separation is what makes it infer as M10K. Index = {set, way, off}.
    reg [63:0]       cache_data [0:NSETS*ASSOC*LINEW-1];
    // TAGS + LRU: simple-dual-port BRAM too (the ALM reclaim). One address = one
    // SET; the word carries all ASSOC ways so a single sync read gives the full
    // compare/victim context. Whole-word writes only (set snapshots captured at
    // lookup time make the read-modify-write free — see fill validate below).
    (* ramstyle = "M10K" *) reg [TAGV_W-1:0] tag_ram [0:NSETS-1];
    (* ramstyle = "M10K" *) reg [LRUV_W-1:0] lru_ram [0:NSETS-1];
    // valid: one bit per way, in flops (cheap; keeps S_INIT + victim-invalidate
    // semantics — BRAM has no reset).
    reg [ASSOC-1:0]  cache_valid[0:NSETS-1];

    // ---- current command (latched when the stream hands off to a slow path) ----
    reg  [1:0] cur_cmd;
    reg [21:0] cur_addr;
    reg [63:0] cur_dta;

    wire [LOFF_W-1:0] cur_off  = cur_addr[LOFF_W-1:0];               // [2:0]
    wire [SET_W-1:0]  cur_set  = cur_addr[LOFF_W +: SET_W];          // [9:3]
    wire [TAG_W-1:0]  cur_tag  = cur_addr[LOFF_W+SET_W +: TAG_W];    // [21:10]
    wire              cur_aerr = (cur_addr == ADDR_ERR);

    // ---- FSM state ----
    // PIPELINED 1-word/cycle hit loop, now THREE overlapped stages (the tag RAM
    // is sync-read):
    //   Stage T: select the live source (pk > sk > FIFO) and present its SET to
    //            the tag/LRU RAM;
    //   Stage A: the RAM word for the pA_* command is out — compare tags, pick
    //            hit way / victim, present the hit word's data-RAM address;
    //   Stage B: cache_rdata is out — emit + LRU-touch (write port).
    // S_PROC is the RARE slow path only (ADDR_ERR / NOOP): a read MISS issues its
    // burst and a WRITE issues its beat DIRECTLY from the stage-A verdict cycle
    // (fast-path entry), so miss/write timing matches the flop-tag version.
    // S_RX/S_HIT (4'd2/4'd4) are the RETIRED 2-cycle loop — kept as reserved
    // encodings so debug_state numbering for the slow-path states is unchanged.
    localparam [3:0] S_INIT      = 4'd0,    // clear valid bits + seed LRU after reset
                     S_REQ       = 4'd1,    // pulse rd_en (refetch after slow path / drain)
                     S_RX        = 4'd2,    // (retired encoding)
                     S_PROC      = 4'd3,    // slow path: ADDR_ERR / NOOP (rare)
                     S_HIT       = 4'd4,    // (retired encoding)
                     S_FILL_CMD  = 4'd5,    // drive burst read, wait acceptance
                     S_FILL_DAT  = 4'd6,    // collect LINEW beats into the victim way
                     S_FILL_DRN  = 4'd7,    // 1-cycle drain so the last beat write commits
                     S_SERVE_ADR = 4'd8,    // present the served word's read address
                     S_SERVE     = 4'd9,    // emit the miss's requested word
                     S_WR_CMD    = 4'd10,   // drive single write, wait acceptance
                     S_STREAM    = 4'd11,   // PIPELINED hit loop: 1 word/cycle
                     S_PEEK      = 4'd12,   // DUAL: latch the next command, present its set
                     S_ISSUE2    = 4'd13,   // DUAL: drive burst B, wait acceptance
                     S_PEEK2     = 4'd14;   // DUAL: tag word out — pair decision
    reg [3:0] state;

    // ---- PIPELINED HIT path (1 word/cycle) ----
    // Stage A register: the command whose tag/LRU RAM word is on tag_rd/lru_rd
    // this cycle.
    reg             pA_valid;
    reg  [1:0]      pA_cmd;
    reg [21:0]      pA_addr;
    reg [63:0]      pA_dta;
    wire [LOFF_W-1:0] pA_off  = pA_addr[LOFF_W-1:0];
    wire [SET_W-1:0]  pA_set  = pA_addr[LOFF_W +: SET_W];
    wire [TAG_W-1:0]  pA_tag  = pA_addr[LOFF_W+SET_W +: TAG_W];
    wire              pA_aerr = (pA_addr == ADDR_ERR);
    wire [21:0] pA_line_base  = {pA_addr[21:LOFF_W], {LOFF_W{1'b0}}};
    // Stage B register (emit): the hit looked up LAST cycle; cache_rdata is valid
    // now. pB_* holds set/way/off (to re-read on backpressure + LRU-touch on
    // emit) and the command's bypassed rank word (pB_lru) for the touch.
    reg             pB_valid;
    reg [SET_W-1:0] pB_set;
    reg [ASW-1:0]   pB_way;
    reg [LOFF_W-1:0]pB_off;
    reg [LRUV_W-1:0]pB_lru;
    // Skid register: the FIFO holds `valid` for only one cycle, so when a command
    // arrives during a backpressure stall — or on the cycle stage A exits to a
    // slow path (the pop was speculative) — we capture it here so it is never
    // lost. Drained at stage T (after pk) before the live FIFO output.
    reg             sk_valid;
    reg  [1:0]      sk_cmd;
    reg [21:0]      sk_addr;
    reg [63:0]      sk_dta;

    // ---- PAIRED DUAL-OUTSTANDING miss fills (dual_en) — declared early because the
    // stage-T mux and rd_en assign below reference pk_valid/dual_en_q ----
    // On a read miss (slot A) we peek the next command; if it is ALSO a read miss to
    // a DIFFERENT set (so no victim-way collision with A), we issue burst B as well,
    // overlapping the two DDR command latencies. Beats return in order (all of A then
    // all of B), so a SINGLE always-on COLLECT block routes each beat to the active
    // slot, early-serves its requested word (cwf), and on the last beat validates the
    // line + queues a fallback serve. The case statement only ISSUES bursts and
    // sequences A->peek->B. Responses stay strictly in order. A non-pairable peek is
    // stashed in pk_* and processed by S_STREAM after the fill, so no command is lost.
    // NOTE (BRAM-tag rework): the stream's pops are SPECULATIVE, so at fill entry
    // the next command usually sits in the SKID already (parked on the miss-exit
    // cycle) — that skid command IS the peek candidate then (its set has been on
    // the tag-RAM address since the exit cycle, so S_FILL_CMD goes straight to
    // S_PEEK2); only an empty skid pops the FIFO for a candidate (S_PEEK latches
    // it into pk_*). sk and pk are therefore mutually exclusive. A non-pairable
    // candidate simply STAYS in its hold register for S_STREAM to process in
    // order — no command is ever lost or reordered.
    reg        dual_en_q;
    reg [SET_W-1:0]  ifb_set;    // slot B (2nd burst) line set
    reg [ASW-1:0]    ifb_way;    // slot B victim way (chosen from B's set; set != A's)
    reg [LOFF_W-1:0] ifb_off;    // slot B requested word offset
    reg [TAG_W-1:0]  ifb_tag;    // slot B tag
    reg        ifb_active;       // burst B has been ACCEPTED and is in flight
    reg        pairing;          // this fill is a pair (B will/did issue)
    reg        a_done;           // slot A fully collected before B was accepted (wait)
    reg        c2;               // COLLECT is currently filling slot B (else slot A)
    reg        served_b;         // slot-B requested word emitted during the fill
    reg        pk_valid;         // a peeked non-pairable command is held in pk_*
    reg  [1:0] pk_cmd;
    reg [21:0] pk_addr;
    reg [63:0] pk_dta;
    // Pair-candidate mux for S_PEEK2: the skid command when it holds one (the
    // common case — the speculative pop parked the next command there on the
    // miss-exit cycle), else the S_PEEK-latched pk. Mutually exclusive by
    // construction (S_PEEK is only entered with an empty skid; the skid only
    // loads while streaming).
    wire        cand_is_sk = sk_valid;
    wire [1:0]  cand_cmd  = sk_valid ? sk_cmd  : pk_cmd;
    wire [21:0] cand_addr = sk_valid ? sk_addr : pk_addr;
    wire [LOFF_W-1:0] cand_off  = cand_addr[LOFF_W-1:0];
    wire [SET_W-1:0]  cand_set  = cand_addr[LOFF_W +: SET_W];
    wire [TAG_W-1:0]  cand_tag  = cand_addr[LOFF_W+SET_W +: TAG_W];
    wire              cand_aerr = (cand_addr == ADDR_ERR);
    wire [21:0] cand_line_base  = {cand_addr[21:LOFF_W], {LOFF_W{1'b0}}};
    // fallback serve queue (depth 2): words whose cwf early-serve didn't fire.
    reg [SET_W-1:0]  sv_set [0:1];
    reg [ASW-1:0]    sv_way [0:1];
    reg [LOFF_W-1:0] sv_off [0:1];
    reg              sv_fail[0:1];   // that fill timed out => serve zero
    reg        sv_wr, sv_rd;   // 1-bit ring pointers (depth 2)
    reg [1:0]        sv_n;           // queued count (0..2)

    // ---- Stage T source mux ----
    // Priority: the peeked-non-pairable hold (pk_*, drained first so order is
    // preserved), then the backpressure/exit skid, then the live FIFO output.
    // (pk and sk can never BOTH be valid: pairing peeks are suppressed while the
    // skid holds, and the skid only loads while streaming — the rd_en guard is
    // defensive.)
    wire        lu_src_v  = pk_valid ? 1'b1    : sk_valid ? 1'b1    : mem_req_rd_valid;
    wire [1:0]  lu_src_c  = pk_valid ? pk_cmd  : sk_valid ? sk_cmd  : mem_req_rd_cmd;
    wire [21:0] lu_src_a  = pk_valid ? pk_addr : sk_valid ? sk_addr : mem_req_rd_addr;
    wire [63:0] lu_src_d  = pk_valid ? pk_dta  : sk_valid ? sk_dta  : mem_req_rd_dta;

    // ---- tag/LRU RAM read port (shared address; registered outputs) ----
    // Streaming presents the LIVE stage-T source's set (so the word is out when
    // that command sits in stage A); a stall re-presents stage A's set so the
    // word HOLDS across the stall; S_PEEK/S_PEEK2 present the peeked command's
    // set through the same stage-T mux (pk latches at the S_PEEK edge and takes
    // mux priority in S_PEEK2). In the remaining (slow-path) states the read is
    // don't-care: every consumer there uses the snap_* / fillB_* snapshots.
    reg  [TAGV_W-1:0] tag_rd;
    reg  [LRUV_W-1:0] lru_rd;
    wire [SET_W-1:0]  tl_raddr = ((state == S_STREAM) && mem_res_wr_almost_full)
                               ? pA_set
                               : lu_src_a[LOFF_W +: SET_W];
    always @(posedge clk) begin
        tag_rd <= tag_ram[tl_raddr];
        lru_rd <= lru_ram[tl_raddr];
    end

    // ---- LRU touch (pure function of a rank word) ----
    // Make way `way` MRU (rank 0), age the ways younger than its old rank.
    // Same policy, bit for bit, as the flop version's lru_touch task.
    function automatic [LRUV_W-1:0] lru_touch_f(input [LRUV_W-1:0] ranks,
                                                input [ASW-1:0]    way);
        integer ti;
        reg [ASW-1:0] old;
        begin
            old = {ASW{1'b0}};
            for (ti = 0; ti < ASSOC; ti = ti + 1)
                if (ti[ASW-1:0] == way) old = ranks[ti*ASW +: ASW];
            for (ti = 0; ti < ASSOC; ti = ti + 1) begin
                if (ti[ASW-1:0] == way)
                    lru_touch_f[ti*ASW +: ASW] = {ASW{1'b0}};
                else if (ranks[ti*ASW +: ASW] < old)
                    lru_touch_f[ti*ASW +: ASW] = ranks[ti*ASW +: ASW] + 1'b1;
                else
                    lru_touch_f[ti*ASW +: ASW] = ranks[ti*ASW +: ASW];
            end
        end
    endfunction

    // S_INIT seed: way i gets rank i (0 = MRU .. ASSOC-1 = LRU)
    wire [LRUV_W-1:0] lru_seed;
    genvar gs;
    generate
        for (gs = 0; gs < ASSOC; gs = gs + 1) begin : g_seed
            assign lru_seed[gs*ASW +: ASW] = gs[ASW-1:0];
        end
    endgenerate

    // ---- LRU read-after-write bypass (streaming) ----
    // The rank word a stage-A command reads from the RAM can be stale by up to
    // two writes: the touch being WRITTEN this cycle (stage B, same set) and the
    // touch written LAST cycle (mixed-port read-during-write at the capture edge
    // is undefined on M10K). Forward both; newest wins. Chained same-set touches
    // stay consistent because each bypassed value feeds the next touch.
    // Gated to S_STREAM: outside the stream the RAM is always up to date w.r.t.
    // its readers (snapshots are captured before any conflicting write), and lw_*
    // could be stale vs a later fill-validate touch.
    reg              lw_valid;
    reg [SET_W-1:0]  lw_set;
    reg [LRUV_W-1:0] lw_ranks;
    wire stream_touch = (state == S_STREAM) && !mem_res_wr_almost_full && pB_valid;
    wire [LRUV_W-1:0] pB_touched = lru_touch_f(pB_lru, pB_way);
    wire [LRUV_W-1:0] lru_eff =
        (stream_touch && (pB_set == pA_set)) ? pB_touched :
        (lw_valid     && (lw_set == pA_set)) ? lw_ranks   : lru_rd;

    // ---- combinational hit / victim select over the looked-up set word ----
    // Inputs: stage A's command while streaming, the peeked command in S_PEEK2.
    // (S_PROC never uses this block — it runs on the snap_* snapshot registers.)
    wire              peek_cmp  = (state == S_PEEK2);
    wire [TAG_W-1:0]  cmp_tag   = peek_cmp ? cand_tag : pA_tag;
    wire [SET_W-1:0]  cmp_set   = peek_cmp ? cand_set : pA_set;
    wire [LRUV_W-1:0] cmp_lru   = peek_cmp ? lru_rd : lru_eff;
    wire [ASSOC-1:0]  cmp_valid = cache_valid[cmp_set];

    integer wi;
    reg                hit_c;
    reg  [ASW-1:0]     hit_way_c;
    reg  [ASW-1:0]     victim_c;
    reg                vic_done;
    always @* begin
        hit_c     = 1'b0;
        hit_way_c = {ASW{1'b0}};
        for (wi = 0; wi < ASSOC; wi = wi + 1)
            if (cmp_valid[wi] && (tag_rd[wi*TAG_W +: TAG_W] == cmp_tag)) begin
                hit_c     = 1'b1;
                hit_way_c = wi[ASW-1:0];
            end
        // victim: prefer the lowest-index invalid way, else the LRU (rank max) way
        victim_c = {ASW{1'b0}};
        vic_done = 1'b0;
        for (wi = ASSOC-1; wi >= 0; wi = wi - 1)
            if (!cmp_valid[wi]) begin victim_c = wi[ASW-1:0]; vic_done = 1'b1; end
        if (!vic_done)
            for (wi = 0; wi < ASSOC; wi = wi + 1)
                if (cmp_lru[wi*ASW +: ASW] == (ASSOC-1)) victim_c = wi[ASW-1:0];
    end

    // ---- streaming stage-A verdict ----
    wire sA_hit  = pA_valid && (pA_cmd == CMD_READ) && hit_c && !pA_aerr;
    wire sA_slow = pA_valid && !sA_hit;              // miss / write / aerr / noop
    wire pA_rd_miss = (pA_cmd == CMD_READ)  && !pA_aerr && !hit_c;
    wire pA_wr_fast = (pA_cmd == CMD_WRITE) && !pA_aerr;
    wire stream_stall = (state == S_STREAM) && mem_res_wr_almost_full;

    // ---- slow-path lookup snapshots ----
    // Captured on the stage-A exit cycle; consumed by S_PROC (decisions), the
    // fast-path write (wr_is_hit/wr_way latch directly), and slot A's fill
    // validate (whole-word tag/LRU read-modify-write). Valid from capture until
    // the fill/write completes: nothing else writes that set in between (the
    // stream is drained; a paired slot B is a DIFFERENT set by rule).
    reg [TAGV_W-1:0] snap_tags;
    reg [LRUV_W-1:0] snap_lru;
    reg              snap_hit;
    reg [ASW-1:0]    snap_hit_way;
    reg [ASW-1:0]    snap_victim;
    // slot B's set snapshot (captured in S_PEEK2 for B's validate RMW)
    reg [TAGV_W-1:0] fillB_tags;
    reg [LRUV_W-1:0] fillB_lru;

    // rd_en pulses in S_REQ (cold refetch) and EVERY streaming cycle the pipeline
    // advances — the pop is SPECULATIVE (the popped command's verdict is only
    // known one cycle later at stage A), so a slow-path exit parks the in-flight
    // command in the skid. It stays low on a stall (almost_full), on the exit
    // cycle itself, when both hold registers are full (defensive), and on the
    // empty-drain cycle (a pop there would land in S_REQ unconsumed and be lost).
    assign mem_req_rd_en = (state == S_REQ)
                        || ((state == S_STREAM) && !mem_res_wr_almost_full && !sA_slow
                            && !(pk_valid && sk_valid) && (lu_src_v || pA_valid))
                        // DUAL: on burst-A acceptance, pop the next command so it is
                        // live in S_PEEK for the pair decision (unless the skid holds
                        // an older command — peeking would reorder).
                        || ((state == S_FILL_CMD) && dual_en_q && !ddr3_waitrequest && !sk_valid);

    reg [LOFF_W:0]  beat;        // 0..LINEW beat counter (one extra bit)
    reg [ASW-1:0]   sel_way;     // victim way being filled / served on a miss
    reg [ASW-1:0]   wr_way;      // way to update on a write hit
    reg             wr_is_hit;   // the in-flight write hit a cached line
    reg [SET_W-1:0] init_idx;    // S_INIT walk index

    // ---- cache_data read port (combinational address, registered output) ----
    // Serve states read the HEAD of the fallback serve queue (sv_rd); a streaming
    // stall re-reads Stage B's word (so cache_rdata holds across the stall); else
    // present stage A's hit word, which becomes Stage B next cycle.
    wire serve_rd = (state == S_SERVE_ADR) || (state == S_SERVE);
    wire [DIDX_W-1:0] raddr_comb = serve_rd     ? {sv_set[sv_rd], sv_way[sv_rd], sv_off[sv_rd]}
                                 : stream_stall ? {pB_set,  pB_way,   pB_off}
                                 :                {pA_set,  hit_way_c, pA_off};
    reg [63:0] cache_rdata;
    always @(posedge clk) cache_rdata <= cache_data[raddr_comb];

    // fill response timeout (belt-and-suspenders; bursts return at 90 MHz per BIST)
    localparam [13:0] FILL_TIMEOUT = 14'd8191;
    reg [13:0] fill_to;
    reg        fill_failed;      // a fill timed out: serve zero, don't validate

    // ---- CRITICAL-WORD early-serve (cwf_en) ----
    // The burst returns the line in word order, so the REQUESTED word arrives at
    // beat == cur_off. Instead of waiting for all LINEW beats + S_FILL_DRN +
    // S_SERVE_ADR + S_SERVE to read it back from BRAM, emit ddr3_readdata straight
    // to the response FIFO the cycle that beat lands, then keep filling the rest of
    // the line in the background. `served` records that the word was emitted (so the
    // end-of-fill path skips the serve states and goes directly to refetch). Best-
    // effort: if the response FIFO is full at that beat, served stays 0 and the
    // legacy serve-at-end path runs. NEVER early-serves on a timed-out fill.
    reg        cwf_en_q;        // registered enable (no combinational fanout from the pin)
    reg        served;          // slot-A requested word emitted during the fill

    // active COLLECT-slot fields (slot B while c2, else slot A):
    wire [SET_W-1:0]  c_set = c2 ? ifb_set : cur_set;
    wire [ASW-1:0]    c_way = c2 ? ifb_way : sel_way;
    wire [LOFF_W-1:0] c_off = c2 ? ifb_off : cur_off;
    wire [TAG_W-1:0]  c_tag = c2 ? ifb_tag : cur_tag;
    wire              c_aerr   = c2 ? 1'b0    : cur_aerr;     // B is never an ADDR_ERR
    wire              c_served = c2 ? served_b : served;

    // A burst beat is landing this cycle (any fill-region state — collection is
    // centralized so a beat is never dropped while we are peeking/issuing B):
    wire in_fill   = (state == S_FILL_CMD) || (state == S_FILL_DAT)
                  || (state == S_PEEK)     || (state == S_PEEK2)
                  || (state == S_ISSUE2);
    wire fill_beat = in_fill && ddr3_readdatavalid;
    // ...and it is the active slot's requested word, the FIFO can take it, CWF on.
    // ORDER GUARD: slot B may early-serve only once slot A has been served (`served`)
    // — else, if A's critical beat was backpressured to the serve queue, B's cwf
    // would emit B before A (responses must stay in request order A then B).
    wire cwf_fire  = cwf_en_q && fill_beat && !c_served && !c_aerr
                  && (beat[LOFF_W-1:0] == c_off) && !mem_res_wr_almost_full
                  && (!c2 || served);
    wire fill_last = fill_beat && (beat == LINEW-1);

    // ---- cache_data SINGLE WRITE PORT (combinational decode -> one clocked write) ----
    // ALL writes to cache_data go through this one port so the 2048x64b array infers
    // as M10K (a write scattered across case branches / the pre-case COLLECT block
    // breaks inference and the array collapses to 130k flip-flops). Two writers, both
    // mutually exclusive by state: a burst-fill beat (active slot), and a write-hit
    // cache update in S_WR_CMD.
    reg              cache_we;
    reg [DIDX_W-1:0] cache_waddr;
    reg [63:0]       cache_wdata;
    always @* begin
        cache_we    = 1'b0;
        cache_waddr = {c_set, c_way, beat[LOFF_W-1:0]};
        cache_wdata = ddr3_readdata;
        if (fill_beat) begin
            cache_we = 1'b1;                         // fill: write the active slot's beat
        end else if ((state == S_WR_CMD) && !ddr3_waitrequest && wr_is_hit) begin
            cache_we    = 1'b1;                       // write-hit: update the cached word
            cache_waddr = {cur_set, wr_way, cur_off};
            cache_wdata = cur_dta;
        end
    end
    always @(posedge clk) if (cache_we) cache_data[cache_waddr] <= cache_wdata;

    // ---- tag_ram SINGLE WRITE PORT ----
    // Only writer: the fill validate (last beat of the active slot). Whole-word
    // write: the set's snapshot (captured at the miss lookup) with the victim
    // way's slice replaced — legal because nothing else writes that set between
    // capture and validate.
    reg [TAGV_W-1:0] tag_wr_word;
    integer twi;
    always @* begin
        tag_wr_word = c2 ? fillB_tags : snap_tags;
        for (twi = 0; twi < ASSOC; twi = twi + 1)
            if (twi[ASW-1:0] == c_way)
                tag_wr_word[twi*TAG_W +: TAG_W] = c_tag;
    end
    always @(posedge clk) if (fill_last) tag_ram[c_set] <= tag_wr_word;

    // ---- lru_ram SINGLE WRITE PORT ----
    // Writers (mutually exclusive by state): S_INIT seed walk, fill validate
    // touch, streaming stage-B touch, write-hit touch.
    reg              lru_we;
    reg [SET_W-1:0]  lru_waddr;
    reg [LRUV_W-1:0] lru_wdata;
    always @* begin
        lru_we    = 1'b0;
        lru_waddr = {SET_W{1'b0}};
        lru_wdata = {LRUV_W{1'b0}};
        if (state == S_INIT) begin
            lru_we    = 1'b1;
            lru_waddr = init_idx;
            lru_wdata = lru_seed;
        end else if (fill_last) begin
            lru_we    = 1'b1;
            lru_waddr = c_set;
            lru_wdata = lru_touch_f(c2 ? fillB_lru : snap_lru, c_way);
        end else if (stream_touch) begin
            lru_we    = 1'b1;
            lru_waddr = pB_set;
            lru_wdata = pB_touched;
        end else if ((state == S_WR_CMD) && !ddr3_waitrequest && wr_is_hit) begin
            lru_we    = 1'b1;
            lru_waddr = cur_set;
            lru_wdata = lru_touch_f(snap_lru, wr_way);
        end
    end
    always @(posedge clk) if (lru_we) lru_ram[lru_waddr] <= lru_wdata;

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= S_INIT;
            init_idx       <= 0;
            mem_res_wr_en  <= 1'b0;
            mem_res_wr_dta <= 64'd0;
            ddr3_read      <= 1'b0;
            ddr3_write     <= 1'b0;
            ddr3_addr      <= 29'd0;
            ddr3_burstcnt  <= 8'd1;
            ddr3_writedata <= 64'd0;
            cur_cmd        <= 2'd0;
            cur_addr       <= 22'd0;
            cur_dta        <= 64'd0;
            beat           <= 0;
            sel_way        <= 0;
            pA_valid       <= 1'b0;
            pA_cmd         <= 2'd0;
            pA_addr        <= 22'd0;
            pA_dta         <= 64'd0;
            pB_valid       <= 1'b0;
            pB_set         <= 0;
            pB_way         <= 0;
            pB_off         <= 0;
            pB_lru         <= 0;
            sk_valid       <= 1'b0;
            sk_cmd         <= 2'd0;
            sk_addr        <= 22'd0;
            sk_dta         <= 64'd0;
            lw_valid       <= 1'b0;
            lw_set         <= 0;
            lw_ranks       <= 0;
            snap_tags      <= 0;
            snap_lru       <= 0;
            snap_hit       <= 1'b0;
            snap_hit_way   <= 0;
            snap_victim    <= 0;
            fillB_tags     <= 0;
            fillB_lru      <= 0;
            wr_way         <= 0;
            wr_is_hit      <= 1'b0;
            fill_to        <= 0;
            fill_failed    <= 1'b0;
            cwf_en_q       <= 1'b0;
            served         <= 1'b0;
            dual_en_q      <= 1'b0;
            ifb_set        <= 0;
            ifb_way        <= 0;
            ifb_off        <= 0;
            ifb_tag        <= 0;
            ifb_active     <= 1'b0;
            pairing        <= 1'b0;
            a_done         <= 1'b0;
            c2             <= 1'b0;
            served_b       <= 1'b0;
            pk_valid       <= 1'b0;
            pk_cmd         <= 2'd0;
            pk_addr        <= 22'd0;
            pk_dta         <= 64'd0;
            sv_set[0] <= 0; sv_set[1] <= 0;
            sv_way[0] <= 0; sv_way[1] <= 0;
            sv_off[0] <= 0; sv_off[1] <= 0;
            sv_fail[0] <= 0; sv_fail[1] <= 0;
            sv_wr <= 1'b0; sv_rd <= 1'b0; sv_n <= 2'd0;
        end
        else begin
            mem_res_wr_en <= 1'b0;        // default single-cycle strobe
            cwf_en_q      <= cwf_en;      // register the enable pins
            dual_en_q     <= dual_en;

            // =================================================================
            // CENTRALIZED COLLECT (runs in ALL fill-region states so a returning
            // beat is never dropped while we are peeking/issuing burst B).
            // Routes the beat to the ACTIVE slot (c2 ? B : A), critical-word early-
            // serves its requested word, and on the LAST beat validates the line
            // (valid bit here; the tag/LRU words commit through their write ports
            // this same cycle), queues a fallback serve if it wasn't early-served,
            // then advances to slot B (pair) or finishes.
            // =================================================================
            // CWF early-serve for the active slot:
            if (cwf_fire) begin
                mem_res_wr_dta <= ddr3_readdata;
                mem_res_wr_en  <= 1'b1;
                if (c2) served_b <= 1'b1; else served <= 1'b1;
            end
            if (fill_beat) begin
                // (the beat itself is written via the single cache_data write port)
                if (beat == LINEW-1) begin
                    // validate the active line (tag + LRU via their write ports)
                    cache_valid[c_set][c_way] <= 1'b1;
                    // queue a fallback serve unless the word was/is early-served
                    if (!(c_served || cwf_fire)) begin
                        sv_set[sv_wr] <= c_set; sv_way[sv_wr] <= c_way;
                        sv_off[sv_wr] <= c_off; sv_fail[sv_wr] <= 1'b0;
                        sv_wr <= sv_wr + 1'b1;  sv_n <= sv_n + 1'b1;
                    end
                    if (!c2 && pairing) begin
                        // slot A done in a pair: continue to B if it is in flight,
                        // else mark a_done and wait (B accept handled below).
                        if (ifb_active) begin c2 <= 1'b1; beat <= 0; end
                        else            a_done <= 1'b1;
                    end else begin
                        // single A, or B just finished: drain/serve. Preserve the
                        // cwf fast-path (nothing queued AND this word served). If a
                        // held command exists (pk/sk), go to S_STREAM DIRECTLY
                        // (not S_REQ — S_REQ pops the FIFO and would skip a command
                        // while S_STREAM consumes the hold first).
                        if ((sv_n == 2'd0) && (c_served || cwf_fire))
                            state <= (pk_valid || sk_valid) ? S_STREAM : S_REQ;
                        else
                            state <= S_FILL_DRN;
                    end
                end else begin
                    beat <= beat + 1'b1;
                end
            end
            else if (!c2 && a_done && ifb_active) begin
                // slot A finished before burst B was accepted; B is now in flight and
                // no A beat is pending — switch COLLECT to slot B before its beats land.
                c2 <= 1'b1; beat <= 0; a_done <= 1'b0;
            end
            else if (in_fill && (fill_to == FILL_TIMEOUT)) begin
                // safety net: a fill stalled. Mark the active line failed (stays
                // invalid), queue a zero-serve for it, and finish.
                fill_failed   <= 1'b1;
                sv_set[sv_wr] <= c_set; sv_way[sv_wr] <= c_way;
                sv_off[sv_wr] <= c_off; sv_fail[sv_wr] <= 1'b1;
                sv_wr <= sv_wr + 1'b1;  sv_n <= sv_n + 1'b1;
                state <= S_FILL_DRN;
            end
            else if (in_fill) begin
                fill_to <= fill_to + 1'b1;
            end

            case (state)
            // =================================================================
            // Walk every set: invalidate all ways, seed LRU ranks (0,1,2,3 — via
            // the lru_ram write port). Avoids a huge async-reset fanout.
            S_INIT: begin
                cache_valid[init_idx] <= {ASSOC{1'b0}};
                if (init_idx == NSETS-1) state <= S_REQ;
                else                     init_idx <= init_idx + 1'b1;
            end

            // =================================================================
            S_REQ: begin                 // rd_en is combinationally high here
                pA_valid <= 1'b0;         // enter streaming with an empty pipeline
                pB_valid <= 1'b0;
                sk_valid <= 1'b0;
                lw_valid <= 1'b0;
                state    <= S_STREAM;
            end

            // =================================================================
            // PIPELINED HIT LOOP (1 word/cycle). Three overlapped stages:
            //   Stage T: present the live source's SET to the tag/LRU RAM and
            //            register the command into pA_* (rd_en fetched ahead).
            //   Stage A: the set word is on tag_rd/lru_rd — verdict. A clean READ
            //            hit presents its data-RAM address and moves to pB_*; a
            //            miss ISSUES ITS BURST NOW (fast entry), a write issues
            //            its beat now; ADDR_ERR/NOOP go to S_PROC.
            //   Stage B: cache_rdata is out — emit + LRU touch (write port).
            // Backpressure stalls all three stages without losing a command (the
            // skid); the speculative in-flight pop on a slow exit parks there too.
            S_STREAM: begin
                if (mem_res_wr_almost_full) begin
                    // STALL: can't emit Stage B. Capture a just-arrived FIFO command
                    // into the skid (its `valid` is 1 cycle only) so it survives;
                    // tl_raddr re-reads Stage A's set and raddr_comb Stage B's word
                    // so tag_rd/lru_rd/cache_rdata hold. No emit/consume/fetch.
                    if (!sk_valid && !pk_valid && mem_req_rd_valid) begin
                        sk_cmd   <= mem_req_rd_cmd;
                        sk_addr  <= mem_req_rd_addr;
                        sk_dta   <= mem_req_rd_dta;
                        sk_valid <= 1'b1;
                    end
                end else begin
                    // Stage B: emit the hit looked up two cycles ago. Its LRU
                    // touch commits through the write port this cycle; lw_* keeps
                    // the written word for next cycle's read bypass.
                    if (pB_valid) begin
                        mem_res_wr_dta <= cache_rdata;
                        mem_res_wr_en  <= 1'b1;
                        lw_valid <= 1'b1;
                        lw_set   <= pB_set;
                        lw_ranks <= pB_touched;
                    end
                    if (sA_slow) begin
                        // Stage A holds a non-streamable command: capture its
                        // lookup and hand off. The stage-T source is left in
                        // place (younger commands, served after); a live FIFO
                        // word — the speculative pop — parks in the skid.
                        cur_cmd      <= pA_cmd;
                        cur_addr     <= pA_addr;
                        cur_dta      <= pA_dta;
                        snap_tags    <= tag_rd;
                        snap_lru     <= lru_eff;
                        snap_hit     <= hit_c;
                        snap_hit_way <= hit_way_c;
                        snap_victim  <= victim_c;
                        pA_valid     <= 1'b0;
                        pB_valid     <= 1'b0;
                        lw_valid     <= 1'b0;
                        if (!sk_valid && !pk_valid && mem_req_rd_valid) begin
                            sk_cmd   <= mem_req_rd_cmd;
                            sk_addr  <= mem_req_rd_addr;
                            sk_dta   <= mem_req_rd_dta;
                            sk_valid <= 1'b1;
                        end
                        if (pA_rd_miss) begin
                            // FAST miss entry (timing parity with the flop-tag
                            // version: verdict -> S_FILL_CMD in one cycle).
                            // Invalidate the victim now (so a fill timeout can't
                            // leave a stale valid line), issue one burst line-fill.
                            sel_way                        <= victim_c;
                            cache_valid[pA_set][victim_c]  <= 1'b0;
                            ddr3_addr                      <= {7'b0011000, pA_line_base};
                            ddr3_burstcnt                  <= LINEW[7:0];
                            ddr3_read                      <= 1'b1;
                            beat                           <= 0;
                            fill_to                        <= 0;
                            fill_failed                    <= 1'b0;
                            served                         <= 1'b0;   // CWF: not yet emitted
                            // DUAL bookkeeping: fresh fill, empty serve queue, slot A.
                            pairing    <= 1'b0;  ifb_active <= 1'b0;
                            c2         <= 1'b0;  a_done     <= 1'b0;  served_b <= 1'b0;
                            sv_wr      <= 1'b0;  sv_rd      <= 1'b0;  sv_n     <= 2'd0;
                            state                          <= S_FILL_CMD;
                        end else if (pA_wr_fast) begin
                            // FAST write entry (single-beat write-through)
                            wr_is_hit      <= hit_c;       // update cached word on accept
                            wr_way         <= hit_way_c;
                            ddr3_addr      <= {7'b0011000, pA_addr};
                            ddr3_burstcnt  <= 8'd1;
                            ddr3_writedata <= pA_dta;
                            ddr3_write     <= 1'b1;
                            state          <= S_WR_CMD;
                        end else begin
                            state <= S_PROC;               // ADDR_ERR / NOOP / REFRESH
                        end
                    end else begin
                        // Stage A -> B advance (or bubble): stage A's hit word
                        // address is on raddr_comb; its bypassed rank word rides
                        // along for the stage-B touch.
                        pB_valid <= sA_hit;
                        pB_set   <= pA_set;
                        pB_way   <= hit_way_c;
                        pB_off   <= pA_off;
                        pB_lru   <= lru_eff;
                        // Stage T -> A: consume the live source (pk first, then
                        // skid, then FIFO — order is preserved by the priority).
                        pA_cmd   <= lu_src_c;
                        pA_addr  <= lu_src_a;
                        pA_dta   <= lu_src_d;
                        pA_valid <= lu_src_v;
                        if (lu_src_v) begin
                            if (pk_valid)      pk_valid <= 1'b0;
                            else if (sk_valid) sk_valid <= 1'b0;
                        end else if (!pA_valid) begin
                            state <= S_REQ;   // T and A empty: drain (pB emitted above), refetch
                        end
                    end
                end
            end

            // =================================================================
            // SLOW PATH on the LATCHED command + its snap_* lookup snapshot.
            // Reachable only for the RARE cases (ADDR_ERR read/write, NOOP,
            // REFRESH) — read misses and normal writes fast-path from S_STREAM.
            // The miss/write arms are kept intact (they run correctly off the
            // snapshots) as belt-and-suspenders.
            S_PROC: begin
                case (cur_cmd)
                CMD_READ: begin
                    if (cur_aerr) begin
                        if (!mem_res_wr_almost_full) begin
                            mem_res_wr_dta <= 64'd0;   // sentinel: synthetic zero
                            mem_res_wr_en  <= 1'b1;
                            state          <= (pk_valid || sk_valid) ? S_STREAM : S_REQ;
                        end
                    end
                    else begin
                        // miss (defensive; normally fast-pathed): invalidate the
                        // victim, then issue one burst line-fill.
                        sel_way                          <= snap_victim;
                        cache_valid[cur_set][snap_victim] <= 1'b0;
                        ddr3_addr                        <= {7'b0011000, {cur_addr[21:LOFF_W], {LOFF_W{1'b0}}}};
                        ddr3_burstcnt                    <= LINEW[7:0];
                        ddr3_read                        <= 1'b1;
                        beat                             <= 0;
                        fill_to                          <= 0;
                        fill_failed                      <= 1'b0;
                        served                           <= 1'b0;
                        pairing    <= 1'b0;  ifb_active <= 1'b0;
                        c2         <= 1'b0;  a_done     <= 1'b0;  served_b <= 1'b0;
                        sv_wr      <= 1'b0;  sv_rd      <= 1'b0;  sv_n     <= 2'd0;
                        state                            <= S_FILL_CMD;
                    end
                end
                CMD_WRITE: begin
                    if (cur_aerr) begin
                        state <= (pk_valid || sk_valid) ? S_STREAM : S_REQ;  // drop sentinel write
                    end else begin
                        wr_is_hit      <= snap_hit;    // update cached word on accept
                        wr_way         <= snap_hit_way;
                        ddr3_addr      <= {7'b0011000, cur_addr};
                        ddr3_burstcnt  <= 8'd1;
                        ddr3_writedata <= cur_dta;
                        ddr3_write     <= 1'b1;
                        state          <= S_WR_CMD;
                    end
                end
                default: state <= (pk_valid || sk_valid) ? S_STREAM : S_REQ;  // NOOP / REFRESH
                endcase
            end

            // =================================================================
            // Burst read (slot A): wait for command acceptance. Beats (incl. a same-
            // cycle accept+data) are collected by the centralized COLLECT block above.
            // On accept, in DUAL mode: if the skid already holds the next command
            // (the speculative pop parked it on the miss-exit cycle) its set word
            // has been on the tag-RAM address since the exit — decide DIRECTLY in
            // S_PEEK2; else pop the FIFO for a candidate (rd_en was pulsed
            // combinationally this cycle) and latch it in S_PEEK first.
            S_FILL_CMD: begin
                if (!ddr3_waitrequest) begin
                    ddr3_read <= 1'b0;
                    state     <= !dual_en_q ? S_FILL_DAT
                               : sk_valid   ? S_PEEK2
                               :              S_PEEK;
                end
            end

            // =================================================================
            // DUAL: the next command is live this cycle (popped on A's acceptance).
            // Latch it into pk_* (its FIFO valid is 1 cycle only) and present its
            // set to the tag/LRU RAM (via the stage-T mux — pk takes priority next
            // cycle so the address holds); decide in S_PEEK2.
            S_PEEK: begin
                if (mem_req_rd_valid) begin
                    pk_cmd   <= mem_req_rd_cmd;
                    pk_addr  <= mem_req_rd_addr;
                    pk_dta   <= mem_req_rd_dta;
                    pk_valid <= 1'b1;
                    state    <= S_PEEK2;
                end else begin
                    state <= S_FILL_DAT;                           // FIFO empty: single A
                end
            end

            // =================================================================
            // DUAL: the candidate's (skid- or pk-held) set word is on
            // tag_rd/lru_rd. Pair it as burst B iff it is a READ MISS to a
            // DIFFERENT set (so its victim can't collide with A's in-flight way;
            // also guarantees A's validate never writes B's set word between B's
            // snapshot and B's validate). Otherwise it stays in its hold register
            // for S_STREAM to process in order; single A fill.
            S_PEEK2: begin
                if ((cand_cmd == CMD_READ) && !hit_c && !cand_aerr && (cand_set != cur_set)) begin
                    ifb_set    <= cand_set;
                    ifb_way    <= victim_c;
                    ifb_off    <= cand_off;
                    ifb_tag    <= cand_tag;
                    cache_valid[cand_set][victim_c] <= 1'b0;   // invalidate B's victim
                    fillB_tags <= tag_rd;                      // B's validate RMW base
                    fillB_lru  <= lru_rd;
                    served_b   <= 1'b0;
                    pairing    <= 1'b1;
                    if (cand_is_sk) sk_valid <= 1'b0;          // candidate consumed
                    else            pk_valid <= 1'b0;
                    // issue burst B now (A is already accepted / in flight)
                    ddr3_addr     <= {7'b0011000, cand_line_base};
                    ddr3_burstcnt <= LINEW[7:0];
                    ddr3_read     <= 1'b1;
                    state         <= S_ISSUE2;
                end else begin
                    state <= S_FILL_DAT;                       // candidate stays held
                end
            end

            // =================================================================
            // DUAL: wait for burst B's command to be accepted (A's beats keep
            // streaming into slot A via COLLECT meanwhile). Then collect (A then B).
            S_ISSUE2: begin
                if (!ddr3_waitrequest) begin
                    ddr3_read  <= 1'b0;
                    ifb_active <= 1'b1;
                    state      <= S_FILL_DAT;
                end
            end

            // =================================================================
            // Collection + last-beat validate/advance is entirely in the COLLECT
            // block above; this state just idles while beats stream in.
            S_FILL_DAT: ;

            // =================================================================
            // Drain + serve: emit the fallback serve queue (words whose cwf early-
            // serve didn't fire), in order. S_FILL_DRN lets the last write commit and
            // routes to serving (queue non-empty) or straight to refetch (all early-
            // served). raddr_comb presents the queue head; cache_rdata is valid in
            // S_SERVE one cycle later.
            S_FILL_DRN:  state <= (sv_n != 2'd0) ? S_SERVE_ADR
                                                 : ((pk_valid || sk_valid) ? S_STREAM : S_REQ);
            S_SERVE_ADR: state <= S_SERVE;

            S_SERVE: begin
                if (!mem_res_wr_almost_full) begin
                    mem_res_wr_dta <= sv_fail[sv_rd] ? 64'd0 : cache_rdata;
                    mem_res_wr_en  <= 1'b1;
                    sv_rd          <= sv_rd + 1'b1;
                    sv_n           <= sv_n - 1'b1;
                    // more queued -> next serve; else hand off (S_STREAM if a held
                    // command exists, else S_REQ).
                    state          <= (sv_n > 2'd1) ? S_SERVE_ADR
                                                    : ((pk_valid || sk_valid) ? S_STREAM : S_REQ);
                end
            end

            // =================================================================
            // Single-beat write: wait for acceptance. On a write hit the cached
            // word updates via the cache_data write port and the LRU touch
            // commits via the lru_ram write port (both decoded on this accept).
            S_WR_CMD: begin
                if (!ddr3_waitrequest) begin
                    ddr3_write <= 1'b0;
                    state <= (pk_valid || sk_valid) ? S_STREAM : S_REQ;
                end
            end
            endcase
        end
    end

    // =========================================================================
    // Debug counters / telemetry (match mem_shim.sv field semantics)
    // =========================================================================
    reg [15:0] rd_count, wr_count, rsp_count;
    wire rd_accepted = ddr3_read  && !ddr3_waitrequest;
    wire wr_accepted = ddr3_write && !ddr3_waitrequest;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_count <= 0; wr_count <= 0; rsp_count <= 0;
        end else begin
            if (rd_accepted)        rd_count  <= rd_count  + 1'd1;  // burst cmds (= read misses)
            if (wr_accepted)        wr_count  <= wr_count  + 1'd1;
            if (ddr3_readdatavalid) rsp_count <= rsp_count + 1'd1;  // beats
        end
    end

    // =========================================================================
    // Bottleneck telemetry (windowed) — answers "is the bridge the bottleneck?"
    // =========================================================================
    // Over each fixed 65536-cycle window (~0.73 ms @90 MHz) accumulate:
    //   tele_idle = cycles BLOCKED BY THE DECODER: the request FIFO is empty when
    //               we want a command (S_REQ / streaming with no live source), OR
    //               the response FIFO is full when we want to emit.
    //   tele_fill = cycles actively servicing a read MISS (burst fill + serve).
    // Latched at window end as 8-bit fractions (count>>8), packed {idle, fill}:
    //   high byte ~FF  => bridge is STARVED / back-pressured by the decoder
    //                     => DECODER-bound; faster memory cannot help.
    //   low byte  ~FF  => bridge is pegged in miss FILLs => DDR miss-latency-bound
    //                     => the lever is fewer/over-lapped DDR round-trips.
    //   both ~00       => bridge busy serving cache HITs (hit-throughput-bound).
    // Surfaced on debug_read_pend_cycles (UART field "PC" + overlay row 14 via emu).
    reg [15:0] win_ctr;
    reg [16:0] idle_acc, fill_acc;     // 17-bit: detect the full-window (all-1) case
    reg [7:0]  idle_pct, fill_pct;

    wire tele_idle = (state == S_REQ)
                  || (state == S_STREAM && (!lu_src_v || mem_res_wr_almost_full))
                  || (state == S_SERVE  && mem_res_wr_almost_full);
    wire tele_fill = (state == S_FILL_CMD) || (state == S_FILL_DAT)
                  || (state == S_FILL_DRN) || (state == S_SERVE_ADR)
                  || (state == S_SERVE && !mem_res_wr_almost_full);

    always @(posedge clk) begin
        if (!rst_n) begin
            win_ctr <= 0; idle_acc <= 0; fill_acc <= 0; idle_pct <= 0; fill_pct <= 0;
        end else if (&win_ctr) begin                 // 65535 -> window (65536 cyc) done
            idle_pct <= idle_acc[16] ? 8'hFF : idle_acc[15:8];
            fill_pct <= fill_acc[16] ? 8'hFF : fill_acc[15:8];
            idle_acc <= {16'd0, tele_idle};          // seed next window with this cycle
            fill_acc <= {16'd0, tele_fill};
            win_ctr  <= 0;
        end else begin
            if (tele_idle && !idle_acc[16]) idle_acc <= idle_acc + 1'b1;
            if (tele_fill && !fill_acc[16]) fill_acc <= fill_acc + 1'b1;
            win_ctr <= win_ctr + 1'b1;
        end
    end

    // =========================================================================
    // Cache HIT/MISS-RATE telemetry — the compute-vs-memory disambiguator
    // =========================================================================
    // The bottleneck row above ({idle%,fill%}) showed Matrix "neither saturates"
    // = ambiguous. THIS row settles it. Per 65536-cycle window, classify every
    // READ access by outcome and report the MISS RATE:
    //   cm_hit  = a streamed read served straight from cache (S_STREAM Stage-B emit)
    //   cm_miss = a read that had to launch a burst line-fill (the stage-A miss
    //             verdict / fast fill entry, non-ADDR_ERR). ADDR_ERR sentinel
    //             reads are excluded (not a real cache access).
    // At window close, miss_pct = cm_miss*256/(cm_hit+cm_miss) via a small
    // restoring divider (runs in ~26 of the window's 65536 cycles), 8-bit
    // (0xFF ~= 100% miss). reads_hi = saturating top byte of (cm_hit+cm_miss) =
    // read INTENSITY, so a high miss% is only trusted when reads_hi shows real
    // traffic (a near-idle window's ratio is noise). Packed {miss_pct, reads_hi}.
    //
    //   Matrix miss_pct >> BBB  => high-motion ref-read SCATTER thrashes the cache
    //                              => MEMORY-bound; lever = cache geometry/assoc.
    //   Matrix miss_pct ~= BBB  => cache copes; deficit is pure motion-comp/IDCT
    //                              => COMPUTE-bound; lever = decoder datapath.
    // See memory clock-lever-exhausted-matrix / current-clocks-levers-spent.
    wire cm_hit  = (state == S_STREAM) && !mem_res_wr_almost_full && pB_valid;
    wire cm_miss = (state == S_STREAM) && !mem_res_wr_almost_full
                 && sA_slow && pA_rd_miss;

    reg [15:0] cm_win;
    reg [16:0] cm_hit_acc, cm_miss_acc;        // per-window counts (17b, saturating)
    reg [7:0]  miss_pct, reads_hi;             // latched window result

    // sequential restoring divider: miss_pct = (cm_miss<<8)/(cm_hit+cm_miss)
    reg        div_busy;
    reg [24:0] div_num;                        // (cm_miss<<8): 17b + 8b = 25b
    reg [16:0] div_den;                        // cm_hit + cm_miss
    reg [17:0] div_rem;
    reg [24:0] div_quot;
    reg [4:0]  div_i;
    wire [17:0] div_trial = {div_rem[16:0], div_num[24]};

    always @(posedge clk) begin
        if (!rst_n) begin
            cm_win <= 0; cm_hit_acc <= 0; cm_miss_acc <= 0;
            miss_pct <= 0; reads_hi <= 0;
            div_busy <= 1'b0; div_num <= 0; div_den <= 0;
            div_rem <= 0; div_quot <= 0; div_i <= 0;
        end else begin
            // ---- per-window accumulation + window close ----
            if (&cm_win) begin
                div_num     <= {cm_miss_acc, 8'd0};            // miss << 8
                div_den     <= cm_hit_acc + cm_miss_acc;
                div_rem     <= 0;
                div_quot    <= 0;
                div_i       <= 5'd25;
                div_busy    <= (cm_hit_acc + cm_miss_acc) != 0;
                if ((cm_hit_acc + cm_miss_acc) == 0) miss_pct <= 8'd0;
                reads_hi    <= (cm_hit_acc[16] | cm_miss_acc[16]
                              | ((cm_hit_acc + cm_miss_acc) >= 17'h10000))
                                 ? 8'hFF : (cm_hit_acc + cm_miss_acc) >> 8;
                cm_win      <= 0;
                cm_hit_acc  <= {16'd0, cm_hit};                // seed next window
                cm_miss_acc <= {16'd0, cm_miss};
            end else begin
                if (cm_hit  && !cm_hit_acc[16])  cm_hit_acc  <= cm_hit_acc  + 1'b1;
                if (cm_miss && !cm_miss_acc[16]) cm_miss_acc <= cm_miss_acc + 1'b1;
                cm_win <= cm_win + 1'b1;
            end

            // ---- restoring divider (independent; finishes long before next close) ----
            if (div_busy) begin
                if (div_i != 0) begin
                    if (div_trial >= {1'b0, div_den}) begin
                        div_rem  <= div_trial - {1'b0, div_den};
                        div_quot <= {div_quot[23:0], 1'b1};
                    end else begin
                        div_rem  <= div_trial;
                        div_quot <= {div_quot[23:0], 1'b0};
                    end
                    div_num <= {div_num[23:0], 1'b0};
                    div_i   <= div_i - 1'b1;
                end else begin
                    div_busy <= 1'b0;
                    miss_pct <= (div_quot > 25'd255) ? 8'hFF : div_quot[7:0];
                end
            end
        end
    end

    assign debug_state            = state;           // 0..14 (2/4 retired)
    assign debug_saved_cmd        = cur_cmd;
    assign debug_sdram_busy       = ddr3_waitrequest;
    assign debug_sdram_ack        = rd_accepted | wr_accepted;
    assign debug_rd_count         = rd_count;
    assign debug_wr_count         = wr_count;
    assign debug_rsp_count        = rsp_count;
    assign debug_read_pend_cycles = {idle_pct, fill_pct};  // {idle%, fill%} per window
    assign debug_cache_missrate   = {miss_pct, reads_hi};  // {miss%, read-intensity}

endmodule
