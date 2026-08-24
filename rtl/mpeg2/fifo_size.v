/* 
 * fifo_size.v
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
 * fifo_size.v
 *
 * Dimensioning of various fifos. Tuning parameters; handle with care.
 *
 * Summary:
 *
 * motcomp  throttles motcomp_addr_gen (via fifos_almost_full) when dst_wr_almost_full || fwd_wr_addr_almost_full || bwd_wr_addr_almost_full .
 * This is tuneable via ADDR_THRESHOLD.
 * ADDR_THRESHOLD has to be big enough to allow motcomp_addr_gen to generate all memory requests for a complete macroblock.
 * 
 * framestore_request stops handling requests from fwd motion compensation when fwd_wr_dta_almost_full
 * framestore_request stops handling requests from bwd motion compensation when bwd_wr_dta_almost_full
 * framestore_request stops handling requests from display when disp_wr_dta_almost_full
 * framestore_request stops handling requests for circular video buffer reads when vbr_wr_almost_full
 * This is tuneable via DTA_THRESHOLD.
 * If memory latency is high, DTA_THRESHOLD should be high as well.
 *
 * framestore_request stops handling requests when mem_req fills up (mem_req_wr_almost_full).
 * This is tuneable via MEM_THRESHOLD.
 *
 * memory controller mem_ctl stops handling requests when memory results fifo almost full (mem_res_wr_almost_full).
 * This is tuneable via MEM_THRESHOLD.
 *
 * framestore_response stops draining memory results fifo mem_res when fwd_wr_dta_full, bwd_wr_dta_full, disp_wr_dta_full or vbr_wr_full.
 *
 * mem_tag fifo size is smaller than mem_req or mem_res; hence the number of
 * memory requests "in flight" - including memory latency - is at most mem_tag fifo size.
 * This allows one to dimension DTA_THRESHOLD: if DTA_THRESHOLD is smaller
 * than mem_tag fifo size, you run the risk of overflowing a data fifo. 
 * Indeed, framestore_request will stop issuing read requests when the data fifo has
 * less than DTA_THRESHOLD space left; but since there may be up to mem_tag
 * fifo size (= 2**MEMTAG_DEPTH) requests already queued for execution, 
 * the pending requests may overflow the data fifo if DTA_THRESHOLD < 2**MEMTAG_DEPTH. 
 * Hence always choose DTA_THRESHOLD > 2**MEMTAG_DEPTH.
 *
 * Remark: fifo sizes in this file are influenced by dual-port ram sizes available in FPGA's, typically 18 or 36 kbit.
 * As such, fifo sizes in this file tend not to be minimal fifo sizes.
 */


/*
 * dct_coeff fifo. 31 bits wide.
 * Run/Length Values fifo from vld. Input for rld.
 */

parameter 
  RLD_DEPTH          = 9'd7, // one 4:2:0 macroblock = 6 blocks at 64 run/length values per block maximum = 384 entries maximum
  RLD_THRESHOLD      = 9'd2,

/*
 * predict_err_fifo. 72 bits wide.
 * Inverse Discrete Cosine Transform Output. Contains prediction error.
 */

  PREDICT_DEPTH      = 9'd8,
  PREDICT_THRESHOLD  = 9'd64, // big enough so 1 macroblock ( 6 blocks @ 8 rows each ) fits.

/*
 * mvec fifo. 206 bits wide.
 * prediction motion vector fifo from vld. Input for motvec.
 */

  MVEC_DEPTH          = 9'd3,
  MVEC_THRESHOLD      = 9'd2,

/*
 * 
 */

  ADDR_DEPTH      = 9'd8,
  ADDR_THRESHOLD  = 9'd8,
  DTA_DEPTH       = 9'd8,
  DTA_THRESHOLD   = 9'd64, 
  MOTCOMP_ADDR_THRESHOLD  = 9'd144, /* enough for motcomp_addrgen to produce all reads necessary to process a complete macroblock 
                                       number of addresses produced by motcomp_addrgen = no. of lumi blocks * lumi_rows * columns + no. of chromi blocks * max. chromi rows * colums = 4 * 9 * 2 + 2 * 10 * 2 = 112 (see motcomp_addrgen) 
                                       number of addresses in the mem_addr pipe: 13 (13 tages, numbered 0 to 12)
                                       together: 112 + 13 = 125. 
                                       144: safety margin, just in case.
                                       */

/* 
 * Circular Video Buffer. vbuf_write_fifo and vbuf_read_fifo are both 64 bits wide.
 * from stream input to getbits.
 */

  VBUF_WR_DEPTH      = DTA_DEPTH,
  VBUF_WR_THRESHOLD  = 9'd128,
  VBUF_RD_DEPTH      = DTA_DEPTH,
  VBUF_RD_THRESHOLD  = 9'd32,

/*
 * fwd_reader. addr fifo is 22 bits wide; data fifo is 64 bits wide.
 * Reads the data for forward motion compensation.
 * Two fifo's: one sending addresses to be read to the frame store;
 * one receiving data read from the frame store.
 */

  FWD_ADDR_DEPTH     = ADDR_DEPTH,
  FWD_ADDR_THRESHOLD = MOTCOMP_ADDR_THRESHOLD,
  FWD_DTA_DEPTH      = DTA_DEPTH,
  FWD_DTA_THRESHOLD  = DTA_THRESHOLD, // less than half of dta fifo size

/*
 * bwd_reader. addr fifo is 22 bits wide; data fifo is 64 bits wide.
 * Reads the data for backward motion compensation.
 * Two fifo's: one sending addresses to be read to the frame store;
 * one receiving data read from the frame store.
 */

  BWD_ADDR_DEPTH     = ADDR_DEPTH,
  BWD_ADDR_THRESHOLD = MOTCOMP_ADDR_THRESHOLD,
  BWD_DTA_DEPTH      = DTA_DEPTH,
  BWD_DTA_THRESHOLD  = DTA_THRESHOLD, 

/*
 * dst_fifo. 35 bits wide.
 * Motion compensation. Queues the addresses where the reconstructed pixels need to be written
 * until prediction error, forward and backward motion compensation data are available.
 */

  DST_DEPTH          = ADDR_DEPTH,
  DST_THRESHOLD      = MOTCOMP_ADDR_THRESHOLD,

/*
 * recon_writer. 86 bits wide.
 * Motion compensation. Writes reconstructed pixels to the frame store.
 */

  RECON_DEPTH        = DTA_DEPTH,
  RECON_THRESHOLD    = DTA_THRESHOLD,

/*
 * disp_reader. addr fifo is 22 bits wide; data fifo is 64 bits wide.
 * Reads pixels from the frame store for displaying.
 * Two fifo's: one sending addresses to be read to the frame store;
 * one receiving data read from the frame store.
 */

  DISP_ADDR_DEPTH    = ADDR_DEPTH,
  DISP_ADDR_THRESHOLD= 9'd32,         // about 8 times RESAMPLE_THRESHOLD
  DISP_DTA_DEPTH     = DTA_DEPTH,     // disp_reader data fifo should never be empty
  DISP_DTA_THRESHOLD = DTA_THRESHOLD, // less than half of dta fifo size.

/*
 * resample_fifo. 3 bits wide.
 * Chroma resampling. Fifo from resample_addr to resample_dta.
 */

  RESAMPLE_DEPTH     = 9'd8,
  RESAMPLE_THRESHOLD = 9'd4,

/*
 * pixel_fifo. 35 bits wide.
 * From the decoding process to the display process
 */

  PIXEL_DEPTH        = 9'd10,
  PIXEL_THRESHOLD    = 9'd32,

/*
 * osd_writer. 86 bits wide.
 * On-Screen Display. Writes on-screen display to the frame store.
 */

  OSD_DEPTH          = 9'd5,
  OSD_THRESHOLD      = 9'd8,

/*
 * threshold to make framestore_request stop writing before mem_request_fifo, mem_tag_fifo or mem_response_fifo overflow.
 */

  MEM_THRESHOLD      = 9'd16,

/*
 * mem_request_fifo. 88 bits wide.
 * Memory subsystem. Sends read, write and refresh commands to the memory controller.
 */

  MEMREQ_DEPTH      = 9'd6,
  MEMREQ_THRESHOLD  = MEM_THRESHOLD,

/*
 * mem_tag_fifo. 3 bits wide.
 * Memory subsystem. Queues tags of read commands sent to the memory controller.
 */

  MEMTAG_DEPTH      = 9'd5,
  MEMTAG_THRESHOLD  = MEM_THRESHOLD,

/*
 * mem_response_fifo. 64 bits wide.
 * Memory subsystem. Receives data read from the memory controller.
 */

  MEMRESP_DEPTH     = 9'd7,
  MEMRESP_THRESHOLD = 9'd64;

/* not truncated */
