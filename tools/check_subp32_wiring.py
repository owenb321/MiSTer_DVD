#!/usr/bin/env python3
"""Gate for the 32-subtitle-track change (PR #152; docs/track_selection.md
"32 subtitle tracks").

DVD-Video allows 32 subpicture streams. The core used to keep 16 subp_control
entries, 8 languages and a 3-bit Subtitle-button index. The module benches
(iso_reader_subpctl_tb, iso_reader_attr_tb, subp_stream_map_tb, subp_decl_tb,
transport_hud_tb) prove each piece at 32; this proves the PIECES ARE CONNECTED at
32, because a single narrow wire anywhere in emu.sv silently truncates the index
back to 8 or 16 and every module bench still passes (emu.sv has no bench).

    python3 tools/check_subp32_wiring.py            # exit 0 = wired at 32
    git show <pre-32>:dvd/emu.sv > /tmp/e.sv; git show <pre-32>:dvd/dvd_iso_reader.sv > /tmp/r.sv
    python3 tools/check_subp32_wiring.py /tmp/e.sv /tmp/r.sv     # must exit 1

Comments are stripped first (emu.sv quotes old code in its comments).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from check_forced_subs_wiring import strip_comments, squash  # noqa: E402


def instance_port(src, module, port):
    """`.port(<expr>)` of the single instance of `module`, squashed; handles an
    optional `#( ... )` parameter list and nested parentheses in the expression."""
    m = re.search(r'\b%s\b\s*(#\s*\()?' % re.escape(module), src)
    while m:
        i = m.end()
        if m.group(1):                       # skip the balanced #( ... )
            depth = 1
            while depth and i < len(src):
                depth += {'(': 1, ')': -1}.get(src[i], 0)
                i += 1
        n = re.match(r'\s*(\w+)\s*\(', src[i:])
        if n:
            j = i + n.end()                  # just past the instance's '('
            depth, k = 1, j
            while depth and k < len(src):
                depth += {'(': 1, ')': -1}.get(src[k], 0)
                k += 1
            body = src[j:k - 1]
            pm = re.search(r'\.%s\s*\(' % re.escape(port), body)
            if not pm:
                return None
            a, depth, b = pm.end(), 1, pm.end()
            while depth and b < len(body):
                depth += {'(': 1, ')': -1}.get(body[b], 0)
                b += 1
            return squash(body[a:b - 1])
        m = re.compile(r'\b%s\b\s*(#\s*\()?' % re.escape(module)).search(src, m.end())
    return None


def decl_width(src, name):
    """The [hi:lo] of the declaration of `name` (wire/reg/output/input), squashed."""
    m = re.search(r'\b(?:wire|reg|logic|output\s+reg|output\s+wire|output|input\s+wire|input)'
                  r'\s*(\[[^\]]+\])\s*[^;,()]*?\b%s\b' % re.escape(name), src)
    return squash(m.group(1)) if m else None


def main():
    root = os.path.join(HERE, '..')
    emu_p = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, 'dvd', 'emu.sv')
    rdr_p = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, 'dvd', 'dvd_iso_reader.sv')
    hud_p = os.path.join(root, 'dvd', 'transport_hud.sv')
    map_p = os.path.join(root, 'dvd', 'subp_stream_map.sv')
    emu = strip_comments(open(emu_p, encoding='utf-8', errors='replace').read())
    rdr = strip_comments(open(rdr_p, encoding='utf-8', errors='replace').read())
    hud = strip_comments(open(hud_p, encoding='utf-8', errors='replace').read())
    smap = strip_comments(open(map_p, encoding='utf-8', errors='replace').read())
    E, R = squash(emu), squash(rdr)
    bad = []

    def need(cond, msg):
        if not cond:
            bad.append(msg)

    # 1. the reader produces 32
    for name, want in (('subp_ntracks', '[5:0]'), ('attr_s_sel', '[4:0]'),
                       ('pgc_ctl_waddr', '[5:0]')):
        w = decl_width(rdr, name)
        need(w == want, '1. reader %s is %s, want %s' % (name, w, want))
    need("walk_left<=13'd128;" in R, '1. reader P_SUBP walks 128 bytes (32 x 4) -- not found')
    need("pgc_ctl_waddr<={1'b0,walk_idx[6:2]};" in R, '1. reader subp words go to waddr 0..31')
    need("pgc_ctl_waddr<={3'b100,walk_idx[3:1]};" in R, '1. reader audio words go to waddr 32..39')
    need("pgc_ctl_we&&pgc_ctl_waddr==6'd31" in R, '1. pgc_ctl_valid must rise after subp word 31')
    need("attr_idx==(attr_phase?5'd31:5'd7)" in R, '1. the attribute sweep must read 32 subp entries')

    # 2. emu receives 32: the bus, the RAM, its single read, the audio split
    need(decl_width(emu, 'pgc_ctl_waddr') == '[5:0]', '2. emu pgc_ctl_waddr is not [5:0]')
    m = re.search(r'\(\*\s*ramstyle\s*=\s*"M10K"\s*\*\)\s*reg\s*\[31:0\]\s*subp_ctl_ram\s*\[0:31\]', emu)
    need(m is not None, '2. subp_ctl_ram must be a (* ramstyle="M10K" *) reg [31:0] [0:31]')
    need("if(pgc_ctl_we&&!pgc_ctl_waddr[5])subp_ctl_ram[pgc_ctl_waddr[4:0]]<=pgc_ctl_wdata;" in E,
         '2. subp_ctl_ram write must be guarded by !pgc_ctl_waddr[5], indexed [4:0]')
    need("subp_ctl_sel_q<=subp_ctl_ram[sp_sel_log];" in E, '2. subp_ctl_ram must be read at sp_sel_log')
    need("if(pgc_ctl_we&&pgc_ctl_waddr[5])begin" in E, '2. the audio map must decode waddr[5] (32..39)')

    # 3. every index on the subtitle path is 5 bits, the count 6
    for name, want in (('sp_sel', '[4:0]'), ('sub_idx', '[4:0]'), ('sp_user_log', '[4:0]'),
                       ('sp_sel_log', '[4:0]'), ('subp_ntracks_w', '[5:0]'),
                       ('fs_log', '[4:0]')):
        w = decl_width(emu, name)
        need(w == want, '3. emu %s is %s, want %s' % (name, w, want))

    # 4. subp_decl is fed by the bus and tracks the EFFECTIVE track
    for port, want in (('ctl_we', 'pgc_ctl_we'), ('ctl_waddr', 'pgc_ctl_waddr'),
                       ('ctl_wbit31', 'pgc_ctl_wdata[31]'), ('cur', 'sp_sel')):
        got = instance_port(emu, 'subp_decl', port)
        need(got == want, '4. subp_decl .%s(%s), want %s' % (port, got, want))
    m = re.search(r'\bwire\s+sp_tbl_ok\s*=\s*([^;]*);', emu)
    t = squash(m.group(1)) if m else ''
    for term in ('pgc_ctl_valid', 'pgc_dom_tt', 'subp_any_decl'):
        need(term in t, '4. sp_tbl_ok lacks %s: %s' % (term, t or None))

    # 5. the popup total is the highest DECLARED stream + 1 when there is a table
    got = instance_port(emu, 'transport_hud', 'sub_cnt')
    need(got == "sp_tbl_ok?({1'b0,subp_last_decl}+6'd1):subp_ntracks_w",
         '5. transport_hud .sub_cnt is %r' % got)
    got = instance_port(emu, 'transport_hud', 'sub_no')
    need(got == "{1'b0,sp_sel}+6'd1", '5. transport_hud .sub_no is %r' % got)

    # 6. the VM's SetSTN path is 5 bits and 62/63 never claim
    # (the claim's condition, whatever else it gates on: since 2026-11-11 it also
    # excludes the Subtitle write-back landing -- tools/check_subp_ctx_wiring.py 9.)
    cl = re.search(r"if\(([^;]*?vm_spstn!=vm_spstn_p[^;]*?)\)vm_owns_sp<=1'b1;", E)
    need(cl is not None and "vm_spstn[6]" in cl.group(1) and "!vm_spstn[5]" in cl.group(1),
         '6. the vm_owns_sp claim must exclude SPRM2 62/63 (bit 5)')
    need("?vm_spstn[4:0]:sub_idx;" in E, '6. sp_sel must take vm_spstn[4:0]')

    # 7. no truncation on the way to the demux
    m = re.search(r'\bwire\s*\[4:0\]\s*sp_track_eff\s*=\s*([^;]*);', emu)
    t = squash(m.group(1)) if m else ''
    need(t.endswith(':sp_user_log'), '7. sp_track_eff user arm must be sp_user_log (5 bits): %s' % (t or None))

    # 8. the module ports are wide enough
    need(decl_width(smap, 'logical') == '[4:0]', '8. subp_stream_map.logical is not [4:0]')
    for name in ('sub_no', 'sub_cnt'):
        need(decl_width(hud, name) == '[5:0]', '8. transport_hud.%s is not [5:0]' % name)

    if bad:
        print('check_subp32_wiring: FAIL (%s)' % emu_p)
        for b in bad:
            print('  ' + b)
        return 1
    print('check_subp32_wiring: PASS (32 subtitle streams wired end to end)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
