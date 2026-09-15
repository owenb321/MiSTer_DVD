#!/usr/bin/env python3
"""MiSTer DVD - 6-channel analog dongle (user port -> 3x PCM5102A -> 5.1 analog).

The design IS the `pins` dicts below: every connection is a net label, so this file
is simultaneously the schematic and the netlist.  Generate, then gate with
  kicad-cli sch export netlist ... && python3 check_analog.py

Connector pin numbering is the USB 3.0 Standard-A contact numbering.  What each
contact carries on the MiSTer IO board is a BOARD fact, not a USB fact - see
../user-port.md.  Signal contacts are interchangeable because the core assigns
them; the POWER contacts are not, and they are the ones to verify first.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from kschgen import Sheet, write_project

S = Sheet("MiSTer DVD - 5.1 analog dongle (user port)", rev="A", paper="A1",
          date="2026-09-14")

# ---------------------------------------------------------------- footprints
FP_R = "Resistor_SMD:R_0603_1608Metric"
FP_C = "Capacitor_SMD:C_0603_1608Metric"
FP_CB = "Capacitor_SMD:C_0805_2012Metric"      # bulk / charge-pump caps
FP_DAC = "Package_SO:TSSOP-20_4.4x6.5mm_P0.65mm"
FP_LDO = "Package_TO_SOT_SMD:SOT-23-5"
FP_FB = "Inductor_SMD:L_0603_1608Metric"
FP_USB = "Connector_USB:USB3_A_Plug_Horizontal"
FP_JACK = "Connector_Audio:Jack_3.5mm_CUI_SJ1-3535NG_Horizontal"

# ================================================================= connector
# Contact -> function.  EN deliberately sits on contact 7: on a REAL USB3 port
# contact 7 is the ground drain, so a mis-plug pulls EN low and the board is mute.
S.comp("J1", "Connector", "USB3_A", "USB3_A_PLUG", (60, 80), {
    "1": "+5V",          # IO board: +5V
    "2": "BCLK_IN",      # IO board: USER_IO[a]
    "3": "LRCK_IN",      # IO board: USER_IO[b]
    "4": "GND",          # IO board: GND
    "5": "SD0_IN",       # IO board: USER_IO[c]
    "6": "SD1_IN",       # IO board: USER_IO[d]
    "7": "EN_IN",        # IO board: USER_IO[e]   (USB3 would be GND_DRAIN)
    "8": "SD2_IN",       # IO board: USER_IO[f]
    "9": "HOST_3V3",     # IO board: +3.3V  - NOT USED, test point only
    "SH": "GND",
}, footprint=FP_USB, ref_off=(0, -24), val_off=(0, 24))

for i, t in enumerate([
        "J1 = USB 3.0 Standard-A PLUG - this board is the dongle.",
        "Contacts 2,3,5,6,7,8 are FPGA signals; 1=+5V, 4=GND, 9=+3V3.",
        "Which USER_IO[] index lands on which contact is a property of the",
        "IO BOARD. The core assigns its indices to match - so the signal",
        "contacts are interchangeable and only 1/4/9 must be verified.",
        "HOST_3V3 is left unloaded on purpose: we regulate our own 3V3."]):
    S.text(t, (40, 124 + i * 6))

# =============================================================== power tree
S.comp("FB1", "Device", "FerriteBead", "600R@100MHz", (200, 75),
       {"1": "+5V", "2": "+5VF"}, footprint=FP_FB)
S.comp("C1", "Device", "C", "10uF", (228, 80), {"1": "+5VF", "2": "GND"},
       footprint=FP_CB)
S.comp("C2", "Device", "C", "100nF", (253, 80), {"1": "+5VF", "2": "GND"},
       footprint=FP_C)
S.comp("U4", "Regulator_Linear", "AP2112K-3.3", "AP2112K-3.3", (300, 78), {
    "1": "+5VF", "2": "GND", "3": "+5VF", "5": "+3V3",
}, footprint=FP_LDO)
S.comp("C3", "Device", "C", "10uF", (350, 80), {"1": "+3V3", "2": "GND"},
       footprint=FP_CB)
S.comp("C4", "Device", "C", "100nF", (375, 80), {"1": "+3V3", "2": "GND"},
       footprint=FP_C)

# PWR_FLAGs: the connector's VBUS/GND pins are declared as power INPUTS, so
# without these ERC reports every rail as undriven.  They assert "this rail is
# fed from off-board", which is exactly true here.
for i, (ref, net, x) in enumerate([("#FLG1", "+5V", 150), ("#FLG2", "GND", 175),
                                   ("#FLG3", "+5VF", 265),
                                   ("#FLG4", "HOST_3V3", 110)]):
    S.comp(ref, "power", "PWR_FLAG", "PWR_FLAG", (x, 60), {"1": net},
           ref_off=(0, -8), val_off=(0, -4))

for i, t in enumerate([
        "5V from the user port, regulated locally to 3V3.",
        "3x PCM5102A is ~90 mA; AP2112K is a 600 mA part.",
        "U4 EN tied to VIN: the rail is always on, muting is",
        "done at the DACs (XSMT), not by cutting power."]):
    S.text(t, (195, 124 + i * 6))

# ================================================= series damping + enable
for i, (ref, a, b) in enumerate([
        ("R1", "BCLK_IN", "BCLK"), ("R2", "LRCK_IN", "LRCK"),
        ("R3", "SD0_IN", "SD0"), ("R4", "SD1_IN", "SD1"),
        ("R5", "SD2_IN", "SD2")]):
    S.comp(ref, "Device", "R", "33R", (455 + i * 26, 78), {"1": a, "2": b},
           footprint=FP_R)

for i, t in enumerate([
        "R1-R5: series damping at the receiver.",
        "0R is acceptable - a ~30 cm run at 3.072 MHz",
        "does not need it. Fitted as cheap insurance."]):
    S.text(t, (450, 124 + i * 6))

# EN: the 4k7 pull-down is the safety interlock.
S.comp("R6", "Device", "R", "4k7", (615, 78), {"1": "EN_IN", "2": "GND"},
       footprint=FP_R)
S.comp("R7", "Device", "R", "10k", (650, 78), {"1": "EN_IN", "2": "XSMT"},
       footprint=FP_R)
S.comp("C5", "Device", "C", "100nF", (685, 78), {"1": "XSMT", "2": "GND"},
       footprint=FP_C)
# Escape hatch, NOT FITTED.  Some USB3 cables bond contact 7 (GND_DRAIN) to the
# shield.  If that turns out to be true of the cable in use, EN can never go
# high: remove R7, fit R8, and the DACs are permanently un-muted.  The interlock
# is lost, the board works.  One DNP part instead of a respin.
S.comp("R8", "Device", "R", "10k DNP", (720, 78), {"1": "+3V3", "2": "XSMT"},
       footprint=FP_R, dnp=True)

for i, t in enumerate([
        "R6 (4k7 pull-down) is the MUTE INTERLOCK and the",
        "reason this is safe to leave plugged in. The FPGA's",
        "internal weak pull-up (~25k) cannot overcome it, so",
        "any core not driving EN push-pull leaves the DACs",
        "muted. Plugged into a real USB3 port, contact 7 is",
        "ground - also muted. R7/C5 de-glitch the level.",
        "",
        "R8 is NOT FITTED: see the note next to it before",
        "assuming contact 7 reaches this board as a signal."]):
    S.text(t, (600, 124 + i * 6))

# ==================================================================== DACs
DACS = [
    ("U1", "SD0", "FL", "FR", "J2", "Front L / R      (green jack)"),
    ("U2", "SD1", "FC", "LFE", "J3", "Centre / LFE     (orange jack)"),
    ("U3", "SD2", "SL", "SR", "J4", "Surround L / R   (black jack)"),
]

for n, (ref, din, outl, outr, jack, caption) in enumerate(DACS):
    y = 250 + n * 125
    S.comp(ref, "Audio", "PCM5102A", "PCM5102A", (85, y), {
        "1": "+3V3",           # CPVDD
        "2": f"CAPP{n+1}",
        "3": "GND",            # CPGND
        "4": f"CAPM{n+1}",
        "5": f"VNEG{n+1}",
        "6": f"{outl}_D",      # OUTL
        "7": f"{outr}_D",      # OUTR
        "8": "+3V3",           # AVDD
        "9": "GND",            # AGND
        "10": "GND",           # DEMP = de-emphasis off
        "11": "GND",           # FLT  = normal latency filter
        "12": "GND",           # SCK  = 0 -> derive clock from BCK, no MCLK
        "13": "BCLK",
        "14": din,
        "15": "LRCK",
        "16": "GND",           # FMT  = I2S (not left-justified)
        "17": "XSMT",          # soft mute, active low
        "18": f"LDOO{n+1}",
        "19": "GND",           # DGND
        "20": "+3V3",          # DVDD
    }, footprint=FP_DAC, ref_off=(-4, -26), val_off=(-4, 26))

    S.text(f"{ref}   {caption}", (52, y - 34), size=2.2)

    for i, (pref, val, a, b, fp) in enumerate([
            (f"C{n+1}1", "100nF", "+3V3", "GND", FP_C),
            (f"C{n+1}2", "100nF", "+3V3", "GND", FP_C),
            (f"C{n+1}3", "100nF", "+3V3", "GND", FP_C),
            (f"C{n+1}4", "2.2uF", f"CAPP{n+1}", f"CAPM{n+1}", FP_CB),
            (f"C{n+1}5", "2.2uF", f"VNEG{n+1}", "GND", FP_CB),
            (f"C{n+1}6", "1uF", f"LDOO{n+1}", "GND", FP_CB)]):
        S.comp(pref, "Device", "C", val, (158 + i * 27, y - 16),
               {"1": a, "2": b}, footprint=fp)

    S.comp(f"R{n+1}1", "Device", "R", "100R", (340, y + 36),
           {"1": f"{outl}_D", "2": outl}, footprint=FP_R)
    S.comp(f"C{n+1}7", "Device", "C", "1nF", (368, y + 36),
           {"1": outl, "2": "GND"}, footprint=FP_C)
    S.comp(f"R{n+1}2", "Device", "R", "100R", (405, y + 36),
           {"1": f"{outr}_D", "2": outr}, footprint=FP_R)
    S.comp(f"C{n+1}8", "Device", "C", "1nF", (433, y + 36),
           {"1": outr, "2": "GND"}, footprint=FP_C)

    S.comp(jack, "Connector_Audio", "AudioJack3", "3.5mm TRS", (530, y),
           {"T": outl, "R": outr, "S": "GND"}, footprint=FP_JACK,
           ref_off=(0, -16), val_off=(0, 16))

for i, t in enumerate([
        "PCM5102A output is GROUND-CENTRED - the internal charge pump",
        "(C_4 flying cap across CAPP/CAPM, C_5 on VNEG) generates the",
        "negative rail - so NO DC-blocking capacitors are needed or",
        "wanted. The output R/C is RF rejection and short-circuit",
        "protection only, not a reconstruction filter."]):
    S.text(t, (55, 548 + i * 6))

for i, t in enumerate([
        "SCK tied to GND selects BCK-PLL mode, so no MCLK wire is",
        "needed and the user port has a contact to spare for EN.",
        "Channel order is the PC analog convention, so a stock",
        "3x3.5mm-to-6xRCA cable maps straight through. An HDMI sink",
        "wants LFE/C in the other order - remapped in the transmitter."]):
    S.text(t, (430, 548 + i * 6))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "analog-5p1", "analog-5p1")
write_project(os.path.normpath(out), S)
print(f"wrote {os.path.normpath(out)}.kicad_sch")
print(f"  components: {len(S.instances)}   nets: {len(S.nets)}")
