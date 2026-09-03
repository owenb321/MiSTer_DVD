module emu (
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,
	output        VGA_DISABLE,

	output        CLK_SYS,
	output        CLK_MEM,

	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,

	// DVD-FORK FIX: canonical MiSTer direction is OUTPUT (core -> HPS virtual
	// buttons; b[0] = OSD button). This fork inherited it as an input, leaving
	// sys_top's btn wire undriven -- which is why the core could never pop the
	// OSD open at load like console cores do. See the osd_btn block.
	output  [1:0]  BUTTONS,

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output        AUDIO_MIX,

	// DVD-FORK: IEC 61937 S/PDIF bitstream passthrough (docs/audio.md Path B).
	// SPDIF_PASS is a biphase-encoded (IEC 60958, non-PCM) bitstream that
	// sys_top muxes onto the S/PDIF pin(s) in place of the framework's PCM
	// spdif whenever SPDIF_PASS_EN is high. These are non-standard emu ports;
	// see the matching mux in sys/sys_top.v.
	output        SPDIF_PASS,
	output        SPDIF_PASS_EN,

	// DVD-FORK: the same IEC 61937 bitstream over HDMI. These are IEC 60958
	// subframes in the ADV7513's "IEC958 direct" format, NOT PCM samples;
	// sys_top substitutes them for the framework's PCM I2S on HDMI_SCLK/LRCLK/
	// I2S while HDMI_BS_EN. Gated on the HPS ack, so a Main that has not put the
	// chip in non-PCM mode never sees them. See docs/hdmi_bitstream.md.
	output        HDMI_BS_SCK,
	output        HDMI_BS_WS,
	output        HDMI_BS_SD,
	output        HDMI_BS_EN,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,


	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	output [6:0]  USER_OUT,
	input  [6:0]  USER_IN,

	input         OSD_STATUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,

	input         CLK_AUDIO,
	output        LOCKED
);

// =========================================================================
// Default assignments for unused interfaces
// =========================================================================
// DVD-FORK FIX (aspect ratio): Auto/4:3/16:9 (O[20:19]). ar_wide_eff is a plain wire
// resolved near the decoder instance (Auto follows the stream's aspect_ratio_information,
// 4:3/16:9 force it) — declared early so these assigns can forward-reference it, mirroring
// pal_eff. Selects the MiSTer scaler output aspect; the raster resolution is unchanged.
wire ar_wide_eff;
// DVD-FORK (dual-raster analog output): while Analog Aspect Letterbox/Crop is
// active the RASTER ITSELF is made 4:3-true upstream (disp_vscale/disp_hstretch),
// and under dual raster HDMI sees that raster too — so force the scaler aspect to
// 4:3 or ascal would stretch the already-letterboxed image back to 16:9.
// DVD-FORK (idle screen, PR #9 follow-up): while NO media has been mounted the
// Auto aspect path has no stream DAR to follow and idled at 4:3 -- on a 16:9
// display ascal pillarboxed the raster, confining the bouncing logo to the
// centre 4:3 window (HW report, 2026-08-26). The scaler output mode is already
// an emu input (HDMI_WIDTH/HEIGHT, previously unused), so idle now presents
// 16:9 whenever the DISPLAY is widescreen (W/H >= 1.5, shift+add only:
// 1920x1080 wide, 640x480 / 1280x1024 not) and the raster fills the screen --
// the logo bounces edge-to-edge. Registered + gated on the quasi-static
// media_seen so VIDEO_ARX/ARY stays STABLE (the one flip at first mount
// coincides with the load's own scaler re-init). The mild anamorphic stretch
// of the logo (720x480 -> 16:9) is accepted -- same geometry as anamorphic
// DVD content. Independent of O[20:19]: that option describes CONTENT aspect;
// idle has none, so display-fit wins. HDMI_WIDTH==0 (no scaler) -> 4:3 path.
reg disp_wide_q = 1'b0;
always @(posedge clk_sys)
    disp_wide_q <= ({1'b0, HDMI_WIDTH, 1'b0} >=                       // 14-bit W*2
                    {1'b0, HDMI_HEIGHT, 1'b0} + {2'b00, HDMI_HEIGHT}) // 14-bit H*3
                   && (HDMI_WIDTH != 12'd0);       // W*2 >= H*3  <=>  W/H >= 1.5
wire idle_wide = ~media_seen & disp_wide_q;

assign VIDEO_ARX    = (analog_letterbox | analog_crop) ? 13'd4 : (ar_wide_eff | idle_wide) ? 13'd16 : 13'd4;
assign VIDEO_ARY    = (analog_letterbox | analog_crop) ? 13'd3 : (ar_wide_eff | idle_wide) ? 13'd9  : 13'd3;

// DVD-FORK FIX (interlaced cadence): interlaced field indicator. In interlaced
// mode the syncgen encodes the field in v_pos[0] (rtl/mpeg2/syncgen.v:289:
// v_pos = {v_cntr, ~odd_field}), so v_pos[0] == ~odd_field and is constant for a
// whole field. core_v_pos is in the dot_clk(=clk_sys) domain, same as VGA_F1, so
// no CDC is needed. Progressive mode (O9=off) forces F1=0 (v_pos[0] toggles every
// line there). Polarity may need flipping on HW if the two fields come out
// swapped — see docs/history.md.
// pal_eff: resolved PAL/50Hz flag (Auto-detected or forced via O[17:16]); assigned
// near the decoder instance once core_vertical_size / pal_det_s2 exist.
wire pal_eff;
// DVD-FORK (Video Output consolidation, 2026-09-02 — replaces the O[10:9]
// "Interlaced Out" + O[27:26] "Analog Out" pair):
// ONE output-mode choice, O[10:9] "Video Output" = Auto / Interlaced / Progressive.
//   Interlaced  = the old "Analog Out = Native Fields", renamed: the decoder runs in
//                 native-fields mode (il_eff — the MAIN raster is the pixrep 480i/576i
//                 fields raster WITH the N64-model half-line, i.e. a standard 15 kHz
//                 interlaced signal). SINGLE RASTER (2026-09-03): that one raster goes
//                 to ascal (HDMI 480i, OB Bob/Weave) AND straight to the analog pins
//                 through the stock chain, like every other 480i core — the second
//                 raster (dvd/re_interlace.sv / VGA2_*) is deleted, see
//                 docs/single_raster_analog.md. Structurally immune to the derive
//                 path's field-pairing defect (a governor late re-scans a field PAIR
//                 = even), and the field-parity corrector (docs/field_parity.md) keeps
//                 content-field <-> raster-field alignment through seeks/restarts.
//   Progressive = the progressive main raster: full HDMI quality, Film 24p available,
//                 and the analog pins carry the progressive raster through the stock
//                 path (480p/576p-capable analog displays).
//   Auto        = ini-driven, boot-static: an analog TV configured in MiSTer.ini
//                 (vga_scaler=0 plus composite_sync / ypbpr / vga_sog, or direct_video;
//                 forced_scandoubler vetoes = a 31 kHz VGA rig) resolves to Interlaced,
//                 else Progressive — the same ini workflow as every other core.
// The 2026-07 dual-raster DERIVE (weave) modes — CRT 480i built from the progressive
// raster, HDMI simultaneously progressive — are DELETED (field-reported "extremely
// wobbly": the pairing parity flips on every governor late, ~4/s; the simultaneity was
// deliberately traded away — pick-your-output). A mid-title change WORKS (HW-observed
// 2026-09-02): it toggles il_eff and fires the full seek-equivalent il_switch flush —
// a brief chapter-seek-style interruption — and the parity corrector lands the field
// phase clean (pre-corrector this restart was one of the coin-flip perturbations,
// which is where the old "set it before loading" advice came from). Setting the mode
// before loading merely avoids the interruption.
// See docs/analog_dual_raster.md (history + fieldpass design),
// docs/interlaced_auto.md (superseded), docs/field_parity.md.
wire direct_video;                        // hps_io cfg[10] (declared early for the gating here)
wire forced_scandoubler;                  // hps_io cfg[4]
wire ini_vga_scaler, ini_csync, ini_ypbpr, ini_sog;  // hps_io MiSTer.ini exports (DVD-FORK)
wire cfg_seen, cfg_wr;                               // hps_io cfg-word bookkeeping (DVD-FORK)
wire hdmi_bs_ack;                                    // cfg[14] HPS ack (DVD-FORK, HDMI bitstream)
wire bs_stb_w;                                       // 48 kHz pair strobe from iec61937_wrap
wire [1:0] video_out_mode = status[10:9]; // 0=Auto 1=Interlaced 2=Progressive (O[27:26] left dead — old Analog Out)
// Debug "Title VTS" override (P1, two BCD digits -> VTS 1..99; 0 = Auto).
// See the CONF_STR note at the retired O[31:28] slot.
wire [3:0] dbg_tv_tens  = status[35:32];
wire [3:0] dbg_tv_units = status[39:36];
wire [6:0] dbg_title_vts = {3'd0, dbg_tv_tens} * 7'd10 + {3'd0, dbg_tv_units};
// Player Language (O[43:40]) -> ISO-639 2-char code. Drives the reader's
// menu-LU match AND dvd_vm's SPRM0/16/18 with the SAME value so the disc's
// nav commands and the LU pick can never disagree.
reg [15:0] player_lang;
always @(*) case (status[43:40])
    4'd1:  player_lang = "fr";
    4'd2:  player_lang = "de";
    4'd3:  player_lang = "es";
    4'd4:  player_lang = "it";
    4'd5:  player_lang = "ja";
    4'd6:  player_lang = "zh";
    4'd7:  player_lang = "ko";
    4'd8:  player_lang = "pt";
    4'd9:  player_lang = "ru";
    4'd10: player_lang = "nl";
    4'd11: player_lang = "sv";
    4'd12: player_lang = "da";
    4'd13: player_lang = "no";
    4'd14: player_lang = "fi";
    4'd15: player_lang = "pl";
    default: player_lang = "en";
endcase
wire       analog_want_raw = ((ini_csync | ini_ypbpr | ini_sog) & ~ini_vga_scaler & ~forced_scandoubler)
                           | direct_video;
// DVD-FORK FIX (single-raster analog, 2026-09-03): analog_want is LATCHED. The old
// wire was combinational off Main's live cfg word while the comment next to it
// claimed a boot-time latch that never existed: Main re-sends cfg on every
// video_mode_adjust (each resolution report), on leaving the OSD, and after an ini
// `[video=...]` section re-parse - and a changed analog bit mid-play was a full
// il_switch (flush trio + modeline walk) with nothing the user did. The latch
// (assigned after img_mounted exists, below the file loader) FOLLOWS cfg while no
// media is mounted (so a boot-time video-section re-parse is honoured) and FREEZES
// while a disc plays. Auto is now genuinely boot/idle-static; interlaced_eff changes
// only on an OSD edit (il_switch) or a change made with nothing mounted.
wire       analog_want;
// The ONE resolved output mode. Session flag: drives the decoder fields mode (il_eff)
// = the pixrep 480i/576i half-line MAIN raster that both ascal and the analog pins
// consume, and every analog-only nicety (SIF fill, Analog Aspect, line-21 CC).
wire       interlaced_eff = (video_out_mode == 2'd1)
                          | ((video_out_mode == 2'd0) & analog_want);
// Analog Aspect resolves near the decoder (needs ar_wide_auto_eff); forward-declared
// like ar_wide_eff/pal_eff so VIDEO_ARX/ARY above can reference them.
wire analog_letterbox, analog_crop;
// DVD-FORK (Film 24p Out, issue #124): emit a PROGRESSIVE-FILM raster (one decoded
// film frame per refresh, NO in-core 3:2) so the framework scaler (ascal) does the
// pulldown to the 59.94/50 Hz HDMI output. This cuts the core's framebuffer re-reads
// (NTSC 60/s->24/s, PAL 50/s->25/s), handing motion-comp a big contiguous DDR3 window
// each vblank so it stops missing deadlines (the issue #124 cadence pulse) — a
// throughput win, NOT arbiter scheduling. NTSC => 23.976 Hz (2:5 to 59.94; ascal 3:2);
// PAL => 25.000 Hz (exact 1:2 to 50; ascal frame-doubles). Three-way P1O[25:24]:
//   Off (00) never; On (01) force (hard-telecine discs carry no rff so Auto can't see
//   them); Auto (10) the in-fabric cadence detector drives it. film_det_*_sync are the
//   governor's per-frame cadence verdicts 2-FF synced clk_dec->clk_sys (assigned by the
//   decoder instance); pick the verdict for the resolved standard (NTSC = 3:2 soft-
//   telecine, PAL = sustained progressive = native 25p). CRT can't do 24/25 Hz on the
//   analog pins, so forced off there. See docs/film_24p_plan.md §9.
wire        film_det_ntsc_sync, film_det_pal_sync;   // driven near the decoder instance
// Enum ORDER makes AUTO the power-on default: MiSTer status bits reset to 0, and
// index 0 = "Auto" in the CONF_STR below, so an unconfigured core film-detects.
wire [1:0]  film_mode  = status[25:24];              // 0=Auto 1=Off 2=On
wire        film_det   = pal_eff ? film_det_pal_sync : film_det_ntsc_sync;
wire        film_want  = (film_mode == 2'b10) | ((film_mode == 2'b00) & film_det);
// The 23.976/25 Hz film raster is a PROGRESSIVE-mode feature: it cannot carry fields
// (and cannot feed the analog re-timer — no frame store for the rate conversion), so
// Interlaced mode suppresses it. Film on the CRT then plays with its normal 3:2 field
// cadence — exactly what an NTSC set-top player output.
// DVD-FORK FIX (single-raster analog, 2026-09-03): on a rig whose ini asks for native
// analog (analog_want) but whose user picked Progressive, an AUTO film verdict is
// suppressed - the analog pins carry the main raster through the stock path there, and
// the 23.976/25 Hz film modeline (875x1287 @ 30.9 kHz) is a signal no analog display
// holds: HW report "Progressive is stable in the menus, loses signal when the feature
// starts". ⚠ Only the AUTO verdict: `Film 24p Out = On` is an explicit user choice and
// is honoured, which is how an analog-configured rig watches 24p on HDMI with the CRT
// switched off (HW round 6 - the blunt ~analog_want gate took that away, and Auto
// already resolves such a rig to Interlaced, where filmp_eff is 0 anyway, so the gate
// only ever bit the deliberate case). An HDMI-only rig (analog_want=0) is unaffected.
wire        film_forced = (film_mode == 2'b10);      // O[25:24] = On (not Auto)
wire        filmp_eff  = film_want & ~interlaced_eff & (film_forced | ~analog_want);
wire        film24_eff = filmp_eff & ~pal_eff;       // NTSC 23.976 Hz path
wire        film25_eff = filmp_eff &  pal_eff;        // PAL  25.000 Hz path
// il_eff: the decoder/main-raster fields mode — now simply the resolved Video Output
// verdict (kept as its own name because ~15 consumers ride it: VGA_F1, HDMI_BOB_DEINT,
// the modeline walk, il_switch, the pixrep overlay inverses, the CC inserter). Interlaced
// mode owns the session outright: film_want does NOT override it (Film 24p is a
// Progressive-mode feature, see filmp_eff above). The old derivation
// (analog_fields | (il_want & ~filmp_eff & ~analog_eff)) died with the Interlaced Out
// option and the derive modes — Video Output consolidation, 2026-09-02.
wire il_eff = interlaced_eff;
assign VGA_F1       = il_eff ? ~core_v_pos[0] : 1'b0;
assign VGA_SL       = 0;
// DVD-FORK (dual-raster analog output): VGA_SCALER is never forced any more —
// sys_top ORs this into the ini bit (vga_scaler = cfg[2] | vga_force_scaler), so
// driving it 1 made MiSTer.ini `vga_scaler=0` unobservable (the pre-rework state:
// analog CRT needed the O[14] OSD step). Standard MiSTer behavior: the core
// drives 0 and the ini alone decides scaler-vs-native on the analog pins.
assign VGA_SCALER   = 1'b0;
assign VGA_DISABLE  = 0;
assign HDMI_FREEZE      = 0;
assign HDMI_BLACKOUT    = 0;
// DVD-FORK FIX (interlaced cadence): 480i deinterlace mode for the MiSTer scaler
// (ascal, sys/sys_top.v:1769 -> .bob_deint). Only meaningful when O9 (480i) is on.
//   OB=0 (Bob, default): line-double each field to full height -> smooth 60-phase
//        motion, but HALF vertical resolution and a 1px vertical shimmer on static
//        content (the TOP/BOTTOM field offset).
//   OB=1 (Weave): interleave the two fields -> FULL vertical resolution and no
//        shimmer on static/film content, but combing on fast inter-field motion.
//        Best for film (3:2-pulldown) DVDs; Bob is better for true-video DVDs.
// Progressive mode (O9 off) emits no field flag, so this is forced 0 (don't-care).
assign HDMI_BOB_DEINT   = il_eff & ~status[11];

// DVD-FORK (interlaced overlay alignment, 2026-08-22): the interlaced raster uses
// PIXEL REPETITION (rtl/mpeg2/syncgen_intf.v doubles every horizontal timing value,
// mixer.v duplicates each pixel), so core_h_pos counts 0..1715 with ~1440 active —
// but every overlay layer (subpicture bitmap query, HLI button rects, transport HUD,
// seek bar, debug overlay) authors its geometry in 720-wide SOURCE space, so the
// whole overlay collapsed into the LEFT HALF of the picture. The repetition is a
// uniform x2, so one shift inverts it; no Bresenham inverse needed (contrast
// dvd/crt_ov_map.sv, which does need one for the anamorphic scalers). Progressive
// mode is bit-identical (il_eff low => pure pass-through).
// NOTE: the per-module lead compensations (HUD_QX_ADJ/BAR_QX_ADJ) are expressed in
// raster DOTS and stay uncorrected here, so they read ~2x large in source pixels —
// a <=3 px error on a 720-wide picture, invisible and confined to interlaced output.
// The subpicture path below does it exactly (subtract the lead in dot space, THEN
// halve) because that query drives the menu-highlight hit test.
wire [11:0] ov_h_gen = il_eff ? {1'b0, core_h_pos[11:1]} : core_h_pos;

// LED and status assignments consolidated at the end of module

// In-fabric decoded audio (AC-3 + LPCM) drives the framework audio out directly.
// AUDIO_S=1 -> samples are signed s16. See dvd/dvd_audio_decode.sv.
//
// O6 "Audio Out": 0 = Decode (HDMI PCM, default), 1 = Passthrough (IEC 61937
// bitstream on S/PDIF; the receiver decodes AC-3/DTS). In passthrough the HDMI
// PCM is muted (the receiver plays the S/PDIF stream). O7 flips the S/PDIF
// payload byte order live (the classic "passthrough plays static" gotcha).
wire signed [15:0] dec_audio_l, dec_audio_r;
wire        pass_mode  = status[6];   // O6: 1 = IEC 61937 passthrough
wire        pass_bswap = status[7];   // O7: 1 = swap payload byte order
assign AUDIO_S      = 1;
assign AUDIO_MIX    = 0;
// css_scrambled: CSS-encrypted source detected (sticky latch by the demux
// instance below) — mute the PCM out (scrambled AC-3 decodes to loud static).
// probe taps (declared unconditionally — the instantiation below always
// connects them; the tone logic itself is behind the define)
wire [1:0] dbg_cur_codec_w;
wire       dbg_mp2_avalid_w;
wire       dbg_mp2_s_nz_w, dbg_mp2_pcm_nz_w;
`ifdef MP2_TONE_PROBE
// ============ TEMPORARY HW DIAGNOSTIC v2 (MP2 silent-audio bisect) ===========
// Round-1 result: dispatch + decode-FSM + FIFO pops all run (both v1 tones),
// so the decoder emits perfectly-timed ZERO samples. v2 probes DATA liveness:
//   LEFT  = 1 kHz tone if any NONZERO dequantized subband sample was written
//           in the last ~39 ms (parse + dequant produce real data)
//   RIGHT = 1 kHz tone if any NONZERO PCM pair was pushed in the last ~39 ms
//           (synthesis produces real data)
// Interpretation: both silent -> the parse yields empty allocations / zero
// samples (bit-reader/alloc path in silicon); LEFT only -> synthesis zeros
// the data (N/D ROM or V-ring/MAC path); both tones -> real PCM is pushed and
// the fault is in the FIFO-pop/output-latch path. Remove after the bisect.
reg [14:0] probe_div;  reg probe_sq;
always @(posedge clk_sys) begin
    probe_div <= (probe_div == 15'd13499) ? 15'd0 : probe_div + 15'd1;  // 1 kHz square
    if (probe_div == 15'd13499) probe_sq <= ~probe_sq;
end
reg [19:0] probe_act_s, probe_act_p;        // ~39 ms activity windows
always @(posedge clk_sys) begin
    if (dbg_mp2_s_nz_w)        probe_act_s <= 20'hFFFFF;
    else if (probe_act_s != 0) probe_act_s <= probe_act_s - 20'd1;
    if (dbg_mp2_pcm_nz_w)      probe_act_p <= 20'hFFFFF;
    else if (probe_act_p != 0) probe_act_p <= probe_act_p - 20'd1;
end
wire signed [15:0] probe_tone = probe_sq ? 16'sd8000 : -16'sd8000;
assign AUDIO_L = (probe_act_s != 0) ? probe_tone : (pcm_mute ? 16'sd0 : dec_audio_l);
assign AUDIO_R = (probe_act_p != 0) ? probe_tone : (pcm_mute ? 16'sd0 : dec_audio_r);
// =============================================================================
`else
assign AUDIO_L      = pcm_mute ? 16'sd0 : dec_audio_l;
assign AUDIO_R      = pcm_mute ? 16'sd0 : dec_audio_r;
`endif
assign SPDIF_PASS_EN = pass_mode;

// -----------------------------------------------------------------------------
// DVD-FORK: HDMI IEC 61937 bitstream (docs/hdmi_bitstream.md)
// -----------------------------------------------------------------------------
// hdmi_bs_ack is cfg[14] from MiSTer_DVDcss: "the ADV7513 is in IEC958-direct /
// non-PCM mode". Stock Main never sets it, so everything below stays inert and
// the core behaves exactly as it does today.
//
// ⚠ INVARIANT - the ACK owns the HDMI audio format, not pass_mode. While the ack
// is set the sink has been told to expect non-PCM, so the core must never put PCM
// on HDMI: a receiver would decode it as a data burst. Leaving Passthru is
// instant in fabric but the chip stays in non-PCM mode until Main's next poll, so
// that window has to be digital silence rather than decoded audio. Hence
// hdmi_bs_ack joins the mute term above instead of pass_mode alone.
wire pcm_mute = pass_mode | css_scrambled | hdmi_bs_ack;

// Post-reset hold-off. rst_audio_n pulses on every audio-track switch and
// aud_flush, and it re-phases the subframe pacing (MEASURED: the first interval
// after a reset is 509 clk_audio, not 512 - see bench/dvd/iec61937_wrap_tb.sv
// TEST 9). Mute the HDMI leg for ~100 ms across that so a receiver sees clean
// silence and one switch, never a torn subframe.
reg [12:0] bs_hold;
always @(posedge CLK_AUDIO or negedge rst_audio_n)
    if (!rst_audio_n)                 bs_hold <= 13'd4800;   // ~100 ms at 48 kHz
    else if (bs_stb_w && |bs_hold)    bs_hold <= bs_hold - 13'd1;

assign HDMI_BS_EN = pass_mode & hdmi_bs_ack & ~|bs_hold;

assign SD_SCK       = 0;
assign SD_MOSI      = 0;
assign SD_CS        = 1;

// The SDRAM add-on board controller (dvd/sdram.sv) and its self-test were REMOVED:
// the core's memory runs entirely on the HPS f2sdram (DDRAM) burst bridge
// (dvd/mem_shim_burst.sv), which returns clean burst data at 90 MHz. The SDRAM_*
// pins are no longer driven by this core. See docs/history.md.

assign UART_RTS     = 1;
assign UART_DTR     = 1;
assign UART_TXD     = 1;   // UART debug removed; drive TX to idle (high)

// Debug: Stream loading status on USER_OUT pins
// assign USER_OUT     = {3'b0, streamer_active, streamer_sd_rd, streamer_sd_ack, streamer_has_data};

// =========================================================================
// Clocks and Reset
// =========================================================================
wire clk_sys, clk_mem, clk_vid, clk_dec, locked;

sys_pll sys_pll (
    .refclk   (CLK_50M),
    .rst      (1'b0),
    .outclk_0 (clk_sys),  // 27 MHz
    .outclk_1 (clk_mem),  // 90 MHz (clk_mem — DDRAM burst bridge + decoder mem_clk)
    .outclk_2 (clk_vid),  // 25.175 MHz
    .outclk_3 (clk_dec),  // 81 MHz (VCO 810/10) — decoder COMPUTE clock. The decode domain's
                          // raw Fmax is ~80 MHz, so 81 over-clocked it -> intermittent green
                          // chroma fringe. FIXED via Quartus physical synthesis (DVD.qsf),
                          // which lifts clk_dec Fmax to ~92 MHz => 81 is fringe-free at full
                          // compute. HW-CONFIRMED 2026-07-01. See dvd/sys_pll.sv + docs.
    .locked   (locked)
);

// HPS f2sdram (DDRAM) is the CORE'S MEMORY DATAPATH via the burst bridge
// dvd/mem_shim_burst.sv (instantiated below). f2sdram streams burst reads cleanly
// at clk_mem (90 MHz) — unlike single reads (which never returned) and unlike the
// SDRAM module's burst (which corrupted chroma). The burst bridge amortizes the HPS
// round-trip latency with burst line-fills to beat the SD scan-out shear. See
// docs/history.md.

// burst-bridge DDRAM outputs (driven by mem_shim_burst_inst, below) — these are
// the DECODER master into ddr_arb (not the DDRAM port directly anymore).
wire [28:0] burst_ddr_addr;
wire  [7:0] burst_ddr_burstcnt;
wire        burst_ddr_read, burst_ddr_write;
wire [63:0] burst_ddr_writedata;
wire  [7:0] burst_ddr_byteenable;

// ddr_arb slave-side outputs (the arbitrated stream that drives DDRAM) + the
// decoder read/waitrequest feedback.
wire [28:0] arb_ddr_addr;
wire  [7:0] arb_ddr_burstcnt;
wire        arb_ddr_read, arb_ddr_write;
wire [63:0] arb_ddr_writedata;
wire  [7:0] arb_ddr_byteenable;
wire        arb_dec_waitrequest;
wire [63:0] arb_dec_readdata;
wire        arb_dec_readdatavalid;

// mem_shim_burst (via ddr_arb) owns the HPS f2sdram DDRAM port directly.
assign DDRAM_CLK      = clk_mem;
assign DDRAM_ADDR     = arb_ddr_addr;
assign DDRAM_BURSTCNT = arb_ddr_burstcnt;
assign DDRAM_RD       = arb_ddr_read;
assign DDRAM_WE       = arb_ddr_write;
assign DDRAM_DIN      = arb_ddr_writedata;
assign DDRAM_BE       = arb_ddr_byteenable;

// Active-low reset for the mpeg2video core
// The core's internal reset module handles watchdog_rst independently,
// so we must NOT feed watchdog_rst back into rst to avoid a latch-up:
// watchdog fires -> reset_n LOW -> async_rst LOW -> hard_rst LOW -> watchdog stuck
wire watchdog_rst;
// DVD-FORK (launch feedback): the OSD "R0,Reset" row actually resets the
// core now. status[0] was previously consumed by NOTHING (most cores OR it
// into their reset; this fork never did, so the Reset row was a no-op). A
// full reset_n pulse gives exactly the wanted semantics for free: media_seen
// clears (playback stops; the bouncing logo + widescreen idle presentation
// return), the reader/demux/decoder pipelines and the DVD-VM (GPRMs
// included) restart -- while the two deliberately reset-less blocks survive:
// the user boot.rom logo (power-up-init-only regs) and the startup-OSD
// one-shot (Reset does NOT re-pop the file picker; R-type options close the
// OSD as they fire, dropping straight to the logo). user_rst_qn is declared
// here and driven next to the hps_io instance (status is declared later --
// the ar_wide_eff early-declare pattern); it is a registered copy because
// reset_n is consumed as an ASYNC clear all over the core.
wire user_rst_qn;
wire reset_n = locked & ~RESET & user_rst_qn;

// 108 MHz / 4 = 27 MHz pixel clock enable for internal modules
reg [1:0] ce_cnt;
always @(posedge clk_mem) ce_cnt <= ce_cnt + 1'b1;
wire ce_pixel = (ce_cnt == 2'b00);

// The MiSTer HDMI/VGA PHY natively clocks at CLK_VIDEO frequency.
// For NTSC 480i/p video, this must be exactly 27.0 MHz.
assign CLK_VIDEO = clk_sys;  // 27 MHz

// DVD-FORK (single-raster analog, 2026-09-03): the dot-clock pipeline always runs at
// the full 27 MHz (dot_ce=1; the pixel_queue CE-stretch shim stays in-tree, inert at
// CE==1). What the FRAMEWORK sees as the pixel enable is decided at the registered
// output stage near the end of this file (ce_pix_q): constant 1 on the progressive
// raster, and in Interlaced mode ONE clock of each pixel-repetition pair - so hps_io
// counts 720 active dots (Main reports 720x480i, not 1440x480i), ascal samples 720
// real pixels, and the analog chain (which never used the enable for data) is
// bit-identical. The old ce_13m5 that paced the second raster is gone with it.
assign CE_PIXEL = interlaced_eff ? ce_pix_q : 1'b1;

// =========================================================================
// HPS IO — OSD menu and file loading
// =========================================================================
// DVD-FORK (alpha release): the OSD version line. `build_id.v` is regenerated on
// every compile by sys/build_id.tcl (wired as PRE_FLOW_SCRIPT_FILE in DVD.qsf) and
// defines BUILD_DATE as "yymmdd" — the mechanism was already present but unused,
// with the version line hardcoded to a meaningless "v1.0". Showing the real build
// date matters for a public release: it is the only way a bug report can identify
// WHICH build the reporter is running.
`include "build_id.v"
// VERSIONING (2026-08-25): bump this the moment a release is PUBLISHED, not when
// the next one is cut. `0.1a` shipped as tag v0.1a-20260825, so every build made
// after that point must advertise 0.1b or it lies about which build it is - and
// this OSD line is the only thing a bug report can quote. Keeping the next
// version open also means the latest .rbf already matches the tag when you decide
// to release, instead of forcing a rebuild (and a fitter re-sweep) at release
// time. BUILD_DATE below still separates dev builds within the series.
// ⚠ Do NOT add a time-of-day or git SHA to BUILD_DATE to separate same-day
// builds: it is part of CONF_STR = part of the netlist, so every compile would
// become a new netlist and re-roll the fitter seed lottery (DVD.qsf's ledger).
// Same-day dev builds are identified by their build_release.sh --name filename.
`define CORE_VERSION "0.4.0"

parameter CONF_STR = {
    "DVD;;",
    // MiSTer CONF_STR file extensions are a CONCATENATED list of 3-char exts
    // with NO separator (MPGM2VVOBISO... = MPG + M2V + VOB + ISO + ...). A
    // space-separated list is wrong: the OSD chunks every 3 chars, so
    // "MPG M2V VOB" -> MPG/_M2/... ISO selects a decrypted DVD-Video image;
    // dvd_iso_reader navigates VIDEO_TS in fabric (largest VTS = main feature).
    // BIN/IMG/DAT select a raw MODE2/2352 CD image (VCD/SVCD bin/cue data
    // track — pick the LARGE track bin; .cue sheets are text the fabric cannot
    // parse). Detection is content-based (sector-sync probe at byte 0), the
    // extension list is only the OSD picker filter. Other files stream as before.
    "S0,MPGM2VVOBISOBINIMGDAT,Load Video;",
    // Aspect Ratio: Auto (default) reads the display AR from the MPEG-2 sequence header
    // (aspect_ratio_information, par. 6.3.3: 2=4:3, 3=16:9); 4:3/16:9 force it. Drives the
    // MiSTer scaler output aspect (VIDEO_ARX/ARY) — the 720x480/576 raster is unchanged,
    // ascal letterboxes/pillarboxes it. status[20:19]: 0=Auto, 1=4:3, 2=16:9.
    "O[20:19],Aspect Ratio,Auto,4:3,16:9;",
    // Disc Menus: On (DEFAULT) = the disc boots its authored First Play PGC and
    // the full DVD virtual machine runs — menus, button highlights, and nav
    // commands all execute, like a set-top player. The Menu/Title gamepad keys
    // jump to the authored menus and resume the title at the saved cell.
    // Off = skip the disc's nav entirely and auto-play the main feature (the
    // largest-VTS heuristic); use it if a disc's menus misbehave.
    // ⚠ DEFAULT FLIPPED 2026-08-23 (end-user defaults pass): the value list was
    // REORDERED, so status[1]=0 now means On (it meant Off before) and menus_on
    // inverts the bit. MiSTer persists the whole status word per core, so a
    // stale /media/fat/config/DVD.cfg from an older build decodes the saved bit
    // with the OLD meaning and comes up Off — delete the .cfg after updating.
    // status[1]. See docs/dvd_nav.md, docs/dvd_vm.md.
    "O[1],Disc Menus,On,Off;",
    // D-Pad Seek: OFF by default. On = the D-pad does VLC-style FIXED-TIME
    // seeking while a title plays -- Left/Right jump -/+10 s, Down/Up -/+60 s --
    // with targets read from the disc's OWN authored DSI seek tables
    // (dvd/dpad_seek.sv). Presses inside ~0.4 s add up into ONE jump.
    // ⚠ Default Off ON PURPOSE: the hold-to-seek scrub was deliberately moved
    // OFF the D-pad in 2026-07-28 because interactive/game DVDs have seekable
    // title video yet expect directional input, and the in_title_menu heuristic
    // cannot always tell the two apart. Off keeps the D-pad pure navigation for
    // everyone who does not ask for this. When On it is still suppressed
    // wherever the nav layer claims the D-pad (menus, in-title game menus).
    // See docs/dvd_nav.md 2b.
    "O[45],D-Pad Seek,Off,On;",
    "O5,Audio,On,Off;",
    // Audio Out: Decode = AC-3/LPCM decoded in fabric to HDMI PCM (default).
    // Passthru = the UNDECODED AC-3/DTS frames are wrapped in IEC 61937 and
    // sent as a bitstream for an AV receiver to decode (Path B; enables DTS,
    // which has no in-fabric decoder). Always out optical S/PDIF, and ALSO over
    // HDMI when MiSTer_DVDcss has put the ADV7513 in IEC958-direct mode and the
    // sink advertises AC-3/DTS; otherwise HDMI stays muted as before.
    // status[6]. See docs/iec61937.md and docs/hdmi_bitstream.md.
    //
    // ★ OX (not O) marks it "also handled by the HPS": the bit still reaches the
    // core exactly as before, but Main sees the declaration in parse_config and
    // learns this build HAS the HDMI bitstream path. A core without it never
    // declares OX6, so Main never reconfigures the chip for a core that cannot
    // drive it. Bit layout is unchanged, so no CONF_STR "v,N" bump is needed.
    "OX6,Audio Out,Decode PCM,Passthru (SPDIF+HDMI);",
    // SPDIF Byte Order: flips the 61937 payload byte packing. If the receiver
    // recognises the format (e.g. "Dolby D"/"DTS") but plays static, toggle
    // this. status[7]. Only meaningful in Passthru.
    "O7,SPDIF Byte Order,Normal,Swap;",
    // Phase-10: audio- and subtitle-TRACK selection moved OFF the OSD onto the
    // gamepad Audio (B7) / Subtitle (B8) cycle buttons (see the J1 line below).
    // Rationale: MiSTer CONF_STR value labels are compile-time static, so a
    // per-disc track/language list can't be shown in the OSD. The track counts
    // are bounded by the title IFO; the on-screen indicator is Phase 11.
    // DVD Title override: MOVED to the Debug page (P1 "Title VTS" tens/units,
    // status[39:32]) and widened to VTS 1..99 -- user decision 2026-08-19: it is
    // a debug aid, not a user feature (Disc Menus is the real selector), and the
    // old 4-bit O[31:28] couldn't reach VTS_16+ on ~9% of the library (Atmosfear
    // has 75 VTS). Bits [31:28] are left DEAD one release so stale per-core
    // saved status can't re-arm a title override (the O[14] retirement pattern).
    // Subtitle: DVD subpicture overlay (dvd/spu_decode.sv + dvd/subpic_blend.sv),
    // authored IFO palette (dvd/pgc_palette.sv). Phase-10: on/off + track are now
    // the gamepad Subtitle (B8) cycle button (off -> track 0..N-1 -> off), bounded
    // by the IFO subpicture-stream count. Bits O[15] and O[26:24] are freed.
    // Player Language: one setting drives the DVD player's three language
    // registers, like a set-top player's setup menu - SPRM0 (menu language,
    // picks the PGCI_UT language unit: spec-hardening Phase 4) and SPRM16/18
    // (audio/subtitle preference, read by disc nav commands to auto-select
    // streams). Takes effect at the next menu jump / disc mount. status[43:40].
    "O[43:40],Player Language,English,French,German,Spanish,Italian,Japanese,Chinese,Korean,Portuguese,Russian,Dutch,Swedish,Danish,Norwegian,Finnish,Polish;",
    // Video Output (DVD-FORK consolidation 2026-09-02, replaces "Interlaced Out"
    // O[10:9] + "Analog Out" O[27:26] — bits [27:26] are left DEAD/reserved one
    // release so stale saved status can't re-arm the old enum; the relayout is why
    // the config version below is "v,2"). ONE output-mode choice:
    //   Auto (default) = ini-driven: an analog TV configured in MiSTer.ini
    //                    (vga_scaler=0 AND composite_sync/ypbpr/vga_sog, or
    //                    direct_video=1) => Interlaced, else Progressive — the same
    //                    ini workflow as every other core, nothing to set here.
    //   Interlaced     = the disc's AUTHORED fields (decoder in native-fields mode;
    //                    the main raster IS the 15 kHz half-line 480i/576i signal,
    //                    fed to the analog pins directly; HDMI shows 480i via ascal, OB
    //                    Bob/Weave below). Switchable mid-title — fires the
    //                    seek-equivalent il_switch flush (brief chapter-seek-style
    //                    cut), field phase lands clean via the parity corrector.
    //   Progressive    = the progressive raster: full HDMI quality, Film 24p
    //                    available, analog pins carry 480p/576p through the stock
    //                    path (component/VGA displays; also the dev A/B switch).
    // status[10:9]. See docs/analog_dual_raster.md, docs/field_parity.md.
    "O[10:9],Video Output,Auto,Interlaced,Progressive;",
    "OB,480i Deint,Bob,Weave;",
    // Analog Aspect: how anamorphic content is fitted to the 4:3 analog TV (ONLY
    // active while the analog 480i raster is engaged). Auto = Fit for 4:3 streams,
    // Letterbox for 16:9 (from the sequence header aspect code). Fit = raster
    // passthrough (16:9 shows squished/tall — also the correct 4:3 no-op).
    // Letterbox = vertical downscale 3/4 + black bars (correct 16:9 geometry),
    // vertically anti-aliased (2-tap blend). Crop = horizontal pan-scan: full
    // vertical resolution, sides cropped to fill 4:3 (no bars). NOTE (dual raster):
    // the rescale happens upstream in the shared raster, so HDMI shows it too —
    // VIDEO_ARX/ARY switch to 4:3 while active so HDMI geometry stays correct.
    // status[4:3]: 0=Auto, 1=Fit, 2=Letterbox, 3=Crop. See docs/crt_anamorphic.md.
    "O[4:3],Analog Aspect,Auto,Fit,Letterbox,Crop;",
    // (Line-21 CC moved to the debug page — see P1O[14] below. Normal users never
    // need it: the data is invisible in the VBI and correct behavior is On.)
    // Video Standard: NTSC (720x480p @ 59.94 Hz, 27 MHz dot clock) or PAL (720x576p
    // @ 50 Hz, same 27 MHz clock — 864x625 total = 50.0 Hz). Switches the runtime
    // modeline-write walk AND av_sync's STC tick rate. Auto (default) picks from the
    // stream's vertical_size (480=NTSC, 576=PAL); NTSC/PAL force it (handy for HW
    // bring-up without a matching disc). status[17:16]: 0=Auto, 1=NTSC, 2=PAL. PAL
    // supports native 576i fields (Video Output = Interlaced) for true-interlaced
    // video; PAL film stays 25p. PAL 576i on the analog pins rides the fieldpass
    // re-timer (docs/analog_dual_raster.md).
    // The governor's SHOW_N=2 gives 25 fps from a 50 Hz display. See
    // docs/frame_rate_governor.md / docs/av_sync.md / docs/interlaced_auto.md.
    "O[17:16],Video Standard,Auto,NTSC,PAL;",
    // (DVD-FORK dual raster: the bogus "O[10],Direct Video,Off,On;" entry that used
    // to sit here is DELETED — it collided with the O[10:9] enum (setting it
    // silently forced native fields), and the real direct_video signal comes from
    // the HPS cfg word, not status.)
    // -------------------------------------------------------------------------
    // Debug submenu (P1): diagnostics + tuning levers.
    // NOTE: O[14] Critical-Word Serve, O[15] Dual Outstanding, and O[18] Ref Prefetch
    // were BAKED IN to their HW-confirmed winners (all On) and removed from this menu to
    // free routing (the enables are now 1'b1 constants so Quartus prunes the loser
    // datapaths). See docs/roadmap.md "FPGA congestion / resource cleanup".
    // -------------------------------------------------------------------------
    "P1,Debug;",
    "P1O2,Debug Overlay,Off,On;",
    // Debug title-VTS override (moved off the main page + widened, see the
    // O[31:28] retirement note above). Two BCD digits compose VTS 1..99
    // (CONF_STR value lists are compile-time static, so a single 99-entry list
    // is unusable); 0/0 = Auto (largest VTS). Match tools/iso_nav_check.py's
    // "VTS_0N". status[35:32] = tens, status[39:36] = units.
    "P1O[35:32],Title VTS Tens,0,1,2,3,4,5,6,7,8,9;",
    "P1O[39:36],Title VTS Units,Auto/0,1,2,3,4,5,6,7,8,9;",
    // DVD-FORK (frame-drop governor O[12]): when the decoder falls behind the display
    // cadence on compute-bound (high-motion / PAL) content, drop the next B-frame in the
    // VLD to catch up instead of the governor irregularly repeating late frames. B is
    // never a reference so this cannot corrupt the picture; worst case is a rare dropped
    // frame for a steadier cadence. Default On — the PR #158 film cadence-slip corrector
    // rides this path and does NOT run with Frame Drop Off. O[12] (freed when the AC-3
    // File Test was removed); O[19] is now Aspect Ratio. See docs/motcomp_throughput.md.
    "P1O[12],Frame Drop,On,Off;",
    // Audio Genlock: On (default) = av_sync slews the 48 kHz audio NCO to track the
    // video-referenced STC (PTS-driven A/V sync). Off = free-run the NCO (nco_trim
    // forced 0) while still playing a VOB through the full pipeline — a diagnostic
    // to isolate the av_sync/governor PACING variable from audio_ring overflow /
    // ps_demux filtering. av_sync keeps running so the overlay still shows the drift
    // it WOULD correct. See docs/av_sync.md / docs/fabric_audio.md.
    "P1O[13],Audio Genlock,On,Off;",
    // Force 4:3 Subpics: present as a 4:3/LETTERBOX display so a disc that authors
    // mode-specific subpicture streams serves its 4:3-mode art instead of the 16:9
    // stream. Motivating case: the MiB "visual commentary" - subpicture logical
    // stream 3 maps 16:9-wide -> physical 0x23 (a persistent "set your DVD player to
    // 4x3 display mode" warning) but LETTERBOX -> 0x24 (the actual commentator
    // silhouettes + annotations). On = force the letterbox mapping (selects 0x24) AND
    // apply the pgc->subp_control mapping to the gamepad-selected subtitle stream.
    // Default Off (subpicture path byte-identical when off). Combine with a letterbox
    // OUTPUT mode (CRT O[4:3]=Letterbox) for correct silhouette geometry. status[15].
    // See memory mib-visual-commentary-letterbox-substream / docs/dvd_nav.md.
    "P1O[15],Force 4:3 Subpics,Off,On;",
    // DVD-FORK (line-21 CC diagnostic): paint the caption waveform on a VISIBLE
    // line instead of line 21. The bits are otherwise invisible — they live in the
    // blanking interval — so without this there is no way to tell "the TV is not
    // decoding" from "no captions are reaching the output". See docs/closed_captions.md §6.
    // DVD-FORK (line-21 closed captions): re-inject the disc's EIA-608 caption
    // bytes onto line 21 of the analog raster so the TELEVISION's own decoder
    // renders them, like a real player (dvd/cc_line21.sv, docs/closed_captions.md;
    // ✅ HW-CONFIRMED 2026-08-26). NTSC + analog only; lives in the VBI so it is
    // invisible to anything not looking for it — hence default On, and buried
    // here (user decision, post-HW-confirm): the Off exists only as an escape
    // hatch for capture devices / upscalers that display VBI lines or the rare
    // TV whose caption decoder misbehaves on caption data — the same "CC output
    // on/off" setting real DVD players kept in their setup menus. Reuses bit 14,
    // freed when O[14] "CRT 480i Out" was retired.
    "P1O[14],Line-21 CC,On,Off;",
    "P1O[44],CC Test Line,Off,On;",
    // Flap probe: release a passthrough frame up to N ms EARLY so a marginally
    // not-yet-due frame doesn't cost a whole silence burst on the wire (the STC
    // advances in ~16.7 ms refresh quanta, so an on-the-margin equilibrium
    // chatters hold/release at burst granularity). Bounded (the hold engages
    // past the bias) and below lip-sync perception. status[52:51].
    // Film 24p/25p Out: emit a progressive-film raster (one film frame per refresh, no
    // in-core 3:2) and let the framework scaler (ascal) do the pulldown to the HDMI
    // output — NTSC 23.976 Hz (2:5 -> 59.94) / PAL 25.000 Hz (1:2 -> 50). Fixes the
    // issue #124 progressive-film cadence pulse (and eases the PAL high-motion stutter)
    // by cutting the core's framebuffer re-reads, so motion-comp stops missing
    // deadlines. Off/On/Auto: On forces it (hard-telecine discs); Auto engages only on
    // a confident sustained film cadence (an in-fabric detector). HDMI-only (forced off
    // under Video Output = Interlaced — fields and a 23.976 Hz raster are mutually
    // exclusive). status[25:24]. See docs/film_24p_plan.md.
    // Auto is FIRST so it's the power-on default (status bits reset to 0).
    "P1O[25:24],Film 24p Out,Auto,Off,On;",
    // A/V Offset: signed playback-start trim for the PTS-scheduled audio drain
    // (dvd_audio_decode): audio sample with PTS X leaves the speaker when
    // STC = X + offset. 0 = nominal lip-sync (STC is display-referenced);
    // positive = audio LATER, negative = audio EARLIER. Dial on HW: audio heard
    // EARLY -> go positive; heard LATE -> negative. APPLIES AT THE NEXT (RE)START
    // (clip load / underrun re-entry) — mid-play phase is locked by sample
    // continuity, and a mid-play re-arm deadlocks on full FIFOs (v5.2 reverted).
    // DEFAULT +100 ms (index 0): after the flags_commit drift fix (PR #62, round
    // 12 HW-confirmed) the true residual on NTSC film is ~100 ms audio-EARLY, so
    // +100 nulls it — the recommended NTSC-film setting. The old deep-negative
    // entries (-300/-400/-500) chased the stale-flag RAMP, which is now fixed;
    // the range is rebalanced around +/-200 ms. See docs/av_sync.md.
    "P1O[23:21],A/V Offset,+100ms,-200ms,-100ms,-50ms,0ms,+50ms,+150ms,+200ms;",
    "R0,Reset;",
    // Saved-settings version (lowercase v = user_io.cpp config_ver, DISTINCT
    // from the display-only uppercase V line below): the framework persists
    // the raw 128-bit status word to config/DVD_v<N>.CFG, so any INCOMPATIBLE
    // O[..] relayout must bump N (1..99) or every existing user's file gets
    // silently reinterpreted with mismatched bit meanings (the O[1] Disc
    // Menus polarity flip did exactly that pre-versioning). Bumping orphans
    // the old file and falls everyone back to defaults -- there is no per-bit
    // migration, so audit the index-0 label of every option when bumping.
    "v,2;",   // v2: 2026-09-02 Video Output consolidation relayout (O[10:9] re-enumerated, O[27:26] retired)
    // Gamepad transport (dvd/dvd_iso_reader seek + presentation-clock pause) +
    // disc-menu nav (Phase 2). The J1 list names buttons B1..B11 for the MiSTer
    // "Define buttons" menu (bits 4..14 of joystick_0; D-pad = bits 3:0). The
    // HOLD-to-seek time scrub (accelerating 10->30->60->120 s via
    // dvd/scrub_ctrl.sv) rides its OWN buttons B10 "Fast Fwd" / B11 "Rewind"
    // while a TITLE plays, so the D-pad is ALWAYS free for directional
    // navigation (menu/game button walk) and never conflicts with a game that
    // wants left/right input over seekable video. See docs/dvd_nav.md.
    "J1,Pause,Prev Chapter,Next Chapter,Select,Menu,Angle,Audio,Subtitle,Display,Fast Fwd,Rewind,Title,Return;",
    "V,v",`CORE_VERSION," ",`BUILD_DATE,";"
};

wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wr;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wait = 1'b0;
// (direct_video / forced_scandoubler / ini_* are declared early, next to the
// dual-raster analog gating logic that consumes them.)

wire  [1:0] buttons;
// 128-bit to match hps_io's status port (was [31:0], which truncated it and
// hid bits 32+ — needed since the Debug "Title VTS" picker at status[39:32]).
wire [127:0] status;

// OSD R0 Reset -> core reset (see the reset_n comment near the top)
reg user_rst_q = 1'b0;
always @(posedge clk_sys) user_rst_q <= status[0];
assign user_rst_qn = ~user_rst_q;
wire [31:0] joystick_0;
wire [10:0] ps2_key;    // {toggle, pressed, extended, scancode[7:0]} (numpad menu input)

// SD sector interface signals
wire [31:0] sd_lba;
wire        sd_rd;
wire        sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire        sd_buff_wr;
wire  [0:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;

// BLKSZ=4: 2048-byte sd blocks (= one DVD/ISO sector per request). One HPS
// round-trip per sector instead of four 512-byte ones — the per-request
// latency was the delivery ceiling that starved audio on discs muxed near
// the 10.08 Mbps DVD maximum (Thayer's Quest). sd_lba is in 2048-byte units.
hps_io #(.CONF_STR(CONF_STR), .BLKSZ(4)) hps_io_inst (
    .clk_sys        (clk_sys),
    .HPS_BUS        (HPS_BUS),

    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_index    (ioctl_index),
    .ioctl_wait     (ioctl_wait),

    .buttons        (buttons),
    .status         (status),
    .joystick_0     (joystick_0),
    .ps2_key        (ps2_key),

    .forced_scandoubler(forced_scandoubler),
    .gamma_bus(),
    .direct_video   (direct_video),
    // DVD-FORK (dual-raster analog output): MiSTer.ini video bits
    .ini_vga_scaler (ini_vga_scaler),
    .ini_csync      (ini_csync),
    .ini_ypbpr      (ini_ypbpr),
    .ini_sog        (ini_sog),
    .ini_hdmi_bs_ok (hdmi_bs_ack),
    .cfg_seen       (cfg_seen),
    .cfg_wr         (cfg_wr),

    // SD sector-level access (virtual disk for MPG streaming)
    .sd_lba         ('{sd_lba}),
    .sd_blk_cnt     ('{6'd0}),
    .sd_rd          (sd_rd),
    .sd_wr          (1'b0),
    .sd_ack         (sd_ack),
    .sd_buff_addr   (sd_buff_addr),
    .sd_buff_dout   (sd_buff_dout),
    .sd_buff_din    ('{8'd0}),
    .sd_buff_wr     (sd_buff_wr),

    // Image mount detection
    .img_mounted    (img_mounted),
    .img_readonly   (img_readonly),
    .img_size       (img_size),

    // Wall clock (seconds since the epoch), sent by Main once at core load.
    // The DVD-game entropy seed - see the entropy source below.
    .TIMESTAMP      (hps_timestamp)
);

// =========================================================================
// MPG Sector Streamer: sd_* interface -> stream_data for mpeg2video
// =========================================================================
wire [7:0] stream_data;    // mpg_streamer -> ps_stream_fifo
wire       stream_valid;
wire       core_busy;      // mpeg2video almost-full backpressure

// ps_demux pipeline nets
wire       fifo_almost_full;  // ps_stream_fifo -> mpg_streamer.busy
wire [7:0] demux_in_byte;     // ps_stream_fifo -> ps_demux
wire       demux_in_valid;
wire       demux_in_ready;
wire [7:0] ps_vid_byte;       // ps_demux -> mpeg2video
wire       ps_vid_valid;

wire       ps_demux_in_ready;   // ps_demux's own ready (input handshake)

// O[13] Audio Genlock: index 1 = "Off" = free-run the audio NCO (ignore av_sync's
// nco_trim). Lets a VOB play through the full pipeline with the genlock disabled,
// to tell av_sync/governor pacing apart from audio_ring overflow / ps_demux.
wire       av_freerun = status[13];
// NCO TRIM RETIRED (2026-07-02, lip-sync v3): the 48 kHz audio NCO and the display
// raster both derive from the same 27 MHz clk_sys crystal and the governor plays
// exact cadence ratios, so the audio RATE matches the display by construction —
// there is no drift for a PI slew to correct. Phase is set by the PTS-scheduled
// drain start in dvd_audio_decode. Leaving the trim active would be harmful: its
// entry-side set-point disagrees with the drain-set phase by the (variable) buffer
// occupancy, so the integrator would slowly grind the correct phase away at ±0.5%.
// av_sync stays for the STC + re-anchor + drift telemetry; its trim goes unused.
wire signed [21:0] dec_nco_trim = 22'sd0;

// O[23:21] A/V Offset: signed playback-start trim in 90 kHz ticks (1 ms = 90).
// >0 = audio later. Index 0 = +100 ms (the NTSC-film residual null) power-on
// default. 18-bit SIGNED (the earlier 16-bit width wrapped -400/-500 positive,
// but those entries are retired now that the drift ramp is fixed — PR #62).
reg signed [17:0] av_ofs;
always @(*) begin
    case (status[23:21])
        3'd0:    av_ofs = 18'sd9000;     // +100 ms (default; nulls the NTSC-film residual)
        3'd1:    av_ofs = -18'sd18000;   // -200 ms
        3'd2:    av_ofs = -18'sd9000;    // -100 ms
        3'd3:    av_ofs = -18'sd4500;    //  -50 ms
        3'd4:    av_ofs = 18'sd0;        //    0 ms (nominal)
        3'd5:    av_ofs = 18'sd4500;     //  +50 ms
        3'd6:    av_ofs = 18'sd13500;    // +150 ms
        default: av_ofs = 18'sd18000;    // +200 ms
    endcase
end

// ps_demux audio output -> audio_ring (all clk_sys)
wire [7:0] ps_aud_byte;
wire       ps_aud_valid;
wire [1:0] ps_aud_type;
wire [1:0] ps_aud_lpcm_quant;    // LPCM word length (0=16,1=20,2=24) -> dvd_audio_decode
wire       ps_aud_frame_start;
wire [7:0] ps_pci_byte;         // NAV PCI payload -> nav_pci (Phase 3)
wire       ps_pci_valid;
wire       ps_pci_frame_start;
wire [7:0] ps_dsi_byte;         // NAV DSI payload -> nav_dsi (Phase 7)
wire       ps_dsi_valid;
wire       ps_dsi_frame_start;
wire       ps_aud_ready;        // demux audio flow control: ~(ring almost_full && drain
                                // watchdog armed) — stalls the stream instead of dropping
                                // audio frames; see FLOW CONTROL note at audio_ring below
wire [32:0] ps_aud_frame_pts;       // per-frame audio PTS -> audio_ring
wire        ps_aud_frame_pts_valid;
// Subpicture (subtitle) SPU payload from ps_demux -> spu_decode (all clk_sys)
wire [7:0]  ps_sp_byte;
wire        ps_sp_valid;
wire        ps_sp_frame_start;
wire [32:0] ps_sp_pts;
wire        ps_sp_pts_valid;
// audio_ring status (surfaced on the debug overlay, rows 12/13)
wire [15:0] aud_frames_avail;
wire [15:0] aud_bytes_avail;
wire [15:0] aud_overflow_cnt;

// A/V sync (dvd/av_sync.sv), all clk_sys
wire [32:0] ps_vid_pts;
wire        ps_vid_pts_valid;
wire [32:0] aud_frame_pts_w;        // audio_ring read-side frame PTS
wire        aud_frame_pts_valid_w;
wire [32:0] aud_dispatch_pts;       // dvd_audio_decode -> av_sync
wire        aud_dispatch_pts_valid;
wire signed [21:0] av_nco_trim;     // av_sync -> dvd_audio_decode NCO slew
wire        av_stc_anchored;        // av_sync STC locked -> dispatch schedule gate
wire [32:0] av_stc;
wire signed [31:0] av_drift;
wire [15:0] av_reanchor_cnt;

// Detect image mount event (start streaming)
reg        img_mounted_prev;
wire       start_streaming = img_mounted[0] && !img_mounted_prev;
// DVD-FORK FIX (single-raster analog): the analog_want latch (see its declaration
// near the top). Follows the cfg-derived request while nothing is mounted and once
// Main has actually written cfg (cfg_seen - before that the ini bits read 0), holds
// while media is mounted. Level-based on purpose: an OSD Reset (status[0]) pulls
// reset_n with cfg_seen already high and no new cfg write coming, so an edge-armed
// latch would come back empty.
reg        analog_want_l;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)                          analog_want_l <= 1'b0;
    else if (cfg_seen && !img_mounted[0])  analog_want_l <= analog_want_raw;
end
assign analog_want = analog_want_l;
reg [63:0] current_file_size;

always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        img_mounted_prev  <= 1'b0;
        current_file_size <= 64'd0;
    end else begin
        img_mounted_prev <= img_mounted[0];
        if (img_mounted[0])
            current_file_size <= img_size;
    end
end

// =========================================================================
// STARTUP OSD POPUP (launch-feedback, 2026-08-26): pop the framework OSD
// ~0.9 s after core load when no disc was auto-mounted, so a bare launch
// lands in the file picker instead of a black screen -- the console-core
// convention (NES/SNES/Genesis all raise the virtual OSD button).
//
// Mechanics: BUTTONS[0] is the core->HPS virtual OSD button (sys_top.v ORs
// it into gp_in; menu.cpp synthesises KEY_F12|UPSTROKE on its RELEASE edge).
// ⚠ Because the RELEASE is what fires, the console-core "hold ~did-load for
// the whole window" idiom would pop the OSD even for an auto-mounted disc
// whose mount lands mid-window (an MGL <file> mount arrives seconds after
// load, unlike boot.rom/SC mounts which complete before status[0] falls).
// So this is a WAIT-THEN-PULSE instead: arm on the falling edge of
// status[0] (the framework's core-load reset, released at the END of
// user_io_init -- after every init-time auto-load), wait ~0.9 s watching
// for a mount, and only then emit a 100 ms pulse. Any mount cancels it.
// Must stay well under 3 s: a >=3 s hold means "enter Bluetooth pairing".
//
// One-shot per FPGA configuration (the counter saturates and nothing resets
// it, so OSD-menu Reset can't re-fire it), and disc_ever has no reset term
// (power-up init only) so a played-then-reset session never pops it either.
localparam [24:0] OSD_T_FIRE = 25'd24_300_000;   // ~0.90 s @ 27 MHz
localparam [24:0] OSD_T_END  = 25'd27_000_000;   // ~1.00 s (100 ms pulse)

reg        osd_btn      = 1'b0;
reg        hps_rst_seen = 1'b0;   // status[0] observed high since power-up
reg        disc_ever    = 1'b0;   // any nonzero-size mount since power-up
reg [24:0] osd_wait     = 25'd0;

always @(posedge clk_sys) begin
    if (img_mounted[0] && img_size != 64'd0) disc_ever <= 1'b1;
    if (status[0])                           hps_rst_seen <= 1'b1;
    if (hps_rst_seen && !status[0] && osd_wait != OSD_T_END)
        osd_wait <= osd_wait + 25'd1;
    osd_btn <= (osd_wait >= OSD_T_FIRE) && (osd_wait != OSD_T_END) && !disc_ever;
end

assign BUTTONS = {1'b0, osd_btn};

// =========================================================================
// GAMEPAD TRANSPORT (2026-07-06): pause + cell-granular seek, driven by the
// gamepad (joystick_0 was wired to hps_io but previously unused). joystick_0 is
// a HELD level, so each control is rising-edge detected. Buttons match the J1
// CONF_STR list (B1=Pause[4], B2=Prev Chapter[5], B3=Next Chapter[6]); the D-pad
// Left[1]/Right[0] also seek prev/next:
//   B1 Pause [4]         -> pause toggle
//   B3 [6] / Right [0]   -> next cell (seek_cell = cur_cell + 1)
//   B2 [5] / Left  [1]   -> prev cell (seek_cell = cur_cell - 1)
// The reader ignores a seek unless it is in cell-mode (cell_ready) and the
// target cell is in range, and pulses seek_ack when it actually jumps -- that
// ack is what fires the pipeline flush below (so an out-of-range press, e.g.
// "next" at the last cell, causes no glitch). See docs/dvd_nav.md "Transport".
wire [7:0] cur_cell;         // from dvd_iso_reader
wire       cell_ready;       // from dvd_iso_reader (cell-mode active)
// Linear transport (VCD/SVCD raw .bin, flat .mpg/.VOB): the reader seeks the
// whole file by RBN — raw mode snaps to a CD sector (= MPEG pack) boundary,
// flat mode is qualified by ps_demux having seen a pack (ps_saw_pack) and
// re-syncs via the reader's post-seek pack hunt. Raw ES (.m2v) stays
// linear-only. These open the same scrub/seek-bar/pause UI as a DVD title.
wire        raw_mode_w;      // from dvd_iso_reader (raw MODE2/2352 image)
wire        lin_seek_ok_w;   // from dvd_iso_reader (linear seek available)
wire [31:0] lin_blk_w;       // from dvd_iso_reader (linear playhead block)
wire       seek_ack;         // from dvd_iso_reader (seek accepted this cycle)

// Disc-menu proto-nav read-backs / request lines (Phase 2)
wire       jump_ack;         // from dvd_iso_reader (jump executing this cycle)
wire       keep_vbuf;        // level (valid at seek_ack/jump_ack): menu->menu
                             // transition -> hold the decoder VBUF (no vbuf_flush)
wire       pgc_loaded;       // pulse: jump target parsed + streaming
wire       pgc_error;        // pulse: a MENU jump failed -> run the fallback chain
wire       menu_active;      // level: a menu-domain PGC is loaded
wire       still_active;     // level: reader holds a menu still (watchdog-suppress)
wire [7:0] cur_vts;          // VTS of the playing title (resume target)
wire [7:0] best_menu_vts;    // VTS with the largest menu VOB (fallback root menu)
wire [15:0] cur_pgcn_rd;     // PGCN of the loaded PGC (16-bit: 15-bit DVD field)

reg [31:0] joy_prev;
reg        pause_q;
reg        seek_pulse;
reg  [7:0] seek_cell;
// Phase 8 transport: chapter skip is resolved IN THE READER (its program_map
// BRAM + cell table, full 99-chapter, no self-correcting lag), so emu just
// pulses chap_pulse/chap_dir. Time scrub reads the DSI fwda/bwda table
// (nav_dsi) and issues a raw-RBN seek.
reg        chap_pulse;               // pulse: chapter skip -> reader
reg        chap_dir;                 // 1 = next chapter, 0 = previous
reg  [4:0] chap_mag;                 // # chapters to skip this burst (>=1) -> reader
// Chapter-skip DEBOUNCE: repeated B2/B3 presses inside a short window accumulate
// into a signed net count instead of each firing an immediate seek (which made the
// video visibly scrub through every intermediate scene). When the window elapses
// with no further press, ONE chap_pulse fires carrying the net direction/magnitude,
// so a rapid multi-press jumps straight to the destination chapter.
reg  signed [5:0] chap_net;          // pending net chapters (+next / -prev), saturating
reg  [23:0] chap_timer;              // debounce countdown (clk_sys ticks; 0 = idle)
localparam [23:0] CHAP_DEBOUNCE = 24'd13_500_000;  // ~500 ms @ 27 MHz clk_sys
// |chap_net| as an unsigned magnitude (part-select of an expression isn't legal).
wire [5:0] chap_net_abs = chap_net[5] ? (6'd0 - chap_net) : chap_net;
wire       chap_at_start;            // 1 = <~5 s into the current chapter (from DSI
                                     // c_eltm) -> prev steps back; else prev restarts
                                     // the current chapter. Assigned near nav_dsi below.
wire       seek_rbn_pulse;           // pulse: time scrub -> reader (from scrub_ctrl)
wire [31:0] seek_rbn;                // target RBN (2048-sector, VTSTT_VOBS-rel)
reg        angle_pulse;              // pulse: cycle camera angle (Phase 9) -> reader
wire [3:0] cur_angle;                // from reader: current camera angle (1-based)
wire [3:0] angle_count;              // from reader: angles in the current block (0=none)

// Phase-4: navigation (jumps, resume, fallback, button commands) moved into
// dvd_vm.sv - the Phase-2/3 proto-nav / micro-bridge glue that lived here is
// GONE. emu keeps only the gamepad decode (transport + key pulses) and muxes
// the VM's seek requests with the title transport's.
wire        vm_jump_pulse;
wire [1:0]  vm_jump_domain;
wire [7:0]  vm_jump_vts, vm_jump_cell, vm_jump_pgn;
wire [15:0] vm_jump_pgcn;    // 15-bit DVD PGCN field
wire [3:0]  vm_jump_entry;
wire [6:0]  vm_jump_ttn;
wire [9:0]  vm_jump_ptt;      // Phase 6: exact chapter/PTT part (JumpVTS_PTT)
wire        vm_seek_pulse;
wire [7:0]  vm_seek_cell;
wire        vm_replay_w, vm_adv_w;
wire        vm_cell_cmd_w, vm_pgc_end_w;
// Tail-drain Phase B: natural-jump provenance (VM -> reader) and the gated-
// wait level (reader -> VM). vm_from_wait_w is 1 while the VM's executing
// block is CELL/POST, so a jump/seek pulsed on that cycle came from a natural
// transition and the reader gates it on vbuf_empty; nat_wait_w freezes the
// VM's V_WAIT give-up timer across that gate window.
wire        vm_from_wait_w;
wire        nat_wait_w;
wire        nav_ready_w;
wire [7:0]  auto_vts_w, cell_count_w;
wire [6:0]  res_ttn_w;
wire [15:0] rd_next_pgcn, rd_prev_pgcn, rd_goup_pgcn;
wire [7:0]  cur_cell_cmdnr_w;
wire        menu_ar_wide_w;      // 1 = loaded menu is 16:9 (IFO V_ATR, not seq hdr)
wire        vm_cmd_we;
wire [11:0] vm_cmd_waddr;
wire [7:0]  vm_cmd_wdata;
wire [7:0]  vm_nr_pre, vm_nr_post, vm_nr_cell, vm_nr_pgm;
wire [7:0]  cur_pgm_w;                // Phase 11 HUD: current chapter (1-based, 0=unresolved)
wire [10:0] nr_ptt_w;                 // Phase 6: exact chapter total (nr_of_ptts, 0 = none)
// HUD "CH n/N" total: prefer the exact PTT count; fall back to nr_of_programs
// when there is no PTT table (on single-PGC movie titles the two are equal).
// The HUD renders it through bin2bcd99, so a >99 (game-disc) count clamps.
// (HUD display field is 8-bit: a >255-chapter game title shows CH n/255 --
//  cosmetic display clamp only; the reader's table now holds 1024, Phase 5)
// Cross-PGC (Phase-5 follow-up): cur_pgm_w is the GLOBAL PTT index whenever a
// PTT table is resident (reader CH_G reverse map), so "CH n" and this total
// agree on multi-PGC titles; it too display-clamps at 255 in the reader.
wire [7:0]  hud_nr_ch = (nr_ptt_w != 11'd0)
                        ? (nr_ptt_w > 11'd255 ? 8'd255 : nr_ptt_w[7:0])
                        : vm_nr_pgm;
// PROJECTED chapter target for the OSD during a debounced multi-press. The seek
// doesn't fire until the ~500 ms window closes, so cur_pgm_w (the current chapter)
// wouldn't move while the user is still tapping -- they can't see which chapter
// they're selecting. This mirrors the reader's CH_R resolve in 1-based chapter
// space so the HUD "CH n/N" field counts up/down LIVE on each press:
//   next:  cur + |net|                    (clamped to N)
//   prev:  cur - dec, dec = past_start ? |net|-1 : |net|   (clamped to 1)
// past_start ~ !chap_at_start (>~5 s into the chapter -> first prev restarts it,
// matching the reader; the reader's extra cell_i>best_cell test can't be seen from
// emu, but the c_eltm gate dominates on real discs -> the preview tracks the seek).
wire        chap_past_start = ~chap_at_start;
wire [5:0]  chap_prev_dec   = (chap_past_start && chap_net_abs != 6'd0)
                              ? (chap_net_abs - 6'd1) : chap_net_abs;
wire signed [9:0] chap_proj_raw = (chap_net > 6'sd0)
        ?  ($signed({2'b0, cur_pgm_w}) + $signed({4'b0, chap_net_abs}))
        :  ($signed({2'b0, cur_pgm_w}) - $signed({4'b0, chap_prev_dec}));
wire [7:0]  chap_proj_clamp = (chap_proj_raw < 10'sd1)                       ? 8'd1
                            : (chap_proj_raw > $signed({2'b0, hud_nr_ch})) ? hud_nr_ch
                            : chap_proj_raw[7:0];
// Registered display value: track the projection LIVE while a burst debounces, then
// HOLD the final target through the seek settle (until cur_pgm_w catches up, or a
// ~1 s safety timeout) so the number never flickers back to the old chapter between
// the burst firing and the reader resolving cur_pgm. Idle -> the real chapter.
reg  [7:0]  chap_disp_hold;
reg         chap_disp_act;
reg  [24:0] chap_disp_tmr;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        chap_disp_hold <= 8'd0;
        chap_disp_act  <= 1'b0;
        chap_disp_tmr  <= 25'd0;
    end else if (start_streaming) begin
        chap_disp_act  <= 1'b0;                       // fresh load clears the hold
    end else if (chap_timer != 24'd0 && chap_net != 6'sd0 && cur_pgm_w != 8'd0) begin
        chap_disp_hold <= chap_proj_clamp;            // live preview during debounce
        chap_disp_act  <= 1'b1;
        chap_disp_tmr  <= 25'd27_000_000;             // ~1 s @ 27 MHz settle timeout
    end else if (chap_disp_act) begin
        // burst fired (or cancelled): hold the target until the reader lands on it
        if (cur_pgm_w == chap_disp_hold || chap_disp_tmr == 25'd0) chap_disp_act <= 1'b0;
        else chap_disp_tmr <= chap_disp_tmr - 25'd1;
    end
end
wire [7:0]  hud_cur_ch = chap_disp_act ? chap_disp_hold : cur_pgm_w;
wire [31:0] cur_cell_start_w;         // Phase 11 HUD: BCD start time of the playing cell
wire        cellf_we_w;               // Phase 11 bar: cell first_sector stream tap
wire [6:0]  cellf_idx_w;
wire [31:0] cellf_rbn_w;
wire        vm_pm_we;
wire [6:0]  vm_pm_waddr;
wire [7:0]  vm_pm_wdata;
wire        vm_btn_force;
wire [5:0]  vm_btn_force_val;
wire [7:0]  vm_astn, vm_spstn;
// DVD-FORK DEBUG (Atmosfear wrong-title diagnosis): taps used by the
// DEBUG_OVERLAY rows 21..26. Declared unconditionally (the module ports are
// always connected); the latch logic + overlay feed are under `DEBUG_OVERLAY.
wire [7:0]  vm_dbg_state;
wire [15:0] vm_dbg_g3, vm_dbg_g14_9;
wire [15:0] vm_dbg_rsm;      // {rsm_vts, rsm_pgcn} for the DEBUG_OVERLAY (symptom-1)
wire [15:0] vm_dbg_deadend;  // {deadend_vts, deadend_pgcn} = the PGC that dead-ended
wire        vm_link_fail;      // pulse: menu link failed -> re-entered menu (HUD popup)
wire [7:0]  vm_link_fail_pgcn; // the PGCN that failed to resolve (HUD digits)
wire [7:0]  rdr_play_vtsn, rdr_target_vtsn;
reg         key_menu_p, key_resume_p, key_title_p, key_return_p;

wire menus_on  = ~status[1];                       // O[1] Disc Menus (index 0 = On, default)
wire hud_dbg   = status[2];                         // O[2]: HUD shows reader PGCN/VTS (nav diagnostic)
wire dpad_seek_en = status[45];                     // O[45]: D-pad fixed-time seek
// effective subpicture routing/decode enable: subtitles OR a menu is up
wire sp_route_en;                                  // (assigned at the SPU block)
wire joy_pause = joystick_0[4];                    // B1 "Pause"
wire joy_next  = joystick_0[6];                    // B3 "Next Chapter"
wire joy_prevc = joystick_0[5];                    // B2 "Prev Chapter"
wire joy_sel   = joystick_0[7];                    // B4 "Select"
wire joy_menu  = joystick_0[8];                    // B5 "Menu"
wire joy_angle = joystick_0[9];                    // B6 "Angle"
wire joy_audio = joystick_0[10];                   // B7 "Audio"     (Phase 10)
wire joy_sub   = joystick_0[11];                   // B8 "Subtitle"  (Phase 10)
wire joy_disp  = joystick_0[12];                   // B9 "Display"   (Phase 11 HUD)
// Dedicated seek buttons: the HOLD-to-seek time scrub lives on its OWN buttons
// (B10 Fast Fwd = seek forward, B11 Rewind = seek backward) so the D-pad is
// never claimed by the scrub. This keeps left/right free for directional menu /
// game navigation even when the underlying video is seekable (the conflict this
// split resolves). scrub_ctrl reads the HELD levels; ff_edge/rew_edge below only
// clear pause when a scrub begins.
wire joy_ff    = joystick_0[13];                   // B10 "Fast Fwd" (held scrub fwd)
wire joy_rew   = joystick_0[14];                   // B11 "Rewind"   (held scrub bwd)
wire joy_title = joystick_0[15];                   // B12 "Title"    (VMGM Top Menu)
wire joy_ret   = joystick_0[16];                   // B13 "Return"   (GoUp)
wire pause_edge = joy_pause & ~joy_prev[4];
// Phase 8: B2/B3 = CHAPTER prev/next (program_map); B10/B11 (Fast Fwd/Rewind) =
// HOLD-to-seek TIME SCRUB (dvd/scrub_ctrl.sv, accelerating 10->30->60->120 s the
// longer held). B2/B3 previously aliased the D-pad and did cell+/-1; the scrub
// previously rode the D-pad L/R but moved to its own buttons so the D-pad stays
// directional nav (no conflict with game left/right input over seekable video).
wire chnext_edge = joy_next  & ~joy_prev[6];
wire chprev_edge = joy_prevc & ~joy_prev[5];
wire sel_edge   = joy_sel   & ~joy_prev[7];

// HUD status-line auto-show trigger: USER transport interactions ONLY (pause,
// chapter skip, time scrub). Deliberately EXCLUDES the reader's seek_ack, which
// also pulses on VM-driven jumps/resumes (a menu Play, a CallSS/RSM featurette
// enter/return, a menu next_pgcn advance) - those are "clip starts", not user
// actions, and should not pop the HUD. (Audio/subtitle/angle cycles drive the
// popup line separately.) seek_rbn_pulse is the scrub-release seek (user).
// dpad_pend_evt pops the HUD on the FIRST D-pad press rather than ~0.4 s later
// when the coalesced jump actually fires, so the seconds readout tracks the taps.
wire hud_user_evt = pause_edge
                  | ((chnext_edge | chprev_edge) && cell_ready && !menu_active)
                  | seek_rbn_pulse
                  | dpad_pend_evt;
wire menu_edge  = joy_menu  & ~joy_prev[8];
wire angle_edge = joy_angle & ~joy_prev[9];
wire audio_edge = joy_audio & ~joy_prev[10];       // Phase 10: cycle audio track
wire sub_edge   = joy_sub   & ~joy_prev[11];       // Phase 10: cycle subtitle track
wire display_edge = joy_disp & ~joy_prev[12];      // Phase 11: toggle status line
wire ff_edge    = joy_ff  & ~joy_prev[13];         // Fast Fwd press (scrub start)
wire rew_edge   = joy_rew & ~joy_prev[14];         // Rewind press  (scrub start)
wire title_edge = joy_title & ~joy_prev[15];       // Title press   (Top Menu)
wire ret_edge   = joy_ret   & ~joy_prev[16];       // Return press  (GoUp)
// D-pad edges (bits 3:0 = up/down/left/right): BUTTON NAV in a menu / in-title
// HLI with armed buttons (Phase 3). The HOLD-to-seek scrub is on the dedicated
// Fast Fwd/Rewind buttons, so the D-pad never fights game direction input.
// With O[45] "D-Pad Seek" On (default Off), the same edges ALSO feed
// dvd/dpad_seek.sv for VLC-style fixed-time jumps -- but only where the nav
// layer has NOT claimed them (see the menu_nav / in_title_menu gates below),
// so the no-conflict property above is preserved by construction.
wire up_edge    = joystick_0[3] & ~joy_prev[3];
wire dn_edge    = joystick_0[2] & ~joy_prev[2];
wire lf_edge    = joystick_0[1] & ~joy_prev[1];
wire rt_edge    = joystick_0[0] & ~joy_prev[0];

// nav_pci interface (Phase 3)
wire        hl_btns_armed;
wire [15:0] rd_dbg_pgcerr;    // reader pgc_error reason latch (overlay row 26)
// STC display-coherence latch for nav_pci's scheduled promotion path: 1 when the
// most recent load/seek/jump FLUSHED the decoder (keep_vbuf=0 — STC anchor and
// display reset together). A keep_vbuf menu->menu hop clears it (the re-anchored
// STC leads the still-playing display); nav_pci then requires a still park before
// trusting scheduled crossings. keep_vbuf is registered by the reader in the same
// cycle as the ack (the seek_flush_now precedent).
reg hl_stc_fresh = 1'b1;
always @(posedge clk_sys) begin
    if (seek_ack || jump_ack) hl_stc_fresh <= ~keep_vbuf;
end
wire [63:0] hl_btn_cmd;
wire        hl_btn_cmd_valid;
wire [5:0]  hl_btn_sel;
wire [5:0]  hl_btn_ns;              // # buttons in the committed HLI (nav_pci)
wire        hl_menu_seen;           // EARLY: a multi-button in-title menu HLI parsed (pre-promote)
reg         nav_up_p, nav_dn_p, nav_lf_p, nav_rt_p, nav_act_p;
wire        menu_nav = menus_on && menu_active && hl_btns_armed;

// IN-TITLE PCI/HLI BUTTON (e.g. Matrix "Follow the White Rabbit" icon): nav_pci
// arms an HLI while a TITLE plays (not a disc menu). The button-graphic
// subpicture must then be routed + decoded + highlight-recoloured just like a
// menu button, so the subpicture plumbing (sp_route_en / sp_track_eff /
// menu_mode) is un-gated on this signal too. menus_on is required (the nav layer
// / PCI forwarding is O[1]-gated) and menu_active must be OFF (this is the title,
// not a menu). hl_btns_armed only asserts on VOBUs that actually carry HLI, so
// normal titles (no in-title button) are unaffected.
wire        in_title_hli = menus_on && !menu_active && hl_btns_armed;

// IN-TITLE MULTI-BUTTON MENU (DVD-game discs, e.g. Scene It). Unlike the white
// rabbit (a lone auto-selected button riding a movie), these are full menus
// authored in the TITLE domain: the main game menu (VTS3 Title6/PGCN18, 6 btns),
// ring-select / timer / yes-no / submenus - all in-title HLI with MULTIPLE
// buttons + a u/d/l/r link graph, dispatched by SetGPRM+LinkTailPGC in POST.
// (Decoded with tools/bin/trace_nav; see the scene-it-in-title-hli-menus note.)
// btn_ns > 1 distinguishes a game MENU (walk the buttons with the D-pad, Select
// activates) from the single-button white rabbit (D-pad stays seek-scrub). This
// gates: (a) feeding the D-pad into nav_pci below, and (b) suppressing the
// scrub/chapter/pause transport so left/right walks buttons instead of seeking.
wire        in_title_menu = in_title_hli && (hl_btn_ns > 6'd1);

// EARLY gate for the in-title menu's highlight SUBPICTURE. The subpicture (on
// substream 0x20) arrives a few sectors AFTER the NAV pack in the SAME VOBU, but
// `in_title_menu` above only asserts once nav_pci PROMOTES the HLI (STC / ~1 s
// video-live fallback) — long after that subpicture has already streamed past
// ps_demux, so it would be discarded and the highlight never renders. `hl_menu_seen`
// asserts the moment the PCI is parsed (pre-promote), so the subpicture gate opens
// in time. Menu-domain menus don't need this (their gate follows menu_active); the
// white rabbit doesn't either (its SetSTN opens the gate in the PGC pre-command).
wire        sp_menu_early = menus_on && !menu_active && hl_menu_seen;

// ---- gamepad decode (Phase 4: keys go to the DVD-VM; only the title
// transport and the Phase-3 button-nav pulses stay here) -------------------
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        joy_prev     <= 32'd0;
        pause_q      <= 1'b0;
        seek_pulse   <= 1'b0;
        seek_cell    <= 8'd0;
        chap_pulse   <= 1'b0;
        chap_dir     <= 1'b0;
        chap_mag     <= 5'd1;
        chap_net     <= 6'sd0;
        chap_timer   <= 24'd0;
        angle_pulse  <= 1'b0;
        nav_up_p     <= 1'b0;
        nav_dn_p     <= 1'b0;
        nav_lf_p     <= 1'b0;
        nav_rt_p     <= 1'b0;
        nav_act_p    <= 1'b0;
        key_menu_p   <= 1'b0;
        key_resume_p <= 1'b0;
        key_title_p  <= 1'b0;
        key_return_p <= 1'b0;
    end else begin
        joy_prev     <= joystick_0;
        seek_pulse   <= 1'b0;             // default: one-cycle pulses
        chap_pulse   <= 1'b0;
        angle_pulse  <= 1'b0;
        nav_up_p     <= 1'b0;
        nav_dn_p     <= 1'b0;
        nav_lf_p     <= 1'b0;
        nav_rt_p     <= 1'b0;
        nav_act_p    <= 1'b0;
        key_menu_p   <= 1'b0;
        key_resume_p <= 1'b0;
        key_title_p  <= 1'b0;
        key_return_p <= 1'b0;

        if (start_streaming)      pause_q <= 1'b0;   // fresh load clears pause
        else if (pause_edge)      pause_q <= ~pause_q;
        // a title-mode Fast Fwd/Rewind time scrub resumes playback (the scrub FSM
        // below issues the actual seek_rbn)
        else if ((cell_ready || lin_seek_ok_w) && !menu_active && !in_title_menu && (ff_edge || rew_edge)) pause_q <= 1'b0;
        // a D-pad fixed-time seek likewise resumes playback (dvd/dpad_seek.sv
        // issues the jump when the coalesce window closes)
        else if (dpad_seek_en && (cell_ready || lin_seek_ok_w) && !menu_active &&
                 !in_title_menu && !menu_nav &&
                 (up_edge || dn_edge || lf_edge || rt_edge)) pause_q <= 1'b0;
        // any VM jump / menu key resumes playback (a paused governor would
        // freeze the menu the VM is jumping to)
        if (jump_ack)             pause_q <= 1'b0;

        // BUTTON NAV (Phase 3): with a menu up and an armed HLI, the D-pad
        // walks the disc's button link graph and Select activates (the
        // activated command now EXECUTES in dvd_vm - no micro-bridge). This
        // covers both a menu-domain menu (menu_nav) and an IN-TITLE multi-button
        // game menu (in_title_menu, e.g. Scene It's Title6/ring-select screens),
        // which are identical from the nav layer's view - the only difference is
        // the domain the walk happens in.
        if (menu_nav || in_title_menu) begin
            nav_up_p  <= up_edge;
            nav_dn_p  <= dn_edge;
            nav_lf_p  <= lf_edge;
            nav_rt_p  <= rt_edge;
            nav_act_p <= sel_edge;
        end

        // IN-TITLE SINGLE BUTTON activation (white rabbit): while a TITLE plays
        // with a LONE armed in-title HLI, Select activates the (forced-selected,
        // fosl=1) button. The D-pad is NOT hijacked here - it stays chapter-skip /
        // time-scrub in a title; the rabbit is a single auto-selected button, so
        // only activation is needed. (Multi-button in-title menus take the D-pad
        // walk above instead.) nav_pci -> hl_btn_cmd -> dvd_vm runs the commands.
        else if (in_title_hli && sel_edge)
            nav_act_p <= 1'b1;

        // Menu key -> the VM (CallSS VTSM Root from a title / LinkRSM from a
        // menu). Select with NO buttons armed = resume (Phase-2 behaviour) -
        // but the VM only honours it if the menu was entered via the Menu key
        // (came_via_menukey); in a DISC-driven menu chain (e.g. Cluedo's boot
        // copyright/logos/intro, which arm no buttons) Select is a no-op, like
        // a real player's Enter. See the ev_resume gate in dvd_vm.sv.
        if (menus_on && menu_edge)
            key_menu_p <= 1'b1;
        if (menus_on && menu_active && sel_edge && !hl_btns_armed)
            key_resume_p <= 1'b1;
        // B12 Title = the real-remote "Top Menu" key -> VMGM Title menu.
        if (menus_on && title_edge)
            key_title_p <= 1'b1;
        // B13 Return = GoUp (the loaded PGC's authored goup_pgcn; no-op
        // without one - the VM does the check).
        if (menus_on && ret_edge)
            key_return_p <= 1'b1;

        // CHAPTER skip (TITLE only, B2/B3 - in a menu the D-pad walks buttons):
        // the reader resolves program_map -> entry cell -> cell-seek in fabric and
        // no-ops at the ends. Presses are DEBOUNCED: each B2/B3 edge adjusts a signed
        // net accumulator (+next / -prev, saturating) and (re)arms a ~500 ms timer;
        // only when the window elapses with no further press does emu fire ONE
        // chap_pulse carrying the net direction + magnitude. This lets a rapid
        // multi-press seek straight to the destination chapter instead of scrubbing
        // through each one. (D-pad L/R = time scrub, handled by the scrub FSM below.)
        if (start_streaming) begin
            chap_net   <= 6'sd0;
            chap_timer <= 24'd0;
        end else if (cell_ready && !menu_active && !in_title_menu &&
                     (chnext_edge || chprev_edge)) begin
            // register the press (next wins if both edges land the same cycle) and
            // (re)start the debounce window.
            if (chnext_edge) begin
                if (chap_net < 6'sd31) chap_net <= chap_net + 6'sd1;
            end else begin
                if (chap_net > -6'sd31) chap_net <= chap_net - 6'sd1;
            end
            chap_timer <= CHAP_DEBOUNCE;
            pause_q    <= 1'b0;                       // chapter skip resumes playback
        end else if (chap_timer != 24'd0) begin
            chap_timer <= chap_timer - 24'd1;
            if (chap_timer == 24'd1 && chap_net != 6'sd0) begin
                // window closed with a pending move -> fire the burst.
                chap_pulse <= 1'b1;
                chap_dir   <= (chap_net > 6'sd0);
                chap_mag   <= chap_net_abs[4:0];
                chap_net   <= 6'sd0;
                pause_q    <= 1'b0;
            end else if (chap_timer == 24'd1) begin
                chap_net   <= 6'sd0;                  // net cancelled out (equal +/-)
            end
        end

        // ANGLE cycle (Phase 9, TITLE only - B6): the reader advances cur_angle
        // 1..angle_count and switches at the next ILVU boundary (seamless, no
        // flush). A no-op outside a multi-angle block (angle_count < 2).
        if (cell_ready && !menu_active && !in_title_menu && angle_edge)
            angle_pulse <= 1'b1;
    end
end

// =========================================================================
// NUMPAD MENU INPUT (2026-07-27): keyboard number keys select+activate a menu
// button by number - the DVD-remote "digit" shortcut. ps2_key = {toggle, pressed,
// extended, scancode[7:0]} (MiSTer framework, clk_sys domain; bit 10 toggles on
// every new key event). With a menu HLI armed, a digit PRESS forces nav_pci's
// selection to that button AND activates it (num_sel/num_btn -> auto_pend), so
// chapter menus and hidden auto-action easter-egg buttons (e.g. T2 82997) work
// with one keypress each. Both the numeric keypad and the top-row digits are
// accepted (PS/2 set 2, non-extended). 0 -> button 10 (DVD remote convention).
// See docs/dvd_nav.md "Numpad input" and roadmap "numeric button entry".
// =========================================================================
reg        num_sel_p;
reg  [5:0] num_btn_r;
reg        ps2_tgl_p;

// scancode -> digit 0..9 (ps2_dv=valid). Non-extended keys only (ps2_key[8]==0):
// numpad Enter / '/' are E0-extended and won't false-match here.
reg  [3:0] ps2_digit;
reg        ps2_dv;
always @(*) begin
    ps2_digit = 4'd0;
    ps2_dv    = 1'b0;
    if (!ps2_key[8]) begin
        case (ps2_key[7:0])
        // top-row number keys
        8'h45: begin ps2_digit = 4'd0; ps2_dv = 1'b1; end
        8'h16: begin ps2_digit = 4'd1; ps2_dv = 1'b1; end
        8'h1E: begin ps2_digit = 4'd2; ps2_dv = 1'b1; end
        8'h26: begin ps2_digit = 4'd3; ps2_dv = 1'b1; end
        8'h25: begin ps2_digit = 4'd4; ps2_dv = 1'b1; end
        8'h2E: begin ps2_digit = 4'd5; ps2_dv = 1'b1; end
        8'h36: begin ps2_digit = 4'd6; ps2_dv = 1'b1; end
        8'h3D: begin ps2_digit = 4'd7; ps2_dv = 1'b1; end
        8'h3E: begin ps2_digit = 4'd8; ps2_dv = 1'b1; end
        8'h46: begin ps2_digit = 4'd9; ps2_dv = 1'b1; end
        // numeric keypad
        8'h70: begin ps2_digit = 4'd0; ps2_dv = 1'b1; end
        8'h69: begin ps2_digit = 4'd1; ps2_dv = 1'b1; end
        8'h72: begin ps2_digit = 4'd2; ps2_dv = 1'b1; end
        8'h7A: begin ps2_digit = 4'd3; ps2_dv = 1'b1; end
        8'h6B: begin ps2_digit = 4'd4; ps2_dv = 1'b1; end
        8'h73: begin ps2_digit = 4'd5; ps2_dv = 1'b1; end
        8'h74: begin ps2_digit = 4'd6; ps2_dv = 1'b1; end
        8'h6C: begin ps2_digit = 4'd7; ps2_dv = 1'b1; end
        8'h75: begin ps2_digit = 4'd8; ps2_dv = 1'b1; end
        8'h7D: begin ps2_digit = 4'd9; ps2_dv = 1'b1; end
        default: ;
        endcase
    end
end

// Numpad entry is live only when a menu HLI is armed (menu-domain menu OR in-title
// HLI menu - both set hl_btns_armed). Out-of-range button numbers are dropped by
// nav_pci, so no menu-side range gate is needed here.
wire num_input_en = menus_on && hl_btns_armed;

always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ps2_tgl_p <= 1'b0;
        num_sel_p <= 1'b0;
        num_btn_r <= 6'd0;
    end else begin
        num_sel_p <= 1'b0;                    // default: one-cycle pulse
        ps2_tgl_p <= ps2_key[10];
        // new key event (toggle flipped) + key PRESSED + a digit + a menu armed
        if ((ps2_key[10] ^ ps2_tgl_p) && ps2_key[9] && ps2_dv && num_input_en) begin
            num_sel_p <= 1'b1;
            num_btn_r <= (ps2_digit == 4'd0) ? 6'd10 : {2'd0, ps2_digit};
        end
    end
end

// =========================================================================
// Phase 8a - HOLD-to-seek, SEEK-ON-RELEASE with a position indicator (scrub_ctrl)
// =========================================================================
// Fast Fwd/Rewind (dedicated buttons B10/B11) in a playing title = HOLD to choose
// a seek target, release to jump. Seeking is deliberately OFF the D-pad so left/
// right stay pure navigation and never fight a game expecting directional input.
// While held the video simply PAUSES (a plain, proven freeze via hold_freeze
// -> pause_gov/pause_aud) and an internal target offset ACCELERATES the longer
// it's held (sector step grows by tier). On release, scrub_ctrl issues ONE raw-RBN
// seek (the known-good single-seek path).
// ★ Why not a live still-scan: HW rounds 1-2 proved the decoder (built for
// continuous playback, ~1-2 MB VBUF + watchdog) can't cleanly flush+re-lock+show
// a still fast enough -- it went mostly black, played in the gaps, and the
// un-frozen re-lock window tripped the watchdog (720x179 resync). Seek-on-release
// does exactly ONE flush/re-lock, on release, so it's robust.
// The `bar_*` outputs (playhead + target position) feed a Phase-11 on-screen
// position bar (deferred, not built yet) so the user can see where they're going;
// the seek action itself needs no overlay. Chapter B2/B3 and menu D-pad nav are
// handled elsewhere; scrub_ctrl only runs while `in_title`.
// nav_dsi fwda/bwda seek-table read port. Driven by dvd/dpad_seek.sv (O[45]).
// ⚠ This port was tied to 0 until 2026-08-27, which let Quartus dead-strip the
// whole dsi_tbl RAM and its byte-walker write branches (the fit report showed
// nav_dsi at 16 ALMs / 0 memory bits). Wiring it up RESURRECTS that logic --
// expect nav_dsi to grow by ~1 M10K and ~100 ALMs, and check the map report.
wire [5:0]  dsi_tbl_raddr;
wire [31:0] dsi_tbl_rdata;

// Seek-on-release: holding D-pad L/R pauses the video and accumulates an
// accelerating target offset; releasing issues ONE raw-RBN seek. hold_freeze
// pauses while held. Title RBN span comes from the reader. The bar_* outputs
// (playhead + target position) are computed for the Phase-11 on-screen position
// bar and left UNWIRED for now (the seek action itself needs no overlay).
wire        hold_freeze;
wire        dpad_pend, dpad_pend_dir, dpad_pend_evt, dpad_pend_fail;
wire [1:0]  dpad_pend_n;
wire [6:0]  dpad_pend_min;
wire [2:0]  dpad_pend_sec;
wire        dpad_jump_fire, dpad_jump_dir;
wire [31:0] dpad_jump_base, dpad_jump_off;
wire        bar_active_w;                          // Phase 11: seek-bar visible
wire [31:0] bar_base_rbn_w, bar_tgt_rbn_w;         // Phase 11: bar fill + cursor
wire [31:0] title_first_rbn_w, title_last_rbn_w;
wire [1:0]  hud_tier_w;                            // Phase 11: scrub speed tier
wire        hud_dir_w;                             // Phase 11: scrub direction
scrub_ctrl scrub_ctrl_inst (
    .clk             (clk_sys),
    .rst_n           (reset_n),
    .held_right      (joy_ff),                   // B10 Fast Fwd = seek forward
    .held_left       (joy_rew),                  // B11 Rewind   = seek backward
    .in_title        ((cell_ready || lin_seek_ok_w) && !menu_active && !in_title_menu),  // title OR linear (VCD/SVCD/.mpg) playback
    .cur_rbn         (cell_ready ? dsi_nv_pck_lbn : lin_blk_w),
    .title_first_rbn (title_first_rbn_w),
    .title_last_rbn  (title_last_rbn_w),
    .seek_rbn_pulse  (seek_rbn_pulse),
    .seek_rbn        (seek_rbn),
    .hold_freeze     (hold_freeze),
    .bar_active      (bar_active_w),
    .bar_base_rbn    (bar_base_rbn_w),
    .bar_tgt_rbn     (bar_tgt_rbn_w),
    .hud_tier        (hud_tier_w),
    .hud_dir         (hud_dir_w),
    // ---- O[45] D-Pad Seek: pre-resolved fixed-time jumps ----------------
    .jump_fire       (dpad_jump_fire),
    .jump_dir        (dpad_jump_dir),
    .jump_base       (dpad_jump_base),
    .jump_off        (dpad_jump_off)
);

// =========================================================================
// D-PAD FIXED-TIME SEEK (O[45], default Off) - dvd/dpad_seek.sv
// =========================================================================
// Left/Right = -/+10 s, Down/Up = -/+60 s, resolved from the disc's authored
// DSI fwda/bwda tables (or the exact CD geometry on a raw VCD/SVCD image) and
// handed to scrub_ctrl's jump port, which clamps and issues the ONE proven
// raw-RBN seek. The D-pad is taken ONLY where the nav layer has not claimed it:
// menu_nav and in_title_menu both suppress it, exactly like the transport above,
// so a disc menu or an in-title game menu always keeps its button walk.
// `cancel` guarantees no late surprise jump survives a context change.
dpad_seek dpad_seek_inst (
    .clk            (clk_sys),
    .rst_n          (reset_n),                  // NOT pipe_rst_n: the gesture
                                                // must survive its own seek
    .en             (dpad_seek_en),
    .in_title       ((cell_ready || lin_seek_ok_w) && !menu_active &&
                     !in_title_menu && !menu_nav),
    .dvd_mode       (cell_ready),               // DSI tables available
    .lin_mode       (lin_seek_ok_w && raw_mode_w && !cell_ready),  // raw CD geometry
    .up_edge        (up_edge),
    .dn_edge        (dn_edge),
    .lf_edge        (lf_edge),
    .rt_edge        (rt_edge),
    .cancel         (jump_ack | chap_pulse | start_streaming | hold_freeze),
    .nav_flush      (load_flush),               // nav_dsi's own reset condition
    .dsi_commit     (dsi_commit),
    .dsi_stream     (ps_dsi_valid),
    .dsi_nv_pck_lbn (dsi_nv_pck_lbn),
    .dsi_vobu_ea    (dsi_vobu_ea),
    .dsi_next_vobu  (dsi_next_vobu),
    .dsi_prev_vobu  (dsi_prev_vobu),
    .tbl_raddr      (dsi_tbl_raddr),
    .tbl_rdata      (dsi_tbl_rdata),
    .lin_blk        (lin_blk_w),
    .jump_fire      (dpad_jump_fire),
    .jump_dir       (dpad_jump_dir),
    .jump_base      (dpad_jump_base),
    .jump_off       (dpad_jump_off),
    .pend           (dpad_pend),
    .pend_dir       (dpad_pend_dir),
    .pend_n         (dpad_pend_n),
    .pend_min       (dpad_pend_min),
    .pend_sec       (dpad_pend_sec),
    .pend_evt       (dpad_pend_evt),
    .pend_fail      (dpad_pend_fail)
);
// While a seek gesture is held the video simply PAUSES (a plain, proven freeze --
// no repeated flushing) and audio holds; releasing does one seek. ORed into the
// manual-pause paths below (governor/STC + audio).
wire pause_gov = pause_q | hold_freeze;
wire pause_aud = pause_q | hold_freeze;

// =========================================================================
// DVD-VM (Phase 4): executes the disc's navigation commands. Owns all jumps
// (boot FP, menu keys, button commands, PGC pre/post/cell blocks, RSM,
// fallback chain) - see dvd/dvd_vm.sv + docs/dvd_vm.md. Reset by reset_n:
// GPRM/RSM state must SURVIVE seeks and jumps (the pgc-palette lesson);
// a fresh mount (start_streaming) runs vm_reset.
// =========================================================================
// ------------------------------------------------------------------------
// DVD-game entropy source. The only entropy on a real DVD player is wall-clock
// time (libdvdnav does srand(usec) + wall-clock GPRM counters). Scene It and
// other game discs harvest it to randomize question order; without it every
// playthrough is identical. A free-running clk_sys counter (session-lifetime,
// NOT reset by mount/seek/reset_n = a wall clock) provides: (1) rnd_seed - the
// counter latched by dvd_vm at mount; (2) sec_tick - a 1 Hz pulse that ticks
// counter-mode GPRMs; (3) entropy_stir - user-input timing folded into the rnd
// LFSR (so rnd varies per play even when the mount instant is similar).
// ★ FIRST-BOOT ENTROPY (2026-08-25). The counter below is sampled at the MOUNT
// instant, which is only entropy if that instant is user-timed. On the FIRST
// mount after a core load it need not be: MiSTer can mount an image from the
// core-launch path (and the whole boot chain to the disc's first `rnd` is
// machine-timed), so the sample - and every `rnd` derived from it - came out
// IDENTICAL on every first play. HW symptom (Weakest Link, user report): the
// same question every time from a cold core load, correctly randomised from the
// second disc load on (that mount IS user-timed). A real player has no such
// hole because it seeds from a WALL CLOCK - libdvdnav literally does
// srand(time.tv_usec) at init - so take the same source: hps_io hands us
// TIMESTAMP (seconds since the epoch), sent by Main at core load, before any
// mount. XORed into the seed it varies every core load even when the mount
// instant does not. Falls back to the counter alone if the framework never
// sends it (TIMESTAMP stays 0). See docs/dvd_vm.md "DVD-game entropy".
wire [32:0] hps_timestamp;
reg  [31:0] entropy_ctr = 32'd0;
reg  [24:0] sec_div     = 25'd0;
reg         sec_tick    = 1'b0;
always @(posedge clk_sys) begin
    entropy_ctr <= entropy_ctr + 32'd1;
    if (sec_div == 25'd26_999_999) begin   // clk_sys = 27 MHz -> 1 Hz
        sec_div  <= 25'd0;
        sec_tick <= 1'b1;
    end else begin
        sec_div  <= sec_div + 25'd1;
        sec_tick <= 1'b0;
    end
end
wire vm_entropy_stir = |(joystick_0 ^ joy_prev);   // any gamepad edge = user timing
// Seed = mount-instant counter XOR the wall clock (both halves of it, so a
// 16-bit seed still moves with the high word). srand(time()) parity.
wire [15:0] vm_rnd_seed = entropy_ctr[15:0] ^
                          hps_timestamp[15:0] ^ hps_timestamp[31:16];

dvd_vm dvd_vm_inst (
    .clk           (clk_sys),
    .rst_n         (reset_n),
    .rnd_seed      (vm_rnd_seed),
    .sec_tick      (sec_tick),
    .entropy_stir  (vm_entropy_stir),
    .entropy_val   (entropy_ctr[15:0]),
    .enable        (menus_on),
    .start         (start_streaming),
    .cfg_lang      (player_lang),        // OSD Player Language -> SPRM0/16/18
    .nav_ready     (nav_ready_w),
    .auto_vts      (auto_vts_w),
    .best_menu_vts (best_menu_vts),
    .res_ttn       (res_ttn_w),

    .cmd_we        (vm_cmd_we),
    .cmd_waddr     (vm_cmd_waddr),
    .cmd_wdata     (vm_cmd_wdata),
    .nr_pre        (vm_nr_pre),
    .nr_post       (vm_nr_post),
    .nr_cell       (vm_nr_cell),
    .pm_we         (vm_pm_we),
    .pm_waddr      (vm_pm_waddr),
    .pm_wdata      (vm_pm_wdata),
    .nr_pgms       (vm_nr_pgm),

    .pgc_loaded    (pgc_loaded),
    .pgc_error     (pgc_error),
    .vm_cell_cmd   (vm_cell_cmd_w),
    .cell_cmd_nr   (cur_cell_cmdnr_w),
    .vm_pgc_end    (vm_pgc_end_w),
    .menu_active   (menu_active),
    .cur_vts       (cur_vts),
    .cur_pgcn      (cur_pgcn_rd),
    .cur_cell      (cur_cell),
    .cell_count    (cell_count_w),
    .next_pgcn     (rd_next_pgcn),
    .prev_pgcn     (rd_prev_pgcn),
    .goup_pgcn     (rd_goup_pgcn),

    .key_menu      (key_menu_p),
    .key_resume    (key_resume_p),
    .key_title     (key_title_p),
    .key_return    (key_return_p),

    .btn_cmd       (hl_btn_cmd),
    .btn_cmd_valid (hl_btn_cmd_valid),
    .btn_sel       (hl_btn_sel),
    .btns_armed    (hl_btns_armed),
    .btn_force     (vm_btn_force),
    .btn_force_val (vm_btn_force_val),

    .jump_pulse    (vm_jump_pulse),
    .jump_domain   (vm_jump_domain),
    .jump_vts      (vm_jump_vts),
    .jump_pgcn     (vm_jump_pgcn),
    .jump_entry    (vm_jump_entry),
    .jump_ttn      (vm_jump_ttn),
    .jump_pgn      (vm_jump_pgn),
    .jump_ptt      (vm_jump_ptt),
    .jump_cell     (vm_jump_cell),
    .seek_pulse    (vm_seek_pulse),
    .seek_cell     (vm_seek_cell),
    .vm_replay     (vm_replay_w),
    .vm_adv        (vm_adv_w),
    .vm_from_wait  (vm_from_wait_w),      // Phase B: natural-jump provenance
    .wait_hold     (nat_wait_w),          // Phase B: freeze V_WAIT while gated

    .sprm_astn     (vm_astn),
    .sprm_spstn    (vm_spstn),
    .dbg_state     (vm_dbg_state),
    .dbg_g3        (vm_dbg_g3),
    .dbg_g14_9     (vm_dbg_g14_9),
    .dbg_rsm       (vm_dbg_rsm),
    .dbg_deadend   (vm_dbg_deadend),
    .link_fail     (vm_link_fail),       // failed menu link -> HUD "LINK FAIL nn"
    .link_fail_pgcn(vm_link_fail_pgcn)
);

// Transport / VM seek mux (the VM's LinkCN/LinkPGN cell seeks share the
// reader's one seek port with the gamepad transport; collisions are
// impossible in practice - the VM only seeks from menu/command contexts).
wire       seek_pulse_mux = seek_pulse | vm_seek_pulse;
wire [7:0] seek_cell_mux  = vm_seek_pulse ? vm_seek_cell : seek_cell;
// Phase B: only a VM-issued seek can carry natural provenance - AND with
// vm_seek_pulse so a coincident gamepad seek is never tagged natural.
wire       seek_natural_mux = vm_seek_pulse & vm_from_wait_w;

// ========================================================================
// Phase-10 track selection — gamepad Audio (B7) / Subtitle (B8) cycle buttons.
// Replaces the old OSD O[8:6]/O[15]/O[26:24] selectors: MiSTer CONF_STR value
// labels are compile-time static, so a per-disc track/language list can't live
// in the OSD; a DVD-remote-style cycle button is the authentic surface and the
// visual "AUD 2/4 fr" indicator is deferred to Phase 11 (uses the attr_*
// readout this exposes). aud_cur cycles 0..audio_ntracks-1; the Subtitle button
// cycles off -> 0..subp_ntracks-1 -> off. The counts (audio_ntracks_w /
// subp_ntracks_w) come from the title IFO (default 8 = unconstrained until a
// real IFO parses, so linear playback is unchanged), so a cycle can never land
// on a stream the disc lacks (-> silence / garbage).
wire [3:0] audio_ntracks_w, subp_ntracks_w;
wire [2:0] attr_a_fmt_w;
wire [3:0] attr_a_ch_w;
wire [15:0] attr_a_lang_w, attr_s_lang_w;
reg  [2:0] aud_cur;
reg        sub_on;
reg  [2:0] sub_idx;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        aud_cur <= 3'd0; sub_on <= 1'b0; sub_idx <= 3'd0;
    end else if (start_streaming) begin
        aud_cur <= 3'd0; sub_on <= 1'b0; sub_idx <= 3'd0;  // default: track 0, subs off
    end else begin
        if (audio_edge)
            aud_cur <= (({1'b0,aud_cur} + 4'd1) >= audio_ntracks_w) ? 3'd0 : aud_cur + 3'd1;
        if (sub_edge) begin
            if (!sub_on)                                        begin sub_on <= 1'b1; sub_idx <= 3'd0; end
            else if (({1'b0,sub_idx} + 4'd1) >= subp_ntracks_w) begin sub_on <= 1'b0; sub_idx <= 3'd0; end
            else                                                sub_idx <= sub_idx + 3'd1;
        end
    end
end

// Menu SetSTN (SPRM1/2) vs. the gamepad pick: whichever was touched most
// recently wins, so a menu selection doesn't permanently lock out the buttons
// and vice-versa (HW round 1: once a menu set a track the user control stopped
// working). `vm_owns_*` latches on a SetSTN change and clears the moment the
// matching gamepad button is pressed. Cleared on a fresh mount. SPRM1 default
// 15 (none) never claims audio.
reg  vm_owns_aud, vm_owns_sp;
reg  [7:0] vm_astn_p, vm_spstn_p;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        vm_owns_aud <= 1'b0; vm_owns_sp <= 1'b0;
        vm_astn_p <= 8'd15;  vm_spstn_p <= 8'd0;
    end else begin
        vm_astn_p  <= vm_astn;   vm_spstn_p <= vm_spstn;
        if (start_streaming) begin
            vm_owns_aud <= 1'b0; vm_owns_sp <= 1'b0;
        end else begin
            // audio: a SetSTN that names a real track claims; the Audio button releases
            if (menus_on && vm_astn != vm_astn_p && vm_astn < 8'd8)
                vm_owns_aud <= 1'b1;
            if (audio_edge)
                vm_owns_aud <= 1'b0;
            // subpicture: SetSTN display-on claims; the Subtitle button releases
            if (menus_on && vm_spstn != vm_spstn_p && vm_spstn[6])
                vm_owns_sp <= 1'b1;
            if (sub_edge)
                vm_owns_sp <= 1'b0;
        end
    end
end
// Selected audio track, clamped to the parsed count (belt-and-suspenders — a VM
// SetSTN could name a track the title lacks; the button path is already bounded).
wire [2:0] aud_sel = (menus_on && vm_owns_aud && vm_astn < 8'd8) ? vm_astn[2:0] : aud_cur;
wire [2:0] aud_log = (({1'b0,aud_sel} >= audio_ntracks_w)
                     ? (audio_ntracks_w[2:0] - 3'd1) : aud_sel);
// ---- DVD audio logical->physical stream mapping (libdvdnav vm_get_audio_stream) ----
// aud_log is a LOGICAL stream number (that's what SPRM1/SetSTN and the DVD spec
// mean by "audio stream"); the substream id ps_demux filters on is the PHYSICAL
// number from the PGC's audio_control[8] table. Assuming identity here was the
// "language menu -> movie plays SILENT" bug (a disc may map every logical to
// e.g. 0x83 — GET_SMART VTS2; 31/431 library discs author non-identity maps).
// The map store is deliberately NARROW: only avail (bit15) + phys (bits[10:8])
// are kept — 32 FFs, not eight u16 words (a second 32-bit mux failed to route
// on this design once already; see the subp_ctl_mem note below).
reg [7:0]  actl_avail;
reg [23:0] actl_phys;                       // {phys7,...,phys0}, 3 bits each
always @(posedge clk_sys) begin
    if (pgc_ctl_we && pgc_ctl_waddr[4]) begin
        actl_avail[pgc_ctl_waddr[2:0]] <= pgc_ctl_wdata[15];
        case (pgc_ctl_waddr[2:0])       // explicit mux — no variable part-select
        3'd0: actl_phys[ 2: 0] <= pgc_ctl_wdata[10:8];
        3'd1: actl_phys[ 5: 3] <= pgc_ctl_wdata[10:8];
        3'd2: actl_phys[ 8: 6] <= pgc_ctl_wdata[10:8];
        3'd3: actl_phys[11: 9] <= pgc_ctl_wdata[10:8];
        3'd4: actl_phys[14:12] <= pgc_ctl_wdata[10:8];
        3'd5: actl_phys[17:15] <= pgc_ctl_wdata[10:8];
        3'd6: actl_phys[20:18] <= pgc_ctl_wdata[10:8];
        3'd7: actl_phys[23:21] <= pgc_ctl_wdata[10:8];
        endcase
    end
end
wire [2:0] aud_track_eff;
aud_stream_map aud_stream_map_inst (
    .map_valid    (pgc_ctl_valid),          // 0 = no PGC parsed / linear -> identity
    .dom_tt       (pgc_dom_tt),             // menus/FP force logical 0 (vmget.c)
    .logical      (aud_log),
    .avail        (actl_avail),
    .phys_flat    (actl_phys),
    .phys_streamN (aud_track_eff)
);
// Phase-10 HW follow-up (round 2): an audio-track switch changes which substream
// ps_demux forwards, so the audio pipeline restarts at a new fill level while the
// video STC keeps running — the audio playback phase (set at the PCM-FIFO exit) is
// established for the OLD track and no longer matches, so A/V drifts until the next
// (re)start event. A transport seek fixes it because seek_ack pulses load_flush
// (drain the audio pipeline + re-anchor av_sync's STC).
//   ROUND-1 MISTAKE (reverted): pulsing load_flush on the switch ALSO reset
//   ps_demux — but ps_demux carries VIDEO on the same byte stream, and a
//   mid-PES reset corrupts the video bitstream (green frame) with no vbuf re-lock
//   to recover (unlike a seek/menu-jump, which restart the demux at a CLEAN pack
//   boundary). So the audio switch must re-sync the audio chain WITHOUT touching
//   the shared demux -> the dedicated `aud_resync` reset below.
// Detect a real change of the EFFECTIVE track (covers the gamepad button AND a VM
// SetSTN), one-cycle pulse.
//   ★ Jump-window guard (audio-mapping follow-up): with the logical->physical map
//   in the path, aud_track_eff now ALSO changes whenever a PGC load re-parses
//   audio_control (streaming intermediate words included). Those changes must NOT
//   pulse aud_resync: a ~keep_vbuf jump already did the full aud_flush, and a
//   keep_vbuf menu->menu hop deliberately keeps audio continuous (§5d) — a resync
//   there re-introduces the menu-junction audio drop. Every PGC parse is bracketed
//   by {start_streaming|seek_ack|jump_ack} .. pgc_loaded, so suppress the pulse in
//   that window (0.62 s timeout covers pgc_error / linear seeks, where pgc_loaded
//   never comes). aud_track_eff_q keeps tracking INSIDE the window so its close
//   can't manufacture a stale-vs-new edge. User/SetSTN switches outside a load are
//   untouched — including on linear .VOB/.mpg (map_valid=0 = identity map there).
reg        aud_jw;
reg [23:0] aud_jw_tmr;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        aud_jw <= 1'b0; aud_jw_tmr <= 24'd0;
    end else if (start_streaming | seek_ack | jump_ack) begin
        aud_jw <= 1'b1; aud_jw_tmr <= 24'd0;
    end else if (pgc_loaded | (&aud_jw_tmr)) begin
        aud_jw <= 1'b0;
    end else if (aud_jw) begin
        aud_jw_tmr <= aud_jw_tmr + 24'd1;
    end
end
reg [2:0] aud_track_eff_q;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) aud_track_eff_q <= 3'd0;
    else          aud_track_eff_q <= aud_track_eff;
end
wire aud_switch = (aud_track_eff != aud_track_eff_q) && !aud_jw;
// MENU subpicture is ALWAYS on subpicture stream 0 (substream 0x20 — the button/
// highlight graphic; verified on T2: every menu carries 0x20 + 0x21). ps_demux
// filters to ONE substream, so a SetSTN on the way into a submenu (SPRM2) or a
// non-zero subtitle track would make it drop the menu's own 0x20 stream ->
// no menu graphic + nothing for the highlight to recolour (HW: deep menus blank).
// Force stream 0 while a menu is up; SPRM2/gamepad selection is for the TITLE only.
wire [2:0] sp_sel = (menus_on && vm_owns_sp && vm_spstn[6]) ? vm_spstn[2:0] : sub_idx;

// ---- DVD subpicture display-mode substream mapping (in-title HLI buttons) ----
// A VM SetSTN (SPRM2) selects a LOGICAL subpicture stream; the PHYSICAL substream
// id (0x20+N) depends on the video display mode via pgc->subp_control[logical]
// (streamed from the reader). This is how the Matrix "Follow the White Rabbit"
// icon (SetSTN logical stream 1) reaches substream 0x22 (16:9 wide) / 0x23
// (letterbox) instead of 0x21. Applied ONLY to the VM-selected stream so the
// user subtitle path is byte-identical. Ref: libdvdnav vmget.c vm_get_subp_stream.
reg  [31:0] subp_ctl_mem [0:15];
always @(posedge clk_sys)
    if (pgc_ctl_we && !pgc_ctl_waddr[4]) subp_ctl_mem[pgc_ctl_waddr[3:0]] <= pgc_ctl_wdata;
// Force 4:3 Subpics (P1O[15]) debug override: advertise a 4:3/LETTERBOX display so a
// disc that authors mode-specific subpicture streams serves its 4:3-mode art. MiB
// "visual commentary" is the motivating case (logical subp 3: wide->0x23 warning,
// letterbox->0x24 = the real silhouettes/annotations). See memory
// mib-visual-commentary-letterbox-substream. Off = byte-identical to before.
wire        force_43_subp = status[15];
// The VM (in-title HLI / SetSTN) path and the user (gamepad B8) path both resolve a
// LOGICAL subpicture stream -> PHYSICAL substream via pgc->subp_control by display mode.
// SHARE one subp_ctl_mem 16:1 read between them (routing is tight at ~90% ALM — a second
// mux failed to fit): pick the logical index first, then one lookup + one mapping.
wire        vm_owns_route = menus_on && vm_owns_sp && vm_spstn[6];
wire [2:0]  sp_user_log   = ({1'b0,sp_sel} >= subp_ntracks_w)
                            ? (subp_ntracks_w[2:0] - 3'd1) : sp_sel;   // clamped user index
wire [3:0]  sp_sel_log    = vm_owns_route ? vm_spstn[3:0] : {1'b0, sp_user_log};
wire [31:0] subp_ctl_sel  = subp_ctl_mem[sp_sel_log];                 // single 16:1 mux
// 16:9 display mode: override -> letterbox; else Crop=pan&scan, Letterbox=letterbox,
// else wide (Fit/HDMI anamorphic — the common case; O[4:3] refines it, HW-tunable).
wire [1:0]  sp_disp_mode = force_43_subp        ? 2'd1 :
                           (status[4:3] == 2'd3) ? 2'd2 :
                           (status[4:3] == 2'd2) ? 2'd1 : 2'd0;
wire [4:0]  sp_phys_streamN =
      !subp_ctl_sel[31]      ? {1'b0, sp_sel_log}    :   // undefined -> logical (as before)
      !ar_wide_auto          ? subp_ctl_sel[28:24]   :   // 4:3 content
      (sp_disp_mode == 2'd1) ? subp_ctl_sel[12:8]    :   // 16:9 letterbox
      (sp_disp_mode == 2'd2) ? subp_ctl_sel[4:0]     :   // 16:9 pan&scan
                               subp_ctl_sel[20:16];       // 16:9 wide

// VM streams ALWAYS map (in-title HLI). The user path maps only under Force 4:3 Subpics
// (a user-selected commentary track -> its letterbox physical substream, MiB logical 3 ->
// 0x24, instead of the raw index -> 0x23 warning); the 3-bit ps_demux substream_id[2:0]
// match stays unambiguous here (active substreams 0x20/21/22/23/24 -> 0/1/2/3/4). Off =
// user path byte-identical (raw clamped logical index).
// An in-title multi-button game menu (Scene It) is a MENU: its highlight rides
// subpicture stream 0 like a menu-domain menu, so force stream 0 for it too
// (the single-button white rabbit keeps its SetSTN vm_owns_route mapping).
wire [2:0] sp_track_eff  = (menus_on && menu_active) || sp_menu_early ? 3'd0 :
                           vm_owns_route                  ? sp_phys_streamN[2:0] :
                           force_43_subp                  ? sp_phys_streamN[2:0] :
                                                            sp_user_log;

// =========================================================================
// DVD-FORK (live output-mode switch — built for Interlaced Out Auto, now serving the
// Video Output OSD toggle): a LIVE interlaced<->progressive mode change must
// re-init the pipeline the same way loading an ISO does. Flipping the modeline mid-title
// re-kicks the register walk (emu ~2240) but the decoder/ascal keep running in the old
// raster (observed on HW: toggling the fields mode mid-playback stayed progressive; setting
// it BEFORE load worked because the pipeline cold-starts into the mode).
//   il_switch therefore drives the FULL seek-equivalent flush, NOT just the VBUF flush:
//   - seek_flush -> vbuf_flush_dec : the decoder discards its buffered bitstream and
//     re-locks on the next sequence header, picking up the new interlaced/deinterlace regs
//     (the raster actually changes).
//   - load_flush -> pipe_rst_n : resets ps_demux/ac3_reframer AND av_sync (a FRESH STC
//     anchor) + re-arms the STD mux-lead hold so the first post-switch frame is deferred
//     until audio catches up.
//   - aud_flush  -> aud_rst_n : resets audio_ring + dvd_audio_decode so the queued audio
//     backlog is discarded and re-phases to the new video position.
//   VBUF-flush-ONLY (the first version) jumped video ~1 s FORWARD (discarded buffer) while
//   audio kept its backlog and av_sync kept its old anchor (av_sync only re-anchors on a
//   DEMUX vid_pts jump, and the demux front is continuous through a vbuf flush) => audio ran
//   ~1 s LATE under Auto (On/Off never flush mid-stream, so they stayed synced). The full
//   flush is exactly what a chapter seek does (HW-confirmed synced); the only difference is
//   the reader doesn't jump, so ps_demux re-hunts to the next pack boundary within the vbuf
//   re-lock glitch. Since the 2026-09-02 consolidation il_eff changes ONLY on an OSD edit
//   of Video Output (the det_video Auto detector is gone; Auto is ini-static), so this
//   fires at user rate. il_switch is a one-clk_sys-cycle pulse. See docs/interlaced_auto.md.
// Declared here (above CLIP-LOAD FLUSH) so it precedes its use in load_flush/aud_flush.
reg       il_eff_q = 1'b0;
wire      il_switch = il_eff ^ il_eff_q;
// ⛔ FILM-RASTER SWITCH — ATTEMPTED AND REVERTED (2026-08-28). A filmp_eff XOR edge
// briefly drove mode_switch here (full flush trio on a live film engage/disengage, to
// fix the menu->film constant skew). ON HW IT BROKE T2's menu->Play logo chain: the
// Dolby/THX logos flap the cadence detector, and each flap fired the trio at an
// ARBITRARY mid-stream byte position (no reader jump = no VOBU re-alignment, unlike a
// chapter seek). Repeated mid-parse flushes yielded garbage sequence headers (186-wide
// resolution popups), a garbage 576-line parse flipped pal_eff (25 Hz), and pal_eff
// feeds back into film_want -> another filmp_eff edge -> another flush = a self-
// feeding corruption/strobe loop. il_switch is only safe because il_eff changes
// ~once/title. Do NOT re-add a bare filmp edge here. The proper fix is the early-
// film-detect feature (parse-front sniffer seeds the detector during the load hold so
// the raster is right BEFORE display; a mid-title film_switch then needs hold-
// suppression + a post-discontinuity holdoff, TB'd in flush_ctl_tb) — see
// docs/film_24p_plan.md §13.
// mode_switch = live raster-regime change -> full flush trio (load+aud+seek).
// Today that is il_switch alone.
wire      mode_switch = il_switch;
always @(posedge clk_sys) begin
    if (~reset_n) il_eff_q <= 1'b0;
    else          il_eff_q <= il_eff;
end

// =========================================================================
// FLUSH / RESET TRIGGER MATRIX — dvd/flush_ctl.sv (extracted 2026-08-28 so the
// trigger matrix is testbenchable: bench/dvd/flush_ctl_tb.sv). The full design
// rationale moved with the code: CLIP-LOAD FLUSH scope (what pipe_rst_n does and
// deliberately does NOT reset), AUDIO-ONLY RE-SYNC (aud_resync), keep_vbuf
// audio-continuity (aud_flush gating), the SEEK VBUF FLUSH + the 2026-08-28
// mount/mode_switch flush-trio rule. Events in, ~64-cycle flush levels out.
wire load_flush, aud_flush, aud_resync, seek_flush, mount_flush;
wire pipe_rst_n, aud_rst_n;
flush_ctl flush_ctl_i (
    .clk             (clk_sys),
    .rst_n           (reset_n),
    .start_streaming (start_streaming),
    .seek_ack        (seek_ack),
    .jump_ack        (jump_ack),
    .mode_switch     (mode_switch),
    .aud_switch      (aud_switch),
    .keep_vbuf       (keep_vbuf),
    .load_flush      (load_flush),
    .aud_flush       (aud_flush),
    .aud_resync      (aud_resync),
    .seek_flush      (seek_flush),
    .mount_flush     (mount_flush),
    .pipe_rst_n      (pipe_rst_n),
    .aud_rst_n       (aud_rst_n)
);
// On a keep_vbuf menu transition the audio ring is NOT reset (audio-continuity), so tell it
// to DROP the splice frames (truncated old + ps_demux/reframer re-sync garbage) that would
// otherwise decode as a pop/blip (MiB/Matrix root-menu transitions). §5d.
wire aud_drop_pulse = (jump_ack | seek_ack) & keep_vbuf;
// The AC-3/DTS REFRAMERS reset on `reset_n` ONLY (not per-jump pipe_rst_n). They are
// self-healing passthroughs - on any switch they re-lock on the next 0x0B77 / 0x7FFE8001
// sync word (frmsizcod lock), so a per-jump reset was never needed. It was actively HARMFUL
// once the audio ring rode through a keep_vbuf transition (audio-continuity, aud_rst_n above):
// resetting the reframer while KEEPING the ring let the reframer push one MIS-ALIGNED AC-3
// frame into the preserved ring during re-sync = the "static pop" leaving a root menu
// (MiB/Matrix; [[static-pops-root-cause]]). On a real flush the ring IS reset and only commits
// on the reframer's frame_start, so the reframer's pre-lock bytes never become a committed
// frame - no per-jump reframer reset required. Bonus: taking them off pipe_rst_n's fanout
// (onto the already-global reset_n) also relieves routing congestion (this netlist was over
// the routing cliff). See dvd/emu.sv reframer instantiations (.rst_n(reset_n)).

// MENU VBUF CAP (docs/dvd_menu_refinements.md §5d): the "leaving a video menu lags"
// symptom is the display trailing the parse by the KEPT video-buffer depth (keep_vbuf).
// Rather than FLUSH that backlog (Snappy - cuts T2 transition animations), simply stop
// the reader from running so far ahead WHILE A MENU IS ACTIVE: throttle it whenever the
// decoder's compressed buffer is over ~384 KB. The buffer stays shallow, so a menu->menu
// transition has only a short backlog to play out (small lag) yet is NOT flushed (the
// authored transition still decodes continuously). Menus are low-bitrate so a shallow
// buffer doesn't starve video. `menu_vbuf_over` is
// assigned from the framestore tap further down (declared here for the reader_busy gate);
// hysteresis 0x30 on / 0x18 off ~= 384/192 KB. Now UNIVERSAL (the Snappy/Smooth toggle was
// removed once HW confirmed this keep+cap behaviour works on every disc) - always throttle
// while a menu is active.
//
// ★ MENU-AUDIO STALL GRAIN (Thayer's Quest ~3 Hz menu-audio skipping, 2026-08-04).
// The original assumption above — "audio rides the throttle's brief oscillations via
// its ring" — is FALSE on a just-in-time mux: Thayer authors its audio only ~33 ms
// ahead of its delivery schedule (normal discs: 470-667 ms), so the ring cushion at
// the cap is small and the ORIGINAL release point (drain 0x30 -> 0x18 = a ~250 ms
// full-stream stall per cycle) outlasted it. HW-measured (osd_read on the
// DEBUG_OVERLAY build): stream feed halted one 100 ms sample in three (VBUF sawtooth
// in the hysteresis band), audio ring pinned at 0, zero drops/decoder resets = pure
// supply starvation at a metronomic ~3.3 Hz.
//
// FIX v3 = keep the cap + a RING-FLOOR ESCAPE VALVE. Quantitatively (byte-level
// interleave scan, per-cell monotonic): Thayer's audio sits up to ~+122 KB (p90
// +42 KB) BEHIND its concurrent video in the stream, and the intro's bitrate is
// high, so the 0x30 cap ≈ only ~0.3 s of demux-front lead — minus the interleave
// lag and the audio decode pipeline's hold, the equilibrium ring cushion lands at
// ~ZERO: the cap sits exactly at this disc's viability threshold (v2's finer stall
// grain alone couldn't save it — solid audio only until the VBUF first reached the
// cap, ~3 s). MiB/T2 menus are low-bitrate with generous interleave margin, which
// is why the cap never hurt them.
//
// So: when menu audio is LIVE (retriggerable ~0.7 s window on rf_aud_valid) AND the
// ring is LOW (< 6 committed frames, hysteresis to 12), the cap releases until the
// ring recovers. Self-adjusting: discs with margin never trip the floor (full §5d
// polish, cap-only); a tight-mux/high-rate menu holds its VBUF slightly above the
// cap — exactly as much extra lead as its interleave needs, bounded (~6 frames of
// audio ≈ a few hundred KB of stream per release burst), and VBUF-full (the v1
// failure) remains impossible.
//
// ⛔ REJECTED (HW 2026-08-04): v1 = menu_aud_live alone DISABLING the cap while
// audio flows. Most menus have music, so the cap died everywhere (~1 s sluggish
// transitions + highlight-before-image regressions), and the free-running VBUF hit
// TRUE FULL in ~10 s — in that regime the shared stream is video-paced at the
// vbuf-write stall and the ring has no restoring force (drained once, parked at 0,
// permanent skipping). The cap must stay engaged; only a BOUNDED, ring-closed
// release is safe.
reg [24:0] menu_aud_tmr;                       // ~0.7 s at 27 MHz
wire       menu_aud_live = (menu_aud_tmr != 25'd0);
always @(posedge clk_sys) begin
    if (!reset_n)                   menu_aud_tmr <= 25'd0;
    else if (rf_aud_valid)          menu_aud_tmr <= 25'd18_900_000;
    else if (menu_aud_live)         menu_aud_tmr <= menu_aud_tmr - 25'd1;
end
reg  aud_ring_low;                             // hysteresis: <6 frames low, >=12 ok
always @(posedge clk_sys) begin
    if (!reset_n)                          aud_ring_low <= 1'b0;
    else if (aud_frames_avail <  16'd6)    aud_ring_low <= 1'b1;
    else if (aud_frames_avail >= 16'd12)   aud_ring_low <= 1'b0;
end
reg  menu_vbuf_over;
wire menu_vbuf_throttle = menus_on & menu_active & menu_vbuf_over &
                          ~(menu_aud_live & aud_ring_low);
// ★ GLOBAL VBUF SOFT CEILING (v4, 2026-08-05 — the row-27 verdict). The one regime
// that must NEVER be reached is VBUF hard-full: the demux jams mid-PES on its video
// output (row 27: FIFO stall, sticky, permanent), the ring backpressure never gets
// to engage, and the audio ring bleeds to 0 with no restoring force — measured on
// BOTH Thayer menus (v3 floor released the cap, VBUF crept 110->241->255 in ~16 s,
// then the jam killed audio permanently) and Thayer titles (steady state = vbuf 255
// FIFO for most of gameplay). A reader-side stall at 0xE0 (release 0xD8: an ~8-unit
// ~60-100 ms drain, short enough for the ring to ride through) keeps the front
// regulated at sector granularity instead of the jam's uncontrolled granularity.
// Normal discs never get here (the ring backpressure regulates at ~0x50-0x9B);
// Thayer-class menus park at the ceiling: transitions on THOSE menus are slower
// (~1.5-2.5 s backlog) but the audio is correct — the accepted trade. See
// docs/dvd_menu_refinements.md §5d.
localparam [7:0] VBUF_HARD_ON  = 8'hE0;
localparam [7:0] VBUF_HARD_OFF = 8'hD8;
reg  vbuf_hard_over;
always @(posedge clk_sys) begin
    if (!reset_n)                              vbuf_hard_over <= 1'b0;
    else if (vbuf_fill_s1 >= VBUF_HARD_ON)     vbuf_hard_over <= 1'b1;
    else if (vbuf_fill_s1 <  VBUF_HARD_OFF)    vbuf_hard_over <= 1'b0;
end
wire reader_busy = fifo_almost_full | menu_vbuf_throttle | vbuf_hard_over;

// SEEK VBUF FLUSH — now generated inside flush_ctl (see the trigger-matrix
// instantiation above): a title transport seek / menu->title jump (~keep_vbuf),
// a raster-regime switch (mode_switch), or a file mount (2026-08-28) discards
// the decoder's ~1 s compressed cushion so the picture jumps with the audio.
// Full rationale (incl. the mount flush-trio post-mortem and the keep_vbuf
// menu-transition suppression) lives in dvd/flush_ctl.sv. Here we only 2-FF the
// clk_sys level into clk_dec to drive mpeg2video.vbuf_flush.
reg vbuf_flush_s1, vbuf_flush_dec;
always @(posedge clk_dec) begin
    vbuf_flush_s1  <= seek_flush;
    vbuf_flush_dec <= vbuf_flush_s1;
end

// DISC-MENU STILL (Phase 2): while the reader parks on an authored menu still
// (still_active, clk_sys), suppress the decoder WATCHDOG only - the decoder
// must keep decoding its buffered tail (which ends on the authored still
// frame), then starve gracefully with the last frame on screen. Deliberately
// NOT the full 4-hold pause set: freezing the governor here would hold a frame
// ~1 s of buffered video too early (the transport-seek lesson in reverse), and
// the drop-debt controller already ignores starvation lates (bitstream_ok
// gate). Audio drains to natural silence; av_sync re-anchors on the exit jump.
reg still_s1, still_dec;
always @(posedge clk_dec) begin
    still_s1  <= still_active;
    still_dec <= still_s1;
end

wire streamer_active, streamer_sd_rd, streamer_sd_ack, streamer_has_data;
wire [15:0] streamer_file_size, streamer_total_sectors, streamer_next_lba;

// DVD-FORK: dvd_iso_reader replaces mpg_streamer. Same output contract and sd_*
// bus; adds in-fabric DVD-Video ISO9660 navigation (finds VIDEO_TS, plays the
// largest VTS = main feature). A non-ISO image (no CD001) auto-falls back to the
// old linear whole-file streaming, so .VOB/.mpg/.m2v playback is unchanged.
// No HPS daemon: the sd_* block interface is random-access, so the reader drives
// sd_lba to any sector of the mounted image itself. See docs/dvd_nav.md.
wire        iso_mode_w;
wire        iso_error_w;
wire [15:0] streamer_dbg_state;

dvd_iso_reader dvd_iso_reader_inst (
    .clk            (clk_sys),
    .rst_n          (reset_n),

    .start          (start_streaming),
    .file_size      (current_file_size),
    .lu_lang_pref   (player_lang),        // OSD Player Language -> menu-LU match
    .title_sel      (dbg_title_vts),      // Debug "Title VTS" picker: 0=Auto, else VTS #
    .vbuf_empty     (vbuf_empty),         // §5 menu still cold re-decode: decoder buffer drained
    .menu_snap      (1'b0),               // toggle removed (universal Smooth): still re-decode waits vbuf_empty
    // Authored cell duration: display-referenced cell clock. Same tick av_sync
    // advances the STC with (one pulse per displayed image); disp_fps resolves
    // the active raster rate incl. the Film 24p/25p modes.
    .disp_tick      (av_refresh_tick),
    .disp_fps       (film24_eff ? 6'd24 : film25_eff ? 6'd25 :
                     pal_eff    ? 6'd50 : 6'd60),

    .seek_pulse     (seek_pulse_mux),     // gamepad chapter seek | VM cell links
    .seek_cell      (seek_cell_mux),
    .seek_natural   (seek_natural_mux),   // Phase B: VM CELL/POST-verdict seek
    .seek_rbn_pulse (seek_rbn_pulse),     // gamepad time scrub (DSI fwda/bwda)
    .seek_rbn       (seek_rbn),
    .chap_pulse     (chap_pulse),         // gamepad chapter skip (B2/B3)
    .chap_dir       (chap_dir),
    .chap_mag       (chap_mag),           // debounced burst magnitude (# chapters)
    .chap_at_start  (chap_at_start),      // prev: restart current chapter unless <5 s in
    .angle_pulse    (angle_pulse),        // Phase 9: B6 = cycle camera angle
    .cur_angle      (cur_angle),
    .angle_count    (angle_count),
    .seek_ack       (seek_ack),
    .cur_cell       (cur_cell),
    .cell_ready     (cell_ready),

    .jump_pulse     (vm_jump_pulse),      // Phase 4: the DVD-VM owns all jumps
    .jump_domain    (vm_jump_domain),
    .jump_vts       (vm_jump_vts),
    .jump_pgcn      (vm_jump_pgcn),
    .jump_entry     (vm_jump_entry),
    .jump_cell      (vm_jump_cell),
    .jump_ttn       (vm_jump_ttn),
    .jump_pgn       (vm_jump_pgn),
    .jump_ptt       (vm_jump_ptt),
    .jump_natural   (vm_from_wait_w),     // Phase B: VM CELL/POST-verdict jump
    .jump_ack       (jump_ack),
    .keep_vbuf      (keep_vbuf),
    .pgc_loaded     (pgc_loaded),
    .pgc_error      (pgc_error),
    .menu_active    (menu_active),
    .still_active   (still_active),
    .cur_vts        (cur_vts),
    .cur_pgcn_o     (cur_pgcn_rd),
    .best_menu_vts  (best_menu_vts),
    .menu_btns_armed(hl_btns_armed),      // Phase 3: cell-loop heuristic (vm off)

    .vm_mode        (menus_on),           // Phase 4: the VM drives navigation
    .vm_adv         (vm_adv_w),
    .vm_replay      (vm_replay_w),
    .vm_cell_cmd    (vm_cell_cmd_w),
    .vm_pgc_end     (vm_pgc_end_w),
    .nat_wait_o     (nat_wait_w),         // Phase B: natural jump/seek gated
    .nav_ready_o    (nav_ready_w),
    .auto_vts       (auto_vts_w),
    .cell_count_o   (cell_count_w),
    .res_ttn        (res_ttn_w),

    // Phase-10 track enumeration (title VTS audio/subpicture stream attrs)
    .audio_ntracks  (audio_ntracks_w),
    .subp_ntracks   (subp_ntracks_w),
    .attr_a_sel     (aud_cur),            // read out the selected audio track
    .attr_a_fmt     (attr_a_fmt_w),
    .attr_a_ch      (attr_a_ch_w),
    .attr_a_lang    (attr_a_lang_w),
    .attr_s_sel     (sub_idx),            // read out the selected subtitle track
    .attr_s_lang    (attr_s_lang_w),

    .cmd_we         (vm_cmd_we),          // PGC command table -> VM BRAM
    .cmd_waddr      (vm_cmd_waddr),
    .cmd_wdata      (vm_cmd_wdata),
    .cmd_nr_pre     (vm_nr_pre),
    .cmd_nr_post    (vm_nr_post),
    .cmd_nr_cell    (vm_nr_cell),
    .pm_we          (vm_pm_we),           // program map -> VM BRAM
    .pm_waddr       (vm_pm_waddr),
    .pm_wdata       (vm_pm_wdata),
    .cmd_nr_pgm     (vm_nr_pgm),
    .cur_pgm        (cur_pgm_w),          // Phase 11 HUD: current chapter (1-based)
    .nr_ptt_o       (nr_ptt_w),           // Phase 6: exact chapter total (nr_of_ptts)
    .cell_end_pulse (),
    .pgc_end_pulse  (),
    .pgc_still_time (),
    .pgc_playback_time (pgc_playback_time_w),
    .next_pgcn      (rd_next_pgcn),
    .prev_pgcn      (rd_prev_pgcn),
    .goup_pgcn      (rd_goup_pgcn),
    .cur_cell_start (cur_cell_start_w),   // Phase 11: whole-title time prefix sum
    .cellf_we       (cellf_we_w),         // Phase 11: seek-bar chapter-tick feed
    .cellf_idx      (cellf_idx_w),
    .cellf_rbn      (cellf_rbn_w),
    .cur_cell_still (),
    .cur_cell_cmdnr (cur_cell_cmdnr_w),
    .title_first_rbn (title_first_rbn_w),         // seek-bar: title RBN span
    .title_last_rbn  (title_last_rbn_w),
    .menu_ar_wide   (menu_ar_wide_w),

    .sd_lba         (sd_lba),
    .sd_rd          (sd_rd),
    .sd_ack         (sd_ack),
    .sd_buff_addr   (sd_buff_addr),
    .sd_buff_dout   (sd_buff_dout),
    .sd_buff_wr     (sd_buff_wr),

    .stream_data    (stream_data),
    .stream_valid   (stream_valid),
    .busy           (reader_busy),        // FIFO backpressure + menu VBUF cap (below)

    .pal_we         (pgc_pal_we),         // PGC palette stream -> pgc_palette
    .pal_waddr      (pgc_pal_waddr),
    .pal_wdata      (pgc_pal_wdata),
    .pgc_ctl_we     (pgc_ctl_we),         // PGC subp/audio control stream (shared bus)
    .pgc_ctl_waddr  (pgc_ctl_waddr),
    .pgc_ctl_wdata  (pgc_ctl_wdata),
    .pgc_ctl_valid  (pgc_ctl_valid),
    .pgc_dom_tt     (pgc_dom_tt),

    // Linear transport (VCD/SVCD raw .bin + flat .mpg/.VOB): see the
    // lin_transport_ok gating below.
    .raw_mode_o           (raw_mode_w),
    .flat_seek_en         (ps_saw_pack),
    .lin_seek_ok_o        (lin_seek_ok_w),
    .lin_blk_o            (lin_blk_w),

    .debug_active         (streamer_active),
    .debug_sd_rd          (streamer_sd_rd),
    .debug_sd_ack         (streamer_sd_ack),
    .debug_cache_has_data (streamer_has_data),
    .debug_file_size      (streamer_file_size),
    .debug_total_sectors  (streamer_total_sectors),
    .debug_next_lba       (streamer_next_lba),
    .debug_state          (streamer_dbg_state),
    .debug_iso_mode       (iso_mode_w),
    .debug_iso_error      (iso_error_w),
    .debug_play_vtsn      (rdr_play_vtsn),
    .debug_target_vtsn    (rdr_target_vtsn),
    .dbg_pgcerr           (rd_dbg_pgcerr)
);

// =========================================================================
// Program Stream demux: mpg_streamer -> ps_stream_fifo -> ps_demux -> mpeg2video
//
// The FIFO converts mpg_streamer's one-cycle pulse interface into the held
// valid/ready handshake ps_demux expects (and never drops the in-flight byte).
// ps_demux strips PS pack/PES headers, forwarding only the video elementary
// stream to the decoder. PTS outputs now feed dvd/av_sync.sv (vid_pts anchors the
// STC; aud_frame_pts tags each audio_ring frame). aud_ready is tied high so audio
// PES never stalls the shared in_ready.
// =========================================================================
ps_stream_fifo ps_stream_fifo_inst (
    .clk          (clk_sys),
    .rst_n        (pipe_rst_n),

    .wr_data      (stream_data),
    .wr_en        (stream_valid),
    .almost_full  (fifo_almost_full),

    .out_byte     (demux_in_byte),
    .out_valid    (demux_in_valid),
    .out_ready    (demux_in_ready)
);

// FIFO read side is consumed by ps_demux.
assign demux_in_ready = ps_demux_in_ready;

ps_demux ps_demux_inst (
    .clk          (clk_sys),
    .rst_n        (pipe_rst_n),

    // Input side <- ps_stream_fifo
    .in_byte      (demux_in_byte),
    .in_valid     (demux_in_valid),
    .in_ready     (ps_demux_in_ready),

    // O[8:6]: which audio substream/track to forward (default 0 = substream 0x80).
    .aud_track    (aud_track_eff),   // Phase 4: SetSTN (SPRM1) wins when set

    // Subpicture (subtitle) substream select: O[15] enable, O[26:24] track (0x20+trk).
    // Routes the selected 0x20-0x3F substream out to spu_decode (dvd/subpicture.md).
    .sp_track     (sp_track_eff),    // Phase 4: SetSTN (SPRM2) wins when set
    // HW round 1: this DEMUX-level gate also had to learn the menu force-
    // enable - with subtitles Off it discarded the button subpicture PES
    // before spu_decode ever saw it (highlight only appeared if subs were on
    // at menu load). sp_en = O[15] | menu-up, defined at the transport block.
    .sp_enable    (sp_route_en),

    // Video ES -> decoder-clock CDC FIFO (vidfeed_dc below). The decoder now runs
    // on clk_dec (81 MHz) while ps_demux is on clk_sys (27 MHz), so the ES byte
    // stream crosses domains through a dual-clock FIFO. vid_ready = FIFO not full.
    .vid_byte     (ps_vid_byte),
    .vid_valid    (ps_vid_valid),
    .vid_ready    (vidfeed_wr_ready),

    // Audio path -> audio_ring (clk_sys). aud_ready stays high (audio_ring
    // accepts always and drops-on-full) so audio can never stall the shared
    // in_ready / video path.
    .aud_byte         (ps_aud_byte),
    .aud_valid        (ps_aud_valid),
    .aud_type         (ps_aud_type),
    .aud_frame_start  (ps_aud_frame_start),
    .aud_ready        (ps_aud_ready),

    // PTS for A/V sync (dvd/av_sync.sv). vid_pts anchors the STC; aud_frame_pts
    // stamps each audio_ring frame so the genlock loop can compare them.
    .vid_pts          (ps_vid_pts),
    .vid_pts_valid    (ps_vid_pts_valid),
    .aud_pts          (),                 // per-pulse aud PTS unused; frame-tagged below
    .aud_pts_valid    (),
    .aud_frame_pts       (ps_aud_frame_pts),
    .aud_frame_pts_valid (ps_aud_frame_pts_valid),

    // NAV-pack PCI payload -> nav_pci (Phase-3 disc-menu buttons)
    .pci_enable       (menus_on),
    .pci_byte         (ps_pci_byte),
    .pci_valid        (ps_pci_valid),
    .pci_frame_start  (ps_pci_frame_start),

    // NAV-pack DSI payload -> nav_dsi (Phase-7 nav foundation: seek/time/angle).
    // Always enabled (independent of menus): the DSI carries the current-time
    // readout even during plain title playback.
    .dsi_enable       (1'b1),
    .dsi_byte         (ps_dsi_byte),
    .dsi_valid        (ps_dsi_valid),
    .dsi_frame_start  (ps_dsi_frame_start),

    // Subpicture (subtitle) SPU payload -> spu_decode (clk_sys)
    .sp_byte          (ps_sp_byte),
    .sp_valid         (ps_sp_valid),
    .sp_frame_start   (ps_sp_frame_start),
    .sp_pts           (ps_sp_pts),
    .sp_pts_valid     (ps_sp_pts_valid),

    // LPCM word length (sub-header byte +5) -> dvd_audio_decode/lpcm_unpack.
    // Track-stable, so wired live (not threaded through the ring): settles well
    // before samples drain, and track switches reset audio_ring+dvd_audio_decode.
    .aud_lpcm_quant   (ps_aud_lpcm_quant),

    // CSS detection pulse -> the css_scrambled sticky latch below
    .pes_scrambled    (ps_pes_scrambled),
    .saw_pack         (ps_saw_pack)
);

// =========================================================================
// CSS-SCRAMBLED SOURCE DETECTION. A CSS-encrypted rip (raw disc copy without
// decryption — VLC plays it because libdvdcss decrypts on the fly; this core
// never sees keys BY DESIGN, decryption is a PC-side rip step) decodes as
// green macroblock garbage + loud audio static. Detect it from the PES
// headers (PES_scrambling_control != 0; headers themselves are never
// scrambled), warn via the transport HUD popup ("CSS ENCRYPTED", persistent,
// visible in menus too), and MUTE both audio paths (decode PCM forced to 0;
// passthrough emits PCM-silence bursts while draining the ring normally).
// Video keeps playing — the ~80% unscrambled sectors let the user identify
// the disc. The latch lives HERE (not in ps_demux, which resets on every
// jump via pipe_rst_n) and clears only on a fresh media mount, so the mute
// can't flap (and leak static pops) across menu jumps and seeks. A 4-pack
// threshold debounces against stray corruption; at real CSS density (~20%
// of packs) it trips within a few sectors of mount.
// =========================================================================
wire ps_pes_scrambled;
wire ps_saw_pack;
reg  [2:0] css_det_cnt;
reg        css_scrambled;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        css_det_cnt   <= 3'd0;
        css_scrambled <= 1'b0;
    end else if (start_streaming) begin      // fresh media mount: re-evaluate
        css_det_cnt   <= 3'd0;
        css_scrambled <= 1'b0;
    end else if (ps_pes_scrambled && !css_scrambled) begin
        css_det_cnt <= css_det_cnt + 3'd1;
        if (css_det_cnt == 3'd3) css_scrambled <= 1'b1;   // 4th scrambled PES
    end
end

// =========================================================================
// Phase-2 failure messaging (docs/roadmap.md "Public alpha release prep").
// Three failure modes used to produce NO explanation on screen, each an
// undiagnosable bug report. All three reuse the CSS popup path (PR #160).
// =========================================================================

// (A) Unplayable image. dvd_iso_reader falls back to whole-file LINEAR
// streaming for anything that is not ISO9660 — which is the INTENDED path for
// a bare .VOB/.mpg/.m2v, and those decode within a second. An image the reader
// cannot navigate (UDF-only — 0/34 in the library census but real in the wild —
// or a truncated/garbage file) takes the SAME path and never produces a
// picture. So the discriminator is deliberately NOT the file extension
// (hps_io's ioctl_file_ext packing is unverified here, and guessing it risks
// firing on every .VOB) but BEHAVIOUR: flat-file path AND still no video after
// IMG_WD. Sticky until the next load. A valid ISO holds the counter cleared via
// iso_mode_w, so this can only fire on the fallback path.
// ⚠ media_seen (HW round 1, 2026-08-23): the watchdog must NOT run before the
// user has actually mounted something. Without this gate a freshly-loaded core
// sitting at the file browser with NO image selected satisfies "flat-file path
// AND no video" trivially, so it latched UNSUPPORTED IMAGE after 5 s every time
// — the failure message as a boot screen. Sticky from the first mount; the
// re-arm on each subsequent mount is what actually clears the latch.
// ⚠ STREAMING TIME, NOT WALL TIME (HW round 2, 2026-08-25): the window used to
// run on wall time from the mount, so an image served off a slow share (user
// report: a NAS whose drives spin up on first access) burned the entire 5 s
// before the FIRST BYTE ever arrived — UNSUPPORTED IMAGE latched, the image then
// loaded fine, and the sticky popup sat over correct playback. Two changes fix
// that class of false positive for good:
//   (1) the window only advances while sector data is ACTUALLY BEING DELIVERED
//       (a sd_buff_wr write within IMG_IDLE). Any delivery stall — spin-up, a
//       slow share, a re-seek — freezes the count instead of spending it, so the
//       watchdog measures "streamed this long without a picture", which is the
//       thing it was always trying to say.
//   (2) the window is widened 5 s -> ~20 s of that active streaming. An
//       unplayable image is not urgent to report; a wrong report is expensive.
// And the latch now SELF-RETRACTS on video_live: the message asserts "this image
// never produces a picture", so a decoded frame disproves it by construction and
// it must not outlive that. Belt-and-braces against any future timing surprise.
localparam [29:0] IMG_WD   = 30'd540_000_000;      // ~20 s of ACTIVE streaming @ 27 MHz
localparam [24:0] IMG_IDLE = 25'd13_500_000;       // ~0.5 s with no delivered data = stalled
reg [29:0] img_wd_cnt;
reg [24:0] img_idle_cnt;                           // saturating "time since last sector byte"
reg        img_unplayable;
reg        media_seen;
wire       img_streaming = (img_idle_cnt != IMG_IDLE);
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        img_wd_cnt <= 30'd0; img_idle_cnt <= IMG_IDLE;
        img_unplayable <= 1'b0; media_seen <= 1'b0;
    end else begin
        // Delivery-activity detector (free-running, mount-independent): every
        // sector-buffer write re-arms it; it saturates at IMG_IDLE = "nothing has
        // arrived for ~0.5 s" = the stream is stalled, not slow.
        if (sd_buff_wr)                     img_idle_cnt <= 25'd0;
        else if (img_idle_cnt != IMG_IDLE)  img_idle_cnt <= img_idle_cnt + 25'd1;

        if (start_streaming) begin                    // fresh mount: re-arm
            img_wd_cnt <= 30'd0; img_unplayable <= 1'b0; media_seen <= 1'b1;
        end else if (!media_seen || video_live_s2 || iso_mode_w) begin
            img_wd_cnt <= 30'd0;                      // idle, playing, or a real ISO
            if (video_live_s2) img_unplayable <= 1'b0;   // a picture disproves the verdict
        end else if (!img_streaming) begin
            // Delivery stalled: hold the window rather than spend it. This is the
            // NAS spin-up case and it must not count against the image.
        end else if (img_wd_cnt == IMG_WD) begin
            img_unplayable <= 1'b1;
        end else begin
            img_wd_cnt <= img_wd_cnt + 30'd1;
        end
    end
end

// (B) Unsupported audio format. The IFO's per-track audio_format (VTSI_MAT
// @515+, already parsed for track enumeration in PR #100) is authoritative and
// known at mount, so this needs no PES sniffing. Format 2 (MPEG-1 Layer II)
// NOW DECODES in fabric (feature/mpeg1-codecs: ps_demux routes 0xC0-0xC7 ->
// mp2_reframer -> dvd/mp2/mp2_decode.sv), so the notice is narrowed to
// format 3 only (MPEG-2 multichannel extension, stream_id 0xC8-0xDF — still
// skipped; its backwards-compatible CORE stream would be 0xC0 MP2, but a
// format-3 track's core is on the SAME 0xC0+n id only for 7.1 authoring
// variants we can't verify without a disc, so keep the honest notice).
// Suppressed when the user has muted audio anyway (O5 Off) or is in S/PDIF
// passthrough, where the receiver reports the format itself.
// ⚠ ~css_scrambled (HW round 1, 2026-08-23): on a CSS-scrambled rip the audio
// is muted by the CSS path anyway, so an audio-FORMAT notice is both redundant
// and actively misleading about the cause. CSS is the root cause; suppress this
// under it. (The IFO itself is never scrambled, so attr_a_fmt stays truthful —
// it just isn't the user's problem on such a disc.)
wire aud_unsupported = iso_mode_w & nav_ready_w & aud_dec_en & ~css_scrambled &
                       (attr_a_fmt_w == 3'd3);

// (C) Title-VTS notice — largest-VTS heuristic path ONLY. With Disc Menus On
// (the default since PR #179) the disc's own VM picks the title, so the
// heuristic that is documented to pick the wrong main title on some discs only
// runs with menus Off. Announce the pick THERE, so a wrong title is
// self-evident and the P1 "Title VTS" override becomes discoverable. Gating it
// this way keeps the notice off the default path, where it would just be noise
// over the disc's own menu. One pulse per mount.
reg  nav_ready_q, vts_evt_r;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        nav_ready_q <= 1'b0; vts_evt_r <= 1'b0;
    end else begin
        nav_ready_q <= nav_ready_w;
        vts_evt_r   <= nav_ready_w & ~nav_ready_q & ~menus_on & iso_mode_w;
    end
end

// =========================================================================
// AC-3 reframer (dvd/ac3_reframer.sv): re-frame the demuxed AC-3 byte stream on
// AC-3 FRAME (0x0B77) boundaries before audio_ring, so audio_ring's drop unit is a
// whole AC-3 frame instead of a PES chunk. An overflow drop then becomes a clean,
// silent gap (ac3_front resyncs on the next sync) instead of a non-aligned hole
// that desyncs ac3_front -> self-heal reset -> audible POP (the static-pops root
// cause). Transparent 1-byte passthrough; LPCM/DTS frame_start passes through
// unchanged. See dvd/ac3_reframer.sv + docs/fabric_audio.md §"AC-3 reframer".
// =========================================================================
// ac3_reframer -> dts_reframer -> audio_ring. Each reframer regenerates
// frame_start only for its own codec and passes the other codec through
// unchanged, so chaining them makes audio_ring see whole AC-3 AND whole DTS
// frames (the DTS frame boundary is what the IEC 61937 passthrough burst needs).
wire [7:0]  ar_aud_byte;            // ac3_reframer output (into dts_reframer)
wire        ar_aud_valid;
wire [1:0]  ar_aud_type;
wire        ar_aud_frame_start;
wire [32:0] ar_aud_frame_pts;
wire        ar_aud_frame_pts_valid;

wire [7:0]  dr_aud_byte;            // dts_reframer output (into mp2_reframer)
wire        dr_aud_valid;
wire [1:0]  dr_aud_type;
wire        dr_aud_frame_start;
wire [32:0] dr_aud_frame_pts;
wire        dr_aud_frame_pts_valid;

wire [7:0]  rf_aud_byte;            // mp2_reframer output (into audio_ring)
wire        rf_aud_valid;
wire [1:0]  rf_aud_type;
wire        rf_aud_frame_start;
wire [32:0] rf_aud_frame_pts;
wire        rf_aud_frame_pts_valid;

// ⚠️ HANDSHAKE FIX (2026-07-02): ps_demux's aud_valid is a HELD level (high the whole
// time a byte is offered; ps_demux.sv line "aud_valid = (state==S_AUDIO_DATA) && in_valid"),
// while the reframer/ring have NO ready input and treat every valid cycle as a NEW byte.
// That was safe when aud_ready was tied high (a held byte lasted exactly one cycle), but
// with the demux backpressure a stall made ONE held byte duplicate at 27 MHz — flooding
// the reframer with garbage, blowing its frame-length lock, and starving the ring (the
// constant split-second audio dropouts). Qualify with aud_ready so downstream sees each
// byte exactly once: a transfer happens precisely when ps_demux itself advances
// (in_valid && in_ready, where in_ready = aud_ready during S_AUDIO_DATA).
wire ps_aud_xfer = ps_aud_valid && ps_aud_ready;

ac3_reframer ac3_reframer_inst (
    .clk                (clk_sys),
    .rst_n              (reset_n),        // reset only on core reset - self-heals on the next 0x0B77 (no per-jump reset = no re-sync pop)
    .in_byte            (ps_aud_byte),
    .in_valid           (ps_aud_xfer),
    .in_type            (ps_aud_type),
    .in_frame_start     (ps_aud_frame_start),
    .in_frame_pts       (ps_aud_frame_pts),
    .in_frame_pts_valid (ps_aud_frame_pts_valid),
    .out_byte            (ar_aud_byte),
    .out_valid           (ar_aud_valid),
    .out_type            (ar_aud_type),
    .out_frame_start     (ar_aud_frame_start),
    .out_frame_pts       (ar_aud_frame_pts),
    .out_frame_pts_valid (ar_aud_frame_pts_valid)
);

// DTS reframer (dvd/dts_reframer.sv): re-frame DTS on 0x7FFE8001 core-sync
// boundaries so audio_ring / iec61937_wrap see whole DTS frames (AC-3 passes
// through untouched). See docs/iec61937.md.
dts_reframer dts_reframer_inst (
    .clk                (clk_sys),
    .rst_n              (reset_n),        // reset only on core reset - self-heals on the next 0x7FFE8001
    .in_byte            (ar_aud_byte),
    .in_valid           (ar_aud_valid),
    .in_type            (ar_aud_type),
    .in_frame_start     (ar_aud_frame_start),
    .in_frame_pts       (ar_aud_frame_pts),
    .in_frame_pts_valid (ar_aud_frame_pts_valid),
    .out_byte            (dr_aud_byte),
    .out_valid           (dr_aud_valid),
    .out_type            (dr_aud_type),
    .out_frame_start     (dr_aud_frame_start),
    .out_frame_pts       (dr_aud_frame_pts),
    .out_frame_pts_valid (dr_aud_frame_pts_valid)
);

// MP2 reframer (dvd/mp2_reframer.sv): re-frame MPEG-1 Layer II (T_MP2, DVD
// stream_id 0xC0+n) on real frame boundaries — 15-bit qualified sync +
// frame-length lock — so audio_ring's overflow drop unit is a whole MP2 frame.
// AC-3/DTS/LPCM pass through untouched. See docs/mpeg1.md A.3.
mp2_reframer mp2_reframer_inst (
    .clk                (clk_sys),
    .rst_n              (reset_n),        // reset only on core reset - self-heals on the next 0xFFFx
    .in_byte            (dr_aud_byte),
    .in_valid           (dr_aud_valid),
    .in_type            (dr_aud_type),
    .in_frame_start     (dr_aud_frame_start),
    .in_frame_pts       (dr_aud_frame_pts),
    .in_frame_pts_valid (dr_aud_frame_pts_valid),
    .out_byte            (rf_aud_byte),
    .out_valid           (rf_aud_valid),
    .out_type            (rf_aud_type),
    .out_frame_start     (rf_aud_frame_start),
    .out_frame_pts       (rf_aud_frame_pts),
    .out_frame_pts_valid (rf_aud_frame_pts_valid)
);

// =========================================================================
// Audio frame ring buffer (dvd/audio_ring.sv). Captures complete audio frames
// from the AC-3 reframer (AC-3-frame-granular). Single clk_sys domain.
//
// Its READ SIDE is now drained by the in-fabric audio decoder (dvd/dvd_audio_decode
// .sv) which decodes AC-3 + LPCM and drives AUDIO_L/R directly. See
// docs/fabric_audio.md. (The old DDR3-ring + HPS-daemon path it used to feed is
// retired — see docs/audio_ddr_path.md.)
//
// FLOW CONTROL (2026-07-02, revises the old "aud_ready always high" invariant):
// when the ring is almost full, ps_demux's aud_ready is deasserted, stalling the
// shared demux STREAM until the audio decoder drains — the DVD STD model. An
// overflow drop is a whole AC-3 frame = an audible 32 ms gap (the low-fps
// "stutter"); backpressure loses nothing, and the VIDEO PICTURE is unaffected
// because the video decoder rides its multi-MB VBUF bitstream backlog through
// the stall. Guard: a ~1.2 s drain watchdog — if the audio side stops popping
// frames (O5 muted, DTS-only stream, wedged decoder), backpressure is released
// and the ring reverts to drop-on-full, so the stream can never wedge video.
// The audio NCO itself stays UNTOUCHED at 48 kHz (same crystal as the raster,
// and the governor plays content at exact rate ratios, so no drift to correct).
// =========================================================================
// audio_ring read side -> dvd_audio_decode
wire  [7:0] aud_ring_byte;
wire        aud_ring_valid, aud_ring_ready;
wire        aud_frame_valid, aud_frame_pop;
wire [15:0] aud_frame_len;
wire  [1:0] aud_frame_type;

// Ring read-side arbitration: in Decode mode the in-fabric decoder drains the
// ring; in Passthru mode the IEC 61937 formatter does. Only the selected
// consumer's ready/pop reach the ring (aud_frame_pop still re-arms the demux
// backpressure watchdog either way — the STD model holds in both modes).
wire        dec_ring_ready, dec_frame_pop;   // dvd_audio_decode's ring handshake
wire        pass_ring_ready, pass_frame_pop; // iec61937_wrap's ring handshake
wire        pass_hold_active;                // wrapper A/V-sync hold level (watchdog feed)
assign aud_ring_ready = pass_mode ? pass_ring_ready : dec_ring_ready;
assign aud_frame_pop  = pass_mode ? pass_frame_pop  : dec_frame_pop;

// BYTE_DEPTH raised 8192->32768 (FRAME_DEPTH 64->128) for more elastic buffering
// of compressed frames ahead of the in-fabric decoder (rides out bursty demux
// delivery from the frame-rate governor; near-empty in steady state so it adds no
// latency, just a higher overflow ceiling).
// BYTE_DEPTH 32 KB. (An earlier 64 KB bump chased a WRONG theory - that the deep
// video buffer backpressured the shared demux and starved this ring; HW disproved it.
// The real T2-menu audio dropout is the audio pipeline being RESET at every keep_vbuf
// menu->menu transition while the video buffer is kept - fixed by aud_rst_n excluding
// keep_vbuf jumps below, not by ring size. See docs/dvd_menu_refinements.md §5d.)
audio_ring #(.BYTE_DEPTH(32768), .FRAME_DEPTH(128)) audio_ring_inst (
    .clk              (clk_sys),
    .rst_n            (aud_rst_n),       // audio-only: also resets on an audio-track switch

    .aud_byte         (rf_aud_byte),
    .aud_valid        (rf_aud_valid),
    .aud_type         (rf_aud_type),
    .aud_frame_start  (rf_aud_frame_start),
    .drop_pulse       (aud_drop_pulse),      // §5d: drop menu-transition splice frames
    .aud_frame_pts       (rf_aud_frame_pts),
    .aud_frame_pts_valid (rf_aud_frame_pts_valid),
    .aud_ready        (),                    // ring-internal accept (always high); demux
                                             // flow control uses almost_full below

    .almost_full      (aud_ring_almost_full),

    // Read side -> dvd_audio_decode (in-fabric AC-3 + LPCM).
    .out_byte         (aud_ring_byte),
    .out_valid        (aud_ring_valid),
    .out_ready        (aud_ring_ready),
    .frame_valid      (aud_frame_valid),
    .frame_len        (aud_frame_len),
    .frame_type       (aud_frame_type),
    .frame_pts        (aud_frame_pts_w),
    .frame_pts_valid  (aud_frame_pts_valid_w),
    .frame_pop        (aud_frame_pop),

    .frames_available (aud_frames_avail),
    .bytes_available  (aud_bytes_avail),
    .overflow_count   (aud_overflow_cnt)
);

// Demux backpressure (see FLOW CONTROL note above): stall ps_demux's audio path —
// and with it the shared stream — while the ring is almost full AND the audio
// decoder has popped a frame recently (drain watchdog armed). At startup the
// watchdog is unarmed (bypassed: drop-on-full, exactly the old behaviour) until
// the first frame_pop proves the decode side is alive.
wire        aud_ring_almost_full;
reg  [24:0] aud_bp_wd = 25'd0;                 // ~1.24 s @ 27 MHz
wire        aud_bp_armed = (aud_bp_wd != 25'd0);
always @(posedge clk_sys) begin
    if (~reset_n)            aud_bp_wd <= 25'd0;
    // (Re)arm on a pop (consumer draining) — or while the PASSTHROUGH wrapper is
    // deliberately HOLDING the front frame (A/V sync hold). A hold produces no
    // pop, so before this term the watchdog read every passthrough startup hold
    // as a wedged consumer, left backpressure disengaged (it arms only on the
    // first pop), and the ring dropped whole frames at the free-running demux
    // rate — MEASURED at ~25 frames/s for the first ~46 s of a title (overlay
    // row 13 → 1130 drops), each dropped span a forward PTS hole whose far side
    // is a multi-second silence gap on the wire = the receiver lock flap
    // (docs/iec61937.md "FLAP ROOT CAUSE"). The hold is bounded by the STC
    // reaching the front frame's PTS, so this cannot wedge the stream on any
    // stream whose video plays; the decode path is unaffected (its stale-skip
    // pops keep the watchdog fed the same way it always was).
    else if (aud_frame_pop || (pass_mode && pass_hold_active))
                             aud_bp_wd <= 25'h1FFFFFF;
    // Freeze the drain watchdog while paused: the audio decoder is held (no
    // frame_pop), so without this the watchdog would expire after ~1.24 s,
    // release backpressure, and let the ring drop frames -> an audible gap /
    // A/V drift on resume from a long pause. Holding it armed keeps the demux
    // backpressured (everything is frozen anyway), so no audio is lost.
    else if (aud_bp_armed && ~pause_aud) aud_bp_wd <= aud_bp_wd - 25'd1;
end
assign ps_aud_ready = ~(aud_ring_almost_full && aud_bp_armed);

// =========================================================================
// In-fabric audio decode: audio_ring read side -> dvd_audio_decode -> AUDIO_L/R.
// Decodes AC-3 (ac3_front + pcm_out, 5.1->stereo downmix) and LPCM (lpcm_unpack)
// entirely in fabric, replacing the old DDR3-ring + HPS-daemon path. DTS frames
// are dropped (no fabric DTS decoder yet; future: IEC 61937 bitstream to the
// Digital I/O board). Gated by "O5,Audio" (default On). See docs/fabric_audio.md.
// =========================================================================
wire        aud_dec_en = ~status[5] & ~pass_mode;   // O5 On (default) AND not passthrough
wire        ac3_synced_dbg, ac3_err_dbg;
wire [15:0] dbg_ac3_resets, dbg_ac3_err_resets;

dvd_audio_decode #(.CLK_HZ(27000000), .AUD_HZ(48000)) dvd_audio_decode_inst (
    .clk         (clk_sys),
    .rst_n       (aud_rst_n),            // audio-only: also resets on an audio-track switch
    .enable      (aud_dec_en),
    .pause       (pause_aud),    // freeze/silence audio while paused OR a seek gesture is held
    .ring_byte   (aud_ring_byte),
    .ring_valid  (aud_ring_valid),
    .ring_ready  (dec_ring_ready),
    .frame_valid (aud_frame_valid),
    .frame_len   (aud_frame_len),
    .frame_type  (aud_frame_type),
    .lpcm_quant  (ps_aud_lpcm_quant),   // LPCM word length -> lpcm_unpack (20/24-bit depack)
    .frame_pts       (aud_frame_pts_w),
    .frame_pts_valid (aud_frame_pts_valid_w),
    .frame_pop   (dec_frame_pop),
    // 48 kHz NCO trim: 0 (free-run) when Audio Genlock=Off; otherwise av_sync's
    // genlock slew. See dec_nco_trim above.
    .nco_trim           (dec_nco_trim),
    .dispatch_pts       (aud_dispatch_pts),
    .dispatch_pts_valid (aud_dispatch_pts_valid),
    // PTS-scheduled playback START (lip-sync v3): the 48 kHz drain is held until
    // STC >= first_buffered_pts + av_ofs, setting phase at the PCM-FIFO EXIT (the
    // only place it's settable); underruns re-arm so audio re-enters at phase.
    // Off together with the genlock (O13) so free-run stays a clean diagnostic.
    // ALSO free-run while a DISC MENU is active: menu audio is background music (no
    // lip-sync), and in Smooth mode (keep_vbuf) the video buffer runs deep during a
    // transition so the STC lags - STC-gating the menu audio to that lagging clock
    // starves the drain = the "audio dropout during T2 transitions". Free-running the
    // menu audio decouples it (harmless in Snappy, where the video is already current).
    // docs/dvd_menu_refinements.md §5c.
    .sched_en           (~av_freerun & ~(menus_on & menu_active)),
    .stc_anchored       (av_stc_anchored),
    // Arrival front for the mid-play catch-up (Shea-Stadium ratchet fix): the
    // newest PARSE-time audio PTS — audio may skip forward only when current
    // audio has actually arrived. See head_catchup in dvd_audio_decode.sv.
    .arr_pts            (ps_aud_frame_pts),
    .arr_pts_valid      (ps_aud_frame_pts_valid),
    .video_live         (video_live_s2),   // start audio together with the (STD-held) video start;
                                           // also confines the stale-skip to the load window
                                           // (treadmill fix — see head_stale in dvd_audio_decode.sv)
    .stc                (av_stc),
    .av_ofs             (av_ofs),
    .audio_l     (dec_audio_l),
    .audio_r     (dec_audio_r),
    .ac3_synced  (ac3_synced_dbg),
    .ac3_err     (ac3_err_dbg),
    .dbg_ac3_resets    (dbg_ac3_resets),
    .dbg_ac3_err_resets (dbg_ac3_err_resets),
    .dbg_draining       (dbg_aud_draining),
    .dbg_play_pts_valid (dbg_aud_play_pts_valid),
    .dbg_armed_data     (dbg_aud_armed_data),
    .dbg_skip_run       (dbg_aud_skip_run),
    .dbg_play_pts       (dbg_aud_play_pts),
    // drift-instrument round (overlay rows 13/16/17/18; see the overlay comment)
    .dbg_rearm_cnt      (dbg_aud_rearm_cnt),
    .dbg_fbrel_cnt      (dbg_aud_fbrel_cnt),
    .dbg_skip_cnt       (dbg_aud_skip_cnt),
    .dbg_play_err       (dbg_aud_play_err),
    .dbg_cur_codec      (dbg_cur_codec_w),
    .dbg_mp2_avalid     (dbg_mp2_avalid_w),
    .dbg_mp2_s_nz       (dbg_mp2_s_nz_w),
    .dbg_mp2_pcm_nz     (dbg_mp2_pcm_nz_w)
);
wire [32:0] dbg_aud_play_pts;
wire [3:0]  dbg_aud_rearm_cnt, dbg_aud_fbrel_cnt;
wire [7:0]  dbg_aud_skip_cnt;
wire [15:0] dbg_aud_play_err;

// =========================================================================
// IEC 61937 S/PDIF passthrough (dvd/iec61937_wrap.sv, Path B). In Passthru
// mode (O6) this is the ring's reader: it wraps the UNDECODED AC-3/DTS frames
// in IEC 61937 data-bursts and biphase-encodes them onto SPDIF_PASS (clk_audio
// domain). sys_top muxes SPDIF_PASS onto the S/PDIF pin while SPDIF_PASS_EN.
// frame_samples=0 -> the formatter uses the codec default burst period (AC-3
// 1536; DTS 512 until the DTS reframer supplies the real sample count).
// =========================================================================
// clk_audio (24.576 MHz) reset synchronizer: async assert, sync deassert.
reg [1:0] aud_rsync = 2'b00;
always @(posedge CLK_AUDIO or negedge aud_rst_n)
    if (!aud_rst_n) aud_rsync <= 2'b00;
    else            aud_rsync <= {aud_rsync[0], 1'b1};
wire rst_audio_n = aud_rsync[1];

// Flap-probe burst classification taps (fed to the DEBUG_OVERLAY gap/underrun
// counters, rows 23/24 in Passthru; declared unconditionally like the other
// dbg wires so the ports are always connected).
wire bs_burst_stb, bs_burst_real, bs_burst_held;

iec61937_wrap #(.FIFO_AW(8)) iec61937_wrap_inst (
    .clk_sys      (clk_sys),
    .rst_sys_n    (aud_rst_n),
    .enable       (pass_mode),
    .byte_swap    (pass_bswap),
    .mute_i       (css_scrambled),   // CSS source: drain frames, emit PCM silence
    .ring_byte    (aud_ring_byte),
    .ring_valid   (aud_ring_valid),
    .ring_ready   (pass_ring_ready),
    .frame_valid  (aud_frame_valid),
    .frame_len    (aud_frame_len),
    .frame_type   (aud_frame_type),
    .frame_samples(16'd0),
    .frame_pts    (aud_frame_pts_w),
    .frame_pts_valid(aud_frame_pts_valid_w),
    .frame_pop    (pass_frame_pop),
    // A/V sync: slave passthrough audio to the video STC (same as the decode
    // path) so it tracks the display timeline instead of the parse front.
    // MENU DOMAIN FREE-RUNS (2026-08-31): menus aren't lip-synced (the same
    // rule that forces av_vid_hold off for menu_active), and the §5d keep_vbuf
    // audio-continuity design preserves a near-full ring of OLD-loop-timeline
    // audio across menu->menu transitions — holding those frames against a
    // fresh post-transition anchor is a CIRCULAR STALL (hold -> ring full ->
    // backpressure -> demux jammed -> new menu's video can't parse -> no
    // vid_pts/STC -> hold persists), MEASURED wedged ~20 s on a T2 menu hop
    // until the next user jump reset it (docs/iec61937.md "menu freeze").
    // Free-running menus plays the continuity audio immediately (decode-path
    // parity) and cannot wedge; title entry pulses aud_flush, so title sync
    // re-arms cleanly.
    .sync_armed   (~av_freerun && ~menu_active),
    .stc_anchored (av_stc_anchored),
    .stc          (av_stc),
    .av_ofs       (av_ofs),
    .clk_audio    (CLK_AUDIO),
    .rst_audio_n  (rst_audio_n),
    .spdif_o      (SPDIF_PASS),
    .hdmi_sck_o   (HDMI_BS_SCK),
    .hdmi_ws_o    (HDMI_BS_WS),
    .hdmi_sd_o    (HDMI_BS_SD),
    .bs_l_o       (),
    .bs_r_o       (),
    .bs_nonpcm_o  (),
    .bs_stb_o     (bs_stb_w),
    .dbg_word     (),
    .dbg_word_stb (),
    .dbg_burst_stb (bs_burst_stb),
    .dbg_burst_real(bs_burst_real),
    .dbg_burst_held(bs_burst_held),
    .hold_active_o (pass_hold_active)
);

// =========================================================================
// STD MUX-LEAD HOLD (2026-07-02): DVD interleaves audio ~0.5 s BEHIND the video
// for the same presentation time (video needs VBV lead), so a real player's
// System Target Decoder displays video ~0.5 s behind the demux position.
// Displaying the first decoded frame immediately put our video that far AHEAD
// of the audio's arrival timeline — audio trailed by the per-disc mux depth
// (Matrix +470 ms measured by bench/dvd/aud_pts_chain_tb on the real VOB) and
// no output-side scheduling could fix it. Hold the governor's FIRST pickup
// until the audio side has latched a dispatchable frame at/past the STC anchor
// (play_pts caught up = the audio for the first displayable frame has ARRIVED;
// the stale-skip has already discarded the pre-anchor backlog by then). The
// VBUF flood cushion buffers the deferred video. Fallback ~1.24 s so an
// audio-less / PTS-less clip (raw ES bring-up files) can't hold video forever.
// Asserted from the clip-load flush; the rising edge also re-arms video_live
// inside the governor, so a reload behaves exactly like a cold start.
// =========================================================================
reg         av_vid_hold;
reg  [24:0] av_vid_hold_tmr;                    // 2^25 / 27 MHz ~ 1.24 s fallback
wire signed [34:0] play_vs_anchor =
    $signed({2'b0, dbg_aud_play_pts}) - $signed({2'b0, av_stc});
wire aud_caught = av_stc_anchored && dbg_aud_play_pts_valid &&
                  (play_vs_anchor >= -35'sd4500);   // within ~50 ms of the anchor
always @(posedge clk_sys) begin
    // MENUS: never assert the STD mux-lead hold. It exists to defer the first
    // FEATURE frame ~0.5 s so lip-synced audio (muxed behind the video) can catch
    // up; menus aren't lip-synced. Worse, it re-arms on EVERY load flush and, when
    // `aud_caught` never fires (menus have little/no dispatchable audio), holds the
    // full ~1.24 s fallback PER keep_vbuf menu hop — freezing deep menus (numbers
    // never picked up) and keeping video_live=0 (which blocks the highlight render
    // gate + nav_pci fallback). Forcing it off for menu_active makes the menu
    // display immediately and video_live stay set. Titles are unaffected.
    // A file MOUNT cannot be swallowed by this branch even if a menu was up on
    // the old disc: the reader's `start` clears menu_dom (-> menu_active) on the
    // first cycle of the mount while pipe_rst_n stays low for ~64 cycles, so the
    // !pipe_rst_n arm below always latches the hold (verified 2026-08-28).
    if (menu_active) begin
        av_vid_hold     <= 1'b0;
        av_vid_hold_tmr <= '0;
    end else if (!pipe_rst_n) begin
        av_vid_hold     <= 1'b1;                // held from every load/reset
        av_vid_hold_tmr <= '0;
    end else if (av_vid_hold) begin
        av_vid_hold_tmr <= av_vid_hold_tmr + 1'b1;
        if (aud_caught || (&av_vid_hold_tmr)) av_vid_hold <= 1'b0;   // sticky-off until next load
    end
end
// 2-FF into the decoder clock for the governor
reg vid_hold_s1, vid_hold_s2;
always @(posedge clk_dec) begin
    vid_hold_s1 <= av_vid_hold;
    vid_hold_s2 <= vid_hold_s1;
end

// 2-FF the gamepad pause (clk_sys origin) into the decoder clock for the governor
// (resample_addrgen freezes the frame while paused; av_sync freezes the STC in
// clk_sys). pause changes at human speed, so a plain 2-FF sync is sufficient.
reg pause_s1, pause_dec;
always @(posedge clk_dec) begin
    pause_s1  <= pause_gov;   // manual pause OR a held seek gesture (freeze the governor frame)
    pause_dec <= pause_s1;
end

// 2-FF the resolved Film 24p/25p mode (clk_sys origin) into the decoder clock for the
// governor. In this mode the core raster IS the film rate (23.976/25 Hz), so
// resample_addrgen forces cur_show=1 (one decoded frame per refresh; ascal does the
// pulldown to HDMI). SHOW_N=1 is rate-agnostic, so the single filmp flag serves both
// NTSC 24p and PAL 25p. Slow-changing (human toggle or the hysteretic detector) + the
// modeline walk re-arms the raster on the same edge, so a plain 2-FF sync suffices.
// See docs/film_24p_plan.md §9.
reg filmp_s1_dec, filmp_dec;
always @(posedge clk_dec) begin
    filmp_s1_dec <= filmp_eff;
    filmp_dec    <= filmp_s1_dec;
end

// Drain-gate live-state debug taps from dvd_audio_decode. dbg_aud_play_pts /
// dbg_aud_play_pts_valid feed the STD mux-lead hold above (aud_caught); the
// draining/armed/skip taps stay wired for future diagnosis. The lip-sync drift
// saga is CLOSED (PR #62, flags_commit, round-12 HW-confirmed), so the
// drift-instrument overlay view that once displaced the AC-3 reset counters on
// rows 14/15 is retired — those rows are back to the AC-3 self-heal reset
// counters (see the overlay instantiation below).
wire dbg_aud_draining, dbg_aud_play_pts_valid, dbg_aud_armed_data, dbg_aud_skip_run;

// =========================================================================
// A/V sync (dvd/av_sync.sv): PTS-driven video-referenced STC + audio-NCO genlock.
// Anchors an STC to the video PTS, advances it one TICKS_PER_REFRESH per displayed
// image (refresh_tick = rising edge of core_v_sync, clk_sys / dot_clk domain), and
// slews the audio 48 kHz NCO (av_nco_trim) so the dispatched audio PTS tracks it.
// Gated by the same O5 Audio enable. See docs/av_sync.md.
// =========================================================================
reg  core_vs_prev_sys;
wire av_refresh_tick = ~core_vs_prev_sys & core_v_sync;   // one pulse per displayed image
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) core_vs_prev_sys <= 1'b0;
    else          core_vs_prev_sys <= core_v_sync;
end

av_sync #(.CLK_HZ(27000000), .AUD_HZ(48000),
          .REFRESH_MHZ(59940), .REFRESH_MHZ_PAL(50000)) av_sync_inst (
    .clk                (clk_sys),
    .rst_n              (pipe_rst_n),    // STC is video-continuous through an audio switch; no re-anchor needed
    .enable             (aud_dec_en),
    .pause              (pause_gov),     // manual pause / held seek gesture: freeze the presentation STC
    .refresh_50hz       (pal_eff),      // resolved PAL flag -> 50 Hz STC tick rate
    .refresh_24hz       (film24_eff),   // DVD-FORK (Film 24p Out): NTSC 23.976 Hz STC tick rate (wins over all)
    .refresh_25hz       (film25_eff),   // DVD-FORK (Film 25p Out): PAL 25.000 Hz STC tick rate (wins over refresh_50hz)
    // trim is retired (see dec_nco_trim above); lead only shapes the unused PI/drift
    // telemetry set-point, so feed 0 => drift output reads "0 = in sync".
    .lead_target        (16'd0),

    .vid_pts            (ps_vid_pts),
    .vid_pts_valid      (ps_vid_pts_valid),
    .refresh_tick       (av_refresh_tick),
    .video_live         (video_live_s2),    // STC holds at anchor until display shows a frame
    .dispatch_pts       (aud_dispatch_pts),
    .dispatch_pts_valid (aud_dispatch_pts_valid),
    .nco_trim           (av_nco_trim),
    .stc_anchored       (av_stc_anchored),
    .stc                (av_stc),
    .drift              (av_drift),
    .reanchor_count     (av_reanchor_cnt)
);

// Priority arbiter on the DDRAM port: decoder (mem_shim_burst) is the only master
// now (audio no longer writes to DDR3). The audio master inputs are tied off; the
// arbiter is retained so the proven decoder DDR path is untouched.
ddr_arb ddr_arb_inst (
    .clk               (clk_mem),
    .rst_n             (reset_n),
    // decoder master (from mem_shim_burst)
    .dec_address       (burst_ddr_addr),
    .dec_burstcount    (burst_ddr_burstcnt),
    .dec_read          (burst_ddr_read),
    .dec_write         (burst_ddr_write),
    .dec_writedata     (burst_ddr_writedata),
    .dec_byteenable    (burst_ddr_byteenable),
    .dec_waitrequest   (arb_dec_waitrequest),
    .dec_readdata      (arb_dec_readdata),
    .dec_readdatavalid (arb_dec_readdatavalid),
    // audio master tied off (in-fabric decode no longer writes DDR3)
    .aud_address       (29'd0),
    .aud_burstcount    (8'd1),
    .aud_write         (1'b0),
    .aud_writedata     (64'd0),
    .aud_byteenable    (8'h00),
    .aud_waitrequest   (),
    // slave side -> DDRAM
    .ddr_address       (arb_ddr_addr),
    .ddr_burstcount    (arb_ddr_burstcnt),
    .ddr_read          (arb_ddr_read),
    .ddr_write         (arb_ddr_write),
    .ddr_writedata     (arb_ddr_writedata),
    .ddr_byteenable    (arb_ddr_byteenable),
    .ddr_waitrequest   (DDRAM_BUSY),
    .ddr_readdata      (DDRAM_DOUT),
    .ddr_readdatavalid (DDRAM_DOUT_READY)
);

// =========================================================================
// Video ES clock-domain crossing: ps_demux (clk_sys 27 MHz) -> decoder (clk_dec
// 81 MHz, 3x27). The decoder was COMPUTE-bound at 27 MHz (bridge idle ~100%, core_busy
// high) — raising mpeg2video.clk (27->54->81) raises decode throughput, but its stream
// input now lives in the clk_dec domain, so the ES bytes must cross domains here.
// A dual-clock fifo_dc carries the byte; a 1-deep "head" register on the read side
// converts the FIFO's pull (rd_en -> data next cycle) into the held valid/consume
// handshake the decoder wants. The ES byte rate (a few Mbit/s) is tiny vs 81 MHz,
// so the adapter's <=1-byte-per-2-cycles ceiling is never a limit.
// =========================================================================
// dvd/vidfeed_cdc.sv: dual-clock FIFO + a one-byte-at-a-time pull adapter that is
// byte-exact (no drop/dup) under backpressure on both sides — verified by
// bench/dvd/vidfeed_cdc_tb.sv. (An earlier inline adapter dropped a byte when
// core_busy toggled mid-pop, garbling EVERY clip incl. susi.)
wire       vidfeed_wr_ready;
wire [7:0] dec_stream_data;
wire       dec_stream_valid;   // 1 = byte consumed by decoder this cycle

vidfeed_cdc vidfeed_cdc_inst (
    .rst_n    (reset_n),
    .wr_clk   (clk_sys),
    .wr_data  (ps_vid_byte),
    .wr_valid (ps_vid_valid),
    .wr_ready (vidfeed_wr_ready),
    .rd_clk   (clk_dec),
    .rd_data  (dec_stream_data),
    .rd_valid (dec_stream_valid),
    .rd_ready (~core_busy)
);

// =========================================================================
// MPEG2 Video Decoder Core
// =========================================================================
wire [1:0]  core_mem_cmd;
wire [21:0] core_mem_addr;
wire [63:0] core_mem_dta_out;
wire        core_mem_en;
wire        core_mem_valid;
wire [63:0] shim_mem_dta;
wire        shim_mem_en;
wire        shim_mem_almost_full;

wire [7:0] core_r, core_g, core_b;
wire       core_h_sync, core_v_sync;
wire [11:0] core_h_pos, core_v_pos;
wire [8:0]  core_init_cnt;
wire        core_sync_rst;
wire        core_vbw_almost_full;
wire       core_pixel_en;
wire [3:0]  shim_debug_state;
wire [1:0]  shim_debug_saved_cmd;
wire        shim_debug_sdram_busy;
wire        shim_debug_sdram_ack;
wire [15:0] shim_debug_rd_count;
wire [15:0] shim_debug_wr_count;
wire [15:0] shim_debug_rsp_count;
wire [15:0] shim_debug_read_pend_cycles;
wire [15:0] shim_debug_cache_missrate;   // {miss%, read-intensity} per window (row 6)

// =========================================================================
// DVD-FORK FIX (interlaced cadence): the native 480i/576i fields modeline
// (built as O9 "Interlaced Out", now driven by Video Output = Interlaced via il_eff)
// =========================================================================
// Interlaced DVD content (480i60) played JUDDERY at ~half temporal rate because
// the decoder defaults (reg_wr_en=0 => deinterlace=1, interlaced=0) WEAVE both
// fields into one progressive frame and show only 30 distinct frames/s — the
// 60-field motion is thrown away. Fix: when il_eff is on, switch the modeline to
// native 480i and force deinterlace OFF, so the resample emits TWO fields per
// decoded frame (TOP then BOTTOM), filling the 60 Hz output with 60 distinct
// motion phases. VGA_F1 tags the field; MiSTer's ascal scaler deinterlaces it
// for HDMI. Progressive 480p (O9=off) is the unchanged default/fallback.
//
// Mechanics on the 27 MHz dot clock: the decoder's pixel_repetition VID_MODE bit
// makes syncgen_intf.v (rtl/mpeg2/syncgen_intf.v:229-259) AUTO-DOUBLE every
// horizontal timing value. So we write the PROGRESSIVE NTSC horizontal values
// (matching rtl/mpeg2/modeline.v MODELINE_NTSC) and let pixel_repetition double
// them: line = (857+1)*2 = 1716 dots @27 MHz = 15.7 kHz (480i line rate).
// Vertical: with interlaced=1 syncgen halves only the *display* size
// (syncgen.v:137) to 240 visible lines/field; vertical_length and the vsync
// window are used raw, so we write per-FIELD values (262 lines/field => ~60
// fields/s). The progressive-mode writes reproduce MODELINE_NTSC EXACTLY
// (incl. VERT_RES=480, the strobe-fix value) so O9=off is identical to baseline.
//
// The decoder reg interface is in clk_dec; regfile.clk_en is tied 1, so we hold
// reg_wr_en across consecutive cycles with a changing reg_addr and each cycle
// latches a distinct register. A 6-step walk re-writes the whole modeline on any
// O9 change (and once after reset).
localparam [3:0] REG_WR_HOR      = 4'h1;
localparam [3:0] REG_WR_HOR_SYNC = 4'h2;
localparam [3:0] REG_WR_VER      = 4'h3;
localparam [3:0] REG_WR_VER_SYNC = 4'h4;
localparam [3:0] REG_WR_VID_MODE = 4'h5;
localparam [3:0] REG_WR_TRICK    = 4'hb;

wire il_out  = il_eff;       // native 480i (NTSC) / 576i (PAL) HDMI fields raster (see il_eff)
wire pal_out = pal_eff;      // resolved PAL flag: 720x576p @ 50 Hz (else NTSC 720x480p @ 59.94)
// DVD-FORK (single-raster analog, 2026-09-03): there is no separate CRT branch — the
// il_prev branch below IS the 15 kHz raster (pixrep + half-line), for HDMI and the
// analog pins alike (docs/single_raster_analog.md).
wire filmp_out = filmp_eff;  // Film 24p/25p: progressive-film raster (NTSC 875x1287 @ 23.976024, PAL 864x1250 @ 25.000; pal_prev picks the rate)

// CDC: 2-FF sync the (slow, static) toggles from clk_sys into clk_dec. The walk is
// re-kicked whenever ANY of the interlace / PAL / film modes change (or once at boot).
reg        il_s1, il_s2, il_prev, il_init;
reg        pal_s1, pal_s2, pal_prev;
reg        filmp_s1, filmp_s2, filmp_prev;
reg  [2:0] seq_step;       // 0..5 register-write walk
reg        seq_run;        // sequencer active (reg_wr_en held high while running)

// REG_WR_TRICK payload: [10]deinterlace [9:5]repeat_frame [4]persistence
//                       [3:1]source_select(0) [0]flush_vbuf(0).
// Interlaced mode forces deinterlace=0 (resample must emit raw fields); both
// modes keep persistence=1, repeat=0 — the regfile defaults.
wire [10:0] trick_w = { il_prev ? 1'b0 : 1'b1, // [10] deinterlace
                        5'b00000,             // [9:5] repeat_frame = 0
                        1'b1,                 // [4]  persistence = on
                        3'b000,               // [3:1] source_select
                        1'b0 };               // [0]  flush_vbuf

// Per-step register address + 32-bit payload. Uses il_prev (latched at walk
// start) not il_s2, so all 6 steps of a walk apply ONE consistent mode.
//   REG_WR_HOR     : [27:16]=horizontal_resolution [11:0]=horizontal_length
//   REG_WR_HOR_SYNC: [27:16]=horizontal_sync_start [11:0]=horizontal_sync_end
//   REG_WR_VER     : [27:16]=vertical_resolution   [11:0]=vertical_length
//   REG_WR_VER_SYNC: [27:16]=vertical_sync_start   [11:0]=vertical_sync_end
//   REG_WR_VID_MODE: [27:16]=horizontal_halfline   [2:0]={clip,pixrep,interlaced}
//   REG_WR_TRICK   : [10:0] trick_w
// The walk has these states (il = the 480i/576i half-line raster for HDMI AND analog):
//   pal_prev & filmp_prev   -> PAL  720x576p @ 25.000 (576 active, vtotal 1250 = 27 MHz
//                              / (864 x 1250) = 25.000 Hz exactly; ONLY VER differs from
//                              PAL 50p — hsync/VER_SYNC/VID_MODE reuse the PAL progressive
//                              values. Extra ~625 lines = back porch. ascal frame-doubles
//                              1:2 to 50 Hz HDMI.)
//   pal_prev=1              -> PAL  720x576p @ 50 Hz  (864x625 total @ 27 MHz = 50.0 Hz)
//   pal=0, il_prev=1        -> NTSC 720x480i @ 59.94  (HDMI: per-field, pixel_repetition
//                              doubled, halfline 0 so the receiver locks)
//   pal=0, il_prev=0        -> NTSC 720x480p @ 59.94  (the strobe-fix baseline)
//   filmp_prev=1 (NTSC)     -> NTSC 720x480p @ 23.976024 EXACT (480 active, htotal 875,
//                              vtotal 1287 = 27 MHz / (875 x 1287) = 24000/1001 Hz).
//                              VER_SYNC/VID_MODE reuse the progressive 480p values;
//                              extra ~762 lines + 17 dots/line = blanking.
//     ** DVD-FORK FIX (2026-08-02, A/V drift in 24p) — WHY 875 AND NOT 858: **
//     The audio NCO is a fixed 48 kHz off the same crystal (nco_trim is RETIRED —
//     see docs/av_sync.md), so the ONLY thing holding A/V together over a long title
//     is that the core raster period equals the true content rate. Every other mode
//     hits its rate exactly (480p 858x525 = 59.94006, PAL 864x625 = 50.000, PAL 25p
//     864x1250 = 25.000). NTSC film needs 27e6 x 1001/24000 = 1,126,125 dots/frame,
//     and 1,126,125 / 858 = 1312.5 — a HALF-LINE, not representable in a progressive
//     modeline. The original v1 rounded to vtotal 1313 (858 x 1313 = 1,126,554), i.e.
//     23.96689 Hz: video ran 0.0381% SLOW, so audio walked ahead ~1.37 s per hour
//     (linear, reset by any seek/chapter re-anchor — the reported symptom; interlaced
//     / analog were clean because they use the exact 59.94 raster).
//     1,126,125 = 3^2 x 5^3 x 7 x 11 x 13 is ODD, so htotal must be odd too — 858 can
//     never work. 875 x 1287 is the factorization closest to the standard 858-dot line
//     that lands EXACTLY on 24000/1001; hsync (735..797) still sits inside the line, so
//     only the back porch changes. Proven by bench/dvd/crt_syncgen_tb.sv PHASE 4.
// Steps 0-3 are IDENTICAL for 480i and 480p (720/857 horizontal — pixrep doubles it
// for HDMI-480i — and the same per-field vertical 479/261 + vsync 244/247); only
// step 4 (VID_MODE) and the trick write differ. NTSC film overrides step 0 as well.
// HORZ_RES/VERT_RES are written as the ACTIVE COUNT (720/480/576), matching the
// off-by-one fix in modeline.v (syncgen blanks at `cntr >= resolution`).
reg  [3:0]  wr_addr;
reg  [31:0] wr_data;
always @(*) begin
    case (seq_step)
        3'd0: begin wr_addr = REG_WR_HOR;
                    // DVD-FORK FIX (Film 24p exact rate): NTSC film uses 875 dots/line,
                    // NOT the 858 of every other NTSC mode — see the REG_WR_VER comment
                    // below for why (858 cannot produce an exact 24000/1001 frame period
                    // at 27 MHz; 875 x 1287 can). Active scan (720) and hsync (735..797)
                    // are unchanged — only the back porch grows 60 -> 77 dots.
                    wr_data = pal_prev              ? {4'b0, 12'd720, 4'b0, 12'd863}   // 864 dots/line total
                            : (filmp_prev & ~pal_prev) ? {4'b0, 12'd720, 4'b0, 12'd874}   // NTSC 24p: 875 dots/line total
                                                    : {4'b0, 12'd720, 4'b0, 12'd857}; end // 858 dots/line total
        3'd1: begin wr_addr = REG_WR_HOR_SYNC;
                    wr_data = pal_prev ? {4'b0, 12'd732, 4'b0, 12'd795}   // PAL hsync 732..795
                                       : {4'b0, 12'd735, 4'b0, 12'd797}; end // NTSC hsync 735..797
        3'd2: begin wr_addr = REG_WR_VER;
                    // PAL 576i (pal & il): per-FIELD values, mirroring NTSC 480i one row
                    // down. vertical_resolution 576 -> syncgen halves to 288 active
                    // lines/field (NTSC 480 -> 240). DVD-FORK FIX (single-raster analog,
                    // 2026-09-03): these were 575/479 (-> 287/239 per field = 574/478
                    // lines), the same active-region off-by-one the progressive walk
                    // fixed on 2026-06-24. A decoded stream masked it (the syncgen clamps
                    // the window to the sequence-header size), so it only showed with no
                    // header - the idle logo, or right after a decoder reset - as the
                    // "1441x478i" MiSTer report (1441 = the pixrep 2x+1 doubling, fixed in
                    // syncgen_intf). Per-field total 312 (vertical_length 311): 27 MHz /
                    // (1728 pixrep-dots x 312) = 50.06 fields/s (312.5 would be exact —
                    // 312 is the closer int; PAL analog is still unverified on HW).
                    wr_data = (pal_prev && filmp_prev) ? {4'b0, 12'd576, 4'b0, 12'd1249}  // PAL 25p: vtotal 1250 => 25.000 Hz
                            : (pal_prev && il_prev)     ? {4'b0, 12'd576, 4'b0, 12'd311}   // PAL 576i: 312 lines/field => ~50.06 Hz
                            : pal_prev    ? {4'b0, 12'd576, 4'b0, 12'd624}   // 625 lines/frame (576p @ 50 Hz)
                            : il_prev     ? {4'b0, 12'd480, 4'b0, 12'd261}   // 262 lines/field
                            : filmp_prev  ? {4'b0, 12'd480, 4'b0, 12'd1286}  // NTSC 24p: 1287 lines/frame @ 875 dots => 23.976024 Hz EXACT
                                          : {4'b0, 12'd480, 4'b0, 12'd524}; end // 525 lines/frame (480p, strobe-fix VERT_RES=480)
        3'd3: begin wr_addr = REG_WR_VER_SYNC;
                    // Per-FIELD vsync for the interlaced rasters. These are the values the
                    // retired re_interlace raster used and the composite CRT has always been
                    // happy with; line 21 (closed captions, v_cntr == vertical_length) is
                    // their 15th line after vsync end, which is where a TV's caption decoder
                    // looks (docs/closed_captions.md). ⚠ HW round 2 reverted a one-line-earlier
                    // variant (243..246 / 291..294) that came with the hsync-anchored vsync
                    // reference — see rtl/mpeg2/syncgen.v vs_ref_dot.
                    wr_data = (pal_prev && il_prev) ? {4'b0, 12'd292, 4'b0, 12'd295}   // PAL per-field vsync
                            : pal_prev ? {4'b0, 12'd581, 4'b0, 12'd586}   // PAL per-frame vsync 581..586
                            : il_prev  ? {4'b0, 12'd244, 4'b0, 12'd247}   // NTSC per-field vsync
                                       : {4'b0, 12'd488, 4'b0, 12'd494}; end // per-frame vsync
        3'd4: begin wr_addr = REG_WR_VID_MODE;
                    // The N64 half-line on the MAIN raster: 429 NTSC / 432 PAL, doubled
                    // by syncgen_intf under pixrep to 858 / 864 = exactly half the line.
                    // With the alternating 262/263 field totals this puts vsync edges
                    // exactly 262.5 lines apart every field, which is what makes the two
                    // fields interleave on a CRT — and it is what the N64 and PSX cores
                    // put on their single raster, feeding ascal and the analog pins from
                    // it. Main then reports a steady 59.94 Hz instead of alternating
                    // 59.83/60.05, and a vsync_adjust PLL lands on the true rate.
                    // ⚠ HW rounds 3-5 briefly wrote 0 here on the theory that a half-line
                    // combs ascal's weave (the ff01ac8 note). That was a MISREADING: the
                    // round-4 build had halfline 0 and still combed, and the comb only
                    // cleared when the field-parity corrector was disabled
                    // (dvd/resample_addrgen.v par_ins). Every combed capture had the
                    // corrector on; every clean one had it off, halfline 0 or 429.
                    // docs/single_raster_analog.md §3.9.
                    wr_data = il_prev  ? {4'b0, (pal_prev ? 12'd432 : 12'd429), 13'b0, 3'b011}
                                       : {4'b0, 12'd0,   13'b0, 3'b000}; end // progressive
        default: begin wr_addr = REG_WR_TRICK;                          // 3'd5
                    wr_data = {21'b0, trick_w}; end
    endcase
end

// DVD-FORK FIX (boot-time walk reset race, 2026-09-02 — HW round 1 of the Video
// Output consolidation): this block keys on RAW reset_n, but the decoder
// synchronizes its resets INTERNALLY (rtl/mpeg2/reset.v: cascaded 5-FF
// sync_reset stages), so hard_rst — which gates every modeline register in
// regfile.v — deasserts ~5-10 clk_dec cycles AFTER reset_n rises. A walk kicked
// in that window has its writes silently discarded while the registers
// re-default to the PROGRESSIVE modeline, and il_prev latches anyway, so
// nothing retries: the core then runs a progressive raster (31.47 kHz) with
// VGA_F1 toggling — the HW report's "719x...i @ 31.48kHz", dead CRT. The race
// was here since the walk was built but INVISIBLE: il_eff was always 0 at boot
// (a swallowed init walk wrote the reset defaults anyway) and every change came
// later via OSD with the decoder long alive. `Video Output = Auto` driving
// il_eff from the MiSTer.ini bits is the first boot-time walk that matters.
// FIX: gate every kick on the decoder's own synchronized reset (core_sync_rst =
// mpeg2video.sync_rst_out, clk_dec domain, the LAST reset to deassert) having
// been observed high for 8 consecutive cycles. Pending changes are simply
// applied by the first post-ready walk — il_s2/pal_s2/filmp_s2 keep tracking.
// Proven RED (swallowed walk, both partial and total) / GREEN by
// bench/dvd/modeline_boot_tb.sv over the REAL reset.v + regfile.v.
reg [2:0] dec_rdy_cnt = 3'd0;
always @(posedge clk_dec)
    if (!reset_n || !core_sync_rst) dec_rdy_cnt <= 3'd0;
    else if (dec_rdy_cnt != 3'd7)   dec_rdy_cnt <= dec_rdy_cnt + 3'd1;
wire dec_ready = (dec_rdy_cnt == 3'd7);   // decoder regfile writable (with margin)

always @(posedge clk_dec) begin
    if (!reset_n) begin
        il_s1 <= 1'b0; il_s2 <= 1'b0; il_prev <= 1'b0;
        pal_s1 <= 1'b0; pal_s2 <= 1'b0; pal_prev <= 1'b0;
        filmp_s1 <= 1'b0; filmp_s2 <= 1'b0; filmp_prev <= 1'b0;
        il_init <= 1'b0; seq_run <= 1'b0; seq_step <= 3'd0;
    end else begin
        il_s1  <= il_out;
        il_s2  <= il_s1;                         // 2-FF sync
        pal_s1 <= pal_out;
        pal_s2 <= pal_s1;                        // 2-FF sync
        filmp_s1 <= filmp_out;
        filmp_s2 <= filmp_s1;                    // 2-FF sync
        if (seq_run) begin
            if (seq_step == 3'd5) seq_run <= 1'b0;
            seq_step <= seq_step + 3'd1;
        end else if (dec_ready &&
                     (!il_init || (il_s2 != il_prev) || (pal_s2 != pal_prev) || (filmp_s2 != filmp_prev))) begin
            il_prev  <= il_s2;                   // latch the values being applied
            pal_prev <= pal_s2;
            filmp_prev <= filmp_s2;
            il_init  <= 1'b1;
            seq_run  <= 1'b1;                    // kick a 6-register write walk
            seq_step <= 3'd0;
        end
    end
end

wire        vld_err;         // decoder parse-error flag (was an implicit net — see the
                             // build_release.sh implicit-net gate, instituted 2026-08-26)
// DVD-FORK (line-21 CC): caption byte pairs out of the VLD's user_data snoop.
// clk_dec domain — do NOT sample these in clk_sys directly.
wire        core_cc_valid;
wire [15:0] core_cc_pair;
wire        core_cc_field;

mpeg2video mpeg2video_inst (
    .clk        (clk_dec),   // 81 MHz — decoder COMPUTE clock (3×27). Was 27 (compute-
                             // bound on D1: bridge idle ~100%, core_busy high). The
                             // core supports clk≠dot_clk≠mem_clk via internal CDC; clk
                             // "should be a multiple of 27 MHz" (rtl/mpeg2/mpeg2video.v).
    .mem_clk    (clk_mem),   // 90 MHz — req FIFO wr=54MHz rd=90MHz, still read-faster CDC
    .dot_clk    (clk_sys),   // 27MHz native dot clock (cleanly drives MiSTer HDMI PHY)
    .dot_ce     (1'b1),      // always full 27 MHz; the framework-facing pixel enable
                             // (CE_PIXEL) is derived at the output stage instead — see
                             // ce_pix_q (single-raster analog, 2026-09-03)
    .rst        (reset_n),

    .stream_data  (dec_stream_data),   // <- vidfeed_dc CDC (clk_sys -> clk_dec)
    .stream_valid (dec_stream_valid),  // byte actually consumed this cycle (1:1)

    .reg_addr   (seq_run ? wr_addr : 4'b0),    // DVD-FORK FIX (interlaced cadence): modeline writes
    .reg_wr_en  (seq_run),
    .reg_dta_in (wr_data),
    .reg_rd_en  (1'b0),

    .busy       (core_busy),
    .error      (vld_err),
    .interrupt  (),
    .watchdog_rst (watchdog_rst),

    .r          (core_r),
    .g          (core_g),
    .b          (core_b),
    .y          (),
    .u          (),
    .v          (),
    .pixel_en   (core_pixel_en),
    .h_sync     (core_h_sync),
    .v_sync     (core_v_sync),
    .c_sync     (),
    .h_pos      (core_h_pos),
    .v_pos      (core_v_pos),

    .mem_req_rd_cmd   (core_mem_cmd),
    .mem_req_rd_addr  (core_mem_addr),
    .mem_req_rd_dta   (core_mem_dta_out),
    .mem_req_rd_en    (core_mem_en),
    .mem_req_rd_valid (core_mem_valid),

    .mem_res_wr_dta          (shim_mem_dta),
    .mem_res_wr_en           (shim_mem_en),
    .mem_res_wr_almost_full  (shim_mem_almost_full),

    .testpoint_dip    (4'b0),
    .testpoint_dip_en (1'b0),
    .init_cnt_out     (core_init_cnt),
    .sync_rst_out     (core_sync_rst),
    .vbw_almost_full_out (core_vbw_almost_full),
    .dbg_lines_displayed (core_dbg_lines_displayed),   // DVD-FORK DEBUG (256-line strobe)
    .dbg_first_vpos  (core_dbg_first_vpos),
    .dbg_last_vpos  (core_dbg_last_vpos),
    .dbg_prof0       (core_dbg_prof0),                 // DVD-FORK DEBUG (stage profiler) rows 10/11
    .dbg_prof1       (core_dbg_prof1),
    // DVD-FORK (line-21 CC): EIA-608 pairs sniffed from user_data, in clk_dec.
    // They cross to clk_sys inside dvd/cc_line21.sv's own fifo_dc.
    .cc_pair_valid     (core_cc_valid),
    .cc_pair           (core_cc_pair),
    .cc_pair_field     (core_cc_field),
    .vertical_size_out (core_vertical_size),           // DVD-FORK FIX (PAL auto-detect): seq-header frame height (clk_dec)
    .horizontal_size_out (core_horizontal_size),       // DVD-FORK (CRT anamorphic overlay align): seq-header frame width (clk_dec)
    .aspect_ratio_out  (core_aspect_ratio),            // DVD-FORK FIX (aspect ratio): seq-header display-AR code (clk_dec)
    // DVD-FORK: O[18] Ref Prefetch BAKED IN (1'b1) to its HW-confirmed winner (deep
    // reference run-ahead, depth 512). Tying the constant lets Quartus prune the baseline
    // fill path in ref_dta_gate, freeing routing. See docs/roadmap.md cleanup section.
    .ref_prefetch_en   (1'b1),                         // O[18] baked: deep ref run-ahead always on
    .frame_drop_en     (frame_drop_s2),                // DVD-FORK (frame-drop O[12]): clk_dec-synced enable
    .dbg_frames_late   (core_frames_late),             // DVD-FORK (frame-drop O[12]): governor deadline-miss count (clk_dec)
    .dbg_frames_dropped(core_frames_dropped),          // DVD-FORK (frame-drop O[12]): B-frames dropped count (clk_dec)
    .dbg_vid_err       (core_vid_err),                 // DVD-FORK (vid_err instrument): video content vs wall (clk_dec)
    .dbg_drop_costs    (core_drop_costs),              // DVD-FORK (round 9): drop acks split by debit {cost3, cost2}
    .dbg_vbuf_fill     (core_vbuf_fill),               // DVD-FORK DEBUG: VBUF bitstream-cushion occupancy (0xFF = full)
    .video_live        (core_video_live),              // DVD-FORK (av_sync STC): "first frame displayed" (clk_dec; re-armed per load)
    .pickup_hold       (vid_hold_s2),                  // DVD-FORK (STD mux-lead hold): defer first display until audio caught up
    .pause             (pause_dec),                    // DVD-FORK (gamepad transport): freeze frame while paused (clk_dec-synced)
    .freeze_wd         (still_dec),                    // DVD-FORK (disc-menu still): watchdog-suppress only (clk_dec-synced)
    .vbuf_flush        (vbuf_flush_dec),               // DVD-FORK (gamepad transport): discard VBUF on a seek (clk_dec-synced)
    .soft_flush        (mount_flush),                  // DVD-FORK (mount soft reset): watchdog-equivalent decode reset on a file mount (async, synchronizers inside)
    .disp_vscale_mode  (disp_vscale_mode),             // DVD-FORK (CRT anamorphic vscale): 0 Fit / 2 SIF 2x line repeat
    .disp_vscale_en    (disp_vscale_en),               // DVD-FORK (CRT anamorphic letterbox AA): downstream 2-tap blend enable
    .disp_hcrop_en     (disp_hcrop_en),                // DVD-FORK (CRT anamorphic horizontal crop / pan-scan)
    .disp_hfill_en     (disp_hfill_en),                // DVD-FORK FIX (SIF analog fill): 352->720 stretch + 720 DE window
    .menu_ff           (1'b0),                         // DVD-FORK (menu VBUF-lag §5): fast-drain RETIRED (HW-inert); menu_ff=0 = bit-identical governor
    .film24            (filmp_dec),                    // DVD-FORK (Film 24p/25p Out): 1 frame/refresh in the governor; ascal does the pulldown
    .film_det_ntsc     (core_film_det_ntsc),           // DVD-FORK (Film 24p auto-detect): 3:2 telecine verdict (clk_dec)
    .film_det_pal      (core_film_det_pal)             // DVD-FORK (Film 24p auto-detect): sustained-progressive verdict (clk_dec)
);
// DVD-FORK (Film 24p auto-detect): 2-FF sync the governor's clk_dec cadence verdicts
// into clk_sys, where film_want / filmp_eff resolve the Off/On/Auto mode (the reverse
// of the film24_eff -> filmp_dec feed above). The verdicts are hysteretic (change at
// most ~1/s), so a plain 2-FF sync is sufficient. See docs/film_24p_plan.md §9a.
wire core_film_det_ntsc, core_film_det_pal;
reg  film_det_ntsc_s1, film_det_ntsc_s2, film_det_pal_s1, film_det_pal_s2;
always @(posedge clk_sys) begin
    film_det_ntsc_s1 <= core_film_det_ntsc; film_det_ntsc_s2 <= film_det_ntsc_s1;
    film_det_pal_s1  <= core_film_det_pal;  film_det_pal_s2  <= film_det_pal_s1;
end
assign film_det_ntsc_sync = film_det_ntsc_s2;
assign film_det_pal_sync  = film_det_pal_s2;
// DVD-FORK (frame-drop governor O[12]): 2-FF sync the static toggle into clk_dec.
// "On,Off" (default ON, 2026-07-02): with the cadence-correct governor both NTSC
// film and PAL stutter withOUT frame drop (real lates hold the display), and the
// starvation guard makes dropping safe (never fires while bitstream-starved).
// index 0 (On, default) => status[12]=0 => drop enabled; status[12]=1 => Off.
// core_frames_late/dropped are running counters from frame_drop_ctl; all 16
// debug_overlay rows are currently occupied, so surfacing them on the overlay is a
// deferred follow-up (same reason the av_sync drift overlay was deferred — the
// 4-bit-addressed overlay is fragile to expand). Initial HW validation is the visual
// A/B on BBB-PAL / high-motion (O[12] Off vs On). See docs/motcomp_throughput.md.
wire [15:0] core_frames_late, core_frames_dropped;
wire [15:0] core_vid_err;   // vid_err instrument: signed, 1 unit = 1 refresh (16.7 ms); negative = video content AHEAD
wire [15:0] core_drop_costs; // round-9 debit discriminator: {acks debited 3 [15:8], debited 2 [7:0]}, saturating
wire  [7:0] core_vbuf_fill;   // VBUF occupancy tap (framestore_request), eyeball-grade CDC
// =========================================================================
// MENU VBUF occupancy taps (docs/dvd_menu_refinements.md §5). core_vbuf_fill:
// 1 unit = 8 KB, 0xFF = full ~2 MB. Registered off the eyeball-grade CDC tap.
//   vbuf_deep  : >= 0x40 with hysteresis - now shown on the O[2] diagnostic (blk5) only
//                (the §5c deep-menu-flush that gated on it was removed with the toggle).
//   vbuf_empty : the decoder has drained its compressed buffer. Drives the reader's MENU
//                STILL COLD RE-DECODE (docs/dvd_menu_refinements.md §5): a menu still whose
//                displayed frame was decoded MID-STREAM (entered via a keep_vbuf transition,
//                so with stale references) shows PIXELATED unless re-decoded cleanly. The
//                reader flushes + re-streams just the still cell so its I-frame decodes from
//                the sequence header = a clean frame. It waits for vbuf_empty so the authored
//                transition plays out first; the menu VBUF cap keeps the buffer shallow so
//                vbuf_empty comes quickly = a prompt, clean still.
localparam [7:0] VBUF_FF_ON  = 8'h40;
localparam [7:0] VBUF_FF_OFF = 8'h18;
// MENU CAP SHRUNK 0x30->0x18 (2026-08-05, post-field-drop): the cap depth IS the
// highlight-early gap — nav_pci arms off the PARSE front while the display trails
// it by the kept VBUF, so at 0x30 the highlight landed ~0.4-0.9 s before the
// buffered transition finished on every menu disc. Halving to ~192 KB tightens
// highlight-vs-image coherence; it is safe NOW because (1) frame+FIELD-pair drops
// keep video at realtime (a shallow buffer no longer accrues lateness), (2) the
// ring floor auto-escapes the cap on tight-mux audio menus (Thayer class), and
// (3) the global 0xE0 ceiling backstops the jam regime. Still comfortably above
// the decoder's 64 KB (0x08) bitstream-health threshold. Stall grain kept at 4
// units (~40-50 ms, rides the audio cushion).
localparam [7:0] MENU_CAP_ON  = 8'h18;   // ~192 KB: throttle the reader in menus above this
localparam [7:0] MENU_CAP_OFF = 8'h14;   // release after ~4 units (~40-50 ms stall)
reg  [7:0] vbuf_fill_s1;
reg        vbuf_empty;
reg        vbuf_deep;      // O[2] diagnostic (blk5) only now (the deep-menu-flush that used it was removed)
// menu_vbuf_over is DECLARED earlier (near the reader-busy gate that reads it); here is its
// assignment, alongside vbuf_deep/vbuf_empty, from the framestore occupancy tap.
always @(posedge clk_sys) begin
    vbuf_fill_s1 <= core_vbuf_fill;
    if      (vbuf_fill_s1 >= VBUF_FF_ON)  vbuf_deep <= 1'b1;
    else if (vbuf_fill_s1 <  VBUF_FF_OFF) vbuf_deep <= 1'b0;
    if      (vbuf_fill_s1 >= MENU_CAP_ON)  menu_vbuf_over <= 1'b1;
    else if (vbuf_fill_s1 <  MENU_CAP_OFF) menu_vbuf_over <= 1'b0;
    vbuf_empty <= (vbuf_fill_s1 <= 8'h01);   // drained: safe to cold-re-decode the still cell
end
// DVD-FORK (av_sync STC reference): sticky decoder-domain "a decoded frame has been
// picked up for display" level, 2-FF synced into clk_sys. av_sync freezes the STC at
// its anchor PTS until this asserts, so the presentation clock references the SCREEN,
// not the demux parse position. Same CDC pattern as pal_det_s2.
wire core_video_live;         // clk_dec
reg  video_live_s1, video_live_s2;
always @(posedge clk_sys) begin
    if (!reset_n) begin video_live_s1 <= 1'b0; video_live_s2 <= 1'b0; end
    else          begin video_live_s1 <= core_video_live; video_live_s2 <= video_live_s1; end
end
reg frame_drop_s1, frame_drop_s2;
always @(posedge clk_dec or negedge reset_n) begin
    if (!reset_n) begin frame_drop_s1 <= 1'b0; frame_drop_s2 <= 1'b0; end
    else          begin frame_drop_s1 <= ~status[12]; frame_drop_s2 <= frame_drop_s1; end
end
// DVD-FORK FIX (PAL auto-detect): decoded frame height from the sequence header
// (clk_dec domain). 480 => NTSC, 576 => PAL. We derive a 1-bit "tall" flag and 2-FF
// sync it into clk_sys, where pal_eff (below) resolves the Auto/NTSC/PAL override.
wire [13:0] core_vertical_size;
// DVD-FORK FIX (mpeg1): MPEG-1 PAL/SIF is 352x288 (288 = half of 576), which the
// ">480" test misses — key on it explicitly. MPEG-1 NTSC/SIF is 240 (not >480, and
// not 288), so it correctly stays NTSC.
wire        pal_detect_raw = (core_vertical_size > 14'd480)    // PAL frame is 576 lines
                          || (core_vertical_size == 14'd288);  // MPEG-1 PAL SIF (352x288)
// DVD-FORK FIX (single-raster analog, 2026-09-03): HOLD the verdict while no sequence
// header is in force. vertical_size is a VLD register on sync_rst, so every watchdog
// expiry / mount soft reset zeroed it - and a PAL disc then read "NTSC" for the gap
// until the next header: pal_eff flipped, the modeline walk re-fired (PAL->NTSC->PAL,
// two raster restarts), and av_sync's STC tick rate went with it. Same trap the
// film-switch post-mortem hit (a garbage 576-line parse flipping pal_eff mid-title,
// docs/film_24p_plan.md §13). Last verdict held across resets; reset_n clears it.
reg         pal_detect_dec;
always @(posedge clk_dec or negedge reset_n) begin
    if (!reset_n)                          pal_detect_dec <= 1'b0;
    else if (core_vertical_size != 14'd0)  pal_detect_dec <= pal_detect_raw;
end
reg         pal_det_s1, pal_det_s2;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin pal_det_s1 <= 1'b0; pal_det_s2 <= 1'b0; end
    else          begin pal_det_s1 <= pal_detect_dec; pal_det_s2 <= pal_det_s1; end
end
// pal_eff: resolved PAL flag (clk_sys). O[17:16] = 0 Auto / 1 NTSC / 2 PAL.
// Auto follows the detected frame height; NTSC/PAL force the choice.
assign pal_eff = (status[17:16] == 2'b10) ? 1'b1 :        // force PAL
                 (status[17:16] == 2'b01) ? 1'b0 :        // force NTSC
                                            pal_det_s2;   // Auto: detected
// DVD-FORK (CRT anamorphic overlay align): frame width from the sequence header
// (clk_dec, quasi-static — settles at a seq-header parse, long before display). 2-FF
// registered into clk_sys like the flags above (a mid-transition glitch is harmless:
// the value is stable whenever a frame is actually displaying). The Crop-window
// geometry below replicates resample_addrgen/disp_hstretch exactly:
//   mb_width = ceil(width/16); hcrop_mb = round(mb_width/8) = (mb_width+4)>>3;
//   window = [hcrop_mb*16, width - hcrop_mb*16); stretch surplus = 2*hcrop_mb*16.
wire [13:0] core_horizontal_size;
reg  [13:0] hsz_s1, hsz_s2;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin hsz_s1 <= 14'd720; hsz_s2 <= 14'd720; end
    else          begin hsz_s1 <= core_horizontal_size; hsz_s2 <= hsz_s1; end
end
// DVD-FORK FIX (SIF analog fill, 2026-08-24): sub-D1 detect for the in-core 2x fill.
// MPEG-1 SIF (352x240/352x288) used to display in the upper-left quarter of the ANALOG
// output — the syncgen DE window tracks the decoded size while the re-interlacer is
// hardcoded 720-wide (garbage right/below). Two INDEPENDENT 1-bit flags (so 352x480
// half-D1 gets horizontal-only fill, correctly), clk_dec compares 2-FF synced into
// clk_sys (the pal_det pattern). Threshold: ANY sub-720 width fills (the stretcher is
// a true fractional resampler — SVCD 480 = exact 2:3, DVD sub-D1 704/544 included by
// user decision 2026-08-24, reversing the earlier SIF-only <=360 scope). 720-wide
// content stays un-stretched (hsrc<hdst contract).
wire sif_h_dec = (core_horizontal_size != 14'd0) && (core_horizontal_size < 14'd720);
wire sif_v_dec = (core_vertical_size  != 14'd0) && (core_vertical_size  <= 14'd288);
reg  sif_h_s1, sif_h_s2, sif_v_s1, sif_v_s2;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin sif_h_s1 <= 1'b0; sif_h_s2 <= 1'b0; sif_v_s1 <= 1'b0; sif_v_s2 <= 1'b0; end
    else begin
        sif_h_s1 <= sif_h_dec; sif_h_s2 <= sif_h_s1;
        sif_v_s1 <= sif_v_dec; sif_v_s2 <= sif_v_s1;
    end
end
// Gated on interlaced_eff (the Letterbox/Crop pattern): HDMI-only rigs keep the narrow DE
// window + ascal's polyphase scale (HW-proven for MPEG-1); the fill exists because the
// analog chain (direct video off the main raster) needs a true 720-wide raster line.
wire sif_hfill_eff = interlaced_eff & sif_h_s2;   // horizontal 352->720 stretch
wire sif_v2x_eff   = interlaced_eff & sif_v_s2;   // vertical 2x line repeat (240->480 / 288->576)
// DVD-FORK FIX (SIF analog fill): decoded height, 2-FF synced (hsz_s2 pattern) — feeds
// crt_ov_map's v2x inverse clamp (v_src_max = vertical_size-1).
reg  [13:0] vsz_s1, vsz_s2;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin vsz_s1 <= 14'd480; vsz_s2 <= 14'd480; end
    else          begin vsz_s1 <= core_vertical_size; vsz_s2 <= vsz_s1; end
end
// DVD-FORK FIX (SIF analog fill): the overlay-inverse geometry now describes whichever
// horizontal remap is active. Crop off => hcrop_mb = 0 (window origin 0, full width);
// the stretch target (ov_hdst_w) is 720 whenever the SIF fill is on. crt_ov_map's
// crop_en is analog_crop | sif_hfill_eff, so SIF-only gives the pure 352->720 inverse
// (x0=0, hsrc=352, hextra=368) and Crop+SIF composes (x0=48, hsrc=256, hextra=464) —
// exactly matching mpeg2video's disp_hsrc_w/disp_hdst_w forward geometry.
wire [9:0]  ov_mb_width = (hsz_s2 + 14'd15) >> 4;
wire [7:0]  ov_hcrop_mb = analog_crop ? ((ov_mb_width[7:0] + 8'd4) >> 3) : 8'd0;
wire [11:0] ov_hcrop_x0 = {ov_hcrop_mb[7:0], 4'b0000};              // crop window origin (96; 0 unless Crop)
wire [11:0] ov_hsrc_w   = {ov_mb_width[7:0], 4'b0000} - {ov_hcrop_mb[6:0], 5'b00000}; // source width (528 crop / 352 SIF)
wire [11:0] ov_hdst_w   = sif_hfill_eff ? 12'd720 : {ov_mb_width[7:0], 4'b0000};      // stretch target
wire [11:0] ov_hextra   = ov_hdst_w - ov_hsrc_w;                    // hdst - hsrc (192 crop / 368 SIF)
// DVD-FORK FIX (aspect ratio): sequence-header display aspect (clk_dec), 2-FF synced
// into clk_sys (same CDC pattern as core_vertical_size -> pal_det_s2 above). DVD MPEG-2
// emits code 2 (4:3) or 3 (16:9). CRITICAL: VIDEO_ARX/ARY must be STABLE — every change
// makes the framework re-init the scaler (resolution popup), and if the auto flag flaps
// (aspect_ratio_information is garbage/0 while nothing is locked) the scaler re-inits
// continuously and no video ever stabilizes. So we LATCH the "wide" flag: only a VALID
// code updates it (2 => 4:3, 3 => 16:9); anything else (0/1/garbage, e.g. idle/no-signal)
// HOLDS the last value, default 4:3. This keeps ARX/ARY constant when idle (identical to
// the old hardcoded 4:3) and flips at most once per clip when its real aspect is decoded.
wire [3:0] core_aspect_ratio;
reg  [3:0] ar_code_s1, ar_code_s2;   // 2-FF sync of the 4-bit code, clk_dec -> clk_sys
reg        ar_wide_auto;             // latched: 1 = 16:9, 0 = 4:3 (held on invalid codes)
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ar_code_s1 <= 4'd0; ar_code_s2 <= 4'd0; ar_wide_auto <= 1'b0;
    end else begin
        ar_code_s1 <= core_aspect_ratio;
        ar_code_s2 <= ar_code_s1;
        if      (ar_code_s2 == 4'd3) ar_wide_auto <= 1'b1;   // 16:9
        else if (ar_code_s2 == 4'd2) ar_wide_auto <= 1'b0;   // 4:3
        // else: hold (ignore reserved/square/garbage codes)
    end
end
// Auto source: while a disc MENU is active, take the aspect from the IFO video
// attribute (menu_ar_wide_w, from dvd_iso_reader's VTSM/VMGM V_ATR@0x100), NOT
// the MPEG sequence header. DVD menus are routinely authored 16:9 ANAMORPHIC
// with a 4:3 sequence-header code (e.g. Matrix VTS_02 menu), so the seq-header
// path shows them squished; a spec-correct player follows the IFO (as VLC does).
// Titles keep the proven seq-header path (title seq headers carry the true code).
// menu_ar_wide_w is captured during the menu load, before menu_active asserts,
// so VIDEO_ARX/ARY stays stable across the title->menu transition (no scaler
// re-init) whenever the movie and its menu share an aspect (the common case).
wire ar_wide_auto_eff = (menus_on && menu_active) ? menu_ar_wide_w : ar_wide_auto;
assign ar_wide_eff = (status[20:19] == 2'b01) ? 1'b0 :   // force 4:3
                     (status[20:19] == 2'b10) ? 1'b1 :   // force 16:9
                                                ar_wide_auto_eff; // Auto: IFO for menus, stream for titles

// DVD-FORK (Analog anamorphic): resolve the Analog Aspect menu (O[4:3]) into two
// independent display controls, because Letterbox and Crop act on DIFFERENT axes:
//   - disp_vscale_en (VERTICAL, downstream dvd/disp_vscale.sv): Letterbox = anti-aliased
//     3/4 vertical downscale (480->360, true 2-tap blend) + bars. The
//     addrgen emits FIT vertically so the blender has both straddling source lines.
//   - disp_hcrop_en (HORIZONTAL, dvd/disp_hstretch.sv): Crop = horizontal pan-scan — the
//     addrgen reads only the centre columns and the stretcher fills the raster width
//     (full vertical resolution, no bars). 0 for Fit/Letterbox.
// ONLY active while the analog 480i raster is engaged (interlaced_eff). NOTE (dual
// raster): the rescale is upstream in the SHARED raster, so HDMI shows it too —
// VIDEO_ARX/ARY switch to 4:3 while active (see the assign at the top) so HDMI
// geometry stays correct instead of re-stretching the letterboxed image.
// Auto = Letterbox for 16:9 streams / Fit for 4:3 (Crop is manual only).
// Quasi-static (menu-rate) into the clk_dec core.
//
// disp_vscale_mode (the OLD addrgen nearest-neighbour vertical decimation) is RETIRED —
// Letterbox is now the downstream 2-tap blender. It is driven to 0 always (addrgen = FIT
// vertically); the addrgen NN path is left dormant and prunes under the constant.
wire [1:0] analog_aspect_sel = status[4:3];   // 0 Auto, 1 Fit, 2 Letterbox, 3 Crop
// DVD-FORK (analog anamorphic overlay align): Auto follows ar_wide_auto_eff (the
// menu-aware aspect — IFO V_ATR while a menu is up, PR #86) instead of the raw
// stream aspect, matching what HDMI's ascal path does: an anamorphic menu now
// letterboxes on the CRT under Auto exactly like it corrects on HDMI.
assign analog_letterbox = interlaced_eff & ((analog_aspect_sel == 2'd2) |
                                ((analog_aspect_sel == 2'd0) & ar_wide_auto_eff)); // Letterbox or Auto-16:9
assign analog_crop      = interlaced_eff &  (analog_aspect_sel == 2'd3);         // Crop (manual)
wire       disp_vscale_en   = analog_letterbox;                             // downstream 2-tap letterbox
// DVD-FORK FIX (SIF analog fill): mode 2 = the re-armed addrgen 2x line repeat (v_step
// 128) for sub-D1 heights on the analog output; bit 0 stays tied (mode 1 letterbox-NN
// remains dormant and prunes). Quasi-static into clk_dec like the neighbours.
wire [1:0] disp_vscale_mode = {sif_v2x_eff, 1'b0};                          // 0 Fit / 2 SIF 2x line repeat
wire       disp_hcrop_en    = analog_crop;
wire       disp_hfill_en    = sif_hfill_eff;                                // SIF 352->720 stretch (disp_hstretch)
// DVD-FORK DEBUG (256-line strobe probe): per-output-frame mixer telemetry from
// the decoder core. No longer surfaced on the overlay (the 256-line strobe is
// resolved); kept as debug taps for future re-wiring if needed.
wire [11:0] core_dbg_lines_displayed;
wire [11:0] core_dbg_first_vpos;
wire [11:0] core_dbg_last_vpos;
// DVD-FORK DEBUG (stage profiler): windowed pipeline-stage bottleneck duty
// (clk_dec domain). Surfaced on overlay rows 10/11 (see decoder_profile.sv):
//   row 10 prof0 = {idct_fifo_af%, mvec_af%}  motcomp backpressure
//   row 11 prof1 = {idct_empty%,   rld_af%}   motcomp starvation | mid-pipe
wire [15:0] core_dbg_prof0;
wire [15:0] core_dbg_prof1;

// DVD-FORK DEBUG (slideshow-decay diagnosis): per-second governor rates for overlay
// row 11. Samples the free-running clk_dec counters raw (eyeball-grade CDC, same as
// rows 14/15) and latches the 1-second delta, saturated to 8 bits.
reg [24:0] rate_tick_cnt;
reg [15:0] lates_prev, drops_prev;
reg  [7:0] lates_per_sec, drops_per_sec;
wire [15:0] lates_delta = core_frames_late    - lates_prev;
wire [15:0] drops_delta = core_frames_dropped - drops_prev;
always @(posedge clk_sys) begin
    if (~reset_n) begin
        rate_tick_cnt <= 25'd0;
        lates_prev    <= 16'd0;
        drops_prev    <= 16'd0;
        lates_per_sec <= 8'd0;
        drops_per_sec <= 8'd0;
    end else if (rate_tick_cnt == 25'd26_999_999) begin
        rate_tick_cnt <= 25'd0;
        lates_per_sec <= (lates_delta > 16'd255) ? 8'hFF : lates_delta[7:0];
        drops_per_sec <= (drops_delta > 16'd255) ? 8'hFF : drops_delta[7:0];
        lates_prev    <= core_frames_late;
        drops_prev    <= core_frames_dropped;
    end else
        rate_tick_cnt <= rate_tick_cnt + 25'd1;
end

// =========================================================================
// Core 64-bit FIFO  <->  HPS f2sdram (DDRAM) burst bridge
// =========================================================================
// dvd/mem_shim_burst.sv: SET-ASSOCIATIVE read cache (ao486 L2-style: 4-way, 128
// sets, 8-word lines = 32 KB, LRU) with burst line-fill (LINEW=8, BIST-proven) +
// single-beat write-through + write-hit cache-update. The associativity is what
// stops the interleaved decoder streams (display scan-out + motion-comp refs +
// recon writes) from thrashing a direct-mapped cache; a high hit rate is what
// gives DDR3 its bandwidth (the lever, per ao486 — not clock or burst size).
// Drives DDRAM via the burst_ddr_* wires (through ddr_arb up top).
// shim_debug_* feeds the overlay/UART: debug_state is 0..10 (0 S_INIT, 1 REQ,
// 2 RX, 3 PROC, 4 HIT, 5 FILL_CMD, 6 FILL_DAT, 7 FILL_DRN, 8 SERVE_ADR, 9 SERVE,
// 10 WR_CMD); rd_count counts read-miss BURST commands, rsp_count counts beats.
// 4-way / 128 sets / 8-word = 32 KB (ao486-exact). This is the proven baseline:
// susi (352x240) is pixel-perfect with it. HARDWARE-MEASURED that neither more sets
// (256x4=64KB) NOR more ways (128x8) helps matrix -> matrix is NOT cache-hit-rate-
// bound (capacity+associativity are the only two hit-rate levers; both null). The
// cache's job here is burst amortization (1 miss -> 8-word fill -> 7 sequential
// hits), which works; the wall is bridge THROUGHPUT (~1 word / 4 clk_mem cycles).
// Bigger caches only cost ALM/timing for no gain, so we keep the 32 KB baseline.
// NSETS=64 (4-way, 8-word = 16 KB, was 128/32 KB): the decoder@54 clock domain
// pushed this congestion-marginal design past the fitter's routing limit, and the
// cache sits in the dense HPS-bridge region. Halving it frees routing/M10K there.
// Safe: memory is NOT the 720×480 bottleneck (decoder-compute is), and 256 cache
// lines keep the 4-way associativity that fixed susi (16× the 16-line direct-mapped
// cache that originally sheared it). Correctness re-verified in mem_shim_burst_tb.
mem_shim_burst #(.NSETS(64)) mem_shim_burst_inst (
    .clk              (clk_mem),
    .rst_n            (reset_n),
    .hard_rst_n       (reset_n),
    // DVD-FORK: O[14]/O[15] BAKED IN to their HW-confirmed winners (1'b1 constants) to
    // free routing (Quartus constant-propagates and prunes the loser datapaths). O[14]
    // Critical-Word Serve and O[15] Dual Outstanding are both settled On. See
    // docs/roadmap.md "FPGA congestion / resource cleanup".
    .cwf_en           (1'b1),          // O[14] baked: critical-word early-serve always on
    .dual_en          (1'b1),          // O[15] baked: paired dual-outstanding miss fills always on

    .mem_req_rd_cmd   (core_mem_cmd),
    .mem_req_rd_addr  (core_mem_addr),
    .mem_req_rd_dta   (core_mem_dta_out),
    .mem_req_rd_en    (core_mem_en),
    .mem_req_rd_valid (core_mem_valid),

    .mem_res_wr_dta          (shim_mem_dta),
    .mem_res_wr_en           (shim_mem_en),
    .mem_res_wr_almost_full  (shim_mem_almost_full),

    // Decoder master -> ddr_arb (audio writer shares this port). The arbiter
    // gates waitrequest; read responses pass straight back from DDRAM.
    .ddr3_addr        (burst_ddr_addr),
    .ddr3_burstcnt    (burst_ddr_burstcnt),
    .ddr3_read        (burst_ddr_read),
    .ddr3_write       (burst_ddr_write),
    .ddr3_writedata   (burst_ddr_writedata),
    .ddr3_byteenable  (burst_ddr_byteenable),
    .ddr3_readdata    (arb_dec_readdata),
    .ddr3_readdatavalid (arb_dec_readdatavalid),
    .ddr3_waitrequest (arb_dec_waitrequest),

    .debug_state      (shim_debug_state),
    .debug_saved_cmd  (shim_debug_saved_cmd),
    .debug_sdram_busy (shim_debug_sdram_busy),
    .debug_sdram_ack  (shim_debug_sdram_ack),
    .debug_rd_count   (shim_debug_rd_count),
    .debug_wr_count   (shim_debug_wr_count),
    .debug_rsp_count  (shim_debug_rsp_count),
    .debug_read_pend_cycles (shim_debug_read_pend_cycles),
    .debug_cache_missrate   (shim_debug_cache_missrate)
);

// =========================================================================
// Core Video Active Detection (for debug / uart_debug only)
// =========================================================================
// Tracks vsync edges to know when the core's syncgen is running.
// No longer used for a video mux — VGA is wired directly from the core.

reg [2:0]  core_vs_edge_cnt = 0;
reg        core_vs_prev = 0;
wire       core_video_active = (core_vs_edge_cnt >= 3'd3);
reg [15:0] core_frame_cnt = 0;  // free-running frame counter (all vsync rising edges)

// core_v_sync is in clk_mem domain (dot_clk=clk_mem), so sample here on clk_mem
always @(posedge clk_mem or negedge reset_n) begin
    if (!reset_n) begin
        core_vs_edge_cnt <= 0;
        core_vs_prev     <= 0;
        core_frame_cnt   <= 0;
    end else begin
        core_vs_prev <= core_v_sync;
        // Count rising edges of core vsync
        if (~core_vs_prev & core_v_sync & ~core_video_active)
            core_vs_edge_cnt <= core_vs_edge_cnt + 1'd1;
        // Free-running frame counter (all vsync edges, wraps at 65535)
        if (~core_vs_prev & core_v_sync)
            core_frame_cnt <= core_frame_cnt + 1'd1;
    end
end

// =========================================================================
// Read-path instrumentation (for debug overlay)
// =========================================================================
// Overlay row 6 was the CMD_READ-request counter (dbg_rdreq_count) used during
// black-screen bring-up to confirm the core issued reads at all. That question is
// long answered (video plays), so row 6 was REPURPOSED to the burst-cache
// MISS RATE (shim_debug_cache_missrate, wired from mem_shim_burst) — the
// compute-vs-memory disambiguator. The old counter is removed.

// =========================================================================
// Feed-chain instrumentation (for debug overlay)
// =========================================================================
// matrix.mpg (a valid program stream) still starves the decoder, so trace the
// byte flow: mpg_streamer output -> ps_demux input (consumed) -> ps_demux video
// output. Whichever counter is the last to move is where bytes stop. All three
// nodes are in the clk_sys domain.
reg [15:0] dbg_strm_count    = 0;   // bytes mpg_streamer emits
reg [15:0] dbg_demuxin_count = 0;   // bytes ps_demux actually consumes
reg [15:0] dbg_vidout_count  = 0;   // video bytes ps_demux forwards to decoder
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        dbg_strm_count    <= 0;
        dbg_demuxin_count <= 0;
        dbg_vidout_count  <= 0;
    end else begin
        if (stream_valid)                      dbg_strm_count    <= dbg_strm_count    + 1'd1;
        if (demux_in_valid && demux_in_ready)  dbg_demuxin_count <= dbg_demuxin_count + 1'd1;
        if (ps_vid_valid)                      dbg_vidout_count  <= dbg_vidout_count  + 1'd1;
    end
end

// NOTE: overlay rows 10/11 were the ps_demux start-code counters (dbg_sc_count /
// dbg_e0_count) from the black-screen bring-up — long resolved (video plays). They
// are REPURPOSED to the decoder STAGE PROFILER (core_dbg_prof0/1, wired above), so
// those counters are removed.

// =========================================================================
// Video Output — direct from MPEG2 core (no fallback mux)
// =========================================================================
// The fallback VGA generator ran on clk_vid (25.175 MHz) but CLK_VIDEO =
// clk_mem (108 MHz). Sampling clk_vid signals on clk_mem caused metastable
// sync signals that the MiSTer scaler could never lock to → permanent black.
// The MPEG2 core's outputs are already on clk_mem (dot_clk=clk_mem), so
// wiring them directly is clean. Before a stream is decoded, the core
// outputs black (Y=16, Cb=Cr=128), which is fine — "no signal" until play.

// On-screen pipeline diagnostic overlay (dvd/debug_overlay.sv).
// status[2]==0 -> overlay Off (default, video shows), ==1 -> On. Only RGB is
// muxed; the sync/DE come straight from the core so timing/lock is never disturbed.
wire       dbg_en = status[2];
wire       ov_on;
wire [7:0] ov_r, ov_g, ov_b;

// DVD-FORK (subpicture congestion relief): the debug_overlay renderer sits in the SAME
// congested display hotspot the subpicture blend now uses, and adding the subpicture
// renderer pushed the marginal fit over the edge (playback wedged / constant resync).
// Compile the overlay OUT for the release build (frees the corner + prunes its deep
// debug taps). Define DEBUG_OVERLAY in DVD.qsf to bring it back for diagnostics.
// See docs/roadmap.md "FPGA congestion" (release-vs-debug split).
// FLOW-CONTROL flags (overlay row 27, Thayer menu-audio saga): WHO is stalling
// the shared stream, sampled per frame. The three stall sources are sticky-OR'd
// across each frame (a sub-frame stall still shows); the guard/state levels are
// snapshots. Assembled here (outside the ifdef: 6 flops, free) so the overlay
// port wiring stays trivial.
// {vbuf_fill[7:0], thr_sticky, fifo_sticky, aud_bp_sticky, aud_bp_armed,
//  aud_ring_low, menu_aud_live, menu_vbuf_over, menu_active}
reg fc_thr_s, fc_fifo_s, fc_bp_s;       // sticky accumulators (current frame)
reg fc_thr_l, fc_fifo_l, fc_bp_l;       // latched (previous frame, displayed)
always @(posedge clk_sys) begin
    if (~core_vs_prev_sys & core_v_sync) begin
        {fc_thr_l, fc_fifo_l, fc_bp_l} <= {fc_thr_s, fc_fifo_s, fc_bp_s};
        fc_thr_s  <= menu_vbuf_throttle;
        fc_fifo_s <= fifo_almost_full;
        fc_bp_s   <= ~ps_aud_ready;
    end else begin
        fc_thr_s  <= fc_thr_s  | menu_vbuf_throttle;
        fc_fifo_s <= fc_fifo_s | fifo_almost_full;
        fc_bp_s   <= fc_bp_s   | ~ps_aud_ready;
    end
end
wire [15:0] dbg_flowctl = {vbuf_fill_s1,
                           fc_thr_l, fc_fifo_l, fc_bp_l, aud_bp_armed,
                           aud_ring_low, menu_aud_live, menu_vbuf_over, menu_active};

`ifdef DEBUG_OVERLAY
// ---- Tomb Raider FREEZE-REACH diagnosis (rows 21..26) -----------------------
// TR freezes at the 2nd interactive choice: video freezes, no options. The old
// (2026-07-27) diagnosis said the reader dead-ends at VMGM PGC4, menu_active=0
// -- but the "1-cell PRE-dispatcher never runs its PRE" theory was DISPROVEN in
// sim (bench/dvd/iso_reader_predispatch_tb.sv: the reader+VM handle that
// correctly). libdvdnav stays entirely in title 3 through the choices; our core
// wrongly ends up in the VMGM menu domain. So the REAL question is: which jump
// leaves title 3, and what is the exact PGC-load sequence into the freeze?
//
// These rows capture a rolling 4-deep PGC-LOAD HISTORY (captured on each
// pgc_loaded pulse) + the reader/VM state, so the whole reach is visible when
// the picture freezes. Each history entry packs {menu_dom[15], vts[14:8],
// pgcn[7:0]}: menu_dom=0 => TITLE (TT); menu_dom=1 & vts=0 => VMGM; menu_dom=1
// & vts>0 => VTSM. Read the history newest(23) -> oldest(26) to see the turn,
// e.g. [23]=VMGM/4 [24]=VMGM/3 [25]=TT/3 [26]=TT/25 shows TT/3 -> (jump) ->
// VMGM/3 -> VMGM/4 = the wrong turn out of the title.
reg [7:0]  ovl_pgc_err_cnt;
reg [15:0] tr_ld0, tr_ld1, tr_ld2, tr_ld3;   // PGC-load history (newest..oldest)
// Last VM jump the reader accepted (captured at jump_ack): the JUMP that caused
// the current load. Row 22 = {jump_domain[15:14], jump_vts[13:7], jump_pgcn[6:0]}
// (domain 3=TT 1=VMGM 2=VTSM 0=FP). Post-fix this tells whether the in-title
// LinkPGCN now ships jump_vts=cur_vts (nonzero) or still 0, and reveals the
// mechanism (CallSS VMGM => domain=1, LinkPGCN => domain=3).
reg [15:0] tr_lastjmp;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        ovl_pgc_err_cnt <= 8'd0;
        tr_ld0 <= 16'd0; tr_ld1 <= 16'd0; tr_ld2 <= 16'd0; tr_ld3 <= 16'd0;
        tr_lastjmp <= 16'd0;
    end else begin
        if (pgc_error && ovl_pgc_err_cnt != 8'hFF)
            ovl_pgc_err_cnt <= ovl_pgc_err_cnt + 8'd1;
        if (vm_jump_pulse)
            tr_lastjmp <= {vm_jump_domain, vm_jump_vts[6:0], vm_jump_pgcn[6:0]};
        // Shift a new entry in on each PGC load. cur_vts/cur_pgcn_rd are set by
        // the reader at load time (settled by the pgc_loaded pulse).
        if (pgc_loaded) begin
            tr_ld3 <= tr_ld2;
            tr_ld2 <= tr_ld1;
            tr_ld1 <= tr_ld0;
            tr_ld0 <= {menu_active, cur_vts[6:0], cur_pgcn_rd[7:0]};
        end
    end
end

// ---- IEC 61937 FLAP PROBE (rows 23/24, Passthru mode only) ------------------
// Counts what the RECEIVER actually sees on the wire at title start / across a
// track change, to discriminate the flap hypotheses (docs/iec61937.md "flap
// probe"): repeated re-anchors vs aud_rst_n resets vs marginal-due hold chatter
// vs ring underrun. All saturating, cleared only on core reset — read them as
// deltas (or watch them tick live during a flap).
//   row 23 = {gap_runs[7:0], aud_rst_cnt[3:0], reanchor_cnt[3:0]}
//     gap_runs     = real→silent burst transitions AFTER acquisition (each one
//                    is an interruption of the data-burst stream = one receiver
//                    re-negotiation candidate). Ticking during the flap = the
//                    pacing gaps ARE the flap; static = look at resets instead.
//     aud_rst_cnt  = aud_rst_n pulses (track switch aud_resync, seeks, mounts —
//                    each also hard-resets the spdif encoder = a discontinuity).
//     reanchor_cnt = av_sync STC re-anchors (each can re-open a hold run).
//   row 24 = {max_silent_run[7:0], underrun_bursts[7:0]}
//     max_silent_run  = longest consecutive silent-burst run post-acquisition
//                       (large = long gaps → re-anchor/hold-run shaped; 1-2 =
//                       single-burst chatter → marginal-due shaped, test the
//                       drain-watchdog fix).
//     underrun_bursts = silent bursts with NO frame queued post-acquisition
//                       (ring starvation, distinct from a pacing hold).
reg        bsp_seen;                    // a real burst since the last aud_rst_n
reg        bsp_prev_real;               // last burst's classification
reg [7:0]  bsp_gap_runs, bsp_run_len, bsp_run_max, bsp_under;
reg [3:0]  bsp_audrst, bsp_reanchor;
reg        bsp_audrst_q;
reg [15:0] bsp_reanchor_prev;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n) begin
        bsp_seen <= 1'b0; bsp_prev_real <= 1'b0;
        bsp_gap_runs <= 8'd0; bsp_run_len <= 8'd0; bsp_run_max <= 8'd0;
        bsp_under <= 8'd0; bsp_audrst <= 4'd0; bsp_reanchor <= 4'd0;
        bsp_audrst_q <= 1'b1; bsp_reanchor_prev <= 16'd0;
    end else begin
        bsp_audrst_q <= aud_rst_n;
        if (bsp_audrst_q && !aud_rst_n && bsp_audrst != 4'hF)
            bsp_audrst <= bsp_audrst + 4'd1;
        if (!aud_rst_n) bsp_seen <= 1'b0;   // mirrors the wrapper's burst_seen clear
        bsp_reanchor_prev <= av_reanchor_cnt;
        // av_sync resets per load flush (its counter drops to 0) — count only
        // nonzero changes so a reset itself isn't miscounted as a re-anchor.
        if (av_reanchor_cnt != bsp_reanchor_prev && av_reanchor_cnt != 16'd0
            && bsp_reanchor != 4'hF)
            bsp_reanchor <= bsp_reanchor + 4'd1;
        if (bs_burst_stb) begin
            bsp_prev_real <= bs_burst_real;
            if (bs_burst_real) begin
                bsp_seen    <= 1'b1;
                bsp_run_len <= 8'd0;
            end else if (bsp_seen) begin
                if (bsp_prev_real && bsp_gap_runs != 8'hFF)
                    bsp_gap_runs <= bsp_gap_runs + 8'd1;
                if (bsp_run_len != 8'hFF) begin
                    bsp_run_len <= bsp_run_len + 8'd1;
                    if (bsp_run_len + 8'd1 > bsp_run_max)
                        bsp_run_max <= bsp_run_len + 8'd1;
                end
                if (!bs_burst_held && bsp_under != 8'hFF)
                    bsp_under <= bsp_under + 8'd1;
            end
        end
    end
end
debug_overlay debug_overlay_inst (
    .clk          (clk_sys),
    .rst_n        (reset_n),
    .en           (dbg_en),
    .h_pos        (ov_h_gen),
    .v_pos        (core_v_pos),
    .de           (core_pixel_en),
    .wr_count     (shim_debug_wr_count),
    .rd_count     (shim_debug_rd_count),
    .rsp_count    (shim_debug_rsp_count),
    .frame_cnt    (core_frame_cnt),
    .streamer_active   (streamer_active),
    .streamer_has_data (streamer_has_data),
    .streamer_sd_ack   (streamer_sd_ack),
    .sdram_busy        (shim_debug_sdram_busy),
    .vld_err           (vld_err),
    .watchdog_rst      (watchdog_rst),
    .shim_state        (shim_debug_state),
    .cache_missrate    (shim_debug_cache_missrate),  // row 6: {miss%, read-intensity}
    .strm_count        (dbg_strm_count),
    .demuxin_count     (dbg_demuxin_count),
    .vidout_count      (dbg_vidout_count),
    // Rows 10/11 REPURPOSED (2026-07-02, slideshow-decay diagnosis; the stage profiler
    // that used them was removed 2026-07-01):
    //   row 10 = {VBUF fill (0xFF = 2MB bitstream cushion full), audio_ring fill
    //             (0xFF = 32KB full)} — the two reservoirs, side by side.
    //   row 11 = {frames_late/sec, frames_dropped/sec} (saturating 8-bit) — the
    //             governor's live behavior. Healthy: row10 high-byte rides high with
    //             row11 near 00 00; the smooth->slideshow decay shows WHICH reservoir
    //             drains and whether lateness precedes or follows it.
    .prof0             ({core_vbuf_fill, aud_bytes_avail[14:7]}),
    .prof1             ({lates_per_sec, drops_per_sec}),
    // Rows 14/15 = AC-3 decoder self-heal reset counters (restored 2026-07-04 after
    // the lip-sync drift saga closed — PR #62; the drift-instrument O[12] mux that
    // displaced them is retired). row 14 = ERR-caused resets, row 15 = TOTAL resets.
    // Both flat/low = the AC-3 front is healthy; climbing = input starvation / error
    // resets (the old static-pop class). No longer muxed by Frame Drop; the live
    // governor behaviour is on row 11 ({lates/s, drops/s}).
    .stall_cycles      (dbg_ac3_err_resets),
    .stall_info        (dbg_ac3_resets),
    .core_busy         (core_busy),
    .vbw_full          (core_vbw_almost_full),
    .aud_frames        (aud_frames_avail),   // overlay row 12
    // Row 13 = audio_ring frames DROPPED on overflow (should be ~0 in the STD
    // backpressure era). The drift-era armed-time high byte is retired.
    .aud_overflow      (aud_overflow_cnt),
    // Row 16 = drop-debit split {drop acks debited 3 [15:8], debited 2 [7:0]},
    // saturating (core_drop_costs). KEPT past the drift saga as the frame-drop
    // accounting check: on 3:2 film the drops phase-lock to rff=0 B's, so cost2 is
    // the honest heavy byte — cost3 climbing too would flag film-aware debits.
    // Retire after a Matrix/PAL confirmation pass.
    .drop_costs        (core_drop_costs),
    // Row 17 = vid_err (re-added 2026-07-05 for CRT 480i): signed wall-vs-content
    // refreshes from mpeg2video (clk_dec, eyeball-grade CDC like rows 10/11). The
    // 480i field-path A/V drift is diagnosed by THIS row — flat = timeline locked.
    .vid_err           (core_vid_err),
    // Rows 18/19 = DVD current/total time {mm,ss} BCD (Phase-7 nav foundation):
    // 18 = DSI cell-elapsed (current), 19 = PGC playback_time (total)
    .nav_time          (dbg_nav_time),
    .nav_total         (dbg_nav_total),
    .angle_info        (dbg_angle),
    // Rows 21..26 = Tomb Raider FREEZE-REACH diagnosis. Read at the freeze
    // (picture frozen = stable to read). Row 21 FIRST: S_DONE = reader dead-ended.
    //   row 21 = LIVE reader debug_state: rd_state[5:0], S_STILL[6], menu_dom[7],
    //            best_cnt[12:8], sel_valid[13], iso_error[14], iso_mode[15].
    //   row 22 = LAST VM jump the reader accepted: {jump_domain[15:14],
    //            jump_vts[13:7], jump_pgcn[6:0]}. domain 3=TT 1=VMGM 2=VTSM 0=FP.
    //            Post-fix: an in-title LinkPGCN should now show domain=3, vts=the
    //            title's VTS (nonzero); vts=0 here = the bug persists / other op.
    //   rows 23..26 = rolling PGC-LOAD HISTORY, newest(23) -> oldest(26). Each =
    //            {menu_dom[15], vts[14:8], pgcn[7:0]}. menu_dom=0 => TT (title);
    //            menu_dom=1 & vts=00 => VMGM; menu_dom=1 & vts>0 => VTSM. The
    //            sequence NAMES the wrong turn out of title 3 into the menu domain.
    .dbg21  (streamer_dbg_state),                   // LIVE reader state (rd_state[5:0]+menu_dom[7]+flags)
    .dbg22  (tr_lastjmp),                           // last VM jump {jump_domain[15:14], jump_vts[13:7], jump_pgcn[6:0]}
    // Rows 23/24 are MUXED on pass_mode: Passthru shows the IEC 61937 flap
    // probe (packing documented at the bsp_* block above); Decode keeps the
    // Tomb Raider PGC-load history.
    .dbg23  (pass_mode ? {bsp_gap_runs, bsp_audrst, bsp_reanchor} : tr_ld0),
    .dbg24  (pass_mode ? {bsp_run_max, bsp_under}                : tr_ld1),
    .dbg25  (tr_ld2),                               // PGC-load history [2]
    .dbg26  (rd_dbg_pgcerr),                        // last pgc_error {reason[15:13], nr_srp_sat[12:8],
                                                    //  want_pgcn[7:0]} — reason 1=empty PGCIT,
                                                    //  2=PGCN out of range (the failed-menu-link case),
                                                    //  3=bad pgc_start, 4=JumpTT resolve, 5=no PGCI_UT,
                                                    //  6=bad UT header, 7=VTS/menu-VOB not found
    .flowctl (dbg_flowctl),                         // row 27: {vbuf_fill, flow-control flags}
    .ov_on        (ov_on),
    .ov_r         (ov_r),
    .ov_g         (ov_g),
    .ov_b         (ov_b)
);
`else
// Overlay compiled out (release build): no overlay pixels, video passes through.
assign ov_on = 1'b0;
assign ov_r  = 8'd0;
assign ov_g  = 8'd0;
assign ov_b  = 8'd0;
`endif

// =========================================================================
// DVD subpicture (subtitle) overlay — decode (spu_decode) + reusable alpha
// blend (subpic_blend). The blend is the load-bearing layer transport UI /
// disc menus reuse later. It taps the same clk_sys RGB display path as the
// debug overlay, with the debug overlay kept on TOP. See docs/subpicture.md.
// DVD-FORK (single-raster analog, 2026-09-03): the analog pins take the main raster
// (vga_*_q) directly, so this blend composes once for HDMI and the CRT alike.
// DVD-FORK FIX (2026-08-22, interlaced overlay alignment): when the main raster IS
// interlaced (Video Output = Interlaced; historically Interlaced Out / Native Fields), the
// old `1'b0` ties on spu_decode/crt_ov_map .interlaced were WRONG in both axes:
//   - vertically, v_pos is the ABSOLUTE frame line stepping by 2 per field line, which
//     broke the +1 row-base accumulator (both modules already implement the correct
//     +2 walk behind .interlaced) -> now driven by il_eff;
//   - horizontally, the interlaced modeline uses pixel repetition, so the raster is
//     ~1440 active while overlay geometry is authored 720-wide -> the entire overlay
//     (subtitles, menu button art, HLI highlights, HUD, seek bar) rendered into the
//     LEFT HALF. Fixed by the uniform x2 inverse `ov_h_gen` / `sp_qx` above.
// This was a long-standing open follow-up for HDMI-480i (docs/interlaced_auto.md) and
// is a hard requirement for the analog fields mode, where menus are the point.
// =========================================================================
// Subtitles ON (gamepad Subtitle button cycle, `sub_on`), or a MENU is up
// (button graphics live in the subpicture stream; the subtitle toggle must not
// hide the menu - Phase 3). Drives BOTH spu_decode.enable and ps_demux.sp_enable
// (the demux gate was missed in round 1 -> no button graphics unless subtitles
// were already on).
assign sp_route_en = sub_on | (menus_on && menu_active)
                   | (menus_on && vm_owns_sp && vm_spstn[6]) // Phase 4: SetSTN sp display
                   | in_title_hli                            // in-title button (white rabbit)
                   | sp_menu_early;                          // in-title multi-button menu (Scene It): open early
wire       sp_en = sp_route_en;
wire [1:0] sp_q_idx;
wire       sp_q_inside;
wire [3:0] sp_a0, sp_a1, sp_a2, sp_a3;
wire [3:0] sp_col0, sp_col1, sp_col2, sp_col3;   // SET_COLOR palette indices

// HW round 1 (Phase 3): the raster counter LEADS the RGB datapath at this
// tap, so the subpicture (queried by core_h_pos, +2 output regs) lands a few
// px LEFT of the video it overlays - invisible on subtitles, obvious once
// the button highlight sits next to menu art. Compensate the query column;
// the highlight hit-test shares the same adjusted x so subpic and highlight
// stay pixel-locked. LEAD-2 = 6 estimated from the HW round-1 screenshot -
// CALIBRATE ON HW (too small = still left, too big = right).
localparam [11:0] SP_QX_ADJ = 12'd13;  // HW-calibrated: 6 (r2) -> 9 (r3) -> +4 (r4)
wire [11:0] sp_qx_dot = core_h_pos - SP_QX_ADJ;   // lead comp in raster DOTS
// Interlaced (pixrep) raster: map the lead-compensated dot back to source space.
wire [11:0] sp_qx = il_eff ? {1'b0, sp_qx_dot[11:1]} : sp_qx_dot;

// DVD-FORK (CRT anamorphic overlay align, dvd/crt_ov_map.sv): under the CRT
// Letterbox/Crop modes the VIDEO is rescaled upstream (disp_vscale / disp_hstretch)
// but this overlay tap queries raster space — so the subpicture and the HLI menu
// highlight landed offset from the picture. The mapper inverts the scalers'
// exact Bresenham walks, turning the raster position back into the SOURCE pixel
// being displayed there; the subpicture query, the highlight rect compare, and
// the O[2] rect border all use the mapped coordinates so the whole overlay layer
// stays glued to the video in all three CRT aspect modes. Pure pass-through
// (bit-identical) when neither mode is active (HDMI / CRT Fit).
//
// DVD-FORK FIX (subtitle sawtooth, 2026-09-02): the inverse map is NEAREST-tap —
// under Letterbox it drops every 4th subtitle line with no blending, so subtitle
// edges stair-step (and shimmer between fields) while the 2-tap-scaled picture
// underneath stays smooth (a CRT field report). The mapped coordinates only ever
// MATTER when the HLI rect can draw or the SPU is picture-composed art; plain
// dialogue subtitles don't need to track the rescaled picture (a set-top player
// doesn't scale them either). So the query is CONTEXT-SPLIT: menu/highlight
// contexts keep the mapped space (highlight ⟷ art stay pixel-locked — hl_use
// reads the queried pixel's class, so rect and query MUST share one space), and
// the pure-subtitle context bypasses the Letterbox/Crop inverses = raw raster
// coordinates, 1:1 bitmap, zero resampling. Consequences, all intended:
//   - raw subtitles lose the 0xFFF bar sentinel and may render INTO the
//     letterbox bars (standalone-player behaviour, user-accepted);
//   - the SIF fill stays FULLY mapped in every context (sub-720 SPU bitmaps are
//     authored in SIF source space — raw coords would draw them quarter-screen);
//   - a disc whose VM SetSTN-forces a real dialogue-subtitle stream rides
//     vm_owns_route and keeps the mapped (nearest) path — revisit if reported.
// hl_btns_armed (not hl_on_w) so the mapped space covers the arm→fetch window
// AND the O[2] dbg_rectb gate: whenever any rect can draw, the space is mapped,
// by construction. in_title_hli is subsumed by hl_btns_armed (its definition).
wire sp_ctx_mapped_w = hl_btns_armed              // any armed HLI (white rabbit included)
                     | (menus_on && menu_active)  // menu-domain button art
                     | sp_menu_early              // Scene It: in-title menu art pre-arm
                     | vm_owns_route              // SetSTN-forced SP (art shows via this pre-arm)
                     | force_43_subp;             // MiB flipbook art = picture content
// Committed at frame top: spu_decode's q_row_base walker tolerates only
// {reset,+1,+2}/{reset<=1,+2,+4} q_y steps — a mid-frame raw<->mapped flip would
// leave it stale for the rest of the field. A context change therefore lands at
// the next vsync (<1 frame of raw-vs-mapped rect mismatch on an arming edge,
// masked by video_live_s2). crt_ov_map's own walkers run UNCONDITIONALLY (the
// enables sit only in its output mux), so enable-gating is glitch-free and the
// mapped walk is exact the instant it is re-selected.
reg sp_ctx_mapped_q;
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)             sp_ctx_mapped_q <= 1'b1;   // reset = mapped (pre-fix behaviour)
    else if (av_refresh_tick) sp_ctx_mapped_q <= sp_ctx_mapped_w;
end
wire sp_map_en = sp_ctx_mapped_q | sif_hfill_eff | sif_v2x_eff;   // SIF ⇒ always mapped
wire [11:0] ov_qx, ov_qy;
crt_ov_map crt_ov_map_inst (
    .clk          (clk_sys),
    .rst_n        (reset_n),
    .letterbox_en (analog_letterbox & sp_map_en), // DVD-FORK FIX (subtitle sawtooth): raw in pure-subtitle context
    .crop_en      ((analog_crop & sp_map_en) | sif_hfill_eff), // DVD-FORK FIX (SIF analog fill): SIF drives the same inverse (x0=0)
    .interlaced   (il_eff),                // interlaced raster: v_pos = absolute frame line, +2/field-line
    .v2x_en       (sif_v2x_eff),           // DVD-FORK FIX (SIF analog fill): invert the addrgen 2x line repeat
    .v_src_max    ((vsz_s2 == 14'd0) ? 12'hfff : (vsz_s2[11:0] - 12'd1)), // decoded height - 1 (239/287)
    .v_bar        (pal_eff ? 12'd72 : 12'd60),   // mixer disp_v_offset (vertical_size/8)
    .v_band       (pal_eff ? 12'd432 : 12'd360), // letterboxed content height (3/4)
    .hcrop_x0     (ov_hcrop_x0),
    .hsrc_w       (ov_hsrc_w),
    .hextra       (ov_hextra),
    .h_pos_in     (sp_qx),
    .v_pos_in     (core_v_pos),
    .q_x_out      (ov_qx),
    .q_y_out      (ov_qy)
);

spu_decode spu_decode_inst (
    .clk        (clk_sys),
    .rst_n      (pipe_rst_n),
    .enable     (sp_en),
    // "menu_mode" = windowless display: show the committed SPU whenever valid, ignoring
    // the STC show/hide window (the window is on the demux parse-front PTS, which leads the
    // displayed frame by the VBUF depth). Menus need this (keep_vbuf lead); Force 4:3 Subpics
    // needs it too because MiB's visual-commentary art on substream 0x24 is a ~15 fps FLIPBOOK
    // with STA_DSP-only frames (NO STP_DSP) — each frame's parse-front show-PTS is overwritten
    // ~15x before the STC reaches it, so the windowed gate never fires and nothing animates.
    // Windowless = each committed frame shows until the next replaces it (true flipbook).
    // in_title_menu (Scene It's in-title game menus) needs windowless display too:
    // the highlight subpicture leads the displayed frame by the VBUF depth, same as
    // a menu-domain menu, so the STC window would gate it out.
    .menu_mode  ((menus_on && menu_active) || sp_menu_early || force_43_subp),
    .interlaced (il_eff),                  // interlaced raster: v_pos = absolute frame line, +2/field-line
    .sp_byte        (ps_sp_byte),
    .sp_valid       (ps_sp_valid),
    .sp_frame_start (ps_sp_frame_start),
    .sp_pts         (ps_sp_pts),
    .sp_pts_valid   (ps_sp_pts_valid),
    .stc        (av_stc),                 // video-referenced STC for show/hide timing
    .q_x        (ov_qx),                  // per-pixel query (lead-compensated + CRT-aspect inverse-mapped)
    .q_y        (ov_qy),
    .q_idx      (sp_q_idx),               // registered: 1 clk_sys after q_x/q_y
    .q_inside   (sp_q_inside),
    .alpha0     (sp_a0),
    .alpha1     (sp_a1),
    .alpha2     (sp_a2),
    .alpha3     (sp_a3),
    .col0       (sp_col0),
    .col1       (sp_col1),
    .col2       (sp_col2),
    .col3       (sp_col3),
    .sp_active  ()
);

// PGC palette (IFO @164) -> RGB. Fed by dvd_iso_reader at PGC load; looked up by the
// SET_COLOR index for this pixel. Registered one clk_sys stage below to keep the
// display-path (blend) LUT depth flat in the X33_Y11..X44_Y22 hotspot.
wire        pgc_pal_we;
wire [3:0]  pgc_pal_waddr;
wire [31:0] pgc_pal_wdata;
// PGC stream-control bus (dvd_iso_reader): waddr 0..15 = subp_control words
// (-> subp_ctl_mem, the subpicture display-mode substream mapping above),
// waddr 16..23 = audio_control words (-> the audio logical->physical map).
wire        pgc_ctl_we;
wire [4:0]  pgc_ctl_waddr;
wire [31:0] pgc_ctl_wdata;
wire        pgc_ctl_valid;
wire        pgc_dom_tt;
wire [3:0] sp_sel_col_spu = (sp_q_idx == 2'd0) ? sp_col0 :
                            (sp_q_idx == 2'd1) ? sp_col1 :
                            (sp_q_idx == 2'd2) ? sp_col2 : sp_col3;
// Phase 3: inside the highlighted button rect the HLI's palette index wins - but only
// for classes the highlight actually recolours (hl_use, defined below). A class whose
// coli contrast is 0 keeps its authored subpicture pixel. (hl_ci/hl_a/hl_use defined
// below, all sp_q_idx-aligned.)
wire [3:0] sp_sel_col = hl_use ? hl_ci : sp_sel_col_spu;
wire [7:0] pal_r, pal_g, pal_b;
pgc_palette pgc_palette_inst (
    .clk     (clk_sys),
    // NOT pipe_rst_n: the PGC palette is title-level state that must SURVIVE a
    // cell seek. pipe_rst_n pulses on seek_ack (load_flush), which would reset the
    // palette to its grayscale default — and the reader only streams the palette
    // during the initial PGC parse, never after a seek, so post-seek subtitles
    // showed the default (white). Use the hard reset; the reader overwrites all 16
    // entries on each new title's PGC parse. (This was the MiB white-subtitle bug.)
    .rst_n   (reset_n),
    .pal_we  (pgc_pal_we),
    .pal_waddr (pgc_pal_waddr),
    .pal_wdata (pgc_pal_wdata),
    .idx     (sp_sel_col),
    .rgb_r   (pal_r),
    .rgb_g   (pal_g),
    .rgb_b   (pal_b)
);

// per-index alpha (SET_CONTR); aligned with sp_q_idx (both 1 cyc after core_h/v_pos)
wire [3:0] sp_alpha = (sp_q_idx == 2'd0) ? sp_a0 :
                      (sp_q_idx == 2'd1) ? sp_a1 :
                      (sp_q_idx == 2'd2) ? sp_a2 : sp_a3;

// =========================================================================
// DVD menu BUTTON HIGHLIGHT (Phase 3, dvd/nav_pci.sv). The HLI supplies a
// rect + a colour word ([Ci3..Ci0 A3..A0] nibbles, indices into the SAME PGC
// palette). Inside the selected button's rect the subpicture pixel class
// (sp_q_idx) takes the HLI's palette index + alpha instead of the SPU's
// SET_COLOR/SET_CONTR - which is how authored button graphics (default
// alpha 0 = invisible) light up. All nav_pci outputs are registers; the hit
// test is 4 comparators vs registers, registered one stage (hl_hit_q) to the
// same alignment as sp_q_idx. Hotspot rule kept: register-fed compare+mux only.
// =========================================================================
wire        hl_on_w;
wire [9:0]  hl_x1, hl_x2, hl_y1, hl_y2;
wire [31:0] hl_coli;

nav_pci nav_pci_inst (
    .clk        (clk_sys),
    .rst_n      (pipe_rst_n),            // a load/seek/jump clears nav state
    .pci_byte   (ps_pci_byte),
    .pci_valid  (ps_pci_valid),
    .pci_frame_start (ps_pci_frame_start),
    .stc        (av_stc),
    .disp_wide  (ar_wide_auto_eff),      // Phase-3 spec-hardening button groups: content
                                         // 16:9 verdict (menu V_ATR while a menu is up,
                                         // stream aspect in titles — the PR #115 signal)
    // ★ HW ROUND 1 (2026-08-18): the button group must pair with the RENDERED
    // SUBPICTURE VARIANT, NOT the raw display mode. Display-mode groups are
    // authored for players that composite the highlight at DISPLAY resolution
    // (after the letterbox/crop); this core composites subpicture+highlight in
    // SOURCE space and scales the composite, so the aspect transform already
    // lands on the highlight — display-space rects on top shift it (T2
    // Letterbox split its group-2 rects across two options; MiB Crop split via
    // its pan&scan group; every breakage was exactly a non-group-1 pick, and
    // group-1-always had been HW-correct for the same reason software players
    // get away with libdvdnav's btnit[button-1]). Menus force subpicture
    // stream 0 = source-space art -> force the wide verdict (group 1 /
    // fallback). In-title highlights render the PR #115 mode-mapped substream
    // VARIANT, so the matching group stays self-consistent there (rabbit +
    // Force 4:3: letterbox art + letterbox rects). Same menu term as
    // sp_track_eff's stream-0 force, WITHOUT force_43_subp (menus outrank it
    // there too).
    .disp_mode  (((menus_on && menu_active) || sp_menu_early) ? 2'd0
                                                              : sp_disp_mode),
    .video_live (video_live_s2),         // fallback promotion trigger (keep_vbuf STC skew)
    .menu_settled (still_active && (vbuf_fill_s1 <= 8'h03)),
                                         // SETTLED = reader parked AND the decoder's tail
                                         // essentially displayed. still_active alone fired
                                         // at reader-park with ~0.5-1.5 s of transition
                                         // still buffered (sd-2048 fetches the cell fast) —
                                         // the T2/MiB residual earliness (row-26: settle at
                                         // vbuf 69-76). Threshold <=0x03 (~24 KB, tens of
                                         // ms of tail) instead of strict vbuf_empty (<=1):
                                         // MiB stills read slightly LATE on HW waiting for
                                         // the last few KB + the cold re-decode round trip.
    .stc_fresh  (hl_stc_fresh),          // last load flushed => STC display-coherent
                                         // (keep_vbuf hop => scheduled path blocked
                                         //  until a still park proves catch-up)
    .sel_force  (vm_btn_force),          // Phase 4: SetHL_BTNN / link buttons
    .sel_force_btn (vm_btn_force_val),
    .num_sel    (num_sel_p),             // numpad menu input: digit = select+activate
    .num_btn    (num_btn_r),
    .nav_up     (nav_up_p),
    .nav_dn     (nav_dn_p),
    .nav_lf     (nav_lf_p),
    .nav_rt     (nav_rt_p),
    .nav_act    (nav_act_p),
    .hl_on      (hl_on_w),
    .hl_x1      (hl_x1), .hl_x2 (hl_x2),
    .hl_y1      (hl_y1), .hl_y2 (hl_y2),
    .hl_coli    (hl_coli),
    .btn_cmd    (hl_btn_cmd),
    .btn_cmd_valid (hl_btn_cmd_valid),
    .btns_armed (hl_btns_armed),
    .btn_sel    (hl_btn_sel),
    .dbg_btn_ns (hl_btn_ns),         // gate in-title multi-button menu nav (Scene It)
    .hli_seen   (hl_menu_seen)       // early menu-HLI detect -> open the subpicture gate in time
);

// =========================================================================
// NAV-pack DSI capture (Phase-7 nav foundation, dvd/nav_dsi.sv). Parses each
// VOBU's presentation<->sector data (cell-elapsed time, VOBU sector, seek
// tables, angle offsets) that seeking (Phase 8) and multi-angle (Phase 9)
// will consume. This phase surfaces the CELL-ELAPSED time on the overlay
// (staged: whole-title running time = prefix-sum, a follow-up). Control-path
// only - not the congested display hotspot.
// =========================================================================
wire [31:0] dsi_c_eltm;         // BCD dvd_time: {hh, mm, ss, ff|rate}
wire [7:0]  dsi_c_idn;
// "near chapter start" for prev-chapter: cell-elapsed <= 4 s (hh=mm=00, ss BCD<=04).
// {hh,mm,ss} = dsi_c_eltm[31:8]; BCD 0..4 s = 24'h000000..24'h000004.
assign chap_at_start = (dsi_c_eltm[31:8] <= 24'h000004);
wire [31:0] dsi_nv_pck_lbn, dsi_vobu_ea, dsi_next_vobu, dsi_prev_vobu;
wire        dsi_commit;

nav_dsi nav_dsi_inst (
    .clk        (clk_sys),
    .rst_n      (pipe_rst_n),            // a load/seek/jump clears nav state
    .dsi_byte   (ps_dsi_byte),
    .dsi_valid  (ps_dsi_valid),
    .dsi_frame_start (ps_dsi_frame_start),
    .dsi_nv_pck_lbn (dsi_nv_pck_lbn),
    .dsi_vobu_ea    (dsi_vobu_ea),
    .dsi_1stref_ea  (),
    .dsi_vob_idn    (),
    .dsi_c_idn      (dsi_c_idn),
    .dsi_c_eltm     (dsi_c_eltm),
    .dsi_next_vobu  (dsi_next_vobu),
    .dsi_prev_vobu  (dsi_prev_vobu),
    .dsi_next_video (),
    .dsi_prev_video (),
    .dsi_commit     (dsi_commit),
    // seek/angle table read port -> Phase-8 time scrub (fwda/bwda[9] = +/-10 s)
    .tbl_raddr  (dsi_tbl_raddr),
    .tbl_rdata  (dsi_tbl_rdata)
);

// Overlay time rows (both BCD, osd_read-decodable as 4 nibbles = MM:SS):
//   row 18 = current  = DSI cell-elapsed time  c_eltm[mm,ss]
//   row 19 = total    = PGC playback_time      pgc_playback_time[mm,ss]
// c_eltm / playback_time bytes are hh[31:24] mm[23:16] ss[15:8] ff[7:0].
wire [31:0] pgc_playback_time_w;    // PGC total time from dvd_iso_reader (BCD)
wire [15:0] dbg_nav_time  = {dsi_c_eltm[23:16], dsi_c_eltm[15:8]};
wire [15:0] dbg_nav_total = {pgc_playback_time_w[23:16], pgc_playback_time_w[15:8]};
// Phase 9: {angle_count, cur_angle} for the debug overlay (row 20, DEBUG_OVERLAY
// build only). Release-visible angle indicator is a follow-up (like the time rows).
wire [15:0] dbg_angle     = {4'd0, angle_count, 4'd0, cur_angle};

// rect hit vs the live raster position, registered to align with sp_q_idx
// (both then lag core_h/v_pos by one clk_sys = the same 1-px shift the
// subtitle already tolerates). core_v_pos is the absolute frame line in
// CRT-480i too, so the same compare serves both modes.
reg hl_hit_q;
always @(posedge clk_sys)
    // video_live gate: after a jump the highlight must not float over the
    // black/stale frame while the new menu video is still decoding (it
    // re-arms on every load_flush and sets on the first displayed frame).
    hl_hit_q <= hl_on_w && video_live_s2 &&
                (ov_qx >= {2'b00, hl_x1}) && (ov_qx <= {2'b00, hl_x2}) &&
                (ov_qy >= {2'b00, hl_y1}) && (ov_qy <= {2'b00, hl_y2});

// HLI colour/alpha nibble for this pixel's class (sp_q_idx-aligned)
wire [3:0] hl_ci = (sp_q_idx == 2'd0) ? hl_coli[19:16] :
                   (sp_q_idx == 2'd1) ? hl_coli[23:20] :
                   (sp_q_idx == 2'd2) ? hl_coli[27:24] : hl_coli[31:28];
wire [3:0] hl_a  = (sp_q_idx == 2'd0) ? hl_coli[3:0]   :
                   (sp_q_idx == 2'd1) ? hl_coli[7:4]   :
                   (sp_q_idx == 2'd2) ? hl_coli[11:8]  : hl_coli[15:12];

// "Recolour this pixel with the highlight" = inside the button rect (hl_hit_q) AND the
// coli contrast nibble for this class is nonzero. A contrast-0 class = "no recolor": the
// subpicture's own pixel shows through instead of being deleted (matches discs whose
// selected-button graphic lives in the subpicture with an all-zero-contrast HLI coli,
// e.g. T2). When a class IS recoloured it drives subpic_blend.ov_force so a background-
// class (idx 0) highlight can still blend (the idx0 key otherwise drops it).
wire hl_use = hl_hit_q && (hl_a != 4'd0);

// =========================================================================
// Phase 11 — TRANSPORT HUD (dvd/transport_hud.sv): release-visible playback
// status (transport icon, timecode, CH n/N) rendered as a text plane + glyph
// ROM, composited through the SAME subpic_blend instance below (priority mux
// in the register stage — no second blend, no new DSP). The HUD pixel output
// is already registered inside the module (a 3-stage pipeline that is a pure
// function of core_h_pos/core_v_pos — interlace-safe; see hud_frame_tb).
// HUD_QX_ADJ=5 pre-compensates the pipeline + the sp_*_q register below
// (progressive raster; CRT-480i's 13.5 MHz pacing halves the effective px
// lead — a ~2 px HUD shift, imperceptible; HW-calibrate like SP_QX_ADJ).
// Suppressed while a menu is up (the HLI highlight layer owns the screen).
wire        hud_on_w;
wire [7:0]  hud_r_w, hud_g_w, hud_b_w;
wire [3:0]  hud_alpha_w;
// Whole-title elapsed = the reader's per-cell start-time prefix sum (BCD,
// step 6) + nav_dsi's cell-relative c_eltm — one combinational BCD dvd_time
// add (rate-aware frame carry). Falls back to the bare cell-relative time
// when no cell list is loaded (linear .VOB fallback). Known Phase-7
// characteristic: c_eltm is parse-front-timed, so the readout leads the
// picture by the VBUF depth (~1 s).
wire [31:0] whole_eltm_w;
bcd_time_add hud_time_add (
    .a   (cur_cell_start_w),
    .b   (dsi_c_eltm),
    .sum (whole_eltm_w)
);
transport_hud #(.HUD_QX_ADJ(5)) transport_hud_inst (
    .clk          (clk_sys),
    .rst_n        (reset_n),
    .h_pos        (ov_h_gen),
    .v_pos        (core_v_pos),
    .pal_mode     (pal_eff),
    .menu_active  (menus_on && menu_active),
    .dbg_mode     (hud_dbg),                // O[2]: show reader PGCN/VTS, always visible
    .pause_q      (pause_q),
    .bar_active   (bar_active_w),
    // The status-line transport icon is shared: a HELD FF/REW scrub renders
    // its accelerating tier, and an open D-pad coalesce window renders the tap
    // COUNT in the same "x n" field. hold_freeze itself is untouched -- it still
    // pauses the governor/audio below, which a D-pad tap deliberately does not.
    .scrub_held   (hold_freeze | dpad_pend),
    .scrub_dir    (hold_freeze ? hud_dir_w  : dpad_pend_dir),
    .scrub_tier   (hold_freeze ? hud_tier_w : dpad_pend_n),
    .display_edge (display_edge),
    .load_evt     (start_streaming),
    .show_evt     (hud_user_evt),
    .cur_time     (cell_ready ? whole_eltm_w : dsi_c_eltm),
    .total_time   (pgc_playback_time_w),
    // DIAGNOSTIC (hud_dbg = O[2]): repurpose the "CH n/N" field as {PGCN, VTS} of the
    // reader's currently-loaded PGC, so the boot path and the how-to-play flow are
    // readable on-screen -- e.g. how-to-play looping on Title 33 shows "CH 01/07"
    // (VTS7 PGCN1) vs reaching the VMGM segment menu "CH 03/xx" (PGCN3); a boot
    // question-detour shows a question VTS (01/05/06). Normal (O[2] off) = the real CH.
    .cur_pgm      (hud_dbg ? cur_pgcn_rd : hud_cur_ch),  // projected target while a multi-press debounces
    .nr_pgm       (hud_dbg ? cur_vts     : hud_nr_ch),   // Phase 6: exact PTT total
    // popups: B7/B8 cycle popups mirror the gamepad state (aud_cur/sub_idx —
    // the same selectors that drive the reader's attr_* language readout);
    // angle only inside a real multi-angle block; chapter matches the skip guard.
    .aud_evt      (audio_edge),
    .sub_evt      (sub_edge),
    .angle_evt    (angle_edge && (angle_count != 4'd0)),
    .chap_evt     ((chnext_edge | chprev_edge) && cell_ready && !menu_active),
    .css_warn     (css_scrambled),   // persistent "CSS ENCRYPTED" popup
    .img_warn     (img_unplayable),  // persistent "UNSUPPORTED IMAGE" popup
    .aud_warn     (aud_unsupported), // persistent "AUDIO UNSUPPORTED" popup
    .vts_evt      (vts_evt_r),       // one-shot "TITLE VTS nn" (menus-off only)
    .link_evt     (vm_link_fail),    // failed menu link (menu-exempt popup)
    .link_pgcn    (vm_link_fail_pgcn),
    .vts_no       (rdr_play_vtsn),
    // O[45] D-Pad Seek: "SEEK FWD 30S" / "SEEK BACK 60S" while the coalesce
    // window is open, so the tap COUNT is readable before the jump commits.
    .seek_evt     (dpad_pend_evt),
    .seek_fwd     (dpad_pend_dir),
    .seek_min     (dpad_pend_min),
    .seek_sec     (dpad_pend_sec),
    .aud_no       ({1'b0, aud_cur} + 4'd1),
    .aud_cnt      (audio_ntracks_w),
    .aud_lang     (attr_a_lang_w),
    .sub_enabled  (sub_on),
    .sub_no       ({1'b0, sub_idx} + 4'd1),
    .sub_cnt      (subp_ntracks_w),
    .sub_lang     (attr_s_lang_w),
    .ang_no       (cur_angle),
    .ang_cnt      (angle_count),
    .hud_on       (hud_on_w),
    .hud_r        (hud_r_w),
    .hud_g        (hud_g_w),
    .hud_b        (hud_b_w),
    .hud_alpha    (hud_alpha_w)
);

// Phase 11 — SEEK BAR (dvd/seek_bar.sv): the visual feedback for the Phase-8a
// seek-on-release scrub. While D-pad L/R is held the video is paused, so this
// bar (fill = playhead at hold start, amber cursor = accumulating target) is
// the only indication of where the release lands; it rides scrub_ctrl's
// bar_* outputs (+~1.5 s linger) against the reader's title RBN span. Serial
// divider off-hotspot; 2-stage registered (x,y)-pure render like the HUD.
wire        bar_on_w;
wire [7:0]  bar_r_w, bar_g_w, bar_b_w;
wire [3:0]  bar_alpha_w;
seek_bar #(.BAR_QX_ADJ(4)) seek_bar_inst (
    .clk        (clk_sys),
    .rst_n      (reset_n),
    .h_pos      (ov_h_gen),
    .v_pos      (core_v_pos),
    .pal_mode   (pal_eff),
    .bar_active (bar_active_w),
    .base_rbn   (bar_base_rbn_w),
    .tgt_rbn    (bar_tgt_rbn_w),
    .first_rbn  (title_first_rbn_w),
    .last_rbn   (title_last_rbn_w),
    // progress popup (stretch): pops on pause/landed seek/chapter with the
    // LIVE playhead + chapter notches, suppressed in menus like the HUD
    .pause_q    (pause_q),
    .show_evt   (hud_user_evt),
    .menu_active(menus_on && menu_active),
    .cur_rbn    (cell_ready ? dsi_nv_pck_lbn : lin_blk_w),
    .pgc_loaded (pgc_loaded),
    .nr_pgm     (hud_nr_ch),          // Phase 6: exact PTT total for chapter notches
    .pm_we      (vm_pm_we),
    .pm_waddr   (vm_pm_waddr),
    .pm_wdata   (vm_pm_wdata),
    .cellf_we   (cellf_we_w),
    .cellf_idx  (cellf_idx_w),
    .cellf_rbn  (cellf_rbn_w),
    // chapter-skip preview: the same projected target the HUD's "CH n/N" field
    // counts through during a multi-press burst, so the bar's amber cursor
    // shows WHERE that chapter starts (tick_col[n-1]) while the number moves --
    // the scrub's "where will I land" feedback, on B2/B3 skips.
    .chap_prev  (chap_disp_act),
    .chap_pgm   (hud_cur_ch),
    .bar_on     (bar_on_w),
    .bar_r      (bar_r_w),
    .bar_g      (bar_g_w),
    .bar_b      (bar_b_w),
    .bar_alpha  (bar_alpha_w)
);

// ---------------------------------------------------------------------------
// IDLE LOGO (launch-feedback, 2026-08-26): bouncing logo while no disc is
// mounted -- see dvd/idle_logo.sv + docs/idle_screen.md. Priority-muxed into
// the SAME register stage below (no new blend); alpha is a constant 15 there
// (opaque passthrough). User bitmap = /media/fat/games/DVD/boot.rom (ioctl
// index 0, the framework's zero-CONF_STR boot.rom convention -- the ioctl_*
// wires were previously entirely unused).
//
// Visibility: every term is belt-and-braces on top of !media_seen (nothing
// can be on screen before a mount), but each covers a real path --
// video_live_s2/img_streaming catch the OSD-Reset-while-mounted case
// (reset_n clears media_seen but the HPS does not re-pulse img_mounted);
// img_unplayable yields to the UNSUPPORTED IMAGE popup; ioctl_download
// hides a half-rewritten bank; logo_boot_dly kills the flash of the
// DEFAULT logo between core load and Main's boot.rom push (also re-armed
// by any later download). ⚠ HW round 3: do NOT gate on OSD_STATUS -- the
// framework OSD covers only part of the screen and the logo bouncing
// BEHIND the file browser is the intended (and README-promised) look; the
// original OSD gate made the logo vanish the moment the startup popup
// opened.

reg [24:0] logo_boot_dly;   // ~1.2 s @ 27 MHz
always @(posedge clk_sys or negedge reset_n) begin
    if (!reset_n)                  logo_boot_dly <= 25'h1FFFFFF;
    else if (ioctl_download)       logo_boot_dly <= 25'h1FFFFFF;
    else if (logo_boot_dly != 25'd0) logo_boot_dly <= logo_boot_dly - 25'd1;
end

wire logo_vis = !media_seen && !video_live_s2 && !img_streaming &&
                !img_unplayable && !ioctl_download &&
                (logo_boot_dly == 25'd0);

wire       logo_on_w;
wire [7:0] logo_r_w, logo_g_w, logo_b_w;
idle_logo #(.LOGO_QX_LEAD(12'd12)) idle_logo_inst (
    .clk            (clk_sys),
    .rst_n          (reset_n),
    .h_pos          (ov_h_gen),
    .v_pos          (core_v_pos),
    .pal_mode       (pal_eff),
    .il_mode        (il_eff),
    .frame_tick     (av_refresh_tick),
    .vis            (logo_vis),
    .entropy        (entropy_ctr),
    .ioctl_download (ioctl_download),
    .ioctl_wr       (ioctl_wr),
    .ioctl_addr     (ioctl_addr),
    .ioctl_dout     (ioctl_dout),
    .ioctl_index    (ioctl_index),
    .logo_on        (logo_on_w),
    .logo_r         (logo_r_w),
    .logo_g         (logo_g_w),
    .logo_b         (logo_b_w)
);

// Pipeline the palette RGB + alpha + on/idx one clk_sys stage before the combinational
// blend, so the blend stays a flat mux (no colour-space math) in the output hotspot.
// The subtitle already tolerates a 1-px right shift (see below); this adds one more px,
// imperceptible, and keeps VIDEO/sync/DE timing byte-identical.
// Phase 11: the HUD priority-muxes over the subtitle/HLI INTO this existing
// register (fill/outline/backing are pre-resolved RGB+alpha; force bypasses
// the idx0 transparency key) — the only display-hotspot change.
reg  [7:0] sp_r_q, sp_g_q, sp_b_q;
reg  [3:0] sp_alpha_q;
reg  [1:0] sp_idx_q;
reg        sp_on_q;
reg        sp_force_q;
// The idle logo joins as a fourth layer below the bar (it is mutually
// exclusive with all of them by its !media_seen gate -- the ordering is
// belt-and-braces so any future gate leak keeps warnings on top). Its
// alpha is a constant 15 (weight 16 = exact passthrough in subpic_blend)
// and it MUST assert force: sp_idx_q carries the subpicture's index, which
// is 0 when idle, and without force the idx-0 transparency key would erase
// the logo.
always @(posedge clk_sys) begin
    sp_r_q     <= hud_on_w ? hud_r_w     : bar_on_w ? bar_r_w     : logo_on_w ? logo_r_w : pal_r;
    sp_g_q     <= hud_on_w ? hud_g_w     : bar_on_w ? bar_g_w     : logo_on_w ? logo_g_w : pal_g;
    sp_b_q     <= hud_on_w ? hud_b_w     : bar_on_w ? bar_b_w     : logo_on_w ? logo_b_w : pal_b;
    sp_alpha_q <= hud_on_w ? hud_alpha_w : bar_on_w ? bar_alpha_w : logo_on_w ? 4'd15
                           : (hl_use ? hl_a : sp_alpha);   // HLI alpha for recoloured classes
    sp_idx_q   <= sp_q_idx;
    sp_on_q    <= hud_on_w | bar_on_w | logo_on_w | sp_q_inside;
    sp_force_q <= hud_on_w | bar_on_w | logo_on_w | hl_use; // + logo: bypass the idx0 key
end

// Alpha-composite the subtitle over the decoded video, COMBINATIONALLY, right before
// the existing registered output stage (no added pipeline stage). spu_decode's q_idx /
// q_inside are registered (1 clk_sys after q_x=core_h_pos), so blending them against the
// live core_r shifts the subtitle 1 pixel right vs the video — imperceptible, and it lets
// the VIDEO/sync/DE output timing stay byte-identical to the proven pre-subpicture core
// (only the RGB value now passes through this small blend before the SAME output reg; the
// reg->pin hop that the 2026-06-28 column-dots fix shortened is unchanged).
wire [7:0] sub_r, sub_g, sub_b;
subpic_blend subpic_blend_inst (
    .in_r(core_r), .in_g(core_g), .in_b(core_b),
    .ov_on(sp_on_q), .ov_idx(sp_idx_q),
    .ov_r(sp_r_q), .ov_g(sp_g_q), .ov_b(sp_b_q),
    .ov_alpha(sp_alpha_q),
    .ov_force(sp_force_q),
    .out_r(sub_r), .out_g(sub_g), .out_b(sub_b)
);

// =========================================================================
// MENU HIGHLIGHT DIAGNOSTIC (toggle O[2] "Debug Overlay" — inert in the release
// build otherwise). After several rounds where T2's deep-menu highlights never
// appear, this separates a nav_pci PROMOTION failure from a RENDER failure.
// With O[2] On and menus active it draws, on top of the picture:
//   - top-left block #1 (x 8..23):  GREEN = nav_pci armed (hl_btns_armed), RED = not.
//   - top-left block #2 (x 28..43): GREEN = video_live_s2, RED = not.
//   - top-left block #3 (x 48..63): GREEN = a subpicture was decoded+shown this
//     frame (sp_q_inside seen), RED = none. The highlight recolours the subpicture
//     (subpic_blend.ov_on = sp_q_inside), so RED here = nothing to recolour.
//   - top-left block #4 (x 68..83): GREEN = SPU bytes reached spu_decode since the
//     last load/flush (STICKY — a menu SPU is one-shot). block4 GREEN + block3 RED =
//     SPU arrives but spu_decode won't commit/show; block4 RED = ps_demux filtered it.
//   - MAGENTA 1-px border around the selected button rect (bypasses video_live +
//     coli + subpicture): its PRESENCE = armed, its POSITION = the rect coords.
// Registered => hotspot-safe; zero effect with O[2] Off.
wire        dbg_hl_en = status[2] && menus_on;
wire        dbg_blk1  = (ov_h_gen >= 12'd8)  && (ov_h_gen < 12'd24) &&
                        (core_v_pos >= 12'd8)  && (core_v_pos < 12'd24);
wire        dbg_blk2  = (ov_h_gen >= 12'd28) && (ov_h_gen < 12'd44) &&
                        (core_v_pos >= 12'd8)  && (core_v_pos < 12'd24);
wire        dbg_blk3  = (ov_h_gen >= 12'd48) && (ov_h_gen < 12'd64) &&
                        (core_v_pos >= 12'd8)  && (core_v_pos < 12'd24);
// block 4: SPU bytes reached spu_decode this frame (ps_demux routed the substream).
// GREEN + block3 RED = SPU arrives but spu_decode won't commit/show (decode/PTS);
// RED = ps_demux filtered it out (sp_track) or it isn't in the stream.
wire        dbg_blk4  = (ov_h_gen >= 12'd68) && (ov_h_gen < 12'd84) &&
                        (core_v_pos >= 12'd8)  && (core_v_pos < 12'd24);
// VBUF-LAG DIAGNOSIS (docs/dvd_menu_refinements.md §5) — second row + a bar.
//   blk5 (v30..46, x8..24)  = vbuf_deep: GREEN = the fast-drain threshold tripped
//                             (menu_ff engaged), RED = VBUF below 0x40 (menu_ff never
//                             fired -> that's why fast-drain did nothing; lower the thr).
//   blk6 (v30..46, x28..44) = still_active: GREEN = reader parked on a menu still,
//                             RED = not parked (still streaming / stuck upstream).
//   VBUF BAR (v50..58, x8..8+fill): width == core_vbuf_fill (0xFF = full ~2 MB). Past
//     ~x72 (0x40) vbuf_deep should be set. HIGH bar at the blank frame => cell 0 IS
//     buffered but not displayed (pickup/decode issue); LOW => cell 0 never reached the
//     VBUF (keep_vbuf LinkPGCN junction dropped it).
wire        dbg_blk5  = (ov_h_gen >= 12'd8)  && (ov_h_gen < 12'd24) &&
                        (core_v_pos >= 12'd30) && (core_v_pos < 12'd46);
wire        dbg_blk6  = (ov_h_gen >= 12'd28) && (ov_h_gen < 12'd44) &&
                        (core_v_pos >= 12'd30) && (core_v_pos < 12'd46);
// §7 return-highlight probes (2nd row): blk7 = hl_on_w (nav_pci armed AND fetched -
// the render gate needs BOTH; block1 green + blk7 RED => the FETCH isn't completing).
// blk8 = a highlight RECOLOUR pixel fired this frame (hl_use = inside the rect, class
// 1/2, coli alpha != 0 — NOT sp_force_q, which the HUD/seek bar also drive):
// blk7 GREEN + blk8 RED => armed+fetched but no
// class-1/2 subpicture pixel is landing in the button rect on the displayed frame
// (the keep_vbuf display/parse skew), NOT a promotion/fetch fault.
wire        dbg_blk7  = (ov_h_gen >= 12'd48) && (ov_h_gen < 12'd64) &&
                        (core_v_pos >= 12'd30) && (core_v_pos < 12'd46);
wire        dbg_blk8  = (ov_h_gen >= 12'd68) && (ov_h_gen < 12'd84) &&
                        (core_v_pos >= 12'd30) && (core_v_pos < 12'd46);
wire        dbg_vbar  = (core_v_pos >= 12'd50) && (core_v_pos < 12'd58) &&
                        (ov_h_gen >= 12'd8)  && (ov_h_gen < (12'd8 + {4'd0, vbuf_fill_s1}));
// RASTER-TRIGGER ROW (single-raster analog, 2026-09-03; the RGBS/YPbPr "shake every
// second" field reports). Third row, v 62..78, shown whenever O[2] is On AND the
// fields raster is up (Interlaced) — menus or not — so a reporter on a CRT can read
// it. GREEN = the event has FIRED since the diagnostic was switched on (or since the
// last load/seek flush); RED = quiet. Every one of these is a raster-restart trigger
// found in the code (none of them should fire during steady playback):
//   blk9  (x  8.. 24) decoder WATCHDOG expiry (re-phased the raster pre-fix)
//   blk10 (x 28.. 44) il_switch (Video Output mode change / analog_want edge)
//   blk11 (x 48.. 64) pal_eff changed (modeline walk re-fired)
//   blk12 (x 68.. 84) vertical_size read 0 = a decoder soft reset / lost header
//   blk13 (x 88..104) Main re-wrote the cfg word AFTER its first write (OSD leave,
//                     video_mode_adjust, [video=] section re-parse — informational)
wire        dbg_r3_en = status[2] && interlaced_eff;
wire        dbg_blk9  = (ov_h_gen >= 12'd8)  && (ov_h_gen < 12'd24) &&
                        (core_v_pos >= 12'd62) && (core_v_pos < 12'd78);
wire        dbg_blk10 = (ov_h_gen >= 12'd28) && (ov_h_gen < 12'd44) &&
                        (core_v_pos >= 12'd62) && (core_v_pos < 12'd78);
wire        dbg_blk11 = (ov_h_gen >= 12'd48) && (ov_h_gen < 12'd64) &&
                        (core_v_pos >= 12'd62) && (core_v_pos < 12'd78);
wire        dbg_blk12 = (ov_h_gen >= 12'd68) && (ov_h_gen < 12'd84) &&
                        (core_v_pos >= 12'd62) && (core_v_pos < 12'd78);
wire        dbg_blk13 = (ov_h_gen >= 12'd88) && (ov_h_gen < 12'd104) &&
                        (core_v_pos >= 12'd62) && (core_v_pos < 12'd78);
// clk_dec events -> toggles (one flip per event), 2-FF synced, edge-detected in clk_sys
reg         wd_rst_q, wd_tgl, vs0_q, vs0_tgl;
always @(posedge clk_dec) begin
    wd_rst_q <= watchdog_rst;
    if (wd_rst_q && !watchdog_rst) wd_tgl <= ~wd_tgl;            // active-LOW pulse = expiry
    vs0_q    <= (core_vertical_size == 14'd0);
    if (!vs0_q && (core_vertical_size == 14'd0)) vs0_tgl <= ~vs0_tgl;
end
reg  [2:0]  wd_tgl_s, vs0_tgl_s;
reg         pal_eff_q, cfg_seen_q;
reg         dbg_r3_en_q;
reg         wd_seen_l, ils_seen_l, pal_seen_l, vs0_seen_l, cfg_seen_l;
always @(posedge clk_sys) begin
    wd_tgl_s    <= {wd_tgl_s[1:0],  wd_tgl};
    vs0_tgl_s   <= {vs0_tgl_s[1:0], vs0_tgl};
    pal_eff_q   <= pal_eff;
    cfg_seen_q  <= cfg_seen;
    dbg_r3_en_q <= dbg_r3_en;
    if (!pipe_rst_n || (dbg_r3_en && !dbg_r3_en_q)) begin       // clear: flush, or O[2] turned on
        wd_seen_l <= 1'b0; ils_seen_l <= 1'b0; pal_seen_l <= 1'b0; vs0_seen_l <= 1'b0; cfg_seen_l <= 1'b0;
    end else begin
        if (wd_tgl_s[2] ^ wd_tgl_s[1])   wd_seen_l  <= 1'b1;
        if (il_switch)                   ils_seen_l <= 1'b1;
        if (pal_eff ^ pal_eff_q)         pal_seen_l <= 1'b1;
        if (vs0_tgl_s[2] ^ vs0_tgl_s[1]) vs0_seen_l <= 1'b1;
        if (cfg_wr && cfg_seen_q)        cfg_seen_l <= 1'b1;    // a RE-write, not the first
    end
end
// STICKY since the last flush (a menu SPU is sent ONCE then the reader parks, so a
// per-frame latch reads red in steady state even if the SPU was routed — that was
// misleading last round). Cleared on pipe_rst_n (load/seek/jump), set on any SPU byte.
reg         spb_seen_l;
always @(posedge clk_sys) begin
    if (!pipe_rst_n)      spb_seen_l <= 1'b0;
    else if (ps_sp_valid) spb_seen_l <= 1'b1;
end
wire        dbg_rectb =
    ((ov_qx == {2'b00,hl_x1} || ov_qx == {2'b00,hl_x2}) &&
      ov_qy >= {2'b00,hl_y1} && ov_qy <= {2'b00,hl_y2}) ||
    ((ov_qy == {2'b00,hl_y1} || ov_qy == {2'b00,hl_y2}) &&
      ov_qx >= {2'b00,hl_x1} && ov_qx <= {2'b00,hl_x2});
// sticky "a subpicture pixel was inside this frame" (reset at each vsync)
reg         sp_seen, sp_seen_l;
always @(posedge clk_sys) begin
    if (~core_vs_prev_sys & core_v_sync) begin sp_seen_l <= sp_seen; sp_seen <= 1'b0; end
    else if (sp_q_inside)                sp_seen <= 1'b1;
end
// §7 blk8 sticky: a highlight RECOLOUR pixel fired this frame (hl_use = inside the
// button rect AND coli alpha != 0). GREEN = the recolour ran. NOTE: watches hl_use
// ONLY — NOT sp_force_q, which also carries the HUD and seek-bar terms (see below).
// DVD-FORK FIX (2026-08-17, sweep Pass 2): this probe used to watch sp_force_q,
// which is `hud_on_w | bar_on_w | hl_use` — so it read GREEN whenever the transport
// HUD or the seek bar drew ANY pixel, regardless of the highlight. That made blk8
// useless for the question it exists to answer ("did the highlight recolour fire?"):
// a HUD auto-popup alone turned it green. Watch the registered hl_use term ONLY.
reg         hlvis_seen, hlvis_seen_l, hl_use_q;
always @(posedge clk_sys) hl_use_q <= hl_use;
always @(posedge clk_sys) begin
    if (~core_vs_prev_sys & core_v_sync) begin hlvis_seen_l <= hlvis_seen; hlvis_seen <= 1'b0; end
    else if (hl_use_q)                   hlvis_seen <= 1'b1;
end
reg  [7:0]  dbg_r_q, dbg_g_q, dbg_b_q;
reg         dbg_px_q;
always @(posedge clk_sys) begin
    dbg_px_q <= (dbg_hl_en && (dbg_blk1 || dbg_blk2 || dbg_blk3 || dbg_blk4 ||
                               dbg_blk5 || dbg_blk6 || dbg_blk7 || dbg_blk8 || dbg_vbar ||
                               (hl_btns_armed && dbg_rectb)))
             || (dbg_r3_en && (dbg_blk9 || dbg_blk10 || dbg_blk11 || dbg_blk12 || dbg_blk13));
    if (dbg_blk1) begin
        dbg_r_q <= hl_btns_armed ? 8'h00 : 8'hFF;
        dbg_g_q <= hl_btns_armed ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk2) begin
        dbg_r_q <= video_live_s2 ? 8'h00 : 8'hFF;
        dbg_g_q <= video_live_s2 ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk3) begin
        dbg_r_q <= sp_seen_l ? 8'h00 : 8'hFF;
        dbg_g_q <= sp_seen_l ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk4) begin
        dbg_r_q <= spb_seen_l ? 8'h00 : 8'hFF;
        dbg_g_q <= spb_seen_l ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk5) begin                                 // vbuf_deep (menu_ff engaged)
        dbg_r_q <= vbuf_deep ? 8'h00 : 8'hFF;
        dbg_g_q <= vbuf_deep ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk6) begin                                 // still_active (reader parked)
        dbg_r_q <= still_active ? 8'h00 : 8'hFF;
        dbg_g_q <= still_active ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk7) begin                                 // hl_on_w = armed AND fetched
        dbg_r_q <= hl_on_w ? 8'h00 : 8'hFF;
        dbg_g_q <= hl_on_w ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk8) begin                                 // recolour fired this frame
        dbg_r_q <= hlvis_seen_l ? 8'h00 : 8'hFF;
        dbg_g_q <= hlvis_seen_l ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk9) begin                                 // raster row: watchdog expired
        dbg_r_q <= wd_seen_l ? 8'h00 : 8'hFF;
        dbg_g_q <= wd_seen_l ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk10) begin                                // raster row: il_switch fired
        dbg_r_q <= ils_seen_l ? 8'h00 : 8'hFF;
        dbg_g_q <= ils_seen_l ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk11) begin                                // raster row: pal_eff changed
        dbg_r_q <= pal_seen_l ? 8'h00 : 8'hFF;
        dbg_g_q <= pal_seen_l ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk12) begin                                // raster row: vertical_size hit 0
        dbg_r_q <= vs0_seen_l ? 8'h00 : 8'hFF;
        dbg_g_q <= vs0_seen_l ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_blk13) begin                                // raster row: cfg re-written
        dbg_r_q <= cfg_seen_l ? 8'h00 : 8'hFF;
        dbg_g_q <= cfg_seen_l ? 8'hFF : 8'h00; dbg_b_q <= 8'h00;
    end else if (dbg_vbar) begin                                 // VBUF occupancy bar (cyan)
        dbg_r_q <= 8'h00; dbg_g_q <= 8'hFF; dbg_b_q <= 8'hFF;
    end else begin
        dbg_r_q <= 8'hFF; dbg_g_q <= 8'h00; dbg_b_q <= 8'hFF;   // magenta rect border
    end
end

// =========================================================================
// DVD-FORK (line-21 closed captions, single-raster analog 2026-09-03): the EIA-608
// inserter rides the MAIN raster's vertical blanking interval (it used to live
// inside the deleted dvd/re_interlace.sv second raster). The coordinate glue is
// dvd/cc_vbi.sv (line 21 / field derivations documented there) so that
// bench/dvd/cc_e2e_tb.sv drives exactly this wiring. Gated on the fields raster
// being up (interlaced_eff), P1O[14] Line-21 CC, and NTSC. load_flush is the same
// event that resets ps_demux and re-anchors av_sync on a load / seek / menu jump,
// so the caption backlog is dropped with everything else. P1O[44] CC Test Line
// paints the waveform on visible line 20 (the diagnostic that cracked the field
// mapping on HW).
// ⚠ sys_top's VGA scanlines stage must NOT zero the data outside DE (it did, stock:
//   `de_emu ? data : 0`) — that gate silently killed this waveform once already on
//   the VGA2 path. The output stage below blanks everything outside DE itself
//   except the caption level, so dropping the framework gate changes nothing else.
// =========================================================================
wire [7:0]  cc_level;
wire        cc_on;
cc_vbi cc_vbi_inst (
    .clk            (clk_sys),
    .rst_n          (reset_n),
    .dec_clk        (clk_dec),
    .dec_pair_valid (core_cc_valid),
    .dec_pair       (core_cc_pair),
    .dec_pair_field (core_cc_field),
    .enable         (interlaced_eff & ~status[14]),
    .test           (status[44]),
    .flush          (load_flush),
    .pal            (pal_eff),
    .h_pos          (core_h_pos),
    .v_pos          (core_v_pos),
    .pixel_en       (core_pixel_en),
    .level          (cc_level),
    .on             (cc_on),
    .active         ()
);

// Registered video output stage (DVD-FORK FIX, 2026-06-28): registering the final mux at
// the boundary cuts the route to the VGA_* pins to a short reg->pin hop (cured the faint
// vertical-column dots). The subtitle blend feeds this mux; the debug overlay stays on top.
// DVD-FORK (single-raster analog, 2026-09-03): this ONE stream now feeds ascal/HDMI AND
// the analog pins (the dual-raster VGA2_* path is gone). Outside DE the stage emits
// black except the line-21 caption level (equal on R/G/B = luma only, no chroma), and
// ce_pix_q is the framework-facing pixel enable (see CE_PIXEL near the top).
reg [7:0] vga_r_q, vga_g_q, vga_b_q;
reg       vga_hs_q, vga_vs_q, vga_de_q, ce_pix_q;
always @(posedge clk_sys) begin
    vga_r_q  <= cc_on ? cc_level : ~core_pixel_en ? 8'd0 : ov_on ? ov_r : (dbg_px_q ? dbg_r_q : sub_r);
    vga_g_q  <= cc_on ? cc_level : ~core_pixel_en ? 8'd0 : ov_on ? ov_g : (dbg_px_q ? dbg_g_q : sub_g);
    vga_b_q  <= cc_on ? cc_level : ~core_pixel_en ? 8'd0 : ov_on ? ov_b : (dbg_px_q ? dbg_b_q : sub_b);
    vga_hs_q <= core_h_sync;
    vga_vs_q <= core_v_sync;
    vga_de_q <= core_pixel_en;
    ce_pix_q <= ~core_h_pos[0];                      // first clock of each pixrep pair
end
assign VGA_R  = vga_r_q;
assign VGA_G  = vga_g_q;
assign VGA_B  = vga_b_q;
assign VGA_HS = vga_hs_q;
assign VGA_VS = vga_vs_q;
assign VGA_DE = vga_de_q;


// DVD-FORK: the UART debug transmitter (uart_debug + uart_tx) is REMOVED to free
// routing for the frame-drop reland (the design is congestion-marginal). Diagnostics
// moved to the on-screen debug_overlay long ago, so the UART was dead weight; removing
// it also prunes its exclusive deep debug taps (streamer_*, shim_debug_*, core_*_cnt).
// See docs/roadmap.md "FPGA congestion / resource cleanup".

assign CLK_SYS = clk_sys;
assign CLK_MEM = clk_mem;

// =========================================================================
// LEDs and Debug
// =========================================================================
assign LED_POWER    = 2'b00; // Let system control
assign LED_DISK     = {streamer_active, stream_valid}; // LED indicates: streaming active, data flowing
assign LOCKED       = locked;

reg [24:0] heartbeat;
always @(posedge clk_sys) heartbeat <= heartbeat + 1'b1;
assign LED_USER     = heartbeat[24]; // Toggle ~1Hz @ 27MHz

// UART debug removed (see above) — User IO tied off.
assign USER_OUT = 7'b0;

endmodule

