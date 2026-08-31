// dvd_iso_reader.sv
//
// In-fabric DVD-Video sector source. Drop-in replacement for mpg_streamer:
// same output contract (stream_data / stream_valid / busy) into ps_stream_fifo,
// same hps_io sd_* block interface, same clk_sys single-clock domain.
//
// Two automatically-selected paths, chosen at mount:
//
//   1. ISO path  - when the mounted image is a DVD-Video ISO (ISO9660 "CD001"
//      present at logical sector 16). Parses ISO9660 to find VIDEO_TS/, picks
//      the MAIN FEATURE and streams exactly that title set's VOB sectors, back
//      to back. No HPS daemon: the sd_* block interface is random-access (the
//      framework main binary serves any sd_lba from the mounted image, like a
//      .vhd core), so all navigation lives here in fabric.
//
//      MAIN-FEATURE SELECTION (IFO-primary, size-fallback): after enumerating
//      the VIDEO_TS title VOBs, we parse the DVD-Video VMGI (VIDEO_TS.IFO) Title
//      Search Pointer Table (TT_SRPT) and pick the VTS that holds TITLE 1 (the
//      conventional main feature). If VIDEO_TS.IFO is absent or the TT_SRPT is
//      malformed we fall back to the old heuristic: the VTS whose title VOBs
//      _1.._N are the largest in total. IFO fields are BIG-ENDIAN. Offsets used:
//        VMGI_MAT.tt_srpt          @196 (0xC4)  BE u32  sector ptr rel. to IFO
//                                                       start => abs LBA =
//                                                       vmgi_lba + tt_srpt_ptr
//        TT_SRPT.nr_of_srpts       @0           BE u16  title count
//        TT_SRP[0].title_set_nr    @14 (=8+6)   u8      title 1's VTS number
//      (Cross-checked vs libdvdread ifo_types.h vmgi_mat_t / tt_srpt_t.)
//
//   2. Flat-file fallback - when the image is NOT ISO9660 (a bare .VOB / .mpg /
//      .m2v elementary or program stream). Streams the whole file linearly from
//      block 0, exactly like the original mpg_streamer.
//
// CSS is out of scope (v1 supports DECRYPTED ISOs only). UDF-only images and
// IFO/PGC navigation (chapters/seek/angles) are later phases. See docs/dvd_nav.md.
//
// BLOCK SIZE: the sd_* interface serves 2048-byte blocks (hps_io BLKSZ=4,
// sd_blk_cnt=0 => 1 block/req) = exactly one ISO9660/DVD logical sector, so
// sd_lba IS the 2048-sector LBA and a DVD RBN maps 1:1. The stream engine works
// purely in 2048-sectors via a small extent table of {start_sector, sector_count}
// ranges. (Historical: v1 used 512-byte blocks — sd_lba = N*4 .. N*4+3, four
// round-trips per sector. That per-request HPS round-trip capped delivery below
// the 10.08 Mbps DVD mux ceiling and skipped audio on high-bitrate discs
// (Thayer's Quest); one request per sector cuts the round-trips 4x.)
//
// AREA NOTE: parse_buf is a SYNCHRONOUS single-read-port RAM (infers as one M10K).
// Directory-record fields are NOT read from it with combinational multi-offset
// taps (that synthesises to huge replicated LUT-RAM / muxes - it blew the fitter
// to 226% ALMs). Instead a small fetch sequencer copies the current record's first
// 45 bytes into a 45-entry register shadow (rbuf), and all parsing reads rbuf.

module dvd_iso_reader #(
    // clk_sys cycles per second for the timed-still 1 Hz tick. 27 MHz in
    // hardware; a testbench overrides it small so a 5 s hold isn't 135 M cycles.
    parameter SEC_DIV = 27_000_000,
    // Scrub NAV-align probe budget (sectors). A scrub target is snapped forward to
    // the first NAV pack within this many sectors, else it falls back to the raw
    // target. ~1 VOBU is the practical horizon; a testbench overrides it small.
    parameter NAV_CAP = 1024,
    // NATURAL-TRANSITION TAIL DRAIN watchdog (clk cycles, ~5 s at 27 MHz). A
    // title-domain PGC end waits for the decoder's compressed VBUF to drain
    // (vbuf_empty) before dispatching vm_pgc_end, so the clip's buffered tail
    // plays out instead of being cut by the subsequent jump's vbuf_flush. This
    // bounds the wait so a wedged/never-draining decoder degrades to the old
    // dispatch-with-flush behaviour instead of parking the transition forever.
    // A testbench overrides it small. See docs/dvd_nav.md "Tail drain".
    // DVD-FORK FIX (2026-08-18, Weakest Link answer timer): was 28'd134_217_728
    // = 5.0 s, which is SHORTER THAN AN AUTHORED CELL. WL's question screen is
    // one 17-second cell holding only 311 sectors (0.6 MB) - the whole answer
    // window fits inside the 2 MB VBUF, so the reader finishes parsing it in a
    // fraction of a second and the cell command's verdict is gated waiting for
    // vbuf_empty... which cannot arrive until the display has played all 17 s.
    // The 5 s bound fired first and cut the window to 5 s ("Too Late!").
    // The wait can legitimately last as long as it takes the decoder to DISPLAY
    // a full VBUF: 2 MB at the ~300 kbit/s such screens are authored at is ~56 s,
    // so bound at 60 s. This only ever fires when vbuf_empty never arrives (a
    // wedged decoder); normal transitions still exit early on vbuf_empty and are
    // unchanged. See docs/disc_sweep.md.
    parameter DRAIN_WD = 31'd1_620_000_000
) (
    input             clk,
    input             rst_n,

    // Control
    input             start,        // pulse: begin from a freshly mounted image
    input      [63:0] file_size,    // image size in bytes (from img_size)
    input      [15:0] lu_lang_pref, // OSD "Player Language" ISO-639 code (menu LU
                                     // match, spec-hardening Phase 4; = dvd_vm SPRM0)
    input      [6:0]  title_sel,    // DEBUG "Title VTS" picker: 0 = Auto, else play
                                     // VTS # N (7-bit: 26/302 library discs have >15
                                     // VTS - Atmosfear 75; spec max VTS_99)

    // MENU STILL COLD RE-DECODE (docs/dvd_menu_refinements.md §5). A menu still cell's
    // displayed frame is decoded MID-STREAM (entered via a keep_vbuf transition, so with
    // stale references) and shows PIXELATED. Fix: re-stream just the still cell as a clean
    // COLD decode (from its own sequence header) so the I-frame reconstructs correctly.
    //   vbuf_empty : the decoder has drained its compressed buffer (transition fully played
    //                out) - the Smooth-mode trigger, so the authored transition is NOT cut.
    //   menu_snap  : P1O[18] Snappy - re-decode IMMEDIATELY (the emu deep-flush already
    //                emptied the buffer, so it's fast; a buffered transition is cut, which
    //                Snappy accepts). Either condition arms the once-per-entry re-decode.
    input             vbuf_empty,
    input             menu_snap,

    // AUTHORED CELL DURATION - display-referenced cell clock (docs/dvd_nav.md
    // "authored cell duration"). A DVD cell's presentation lasts its authored
    // playback time (C_PBTM) and ends when that time has elapsed ON THE DISPLAY
    // TIMELINE, not when its sectors have been delivered. disp_tick is one pulse
    // per displayed image (emu: core_v_sync rising edge in clk_sys - the SAME
    // reference av_sync advances the STC with; never clk_sys wall time, never
    // the parse front - the standing lip-sync lesson, docs/av_sync.md).
    // disp_fps = ticks per second of the active raster (emu resolves 60/50 and
    // the film 24/25 rasters), so seconds derived here track real display time.
    input             disp_tick,
    input      [5:0]  disp_fps,

    // Transport seek (cell-granular). seek_pulse jumps playback to seek_cell
    // within the current title's PGC cell list. Ignored unless cell-mode is
    // active and seek_cell is in range. See docs/dvd_nav.md "Transport".
    input             seek_pulse,    // pulse: jump to seek_cell
    input      [7:0]  seek_cell,
    // NATURAL-SEEK PROVENANCE (tail-drain Phase B): valid on the seek_pulse
    // cycle. 1 = this seek is the VM's verdict on a natural CELL/POST command
    // (vm_from_wait; emu ANDs it with vm_seek_pulse so a coincident gamepad
    // seek is never tagged natural) => in the title domain the seek waits for
    // vbuf_empty before executing, so its flush can't cut the clip's tail.
    input             seek_natural,     // target cell index (program order)
    // Sub-cell time scrub (Phase 8): jump to an ABSOLUTE VTSTT_VOBS RBN (2048-
    // sector), typically current-VOBU LBN +/- a DSI fwda/bwda offset. The reader
    // finds the cell whose [first,last] RBN range contains the target (keeps
    // cur_cell / play_end coherent) then streams from that RBN. Same block-boundary
    // + flush contract as seek_cell. See docs/dvd_nav.md "Seeking / Phase 8".
    input             seek_rbn_pulse, // pulse: jump to seek_rbn
    input      [31:0] seek_rbn,       // target RBN (2048-sector, VTSTT_VOBS-relative)
    // Chapter (PTT) skip (Phase 8): jump to the previous/next chapter boundary.
    // Resolved in-fabric from the PGC program_map (chapter -> entry cell) against
    // the current cell, then executed via the seek_cell primitive. Title only.
    input             chap_pulse,    // pulse: chapter skip
    input             chap_dir,      // 1 = next chapter, 0 = previous
    input      [4:0]  chap_mag,      // # of chapters to skip in this burst (>=1).
                                     // emu debounces repeated B2/B3 presses into a
                                     // single pulse carrying the net count, so a rapid
                                     // multi-press seeks straight to the destination
                                     // chapter instead of scrubbing through each.
    input             chap_at_start, // 1 = near the current chapter's start (from DSI
                                     // cell-elapsed time) -> prev goes to the PREVIOUS
                                     // chapter; else prev restarts the current one
    output reg        seek_ack,      // pulse: a seek was accepted (drives load_flush)
    output     [7:0]  cur_cell,      // currently-playing cell index (for UI)
    output            cell_ready,    // 1 = cell-mode active (seek available)

    // ---------------------------------------------------------------------
    // MULTI-ANGLE (Phase 9). A multi-angle segment is an interleaved block:
    // the PGC holds one CELL per angle (cell category byte@0 block_type==1),
    // all sharing the physical VOB range, chopped into interleaved units
    // (ILVUs). The reader plays ONLY the selected angle: it loads the
    // cur_angle cell (its first_sector = that angle's first ILVU) and follows
    // the DSI sml_agli chain, jumping past the sibling angles' ILVUs at each
    // ILVU boundary. A switch is TIME-CONTINUOUS (shared timeline) so the jump
    // does NOT flush the VBUF or re-anchor A/V (no seek_ack). See
    // docs/dvd_nav.md "Multi-angle / Phase 9".
    input             angle_pulse,   // pulse: cycle to the next camera angle
    output reg [3:0]  cur_angle,     // 1-based selected angle (1 when none)
    output reg [3:0]  angle_count,   // angles in the current block (0 = not in one)

    // ---------------------------------------------------------------------
    // VM JUMP interface (Phase-2 disc menus). A jump re-targets playback to
    // any PGC of any domain; it is LATCHED and executed at a block boundary
    // (same contract as the transport seek) and re-runs the generalized IFO
    // parse (PGCI_UT -> PGCIT -> PGC -> commands -> cells). jump_ack pulses
    // when the jump executes (emu ORs it into the load_flush/vbuf_flush
    // contract); pgc_loaded / pgc_error report the outcome. Domains:
    //   0 = FP   (First Play PGC: VMGI@132 byte offset; COMMANDS ONLY, no video)
    //   1 = VMGM (VMG menu:  VMGI@200 PGCI_UT, cells map into VIDEO_TS.VOB)
    //   2 = VTSM (VTS menu:  VTSI@208 PGCI_UT, cells map into VTS_xx_0.VOB)
    //   3 = TT   (title:     VTSI@204 VTS_PGCIT, cells map via the extent table)
    // jump_pgcn selects SRP[pgcn-1]; pgcn==0 means "use jump_entry" for menu
    // domains (entry_id bit7 + low-nibble match: VMGM 2=Title, VTSM 3=Root...;
    // no match -> SRP[0]) and PGCN 1 for TT. jump_cell = start cell (TT resume).
    // See docs/dvd_nav.md "Menu domain".
    input             jump_pulse,
    input      [1:0]  jump_domain,
    input      [7:0]  jump_vts,
    input      [15:0] jump_pgcn,
    input      [3:0]  jump_entry,
    input      [7:0]  jump_cell,
    // Phase-4 VM extensions to the jump:
    //   jump_ttn != 0 (TT domain): select the PGC by TITLE-entry scan
    //     (PGCIT SRP entry_id bit7 + low7 == ttn). With jump_vts == 0 the
    //     VMG TT_SRPT is re-read first (JumpTT n: TT_SRP[n-1].title_set_nr
    //     @+6 / vts_ttn @+7) - the reader is the VM's page-table walker.
    //   jump_pgn != 0 (TT domain): start at PROGRAM n - the start cell is
    //     latched while the P_PMAP walk streams the program map (pm[n-1]-1),
    //     overriding jump_cell (a direct program link, e.g. LinkPGN).
    //   jump_ptt != 0 (TT domain, Phase 6): EXACT chapter/PTT. Resolve
    //     VTS_PTT_SRPT[want_ttn][jump_ptt-1] = {pgcn, pgn} in S_PTT_OFF/PGC
    //     (offset the PTT read by 4*(jump_ptt-1)) and start at that PGC+program.
    //     jump_ptt == 0/1 -> PTT[0] = the title entry (JumpTT / JumpVTS_TT /
    //     the white-rabbit JumpVTS_PTT ttn=6, all unchanged). Supersedes the old
    //     ptt~=pg approximation (jump_pgn) for JumpVTS_PTT / LinkPTTN.
    input      [6:0]  jump_ttn,
    input      [7:0]  jump_pgn,
    input      [9:0]  jump_ptt,
    // NATURAL-JUMP PROVENANCE (tail-drain Phase B): valid on the jump_pulse
    // cycle (= dvd_vm.vm_from_wait). 1 = the jump is the verdict on a natural
    // CELL/POST command block, so - when latched from the TITLE domain - it
    // waits for vbuf_empty (bounded by DRAIN_WD) before jump_go, exactly like
    // the PGC-end dispatch gate: the keep_vbuf=0 flush would otherwise cut
    // the decoder's ~1 s buffered tail (Thayer's Quest FMV branch cells).
    // Menu-domain sources bypass (their tail rides keep_vbuf; menus stay
    // snappy); user/boot jumps arrive with 0 (the VM's BLK_BTN discipline).
    input             jump_natural,
    output reg        jump_ack,      // pulse: jump latched + executing (flush now)
    // MENU-TRANSITION VBUF HOLD (Phase-5): valid on the seek_ack/jump_ack cycle.
    // 1 = this seek/jump stays WITHIN a menu (menu->menu transition: LinkPGN cell
    // seek, LinkPGCN menu jump, authored next_pgcn advance) => emu must NOT pulse
    // vbuf_flush, so the decoder plays out its buffered transition-animation tail
    // instead of cold-restarting on a stale/black frame (the "highlight over a
    // frozen pre-transition still" symptom). load_flush still fires (ps_demux /
    // nav_pci / av_sync re-anchor). Title seeks and menu->title jumps keep the
    // flush (A/V-sync critical). See docs/dvd_menu_refinements.md sec.2.
    output reg        keep_vbuf,
    output reg        pgc_loaded,    // pulse: PGC parse done (streaming / FP cmds done)
    output reg        pgc_error,     // pulse: a MENU jump failed (emu runs a fallback)
    output            menu_active,   // level: a menu-domain PGC is loaded
    output            still_active,  // level: holding a menu still (S_STILL)
    output     [7:0]  cur_vts,       // VTS number of the loaded TITLE (for VTSM/TT jumps)
    output     [15:0] cur_pgcn_o,    // PGCN of the loaded PGC (menu breadcrumbs)
    // VTS with the LARGEST menu VOB (0 = none). Fallback target when the
    // playing title's own VTSM root dead-ends: on VM-heavy discs (MiB) the
    // feature VTS's root entry is a JumpSS trampoline into the VMG dispatcher
    // and the REAL menu lives in another VTS's VTSM - which is invariably the
    // one with the big menu VOB. Heuristic until the Phase-4 VM executes the
    // trampoline for real.
    output     [7:0]  best_menu_vts,
    // CELL-LOOP heuristic (Phase 3): while a menu cell is ENDING with a
    // nonzero cell_cmd_nr AND nav_pci holds an armed button HLI, REPLAY the
    // cell instead of advancing. Authored menus keep their interactive screen
    // looping via a cell command (MiB cell 1: LinkTailPGC-class, 7 buttons;
    // Matrix cell 2: same shape) - without the VM this replay is what a real
    // player's cell-command loop looks like. A button activation or the Menu
    // key escapes the loop. No flush: cells start on clean GOPs and av_sync
    // re-anchors on the PTS jump.
    input             menu_btns_armed,

    // ---------------------------------------------------------------------
    // Phase-4 DVD-VM coupling. vm_mode (= O[1] Disc Menus) hands navigation
    // decisions to dvd_vm.sv:
    //   - mount: after the VIDEO_TS walk the reader IDLES (S_DONE) instead
    //     of auto-playing; the VM boots the First Play PGC.
    //   - a cell ending with cell_cmd_nr != 0 pulses vm_cell_cmd and WAITS
    //     (S_VM_WAIT) for the VM's verdict: vm_adv (advance), vm_replay
    //     (replay the cell, gapless - the menu loop), or a jump/seek.
    //   - a finished PGC drains the cache, pulses vm_pgc_end and waits the
    //     same way (POST commands run against the drained picture).
    //   - the Phase-2/3 heuristics (0-cell LinkPGCN follow, armed-button
    //     cell loop, authored next_pgcn policy) only apply on vm_adv /
    //     with vm_mode off - the VM executes the real commands instead.
    // A ~0.62 s watchdog treats a missing verdict as vm_adv, so a disabled
    // or wedged VM can never park playback.
    input             vm_mode,
    input             vm_adv,        // pulse: continue authored behaviour
    input             vm_replay,     // pulse: replay the current cell (no flush)
    output reg        vm_cell_cmd,   // pulse: waiting on a cell command
    output reg        vm_pgc_end,    // pulse: waiting on POST (drained)
    // Level: a NATURAL jump/seek is latched and gated on vbuf_empty (tail
    // drain in progress). emu feeds it to dvd_vm.wait_hold to freeze the
    // VM's V_WAIT give-up timer across the (up to DRAIN_WD) gate window.
    output            nat_wait_o,
    output            nav_ready_o,   // level: VIDEO_TS walk finished
    output     [7:0]  auto_vts,      // the Auto title pick (OSD override / largest)
    output     [7:0]  cell_count_o,  // cells in the loaded PGC (0 = command stub)
    output     [6:0]  res_ttn,       // resolved vts_ttn of the loaded TT PGC
                                     // (JumpTT: TT_SRPT vts_ttn -> VM SPRM5)

    // ---------------------------------------------------------------------
    // Phase-10 track enumeration. The title VTSI_MAT carries how many audio
    // and subpicture streams the feature actually has, plus each stream's
    // codec / channel count / ISO-639 language. Parsed once at the title mount
    // (S_ATTR sweep, off S_PGC_BEGIN) directly out of the resident VTSI_MAT
    // sector. audio_ntracks/subp_ntracks BOUND the gamepad Audio/Subtitle
    // cycle in emu (a switch can never land on a stream that isn't there ->
    // silence). The per-track readout (selected by attr_a_sel/attr_s_sel) is
    // exposed for the Phase-11 on-screen track indicator. Defaults to 8
    // (unconstrained = pre-Phase-10 behaviour) until a real IFO is parsed, so
    // non-ISO / linear playback is unchanged. See docs/track_selection.md.
    output reg [3:0]  audio_ntracks, // nr_of_vts_audio_streams @515 (1..8)
    output reg [3:0]  subp_ntracks,  // nr_of_vts_subp_streams  @597 (1..8)
    input      [2:0]  attr_a_sel,    // audio track to read out (0..7)
    output     [2:0]  attr_a_fmt,    // audio_format (0=AC3,2=MPEG1,4=LPCM,6=DTS)
    output     [3:0]  attr_a_ch,     // channel count (1..8)
    output     [15:0] attr_a_lang,   // ISO-639 language, 2 ASCII bytes (0=none)
    input      [2:0]  attr_s_sel,    // subpicture track to read out (0..7)
    output     [15:0] attr_s_lang,   // subpicture ISO-639 language (0=none)

    // PGC command table stream (pre|post|cell contiguous, 8 B/command, byte
    // stream into the dvd_vm command BRAM).
    output reg        cmd_we,
    output reg [11:0] cmd_waddr,
    output reg [7:0]  cmd_wdata,
    output reg [7:0]  cmd_nr_pre,
    output reg [7:0]  cmd_nr_post,
    output reg [7:0]  cmd_nr_cell,
    // Program map stream (P_PMAP walk; pm[i] = entry cell of program i+1)
    output reg        pm_we,
    output reg [6:0]  pm_waddr,
    output reg [7:0]  pm_wdata,
    output reg [7:0]  cmd_nr_pgm,    // nr_of_programs (PGC@2)
    // Phase 11 HUD: current chapter (1-based program containing the playing
    // cell; the "n" of the CH n/N readout, N = cmd_nr_pgm). Resolved by a
    // query-only pmap walk whenever the streaming cell changes; 0 until the
    // first query completes (emu gates the readout on cur_pgm != 0).
    // Cross-PGC (spec-hardening Phase-5 follow-up): cur_pgm is the GLOBAL
    // chapter (PTT index), reverse-mapped from the current {pgcn, program}
    // through the resident ptt_mem (CH_G scan) whenever a PTT table loaded;
    // on a single-PGC (movie) title chapter == program so this matches the
    // pre-Phase-6 value. 8-bit display clamp at 255 (matches emu hud_nr_ch).
    output reg [7:0]  cur_pgm,
    // Phase 6: chapter total (nr_of_ptts of the current title) for the HUD's
    // "CH n/N" N. 0 = no PTT table -> HUD falls back to cmd_nr_pgm. On movies
    // nr_ptt == cmd_nr_pgm (== nr_of_programs).
    output     [10:0] nr_ptt_o,

    // PGC / cell playback events + metadata (Phase-4 VM inputs; still handling
    // uses them internally already)
    output reg        cell_end_pulse,
    output reg        pgc_end_pulse,
    output reg [7:0]  pgc_still_time,   // PGC still_time @163
    // PGC total playback time (PGC@4, dvd_time_t: {hh,mm,ss,ff|rate}, all BCD).
    // Phase-7 nav foundation: the TITLE's total running time for the UI/overlay
    // "current / total" readout (the DSI supplies current time). Captured at the
    // PGC header, already resident in the rbuf shadow - no extra fetch/BRAM.
    output reg [31:0] pgc_playback_time,
    output reg [15:0] next_pgcn,        // PGC next/prev/goup @156/158/160 (full u16)
    output reg [15:0] prev_pgcn,
    output reg [15:0] goup_pgcn,
    // Phase 11: BCD dvd_time START of the playing cell within the title (the
    // per-cell playback-time prefix sum, built during the P_CELL walk). emu
    // adds nav_dsi's cell-relative c_eltm to it (bcd_time_add) for the HUD's
    // whole-title elapsed readout. Valid in cell_mode; multi-angle blocks
    // over-count (all angles' cells are summed) — documented limitation.
    output reg [31:0] cur_cell_start,
    // Phase 11 stretch: cell first_sector write TAP (streamed during the
    // P_CELL walk, like the pm_* stream) — dvd/seek_bar.sv shadows the cell
    // and program maps from these to place its chapter ticks, with no extra
    // read port on the reader's own BRAMs.
    output reg        cellf_we,
    output reg [6:0]  cellf_idx,
    output reg [31:0] cellf_rbn,
    output     [7:0]  cur_cell_still,   // current cell's still_time (cell@2)
    output     [7:0]  cur_cell_cmdnr,   // current cell's cell_cmd_nr (cell@3)

    // Title RBN span (VTSTT_VOBS, 2048-sector) for the seek position indicator:
    // first cell's first_sector .. last cell's last_sector, captured at PGC load.
    output reg [31:0] title_first_rbn,
    output reg [31:0] title_last_rbn,

    // Menu aspect ratio from the IFO video attributes (NOT the MPEG sequence
    // header). DVD menus are commonly authored 16:9 ANAMORPHIC while their VOB
    // sequence header still carries the 4:3 aspect code (e.g. Matrix VTS_02
    // menu: VTSM_V_ATR=16:9 but the menu VOB seq-hdr=4:3) - a spec-correct
    // player takes the aspect from VTSM_V_ATR@0x100 / VMGM_V_ATR@0x100, which is
    // what VLC does. Captured at each menu (VTSM/VMGM) load; emu uses it for the
    // Auto aspect while a menu is active (titles keep the seq-header path).
    // 1 = the loaded menu domain is 16:9 (display aspect bits 11:10 == 3).
    output reg        menu_ar_wide,

    // hps_io sd_* interface (directly connected)
    output reg [31:0] sd_lba,
    output reg        sd_rd,
    input             sd_ack,
    input      [13:0] sd_buff_addr, // byte address within the 2048-byte block
    input      [7:0]  sd_buff_dout, // data from HPS
    input             sd_buff_wr,   // write strobe

    // Output to ps_stream_fifo / mpeg2video
    output reg  [7:0] stream_data,
    output reg        stream_valid,
    input             busy,         // backpressure (fifo_almost_full)

    // PGC palette (IFO @164, 16 x {0,Y,Cr,Cb}) streamed at PGC load -> pgc_palette.
    // Phase-1 disc menus: gives DVD subpictures/menus their authored colours.
    output reg        pal_we,
    output reg [3:0]  pal_waddr,
    output reg [31:0] pal_wdata,

    // PGC stream-control tables, streamed at PGC load on ONE shared bus:
    //   waddr  0..15 = subp_control[16] (IFO @ PGC+0x1C, 32-bit each): LOGICAL
    //                  subpicture stream (SPRM2/SetSTN) -> PHYSICAL substream id
    //                  (0x20+N) per video display mode - needed to render
    //                  in-title HLI button graphics (Matrix "Follow the White
    //                  Rabbit" rides substream 0x22/0x23 on logical stream 1).
    //   waddr 16..23 = audio_control[8] (IFO @ PGC+0x0C, u16 each, in
    //                  wdata[15:0]): bit15 = stream available, bits[10:8] =
    //                  PHYSICAL audio stream number. The libdvdnav
    //                  vm_get_audio_stream mapping (vmget.c) - without it SPRM1/
    //                  the user's track pick is a RAW substream index and any
    //                  disc with a non-identity map (GET_SMART VTS2: everything
    //                  -> 0x83) plays SILENT. audio_control is walked in EVERY
    //                  domain (menus resolve logical 0 through it, per vmget.c);
    //                  subp_control stays title-only. See docs/dvd_nav.md.
    output reg        pgc_ctl_we,
    output reg [4:0]  pgc_ctl_waddr,
    output reg [31:0] pgc_ctl_wdata,
    // High while the streamed audio_control words above are COMPLETE and
    // consistent with the loaded PGC: cleared at S_PGC_HDR (a new PGC's parse),
    // set when the P_ACTL walk finishes. Doubles as "any PGC has been parsed" -
    // 0 from reset until the first PGC (linear .VOB/.mpg playback stays 0
    // forever), which emu maps to the IDENTITY mapping = pre-fork behaviour.
    output reg        pgc_ctl_valid,
    // Domain of the audio_control above (1 = title). Latched WITH pgc_ctl_valid
    // because libdvdnav's rule differs by domain (menus force logical 0). NOTE:
    // menu_dom is NOT a substitute - it reads 0 for DOM_FP, which must also
    // take the non-title rule.
    output reg        pgc_dom_tt,

    // Raw MODE2/2352 mode readback: the mounted image is a raw CD sector dump
    // (VCD/SVCD bin/cue data track). The reader strips the 2352-byte sector
    // wrapper in-line (Form-2 payloads only) and streams the contained
    // MPEG-1/MPEG-2 system stream. emu uses this for the transport gating.
    output            raw_mode_o,

    // Linear (non-cell) transport. flat_seek_en (from emu = ps_demux saw a
    // pack) qualifies seeking on a PLAIN flat file: a flat seek lands at an
    // arbitrary byte offset and the demux resets per-jump, so emission is
    // gated by a post-seek pack hunt (drop until 00 00 01 BA) — meaningless
    // for a raw elementary stream (.m2v: no packs, no audio), which therefore
    // stays linear-only. Raw MODE2/2352 mode needs no hunt (every sector is a
    // pack boundary) and no qualifier. lin_seek_ok_o gates the emu transport
    // UI; lin_blk_o is the linear playhead for the seek bar.
    input             flat_seek_en,
    output            lin_seek_ok_o,
    output     [31:0] lin_blk_o,

    // Debug / overlay taps
    output            debug_active,
    output            debug_sd_rd,
    output            debug_sd_ack,
    output            debug_cache_has_data,
    output     [15:0] debug_file_size,      // low 16 bits of file_size
    output     [15:0] debug_total_sectors,  // low 16 bits of total 2048-sectors
    output     [15:0] debug_next_lba,       // low 16 bits of current sd_lba
    output     [15:0] debug_state,          // {iso_mode, iso_error, best_cnt, state}
    output            debug_iso_mode,       // 1 = ISO path taken
    output            debug_iso_error,      // 1 = ISO9660 seen but no playable title
    // DVD-FORK DEBUG (Atmosfear wrong-title diagnosis): the VTS the reader
    // RESOLVED a title jump to (target_vtsn) vs. what it will STREAM (play_vtsn
    // = sel_valid ? target_vtsn : best_vtsn). A JumpTT 66 that ends on 52 shows
    // play_vtsn=52 here.
    output     [7:0]  debug_play_vtsn,
    output     [7:0]  debug_target_vtsn,

    // Last pgc_error's cause, latched at the error site (overlay row 26 —
    // replaced the retired nav_pci dbg_promo probe, 2026-08-27). Format
    // {reason[15:13], nr_srp_sat[12:8], want_pgcn[7:0]}:
    //   1 = PGCIT empty (nr_pgci_srp == 0)
    //   2 = requested PGCN out of the PGCIT/LU's range  <- the failed-menu-link
    //       signature (e.g. a page-2 LinkPGCN valid in one language unit but
    //       not the one the Player Language picked)
    //   3 = malformed pgc_start_byte     4 = JumpTT TT_SRPT resolve failed
    //   5 = no VMGM/VTSM PGCI_UT         6 = malformed PGCI_UT header
    //   7 = VTS / menu VOB not found
    // nr_srp_sat = the PGCIT's SRP count saturated to 31; want_pgcn = the
    // requested PGCN's low byte. Cleared on rst_n only (a diagnostic latch).
    output reg [15:0] dbg_pgcerr
);

// =========================================================================
// Total size in 2048-byte sectors (rounded up)
// =========================================================================
wire [31:0] total_blocks = file_size[42:11] + (file_size[10:0] != 11'd0);

// =========================================================================
// 16 KB circular stream cache (identical scheme to mpg_streamer -> M10K)
// =========================================================================
localparam ADDR_WIDTH  = 14;
localparam CACHE_SIZE  = 2 ** ADDR_WIDTH;   // 16384 (= 8 sectors)
localparam BLK         = 2048;              // sd block size (one DVD sector)

reg  [7:0]            cache_mem [0:CACHE_SIZE-1];
reg  [ADDR_WIDTH-1:0] wr_ptr;
reg  [ADDR_WIDTH-1:0] rd_ptr;
wire [ADDR_WIDTH-1:0] cache_level    = wr_ptr - rd_ptr;
wire                  cache_has_data = (wr_ptr != rd_ptr);
wire                  cache_has_room = (cache_level < CACHE_SIZE - BLK - 1);

reg  [7:0] cache_rd_data;
always @(posedge clk) cache_rd_data <= cache_mem[rd_ptr];

// =========================================================================
// 2 KB parse buffer - one ISO 2048-byte logical sector. SYNCHRONOUS read
// (registered pb_rdata) so it maps to a single M10K, not async LUT-RAM.
// =========================================================================
reg [7:0]  parse_buf [0:2047];
reg [7:0]  pb_rdata;
// read port: combinational address (pb_raddr, below - depends on the fetch
// sequencer regs), registered data => synchronous-read RAM (M10K), 1-cycle latency.

// current-record shadow: first 45 bytes of the record at offset p (or of the
// PVD region being parsed). All field taps read this tiny async array.
localparam FETCH_N = 45;
reg [7:0] rbuf [0:FETCH_N-1];

// =========================================================================
// Phase-10 track-attribute store (title VTS audio/subpicture streams).
// Filled by the S_ATTR sweep from the resident VTSI_MAT sector. 8 audio +
// 8 subpicture entries (the ps_demux substream select is 3-bit, so only the
// low-8 of each 0x8x / 0x2x range is ever routable). Read by emu through a
// single indexed mux (attr_a_sel / attr_s_sel) - NOT an async multi-offset
// parse_buf read, so no LUT-RAM fit blow-up.
// =========================================================================
reg [2:0]  a_fmt_mem  [0:7];    // audio_format
reg [3:0]  a_ch_mem   [0:7];    // channel count (decoded value, 1..8)
reg [15:0] a_lang_mem [0:7];    // ISO-639 language
reg [15:0] s_lang_mem [0:7];    // subpicture language
assign attr_a_fmt  = a_fmt_mem [attr_a_sel];
assign attr_a_ch   = a_ch_mem  [attr_a_sel];
assign attr_a_lang = a_lang_mem[attr_a_sel];
assign attr_s_lang = s_lang_mem[attr_s_sel];

// S_ATTR sweep bookkeeping. attr_addr walks parse_buf; attr_idx/attr_j track
// the current stream and byte-within-stream (stride 8 audio / 6 subp).
reg [10:0] attr_addr;
reg [2:0]  attr_idx;
reg [2:0]  attr_j;
reg        attr_phase;           // 0 = audio table, 1 = subpicture table
reg        attr_cnt_pending;     // 1 = the pending read is a stream-count byte
reg [5:0]  attr_resume;          // FSM state to resume after the sweep
reg [5:0]  ptt_resume;           // Phase 6: state to resume after the PTT-table load

// =========================================================================
// Extent table (2048-sector ranges). Winner slice [best_base..best_base+best_cnt).
// Up to 64 title VOB entries (DVD: <=9 title VOBs per VTS).
// =========================================================================
// DVD-Video allows up to 99 VTS; a many-VTS game disc (Atmosfear = 75 VTS, each
// a short clip) needs the group + extent tables to hold them ALL. At 32/64 the
// reader only enumerated the first 32 VTS -> a JumpTT to a higher VTS number
// wasn't found in S_SELECT and fell back to the largest-VTS (best_vts) = the
// wrong title. 100 covers the spec max. Extent indices are [6:0] (<=127) so they
// already cover 100; only the group counters (grp_count/sel_i) widen to [6:0].
localparam MAXEXT = 100;
// Phase-0 ALM reclaim (2026-07-06): the extent table is now a SYNC-READ M10K
// ({start[31:0], blocks[31:0]} = 64b) instead of two 64×32 async register files.
// The old `all_start[strm_idx]`/`all_blocks[strm_idx]` combinational taps in the
// hot streaming path synthesised as 64:1 32-bit muxes on top of ~4k flops (the
// bulk of the module's ALMs). A single registered read port at `strm_idx` maps it
// to 1 M10K; the FSM uses the registered `ext_start_q`/`ext_blocks_q` and detours
// through S_EXT_LOAD (a 1-cycle wait) after any strm_idx change so the read is
// fresh before use. sd reads are ~ms apart, so the extra idle cycle is free.
reg [63:0] ext_mem [0:MAXEXT-1];       // {start[63:32], blocks[31:0]}
reg [31:0] ext_start_q, ext_blocks_q;  // registered read of ext_mem[strm_idx]
reg [6:0]  all_n;

reg [6:0]  best_base;
reg [6:0]  best_cnt;
reg [31:0] best_total;

reg [6:0]  grp_base;
reg [31:0] grp_total;
reg [7:0]  grp_vts;
reg        grp_valid;

// =========================================================================
// Per-VTS group table (for IFO title selection). One entry per title-VOB
// group in VIDEO_TS, filled at each group-close alongside the largest-VTS
// tracking. IFO selection scans this for the VTS that holds title 1.
// =========================================================================
localparam MAXGRP = 100;  // was 32 (see MAXEXT note): hold up to 99 VTS
// Phase-0 ALM reclaim (2026-07-06): group table is a SYNC-READ M10K packed as
// {vts[8], base[7], cnt[7], ifo_lba[32], menu_lba[32], menu_blk[32]} = 118b,
// read at `sel_i` during S_SELECT (a scan) via a registered port + a 1-cycle
// wait state (S_SELECT2). Replaces four 32-entry async register files. Runs
// once per mount, so 2 cycles/step is free. Phase-2 widened the row with the
// per-VTS menu VOB extent (VTS_xx_0.VOB = VTSM_VOBS: ISO LBA + 2048-sectors).
localparam GMEM_W = 8 + 7 + 7 + 32 + 32 + 32;   // 118
reg [GMEM_W-1:0] gmem [0:MAXGRP-1];   // {vts, base, cnt, ifo_lba, menu_lba, menu_blk}
reg [GMEM_W-1:0] gmem_q;              // registered read of gmem[sel_i]
reg [6:0]  grp_count;   // widened for MAXGRP=100

// Per-VTS VTS_xx_0.IFO (VTSI) LBA capture. The _0.IFO name-sorts just before the
// group's title VOBs, so we latch it "pending" and commit it to the open group.
// Same scheme for VTS_xx_0.VOB (the VTS menu VOB, name-sorts after _0.IFO).
reg [31:0] pending_ifo_lba;  // last-seen VTS_xx_0.IFO LBA
reg [7:0]  pending_ifo_vts;  // its VTS number
reg [31:0] pending_mnu_lba;  // last-seen VTS_xx_0.VOB LBA (menu VOB)
reg [31:0] pending_mnu_blk;  // its length in 2048-sectors
reg [7:0]  pending_mnu_vts;  // its VTS number
reg [31:0] grp_ifo_lba;      // current open group's VTSI LBA
reg [31:0] grp_mnu_lba;      // current open group's menu VOB LBA (0 = none)
reg [31:0] grp_mnu_blk;      // current open group's menu VOB 2048-sectors
reg [31:0] best_ifo_lba;     // VTSI LBA of the largest-VTS group (fallback)
reg [7:0]  best_vtsn;        // VTS number of the largest-VTS group
reg [31:0] best_mnu_blk;     // largest menu VOB seen (2048-sectors)
reg [7:0]  best_mnu_vts;     // its VTS number (0 = none)
reg [31:0] sel_ifo_lba;      // VTSI LBA of the IFO-selected group

// VMG menu VOB (VIDEO_TS.VOB = VMGM_VOBS) extent, captured in the walk.
reg [31:0] vmgm_vob_lba;     // ISO LBA (0 = absent)
reg [31:0] vmgm_vob_blk;     // length in 2048-sectors

// IFO (VMGI / TT_SRPT) navigation + selection
reg [31:0] vmgi_lba;      // ISO LBA of VIDEO_TS.IFO (the VMGI)
reg        vmgi_found;    // VIDEO_TS.IFO record seen during the VIDEO_TS walk
reg [7:0]  target_vtsn;   // VTS number holding title 1 (from TT_SRPT)
reg [6:0]  sel_base;      // IFO-selected group's extent base
reg [6:0]  sel_cnt;       // IFO-selected group's extent count
reg        sel_valid;     // 1 = IFO selection succeeded (else use largest)
reg [6:0]  sel_i;         // group-scan cursor (widened for MAXGRP=100)

// Effective winner: IFO selection if it succeeded, else the largest-VTS.
wire [6:0]  eff_base    = sel_valid ? sel_base    : best_base;
wire [6:0]  eff_cnt     = sel_valid ? sel_cnt     : best_cnt;
wire [31:0] eff_ifo_lba = sel_valid ? sel_ifo_lba : best_ifo_lba;

// =========================================================================
// PGC / cell timeline (Phase 7). After the title VTS is chosen we parse its
// VTS_xx_0.IFO (VTSI_MAT -> VTS_PGCIT -> PGC) and stream the PGC's CELLS in
// program order instead of the VTS title VOBs linearly. All IFO fields are
// BIG-ENDIAN. Cell first_sector/last_sector are 2048-sector RBNs relative to
// VTSTT_VOBS (= the title VOB start = all_start[eff_base]); we map them through
// the extent table into absolute sd 2048-sectors. Any malformed/absent PGC falls
// back to the existing linear whole-VTS streaming (cell_mode=0). Deferred
// (hooks noted below): program_map (chapters), palette@164 (subpicture),
// cell category word@0 (angles), VTS_PTT_SRPT for the exact TTN->PGC map.
// =========================================================================
localparam MAXCELL = 255;             // max cells parsed (DVD nr_of_cells is 1 byte =
                                      // up to 255; was 128 -> a >128-cell title fell to
                                      // linear fallback losing cell-granular nav). The
                                      // cell_*_mem arrays size off this; cell_raddr/
                                      // cell_i/cell_count are already [7:0] (cover 255).
// Cell list held in SYNCHRONOUS-read BRAM (like parse_buf/cache_mem) - NEVER
// async-indexed (a 128-entry async register file blew the fitter to 106% ALMs).
// Only one cell is read at a time via cell_raddr -> cf_rd/cl_rd (1-cycle latency);
// cell_raddr stays fixed while a cell streams, so cf_rd/cl_rd track the current
// cell. S_CELL_LOAD/S_CELL_LOAD2 cover the read latency before each cell.
reg [31:0] cell_first_mem [0:MAXCELL-1];  // cell first_sector (2048-sector RBN)
reg [31:0] cell_last_mem  [0:MAXCELL-1];  // cell last_sector  (2048-sector RBN, incl)
reg [31:0] cell_start_mem [0:MAXCELL-1];  // Phase 11: BCD start time (prefix sum)
reg [32:0] cell_meta_mem  [0:MAXCELL-1];  // {heur, pb_secs[15:0]@4-7, still_time@2,
                                          //  cell_cmd_nr@3}. pb_secs = authored
                                          // playback time (C_PBTM) in binary seconds,
                                          // the FRAME field rounded in (pb_dur_w:
                                          // "1 s + 24 f" = 1.96 s stores as 2, not 1),
                                          // clamped at the SPEC MAX 9:59:59 = 35,999 s
                                          // (spec-hardening Phase 6; was 255) - the
                                          // authored-cell-duration hold source. heur =
                                          // the still byte came from the libdvdnav
                                          // playback-time heuristic (so a timed still
                                          // may hold the full 16-bit duration instead
                                          // of the byte's 254 s clamp).
reg [7:0]  cell_cat_mem   [0:MAXCELL-1];  // cell category byte@0 (Phase 9 angles)
reg [7:0]  cell_raddr;                     // BRAM read address (current cell)
reg [31:0] cf_rd, cl_rd;                   // registered first/last for cell_raddr
reg [32:0] cm_rd;                          // registered {heur, pb_secs, still, cmd_nr} for cell_raddr
reg [7:0]  cc_rd;                          // registered category byte for cell_raddr

// ---- Multi-angle (Phase 9) + seamless-branch (interleaved) ILVU state ------
// cell category byte@0: block_mode = [7:6] (0 none,1 first,2 in,3 last of block),
// block_type = [5:4] (1 = angle block), interleaved = [2]. An angle block = the
// consecutive run of block_type==1 cells; angle N = block_first + (N-1).
//
// SEAMLESS-BRANCH cells (Matrix "Follow the White Rabbit" chapters, T2 Ultimate
// extended scenes) use interleaved=1 with block_mode=0/block_type=0 (NOT the
// angle encoding), so cc_is_angle is false and they fall through to the title
// path. Their [first..last] range physically INTERLEAVES this branch's ILVUs
// with sibling-branch ILVUs; reading it linearly plays main/sibling/main = the
// "skipping". Unlike angles there is no user selection and no sml_agli: the
// correct branch is followed by chasing vobu_sri.next_vobu, which at each
// BLOCK|LAST VOBU jumps PAST the sibling ILVU to this branch's next ILVU (this
// is libdvdnav's DEFAULT vobu_next path; the sml_agli case is num_angle!=0 only).
// See docs/dvd_nav.md "Seamless-branch interleaved blocks".
wire       cc_is_angle = (cc_rd[5:4] == 2'd1);        // block_type == angle block
wire       cc_blk_first= cc_is_angle && (cc_rd[7:6] == 2'd1);
wire       cc_interleaved = cc_rd[2];                 // interleaved (seamless-branch) cell
reg [7:0]  block_first;                     // first (angle-1) cell of the block
reg [7:0]  block_last;                      // last angle cell (block_first+count-1)
reg        angle_active;                    // 1 = streaming an angle-block cell
reg        angle_resolved;                  // 1 = angle cell chosen (skip re-scan)
reg [7:0]  ang_scan_i;                      // angle-count scan cursor
reg        angle_pulse_d;                   // rising-edge detect for angle_pulse
reg        seamless_active;                 // 1 = streaming an interleaved (non-angle) cell

// NV_PCK snoop: capture DSI fields off the sd_buff write stream of a nav
// sector's DSI region (sector bytes 0x400..0x5FF, DSI data @0x407). Angle + seamless.
reg [31:0] snoop_sig;                        // 0x400..0x403 (want 00 00 01 BF = DSI PES)
reg [7:0]  snoop_sub;                        // 0x406 (want 0x01 = DSI substream)
reg [31:0] snoop_ea;                         // vobu_ea  (DSI @0x08 -> sector 0x40F)
reg [15:0] snoop_cat;                        // category (DSI @0x20 -> sector 0x427)
reg [31:0] snoop_agli;                        // sml_agli[cur_angle-1].address (angle)
reg [31:0] snoop_nextv;                      // vobu_sri.next_vobu (DSI @0x13A -> sector 0x541)
reg [31:0] snoop_rbn;                         // this nav sector's RBN (= play_blk)
reg        snoop_done;                        // pulse: a nav sector's block-2 finished
wire       ilvu_active = angle_active || seamless_active;   // snoop/jump gate

// Armed ILVU jump: fire a no-flush RBN jump when play_blk passes ilvu_end_rbn.
reg        ilvu_armed;
reg [31:0] ilvu_end_rbn;                     // last sector of the ILVU_LAST VOBU
reg [31:0] ilvu_target;                      // next-ILVU RBN for the current angle
reg [7:0]  cell_count;                // number of cells parsed
reg [7:0]  cell_i;                    // streaming cell cursor
reg        cell_mode;                 // 1 = stream by cell list, 0 = linear extents

// Transport seek: a request is LATCHED here and executed only when no sd block
// is in flight (blk_inflight=0) -- the outstanding read must finish first, or
// the framework's remaining beats would land in the post-seek cache as stale
// bytes. seek_jump (defined after blk_inflight below) is the actual jump cycle,
// used by the FSM and the output pipeline reset. See docs/dvd_nav.md "Transport".
reg        seek_pending;
reg [7:0]  seek_cell_l;
reg        seek_is_rbn;               // 1 = latched seek is a raw-RBN scrub
reg [31:0] seek_rbn_l;                // latched target RBN (2048-sector)
reg        rbn_override;              // S_CELL_LOAD2: use seek_rbn_l, not cf_rd
reg [7:0]  rbn_scan_i;                // S_RBN_SCAN containing-cell scan cursor
reg [31:0] nav_cand;                  // S_NAV_SEEK: candidate RBN (raw target upward)
reg [10:0] nav_left;                  // S_NAV_SEEK: remaining probe budget

// Chapter (PTT) skip: a small mini-FSM (chap_st) parallel to the main state
// machine. It walks the PGC program_map BRAM (pmap_mem: program -> entry cell#,
// 1-based) against the current cell (cell_i) to find the current chapter, picks
// the prev/next target, and sets seek_pending/seek_cell_l -> the normal
// seek_jump path executes it. See docs/dvd_nav.md "Seeking / Phase 8".
// Cross-PGC (spec-hardening Phase-5 follow-up): when the target chapter lives
// in ANOTHER PGC of the title (multi-PGC game discs: Scene_It 798 PTTs), the
// CH_G* states reverse-map the position through ptt_mem and dispatch an
// internal JumpVTS_PTT-shaped jump instead (see CH_T2 below).
reg [7:0]  pmap_mem [0:127];          // program_map: pmap[p] = entry cell (1-based)
reg [7:0]  pm_rd_q;                   // sync read of pmap_mem[pm_raddr]
reg [6:0]  pm_raddr;
localparam CH_IDLE=4'd0, CH_A=4'd1, CH_B=4'd2, CH_R=4'd5, CH_C=4'd3, CH_D=4'd4,
           // Cross-PGC chapter skip (spec-hardening Phase-5 follow-up): the
           // global PTT reverse-map scan + target resolve, wired between the
           // program-map walk (CH_A/CH_B) and the legacy resolve/seek states.
           CH_G0=4'd6, CH_G=4'd7, CH_GR=4'd8, CH_T=4'd9, CH_T2=4'd10;
reg [3:0]  chap_st;
reg [6:0]  chap_p;                    // scan cursor (program index, 0-based)
reg [6:0]  chap_best;                 // current chapter (largest start <= cell_i)
reg [7:0]  chap_best_cell;            // start cell (0-based) of chap_best
reg        chap_dir_l;
reg [4:0]  chap_mag_l;                // magnitude latched at the chap_pulse (>=1)
reg [6:0]  chap_tp;                   // resolved target program
reg        chap_do;                   // 1 = the resolved skip is a real move
reg        chap_at_start_l;           // chap_at_start latched at the chap_pulse
// Phase 11: query-only reuse of the same walk -> cur_pgm (chapter for the HUD).
// A real chap_pulse pre-empts an in-flight query (chap_go restarts the FSM);
// pgm_q_cell remembers which cell was last queried (FF = force a re-query).
reg        chap_query;                // 1 = the running walk is a cur_pgm query
reg [7:0]  pgm_q_cell;                // cell_i the last query ran for
// Multi-chapter target resolution (combinational; used in CH_R). chap_best is the
// current chapter (0-based); jump chap_mag_l chapters, clamped to the title range.
wire [7:0] chap_next_sum = {1'b0, chap_best} + {3'd0, chap_mag_l};   // best + mag
wire [6:0] chap_last     = (cmd_nr_pgm[6:0] != 7'd0) ? cmd_nr_pgm[6:0] - 7'd1 : 7'd0;
wire [6:0] chap_next_tp  = (chap_next_sum > {1'b0, chap_last}) ? chap_last
                                                              : chap_next_sum[6:0];
// prev: the first step restarts the current chapter unless we're already past its
// start, so the effective decrement is (mag-1) mid-chapter, mag from the start.
wire       chap_past_st  = (cell_i > chap_best_cell) || !chap_at_start_l;
wire [4:0] chap_dec      = chap_past_st ? (chap_mag_l - 5'd1) : chap_mag_l;
wire [6:0] chap_prev_tp  = ({2'd0, chap_dec} >= chap_best) ? 7'd0
                                                          : chap_best - {2'd0, chap_dec};

// ---- Cross-PGC chapter skip: global PTT reverse map (CH_G*/CH_T*) ---------
// After the program-map walk settles chap_best (current PROGRAM within the
// loaded PGC), a title with a resident PTT table (nr_ptt != 0) runs a
// one-entry-per-cycle scan of ptt_mem (sync-read, pipelined address — the fit
// discipline: no async indexing) to reverse-map {cur_pgcn, program} -> the
// GLOBAL chapter index g_best (0-based; last entry of cur_pgcn with
// pgn <= current program). g_pgc_first/g_pgc_last bound the current PGC's run
// of entries so CH_GR can tell whether a clamped within-PGC move actually has
// somewhere to go in that direction. Single-PGC (movie) titles always have
// g_pgc_first==0 && g_pgc_last==nr_ptt-1, so they take the LEGACY program-map
// resolve structurally — bit-identical to the pre-cross-PGC behaviour.
// (Assumes each PGC's PTT entries form one contiguous playback-ordered run —
// true of real authoring; a pathological split run would just mis-bound the
// boundary test, degrading to a within-PGC clamp.)
reg  [9:0] g_i;                       // scan cursor
reg  [9:0] g_best;                    // global index of the current chapter
reg        g_found;                   // reverse map hit (cur_pgcn matched)
reg        g_seen;                    // first cur_pgcn entry seen (g_pgc_first valid)
reg  [9:0] g_pgc_first, g_pgc_last;   // global index bounds of cur_pgcn's entries
reg  [9:0] g_t;                       // resolved global target (CH_T read address)
// (g_next_t / g_prev_t target wires live below the nr_ptt declaration)

// ---- Phase 6: exact chapters / PTT ------------------------------------
// Resident PTT table for the CURRENTLY-PLAYING title: ptt_mem[c] = {pgcn,pgn}
// of chapter c+1, loaded at title mount (P_PTT walker) from VTS_PTT_SRPT.
// CONSUMED (read side wired, spec-hardening Phase-5 follow-up) by the CH_G*
// chapter states: the exact reverse map (current chapter -> HUD cur_pgm) and
// the cross-PGC user skip. Capped at PTT_CAP (Phase 5: 256 -> 1024. nr_of_ptts is
// u16 by spec and GAME titles author hundreds -- the Phase-1 library audit
// found Scene_It title 1 = 798 and PNP0NNS1 title 29 = 369, both clamped by
// the old 256. 1024 covers the JumpVTS_PTT operand's full 10-bit range; a
// hypothetical >1024 title still clamps the user-skip/HUD gracefully -- VM
// JumpVTS_PTT is unaffected either way, it resolves the part on-demand in
// S_PTT_*). Sync-read M10K, no async indexing (fit).
localparam PTT_CAP = 11'd1024;
reg [23:0] ptt_mem [0:1023];          // {pgcn[15:0], pgn[7:0]} - pgcn is a 15-bit field
reg [23:0] ptt_rd_q;                  // sync read of ptt_mem[ptt_raddr]
reg [9:0]  ptt_raddr;
reg        ptt_we;                    // P_PTT write strobe
reg [9:0]  ptt_waddr;
reg [23:0] ptt_wdata;
reg [10:0] nr_ptt;                    // chapter count of the current title (0 = none)
reg [6:0]  cur_ttn;                   // vts_ttn of the loaded title (for the PTT map)
reg [15:0] ptt_pgcn_c;                // P_PTT: captured pgcn (u16) of the entry
// PTT-load bookkeeping (VTS_PTT_SRPT header + TTU span)
reg [15:0] ptt_nr_srpt;              // nr_of_srpts of the VTS_PTT_SRPT
reg [31:0] ptt_last_byte;            // last_byte @4
reg [20:0] ptt_base_off;            // byte offset of cur_ttn's TTU (rel VTS_PTT_SRPT)

always @(posedge clk) begin
    if (ptt_we) ptt_mem[ptt_waddr] <= ptt_wdata;
    ptt_rd_q <= ptt_mem[ptt_raddr];
end
assign nr_ptt_o = nr_ptt;

// Cross-PGC skip target math (global chapter space; consulted only when
// nr_ptt != 0, so nr_ptt-1 never underflows).
wire [10:0] g_next_sum = {1'b0, g_best} + {6'd0, chap_mag_l};
wire [10:0] g_nr_m1    = nr_ptt - 11'd1;
wire [9:0]  g_last_idx = g_nr_m1[9:0];
wire [9:0]  g_next_t   = (g_next_sum > {1'b0, g_last_idx}) ? g_last_idx
                                                           : g_next_sum[9:0];
// prev reuses chap_dec (the restart-current-chapter rule) in global space
wire [9:0]  g_prev_t   = ({5'd0, chap_dec} >= g_best) ? 10'd0
                                                      : g_best - {5'd0, chap_dec};

// program_map BRAM: sync read/write (M10K). Written in lockstep with the VM
// program-map stream (pm_we/pm_waddr/pm_wdata) during PGC parse.
always @(posedge clk) begin
    if (pm_we) pmap_mem[pm_waddr] <= pm_wdata;
    pm_rd_q <= pmap_mem[pm_raddr];
end

// PGC-parse scratch (sector,offset pairs to avoid 34-bit byte math).
// Phase 2 generalized the parse: (pit_sec, pit_off) hold the ACTIVE PGCIT --
// the title VTS_PGCIT (sector-aligned, pit_off=0) OR a menu PGCIT reached
// through a PGCI_UT LU (byte offset rel. to the UT) -- and they PERSIST while
// the domain is loaded, so a PGC-to-PGC move (LinkPGCN follow / next_pgcn /
// menu loop) re-enters at S_SRP_FETCH without re-walking the IFO.
reg [31:0] pit_sec;                   // abs LBA of the sector holding the PGCIT start
reg [10:0] pit_off;                   // byte offset of the PGCIT within pit_sec
reg [15:0] nr_srp_l;                  // nr of SRPs in the active PGCIT
reg [31:0] pgc_sec;                   // abs LBA of the sector holding the PGC start
reg [10:0] pgc_off;                   // byte offset of the PGC within pgc_sec
reg [7:0]  nr_cells;                  // nr_of_cells from the PGC header
reg [15:0] cmd_tbl_off;               // PGC command_tbl_offset @228 (0 = none)
reg [15:0] cell_pb_off16;             // PGC cell_playback_offset @232
reg [15:0] cur_pgcn;                  // PGCN (1-based) of the loaded PGC (0 = FP)

// Jump/domain state. dom follows the DVD-VM domain encoding of jump_domain.
localparam DOM_FP = 2'd0, DOM_VMGM = 2'd1, DOM_VTSM = 2'd2, DOM_TT = 2'd3;
reg [1:0]  dom;                       // domain of the loaded PGC
reg        menu_dom;                  // dom is VMGM/VTSM (menu VOB streaming)

// Real chapter-skip walk arm (may pre-empt an in-flight cur_pgm query walk).
// Cross-PGC: nr_ptt > 1 also arms it — a 1-program PGC inside a multi-chapter
// title (the Scene_It shape) can now skip OUT of its PGC via the PTT table.
wire chap_go = chap_pulse && cell_mode && !menu_dom &&
               (cmd_nr_pgm > 8'd1 || nr_ptt > 11'd1) &&
               (chap_st == CH_IDLE || chap_query) && !seek_pending;
reg        jump_pending;              // a jump is latched awaiting a block boundary
reg        jump_ctx;                  // parsing under a JUMP (errors -> pgc_error, not linear)
reg [1:0]  jdom_l;                    // latched jump request
reg [7:0]  jvts_l, jcell_l;
reg [15:0] jpgcn_l;                   // 15-bit DVD PGCN field
reg [3:0]  jentry_l;
reg [6:0]  jttn_l;                    // Phase-4: TT title-entry scan target
reg [7:0]  jpgn_l;                    // Phase-4: TT start program (pm walk latch)
reg [10:0] jptt_l;                    // Phase-6: exact PTT part to resolve (0/1 = PTT[0]).
                                      // 11-bit: the VM operand is 10-bit (part <= 1023)
                                      // but the internal cross-PGC skip can target
                                      // chapter 1024 (= PTT_CAP, the table's last entry).
reg        use_jcell;                 // start streaming at jcell_l (TT resume)
reg [15:0] want_pgcn;                 // SRP select: 0 = scan for want_entry/ttn
reg [3:0]  want_entry;                // menu entry type to scan for
reg [6:0]  want_ttn;                  // title number to scan for (TT domain)
reg        scan_mode;                 // 1 = S_SRP_EVAL is entry-scanning
reg        scan_title;                // 1 = the scan matches TITLE numbers
reg [15:0] srp_i;                     // SRP cursor (PGCITs can exceed 255 entries)
reg        sel_ret;                   // S_SELECT return: 0=title (S_PGC_BEGIN), 1=VTSM menu
reg [31:0] jmp_ifo_lba;               // VTSI LBA of a VTSM jump target
reg [31:0] ptt_srpt_lba;              // abs LBA of the VTS_PTT_SRPT (PTT resolve)
reg [31:0] jmp_ut_lba;                // abs LBA of the active PGCI_UT
// Phase 4 PGCI_UT language-unit walk (S_LU_EVAL)
reg [6:0]  lu_i;                      // LU scan cursor
reg [6:0]  lu_n;                      // nr_of_lus latched (rbuf gets re-shadowed)
reg [31:0] lu0_st;                    // LU[0].lang_start_byte (the fallback)
reg [31:0] menu_base_blk;             // menu VOB base (2048-sector LBA)
reg [31:0] menu_blocks;               // menu VOB length in 2048-sectors (cell bound)
reg [7:0]  play_vtsn;                 // VTS of the loaded TITLE (cur_vts export)
reg        nav_ready;                 // VIDEO_TS walk finished (jumps accepted)
reg        still_pend;                // menu still reached: drain cache then S_STILL
reg        still_flushed;             // menu still already cold-re-decoded (§5, once per entry)
// TIMED STILLS (Phase 5): an authored ad/copyright/menu-intro still holds for a
// bounded time then auto-advances (libdvdnav honours the same). still_timed marks
// a finite (1..254 s) hold; still_secs counts it down at 1 Hz in S_STILL;
// still_next encodes the action to run when the timer (or a button) fires.
localparam STILL_NEXT = 2'd0;   // advance to the next cell
localparam STILL_CMD  = 2'd1;   // run the cell command (vm_cell_cmd)
localparam STILL_PGEND= 2'd2;   // PGC end -> POST (vm_pgc_end)
reg        still_timed;               // 1 = finite hold (auto-advance), 0 = indefinite (0xFF)
reg [15:0] still_secs;                // seconds remaining (16-bit: a duration-
                                      // residual hold can exceed 255 s, Phase 6)
reg [1:0]  still_next;                // deferred action after the timer/button
reg        still_last;                // the still cell was the PGC's last cell

// ---- AUTHORED CELL DURATION (real-player cell timing) --------------------
// A cell's presentation lasts its authored playback time (C_PBTM); the reader
// used to end a cell when its SECTORS were delivered. For ordinary cells the
// two nearly coincide, but a still-image cell diverges completely (Weakest
// Link's 17 s answer window = ONE I-frame in 311 sectors, delivered in ~0.2 s
// - the cell command ran 16.8 s early). cell_secs counts DISPLAY time
// (disp_tick / disp_fps) since the cell loaded; when a title-domain cell-end
// would dispatch to the VM (cell command / PGC end) with >= RESID_MIN seconds
// of its authored duration unspent, the residual is served as a TIMED STILL
// (the HW-proven Thayer machinery) before the dispatch, so the command runs
// at the cell's authored end - like a real player. See docs/dvd_nav.md
// "authored cell duration" and docs/disc_sweep.md "Round-6".
//
// Scope guards (why each exists):
//  - vm_mode && !menu_dom : menus keep their loop/still semantics (HW-tuned);
//    menus-off playback is exactly as before.
//  - cell-end paths that already dispatch/wait ONLY (cell command, PGC end):
//    the plain mid-PGC advance stays seamless - there the parse front leads
//    the display by the buffered depth by DESIGN, so "authored time not yet
//    elapsed since load" is the normal steady state, not a still.
//  - !angle_active && !seamless_active : interleaved (ILVU) blocks never hold.
//  - !cell_partial : a mid-cell entry (raw-RBN scrub, ILVU hop) breaks the
//    "elapsed since load" measurement -> hold disabled for that cell (a user
//    seek must stay immediate anyway - the PR #150 provenance discipline).
//  - RESID_MIN absorbs measurement slack (load->display latency, sub-second
//    truncation) so an ordinary cell can never gain a visible hitch.
// cell_secs saturates at 16'hFFFF, above the 35,999 s C_PBTM spec max (the
// Phase-6 clamp widening), so a long cell stops qualifying once its full
// authored duration has displayed - never a spurious hold.
//
// The authored duration read here (cell_dur_w) is the FRAME-ROUNDED C_PBTM
// (see pb_dur_w at the cell-meta write): before that rounding a "1 s + 24 f"
// = 1.96 s screen stored as 1 s, and 1 < RESID_MIN meant it got NO hold at
// all - the Weakest Link answer-reveal / money-banked flash (2026-08-25).
// RESID_MIN stays at 2 deliberately: with the rounding in place a genuine
// 2 s screen qualifies, while sub-second cells (0 s + n f, e.g. Deal or No
// Deal's ~1800 half-second cells) round to 1 and still take no hold - the
// same behaviour they have today, so no disc gains a new hitch.
localparam RESID_MIN = 16'd2;         // min unspent seconds worth holding for
reg [15:0] cell_secs;                 // display seconds since this cell loaded
reg [5:0]  cell_refr;                 // sub-second display-refresh counter
reg        cell_partial;              // 1 = cell entered mid-content: no duration hold
reg        st_was_cl;                 // S_CELL_LOAD entry edge detect
reg [24:0] sec_pre;                   // clk_sys prescaler -> 1 Hz tick
reg        sec_tick;                  // 1-cycle pulse once per second while timing a still
reg        adv_pend;                  // authored next_pgcn reached: drain, then re-enter PGCIT
// 0-cell menu entry PGCs (e.g. MiB root) are command stubs ending in LinkPGCN:
// remember the last unconditional (preferred) / conditional LinkPGCN target
// seen in the PRE commands and follow it, depth-limited.
reg [15:0] link_pgcn_u, link_pgcn_c;
reg [1:0]  follow_cnt;

// Sector-crossing byte WALKER. One engine walks parse_buf a byte per 2 cycles
// (S_WALK_RD sets the address, S_WALK_CAP consumes pb_rdata) across sector
// boundaries: whenever walk_sec is not the sector resident in parse_buf
// (pb_sec), S_WALK_RD detours through S_SECREAD (with a skipped rbuf fetch)
// and resumes. Replaces the Phase-1 single-sector palette window (which had
// to SKIP straddling PGCs -- Matrix/T2 menu PGCITs straddle routinely) and
// the per-field cell reads. Phases walk, in order: the PGC header window
// @156..233 (next/prev/goup/mode/still + palette@164 + cmd/prog/cell table
// offsets), the command table (counts + all commands -> cmd_we stream), and
// the cell playback table (-> cell BRAMs, still/cmd_nr meta included).
localparam [2:0] P_HDR = 3'd0, P_CMDH = 3'd1, P_CMD = 3'd2, P_CELL = 3'd3,
                 P_PMAP = 3'd4,      // Phase-4: program-map stream -> dvd_vm
                 P_SUBP = 3'd5,      // subp_control[16] @ PGC+0x1C -> pgc_ctl_we
                 P_PTT  = 3'd6,      // Phase-6: VTS_PTT_SRPT TTU -> ptt_mem
                 P_ACTL = 3'd7;      // audio_control[8] @ PGC+0x0C -> pgc_ctl_we
reg [2:0]  wphase;
reg [31:0] walk_sec;                  // sector being walked
reg [10:0] walk_off;                  // byte offset within walk_sec
reg [12:0] walk_left;                 // bytes remaining in the phase
reg [12:0] walk_idx;                  // byte index within the phase
reg [31:0] pb_sec;                    // sector currently resident in parse_buf
reg [23:0] wacc;                      // rolling byte accumulator (u16/u32 assembly)
reg [15:0] nr_pre16, nr_post16, nr_cellc16;  // raw command counts
reg [15:0] prog_map_off16;            // PGC program_map_offset @230 (0 = none)
// Phase-4 VM-wait context (S_VM_WAIT)
reg        vmw_pgc;                   // 1 = waiting on POST (else a cell cmd)
reg        vmw_last;                  // the waited cell was the PGC's last
reg        vmw_pgc_pend;              // PGC ended (vm_mode): drain, then wait
reg [23:0] vmw_tmr;                   // verdict watchdog (~0.62 s)

// NATURAL-TRANSITION TAIL DRAIN (docs/dvd_nav.md "Tail drain"). A natural
// title-domain PGC end (First Play logo chains, end-of-title -> menu) must
// play out the decoder's ~1 s buffered tail before the POST commands run:
// the POST's jump lands with keep_vbuf=0 (title source), so dispatching
// while the VBUF still holds the tail lets the jump's vbuf_flush cut the
// end of the clip. So the vm_pgc_end dispatch gate ALSO waits for
// vbuf_empty (the HW-proven menu-still cold-re-decode trigger: compressed
// VBUF fill <= 8 KB = tail displayed to within tens of ms). Menu-domain
// ends bypass the wait (keep_vbuf holds their tail; menus stay snappy).
// User actions stay immediate by construction: a VM jump (Menu key) or a
// transport seek executes from S_STREAM regardless of this gate and clears
// vmw_pgc_pend. DRAIN_WD bounds the wait; on timeout the transition
// proceeds with the flush = the old behaviour, never a deadlock. NOTE the
// decoder watchdog needs no suppression here: it only runs while the
// decoder is BUSY (input FIFO backpressured), and a draining/starving
// decoder is not (rtl/mpeg2/watchdog.v decoder_active <= ~busy).
reg [30:0] drain_tmr;   // 31 bits: DRAIN_WD is now 60 s @ 27 MHz
wire       drain_wd_hit = (drain_tmr >= DRAIN_WD);
wire       tail_wait = vmw_pgc_pend && ~menu_dom && ~vbuf_empty && ~drain_wd_hit;

// PHASE B (tail-drain for CELL-COMMAND verdicts, docs/dvd_nav.md). A natural
// title-domain cell command (Thayer's Quest FMV branch cells: LinkTailPGC /
// LinkPGCN at a choice cell) delivers its verdict as a JUMP or SEEK, which
// executed immediately with keep_vbuf=0 and flushed the decoder's ~1 s tail -
// the same cut PR #149 fixed for PGC ends. The DISPATCH must stay ungated
// (a mid-title GPRM cell command's vm_adv verdict would hitch playback);
// instead the resulting jump/seek EXECUTION is gated: jnat_l/snat_l latch the
// VM's provenance (vm_from_wait, qualified ~menu_dom at the latch) with the
// request, and jump_go/seek_jump additionally wait for vbuf_empty - bounded
// by the same DRAIN_WD watchdog, whose enable extends to this window. A
// non-natural (user/boot/menu) jump or seek is never gated.
reg        jnat_l;                 // latched: pending jump is natural (title)
reg        snat_l;                 // latched: pending seek is natural (title)
wire       nat_jump_wait = jump_pending && jnat_l && ~vbuf_empty && ~drain_wd_hit;
wire       nat_seek_wait = seek_pending && snat_l && ~vbuf_empty && ~drain_wd_hit;
assign     nat_wait_o    = nat_jump_wait || nat_seek_wait;

// Counts the whole pending window (cache drain + VBUF drain) and holds its
// value once the bound is hit; any exit that clears the pending source
// (dispatch, jump_go, seek_jump, reset) zeroes it. A natural jump chained
// AFTER a watchdog-released dispatch re-arms the bound (worst case 2x
// DRAIN_WD on a wedged decoder - still strictly bounded, never a deadlock).
always @(posedge clk) begin
    if (!rst_n || !(vmw_pgc_pend || (jump_pending && jnat_l) ||
                    (seek_pending && snat_l)))
        drain_tmr <= 31'd0;
    else if (tail_wait || nat_jump_wait || nat_seek_wait)
        drain_tmr <= drain_tmr + 31'd1;
end
reg [4:0]  cell_bi;                   // byte index within the current 24 B cell entry
reg [7:0]  cell_wi;                   // cell entry being written
reg [7:0]  cm_still_c, cm_cmd_c;      // captured meta for the cell being written
reg [7:0]  cm_cat_c;                  // captured cell category byte@0 (Phase 9)
// libdvdnav still heuristic (vm.c get_current_position 561-596): a menu/ad/
// copyright STILL is often authored with cell still_time@2 == 0 and signalled
// only by a cell whose playback_time exceeds its content duration. Capture the
// extra fields to reconstruct the effective hold at parse time.
reg [31:0] cf_c;                      // cell first_sector @8 (RBN)
reg [31:0] lv_c;                      // cell last_vobu_start_sector @16 (RBN)
reg [7:0]  pbh_c, pbm_c;              // playback_time @4/@5 hour/minute (BCD-decoded)
reg [15:0] pb_c;                      // playback_time in seconds, clamped to the
                                      // C_PBTM spec max 9:59:59 = 35,999 (Phase 6)
reg [7:0]  cmd_b0, cmd_b1, cmd_b6;    // command bytes 0/1/6 (LinkPGCN detect)
reg        pb_skip;                   // next S_SECREAD completion skips the rbuf fetch

// Cell-streaming position (concatenated title-VOB 2048-sector domain = the DVD
// RBN domain). Reuses the existing strm_idx as both the S_CELL_SEEK scan cursor
// and the streaming extent pointer, so the 64-entry extent tables keep a single
// read mux (strm_idx) - no extra index muxes (that pressure contributed to the
// 106% fit).
reg [31:0] play_blk;                  // current concatenated 2048-sector position
reg [31:0] play_end;                  // end (exclusive) sector of the current cell
reg [31:0] ext_cum;                   // concatenated sector base of strm_idx's extent
reg [31:0] seek_cum;                  // S_CELL_SEEK cumulative sector base
reg [31:0] seek_target;               // S_CELL_SEEK target concatenated sector

// =========================================================================
// FSM
// =========================================================================
localparam S_IDLE      = 6'd0;
localparam S_INIT      = 6'd1;
localparam S_SECREAD   = 6'd2;   // gather one 2048 sector (one sd block) -> parse_buf
localparam S_FETCH     = 6'd3;   // copy parse_buf[fetch_base .. +45] -> rbuf
localparam S_CHK_VD0   = 6'd4;   // rbuf@0: CD001 + PVD type check
localparam S_CHK_VD1   = 6'd5;   // rbuf@156: PVD root-dir record
localparam S_WALK_ROOT = 6'd6;   // rbuf@p: find VIDEO_TS
localparam S_WALK_VTS  = 6'd7;   // rbuf@p: enumerate VTS_xx_y.VOB, pick largest
localparam S_FINALIZE  = 6'd8;
localparam S_FINAL2    = 6'd9;
localparam S_STREAM    = 6'd10;
localparam S_DONE      = 6'd11;
localparam S_ERROR     = 6'd12;
// IFO title-selection states (appended at the end so S_STREAM/DONE/ERROR keep
// their numbers and existing testbenches' magic numbers stay valid)
localparam S_IFO_MAT      = 6'd13;   // setup: read VMGI sector, shadow @196
localparam S_IFO_MAT_PARSE= 6'd14;   // tt_srpt ptr -> read TT_SRPT sector
localparam S_IFO_TSRPT    = 6'd15;   // nr_of_srpts + title 1 title_set_nr
localparam S_SELECT       = 6'd16;   // scan group table for target VTS
// PGC / cell-timeline states (Phase 7; appended)
localparam S_PGC_BEGIN    = 6'd17;   // decide PGC-parse vs linear fallback; read VTSI_MAT
localparam S_PGC_MAT      = 6'd18;   // parse vts_pgcit ptr -> read VTS_PGCIT sector
// Phase-2: the one-shot S_PGC_PGCIT/S_PGC_HDR2/S_CELL_F/S_CELL_L/S_PAL_EMIT
// states were replaced by the generalized PGCIT path + the sector-crossing
// walker; their slots are reused (values below).
localparam S_PGCIT_HDR    = 6'd19;   // nr_of_pgci_srp -> pick/scan an SRP
localparam S_PGC_HDR      = 6'd20;   // nr_of_cells -> start the P_HDR walk
localparam S_SRP_FETCH    = 6'd21;   // read SRP[srp_i] (entry_id + pgc_start_byte)
localparam S_SRP_EVAL     = 6'd22;   // entry match / take -> position the PGC
localparam S_WALK_RD      = 6'd23;   // walker: address parse_buf (or refill sector)
localparam S_PGC_DONE     = 6'd24;   // set up cell-mode streaming
localparam S_CELL_LOAD    = 6'd25;   // BRAM read latency #1 (cf_rd/cl_rd for cell_raddr)
localparam S_CELL_LOAD2   = 6'd26;   // BRAM read latency #2 -> compute seek target
localparam S_CELL_SEEK    = 6'd27;   // map a cell's first_sector to an extent + offset
// Phase-0 ALM reclaim: sync-read wait states for the ext_mem / gmem M10K ports.
localparam S_EXT_LOAD     = 6'd28;   // 1-cycle wait: ext_start_q/ext_blocks_q refresh, -> S_STREAM
localparam S_CELL_SEEK2   = 6'd29;   // 1-cycle wait during the S_CELL_SEEK extent scan
localparam S_SELECT2      = 6'd30;   // 1-cycle wait during the S_SELECT group scan
localparam S_WALK_CAP     = 6'd31;   // walker: consume one byte (phase dispatch)
localparam S_PGC_CELLCHK  = 6'd32;   // after hdr/cmd walk: cells valid? / 0-cell follow
// Phase-2 menu domain (appended)
localparam S_STILL        = 6'd33;   // menu still: hold until a jump/seek
localparam S_JMP_VMGI     = 6'd34;   // parse VMGI@132 (FP) / @200 (VMGM PGCI_UT ptr)
localparam S_JMP_VTSM     = 6'd35;   // parse VTSI@208 (VTSM PGCI_UT ptr)
localparam S_UT_HDR       = 6'd36;   // PGCI_UT: nr_of_lus + LU[0].lang_start_byte
localparam S_LU_EVAL      = 6'd57;   // Phase 4: LU[lu_i] language-match walk
// Phase-4 DVD-VM (appended)
localparam S_VM_WAIT      = 6'd37;   // cell-cmd / PGC-end: await the VM verdict
localparam S_TT_RES       = 6'd38;   // JumpTT: TT_SRPT ptr -> read the entry
localparam S_TT_RES2      = 6'd39;   // JumpTT: entry -> {vts, vts_ttn} -> scan
// VTS_PTT_SRPT resolve (vts_ttn -> pgcn/pgn), so JumpVTS_TT / JumpTT land on
// the RIGHT title PGC instead of the entry-scan heuristic's SRP[0] (= the main
// feature). This is what made Matrix's special-feature buttons all play the
// movie. VTSI_MAT.vts_ptt_srpt @200 -> nr_of_srpts@0, ttu_offset[i] u32 @8+4i,
// ptt[0] {pgcn u16@0, pgn u16@2} at VTS_PTT_SRPT + ttu_offset. All rel. VTSI.
localparam S_PTT_MAT      = 6'd40;   // read VTSI@200 -> vts_ptt_srpt ptr
localparam S_PTT_OFF      = 6'd41;   // read ttu_offset[ttn-1]
localparam S_PTT_PGC      = 6'd42;   // read ptt[0].pgcn/pgn -> want_pgcn/jpgn
localparam S_RBN_SCAN     = 6'd44;   // sub-cell scrub: find the cell containing seek_rbn_l
localparam S_RBN_SCAN2    = 6'd45;   // BRAM read latency during the containing-cell scan
localparam S_ANGLE_SCAN   = 6'd46;   // Phase 9: count the angle-block cells (block_type==1)
localparam S_ANGLE_SCAN2  = 6'd47;   // BRAM read latency during the angle-count scan
localparam S_MENU_VATR    = 6'd43;   // capture menu aspect (V_ATR@0x100) then read the PGCI_UT
localparam S_ATTR_RD      = 6'd48;   // Phase 10: address parse_buf @attr_addr (read latency #1)
localparam S_ATTR_CAP     = 6'd49;   // Phase 10: capture pb_rdata -> track-attr store
// Scrub NAV-align (VOBU snap): before the containing-cell scan, walk forward from
// the raw scrub target to the first NAV pack (VOBU boundary) so the decoder re-locks
// on a clean GOP and av_sync anchors on the VOBU-first video PTS. See docs/dvd_nav.md.
localparam S_NAV_SEEK     = 6'd50;   // extent-walk / issue a 1-block probe read
localparam S_NAV_SEEK2    = 6'd51;   // 1-cycle ext_*_q refresh (mirrors S_CELL_SEEK2)
localparam S_NAV_CHK      = 6'd52;   // evaluate the NAV signature in rbuf
// Phase-6 PTT-table load (resident ptt_mem for the current title). Runs off the
// title-mount attr-sweep resume, BEFORE the PGC parse, for BOTH Auto and jump
// mounts, then chains to ptt_resume (= the original S_PTT_MAT / S_PGC_MAT).
localparam S_PTTLD_MAT    = 6'd53;   // entered after VTSI@200 shadow: vts_ptt_srpt ptr
localparam S_PTTLD_HDR    = 6'd54;   // nr_of_srpts@0 + last_byte@4 -> read ttu offsets
localparam S_PTTLD_OFF    = 6'd55;   // ttu_offset[ttn-1]/[ttn] -> nr_ptt, launch P_PTT
localparam S_PTTLD_DONE   = 6'd56;   // re-fetch the resume field (@200 / @204) -> ptt_resume
localparam S_CHK_RAW      = 6'd58;   // raw MODE2/2352 (VCD/SVCD .bin) signature probe

reg [5:0]  state;
reg [5:0]  fetch_ret;   // state to enter after S_FETCH
reg [10:0] fetch_base;  // parse_buf offset the shadow starts at
reg [5:0]  fi;          // fetch byte counter
reg        fi_cap_v;
reg [5:0]  fi_cap;
// SECTOR-CROSSING SHADOW FETCH (straddle audit). The 45-byte rbuf shadow is copied
// from parse_buf starting at fetch_base; when a copied byte index (fetch_base+fi)
// runs past offset 2047 the byte lives in the NEXT sector, so the fetch refills
// parse_buf with sec_lba+1 and resumes with fetch_xw=1 (reads at fetch_base+fi-2048)
// -- instead of the old wrap-to-parse_buf[0] which read GARBAGE. This makes every
// IFO field read at an arbitrary byte offset straddle-safe (SRP srp_pgc_start@4-7,
// VTS_PTT_SRPT / TT_SRP entries, and the PGC header pre-walk bytes @2/@3/@4-7), so
// e.g. a menu PGC whose header starts in the last few bytes of a sector no longer
// dead-ends. FETCH_N(45) < 2048 so a shadow spans at most two sectors. See
// docs/dvd_nav.md "Sector-straddle audit".
reg        fetch_xw;    // fetch is continuing in the NEXT sector (wrapped)
reg        fetch_cross; // a cross-refill is in progress (S_SECREAD resumes S_FETCH, keeps fi)
reg [5:0]  fi_save;     // fi latched at the straddle point (restored after the refill)

reg [31:0] sec_lba;     // 2048-LBA to read in S_SECREAD
reg        blk_inflight;
// Transport/VM seek executes at a block boundary. Phase-B additions: a
// NATURAL seek (snat_l) also waits for vbuf_empty (bounded by DRAIN_WD); and
// ~jump_pending makes the "jump outranks seek" rule explicit - the pending-
// jump window used to be ~us wide, but a gated natural jump now pends for
// seconds, during which a latched seek must not slip past it.
wire       seek_jump = seek_pending && ~blk_inflight && ~jump_pending &&
                       (~snat_l || vbuf_empty || drain_wd_hit);
// A VM jump executes at a block boundary too, but only from a SETTLED state
// (streaming / finished / holding a still) - never mid-parse, where it would
// corrupt an in-progress IFO walk. It outranks a pending seek (jump_go clears
// seek_pending); a seek cannot be latched during a jump parse (cell_mode=0).
// Phase B: a NATURAL jump (jnat_l) waits for vbuf_empty (bounded by DRAIN_WD)
// so its keep_vbuf=0 flush lands on a drained decoder - the clip's tail plays
// out first. User jumps (jnat_l=0) execute immediately, clearing the gate.
wire       jump_go = jump_pending && ~blk_inflight &&
                     (~jnat_l || vbuf_empty || drain_wd_hit) &&
                     (state == S_STREAM || state == S_DONE ||
                      state == S_STILL  || state == S_VM_WAIT);
reg        sd_ack_d;
reg [31:0] vd_lba;      // volume-descriptor scan cursor

reg        iso_mode;
reg        iso_error;

reg [31:0] dir_lba;     // 2048-LBA of the current directory sector
reg [31:0] dir_remain;  // bytes remaining in the whole directory
reg [11:0] p;           // byte offset of the current record within the sector

reg [6:0]  strm_idx;    // current extent (absolute)
reg [6:0]  strm_left;   // extents remaining
reg [31:0] strm_blk;    // 2048-sector offset within the current extent
reg        strm_done;

// =========================================================================
// Raw MODE2/2352 deblocker (VCD/SVCD .bin). The stream cache write port is
// gated so ONLY Mode-2 Form-2 payload bytes (sector offsets [24, 24+2324))
// land in the cache — Form-1 sectors (the ISO-filesystem track of single-bin
// images) are skipped entirely so filesystem bytes can never false-sync the
// PS demux, and zero-payload Form-2 pregap sectors pass as harmless zeros.
// raw_pos is a free-running mod-2352 byte position: linear streaming requests
// blocks strictly in order, so it simply accumulates across the 2048-byte
// blocks (2352 > 2048 sector-straddle needs no special case). raw_sec_pass is
// latched from the mode byte (@15) and XA submode (@18, bit5 = Form 2) and
// cleared at every sector wrap — a stream entered mid-sector (seek, RIFF CDXA
// header skip) drops the partial first sector and starts clean at the next
// boundary. Golden model: tools/cd_deblock_ref.py (byte-exact contract).
// =========================================================================
reg        raw_mode;       // mounted image is raw 2352-byte CD sectors
reg [11:0] raw_pos;        // sector byte position (mod 2352) of the next byte
reg        raw_m2;         // this sector's mode byte (@15) == 2
reg        raw_sec_pass;   // Form-2 sector: pass payload window [24, 2348)
reg [11:0] raw_wcnt;       // compact cache write index within the current block

// Linear-transport seek math (combinational off the latched target; consumed
// by the !cell_mode seek_jump branch). Raw mode: a target file block r maps to
// the containing sector s ~= r*2048/2352 = r*128/147, approximated by
// r - r/8 - r/256 - r/1024 (-0.07 %, biased early = harmless for a scrub),
// then byte0 = s*2352 via shift-adds (2048+256+32+16); the stream restarts at
// block byte0>>11 with raw_pos pre-loaded to byte0's position within its
// sector ((2352 - byte0 mod 2048-block phase) mod 2352) and the pass latch
// cleared, so the partial head sector drops and emission resumes at the next
// sector = a clean MPEG pack boundary (the raw analogue of the DVD NAV snap).
wire [31:0] ls_tgt   = (seek_rbn_l >= total_blocks) ? (total_blocks - 32'd1)
                                                    : seek_rbn_l;
wire [31:0] ls_sec   = ls_tgt - (ls_tgt >> 3) - (ls_tgt >> 8) - (ls_tgt >> 10);
wire [42:0] ls_byte  = {ls_sec[31:0], 11'b0} + {3'b0, ls_sec, 8'b0}
                     + {6'b0, ls_sec, 5'b0}  + {7'b0, ls_sec, 4'b0};
wire [31:0] ls_blk   = ls_byte[42:11];
wire [10:0] ls_phase = ls_byte[10:0];
wire [11:0] ls_pos   = (ls_phase == 11'd0) ? 12'd0
                                           : (12'd2352 - {1'b0, ls_phase});

// parse_buf read address (combinational; 1-cycle latency to pb_rdata). The
// walker addresses parse_buf directly at walk_off during S_WALK_RD; every
// other state goes through the rbuf shadow fetch.
// Shadow byte index (may run past 2047 into the next sector; the fetch refills
// parse_buf and sets fetch_xw so the wrapped bytes read the correct next-sector
// offset). fb_fi is 12-bit (max fetch_base 2047 + fi 45 = 2092).
wire [11:0] fb_fi      = {1'b0, fetch_base} + {6'b0, fi};
wire [11:0] fb_fi_sub  = fb_fi - 12'd2048;   // wrapped offset (fb_fi in 2048..2092)
wire [10:0] fb_fi_wrap = fb_fi_sub[10:0];
wire [10:0] pb_raddr = (state == S_WALK_RD)  ? walk_off  :
                       (state == S_ATTR_RD)  ? attr_addr :
                       // SECTOR-CROSSING SHADOW FETCH: while wrapped, the shadow
                       // reads the NEXT resident sector at (fb_fi-2048); otherwise
                       // the in-sector byte. fb_fi>2047 with fetch_xw==0 is the
                       // pre-cross cycle (its data is discarded before the detour)
                       // -> clamp to 0 so the index stays inside parse_buf.
                       fetch_xw            ? fb_fi_wrap :
                       (fb_fi <= 12'd2047) ? fb_fi[10:0] : 11'd0;
always @(posedge clk) pb_rdata <= parse_buf[pb_raddr];

// Cell list BRAM: synchronous read (cell_raddr -> cf_rd/cl_rd/cm_rd) + a
// dedicated write from the P_CELL walker, so it infers M10K (no async
// register-file muxes).
always @(posedge clk) begin
    cf_rd <= cell_first_mem[cell_raddr];
    cl_rd <= cell_last_mem [cell_raddr];
    cm_rd <= cell_meta_mem [cell_raddr];
    cc_rd <= cell_cat_mem  [cell_raddr];   // Phase-9 cell category byte@0
end

// Phase 11: cur_cell_start continuously tracks the STREAMING cell via its own
// sync read port on cell_i (cell_raddr is transiently repointed by the angle
// prefetch / seek scans, so piggybacking there would skew the readout).
reg [31:0] cs_rd;
always @(posedge clk) begin
    cs_rd          <= cell_start_mem[cell_i[6:0]];
    cur_cell_start <= cs_rd;
end

// Extent + group tables: synchronous read ports (M10K). ext_mem tracks the
// streaming cursor strm_idx (1-cycle latency; S_EXT_LOAD covers it); gmem tracks
// the S_SELECT scan cursor sel_i (S_SELECT2 covers it).
always @(posedge clk) begin
    ext_start_q  <= ext_mem[strm_idx][63:32];
    ext_blocks_q <= ext_mem[strm_idx][31:0];
    gmem_q       <= gmem[sel_i];
end
wire [7:0]  gq_vts     = gmem_q[117:110];
wire [6:0]  gq_base    = gmem_q[109:103];
wire [6:0]  gq_cnt     = gmem_q[102:96];
wire [31:0] gq_ifo_lba = gmem_q[95:64];
wire [31:0] gq_mnu_lba = gmem_q[63:32];
wire [31:0] gq_mnu_blk = gmem_q[31:0];

// -------------------------------------------------------------------------
// Field taps - all read the 45-byte shadow (cheap async), NOT parse_buf
// -------------------------------------------------------------------------
wire        cd001 = (rbuf[1]=="C") && (rbuf[2]=="D") && (rbuf[3]=="0") &&
                    (rbuf[4]=="0") && (rbuf[5]=="1");
wire [7:0]  vd_type = rbuf[0];

// Raw MODE2/2352 image signature at file byte 0 (shadow of block 0): the
// 12-byte CD sector sync 00 FF*10 00 + mode byte 2 @15. Block-aligned, so the
// probe is free; a DVD ISO has zeros at LBA 0 and can never false-fire.
wire raw2352 = (rbuf[0]==8'h00) && (rbuf[1]==8'hFF) && (rbuf[2]==8'hFF) &&
               (rbuf[3]==8'hFF) && (rbuf[4]==8'hFF) && (rbuf[5]==8'hFF) &&
               (rbuf[6]==8'hFF) && (rbuf[7]==8'hFF) && (rbuf[8]==8'hFF) &&
               (rbuf[9]==8'hFF) && (rbuf[10]==8'hFF) && (rbuf[11]==8'h00) &&
               (rbuf[15]==8'h02);
// RIFF/CDXA wrapper (extracted AVSEQnn.DAT files): 44-byte RIFF header, then
// raw 2352-byte sectors. Handled by pre-loading raw_pos so the header bytes
// count as the tail of a phantom sector (positions 2308..2351, never in the
// pass window) and byte 44 lands on position 0.
wire riff_cdxa = (rbuf[0]=="R") && (rbuf[1]=="I") && (rbuf[2]=="F") &&
                 (rbuf[3]=="F") && (rbuf[8]=="C") && (rbuf[9]=="D") &&
                 (rbuf[10]=="X") && (rbuf[11]=="A");

// directory record (rbuf shadow starts at the record) - also used for the PVD
// root record when the shadow is fetched at offset 156
wire [7:0]  rec_len_b   = rbuf[0];
wire [31:0] rec_extlba  = {rbuf[5], rbuf[4], rbuf[3], rbuf[2]};
wire [31:0] rec_datalen = {rbuf[13],rbuf[12],rbuf[11],rbuf[10]};
wire [7:0]  rec_flags   = rbuf[25];
wire [7:0]  rec_namelen = rbuf[32];
wire        is_dir      = rec_flags[1];

wire [11:0] sec_bytes   = (dir_remain > 32'd2048) ? 12'd2048 : dir_remain[11:0];
wire        rec_ok      = (rec_len_b != 8'd0) &&
                          ((p + rec_len_b) <= sec_bytes) &&
                          ((p + 12'd33)    <= sec_bytes);

wire name_is_videots =
      (rec_namelen==8'd8) && is_dir &&
      rbuf[33]=="V" && rbuf[34]=="I" && rbuf[35]=="D" && rbuf[36]=="E" &&
      rbuf[37]=="O" && rbuf[38]=="_" && rbuf[39]=="T" && rbuf[40]=="S";

// VIDEO_TS.IFO (the VMGI) file record - latched to find the TT_SRPT.
// "VIDEO_TS.IFO" = rbuf[33..44]; .BUP differs at [42..44] so this is exact.
wire name_is_vmgi_pfx =
      !is_dir &&
      rbuf[33]=="V" && rbuf[34]=="I" && rbuf[35]=="D" && rbuf[36]=="E" &&
      rbuf[37]=="O" && rbuf[38]=="_" && rbuf[39]=="T" && rbuf[40]=="S" &&
      rbuf[41]==".";
wire name_is_vmgi_ifo =
      name_is_vmgi_pfx && rbuf[42]=="I" && rbuf[43]=="F" && rbuf[44]=="O";
// VIDEO_TS.VOB = VMGM_VOBS, the VMG menu VOB (Phase-2 disc menus).
wire name_is_vmgm_vob =
      name_is_vmgi_pfx && rbuf[42]=="V" && rbuf[43]=="O" && rbuf[44]=="B";

// NAV-pack (NV_PCK / VOBU-first pack) signature, checked in the sector's
// shadow (rbuf @fetch_base=0): pack start 00 00 01 BA @0 (every PS
// sector), PS system header 00 00 01 BB @14 (VOBU-first pack only), and PCI PES
// 00 00 01 BF @38 (0x26). Offsets verified vs libdvdnav dvdnav_decode_packet.
wire nav_sig_hit =
      rbuf[0]==8'h00  && rbuf[1]==8'h00  && rbuf[2]==8'h01  && rbuf[3]==8'hBA &&
      rbuf[14]==8'h00 && rbuf[15]==8'h00 && rbuf[16]==8'h01 && rbuf[17]==8'hBB &&
      rbuf[38]==8'h00 && rbuf[39]==8'h00 && rbuf[40]==8'h01 && rbuf[41]==8'hBF;

// IFO big-endian field taps (rbuf shadow fetched at the relevant offset)
wire [31:0] tt_srpt_ptr = {rbuf[0], rbuf[1], rbuf[2], rbuf[3]};   // VMGI@196
wire [15:0] nr_of_srpts = {rbuf[0], rbuf[1]};                     // TT_SRPT@0
wire [7:0]  ttsrp0_vtsn  = rbuf[14];                              // TT_SRP[0]@6

// PGC big-endian field taps. Reads set fetch_base to the field's byte offset so
// the field lands in the low shadow bytes (only rbuf[0..15] are relied on ->
// safe for fetch_base up to ~2044; the shadow read wraps >2047 to parse_buf[0]).
wire [31:0] vts_pgcit_ptr  = {rbuf[0], rbuf[1], rbuf[2], rbuf[3]};   // VTSI_MAT@204 / @208 / VMGI@200/@132
wire [15:0] nr_pgci_srp    = {rbuf[0], rbuf[1]};                     // PGCIT@0 (shadow@pit_off)
wire [7:0]  nr_of_cells_b   = rbuf[3];                               // PGC@3 (shadow@pgc_off)
// SRP taps (shadow fetched at the SRP's byte offset): entry_id u8@0 (menu
// PGCITs: bit7=entry PGC, low nibble = menu type; title PGCITs: title nr),
// pgc_start_byte BE u32 @4 (rel. to the PGCIT start).
wire [7:0]  srp_entry_id    = rbuf[0];
wire [31:0] srp_pgc_start   = {rbuf[4], rbuf[5], rbuf[6], rbuf[7]};
// PGCI_UT taps (shadow fetched at the UT start): nr_of_lus u16@0; LU[0]@8 =
// {lang u16, ext u8, exists u8, lang_start_byte u32@12 rel. to the UT}.
// Phase 4 (spec-hardening): multi-LU UTs are walked matching the player
// language against each LU's lang_code (libdvdnav get_MENU_PGCIT semantics:
// exact u16 match, LU[0] fallback). Single-LU UTs take LU[0] directly — the
// pre-Phase-4 path, bit-identical.
wire [15:0] ut_nr_lus       = {rbuf[0], rbuf[1]};
wire [31:0] ut_lu0_start    = {rbuf[12], rbuf[13], rbuf[14], rbuf[15]};
// S_LU_EVAL taps (the shadow then holds ONE 8-byte LU descriptor):
// lang u16@0 (aliases the ut_nr_lus byte positions), start u32@4 (rbuf_be32_4).
wire [15:0] lu_lang         = {rbuf[0], rbuf[1]};
// Player menu language = SPRM0 (the OSD "Player Language" setting, threaded
// in as the lu_lang_pref port; emu drives dvd_vm.cfg_lang with the same code
// so the VM's SPRM0/16/18 reads always agree with the LU pick).
// VTS_PTT_SRPT resolve taps: pgcn = nr_pgci_srp (rbuf@0-1), pgn @2-3 (BE u16).
wire [15:0] ptt_pgn         = {rbuf[2], rbuf[3]};
// Phase 6 exact PTT: byte offset of ptt[part-1] = ttu_off (in vts_pgcit_ptr,
// reused during S_PTT_OFF) + 4*(jptt_l-1). jptt_l 0/1 -> ptt[0].
wire [20:0] eff_ptt_off     = vts_pgcit_ptr[20:0] +
                              ((jptt_l > 11'd1) ? {8'd0, (jptt_l - 11'd1), 2'b00}
                                                : 21'd0);
// PTT-load taps: VTS_PTT_SRPT last_byte@4 / ttu_offset[ttn]@(shadow+4) = rbuf[4..7]
// (BE u32). tt_srpt_ptr (rbuf[0..3]) doubles as ttu_offset[ttn-1].
wire [31:0] rbuf_be32_4     = {rbuf[4], rbuf[5], rbuf[6], rbuf[7]};

wire pfx_vts = rbuf[33]=="V" && rbuf[34]=="T" && rbuf[35]=="S" && rbuf[36]=="_";
wire sfx_vob = rbuf[41]=="." && rbuf[42]=="V" && rbuf[43]=="O" && rbuf[44]=="B";
wire        is_vts_vob = (rec_namelen>=8'd12) && !is_dir && pfx_vts && sfx_vob;

// VTS_xx_0.IFO (the per-title VTSI) file record - latched per VTS to find its PGC.
// "VTS_01_0.IFO" occupies rbuf[33..44] (12 chars) exactly within the shadow.
wire name_is_vts_ifo =
      (rec_namelen>=8'd12) && !is_dir && pfx_vts &&
      rbuf[39]=="_" && rbuf[40]=="0" && rbuf[41]=="." &&
      rbuf[42]=="I" && rbuf[43]=="F" && rbuf[44]=="O";
wire [7:0]  vts_num    = (rbuf[37]-8'h30)*8'd10 + (rbuf[38]-8'h30);
wire [7:0]  part_num   = rbuf[40]-8'h30;

wire [31:0] rec_startblk = rec_extlba;                        // 2048-sector LBA
wire [31:0] rec_blocks   = (rec_datalen + 32'd2047) >> 11;    // ceil(bytes/2048)

wire [31:0] root_lba = rec_extlba;   // when shadow fetched at PVD offset 156
wire [31:0] root_len = rec_datalen;

// =========================================================================
// parse_buf write (during navigation sector reads)
// =========================================================================
always @(posedge clk)
    if (sd_buff_wr && state==S_SECREAD)
        parse_buf[sd_buff_addr[10:0]] <= sd_buff_dout;

// =========================================================================
// stream cache write (during streaming block reads). Raw MODE2/2352 mode
// filters to Form-2 payload bytes and compacts them (raw_wcnt) so the cache
// holds a contiguous deblocked stream; the wr_ptr advance at block completion
// is counted (+raw_wcnt) instead of the fixed +BLK.
// =========================================================================
wire raw_keep = raw_sec_pass && (raw_pos >= 12'd24) && (raw_pos < 12'd2348);
always @(posedge clk)
    if (sd_buff_wr && state==S_STREAM && (!raw_mode || raw_keep))
        cache_mem[wr_ptr + (raw_mode ? {2'b00, raw_wcnt}
                                     : {3'b000, sd_buff_addr[10:0]})] <= sd_buff_dout;

// =========================================================================
// Multi-angle NV_PCK snoop (Phase 9). While streaming an angle-block cell,
// capture the DSI fields from each cached sector's DSI region (sector bytes
// 0x400..0x5FF) as it flows through sd_buff (one whole 2048-byte sector per
// request; sd_buff_addr is the sector byte offset). A NAV pack is identified by
// the DSI PES header (00 00 01 BF @0x400, substream 0x01 @0x406); the DSI DATA
// then starts at 0x407, so category is at 0x427, vobu_ea at 0x40F and
// sml_agli[cur_angle-1].address at 0x4BB+6*(cur_angle-1). snoop_rbn latches the
// sector's RBN (= play_blk). snoop_done pulses at the DSI region's last byte;
// the FSM evaluates + arms the ILVU jump then.
// =========================================================================
wire [3:0]  ang_idx = (cur_angle == 4'd0) ? 4'd0 : (cur_angle - 4'd1);   // 0-based
wire [10:0] agli_o  = 11'h4BB + 11'd6 * {7'd0, ang_idx};                 // sector offset
always @(posedge clk) begin
    snoop_done <= 1'b0;
    if (state==S_STREAM && sd_buff_wr && ilvu_active) begin
        case (sd_buff_addr[10:0])
            11'h400: snoop_sig[31:24] <= sd_buff_dout;
            11'h401: snoop_sig[23:16] <= sd_buff_dout;
            11'h402: snoop_sig[15:8]  <= sd_buff_dout;
            11'h403: snoop_sig[7:0]   <= sd_buff_dout;
            11'h406: snoop_sub        <= sd_buff_dout;
            11'h40F: snoop_ea[31:24]  <= sd_buff_dout;
            11'h410: snoop_ea[23:16]  <= sd_buff_dout;
            11'h411: snoop_ea[15:8]   <= sd_buff_dout;
            11'h412: snoop_ea[7:0]    <= sd_buff_dout;
            11'h427: snoop_cat[15:8]  <= sd_buff_dout;
            11'h428: snoop_cat[7:0]   <= sd_buff_dout;
            // vobu_sri.next_vobu (DSI-rel 0x13A -> sector 0x541)
            11'h541: snoop_nextv[31:24] <= sd_buff_dout;
            11'h542: snoop_nextv[23:16] <= sd_buff_dout;
            11'h543: snoop_nextv[15:8]  <= sd_buff_dout;
            11'h544: snoop_nextv[7:0]   <= sd_buff_dout;
            default: ;
        endcase
        if (sd_buff_addr[10:0] == 11'd0)          snoop_rbn <= play_blk;
        if (sd_buff_addr[10:0] == agli_o)         snoop_agli[31:24] <= sd_buff_dout;
        if (sd_buff_addr[10:0] == agli_o+11'd1)   snoop_agli[23:16] <= sd_buff_dout;
        if (sd_buff_addr[10:0] == agli_o+11'd2)   snoop_agli[15:8]  <= sd_buff_dout;
        if (sd_buff_addr[10:0] == agli_o+11'd3)   snoop_agli[7:0]   <= sd_buff_dout;
        if (sd_buff_addr[10:0] == 11'h5FF)        snoop_done <= 1'b1;   // DSI region done
    end
end

// Snoop decode: is this VOBU the last of an ILVU, and where does this branch's
// next ILVU start? ANGLE (Phase 9): sml_agli[cur_angle-1] (signed, libdvdnav
// dvdnav.c ~L452-468). SEAMLESS-BRANCH: vobu_sri.next_vobu (always FORWARD -
// bit31 is the SRI "valid" flag, NOT a sign; libdvdnav's default vobu_next).
wire        snoop_is_last = (snoop_sig == 32'h000001BF) && (snoop_sub == 8'h01)
                            && (snoop_cat[15:12] == 4'b0101);            // BLOCK|LAST
wire [29:0] snoop_off   = snoop_agli[29:0];
wire        snoop_neg   = snoop_agli[31] && (snoop_agli != 32'h7fffffff);
wire        snoop_valid = (snoop_agli != 32'd0) && (snoop_agli[29:0] != 30'h3fffffff);
wire [31:0] snoop_tgt   = snoop_neg ? (snoop_rbn - {2'b0, snoop_off})
                                    : (snoop_rbn + {2'b0, snoop_off});
wire [31:0] snoop_iend  = snoop_rbn + snoop_ea;         // last sector of this VOBU
// Seamless-branch target/validity from next_vobu (forward-only, mask off SRI bits).
wire [29:0] snoop_nvoff  = snoop_nextv[29:0];
wire        snoop_nvvalid= (snoop_nvoff != 30'h3fffffff) && (snoop_nvoff != 30'd0);
wire [31:0] snoop_nvtgt  = snoop_rbn + {2'b0, snoop_nvoff};

// =========================================================================
// cell list write (from the P_CELL walker: first_sector completes at entry
// byte 11, last_sector + meta at byte 23) - dedicated blocks so the arrays
// map to M10K, not async register files.
// =========================================================================
// libdvdnav still heuristic, evaluated as cell byte 23 (last_sector) lands.
// cf_c/lv_c/pb_c were captured earlier in the same 24 B record.
wire [31:0] cell_last_w = {wacc, pb_rdata};                 // last_sector @20
wire [31:0] cell_sz_w   = cell_last_w - cf_c;               // content size (sectors)
wire        heur_hit_w  = (cell_last_w == lv_c) && (cell_sz_w < 32'd1024) &&
                          (pb_c != 16'd0) && (cell_sz_w <= (32'd30 * {16'd0, pb_c}));
// The heuristic still byte clamps at 254 (255 would alias the INDEFINITE
// hold - a latent bug while pb_c capped at 255); the stored heur flag lets
// the timed-still load use the full 16-bit duration instead.
wire [7:0]  eff_still_w = (cm_still_c != 8'd0) ? cm_still_c
                          : (heur_hit_w ? ((pb_c > 16'd254) ? 8'd254 : pb_c[7:0])
                                        : 8'd0);
wire        heur_flag_w = (cm_still_c == 8'd0) && heur_hit_w;
// Phase 11: per-cell start-time PREFIX SUM. pt_c captures this cell's full
// playback_time (@4..7, BCD dvd_time incl. the rate|frames byte); run_eltm
// carries the sum of all PRIOR cells' durations (rate-aware frame carry via
// bcd_time_add, so truncation can't accumulate). Self-initializing: cell 0
// stores 0 and seeds run_eltm, so no extra reset state in the walk.
reg  [31:0] pt_c;                     // this cell's playback_time (BCD)
reg  [31:0] run_eltm;                 // running duration sum (BCD)
wire [31:0] run_sum_w;
bcd_time_add run_eltm_add (.a(run_eltm), .b(pt_c), .sum(run_sum_w));
// ---- AUTHORED DURATION: ROUND THE C_PBTM FRAME FIELD (2026-08-25) ---------
// C_PBTM is a BCD dvd_time {hh, mm, ss, rate|frames}; pb_c above keeps only
// hh:mm:ss because that is what libdvdnav's still HEURISTIC uses (vm.c
// get_current_position - keep pb_c truncated so detection stays in lockstep
// with tools/iso_nav_check.py). The HOLD, though, must serve the cell's REAL
// authored length, and interactive discs author their short screens as
// "N seconds + (fps-1) frames" = N+1 seconds minus one frame:
//
//   Weakest Link (PAL, 25 fps): the correct/wrong answer reveal and the
//   "money banked" screen are single I-frame cells with pbtime = 1 s + 24 f
//   = 1.96 s. Truncating to 1 s put the residual (1 s) UNDER RESID_MIN, so
//   no hold was served at all and the screen flashed by in ~0.2 s - while
//   the 17 s + 23 f question cell held fine. See docs/disc_sweep.md
//   "Round-7" and docs/dvd_nav.md "Authored cell duration".
//
// So the STORED duration rounds the frame field to the nearest second (the
// hold countdown is 1 Hz - docs record the +-0.5 s quantisation). Rate bits:
// 2'b01 = 25 fps, 2'b11 = 30 fps (dvd/bcd_time_add.sv); anything else is
// malformed and takes the 30 fps threshold (rounds up less eagerly).
wire [5:0]  pb_frames_w = {2'b0, pt_c[5:4]} * 6'd10 + {2'b0, pt_c[3:0]};
wire        pb_rndup_w  = (pt_c[7:6] == 2'b01) ? (pb_frames_w >= 6'd13)
                                               : (pb_frames_w >= 6'd15);
wire [15:0] pb_dur_w    = (pb_c >= 16'd35999) ? 16'd35999      // spec-max clamp
                                              : (pb_c + {15'd0, pb_rndup_w});
always @(posedge clk)
    if (!rst_n) begin
        // title span is captured only in this block (sole driver of the outputs)
        title_first_rbn <= 32'd0;
        title_last_rbn  <= 32'd0;
        pt_c            <= 32'd0;
        run_eltm        <= 32'd0;
        cellf_we        <= 1'b0;
        cellf_idx       <= 7'd0;
        cellf_rbn       <= 32'd0;
    end else begin
        cellf_we <= 1'b0;                 // 1-cycle stream pulses
        // Linear/raw transport: the whole file is the "title" — publish its
        // block span for the seek bar / scrub clamp (inclusive last block).
        // Stops the moment an ISO is recognised (iso_mode); the cell walk
        // below then owns the span as before.
        if (!iso_mode && !cell_mode) begin
            title_first_rbn <= 32'd0;
            title_last_rbn  <= (total_blocks == 32'd0) ? 32'd0
                                                       : (total_blocks - 32'd1);
        end
        if (state==S_WALK_CAP && wphase==P_CELL) begin
        if (cell_bi == 5'd4) pt_c[31:24] <= pb_rdata;   // playback_time hh
        if (cell_bi == 5'd5) pt_c[23:16] <= pb_rdata;   // mm
        if (cell_bi == 5'd6) pt_c[15:8]  <= pb_rdata;   // ss
        if (cell_bi == 5'd7) pt_c[7:0]   <= pb_rdata;   // rate | frames
        if (cell_bi == 5'd11) begin
            cell_first_mem[cell_wi] <= {wacc, pb_rdata};
            // title_first = the FIRST cell's first_sector.
            if (cell_wi == 8'd0) title_first_rbn <= {wacc, pb_rdata};
            // start time = sum of the cells before this one (pt_c complete @7)
            cell_start_mem[cell_wi] <= (cell_wi == 8'd0) ? 32'd0 : run_eltm;
            run_eltm                <= (cell_wi == 8'd0) ? pt_c  : run_sum_w;
            // stretch: stream the first_sector to seek_bar's shadow map
            cellf_we  <= 1'b1;
            cellf_idx <= cell_wi[6:0];
            cellf_rbn <= {wacc, pb_rdata};
        end
        if (cell_bi == 5'd23) begin
            cell_last_mem[cell_wi] <= {wacc, pb_rdata};
            // title_last tracks the last-written cell's last_sector (cells are
            // captured in order, so after the walk this is the title's end RBN).
            title_last_rbn <= {wacc, pb_rdata};
            // Store the EFFECTIVE hold (explicit still_time OR the heuristic),
            // so downstream sees a nonzero still for authored menu/ad/copyright
            // stills that carry still_time==0.
            // pb_dur_w (not pb_c): the frame-rounded authored duration - the
            // hold must serve the cell's real length, while the heuristic
            // DETECTION above stays on the truncated libdvdnav value.
            cell_meta_mem[cell_wi] <= {heur_flag_w, pb_dur_w, eff_still_w, cm_cmd_c};
            cell_cat_mem [cell_wi] <= cm_cat_c;      // Phase 9 angle-block flags
        end
        end
    end

// =========================================================================
// 1 Hz tick for TIMED STILLS. Runs only while parked on a finite still
// (S_STILL && still_timed); reset otherwise so each hold starts from a full
// second. clk_sys = 27 MHz.
// =========================================================================
always @(posedge clk)
    if (!rst_n) begin
        sec_pre  <= 25'd0;
        sec_tick <= 1'b0;
    end else if (state == S_STILL && still_timed) begin
        if (sec_pre >= SEC_DIV[24:0] - 25'd1) begin
            sec_pre  <= 25'd0;
            sec_tick <= 1'b1;
        end else begin
            sec_pre  <= sec_pre + 25'd1;
            sec_tick <= 1'b0;
        end
    end else begin
        sec_pre  <= 25'd0;
        sec_tick <= 1'b0;
    end

// =========================================================================
// AUTHORED CELL DURATION: display-referenced elapsed time for the playing
// cell. Reset on a fresh cell load (S_CELL_LOAD entry, cell start = RBN of
// C_POSI); an rbn_override entry (raw-RBN scrub, ILVU hop, mid-block angle
// switch) is a MID-CELL entry -> poison the measurement (cell_partial) so the
// duration hold cannot mis-fire off a short residue. rbn_override is still
// set on the S_CELL_LOAD entry cycle (S_CELL_LOAD2 clears it), so sampling at
// the entry edge is race-free. Counting disp_tick (not clk_sys wall time)
// keeps the clock display-referenced per docs/av_sync.md.
// =========================================================================
always @(posedge clk)
    if (!rst_n) begin
        cell_secs    <= 16'd0;
        cell_refr    <= 6'd0;
        cell_partial <= 1'b0;
        st_was_cl    <= 1'b0;
    end else begin
        st_was_cl <= (state == S_CELL_LOAD);
        if (state == S_CELL_LOAD && !st_was_cl) begin
            if (rbn_override)
                cell_partial <= 1'b1;
            else begin
                cell_secs    <= 16'd0;
                cell_refr    <= 6'd0;
                cell_partial <= 1'b0;
            end
        end else if (disp_tick) begin
            if (cell_refr >= disp_fps - 6'd1) begin
                cell_refr <= 6'd0;
                if (cell_secs != 16'hFFFF) cell_secs <= cell_secs + 16'd1;
            end else
                cell_refr <= cell_refr + 6'd1;
        end
    end

// The hold decision, evaluated at CELL FINISHED (cm_rd tracks cell_raddr =
// this cell, same as the existing still branch). dur_resid is only meaningful
// under dur_hold's cell_secs < dur guard.
wire [15:0] cell_dur_w  = cm_rd[31:16];              // authored secs, frames rounded in
                                                     // (pb_dur_w; spec-max clamp)
wire [15:0] dur_resid_w = cell_dur_w - cell_secs;    // unspent authored seconds
wire        dur_hold_w  = vm_mode && !menu_dom &&
                          !angle_active && !seamless_active && !cell_partial &&
                          (cell_dur_w != 16'd0) && (cell_secs < cell_dur_w) &&
                          (dur_resid_w >= RESID_MIN);

// =========================================================================
// Main FSM + sd_* block handshake + fetch sequencer
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state        <= S_IDLE;
        sd_lba       <= 32'd0;
        sd_rd        <= 1'b0;
        blk_inflight <= 1'b0;
        sd_ack_d     <= 1'b0;
        wr_ptr       <= 0;
        fetch_xw     <= 1'b0;
        fetch_cross  <= 1'b0;
        fi_save      <= 6'd0;
        iso_mode     <= 1'b0;
        iso_error    <= 1'b0;
        all_n        <= 7'd0;
        best_base    <= 7'd0;
        best_cnt     <= 7'd0;
        best_total   <= 32'd0;
        grp_valid    <= 1'b0;
        fi_cap_v     <= 1'b0;
        grp_count    <= 7'd0;
        vmgi_found   <= 1'b0;
        sel_valid    <= 1'b0;
        best_ifo_lba <= 32'd0;
        sel_ifo_lba  <= 32'd0;
        grp_ifo_lba  <= 32'd0;
        // Phase-10: default to unconstrained (8) so pre-parse / linear playback
        // behaves exactly as before; the S_ATTR sweep tightens it per title.
        // Title-level state: reset ONLY here (rst_n), never on a per-seek pipe
        // reset (cf. the pgc-palette-seek-reset-bug lesson).
        audio_ntracks <= 4'd8;
        subp_ntracks  <= 4'd8;
        grp_mnu_lba  <= 32'd0;
        grp_mnu_blk  <= 32'd0;
        pending_ifo_vts <= 8'hFF;
        pending_mnu_vts <= 8'hFF;
        vmgm_vob_lba <= 32'd0;
        vmgm_vob_blk <= 32'd0;
        best_vtsn    <= 8'd0;
        best_mnu_blk <= 32'd0;
        best_mnu_vts <= 8'd0;
        cell_mode    <= 1'b0;
        cell_raddr   <= 8'd0;
        seek_ack     <= 1'b0;
        seek_pending <= 1'b0;
        seek_cell_l  <= 8'd0;
        seek_is_rbn  <= 1'b0;
        jnat_l       <= 1'b0;
        snat_l       <= 1'b0;
        seek_rbn_l   <= 32'd0;
        rbn_override <= 1'b0;
        rbn_scan_i   <= 8'd0;
        nav_cand     <= 32'd0;
        nav_left     <= 11'd0;
        cur_angle    <= 4'd1;
        angle_count  <= 4'd0;
        angle_active <= 1'b0;
        angle_resolved <= 1'b0;
        seamless_active <= 1'b0;
        block_first  <= 8'd0;
        block_last   <= 8'd0;
        ang_scan_i   <= 8'd0;
        angle_pulse_d<= 1'b0;
        ilvu_armed   <= 1'b0;
        ilvu_end_rbn <= 32'd0;
        ilvu_target  <= 32'd0;
        chap_st      <= CH_IDLE;
        chap_p       <= 7'd0;
        chap_best    <= 7'd0;
        chap_best_cell <= 8'd0;
        chap_dir_l   <= 1'b0;
        chap_mag_l   <= 5'd1;
        chap_at_start_l <= 1'b0;
        lu_i         <= 7'd0;
        lu_n         <= 7'd0;
        lu0_st       <= 32'd0;
        chap_tp      <= 7'd0;
        chap_do      <= 1'b0;
        chap_query   <= 1'b0;
        pgm_q_cell   <= 8'hFF;
        cur_pgm      <= 8'd0;
        pm_raddr     <= 7'd0;
        ptt_raddr    <= 10'd0;
        g_i          <= 10'd0;
        g_best       <= 10'd0;
        g_found      <= 1'b0;
        g_seen       <= 1'b0;
        g_pgc_first  <= 10'd0;
        g_pgc_last   <= 10'd0;
        g_t          <= 10'd0;
        pal_we       <= 1'b0;
        pal_waddr    <= 4'd0;
        pal_wdata    <= 32'd0;
        pgc_ctl_we    <= 1'b0;
        pgc_ctl_waddr <= 5'd0;
        pgc_ctl_wdata <= 32'd0;
        pgc_ctl_valid <= 1'b0;
        pgc_dom_tt    <= 1'b0;
        dbg_pgcerr    <= 16'd0;
        wacc         <= 24'd0;
        jump_pending <= 1'b0;
        jump_ctx     <= 1'b0;
        jump_ack     <= 1'b0;
        keep_vbuf    <= 1'b0;
        pgc_loaded   <= 1'b0;
        pgc_error    <= 1'b0;
        cmd_we       <= 1'b0;
        cell_end_pulse <= 1'b0;
        pgc_end_pulse  <= 1'b0;
        still_timed  <= 1'b0;
        still_secs   <= 16'd0;
        still_next   <= STILL_NEXT;
        still_last   <= 1'b0;
        dom          <= DOM_TT;
        menu_dom     <= 1'b0;
        menu_ar_wide <= 1'b0;             // default 4:3 until a menu V_ATR is read
        use_jcell    <= 1'b0;
        want_pgcn    <= 16'd1;
        want_entry   <= 4'd0;
        want_ttn     <= 7'd0;
        scan_mode    <= 1'b0;
        scan_title   <= 1'b0;
        sel_ret      <= 1'b0;
        nav_ready    <= 1'b0;
        still_pend   <= 1'b0;
        still_flushed <= 1'b0;
        adv_pend     <= 1'b0;
        jttn_l       <= 7'd0;
        jpgn_l       <= 8'd0;
        jptt_l       <= 11'd0;
        vm_cell_cmd  <= 1'b0;
        vm_pgc_end   <= 1'b0;
        vmw_pgc      <= 1'b0;
        vmw_last     <= 1'b0;
        vmw_pgc_pend <= 1'b0;
        vmw_tmr      <= 24'd0;
        pm_we        <= 1'b0;
        pm_waddr     <= 7'd0;
        pm_wdata     <= 8'd0;
        cmd_nr_pgm   <= 8'd0;
        // Phase-6 PTT table
        ptt_we       <= 1'b0;
        ptt_waddr    <= 10'd0;
        ptt_wdata    <= 24'd0;
        nr_ptt       <= 11'd0;
        cur_ttn      <= 7'd0;
        ptt_resume   <= S_PGC_MAT;
        ptt_pgcn_c   <= 16'd0;
        ptt_nr_srpt  <= 16'd0;
        ptt_last_byte<= 32'd0;
        ptt_base_off <= 21'd0;
        prog_map_off16 <= 16'd0;
        follow_cnt   <= 2'd0;
        link_pgcn_u  <= 16'd0;
        link_pgcn_c  <= 16'd0;
        play_vtsn    <= 8'd0;
        cur_pgcn     <= 16'd0;
        pb_sec       <= 32'hFFFFFFFF;
        pb_skip      <= 1'b0;
        pgc_still_time <= 8'd0;
        pgc_playback_time <= 32'd0;
        next_pgcn    <= 16'd0;
        prev_pgcn    <= 16'd0;
        goup_pgcn    <= 16'd0;
        cmd_nr_pre   <= 8'd0;
        cmd_nr_post  <= 8'd0;
        cmd_nr_cell  <= 8'd0;
    end else begin
        sd_ack_d <= sd_ack;
        seek_ack <= 1'b0;               // default: one-cycle pulses
        pal_we   <= 1'b0;
        pgc_ctl_we <= 1'b0;
        // audio_control completion: the P_ACTL walk's LAST write (addr 23 =
        // audio_control[7]) is registered, so this fires the cycle it lands at
        // the consumer - pgc_ctl_valid rises strictly AFTER all 8 words are
        // stable. dom is still the loaded PGC's domain here (it only changes
        // at jump dispatch).
        if (pgc_ctl_we && pgc_ctl_waddr == 5'd23) begin
            pgc_ctl_valid <= 1'b1;
            pgc_dom_tt    <= (dom == DOM_TT);
        end
        cmd_we   <= 1'b0;
        pm_we    <= 1'b0;
        ptt_we   <= 1'b0;
        jump_ack <= 1'b0;
        pgc_loaded <= 1'b0;
        pgc_error  <= 1'b0;
        cell_end_pulse <= 1'b0;
        pgc_end_pulse  <= 1'b0;
        vm_cell_cmd    <= 1'b0;
        vm_pgc_end     <= 1'b0;

        // ---- Multi-angle (Phase 9) ------------------------------------------
        // Angle cycle: emu delivers a 1-cycle pulse. Cycle 1..angle_count; the
        // new angle takes effect at the next ILVU boundary (the snoop reads
        // cur_angle live), so the switch is seamless (no flush / no re-anchor).
        angle_pulse_d <= angle_pulse;
        if (angle_pulse && !angle_pulse_d && angle_count >= 4'd2)
            cur_angle <= (cur_angle >= angle_count) ? 4'd1 : (cur_angle + 4'd1);

        // Arm the ILVU jump when the snoop finishes a NAV sector that is the
        // LAST VOBU of an ILVU and whose next-ILVU target lands inside this cell.
        // Fired in S_STREAM when play_blk passes ilvu_end_rbn. ANGLE uses the
        // signed sml_agli target; SEAMLESS-BRANCH uses the forward next_vobu
        // target. (angle_active and seamless_active are mutually exclusive.)
        if (snoop_done && angle_active && snoop_is_last && snoop_valid
                && snoop_tgt <= cl_rd) begin
            ilvu_armed   <= 1'b1;
            ilvu_end_rbn <= snoop_iend;
            ilvu_target  <= snoop_tgt;
        end else if (snoop_done && seamless_active && snoop_is_last
                && snoop_nvvalid && snoop_nvtgt <= cl_rd) begin
            ilvu_armed   <= 1'b1;
            ilvu_end_rbn <= snoop_iend;
            ilvu_target  <= snoop_nvtgt;
        end

        // ---- Raw MODE2/2352 position walk (parallel; one step per delivered
        // stream byte). Latches the per-sector mode/submode, counts accepted
        // payload bytes (raw_wcnt, consumed by the cache write port above),
        // and wraps the mod-2352 position — clearing the pass flag at the wrap
        // so a mid-sector entry can never emit a partial sector. Placed BEFORE
        // the main state dispatch so block-completion / seek writes (later in
        // this block) override the walk on a collision cycle.
        if (raw_mode && state == S_STREAM && sd_buff_wr) begin
            if (raw_pos == 12'd15) raw_m2       <= (sd_buff_dout == 8'h02);
            if (raw_pos == 12'd18) raw_sec_pass <= raw_m2 && sd_buff_dout[5];
            if (raw_keep)          raw_wcnt     <= raw_wcnt + 12'd1;
            if (raw_pos == 12'd2351) begin
                raw_pos      <= 12'd0;
                raw_sec_pass <= 1'b0;
            end else
                raw_pos <= raw_pos + 12'd1;
        end

        // Latch a transport seek request (emu delivers a 1-cycle pulse). Range +
        // cell-mode checked at capture; executed at the next block boundary via
        // seek_jump below so the outstanding sd read completes cleanly first.
        if (seek_pulse && cell_mode && seek_cell < cell_count) begin
            seek_pending <= 1'b1;
            seek_is_rbn  <= 1'b0;
            seek_cell_l  <= seek_cell;
            // Phase B: a natural (CELL/POST-verdict) TITLE seek waits for
            // vbuf_empty before executing. menu_dom sources bypass (menu
            // cell links ride keep_vbuf); gamepad seeks arrive natural=0.
            snat_l       <= seek_natural && ~menu_dom;
        end else if (seek_rbn_pulse && cell_mode) begin
            // Sub-cell scrub: the containing-cell scan (S_RBN_SCAN) validates the
            // target lands in a real cell; an out-of-range RBN clamps there.
            seek_pending <= 1'b1;
            seek_is_rbn  <= 1'b1;
            seek_rbn_l   <= seek_rbn;
            snat_l       <= 1'b0;          // gamepad scrub: never gated
        end else if (seek_rbn_pulse && lin_seek_ok_o) begin
            // Linear transport scrub (raw VCD/SVCD .bin, flat .mpg/.VOB):
            // whole-file RBN seek, executed by the !cell_mode seek_jump branch.
            seek_pending <= 1'b1;
            seek_is_rbn  <= 1'b1;
            seek_rbn_l   <= seek_rbn;
            snat_l       <= 1'b0;
        end

        // ---- Chapter (PTT) skip resolve (parallel mini-FSM) ----------------
        // Walk the program_map to find the current chapter (largest program
        // whose entry cell <= cell_i), pick prev/next, then arm a cell seek.
        // Guard: title cell-mode only, needs >1 program, idle + no seek pending
        // (chap_go, above) -- a real skip may also pre-empt an in-flight
        // cur_pgm QUERY walk (its half-done result is simply discarded; the
        // cell change after the skip re-fires the query).
        if (chap_go) begin
            chap_dir_l      <= chap_dir;
            chap_mag_l      <= (chap_mag == 5'd0) ? 5'd1 : chap_mag;
            chap_at_start_l <= chap_at_start;
            chap_p          <= 7'd0;
            chap_best       <= 7'd0;
            chap_best_cell  <= 8'd0;
            pm_raddr        <= 7'd0;
            chap_query      <= 1'b0;
            chap_st         <= CH_A;
        end else if (cell_mode && !menu_dom && chap_st == CH_IDLE &&
                     cell_i != pgm_q_cell) begin
            // Phase 11: the streaming cell moved -> re-resolve cur_pgm. Single-
            // program titles resolve directly; otherwise run the same walk in
            // query mode (CH_R publishes cur_pgm and skips the seek states).
            // Cross-PGC: with a PTT table resident the walk ALWAYS runs (even
            // 1-program PGCs) so cur_pgm publishes the GLOBAL chapter index.
            pgm_q_cell <= cell_i;
            if (cmd_nr_pgm <= 8'd1 && nr_ptt == 11'd0) begin
                cur_pgm <= 8'd1;
            end else begin
                chap_query     <= 1'b1;
                chap_p         <= 7'd0;
                chap_best      <= 7'd0;
                chap_best_cell <= 8'd0;
                pm_raddr       <= 7'd0;
                chap_st        <= CH_A;
            end
        end
        // A (re)streamed program map invalidates the last query (new PGC).
        if (pm_we) pgm_q_cell <= 8'hFF;
        if (!chap_go) case (chap_st)
            CH_A: chap_st <= CH_B;               // pm_rd_q <- pmap[chap_p]
            CH_B: begin
                // pm_rd_q = pmap[chap_p] (1-based entry cell). Track the chapter
                // whose start cell is <= the current cell.
                if (pm_rd_q != 8'd0 && (pm_rd_q - 8'd1) <= cell_i) begin
                    chap_best      <= chap_p;
                    chap_best_cell <= pm_rd_q - 8'd1;
                end
                if (chap_p + 7'd1 < cmd_nr_pgm[6:0]) begin
                    chap_p   <= chap_p + 7'd1;
                    pm_raddr <= chap_p + 7'd1;
                    chap_st  <= CH_A;
                end else begin
                    // Last program compared this cycle -> chap_best settles on the
                    // NEXT cycle (non-blocking). Resolve in CH_R so it isn't stale.
                    chap_st  <= CH_R;
                end
            end
            CH_R: begin
                if (nr_ptt != 11'd0) begin
                    // Cross-PGC: a PTT table is resident -> reverse-map the
                    // current {cur_pgcn, program} to its GLOBAL chapter first
                    // (CH_G0/CH_G scan, one entry/cycle); CH_GR then resolves
                    // query/skip in global chapter space, falling back to the
                    // legacy within-PGC resolve whenever the move stays (or
                    // must clamp) inside the loaded PGC.
                    g_i         <= 10'd0;
                    ptt_raddr   <= 10'd0;
                    g_found     <= 1'b0;
                    g_seen      <= 1'b0;
                    g_pgc_first <= 10'd0;
                    g_pgc_last  <= 10'd0;
                    chap_st     <= CH_G0;
                end else if (chap_query) begin
                    // Query-only walk: chap_best (0-based) settled -> publish the
                    // 1-based chapter number and stop (no seek states).
                    cur_pgm    <= {1'b0, chap_best} + 8'd1;
                    chap_query <= 1'b0;
                    chap_st    <= CH_IDLE;
                end else begin
                // chap_best/chap_best_cell now settled -> resolve the target.
                // A rapid multi-press was debounced by emu into ONE pulse carrying
                // chap_mag_l (>=1) chapters to move; jump the whole distance at once
                // (clamped to the title's chapter range) so the video seeks straight
                // to the destination instead of scrubbing through every chapter.
                //  next: chap_best + mag (clamped at the last chapter).
                //  prev: step back mag chapters, but the FIRST step RESTARTS the
                //   current chapter (the standard player behaviour) unless we're past
                //   its start (a later cell, or >~5 s cell-elapsed = !chap_at_start_l).
                //   So one prev from mid-chapter restarts it; mag>=2 (or from the
                //   start) steps to earlier chapters. dec = # chapters below chap_best.
                chap_tp <= chap_dir_l
                    ? chap_next_tp
                    : chap_prev_tp;
                pm_raddr <= chap_dir_l
                    ? chap_next_tp
                    : chap_prev_tp;
                // "next" at the last chapter isn't a real move -> don't seek.
                chap_do <= chap_dir_l ? (chap_best + 7'd1 < cmd_nr_pgm[6:0]) : 1'b1;
                chap_st <= CH_C;
                end
            end

            // ---- Cross-PGC global PTT scan + resolve ------------------------
            // CH_G0 primes the sync-read pipeline (ptt_raddr=0 was set in CH_R;
            // its data lands in ptt_rd_q at the END of this cycle). CH_G then
            // consumes one entry per cycle with the address one entry ahead.
            CH_G0: begin
                ptt_raddr <= 10'd1;
                chap_st   <= CH_G;
            end
            CH_G: begin
                // ptt_rd_q = ptt_mem[g_i] = {pgcn[15:0], pgn[7:0]}
                if (ptt_rd_q[23:8] == cur_pgcn) begin
                    if (!g_seen) begin
                        g_pgc_first <= g_i;
                        g_seen      <= 1'b1;
                    end
                    g_pgc_last <= g_i;
                    if (ptt_rd_q[7:0] != 8'd0 &&
                        ptt_rd_q[7:0] <= ({1'b0, chap_best} + 8'd1)) begin
                        g_best  <= g_i;
                        g_found <= 1'b1;
                    end
                end
                if ({1'b0, g_i} + 11'd1 < nr_ptt) begin
                    g_i       <= g_i + 10'd1;
                    ptt_raddr <= g_i + 10'd2;
                end else
                    chap_st <= CH_GR;
            end
            CH_GR: begin
                if (chap_query) begin
                    // HUD query: publish the GLOBAL chapter (matches the
                    // nr_ptt-based "CH n/N" total). 8-bit display clamp at
                    // 255 (cosmetic, same clamp as emu's hud_nr_ch). No
                    // reverse-map hit -> the per-PGC program as before.
                    cur_pgm <= !g_found ? ({1'b0, chap_best} + 8'd1)
                             : (g_best >= 10'd255) ? 8'd255
                             : (g_best[7:0] + 8'd1);
                    chap_query <= 1'b0;
                    chap_st    <= CH_IDLE;
                end else if (!g_found ||
                             ( chap_dir_l && ((chap_next_sum <= {1'b0, chap_last}) ||
                                              ({1'b0, g_pgc_last} + 11'd1 >= nr_ptt))) ||
                             (!chap_dir_l && (({2'd0, chap_dec} <= chap_best) ||
                                              (g_pgc_first == 10'd0)))) begin
                    // LEGACY within-PGC resolve (the HW-proven program-map
                    // path, bit-identical): taken when the reverse map missed,
                    // when the move resolves inside the loaded PGC, or when it
                    // clamps at a title end that lives in this PGC. Single-PGC
                    // movie titles always land here (g_pgc_first==0 &&
                    // g_pgc_last==nr_ptt-1).
                    chap_tp  <= chap_dir_l ? chap_next_tp : chap_prev_tp;
                    pm_raddr <= chap_dir_l ? chap_next_tp : chap_prev_tp;
                    chap_do  <= chap_dir_l ? (chap_best + 7'd1 < cmd_nr_pgm[6:0])
                                           : 1'b1;
                    chap_st  <= CH_C;
                end else begin
                    // The move leaves the loaded PGC's entry run -> resolve the
                    // GLOBAL target chapter and read its {pgcn, pgn}.
                    g_t       <= chap_dir_l ? g_next_t : g_prev_t;
                    ptt_raddr <= chap_dir_l ? g_next_t : g_prev_t;
                    chap_st   <= CH_T;
                end
            end
            CH_T: chap_st <= CH_T2;              // ptt_rd_q <- ptt_mem[g_t]
            CH_T2: begin
                // ptt_rd_q = ptt_mem[g_t] = target chapter's {pgcn, pgn}.
                if (ptt_rd_q[23:8] == cur_pgcn) begin
                    // Global math still landed inside the loaded PGC (e.g. a
                    // clamped magnitude) -> the program-map fast path seeks it.
                    if (ptt_rd_q[7:0] != 8'd0 &&
                        ptt_rd_q[7:0] <= cmd_nr_pgm &&
                        ptt_rd_q[7:0] <= 8'd128) begin
                        chap_tp  <= ptt_rd_q[6:0] - 7'd1;   // pgn-1 (pgn <= 128)
                        pm_raddr <= ptt_rd_q[6:0] - 7'd1;
                        chap_do  <= 1'b1;
                        chap_st  <= CH_C;
                    end else
                        chap_st <= CH_IDLE;      // malformed entry -> no move
                end else if (!jump_pending && play_vtsn != 8'd0) begin
                    // CROSS-PGC: dispatch an internal JumpVTS_PTT-shaped jump -
                    // the exact S_PTT_MAT/OFF/PGC + want_pgcn/jpgn_l machinery
                    // the VM's JumpVTS_PTT uses (resolved from disc, lands on
                    // the part's start program). User action: jnat_l=0 =
                    // immediate (no tail-drain gate), and the title-domain
                    // jump takes the full seek-flush contract (load_flush +
                    // vbuf_flush -> A/V re-anchor) via jump_ack, like a
                    // chapter jump today. A VM jump latched this same cycle
                    // outranks it (the external latch below overwrites).
                    jump_pending <= 1'b1;
                    jnat_l   <= 1'b0;
                    jdom_l   <= DOM_TT;
                    jvts_l   <= play_vtsn;
                    jpgcn_l  <= 16'd0;
                    jentry_l <= 4'd0;
                    jcell_l  <= 8'd0;
                    jttn_l   <= cur_ttn;
                    jpgn_l   <= 8'd0;            // S_PTT_PGC sets the start pgn
                    jptt_l   <= {1'b0, g_t} + 11'd1;
                    chap_st  <= CH_IDLE;
                end else
                    chap_st <= CH_IDLE;          // jump busy / no VTS -> drop
            end
            CH_C: chap_st <= CH_D;               // pm_rd_q <- pmap[chap_tp]
            CH_D: begin
                // pm_rd_q = target chapter's entry cell (1-based). Arm a cell seek.
                if (chap_do && pm_rd_q != 8'd0 && (pm_rd_q - 8'd1) < cell_count &&
                    !seek_pending) begin
                    seek_pending <= 1'b1;
                    seek_is_rbn  <= 1'b0;
                    seek_cell_l  <= pm_rd_q - 8'd1;
                    snat_l       <= 1'b0;  // chapter skip = user action: never gated
                end
                chap_st <= CH_IDLE;
            end
            default: ;
        endcase

        // Latch a VM jump request. Accepted once the VIDEO_TS walk has finished
        // on a healthy ISO; executed at a block boundary from a settled state
        // (jump_go below). A newer jump overwrites an unexecuted older one.
        if (jump_pulse && iso_mode && !iso_error && nav_ready) begin
            jump_pending <= 1'b1;
            // Phase B: a natural (CELL/POST-verdict) jump latched from the
            // TITLE domain gates jump_go on vbuf_empty (see jnat_l decl).
            jnat_l   <= jump_natural && ~menu_dom;
            jdom_l   <= jump_domain;
            jvts_l   <= jump_vts;
            jpgcn_l  <= jump_pgcn;
            jentry_l <= jump_entry;
            jcell_l  <= jump_cell;
            jttn_l   <= jump_ttn;
            jpgn_l   <= jump_pgn;
            jptt_l   <= {1'b0, jump_ptt};
        end

        if (start) begin
            state      <= S_INIT;
            sd_rd      <= 1'b0;
            blk_inflight <= 1'b0;
            wr_ptr     <= 0;
            iso_mode   <= 1'b0;
            iso_error  <= 1'b0;
            raw_mode   <= 1'b0;
            raw_pos    <= 12'd0;
            raw_m2     <= 1'b0;
            raw_sec_pass <= 1'b0;
            raw_wcnt   <= 12'd0;
            all_n      <= 7'd0;
            best_base  <= 7'd0;
            best_cnt   <= 7'd0;
            best_total <= 32'd0;
            grp_valid  <= 1'b0;
            grp_vts    <= 8'hFF;
            grp_count  <= 7'd0;
            vmgi_found <= 1'b0;
            sel_valid  <= 1'b0;
            best_ifo_lba    <= 32'd0;
            sel_ifo_lba     <= 32'd0;
            grp_ifo_lba     <= 32'd0;
            grp_mnu_lba     <= 32'd0;
            grp_mnu_blk     <= 32'd0;
            pending_ifo_vts <= 8'hFF;
            pending_mnu_vts <= 8'hFF;
            vmgm_vob_lba    <= 32'd0;
            vmgm_vob_blk    <= 32'd0;
            best_vtsn       <= 8'd0;
            best_mnu_blk    <= 32'd0;
            best_mnu_vts    <= 8'd0;
            cell_mode       <= 1'b0;
            seek_pending    <= 1'b0;
            jump_pending    <= 1'b0;
            jnat_l          <= 1'b0;
            snat_l          <= 1'b0;
            jump_ctx        <= 1'b0;
            dom             <= DOM_TT;
            menu_dom        <= 1'b0;
            use_jcell       <= 1'b0;
            want_pgcn       <= 16'd1;   // mount plays PGCN 1 of the title PGCIT
            want_entry      <= 4'd0;
            want_ttn        <= 7'd0;
            scan_mode       <= 1'b0;
            scan_title      <= 1'b0;
            sel_ret         <= 1'b0;
            nav_ready       <= 1'b0;
            still_pend      <= 1'b0;
            still_flushed   <= 1'b0;
            adv_pend        <= 1'b0;
            follow_cnt      <= 2'd0;
            jttn_l          <= 7'd0;
            jpgn_l          <= 8'd0;
            jptt_l          <= 11'd0;
            vmw_pgc_pend    <= 1'b0;
            pb_sec          <= 32'hFFFFFFFF;   // parse_buf holds no valid sector
        end else if (jump_go) begin
            // VM JUMP (executes at a block boundary, like the transport seek).
            // Cut the stream NOW (jump_ack -> emu pulses load_flush+vbuf_flush)
            // and re-run the generalized parse for the requested domain/PGC.
            jump_pending <= 1'b0;
            seek_pending <= 1'b0;       // a jump outranks a pending seek
            still_pend   <= 1'b0;
            still_flushed <= 1'b0;      // new menu entry: re-arm the still-cell cold re-decode
            adv_pend     <= 1'b0;
            vmw_pgc_pend <= 1'b0;
            jump_ack     <= 1'b1;
            // menu->menu jump (transition between menu PGCs): hold the VBUF so
            // the buffered transition tail plays out. `menu_dom` here is the
            // PRE-jump value (RHS reads the old reg); the new domain is jdom_l.
            // menu->title (Play) and title->menu (Menu key) keep the flush.
            keep_vbuf    <= menu_dom &&
                            ((jdom_l == DOM_VMGM) || (jdom_l == DOM_VTSM));
            jump_ctx     <= 1'b1;
            wr_ptr       <= 0;
            strm_done    <= 1'b0;
            cell_mode    <= 1'b0;
            use_jcell    <= 1'b0;
            follow_cnt   <= 2'd0;
            scan_mode    <= 1'b0;
            scan_title   <= 1'b0;
            want_ttn     <= (jdom_l == DOM_TT) ? jttn_l : 7'd0;
            dom          <= jdom_l;
            menu_dom     <= (jdom_l == DOM_VMGM) || (jdom_l == DOM_VTSM);
            case (jdom_l)
            DOM_FP: begin
                // First Play PGC: VMGI@132 is a BYTE offset rel. to the VMGI.
                if (vmgi_found) begin
                    sec_lba    <= vmgi_lba;
                    fetch_base <= 11'd132;
                    fetch_ret  <= S_JMP_VMGI;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end else begin
                    pgc_error  <= 1'b1;
                    state      <= S_DONE;
                end
            end
            DOM_VMGM: begin
                // VMG menu: VMGI@200 = VMGM_PGCI_UT sector ptr; displayable
                // cells map into VIDEO_TS.VOB (captured in the walk). A disc
                // may have NO VMGM VOB yet still use VMGM PGCs as COMMAND-ONLY
                // dispatchers (0 cells; the Matrix special-feature routing is
                // a GPRM state machine of these). So proceed as long as the
                // VMGI is present; menu_blocks==0 just means "no cells to
                // display" - S_PGC_CELLCHK reports a 0-cell PGC as a command
                // stub and the VM runs its commands (a cells>0 PGC with no VOB
                // degenerates to a still, never a wrong-title fallback).
                if (vmgi_found) begin
                    menu_base_blk <= vmgm_vob_lba;
                    menu_blocks   <= vmgm_vob_blk;        // 0 if no VMGM VOB
                    want_pgcn     <= jpgcn_l;
                    want_entry    <= jentry_l;
                    use_jcell     <= (jcell_l != 8'd0);   // breadcrumb return cell
                    sec_lba    <= vmgi_lba;
                    fetch_base <= 11'd200;
                    fetch_ret  <= S_JMP_VMGI;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end else begin
                    pgc_error  <= 1'b1;
                    state      <= S_DONE;
                end
            end
            DOM_VTSM: begin
                // VTS menu: group-scan for the VTS, then VTSI@208 -> PGCI_UT.
                // sel_ret=1 keeps the scan from clobbering the TITLE selection.
                target_vtsn <= jvts_l;
                sel_i       <= 7'd0;
                sel_ret     <= 1'b1;
                want_pgcn   <= jpgcn_l;
                want_entry  <= jentry_l;
                use_jcell   <= (jcell_l != 8'd0);   // breadcrumb return cell
                state       <= S_SELECT2;
            end
            default: begin  // DOM_TT
                // Title jump: the group scan re-selects the playing title
                // (sel_* overwritten on purpose), then the normal PGC path.
                // Phase-4: jttn_l != 0 selects the PGC by TITLE-entry scan
                // (want_pgcn = 0); jvts_l == 0 with a ttn = JumpTT -> resolve
                // the VTS through the VMG TT_SRPT first (S_TT_RES).
                want_entry  <= 4'd0;
                use_jcell   <= 1'b1;
                if (jttn_l != 7'd0 && jvts_l == 8'd0) begin
                    if (vmgi_found) begin
                        sec_lba    <= vmgi_lba;
                        fetch_base <= 11'd196;      // VMGI.tt_srpt ptr
                        fetch_ret  <= S_TT_RES;
                        fi         <= 6'd0;
                        fi_cap_v   <= 1'b0;
                        state      <= S_SECREAD;
                    end else begin
                        pgc_error  <= 1'b1;         // no VMGI: cannot resolve
                        state      <= S_DONE;
                    end
                end else begin
                    target_vtsn <= jvts_l;
                    sel_i       <= 7'd0;
                    sel_ret     <= 1'b0;
                    play_vtsn   <= jvts_l;
                    want_pgcn   <= (jttn_l != 7'd0) ? 16'd0
                                   : ((jpgcn_l == 16'd0) ? 16'd1 : jpgcn_l);
                    state       <= S_SELECT2;
                end
            end
            endcase
        end else if (seek_jump) begin
            // TRANSPORT SEEK (executes once the outstanding block has finished):
            // (also exits a menu still - the seek target is a menu cell then)
            // jump to the latched cell. This reuses the exact cell-load path the
            // streamer runs on every cell boundary (S_CELL_LOAD -> S_CELL_LOAD2 ->
            // S_CELL_SEEK -> S_STREAM), which re-maps the cell's first_sector
            // through the extent table to an sd_lba. We point cell_i/cell_raddr at
            // the target and clear the cache (wr_ptr) so no stale bytes leak; the
            // output pipeline (rd_ptr) is cleared in the block below. emu.sv pulses
            // load_flush off seek_ack in parallel so the downstream pipe
            // (ps_demux/audio_ring/av_sync) re-anchors on the new cell's PTS.
            strm_done    <= 1'b0;
            still_pend   <= 1'b0;
            still_flushed <= 1'b0;         // new cell target: re-arm the still-cell cold re-decode
            adv_pend     <= 1'b0;
            vmw_pgc_pend <= 1'b0;
            wr_ptr       <= 0;
            // a transport seek re-scans any angle/interleaved block it lands in
            angle_resolved <= 1'b0;
            angle_active   <= 1'b0;
            angle_count    <= 4'd0;
            seamless_active <= 1'b0;
            ilvu_armed     <= 1'b0;
            seek_pending <= 1'b0;
            seek_ack     <= 1'b1;          // tell emu.sv to pulse load_flush
            // A seek issued while a menu PGC is loaded is a menu-internal
            // program/cell link (LinkPGN transition cell) -> hold the VBUF.
            // A title/gamepad transport seek (menu_dom=0) keeps vbuf_flush.
            keep_vbuf    <= menu_dom;
            if (!cell_mode) begin
                // LINEAR transport seek (raw VCD/SVCD .bin or a flat PS file):
                // whole-file single-extent stream, restart at the target block.
                strm_idx  <= 7'd0;
                strm_left <= 7'd1;
                if (raw_mode) begin
                    strm_blk     <= ls_blk;
                    raw_pos      <= ls_pos;
                    raw_m2       <= 1'b0;
                    raw_sec_pass <= 1'b0;   // drop the partial head sector
                    raw_wcnt     <= 12'd0;
                end else begin
                    strm_blk <= ls_tgt;
                    // flat PS: the output pipeline arms its pack hunt off this
                    // same seek_jump cycle (drop until 00 00 01 BA) so the
                    // demux can only re-sync on a real pack — never a slice
                    // code that would mis-latch ES passthrough.
                end
                state <= S_EXT_LOAD;
            end else if (seek_is_rbn) begin
                // Sub-cell scrub: scan the cell table for the cell whose RBN range
                // contains seek_rbn_l, then stream from that RBN (S_CELL_LOAD2 uses
                // rbn_override). cell_i is set by the scan when it lands.
                rbn_scan_i   <= 8'd0;
                cell_raddr   <= 8'd0;
                rbn_override <= 1'b1;
                // VOBU-align: a raw scrub target lands mid-VOBU, so the decoder
                // would re-lock mid-GOP (pixelated) and av_sync would anchor its
                // STC on the NEXT VOBU's video PTS (DVD video PES carry a PTS only
                // on the VOBU-first pack) -> a permanent sub-second audio lead.
                // Probe forward from the raw target to the first NAV pack so the
                // scrub landing matches the clean chapter-seek contract. Menu /
                // empty-cell keep the direct scan.
                if (cell_count == 8'd0) begin
                    state <= S_STREAM;         // empty cell list (shouldn't happen)
                end else if (menu_dom) begin
                    state <= S_RBN_SCAN2;      // menu scrub: no VOBU align, direct scan
                end else begin
                    nav_cand <= seek_rbn_l;    // walk up from the raw target
                    nav_left <= NAV_CAP[10:0];
                    strm_idx <= eff_base;       // extent-walk cursor (S_CELL_LOAD2 re-inits)
                    seek_cum <= 32'd0;
                    state    <= S_NAV_SEEK2;    // 1-cycle ext_*_q refresh, then probe
                end
            end else begin
                cell_i       <= seek_cell_l;
                cell_raddr   <= seek_cell_l;
                rbn_override <= 1'b0;
                state        <= S_CELL_LOAD;
            end
        end else begin
            case (state)

            // ------------------------------------------------------------
            S_INIT: begin
                if (total_blocks < 32'd17) begin
                    ext_mem[0] <= {32'd0, total_blocks};
                    best_base <= 7'd0; best_cnt <= 7'd1;
                    strm_idx  <= 7'd0; strm_left <= 7'd1;
                    strm_blk  <= 32'd0; strm_done <= 1'b0;
                    wr_ptr    <= 0;
                    state     <= S_EXT_LOAD;   // let ext_start_q/ext_blocks_q refresh first
                end else begin
                    // Probe file byte 0 first: a raw MODE2/2352 image (VCD/SVCD
                    // .bin) starts with the 12-byte CD sync there, block-aligned.
                    // Not raw -> S_CHK_RAW falls through to the LBA-16 CD001
                    // probe (one extra block read per mount, negligible).
                    vd_lba    <= 32'd16;
                    sec_lba   <= 32'd0;
                    fetch_base<= 11'd0;
                    fetch_ret <= S_CHK_RAW;
                    state     <= S_SECREAD;
                end
            end

            // ------------------------------------------------------------
            // Raw MODE2/2352 signature probe (shadow of file byte 0)
            S_CHK_RAW: begin
                if (raw2352 || riff_cdxa) begin
                    // Raw CD image -> whole-file linear stream through the
                    // deblocker (same extent setup as the flat-file fallback).
                    raw_mode     <= 1'b1;
                    raw_pos      <= riff_cdxa ? 12'd2308 : 12'd0;  // 2352-44
                    raw_m2       <= 1'b0;
                    raw_sec_pass <= 1'b0;
                    raw_wcnt     <= 12'd0;
                    ext_mem[0] <= {32'd0, total_blocks};
                    best_base <= 7'd0; best_cnt <= 7'd1;
                    strm_idx  <= 7'd0; strm_left <= 7'd1;
                    strm_blk  <= 32'd0; strm_done <= 1'b0;
                    wr_ptr    <= 0;
                    state     <= S_EXT_LOAD;
                end else begin
                    sec_lba   <= 32'd16;
                    fetch_base<= 11'd0;      // CD001 / type at sector start
                    fetch_ret <= S_CHK_VD0;
                    state     <= S_SECREAD;
                end
            end

            // ------------------------------------------------------------
            // Gather one 2048-byte ISO sector (one sd block) into parse_buf,
            // then hand off to the fetch sequencer.
            S_SECREAD: begin
                if (!blk_inflight) begin
                    sd_lba       <= sec_lba;
                    sd_rd        <= 1'b1;
                    blk_inflight <= 1'b1;
                end else begin
                    if (sd_ack) sd_rd <= 1'b0;
                    if (sd_ack_d && !sd_ack) begin
                        blk_inflight <= 1'b0;
                        // Every read is a whole sector now, so even a NAV-align
                        // probe (fetch_ret==S_NAV_CHK) leaves a fully-resident
                        // parse_buf and pb_sec can always claim residency.
                        pb_sec   <= sec_lba;
                        // A straddle cross-refill (fetch_cross) resumes the SAME
                        // fetch at the saved fi with fetch_xw=1 (wrapped reads);
                        // else a fresh fetch (fi=0), or a walker refill (fi=45 =
                        // FETCH_N via pb_skip -> S_FETCH exits with rbuf untouched).
                        fi       <= fetch_cross ? fi_save
                                                : (pb_skip ? 6'd45 : 6'd0);
                        fetch_xw    <= fetch_cross;
                        fetch_cross <= 1'b0;
                        pb_skip  <= 1'b0;
                        fi_cap_v <= 1'b0;
                        state    <= S_FETCH;
                    end
                end
            end

            // ------------------------------------------------------------
            // Copy parse_buf[fetch_base .. fetch_base+44] -> rbuf (1 byte/cyc,
            // 1-cycle read latency), then enter fetch_ret.
            S_FETCH: begin
                // Capture the previous byte first (valid even on the cross cycle:
                // it is the last in-sector byte, fetch_base+fi-1 <= 2047).
                if (fi_cap_v) rbuf[fi_cap] <= pb_rdata;
                // `fi != FETCH_N` keeps a walker refill (pb_skip forces fi=FETCH_N
                // to exit immediately) from mis-triggering the cross when its stale
                // fetch_base is large; a real cross only happens while fi < FETCH_N.
                if (!fetch_xw && fi != FETCH_N && fb_fi > 12'd2047) begin
                    // The byte at this fi lives in the NEXT sector. Refill parse_buf
                    // with sec_lba+1 (sec_lba still holds the fetch's base sector)
                    // and resume this same fetch with fetch_xw=1, preserving fi.
                    fi_save     <= fi;
                    fetch_cross <= 1'b1;
                    sec_lba     <= sec_lba + 32'd1;
                    fi_cap_v    <= 1'b0;
                    state       <= S_SECREAD;
                end else begin
                    fi_cap   <= fi;
                    fi_cap_v <= 1'b1;
                    if (fi == FETCH_N) begin
                        fi_cap_v <= 1'b0;
                        fetch_xw <= 1'b0;      // clear for the next fetch
                        state    <= fetch_ret;
                    end else
                        fi <= fi + 6'd1;
                end
            end

            // ------------------------------------------------------------
            // CD001 + PVD type
            S_CHK_VD0: begin
                if (!cd001) begin
                    // Not ISO9660 -> flat-file fallback (whole file linear)
                    ext_mem[0] <= {32'd0, total_blocks};
                    best_base <= 7'd0; best_cnt <= 7'd1;
                    strm_idx  <= 7'd0; strm_left <= 7'd1;
                    strm_blk  <= 32'd0; strm_done <= 1'b0;
                    wr_ptr    <= 0;
                    state     <= S_EXT_LOAD;   // let ext_start_q/ext_blocks_q refresh first
                end else if (vd_type == 8'd1) begin
                    // PVD present in parse_buf; shadow its root record @156
                    iso_mode   <= 1'b1;
                    fetch_base <= 11'd156;
                    fetch_ret  <= S_CHK_VD1;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_FETCH;
                end else if (vd_type == 8'd255 || vd_lba >= 32'd32) begin
                    iso_mode  <= 1'b1;
                    iso_error <= 1'b1;
                    state     <= S_ERROR;
                end else begin
                    vd_lba    <= vd_lba + 32'd1;
                    sec_lba   <= vd_lba + 32'd1;
                    fetch_base<= 11'd0;
                    fetch_ret <= S_CHK_VD0;
                    state     <= S_SECREAD;
                end
            end

            // ------------------------------------------------------------
            // PVD root directory record -> start walking the root directory
            S_CHK_VD1: begin
                dir_lba    <= root_lba;
                dir_remain <= root_len;
                sec_lba    <= root_lba;
                p          <= 12'd0;
                fetch_base <= 11'd0;
                fetch_ret  <= S_WALK_ROOT;
                state      <= S_SECREAD;
            end

            // ------------------------------------------------------------
            // Root directory: find the VIDEO_TS subdirectory
            S_WALK_ROOT: begin
                if (rec_ok) begin
                    if (name_is_videots) begin
                        dir_lba    <= rec_extlba;
                        dir_remain <= rec_datalen;
                        sec_lba    <= rec_extlba;
                        p          <= 12'd0;
                        fetch_base <= 11'd0;
                        fetch_ret  <= S_WALK_VTS;
                        state      <= S_SECREAD;
                    end else begin
                        p          <= p + rec_len_b;
                        fetch_base <= (p + rec_len_b);
                        fetch_ret  <= S_WALK_ROOT;
                        fi         <= 6'd0;
                        fi_cap_v   <= 1'b0;
                        state      <= S_FETCH;
                    end
                end else begin
                    if (dir_remain > 32'd2048) begin
                        dir_remain <= dir_remain - 32'd2048;
                        dir_lba    <= dir_lba + 32'd1;
                        sec_lba    <= dir_lba + 32'd1;
                        p          <= 12'd0;
                        fetch_base <= 11'd0;
                        fetch_ret  <= S_WALK_ROOT;
                        state      <= S_SECREAD;
                    end else begin
                        iso_error <= 1'b1;   // VIDEO_TS not found
                        state     <= S_ERROR;
                    end
                end
            end

            // ------------------------------------------------------------
            // VIDEO_TS: enumerate title VOBs, accumulate the largest VTS group
            S_WALK_VTS: begin
                if (rec_ok) begin
                    // Latch the VMGI (VIDEO_TS.IFO) LBA for later TT_SRPT parse.
                    if (name_is_vmgi_ifo) begin
                        vmgi_lba   <= rec_extlba;
                        vmgi_found <= 1'b1;
                    end
                    // VIDEO_TS.VOB = VMGM_VOBS (the VMG menu VOB) - Phase 2.
                    if (name_is_vmgm_vob) begin
                        vmgm_vob_lba <= rec_extlba;
                        vmgm_vob_blk <= rec_blocks;
                    end
                    // Latch a VTS_xx_0.IFO (VTSI) LBA; it name-sorts just before
                    // its group's title VOBs, so hold it "pending" until the group
                    // opens (below) and commit it to that group. Same for
                    // VTS_xx_0.VOB (the VTS menu VOB, sorts after _0.IFO).
                    if (name_is_vts_ifo) begin
                        pending_ifo_lba <= rec_extlba;
                        pending_ifo_vts <= vts_num;
                    end
                    if (is_vts_vob && part_num==8'd0) begin
                        pending_mnu_lba <= rec_extlba;
                        pending_mnu_blk <= rec_blocks;
                        pending_mnu_vts <= vts_num;
                    end
                    if (is_vts_vob && part_num>=8'd1 && part_num<=8'd9 && all_n<MAXEXT) begin
                        if (vts_num != grp_vts) begin
                            if (grp_valid && grp_total > best_total) begin
                                best_total   <= grp_total;
                                best_base    <= grp_base;
                                best_cnt     <= all_n - grp_base;
                                best_ifo_lba <= grp_ifo_lba;
                                best_vtsn    <= grp_vts;
                            end
                            // Record the closing group in the selection table
                            // (nonblocking -> reads the pre-reassignment grp_* regs).
                            if (grp_valid && grp_count < MAXGRP) begin
                                gmem[grp_count] <= {grp_vts, grp_base,
                                                    (all_n - grp_base), grp_ifo_lba,
                                                    grp_mnu_lba, grp_mnu_blk};
                                grp_count       <= grp_count + 7'd1;
                            end
                            if (grp_valid && grp_mnu_blk > best_mnu_blk) begin
                                best_mnu_blk <= grp_mnu_blk;   // largest menu VOB -> fallback
                                best_mnu_vts <= grp_vts;
                            end
                            grp_base  <= all_n;
                            grp_total <= rec_datalen;
                            grp_vts   <= vts_num;
                            grp_valid <= 1'b1;
                            // Commit the pending VTSI / menu-VOB records to this group.
                            grp_ifo_lba <= (pending_ifo_vts == vts_num) ? pending_ifo_lba : 32'd0;
                            grp_mnu_lba <= (pending_mnu_vts == vts_num) ? pending_mnu_lba : 32'd0;
                            grp_mnu_blk <= (pending_mnu_vts == vts_num) ? pending_mnu_blk : 32'd0;
                        end else begin
                            grp_total <= grp_total + rec_datalen;
                        end
                        ext_mem[all_n] <= {rec_startblk, rec_blocks};
                        all_n          <= all_n + 7'd1;
                    end
                    p          <= p + rec_len_b;
                    fetch_base <= (p + rec_len_b);
                    fetch_ret  <= S_WALK_VTS;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_FETCH;
                end else begin
                    if (dir_remain > 32'd2048) begin
                        dir_remain <= dir_remain - 32'd2048;
                        dir_lba    <= dir_lba + 32'd1;
                        sec_lba    <= dir_lba + 32'd1;
                        p          <= 12'd0;
                        fetch_base <= 11'd0;
                        fetch_ret  <= S_WALK_VTS;
                        state      <= S_SECREAD;
                    end else begin
                        state <= S_FINALIZE;
                    end
                end
            end

            // ------------------------------------------------------------
            S_FINALIZE: begin
                nav_ready <= 1'b1;              // VM jumps accepted from here on
                if (grp_valid && grp_total > best_total) begin
                    best_total   <= grp_total;
                    best_base    <= grp_base;
                    best_cnt     <= all_n - grp_base;
                    best_ifo_lba <= grp_ifo_lba;
                    best_vtsn    <= grp_vts;
                end
                // Record the final open group in the selection table.
                if (grp_valid && grp_count < MAXGRP) begin
                    gmem[grp_count] <= {grp_vts, grp_base,
                                        (all_n - grp_base), grp_ifo_lba,
                                        grp_mnu_lba, grp_mnu_blk};
                    grp_count       <= grp_count + 7'd1;
                end
                if (grp_valid && grp_mnu_blk > best_mnu_blk) begin
                    best_mnu_blk <= grp_mnu_blk;
                    best_mnu_vts <= grp_vts;
                end
                // Title selection:
                //   - OSD manual "DVD Title" (title_sel != 0) -> play VTS # N
                //     (reuses the S_SELECT group scan with target = title_sel).
                //     Needed for multi-feature discs (e.g. Big Buck Bunny) where
                //     the wanted feature is neither the largest nor title 1, so no
                //     heuristic finds it; a manual VTS # not present funnels to
                //     S_SELECT's largest fallback.
                //   - Auto (title_sel == 0) -> the LARGEST VTS (best_base, by total
                //     title-VOB bytes) = the longest-title proxy. This replaced the
                //     old VMGI TT_SRPT "title 1" pick, which chose a short
                //     license/logo clip on discs where title 1 isn't the feature.
                //     (The S_IFO_MAT/TSRPT title-1 states are now unreachable but
                //     retained; S_SELECT is still used for the manual pick.) The
                //     real fix for ambiguous discs is the graphical DVD menu.
                // Both converge on S_PGC_BEGIN for the PGC cell-timeline parse.
                // Phase-4: with Disc Menus on, the reader IDLES here and the
                // DVD-VM boots the disc (First Play PGC) - nothing auto-plays.
                // The VM's fallback chain ends in a TT jump to auto_vts, so a
                // broken FP still reaches this same title selection.
                if (vm_mode) begin
                    state <= S_DONE;
                end else if (title_sel != 7'd0) begin
                    target_vtsn <= {1'd0, title_sel};
                    sel_i       <= 7'd0;
                    state       <= S_SELECT2;  // wait for gmem_q to refresh, then scan
                end else
                    state <= S_PGC_BEGIN;      // Auto = largest VTS
            end

            // ------------------------------------------------------------
            // Linear whole-VTS streaming setup (flat-file fallback + any PGC
            // parse failure). Streams the effective winner's extents back to back.
            S_FINAL2: begin
                if (eff_cnt > 7'd0) begin
                    strm_idx  <= eff_base;
                    strm_left <= eff_cnt;
                    strm_blk  <= 32'd0;
                    strm_done <= 1'b0;
                    cell_mode <= 1'b0;
                    wr_ptr    <= 0;
                    state     <= S_EXT_LOAD;   // let ext_start_q/ext_blocks_q refresh first
                end else begin
                    iso_error <= 1'b1;
                    state     <= S_ERROR;
                end
            end

            // ------------------------------------------------------------
            // IFO title selection: read the VMGI (VIDEO_TS.IFO) sector and
            // shadow bytes @196.. to get the TT_SRPT sector pointer.
            S_IFO_MAT: begin
                sec_lba    <= vmgi_lba;
                fetch_base <= 11'd196;
                fetch_ret  <= S_IFO_MAT_PARSE;
                fi         <= 6'd0;
                fi_cap_v   <= 1'b0;
                state      <= S_SECREAD;
            end

            // ------------------------------------------------------------
            // tt_srpt is a sector ptr relative to the IFO start (BE). Read the
            // TT_SRPT sector; bail to the largest-VTS fallback if it's absent.
            S_IFO_MAT_PARSE: begin
                if (tt_srpt_ptr == 32'd0 || tt_srpt_ptr > 32'd65535) begin
                    state <= S_PGC_BEGIN;              // malformed -> largest-VTS
                end else begin
                    sec_lba    <= vmgi_lba + tt_srpt_ptr;
                    fetch_base <= 11'd0;
                    fetch_ret  <= S_IFO_TSRPT;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            // ------------------------------------------------------------
            // TT_SRPT: nr_of_srpts@0 (BE) + TT_SRP[0].title_set_nr@14 = the VTS
            // that holds title 1 (the conventional main feature).
            S_IFO_TSRPT: begin
                target_vtsn <= ttsrp0_vtsn;
                if (nr_of_srpts == 16'd0 || ttsrp0_vtsn == 8'd0) begin
                    state <= S_PGC_BEGIN;              // no titles -> largest-VTS
                end else begin
                    sel_i <= 7'd0;
                    state <= S_SELECT2;   // wait for gmem_q to refresh, then scan
                end
            end

            // ------------------------------------------------------------
            // Scan the group table for a target VTS (sync-read M10K: gmem_q
            // tracks sel_i, so each step is S_SELECT2 (wait) -> S_SELECT
            // (eval)). Two callers: sel_ret=0 selects the TITLE (match ->
            // sel_* overwritten, exhausted -> largest-VTS fallback); sel_ret=1
            // is a VTSM menu jump (match -> read VTSI@208, no sel_* clobber,
            // exhausted -> pgc_error).
            S_SELECT2: state <= S_SELECT;          // gmem_q now holds gmem[sel_i]
            S_SELECT: begin
                if (sel_i >= grp_count) begin
                    if (sel_ret) begin
                        pgc_error <= 1'b1;             // VTS not found -> menu jump fails
                        dbg_pgcerr <= {3'd7, ((nr_srp_l > 16'd31) ? 5'd31 : nr_srp_l[4:0]), want_pgcn[7:0]};
                        state     <= S_DONE;
                    end else
                        state <= S_PGC_BEGIN;          // not found -> largest-VTS
                end else if (gq_vts == target_vtsn) begin
                    if (sel_ret) begin
                        // Need the VTSI (to find the PGCI_UT); the menu VOB is
                        // OPTIONAL - a VTSM PGC may be a command-only dispatcher
                        // (menu_blocks==0 -> S_PGC_CELLCHK treats a 0-cell PGC
                        // as a command stub the VM runs; see DOM_VMGM).
                        if (gq_ifo_lba != 32'd0) begin
                            jmp_ifo_lba   <= gq_ifo_lba;
                            menu_base_blk <= gq_mnu_lba;
                            menu_blocks   <= gq_mnu_blk;   // 0 if no VTSM VOB
                            sec_lba    <= gq_ifo_lba;
                            fetch_base <= 11'd208;     // VTSI_MAT.vtsm_pgci_ut @208
                            fetch_ret  <= S_JMP_VTSM;
                            fi         <= 6'd0;
                            fi_cap_v   <= 1'b0;
                            state      <= S_SECREAD;
                        end else begin
                            pgc_error <= 1'b1;         // no VTSI / no menu VOB
                            dbg_pgcerr <= {3'd7, ((nr_srp_l > 16'd31) ? 5'd31 : nr_srp_l[4:0]), want_pgcn[7:0]};
                            state     <= S_DONE;
                        end
                    end else begin
                        sel_base    <= gq_base;
                        sel_cnt     <= gq_cnt;
                        sel_ifo_lba <= gq_ifo_lba;
                        sel_valid   <= 1'b1;
                        state       <= S_PGC_BEGIN;
                    end
                end else begin
                    sel_i <= sel_i + 7'd1;
                    state <= S_SELECT2;               // reload gmem_q for the next index
                end
            end

            // ------------------------------------------------------------
            // PGC / cell-timeline parse. Reads the selected VTS's VTS_xx_0.IFO
            // (VTSI_MAT -> VTS_PGCIT -> PGC -> cell playback table) and builds a
            // program-order cell list {cell_first, cell_last}. Positions are
            // tracked as (2048-sector LBA, 11-bit offset) pairs; each field is
            // read by pointing the shadow (fetch_base) at the field so it lands
            // in rbuf[0..15]. Any malformed/absent PGC -> S_FINAL2 (linear).
            S_PGC_BEGIN: begin
                dom      <= DOM_TT;                    // title path (mount + TT jump)
                menu_dom <= 1'b0;
                play_vtsn <= sel_valid ? target_vtsn : best_vtsn;
                // Phase-10: the VTSI_MAT sector these branches read in also
                // carries the audio/subpicture stream-attribute tables. Sweep
                // them out (S_ATTR) once the sector is resident, THEN resume
                // the normal PGC parse. The rbuf shadow fetched below (@200 /
                // @204) is untouched by the sweep (it reads parse_buf directly),
                // so attr_resume proceeds exactly as before.
                if (iso_mode && eff_ifo_lba != 32'd0) begin
                    // Both Auto and jump mounts fetch VTSI@200 (vts_ptt_srpt) so
                    // the Phase-6 PTT-table load (S_PTTLD_*) can run for the
                    // current title BEFORE the PGC parse; S_PTTLD_DONE re-fetches
                    // the resume field (@200 for the jump's S_PTT_MAT part-resolve,
                    // @204 for Auto's S_PGC_MAT) so ptt_resume proceeds unchanged.
                    sec_lba    <= eff_ifo_lba;
                    fetch_base <= 11'd200;             // VTSI_MAT.vts_ptt_srpt @200
                    fetch_ret  <= S_ATTR_RD;
                    attr_resume<= S_PTTLD_MAT;
                    attr_phase <= 1'b0; attr_cnt_pending <= 1'b1;
                    attr_addr  <= 11'd515;             // nr_of_vts_audio_streams
                    attr_idx   <= 3'd0; attr_j <= 3'd0;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end else begin
                    state <= S_FINAL2;                 // no VTSI -> linear
                end
            end

            // ---------------------------------------------------------------
            // Phase-10 track-attribute sweep. Walks the resident VTSI_MAT
            // sector: audio count @515 + vts_audio_attr[8] @516 (stride 8),
            // then subp count @597 + vts_subp_attr[32] @598 (stride 6, first 8
            // routable). Two cycles per byte (S_ATTR_RD sets the parse_buf
            // address, S_ATTR_CAP consumes the 1-cycle-late pb_rdata). ~120
            // cycles, one-off at the title mount. Resumes attr_resume.
            S_ATTR_RD: state <= S_ATTR_CAP;   // pb_raddr = attr_addr; latch next cycle
            S_ATTR_CAP: begin
                if (attr_cnt_pending) begin
                    // stream-count byte. Clamp to 1..8 (a switch needs >=1 valid
                    // target; only the low-8 substreams are routable).
                    if (!attr_phase)
                        audio_ntracks <= (pb_rdata == 8'd0) ? 4'd1 :
                                         (pb_rdata >  8'd8) ? 4'd8 : pb_rdata[3:0];
                    else
                        subp_ntracks  <= (pb_rdata == 8'd0) ? 4'd1 :
                                         (pb_rdata >  8'd8) ? 4'd8 : pb_rdata[3:0];
                    attr_cnt_pending <= 1'b0;
                    attr_addr <= attr_phase ? 11'd598 : 11'd516;  // table base
                    attr_idx  <= 3'd0; attr_j <= 3'd0;
                    state     <= S_ATTR_RD;
                end else begin
                    // attribute byte attr_j of stream attr_idx
                    if (!attr_phase) begin
                        case (attr_j)
                          3'd0: a_fmt_mem [attr_idx] <= pb_rdata[7:5];       // audio_format
                          3'd1: a_ch_mem  [attr_idx] <= {1'b0, pb_rdata[2:0]} + 4'd1;
                          3'd2: a_lang_mem[attr_idx][15:8] <= pb_rdata;      // lang hi
                          3'd3: a_lang_mem[attr_idx][7:0]  <= pb_rdata;      // lang lo
                          default: ;                                        // bytes 4..7 unused
                        endcase
                    end else begin
                        case (attr_j)
                          3'd2: s_lang_mem[attr_idx][15:8] <= pb_rdata;      // lang hi
                          3'd3: s_lang_mem[attr_idx][7:0]  <= pb_rdata;      // lang lo
                          default: ;                                        // byte0=type,4,5 unused
                        endcase
                    end
                    attr_addr <= attr_addr + 11'd1;
                    if (attr_j == (attr_phase ? 3'd5 : 3'd7)) begin
                        attr_j <= 3'd0;
                        if (attr_idx == 3'd7) begin
                            // finished this table (all 8 routable streams read)
                            if (!attr_phase) begin
                                attr_phase       <= 1'b1;
                                attr_cnt_pending <= 1'b1;
                                attr_addr        <= 11'd597;   // subp count
                                attr_idx <= 3'd0;
                                state <= S_ATTR_RD;
                            end else begin
                                state <= attr_resume;          // sweep done
                            end
                        end else begin
                            attr_idx <= attr_idx + 3'd1;
                            state <= S_ATTR_RD;
                        end
                    end else begin
                        attr_j <= attr_j + 3'd1;
                        state <= S_ATTR_RD;
                    end
                end
            end

            // VTS_PTT_SRPT resolve (vts_ttn -> pgcn). @200 = sector ptr rel VTSI.
            S_PTT_MAT: begin
                if (vts_pgcit_ptr == 32'd0 || vts_pgcit_ptr > 32'd1048575 ||
                    want_ttn == 7'd0) begin
                    // no PTT table -> fall back to the title-entry scan (@204;
                    // want_ttn kept so S_PGCIT_HDR scans by title, else SRP[0]).
                    sec_lba    <= eff_ifo_lba;
                    fetch_base <= 11'd204;
                    fetch_ret  <= S_PGC_MAT;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end else begin
                    ptt_srpt_lba <= eff_ifo_lba + vts_pgcit_ptr;
                    // read ttu_offset[ttn-1] = u32 @ 8 + 4*(ttn-1) = 4*ttn + 4
                    sec_lba    <= eff_ifo_lba + vts_pgcit_ptr;
                    fetch_base <= {2'b00, want_ttn, 2'b00} + 11'd4;
                    fetch_ret  <= S_PTT_OFF;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            // ttu_offset[ttn-1] (BE u32, byte offset rel. VTS_PTT_SRPT) -> read
            // ptt[part-1] {pgcn u16@0, pgn u16@2}. Phase 6: EXACT chapter/PTT --
            // add 4*(jptt_l-1) to the TTU base so JumpVTS_PTT / LinkPTTN land on
            // the requested part's {pgcn, pgn} (jptt_l 0/1 -> ptt[0] = the title
            // entry, unchanged). eff_ptt_off = ttu_off + 4*(part-1); this crosses
            // sectors via the >>11 / [10:0] split like any other IFO field read.
            S_PTT_OFF: begin
                if (vts_pgcit_ptr == 32'd0 || vts_pgcit_ptr > 32'd2097151) begin
                    // bad ttu offset -> title-entry scan (want_ttn preserved)
                    sec_lba    <= eff_ifo_lba;
                    fetch_base <= 11'd204;
                    fetch_ret  <= S_PGC_MAT;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end else begin
                    sec_lba    <= ptt_srpt_lba + (eff_ptt_off[20:0] >> 11);
                    fetch_base <= eff_ptt_off[10:0];
                    fetch_ret  <= S_PTT_PGC;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            // ptt[part-1].pgcn -> want_pgcn (direct SRP pick); .pgn -> start
            // program (P_PMAP start-cell latch). Phase 6: for an exact part
            // (jptt_l > 1) the pgn is authoritative even when 1 (a chapter can
            // start at program 1 of a LATER PGC), so set jpgn_l whenever valid.
            S_PTT_PGC: begin
                want_ttn <= 7'd0;
                jptt_l   <= 11'd0;                     // resolve consumed
                // DVD-FORK FIX: the old `> 255 -> garbage` guard WAS the clamp
                // (PGCN is a 15-bit field); only 0 is invalid now.
                if (nr_pgci_srp == 16'd0) begin
                    want_pgcn <= 16'd1;                // garbage -> PGCN 1
                end else begin
                    want_pgcn <= nr_pgci_srp;          // = ptt[part-1].pgcn (u16)
                    if (ptt_pgn >= 16'd1 && ptt_pgn <= 16'd255)
                        jpgn_l <= ptt_pgn[7:0];        // start at program pgn
                end
                sec_lba    <= eff_ifo_lba;
                fetch_base <= 11'd204;                 // VTSI_MAT.vts_pgcit @204
                fetch_ret  <= S_PGC_MAT;
                fi         <= 6'd0;
                fi_cap_v   <= 1'b0;
                state      <= S_SECREAD;
            end

            // ---- Phase-6 PTT-table load (resident ptt_mem for the mounted
            // title) -----------------------------------------------------------
            // Entered after the @200 shadow is resident (vts_pgcit_ptr wire =
            // vts_ptt_srpt sector ptr). Reads VTS_PTT_SRPT header + the current
            // title's TTU span, then streams {pgcn,pgn} per chapter into ptt_mem
            // (P_PTT walker). Always exits via S_PTTLD_DONE, which restores the
            // resume field the PGC parse needs. cur_ttn = the loaded title's
            // vts_ttn (want_ttn on a jump, else 1 = the Auto main title).
            S_PTTLD_MAT: begin
                cur_ttn    <= (want_ttn != 7'd0) ? want_ttn : 7'd1;
                nr_ptt     <= 11'd0;
                ptt_resume <= (want_ttn != 7'd0) ? S_PTT_MAT : S_PGC_MAT;
                if (vts_pgcit_ptr == 32'd0 || vts_pgcit_ptr > 32'd1048575) begin
                    state <= S_PTTLD_DONE;             // no PTT table
                end else begin
                    ptt_srpt_lba <= eff_ifo_lba + vts_pgcit_ptr;
                    sec_lba    <= eff_ifo_lba + vts_pgcit_ptr;
                    fetch_base <= 11'd0;               // VTS_PTT_SRPT header @0
                    fetch_ret  <= S_PTTLD_HDR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            // header: nr_of_srpts@0, last_byte@4. Validate cur_ttn, then read the
            // two adjacent ttu_offsets (ttn-1 @8+4*(ttn-1), ttn @+4) in one shadow.
            S_PTTLD_HDR: begin
                ptt_nr_srpt   <= nr_of_srpts;
                ptt_last_byte <= rbuf_be32_4;          // last_byte @4
                if (nr_of_srpts == 16'd0 ||
                    {9'd0, cur_ttn} > nr_of_srpts) begin
                    state <= S_PTTLD_DONE;             // ttn out of range -> no table
                end else begin
                    sec_lba    <= ptt_srpt_lba +
                                  (({2'b00, cur_ttn, 2'b00} + 11'd4) >> 11);
                    fetch_base <= ({2'b00, cur_ttn, 2'b00} + 11'd4);  // 8+4*(ttn-1)
                    fetch_ret  <= S_PTTLD_OFF;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            // ttu_offset[ttn-1] = rbuf[0..3], ttu_offset[ttn] = rbuf[4..7]. Span
            // -> nr_ptt (clamped to PTT_CAP). Launch the P_PTT walker over the TTU.
            S_PTTLD_OFF: begin : pttoff
                reg [31:0] ttu0, ttu1, span, cnt;
                reg [10:0] cnt_c;
                ttu0 = tt_srpt_ptr;                    // ttu_offset[ttn-1]
                ttu1 = ({9'd0, cur_ttn} < ptt_nr_srpt) ? rbuf_be32_4
                                                       : (ptt_last_byte + 32'd1);
                span = (ttu1 > ttu0) ? (ttu1 - ttu0) : 32'd0;
                cnt  = span >> 2;
                cnt_c = (cnt > {21'd0, PTT_CAP}) ? PTT_CAP : cnt[10:0];
                ptt_base_off <= ttu0[20:0];
                if (cnt == 32'd0 || ttu0 > 32'd2097151) begin
                    nr_ptt <= 11'd0;
                    state  <= S_PTTLD_DONE;
                end else begin
                    nr_ptt    <= cnt_c;
                    walk_sec  <= ptt_srpt_lba + (ttu0[20:0] >> 11);
                    walk_off  <= ttu0[10:0];
                    walk_left <= {cnt_c, 2'b00};        // 4 * cnt_c bytes
                    walk_idx  <= 13'd0;
                    wphase    <= P_PTT;
                    state     <= S_WALK_RD;
                end
            end

            // Restore the resume field then continue the normal mount: the jump
            // path re-reads VTSI@200 (S_PTT_MAT needs vts_ptt_srpt), Auto re-reads
            // VTSI@204 (S_PGC_MAT needs vts_pgcit). vts_pgcit_ptr is a live tap of
            // the shadow, so the resume state reads the right value next.
            S_PTTLD_DONE: begin
                sec_lba    <= eff_ifo_lba;
                fetch_base <= (ptt_resume == S_PTT_MAT) ? 11'd200 : 11'd204;
                fetch_ret  <= ptt_resume;
                fi         <= 6'd0;
                fi_cap_v   <= 1'b0;
                state      <= S_SECREAD;
            end

            // vts_pgcit: sector ptr rel. to VTSI start (BE). The title PGCIT is
            // sector-aligned (pit_off = 0); enter the generalized PGCIT path.
            S_PGC_MAT: begin
                if (vts_pgcit_ptr == 32'd0 || vts_pgcit_ptr > 32'd1048575) begin
                    state <= S_FINAL2;
                end else begin
                    pit_sec    <= eff_ifo_lba + vts_pgcit_ptr;
                    pit_off    <= 11'd0;
                    sec_lba    <= eff_ifo_lba + vts_pgcit_ptr;
                    fetch_base <= 11'd0;               // nr_pgci_srp@0
                    fetch_ret  <= S_PGCIT_HDR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            // ------------------------------------------------------------
            // Generalized PGCIT entry (title VTS_PGCIT or a menu PGCI LU):
            // nr_of_pgci_srp@0, then pick SRP[want_pgcn-1] directly or scan
            // for the entry_id (want_pgcn==0, menu domains).
            S_PGCIT_HDR: begin
                nr_srp_l <= nr_pgci_srp;
                if (nr_pgci_srp == 16'd0) begin
                    if (jump_ctx && dom != DOM_TT) begin
                        pgc_error <= 1'b1;
                        dbg_pgcerr <= {3'd1, 5'd0, want_pgcn[7:0]};
                        state     <= S_DONE;
                    end else
                        state <= S_FINAL2;             // no PGCs -> linear title
                end else if (want_pgcn != 16'd0) begin
                    if (want_pgcn <= nr_pgci_srp) begin
                        srp_i     <= want_pgcn - 16'd1;
                        scan_mode <= 1'b0;
                        state     <= S_SRP_FETCH;
                    end else if (jump_ctx && dom != DOM_TT) begin
                        pgc_error <= 1'b1;     // requested PGCN out of range
                        dbg_pgcerr <= {3'd2, ((nr_pgci_srp > 16'd31) ? 5'd31 : nr_pgci_srp[4:0]), want_pgcn[7:0]};
                        state     <= S_DONE;
                    end else
                        state <= S_FINAL2;
                end else begin
                    srp_i      <= 16'd0;               // scan for want_entry/ttn
                    scan_mode  <= 1'b1;
                    // Phase-4: title PGCITs are scanned by TITLE number
                    // (entry bit7 + low7 == want_ttn), menu PGCITs by menu
                    // entry type (bit7 + low nibble == want_entry).
                    scan_title <= (dom == DOM_TT);
                    state      <= S_SRP_FETCH;
                end
            end

            // Read SRP[srp_i] (8 B @ PGCIT+8+8*srp_i, sector-normalized).
            S_SRP_FETCH: begin
                // DVD-FORK FIX: srp_i is 16 bits now (PGCITs > 255 entries), so
                // srp_i*8 needs 19 bits - the old 17-bit expression overflowed.
                sec_lba    <= pit_sec + (({10'b0,pit_off} + 21'd8 + {2'b0,srp_i,3'b000}) >> 11);
                fetch_base <= (({10'b0,pit_off} + 21'd8 + {2'b0,srp_i,3'b000})) & 21'h007FF;
                fetch_ret  <= S_SRP_EVAL;
                fi         <= 6'd0;
                fi_cap_v   <= 1'b0;
                state      <= S_SECREAD;
            end

            // Entry match / take. Scanning (menu, pgcn==0): accept the first
            // SRP with entry bit7 set and the low nibble == want_entry; if the
            // scan exhausts, fall back to SRP[0] (= PGCN 1). Taking: position
            // the PGC (pgc_start_byte@4 rel. PGCIT) and read its header.
            S_SRP_EVAL: begin
                if (scan_mode && !(srp_entry_id[7] &&
                                   (scan_title ? (srp_entry_id[6:0] == want_ttn)
                                               : (srp_entry_id[3:0] == want_entry)))) begin
                    if (srp_i + 16'd1 < nr_srp_l && srp_i != 16'hFFFF) begin
                        srp_i <= srp_i + 16'd1;
                        state <= S_SRP_FETCH;
                    end else begin
                        scan_mode  <= 1'b0;            // no entry match -> SRP[0]
                        scan_title <= 1'b0;
                        srp_i      <= 16'd0;
                        state      <= S_SRP_FETCH;
                    end
                end else if (srp_pgc_start[31:21] != 11'd0) begin
                    // pgc_start_byte beyond 2 MB = malformed PGCIT
                    if (jump_ctx && dom != DOM_TT) begin
                        pgc_error <= 1'b1;
                        dbg_pgcerr <= {3'd3, ((nr_srp_l > 16'd31) ? 5'd31 : nr_srp_l[4:0]), want_pgcn[7:0]};
                        state     <= S_DONE;
                    end else
                        state <= S_FINAL2;
                end else begin
                    scan_mode   <= 1'b0;
                    scan_title  <= 1'b0;
                    cur_pgcn    <= srp_i + 16'd1;
                    link_pgcn_u <= 16'd0;
                    link_pgcn_c <= 16'd0;
                    pgc_sec    <= pit_sec + (({10'b0,pit_off} + srp_pgc_start[20:0]) >> 11);
                    pgc_off    <= (({10'b0,pit_off} + srp_pgc_start[20:0])) & 21'h007FF;
                    sec_lba    <= pit_sec + (({10'b0,pit_off} + srp_pgc_start[20:0]) >> 11);
                    fetch_base <= (({10'b0,pit_off} + srp_pgc_start[20:0])) & 21'h007FF;
                    fetch_ret  <= S_PGC_HDR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            // Latch nr_of_cells, then WALK the PGC header window @156..233
            // (next/prev/goup@156/158/160, mode@162, still@163, palette@164
            // -> pgc_palette, command_tbl@228, cell_playback@232). The walker
            // crosses sector boundaries, so straddling PGCs (Matrix/T2 menu
            // PGCITs) parse fine - the Phase-1 "skip palette on straddle"
            // limitation is gone. The palette loads INDEPENDENTLY of the
            // cell-count sanity check (the MiB white-subtitles lesson).
            S_PGC_HDR: begin
                // STRADDLE AUDIT: the give-up guard is GONE. The pre-walk header
                // bytes -- nr_of_programs (rbuf[2]), nr_of_cells (rbuf[3]) and the
                // cosmetic playback_time (rbuf[4..7]) -- are read from the rbuf
                // shadow, which is now SECTOR-CROSSING (fetch_xw): a PGC header that
                // starts in the last bytes of a sector reads all of @2..@7 correctly
                // from the next sector instead of wrapping to parse_buf[0]. The old
                // `pgc_off > 2044 -> pgc_error/S_FINAL2` bail (which dead-ended a
                // menu PGC at off 2045-2047, and forced Atmosfear PGC13 at the exact
                // 2044 boundary) is no longer needed. The @156..233 window is walked
                // by the sector-crossing walker as before.
                begin
                    nr_cells <= nr_of_cells_b;         // validity checked in S_PGC_CELLCHK
                    // PGC total playback time (PGC@4..7, BCD dvd_time) for the
                    // Phase-7 current/total-time UI readout - straddle-safe now.
                    pgc_playback_time <= {rbuf[4], rbuf[5], rbuf[6], rbuf[7]};
                    // nr_of_programs (PGC@2) - bounds the P_PMAP walk and the
                    // VM's program-links; clamp to the 99-program DVD limit.
                    cmd_nr_pgm <= (rbuf[2] > 8'd99) ? 8'd0 : rbuf[2];
                    pgc_still_time <= 8'd0;
                    next_pgcn <= 16'd0;
                    prev_pgcn <= 16'd0;
                    goup_pgcn <= 16'd0;
                    cmd_tbl_off    <= 16'd0;
                    cell_pb_off16  <= 16'd0;
                    prog_map_off16 <= 16'd0;
                    // EVERY domain first walks audio_control[8] (PGC@0x0C, 16 B)
                    // -> pgc_ctl_we addr 16..23 (menus resolve logical audio 0
                    // through it too, per libdvdnav vmget.c). audio_control is
                    // CONTIGUOUS with subp_control @0x1C, so a TITLE PGC then
                    // rolls straight into P_SUBP with no re-seek; menu/FP
                    // domains re-seek to the @156 header (P_HDR) - menu buttons
                    // force subpicture stream 0 anyway. pgc_ctl_valid drops for
                    // the duration of the parse (emu gates aud_switch on it so
                    // the streaming words can't glitch a track resync).
                    pgc_ctl_valid <= 1'b0;
                    walk_sec  <= pgc_sec + (({1'b0,pgc_off} + 12'd12) >> 11);
                    walk_off  <= ({1'b0,pgc_off} + 12'd12) & 12'h7FF;
                    walk_left <= 13'd16;               // 8 streams x 2 bytes
                    walk_idx  <= 13'd0;
                    wphase    <= P_ACTL;
                    state     <= S_WALK_RD;
                end
            end

            // ------------------------------------------------------------
            // Sector-crossing byte walker: S_WALK_RD addresses parse_buf (or
            // refills it when the walk moved past the resident sector - the
            // rbuf fetch is skipped via fi=FETCH_N), S_WALK_CAP consumes the
            // byte and dispatches per phase. 2 cycles/byte + ~ms per sector
            // refill; all parse-time, nowhere near the streaming path.
            S_WALK_RD: begin
                if (walk_sec != pb_sec) begin
                    sec_lba    <= walk_sec;
                    pb_skip    <= 1'b1;                // skip the rbuf fetch
                    fi_cap_v   <= 1'b0;
                    fetch_ret  <= S_WALK_RD;
                    state      <= S_SECREAD;
                end else
                    state <= S_WALK_CAP;               // pb_rdata <= parse_buf[walk_off]
            end

            S_WALK_CAP: begin
                wacc <= {wacc[15:0], pb_rdata};
                if (walk_off == 11'd2047) begin
                    walk_off <= 11'd0;
                    walk_sec <= walk_sec + 32'd1;
                end else
                    walk_off <= walk_off + 11'd1;
                walk_idx  <= walk_idx + 13'd1;
                walk_left <= walk_left - 13'd1;
                state     <= S_WALK_RD;                // default: next byte

                case (wphase)
                // ----- audio_control[8]: PGC bytes 0x0C..0x1B (idx 0..15) -----
                // Emit one u16 per stream (BE, wdata[15:0]) at addr 16..23.
                // Title -> roll into P_SUBP (contiguous, no re-seek);
                // menu/FP -> the @156 header window.
                P_ACTL: begin
                    if (walk_idx[0]) begin
                        pgc_ctl_we    <= 1'b1;
                        pgc_ctl_waddr <= {2'b10, walk_idx[3:1]};  // 16 + stream 0..7
                        pgc_ctl_wdata <= {16'd0, wacc[7:0], pb_rdata};
                    end
                    if (walk_left == 13'd1) begin
                        // (pgc_ctl_valid rises one cycle later, off the last
                        // write pulse itself - see the we/waddr==23 clause -
                        // so a consumer never sees valid=1 while word 7 is
                        // still in flight.)
                        if (dom == DOM_TT) begin
                            // walk_off/walk_sec continue naturally into 0x1C
                            walk_left <= 13'd64;       // 16 streams x 4 bytes
                            walk_idx  <= 13'd0;
                            wphase    <= P_SUBP;
                        end else begin
                            walk_sec  <= pgc_sec + (({1'b0,pgc_off} + 12'd156) >> 11);
                            walk_off  <= ({1'b0,pgc_off} + 12'd156) & 12'h7FF;
                            walk_left <= 13'd78;
                            walk_idx  <= 13'd0;
                            wphase    <= P_HDR;
                        end
                    end
                end

                // ----- subp_control[16]: PGC bytes 0x1C..0x5B (idx 0..63) -----
                // Emit one 32-bit word per stream (BE), then walk the @156 header.
                P_SUBP: begin
                    if (walk_idx[1:0] == 2'd3) begin
                        pgc_ctl_we    <= 1'b1;
                        pgc_ctl_waddr <= {1'b0, walk_idx[5:2]};   // stream 0..15
                        pgc_ctl_wdata <= {wacc, pb_rdata};
                    end
                    if (walk_left == 13'd1) begin
                        // subp_control done -> the @156 PGC header window (P_HDR).
                        walk_sec  <= pgc_sec + (({1'b0,pgc_off} + 12'd156) >> 11);
                        walk_off  <= ({1'b0,pgc_off} + 12'd156) & 12'h7FF;
                        walk_left <= 13'd78;
                        walk_idx  <= 13'd0;
                        wphase    <= P_HDR;
                    end
                end

                // ----- PGC header window: bytes 156..233 (idx 0..77) -----
                P_HDR: begin
                    case (walk_idx)
                    // DVD-FORK FIX: capture the FULL u16 (the high byte was dropped,
                    // clamping next/prev/goup PGCN to 255 - same defect class as the
                    // LinkPGCN truncation; see docs/disc_sweep.md).
                    13'd0:  next_pgcn[15:8] <= pb_rdata;  // @156 (high byte of u16)
                    13'd1:  next_pgcn[7:0]  <= pb_rdata;  // @157
                    13'd2:  prev_pgcn[15:8] <= pb_rdata;  // @158
                    13'd3:  prev_pgcn[7:0]  <= pb_rdata;  // @159
                    13'd4:  goup_pgcn[15:8] <= pb_rdata;  // @160
                    13'd5:  goup_pgcn[7:0]  <= pb_rdata;  // @161
                    13'd7:  pgc_still_time <= pb_rdata;   // @163 (mode@162 ignored)
                    13'd73: cmd_tbl_off    <= {wacc[7:0], pb_rdata};   // @228-229
                    13'd75: prog_map_off16 <= {wacc[7:0], pb_rdata};   // @230-231
                    13'd77: cell_pb_off16  <= {wacc[7:0], pb_rdata};   // @232-233
                    default: ;
                    endcase
                    // palette @164..227 = idx 8..71: emit an entry per 4 bytes.
                    // FP PGCs skip the emit (their palette is not a title's).
                    if (walk_idx >= 13'd8 && walk_idx <= 13'd71 &&
                        walk_idx[1:0] == 2'd3 && dom != DOM_FP) begin
                        pal_we    <= 1'b1;
                        pal_waddr <= walk_idx[5:2] - 4'd2;   // (idx-8)/4
                        pal_wdata <= {wacc, pb_rdata};
                    end
                    if (walk_left == 13'd1) begin
                        // header done -> command table (if any) -> program map
                        // (if any) -> cell check. cell_pb_off16 is being written
                        // THIS cycle; later states read the registered value.
                        if (cmd_tbl_off != 16'd0) begin
                            walk_sec  <= pgc_sec + (({6'b0,pgc_off} + {1'b0,cmd_tbl_off}) >> 11);
                            walk_off  <= (({6'b0,pgc_off} + {1'b0,cmd_tbl_off})) & 17'h07FF;
                            walk_left <= 13'd8;        // counts@0-5 + last_byte@6-7
                            walk_idx  <= 13'd0;
                            wphase    <= P_CMDH;
                        end else begin
                            cmd_nr_pre  <= 8'd0;
                            cmd_nr_post <= 8'd0;
                            cmd_nr_cell <= 8'd0;
                            if (prog_map_off16 != 16'd0 && cmd_nr_pgm != 8'd0 &&
                                dom != DOM_FP) begin
                                walk_sec  <= pgc_sec + (({6'b0,pgc_off} + {1'b0,prog_map_off16}) >> 11);
                                walk_off  <= (({6'b0,pgc_off} + {1'b0,prog_map_off16})) & 17'h07FF;
                                walk_left <= {5'd0, cmd_nr_pgm};
                                walk_idx  <= 13'd0;
                                wphase    <= P_PMAP;
                            end else
                                state <= S_PGC_CELLCHK;
                        end
                    end
                end

                // ----- command table header: nr_pre@0, nr_post@2, nr_cell@4 -----
                P_CMDH: begin
                    case (walk_idx)
                    13'd1: nr_pre16   <= {wacc[7:0], pb_rdata};
                    13'd3: nr_post16  <= {wacc[7:0], pb_rdata};
                    13'd5: nr_cellc16 <= {wacc[7:0], pb_rdata};
                    default: ;
                    endcase
                    if (walk_left == 13'd1) begin
                        // export clamped counts; stream total*8 bytes (<= 2040)
                        cmd_nr_pre  <= (nr_pre16   > 16'd255) ? 8'd255 : nr_pre16[7:0];
                        cmd_nr_post <= (nr_post16  > 16'd255) ? 8'd255 : nr_post16[7:0];
                        cmd_nr_cell <= (nr_cellc16 > 16'd255) ? 8'd255 : nr_cellc16[7:0];
                        if (nr_pre16 + nr_post16 + nr_cellc16 == 16'd0 ||
                            nr_pre16 + nr_post16 + nr_cellc16 > 16'd511) begin
                            // empty or absurd -> skip to the program map / cells
                            if (prog_map_off16 != 16'd0 && cmd_nr_pgm != 8'd0 &&
                                dom != DOM_FP) begin
                                walk_sec  <= pgc_sec + (({6'b0,pgc_off} + {1'b0,prog_map_off16}) >> 11);
                                walk_off  <= (({6'b0,pgc_off} + {1'b0,prog_map_off16})) & 17'h07FF;
                                walk_left <= {5'd0, cmd_nr_pgm};
                                walk_idx  <= 13'd0;
                                wphase    <= P_PMAP;
                            end else
                                state <= S_PGC_CELLCHK;
                        end else begin
                            // total <= 511 (guard above); 10-bit sum avoids the
                            // 8-bit wrap when total exceeds 255 (up to 384 spec).
                            walk_left <= {(nr_pre16[9:0] + nr_post16[9:0] + nr_cellc16[9:0]), 3'b000};
                            wphase    <= P_CMD;
                            walk_idx  <= 13'd0;
                        end
                    end
                end

                // ----- command bytes: stream to cmd_we; watch PRE LinkPGCN -----
                P_CMD: begin
                    cmd_we    <= 1'b1;
                    cmd_waddr <= walk_idx[11:0];
                    cmd_wdata <= pb_rdata;
                    if (walk_idx[2:0] == 3'd0) cmd_b0 <= pb_rdata;
                    if (walk_idx[2:0] == 3'd1) cmd_b1 <= pb_rdata;
                    if (walk_idx[2:0] == 3'd6) cmd_b6 <= pb_rdata;
                    // LinkPGCN in a PRE command (type 1 link, op 4): byte0=0x20,
                    // byte1 low nibble=4; unconditional when the compare op
                    // (byte1[6:4]) is 0. DVD-FORK FIX: the target is the 15-BIT
                    // field ins[14:0] = {byte6[6:0], byte7}, not byte7 alone (which
                    // aliased PGCN 1381 -> 101; see docs/disc_sweep.md).
                    // - 0-cell menu entry stubs (MiB root) end in one of these.
                    if (walk_idx[2:0] == 3'd7 &&
                        {6'd0, walk_idx[12:3]} < nr_pre16 &&
                        cmd_b0 == 8'h20 && cmd_b1[3:0] == 4'h4) begin
                        if (cmd_b1[6:4] == 3'd0) link_pgcn_u <= {1'b0, cmd_b6[6:0], pb_rdata};
                        else                     link_pgcn_c <= {1'b0, cmd_b6[6:0], pb_rdata};
                    end
                    if (walk_left == 13'd1) begin
                        if (prog_map_off16 != 16'd0 && cmd_nr_pgm != 8'd0 &&
                            dom != DOM_FP) begin
                            walk_sec  <= pgc_sec + (({6'b0,pgc_off} + {1'b0,prog_map_off16}) >> 11);
                            walk_off  <= (({6'b0,pgc_off} + {1'b0,prog_map_off16})) & 17'h07FF;
                            walk_left <= {5'd0, cmd_nr_pgm};
                            walk_idx  <= 13'd0;
                            wphase    <= P_PMAP;
                        end else
                            state <= S_PGC_CELLCHK;
                    end
                end

                // ----- program map: nr_pgms bytes -> pm_we stream + the
                // jump_pgn start-cell latch (JumpVTS_PTT / LinkPGN's target
                // is known only now, so the start cell is picked up in
                // passing - no extra states) -----
                P_PMAP: begin
                    pm_we    <= 1'b1;
                    pm_waddr <= walk_idx[6:0];
                    pm_wdata <= pb_rdata;
                    if (use_jcell && jpgn_l != 8'd0 &&
                        walk_idx + 13'd1 == {5'd0, jpgn_l} && pb_rdata != 8'd0) begin
                        jcell_l <= pb_rdata - 8'd1;    // program n -> its entry cell
                    end
                    if (walk_left == 13'd1)
                        state <= S_PGC_CELLCHK;
                end

                // ----- cell playback table: 24 B/cell -> cell BRAMs -----
                P_CELL: begin
                    if (cell_bi == 5'd0) cm_cat_c   <= pb_rdata;   // category@0 (Phase 9)
                    if (cell_bi == 5'd2) cm_still_c <= pb_rdata;
                    if (cell_bi == 5'd3) cm_cmd_c   <= pb_rdata;
                    // playback_time @4/5/6 (BCD hour/min/sec) -> seconds (heuristic)
                    if (cell_bi == 5'd4)
                        pbh_c <= {4'd0, pb_rdata[7:4]} * 8'd10 + {4'd0, pb_rdata[3:0]};
                    if (cell_bi == 5'd5)
                        pbm_c <= {4'd0, pb_rdata[7:4]} * 8'd10 + {4'd0, pb_rdata[3:0]};
                    if (cell_bi == 5'd6) begin : pbsum
                        // hh*3600 + mm*60 + ss, full 16-bit (spec-hardening
                        // Phase 6: the old any-hours/255 clamp under-held
                        // still-shaped cells > 4 min 15 s). Clamp only at the
                        // C_PBTM spec max 9:59:59 = 35,999 s - reachable only
                        // by garbage BCD digits (legal max hh = 9).
                        reg [19:0] pbs;
                        pbs = {12'd0, pbh_c} * 20'd3600 +
                              {12'd0, pbm_c} * 20'd60 +
                              {16'd0, pb_rdata[7:4]} * 20'd10 +
                              {16'd0, pb_rdata[3:0]};
                        pb_c <= (pbs > 20'd35999) ? 16'd35999 : pbs[15:0];
                    end
                    if (cell_bi == 5'd11) cf_c <= {wacc, pb_rdata};   // first_sector @8
                    if (cell_bi == 5'd19) lv_c <= {wacc, pb_rdata};   // last_vobu_start @16
                    // (first/last BRAM writes live in the dedicated block above)
                    if (cell_bi == 5'd23) begin
                        cell_bi <= 5'd0;
                        cell_wi <= cell_wi + 8'd1;
                    end else
                        cell_bi <= cell_bi + 5'd1;
                    if (walk_left == 13'd1) begin
                        cell_count <= nr_cells;
                        state      <= S_PGC_DONE;
                    end
                end

                // ----- Phase-6 PTT table: 4 B/entry {pgcn u16, pgn u16} BE ->
                // ptt_mem[{pgcn u16, pgn_lo}]. DVD-FORK FIX: the pgcn HIGH byte is
                // now kept (it was dropped, clamping PGCN to 255 - see the LinkPGCN
                // truncation in docs/disc_sweep.md). pgn keeps its low byte (a
                // program number is <= 99 by spec). -----
                P_PTT: begin
                    if (walk_idx[1:0] == 2'd0) ptt_pgcn_c[15:8] <= pb_rdata; // pgcn hi @+0
                    if (walk_idx[1:0] == 2'd1) ptt_pgcn_c[7:0]  <= pb_rdata; // pgcn lo @+1
                    if (walk_idx[1:0] == 2'd3) begin                   // pgn lo @+3
                        ptt_we    <= 1'b1;
                        ptt_waddr <= walk_idx[11:2];                   // entry index
                        ptt_wdata <= {ptt_pgcn_c, pb_rdata};
                    end
                    if (walk_left == 13'd1) state <= S_PTTLD_DONE;
                end
                endcase
            end

            // Cell-count gate (runs AFTER the header/command walk; palette +
            // commands already captured). Title: 0 or >MAXCELL -> linear
            // whole-VTS fallback. Menu: a 0-cell entry PGC is a command STUB
            // (MiB root) -> follow its last pre-command LinkPGCN (unconditional
            // preferred), depth-limited; FP parses commands only and idles.
            S_PGC_CELLCHK: begin
                if (dom == DOM_FP) begin
                    cell_count <= 8'd0;
                    pgc_loaded <= 1'b1;
                    state      <= S_DONE;              // FP: commands only, no video
                end else if (nr_cells == 8'd0 || nr_cells > MAXCELL ||
                             cell_pb_off16 == 16'd0) begin
                    if (vm_mode && (cmd_nr_pre != 8'd0 || cmd_nr_post != 8'd0)) begin
                        // Phase-4: a 0-cell PGC is a COMMAND STUB - report it
                        // loaded and let the VM execute its pre commands (the
                        // real LinkPGCN / JumpSS trampoline). The heuristic
                        // follow below stays for vm_mode-off. A stub with no
                        // commands falls through to the legacy handling.
                        // DVD-FORK FIX: || cmd_nr_post - a stub may carry its
                        // dispatch ENTIRELY in POST (0 cells, 0 pre), which is
                        // how menu discs route buttons that all share one
                        // LinkPGCN target whose POST reads HL_BTNN. The old
                        // pre-only gate dropped those to the pgc_error path
                        // below = LINK FAIL (Residents VTSM1 PGCN 81, Dinosaur
                        // x26, 15/122 library discs). dvd_vm.sv runs the POST.
                        cell_count <= 8'd0;
                        cell_mode  <= 1'b0;
                        pgc_loaded <= 1'b1;
                        state      <= S_DONE;
                    end else if (menu_dom) begin
                        if ((link_pgcn_u != 16'd0 || link_pgcn_c != 16'd0) &&
                            follow_cnt < 2'd2) begin
                            want_pgcn  <= (link_pgcn_u != 16'd0) ? link_pgcn_u : link_pgcn_c;
                            srp_i      <= ((link_pgcn_u != 16'd0) ? link_pgcn_u : link_pgcn_c) - 16'd1;
                            follow_cnt <= follow_cnt + 2'd1;
                            scan_mode  <= 1'b0;
                            state      <= (((link_pgcn_u != 16'd0) ? link_pgcn_u : link_pgcn_c)
                                           <= nr_srp_l) ? S_SRP_FETCH : S_DONE;
                            if (((link_pgcn_u != 16'd0) ? link_pgcn_u : link_pgcn_c) > nr_srp_l) begin
                                pgc_error <= 1'b1;
                                dbg_pgcerr <= {3'd2, ((nr_srp_l > 16'd31) ? 5'd31 : nr_srp_l[4:0]),
                                               ((link_pgcn_u != 16'd0) ? link_pgcn_u[7:0] : link_pgcn_c[7:0])};
                            end
                        end else begin
                            pgc_error <= 1'b1;
                            state     <= S_DONE;
                        end
                    end else
                        state <= S_FINAL2;             // title linear fallback (palette kept)
                end else begin
                    // start the P_CELL walk at pgc + cell_playback_offset
                    walk_sec  <= pgc_sec + (({6'b0,pgc_off} + {1'b0,cell_pb_off16}) >> 11);
                    walk_off  <= (({6'b0,pgc_off} + {1'b0,cell_pb_off16})) & 17'h07FF;
                    walk_left <= {nr_cells, 5'd0} - {2'd0, nr_cells, 3'd0};  // nr_cells*24
                    walk_idx  <= 13'd0;
                    wphase    <= P_CELL;
                    cell_bi   <= 5'd0;
                    cell_wi   <= 8'd0;
                    state     <= S_WALK_RD;
                end
            end

            // Cell list parsed -> set up cell-mode streaming. A TT jump starts
            // at the requested resume cell; everything else at cell 0.
            S_PGC_DONE: begin
                cell_mode  <= 1'b1;
                cell_i     <= (use_jcell && jcell_l < cell_count) ? jcell_l : 8'd0;
                cell_raddr <= (use_jcell && jcell_l < cell_count) ? jcell_l : 8'd0;
                use_jcell  <= 1'b0;
                still_flushed <= 1'b0;  // fresh PGC = new menu: re-arm the still-cell cold re-decode
                jpgn_l     <= 8'd0;    // program-start latch consumed
                strm_done  <= 1'b0;
                wr_ptr     <= 0;
                pgc_loaded <= 1'b1;
                // fresh PGC: re-scan any angle block from scratch, and reset the
                // selected angle to 1 (Phase 9). Angle is a per-title context -
                // like a set-top box, each new feature/title starts at angle 1;
                // a switch only persists WITHIN the feature being watched (seeks
                // and chapter skips don't re-enter S_PGC_DONE).
                angle_resolved <= 1'b0;
                angle_active   <= 1'b0;
                angle_count    <= 4'd0;
                seamless_active <= 1'b0;
                ilvu_armed     <= 1'b0;
                cur_angle      <= 4'd1;
                state      <= S_CELL_LOAD;
            end

            // BRAM read latency for cf_rd/cl_rd/cm_rd (cell_raddr set the prior cycle).
            S_CELL_LOAD:  state <= S_CELL_LOAD2;
            S_CELL_LOAD2: begin
                if (menu_dom) begin
                    // Menu VOB = ONE extent: cell RBNs map directly to
                    // menu_base_blk + RBN, bounded by the VOB length.
                    if (cf_rd > cl_rd || cf_rd >= menu_blocks) begin
                        // malformed cell -> skip to the next / finish on a still
                        if (cell_i + 8'd1 >= cell_count) begin
                            strm_done  <= 1'b1;
                            still_pend <= 1'b1;        // menu end: hold, don't black out
                            state      <= S_STREAM;
                        end else begin
                            cell_i     <= cell_i + 8'd1;
                            cell_raddr <= cell_i + 8'd1;
                            state      <= S_CELL_LOAD;
                        end
                    end else begin
                        play_blk <= cf_rd;
                        play_end <= (cl_rd + 32'd1 > menu_blocks)
                                    ? menu_blocks
                                    : (cl_rd + 32'd1);
                        state    <= S_STREAM;
                    end
                end else if (cc_blk_first && !angle_resolved && !rbn_override) begin
                    // MULTI-ANGLE (Phase 9): the first cell of an angle block.
                    // Count the block's angle cells (block_type==1 run), then load
                    // the cur_angle cell instead of this one. block_first = this
                    // cell; the scan cursor prefetches the next cell's category.
                    block_first <= cell_i;
                    angle_count <= 4'd1;                 // this cell is angle 1
                    ang_scan_i  <= cell_i + 8'd1;
                    cell_raddr  <= cell_i + 8'd1;        // prefetch cat[cell_i+1]
                    state       <= S_ANGLE_SCAN2;
                end else begin
                    // Title: map through the extent table. Start the seek scan
                    // from the group base, reusing strm_idx as the cursor.
                    // Sub-cell scrub (rbn_override): stream from the raw target RBN
                    // (already validated within [cf,cl] by S_RBN_SCAN) instead of
                    // the cell's first_sector; play_end still bounds at the cell end.
                    // angle_active / seamless_active gate the NV_PCK snoop / ILVU
                    // jump. angle = a chosen angle-block cell; seamless = an
                    // interleaved (non-angle) cell (Matrix white-rabbit / T2). The
                    // two are mutually exclusive (cc_is_angle vs !cc_is_angle).
                    angle_active    <= cc_is_angle && angle_resolved;
                    seamless_active <= cc_interleaved && !cc_is_angle;
                    ilvu_armed  <= 1'b0;
                    strm_idx    <= eff_base;
                    seek_cum    <= 32'd0;
                    seek_target <= rbn_override ? seek_rbn_l
                                                : cf_rd;         // RBN = sector unit
                    play_end    <= cl_rd + 32'd1;                // last+1 (exclusive)
                    rbn_override <= 1'b0;
                    state       <= S_CELL_SEEK2;   // wait for ext_blocks_q at eff_base
                end
            end

            // MULTI-ANGLE angle-count scan (Phase 9): walk cell_cat_mem forward
            // from block_first counting consecutive block_type==1 cells, then
            // load the cur_angle cell. Reuses cc_rd (cell_raddr) with a 1-cycle
            // BRAM-latency wait state, mirroring S_RBN_SCAN.
            S_ANGLE_SCAN2: state <= S_ANGLE_SCAN;
            S_ANGLE_SCAN: begin
                if (cc_is_angle && ({8'd0, ang_scan_i} < {8'd0, cell_count})
                        && angle_count < 4'd9) begin
                    angle_count <= angle_count + 4'd1;
                    ang_scan_i  <= ang_scan_i + 8'd1;
                    cell_raddr  <= ang_scan_i + 8'd1;
                    state       <= S_ANGLE_SCAN2;
                end else begin
                    // angle_count known. block_last = block_first + count - 1.
                    // Pick the cur_angle cell (clamped to the block size).
                    block_last     <= block_first + {4'd0, angle_count} - 8'd1;
                    angle_resolved <= 1'b1;
                    if (cur_angle == 4'd0 || cur_angle > angle_count) cur_angle <= 4'd1;
                    cell_i     <= block_first + {4'd0, ((cur_angle == 4'd0 ||
                                  cur_angle > angle_count) ? 4'd1 : cur_angle)} - 8'd1;
                    cell_raddr <= block_first + {4'd0, ((cur_angle == 4'd0 ||
                                  cur_angle > angle_count) ? 4'd1 : cur_angle)} - 8'd1;
                    state      <= S_CELL_LOAD;         // load the chosen angle cell
                end
            end

            // Sub-cell scrub: scan the cell table for the cell whose RBN range
            // [cf_rd, cl_rd] contains seek_rbn_l. cell_raddr walks 0..cell_count-1
            // (S_RBN_SCAN2 covers the 1-cycle BRAM latency). On a hit, land on that
            // cell and fall into the normal cell-load path with rbn_override set.
            // If the scan exhausts (target past the last cell / gap), clamp to the
            // last cell's start (rbn_override cleared) so playback still resumes.
            S_RBN_SCAN2: state <= S_RBN_SCAN;
            S_RBN_SCAN: begin
                if (cf_rd <= seek_rbn_l && seek_rbn_l <= cl_rd) begin
                    cell_i     <= rbn_scan_i;
                    cell_raddr <= rbn_scan_i;      // reload cf_rd/cl_rd for this cell
                    state      <= S_CELL_LOAD;     // rbn_override stays set
                end else if (rbn_scan_i + 8'd1 >= cell_count) begin
                    // not found -> clamp to the last cell, play from its start
                    cell_i       <= cell_count - 8'd1;
                    cell_raddr   <= cell_count - 8'd1;
                    rbn_override <= 1'b0;
                    state        <= S_CELL_LOAD;
                end else begin
                    rbn_scan_i <= rbn_scan_i + 8'd1;
                    cell_raddr <= rbn_scan_i + 8'd1;
                    state      <= S_RBN_SCAN2;
                end
            end

            // Scrub NAV-align: walk the extent table (mirroring S_CELL_SEEK) to
            // map the candidate RBN to an absolute 2048-sector, read it, and
            // test the NAV signature. On a hit, SNAP seek_rbn_l to
            // that RBN and enter the normal containing-cell scan; on a miss, step
            // one sector forward (bounded by nav_left) until a NAV pack is found,
            // the title extents/end are exceeded, or the budget runs out -> fall
            // back to the raw target (pre-fix behaviour).
            S_NAV_SEEK2: state <= S_NAV_SEEK;   // ext_*_q refresh for strm_idx
            S_NAV_SEEK: begin
                if (strm_idx >= eff_base + eff_cnt ||
                    nav_cand > title_last_rbn   ||
                    nav_left == 11'd0) begin
                    state <= S_RBN_SCAN2;                 // fallback: raw seek_rbn_l
                end else if (seek_cum + ext_blocks_q > nav_cand) begin
                    // candidate lies in extent strm_idx -> probe its sector
                    sec_lba    <= ext_start_q + nav_cand - seek_cum;
                    fetch_base <= 11'd0;
                    fetch_ret  <= S_NAV_CHK;
                    state      <= S_SECREAD;
                end else begin
                    seek_cum <= seek_cum + ext_blocks_q;  // advance to the next extent
                    strm_idx <= strm_idx + 7'd1;
                    state    <= S_NAV_SEEK2;
                end
            end
            S_NAV_CHK: begin
                if (nav_sig_hit) begin
                    seek_rbn_l <= nav_cand;               // SNAP to the aligned VOBU RBN
                    state      <= S_RBN_SCAN2;            // -> containing-cell scan
                end else begin
                    nav_cand <= nav_cand + 32'd1;
                    nav_left <= nav_left - 11'd1;
                    state    <= S_NAV_SEEK;               // same extent: ext_*_q still valid
                end
            end

            // Map the current cell's first_sector (concatenated 2048-sector target)
            // to an extent index + offset within the selected group. cf_rd/cl_rd
            // track cell_raddr (the current cell) throughout; strm_idx scans then
            // stays put as the streaming extent pointer. ext_blocks_q is the
            // sync-read of ext_mem[strm_idx]; S_CELL_SEEK2 covers its 1-cycle
            // latency after each strm_idx step.
            S_CELL_SEEK2: state <= S_CELL_SEEK;
            S_CELL_SEEK: begin
                if (cf_rd > cl_rd || strm_idx >= eff_base + eff_cnt) begin
                    // malformed / out-of-range cell -> skip to the next cell
                    if (cell_i + 8'd1 >= cell_count) begin
                        strm_done <= 1'b1;
                        state     <= S_STREAM;
                    end else begin
                        cell_i     <= cell_i + 8'd1;
                        cell_raddr <= cell_i + 8'd1;
                        state      <= S_CELL_LOAD;
                    end
                end else if (seek_cum + ext_blocks_q > seek_target) begin
                    ext_cum  <= seek_cum;
                    play_blk <= seek_target;
                    state    <= S_STREAM;       // strm_idx settled -> ext_*_q valid
                end else begin
                    seek_cum <= seek_cum + ext_blocks_q;
                    strm_idx <= strm_idx + 7'd1;
                    state    <= S_CELL_SEEK2;   // reload ext_blocks_q for the next index
                end
            end

            // ------------------------------------------------------------
            // Stream into the cache. cell_mode=0: the winning extent ranges
            // back to back (flat-file + linear fallback, unchanged). cell_mode=1:
            // the PGC cell list in program order, mapping each cell's
            // concatenated 2048-sector position through the extent table.
            S_STREAM: begin
                if (!blk_inflight && !strm_done && cache_has_room) begin
                    // ext_start_q = ext_mem[strm_idx][start]; valid because every
                    // strm_idx change detours through S_EXT_LOAD before returning
                    // here. Menu domain bypasses the extent table (single VOB).
                    sd_lba       <= cell_mode ? (menu_dom ? (menu_base_blk + play_blk)
                                                          : (ext_start_q + (play_blk - ext_cum)))
                                              : (ext_start_q + strm_blk);
                    sd_rd        <= 1'b1;
                    blk_inflight <= 1'b1;
                end else if (blk_inflight) begin
                    if (sd_ack) sd_rd <= 1'b0;
                    if (sd_ack_d && !sd_ack) begin
                        blk_inflight <= 1'b0;
                        // Raw mode: counted advance (only the deblocked payload
                        // bytes landed in the cache); else the fixed block size
                        // (14'd2048 = BLK; plain literal, no size cast — the
                        // Quartus-17 N'() netlist lesson).
                        wr_ptr       <= wr_ptr + (raw_mode ? {2'b00, raw_wcnt}
                                                           : 14'd2048);
                        raw_wcnt     <= 12'd0;
                        if (cell_mode) begin
                            if (ilvu_armed &&
                                play_blk == ilvu_end_rbn) begin
                                // ILVU JUMP: reached the last sector of the
                                // ILVU_LAST VOBU -> jump to this branch's next ILVU.
                                // TIME-CONTINUOUS: route through the rbn_override
                                // cell-load (streams from the raw target RBN),
                                // NOT resetting wr_ptr and NOT pulsing seek_ack, so
                                // the cache byte stream stays a single seamless PS
                                // (no VBUF flush, no A/V re-anchor).
                                //  - ANGLE (Phase 9): re-point cell_i at the current
                                //    angle's cell (block_first+cur_angle-1) so
                                //    play_end tracks a mid-block angle switch.
                                //  - SEAMLESS-BRANCH: STAY on the same cell (the
                                //    interleaved cell owns the whole [first..last]
                                //    range); just reload it via rbn_override.
                                ilvu_armed   <= 1'b0;
                                seek_rbn_l   <= ilvu_target;
                                rbn_override <= 1'b1;
                                if (angle_active) begin
                                    cell_i     <= block_first + {4'd0, cur_angle} - 8'd1;
                                    cell_raddr <= block_first + {4'd0, cur_angle} - 8'd1;
                                end else begin
                                    cell_raddr <= cell_i;   // seamless: same cell
                                end
                                state        <= S_CELL_LOAD;
                            end else if (play_blk + 32'd1 == play_end) begin
                                // CELL FINISHED. First check the cell's own
                                // still_time (cm_rd tracks cell_raddr = this cell):
                                // authored menus park on a still cell (MiB/Matrix/T2
                                // all use cell still=0xFF), and — with Disc Menus on
                                // (vm_mode) — title cells honour a finite still too
                                // (FMV-game timed choices). v1 holds ANY nonzero
                                // still until a jump/timeout (timed stills = Phase 5).
                                cell_end_pulse <= 1'b1;
                                if ((menu_dom || vm_mode) && cm_rd[15:8] != 8'd0 &&
                                    cm_rd[15:8] != 8'd255) begin
                                    // TIMED STILL (Phase 5): an authored ad /
                                    // copyright / menu-intro hold (explicit
                                    // still_time OR the libdvdnav playback-time
                                    // heuristic - see the cell-meta write). Drain
                                    // and park; hold for still_secs, THEN run the
                                    // action this cell-end WOULD have taken. A
                                    // menu button that fires a VM jump exits early
                                    // via jump_go. Indefinite (0xFF) stills fall
                                    // through to the existing branches so
                                    // MiB/Matrix loop-holds are untouched.
                                    //
                                    // TITLE-DOMAIN finite stills (vm_mode): this is
                                    // how FMV-game discs (Thayer's Quest) author a
                                    // TIMED CHOICE — a title cell carries an explicit
                                    // still_time (4/5/10 s) AND a cell_cmd_nr. The cell
                                    // plays the "approach" video, FREEZES the last frame
                                    // for still_time while the forever-HLI buttons stay
                                    // armed (nav_pci), and on TIMEOUT runs the cell
                                    // command (STILL_CMD -> the "too slow / lose a life"
                                    // branch). A left/right press during the hold fires
                                    // its LinkTailPGC and exits early via jump_go. Before
                                    // this was menu_dom-only, so a title choice cell fell
                                    // through to the `vm_mode && cell_cmd_nr` branch below
                                    // and ran the timeout command INSTANTLY (no window +
                                    // the door subpicture was overwritten = 1-frame flash).
                                    // Gated on vm_mode (Disc Menus): menus-off title
                                    // playback advances as before. libdvdnav honours the
                                    // same finite title stills.
                                    // heuristic stills (cm_rd[32]) hold the FULL
                                    // 16-bit duration; the byte clamps at 254
                                    still_secs  <= cm_rd[32] ? cell_dur_w
                                                             : {8'd0, cm_rd[15:8]};
                                    still_timed <= 1'b1;
                                    still_last  <= (cell_i + 8'd1 >= cell_count);
                                    still_next  <=
                                        (vm_mode && cm_rd[7:0] != 8'd0) ? STILL_CMD :
                                        (cell_i + 8'd1 >= cell_count)    ? STILL_PGEND :
                                                                           STILL_NEXT;
                                    strm_done  <= 1'b1;
                                    still_pend <= 1'b1;   // drain, then S_STILL
                                end else if (vm_mode && cm_rd[7:0] != 8'd0) begin
                                    if (dur_hold_w) begin
                                        // AUTHORED CELL DURATION: the cell's
                                        // sectors are delivered but its C_PBTM
                                        // has not elapsed on the display (the
                                        // Weakest Link answer window: ONE
                                        // I-frame authored to hold 17 s,
                                        // still_time = 0 - the hold is the
                                        // cell's DURATION). Serve the unspent
                                        // seconds as a timed still, THEN run
                                        // the cell command - so it evaluates
                                        // SPRM8 etc. at the cell's authored
                                        // end, like a real player. Buttons
                                        // stay armed through S_STILL; a user
                                        // activation jumps out early via
                                        // jump_go (unchanged).
                                        still_secs  <= dur_resid_w;
                                        still_timed <= 1'b1;
                                        still_last  <= (cell_i + 8'd1 >= cell_count);
                                        still_next  <= STILL_CMD;
                                        strm_done   <= 1'b1;
                                        still_pend  <= 1'b1;   // drain, then S_STILL
                                    end else begin
                                    // Phase-4: the cell has a CELL COMMAND -
                                    // hand it to the VM and wait for the
                                    // verdict (adv / replay / seek / jump).
                                    // Ordering matches the HW-proven Phase-3
                                    // heuristic: the command outranks the
                                    // cell still (MiB/Matrix interactive
                                    // cells carry both).
                                    vm_cell_cmd <= 1'b1;
                                    vmw_pgc     <= 1'b0;
                                    vmw_last    <= (cell_i + 8'd1 >= cell_count);
                                    vmw_tmr     <= 24'd0;
                                    state       <= S_VM_WAIT;
                                    end
                                end else if (!vm_mode && menu_dom &&
                                             menu_btns_armed && cm_rd[7:0] != 8'd0) begin
                                    // CELL LOOP (Phase 3): replay this
                                    // interactive cell (cell_raddr = cell_i
                                    // already; no flush - clean GOP start,
                                    // av_sync re-anchors on the PTS jump)
                                    state <= S_CELL_LOAD;
                                end else if ((menu_dom || vm_mode) &&
                                             cm_rd[15:8] == 8'd255) begin
                                    // Indefinite (0xFF) still: hold until a
                                    // jump/button. Menu-domain menus park here
                                    // (MiB/Matrix/T2). An IN-TITLE 0xFF still with
                                    // disc menus on (vm_mode) is Scene It's how-to-
                                    // play / segment-select PARK screen (VTS7 PGCN5
                                    // cell0): its buttons arm during the hold so the
                                    // user can pick a segment up front, instead of
                                    // the video playing through and looping. Movies
                                    // never author an in-title 0xFF still, so this is
                                    // safe. Buttons (nav_pci) arm during S_STILL.
                                    still_timed <= 1'b0;
                                    strm_done  <= 1'b1;
                                    still_pend <= 1'b1;   // drain, then S_STILL
                                end else if (angle_active) begin
                                    // MULTI-ANGLE (Phase 9): the selected angle's
                                    // cell finished -> SKIP the sibling angle cells
                                    // and advance to the cell after the block (the
                                    // common continuation). Clears the angle state.
                                    angle_active   <= 1'b0;
                                    angle_resolved <= 1'b0;
                                    angle_count    <= 4'd0;
                                    ilvu_armed     <= 1'b0;
                                    if (block_last + 8'd1 >= cell_count) begin
                                        pgc_end_pulse <= 1'b1;
                                        strm_done     <= 1'b1;
                                        if (vm_mode) vmw_pgc_pend <= 1'b1;
                                    end else begin
                                        cell_i     <= block_last + 8'd1;
                                        cell_raddr <= block_last + 8'd1;
                                        state      <= S_CELL_LOAD;
                                    end
                                end else if (cell_i + 8'd1 >= cell_count) begin
                                    // PGC FINISHED.
                                    pgc_end_pulse <= 1'b1;
                                    strm_done     <= 1'b1;
                                    if (vm_mode && dur_hold_w) begin
                                        // AUTHORED CELL DURATION at PGC end:
                                        // the last cell's C_PBTM has unspent
                                        // display time - hold it as a timed
                                        // still, then funnel through
                                        // STILL_PGEND (which inherits the
                                        // Phase-B tail-drain before POST).
                                        still_secs  <= dur_resid_w;
                                        still_timed <= 1'b1;
                                        still_last  <= 1'b1;
                                        still_next  <= STILL_PGEND;
                                        still_pend  <= 1'b1;   // drain, then S_STILL
                                    end else if (vm_mode) begin
                                        // Phase-4: drain the cache first, then
                                        // pulse vm_pgc_end and wait - the POST
                                        // commands run against the played-out
                                        // picture (the menu-still lesson).
                                        vmw_pgc_pend <= 1'b1;
                                    end else if (menu_dom) begin
                                        // Without the VM the menu end policy
                                        // is: PGC still -> hold; authored
                                        // next_pgcn -> follow it (DRAIN the
                                        // cache first - flushing here would
                                        // truncate the tail of this cell - then
                                        // flush like a seek); otherwise hold
                                        // the last frame (never black-screen).
                                        if (pgc_still_time == 8'd0 &&
                                            next_pgcn != 16'd0 &&
                                            next_pgcn <= nr_srp_l)
                                            adv_pend   <= 1'b1;
                                        else
                                            still_pend <= 1'b1;
                                    end
                                end else begin
                                    cell_i     <= cell_i + 8'd1;
                                    cell_raddr <= cell_i + 8'd1;   // load next cell from BRAM
                                    state      <= S_CELL_LOAD;
                                end
                            end else begin
                                play_blk <= play_blk + 32'd1;
                                // cross an extent boundary within the group
                                // (title only - the menu VOB is one extent)
                                if (!menu_dom &&
                                    play_blk + 32'd1 == ext_cum + ext_blocks_q) begin
                                    ext_cum  <= ext_cum + ext_blocks_q;
                                    strm_idx <= strm_idx + 7'd1;
                                    state    <= S_EXT_LOAD;   // refresh ext_*_q for new extent
                                end
                            end
                        end else begin
                            if (strm_blk + 32'd1 == ext_blocks_q) begin
                                strm_blk <= 32'd0;
                                if (strm_left == 7'd1) strm_done <= 1'b1;
                                else begin
                                    strm_idx  <= strm_idx + 7'd1;
                                    strm_left <= strm_left - 7'd1;
                                    state     <= S_EXT_LOAD;  // refresh ext_*_q for new extent
                                end
                            end else
                                strm_blk <= strm_blk + 32'd1;
                        end
                    end
                end

                // Stream exhausted AND the output cache drained: settle. An
                // authored next_pgcn advance re-enters the PGCIT (flushing the
                // downstream pipe like a seek - nothing left to truncate now);
                // a menu still parks in S_STILL (still_active holds the
                // display; any jump/seek exits); a finished title parks in
                // S_DONE as before. A title-domain PGC end additionally waits
                // for the decoder VBUF to drain (tail_wait) so the POST's
                // jump can't flush away the clip's buffered tail — the
                // natural-transition tail drain (see the drain_tmr block).
                if (strm_done && !blk_inflight && !cache_has_data && !tail_wait) begin
                    if (vmw_pgc_pend) begin
                        // Phase-4: PGC done + drained -> POST commands' turn.
                        vmw_pgc_pend <= 1'b0;
                        vm_pgc_end   <= 1'b1;
                        vmw_pgc      <= 1'b1;
                        vmw_tmr      <= 24'd0;
                        state        <= S_VM_WAIT;
                    end else if (adv_pend) begin
                        adv_pend   <= 1'b0;
                        still_flushed <= 1'b0;    // next_pgcn = new menu: re-arm cold re-decode
                        seek_ack   <= 1'b1;   // emu: load_flush (+vbuf if not menu)
                        keep_vbuf  <= menu_dom;   // menu next_pgcn advance: hold VBUF
                        wr_ptr     <= 0;
                        strm_done  <= 1'b0;
                        want_pgcn  <= next_pgcn;
                        srp_i      <= next_pgcn - 8'd1;
                        scan_mode  <= 1'b0;
                        follow_cnt <= 2'd0;
                        cell_mode  <= 1'b0;
                        state      <= S_SRP_FETCH;
                    end else
                        state <= still_pend ? S_STILL : S_DONE;
                end
            end

            // 1-cycle wait so ext_start_q/ext_blocks_q reflect the (just-changed)
            // strm_idx before S_STREAM issues the next sd read from a new extent.
            S_EXT_LOAD: state <= S_STREAM;

            // ------------------------------------------------------------
            // MENU STILL: the stream is exhausted and the cache has drained;
            // still_active (= this state) tells emu to suppress the decoder
            // watchdog so the last decoded frame - the authored menu still -
            // stays on screen indefinitely. Exits via jump_go / seek_jump.
            //
            // The still's FINAL frame (T2 numbered scene-range cubes, mission-profile
            // slides, ad/copyright/menu-end frames) was decoded MID-STREAM (entered via a
            // keep_vbuf transition, so with stale references) and would show PIXELATED if
            // merely flushed to the display. So COLD RE-DECODE it: re-stream JUST this still
            // cell (from its own sequence header) as a clean decode - the I-frame
            // reconstructs correctly and the frame displays sharp. Trigger:
            //   - menu_snap (P1O[18] Snappy): fire IMMEDIATELY - the emu deep-flush already
            //     emptied the buffer, so the re-decode is fast (a buffered transition is cut,
            //     which Snappy accepts).
            //   - else vbuf_empty (Smooth): wait until the authored transition has fully
            //     played out (buffer drained), THEN re-decode - transition NOT cut.
            // Once per entry (still_flushed); menu stills only; a real jump/seek exits first.
            S_STILL: begin
                if (menu_dom && !still_flushed && (menu_snap || vbuf_empty)) begin
                    still_flushed <= 1'b1;
                    cell_raddr    <= cell_i;   // re-load THIS still cell (cell_i unchanged)
                    strm_done     <= 1'b0;
                    still_pend    <= 1'b0;
                    wr_ptr        <= 0;
                    seek_ack      <= 1'b1;     // emu: load_flush + (keep_vbuf=0) vbuf_flush
                    keep_vbuf     <= 1'b0;     // FORCE the clean cold decode of the still cell
                    state         <= S_CELL_LOAD;
                end else if (still_timed && sec_tick) begin
                    // TIMED hold: count down at 1 Hz, then run the deferred action
                    // (a menu button that fires a VM jump exits earlier via jump_go).
                    if (still_secs <= 16'd1) begin
                        still_timed <= 1'b0;
                        still_pend  <= 1'b0;
                        case (still_next)
                        STILL_CMD: begin
                            vm_cell_cmd <= 1'b1;
                            vmw_pgc     <= 1'b0;
                            vmw_last    <= still_last;
                            vmw_tmr     <= 24'd0;
                            state       <= S_VM_WAIT;
                        end
                        STILL_PGEND: begin
                            // Funnel through the S_STREAM PGC-end gate (the
                            // vmw_last precedent) so a TITLE-domain timed
                            // still inherits the tail-drain wait before POST
                            // runs. Cache is already drained, so for menus
                            // this is the same dispatch one state hop later;
                            // for a title the gate adds the vbuf_empty wait.
                            if (vm_mode) begin
                                vmw_pgc_pend <= 1'b1;
                                strm_done    <= 1'b1;
                                state        <= S_STREAM;
                            end else
                                state <= S_DONE;
                        end
                        default: begin   // STILL_NEXT
                            cell_i     <= cell_i + 8'd1;
                            cell_raddr <= cell_i + 8'd1;
                            strm_done  <= 1'b0;
                            state      <= S_CELL_LOAD;
                        end
                        endcase
                    end else
                        still_secs <= still_secs - 16'd1;
                end
            end

            // ------------------------------------------------------------
            // Phase-4: waiting for the VM's verdict on a cell command
            // (vmw_pgc=0) or the POST block (vmw_pgc=1). A jump/seek exits
            // via jump_go/seek_jump; vm_replay restarts the current cell
            // gapless (the menu loop); vm_adv continues the authored flow.
            // The ~0.62 s watchdog turns a missing verdict into vm_adv so a
            // disabled/wedged VM can never park playback.
            S_VM_WAIT: begin
                // Phase B: the VM's verdict HAS arrived but is a natural
                // jump/seek gated on vbuf_empty - freeze the verdict watchdog
                // for the (up to DRAIN_WD) gate window, or its ~0.62 s
                // fallthrough would fire a spurious vm_adv-equivalent advance
                // underneath the pending jump.
                if (!(nat_jump_wait || nat_seek_wait))
                    vmw_tmr <= vmw_tmr + 24'd1;
                if (vm_replay) begin
                    strm_done <= 1'b0;
                    state     <= S_CELL_LOAD;   // cell_raddr = cell_i already
                end else if (vm_adv || !vm_mode || vmw_tmr == 24'hFFFFFF) begin
                    if (vmw_pgc) begin
                        // POST fell through -> the authored Phase-2/3 policy
                        // (already drained: advance directly / hold).
                        if (pgc_still_time == 8'd0 && next_pgcn != 8'd0 &&
                            {8'd0, next_pgcn} <= nr_srp_l) begin
                            seek_ack   <= 1'b1;   // emu: load_flush (+vbuf if not menu)
                            keep_vbuf  <= menu_dom;   // menu POST->next_pgcn: hold VBUF
                            wr_ptr     <= 0;
                            strm_done  <= 1'b0;
                            want_pgcn  <= next_pgcn;
                            srp_i      <= next_pgcn - 8'd1;
                            scan_mode  <= 1'b0;
                            scan_title <= 1'b0;
                            follow_cnt <= 2'd0;
                            cell_mode  <= 1'b0;
                            state      <= S_SRP_FETCH;
                        end else
                            state <= menu_dom ? S_STILL : S_DONE;
                    end else if (vmw_last) begin
                        // the waited cell was the last: now it's a PGC end
                        pgc_end_pulse <= 1'b1;
                        strm_done     <= 1'b1;
                        vmw_pgc_pend  <= 1'b1;
                        state         <= S_STREAM;   // drain, then vm_pgc_end
                    end else begin
                        cell_i     <= cell_i + 8'd1;
                        cell_raddr <= cell_i + 8'd1;
                        strm_done  <= 1'b0;
                        state      <= S_CELL_LOAD;
                    end
                end
            end

            // ------------------------------------------------------------
            // Phase-4 JumpTT resolve: the VMGI@196 shadow holds the TT_SRPT
            // sector ptr; read the requested TT_SRP entry (12 B each from
            // @8; entries for <= 99 titles sit inside one sector) and take
            // {title_set_nr@+6, vts_ttn@+7} into the normal TT group scan.
            S_TT_RES: begin
                if (tt_srpt_ptr == 32'd0 || tt_srpt_ptr > 32'd65535 ||
                    jttn_l == 7'd0) begin
                    pgc_error <= 1'b1;
                    dbg_pgcerr <= {3'd4, 5'd0, 1'b0, jttn_l};
                    state     <= S_DONE;
                end else begin
                    sec_lba    <= vmgi_lba + tt_srpt_ptr;
                    // entry offset = 8 + 12*(ttn-1) = 12*ttn - 4 = 4t + 8t - 4
                    fetch_base <= {2'd0, jttn_l, 2'b00} + {1'd0, jttn_l, 3'b000}
                                  - 11'd4;
                    fetch_ret  <= S_TT_RES2;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            S_TT_RES2: begin
                // rbuf@0 = TT_SRP[ttn-1]: title_set_nr @+6, vts_ttn @+7
                if (rbuf[6] == 8'd0 || rbuf[6] > 8'd99 || rbuf[7] == 8'd0) begin
                    pgc_error <= 1'b1;
                    dbg_pgcerr <= {3'd4, 5'd1, 1'b0, jttn_l};
                    state     <= S_DONE;
                end else begin
                    want_ttn    <= rbuf[7][6:0];
                    target_vtsn <= rbuf[6];
                    play_vtsn   <= rbuf[6];
                    want_pgcn   <= 16'd0;      // title-entry scan
                    sel_i       <= 7'd0;
                    sel_ret     <= 1'b0;
                    state       <= S_SELECT2;
                end
            end

            // ------------------------------------------------------------
            // VM-jump IFO hops (Phase 2). S_JMP_VMGI parses the VMGI field the
            // jump fetched: FP -> @132 = First Play PGC BYTE offset; VMGM ->
            // @200 = VMGM_PGCI_UT sector ptr. S_JMP_VTSM parses VTSI@208
            // (VTSM_PGCI_UT sector ptr). S_UT_HDR reads the PGCI_UT header +
            // LU[0] and positions the menu PGCIT.
            S_JMP_VMGI: begin
                if (vts_pgcit_ptr == 32'd0 || vts_pgcit_ptr > 32'd1048575) begin
                    pgc_error <= 1'b1;
                    dbg_pgcerr <= {3'd5, 5'd0, want_pgcn[7:0]};
                    state     <= S_DONE;
                end else if (dom == DOM_FP) begin
                    // FP PGC: byte offset rel. to the VMGI start
                    cur_pgcn   <= 8'd0;
                    link_pgcn_u <= 16'd0;
                    link_pgcn_c <= 16'd0;
                    pgc_sec    <= vmgi_lba + (vts_pgcit_ptr[20:0] >> 11);
                    pgc_off    <= vts_pgcit_ptr[10:0];
                    sec_lba    <= vmgi_lba + (vts_pgcit_ptr[20:0] >> 11);
                    fetch_base <= vts_pgcit_ptr[10:0];
                    fetch_ret  <= S_PGC_HDR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end else begin
                    // VMGM menu: latch the UT target, then capture VMGM_V_ATR
                    // @0x100 from the resident VMGI_MAT sector (S_MENU_VATR).
                    jmp_ut_lba <= vmgi_lba + vts_pgcit_ptr;
                    fetch_base <= 11'd256;             // VMGM_V_ATR @0x100 (high byte)
                    fetch_ret  <= S_MENU_VATR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_FETCH;             // parse_buf still holds VMGI_MAT
                end
            end

            S_JMP_VTSM: begin
                if (vts_pgcit_ptr == 32'd0 || vts_pgcit_ptr > 32'd1048575) begin
                    pgc_error <= 1'b1;     // no VTSM menu -> emu falls back to VMGM
                    dbg_pgcerr <= {3'd5, 5'd1, want_pgcn[7:0]};
                    state     <= S_DONE;
                end else begin
                    // Latch the UT target (uses the current @208 rbuf), then grab
                    // the VTSM aspect from @0x100 of the still-resident VTSI_MAT
                    // sector (S_MENU_VATR issues the deferred UT read).
                    jmp_ut_lba <= jmp_ifo_lba + vts_pgcit_ptr;
                    fetch_base <= 11'd256;             // VTSM_V_ATR @0x100 (high byte)
                    fetch_ret  <= S_MENU_VATR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_FETCH;             // parse_buf still holds VTSI_MAT
                end
            end

            // Menu aspect capture: rbuf[0] = V_ATR@0x100 high byte. The display
            // aspect ratio is bits 11:10 of the BE u16 (both set = 3 = 16:9),
            // i.e. 0x0C in the high byte. Then issue the (deferred) PGCI_UT read.
            S_MENU_VATR: begin
                menu_ar_wide <= (rbuf[0] & 8'h0C) == 8'h0C;
                sec_lba    <= jmp_ut_lba;
                fetch_base <= 11'd0;
                fetch_ret  <= S_UT_HDR;
                fi         <= 6'd0;
                fi_cap_v   <= 1'b0;
                state      <= S_SECREAD;
            end

            // PGCI_UT header: nr_of_lus@0; LU[0].lang_start_byte u32 @12 (byte
            // offset rel. to the UT). Single LU -> take it directly (the
            // pre-Phase-4 path, bit-identical). Multiple LUs -> Phase 4
            // language walk (S_LU_EVAL): match LU_LANG_PREF ('en' = SPRM0)
            // against each LU's lang_code, LU[0] on no match — the exact
            // libdvdnav get_MENU_PGCIT rule (getset.c; no wildcard-0xFFFF
            // special case: an all-wildcard UT falls back to LU[0], with the
            // same result libdvdnav gets). parse_buf still holds the UT
            // sector and the whole LU list fits in it (8 + 99*8 < 2048), so
            // each step is a cheap S_FETCH re-shadow, no extra sd reads.
            S_UT_HDR: begin
                if (ut_nr_lus == 16'd0 || ut_nr_lus > 16'd99 ||
                    ut_lu0_start < 32'd8 || ut_lu0_start > 32'd2097151) begin
                    pgc_error <= 1'b1;
                    dbg_pgcerr <= {3'd6, 5'd0, want_pgcn[7:0]};
                    state     <= S_DONE;
                end else if (ut_nr_lus == 16'd1) begin
                    pit_sec    <= jmp_ut_lba + (ut_lu0_start[20:0] >> 11);
                    pit_off    <= ut_lu0_start[10:0];
                    sec_lba    <= jmp_ut_lba + (ut_lu0_start[20:0] >> 11);
                    fetch_base <= ut_lu0_start[10:0];
                    fetch_ret  <= S_PGCIT_HDR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end else begin
                    lu_n       <= ut_nr_lus[6:0];
                    lu0_st     <= ut_lu0_start;
                    lu_i       <= 7'd0;
                    fetch_base <= 11'd8;               // LU[0] descriptor @8
                    fetch_ret  <= S_LU_EVAL;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_FETCH;             // UT sector is resident
                end
            end

            // Phase 4: LU[lu_i] descriptor in the shadow ({lang u16@0,
            // start u32@4}). Match -> that unit's PGCIT; exhausted -> LU[0].
            S_LU_EVAL: begin
                if (lu_lang == lu_lang_pref &&
                    rbuf_be32_4 >= 32'd8 && rbuf_be32_4 <= 32'd2097151) begin
                    pit_sec    <= jmp_ut_lba + (rbuf_be32_4[20:0] >> 11);
                    pit_off    <= rbuf_be32_4[10:0];
                    sec_lba    <= jmp_ut_lba + (rbuf_be32_4[20:0] >> 11);
                    fetch_base <= rbuf_be32_4[10:0];
                    fetch_ret  <= S_PGCIT_HDR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end else if ({1'b0, lu_i} + 8'd1 < {1'b0, lu_n}) begin
                    lu_i       <= lu_i + 7'd1;
                    fetch_base <= 11'd8 + {(lu_i + 7'd1), 3'b000};
                    fetch_ret  <= S_LU_EVAL;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_FETCH;
                end else begin
                    // no language match -> LU[0] (libdvdnav fallback)
                    pit_sec    <= jmp_ut_lba + (lu0_st[20:0] >> 11);
                    pit_off    <= lu0_st[10:0];
                    sec_lba    <= jmp_ut_lba + (lu0_st[20:0] >> 11);
                    fetch_base <= lu0_st[10:0];
                    fetch_ret  <= S_PGCIT_HDR;
                    fi         <= 6'd0;
                    fi_cap_v   <= 1'b0;
                    state      <= S_SECREAD;
                end
            end

            // ------------------------------------------------------------
            S_DONE:  ;
            S_ERROR: ;
            default: state <= S_IDLE;
            endcase
        end
    end
end

// =========================================================================
// Output pipeline: one byte/cycle from the cache when the FIFO can take it
// (identical 2-stage scheme to mpg_streamer)
// =========================================================================
wire streaming = (state == S_STREAM);
reg  read_valid_pipe;

// FLAT-SEEK PACK HUNT: a seek on a plain flat PS file (.mpg / directly-selected
// .VOB) lands at an arbitrary byte offset, and ps_demux resets per-jump — if
// the first start code it then saw were a video slice/picture code it would
// mis-latch into raw-ES passthrough (video-only, no audio, wedged until the
// next load). MPEG start codes cannot be emulated in-stream, so after such a
// seek the pipeline DROPS bytes until 00 00 01 BA, then re-emits the consumed
// preamble from constants (the ps_demux S_ES_EMIT trick) and streams on —
// emission always (re)starts at a genuine pack. Raw MODE2/2352 seeks don't arm
// this (every sector is a pack boundary); cell-mode seeks use the NAV snap.
reg        hunt_active;     // dropping bytes, looking for the pack start code
reg        pre_active;      // re-emitting the 00 00 01 BA preamble
reg [1:0]  pre_idx;
reg [23:0] hunt_shift;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        stream_data     <= 8'd0;
        stream_valid    <= 1'b0;
        read_valid_pipe <= 1'b0;
        rd_ptr          <= 0;
        hunt_active     <= 1'b0;
        pre_active      <= 1'b0;
        pre_idx         <= 2'd0;
        hunt_shift      <= 24'hFFFFFF;
    end else if (start || seek_jump || jump_ack || seek_ack) begin
        // Flush the output pipeline on load, an executing seek, a VM jump, or
        // a reader-internal PGC advance (menu next_pgcn - it pulses seek_ack)
        // so no stale cached bytes from the old position leak downstream.
        // jump_ack/seek_ack arrive one cycle after their wr_ptr reset, but the
        // FSM has already left S_STREAM by then (streaming=0), so no byte can
        // be read in the gap.
        rd_ptr          <= 0;
        stream_valid    <= 1'b0;
        read_valid_pipe <= 1'b0;
        // Arm the pack hunt on the seek_jump cycle itself; the trailing
        // seek_ack flush cycle must PRESERVE it (seek_ack pulses one cycle
        // after seek_jump), and a fresh mount clears it.
        if (start)          hunt_active <= 1'b0;
        else if (seek_jump) hunt_active <= !cell_mode && !raw_mode;
        pre_active      <= 1'b0;
        pre_idx         <= 2'd0;
        hunt_shift      <= 24'hFFFFFF;
    end else begin
        stream_valid <= 1'b0;

        if (pre_active) begin
            // re-emit the consumed 00 00 01 BA (input pipeline held)
            if (!busy) begin
                stream_data  <= (pre_idx == 2'd3) ? 8'hBA :
                                (pre_idx == 2'd2) ? 8'h01 : 8'h00;
                stream_valid <= 1'b1;
                if (pre_idx == 2'd3) pre_active <= 1'b0;
                else                 pre_idx    <= pre_idx + 2'd1;
            end
        end else if (read_valid_pipe) begin
            if (hunt_active) begin
                // consume silently; fire the preamble once the code completes
                if ({hunt_shift, cache_rd_data} == 32'h000001BA) begin
                    hunt_active <= 1'b0;
                    pre_active  <= 1'b1;
                    pre_idx     <= 2'd0;
                end
                hunt_shift      <= {hunt_shift[15:0], cache_rd_data};
                read_valid_pipe <= 1'b0;
            end else begin
                stream_data     <= cache_rd_data;
                stream_valid    <= 1'b1;
                read_valid_pipe <= 1'b0;
            end
        end

        if (!busy && !read_valid_pipe && !pre_active && cache_has_data && streaming) begin
            rd_ptr          <= rd_ptr + 1;
            read_valid_pipe <= 1'b1;
        end
    end
end

// =========================================================================
// Debug
// =========================================================================
// Transport read-backs (for gamepad seek + future UI)
assign cur_cell             = cell_i;
assign cell_ready           = cell_mode;

// Menu-domain read-backs (Phase 2)
assign menu_active          = menu_dom;
assign still_active         = (state == S_STILL);
assign cur_vts              = play_vtsn;
assign cur_pgcn_o           = cur_pgcn;
assign best_menu_vts        = best_mnu_vts;
assign cur_cell_still       = cm_rd[15:8];
assign cur_cell_cmdnr       = cm_rd[7:0];

// Phase-4 DVD-VM read-backs
assign nav_ready_o          = nav_ready;
assign auto_vts             = (title_sel != 7'd0) ? {1'd0, title_sel} : best_vtsn;
assign cell_count_o         = cell_count;
// SPRM5 (VTS_TTN) source: cur_ttn = the loaded title's vts_ttn (latched in
// S_PTTLD_MAT on every title load, BEFORE the PTT resolve clears want_ttn in
// S_PTT_PGC). Using want_ttn directly zeroed res_ttn/SPRM5 after a JumpTT on any
// disc with a VTS_PTT_SRPT (the resolve path clears want_ttn pre-pgc_loaded),
// which then broke the VM's cross-PGC LinkPTT resolve (jump_ttn=SPRM5=0).
assign res_ttn              = cur_ttn;

assign debug_active         = streaming;
assign debug_sd_rd          = sd_rd;
assign debug_sd_ack         = sd_ack;
assign debug_cache_has_data = cache_has_data;
assign debug_file_size      = file_size[15:0];
assign debug_total_sectors  = total_blocks[15:0];
assign debug_next_lba       = sd_lba[15:0];
// state widened 5->6 bits (Phase-0 ALM reclaim); the 2 pad bits now carry the
// Phase-2 menu-domain/still flags.
assign debug_state          = {iso_mode, iso_error, sel_valid, best_cnt[4:0],
                               menu_dom, (state == S_STILL), state};
assign debug_iso_mode       = iso_mode;
assign debug_iso_error      = iso_error;
assign raw_mode_o           = raw_mode;
// Linear transport: raw mode always seeks (sector = pack boundary); a plain
// flat file only once the demux has proven the stream has packs (else .m2v
// ES stays linear-only). Never in cell/ISO mode.
assign lin_seek_ok_o        = !cell_mode && !iso_mode &&
                              (raw_mode || flat_seek_en);
assign lin_blk_o            = strm_blk;
assign debug_play_vtsn      = play_vtsn;
assign debug_target_vtsn    = target_vtsn;

endmodule
