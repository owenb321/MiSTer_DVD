//============================================================================
//  gen_imdct_vec.c — standalone golden vector for imdct_512 (M8).
//
//  Builds two channels of random Q1.23 transform coefficients (a torture test:
//  every one of the 256 bins is populated, unlike real AC-3 which is sparse),
//  then calls liba52's exported a52_imdct_512() per channel — each with a fresh
//  zero delay line + bias 0, exactly as the RTL runs block 0 — to get the
//  golden time-domain samples.  Emits $readmemh files consumed by
//  imdct_512_tb.sv so the RTL and liba52 share one input:
//
//    imdct_coeff.mem   512 lines : coeff[{ch,idx}], 24-bit Q1.23 (hex)
//    imdct_golden.mem  512 lines : golden sample[{ch,idx}] as round(x*2^23),
//                                  32-bit Q8.23 (hex) — liba52 float, requantized
//
//  The TB drives the DUT from imdct_coeff.mem and checks each output against
//  imdct_golden.mem with a fixed-point tolerance (this is a float-vs-fixed
//  stage; see architecture.md §5).
//============================================================================
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <a52dec/a52.h>
#include <a52dec/a52_internal.h>

#define NCH  2
#define N    256

static int32_t coeff[NCH][N];   // Q1.23 ints
static sample_t data[N];        // per-channel float work buffer
static sample_t delay[N];

int main(void) {
    a52_imdct_init(0);          // fill liba52's static twiddle/window tables
    srand(0xA3C0FFEE);

    FILE *fc = fopen("imdct_coeff.mem",  "w");
    FILE *fg = fopen("imdct_golden.mem", "w");
    if (!fc || !fg) { perror("fopen"); return 1; }

    for (int ch = 0; ch < NCH; ch++) {
        for (int k = 0; k < N; k++) {
            // random Q1.23 in [-2^23, 2^23) -> value in [-1, 1)
            int32_t v = (int32_t)(rand() % (1 << 24)) - (1 << 23);
            coeff[ch][k] = v;
            data[k]  = (sample_t)((double)v / (double)(1 << 23));
            delay[k] = 0.0f;    // block 0: silent overlap (RTL rst-zeroes delay)
        }
        a52_imdct_512(data, delay, 0.0f);   // in-place -> golden samples in data[]
        for (int k = 0; k < N; k++) {
            fprintf(fc, "%06x\n", (unsigned)(coeff[ch][k] & 0xFFFFFF));
            // requantize liba52's float sample to Q8.23 for an integer compare
            int32_t g = (int32_t)lround((double)data[k] * (double)(1 << 23));
            fprintf(fg, "%08x\n", (unsigned)g);
        }
    }
    fclose(fc); fclose(fg);
    fprintf(stderr, "[gen_imdct_vec] wrote imdct_coeff.mem + imdct_golden.mem "
                    "(%d ch x %d)\n", NCH, N);
    return 0;
}
