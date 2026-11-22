# IEC 61937 bitstream over HDMI

**Status: ✅ HW-CONFIRMED 2026-08-31** — DD and DTS both decode on a real receiver
over HDMI, with no Digital I/O board, via **route (i)** (§ below). Default build,
no ini needed. The startup / track-change lock flap it used to inherit is
**✅ FIXED + HW-CONFIRMED 2026-08-31** (both outputs) — root cause was the ring
drain watchdog, not this feature: `docs/iec61937.md` "FLAP ROOT CAUSE".

Design below; the S/PDIF half this builds on is `docs/iec61937.md`.

`Audio Out = Passthru` wraps undecoded AC-3/DTS in IEC 61937. Until now that
only ever left over optical S/PDIF, so 5.1 required the Digital I/O board and
`docs/iec61937.md` recorded "inaudible on a plain HDMI TV" as a hard boundary.
It isn't one. The same burst now also goes out HDMI, and an AV receiver decodes
DD/DTS 5.1 with no add-on board.

---

## 1. Why this fits on one wire

The DE10-Nano routes exactly **one** I2S data line to the ADV7513 — `HDMI_I2S`
(PIN_T13), plus MCLK/SCLK/LRCLK. Confirmed in the board's own pin table; there
is no FPGA connection to the chip's other I2S inputs or its S/PDIF pin.

That kills multichannel LPCM permanently (6 ch would need three more wires — a
board mod, see §7) but it does **not** limit compressed audio, because IEC 61937
rides *inside* an ordinary 2-channel / 48 kHz / 16-bit IEC 60958 stream:

```
48000 samples/s x 2 ch x 16 bit = 1.536 Mbit/s = AC-3's maximum rate
```

That equality is not a coincidence — it is what 61937 was designed around. So
the payload needs no new formatting at all; only the link layer changes.

---

## 2. Route decision: IEC958-direct, not an I2C channel-status bit

> ⛔ **THIS SECTION DESCRIBES A ROUTE THAT WAS REMOVED (corrected 2026-09-09).**
> IEC958-direct was built, sim-correct, and **never produced a decodable stream across
> four hardware rounds** (`dvd/hdmi_bs_i2s.sv:14-19`). The shipping path is route **(i)**:
> plain 16-bit standard I2S with the channel status from the register map — `0x0C` =
> `0x44` (bitstream) / `0x04` (PCM) and the non-PCM bit in `0x12[7]` = `0xA0` / `0x20`.
> The register table later in this file still lists the removed route's values
> (`0x0C` = `0x07`, no `0x12` row, `0x73` inverted); the authority is
> `hdmi_config_set_audio()` in `main/integration/apply_integration.py`.
> **Consequence, and it is load-bearing for any future work here:** the non-PCM flag over
> HDMI is a STATIC per-session I2C setting written by Main, *not* the per-block wire bit
> `spdif_pass` carries on optical. `dvd/emu.sv` leaves `bs_nonpcm_o` unconnected.
> §6's testbench list also names `i2s_iec958_tb`, which was deleted with the route.


There were two ways to tell the ADV7513 "this is not PCM".

**(i) Keep I2S Standard, set channel status from I2C registers** (`0x0C[6]=1`
plus a non-PCM bit somewhere in `0x12`/`0x13`).

**(ii) IEC958-direct** (`0x0C[1:0] = 3`) — feed the chip complete IEC 60958
subframes and let the channel status travel inside them.

**Route (ii) was chosen**, on two grounds.

The mainline Linux `adv7511` driver reaches for exactly this mode, and only this
mode, for IEC958 subframe data:

```c
i2s_format = ADV7511_I2S_FORMAT_I2S;
if (fmt->bit_fmt == SNDRV_PCM_FORMAT_IEC958_SUBFRAME_LE)
        i2s_format = ADV7511_I2S_IEC958_DIRECT;   /* 0x0C[1:0] = 3 */
```

It never writes a non-PCM channel-status register anywhere. (It *does* set
`0x12` bit 5 for "not copyrighted", which proves `0x12` carries channel-status
fields — but that bit doesn't line up with IEC 60958 byte 0 bit 2, so the
mapping isn't derivable from the driver and route (i)'s key register stayed
unconfirmed. analog.com blocked every attempt at the Programming Guide.)

★ **The stronger reason is that route (ii) keeps the non-PCM flag DYNAMIC.**
On S/PDIF, `spdif_pass` latches it per 192-frame block, which is the fj#110
ROUND 2 fix: receivers could not acquire across non-PCM null bursts, so holds
present real linear-PCM silence and there is exactly one clean PCM→non-PCM
switch when the burst starts. An I2C channel-status register can only pin the
flag high for a whole session, putting us straight back in the regime that fix
exists to avoid. Route (ii) inherits the proven behaviour instead of
re-litigating it.

---

## 3. Data flow

```
audio_ring ──▶ iec61937_wrap (clk_sys)          producer: Pa,Pb,Pc,Pd,payload,pad
                    │  33-bit {nonpcm,R,L} pairs
                    ▼  async FIFO
               cur_pair (clk_audio, held one 48 kHz frame)
                    │
              spdif_pass ── subframe assembly + channel status
                    ├──────────────▶ biphase encoder ──▶ SPDIF_PASS  (optical)
                    └── sub_w_o/sub_load_o ──▶ i2s_iec958 ──▶ HDMI_BS_SCK/WS/SD
```

**One subframe source, two link layers.** `spdif_pass` exports the very subframe
it is about to biphase-encode, so the outputs cannot drift apart — there is
nothing to keep in sync. Exporting rather than duplicating also matters because
the channel-status table it feeds is HW-proven; a second copy would drift from
it over time.

Two details the export had to get right:

- **Parity and the preamble code are filled in for the parallel consumer.** The
  biphase stage derives both serially as it emits, which is far too late for
  someone taking the word in parallel.
- **`sub_load_o` is delayed one cycle.** `preamble_r` already describes the
  subframe about to start while `audio_sample_q` still holds the previous one —
  they are valid on *opposite* sides of the load edge, so the strobe is placed
  where both have settled.

### Pacing: why there is no handshake

Three counters, all exact integer dividers of the same 24.576 MHz clock:

| | period |
|---|---|
| `spdif_pass` pair request | 512 clk (64 bit-CE x 2 subframes) |
| `audio_out` `sample_ce` | 512 clk |
| I2S frame (either serializer) | 512 clk |

A fixed offset, established at reset, that **never drifts** — so it is exactly
one frame per pair, forever. There is nothing to hand-shake with; both sides are
free-running dividers of one crystal. (Same same-crystal reasoning that retired
the NCO trim.)

⚠ **The one real hazard is a PHASE STEP, and it is measured, not theoretical.**
`bench/dvd/iec61937_wrap_tb.sv` TEST 9 found the first interval after an
audio-domain reset is **509 clk, not 512**: `bit_ce` is `(ce_cnt==0)` of a
free-running 2-bit counter that reset clears, while `spdif_pass`'s subframe
counter restarts from its own reset state, so the two re-align three cycles in.
`rst_audio_n` pulses on **every audio-track switch and `aud_flush`**, so this is
recurring, not a power-on curiosity. Hence the ~100 ms hold-off in `dvd/emu.sv`:
across a re-phase the HDMI leg mutes, so a receiver sees clean silence and one
switch rather than a torn subframe. Since 2026-09-23 the same `bs_hold` also gates
the optical S/PDIF leg (`SPDIF_PASS_EN`), which had carried the torn burst — see
`docs/iec61937.md` finding 3.

The framework's own `areset` is the mirror image — it is pulsed by **every OSD
volume keypress** (`audio.cpp` `setFilter()` → `sys_top.v:359-369`), restarting
`audio_out`. Note also that the OSD volume slider has **no effect** on a
bitstream: attenuation lives in `aud_mix_top`, which this path bypasses
entirely. That is correct player behaviour, not a bug.

### Note on the SV-function silent-silicon trap

`docs/ac3_decoder.md` records (2026-08-31) that `function automatic` helpers in the
AC-3 decoder simulated perfectly and produced **silent hardware** under Quartus 17,
with no warning. Worth stating plainly for this path: **the HDMI leg adds no
functions.** `dvd/i2s_iec958.sv` is one always block; the `spdif_pass` export is
wires. The two functions in `iec61937_wrap.sv` (`mkword`, `bin2gray`) are
pre-existing and sit on the HW-CONFIRMED S/PDIF path — and since HDMI reuses that
same word stream, a fault in either would already show up on optical. So this
feature carries no new exposure to that trap.

### Serial format

`dvd/i2s_iec958.sv`, 64 bits per frame = two 32-bit subframes, channel A then B.
Bits leave in **timeslot order, LSB first** — the opposite of `sys/i2s.v`'s
MSB-first PCM. `sck` = 64·Fs = 3.072 MHz, `ws` = 48 kHz.

### ★ HW ROUND 1 (2026-08-31): the chip switches, the receiver cannot sync

Receiver reported **PCM + silence** on the first attempt and **"decoder off"**
once bitstream mode actually engaged. That progression is the useful part:

- "PCM + silence" was the **designed safe fallback** — the ack had not engaged,
  so `pass_mode` muted `AUDIO_L/R` and `HDMI_BS_EN` stayed low. Nothing made
  noise, which is the gate working.
- "decoder off" means the ADV7513 **did** switch to IEC958-direct (it stopped
  calling the stream PCM) but the receiver could not find IEC 61937 sync
  (Pa=`F872`, Pb=`4E1F`) inside our subframes.

So Main, the EDID path, the ack and the register write are all **confirmed
working end to end**. What remains is purely the subframe content, i.e. exactly
the two things the Programming Guide would have settled and that had to be
assumed (§ below).

⚠ **Diagnostic lesson, worth keeping:** the round-1 popup was invisible.
`InfoMessage` no-ops unless the menu FSM is idle, and Audio Out is toggled from
*inside* the OSD, so a single call at the transition is always dropped —
`dvd_css` had hit the identical trap. The state is now also written to
`/tmp/dvd_hdmi_audio.log`, which does not care about menu state:
`state: passthru=N sink_ok=N declared=N ini_mode=N acked=N`.

### ★★ THE FORMAT, from the Programming Guide §4.4.1.1 (obtained 2026-08-31)

Three HW rounds were spent guessing at this. The document settles it in one
paragraph:

> "In the direct AES3 stream I2S format, the user can send an IEC60958 sub-frame
> ... with the **Preamble left out** ... Notice that the **parity bit is replaced
> by the block start flag**. The parity bit will be calculated automatically. The
> information contained in "C" of I2S0 is used in the HDMI audio sample packet."

So the AES3-direct subframe is the IEC 60958 subframe with **both ends changed**:

| slots | content |
|---|---|
| `[3:0]` | preamble **left out** → zero (the chip regenerates preambles) |
| `[27:4]` | audio + aux, unchanged |
| `[28] [29] [30]` | V, U, C — unchanged |
| `[31]` | **BLOCK START flag**, *not* parity (parity is computed by the chip) |

**The missing block-start flag was the bug.** Without it the chip can never find
the head of a 192-frame channel-status block, so it cannot assemble the status
the sink needs. That is exactly what HW round 3 showed: a *stable* non-PCM
indication (proving V/U/C were already in the right slots) with no 61937 lock —
and it is why zeroing the preamble alone made the receiver FLAP between PCM and
"decoder off", since block start then landed wherever the old parity bit
happened to be 1.

⚠ **Word select must come from `spdif_pass`, not from the word.** With no
preamble the subframe no longer identifies its own channel. Deriving `ws` from
the preamble code — which worked while a code was present — left `ws` stuck at 0
once it was correctly zeroed: no word select at all, a total and silent failure.
`sub_chb_o` now carries it explicitly.

⚠ **Channel Count `0x73[2:0]` must be 1, not 0.** §4.4.1.1: "If I2S0 only is
needed, setting the Channel Count register (0x73[2:0]) and I2S enable (0x0C[2])
to 1 will select this." CC also drives the Audio Sample Packet layout bit and
`sample_present.spX` (Figure 23), so 0 mis-frames the packet. A 61937 burst is a
two-channel carrier, so stereo is correct for bitstream as well.

**Correction to an earlier reading of Table 11.** Its Output Format column lists
"AES3 Direct" for this mode and "IEC61937" only for the SPDIF pin and HBR, which
looked like a statement that I2S AES3-direct *cannot* carry 61937. It is not —
that column describes the input encoding. §4.4.1.1 is explicit that C from I2S0
reaches the HDMI audio sample packet, which is the whole mechanism. (The SPDIF
input really is unreachable, though: it is **pin 3**, physically separate from
I2S0 on pin 5, and the DE10-Nano routes only I2S0/MCLK/SCLK/LRCLK.)

### ★ HW ROUND 4: block-start did not fix it — and route (i) exists

The documented format still gives "decoder off" (now flapping to PCM), silent,
with Main provably correct in the log. AES3-direct has cost four rounds.

**Route (i) is now fully specified**, which is exactly what was missing when it
was abandoned at Step 0:

| what | where |
|---|---|
| non-PCM flag ("audio sample word", CS bit 1) | **`0x12[7]`** (Table 84) |
| channel-status source | `0x0C[6]` — 1 = from the register map |
| transport | plain 16-bit **standard I2S** carrying the raw 61937 words |

It needs no preamble, no block-start flag and no word-select derivation, and the
serializer is `sys/i2s.v` — the framework's own, already carrying PCM to this
chip daily. The cost is a **static** non-PCM flag rather than per-block.

Select with fabric variant **4 (PCM16)** *and* ini `dvd_hdmi_bs_mode=1`; one
picks the transport, the other the chip config, so they must agree.

### Instrument: what the chip actually detected

`0x42[3]` is read back and logged: SCLK periods per LRCLK period, 0 = 32-bit
mode, 1 = **64-bit** mode. AES3-direct carries 32 bits per channel and therefore
*requires* 64-bit mode — if the chip reports 32-bit it is taking half of every
subframe, which would explain the whole saga and which nothing on our side could
have revealed by reasoning.

### The AES3-direct apparatus has been REMOVED (2026-08-31)

Route (ii) was built, documented from the Programming Guide, made sim-correct, and
**never produced a decodable stream across four hardware rounds**. Before release it
was deleted rather than carried: the `HDMI BS Variant` selector, the 32-bit AES3
serializer, and `spdif_pass`'s `sub_w_o`/`sub_chb_o` subframe export are all gone,
which returns the HW-proven biphase encoder to its single documented change.

Everything needed to rebuild it is above — the frame format (preamble omitted,
block-start flag replacing parity), the word-select trap, the register set, and
what the receiver reported at each stage. The finding is the durable part; the
apparatus was not worth the area or the "which mode am I in" ambiguity.

`dvd/hdmi_bs_i2s.sv` is what remains: a ce divider and an instance of the
framework's own `sys/i2s.v`.

### Serial format

`dvd/i2s_iec958.sv`, 64 bits per frame = two 32-bit subframes, channel A then B.
Bits leave in **timeslot order, LSB first** — the opposite of `sys/i2s.v`'s
MSB-first PCM. `sck` = 64·Fs = 3.072 MHz, `ws` = 48 kHz.

### ★ HW ROUND 1 (2026-08-31): the chip switches, the receiver cannot sync

Receiver reported **PCM + silence** on the first attempt and **"decoder off"**
once bitstream mode actually engaged. That progression is the useful part:

- "PCM + silence" was the **designed safe fallback** — the ack had not engaged,
  so `pass_mode` muted `AUDIO_L/R` and `HDMI_BS_EN` stayed low. Nothing made
  noise, which is the gate working.
- "decoder off" means the ADV7513 **did** switch to IEC958-direct (it stopped
  calling the stream PCM) but the receiver could not find IEC 61937 sync
  (Pa=`F872`, Pb=`4E1F`) inside our subframes.

So Main, the EDID path, the ack and the register write are all **confirmed
working end to end**. What remains is purely the subframe content, i.e. exactly
the two things the Programming Guide would have settled and that had to be
assumed (§ below).

⚠ **Diagnostic lesson, worth keeping:** the round-1 popup was invisible.
`InfoMessage` no-ops unless the menu FSM is idle, and Audio Out is toggled from
*inside* the OSD, so a single call at the transition is always dropped —
`dvd_css` had hit the identical trap. The state is now also written to
`/tmp/dvd_hdmi_audio.log`, which does not care about menu state:
`state: passthru=N sink_ok=N declared=N ini_mode=N acked=N`.

### ★★ THE FORMAT, from the Programming Guide §4.4.1.1 (obtained 2026-08-31)

Three HW rounds were spent guessing at this. The document settles it in one
paragraph:

> "In the direct AES3 stream I2S format, the user can send an IEC60958 sub-frame
> ... with the **Preamble left out** ... Notice that the **parity bit is replaced
> by the block start flag**. The parity bit will be calculated automatically. The
> information contained in "C" of I2S0 is used in the HDMI audio sample packet."

So the AES3-direct subframe is the IEC 60958 subframe with **both ends changed**:

| slots | content |
|---|---|
| `[3:0]` | preamble **left out** → zero (the chip regenerates preambles) |
| `[27:4]` | audio + aux, unchanged |
| `[28] [29] [30]` | V, U, C — unchanged |
| `[31]` | **BLOCK START flag**, *not* parity (parity is computed by the chip) |

**The missing block-start flag was the bug.** Without it the chip can never find
the head of a 192-frame channel-status block, so it cannot assemble the status
the sink needs. That is exactly what HW round 3 showed: a *stable* non-PCM
indication (proving V/U/C were already in the right slots) with no 61937 lock —
and it is why zeroing the preamble alone made the receiver FLAP between PCM and
"decoder off", since block start then landed wherever the old parity bit
happened to be 1.

⚠ **Word select must come from `spdif_pass`, not from the word.** With no
preamble the subframe no longer identifies its own channel. Deriving `ws` from
the preamble code — which worked while a code was present — left `ws` stuck at 0
once it was correctly zeroed: no word select at all, a total and silent failure.
`sub_chb_o` now carries it explicitly.

⚠ **Channel Count `0x73[2:0]` must be 1, not 0.** §4.4.1.1: "If I2S0 only is
needed, setting the Channel Count register (0x73[2:0]) and I2S enable (0x0C[2])
to 1 will select this." CC also drives the Audio Sample Packet layout bit and
`sample_present.spX` (Figure 23), so 0 mis-frames the packet. A 61937 burst is a
two-channel carrier, so stereo is correct for bitstream as well.

**Correction to an earlier reading of Table 11.** Its Output Format column lists
"AES3 Direct" for this mode and "IEC61937" only for the SPDIF pin and HBR, which
looked like a statement that I2S AES3-direct *cannot* carry 61937. It is not —
that column describes the input encoding. §4.4.1.1 is explicit that C from I2S0
reaches the HDMI audio sample packet, which is the whole mechanism. (The SPDIF
input really is unreachable, though: it is **pin 3**, physically separate from
I2S0 on pin 5, and the DE10-Nano routes only I2S0/MCLK/SCLK/LRCLK.)

### ★ HW ROUND 4: block-start did not fix it — and route (i) exists

The documented format still gives "decoder off" (now flapping to PCM), silent,
with Main provably correct in the log. AES3-direct has cost four rounds.

**Route (i) is now fully specified**, which is exactly what was missing when it
was abandoned at Step 0:

| what | where |
|---|---|
| non-PCM flag ("audio sample word", CS bit 1) | **`0x12[7]`** (Table 84) |
| channel-status source | `0x0C[6]` — 1 = from the register map |
| transport | plain 16-bit **standard I2S** carrying the raw 61937 words |

It needs no preamble, no block-start flag and no word-select derivation, and the
serializer is `sys/i2s.v` — the framework's own, already carrying PCM to this
chip daily. The cost is a **static** non-PCM flag rather than per-block.

Select with fabric variant **4 (PCM16)** *and* ini `dvd_hdmi_bs_mode=1`; one
picks the transport, the other the chip config, so they must agree.

### Instrument: what the chip actually detected

`0x42[3]` is read back and logged: SCLK periods per LRCLK period, 0 = 32-bit
mode, 1 = **64-bit** mode. AES3-direct carries 32 bits per channel and therefore
*requires* 64-bit mode — if the chip reports 32-bit it is taking half of every
subframe, which would explain the whole saga and which nothing on our side could
have revealed by reasoning.

### What the runtime A/B was for (selector since REMOVED — see above)

`P1O[47:46] HDMI BS Variant` selected:

| variant | meaning |
|---|---|
| 0 `LSB+blkstart` | the documented format above — **the expected answer** |
| 1 `MSB+blkstart` | MSB-first, insurance against a bit-order misreading |
| 2 `LSB+legacy` | reproduces the pre-document guess (parity in `[31]`, one-hot preamble) |
| 3 `MSB+legacy` | both |

Variant 2 exists so the fix can be A/B'd against the exact thing that failed,
rather than trusting that anything changed.

### Serial format

`dvd/i2s_iec958.sv`, 64 bits per frame = two 32-bit subframes, channel A then B.
Bits leave in **timeslot order, LSB first** — the opposite of `sys/i2s.v`'s
MSB-first PCM. `sck` = 64·Fs = 3.072 MHz, `ws` = 48 kHz.

### ★ HW ROUND 1 (2026-08-31): the chip switches, the receiver cannot sync

Receiver reported **PCM + silence** on the first attempt and **"decoder off"**
once bitstream mode actually engaged. That progression is the useful part:

- "PCM + silence" was the **designed safe fallback** — the ack had not engaged,
  so `pass_mode` muted `AUDIO_L/R` and `HDMI_BS_EN` stayed low. Nothing made
  noise, which is the gate working.
- "decoder off" means the ADV7513 **did** switch to IEC958-direct (it stopped
  calling the stream PCM) but the receiver could not find IEC 61937 sync
  (Pa=`F872`, Pb=`4E1F`) inside our subframes.

So Main, the EDID path, the ack and the register write are all **confirmed
working end to end**. What remains is purely the subframe content, i.e. exactly
the two things the Programming Guide would have settled and that had to be
assumed (§ below).

⚠ **Diagnostic lesson, worth keeping:** the round-1 popup was invisible.
`InfoMessage` no-ops unless the menu FSM is idle, and Audio Out is toggled from
*inside* the OSD, so a single call at the transition is always dropped —
`dvd_css` had hit the identical trap. The state is now also written to
`/tmp/dvd_hdmi_audio.log`, which does not care about menu state:
`state: passthru=N sink_ok=N declared=N ini_mode=N acked=N`.

### The two unknowns, and the runtime A/B (historical — selector REMOVED)

`P1O[47:46] HDMI BS Variant` selected all four combinations from one build,
because each guess would otherwise have cost a 30-minute fit:

| variant | bit order | preamble field |
|---|---|---|
| 0 `LSB+code` | LSB / timeslot first (IEC 60958 on the wire) | one-hot Z=1, Y=2, X=4 |
| 1 `MSB+code` | MSB first (what plain I2S does) | one-hot |
| 2 `LSB+zero` | LSB first | zeroed — chip derives framing from `ws` |
| 3 `MSB+zero` | MSB first | zeroed |

Variant 0 is the original assumption. Sim proves the **mux** in all four (each
channel still carries its own audio, preamble zeroed exactly when asked); which
one the real chip wants is the HW question the selector exists to answer.

---

## 4. Safety: why stock Main cannot make noise

The ADV7513's I2C is HPS-only (`sys/sys_top.v:1095-1105` ties it to a hard
macro), so only Main can put the chip in non-PCM mode. If the core emitted a
bitstream while the sink still expected PCM, the result is **full-scale noise**.
The custom Main is opt-in, so this had to be safe by construction, not by
instruction.

Three independent layers, any one of which suffices:

1. **`cfg[14]` is set only by MiSTer_DVDcss**, and only after it has configured
   the chip *and* confirmed the sink advertises AC-3/DTS. Stock Main never sets
   it — bits 14 and 15 are the only ones it leaves free.
2. `HDMI_BS_EN = pass_mode & hdmi_bs_ack & ~hold`.
3. With `hdmi_bs_en` low, every HDMI audio signal is the stock PCM net through a
   mux with select 0.

★ **INVARIANT — the ack owns the HDMI audio format, not `pass_mode`.** Leaving
Passthru is instant in fabric, but the chip stays non-PCM until Main's next
poll. That window must be digital silence, never PCM. So `hdmi_bs_ack` joins the
`AUDIO_L/R` mute term (`pcm_mute` in `dvd/emu.sv`), and Main sequences the two
directions **asymmetrically**:

- **Engaging:** configure the chip FIRST, then raise the ack.
- **Releasing:** drop the ack FIRST so the core stops emitting, restore the PCM
  registers 50 ms later.

~~Also guarded: `SW[0]`/`mcp_en` route the HDMI audio signals to the analog
board's audio pins, where an I2S DAC would render a bitstream as noise. The mux
falls back to PCM in that case.~~ **Superseded by §9:** that guard made HDMI passthrough
silent on every MCP23009 board. The I2S DAC now reads the PCM serializer directly.

**Old Main + new core** → no ack → today's behaviour exactly.
**New Main + old core** → no `OX6` declaration → Main never reconfigures the chip.

---

## 5. HPS side

`main/support/dvd/dvd_hdmi_audio.cpp`, integration steps 12-21 (see
`main/integration/INTEGRATION.md` — these are the overlay's first edits to
`video.cpp`/`video.h`/`cfg.*`).

- **EDID Short Audio Descriptors.** Stock Main never reads audio capability:
  `edid_parse_cea_ext()` handles CEA tags 0x03/0x07 for VRR and lets tag 0x01
  fall through. Rather than patch that, we re-walk the blocks off the exported
  `video_get_edid()` buffer. The test is deliberately strict — the sink must
  NAME AC-3 (format 2) or DTS (format 7) *and* claim 48 kHz — because the
  permissive failure is the one that makes noise.
- **`hdmi_config_set_audio()`** writes only the audio registers. Reusing
  `hdmi_config_init()` would rewrite ~50 registers plus the CSC and blank the
  picture on every toggle. But that full init *does* revert the audio block
  (boot, and `video_reinit()` on hotplug), so a generation counter notices and
  re-applies, dropping the ack across the gap.
- **`OX6`** marks Audio Out as "also handled by the HPS". The bit still reaches
  the core unchanged; the declaration is how Main learns the build has the HDMI
  path.

Registers written for bitstream / PCM:

Registers written for bitstream / PCM (**the shipping route (i) values**, corrected
2026-09-11 — this table used to list the removed IEC958-direct route and was flagged
as stale in §2's banner; the authority is `hdmi_config_set_audio()` in
`main/integration/apply_integration.py`):

| reg | bitstream | PCM | meaning |
|---|---|---|---|
| `0x0A` | `0x00` | `0x00` | audio select = I2S |
| `0x0C` | `0x44` | `0x04` | I2S0 enable; `[6]` 1 = channel status from the register map; `[1:0]` 0 = standard I2S |
| `0x12` | `0xA0` | `0x20` | channel status byte 0: `[7]` 1 = NOT linear PCM, `[5]` copyright not asserted |
| `0x14` | `0x02` | `0x02` | word length 16 bit |
| `0x15` | rate | rate | sampling rate (follows `hdmi_audio_96k`) |
| `0x73` | `0x01` | `0x01` | Channel Count = 1 (stereo) — Programming Guide §4.4.1.1 |

**N and CTS are unchanged.** 61937 at 48 kHz *is* a 48 kHz stream — which is a
large part of why this feature is small.

MiSTer.ini: `dvd_hdmi_bitstream` — `0` auto (EDID-gated, default), `1` off,
`2` force. Force exists because sinks do mis-report, especially over ARC.

---

## 5a. The non-PCM flag is STICKY (field report, 2026-09-11)

Report: *"enable passthru with the modified main installed, then load another core
— the register is still set and you get no audio."* Confirmed, and worse than it
sounds, because it needed no disc: selecting Passthru was enough.

★★ **§2 PREDICTED THIS AND THE PREDICTION WAS FILED UNDER A ROUTE WE DIDN'T
SHIP.** Its argument for IEC958-direct was that route (i) *"can only pin the flag
high for a whole session, putting us straight back in the regime the fj#110 fix
exists to avoid"*. Route (ii) was then removed after four failed HW rounds and we
shipped (i) — inheriting exactly the property §2 had rejected it for, with the
warning still sitting in the file describing the losing option.

Two mechanisms, and the second is the one that reaches other cores:

1. **`0x12` is written by nobody else.** Stock `hdmi_config_init()` rewrites `0x0C`
   — so the *route* reverts — but its `init_data` has **no `0x12` entry at all**.
   Whatever we last wrote there stands, through a core load and through a warm
   reboot (which resets the HPS, not the transmitter). **A power cut does clear it
   — MEASURED 2026-09-12** (see §6 gate (e)), which was assumed from the chip's
   reset value until someone pulled the plug and checked.
2. **Nothing ran on the way out.** Every other core runs **stock Main** via
   `main=`, and our own re-exec cannot help either: `user_io_init()` hands off to
   the core's `main=` binary at stock `user_io.cpp:~1484`, **before `video_init()`
   at 1514**. So this process never touched the chip again.

⚠ A third thing made it fire with nothing playing: `want` was
`passthru && sink_ok && !pcm_session`, and `pcm_session` reads 0 **both** when
AC-3 is playing and when nothing is. See `dvd/aud_route.sv`.

**The fix is three-layered, because no single layer can cover a crash:**

| layer | covers | mechanism |
|---|---|---|
| PCM is the resting state | idle, menus, LPCM/MP2, ejected, and everything after a crash *unless a DD/DTS track was playing at that instant* | `bs_session` (core) + `content_is_bitstream()` (Main) |
| teardown at both exits | every core load and every reboot | steps 36/37: `dvd_hdmi_audio_teardown()` in `app_restart()` and `reboot()` |
| clear at our own init | an unclean exit, recovered by loading this core again | step 38: `0x12 = 0x20` in `hdmi_config_init()` |

★ **Teardown keys on `chip_nonpcm`, not on `acked`.** They disagree for 50 ms on
every release — ack down, registers not yet restored — and a core load landing in
that window is precisely the case `acked` answers wrongly. That is the one host
mutation (`teardown-keyed-on-ack`) caught by a single arm.

★ Both teardown sites sit immediately after their own function's
`fpga_core_reset(1)`, so the core is silent before the registers move: the §4
ordering invariant, applied to an exit.

⚠ **Residual, by construction:** a Main crash, a kernel panic, or the board's
reset button *while a DD/DTS track is playing* leaves the flag set, and the next
stock-Main boot will not clear it. **Recovery is a power cycle (measured: the
register does not survive one) or loading this core again.** Layer 1 is what makes
that window small instead of "any session in which Passthru was ever selected".

✅ **The accepted trade, now paid:** every title start is one PCM→DD switch, the
fj#110 shape (*"receiver sees PCM then one clean switch, like a real player"*). It
was expected to cost the first moment of audio while the receiver locks; **on a real
receiver it does not clip audibly** (2026-09-12, §6 gate (f)).

---

## 6. Verification

`bench/dvd/run_hdmi_bitstream.sh` (also the first runner `iec61937_wrap_tb` has
ever had — it was run by hand out of `docs/iec61937.md`, which is how a TB
quietly rots).

- **`iec61937_wrap_tb` TEST 9** — tap coherence, and steady-state pacing exact
  over 513 strobes with the post-reset transient bounded to one short interval
  per reset.
- **`i2s_iec958_tb`** — a **demodulator**, not a register peek: recovers
  subframes off `sck`/`ws`/`sd` the way a sink would and checks preamble codes,
  even parity, both channels present, and each channel carrying its own audio.

★ Writing it as a demodulator paid for itself on the first run. All four checks
failed — and the serializer was *correct* (exactly 32 `sck` per load); the
demodulator was free-running a bit counter from reset instead of framing on
`ws`. A register-peek test would have passed and proven nothing. The two things
that fail silently here are bit order and channel mapping, which is exactly why
they have to be read back off the wire.

⚠ **`i2s_iec958_tb` was DELETED with the IEC958-direct route** (§2's banner says so);
the runner no longer builds it. The bullet stays because the *reason* it was written
that way is the reusable part.

The §5a engage policy and teardown are covered off-hardware in two places:

- **`bench/dvd/run_passthru_pcm.sh --red`** — `aud_route_tb` TEST 6 measures
  `bs_session` as a level at boot / AC-3 / a seek / LPCM / eject / Decode mode, with
  four mutations each caught by its own assertion. The seek arm is the load-bearing
  one: it is the only thing separating `bs_session` from `pcm_session`.
- **`main/tests/run_tests.sh --red`** — the Main decision table, including teardown
  inside the 50 ms release window and the version-flag fallback, with four mutations.
  Ordinary host `g++`; no ARM toolchain, no MiSTer, no Docker.

### HW gate — nothing about the ADV7513 is simulable

1. AVR shows "Dolby Digital" / "DTS" and plays 5.1.
2. **Locks at startup without a chapter skip**; survives 5 consecutive
   audio-track switches, a chapter skip and a D-pad seek. (This is the §3
   phase-step / hold-off gate.)
3. Volume keypress mid-bitstream recovers.
4. Picture unaffected across repeated Audio Out toggles.
5. **Negatives — ✅ VERIFIED 2026-09-01.** A sink with no AC-3/DTS in its EDID is
   **silent, never noisy**, in Passthru. On **stock Main** the same `.rbf` is silent
   over HDMI and optical passthrough still works — i.e. the ack gate holds and a
   user who never installs MiSTer_DVDcss is unaffected.
6. **§5a stickiness — ✅ HW-CONFIRMED 2026-09-12, defect reproduced first.** Read the
   flag rather than listening: `i2cget -y 1 0x39 0x12` on the rig (**bus 1**, the
   ADV7513 main map at `0x39`; chip revision reads `0x13` at register `0x00`, which is
   how to find the bus). `0x20` = PCM, `0xA0` = non-PCM.
   ⚠ **The rig's own sink does not advertise AC-3/DTS** (`sink_ok=0` in the log), so
   nothing engages at all until `dvd_hdmi_bitstream=2` is set under `[DVD]` in
   `MiSTer.ini` — **back it up and put it back by hand; `mister.py restore` does not
   touch the ini.**

   | arm | measured |
   |---|---|
   | RED: pre-fix core + Main, DVD core running | `0xA0` |
   | RED: …then load the menu core | **`0xA0`** — the report, reproduced |
   | GREEN: core load with the flag left stuck at `0xA0` | `0x20` — self-heal (step 38) |
   | GREEN: Passthru, nothing routed yet (t+3 s, t+6 s) | `0x20` |
   | GREEN: AC-3 playing (t+9 s onward) | `0xA0` |
   | GREEN: 3 chapter skips + 3 audio-track switches | `0xA0`, **1 write in total** |
   | GREEN: LPCM VOB in Passthru | `0x20` |
   | GREEN: Decode PCM, AC-3 playing | `0x20` |
   | GREEN: load another core while engaged | **`0x20`** + `teardown: restoring PCM mode` |

   ★ **Count `adv7513:` lines in `/tmp/dvd_hdmi_audio.log` for the churn arms, not
   register samples** — the log records every write, so it catches a release/engage
   pair that a 0.5 s sampler would step over. Exactly 1 across six transport events.

   ✅ **(e) the `reboot()` arm and the power-cut question — CONFIRMED BY THE MAINTAINER
   2026-09-12**, both out of the harness's reach: rebooting while a DD track plays
   restores PCM for the next core, and **a power cut does not retain the register** (a
   game core has audio afterwards). ★ The power-cut behaviour had been asserted three
   times in these notes as the chip's reset value *"not something any code here can
   assert"* — it is now measured, and it is the one layer no code can provide, which is
   why the residual below is bounded by it rather than by anything we wrote.
   ✅ **(f) CONFIRMED 2026-09-12 (maintainer, on a real receiver): the PCM→DD switch at
   a title start does not clip audibly.** This rig's sink has no AC-3/DTS decoder, so
   nothing here could hear it — the whole per-track policy rested on the fj#110
   precedent until someone listened.

If (1) fails with the receiver naming nothing or mis-locking, try the §3
preamble table before anything else.

### Bit-exact capture instead of a receiver (`tools/iec61937_check.py`, 2026-11-21)

A receiver says a bitstream plays, and only someone listening can say it. This tool
measures it. Given a PCM capture of the core's HDMI or optical output, it finds the
IEC 61937 bursts (`F872 4E1F`), pulls the AC-3 / DTS frame out of each burst and looks
every frame up among the frames of the same substream read off the disc. That makes
these HW-gate items measurable with no receiver:

| Claim | Capture, then |
|---|---|
| passthrough is the disc's own frames | `--iso <disc> --stream 0x80 --expect bitstream` |
| byte order right (the "static" gotcha) | the report's `byte order normal` (`swapped` = SPDIF Byte Order on Swap) |
| no dropped / repeated frames | `order breaks` 0 over a capture with no seek in it |
| Audio Off silences passthrough (issue #197) | `--expect silent` |
| MiSTer volume never touches a bitstream (issue #196) | `--expect bitstream` passes at any volume |
| teardown back to PCM (LPCM VOB, Decode PCM) | `--expect pcm` |

It needs a capture path that hands back the wire's 16-bit words untouched: integer PCM,
no resampling, no mixer, and the non-audio flag ignored. Two candidates on the rig:

- **HDMI straight into the USB capture card**, with `dvd_hdmi_bitstream=2`, because the
  card's EDID won't list AC-3. ⚠ On rig 236 that means unplugging the RetroTINK, which
  normally feeds the card from the analog output.
- **A bit-transparent USB S/PDIF input** for optical. Many cheap ones mute when the
  non-audio flag is set.

Whether a path is transparent is exactly what the first capture answers: matching frames
= yes; no bursts, or bursts that don't match = no (or the core sent PCM). Capture through
`hw:`, not PipeWire's float mixer: a float capture is refused because it cannot be
bit-exact.

**Validated:**
- `--selftest` covers 19 synthetic cases, one per verdict, each failing exactly its own
  case: a flipped bit, byte swap, wrong track, dropped frame, bursts where PCM or silence
  was expected, and the reverse. It runs in `run_hdmi_bitstream.sh`.
- Against an independent encoder (ffmpeg's `-f spdif` muxer) on real frames: the AC-3
  vector `bench/ac3/vectors/bbb_short_5p1.ac3` (11/11) and T2's DTS slice
  `bench/dvd/test_vobs/dts_t2_4k.hex` (4/4).

**★ First rig capture (2026-11-21): rig 236's USB HDMI card (MacroSilicon) is NOT
bit-transparent.** Setup: HDMI straight into the card, `dvd_hdmi_bitstream=2`, raw
`hw:CARD=Hagibis` (PipeWire's source suspended). What came back:
- Every burst arrives on its exact period (3072 words for AC-3), but no sample is right:
  `F872 4E1F` arrives as `F881 4D82`, and Pa reads anywhere from −1919 to −76 from one
  burst to the next.
- About 1 burst gap in 50 is 3070 words, so the card also drops a pair now and then
  while re-clocking to its own 48 kHz.
- The card's ALSA mixer has no gain control, so this can't be fixed from the host.

The checker therefore also recognises **burst-shaped runs**: non-zero runs starting on a
codec's burst period after a zero gap. It reports them as "the capture path alters
samples", and counts them as bursts for `--expect silent` / `pcm`. So this card can't
check frames, but it does answer whether a bitstream is on the wire at all.

| T2, Passthru, 8 s per leg | control `DVD_vcdrestart` (`main`) | fix `DVD_passthruaudio` |
|---|---|---|
| Audio On | 212 AC-3-period bursts | 212 AC-3-period bursts |
| **Audio Off** (`--expect silent`) | **FAIL: 212 bursts still going** | **PASS: 0 non-zero words** |
| Audio On again | 212 bursts | 212 bursts |
| Decode PCM (`--expect pcm`) | PASS | PASS |

That is issue #197 measured at the output itself, with a control that fails. The chip-log
A/B in `docs/status_log.md` showed the same thing one step earlier, at the ADV7513's mode.

Issue #196 needs no capture. It is a documentation fix for behaviour the code
guarantees: both bitstream paths are muxed in after `audio_out`'s `vol_att`
(§7 Known limitations), and the field report observed exactly that.
⏳ **Nice to have, with a transparent path** (a bit-perfect USB S/PDIF input, or another
HDMI card): the bit-exact frame match and the byte order.
⏳ The `--iso` reference path is also not yet run against a real image.

---

## 7. Known limitations

- **Multichannel LPCM is impossible** on this board — one I2S data line. The
  DVD spec allows up to 8 channels of LPCM (48/96 kHz, 16/20/24-bit, capped at
  6.144 Mbit/s), but it is rare on DVD-Video and cannot ride the bitstream
  workaround either: 6 ch/48/16 is 4.608 Mbit/s against 1.536, and IEC 61937
  carries no LPCM burst type.
- **DTS-HD / TrueHD (HBR)** would need 4 data lines and 8x the bandwidth.
- ~~**MP2 and LPCM tracks are silent in Passthru**~~. *Superseded 2026-09-10 (PR #79,
  HW-confirmed): LPCM and MP2 are decoded and sent as PCM in Passthru. See
  `docs/iec61937.md` status.*
- **MiSTer's volume / mute / boost cannot touch a bitstream, and in Passthru it does not
  reach optical at all** (issue #196). `vol_att` lives in the framework's `audio_out`, and
  both bitstream paths are muxed in after it (`sys_top.v`: `spdif_out = spdif_pass_en ?
  spdif_pass : spdif`; `HDMI_* = hdmi_bs_ok ? hdmi_bs_* : i2s_*_pcm`). `SPDIF_PASS_EN` is
  `pass_mode & ~|bs_hold`, with no content term, so for the whole Passthru session optical is
  `iec61937_wrap`, whose PCM mode takes `dec_audio_l/r` straight from the decoder: LPCM and MP2
  over optical ignore the volume too. HDMI and analog follow it for PCM content (ack released
  → framework I2S; analog via `audio_out`). Documented in the manual's passthrough page. A fix
  would apply `vol_att` to the wrapper's PCM input, which needs the attenuation shipped to the
  core (stock has no such path). Not planned.
- **Audio Off is folded into `pass_mode`** (issue #197): `pass_mode = pass_sel & aud_on`, so
  Off in Passthru is Off in Decode (zeros on every leg, Main releases the chip). `pass_sel`
  feeds `player_regs` only, so SPRM15 does not follow the Audio toggle. `af_bs_session` is
  `rt_bs_session & pass_mode`: aud_route updates `bs_session` only under `split_en`, so the
  ungated bit went stale whenever `pass_mode` fell (Audio Off, or Standard Convert engaging
  mid-play) and Main kept the ADV7513 in non-PCM mode with a PCM session on the wire.
  Gate: `tools/check_audio_off_wiring.py --red` (in `run_hdmi_bitstream.sh`).
- **Simultaneous decoded-PCM-on-HDMI + bitstream-on-S/PDIF is deferred.** It
  needs two consumers of the single `audio_ring` read side. Measured cost of the
  clean fix (a second ring) is **34 M10K** against 47 free — RAM 92% → 97.6% on
  a design that has needed fit rescue twice. An 8 KB clone (~8 M10K) is the
  cheaper lever if it ever becomes a priority.
  Issue #201 hit this edge (§8): on an AC-3-only sink, DTS goes to PCM on both legs.

## 8. A sink that lists AC-3 but not DTS (issue #201, 2026-11-22)

**Problem.** `scan_sads()` used to set one `sink_ok` if the EDID named AC-3 **or** DTS at
48 kHz, and the core then bitstreamed every DD/DTS track. Many TVs name AC-3 only, so
a DTS track was sent as a burst the sink cannot decode. That most likely means silence,
with no message: `Sink does not list AC-3/DTS` fires only when **neither** codec is listed.
Found while working on #196/#197. No user had reported it.

**Fix: DTS falls back to the in-fabric decoder.**

- **Main** (`main/support/dvd/dvd_hdmi_audio.cpp`): `scan_sads()` returns
  `SINK_AC3 | SINK_DTS`. `update_no_dts()` sets `no_dts` when the ini mode is auto (0),
  the core has declared OX6, it is the DVD core, and the sink names AC-3 but not DTS.
  `user_io_send_buttons()` ORs it into **`cfg[15]`** (integration steps 61/62,
  `CONF_DVD_HDMI_NODTS`). The bit follows the sink, not the track, so it is pushed only
  when the EDID or the mode changes.
- **Core**: `sys/hps_io.sv` exports `ini_hdmi_no_dts = cfg[15]` → `hdmi_no_dts` →
  `aud_route .dts_dec`. Under `dts_dec` a DTS frame is not `is_bitstream`, so it is granted
  to `dvd_audio_decode` like LPCM. `pcm_session` and `bs_session` follow from the routing
  alone: Main sees a PCM session and releases the ADV7513, and AC-3 keeps engaging it as
  before. Because it is sampled at each grant, an EDID change mid-track (hotplug) takes
  effect at a frame boundary.
- **SPRM15**: `player_regs .pass_mode` is now `pass_dts = pass_sel & ~hdmi_no_dts`. On
  such a sink the DTS bit rests on `cb_tables_ok` alone, so a core whose codebook copy
  failed tells the disc it cannot play DTS.
- **`AUDIO UNSUPPORTED`** for DTS (codebooks failed) can now fire in Passthru when
  `hdmi_no_dts` is set, because the decoder is the one playing it there.
- **0x7B word**: bit 14 = this core reads `cfg[15]`, bit 13 = the value it holds. The Main
  only logs these (`/tmp/dvd_hdmi_audio.log`: `no_dts=` and `core_nodts=v4/value`).

**Decisions.**

- **Optical gets PCM too (user decision, 2026-11-22).** One ring consumer per frame, so
  a DTS frame goes to either the wrapper (both legs get a bitstream) or the decoder (both
  get PCM). Keeping optical on DTS while HDMI gets PCM is the "two ring consumers" item
  deferred in §7, at a cost of 8–34 M10K. The accepted cost: someone with HDMI to an
  AC-3-only TV and optical to a DTS receiver now gets stereo PCM on DTS tracks.
  `dvd_hdmi_bitstream=2` restores the old behaviour for them, and the manual says so.
- **Force (=2) and off (=1) leave `cfg[15]` clear.** Force exists because sinks
  misreport. Off never engages HDMI, so optical keeps the DTS bitstream as before.
- **No AC-3 fallback for a sink that names DTS only.** `cfg[15]` was the last free cfg
  bit, and no such sink has been seen. The Main logs the flags, so a report would show it.
- **No new on-screen notice.** A decoded DTS track is the feature working, not a failure
  to explain. It is the same rule as the removed engage notice (§5).

**Gates.** `bench/dvd/run_passthru_pcm.sh --red` (`aud_route_tb` TEST 7; RED
`dts-dec-ignored`, `dts-dec-takes-ac3`, `dts-always-decoded`); `bench/dvd/run_telem.sh`
(0x7B bits 13/14); `tools/check_dts_sink_wiring.py --red` (in `run_hdmi_bitstream.sh`);
`tools/check_player_regs_wiring.py --red` and `tools/check_audio_off_wiring.py --red`
(both follow `pass_dts`); `main/tests/run_tests.sh --red` ([14] the 8-row decision table,
[15] AC-3 engages and decoded DTS releases, with no `cfg[15]` push per track; RED
`nodts-never-set`, `nodts-ignores-dts-sad`, `nodts-in-force-mode`, `nodts-not-pushed`).

**HW A/B (2026-11-22, rig .201, by ear).** The sink was an Insignia NS24D310NA21 TV. Its
EDID, read off the ADV7513 at `i2c-1:0x3f`, lists LPCM 2 ch and AC-3 6 ch at 48 kHz, and
no DTS. Disc: *A.I.* VTS 1, track 1 AC-3 5.1 and track 3 DTS 5.1. Passthru, Disc Menus
Off, `dvd_hdmi_bitstream` auto, the new Main on both arms.

| | control `DVD_drc_20261113_0253` | fix `DVD_dtssink_20261122_0152` |
|---|---|---|
| Main's log | `no_dts=1 core_nodts=0/0` | `no_dts=1 core_nodts=1/1` |
| DTS track | `bs_session=1`, chip non-PCM, decoder idle: **silent** | `pcm_session=1`, chip `PCM I2S`, `dts_active 1`: **sound** |
| AC-3 track | `bs_session=1`, chip non-PCM: silent | the same: silent |

So the fix works end to end, and the control fails the way the issue predicted.

> **Superseded (2026-11-22): the cause was the core, not the board.** The SuperStation One
> is an MCP23009 board, and `sys_top`'s `mcp_en` guard kept the bitstream off its HDMI
> pins (§9). The "not bit-exact" conclusion below is wrong; it stays as the bisect's record.

**Rig .201 does not bitstream over HDMI at all, and that confounds every .201 result
above.** The AC-3 silence (both arms) led to a bisect. Every HDMI bitstream from rig .201
failed, whatever the sink:
- a Samsung TV (`SAM 0d42`, lists AC-3 + DTS): AC-3 and DTS both silent;
- the maintainer's AV receiver ("decoder off"): with today's core and Main, the Oct 1 Main,
  the Sept 30 core, the **Aug 31 `bsflapfix2` core that passed on this receiver then**, and
  at `video_mode=8`.
On .201, PCM to the receiver plays, the ADV7513 reads back `0x0C=0x44 0x12=0xA0
0x15=0x20` (as designed), and its active ini lines match .236's for everything audio.
**The same receiver on rig .236, with today's build, plays Dolby Digital and DTS.** So the
code is fine and the cause is specific to .201. **Rig .201 is a SuperStation One**, a
single-board MiSTer-compatible console. Rig .236 is a DE10-Nano. Nothing published names the
SuperStation's HDMI transmitter or how its audio is wired. It answers at the ADV7513's I2C
address and plays PCM. **Settled 2026-11-22:**
- Its transmitter is the same chip, ID `0x7511` rev `0x13`. A full 256-register dump taken
  mid-bitstream at `video_mode=8` matches .236's in every audio and configuration register:
  N/CTS, `0x0A`-`0x16` (I2S select, CS source, the `0x12[7]` non-PCM flag, 48 kHz) and the
  audio infoframe. The only differences are status and interrupt bytes: `0x97` 00/80,
  `0x9E` 18/17, `0xA0` 01/00, `0xC5` 10/90, `0xC8` 02/42 (.236/.201).
- **Its TOSLINK passthrough decodes fine on the same receiver** (maintainer, by ear). That
  output is the FPGA's own S/PDIF pin and does not go through the HDMI chip.

So the core's bursts are right and the transmitter is told the right thing. What reaches the
transmitter's I2S input on that board is not bit-exact. PCM hides an LSB-level error and a
61937 sync word does not, so the receiver never locks ("decoder off"). This is
hardware-specific. The manual (passthrough, troubleshooting, compatibility) tells
SuperStation owners to use TOSLINK. A fabric-side fix, such as an I2S timing or edge
change, would need a capture path on that board to prove it and is not planned. The DTS-decode result on .201 still stands, since it is PCM. The
TV AC-3 result does not: it says nothing about TVs until it is repeated from a working rig.

**HW, rig .236 → the receiver (`dev-dtssink`, *Ultimate T2*):** `no_dts=0`; AC-3 track:
Dolby Digital, sound; DTS track: **DTS, sound**, bitstreamed. The new core leaves DTS
alone on a sink that lists it.

The rigs' other sinks, for the record: rig 236's Hagibis card and a "MATRIX 4*4" switch,
and an AOC Q27G3XMN monitor, list LPCM only. A Samsung TV (`SAM 0d42`) lists AC-3 + DTS.
An Insignia NS-50E440NA14 behind (apparently) an AVR lists everything up to TrueHD/DTS-HD.

## 9. MCP23009 boards and the SuperStation One (2026-11-22): the guard was the cause

**State:** 🔧 `feature/ss1-hdmi-bs` (stacked on #201's branch), fit
`DVD_ss1hdmibs_20261122_0450` PASS. ✅ HW A/B by ear on rig .201 (SuperStation One →
the AV receiver over HDMI, *A.I.* AC-3, Passthru): control **decoder off**, fix **Dolby
Digital**, fix again **Dolby Digital**. ✅ DE10-Nano regression on .236 (Hagibis, *A.I.*): Passthru 212 AC-3-period bursts in 8 s,
the same as the #197 reference; Decode PCM: PCM, no bursts. The SuperStation's analog
jack by ear was skipped (maintainer's call): it gets the PCM serializer, as before.

**The guard.** `sys/sys_top.v` had `hdmi_bs_ok = hdmi_bs_en & ~(SW[0] | mcp_en)`. On a
board whose analog jack is an I2S DAC (`SW[0]`, or an MCP23009 I/O-expander board:
`mcp_en`), stock drives the DAC from `HDMI_SCLK/I2S/LRCLK` (`AUDIO_L/R/SPDIF`). So the
bitstream was refused on the HDMI pins there, because it would have reached the DAC as
noise. The Main still set the chip's non-PCM flag, so the receiver got PCM samples flagged
as data: "decoder off". **The SuperStation One is such a board.** **Change (7821e5a):**
the DAC pins read the PCM serializer (`i2s_*_pcm`) and `hdmi_bs_ok = hdmi_bs_en`. With no
bitstream, `HDMI_*` *are* `i2s_*_pcm`, so every board is bit-for-bit stock. With one, the
DAC keeps getting the PCM path and never the burst. Gate:
`tools/check_hdmi_bs_dac_wiring.py --red` (in `run_hdmi_bitstream.sh`).

**The A/B that settled it** (same direct cable, receiver on its HDMI input, the same Main):

| build | receiver |
|---|---|
| `DVD_ss1hdmibs_20261122_0450` (the change), `dvd_hdmi_bitstream=2` | Dolby Digital, sound |
| the same, auto mode | Dolby Digital, sound |
| control `DVD_dtssink_20261122_0152` (the guard in), auto mode | **decoder off, silent** |
| the change again, auto mode | Dolby Digital, sound |

**⚠ An earlier round wrongly cleared the guard.** The first test of this build, and of a
diagnostic build that also put the bitstream on `AUDIO_*` (`dev-ss1hdmibs2`, reverted),
both read "decoder off". The maintainer later found the receiver set to its optical input
during a test, and that most likely happened then too. On the strength of that round, this
section blamed the board's wiring for a while. Lesson: in a by-ear A/B, confirm the sink's
input before each reading, and run the control in the same sitting.

**The capture (2026-11-22)** narrowed it before the A/B. The SuperStation's HDMI straight
into the Hagibis, the change's build, `dvd_hdmi_bitstream=2`, 10 s, raw
`hw:CARD=Hagibis`, against rig 236's #197 capture through the same card:

| | SuperStation (.201) | DE10-Nano (.236) |
|---|---|---|
| burst period | 3072 words (265×), 3070 (9×, the card's re-clock) | 3072 (208×), 3070 (4×) |
| burst length | 902 words | 902 words |
| first words as the card delivers them | `f881 4d82 fff1 382c 0b60 …` | `f881 4d82 fff1 382c 0b60 …` |

The same stream reaches both boards' ADV7513. N = 6144 and CTS = 27000 on the
SuperStation, steady, and its I2C bus holds only the ADV7513's own maps
(0x38/0x39/0x3C/0x3E/0x3F). Nothing on the board alters the bitstream.

**Who else this fixes:** a DE10-Nano with an MCP23009 analog I/O board, or with `SW[0]`
set, had silent HDMI passthrough by construction. Not tested on such a board.
