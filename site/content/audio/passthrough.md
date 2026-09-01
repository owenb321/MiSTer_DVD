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

## Track changes and startup

The receiver needs a moment to lock onto the bitstream, and switching audio tracks
re-establishes it. This used to be visibly bad — several seconds of dropouts at every title
start, and audible flapping on track changes — and is now fixed: titles lock within a
couple of seconds and track changes are near-instant.

During deliberate silences (an authored gap, a menu transition, an A/V sync hold) the core
emits **real PCM silence** rather than null bitstream bursts. Receivers cannot acquire lock
across null non-PCM bursts, so they would drop out; sending genuine PCM means the receiver
sees a clean single transition from PCM to Dolby/DTS, exactly like a real player.

## Limitations

- **Core DTS only** — 48 kHz, up to 16-bit. No DTS-HD, no 96 kHz, no high-bit-depth
  variants. DVDs do not carry those.
- **LPCM and MP2 are silent** in Passthru; use Decode PCM for those discs.
- Needs a receiver that decodes AC-3/DTS. Inaudible on a plain television.
