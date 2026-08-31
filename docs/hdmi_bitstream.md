# IEC 61937 bitstream over HDMI

**Status: 🔧 built, sim-verified, ⏳ HW-confirm pending** (2026-08-30, branch
`feature/hdmi-bitstream`). Design + the open HW questions are below; the S/PDIF
half this builds on is `docs/iec61937.md`.

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
switch rather than a torn subframe.

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

⚠ **Open assumption.** The exact preamble nibble the ADV7513 expects in
IEC958-direct is unconfirmed. The upper nibble of the biphase patterns is
already a clean one-hot (Z=1, Y=2, X=4) and that is what is exported. **If HW
round 1 shows the receiver locking to the wrong channel or never finding block
start, this table is the first thing to change** — it is flagged in both
`dvd/spdif_pass.sv` and `dvd/i2s_iec958.sv`.

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

Also guarded: `SW[0]`/`mcp_en` route the HDMI audio signals to the analog
board's audio pins, where an I2S DAC would render a bitstream as noise. The mux
falls back to PCM in that case.

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

| reg | bitstream | PCM | meaning |
|---|---|---|---|
| `0x0A` | `0x00` | `0x00` | audio select = I2S |
| `0x0C` | `0x07` | `0x04` | I2S0 enable; `[1:0]` 3 = IEC958 direct, 0 = standard |
| `0x14` | `0x02` | `0x02` | word length 16 bit |
| `0x15` | rate | rate | sampling rate (follows `hdmi_audio_96k`) |
| `0x73` | `0x00` | `0x01` | InfoFrame CC: 0 = refer to stream header |

**N and CTS are unchanged.** 61937 at 48 kHz *is* a 48 kHz stream — which is a
large part of why this feature is small.

MiSTer.ini: `dvd_hdmi_bitstream` — `0` auto (EDID-gated, default), `1` off,
`2` force. Force exists because sinks do mis-report, especially over ARC.

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

### HW gate — nothing about the ADV7513 is simulable

1. AVR shows "Dolby Digital" / "DTS" and plays 5.1.
2. **Locks at startup without a chapter skip**; survives 5 consecutive
   audio-track switches, a chapter skip and a D-pad seek. (This is the §3
   phase-step / hold-off gate.)
3. Volume keypress mid-bitstream recovers.
4. Picture unaffected across repeated Audio Out toggles.
5. **Negatives:** a plain TV stays muted and **silent, never noisy**; the same
   `.rbf` on **stock** Main behaves exactly as today.

If (1) fails with the receiver naming nothing or mis-locking, try the §3
preamble table before anything else.

---

## 7. Known limitations

- **Multichannel LPCM is impossible** on this board — one I2S data line. The
  DVD spec allows up to 8 channels of LPCM (48/96 kHz, 16/20/24-bit, capped at
  6.144 Mbit/s), but it is rare on DVD-Video and cannot ride the bitstream
  workaround either: 6 ch/48/16 is 4.608 Mbit/s against 1.536, and IEC 61937
  carries no LPCM burst type.
- **DTS-HD / TrueHD (HBR)** would need 4 data lines and 8x the bandwidth.
- **MP2 and LPCM tracks are silent in Passthru**, as before — and now under a
  permanent non-PCM flag, so an AVR may report no signal rather than silence.
- **Simultaneous decoded-PCM-on-HDMI + bitstream-on-S/PDIF is deferred.** It
  needs two consumers of the single `audio_ring` read side. Measured cost of the
  clean fix (a second ring) is **34 M10K** against 47 free — RAM 92% → 97.6% on
  a design that has needed fit rescue twice. An 8 KB clone (~8 M10K) is the
  cheaper lever if it ever becomes a priority.
