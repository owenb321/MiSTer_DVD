//============================================================================
//  cosim_main.cpp — Verilator + liba52 co-simulation for the AC-3 front-end.
//
//  Golden reference: liba52.  a52_syncinfo() gives each syncframe's offset,
//  length, and sample rate; a52_frame()+a52_block() expose the channel mode and
//  the block-0 coding tools (coupling, rematrixing) via a52_internal.h.  The
//  same bytes drive the Verilated ac3_front (FIFO -> bit_reader -> sync_crc ->
//  bsi_parse -> audblk_parse -> ... -> imdct_512) and we check, frame-for-frame:
//    - frame boundaries (offset + length) and sample rate            [M2]
//    - BSI: channel mode (acmod) and LFE flag                        [M3]
//    - per-block scope decision: the dut must pulse block_side_valid   [M4]
//      (err_unsupported==0) for every in-PoC-scope block (no coupling,
//      no rematrixing) and raise err_unsupported on the first out-of-
//      scope block.  Real ffmpeg stereo uses coupling/rematrixing, so
//      this also exercises the "fail loud" path on real content.
//
//  Since M10 the dut decodes ALL 6 audio blocks of each frame (block loop), so
//  the golden walks all 6 blocks with liba52 and the cosim checks, per block:
//    - decoded exponents: every absolute exponent from exponent_decode   [M5]
//      == liba52 fbw_expbap[ch].exp[0..endmant-1]  (bit-exact)
//    - bit-allocation pointers: every bap == liba52 bap[]  (bit-exact)   [M6]
//    - full-chain PCM: imdct_512.pcm_mem (Q8.23) within a bounded error  [M7-M9]
//      of liba52's a52_samples()/dynrng  (each stage's done pulse is read
//      out combinationally before the next block overwrites pcm_mem).
//
//  The dut latches err_unsupported and halts on the first out-of-scope block
//  (never decode wrong), so for an out-of-scope stream we validate exactly that
//  frame's header+BSI and the halt; for a fully in-scope stream every frame's
//  6 blocks are decoded and compared.
//
//  Usage: ac3_front_cosim <stream.ac3>
//============================================================================

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>
#include <algorithm>

// Block-0 PCM bounded-error budget vs liba52 (dynrng-normalized), in s16 LSB.
// Two fixed-point stages feed it: mantissa_dequant (~0.1 LSB @ s16) and
// imdct_512 (~0.4 LSB @ s16, torture-vector worst case).  Real content is
// sparse/low-level so the chain errs far less; the measured max is printed each
// run.  Set under the project's +/-2-LSB-@-s16 budget with head-room.
static const double PCM_TOL_LSB = 2.0;
#include <verilated.h>
#include "Vac3_front.h"

extern "C" {
#include <a52dec/a52.h>
#include <a52dec/a52_internal.h>
}

// Per frame the dut now decodes all 6 audio blocks (M10 block loop), so the
// golden + dut state are arrays indexed by block.  Each stage (exponent_decode,
// bit_allocation, imdct_512) pulses its `done` once per block, and the cosim
// reads its combinational port out on that pulse — so block N's values are
// captured before block N+1's IMDCT overwrites the shared pcm_mem (no metering
// needed on the bench side; pcm_done is tied high).
static const int NB = 6;          // audio blocks per AC-3 frame
static const int MAXFBW = 5;      // max full-bandwidth channels (acmod==7)
// fbw channel count by acmod (== liba52 nfchans_tbl).
static int nfchans_of(int acmod) {
    static const int t[8] = {2,1,2,3,3,4,4,5};
    return t[acmod & 7];
}
struct Frame {
    long start_byte;   // byte offset of the 0x0B77 sync word
    int  len_bytes;    // frame length in bytes
    int  sample_rate;  // Hz
    int  acmod;        // golden = A52 channel mode; dut = bsi acmod
    int  nf;           // number of fbw channels (from acmod)
    int  lfe;          // 0/1
    int  oos;          // frame has any coupled/rematrixed block (no full datapath yet)
    int  oos_blk;      // golden: index of the first coupled block (NB if none)
    int  n_inscope;    // golden: # of leading uncoupled blocks decoded (== oos_blk)
    // M12 Stage A: block-0 coupling geometry (golden + dut).  A coupled frame is
    // no longer a hard stop — the side-info parse now walks the coupling syntax,
    // and we golden-check its staged geometry (the datapath that consumes it is
    // Stages B/C/D, so exp/bap/pcm are NOT checked on coupled blocks yet).
    int  coupled;          // block 0 is coupled or rematrixed
    int  g_chincpl, g_cplstrtmant, g_cplendmant, g_ncplbnd, g_cplstrtbnd;
    int  g_phsflginu, g_rematflg;
    float g_cplco[2][18];
    int  geom_cap;         // dut captured block-0 geometry
    int  d_chincpl, d_cplstrtmant, d_cplendmant, d_ncplbnd, d_cplstrtbnd;
    int  d_phsflginu, d_rematflg;
    float d_cplco[2][18];
    // M12 Stage B/C: coupling-channel exponents + bap, PER BLOCK (each coupled
    // block carries its own), indexed by coefficient index [cplstrtmant,
    // cplendmant).  Golden = liba52 st->cpl_expbap.exp[]/.bap[]; dut =
    // exponent_decode/bit_allocation ch 2.
    uint8_t g_cpl_exp[NB][256];  int8_t g_cpl_bap[NB][256];
    uint8_t d_cpl_exp[NB][256];  int8_t d_cpl_bap[NB][256];
    int  cpl_exp_cap[NB], cpl_bap_cap[NB];
    // dut-only outcome:
    int  dut_inscope;  // at least block 0's side info pulsed
    int  dut_oos;      // err_unsupported rose during this frame
    int  err;          // dut err_unsupported sampled at outcome
    int  dut_blocks;   // # of blocks the dut produced PCM for (imdct_done pulses)
    // Per-block golden (liba52) + dut, for the in-scope blocks of this frame.
    int     endmant[NB][MAXFBW];   // golden per-channel coeff count
    uint8_t gexp[NB][MAXFBW][256]; // golden exps (liba52 fbw_expbap.exp)
    uint8_t dexp[NB][MAXFBW][256]; // dut decoded exps (exponent_decode)
    int     exp_cap[NB];           // dut exps read out for this block
    int8_t  gbap[NB][MAXFBW][256]; // golden bap (liba52 fbw_expbap.bap)
    int8_t  dbap[NB][MAXFBW][256]; // dut bap (bit_allocation)
    int     bap_cap[NB];           // dut bap read out for this block
    // LFE exps/bap (7 mantissas): golden = liba52 lfe_expbap; dut = slot 6.
    uint8_t g_lfe_exp[NB][8]; int8_t g_lfe_bap[NB][8];
    uint8_t d_lfe_exp[NB][8]; int8_t d_lfe_bap[NB][8];
    int     lfe_cap[NB];
    // Full-chain time-domain PCM.  The dut parses-and-discards dynrng, so the
    // comparable golden is liba52's a52_samples() divided by the per-block
    // dynrng (a single fbw-coeff scalar; the IMDCT is linear).  dynrng can vary
    // per block, so the normalization is captured per block.
    float   gpcm[NB][MAXFBW][256]; // golden = a52_samples()/dynrng  ([-1,1) float)
    float   dpcm[NB][MAXFBW][256]; // dut pcm_mem (Q8.23 -> float)
    int     pcm_cap[NB];           // dut PCM read out for this block
    // M14 Stage F: centre/surround mix levels (liba52 state->clev/slev, frame
    // constants).  For acmod==7 the dut folds the 5 fbw channels to stereo in
    // place (pcm slots 0/1 = Lo/Ro), so the golden for those slots is
    // Lo=L+clev*C+slev*Ls, Ro=R+clev*C+slev*Rs from the per-channel gpcm.
    double  g_clev, g_slev;
    double  g_dynrng[NB]; // M17: liba52 state->dynrng (== range) per block, for reporting
};

// M17 DRC: the dut now APPLIES dynrng (a uniform per-block gain on every coeff,
// at the IMDCT coeff read — the IMDCT is linear so this matches liba52 folding
// state->dynrng into coeff_get).  So we let liba52 apply its native per-block
// dynrng too (default a52_frame state: dynrngcall=NULL, dynrnge=1) — NO unity
// callback.  Both sides scale block b's coeffs by the same range_b, so their
// overlap/delay lines stay consistent across the inter-block add even when range
// varies per block.  (Earlier the dut discarded dynrng, so the golden was forced
// to unity; post-hoc dividing the golden by a per-block scalar was wrong because
// the overlap mixes two blocks with different range — see the git history.)

static int acmod_from_flags(int flags) {
    int ch = flags & A52_CHANNEL_MASK;
    if (ch == A52_STEREO || ch == A52_DOLBY) return 2;   // 2/0
    if (ch == A52_MONO || ch == A52_CHANNEL1 || ch == A52_CHANNEL2) return 1; // 1/0
    return ch;
}

static std::vector<uint8_t> read_file(const char* path) {
    FILE* f = std::fopen(path, "rb");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", path); std::exit(2); }
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> buf(n);
    if (std::fread(buf.data(), 1, n, f) != (size_t)n) { std::exit(2); }
    std::fclose(f);
    return buf;
}

// Golden: walk the stream with liba52, recording each frame's boundary, BSI,
// and whether its *block 0* is out of PoC scope (coupling or rematrixing).
static std::vector<Frame> golden_frames(const std::vector<uint8_t>& buf,
                                        int max_frames, a52_state_t* st) {
    std::vector<Frame> out;
    long off = 0;
    const long n = (long)buf.size();
    while (off + 7 <= n && (int)out.size() < max_frames) {
        int flags = 0, srate = 0, brate = 0;
        int len = a52_syncinfo(const_cast<uint8_t*>(&buf[off]), &flags, &srate, &brate);
        if (len <= 0) { off += 1; continue; }
        Frame f{};
        f.start_byte = off; f.len_bytes = len; f.sample_rate = srate;
        f.acmod = acmod_from_flags(flags); f.lfe = (flags & A52_LFE) ? 1 : 0;
        f.nf = nfchans_of(f.acmod);
        f.oos = 0; f.oos_blk = NB; f.n_inscope = 0;
        // Decode all 6 blocks.  Since M12 Stage C/D the dut decodes COUPLED frames
        // fully too (coupling recombine + rematrixing), so coupling is no longer an
        // out-of-scope stop — only an a52_block() failure is.  exp[0] is the DC
        // exponent; exp[1..endmant-1] the differentially decoded ones.
        // a52_frame sets state->level = 2*level; a52_block sets state->dynrng =
        // state->level * range, and that product scales the coefficients.  We pass
        // level=0.5 (→ state->level=1.0) so state->dynrng == range, i.e. liba52
        // applies exactly the dynrng gain the dut applies (M17).  No unity callback.
        sample_t level = 0.5, bias = 0.0;
        int aflags = flags;
        if (a52_frame(st, const_cast<uint8_t*>(&buf[off]), &aflags, &level, bias) == 0) {
            // M17: no unity callback — liba52 applies its native per-block dynrng
            // (state->level==1.0 since level=0.5, so state->dynrng == range).
            f.g_clev = (double)st->clev;   // centre/surround mix levels (frame const)
            f.g_slev = (double)st->slev;
            for (int b = 0; b < NB; b++) {
                if (a52_block(st) != 0) { f.oos = 1; f.oos_blk = b; break; }
                if (b == 0) {
                    // Block-0 coupling geometry — staged by the dut's side-info
                    // parser (M12 Stage A), compared regardless of coupling.
                    f.coupled      = (st->chincpl || st->rematflg) ? 1 : 0;
                    f.g_chincpl    = st->chincpl;
                    f.g_cplstrtmant= st->cplstrtmant;
                    f.g_cplendmant = st->cplendmant;
                    f.g_ncplbnd    = st->ncplbnd;
                    f.g_cplstrtbnd = st->cplstrtbnd;
                    f.g_phsflginu  = st->phsflginu;
                    f.g_rematflg   = st->rematflg;
                    for (int ch = 0; ch < 2; ch++)
                        for (int j = 0; j < st->ncplbnd && j < 18; j++)
                            f.g_cplco[ch][j] = (float)(double)st->cplco[ch][j];
                }
                // coupling-channel exps + bap (per block) at [cplstrtmant,cplendmant).
                if (st->chincpl)
                    for (int e = st->cplstrtmant; e < st->cplendmant && e < 256; e++) {
                        f.g_cpl_exp[b][e] = st->cpl_expbap.exp[e];
                        f.g_cpl_bap[b][e] = st->cpl_expbap.bap[e];
                    }
                for (int ch = 0; ch < f.nf; ch++) {
                    f.endmant[b][ch] = st->endmant[ch];
                    for (int e = 0; e < st->endmant[ch] && e < 256; e++) {
                        f.gexp[b][ch][e] = st->fbw_expbap[ch].exp[e];
                        f.gbap[b][ch][e] = st->fbw_expbap[ch].bap[e];
                    }
                }
                // LFE exps/bap (7 mantissas), if present.
                if (f.lfe)
                    for (int e = 0; e < 7; e++) {
                        f.g_lfe_exp[b][e] = st->lfe_expbap.exp[e];
                        f.g_lfe_bap[b][e] = st->lfe_expbap.bap[e];
                    }
                // a52_block() IMDCT'd this block into a52_samples().  liba52's
                // buffer layout (no downmix): when lfeon, samples[0..255]=LFE and
                // fbw channel i follows at samples[256*(i+1)]; without LFE, fbw i
                // is at samples[256*i].  dynrng is forced to unity above, so the
                // samples are unscaled like the dut — no normalization needed.
                // fbw coded order = L C R Ls Rs == dut slots 0..nf-1.
                f.g_dynrng[b] = (double)st->dynrng;   // == range (state->level==1.0)
                sample_t* samp = a52_samples(st);
                int off = f.lfe ? 1 : 0;
                for (int ch = 0; ch < f.nf; ch++)
                    for (int i = 0; i < 256; i++)
                        f.gpcm[b][ch][i] = (float)((double)samp[(ch + off) * 256 + i]);
                f.n_inscope = b + 1;
            }
        }
        out.push_back(f);
        off += len;
    }
    return out;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { std::fprintf(stderr, "usage: %s <stream.ac3>\n", argv[0]); return 2; }

    std::vector<uint8_t> buf = read_file(argv[1]);
    const long n = (long)buf.size();

    // The band-split 5.1 vector (noise_5p1) is a GEOMETRY/exps/bap gate only: its
    // disjoint per-channel bands force the high channels' energy near Nyquist,
    // where the fixed-point IMDCT's Q1.17 twiddle quantization dominates the
    // error (decode is bit-accurate — coeffs match liba52 to ~1e-5; verified via
    // COEFFDUTDUMP).  Real full-band content uses the same IMDCT already shipped
    // for stereo (M11-M13, hw-validated).  So for this one vector the full-chain
    // PCM tolerance is informational (reported, not fatal); the coupled 5.1 PCM
    // gate is tone_5p1.  Everything else (exps/bap/geometry/coupling) still gates.
    //
    // bbb_short_5p1 (M16) is informational on the SAME basis: it is a real DVD
    // 5.1 extract with short (256-pt) blocks, so its full-band content is fixed-
    // point-IMDCT-precision-limited.  Its purpose is to gate short-block PARSING
    // (geom/exps/bap bit-exact, and the frame staying synced through all 6 blocks
    // proves short-block bit-consumption); the short IMDCT ARITHMETIC is gated
    // bit-bounded by the standalone run_imdct256.sh (vs a52_imdct_256, 2 blocks).
    const bool pcm_informational = std::strstr(argv[1], "noise_5p1")    != nullptr
                                || std::strstr(argv[1], "bbb_short")    != nullptr;

    // Default 8 (the short test vectors); override with AC3_MAX_FRAMES to scan a
    // long real stream for the first out-of-scope (e.g. short-block) frame.
    const int MAX_FRAMES = getenv("AC3_MAX_FRAMES") ? atoi(getenv("AC3_MAX_FRAMES")) : 8;
    a52_state_t* gst = a52_init(0);
    std::vector<Frame> gold = golden_frames(buf, MAX_FRAMES, gst);
    if (gold.empty()) { std::fprintf(stderr, "liba52 found no frames in %s\n", argv[1]); return 1; }

    // First out-of-scope frame -> where the dut is expected to halt.  The dut
    // still emits that frame's header+BSI before halting in its block 0.
    int first_oos = (int)gold.size();
    for (int i = 0; i < (int)gold.size(); i++) if (gold[i].oos) { first_oos = i; break; }
    // M12 Stage A: a coupled frame is no longer rejected — the parser walks the
    // coupling syntax and stages block-0 geometry (golden-checked below).  But
    // the datapath downstream is still coupling-unaware (Stages B/C/D), so a
    // coupled block's mantissa region is mis-walked and a later block in the same
    // frame eventually trips a loud guard (fail loud, never decode wrong).  So we
    // verify the FIRST coupled frame's block-0 geometry and stop there; full
    // multi-block decode + cross-frame resync arrives with Stage C/D.
    const int expect_frames = std::min((int)gold.size(), first_oos + 1);

    // ---- Verilated DUT ----
    Vac3_front* dut = new Vac3_front;
    auto eval0   = [&](){ dut->clk = 0; dut->eval(); };
    auto posedge = [&](){ dut->clk = 1; dut->eval(); };

    dut->rst = 1; dut->wr_en = 0; dut->wr_data = 0;
    dut->pcm_done = 1;            // no DAC on the bench: never stall the metering
    for (int i = 0; i < 6; i++) { eval0(); posedge(); }
    dut->rst = 0;

    std::vector<Frame> df;
    long fed = 0;
    const long MAX_CYCLES = getenv("AC3_MAX_CYCLES") ? atol(getenv("AC3_MAX_CYCLES")) : 50'000'000;
    long drain = 0;
    int  prev_err = 0;
    int  cur_blk  = -1;          // current block index within the dut's frame
    int  bap_cap_pending = -1;   // M13: frame idx awaiting deferred bap snapshot
    int  bap_cap_blk     = 0;    // block idx for the deferred bap snapshot

    for (long cyc = 0; cyc < MAX_CYCLES; cyc++) {
        eval0();
        bool can = (fed < n) && !dut->full;
        dut->wr_en   = can;
        dut->wr_data = can ? buf[fed] : 0;
        posedge();
        if (can) fed++;

        if (dut->frame_hdr_valid) {
            int sr = (dut->fscod == 0) ? 48000 : (dut->fscod == 1) ? 44100 : 32000;
            long start = (long)dut->sync_bitpos / 8 - 2;
            Frame nf{};
            nf.start_byte = start; nf.len_bytes = (int)dut->frame_bytes;
            nf.sample_rate = sr; nf.acmod = -1; nf.oos_blk = NB;
            df.push_back(nf);
            cur_blk = -1;        // a new frame: blocks restart at 0
        }
        if (dut->bsi_valid && !df.empty()) {
            df.back().acmod = (int)dut->acmod;
            df.back().nf    = nfchans_of((int)dut->acmod);
            df.back().lfe   = (int)dut->lfeon;
        }
        // each block's side info pulses block_side_valid in order -> advance the
        // dut's per-frame block index that exp/bap/pcm captures key off.
        if (dut->block_side_valid && !df.empty()) {
            Frame& fr = df.back();
            fr.dut_inscope = 1;
            fr.err = (int)dut->err_unsupported;
            // Capture the dut's block-0 coupling geometry (M12 Stage A).  The
            // geometry regs are registered and held after block_side_valid; cplco
            // is a signed Q5.18 value read out over the combinational rd port.
            if (cur_blk < 0) {
                fr.geom_cap     = 1;
                fr.d_chincpl    = (int)dut->chincpl;
                fr.d_cplstrtmant= (int)dut->cplstrtmant;
                fr.d_cplendmant = (int)dut->cplendmant;
                fr.d_ncplbnd    = (int)dut->ncplbnd;
                fr.d_cplstrtbnd = (int)dut->cplstrtbnd;
                fr.d_phsflginu  = (int)dut->phsflginu;
                fr.d_rematflg   = (int)dut->rematflg;
                for (int ch = 0; ch < 2; ch++)
                    for (int j = 0; j < (int)dut->ncplbnd && j < 18; j++) {
                        dut->cplco_rd_addr = (ch << 5) | j;
                        dut->eval();                 // combinational read
                        fr.d_cplco[ch][j] = (float)((double)(int32_t)dut->cplco_rd_data / 262144.0);
                    }
                dut->cplco_rd_addr = 0;
            }
            if (cur_blk < NB - 1) cur_blk++;
        }
        if (dut->err_unsupported && !prev_err && !df.empty()) {  // rising edge
            df.back().dut_oos = 1;
            df.back().err = 1;
        }
        prev_err = (int)dut->err_unsupported;

        const int b = (cur_blk < 0) ? 0 : cur_blk;

        // exponent_decode finished the current block: read the decoded exponents
        // out through the combinational dexp read port.
        if (dut->exp_done && !df.empty()) {
            Frame& fr = df.back();
            int nf = fr.nf ? fr.nf : 2;
            for (int ch = 0; ch < nf; ch++)
                for (int e = 0; e < 256; e++) {
                    dut->dexp_rd_addr = (ch << 8) | e;
                    dut->eval();                 // combinational read
                    fr.dexp[b][ch][e] = (uint8_t)dut->dexp_rd_data;
                }
            // coupling channel (slot 5 = AC3_CH_CPL), per block.
            for (int e = 0; e < 256; e++) {
                dut->dexp_rd_addr = (5 << 8) | e;
                dut->eval();
                fr.d_cpl_exp[b][e] = (uint8_t)dut->dexp_rd_data;
            }
            // LFE channel (slot 6 = AC3_CH_LFE), 7 mantissas.
            for (int e = 0; e < 7; e++) {
                dut->dexp_rd_addr = (6 << 8) | e;
                dut->eval();
                fr.d_lfe_exp[b][e] = (uint8_t)dut->dexp_rd_data;
            }
            fr.cpl_exp_cap[b] = 1;
            dut->dexp_rd_addr = 0;
            fr.exp_cap[b] = 1;
        }

        // bit_allocation finished the current block: read bap[] out through the
        // combinational bap read port.  M13: bap_mem is now an M10K written through
        // a registered write-enable, so the final bap of the block commits one
        // cycle AFTER ba_done — defer the snapshot by one clock so the last index
        // is settled (the decode itself reads bap later and is unaffected; PCM
        // confirms).  Pending state remembers which frame/block to capture.
        if (bap_cap_pending >= 0 && bap_cap_pending < (int)df.size()) {
            Frame& fr = df[bap_cap_pending];
            int bb = bap_cap_blk;
            int nf = fr.nf ? fr.nf : 2;
            for (int ch = 0; ch < nf; ch++)
                for (int e = 0; e < 256; e++) {
                    dut->bap_rd_addr = (ch << 8) | e;
                    dut->eval();                 // combinational read
                    fr.dbap[bb][ch][e] = (int8_t)dut->bap_rd_data;
                }
            for (int e = 0; e < 256; e++) {
                dut->bap_rd_addr = (5 << 8) | e;   // coupling slot 5
                dut->eval();
                fr.d_cpl_bap[bb][e] = (int8_t)dut->bap_rd_data;
            }
            for (int e = 0; e < 7; e++) {
                dut->bap_rd_addr = (6 << 8) | e;   // LFE slot 6
                dut->eval();
                fr.d_lfe_bap[bb][e] = (int8_t)dut->bap_rd_data;
            }
            fr.lfe_cap[bb] = 1;
            fr.cpl_bap_cap[bb] = 1;
            dut->bap_rd_addr = 0;
            fr.bap_cap[bb] = 1;
            bap_cap_pending = -1;
        }
        if (dut->ba_done && !df.empty()) {       // arm the deferred snapshot
            bap_cap_pending = (int)df.size() - 1;
            bap_cap_blk     = b;
        }

        // imdct_512 finished the current block: read the Q8.23 time-domain PCM
        // out through the combinational pcm read port (the full-chain tap),
        // before the next block's IMDCT overwrites pcm_mem.
        if (dut->imdct_done && !df.empty()) {
            Frame& fr = df.back();
            int nf = fr.nf ? fr.nf : 2;
            for (int ch = 0; ch < nf; ch++)
                for (int i = 0; i < 256; i++) {
                    dut->pcm_rd_addr = (ch << 8) | i;
                    dut->eval();                 // combinational read
                    int32_t raw = (int32_t)dut->pcm_rd_data;
                    fr.dpcm[b][ch][i] = (float)((double)raw / 8388608.0);  // Q8.23
                }
            dut->pcm_rd_addr = 0;
            fr.pcm_cap[b] = 1;
            fr.dut_blocks++;
            // Optional coeff tap: dump dut coeff_mem (pre-IMDCT) for one block to
            // diff against liba52's pre-IMDCT coeffs (COEFFDUMP probe).  coeff_mem
            // still holds this block's coeffs at imdct_done (next block's mantissa
            // hasn't run yet).  Q1.23 -> float, normalized like the golden.
            if (getenv("COEFFDUTDUMP") && b == atoi(getenv("COEFFDUTDUMP"))) {
                int nf = fr.nf ? fr.nf : 2;
                for (int ch = 0; ch < nf; ch++)
                    for (int i = 0; i < 256; i++) {
                        dut->coeff_rd_addr = (ch << 8) | i;
                        dut->eval();
                        int32_t c = (int32_t)dut->coeff_rd_data;
                        if (c & 0x800000) c |= ~0xffffff;   // sign-extend 24-bit
                        std::fprintf(stderr, "DUTC blk%d ch%d idx%d %.10e\n",
                                     b, ch, i, (double)c / 8388608.0);
                    }
                dut->coeff_rd_addr = 0;
            }
        }

        // Stop once the expected frames are produced and the last one's outcome
        // is fully known: its final block's PCM read out (in-scope), its block-0
        // coupling geometry captured (coupled frame — M12 Stage A), or a halt.
        // Stop once the expected frames are produced and the last one's outcome is
        // known: its final block's PCM read out (in-scope, incl. coupled) or a halt.
        if ((int)df.size() >= expect_frames && !df.empty() &&
            (df.back().pcm_cap[NB-1] || df.back().dut_oos))
            break;

        // Drain long enough for the LAST frame's 6 blocks to finish decoding after
        // the final byte is fed (the multi-cycled IMDCT is ~tens of k cycles/block).
        if (fed >= n) { if (++drain > 3'000'000) break; }
    }
    delete dut;

    // ---- Compare ----
    int errors = 0;
    int k = std::min((int)gold.size(), (int)df.size());
    std::printf("liba52 frames=%zu (first_oos=%d), dut frames=%zu, comparing %d\n",
                gold.size(), first_oos, df.size(), k);
    for (int i = 0; i < k; i++) {
        const Frame& g = gold[i];
        const Frame& d = df[i];
        // Scope: every in-scope frame (incl. coupled — M12 Stage C/D decodes them
        // fully now) must decode all blocks with no error; an a52_block failure
        // (the only remaining oos) halts.  Coupled frames additionally golden-check
        // their block-0 coupling geometry + cpl exps/bap below.
        bool scope_ok = g.oos ? (d.dut_oos == 1)
                              : (d.dut_inscope == 1 && d.err == 0 &&
                                 d.dut_blocks >= g.n_inscope);

        // Block-0 coupling geometry golden check (coupled frames only).  cplco is
        // dut Q5.18 vs liba52 float -> bounded; the rest are bit-exact integers.
        const double CPLCO_TOL = 1e-3;
        bool geom_ok = true;
        int  gm_field = -1; double gm_g = 0, gm_d = 0;   // first mismatch (for print)
        if (g.coupled) {
            if (!d.geom_cap) { geom_ok = false; gm_field = 0; }
            else {
                struct { const char* nm; int gg, dd; } iv[] = {
                    {"chincpl",    g.g_chincpl,    d.d_chincpl},
                    {"cplstrtmant",g.g_cplstrtmant,d.d_cplstrtmant},
                    {"cplendmant", g.g_cplendmant, d.d_cplendmant},
                    {"ncplbnd",    g.g_ncplbnd,    d.d_ncplbnd},
                    {"cplstrtbnd", g.g_cplstrtbnd, d.d_cplstrtbnd},
                    {"phsflginu",  g.g_phsflginu,  d.d_phsflginu},
                    {"rematflg",   g.g_rematflg,   d.d_rematflg},
                };
                for (int q = 0; q < 7 && geom_ok; q++)
                    if (iv[q].gg != iv[q].dd) {
                        geom_ok = false; gm_field = 1 + q; gm_g = iv[q].gg; gm_d = iv[q].dd;
                    }
                for (int ch = 0; ch < 2 && geom_ok; ch++)
                    for (int j = 0; j < g.g_ncplbnd && j < 18 && geom_ok; j++) {
                        double e = fabs((double)g.g_cplco[ch][j] - (double)d.d_cplco[ch][j]);
                        if (e > CPLCO_TOL) {
                            geom_ok = false; gm_field = 100 + ch * 18 + j;
                            gm_g = g.g_cplco[ch][j]; gm_d = d.d_cplco[ch][j];
                        }
                    }
            }
        }

        // M12 Stage B/C: coupling-channel exponents + bap, bit-exact vs liba52
        // cpl_expbap.exp[]/.bap[] over [cplstrtmant, cplendmant), EVERY coupled
        // block (each carries its own cpl exps).
        bool cple_ok = true, cplb_ok = true;
        int  ce_blk = -1, ce_idx = -1, ce_g = 0, ce_d = 0;
        int  cb_blk = -1, cb_idx = -1, cb_g = 0, cb_d = 0;
        if (g.coupled && g.g_chincpl) {
            for (int b = 0; b < g.n_inscope; b++) {
                if (!d.cpl_exp_cap[b]) { if (cple_ok) { cple_ok = false; ce_blk = b; } }
                else for (int e = g.g_cplstrtmant; e < g.g_cplendmant; e++)
                    if (d.d_cpl_exp[b][e] != g.g_cpl_exp[b][e] && cple_ok) {
                        cple_ok = false; ce_blk = b; ce_idx = e;
                        ce_g = g.g_cpl_exp[b][e]; ce_d = d.d_cpl_exp[b][e];
                    }
                if (!d.cpl_bap_cap[b]) { if (cplb_ok) { cplb_ok = false; cb_blk = b; } }
                else for (int e = g.g_cplstrtmant; e < g.g_cplendmant; e++)
                    if (d.d_cpl_bap[b][e] != g.g_cpl_bap[b][e] && cplb_ok) {
                        cplb_ok = false; cb_blk = b; cb_idx = e;
                        cb_g = g.g_cpl_bap[b][e]; cb_d = d.d_cpl_bap[b][e];
                    }
            }
        }

        // Per-block bit-exact (exps, bap) + bounded-error (PCM) vs liba52, over
        // every in-scope block of the frame.
        bool exp_ok = true, bap_ok = true, pcm_ok = true;
        int  mm_blk = -1, mm_ch = -1, mm_idx = -1, mm_g = 0, mm_d = 0;
        int  bm_blk = -1, bm_ch = -1, bm_idx = -1, bm_g = 0, bm_d = 0;
        double maxerr_lsb = 0.0;
        int    pm_blk = -1, pm_ch = -1, pm_idx = -1; double pm_d = 0, pm_g = 0;

        for (int b = 0; b < g.n_inscope; b++) {
            if (!d.exp_cap[b]) { exp_ok = false; if (mm_blk < 0) mm_blk = b; }
            else for (int ch = 0; ch < g.nf; ch++)
                for (int e = 0; e < g.endmant[b][ch]; e++)
                    if (d.dexp[b][ch][e] != g.gexp[b][ch][e]) {
                        if (exp_ok) { exp_ok = false; mm_blk = b; mm_ch = ch;
                            mm_idx = e; mm_g = g.gexp[b][ch][e]; mm_d = d.dexp[b][ch][e]; }
                    }
            // LFE exps/bap (7 mantissas) when present.
            if (g.lfe && d.lfe_cap[b])
                for (int e = 0; e < 7; e++) {
                    if (d.d_lfe_exp[b][e] != g.g_lfe_exp[b][e] && exp_ok) {
                        exp_ok = false; mm_blk = b; mm_ch = 9; mm_idx = e;
                        mm_g = g.g_lfe_exp[b][e]; mm_d = d.d_lfe_exp[b][e]; }
                }
            if (!d.bap_cap[b]) { bap_ok = false; if (bm_blk < 0) bm_blk = b; }
            else for (int ch = 0; ch < g.nf; ch++)
                for (int e = 0; e < g.endmant[b][ch]; e++)
                    if (d.dbap[b][ch][e] != g.gbap[b][ch][e]) {
                        if (bap_ok) { bap_ok = false; bm_blk = b; bm_ch = ch;
                            bm_idx = e; bm_g = g.gbap[b][ch][e]; bm_d = d.dbap[b][ch][e]; }
                    }
            if (g.lfe && d.lfe_cap[b])
                for (int e = 0; e < 7; e++) {
                    if (d.d_lfe_bap[b][e] != g.g_lfe_bap[b][e] && bap_ok) {
                        bap_ok = false; bm_blk = b; bm_ch = 9; bm_idx = e;
                        bm_g = g.g_lfe_bap[b][e]; bm_d = d.d_lfe_bap[b][e]; }
                }
            double blkmax = 0.0;
            // M14 Stage F: for acmod==7 the dut downmixes the 5 fbw channels into
            // pcm slots 0/1 (Lo/Ro), so the golden for those slots is the stereo
            // downmix of the per-channel goldens; slots 2..4 stay per-channel.
            // (clev/slev are liba52's own state->clev/slev — same LEVEL constants
            // the dut's ROM uses; the per-channel gpcm are already golden-verified,
            // so this is a full-chain Lo/Ro check by linearity of the IMDCT.)
            bool dmx = (g.acmod == 7);
            auto golden = [&](int ch, int s) -> double {
                if (dmx && ch == 0) return g.gpcm[b][0][s] + g.g_clev*g.gpcm[b][1][s]
                                         + g.g_slev*g.gpcm[b][3][s];
                if (dmx && ch == 1) return g.gpcm[b][2][s] + g.g_clev*g.gpcm[b][1][s]
                                         + g.g_slev*g.gpcm[b][4][s];
                return g.gpcm[b][ch][s];
            };
            if (!d.pcm_cap[b]) { pcm_ok = false; if (pm_blk < 0) pm_blk = b; }
            else for (int ch = 0; ch < g.nf; ch++)
                for (int s = 0; s < 256; s++) {
                    double e = fabs((double)d.dpcm[b][ch][s] - golden(ch, s)) * 32768.0;
                    if (e > blkmax) blkmax = e;
                    if (e > maxerr_lsb) {
                        maxerr_lsb = e; pm_blk = b; pm_ch = ch; pm_idx = s;
                        pm_d = d.dpcm[b][ch][s]; pm_g = golden(ch, s);
                    }
                }
            if (getenv("PCMDUMP") && b == atoi(getenv("PCMDUMP"))) {
                for (int ch = 0; ch < g.nf; ch++)
                    for (int s = 0; s < 256; s++)
                        std::fprintf(stderr, "PCMD blk%d ch%d s%d dut=%.8e ref=%.8e\n",
                                     b, ch, s, (double)d.dpcm[b][ch][s],
                                     (double)g.gpcm[b][ch][s]);
            }
            if (getenv("CPLDBG")) {
                std::printf("    [dbg] blk%d pcm max %.3f LSB |", b, blkmax);
                for (int ch = 0; ch < g.nf; ch++) {
                    double cmax = 0;
                    for (int s = 0; s < 256; s++) {
                        double e = fabs((double)d.dpcm[b][ch][s]-golden(ch,s))*32768.0;
                        if (e > cmax) cmax = e;
                    }
                    std::printf(" ch%d=%.2f", ch, cmax);
                }
                std::printf("\n");
            }
        }
        if (g.n_inscope > 0 && maxerr_lsb > PCM_TOL_LSB && !pcm_informational)
            pcm_ok = false;
        if (g.oos) { exp_ok = bap_ok = pcm_ok = true; }   // not checked past halt

        bool ok = (g.start_byte == d.start_byte) &&
                  (g.len_bytes  == d.len_bytes)  &&
                  (g.sample_rate == d.sample_rate) &&
                  (g.acmod      == d.acmod)       &&
                  (g.lfe        == d.lfe)         &&
                  scope_ok && geom_ok && cple_ok && cplb_ok && exp_ok && bap_ok && pcm_ok;
        std::printf("  frame %d: liba52[off=%ld len=%d sr=%d acmod=%d lfe=%d oos=%d@blk%d cpl=%d]  "
                    "dut[off=%ld len=%d acmod=%d lfe=%d inscope=%d blocks=%d oos=%d err=%d geom=%d]  %s\n",
                    i, g.start_byte, g.len_bytes, g.sample_rate, g.acmod, g.lfe, g.oos, g.oos_blk, g.coupled,
                    d.start_byte, d.len_bytes, d.acmod, d.lfe,
                    d.dut_inscope, d.dut_blocks, d.dut_oos, d.err, d.geom_cap, ok ? "ok" : "MISMATCH");
        if (g.coupled) {
            if (geom_ok)
                std::printf("           cpl geom ok (chincpl=%d cplstrtmant=%d cplendmant=%d "
                            "ncplbnd=%d cplstrtbnd=%d phsflginu=%d rematflg=0x%x, cplco[0][0]=%.5f)\n",
                            g.g_chincpl, g.g_cplstrtmant, g.g_cplendmant, g.g_ncplbnd,
                            g.g_cplstrtbnd, g.g_phsflginu, g.g_rematflg, d.d_cplco[0][0]);
            else if (gm_field == 0)
                std::printf("           CPL GEOM MISMATCH: dut did not capture block-0 geometry\n");
            else if (gm_field >= 100)
                std::printf("           CPL GEOM MISMATCH: cplco[%d][%d] dut=%.6f golden=%.6f\n",
                            (gm_field - 100) / 18, (gm_field - 100) % 18, gm_d, gm_g);
            else
                std::printf("           CPL GEOM MISMATCH: field %d dut=%.0f golden=%.0f\n",
                            gm_field, gm_d, gm_g);
            if (g.g_chincpl) {
                if (cple_ok)
                    std::printf("           cpl exps ok (%d blocks, idx %d..%d)\n",
                                g.n_inscope, g.g_cplstrtmant, g.g_cplendmant - 1);
                else if (ce_idx < 0)
                    std::printf("           CPL EXP MISMATCH: dut did not capture blk%d cpl exps\n", ce_blk);
                else
                    std::printf("           CPL EXP MISMATCH: blk%d exp[%d] dut=%d golden=%d\n",
                                ce_blk, ce_idx, ce_d, ce_g);
                if (cplb_ok)
                    std::printf("           cpl bap  ok (%d blocks, idx %d..%d)\n",
                                g.n_inscope, g.g_cplstrtmant, g.g_cplendmant - 1);
                else if (cb_idx < 0)
                    std::printf("           CPL BAP MISMATCH: dut did not capture blk%d cpl bap\n", cb_blk);
                else
                    std::printf("           CPL BAP MISMATCH: blk%d bap[%d] dut=%d golden=%d\n",
                                cb_blk, cb_idx, cb_d, cb_g);
            }
        }
        if (g.n_inscope > 0) {
            if (exp_ok)
                std::printf("           exps ok (%d blocks)\n", g.n_inscope);
            else if (mm_ch < 0)
                std::printf("           EXP MISMATCH: dut did not produce block %d exponents\n", mm_blk);
            else
                std::printf("           EXP MISMATCH: blk%d ch%d exp[%d] dut=%d golden=%d\n",
                            mm_blk, mm_ch, mm_idx, mm_d, mm_g);
            if (bap_ok)
                std::printf("           bap  ok (%d blocks)\n", g.n_inscope);
            else if (bm_ch < 0)
                std::printf("           BAP MISMATCH: dut did not produce block %d bap\n", bm_blk);
            else
                std::printf("           BAP MISMATCH: blk%d ch%d bap[%d] dut=%d golden=%d\n",
                            bm_blk, bm_ch, bm_idx, bm_d, bm_g);
            if (pcm_ok && pcm_informational && maxerr_lsb > PCM_TOL_LSB)
                std::printf("           pcm  INFO (%d blocks, max err %.3f LSB @ s16) "
                            "— geometry-only vector, IMDCT-precision PCM not gated\n",
                            g.n_inscope, maxerr_lsb);
            else if (pcm_ok)
                std::printf("           pcm  ok (%d blocks, max err %.3f LSB @ s16, tol %.1f)\n",
                            g.n_inscope, maxerr_lsb, (double)PCM_TOL_LSB);
            else if (pm_ch < 0)
                std::printf("           PCM MISMATCH: dut did not produce block %d PCM\n", pm_blk);
            else
                std::printf("           PCM MISMATCH: blk%d ch%d pcm[%d] dut=%.6f golden=%.6f "
                            "(err %.3f LSB @ s16, tol %.1f)\n",
                            pm_blk, pm_ch, pm_idx, pm_d, pm_g, maxerr_lsb, (double)PCM_TOL_LSB);
            // M17: report the per-frame DRC gain span (range==1.0 ⇒ no DRC this
            // block).  A span away from 1.0 confirms the DRC path is exercised.
            double drmin = 1e9, drmax = -1e9; bool drc_any = false;
            for (int b = 0; b < g.n_inscope; b++) {
                double r = g.g_dynrng[b];
                if (r < drmin) drmin = r;
                if (r > drmax) drmax = r;
                if (fabs(r - 1.0) > 1e-6) drc_any = true;
            }
            std::printf("           drc  range %.4f..%.4f (%s)\n", drmin, drmax,
                        drc_any ? "DRC active — gain applied & checked" : "all unity");
        }
        if (!ok) errors++;
    }
    if ((int)df.size() < expect_frames) {
        std::printf("  dut produced %zu frames, expected %d\n", df.size(), expect_frames);
        errors++;
    }

    std::printf("RESULT: %s\n", errors == 0 ? "PASS" : "FAIL");
    return errors == 0 ? 0 : 1;
}
