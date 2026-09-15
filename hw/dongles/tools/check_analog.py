#!/usr/bin/env python3
"""Gate the 5.1 analog dongle: assert the EXPORTED netlist, not the source.

The schematic generator and this checker are written from opposite ends - the
generator from "what should each pin connect to", this from "what must each net
contain" - so a typo in one does not reproduce itself in the other.  Reads the
netlist KiCad exported, which is the artefact a fab actually consumes.

Usage:  python3 check_analog.py ../analog-5p1/netlist.net
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ksym

fails = []
checks = 0


def load(path):
    root = ksym.parse_sexp(open(path, encoding="utf-8").read())[0]
    nets = {}
    for n in ksym.find_all(ksym.find_one(root, "nets"), "net"):
        name = ksym.unq(ksym.find_one(n, "name")[1])
        nodes = set()
        for nd in ksym.find_all(n, "node"):
            r = ksym.unq(ksym.find_one(nd, "ref")[1])
            p = ksym.unq(ksym.find_one(nd, "pin")[1])
            nodes.add(f"{r}.{p}")
        nets[name.lstrip("/")] = nodes
    comps = {}
    for c in ksym.find_all(ksym.find_one(root, "components"), "comp"):
        ref = ksym.unq(ksym.find_one(c, "ref")[1])
        val = ksym.unq(ksym.find_one(c, "value")[1])
        fp = ksym.find_one(c, "footprint")
        comps[ref] = (val, ksym.unq(fp[1]) if fp else "")
    return nets, comps


def want(nets, net, *nodes):
    """Net must contain exactly these nodes."""
    global checks
    checks += 1
    got = nets.get(net)
    if got is None:
        fails.append(f"net {net!r} does not exist")
        return
    exp = set(nodes)
    if got != exp:
        fails.append(f"net {net!r}\n     expected {sorted(exp)}\n     got      {sorted(got)}")


def contains(nets, net, *nodes):
    """Net must contain at least these nodes."""
    global checks
    checks += 1
    got = nets.get(net, set())
    miss = set(nodes) - got
    if miss:
        fails.append(f"net {net!r} missing {sorted(miss)}")


def main(path):
    nets, comps = load(path)

    DAC = {"U1": ("SD0", "FL", "FR", 1), "U2": ("SD1", "FC", "LFE", 2),
           "U3": ("SD2", "SL", "SR", 3)}

    # --- the user port contract -------------------------------------------
    # Power contacts are the ones that destroy hardware if wrong.
    contains(nets, "+5V", "J1.1", "FB1.1")
    contains(nets, "GND", "J1.4", "J1.SH")
    # Contact 9 (+3V3 on the IO board) must be loaded by NOTHING.
    want(nets, "HOST_3V3", "J1.9")

    # Each signal contact reaches exactly one series resistor and nothing else.
    for contact, net, r in [("2", "BCLK_IN", "R1"), ("3", "LRCK_IN", "R2"),
                            ("5", "SD0_IN", "R3"), ("6", "SD1_IN", "R4"),
                            ("8", "SD2_IN", "R5")]:
        want(nets, net, f"J1.{contact}", f"{r}.1")

    # --- the mute interlock ------------------------------------------------
    # EN contact, its pull-down and the de-glitch resistor, and nothing else.
    want(nets, "EN_IN", "J1.7", "R6.1", "R7.1")
    contains(nets, "GND", "R6.2")
    # XSMT reaches all three DACs, the de-glitch cap, and the DNP escape R8.
    want(nets, "XSMT", "R7.2", "C5.1", "R8.2", "U1.17", "U2.17", "U3.17")
    # R8 is the only DNP part; it must sit between +3V3 and XSMT so that
    # fitting it (and removing R7) holds the DACs un-muted.
    contains(nets, "+3V3", "R8.1")

    # --- clocks fan out to all three DACs ----------------------------------
    want(nets, "BCLK", "R1.2", "U1.13", "U2.13", "U3.13")
    want(nets, "LRCK", "R2.2", "U1.15", "U2.15", "U3.15")

    # --- each data line reaches exactly ONE DAC ----------------------------
    for u, (din, _l, _r, _n) in DAC.items():
        src = {"SD0": "R3.2", "SD1": "R4.2", "SD2": "R5.2"}[din]
        want(nets, din, src, f"{u}.14")

    # --- per-DAC configuration straps --------------------------------------
    # Getting any of these wrong is silent: the part still runs, just wrong.
    for u in DAC:
        # SCK=GND selects BCK-PLL mode (no MCLK wire). FMT=GND selects I2S.
        # DEMP=GND de-emphasis off. FLT=GND normal latency.
        contains(nets, "GND", f"{u}.12", f"{u}.16", f"{u}.10", f"{u}.11")
        # supplies
        contains(nets, "+3V3", f"{u}.1", f"{u}.8", f"{u}.20")
        contains(nets, "GND", f"{u}.3", f"{u}.9", f"{u}.19")

    # --- charge pump: flying cap across CAPP/CAPM, reservoir on VNEG -------
    for u, (_d, _l, _r, n) in DAC.items():
        want(nets, f"CAPP{n}", f"{u}.2", f"C{n}4.1")
        want(nets, f"CAPM{n}", f"{u}.4", f"C{n}4.2")
        want(nets, f"VNEG{n}", f"{u}.5", f"C{n}5.1")
        want(nets, f"LDOO{n}", f"{u}.18", f"C{n}6.1")

    # --- outputs: OUTL/OUTR -> series R -> jack, with the shunt cap -------
    JACK = {"U1": "J2", "U2": "J3", "U3": "J4"}
    for u, (_d, outl, outr, n) in DAC.items():
        j = JACK[u]
        want(nets, f"{outl}_D", f"{u}.6", f"R{n}1.1")
        want(nets, f"{outr}_D", f"{u}.7", f"R{n}2.1")
        want(nets, outl, f"R{n}1.2", f"C{n}7.1", f"{j}.T")
        want(nets, outr, f"R{n}2.2", f"C{n}8.1", f"{j}.R")
        contains(nets, "GND", f"{j}.S")

    # --- channel order is the PC analog convention -------------------------
    # green = FL/FR, orange = C/LFE, black = SL/SR.  A swap here is inaudible
    # as "wrong" on a bench and very audible in a room.
    want(nets, "FL", "R11.2", "C17.1", "J2.T")
    want(nets, "FR", "R12.2", "C18.1", "J2.R")
    want(nets, "FC", "R21.2", "C27.1", "J3.T")
    want(nets, "LFE", "R22.2", "C28.1", "J3.R")
    want(nets, "SL", "R31.2", "C37.1", "J4.T")
    want(nets, "SR", "R32.2", "C38.1", "J4.R")

    # --- every pin is accounted for ---------------------------------------
    # KiCad names a net for each pin it finds connected to nothing.  Asserting
    # the EXACT set (rather than ignoring them) turns "I forgot to wire a pin"
    # into a failure instead of a silent omission.  U4.4 is the LDO's NC pin.
    global checks
    checks += 1
    unconn = set()
    for k, v in nets.items():
        if k.startswith("unconnected-"):
            unconn |= v
    if unconn != {"U4.4"}:
        fails.append(f"unconnected pins: expected ['U4.4'], got {sorted(unconn)}")

    # --- no NAMED net may be left dangling --------------------------------
    # HOST_3V3 is the deliberate exception: contact 9 is brought out and
    # loaded by nothing, which is the point.
    checks += 1
    singles = sorted(k for k, v in nets.items()
                     if len(v) == 1 and k != "HOST_3V3"
                     and not k.startswith("unconnected-"))
    if singles:
        fails.append(f"named nets with only one connection: {singles}")

    # --- every component has a footprint ----------------------------------
    checks += 1
    nofp = sorted(r for r, (_v, fp) in comps.items() if not fp)
    if nofp:
        fails.append(f"components with no footprint: {nofp}")

    print(f"{len(comps)} components, {len(nets)} nets, {checks} checks")
    if fails:
        print(f"\nFAIL ({len(fails)}):")
        for f in fails:
            print("  - " + f)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1
                  else "../analog-5p1/netlist.net"))
