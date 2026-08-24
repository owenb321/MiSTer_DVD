/* 
 * vld_codes.v
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
 * vld_codes - parameters passed from vld to other modules.
 */

  parameter [1:0] /* chroma_format */
    CHROMA420     = 2'd1,
    CHROMA422     = 2'd2,
    CHROMA444     = 2'd3;

  parameter [1:0] /* picture structure */
    TOP_FIELD     = 2'd1,
    BOTTOM_FIELD  = 2'd2,
    FRAME_PICTURE = 2'd3;

  parameter [1:0] /* motion_type */
    MC_NONE       = 2'd0,
    MC_FIELD      = 2'd1,
    MC_FRAME      = 2'd2,
    MC_16X8       = 2'd2,
    MC_DMV        = 2'd3;

  parameter [1:0] /* mv_format */
    MV_FIELD      = 2'd0,
    MV_FRAME      = 2'd1;
 
  parameter [2:0] /* picture coding type, table 6-12 */
    I_TYPE        = 3'd1,
    P_TYPE        = 3'd2,
    B_TYPE        = 3'd3,
    D_TYPE        = 3'd4;

  parameter       /* dct_type */
    DCT_FIELD     = 1'd1,
    DCT_FRAME     = 1'd0;

  parameter [1:0] /* rld_cmd */
    RLD_DCT       = 2'd0,
    RLD_QUANT     = 2'd1,
    RLD_NOOP      = 2'd2;

/* not truncated */
