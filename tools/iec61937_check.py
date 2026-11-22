#!/usr/bin/env python3
"""iec61937_check.py -- is a captured passthrough bitstream the disc's own frames?

A receiver tells you a bitstream "plays". This tells you it is BIT-EXACT: it
finds the IEC 61937 bursts in a PCM capture of the core's HDMI or optical
output, pulls the AC-3 / DTS frame out of each one, and looks every frame up
in the frames of the same track read off the disc. It is the instrument for
docs/hdmi_bitstream.md and docs/iec61937.md claims that previously needed an
AV receiver and someone's ear.

What it needs: a capture whose 16-bit words are the words on the wire. A
bitstream rides S/PDIF / HDMI as "PCM" with the non-audio flag set, so any
capture path that ignores that flag and does not resample, mix or apply
volume hands back the bursts intact: a bit-transparent USB S/PDIF input, or a
USB HDMI capture card fed with `dvd_hdmi_bitstream=2` (its EDID will not list
AC-3, so the core must be forced). Whether a given card is transparent is
exactly what the first capture answers: bursts with frames that match = yes;
none, or none that match = it is not (or the core sent PCM).

Usage:
    tools/iec61937_check.py <capture.wav> --iso <disc.iso> --stream 0x80
    tools/iec61937_check.py <capture.wav> --ref <track.ac3|.dts>
    tools/iec61937_check.py <capture.wav>            # bursts only, no reference
    tools/iec61937_check.py <capture.wav> ... --expect bitstream|pcm|silent
    tools/iec61937_check.py --selftest               # every verdict on synthetic captures

--stream is the private-stream-1 substream id (0x80-0x87 AC-3, 0x88-0x8F DTS),
i.e. the physical track; --vts limits the disc read to one title set (faster).

--expect turns the report into an exit status:
    bitstream  every burst's frame is the disc's, and at least --min-frames of them
    pcm        no bursts at all, and the capture is not digitally silent
    silent     no bursts and every sample zero (Audio Off, issue #197)

What it reports beyond pass/fail: the byte order of the payload words (the
OSD's SPDIF Byte Order; "swapped" plays as static on a receiver), the burst
data types, frames that are not on the disc (corruption), and order breaks
(a matched frame that is not the reference's next one: a dropped or repeated
frame, or a seek). A seek or a track switch inside the capture is an expected
order break, not a fault; the verdict does not count breaks.

The capture must be integer PCM (16, 24 or 32 bit; the top 16 bits are the
wire word). A float capture is refused: a float path has already been through
a mixer and cannot be bit-exact.
"""
import argparse
import hashlib
import json
import os
import random
import struct
import sys
import tempfile
import wave

PA, PB = 0xF872, 0x4E1F
# IEC 61937-2 data types this core sends (Pc[4:0])
DTYPES = {0: 'null', 1: 'ac3', 3: 'pause', 11: 'dts-512', 12: 'dts-1024', 13: 'dts-2048'}

# AC-3 frame size in 16-bit words at 48 kHz, indexed by frmsizecod (DVD is 48 kHz only)
AC3_WORDS_48K = [64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192,
                 224, 224, 256, 256, 320, 320, 384, 384, 448, 448, 512, 512,
                 640, 640, 768, 768, 896, 896, 1024, 1024, 1152, 1152, 1280, 1280]


# ---------------------------------------------------------------- frames

def ac3_frame_len(b, i):
    if b[i:i + 2] != b'\x0b\x77' or i + 5 > len(b):
        return 0
    fscod, frmsizecod = b[i + 4] >> 6, b[i + 4] & 0x3F
    if fscod != 0 or frmsizecod >= len(AC3_WORDS_48K):
        return 0
    return AC3_WORDS_48K[frmsizecod] * 2


def dts_frame_len(b, i):
    if b[i:i + 4] != b'\x7f\xfe\x80\x01' or i + 10 > len(b):
        return 0
    # sync(32) FTYPE(1) SHORT(5) CPF(1) NBLKS(7) FSIZE(14): FSIZE at bit 46
    v = int.from_bytes(b[i + 4:i + 10], 'big')            # bits 32..79
    fsize = (v >> (48 - 14 - 14)) & 0x3FFF                # bits 46..59
    return fsize + 1 if fsize >= 95 else 0


def split_frames(es, codec):
    """Elementary stream -> [frame bytes], resyncing on the sync word."""
    flen = ac3_frame_len if codec == 'ac3' else dts_frame_len
    sync = b'\x0b\x77' if codec == 'ac3' else b'\x7f\xfe\x80\x01'
    out, i = [], 0
    while True:
        i = es.find(sync, i)
        if i < 0:
            break
        n = flen(es, i)
        if n and i + n <= len(es) and (i + n == len(es) or es[i + n:i + n + len(sync)] == sync
                                       or i + n + len(sync) > len(es)):
            out.append(bytes(es[i:i + n]))
            i += n
        else:
            i += 1
    return out


def codec_of(stream):
    if 0x80 <= stream <= 0x87:
        return 'ac3'
    if 0x88 <= stream <= 0x8F:
        return 'dts'
    raise SystemExit(f'--stream 0x{stream:02x}: passthrough carries AC-3 (0x80-0x87) or DTS (0x88-0x8F)')


def iso_stream(path, stream, vts=None):
    """The whole of one private-stream-1 substream across a disc's title VOBS."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from dvd_vm_ref import IsoNav                       # noqa: E402
    nav = IsoNav(path)
    es = bytearray()
    for vn, ifo_lba in sorted(nav.vts_ifo.items()):
        if vts is not None and vn != vts:
            continue
        mat = nav.sec(ifo_lba)
        last_vts = struct.unpack('>I', mat[0x0C:0x10])[0]
        last_ifo = struct.unpack('>I', mat[0x1C:0x20])[0]
        tt = struct.unpack('>I', mat[0xC4:0xC8])[0]
        if not tt:
            continue
        start, end = ifo_lba + tt, ifo_lba + last_vts - (last_ifo + 1)
        nav.f.seek(start * 2048)
        for pos in range(start, end, 512):
            blob = nav.f.read(min(512, end - pos) * 2048)
            for k in range(len(blob) // 2048):
                sec = blob[k * 2048:(k + 1) * 2048]
                if sec[:4] != b'\x00\x00\x01\xba':
                    continue
                p = 14 + (sec[13] & 7)
                while p + 6 < 2048 and sec[p:p + 3] == b'\x00\x00\x01':
                    sid = sec[p + 3]
                    plen = struct.unpack('>H', sec[p + 4:p + 6])[0]
                    body = p + 6
                    if sid == 0xBD and body + 3 < 2048:
                        sub = body + 3 + sec[body + 2]
                        if sub + 4 <= min(2048, body + plen) and sec[sub] == stream:
                            es.extend(sec[sub + 4:min(2048, body + plen)])
                    p = body + plen
    nav.f.close()
    return bytes(es)


# ---------------------------------------------------------------- capture

def read_words(path):
    """WAV -> the wire's 16-bit words in transmission order (L, R, L, R ...)."""
    with open(path, 'rb') as f:
        hdr = f.read(64)
    if hdr[:4] == b'RIFF':
        i = 12
        with open(path, 'rb') as f:
            data = f.read()
        fmt = None
        while i + 8 <= len(data):
            cid, n = data[i:i + 4], struct.unpack('<I', data[i + 4:i + 8])[0]
            if cid == b'fmt ':
                fmt = struct.unpack('<HHIIHH', data[i + 8:i + 24])
                if fmt[0] == 0xFFFE and n >= 40:                 # WAVE_FORMAT_EXTENSIBLE
                    fmt = (struct.unpack('<H', data[i + 32:i + 34])[0],) + fmt[1:]
            elif cid == b'data':
                if fmt is None:
                    raise SystemExit(f'{path}: data before fmt')
                tag, ch, rate, _, _, bits = fmt
                if tag == 3:
                    raise SystemExit(f'{path}: float PCM. A float path has been mixed and '
                                     'cannot be bit-exact; capture as s16/s32 integer.')
                if tag != 1:
                    raise SystemExit(f'{path}: WAV format tag {tag}, need integer PCM')
                if ch != 2:
                    raise SystemExit(f'{path}: {ch} channels; IEC 61937 rides a stereo pair')
                body = data[i + 8:i + 8 + n]
                w = bits // 8
                words = [int.from_bytes(body[k + w - 2:k + w], 'little')
                         for k in range(0, len(body) - w + 1, w)]
                return words, rate, bits
            i += 8 + n + (n & 1)
        raise SystemExit(f'{path}: no data chunk')
    raise SystemExit(f'{path}: not a WAV file (record with -f S16_LE -c 2 -r 48000)')


def find_bursts(words):
    """-> [(word index, pc, pd, payload bytes as transmitted)]"""
    out, i, n = [], 0, len(words)
    while i + 4 <= n:
        if words[i] == PA and words[i + 1] == PB:
            pc, pd = words[i + 2], words[i + 3]
            dt = pc & 0x1F
            nbytes = pd // 8 if dt not in (0, 3) else 0
            nw = (nbytes + 1) // 2
            if i + 4 + nw > n:                       # cut off by the capture's end
                break
            pay = b''.join(struct.pack('>H', x) for x in words[i + 4:i + 4 + nw])[:nbytes]
            out.append((i, pc, pd, pay))
            i += 4 + nw
        else:
            i += 1
    return out


def unswap(b):
    return b''.join(bytes((b[k + 1], b[k])) for k in range(0, len(b) - 1, 2)) + \
        (b[-1:] if len(b) & 1 else b'')


# ---------------------------------------------------------------- analysis

def analyse(words, rate, ref_frames, codec_hint=None):
    bursts = find_bursts(words)
    r = {'rate': rate, 'words': len(words), 'bursts': len(bursts), 'types': {},
         'byte_order': None, 'frames': 0, 'matched': 0, 'not_on_disc': 0,
         'order_breaks': 0, 'nonzero_words': sum(1 for w in words if w),
         'first_burst_s': None, 'last_burst_s': None, 'bad': []}
    if bursts:
        r['first_burst_s'] = round(bursts[0][0] / 2 / rate, 3)
        r['last_burst_s'] = round(bursts[-1][0] / 2 / rate, 3)
    index = {}
    for k, fr in enumerate(ref_frames or []):
        index.setdefault(hashlib.sha1(fr).digest(), []).append(k)
    normal = swapped = 0
    prev = None
    for at, pc, pd, pay in bursts:
        dt = pc & 0x1F
        name = DTYPES.get(dt, f'type{dt}')
        r['types'][name] = r['types'].get(name, 0) + 1
        if dt in (0, 3):
            continue
        r['frames'] += 1
        if pay[:2] in (b'\x0b\x77', b'\x7f\xfe'):
            normal += 1
            fr = pay
        elif pay[:2] in (b'\x77\x0b', b'\xfe\x7f'):
            swapped += 1
            fr = unswap(pay)
        else:
            fr = pay
        if ref_frames is None:
            continue
        hit = index.get(hashlib.sha1(fr).digest())
        if not hit:
            r['not_on_disc'] += 1
            if len(r['bad']) < 8:
                r['bad'].append({'t_s': round(at / 2 / rate, 3), 'pd_bits': pd,
                                 'head': fr[:8].hex()})
            prev = None
            continue
        r['matched'] += 1
        if prev is not None and not any(h == p + 1 for h in hit for p in prev):
            r['order_breaks'] += 1
        prev = hit
    if normal or swapped:
        r['byte_order'] = 'normal' if swapped == 0 else 'swapped' if normal == 0 else 'mixed'
    return r


def verdict(r, expect, min_frames, have_ref):
    if expect == 'bitstream':
        if r['frames'] == 0:
            return False, 'no codec bursts in the capture'
        if r['byte_order'] != 'normal':
            return False, f"payload byte order {r['byte_order']} (SPDIF Byte Order = Swap?)"
        if have_ref and r['not_on_disc']:
            return False, f"{r['not_on_disc']} of {r['frames']} frames are not the disc's"
        if have_ref and r['matched'] < min_frames:
            return False, f"only {r['matched']} matched frames (need {min_frames})"
        return True, f"{r['frames']} frames, all the disc's" if have_ref else \
            f"{r['frames']} frames (no reference given: framing only)"
    if expect == 'pcm':
        if r['bursts']:
            return False, f"{r['bursts']} IEC 61937 bursts in what should be PCM"
        if r['nonzero_words'] == 0:
            return False, 'digitally silent: no PCM to speak of'
        return True, 'PCM, no bursts'
    if expect == 'silent':
        if r['bursts']:
            return False, f"{r['bursts']} IEC 61937 bursts still going"
        if r['nonzero_words']:
            return False, f"{r['nonzero_words']} non-zero words"
        return True, 'digital silence, no bursts'
    return True, 'report only'


# ---------------------------------------------------------------- selftest

def _synth_frames(codec, n, seed):
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        if codec == 'ac3':
            code = 28                                           # 448 kb/s
            fr = bytearray(rnd.randbytes(AC3_WORDS_48K[code] * 2))
            fr[0:2] = b'\x0b\x77'
            fr[4] = code
        else:
            size = 2012
            fr = bytearray(rnd.randbytes(size))
            fr[0:4] = b'\x7f\xfe\x80\x01'
            v = (1 << 47) | (31 << 42) | (15 << 34) | ((size - 1) << 20)
            fr[4:10] = v.to_bytes(6, 'big')
        out.append(bytes(fr))
    return out


def _synth_capture(path, frames, codec, swap=False, pcm_tail=0, pre=37):
    words = [0] * pre
    period = 1536 if codec == 'ac3' else 512
    for fr in frames:
        pay = unswap(fr) if swap else fr
        if len(pay) & 1:
            pay += b'\0'
        pw = list(struct.unpack(f'>{len(pay) // 2}H', pay))
        burst = [PA, PB, 1 if codec == 'ac3' else 11, len(fr) * 8] + pw
        words += burst + [0] * (period * 2 - len(burst))
    rnd = random.Random(5)
    words += [rnd.randrange(1, 0x8000) for _ in range(pcm_tail)]
    with wave.open(path, 'wb') as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(48000)
        w.writeframes(struct.pack(f'<{len(words)}H', *words))


def selftest():
    fails = []
    tmp = tempfile.mkdtemp(prefix='iec61937_selftest_')

    def run(name, frames, ref, expect, want, **kw):
        codec = kw.pop('codec', 'ac3')
        p = os.path.join(tmp, name + '.wav')
        if frames is None:
            with wave.open(p, 'wb') as w:
                w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
                body = kw.pop('raw')
                w.writeframes(struct.pack(f'<{len(body)}H', *body))
        else:
            _synth_capture(p, frames, codec, **kw)
        words, rate, _ = read_words(p)
        r = analyse(words, rate, ref)
        ok, why = verdict(r, expect, 4, ref is not None)
        mark = 'ok ' if ok == want else 'BAD'
        print(f'  [{mark}] {name:22s} expect={expect:9s} -> {"PASS" if ok else "FAIL"}: {why}')
        if ok != want:
            fails.append(name)
        return r

    for codec in ('ac3', 'dts'):
        ref = _synth_frames(codec, 40, 1)
        print(f'{codec}:')
        r = run(f'{codec}_clean', ref[5:30], ref, 'bitstream', True, codec=codec)
        if r['order_breaks'] or r['matched'] != 25:
            fails.append(f'{codec}_clean counts'); print('  [BAD] clean counts', r)
        bad = [bytearray(f) for f in ref[5:30]]
        bad[10][200] ^= 0x01                                    # one flipped bit
        run(f'{codec}_one_bit_flipped', [bytes(f) for f in bad], ref, 'bitstream', False, codec=codec)
        run(f'{codec}_byte_swapped', ref[5:30], ref, 'bitstream', False, codec=codec, swap=True)
        run(f'{codec}_other_track', _synth_frames(codec, 25, 2), ref, 'bitstream', False, codec=codec)
        r = run(f'{codec}_dropped_frame', ref[5:15] + ref[16:30], ref, 'bitstream', True, codec=codec)
        if r['order_breaks'] != 1:
            fails.append(f'{codec}_dropped_frame breaks'); print('  [BAD] order_breaks', r['order_breaks'])
        run(f'{codec}_as_pcm', ref[5:30], ref, 'pcm', False, codec=codec)
        run(f'{codec}_as_silent', ref[5:30], ref, 'silent', False, codec=codec)
        # the reference path: frames split back out of a concatenated stream
        if split_frames(b''.join(ref), codec) != ref:
            fails.append(f'{codec}_split'); print(f'  [BAD] split_frames({codec}) != frames')
    print('pcm / silence:')
    rnd = random.Random(9)
    run('pcm_music', None, None, 'pcm', True, raw=[rnd.randrange(0x10000) for _ in range(9600)])
    run('pcm_as_silent', None, None, 'silent', False, raw=[rnd.randrange(1, 0x10000) for _ in range(9600)])
    run('zeros_silent', None, None, 'silent', True, raw=[0] * 9600)
    run('zeros_as_pcm', None, None, 'pcm', False, raw=[0] * 9600)
    ref = _synth_frames('ac3', 10, 1)
    run('bursts_as_silent', ref, ref, 'silent', False)
    if fails:
        print(f'SELFTEST FAIL: {fails}')
        return 1
    print('SELFTEST PASS: every verdict fires on its own case')
    return 0


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('capture', nargs='?')
    ap.add_argument('--iso', help='disc image to take the reference frames from')
    ap.add_argument('--stream', type=lambda s: int(s, 0), help='substream id, e.g. 0x80')
    ap.add_argument('--vts', type=int, help='read only this title set')
    ap.add_argument('--ref', help='a raw .ac3 / .dts elementary stream instead of --iso')
    ap.add_argument('--codec', choices=('ac3', 'dts'), help='with --ref, if not by extension')
    ap.add_argument('--expect', choices=('bitstream', 'pcm', 'silent'))
    ap.add_argument('--min-frames', type=int, default=32)
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.capture:
        ap.error('a capture is required (or --selftest)')

    ref = None
    if a.iso:
        if a.stream is None:
            ap.error('--iso needs --stream')
        codec = codec_of(a.stream)
        ref = split_frames(iso_stream(a.iso, a.stream, a.vts), codec)
        if not ref:
            raise SystemExit(f'no {codec} frames for stream 0x{a.stream:02x} on {a.iso}')
    elif a.ref:
        codec = a.codec or ('dts' if a.ref.lower().endswith('.dts') else 'ac3')
        ref = split_frames(open(a.ref, 'rb').read(), codec)
        if not ref:
            raise SystemExit(f'{a.ref}: no {codec} frames')

    words, rate, bits = read_words(a.capture)
    r = analyse(words, rate, ref)
    r['reference_frames'] = len(ref) if ref is not None else None
    r['capture_bits'] = bits
    ok, why = verdict(r, a.expect, a.min_frames, ref is not None)
    if a.json:
        print(json.dumps(dict(r, verdict=ok, why=why)))
    else:
        print(f"capture   {len(words) / 2 / rate:.2f} s at {rate} Hz, {bits}-bit")
        print(f"bursts    {r['bursts']}  {r['types']}  byte order {r['byte_order']}")
        if r['bursts']:
            print(f"          first at {r['first_burst_s']} s, last at {r['last_burst_s']} s")
        if ref is not None:
            print(f"reference {len(ref)} frames")
            print(f"frames    {r['frames']}: {r['matched']} the disc's, {r['not_on_disc']} not, "
                  f"{r['order_breaks']} order breaks")
            for b in r['bad']:
                print(f"          not on disc at {b['t_s']} s: Pd {b['pd_bits']} bits, head {b['head']}")
        print(f"nonzero   {r['nonzero_words']} of {len(words)} words")
        if a.expect:
            print(f"{'PASS' if ok else 'FAIL'} ({a.expect}): {why}")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
