// probe_5p1.c — dump liba52 ground-truth geometry for a 5.1 (acmod==7) stream,
// so the RTL audblk_parse / exponent_decode / bit_allocation can be implemented
// against real per-channel numbers (and the bit order cross-checked).
//
// build: gcc -O2 probe_5p1.c -la52 -lm -o /tmp/probe_5p1
// run:   /tmp/probe_5p1 ../../tools/streams/tone_5p1_48k_192k.ac3
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <a52dec/a52.h>
#include <a52dec/a52_internal.h>

static int nfchans_of(int acmod){
    static const int t[8]={2,1,2,3,3,4,4,5};
    return t[acmod & 7];
}

int main(int argc,char**argv){
    if(argc<2){fprintf(stderr,"usage: %s file.ac3\n",argv[0]);return 2;}
    FILE*f=fopen(argv[1],"rb"); if(!f){perror("open");return 2;}
    fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t*buf=malloc(n); if(fread(buf,1,n,f)!=(size_t)n)return 2; fclose(f);

    a52_state_t*st=a52_init(0);
    long off=0; int frame=0;
    while(off+7<=n && frame<2){
        int flags=0,srate=0,brate=0;
        int len=a52_syncinfo(buf+off,&flags,&srate,&brate);
        if(len<=0){off++;continue;}
        int acmod=flags&A52_CHANNEL_MASK, lfe=(flags&A52_LFE)?1:0;
        int nf=nfchans_of(acmod);
        sample_t level=1.0,bias=0.0; int aflags=flags;
        printf("=== frame %d: len=%d acmod=%d nfchans=%d lfe=%d ===\n",
               frame,len,acmod,nf,lfe);
        if(a52_frame(st,buf+off,&aflags,&level,bias)==0){
            printf("  clev=%.6f slev=%.6f\n",(double)st->clev,(double)st->slev);
            for(int b=0;b<6;b++){
                if(a52_block(st)!=0){printf("  block %d: a52_block FAILED\n",b);break;}
                printf("  blk%d chincpl=0x%x cplstrtmant=%d cplendmant=%d ncplbnd=%d cplstrtbnd=%d phsflginu=%d rematflg=0x%x\n",
                       b,st->chincpl,st->cplstrtmant,st->cplendmant,st->ncplbnd,st->cplstrtbnd,st->phsflginu,st->rematflg);
                for(int ch=0;ch<nf;ch++)
                    printf("     fbw[%d] endmant=%d exp[0..3]=%d,%d,%d,%d bap[0..3]=%d,%d,%d,%d\n",
                       ch,st->endmant[ch],
                       st->fbw_expbap[ch].exp[0],st->fbw_expbap[ch].exp[1],st->fbw_expbap[ch].exp[2],st->fbw_expbap[ch].exp[3],
                       st->fbw_expbap[ch].bap[0],st->fbw_expbap[ch].bap[1],st->fbw_expbap[ch].bap[2],st->fbw_expbap[ch].bap[3]);
                if(lfe)
                    printf("     lfe exp[0..6]=%d,%d,%d,%d,%d,%d,%d bap[0..6]=%d,%d,%d,%d,%d,%d,%d\n",
                       st->lfe_expbap.exp[0],st->lfe_expbap.exp[1],st->lfe_expbap.exp[2],st->lfe_expbap.exp[3],
                       st->lfe_expbap.exp[4],st->lfe_expbap.exp[5],st->lfe_expbap.exp[6],
                       st->lfe_expbap.bap[0],st->lfe_expbap.bap[1],st->lfe_expbap.bap[2],st->lfe_expbap.bap[3],
                       st->lfe_expbap.bap[4],st->lfe_expbap.bap[5],st->lfe_expbap.bap[6]);
                if(st->chincpl)
                    printf("     cpl exp[strt..+3]=%d,%d,%d,%d bap=%d,%d,%d,%d\n",
                       st->cpl_expbap.exp[st->cplstrtmant],st->cpl_expbap.exp[st->cplstrtmant+1],
                       st->cpl_expbap.exp[st->cplstrtmant+2],st->cpl_expbap.exp[st->cplstrtmant+3],
                       st->cpl_expbap.bap[st->cplstrtmant],st->cpl_expbap.bap[st->cplstrtmant+1],
                       st->cpl_expbap.bap[st->cplstrtmant+2],st->cpl_expbap.bap[st->cplstrtmant+3]);
            }
        }
        off+=len; frame++;
    }
    return 0;
}
