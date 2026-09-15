# HDMI audio dongle — design specification

**Status: specification, not a drawn schematic.** Read "Why there is no `.kicad_sch` here"
before commissioning anything.

User port → this dongle → one HDMI cable to a receiver or soundbar, carrying **6–8 channel
LPCM**. The MiSTer's own HDMI output goes to the display as usual. No DAC, no soldering to
the DE10-Nano, and the receiver does all decoding, bass management and speaker distances.

---

## Why there is no `.kicad_sch` here

The analog dongle in `../analog-5p1/` is a complete, ERC-clean, netlist-gated schematic
because every part in it exists in KiCad's stock symbol libraries, so **every pin number
was read from a library rather than transcribed by me**.

There is no HDMI transmitter symbol in those libraries — no IT66121, no ADV7513, no
LT8618. Drawing a 100-pin part from memory and handing it to an assembly house is exactly
the failure this project's notes call *confidently wrong data instead of none*: the error
would be invisible until bring-up and would cost a full respin plus assembly.

So this file specifies the design completely — architecture, signal list, power tree, GPIO
allocation, firmware behaviour — and the transmitter sheet is to be drawn **from the
IT66121 datasheet and ITE's reference schematic** by whoever lays the board out. That is
normal practice for a part with a vendor reference design, and it is the honest split.

---

## The constraint that shapes everything

**There is no audio-only HDMI.** A source must transmit TMDS video periods for a sink to
lock; audio lives in the *data islands between them*. So the dongle has to generate a
raster whether or not anybody looks at it.

The saving grace: for a **black** raster all 24 RGB inputs tie to ground, so the timing
source only has to produce **PCLK, DE, HSYNC, VSYNC** — four signals from a small MCU
rather than a 24-bit bus from anywhere.

---

## Architecture

```
   MiSTer user port (USB3-A)
     |
     +-- BCLK, LRCK, SD0, SD1, SD2 -----------------> IT66121  I2S0..I2S2
     |                                                   |
     +-- LRCK ------------------> RP2040 GPIO            |  (rate detect)
     +-- EN --------------------> RP2040 GPIO            |  (audio enable)
     +-- +5V, GND                      |                 |
                                       |  PCLK/DE/HS/VS  |
                                       +---------------->|
                                       |  I2C (SCL/SDA)  |
                                       +<--------------->|
                                       |  RESET, INT     |
                                       +---------------->|
                                                         |
                                            RGB[23:0] = GND (black)
                                                         |
                                                    HDMI Type-A out
```

The audio path never touches the MCU. Five wires go straight from the user port to the
transmitter's I2S inputs; the RP2040 only makes a raster and configures registers.

### Why IT66121

Confirmed from the [ITE datasheet](https://www.ite.com.tw/en/product/cate1/IT66121): four
I2S inputs carrying **8 channels of uncompressed LPCM up to 192 kHz**, 16–24 bit, and —
usefully — *"MCLK input is optional… By default IT66121 generates the MCLK internally"*.
That is what frees the sixth user-port contact for `EN`.

---

## Signals from the user port

Identical to the analog dongle — see `../user-port.md`, including the `EN` interlock and
the push-pull requirement. Contacts 2, 3, 5, 6, 8 are the I2S; contact 7 is `EN`.

`LRCK` additionally goes to an RP2040 GPIO so firmware can measure the frame rate and
program the audio clock regeneration for 48 kHz vs 96 kHz rather than assuming.

---

## Power tree

| Rail | From | Feeds |
|---|---|---|
| +5 V | user port contact 1 | input only |
| +3.3 V | LDO from +5 V | RP2040 IOVDD, IT66121 I/O, HDMI DDC pull-ups |
| +1.8 V | LDO from +3.3 V | IT66121 core — **check the datasheet for the actual core rail** |
| +1.1 V | RP2040 internal regulator | RP2040 core (decoupling only) |

⚠ HDMI pin 18 (+5 V) is **supplied by the source**, and the dongle is the source. It must
provide it, current-limited, and cannot draw power from the receiver. Budget the dongle's
own consumption against what the user port can deliver — an unknown worth measuring.

---

## RP2040 GPIO allocation

| Function | Count | Notes |
|---|---|---|
| PCLK, DE, HSYNC, VSYNC | 4 | one PIO state machine drives all four |
| SCL, SDA | 2 | I2C to the transmitter; also its DDC master for EDID |
| TX_RESET | 1 | |
| TX_INT | 1 | hot-plug / receiver events |
| LRCK sense | 1 | sample-rate detection |
| EN sense | 1 | from user port contact 7 |

Plus the standard RP2040 support circuit: 12 MHz crystal, QSPI flash, USB micro-B or
Type-C for firmware loading (BOOTSEL), RUN pull-up, SWD pads.

---

## Firmware specification

1. **Boot** — hold TX_RESET, bring up rails, release, wait for the transmitter's ID.
2. **Raster** — start the PIO timing generator. 640×480 is ample. It does **not** need to
   be exactly 25.175 MHz: nothing looks at this picture, and a 25.0 MHz pixel clock
   (system 100 MHz ÷ 4) giving ~59.5 Hz is fine. Audio and video clocks being asynchronous
   is ordinary HDMI, handled by measured CTS in the audio clock regeneration.
3. **EDID** — read the sink's Short Audio Descriptors through the transmitter's DDC
   master. Engage multichannel only if the sink advertises 6- or 8-channel LPCM; otherwise
   fall back to 2 channels. This mirrors the refuse-unless-advertised discipline the
   existing bitstream path uses.
4. **Audio** — on `EN` high, measure LRCK, program N/CTS and the channel-status block,
   set channel count and speaker allocation, unmute. On `EN` low, mute.
5. **Hot plug** — on TX_INT, re-read EDID and re-apply.

### ⚠ Channel order differs from the analog dongle

HDMI's standard 5.1 channel allocation orders the second subpacket **LFE then FC**; the
analog convention pairs **C then LFE**. The wire order is fixed by the analog dongle (see
`../analog-5p1/`), so **the transmitter's channel-mapping registers do the swap**. One
core-side implementation serves both dongles; do not "fix" this in the RTL.

---

## Rough BOM

| Item | Note |
|---|---|
| IT66121FN | 100-pin LQFP. The reason this sheet is not drawn here. |
| RP2040 | QFN-56. KiCad symbol exists (`MCU_RaspberryPi:RP2040`). |
| W25Q16 / W25Q128 QSPI flash | |
| 12 MHz crystal + load caps | |
| 3.3 V LDO, 1.8 V LDO | |
| HDMI Type-A receptacle | plus a TMDS-rated ESD array |
| USB 3.0 Standard-A plug | user port side |
| USB micro-B / Type-C | firmware loading only |
| Passives | decoupling, DDC pull-ups, TMDS termination per datasheet |

Expect roughly £30–50 in parts at low volume, dominated by the transmitter — against about
£10 for the analog dongle.

---

## Open questions to close before layout

1. **IT66121 core rail voltage and full pinout** — datasheet. Everything else here is
   independent of the answer.
2. **Does the user port supply enough current** for RP2040 + IT66121 + the HDMI +5 V
   obligation? Measure before assuming.
3. **Will a receiver accept a source whose video is a black 640×480 raster** while its
   audio is what matters? Expected yes — it is valid video — but this is the assumption
   with the least evidence behind it, and it is worth proving on a dev board with an
   IT66121 module before committing to a PCB.
4. **The EDID split.** The receiver's EDID is visible only to this dongle, not to the
   core, so the core cannot know what the audio sink supports. Decide whether firmware
   reports it back over the user port or simply always sends 6 channels.

Question 3 is the one that would invalidate the whole approach, and it is testable for the
price of a breakout board.
