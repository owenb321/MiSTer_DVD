//============================================================================
//  ac3_tables.svh - bit-allocation ROM tables (A/52 §7.2, == liba52 0.8.0
//  bit_allocate.c).  Included *inside* the bit_allocation module body; the
//  arrays are module items, initialised in an `initial` block (Quartus infers
//  ROMs from this, and it is the one array-init style accepted by both
//  iverilog -g2012 and the verilated build; unpacked-array localparams are not
//  supported by iverilog).
//
//  Values transcribed verbatim from liba52 so our derived bap[] is bit-exact to
//  liba52's fbw_expbap[ch].bap[] (the co-sim golden).  Notes:
//    - baptab is 305 entries; bit_allocate.c indexes it as (baptab+156)[k] with
//      k in [-156,147], i.e. absolute index 156+k in [0,303].  We keep the +156
//      bias explicit at the lookup.  Negative entries (-1,-2,-3) are liba52's
//      encoding for the grouped quantizers (A/52 bap 1/2/4) - mantissa_dequant
//      (M7) mirrors that convention.
//    - hthtab: only fscod==0 (48 kHz) is in PoC scope, so just that row is here.
//    - latab is the log-add table used by the band PSD integration.
//============================================================================
`ifndef AC3_TABLES_SVH
`define AC3_TABLES_SVH

// Bit-allocation pointer table.  bap[j] = baptab[156 + mask + 4*exp].
// (M19b: ramstyle + registered sync reads in bit_allocation so these three
//  ROMs infer as M10K blocks instead of LUT logic.)
(* ramstyle = "M10K" *)
logic signed [7:0]  baptab [0:304];

// Log-add table for band PSD integration.
(* ramstyle = "M10K" *)
logic signed [7:0]  latab  [0:255];

// Hearing-threshold table, fscod==0 (48 kHz) row only.  Positive (<= 0x910).
(* ramstyle = "M10K" *)
logic        [15:0] hthtab0 [0:49];

// Band boundary table: endband of band (i) is bndtab[i-20] (i = 20..49).
logic        [8:0]  bndtab [0:29];

// Small parameter tables (indexed by the BAI sub-codes).
logic        [11:0] slowgain_t [0:3];
logic        [12:0] dbpbtab_t  [0:3];
logic        [12:0] floortab_t [0:7];

initial begin
    // ---- baptab[0:304] ----
    // [0:92] = 93 padding 16's
    baptab = '{
        16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,
        16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,
        16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,
        16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,
        16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,
        16,16,16,16,16,16,16,16,16,16,16,16,16,           // 93 padding
        16,16,16,16,16,16,16,16,16,14,14,14,14,14,14,14,
        14,12,12,12,12,11,11,11,11,10,10,10,10, 9, 9, 9,
         9, 8, 8, 8, 8, 7, 7, 7, 7, 6, 6, 6, 6, 5, 5, 5,
         5, 4, 4,-3,-3, 3, 3, 3,-2,-2,-1,-1,-1,-1,-1, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0                                       // 148 trailing 0's
    };

    // ---- latab[0:255] ----
    latab = '{
        -64,-63,-62,-61,-60,-59,-58,-57,-56,-55,-54,-53,
        -52,-52,-51,-50,-49,-48,-47,-47,-46,-45,-44,-44,
        -43,-42,-41,-41,-40,-39,-38,-38,-37,-36,-36,-35,
        -35,-34,-33,-33,-32,-32,-31,-30,-30,-29,-29,-28,
        -28,-27,-27,-26,-26,-25,-25,-24,-24,-23,-23,-22,
        -22,-21,-21,-21,-20,-20,-19,-19,-19,-18,-18,-18,
        -17,-17,-17,-16,-16,-16,-15,-15,-15,-14,-14,-14,
        -13,-13,-13,-13,-12,-12,-12,-12,-11,-11,-11,-11,
        -10,-10,-10,-10,-10, -9, -9, -9, -9, -9, -8, -8,
         -8, -8, -8, -8, -7, -7, -7, -7, -7, -7, -6, -6,
         -6, -6, -6, -6, -6, -6, -5, -5, -5, -5, -5, -5,
         -5, -5, -4, -4, -4, -4, -4, -4, -4, -4, -4, -4,
         -4, -3, -3, -3, -3, -3, -3, -3, -3, -3, -3, -3,
         -3, -3, -3, -2, -2, -2, -2, -2, -2, -2, -2, -2,
         -2, -2, -2, -2, -2, -2, -2, -2, -2, -2, -1, -1,
         -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
         -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,
         -1, -1, -1, -1, -1, -1,  0,  0,  0,  0,  0,  0,
          0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
          0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
          0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
          0,  0,  0,  0
    };

    // ---- hthtab[fscod=0][0:49] ----
    hthtab0 = '{
        16'h730, 16'h730, 16'h7c0, 16'h800, 16'h820, 16'h840, 16'h850, 16'h850,
        16'h860, 16'h860, 16'h860, 16'h860, 16'h860, 16'h870, 16'h870, 16'h870,
        16'h880, 16'h880, 16'h890, 16'h890, 16'h8a0, 16'h8a0, 16'h8b0, 16'h8b0,
        16'h8c0, 16'h8c0, 16'h8d0, 16'h8e0, 16'h8f0, 16'h900, 16'h910, 16'h910,
        16'h910, 16'h910, 16'h900, 16'h8f0, 16'h8c0, 16'h870, 16'h820, 16'h7e0,
        16'h7a0, 16'h770, 16'h760, 16'h7a0, 16'h7c0, 16'h7c0, 16'h6e0, 16'h400,
        16'h3c0, 16'h3c0
    };

    // ---- bndtab[0:29] ----
    bndtab = '{
        9'd21,  9'd22,  9'd23,  9'd24,  9'd25,  9'd26,  9'd27,  9'd28,
        9'd31,  9'd34,  9'd37,  9'd40,  9'd43,  9'd46,  9'd49,  9'd55,
        9'd61,  9'd67,  9'd73,  9'd79,  9'd85,  9'd97,  9'd109, 9'd121,
        9'd133, 9'd157, 9'd181, 9'd205, 9'd229, 9'd253
    };

    slowgain_t = '{12'h540, 12'h4d8, 12'h478, 12'h410};
    dbpbtab_t  = '{13'h0c00, 13'h0500, 13'h0300, 13'h0100};
    floortab_t = '{13'h0910, 13'h0950, 13'h0990, 13'h09d0,
                   13'h0a10, 13'h0a90, 13'h0b10, 13'h1400};
end

`endif // AC3_TABLES_SVH
