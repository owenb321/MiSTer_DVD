/* define DCT types */

/*
 * DCTSIZE      underlying (1d) transform size
 * DCTSIZE2     DCTSIZE squared
 */

#define DCTSIZE      (8)
#define DCTSIZE2     (DCTSIZE*DCTSIZE)

#define EIGHT_BIT_SAMPLES	/* needed in jrevdct.c */

typedef short DCTELEM;		/* must be at least 16 bits */

typedef DCTELEM DCTBLOCK[DCTSIZE2];

typedef long INT32;		/* must be at least 32 bits */

extern void j_fwd_dct();
extern void j_rev_dct();
