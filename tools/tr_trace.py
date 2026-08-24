#!/usr/bin/env python3
# tr_trace.py - drive tools/dvd_vm_ref.py (our dvd_vm.sv mirror) through Tomb
# Raider's IN-TITLE HLI choices and print the domain/PGC path, to diff against
# libdvdnav (tools/bin/trace_nav). TR's game choices are title-domain HLI whose
# buttons carry SELF-CONTAINED commands (e.g. "71 04 00 0f 00 02 00 02" =
# g15=2; LinkPGCN 2), so a press = execute that command directly (no POST).
#
#   python3 tools/tr_trace.py <iso> "CMD1 ; CMD2 ; ..."
# where each CMDk is an 8-byte hex button command applied at the k-th park
# (a point where the ref would STOP/LOOP waiting for input). Use ';' to
# separate; whitespace inside a command is fine.
#
# Prints every PGC the ref loads (DOM vts PGCN) so the path can be diffed
# against libdvdnav's [VTS_CHANGE]/[CELL] title/part markers.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dvd_vm_ref as R


def parse_cmds(s):
    out = []
    for tok in s.split(';'):
        tok = tok.strip()
        if not tok:
            continue
        out.append(bytes(int(x, 16) for x in tok.split()))
    return out


def drive(iso, cmds, max_steps=6000):
    nav = R.IsoNav(iso)
    vm = R.VM(nav, verbose=False)
    ci = 0
    seen = set()
    path = []

    def load_note():
        st = (R.DOM_NAME[vm.dom], vm.vts, vm.pgcn)
        if not path or path[-1] != st:
            path.append(st)
            print("  LOAD %s vts=%d PGCN %d  cell=%d" %
                  (R.DOM_NAME[vm.dom], vm.vts, vm.pgcn, vm.cell))

    if not vm.boot():
        print("BOOT FAILED"); return
    load_note()

    def inject_or_stop(why):
        nonlocal ci
        if ci >= len(cmds):
            print(">>> PARK/%s at %s vts=%d PGCN %d cell=%d (script exhausted)" %
                  (why, R.DOM_NAME[vm.dom], vm.vts, vm.pgcn, vm.cell))
            return False
        cmd = cmds[ci]; ci += 1
        print("  PRESS[%d] %s   (at %s vts=%d PGCN %d)" %
              (ci, R.decode_vmcmd(cmd), R.DOM_NAME[vm.dom], vm.vts, vm.pgcn))
        vm.stopped = False
        seen.clear()
        vm.fuse = 0
        link = R.eval_block([cmd], vm.regs, vm.lfsr, R.FUSE, vm.trace)
        if link is not None:
            vm._process(link)
        load_note()
        return True

    for step in range(max_steps):
        if vm.stopped:
            if not inject_or_stop("STOP"):
                return
            continue
        cells = vm.pgc["cells"]
        if not cells:
            vm.fuse = 0
            if not vm._run_post():
                print(">>> post-error (0cell)"); return
            load_note()
            continue
        cell = vm.cell if vm.cell < len(cells) else 0
        meta = cells[cell]
        still, cmd_nr = meta["still"], meta["cmd_nr"]
        if still == 0xFF:
            if not inject_or_stop("STILL"):
                return
            continue
        st = (vm.dom, vm.vts, vm.pgcn, cell)
        if st in seen:
            # looping cell (video menu waiting for input)
            if not inject_or_stop("LOOP"):
                return
            continue
        seen.add(st)
        before = (vm.dom, vm.vts, vm.pgcn, vm.pgc)
        linked = False
        if cmd_nr and vm.pgc["cellc"] and cmd_nr <= len(vm.pgc["cellc"]):
            vm.fuse = 0
            link = R.eval_block([vm.pgc["cellc"][cmd_nr - 1]], vm.regs, vm.lfsr,
                                R.FUSE, vm.trace)
            if link is not None:
                if not vm._process(link):
                    print(">>> cell-cmd-link error"); return
                linked = True
        if linked and (vm.dom, vm.vts, vm.pgcn, vm.pgc) != before:
            load_note()
            continue
        vm.cell = cell + 1
        if vm.cell >= vm.pgc["nr_cells"]:
            vm.fuse = 0
            if not vm._run_post():
                print(">>> post-error"); return
            load_note()
    print(">>> step cap reached")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: tr_trace.py <iso> \"CMD1 ; CMD2 ; ...\""); sys.exit(1)
    iso = sys.argv[1]
    script = sys.argv[2] if len(sys.argv) > 2 else ""
    print("SCRIPT: %r" % script)
    drive(iso, parse_cmds(script))
