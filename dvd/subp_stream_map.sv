// =============================================================================
// dvd/subp_stream_map.sv — logical→physical SUBPICTURE stream resolution
// =============================================================================
// Sibling of dvd/aud_stream_map.sv. Resolves a LOGICAL subpicture stream number
// to the PHYSICAL substream index ps_demux filters on (0x20 + N), through the
// PGC's subp_control[16] table (streamed by dvd_iso_reader at PGC load).
//
// WHY THIS EXISTS (issues #60 / #61)
//
// The DVD spec gives each logical subpicture stream FOUR physical ids, one per
// presentation:  [31] available, [28:24] 4:3, [20:16] 16:9 wide,
// [12:8] letterbox, [4:0] pan&scan  (libdvdnav vm_get_subp_stream, vmget.c).
//
// This core used to hardcode physical 0 for every menu, on the recorded premise
// that "menu buttons force subpicture stream 0 anyway". That premise held for
// the NTSC R1 discs it was written against and is false in general. Two PAL FR
// R2 discs (Once Upon a Time in China, Jin Roh) author 0x80010200 on EVERY menu
// PGC = available, 4:3→0, wide→1, letterbox→2, with 16:9 menus. Their menu SPU
// therefore rides substream 0x21; the core filtered 0x20, decoded no
// subpicture, and since a button highlight is a RECOLOUR of subpicture pixels
// (emu.sv sp_q_inside -> subpic_blend.ov_on) nothing was drawn at all —
// "blind selection". A 212-ISO library sweep found ZERO discs with that shape,
// which is why it could not be reproduced locally.
//
// DELIBERATE DEVIATION FROM libdvdnav: a MENU always resolves through the WIDE
// field, never letterbox or pan&scan. This core composites the subpicture in
// SOURCE space and scales the composite (emu.sv, the analog-overlay HW round),
// so selecting the disc's already-letterboxed variant and then applying
// disp_vscale would letterbox it TWICE. It also keeps the SPU variant and
// nav_pci's button-group choice on one shared display-mode wire, which emu
// already forces to wide for menus — so the rects and the art can never come
// from different presentations. The caller supplies disp_mode; this module
// does not know about menus beyond ctx_menu's validity gate.
//
// THE ctx_menu GATE IS NOT HYGIENE. subp_ctl_mem is a single store shared by
// both domains and is never cleared. Without a domain match:
//   - a menu jump raises menu_active BEFORE S_PGC_HDR clears pgc_ctl_valid, so
//     a menu context would briefly resolve through the TITLE's table;
//   - a menu's table would leak into the in-title HLI path (Matrix "Follow the
//     White Rabbit", SetSTN logical 1 -> 0x22).
// Both fall back to the logical index, which is the pre-fix behaviour.
//
// Golden model: tools/dvd_vm_ref.py subp_stream_map(); TB:
// bench/dvd/subp_stream_map_tb.sv. Detail: docs/track_selection.md.
//
// Purely combinational — Quartus flattens it into emu; it is a module only so
// it is unit-testable. The 16:1 mux over subp_ctl_mem stays in emu (routing is
// tight at ~90% ALM and a second mux has already failed to fit once), so this
// takes the ALREADY-MUXED word, exactly as aud_stream_map takes pre-flattened
// avail/phys_flat.
// =============================================================================
`default_nettype none

module subp_stream_map (
    input  wire        map_valid,     // subp_control parsed & consistent (reader)
    input  wire        dom_tt,        // loaded PGC is title-domain (reader)
    input  wire        ctx_menu,      // this resolution is for a menu context
    input  wire [3:0]  logical,       // logical stream index (already selected)
    input  wire [31:0] ctl_sel,       // subp_control[logical], muxed by emu
    input  wire        wide,          // content is 16:9 (ar_wide_auto_eff)
    input  wire [1:0]  disp_mode,     // 0 = wide, 1 = letterbox, 2 = pan&scan
    // OR of the "available" bit across all 16 subp_control entries of the loaded
    // PGC (emu computes it; this module only ever sees the ONE selected word).
    input  wire        any_present,
    output wire [4:0]  phys_streamN,  // -> ps_demux.sp_track
    // 1 = the loaded PGC has a usable table and it does NOT declare this logical
    // stream, so there is nothing to show. See the STREAM AVAILABILITY note below.
    output wire        stream_absent
);

    // The table is trustworthy only when the reader has finished streaming it
    // AND it belongs to the domain this resolution is for.
    wire dom_ok  = ctx_menu ? ~dom_tt : dom_tt;
    // the table is usable for this context (says nothing about THIS entry)
    wire use_map_dom = map_valid && dom_ok;
    wire use_map = use_map_dom && ctl_sel[31];

    // Explicit case mux, not a variable part-select (the Quartus-17
    // netlist-mangling lesson, docs/mpeg1.md: keep the indexing boring).
    reg [4:0] phys_wide;
    always @* begin
        case (disp_mode)
        2'd1:    phys_wide = ctl_sel[12: 8];   // 16:9 letterbox
        2'd2:    phys_wide = ctl_sel[ 4: 0];   // 16:9 pan&scan
        default: phys_wide = ctl_sel[20:16];   // 16:9 wide
        endcase
    end

    assign phys_streamN = !use_map ? {1'b0, logical}     :  // fall back: identity
                          !wide    ? ctl_sel[28:24]      :  // 4:3 content
                                     phys_wide;

    // ---- STREAM AVAILABILITY (2026-09-08) -----------------------------------
    // libdvdnav guards the WHOLE resolution on the available bit
    // (vmget.c: `if(pgc->subp_control[subpN] & 0x80000000)`), leaving the stream
    // unselected when it is clear. This core instead falls back to identity, which
    // is right when there is no usable table and wrong when there is one that
    // simply does not offer this stream.
    //
    // ★ THE FIELD CASE: The Matrix's "Follow the White Rabbit" PGC (VTS_02 PGCN 6)
    // declares logical stream 1 ONLY -- the rabbit icon on 0x22. Pressing the
    // Subtitle button releases the VM's claim (emu: `if (sub_edge) vm_owns_sp<=0`),
    // the user path resolves logical 0 by raw index to 0x20 (which IS the real
    // subtitle stream), and it is then drawn with PGCN 6's palette -- where the
    // three opaque subtitle classes are ALL Y=128. MEASURED on the disc:
    //   PGCN 1 palette  [0] Y=16  [8] Y=128 [9] Y=176   -> fill/outline/black edge
    //   PGCN 6 palette  [0] Y=128 [8] Y=128 [9] Y=128   -> one flat grey
    // Reported as "subtitles are white on white with no black outline".
    //
    // ⚠ THE RULE IS NARROWED ON A MEASUREMENT, not on the spec alone. A 221-disc,
    // 22,733-PGC sweep classified every title PGC:
    //   A  declares logical 0                     18,801
    //   B  declares NOTHING                        3,929  (586 in a VTS that has
    //                                                     subpicture streams)
    //   C  declares something, but not logical 0       3
    // Applying the available bit unconditionally would strip subtitles from the 586
    // class-B PGCs (up to 168 discs) that rely on the identity fallback today. So
    // `any_present` narrows it to class C: a PGC that declares SOME stream has a
    // working table, and an entry it omits really is unavailable. Blast radius: 3
    // PGCs library-wide, which is the case that was reported.
    assign stream_absent = use_map_dom && any_present && !ctl_sel[31];

endmodule

`default_nettype wire
