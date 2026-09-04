#!/bin/bash
# publish_draft.sh — create the GitHub release DRAFT for a built core and kick the
# packaging workflow, in one step.
#
# The .rbf is the one artifact CI cannot produce: raetro/quartus:mister is 17 GB
# unpacked against a hosted runner's ~14 GB of disk, and a timing-marginal fit needs
# a human-judged seed sweep. So the split is: build the core here, let
# .github/workflows/package.yml do everything mechanical around it.
#
#   USE_DOCKER=1 ./build_release.sh --release --compile    # -> releases/DVD_YYYYMMDD.rbf (+ .json)
#   ./tools/publish_draft.sh v0.4.0 --notes /tmp/relnotes.md --title "v0.4.0 — <headline>"
#   # ...watch the run, download the zip, flash, smoke-test...
#   gh release edit v0.4.0 --draft=false
#
# ⚠ A DRAFT cannot trigger a workflow (GitHub does not fire release:created for
# drafts) and has no git tag, which is why this dispatches package.yml explicitly
# and why the workflow reads the commit out of the build manifest.
#
# Options:
#   --notes PATH   release-notes markdown (required unless --notes-inline)
#   --title TEXT   release title (default: "<tag> — <first heading in the notes>")
#   --rbf PATH     core to publish (default: newest non-MARGINAL releases/DVD_*.rbf)
#   --no-dispatch  create the draft only; do not start the packaging workflow

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

TAG=""; NOTES=""; TITLE=""; RBF=""; DISPATCH=1
while [ $# -gt 0 ]; do
    case "$1" in
        --notes)       NOTES="$2"; shift 2 ;;
        --title)       TITLE="$2"; shift 2 ;;
        --rbf)         RBF="$2";   shift 2 ;;
        --no-dispatch) DISPATCH=0; shift ;;
        -h|--help)     sed -n '2,26p' "$0"; exit 0 ;;
        -*)            echo "!! unknown option: $1" >&2; exit 1 ;;
        *)             [ -z "$TAG" ] || { echo "!! unexpected argument: $1" >&2; exit 1; }
                       TAG="$1"; shift ;;
    esac
done

die() { echo "!! $*" >&2; exit 1; }

[ -n "$TAG" ] || die "usage: tools/publish_draft.sh vX.Y.Z --notes PATH [--title TEXT]"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be vMAJOR.MINOR.PATCH, got '$TAG'"
[ -n "$NOTES" ] || die "--notes PATH is required (the workflow never writes the release body)"
[ -f "$NOTES" ] || die "notes file not found: $NOTES"

# --- Pre-flight, all of it BEFORE touching GitHub --------------------------
# The invariant this protects: a bare semver lives in exactly one commit, and
# that commit is the one being released. See dvd/emu.sv "VERSIONING".
VER="$(sed -n 's/.*`define CORE_VERSION "\([^"]*\)".*/\1/p' dvd/emu.sv | head -1)"
[ "$VER" = "$TAG" ] || die "dvd/emu.sv says CORE_VERSION \"$VER\" but you are releasing $TAG.
   Set it on the release commit (together with mkdocs.yml's released_version and the
   manual sweep) and rebuild — the OSD would otherwise advertise the wrong version."

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo ">> note: releasing from branch '$BRANCH', not main" >&2
[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first.
   The workflow checks out the commit named in the build manifest, so uncommitted
   changes would silently NOT be in the released Main, Scripts or DVD_INSTALL.txt."
git diff --quiet "@{upstream}" 2>/dev/null || echo ">> note: HEAD differs from its upstream; push before publishing" >&2

if [ -z "$RBF" ]; then
    RBF="$(ls -t releases/DVD_*.rbf 2>/dev/null | grep -v MARGINAL | head -1 || true)"
fi
[ -n "$RBF" ] && [ -f "$RBF" ] || die "no core .rbf found. Build one:
   USE_DOCKER=1 ./build_release.sh --release --compile"
BASE="$(basename "$RBF")"
[[ "$BASE" =~ ^DVD_[0-9]{8}\.rbf$ ]] || die "'$BASE' is not DVD_YYYYMMDD.rbf.
   MiSTer's core browser parses that date to rank builds; use --release (no --name)."

MAN="${RBF}.json"
[ -f "$MAN" ] || die "missing the provenance manifest $MAN.
   build_release.sh emits it beside the .rbf; rebuild, or the workflow cannot
   determine which commit to check out (a draft release has no git tag)."

# Cheap local mirror of the workflow's gates, so a mistake costs no round trip.
python3 - "$MAN" "$TAG" "$RBF" <<'PY'
import json, sys, hashlib, os
man, tag, rbf = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
def die(m): sys.exit("!! " + m)
if man.get("core_version") != tag:
    die("manifest says the core was built as %r, not %r" % (man.get("core_version"), tag))
if man["rbf"].get("marginal") or not man["timing"].get("pass"):
    die("that build is TIMING-MARGINAL (%s/%s MHz, gate %s) — never ship one; re-roll with tools/seed_sweep.sh"
        % (man["timing"].get("clk_dec_100c_mhz"), man["timing"].get("clk_dec_m40c_mhz"),
           man["timing"].get("threshold_mhz")))
h = hashlib.sha256(open(rbf, "rb").read()).hexdigest()
if man["rbf"].get("sha256") != h:
    die("manifest sha256 does not match the .rbf — they are from different builds")
sz = os.path.getsize(rbf)
if not (3_500_000 <= sz <= 5_000_000):
    die(".rbf is %d bytes, outside the 3.5-5.0 MB band (an uncompressed pack does not configure the FPGA)" % sz)
if man["git"].get("dirty"):
    print(">> note: that core was built from a DIRTY tree", file=sys.stderr)
print(">> core %s  seed %s  %s/%s MHz  %s"
      % (man["rbf"]["name"], man["fit"]["seed"], man["timing"]["clk_dec_100c_mhz"],
         man["timing"]["clk_dec_m40c_mhz"], man["git"]["sha"][:12]))
PY

# gh is not authenticated on this machine by default; the token lives in the git
# credential helper (see the gh-cli-not-authenticated memory).
if [ -z "${GH_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
    GH_TOKEN="$(printf 'host=github.com\nprotocol=https\n\n' | git credential fill | sed -n 's/^password=//p')"
    [ -n "$GH_TOKEN" ] || die "could not obtain a GitHub token from the git credential helper"
    export GH_TOKEN
fi

[ -n "$TITLE" ] || TITLE="$TAG — $(sed -n 's/^#\+ *//p' "$NOTES" | head -1)"

echo "== creating DRAFT $TAG"
echo "   title : $TITLE"
echo "   core  : $BASE"
gh release create "$TAG" --draft --title "$TITLE" --notes-file "$NOTES" "$RBF" "$MAN"

if [ "$DISPATCH" -eq 1 ]; then
    echo "== dispatching package.yml"
    gh workflow run package.yml -f tag="$TAG"
    sleep 3
    echo
    echo "Watch it:      gh run watch \$(gh run list --workflow=package.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
fi
echo "Review draft:  gh release view $TAG --web"
echo "Then publish:  gh release edit $TAG --draft=false"
