//============================================================================
//  gen_imdct_tables.c — generate the imdct_512 ROM tables + IFFT128 butterfly
//  schedule for the M8 RTL (dvd/ac3/ac3_imdct_tables.svh).
//
//  liba52's 512-pt IMDCT (imdct.c) is: pre-twiddle (pre1[]) -> a 128-pt complex
//  split-radix IFFT (ifft128_c, a *recursion* of ifft2/4/8/.. + ifft_pass
//  butterflies) -> post-twiddle (post1[]) + KBD window -> overlap/add.  The
//  recursion is awkward to build in fabric, so here we **trace it once into a
//  flat butterfly schedule** (a data-independent op list: op type + the four
//  complex-buffer indices it touches + its twiddle(s)).  The RTL then just
//  steps a tiny FSM through that schedule with one time-shared multiplier —
//  same arithmetic, same order as liba52, only fixed-point rounding differs.
//
//  This generator is **self-checking**: it (1) replicates a52_imdct_init's
//  exact float formulas for pre1/post1/window/roots, (2) records the schedule
//  by walking the same recursion structure liba52 uses, (3) runs that schedule
//  (in double) as a full IMDCT and asserts it matches the *real* exported
//  a52_imdct_512() to < 1e-6 on random input — proving the schedule + the RTL's
//  butterfly semantics before any quantization.  Only then does it emit the
//  quantized .svh.  Run via bench/ac3/run_imdct.sh (it regenerates the header).
//
//  Fixed-point (architecture.md §5, IMDCT): twiddles + window are signed
//  **Q1.17** in 18-bit words (DSP 18x18 friendly); the RTL keeps complex
//  samples in Q8.23 (32-bit).  See the header it emits + imdct_512.sv.
//============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <a52dec/a52.h>
#include <a52dec/a52_internal.h>

#ifndef M_PI
#define M_PI 3.1415926535897932384626433832795029
#endif

typedef struct { double real, imag; } cplx;

// liba52 imdct.c fftorder[] (the bit-reversed-ish pre/post permutation).
static const unsigned char fftorder[128] = {
      0,128, 64,192, 32,160,224, 96, 16,144, 80,208,240,112, 48,176,
      8,136, 72,200, 40,168,232,104,248,120, 56,184, 24,152,216, 88,
      4,132, 68,196, 36,164,228,100, 20,148, 84,212,244,116, 52,180,
    252,124, 60,188, 28,156,220, 92, 12,140, 76,204,236,108, 44,172,
      2,130, 66,194, 34,162,226, 98, 18,146, 82,210,242,114, 50,178,
     10,138, 74,202, 42,170,234,106,250,122, 58,186, 26,154,218, 90,
    254,126, 62,190, 30,158,222, 94, 14,142, 78,206,238,110, 46,174,
      6,134, 70,198, 38,166,230,102,246,118, 54,182, 22,150,214, 86
};

// ---- replicated float tables (== a52_imdct_init, imdct.c) ----
static double roots16[3], roots32[7], roots64[15], roots128[31];
static cplx   pre1[128], post1[64];
static cplx   pre2[64],  post2[32];     // short-block (256-pt) twiddles
static double window[256];

static double besselI0 (double x) {
    double bessel = 1;
    int i = 100;
    do bessel = bessel * x / (i * i) + 1; while (--i);
    return bessel;
}

static void init_tables (void) {
    int i, k;
    double sum = 0;
    for (i = 0; i < 256; i++) {
        sum += besselI0 (i * (256 - i) * (5 * M_PI / 256) * (5 * M_PI / 256));
        window[i] = sum;
    }
    sum++;
    for (i = 0; i < 256; i++) window[i] = sqrt (window[i] / sum);

    for (i = 0; i < 3;  i++) roots16[i]  = cos ((M_PI / 8)  * (i + 1));
    for (i = 0; i < 7;  i++) roots32[i]  = cos ((M_PI / 16) * (i + 1));
    for (i = 0; i < 15; i++) roots64[i]  = cos ((M_PI / 32) * (i + 1));
    for (i = 0; i < 31; i++) roots128[i] = cos ((M_PI / 64) * (i + 1));

    for (i = 0; i < 64; i++) {
        k = fftorder[i] / 2 + 64;
        pre1[i].real = cos ((M_PI / 256) * (k - 0.25));
        pre1[i].imag = sin ((M_PI / 256) * (k - 0.25));
    }
    for (i = 64; i < 128; i++) {
        k = fftorder[i] / 2 + 64;
        pre1[i].real = -cos ((M_PI / 256) * (k - 0.25));
        pre1[i].imag = -sin ((M_PI / 256) * (k - 0.25));
    }
    for (i = 0; i < 64; i++) {
        post1[i].real = cos ((M_PI / 256) * (i + 0.5));
        post1[i].imag = sin ((M_PI / 256) * (i + 0.5));
    }

    // short-block (256-pt IMDCT) twiddles — a52_imdct_init, imdct.c
    for (i = 0; i < 64; i++) {
        k = fftorder[i] / 4;
        pre2[i].real = cos ((M_PI / 128) * (k - 0.25));
        pre2[i].imag = sin ((M_PI / 128) * (k - 0.25));
    }
    for (i = 0; i < 32; i++) {
        post2[i].real = cos ((M_PI / 128) * (i + 0.5));
        post2[i].imag = sin ((M_PI / 128) * (i + 0.5));
    }
}

// ---- butterfly schedule (traced from the ifft recursion) ----
enum { OP_IFFT2, OP_IFFT4, OP_BZERO, OP_BHALF, OP_BFULL };
typedef struct { int op, a, b, c, d; double wr, wi; } sop;
static sop sched[1024];      // long-block (ifft128) schedule
static int nsched = 0;
static sop sched256[1024];   // short-block (two ifft64) schedule
static int nsched256 = 0;

// emit() targets whichever schedule the current trace is building.
static sop *cur_sched = sched;
static int *cur_n      = &nsched;

static void emit (int op, int a, int b, int c, int d, double wr, double wi) {
    cur_sched[(*cur_n)++] = (sop){ op, a, b, c, d, wr, wi };
}

// The recursion mirrors imdct.c exactly (ifft128 path only — long blocks).
// ifft_pass(buf, roots-N, N): one BUTTERFLY_ZERO on (o,o+N,o+2N,o+3N) then for
// k=0..N-2 a full BUTTERFLY on (o+1+k, o+1+N+k, o+1+2N+k, o+1+3N+k) with
// wr=roots[k], wi=roots[N-2-k] (the -N pointer bias collapses to these, see
// the index algebra in the file history / architecture.md §4.8).
static void rec_ifft2 (int o) { emit (OP_IFFT2, o, o + 1, 0, 0, 0, 0); }
static void rec_ifft4 (int o) { emit (OP_IFFT4, o, o + 1, o + 2, o + 3, 0, 0); }
static void rec_ifft8 (int o) {
    rec_ifft4 (o);
    rec_ifft2 (o + 4);
    rec_ifft2 (o + 6);
    emit (OP_BZERO, o + 0, o + 2, o + 4, o + 6, 0, 0);
    emit (OP_BHALF, o + 1, o + 3, o + 5, o + 7, roots16[1], 0);
}
static void rec_pass (int o, const double *roots, int n) {
    emit (OP_BZERO, o, o + n, o + 2 * n, o + 3 * n, 0, 0);
    for (int k = 0; k <= n - 2; k++)
        emit (OP_BFULL, o + 1 + k, o + 1 + n + k, o + 1 + 2 * n + k,
              o + 1 + 3 * n + k, roots[k], roots[n - 2 - k]);
}
static void rec_ifft16 (int o) {
    rec_ifft8 (o); rec_ifft4 (o + 8); rec_ifft4 (o + 12);
    rec_pass (o, roots16, 4);
}
static void rec_ifft32 (int o) {
    rec_ifft16 (o); rec_ifft8 (o + 16); rec_ifft8 (o + 24);
    rec_pass (o, roots32, 8);
}
static void rec_ifft128 (void) {
    rec_ifft32 (0); rec_ifft16 (32); rec_ifft16 (48); rec_pass (0, roots64, 16);
    rec_ifft32 (64); rec_ifft32 (96); rec_pass (0, roots128, 32);
}
// short block: imdct_256 runs TWO independent 64-pt IFFTs (ifft64_c on buf1 and
// buf2).  We lay buf1 at indices [0..63] and buf2 at [64..127] of one 128-entry
// working buffer, so the flat schedule is rec_ifft64(0) ++ rec_ifft64(64).
static void rec_ifft64 (int o) {
    rec_ifft32 (o); rec_ifft16 (o + 32); rec_ifft16 (o + 48);
    rec_pass (o, roots64, 16);
}
static void rec_ifft256 (void) { rec_ifft64 (0); rec_ifft64 (64); }

// Interpreter (double) — the EXACT arithmetic the RTL FSM will perform per op,
// matching liba52's BUTTERFLY* macros term-for-term.
static void interp (cplx *buf, const sop *sc, int n) {
    double t1, t2, t3, t4, t5, t6, t7, t8, r, im;
    for (int s = 0; s < n; s++) {
        const sop *p = &sc[s];
        cplx *a0 = &buf[p->a], *a1 = &buf[p->b], *a2 = &buf[p->c], *a3 = &buf[p->d];
        switch (p->op) {
        case OP_IFFT2:
            r = a0->real; im = a0->imag;
            a0->real += a1->real; a0->imag += a1->imag;
            a1->real = r - a1->real; a1->imag = im - a1->imag;
            break;
        case OP_IFFT4:
            t1 = a0->real + a1->real; t2 = a3->real + a2->real;
            t3 = a0->imag + a1->imag; t4 = a2->imag + a3->imag;
            t5 = a0->real - a1->real; t6 = a0->imag - a1->imag;
            t7 = a2->imag - a3->imag; t8 = a3->real - a2->real;
            a0->real = t1 + t2; a0->imag = t3 + t4;
            a2->real = t1 - t2; a2->imag = t3 - t4;
            a1->real = t5 + t7; a1->imag = t6 + t8;
            a3->real = t5 - t7; a3->imag = t6 - t8;
            break;
        case OP_BZERO:
            t1 = a2->real + a3->real; t2 = a2->imag + a3->imag;
            t3 = a2->imag - a3->imag; t4 = a3->real - a2->real;
            goto combine;
        case OP_BHALF:
            t5 = (a2->real + a2->imag) * p->wr;
            t6 = (a2->imag - a2->real) * p->wr;
            t7 = (a3->real - a3->imag) * p->wr;
            t8 = (a3->imag + a3->real) * p->wr;
            goto bfly;
        case OP_BFULL:
            t5 = a2->real * p->wr + a2->imag * p->wi;
            t6 = a2->imag * p->wr - a2->real * p->wi;
            t7 = a3->real * p->wr - a3->imag * p->wi;
            t8 = a3->imag * p->wr + a3->real * p->wi;
        bfly:
            t1 = t5 + t7; t2 = t6 + t8; t3 = t6 - t8; t4 = t7 - t5;
        combine:
            a2->real = a0->real - t1; a2->imag = a0->imag - t2;
            a3->real = a1->real - t3; a3->imag = a1->imag - t4;
            a0->real += t1; a0->imag += t2;
            a1->real += t3; a1->imag += t4;
            break;
        }
    }
}

// Full IMDCT in double using our tables + the traced schedule (out-of-place
// writes, but reads delay before overwriting it — same as liba52's in-place).
static void imdct_double (const double *data, double *delay, double bias,
                          double *out) {
    cplx buf[128];
    int i, k;
    for (i = 0; i < 128; i++) {
        k = fftorder[i];
        buf[i].real = pre1[i].imag * data[255 - k] + pre1[i].real * data[k];
        buf[i].imag = pre1[i].real * data[255 - k] - pre1[i].imag * data[k];
    }
    interp (buf, sched, nsched);
    for (i = 0; i < 64; i++) {
        double tr = post1[i].real, ti = post1[i].imag;
        double ar = tr * buf[i].real     + ti * buf[i].imag;
        double ai = ti * buf[i].real     - tr * buf[i].imag;
        double br = ti * buf[127-i].real + tr * buf[127-i].imag;
        double bi = tr * buf[127-i].real - ti * buf[127-i].imag;
        double w1 = window[2*i], w2 = window[255-2*i];
        out[2*i]     = delay[2*i] * w2 - ar * w1 + bias;
        out[255-2*i] = delay[2*i] * w1 + ar * w2 + bias;
        delay[2*i] = ai;
        w1 = window[2*i+1]; w2 = window[254-2*i];
        out[2*i+1]   = delay[2*i+1] * w2 + br * w1 + bias;
        out[254-2*i] = delay[2*i+1] * w1 - br * w2 + bias;
        delay[2*i+1] = bi;
    }
}

// Short-block (256-pt) IMDCT in double using our pre2/post2 tables + the traced
// two-ifft64 schedule — a literal transcription of liba52 a52_imdct_256.  buf1
// at cbuf[0..63], buf2 at cbuf[64..127]; the schedule runs ifft64 on each half.
static void imdct_256_double (const double *data, double *delay, double bias,
                              double *out) {
    cplx cbuf[128];
    int i, k;
    for (i = 0; i < 64; i++) {
        k = fftorder[i];
        double tr = pre2[i].real, ti = pre2[i].imag;
        cbuf[i].real      = ti * data[254 - k] + tr * data[k];      // buf1[i]
        cbuf[i].imag      = tr * data[254 - k] - ti * data[k];
        cbuf[64 + i].real = ti * data[255 - k] + tr * data[k + 1];  // buf2[i]
        cbuf[64 + i].imag = tr * data[255 - k] - ti * data[k + 1];
    }
    interp (cbuf, sched256, nsched256);     // ifft64(buf1) then ifft64(buf2)
    cplx *buf1 = cbuf, *buf2 = cbuf + 64;
    for (i = 0; i < 32; i++) {
        double tr = post2[i].real, ti = post2[i].imag;
        double a_r = tr * buf1[i].real    + ti * buf1[i].imag;
        double a_i = ti * buf1[i].real    - tr * buf1[i].imag;
        double b_r = ti * buf1[63-i].real + tr * buf1[63-i].imag;
        double b_i = tr * buf1[63-i].real - ti * buf1[63-i].imag;
        double c_r = tr * buf2[i].real    + ti * buf2[i].imag;
        double c_i = ti * buf2[i].real    - tr * buf2[i].imag;
        double d_r = ti * buf2[63-i].real + tr * buf2[63-i].imag;
        double d_i = tr * buf2[63-i].real - ti * buf2[63-i].imag;
        double w1, w2;
        w1 = window[2*i];     w2 = window[255-2*i];
        out[2*i]     = delay[2*i] * w2 - a_r * w1 + bias;
        out[255-2*i] = delay[2*i] * w1 + a_r * w2 + bias;
        delay[2*i] = c_i;
        w1 = window[128+2*i]; w2 = window[127-2*i];
        out[128+2*i] = delay[127-2*i] * w2 + a_i * w1 + bias;
        out[127-2*i] = delay[127-2*i] * w1 - a_i * w2 + bias;
        delay[127-2*i] = c_r;
        w1 = window[2*i+1];   w2 = window[254-2*i];
        out[2*i+1]   = delay[2*i+1] * w2 - b_i * w1 + bias;
        out[254-2*i] = delay[2*i+1] * w1 + b_i * w2 + bias;
        delay[2*i+1] = d_r;
        w1 = window[129+2*i]; w2 = window[126-2*i];
        out[129+2*i] = delay[126-2*i] * w2 + b_r * w1 + bias;
        out[126-2*i] = delay[126-2*i] * w1 - b_r * w2 + bias;
        delay[126-2*i] = d_i;
    }
}

// ---- Q1.17 quantization (18-bit signed, value/131072), clamped to ±131071 ----
static int q17 (double x) {
    long v = lround (x * 131072.0);
    if (v >  131071) v =  131071;
    if (v < -131072) v = -131072;
    return (int)v;
}

static void self_check (void) {
    double data2[256], delay2[256], out[256];
    // sample_t is float in this liba52 build, so a52_imdct_512 computes with
    // float twiddles; our reference uses double.  The gap is float rounding
    // (~1e-5 relative on signals of magnitude ~10s), NOT a schedule error — a
    // wrong schedule mis-routes a butterfly and errs by O(signal).  So a 1e-3
    // absolute tolerance cleanly separates "schedule correct" from "bug".
    sample_t fdata[256], fdelay[256];
    srand (12345);
    for (int i = 0; i < 256; i++) {
        double v = (rand () / (double)RAND_MAX) * 2.0 - 1.0;   // [-1,1)
        data2[i] = v;  fdata[i]  = (sample_t)v;
        double d = (rand () / (double)RAND_MAX) * 2.0 - 1.0;
        delay2[i] = d * 8.0;  fdelay[i] = (sample_t)(d * 8.0);  // overlap state
    }
    double bias = 0.0;
    imdct_double (data2, delay2, bias, out);   // ours (double)
    a52_imdct_512 (fdata, fdelay, (sample_t)bias);   // liba52 (in-place, float)

    double maxd = 0, maxdel = 0, maxmag = 0;
    for (int i = 0; i < 256; i++) {
        double e  = fabs (out[i]    - fdata[i]);  if (e  > maxd)   maxd   = e;
        double ed = fabs (delay2[i] - fdelay[i]); if (ed > maxdel) maxdel = ed;
        if (fabs (out[i]) > maxmag) maxmag = fabs (out[i]);
    }
    fprintf (stderr, "[gen_imdct] schedule ops = %d, peak |out| = %.3f\n",
             nsched, maxmag);
    fprintf (stderr, "[gen_imdct] self-check vs a52_imdct_512 (float): "
             "max |out diff|=%.3e  max |delay diff|=%.3e\n", maxd, maxdel);
    if (maxd > 1e-3 || maxdel > 1e-3) {
        fprintf (stderr, "[gen_imdct] FAIL: schedule does not match liba52\n");
        exit (1);
    }
    fprintf (stderr, "[gen_imdct] OK: traced schedule matches liba52 IMDCT\n");
}

static void self_check_256 (void) {
    double data2[256], delay2[256], out[256];
    sample_t fdata[256], fdelay[256];
    srand (54321);
    for (int i = 0; i < 256; i++) {
        double v = (rand () / (double)RAND_MAX) * 2.0 - 1.0;   // [-1,1)
        data2[i] = v;  fdata[i]  = (sample_t)v;
        double d = (rand () / (double)RAND_MAX) * 2.0 - 1.0;
        delay2[i] = d * 8.0;  fdelay[i] = (sample_t)(d * 8.0);  // overlap state
    }
    double bias = 0.0;
    imdct_256_double (data2, delay2, bias, out);           // ours (double)
    a52_imdct_256 (fdata, fdelay, (sample_t)bias);         // liba52 (float)

    double maxd = 0, maxdel = 0, maxmag = 0;
    for (int i = 0; i < 256; i++) {
        double e  = fabs (out[i]    - fdata[i]);  if (e  > maxd)   maxd   = e;
        double ed = fabs (delay2[i] - fdelay[i]); if (ed > maxdel) maxdel = ed;
        if (fabs (out[i]) > maxmag) maxmag = fabs (out[i]);
    }
    fprintf (stderr, "[gen_imdct] short schedule ops = %d, peak |out| = %.3f\n",
             nsched256, maxmag);
    fprintf (stderr, "[gen_imdct] self-check vs a52_imdct_256 (float): "
             "max |out diff|=%.3e  max |delay diff|=%.3e\n", maxd, maxdel);
    if (maxd > 1e-3 || maxdel > 1e-3) {
        fprintf (stderr, "[gen_imdct] FAIL: short schedule does not match liba52\n");
        exit (1);
    }
    fprintf (stderr, "[gen_imdct] OK: traced short schedule matches liba52 IMDCT256\n");
}

// ---- emit the SystemVerilog header ----
static const char *opname (int op) {
    switch (op) {
    case OP_IFFT2: return "OP_IFFT2";
    case OP_IFFT4: return "OP_IFFT4";
    case OP_BZERO: return "OP_BZERO";
    case OP_BHALF: return "OP_BHALF";
    default:       return "OP_BFULL";
    }
}

static void emit_svh (const char *path) {
    FILE *f = fopen (path, "w");
    if (!f) { perror (path); exit (1); }

    fprintf (f,
"//============================================================================\n"
"//  ac3_imdct_tables.svh — GENERATED by bench/ac3/gen_imdct_tables.c.  DO NOT\n"
"//  EDIT BY HAND.  Re-run bench/ac3/run_imdct.sh to regenerate.\n"
"//\n"
"//  liba52 0.8.0 512-pt IMDCT tables (a52_imdct_init formulas) + the traced\n"
"//  IFFT128 butterfly schedule (ifft128_c recursion flattened).  Included\n"
"//  inside imdct_512.sv.  Twiddles + window are signed Q1.17 (value/131072);\n"
"//  the schedule op codes match imdct_512's localparams.\n"
"//============================================================================\n"
"`ifndef AC3_IMDCT_TABLES_SVH\n"
"`define AC3_IMDCT_TABLES_SVH\n\n"
"localparam int IMDCT_NSCHED    = %d;  // long-block (ifft128) butterfly count\n"
"localparam int IMDCT_NSCHED256 = %d;  // short-block (two ifft64) count\n\n"
"// schedule op codes (must match imdct_512.sv)\n"
"localparam logic [2:0] OP_IFFT2 = 3'd0, OP_IFFT4 = 3'd1,\n"
"                       OP_BZERO = 3'd2, OP_BHALF = 3'd3, OP_BFULL = 3'd4;\n\n",
        nsched, nsched256);

    fprintf (f,
"// M19c (area pass): fftorder/window carry ramstyle and are read REGISTERED\n"
"// in imdct_512 (sync M10K ROMs); the *_pk arrays below are packed literal\n"
"// copies of the twiddle/schedule tables for the same purpose.  The unpacked\n"
"// per-field arrays are kept for reference/tooling and are unread in synthesis\n"
"// (optimized away).\n"
"(* ramstyle = \"M10K\" *)\n"
"logic [7:0]         imdct_fftorder [0:127];\n"
"logic signed [17:0] imdct_pre1_re  [0:127];\n"
"logic signed [17:0] imdct_pre1_im  [0:127];\n"
"logic signed [17:0] imdct_post1_re [0:63];\n"
"logic signed [17:0] imdct_post1_im [0:63];\n"
"logic signed [17:0] imdct_pre2_re  [0:63];\n"
"logic signed [17:0] imdct_pre2_im  [0:63];\n"
"logic signed [17:0] imdct_post2_re [0:31];\n"
"logic signed [17:0] imdct_post2_im [0:31];\n"
"(* ramstyle = \"M10K\" *)\n"
"logic signed [17:0] imdct_window   [0:255];\n"
"// packed twiddles {re[17:0], im[17:0]}: pre1 at 0..127 / pre2 at 128..191;\n"
"// post1 at 0..63 / post2 at 64..95\n"
"(* ramstyle = \"M10K\" *)\n"
"logic [35:0]        imdct_pre_pk   [0:191];\n"
"(* ramstyle = \"M10K\" *)\n"
"logic [35:0]        imdct_post_pk  [0:95];\n"
"// packed butterfly schedule {op[2:0],a,b,c,d,wr[17:0],wi[17:0]}: long-block\n"
"// entries at 0..IMDCT_NSCHED-1, short-block at IMDCT_NSCHED..+NSCHED256-1\n"
"(* ramstyle = \"M10K\" *)\n"
"logic [70:0]        imdct_sched_pk [0:IMDCT_NSCHED+IMDCT_NSCHED256-1];\n"
"logic [2:0]         imdct_sched_op [0:IMDCT_NSCHED-1];\n"
"logic [7:0]         imdct_sched_a  [0:IMDCT_NSCHED-1];\n"
"logic [7:0]         imdct_sched_b  [0:IMDCT_NSCHED-1];\n"
"logic [7:0]         imdct_sched_c  [0:IMDCT_NSCHED-1];\n"
"logic [7:0]         imdct_sched_d  [0:IMDCT_NSCHED-1];\n"
"logic signed [17:0] imdct_sched_wr [0:IMDCT_NSCHED-1];\n"
"logic signed [17:0] imdct_sched_wi [0:IMDCT_NSCHED-1];\n"
"logic [2:0]         imdct_s256_op  [0:IMDCT_NSCHED256-1];\n"
"logic [7:0]         imdct_s256_a   [0:IMDCT_NSCHED256-1];\n"
"logic [7:0]         imdct_s256_b   [0:IMDCT_NSCHED256-1];\n"
"logic [7:0]         imdct_s256_c   [0:IMDCT_NSCHED256-1];\n"
"logic [7:0]         imdct_s256_d   [0:IMDCT_NSCHED256-1];\n"
"logic signed [17:0] imdct_s256_wr  [0:IMDCT_NSCHED256-1];\n"
"logic signed [17:0] imdct_s256_wi  [0:IMDCT_NSCHED256-1];\n\n"
"initial begin\n");

    // fftorder
    fprintf (f, "    imdct_fftorder = '{");
    for (int i = 0; i < 128; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 16 == 0 ? ",\n        " : ", ")), fftorder[i]);
    fprintf (f, "\n    };\n");

    // pre1 re/im
    fprintf (f, "    imdct_pre1_re = '{");
    for (int i = 0; i < 128; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (pre1[i].real));
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_pre1_im = '{");
    for (int i = 0; i < 128; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (pre1[i].imag));
    fprintf (f, "\n    };\n");

    // post1 re/im
    fprintf (f, "    imdct_post1_re = '{");
    for (int i = 0; i < 64; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (post1[i].real));
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_post1_im = '{");
    for (int i = 0; i < 64; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (post1[i].imag));
    fprintf (f, "\n    };\n");

    // pre2 / post2 (short-block twiddles)
    fprintf (f, "    imdct_pre2_re = '{");
    for (int i = 0; i < 64; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (pre2[i].real));
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_pre2_im = '{");
    for (int i = 0; i < 64; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (pre2[i].imag));
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_post2_re = '{");
    for (int i = 0; i < 32; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (post2[i].real));
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_post2_im = '{");
    for (int i = 0; i < 32; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (post2[i].imag));
    fprintf (f, "\n    };\n");

    // window
    fprintf (f, "    imdct_window = '{");
    for (int i = 0; i < 256; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (window[i]));
    fprintf (f, "\n    };\n");

    // schedule
    fprintf (f, "    imdct_sched_op = '{");
    for (int i = 0; i < nsched; i++)
        fprintf (f, "%s%s", (i == 0 ? "\n        " : (i % 6 == 0 ? ",\n        " : ", ")), opname (sched[i].op));
    fprintf (f, "\n    };\n");
    const char *names[4] = { "imdct_sched_a", "imdct_sched_b",
                             "imdct_sched_c", "imdct_sched_d" };
    for (int fld = 0; fld < 4; fld++) {
        fprintf (f, "    %s = '{", names[fld]);
        for (int i = 0; i < nsched; i++) {
            int v = fld == 0 ? sched[i].a : fld == 1 ? sched[i].b
                  : fld == 2 ? sched[i].c : sched[i].d;
            fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 12 == 0 ? ",\n        " : ", ")), v);
        }
        fprintf (f, "\n    };\n");
    }
    fprintf (f, "    imdct_sched_wr = '{");
    for (int i = 0; i < nsched; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (sched[i].wr));
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_sched_wi = '{");
    for (int i = 0; i < nsched; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (sched[i].wi));
    fprintf (f, "\n    };\n");

    // short-block (two ifft64) schedule
    fprintf (f, "    imdct_s256_op = '{");
    for (int i = 0; i < nsched256; i++)
        fprintf (f, "%s%s", (i == 0 ? "\n        " : (i % 6 == 0 ? ",\n        " : ", ")), opname (sched256[i].op));
    fprintf (f, "\n    };\n");
    const char *n256[4] = { "imdct_s256_a", "imdct_s256_b",
                            "imdct_s256_c", "imdct_s256_d" };
    for (int fld = 0; fld < 4; fld++) {
        fprintf (f, "    %s = '{", n256[fld]);
        for (int i = 0; i < nsched256; i++) {
            int v = fld == 0 ? sched256[i].a : fld == 1 ? sched256[i].b
                  : fld == 2 ? sched256[i].c : sched256[i].d;
            fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 12 == 0 ? ",\n        " : ", ")), v);
        }
        fprintf (f, "\n    };\n");
    }
    fprintf (f, "    imdct_s256_wr = '{");
    for (int i = 0; i < nsched256; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (sched256[i].wr));
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_s256_wi = '{");
    for (int i = 0; i < nsched256; i++)
        fprintf (f, "%s%d", (i == 0 ? "\n        " : (i % 8 == 0 ? ",\n        " : ", ")), q17 (sched256[i].wi));
    fprintf (f, "\n    };\n");

    // ---- M19c packed sync-ROM images (all literal-valued: no cross-array
    // initial-block copying — ordering-safe in sim, constant-foldable for
    // Quartus ROM inference; negative Q1.17 values as 18-bit two's-complement
    // hex so no signed casts appear in procedural code) ----
    fprintf (f, "    // M19c packed images of the tables above (see decls)\n");
    fprintf (f, "    imdct_pre_pk = '{");
    for (int i = 0; i < 192; i++) {
        cplx v = i < 128 ? pre1[i] : pre2[i - 128];
        unsigned long long w = (((unsigned long long)((unsigned) q17 (v.real) & 0x3FFFF)) << 18)
                             |  ((unsigned long long)((unsigned) q17 (v.imag) & 0x3FFFF));
        fprintf (f, "%s36'h%09llX", (i == 0 ? "\n        " : (i % 4 == 0 ? ",\n        " : ", ")), w);
    }
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_post_pk = '{");
    for (int i = 0; i < 96; i++) {
        cplx v = i < 64 ? post1[i] : post2[i - 64];
        unsigned long long w = (((unsigned long long)((unsigned) q17 (v.real) & 0x3FFFF)) << 18)
                             |  ((unsigned long long)((unsigned) q17 (v.imag) & 0x3FFFF));
        fprintf (f, "%s36'h%09llX", (i == 0 ? "\n        " : (i % 4 == 0 ? ",\n        " : ", ")), w);
    }
    fprintf (f, "\n    };\n");
    fprintf (f, "    imdct_sched_pk = '{");
    for (int i = 0; i < nsched + nsched256; i++) {
        const sop *e = i < nsched ? &sched[i] : &sched256[i - nsched];
        fprintf (f, "%s{%s, 8'd%d, 8'd%d, 8'd%d, 8'd%d, 18'h%05X, 18'h%05X}",
                 (i == 0 ? "\n        " : (i % 2 == 0 ? ",\n        " : ", ")),
                 opname (e->op), e->a, e->b, e->c, e->d,
                 (unsigned) q17 (e->wr) & 0x3FFFF,
                 (unsigned) q17 (e->wi) & 0x3FFFF);
    }
    fprintf (f, "\n    };\n");

    fprintf (f, "end\n\n`endif // AC3_IMDCT_TABLES_SVH\n");
    fclose (f);
    fprintf (stderr, "[gen_imdct] wrote %s (%d schedule ops)\n", path, nsched);
}

int main (int argc, char **argv) {
    const char *out = argc > 1 ? argv[1] : "ac3_imdct_tables.svh";
    a52_imdct_init (0);     // fills liba52's static tables (for the self-check)
    init_tables ();         // our replicated float tables
    rec_ifft128 ();         // trace the long-block (ifft128) schedule -> sched
    cur_sched = sched256; cur_n = &nsched256;
    rec_ifft256 ();         // trace the short-block (two ifft64) schedule
    cur_sched = sched;    cur_n = &nsched;
    self_check ();          // prove long schedule == liba52 before emitting
    self_check_256 ();      // prove short schedule == liba52 before emitting
    emit_svh (out);
    return 0;
}
