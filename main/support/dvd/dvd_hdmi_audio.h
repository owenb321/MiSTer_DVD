// dvd_hdmi_audio.h — HDMI IEC 61937 bitstream support for the DVD core.
//
// The DVD core's "Audio Out = Passthru" wraps undecoded AC-3/DTS in IEC 61937.
// It has always gone out optical S/PDIF; the core can now also clock the same
// IEC 60958 subframes into the ADV7513's I2S input, so an AV receiver on HDMI
// decodes DD/DTS 5.1 with no Digital I/O board.
//
// The ADV7513's I2C is HPS-only, so putting it in IEC958-direct mode is our job.
// Until we have done it the sink expects PCM, and a bitstream would come out as
// full-scale noise — so the core will not emit one until we set the cfg[14] ack.
// Stock Main never sets it, which is exactly why a stock-Main user is safe.
//
// See MiSTer_DVD/docs/hdmi_bitstream.md.

#ifndef DVD_HDMI_AUDIO_H
#define DVD_HDMI_AUDIO_H

// Called from parse_config()'s OX arm when the core declares OX6 ("Audio Out").
// A core build without the HDMI tap never declares it, so we never reconfigure
// the chip for a core that cannot drive it.
void dvd_hdmi_audio_declare(void);

// Called every user_io_poll(). Watches the Audio Out status bit and the sink's
// EDID, drives the ADV7513, and raises/clears the ack.
void dvd_hdmi_audio_tick(void);

// The cfg[14] ack, read by user_io_send_buttons().
int  dvd_hdmi_audio_ack(void);

#endif
