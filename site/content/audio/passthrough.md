# Bitstream passthrough

Set **`Audio Out` = `Passthru (SPDIF+HDMI)`** and the core stops decoding audio, sending the
disc's **undecoded AC-3 or DTS bitstream** to an AV receiver to decode instead. This is what
gets you real 5.1 rather than a stereo downmix, and it is the only way to hear DTS at all.

The format is **IEC 61937**, the standard wrapper for carrying compressed audio inside what
otherwise looks like an ordinary PCM stream. It is what a set-top DVD player's optical
output does.

## Two ways out

**Optical S/PDIF** — works with the stock MiSTer Main. The framework drives its S/PDIF
signal to both the Digital I/O board's TOSLINK connector and the Analog I/O board's combo
3.5 mm mini-TOSLINK output, so either add-on board carries it.

**Over HDMI** — needs the [`MiSTer_DVDcss` custom Main](../formats/physical-discs.md).
IEC 61937 rides inside an ordinary 2-channel/48 kHz/16-bit stream at 1.536 Mbit/s, which is
exactly what the DE10-Nano's single wired audio line to the HDMI transmitter carries. So
**5.1 over HDMI needs no add-on board at all** — just the custom Main and a receiver that
advertises AC-3/DTS support in its EDID.

!!! warning "HDMI bitstream needs `MiSTer_DVDcss`"
    Optical S/PDIF passthrough works on the bare `.rbf`. **Over HDMI it does not** — see
    [What you need](../getting-started/what-you-need.md). Nothing else about passthrough
    changes; the same `Audio Out` toggle drives both outputs.

!!! info "Why HDMI needs the custom Main"
    Sending a bitstream to a device still expecting PCM produces full-scale noise. The
    HDMI transmitter's configuration is only reachable from the ARM side, so the core
    refuses to emit a bitstream over HDMI without an explicit acknowledgement that only
    `MiSTer_DVDcss` sets — after it has checked the display's EDID audio descriptors, which
    the stock Main does not parse at all. The safety is structural rather than a
    convention.

## What passes through and what does not

| Format | In Passthru | Notes |
|---|---|---|
| **AC-3 (Dolby Digital)** | Bitstreamed | All channel modes |
| **DTS** | Bitstreamed | **The only way to hear DTS** — there is no DTS decoder in the core |
| **LPCM** | Silent | Use Decode PCM |
| **MP2** | Silent | Has no passthrough encoding |

!!! warning "Passthru is not a better version of Decode"
    On a display that cannot decode AC-3 or DTS — an ordinary television, a monitor —
    Passthru is **silent**. Decode PCM works on anything. Only switch to Passthru if the
    audio is reaching a receiver that says it handles these formats.

## If the receiver names the format but plays static

Toggle **`SPDIF Byte Order`** (Normal / Swap). Payload byte order is the classic failure
here — the receiver correctly identifies "Dolby Digital" from the stream's header but
cannot make sense of the payload, so it hisses. It is a runtime toggle for exactly this
reason.

## Controlling the HDMI path from `MiSTer.ini`

By default the core engages the HDMI bitstream only when the display's EDID advertises
AC-3/DTS support. That is the safe behaviour, but sinks do misreport — **especially over
ARC** — so there is an override:

```ini
[DVD]
main=MiSTer_DVDcss

; HDMI bitstream for Audio Out = Passthru.
;   0 = auto  (default) engage only when the sink's EDID advertises AC-3/DTS
;   1 = off   never engage; HDMI behaves as it did before
;   2 = force engage regardless of EDID
dvd_hdmi_bitstream=0
```

Use **`2` (force)** when you know your receiver handles Dolby Digital or DTS but the core
is not engaging — a receiver reached over ARC often does not advertise its capabilities
correctly. Use **`1` (off)** to rule the HDMI path out entirely while diagnosing something
else.

!!! tip "Finding out what it decided"
    The custom Main writes `/tmp/dvd_hdmi_audio.log` with the stage-by-stage result —
    what the EDID said, whether the bitstream path engaged, and why not if it did not.
    That is the first thing to read when HDMI passthrough is silent.

## Track changes and startup

The receiver needs a moment to lock onto the bitstream, and switching audio tracks
re-establishes it. This used to be visibly bad — several seconds of dropouts at every title
start, and audible flapping on track changes — and is now fixed: titles lock within a couple
of seconds and track changes are near-instant.

## Authored silence drops the receiver out of Dolby/DTS

**Where a disc authors silence — a menu with no background audio, a gap between
programmes — your receiver will stop decoding and show something like "Decoder Off"** until
audio returns. Re-acquisition takes under a second.

This is a real limitation, not a misconfiguration, and there is currently no way around it.
Silence in the stream means there is no bitstream to send, and a receiver only holds its
lock on **real data**. Both plausible fillers were built and tested on a real receiver — a
non-PCM hold, and a pause burst — and **neither holds the lock**, even with an otherwise
clean stream.

The fix that would work is "digital black": looping a pre-encoded silent AC-3 frame during
authored silence, which is what some set-top players do. It is recorded as possible future
polish rather than something in progress. Many real players behave exactly as this core does
today.

!!! note "Not to be confused with the old startup flap"
    A separate, now-fixed bug made receivers flap between naming the codec and no decode for
    around 45 seconds at every title start. If you see dropouts at a *title start* or on a
    *track change*, that is the fixed bug and you want a newer build. Dropouts at a silent
    menu are the limitation above.

## Limitations

- **Core DTS only** — 48 kHz, up to 16-bit. No DTS-HD, no 96 kHz, no high-bit-depth
  variants. DVDs do not carry those.
- **LPCM and MP2 are silent** in Passthru; use Decode PCM for those discs.
- **Authored silence drops the receiver out of decode mode** — see above.
- Needs a receiver that decodes AC-3/DTS. Inaudible on a plain television.
