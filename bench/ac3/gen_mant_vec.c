//============================================================================
//  gen_mant_vec.c — generate a standalone golden vector for mantissa_dequant.
//
//  Builds a hand-shaped two-channel mantissa problem that exercises every bap
//  class (zero, dither, the three grouped quantizers q1/q2/q4, the two direct-
//  table quantizers q3/q5, and direct reads of several bit widths 5..16),
//  including a grouped run that straddles the ch0→ch1 boundary so the shared
//  quantizer cache must persist across channels (exactly as liba52 does).
//
//  It walks the coefficients in the SAME order mantissa_dequant reads them and,
//  at each bitstream read, picks a code, appends its bits MSB-first to the
//  mantissa bitstream, and computes the resulting mantissa(s).  Two goldens are
//  produced from one walk so the bitstream and goldens can never disagree:
//
//    mant_gold_fixed.mem : the *exact* Q1.23 value the RTL must compute — uses
//        the same round-to-nearest 16-bit level integers and the same
//        (m16<<8)>>exp truncation as ac3_mant_tables.svh / mantissa_dequant.
//        The TB checks this BIT-EXACT (proves the ungroup/cache/scale logic).
//    mant_goldf.mem      : liba52's *float* reconstruction, rounded to Q1.23.
//        The TB measures max |dut − this| to bound the fixed-point error (the
//        M7 "isolate quantization error" goal).  See architecture.md §5.
//
//  Mem files (all consumed by mantissa_dequant_tb.sv):
//    mant_bits.mem    bytes of the mantissa bitstream            (hex, 1/line)
//    mant_params.mem  endmant0/1, dithflag, nbytes               (hex)
//    mant_exp.mem     512 : exp[{ch,idx}]   5-bit                 (hex)
//    mant_bap.mem     512 : bap[{ch,idx}]   8-bit 2's complement  (hex)
//    mant_gold_fixed.mem 512 : Q1.23 24-bit 2's complement        (hex)
//    mant_goldf.mem      512 : Q1.23 24-bit 2's complement        (hex)
//============================================================================
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

// ---- liba52 dither LFSR (tables.h dither_lut) ----
static const uint16_t dither_lut[256] = {
    0x0000,0xa011,0xe033,0x4022,0x6077,0xc066,0x8044,0x2055,0xc0ee,0x60ff,0x20dd,0x80cc,0xa099,0x0088,0x40aa,0xe0bb,
    0x21cd,0x81dc,0xc1fe,0x61ef,0x41ba,0xe1ab,0xa189,0x0198,0xe123,0x4132,0x0110,0xa101,0x8154,0x2145,0x6167,0xc176,
    0x439a,0xe38b,0xa3a9,0x03b8,0x23ed,0x83fc,0xc3de,0x63cf,0x8374,0x2365,0x6347,0xc356,0xe303,0x4312,0x0330,0xa321,
    0x6257,0xc246,0x8264,0x2275,0x0220,0xa231,0xe213,0x4202,0xa2b9,0x02a8,0x428a,0xe29b,0xc2ce,0x62df,0x22fd,0x82ec,
    0x8734,0x2725,0x6707,0xc716,0xe743,0x4752,0x0770,0xa761,0x47da,0xe7cb,0xa7e9,0x07f8,0x27ad,0x87bc,0xc79e,0x678f,
    0xa6f9,0x06e8,0x46ca,0xe6db,0xc68e,0x669f,0x26bd,0x86ac,0x6617,0xc606,0x8624,0x2635,0x0660,0xa671,0xe653,0x4642,
    0xc4ae,0x64bf,0x249d,0x848c,0xa4d9,0x04c8,0x44ea,0xe4fb,0x0440,0xa451,0xe473,0x4462,0x6437,0xc426,0x8404,0x2415,
    0xe563,0x4572,0x0550,0xa541,0x8514,0x2505,0x6527,0xc536,0x258d,0x859c,0xc5be,0x65af,0x45fa,0xe5eb,0xa5c9,0x05d8,
    0xae79,0x0e68,0x4e4a,0xee5b,0xce0e,0x6e1f,0x2e3d,0x8e2c,0x6e97,0xce86,0x8ea4,0x2eb5,0x0ee0,0xaef1,0xeed3,0x4ec2,
    0x8fb4,0x2fa5,0x6f87,0xcf96,0xefc3,0x4fd2,0x0ff0,0xafe1,0x4f5a,0xef4b,0xaf69,0x0f78,0x2f2d,0x8f3c,0xcf1e,0x6f0f,
    0xede3,0x4df2,0x0dd0,0xadc1,0x8d94,0x2d85,0x6da7,0xcdb6,0x2d0d,0x8d1c,0xcd3e,0x6d2f,0x4d7a,0xed6b,0xad49,0x0d58,
    0xcc2e,0x6c3f,0x2c1d,0x8c0c,0xac59,0x0c48,0x4c6a,0xec7b,0x0cc0,0xacd1,0xecf3,0x4ce2,0x6cb7,0xcca6,0x8c84,0x2c95,
    0x294d,0x895c,0xc97e,0x696f,0x493a,0xe92b,0xa909,0x0918,0xe9a3,0x49b2,0x0990,0xa981,0x89d4,0x29c5,0x69e7,0xc9f6,
    0x0880,0xa891,0xe8b3,0x48a2,0x68f7,0xc8e6,0x88c4,0x28d5,0xc86e,0x687f,0x285d,0x884c,0xa819,0x0808,0x482a,0xe83b,
    0x6ad7,0xcac6,0x8ae4,0x2af5,0x0aa0,0xaab1,0xea93,0x4a82,0xaa39,0x0a28,0x4a0a,0xea1b,0xca4e,0x6a5f,0x2a7d,0x8a6c,
    0x4b1a,0xeb0b,0xab29,0x0b38,0x2b6d,0x8b7c,0xcb5e,0x6b4f,0x8bf4,0x2be5,0x6bc7,0xcbd6,0xeb83,0x4b92,0x0bb0,0xaba1
};
#define LEVEL_3DB 0.7071067811865476

// scale_factor[exp] = 2^-(15+exp).
static double scale_factor(int e) { return ldexp(1.0, -(15 + e)); }

// quantizer level value (float) for sub-index s in a level set of N values
// k = -(N-1)..(N-1) step 2 : liba52 stores (k<<15)/N.
static double levf(int N, int s) { int k = 2*s - (N-1); return (double)(k << 15) / (double)N; }
static int    levi(int N, int s) { return (int)lround(levf(N, s)); }

// ---- bitstream emitter (MSB-first) ----
static uint8_t bits[8192]; static int nbits = 0;
static void emit(uint32_t val, int w) {
    for (int i = w - 1; i >= 0; i--) bits[nbits++] = (val >> i) & 1;
}

// ---- reproducible PRNG (xorshift32, fixed seed) ----
static uint32_t rng = 0x1234abcdu;
static uint32_t nrand(void){ rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; }

int main(void) {
    const int endmant[2] = {60, 40};
    const int dith[2]     = {1, 0};        // ch0 dithers bap0, ch1 zeroes them

    int8_t  bap[2][256];
    uint8_t exp[2][256];
    memset(bap, 0, sizeof(bap));
    memset(exp, 0, sizeof(exp));

    // ---- hand-shaped bap pattern (covers every class) ----
    // ch0: zero/dither, then runs of each grouped quantizer, the two direct
    // tables, a sweep of direct widths, and a q1 run that ends ch0 mid-group.
    for (int k = 0; k < endmant[0]; k++) bap[0][k] = 5;          // default direct-5
    for (int k = 0; k < 4;  k++) bap[0][k] = 0;                  // 0..3  dither
    for (int k = 4; k < 10; k++) bap[0][k] = -1;                 // 4..9  q1 (6)
    for (int k =10; k < 16; k++) bap[0][k] = -2;                 // 10..15 q2 (6)
    for (int k =16; k < 21; k++) bap[0][k] = -3;                 // 16..20 q4 (5)
    for (int k =21; k < 26; k++) bap[0][k] = 3;                  // 21..25 q3
    for (int k =26; k < 31; k++) bap[0][k] = 4;                  // 26..30 q5
    { int w[10]={5,6,7,8,9,10,11,12,14,16};
      for (int k=31;k<41;k++) bap[0][k]=w[k-31]; }               // 31..40 direct sweep
    bap[0][57] = 6;                                              // break any cache
    bap[0][58] = -1; bap[0][59] = -1;                            // q1 read@58, cache→ch1
    // ch1: first q1 consumes ch0's leftover cache (no read), then fresh q1, then
    // non-dithered zeros and a direct mix.
    for (int k = 0; k < endmant[1]; k++) bap[1][k] = 7;          // default direct-7
    bap[1][0] = -1; bap[1][1] = -1; bap[1][2] = -1; bap[1][3] = -1;  // q1 across boundary
    for (int k = 4; k < 8;  k++) bap[1][k] = 0;                  // non-dither zeros
    bap[1][8] = -2; bap[1][9] = -2; bap[1][10] = -2;             // q2 group
    bap[1][11] = -3; bap[1][12] = -3;                            // q4 group
    bap[1][13] = 3; bap[1][14] = 4;

    // exponents: vary, and force exp==0 inside grouped runs (worst-case error).
    for (int ch = 0; ch < 2; ch++)
        for (int k = 0; k < endmant[ch]; k++)
            exp[ch][k] = (uint8_t)((k * 3 + ch * 7) % 25);
    exp[0][4] = 0; exp[0][5] = 0; exp[0][10] = 0; exp[0][16] = 0; // grouped @ exp0
    exp[1][0] = 0; exp[1][8] = 0;

    // ---- walk coeffs exactly as mantissa_dequant: emit bits + both goldens ----
    int32_t gold_fixed[2][256];
    int32_t goldf[2][256];
    memset(gold_fixed, 0, sizeof(gold_fixed));
    memset(goldf, 0, sizeof(goldf));

    // shared quantizer caches (persist across channels — never reset per ch)
    double q1cf[2], q2cf[2], q4cf; int q1ci[2], q2ci[2], q4ci;
    int q1ptr = -1, q2ptr = -1, q4ptr = -1;
    uint16_t lfsr = 1;

    for (int ch = 0; ch < 2; ch++) {
        for (int k = 0; k < endmant[ch]; k++) {
            int b = bap[ch][k], e = exp[ch][k];
            double mf = 0.0; int mi = 0;     // mantissa: float ref + rom integer
            int  is_dith = 0; int dith_ns = 0;  // M14: full-precision dither path
            switch (b) {
            case 0:
                if (dith[ch]) {
                    int16_t ns = (int16_t)(dither_lut[lfsr >> 8] ^ (lfsr << 8));
                    lfsr = (uint16_t)ns;
                    mf = (double)ns * LEVEL_3DB;
                    is_dith = 1; dith_ns = ns;
                } else { mf = 0.0; mi = 0; }
                break;
            case -1:    // q1 3-level, group of 3, 5-bit code
                if (q1ptr >= 0) { mf = q1cf[q1ptr]; mi = q1ci[q1ptr]; q1ptr--; }
                else {
                    uint32_t c = nrand() % 27; emit(c, 5);
                    int a=c/9, bb=(c/3)%3, cc=c%3;
                    mf=levf(3,a); mi=levi(3,a);
                    q1cf[1]=levf(3,bb); q1ci[1]=levi(3,bb);
                    q1cf[0]=levf(3,cc); q1ci[0]=levi(3,cc); q1ptr=1;
                }
                break;
            case -2:    // q2 5-level, group of 3, 7-bit code
                if (q2ptr >= 0) { mf = q2cf[q2ptr]; mi = q2ci[q2ptr]; q2ptr--; }
                else {
                    uint32_t c = nrand() % 125; emit(c, 7);
                    int a=c/25, bb=(c/5)%5, cc=c%5;
                    mf=levf(5,a); mi=levi(5,a);
                    q2cf[1]=levf(5,bb); q2ci[1]=levi(5,bb);
                    q2cf[0]=levf(5,cc); q2ci[0]=levi(5,cc); q2ptr=1;
                }
                break;
            case -3:    // q4 11-level, group of 2, 7-bit code
                if (q4ptr == 0) { mf = q4cf; mi = q4ci; q4ptr = -1; }
                else {
                    uint32_t c = nrand() % 121; emit(c, 7);
                    int a=c/11, bb=c%11;
                    mf=levf(11,a); mi=levi(11,a);
                    q4cf=levf(11,bb); q4ci=levi(11,bb); q4ptr=0;
                }
                break;
            case 3: {   // q3 7-level, direct 3-bit
                uint32_t c = nrand() % 7; emit(c, 3);
                mf=levf(7,c); mi=levi(7,c);
            } break;
            case 4: {   // q5 15-level, direct 4-bit
                uint32_t c = nrand() % 15; emit(c, 4);
                mf=levf(15,c); mi=levi(15,c);
            } break;
            default: {  // direct, b bits signed: m16 = sext(bits)<<(16-b)
                int range = 1 << (b - 1);
                int val = (int)(nrand() % (uint32_t)(2 * range)) - range; // [-range,range)
                emit((uint32_t)val & ((1u << b) - 1u), b);
                int m = val << (16 - b);
                mf = (double)m; mi = m;
            } break;
            }

            double cf = mf * scale_factor(e);
            goldf[ch][k]      = (int32_t)lround(cf * (double)(1 << 23));
            if (is_dith) {
                // M14 dither_coeff(): round(ns*23170 / 2^(7+e)) in ONE step (no
                // early 17-bit floor), matching the RTL full-precision path.
                int sh = 7 + e;
                long long prod = (long long)dith_ns * 23170LL;
                long long r = (prod + (1LL << (sh - 1))) >> sh;   // round-to-nearest
                gold_fixed[ch][k] = (int32_t)r;
            } else {
                gold_fixed[ch][k] = ((int32_t)mi << 8) >> e;   // truncating, matches RTL
            }
        }
        // HF tail endmant..255 stays 0 in both goldens (memset).
    }

    int nbytes = (nbits + 7) / 8;

    // ---- emit mem files ----
    FILE *fb = fopen("mant_bits.mem", "w");
    for (int by = 0; by < nbytes; by++) {
        int v = 0;
        for (int i = 0; i < 8; i++) {
            int bi = by * 8 + i;
            if (bi < nbits && bits[bi]) v |= (1 << (7 - i));
        }
        fprintf(fb, "%02x\n", v & 0xff);
    }
    fclose(fb);

    FILE *fe = fopen("mant_exp.mem", "w");
    FILE *fp = fopen("mant_bap.mem", "w");
    FILE *gx = fopen("mant_gold_fixed.mem", "w");
    FILE *gf = fopen("mant_goldf.mem", "w");
    for (int ch = 0; ch < 2; ch++)
        for (int k = 0; k < 256; k++) {
            fprintf(fe, "%02x\n", exp[ch][k] & 0x1f);
            fprintf(fp, "%02x\n", (uint8_t)bap[ch][k]);
            fprintf(gx, "%06x\n", (uint32_t)gold_fixed[ch][k] & 0xffffff);
            fprintf(gf, "%06x\n", (uint32_t)goldf[ch][k]      & 0xffffff);
        }
    fclose(fe); fclose(fp); fclose(gx); fclose(gf);

    FILE *pf = fopen("mant_params.mem", "w");
    int p[8] = { endmant[0], endmant[1], (dith[1]<<1)|dith[0], nbytes, 0,0,0,0 };
    for (int k = 0; k < 8; k++) fprintf(pf, "%04x\n", p[k] & 0xffff);
    fclose(pf);

    printf("gen_mant_vec: endmant=%d,%d dithflag=%d%d  mantissa bits=%d (%d bytes)\n",
           endmant[0], endmant[1], dith[1], dith[0], nbits, nbytes);
    return 0;
}
