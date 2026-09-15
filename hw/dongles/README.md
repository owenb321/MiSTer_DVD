# Multichannel audio dongles for the MiSTer user port

Hardware to get 5.1 out of the DVD core. Both dongles hang off the MiSTer IO board's
**user port**, which this core does not otherwise use, and both take the same six signals
— so **one core-side implementation serves both** and the choice of dongle can be deferred.

| | What you get | Hardware | Install | Status |
|---|---|---|---|---|
| [`analog-5p1/`](analog-5p1/) | 6 analog channels on 3× 3.5 mm | ~£10 | plug in | **schematic done, gated** |
| [`hdmi-audio/`](hdmi-audio/) | 6–8 ch LPCM over one HDMI cable | ~£40 | plug in | **specification only** |

Start with [`user-port.md`](user-port.md) — it carries the one fact that can damage
hardware, and the ten-minute measurement that confirms it.

---

## Why this exists

The DVD core already decodes AC-3 5.1 in full and throws four channels away at the last
step (`dvd/ac3/imdct_512.sv` holds a real 6-channel `pcm_mem`; `S_DMX` folds it to stereo
in place). Getting 5.1 out is an **output-plumbing problem, not a decoder problem**.

It cannot go over the MiSTer's own HDMI. The DE10-Nano routes one I2S data pin to the
ADV7513, and the ADV7511/7513 programming guide §4.4.1.1 is explicit that each of I2S0–I2S3
carries exactly one channel pair, with no TDM mode. Six channels need three data lines,
and the user port is where three spare lines exist.

The full design record, including the core-side RTL work these dongles depend on, is in the
plan this came from — see `docs/multichannel_user_port.md` once that lands.

---

## ⚠ Neither dongle works with today's core

Two things are missing on the FPGA side and neither is built yet:

1. **`mc_i2s_out`** — the three-line I2S serializer.
2. **`USER_OE`** — `sys/sys_top.v` currently drives `USER_IO` open-drain, which cannot
   switch at 3.072 MHz against the FPGA's ~25 kΩ internal pull-up. The lines must be driven
   push-pull while the mode is on, and left bit-for-bit stock otherwise.

Build the boards only if you are prepared to do that RTL work too — or build one and keep
it on the shelf until it lands.

---

## How this is generated

Nothing here is hand-drawn. `tools/gen_analog.py` is simultaneously the schematic *and* the
netlist: every pin gets a wire stub and a net label, so a mis-drawn wire cannot silently
create or break a connection. Pin coordinates are read from the installed KiCad symbol
libraries rather than transcribed.

```bash
./build.sh          # regenerate, ERC, netlist gate, BOM, PDF
./build.sh --red    # also prove the gate can fail
```

`tools/check_analog.py` asserts the **exported** netlist — the artefact a fab consumes —
and is written from the opposite direction to the generator ("what must each net contain"
vs "what should each pin connect to"), so a typo in one does not reproduce itself in the
other. `--red` swaps centre and LFE and confirms the gate rejects it; a gate that cannot
fail is not a gate.

That discipline has already paid for itself once. `PCM5102A` is a *derived* KiCad symbol,
and the first generated schematic embedded it with an unresolved `extends` — KiCad gave the
part **no pins at all** and cheerfully exported a netlist in which all three DACs were
simply absent, with no error anywhere. Only asserting the netlist caught it.

Requires `kicad-cli` (KiCad 10) and `python3`.
