#!/usr/bin/env python3
"""Jump latency from hil_suite runs: seconds from a seek FLUSH to video_live, per scenario.

The suite's own checks score WHERE a jump lands, not how long it took, and a press window
only has so long. This is the number the plain-ISO read-ahead doubled on interactive discs
while every check stayed green (docs/physical_disc.md "What the ring costs a jump").

    tools/hil_jumps.py control=<suite-out>/control build=<suite-out>/build

Each argument is name=<dir holding the scenario dirs>. Compare medians between arms on the
same rig, with nothing else using the share.
"""
import json
import os
import sys


def jumps(agent_jsonl):
    out, start = [], None
    for line in open(agent_jsonl):
        try:
            e = json.loads(line).get('nav')
        except ValueError:
            continue
        if not e or 't_ev' not in e or e.get('backlog'):
            continue
        if e['ev'] == 'FLUSH' and e.get('seek') and start is None:
            start = e['t_ev']
        elif e['ev'] == 'STATE' and e.get('video_live') and start is not None:
            out.append(e['t_ev'] - start)
            start = None
    return sorted(out)


def main():
    arms = [a.split('=', 1) for a in sys.argv[1:]]
    if not arms or any(len(a) != 2 for a in arms):
        sys.exit(__doc__)
    scenarios = sorted({s for _, d in arms for s in os.listdir(d)
                        if os.path.exists(os.path.join(d, s, 'agent.jsonl'))})
    for s in scenarios:
        for name, d in arms:
            path = os.path.join(d, s, 'agent.jsonl')
            j = jumps(path) if os.path.exists(path) else []
            if j:
                print('%-28s %-10s jumps %3d  median %.3f  p90 %.3f  max %.3f' % (
                    s, name, len(j), j[len(j) // 2], j[int(len(j) * .9)], j[-1]))
            else:
                print('%-28s %-10s no jumps (a core with no nav FIFO reads as this)' % (s, name))


if __name__ == '__main__':
    main()
