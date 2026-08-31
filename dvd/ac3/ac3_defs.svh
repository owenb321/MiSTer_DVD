//============================================================================
//  ac3_defs.svh — shared parameters/constants for the AC-3 decoder PoC
//  Include guard so it is safe to `include from multiple modules.
//============================================================================
`ifndef AC3_DEFS_SVH
`define AC3_DEFS_SVH

// AC-3 sync word, MSB-first in the byte stream: 0x0B 0x77.
localparam logic [15:0] AC3_SYNCWORD = 16'h0B77;

// fscod == 0 => 48 kHz (the only rate this PoC supports).
localparam logic [1:0] AC3_FSCOD_48K = 2'b00;

// acmod == 2 => 2/0 L/R stereo; acmod == 7 => 3/2 (L C R Ls Rs), i.e. 5.1 when
// lfeon==1.  These are the two channel modes this decoder supports (M14).
localparam logic [2:0] AC3_ACMOD_MONO = 3'd1;   // 1/0 (DVD-FORK 2026-08-31)
localparam logic [2:0] AC3_ACMOD_LR  = 3'd2;
localparam logic [2:0] AC3_ACMOD_3_2 = 3'd7;

// Channel-slot indices in the {ch,idx}-addressed datapath memories.  Full-
// bandwidth channels are 0..nfchans-1 in liba52 order; the coupling channel and
// LFE get fixed high slots so addressing is uniform across acmod.
//   acmod==2: 0=L 1=R                           (nfchans=2)
//   acmod==7: 0=L 1=C 2=R 3=Ls 4=Rs             (nfchans=5)
localparam int AC3_MAX_FBW   = 5;   // max full-bandwidth channels (acmod==7)
localparam int AC3_CH_CPL    = 5;   // coupling channel slot
localparam int AC3_CH_LFE    = 6;   // LFE channel slot
localparam int AC3_NCH_SLOTS = 7;   // 5 fbw + cpl + lfe

// Per-block transform size (long block).
localparam int AC3_BLOCK_SAMPLES = 256;   // unique coeffs / output samples per block
localparam int AC3_BLOCKS_PER_FRAME = 6;

// bit_reader: max bits returnable in one get_bits request.
localparam int AC3_MAXW = 32;

`endif // AC3_DEFS_SVH
