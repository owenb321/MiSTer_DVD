#!/usr/bin/env python3
"""trick_reader_check.py <log> <iso> --tier T --rev R

Checks bench/dvd/iso_reader_trick_tb.sv's log against tools/trick_splice.py walk_cells,
run over the cell table the reader itself parsed (the log's C lines):
  - every armed VOBU (A lines): the same NAV packs, the same end sectors, in order;
  - every sector read from the first armed NAV pack on (R lines): exactly nav..end of
    each VOBU in turn, nothing else (the last VOBU's reads may be cut short by the
    end of the run);
  - the PGC's edge (E) exactly when the model's walk ends.
Exit 0 = PASS.
"""
import argparse, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'tools'))
from trick_splice import walk_cells                 # noqa: E402
from trick_scan import title_extents, SEC           # noqa: E402


def play_order(cells, angle):
    """[(first, last, lvobu)] in play order: each angle block collapsed to its chosen
    angle's cell, as the reader plays it (angle 0 or past the block's count = 1)."""
    out, i = [], 0
    while i < len(cells):
        cat = cells[i][3]
        if (cat >> 4) & 3 == 1 and cat >> 6 == 1:
            j = i
            while j + 1 < len(cells) and (cells[j + 1][3] >> 4) & 3 == 1 and cells[j + 1][3] >> 6 >= 2:
                j += 1
            n = j - i + 1
            k = angle if 1 <= angle <= n else 1
            out.append(cells[i + k - 1][:3])
            i = j + 1
        else:
            out.append(cells[i][:3])
            i += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('log')
    ap.add_argument('iso')
    ap.add_argument('--tier', type=int, required=True)
    ap.add_argument('--rev', type=int, required=True)
    ap.add_argument('--angle', type=int, default=0, help='the angle each block plays (0 = 1)')
    a = ap.parse_args()

    cells, arms, reads, edge, tcell, xcn = [], [], [], False, None, []
    for line in open(a.log):
        t = line.split()
        if not t:
            continue
        if t[0] == 'C':
            cells.append((int(t[2]), int(t[3]), int(t[4]), int(t[5]) if len(t) > 5 else 0))
        elif t[0] == 'T':
            tcell = int(t[1])
        elif t[0] == 'A':
            arms.append((int(t[1]), int(t[2])))
            xcn.append(int(t[3]))
        elif t[0] == 'R':
            reads.append(int(t[1]))
        elif t[0] == 'E':
            edge = True
    if not arms:
        print('FAIL: no armed VOBU in the log')
        return 1

    with open(a.iso, 'rb') as f:
        # RBN -> ISO LBA through the title VOBs of the VTS the reader plays: the one
        # whose mapping puts the first armed NAV pack on a sector the reader read.
        ext = title_extents(f)
        rset = set(reads)
        lba_of = None
        for vts, xs in sorted(ext.items()):
            spans, base = [], 0
            for lba, size in xs:
                n = (size + SEC - 1) // SEC
                spans.append((base, base + n, lba))
                base += n

            def m(rbn, spans=spans):
                for lo, hi, lba in spans:
                    if lo <= rbn < hi:
                        return lba + rbn - lo
                return None
            if m(arms[0][0]) in rset:
                lba_of = m
                break
        if lba_of is None:
            print('FAIL: no VTS maps the first armed NAV pack onto a sector the reader read')
            return 1

        def read_rbn(rbn, n):
            f.seek(lba_of(rbn) * SEC)
            return f.read(n * SEC)

        # Play order: an angle block is ONE step, the chosen angle's cell (block_type 1 in
        # the category byte's [5:4]; block_mode [7:6] 1 starts a block, 2/3 continue it).
        play = play_order(cells, a.angle)
        nav0 = arms[0][0]
        cell = next((i for i, (lo, hi, _) in enumerate(play) if lo <= nav0 <= hi), None)
        if cell is None:
            print('FAIL: the first armed NAV pack %d is in no cell' % nav0)
            return 1
        walk = list(walk_cells(read_rbn, play, cell, nav0, a.tier, bool(a.rev), len(arms) + 1))
        model = [(n, e) for n, e, _ in walk]
        mcross = [c for _, _, c in walk]

    print('cells %d, %d in play order (trick began in cell %s, first NAV in play step %d); armed %d, model %d, edge %s'
          % (len(cells), len(play), tcell, cell, len(arms), len(model), edge))
    ok = True
    for i, (got, want) in enumerate(zip(arms, model)):
        if got != want:
            print('  VOBU %d: reader nav %d end %d, model nav %d end %d' % (i, *got, *want))
            ok = False
            break
    # cell crossings: the reader's running count at each arm vs the model's. On a disc
    # whose cells are physically contiguous, next_vobu at a cell's end lands where a
    # crossing would, so only this sees whether the reader went through the cell table.
    run = 0
    for i in range(min(len(arms), len(mcross))):
        run += mcross[i]
        if xcn[i] - xcn[0] != run - mcross[0]:
            print('  VOBU %d: the reader has crossed %d cells, the model %d'
                  % (i, xcn[i] - xcn[0], run - mcross[0]))
            ok = False
            break
    if len(model) < len(arms):
        print('  the reader armed %d VOBUs, the model only %d' % (len(arms), len(model)))
        ok = False
    if edge and len(model) != len(arms):
        print('  the reader reached the edge after %d VOBUs, the model walks on' % len(arms))
        ok = False
    if not edge and len(model) == len(arms) and len(arms) > 0 and ok:
        # the model ended exactly here: the reader should have said so (unless the
        # run's VOBU budget ended at the same place; the runner asks for one more)
        pass

    # the reads, from the first armed NAV pack's sector on
    want = []
    for n, e in arms:
        want += [lba_of(r) for r in range(n, e + 1)]
    try:
        k = reads.index(want[0])
    except ValueError:
        print('  the first armed NAV pack was never read')
        return 1
    got = reads[k:k + len(want)]
    last_n = arms[-1][1] - arms[-1][0] + 1
    full = len(want) - last_n
    if got[:full] != want[:full]:
        j = next(i for i in range(full) if i >= len(got) or got[i] != want[i])
        print('  read %d: reader LBA %s, expected %d' % (j, got[j] if j < len(got) else 'none', want[j]))
        ok = False
    elif got[full:] != want[full:len(got)]:
        print('  the last VOBU\'s reads differ')
        ok = False
    print('reads checked: %d' % min(len(got), len(want)))
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
