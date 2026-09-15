# The MiSTer user port, as these dongles use it

Both dongles hang off the **user port** on the MiSTer IO board — the blue USB-3-shaped
connector that is not USB at all, just seven FPGA pins plus power. This core does not use
it for anything (`dvd/emu.sv`: `assign USER_OUT = 7'b0;`), so it is free.

---

## ⚠ Verify this before you order anything

The contact assignment below comes from a [first-hand wiring
write-up](https://8bitshardway.blogspot.com/2021/07/mister-fpga-user-serial-connector-to.html)
of the C64 IEC adapter, not from an IO board schematic I have read. It is the single fact
that can destroy hardware if it is wrong, and **it costs ten minutes to confirm**.

| Contact | Believed function | Consequence if wrong |
|---|---|---|
| 1 | **+5 V** | feeds the regulator — a signal pin here does nothing bad, a ground does |
| 4 | **GND** | reference for everything |
| 9 | **+3.3 V** | *left unconnected on both dongles on purpose* |
| 2, 3, 5, 6, 7, 8 | FPGA signals | interchangeable — see below |

**Confirm contacts 1, 4 and 9 with a multimeter before plugging a dongle in.** Power the
MiSTer with nothing in the user port and measure each contact against chassis ground. You
are looking for 5 V on 1, 0 V on 4, 3.3 V on 9, and roughly 3.3 V (the FPGA's weak
pull-ups) on the rest.

The dongles deliberately do **not** load contact 9. If your board turns out to put a
signal there, nothing is damaged.

---

## Why the signal contacts do not need identifying

Which `USER_IO[n]` index lands on which contact is a property of the IO board, and I could
not find a schematic that states it. That would normally be a blocker.

It isn't, because **the assignment is ours to choose.** `mc_i2s_out` drives
`USER_IO[6:0]` and the RTL decides which index carries BCLK, which carries LRCLK, and so
on. So the dongle fixes the *contacts* and the core is told to match. Only the power
contacts are outside our control.

To find the mapping once the board exists, have the core drive a distinct slow square wave
on each index — index *n* at roughly *n+1* Hz — and read each contact with a multimeter on
its frequency range. No scope needed.

---

## The six signals

| Contact | Net | Direction | Notes |
|---|---|---|---|
| 2 | `BCLK` | MiSTer → dongle | 3.072 MHz (64·Fs at 48 kHz) |
| 3 | `LRCK` | MiSTer → dongle | 48 kHz frame clock, low = left |
| 5 | `SD0` | MiSTer → dongle | front L/R |
| 6 | `SD1` | MiSTer → dongle | centre + LFE |
| 8 | `SD2` | MiSTer → dongle | surround L/R |
| 7 | `EN` | MiSTer → dongle | high = this core is driving audio |

Exactly six, which is exactly what is available. That is why neither dongle uses MCLK —
the PCM5102A's BCK-PLL mode and the IT66121's internal MCLK generation both make it
unnecessary, freeing the sixth contact for `EN`.

### `EN` is a safety interlock, not a convenience

The user port is shared with every other core. Without `EN`, loading a SNAC-using core
would push arbitrary logic into a DAC and out to an amplifier.

`EN` has a **4.7 kΩ pull-down on the dongle**. The FPGA's internal weak pull-up is ~25 kΩ
(`sys/sys.tcl`: `WEAK_PULL_UP_RESISTOR ON -to USER_IO[*]`), so a tri-stated pin sits at
about 0.5 V — comfortably low. Only a core *actively driving the pin push-pull* can raise
it. The consequences fall out for free:

- another core running → muted
- MiSTer off or unplugged → muted
- plugged into a **real** USB 3 port by mistake → contact 7 is the ground drain → muted

### ⚠ The one thing that can defeat it

On a real USB 3 cable contact 7 is `GND_DRAIN`, and many cables bond it to the shield. If
you use a cable rather than plugging the dongle straight in, `EN` may be shorted to ground
and the board will be permanently muted.

That is a hard, obvious failure at bring-up rather than a subtle one, and the analog dongle
carries a no-respin escape: **remove R7, fit R8** (10 kΩ, `+3V3` → `XSMT`) and the DACs are
permanently un-muted. You lose the interlock and should then only plug the dongle in when
you intend to use it.

---

## Electrical: the port must be driven push-pull

`sys/sys_top.v:1706-1712` drives `USER_IO` **open-drain** — `!x ? 1'b0 : 1'bZ` — with only
the FPGA's internal weak pull-up to raise the line. At 3.072 MHz that does not work: ~25 kΩ
into cable and input capacitance is a rise time on the order of hundreds of nanoseconds
against a 163 ns half-period.

The RTL change (`USER_OE`, see `docs/multichannel_user_port.md` when it is written) drives
the five signal lines push-pull while the multichannel mode is on, and leaves them
bit-for-bit stock otherwise. **A dongle plugged into an unmodified core will not work**,
and that is the correct behaviour rather than a bug.

---

## Cable and connector

A standard USB 3.0 A-to-B cable is **pin-number straight through**: the A plug's SSTX pair
lands on the B receptacle's SSRX pair, so the *names* differ but contact *n* reaches
contact *n*. That makes a Type-B receptacle on the dongle a legitimate alternative to a
board-mounted Type-A plug, and a much easier part to assemble — at the cost of the
`GND_DRAIN` risk above.

The shipped design uses a Type-A plug (the SNAC form factor: the dongle plugs straight in,
no cable, no drain bonding). Swap the footprint if sourcing pushes you the other way; the
netlist does not change.
