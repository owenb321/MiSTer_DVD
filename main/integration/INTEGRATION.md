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

and replace the opening `if (x2trd_ext_supp(name))` of the mount dispatch with:

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

## MiSTer.ini (end user)

```
[DVD]
main=MiSTer_DVDcss
```
