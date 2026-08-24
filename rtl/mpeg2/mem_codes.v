/* 
 * mem_codes.v
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
 * Memory controller commands.
 */
  parameter [1:0]
    CMD_NOOP       = 2'b00,  // no operation
    CMD_REFRESH    = 2'b01,  // refresh memory
    CMD_READ       = 2'b10,  // read 64-bit word
    CMD_WRITE      = 2'b11;  // write 64-bit word

  /*
   * When submitting a memory request to the memory controller, a 'tag' is added, indicating the memory request source. 
   * This allows us to route the data read back to the port which originated the request. 
   *
   * Tags used:
   *   TAG_CTRL   Request from the memory controller. Used when initializing or refreshing DRAM.
   *   TAG_FWD    Request from motion compensation. Read request for forward reference frame.
   *   TAG_BWD    Request from motion compensation. Read request for backward reference frame.
   *   TAG_RECON  Request from motion compensation. Write request for reconstructed frame.
   *   TAG_DISP   Request from chroma resampling. Read request for reconstructed frame.
   *   TAG_OSD    Request from register file. Write request for on-screen display.
   */

  parameter [2:0]
    TAG_CTRL  = 3'd0,
    TAG_FWD   = 3'd1,
    TAG_BWD   = 3'd2,
    TAG_RECON = 3'd3,
    TAG_DISP  = 3'd4,
    TAG_OSD   = 3'd5,
    TAG_VBUF  = 3'd6;

/*
 * Frame store layout. 
 * 
 * Writing to and reading from the framestore uses 22-bit frame store addresses.
 * Each address uniquely identifies an 8-pixel row of luminance or chrominance values in a block.
 * 
 *   chroma_format: (CHROMA420, CHROMA422, or CHROMA444)
 *   image width is mb_width macroblocks, height is mb_height macroblocks.
 * 
 *   4:2:0 frame: (CHROMA420)
 *        mb_width              
 *   +---------------+       
 *   |               |          
 *   |      Y        | mb_height
 *   |               |
 *   | mb_width/2    |
 *   +-------+-------+
 *   |  Cb   | 
 *   |       | mb_height/2
 *   +-------+
 *   |  Cr   | 
 *   |       | mb_height/2
 *   +-------+
 * 
 *   Macroblocks in memory. 
 *   Each number represents a block row.
 *   A block row is a 64-bit word, consisting of 8 8-bit luminance or chrominance values of 8 consecutive pixels.
 * 
 *   +MB 0 ------------+MB 1 ------------+MB 2 -----------
 *   |      0      1   |      0      1   |      0      1 
 *   |      2      3   |      2      3   |      2      3 
 *   |      4      5   |      4      5   |      4      5 
 *   |      6      7   |      6      7   |      6      7 
 *   |      8      9   |      8      9   |      8      9 
 *   |     10     11   |     10     11   |     10     11 
 *   |     12     13   |     12     13   |     12     13 
 *   |     14     15   |     14     15   |     14     15 
 *   |     16     17   |     16     17   |     16     17 
 *   |     18     19   |     18     19   |     18     19 
 *   |     20     21   |     20     21   |     20     21 
 *   |     22     23   |     22     23   |     22     23 
 *   |     24     25   |     24     25   |     24     25 
 *   |     26     27   |     26     27   |     26     27 
 *   |     28     29   |     28     29   |     28     29 
 *   |     30     31   |     30     31   |     30     31 
 *   +MB mb_width -----+MB mb_width+1 ---+MB mb_width+2 --
 *   |      0      1   |      0      1   |      0      1 
 *   |      2      3   |      2      3   |      2      3 
 *   |      4      5   |      4      5   |      4      5 
 *   |      6      7   |      6      7   |      6      7 
 *   |      8      9   |      8      9   |      8      9 
 *   |     10     11   |     10     11   |     10     11 
 *   |     12     13   |     12     13   |     12     13 
 *   |     14     15   |     14     15   |     14     15 
 *   |     16     17   |     16     17   |     16     17 
 *   |     18     19   |     18     19   |     18     19 
 *   |     20     21   |     20     21   |     20     21 
 *   |     22     23   |     22     23   |     22     23 
 *   |     24     25   |     24     25   |     24     25 
 *   |     26     27   |     26     27   |     26     27 
 *   |     28     29   |     28     29   |     28     29 
 *   |     30     31   |     30     31   |     30     31 
 *   +MB 2*mb_width ---+MB 2*mb_width+1 -+MB 2*mb_width+2 -
 *   |      0      1   |      0      1   |      0      1 
 *   |      2      3   |      2      3   |      2      3 
 *   |      4      5   |      4      5   |      4      5 
 *   |      6      7   |      6      7   |      6      7 
 *   |      8      9   |      8      9   |      8      9 
 *   |     10     11   |     10     11   |     10     11 
 *   |     12     13   |     12     13   |     12     13 
 *   |     14     15   |     14     15   |     14     15 
 *   |     16     17   |     16     17   |     16     17 
 *   |     18     19   |     18     19   |     18     19 
 *   |     20     21   |     20     21   |     20     21 
 *   |     22     23   |     22     23   |     22     23 
 *   |     24     25   |     24     25   |     24     25 
 *   |     26     27   |     26     27   |     26     27 
 *   |     28     29   |     28     29   |     28     29 
 *   |     30     31   |     30     31   |     30     31 
 * 
 *   Blocks within a macroblock. 
 *   Each digit represents an 8-bit luminance or chrominance value.
 * 
 *   +block0--+block1--+
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   +block2--+block3--+
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   |01234567|01234567|
 *   +--------+--------+
 * 
 *   Rows within a block.
 * 
 *   +block0--+
 *   |01234567| row 0
 *   |01234567| row 1
 *   |01234567| row 2
 *   |01234567| row 3
 *   |01234567| row 4
 *   |01234567| row 5
 *   |01234567| row 6
 *   |01234567| row 7
 *   +--------+
 * 
 * To calculate a block row's address in memory, use memory_address().
 *
 */

  parameter [1:0]
    COMP_Y       = 2'b00,  // Y operation
    COMP_CR      = 2'b01,  // Cr
    COMP_CB      = 2'b10;  // Cb

// Uncomment next line for HDTV memory mapping
`define MP_AT_HL 1
`ifdef MP_AT_HL
/*
 * Memory mapping.
 *
 * This memory mapping is sufficient for up to MP@HL, 1920x1088 pixels, 4:2:0. Requires 15 mbyte ram.
 * Consists of four frames, on-screen display and video buffer.
 * Note that as the vbuf_wr_addr and vbuf_rd_addr counters are 18 bit, VBUF needs to end in 18 zeroes binary. eg. VBUF = 22'h1c0000 is ok, 22'h1d0000 isn't.
 * 
 */

  parameter [21:0]
    WIDTH_Y         = 22'd18,     // Luminance size = 2 ** WIDTH_Y. 2 mbyte of 8-byte words.
    WIDTH_C         = 22'd16,     // Chrominance size = 2 ** WIDTH_C. 512 kbyte of 8-byte words.
    VBUF            = 22'h1c0000, // Table E-23: MP@HL: vbv buffer size is 9781248 bits.
    VBUF_END        = 22'h1efffe,
    ADDR_ERR        = 22'h1effff; // Error address; used to signal overflow. (eg. macroblock address too large, or motion vector outside frame). Points to somewhere harmless.

`else

/*
 * Memory mapping.
 *
 * This memory mapping is sufficient for up to MP@ML, up to 768x576 pixels SDTV, 4:2:0. Requires 4 mbyte ram.
 * Consists of four frames, on-screen display and video buffer.
 */

  parameter [21:0]
    WIDTH_Y         = 22'd16,     // Luminance size = 2 ** WIDTH_Y. 512 kbyte of 8-byte words
    WIDTH_C         = 22'd14,     // Chrominance size = 2 ** WIDTH_C. 128 kbyte of 8-byte words
    VBUF            = 22'h070000, // Table E-23: MP@ML: vbv buffer size is 1835008 bits.
    VBUF_END        = 22'h077ffe,
    ADDR_ERR        = 22'h077fff; // Error address; used to signal overflow. (eg. macroblock address too large, or motion vector outside frame). Points to somewhere harmless.

`endif

  parameter [21:0]
    FRAME_0_Y       = 22'h000000,
    FRAME_0_CR      =                                           (22'h1 << WIDTH_Y),
    FRAME_0_CB      =                                           (22'h1 << WIDTH_Y) + (22'h1 << WIDTH_C),
    FRAME_1_Y       = (22'h1 << WIDTH_Y) + (22'h2 << WIDTH_C),
    FRAME_1_CR      = (22'h1 << WIDTH_Y) + (22'h2 << WIDTH_C) + (22'h1 << WIDTH_Y),
    FRAME_1_CB      = (22'h1 << WIDTH_Y) + (22'h2 << WIDTH_C) + (22'h1 << WIDTH_Y) + (22'h1 << WIDTH_C),
    FRAME_2_Y       = (22'h2 << WIDTH_Y) + (22'h4 << WIDTH_C),
    FRAME_2_CR      = (22'h2 << WIDTH_Y) + (22'h4 << WIDTH_C) + (22'h1 << WIDTH_Y),
    FRAME_2_CB      = (22'h2 << WIDTH_Y) + (22'h4 << WIDTH_C) + (22'h1 << WIDTH_Y) + (22'h1 << WIDTH_C),
    FRAME_3_Y       = (22'h3 << WIDTH_Y) + (22'h6 << WIDTH_C),
    FRAME_3_CR      = (22'h3 << WIDTH_Y) + (22'h6 << WIDTH_C) + (22'h1 << WIDTH_Y),
    FRAME_3_CB      = (22'h3 << WIDTH_Y) + (22'h6 << WIDTH_C) + (22'h1 << WIDTH_Y) + (22'h1 << WIDTH_C),
    OSD             = (22'h4 << WIDTH_Y) + (22'h8 << WIDTH_C);

  parameter [2:0]
    OSD_FRAME       = 3'd4;

  parameter [21:0]
    END_OF_MEM      = ADDR_ERR;   // End of memory.

/* not truncated */
