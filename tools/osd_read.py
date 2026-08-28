#!/usr/bin/env python3
"""
osd_read.py — decode the DVD core's debug overlay (dvd/debug_overlay.sv) from a
capture-card recording, so HW telemetry can be logged/plotted instead of read
off the screen by eye.

The overlay is a machine-readable lattice drawn in CORE pixel coordinates
(720x480/576 raster, before the MiSTer scaler):

    cell grid : 16 cols x NROW(=17) rows, pitch 16 px both axes
    col c     : x in [48 + 16c, 48 + 16c + 14)          (col 0 = bit 15, MSB)
    row r     : y in [24 + 16r, 24 + 16r + 12)
    panel box : x in [40, 312), y in [16, 24 + NROW*16 + 4)  (dark background)
    cell value: WHITE = 1, dim gray = 0
    row 4     : 8 flag cells, GREEN = asserted / RED = not (cols 0..7)
    row 5     : 4-cell nibble (MSB..LSB)

The recording sees this through an affine scale+offset (scaler AR, capture
crop), so a calibration maps core->capture pixels:
    capx = x0 + sx*corex ; capy = y0 + sy*corey
`calibrate` derives it automatically from the panel box (and can be verified:
row 3 is a free-running frame counter, so it MUST increment across frames) or
takes --box manually; the result is stored in a JSON and reused (the capture
chain is fixed).

Usage:
    osd_read.py calibrate REC [--time T] [--box X0,Y0,X1,Y1] [--cal FILE] [--png OUT]
    osd_read.py read      REC --time T[,T2,...] [--cal FILE] [--rows 14,15,...]
    osd_read.py csv       REC [--every SECS] [--start T] [--end T] [--cal FILE] [--out FILE]
    osd_read.py selftest

Only needs python3 + numpy + ffmpeg/ffprobe.

Row map (2026-07-05, CRT-480i work — keep in sync with debug_overlay.sv):
    see ROW_LABELS below. The lip-sync drift saga is CLOSED, so the drift
    instrument rows (18-20) stay retired and rows 14/15 are back to the AC-3
    self-heal reset counters (no O[12] mux). Row 11 = {lates/s, drops/s} carries
    the live governor behaviour; row 16 keeps the {drop3, drop2} debit split.
    Row 17 = vid_err (SIGNED wall-minus-content refreshes) is RE-ADDED for the
    CRT-480i field-path timeline work: flat = locked, climbing = video slipping
    behind the wall clock (audio rides ahead).
NOTE (480i captures): with CRT 480i Out the overlay renders NATIVE-width (no
    pixel-repetition squish), so plain `calibrate` should work again; the HDMI
    480i (O9) overlay is still squished left — use `calibrate --box`.
"""

import argparse
import json
import subprocess
import sys

import numpy as np

# ---- overlay geometry (must match dvd/debug_overlay.sv) ---------------------
NCOL, NROW = 16, 28
X0, Y0 = 48, 24            # first cell top-left, core px
PITCH = 16
CELLW, CELLH = 14, 12
BOXX0, BOXX1 = 40, X0 + NCOL * 16 + 8      # 40 .. 312
BOXY0, BOXY1 = 16, Y0 + NROW * 16 + 4      # 16 .. 348

ROW_LABELS = [
    "wr_count      ",  # 0
    "rd_count      ",  # 1
    "rsp_count     ",  # 2
    "frame_cnt     ",  # 3
    "flags         ",  # 4  (8 G/R cells: sa,hd,ack,busy,vld_err,WD-FIRED,core_busy,vbw)
    "shim_state    ",  # 5  (nibble)
    "cache_missrate",  # 6  {miss%, read-intensity}
    "strm_count    ",  # 7
    "demuxin_count ",  # 8
    "vidout_count  ",  # 9
    "vbuf|ring     ",  # 10 {VBUF fill, audio ring fill}
    "lates|drops   ",  # 11 per second
    "aud_frames    ",  # 12
    "ring_ovfl     ",  # 13 audio_ring frames dropped on overflow (~0)
    "ac3_err_rst   ",  # 14 AC-3 ERR-caused self-heal resets
    "ac3_tot_rst   ",  # 15 AC-3 TOTAL self-heal resets
    # Row 16 layout v2 (2026-08-05, in-vld probe): {debt[15:11], drop_req[10],
    # hdr_cnt[9:6] (wrapping picture-header visits), dropnow_cnt[5:2] (wrapping
    # drop decisions), req_in_vld[1], b_seen[0]}. hdr ticking + dropnow frozen
    # = dead compare; req_in_vld=0 with req=1 = mangled request net; dropnow
    # ticking + row-11 drops 0 = latch-to-slice-ack leg.
    "dropprobe     ",  # 16 {debt, req, hdr_cnt, dropnow_cnt, req_in, b_seen}
    "vid_err       ",  # 17 SIGNED wall-content refreshes (re-added for CRT 480i)
    "nav_cur MM:SS ",  # 18 DVD current time: DSI cell-elapsed {mm,ss} BCD (Phase 7)
    "nav_tot MM:SS ",  # 19 DVD total time: PGC playback_time {mm,ss} BCD (Phase 7)
    "angle cnt|cur ",  # 20 {angle_count[15:8], cur_angle[7:0]}
    # --- Tomb Raider FREEZE-REACH diagnosis (rows 21..26) ---
    # Read at the freeze (picture frozen). Row 21 rd_state FIRST (S_DONE=dead-end).
    # Rows 23..26 = PGC-load history newest->oldest, {menu_dom15, vts[14:8], pgcn[7:0]}:
    #   menu_dom=0 => TT(title); menu_dom=1 & vts=00 => VMGM; menu_dom=1 & vts>0 => VTSM.
    "TR  rd_state  ",  # 21 LIVE reader debug_state {iso_mode15,iso_err14,selvalid13,best_cnt[12:8],menu_dom7,S_STILL6,rd_state[5:0]}
    "TR  lastjump  ",  # 22 last VM jump {jump_domain[15:14], jump_vts[13:7], jump_pgcn[6:0]}  (dom 3=TT 1=VMGM 2=VTSM)
    "TR  load[0]new",  # 23 PGC-load history newest {menu_dom15, vts[14:8], pgcn[7:0]}
    "TR  load[1]   ",  # 24 PGC-load history [1]
    "TR  load[2]   ",  # 25 PGC-load history [2]
    # Row 26 (2026-08-27, menu-link/audio-map branch — replaced the answered
    # dbg_promo probe): the reader's LAST pgc_error cause, latched at the error
    # site. {reason[15:13], nr_srp_sat[12:8] (PGCIT SRP count, sat 31),
    # want_pgcn[7:0]}. reason: 1=empty PGCIT, 2=PGCN out of the LU's range (the
    # failed-menu-link signature), 3=bad pgc_start, 4=JumpTT resolve,
    # 5=no PGCI_UT, 6=bad UT header, 7=VTS/menu-VOB not found.
    "pgc_err reason",  # 26 {reason, nr_srp, want_pgcn}
    # --- Thayer menu-audio flow-control (row 27) ---
    # {vbuf_fill[15:8], thr_sticky7, fifo_sticky6, aud_bp_sticky5, aud_bp_armed4,
    #  aud_ring_low3, menu_aud_live2, menu_vbuf_over1, menu_active0}
    # thr = menu VBUF cap stalling the reader; fifo = ps_stream_fifo full (demux
    # jammed: video VBUF-full or ring backpressure); aud_bp = ring almost_full
    # backpressure. Sticky bits OR'd per frame.
    "flowctl       ",  # 27 {vbuf_fill, stall/guard flags}
]
SIGNED_MS_ROWS = {17}       # vid_err renders signed + ms (re-added 2026-07-05)
MS_PER_UNIT = 1000.0 / 59.94   # vid_err unit = 1 display refresh (NTSC; PAL would be 20 ms)


# ---- video I/O via ffmpeg ----------------------------------------------------
def probe(video):
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height,r_frame_rate,duration",
         "-of", "json", video])
    st = json.loads(out)["streams"][0]
    num, den = st["r_frame_rate"].split("/")
    fps = float(num) / float(den)
    return int(st["width"]), int(st["height"]), fps, float(st.get("duration") or 0)


def grab_frame(video, t, w, h):
    raw = subprocess.check_output(
        ["ffmpeg", "-v", "error", "-ss", f"{t:.3f}", "-i", video,
         "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    if len(raw) < w * h * 3:
        raise RuntimeError(f"no frame at t={t}")
    return np.frombuffer(raw[: w * h * 3], np.uint8).reshape(h, w, 3)


def stream_frames(video, w, h, every=None, start=0.0, end=None):
    """Yield (t, frame). every=None -> native rate."""
    cmd = ["ffmpeg", "-v", "error"]
    if start:
        cmd += ["-ss", f"{start:.3f}"]
    cmd += ["-i", video]
    if end is not None:
        cmd += ["-t", f"{end - start:.3f}"]
    vf = f"fps=1/{every}" if every else None
    if vf:
        cmd += ["-vf", vf]
    cmd += ["-f", "rawvideo", "-pix_fmt", "rgb24", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    n, fsz = 0, w * h * 3
    try:
        while True:
            raw = p.stdout.read(fsz)
            if len(raw) < fsz:
                break
            t = start + n * (every if every else 0)
            yield t, np.frombuffer(raw, np.uint8).reshape(h, w, 3)
            n += 1
    finally:
        p.kill()
        p.wait()


# ---- calibration --------------------------------------------------------------
def auto_find_panel(frame):
    """Find the overlay panel bbox in capture px. The panel is a large dark
    rectangle whose interior is only {panel-dark, dim-gray, white, green, red}.
    Returns (px0, py0, px1, py1) or None."""
    f = frame.astype(np.int16)
    luma = f.mean(axis=2)
    r, g, b = f[..., 0], f[..., 1], f[..., 2]
    sat = f.max(axis=2) - f.min(axis=2)
    dark = (luma < 70) & (sat < 40)                       # panel / gaps
    dim = (luma >= 25) & (luma < 95) & (sat < 40)         # 0-cells
    white = luma > 170                                    # 1-cells
    green = (g > 110) & (r < 90) & (b < 90)               # flag asserted
    red = (r > 110) & (g < 90) & (b < 90)                 # flag deasserted
    palette = dark | dim | white | green | red
    h, w = luma.shape
    # search the top-left ~70% of the frame for dense palette rows/cols
    sub = palette[: int(h * 0.97), : int(w * 0.75)]   # 0.97: NROW=27 panel is tall
    colden = sub.mean(axis=0)
    rowden = sub.mean(axis=1)

    def longest_run(dens, thresh):
        best, cur, s, bs = 0, 0, 0, 0
        for i, v in enumerate(dens > thresh):
            if v:
                if cur == 0:
                    s = i
                cur += 1
                if cur > best:
                    best, bs = cur, s
            else:
                cur = 0
        return (bs, bs + best) if best else None

    # the panel occupies a contiguous dense span in both projections
    cs = longest_run(colden, 0.30)
    rs = longest_run(rowden, 0.30)
    if not cs or not rs:
        return None
    px0, px1 = cs
    py0, py1 = rs
    # refine: within that band, panel pixels specifically
    band = palette[py0:py1, px0:px1]
    ys, xs = np.nonzero(band)
    if len(xs) < 1000:
        return None
    bx0, by0 = px0 + xs.min(), py0 + ys.min()
    bx1, by1 = px0 + xs.max() + 1, py0 + ys.max() + 1
    # sanity: the panel is 272x332 CORE px; at any plausible scale it cannot
    # span most of the frame. A mostly-dark SCENE matches the palette
    # everywhere and yields a window-sized bbox — reject it (the candidate
    # geometry search below takes over).
    if (bx1 - bx0) > 0.55 * w or (by1 - by0) > 0.96 * h:   # 0.96: NROW=27 tall panel
        return None
    return (bx0, by0, bx1, by1)


def candidate_cals(w, h):
    """Plausible MiSTer-scaler core->capture mappings for this capture size:
    NTSC/PAL core heights x {fractional fill, integer vscale} x
    {4:3 pillarbox, 16:9 full-width stretch, 1:1 PAR}. The row-3 frame-counter
    validation picks the right one — works even on an all-dark scene."""
    cands = []
    for core_h in (480, 576):
        sys_ = {h / core_h}
        if h // core_h >= 1:
            sys_.add(float(h // core_h))
        for sy in sorted(sys_, reverse=True):
            y0 = (h - core_h * sy) / 2.0
            for aw in {sy * core_h * 4.0 / 3.0, float(w), 720.0 * sy}:
                if aw > w + 4:
                    continue
                cands.append({"x0": (w - aw) / 2.0, "y0": y0,
                              "sx": aw / 720.0, "sy": sy})
    out = []
    for c in cands:
        if not any(all(abs(c[k] - d[k]) < 0.01 for k in c) for d in out):
            out.append(c)
    return out


def cal_from_box(box):
    px0, py0, px1, py1 = box
    sx = (px1 - px0) / (BOXX1 - BOXX0)
    sy = (py1 - py0) / (BOXY1 - BOXY0)
    return {"x0": px0 - BOXX0 * sx, "y0": py0 - BOXY0 * sy, "sx": sx, "sy": sy}


def refine_subcell(frame, cal, span=8):
    """Maximize cell-vs-gap contrast over sub-cell offsets (the grid is 16-px
    periodic, so this aligns PHASE only; whole-cell aliases are resolved by
    dealias() below)."""
    luma = frame.mean(axis=2)
    H, W = luma.shape
    cell_pts, gap_pts = [], []
    for r in range(NROW):
        cy = Y0 + 16 * r + CELLH / 2.0
        for c in range(NCOL):
            cell_pts.append((X0 + 16 * c + CELLW / 2.0, cy))
            gap_pts.append((X0 + 16 * c - 1.0, cy))
    cell_pts = np.array(cell_pts)
    gap_pts = np.array(gap_pts)

    def sample(pts, dx, dy):
        xs = (cal["x0"] + cal["sx"] * (pts[:, 0] + dx)).astype(int).clip(0, W - 1)
        ys = (cal["y0"] + cal["sy"] * (pts[:, 1] + dy)).astype(int).clip(0, H - 1)
        return luma[ys, xs]

    # SIGNED score: cells (dim 42 / white 255) are BRIGHTER than the panel gaps
    # (~16-24). An |abs| score would tie at a half-cell offset (roles swap);
    # the signed mean does not.
    best, bdx, bdy = -1e9, 0, 0
    for dy in range(-span, span + 1):
        for dx in range(-span, span + 1):
            sc = float((sample(cell_pts, dx, dy) - sample(gap_pts, dx, dy)).mean())
            if sc > best:
                best, bdx, bdy = sc, dx, dy
    out = dict(cal)
    out["x0"] = cal["x0"] + bdx * cal["sx"]
    out["y0"] = cal["y0"] + bdy * cal["sy"]
    return out, (bdx, bdy)


def dealias(frames, cal):
    """The 16-px cell lattice makes whole-cell shifts look locally perfect
    (this exactly happened on HW: a 3-column shift read every row <<3 and
    still 'looked' like a grid). Row 3 is the semantic anchor — a free-running
    frame counter that increments by 1 per frame ONLY at zero shift (a shift
    of s columns makes the observed delta 2^s). Try whole-cell shifts ordered
    by distance and keep the one whose row-3 deltas validate."""
    shifts = sorted(((sc, sr) for sc in range(-6, 7) for sr in range(-3, 4)),
                    key=lambda p: (abs(p[0]) + abs(p[1])))
    for sc, sr in shifts:
        c = dict(cal)
        c["x0"] = cal["x0"] + 16 * sc * cal["sx"]
        c["y0"] = cal["y0"] + 16 * sr * cal["sy"]
        ok, seen = validate_frames(frames, c)
        if ok:
            return c, (sc, sr), seen
    return None, None, []


def integrity_check(video, cal, w, h, t0, dur=0):
    """Cheap pre-flight for read/csv: row 3 must increment ~1/frame. Probes up
    to three timestamps — a recording's head may predate the core loading (the
    counter legitimately dead there), which must not condemn a good cal."""
    probes = [t0]
    if dur > 0:
        probes += [t0 + dur * 0.3, t0 + dur * 0.6]
    for t in probes:
        ok, _ = validate_cal(video, cal, w, h, t)
        if ok:
            # the row-3 vote alone passed a 3:4 pitch alias once (drift5c);
            # require the physical grid pitch to agree with the cal too
            try:
                frame = grab_frame(video, t, w, h)
            except RuntimeError:
                continue
            if pitch_ok(frame, cal):
                return True
    return False


def refine_columns(frame, cal):
    """Locate each column's TRUE capture-x center by segmenting the luma
    profile of the grid band: cells (dim 42 / white 255) are runs brighter than
    the panel (~16-24) separated by 2-px gaps. Any monotonic warp preserves
    the ORDER of the 16 runs, so run k = column k regardless of how far the
    capture chain displaced it (HW: four columns sat >half a cell off a
    validated affine — beyond what any affine or small comb search can fix).
    Returns cal with "colpx" = [16 capture x centers], or unchanged if the
    segmentation does not find exactly 16 runs."""
    luma = frame.mean(axis=2)
    H, W = luma.shape
    ys = []
    for r in range(NROW):
        py = int(cal["y0"] + cal["sy"] * (Y0 + 16 * r + CELLH / 2.0))
        for o in (-1, 0, 1):
            if 0 <= py + o < H:
                ys.append(py + o)
    x_lo = int(cal["x0"] + cal["sx"] * (X0 - 4))
    x_hi = int(cal["x0"] + cal["sx"] * (X0 + 15 * 16 + CELLW + 4))
    x_lo, x_hi = max(0, x_lo), min(W, x_hi)
    prof = luma[np.array(ys)][:, x_lo:x_hi].mean(axis=0)
    dark = np.percentile(prof, 12)
    lite = np.percentile(prof, 88)
    thr = dark + 0.35 * (lite - dark)
    on = prof > thr
    # merge sub-2px dark notches, then collect runs
    runs, i = [], 0
    n = len(on)
    while i < n:
        if on[i]:
            j = i
            while j < n and (on[j] or (j + 2 < n and (on[j + 1] or on[j + 2]))):
                j += 1
            runs.append((i, j))
            i = j
        else:
            i += 1
    runs = [(a, b) for a, b in runs if (b - a) >= cal["sx"] * CELLW * 0.4]
    if len(runs) != NCOL:
        return cal, len(runs)
    cal2 = dict(cal)
    cal2["colpx"] = [x_lo + (a + b) / 2.0 for a, b in runs]
    return cal2, NCOL


def cell_patch(frame, cal, row, col):
    """RGB of cell (row,col): the BRIGHTEST of three probe patches across the
    cell's width. A single center probe can land in the inter-cell gap when the
    capture chain warps the grid non-affinely (HW: a real recording read every
    4th column permanently dark — nearest-neighbour scaler phase pushed those
    centers into the gap; words read value & 0xBBBB). A cell is white/dim
    across its whole 14-px width, the 2-px gap is not, so max-of-three probes
    is immune while never brightening a genuinely dim cell."""
    cy = Y0 + 16 * row + CELLH / 2.0
    h, w = frame.shape[:2]
    hw = max(1, int(cal["sx"] * CELLW * 0.18))
    hh = max(1, int(cal["sy"] * CELLH * 0.25))
    colpx = cal.get("colpx")
    best, best_luma = None, -1.0
    for fx in (0.28, 0.5, 0.72):
        if colpx is not None:
            px = colpx[col] + cal["sx"] * CELLW * (fx - 0.5)
        else:
            px = cal["x0"] + cal["sx"] * (X0 + 16 * col + CELLW * fx)
        py = cal["y0"] + cal["sy"] * cy
        x0, x1 = int(px) - hw, int(px) + hw + 1
        y0, y1 = int(py) - hh, int(py) + hh + 1
        x0, x1 = max(0, x0), min(w, x1)
        y0, y1 = max(0, y0), min(h, y1)
        if x1 <= x0 or y1 <= y0:
            continue
        rgb = frame[y0:y1, x0:x1].reshape(-1, 3).mean(axis=0)
        luma = float(rgb.mean())
        if luma > best_luma:
            best, best_luma = rgb, luma
    return best


def decode_rows(frame, cal):
    """-> list of 20 ints (rows 4/5 encoded too: row4 = 8 flag bits in [7:0]
    matching flags_d, row5 = nibble)."""
    vals = []
    for rrow in range(NROW):
        v = 0
        for col in range(NCOL):
            rgb = cell_patch(frame, cal, rrow, col)
            luma = rgb.mean()
            if rrow == 4:
                if col < 8:
                    # green = asserted; flag_val = flags_d[col]. Key on the
                    # GREEN channel, not mean luma: the RTL's green (0,C0,0)
                    # captures at ~(3,141,6) = luma 50, under a luma-60 gate
                    # (rec5: the whole flag row read 0x00 for the entire run).
                    if rgb[1] > rgb[0] + 20 and rgb[1] > 60:
                        v |= 1 << col
                continue
            if rrow == 5:
                if col < 4 and luma > 140:
                    v |= 1 << (3 - col)
                continue
            if luma > 140:
                v |= 1 << (15 - col)
        vals.append(v)
    return vals


def fetch_frames(video, w, h, t0, n=14):
    """Grab n consecutive native-rate frames once; the geometry search then
    runs entirely in memory (it would otherwise spawn one ffmpeg per shift
    hypothesis)."""
    frames = []
    for i, (_, fr) in enumerate(stream_frames(video, w, h, every=None, start=t0,
                                              end=t0 + 1.0)):
        frames.append(fr)
        if i >= n - 1:
            break
    return frames


def decode_row_word(frame, cal, rrow):
    """Fast single-row decode (block-bit rows only) for the geometry search.
    Returns None if any cell lands outside the frame (a dealias shift probe can
    push the lattice off-screen; that must read as invalid, not crash)."""
    v = 0
    for col in range(NCOL):
        patch = cell_patch(frame, cal, rrow, col)
        if patch is None:
            return None
        if patch.mean() > 140:
            v |= 1 << (15 - col)
    return v


def validate_frames(frames, cal):
    """row 3 (frame counter) must increment by exactly 1 across consecutive
    frames (dups 0 / a dropped capture frame 2 tolerated) — and EVERY delta
    must, not just a majority. A wrong column PITCH (e.g. affine sx=2.0 against
    a true 2.667 full-width scale) reads bits [15:4] from cells [12:3] with
    every 4th column duplicated: the low nibble still counts +1 per frame, so
    12 of 13 deltas are exactly 1 and a majority vote PASSES — while every 8th
    frame the duplicated bit-3 cell fires a +9/+17 burst. That alias shipped a
    whole telemetry round whose counters read ~4x-13x their true rate
    (drift5c, 2026-07-04). Any delta outside {0,1,2} = misdecode = reject."""
    vals = [decode_row_word(fr, cal, 3) for fr in frames]
    if len(vals) < 4 or any(v is None for v in vals):
        return False, vals
    deltas = [(b - a) & 0xFFFF for a, b in zip(vals, vals[1:])]
    ones = sum(1 for d in deltas if d == 1)
    strict = all(d in (0, 1, 2) for d in deltas)
    # Increment-rate gate, RATE-AWARE (2026-08-02): at 59.94 Hz core vs ~60 fps
    # capture the counter bumps on ~all frames (ones ~ 1.0), but in Film 24p it
    # runs at 23.976/s so only ~0.4 of capture-frame deltas are 1 — the old
    # `ones > 0.5*len` majority rejected every calibration of a 24p capture.
    # The alias trap is carried by `strict` (a pitch alias fires +9/+17 bursts,
    # outside {0,1,2}); the ones-floor only needs to reject a DEAD counter.
    # Accept any live rate from 24p (0.4) down to a safety floor of 0.2.
    return strict and ones > len(deltas) * 0.2, vals


def measure_pitch(frame, cal):
    """Measure the grid's TRUE horizontal cell pitch (capture px) from the luma
    profile of the cell band, via autocorrelation. Independent of the cal's sx
    (the cal only locates the band vertically and roughly horizontally), so it
    cross-checks a hypothesised sx against physical reality: a 3:4 pitch alias
    passes row-3 majority voting but is ~33% off here. Returns pitch or None."""
    luma = frame.mean(axis=2)
    H, W = luma.shape
    ys = []
    for r in range(NROW):
        py = int(cal["y0"] + cal["sy"] * (Y0 + 16 * r + CELLH / 2.0))
        for o in (-1, 0, 1):
            if 0 <= py + o < H:
                ys.append(py + o)
    if not ys:
        return None
    # generous x window: the hypothesis sx may be too SMALL, so widen by 1.5x
    x_lo = int(cal["x0"] + cal["sx"] * (X0 - 8))
    x_hi = int(cal["x0"] + cal["sx"] * (X0 + NCOL * 16 + 8) * 1.5)
    x_lo, x_hi = max(0, x_lo), min(W, x_hi)
    prof = luma[np.array(ys)][:, x_lo:x_hi].mean(axis=0)
    if len(prof) < 3 * PITCH:
        return None
    p = prof - prof.mean()
    ac = np.correlate(p, p, "full")[len(p) - 1:]
    lo, hi = int(PITCH * 0.75), int(PITCH * 4.5)  # sx ~0.75..4.5
    if hi >= len(ac):
        return None
    lag = lo + int(np.argmax(ac[lo:hi]))
    # refine to sub-px by parabolic interpolation around the peak
    if 1 <= lag < len(ac) - 1:
        y0_, y1_, y2_ = ac[lag - 1], ac[lag], ac[lag + 1]
        den = (y0_ - 2 * y1_ + y2_)
        if den != 0:
            lag = lag + 0.5 * (y0_ - y2_) / den
    return float(lag)


def pitch_ok(frame, cal, verbose=False):
    """True if the measured grid pitch agrees with cal['sx']*16 within 6%."""
    got = measure_pitch(frame, cal)
    want = cal["sx"] * PITCH
    ok = got is not None and abs(got - want) < 0.06 * want
    if verbose and got is not None:
        print(f"  pitch check: measured {got:.2f} px vs cal {want:.2f} px "
              f"({'OK' if ok else 'MISMATCH'})")
    return ok


def validate_cal(video, cal, w, h, t0):
    return validate_frames(fetch_frames(video, w, h, t0), cal)


def annotate_png(frame, cal, path):
    """Write a PNG with sampling points marked (via ffmpeg)."""
    img = frame.copy()
    for rrow in range(NROW):
        for col in range(NCOL):
            cx = X0 + 16 * col + CELLW / 2.0
            cy = Y0 + 16 * rrow + CELLH / 2.0
            px = int(cal["x0"] + cal["sx"] * cx)
            py = int(cal["y0"] + cal["sy"] * cy)
            if 1 <= px < img.shape[1] - 1 and 1 <= py < img.shape[0] - 1:
                img[py - 1: py + 2, px, :] = [255, 0, 255]
                img[py, px - 1: px + 2, :] = [255, 0, 255]
    h, w = img.shape[:2]
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
         "-s", f"{w}x{h}", "-i", "-", "-frames:v", "1", path],
        input=img.tobytes(), check=True)


# ---- pretty printing -----------------------------------------------------------
def fmt_row(i, v):
    s = f" row {i:2d} {ROW_LABELS[i]} 0x{v:04X}"
    if i == 4:
        names = ["sa", "hd", "ack", "sdram", "vld_err", "WD!", "cbusy", "vbw"]
        s += "  [" + " ".join(n for bit, n in enumerate(names) if v >> bit & 1) + "]"
    elif i == 5:
        s = f" row {i:2d} {ROW_LABELS[i]} 0x{v & 0xF:X}"
    elif i in SIGNED_MS_ROWS:
        sv = v - 0x10000 if v & 0x8000 else v
        s += f"  ({sv:+d} = {sv * MS_PER_UNIT:+.1f} ms)"
    elif i in (18, 19):
        # {mm_bcd, ss_bcd}: DVD current/total time from the NAV-pack DSI / PGC
        mm = ((v >> 12 & 0xF) * 10) + (v >> 8 & 0xF)
        ss = ((v >> 4 & 0xF) * 10) + (v & 0xF)
        s += f"  ({mm:02d}:{ss:02d})"
    elif i in (10, 11, 13, 16):
        s += f"  ({{{v >> 8 & 0xFF}, {v & 0xFF}}})"
    return s


# ---- selftest: render a synthetic capture and decode it -------------------------
def render_overlay(vals, sx=2.37, sy=2.25, ox=13.0, oy=7.0, noise=6):
    """Draw the overlay per debug_overlay.sv at core res, scale by (sx,sy),
    offset (ox,oy), add noise — a fake capture frame."""
    core = np.zeros((480, 720, 3), np.uint8)
    core[:] = (90, 40, 120)                      # arbitrary "video"
    core[BOXY0:BOXY1, BOXX0:BOXX1] = (0x10, 0x10, 0x18)
    for rrow in range(NROW):
        for col in range(NCOL):
            y = Y0 + 16 * rrow
            x = X0 + 16 * col
            if rrow == 4:
                if col < 8:
                    on = vals[4] >> col & 1
                    core[y:y + CELLH, x:x + CELLW] = (0, 0xC0, 0) if on else (0xC0, 0, 0)
                continue
            if rrow == 5:
                if col < 4:
                    bit = vals[5] >> (3 - col) & 1
                    core[y:y + CELLH, x:x + CELLW] = (255, 255, 255) if bit else (42, 42, 42)
                continue
            bit = vals[rrow] >> (15 - col) & 1
            core[y:y + CELLH, x:x + CELLW] = (255, 255, 255) if bit else (42, 42, 42)
    H, W = int(480 * sy) + int(oy) + 20, int(720 * sx) + int(ox) + 20
    yy = ((np.arange(H) - oy) / sy).clip(0, 479).astype(int)
    xx = ((np.arange(W) - ox) / sx).clip(0, 719).astype(int)
    cap = core[yy][:, xx].astype(np.int16)
    cap += np.random.default_rng(1).integers(-noise, noise + 1, cap.shape)
    return cap.clip(0, 255).astype(np.uint8)


def selftest():
    rng = np.random.default_rng(42)
    vals = [int(rng.integers(0, 0x10000)) for _ in range(NROW)]
    vals[4] &= 0xFF
    vals[5] &= 0xF
    frame = render_overlay(vals)
    box = auto_find_panel(frame)
    assert box, "selftest: panel not found"
    cal = cal_from_box(box)
    got = decode_rows(frame, cal)
    ok = True
    for i, (a, b) in enumerate(zip(vals, got)):
        if a != b:
            print(f"selftest MISMATCH row {i}: wrote 0x{a:04X} read 0x{b:04X}")
            ok = False
    print("selftest:", f"PASS (auto-calibrated, all {NROW} rows round-trip)" if ok else "FAIL")

    # ---- pitch-alias trap (the drift5c incident, 2026-07-04) ---------------
    # A 1920-wide full-width capture of the 720 core has sx = 2.667. An affine
    # with sx = 2.0, right-aligned on the grid, reads the low nibble correctly
    # (+1/frame most frames) and every 4th column duplicated — the row-3
    # MAJORITY vote passed it and a whole telemetry round shipped counters
    # reading 4x-13x high. Assert both new gates catch it.
    sx_true, sy_true, ox, oy = 2.0 * 4 / 3, 2.25, 13.0, 7.0
    seq = []
    for i in range(14):
        v = list(vals)
        v[3] = 4 + i                    # crosses bit 3 mid-sequence
        seq.append(render_overlay(v, sx=sx_true, sy=sy_true, ox=ox, oy=oy))
    good = {"x0": ox, "y0": oy, "sx": sx_true, "sy": sy_true}
    # right-align the bad grid on the true one: col 15 coincides, drift leftward
    bad = {"x0": ox + (sx_true - 2.0) * (X0 + 15 * 16 + CELLW / 2.0),
           "y0": oy, "sx": 2.0, "sy": sy_true}
    trap_ok = True
    if pitch_ok(seq[0], bad):
        print("selftest ALIAS TRAP: pitch_ok ACCEPTED sx=2.0 on a 2.667 capture")
        trap_ok = False
    if validate_frames(seq, bad)[0]:
        print("selftest ALIAS TRAP: validate_frames ACCEPTED the 3:4 pitch alias")
        trap_ok = False
    if not pitch_ok(seq[0], good):
        print("selftest ALIAS TRAP: pitch_ok REJECTED the correct geometry")
        trap_ok = False
    if not validate_frames(seq, good)[0]:
        print("selftest ALIAS TRAP: validate_frames REJECTED the correct geometry")
        trap_ok = False
    print("selftest alias trap:", "PASS" if trap_ok else "FAIL")
    ok = ok and trap_ok
    return 0 if ok else 1


# ---- main -----------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("calibrate", "read", "csv"):
        p = sub.add_parser(name)
        p.add_argument("video")
        p.add_argument("--cal", default="tools/osd_cal.json")
    sub.choices["calibrate"].add_argument("--time", type=float, default=5.0)
    sub.choices["calibrate"].add_argument("--box", help="manual panel bbox X0,Y0,X1,Y1 (capture px)")
    sub.choices["calibrate"].add_argument("--png", default="osd_calibrated.png")
    sub.choices["read"].add_argument("--time", required=True,
                                     help="timestamp(s), comma-separated seconds")
    sub.choices["read"].add_argument("--rows", help="only these rows, comma-separated")
    sub.choices["csv"].add_argument("--every", type=float, default=1.0)
    sub.choices["csv"].add_argument("--start", type=float, default=0.0)
    sub.choices["csv"].add_argument("--end", type=float)
    sub.choices["csv"].add_argument("--out", default="-")
    sub.add_parser("selftest")
    args = ap.parse_args()

    if args.cmd == "selftest":
        sys.exit(selftest())

    w, h, fps, dur = probe(args.video)

    if args.cmd == "calibrate":
        frame = grab_frame(args.video, args.time, w, h)
        # Coarse hypotheses in priority order; EACH gets the sub-cell phase
        # refine + whole-cell de-alias before its row-3 verdict — a hypothesis
        # a few pixels or whole cells off is recoverable, not a failure (the HW
        # capture that motivated this was a standard geometry 3 cells off).
        frames = fetch_frames(args.video, w, h, args.time)
        if len(frames) < 4:
            sys.exit(f"could not read frames at --time {args.time}")
        hyps = []
        if args.box:
            hyps.append((f"manual box", cal_from_box(
                tuple(int(x) for x in args.box.split(",")))))
        else:
            pbox = auto_find_panel(frame)
            if pbox:
                hyps.append((f"palette bbox {pbox}", cal_from_box(pbox)))
            hyps += [(f"scaler sx={c['sx']:.4f} sy={c['sy']:.4f} "
                      f"x0={c['x0']:.1f} y0={c['y0']:.1f}", c)
                     for c in candidate_cals(w, h)]
        cal, seen = None, []
        for name, c0 in hyps:
            c1, (fdx, fdy) = refine_subcell(frame, c0)
            # physical pitch gate BEFORE the row-3 vote: a 3:4 pitch alias
            # (sx=2.0 vs true 2.667) reads a valid-looking counter (see
            # validate_frames) — but its grid pitch is ~33% off the actual
            # cell lattice, which the luma autocorrelation measures directly.
            if not pitch_ok(frame, c1, verbose=True):
                print(f"  {name}: no (pitch mismatch)")
                continue
            c2, shift, vseen = dealias(frames, c1)
            if c2 is not None:
                print(f"  {name}: PASS (refine ({fdx},{fdy}) px, cell shift {shift})")
                cal, seen = c2, vseen
                break
            print(f"  {name}: no")
        if cal is None:
            sys.exit("no geometry validated — grab a timestamp where the overlay "
                     "is clearly visible (try another --time), or pass "
                     "--box X0,Y0,X1,Y1 (panel corners in capture pixels)")
        cal2, nruns = refine_columns(frame, cal)
        if "colpx" in cal2:
            ok2, seen2 = validate_frames(frames, cal2)
            if ok2:
                affine_px = [cal["x0"] + cal["sx"] * (X0 + 16 * c + CELLW / 2.0)
                             for c in range(NCOL)]
                dev = [round(p - a, 1) for p, a in zip(cal2["colpx"], affine_px)]
                print(f"per-column centers locked (deviation from affine, capture px): {dev}")
                cal, seen = cal2, seen2
            else:
                print("per-column segmentation failed row-3 validation; keeping affine")
        else:
            print(f"column segmentation found {nruns}/16 runs; keeping affine sampling")
        ok = True
        annotate_png(frame, cal, args.png)
        print(f"cal: {json.dumps({k: (round(v, 4) if isinstance(v, float) else v) for k, v in cal.items()})}")
        print(f"row-3 frame counter across ~13 frames: {[hex(v) for v in seen]}")
        print(f"validation (counter increments): {'PASS' if ok else 'FAIL'}")
        print(f"sampling points written to {args.png} — verify crosses hit cell centers")
        if ok:
            with open(args.cal, "w") as f:
                json.dump(cal, f)
            print(f"calibration saved to {args.cal}")
        sys.exit(0 if ok else 1)

    try:
        cal = json.load(open(args.cal))
    except FileNotFoundError:
        sys.exit(f"no calibration at '{args.cal}' — run the one-time step first:\n"
                 f"    python3 tools/osd_read.py calibrate <recording> --time <secs-with-overlay-visible>\n"
                 f"(it saves {args.cal} on validation PASS; or point --cal at an existing file)")

    if args.cmd == "read":
        rows = [int(r) for r in args.rows.split(",")] if args.rows else range(NROW)
        times = [float(x) for x in args.time.split(",")]
        if not integrity_check(args.video, cal, w, h, times[0], dur):
            print("WARNING: row-3 frame-counter integrity check FAILED at "
                  f"t={times[0]} — the calibration does not fit this recording "
                  "(re-run calibrate on THIS file); values below are suspect",
                  file=sys.stderr)
        for t in times:
            frame = grab_frame(args.video, t, w, h)
            vals = decode_rows(frame, cal)
            print(f"t={t:.3f}s")
            for i in rows:
                print(fmt_row(i, vals[i]))
            print()

    elif args.cmd == "csv":
        if not integrity_check(args.video, cal, w, h, args.start + 1.0,
                               (args.end or dur) - args.start):
            print("WARNING: row-3 frame-counter integrity check FAILED — the "
                  "calibration does not fit this recording (re-run calibrate on "
                  "THIS file); CSV values are suspect", file=sys.stderr)
        out = sys.stdout if args.out == "-" else open(args.out, "w")
        hdr = ",".join(f"row{i:02d}" for i in range(NROW))
        print(f"t,{hdr}", file=out)
        for t, frame in stream_frames(args.video, w, h, every=args.every,
                                      start=args.start,
                                      end=args.end or (dur if dur > 0 else None)):
            vals = decode_rows(frame, cal)
            print(f"{t:.3f}," + ",".join(f"0x{v:04X}" for v in vals), file=out)
        if out is not sys.stdout:
            out.close()
            print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
