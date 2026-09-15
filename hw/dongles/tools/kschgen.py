#!/usr/bin/env python3
"""Emit a KiCad 10 .kicad_sch from a component/net description.

Style: every pin gets a short wire stub and a net LABEL.  Nothing is connected by
wire routing, so the netlist is exactly the `pins` dict in the design file and a
mis-drawn wire cannot silently create or break a connection.  Pin coordinates come
from the installed symbol library via ksym, never from a transcribed table.
"""

import os
import uuid

import ksym

SYMDIR = ksym.SYMDIR


def _u():
    return str(uuid.uuid4())


def _esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


GRID = 1.27


def snap(v):
    return round(round(v / GRID) * GRID, 3)


# Pin angle in the symbol -> (stub dx, dy) in SCHEMATIC space, and label rotation.
# Symbol +Y is up, schematic +Y is down, so the Y sign flips.
#   angle 0   : connection point is the pin's LEFT end   -> stub runs left
#   angle 180 : connection point is the pin's RIGHT end  -> stub runs right
#   angle 90  : connection point is the pin's BOTTOM end -> stub runs down
#   angle 270 : connection point is the pin's TOP end    -> stub runs up
_STUB = {
    0:   (-1.0, 0.0, 180),
    180: (1.0, 0.0, 0),
    90:  (0.0, 1.0, 270),
    270: (0.0, -1.0, 90),
}


class Sheet:
    def __init__(self, title, rev="1.0", paper="A3", date=""):
        self.title, self.rev, self.paper, self.date = title, rev, paper, date
        self.libs = {}       # "Lib:Sym" -> raw s-expr text
        self.items = []      # emitted body chunks
        self.instances = []  # (ref, lib_id, uuid, value, footprint)
        self.nets = set()

    # ---- library embedding -------------------------------------------------
    def _embed(self, lib, sym):
        lib_id = f"{lib}:{sym}"
        if lib_id in self.libs:
            return lib_id
        path = os.path.join(SYMDIR, lib + ".kicad_sym")
        text = open(path, encoding="utf-8").read()
        # slice out the top-level (symbol "<name>" ...) block by brace matching
        needle = f'(symbol "{sym}"'
        i = text.index(needle)
        depth, j = 0, i
        while True:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        block = text[i:j]

        # A DERIVED symbol (`extends`) must be FLATTENED here.  KiCad resolves
        # `extends` against the library, but a schematic's lib_symbols cache is
        # self-contained: an unresolved parent yields a symbol with NO PINS, and
        # the schematic then exports a netlist in which that part is simply
        # absent -- silently, with no error.  (PCM5102A extends PCM5100; the
        # netlist gate caught exactly this.)  So splice in the parent's body
        # under the derived name instead.
        if "(extends " in block:
            base = block[block.index("(extends "):].split('"')[1]
            bi = text.index(f'(symbol "{base}"')
            depth, bj = 0, bi
            while True:
                if text[bj] == "(":
                    depth += 1
                elif text[bj] == ")":
                    depth -= 1
                    if depth == 0:
                        bj += 1
                        break
                bj += 1
            # rename the parent and its sub-unit blocks ("PCM5100_1_1" ...)
            block = (text[bi:bj]
                     .replace(f'"{base}"', f'"{sym}"')
                     .replace(f'"{base}_', f'"{sym}_'))
            needle = f'(symbol "{sym}"'

        block = block.replace(needle, f'(symbol "{lib_id}"', 1)
        self.libs[lib_id] = block
        return lib_id

    # ---- placement ---------------------------------------------------------
    def comp(self, ref, lib, sym, value, at, pins, footprint="", mirror=None,
             ref_off=(0, -12.7), val_off=(0, 12.7), dnp=False):
        """Place a symbol and stub+label every pin named in `pins`."""
        lib_id = self._embed(lib, sym)
        s = ksym.load(lib, sym)
        # Snap to KiCad's 1.27 mm connection grid.  Every pin offset in the
        # stock libraries is a multiple of 1.27, so snapping the PLACEMENT is
        # enough to keep every pin and stub endpoint on grid.  Off-grid pins
        # still export a correct netlist but are painful to edit by hand.
        x, y = snap(at[0]), snap(at[1])
        cu = _u()
        self.instances.append((ref, lib_id, cu, value, footprint))

        mir = f"\n\t\t(mirror {mirror})" if mirror else ""
        DNP = "yes" if dnp else "no"
        self.items.append(f"""	(symbol
		(lib_id "{lib_id}")
		(at {x} {y} 0){mir}
		(unit 1)
		(exclude_from_sim no)
		(in_bom yes)
		(on_board yes)
		(dnp {DNP})
		(uuid "{cu}")
		(property "Reference" "{_esc(ref)}"
			(at {x + ref_off[0]} {y + ref_off[1]} 0)
			(effects (font (size 1.27 1.27)))
		)
		(property "Value" "{_esc(value)}"
			(at {x + val_off[0]} {y + val_off[1]} 0)
			(effects (font (size 1.27 1.27)))
		)
		(property "Footprint" "{_esc(footprint)}"
			(at {x} {y} 0)
			(effects (font (size 1.27 1.27)) (hide yes))
		)
		(instances
			(project ""
				(path "/{self.root_uuid}"
					(reference "{_esc(ref)}")
					(unit 1)
				)
			)
		)
	)""")

        for num, net in pins.items():
            p = s.pin(num)
            px = x + p["x"]
            py = y - p["y"]           # symbol +Y up -> schematic +Y down
            dx, dy, lrot = _STUB[int(p["angle"]) % 360]
            L = 3.81
            ex, ey = px + dx * L, py + dy * L
            self.wire((px, py), (ex, ey))
            self.label(net, (ex, ey), lrot)

    def wire(self, a, b):
        self.items.append(f"""	(wire
		(pts (xy {a[0]} {a[1]}) (xy {b[0]} {b[1]}))
		(stroke (width 0) (type default))
		(uuid "{_u()}")
	)""")

    def label(self, name, at, rot=0):
        self.nets.add(name)
        just = "left" if rot in (0, 90) else "right"
        self.items.append(f"""	(label "{_esc(name)}"
		(at {at[0]} {at[1]} {rot})
		(effects
			(font (size 1.27 1.27))
			(justify {just} bottom)
		)
		(uuid "{_u()}")
	)""")

    def text(self, body, at, size=1.27):
        self.items.append(f"""	(text "{_esc(body)}"
		(exclude_from_sim no)
		(at {at[0]} {at[1]} 0)
		(effects (font (size {size} {size})) (justify left bottom))
		(uuid "{_u()}")
	)""")

    # ---- output ------------------------------------------------------------
    def render(self):
        libs = "\n".join(self.libs[k] for k in sorted(self.libs))
        body = "\n".join(self.items)
        return f"""(kicad_sch
	(version 20250114)
	(generator "kschgen")
	(generator_version "9.0")
	(uuid "{self.root_uuid}")
	(paper "{self.paper}")
	(title_block
		(title "{_esc(self.title)}")
		(date "{_esc(self.date)}")
		(rev "{_esc(self.rev)}")
	)
	(lib_symbols
{libs}
	)
{body}
	(sheet_instances
		(path "/"
			(page "1")
		)
	)
)
"""

    root_uuid = property(lambda self: self._ru)

    def __new__(cls, *a, **k):
        o = super().__new__(cls)
        o._ru = _u()
        return o


def write_project(path_noext, sheet):
    """Write <name>.kicad_sch plus a minimal .kicad_pro so KiCad opens it cleanly."""
    with open(path_noext + ".kicad_sch", "w", encoding="utf-8") as f:
        f.write(sheet.render())
    name = os.path.basename(path_noext)
    with open(path_noext + ".kicad_pro", "w", encoding="utf-8") as f:
        f.write('{\n  "board": {},\n  "boards": [],\n  "libraries": {"pinned_footprint_libs": [], "pinned_symbol_libs": []},\n'
                '  "meta": {"filename": "%s.kicad_pro", "version": 1},\n'
                '  "net_settings": {"classes": [{"bus_width": 12, "clearance": 0.2, "diff_pair_gap": 0.25,\n'
                '    "diff_pair_via_gap": 0.25, "diff_pair_width": 0.2, "line_style": 0, "microvia_diameter": 0.3,\n'
                '    "microvia_drill": 0.1, "name": "Default", "pcb_color": "rgba(0, 0, 0, 0.000)", "schematic_color":\n'
                '    "rgba(0, 0, 0, 0.000)", "track_width": 0.25, "via_diameter": 0.6, "via_drill": 0.3, "wire_width": 6}],\n'
                '    "meta": {"version": 3}},\n'
                '  "sheets": [], "text_variables": {}\n}\n' % name)
