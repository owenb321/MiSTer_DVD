/* 
 * modeline.v
 * 
 * Copyright (c) 2007 Koen De Vleeschauwer. 
 * 
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND 
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE 
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE 
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE 
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL 
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS 
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) 
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY 
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF 
 * SUCH DAMAGE.
 */

/*
 * modeline - Hardcode initial modeline 
 */

`ifndef MODELINE_SIF
`ifndef MODELINE_SIF_INTERL
`ifndef MODELINE_PAL_INTERL
`ifndef MODELINE_PAL_PROGR
`ifndef MODELINE_HDTV_INTERL
`ifndef MODELINE_VGA
`define MODELINE_SVGA 1
`endif
`endif
`endif
`endif
`endif
`endif

// XXX check values

`ifdef MODELINE_SVGA

  /*
   * modeline: SVGA (synthesis default)
   * The default dot clock of 40.0 Mhz is set in dotclock.v
   */

  parameter [11:0]
    HORZ_RES       = 799,
    HORZ_SYNC_STRT = 839,
    HORZ_SYNC_END  = 967,
    HORZ_LEN       = 1055,
    VERT_RES       = 599,
    VERT_SYNC_STRT = 600,
    VERT_SYNC_END  = 604,
    VERT_LEN       = 627,
    HALFLINE       = 528;

  parameter [2:0]
    VID_MODE       = 3'b000;
`endif

`ifdef MODELINE_VGA

  /*
   * modeline: VGA
   * ModeLine "640x480"    25.2  640  656  752  800    480  490  492  525 -hsync -vsync # 640x480 @ 60Hz (Industry standard) hsync: 31.5kHz dotclock: 25.2 MHz
   */

  parameter [11:0]
    HORZ_RES       = 639,
    HORZ_SYNC_STRT = 655,
    HORZ_SYNC_END  = 751,
    HORZ_LEN       = 799,
    VERT_RES       = 479,
    VERT_SYNC_STRT = 489,
    VERT_SYNC_END  = 491,
    VERT_LEN       = 524,
    HALFLINE       = 0;

  parameter [2:0]
    VID_MODE       = 3'b000; // = {clip_display_size, pixel_repetition, interlaced}
`endif

`ifdef MODELINE_SIF
  // test
  parameter [11:0]
    HORZ_RES       = 352,
    HORZ_SYNC_STRT = 381,
    HORZ_SYNC_END  = 388,
    HORZ_LEN       = 458,
    VERT_RES       = 288,
    VERT_SYNC_STRT = 295,
    VERT_SYNC_END  = 298,
    VERT_LEN       = 315,
    HALFLINE       = 0;

  parameter [2:0]
    VID_MODE       = 3'b000;
`endif

`ifdef MODELINE_SIF_INTERL
  // test
  parameter [11:0]
    HORZ_RES       = 352,
    HORZ_SYNC_STRT = 381,
    HORZ_SYNC_END  = 388,
    HORZ_LEN       = 458,
    VERT_RES       = 144,
    VERT_SYNC_STRT = 147,
    VERT_SYNC_END  = 149,
    VERT_LEN       = 157,
    HALFLINE       = 175;

  parameter [2:0]
    VID_MODE       = 3'b001;
`endif

`ifdef MODELINE_PAL_PROGR
  // PAL 768x576 progressive
  parameter [11:0]
    HORZ_RES       = 768,
    HORZ_SYNC_STRT = 789,
    HORZ_SYNC_END  = 858,
    HORZ_LEN       = 944,
    VERT_RES       = 576,
    VERT_SYNC_STRT = 581,
    VERT_SYNC_END  = 586,
    VERT_LEN       = 625,
    HALFLINE       = 383;

  parameter [2:0]
    VID_MODE       = 3'b000;
`endif

`ifdef MODELINE_PAL_INTERL
  // PAL 768x576 interlaced
  parameter [11:0]
    HORZ_RES       = 768,
    HORZ_SYNC_STRT = 789,
    HORZ_SYNC_END  = 858,
    HORZ_LEN       = 944,
    VERT_RES       = 288,
    VERT_SYNC_STRT = 291,
    VERT_SYNC_END  = 293,
    VERT_LEN       = 313,
    HALFLINE       = 383;

  parameter [2:0]
//    VID_MODE       = 3'b011;
    VID_MODE       = 3'b001;
`endif

`ifdef MODELINE_HDTV_INTERL
  // 1920x1080 interlaced
  parameter [11:0]
    HORZ_RES       = 1919,
    HORZ_SYNC_STRT = 1960,
    HORZ_SYNC_END  = 2016,
    HORZ_LEN       = 2199,
    VERT_RES       = 539,
    VERT_SYNC_STRT = 541,
    VERT_SYNC_END  = 544,
    VERT_LEN       = 562,
    HALFLINE       = 959;

  parameter [2:0]
    VID_MODE       = 3'b001;
`endif

/* not truncated */
