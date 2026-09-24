#!/usr/bin/env bash
#
# run_tests.sh — host-side tests for the MiSTer_DVDcss overlay modules.
#
# These are ordinary native builds: no ARM toolchain, no MiSTer, no Docker. Each
# test #includes the module under test and stubs the rest of Main at link time,
# so it exercises the real logic rather than a paraphrase of it.
#
#   ./run_tests.sh          GREEN only
#   ./run_tests.sh --red    + mutations, each caught by the test written for it
#
set -e
cd "$(dirname "$0")"

RED=0
[ "${1:-}" = "--red" ] && RED=1

CXX="${CXX:-g++}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# Stage the overlay where its own relative includes resolve. dvd_phys.cpp reaches
# for "../../user_io.h"; an EMPTY file there is deliberate -- the test defines the
# handful of Main functions it needs before including the module, so they are
# already in scope and there is no second copy of Main's API to drift out of date.
TREE="$OUT/tree"
mkdir -p "$TREE/support/dvd"
cp ../support/dvd/*.cpp ../support/dvd/*.h "$TREE/support/dvd/"
: > "$TREE/user_io.h"
: > "$TREE/menu.h"
: > "$TREE/video.h"
: > "$TREE/cfg.h"
: > "$TREE/hardware.h"
: > "$TREE/osd.h"
: > "$TREE/file_io.h"
# dvd_remote.cpp reaches for these two as well (spi_uio_cmd_cont/spi_w, and
# set_volume -- the framework's ONE attenuator).
: > "$TREE/spi.h"
: > "$TREE/audio.h"

fail=0
for t in *_test.cpp; do
    n="${t%.cpp}"
    echo "### $n"
    "$CXX" -std=c++11 -Wall -Wno-unused-function -O0 -g -pthread \
        -I "$TREE/support/dvd" -o "$OUT/$n" "$t"
    "$OUT/$n" || fail=1
    echo
done

# ---------------------------------------------------------------------------
# RED arm. A decision table is exactly the shape that passes without proving
# anything, so each mutation must be caught BY ITS OWN test -- one caught only by
# some unrelated assertion leaves the intended arm vacuous. A mutation that fails
# to COMPILE is a harness failure, not a pass: it proves nothing about the test.
red_case() {
    local mod="$1" test="$2" expect="$3" sedexpr="$4" name="$5"
    local dir="$OUT/red_$name"
    cp -r "$TREE" "$dir"
    sed "$sedexpr" "$TREE/support/dvd/$mod" > "$dir/support/dvd/$mod"
    if cmp -s "$TREE/support/dvd/$mod" "$dir/support/dvd/$mod"; then
        echo "  !! RED $name: mutation matched nothing (the anchor moved)"; fail=1; return
    fi
    if ! "$CXX" -std=c++11 -Wall -Wno-unused-function -O0 -g -pthread \
            -I "$dir/support/dvd" -o "$dir/bin" "$test" 2>"$dir/build.log"; then
        echo "  !! RED $name: mutant did not compile"; sed -n '1,4p' "$dir/build.log"
        fail=1; return
    fi
    local log="$dir/log"
    "$dir/bin" > "$log" 2>&1 && { echo "  !! RED $name: test PASSED against broken code"; fail=1; return; }
    # -e: an expect string may legitimately START with "--" (a CLI flag being
    # asserted present or absent), which grep would otherwise read as an option.
    if ! grep -q -e "$expect" "$log"; then
        echo "  !! RED $name: caught, but not by \"$expect\""
        grep -e "FAIL" "$log" | head -3; fail=1
    else
        echo "  RED $name -> caught by \"$expect\""
    fi
}

if [ "$RED" -eq 1 ]; then
    echo "### RED arm"

    # ---- dvd_phys: the eject button, both reported symptoms --------------
    # "eject does not eject the disc, instead it reloads it... we see the key
    # cracking message again and the disc starts over."
    red_case dvd_phys.cpp dvd_phys_test.cpp \
        "does NOT re-mount the disc still in the tray" \
        "s/^\tforeign = 1;$/\tforeign = 0;/" \
        phys-eject-remounts

    # The tray asked to open while the CSS session still holds /dev/srN, which
    # the kernel refuses -- so nothing ejects.
    red_case dvd_phys.cpp dvd_phys_test.cpp \
        "tray opened AFTER the unmount" \
        "s/^\tteardown_to_idle(now);$/\t;/" \
        phys-eject-order

    # ---- dvd_cdda: the drive fd's lifecycle ------------------------------
    # The fd handed to dvd_cdda_open() is OURS from then on. Dropping it without
    # closing leaks one descriptor on /dev/srN per mount, and the kernel then
    # refuses CDROMEJECT with EBUSY: on the rig this read as "eject unmounts the
    # disc and returns to the idle logo, but the tray never opens". Nothing
    # exercised the fd lifecycle before 2026-09-22, which is why it shipped.
    red_case dvd_cdda.cpp dvd_cdda_test.cpp \
        "the fd was closed exactly once" \
        "s/^\tif (g_fd >= 0) close(g_fd);$/\t;/" \
        cdda-fd-leak

    # ---- dvd_remote: the Eject/Volume request protocol -------------------
    # Every one of these is a way the polled protocol degrades into "acts on a
    # level", which is what makes one press eject repeatedly.
    red_case dvd_remote.cpp dvd_remote_test.cpp \
        "first word: no eject" \
        "s/\t\thave_ref = 1; ref_eject = e; ref_volup = u; ref_voldn = d;/\t\thave_ref = 1;/" \
        remote-no-baseline

    red_case dvd_remote.cpp dvd_remote_test.cpp \
        "the other flip ejects too" \
        "s/\tif (e != ref_eject)/\tif (e \&\& !ref_eject)/" \
        remote-eject-level

    red_case dvd_remote.cpp dvd_remote_test.cpp \
        "three presses between polls -> three steps" \
        "s/\twhile (nu--) set_volume(VOL_CMD_UP);/\tif (nu) set_volume(VOL_CMD_UP);/" \
        remote-vol-one-step

    red_case dvd_remote.cpp dvd_remote_test.cpp \
        "and it is -1 (quieter)" \
        "s/#define VOL_CMD_DOWN  (-1)/#define VOL_CMD_DOWN  (+1)/" \
        remote-vol-both-up

    red_case dvd_remote.cpp dvd_remote_test.cpp \
        "a huge gap is capped" \
        "s/\tif (nu > VOL_MAX_PER_POLL) nu = VOL_MAX_PER_POLL;//" \
        remote-no-cap

    red_case dvd_remote.cpp dvd_remote_test.cpp \
        "no v3 bit: no eject" \
        "s/if (magic != DVD_TELEM_MAGIC || !AF_V3(w))/if (magic != DVD_TELEM_MAGIC)/" \
        remote-ignores-version

    # ⚠ single-line anchor: sed works line by line, so a pattern containing \n
    # matches NOTHING and red_case reports "the anchor moved". The two tabs pin
    # this to the EJECT gate rather than the volume one a line earlier.
    red_case dvd_remote.cpp dvd_remote_test.cpp \
        "launch busy: no eject" \
        "s/^\t\tif (!dvd_launch_ui_busy())$/\t\tif (1)/" \
        remote-launch-gate

    # The reported bug itself: nothing restores the transmitter, so the next core
    # inherits a non-PCM link and plays silently.
    red_case dvd_hdmi_audio.cpp dvd_hdmi_audio_test.cpp \
        "teardown did not write the PCM registers" \
        "s/\tif (!chip_nonpcm) return;/\treturn;/" teardown-noop

    # Teardown keyed on the ack instead of the chip. Correct everywhere EXCEPT the
    # 50 ms release window, where the ack is already down and the chip is not --
    # which is the whole reason chip_nonpcm exists as a separate flag.
    red_case dvd_hdmi_audio.cpp dvd_hdmi_audio_test.cpp \
        "chip after teardown in the window" \
        "s/\tif (!chip_nonpcm) return;/\tif (!acked) return;/" teardown-keyed-on-ack

    # Ignore the version flag: an idle v2 core reads as "not PCM" and the link is
    # claimed with nothing playing -- the shipped behaviour this fixes.
    red_case dvd_hdmi_audio.cpp dvd_hdmi_audio_test.cpp \
        "chip left in PCM" \
        "s/return core_fmt_v2 ? core_bs_session : !core_pcm_session;/return !core_pcm_session;/" \
        ignores-fmt-version

    # ...and the other way: assume every core reports bs_session, and a core built
    # before it can never engage at all.
    red_case dvd_hdmi_audio.cpp dvd_hdmi_audio_test.cpp \
        "acked (old core still engages)" \
        "s/core_fmt_v2      = (fmt >> 15) \& 1;/core_fmt_v2      = 1;/" assumes-fmt-version

    # ---- dvd_css: where a title key is asked for -------------------------------
    # The shipped-until-now behaviour, restored exactly: re-key on ANY
    # discontinuity, at the read LBA. libdvdcss caches title keys by EXACT block,
    # so every chapter start misses and re-acquires -- a full crack on a drive with
    # no region, which is the reported multi-minute freeze.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "title keys acquired over 17 chapter skips" \
        "s/^\t\tif (vi != cur_vob)$/\t\tif (vi != cur_vob || (int)lba != css_pos)/; s/(int)g_vobs\[vi\]\.start, DVDCSS_SEEK_KEY/(int)lba, DVDCSS_SEEK_KEY/" \
        css-rekey-every-seek

    # Key at the read position but only on a VOB change. Subtler, and it survives
    # the chapter-skip arm untouched -- the cost moves to every VOB crossing, where
    # the landing block is no more cached than a chapter start was.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "title keys acquired crossing VOBs" \
        "s/(int)g_vobs\[vi\]\.start, DVDCSS_SEEK_KEY/(int)lba, DVDCSS_SEEK_KEY/" \
        css-key-at-read-lba

    # Stop latching the verdict. The failing read still falls back to a raw read,
    # but cur_vob advanced anyway, so the NEXT sequential read skips the block and
    # decrypts with a key that was never obtained -- garbage, not raw data.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "decrypted reads after the key seek failed" \
        "/if (!key_ok) decrypt = 0;/d" \
        css-key-verdict-not-latched

    # CONTROL, and the one that matters most: every bug above is trivially "fixed"
    # by never asking for a key at all, which silently stops decrypting.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "SEEK_KEY calls over three VOB crossings" \
        "s/key_ok  = (p_seek(css, (int)g_vobs\[vi\]\.start, DVDCSS_SEEK_KEY) >= 0);/key_ok  = 1;/" \
        css-never-keys

    # ---- dvd_css: the VOB table (issue #112) -----------------------------------
    # Expect strings start with "FAIL " so a passing "ok" line of the same check
    # cannot satisfy them.
    #
    # The shipped behaviour, restored: 64 entries, no alias collapsing. OZ's 91
    # entries overflow, VTS_20 is never registered, and its sectors are read raw --
    # the green garbage + CSS ENCRYPTED the maintainer reproduced on the rig.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "FAIL VTS_20 sneak peeks resolve to a VOB" \
        "s/^#define MAX_VOBS 1024$/#define MAX_VOBS 64/; s/return;   \/\/ alias/;   \/\/ alias/" \
        css-vob-table-shipped

    # Aliases no longer collapsed. OZ still fits a 1024 table, so it plays -- but
    # every alias is keyed again at mount (91 SEEK_KEYs, not 21).
    red_case dvd_css.cpp dvd_css_test.cpp \
        "FAIL SEEK_KEY calls priming the disc" \
        "s/return;   \/\/ alias/;   \/\/ alias/" \
        css-no-alias-collapse

    # Collapsing kept, old cap: OZ fits (21), a spec-maximum disc does not.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "got 64, want 991" \
        "s/^#define MAX_VOBS 1024$/#define MAX_VOBS 64/" \
        css-cap-64

    # The drop goes uncounted -- the silence that let #112 ship.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "FAIL distinct extents counted as dropped" \
        "s/^\t\tg_vobs_dropped++;$//" \
        css-drop-silent

    # ---- dvd_css: every window comes back full --------------------------------
    # The shipped behaviour: stop at the VOB clamp and return short. Main then caches
    # the whole window, so its tail serves the PREVIOUS window's sectors -- up to 7
    # stale sectors at every linear crossing of a 1 GB VOB part boundary.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "FAIL stale sectors left in the window" \
        "s/^\t\tdone += (uint32_t)n;$/\t\tdone += (uint32_t)n; break;/" \
        css-short-window

    # An unreadable tail left as-is is the same stale-sector hole by another route.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "FAIL unreadable tail is zero-filled" \
        "/memset(p + (size_t)done \* 2048, 0/d" \
        css-tail-not-zeroed

    # A failed FIRST sector reported as success: Main would cache a window of zeros
    # and never retry it.
    red_case dvd_css.cpp dvd_css_test.cpp \
        "FAIL window whose first sector is unreadable fails" \
        "/if (done == 0) return -1;/d" \
        css-head-failure-hidden

    # ---- dvd_readahead: the RAM ring between the disc and the core ---------------
    # A burst in flight when the core seeks completes for the OLD position; kept, it
    # is stored and counted under the new one -- the landing is someone else's data.
    red_case dvd_readahead.cpp dvd_readahead_test.cpp \
        "FAIL landing sectors that are not what they claim" \
        "s/if (stop_req || g != gen) continue;   \/\/ retargeted/if (stop_req) continue;   \/\/ retargeted/" \
        ra-keeps-stale-burst

    # A window whose head is in the ring but whose tail is not, served as whole:
    # the stale-sector defect dvd_css_read was just fixed for, one layer up.
    red_case dvd_readahead.cpp dvd_readahead_test.cpp \
        "FAIL a window reaching past the fill" \
        "s/if (lba >= base \&\& end <= base + fill) return 1;/if (lba >= base \&\& lba < base + fill) return 1;/" \
        ra-serves-partial

    # The consumer never frees room: the worker parks once the ring is full and
    # playback stops dead one ring-length in.
    red_case dvd_readahead.cpp dvd_readahead_test.cpp \
        "FAIL windows never served" \
        "/^\tadvance(end);$/d" \
        ra-no-advance

    # An unreadable sector left holding whatever the burst buffer held before.
    red_case dvd_readahead.cpp dvd_readahead_test.cpp \
        "FAIL the unreadable sector is zeros" \
        "/memset(tmp, 0, 2048);/d" \
        ra-hole-not-zeroed

    # A failed burst retried a sector at a time but stored at the burst's LENGTH:
    # the good sectors around a bad one come back as leftovers.
    red_case dvd_readahead.cpp dvd_readahead_test.cpp \
        "FAIL its neighbours are intact" \
        "/^\t\t\tn = 1;$/d" \
        ra-retry-keeps-burst-len

    # Main's own window ignored: every buffer hit would wait on the ring.
    red_case dvd_readahead.cpp dvd_readahead_test.cpp \
        "FAIL Main's own window is a hit" \
        "/return 1;                          \/\/ Main's own window has it/d" \
        ra-ignores-main-window

    # ---- the support bundle's argv (issue #81) ---------------------------------
    # The shipped-until-#81 behaviour: no NAV-pack capture at all, so a highlight
    # bug's bundle carried no button data and nothing said so.
    red_case dvd_report.cpp dvd_report_test.cpp \
        "--nav-window is missing" \
        "/argv\[i++\] = \"--nav-window\"/d" no-nav-window

    # Pass the window unconditionally: with no playhead the tool gets a base of 0
    # and captures the NAV packs at the START of the disc -- confidently wrong data
    # instead of none, which is worse than the bug being fixed.
    red_case dvd_report.cpp dvd_report_test.cpp \
        "--nav-window must NOT be passed" \
        "s/if (lba \&\& want_window){/if (want_window)       {/" window-without-playhead

    # Reach for the expensive capture instead. Correct data, wrong cost: minutes of
    # seeking on the optical disc the core is streaming from -- and it still cannot
    # see an in-title menu's buttons, which is the whole point of the window.
    red_case dvd_report.cpp dvd_report_test.cpp \
        "--nav-packs must NOT be passed" \
        "s/argv\[i++\] = \"--nav-window\";   argv\[i++\] = nav_window_for(src);/argv[i++] = \"--nav-packs\";/" \
        expensive-capture

    # Forget the terminator. execvp reads past the end of the array.
    red_case dvd_report.cpp dvd_report_test.cpp \
        "not NUL-terminated" \
        "s/^\targv\[i\] = 0;$/\t\/\* argv[i] = 0; \*\//" no-terminator

    # Ignore what the installed script actually accepts. MEASURED on the rig: an
    # older dvd_report.py exits on the unknown flag and writes NO bundle at all.
    red_case dvd_report.cpp dvd_report_test.cpp \
        "--nav-window must NOT be passed" \
        "s/if (lba \&\& want_window){/if (lba)                {/" ignores-script-version

    # Drop the chunk overlap: the probe then misses a token that straddles an 8 KB
    # read boundary and silently reports "this script is too old", losing the
    # capture on a tool that supports it perfectly well.
    red_case dvd_report.cpp dvd_report_test.cpp \
        "straddling a read boundary" \
        "s/keep = (tlen > 1) ? (tlen - 1) : 0;/keep = 0;/" probe-no-overlap

    # One cap for both media. MEASURED on the rig: 2048 sectors of a real DVD, read
    # while the core streamed it, took 15.7-29.1 s -- the wait this cap exists to
    # bound. An image pays ~0.5 s for the same thing.
    red_case dvd_report.cpp dvd_report_test.cpp \
        "--nav-window = \"2048\" (want \"512\")" \
        "s/if (src \&\& !stat(src, \&st) \&\& S_ISBLK(st.st_mode)) return NAV_WINDOW_OPTICAL;//" \
        one-cap-both-media

    # ...and the inverse: treat an IMAGE as optical and every PC-route bundle loses
    # three quarters of its window for no reason.
    red_case dvd_report.cpp dvd_report_test.cpp \
        "--nav-window = \"512\" (want \"2048\")" \
        "s/return NAV_WINDOW_IMAGE;/return NAV_WINDOW_OPTICAL;/" everything-optical

    # ---- physical VCD/SVCD: probe, track selection, byte assembly ------------
    # Loosen the marker match to "any directory" -- a plain DVD-Video disc
    # (whose root holds VIDEO_TS, a directory too) would then read as VCD/SVCD.
    red_case dvd_vcd_detect.cpp dvd_vcd_test.cpp \
        "DVD-Video root has neither marker" \
        "s/name_is(sec + off + 33, nlen, \"MPEG2\")/1/" \
        vcd-marker-too-loose

    # Stop checking the CDROM_DATA_TRACK bit -- an audio (CD-DA) track would
    # be picked over the real data track whenever it happens to come first.
    red_case dvd_vcd.cpp dvd_vcd_test.cpp \
        "finds a non-first data track" \
        "s/if (e.cdte_ctrl & CDROM_DATA_TRACK)/if (1)/" \
        vcd-any-track-is-data

    # Stop the span at the very NEXT track regardless of its type -- the
    # bug a real burned test disc found: a VCD/SVCD conventionally splits
    # its ISO9660 filesystem into a short first data track and puts the
    # actual MPEG payload in the data track(s) that follow, so stopping at
    # "the next track" unconditionally mounts only the filesystem stub as
    # "the movie" and nothing ever decodes.
    red_case dvd_vcd.cpp dvd_vcd_test.cpp \
        "not track 2's start" \
        "s/if (!(e.cdte_ctrl & CDROM_DATA_TRACK)) { have_end = 1; break; }/{ have_end = 1; break; }/" \
        vcd-span-stops-at-next-track

    # The inverse defect: never stop the span at all, running straight
    # through a trailing CD-DA track into the leadout on a hybrid disc.
    red_case dvd_vcd.cpp dvd_vcd_test.cpp \
        "stops at the CD-DA track" \
        "s/if (!(e.cdte_ctrl & CDROM_DATA_TRACK)) { have_end = 1; break; }//" \
        vcd-span-ignores-cdda-track

    # Drop the burst cap: a large sd_* request would ask READ CD for more
    # frames than g_scratch (sized to VCD_BURST_MAX) can hold.
    red_case dvd_vcd.cpp dvd_vcd_test.cpp \
        "bursts never exceed the cap" \
        "s/if (frames > VCD_BURST_MAX) frames = VCD_BURST_MAX;//" \
        vcd-burst-uncapped

    # Clamp the past-EOF tail but stop zero-filling it -- the core would read
    # whatever was already in the HPS transfer buffer as if it were disc data.
    red_case dvd_vcd.cpp dvd_vcd_test.cpp \
        "the byte just past EOF is zero-filled" \
        "s/memset(out, 0, (size_t)(b1 - b0)); //" \
        vcd-eof-not-zeroed

    # dvd_phys.cpp's dispatch: mount every recognized disc via the DVD-Video
    # sentinel. A VCD/SVCD would then take the CSS-decrypt path (which
    # dvd_css_open() would fail on a disc with no VIDEO_TS) instead of the
    # raw VCD/SVCD source.
    # ⚠ The anchor is the THREE-WAY pick (`is_vcd ? VCD : DVD`), not the old
    # two-way `is_dvd_video ? DVD : VCD`: an audio CD shares the DVD-Video
    # sentinel, so the expression had to be rewritten around is_vcd when the
    # CD-DA probe landed. The harness caught the stale anchor as "mutation
    # matched nothing", which is exactly what that guard is for.
    red_case dvd_phys.cpp dvd_phys_test.cpp \
        "want the VCD sentinel" \
        "s/is_vcd ? DVD_PHYS_VCD_SENTINEL : DVD_PHYS_SENTINEL/DVD_PHYS_SENTINEL/" \
        phys-vcd-wrong-sentinel
    echo
fi

if [ "$fail" != 0 ]; then echo "main/tests: FAILURES"; exit 1; fi
echo "main/tests: ALL GREEN"
