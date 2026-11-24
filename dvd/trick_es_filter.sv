// =============================================================================
// dvd/trick_es_filter.sv -- trick play's video ES filter (docs/trick_play.md)
// =============================================================================
// In trick play the reader fetches only [nv_pck .. nv_pck + vobu_1stref_ea] of each
// VOBU and splices those reads into one stream. 1stref_ea is a SECTOR, so each read
// ends with the start of whatever follows the reference picture, usually a partial
// B-picture (measured: 99.6 % of 56,401 VOBUs). Fed to the decoder unfiltered, the
// stream decodes as garbage (bench/dvd/run_trick_decode.sh [R1]: the vld raises
// `error`). This module keeps exactly the reference frame of each read:
//
//   * drop until a sequence header (00 00 01 B3);
//   * pass from it through the end of the first picture: one frame picture, or two
//     field pictures when the first is field-structured (picture_coding_extension
//     picture_structure != 3; MPEG-1 has no extension and is always a frame);
//   * cut at the next picture start code (00 00 01 00), recognised from its 4 bytes
//     alone, and drop until the next sequence header;
//   * a first picture that is not an I-picture: drop it, count it (skip_n);
//   * a read that ends with a dangling `00 00 01`: the next read starts `00 00 01 B3`,
//     so the wire carries `00 00 01 00 00 01 B3`. The first four bytes ARE a picture
//     start code and cut, and the code's last byte is held as the first byte of the
//     sequence header. In a valid ES `00 00 01 00 00 01` cannot occur (it would be
//     picture_coding_type 0, forbidden), so holding that byte is always safe.
//
// This is tools/trick_splice.py's es_filter, streamed. The gate is byte-exactness
// against that model on real discs plus synthetic streams for the cases the library
// never shows (bench/dvd/run_trick_es_filter.sh).
//
// HOW IT STREAMS. A byte's fate is final once no future byte can change it. Only
// bytes that might begin a start code (a suffix that is a prefix of 00 00 01) are
// held, plus, for the first picture's code, the two header bytes that carry
// picture_coding_type. So at most 6 bytes are ever held (hb), and a byte that cannot
// begin a start code leaves at once: the last bytes of a picture never wait for the
// next read (that would hold a whole frame for one cadence period).
//
// RATE. In trick play one input byte is taken when no decided byte is waiting, so
// the filter moves at most one byte every two cycles (13.5 MB/s at clk_sys): ample,
// a trick-play read is ~0.5 MB/s. With en = 0 it is a wire: in -> out, combinational,
// state held in reset.
//
// Visibility (CLAUDE.md "never truncate silently"): skip_n counts VOBUs whose first
// picture was not an I-picture, pair_n counts field pairs passed. Neither occurs in
// the 150-disc sweep; both are spec-legal.
// =============================================================================
`default_nettype none
module trick_es_filter (
    input  wire       clk,            // clk_sys
    input  wire       rst_n,          // pipe reset: a seek or trick entry restarts the hunt
    input  wire       en,             // trick play active; 0 = transparent

    input  wire [7:0] in_byte,        // <- ps_demux vid_*
    input  wire       in_mark,
    input  wire       in_valid,
    output wire       in_ready,

    output wire [7:0] out_byte,       // -> es_stuff in_*
    output wire       out_mark,
    output wire       out_valid,
    input  wire       out_ready,

    output reg  [15:0] skip_n,        // first picture of a read was not an I-picture
    output reg  [15:0] pair_n         // field pairs passed
);
    localparam [1:0] S_HUNT = 2'd0, S_PASS = 2'd1, S_PCT = 2'd2;

    reg [47:0] hb;                    // held bytes, byte k = hb[8k +: 8], oldest = byte 0
    reg  [5:0] hm;                    // their PTS marks
    reg  [5:0] hk;                    // keep flag (meaningful for decided bytes only)
    reg  [2:0] hl;                    // bytes held
    reg  [2:0] hd;                    // of which decided: always the oldest hd
    reg  [1:0] st;
    reg  [1:0] npic;                  // pictures of this read passed (0, 1, 2)
    reg        fld;                   // the first picture is field-structured
    reg  [1:0] ecnt;                  // picture_coding_extension byte tracker

    // ---- output: the oldest decided byte ------------------------------------------
    wire emit = en && (hd != 3'd0);
    assign out_byte  = en ? hb[7:0] : in_byte;
    assign out_mark  = en ? hm[0] : in_mark;
    assign out_valid = en ? (emit && hk[0]) : in_valid;
    wire   pop       = emit && (!hk[0] || out_ready);
    assign in_ready  = en ? (hd == 3'd0) : out_ready;
    wire   take      = en && in_valid && (hd == 3'd0);

    // ---- resolve: append the new byte, decide what can be decided -----------------
    // Packed vectors throughout: Icarus runs unpacked arrays written through a variable
    // index ~10x slower, and the real-disc gate streams tens of MB.
    reg [47:0] a;
    reg  [5:0] am, ak;
    reg  [7:0] z, o;                  // a[k]==00 / a[k]==01; bits 6-7 stay 0 (the scan's
                                      // i+1 / i+2 reach them: Quartus error 10232 at 6 bits)
    reg  [2:0] L, nd, base, cut;
    reg  [1:0] nst, nnpic;
    reg        nfld, keep_now, skip_inc, pair_inc, reduce, sc;
    integer    i;

    always @* begin
        a  = hb;
        am = hm;
        ak = hk;
        a[8*hl +: 8] = in_byte;       // hl <= 5 whenever a byte is taken (see S_PCT)
        am[hl]       = in_mark;
        z = 8'd0;
        o = 8'd0;
        for (i = 0; i < 6; i = i + 1) begin
            z[i] = (a[8*i +: 8] == 8'h00);
            o[i] = (a[8*i +: 8] == 8'h01);
        end
        L        = hl + 3'd1;
        nd       = 3'd0;
        nst      = st;
        nnpic    = npic;
        nfld     = fld;
        skip_inc = 1'b0;
        pair_inc = 1'b0;
        reduce   = 1'b0;
        base     = 3'd0;
        cut      = 3'd0;
        keep_now = (st == S_PASS);
        sc       = (L == 3'd4) && z[0] && z[1] && o[2];      // a full 00 00 01 xx

        if (st == S_PCT) begin
            // [00 00 01 00 t0 t1]: picture_coding_type is t1[5:3]
            if (L == 3'd6) begin
                if (a[45:43] == 3'b001) begin
                    ak = 6'b111111;
                    nd = 3'd6; nst = S_PASS; nnpic = 2'd1;
                end else begin
                    ak[2:0] = 3'b000;
                    nst = S_HUNT; skip_inc = 1'b1;
                    keep_now = 1'b0; base = 3'd3; reduce = 1'b1;
                end
            end
        end else if (sc && a[31:24] == 8'hB3) begin             // sequence header: a read begins
            ak[3:0] = 4'b1111;
            nd = 3'd4; nst = S_PASS; nnpic = 2'd0; nfld = 1'b0;
        end else if (sc && a[31:24] == 8'h00) begin             // picture start code
            if (st == S_PASS && npic == 2'd0) begin
                nst = S_PCT;                                   // hold all 4, read the type
            end else if (st == S_PASS && npic == 2'd1 && fld) begin
                ak[2:0] = 3'b111;
                nd = 3'd3; nnpic = 2'd2; pair_inc = 1'b1;      // the second field
            end else begin                                     // the cut (or still hunting):
                ak[2:0] = 3'b000;                              // byte 3 stays held, it may be
                nd = 3'd3; nst = S_HUNT;                       // the next header's first 00
            end
        end else if (sc) begin                                 // any other start code
            ak[3:0] = {4{keep_now}};
            nd = 3'd4;
        end else begin
            reduce = 1'b1;
        end

        // Reduce: decide every byte from `base` that cannot begin 00 00 01, keeping the
        // longest suffix that can (empty, 00, 00 00, 00 00 01). Scanned high to low so the
        // smallest such start wins. Decided bytes always precede held ones.
        if (reduce) begin
            cut = L;
            for (i = 5; i >= 0; i = i - 1)
                if (i >= base && i < L)
                    if ((L - i == 1 && z[i]) ||
                        (L - i == 2 && z[i] && z[i+1]) ||
                        (L - i == 3 && z[i] && z[i+1] && o[i+2]))
                        cut = i[2:0];
            for (i = 0; i < 6; i = i + 1)
                if (i >= base && i < cut) ak[i] = keep_now;
            nd = cut;
        end
    end

    // ---- state ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n || !en) begin
            hb <= 48'd0; hm <= 6'd0; hk <= 6'd0;
            hl <= 3'd0; hd <= 3'd0; st <= S_HUNT; npic <= 2'd0; fld <= 1'b0; ecnt <= 2'd0;
            if (!rst_n) begin skip_n <= 16'd0; pair_n <= 16'd0; end
        end else if (pop) begin
            hb <= {8'h00, hb[47:8]};
            hm <= {1'b0, hm[5:1]};
            hk <= {1'b0, hk[5:1]};
            hl <= hl - 3'd1;
            hd <= hd - 3'd1;
        end else if (take) begin
            hb   <= a;
            hm   <= am;
            hk   <= ak;
            hl   <= L;
            hd   <= nd;
            st   <= nst;
            npic <= nnpic;
            if (skip_inc) skip_n <= skip_n + 16'd1;
            if (pair_inc) pair_n <= pair_n + 16'd1;
            // picture_coding_extension after the first picture's header: byte 0 is
            // 0x8 | f_code[0][0], byte 2's low two bits are picture_structure
            // (ISO 13818-2 6.2.3.1). Tracked on raw bytes, independent of holding.
            fld <= nfld;
            if (nst == S_PASS && nnpic == 2'd1) begin
                case (ecnt)
                    2'd0: if (sc && a[31:24] == 8'hB5) ecnt <= 2'd1;
                    2'd1: ecnt <= (in_byte[7:4] == 4'h8) ? 2'd2 : 2'd0;
                    2'd2: ecnt <= 2'd3;
                    2'd3: begin fld <= (in_byte[1:0] != 2'b11); ecnt <= 2'd0; end
                endcase
            end else begin
                ecnt <= 2'd0;
            end
        end
    end
endmodule
`default_nettype wire
