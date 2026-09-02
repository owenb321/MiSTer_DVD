#!/usr/bin/env python3
"""wav_ref.py — golden reference model + fixture generator for WAV/CD-DA playback.

Models the dvd_iso_reader.sv WAV path (branch feature/wav-audio) BYTE-EXACTLY:

  * Probe: sector 0 must start "RIFF" with "WAVE" at offset 8 (same rbuf shadow
    the riff_cdxa comparator uses).  The chunk walker then runs over SECTOR 0
    ONLY (2048 bytes): from offset 12, each chunk is <ckid:4><cksize:4 LE> and
    advances by 8 + cksize rounded UP to even (RIFF pad rule).  "fmt " captures
    {audio_format, channels, sample_rate, bits}; "data" captures the payload
    byte offset and length and STOPS the walk.
  * Accept: audio_format == 1 (PCM), channels == 2, bits == 16, rate in
    {44100, 48000}.  Anything else — or "data" not found within sector 0, or a
    chunk record straddling past sector 0 — is a REJECT (RTL: wav_bad ->
    img_unplayable, no audio ever emitted).
  * Playback: bytes [data_off, data_off + data_len) stream to the PCM
    assembler, little-endian interleaved s16: b0=L.lo b1=L.hi b2=R.lo b3=R.hi.
    A trailing partial pair (data_len % 4 != 0) is DISCARDED.  Bytes after the
    data chunk (trailing LIST/id3) are swallowed, never played.  If the data
    chunk claims more bytes than the file holds, playback ends at EOF on the
    last whole pair.

The physical-CD virtual image (branch 2) is a canonical 44-byte header + raw
CD-DA audio, i.e. exactly the `canonical()` shape here — one model covers both.

Usage:
    tools/wav_ref.py gen <outdir>     # write the fixture set + goldens
    tools/wav_ref.py probe <file.wav> # print the model's verdict for a file

Fixture set written by `gen` (all synthetic, deterministic — xorshift32 PCM so
every bit pattern is exercised and no libm/float variance can creep in):

  accept:  pcm441.wav    canonical 44-byte header, 44100 Hz, partial last block
           pcm48.wav     canonical, 48000 Hz
           listchunk.wav LIST + fact chunks between fmt and data
           oddchunk.wav  odd-cksize junk chunk (pad-byte walk rule) + trailing
                         bytes AFTER the data chunk (must not play)
  reject:  rej_mono.wav  rej_24bit.wav  rej_float.wav  rej_96k.wav
           rej_latedata.wav (data chunk starts beyond sector 0)

Per accept fixture, alongside the .wav:
  <name>.wav.hex   one hex byte per line ($readmemh into the TB block server)
  <name>.pcm.hex   expected pairs, one per line, 8 hex chars {L[15:0],R[15:0]}
  <name>.meta      "<fs_code> <data_off> <npairs>"  (fs_code: 0=44.1k 1=48k —
                   the nco_fs encoding)
Reject fixtures get only <name>.wav.hex.
"""

import os
import struct
import sys

SECTOR = 2048


# ---------------------------------------------------------------- PCM source
def xs32_pcm(nbytes: int, seed: int = 0xC0FFEE01) -> bytes:
    """Deterministic pseudo-random PCM payload (xorshift32, low 8 bits/step)."""
    out = bytearray(nbytes)
    s = seed
    for i in range(nbytes):
        s ^= (s << 13) & 0xFFFFFFFF
        s ^= s >> 17
        s ^= (s << 5) & 0xFFFFFFFF
        out[i] = s & 0xFF
    return bytes(out)


# ---------------------------------------------------------------- WAV writers
def fmt_chunk(audio_format=1, channels=2, rate=44100, bits=16) -> bytes:
    block_align = channels * bits // 8
    byte_rate = rate * block_align
    body = struct.pack('<HHIIHH', audio_format, channels, rate,
                       byte_rate, block_align, bits)
    return b'fmt ' + struct.pack('<I', len(body)) + body


def build_wav(chunks_before_data, data: bytes, trailing: bytes = b'') -> bytes:
    """Assemble RIFF/WAVE from pre-data chunks + a data chunk (+ trailing)."""
    body = bytearray()
    for ck in chunks_before_data:
        body += ck
        if len(ck) & 1:
            body += b'\x00'          # RIFF pad byte after odd-size chunk
    body += b'data' + struct.pack('<I', len(data)) + data
    if len(data) & 1:
        body += b'\x00'
    body += trailing
    return b'RIFF' + struct.pack('<I', 4 + len(body)) + b'WAVE' + bytes(body)


def canonical(rate: int, data: bytes) -> bytes:
    return build_wav([fmt_chunk(rate=rate)], data)


# ---------------------------------------------------------------- the model
class Verdict:
    def __init__(self):
        self.ok = False
        self.reason = ''
        self.fs_code = None      # 0=44.1k, 1=48k (nco_fs encoding)
        self.data_off = None
        self.data_len = None


def probe(img: bytes) -> Verdict:
    """Chunk-walk sector 0 exactly as the RTL does."""
    v = Verdict()
    sec = img[:SECTOR]
    if len(sec) < 12 or sec[0:4] != b'RIFF' or sec[8:12] != b'WAVE':
        v.reason = 'no RIFF/WAVE signature'
        return v
    fmt = None
    off = 12
    while True:
        if off + 8 > SECTOR:
            v.reason = 'chunk record beyond sector 0'
            return v
        ckid = sec[off:off + 4]
        cksz = struct.unpack('<I', sec[off + 4:off + 8])[0]
        if ckid == b'fmt ':
            if off + 8 + 16 > SECTOR:
                v.reason = 'fmt body beyond sector 0'
                return v
            fmt = struct.unpack('<HHIIHH', sec[off + 8:off + 24])
        elif ckid == b'data':
            if fmt is None:
                v.reason = 'data before fmt'
                return v
            afmt, ch, rate, _br, _ba, bits = fmt
            if afmt != 1:
                v.reason = f'audio_format {afmt} != PCM'
            elif ch != 2:
                v.reason = f'{ch} channel(s), need 2'
            elif bits != 16:
                v.reason = f'{bits}-bit, need 16'
            elif rate not in (44100, 48000):
                v.reason = f'rate {rate}, need 44100/48000'
            else:
                v.ok = True
                v.fs_code = 0 if rate == 44100 else 1
                v.data_off = off + 8
                v.data_len = cksz
            return v
        off += 8 + cksz + (cksz & 1)


def expected_pairs(img: bytes):
    """Expected {L,R} s16 pairs for an ACCEPTED image (RTL playback model)."""
    v = probe(img)
    assert v.ok, v.reason
    data = img[v.data_off:v.data_off + v.data_len]
    pairs = []
    for i in range(0, len(data) - 3, 4):
        l = data[i] | (data[i + 1] << 8)
        r = data[i + 2] | (data[i + 3] << 8)
        pairs.append((l, r))
    return v, pairs


# ---------------------------------------------------------------- fixtures
def write_hex_bytes(path: str, blob: bytes):
    with open(path, 'w') as f:
        for b in blob:
            f.write(f'{b:02x}\n')


def emit(outdir: str, name: str, img: bytes, accept: bool):
    open(os.path.join(outdir, name + '.wav'), 'wb').write(img)
    write_hex_bytes(os.path.join(outdir, name + '.wav.hex'), img)
    v = probe(img)
    if accept:
        assert v.ok, f'{name}: model rejects its own accept fixture: {v.reason}'
        v, pairs = expected_pairs(img)
        with open(os.path.join(outdir, name + '.pcm.hex'), 'w') as f:
            for l, r in pairs:
                f.write(f'{l:04x}{r:04x}\n')
        with open(os.path.join(outdir, name + '.meta'), 'w') as f:
            f.write(f'{v.fs_code} {v.data_off} {len(pairs)}\n')
        print(f'  {name}.wav  ACCEPT fs={44100 if v.fs_code==0 else 48000} '
              f'data_off={v.data_off} pairs={len(pairs)} '
              f'({len(img)} bytes, {len(img)/2048:.2f} blocks)')
    else:
        assert not v.ok, f'{name}: model accepts a reject fixture'
        print(f'  {name}.wav  REJECT ({v.reason})')


def gen(outdir: str):
    os.makedirs(outdir, exist_ok=True)

    # accept: 2500 pairs -> 10 KB data + 44 hdr = 10044 B = 4.90 blocks
    # (multiple full blocks + a partial final block)
    emit(outdir, 'pcm441', canonical(44100, xs32_pcm(2500 * 4)), True)
    emit(outdir, 'pcm48', canonical(48000, xs32_pcm(1500 * 4, seed=0x48484848)),
         True)
    # LIST(INFO) + fact chunks between fmt and data
    lst = b'LIST' + struct.pack('<I', 26) + b'INFOISFT' + \
        struct.pack('<I', 14) + b'wav_ref.py\x00\x00\x00\x00'
    fact = b'fact' + struct.pack('<I', 4) + struct.pack('<I', 1200)
    emit(outdir, 'listchunk',
         build_wav([fmt_chunk(rate=44100), lst, fact], xs32_pcm(1200 * 4,
                                                                seed=0x1157)),
         True)
    # odd-cksize junk chunk (walker must take the pad byte) + trailing id3
    # after data (must never play)
    junk = b'junk' + struct.pack('<I', 7) + b'oddness'
    emit(outdir, 'oddchunk',
         build_wav([fmt_chunk(rate=44100), junk], xs32_pcm(1000 * 4,
                                                           seed=0x0DD0DD),
                   trailing=b'id3 ' + b'\xAA' * 60),
         True)

    # rejects
    emit(outdir, 'rej_mono',
         build_wav([fmt_chunk(channels=1)], xs32_pcm(400)), False)
    emit(outdir, 'rej_24bit',
         build_wav([fmt_chunk(bits=24)], xs32_pcm(600)), False)
    emit(outdir, 'rej_float',
         build_wav([fmt_chunk(audio_format=3, bits=32)], xs32_pcm(800)), False)
    emit(outdir, 'rej_96k',
         build_wav([fmt_chunk(rate=96000)], xs32_pcm(400)), False)
    # data chunk pushed past sector 0 by a huge LIST chunk
    biglist = b'LIST' + struct.pack('<I', 2100) + b'INFO' + b'\x20' * 2096
    emit(outdir, 'rej_latedata',
         build_wav([fmt_chunk(rate=44100), biglist], xs32_pcm(400)), False)


# ---------------------------------------------------------------- CLI
def main():
    if len(sys.argv) >= 3 and sys.argv[1] == 'gen':
        gen(sys.argv[2])
        return 0
    if len(sys.argv) >= 3 and sys.argv[1] == 'probe':
        img = open(sys.argv[2], 'rb').read()
        v = probe(img)
        if v.ok:
            print(f'ACCEPT fs_code={v.fs_code} data_off={v.data_off} '
                  f'data_len={v.data_len}')
        else:
            print(f'REJECT: {v.reason}')
        return 0
    sys.stderr.write(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main())
