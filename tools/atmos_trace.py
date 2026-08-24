#!/usr/bin/env python3
# atmos_trace.py - drive tools/dvd_vm_ref.py (our RTL VM/reader mirror) with a
# button SCRIPT, exactly like tools/bin/trace_nav drives libdvdnav, so the two
# can be diffed on the SAME path to find where OUR nav diverges.
#
#   python3 tools/atmos_trace.py <iso> "1 1 2 1"   # press these buttons at parks
#
# Script tokens (one consumed per menu park):
#   N   press (select+activate) button N          -- all Atmosfear menu buttons
#                                                     are LinkTailPGC -> run POST
#   .   leave a finite still / advance
#
# A "park" is a menu-domain PGC that is waiting for input: either an indefinite
# (0xFF) still cell, or a looping video-menu cell (cell command loops back to
# itself: LinkTopC / LinkTopPGC).  At a park we set HL_BTNN (SPRM8) to the
# scripted button and run the PGC POST -- the LinkTailPGC dispatch the disc
# authors for these menus (verified via trace_nav: every button = 20 01 .. 0d).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dvd_vm_ref as R

LOOP_CELLCMDS = None  # resolved from decode below


def cell_cmd_is_selfloop(vm, cmd_nr):
    """True if the current cell's command loops the menu (LinkTopC/LinkTopPGC),
    i.e. the cell waits for a button rather than advancing."""
    if not cmd_nr or not vm.pgc["cellc"] or cmd_nr > len(vm.pgc["cellc"]):
        return False
    link = R.eval_block([vm.pgc["cellc"][cmd_nr - 1]], R.Regs(), R.Lfsr(),
                        R.FUSE, None)
    return link is not None and link[0] in ("LinkTopC", "LinkTopPGC")


def is_menu(vm):
    return vm.dom in (R.DOM_VMGM, R.DOM_VTSM)


def post_target(vm, btn):
    """Evaluate this PGC's POST with HL_BTNN=btn (no side effects on vm.regs)
    and return the resulting link tuple, so we can tell a real multi-choice
    menu (different target per button) from a 'press-any-to-continue' screen
    (same target for every button = an foac auto-action in libdvdnav)."""
    r = R.Regs()
    for i in range(16):
        r.gprm[i] = vm.regs.gprm[i]
    for i in range(len(vm.regs.sprm)):
        r.sprm[i] = vm.regs.sprm[i]
    r.sprm[8] = btn << 10
    return R.eval_block(vm.pgc["post"], r, R.Lfsr(), R.FUSE, None)


def is_real_choice(vm):
    """A user menu iff two different buttons dispatch to different targets."""
    a = post_target(vm, 1)
    b = post_target(vm, 2)
    return a != b


def drive(iso, script, verbose=False, max_steps=4000):
    nav = R.IsoNav(iso)
    vm = R.VM(nav, verbose=verbose)
    toks = script.split()
    ti = 0
    parks = []
    seen = set()
    last_title = [None]
    if not vm.boot():
        return {"result": "boot-failed", "parks": parks, "vm": vm}
    for step in range(max_steps):
        if vm.stopped:
            return {"result": "STOPPED at %s vts=%d PGCN %d" %
                    (R.DOM_NAME[vm.dom], vm.vts, vm.pgcn), "parks": parks, "vm": vm}
        cells = vm.pgc["cells"]
        if not cells:
            vm.fuse = 0
            if not vm._run_post():
                return {"result": "post-error 0cell", "parks": parks, "vm": vm}
            continue
        cell = vm.cell if vm.cell < len(cells) else 0
        meta = cells[cell]
        still, cmd_nr = meta["still"], meta["cmd_nr"]

        park = is_menu(vm) and (still == 0xFF or cell_cmd_is_selfloop(vm, cmd_nr))
        if park:
            g = vm.regs.gprm
            gstr = "g3=%d [" % g[3] + " ".join("%x" % x for x in g) + "]"
            here = (R.DOM_NAME[vm.dom], vm.vts, vm.pgcn, cell, still)
            real = is_real_choice(vm)
            if verbose:
                print("  PARK PGC%-3d real=%d %s" % (vm.pgcn, real, gstr))
            if not real:
                # 'press-any-to-continue' auto screen: activate button 1, no
                # script token consumed (libdvdnav auto-actions past it).
                vm.regs.sprm[8] = 1 << 10
                vm.fuse = 0
                if not vm._run_post():
                    return {"result": "post-error autocont", "parks": parks, "vm": vm}
                continue
            if ti >= len(toks):
                parks.append(here + ("PGC%d" % vm.pgcn,))
                return {"result": "PARK(script-exhausted) at %s vts=%d PGCN %d cell %d still=%d"
                        % here, "parks": parks, "vm": vm}
            t = toks[ti]; ti += 1
            parks.append((vm.pgcn, "g3=%d" % g[3], "btn" + t))
            if t == '.':
                vm.cell = cell + 1
                if vm.cell >= vm.pgc["nr_cells"]:
                    vm.fuse = 0
                    vm._run_post()
                continue
            n = int(t)
            vm.regs.sprm[8] = n << 10          # HL_BTNN latch (button activate)
            vm.fuse = 0
            if not vm._run_post():
                return {"result": "post-error at park", "parks": parks, "vm": vm}
            continue

        # play through (mirror run()'s cell/cellcmd/post loop). Track the last
        # title domain we entered; if the drive loops/stops on it, that title is
        # the "game" landing (the JumpTT destination to compare vs libdvdnav).
        if vm.dom == R.DOM_TT:
            dur = sum(c.get("pbtime", 0) for c in cells)
            last_title[0] = (vm.vts, vm.pgcn, vm.pgc["nr_cells"], dur)
        # loop detection: same (dom,vts,pgcn,cell) twice -> parked
        st = (vm.dom, vm.vts, vm.pgcn, cell)
        if st in seen:
            lt = last_title[0]
            return {"result": "LOOP; last TITLE vts=%s PGCN %s cells=%s dur=%ss"
                    % (lt if lt else (None,)*4), "title_vts": lt[0] if lt else None,
                    "parks": parks, "vm": vm}
        seen.add(st)
        before = (vm.dom, vm.vts, vm.pgcn, vm.pgc)
        linked = False
        if cmd_nr and vm.pgc["cellc"] and cmd_nr <= len(vm.pgc["cellc"]):
            vm.fuse = 0
            link = R.eval_block([vm.pgc["cellc"][cmd_nr - 1]], vm.regs, vm.lfsr,
                                R.FUSE, vm.trace)
            if link is not None:
                if not vm._process(link):
                    return {"result": "cell-cmd-link-error", "parks": parks, "vm": vm}
                linked = True
        if linked and (vm.dom, vm.vts, vm.pgcn, vm.pgc) != before:
            continue
        vm.cell = cell + 1
        if vm.cell >= vm.pgc["nr_cells"]:
            vm.fuse = 0
            if not vm._run_post():
                return {"result": "post-error", "parks": parks, "vm": vm}
    return {"result": "step-cap", "parks": parks, "vm": vm}


def main():
    if len(sys.argv) < 2:
        print("usage: atmos_trace.py <iso> [\"script\"] [-v]"); sys.exit(1)
    iso = sys.argv[1]
    script = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('-') else ""
    verbose = '-v' in sys.argv
    out = drive(iso, script, verbose=verbose)
    print("\nSCRIPT: %r" % script)
    for p in out["parks"]:
        print("  park:", p)
    print("RESULT:", out["result"])


if __name__ == "__main__":
    main()
