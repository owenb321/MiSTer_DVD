#!/usr/bin/env python3
"""Gate for the LINEAR-STREAM JUNCTION (issue #188): check how emu.sv wires
ps_demux's park on a program end code to dvd/lin_junction.sv and flush_ctl.

WHY THIS EXISTS
---------------
The parts are benched (`bench/dvd/run_lin_junction.sh`): ps_demux parks on a 0xB9
when `jn_en` is high and resumes on `jn_go`; lin_junction waits for a continuous
drain and pulses `junction` then `go`; flush_ctl turns `lin_junction` into
aud_flush + seek_flush without load_flush. Everything that joins them lives in
emu.sv, which has no bench, and each seam is a way to ship the old bug or a new
one:
  * `jn_en` must be the LINEAR qualifier, `lin_mode_w` (= lin_seek_ok_w &&
    !cell_ready). Tied high, every DVD VOB that carries a 0xB9 would park and
    flush mid-title; tied low, issue #188 is back.
  * the controller must reset on `pipe_rst_n` (a seek or load mid-park resets the
    demux, which ends the park) and read the REAL drain terms, `aud_drained_w` and
    `vbuf_empty`. Tied high, it flushes the old stream's last second of audio and
    pictures; that is the defect, moved.
  * its `junction` must reach flush_ctl's `lin_junction`, and its `go` the demux.
  * the STD video hold must re-arm on `lin_junction` as on a load, or the movie's
    first picture starts the clock before its audio has caught up.
  * the junction nets must be declared before their first use: emu.sv has no
    `default_nettype none`, so a forward reference is a silent 1-bit implicit net.
  * DVD.qsf must name dvd/lin_junction.sv, or Quartus never sees the module.
A module bench is handed the value and cannot see a wrong wire, so this reads the
connections out of the file.

    python3 tools/check_lin_junction_wiring.py [emu.sv]   # exit 0 = wired right
    python3 tools/check_lin_junction_wiring.py --red      # self-test: each
                                                          # miswiring must FAIL

strip_comments() runs first and every match is over code: the comments beside
this logic quote the terms it checks.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')


def strip_comments(src):
    """Blank out // and /* */ comments, preserving offsets and newlines."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            j = n if j < 0 else j
            out.append(' ' * (j - i))
            i = j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', src[i:j]))
            i = j
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def instantiation(src, module):
    """(start offset, body) of the first `module [#(..)] inst (...)`, or (None, None)."""
    m = re.search(r'(?m)^\s*' + re.escape(module) + r'\s+(#\s*\(.*?\)\s*)?\w+\s*\(', src, re.S)
    if not m:
        return None, None
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == '(':
            depth += 1
        elif src[j] == ')':
            depth -= 1
            if depth == 0:
                return m.start(), src[i + 1:j]
    return None, None


def port_net(body, port):
    m = re.search(r'\.' + re.escape(port) + r'\s*\(\s*([^()]*?)\s*\)', body)
    return None if not m else ''.join(m.group(1).split())


PORTS = {
    'ps_demux':     {'jn_en': 'lin_mode_w', 'jn_go': 'dmx_jn_go', 'jn_wait': 'dmx_jn_wait'},
    'lin_junction': {'clk': 'clk_sys', 'rst_n': 'pipe_rst_n', 'jn_wait': 'dmx_jn_wait',
                     'aud_drained': 'aud_drained_w', 'vbuf_empty': 'vbuf_empty',
                     'junction': 'lin_junction', 'go': 'dmx_jn_go'},
    'flush_ctl':    {'lin_junction': 'lin_junction'},
}
NETS = ('dmx_jn_wait', 'dmx_jn_go', 'lin_junction')


def check(raw, qsf):
    src = strip_comments(raw)
    bad = []
    first_use = len(src)
    for mod, ports in PORTS.items():
        at, body = instantiation(src, mod)
        if body is None:
            bad.append('%s: no instance in emu.sv' % mod)
            continue
        first_use = min(first_use, at)
        for port, want in ports.items():
            got = port_net(body, port)
            if got != want:
                bad.append('%s .%s: want (%s), got (%s)' % (mod, port, want, got))

    # the linear qualifier: never DVD cell mode
    m = re.search(r'\bwire\s+lin_mode_w\s*=\s*([^;]+);', src)
    expr = '' if not m else ''.join(m.group(1).split())
    if expr != 'lin_seek_ok_w&&!cell_ready':
        bad.append('lin_mode_w: want `lin_seek_ok_w && !cell_ready`, got `%s`' % expr)

    # the STD video hold re-arms on the junction, as on a load
    if not re.search(r"else\s+if\s*\(\s*!pipe_rst_n\s*\|\|\s*lin_junction\s*\)\s*begin\s*"
                     r"av_vid_hold\s*<=\s*1'b1\s*;", src):
        bad.append("av_vid_hold: the `else if (!pipe_rst_n || lin_junction)` arm is gone")

    # declared before the first instance that uses them
    for net in NETS:
        d = re.search(r'\bwire\s+' + net + r'\s*;', src)
        if not d:
            bad.append('%s: no `wire %s;` declaration' % (net, net))
        elif d.start() > first_use:
            bad.append('%s: declared after its first use (an implicit net)' % net)

    if not re.search(r'(?m)^set_global_assignment\s+-name\s+SYSTEMVERILOG_FILE\s+dvd/lin_junction\.sv\s*$',
                     qsf):
        bad.append('DVD.qsf: dvd/lin_junction.sv is not in the project')
    return bad


def red(raw, qsf):
    """Each plausible miswiring must fail the check."""
    cases = [
        ('jn_en tied high (parks DVD too)',
         r'\.jn_en(\s*)\(\s*lin_mode_w\s*\)', r".jn_en\1(1'b1)", 'emu'),
        ('jn_en tied low (issue #188 back)',
         r'\.jn_en(\s*)\(\s*lin_mode_w\s*\)', r".jn_en\1(1'b0)", 'emu'),
        ('lin_mode_w admits cell mode',
         r'(wire\s+lin_mode_w\s*=\s*lin_seek_ok_w)\s*&&\s*!cell_ready', r'\1', 'emu'),
        ('controller on the core reset',
         r'(\.rst_n\s*\(\s*)pipe_rst_n(\s*\),\s*//\s*a seek/load)', r'\1reset_n\2', 'emu'),
        # anchored INSIDE the controller's instance: the reader carries the same
        # two port names, and a mutation landing there tests nothing here
        ('audio drain tied high',
         r'(lin_junction_i\s*\([^;]*?\.aud_drained\s*)\(\s*aud_drained_w\s*\)', r"\1(1'b1)", 'emu'),
        ('VBUF drain tied high',
         r'(lin_junction_i\s*\([^;]*?\.vbuf_empty\s*)\(\s*vbuf_empty\s*\)', r"\1(1'b1)", 'emu'),
        ('flush_ctl row unwired',
         r'(\.lin_junction\s*)\(\s*lin_junction\s*\)', r"\1(1'b0)", 'emu'),
        ('demux never released',
         r'\.jn_go(\s*)\(\s*dmx_jn_go\s*\)', r".jn_go\1(1'b0)", 'emu'),
        ('video hold not re-armed',
         r'!pipe_rst_n\s*\|\|\s*lin_junction', '!pipe_rst_n', 'emu'),
        ('net declared after use',
         r'wire dmx_jn_wait;', '', 'emu'),
        ('module not in DVD.qsf',
         r'(?m)^set_global_assignment -name SYSTEMVERILOG_FILE dvd/lin_junction\.sv\n', '', 'qsf'),
    ]
    ok = True
    for name, pat, sub, where in cases:
        tgt = raw if where == 'emu' else qsf
        mut, n = re.subn(pat, sub, tgt, count=1, flags=re.S)
        if n == 0:
            print('RED STALE: %s (pattern matched nothing)' % name)
            ok = False
            continue
        if name == 'net declared after use':
            # re-declare it after the instances instead of deleting it outright
            mut = mut + '\nwire dmx_jn_wait;\n'
        why = check(mut, qsf) if where == 'emu' else check(raw, mut)
        if not why:
            print('RED MISS: %s passed the check' % name)
            ok = False
        else:
            print('red ok: %s -> FAIL: %s' % (name, why[0]))
    return ok


def main():
    args = [a for a in sys.argv[1:] if a != '--red']
    path = args[0] if args else os.path.join(ROOT, 'dvd', 'emu.sv')
    raw = open(path).read()
    qsf = open(os.path.join(ROOT, 'DVD.qsf')).read()
    if '--red' in sys.argv[1:]:
        if not red(raw, qsf):
            return 1
    bad = check(raw, qsf)
    if bad:
        print('\n'.join('FAIL: ' + b for b in bad))
        return 1
    print('OK: ps_demux .jn_en(lin_mode_w) parks on 0xB9 -> lin_junction (pipe_rst_n; '
          'aud_drained_w && vbuf_empty) -> flush_ctl .lin_junction + av_vid_hold; go -> demux')
    return 0


if __name__ == '__main__':
    sys.exit(main())
