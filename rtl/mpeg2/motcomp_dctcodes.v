/* 
 * motcomp_dctcodes.v
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
  * motcomp_dctcodes - parameters passed from motcomp_addrgen to motcomp_dcttype, indicating how to re-arrange dct blocks 
  */

  parameter [2:0] 
    DCT_C1_PASS                   = 3'd0,  /* 1 8x8 chrominance block,  passthrough */
    DCT_C1_FRAME_TO_TOP_FIELD     = 3'd1,  /* 1 8x8 chrominance block,  convert from frame to field order. First 4 rows top field, then 4 rows bottom field */
    DCT_L4_PASS                   = 3'd2,  /* 4 8x8 luminance blocks, passthrough */
    DCT_L4_TOP_FIELD_TO_FRAME     = 3'd3,  /* 4 8x8 luminance blocks, convert from field to frame order */
    DCT_L4_FRAME_TO_TOP_FIELD     = 3'd4;  /* 4 8x8 luminance blocks, convert from frame to field order. First 8 rows top field, then 8 rows bottom field */

/* not truncated */
