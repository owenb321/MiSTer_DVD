//============================================================================
//  ac3_mant_tables.svh — mantissa-dequant ROM tables (A/52 §7.3.1, == liba52
//  0.8.0 tables.h).  Included *inside* the mantissa_dequant module body; arrays
//  are module items initialised in an `initial` block (same ROM-inference style
//  as ac3_tables.svh — the one form both iverilog -g2012 and the verilated
//  build accept).
//
//  liba52 stores each quantizer level as a `sample_t` float `(k<<15)/N`.  Our
//  fabric path is fixed-point, so we store the **round-to-nearest 16-bit
//  integer** of that float (the "m16" mantissa value).  The final coefficient
//  is `coeff = m16 · 2^-(15+exp)` (see architecture.md §5); that ROM rounding is
//  the dominant fixed-point error term (≤ 0.5 LSB @ m16) and is well inside the
//  ±2-LSB-@-s16 budget.
//
//  liba52 ungroups each grouped quantizer with full per-code tables (q_1_0[],
//  q_1_1[], …).  We instead keep the small per-quantizer *level* LUT and derive
//  the sub-indices arithmetically (the same small-constant divides
//  exponent_decode already uses):
//    bap1 (3-level, 5-bit code, group of 3): lev[code/9], lev[(code/3)%3], lev[code%3]
//    bap2 (5-level, 7-bit code, group of 3): lev[code/25], lev[(code/5)%5], lev[code%5]
//    bap4 (11-level,7-bit code, group of 2): lev[code/11], lev[code%11]
//  emitted most-significant sub-mantissa first (matches liba52's q_*_0 → q_*_1
//  → q_*_2 emit order).  bap3 (7-level,3-bit) and bap5 (15-level,4-bit) are
//  ungrouped direct table lookups.
//============================================================================
`ifndef AC3_MANT_TABLES_SVH
`define AC3_MANT_TABLES_SVH

// 3-level  (bap 1): round((k<<15)/3),  k = -2,0,2
logic signed [16:0] q1lev [0:2];
// 5-level  (bap 2): round((k<<15)/5),  k = -4,-2,0,2,4
logic signed [16:0] q2lev [0:4];
// 7-level  (bap 3): round((k<<15)/7),  k = -6,-4,-2,0,2,4,6 ; idx 7 unused (0)
logic signed [16:0] q3lev [0:7];
// 11-level (bap 4): round((k<<15)/11), k = -10..10 step 2
logic signed [16:0] q4lev [0:10];
// 15-level (bap 5): round((k<<15)/15), k = -14..14 step 2 ; idx 15 unused (0)
logic signed [16:0] q5lev [0:15];

// dither LFSR lookup (a52 tables.h dither_lut), 256 × 16-bit.
logic [15:0] dither_lut [0:255];

initial begin
    // round((k<<15)/3)
    q1lev = '{ -21845, 0, 21845 };
    // round((k<<15)/5)
    q2lev = '{ -26214, -13107, 0, 13107, 26214 };
    // round((k<<15)/7)
    q3lev = '{ -28087, -18725, -9362, 0, 9362, 18725, 28087, 0 };
    // round((k<<15)/11)
    q4lev = '{ -29789, -23831, -17873, -11916, -5958, 0,
                 5958, 11916, 17873, 23831, 29789 };
    // round((k<<15)/15)
    q5lev = '{ -30583, -26214, -21845, -17476, -13107, -8738, -4369, 0,
                 4369, 8738, 13107, 17476, 21845, 26214, 30583, 0 };

    dither_lut = '{
        16'h0000, 16'ha011, 16'he033, 16'h4022, 16'h6077, 16'hc066, 16'h8044, 16'h2055,
        16'hc0ee, 16'h60ff, 16'h20dd, 16'h80cc, 16'ha099, 16'h0088, 16'h40aa, 16'he0bb,
        16'h21cd, 16'h81dc, 16'hc1fe, 16'h61ef, 16'h41ba, 16'he1ab, 16'ha189, 16'h0198,
        16'he123, 16'h4132, 16'h0110, 16'ha101, 16'h8154, 16'h2145, 16'h6167, 16'hc176,
        16'h439a, 16'he38b, 16'ha3a9, 16'h03b8, 16'h23ed, 16'h83fc, 16'hc3de, 16'h63cf,
        16'h8374, 16'h2365, 16'h6347, 16'hc356, 16'he303, 16'h4312, 16'h0330, 16'ha321,
        16'h6257, 16'hc246, 16'h8264, 16'h2275, 16'h0220, 16'ha231, 16'he213, 16'h4202,
        16'ha2b9, 16'h02a8, 16'h428a, 16'he29b, 16'hc2ce, 16'h62df, 16'h22fd, 16'h82ec,
        16'h8734, 16'h2725, 16'h6707, 16'hc716, 16'he743, 16'h4752, 16'h0770, 16'ha761,
        16'h47da, 16'he7cb, 16'ha7e9, 16'h07f8, 16'h27ad, 16'h87bc, 16'hc79e, 16'h678f,
        16'ha6f9, 16'h06e8, 16'h46ca, 16'he6db, 16'hc68e, 16'h669f, 16'h26bd, 16'h86ac,
        16'h6617, 16'hc606, 16'h8624, 16'h2635, 16'h0660, 16'ha671, 16'he653, 16'h4642,
        16'hc4ae, 16'h64bf, 16'h249d, 16'h848c, 16'ha4d9, 16'h04c8, 16'h44ea, 16'he4fb,
        16'h0440, 16'ha451, 16'he473, 16'h4462, 16'h6437, 16'hc426, 16'h8404, 16'h2415,
        16'he563, 16'h4572, 16'h0550, 16'ha541, 16'h8514, 16'h2505, 16'h6527, 16'hc536,
        16'h258d, 16'h859c, 16'hc5be, 16'h65af, 16'h45fa, 16'he5eb, 16'ha5c9, 16'h05d8,
        16'hae79, 16'h0e68, 16'h4e4a, 16'hee5b, 16'hce0e, 16'h6e1f, 16'h2e3d, 16'h8e2c,
        16'h6e97, 16'hce86, 16'h8ea4, 16'h2eb5, 16'h0ee0, 16'haef1, 16'heed3, 16'h4ec2,
        16'h8fb4, 16'h2fa5, 16'h6f87, 16'hcf96, 16'hefc3, 16'h4fd2, 16'h0ff0, 16'hafe1,
        16'h4f5a, 16'hef4b, 16'haf69, 16'h0f78, 16'h2f2d, 16'h8f3c, 16'hcf1e, 16'h6f0f,
        16'hede3, 16'h4df2, 16'h0dd0, 16'hadc1, 16'h8d94, 16'h2d85, 16'h6da7, 16'hcdb6,
        16'h2d0d, 16'h8d1c, 16'hcd3e, 16'h6d2f, 16'h4d7a, 16'hed6b, 16'had49, 16'h0d58,
        16'hcc2e, 16'h6c3f, 16'h2c1d, 16'h8c0c, 16'hac59, 16'h0c48, 16'h4c6a, 16'hec7b,
        16'h0cc0, 16'hacd1, 16'hecf3, 16'h4ce2, 16'h6cb7, 16'hcca6, 16'h8c84, 16'h2c95,
        16'h294d, 16'h895c, 16'hc97e, 16'h696f, 16'h493a, 16'he92b, 16'ha909, 16'h0918,
        16'he9a3, 16'h49b2, 16'h0990, 16'ha981, 16'h89d4, 16'h29c5, 16'h69e7, 16'hc9f6,
        16'h0880, 16'ha891, 16'he8b3, 16'h48a2, 16'h68f7, 16'hc8e6, 16'h88c4, 16'h28d5,
        16'hc86e, 16'h687f, 16'h285d, 16'h884c, 16'ha819, 16'h0808, 16'h482a, 16'he83b,
        16'h6ad7, 16'hcac6, 16'h8ae4, 16'h2af5, 16'h0aa0, 16'haab1, 16'hea93, 16'h4a82,
        16'haa39, 16'h0a28, 16'h4a0a, 16'hea1b, 16'hca4e, 16'h6a5f, 16'h2a7d, 16'h8a6c,
        16'h4b1a, 16'heb0b, 16'hab29, 16'h0b38, 16'h2b6d, 16'h8b7c, 16'hcb5e, 16'h6b4f,
        16'h8bf4, 16'h2be5, 16'h6bc7, 16'hcbd6, 16'heb83, 16'h4b92, 16'h0bb0, 16'haba1
    };
end

`endif // AC3_MANT_TABLES_SVH
