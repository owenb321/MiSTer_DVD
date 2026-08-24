//============================================================================
//  gen_drc_vec.c — golden vector for the M17 DRC (dynrng) path in imdct_512.
//
//  Verifies that imdct_512 applies the per-block dynamic-range gain correctly.
//  The dut decodes the 8-bit `dynrng` word to a linear gain and multiplies it
//  into every coefficient at the PRE read (A/52 §7.7.1):
//
//      gain = (0x20 | (dynrng & 0x1f)) / 32 * 2^signed3(dynrng>>5)
//
//  where dynrng[7:5] is a 3-bit TWO'S-COMPLEMENT exponent (-4..+3): unity at
//  dynrng==0x00, max cut 0x80 (-24 dB), max boost 0x7F (+23.9 dB).  This
//  matches liba52's parse.c, which reads the byte as a SIGNED int8 before
//  `>>5`.  (This file's original formula decoded the exponent UNSIGNED —
//  unity at 0x80, the exact pre-M17 RTL bug — so every golden mismatched the
//  fixed RTL and the TB had been failing silently, masked by vvp's zero exit.)
//
//  Each test CASE is one independent block (fresh zero delay line, like block 0)
//  with one dynrng word applied to both channels.  The golden scales the random
//  Q1.23 coeffs by `gain` (in double) and runs liba52's exported a52_imdct_512;
//  the dut gets the UNSCALED coeffs + the dynrng word and must reproduce it
//  within the usual fixed-point IMDCT tolerance.
//
//  Emits, consumed by drc_tb.sv:
//    drc_coeff.mem    NCASE*2*256 lines : unscaled coeff[{case,ch,idx}] Q1.23 hex
//    drc_golden.mem   NCASE*2*256 lines : golden sample Q8.23 hex (gain-scaled)
//    drc_dynrng.mem   NCASE lines       : the 8-bit dynrng word per case (hex)
//============================================================================
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <a52dec/a52.h>
#include <a52dec/a52_internal.h>

#define NCH  2
#define N    256

// dynrng words spanning the gain range under the signed-exponent decode:
// 0x00 unity, 0x5A/0x7F boosts, 0x80 max cut (-24 dB), 0x9C/0xC3/0xFF cuts.
static const unsigned dynrng_cases[] = { 0x00, 0x5A, 0x80, 0x9C, 0xC3, 0xFF };
#define NCASE ((int)(sizeof(dynrng_cases)/sizeof(dynrng_cases[0])))

static int32_t coeff[NCH][N];
static sample_t data[N];
static sample_t delay[N];

static double drc_gain(unsigned w) {
    int mant = (int)(w & 0x1f);
    int exp  = ((int)(signed char)w) >> 5;          // two's-complement [7:5]
    return ldexp((double)(0x20 | mant), exp - 5);   // (32+mant)/32 * 2^exp
}

int main(void) {
    a52_imdct_init(0);
    srand(0xD8C0FFEE);

    FILE *fc = fopen("drc_coeff.mem",  "w");
    FILE *fg = fopen("drc_golden.mem", "w");
    FILE *fd = fopen("drc_dynrng.mem", "w");
    if (!fc || !fg || !fd) { perror("fopen"); return 1; }

    for (int c = 0; c < NCASE; c++) {
        unsigned w = dynrng_cases[c];
        double   g = drc_gain(w);
        fprintf(fd, "%02x\n", w);
        for (int ch = 0; ch < NCH; ch++) {
            for (int k = 0; k < N; k++) {
                // Moderate amplitude (|coeff| < 1/8) so even the +24 dB case
                // (×15.75) stays well inside [-1,1) → output bounded like the
                // full-scale unity torture vector; tolerance stays meaningful.
                int32_t v = (int32_t)(rand() % (1 << 21)) - (1 << 20);  // [-2^20,2^20)
                coeff[ch][k] = v;
                data[k]  = (sample_t)(((double)v / (double)(1 << 23)) * g);
                delay[k] = 0.0f;
            }
            a52_imdct_512(data, delay, 0.0f);
            for (int k = 0; k < N; k++) {
                fprintf(fc, "%06x\n", (unsigned)(coeff[ch][k] & 0xFFFFFF));
                int32_t gg = (int32_t)lround((double)data[k] * (double)(1 << 23));
                fprintf(fg, "%08x\n", (unsigned)gg);
            }
        }
    }
    fclose(fc); fclose(fg); fclose(fd);
    fprintf(stderr, "[gen_drc_vec] wrote drc_{coeff,golden,dynrng}.mem "
                    "(%d cases x %d ch x %d)\n", NCASE, NCH, N);
    return 0;
}
