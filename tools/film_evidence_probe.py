#!/usr/bin/env python3
# =============================================================================
# film_evidence_probe.py -- what evidence does the video stream ACTUALLY carry?
# =============================================================================
# The film/video detector in dvd/resample_addrgen.v keys on ONE bit,
# progressive_frame, and that bit is not a measurement: it is what the ENCODER
# chose to write into the MPEG-2 picture coding extension. On a near-black
# frame there is no field structure to analyse, so the encoder falls back to
# the MPEG-2 default and marks it interlaced (mismarking progressive costs
# visible artifacts; mismarking interlaced costs a few bytes of disc space).
# Our detector then counts that meaningless flag at full weight, DN_HARD=8 --
# which is why APOLLO_13's fading credits knock it out of film lock repeatedly.
#
# VLC does not have this problem because its IVTC reads PIXELS and explicitly
# discards uninformative frames as evidence ("If no motion, the result from
# this algorithm cannot be reliable"). We cannot read pixels at the display
# pickup, but we are not out of options -- and docs/film_24p_plan.md §14's
# claim that "no threshold tuning or cleverer flag rule can help" was only ever
# tested against progressive_frame alone. This tool tests the alternatives.
#
# It walks a CONTIGUOUS region of a title (the census samples spread windows
# instead), reorders to DISPLAY order -- coded order hides the flapping behind
# B-frame reordering -- and records, per picture, every field the VLD already
# parses that could serve as evidence:
#
#   progressive_frame     ext bit 32  (rtl/mpeg2/vld.v:1462)  today's evidence
#   repeat_first_field    ext bit 30  (vld.v rff)             the 3:2 toggle
#   frame_pred_frame_dct  ext bit 25  (vld.v:1455, offset 5)  CANDIDATE B
#   picture_structure     ext bits 22-23 (vld.v:1453)         frame vs field
#   coded picture size    start code to start code            CANDIDATE A
#
# Field offsets are taken from OUR decoder rather than from the spec, the same
# discipline tools/video_cadence_census.py uses, so probe and RTL cannot drift.
#
# It then replays main's EXACT detector arithmetic over the trace and counts
# engage/disengage transitions, first for the shipped evidence (which must
# reproduce the documented APOLLO_13 baseline before any candidate is trusted)
# and then for each candidate rule.
#
# Usage:
#   tools/film_evidence_probe.py <iso> [--vts N] [--start-frac 0.0] [--sectors 4000]
#   tools/film_evidence_probe.py <iso> --csv /tmp/trace.csv
#   tools/film_evidence_probe.py <iso> --xtab        # the flag cross-tabulation
# =============================================================================
import sys, os, argparse, csv, statistics

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dvd_vm_ref import IsoNav                       # noqa: E402
from video_cadence_census import video_payload      # noqa: E402

SEC = 2048

# --- Detector constants: MUST track dvd/resample_addrgen.v:744-751 -----------
CONF_MAX, ENGAGE_TH, DISENGAGE_TH = 127, 120, 24
UP_STEP, DN_SOFT, DN_HARD = 3, 2, 8

FIELD = 1.0 / 59.94                                 # one NTSC field, seconds


# ---------------------------------------------------------------- ES parsing
def parse_pictures(buf):
    """Walk a video ES -> per-picture records in CODED order.

    Coded size is measured start-code-to-start-code, so it includes the slice
    data: that is exactly the "did this frame carry any information" quantity
    14.8 measured (384 B on black vs 20,380 B median) and never wired up.
    """
    pics, cur, gop = [], None, -1
    n = len(buf)

    def close(end):
        nonlocal cur
        if cur is not None:
            cur['size'] = end - cur['off']
            pics.append(cur)
            cur = None

    i = buf.find(b'\x00\x00\x01')
    while i >= 0 and i + 4 <= n:
        sc = buf[i + 3]
        if sc == 0x00:                              # picture_start_code
            close(i)
            if i + 6 <= n:
                p = buf[i + 4:i + 6]
                cur = dict(off=i, gop=gop,
                           tr=(p[0] << 2) | (p[1] >> 6),
                           ct=(p[1] >> 3) & 0x07,
                           prog=None, rff=0, tff=0, fpfd=0, pstruct=3, size=0)
        elif sc in (0xB3, 0xB8, 0xB7):              # sequence / GOP / seq_end
            close(i)
            if sc == 0xB8:
                gop += 1
        elif sc == 0xB5 and cur is not None and cur['prog'] is None:
            if i + 9 <= n:
                e = buf[i + 4:i + 9]
                if (e[0] >> 4) == 0x8:              # picture_coding_extension
                    cur['pstruct'] = e[2] & 0x03
                    cur['tff'] = (e[3] >> 7) & 1
                    cur['fpfd'] = (e[3] >> 6) & 1   # frame_pred_frame_dct
                    cur['rff'] = (e[3] >> 1) & 1
                    cur['prog'] = (e[4] >> 7) & 1
        i = buf.find(b'\x00\x00\x01', i + 3)
    close(n)
    return [p for p in pics if p['prog'] is not None]


def annotate(pics_coded, gate):
    """Run the informativeness gate in CODED order -- which is the only order
    the VLD has -- and stamp the verdict onto each picture. The detector then
    consumes that verdict in DISPLAY order, exactly as the hardware will: the
    running means live in the VLD (clk_dec, coded order), the 1-bit verdict
    rides to the display through motcomp_picbuf alongside progressive_frame.

    Modelling the gate in display order would flatter it -- the reorder is
    small, but 'small' is what the round-11 stale-flags bug was called too.
    """
    for p in pics_coded:
        p['inf'] = gate(p)
    return pics_coded


def display_order(pics):
    """Sort to display order. temporal_reference is display position within a
    GOP, so (gop, tr) IS display order -- and the whole point of the exercise:
    the sustained detector runs on displayed pictures, not coded ones."""
    return sorted(pics, key=lambda p: (p['gop'], p['tr']))


def duration(p):
    """Display duration in seconds. A frame picture shows 2 fields, 3 with rff
    (that is the 3:2 pulldown); a field picture shows 1."""
    return FIELD * (1 if p['pstruct'] != 3 else 2 + p['rff'])


def rel_gate(shift=3, ew=4):
    """CANDIDATE D -- informativeness measured RELATIVE to this stream, per
    picture coding type.

    A fixed byte threshold cannot work, and APOLLO_13 shows exactly why: during
    a fade its B/P pictures collapse to 384 B but the GOP's I-frame still codes
    7,580 B -- tiny against its own ~82,000 B norm, yet far above any threshold
    that does not also swallow legitimate B-frames (median 18,540 B). Comparing
    a picture against the running mean FOR ITS OWN CODING TYPE separates them
    cleanly, and adapts to bitrate and resolution instead of assuming DVD-sized
    pictures.

    The mean updates only on ACCEPTED pictures: otherwise a long dark run drags
    the baseline down to meet itself and starts trusting black frames again.
    """
    avg = {}
    def g(p):
        a = avg.get(p['ct'])
        if a is None:                       # no baseline for this type yet
            avg[p['ct']] = p['size']
            return True
        ok = p['size'] >= (a >> shift)
        if ok:
            avg[p['ct']] = a - (a >> ew) + (p['size'] >> ew)
        return ok
    return g


def peak_gate(shift=3, decay=7):
    """CANDIDATE E -- informativeness relative to a decaying PEAK, per coding
    type. Same idea as D but without D's bootstrap fragility.

    D seeds a running mean from whatever picture happens to arrive first, so
    two rips of near-identical content gated differently depending only on
    where the window started (HIGH_SCHOOL_MUSICAL skipD=0.0% vs PRI0NNW1
    skipD=85.8%, same median, same p10, same p90). A peak needs no seed: it
    starts at zero, the first picture of each type sets it, and it only ever
    rises on real content.

    Decay runs only on ACCEPTED pictures, so a long fade cannot walk the
    reference down to meet itself and start trusting black frames again --
    the failure that makes a fixed threshold break on a longer fade.
    """
    peak = {}
    def g(p):
        k = peak.get(p['ct'], 0)
        ok = p['size'] >= (k >> shift)
        if ok:
            peak[p['ct']] = max(p['size'], k - (k >> decay))
        return ok
    return g


def warm_gate(shift=3, ew=4, warm=16):
    """CANDIDATE F -- D with the bootstrap fixed, which is the whole difference
    between D being right and D being lucky.

    D seeded its mean from the FIRST picture of each coding type, so the gate's
    behaviour depended on where the window happened to start: two rips of
    near-identical content (HIGH_SCHOOL_MUSICAL, PRI0NNW1 -- same median 318 B,
    same p10 288 B, same p90 31,45x B) came out skipping 0.0% and 85.8%.

    F warms up instead. For the first `warm` pictures of a coding type nothing
    is gated and the mean tracks EVERY picture, so it converges on what this
    stream actually looks like. After that the mean updates only on ACCEPTED
    pictures, so a long fade cannot walk the reference down to meet itself.

    That distinction is the entire point: APOLLO_13's 384 B pictures are tiny
    RELATIVE TO THEIR OWN STREAM (median 17,704 B), while HIGH_SCHOOL_MUSICAL's
    318 B pictures ARE the stream. An absolute threshold cannot tell those
    apart, and the core plays VCD/SVCD too, where the whole scale shifts again.
    """
    avg, seen = {}, {}
    def g(p):
        ct = p['ct']
        n = seen.get(ct, 0)
        a = avg.get(ct, p['size'])
        if n < warm:                        # warm-up: gate nothing, learn scale
            seen[ct] = n + 1
            avg[ct] = a - (a >> ew) + (p['size'] >> ew)
            return True
        ok = p['size'] >= (a >> shift)
        if ok:
            avg[ct] = a - (a >> ew) + (p['size'] >> ew)
        return ok
    return g


# ------------------------------------------------------------ detector replay
def simulate(pics, prog_of=None, gate=None):
    """Replay dvd/resample_addrgen.v's accumulators over the display trace.

    prog_of : what stands in for progressive_frame (candidate B)
    gate    : return False to DISCARD a pickup as uninformative (candidate A).
              A discarded pickup updates nothing at all -- not the accumulators
              and not rff_q -- which is VLC's "we do nothing, as it's not a
              good idea to act on unreliable data".
    """
    prog_of = prog_of or (lambda p: p['prog'])
    conf_n = conf_v = 0
    det_n = det_v = 0
    rff_q = 0
    t = 0.0
    events, skipped = [], 0

    for p in pics:
        if gate is not None and not gate(p):
            skipped += 1
            t += duration(p)
            continue
        pr = prog_of(p)
        tog = (p['rff'] != rff_q)
        rff_q = p['rff']

        if pr and tog:   conf_n = min(CONF_MAX, conf_n + UP_STEP)
        elif not pr:     conf_n = max(0, conf_n - DN_HARD)
        else:            conf_n = max(0, conf_n - DN_SOFT)
        nd = 1 if conf_n >= ENGAGE_TH else (0 if conf_n <= DISENGAGE_TH else det_n)
        if nd != det_n:
            events.append((t, 'FILM+' if nd else 'FILM-'))
            det_n = nd

        if not pr: conf_v = min(CONF_MAX, conf_v + UP_STEP)
        else:      conf_v = max(0, conf_v - DN_HARD)
        vd = 1 if conf_v >= ENGAGE_TH else (0 if conf_v <= DISENGAGE_TH else det_v)
        if vd != det_v:
            events.append((t, 'VIDEO+' if vd else 'VIDEO-'))
            det_v = vd

        t += duration(p)
    return dict(events=events, span=t, skipped=skipped,
                film_flips=sum(1 for _, e in events if e.startswith('FILM')))


# ------------------------------------------------------------------ reporting
def pct(vals, q):
    if not vals:
        return 0
    s = sorted(vals)
    return s[min(len(s) - 1, int(q * len(s)))]


def cross_tab(pics):
    """The hypothesis test: is frame_pred_frame_dct honest where
    progressive_frame is lazy? Cells are (progressive_frame, fpfd)."""
    cells = {}
    for p in pics:
        cells.setdefault((p['prog'], p['fpfd']), []).append(p['size'])
    print("  progressive_frame / frame_pred_frame_dct cross-tab")
    print(f"    {'pf':>3} {'fpfd':>5} {'count':>7} {'share':>7} "
          f"{'med size':>9} {'p10':>7} {'p90':>8}")
    tot = len(pics) or 1
    for key in sorted(cells):
        v = cells[key]
        print(f"    {key[0]:>3} {key[1]:>5} {len(v):>7} {100*len(v)/tot:6.1f}% "
              f"{int(statistics.median(v)):>9} {pct(v,0.10):>7} {pct(v,0.90):>8}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('iso')
    ap.add_argument('--vts', type=int, default=None)
    ap.add_argument('--start-frac', type=float, default=0.0,
                    help="where in the title to start (0.0 = head, where the "
                         "APOLLO_13 credits are)")
    ap.add_argument('--sectors', type=int, default=4000,
                    help="contiguous sectors to walk (~8 MB at 2048 B)")
    ap.add_argument('--csv', default=None, help="write the per-picture trace")
    ap.add_argument('--xtab', action='store_true', help="flag cross-tabulation")
    ap.add_argument('--cut', default=None, metavar='STEM',
                    help="write a simulation fixture: STEM.hex (video ES as "
                         "64-bit words) + STEM.golden.hex (one word per "
                         "picture, {informative[24], size_bytes[23:0]}), for "
                         "bench/dvd/film_evidence_tb.sv")
    ap.add_argument('--cut-warm', type=int, default=2,
                    help="EV_WARM the fixture's golden verdicts assume; must "
                         "match the TB's parameter override")
    ap.add_argument('--brief', action='store_true',
                    help="one machine-readable line per disc, for library "
                         "regression sweeps: the gate must never ADD film "
                         "transitions relative to the baseline")
    ap.add_argument('--sweep', default=None,
                    help="comma-separated candidate-A thresholds to compare, "
                         "e.g. 512,768,1024,2048")
    ap.add_argument('--scan', type=int, default=0,
                    help="probe N evenly spaced windows through the title "
                         "instead of one contiguous region (finds where a "
                         "film title turns into real video)")
    ap.add_argument('--small', type=int, default=1000,
                    help="candidate A threshold: coded bytes below which a "
                         "picture is treated as carrying no evidence")
    a = ap.parse_args()

    nav = IsoNav(a.iso)
    vts = a.vts if a.vts is not None else nav.best_vts
    runs = [(ext, dl // SEC) for ext, dl in nav.groups[vts]]
    total = sum(n for _, n in runs)

    def sector_at(idx):
        for ext, n in runs:
            if idx < n:
                return ext + idx
            idx -= n
        return None

    def window(start, count):
        chunks = []
        for k in range(count):
            s = sector_at(start + k)
            if s is None:
                break
            d = video_payload(nav.sec(s))
            if d:
                chunks.append(d)
        return display_order(parse_pictures(b''.join(chunks)))

    # --- --scan: where in the title does the content change? ----------------
    if a.scan:
        print(f"{os.path.basename(a.iso)}  VTS{vts:02d}  {a.scan} windows x "
              f"{a.sectors} sectors across {total} sectors")
        print(f"  {'at%':>5} {'pics':>6} {'sec':>6} {'pf=0%':>6} {'tiny%':>6} "
              f"{'verdict (baseline)':>22}  {'verdict (gate)':>18}")
        for w in range(a.scan):
            st = (total * w) // a.scan
            ps = window(st, a.sectors)
            if not ps:
                continue
            npx = len(ps)
            z = sum(1 for q in ps if not q['prog'])
            tiny = sum(1 for q in ps if q['size'] < a.small)
            b = simulate(ps)
            g = simulate(ps, gate=lambda q: q['size'] >= a.small)

            def fin(r):
                st_ = 'none'
                for _, e in r['events']:
                    st_ = e
                return st_
            print(f"  {100*w/a.scan:5.1f} {npx:>6} {b['span']:6.1f} "
                  f"{100*z/npx:5.1f}% {100*tiny/npx:5.1f}% "
                  f"{fin(b):>22}  {fin(g):>18}")
        return 0

    start = int(total * a.start_frac)
    coded = parse_pictures(b''.join(
        d for d in (video_payload(nav.sec(sector_at(start + k)))
                    for k in range(a.sectors)
                    if sector_at(start + k) is not None) if d))
    pics = display_order(list(coded))
    if not pics:
        print("no pictures found")
        return 1

    span = sum(duration(p) for p in pics)
    sizes = [p['size'] for p in pics]

    if a.cut:
        es = b''.join(
            d for d in (video_payload(nav.sec(sector_at(start + k)))
                        for k in range(a.sectors)
                        if sector_at(start + k) is not None) if d)
        # Start the cut at a SEQUENCE HEADER. The vld refuses picture start
        # codes until sequence_header_seen, so a cut that begins mid-GOP makes
        # the golden count pictures the hardware will never commit -- the two
        # models would then disagree about WHICH picture index they are on,
        # which reads as a size mismatch on every row.
        sh = es.find(b'\x00\x00\x01\xb3')
        if sh < 0:
            print("  no sequence header in this cut -- move --start-frac")
            return 1
        es = es[sh:]
        es += b'\x00' * (-len(es) % 8)
        with open(a.cut + '.hex', 'w') as fh:
            for i in range(0, len(es), 8):
                fh.write(es[i:i+8].hex() + '\n')
        # Golden verdicts come from the CODED-order gate -- the only order the
        # vld has, and the one F' proved equivalent on every disc.
        gold = annotate(parse_pictures(es), warm_gate(warm=a.cut_warm))
        with open(a.cut + '.golden.hex', 'w') as fh:
            for q in gold:
                fh.write(f"{(1 << 24 if q['inf'] else 0) | (q['size'] & 0xFFFFFF):08x}\n")
        print(f"  {a.cut}.hex        {len(es)} B of video ES")
        print(f"  {a.cut}.golden.hex {len(gold)} pictures "
              f"({sum(1 for q in gold if not q['inf'])} uninformative, "
              f"EV_WARM={a.cut_warm})")
        return 0

    if a.brief:
        b = simulate(pics)
        g = simulate(pics, gate=lambda p: p['size'] >= a.small)
        dg = rel_gate()
        d = simulate(pics, gate=dg)
        tiny = sum(1 for p in pics if p['size'] < a.small)

        def flag(r):
            return ('WORSE' if r['film_flips'] > b['film_flips'] else
                    ('better' if r['film_flips'] < b['film_flips'] else 'same'))
        print(f"{os.path.basename(a.iso)[:44]:44s} VTS{vts:02d} "
              f"pics={len(pics):5d} p10={pct(sizes,0.10):6d} "
              f"tinyA={100*tiny/len(pics):5.1f}% "
              f"skipD={100*d['skipped']/len(pics):5.1f}% "
              f"base={b['film_flips']:2d} A={g['film_flips']:2d} D={d['film_flips']:2d} "
              f"A:{flag(g):6s} D:{flag(d)}")
        return 0

    print(f"{os.path.basename(a.iso)}  VTS{vts:02d}  sectors {start}..{start+a.sectors} "
          f"of {total}")
    print(f"  {len(pics)} pictures, {span:.1f} s displayed, "
          f"median coded size {int(statistics.median(sizes))} B, "
          f"p10 {pct(sizes,0.10)} B, p90 {pct(sizes,0.90)} B")
    small = [p for p in pics if p['size'] < a.small]
    print(f"  pictures under {a.small} B: {len(small)} "
          f"({100*len(small)/len(pics):.1f}%), of which "
          f"{sum(1 for p in small if not p['prog'])} are progressive_frame==0")

    if a.xtab:
        cross_tab(pics)

    # --- the four rules, same trace, same arithmetic ------------------------
    rules = [
        ("baseline  (progressive_frame)", None, None),
        ("A  informative-only (size gate)", None,
         lambda p: p['size'] >= a.small),
        ("B  frame_pred_frame_dct", lambda p: p['fpfd'], None),
        ("C  A + B", lambda p: p['fpfd'], lambda p: p['size'] >= a.small),
        ("D  relative mean, per type", None, rel_gate()),
        ("E  relative peak, per type", None, peak_gate()),
        ("F  relative mean + warm-up", None, warm_gate()),
        ("F' same, gate in CODED order", None, 'coded'),
    ]
    if a.sweep:
        print(f"\n  {'threshold':>10} {'film flips':>11} {'skipped':>8} "
              f"{'1st engage':>11}  events")
        cands = [(f"abs {x}", (lambda p, t=int(x): p['size'] >= t))
                 for x in a.sweep.split(',')]
        cands += [(f"rel >>{k}", rel_gate(shift=k)) for k in (2, 3, 4, 5)]
        cands += [(f"peak >>{k}", peak_gate(shift=k)) for k in (2, 3, 4, 5)]
        for th, gt in cands:
            r = simulate(pics, gate=gt)
            first = next((f"{t:.1f}s" for t, e in r['events'] if e == 'FILM+'),
                         '-')
            ev = " ".join(f"{t:.1f}{e}" for t, e in r['events'][:8])
            print(f"  {th:>10} {r['film_flips']:>11} {r['skipped']:>8} "
                  f"{first:>11}  {ev}")
        return 0

    print(f"\n  {'rule':34s} {'film flips':>11} {'skipped':>8}  events")
    for name, prog_of, gate in rules:
        if gate == 'coded':
            annotate(coded, warm_gate())
            gate = (lambda p: p['inf'])
        r = simulate(pics, prog_of, gate)
        ev = " ".join(f"{t:.1f}{e}" for t, e in r['events'][:12])
        if len(r['events']) > 12:
            ev += " ..."
        print(f"  {name:34s} {r['film_flips']:>11} {r['skipped']:>8}  {ev}")

    if a.csv:
        with open(a.csv, 'w', newline='') as fh:
            w = csv.writer(fh)
            w.writerow(['t', 'gop', 'tr', 'coding_type', 'pic_struct',
                        'progressive_frame', 'rff', 'tff',
                        'frame_pred_frame_dct', 'coded_bytes'])
            t = 0.0
            for p in pics:
                w.writerow([f"{t:.4f}", p['gop'], p['tr'], p['ct'], p['pstruct'],
                            p['prog'], p['rff'], p['tff'], p['fpfd'], p['size']])
                t += duration(p)
        print(f"\n  trace -> {a.csv}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
