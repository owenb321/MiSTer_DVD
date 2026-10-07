#!/usr/bin/env python3
"""Gate: the microcoded VM's memories stay RAMs (docs/nav_engine.md; the GPRM move
it grew from is docs/logic_reclaim.md §9).

dvd/dvd_vm.sv holds five memories that must infer as block RAM: the sequencer's
program ROM and data RAM (the GPRMs, the RAM-resident SPRMs, RSM, the fallback
state), the two byte banks of the command table and the program map. That only
holds while EVERY access to each array sits in its port block:

  * a READ anywhere else (a continuous assign, an always @*, a debug tap) makes
    Quartus build the array out of LUTs -- the parse_buf LUT-RAM explosion --
    which for the 1K x 40 ROM alone would cost thousands of ALMs;
  * a WRITE anywhere else, or an async reset of the array, stops the RAM being
    inferred at all, and Quartus says NOTHING (the ext_mem trap,
    docs/logic_reclaim.md).

Neither shows up in simulation; both show up as a fit that no longer closes. So
this reads dvd/dvd_vm.sv (comments stripped) and requires that every `name[` of
each memory is one of its allowed lines, and that the arrays that need it keep
their M10K ramstyle. (The file name is historical: it gated the GPRM array alone.)

    python3 tools/check_gprm_ram.py [dvd_vm.sv]
    python3 tools/check_gprm_ram.py --red     # must FAIL each re-regression
"""
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from check_hl_btnn_wiring import strip_comments  # noqa: E402

# memory: (its declaration, M10K required, the only lines that may index it)
MEMS = {
    'dram': (r'\(\*\s*ramstyle\s*=\s*"M10K[^"]*"\s*\*\)\s*reg\s*\[15:0\]\s*dram\s*\[0:255\]', {
        'if (d_we) dram[d_a] <= vd;',
        'd_q <= dram[d_a];',
        'initial for (di = 0; di < 256; di = di + 1) dram[di] = 16\'d0;'}),
    'rom': (r'\(\*\s*ramstyle\s*=\s*"M10K[^"]*"\s*\*\)\s*reg\s*\[39:0\]\s*rom\s*\[0:UC_DEPTH-1\]', {
        'always @(posedge clk) ir <= rom[fetch_a];'}),
    'cmem_e': (r'\(\*\s*ramstyle\s*=\s*"M10K[^"]*"\s*\*\)\s*reg\s*\[7:0\]\s*cmem_e\s*\[0:2047\]', {
        'if (cmd_we && !cmd_waddr[0]) cmem_e[cmd_waddr[11:1]] <= cmd_wdata;',
        'ce_q <= cmem_e[c_ra];',
        'for (mi = 0; mi < 2048; mi = mi + 1) begin cmem_e[mi] = 8\'d0; cmem_o[mi] = 8\'d0; end'}),
    'cmem_o': (r'\(\*\s*ramstyle\s*=\s*"M10K[^"]*"\s*\*\)\s*reg\s*\[7:0\]\s*cmem_o\s*\[0:2047\]', {
        'if (cmd_we && cmd_waddr[0]) cmem_o[cmd_waddr[11:1]] <= cmd_wdata;',
        'co_q <= cmem_o[c_ra];',
        'for (mi = 0; mi < 2048; mi = mi + 1) begin cmem_e[mi] = 8\'d0; cmem_o[mi] = 8\'d0; end'}),
    'pmem': (r'reg\s*\[7:0\]\s*pmem\s*\[0:127\]', {
        'if (pm_we) pmem[pm_waddr] <= pm_wdata;',
        'p_q <= pmem[p_ra];',
        'for (mi = 0; mi < 128; mi = mi + 1) pmem[mi] = 8\'d0;'}),
}


def check(path):
    src = strip_comments(open(path).read())
    bad = []
    for name, (decl, allowed) in MEMS.items():
        if not re.search(decl, src):
            bad.append(f'{name} is not declared as it must be ({decl})')
        for ln in src.splitlines():
            if re.search(r'\b%s\[' % name, ln):
                t = ' '.join(ln.split())
                if t not in allowed:
                    bad.append("%s[] touched outside its RAM port block: '%s' -- a read here "
                               "rebuilds the array out of LUTs, a write stops the RAM "
                               "inferring" % (name, t))
    return bad


def red():
    path = os.path.join(HERE, '..', 'dvd', 'dvd_vm.sv')
    if check(path):
        print('  GREEN FAILS on the working tree -- fix that first')
        return 1
    txt = open(path).read()
    muts = [
        ('R1 a debug tap reads the data RAM', "wire parked       = wev_req;",
         "wire parked       = wev_req;\nwire [15:0] dbg_g0 = dram[0];"),
        ('R2 a combinational ROM read', "wire [5:0]  op  = ir[39:34];",
         "wire [39:0] ir_c = rom[pc];\nwire [5:0]  op  = ir[39:34];"),
        ('R3 the data RAM reset in the sequencer', "        for (ri = 0; ri < 4; ri = ri + 1) stk[ri] <= 10'd0;",
         "        for (ri = 0; ri < 4; ri = ri + 1) stk[ri] <= 10'd0;\n        for (ri = 0; ri < 256; ri = ri + 1) dram[ri] <= 16'd0;"),
        ('R4 ramstyle dropped on the data RAM', '(* ramstyle = "M10K, no_rw_check" *) reg [15:0] dram [0:255];',
         'reg [15:0] dram [0:255];'),
        ('R5 a second write port on the command table', "always @(posedge clk) begin\n    if (cmd_we && cmd_waddr[0])",
         "always @(posedge clk) if (start) cmem_o[0] <= 8'd0;\nalways @(posedge clk) begin\n    if (cmd_we && cmd_waddr[0])"),
    ]
    rc = 0
    for label, a, b in muts:
        if txt.count(a) != 1:
            print('  BROKEN %s: anchor not found exactly once' % label)
            rc = 1
            continue
        with tempfile.NamedTemporaryFile('w', suffix='.sv', delete=False) as f:
            f.write(txt.replace(a, b, 1))
            tmp = f.name
        got = check(tmp)
        os.unlink(tmp)
        print(('  ok     %s -> %s' % (label, got[0])) if got else ('  MISSED %s' % label))
        rc |= 0 if got else 1
    return rc


def main():
    if sys.argv[1:2] == ['--red']:
        return red()
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', 'dvd', 'dvd_vm.sv')
    bad = check(path)
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: the VM\'s ROM, data RAM, command table and program map are touched only '
          'by their port blocks')
    return 0


if __name__ == '__main__':
    sys.exit(main())
