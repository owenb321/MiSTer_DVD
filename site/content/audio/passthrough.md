# Bitstream passthrough

Set **`Audio Out` = `Passthru (SPDIF+HDMI)`** and the disc's **undecoded AC-3 or DTS
bitstream** goes to an AV receiver to decode instead of being decoded in the core. This is
what gets you real 5.1 rather than a stereo downmix, and it is the only way to hear DTS at
all. Tracks with no bitstream format — LPCM and MP2 — are still decoded and sent as
ordinary PCM, so the setting never costs you sound.

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

Over HDMI the transmitter is switched out of PCM mode **only while a Dolby Digital or DTS
track is actually playing**, and switched back when the track changes, when you load
another core, and when you reboot. You do not need to leave Passthru before loading
something else.

!!! warning "If another core loses HDMI audio, update both halves and power-cycle"
    Earlier versions switched the transmitter as soon as Passthru was selected and never
    switched it back, so the next core was silent — and nothing but removing power cleared
    it. Update the core and `MiSTer_DVDcss` together: a current Main with an older core
    falls back to the older behaviour, because an older core cannot tell it which format is
    playing. See
    [Troubleshooting](../reference/troubleshooting.md#another-core-has-no-hdmi-audio-after-i-used-the-dvd-core).

## What passes through and what does not

| Format | In Passthru | Notes |
|---|---|---|
| **AC-3 (Dolby Digital)** | Bitstreamed | All channel modes |
| **DTS** | Bitstreamed | **The only way to hear DTS** — there is no DTS decoder in the core |
| **LPCM** | Sent as PCM | Decoded in the core and sent as ordinary stereo — see below |
| **MP2** | Sent as PCM | Same; this is what VCD and SVCD discs carry |

!!! warning "The HDMI half needs a matching `MiSTer_DVDcss`"
    Over HDMI the wire format is set from the ARM side, so LPCM and MP2 come out as PCM
    only when the core and `MiSTer_DVDcss` are from the same release. Pairing a v0.5.0
    core with an older Main leaves those two **silent over HDMI** — extract the release
    zip so both update together. Optical S/PDIF works with either.

!!! info "New in v0.5.0 — LPCM and MP2 no longer go silent"
    These two used to be silent in Passthru, so a concert disc or a VCD needed a trip
    back to `Decode PCM`. They now come out as ordinary PCM, which is what a set-top
    player does with them. The switch is automatic and happens per track.

Passthru is no longer all-or-nothing. It sends whatever the disc's current audio track
needs: a Dolby Digital or DTS track goes out as an undecoded bitstream for your receiver,
and an LPCM or MP2 track is decoded in the core and goes out as ordinary PCM. Changing
audio track with **B7** switches the format on the wire, and your receiver will re-lock —
a second or so of silence at the change is normal, and a real player does the same.

!!! warning "DTS still needs a receiver"
    **There is no DTS decoder in the core**, so DTS is the one format with no fallback:
    on a plain television or monitor a DTS track is silent in *both* modes. Most DTS
    discs also carry a Dolby Digital track — cycling audio with **B7** will usually find
    one. AC-3 has the same limitation in Passthru specifically, but `Decode PCM` handles
    it on any display.

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
re-establishes it. A title locks within a couple of seconds and track changes are
near-instant.

## Limitations

- **Core DTS only** — 48 kHz, up to 16-bit. No DTS-HD, no 96 kHz, no high-bit-depth
  variants. DVDs do not carry those.
- **LPCM is 48 kHz stereo, 16-bit.** 96 kHz and multichannel LPCM are not decoded;
  24-bit is truncated to 16. Those discs are rare and the format is a DVD-Audio corner.
