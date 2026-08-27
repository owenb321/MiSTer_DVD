// =============================================================================
// dvd/aud_stream_map.sv — logical→physical audio stream resolution
// =============================================================================
// Resolves the LOGICAL audio stream number (SPRM1 / the user's clamped track
// pick) to the PHYSICAL substream index ps_demux filters on, through the PGC's
// audio_control[8] table (streamed by dvd_iso_reader at PGC load).
//
// Faithful to libdvdnav:
//   - vm_get_audio_stream (vmget.c:111): outside the title domain the logical
//     number is forced to 0 (menus/FP always use logical audio 0); an available
//     entry resolves to its bits[10:8] physical number; a non-title miss
//     resolves to 0.
//   - vm_get_audio_active_stream (vmget.c:169): a title-domain miss falls back
//     to the FIRST available stream (lowest logical n with the avail bit set).
//
// ONE documented deviation: where libdvdnav returns -1 (title PGC with no
// available stream at all -> silence), we return the logical number unchanged —
// the IDENTITY mapping, i.e. exactly the pre-mapping core. Same for
// map_valid=0 (no PGC parsed yet / linear .VOB/.mpg playback), so every legacy
// path is bit-identical to the old  aud_track_eff = clamped-logical  wiring.
// Rationale + the disc census that motivated all of this (GET_SMART VTS2 maps
// everything to substream 0x83; 31/431 library discs author non-identity maps):
// docs/track_selection.md "Logical→physical audio mapping".
//
// Golden model: tools/dvd_vm_ref.py aud_stream_map() (validated against
// libdvdnav on real discs); TB: bench/dvd/aud_stream_map_tb.sv.
//
// Purely combinational — Quartus flattens it into emu; it is a module only so
// it is unit-testable. Explicit case muxes instead of variable part-selects
// (the Quartus-17 N'(expr) netlist-mangling lesson, docs/mpeg1.md: keep the
// indexing structures boring).
// =============================================================================
`default_nettype none

module aud_stream_map (
    input  wire        map_valid,     // audio_control parsed & consistent (reader)
    input  wire        dom_tt,        // loaded PGC is title-domain (reader)
    input  wire [2:0]  logical,       // clamped logical pick (SPRM1 / aud_cur)
    input  wire [7:0]  avail,         // audio_control[n][15] per stream
    input  wire [23:0] phys_flat,     // {phys7,...,phys0} = audio_control[n][10:8]
    output wire [2:0]  phys_streamN   // -> ps_demux.aud_track
);

    // Menus/FP force logical 0 (vm_get_audio_stream's first rule).
    wire [2:0] log_eff = dom_tt ? logical : 3'd0;

    // audio_control[log_eff]
    reg       hit;
    reg [2:0] phys_hit;
    always @* begin
        case (log_eff)
        3'd0: begin hit = avail[0]; phys_hit = phys_flat[ 2: 0]; end
        3'd1: begin hit = avail[1]; phys_hit = phys_flat[ 5: 3]; end
        3'd2: begin hit = avail[2]; phys_hit = phys_flat[ 8: 6]; end
        3'd3: begin hit = avail[3]; phys_hit = phys_flat[11: 9]; end
        3'd4: begin hit = avail[4]; phys_hit = phys_flat[14:12]; end
        3'd5: begin hit = avail[5]; phys_hit = phys_flat[17:15]; end
        3'd6: begin hit = avail[6]; phys_hit = phys_flat[20:18]; end
        3'd7: begin hit = avail[7]; phys_hit = phys_flat[23:21]; end
        endcase
    end

    // First available stream (vm_get_audio_active_stream's scan).
    reg [2:0] phys_first;
    always @* begin
        casez (avail)
        8'b???????1: phys_first = phys_flat[ 2: 0];
        8'b??????10: phys_first = phys_flat[ 5: 3];
        8'b?????100: phys_first = phys_flat[ 8: 6];
        8'b????1000: phys_first = phys_flat[11: 9];
        8'b???10000: phys_first = phys_flat[14:12];
        8'b??100000: phys_first = phys_flat[17:15];
        8'b?1000000: phys_first = phys_flat[20:18];
        8'b10000000: phys_first = phys_flat[23:21];
        default:     phys_first = 3'd0;
        endcase
    end

    assign phys_streamN = !map_valid ? logical    :  // no PGC / linear: identity
                          hit        ? phys_hit   :
                          !dom_tt    ? 3'd0       :  // vmget.c non-title miss -> 0
                          |avail     ? phys_first :  // title miss -> first available
                                       logical;      // DEVIATION: identity, not -1

endmodule

`default_nettype wire
