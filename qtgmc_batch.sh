#!/usr/bin/env bash
set -euo pipefail

# ---- Config (override via env) ----------------------------------------------
: "${VS_THREADS:=$(python3 - <<'PY'
import subprocess
try:
    n = int(subprocess.check_output(["sysctl","-n","hw.ncpu"]).strip())
except Exception:
    n = 4
print(max(2, n-2))
PY
)}"

: "${FFMPEG_V_BITRATE:=40M}"     # for h264_videotoolbox
: "${FFMPEG_V_MAXRATE:=50M}"
: "${FFMPEG_V_BUFSIZE:=80M}"
: "${FFMPEG_A_BITRATE:=192k}"

# If you know the tape/clip is actually BFF, export TFF=false
: "${TFF:=true}"

# Duplicate left channel to both if you know one side is dead (set to 1 to enable)
: "${DUP_LEFT_TO_STEREO:=0}"

# Paths to templates (adjust if you keep them elsewhere)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL_DV="${SCRIPT_DIR}/DVTapes_411.vpy"
TMPL_GEN="${SCRIPT_DIR}/Interlaced_Generic.vpy"

# ---- Helpers ----------------------------------------------------------------
die(){ echo "xx $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

abs() {
  python3 - <<'PY' "$1"
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
}

probe_json() {
  ffprobe -hide_banner -v error -print_format json -show_streams -show_format -- "$1"
}

pick_matrix() {
  # crude SD/HD matrix detector from WxH (used only for logging here)
  local w="$1" h="$2"
  if [ "$w" -le 720 ] && [ "$h" -le 576 ]; then
    echo "470bg"
  else
    echo "709"
  fi
}

# ---- Checks -----------------------------------------------------------------
need vspipe
need ffmpeg
need ffprobe
[ -f "$TMPL_DV" ]  || die "Missing template: $TMPL_DV"
[ -f "$TMPL_GEN" ] || die "Missing template: $TMPL_GEN"

# ---- Usage ------------------------------------------------------------------
usage() {
  cat <<USAGE
Usage:
  $(basename "$0") file <input_path> <output_dir>

Example:
  VS_THREADS=6 $(basename "$0") file "/Users/you/QTGMC/_dvd_rips/SC A1" "/Users/you/QTGMC/_exports/"
USAGE
}

[ "${1:-}" = "file" ] || { usage; exit 1; }
in="${2:?input path required}"
outdir="${3:?output directory required}"

[ -e "$in" ] || die "Input not found: $in"
mkdir -p "$outdir"

in_abs="$(abs "$in")"
export VS_SRC="$in_abs"

# ---- Inspect with ffprobe ---------------------------------------------------
json="$(probe_json "$in_abs")" || die "ffprobe failed on: $in_abs"

read -r codec pix_fmt width height channels <<<"$(
python3 - <<'PY' "$json"
import json,sys
j=json.loads(sys.argv[1])
v=[s for s in j.get("streams",[]) if s.get("codec_type")=="video"]
a=[s for s in j.get("streams",[]) if s.get("codec_type")=="audio"]
vc=v[0] if v else {}
ac=a[0] if a else {}
codec=vc.get("codec_name","")
pix=vc.get("pix_fmt","")
w=vc.get("width",0)
h=vc.get("height",0)
ch=ac.get("channels",0)
print(codec, pix, w, h, ch)
PY
)"

[ -n "${codec:-}" ] || die "Could not parse video stream info from ffprobe."

# Choose template and TFF default for DV
tmpl="$TMPL_GEN"
tag="Interlaced_Generic"
# normalize TFF for comparisons without using ${var,,}
tff_norm="$(printf '%s' "$TFF" | tr '[:upper:]' '[:lower:]')"
tff="$tff_norm"

if [ "$codec" = "dvvideo" ] && [ "$pix_fmt" = "yuv411p" ]; then
  tmpl="$TMPL_DV"
  tag="DVTapes_411"
  # DV NTSC in your captures behaves BFF historically; only trust user override if clean true/false
  case "$tff_norm" in
    true|false) tff="$tff_norm" ;;
    *)          tff="false" ;;
  esac
else
  case "$tff_norm" in
    true|false) tff="$tff_norm" ;;
    *)          tff="true" ;;  # default TFF for non-DV unless user overrides
  esac
fi

# ---- Build temp .vpy --------------------------------------------------------
vpy_tmp="$(mktemp -t qtgmc_vpy.XXXXXX).vpy"
trap 'rm -f "$vpy_tmp"' EXIT

# Patch TFF and THREADS placeholders if present in templates
sed \
  -e "s|TFF=True|TFF=$tff|g" \
  -e "s|TFF=False|TFF=$tff|g" \
  -e "s|THREADS=[0-9][0-9]*|THREADS=$VS_THREADS|g" \
  "$tmpl" > "$vpy_tmp"

# ---- Output path ------------------------------------------------------------
base="$(basename "$in_abs")"
safe_base="$(printf '%s' "$base" | sed 's/[^A-Za-z0-9._-]/_/g')"
out_path="${outdir%/}/${safe_base}_4k_hw.mp4"

# ---- Audio filter (optional mono/left dup) ----------------------------------
AFILTER=""
if [ "${DUP_LEFT_TO_STEREO}" = "1" ]; then
  AFILTER="-af pan=stereo|c0=FL|c1=FL"
fi

# ---- Log --------------------------------------------------------------------
matrix="$(pick_matrix "$width" "$height")"
echo ">> [$tag] $in  (pix=$pix_fmt, codec=$codec, TFF=$tff, threads=$VS_THREADS, matrix=$matrix)"

# ---- Run vspipe | ffmpeg ----------------------------------------------------
set +e
vspipe -c y4m "$vpy_tmp" - | \
ffmpeg -hide_banner -y \
  -f yuv4mpegpipe -i - \
  -i "$in_abs" \
  -map 0:v:0 -map 1:a:0 \
  -vf "scale=3840:2160:flags=bicubic,format=yuv420p" \
  -c:v h264_videotoolbox -b:v "$FFMPEG_V_BITRATE" -maxrate "$FFMPEG_V_MAXRATE" -bufsize "$FFMPEG_V_BUFSIZE" \
  -c:a aac -b:a "$FFMPEG_A_BITRATE" \
  ${AFILTER:+$AFILTER} \
  -shortest \
  -threads:v "$VS_THREADS" -threads:a 2 \
  "$out_path"
rc=$?
set -e

[ "$rc" -eq 0 ] || die "ffmpeg failed"
echo "✓ Done: $out_path"

