/* Predict.c, motion compensation routines                                    */

/* Copyright (C) 1996, MPEG Software Simulation Group. All Rights Reserved. */

/*
 * Disclaimer of Warranty
 *
 * These software programs are available to the user without any license fee or
 * royalty on an "as is" basis.  The MPEG Software Simulation Group disclaims
 * any and all warranties, whether express, implied, or statuary, including any
 * implied warranties or merchantability or of fitness for a particular
 * purpose.  In no event shall the copyright-holder be liable for any
 * incidental, punitive, or consequential damages of any kind whatsoever
 * arising from the use of these programs.
 *
 * This disclaimer of warranty extends to the user of these programs and user's
 * customers, employees, agents, transferees, successors, and assigns.
 *
 * The MPEG Software Simulation Group does not represent or warrant that the
 * programs furnished hereunder are free of infringement of any third-party
 * patents.
 *
 * Commercial implementations of MPEG-1 and MPEG-2 video, including shareware,
 * are subject to royalty fees to patent holders.  Many of these patents are
 * general enough such that they are unavoidable regardless of implementation
 * design.
 *
 */

#include <stdio.h>

#include "config.h"
#include "global.h"

#ifdef TRACE_RECON
/* Detailed tracing */
static int printPixelAddress(unsigned char *addr, char *str, unsigned char *frame_addr, int w, int h)
{
    int size;
    long int offset, x, y;
    int val;
    size = w * h;
    offset = addr - frame_addr;

    if ((frame_addr != NULL) && (offset >= 0) && (offset < size)) {
	y = offset / w ;
        x = offset % w ;
        val = *addr;
//        printf("printPixelAddress: addr: %p frame_addr: %p w: %i h: %i offset: %li\n", addr, frame_addr, w, h, offset);
	printf("%s[%3li,%3li]", str, x, y);
	printf("(=%3i)", val);
        return (1);
    }
    else {
      return(0);
    }
}

void printPixel(unsigned char *addr)
{
  if (
  !printPixelAddress(addr, "bwd_y", backward_reference_frame[0], Coded_Picture_Width, Coded_Picture_Height) &&
  !printPixelAddress(addr, "fwd_y", forward_reference_frame[0], Coded_Picture_Width, Coded_Picture_Height) &&
  !printPixelAddress(addr, "aux_y", auxframe[0], Coded_Picture_Width, Coded_Picture_Height) &&
  !printPixelAddress(addr, "bwd_u", backward_reference_frame[1], Chroma_Width, Chroma_Height) &&
  !printPixelAddress(addr, "fwd_u", forward_reference_frame[1], Chroma_Width, Chroma_Height) &&
  !printPixelAddress(addr, "aux_u", auxframe[1], Chroma_Width, Chroma_Height) &&
  !printPixelAddress(addr, "bwd_v", backward_reference_frame[2], Chroma_Width, Chroma_Height) &&
  !printPixelAddress(addr, "fwd_v", forward_reference_frame[2], Chroma_Width, Chroma_Height) &&
  !printPixelAddress(addr, "aux_v", auxframe[2], Chroma_Width, Chroma_Height)) {
    printf ("***pixel not found***");
  }
}
#endif

/* private prototypes */
static void form_prediction _ANSI_ARGS_((unsigned char *src[], int sfield,
  unsigned char *dst[], int dfield,
  int lx, int lx2, int w, int h, int x, int y, int dx, int dy,
  int average_flag));

static void form_component_prediction _ANSI_ARGS_((unsigned char *src, unsigned char *dst,
  int lx, int lx2, int w, int h, int x, int y, int dx, int dy, int average_flag));

void form_predictions(bx,by,macroblock_type,motion_type,PMV,motion_vertical_field_select,dmvector,stwtype)
int bx, by;
int macroblock_type;
int motion_type;
int PMV[2][2][2], motion_vertical_field_select[2][2], dmvector[2];
int stwtype;
{
  int currentfield;
  unsigned char **predframe;
  int DMV[2][2];
  int stwtop, stwbot;

#ifdef TRACE

  char mc_descript[10];
  int mc_1_dst_field;
  int mc_1_fwd_valid;
  int mc_1_fwd_src_field;
  int mc_1_fwd_mv_x;
  int mc_1_fwd_mv_y;
  int mc_1_bwd_valid;
  int mc_1_bwd_src_field;
  int mc_1_bwd_mv_x;
  int mc_1_bwd_mv_y;
  int mc_2_dst_field;
  int mc_2_fwd_valid;
  int mc_2_fwd_src_field;
  int mc_2_fwd_mv_x;
  int mc_2_fwd_mv_y;
  int mc_2_bwd_valid;
  int mc_2_bwd_src_field;
  int mc_2_bwd_mv_x;
  int mc_2_bwd_mv_y;

  strcpy(mc_descript, "MC_NONE");

  mc_1_dst_field = 0;
  mc_1_fwd_valid = 0;
  mc_1_fwd_src_field = 0;
  mc_1_fwd_mv_x = 0;
  mc_1_fwd_mv_y = 0;

  mc_1_bwd_valid = 0;
  mc_1_bwd_src_field = 0;
  mc_1_bwd_mv_x = 0;
  mc_1_bwd_mv_y = 0;

  mc_2_dst_field = 0;
  mc_2_fwd_valid = 0;
  mc_2_fwd_src_field = 0;
  mc_2_fwd_mv_x = 0;
  mc_2_fwd_mv_y = 0;

  mc_2_bwd_valid = 0;
  mc_2_bwd_src_field = 0;
  mc_2_bwd_mv_x = 0;
  mc_2_bwd_mv_y = 0;
#endif

  stwtop = stwtype%3; /* 0:temporal, 1:(spat+temp)/2, 2:spatial */
  stwbot = stwtype/3;

  if ((macroblock_type & MACROBLOCK_MOTION_FORWARD) 
   || (picture_coding_type==P_TYPE))
  {
    if (picture_structure==FRAME_PICTURE)
    {
      if ((motion_type==MC_FRAME) 
        || !(macroblock_type & MACROBLOCK_MOTION_FORWARD))
      {
        /* frame-based prediction (broken into top and bottom halves
             for spatial scalability prediction purposes) */
        if (stwtop<2)
          form_prediction(forward_reference_frame,0,current_frame,0,
            Coded_Picture_Width,Coded_Picture_Width<<1,16,8,bx,by,
            PMV[0][0][0],PMV[0][0][1],stwtop);

        if (stwbot<2)
          form_prediction(forward_reference_frame,1,current_frame,1,
            Coded_Picture_Width,Coded_Picture_Width<<1,16,8,bx,by,
            PMV[0][0][0],PMV[0][0][1],stwbot);

#ifdef TRACE
       strcpy(mc_descript, "MC_FRAME");

       mc_1_dst_field = 0;
       mc_1_fwd_valid = 1;
       mc_1_fwd_src_field = 0;
       mc_1_fwd_mv_x = PMV[0][0][0];
       mc_1_fwd_mv_y = PMV[0][0][1];

       mc_2_dst_field = 1;
       mc_2_fwd_valid = 1;
       mc_2_fwd_src_field = 1;
       mc_2_fwd_mv_x = PMV[0][0][0];
       mc_2_fwd_mv_y = PMV[0][0][1];
#endif
      }
      else if (motion_type==MC_FIELD) /* field-based prediction */
      {
        /* top field prediction */
        if (stwtop<2)
          form_prediction(forward_reference_frame,motion_vertical_field_select[0][0],
            current_frame,0,Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,
            bx,by>>1,PMV[0][0][0],PMV[0][0][1]>>1,stwtop);

        /* bottom field prediction */
        if (stwbot<2)
          form_prediction(forward_reference_frame,motion_vertical_field_select[1][0],
            current_frame,1,Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,
            bx,by>>1,PMV[1][0][0],PMV[1][0][1]>>1,stwbot);

#ifdef TRACE
       strcpy(mc_descript, "MC_FIELD");

       mc_1_dst_field = 0;
       mc_1_fwd_valid = 1;
       mc_1_fwd_src_field = motion_vertical_field_select[0][0];
       mc_1_fwd_mv_x = PMV[0][0][0];
       mc_1_fwd_mv_y = PMV[0][0][1]>>1;

       mc_2_dst_field = 1;
       mc_2_fwd_valid = 1;
       mc_2_fwd_src_field = motion_vertical_field_select[1][0];
       mc_2_fwd_mv_x = PMV[1][0][0];
       mc_2_fwd_mv_y = PMV[1][0][1]>>1;
#endif
      }
      else if (motion_type==MC_DMV) /* dual prime prediction */
      {
        /* calculate derived motion vectors */
        Dual_Prime_Arithmetic(DMV,dmvector,PMV[0][0][0],PMV[0][0][1]>>1);

        if (stwtop<2)
        {
          /* predict top field from top field */
          form_prediction(forward_reference_frame,0,current_frame,0,
            Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,bx,by>>1,
            PMV[0][0][0],PMV[0][0][1]>>1,0);

          /* predict and add to top field from bottom field */
          form_prediction(forward_reference_frame,1,current_frame,0,
            Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,bx,by>>1,
            DMV[0][0],DMV[0][1],1);
        }

        if (stwbot<2)
        {
          /* predict bottom field from bottom field */
          form_prediction(forward_reference_frame,1,current_frame,1,
            Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,bx,by>>1,
            PMV[0][0][0],PMV[0][0][1]>>1,0);

          /* predict and add to bottom field from top field */
          form_prediction(forward_reference_frame,0,current_frame,1,
            Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,bx,by>>1,
            DMV[1][0],DMV[1][1],1);
        }

#ifdef TRACE
       strcpy(mc_descript, "MC_DMV");

       mc_1_dst_field = 0;
       mc_1_fwd_valid = 1;
       mc_1_fwd_src_field = 0;
       mc_1_fwd_mv_x = PMV[0][0][0];
       mc_1_fwd_mv_y = PMV[0][0][1]>>1;

       mc_1_bwd_valid = 1;
       mc_1_bwd_src_field = 1;
       mc_1_bwd_mv_x = DMV[0][0];
       mc_1_bwd_mv_y = DMV[0][1];

       mc_2_dst_field = 1;
       mc_2_fwd_valid = 1;
       mc_2_fwd_src_field = 1;
       mc_2_fwd_mv_x = PMV[0][0][0];
       mc_2_fwd_mv_y = PMV[0][0][1]>>1;

       mc_2_bwd_valid = 1;
       mc_2_bwd_src_field = 0;
       mc_2_bwd_mv_x = DMV[1][0];
       mc_2_bwd_mv_y = DMV[1][1];
#endif
      }
      else
      {
        /* invalid motion_type */
        printf("invalid motion_type\n");
#ifdef TRACE
       strcpy(mc_descript, "MC_ERR");
#endif
      }
    }
    else /* TOP_FIELD or BOTTOM_FIELD */
    {
      /* field picture */
      currentfield = (picture_structure==BOTTOM_FIELD);

      /* determine which frame to use for prediction */
      if ((picture_coding_type==P_TYPE) && Second_Field
         && (currentfield!=motion_vertical_field_select[0][0]))
        predframe = backward_reference_frame; /* same frame */
      else
        predframe = forward_reference_frame; /* previous frame */

      if ((motion_type==MC_FIELD)
        || !(macroblock_type & MACROBLOCK_MOTION_FORWARD))
      {
        /* field-based prediction */
        if (stwtop<2)
          form_prediction(predframe,motion_vertical_field_select[0][0],current_frame,0,
            Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,16,bx,by,
            PMV[0][0][0],PMV[0][0][1],stwtop);

#ifdef TRACE
       strcpy(mc_descript, "MC_FIELD");

       mc_1_dst_field = currentfield;
       mc_1_fwd_valid = 1;
       mc_1_fwd_src_field = motion_vertical_field_select[0][0];
       mc_1_fwd_mv_x = PMV[0][0][0];
       mc_1_fwd_mv_y = PMV[0][0][1];
#endif
      }
      else if (motion_type==MC_16X8)
      {
        if (stwtop<2)
        {
          form_prediction(predframe,motion_vertical_field_select[0][0],current_frame,0,
            Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,bx,by,
            PMV[0][0][0],PMV[0][0][1],stwtop);

          /* determine which frame to use for lower half prediction */
          if ((picture_coding_type==P_TYPE) && Second_Field
             && (currentfield!=motion_vertical_field_select[1][0]))
            predframe = backward_reference_frame; /* same frame */
          else
            predframe = forward_reference_frame; /* previous frame */

          form_prediction(predframe,motion_vertical_field_select[1][0],current_frame,0,
            Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,bx,by+8,
            PMV[1][0][0],PMV[1][0][1],stwtop);
        }

#ifdef TRACE
       strcpy(mc_descript, "MC_16X8");

       mc_1_dst_field = currentfield;
       mc_1_fwd_valid = 1;
       mc_1_fwd_src_field = motion_vertical_field_select[0][0];
       mc_1_fwd_mv_x = PMV[0][0][0];
       mc_1_fwd_mv_y = PMV[0][0][1];

       mc_1_bwd_valid = 1;
       mc_1_bwd_src_field = motion_vertical_field_select[1][0];
       mc_1_bwd_mv_x = PMV[1][0][0];
       mc_1_bwd_mv_y = PMV[1][0][1];
#endif
      }
      else if (motion_type==MC_DMV) /* dual prime prediction */
      {
        if (Second_Field)
          predframe = backward_reference_frame; /* same frame */
        else
          predframe = forward_reference_frame; /* previous frame */

        /* calculate derived motion vectors */
        Dual_Prime_Arithmetic(DMV,dmvector,PMV[0][0][0],PMV[0][0][1]);

        /* predict from field of same parity */
        form_prediction(forward_reference_frame,currentfield,current_frame,0,
          Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,16,bx,by,
          PMV[0][0][0],PMV[0][0][1],0);

        /* predict from field of opposite parity */
        form_prediction(predframe,!currentfield,current_frame,0,
          Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,16,bx,by,
          DMV[0][0],DMV[0][1],1);

#ifdef TRACE
       strcpy(mc_descript, "MC_DMV");

       mc_1_dst_field = currentfield;
       mc_1_fwd_valid = 1;
       mc_1_fwd_src_field = currentfield;
       mc_1_fwd_mv_x = PMV[0][0][0];
       mc_1_fwd_mv_y = PMV[0][0][1];

       mc_1_bwd_valid = 1;
       mc_1_bwd_src_field = !currentfield;
       mc_1_bwd_mv_x = DMV[0][0];
       mc_1_bwd_mv_y = DMV[0][1];
#endif
      }
      else
      {
        /* invalid motion_type */
        printf("invalid motion_type\n");
#ifdef TRACE
       strcpy(mc_descript, "MC_ERR");
#endif
      }
    }
    stwtop = stwbot = 1;
  }

  if (macroblock_type & MACROBLOCK_MOTION_BACKWARD)
  {
    if (picture_structure==FRAME_PICTURE)
    {
      if (motion_type==MC_FRAME)
      {
        /* frame-based prediction */
        if (stwtop<2)
          form_prediction(backward_reference_frame,0,current_frame,0,
            Coded_Picture_Width,Coded_Picture_Width<<1,16,8,bx,by,
            PMV[0][1][0],PMV[0][1][1],stwtop);

        if (stwbot<2)
          form_prediction(backward_reference_frame,1,current_frame,1,
            Coded_Picture_Width,Coded_Picture_Width<<1,16,8,bx,by,
            PMV[0][1][0],PMV[0][1][1],stwbot);

#ifdef TRACE
       strcpy(mc_descript, "MC_FRAME");

       mc_1_dst_field = 0;

       mc_1_bwd_valid = 1;
       mc_1_bwd_src_field = 0;
       mc_1_bwd_mv_x = PMV[0][1][0];
       mc_1_bwd_mv_y = PMV[0][1][1];

       mc_2_dst_field = 1;

       mc_2_bwd_valid = 1;
       mc_2_bwd_src_field = 1;
       mc_2_bwd_mv_x = PMV[0][1][0];
       mc_2_bwd_mv_y = PMV[0][1][1];
#endif
      }
      else /* field-based prediction */
      {
        /* top field prediction */
        if (stwtop<2)
          form_prediction(backward_reference_frame,motion_vertical_field_select[0][1],
            current_frame,0,Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,
            bx,by>>1,PMV[0][1][0],PMV[0][1][1]>>1,stwtop);

        /* bottom field prediction */
        if (stwbot<2)
          form_prediction(backward_reference_frame,motion_vertical_field_select[1][1],
            current_frame,1,Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,
            bx,by>>1,PMV[1][1][0],PMV[1][1][1]>>1,stwbot);

#ifdef TRACE
       strcpy(mc_descript, "MC_FIELD");

       mc_1_dst_field = 0;

       mc_1_bwd_valid = 1;
       mc_1_bwd_src_field = motion_vertical_field_select[0][1];
       mc_1_bwd_mv_x = PMV[0][1][0];
       mc_1_bwd_mv_y = PMV[0][1][1]>>1;

       mc_2_dst_field = 1;

       mc_2_bwd_valid = 1;
       mc_2_bwd_src_field = motion_vertical_field_select[1][1];
       mc_2_bwd_mv_x = PMV[1][1][0];
       mc_2_bwd_mv_y = PMV[1][1][1]>>1;
#endif
      }
    }
    else /* TOP_FIELD or BOTTOM_FIELD */
    {
      /* field picture */
      if (motion_type==MC_FIELD)
      {
        /* field-based prediction */
        form_prediction(backward_reference_frame,motion_vertical_field_select[0][1],
          current_frame,0,Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,16,
          bx,by,PMV[0][1][0],PMV[0][1][1],stwtop);

#ifdef TRACE
       strcpy(mc_descript, "MC_FIELD");

       mc_1_dst_field = currentfield;

       mc_1_bwd_valid = 1;
       mc_1_bwd_src_field = motion_vertical_field_select[0][1];
       mc_1_bwd_mv_x = PMV[0][1][0];
       mc_1_bwd_mv_y = PMV[0][1][1];
#endif
      }
      else if (motion_type==MC_16X8)
      {
        form_prediction(backward_reference_frame,motion_vertical_field_select[0][1],
          current_frame,0,Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,
          bx,by,PMV[0][1][0],PMV[0][1][1],stwtop);

        form_prediction(backward_reference_frame,motion_vertical_field_select[1][1],
          current_frame,0,Coded_Picture_Width<<1,Coded_Picture_Width<<1,16,8,
          bx,by+8,PMV[1][1][0],PMV[1][1][1],stwtop);

#ifdef TRACE
       strcpy(mc_descript, "MC_16X8");

       mc_1_dst_field = currentfield;

       mc_1_bwd_valid = 1;
       mc_1_bwd_src_field = motion_vertical_field_select[0][1];
       mc_1_bwd_mv_x = PMV[0][1][0];
       mc_1_bwd_mv_y = PMV[0][1][1];

       mc_2_dst_field = currentfield;

       mc_2_bwd_valid = 1;
       mc_2_bwd_src_field = motion_vertical_field_select[1][1];
       mc_2_bwd_mv_x = PMV[1][1][0];
       mc_2_bwd_mv_y = PMV[1][1][1];
#endif
      }
      else
      {
        /* invalid motion_type */
        printf("invalid motion_type\n");
#ifdef TRACE
       strcpy(mc_descript, "MC_ERR");
#endif
      }
    }
  }
#ifdef TRACE
  if (Trace_Flag && (mc_1_fwd_valid || mc_1_bwd_valid))
  {
    printf("field %1i %10s", mc_1_dst_field, mc_descript);
    if (mc_1_fwd_valid) printf (" fwd field %1i (%5i, %5i)", mc_1_fwd_src_field, mc_1_fwd_mv_x, mc_1_fwd_mv_y);
    if (mc_1_bwd_valid) printf (" bwd field %1i (%5i, %5i)", mc_1_bwd_src_field, mc_1_bwd_mv_x, mc_1_bwd_mv_y);
    printf("\n");
  }

  if (Trace_Flag && (mc_2_fwd_valid || mc_2_bwd_valid))
  {
    printf("field %1i %10s", mc_2_dst_field, mc_descript);
    if (mc_2_fwd_valid) printf (" fwd field %1i (%5i, %5i)", mc_2_fwd_src_field, mc_2_fwd_mv_x, mc_2_fwd_mv_y);
    if (mc_2_bwd_valid) printf (" bwd field %1i (%5i, %5i)", mc_2_bwd_src_field, mc_2_bwd_mv_x, mc_2_bwd_mv_y);
    printf("\n");
  }
#endif
}

static void form_prediction(src,sfield,dst,dfield,lx,lx2,w,h,x,y,dx,dy,average_flag)
unsigned char *src[]; /* prediction source buffer */
int sfield;           /* prediction source field number (0 or 1) */
unsigned char *dst[]; /* prediction destination buffer */
int dfield;           /* prediction destination field number (0 or 1)*/
int lx,lx2;           /* line strides */
int w,h;              /* prediction block/sub-block width, height */
int x,y;              /* pixel co-ordinates of top-left sample in current MB */
int dx,dy;            /* horizontal, vertical prediction address */
int average_flag;     /* add prediction error to prediction ? */
{
  /* Y */
  form_component_prediction(src[0]+(sfield?lx2>>1:0),dst[0]+(dfield?lx2>>1:0),
    lx,lx2,w,h,x,y,dx,dy,average_flag);

  if (chroma_format!=CHROMA444)
  {
    lx>>=1; lx2>>=1; w>>=1; x>>=1; dx/=2;
  }

  if (chroma_format==CHROMA420)
  {
    h>>=1; y>>=1; dy/=2;
  }

  /* Cb */
  form_component_prediction(src[1]+(sfield?lx2>>1:0),dst[1]+(dfield?lx2>>1:0),
    lx,lx2,w,h,x,y,dx,dy,average_flag);

  /* Cr */
  form_component_prediction(src[2]+(sfield?lx2>>1:0),dst[2]+(dfield?lx2>>1:0),
    lx,lx2,w,h,x,y,dx,dy,average_flag);
}

/* ISO/IEC 13818-2 section 7.6.4: Forming predictions */
/* NOTE: the arithmetic below produces numerically equivalent results
 *  to 7.6.4, yet is more elegant. It differs in the following ways:
 *
 *   1. the vectors (dx, dy) are based on cartesian frame 
 *      coordiantes along a half-pel grid (always positive numbers)
 *      In contrast, vector[r][s][t] are differential (with positive and 
 *      negative values). As a result, deriving the integer vectors 
 *      (int_vec[t]) from dx, dy is accomplished by a simple right shift.
 *
 *   2. Half pel flags (xh, yh) are equivalent to the LSB (Least
 *      Significant Bit) of the half-pel coordinates (dx,dy).
 * 
 *
 *  NOTE: the work of combining predictions (ISO/IEC 13818-2 section 7.6.7)
 *  is distributed among several other stages.  This is accomplished by 
 *  folding line offsets into the source and destination (src,dst)
 *  addresses (note the call arguments to form_prediction() in Predict()),
 *  line stride variables lx and lx2, the block dimension variables (w,h), 
 *  average_flag, and by the very order in which Predict() is called.  
 *  This implementation design (implicitly different than the spec) 
 *  was chosen for its elegance.
*/

static void form_component_prediction(src,dst,lx,lx2,w,h,x,y,dx,dy,average_flag)
unsigned char *src;
unsigned char *dst;
int lx;          /* raster line increment */ 
int lx2;
int w,h;
int x,y;
int dx,dy;
int average_flag;      /* flag that signals bi-directional or Dual-Prime 
                          averaging (7.6.7.1 and 7.6.7.4). if average_flag==1,
                          a previously formed prediction has been stored in 
                          pel_pred[] */
{
  int xint;      /* horizontal integer sample vector: analogous to int_vec[0] */
  int yint;      /* vertical integer sample vectors: analogous to int_vec[1] */
  int xh;        /* horizontal half sample flag: analogous to half_flag[0]  */
  int yh;        /* vertical half sample flag: analogous to half_flag[1]  */
  int i, j, v;
  unsigned char *s;    /* source pointer: analogous to pel_ref[][]   */
  unsigned char *d;    /* destination pointer:  analogous to pel_pred[][]  */

  /* half pel scaling for integer vectors */
  xint = dx>>1;
  yint = dy>>1;

  /* derive half pel flags */
  xh = dx & 1;
  yh = dy & 1;

  /* compute the linear address of pel_ref[][] and pel_pred[][] 
     based on cartesian/raster cordinates provided */
  s = src + lx*(y+yint) + x + xint;
  d = dst + lx*y + x;

#ifdef TRACE_RECON
  if (Trace_Flag)
  {
    printf("form_component_prediction: xint: %i xh: %i yint: %i yh: %i x: %i y: %i s: src+%i d: dst+%i\n", xint, xh, yint, yh, x, y, lx*(y+yint) + x + xint, lx*y + x);
  }
#endif /* TRACE_RECON */

  if (!xh && !yh) /* no horizontal nor vertical half-pel */
  {
    if (average_flag)
    {
      for (j=0; j<h; j++)
      {
        for (i=0; i<w; i++)
        {
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printf("form_component_prediction (1): 0.5 * ( ");
            printPixel(&d[i]); 
            printf(" + ");
            printPixel(&s[i]); 
            printf(" ) ->  ");
          }
#endif /* TRACE_RECON */
          v = d[i]+s[i];
          d[i] = (v+(v>=0?1:0))>>1;
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printPixel(&d[i]); 
            printf("\n"); 
          }
#endif /* TRACE_RECON */
        }
      
        s+= lx2;
        d+= lx2;
      }
    }
    else
    {
      for (j=0; j<h; j++)
      {
        for (i=0; i<w; i++)
        {
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printf("form_component_prediction (2):");
            printPixel(&s[i]); 
            printf(" ->  ");
          }
#endif /* TRACE_RECON */
          d[i] = s[i];
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printPixel(&d[i]); 
            printf("\n");
          }
#endif /* TRACE_RECON */
        }
        
        s+= lx2;
        d+= lx2;
      }
    }
  }
  else if (!xh && yh) /* no horizontal but vertical half-pel */
  {
    if (average_flag)
    {
      for (j=0; j<h; j++)
      {
        for (i=0; i<w; i++)
        {
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printf("form_component_prediction (3): 0.5 * (");
            printPixel(&d[i]); 
            printf(" + 0.5 * (");
            printPixel(&s[i]); 
            printf(" + ");
            printPixel(&s[i+lx+1]); 
            printf(" )) ->  ");
          }
#endif /* TRACE_RECON */
          v = d[i] + ((unsigned int)(s[i]+s[i+lx]+1)>>1);
          d[i]=(v+(v>=0?1:0))>>1;
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printPixel(&d[i]); 
            printf("\n"); 
          }
#endif /* TRACE_RECON */
        }
     
        s+= lx2;
        d+= lx2;
      }
    }
    else
    {
      for (j=0; j<h; j++)
      {
        for (i=0; i<w; i++)
        {
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printf("form_component_prediction (4): 0.5 * (");
            printPixel(&s[i]); 
            printf(" + ");
            printPixel(&s[i+lx]); 
            printf(") ->  ");
          }
#endif /* TRACE_RECON */
          d[i] = (unsigned int)(s[i]+s[i+lx]+1)>>1;
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printPixel(&d[i]); 
            printf("\n"); 
          }
#endif /* TRACE_RECON */
        }

        s+= lx2;
        d+= lx2;
      }
    }
  }
  else if (xh && !yh) /* horizontal but no vertical half-pel */
  {
    if (average_flag)
    {
      for (j=0; j<h; j++)
      {
        for (i=0; i<w; i++)
        {
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printf("form_component_prediction (5): 0.5 * (");
            printPixel(&d[i]); 
            printf(" + 0.5 * (");
            printPixel(&s[i]); 
            printf(" + ");
            printPixel(&s[i+1]); 
            printf(")) ->  ");
          }
#endif /* TRACE_RECON */
          v = d[i] + ((unsigned int)(s[i]+s[i+1]+1)>>1);
          d[i] = (v+(v>=0?1:0))>>1;
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printPixel(&d[i]); 
            printf("\n");
          }
#endif /* TRACE_RECON */
        }
     
        s+= lx2;
        d+= lx2;
      }
    }
    else
    {
      for (j=0; j<h; j++)
      {
        for (i=0; i<w; i++)
        {
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printf("form_component_prediction (6): 0.5 * (");
            printPixel(&s[i]); 
            printf(" + ");
            printPixel(&s[i+1]); 
            printf(") ->  ");
          }
#endif /* TRACE_RECON */
          d[i] = (unsigned int)(s[i]+s[i+1]+1)>>1;
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printPixel(&d[i]); 
            printf("\n");
          }
#endif /* TRACE_RECON */
        }

        s+= lx2;
        d+= lx2;
      }
    }
  }
  else /* if (xh && yh) horizontal and vertical half-pel */
  {
    if (average_flag)
    {
      for (j=0; j<h; j++)
      {
        for (i=0; i<w; i++)
        {
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printf("form_component_prediction (7): 0.5 * (");
            printPixel(&d[i]); 
            printf(" + 0.25 * (");
            printPixel(&s[i]); 
            printf(" + ");
            printPixel(&s[i+1]); 
            printf(" + ");
            printPixel(&s[i+lx]); 
            printf(" + ");
            printPixel(&s[i+lx+1]); 
            printf(")) -> ");
          }
#endif /* TRACE_RECON */
          v = d[i] + ((unsigned int)(s[i]+s[i+1]+s[i+lx]+s[i+lx+1]+2)>>2);
          d[i] = (v+(v>=0?1:0))>>1;
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printPixel(&d[i]); 
            printf("\n"); 
          }
#endif /* TRACE_RECON */
        }
     
        s+= lx2;
        d+= lx2;
      }
    }
    else
    {
      for (j=0; j<h; j++)
      {
        for (i=0; i<w; i++)
        {
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printf("form_component_prediction (8): 0.25 * (");
            printPixel(&s[i]); 
            printf(" + ");
            printPixel(&s[i+1]); 
            printf(" + ");
            printPixel(&s[i+lx]); 
            printf(" + ");
            printPixel(&s[i+lx+1]); 
            printf(") -> ");
          }
#endif /* TRACE_RECON */
          d[i] = (unsigned int)(s[i]+s[i+1]+s[i+lx]+s[i+lx+1]+2)>>2;
#ifdef TRACE_RECON
          if (Trace_Flag)
          {
            printPixel(&d[i]); 
            printf("\n");
          }
#endif /* TRACE_RECON */
        }

        s+= lx2;
        d+= lx2;
      }
    }
  }
}
