//============================================================================
//  gen_imdct256_vec.c — standalone golden vector for the imdct_512 SHORT path
//  (M16, blksw==1).
//
//  Same idea as gen_imdct_vec.c but calls liba52's exported a52_imdct_256()
//  (the 256-pt short-block transform) per channel.  Builds two channels of
//  random Q1.23 transform coefficients (every one of the 256 bins populated —
//  a torture test), runs a52_imdct_256 with a fresh zero delay line + bias 0
//  (exactly as the RTL runs block 0 with blksw[ch]==1), and emits $readmemh
//  files consumed by imdct_256_tb.sv:
//
//    imdct256_coeff.mem   1024 lines : coeff[{blk,ch,idx}], 24-bit Q1.23 (hex)
//    imdct256_golden.mem  1024 lines : golden sample as round(x*2^23), 32-bit
//                                      Q8.23 (hex) — liba52 float, requantized
//
//  TWO consecutive blocks per channel are emitted (block 0 with a fresh zero
//  delay line, block 1 with the delay line carried over from block 0) so the TB
//  exercises BOTH the short-block overlap WRITE (block 0) and READ (block 1) —
//  i.e. the delay-line packing of imdct_512's S_POST256.  Layout per .mem:
//  lines [0..511] = block 0 ({ch,idx}), [512..1023] = block 1.  The TB drives
//  the DUT with blksw set so both channels take the short path, then checks each
//  Q8.23 output sample against the requantized liba52 golden with a fixed-point
//  tolerance (float-vs-fixed; see architecture.md §5).
//============================================================================
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <a52dec/a52.h>
#include <a52dec/a52_internal.h>

#define NCH  2
#define NB   2          // blocks per channel (0: fresh delay, 1: carried delay)
#define N    256

static int32_t coeff[NB][NCH][N];   // Q1.23 ints
static int32_t gold [NB][NCH][N];   // requantized golden samples (Q8.23)
static sample_t data[N];            // per-channel float work buffer
static sample_t delay[NCH][N];      // per-channel overlap state, carried across blocks

int main(void) {
    a52_imdct_init(0);          // fill liba52's static twiddle/window tables
    srand(0x5407B10C);

    FILE *fc = fopen("imdct256_coeff.mem",  "w");
    FILE *fg = fopen("imdct256_golden.mem", "w");
    if (!fc || !fg) { perror("fopen"); return 1; }

    for (int ch = 0; ch < NCH; ch++)
        for (int k = 0; k < N; k++) delay[ch][k] = 0.0f;  // block 0: silent overlap

    for (int b = 0; b < NB; b++)
        for (int ch = 0; ch < NCH; ch++) {
            for (int k = 0; k < N; k++) {
                int32_t v = (int32_t)(rand() % (1 << 24)) - (1 << 23);  // [-2^23,2^23)
                coeff[b][ch][k] = v;
                data[k] = (sample_t)((double)v / (double)(1 << 23));     // [-1, 1)
            }
            // a52_imdct_256 reads+updates delay[ch] in place — the overlap state
            // carries from block 0 into block 1, exactly like the RTL delay_mem.
            a52_imdct_256(data, delay[ch], 0.0f);
            for (int k = 0; k < N; k++)
                gold[b][ch][k] = (int32_t)lround((double)data[k] * (double)(1 << 23));
        }

    for (int b = 0; b < NB; b++)
        for (int ch = 0; ch < NCH; ch++)
            for (int k = 0; k < N; k++) {
                fprintf(fc, "%06x\n", (unsigned)(coeff[b][ch][k] & 0xFFFFFF));
                fprintf(fg, "%08x\n", (unsigned)gold[b][ch][k]);
            }
    fclose(fc); fclose(fg);
    fprintf(stderr, "[gen_imdct256_vec] wrote imdct256_coeff.mem + imdct256_golden.mem "
                    "(%d blk x %d ch x %d)\n", NB, NCH, N);
    return 0;
}
