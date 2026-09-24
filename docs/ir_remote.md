# IR remotes and media keyboards

Engineering note. Not the manual — the user-facing page is
`site/content/playback/controls.md`.

**Status: 🔧 sim/host-proven, ⏳ HW-confirm pending.** The hardware round needs a
Flirc on the rig; see §7.

---

## 1. The problem, measured

A user asked for a Windows Media Center remote (Rosewill RHRC-11002, eHome USB
dongle `147a:e03e`) to work on this core without remapping anything, and noted
that another user *"had to enable a kernel module on the MiSTer to get their
remote to show up, but the keycodes above 255 are not supported by the stock
MiSTer Main so he wasn't able to map many buttons."*

That report understates it. There are **three stacked ceilings**, all measured
against the pinned stock tree (`main/.build/Main_MiSTer`, ref `7317947`), not
recalled:

| # | Where | Effect |
|---|---|---|
| 1 | `input.cpp:3602` | `ev->code >= 256` is routed to the **joystick button** handler and never reaches the keyboard path at all — **39 of the 63 keycodes** an MCE receiver emits: Title, Subtitle, Audio, DVD, Info, Next/Prev, the whole numeric pad |
| 2 | `input.cpp:1409-1412` | `get_ps2_code()` returns `NONE` for `key > 255` — a second barrier behind the first |
| 3 | `input.cpp:367` | `ev2ps2[]` is 256 entries **and most media keys are `NONE` in it anyway**: PLAY, STOP, REWIND, FASTFORWARD, PLAYPAUSE, EJECTCD, EXIT, MEDIA |

**Net effect without this feature: arrows, Enter and volume work. Nothing else
does** — on any remote, not just Media Center ones.

★ **`KEY_PAUSE` is the sharpest single case and it is ceiling 3, not ceiling 1.**
`ev2ps2[119] = 0xE1` — the multi-byte PS/2 Pause sequence, which
`dvd/kbd_map.sv` deliberately never binds (a `0xE1` prefix is not a scancode the
decode table can match). So the most obvious button on the handset is inert for
a reason unrelated to the 255 ceiling everyone points at. Anyone who "fixes"
only the ceiling will find Pause still dead.

## 2. Why a Linux-keycode table is what makes "different flavours" true

The table is keyed on **Linux keycodes**, which is the vendor-neutral layer.
RC6-MCE handsets, NEC MCE clones, a Flirc's profiles, 2.4 GHz RF media remotes,
HDMI-CEC and plain USB media keyboards all converge on the same `KEY_*` set
before Main ever sees them. One table therefore serves all of them, and a new
remote protocol needs no code.

★★ **Confirmed on a second device class, so this is not an MCE-specific claim.**
A Nordic 2.4 GHz RF receiver (an ordinary "air mouse" dongle, three input nodes)
plugged into the development machine advertises **exactly the keycodes this
table covers** — `KEY_PLAY` 207, `KEY_FASTFORWARD` 208, `KEY_REWIND` 168,
`KEY_PLAYPAUSE` 164, `KEY_STOPCD` 166, `KEY_NEXTSONG` 163, `KEY_PREVIOUSSONG`
165, `KEY_STOP` 128, `KEY_BACK` 158, `KEY_HOMEPAGE` 172, `KEY_CONFIG` 171,
`KEY_RECORD` 167 — **and every one of them is `NONE` in `ev2ps2`** except volume
and mute. It also carries **75 keycodes ≥ 256**.

So a device that already enumerates perfectly on a stock MiSTer, needing no
kernel work at all, has a **completely dead transport section today**. That
widens the feature's reach well beyond Media Center remotes and is the strongest
argument for shipping it.

## 3. What this reaches, and what it does not

The dividing line is **not** the remote or the IR protocol. It is whether the
receiver reaches `/dev/input/event*` **without kernel IR support**.

### Works today; the remap is what makes it useful

| Receiver | Why |
|---|---|
| **Flirc USB** (`20A0:0001`) | Presents as a HID keyboard; learns any IR remote in its own firmware. **The one to recommend.** |
| 2.4 GHz RF media remotes | HID keyboard + Consumer Control. Not IR at all, identical from Main's side. |
| MCE dongles in **HID-keyboard mode** | Some ship switchable; that mode bypasses `rc-core` entirely. |
| Console-dock IR receivers (e.g. Retro Remake SuperDock) | HID keyboard. Already referenced in `CLAUDE.md`. |
| Any USB keyboard with media keys | Same keycodes, same fix. |

### Needs `CONFIG_RC_CORE` — not supported out of the box

⚠⚠ **Say "not supported out of the box". Never say "cannot work".**

| Family | Note |
|---|---|
| **eHome / MCE receivers** (`mceusb`) | **68 models across 27 vendors** in the kernel's own device table — Philips 9, Formosa 8, Hauppauge 7, SMK 6, TopSeed 6, Microsoft 2… The reporter's Rosewill dongle is one of them. |
| IguanaIR, USB-UIRT, Tira | Also need lirc userspace on top. |
| Motherboard CIR (`nuvoton-cir`, `ite-cir`, `fintek-cir`) | x86 only; irrelevant to a DE10-Nano. |

**MiSTer's kernel ships no IR support at all.** Measured on the rig
(5.15.1-MiSTer): `/lib/modules/.../kernel/drivers/` holds only `bluetooth`,
`hid` and `net`; `modules.dep` is 52 lines; a `find` for
`*mceusb*`/`*rc_core*`/`*ir_*`/`*lirc*` returns nothing; there is no
`/sys/class/rc`. `MiSTer_defconfig` says so explicitly —
`# CONFIG_RC_CORE is not set`, `# CONFIG_MEDIA_SUPPORT is not set` — matching
`/proc/config.gz` on the board.

⚠ **No kernel update fixes this, and this was checked on every line, not just
the rig's.** `MiSTer-v5.15` (5.15.1), `MiSTer-v6.18` (6.18.38) and `master`
(6.18.38) **all** carry both of those lines. `update_all` may well move a user to
6.18, which is worth doing for unrelated reasons, but it cannot make an eHome
receiver appear.

It cannot fall back to HID either. The dongle's second interface binds
`hid-generic`, but its report descriptor is

```
05 0c 09 00 a1 01 09 00 15 00 25 ff 75 08 95 08 b1 02 c0
```

— a Consumer Control collection with **one 8-byte FEATURE report and no INPUT
report**. It creates no input node. (Confirmed on the machine where the driver
*is* loaded.)

### The DIY route, and why it is worth documenting

A determined user **can** do it, and three measured facts make it tractable:
`CONFIG_MODULES=y`, `CONFIG_MODVERSIONS` **unset** and `CONFIG_MODULE_SIG`
**unset** — so only `vermagic` must match, with no symbol CRCs and no signing —
and the driver source is **already in MiSTer's own kernel tree** at its own
commit (`drivers/media/rc/`, 52 files, verified at the commit the user cited).
Build `rc-core`, `ir-rc6-decoder`, `rc-rc6-mce` and `mceusb` against that commit,
`insmod` them in order, persist through `/media/fat/linux/user-startup.sh`.

★★ **And the remap is what makes that path worth taking — which is the argument
for documenting it rather than dismissing it.** A user who loads those modules
against *today's* Main still gets 39 keycodes routed to the joystick handler and
most of the rest dropped in `ev2ps2`: arrows, Enter, volume, nothing else.
**The two halves compose.** Their kernel modules plus this normalisation is a
working MCE remote; neither alone is.

Honest cost of the DIY route: built per kernel line, and it breaks on a kernel
bump. Which is why §6 files an upstream request instead of shipping binaries.

## 4. The design

`main/support/dvd/dvd_ir.{h,cpp}` rewrites `ev->code` before Main's own
dispatch, into the ordinary keys `ev2ps2[]` already carries and
`dvd/kbd_map.sv` / `dvd/emu.sv` already bind.

> **No functional RTL change → this rides the currently released `.rbf`.** The
> only release asset that changes is `MiSTer_DVDcss`. Same property the physical
> VCD/SVCD feature had.
>
> ⚠ Stated precisely, because the loose version is an overclaim. The *feature*
> needs no netlist change, but CLAUDE.md makes setting `` `CORE_VERSION `` to
> `dev-<slug>` in the branch's first commit **mandatory**, and that macro is
> inside `CONF_STR` = inside the netlist. **Precedent settles it:** PR #117
> (physical VCD/SVCD) was also Main-only and its entire `dvd/emu.sv` diff was one
> line. So the slug bump happens here too, and it costs nothing **because no
> `.rbf` is cut from this branch** — nothing is re-fitted, so no seed is
> re-rolled. Do not write "no `CONF_STR` touch".

Rows are `{ from, to_play, to_osd, why }`.

- `to_osd == 0` means **pass through untouched** while the MiSTer OSD is open —
  never suppress. A row may legitimately want a different key there: Back should
  cancel a menu rather than go up a disc level.
- The `why` string is **load-bearing**, not a comment:
  `tools/check_ir_remap.py` parses it and asserts the core really does reach the
  button it names. See §5.

Placement of the hook is the subtle part and lives in
`main/integration/INTEGRATION.md` "Steps 50-53" — summarised: after the three
map-loading blocks (so `map[]`/`mmap[]` are populated and a user's own binding
can be detected on a device's *first* event), downstream of
`input[dev].kbdmap` (so an explicit `config/kbd_<vid>_<pid>.map` still wins),
and **upstream of the `ev->code >= 256` joystick split**, which *is* ceiling 1 —
a hook below that line applies cleanly, compiles, and fixes nothing.

### The ini key

`DVD_IR_REMAP`, **default on**. ⚠ `cfg` is `memset` to zero with no separate
defaults pass, so **0 must be the default-on value**: `0` = on for the DVD core,
`1` = off, `2` = on for every core — mirroring `DVD_HDMI_BITSTREAM`'s
`0=auto 1=off 2=force`.

⛔ **No OSD option.** `CONF_STR` is inside the netlist, so a menu row would
re-roll the pinned fitter seed for a setting nobody changes.

### The table

*Transport* — PLAY/PAUSE/PLAYPAUSE/PLAYCD/PAUSECD → `KEY_SPACE` (B1 Pause);
STOP/STOPCD → `KEY_Q` (B14); FASTFORWARD → `KEY_TAB` (B10);
REWIND/FASTREVERSE → `KEY_BACKSPACE` (B11); NEXT/NEXTSONG → `KEY_N` (B3);
PREVIOUS/PREVIOUSSONG → `KEY_P` (B2); EJECTCD/EJECTCLOSECD → `KEY_E` (B19).

*Navigation* — OK/SELECT → `KEY_ENTER` (B4, both columns);
EXIT/BACK → `KEY_B` playing, `KEY_ESC` in the OSD (B13 Return — `KEY_B` matches
integration step 41's CEC mapping); DVD/ROOT_MENU → `KEY_M` (B5);
TITLE/MEDIA_TOP_MENU → `KEY_T` (B12); CONTEXT_MENU → `KEY_F5` (B16);
MEDIA/HOMEPAGE/CONFIG → `KEY_MENU` (the MiSTer OSD, both columns);
NUMERIC_0..9 → `KEY_0`..`KEY_9`.

> ★ **`KEY_MENU` (139), not `KEY_F12`.** `user_io.cpp:4357` gates plain F12 on a
> modifier condition, while `KEY_MENU` takes the same branch unconditionally and
> is folded to F12 one line later. Same effect, one fewer dependency.

*A/V features* — INFO → `KEY_D` (B9); SUBTITLE → `KEY_S` (B8);
LANGUAGE/AUDIO → `KEY_A` (B7); FULL_SCREEN/ASPECT_RATIO → `KEY_Z` (B15);
ANGLE → `KEY_G` (B6); MEDIA_REPEAT → `KEY_L` (B17); SLOW → `KEY_DOT` (B18);
CHANNELUP/CHANNELDOWN → `KEY_N`/`KEY_P` playing, PageUp/PageDown in the OSD.

*Decision D3 — the four core functions with no natural remote button* go on
media-source buttons a US MCE handset physically has, and which mean nothing on
a DVD player: EPG (Guide) → B16 Chapter Menu; PVR (RecordedTV) → B17 A-B Repeat;
TUNER + TV (LiveTV) → B6 Angle; CAMERA (Pictures) → B18 Frame Step.

*Colour keys* RED/GREEN/YELLOW/BLUE → `KEY_F2/F3/F4/F1`
(Title/Audio/Subtitle/Menu), matching the CEC convention already in the manual —
**aliases only**. No function is parked solely on them, because the reporter's
handset does not have them.

⚠ **`KEY_ZOOM` *is* `KEY_FULL_SCREEN` and `KEY_SCREEN` *is* `KEY_ASPECT_RATIO`**
— aliases, not four codes. Listing all four would be a duplicate source row.
Caught by design; the test sweeps for it.

### The deny list, with reasons in the source

An omission is not a decision, so these are **listed** rather than merely absent
(`ir_deny[]`), and the checker asserts the table never claims one:

| Key | Why |
|---|---|
| MUTE, VOLUMEUP, VOLUMEDOWN | Main already drives the framework's **one** attenuator (`sys_top.v` `vol_att`, covering I2S, the analog DAC **and S/PDIF**) at `user_io.cpp:4266-4280`, from the OSD, `/dev/MiSTer_cmd` and HDMI-CEC volume keys. A second route would desync from the OSD bar and could not touch passthrough at all. |
| `KEY_MENU` | The OSD toggle, and many remotes' only route to it. |
| `KEY_DELETE` | Folded into the ctrl-alt-del reset combo. |
| POWER2, SLEEP | Never bind a power key to a media action. |
| RECORD | No core action. |
| BRIGHTNESSUP/DOWN | Main uses pseudo-codes `0xBE`/`0xBF`, not these. |

Also considered and **deliberately unbound**: RADIO, PLAYER, VIDEO, MODE,
PRESENTATION, MESSENGER, PRINT, NUMERIC_STAR/POUND, CLEAR, GOTO, LIST, CHANNEL,
SHUFFLE, RESTART, LAST, SETUP, CYCLEWINDOWS, VIDEO_NEXT. An unbound key is
honest; a wrongly bound one is a support ticket.

### Cross-compile guards

**Seven** `#ifndef` fallbacks — `KEY_ROOT_MENU` 0x26a, `KEY_MEDIA_TOP_MENU`
0x26b, `KEY_FASTREVERSE` 0x275, `KEY_FULL_SCREEN` 0x174, `KEY_ASPECT_RATIO`
0x177, `KEY_CONTEXT_MENU` 0x1b6, `KEY_MEDIA_REPEAT` 0x1b7 — covering toolchain
headers older than these codes. Motivated by `dvd_vcd.cpp`'s missing
`<limits.h>`, which was invisible to a host `g++` (glibc pulls it in
transitively) and caught only by the real ARM build.

★★ **AND THAT IS NOT HYPOTHETICAL HERE — THE CROSS-COMPILE CAUGHT A REAL ONE.**
The ARM toolchain's own UAPI header (`gcc-arm-10.2`) defines **446** `KEY_*`
names against this host's **527**, and `KEY_FULL_SCREEN` is one of the 81
missing. It shipped **unguarded** and **would not have compiled**, while every
host gate stayed green.

⚠⚠ **THE DURABLE LESSON, because I made the mistake first:** an earlier audit
swept all 126 `KEY_*` names the module uses and concluded *"none undefined and
unguarded — all six guards are pure future-proofing"*. **That audit read the
HOST header.** Portability must be checked against the toolchain that will build
the code, never the one you are typing on — which is exactly the thing a host
test cannot do and the reason this gate runs inside the container.

★ **It also turned the guard mechanism from a precaution into a measured one.**
Against the real ARM header:

| guard | ARM toolchain | host |
|---|---|---|
| `KEY_FULL_SCREEN` | **absent** | present |
| `KEY_ASPECT_RATIO` | **absent** | present |
| the other five | present | present |

So two of the seven are load-bearing on the build that ships, and five are
genuine future-proofing. ⚠ `KEY_ZOOM` *is* present on ARM at the same code
(0x174), so the guard is what keeps the two spellings interchangeable rather
than forcing the table to pick the older name.

⚠⚠ **The fallbacks are never exercised where they usually compile.** On any host
new enough to define the code, `#ifndef` makes the fallback dead — so a wrong
constant would compile cleanly, pass all 76 host assertions, and silently map
the wrong key on the only build that uses it.
`tools/tests/test_check_ir_remap.py` therefore compares each one against
`linux/input-event-codes.h`, RED-proven by a one-digit mutation.

⚠ **Finding the header is itself part of the gate.** The checker's first run in
the container died with *"no header on this machine"* — the ARM image carries no
host kernel headers. It now asks the cross-compiler
(`${CROSS_COMPILE}gcc -print-sysroot`) and prefers the **sysroot** copy, which is
both the one that exists there and the one the guards must actually agree with.
⛔ Never a hardcoded `/opt/...` path: the image tag is overridable
(`MAIN_DOCKER_IMAGE`) and a native toolchain lives somewhere else again.
`KEY_HEADER=` overrides; `CHECK_IR_VERBOSE=1` prints which copy was used.

## 5. Gates

| Gate | What it proves |
|---|---|
| `main/tests/dvd_ir_test.cpp` | 76 assertions, host `g++`, no MiSTer or Docker. 17 RED mutations in `run_tests.sh --red`, **each caught by its own named arm**. |
| `tools/check_ir_remap.py` | The derived-table gate. Run from `build_main.sh` with `--require-stock`. |
| `tools/tests/test_check_ir_remap.py` | 9 RED arms proving the checker can fail, and for the right reason; plus the fallback-constant comparison. |
| `tools/tests/test_ir_integration.py` | Rehearses steps 50-53 verbatim against copies of the real stock files and asserts the **placement**, with 2 RED arms that move the hook to the wrong places. |

★ **Why `check_ir_remap.py` exists at all.** The table asserts things about
three files it does not contain, and a restatement goes stale **silently** — the
remote simply stops doing what the manual says. So it *reads* them: `ev2ps2[]`
out of stock `input.cpp`, `dvd/kbd_map.sv`'s two `case` blocks after
`strip_comments()`, and `emu.sv`'s digit block and `J1,…` button list. Every
target must have a real scancode, must not be the `0xE1` sentinel, and must
reach the button its `why` string **names**.

⚠ **It parses `ev2ps2[]` by walking from its declaration to `};` — never a bare
grep.** Four more 256-entry tables in that file carry identical `//NNN KEY_x`
comments, and a grep would blend them.

★★ **It found a real error on its first run against real data:**

```
CHANNELUP -> KEY_PAGEUP claims "B3 Next Chapter" but reaches B2 Prev Chapter
```

Root cause was mine: the `why` string describes the **play** target, and I
applied the claim to both columns — but the OSD column never goes through
`kbd_map.sv` at all (with the OSD open, `user_io_kbd` hands the raw keycode to
`menu_key_set()`). The claim is now enforced on `to_play` only.

⚠ **`main/tests/` cannot see the cross-compile class of error at all** — it
never targets the ARM toolchain. `USE_DOCKER=1 main/build_main.sh` is the only
gate for that, and **its log must be read rather than its exit status**
(`build_main.sh` has exited 0 on a failed compile before, and exits 0 when the
Docker daemon is simply down).

★★ **It earned that on this very branch** — see the guards section above: it
rejected `KEY_FULL_SCREEN`, which no host gate could have. Status: the overlay
cross-compiles and links clean (stripped ARM EABI5 `MiSTer_DVDcss`).

## 6. Upstream (separate; does not gate the release)

Open a MiSTer_Linux issue/PR against **`master` / `MiSTer-v6.18`** (the live
line, 6.18.38 — not the 5.15 branch the rig runs) flipping
`arch/arm/configs/MiSTer_defconfig` from `# CONFIG_RC_CORE is not set` to
`CONFIG_RC_CORE=m` plus `CONFIG_RC_DECODERS`, `CONFIG_IR_RC6_DECODER=m`,
`CONFIG_RC_MAP=m`, `CONFIG_IR_MCEUSB=m`. The driver source is already in their
tree.

Frame it as **generic input support, not media playback**: `=m` costs nothing at
boot for users without a receiver, and it lets **any** core take an IR remote.

⛔ **No binary kernel modules shipped from here** (decision D4) — they would have
to be rebuilt per kernel line and would break on a bump.

## 7. Hardware round — the only things sim cannot settle

On the rig with the Flirc (`flirc.tv flirc Keyboard`, `20A0:0001`), via the
`hil-testing` skill. ⚠ **Announce first — the rig is shared.**

1. **`evtest` the Flirc first** and record which keycodes each remote button
   actually emits under the profile in use. The table is keyed on keycodes, and
   only the device can say which it sends.
2. Transport sweep on a real disc.
3. Digits into a disc menu.
4. **The OSD round trip** — Start opens, arrows navigate, OK confirms, Back
   closes. The one path with no bench at all.
5. **The regression arm**: bind a key via Define buttons, confirm it still wins
   and can still be captured.
6. `DVD_IR_REMAP=1` kills every rewrite.
7. A plain USB keyboard unregressed.

Not confirmable on this rig, and to be said so in the docs: eHome/`mceusb` (no
kernel support) and HDMI-CEC (that board's CEC engine never completes a frame —
`CEC: no clock detected`).

⚠ **Held keys do not repeat.** `user_io.cpp:4114` drops autorepeat for the 8-bit
core path, consistent with `kbd_map.sv`'s pulse-only design. Expected, not a
defect — do not "fix" it.

## 8. Decisions

| # | Decision |
|---|---|
| D1 | `MiSTer.ini` key `DVD_IR_REMAP`, default on. No OSD option (it would re-roll the seed). |
| D2 | Green Start (`KEY_MEDIA`) opens the **MiSTer OSD**. |
| D3 | Spare core functions go on media-source buttons a US MCE handset has: Chapter Menu ← Guide, A-B Repeat ← RecordedTV, Angle ← LiveTV, Frame Step ← Pictures. Colour keys are aliases only. |
| D4 | Ship the remap now; open a MiSTer_Linux defconfig request separately. **No binary kernel modules.** |
| D5 | Document the Flirc setup in the manual; no shipped `.fcfg`. |
