# Integrating `MiSTer_DVDcss` into stock Main_MiSTer

The custom Main is **stock Main_MiSTer + this overlay**. `build_main.sh` applies all
of this automatically; this file is the human-readable source of truth for exactly
what changes, so a stock-version bump that breaks an anchor can be fixed by hand.

Base pinned in `build_main.sh`: `MAIN_MISTER_REF` (a MiSTer-devel/Main_MiSTer commit).

## Files copied in (no edits needed — the Makefile auto-globs `support/*/*.cpp`)

- `support/dvd/dvd_css.cpp` / `dvd_css.h`   — CSS-decrypted sector reads (dlopen libdvdcss)
- `support/dvd/dvd_detect.cpp` / `dvd_detect.h` — READ(10) DVD-Video probe
- `support/dvd/dvd_phys.cpp` / `dvd_phys.h` — standalone auto-mount trigger
- `Scripts/install_dvdcss.sh`               — user-run libdvdcss installer

## Makefile — one edit

Add `-ldl` (dlopen) to `LFLAGS`:

```
-LFLAGS	= -lc -lstdc++ -lm -lrt $(IMLIB2_LIB) -Llib/bluetooth -lbluetooth -lpthread
+LFLAGS	= -lc -lstdc++ -lm -lrt -ldl $(IMLIB2_LIB) -Llib/bluetooth -lbluetooth -lpthread
```

## user_io.cpp — six edits

Note: unlike the MiSTer Physical Disc fork, we do **not** include
`support/physical_disc/physical_disc.h`; the mount is triggered by our own
`dvd_phys_tick()` using `DVD_PHYS_SENTINEL`, so the custom Main is self-contained
on stock MiSTer.

**1. Includes** — after `#include "ide_cdrom.h"`:

```cpp
#include "support/dvd/dvd_css.h"
#include "support/dvd/dvd_phys.h"
```

**2. Slot type** — after `#define SD_TYPE_A2 2`:

```cpp
#define  SD_TYPE_DVDCSS 4   // physical DVD-Video, sectors served CSS-decrypted via libdvdcss
                            // (3 == SD_TYPE_IIGS in support/a2/iigs_disk.h — must differ)
```

**3. `is_dvd()`** — after the `is_3do()` function (anchor: `return (is_3do_type == 1);` `}`):

```cpp
static int is_dvd_type = 0;
char is_dvd()
{
	if (!is_dvd_type) is_dvd_type = strcasecmp(orig_name, "DVD") ? 2 : 1;
	return (is_dvd_type == 1);
}
```

Also declare `char is_dvd();` in `user_io.h` (near the other `is_*()` declarations).

**4. Reset in `user_io_read_core_name()`** — after `is_uneon_type = 0;`:

```cpp
	is_dvd_type = 0;
```

**5. Mount path in `user_io_file_mount()`** — after `sd_image_cangrow[index] = (pre != 0);`:

```cpp
	if (sd_type[index] == SD_TYPE_DVDCSS) dvd_css_close();
```

and replace the opening `if (x2trd_ext_supp(name))` of the mount dispatch with the
physical-disc branch, the encrypted-ISO branch, and an `else if` back to `x2trd`:

```cpp
			if (!strcmp(name, DVD_PHYS_SENTINEL) && is_dvd())
			{
				// Physical DVD-Video: no file to open. libdvdcss (user-supplied)
				// serves CSS-decrypted 2048-byte sectors; drive-backed, read-only.
				// Without libdvdcss it falls back to raw reads (unencrypted discs
				// still play); an encrypted disc gets the "install libdvdcss" popup.
				if (dvd_css_open())
				{
					sd_type[index] = SD_TYPE_DVDCSS;
					sd_image[index].size = dvd_css_size();
					writable = 0;
					ret = 1;
				}
			}
			else if (is_dvd() && len > 4 && !strcasecmp(name + len - 4, ".iso")
			         && dvd_css_open_image(name))
			{
				// CSS-encrypted ISO image (no drive needed). dvd_css_open_image()
				// claims the mount only when the image is genuinely scrambled; a
				// decrypted ISO returns 0 and takes the normal direct-file path.
				sd_type[index] = SD_TYPE_DVDCSS;
				sd_image[index].size = dvd_css_size();
				writable = 0;
				ret = 1;
			}
			else if (x2trd_ext_supp(name))
```

**6. Poll hooks + block-read servicing** — in `user_io_poll()`, after
`add_frame_callback(screenshot_cb);`:

```cpp
	dvd_css_tick();    // deferred "install libdvdcss" popup once launch settles
	dvd_phys_tick();   // auto-mount / unmount the optical drive
```

and in the two sd block-read branches, before the `else if (sd_image[disk].size)` /
`else if (FileSeek(...))` fallbacks, add the CSS read source:

```cpp
					else if (sd_type[disk] == SD_TYPE_DVDCSS)
					{
						diskled_on();
						if (dvd_css_read(buffer[disk], lba, buf_n) > 0)
						{
							done = 1;                  // (first branch only)
							buffer_lba[disk] = lba;
						}
					}
```

(The second read site sets `buffer_lba[disk] = lba` on success and zero-fills +
`buffer_lba[disk] = -1` on failure — see `dvd_phys`/fork history for the exact
form; `build_main.sh` inserts both.)

## HDMI IEC 61937 bitstream (steps 12-21)

Lets `Audio Out = Passthru` reach an AV receiver over **HDMI** as well as optical
S/PDIF. The core serializes IEC 60958 subframes into the ADV7513's I2S input, but
only the HPS can put that chip into IEC958-direct mode over I2C — so the core
refuses to emit a bitstream until Main sets the `cfg[14]` ack. **Stock Main never
sets it**, which is what makes a stock-Main user safe: without the mode change the
sink expects PCM, and a bitstream would arrive as full-scale noise.

> ⚠ These are the overlay's **first edits to `video.cpp`, `video.h` and `cfg.*`**.
> Everything before step 12 touches only `user_io.*` and the `Makefile`. On a
> `MAIN_MISTER_REF` bump, re-verify these specifically.

| Step | File | What |
|---|---|---|
| 12 | `user_io.cpp` | include `support/dvd/dvd_hdmi_audio.h` |
| 13 | `user_io.cpp` | `dvd_hdmi_audio_tick()` on the step-7 poll site |
| 14 | `user_io.cpp` | `CONF_DVD_HDMI_BS` into the `cfg[]` word sent to the core |
| 15 | `user_io.cpp` | `dvd_hdmi_audio_declare()` off the `OX` arm in `parse_config()` |
| 16 | `user_io.h` | `#define CONF_DVD_HDMI_BS 0b0100000000000000` (bit 14) |
| 17 | `video.h` | export `hdmi_config_set_audio()` + `video_hdmi_config_generation()` |
| 18 | `video.cpp` | `static int hdmi_cfg_generation` beside the other file statics |
| 19 | `video.cpp` | bump that counter in `hdmi_config_init()` |
| 20 | `video.cpp` | `hdmi_config_set_audio()` — the audio-only register writer |
| 21 | `cfg.h` / `cfg.cpp` | `dvd_hdmi_bitstream` ini key (0=auto, 1=off, 2=force) |

Three things here are easy to get subtly wrong:

- **Step 19's anchor is the `for (uint i = 0; ...)` write-loop header, not
  `hdmi_config_set_csc();`.** That second string appears again later in
  `video.cpp`, and `insert_after` takes the FIRST match — it would apply today and
  silently land in the wrong function after any stock reorder.
- **Step 20 is a small audio-only writer on purpose.** Reusing
  `hdmi_config_init()` would rewrite ~50 registers plus the CSC and blank the
  picture on every Audio Out toggle. But that full init *does* revert the audio
  block, so step 18/19's generation counter exists to notice and re-apply.
- **Bit 14 is nearly the last free `cfg[]` bit.** Stock defines up to
  `CONF_DIRECT_VIDEO2` (bit 13); only 14 and 15 remain. If a future stock version
  claims 14, this step must move rather than collide silently.

The core marks the option `OX6` rather than `O6`. `OX` means "also handled by the
HPS": the bit still reaches the core exactly as before, but Main sees the
declaration and learns this build *has* the HDMI path. A core without it never
declares `OX6`, so Main never reconfigures the chip for a core that cannot drive
it.

## MiSTer.ini (end user)

```
[DVD]
main=MiSTer_DVDcss

; HDMI bitstream for Audio Out = Passthru.
;   0 = auto  (default) engage only when the sink's EDID advertises AC-3/DTS
;   1 = off   never engage; HDMI behaves as it did before
;   2 = force engage regardless of EDID (sinks do mis-report, especially over ARC)
dvd_hdmi_bitstream=0
```

## Steps 22-26 — on-player support bundle

`main/support/dvd/dvd_report.{h,cpp}`. A gamepad chord (Audio + Subtitle, held
2 s) makes the Main build a navigation support bundle from whatever is mounted
and write it to `/media/fat/DVD_reports/`. Design, and the alternatives that were
rejected: `MiSTer_DVD/docs/support_bundle_hps.md`.

| # | File | Edit |
|---|---|---|
| 22 | `user_io.cpp` | include `support/dvd/dvd_report.h` |
| 23 | `user_io.cpp` | `dvd_report_tick()` at the step-7 tick site |
| 24 | `user_io.cpp` | `dvd_report_joy(map)` at the top of `user_io_digital_joystick()` |
| 25 | `user_io.cpp` + `user_io.h` | `user_io_last_lba(int index)` accessor |
| 26 | `user_io.cpp` | `dvd_report_note_mount(name)` inside `user_io_file_mount()` |

Notes that matter on a `MAIN_MISTER_REF` bump:

- **Step 24 observes only.** It reads `map` and never writes it, so the chord's
  buttons still reach the core and a bug here cannot stop a button working. Do
  not "improve" it into masking the chord bits — that trades a harmless
  double-action for the risk of breaking input outright, and it would swallow a
  legitimate fast double-press.
- **Step 25 is anchored on the end of the `buffer_lba[16]` initialiser**, i.e. the
  line `ULLONG_MAX,ULLONG_MAX,ULLONG_MAX,ULLONG_MAX };`. If stock reformats that
  array the anchor breaks loudly, which is correct — the accessor must sit after
  the declaration it reads.
- **Step 26 exists because nothing else keeps the mounted path.** `fileTYPE::name`
  is the basename only and `fileTYPE::path` is filled only in this function's
  pre-create branch, so a normal mount has neither. It observes `name` and never
  modifies it.
- **No Makefile edit is needed.** `CPP_SRC` already has
  `$(wildcard ./support/*/*.cpp)`.
- The work forks; it must never run inline in the poll loop, which also services
  SD blocks for the core.

## Steps 27-29 — MGL launch (issue #48)

`main/support/dvd/dvd_launch.{h,cpp}`. Design and the full launch timeline:
`MiSTer_DVD/docs/mgl_launch.md`.

| # | File | Edit |
|---|---|---|
| 27 | `user_io.cpp` | include `support/dvd/dvd_launch.h` |
| 28 | `user_io.cpp` | `dvd_launch_tick()` **first** of the DVD ticks in `user_io_poll()` |
| 29 | `user_io.cpp` | `dvd_report_note_mount_result(...)` immediately before `UIO_SET_SDSTAT` |
| 30 | `user_io.cpp` | `dvd_phys_note_mount(name, index)` beside step 26, so the drive can see slot 0 being taken |

The rule these steps exist to enforce, and it applies to **any** future overlay
code that runs from a `user_io_poll()` tick:

> **Never raise `Info()` / `InfoMessage()` / `ProgressMessage()` while
> `mgl_get()->done == 0`.** Check `dvd_launch_ui_busy()` first and defer.

Why it is not merely cosmetic: during an MGL launch `HandleUI()` takes the MGL
branch and **never calls `menu_key_get()`**, which is the sole source of every
input event — keyboard menu key, gamepad menu key, the physical OSD button and
the core's own virtual one. The MGL's only forward edge out of `state == 1`
requires `menustate == MENU_NONE2`, and `InfoMessage()` pins
`menustate = MENU_INFO`. So a notice raised from a poll tick stalls the load
**and** every input path on the machine — the reported "completely unresponsive,
the MiSTer must be restarted".

- **Step 28 is placed first** so that when the watchdog releases a stalled MGL,
  the notice pumps see `done == 1` in the same poll iteration.
- **The watchdog is a floor, not the fix.** It bounds a stall at ~20 s and hands
  the UI back; the fix is the `dvd_launch_ui_busy()` gate in the pumps
  (`dvd_css_tick`, `report_pump`). Keep both: the gate covers the causes we know
  about, the watchdog covers the ones we do not.
- **Step 29 is a log line only.** It matters because `UIO_SET_SDSTAT` is sent
  even when the open FAILED (with size 0), so from the core's side a failed mount
  and a real one are the same pulse. `/tmp/dvd_report.log` then says which
  happened, which is the difference between a Main-side and a core-side bug.

### Step 30 — slot 0 has more than one claimant

The optical drive shares slot 0 with every image the user can load, and
`dvd_phys.cpp` used to track only *"we mounted a disc at some point"*. Two field
bugs came out of that on an MGL launch with a disc in the drive:

- the drive auto-mounted on the first poll, so a `.mpg` named by the MGL waited
  minutes for CSS key extraction nobody asked for — on a disc that was then
  replaced by the file anyway;
- ejecting that disc unmounted the file that *was* playing (freezing it) and reset
  the core.

`dvd_phys_note_mount()` gives the module the one fact it was missing. The rules it
now follows are pinned by `main/tests/run_tests.sh` (host-side, no MiSTer needed),
which reproduces both symptoms against the pre-fix module.

⚠ It takes the **index** as well as the path. Main mounts `boot*.vhd` across slots
0–3 during init, and the drive only ever binds slot 0 — without the index a
`boot.vhd` in `games/DVD/` would read as a claim on the drive's slot and silently
disable physical-disc playback.
