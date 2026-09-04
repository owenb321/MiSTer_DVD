# MGL launch — how it works, and how it broke (issue #48)

Engineering note, not user documentation. The user-facing page is
`site/content/getting-started/loading.md`.

An **MGL** is MiSTer's shortcut format: a small XML file in the SD root or a `_menu`
folder that loads a core and then mounts a file into it. Users make one per movie so
the DVD core appears in their menu next to everything else.

```xml
<mistergamedescription>
  <rbf>_Other/DVD</rbf>
  <file delay="5" type="s" index="0" path="/media/fat/cifs/games/DVD/Movies/Terminator.mpg"/>
</mistergamedescription>
```

Issue #48 reported that this produced "a grey or green screen" and a MiSTer that was
"completely unresponsive" and had to be restarted, while the same file played when
picked by hand from **Load Video**.

---

## 1. The launch timeline

`user_io_init()` is identical for both flows. The only thing it does differently for an
MGL is parse it and arm a timer at the very end, *after* the core's reset is released:

| t | what happens |
|---|---|
| — | `user_io_status_set("[0]", 1)` — core held in reset |
| — | `cfg_parse()`, `video_init()`, first cfg word (`UIO_BUT_SW`) |
| — | `mgl_parse(xml)` |
| — | saved `DVD_v2.CFG` pushed as the status word |
| — | `boot.rom` download (the idle logo — **this happens for an MGL too**) |
| **0** | `user_io_status_set("[0]", 0)` — reset released; `mgl->timer = delay × 1000` |
| 0.9–1.0 s | the core pulses its virtual OSD button (`BUTTONS[0]`, `dvd/emu.sv`) |
| **delay** | `mgl->state 0 → 1` |
| delay | `MENU_NONE2` sees `state == 1`, opens the main menu **invisibly** (`OsdDisable`), `state → 2` |
| delay | the menu render matches `S0,…,Load Video` and records `submenu = 0` |
| delay | `MENU_GENERIC_MAIN2` forces `menusub = 0` and `select = 1`, dispatches |
| delay | `MENU_GENERIC_IMAGE_SELECTED`: `user_io_set_index(0x01)`, `user_io_file_mount(path, 0)` |
| delay | `mgl->state = 3` → `mgl->done = 1` |

**The dispatch itself is sound for this core.** `type="s" index="0"` matches the S0 row
at `selentry 0`, `user_io_ext_idx` resolves `.mpg` to extension 0, the index byte is
`0x01` in both flows, and `make_fullpath()` passes an absolute path through unchanged.
Nothing about the MGL format needed to change.

---

## 2. The rule that matters: a running MGL owns the whole UI

```c
// menu.cpp, HandleUI()
if (!mgl->done) { switch (mgl->state) { … } }
else            { c = menu_key_get(); }
```

`menu_key_get()` is the **sole source of every input event** — the keyboard menu key,
the gamepad menu key, the physical OSD button, and the core's own virtual one (the
`KEY_F12|UPSTROKE` synthesis lives inside it). So while `mgl->done == 0`, the MiSTer
accepts no input at all.

And the MGL cannot finish on its own. States 1 and 2 have **no handler in the MGL
switch**; they are advanced only by the `menustate` FSM, and there is no timeout and no
watchdog. The single forward edge out of state 1 is:

```c
else if (menu || (is_menu() && !video_fb_state())
              || (menustate == MENU_NONE2 && !mgl->done && mgl->state == 1))
```

It requires `menustate` to be **literally `MENU_NONE2`**. `menu` is permanently false,
because producing it needs `menu_key_get()`.

> ### ⚠ Never raise `Info()` / `InfoMessage()` / `ProgressMessage()` from a `user_io_poll()` tick while `mgl_get()->done == 0`.
> Check `dvd_launch_ui_busy()` first and defer.

`InfoMessage()` pins `menustate = MENU_INFO` whenever `menustate <= MENU_INFO`
(`MENU_NONE1=0, MENU_NONE2=1, MENU_INFO=2`) and calls `HandleUI()` re-entrantly. Two of
our own overlay pumps called it once a second from `user_io_poll()`, *before* `HandleUI`
runs:

- `dvd_css.cpp` `dvd_css_tick()` — 8 s window, armed when an encrypted disc is opened
  without libdvdcss.
- `dvd_hdmi_audio.cpp` `report_pump()` — 6 s per arm, **re-armed on every stage
  transition**, and the stage is recomputed against `hdmi_config_init()`'s generation and
  the scaler re-init a mount itself provokes.

A `delay="5"` MGL fires its state-1 transition squarely inside those windows. Nothing
mounted, nothing responded, and the only way out was the power switch.

**This is why MGL misbehaved on this core and not on stock ones.** The pumps are ours.

Both now hold their window open rather than spending it, so the notice still appears
once the launch settles — which is what those pumps were written to do in the first
place. `dvd_launch_tick()` adds a 20 s watchdog on top: not the fix, a floor under it,
so a stall we have not thought of costs a failed load instead of a reboot.

⚠ Two comments in those files described `InfoMessage` as "no-oping" or being "dropped"
when the menu FSM is busy. For the *idle* case that is exactly backwards, and believing
it is what let this ship. Both are corrected in place.

---

## 3. Reading the screen: grey vs green vs black

Traced through `rtl/mpeg2/mixer.v` → `rtl/mpeg2/yuv2rgb.v` (SMPTE-170M coefficients,
`cy = 38155`). This is a genuinely reusable diagnostic — it splits three different bugs
apart before any instrumentation is added.

| colour | RGB | what it means |
|---|---|---|
| **black** | (0,0,0) | nothing is scanning at all — the reader is wedged or the decoder is held in reset. `mixer` emits Y=16, U=V=128 when not displaying. |
| **green** | (0,136,0) | a framestore slot is being scanned that was **never written** (Y=Cb=Cr=0). References were never established, or a flush left a slot flagged valid. |
| **grey** | (130,130,130) | an **intra picture was decoded out of mis-framed bytes**. MPEG-2 resets the intra DC predictor to 128 at every slice, so an I-picture whose coefficients never decoded reconstructs flat mid-grey. Strongly indicates `ps_demux` framing. |

The `mode_realign` switch blank is **not** a candidate for any of these: it has a hard
~1.5 s ceiling (`BLANK_MAX`), is cleared on `start_streaming`, is gated off before the
first mount, and produces black.

---

## 4. The core-side defects the launch exposed

Neither is MGL-specific in mechanism; an MGL just makes them far more likely, because it
mounts a cold path seconds after boot instead of after the user has walked the file
browser over that same directory (`ScanDirectory` warms the CIFS dentry cache; the MGL
flow's `FileOpenEx` is the first access).

### 4.1 A mount with no media was treated as a mount

`user_io_file_mount()` sends `UIO_SET_SDSTAT` even when the open failed, with
`sd_image[].size` zeroed, and `hps_io.sv` raises `img_mounted` for an all-zero status
word — which is also how an **eject** arrives. So the pulse means "the slot changed",
not "there is media".

`disc_ever` in `dvd/emu.sv` always guarded on `img_size != 0`. `start_streaming` and
`media_seen` did not, so a failed mount killed the idle logo (and its file picker with
it), flipped `VIDEO_ARX/ARY`, and started the reader on a zero-length image. In the
reader, `total_blocks == 0` took the "< 17 sectors" branch and wrote a zero-length
extent, which `S_STREAM`'s `strm_blk + 1 == ext_blocks_q` terminator can never satisfy —
so it walked LBA 0,1,2,… of an empty slot indefinitely.

And it could not be reported: `img_unplayable`'s window only advances while
`img_streaming`, which needs sector data to be arriving. A reader that requests and
receives nothing silences the one notice that would have named the problem. **A blank
screen with no message means delivery stopped, not that decode failed.**

Fixed in three places, deliberately: `start_streaming` gated on `img_size` and a new
`img_ejected` clearing `media_seen` (guarded on the delivery/picture signals `logo_vis`
already uses, so a failed mount cannot flip `VIDEO_ARX` out from under live content);
`S_INIT` sending a zero-block image to `S_DONE`; and the terminator relaxed to `>=`.

### 4.2 `S_ES_PASS` was terminal

`ps_demux` decides "this is a bare `.m2v`, not a program stream" from the first start
code after a pipe reset — and `ever_seen_pack` is cleared by **every** `load_flush`, so
that verdict is retaken after each one. A flush does not always land on a pack boundary:
the in-place `mode_switch` fallback (`dvd/mode_realign.sv`) flushes without moving the
reader at all, which is *more* likely right after a mount because it is chosen when
`lin_seek_ok_w` is 0, and that depends on `ps_saw_pack`, which the mount's own flush just
cleared.

Landing mid-PES on `00 00 01 B3` latched raw-ES mode for the rest of the title and handed
PES headers, audio, subpicture and NAV packs to the video decoder — the grey picture,
with no self-recovery from any seek or watchdog.

The state now leaves on `00 00 01 BA`. A genuine bare elementary stream cannot contain
one: start codes `0xB9`–`0xFF` are system codes, illegal inside a video ES, and MPEG-2
forbids start-code emulation in the payload. The four bytes of the pack code that raw-ES
mode had already forwarded are left to leak on purpose — the first three went out on
earlier cycles, so suppressing only the `BA` would emit a headless `00 00 01` and the
decoder would swallow the next real byte as its code. A complete `0xBA` is a system start
code the VLD's start-code walk skips.

This also subsumes the alternative of arming the reader's `hunt_active` on the in-place
`mode_switch`: the demux now re-syncs on the next pack either way, without touching the
reader, and the garbage between flush and pack is bounded by one pack.

### 4.3 Two latches that did not do what their comments said

- **The virtual OSD button could stick high.** `osd_wait` advances only while `status[0]`
  is low, but `osd_btn` was a pure decode of the counter — so a reset inside the
  `[FIRE, END)` window froze the count with the button *held*, and Main reads a ≥3 s hold
  as "enter Bluetooth pairing". Now gated on `~status[0]`, so the button is high exactly
  while it is counting.

  Related, and worth knowing: `disc_ever` can only suppress a mount that lands *before*
  the window, so the pulse **always** goes out on an MGL launch. Main swallows it —
  during an MGL `menu_key_get()` never runs, which is where the press becomes `KEY_F12` —
  so it is benign, but benign by someone else's accident rather than by design. The old
  comment's "any mount cancels it" was too strong.

- **`analog_want_l`'s "freeze while a disc is mounted" never froze.** It gated on
  `img_mounted[0]`, which is a one-transaction *pulse* (cleared on `~io_enable`), not a
  level — so the latch tracked the cfg word for ever, mid-title included, and the freeze
  its comment described was never implemented. Main re-sends cfg on every
  `video_mode_adjust`, including the one the mount's own `VIDEO_ARX` flip provokes, so a
  changed ini bit could fire a live `il_switch` under playing content: the failure class
  of issue #42. `media_seen` is the level that was meant.

---

## 4.4 The optical drive fights for the same slot

Reported after the first fix landed: an MGL for a `.mpg` *worked*, but with a disc
in the drive it waited for key extraction first — and removing that disc froze the
`.mpg` and left the core unable to reach the idle screen.

Both come from `dvd_phys.cpp` treating slot 0 as its own. It is not: the drive
shares it with every image the user can load.

- **`dvd_phys_tick()` auto-mounted on the very first poll.** An MGL's `<file>`
  lands `delay` seconds later, so the drive won that race every time. On an
  encrypted disc that is minutes of `crack_title_keys()` — synchronous, blocking
  `user_io_poll()` — for a disc the MGL then replaces anyway.
- **`mounted` meant "we mounted a disc at some point", not "we still own the
  slot".** After any later mount took slot 0, an eject still ran the teardown:
  `user_io_file_mount("", 0)` closed the file that *was* playing (so the reader
  starved — the freeze) and pulsed `status[0]`.

New `dvd_phys_note_mount(path, index)`, called from `user_io_file_mount()`
(integration step 30), supplies the missing fact. The rules now:

| condition | auto-mount? | eject tears down? |
|---|---|---|
| nothing in the slot, disc ready | ✅ | ✅ |
| an MGL launch is pending (`dvd_launch_ui_busy()`) | ❌ deferred | — |
| a file the user asked for is in the slot (`foreign`) | ❌ | ❌ |
| the disc was already sitting there when the file loaded | ❌ | ❌ |
| a disc is **inserted** while a file plays | ✅ (insertion edge clears `foreign`) | ✅ |

★ **Every reason not to mount is checked before `dvd_video_probe()`**, which is the
first thing that actually reads the disc. "Do no disc operations when we were
launched to play a file" has to mean no *reads*, not just no mount — otherwise a
spinning drive is probed once a second for the whole session. A non-DVD-Video disc
(an audio CD) is likewise probed once per insertion, not once per scan.

★ **The insertion EDGE, not the level, clears `foreign`.** Putting a disc in is a
deliberate act and the auto-mount is the only way to play one, so an insertion
still wins; a disc merely *sitting* in the drive never takes the slot back from an
image the user chose. Readiness is the edge, so it costs one ioctl and reads
nothing.

⚠ The eject path also pulses `status[0]` and releases it ~1 s later from
`reset_release_at`. That release is unconditional, so an OSD Reset pressed inside
that window would be cancelled by it. Much harder to reach now that the teardown
only runs for a disc the drive still owns, but it is not *impossible* and it is a
candidate if "Reset does nothing" is ever reported.

## 5. Gates

- `bench/dvd/run_mgl.sh` — `iso_reader_mount_tb` (RED: 10 reads against an empty slot,
  still in `S_STREAM`; GREEN: 0 reads, `S_DONE`) and `ps_demux_esrecover_tb` (RED: 48
  video bytes and **0 audio bytes** after the next pack; GREEN: 12 and 4). Both measure
  what the hardware *does* — requests issued, bytes demuxed onto which port — not a
  signal the fix names, so neither can agree with its own RTL by construction. Each
  carries a control arm against over-reach.
- ⚠ `iso_reader_mount_tb` ships its **own mock HPS, which polls**. The mock in
  `iso_reader_tb.sv` and its clones latches the request on the first cycle `sd_rd` is
  high and always serves it; the real `hps_io` picks requests up by polling command
  `'h16` at Main's poll rate, so a request withdrawn in between is simply lost. Without a
  polling mock, the "mount over an in-flight read" arm is a bench that cannot fail.
- `main/tests/run_tests.sh` — host-side (plain `g++`, no MiSTer, no ARM toolchain,
  no Docker). `dvd_phys_test.cpp` includes the module and stubs the rest of Main at
  link time, so it exercises the real logic. Seven scenarios; RED against the
  pre-fix module reproduces **both** field symptoms (disc read and mounted during
  the MGL delay; eject unmounting and resetting over a playing file). [4]–[6] are
  controls: every one of these bugs is trivially "fixed" by never mounting a disc.
  ⚠ The module carries exactly one `#ifdef DVD_PHYS_TEST`, around `open_ready_drive`
  — a real `/dev/srN` cannot be faked (a regular file opens fine and then fails
  `CDROM_DRIVE_STATUS`). Everything else is an ordinary extern.
- The rest of the Main-side half is not simulatable. It is gated on hardware, and
  `/tmp/dvd_report.log` now records what each mount achieved
  (`dvd_report_note_mount_result`) precisely so the next round is not another guess.

## 6. Reproducing

1. Put an MGL like the one above in `/media/fat/_Other/`, pointing first at a local
   `.mpg`, then at a CIFS path.
2. Launch it and collect `/tmp/dvd_report.log`, `/tmp/dvd_css.log`, and Main's console
   (`F9`). The console prints `MGL <path>` with the parsed item, `Image selected: …`, and
   either `Mount … on 0 slot` or `Failed to open file …`.
3. Note the **colour** (§3) — it splits a wedged reader from a mis-framed demux before
   anything else is measured.
4. Expected after the fix: the OSD comes back within 20 s even if the load fails, and a
   failed mount returns to the bouncing idle logo with the file picker, never a silent
   grey field.

## 7. The CSS progress bar, and which mounts keep it

`crack_title_keys()` reports through `ProgressMessage()` → `InfoMessage()`. Two properties
of `InfoMessage` decide whether that bar is seen, and only one of them is about the OSD:

```c
void InfoMessage(const char *message, int timeout, const char *title)
{
    if (menustate <= MENU_INFO)                       //  ← the gate that matters
    {
        if (menustate != MENU_INFO) { OsdSetTitle(title, 0); OsdEnable(OSD_MSG); }
        …
```

It **re-enables the OSD itself**, so the `OsdDisable()` an MGL performs when it opens the
menu invisibly does *not* hide the bar. What hides it is the `menustate <= MENU_INFO`
guard (`MENU_NONE1 = 0, MENU_NONE2 = 1, MENU_INFO = 2`).

| mount | `menustate` while cracking | bar |
|---|---|---|
| **physical disc** (`dvd_phys_tick` → `dvd_css_open`) | `MENU_NONE1` — it mounts on the **very first** `user_io_poll()`, before HandleUI has run at all and long before an MGL's `delay` expires | ✅ visible |
| `.iso` picked by hand (`dvd_css_open_image`) | `MENU_NONE1`, via the file browser's `MenuHide()` | ✅ visible |
| **`.iso` mounted by an MGL** | `MENU_GENERIC_IMAGE_SELECTED` — the mount happens *inside* that case | ❌ `InfoMessage` no-ops |

So a **physical disc keeps its progress bar on an MGL launch**; only an encrypted `.iso`
that the MGL itself mounts loses it. Keys cache, so that is once per disc. Not fixed:
making it visible means driving `menustate` from a support module mid-dispatch, which is
more Main-internal surgery than a cosmetic bar is worth.

⚠ An earlier version of this note blamed `OsdDisable()`. That was wrong — the conclusion
happened to be right for the `.iso` case, which is exactly how a wrong mechanism survives.

### ⚠ Why the watchdog measures ticks, not wall clock

The same crack is why `dvd_launch_tick()` discounts gaps between its own invocations.
`crack_title_keys()` is **synchronous inside `user_io_file_mount()`** and blocks
`user_io_poll()` for minutes on an uncached disc. A physical disc mounts on the first poll,
so with plain wall-clock timing the next tick would see minutes elapsed, call a
still-pending MGL stalled, and destroy the user's auto-load — a watchdog killing the thing
it was added to protect. A gap between ticks means the loop was not running, so it cannot
be time the MGL spent stuck.
