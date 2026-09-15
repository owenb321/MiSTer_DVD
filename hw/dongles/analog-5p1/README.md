# 5.1 analog dongle — user port → 3× PCM5102A → six analog channels

**Status: schematic complete, ERC-clean, netlist-gated. Not yet laid out, not yet built.**

Three I2S data lines from the MiSTer user port feed three stereo DACs sharing one bit
clock and frame clock, giving six analog channels on three 3.5 mm jacks in the standard PC
colour order. A stock 3×3.5 mm-to-6×RCA cable then maps straight into any receiver with a
multichannel analog input.

This is the topology a period DVD player used internally — decoder → three I2S lines →
6-channel DAC → six phono sockets — with the DAC moved outside the case.

| File | What it is |
|---|---|
| `analog-5p1.kicad_sch` | the schematic (open in KiCad 10) |
| `analog-5p1.pdf` | rendered, for review or sending to a designer |
| `netlist.net` | KiCad netlist — the machine-readable handoff |
| `bom.csv` | generated from the netlist, so it cannot drift |
| `erc.rpt` | ERC result (0 errors) |

Everything above is **generated**. Edit `../tools/gen_analog.py`, then run `../build.sh`.
Do not hand-edit the schematic: the netlist gate compares against the generator's intent,
and hand edits will be overwritten.

---

## What is verified, and what is not

**Verified**
- KiCad parses the schematic and exports a netlist; ERC reports **0 errors**.
- 62 assertions in `../tools/check_analog.py` pass against the *exported* netlist —
  including every PCM5102A configuration strap, the charge-pump topology, and the channel
  order at the jacks.
- The gate is **proven non-vacuous**: `../build.sh --red` swaps centre and LFE and confirms
  the gate rejects it.
- Every pin coordinate came from the installed KiCad symbol libraries, not from a table I
  typed. (This caught a real defect: `PCM5102A` is a derived symbol, and the first version
  embedded it unresolved — KiCad silently gave the part **no pins at all** and exported a
  netlist with all three DACs absent.)

**Not verified — do these before ordering**
- ⚠ **The user port pinout.** See `../user-port.md`. Confirm contacts 1 (+5 V), 4 (GND) and
  9 (+3.3 V) with a multimeter. This is the only thing here that can damage hardware.
- ⚠ **No PCB layout exists.** A fab needs Gerbers, and nobody has drawn them.
- ⚠ **The core-side RTL does not exist yet** — `USER_OE` push-pull and `mc_i2s_out` are
  designed but unbuilt. A dongle plugged into today's core does nothing.
- Nothing has been built or measured. Every claim is from datasheets and the netlist.

---

## Getting it made

A PCB house does not work from a schematic — it needs **Gerbers + BOM + pick-and-place**.
Someone has to do layout first. Two routes:

1. **Lay it out yourself.** KiCad is already installed; the schematic imports straight into
   Pcbnew. It is a small two-layer board: ~50 parts, one solid ground pour, keep the three
   DAC analog sections away from the regulator, keep BCLK/LRCK stubs short.
2. **Pay for layout.** Send `analog-5p1.pdf`, `netlist.net` and `bom.csv` — that is a
   complete handoff. PCBWay and others offer this; so do freelance designers. Then send the
   resulting Gerbers to assembly.

For JLCPCB-style assembly, fill in the `supplier_pn` column of `bom.csv` yourself. **I have
deliberately not invented distributor part numbers** — a wrong LCSC code silently populates
the wrong part. The PCM5102A and the jacks are likely "extended" parts attracting a setup
fee; the resistors and capacitors are basic parts.

### Sourcing notes

- **J1 (USB 3.0 Standard-A plug)** is the awkward part — board-mount A *plugs* are less
  common than receptacles. The documented alternative is a **Type-B receptacle plus a stock
  A-to-B cable**, which is pin-number straight through. Read the `GND_DRAIN` warning in
  `../user-port.md` first: it is why the plug is the default.
- **J2–J4** are through-hole jacks; confirm your assembler does THT, or substitute SMD.
- **R8 is DNP.** Do not fit it. It is the escape hatch if `EN` turns out to be grounded by
  a cable.

---

## Design decisions worth not re-deriving

- **`SCK` tied to GND** puts the PCM5102A in BCK-PLL mode — it derives its clock from the
  bit clock, so no MCLK wire is needed. That is what frees a user-port contact for `EN`.
  It is also the configuration every Raspberry Pi I2S HAT uses, so it is very well trodden.
- **No DC-blocking capacitors on the outputs, deliberately.** The PCM5102A's internal
  charge pump generates a negative rail, so the outputs are ground-centred. The `100R`/`1nF`
  on each output is RF rejection and short-circuit protection, not a reconstruction filter.
- **Channel order follows the PC analog convention** (green = FL/FR, orange = C/LFE, black =
  SL/SR). HDMI orders the second pair the other way; that gets remapped in the HDMI
  dongle's transmitter, not here, so one RTL implementation serves both.
- **`R6` must stay ≤ 4.7 kΩ.** It is the mute interlock and has to beat the FPGA's ~25 kΩ
  internal pull-up. Raising it silently disarms the safety property.
- **Series resistors R1–R5 are insurance**, not necessity — a ~30 cm run at 3.072 MHz does
  not need termination. 0 Ω is an acceptable substitution.
