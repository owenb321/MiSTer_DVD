#!/usr/bin/env python3
"""Count sequence headers per MENU CELL -- the measurement that killed the
`still_time` predicate (docs/quant_matrix.md §13o).

WHY THIS EXISTS
---------------
§11 says only a STILL can be damaged by an eaten sequence header, because "a
moving title re-sends a sequence header every GOP; a menu still is
SEQ GOP PIC:I SEQ_END, one sequence header ever". That is true of the STREAM.
The repair was then gated on the IFO's `still_time`, which is a number the
AUTHORING TOOL wrote -- the progressive_frame failure class -- and on
INCREDIBLE_HULK the two disagree:

    cell                        ES bytes  SEQ b3  GOP b8  PIC 00  END b7
    PGCN10 loop 30s              5510099      22      22     231       0
    PGCN11 39s                   5537891      26      26     220       0
    PGCN12 3s                    1975764      11      11      96       0
    PGCN13 heur-still 41s         224757       1       1       1       1
    PGCN14 loop 70s               224701       1       1       1       1   <-- !!
    PGCN15 STILL 255              224615       1       1       1       1
    PGCN16 loop 70s               224587       1       1       1       1   <-- !!
    PGCN17 STILL 255              224542       1       1       1       1

PGCN 14 and 16 carry `still_time = 0` and a 70 s playback time, and are ONE
PICTURE plus 70 s of audio -- stills the disc implements by looping a
single-picture cell rather than by setting still_time. They fry exactly like a
declared still and no metadata says so.

⚠ Hardcoded to the Hulk menu VOB, because it exists to record THAT measurement.
Point it at another disc by editing VOB_LBA/CELLS from `iso_nav_check.py` output.
"""

ISO='/mnt/dvd/pal/INCREDIBLE_HULK.iso'
VOB_LBA=594143          # VTS_06_0.VOB (menu VOBS) first LBA, from iso_nav_check
CELLS={  # pgcn: (first_rbn, last_rbn, label)
 10:(12763,22799,'PGCN10 loop 30s'),
 11:(0,12762,'PGCN11 39s'),
 12:(22800,23895,'PGCN12 3s'),
 13:(24476,24674,'PGCN13 heur-still 41s'),
 14:(24675,26877,'PGCN14 loop 70s'),
 15:(26878,26991,'PGCN15 STILL 255'),
 16:(26992,29196,'PGCN16 loop 70s'),
 17:(29197,29312,'PGCN17 STILL 255'),
}
def video_es(f, first, last, cap_sectors=None):
    out=bytearray()
    n=last-first+1
    if cap_sectors: n=min(n,cap_sectors)
    f.seek((VOB_LBA+first)*2048)
    data=f.read(n*2048)
    for o in range(0,len(data),2048):
        s=data[o:o+2048]
        if s[:4]!=b'\x00\x00\x01\xba': continue
        p=14+(s[13]&7)                      # pack header + stuffing
        while p+6<=len(s):
            if s[p:p+3]!=b'\x00\x00\x01': break
            sid=s[p+3]; ln=(s[p+4]<<8)|s[p+5]
            body=s[p+6:p+6+ln]
            if 0xe0<=sid<=0xef and len(body)>=3:
                hl=body[2]; out+=body[3+hl:]
            p+=6+ln
    return bytes(out)
def count(es, code):
    n=0; i=0; pat=b'\x00\x00\x01'+bytes([code])
    while True:
        i=es.find(pat,i)
        if i<0: return n
        n+=1; i+=4
with open(ISO,'rb') as f:
    print(f"{'cell':26s} {'ES bytes':>9s} {'SEQ b3':>7s} {'GOP b8':>7s} {'PIC 00':>7s} {'END b7':>7s}")
    for pgcn,(a,b,lab) in sorted(CELLS.items()):
        es=video_es(f,a,b,cap_sectors=3000)
        print(f"{lab:26s} {len(es):9d} {count(es,0xb3):7d} {count(es,0xb8):7d} {count(es,0x00):7d} {count(es,0xb7):7d}")
