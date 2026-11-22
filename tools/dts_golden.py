#!/usr/bin/env python3
"""dts_golden.py -- goldens for the DTS engine's RTL benches (docs/dts_decoder.md sec 10).

The emulator (tools/dts_isa.py) runs a window of a raw .dts stream. It must first
agree with tools/dts_fixed.py, the independent model, frame by frame: no golden is
written from an emulator that disagrees. Then this writes what the benches score:

    STEM.bytes    the frames' bytes, hex, one a line
    STEM.frames   each frame's length in bytes, one a line (the engine's descriptor)
    STEM.trace    "kind pc addr value" hex, one event a line (Machine.trace: register
                  writes, stores, XQ's extracted codes) -- bench/dvd/run_dts_seq.sh
    STEM.vops     "op x hist ring buf2" hex, one vector op a line (Machine.checksums
                  after the op) -- bench/dvd/run_dts.sh
    STEM.pcm      "llll rrrr" hex, one stereo pair a line
    STEM.meta     "bytes frames events vops pairs refusals overrun-bits lenient-codes
                  dmix-ignored fs dynf" (fs 1, 48 kHz, MP2's field; dynf the frames
                  whose header sets DYNF, CNT 1, issue #189)"

    tools/dts_golden.py STREAM.dts --out STEM [--skip N] [--frames N] [--refuse K]
                        [--truncate K:N]
    tools/dts_golden.py --codebooks DIR     # the bench's codebook rows (cb_adpcm.mem,
                                            # cb_vq.mem: the engine's 64-bit row format)

--refuse K corrupts frame K's last DSYNC word (one bit), so the engine refuses it after
part of its PCM has already gone out: the refusal must drain the frame's remaining
bytes and leave the decoder's state as the model leaves it.
--truncate K:N delivers frame K N bytes short (its descriptor says the shorter
length): the engine reads past the end as zeros (counted) and refuses the frame; the
model refuses it as an over-read. The next frame proves no byte of it was taken.
Exit 0 written; 5 the emulator disagrees with the model.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dts_fixed as F  # noqa: E402
import dts_isa as I    # noqa: E402
import dts_ref as R    # noqa: E402


def dsync_bitpos(fr, words, labels):
    """The bit position of the frame's LAST DSYNC word (after its last subsubframe,
    so some of the frame's PCM is already out when it is refused), found by running
    the program on the frame alone and noting where each DS_CHK `get` reads."""
    m = I.Machine(words, labels)
    pos = []
    orig = m.bits

    def bits(n):
        if m.pc == labels['DS_CHK']:
            pos.append(m.bitpos)
        return orig(n)
    m.bits = bits
    m.feed(fr)
    m.run()
    if not pos:
        raise SystemExit('dts_golden: no DSYNC read in the frame to refuse')
    return pos[-1]


def write_codebooks(d):
    """The rows dts_vec's codebook port returns: an ADPCM vector, 4 x int16 (coefficient
    i at bits 16i), at row pvq; a VQ vector's slice for subsubframe ssf, 8 x int8 (value
    k at bits 8k), at row {index, ssf}."""
    import dts_tables as T
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'cb_adpcm.mem'), 'w') as f:
        for vec in T.ADPCM_VB:
            f.write(f'{sum((c & 0xFFFF) << (16 * i) for i, c in enumerate(vec)):016x}\n')
    with open(os.path.join(d, 'cb_vq.mem'), 'w') as f:
        for vec in T.HIGH_FREQ_VQ:
            for ssf in range(4):
                sl = vec[8 * ssf:8 * ssf + 8]
                f.write(f'{sum((v & 0xFF) << (8 * k) for k, v in enumerate(sl)):016x}\n')
    print(f'dts_golden: codebook rows in {d}')
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('stream', nargs='?')
    ap.add_argument('--codebooks')
    ap.add_argument('--out')
    ap.add_argument('--skip', type=int, default=0)
    ap.add_argument('--frames', type=int, default=4)
    ap.add_argument('--refuse', type=int, action='append', default=[])
    ap.add_argument('--truncate', action='append', default=[])
    a = ap.parse_args(argv)
    if a.codebooks:
        return write_codebooks(a.codebooks)
    if not a.stream or not a.out:
        ap.error('a stream and --out are required')
    R.OPT.add('lenient_block')                         # D5: the hardware's behaviour
    words, labels = I.load_program()
    sel = [fr for _, fr in R.frames(open(a.stream, 'rb').read())][a.skip:a.skip + a.frames]
    if not sel:
        print(f'dts_golden: no frames in {a.stream} past {a.skip}')
        return 5
    for k in a.refuse:
        fr = bytearray(sel[k])
        p = dsync_bitpos(bytes(fr), words, labels)
        fr[p >> 3] ^= 0x80 >> (p & 7)
        sel[k] = bytes(fr)
    cut = {}
    for t in a.truncate:
        k, n = (int(x) for x in t.split(':'))
        sel[k] = sel[k][:-n]
        cut[k] = n
    expect = set(a.refuse) | set(cut)

    m = I.Machine(words, labels)
    m.trace = []
    vops = []
    m.vop_hook = lambda mach, op: vops.append((op,) + mach.checksums())
    hw = F.StreamDecoder()
    for k, fr in enumerate(sel):
        n0 = len(m.pcm[0])
        e0 = sum(m.errors.values())
        m.feed(fr)
        m.run()
        refused = sum(m.errors.values()) - e0
        try:
            GL, GR, _, _ = hw.decode(fr)
            model_refused = False
        except R.DtsError:
            model_refused = True
        if refused != (k in expect) or model_refused != (k in expect):
            print(f'dts_golden: frame {k}: emulator refused {refused}, model refused '
                  f'{model_refused}, expected {k in expect}')
            return 5
        if not refused and (m.pcm[0][n0:] != GL or m.pcm[1][n0:] != GR):
            print(f'dts_golden: frame {k}: the emulator\'s PCM differs from dts_fixed')
            return 5
    # a refused frame's partial PCM is checked by the frames after it: the model and
    # the emulator must leave the same state, or the next frame differs (above)
    # CNT 1 (issue #189) counts the frames whose header sets DYNF: against the reference
    # parser's own reading of the bit, so a microcode that stops counting fails here and
    # never becomes the golden the RTL is scored against
    want_dynf = 0
    for k, fr in enumerate(sel):
        try:
            want_dynf += k not in expect and R.parse_frame_header(R.BitReader(fr))['drc_present']
        except R.DtsError:
            pass
    if m.counters.get(I.CNT_DYNF, 0) != want_dynf:
        print(f'dts_golden: the emulator counted {m.counters.get(I.CNT_DYNF, 0)} DYNF frames, '
              f'the headers set {want_dynf}')
        return 5

    stem = a.out
    os.makedirs(os.path.dirname(os.path.abspath(stem)), exist_ok=True)
    data = b''.join(sel)
    with open(stem + '.bytes', 'w') as f:
        f.write(''.join(f'{b:02x}\n' for b in data))
    with open(stem + '.frames', 'w') as f:
        f.write(''.join(f'{len(fr):x}\n' for fr in sel))
    with open(stem + '.trace', 'w') as f:
        f.write(''.join(f'{k:x} {pc:03x} {ad:x} {v:06x}\n' for k, pc, ad, v in m.trace))
    with open(stem + '.vops', 'w') as f:
        f.write(''.join(f'{op:x} {x:08x} {h:08x} {r:08x} {b:08x}\n' for op, x, h, r, b in vops))
    with open(stem + '.pcm', 'w') as f:
        f.write(''.join(f'{l & 0xFFFF:04x} {r & 0xFFFF:04x}\n' for l, r in zip(*m.pcm)))
    nerr = sum(m.errors.values())
    with open(stem + '.meta', 'w') as f:
        f.write(f'{len(data)} {len(sel)} {len(m.trace)} {len(vops)} {len(m.pcm[0])} {nerr} '
                f'{m.overrun} {m.lenient} {m.counters.get(I.CNT_DMIX_IGNORED, 0)} 1 '
                f'{m.counters.get(I.CNT_DYNF, 0)}\n')
    fc = m.frame_cycles
    print(f'dts_golden: {os.path.basename(a.stream)} frames {a.skip}..{a.skip + len(sel) - 1}: '
          f'{len(data)} bytes, {len(m.trace)} events, {len(vops)} vector ops, '
          f'{len(m.pcm[0])} pairs, {nerr} refused; matches the model')
    return 0


if __name__ == '__main__':
    sys.exit(main())
