//============================================================================
//  gen_balloc_vec.c — generate a standalone golden vector for bit_allocation.
//
//  Builds a hand-picked two-channel bit-allocation problem (varied exponents,
//  realistic BAI/SNR sub-codes, and a DELTA_BIT_NEW channel that the co-sim
//  streams never exercise), then calls liba52's exported a52_bit_allocate()
//  directly to get the golden bap[].  Emits $readmemh files consumed by
//  bit_allocation_tb.sv so the RTL and liba52 share one source of truth:
//
//    balloc_exp.mem     512 lines : exp[{ch,idx}]                   (hex)
//    balloc_deltba.mem  128 lines : deltba[{ch,band}], 4-bit 2'comp (hex)
//    balloc_params.mem   16 lines : endmant/sub-codes/deltbae       (hex)
//    balloc_golden.mem  512 lines : golden bap[{ch,idx}], 8-bit 2'comp (hex)
//
//  The RTL takes the BAI as sub-codes; liba52 packs them into state->bai /
//  ba->bai, so we derive both here from the same sub-code constants.
//============================================================================
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <a52dec/a52.h>
#include <a52dec/a52_internal.h>

int main(void) {
    // ---- hand-picked input ----
    const int endmant[2] = {133, 88};

    // BAI sub-codes (shared by RTL inputs and liba52's packed bai).
    const int sdcycod = 2, fdcycod = 1, sgaincod = 1, dbpbcod = 3, floorcod = 7;
    const int csnroffst = 20;
    const int fsnroffst[2] = {13, 10};
    const int fgaincod[2]  = {4, 4};
    const int deltbae[2]   = {DELTA_BIT_NEW, DELTA_BIT_NONE};

    a52_state_t st;
    memset(&st, 0, sizeof(st));
    st.fscod    = 0;            // 48 kHz
    st.halfrate = 0;
    st.csnroffst = csnroffst;
    st.bai = (sdcycod << 9) | (fdcycod << 7) | (sgaincod << 5) |
             (dbpbcod << 3) | floorcod;

    ba_t ba[2];
    expbap_t eb[2];
    memset(ba, 0, sizeof(ba));
    memset(eb, 0, sizeof(eb));

    // Varied exponents in [0,24] (rising/falling to exercise lowcomp + log-add).
    for (int ch = 0; ch < 2; ch++) {
        for (int k = 0; k < endmant[ch]; k++) {
            int v = 2 + ((k * 5 + 3 * (k / 4) + ch * 7) % 11);
            int dip = ((k % 9) == 0) ? 2 : 0;       // occasional exp[i+1]==exp[i]-2
            v -= dip;
            if (v < 0) v = 0; if (v > 24) v = 24;
            eb[ch].exp[k] = (uint8_t)v;
        }
        ba[ch].bai = (fsnroffst[ch] << 3) | fgaincod[ch];
        ba[ch].deltbae = deltbae[ch];
    }

    // ch0 delta bit allocation (DELTA_BIT_NEW): a few non-zero bands.
    ba[0].deltba[30] =  3;
    ba[0].deltba[31] =  3;
    ba[0].deltba[32] = -2;
    ba[0].deltba[40] =  1;

    // ---- golden: liba52 bit allocation, in-scope call shape ----
    for (int ch = 0; ch < 2; ch++)
        a52_bit_allocate(&st, &ba[ch], 0, 0, endmant[ch], 0, 0, &eb[ch]);

    // ---- emit mem files ----
    FILE *fe = fopen("balloc_exp.mem", "w");
    FILE *fd = fopen("balloc_deltba.mem", "w");
    FILE *fg = fopen("balloc_golden.mem", "w");
    for (int ch = 0; ch < 2; ch++)
        for (int k = 0; k < 256; k++) {
            fprintf(fe, "%02x\n", eb[ch].exp[k] & 0x1f);
            fprintf(fg, "%02x\n", (uint8_t)(int8_t)eb[ch].bap[k]);
        }
    for (int ch = 0; ch < 2; ch++)
        for (int b = 0; b < 64; b++) {
            int dv = (deltbae[ch] == DELTA_BIT_NEW) ? ba[ch].deltba[b] : 0;
            fprintf(fd, "%01x\n", (uint8_t)(int8_t)dv & 0xf);
        }
    fclose(fe); fclose(fd); fclose(fg);

    FILE *fp = fopen("balloc_params.mem", "w");
    int p[16] = { endmant[0], endmant[1], sdcycod, fdcycod, sgaincod, dbpbcod,
                  floorcod, csnroffst, fsnroffst[0], fgaincod[0],
                  fsnroffst[1], fgaincod[1], deltbae[0], deltbae[1], 0, 0 };
    for (int k = 0; k < 16; k++) fprintf(fp, "%04x\n", p[k] & 0xffff);
    fclose(fp);

    printf("gen_balloc_vec: endmant=%d,%d  bai=0x%03x  csnroffst=%d  "
           "ba.bai=0x%02x,0x%02x  deltbae=%d,%d\n",
           endmant[0], endmant[1], st.bai, csnroffst,
           ba[0].bai, ba[1].bai, deltbae[0], deltbae[1]);
    return 0;
}
